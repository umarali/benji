"""Persistent memory: a simple append-only JSONL store of things Benji was told.

One fact per line: {"ts": <unix>, "text": "...", "tags": [...]}. Kept small and
human-readable, readable by this user only (0600). The app's Settings › Memory lists, changes and
forgets lines (BenjiCore/ProfileMemory.swift). `add` refuses what must never be kept: secrets,
and guesses about the user (only what they said themselves).
"""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path

MAX_FACT_CHARS = 300

_SECRET_PATTERNS = [
    # "my password is …", "API key: …", "PIN = …"
    re.compile(r"\b(pass(word|code|phrase)|pin|api[ _-]?key|secret|token|private key|seed phrase|recovery "
               r"(phrase|code)|one[- ]time code|2fa code|otp|cvv|cvc)\b\s*(is|was|:|=)", re.I),
    re.compile(r"\b(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_\w{20,}|xox[abpr]-[\w-]{10,}"
               r"|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),                              # a US social security number
    re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"),  # an IBAN
]
_TOKEN = re.compile(r"[A-Za-z0-9+/=_-]{32,}")
_DIGIT_RUN = re.compile(r"\d(?:[ -]?\d){12,18}")
_GUESS = re.compile(r"\b(probably|presumably|apparently|likely|maybe|perhaps|seems?|appears?|might be|may be|"
                    r"must be|i (think|guess|suspect|assume)|i'?m guessing)\b", re.I)


def _luhn(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        n = int(ch)
        if i % 2:
            n = n * 2 - 9 if n > 4 else n * 2
        total += n
    return total % 10 == 0


def refusal(text: str) -> str | None:
    """Why `text` can't be remembered, or None when it can. Secrets (passwords, keys, tokens,
    card, ID and account numbers) never; and only what the user said, never a guess about them
    (a hedged fact is a guess). One short line."""
    t = (text or "").strip()
    if not t:
        return "nothing to remember"
    if len(t) > MAX_FACT_CHARS:
        return f"too long: keep one short line (at most {MAX_FACT_CHARS} characters)"
    if any(p.search(t) for p in _SECRET_PATTERNS):
        return "it looks like a secret (a password, key, code or ID number); those are never kept"
    if any(any(c.isdigit() for c in m) and any(c.isalpha() for c in m) for m in _TOKEN.findall(t)):
        return "it looks like a key or token; those are never kept"
    if any(_luhn(re.sub(r"\D", "", m)) for m in _DIGIT_RUN.findall(t)):
        return "it looks like a card or account number; those are never kept"
    if _GUESS.search(t):
        return "only keep what the user said about themselves, not a guess about them"
    return None


class Refused(ValueError):
    pass


def load(path: str | Path) -> list[dict]:
    out: list[dict] = []
    try:
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    except OSError:
        pass
    return out


def add(path: str | Path, text: str, tags: list[str] | None = None) -> dict:
    """Appends one fact, as one line. Raises Refused for what `refusal` rejects; a fact already
    kept (same words, any case) is returned as it is, not added twice."""
    text = " ".join((text or "").split())
    reason = refusal(text)
    if reason:
        raise Refused(reason)
    for m in load(path):
        if str(m.get("text", "")).strip().casefold() == text.casefold():
            return m
    entry = {"ts": int(time.time()), "text": text, "tags": tags or []}
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    os.chmod(p, 0o600)   # a file from before this rule, too
    return entry


def search(path: str | Path, query: str | None = None, limit: int = 50) -> list[dict]:
    items = load(path)
    if query:
        q = query.lower()
        items = [m for m in items
                 if q in m.get("text", "").lower()
                 or any(q in str(t).lower() for t in m.get("tags", []))]
    return items[-limit:]


def digest(path: str | Path, limit: int = 20) -> str:
    """A short bullet list of recent memories, for the system prompt."""
    items = load(path)[-limit:]
    return "\n".join(f"- {m.get('text', '')}" for m in items if m.get("text"))
