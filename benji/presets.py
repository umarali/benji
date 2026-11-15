"""Open-model providers: DeepSeek, GLM (Z.ai / Zhipu), Kimi (Moonshot), Qwen (Alibaba Cloud
Model Studio), and Ollama / LM Studio on this computer.

Each speaks the OpenAI chat-completions format, so each is a preset for OpenAIProvider: where it
lives, which environment variable holds its key, which model to use when none is named, which of its
models read images, how its thinking is switched, and what it wants sent back. Everything here comes
from the provider's own API documentation as read on 2026-11-05 (docs/providers.md
holds the sources and says which facts are unconfirmed). Model ids change fast: every id here can be
replaced with BENJI_MODEL, and an id that is not in a doc read on that date is not in this file.

The key is sent only to the preset's own host. BENJI_BASE_URL on a preset points it somewhere else
and then the key is BENJI_API_KEY, never the preset's key.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Callable
from urllib.parse import urlparse

THINKING_MODES = ("off", "on", "default")
REGIONS = ("intl", "cn")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "[::1]", "::1")


@dataclass(frozen=True)
class Preset:
    name: str                               # BENJI_PROVIDER
    label: str                              # who receives the data, in plain words
    endpoints: dict[str, str]               # region -> base URL (no trailing /chat/completions)
    key_envs: tuple[str, ...]               # the first one that is set is the key; () for a local server
    model: str                              # used when BENJI_MODEL is not set; "" = the user must name one
    docs: str                               # where the facts below were read, and when
    local: bool = False                     # a server on this computer: plain http to localhost is fine
    max_tokens_param: str = "max_tokens"
    vision: tuple[str, ...] = ()            # regexes (full match, lowercase) of ids that read images
    stream_options: bool = True             # the server documents stream_options.include_usage
    reasoning_fields: tuple[str, ...] = ("reasoning_content",)
    replay: str = "none"                    # "none" | "session": reasoning to send back with later requests
    replay_always: bool = False             # ...even with thinking "off" (a model that always thinks)
    max_tokens: int = 8192                  # sent as max_tokens_param; thinking counts toward it on some servers
    thinking: Callable[[str, str], dict] = field(default=lambda model, mode: {})
    no_retry_codes: frozenset[str] = frozenset()   # error codes under a 429 that waiting does not fix
    refuse_paths: tuple[str, ...] = ()      # a base URL containing one of these is not for general apps
    host_suffixes: tuple[str, ...] = ()     # other hosts that are the provider's too (the key may go there)
    label_cn: str = ""                      # the label on the China platform, when it is another company name
    key_url: str = ""                       # where the user makes a key, for the "no key" message
    aliases: tuple[str, ...] = ()

    @property
    def hosts(self) -> tuple[str, ...]:
        return tuple(dict.fromkeys(urlparse(u).hostname or "" for u in self.endpoints.values()))

    def is_own_host(self, host: str) -> bool:
        """Whether this host is the provider's, so the provider's key may be sent to it."""
        host = host.lower()
        return host in self.hosts or any(host == s or host.endswith("." + s) for s in self.host_suffixes)


def _off_on(body_off: dict, body_on: dict) -> Callable[[str, str], dict]:
    def thinking(_model: str, mode: str) -> dict:
        return dict(body_off if mode == "off" else body_on) if mode in ("off", "on") else {}
    return thinking


def _deepseek_thinking(_model: str, mode: str) -> dict:
    # thinking is on by default at the server; `thinking.type` is the documented switch
    return {"thinking": {"type": {"off": "disabled", "on": "enabled"}[mode]}} if mode in ("off", "on") else {}


def _glm_thinking(model: str, mode: str) -> dict:
    if mode not in ("off", "on"):
        return {}
    if re.match(r"glm-5\.3", model.lower()):
        # glm-5.3 and glm-5.3-flash(x) cannot switch thinking off (`disabled` is an error);
        # reasoning_effort takes low, high or max there
        return {"reasoning_effort": "low" if mode == "off" else "high"}
    return {"thinking": {"type": "disabled" if mode == "off" else "enabled"}}


def _qwen_thinking(_model: str, mode: str) -> dict:
    # enable_thinking is per model (on by default for the 3.x flash/plus/max ids): say it either way
    return {"enable_thinking": mode == "on"} if mode in ("off", "on") else {}


# A local server's model names are the user's; vision is guessed from the well-known multimodal
# families and can always be overridden with BENJI_VISION=1 or 0.
_LOCAL_VISION = (r".*(llava|vision|minicpm-v|moondream|pixtral|bakllava|gemma-?3|qwen[0-9.]*-?vl|-vl\b|internvl|llama-?4|mistral-small3).*",)

PRESETS: dict[str, Preset] = {}


def _add(p: Preset) -> Preset:
    PRESETS[p.name] = p
    return p


DEEPSEEK = _add(Preset(
    name="deepseek", label="DeepSeek",
    endpoints={"intl": "https://api.deepseek.com", "cn": "https://api.deepseek.com"},
    key_envs=("DEEPSEEK_API_KEY",), model="deepseek-flash", key_url="https://platform.deepseek.com/api_keys",
    docs="api-docs.deepseek.com, read 2026-11-05",
    vision=(r"deepseek-flash", r"deepseek-v4-flash(-vision-exp)?"),      # deepseek-v4-pro: no vision
    replay="session", thinking=_deepseek_thinking,
    aliases=("deepseek-ai",),
))

GLM = _add(Preset(
    name="glm", label="Z.ai (GLM)", label_cn="Zhipu AI (GLM, China)",
    endpoints={"intl": "https://api.z.ai/api/paas/v4", "cn": "https://open.bigmodel.cn/api/paas/v4"},
    key_envs=("ZAI_API_KEY", "ZHIPUAI_API_KEY"), model="glm-5.3-flash",
    key_url="https://z.ai/manage-apikey/apikey-list (or open.bigmodel.cn with BENJI_REGION=cn)",
    docs="docs.z.ai and docs.bigmodel.cn, read 2026-11-05",
    vision=(r"glm-5\.3-flash.*", r"glm-5v.*", r"glm-4\.[1-9]v.*", r"glm-4v.*", r"autoglm-phone"),
    stream_options=False,           # not in either doc: usage rides on the last chunk
    thinking=_glm_thinking,
    # a 429 under these codes is an account problem (balance, plan, quota windows), not a busy server
    no_retry_codes=frozenset({"1113", "1308", "1309", "1310", "1311", "1313", "1314", "1315",
                              "1316", "1317", "1318", "1319", "1320", "1321"}),
    refuse_paths=("/coding/",),     # the Coding Plan endpoint is for the vendor's listed tools only
    aliases=("zai", "z.ai", "zhipu", "zhipuai", "bigmodel"),
))

OLLAMA = _add(Preset(
    name="ollama", label="Ollama on this computer",
    endpoints={"intl": "http://localhost:11434/v1", "cn": "http://localhost:11434/v1"},
    key_envs=(), model="", docs="not read: local server; the user names the model",
    local=True, vision=_LOCAL_VISION, stream_options=False,
))

LMSTUDIO = _add(Preset(
    name="lmstudio", label="LM Studio on this computer",
    endpoints={"intl": "http://localhost:1234/v1", "cn": "http://localhost:1234/v1"},
    key_envs=(), model="", docs="not read: local server; the user names the model",
    local=True, vision=_LOCAL_VISION, stream_options=False,
    aliases=("lm-studio", "lm_studio"),
))

QWEN = _add(Preset(
    name="qwen", label="Alibaba Cloud (Qwen)", label_cn="Alibaba Cloud (Qwen, China)",
    # the legacy hosts: the docs call them legacy but say they remain functional; the workspace-dedicated
    # {WorkspaceId}.{region}.maas.aliyuncs.com hosts are the documented way forward and are taken as
    # BENJI_BASE_URL (they need the workspace id, which only the user has)
    endpoints={"intl": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
               "cn": "https://dashscope.aliyuncs.com/compatible-mode/v1"},
    key_envs=("DASHSCOPE_API_KEY",), model="qwen3.8-flash",
    key_url="the Model Studio console of the region you chose (keys do not work across regions)",
    docs="alibabacloud.com/help/en/model-studio, pages dated 2026-10-11 to 2026-11-05, read 2026-11-05",
    vision=(r"qwen3\.[78]-(max|plus|flash)(-[0-9a-z-]+)?", r"qwen3\.8-omni-flash", r"qwen3-vl-[a-z0-9.-]+"),
    max_tokens_param="max_completion_tokens",      # max_tokens is marked "to be deprecated" and leaves out the thinking
    thinking=_qwen_thinking,
    host_suffixes=("aliyuncs.com",),
    aliases=("dashscope", "alibaba", "tongyi"),
))

def _kimi_thinking(_model: str, mode: str) -> dict:
    # K3 models always think and take no `thinking` field; reasoning_effort is low, high or max
    return {"reasoning_effort": "low" if mode == "off" else "high"} if mode in ("off", "on") else {}


KIMI = _add(Preset(
    name="kimi", label="Moonshot AI (Kimi)", label_cn="Moonshot AI (Kimi, China)",
    endpoints={"intl": "https://api.moonshot.ai/v1", "cn": "https://api.moonshot.cn/v1"},
    key_envs=("MOONSHOT_API_KEY",), key_url="https://platform.kimi.ai/console/api-keys (platform.kimi.com for BENJI_REGION=cn)",
    # kimi-k3.1-pro is the docs' flagship and the id in all their examples; the faster
    # kimi-k3.1-pro-highspeed is not listed as reading images, so it is not the default
    model="kimi-k3.1-pro",
    docs="platform.kimi.ai/docs (and platform.kimi.com/docs for China), read 2026-11-05",
    vision=(r"kimi-k3(?:\.1-pro)?", r"kimi-k2\.(?:6|7)(?:-code(?:-highspeed)?)?"),
    max_tokens_param="max_completion_tokens",      # max_tokens is deprecated there
    max_tokens=16000,                              # their guide: at least 16000 for multi-step tool calls
    replay="session", replay_always=True,          # K3: return reasoning_content unchanged (docs: required)
    thinking=_kimi_thinking,
    refuse_paths=("/coding/",),                    # Kimi Code (api.kimi.com / api.kimi.ai) is for coding tools
    aliases=("moonshot",),
))

NAMES = ("claude", "openai") + tuple(PRESETS)       # audit.PROVIDERS is checked against this
_ALIASES = {a: p.name for p in PRESETS.values() for a in p.aliases}


def lookup(raw: str) -> Preset | None:
    raw = raw.strip().lower()
    return PRESETS.get(_ALIASES.get(raw, raw))


def region() -> str:
    """BENJI_REGION: intl (the default) or cn, for the providers that run two platforms with their
    own accounts and keys (GLM, Kimi, Qwen). The two are not interchangeable: a key from one does not
    work on the other."""
    raw = os.environ.get("BENJI_REGION", "").strip().lower()
    if not raw:
        return "intl"
    for name, words in (("intl", ("intl", "international", "global", "world", "sg", "singapore", "us")),
                        ("cn", ("cn", "china", "zh", "beijing", "mainland"))):
        if raw in words:
            return name
    raise SystemExit(f"BENJI_REGION={raw!r} is not one of intl, cn.")


def thinking_mode() -> str:
    """BENJI_THINKING: off (the default: a voice assistant wants a quick answer), on, or default
    (whatever the server does when not told)."""
    raw = os.environ.get("BENJI_THINKING", "").strip().lower()
    if not raw:
        return "off"
    raw = {"0": "off", "false": "off", "no": "off", "1": "on", "true": "on", "yes": "on"}.get(raw, raw)
    if raw not in THINKING_MODES:
        raise SystemExit(f"BENJI_THINKING={raw!r} is not one of {', '.join(THINKING_MODES)}.")
    return raw


def reads_images(preset: Preset | None, model: str) -> bool:
    """Whether Benji may send this model a picture (the screen features need it). BENJI_VISION=1
    or 0 decides when set. Otherwise: Claude, OpenAI and a custom OpenAI-format server are taken to
    read images; a preset says so for the ids its docs name as vision-capable, and an id it doesn't
    name is taken not to be."""
    raw = os.environ.get("BENJI_VISION", "").strip().lower()
    if raw in ("1", "true", "yes", "on"):
        return True
    if raw in ("0", "false", "no", "off"):
        return False
    if preset is None:
        return True
    m = model.strip().lower()
    return any(re.fullmatch(rx, m) for rx in preset.vision)


def is_local_host(host: str | None) -> bool:
    return (host or "").lower() in LOCAL_HOSTS
