"""Offline first-run model checks. Real config/provider conversion, fake HTTP transport only."""
from __future__ import annotations

import io
import json
import os
import tempfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


def run(check, here):
    from benji import config, providers, serve

    print("first-run model setup:")
    fake_key = "fake-model-key-for-tests"
    with tempfile.TemporaryDirectory() as td:
        folder = Path(td)
        env = {"HOME": td, "BENJI_WORKDIR": str(folder / "work"), "BENJI_KEY_SOURCE": "keychain",
               "BENJI_MIGRATION_GUARD": "abort", "BENJI_PROMPT_CACHE": "0"}
        claude = {**env, "BENJI_PROVIDER": "claude", "ANTHROPIC_API_KEY": fake_key, "BENJI_MODEL": "test-model",
                  "BENJI_SETUP_KEYCHAIN_KEYS": "ANTHROPIC_API_KEY"}
        response = {"content": [{"type": "text", "text": "OK"}], "stop_reason": "end_turn", "usage": {}}
        with patch.dict(os.environ, env, clear=True), patch.object(providers, "_post") as post:
            missing = serve.model_setup()
            check("setup without a model source fails without an HTTP request", not missing["ok"] and post.call_count == 0)

        inherited = {name: value for name, value in claude.items() if name not in ("BENJI_KEY_SOURCE", "BENJI_SETUP_KEYCHAIN_KEYS")}
        with patch.dict(os.environ, inherited, clear=True), patch.object(providers, "_post") as post:
            inherited_probe = serve.model_setup()
            check("an existing engine environment key is detected without being tested",
                  inherited_probe["ok"] and inherited_probe["source"]["origin"] == "engine environment"
                  and post.call_count == 0)

        keychain_mode_inherited = {name: value for name, value in claude.items() if name != "BENJI_SETUP_KEYCHAIN_KEYS"}
        with patch.dict(os.environ, keychain_mode_inherited, clear=True), patch.object(providers, "_post") as post:
            found = serve.model_setup()
            check("Keychain mode does not misattribute an inherited environment key to the Keychain",
                  found["ok"] and found["source"]["origin"] == "engine environment" and not post.called)

        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post", return_value=response) as post:
            probe = serve.model_setup()
            check("setup probe detects Keychain-backed config and never calls the model",
                  probe["ok"] and probe["source"]["origin"] == "Keychain" and post.call_count == 0)
            check("setup metadata never includes the key or key field",
                  fake_key not in json.dumps(probe) and "api_key" not in probe["source"])
            result = serve.model_setup(probe["source"])
            check("explicit setup Test uses the normal provider once and returns the tested source",
                  result == probe and post.call_count == 1)
            url, headers, body = post.call_args.args
            check("Anthropic test sends only the fixed instruction and short text, with no tools",
                  url == providers.AnthropicProvider.API and headers["x-api-key"] == fake_key
                  and body["system"] == serve.MODEL_SETUP_SYSTEM
                  and body["messages"] == [{"role": "user", "content": [{"type": "text", "text": "Reply OK."}]}]
                  and body["tools"] == [])
            post.reset_mock()
            changed = {**probe["source"], "host": "somewhere-else.example"}
            check("a destination changed since disclosure is refused before HTTP",
                  not serve.model_setup(changed)["ok"] and post.call_count == 0)

        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post", side_effect=providers.ProviderError(
                f"HTTP 401 from https://api.anthropic.com/v1/messages: echoed {fake_key}")):
            result = serve.model_setup(probe["source"])
            check("setup reports the real authentication error in plain words without the key",
                  not result["ok"] and "HTTP 401" in result["error"] and "didn't accept" in result["error"]
                  and fake_key not in json.dumps(result))

        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post", side_effect=providers.ProviderError(
                f"HTTP 400 from https://api.anthropic.com/v1/messages: invalid model, echoed {fake_key}")):
            result = serve.model_setup(probe["source"])
            check("unmapped provider errors keep the useful error and redact exact secret values",
                  not result["ok"] and "invalid model" in result["error"] and fake_key not in json.dumps(result))

        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post", side_effect=providers.ProviderError(
                "invalid model: " + fake_key + " " + "detail " * 200)):
            result = serve.model_setup(probe["source"])
            check("provider diagnostics are redacted before being bounded to 300 characters",
                  not result["ok"] and len(result["error"]) <= 300 and fake_key not in result["error"])

        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post", return_value={"content": [], "usage": {}}):
            check("an empty model answer is never a passing test", not serve.model_setup(probe["source"])["ok"])

        for provider, port in (("ollama", 11434), ("lmstudio", 1234)):
            local = {**env, "BENJI_PROVIDER": provider, "BENJI_MODEL": "test-local-model"}
            reply = {"choices": [{"message": {"content": "OK"}, "finish_reason": "stop"}], "usage": {}}
            with patch.dict(os.environ, local, clear=True), patch.object(providers, "_post", return_value=reply) as post:
                found = serve.model_setup()
                check(f"{provider} existing source is local, keyless and probed without HTTP",
                      found["ok"] and found["source"]["local"] and found["source"]["origin"] == "local model settings"
                      and post.call_count == 0)
                result = serve.model_setup(found["source"])
                check(f"{provider} Test uses its normal local endpoint exactly once",
                      result["ok"] and post.call_count == 1
                      and post.call_args.args[0] == f"http://localhost:{port}/v1/chat/completions")
                check(f"{provider} Test allows 256 output tokens for reasoning models",
                      post.call_args.args[2]["max_tokens"] == 256)
                check(f"{provider} Test sends no API key, history, tools or files",
                      "Authorization" not in post.call_args.args[1]
                      and post.call_args.args[2]["messages"] == [
                          {"role": "system", "content": serve.MODEL_SETUP_SYSTEM},
                          {"role": "user", "content": "Reply OK."}]
                      and not post.call_args.args[2].get("tools"))

        with patch.dict(os.environ, {**env, "BENJI_PROVIDER": "ollama"}, clear=True), patch.object(providers, "_post") as post:
            check("a local provider without a model name does not complete setup",
                  not serve.model_setup()["ok"] and post.call_count == 0)

        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post") as post, \
                patch("sys.stdin", io.StringIO("null")), redirect_stdout(io.StringIO()) as output:
            serve.model_setup_main()
            probe_ok = json.loads(output.getvalue())["ok"] and post.call_count == 0
        check("the app's JSON-null entry point is a probe, never an automatic test", probe_ok)

        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post", return_value=response) as post, \
                patch("sys.stdin", io.StringIO(json.dumps(probe["source"]))), redirect_stdout(io.StringIO()) as output:
            serve.model_setup_main()
            bounded_ok = json.loads(output.getvalue())["ok"] and post.call_count == 1 and post.call_args.args[2]["max_tokens"] == 64
        check("the app Test entry point bounds Anthropic's output to 64 tokens", bounded_ok)

        for provider in ("ollama", "lmstudio"):
            encoded = {**env, "BENJI_PROVIDER": provider, "BENJI_MODEL": "test", "BENJI_BASE_URL": "http://%6cocalhost:11434/v1"}
            with patch.dict(os.environ, encoded, clear=True), patch.object(providers, "_post") as post:
                result = serve.model_setup()
                check(f"{provider} encoded local host fails in plain words before HTTP",
                      not result["ok"] and "without percent encoding" in result["error"]
                      and "SystemExit" not in result["error"] and "BENJI_BASE_URL=" not in result["error"] and not post.called)

        custom = {**env, "BENJI_PROVIDER": "openai", "BENJI_MODEL": "test", "BENJI_BASE_URL": "https://server.example/v1"}
        with patch.dict(os.environ, custom, clear=True), patch.object(providers, "_post") as post:
            found = serve.model_setup()
            check("a keyless custom server reports no key usage",
                  found["ok"] and not found["source"]["usesKey"] and found["source"].get("keyVariable") is None and not post.called)

        # Real disposable config storage proves saving one Keychain key leaves file tool keys active.
        mixed = {**claude, "BENJI_KEY_SOURCE": "file"}
        key_file = folder / ".benji.env"
        key_file.write_text("SERPAPI_KEY=fake-file-search-value\n")
        try:
            with patch.dict(os.environ, mixed, clear=True), patch.object(providers, "_post") as post:
                found = serve.model_setup()
                check("a saved Anthropic key coexists with the file's tool keys without moving them",
                      found["ok"] and found["source"]["origin"] == "Keychain"
                      and os.environ.get("SERPAPI_KEY") == "fake-file-search-value" and not post.called
                      and key_file.read_text() == "SERPAPI_KEY=fake-file-search-value\n")
        finally:
            key_file.unlink()

        old_limits = (providers.RETRIES, providers.MAX_CONTINUATIONS, providers.ANTHROPIC_MAX_TOKENS, providers.TIMEOUT)
        timeouts = []
        def timed_out(*args, **kwargs):
            timeouts.append(providers.TIMEOUT)
            raise TimeoutError("timed out")
        with patch.dict(os.environ, claude, clear=True), patch.object(providers, "_post", side_effect=timed_out), \
                patch("sys.stdin", io.StringIO(json.dumps(probe["source"]))), redirect_stdout(io.StringIO()) as output:
            serve.model_setup_main()
            result = json.loads(output.getvalue())
            check("a request timeout states it may have reached the model",
                  result["error"] == "The test timed out. The request may have reached the model.")
        check("setup request has a 60 second timeout before the app's 90 second deadline", timeouts == [60])
        check("setup restores the timeout and all other provider limits after failure",
              old_limits == (providers.RETRIES, providers.MAX_CONTINUATIONS, providers.ANTHROPIC_MAX_TOKENS, providers.TIMEOUT))

        from urllib.error import HTTPError
        local = {**env, "BENJI_PROVIDER": "ollama", "BENJI_MODEL": "test-local-model"}
        with patch.dict(os.environ, local, clear=True):
            expected = serve.model_setup()["source"]
            error = HTTPError("http://localhost:11434/v1/chat/completions", 503, "busy", {}, io.BytesIO(b'{"error":"busy"}'))
            with patch("urllib.request.urlopen", side_effect=error) as opening, \
                    patch("sys.stdin", io.StringIO(json.dumps(expected))), redirect_stdout(io.StringIO()) as output:
                serve.model_setup_main()
                once = not json.loads(output.getvalue())["ok"] and opening.call_count == 1
            check("Test makes only one HTTP attempt, even when the local server is busy", once)
        check("setup restores provider limits for the surrounding test process",
              providers.RETRIES > 0 and providers.MAX_CONTINUATIONS > 0 and providers.ANTHROPIC_MAX_TOKENS > 64)
