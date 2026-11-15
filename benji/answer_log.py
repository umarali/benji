"""The answer log: one JSON line per `--serve` turn in the working folder's
`answers.jsonl`, for diagnosing a turn afterwards. Each record holds the model's raw answer (tags and
card lines included), the events the app was sent for that turn (consecutive deltas joined), what
the app said about the screen it drew on, and the turn id. Never the screenshot or its path, never
a key: only text the model wrote and the engine's own events. Off with BENJI_ANSWER_LOG=0.
Rotated to `answers.jsonl.1` past MAX_BYTES. Both files are mode 0600 (a file left with wider
permissions is tightened on the first write): the raw answers are the user's. Turns of background jobs are not
here (their metadata is in events.jsonl, benji/audit.py)."""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

from . import private_file
from .switches import switch

FILE_NAME = "answers.jsonl"
MAX_BYTES = 2_000_000


def enabled() -> bool:
    return switch("BENJI_ANSWER_LOG", True)


def compact(events: list[dict]) -> list[dict]:
    """The turn's events with each run of deltas joined into one."""
    out: list[dict] = []
    for e in events:
        if e.get("type") == "delta" and out and out[-1].get("type") == "delta":
            out[-1] = {**out[-1], "text": out[-1].get("text", "") + e.get("text", "")}
        else:
            out.append(dict(e))
    return out


def record(path: Path | None, *, run: str, raw: str | None, events: list[dict], screen: dict | None,
           canvas: dict | None, spoken: bool, model: str = "", status: str = "ok") -> None:
    """Append one turn. A failure to write is reported on stderr and never stops the turn."""
    if path is None:
        return
    entry = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "run": run, "status": status, "model": model,
             "spoken": spoken, "screen": screen, "canvas": canvas, "raw": raw, "events": compact(events)}
    try:
        private_file.append(path, json.dumps(entry, ensure_ascii=False) + "\n", max_bytes=MAX_BYTES, keep=1)
    except OSError as e:
        print(f"[Benji] answer log: {type(e).__name__}", file=sys.stderr)     # the kind, not the path


def read(path: Path) -> list[dict]:
    """Every record in the log, oldest first (lines that don't parse are skipped)."""
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out
