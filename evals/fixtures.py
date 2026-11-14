"""Fixtures: one recorded turn per JSON file, under evals/fixtures/<kind>/ (shared, in git) or
evals/fixtures/private/ (the user's own turns, never in git or the public export).

A fixture holds what was asked, what one model answered, what a person expects of the answer, the code
checks' verdict when it was stored (the baseline, so a parser or check change shows up as drift) and,
optionally, a person's answers to the rubric questions (to measure the judge).

    {"schema": 1, "id": "card/compare", "kind": "card", "case": "compare",
     "request": {"text": "...", "screen": "document" | null, "spoken": false},
     "expect":  {"card": true, "layout": "compare"},
     "reply":   {"model": "claude-haiku-5-5", "effort": "low", "recorded": "2026-11-01",
                 "source": "docs/impl-notes/...", "raw": "...", "events": [...], "usage": {...}},
     "baseline": {"pass": true, "why": []},
     "human":   null | {"by": "user", "date": "2026-11-08", "answers": {"<question id>": true}}}
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
PRIVATE = FIXTURES / "private"
RUNS = ROOT / "runs"

SCHEMA = 1
KINDS = ("figure", "card", "beats")
SCREENS = (None, "document", "desktop")   # the behaviour eval's synthetic screens; never a real capture


class FixtureError(ValueError):
    pass


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def validate(fx: dict) -> dict:
    """The fixture, or FixtureError naming the first thing wrong with it."""
    def need(cond, what):
        if not cond:
            raise FixtureError(f"{fx.get('id', '?')}: {what}")

    need(isinstance(fx, dict), "not an object")
    need(fx.get("schema") == SCHEMA, f"schema {fx.get('schema')!r}, expected {SCHEMA}")
    need(isinstance(fx.get("id"), str) and fx["id"], "no id")
    need(fx.get("kind") in KINDS, f"kind {fx.get('kind')!r} is not one of {KINDS}")
    need(isinstance(fx.get("case"), str) and fx["case"], "no case")
    req = fx.get("request")
    need(isinstance(req, dict) and isinstance(req.get("text"), str) and req["text"].strip(), "no request text")
    need(req.get("screen") in SCREENS, f"screen {req.get('screen')!r} is not one of {SCREENS}")
    need(isinstance(req.get("spoken", False), bool), "spoken is not true or false")
    need(isinstance(fx.get("expect", {}), dict), "expect is not an object")
    reply = fx.get("reply")
    need(isinstance(reply, dict), "no reply")
    need(isinstance(reply.get("model"), str) and reply["model"], "reply has no model")
    if fx["kind"] == "beats":
        need(isinstance(reply.get("events"), list), "a beats fixture needs the turn's events")
    else:
        need(isinstance(reply.get("raw"), str), "reply has no raw text")
    base = fx.get("baseline")
    need(base is None or (isinstance(base, dict) and isinstance(base.get("pass"), bool)
                          and isinstance(base.get("why"), list)), "baseline is not {pass, why}")
    human = fx.get("human")
    need(human is None or (isinstance(human, dict) and isinstance(human.get("answers"), dict)
                           and all(isinstance(v, bool) for v in human["answers"].values())),
         "human labels are not {answers: {question: true/false}}")
    return fx


def load(path: Path) -> dict:
    try:
        fx = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        raise FixtureError(f"{path.name}: not JSON ({e})") from None
    fx = validate(fx)
    fx["_path"] = str(path)
    return fx


def save(fx: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    clean = {k: v for k, v in fx.items() if not k.startswith("_")}
    validate(clean)
    path.write_text(json.dumps(clean, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def load_dir(folder: Path, *, private: bool = False) -> list[dict]:
    """Every fixture under a folder, sorted by id. The private folder only when asked for."""
    out = []
    for p in sorted(folder.rglob("*.json")):
        if not private and PRIVATE in p.parents:
            continue
        out.append(load(p))
    ids = [f["id"] for f in out]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        raise FixtureError(f"duplicate fixture ids: {dupes}")
    return sorted(out, key=lambda f: f["id"])


def select(fxs: list[dict], *, kind: str | None = None, model: str | None = None, only: str | None = None) -> list[dict]:
    return [f for f in fxs
            if (kind is None or f["kind"] == kind)
            and (model is None or f["reply"]["model"] == model)
            and (only is None or only.lower() in f["id"].lower())]
