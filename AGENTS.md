# Guide for coding agents

## Where things are

- `benji/`: the Python engine and command line (standard library only).
- `companion/`: the macOS app, a SwiftPM package. Logic without UI goes in `BenjiCore`, with tests in `companion/Tests`.
- `browser-extension/`: the optional Chromium extension, with node tests.
- `tests/`: the engine's offline checks; `tests/README.md` says which file covers what.
- `docs/`: start with [docs/architecture.md](docs/architecture.md). What has run live is in [docs/status.md](docs/status.md).
  Decisions are in `docs/decisions.md`: append only, never renumber.

## Check your work

```bash
python3 tools/isolated_run.py -- python3 tests/selftest.py               # engine
python3 tools/isolated_run.py -- sh -c 'cd companion && xcrun swift test'  # app logic
node --test browser-extension/test/*.test.mjs                            # extension
```

`tools/isolated_run.py` gives the command a throwaway home folder and strips keys. Browser tests run headless only.

## Rules

- Work only inside your assigned checkout or git worktree. Never read or write `~/.benji`, `~/.benji.env`,
  any key file, or anything else in the home folder. Your brief may name more private paths; treat them the same.
- No API keys on command lines, in logs or in commits. No live model or paid API calls unless the brief says so.
- Never request or use Screen Recording, Accessibility, Microphone, Calendar or Automation permissions.
- Don't loosen the approval gate (`benji/gate.py`, `benji/tools/approval.py`) without a test that shows what is still asked.
- Don't copy code, prompts, regexes, assets, colours or copy from other assistants' products.
- Only show UI states backed by real events. Say exactly what is live-verified, unit-tested, built or untested.
- Don't commit, push, merge, force-push or delete branches unless the brief says so.
- Swift: use `xcrun swift` / `xcrun swiftc`, not a `swiftc` found first on `PATH`.
- Report: what changed, check results as counts, and what is not verified.
