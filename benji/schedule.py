"""Schedules inside a job: a job the user told to repeat runs again,
as the SAME job (a new run, the same folder, the report history kept).

What this module is: the rules, in plain functions with the clock passed in, so every one can be
tested with a fake clock. It decides nothing from model text. The model may *propose* a repeat
(a small structured object, `clean_repeat`); the user answers a card; only then does a schedule
exist, in `<job folder>/schedule.json`.

What a schedule is not: there is no server-side scheduler, no keep-awake assertion and no helper
that runs while Benji is closed. A schedule is checked by `benji --serve` every half minute while
the app is open. A run missed because the Mac slept or Benji was closed is caught up ONCE when the
engine next looks (`after_run` plans the next run from now, never from the missed slot, so a
night of sleep is one run, not a burst). A clock that jumps back cannot park a schedule far in the
future (`clamp`). Three failed runs in a row pause the schedule (`MAX_FAILURES`).

The schedule file (`jobs/<id>.schedule.json`, outside the job's own folder) is written whole to a
temporary file and renamed. If it can't be read or its values are out of range, `load` moves it aside
as `.bad`, reports a plain problem and the job has no schedule; it never guesses.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timedelta, tzinfo
from pathlib import Path

VERSION = 1
FILE = "schedule.json"       # the name ends a job id: jobs/<id>.schedule.json
MAX_FAILURES = 3                  # failed runs in a row that pause the schedule
MIN_MINUTES = 30                  # no unattended run more often than this
MAX_MINUTES = 7 * 24 * 60
PAUSED_BY = ("", "user", "failures")
_DAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
_UNITS = {"minute": 1, "minutes": 1, "min": 1, "mins": 1, "hour": 60, "hours": 60, "hr": 60, "hrs": 60}


# ---- the spec: what repeats --------------------------------------------------------------------

def _clock(raw: object) -> str | None:
    """'HH:MM' (24 hour) or None."""
    if not isinstance(raw, str):
        return None
    parts = raw.strip().split(":")
    if len(parts) != 2 or not all(p.isdigit() and len(p) in (1, 2) for p in parts):
        return None
    h, m = int(parts[0]), int(parts[1])
    return f"{h:02d}:{m:02d}" if 0 <= h <= 23 and 0 <= m <= 59 else None


def clean_spec(raw: object) -> dict | None:
    """The stored form of a spec, or None when it isn't one. Strict: unknown keys are dropped, a
    wrong type or an out-of-range number is None (never repaired by guessing)."""
    if not isinstance(raw, dict):
        return None
    kind = raw.get("kind")
    if kind == "interval":
        minutes = raw.get("minutes")
        if isinstance(minutes, int) and not isinstance(minutes, bool) and MIN_MINUTES <= minutes <= MAX_MINUTES:
            return {"kind": "interval", "minutes": minutes}
        return None
    at = _clock(raw.get("at"))
    if at is None:
        return None
    if kind == "daily":
        return {"kind": "daily", "at": at}
    day = raw.get("day")
    if kind == "weekly" and isinstance(day, int) and not isinstance(day, bool) and 0 <= day <= 6:
        return {"kind": "weekly", "day": day, "at": at}
    return None


def clean_repeat(raw: object) -> tuple[dict | None, str]:
    """(spec, problem) for what the model proposed in `repeat`:
    {"every": "day", "at": "09:00"}, {"every": "week", "day": "monday", "at": "09:00"},
    {"every": "hours" | "minutes", "count": 6}. A plain reason for the model when it won't do."""
    if not isinstance(raw, dict):
        return None, "repeat must be an object like {\"every\": \"day\", \"at\": \"09:00\"}"
    every = str(raw.get("every") or "").strip().lower()
    if every in _UNITS:
        count = raw.get("count")
        if not isinstance(count, int) or isinstance(count, bool) or count < 1:
            return None, "repeat needs a whole number `count` of minutes or hours"
        minutes = count * _UNITS[every]
        if minutes < MIN_MINUTES:
            return None, f"a repeat can't be more often than every {MIN_MINUTES} minutes"
        if minutes > MAX_MINUTES:
            return None, "a repeat can't be less often than weekly"
        return {"kind": "interval", "minutes": minutes}, ""
    if every in ("day", "daily"):
        spec = clean_spec({"kind": "daily", "at": raw.get("at", "09:00")})
        return (spec, "") if spec else (None, "`at` must be a 24-hour time such as 09:00")
    if every in ("week", "weekly"):
        day = str(raw.get("day") or "").strip().lower()
        index = next((i for i, d in enumerate(_DAYS) if d == day or d[:3] == day), None)
        if index is None:
            return None, "a weekly repeat needs a `day` such as monday"
        spec = clean_spec({"kind": "weekly", "day": index, "at": raw.get("at", "09:00")})
        return (spec, "") if spec else (None, "`at` must be a 24-hour time such as 09:00")
    return None, "`every` must be minutes, hours, day or week"


def describe(spec: dict) -> str:
    """The schedule in plain words, for the card and the row."""
    if spec["kind"] == "interval":
        m = spec["minutes"]
        if m % 60 == 0:
            h = m // 60
            return "Every hour" if h == 1 else f"Every {h} hours"
        return f"Every {m} minutes"
    if spec["kind"] == "daily":
        return f"Every day at {spec['at']}"
    return f"Every {_DAYS[spec['day']].capitalize()} at {spec['at']}"


def next_after(spec: dict, after: float, tz: tzinfo | None = None) -> float:
    """The first run time strictly after `after` (epoch seconds). `tz` None: the Mac's local time."""
    if spec["kind"] == "interval":
        return after + spec["minutes"] * 60
    when = datetime.fromtimestamp(after, tz)
    hour, minute = (int(x) for x in spec["at"].split(":"))
    candidate = when.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if spec["kind"] == "weekly":
        candidate += timedelta(days=(spec["day"] - candidate.weekday()) % 7)
    step = timedelta(days=1 if spec["kind"] == "daily" else 7)
    while candidate.timestamp() <= after:
        candidate += step
    return candidate.timestamp()


# ---- the state: when it runs next --------------------------------------------------------------

def new_state(spec: dict, now: float, tz: tzinfo | None = None) -> dict:
    return {"version": VERSION, "spec": spec, "paused": False, "paused_by": "", "next_at": next_after(spec, now, tz),
            "last_run_at": None, "failures": 0, "created_at": now, "runs": 0}


def clean_state(raw: object) -> dict | None:
    """A loaded state if every value is of its kind, else None."""
    if not isinstance(raw, dict) or raw.get("version") != VERSION:
        return None
    spec = clean_spec(raw.get("spec"))
    num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) < 4e9  # noqa: E731
    if spec is None or not num(raw.get("next_at")) or not isinstance(raw.get("paused"), bool):
        return None
    if raw.get("paused_by", "") not in PAUSED_BY:
        return None
    last = raw.get("last_run_at")
    failures, runs = raw.get("failures", 0), raw.get("runs", 0)
    if (last is not None and not num(last)) or not num(raw.get("created_at", 0)):
        return None
    for count in (failures, runs):
        if not isinstance(count, int) or isinstance(count, bool) or not 0 <= count <= 100_000_000:
            return None
    return {"version": VERSION, "spec": spec, "paused": raw["paused"], "paused_by": raw.get("paused_by", ""),
            "next_at": float(raw["next_at"]), "last_run_at": None if last is None else float(last),
            "failures": failures, "created_at": float(raw.get("created_at", 0)), "runs": runs}


def clamp(state: dict, now: float, tz: tzinfo | None = None) -> bool:
    """If the clock went back, a next run set from the later clock can lie further away than any
    legitimate one: bring it in. True when it changed."""
    soonest = next_after(state["spec"], now, tz)
    if state["next_at"] > soonest:
        state["next_at"] = soonest
        return True
    return False


def is_due(state: dict, now: float) -> bool:
    return not state["paused"] and now >= state["next_at"]


def after_run(state: dict, now: float, ok: bool, tz: tzinfo | None = None) -> bool:
    """Record a finished run and plan the next from NOW (a missed slot is caught up once, never
    repeated). A failed run counts against the schedule; the third in a row pauses it. A run that
    wasn't a failure of the job (a stop, the switch turned off) is passed as ok=True by the caller
    only when it should clear the count; otherwise use `skip_run`. Returns True when this run paused it."""
    state["last_run_at"] = now
    state["runs"] += 1
    state["next_at"] = next_after(state["spec"], now, tz)
    if ok:
        state["failures"] = 0
        return False
    state["failures"] += 1
    if state["failures"] >= MAX_FAILURES and not state["paused"]:
        state["paused"], state["paused_by"] = True, "failures"
        return True
    return False


def skip_run(state: dict, now: float, tz: tzinfo | None = None) -> None:
    """A run that was started and then stopped by the user, or cut short by the switch: neither a
    success nor a failure. Plan the next from now; leave the failure count alone."""
    state["last_run_at"] = now
    state["next_at"] = next_after(state["spec"], now, tz)


def pause(state: dict, by: str = "user") -> None:
    state["paused"], state["paused_by"] = True, by if by in PAUSED_BY else "user"


def resume(state: dict, now: float, tz: tzinfo | None = None) -> None:
    """Resuming plans the next run from now (no catch-up of what was missed while paused) and
    clears the failure count, so a schedule paused for failures gets a fresh start."""
    state["paused"], state["paused_by"], state["failures"] = False, "", 0
    state["next_at"] = next_after(state["spec"], now, tz)


def line(state: dict) -> str:
    """The row's plain line: what repeats, and whether it is paused and why."""
    text = describe(state["spec"])
    if state["paused"]:
        why = "paused after three runs in a row didn't finish" if state["paused_by"] == "failures" else "paused"
        return f"{text}, {why}"
    return text


def shown(state: dict | None, switch_on: bool) -> dict | None:
    """The schedule as the app's `job` event carries it. None: no schedule."""
    if state is None:
        return None
    return {"text": line(state), "next": None if state["paused"] or not switch_on else state["next_at"],
            "paused": state["paused"], "reason": state["paused_by"], "last": state["last_run_at"],
            "switch_on": switch_on}


# ---- the file ----------------------------------------------------------------------------------
#
# A schedule lives NEXT TO the job's folder, not in it (`jobs/<id>.schedule.json`): the job's own
# tools work inside its folder, and a job that could write its own schedule file would repeat itself
# without a card.

def file_for(jobs_root: str | Path, job_id: str) -> Path:
    return Path(jobs_root) / f"{job_id}.{FILE}"


def load(path: str | Path) -> tuple[dict | None, str]:
    """(state, problem). No file: (None, ""). An unreadable or invalid file is moved aside as
    `<name>.bad` and reported ("bad"), and the job has no schedule."""
    path = Path(path)
    try:
        text = path.read_text()
    except FileNotFoundError:
        return None, ""
    except OSError:
        return None, "bad"
    try:
        state = clean_state(json.loads(text))
    except ValueError:
        state = None
    if state is None:
        try:
            os.replace(path, path.with_name(path.name + ".bad"))
        except OSError:
            pass
        return None, "bad"
    return state, ""


def save(path: str | Path, state: dict) -> None:
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=1))
    os.replace(tmp, path)


def remove(path: str | Path) -> None:
    try:
        Path(path).unlink()
    except OSError:                 # not there, or not a file we can remove: either way it is not a schedule
        pass
