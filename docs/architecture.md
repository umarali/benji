# How Benji works

Benji has two main parts and one optional one:

- **The app** (`companion/`) is what you see: the notch, the panel, approval cards, pointing
  marks and 3D figures. It is written in Swift.
- **The engine** (`benji/`) does the work: it talks to the model, runs tools and decides what
  needs your approval. It is written in Python and uses only the standard library.
- **The browser extension** (`browser-extension/`) is optional. It lets a background job read,
  and if you allow it, act on sites in your own Chromium browser.

```
 Benji.app (Swift)  ── JSON lines over stdin/stdout ──▶  benji --serve (Python)  ── HTTPS ──▶  your model provider
                                                               ▲
                                                     127.0.0.1, with a token
                                                               │
                          Chrome extension ◀── native messaging ──▶  benji/browser_host.py
```

## The app

- A SwiftPM package with two targets. `BenjiCore` holds logic that has no user interface and is
  unit-tested; `BenjiApp` holds the AppKit and SwiftUI code.
- Speech is transcribed on the Mac with Apple's on-device recognition. Only text reaches the engine.
- The app starts one engine for itself: `python3 -m benji --serve`, run through a zsh login shell
  from the checkout the app was built in. Set `BENJI_DIR` to use another checkout. Because the
  engine is loaded from the checkout, keep `Benji.app` inside it.

## The engine

The same engine serves the app and the command line (`python3 -m benji "…"`). The main modules:

| Module | What it does |
|---|---|
| `agent.py` | The tool-use loop, independent of any provider |
| `providers.py`, `presets.py` | Adapters for Anthropic's API and OpenAI-compatible APIs, and the provider presets |
| `tools/`, `gate.py`, `policy.py` | The tools (one module per kind), and the rules that decide whether a call runs, asks or is refused (`tools/approval.py`) |
| `serve.py` | The long-lived process the app talks to |
| `jobs.py`, `schedule.py` | Background jobs and repeating jobs |
| `browser_link.py`, `browser_host.py`, `browser.py`, `browser_act.py` | The link to the extension, and what a job may read or do in the browser |
| `prompts.py` | The system prompt |
| `figures.py`, `pointing.py`, `cards.py` | The formats for 3D figures, pointing marks and explanation cards |
| `audit.py`, `diagnose.py` | The metadata-only audit log and the `--diagnose` report |
| `config.py`, `home.py` | Settings, provider detection and Benji's folder |

## How the app and the engine talk

The app writes one JSON object per line to the engine's standard input, and reads one per line
from its standard output. The app sends messages, screen pictures, approval answers, and job
and browser controls. The engine streams the answer as it is written, then reports tool activity,
approval requests, job updates, token usage and the end of each turn.

The message types are defined in two places that are tested against each other:
[`benji/serve.py`](../benji/serve.py) and
[`companion/Sources/BenjiCore/Engine/ServeProtocol.swift`](../companion/Sources/BenjiCore/Engine/ServeProtocol.swift).
`companion/ServeCheck` runs the app's real backend code against a real engine and a fake model.

## How the browser extension connects

The engine listens on `127.0.0.1` only, on a port the system picks, behind a token made fresh
for each run. When the extension connects, Chrome starts `benji/browser_host.py`, which reads the
port and token from a private file, checks that the caller is the Benji extension, and then
relays messages both ways. The host reads no pages and runs no commands.
[Safety, jobs and browser reach](safety.md#browser-reach) covers what a job may do there.

## Where things are kept

- **Benji's folder**, `~/.benji` by default (`BENJI_WORKDIR` changes it): memory, saved
  conversations, job folders, the audit log and the engine log. Log files are readable by you only.
- **Your API key**: `~/.benji.env`, or the macOS Keychain if you choose it in the app.

[Privacy](privacy.md) lists every file and what leaves your Mac.

## Tests

| Where | What | Run it |
|---|---|---|
| `tests/` | The engine, offline, with fake models | `python3 tools/isolated_run.py -- python3 tests/selftest.py` |
| `companion/Tests/` | The app's logic | `cd companion && xcrun swift test` |
| `browser-extension/test/` | The extension's rules | `node --test browser-extension/test/*.test.mjs` |
| `companion/ServeCheck/` | The app's backend against a real engine | `python3 -I companion/ServeCheck/run.py` |

None of them calls a live model. GitHub Actions runs all four on macOS for every pull request.
