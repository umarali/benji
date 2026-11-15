"""Checks the local policy file, the per-turn tool limit, start-up, provider errors in plain words,
and keys kept in the Keychain.

The engine side of each: the policy file that can only restrict, the per-turn tool cap, what the app says in `hello`, the measured prewarm, an unchanged screenshot not sent
again, provider failures in plain words, the Keychain mode of the key loader, and Benji's own cues.
Called from selftest.py. No network, no real key, no real Keychain, no model.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import wave
import struct
from pathlib import Path


def run(check, here: Path) -> None:
    from benji import audit, config, errors, policy
    from benji import serve as S
    from benji import tools as T
    from benji.agent import MAX_TOOL_CALLS, Agent
    from benji.prompts import TurnInfo

    print("quiet check, policy, protocol hello and cues:")
    say = lambda text: {"text": text, "tool_calls": [], "usage": {"input_tokens": 1, "output_tokens": 1,
                                                                    "cache_read_tokens": 0, "cache_write_tokens": 0}}
    call = lambda name, inp, cid="c1": {"text": "", "tool_calls": [{"id": cid, "name": name, "input": inp}],
                                        "usage": {"input_tokens": 1, "output_tokens": 1,
                                                  "cache_read_tokens": 0, "cache_write_tokens": 0}}

    class Script:
        name, model = "claude", "scripted"

        def __init__(self, *replies):
            self.replies, self.seen, self.tools = list(replies), [], []

        def complete(self, system, neutral, tools):
            self.seen.append([dict(m) for m in neutral])
            self.tools.append([t["name"] for t in tools])
            r = self.replies.pop(0) if self.replies else say("done")
            return r(neutral) if callable(r) else r

    class Events:
        def __init__(self):
            self.items, self.cv = [], threading.Condition()

        def __call__(self, e):
            with self.cv:
                self.items.append(e)
                self.cv.notify_all()

        def wait(self, pred, timeout=5.0):
            end = time.time() + timeout
            with self.cv:
                while not any(pred(e) for e in self.items):
                    if not self.cv.wait(max(end - time.time(), 0)) and time.time() >= end:
                        return None
                return next(e for e in self.items if pred(e))

        def of(self, tid):
            return [e for e in self.items if e.get("id") == tid]

    def log_lines(path: Path) -> list[dict]:
        return [json.loads(l) for l in path.read_text().splitlines() if l.strip()] if path.exists() else []

    # ---- the policy file --------------------------------------------------------------------------
    every_tool = set(T._BY_NAME)
    in_families = {t for tools in policy.FAMILIES.values() for t in tools}
    check("every tool the engine can offer is in exactly one policy family",
          every_tool == in_families and sum(len(t) for t in policy.FAMILIES.values()) == len(in_families))

    def pol(text: str | bytes | None) -> policy.Policy:
        with tempfile.TemporaryDirectory() as td:
            if text is not None:
                (Path(td) / policy.FILE_NAME).write_bytes(text if isinstance(text, bytes) else text.encode())
            return policy.load(td)

    check("no file: no policy; an empty object, an empty list: no policy",
          not pol(None).active and not pol("{}").active and not pol('{"disable": []}').active)
    p = pol('{"disable": ["shell", "Web", " apps ", "browser_read", "nonsense", "run_applescript"]}')
    check("a policy names families (any case, trimmed) and single tools; unknown names are ignored",
          p.families == {"shell", "web", "apps"} and p.tools == {"browser_read", "run_applescript"}
          and p.blocks("run_shell") and p.blocks("web_fetch") and p.blocks("run_shortcut")
          and p.blocks("browser_read") and not p.blocks("browser_open") and not p.blocks("read_file"))
    widen = pol('{"enable": ["shell"], "allow": ["web"], "disable": [], "approve": "always", "auto_approve": true, '
                '"folders": ["/"], "workdir": "/", "yes": true}')
    check("it can only restrict: enable, allow, approve, folders and every other key change nothing",
          not widen.active and not widen.unreadable)
    strict = [pol("not json"), pol("[1,2]"), pol('{"disable": "shell"}'), pol('{"disable": [1]}'), pol(b"\xff\xfe"),
              pol('{"disable": [' + '"x",' * 5000 + '"x"]}')]
    check("a file that is there but isn't in the format is read the strict way: everything that reaches outside is off",
          all(s.unreadable and s.families == set(policy.STRICT) for s in strict)
          and all(s.blocks(t) for s in strict for t in ("run_shell", "write_file", "web_fetch", "click", "browser_read", "start_job"))
          and not any(s.blocks(t) for s in strict for t in ("remember", "recall", "list_skills")))
    specs = T.tool_specs(screen=True, jobs=True, browser=True, notes=True)
    check("a blocked tool is not in the specs the model is given",
          {s["name"] for s in p.filter_specs(specs)} == {s["name"] for s in specs} - set(policy.FAMILIES["shell"])
          - set(policy.FAMILIES["web"]) - set(policy.FAMILIES["apps"]) - {"browser_read"})

    with tempfile.TemporaryDirectory() as td:
        wd = Path(td)
        (wd / "note.txt").write_text("hello")
        audit.configure(wd / audit.FILE_NAME)
        counted: list = []
        orig = T.dispatch
        T.dispatch = lambda ctx, name, inp: counted.append(name) or orig(ctx, name, inp)
        try:
            prov = Script(call("run_shell", {"command": "ls"}), call("read_file", {"path": "note.txt"}), say("ok"))
            agent = Agent(prov, "sys", wd, approve=lambda r: True, policy=policy.Policy(families=frozenset({"shell"})))
            agent.set_run("t1")
            agent.send("list")
            check("the agent doesn't offer a blocked family, and a call to it that comes anyway is refused before the gate",
                  "run_shell" not in prov.tools[0] and "read_file" in prov.tools[0]
                  and prov.seen[1][-1]["content"].startswith("[refused]") and "policy.json" in prov.seen[1][-1]["content"]
                  and counted == ["read_file"])
            tool_events = [e for e in log_lines(wd / audit.FILE_NAME) if e["kind"] == "tool"]
            check("the refused call is one audit line: tool, gate denied, code policy_blocked, result refused",
                  tool_events[0]["tool"] == "run_shell" and tool_events[0]["gate"] == "denied"
                  and tool_events[0]["code"] == "policy_blocked" and tool_events[0]["result"] == "refused"
                  and tool_events[1]["tool"] == "read_file" and all(audit.validate(e) for e in tool_events))
            info = TurnInfo(allow_pointing=True, screen_actions=True, screen_simple_steps=True, jobs=True, browser=True)
            r = policy.Policy(families=frozenset({"screen", "jobs"})).restrict_turn(info)
            check("a turn the policy narrows loses screen steps and jobs; it never gains anything",
                  not r.screen_actions and not r.jobs and info.screen_actions and r.allow_pointing and r.browser
                  and policy.NONE.restrict_turn(info) is info)
        finally:
            T.dispatch = orig
            audit.configure(None)

    # ---- the per-turn tool cap -----------------------------------------------------------------------
    with tempfile.TemporaryDirectory() as td:
        wd = Path(td)
        (wd / "a.txt").write_text("a")
        ran: list = []
        orig = T.dispatch
        T.dispatch = lambda ctx, name, inp: ran.append(name) or "[ok] fine"
        audit.configure(wd / audit.FILE_NAME)
        try:
            prov = Script(*[call("list_dir", {"path": "."}, f"c{i}") for i in range(6)], say("Here's what I have."))
            agent = Agent(prov, "sys", wd, approve=lambda r: True)
            agent.max_tool_calls = 3
            agent.set_run("t2")
            answer = agent.send("go")
            check("past the cap a call returns 'superseded' and is not run; the turn then ends with an answer",
                  len(ran) == 3 and answer == "Here's what I have."
                  and sum("[superseded]" in m.get("content", "") for m in agent.messages if m.get("role") == "tool") == 3
                  and "tool calls" in prov.seen[-1][-1]["content"])
            e = [x for x in log_lines(wd / audit.FILE_NAME) if x["kind"] == "tool" and x["code"] == "tool_cap"]
            check("each superseded call is an audit line with the code tool_cap, and the cap counts per send()",
                  len(e) == 3 and all(x["result"] == "refused" and x["gate"] == "denied" for x in e)
                  and MAX_TOOL_CALLS == 30 and agent._tool_calls == 6)
            ran.clear()
            prov.replies = [call("list_dir", {"path": "."}), say("again")]
            agent.send("again")
            check("the next turn starts its count again", len(ran) == 1 and agent._tool_calls == 1)
        finally:
            T.dispatch = orig
            audit.configure(None)

    # ---- an unchanged screenshot is not sent again ------------------------------------------------------
    import base64, struct as _s, zlib

    def png(rgb: bytes) -> bytes:
        chunk = lambda t, b: _s.pack(">I", len(b)) + t + b + _s.pack(">I", zlib.crc32(t + b))
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", _s.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(b"\x00" + rgb)) + chunk(b"IEND", b""))

    def image(rgb: bytes) -> dict:
        return {"media_type": "image/png", "data": base64.b64encode(png(rgb)).decode()}

    def screen_run(second: bytes, third: bytes):
        a, b, c = image(b"\x01\x02\x03"), image(second), image(third)
        results = iter([b, c])
        prov = Script(call("click", {"x": 5, "y": 5, "label": "a"}, "c1"), call("click", {"x": 6, "y": 6, "label": "b"}, "c2"),
                      say("done"))

        def step(st, mode=None):
            img = next(results)
            return {"status": "done", "text": "ok", "image": img}
        agent = Agent(prov, "sys", Path(tempfile.gettempdir()), approve=lambda r: True)
        agent.allow_screen_actions(step, (100, 100))
        agent.send("go", images=[a])
        return agent, a

    agent, first = screen_run(b"\x01\x02\x03", b"\x09\x09\x09")
    tools = [m for m in agent.messages if m.get("role") == "tool"]
    check("a screen step that changed nothing sends no new picture and keeps the one the model has",
          "images" not in tools[0] and "exactly the same" in tools[0]["content"]
          and agent.messages[0]["images"] == [first] and tools[1].get("images"))
    agent, first = screen_run(b"\x07\x07\x07", b"\x07\x07\x07")
    tools = [m for m in agent.messages if m.get("role") == "tool"]
    check("a changed screen is sent (the earlier step's picture is dropped for the newer one), and the same one twice is sent once",
          tools[0].get("images") and not tools[0]["images"][0] == first and "images" not in tools[1]
          and "exactly the same" in tools[1]["content"])

    # ---- hello: what the app says it can do ------------------------------------------------------------------
    sent_info: list = []

    def server(**kw):
        ev = Events()

        def make(approve, on_tool, cancelled, info):
            sent_info.append(info)
            return Agent(Script(say("ok")), info.rules("panel"), Path(tempfile.gettempdir()), approve=approve,
                         on_tool=on_tool, cancelled=cancelled)
        srv = S.Server(make, ev, {"version": "t", "host": "api.example.com"}, **kw)
        return srv, ev

    shot = Path(tempfile.mkdtemp()) / "s.png"
    shot.write_bytes(png(b"\x01\x02\x03"))
    screen = {"width": 1330, "height": 864, "menu_bar": 33, "display": "built-in", "displays": 1}
    send = lambda tid: {"type": "send", "id": tid, "text": "hi", "allow_pointing": True, "image": str(shot),
                        "screen": screen, "screen_actions": True, "screen_simple_steps": True}

    def turn_with(hello_extra: dict, policy_for=None):
        sent_info.clear()
        srv, ev = server(**({"policy_for": policy_for} if policy_for else {}))
        srv.handle({"type": "hello", "protocol": S.PROTOCOL, **hello_extra})
        ready = ev.wait(lambda e: e.get("type") == "ready")
        srv.handle(send("t1"))
        ev.wait(lambda e: e.get("type") == "done")
        return ready, sent_info[0], srv

    ready, info, srv = turn_with({})
    check("an older app (hello with no capabilities) is taken at its send; ready lists the engine's own",
          info.screen_actions and info.allow_pointing and srv.app_caps is None
          and ready["capabilities"] == list(S.ENGINE_CAPS) and ready["protocol"] == 1)
    ready, info, srv = turn_with({"capabilities": ["pointing", "cards", "figures", "jobs"]})
    check("an app that doesn't list screen_actions gets no screen steps even if its send asks for them",
          not info.screen_actions and not info.screen_simple_steps and info.allow_pointing)
    ready, info, srv = turn_with({"capabilities": ["screen_actions", "pointing", "teleport", "x" * 99]})
    check("a capability the engine doesn't know is ignored; one that is too long makes the whole list unusable",
          srv.app_caps is None and info.screen_actions)
    ready, info, srv = turn_with({"capabilities": ["screen_actions", "pointing", "teleport"]})
    check("unknown names are dropped from a usable list, known ones kept",
          srv.app_caps == {"screen_actions", "pointing"} and info.screen_actions and not info.cards)
    ready, info, srv = turn_with({"capabilities": ["pointing"]})
    check("without 'screen_actions' and 'cards' the engine neither offers screen steps nor card lines",
          not info.screen_actions and not info.cards)
    ready, info, srv = turn_with({"capabilities": []})
    check("an empty list means the app can do none of it: no pointing, no screen steps",
          srv.app_caps == frozenset() and not info.allow_pointing and not info.screen_actions)
    for junk in ("screen_actions", 7, {"a": 1}, [1, 2], [None]):
        ready, info, srv = turn_with({"capabilities": junk})
        check(f"hello capabilities {junk!r}: ignored, as if absent", srv.app_caps is None and info.screen_actions)
    ready, info, srv = turn_with({"capabilities": ["screen_actions", "pointing"]},
                                 policy_for=lambda: policy.Policy(families=frozenset({"screen"})))
    check("the policy narrows a turn the app could carry out", not info.screen_actions and info.allow_pointing)

    # ---- prewarm --------------------------------------------------------------------------------------------
    with tempfile.TemporaryDirectory() as td:
        audit.configure(Path(td) / audit.FILE_NAME)
        warmed: list = []
        srv, ev = server(warm=lambda host: warmed.append(host))
        srv.handle({"type": "hello", "protocol": S.PROTOCOL})
        srv.handle({"type": "prewarm"})
        for _ in range(100):
            if warmed:
                break
            time.sleep(0.02)
        time.sleep(0.1)
        srv.handle({"type": "prewarm"})                 # too soon after the first
        srv.last_prewarm_at = 0.0
        srv.last_call_at = time.monotonic()
        srv.handle({"type": "prewarm"})                 # a recent call: the connection is warm anyway
        time.sleep(0.1)
        lines = [e for e in log_lines(Path(td) / audit.FILE_NAME) if e["kind"] == "prewarm"]
        check("prewarm resolves the provider's host once when the last call is old; a second key-down at once, or after a recent call, is skipped",
              warmed == ["api.example.com"] and [e["skipped"] for e in lines] == [False, True, True]
              and lines[0]["ok"] is True and isinstance(lines[0]["ms"], int))
        check("the audit line is a kind, a flag and a time: nothing else; every line passes the schema",
              all(set(e) <= {"time", "kind", "src", "skipped", "ms", "ok"} for e in lines)
              and all(audit.validate(e) for e in lines))
        srv2, ev2 = server(warm=lambda host: warmed.append(host))
        srv2.info["host"] = "localhost:11434"
        srv2.handle({"type": "hello", "protocol": S.PROTOCOL})
        before = len(warmed)
        srv2.handle({"type": "prewarm"})
        time.sleep(0.1)
        check("a server on this Mac is never warmed", len(warmed) == before)
        srv3, _ = server(warm=lambda host: (_ for _ in ()).throw(OSError("no network")))
        srv3.handle({"type": "hello", "protocol": S.PROTOCOL})
        srv3.handle({"type": "prewarm"})
        time.sleep(0.2)
        check("a warm-up that fails is logged as not ok and changes nothing else",
              any(e["kind"] == "prewarm" and e.get("ok") is False for e in log_lines(Path(td) / audit.FILE_NAME)))
        srv4, ev4 = server()
        srv4.handle({"type": "prewarm"})
        check("prewarm before hello is refused like any request", ev4.items and ev4.items[0].get("code") == "protocol")
        audit.configure(None)

    # ---- provider failures in plain words -------------------------------------------------------------------
    cases = [
        ("HTTP 401 from api.anthropic.com:\n{\"error\":{\"message\":\"invalid x-api-key\"}}", "auth"),
        ("HTTP 401 from api.deepseek.com: Authentication Fails", "auth"),
        ("HTTP 403 from api.openai.com: Your key doesn't have access to this model", "auth"),
        ("HTTP 403 from api.openai.com: unsupported_country_region_territory", "region"),
        ("HTTP 403 from api.anthropic.com: Request not allowed in your country", "region"),
        ("HTTP 429 from api.openai.com: rate limit reached for requests", "rate_limit"),
        ("HTTP 429 from api.openai.com: insufficient_quota: you exceeded your current quota", "quota"),
        ("HTTP 429 from api.moonshot.ai: account balance is not enough", "quota"),
        ("HTTP 402 from api.deepseek.com: Insufficient Balance", "quota"),
        ("HTTP 529 from api.anthropic.com: overloaded", "provider"),
        ("HTTP 503 from api.openai.com: The server is overloaded", "provider"),
        ("network error calling https://api.anthropic.com/v1/messages: [Errno 8] nodename nor servname provided", "network"),
        ("stream from https://api.openai.com/v1/chat/completions broke off: timed out", "network"),
        ("HTTP 400 from api.openai.com: bad param", "bad_request"),
        ("claude-x did not return anything", "other"),
    ]
    got = [(errors.explain(t)[0], errors.explain(t)[1]) for t, _ in cases]
    check("auth, network, rate limit, quota, region and a provider in trouble are told apart",
          [g[0] for g in got] == [r for _, r in cases] and set(errors.REASONS) >= {r for _, r in cases})
    check("the words name the status and the host and say what to do; the server's body is not repeated",
          "api.anthropic.com" in got[0][1] and "401" in got[0][1] and "invalid x-api-key" not in got[0][1]
          and "country" in got[4][1] and "minute" in got[5][1] and "credit" in got[6][1]
          and "internet" in got[11][1] and "v1/messages" not in got[11][1] and got[14][1] == cases[14][0])
    srv, ev = server()
    from benji.providers import ProviderError

    def broken(approve, on_tool, cancelled, info):
        class P(Script):
            def complete(self, *a):
                raise ProviderError("HTTP 401 from api.anthropic.com:\n{}")
        return Agent(P(), "sys", Path(tempfile.gettempdir()), approve=approve)
    bad = S.Server(broken, ev, {"version": "t"})
    bad.handle({"type": "hello", "protocol": 1})
    bad.handle({"type": "send", "id": "e1", "text": "hi"})
    err = ev.wait(lambda e: e.get("type") == "error" and e.get("id") == "e1")
    check("the error event keeps code 'provider', adds a reason, and carries the plain words",
          err and err["code"] == "provider" and err["reason"] == "auth" and "didn't accept the API key" in err["text"])

    # ---- the key loader in Keychain mode ----------------------------------------------------------------------
    names = json.loads((here / "companion" / "Tests" / "key-name-cases.json").read_text())
    check("one table of key names: the engine's rule says what the app's Keychain code says",
          all(config.is_secret_name(n) is want for n, want in names.items()))
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        (home / ".benji.env").write_text("ANTHROPIC_API_KEY=FAKE-file-key\nBENJI_MODEL=claude-sonnet-5-5\n"
                                          "export OTHER_API_KEY = x\nSERPAPI_KEY=FAKE-serp\n")
        code = (f"import sys; sys.path.insert(0, {str(here)!r}); import os, json; from benji import config; config.load_dotenv(); "
                "print(json.dumps({k: os.environ.get(k) for k in ('ANTHROPIC_API_KEY','BENJI_MODEL','SERPAPI_KEY','FROM_APP_API_KEY')}))")
        def engine(extra: dict) -> dict:
            env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "BENJI_KEY_SOURCE", "BENJI_MODEL")}
            env.update(HOME=str(home), **extra)
            out = subprocess.run([sys.executable, "-I", "-c", code], env=env, capture_output=True, text=True, cwd=str(home))
            return json.loads(out.stdout)
        plain = engine({})
        kc = engine({"BENJI_KEY_SOURCE": "keychain", "FROM_APP_API_KEY": "FAKE-from-app"})
        check("without the Keychain mode the keys load from the file",
              plain["ANTHROPIC_API_KEY"] == "FAKE-file-key" and plain["SERPAPI_KEY"] == "FAKE-serp")
        check("in Keychain mode no key is read from the file, even one that is still there; other settings are, and the app's own value stays",
              kc["ANTHROPIC_API_KEY"] is None and kc["SERPAPI_KEY"] is None and kc["BENJI_MODEL"] == "claude-sonnet-5-5"
              and kc["FROM_APP_API_KEY"] == "FAKE-from-app")
        miss = subprocess.run([sys.executable, "-I", "-c", "import sys; sys.path.insert(0, %r); from benji import config; config.load_config(workdir='%s')" % (str(here), home / "w")],
                              env={"HOME": str(home), "PATH": os.environ.get("PATH", ""),
                                   "BENJI_KEY_SOURCE": "keychain"}, capture_output=True, text=True, cwd=str(home))
        check("a missing key in Keychain mode says where it should have come from, and never prints the file's key",
              "Keychain" in miss.stderr and "FAKE-file-key" not in miss.stderr + miss.stdout)

    # ---- Benji's own cues -----------------------------------------------------------------------------------
    cues = here / "companion" / "Resources" / "Cues"
    manifest = json.loads((cues / "manifest.json").read_text())
    listed = [f for c in manifest["cues"] for f in c["files"]]
    on_disk = sorted(p.name for p in cues.glob("*.wav"))
    check("five cues, and every cue id in the manifest resolves to a file; every audio file is listed",
          [c["id"] for c in manifest["cues"]] == ["listening-on", "listening-off", "done", "approval", "error"]
          and sorted(listed) == on_disk and all((cues / f).is_file() for f in listed))
    problems: list = []
    for c in manifest["cues"]:
        for f in c["files"]:
            with wave.open(str(cues / f), "rb") as w:
                n = w.getnframes()
                fmt = (w.getnchannels(), w.getsampwidth(), w.getframerate())
                d = struct.unpack(f"<{n}h", w.readframes(n))
            seconds = n / fmt[2]
            peak = max(abs(x) for x in d) / 32768
            dc = abs(sum(d) / n) / 32768
            if fmt != (1, 2, 48000): problems.append((f, "format", fmt))
            if not 0.1 <= seconds <= 0.6: problems.append((f, "length", seconds))
            if abs(seconds * 1000 - c["duration_ms"]) > 1: problems.append((f, "manifest length", seconds))
            if not peak <= 10 ** (-18 / 20): problems.append((f, "peak", peak))
            if peak < 10 ** (-30 / 20): problems.append((f, "too quiet", peak))
            if dc > 0.0005: problems.append((f, "dc", dc))
            if d[0] != 0 or d[-1] != 0: problems.append((f, "ends", d[0], d[-1]))
            if max(abs(x) for x in d[:48]) > 32768 * 0.2: problems.append((f, "starts loud"))
    check("every bundled cue is 48 kHz mono 16-bit, 0.1 to 0.6 s, peaks at or under -18 dBFS (never near clipping), "
          "has no DC offset, starts and ends on zero",
          not problems)
    if problems:
        print("   ", problems)
    r = subprocess.run([sys.executable, "-I", str(here / "tools" / "make_cues.py"), "--check"], capture_output=True, text=True)
    check("the committed cue files are exactly what tools/make_cues.py renders (stdlib only, from sine tones)",
          r.returncode == 0)
    src = (here / "tools" / "make_cues.py").read_text()
    check("the script reads no audio file and uses no library beyond the standard one",
          "numpy" not in src and "import scipy" not in src and "open(" not in src.replace("wave.open(", "").replace("Path.open", "")
          and ".read_bytes()" in src.split("def main")[1] and "wave.open(buf" in src)
