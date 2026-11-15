"""Checks for the open-model providers (D-147): DeepSeek, GLM, Kimi, Qwen, Ollama and LM Studio as
presets of the OpenAI-format provider. Called from selftest.py.

No live API and no key: a small fake OpenAI-compatible server (class Fake) stands in for each
provider and reproduces what that provider's own documentation (read 2026-11-05, see
docs/providers.md) says it does: the reasoning field, how tool-call deltas arrive,
where usage sits, the parameter it wants for the output limit, what it refuses (a `thinking`
switch it doesn't have, a picture for a text-only model, a model without tools, a reasoning field
that was not sent back), its 429 shapes. Where a doc leaves a fact open (DeepSeek's error body, say)
the fake says so and uses the OpenAI shape. Passing here means Benji does what the docs say; it
does not mean the real servers agree (they are not live-verified).
"""

from __future__ import annotations

import io
import json
import os
import re
import tempfile
import threading
import time
from contextlib import redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CANARY = "CANARY-9c41"             # the user's words, a page, a file
THOUGHT = "REASONING-5b2e"          # what a model "thought": never shown, spoken, logged or kept
KEYWORD = "KEYCANARY-77d0"          # inside every fake key
# a 1x1 PNG, the "screenshot"
_PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478"
                     "9c6360606060000000050001a5f645400000000049454e44ae426082")

PROVIDER_VARS = ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "DEEPSEEK_API_KEY", "ZAI_API_KEY", "ZHIPUAI_API_KEY",
                 "MOONSHOT_API_KEY", "DASHSCOPE_API_KEY", "BENJI_API_KEY", "BENJI_PROVIDER", "BENJI_MODEL",
                 "BENJI_BASE_URL", "BENJI_REGION", "BENJI_THINKING", "BENJI_VISION", "BENJI_MAX_TOKENS",
                 "BENJI_STREAM", "BENJI_PROMPT_CACHE", "PAL_PROVIDER", "PAL_MODEL", "PAL_BASE_URL", "HOME")

# What each fake does, from the provider's docs. `usage`: (prompt, cached, written, completion).
PROFILES: dict[str, dict] = {
    "deepseek": dict(
        model="deepseek-flash", key="sk-" + KEYWORD + "-deepseek", max_param="max_tokens",
        vision={"deepseek-flash"}, no_tools=set(), stream_options=True, usage_in_last_choice=True,
        usage=(100, 40, 0, 7), tool_style="delta", err="openai", replay_needed=True,
        thinking_probe={"on": ("thinking", {"type": "enabled"}), "off": ("thinking", {"type": "disabled"})},
        quota=dict(status=402, code="", type="", message="Insufficient Balance"),
        busy=dict(status=429, code="", type="", message="Rate Limit Reached"),
    ),
    "glm": dict(
        model="glm-5.3-flash", key=KEYWORD + "0123456789abcdef0123456789.AbCdEfGhIjKl", max_param="max_tokens",
        vision={"glm-5.3-flash"}, no_tools=set(), stream_options=False, usage_in_last_choice=True,
        usage=(100, 40, 0, 7), tool_style="whole", err="glm", replay_needed=False,
        thinking_probe={"on": ("reasoning_effort", "high"), "off": ("reasoning_effort", "low")},
        quota=dict(status=429, code="1113", type="", message="Insufficient balance or no resource package"),
        busy=dict(status=429, code="1302", type="", message="High concurrency usage of this API"),
    ),
    "kimi": dict(
        model="kimi-k3.1-pro", key="sk-" + KEYWORD + "-kimi", max_param="max_completion_tokens",
        vision={"kimi-k3.1-pro"}, no_tools=set(), stream_options=True, usage_in_last_choice=False,
        usage=(100, 30, 10, 7), tool_style="delta", err="kimi", replay_needed=True,
        thinking_probe={"on": ("reasoning_effort", "high"), "off": ("reasoning_effort", "low")},
        quota=dict(status=429, code="", type="exceeded_current_quota_error", message="Your account is suspended"),
        busy=dict(status=429, code="", type="engine_overloaded_error", message="engine busy",
                  headers={"Retry-After": "3"}),
    ),
    "qwen": dict(
        model="qwen3.8-flash", key="sk-" + KEYWORD + "-qwen", max_param="max_completion_tokens",
        vision={"qwen3.8-flash"}, no_tools=set(), stream_options=True, usage_in_last_choice=False,
        usage=(100, 40, 0, 7), tool_style="delta-empty-id", err="qwen", replay_needed=False,
        thinking_probe={"on": ("enable_thinking", True), "off": ("enable_thinking", False)},
        quota=dict(status=403, code="Arrearage", type="Arrearage", message="Access denied, please make sure your account is in good standing."),
        busy=dict(status=429, code="Throttling.RateQuota", type="Throttling.RateQuota", message="Requests rate limit exceeded"),
    ),
    "ollama": dict(
        model="llama3.2", key="", max_param="max_tokens",
        vision=set(), no_tools={"gemma-no-tools"}, stream_options=False, usage_in_last_choice=True,
        usage=(100, 0, 0, 7), tool_style="delta", err="openai", replay_needed=False, think_tags=True,
        thinking_probe={}, quota=None,
        busy=dict(status=503, code="", type="", message="server busy"),
    ),
    "lmstudio": dict(
        model="qwen2.5-vl-7b", key="", max_param="max_tokens",
        vision={"qwen2.5-vl-7b"}, no_tools=set(), stream_options=False, usage_in_last_choice=True,
        usage=(100, 0, 0, 7), tool_style="delta", err="flat", replay_needed=False, think_tags=True,
        thinking_probe={}, quota=None,
        busy=dict(status=500, code="", type="", message="model crashed"),
    ),
}
ANTHROPIC_ONLY = ("cache_control", "output_config", "anthropic_version", "anthropic-version")


def _error_body(kind: str, status: int, code: str, typ: str, message: str, echo: str = "") -> dict:
    extra = {"debug_echo": echo} if echo else {}
    if kind == "glm":
        return {"error": {"code": code, "message": message}, **extra}
    if kind == "kimi":
        return {"error": {"type": typ, "message": message}, **extra}
    if kind == "qwen":
        return {"error": {"message": message, "type": typ or "invalid_request_error", "param": None, "code": code or None}, **extra}
    if kind == "flat":                      # a plain string, as some local servers send
        return {"error": message, **extra}
    return {"error": {"message": message, "type": typ or "invalid_request_error", "code": code or None}, **extra}


class Fake:
    """One provider's fake server. `script(match, *replies)` queues replies for the request whose
    last user message is `match` (or holds it, when it starts with "~"); a reply is a dict: text, reasoning, tools
    [(name, args)], or an error {status, code, type, message, headers}. With nothing queued it
    answers "ok"."""

    def __init__(self, name: str):
        self.name, self.p = name, PROFILES[name]
        self.first_user = False         # match on the conversation's first user message, else its last
        self.requests: list[dict] = []
        self.queues: list[tuple[str, list]] = []
        self.lock = threading.Lock()
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["content-length"])))
                fake.handle(self, body)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_port}/v1"
        self.host = f"127.0.0.1:{self.httpd.server_port}"

    def close(self) -> None:
        self.httpd.shutdown()

    def script(self, match: str, *replies) -> None:
        with self.lock:
            self.queues.append((match, list(replies)))

    def _pick(self, body: dict) -> dict:
        users = [m for m in body["messages"] if m["role"] == "user" and
                 (isinstance(m["content"], str) or any(part.get("type") == "text" and part["text"] != "[the screen after that step]"
                                                       for part in m["content"]))]
        first = users[0] if self.first_user else users[-1]
        text = first["content"] if isinstance(first["content"], str) else " ".join(
            part["text"] for part in first["content"] if part.get("type") == "text")
        with self.lock:
            for match, q in self.queues:
                if (text == match or (match.startswith("~") and match[1:] in text)) and q:
                    return q.pop(0)
        return {"text": "ok"}

    # ---- a request ---------------------------------------------------------------------------------

    def refuse(self, h, status: int, message: str, code: str = "", typ: str = "", headers=None) -> None:
        data = json.dumps(_error_body(self.p["err"], status, code, typ, message, echo=CANARY)).encode()
        h.send_response(status)
        h.send_header("content-type", "application/json")
        h.send_header("content-length", str(len(data)))
        for k, v in (headers or {}).items():
            h.send_header(k, v)
        h.end_headers()
        h.wfile.write(data)

    def quirks(self, h, body: dict) -> bool:
        """What this provider's docs say it refuses. True if the request was refused."""
        p, model = self.p, body.get("model", "")
        if p["key"] and h.headers.get("Authorization") != "Bearer " + p["key"]:
            self.refuse(h, 401, "Incorrect API key provided.", code="invalid_api_key")
            return True
        if not p["key"] and h.headers.get("Authorization"):
            self.refuse(h, 400, "unexpected key for a local server")
            return True
        dump = json.dumps(body)
        bad = next((k for k in ANTHROPIC_ONLY if f'"{k}"' in dump), None)
        if bad or "system" in body:
            self.refuse(h, 400, "unknown parameter " + (bad or "system"))
            return True
        if self.name not in ("ollama", "lmstudio"):        # the hosted APIs name their limit parameter
            other = "max_tokens" if p["max_param"] != "max_tokens" else "max_completion_tokens"
            if p["max_param"] not in body or other in body:
                self.refuse(h, 400, f"expected {p['max_param']} and not {other}")
                return True
        if "stream_options" in body and not p["stream_options"]:
            self.refuse(h, 400, "stream_options is not a parameter of this API", code="1210")
            return True
        if self.name == "kimi" and (set(body) & {"temperature", "top_p", "n", "thinking"}):
            self.refuse(h, 400, "invalid temperature: only 1 is allowed for this model", typ="invalid_request_error")
            return True
        if self.name == "glm" and model.startswith("glm-5.3") and (body.get("thinking") or {}).get("type") == "disabled":
            self.refuse(h, 400, "thinking cannot be disabled for this model", code="1214")
            return True
        if body.get("tools") and model in p["no_tools"]:
            self.refuse(h, 400, f"registry.example/library/{model} does not support tools")
            return True
        images = [part for m in body["messages"] if isinstance(m.get("content"), list)
                  for part in m["content"] if part.get("type") == "image_url"]
        if images and model not in p["vision"]:
            self.refuse(h, 400, "this model does not support image input", code="1210")
            return True
        if images and any(not part["image_url"]["url"].startswith("data:image/") for part in images):
            self.refuse(h, 400, "only base64 data URLs are accepted")
            return True
        if images and any(m["role"] in ("assistant", "system", "tool") and isinstance(m.get("content"), list)
                          for m in body["messages"]):
            self.refuse(h, 400, "images are allowed only in user messages")
            return True
        # DeepSeek (thinking on) and Kimi K3 (always) want the reasoning of earlier assistant turns back
        if body.get("tools") and (self.name == "kimi" or (self.name == "deepseek"
                                                          and (body.get("thinking") or {}).get("type") != "disabled")):
            if any(m["role"] == "assistant" and "reasoning_content" not in m for m in body["messages"]):
                self.refuse(h, 400, "the reasoning_content in the thinking mode must be passed back to the API")
                return True
        return False

    def handle(self, h, body: dict) -> None:
        with self.lock:
            self.requests.append({"body": body, "headers": dict(h.headers)})
        if self.quirks(h, body):
            return
        reply = self._pick(body)
        if "status" in reply:
            self.refuse(h, reply["status"], reply.get("message", "error"), reply.get("code", ""),
                        reply.get("type", ""), reply.get("headers"))
            return
        if body.get("stream"):
            self.stream(h, body, reply)
        else:
            self.whole(h, body, reply)

    # ---- replies -----------------------------------------------------------------------------------

    def _usage(self) -> dict:
        prompt, cached, written, completion = self.p["usage"]
        u = {"prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion}
        if self.name == "deepseek":
            u.update(prompt_cache_hit_tokens=cached, prompt_cache_miss_tokens=prompt - cached,
                     completion_tokens_details={"reasoning_tokens": 3})
        elif self.name == "kimi":
            u["prompt_tokens_details"] = {"cached_tokens": cached, "cache_write_tokens": written}
        else:
            u["prompt_tokens_details"] = {"cached_tokens": cached}
        return u

    def _text(self, reply: dict) -> str:
        text = reply.get("text", "")
        if self.p.get("think_tags") and reply.get("reasoning"):
            text = f"<think>{reply['reasoning']}</think>\n\n{text}"
        return text

    def whole(self, h, body: dict, reply: dict) -> None:
        msg: dict = {"role": "assistant", "content": self._text(reply) or None}
        if reply.get("reasoning") and not self.p.get("think_tags"):
            msg["reasoning_content"] = reply["reasoning"]
        calls = reply.get("tools") or []
        if calls:
            msg["tool_calls"] = [{"id": f"call_{i}", "type": "function",
                                  "function": {"name": n, "arguments": json.dumps(a)}} for i, (n, a) in enumerate(calls)]
        out = {"id": "x", "object": "chat.completion", "model": body["model"],
               "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if calls else reply.get("finish", "stop")}],
               "usage": self._usage()}
        data = json.dumps(out).encode()
        h.send_response(200)
        h.send_header("content-type", "application/json")
        h.send_header("content-length", str(len(data)))
        h.end_headers()
        h.wfile.write(data)

    def stream(self, h, body: dict, reply: dict) -> None:
        h.send_response(200)
        h.send_header("content-type", "text/event-stream")
        h.end_headers()

        def send(chunk) -> None:
            h.wfile.write(b"data: " + (chunk if isinstance(chunk, bytes) else json.dumps(chunk).encode()) + b"\n\n")
            h.wfile.flush()

        def chunk(delta: dict, finish=None, **more) -> dict:
            return {"id": "x", "object": "chat.completion.chunk", "model": body["model"],
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}], **more}

        if self.name == "deepseek":
            h.wfile.write(b": keep-alive\n\n")
        send(chunk({"role": "assistant", "content": ""}))
        if reply.get("reasoning") and not self.p.get("think_tags"):
            for i in range(0, len(reply["reasoning"]), 6):
                send(chunk({"reasoning_content": reply["reasoning"][i:i + 6]}))
        text = self._text(reply)
        for i in range(0, len(text), 4):
            send(chunk({"content": text[i:i + 4]}))
        calls = reply.get("tools") or []
        style = self.p["tool_style"]
        for idx, (name, args) in enumerate(calls):
            raw = json.dumps(args)
            if style == "whole":
                send(chunk({"tool_calls": [{"index": idx, "id": f"call_{idx}", "type": "function",
                                            "function": {"name": name, "arguments": raw}}]}))
            else:
                send(chunk({"tool_calls": [{"index": idx, "id": f"call_{idx}", "type": "function",
                                            "function": {"name": name, "arguments": ""}}]}))
        if style != "whole":       # the arguments, in pieces, the calls interleaved
            pieces = [json.dumps(a) for _, a in calls]
            for off in range(0, max((len(x) for x in pieces), default=0), 5):
                for idx, raw in enumerate(pieces):
                    if raw[off:off + 5]:
                        tc = {"index": idx, "function": {"arguments": raw[off:off + 5]}}
                        if style == "delta-empty-id":
                            tc["id"] = ""
                        send(chunk({"tool_calls": [tc]}))
        finish = "tool_calls" if calls else reply.get("finish", "stop")
        if self.p["usage_in_last_choice"]:
            send(chunk({}, finish, usage=self._usage()))
        else:
            send(chunk({}, finish))
            send({"id": "x", "object": "chat.completion.chunk", "choices": [], "usage": self._usage()})
        h.wfile.write(b"data: [DONE]\n\n")
        h.wfile.flush()


# ------------------------------------------------------------------------------------------------------------


def run(check, here: Path) -> None:
    from benji import audit, diagnose
    from benji import config as C
    from benji import gate as G
    from benji import presets as PR
    from benji import providers as P
    from benji import serve as S
    from benji import tools as T
    from benji import usage as U
    from benji import web as W
    from benji.agent import Agent
    from benji.__main__ import _where, startup_line

    print("open-model providers (D-147): presets, fake servers that reproduce each provider's documented quirks:")
    saved = {k: os.environ.get(k) for k in PROVIDER_VARS}
    os.environ.update(NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
    sleeps: list[float] = []
    real_sleep, P._sleep = P._sleep, sleeps.append
    try:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            # no test reads the user's ~/.benji.env: HOME is an empty folder
            home = base / "home"
            home.mkdir()
            os.environ["HOME"] = str(home)
            for k in PROVIDER_VARS:
                if k != "HOME":
                    os.environ.pop(k, None)
            config_checks(check, C, PR, base)
            table_checks(check, PR, P, U)
            wire_checks(check, P, PR, U, sleeps, base)
            agent_checks(check, P, Agent, T, base)
            serve_checks(check, audit, diagnose, G, P, PR, S, T, W, Agent, base)
            audit_checks(check, audit, diagnose, C, PR, startup_line, _where, base)
    finally:
        P._sleep = real_sleep
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# ---- configuration ----------------------------------------------------------------------------------------


def _env(**env):
    for k in PROVIDER_VARS:
        if k != "HOME":
            os.environ.pop(k, None)
    os.environ.update(env)


def _cfg(C, base: Path, **env):
    _env(**env)
    try:
        return C.load_config(workdir=str(base / "work"))
    except SystemExit as e:
        return str(e)


def config_checks(check, C, PR, base: Path) -> None:
    ok = lambda c: isinstance(c, C.Config)    # noqa: E731
    cases = [
        ("deepseek", "DEEPSEEK_API_KEY", "deepseek-flash", "DeepSeek", "api.deepseek.com"),
        ("glm", "ZAI_API_KEY", "glm-5.3-flash", "Z.ai (GLM)", "api.z.ai"),
        ("kimi", "MOONSHOT_API_KEY", "kimi-k3.1-pro", "Moonshot AI (Kimi)", "api.moonshot.ai"),
        ("qwen", "DASHSCOPE_API_KEY", "qwen3.8-flash", "Alibaba Cloud (Qwen)", "dashscope-intl.aliyuncs.com"),
    ]
    for name, var, model, label, host in cases:
        c = _cfg(C, base, BENJI_PROVIDER=name, **{var: "k-" + name})
        check(f"{name}: BENJI_PROVIDER picks it; key from {var}, default model, who and which host",
              ok(c) and c.provider == name and c.api_key == "k-" + name and c.model == model
              and c.destination == label and c.host == host and c.sends_to == f"{label} ({host})"
              and c.base_url.startswith("https://" + host) and c.vision and c.thinking == "off")
        check(f"{name}: BENJI_MODEL still overrides the default",
              _cfg(C, base, BENJI_PROVIDER=name, BENJI_MODEL="my-model", **{var: "k"}).model == "my-model")
        check(f"{name}: a missing key is a plain message naming the variable and where to make one",
              var in str(_cfg(C, base, BENJI_PROVIDER=name)) and "~/.benji.env" in str(_cfg(C, base, BENJI_PROVIDER=name)))
        check(f"{name}: without BENJI_PROVIDER, its key alone selects it",
              _cfg(C, base, **{var: "k"}).provider == name)
        check(f"{name}: http to the hosted API is refused",
              "unencrypted" in str(_cfg(C, base, BENJI_PROVIDER=name, BENJI_BASE_URL="http://localhost:9/v1", **{var: "k"})))
        other = _cfg(C, base, BENJI_PROVIDER=name, BENJI_BASE_URL="https://proxy.example.net/v1", **{var: "KEY-" + name})
        check(f"{name}: BENJI_BASE_URL on another host does not get the provider's key (needs BENJI_API_KEY)",
              "BENJI_API_KEY" in str(other) and var in str(other) and "KEY-" + name not in str(other))
        other = _cfg(C, base, BENJI_PROVIDER=name, BENJI_BASE_URL="https://proxy.example.net/v1",
                     BENJI_API_KEY="proxy-key", **{var: "KEY-" + name})
        check(f"{name}: …with BENJI_API_KEY it goes to that host, and the startup words name that host, not the provider",
              ok(other) and other.api_key == "proxy-key" and other.destination == "proxy.example.net"
              and other.sends_to == "proxy.example.net")
    check("Z.ai's other platform: BENJI_REGION=cn is open.bigmodel.cn; Kimi's api.moonshot.cn; Qwen's dashscope.aliyuncs.com",
          [_cfg(C, base, BENJI_PROVIDER=n, BENJI_REGION="cn", **{v: "k"}).host
           for n, v in (("glm", "ZAI_API_KEY"), ("kimi", "MOONSHOT_API_KEY"), ("qwen", "DASHSCOPE_API_KEY"))]
          == ["open.bigmodel.cn", "api.moonshot.cn", "dashscope.aliyuncs.com"])
    check("a region that doesn't exist is a plain error", "BENJI_REGION" in str(
        _cfg(C, base, BENJI_PROVIDER="glm", BENJI_REGION="mars", ZAI_API_KEY="k")))
    check("aliases: zai, zhipu, moonshot, dashscope, lm-studio name the same presets",
          [_cfg(C, base, BENJI_PROVIDER=a, BENJI_MODEL="m", **{v: "k"}).provider
           for a, v in (("zai", "ZAI_API_KEY"), ("zhipu", "ZHIPUAI_API_KEY"), ("moonshot", "MOONSHOT_API_KEY"),
                        ("dashscope", "DASHSCOPE_API_KEY"), ("lm-studio", "X"))]
          == ["glm", "glm", "kimi", "qwen", "lmstudio"])
    check("GLM also takes ZHIPUAI_API_KEY", _cfg(C, base, BENJI_PROVIDER="glm", ZHIPUAI_API_KEY="zk").api_key == "zk")
    check("Qwen's workspace-dedicated host (the docs' way forward) is still Qwen's: the DashScope key goes there",
          _cfg(C, base, BENJI_PROVIDER="qwen", DASHSCOPE_API_KEY="dk",
               BENJI_BASE_URL="https://ws123.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1").api_key == "dk")
    check("a vendor's coding-plan endpoint is refused (Z.ai, bigmodel.cn, Kimi Code)", all(
        "coding-plan" in str(_cfg(C, base, BENJI_PROVIDER=n, BENJI_BASE_URL=u, **{v: "k"}))
        for n, v, u in (("glm", "ZAI_API_KEY", "https://api.z.ai/api/coding/paas/v4"),
                        ("glm", "ZAI_API_KEY", "https://open.bigmodel.cn/api/coding/paas/v4"),
                        ("kimi", "MOONSHOT_API_KEY", "https://api.kimi.ai/coding/v1"))))
    check("an unknown provider lists the ones there are", all(
        n in str(_cfg(C, base, BENJI_PROVIDER="mistrall")) for n in ("claude", "openai", "deepseek", "glm", "kimi", "qwen", "ollama", "lmstudio")))
    check("two providers' keys and no BENJI_PROVIDER: Benji says to choose",
          "BENJI_PROVIDER" in str(_cfg(C, base, DEEPSEEK_API_KEY="a", MOONSHOT_API_KEY="b")))
    check("no key at all names every key variable",
          all(v in str(_cfg(C, base)) for v in ("DEEPSEEK_API_KEY", "ZAI_API_KEY", "MOONSHOT_API_KEY", "DASHSCOPE_API_KEY", "ollama")))
    check("no key at all says where a key goes", "~/.benji.env" in str(_cfg(C, base)) and ".benji.env.example" in str(_cfg(C, base)))
    c = _cfg(C, base, ANTHROPIC_API_KEY="a", DEEPSEEK_API_KEY="d")
    check("Claude and OpenAI work as before: Anthropic still wins when both keys are there", ok(c) and c.provider == "claude"
          and c.preset is None and c.sends_to == "Anthropic (api.anthropic.com)" and c.vision)
    c = _cfg(C, base, OPENAI_API_KEY="o")
    check("OpenAI as before: gpt-4o, no preset, nothing new sent", ok(c) and c.provider == "openai" and c.model == "gpt-4o"
          and c.preset is None and c.sends_to == "OpenAI (api.openai.com)")
    # local servers
    for name, port in (("ollama", 11434), ("lmstudio", 1234)):
        c = _cfg(C, base, BENJI_PROVIDER=name, BENJI_MODEL="m1")
        check(f"{name}: no key, plain http on localhost:{port}, who is 'this computer'",
              ok(c) and c.api_key == "" and c.base_url == f"http://localhost:{port}/v1"
              and "this computer" in c.destination and c.host == f"localhost:{port}")
        check(f"{name}: with no model named Benji asks for one and says how to find it",
              "BENJI_MODEL" in str(_cfg(C, base, BENJI_PROVIDER=name)))
        check(f"{name}: a server on another machine over plain http is refused",
              "unencrypted" in str(_cfg(C, base, BENJI_PROVIDER=name, BENJI_MODEL="m", BENJI_BASE_URL="http://192.168.1.9:11434/v1")))
        check(f"{name}: http://127.0.0.1 is local too",
              ok(_cfg(C, base, BENJI_PROVIDER=name, BENJI_MODEL="m", BENJI_BASE_URL="http://127.0.0.1:9999/v1")))
    check("a remote Ollama behind https is allowed", ok(_cfg(
        C, base, BENJI_PROVIDER="ollama", BENJI_MODEL="m", BENJI_BASE_URL="https://ollama.example.net/v1")))
    check("BENJI_THINKING and BENJI_MAX_TOKENS are checked, not guessed",
          "BENJI_THINKING" in str(_cfg(C, base, BENJI_PROVIDER="deepseek", DEEPSEEK_API_KEY="k", BENJI_THINKING="deep"))
          and "BENJI_MAX_TOKENS" in str(_cfg(C, base, BENJI_PROVIDER="deepseek", DEEPSEEK_API_KEY="k", BENJI_MAX_TOKENS="7"))
          and _cfg(C, base, BENJI_PROVIDER="deepseek", DEEPSEEK_API_KEY="k", BENJI_THINKING="on").thinking == "on"
          and _cfg(C, base, BENJI_PROVIDER="deepseek", DEEPSEEK_API_KEY="k", BENJI_MAX_TOKENS="1234").max_tokens == 1234)
    check("tool processes never see the new providers' keys",
          not any(k in T_env() for k in ("DEEPSEEK_API_KEY", "ZAI_API_KEY", "ZHIPUAI_API_KEY", "MOONSHOT_API_KEY", "DASHSCOPE_API_KEY")))
    _env()


def T_env() -> dict:
    from benji import gate
    return gate.tool_env({"DEEPSEEK_API_KEY": "a", "ZAI_API_KEY": "b", "ZHIPUAI_API_KEY": "c", "MOONSHOT_API_KEY": "d",
                          "DASHSCOPE_API_KEY": "e", "PATH": "/bin"})


# ---- the tables: which models read pictures, how thinking is switched, usage fields ------------------------


def table_checks(check, PR, P, U) -> None:
    _env()
    r = lambda name, model: PR.reads_images(PR.PRESETS[name], model)    # noqa: E731
    check("vision table: DeepSeek's deepseek-flash reads images, deepseek-v4-pro does not (its pricing page)",
          r("deepseek", "deepseek-flash") and not r("deepseek", "deepseek-v4-pro"))
    check("vision table: GLM-5.3 (the flagship) is text only; glm-5.3-flash and glm-4.6v read images",
          not r("glm", "glm-5.3") and r("glm", "glm-5.3-flash") and r("glm", "glm-4.6v") and not r("glm", "glm-4.7-flash"))
    check("vision table: Kimi K3.1 Pro reads images; an id not in the doc's list is taken not to",
          r("kimi", "kimi-k3.1-pro") and not r("kimi", "kimi-k3.1-pro-highspeed") and not r("kimi", "moonshot-v1-8k"))
    check("vision table: Qwen 3.8/3.7 flash, plus and max read images; qwen-plus (the legacy name) is not taken to",
          all(r("qwen", m) for m in ("qwen3.8-flash", "qwen3.7-plus", "qwen3.8-max", "qwen3.7-flash-2026-07-15", "qwen3-vl-plus"))
          and not r("qwen", "qwen-plus") and not r("qwen", "qwen3.8-27b"))
    check("vision table: local models by well-known multimodal names only (llava, vision, -vl, gemma3…)",
          all(r("ollama", m) for m in ("llava:13b", "llama3.2-vision", "qwen2.5-vl-7b", "gemma3:12b"))
          and not any(r("ollama", m) for m in ("llama3.2", "qwen2.5-coder", "deepseek-r1:8b")))
    check("vision: Claude, OpenAI and a custom server are taken to read images, as before",
          PR.reads_images(None, "gpt-4o") and PR.reads_images(None, "anything"))
    os.environ["BENJI_VISION"] = "1"
    check("BENJI_VISION=1 overrides the table", r("glm", "glm-5.3") and r("ollama", "llama3.2"))
    os.environ["BENJI_VISION"] = "0"
    check("BENJI_VISION=0 overrides it the other way", not r("deepseek", "deepseek-flash") and not PR.reads_images(None, "gpt-4o"))
    os.environ.pop("BENJI_VISION")

    th = lambda name, model, mode: PR.PRESETS[name].thinking(model, mode)     # noqa: E731
    check("thinking: DeepSeek disabled/enabled by `thinking.type`; default sends nothing",
          th("deepseek", "deepseek-flash", "off") == {"thinking": {"type": "disabled"}}
          and th("deepseek", "deepseek-flash", "on") == {"thinking": {"type": "enabled"}} and th("deepseek", "deepseek-flash", "default") == {})
    check("thinking: GLM-5.3 can't be switched off, so 'off' is reasoning_effort low (never thinking: disabled); older GLM uses thinking.type",
          th("glm", "glm-5.3-flash", "off") == {"reasoning_effort": "low"} and th("glm", "glm-5.3", "on") == {"reasoning_effort": "high"}
          and th("glm", "glm-4.6", "off") == {"thinking": {"type": "disabled"}})
    check("thinking: Kimi K3 always thinks: reasoning_effort low/high, never a thinking field",
          th("kimi", "kimi-k3.1-pro", "off") == {"reasoning_effort": "low"} and th("kimi", "kimi-k3", "on") == {"reasoning_effort": "high"})
    check("thinking: Qwen's enable_thinking, said either way", th("qwen", "qwen3.8-flash", "off") == {"enable_thinking": False}
          and th("qwen", "qwen3.8-flash", "on") == {"enable_thinking": True})
    check("thinking: local servers get nothing", th("ollama", "m", "off") == {} and th("lmstudio", "m", "on") == {})

    d = U.from_openai({"usage": {"prompt_tokens": 100, "completion_tokens": 7, "prompt_cache_hit_tokens": 40, "prompt_cache_miss_tokens": 60}})
    check("usage: DeepSeek's prompt_cache_hit_tokens at the top of usage", d == {"input_tokens": 60, "output_tokens": 7, "cache_read_tokens": 40, "cache_write_tokens": 0})
    d = U.from_openai({"usage": {"prompt_tokens": 100, "completion_tokens": 7, "prompt_tokens_details": {"prompt_cache_hit_tokens": 40}}})
    check("usage: …or inside prompt_tokens_details (its docs show both)", d["cache_read_tokens"] == 40 and d["input_tokens"] == 60)
    d = U.from_openai({"usage": {"prompt_tokens": 100, "completion_tokens": 7, "prompt_tokens_details": {"cached_tokens": 30, "cache_write_tokens": 10}}})
    check("usage: Kimi's cached and cache-write tokens are apart from the plain input",
          d == {"input_tokens": 60, "output_tokens": 7, "cache_read_tokens": 30, "cache_write_tokens": 10})
    d = U.from_openai({"usage": {"prompt_tokens": 100, "completion_tokens": 7, "cached_tokens": 25}})
    check("usage: a top-level cached_tokens (Kimi's schema) counts too", d["cache_read_tokens"] == 25 and d["input_tokens"] == 75)
    check("usage: OpenAI's shape is unchanged", U.from_openai({"usage": {"prompt_tokens": 10, "completion_tokens": 2,
          "prompt_tokens_details": {"cached_tokens": 4}}}) == {"input_tokens": 6, "output_tokens": 2, "cache_read_tokens": 4, "cache_write_tokens": 0})

    f = P._ThinkFilter()
    pieces = ["Hel", "lo <th", "ink>secret ", "thoughts</thi", "nk>\n\nThe answer", " is 4. <", "b>x"]
    out = "".join(f.feed(p) for p in pieces) + f.flush()
    check("a <think> block in a local model's text is cut out wherever the chunks split it", out == "Hello The answer is 4. <b>x")
    f = P._ThinkFilter()
    out = f.feed("<think>never closed") + f.flush()
    check("an unclosed <think> shows nothing", out == "")


# ---- the wire ---------------------------------------------------------------------------------------------


def provider_for(P, PR, name: str, fake: Fake, model: str | None = None, thinking: str = "off", vision=None):
    model = model or fake.p["model"]
    preset = PR.PRESETS[name]
    return P.make_provider(name, fake.p["key"], model, fake.base, thinking=thinking,
                           vision=PR.reads_images(preset, model) if vision is None else vision)


def wire_checks(check, P, PR, U, sleeps: list, base: Path) -> None:
    ask = lambda text, **k: [{"role": "user", "text": text, **k}]       # noqa: E731
    tools = [{"name": "list_dir", "description": "List a folder.",
              "parameters": {"type": "object", "properties": {"path": {"type": "string"}}}},
             {"name": "read_file", "description": "Read a file.",
              "parameters": {"type": "object", "properties": {"path": {"type": "string"}}}}]
    png = {"media_type": "image/png", "data": "iVBORw0KGgo="}
    for name, prof in PROFILES.items():
        _env()
        fake = Fake(name)
        try:
            preset = PR.PRESETS[name]
            mk = lambda **k: provider_for(P, PR, name, fake, **k)       # noqa: E731
            p = mk()
            # 1. a plain reply, reasoning kept out
            fake.script("hi", {"text": "Hello there.", "reasoning": THOUGHT}, {"text": "Hello there.", "reasoning": THOUGHT})
            whole = p.complete("sys", ask("hi"), tools)
            pieces: list[str] = []
            streamed = p.stream("sys", ask("hi"), tools, on_text=pieces.append)
            body = fake.requests[0]["body"]
            check(f"{name}: a plain reply; the model's reasoning is not in the text, the pieces or the result",
                  whole["text"] == "Hello there." and streamed["text"] == "Hello there." and "".join(pieces) == "Hello there."
                  and THOUGHT not in whole["text"] + streamed["text"] + "".join(pieces)
                  and ("reasoning" in streamed) == (prof["model"] and mk().replay != "none"))
            other = "max_tokens" if prof["max_param"] != "max_tokens" else "max_completion_tokens"
            check(f"{name}: the output limit goes by its documented name ({prof['max_param']}), no other; sized {preset.max_tokens}",
                  body[prof["max_param"]] == preset.max_tokens and other not in body)
            check(f"{name}: nothing Anthropic-only (cache_control, effort, anthropic version) is sent, and no `system` field",
                  not any(k in json.dumps(body) for k in ANTHROPIC_ONLY) and "system" not in body)
            check(f"{name}: no temperature, top_p or n (some providers fix them)", not {"temperature", "top_p", "n"} & set(body))
            check(f"{name}: the key goes in an Authorization: Bearer header" if prof["key"] else f"{name}: a local server gets no Authorization header",
                  (fake.requests[0]["headers"].get("Authorization") == "Bearer " + prof["key"]) if prof["key"]
                  else "Authorization" not in fake.requests[0]["headers"])
            sbody = fake.requests[1]["body"]
            check(f"{name}: stream_options.include_usage is sent only where the docs have it ({'yes' if preset.stream_options else 'no'})",
                  ("stream_options" in sbody) == preset.stream_options and sbody.get("stream") is True and "stream_options" not in body)
            if prof["thinking_probe"]:
                key, want = prof["thinking_probe"]["off"]
                got = body.get(key)
                check(f"{name}: thinking is off by default ({key}={want!r})", got == want)
                p_on = mk(thinking="on")
                fake.script("on", {"text": "ok"})
                p_on.complete("sys", ask("on"), tools)
                key, want = prof["thinking_probe"]["on"]
                check(f"{name}: BENJI_THINKING=on turns it on ({key}={want!r})", fake.requests[-1]["body"].get(key) == want)
            else:
                check(f"{name}: a local server is sent no thinking field", not ({"thinking", "reasoning_effort", "enable_thinking"} & set(body)))

            # 2. two parallel tool calls, arguments in pieces (or whole)
            reply = {"tools": [("list_dir", {"path": "output/notes"}), ("read_file", {"path": "output/notes/a-long-name.txt"})]}
            fake.script("tools", reply, reply)
            a = p.complete("sys", ask("tools"), tools)
            b = p.stream("sys", ask("tools"), tools, on_text=lambda s: None)
            want = [{"id": "call_0", "name": "list_dir", "input": {"path": "output/notes"}},
                    {"id": "call_1", "name": "read_file", "input": {"path": "output/notes/a-long-name.txt"}}]
            check(f"{name}: parallel tool calls ({prof['tool_style']} chunks) are put together the same streamed as not",
                  a["tool_calls"] == want and b["tool_calls"] == want)

            # 3. usage
            prompt, cached, written, completion = prof["usage"]
            check(f"{name}: usage counts (plain input {prompt - cached - written}, cache read {cached}, written {written}, output {completion})",
                  b["usage"] == {"input_tokens": prompt - cached - written, "output_tokens": completion,
                                 "cache_read_tokens": cached, "cache_write_tokens": written} == a["usage"])

            # 4. a busy server: a short retry
            n0 = len(fake.requests)
            sleeps.clear()
            busy = dict(prof["busy"])
            fake.script("busy", busy, {"text": "recovered"}, busy, {"text": "recovered"})
            r1 = p.complete("sys", ask("busy"), tools)
            r2 = p.stream("sys", ask("busy"), tools, on_text=lambda s: None)
            want_wait = float(busy.get("headers", {}).get("Retry-After", 0)) or 0.0
            check(f"{name}: {busy['status']} then success: tried again once, text intact, both ways",
                  r1["text"] == r2["text"] == "recovered" and len(fake.requests) - n0 == 4)
            check(f"{name}: the wait is the server's Retry-After when it sends one, else a second ({sleeps})",
                  sleeps == [want_wait or 1.0, want_wait or 1.0])
            sleeps.clear()
            n0 = len(fake.requests)
            fake.script("down", *([dict(busy)] * 5))
            try:
                p.complete("sys", ask("down"), tools)
                msg = ""
            except P.ProviderError as e:
                msg = str(e)
            check(f"{name}: a server that stays busy: two retries, then one plain error that names the status and the host only",
                  len(fake.requests) - n0 == 3 and len(sleeps) == 2 and msg.startswith(f"HTTP {busy['status']} from {fake.host}:")
                  and busy["message"] in msg and CANARY not in msg and "/v1/chat" not in msg and "{" not in msg)

            # 5. out of money: not retried
            if prof["quota"]:
                n0 = len(fake.requests)
                sleeps.clear()
                fake.script("poor", dict(prof["quota"]))
                try:
                    p.complete("sys", ask("poor"), tools)
                    msg = ""
                except P.ProviderError as e:
                    msg = str(e)
                check(f"{name}: a balance or quota error ({prof['quota']['status']} {prof['quota']['code'] or prof['quota']['type'] or prof['quota']['message'][:12]}) is not retried",
                      len(fake.requests) - n0 == 1 and not sleeps and msg.startswith(f"HTTP {prof['quota']['status']}") and CANARY not in msg)
            if name == "kimi":
                sleeps.clear()
                fake.script("long", dict(prof["busy"], headers={"Retry-After": "99"}), {"text": "ok"})
                p.complete("sys", ask("long"), tools)
                check("kimi: a long Retry-After is cut to 8 s", sleeps == [P.MAX_WAIT])

            # 6. pictures
            reads = PR.reads_images(preset, prof["model"])
            if reads:
                n0 = len(fake.requests)
                fake.script("see", {"text": "I see it."})
                got = mk().complete("sys", ask("see", images=[png]), tools)
                sent = fake.requests[-1]["body"]["messages"][1]["content"]
                check(f"{name}: {prof['model']} reads images: the picture goes as a data URL in the user message",
                      got["text"] == "I see it." and sent[1]["image_url"]["url"] == "data:image/png;base64,iVBORw0KGgo=")
                sleeps.clear()
                fake.script("tools-see", {"tools": [("list_dir", {"path": "."})]}, {"text": "after"})
                msgs = ask("tools-see") + [{"role": "assistant", "text": "", "tool_calls": [{"id": "c1", "name": "click", "input": {}}],
                                            **({"reasoning": THOUGHT} if mk().replay != "none" else {})},
                                           {"role": "tool", "id": "c1", "name": "click", "content": "[done]", "images": [png]}]
                mk().complete("sys", msgs, tools)
                last = fake.requests[-1]["body"]["messages"]
                check(f"{name}: a screen step's screenshot follows the tool result as a user message (no image in a tool message)",
                      last[-2]["role"] == "tool" and isinstance(last[-2]["content"], str) and last[-1]["role"] == "user"
                      and last[-1]["content"][1]["type"] == "image_url")
            else:
                n0 = len(fake.requests)
                try:
                    mk().complete("sys", ask("see", images=[png]), tools)
                    msg = ""
                except P.ProviderError as e:
                    msg = str(e)
                check(f"{name}: {prof['model']} can't read images: Benji says so plainly and sends nothing",
                      "can't read images" in msg and len(fake.requests) == n0 and CANARY not in msg)
            # a table that is wrong, overridden: the server's refusal becomes a plain sentence
            if not reads:
                fake.script("see2", {"text": "x"})
                try:
                    mk(vision=True).complete("sys", ask("see2", images=[png]), tools)
                    msg = ""
                except P.ProviderError as e:
                    msg = str(e)
                check(f"{name}: with BENJI_VISION=1 on a model that refuses, the refusal is explained (BENJI_VISION=0)",
                      "does not accept images" in msg and "BENJI_VISION" in msg)

            # 7. a model without tools
            if prof["no_tools"]:
                try:
                    mk(model="gemma-no-tools").complete("sys", ask("hi"), tools)
                    msg = ""
                except P.ProviderError as e:
                    msg = str(e)
                check(f"{name}: a model that rejects tools gets one plain sentence naming BENJI_MODEL",
                      "does not accept tool calls" in msg and "BENJI_MODEL" in msg)

            # 8. a wrong key
            bad = P.make_provider(name, "wrong", prof["model"], fake.base)
            if prof["key"]:
                try:
                    bad.complete("sys", ask("hi"), tools)
                    msg = ""
                except P.ProviderError as e:
                    msg = str(e)
                check(f"{name}: a refused key is a 401 with the server's words, not retried, and not the key",
                      msg.startswith("HTTP 401") and "wrong" not in msg and prof["key"] not in msg)

            # 9. the finish reasons that mean no answer
            fake.script("cut", {"text": "", "finish": "length"}, {"text": "", "finish": "length"})
            for how in ("complete", "stream"):
                try:
                    (p.complete("sys", ask("cut"), tools) if how == "complete"
                     else p.stream("sys", ask("cut"), tools, on_text=lambda s: None))
                    msg = ""
                except P.ProviderError as e:
                    msg = str(e)
                check(f"{name}: an empty reply that hit the output limit says so ({how})", "BENJI_MAX_TOKENS" in msg)
        finally:
            fake.close()

    # reasoning that has to be sent back (DeepSeek with thinking on, Kimi always)
    for name, thinking, replays in (("deepseek", "off", False), ("deepseek", "on", True), ("kimi", "off", True),
                                    ("glm", "off", False), ("qwen", "off", False)):
        fake = Fake(name)
        try:
            p = provider_for(P, PR, name, fake, thinking=thinking)
            fake.script("loop", {"text": "", "reasoning": THOUGHT, "tools": [("list_dir", {"path": "."})]}, {"text": "done"})
            first = p.stream("sys", ask("loop"), tools, on_text=lambda s: None)
            check(f"{name} (thinking {thinking}): its reasoning is {'handed to the agent, in memory' if replays else 'dropped on arrival'}",
                  ("reasoning" in first) == replays and THOUGHT not in first["text"])
            msgs = ask("loop") + [{"role": "assistant", "text": first["text"], "tool_calls": first["tool_calls"],
                                   **({"reasoning": first["reasoning"]} if "reasoning" in first else {})},
                                  {"role": "tool", "id": "call_0", "name": "list_dir", "content": "a.txt"}]
            out = p.stream("sys", msgs, tools, on_text=lambda s: None)
            sent = fake.requests[-1]["body"]["messages"]
            asst = next(m for m in sent if m["role"] == "assistant")
            check(f"{name} (thinking {thinking}): the next request {'carries reasoning_content back unchanged' if replays else 'has no reasoning_content'}"
                  f" and the server {'accepts it' if replays or not PROFILES[name]['replay_needed'] or thinking == 'off' else 'refuses'}",
                  (asst.get("reasoning_content") == THOUGHT) == replays and out["text"] == "done")
        finally:
            fake.close()

    # the old providers are untouched
    sent: list = []
    real = P._post
    P._post = lambda url, headers, payload: (sent.append(payload) or {"choices": [{"message": {"content": "x"}}]})
    try:
        P.OpenAIProvider("k", "gpt-4o").complete("sys", ask("hi"), tools)
        check("OpenAI is untouched: no max-tokens field, no thinking field, no stream_options, same keys as before",
              set(sent[0]) == {"model", "messages", "tools"})
        check("Claude is untouched: make_provider builds the Anthropic provider", P.make_provider("claude", "k", "m").name == "claude")
    finally:
        P._post = real


# ---- an agent turn over the fake ---------------------------------------------------------------------------


def agent_checks(check, P, Agent, T, base: Path) -> None:
    from benji import presets as PR
    for name, thinking in (("deepseek", "on"), ("kimi", "off"), ("glm", "off"), ("qwen", "off"), ("ollama", "off")):
        _env()
        fake = Fake(name)
        wd = base / f"agent-{name}"
        (wd / "output").mkdir(parents=True)
        (wd / "note.txt").write_text("a line\n")
        try:
            p = provider_for(P, PR, name, fake, thinking=thinking)
            fake.script("what is in the folder?", {"text": "", "reasoning": THOUGHT, "tools": [("list_dir", {"path": "."})]},
                        {"text": "There is a note.txt.", "reasoning": THOUGHT})
            asked: list[str] = []
            agent = Agent(p, "sys", wd, approve=lambda r: asked.append(r) or False)
            answer = agent.send("what is in the folder?")
            check(f"{name}: an agent turn over the fake server: tool call, tool result, answer; no card for a free read",
                  answer == "There is a note.txt." and not asked and len(fake.requests) == 2
                  and "note.txt" in json.dumps(fake.requests[1]["body"]["messages"]))
            check(f"{name}: the model's reasoning is not in the answer, the usage log line or anything the agent wrote",
                  THOUGHT not in answer and THOUGHT not in json.dumps(agent.last_usage))
            # the gate is the same: a write outside the folder asks, and a No reaches the model
            fake.script("write outside please", {"text": "", "reasoning": THOUGHT,
                                                 "tools": [("write_file", {"path": str(base / "evil.txt"), "content": "x"})]},
                        {"text": "I could not.", "reasoning": THOUGHT})
            agent.send("write outside please")
            check(f"{name}: the gate is the same for every provider: a write outside the folder asked, and the No went back to the model",
                  len(asked) == 1 and "write" in asked[0].lower() and not (base / "evil.txt").exists()
                  and "[declined]" in json.dumps(fake.requests[-1]["body"]["messages"]))
        finally:
            fake.close()


# ---- the engine over the fake: a turn, a job, the logs -----------------------------------------------------


def serve_checks(check, audit, diagnose, G, P, PR, S, T, W, Agent, base: Path) -> None:
    from benji import jobs as J

    class Events:
        def __init__(self):
            self.items, self.cv = [], threading.Condition()

        def __call__(self, e):
            with self.cv:
                self.items.append(e)
                self.cv.notify_all()

        def wait(self, pred, timeout=10.0):
            end = time.time() + timeout
            with self.cv:
                while not any(pred(e) for e in self.items):
                    if not self.cv.wait(max(end - time.time(), 0)) and time.time() >= end:
                        return None
                return next(e for e in self.items if pred(e))

    shot = base / "screen.png"
    shot.write_bytes(_PNG)
    state = lambda name: (lambda e: e.get("type") == "job" and e["job"]["state"] == name)      # noqa: E731
    done = lambda tid: (lambda e: e.get("type") == "done" and e.get("id") == tid)               # noqa: E731
    real_fetch = W.fetch_text
    W.fetch_text = lambda url, max_chars=0: f"page text {CANARY}"
    try:
        for name in ("deepseek", "glm", "kimi", "qwen", "ollama", "lmstudio"):
            _env()
            prof = PROFILES[name]
            fake = Fake(name)
            wd = base / f"serve-{name}"
            (wd / "output").mkdir(parents=True)
            logs = base / f"logs-{name}"
            audit.configure(logs / audit.FILE_NAME)
            err = io.StringIO()
            usage_path = wd / "usage.jsonl"
            reads = PR.reads_images(PR.PRESETS[name], prof["model"])
            thinking = "on" if name == "deepseek" else "off"       # DeepSeek's replay is part of this run
            provider = provider_for(P, PR, name, fake, thinking=thinking)
            ev, store = Events(), J.JobStore(J.folder(wd))
            made = {}

            def make(approve, on_tool, cancelled, info):
                made["fg"] = Agent(provider, "sys", wd, approve=approve, on_tool=on_tool, cancelled=cancelled, usage_path=usage_path)
                return made["fg"]

            def make_job(record, approve, on_tool, cancelled):
                return Agent(provider, "sys", store.path(record["id"]), approve=approve, on_tool=on_tool, cancelled=cancelled,
                             usage_path=usage_path)

            try:
                with redirect_stderr(err):
                    srv = S.Server(make, ev, {"version": "t", "provider": name, "model": prof["model"]}, make_job_agent=make_job,
                                   job_store=store, job_beat=0.05, answer_log_path=wd / "answers.jsonl")
                    srv.handle({"type": "hello", "protocol": S.PROTOCOL})
                    brief = f"Write notes about {CANARY}."
                    # the foreground turn reads a page (tainted), then starts a job; the job writes
                    fake.script(f"look at {CANARY} and write it up in the background",
                                {"text": "", "reasoning": THOUGHT, "tools": [("web_fetch", {"url": "https://news.example/story"})]},
                                {"text": "", "reasoning": THOUGHT, "tools": [("start_job", {"title": f"Notes {CANARY}", "brief": brief})]},
                                {"text": f"Started {CANARY}.", "reasoning": THOUGHT})
                    fake.script("~Brief, written by Benji",
                                {"text": "", "reasoning": THOUGHT, "tools": [("write_file", {"path": "output/a.txt", "content": CANARY})]},
                                {"text": f'Done.\n{{"spoken": "Saved {CANARY}.", "written": "Saved {CANARY}.", "files": ["output/a.txt"]}}',
                                 "reasoning": THOUGHT})
                    kwargs = {"image": str(shot)} if reads else {}
                    srv.handle({"type": "send", "id": "t1", "text": f"look at {CANARY} and write it up in the background",
                                "jobs": True, **kwargs})
                    end = time.time() + 20
                    seen: set = set()
                    cards: list[str] = []
                    while time.time() < end:
                        for e in list(ev.items):
                            if e.get("type") == "approval" and (e["id"], e["request"]) not in seen:
                                seen.add((e["id"], e["request"]))
                                cards.append(e["action"])
                                srv.handle({"type": "approve", "id": e["id"], "request": e["request"], "decision": "yes"})
                            if e.get("type") == "job" and e["job"].get("pending") and ("j", e["job"]["pending"]["request"]) not in seen:
                                seen.add(("j", e["job"]["pending"]["request"]))
                                cards.append(e["job"]["pending"]["action"])
                                srv.handle({"type": "approve", "id": e["job"]["id"], "request": e["job"]["pending"]["request"],
                                            "decision": "yes"})
                        if any(e.get("type") == "job" and e["job"]["state"] in ("done", "failed") for e in ev.items):
                            break
                        time.sleep(0.02)
                    S.run(srv, io.StringIO(""))
                fin = next((e for e in reversed(ev.items) if e.get("type") == "job"), None)
                check(f"{name}: a turn and a job against the fake: the job finishes ({fin and fin['job']['state']})",
                      fin is not None and fin["job"]["state"] == "done")
                check(f"{name}: the gate asks what it asks for Claude: the start after a page and the job's write on cards"
                      + (", and the fetch after the screen" if reads else " (no screen here, so a plain fetch is free)"),
                      len(cards) == (3 if reads else 2) and (not reads or cards[0].startswith("fetch a web page")) and any(c.startswith("start a background job") for c in cards)
                      and any(c.startswith("write a file") for c in cards))
                events = [json.loads(l) for l in (logs / audit.FILE_NAME).read_text().splitlines()]
                tool_events = [(e["tool"], e["gate"], e["code"]) for e in events if e["kind"] == "tool"]
                check(f"{name}: the audit log holds the gate's decisions with the same codes as for Claude, every line valid",
                      any(t[0] == "start_job" and t[1] == "asked" for t in tool_events)
                      and any(t[0] == "write_file" and t[1] == "asked" and t[2] == "tainted_change" for t in tool_events)
                      and all(audit.validate(e) for e in events))
                logtext = "".join(f.read_text() for f in logs.glob("events.jsonl*"))
                usage_text = usage_path.read_text()
                lines = [json.loads(l) for l in usage_text.splitlines()]
                check(f"{name}: usage.jsonl has one metadata line per model call (provider {name}, model, counts), no text",
                      len(lines) >= 5 and all(l["provider"] == name and l["model"] == prof["model"] and l["output_tokens"] == prof["usage"][3]
                                              for l in lines) and set(lines[0]) == {"ts", "provider", "model", "input_tokens", "output_tokens",
                                                                                   "cache_read_tokens", "cache_write_tokens"})
                where = [(n, text) for n, text in (("events.jsonl", logtext), ("usage.jsonl", usage_text),
                                                   ("the engine's stderr", err.getvalue()), ("the diagnose report", diagnose.report(logs, hours=24)))]
                key = prof["key"]
                check(f"{name}: no log, no stderr line and no diagnose report holds the user's words, a page, or a file's text",
                      not [n for n, t in where if CANARY.lower() in t.lower()])
                check(f"{name}: …nor the model's reasoning, nor the key, nor a key-shaped string",
                      not [n for n, t in where if THOUGHT in t or KEYWORD in t or (key and key in t)])
                shown = json.dumps([e for e in ev.items if e.get("type") in ("delta", "answer", "job")])
                check(f"{name}: …and the reasoning never reached what the app shows or speaks (deltas, answer, job rows)",
                      THOUGHT not in shown and THOUGHT not in json.dumps([store.load(j["id"]) for j in store.all()])
                      and THOUGHT not in "".join(p.read_text(errors="ignore") for p in wd.rglob("*") if p.is_file()))
                check(f"{name}: …and the key is in no file the engine wrote",
                      KEYWORD not in "".join(p.read_text(errors="ignore") for p in list(wd.rglob("*")) + list(logs.rglob("*")) if p.is_file()))
                if reads:
                    sent = json.dumps(fake.requests[0]["body"]["messages"])
                    check(f"{name}: the screenshot went to the model as a user-message image", "image_url" in sent and "data:image/png" in sent)
            finally:
                fake.close()

        # a model that can't read pictures, asked a screen question: one plain error, nothing sent
        _env()
        fake = Fake("ollama")
        wd = base / "serve-novision"
        (wd / "output").mkdir(parents=True)
        try:
            provider = provider_for(P, PR, "ollama", fake)
            ev = Events()
            audit.configure(base / "logs-novision" / audit.FILE_NAME)
            srv = S.Server(lambda approve, on_tool, cancelled, info: Agent(provider, "sys", wd, approve=approve, on_tool=on_tool,
                                                                           cancelled=cancelled), ev, {"version": "t"})
            srv.handle({"type": "hello", "protocol": S.PROTOCOL})
            srv.handle({"type": "send", "id": "s1", "text": "what is on my screen?", "image": str(shot), "allow_pointing": True})
            ev.wait(done("s1"))
            errs = [e for e in ev.items if e.get("type") == "error"]
            check("a text-only model asked a screen question: one plain error that says it can't read images, and nothing was sent",
                  len(errs) == 1 and "can't read images" in errs[0]["text"] and not fake.requests)
            S.run(srv, io.StringIO(""))
        finally:
            fake.close()
    finally:
        W.fetch_text = real_fetch
        audit.configure(None)


# ---- the audit log and the words that say where the data goes -----------------------------------------------


def audit_checks(check, audit, diagnose, C, PR, startup_line, where, base: Path) -> None:
    for name, var, host in (("deepseek", "DEEPSEEK_API_KEY", "api.deepseek.com"), ("glm", "ZAI_API_KEY", "api.z.ai"),
                            ("kimi", "MOONSHOT_API_KEY", "api.moonshot.ai"), ("qwen", "DASHSCOPE_API_KEY", "dashscope-intl.aliyuncs.com")):
        c = _cfg(C, base, BENJI_PROVIDER=name, **{var: "sk-" + KEYWORD})
        line = startup_line(c)
        w = where(c)
        check(f"{name}: the startup line names the provider, model and HOST, and no key",
              f"provider={name}" in line and f"model={c.model}" in line and f"({host})" in line and KEYWORD not in line
              and w == {"provider": name, "model": c.model, "host": host})
    c = _cfg(C, base, BENJI_PROVIDER="ollama", BENJI_MODEL="llama3.2")
    check("a local server: the startup line says this computer and localhost:port, and that Screen is off for a text-only model",
          "this computer" in startup_line(c) and "localhost:11434" in startup_line(c) and "screen=off" in startup_line(c)
          and where(c) == {"provider": "ollama", "model": "llama3.2"})
    c = _cfg(C, base, ANTHROPIC_API_KEY="a")
    check("Claude's startup line gains only the host", "sends to=Anthropic (api.anthropic.com)" in startup_line(c) and "screen=off" not in startup_line(c))

    log = base / "diag" / audit.FILE_NAME
    audit.configure(log)
    audit.event("engine_start", mode="serve", version="0.1.0", provider="deepseek", host="api.deepseek.com", model="deepseek-flash")
    audit.event("engine_start", mode="serve", version="0.1.0", provider="ollama", model="llama3.2")
    report = diagnose.report(base / "diag", hours=24)
    check("benji --diagnose says where the data goes: provider, host, model (and 'this computer' for a local server)",
          "Sending to ollama (this computer), model llama3.2" in report
          or "Sending to deepseek (api.deepseek.com), model deepseek-flash" in report)
    audit.event("engine_start", mode="serve", version="0.1.0", provider="deepseek", host="api.deepseek.com", model="deepseek-flash")
    check("…the last start wins", "Sending to deepseek (api.deepseek.com), model deepseek-flash" in diagnose.report(base / "diag", hours=24))
    with redirect_stderr(io.StringIO()):
        refused = (not audit.event("engine_start", mode="serve", provider="evilcorp")
                   and not audit.event("engine_start", mode="serve", host="not a host"))
    check("the audit schema refuses a provider or host it doesn't know (nothing free-form gets in)", refused)
    audit.configure(None)
