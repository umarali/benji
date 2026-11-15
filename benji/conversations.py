"""Saved conversations, as background: the titles of the user's recent conversations with Benji.

The app saves each conversation's panel lines in `<workdir>/conversations/<id>.json`
(BenjiCore/Conversation/ConversationStore.swift; sample in companion/Tests/conversation-sample.json):
{"version": 1, "id": "<uuid>", "title": "...", "started": "<ISO 8601>", "updated": "<ISO 8601>",
 "lines": [{"role": "user" | "assistant" | "error" | "system", "text": "...", "at": "<ISO 8601>"}]}
(each line's "at" is optional: files saved by older versions of the app have none).
Only the titles and dates reach the model, never the lines; the conversation being continued is
already in the history it is given.
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

RECENT_LIMIT = 5
MAX_TITLE_CHARS = 60


def folder(workdir: str | Path) -> Path:
    return Path(workdir) / "conversations"


def recent(directory: str | Path, limit: int = RECENT_LIMIT, drop_newest: bool = False) -> list[tuple[str, str]]:
    """(title, day "YYYY-MM-DD") of the newest saved conversations, newest first. `drop_newest`:
    leave out the most recently changed one, the conversation being continued (the app saves
    it after each answer). Unreadable files are skipped."""
    found = []
    try:
        paths = list(Path(directory).glob("*.json"))
    except OSError:
        return []
    for p in paths:
        try:
            c = json.loads(p.read_text())
            updated = datetime.fromisoformat(str(c["updated"]).replace("Z", "+00:00"))
            title = " ".join(str(c["title"]).split())[:MAX_TITLE_CHARS].replace('"', "'")
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if title:
            found.append((updated, str(c.get("id", "")), title))
    found.sort(reverse=True)
    if drop_newest:
        found = found[1:]
    return [(title, updated.astimezone().date().isoformat()) for updated, _, title in found[:limit]]


def digest(directory: str | Path, limit: int = RECENT_LIMIT, drop_newest: bool = False) -> str:
    """A short bullet list for the system prompt: - "Title" (2026-10-30)."""
    return "\n".join(f'- "{title}" ({day})' for title, day in recent(directory, limit, drop_newest))
