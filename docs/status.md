# Feature status

What has been tried live and what has only been tested offline, feature by feature. A label changes only after a live run that is written down.

Labels, used honestly. **Stable** = used by the maintainer on one Mac over weeks; still early
software. **Experimental** = unit-tested offline and run live once, briefly. **Not live-tested** =
unit-tested against fakes (and, where noted, scripted headless checks); never run for real.

| Feature | Label | What backs it |
|---|---|---|
| Typed and spoken requests, on-device transcription, spoken answers | Stable | Used daily against Anthropic's API on one Mac |
| Tool use and the approval gate (cards in the app, `y/N` in the terminal) | Stable | Used daily; extensive offline tests |
| Screen context and pointing | Stable | Used live with Claude; other models: see providers |
| Permissions setup, panel, history, explain cards and figures | Stable | Used live on one Mac; other Macs, macOS versions and displays untested |
| External-display entry bars and per-message display selection; focused setup helper and dimensional cursor | Not live-tested | Offline tests with injected displays and capture callbacks; native offscreen renders at 1× and 2×. No live multi-display, full-screen or permission interaction verified |
| Worked 3D-figure examples (a build recipe plus one example from the nearest family, added only when you ask to draw something) | Experimental | Unit-tested; checked live on Haiku 5.5 in a scripted eval (32 calls over eight things the prompt never mentions): figures were richer and the bicycle wheels and guitar came out right. A small sample, one model |
| A private note the model keeps for a conversation (for games with a hidden answer such as hangman) | Experimental | Unit-tested; a four-turn hangman run against Haiku 5.5 through the eval harness kept the word to the end. Not yet tried by voice in the app; the model still misplaces letters on the board at times |
| App offers (a notch card that suggests a skill when you open Reminders, Music, Things, Obsidian or a GitHub page; Settings → "Offer help in apps", off by default) and those five skills | Not live-tested | Unit-tested; the card was never seen in the real app and none of the five skills has been run for real |
| Words held back because another app was playing sound are kept in the input box (the menu's hold-back setting, off by default) | Not live-tested | Unit-tested only |
| In-panel Esc stops an answer before folding; refused screen captures keep typed or spoken words and offer Send without screen | Not live-tested | Unit-tested with a fake backend and injected capture errors; not exercised in the app |
| Gate and taint refinements made after the first jobs run (a screen-only look no longer asks before starting a job; read-only compound shell commands such as `a; b`, `a && b`, `a \| b`) | Not live-tested | Unit-tested, including a 10,000-command fuzz run; built into the app but not exercised by hand |
| Background jobs (row, approvals parked as *Needs you*, steer, stop, recall) | Experimental | Unit-tested; one short live run on 2026-11-05 (row, approvals by the row's buttons, a declined write, the foreground staying free). **Not yet seen live:** quitting mid-job, a long wait, a long job |
| Jobs, second pass: repeating jobs (after a card; read-only when unattended), Continue, the brief read again to a long job, a plain report at the step limit, a 30-minute memory of "not now", the brief built from the conversation | Not live-tested | Unit-tested with a fake model and a fake clock (sleep, clock jumps, corrupt schedule files, an instruction in a page); never run in the real app |
| Metadata-only audit log, `engine.log`, `benji --diagnose` | Experimental | Unit-tested, with a test that fails if message text reaches a log; one short live run (the report and file modes were checked) |
| Browser reach (extension, native host, per-job site grants, acting, the front tab) | Not live-tested | Unit-tested; 33 scripted checks in a headless Chrome with a throwaway profile (look, click, type, upload, keys, close). Never run in a real browser profile, never with the real model |
| OpenAI provider | Not live-tested | Unit-tested against a fake server |
| DeepSeek, GLM, Kimi and Qwen providers | Not live-tested | Fake servers that reproduce each provider's documentation as read on 2026-11-05 (the documents may have moved on). `tools/model_smoke.py` is a live check you can run with your own key |
| Ollama and LM Studio (local models) | Not live-tested | Same |
| `--voice` and `--listen` (cloud transcription, wake word) | Not live-tested | |
| Notarised download, other Macs and macOS versions | Not available / untested | See [Building from source](building.md#build-from-source) |

Offline checks run in [GitHub Actions](https://github.com/umarali/benji/actions): engine selftests
on macOS with Python 3.11 and 3.12 (through `tools/isolated_run.py`, as in the contribution guide),
Swift tests and ServeCheck on `macos-26`, extension tests, and repository checks.
Details per feature are in the [docs](README.md) and [providers.md](providers.md).
