"""The audit log: what happened and why it was allowed, with none of what was said.

One JSON object per line in the working folder's `events.jsonl` (mode 0600, rotated, stdlib only).
Each line has a time, a `kind` from the closed list `KINDS` below, who wrote it (`src`: the engine
or the app), usually a run or job id, and only fields whose values come from a fixed vocabulary: an
enum, a number, a flag, a host name, an id or an exception class name. Nothing else can be written:
`event()` checks every field against its kind's schema and refuses the whole event if one fails.

Never in this log, by construction: message text, model output, page text, file contents or the
names of files the user gave, full URLs or query strings, keys, tokens, screenshots. A path is only
ever `inside` the working folder, `private` or `outside`. A host is a host, never an address with a
path. The same holds for `--diagnose`'s report, which is built only from lines that pass `validate`.

A failed write is reported on stderr (the kind of failure, nothing more) and never stops a turn.
`BENJI_AUDIT=0` turns the log off. The app appends to the same file for the things only it sees
(job-row buttons, the engine's exit, the browser switch); its writer is BenjiCore/Safety/AuditLog.swift,
and companion/Tests/audit-cases.json holds lines both sides must agree on.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Any, Callable

from . import private_file
from .switches import switch

FILE_NAME = "events.jsonl"
MAX_BYTES = 1_000_000           # one generation: about 5000 events
KEEP = 3                        # events.jsonl.1 .. .3; the log is bounded at 4 MB

# ---- the vocabularies ------------------------------------------------------------------------

GATES = ("free", "quiet", "asked", "denied")
RESULTS = ("ok", "declined", "refused", "error", "cancelled", "stopped")
SCOPES = ("turn", "job")
TURN_STATUS = ("ok", "error", "cancelled")
APPROVAL_WHO = ("row", "card", "timeout", "stop")      # never by voice or a key
DECISIONS = ("yes", "no")
JOB_STATES = ("queued", "running", "needs-you", "finished", "failed", "stopped", "interrupted")
JOB_CODES = ("provider_error", "internal_error", "out_of_steps", "interrupted", "step_limit")
# Jobs: a job's runs, its schedule, the brief read again. Kinds and ids only.
RUN_KINDS = ("first", "scheduled", "continued")
RUN_OUTCOMES = ("news", "nothing_new", "failed", "stopped", "limit", "parked")
SCHEDULE_ACTIONS = ("set", "changed", "removed", "paused", "resumed", "auto_paused", "switch_on", "switch_off",
                    "bad_file", "clock_back", "started")
REREAD_REASONS = ("interval", "resume")
TAINT_KINDS = ("screen", "web", "browser", "file")      # gate.TAINT_KINDS: the set a turn's taint is
TAINT_SOURCES = ("screen", "web_page", "browser_page", "applescript", "outside_file", "command_output",
                 "past_job", "inherited", "other")
BROWSER_STATES = ("off", "waiting", "connected", "rejected")
LINK_CODES = ("bad_hello", "bad_token", "bad_protocol", "bad_origin")
MATCHES = ("granted", "not_listed", "invalid", "no_grant", "always")
GRANT_HOW = ("start", "card", "act_card", "always")
PATH_CLASSES = ("inside", "private", "outside")
ENGINE_MODES = ("serve", "oneshot", "repl")
PROVIDERS = ("claude", "openai", "deepseek", "glm", "kimi", "qwen", "ollama", "lmstudio")   # presets.NAMES
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,79}$")
SOURCES = ("engine", "app")
JOB_ACTIONS = ("answer", "stop", "steer", "dismiss", "continue", "schedule_pause", "schedule_resume",
               "schedule_delete", "schedules_off", "schedules_on")
DRIVE_STATES = ("granted", "declined", "timeout", "started", "ended")     # benji/drive.py
DRIVE_WHY = ("finished", "user_stop", "mouse", "typing", "click", "scroll", "limit", "time", "tainted",
             "turn_over", "app_stop", "error")                                  # drive.END_REASONS
ERROR_WHERE = ("turn", "job", "serve", "browser", "startup", "audit", "app")
ERROR_CODES = ("provider", "internal", "bad_request", "protocol", "startup", "browser", "image",
               "job_report", "audit_write", "engine_exit", "engine_launch", "out_of_steps")

# Why the gate decided as it did: one code per rule in benji/tools/approval.py (`decide`) and
# benji/browser.py (`plan`). Closed: a tool event with another code is refused.
GATE_CODES = frozenset({
    # free
    "read_only", "shell_allowlisted", "write_inside_folder", "read_inside_folder", "fetch_plain",
    "remember_said", "applescript_readonly", "job_start", "screen_free", "browser_tabs",
    "drive_free", "drive_start", "drive_end",
    # quiet
    "screen_quiet", "browser_granted", "drive_quiet", "browser_act", "browser_act_quiet", "browser_always",
    "browser_look", "browser_act_free",
    # asked
    "shell_destructive", "shell_sensitive", "shell_cwd_outside", "shell_unclear", "shell_not_listed",
    "shell_args", "shell_private_path", "shell_outside_path", "write_outside_folder", "overwrite_existing",
    "write_skill", "read_outside_folder", "url_review", "remember_unsaid", "applescript_sensitive",
    "applescript_mutating", "shortcut", "browser_new_origin", "browser_url_review", "browser_step_cap",
    "job_sites", "screen_asked", "screen_app_escalated", "tainted_change", "tainted_site",
    "shell_writes_file", "shell_system_action", "drive_consent", "drive_asked",
    "browser_act_asked", "browser_act_leaves", "browser_act_grant", "browser_act_cap", "browser_upload",
    "browser_active_tab",
    # denied (refused in code, never asked)
    "private_path", "host_refused", "tool_refused", "unknown_tool", "screen_unusable", "browser_no_grant",
    "browser_bad_tab", "browser_bad_url", "browser_open_cap", "browser_not_listed", "job_sites_invalid",
    "screen_one_at_a_time", "policy_blocked", "tool_cap", "browser_act_refused", "browser_bad_args", "browser_bad_ref",
    "drive_unusable", "drive_tainted", "drive_declined", "drive_stopped", "drive_secret", "drive_limit",
    # jobs: a repeat is always asked; a job can't start jobs; a scheduled run
    # only reads; a "not now" is not asked again for a while
    "job_schedule", "unattended_change", "job_schedule_invalid", "job_cannot_start", "recent_decline",
})

_ID = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
_REQUEST = re.compile(r"^[as]\d{1,6}$")
_PYNAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")      # an exception class or a tool name
_TOOL = re.compile(r"^[a-z][a-z0-9_]{0,39}$")
_VERSION = re.compile(r"^[0-9A-Za-z.+-]{1,24}$")
# A real host name (labels, a letters-only last label) or a dotted IPv4 address: a single word,
# which a mistyped argument could be, is not one.
_HOST = re.compile(r"^(?:(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}|\d{1,3}(?:\.\d{1,3}){3})$")
_TIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}$")


def _enum(*values: str) -> Callable[[Any], bool]:
    return lambda v: isinstance(v, str) and v in values


def _rx(rx: re.Pattern) -> Callable[[Any], bool]:
    return lambda v: isinstance(v, str) and rx.match(v) is not None


def _int(lo: int, hi: int) -> Callable[[Any], bool]:
    return lambda v: isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def _member(allowed) -> Callable[[Any], bool]:
    return lambda v: isinstance(v, str) and v in allowed


_CODE = _member(GATE_CODES)
_BOOL = lambda v: isinstance(v, bool)          # noqa: E731
_MS = _int(0, 7 * 86_400_000)
_COUNT = _int(0, 100_000)


def _taintset(v: Any) -> bool:
    """The sources a turn has read, as `+`-joined kinds in TAINT_KINDS order ("screen+web"): a
    fixed vocabulary, one string for each of the 15 possible sets and no other."""
    if not isinstance(v, str) or not v:
        return False
    parts = v.split("+")
    return all(p in TAINT_KINDS for p in parts) and v == "+".join(k for k in TAINT_KINDS if k in parts)


_TAINTSET = _taintset
_HOSTCHECK = lambda v: isinstance(v, str) and len(v) <= 253 and _HOST.match(v) is not None  # noqa: E731

# kind -> (required fields, {field: check}). The one place the list of kinds is defined.
KINDS: dict[str, tuple[tuple[str, ...], dict[str, Callable[[Any], bool]]]] = {
    # provider, host and model say where the data goes; the host is left out for localhost,
    # which is not a dotted name, and a key or a message can never be in any of them.
    "engine_start": (("mode",), {
        "mode": _enum(*ENGINE_MODES), "version": _rx(_VERSION), "jobs": _BOOL, "browser": _BOOL,
        "provider": _enum(*PROVIDERS), "host": _HOSTCHECK, "model": _rx(_MODEL)}),
    "engine_exit": (("clean",), {
        "clean": _BOOL, "code": _int(-255, 255), "error_type": _rx(_PYNAME)}),
    "turn_start": (("scope",), {
        "scope": _enum(*SCOPES), "screen": _BOOL, "jobs": _BOOL}),
    "turn_end": (("scope", "status"), {
        "scope": _enum(*SCOPES), "status": _enum(*TURN_STATUS), "ms": _MS, "tools": _COUNT,
        "calls": _COUNT, "code": _enum(*ERROR_CODES)}),
    "tool": (("tool", "gate", "code"), {
        "tool": _rx(_TOOL), "gate": _enum(*GATES), "code": _CODE,
        "scope": _enum(*SCOPES), "tainted": _BOOL, "taint": _TAINTSET, "result": _enum(*RESULTS), "ms": _MS,
        "path": _enum(*PATH_CLASSES), "host": _HOSTCHECK, "match": _enum(*MATCHES), "auto": _BOOL}),
    "approval_asked": (("request",), {
        "request": _rx(_REQUEST), "scope": _enum(*SCOPES), "tool": _rx(_TOOL),
        "code": _CODE}),
    "approval_answered": (("request", "who"), {
        "request": _rx(_REQUEST), "who": _enum(*APPROVAL_WHO), "decision": _enum(*DECISIONS),
        "scope": _enum(*SCOPES), "waited_ms": _MS}),
    "job_state": (("job", "state"), {
        "job": _rx(_ID), "state": _enum(*JOB_STATES), "code": _enum(*JOB_CODES)}),
    "taint": (("source",), {"source": _enum(*TAINT_SOURCES), "taint": _enum(*TAINT_KINDS),
                            "host": _HOSTCHECK, "scope": _enum(*SCOPES)}),
    "browser_link": (("state",), {"state": _enum(*BROWSER_STATES), "code": _enum(*LINK_CODES)}),
    "browser_grant": (("job", "host", "how"), {
        "job": _rx(_ID), "host": _HOSTCHECK, "how": _enum(*GRANT_HOW)}),
    "browser_refuse": (("tool", "code"), {
        "tool": _rx(_TOOL), "code": _CODE, "host": _HOSTCHECK,
        "match": _enum(*MATCHES), "job": _rx(_ID)}),
    "job_action": (("action",), {
        "action": _enum(*JOB_ACTIONS), "job": _rx(_ID), "decision": _enum(*DECISIONS)}),
    "drive": (("state",), {"state": _enum(*DRIVE_STATES), "why": _enum(*DRIVE_WHY), "steps": _COUNT,
                           "scope": _enum(*SCOPES)}),
    "job_run": (("job", "how", "outcome"), {
        "job": _rx(_ID), "how": _enum(*RUN_KINDS), "outcome": _enum(*RUN_OUTCOMES), "n": _int(1, 100_000)}),
    "job_schedule": (("action",), {"action": _enum(*SCHEDULE_ACTIONS), "job": _rx(_ID)}),
    "job_reread": (("reason", "job"), {"reason": _enum(*REREAD_REASONS), "job": _rx(_ID)}),
    "job_wait": (("job", "state"), {"job": _rx(_ID), "state": _enum("waiting", "back"),
                                    "reason": _enum("network", "rate_limit", "provider")}),
    "browser_switch": (("enabled",), {"enabled": _BOOL}),
    "diagnostics_copied": ((), {"ok": _BOOL}),
    # The measured warm-up on the talk key's key-down: how long it took and whether it was
    # skipped (the last call was recent, or the host is on this Mac). Times and flags only.
    "prewarm": (("skipped",), {"skipped": _BOOL, "ms": _MS, "ok": _BOOL}),
    "error": (("where", "code"), {
        "where": _enum(*ERROR_WHERE), "code": _enum(*ERROR_CODES), "error_type": _rx(_PYNAME)}),
}

_COMMON = {"time": _rx(_TIME), "kind": _member(KINDS), "src": _enum(*SOURCES), "run": _rx(_ID)}


class AuditError(ValueError):
    """An event the schema refuses. The message names the field, never the value."""


def validate(entry: dict) -> dict:
    """The entry if every field is of the kind's schema, else AuditError. The reader (`--diagnose`)
    and the tests use this on every line; `event()` uses it before anything is written."""
    kind = entry.get("kind")
    if kind not in KINDS:
        raise AuditError("unknown kind")
    required, fields = KINDS[kind]
    for name, value in entry.items():
        check = _COMMON.get(name) or fields.get(name)
        if check is None:
            raise AuditError(f"{kind}: unknown field {name[:24]!r}")
        if not check(value):
            raise AuditError(f"{kind}: bad value for {name}")
    for name in required:
        if name not in entry:
            raise AuditError(f"{kind}: missing {name}")
    return entry


def validate_line(line: str) -> dict:
    try:
        entry = json.loads(line)
    except ValueError:
        raise AuditError("not JSON") from None
    if not isinstance(entry, dict):
        raise AuditError("not an object")
    for name in ("time", "src"):
        if name not in entry:
            raise AuditError(f"missing {name}")
    return validate(entry)


# ---- the log ---------------------------------------------------------------------------------

_state: dict[str, Any] = {"path": None, "src": "engine"}
_lock = threading.Lock()
_reported: set[str] = set()


def enabled() -> bool:
    return switch("BENJI_AUDIT", True)


def configure(path: str | Path | None, src: str = "engine") -> None:
    """Where events go (the working folder's events.jsonl), or None to write nothing. Called once
    by the entry points; the library never writes unless it was told where."""
    _state["path"] = Path(path) if path is not None and enabled() else None
    _state["src"] = src if src in SOURCES else "engine"
    _reported.clear()


def path() -> Path | None:
    return _state["path"]


def _report(what: str) -> None:
    """One line on stderr per kind of failure (not per event): the failure's kind, nothing more."""
    if what not in _reported:
        _reported.add(what)
        print(f"[Benji] audit log: {what}", file=sys.stderr)


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def event(kind: str, run: str = "", **fields: Any) -> bool:
    """Append one event. False when it was refused by the schema or couldn't be written; it never
    raises, so logging can't stop a turn. Fields whose value is None are left out."""
    target = _state["path"]
    if target is None:
        return False
    try:
        entry: dict[str, Any] = {"time": _now(), "kind": kind, "src": _state["src"]}
        if run:
            entry["run"] = run
        entry.update({k: v for k, v in fields.items() if v is not None})
        validate(entry)
        private_file.append(target, json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n",
                            max_bytes=MAX_BYTES, keep=KEEP)
        return True
    except AuditError as e:
        _report(f"refused an event ({e})")      # names the kind and field, never a value
    except Exception as e:  # noqa: BLE001 — a log must never stop a turn
        _report(f"write failed ({type(e).__name__})")
    return False


def error(where: str, code: str, exc: BaseException | None = None, run: str = "") -> bool:
    """An `error` event: where it happened, a stable code, the exception's class (never its message)."""
    return event("error", run, where=where, code=code,
                 error_type=type(exc).__name__ if exc is not None else None)


# ---- helpers for the callers -------------------------------------------------------------------

def host_of(url: object) -> str | None:
    """The host of a URL or origin, lower-case, no port, no userinfo, no path: or None when it
    isn't one the schema takes. This is the only way a URL reaches the log."""
    if not isinstance(url, str):
        return None
    text = url.strip()
    if "//" not in text:
        text = "//" + text
    try:
        import urllib.parse
        host = urllib.parse.urlsplit(text).hostname
    except ValueError:
        return None
    host = (host or "").lower().rstrip(".")
    # A name made to carry data (a long label, an encoded blob) is not logged, only that a host was used.
    if len(host) > 80 or any(len(label) > 30 for label in host.split(".")):
        return None
    return host if _HOSTCHECK(host) else None


def taint_code(source: str) -> str:
    """Which of TAINT_SOURCES a Ctx.taint() description is."""
    s = (source or "").lower()
    for needle, code in (("past job", "past_job"), ("screen", "screen"), ("browser", "browser_page"),
                         ("web page", "web_page"), ("applescript", "applescript"),
                         ("outside the working folder", "outside_file"), ("command", "command_output")):
        if needle in s:
            return code
    return "other"


def safe_traceback(exc: BaseException) -> str:
    """A traceback with no message and no source line: exception class, then file:line in function
    for each frame. An exception's text can hold what the user typed (a path, a JSON error quoting
    a message), so the engine's stderr gets this, never traceback.print_exc."""
    frames = [f"  {Path(f.filename).name}:{f.lineno} in {f.name}" for f in traceback.extract_tb(exc.__traceback__)]
    return "\n".join(["Traceback (most recent call last):", *frames, type(exc).__name__])


# ---- redaction (engine.log, and a last pass over the diagnose report) --------------------------

_URL = re.compile(r"""\b(?:https?|wss?)://[^\s"'<>]+""", re.I)
_KEYS = [
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*"),
    re.compile(r"\b[0-9a-fA-F]{32}\.[A-Za-z0-9_-]{8,}"),      # an id.secret key, the shape Zhipu's older keys had
]
_BEARER = re.compile(r"\b[Bb]earer\s+[A-Za-z0-9._~+/=-]{8,}")
_ASSIGNED = re.compile(
    r"""(?i)\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH|AUTHORIZATION)[A-Z0-9_]*)\s*[=:]\s*(?:[Bb]earer\s+)?("[^"]*"|'[^']*'|\S+)""")
_HOME = re.compile(r"/Users/[^/\s]+")
_OPAQUE = re.compile(r"[A-Za-z0-9+/_=]{32,}")      # no hyphen: a job's id (a UUID) is not a secret


def _url_to_host(m: re.Match) -> str:
    rest = m.group(0).split("://", 1)
    scheme = rest[0].lower()
    authority = re.split(r"[/?#]", rest[1], maxsplit=1)[0]
    host = authority.rsplit("@", 1)[-1]
    return f"{scheme}://{host}/…" if len(rest[1]) > len(authority) else f"{scheme}://{host}"


def redact(text: str) -> str:
    """`text` with what must not be kept in a log taken out: a URL is cut to its host, key-shaped
    strings, bearer tokens, `KEY=value` assignments and long opaque runs become placeholders, and
    the home folder becomes `~`. engine.log's lines go through this (BenjiCore/Safety/LogRedaction.swift
    does the same; companion/Tests/redaction-cases.json holds the cases both must agree on)."""
    out = _URL.sub(_url_to_host, text)
    for rx in _KEYS:
        out = rx.sub("[key]", out)
    out = _BEARER.sub("Bearer [key]", out)
    out = _ASSIGNED.sub(lambda m: f"{m.group(1)}=[redacted]", out)
    out = _HOME.sub("~", out)
    return _OPAQUE.sub("[redacted]", out)
