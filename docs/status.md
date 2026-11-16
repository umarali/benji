# Feature status

What has been tried live, and what has only been tested offline. Every feature carries one of
three labels, and a label changes only after a live run that is written down.

| Label | What it means |
|---|---|
| **Stable** | Used by the maintainer on one Mac over weeks. Still early software. |
| **Experimental** | Unit-tested offline and run live once, briefly. |
| **Not live-tested** | Unit-tested against fakes (and, where noted, scripted headless checks). Never run for real. |

| Feature | Label | What backs it |
|---|---|---|
| Typed and spoken requests, on-device transcription, spoken answers | Stable | Used daily with Anthropic's API |
| Tool use and approval cards | Stable | Used daily; extensive offline tests |
| Screen context and pointing | Stable | Used live with Claude |
| Guided setup, the panel, saved conversations, explanation cards and 3D figures | Stable | Used live on one Mac |
| Clicking, scrolling and typing on the screen, and drive | Not live-tested | Unit-tested; not yet run live by hand |
| Worked 3D-figure examples, added when you ask to draw something | Experimental | One scripted live run on Haiku: richer figures |
| A private note per conversation, for games with a hidden answer such as hangman | Experimental | One scripted hangman game on Haiku kept the word; not tried by voice |
| Background jobs: the row, *Needs you*, steer, stop | Experimental | One short live run. Not seen live: quitting mid-job, a long job |
| Repeating jobs, Continue, the brief built from the conversation | Not live-tested | Unit-tested with a fake model and clock |
| Audit log, `engine.log`, `benji --diagnose` | Experimental | One short live run; a test fails if message text reaches a log |
| Browser reach: the extension, site grants, acting, the page in front | Not live-tested | Unit-tested and scripted in headless Chrome; never in a real browser profile |
| App offers (Settings › Voice › Offer help in apps, off by default) and their five skills | Not live-tested | Unit-tested |
| Phone control (Settings › Phone, off by default) | Not live-tested | Unit-tested; the real listener and the phone page scripted in headless Chrome; never with a real phone or Tailscale |
| More than one display, full-screen apps | Not live-tested | Offline tests with fake displays |
| Holding back words heard over other apps' sound (Settings › Voice, off by default) | Not live-tested | Unit-tested |
| OpenAI, DeepSeek, GLM, Kimi and Qwen | Not live-tested | Fake servers built from each provider's API docs; `tools/model_smoke.py` checks one live with your key |
| Ollama and LM Studio | Not live-tested | Same |
| `--voice` and `--listen` on the command line | Not live-tested | |
| A signed download, other Macs and macOS versions | Not available | Build from source: see the [setup guide](setup.md) |

## How it is checked

Every pull request runs the offline checks in [GitHub Actions](https://github.com/umarali/benji/actions):
the engine's tests on macOS with Python 3.11 and 3.12, the Swift tests and ServeCheck on `macos-26`,
the extension's tests, and checks on the repository itself. None of them calls a live model.
[How Benji works](architecture.md#tests) lists them and how to run each one. What has been checked
for each model provider is in [providers.md](providers.md).
