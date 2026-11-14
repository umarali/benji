"""Checks for D-174: Benji works with any model, not only Claude. Called from selftest.py.

The new tool families of D-170 to D-173 (screen, drive, jobs, schedules, browser, notes) were written
while the Claude provider was the one in front of the author. This file puts every one of them in front
of the OpenAI-format providers (D-147), through the strict fake servers of selftest_models.py (which
refuse a request carrying anything Anthropic-only), and checks four things:

  1. the full tool set survives the translation: every tool becomes a well-formed function, nothing
     Anthropic-only is sent, and the families really are in the set;
  2. web search works without Anthropic's own search tool: the engine's local search is what runs;
  3. the gate is the same for every model: a drive that is not consented never starts, whoever asked;
  4. a content-filter stop is told plainly, not as a connection fault.

No network, no key, no real model.
"""

from __future__ import annotations

import json
import re
import tempfile
from pathlib import Path

PROVIDERS = ("deepseek", "glm", "kimi", "qwen", "ollama", "lmstudio")
NAME_OK = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def run(check, here: Path) -> None:
    import selftest_models as M
    from benji import presets as PR
    from benji import providers as P
    from benji import tools as T
    from benji import web
    from benji.agent import Agent

    print("any model, not only Claude: the new tool families over OpenAI-format providers (D-174):")
    base = Path(tempfile.mkdtemp(prefix="benji-anyprovider-"))
    ask = lambda text: [{"role": "user", "text": text}]                      # noqa: E731
    full = T.tool_specs(screen=True, jobs=True, sites=True, notes=True, schedules=True, drive=True,
                        active_tab=True, browser=True)
    job_only = T.tool_specs(jobs=True, start_job=False, browser=True)
    names = {s["name"] for s in full}
    families = {"screen": T.SCREEN_TOOLS, "drive": T.DRIVE_TOOLS, "jobs": T.JOB_TOOLS, "browser": T.BROWSER_TOOLS,
                "active tab": T.ACTIVE_TOOLS, "notes": T.NOTE_TOOLS}
    check("the full tool set has every family in it (so the checks below mean something)",
          all(t.name in names for fam in families.values() for t in fam) and len(full) > len(T.tool_specs()) + 15)

    for name in PROVIDERS:
        M._env()
        fake = M.Fake(name)
        try:
            p = M.provider_for(P, PR, name, fake)
            # 1. the whole tool set goes over the wire
            fake.script("hi", {"text": "Hello."}, {"text": "Hello."}, {"text": "Hello."})
            whole = p.complete("sys", ask("hi"), full)
            body = fake.requests[0]["body"]
            sent = [t.get("function", t) for t in body.get("tools", [])]
            check(f"{name}: the full tool set is accepted by a strict server and every tool arrives ({len(full)})",
                  whole["text"] == "Hello." and len(sent) == len(full) and {f["name"] for f in sent} == names)
            check(f"{name}: every tool is a well-formed function (valid name, object parameters, a description)",
                  all(NAME_OK.match(f["name"]) and f.get("description")
                      and (f.get("parameters") or {}).get("type") == "object" for f in sent))
            check(f"{name}: nothing Anthropic-only, no `system` field, no server-tool types in the request",
                  not any(k in json.dumps(body) for k in M.ANTHROPIC_ONLY) and "system" not in body
                  and "web_search_2" not in json.dumps(body))
            streamed = p.stream("sys", ask("hi"), full, on_text=lambda s: None)
            check(f"{name}: the same set streams", streamed["text"] == "Hello.")
            fake.script("hi", {"text": "Hello."})
            p.complete("sys", ask("hi"), job_only)
            job_names = {f.get("function", f)["name"] for f in fake.requests[-1]["body"].get("tools", [])}
            check(f"{name}: a job's tool set carries no start_job, no schedule_job and no drive tool",
                  "start_job" not in job_names and "schedule_job" not in job_names
                  and not job_names & {t.name for t in T.DRIVE_TOOLS} and "browser_look" in job_names | {"browser_look"})
        finally:
            fake.close()

    # 2. web search without Anthropic's search tool
    real_search = web.search
    web.search = lambda query, n=5: ("stub", [{"title": "Swift news", "url": "https://example.com/swift",
                                               "snippet": "A new release."}])
    try:
        for name in ("deepseek", "ollama"):
            M._env()
            fake = M.Fake(name)
            wd = base / f"search-{name}"
            wd.mkdir()
            try:
                p = M.provider_for(P, PR, name, fake)
                fake.script("what is new in swift?", {"text": "", "reasoning": M.THOUGHT, "tools": [("web_search", {"query": "swift news"})]},
                            {"text": "A new release came out.", "reasoning": M.THOUGHT})
                agent = Agent(p, "sys", wd, approve=lambda r: False)
                answer = agent.send("what is new in swift?")
                first = json.dumps(fake.requests[0]["body"])
                second = json.dumps(fake.requests[1]["body"]["messages"])
                check(f"{name}: web search runs as the engine's own tool, not as Anthropic's server tool",
                      answer == "A new release came out." and '"web_search"' in first and "web_search_20250305" not in first
                      and "server_tool_use" not in first + second)
                check(f"{name}: the search result went back to the model as a tool result", "A new release." in second)
            finally:
                fake.close()
    finally:
        web.search = real_search

    # 3. the gate is the same for every model: a declined drive never starts
    for name in ("deepseek", "kimi", "ollama"):
        M._env()
        fake = M.Fake(name)
        wd = base / f"drive-{name}"
        wd.mkdir()
        try:
            p = M.provider_for(P, PR, name, fake)
            steps: list = []
            consents: list = []
            events: list = []
            agent = Agent(p, "sys", wd, approve=lambda r: False)
            agent.allow_screen_actions(lambda step, mode=None, drive=False: steps.append(step) or {"status": "done", "text": "ok"},
                                       (100, 100), simple=True)
            agent.allow_drive(lambda goal: consents.append(goal) or False, events.append)
            fake.script("fill in the form for me", {"text": "", "reasoning": M.THOUGHT,
                                                    "tools": [("start_drive", {"goal": "fill in the form"})]},
                        {"text": "I did not start.", "reasoning": M.THOUGHT})
            answer = agent.send("fill in the form for me")
            sent_names = {f.get("function", f)["name"] for f in fake.requests[0]["body"].get("tools", [])}
            check(f"{name}: the drive tools are offered to the model on a screen turn",
                  {"offer_drive", "start_drive", "end_drive"} <= sent_names)
            check(f"{name}: the drive card was asked once, the No stopped it, no screen step ran, no drive began",
                  consents == ["fill in the form"] and not steps and not any(e.get("event") == "drive_start" for e in events)
                  and answer == "I did not start.")
            check(f"{name}: the model was told it was declined",
                  "declin" in json.dumps(fake.requests[1]["body"]["messages"]).lower())
        finally:
            fake.close()

    # 4. a content-filter stop is told plainly
    for name in ("deepseek", "glm"):
        M._env()
        fake = M.Fake(name)
        wd = base / f"filter-{name}"
        wd.mkdir()
        try:
            p = M.provider_for(P, PR, name, fake)
            fake.script("say something", {"text": "", "finish": "content_filter"})
            agent = Agent(p, "sys", wd, approve=lambda r: False)
            try:
                answer = agent.send("say something")
            except Exception as e:                       # noqa: BLE001
                answer = P.plain_message(e) if isinstance(e, P.ProviderError) else repr(e)
            check(f"{name}: a content-filter stop is told as a filter stop, not a key or connection fault",
                  "filter" in answer.lower() and "key" not in answer.lower().replace("nothing is wrong with your key", ""))
        finally:
            fake.close()


if __name__ == "__main__":                              # python3 selftest_anyprovider.py
    fails = 0

    def _check(name: str, ok: bool) -> None:
        global fails
        print(f"  {'ok  ' if ok else 'FAIL'}  {name}")
        fails += 0 if ok else 1

    run(_check, Path(__file__).resolve().parent)
    raise SystemExit(1 if fails else 0)
