"""`benji --diagnose [--hours N]` (D-144): a short report of what Benji did lately, to read or to
paste into a bug report. It says what happened and why it was allowed, and holds no content.

Everything printed comes from lines of `events.jsonl` that pass `audit.validate` (so only enums,
numbers, flags, tool names, hosts, ids and exception class names), from the fixed fields of
`latency.jsonl`, and from counts and exception class names found in `engine.log`. No line of
either log is ever copied into the report. The Settings > Copy diagnostics button puts this text on
the clipboard (the app runs this command).
"""

from __future__ import annotations

import json
import re
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import __version__, audit

# What each reason code means, in the report's words. Every code the gate can give is here.
CODE_WORDS = {
    "private_path": "a private file or folder (keys, mail, browser data): refused, never asked",
    "host_refused": "a web address on this Mac or its network: refused",
    "tool_refused": "refused by the tool itself",
    "unknown_tool": "a tool Benji doesn't have",
    "screen_unusable": "a screen step with no screen to act on, or one that didn't parse",
    "screen_one_at_a_time": "a second screen step in one reply",
    "policy_blocked": "a tool the user's policy.json switches off: never run, never asked",
    "tool_cap": "a tool call past the turn's limit: answered 'superseded' without running",
    "browser_no_grant": "a browser tool on a job with no approved sites",
    "browser_bad_tab": "a browser tool with no tab number",
    "browser_bad_url": "a page address Benji won't open (not https, an IP, a local name)",
    "browser_open_cap": "a job past its limit of opened pages",
    "browser_not_listed": "a tab on a site that isn't on the job's list: nothing was read",
    "job_sites_invalid": "a background job's site list that wasn't usable",
    "shell_destructive": "a command that deletes, overwrites or changes permissions",
    "shell_writes_file": "a command that writes to a file with >",
    "shell_system_action": "a command that stops programs, restarts the Mac, publishes or runs as administrator",
    "shell_sensitive": "a command that reaches the screen, other apps, the network or the clipboard",
    "shell_cwd_outside": "a command run outside the working folder",
    "shell_unclear": "a command Benji can't check first (variables, subshell, input redirection, very long)",
    "shell_not_listed": "a command not on the read-only list",
    "shell_args": "a read-only command with options that change things",
    "shell_private_path": "a command naming a private path",
    "shell_outside_path": "a command reading outside the working folder",
    "write_outside_folder": "a write outside the working folder",
    "overwrite_existing": "overwriting an existing file",
    "write_skill": "writing a skill",
    "read_outside_folder": "reading outside the working folder",
    "url_review": "a web address that could carry data out",
    "remember_unsaid": "remembering something the user didn't say",
    "applescript_sensitive": "an AppleScript that reaches beyond the app",
    "applescript_mutating": "an AppleScript that changes things",
    "shortcut": "running a Shortcut",
    "browser_new_origin": "opening a site not on the job's list",
    "browser_url_review": "opening a page whose address could carry data out",
    "browser_step_cap": "a job past its limit of unasked browser steps",
    "job_sites": "starting a job that reads sites in Chrome",
    "browser_act": "a click, typed word or key press in Chrome, classed after the page's element was looked at",
    "browser_act_quiet": "a step in Chrome that needed no card: a link on the same site, a tab, a disclosure, a tick, a field named in the message",
    "browser_act_free": "a scroll or a navigation key in Chrome",
    "browser_look": "listing a page's controls in Chrome",
    "browser_always": "reading a site the user set to always allow reading",
    "browser_act_asked": "a click, word or key in Chrome that sends, pays, posts, deletes, submits a form or can't be told",
    "browser_act_leaves": "a click in Chrome that leaves the site",
    "browser_act_grant": "letting a job click and type on a site (separate from reading it)",
    "browser_act_cap": "a job past its limit of unasked steps in Chrome",
    "browser_upload": "uploading a file to a site in Chrome (always asked, one card per file)",
    "browser_active_tab": "reading the page the user is looking at in Chrome",
    "browser_act_refused": "a password, card-number or one-time-code field, a file chooser, an unnamed element or a disallowed key: refused",
    "browser_bad_args": "a browser step with an argument that couldn't be right",
    "browser_bad_ref": "a browser step with no control number from browser_look",
    "screen_asked": "a screen step that is always asked",
    "screen_app_escalated": "a screen step the app asked about after all",
    "tainted_change": "a change after reading outside content",
    "tainted_site": "fetching a site nobody named, after reading outside content",
    "job_schedule": "making a job repeat, or changing or stopping that",
    "job_schedule_invalid": "a repeat that wasn't usable (not offered, or not a valid schedule)",
    "job_cannot_start": "a job trying to start another job or set a schedule: refused",
    "unattended_change": "a repeat run, with nobody watching, trying to do more than read: it waited for you",
    "recent_decline": "an action you said not now to a few minutes ago: not asked again yet",
}
_MAX_LISTED = 12

_TRACEBACK = re.compile(r"^Traceback \(most recent call last\)")
_EXC_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Interrupt|Exit))\b")
_LOG_TIME = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4})\s")


def _when(text: str) -> datetime | None:
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None


def _generations(path: Path, keep: int) -> list[Path]:
    """Oldest first: path.N ... path.1, path."""
    return [p for p in [path.with_name(f"{path.name}.{i}") for i in range(keep, 0, -1)] + [path] if p.exists()]


def read_events(workdir: Path, since: datetime, tz=None) -> tuple[list[dict], int, bool]:
    """(the events since `since` that pass the schema, how many lines didn't, whether a log exists)."""
    files = _generations(workdir / audit.FILE_NAME, audit.KEEP)
    events: list[dict] = []
    skipped = 0
    for f in files:
        try:
            lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            if not line.strip():
                continue
            try:
                e = audit.validate_line(line)
            except audit.AuditError:
                skipped += 1
                continue
            at = _when(e["time"])
            if at is not None and at >= since:
                e["_at"] = at.astimezone(tz) if tz else at
                events.append(e)
    events.sort(key=lambda e: e["_at"])
    return events, skipped, bool(files)


def read_engine_log(workdir: Path, since: datetime) -> tuple[int, int, Counter]:
    """(lines, tracebacks, exception class names) of engine.log since `since`. Nothing of a line is kept."""
    lines = tracebacks = 0
    types: Counter = Counter()
    for f in _generations(workdir / "engine.log", 2):
        try:
            text = f.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for raw in text:
            m = _LOG_TIME.match(raw)
            at = _when(m.group(1)) if m else None
            if at is None or at < since:
                continue
            lines += 1
            body = raw[m.end():].strip()
            if _TRACEBACK.match(body):
                tracebacks += 1
            found = _EXC_LINE.match(body)
            if found:
                name = found.group(1).rsplit(".", 1)[-1]
                if audit._PYNAME.match(name):
                    types[name] += 1
    return lines, tracebacks, types


def read_latency(workdir: Path, since: datetime, tz=None) -> list[tuple[datetime, int, str]]:
    """(time, sent-to-finished ms, a few fixed words) for the turns since `since`, slowest first."""
    try:
        lines = (workdir / "latency.jsonl").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    result = []
    for line in lines:
        try:
            e = json.loads(line)
            ms, ts = e.get("sent_to_finished_ms"), e.get("ts")
            at = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (ValueError, TypeError, AttributeError):
            continue
        if not isinstance(ms, int) or isinstance(ms, bool) or at < since:
            continue
        words = [w for w, on in (("spoken", e.get("spoken") is True), ("with the screen", e.get("screen") is True)) if on]
        backend = e.get("backend") if e.get("backend") in ("serve", "oneshot") else ""
        result.append((at.astimezone(tz) if tz else at, ms, " · ".join(([backend] if backend else []) + words)))
    return sorted(result, key=lambda r: -r[1])


def _stamp(at: datetime) -> str:
    return at.strftime("%m-%d %H:%M")           # in the time zone of the report (events are read into it)


def _counts(counter: Counter, order: tuple[str, ...] | None = None) -> str:
    keys = [k for k in order if counter[k]] if order else [k for k, _ in counter.most_common()]
    return " · ".join(f"{k} {counter[k]}" for k in keys) or "none"


def report(workdir: Path, hours: float = 24.0, now: datetime | None = None) -> str:
    now = now or datetime.now().astimezone()
    since = now - timedelta(hours=hours)
    events, skipped, found = read_events(workdir, since, now.tzinfo)
    out = [f"Benji {__version__} diagnostics · the last {_hours(hours)} to {now.strftime('%Y-%m-%d %H:%M %z')}",
           "No message text, page text, file contents or addresses are in this report.", ""]
    if not found:
        out.append("events.jsonl: not found. Benji hasn't logged yet, or BENJI_AUDIT=0 is set.")
    elif not events:
        out.append("events.jsonl: nothing logged in this time.")
    else:
        out += _activity(events) + _denials(events) + _approvals(events) + _jobs(events) + _browser(events) \
            + _errors(events) + _engine(events)
    if skipped:
        out.append(f"{skipped} line{'s' if skipped != 1 else ''} of events.jsonl weren't in the log's format and were skipped.")
    lines, tracebacks, types = read_engine_log(workdir, since)
    if lines or tracebacks:
        out += ["", "Engine log (engine.log)",
                f"  {lines} line{'s' if lines != 1 else ''}, {tracebacks} traceback{'s' if tracebacks != 1 else ''}"
                + (f" ({_counts(types)})" if types else "")]
    slow = read_latency(workdir, since, now.tzinfo)[:3]
    if slow:
        out += ["", "Slowest turns (latency.jsonl, from sending to finished)"]
        out += [f"  {_stamp(at)}  {ms / 1000:.1f} s" + (f"  ({words})" if words else "") for at, ms, words in slow]
    return "\n".join(out).rstrip()


def _hours(hours: float) -> str:
    return f"{hours:g} hour{'s' if hours != 1 else ''}"


def _activity(events: list[dict]) -> list[str]:
    turns = [e for e in events if e["kind"] == "turn_end"]
    tools = [e for e in events if e["kind"] == "tool"]
    taints = Counter(e.get("taint") or e["source"] for e in events if e["kind"] == "taint")
    status = Counter(e["status"] for e in turns if e["scope"] == "turn")
    job_status = Counter(e["status"] for e in turns if e["scope"] == "job")
    names = Counter(e["tool"] for e in tools)
    out = ["Activity",
           f"  Turns: {sum(status.values())} ({_counts(status, audit.TURN_STATUS)}) · job turns: {sum(job_status.values())}"
           + (f" ({_counts(job_status, audit.TURN_STATUS)})" if job_status else ""),
           f"  Tool calls: {len(tools)} — {_counts(Counter(e['gate'] for e in tools), audit.GATES)}"]
    if names:
        out.append("  Tools used: " + ", ".join(f"{n} {c}" for n, c in names.most_common(8)))
    if taints:
        out.append(f"  Read outside content (turn marked tainted): {sum(taints.values())} ({_counts(taints)})")
    actions = Counter(e["action"] for e in events if e["kind"] == "job_action")
    if actions:
        out.append(f"  Job row buttons: {_counts(actions, audit.JOB_ACTIONS)}")
    return out + [""]


def _denials(events: list[dict]) -> list[str]:
    rows = [e for e in events if e["kind"] == "tool" and (e["gate"] == "denied" or e.get("result") == "declined")]
    if not rows:
        return ["Denied or declined", "  none", ""]
    out = ["Denied or declined (refused in code, or answered No)"]
    for e in rows[:_MAX_LISTED]:
        how = "declined by you" if e.get("result") == "declined" else "refused in code"
        host = f" {e['host']}" if e.get("host") else ""
        path = f" [{e['path']} path]" if e.get("path") else ""
        out.append(f"  {_stamp(e['_at'])}  {e['tool']}{host}{path}: {how} ({e['code']}) — {CODE_WORDS.get(e['code'], 'see the code')}")
    if len(rows) > _MAX_LISTED:
        out.append(f"  … and {len(rows) - _MAX_LISTED} more")
    return out + [""]


def _approvals(events: list[dict]) -> list[str]:
    asked = [e for e in events if e["kind"] == "approval_asked"]
    answered = [e for e in events if e["kind"] == "approval_answered"]
    if not asked and not answered:
        return ["Approvals", "  none asked", ""]
    by = Counter(e["who"] for e in answered)
    decided = Counter(e.get("decision", "") for e in answered)
    codes = Counter(e["code"] for e in asked if e.get("code"))
    out = ["Approvals",
           f"  Asked {len(asked)} · answered {len(answered)} (yes {decided['yes']} · no {decided['no']})",
           f"  Answered by: {_counts(by, audit.APPROVAL_WHO)}"]
    if codes:
        out.append("  Asked for: " + ", ".join(f"{c} ×{n}" for c, n in codes.most_common(6)))
    unanswered = len(asked) - len(answered)
    if unanswered > 0:
        out.append(f"  {unanswered} still waiting, or the engine stopped before they were answered")
    return out + [""]


def _jobs(events: list[dict]) -> list[str]:
    last: dict[str, dict] = {}
    for e in events:
        if e["kind"] == "job_state":
            last[e["job"]] = e
    if not last and not any(e["kind"] in ("job_run", "job_schedule") for e in events):
        return []
    states = Counter(e["state"] for e in last.values())
    out = ["Jobs", f"  {len(last)} seen: {_counts(states, audit.JOB_STATES)}"]
    for job, e in last.items():
        if e["state"] in ("failed", "interrupted"):
            out.append(f"  {_stamp(e['_at'])}  job {job[:8]} {e['state']}" + (f" ({e['code']})" if e.get("code") else ""))
    runs = Counter((e["how"], e["outcome"]) for e in events if e["kind"] == "job_run")
    if runs:
        out.append("  Runs: " + ", ".join(f"{how} {outcome} ×{n}" for (how, outcome), n in sorted(runs.items())))
    sched = Counter(e["action"] for e in events if e["kind"] == "job_schedule")
    if sched:
        out.append("  Schedules: " + _counts(sched, audit.SCHEDULE_ACTIONS))
    rereads = sum(1 for e in events if e["kind"] == "job_reread")
    if rereads:
        out.append(f"  Brief read to a long job again: {rereads}×")
    return out + [""]


def _browser(events: list[dict]) -> list[str]:
    link = [e for e in events if e["kind"] == "browser_link"]
    refuse = [e for e in events if e["kind"] == "browser_refuse"]
    grants = [e for e in events if e["kind"] == "browser_grant"]
    switches = [e for e in events if e["kind"] == "browser_switch"]
    if not (link or refuse or grants or switches):
        return []
    out = ["Browser"]
    if switches:
        out.append(f"  Settings switch: turned on {sum(1 for e in switches if e['enabled'])}×, off {sum(1 for e in switches if not e['enabled'])}×")
    if link:
        states = Counter(e["state"] for e in link)
        rejects = Counter(e["code"] for e in link if e["state"] == "rejected" and e.get("code"))
        out.append(f"  Link: {_counts(states, audit.BROWSER_STATES)}" + (f" (refused hellos: {_counts(rejects)})" if rejects else ""))
    if grants:
        out.append(f"  Sites approved for jobs: {_counts(Counter(e['host'] for e in grants))}")
    if refuse:
        by_host = Counter((e.get("host") or "(no valid host)", e["code"]) for e in refuse)
        out.append("  Refused: " + ", ".join(f"{h} ×{n} ({c})" for (h, c), n in by_host.most_common(8)))
    return out + [""]


def _errors(events: list[dict]) -> list[str]:
    errors = [e for e in events if e["kind"] == "error"]
    if not errors:
        return ["Errors", "  none", ""]
    by = Counter((e["where"], e["code"], e.get("error_type", "")) for e in errors)
    out = ["Errors"]
    for (where, code, etype), n in by.most_common(10):
        out.append(f"  {code} ×{n} in {where}" + (f" ({etype})" if etype else ""))
    return out + [""]


def _engine(events: list[dict]) -> list[str]:
    starts = [e for e in events if e["kind"] == "engine_start" and e["src"] == "engine"]
    app_starts = [e for e in events if e["kind"] == "engine_start" and e["src"] == "app"]
    exits = [e for e in events if e["kind"] == "engine_exit" and not e["clean"]]
    if not (starts or app_starts or exits):
        return []
    launched = max(len(starts), len(app_starts))
    restarts = max(launched - 1, 0)
    out = ["Engine", f"  Started {launched}× ({restarts} restart{'s' if restarts != 1 else ''})"
           f" · exits that weren't a clean quit: {len(exits)}"]
    named = [e for e in starts if e.get("provider")]
    if named:       # where the data goes (D-147): the provider and host the engine last started with
        e = named[-1]
        out.append(f"  Sending to {e['provider']}" + (f" ({e['host']})" if e.get("host") else " (this computer)"
                   if e["provider"] in ("ollama", "lmstudio") else "") + (f", model {e['model']}" if e.get("model") else ""))
    for e in exits[:5]:
        detail = f"code {e['code']}" if "code" in e else e.get("error_type", "")
        out.append(f"  {_stamp(e['_at'])}  exit ({detail}) seen by the {e['src']}")
    return out + [""]
