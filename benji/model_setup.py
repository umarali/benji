"""First-run model setup: the app's "check" and "test" of the configured model.

It uses the same configuration and provider path as a conversation, but never builds an agent: no
history, memory, tools, screenshot, audit log or answer log is read. The app runs
`python3 -c 'from benji.model_setup import model_setup_main; model_setup_main()'`.
"""

from __future__ import annotations

import json
import os
import sys

from . import audit
from . import errors as errors_mod
from . import providers as providers_mod
from .providers import ProviderError

MODEL_SETUP_SYSTEM = "This is a connection test. Reply OK."
MODEL_SETUP_MESSAGE = "Reply OK."


def model_setup(expected: dict | None = None) -> dict:
    """None probes only. Metadata from that probe explicitly authorizes one provider completion.

    Refuse changed configuration before sending anything, so the destination on the setup button
    is the destination actually tested. Only metadata and redacted errors return to the app.
    """
    from .config import load_config, is_secret_name
    from . import presets
    from urllib.parse import urlparse

    def safe(text):
        text = str(text)
        for name, value in os.environ.items():
            if is_secret_name(name) and value:
                text = text.replace(value, "[key]")
        return audit.redact(text)

    inherited = dict(os.environ)
    keychain_names = set(os.getenv("BENJI_SETUP_KEYCHAIN_KEYS", "").split(","))
    try:
        cfg = load_config()
        local = bool(cfg.preset and cfg.preset.local and presets.is_local_host(urlparse(cfg.base_url).hostname))
        key_name = None
        if cfg.api_key:
            if cfg.preset and not cfg.preset.local and cfg.preset.is_own_host(urlparse(cfg.base_url).hostname or ""):
                key_name = next((name for name in cfg.preset.key_envs if os.getenv(name, "").strip()), None)
            elif cfg.base_url:
                key_name = "BENJI_API_KEY"
            else:
                key_name = "ANTHROPIC_API_KEY" if cfg.provider == "claude" else "OPENAI_API_KEY"
        origin = "local model settings" if local and not cfg.api_key else "server settings"
        if key_name:
            handed = inherited.get(key_name, "").strip() == cfg.api_key
            origin = "Keychain" if handed and key_name in keychain_names else ("engine environment" if handed else "key file")
        source = {
            "provider": cfg.provider, "model": safe(cfg.model),
            "destination": safe(cfg.destination), "host": safe(cfg.host),
            "origin": origin, "local": local,
            "usesKey": bool(cfg.api_key),
        }
        if key_name:
            source["keyVariable"] = key_name
        if expected is not None:
            if expected != source:
                return {"ok": False, "error": "Model settings changed. Check the source again before testing."}
            provider = providers_mod.make_provider(cfg.provider, cfg.api_key, cfg.model, cfg.base_url,
                                                   thinking=cfg.thinking, max_tokens=cfg.max_tokens, vision=cfg.vision)
            if isinstance(provider, providers_mod.OpenAIProvider):
                provider.max_tokens = min(provider.max_tokens, 256 if local else 64)
            answer = provider.complete(MODEL_SETUP_SYSTEM, [{"role": "user", "text": MODEL_SETUP_MESSAGE}], [])
            if not answer.get("text", "").strip() or answer.get("tool_calls"):
                return {"ok": False, "error": "The server connected but returned no text within the test limit. Try again; a reasoning model may need more output tokens."}
        return {"ok": True, "source": source}
    except (SystemExit, ProviderError, OSError, ValueError) as error:
        _, words = errors_mod.explain(str(error))
        if isinstance(error, SystemExit) and str(error).startswith("No API key found."):
            words = "No model key found. Add an Anthropic API key or use a local model."
        elif isinstance(error, SystemExit) and "BENJI_BASE_URL" in str(error) and "%" in os.getenv("BENJI_BASE_URL", ""):
            words = "Use a plain http or https server address. For a local model, use localhost, 127.0.0.1 or ::1 without percent encoding."
        elif isinstance(error, TimeoutError) or "timed out" in str(error).lower():
            words = "The test timed out. The request may have reached the model."
        return {"ok": False, "error": safe(words)[:300]}


def model_setup_main() -> None:
    """Private app entry point. A JSON null probes; the source object from a probe requests Test.
    The key is inherited through the usual key environment, never stdin or command arguments.
    """
    # One attempt, no continuation, 64 hosted / 256 local output tokens and a 60 s request
    # timeout, shorter than the app's 90 s deadline. Restore globals for in-process tests.
    limits = (providers_mod.RETRIES, providers_mod.MAX_CONTINUATIONS, providers_mod.ANTHROPIC_MAX_TOKENS,
              providers_mod.TIMEOUT)
    try:
        providers_mod.RETRIES = 0
        providers_mod.MAX_CONTINUATIONS = 0
        providers_mod.ANTHROPIC_MAX_TOKENS = 64
        providers_mod.TIMEOUT = 60
        expected = json.loads(sys.stdin.read(16384))
        if expected is not None and not isinstance(expected, dict):
            raise ValueError("invalid setup request")
        reply = model_setup(expected)
    except Exception:
        reply = {"ok": False, "error": "Benji couldn't finish the model check. Check the engine configuration and try again."}
    finally:
        (providers_mod.RETRIES, providers_mod.MAX_CONTINUATIONS, providers_mod.ANTHROPIC_MAX_TOKENS,
         providers_mod.TIMEOUT) = limits
    # A leading newline also separates the reply from a login profile that printed no newline.
    print("\n" + json.dumps(reply), flush=True)
