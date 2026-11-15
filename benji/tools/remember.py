"""Memory: facts the user asked Benji to keep."""

from __future__ import annotations

from .context import Ctx, _truncate


def _remember(ctx: Ctx, text: str, tags: list[str] | None = None) -> str:
    if not ctx.memory_path:
        return "[error] no memory configured"
    from .. import memory
    try:
        entry = memory.add(ctx.memory_path, text, tags if isinstance(tags, list) else None)
    except memory.Refused as e:
        return f"[refused] not remembered: {e}"
    return f"[ok] remembered: {entry['text']}"


def _recall(ctx: Ctx, query: str | None = None) -> str:
    if not ctx.memory_path:
        return "[error] no memory configured"
    from .. import memory
    items = memory.search(ctx.memory_path, query)
    if not items:
        return f"[no memories match {query!r}]" if query else "[no memories yet]"
    return _truncate("\n".join(f"- {m.get('text', '')}" for m in items))


MAX_NOTE_CHARS = 800


def _keep_note(ctx: Ctx, text: str = "") -> str:
    if ctx.keep_note is None:
        return "[error] no note is kept in this conversation"
    text = text.strip() if isinstance(text, str) else ""
    if len(text) > MAX_NOTE_CHARS:
        return f"[refused] too long: keep it under {MAX_NOTE_CHARS} characters"
    return ctx.keep_note(text)
