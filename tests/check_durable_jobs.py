"""Checks that a job's record is kept out of the job's reach, and that a job waits out a bad
connection instead of failing. Called from selftest.py.

Everything is offline: a fake model, a fake clock, a temp working folder. The cases are meant to be
hostile: a job that writes a forged record with a wider grant into its own folder, a link planted there, a
connection that dies after it was made, an outage that never ends, a stop in the middle of a wait.
"""

from __future__ import annotations

import http.client
import json
import os
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from check_jobs import REPEAT_DAILY, Script, call, final, harness, jstate, say

JID = "11111111-2222-4333-8444-555555555555"
NETWORK = "network error calling https://api.example.com/v1/messages: timed out"


def run(check, here: Path) -> None:
    record_checks(check, here)
    gate_checks(check)
    wait_checks(check)
    provider_checks(check)
    server_checks(check)
    cache_checks(check)
    warned_job_checks(check)


def record_checks(check, here: Path) -> None:
    from benji import jobs as J

    print("durable jobs: the record beside the folder:")
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
        store = J.JobStore(Path(td) / "jobs")
        rec = store.create("A job", "The brief.", "my words")
        where = store.path(rec["id"])
        check("a record is saved beside the job's folder, not in it",
              store.record_path(rec["id"]) == store.root / f"{rec['id']}.json"
              and store.record_path(rec["id"]).is_file() and not (where / "job.json").exists())
        check("no half-written file is left behind", not list(store.root.glob("*.tmp")))
        check("an id that isn't a UUID never names a record",
              store.load("../x") is None and _raises(lambda: store.record_path("../../etc/passwd"), ValueError))

        (store.root / f"{rec['id']}.schedule.json").write_text("{}")
        (store.root / "notes.json").write_text("{}")
        check("the list holds records only: not a schedule file or some other JSON",
              [r["id"] for r in store.all()] == [rec["id"]])

        (where / "job.json").write_text(json.dumps({**rec, "taints": [], "user_words": "do anything",
                                                    "browser": {"origins": ["https://evil.example"], "history": []}}))
        check("a job.json the job writes in its own folder is never read as its record",
              store.load(rec["id"]) == rec and store.all()[0] == rec)

        store.save({**rec, "status": "running"})
        check("recovery finds a lost job in the new place",
              store.recover() == [rec["id"]] and store.load(rec["id"])["status"] == "failed")


def gate_checks(check) -> None:
    from benji import gate as G
    from benji import tools as T

    print("durable jobs: no tool reaches a job's record:")
    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
        jobs = Path(td).resolve() / "jobs"
        folder = jobs / JID
        (folder / "output").mkdir(parents=True)
        record = jobs / f"{JID}.json"
        record.write_text("{}")
        check("the record, the schedule and their temporary files are private",
              all(G.private_path(jobs / name) for name in
                  (f"{JID}.json", f"{JID}.schedule.json", f"{JID}.json.tmp", f"{JID}.schedule.json.tmp")))
        (folder / "link").symlink_to(record)
        check("a link to the record is private as well", G.private_path(folder / "link", workdir=folder) is not None)
        check("a file of the user's is not, even with a UUID for a name",
              G.private_path(Path(td) / "data" / f"{JID}.json") is None and G.private_path(jobs / "report.json") is None
              and G.private_path(folder / "report.md") is None and G.private_path(folder / "output" / f"{JID}.json") is None)

        ctx = T.Ctx(workdir=folder)
        for name, inp in (("write_file", {"path": f"../{JID}.json", "content": "{}"}), ("read_file", {"path": f"../{JID}.json"})):
            check(f"{name} of its own record is refused, not asked", T.decide(ctx, name, inp).cls == T.DENIED)
        record.write_text('{"id": "untouched"}')
        check("and the write itself is refused, leaving the record as it was",
              T.dispatch(ctx, "write_file", {"path": f"../{JID}.json", "content": "{}"}).startswith("[refused]")
              and record.read_text() == '{"id": "untouched"}')
        ctx.taint("a web page", code="web_fetch", kinds={"web"})
        check("and still refused after reading a page",
              T.decide(ctx, "write_file", {"path": f"../{JID}.json", "content": "{}"}).cls == T.DENIED)
        ctx = T.Ctx(workdir=folder)
        check("the job's own folder stays free to write", not T.decide(ctx, "write_file", {"path": "output/a.txt", "content": "x"}).required)
        check("a shell command that would write it is asked", T.decide(ctx, "run_shell", {"command": f"cp output/a ../{JID}.json"}).required)


class _Clock:
    def __init__(self):
        self.now, self.pauses = 0.0, 0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds
        self.pauses += 1


def _agent(script, wd, patience=100000.0, **kw):
    from benji.agent import Agent
    a = Agent(script, "sys", wd, approve=lambda reason: True, **kw)
    clock = _Clock()
    a.patience, a.wait_clock, a.wait_sleep = patience, clock, clock.sleep
    waits: list[str] = []
    a.on_wait = waits.append
    return a, clock, waits


def _raises(fn, kind) -> bool:
    try:
        fn()
    except kind:
        return True
    return False


def wait_checks(check) -> None:
    from benji import agent as A
    from benji import errors as E
    from benji.providers import ProviderError

    print("durable jobs: waiting out a bad connection:")
    net = ProviderError(NETWORK)
    table = {NETWORK: True, "stream from https://x.example/v1 broke off: reset": True,
             "HTTP 429 from https://api.example.com/v1: slow down": True,
             "HTTP 500 from api.example.com: oops": True, "HTTP 503 from api.example.com: oops": True,
             "HTTP 529 from https://api.example.com/v1/messages:\noverloaded": True,
             "HTTP 401 from api.example.com: no": False, "HTTP 403 from api.example.com: no": False,
             "HTTP 429 from api.example.com: insufficient_quota": False,
             "HTTP 402 from api.example.com: pay": False, "HTTP 400 from api.example.com: bad": False,
             "something else": False}
    check("only what passes by itself is worth waiting for",
          all((E.explain(text)[0] in E.WORTH_WAITING) is want for text, want in table.items()))

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
        wd = Path(td)
        script = Script(net, net, net, say("All done."))
        a, clock, waits = _agent(script, wd)
        answer = a.send("go")
        check("a job carries on after the connection comes back", answer == "All done." and script.calls == 4)
        check("each wait is twice as long: 5, 10, 20 seconds", clock.now == 35.0)
        check("it says why it waits, and when it is back", waits == ["network", "network", "network", ""])
        check("a failed call leaves nothing in the conversation",
              [m["role"] for m in a.messages] == ["user", "assistant"] and a.messages[1]["text"] == "All done.")

        script = Script(*[net] * 9, say("Done."))
        a, clock, _ = _agent(script, wd)
        a.send("go")
        check("the waits stop growing at 5 minutes", clock.now == 5 + 10 + 20 + 40 + 80 + 160 + 300 * 3)

        script = Script(net, say("Fine."), net, say("Fine again."))
        a, clock, _ = _agent(script, wd, patience=6.0)
        check("patience is per outage: a good call starts it again",
              a.send("one") == "Fine." and a.send("two") == "Fine again." and script.calls == 4)

        script = Script(net)
        a, _, waits = _agent(script, wd, patience=0.0)
        check("a spoken turn doesn't wait", _raises(lambda: a.send("go"), ProviderError) and script.calls == 1 and waits == [])

        script = Script(fn=lambda n, m: net)
        a, clock, _ = _agent(script, wd, patience=30.0)
        check("an outage that doesn't end stops at the limit, as the error it was",
              _raises(lambda: a.send("go"), ProviderError) and script.calls == 4 and clock.now == 35.0)

        for text in ("HTTP 401 from api.example.com: no", "HTTP 429 from api.example.com: insufficient_quota"):
            script = Script(ProviderError(text))
            a, clock, waits = _agent(script, wd)
            check(f"no waiting for: {text[:24]}", _raises(lambda: a.send("go"), ProviderError) and script.calls == 1 and clock.now == 0)

        script = Script(net, ProviderError("HTTP 401 from api.example.com: no"))
        a, _, _ = _agent(script, wd)
        check("a wait that turns into a refused key ends at once", _raises(lambda: a.send("go"), ProviderError) and script.calls == 2)

        stopped = [False]
        script = Script(fn=lambda n, m: net)
        a, clock, _ = _agent(script, wd, cancelled=lambda: stopped[0])
        real_sleep = clock.sleep

        def stop_during_wait(seconds):
            real_sleep(seconds)
            stopped[0] = True

        a.wait_sleep = stop_during_wait
        check("stopping the job ends the wait within a quarter second",
              a.send("go") == A.CANCELLED and script.calls == 1 and clock.now == 0.25)

        ran = []
        script = Script(call("list_dir", {"path": "."}, "c1"), net, net, say("Listed."))
        a, _, _ = _agent(script, wd, on_tool=lambda name, inp: ran.append(name))
        check("a tool that already ran is not run again by the wait",
              a.send("go") == "Listed." and ran == ["list_dir"] and script.calls == 4)

        script = Script(call("list_dir", {"path": "."}, "c1"), net, say("The report."))
        a, _, _ = _agent(script, wd)
        a.max_steps, a.wrap_at_limit = 1, True
        check("the last report waits as well", "The report." in a.send("go"))

        a, _, _ = _agent(Script(say("x")), wd)
        from benji.agent import Agent
        fresh = Agent(Script(say("x")), "sys", wd, approve=lambda reason: True)
        check("by default an agent doesn't wait, and its clock pauses while the Mac sleeps",
              fresh.patience == 0 and fresh.wait_clock is time.monotonic)


def provider_checks(check) -> None:
    from benji import errors as E
    from benji import providers as P

    print("durable jobs: a connection that dies after it was made:")
    url = "https://api.example.com/v1/messages"
    secret = "SECRET-from-the-socket"
    real = urllib.request.urlopen
    try:
        for label, exc in (("reset", ConnectionResetError(secret)), ("timeout", TimeoutError(secret)),
                           ("server hung up", http.client.RemoteDisconnected(secret)),
                           ("cut short", http.client.IncompleteRead(b"x"))):
            def boom(*a, **k):
                raise exc

            urllib.request.urlopen = boom
            for retry in (False, True):
                try:
                    P._post(url, {}, {"a": 1}, retry=retry)
                    message = ""
                except P.ProviderError as e:
                    message = str(e)
                check(f"{label}, retry={retry}: a network error, with nothing from the socket",
                      E.explain(message)[0] == "network" and secret not in message)

        def http_503(*a, **k):
            raise urllib.error.HTTPError(url, 503, "busy", {}, None)

        urllib.request.urlopen = http_503
        try:
            P._post(url, {}, {"a": 1})
            message = ""
        except P.ProviderError as e:
            message = str(e)
        check("an HTTP error is still told apart from a dropped connection", E.explain(message)[0] == "provider")
    finally:
        urllib.request.urlopen = real


def server_checks(check) -> None:
    from benji import audit
    from benji import jobs as J
    from benji.providers import ProviderError

    print("durable jobs: the job row while it waits (through the serve process):")
    net = ProviderError(NETWORK)
    saved = J.WAIT_FIRST, J.WAIT_LIMIT
    J.WAIT_FIRST = 0.01
    t0 = 1_700_000_000.0
    try:
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
            wd = Path(td)
            log = wd / "events.jsonl"
            audit.configure(log)
            start = call("start_job", {"title": "Prices", "brief": "Find prices."}, "s1")
            job = Script(net, net, final(["A"], "Found one."))
            srv, ev, store, made = harness(Script(start, say("Started.")), job, wd, [t0])
            srv.handle({"type": "send", "id": "t1", "text": "find prices in the background", "jobs": True})
            done = ev.wait(jstate("done"))
            lines = [e["job"]["line"] for e in ev.items if e.get("type") == "job"]
            check("a job that loses its connection finishes", done is not None and job.calls == 3)
            check("the row says it is waiting, in plain words", "Waiting for a connection" in lines)
            check("it never showed as failed",
                  not [e for e in ev.items if e.get("type") == "job" and e["job"]["state"] == "failed"])
            check("a job gets the long patience", made[-1].patience == J.WAIT_LIMIT)
            events = [json.loads(line) for line in log.read_text().splitlines()]
            waits = [(e["state"], e["reason"]) for e in events if e["kind"] == "job_wait"]
            check("the audit log has one wait and one return, with kinds only",
                  waits == [("waiting", "network"), ("back", "network")])
            check("the host it couldn't reach is not in the audit log", "api.example.com" not in log.read_text())

        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
            wd = Path(td)
            audit.configure(wd / "events.jsonl")
            J.WAIT_FIRST = 60.0
            start = call("start_job", {"title": "Prices", "brief": "Find prices."}, "s1")
            job = Script(fn=lambda n, m: net)
            srv, ev, store, made = harness(Script(start, say("Started.")), job, wd, [t0])
            srv.handle({"type": "send", "id": "t1", "text": "find prices in the background", "jobs": True})
            waiting = ev.wait(lambda e: e.get("type") == "job" and e["job"]["line"] == "Waiting for a connection")
            check("while waiting the job is working, not failed", waiting is not None and waiting["job"]["state"] == "working")
            before = time.monotonic()
            srv.handle({"type": "job_stop", "job": waiting["job"]["id"]})
            stopped = ev.wait(jstate("stopped"))
            check("Stop works during the wait, at once", stopped is not None and time.monotonic() - before < 5)

        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
            wd = Path(td)
            audit.configure(wd / "events.jsonl")
            J.WAIT_FIRST, J.WAIT_LIMIT = 0.01, 0.03
            start = call("start_job", {"title": "Prices", "brief": "Find prices."}, "s1")
            job = Script(fn=lambda n, m: net)
            srv, ev, store, made = harness(Script(start, say("Started.")), job, wd, [t0])
            srv.handle({"type": "send", "id": "t1", "text": "find prices in the background", "jobs": True})
            failed = ev.wait(jstate("failed"))
            check("past its patience the job stops plainly and can be continued",
                  failed is not None and failed["job"]["can_continue"] is True and "couldn't reach" in failed["job"]["error"].lower()
                  and "NETWORK" not in failed["job"]["error"])

        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
            wd = Path(td)
            audit.configure(wd / "events.jsonl")
            J.WAIT_FIRST, J.WAIT_LIMIT = saved
            clock = [t0]
            start = call("start_job", {"title": "Tea", "brief": "Watch tea.", "repeat": REPEAT_DAILY}, "s1")
            job = Script(final(["A"], "One."), final(["A", "B"], "Two."))
            srv, ev, store, made = harness(Script(start, say("Started.")), job, wd, clock)
            srv.handle({"type": "schedules_set", "enabled": True})
            srv.handle({"type": "send", "id": "t1", "text": "watch tea every day", "jobs": True, "schedules": True})
            card = ev.wait(lambda e: e.get("type") == "approval")
            srv.handle({"type": "approve", "id": "t1", "request": card["request"], "decision": "yes"})
            ev.wait(jstate("done"))
            clock[0] = t0 + 2 * 86400
            mark = ev.mark()
            srv.schedule_tick_once()
            second = ev.wait(jstate("done"), after=mark)
            check("a run nobody is watching gives up sooner, because it holds the one slot",
                  second is not None and second["job"]["unattended"] is True and made[-1].patience == J.WAIT_LIMIT_UNATTENDED)
    finally:
        J.WAIT_FIRST, J.WAIT_LIMIT = saved
        audit.configure(None)


def _marks(value) -> int:
    return json.dumps(value).count("cache_control")


def _unmarked(value):
    if isinstance(value, dict):
        return {k: _unmarked(v) for k, v in value.items() if k != "cache_control"}
    if isinstance(value, list):
        return [_unmarked(v) for v in value]
    return value


def cache_checks(check) -> None:
    from benji import providers as P
    from benji.prompts import SystemPrompt

    print("durable jobs: a tool loop reads its own earlier steps from cache:")
    eph = {"type": "ephemeral"}
    tools = [{"name": "t", "description": "d", "parameters": {"type": "object", "properties": {}}}]
    system = SystemPrompt("base rules", "\nturn rules")
    provider = P.AnthropicProvider("not-a-real-key", "claude-haiku-5-5")
    saved = os.environ.pop("BENJI_PROMPT_CACHE", None)

    def step(n):
        return [{"role": "assistant", "text": "", "tool_calls": [{"id": f"c{n}", "name": "t", "input": {}}]},
                {"role": "tool", "id": f"c{n}", "name": "t", "content": f"result {n}"}]

    try:
        job = [{"role": "user", "text": "the brief"}]
        check("a job's first call has no conversation mark: there is nothing to read back yet",
              _marks(provider._payload(system, job, tools)["messages"]) == 0)
        one = job + step(1)
        body = provider._payload(system, one, tools)
        check("after a step, the newest tool result is marked, and nothing else in the conversation",
              body["messages"][-1]["content"][-1].get("cache_control") == eph and _marks(body["messages"]) == 1)
        three = one + step(2) + step(3)
        later = provider._payload(system, three, tools)
        check("the mark moves forward with the steps; older steps carry none",
              later["messages"][-1]["content"][-1].get("cache_control") == eph and _marks(later["messages"]) == 1)
        check("what an earlier call sent is exactly the start of what a later call sends, so it can be read back",
              _unmarked(later["messages"])[:len(body["messages"])] == _unmarked(body["messages"]))

        two_results = job + [{"role": "assistant", "text": "", "tool_calls": [{"id": "a", "name": "t", "input": {}}, {"id": "b", "name": "t", "input": {}}]},
                             {"role": "tool", "id": "a", "name": "t", "content": "A"}, {"role": "tool", "id": "b", "name": "t", "content": "B"}]
        wire = provider._payload(system, two_results, tools)["messages"][-1]["content"]
        check("two results in one step: only the last is marked", "cache_control" not in wire[0] and wire[1].get("cache_control") == eph)

        chat = [{"role": "user", "text": "earlier"}, {"role": "assistant", "text": "answer", "tool_calls": []},
                {"role": "user", "text": "now"}] + step(1)
        body = provider._payload(system, chat, tools)
        check("a spoken turn with steps keeps its mark on the earlier conversation and gains one on the step, four at most",
              body["messages"][1]["content"][-1].get("cache_control") == eph
              and body["messages"][-1]["content"][-1].get("cache_control") == eph
              and _marks(body["messages"]) == 2 and _marks(body) == 4)
        body = provider._payload(system, chat[:3], tools)
        check("the live user message is still never marked", "cache_control" not in json.dumps(body["messages"][-1]))

        shot = job + [step(1)[0], {**step(1)[1], "images": [{"media_type": "image/png", "data": "AAAA"}]}]
        check("a step carrying a screenshot is not marked: the next picture replaces it",
              _marks(provider._payload(system, shot, tools)["messages"]) == 0)

        os.environ["BENJI_PROMPT_CACHE"] = "0"
        check("BENJI_PROMPT_CACHE=0 still sends no marks at all", _marks(provider._payload(system, three, tools)) == 0)
    finally:
        os.environ.pop("BENJI_PROMPT_CACHE", None)
        if saved is not None:
            os.environ["BENJI_PROMPT_CACHE"] = saved


def warned_job_checks(check) -> None:
    from benji import audit
    from benji import jobs as J
    from benji.agent import JOB_MAX_STEPS

    print("durable jobs: a job that wraps up when warned is not shown as done:")
    warn_at = JOB_MAX_STEPS - J.LIMIT_WARN_LEFT
    t0 = 1_700_000_000.0

    def run_job(steps, *after):
        td = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        wd = Path(td.name)
        audit.configure(wd / "events.jsonl")
        start = call("start_job", {"title": "Long", "brief": "Do all thirty."}, "s1")
        replies = [call("list_dir", {"path": "."}, f"c{n}") for n in range(steps)] + list(after)
        job = Script(*replies)
        srv, ev, store, made = harness(Script(start, say("Started.")), job, wd, [t0])
        srv.handle({"type": "send", "id": "t1", "text": "do all thirty in the background", "jobs": True})
        return td, srv, ev, store, job

    report = final(["a"], "Nineteen of thirty done.")
    td, srv, ev, store, job = run_job(warn_at, report)
    stopped = ev.wait(jstate("stopped"))
    check("told its steps are nearly out, it wraps up: the row says stopped at the limit, not done",
          stopped is not None and stopped["job"]["stopped_at_limit"] is True and stopped["job"]["state"] == "stopped")
    check("it can be continued", stopped is not None and stopped["job"]["can_continue"] is True)
    check("the row says how many of the steps it used, and not that it used them all",
          stopped is not None and f"{warn_at} of its {JOB_MAX_STEPS} steps" in stopped["job"]["written"]
          and f"used all {JOB_MAX_STEPS}" not in store.report_path(stopped["job"]["id"]).read_text())
    check("the job's own report is kept", stopped is not None and "Nineteen of thirty done." in store.report_path(stopped["job"]["id"]).read_text())
    check("the record says why, for code to read", stopped is not None and store.load(stopped["job"]["id"])["stop_reason"] == "limit")
    if stopped is not None:
        job.replies.append(final(["b"], "All thirty done."))
        mark = ev.mark()
        srv.handle({"type": "job_continue", "job": stopped["job"]["id"]})
        done = ev.wait(jstate("done"), after=mark)
        check("Continue runs it again, and a run that isn't warned ends as done",
              done is not None and done["job"]["run"] == 2 and done["job"]["stopped_at_limit"] is False)
    td.cleanup()

    td, srv, ev, store, job = run_job(warn_at - 1, final(["a"], "All done early."))
    done = ev.wait(jstate("done"))
    check("a job that finishes before the warning is simply done",
          done is not None and done["job"]["stopped_at_limit"] is False and done["job"]["can_continue"] is False)
    td.cleanup()

    td, srv, ev, store, job = run_job(JOB_MAX_STEPS, say("Out of steps, here is where I got to."))
    stopped = ev.wait(jstate("stopped"))
    check("a job that uses every step still says it used them all",
          stopped is not None and stopped["job"]["stopped_at_limit"] is True
          and f"used all {JOB_MAX_STEPS}" in store.report_path(stopped["job"]["id"]).read_text())
    td.cleanup()
    audit.configure(None)
