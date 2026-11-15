"""Local token-usage log: one JSONL line per model call, so Benji's own API spend is visible.

Each line: {"ts": <unix>, "provider": "claude", "model": "...", "input_tokens": n,
"output_tokens": n, "cache_read_tokens": n, "cache_write_tokens": n}. The numbers come from
the usage block of the response Benji already received; nothing extra is sent anywhere.
Set BENJI_USAGE_LOG=0 to turn it off. No prompts, answers or file contents are stored. The file
is mode 0600 (a file with a wider mode is tightened on the first write).
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from . import private_file
from .switches import switch

FIELDS = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")


def from_anthropic(resp: dict) -> dict:
    u = resp.get("usage") or {}
    return {
        "input_tokens": _int(u.get("input_tokens")),
        "output_tokens": _int(u.get("output_tokens")),
        "cache_read_tokens": _int(u.get("cache_read_input_tokens")),
        "cache_write_tokens": _int(u.get("cache_creation_input_tokens")),
    }


def from_openai(resp: dict) -> dict:
    u = resp.get("usage") or {}
    details = u.get("prompt_tokens_details") or {}
    # Where a server says what came from its cache: OpenAI, GLM, Kimi, Qwen in
    # prompt_tokens_details.cached_tokens; DeepSeek as prompt_cache_hit_tokens (in the details or at
    # the top of usage, its own docs show both); Kimi's schema also shows usage.cached_tokens.
    cached = max(_int(details.get("cached_tokens")), _int(details.get("prompt_cache_hit_tokens")),
                 _int(u.get("prompt_cache_hit_tokens")), _int(u.get("cached_tokens")))
    # Cached tokens count inside prompt_tokens; report them apart, like Anthropic does. Kimi and
    # Qwen also report what was written to their cache (billed apart from plain input).
    written = max(_int(details.get("cache_write_tokens")), _int(details.get("cache_creation_input_tokens")))
    return {
        "input_tokens": max(_int(u.get("prompt_tokens")) - cached - written, 0),
        "output_tokens": _int(u.get("completion_tokens")),
        "cache_read_tokens": cached,
        "cache_write_tokens": written,
    }


def _int(v) -> int:
    return v if isinstance(v, int) and v >= 0 else 0


def enabled() -> bool:
    return switch("BENJI_USAGE_LOG", True)


def record(path: str | Path, provider: str, model: str, usage: dict) -> dict | None:
    """Append one call's usage. Never raises: a full disk mustn't break a run."""
    entry = {"ts": int(time.time()), "provider": provider, "model": model,
             **{k: _int(usage.get(k)) for k in FIELDS}}
    try:
        private_file.append(path, json.dumps(entry) + "\n")
    except OSError:
        return None
    return entry


def load(path: str | Path) -> list[dict]:
    out: list[dict] = []
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return out
    for line in lines:
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(e, dict):
            out.append(e)
    return out


def totals(entries: list[dict]) -> dict:
    """Calls and token sums, overall and per model."""
    def empty() -> dict:
        return {"calls": 0, **{k: 0 for k in FIELDS}}

    overall, by_model = empty(), {}
    for e in entries:
        key = f"{e.get('provider', '?')}/{e.get('model', '?')}"
        for bucket in (overall, by_model.setdefault(key, empty())):
            bucket["calls"] += 1
            for k in FIELDS:
                bucket[k] += _int(e.get(k))
    return {"overall": overall, "by_model": by_model}


def summary(path: str | Path, since: float | None = None) -> str:
    """A short human-readable report of the log (optionally only entries at or after `since`)."""
    entries = [e for e in load(path) if since is None or _int(e.get("ts")) >= since]
    if not entries:
        return f"No model calls logged in {path}."
    t = totals(entries)
    first = time.strftime("%Y-%m-%d %H:%M", time.localtime(min(_int(e.get("ts")) for e in entries)))
    lines = [f"Model calls logged since {first} ({path}):"]
    for name, b in sorted(t["by_model"].items()):
        lines.append(f"  {name}: {b['calls']} calls, {_fmt(b)}")
    if len(t["by_model"]) > 1:
        lines.append(f"  total: {t['overall']['calls']} calls, {_fmt(t['overall'])}")
    return "\n".join(lines)


def _fmt(b: dict) -> str:
    s = f"{b['input_tokens']:,} in, {b['output_tokens']:,} out"
    if b["cache_read_tokens"] or b["cache_write_tokens"]:
        s += f", cache {b['cache_read_tokens']:,} read / {b['cache_write_tokens']:,} written"
    return s
