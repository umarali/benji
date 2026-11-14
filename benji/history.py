"""Recent conversation passed in by a front-end, so follow-up questions have context.

The companion runs one Benji process per message. It keeps the recent exchanges in
memory and hands them over as a JSON file: [{"user": "...", "assistant": "..."}, ...].
They become plain prior turns (no tool calls, no images) before the new message.

How much is kept: everything while the user+assistant text fits in HISTORY_BUDGET_CHARS; once it
is over, whole exchanges are dropped, oldest first, until the rest fits in HISTORY_TRIM_TO_CHARS
(three quarters of the budget), never below the last MIN_EXCHANGES. Dropping in a chunk means
the start of the conversation changes once every several turns, not every turn, so it stays
cacheable (providers.py). The companion's ConversationMemory keeps the same ones (shared cases in
companion/Tests/history-cases.json). Lengths are Unicode code points (Swift: unicodeScalars).
"""

from __future__ import annotations

import json
from pathlib import Path

HISTORY_BUDGET_CHARS = 24_000   # user+assistant text of the kept exchanges, about 6,000 tokens
HISTORY_TRIM_TO_CHARS = HISTORY_BUDGET_CHARS * 3 // 4   # where a drop stops: 18,000
MIN_EXCHANGES = 10              # the old fixed window, kept even when long
MAX_EXCHANGES = MIN_EXCHANGES   # the old window's name
MAX_CHARS_PER_TURN = 4000  # keep a long earlier answer from crowding out the new turn


class HistoryError(Exception):
    pass


def kept_count(sizes: list[int]) -> int:
    """How many of the newest exchanges to keep, given each one's user+assistant length, oldest
    first: all of them while they fit in HISTORY_BUDGET_CHARS; otherwise as many as fit in
    HISTORY_TRIM_TO_CHARS counting back from the newest (stopping at the first that doesn't), but
    never fewer than the last MIN_EXCHANGES."""
    if sum(sizes) <= HISTORY_BUDGET_CHARS:
        return len(sizes)
    total = kept = 0
    for size in reversed(sizes):
        if total + size > HISTORY_TRIM_TO_CHARS:
            break
        total += size
        kept += 1
    return max(kept, min(MIN_EXCHANGES, len(sizes)))


def load_history(path: str) -> list[dict]:
    """Return neutral messages for the recent exchanges in `path` (see kept_count)."""
    return read_history(path)[0]


def read_history(path: str) -> tuple[list[dict], bool]:
    """The recent exchanges in `path` as neutral messages, and whether older ones were dropped."""
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise HistoryError(f"couldn't read conversation history {path}: {e}") from e
    return history_from_exchanges(raw)


def messages_from_exchanges(raw) -> list[dict]:
    """Neutral messages for the recent exchanges of [{"user", "assistant"}, ...] (see kept_count)."""
    return history_from_exchanges(raw)[0]


def history_from_exchanges(raw) -> tuple[list[dict], bool]:
    """Neutral messages for the recent exchanges of [{"user", "assistant"}, ...], and whether
    older ones were dropped. Blank entries are skipped before counting."""
    if not isinstance(raw, list):
        raise HistoryError("conversation history must be a JSON list of {user, assistant} objects")
    pairs: list[tuple[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            raise HistoryError("each history entry must be an object with 'user' and 'assistant'")
        user, assistant = item.get("user"), item.get("assistant")
        if not isinstance(user, str) or not isinstance(assistant, str):
            raise HistoryError("each history entry needs string 'user' and 'assistant' fields")
        if user.strip() and assistant.strip():
            pairs.append((user, assistant))
    keep = kept_count([len(u) + len(a) for u, a in pairs])
    messages: list[dict] = []
    for user, assistant in pairs[len(pairs) - keep:]:
        messages.append({"role": "user", "text": user[:MAX_CHARS_PER_TURN]})
        messages.append({"role": "assistant", "text": assistant[:MAX_CHARS_PER_TURN], "tool_calls": []})
    return messages, keep < len(pairs)
