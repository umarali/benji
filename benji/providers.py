"""Model-provider adapters.

One neutral message/tool format is used by the agent; each provider translates
it to and from its own wire protocol. HTTP uses only the Python standard library
(urllib), so there are no third-party dependencies.

Neutral message shapes (list of dicts):
  {"role": "user", "text": str, "images": [{"media_type", "data"}]}   (images optional)
  {"role": "assistant", "text": str, "tool_calls": [{"id","name","input"}]}
  {"role": "tool", "id": str, "name": str, "content": str}

complete() returns: {"text": str, "tool_calls": [{"id","name","input"}], "usage": {...}}
(usage: token counts from the response, see benji/usage.py)

stream() takes the same arguments plus on_text, cancelled and abort, asks the server to stream
(server-sent events), hands each piece of text to on_text as it arrives, and returns the same
dict as complete(); a stream stopped by a cancel returns it with "cancelled": True. A server
that answers a streaming request with plain JSON is read as complete() would read it.
Streaming is off until BENJI_STREAM=1 (the user's rule of 2026-10-31: unverified against the
real API, so opt-in); off, the agent calls complete(), exactly as before streaming. The app sets
BENJI_STREAM=1 for its `--serve` engine by default (D-118); the CLI still needs it set.

Prompt caching (Anthropic only), on unless BENJI_PROMPT_CACHE=0: up to four cache_control
breakpoints, read in the API's order (tools, system, messages): the last tool definition; the
stable base of the system prompt, sent as its own block, with this turn's rules after it in a
block of their own (prompts.SystemPrompt); the last message of the earlier conversation, so
the conversation is read from cache turn after turn; and, in a tool loop, the newest tool results,
so each step reads the steps before it (D-177: a job is one user message and many steps). The live
user message and any step that carries a screenshot are never marked. The 5-minute cache only. BENJI_PROMPT_CACHE=0 sends the request exactly as before
caching.

Web search (Anthropic only, D-154): the `web_search` tool goes to Anthropic's own search, which runs
on their side inside the model call, unless BENJI_WEB_SEARCH=local (the engine's own search: a Brave
or SerpAPI key, else DuckDuckGo, which now refuses automated requests). Billed per search on top of
tokens; at most WEB_SEARCH_MAX_USES a call. The searches it made come back in the result as
`searches` (query, hosts, error) so the agent taints the turn and logs them as it does its own tool.
Text written before a search is narration ("I'll look that up") and is not the answer.

Effort (Anthropic only): output_config.effort, read from BENJI_EFFORT (low, medium, high, xhigh,
max), default low (the user's rule of 2026-10-31). Sent only to models that accept it (effort_for);
no thinking field is ever sent, so Claude 5-family models think adaptively and effort sets how much.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Iterator
from urllib.parse import urlparse

from . import presets
from . import usage as usage_mod

TIMEOUT = 180
EPHEMERAL = {"type": "ephemeral"}
# The most one Anthropic reply may be, thinking included. A rich 3D figure runs 3,000-4,000 tokens
# of JSON; at 4,096 a guided microscope was cut off mid-block and nothing drew (D-150).
ANTHROPIC_MAX_TOKENS = 8192
# Anthropic's own web search (D-154): the basic version, which every current model takes and calls
# directly (no code execution). $10 per 1,000 searches, so a turn costs at most this many cents.
WEB_SEARCH_MAX_USES = 3
SERVER_WEB_SEARCH = {"type": "web_search_20250305", "name": "web_search", "max_uses": WEB_SEARCH_MAX_USES}
# A server-side search that hit its round limit comes back as pause_turn; it is resumed this often.
MAX_CONTINUATIONS = 3


class ProviderError(RuntimeError):
    pass


# A safety-filter stop, told plainly (D-172). The model service ended the reply because its own
# safety filter stepped in; nothing is wrong with the key or the network, and rewording often helps.
SAFETY_STOP = ("The model's safety filter stopped this reply. Nothing is wrong with your key or connection; "
               "the service chose not to answer. Try rewording what you asked, or ask me to explain what I "
               "was about to do.")
_SAFETY_WORDS = ("content filter", "content_filter", "safety filter", "safety system", "refusal",
                 "content policy", "content_policy", "responsibleaipolicyviolation")


def is_safety_stop(err: Exception) -> bool:
    text = " ".join(str(err).split()).casefold()
    return str(err) == SAFETY_STOP or any(w in text for w in _SAFETY_WORDS)


def foreground_message(err: Exception) -> str:
    """A foreground turn's error line: the provider's own words, except that a safety-filter stop
    is told plainly (D-172)."""
    return SAFETY_STOP if is_safety_stop(err) else str(err)


def plain_message(err: Exception) -> str:
    """A provider error in words a person can act on: a safety-filter stop, then benji/errors.py's
    plain reasons (a refused key, an account out of credit, a busy or unreachable service, a region);
    otherwise the provider's own line, cut. Used for jobs; a foreground turn does the same in serve.py.
    Never a traceback."""
    if is_safety_stop(err):
        return SAFETY_STOP
    from .errors import explain
    reason, words = explain(" ".join(str(err).split()))
    return words[:300] if reason != "other" else (words[:240] or "The model service returned an error.")


# OpenAI-format servers only (Anthropic's calls are unchanged): a 429 or a 5xx is tried again twice,
# after the server's Retry-After (cut to MAX_WAIT) or 1 s then 2 s. A 429 that says the account is
# out of balance or quota is not tried again: waiting will not fix it.
RETRY_STATUS = (429, 500, 502, 503, 504)
RETRIES = 2
MAX_WAIT = 8.0
_QUOTA_WORDS = ("balance", "insufficient_quota", "exceeded_current_quota", "arrear", "recharge", "billing",
                "overdue", "out of credit", "insufficient funds")
_sleep = time.sleep         # the tests replace it


def _retry_after(headers, attempt: int) -> float:
    raw = (headers.get("retry-after") if headers is not None else None) or ""
    try:
        wait = float(raw)
    except ValueError:
        wait = float(attempt + 1)
    return min(max(wait, 0.0), MAX_WAIT)


def _error_text(body: str) -> str:
    """The server's own error message, short: `{"error": {"message": ...}}` and the flat shapes
    some servers use. A body that is not JSON is cut. Never the whole body: an error can echo
    what was sent."""
    text = body.strip()
    try:
        data = json.loads(text)
    except ValueError:
        return text[:300]
    err = data.get("error", data) if isinstance(data, dict) else data
    if isinstance(err, str):
        return err[:300]
    if isinstance(err, dict):
        bits = [str(err[k]) for k in ("code", "type", "message", "msg") if err.get(k) not in (None, "")]
        return " · ".join(dict.fromkeys(bits))[:300] or text[:300]
    return text[:300]


def _out_of_money(body: str) -> bool:
    low = body.lower()
    return any(w in low for w in _QUOTA_WORDS)


def _host(url: str) -> str:
    return urlparse(url).netloc or url


def _error_code(body: str) -> str:
    try:
        data = json.loads(body)
    except ValueError:
        return ""
    err = data.get("error", data) if isinstance(data, dict) else None
    code = err.get("code") if isinstance(err, dict) else None
    return str(code) if code not in (None, "") else ""


def _open(req: urllib.request.Request, url: str, retry: bool, cancelled: Callable[[], bool] = lambda: False,
          no_retry_codes: frozenset[str] = frozenset()):
    """urlopen with the OpenAI-format policy: a short retry on 429/5xx, and errors that name the
    host and the server's message instead of dumping the body."""
    attempt = 0
    while True:
        try:
            return urllib.request.urlopen(req, timeout=TIMEOUT)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            if (retry and e.code in RETRY_STATUS and attempt < RETRIES and not cancelled()
                    and not (e.code == 429 and (_out_of_money(body) or _error_code(body) in no_retry_codes))):
                _sleep(_retry_after(e.headers, attempt))
                attempt += 1
                continue
            if retry:
                raise ProviderError(f"HTTP {e.code} from {_host(url)}: {_error_text(body)}") from None
            raise ProviderError(f"HTTP {e.code} from {url}:\n{body}") from None
        except urllib.error.URLError as e:
            raise ProviderError(f"network error calling {url}: {e.reason}") from None


def _switch(name: str) -> bool:
    """Off unless explicitly on (streaming stays opt-in, the user's rule of 2026-10-31)."""
    return os.environ.get(name, "0").strip().lower() in ("1", "true", "yes", "on")


def server_search_enabled() -> bool:
    """Anthropic's own web search for the web_search tool, unless BENJI_WEB_SEARCH=local (D-154)."""
    return os.environ.get("BENJI_WEB_SEARCH", "").strip().lower() != "local"


def streaming_enabled() -> bool:
    """BENJI_STREAM=1 (or true/yes/on) streams; anything else keeps every call one blocking request."""
    return _switch("BENJI_STREAM")


def caching_enabled() -> bool:
    """On by default (cache_control on Anthropic requests); BENJI_PROMPT_CACHE=0 (or false/no/off)
    turns it off."""
    return os.environ.get("BENJI_PROMPT_CACHE", "1").strip().lower() not in ("0", "false", "no", "off")


EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")
DEFAULT_EFFORT = "low"
_MODEL_ID = re.compile(r"claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?")
_effort_noted: set[str] = set()


def effort_level() -> str:
    """BENJI_EFFORT, or low; an unknown value falls back to low with one stderr note."""
    raw = os.environ.get("BENJI_EFFORT", "").strip().lower()
    if not raw or raw in EFFORT_LEVELS:
        return raw or DEFAULT_EFFORT
    if raw not in _effort_noted:
        _effort_noted.add(raw)
        print(f"[Benji] BENJI_EFFORT={raw!r} is not one of {', '.join(EFFORT_LEVELS)}; "
              f"using {DEFAULT_EFFORT}", file=sys.stderr)
    return DEFAULT_EFFORT


def effort_for(model: str, level: str) -> str | None:
    """The effort to send for this model id, or None when the model takes no effort field.
    Claude 5 family and Opus/Sonnet 4.6 and later accept it; Sonnet/Haiku 4.5 and older answer it
    with a 400, and so might an id this doesn't recognise, so those get none. xhigh came with Opus
    4.7, so a 4.6 model gets high instead."""
    m = _MODEL_ID.fullmatch(model.strip().lower())
    if not m or level not in EFFORT_LEVELS:
        return None
    major, minor = int(m.group(2)), int(m.group(3) or 0)
    if major >= 5:
        return level
    if major == 4 and minor >= 6:
        return "high" if level == "xhigh" and minor == 6 else level
    return None


# What a connection that dies after it was made raises: urllib wraps only the failure to make one
# (D-177: the Mac slept, the Wi-Fi changed, the read timed out). Named last, after urllib's own errors.
_DROPPED = (OSError, http.client.HTTPException)


def _post(url: str, headers: dict[str, str], payload: dict[str, Any], retry: bool = False,
          no_retry_codes: frozenset[str] = frozenset()) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    if retry:       # the OpenAI-format policy: see _open
        try:
            with _open(req, url, True, no_retry_codes=no_retry_codes) as resp:
                try:
                    return json.loads(resp.read().decode("utf-8"))
                except ValueError:
                    raise ProviderError(f"{_host(url)} answered with something that is not JSON") from None
        except _DROPPED as e:
            raise ProviderError(f"network error calling {url}: {type(e).__name__}") from None
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise ProviderError(f"HTTP {e.code} from {url}:\n{body}") from None
    except urllib.error.URLError as e:
        raise ProviderError(f"network error calling {url}: {e.reason}") from None
    except _DROPPED as e:
        raise ProviderError(f"network error calling {url}: {type(e).__name__}") from None


class Abort:
    """Lets another thread stop a streaming call (a cancelled turn). fire() shuts the live
    connection down, which wakes a read blocked on it; once fired, no new stream starts."""

    def __init__(self):
        self._lock = threading.Lock()
        self._resp = None
        self.fired = False

    def watch(self, resp) -> bool:
        with self._lock:
            if self.fired:
                return False
            self._resp = resp
            return True

    def release(self) -> None:
        """Called before the response is closed, so fire() never touches a reused fd."""
        with self._lock:
            self._resp = None

    def fire(self) -> None:
        with self._lock:
            self.fired = True
            if self._resp is not None:
                _shutdown(self._resp)


def _shutdown(resp) -> None:
    try:
        sock = socket.socket(fileno=os.dup(resp.fileno()))
    except (OSError, ValueError):
        return
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    finally:
        sock.close()


def _sse(resp) -> Iterator[tuple[str, str]]:
    """Server-sent events as (event name, data); comments and empty data are skipped."""
    event, data = "", []
    for raw in resp:
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if not line:
            if data:
                yield event, "\n".join(data)
            event, data = "", []
        elif line.startswith(":"):
            continue
        else:
            field, _, value = line.partition(":")
            value = value[1:] if value.startswith(" ") else value
            if field == "event":
                event = value
            elif field == "data":
                data.append(value)
    if data:
        yield event, "\n".join(data)


class _Stop(Exception):
    """Raised by an event handler when the stream is complete (message_stop, [DONE])."""


def _stream(url: str, headers: dict[str, str], payload: dict[str, Any],
            on_event: Callable[[str, dict], None], whole: Callable[[dict], None],
            cancelled: Callable[[], bool], abort: Abort | None, retry: bool = False,
            no_retry_codes: frozenset[str] = frozenset()) -> bool:
    """POST a streaming request and feed its events to on_event (a plain JSON reply goes to
    whole). Returns False if a cancel stopped it; the connection is closed either way."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    if cancelled() or (abort is not None and abort.fired):
        return False
    if retry:
        try:
            resp = _open(req, url, True, lambda: cancelled() or (abort is not None and abort.fired), no_retry_codes)
        except _DROPPED as e:
            raise ProviderError(f"network error calling {url}: {type(e).__name__}") from None
    else:
        try:
            resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise ProviderError(f"HTTP {e.code} from {url}:\n{body}") from None
        except urllib.error.URLError as e:
            raise ProviderError(f"network error calling {url}: {e.reason}") from None
        except _DROPPED as e:
            raise ProviderError(f"network error calling {url}: {type(e).__name__}") from None
    stopped = lambda: cancelled() or (abort is not None and abort.fired)
    try:
        if abort is not None and not abort.watch(resp):
            return False
        if "text/event-stream" not in resp.headers.get("content-type", ""):
            whole(json.loads(resp.read().decode("utf-8")))   # the server didn't stream
            return not stopped()
        for _event, text in _sse(resp):
            if stopped():
                return False
            if text.strip() == "[DONE]":
                break
            try:
                event = json.loads(text)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                try:
                    on_event(_event, event)
                except _Stop:
                    break
        return not stopped()
    except (OSError, ValueError, http.client.HTTPException) as e:
        if stopped():
            return False
        raise ProviderError(f"stream from {url} broke off: {e}") from None
    finally:
        if abort is not None:
            abort.release()
        resp.close()


class AnthropicProvider:
    name = "claude"
    API = "https://api.anthropic.com/v1/messages"

    def __init__(self, api_key: str, model: str):
        self.api_key = api_key
        self.model = model

    def _messages(self, neutral: list[dict]) -> list[dict]:
        out: list[dict] = []
        i = 0
        while i < len(neutral):
            m = neutral[i]
            role = m["role"]
            if role == "user":
                content = [
                    {"type": "image",
                     "source": {"type": "base64", "media_type": im["media_type"], "data": im["data"]}}
                    for im in m.get("images", [])
                ]
                content.append({"type": "text", "text": m["text"]})
                out.append({"role": "user", "content": content})
                i += 1
            elif role == "assistant":
                content: list[dict] = []
                if m.get("text"):
                    content.append({"type": "text", "text": m["text"]})
                for tc in m.get("tool_calls", []):
                    content.append({"type": "tool_use", "id": tc["id"],
                                    "name": tc["name"], "input": tc["input"]})
                out.append({"role": "assistant", "content": content})
                i += 1
            elif role == "tool":
                # Merge consecutive tool results into one user message.
                results = []
                while i < len(neutral) and neutral[i]["role"] == "tool":
                    t = neutral[i]
                    content = t["content"]
                    if t.get("images"):     # a screen step's fresh screenshot (D-123)
                        content = [{"type": "text", "text": content}] + [
                            {"type": "image",
                             "source": {"type": "base64", "media_type": im["media_type"], "data": im["data"]}}
                            for im in t["images"]]
                    results.append({"type": "tool_result", "tool_use_id": t["id"],
                                    "content": content})
                    i += 1
                out.append({"role": "user", "content": results})
            else:
                i += 1
        return out

    def _payload(self, system: str, neutral: list[dict], tools: list[dict]) -> dict:
        payload = {
            "model": self.model,
            "max_tokens": ANTHROPIC_MAX_TOKENS,
            "system": system,
            "messages": self._messages(neutral),
            "tools": [dict(SERVER_WEB_SEARCH) if t["name"] == "web_search" and server_search_enabled()
                      else {"name": t["name"], "description": t["description"], "input_schema": t["parameters"]}
                      for t in tools],
        }
        if caching_enabled():
            # The stable base is cached; this turn's rules follow it, unmarked.
            base, turn = getattr(system, "base", system), getattr(system, "turn", "")
            blocks = ([{"type": "text", "text": base, "cache_control": EPHEMERAL}] if base else []) + (
                [{"type": "text", "text": turn}] if turn else [])
            if blocks:
                payload["system"] = blocks
            if payload["tools"]:
                payload["tools"][-1] = {**payload["tools"][-1], "cache_control": EPHEMERAL}
            self._mark_history(payload["messages"], neutral)
        effort = effort_for(self.model, effort_level())
        if effort:
            payload["output_config"] = {"effort": effort}
        return payload

    def _mark_history(self, wire: list[dict], neutral: list[dict]) -> None:
        """Breakpoints on the conversation. One on the last block of the last message before the live
        one (the newest neutral user message), so earlier turns are read from cache. One on the newest
        tool results, so a tool loop reads its own earlier steps: without it a job, which is a single
        user message followed by steps, sends its whole history at full price on every call (D-177).
        A step with a screenshot isn't marked: the next step's picture replaces it, so it is never read."""
        live = next((i for i in range(len(neutral) - 1, -1, -1) if neutral[i]["role"] == "user"), None)
        if live:
            # A user message ends any run of tool results, so the prefix maps to the same wire messages.
            before = len(self._messages(neutral[:live]))
            content = wire[before - 1]["content"] if before else []
            if content:
                content[-1] = {**content[-1], "cache_control": EPHEMERAL}
        last_run = []
        for m in reversed(neutral):
            if m["role"] != "tool":
                break
            last_run.append(m)
        if last_run and not any(m.get("images") for m in last_run):
            content = wire[-1]["content"]
            content[-1] = {**content[-1], "cache_control": EPHEMERAL}

    def _headers(self) -> dict[str, str]:
        return {
            "x-api-key": self.api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }

    def complete(self, system: str, neutral: list[dict], tools: list[dict]) -> dict:
        payload = self._payload(system, neutral, tools)
        resp = _post(self.API, self._headers(), payload)
        return self._result(self._resumed(payload, resp))

    def _resumed(self, payload: dict, resp: dict) -> dict:
        """A turn a server-side search paused (pause_turn), resumed by sending what it wrote so far
        back as the assistant's message, a few times at most. One response: every part's content in
        order, the usages added up."""
        content, usage = list(resp.get("content") or []), dict(resp.get("usage") or {})
        for _ in range(MAX_CONTINUATIONS):
            if resp.get("stop_reason") != "pause_turn":
                break
            more = {**payload, "messages": payload["messages"] + [{"role": "assistant", "content": list(content)}]}
            resp = _post(self.API, self._headers(), more)
            content += resp.get("content") or []
            for k, v in (resp.get("usage") or {}).items():
                if isinstance(v, int):
                    usage[k] = usage.get(k, 0) + v
        return {**resp, "content": content, "usage": usage}

    @staticmethod
    def _result(resp: dict) -> dict:
        text_parts, tool_calls, searches, by_id = [], [], [], {}
        for block in resp.get("content", []):
            kind = block.get("type")
            if kind == "text":
                text_parts.append(block["text"])
            elif kind == "tool_use":
                tool_calls.append({"id": block["id"], "name": block["name"],
                                   "input": block.get("input", {})})
            elif kind == "server_tool_use" and block.get("name") == "web_search":
                by_id[block.get("id")] = str((block.get("input") or {}).get("query", ""))
            elif kind == "web_search_tool_result" and block.get("tool_use_id") in by_id:
                found = block.get("content")
                hosts = [h for h in dict.fromkeys((urlparse(str(r.get("url", ""))).hostname or "").casefold()
                                                  for r in found if isinstance(r, dict)) if h] \
                    if isinstance(found, list) else []
                error = "" if isinstance(found, list) else str((found or {}).get("error_code") or "unavailable")
                searches.append({"query": by_id[block["tool_use_id"]], "hosts": hosts, "error": error})
                text_parts = []         # what came before the search was narration, not the answer
        if resp.get("stop_reason") == "refusal" and not tool_calls and not "".join(text_parts).strip():
            raise ProviderError(SAFETY_STOP)       # D-172: the filter ended the reply (also after a search); say so
        out = {"text": "".join(text_parts), "tool_calls": tool_calls, "usage": usage_mod.from_anthropic(resp)}
        if searches:
            out["searches"] = searches
        return out

    def stream(self, system: str, neutral: list[dict], tools: list[dict],
               on_text: Callable[[str], None], cancelled: Callable[[], bool] = lambda: False,
               abort: Abort | None = None, on_drop: Callable[[], None] = lambda: None) -> dict:
        """Messages API with stream: true. Text deltas go to on_text as they arrive; tool_use
        inputs are put together from their input_json_delta pieces. Text streamed before a
        server-side search is taken back with on_drop: it was narration, not the answer."""
        plain = self._payload(system, neutral, tools)
        payload = {**plain, "stream": True}
        blocks: dict[int, dict] = {}
        usage: dict = {}
        stop: dict = {}
        result: dict = {}
        said: list[str] = []

        def text(piece: str) -> None:
            if piece and not cancelled():
                said.append(piece)
                on_text(piece)

        def on_event(_name: str, ev: dict) -> None:
            kind = ev.get("type")
            if kind == "message_start":
                usage.update((ev.get("message") or {}).get("usage") or {})
            elif kind == "content_block_start":
                block = dict(ev.get("content_block") or {})
                block["json"] = ""
                blocks[ev.get("index", len(blocks))] = block
                if block.get("type") == "text":
                    text(block.get("text", ""))
                elif block.get("type") == "server_tool_use" and said:
                    said.clear()
                    on_drop()
            elif kind == "content_block_delta":
                block = blocks.setdefault(ev.get("index", 0), {"type": "text", "text": "", "json": ""})
                delta = ev.get("delta") or {}
                if delta.get("type") == "text_delta":
                    block["text"] = block.get("text", "") + delta.get("text", "")
                    text(delta.get("text", ""))
                elif delta.get("type") == "input_json_delta":
                    block["json"] += delta.get("partial_json", "")
                elif delta.get("type") == "citations_delta":
                    block.setdefault("citations", []).append(delta.get("citation"))
            elif kind == "message_delta":
                usage.update(ev.get("usage") or {})
                stop.update(ev.get("delta") or {})
            elif kind == "message_stop":
                raise _Stop
            elif kind == "error":
                raise ProviderError(f"stream error from {self.API}:\n{json.dumps(ev)}")

        def whole(resp: dict) -> None:
            result.update(self._result(resp))
            if not result["tool_calls"]:
                text(result["text"])

        finished = _stream(self.API, self._headers(), payload, on_event, whole, cancelled, abort)
        if not result:
            content = []
            for _, block in sorted(blocks.items()):
                kept = {k: v for k, v in block.items() if k != "json"}
                if block.get("type") in ("tool_use", "server_tool_use"):
                    content.append({**kept, "input": _json_object(block["json"], block.get("input"))})
                elif block.get("type") in ("text", "web_search_tool_result"):
                    content.append(kept)
            resp = {"content": content, "usage": usage, "stop_reason": stop.get("stop_reason")}
            if finished and resp["stop_reason"] == "pause_turn" and not cancelled():
                # A paused search: the rest comes in one plain call, and the answer is what follows it.
                resp = self._resumed(plain, resp)
                result.update(self._result(resp))
                if said:
                    said.clear()
                    on_drop()
                if not result["tool_calls"]:
                    text(result["text"])
            else:
                result.update(self._result(resp))
        if not finished:
            return {**result, "tool_calls": [], "cancelled": True}
        return result


def _screenshot_message(images: list[dict]) -> dict:
    """The screen after a step, for an OpenAI-compatible server (tool messages hold text only)."""
    return {"role": "user", "content": [{"type": "text", "text": "[the screen after that step]"}] + [
        {"type": "image_url", "image_url": {"url": f"data:{im['media_type']};base64,{im['data']}"}}
        for im in images]}


class _ThinkFilter:
    """Takes <think>…</think> out of a streamed answer. Some local models (and distills of
    reasoning models) put their reasoning in the text itself; it is never shown, spoken or kept.
    Used for the local presets only: a hosted API sends its reasoning in a field of its own.
    A tag cut in two by a chunk boundary is held back until it can be told."""
    OPEN, CLOSE = "<think>", "</think>"

    def __init__(self) -> None:
        self.buf, self.inside, self.trim = "", False, False

    def feed(self, piece: str) -> str:
        self.buf += piece
        out: list[str] = []
        while True:
            if self.inside:
                i = self.buf.find(self.CLOSE)
                if i < 0:
                    self.buf = self.buf[-(len(self.CLOSE) - 1):]
                    break
                self.buf, self.inside, self.trim = self.buf[i + len(self.CLOSE):], False, True
                continue
            i = self.buf.find(self.OPEN)
            if i >= 0:
                out.append(self.buf[:i])
                self.buf, self.inside = self.buf[i + len(self.OPEN):], True
                continue
            hold = next((k for k in range(len(self.OPEN) - 1, 0, -1) if self.buf.endswith(self.OPEN[:k])), 0)
            out.append(self.buf[:len(self.buf) - hold])
            self.buf = self.buf[len(self.buf) - hold:]
            break
        text = "".join(out)
        if self.trim and text:
            text, self.trim = text.lstrip("\n"), False
        return text

    def flush(self) -> str:
        rest, self.buf = ("" if self.inside else self.buf), ""
        return rest


_THINK = re.compile(r"<think>.*?(?:</think>\s*|$)", re.S)
_FINISH_FAILS = {
    "length": "ran out of output tokens before it answered (thinking counts); raise BENJI_MAX_TOKENS",
    "insufficient_system_resource": "stopped early because the server ran short of resources; try again",
    "content_filter": "withheld its answer (the provider's content filter)",
    "sensitive": "withheld its answer (the provider's content filter)",
    "network_error": "lost its connection while answering; try again",
}


class OpenAIProvider:
    """OpenAI Chat Completions, or any server that speaks the same format (hosted open-weight
    models, Ollama, llama.cpp, LM Studio, MLX) via base_url.

    With a `preset` (benji/presets.py: DeepSeek, GLM, Kimi, Qwen, Ollama, LM Studio) it follows that
    provider's documented quirks (D-147): the max-tokens parameter it names, its thinking switch,
    stream_options only where documented, a short retry on 429 and 5xx, short error messages, a
    refusal to send a picture to a model that can't read one, and reasoning kept out of the answer.
    Without one it is the provider it always was."""
    name = "openai"
    API = "https://api.openai.com/v1/chat/completions"
    DEFAULT_MAX_TOKENS = 8192

    def __init__(self, api_key: str, model: str, base_url: str | None = None, preset=None,
                 thinking: str = "off", max_tokens: int | None = None, vision: bool = True):
        self.api_key = api_key
        self.model = model
        self.url = base_url.rstrip("/") + "/chat/completions" if base_url else self.API
        self.preset = preset
        self.vision = vision
        self.thinking = thinking
        self.max_tokens = max_tokens or (preset.max_tokens if preset is not None else self.DEFAULT_MAX_TOKENS)
        if preset is not None:
            self.name = preset.name
        # reasoning is handed to the agent only when the server wants it sent back (DeepSeek, with
        # thinking on); otherwise it is dropped on arrival
        self.replay = (preset.replay if preset is not None and (thinking != "off" or preset.replay_always)
                       else "none")

    # ---- the request ---------------------------------------------------------------------------

    def _messages(self, system: str, neutral: list[dict]) -> list[dict]:
        out: list[dict] = [{"role": "system", "content": system}]
        # A tool message holds text only here, so a screen step's screenshot (D-123) follows the
        # run of tool results as a user message of its own.
        screenshots: list[dict] = []
        for m in neutral:
            role = m["role"]
            if role != "tool" and screenshots:
                out.append(_screenshot_message(screenshots))
                screenshots = []
            if role == "user":
                images = m.get("images", [])
                if images:
                    parts: list[dict] = [{"type": "text", "text": m["text"]}]
                    parts += [{"type": "image_url",
                               "image_url": {"url": f"data:{im['media_type']};base64,{im['data']}"}}
                              for im in images]
                    out.append({"role": "user", "content": parts})
                else:
                    out.append({"role": "user", "content": m["text"]})
            elif role == "assistant":
                msg: dict[str, Any] = {"role": "assistant", "content": m.get("text") or None}
                tcs = m.get("tool_calls", [])
                if tcs:
                    msg["tool_calls"] = [
                        {"id": tc["id"], "type": "function",
                         "function": {"name": tc["name"], "arguments": json.dumps(tc["input"])}}
                        for tc in tcs
                    ]
                if m.get("reasoning") and self.replay != "none":
                    msg["reasoning_content"] = m["reasoning"]
                out.append(msg)
            elif role == "tool":
                out.append({"role": "tool", "tool_call_id": m["id"], "content": m["content"]})
                screenshots += m.get("images", [])
        if screenshots:
            out.append(_screenshot_message(screenshots))
        return out

    def _payload(self, system: str, neutral: list[dict], tools: list[dict]) -> dict:
        payload = {
            "model": self.model,
            "messages": self._messages(system, neutral),
            "tools": [{"type": "function",
                       "function": {"name": t["name"], "description": t["description"],
                                    "parameters": t["parameters"]}} for t in tools],
        }
        if self.preset is not None:
            payload[self.preset.max_tokens_param] = self.max_tokens
            payload.update(self.preset.thinking(self.model, self.thinking))
        return payload

    def _headers(self) -> dict[str, str]:
        headers = {"content-type": "application/json"}
        if self.api_key:  # local servers often need no key
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _check_images(self, neutral: list[dict]) -> None:
        """A model that can't read pictures is told so before anything is sent, not by the server
        in the middle of a turn. (The app keeps Screen off for such a model; this is the last line.)"""
        if self.vision or not any(m.get("images") for m in neutral):
            return
        raise ProviderError(f"{self.model} can't read images, so Benji did not send the picture. "
                            "Use a model that can, or set BENJI_VISION=1 if you know this one can.")

    # ---- errors --------------------------------------------------------------------------------

    @property
    def _no_retry(self) -> frozenset[str]:
        return self.preset.no_retry_codes if self.preset is not None else frozenset()

    def _explain(self, err: ProviderError) -> ProviderError:
        """A 4xx that says the model has no tools or no pictures becomes a plain sentence."""
        if self.preset is None:
            return err
        text = str(err)
        low = text.lower()
        if re.match(r"HTTP (400|404|422)\b", text):
            if re.search(r"(tool|function)", low) and re.search(r"(not support|unsupported|does not support|doesn't support|invalid)", low):
                return ProviderError(f"{self.model} does not accept tool calls on {self.preset.label}, and Benji "
                                     f"needs them. Choose a model that does with BENJI_MODEL. ({text[:200]})")
            if re.search(r"(image|vision|multimodal|multi-modal|image_url)", low) and re.search(r"(not support|unsupported|invalid)", low):
                return ProviderError(f"{self.model} on {self.preset.label} does not accept images. Set BENJI_VISION=0 "
                                     f"to keep Screen off, or choose a model that reads images. ({text[:200]})")
        return err

    # ---- the reply -----------------------------------------------------------------------------

    def complete(self, system: str, neutral: list[dict], tools: list[dict]) -> dict:
        self._check_images(neutral)
        try:
            body = self._payload(system, neutral, tools)
            resp = (_post(self.url, self._headers(), body) if self.preset is None else
                    _post(self.url, self._headers(), body, retry=True, no_retry_codes=self._no_retry))
        except ProviderError as e:
            raise self._explain(e) from None
        return self._result(resp)

    def _result(self, resp: dict) -> dict:
        choice = (resp.get("choices") or [{}])[0]
        msg = choice.get("message", {})
        tool_calls = []
        for n, tc in enumerate(msg.get("tool_calls") or []):
            fn = tc.get("function", {})
            raw = fn.get("arguments")
            if isinstance(raw, dict):  # some compatible servers send an object, not a string
                args = raw
            else:
                try:
                    args = json.loads(raw or "{}")
                except json.JSONDecodeError:
                    args = {}
            # Tool results are matched by id, so never leave it empty.
            tool_calls.append({"id": tc.get("id") or f"call_{n}", "name": fn.get("name", ""),
                               "input": args})
        text = msg.get("content") or ""
        out = {"text": text, "tool_calls": tool_calls, "usage": usage_mod.from_openai(resp)}
        if self.preset is not None:
            out["text"] = _THINK.sub("", text) if self.preset.local and "<think>" in text else text
            self._reasoning(out, next((msg[f] for f in self.preset.reasoning_fields
                                       if isinstance(msg.get(f), str) and msg[f]), ""))
            self._finished(out, choice.get("finish_reason"))
        return out

    def _reasoning(self, out: dict, reasoning: str) -> None:
        """The server's reasoning goes nowhere (never into the text) unless it has to be sent back."""
        if reasoning and self.replay != "none":
            out["reasoning"] = reasoning

    def _finished(self, out: dict, reason) -> None:
        """An empty reply that ended for a reason other than finishing is an error to say plainly."""
        if not out["text"].strip() and not out["tool_calls"] and reason in _FINISH_FAILS:
            raise ProviderError(f"{self.model} {_FINISH_FAILS[reason]}.")

    def stream(self, system: str, neutral: list[dict], tools: list[dict],
               on_text: Callable[[str], None], cancelled: Callable[[], bool] = lambda: False,
               abort: Abort | None = None) -> dict:
        """Chat completions with stream: true; usage comes in the last chunk
        (stream_options.include_usage, where the server documents it). Tool calls are put together by
        their index, whether the server sends their arguments in pieces or whole."""
        self._check_images(neutral)
        payload = {**self._payload(system, neutral, tools), "stream": True}
        if self.preset is None or self.preset.stream_options:
            payload["stream_options"] = {"include_usage": True}
        parts: list[str] = []
        reasoning: list[str] = []
        calls: dict[int, dict] = {}
        usage: dict = {}
        finish: list = []
        result: dict = {}
        think = _ThinkFilter() if self.preset is not None and self.preset.local else None

        def text(piece) -> None:
            if isinstance(piece, str) and piece and not cancelled():
                on_text(piece)

        def on_event(_name: str, chunk: dict) -> None:
            if chunk.get("error"):
                raise ProviderError(f"stream error from {_host(self.url)}: {_error_text(json.dumps(chunk))}"
                                    if self.preset is not None else
                                    f"stream error from {self.url}:\n{json.dumps(chunk)}")
            if chunk.get("usage"):
                usage.clear()
                usage.update(chunk["usage"])
            for choice in chunk.get("choices") or []:
                if choice.get("index", 0) != 0:
                    continue
                if isinstance(choice.get("usage"), dict) and choice["usage"] and not chunk.get("usage"):
                    usage.clear()           # Kimi's guide shows usage inside the last choice too
                    usage.update(choice["usage"])
                if choice.get("finish_reason"):
                    finish.append(choice["finish_reason"])
                delta = choice.get("delta") or {}
                if self.preset is not None:
                    for f in self.preset.reasoning_fields:
                        if isinstance(delta.get(f), str):
                            reasoning.append(delta[f])
                piece = delta.get("content")
                if isinstance(piece, str):
                    if think is not None:
                        piece = think.feed(piece)
                    parts.append(piece)
                    text(piece)
                for n, tc in enumerate(delta.get("tool_calls") or []):
                    call = calls.setdefault(tc.get("index", n), {"function": {}})
                    if tc.get("id"):
                        call["id"] = tc["id"]
                    fn = tc.get("function") or {}
                    if fn.get("name"):
                        call["function"]["name"] = fn["name"]
                    args = fn.get("arguments")
                    if isinstance(args, dict):
                        call["function"]["arguments"] = args
                    elif isinstance(args, str):
                        call["function"]["arguments"] = call["function"].get("arguments", "") + args

        def whole(resp: dict) -> None:
            result.update(self._result(resp))
            if not result["tool_calls"]:
                text(result["text"])

        try:
            finished = _stream(self.url, self._headers(), payload, on_event, whole, cancelled, abort,
                               retry=self.preset is not None, no_retry_codes=self._no_retry)
        except ProviderError as e:
            raise self._explain(e) from None
        if think is not None:
            tail = think.flush()
            if tail:
                parts.append(tail)
                text(tail)
        if not result:
            message = {"content": "".join(parts) or None,
                       "tool_calls": [calls[i] for i in sorted(calls)]}
            result.update(self._result({"choices": [{"message": message}], "usage": usage}))
            if self.preset is not None and finished:
                self._reasoning(result, "".join(reasoning))
                self._finished(result, finish[-1] if finish else None)
        if not finished:
            return {**result, "tool_calls": [], "cancelled": True}
        return result


def _json_object(raw: str, fallback) -> dict:
    """A streamed tool input: the joined input_json_delta pieces (empty means no input)."""
    if not raw:
        return fallback if isinstance(fallback, dict) else {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def make_provider(provider: str, api_key: str, model: str, base_url: str | None = None, *,
                  thinking: str = "off", max_tokens: int | None = None, vision: bool = True):
    if provider == "claude":
        return AnthropicProvider(api_key, model)
    if provider == "openai":
        return OpenAIProvider(api_key, model, base_url, vision=vision)
    preset = presets.PRESETS.get(provider)
    if preset is not None:
        return OpenAIProvider(api_key, model, base_url or preset.endpoints["intl"], preset=preset,
                              thinking=thinking, max_tokens=max_tokens, vision=vision)
    raise ProviderError(f"unknown provider: {provider}")
