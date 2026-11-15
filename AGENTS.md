# Benji: rules for every coding agent

- Code: `benji/` (Python engine), `companion/` (SwiftPM macOS app), `browser-extension/`.
  What has run live is in the status table, `docs/status.md`. Decisions: `docs/decisions.md` (append-only; never renumber).
- Work only inside your assigned checkout or git worktree. Never read or write `~/.benji`, `~/.benji.env`,
  any key file, or anything else in the home folder. Your brief may name more private paths; treat them the same.
- No API keys on command lines, in logs or in commits. No live model or paid API calls unless the brief says so.
- Tests run through `python3 tools/isolated_run.py -- <command>`, which fakes the home folder and strips keys.
  Browser tests run headless only.
- Never request or use Screen Recording, Accessibility, Microphone, Calendar or Automation permissions.
- Don't copy code, prompts, regexes, assets, colours or copy from other assistants' products.
- Only show UI states backed by real events. Say exactly what is live-verified, unit-tested, built or untested.
- Don't commit, push, merge, force-push or delete branches unless the brief says so.
- Swift: use `xcrun swift` / `xcrun swiftc`, not a `swiftc` found first on `PATH`.
- Report: what changed, gate results as counts, and what is not verified.
