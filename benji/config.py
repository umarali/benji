"""Runtime configuration: provider/model detection and the working folder."""

from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from . import aliases, home, presets
from .usage import enabled as usage_enabled

# Sensible defaults. If the API rejects the model id, override with BENJI_MODEL.
# Claude: Haiku 5.5 at low effort (the user's choice, 2026-10-31); BENJI_MODEL=claude-sonnet-5-5
# is the documented secondary, for better figures (the effort implementation note).
DEFAULT_MODELS = {
    "claude": "claude-haiku-5-5",
    "openai": "gpt-4o",
}


KEY_SOURCE_VAR = aliases.KEY_SOURCE_NAMES[0]        # "keychain": the app keeps the keys and hands them over (D-173)
_SECRET_NAMES = frozenset({"SERPAPI_KEY"})


def is_secret_name(name: str) -> bool:
    """A variable that holds a key: `*_API_KEY` and the few other key names Benji reads. The app's
    Keychain code (BenjiCore/KeyStore.swift) uses the same rule; both are tested against one table."""
    upper = name.strip().upper()
    return upper.endswith("_API_KEY") or upper in _SECRET_NAMES


def keys_from_keychain() -> bool:
    """The app started this engine in Keychain mode (BENJI_KEY_SOURCE=keychain, set by the app).
    Then a key is read from the environment the app handed over and from nowhere else: the key
    lines of the home env files are not read even if they are still there, so there is no silent
    fallback to a plaintext file once the user has moved the key. Any of the variable's names saying
    "keychain" is enough, whatever the others say: a conflict fails closed."""
    return any(os.environ.get(name, "").strip().lower() == "keychain" for name in aliases.KEY_SOURCE_NAMES)


def missing_key_hint() -> str:
    return (" Benji's app keeps your key in the Keychain and hands it to its engine when it starts; "
            "open Benji's Settings to check it. (Keys in ~/.benji.env and older key files are not used while the Keychain is on.)"
            if keys_from_keychain() else "")


def load_dotenv() -> None:
    """Load KEY=VALUE lines from the home env files into the environment, as canonical BENJI_* names.

    In order of strength: a real environment variable under any of its names (BENJI_* over CHILLY_* over
    PAL_*), then ~/.benji.env, ~/.chilly.env, ~/.pal.env, and within one file BENJI_* over CHILLY_* over
    PAL_*. No file overrides a real variable. Never from the current folder (chilly-gate fix 12): a folder
    Benji is started in could otherwise point it at another server.

    Keychain mode, set under any name in the environment or in any of these files, keeps every key line
    of every file out. There is no silent fallback to a plaintext file.
    """
    aliases.adopt()
    home.migrate_key_file()
    parsed = [_read_env_file(path) for path in home_env_files()]
    keychain = keys_from_keychain() or any(
        key in aliases.KEY_SOURCE_NAMES and value.strip().lower() == "keychain"
        for lines in parsed for key, value in lines)
    for lines in parsed:
        chosen: dict[str, tuple[int, str]] = {}
        for key, value in lines:            # the newest name wins in a file; then the first line of it
            name, strength = aliases.canonical_name(key), aliases.rank(key)
            if name not in chosen or strength < chosen[name][0]:
                chosen[name] = (strength, value)
        for name, (_, value) in chosen.items():
            if keychain and is_secret_name(name):
                continue                    # fail closed: the key comes from the Keychain, never from a file
            os.environ.setdefault(name, value)
    if keychain:
        os.environ[KEY_SOURCE_VAR] = "keychain"


def home_env_files() -> tuple[Path, ...]:
    return tuple(Path.home() / name for name in (".benji.env", ".chilly.env", ".pal.env"))


def _read_env_file(path: Path) -> list[tuple[str, str]]:
    try:
        if not path.is_file():
            return []
        text = path.read_text()
    except OSError:
        return []
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        lines.append((key.strip(), val.strip().strip('"').strip("'")))
    return lines


@dataclass
class Config:
    provider: str
    model: str
    api_key: str
    workdir: Path
    skills_dir: Path
    memory_path: Path
    usage_path: Path | None = None  # token-usage log; None when BENJI_USAGE_LOG=0
    auto_approve: bool = False
    base_url: str | None = None  # an OpenAI-compatible server other than OpenAI
    preset: presets.Preset | None = None    # DeepSeek, GLM, Kimi, Qwen, Ollama, LM Studio (D-147)
    region: str = "intl"
    thinking: str = "off"
    vision: bool = True             # the model can read pictures; if not, Screen stays off
    max_tokens: int | None = None

    @property
    def host(self) -> str:
        """The host (and port) the data goes to; never a key or a path."""
        if self.base_url:
            return _hostport(self.base_url)
        return "api.anthropic.com" if self.provider == "claude" else "api.openai.com"

    @property
    def destination(self) -> str:
        """Who receives what Benji sends: a company name, or the custom server's host."""
        if self.base_url:
            if self.preset is not None and self.preset.is_own_host(urlparse(self.base_url).hostname or ""):
                return (self.preset.label_cn if self.region == "cn" and self.preset.label_cn else self.preset.label)
            return self.host
        return "Anthropic" if self.provider == "claude" else "OpenAI"

    @property
    def sends_to(self) -> str:
        """The startup line's words: who, and which host ("DeepSeek (api.deepseek.com)")."""
        return self.destination if self.destination == self.host else f"{self.destination} ({self.host})"

    @property
    def output_dir(self) -> Path:
        return self.workdir / "output"

    @property
    def tmp_dir(self) -> Path:
        return self.workdir / "tmp"


def _is_private_host(host: str) -> bool:
    if host == "localhost" or host.endswith((".local", ".ts.net")):
        return True
    try:
        return not ipaddress.ip_address(host).is_global
    except ValueError:
        return False


def _hostport(url: str) -> str:
    parts = urlparse(url)
    host = parts.hostname or ""
    return f"{host}:{parts.port}" if parts.port else host


def _base_url() -> str | None:
    """BENJI_BASE_URL points the OpenAI-format provider at another server, e.g.
    https://openrouter.ai/api/v1 or http://localhost:11434/v1 (Ollama)."""
    url = os.getenv("BENJI_BASE_URL", "").strip()
    if not url:
        return None
    parts = urlparse(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise SystemExit(f"BENJI_BASE_URL={url!r} must be an http(s) URL.")
    if parts.scheme == "http" and not _is_private_host(parts.hostname):
        raise SystemExit(f"BENJI_BASE_URL={url!r} would send your data unencrypted; use https.")
    return url


def _preset_url(preset: presets.Preset, override: str | None, region: str) -> str:
    """The base URL a preset sends to. Stricter than a custom server: plain http only for a server
    on this computer (localhost, 127.0.0.1, ::1) and only for the local presets; a hosted provider
    is https always; and a provider's coding-plan endpoint is refused (it is for its listed tools)."""
    url = (override or preset.endpoints[region]).strip()
    parts = urlparse(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise SystemExit(f"BENJI_BASE_URL={url!r} must be an http(s) URL.")
    if parts.scheme == "http" and not (preset.local and presets.is_local_host(parts.hostname)):
        where = "only a local server (localhost or 127.0.0.1) may use http" if preset.local else \
                f"{preset.label} is reached over https only"
        raise SystemExit(f"BENJI_BASE_URL={url!r} would send your data unencrypted: {where}.")
    for path in preset.refuse_paths:
        if path in parts.path + "/":
            raise SystemExit(f"BENJI_BASE_URL={url!r} is {preset.label}'s coding-plan endpoint, which its terms "
                             "limit to its listed coding tools. Use the standard API endpoint.")
    return url.rstrip("/")


def _detect_provider(base_url: str | None) -> str:
    forced = os.getenv("BENJI_PROVIDER", "").strip().lower()
    if forced in ("claude", "anthropic"):
        if base_url:
            raise SystemExit("BENJI_BASE_URL works only with BENJI_PROVIDER=openai or an open-model "
                             "provider (OpenAI-compatible servers).")
        return "claude"
    if forced in ("openai", "gpt"):
        return "openai"
    if forced:
        preset = presets.lookup(forced)
        if preset is None:
            raise SystemExit(f"Unknown BENJI_PROVIDER={forced!r} (use {', '.join(presets.NAMES)}).")
        return preset.name
    if base_url:
        return "openai"
    # Auto-detect from whichever key is present; prefer Anthropic if both.
    if os.getenv("ANTHROPIC_API_KEY"):
        return "claude"
    if os.getenv("OPENAI_API_KEY"):
        return "openai"
    found = [p.name for p in presets.PRESETS.values() if any(os.getenv(k, "").strip() for k in p.key_envs)]
    if len(found) == 1:
        return found[0]
    if found:
        raise SystemExit(f"More than one provider's key is set ({', '.join(found)}); "
                         "choose with BENJI_PROVIDER.")
    raise SystemExit(
        "No API key found. Set ANTHROPIC_API_KEY or OPENAI_API_KEY, or the key of an open-model provider "
        "(DEEPSEEK_API_KEY, ZAI_API_KEY, MOONSHOT_API_KEY, DASHSCOPE_API_KEY) with BENJI_PROVIDER, "
        "or run a local model (BENJI_PROVIDER=ollama or lmstudio)."
        + (missing_key_hint() or " Put the key in ~/.benji.env (copy .benji.env.example to it), or export it in your shell.")
    )


def _api_key_for(provider: str, base_url: str | None, preset: presets.Preset | None = None) -> str:
    if preset is not None:
        own = base_url is None or preset.is_own_host(urlparse(base_url).hostname or "")
        if preset.local:
            return os.getenv("BENJI_API_KEY", "").strip()      # a local server needs none
        if own:
            for env in preset.key_envs:
                key = os.getenv(env, "").strip()
                if key:
                    return key
            raise SystemExit(f"Provider {preset.name!r} selected but {preset.key_envs[0]} is not set. "
                             f"Make a key at {preset.key_url} and put it in ~/.benji.env." + missing_key_hint())
        # Never send the provider's key to some other host.
        key = os.getenv("BENJI_API_KEY", "").strip()
        if not key:
            raise SystemExit(f"BENJI_BASE_URL is not {preset.label}'s host, so {preset.key_envs[0]} is not "
                             "sent there; set BENJI_API_KEY to that server's key.")
        return key
    if base_url:
        # Never send the OpenAI key to some other host; local servers may need no key.
        return os.getenv("BENJI_API_KEY", "").strip()
    env = "ANTHROPIC_API_KEY" if provider == "claude" else "OPENAI_API_KEY"
    key = os.getenv(env, "").strip()
    if not key:
        raise SystemExit(f"Provider {provider!r} selected but {env} is not set." + missing_key_hint())
    return key


def _max_tokens() -> int | None:
    raw = os.getenv("BENJI_MAX_TOKENS", "").strip()
    if not raw:
        return None
    if not raw.isdigit() or not 256 <= int(raw) <= 1_000_000:
        raise SystemExit(f"BENJI_MAX_TOKENS={raw!r} must be a number from 256 to 1000000.")
    return int(raw)


def workdir_path(workdir: str | None = None) -> Path:
    """The working folder: --workdir, else $BENJI_WORKDIR (or an older name of it), else ~/.benji.
    Needs no API key. The default is Benji's one hidden home folder; the first call moves an older
    ~/.chilly, ~/chilly or ~/pal into it, once (benji/home.py). An explicit folder is used as
    given and nothing is moved."""
    chosen = workdir or home.workdir_override()
    if chosen:
        return Path(chosen).expanduser()
    found = home.migrate()
    if found.kind in ("failed", "busy") and found.folder is not None:
        return found.folder             # the move was impossible or Benji is running: keep using the old folder, move nothing
    folder = home.home_dir()
    home.ensure(folder)
    return folder


def load_config(workdir: str | None = None,
                model: str | None = None,
                auto_approve: bool = False) -> Config:
    load_dotenv()
    base_url = _base_url()
    provider = _detect_provider(base_url)
    preset = presets.PRESETS.get(provider)
    region = presets.region()
    if preset is not None:
        base_url = _preset_url(preset, base_url, region)
    api_key = _api_key_for(provider, base_url if preset is None or os.getenv("BENJI_BASE_URL", "").strip() else None,
                           preset)
    model = model or os.getenv("BENJI_MODEL", "").strip()
    if not model and base_url and preset is None:
        raise SystemExit("BENJI_BASE_URL is set, so name the model with BENJI_MODEL "
                         "(as that server lists it).")
    if not model and preset is not None and not preset.model:
        raise SystemExit(f"{preset.label}: name the model you have loaded with BENJI_MODEL "
                         "(Ollama: the name `ollama list` shows; LM Studio: the model's id in its server tab).")
    model = model or (preset.model if preset is not None else DEFAULT_MODELS[provider])
    thinking = presets.thinking_mode() if preset is not None else "off"
    vision = presets.reads_images(preset, model) if provider != "claude" else True

    wd = workdir_path(workdir)
    (wd / "output").mkdir(parents=True, exist_ok=True)
    (wd / "tmp").mkdir(parents=True, exist_ok=True)

    # Skills ship with the package: assistant/skills/
    skills_dir = Path(__file__).resolve().parent.parent / "skills"

    return Config(
        provider=provider,
        model=model,
        api_key=api_key,
        workdir=wd,
        skills_dir=skills_dir,
        memory_path=wd / "memory.jsonl",
        usage_path=wd / "usage.jsonl" if usage_enabled() else None,
        auto_approve=auto_approve,
        base_url=base_url,
        preset=preset,
        region=region,
        thinking=thinking,
        vision=vision,
        max_tokens=_max_tokens() if preset is not None else None,
    )
