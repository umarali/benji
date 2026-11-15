"""macOS automation: AppleScript and Shortcuts."""

from __future__ import annotations

import re
import shutil
import subprocess
import sys

from .context import Ctx, _run, _truncate


# Stance: automate apps through their own scripting, never by faking clicks.

# Verbs that change state, send things, or escape to the shell -> need approval.
# A bare `set` is not in this list: AppleScript also uses it for local variables in read-only scripts
# (date math, results of a read). Property writes made with `set` are caught by `_sets_a_property` below.
# `do script` (Terminal), `run script`/`load script` (other code), raw «event»/«class» codes (the
# user can't read them), `set URL`/`set name` and `open location`.
_AS_MUTATING = re.compile(
    r"\b(make|create|delete|duplicate|send|move|remove|add|open|quit|close|save|"
    r"empty|paste|mount|eject)\b|do\s+shell\s+script|\bdo\s+script\b|\b(?:run|load)\s+script\b"
    r"|«|<<\s*(?:event|class)\b|\bset\s+(?:the\s+)?(?:URL|name)\b|\bopen\s+location\b", re.I)


# `set` and `copy` also write an app object's property: `set body of note 1 to "x"`, or inside a
# `tell` block `set body to "x"`. A property is named with `of`; inside an app's tell block a bare name
# set to a literal value is the target's own property. A local variable filled from a read (`set evs
# to every event of calendar 1`) names no `of` and takes no literal, so it stays a read.
_AS_SET = re.compile(r"\b(?:set|copy)\s+(.+?)\s+to\s+(.+)", re.I)
_AS_COPY = re.compile(r"\bcopy\s+.+?\s+to\s+(.+)", re.I)
_AS_LITERAL = re.compile(r"""^(?:["\u201c]|-?\d|true\b|false\b|\{|missing\s+value\b|date\s+")""", re.I)
_AS_TELL_APP = re.compile(r"\btell\s+(?:application|app)\b", re.I)


def _sets_a_property(script: str) -> bool:
    in_app = bool(_AS_TELL_APP.search(script))
    for line in script.splitlines():
        copied = _AS_COPY.search(line)
        if copied and re.search(r"\bof\b", copied.group(1), re.I):
            return True
        m = _AS_SET.search(line)
        if not m or line.lstrip().lower().startswith("copy"):
            continue
        target, value = m.group(1).strip(), m.group(2).strip()
        if re.search(r"\bof\b", target, re.I):
            return True
        if in_app and _AS_LITERAL.match(value):
            return True
    return False


def applescript_is_mutating(script: str) -> bool:
    return bool(_AS_MUTATING.search(script)) or _sets_a_property(script)


# Read-only in AppleScript's terms, but they act as the user or reach private data,
# using the host app's Accessibility grant. Each: (what the user is asked to allow, pattern).
_AS_SENSITIVE = [
    ("type, click or script another app's interface",       # `delay` + System Events: here too
     re.compile(r"\b(?:keystroke|key\s+code|click|perform\s+action)\b|\bSystem\s+Events\b", re.I)),
    ("run JavaScript inside a web page", re.compile(r"\bdo\s+JavaScript\b", re.I)),
    ("read the clipboard", re.compile(r"\bthe\s+clipboard\b", re.I)),
]


def applescript_sensitivity(script: str) -> str | None:
    for why, pattern in _AS_SENSITIVE:
        if pattern.search(script):
            return why
    return None


def _brief(text: str, limit: int = 200) -> str:
    """One line, shortened, for an approval prompt."""
    one = " ".join(text.split())
    return one if len(one) <= limit else one[: limit - 1] + "…"


def _require_macos() -> str | None:
    return None if sys.platform == "darwin" else "[error] macOS-only tool (not available on this OS)."


def _run_applescript(ctx: Ctx, script: str) -> str:
    err = _require_macos()
    if err:
        return err
    try:
        proc = _run(ctx, ["osascript"], input=script, timeout=120)
    except FileNotFoundError:
        return "[error] osascript not found"
    except subprocess.TimeoutExpired:
        return "[error] AppleScript timed out after 120s"
    out = (proc.stdout or "") + (("\n[stderr]\n" + proc.stderr) if proc.stderr else "")
    return _truncate(f"[exit {proc.returncode}]\n{out}".rstrip())


def _run_shortcut(ctx: Ctx, name: str, input: str | None = None) -> str:
    err = _require_macos()
    if err:
        return err
    if shutil.which("shortcuts") is None:
        return "[error] the 'shortcuts' CLI is not available"
    try:
        proc = _run(ctx, ["shortcuts", "run", name], input=input, timeout=120)
    except subprocess.TimeoutExpired:
        return "[error] shortcut timed out after 120s"
    out = (proc.stdout or "") + (("\n[stderr]\n" + proc.stderr) if proc.stderr else "")
    return _truncate(f"[exit {proc.returncode}]\n{out}".rstrip())


def _list_shortcuts(ctx: Ctx) -> str:
    err = _require_macos()
    if err:
        return err
    if shutil.which("shortcuts") is None:
        return "[error] the 'shortcuts' CLI is not available"
    try:
        proc = _run(ctx, ["shortcuts", "list"], timeout=30)
    except subprocess.TimeoutExpired:
        return "[error] 'shortcuts list' timed out"
    return _truncate(proc.stdout.strip() or "[no shortcuts found]")
