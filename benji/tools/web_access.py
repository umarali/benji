"""Web search and fetching a page."""

from __future__ import annotations

import urllib.parse

from .context import Ctx, MAX_OUTPUT, _truncate


def _web_fetch(ctx: Ctx, url: str, prompt: str | None = None) -> str:
    from .. import web
    try:
        text = web.fetch_text(url, max_chars=MAX_OUTPUT - 200)
    except web.WebError as e:
        if str(e).startswith("refusing"):
            ctx.denied_code = "tool_refused" if "non-http" in str(e) else "host_refused"
        return f"[error] {e}"
    header = f"[fetched {url}]"
    if prompt:
        header += f" (looking for: {prompt})"
    return _truncate(f"{header}\n\n{text}")


def _web_search(ctx: Ctx, query: str, count: int = 5) -> str:
    from .. import web
    try:
        provider, results = web.search(query, n=max(1, min(count, 10)))
    except web.WebError as e:
        return f"[error] {e}"
    if not results:
        return f"[no results] {query!r} (via {provider})"
    for r in results:               # web_fetch may read these unasked in a tainted turn
        host = urllib.parse.urlsplit(str(r.get("url", ""))).hostname
        if host:
            ctx.search_hosts.add(host.casefold())
    lines = [f"[search via {provider}]"]
    for i, r in enumerate(results, 1):
        lines.append(f"{i}. {r['title']}\n   {r['url']}\n   {r['snippet']}")
    return _truncate("\n".join(lines))
