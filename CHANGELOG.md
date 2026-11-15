# Changelog

All notable changes to Benji (called Chilly until 2026-11-08) are recorded here. Older entries keep the name it had. The format follows [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic
Versioning](https://semver.org/) with the pre-1.0 meaning described in
[docs/RELEASING.md](docs/RELEASING.md).

Each headline feature carries the status table's honesty label: **stable** (used by the maintainer on one Mac
over weeks), **experimental** (unit-tested, run live once and briefly) or **not live-tested**
(unit-tested against fakes only).

## [Unreleased]

### Changed
- **With no key set, Benji now says where one goes**: `~/.benji.env`, copied from `.benji.env.example`, or your shell. The
  example file no longer suggests a key file in the current folder, which Benji never reads.
- **Chilly is now Benji.** The app is `Benji.app`, the bundle id `com.emerssive.heybenji.app`, the engine `python3 -m benji`, the data
  folder `~/.benji`, the key file `~/.benji.env` and the settings `BENJI_*`. Your data moves on first launch with one atomic
  rename, from `~/.chilly` (or `~/chilly`, or `~/pal`), and your settings come across. `~/.chilly.env` is renamed to `~/.benji.env`. `CHILLY_*` and `PAL_*` variables and
  any older key file left in place keep working. macOS gives a new bundle id no permissions, so Benji asks for them again.
  Listening is unchanged, and there is still no always-on wake word. "Hey Chilly" is no longer a phrase it answers to.
  Not live-tested. See [docs/benji-rename.md](docs/benji-rename.md).
- **The local signing certificate is now `Benji Local Signing`.** `build.sh` looks for that name first. A Mac that only has
  the older `Chilly Local Signing` keeps using it, so its permissions stay granted.
- **One hidden folder, `~/.chilly`.** Everything Chilly writes (jobs, logs, answers, policy, schedules, memory,
  conversations, the on-device voice, and the export tool's default output in `exports/`) is kept in one hidden
  folder in your home folder, as other command-line tools keep theirs, instead of loose folders. The first time Chilly
  starts, an existing `~/chilly` is moved to `~/.chilly` with one atomic rename (never copied over or merged; if
  both exist, `~/.chilly` is used and one line says the old one is no longer used). `CHILLY_WORKDIR` stays the
  single switch and means the same in the app and the engine; the key file `~/.chilly.env` and the browser
  link's private folder stay where they were. Settings has a "Show Chilly's folder" button and a job's details a
  "Show in Finder". Not live-tested.

### Added
- App offers (not live-tested, off by default): when you open Reminders, Music, Things, Obsidian or a GitHub page,
  a small notch card can suggest the matching skill; "Try it" only fills the message box. Turn it on in Settings →
  "Offer help in apps". New skills for those five apps, unit-tested only.
- Browser reach, steps 2 and 3 (not live-tested): a job can click, type, press keys, scroll and upload in your
  browser on a site you separately allowed it to act on, each step classed in code from the page's element
  (uploads and anything that sends, pays, posts or deletes always ask; password and card fields are refused);
  "summarise this page" reads the tab in front after a card; Brave, Edge, Arc and Chrome Beta are in the browser
  table, each its own opt-in; a job's tabs close when it ends; Settings can mark exact sites "always allow
  reading". The extension is now version 0.2.0 and needs the `debugger` permission approved again.

### Added

- **Jobs, second pass.** A job can repeat on a schedule you approve on a card (only while Chilly is open; a repeat
  run only reads, "nothing new" is decided in code and is silent, three failures pause it, one Settings switch turns
  all off). A long job re-reads its brief and, at its step limit, reports what is done and what is left; Continue
  picks it up again. A "No" is remembered for 30 minutes. A job starts with the brief built from your conversation,
  and the row shows it. A reworded answer style ("keep answers short from now on") is kept in Memory when you ask.
  A safety-filter stop from a model service is told plainly. *Not live-tested.*
- **Worked 3D-figure examples.** A short build recipe and one hand-built example from the nearest family
  (vehicle, building, wheels, mechanism, everyday object) join a turn only when you ask to draw something.
  *Experimental.*
- **A private note for the conversation** (`keep_note`): the model can keep the state of a game with a
  hidden answer between turns, in a note you never see and that clears with the conversation. *Experimental.*

- **A quiet check before anything Chilly does unasked** (its own cues, the notch opening for a job): held
  while a meeting window is open, a call app is using the microphone, or the camera is on during a call.
  Recording and music apps never count as a call. Your own key press is never held. *Not live-tested.*
- **A muted Mac gets text, not silence:** the answer shows in the panel with how to unmute and a Copy
  button. Chilly never changes the volume or the clipboard. *Not live-tested.*
- **Your API key in the macOS Keychain, on a button** (Settings › General). Nothing moves until you press it;
  afterwards Chilly never reads a key from `~/.chilly.env` and says so if the Keychain can't be read.
  *Not live-tested.*
- **Open Chilly at login** (off by default), a one-line ask when a permission is needed, a line at launch if
  macOS turned a permission off, and a relaunch that waits for the old copy to quit. *Not live-tested.*
- **`~/chilly/policy.json`** can switch tool families off (`{"disable": ["shell", "web"]}`); it cannot
  switch anything on. A per-turn limit on tool calls. Provider errors say plainly whether the key, the
  connection, a rate limit, the account or the region is the problem. *Unit-tested.*
- **Chilly's own quiet cues** for a finished, waiting or failed job, made from plain tones by
  `tools/make_cues.py`. Off by default. *Not live-tested.*

### Changed

- **Web search with a Claude model uses Anthropic's own search** (no extra key; billed per search,
  at most three a request). Searched pages still count as outside content for the approval gate.
  `CHILLY_WEB_SEARCH=local` keeps the engine's own search. *Experimental* (one live run).
- A figure that fails to parse is never read aloud, and its labels now point at the part that shows,
  not one hidden behind another. The reply limit for Anthropic models is 8,192 tokens (was 4,096), so a
  detailed figure is not cut off.
- Words held back because another app was playing sound are put in the input box instead of being
  dropped. *Not live-tested.*

## [0.1.0] - not yet released

The first public version, built from the maintainer's private history. It is **early software**: it has
been used on one Mac (Apple silicon, notched display) against Anthropic's API. There is no signed or
notarised download; you build it from source.

### Added

- **The notch app** (`Chilly.app`, SwiftPM, macOS 14+): a panel that lives in the notch, typed and spoken
  requests (hold Right ⌥), on-device transcription, spoken answers with an on-device voice, saved
  conversations, a permission setup window, settings, and pointing at things on your screen. *Stable.*
- **The engine** (`chilly`, Python standard library only): a tool-use loop with shell, files, web search
  and fetch, AppleScript, Shortcuts, skills and a small memory; `chilly --serve` for the app;
  command-line use. *Stable.*
- **The approval gate, in code**: each tool call is free, quiet, asked or denied; destructive commands,
  overwrites, sends, writes and reads outside the working folder ask; private locations are refused;
  the text of files, pages and screenshots is treated as data. Taint: once a turn has read from
  outside, anything it changes asks. *Stable at its core; the most recent refinements (a screen-only look
  no longer asks before starting a job; read-only compound shell commands) are not live-tested.*
- **Screen context and drawing**: one screenshot with the next message only, pointing with rings and
  regions, explanation cards and 3D figures. *Stable with Claude.*
- **Background jobs**: ask for something "in the background"; one job at a time, in its own folder, behind
  the same gate; approvals wait as *Needs you* without a timeout and are answered only by the row's own
  buttons; steer, stop, recall by `find_jobs` / `read_job`. *Experimental* (one short live run). A job
  does not survive quitting Chilly.
- **Browser reach, read only**: a Chrome extension (loaded unpacked) and a local link let a job open
  pages in a tab group called *Chilly*, list those tabs and read their visible text, only on sites you
  approved for that job on a card. Off until you turn on Settings › Browser. No click, type or script.
  *Not live-tested* (scripted checks in a headless Chrome with a throwaway profile only).
- **Metadata-only audit log and diagnostics**: `events.jsonl` with a closed schema that cannot hold message
  text, an `engine.log` with redaction, owner-only file modes for the logs, `chilly --diagnose` and
  Settings › General › Diagnostics › Copy. *Experimental* (one short live run).
- **Model providers**: Claude (default), OpenAI, and presets for DeepSeek, GLM (Z.ai), Kimi (Moonshot),
  Qwen (Alibaba Cloud), Ollama and LM Studio, with regions, thinking control, image-capability checks, a
  visible "where does my data go" line and `chilly --print-provider`. Claude: *stable*. All others:
  *not live-tested*; `tools/model_smoke.py` is a live check for your own key.
- Public-repository files: MIT licence, third-party notices, contributing guide, security policy, code of
  conduct, issue and pull-request templates, CI, `docs/RELEASING.md`, `docs/ROADMAP.md`, and a `demo/` kit
  for recording a real demo in a separate macOS account.

### Changed

- The shell allowlist reads compound read-only commands (`;`, `&&`, `||`, `|`, redirects to `/dev/null`)
  instead of asking for anything with an operator, and approval cards say what was found rather than
  calling everything "potentially destructive".
- Looking at the screen is tracked as a weaker taint than reading a web page, a browser tab or a file.
- The Right ⌥ key is the only talk key (a former global shortcut was removed).

### Fixed

- `cat $'\x2fetc\x2fpasswd'` (a shell quoting form) ran without asking in an earlier shell allowlist; it
  now asks.
- The engine's stderr lines held message text in six places (card wording in approval lines, exception
  messages, file paths); they now carry only tool names, reason codes and exception class names, and a
  test fails if a canary string reaches any log.
- The job row and its buttons were not connected in the app's default setup (two backend wrappers did not
  forward job calls); fixed before the first live run.

### Security

- API keys are sent only to their provider's own host; plain `http://` is refused except to your own
  computer; GLM and Kimi "coding plan" endpoints are refused.
- Log files (`events.jsonl`, `engine.log`, `answers.jsonl`, `usage.jsonl`, `voice.log`) are written
  readable by you only. Files written by earlier builds are tightened on their next write.

### Known issues and limits

- No notarised build, no installer. A self-built app signed ad hoc loses its permissions on every rebuild
  (see [Building from source](docs/building.md#build-from-source)).
- Jobs are interrupted by quitting and do not resume; one job at a time; no sound cues.
- Browser reach: Chrome only, unpacked extension, never used in a real profile; an IDN site cannot be
  granted.
- Only one Mac, one macOS version and one display setup have been tried.
- The providers' documentation was read on 2026-11-05; model ids may have changed since.

[Unreleased]: https://github.com/umarali/benji/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/umarali/benji/releases/tag/v0.1.0
