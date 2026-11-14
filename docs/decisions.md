# Decision log

Each entry records what was decided, who decided it, why, and what was turned down.
"User" means the user chose explicitly; "Claude" means Claude chose and the user
accepted it (by approving or by building on it). Entries are append-only: a reversed
decision gets a new entry that supersedes it.

Status values: **Active**, **Superseded by D-xx**, **Open** (needs a decision).

> **Public trim.** This is the maintainer's decision log with 57 of 203 entries left out because they refer to private working material. Ids are kept, not renumbered, so gaps are expected. References to files that are not part of this repository read "(not in this export)".

---
## Building pal: backend and CLI

### D-06 · Build our own assistant, spec first
- **When / who:** 2026-10-29 17:22–17:34 · User asked to build; Claude wrote `SPEC.md`; user
  said "Build M0 now".
- **Decision:** Write a spec with milestones M0–M4 before coding, then build milestone by
  milestone.
- **Why:** Keeps scope visible and lets the user steer at each milestone.
- **Status:** Active (M0–M4 complete).

### D-08 · Settle the spec's open questions with Claude's defaults
- **When / who:** 2026-10-29 17:34 · Claude proposed; user accepted ("Build M0 now")
- **Decision:** Name `pal`; one global working folder `~/pal`; model ids via `PAL_MODEL`;
  plain stdlib REPL; stateless MVP (memory came later, D-17).
- **Status:** Active.

### D-09 · Python standard library only, zero third-party dependencies
- **When / who:** 2026-10-29 M0 · Claude
- **Why:** Nothing to install, no supply-chain risk, easy to read. HTTP via `urllib`.
- **Trade-off:** We hand-write the provider adapters instead of using SDKs.
- **Status:** Active.

### D-10 · Provider-agnostic from day one, both adapters in M0
- **When / who:** 2026-10-29 M0 · Claude
- **Decision:** One neutral message format, an Anthropic and an OpenAI adapter, provider
  auto-detected from whichever key exists (Anthropic preferred if both).
- **Why:** Avoid lock-in; it's the core of the design, so it went in before it was strictly
  needed for M0.
- **Status:** Active. OpenAI path never live-tested (no key).

### D-11 · pal's default runtime model: `claude-sonnet-4-5` (and `gpt-4o`)
- **When / who:** 2026-10-29 M0 · Claude
- **Why:** A capable, cheaper-than-Opus tool-use model; verified working with the user's key.
  `gpt-4o` is a best guess and unverified.
- **Status:** Active. Worth revisiting now that newer models exist (see progress.md). **[Reconciled 2026-11-09: Superseded by D-114, then D-117 (Haiku 5.5 low).]**

### D-14 · Stay local instead of using cloud sessions
- **When / who:** 2026-10-29 22:24–22:30 · User ("Build M1 locally")
- **Why:** Cloud sessions need a git repo with a GitHub remote, and cloud credits only fund
  Claude Code's work, not pal's own API calls.
- **Status:** Active. Revisit if a GitHub remote is added. **[Reconciled 2026-11-09: overtaken. Its own condition was met (a GitHub remote exists), cloud sessions were used from 2026-10-30, and D-74 sets their scope.]**

### D-15 · Keys live in `~/.pal.env` (chmod 600), never in chat
- **When / who:** 2026-10-29 22:43 (guidance) and 23:43 (feature) · Claude, user asked for `.env`
- **Decision:** pal loads `./.pal.env` then `~/.pal.env`; real environment variables win.
  The file is gitignored. Claude never handles key values.
- **Why:** The key had been typed inline and landed in zsh history. The apps launch pal
  through a login shell, which doesn't see a terminal's exported variables.
- **Status:** Active.

### D-16 · Web search: Brave → SerpAPI → DuckDuckGo, fail loudly
- **When / who:** 2026-10-29 M2 · Claude
- **Why:** Keyless search is convenient but DuckDuckGo bot-blocks pal, so pal returns a clear
  "set BRAVE_API_KEY or SERPAPI_KEY" error instead of silently empty results.
- **Status:** Active. No search key configured yet.

### D-18 · Persistent memory as JSONL plus a prompt digest
- **When / who:** 2026-10-30 00:20 · User asked to keep extending; Claude chose memory
- **Decision:** `memory.jsonl` in the working folder; `remember`/`recall` tools; last 20 facts
  injected into the system prompt; never store secrets.
- **Why:** Human-readable and simple; makes pal feel personal across runs.
- **Status:** Active. Edit/forget not built.

### D-19 · Don't gate AppleScript's bare `set`
- **When / who:** 2026-10-30 00:31 · Claude, found while building the calendar skill
- **Why:** `set` is variable assignment in read-only scripts; gating it made every calendar
  read ask for approval.
- **Status:** Active.

### D-20 · Opt-in stdio protocols with `\x01` sentinels
- **When / who:** 2026-10-30 00:12 (approvals) and 00:37 (events) · Claude
- **Decision:** `PAL_APPROVAL_IO=1` sends approval requests on stdout and reads y/n on stdin;
  `PAL_EVENTS=1` emits JSON events. Without the flags the CLI output is byte-identical.
- **Why:** Lets GUI front-ends drive the same backend without a server, and keeps the CLI
  unchanged.
- **Status:** Active. A persistent `pal --serve` mode is proposed (D-34).

---

## Front-ends

### D-21 · Menu-bar app as a single Swift file built with `xcrun swiftc`
- **When / who:** 2026-10-29 23:50 · User ("Build menu-bar"); Claude chose the approach
- **Why:** Smallest native step; no Xcode project. `xcrun` because the `swiftc` on PATH is a
  stale 5.6.3 that can't read the macOS 26 SDK.
- **Status:** Active (legacy; kept working, not developed further).

### D-22 · Move to a notch-centered companion, in the same project
- **When / who:** 2026-10-30 00:35 · User
- **Constraints set by the user:** only real-event states, no mock conversation, explicit
  default-safe approvals, push-to-talk first, permission-aware per-turn screen context,
  testable separation of geometry/state/transport, small verified increments, preserve CLI
  and menu-bar behaviour.
- **Status:** Active (Increments 1–3 built).

### D-23 · Put the code under git: baseline on `master`, work on `companion-ui`
- **When / who:** 2026-10-30 00:37 · Claude
- **Why:** The user asked for a git diff and preserving unrelated work; there was no repo.
  A baseline commit makes the whole companion effort reviewable as one diff. No remote.
- **Status:** Active. Commit only when the user asks; never push or merge unasked.

### D-24 · SwiftPM package split into `PalCompanionCore` (pure) and `PalCompanionApp`
- **When / who:** 2026-10-30 Increment 1 · Claude
- **Why:** The brief asked for independently testable geometry, state and transport. Core
  has no AppKit, so it runs under XCTest.
- **Status:** Active (46 tests).

### D-25 · One pal process per companion message (for now)
- **When / who:** 2026-10-30 Increment 1 · Claude
- **Why:** Reuses the existing CLI unchanged and was the fastest path to a working end to end.
- **Cost:** No conversation context between messages (only persistent memory).
- **Status:** Active, known gap; superseding proposal D-34.

### D-26 · Show unstructured backend output as an error
- **When / who:** 2026-10-30 01:06 · Claude, after the "not responding" report
- **Why:** "No API key found" was being swallowed; silent failure broke the "only real
  states" rule in spirit.
- **Status:** Active.

### D-27 · Remove `@MainActor` from the model and controller
- **When / who:** 2026-10-30 Increment 1 · Claude
- **Why:** It caused actor-isolation errors with the top-level entry point. Everything already
  runs on the main thread; the backend dispatches callbacks there.
- **Status:** Active.

### D-28 · Push-to-talk on ⇧⌘Space via Carbon `RegisterEventHotKey`
- **When / who:** 2026-10-30 Increment 2 · Claude, within the user's "no Control+Option" rule
- **Why:** Carbon hotkeys report press and release and need no Input Monitoring permission.
  ⌥⌘Space is Finder search, ⌃⌘Space is Character Viewer, ⌃⌥ is VoiceOver. Configurable via
  `defaults`; a ⌃⌥ setting falls back to the default.
- **Status:** Active as a secondary shortcut. Live-verified 2026-10-30. Its hold-only gesture
  is superseded by D-41, and the primary talk key is now Right ⌥ (D-42).

### D-29 · Record with AVAudioEngine and transcribe on-device with Apple Speech
- **When / who:** 2026-10-30 Increment 2 · Claude
- **Why:** This Mac has no ffmpeg and no transcription key, so pal's existing path would fail
  every time. On-device recognition is free and keeps audio on the Mac. Cloud transcription
  stays available through `pal --transcribe` and a `defaults` switch.
- **Status:** Active. Live-verified.

### D-30 · Screen context: one screenshot, next message only, pal excluded, deleted after
- **When / who:** 2026-10-30 Increment 3 · User set the rules; Claude implemented
- **Decision:** Off by default; a disclosure names the provider; ScreenCaptureKit with a filter
  excluding pal's own process; downscale to ≤1568 px JPEG; thumbnail kept in memory; file
  deleted after the run and on launch/quit; failed capture doesn't send.
- **Why:** The user's privacy rules. 1568 px matches the model's useful image size.
- **Status:** Active. Real capture not yet seen live.

### D-31 · Add real image input to pal rather than a placeholder
- **When / who:** 2026-10-30 Increment 3 · Claude
- **Why:** The user said not to pretend vision works. pal could only send text, so we added
  `--image`, validation (`images.py`), and image blocks for both providers, then proved it
  with a synthetic image.
- **Status:** Active. Live-verified on a synthetic image.

### D-32 · Approval alert: Return = Deny, Approve by click only, 60 s timeout denies
- **When / who:** 2026-10-30 Increment 1 · Claude, from the user's default-safe rule
- **Why:** Dismissal or timeout must never approve. The app activates itself so the alert gets
  the keyboard even when the panel isn't focused.
- **Status:** Active. All three cases live-verified 2026-10-30 10:19.

### D-33 · Increments 2 and 3 in one commit
- **When / who:** 2026-10-30 01:37 · Claude, when the user said "Commit both"
- **Why:** They change the same files; splitting would have meant cutting hunks with no
  guarantee the intermediate commit builds. The message describes each separately.
- **Status:** Done (`3e6a1fc`).

### D-34 · Proposed: persistent `pal --serve` over JSON lines
- **When / who:** 2026-10-30 handoff · Claude proposal
- **Why:** Gives the companion multi-turn context and lets the listen loop emit real events
  (needed for optional continuous listening).
- **Status:** **Open**, not started. **[Reconciled 2026-11-09: Built: D-72, then the default path in D-118 step 1.]**

### D-35 · Debug-only tracing in the companion (`PAL_DEBUG=1`)
- **When / who:** 2026-10-30 session 2 · Claude
- **Decision:** Log every state transition with timestamps, approval outcomes, focus state,
  and push-to-talk press/release/permission state. Never log message text.
- **Why:** User reports during live tests were ambiguous ("Done, check"); logs made each
  result checkable and caught one mis-remembered action.
- **Status:** Active, uncommitted. **[Reconciled 2026-11-09: committed; `git status` showed no uncommitted code at `d68f1ce`.]**

### D-36 · Mic button, edit shortcuts and better voice selection
- **When / who:** 2026-10-30 10:24–10:26 · User feedback; Claude chose the fixes
- **Decision:** Mic icon becomes click-to-talk (in addition to the hotkey). The panel forwards
  ⌘V/C/X/A/Z/⇧⌘Z to the text box, because a menu-bar app has no Edit menu. TTS picks the
  best installed voice (Premium, then Enhanced); a menu item opens the voice download page.
- **Why:** User couldn't toggle the mic, couldn't paste, and found the voice robotic.
- **Status:** Active, built, not tried live, uncommitted. **[Reconciled 2026-11-09: committed; `git status` showed no uncommitted code at `d68f1ce`.]**

### D-37 · Speech output quality: stay with Apple voices or add a cloud TTS?
- **Status:** **Open.** The fix in D-36 only helps once the user downloads a Premium voice. **[Reconciled 2026-11-09: Overtaken by D-90 (Kokoro on device).]**
  A cloud voice (e.g. OpenAI TTS, ElevenLabs) would sound better but needs a key, costs money,
  and sends text off the Mac. The user's preference is needed.

### D-38 · pal's visual identity
- **When / who:** 2026-10-30 handoff · Claude proposal from the teardown PDF
- **Proposal:** A "halo" avatar that changes per state; palette ink `#0F1716`, jade `#1FB58F`,
  marigold `#F2B035`, rose-clay `#E07A5F`, mist `#E8EFEC`.
- **Status:** **Open.** Deferred until the end-to-end path is verified (the user's rule).

### D-40 · Push-to-talk key and gesture: hold or tap, which key?
- **When / who:** 2026-10-30 ~10:33 · Asked by Claude in session 2, after the user reported
  "Something broke"
- **Options offered:** tap right ⌥ alone (Claude's recommendation; one key, but needs the
  Input Monitoring permission to see a lone modifier); keep ⇧⌘Space but tap to start/stop
  instead of hold; tap ⌥Space (may clash with the Claude app and launchers).
- **Status:** **Decided ~10:32 · User: Right ⌥ alone, tapped.** Implemented as D-41/D-42.

### D-41 · Tap to start, tap again to send (no holding)
- **When / who:** 2026-10-30 ~10:32–10:34 · User asked; Claude chose the details
- **Decision:** A quick tap (under 0.35 s) of any talk input latches listening on until the next
  tap, which sends. ⇧⌘Space still sends on release when held. The mic button behaves as a tap.
  Letting go of the key to answer a permission prompt latches rather than dropping the turn.
  A latched recording auto-sends after 5 minutes so the mic is never left on indefinitely.
- **Why:** User: holding three keys needs both hands; "once I toggle it on it should keep
  listening until I toggle it off". Supersedes D-28's hold-only gesture and its "short taps are
  accidental, discard them" rule.
- **Alternatives:** keep hold-only; stop automatically on silence (needs end-of-speech
  detection; part of D-43); no time limit (rejected: an unattended open mic).
- **Status:** Active. Built and unit-tested, not yet tried live.

### D-42 · Detect Right ⌥ with a listen-only event tap (Input Monitoring)
- **When / who:** 2026-10-30 10:34 · Claude, implementing D-40
- **Decision:** A `CGEventTap` in listen-only mode reads modifier changes and key-down timing;
  a pure `ModifierTapDetector` (in `PalCompanionCore`, unit-tested) counts only a clean tap of
  Right ⌥ alone, so chords like ⌥E never trigger. It asks for Input Monitoring once and
  re-checks every 2 s, starting as soon as permission is granted. `defaults write
  com.pal.companion talkKey off` disables it.
- **Why:** Carbon hotkeys can't register a lone modifier. Right and left ⌥ are told apart by
  device-dependent flag bits.
- **Alternatives:** `NSEvent` global monitor (needs Accessibility, a broader permission);
  Carbon (impossible for a lone modifier).
- **Status:** Active. Built; waiting on Input Monitoring permission to test live. **[Reconciled 2026-11-09: Permission choice superseded by D-51.]**

### D-43 · Proposed: conversation mode (keep listening across turns)
- **When / who:** 2026-10-30 ~10:33 · User expectation; Claude proposal
- **Proposal:** After pal answers, listen again automatically until the user switches it off,
  like other voice agents.
- **Why not now:** Each companion message is a fresh pal process, so a spoken follow-up would
  lose context. Needs the persistent `pal --serve` (D-34) and end-of-speech detection first.
- **Status:** **Open**, to be offered after this round is verified. **[Reconciled 2026-11-09: Closed by D-93; "no barge-in" later superseded by D-115.]**

---

## Direction and privacy

### D-45 · Stay on Claude for now; no open-weight models yet
- **When / who:** 2026-10-30 ~13:00 · User
- **Decision:** Keep Claude as pal's model. Don't move to open-weight models yet, and don't
  run them on this Mac.
- **Why:** The user isn't comfortable with open models' current limits (multi-step tool use,
  screen reading), and this Mac isn't set up to host them well.
- **Alternatives:** run open models locally now (rejected: hardware and capability); hosted
  open models now (possible through D-46, not chosen).
- **Status:** Active. Revisit when hardware or models change.

### D-46 · Keep the model swappable: any OpenAI-compatible server via `PAL_BASE_URL`
- **When / who:** 2026-10-30 ~13:00 · User asked for flexibility; Claude chose the design
- **Decision:** `PAL_BASE_URL` points pal's OpenAI-format provider at any compatible server
  (OpenRouter, Together, Groq, a rented GPU box, or Ollama / llama.cpp / LM Studio / MLX).
  Setting it implies the OpenAI format and requires `PAL_MODEL`. Its key comes only from
  `PAL_API_KEY`, which may be empty for local servers. `OPENAI_API_KEY` is never sent to another
  host. Plain `http://` is refused except to localhost, private addresses, `.local` and
  `.ts.net`. `--print-provider` reports a `destination`, and the companion's screen disclosure
  names it.
- **Why:** Switching models becomes a config change rather than code work, while the default
  stays on Claude (D-45). The key and http rules stop a config mistake from leaking a key or
  your data.
- **Alternatives:** a separate "local" provider class (the same wire format, so no need); also
  supporting Anthropic-compatible endpoints (not needed yet).
- **Status:** Built, unit-tested and documented in README. Never used against a real
  open-model server.

### D-47 · Open: where to draw the privacy line
- **When / who:** 2026-10-30 ~12:55 · Claude proposal; user has not chosen
- **Options:** strictly local (nothing ever leaves); local by default, with a frontier model
  only when approved per request and the outgoing data shown (Claude's recommendation); or by
  type of data (screen, files and memory never leave, generic questions can).
- **Why it matters:** It decides how requests get routed, and it should be a visible system
  rule, not a habit. It only becomes real once a private model exists (D-45).
- **Status:** **Open.**

### D-48 · The companion's name: Chilly ("Hey Chilly")
- **When / who:** 2026-10-30 ~15:25 · User
- **Decision:** The product is called **Chilly**, invoked as **Hey Chilly**. It replaces the
  placeholder `pal` (D-07) and the app name PalCompanion. The story: "chilly" moved from *cold*
  to *calm* ("chill out", 1979); Chilly keeps its cool, sorts the problem out, gives you your
  space back, and never watches you when you haven't asked.
- **Why:** The user wanted a catchy name that relates to the global public. Claude's
  shortlists (Wren/Perch/Kestrel/Mynah; Mira/Ami/Ayo/Amiko) were rejected; the user ran their
  own naming work (`~/Downloads/Naming the companion_ the story.pdf`).
- **Alternatives:** Chili (chosen briefly, superseded: CHILI marks in classes 9/42, Chili
  Piper's AI agent, slang meaning in some Spanish dialects), Lowkey (no-go), Gif, Spiffy,
  Nifty, Witty (parked), Glixie, Suha, Stippy.
- **Preliminary screen (user's PDF, not legal clearance):** no live CHILLY or HEY CHILLY mark
  in USPTO classes 9 or 42; no AI assistant called Chilly found; heychilly.ai, heychilly.io and
  meetchilly.com available; heychilly.com taken (expires Oct 30, 2026). Nothing registered.
- **Next:** design system from the brand handoff brief (`chilly-brand-handoff.md`, not on this
  Mac yet); renaming the code (`pal`, `PalCompanion`, `com.pal.companion`) is a separate step.
- **Status:** Active.

### D-50 · Cap screenshots at 1.15 megapixels
- **When / who:** 2026-10-30 ~15:55 · Claude, from a live check
- **Decision:** Downscale screen captures to fit both a 1568 px long edge and 1.15 MP.
- **Why:** Anthropic shrinks larger images before the model sees them, and pointing
  coordinates then come back in the shrunken image's pixels: a 2400×1600 test was ~15% off;
  at 1200×800 the answer was (899,600) for a true (900,600). Also cuts image tokens.
- **Status:** Active.

### D-53 · Sign builds with a local certificate so permissions survive rebuilds
- **When / who:** 2026-10-30 ~19:30 · User chose "Local certificate" over their Apple
  Development certificate
- **Decision:** A self-signed, code-signing-only certificate "Chilly Local Signing" (RSA 2048,
  10 years, SHA-1 `4B8A7B65…1743`) lives in the login keychain, with `codesign` allowed to use
  its key. `companion/build.sh` signs with it (override: `PAL_SIGN_IDENTITY`; falls back to
  ad-hoc if missing). It isn't marked trusted; that isn't needed for signing.
- **Why:** Ad-hoc signatures change every build, and macOS ties each privacy grant to the
  signature, so every rebuild silently voided Accessibility, Screen Recording, Microphone and
  Speech grants (the root of the Input Monitoring and Accessibility "switched on but not
  working" reports). The app's designated requirement is now `identifier "com.pal.companion"
  and certificate leaf = H"4b8a7b65…"`, the same for every build.
- **Trade-off:** Only meaningful on this Mac; distributing to others would need a Developer ID
  certificate and notarization.
- **Status:** Active. Verified ~19:50: after a rebuild, Accessibility was still granted
  (talk key ready at launch).

### D-54 · Chilly lives on the notch, revealed by hover
- **When / who:** 2026-10-30 ~20:00 · User
- **Decision:** Replace the always-visible pill *under* the notch with an object *on* the
  notch: closed (invisible, notch-shaped black), peek (cursor reaches the notch, or a real
  event such as an answer or approval while closed), open (full panel), growing out of the
  notch with a spring animation; crossfade under reduce motion. The talk key, ⇧⌘Space and the
  ✦ menu also reveal it, so it never depends on the mouse.
- **Why:** User: "it shouldn't sit under the notch but on the notch, like when you take the
  cursor up there, it should appear with animation." Fits "tiny presence, big payload" and
  Chilly's calm, out-of-the-way character.
- **Details:** measured notch 185 × 32 pt at x 663–848 on the 1512 × 982 built-in display;
  displays without a notch get the same object at the top centre. Spec in
  `(not in this export)` §3a.
- **Status:** Active as direction. Look and motion come from the design system; code not
  started (the app still shows the pill).

### D-55 · Native-first design system for Chilly
- **When / who:** 2026-10-30 ~20:10 · User ("syncs with the Mac ecosystem perfectly … colors,
  animation, everything"; "improve the brief first"); Claude chose the specifics
- **Decision:** Chilly uses Apple's system values: system colours (light/dark, Increase
  Contrast, the user's accent), SF Pro and SF Pro Rounded, SF Symbols, system materials and
  Liquid Glass on macOS 26, SwiftUI's standard springs. Identity lives in the name and voice,
  the notch behaviour, one tint (`chilly-mint` = systemMint) and the app icon/wordmark. Privacy
  colours match macOS (orange mic, purple screen). Home is the notch (D-54); no cursor
  companion, no face. Brief v2 (`(not in this export)`) supersedes the draft's three
  custom palettes, Google fonts and cursor-trailing mascot.
- **Built:** Design System artifact https://claude.ai/artifact/EqHWGJM2jH8kkwQEP4u5Zi (private;
  source copy in `docs/design-system/project/`): tokens (22 colours with contrast notes, 11
  type styles, spacing, radii, notch sizes, shadows), brand book README, 9 components with
  guidelines and live previews, 3 proposal logos, a cover.
- **Contrast:** every pair on the black notch passes AA (5.96–14.88:1); Apple's light-mode
  mint/orange (~2.1:1) and secondary label (3.84:1) are kept exact and flagged in their notes.
- **Status:** Active. Logos and icon are proposals; not yet applied to the app's code.

### D-57 · Approval for sensitive capabilities, not just destructive ones
- **When / who:** 2026-10-30 ~21:20 · User ("Fix the gap"); Claude chose the rules
- **Problem:** pal runs as the companion's child and most likely uses its Screen Recording and
  Accessibility grants, but the gate only asked about destructive commands. A screenshot,
  System Events typing/clicking, or an upload ran without asking.
- **Decision:** `run_shell` also asks before: taking screenshots or recording screen, camera or
  mic (`screencapture`, `-f avfoundation`, `imagesnap`); `osascript`; `shortcuts run`; sending
  data over the network (`curl` with -F/-T/-d/--data*/POST-style methods, `wget --post`, scp,
  sftp, rsync, ssh, ftp, nc, telnet); `open`; `pbpaste`. `run_applescript` also asks before UI
  scripting (keystroke, key code, click, perform action, anything via System Events),
  `do JavaScript`, and reading the clipboard. Each prompt names the capability and shows the
  command or script, so the companion's dialog says exactly what is being allowed.
- **Verified:** 26 new self-test checks (13 must-ask, 6 must-not-nag, reasons, AppleScript);
  live: the model's `screencapture` attempt was stopped and nothing was written.
- **Limits:** pattern matching, not a sandbox. An obfuscated command (encoded, or built at
  runtime) could slip past, and `web_fetch` can still put data in a URL. The real fix is to stop
  pal inheriting the app's grants (separate identity or a sandbox) — under investigation.
- **Status:** Active. Committed as `3c9b637`.

## Brand and design system (session 3)

### D-58 · Chilly is final; the call phrase is "Hey Chilly"
- **When / who:** 2026-10-30 ~23:40 PKT · User (answering the design session's questions)
- **Decision:** The name **Chilly** (D-48) is final. The call phrase shown everywhere is
  **"Hey Chilly"**; "Okay Chilly" stays a documented fallback for a future wake word only.
- **Why:** The user kept the recommended option; the talk key remains the main way in (brief
  v2 §13), so the wake-phrase collision risk doesn't block the name.
- **Alternatives:** lead with "Okay Chilly"; reopen the name.
- **Status:** Active. Code rename (pal → Chilly) still out of scope.

### D-59 · App icon direction: Pebble v2
- **When / who:** 2026-10-30 ~23:40 PKT · User
- **Decision:** Finish **Pebble v2** (a single calm mint pebble with a darker underside on a
  black rounded square) into the final macOS 26 layered icon set and menu-bar glyph.
- **Why:** User's pick from the eight options (Claude had recommended Notch + Pebble).
- **Alternatives:** Notch + Pebble (recommended), the c lettermark, Pebble, Calm ripple, Notch,
  Two lines, Breeze.
- **Status:** Active; final artwork in progress (`docs/design-work/icon/`). **[Reconciled 2026-11-09: Superseded by D-137.]**

### D-60 · The open panel is all black, one object
- **When / who:** 2026-10-30 ~23:40 PKT · User
- **Decision:** The open panel stays **solid black and continuous with the notch** (like the
  Dynamic Island). Liquid Glass is used only for controls inside it. Closes brief v2 §16 item 5.
- **Why:** Reads as hardware, keeps the one-object story, and gives the highest contrast.
- **Alternatives:** black top with a Liquid Glass panel below the notch line.
- **Status:** Active.

### D-61 · Silent by default; calm motion with one bounce on Done
- **When / who:** 2026-10-30 ~23:40 PKT · User
- **Decision:** Chilly makes **no sounds by default**; a small set of quiet cues exists as an
  option. Motion is **calm and system-like**, with exactly **one gentle bounce, on Done**, and
  no other overshoot or playfulness.
- **Why:** Matches "never fusses, never hovers"; the single bounce gives a small, earned moment
  of character at the end of a task.
- **Alternatives:** quiet cues on by default; purely calm with no bounce; a little playful
  (softer overshoot on peek too).
- **Status:** Active. Specified in the Motion and Sound sections of the design system.

### D-63 · Peek height 60 pt instead of 40 (proposal)
- **When / who:** 2026-10-30 ~23:45 PKT · Claude, **needs the user's OK**
- **Decision:** `notch-peek-height` 40 → 60 pt: the wings sit at notch height (32 pt) beside
  the hardware notch, then a 28 pt row holds the one `peek-line`.
- **Why:** The peek promises a line below the notch, but the hardware notch is 32 pt deep and
  can't show anything, so 40 pt left an 8 pt strip. The wings beside the notch are only 87.5 pt
  wide each, too narrow for a line.
- **Alternatives:** keep 40 pt and drop the line from the peek (glyph and word only); a wider
  peek with the line squeezed into the right wing.
- **Status:** Accepted (D-67, user delegated the call, 2026-10-31).

### D-64 · Final menu-bar glyph: the pebble's outline
- **When / who:** 2026-10-30 ~23:45 PKT · Claude (icon workstream B), from rendered comparisons
- **Decision:** The menu-bar item is the Pebble v2 outline as a 1.5 pt ring in an 18 × 18 pt
  template image. The solid pebble is kept as an alternate.
- **Why:** The ring matches the weight of 13 pt menu-bar text; the solid pebble was the heaviest
  item in the bar and read as a recording or status dot.
- **Alternatives:** the solid pebble; a pebble with an underside groove (smeared at 1x).
- **Status:** Active; the user hasn't seen it yet. **[Reconciled 2026-11-09: Superseded by D-137.]**

### D-67 · Design-session open questions answered (user delegated)
- **When / who:** 2026-10-31 ~00:05 PKT · Claude, on the user's instruction "go for the most
  befitting answers and mark them; we'll see if we need any changes later"
- **Decision:**
  1. **Peek height 60 pt** — D-63 accepted.
  2. **Publish** the staged integration to the Design System artifact.
  3. **VoiceOver:** while VoiceOver runs, Listening on/off cues play by default (until the user
     sets the toggle); other events stay announced, not cued.
  4. **"Hey Chilly"** always plays Listening on, even with cues off; Listening off follows the
     setting. The wake phrase itself stays off by default.
  5. **Overlay targets:** add `[BOX:x1,y1,x2,y2:label]` and ordered multi-target answers to the
     backend; build order is the ring first, then the region and steps in the same rework.
  6. **Open panel covering the target** collapses to peek when the mark appears (as specified).
  7. **Escape** dismisses marks by observing the key only; the front app still receives it.
- **Why:** (1) the line needs its own row; (3) a cue confirms the mic without speech landing in
  the recording; (4) a microphone opened by voice must be heard to open, and silence-by-default
  still holds because the wake phrase is off by default; (5) the ring covers today's point
  protocol, the region needs a box the backend doesn't send yet; (6) the model saw the screen
  without Chilly's panel, so the user must too; (7) Chilly never swallows other apps' keys.
- **Alternatives:** keep 40 pt; publish later; cues off for everyone; ring only, no box tag;
  leave the panel open; consume Escape.
- **Status:** Active; open to change after the user reviews.

### D-69 · PalCompanionCore stays Foundation-only, and is tested on Linux too
- **When / who:** 2026-10-31 ~00:15 PKT · Claude (cloud session); the brief asked for it
- **Decision:** Core imports only Foundation (the three `import CoreGraphics` lines were
  dropped: on macOS Foundation already brings `CGFloat`/`CGRect`, and on Linux it provides
  them). In a cloud container, Core's tests run through a scratch package that declares only
  `PalCompanionCore` and its tests (the app target needs AppKit). Swift 5.10.1 came from
  Ubuntu's `swiftlang` .deb plus `libicu76`, unpacked into `/tmp` (swift.org is blocked by the
  container's network policy).
- **Why:** Core logic can then be built and tested in cloud sessions, not only written blind.
- **Alternatives:** write Swift uncompiled in the cloud; a Linux-only test target in
  `Package.swift` (would change the package the Mac builds).
- **Status:** Active. 90/90 tests on Linux; the Mac run (Swift 6.2.1, macOS SDK) is still to do.

### D-70 · Notch geometry and motion constants live in Core
- **When / who:** 2026-10-31 ~00:20 PKT · Claude (cloud session), from Motion.md
- **Decision:** `PanelGeometry.notchShape(_:notch:screenFrame:)` returns closed / peek / open
  as one `NotchShape` (frame, bottom and shoulder radii, opacity, shadow opacity). Closed is the
  **reported hardware notch rect**, not a 185 pt constant (notches differ by model); peek and
  open are centred on it, flush with the top of the display, never narrower than the notch or
  wider than the display. Without a notch, closed is 185 × 32 at the top centre with opacity 0.
  The hover hot zone is the closed rect grown 8 pt on every side, including above the top edge,
  so a pointer pinned to the top still counts. `MotionTokens` and `MotionTiming` hold Motion.md's
  numbers as plain constants; `SpringToken` derives stiffness, damping and settle time. The
  settle factor is the exact 1.1825 × d (Motion.md's "1.18" lands at 99.49%, not 99.5%). The
  existing `layout(screen:idleSize:expandedSize:)` the app uses is unchanged.
- **Why:** Geometry and timing get unit tests before the Mac work on the notch object starts;
  the app then only draws.
- **Alternatives:** keep the numbers in the SwiftUI views; a 185 pt closed size everywhere.
- **Status:** Active. Unit-tested on Linux; not used by the app yet.

### D-71 · pal logs its own token usage locally
- **When / who:** 2026-10-31 ~00:22 PKT · Claude (cloud session), for open issue 8
- **Decision:** Each model call appends one line of counts (time, provider, model, input,
  output, cache read, cache write) to `<workdir>/usage.jsonl`, next to `memory.jsonl`. The
  numbers come from the usage block of the response pal already receives: no extra calls. On by
  default; `PAL_USAGE_LOG=0` turns it off. No prompts, answers or file contents are stored, and
  no costs are computed (prices change; the Anthropic Console is the source of truth). The CLI
  prints a per-task line to stderr (not in `PAL_EVENTS` mode, where the app reads that stream);
  `pal --usage` summarises the log per model without a key.
- **Why:** The user pays per token and pal had no record of it.
- **Alternatives:** compute dollar costs (a price table to maintain); log only on request; send
  usage as an event to the app (later, with `--serve`).
- **Status:** Active. Unit-tested offline; not yet run against the live API.

### D-72 · Proposed design for `pal --serve`
- **When / who:** 2026-10-31 ~00:26 PKT · Claude proposal; Python part approved by the user
  ~00:28 (D-74)
- **Proposal:** `docs/proposal-serve.md`: one long-lived pal per app launch speaking
  versioned JSON lines over stdio (requests: hello, send, approve, cancel, restore, reset,
  shutdown; events: ready, tool, approval, answer with parsed pointing targets, usage, error,
  done). A turn works on a copy of the conversation and commits only when it ends, so a cancel
  never leaves a half turn behind. Context is bounded (10 exchanges, old screenshots dropped).
  One-shot mode stays; the app switches behind a setting.
- **Why:** Fuller context, no start-up cost per message, and the base for conversation mode
  (D-43). Refines D-34.
- **Alternatives:** richer `--history`; a local socket server; reuse the sentinel protocol.
- **Status:** Increment 1 (Python) built 2026-10-31 ~00:31, unit-tested offline; the app
  doesn't use it yet. Increment 2 (Swift protocol types) deferred to the Mac (D-74).

### D-73 · `(not in this export)` is the one place for status
- **When / who:** 2026-10-31 ~00:25 PKT · Claude (cloud session), refreshing stale docs (open
  issue 6)
- **Decision:** `README.md`, `SPEC.md` and `(not in this export)` describe the product and the code, and
  point to `(not in this export)` for what is verified and what comes next instead of keeping their
  own lists. HANDOFF's §10 (verification) and §11 (next work) became pointers; SPEC keeps the
  original v0.1 text with a status line and a "Since the spec" section.
- **Why:** Three copies of the status went stale within a day; one copy is updated every session.
- **Alternatives:** keep refreshing all four.
- **Status:** Active.

### D-74 · Cloud sessions do Python and docs; Swift waits for the Mac
- **When / who:** 2026-10-31 ~00:28 PKT · User, after asking why Swift was written in the cloud
- **Decision:** "Just finish what you started, and then you can focus on the Python part." The
  Swift already written (Core pointing, notch geometry, motion constants) stays as is; new Swift,
  including `pal --serve`'s protocol types (increment 2 of D-72), is written on the Mac.
  Cloud sessions work on pal (Python) and the docs. Taken as the go-ahead to build `--serve`'s
  Python side now.
- **Why:** Only the Mac can build the app, run the Mac toolchain and show the UI; Swift written
  elsewhere waits unused and unverified on the platform that matters.
- **Alternatives:** keep writing Core in the cloud and testing it on Linux (D-69).
- **Status:** Active.

### D-75 · Tool processes run in their own group, with stdin closed
- **When / who:** 2026-10-31 ~00:50 PKT · Claude (cloud session), closing the `--serve` cancel gap
- **Decision:** Every process a tool starts (`run_shell`, `search_files`, `osascript`,
  `shortcuts`) goes through one helper that starts it in a new process group
  (`start_new_session`), with stdin from `/dev/null`, and records it on the tool context. A
  timeout or Ctrl-C kills the whole group; `Ctx.kill_running()` does so on demand and refuses new
  tools, and `pal --serve` calls it when a turn is cancelled.
- **Why:** Killing only the shell left its children running, and `subprocess.run` then waited on
  their pipes, so a slow child could hang a tool past its timeout (a latent bug, now covered by a
  test that fails with the old behaviour). Tool commands also inherited pal's stdin, which
  carries the approval replies (`PAL_APPROVAL_IO`) or the `--serve` protocol; a command that read
  stdin could have swallowed them.
- **Alternatives:** kill only the direct child; a per-tool cancel flag without killing.
- **Status:** Active. Unit-tested on Linux. To check on the Mac: that AppleScript automation
  prompts and grants still work with `osascript` in its own session.

### D-76 · Merge the cloud design branch with the cloud versions winning; Core imports CoreGraphics where it exists
- **When / who:** 2026-10-31 ~01:45–02:05 PKT · User ("merge that very carefully"; chose
  "Merge, cloud wins", kept the outline glyph, "commit them first"); Claude did the merge
- **Decision:** `claude/nice-clarke-v8uau6` merged into `companion-ui` (`e61441c`). Where the
  local session's finished icon set and motion drafts (`26f80a1`, made in parallel by local
  subagents) collided with the cloud's, the **cloud versions win**: they are what's published
  (artifact version 7) and what Core's `MotionTokens.swift` follows. The local icon set is kept
  in `(not in this export)` for its real `actool` compile and its Dock
  check beside Apple icons; the local motion drafts stay in history only. The user confirmed the
  published **outline** menu-bar glyph (D-64) over the local filled-with-groove one.
- **Fix found by verifying:** the cloud had removed `import CoreGraphics` for Linux (D-69), which
  broke Core on macOS (`CGRect` has no `width`/`height`/`midX`… without the overlay). Core now
  uses `#if canImport(CoreGraphics) import CoreGraphics #endif` (`fd71ca7`): 90/90 on the Mac,
  full package build including the app.
- **Alternatives:** keep the local icon set (stronger checks, filled glyph); drop the local set
  entirely; hold the merge.
- **Status:** Active. The artifact was checked against the merged local copy (all 31 text files
  match in size, index identical); nothing republished.

### D-77 · Keep nice-clarke's `pal --serve`; hand-port brave-dijkstra's safety pieces (proposal)
- **When / who:** 2026-10-31 ~02:00 PKT · Claude, from a read-only comparison of both branches;
  **needs the user's OK**
- **Proposal:** Two cloud sessions built `pal --serve` independently: `claude/nice-clarke-v8uau6`
  (D-72, now on `companion-ui`) and `claude/brave-dijkstra-qlul13` (PR open; it numbered itself
  "D-58", which is the name decision on the main line). Keep nice-clarke's as the base (process-
  group kill on cancel, turns on a copy so a cancel leaves no trace, usage and parsed pointing
  targets, tighter context). Don't merge brave's branch (whole-file conflicts); hand-port its fd
  0/1 isolation, try/except around handlers, SIGTERM/SIGINT handling, `approval_result` event,
  a pal-side approval timeout longer than the app's, and its extra tests; then close its PR.
- **Verified in the comparison:** nice-clarke's selftest 167 ok; an `approve` with a non-string
  `request` raises TypeError and ends nice-clarke's server. Brave's selftest stops on Python
  3.14 (`stdin.close()` then `communicate()`, a test bug); with that line changed, 172 ok.
- **Alternatives:** switch to brave's serve and port nice-clarke's pieces; merge both (no).
- **Status:** **Active, built 2026-10-31 ~02:40 PKT** on the user's go-ahead ("Yes, do it
  here"). In `pal/serve.py` and `pal/__main__.py`: `approve`/`cancel` fields validated (the
  crash fixed); a catch-all around request handlers (`internal`); `make_agent` inside the turn's
  try; `approval_result {approved, why}` after every approval; only the string yes approves;
  pal's approval timeout 90 s (announced in `ready`) as a backstop to the app's 60 s, and an
  answer racing the timeout is used or refused, never dropped; a committed turn can't be
  cancelled; `isolate_stdio` (protocol on private fd copies, fd 1 → stderr, fd 0 →
  /dev/null); SIGTERM/SIGINT/EOF cancel the turn and exit 0; a gone front-end stops the emitter;
  JSON `startup` errors. 17 new selftest checks (184 total), including brave's real-process
  checks against a localhost fake model and a SIGTERM check that the running tool dies; the new
  checks fail against the old `serve.py` (the crash reproduces); 10 runs in a row pass. Not
  ported: brave's `ping`, `spoken` rule and `[unfinished]` notes. Brave's branch is closed
  unmerged.

### D-78 · Rename the notch app to Chilly (`com.chilly.app`); the engine keeps the code name pal
- **When / who:** 2026-10-31 ~03:00 PKT · user ("Full rename now"; "I edit, you sign"), Claude
  for the scope
- **What:** `PalCompanion.app` → `Chilly.app`, bundle id `com.pal.companion` → `com.chilly.app`,
  SwiftPM package `Chilly` with targets `ChillyCore`, `ChillyApp`, `ChillyCoreTests`; executable
  `Chilly`; every user-visible "pal" in the app says Chilly ("Chilly's backend (pal)" where the
  Python process is meant). The Python package, the CLI, `PAL_*` variables, `~/pal` and
  `~/.pal.env` keep the name pal: they are the engine, and renaming them would break every
  existing setup for no user-visible gain. Type names that describe the pal process
  (`PalBackend`, `PalBackendEvent`) stay. The legacy `(not in this export)` is untouched.
- **Settings:** copied once from `com.pal.companion` by an allowlist of user settings (`talkKey`,
  `pttKeyCode`, `pttModifiers`, `pttTranscriber`, `ttsVoice`, `backendMode`). Not the
  permission bookkeeping (`screenRecordingConfirmed`, `talkKeyAskedAccessibility`): macOS
  grants per bundle id, so the new app has none of the old grants. (On this Mac the old domain
  held only those two flags.)
- **Signing:** the user signs. `build.sh` takes `CHILLY_SIGN_IDENTITY` (or the older
  `PAL_SIGN_IDENTITY`), defaults to the self-signed "Chilly Local Signing" certificate already in
  the login keychain, and now stops if `codesign` fails instead of shipping an unsigned bundle.
  The user chose their Apple Development identity; either is stable across rebuilds, but
  switching between them resets the grants.
- **Alternatives:** visible name only, keeping the old bundle id (no new permission prompts, but
  the old id forever); rename the Python side too; defer.
- **Status:** Built and unit-tested; `Chilly.app` assembles. Not launched: the user builds,
  signs, opens it and grants permissions (`(not in this export)`).

### D-79 · The app's side of `pal --serve` (increments 2–3), behind a setting
- **When / who:** 2026-10-31 ~03:10 PKT · Claude, per the proposal (D-72) and progress step 4
- **What:** Core `ServeProtocol.swift` (requests, events, the approval-timeout rule); in the app
  a `CompanionBackend` protocol with `PalBackend` (one-shot, still the default) and
  `ServeBackend` (`defaults write com.chilly.app backendMode serve`). Details in the proposal's
  "As built (increments 2–3)". The app's approval alert uses
  `ServeProtocol.approvalTimeout(palTimeout:)`: 60 s, and always at least 5 s below what pal
  announces in `ready` (90 s today).
- **Why behind a setting:** the one-shot path is the one seen live; serve becomes the default
  after the user's live round (proposal step 4).
- **Alternatives:** switch outright; put the protocol in the app target (untestable headlessly).
- **Status:** Built. 11 Core tests; `companion/ServeCheck/run.py` drives the app's own backend
  files against a real `pal --serve` with a localhost fake model (15 checks). The
  protocol-mismatch fallback and the running app are not checked.

### D-80 · Overlay rework, first pass: ordered ring/region marks, estimated reveal times
- **When / who:** 2026-10-31 ~03:20 PKT · Claude, from Overlay.md (D-66, D-67) and progress step 8
- **What:** Up to three targets per answer (from `[POINT]`/`[BOX]` or serve's `targets`), one
  mark at a time in order. Ring or region per `PointMapping.mark` (D-68), drawn with the
  Anatomy's layers (keylines, 3 pt/2 pt mint, halo; heavier under Increase Contrast). Reveal:
  stroke draws with `motion-content` (ring) or `motion-open` (region), label fades in at 0.353 d,
  **one** halo pulse after the stroke settles, nothing loops (PointerOverlay's endless pulse is
  gone); Reduce Motion fades everything in over 0.2 s. Each target appears at the **estimated**
  time its label's first word is spoken (4.5 syllables/s, comma 1, sentence end 2; at least
  1.2 s apart); the last stays 8 s after it settles. Labels: below, above, trailing, leading
  in that order, inside the visible frame inset 12 pt, clear of the mark and of Chilly's panel.
  One click-through, never-key window over the captured display, found again by its frame (no
  mark if the display changed); `sharingType = .none`.
- **Left for later:** timing from the synthesizer's word callbacks, the glide between nearby
  targets, the HUD material band, Escape/click/scroll/window-move erase, collapsing the panel
  when it covers the target, the peek's Pointing state.
- **Status:** Built. Layout and timing: 13 Core tests. The marks were rendered offscreen
  (`ImageRenderer`) over the synthetic test screen and looked at. Not seen on a real display,
  not with VoiceOver, not with speech.

### D-81 · Privacy rules for live runs: ask each time; no direct access for Claude
- **When / who:** 2026-10-31 ~03:07 PKT · user (relayed by the parent session)
- **What:** Ask before every live API call and say exactly what leaves the Mac; synthetic
  images unless the user agrees to a real screen for that run; calendar or other personal data
  only with a specific yes; keys never on command lines, in output or in git; logs and personal
  output stay out of `docs/` and commits; Claude changes no privacy settings, TCC grants or
  signing, and doesn't widen pal's reach without asking. And: no direct access for Claude for
  the rest of the work (no computer use, Chrome, simulator or screen reading; no permission
  prompts triggered for Claude's own processes). Live GUI, voice, pointing and AppleScript
  checks are steps the user runs and reports back.
- **Status:** Active. Before it arrived, Claude had made one pointing call (synthetic image),
  one calendar call (access refused, nothing read) and one direct `osascript` to Calendar
  (refused, -1743); all reported to the user. `~/pal/usage.jsonl` was checked: token counts,
  model and time only.

### D-82 · The assistant is Chilly, and knows where it is answering (`PAL_SURFACE`)
- **When / who:** 2026-10-31 ~03:35 PKT · user ("Yes, send them"), Claude for the mechanism
- **What:** The system prompt now opens "You are Chilly…" everywhere. A surface decides the
  rest: `terminal` (the CLI, the default: "running in a terminal… (the `pal` command line)")
  or `panel` ("answering in Chilly's panel… under the Mac's notch; when the user spoke… read
  aloud", plus a short rule to keep to inline Markdown and number steps on their own lines).
  The app sets `PAL_SURFACE=panel` in the environment of every pal it starts, one-shot and
  `--serve`; any other value, or none, is the terminal.
- **Why an environment variable:** it reaches both entry points without new flags (`--serve`
  refuses task-shaped flags), matches `PAL_EVENTS`/`PAL_APPROVAL_IO`, and a user's own
  terminal never sets it.
- **Alternatives:** a `--surface` flag; a field in serve's `hello` (one-shot has no hello);
  calling it Chilly only in the panel.
- **Status:** Built. 8 selftest checks, including real processes against a localhost fake model
  that report which prompt they received (one-shot without and with the variable, and
  `--serve`). Not seen with the real model.

### D-83 · Render inline Markdown in the panel (not plain-text-only answers)
- **When / who:** 2026-10-31 ~03:37 PKT · Claude (the user asked for one of the two, with a reason)
- **What:** Assistant lines in the transcript go through `PanelMarkdown.attributed` (Core):
  `AttributedString(markdown:)` with `inlineOnlyPreservingWhitespace`, so **bold**, *italic*,
  `code` and line breaks render and block syntax stays as typed. Link and image attributes are
  removed (their text stays), so nothing in an answer is clickable: answers can repeat text
  from web pages and files. VoiceOver gets the plain text. Speech is unchanged
  (`SpeechText.plain` in the app, `voice.py` in the CLI).
- **Why rendering rather than asking for plain text:** models write Markdown out of habit even
  when told not to, so a prompt alone would still leak `**` now and then; rendering fixes what
  slips through, and the panel prompt (D-82) keeps the model to the inline subset rendering can
  show. Bold for a key word and `code` for a path also read better than plain text.
- **Alternatives:** plain text only, by prompt; full Markdown with block rendering (lists,
  headings) in a small panel.
- **Status:** Built. 5 Core tests (inline styles, line breaks, links/images not clickable,
  unbalanced markup, plain text). Not seen in the running app.

### D-84 · The engine and CLI are `chilly` too; the name pal is gone
- **When / who:** 2026-10-31 ~03:50 PKT · the user ("Don't give me that pal shit again. Change it
  already"), carried out by Claude.
- **What:** D-78 renamed only the app. Now everything else follows:
  - the Python package `pal/` → `chilly/` (`python3 -m chilly`, `chilly.sh`);
  - `PAL_*` variables → `CHILLY_*`, and the stdout sentinels → `CHILLY-APPROVE`/`CHILLY-EVENT`;
  - `.pal.env` → `.chilly.env`;
  - the working folder `~/pal` → `~/chilly`;
  - the temp files → `chilly-*`;
  - the wake word default → `chilly`;
  - the REPL prompt and log prefix → `chilly›` and `[Chilly]`;
  - the Swift types `PalBackend`/`PalEvent` → `OneShotBackend`/`EngineEvent`/`BackendEvent`;
  - the transcriber setting `.pal` → `.engine`;
  - `(not in this export)` → `docs/proposal-serve.md`;
  - living docs (README, HANDOFF, SPEC, (not in this export), progress, skills) say Chilly.

  The history logs (decisions, timeline, findings, usage) keep what they said at the time. The legacy `(not in this export)` app only got its command and variables updated.
- **Compatibility:**
  - An old `.pal.env` and `PAL_*` variables are still read and copied to `CHILLY_*` when those are unset.
  - `~/pal` is moved to `~/chilly` on first run, only when `~/chilly` doesn't exist and no workdir is set.
  - The setting values `pal` and `PAL_SIGN_IDENTITY` still work.
  - On this Mac, `~/.pal.env` was renamed to `~/.chilly.env` without being opened (mode 600 kept) and `~/pal` moved to `~/chilly`. `chilly --print-provider` finds the key (no API call).
- **Why:** the user wants one name everywhere; the split code name kept showing up in answers, logs and docs.
- **Alternatives:** keep pal as an internal code name (D-78's choice, overruled).
- **Status:** Built. selftest 196 checks (4 new: old `.pal.env`/`PAL_*`, folder move, explicit
  workdir untouched, both folders present); `swift test` 120/120; ServeCheck 15/15.
  The installed `Chilly.app` still runs `python3 -m pal`, so it **fails until rebuilt**.

### D-87 · The notch object replaces the panel; sizes come only from real signals
- **When / who:** 2026-10-31 ~04:30 PKT · Claude (chilly-panel session), implementing D-60/D-62/D-63/D-70
- **Decision:** The app draws Chilly as the notch object: one `NotchOutline` shape in a window flush with the top of the display, level `mainMenu + 3`.
  - The size is `NotchPresence.targetSize`: open only on request; peek for ongoing events, the Done hold, an unseen error, or a hover rest; closed otherwise.
  - Morphs follow `NotchMorphPlan` (Core, unit-tested).
  - Listening no longer opens the panel; it shows in the peek.
  - Approval decisions stay in the NSAlert for now, raised to `mainMenu + 4` (superseded by D-88).
- **Why:** D-60 (all black, one object) and the Motion spec. Keeping the decisions in Core keeps them testable without a display.
- **Alternatives:** keep the window below the menu bar (it would break continuity with the notch); an in-panel approval card now (needs live keyboard-focus testing).
- **Status:** Built and unit-tested; renders checked; not yet tried live.
- **Merged:** 2026-10-31 ~04:30 PKT into `companion-ui` (branch `chilly-panel`; full notes in `(not in this export)`).

### D-88 · Approvals are answered in the notch, not in an alert
- **When / who:** 2026-10-31 ~04:25 PKT · Claude (chilly-approval session)
- **Decision:** An approval grows the notch to open (`NotchPresence`) and the non-activating panel takes the keyboard with `makeKey`, without activating the app. The ApprovalCard offers No / Adjust / Yes. Return, Escape, any non-⌘ Return and the timeout mean No; only ⌘Return or a click means Yes. Adjust says No, ends the turn and pre-fills the composer. The model owns the timeout, which always ends before the engine's. The `NSAlert` is removed.
- **Why:** Design system (ApprovalCard, principle 5, Motion.md). The decision stays on the one object, and the user's app keeps focus.
- **Alternatives:** keep the NSAlert (it steals focus and is off-brand); use SwiftUI `.keyboardShortcut` on the buttons (conflicts with the composer's Return-to-send, and would make a button the default).
- **Status:** Built, unit-tested and rendered offscreen; not yet tried live.
- **Merged:** 2026-10-31 ~04:30 PKT into `companion-ui` (branch `chilly-approval`; full notes in `(not in this export)`).

### D-89 · The screen leaves the Mac only after a Yes at send time; emoji are never spoken
- **When / who:** 2026-10-31 ~05:00 PKT · the user ("Fix both"), after Chilly sent their screen
  to Anthropic when they had asked it to "capture a screenshot".
- **What:**
  - With the screen button on, sending a message (typed or spoken) no longer captures anything.
    The panel opens a card instead: "Send a picture of this screen to Anthropic with your
    message?", with three buttons: Cancel, Send without screen and Send screen. Only a click on
    Send screen captures and sends. The card has no default button and no key shortcut. If it
    gets no answer within 60 s, the message is cancelled and nothing is sent.
  - The button's tooltip names the provider. The disclosure strip says Chilly asks first.
  - A plain "take a screenshot" request goes through `screencapture -x` into `output/`. That
    stays approval-gated, and the system prompt now says the file stays on the Mac and is never
    seen or sent.
  - Spoken text drops emoji in both places: `SpeechText.withoutEmoji` in the app and `to_plain`
    in the CLI. The panel prompt also tells the model not to use emoji, since replies may be read
    aloud.
- **Why:** the user expected "screenshot" to mean a local file. The armed toggle plus an
  easy-to-miss strip wasn't consent at the moment data left the Mac. Separately, macOS speech
  reads emoji by name.
- **Alternatives:**
  - Confirm when the button is switched on rather than at send time. This was rejected because
    the decision is too far from the moment the screen is sent.
  - Detect "screenshot" in the text. This was rejected as fragile.
  - Remove screen context. This was rejected because it's needed for "where is …?".
- **Status:** Built. `swift test` 161/161; selftest 198 (emoji, prompt rules); Core tests for
  the confirm text and timeout. Not yet tried live.

### D-91 · Overlay rework, second pass: speech-timed reveal, glide, variants, erase triggers
- **When / who:** 2026-10-31 ~04:00–04:20 PKT · Claude (side session chilly-overlay), from Overlay.md (D-66, D-67) and D-80's "left for later"
- **What:**
  - **Speech-timed reveal.** For spoken answers, each target is revealed when the synthesizer's `willSpeakRangeOfSpeechString` reaches its anchor word. The anchor is the label's first word, skipping a leading "the/a/an"; offsets are UTF-16 into `SpeechText.plain(text)`. The estimate stays as a late fallback (estimate × 1.5 + 1 s). If speech hasn't started 2 s after the answer, pacing falls back to text. Text-only answers reveal the first target when the answer arrives, the rest at their estimated gaps. Steps stay at least 1.2 s apart.
  - **Lifetime.** A mark stays 8 s after it comes to rest, and at least 3 s after speech ends, capped at 60 s. All of this lives in the Core state machine `PointingSequence`.
  - **Glide.** Between rings ≤ 220 pt apart the ring glides with `motion-follow`. The old label fades out at once; the new one fades in at 65% of the hop; one pulse on arrival. Otherwise the old mark fades out (`motion-fade`) while the new one draws.
  - **Frames as functions of time.** Every frame is a pure function of time (`MarkTimeline`): stroke and keylines draw together clockwise from 12 o'clock (region: from the top centre), the halo fades in, the label appears at 0.353 d, and there is one pulse after the stroke settles. The live view redraws (`TimelineView(.animation)`) only until everything is at rest; then nothing is scheduled.
  - **Reduce Motion.** Fade in over `motion-reduce` with no draw, pulse or glide. Steps crossfade with `motion-reduce`.
  - **Increase Contrast.** The mint stroke grows 1 pt inward (ring 4 pt, region 3 pt), with flush 1.5 pt opaque black keylines. The label is opaque `notch-raised` with a 1 pt `notch-label-secondary` border.
  - **Reduce Transparency.** No halo, no material and so no pulse. Keylines are 2 pt opaque `notch-raised`, and the label is opaque.
  - **Increase Contrast and Reduce Transparency together.** 2 pt black keylines.
  - **Differentiate Without Color.** No change, and a test checks that.
  - **Live updates.** The settings update live via `accessibilityDisplayOptionsDidChangeNotification`.
  - **HUD material.** `NSVisualEffectView` (`.hudWindow`, dark, behind-window) masked to the halo band, plus the label capsule with a `notch-hairline` edge.
  - **Label placement.** Below or above may now sit up to 24 pt further from the mark (never closer) to reach the safe area, so menu-bar and Dock targets get a label (Overlay.md says they should). The hardware notch (from `auxiliaryTopLeft/RightArea`) is kept clear along with Chilly's panel. Both are read at each reveal, not when the answer arrives.
  - **Erase triggers** while a mark is up or pending:
    - Escape, observed only (global monitor plus a local one for Chilly's own panel).
    - ⇧⌘3/4/5.
    - A click inside the target plus its outset.
    - A scroll over the target's window (the whole display if there's no window).
    - A 4 Hz poll for the target window moving, resizing, closing or being newly covered (see below), and for `IsSecureEventInputEnabled()`.
    - A Space change; an app switch to an app other than the target's or Chilly.
    - A display change, sleep, screen lock, session resign, or the Screenshot app launching.
    - The talk key (both kinds).
  - **Window tracking.** The window list is taken right after the capture (`CGWindowListCopyWindowInfo`, bounds only). The target's window is the topmost one under it. Windows already in front of the target at capture time don't count as covering it later; they were see-through or out of the way for the model.
  - **Coordinates and displays.** The capture carries its `CGDirectDisplayID`. The overlay finds the display again by ID and frame; if the display is gone or changed, there is no mark. The capture no longer falls back to "the first display" when the ID doesn't match, which could have mapped marks onto the wrong screen. Marks are snapped to the backing pixel grid.
  - **VoiceOver.** `announcementRequested` at medium priority (was high): "Pointing at Share." / "Step 2 of 3: Include photos." / "Pointing at something on screen."
  - **Panel collapse.** When a revealed mark's keep-out intersects the visible panel, `model.setExpanded(false)` is called (D-67 #6).
  - **One plan for both backends.** `PointingPlan` builds the marks and reveal cues in Core. One-shot tags parsed in the app and serve's pre-parsed `targets` give identical plans (tested with three targets: ring, region, ring).
- **Why:** this closes the D-80 gaps and Overlay.md's Reveal, Variants, Lifetime, Coordinates and Accessibility rules. Pure Core models (`PointingSequence`, `MarkTimeline`, `MarkLayers`, `WindowTracking`) keep the timing and geometry unit-tested without AppKit.
- **Alternatives:**
  - Keep the estimated timers only.
  - SwiftUI implicit animations (D-80): these can't be rendered at exact times offscreen and can't be paused at rest.
  - Core Animation layers per mark: more code, and still no offscreen renders.
  - Ignore the window list and erase on any scroll or click.
- **Status:** Built.
  - **Unit-tested:** 145 Swift tests (25 new, in `OverlayMotionTests`); `selftest.py` passes; app assembled ad-hoc.
  - **Rendered offscreen:** 16 moments over a synthetic screen, all looked at.
  - **Not verified:** a real display, VoiceOver, real speech callbacks, the HUD material, the global monitors, the window poll, and `sharingType = .none` against ScreenCaptureKit recorders.
- **Merged:** 2026-10-31 ~05:45 PKT into `companion-ui` (branch `chilly-overlay`). One conflict (VoiceController properties) kept both. With Kokoro there are no word callbacks, so marks fall back to text pacing; sentence-level progress from Kokoro is a follow-up.

### D-93 · Hands-free conversation: listen again after each answer, end on pause, phrase, quiet or Escape
- **When / who:** 2026-10-31 ~05:20–06:10 PKT · Claude (side session chilly-handsfree), from the
  user's ask ("I don't need to be tapping on that option key over and over"). Closes D-43.
- **What:**
  - **Starting.** A tap of the talk key or the mic starts a conversation; so does a new
    Conversation control. A hold is still one push-to-talk message.
  - **Sending.** End of speech is detected on-device from the recogniser's partials plus the mic
    level against an adaptive noise floor. The pause is 1.0 s, with +1.2 s after a word that
    promises more, at most 3.5 s, and is a setting.
  - **Turn-taking.** The mic opens only when Chilly is idle, isn't speaking or about to speak,
    and no approval or screen card waits. No barge-in.
  - **Ending.** A stop phrase (whole utterance, or after a request with a pause mark; matched on
    the Mac), 60 s quiet (a setting), Escape, lock, sleep, closing the panel, Cancel, or the
    control.
  - **Noise.** Noise-only transcripts are dropped silently.
  - **Recognition.** Requests restart mid-utterance so speech after an early final or a
    "no speech" error isn't lost.
- **Why:** this removes the key press between turns, the user's main complaint. Keeping it to
  on-device recognition and text-only output keeps D-90's and the user's privacy rules. Pausing
  for cards keeps D-88: voice never approves anything.
- **Alternatives:**
  - **Barge-in with `AVAudioEngine` voice processing.** Rejected for now: Kokoro plays through a
    separate engine, so echo cancellation would need one shared engine and live proof with
    speakers. That is a follow-up.
  - **A wake word.** Rejected: it means always listening.
  - **A fixed silence with no continuation cues.** Rejected: it cuts people off mid-thought.
  - **Ending on any "thanks".** Rejected: "thanks, now open Mail" is common.
  - **Making the tap toggle a separate mode key.** Rejected: one more thing to learn.
- **Status:** built and unit-tested (245 Swift tests, 50 new; selftest and ServeCheck pass;
  `build.sh` assembles). Not tried live.
- **Merged:** 2026-10-31 ~06:15 PKT into `companion-ui` (branch `chilly-handsfree`; notes in `(not in this export)`).

### D-94 · The model is told when a turn was spoken and where the notch is, and drawing is a capability it uses
- **When:** 2026-10-31 ~06:30–06:55 PKT.
- **What:**
  - A per-turn `spoken` flag (`--spoken`, `"spoken"`).
  - A per-screenshot `screen` geometry (`--screen`, `"screen"`; ChillyCore
    `ScreenshotGeometry`): size, display, menu bar, and the notch in image pixels.
  - Both are added to that turn's system prompt.
  - The drawing section is rewritten to draw without asking or naming tags.
  - A brevity rule for the panel.
- **Who:** the user asked for it after the live failures; implemented in this branch.
- **Why:** the model was never told it could hear, never knew the notch's position (the notch
  never appears in a capture), and the old wording made marks optional and cautious.
- **Alternatives:**
  - Put the spoken flag in the user message text: it would leak into history and the transcript.
  - Draw the notch into the screenshot: that changes what's sent and lies about the image.
  - Let the app add notch marks itself: that only covers the notch, not "draw a smiley".
- **Status:** done on `chilly-behaviour`; live eval 96% (above).
- **Merged:** 2026-10-31 ~07:00 PKT into `companion-ui` (branch `chilly-behaviour`; notes in `(not in this export)`).

### D-95 · A calm panel that listens while it's open

- **When / who:** 2026-10-31 ~06:20–07:10 PKT · Claude (side session chilly-panel-polish),
  from the user's first full live test.
- **What:**
  - The open panel's band holds only the mic glyph (the mic control in the open panel), the
    state word, "…" and collapse.
  - Screen is one small capsule menu beside the composer; its explanation is in the tooltip,
    the VoiceOver hint and the menu.
  - The transcript is the conversation only:
    - tool steps and listening notes go to one status line;
    - a screen picture is a mark on its message, with the thumbnail on click.
  - The status word swaps out-then-in, never cross-faded.
  - **Listening is on while the panel is open:**
    - started by opening, with no key, only when mic and speech are already allowed and on-device;
    - ended by closing, a stop phrase, Escape, lock or sleep, or 5 minutes quiet
      (1/5/15/30 in the menu);
    - held off after any stop until the panel reopens or the user starts it.
  - Cancel stops the task, not the mic.
  - A menu setting turns it off.
  - Supersedes D-93's 60 s quiet default and its Conversation button.
- **Why:** the user found the band cluttered, the Screen control wordy, the transcript noisy, and
  having to start the conversation by key, then losing it after 60 s of reading, "pathetic". The
  privacy rules hold:
  - on-device speech;
  - the orange mic and macOS's indicator whenever the mic is open;
  - no permission prompts from opening;
  - voice never answers cards (D-88);
  - no barge-in.
- **Alternatives:**
  - **Keep the Conversation button and add auto-start.** Rejected: two controls for one idea.
  - **Always listen, even when closed (a wake word).** Rejected: the mic would be open with
    nothing visible.
  - **Restart listening by itself after lock or a stop phrase.** Rejected: the mic must never
    come back on without the user.
  - **An eye icon for Screen.** Rejected: the design system forbids eyes; `viewfinder` is
    already Screen's glyph.
  - **Cross-fade the status word in a ZStack with a fixed width.** Rejected: it still draws two
    words mid-fade.
- **Status:** built and unit-tested (294 tests, 25 new). Rendered before and after. Not tried live.
- **Merged:** 2026-10-31 ~07:00 PKT into `companion-ui` (branch `chilly-panel-polish`; notes in `(not in this export)`).

### D-96 · "Show Drawings in Screenshots" (off by default); hint lines swap without a cross-fade; misheard words map to the screen
- **When / who:** 2026-10-31 ~07:30 PKT · the user ("Yes, do both"), after a live test where a
  highlight couldn't be shown in their screenshot.
- **What:**
  - **New menu item: "Show Drawings in Screenshots"**, off by default (`showDrawingsInScreenshots`).
    - When on, the overlay's `sharingType` is `.readOnly`, so screenshots and recordings can
      include Chilly's drawings, and the screenshot shortcuts no longer clear them.
    - When off, the old behaviour stays: the overlay is hidden from captures, and the
      shortcuts clear the marks.
    - Chilly's own captures, the ones sent to the model, leave its windows out either way.
  - **No more overlapping text.** The open panel's status line and the peek line swap their
    text at once, with no cross-fade. A cross-fade drew "Go on." over the longer conversation
    line, the same fault as "Doneking".
  - **Misheard words.** Spoken turns tell the model that speech recognition mishears words: if
    the named word isn't on screen but a similar-sounding one is, act on that one.
- **Why:**
  - Drawings hidden from captures meant the user couldn't show what Chilly drew.
  - "cutter" was heard for "clutter", and the model said it couldn't find it.
- **Alternatives:**
  - Always show drawings in captures. Rejected: they'd land in recordings by default.
  - Fade the hint lines out, then in, as the status word does. More motion for a secondary line.
- **Status:** Built. `swift test` 302/302 (2 new), selftest, ServeCheck.
  - The prompt change was not run against the live model.
  - Whether `.readOnly` reaches ScreenCaptureKit-based tools hasn't been checked.

### D-97 · Chilly draws pictures from parts: LINE, SHAPE, OVAL, GROUP, CALLOUT; corners kept; a picture stays up
- **When / who:** 2026-10-31 ~10:20–10:45 PKT · proposed by the chilly-drawing-v2 session after the user's live "draw an airplane" test; merged into `companion-ui` at 10:45 (`b1581f7`).
- **What:** PATH takes 2–40 points and is cut at turns over 60° (centripetal Catmull-Rom between corners); new LINE, SHAPE (closed) and OVAL as a picture's parts, GROUP (dashed region) and CALLOUT (label pill with a pen pointer) for pointing. A reply with picture parts keeps up to 20 tags (still at most 3 POINT/BOX). A picture is drawn part after part (0.25 s floor, 0.06 s pen lift) and stays up 120 s, through the next turn, until replaced, dismissed or erased by the overlay's own triggers; marks on things keep the 8 s timing. The prompt teaches composing a picture from shapes and forbids promising a drawing without tags; without a screenshot Chilly may talk about what it drew.
- **Why:** the live airplane was a loopy scribble (PATH limited to 8 points, Catmull-Rom through sharp corners), the marks were gone before the user looked, and "not even close" got a promise with no drawing.
- **Alternatives:** only raising PATH's point limit (still loops at corners); a bitmap or SVG drawing tool (heavier, not Chilly's pen); keeping marks a fixed 8 s.
- **Status:** merged; unit-tested (318 Swift tests at merge, 342 on the merged head) and render-checked offscreen with hand-written tags. **Not live-verified**; no model call made. The screen rule grew from 4,220 to 6,658 characters. Full notes: `(not in this export)`. See D-103 for what the review found it still lacks.

### D-99 · Turn tokens: a cancelled run can't come back, and approvals are bound to their request
- **When / who:** 2026-10-31 ~10:45–10:50 PKT · proposed by the chilly-interaction session from the user's interaction brief; merged into `companion-ui` at ~12:05 (`ff593d5`).
- **What:** `RunToken` numbers every engine run; backends tag each event and finish with it and the model admits only the live run, so a cancelled run's late answer, error, approval or finish can't revive it or end the next turn. One-shot gets a line reader and history file per run. Cancel updates the panel at once and deletes the sent screenshot; a transcript or partial arriving after Cancel never starts a turn. Approval answers carry the card's request id; a second pending request is refused (`approve{no}` in serve), never swapped in.
- **Why:** `ServeBackend.cancel()` kept forwarding a committed answer; `OneShotBackend` let a cancelled process's lines land in the next turn and deleted the next run's history file; a stale card's click went to whichever request was pending.
- **Alternatives:** carrying the engine's request id up to the model (deferred: one pending request per run today).
- **Status:** merged. New `ChillyAppTests` target drives the real `CompanionModel` through a fake backend; the new tests were shown to fail (15 assertions) with the run gate removed. Not seen live.

### D-100 · Retry never repeats a side effect
- **When / who:** as D-99.
- **What:** a cut-off turn whose activity line already says it ran a command, saved a file, ran an automation or Shortcut, remembered something, or had an approval allowed gets no Retry; its footer says "Cut off after it had started changing things. Check what was done before asking again." A turn that only looked can still be retried (D-98).
- **Why:** an engine run isn't idempotent and the activity line is the only record of what ran. **Limit:** the engine drops a cancelled turn's events, so a command finishing in the instant before Cancel may not report, and that turn still offers Retry.
- **Status:** merged; 4 tests. Not seen live.

### D-102 · The approval card says up front that no answer means No
- **When / who:** 2026-10-31 ~10:55 PKT · proposed by the chilly-interaction session; merged at ~12:05.
- **What:** "No answer in 60 s means No." in the secondary colour beside No / Adjust / Yes, read by VoiceOver with the request (`ApprovalPolicy.expiryLine`). Timeouts unchanged: 60 s in the app, 90 s engine backstop. No ticking countdown.
- **Why:** the timeout was only announced after the fact.
- **Status:** merged; offscreen render; not seen live. (D-103 was numbered D-102 until 11:50.)

### D-104 · The engine can stream replies and cache the Anthropic prompt prefix; both opt-in until proved live
- **When / who:** 2026-10-31 ~11:50–12:45 PKT · proposed by the chilly-stream session (D-103.1); the user: "Merge both, stream off" (~12:50); merged at ~13:00 (`0bbca47`).
- **What:** `stream()` beside the unchanged `complete()` in both providers (Anthropic SSE; OpenAI-compatible chunks with usage), the same return shape; `--serve` emits `delta` events before the unchanged `answer` (older apps ignore them; `delta_reset` takes back text written before a tool call; tags never stream); cancel, SIGTERM and stdin EOF close the stream at once; usage records gain cache reads and writes; `cache_control` on the tool prefix and system prompt. **Both are off unless `CHILLY_STREAM=1` and `CHILLY_PROMPT_CACHE=1`**; off, every call is the blocking request from before and no delta is sent (a self-test check proves the default).
- **Why:** first ink and first words waited for the whole reply; the screen prompt was resent uncached every turn. Measured with the fake model pacing 0.6 s to first token and 75 tokens/s: first delta at 619 ms against the answer at 8,608 ms; Chilly's own overhead 1 ms to first delta.
- **Why off:** nothing has run against the real API; a wrong `cache_control` shape or a stream quirk would break every call. The gate to flip the defaults is one live call with each switch on, run by the user.
- **Alternatives:** streaming on by default with the off switch (rejected under the credibility rule); only caching (would not touch latency).
- **Status:** merged, opt-in. Selftest (10 runs on the branch, 3 on the merged head), ServeCheck, Swift tests unchanged. The panel does not show deltas yet (a later Swift session, after D-99's run tokens).

### D-105 · Parametric 2D picture parts and a shorter screen rule (built, held)
- **When / who:** 2026-10-31 ~11:50–12:30 PKT · built by the chilly-parts session (D-103.2) on `chilly-parts` (`afe178d`): ELLIPSE, RECT, POLYGON, SEGMENT, ARC, MIRROR beside the existing tags, the screen rule cut from 6,658 to 4,804 characters, renders byte-identical for existing tags, all gates green.
- **Status:** **held unmerged** by the parent after D-107: pictures of things are to be 3D figures, so 2D parts are the wrong road for them. The prompt cut is still wanted; it can be taken on its own later.

### D-106 · The overlay reads the window list once per plan and polls off the main thread; spoken pictures end with their sentence
- **When / who:** 2026-10-31 ~11:50–12:35 PKT · proposed by the chilly-overlay-perf session (D-103.4, .5); merged at ~13:00 (`909ec10`) on the user's "Merge both".
- **What:** `WindowTracking.PlanWatch` built once per plan from the capture's window list (one watch per distinct target window); `WindowPoller` runs the 4 Hz poll on a background queue and delivers only a detected change to the main thread, guarded by a generation counter; the secure-input check stays on the main thread. A spoken picture is paced to end with the sentence that names it, between 0.5× and 1.4× its pen time, no part under 0.25 s; when speech ends or the next turn starts, the remaining parts come at the fastest pace in order. Every erase rule, the 120 s hold and `hide()`/`dismiss()` are unchanged; text-only answers keep today's timing to the frame (42 renders byte-identical).
- **Why:** measured: the old path blocked the main thread 54–170 ms per 12-part picture's reveal (worst call 38 ms) plus 480 reads over the hold; now 0.3–1.9 ms with no call over 1.1 ms. A picture after a 2 s sentence finished 5.1 s late; now 2.0 s late at the limits, on time when the sentence is long enough.
- **Status:** merged; unit-tested (15 new tests). Not seen live.

---

## Going to market

### D-108 · The figure grammar and the SceneKit tier-1 renderer (merged, off by default)
- **What:** pictures of things are a fenced `figure` JSON block (title, parts of nine kinds with placement, materials, labels, view, cut), parsed identically in `chilly/figures.py` and `ChillyCore/FigureGrammar.swift` against shared cases, built into renderer-agnostic meshes in ChillyCore, and shown by a SceneKit stage on Chilly's black card (PBR by material name, shadow, rim, SSAO, outline, cut plane, labels that follow, framing that follows the slow turn). Behind the `figureStage` setting and `CHILLY_FIGURES=1`, which the app sets for the engine when the setting is on. The block is lenient inside (bad parts dropped) and strict at the top (bad JSON, non-finite numbers, no parts: left in the text); vertex budgets fixed per recipe so both parsers agree without building meshes.
- **Who:** proposed by the chilly-figures session (Opus 5.5, high); the user asked for it ("Yes, start it", 13:00) and for the merge after the live round (15:55 "Do both"); merged by the parent.
- **Why:** D-107. Proved by offscreen renders, then six real-model rounds (~$2.50 in all): from 1 of 3 to 22 of 33 figures reading clearly by eye, 7 of 8 on things the prompt never mentions. The user's live round at 15:46 asked for "a 3-D model" of a plane and got circles and lines.
- **Alternatives:** model-written code (D-107 rejected it); SceneKit primitives instead of own meshes; an `SCNTechnique` edge pass; RealityKit. Details in `(not in this export)` §7.
- **Status:** **merged** as `2d74eb5` (figures tip `4507e55`); 423 Swift tests, selftest, ServeCheck green on the merged head. Off by default; a menu switch is being added (chilly-live-fixes). Not yet seen in the running app. Left on the figures worktree, uncommitted: a joints fix for parts that do not touch.

### D-115 · Talking over Chilly interrupts it: Off / Headphones (default) / Always (supersedes D-43's "no barge-in")
- **What:** Settings › Voice › "Talk over Chilly to interrupt". Off: as before, it finishes and Right ⌥ stops it. Headphones (default): with sound in the ears (AirPods and other headphones count), speaking stops Chilly and what was said starts the next message. Always: speakers too, through one echo-cancelling `AVAudioEngine` shared by the voice and the mic. An echo guard ignores heard words that match Chilly's own answer; two words of the user's own, or "stop", "wait", "no" or Chilly's name, interrupt. While it listens over its answer the glyph turns orange.
- **Who:** the user, to the chilly-live-fixes session ("why doesn't it stop when I talk over it", then "Yes, merge and rebuild", ~17:05); built there (Opus 5.5, high); merged by the parent.
- **Why:** D-43 closed the mic while Chilly speaks so it never hears itself on speakers; the user found the result unresponsive. The headphone default keeps D-43's safety where echo is possible.
- **Alternatives:** always on with echo cancelling (kept behind "Always" until tried on this Mac); keep D-43.
- **Status:** **merged** as `b859a8a` (`28b71d7`); 461 Swift tests; not tried live (how fast it notices, whether its own voice ever stops it on speakers, whether echo cancelling starts cleanly).

### D-117 · Default model is `claude-haiku-5-5` at low effort; `claude-sonnet-5-5` low is the named secondary; caching stays on (supersedes D-114)
- **What:** `DEFAULT_MODELS["claude"]` becomes `claude-haiku-5-5`; the engine sends `output_config.effort` from `CHILLY_EFFORT`, default `low`, only to models that accept it; `CHILLY_MODEL=claude-sonnet-5-5` is the documented better-figures option, and the app's Settings › General gets a Model choice (Haiku 5.5 default / Sonnet 5.5) that sets `CHILLY_MODEL` for the engine. Prompt caching (D-111) stays on for every model.
- **Who:** the user (~17:30): "I'd like to stick with Haiku 5.5 low. Just keep Sonnet 5.5 low as a secondary option. Use cache as much as possible to minimise the cost." Built by chilly-effort (engine) and chilly-live-fixes (settings page), both Opus 5.5 high.
- **Why:** list prices per million: Haiku 5.5 $0.10 in / $0.50 out (cache read $0.01), Sonnet 5.5 $2 / $10 (read $0.20); the 17:02 round of 8 calls cost $0.147 on Sonnet 5.5 and would have cost $0.007 on Haiku 5.5; 60% of the Sonnet cost was thinking at the default `high` effort, billed as output, which `low` removes. The figure eval at low effort on both models (running, ~$0.10) is the evidence on quality; the user chose cost first with Sonnet one switch away.
- **Alternatives:** Sonnet 5.5 low as default (better figures, 20× the price); a local open model through `CHILLY_BASE_URL` (free, private, untested, weaker); Gemini Flash (Haiku's price band, a second provider).
- **Evidence (the eval at low effort, 11 prompts each, `(not in this export)`):** Haiku 5.5 low $0.0139 for 11 figures, Sonnet 5.5 low $0.1685 (both runs $0.18, above the ~$0.10 estimate: Sonnet wrote ~1,040 output tokens a figure). By eye Haiku loses clearly on two (microscope arm apart, no crankshaft), a little on three, is even on four and better on two (house, wind turbine). Haiku writes about twice the tokens at low, so a turn averages 9.1 s against 6.8 s. Every call after the first read the 3,248-token prefix from cache on both models.
- **Status:** **merged** as `2a6e692` (engine: `b5b372d` effort, `b223524` default; the behaviour eval on Haiku 5.5 is not run) and `1cbb0b3` (app: Settings › General › Model, `021745f`). Not yet tried in the running app.

### D-119 · Where the Mac's echo cancelling won't start, Always acts like Headphones (built, merged)
- **When / who:** 2026-10-31 ~22:42–22:50 PKT · the user's live round (voice not getting through; "the sound is not from" Kokoro); Claude (Opus 5.5, high) diagnosed it from `~/chilly/voice.log`; the user: **"Build the fix"**.
- **What:** one failed start of the voice-processing engine is remembered per audio setup (output route and input device name, `EchoVerdicts` in user defaults) for a week, or until the user picks Always again; on such a setup Always acts like Headphones (`BargeInMode.effective`): on speakers the mic stays shut while Chilly speaks and opens on the plain engine, and Kokoro plays on its own output. A failed echo start resets that engine (voice processing off, graph cleared) and opens a fresh plain engine; Kokoro moves to its own output instead of handing the answer to the Apple voice. One status-line notice; the settings page says why.
- **Why:** on this Mac (built-in mic and speakers) the echo engine failed with -10875 on every start, mic and voice alike (voice.log 22:39–22:41). Each turn then fell back: the mic to a plain engine that seemed to hear silence (flat meter in the user's screenshot), the voice to Apple's. Retrying a start that never works costs every turn. The reference app caches such verdicts per audio topology too (round 6, `11-app-internals.md`); this is Chilly's own, smaller version.
- **Alternatives:** fix why voice processing won't start here (unknown cause, needs live debugging with the mic, which Claude's processes can't use); drop Always (the user chose it); a per-step probe before trusting it (later, if Always ever works on this Mac).
- **Status:** merged as `3d5a567` (`c571ccf`); 7 new tests, 524 Swift tests, selftest, ServeCheck; signed build 22:49. **Not tried live.** Supersedes nothing; narrows D-115's Always on setups where it can't work.

### D-120 · The user picks Chilly's voice from six Kokoro voices; a choice speaks from the next answer (merged)
- **When / who:** 2026-10-31 ~23:15–23:35 PKT · the user: "I would like the user to be able to pick the voice … three male voices and three female voices … without losing any previous history … It should just start using the newly selected voice. The current one is good." Built by the chilly-voice-picker session (Opus 5.5). _(Number taken on the branch; renumber at merge if a sibling branch took D-120.)_
- **What:** Settings › Voice lists six Kokoro voices, Heart (`af_heart`, default), Bella, Nicole, Michael, Fenrir, Puck, by name with a line each and a Preview; a Speed choice for `kokoroSpeed`. The voice and speed are fixed when an answer starts, so a change speaks from the next answer and an answer already playing finishes in its old voice. A preview goes through the same Kokoro service but is refused while a turn is running or while the mic is open on speakers, and any answer stops it. Without Kokoro the row keeps the Apple voice and says why.
- **Why:** the voice was already per request in the service, so switching needs no restart and touches nothing else. Six American English voices because the service phonemizes as `en-us`; among them the ones Kokoro rates best, checked by measured pitch. Locking the voice per answer avoids a voice change in the middle of a sentence stream.
- **Alternatives:** switch at the next sentence even mid-answer (a mixed-voice answer, which reads as a glitch); two voices only (the user offered both; six gives a real choice at no cost); all 54 voices (most are other languages under en-us phonemes); preview through a second service (twice the memory).
- **Status:** committed on `chilly-voice-picker`, **not merged**; 531 Swift tests, selftest; renders checked; the six preview sentences synthesized by the real service. **Not run in the app; descriptions not listened to.** Notes: `(not in this export)`. **[Reconciled 2026-11-09: in `companion-ui` (`805d08c`). Any "not seen live" wording here still stands.]**
### D-122 · Talk to Chilly like a person: guarded talk-over on speakers, one-press interrupt, history of what was heard, teaching (merged)
- **When / who:** 2026-10-31 ~23:05–23:55 PKT · the user: "I cannot interrupt while the assistant speaks… converse with me… you talk, and then they talk, and they could interrupt you. You could interrupt them. When it comes to learning, that becomes more significant." The parent session briefed a side session (Claude Opus 5.5), which designed and built this on `chilly-conversation`.
- **What:** (1) Always on speakers where echo cancelling won't start (D-119) now listens over Chilly's voice on the plain mic, **guarded**: an interrupt needs 3 words of the user's own (or "stop"/"wait"/Chilly's name…), heard while the mic level is 7.5 dB above what Chilly's own playback explains for 0.3 s in 2 s (the step learnt from Kokoro's PCM), with a 0.6 s settle after Chilly stops. Settings › Voice says it may miss a quiet interruption. (2) The talk key or mic button while Chilly speaks stops it and listens in the same press. (3) A cut-off answer is kept as only the words that had been said, marked `[cut off: …]`, in the app's memory, the panel line, and the engine (new serve request `cut_off`; a running turn stops and keeps the message). (4) A finished question is sent at 0.75 × the end silence; after Chilly asks a question the answer gets +0.8 s. (5) Prompt sections "Talking with the user" (panel) and "Teaching and quizzing" (both surfaces), in the cached base.
- **Why:** on this Mac's speakers D-119 left no way to interrupt by voice, and the press needed two taps. Without the cut-off, the model assumed the user heard a whole answer they had stopped. The gate is tuned to miss a soft interruption rather than have Chilly stop itself; measured on simulated audio: 0 false interrupts in 2,400 s, ≥ 18/20 users who speak up caught within 2.2 s, a user as loud as the echo missed 20/20 (`(not in this export)`).
- **Alternatives:** fix the voice-processing engine on this Mac (cause unknown; needs live mic debugging); a learned echo canceller of our own on the plain mic (much larger, not testable without audio); keep the mic shut on speakers and rely on the press (the user asked for voice); a backchannel while the user talks (the brief ruled it out); shorten the end silence after any sentence (the recogniser adds periods at every pause; an existing test pins "." to the full silence).
- **Also (~23:55, the user's 23:25 ask via the parent):** Settings › Voice › "Keep listening when the panel closes", on by default: closing the panel keeps a running conversation going in the notch's peek; closing never starts one; Show / Hide, the talk key, a stop phrase, the quiet spell, Escape, lock and sleep still end it. Supersedes D-95's "closing it ends one" while the switch is on.
- **Status:** committed on `chilly-conversation`, not merged; 57 new Swift tests (581/581), 12 selftest checks, 3 ServeCheck checks; no existing test changed. **Nothing tried live**; the parent merges and builds. Supersedes D-119's "Always acts like Headphones" for the mic over speech (D-119's engine choice stays); extends D-115's echo guard. **[Reconciled 2026-11-09: in `companion-ui` (`5933375`). Any "not seen live" wording here still stands.]**
### D-121 · Saved conversations, a home view, and a small personal profile kept on the Mac (merged; numbered D-120 on its branch)
- **When / who:** 2026-10-31 ~23:10–23:45 PKT · the user asked for a home that lists earlier conversations, opens and continues them, and uses them to make answers personal; built by the chilly-history side session (Opus 5.5). Number provisional: renumber at merge if a sibling session took D-120.
- **What:** each conversation's panel lines (never tool steps or screenshots) are saved as it goes in `~/chilly/conversations/<uuid>.json` (folder 0700, files 0600; title from the first real question, no model call; on by default, a switch turns it off; deletion removes files after a confirmation). The open panel shows a home when nothing runs and the conversation is empty, or when asked: a time-of-day greeting, the talk line, four recent conversations and All conversations…; a glyph left of the Screen control (⇧⌘H) switches. Opening one makes it current, and its answered exchanges go to the engine (serve: `restore` after `reset`) within D-113's budget. The profile is the existing `memory.jsonl`: `remember` refuses secrets and hedged guesses and keeps each fact once; the prompt shows the facts and the five newest conversation titles as background, never instructions, read once per conversation for caching; a bare greeting gets context. Settings › Memory lists the facts to change or forget.
- **Why:** the user wants what has been said over time kept and usable; everything stays on the Mac and in the user's control (D-109's privacy line).
- **Alternatives:** one append-only log for all conversations (simpler writes, harder to delete one); model-written titles or summaries of past conversations (a model call per conversation and a new failure mode, as with summarising in D-113); sending past conversations' lines as context (more tokens, more exposure); a switch in the band (the band is full, BandLayout tests); a new `SettingsSection` case (an existing test pins the five sections, so Memory is a `SettingsPane`).
- **Status:** built on `chilly-history`; 559/559 Swift tests, selftest, ServeCheck; renders checked. **Not built into the app, not tried live, the prompt rules not tried with the real model.** Notes: `(not in this export)`.

### D-124 · Hold Right ⌥ to talk, let go to send; a quick tap works as before (merged)
- **When / who:** 2026-10-31 ~23:30 PKT · the user: "use that option key to give input to Chilly while you hold it. As soon as you leave that key, Chilly responds"; built by the hold-to-talk session (Opus 5.5), merged by the parent at ~00:05 on 2026-11-01.
- **What:** the Right ⌥ detector reports press, release after a hold, and tap; a hold goes through the same path as ⇧⌘Space (listen on press, send on release); a tap keeps today's behaviour; Right ⌥ with any other key or modifier never starts listening and the tap stays pass-through.
- **Why:** a tap-to-start, tap-to-send key needed two presses for one message.
- **Status:** merged (`77f7514`, in `75741c5`'s merge line); 6 new tests; not tried live.

### D-126 · A tap while Chilly is transcribing sends the words; ending the conversation never drops a pending utterance (merged)
- **When / who:** 2026-11-01 ~11:40 PKT · diagnosed by Claude (Fable 5.1, parent session, with a read-only subagent) from the user's report ("you see those words being transcribed … then they disappear, which does not really get the assistant to act on that"); built by the `chilly-send-tap` side session (Sonnet 5.5) in the shared checkout.
- **What:** in a conversation the endpointer closes the mic after ~1 s of quiet and waits up to 2.5 s for Apple Speech's final text (phase Transcribing). A tap of the talk key, Right ⌥ or the mic glyph in that window reached `toggle()` with `recording == false`, so it fell through to `endHandsFree(.user)`; when the final text then arrived, `HandsFree.utteranceFinished` returned nothing (`guard isOn`) and `voiceIgnored()` cleared the words. Now a tap during Transcribing means "send now" (deliver the latest partial at once and submit), and an utterance that was already ending when the conversation is switched off for any reason but an explicit cancel (Escape, the menu-bar panel toggle, lock, sleep, idle timeout) is still submitted before the conversation ends. The menu-bar toggle respects "Keep listening when the panel closes" as the panel's own close does. Decided in `HandsFree` (Core) so it is unit-tested; a `voice.log` line marks the path.
- **Why:** the words were on screen and the user had finished; losing them on the very gesture that means "go" is the worst case. The other paths that clear shown words (D-101 hold-back when on, stop phrases, noise, Stop, typing while listening) are intended and stay; the hold-back note must be visible.
- **Alternatives:** shorten the 2.5 s final-result wait (helps, but the tap still has to mean send); a tap as "cancel" (what it did, by accident).
- **Status:** committed `2e65a24` on `companion-ui` (the session shared the checkout), in the 12:50 build; 10 new tests, 718/718 at the commit. **Not live-verified.** The live check is the user's: speak, pause a second, tap, and see the turn start; `~/chilly/voice.log` should show "tap while transcribing: sending now".

### D-131 · The 3D figure card joins Chilly's screenshots like the other drawings; the home page never covers the composer (in progress)
- **When / who:** 2026-11-01 ~19:10 PKT · from the user's live round on the 18:00 build (18:51–19:01, pasted; raw answers in `~/chilly/answers.jsonl`, the first round the log could diagnose) and two screenshots of the panel. Claude (parent, Fable 5.1) diagnosed; built by the `chilly-panel-fit` side session (Sonnet 5.5) on worktree `chilly-panel-fit` from `5779de0`.
- **What:** (1) `FigureStageCard` sets `sharingType = .none` unconditionally, so the 3D figure is never in the screenshot sent to the model even though D-129 made the overlay and the explain card follow `DrawingCapture` (shown while a drawing is up unless the user turned the setting off). The figure card follows the same rule and registers its window with `ScreenCapturer.keepIn` while a figure is up. (2) The open panel is a fixed 460×380; the home page (greeting, hint, the listening line, four recent rows, "All conversations…") plus the composer is taller than that once the listening lines show, so the text field is half under the bottom edge. The composer stays pinned and fully visible; the rows give way or scroll.
- **Why:** the live round's turn 16: "I can't see the watch in this screenshot… Chilly's board isn't captured", the very blindness D-129 ended for 2D; the watch edits were made from the part list, not from what was on screen. The user's screenshot shows the cut-off field in both the idle and the listening state.
- **Alternatives:** a taller panel (changes every geometry test and the notch look for one page); fewer recent rows always (the list is useful when there is room).
- **Status:** built by `chilly-panel-fit` (`6a6c7bf`, notes `(not in this export)`), merged `91ece3e` (~21:25) on the user's "Wait for both", in the 21:36 build; 809/809 on the branch. **Not live-verified.** Also seen in the round and **left open**: the board was empty after the user switched displays (turns 2–5 on the built-in display, turn 6 on the external with no canvas, parts without boxes on return at turn 10), so the user had to ask for the diagram again; the right triangle's six marks all came after the first two sentences in one block (no interleaving on the words; the whiteboard live eval is still unrun); the clipboard turn also wrote `~/chilly/tmp/chat_history.txt` unasked; the old conversation's title leaked into "your binomial-style triangle question"; the web search failed on the Interstellar question (not looked into). What worked: the watch became 3D without the word 3D, both edits kept the other parts, the title greeting, no takeaway spoken.

### D-182 · Anything of Chilly shown to other people is the real app on the user's live screen, recorded by the user; no made-up screens (active)
- **Number note (2026-11-09):** numbered D-134 when written on 2026-11-02, which collided with the listening decision. Same decision, new number, left in its original place. Older mentions of D-134 about demos, clips or synthetic screens mean this entry.
- **When / who:** 2026-11-02 ~09:20 PKT · the user said this while a separate session (Opus 5.5) was drafting a reply to a past client and looking at the rendered demo still: **"Whatever you do, I need the live screen. I don't need a made-up Mac screen that Chilly designed or works on."**
- **What:** clips, screenshots and demos of Chilly for clients, LinkedIn or anyone else show the real app running on the user's Mac. The user records them, because Claude has no screen access (D-81), and checks each one for anything personal before it goes out. The offscreen renderer over the synthetic screen (`companion/tools/demo-video/`, output in `(not in this export)`) is never used for anything shown outside.
- **Why:** the user wants people to see the product as it really runs, not a staged screen.
- **Scope (Claude's reading; the user may widen it):** outward-facing material only. Internal renders and evals keep using synthetic screens, since the privacy rule prefers them to real screen data.
- **Alternatives:** the 27 s rendered demo (~3 fps, synthetic screen), rejected for outward use.
- **Status:** Active.

### D-134 · Listening ends after 2 quiet minutes, the talk button stays calm while listening, New conversation always reachable, no pointer (in progress)
- **Number note (2026-11-09):** a second decision also carried D-134 until today. This entry keeps the number, because code comments and commits cite it. The live-screen rule is now D-182.
- **When / who:** 2026-11-02 ~10:00 PKT · the user, after the D-133 build: "the listening mode should turn off" after 2 to 5 minutes of nothing; the listening look on the talk button "might not be needed because it says listening on the top"; "no straightforward way of starting a new conversation … when you have an active conversation"; "I do not really like the cursor at all." Claude (Opus 5.5) diagnosed from the code; to be built by `chilly-panel-v3`.
- **What:** (1) The hands-free quiet spell defaults to **2 minutes** (`HandsFreeSettings.idleTimeoutDefault` 300 → 120; 120 joins the menu's choices; a saved choice is kept), and words held back as another app's audio no longer restart it. (2) While listening the talk capsule keeps its shape and colours; only the mic glyph turns orange (the privacy colour) and the label reads "Stop listening"; no level meter in the composer (the band shows the state). (3) New conversation works while listening: it clears the conversation and keeps the mic open for the new one; ⌘N in the panel; the expanded sidebar gets a "New conversation" row at the top. Still disabled while a reply is running (Stop shows there instead). (4) D-133's pointer window, its setting and its tests are removed.
- **Why:** the quiet timer is reset by any meaningful words, so another app's speech kept the mic on; `canStartNew` is `!state.isBusy`, and listening counts as busy, so with listen-while-open (default on) New conversation was greyed out almost all the time.
- **Alternatives:** a spoken "new conversation" phrase (later, if wanted); keeping the meter in the composer (the band already shows the level in the peek).
- **Status:** built by `chilly-panel-v3` (Sonnet 5.5) as `529054a` (notes `(not in this export)`); parent re-ran the gates on the branch: selftest, ServeCheck, `swift test` **839/839**; renders checked by eye (calm capsule, sidebar row). Its own build signed ad hoc because the keychain step hung in that session; the merge build signs normally. Merged `3ac5149` on the user's "Merge and rebuild"; merged head 839/839, selftest, ServeCheck; **build 10:36** signed "Chilly Local Signing", verified, no keychain prompt, not launched. **Not live-verified.** Open: with "Hold back words heard over other apps' sound" off (its default, D-101), another app's speech is sent as a request, which still resets the quiet spell; only the held-back case was fixed. Supersedes D-133 item 7.

### D-135 · Band glyphs: one optical size and stroke, boxed expand and shrink (in progress)
- **When / who:** 2026-11-02 ~10:55 PKT · the user, from a screenshot of the expanded band on the 10:36 build: "no symmetry between them … small and big. Small is fine but consistency is crucial"; the expand/shrink arrows "don't look good", with a reference of outline rounded squares holding two diagonal arrows. Claude (Opus 5.5) found the causes; to be built by `chilly-band-icons`.
- **What:** every band glyph (Home pebble, New conversation or Stop, Settings or back, Expand/Shrink, Collapse) sits in the same 22 pt slot with the same optical box (about 14 pt) and the same stroke weight; Expand is `arrow.up.left.and.arrow.down.right.square`, Shrink `arrow.down.right.and.arrow.up.left.square` (outline, SF Symbols, our own choice from the system set); the pebble becomes an outline at the symbols' stroke weight instead of a filled even-odd shape. A pure size table in `ChillyCore` with tests, and an offscreen strip render to compare.
- **Why:** SF Symbols at one font size differ in visual size (the pencil and bubble read large, the arrows and chevron small and light); the pebble is a custom filled shape 15 pt wide with no matching weight.
- **Status:** built by `chilly-band-icons` (Sonnet 5.5) as `8f54a89` (notes `(not in this export)`: measured boxes, scale table, 4× strip); parent re-ran 844/844, selftest, ServeCheck. Pebble part superseded by D-136. Merged with D-136 in `bfd7cdd`.

### D-136 · Consistency pass on the band: Home is a house, Settings and New conversation live only in the band, in both sizes (in progress)
- **When / who:** 2026-11-02 ~11:15 PKT · proposed by Claude (Opus 5.5) under the user's new standing rule ("You can push back on anything from me that might introduce inconsistencies"); the user: **"Agree all three."**
- **What:** (1) Home is the `house` SF Symbol at the band's measured size; the pebble stays in the menu bar and app icon only (supersedes D-133's pebble Home). (2) The gear stays in the band in the expanded size too; the sidebar's pinned Settings row goes. (3) New conversation only in the band (⌘N kept); the sidebar's top row goes, leaving RECENT and "All conversations…". (4) The chevron's stroke matched to the others.
- **Why:** the pebble is a brand mark among system symbols and never matches them; Settings and New conversation moved or doubled between the compact and expanded sizes.
- **Status:** built as `f835120` on `chilly-band-icons`; parent re-ran 844/844, selftest, ServeCheck, and checked the 4× strip, idle and expanded renders. Then `ad76664` (wording: "Hold Right ⌥ to talk", tooltip says what a tap does, following `updateTalkHint`), approved by the user ("Fix wording, merge"). Merged `bfd7cdd`; merged head 844/844, selftest, ServeCheck; **build 12:05** signed and verified, not launched. **Not live-verified.** The clash raised under the same rule, now fixed: the capsule says "Hold right ⌥ to talk" (lower-case, hold only) while the home hint and permission text say "Right ⌥" and "tap".

### D-137 · The app icon and menu-bar glyph are Exchange; the pebble retires (in progress)
- **When / who:** 2026-11-02 ~16:00 PKT · the user ("Adopt Exchange"), after rejecting Pebble v2 and two rounds of Claude's directions. The mark was proposed independently by ChatGPT ("The Exchange") and OpenAI Codex (`gpt-5.6-sol` "Quiet hinge", `gpt-6-astra` "Quiet joint") at the user's request, and refined by Claude (Opus 5.5).
- **What:** (1) App icon: two thick rounded elbows on opposite corners of a square, with equal half-stroke gaps; the light mint half is you, the deep mint half is Chilly; gradient black tile; mark about 60% of the tile; default, dark, tinted and clear appearances built as a macOS 26 layered icon from `(not in this export)`. (2) Menu bar: the two elbows as a one-ink template glyph (1.75 pt stroke, 11.5 pt box); while Chilly is busy with a turn (listening, transcribing, working, speaking or awaiting approval) the glyph switches to the halves closed into one rounded square, and back when idle. A swap, not an animation. (3) Pebble wording in the app, build script and design-system docs goes; the pebble artwork moves to `(not in this export)` as history.
- **Why:** the pebble said "calm" only to people who knew the story and read as an empty ring in the menu bar. Exchange is simple, survives 16 px and 18 pt, and carries the product's promise (you start it, Chilly hands it back); the working state gives the menu bar a real-event signal (design-system rule: nothing changes without a real event).
- **Alternatives:** Pebble v2 (D-59, D-64, kept until now); round one (Notch, Notch and pebble, Notch line, c lettermark); round two (Untangle, Settle, Tilde); Exchange, round (reads as refresh); the Codex drafts Held space, Soft relay, Slipfold, Counterweight. Known risk accepted: at a glance Exchange can recall a crop or selection symbol.
- **Supersedes:** D-59 (app icon direction) and D-64 (menu-bar glyph).
- **Status:** built by `chilly-exchange` (Sonnet 5.5) as `3d4c739` and `0f7b59e` (notes `(not in this export)`); parent re-ran 848/848 and checked the icon ladder and 4× glyph renders; merged `1122d03`; merged head selftest, ServeCheck, `swift test` **848/848**. `build.sh` compiled and assembled (15:57) but **signing hung** (the "Chilly Local Signing" key needs a keychain approval only the user can give), so the bundle is unsigned. Published design-system artifact updated to version 9 (`1793622012-ef9b`) on the user's OK at ~17:20: Logos now hold the Exchange icons and both glyphs; Icon options still list the retired pebble drafts (repo source tags them retired). Not live-verified.

### D-138 · Band v2: one sidebar toggle, a smaller collapse chevron, back is a chevron (in progress)
- **When / who:** 2026-11-02 ~17:20–17:35 PKT · the user, from two screenshots: the collapse chevron "doesn't sit well with the rest"; of three renders they liked the smaller chevron; "the squared icon does not really look consistent with the rest of the three icons to the left"; on Home, "a new chat icon, and there's another chat icon". Claude (Opus 5.5) measured the glyphs and rendered options; Codex (gpt-6-astra, high) reviewed them (`(not in this export)`). User: **"Adopt it."**
- **What:** (1) Collapse is `chevron.up` at semibold and the base size (about 11.4 × 6.6 pt), no longer the lighter, wider exception. (2) Expand and Shrink become one toggling `sidebar.left` ("Show recent conversations" / "Hide recent conversations", with its on state exposed to accessibility); the boxed arrows retire. (3) Back to the conversation is `chevron.backward` in slot 1 on Home and in Settings, sized to match the collapse chevron; the band no longer uses `bubble.left`. (4) In Settings the gear stays a gear, drawn as selected (full-strength glyph on a faint rounded fill), instead of turning into a back button. Conversation rows in lists keep `bubble.left`.
- **Why:** measured at band size the boxed arrows carry the most ink (about 97 pt² against 62–86) because a square with four arrowheads is dense, and no box size fixes that; `sidebar.left` also names what Expand shows. The bubble was the lightest glyph and, next to the compose pencil, made two conversation icons whose difference ("back to this one" vs "start a new one") users had to guess. One back place, one compose icon.
- **Alternatives:** boxed chevron (`chevron.up.square`, matched the boxed arrows, not the left three); bare diagonal arrows (rejected by the user in D-135); a heavier or text-filled bubble (fixes weight, not meaning).
- **Supersedes:** D-135's boxed expand and shrink and its lighter chevron; D-136's bubble as the back glyph.
- **Status:** built by `chilly-band-v2` (Sonnet 5.5) as `060e25c` (notes `(not in this export)`, 4× state strip); scales: `sidebar.left` 0.93, both chevrons 1.00 semibold, the lighter-weight exception removed. Back from Settings returns to the page underneath (label names it). Parent re-ran `swift test` **851/851**, selftest, ServeCheck, and checked the strip. Merged `f6e8a00` on the user's word ("Merge it"); merged head 851/851, selftest, ServeCheck. Not built signed, not live-verified.

### D-139 · ⇧⌘Space goes; Right ⌥ is the only talk key (in progress)
- **When / who:** 2026-11-02 ~17:30 PKT · the user, seeing "⇧⌘Space" on the talk capsule: a two-handed chord is the wrong choice. Claude (Opus 5.5) traced it: the code had not changed the key. The running app was the ad-hoc 15:51 build (signing hung, identifier `ChillyApp`), which macOS treats as a different app without Accessibility, so Right ⌥ was not ready and the capsule fell back to D-28's ⇧⌘Space. User: **"go ahead with shift-command-space removal"**.
- **What:** remove the ⇧⌘Space Carbon hotkey and everything that names it (`PushToTalk`, the hint and capsule fallbacks, Settings' shortcut line, tests, the brand book's two mentions). Right ⌥ (D-40) is the only talk key; the mic button and click-to-talk stay. When Right ⌥ is not ready, the capsule and hint say why ("Right ⌥ needs Accessibility") and point to Finish Setup, never to another key.
- **Why:** one talk key, one-handed, as decided in D-40/D-41 ("holding three keys needs both hands"); a fallback that advertises a rejected chord is inconsistent.
- **Alternatives:** keep ⇧⌘Space registered but never shown (offered; the user chose removal).
- **Supersedes:** D-28.
- **Status:** built by `chilly-band-v2` as `2be9b51`: `PushToTalk.swift` deleted, `ComposerTalk.hint` and a `needsSetup` capsule title ("Right ⌥ needs Accessibility"), Settings' Shortcut row gone, brand book and component notes cleaned; gestures unchanged. Parent re-ran 851/851, selftest, ServeCheck. Merged `f6e8a00` on the user's word ("Merge it"); merged head 851/851, selftest, ServeCheck. Not built signed, not live-verified.

### D-141 · Background jobs v1: a job is a second turn in the same engine, in its own folder, behind the same gate, parked (not failed) on an unanswered approval (built, unmerged; numbered D-141 on its branch)
- **When / who:** 2026-11-04 ~16:00–19:30 PKT · the user accepted D-130 step 1; built by a side session (Claude Sonnet 5.5) from the parent session's brief, on the `claude/chilly-jobs-e183b6` worktree. Notes: `(not in this export)`.
- **What:** (1) **Same process, not a child per job:** `Server` already runs turns in worker threads over a stateless provider and every `Agent` owns its `Ctx`, so a job is a second `_Turn`, found by `approve` under its id. (2) **Storage:** `~/chilly/jobs/<uuid>/` with `job.json`, `report.md`, `output/`, `tmp/`; the record stores a lifecycle, the shown state (`queued`, `working`, `needs-you`, `done`, `failed`, `stopped`) is derived in `chilly/jobs.py` and sent as such. (3) **Gate:** the job's own `Agent`, with its folder as the working folder; the user's own words (not the brief) are what `remember` and named sites are compared with; the foreground turn's taint is handed down; `start_job` itself asks in a tainted turn; `read_job` of a job that read outside content taints the reader. (4) **An unanswered approval parks the job** (`needs-you`, no timeout, answered only by the app's own Yes/No in the row) instead of declining it. (5) **Start** after a 2.5 s beat the notch peeks and Esc cancels; **steer** between tool steps; **one job at a time**; no screen, no browser, no nested jobs. (6) **Finish** with a structured turn_end (spoken line, files checked on disk, at most three chips), parsed leniently; the report is written by code. (7) **UI:** one quiet row in the panel, a peek line for the beat and for news not yet seen, the thread saved as a conversation under the job's id so it opens in the history view. (8) **Recall:** `find_jobs` and `read_job`, a local word search, no embeddings.
- **Why:** a second process would have meant a second protocol path, a second approval path and shared files without locks, for no isolation the per-`Agent` `Ctx` doesn't already give; parking is what makes a background job usable when the user is elsewhere (a timed-out No would have the model "adapt" with nobody watching); deriving the state in code keeps D-130's rule that nothing the model writes decides what the panel says.
- **Alternatives:** a child `chilly --serve` per job (rejected above); a deck of cards (D-130: not until parallel jobs are common); a job with the screen or a browser (out of scope: D-132, D-130); resuming a parked job across a restart (v2: it would need the model's conversation persisted); letting the job's tainted writes into its own folder go unasked (rejected: D-132 says every write asks).
- **Status:** built, **not committed, not merged, not built into the app, nothing seen live**. 52 new selftest checks (637), 44 new Swift tests (888/888), 8 new ServeCheck checks through the real `ServeBackend` and engine (ALL PASSED), four offscreen panel renders checked. **The "existing" chimes the brief names do not exist** (D-65's cues were never built): only the mapping from job state to done / needs-approval / error exists, behind `jobCues` (off); nothing plays. Unverified: the real model's brief and turn_end, Esc in the beat, the live row and peek, a real approval, steering, the history view's thread. **[Reconciled 2026-11-09: in `companion-ui` (`fd55e33`). Any "not seen live" wording here still stands.]**
### D-144 · One metadata-only audit log, an engine log file, and a "copy diagnostics" action (accepted 2026-11-05; built, not live-verified)
- **When / who:** 2026-11-05 · the user asked whether we log enough that a problem can be found in the logs afterwards, and whether that much is needed; the orchestrating session read the code and `~/chilly`.
- **What we log today (seen):** `answers.jsonl` (one record per foreground turn: raw answer, events including tool name and a short detail, approvals; mode 0644; rotated at 2 MB), `latency.jsonl` (timings, 0600), `usage.jsonl` (token counts), `voice.log` (push-to-talk states), saved conversations, and for jobs only the end state in `job.json` and `report.md`. The app's engine stderr is kept as the last 20 lines in memory and written out only with `CHILLY_DEBUG=1`.
- **Gaps (seen):** (1) job turns never reach `answers.jsonl`, so a job's tool steps, asks, denials and taint are not recorded between start and end; (2) gate decisions (allowed, asked, denied, and why) are not logged anywhere durable; (3) engine crashes and tracebacks are lost after a restart; (4) the browser (connect, refuse, grant, origin) and the job-row actions (answer, stop, steer) leave no trace; (5) `answers.jsonl` is world-readable and holds raw answer text.
- **Proposal:** (a) one `events.jsonl` in the working folder, mode 0600, rotated, **metadata only**: time, turn or job id, a kind from a closed list (turn start/end, tool with its gate class free/quiet/asked/denied and a reason code, approval asked and who answered by which channel, job state change, taint set and source host, browser connect/grant/refuse with the host only, engine start/exit with exit code and error type). Never message text, page text, file contents, full URLs, keys or tokens. (b) The engine's stderr goes to a rotated `engine.log`, also 0600. (c) `answers.jsonl` becomes 0600. (d) A "Copy diagnostics" action (and `chilly --diagnose`) prints the last N hours as a short report: errors, denials, failed or interrupted jobs, slow turns, with no content, so it can be pasted into a bug report. (e) Tests: every gate path writes exactly one event; a canary string in a message, page and file never appears in any log.
- **Why not log everything:** content is already in the saved conversations the user can see; a second full copy in logs would double the privacy exposure for little diagnostic gain (privacy and security first). Metadata answers "what happened and why was it allowed" without copying what the user said.
- **Alternatives:** keep as is (no way to explain a job after the fact); full transcript logging (rejected, privacy); an external log service (rejected, local only).
- **Status:** ~~proposed; not built.~~ Cost estimate: one side session, about the size of jobs v1's storage work.
- **Status update (2026-11-05 ~14:00 PKT):** the user accepted it; built by a side session (Claude Sonnet 5.5) on `claude/chilly-logging-de28ca`, **uncommitted, not merged, not live-verified**. All five parts: `events.jsonl` (`chilly/audit.py`, the closed list of 16 kinds, a schema checked at write), wired into the gate (`tools.decide()`), turns including job turns, approvals, job states, taint, the browser tools and link, the engine's start and exit, and the app's job-row buttons, engine exit and launch, and browser switch; `engine.log` (the app appends every stderr line, redacted); `answers.jsonl`, `usage.jsonl` and `voice.log` now 0600 (an existing wide file is tightened on its next write); `chilly --diagnose [--hours N]` and Settings › General › Diagnostics › Copy; tests with a canary. Unit-tested: `selftest.py` 780 checks (42 new), `xcrun swift test` 934/934 (17 new), ServeCheck ALL PASSED (6 new), public export check passes. Notes: `(not in this export)`. Two things the brief called for that turned out different: there was **no existing secret redaction** to reuse (written, in both languages, with 21 shared cases), and the engine's stderr **did** carry message text in six places (card words in the approval lines, tracebacks, OS error paths); all fixed (see D-145).

### D-145 · Audit-log mechanics: the schema is enforced at write, the app appends its own lines, hosts are logged but data-looking names are not, `answers.jsonl` stays the one content log
- **When / who:** 2026-11-05 · the side session building D-144, within its brief; the app-helper choice was the brief's to justify.
- **What:** (1) **Closed schema at write.** `audit.event()` refuses a whole event whose kind, field or value is outside `KINDS` (enums, ints, flags, ids, tool names, exception class names, hosts); there is no free-text field, so a careless caller cannot leak content, and `--diagnose` reads only lines that pass the same check. (2) **The app appends to the same `events.jsonl` itself** (one small helper, one utility queue) rather than sending events through the engine: it works when the engine is gone (its exit, a failed launch), adds no protocol request, and tests in a temp folder. Cost: two writers, both rotating by size; a simultaneous rotation could move a line to `.1` early, never lose it. (3) **Hosts are logged** (a refused host is the point of a browser refusal), **but a name with a label over 30 characters or over 80 in all is dropped** (the event is kept, without the host), so a page cannot make the model put data in a subdomain that then sits in the log. (4) **The tool event's class is the gate's own decision** (`tools.decide()`, the same value that makes the card), so the log cannot disagree with what the gate did; a call that was free and then refused by the tool (a blocked host, a tab off the list) is recorded as denied. (5) **`answers.jsonl` is unchanged in content** (the model's raw answers, the one content log, kept for diagnosing a live round), now 0600; job turns still do not go to it, their metadata is in `events.jsonl`. (6) **`engine.log` is written by the app** (it is the app that reads stderr), so a terminal run keeps its stderr in the terminal; the engine's stderr lines are made content-free at the source and redacted again on the way into the file.
- **Why:** privacy first and the smallest thing that explains an incident: what ran, what the gate said and why, who answered, what failed.
- **Alternatives:** a free-text `detail` field with a scrubber (rejected: a scrubber is a list of what we thought of); events through the engine (rejected above); logging the card's words (rejected: they are commands, paths and URLs); a Settings switch for the audit log (not now; `CHILLY_AUDIT=0` exists).
- **Status:** built with D-144, same branch, same state.



### D-146 · Friction fixes after the first live run: taint is a set and the screen alone is weaker, compound read-only shell commands, a written line for jobs, fewer jobs in Recents (amends D-132; accepted by the user 2026-11-05; built, not live-verified)
- **When / who:** 2026-11-05 afternoon · the user approved four fixes after the first live run of jobs v1 and the audit log (`chilly --diagnose`: 13 tainted turns in two hours, 11 of them only from looking at the screen, so nearly every job start and write asked); built by a side session (Claude Sonnet 5.5, worktree `chilly-friction-9aa8a5`) from the orchestrating session's brief. Notes: `(not in this export)`. The brief called this D-145; D-145 was already taken by the audit-log mechanics, so it is D-146. Amends D-132 (supersedes only the rule below; the rest of D-132 stands).
- **What:** (1) **A turn's taint is a closed set of sources**, `screen`, `web`, `browser`, `file` (`file` is everything else from outside that is not a screenshot: a file outside the working folder, AppleScript output, the output of a command that isn't read-only, an unverified skill; as strong as `web`), kept in code (`Ctx.taints`), carried into a job as `taints` beside `tainted_by`, and written to the audit log as fixed values (a `taint` field on `taint` and `tool` events). Rules are decided from the set, never from model text. **The one rule that changed: starting a background job does not ask when the foreground turn's only source is the screen.** The job still asks for every change (the card says "Chilly read the screen this turn"), the 2.5 s beat and Esc remain, and starting a job after a web page, a fetch or search result, a browser read, a file or any mix with one of those asks as before. A turn or job that only looked at the screen still asks before any write, `remember`, shortcut or send; a fetch of a host nobody named still asks; a job that reads a page after inheriting the screen becomes `screen+web` at once. Inside a job, read-only commands in its own folder do not ask on screen-only taint; that was already how allowlisted commands behaved under any taint, and the asks the user saw came from (2). (2) **Compound read-only shell commands:** a command is read as simple commands joined by `;`, `&&`, `||`, `|`, `&` or a newline, and runs unasked only if every part is on the read-only list, every path is inside the working folder and the only redirects are to `/dev/null` or exactly `2>&1`. Any other redirect, `$(…)`, backticks, variables, `$'…'`, here-documents, process substitution, `eval`, `sudo`, `rm`, `mv`, `dd`, `chmod`, `chown`, `kill`, `curl | sh`, an unknown program, an unusual space character, or a command over 4000 characters keeps asking. The card says what it saw ("a compound command that writes to a file", "`sleep`, a command that is not on the read-only list") and says "potentially destructive" only for a real deletion, overwrite or permission change; a word such as `rm` that is only an argument is "a command that contains `rm`". Two new codes, `shell_writes_file` and `shell_system_action`. (3) **A written line:** a job's `turn_end` carries `spoken` (240 characters, for a speaker) and `written` (140, for the row, the peek, the thread and `report.md`); code derives the written one from the spoken one when the model gave none ("output slash tea dot txt" becomes `output/tea.txt`). (4) **The label** says what applies ("Chilly looked at your screen, so changes ask first." for the screen alone; the old wording for anything stronger or an engine that doesn't say), and **Recent** (home view and sidebar) shows at most one job thread, the newest; "All conversations" keeps every one.
- **Why:** a taint that fires on most turns trains the user to press Yes without reading, which is worse than a rarer ask: the screen is looked at on almost every turn, so it is the weakest, most frequent source, and a card for starting a job (which asks again for every change) bought little. A web page, the browser and files are the sources that can carry an instruction, so they keep every ask. The shell allowlist could only read one simple command, so an honest `ls … 2>/dev/null; ls …` was "potentially destructive", which wasn't true and made the card less believable.
- **Risks of loosening the screen rule (honest):** a window the user had on screen (a web page in any browser, a chat message, an email, a document) can contain text that gets the foreground model to call `start_job`, and it now starts after a 2.5 s peek with no card. The job's brief is shaped by that text and its title is what the row shows. Without a card the job can: search the web (the query can carry text the model saw on the screen out to the search provider), fetch hosts the user named or a search found (a short query can carry data to such a host; only long or encoded URLs are reviewed), read files inside its own folder and run read-only commands there, and spend up to 40 model steps (money and time) while nobody is watching; one job at a time. It cannot, without a card: write or overwrite any file, remember anything, run a shortcut or a non-listed command, fetch a host nobody named, read outside its folder or a private path, or use the browser (its sites are a grant on their own card). Anything it reads from the web turns its taint into `screen+web` and the report it leaves is then tainted for a later reader. The beat and Esc are the user's only chance to stop an unwanted start; the row shows it at once. The compound-command change widens what runs unasked only to combinations of commands that already ran unasked one at a time, plus output sent to `/dev/null`.
- **Found on the way:** `cat $'\x2fetc\x2fpasswd'` and `cat $'\x2e\x2e/x'` ran unasked in the old allowlist (`$'` was read as a literal `$` and a quoted string, the shell spells out the characters); now asked. True on `companion-ui` before this change.
- **Alternatives:** make the screen taint ask nothing about writes (rejected: the user's rule is that a turn that looked at the screen still asks before a write); drop taint for jobs altogether (rejected: it is what makes a job's report safe to read later); a per-folder "always allow" (still the user's call, not built); only fixing the wording of "potentially destructive" (kept the asks, changed what they say; the parse is what lets honest compounds through); a separate "Jobs" heading on the home view (one job entry in Recent is smaller and adds no visual language).
- **Status:** accepted by the user 2026-11-05. Built on `claude/chilly-friction-9aa8a5`, **uncommitted, unmerged, not built into the app, not seen live.** Unit-tested: `selftest.py` 1053 checks (273 new, `selftest_friction.py`, including a seeded fuzz of 10000 random commands whose allowed ones ran in a sandbox and changed nothing, a check that every ask that exists today for web, browser and file taint still asks, and a canary run through a real `Server`), `xcrun swift test` 942/942 (8 new), ServeCheck ALL PASSED (the written line through the real `ServeBackend`), `make_public_export.py --working-tree` passes. Not verified: the real model's `written` line and its brief, the new label and Recents on screen, a hostile window against a real job. **[Reconciled 2026-11-09: in `companion-ui` (`b570578`). Any "not seen live" wording here still stands.]**


### D-147 · First-class open-model providers: DeepSeek, GLM, Kimi, Qwen, Ollama and LM Studio as presets of the OpenAI-format provider (accepted by the user 2026-11-05; built, not live-verified)
- **When / who:** 2026-11-05 · the user asked for first-class support for the most popular open-weight model families (DeepSeek, GLM, Kimi, Qwen) "instead of being fixed to OpenAI and Anthropic"; built by a side session (Claude Sonnet 5.5, worktree `chilly-models-679fce`) with four research subagents that read each provider's own documentation that day. Notes: `(not in this export)`; public: `docs/providers.md`. The number D-147 assumes nothing else took it; renumber on merge if needed.
- **What:** (1) **`CHILLY_PROVIDER=deepseek|glm|kimi|qwen|ollama|lmstudio`** (aliases `zai`, `zhipu`, `moonshot`, `dashscope`, `lm-studio`), each a preset (`chilly/presets.py`) of `OpenAIProvider`: base URL (international and China for GLM, Kimi, Qwen; `CHILLY_REGION`), key variable (`DEEPSEEK_API_KEY`, `ZAI_API_KEY` or `ZHIPUAI_API_KEY`, `MOONSHOT_API_KEY`, `DASHSCOPE_API_KEY`), default model, and `CHILLY_BASE_URL` / `CHILLY_MODEL` still override. `claude` and `openai` are unchanged (a test pins the OpenAI payload). **Model ids come only from documents read on 2026-11-05** (`deepseek-flash`, `glm-5.3-flash`, `kimi-k3.1-pro`, `qwen3.8-flash`; the local presets have none, the user names the model), each with its doc date in `docs/providers.md`, each replaceable with `CHILLY_MODEL`. (2) **Safety of the address:** a hosted preset is https only; plain http only for `ollama` and `lmstudio` on `localhost` or `127.0.0.1`; **a preset's key is sent only to its own host** (another `CHILLY_BASE_URL` needs `CHILLY_API_KEY`); GLM's and Kimi's **coding-plan endpoints are refused** (their terms limit them to listed coding tools); clear errors for a missing key (names the variable and where to make one), an unknown provider (lists the valid ones), two providers' keys with no choice, and a model that rejects tools. (3) **Provider correctness** in `OpenAIProvider(preset=…)`: the documented limit parameter (`max_tokens` for DeepSeek and GLM, `max_completion_tokens` for Kimi and Qwen; 8192, 16000 for Kimi), `stream_options` only where documented (not GLM), tool-call deltas by index (or whole), parallel calls, usage from each provider's cache fields into `usage.jsonl`, a retry of 429/5xx twice (`Retry-After` honoured to 8 s; not for balance or quota errors), short errors (`HTTP 429 from host: code · message`, never the body), `<think>` tags cut from local models' text, and **no Anthropic-only parameter** (cache markers, effort) ever sent. (4) **Thinking** is off by default (`CHILLY_THINKING=off|on|default`): DeepSeek and Qwen by their switch; GLM-5.3 and Kimi K3 cannot be switched off, so `reasoning_effort: low`. **Reasoning is never shown, spoken, logged or saved**; it is kept in memory for the session and sent back only where the docs require it (DeepSeek with thinking on, Kimi K3). (5) **Images:** a per-preset list of the ids whose docs say they read images (full match), `CHILLY_VISION=1|0` overrides; a model not on the list is taken not to read images, and then the engine says so in `ready` and `--print-provider`, **the app keeps Screen off for the session** (the saved choice is untouched; Settings › Screen says why), the startup line says `screen=off`, and the provider refuses a picture before sending it. (6) **Visible destination:** the startup line `sends to=DeepSeek (api.deepseek.com)`, `ready` and `--print-provider` carry `host`, `engine_start` in the audit log carries provider, host and model (closed vocabulary), `chilly --diagnose` prints "Sending to …", Settings › General › Model says "Your messages go to …"; README and `docs/providers.md` say that hosted providers receive prompts, tool results and screenshots, and where each says it stores them. (7) **Unchanged and now tested for every provider:** the gate, taint and audit rules (D-132, D-144, D-146); a whole engine run (foreground turn, page read, job, approvals) against a fake server per provider with a canary for the user's words, a page, the model's reasoning and the key, grepped in `events.jsonl`, `usage.jsonl`, stderr and the diagnose report. Key redaction gains an `id.secret` shape (Python and Swift, shared cases); the new key variables are kept out of tool processes. (8) **Tests without live keys:** `selftest_models.py`, a fake OpenAI-compatible server per provider that reproduces its documented quirks; and `tools/model_smoke.py`, a five-minute live check the user runs with his own key.
- **Why:** the user wants the most popular open-weight families and not to be fixed to two vendors. Most of them speak the OpenAI format, so the work is the parts that are not the same (thinking, reasoning replay, the limit parameter, images, 429s) and keeping the privacy promises visible and identical. Reading the docs that day mattered: per those docs `deepseek-chat` / `deepseek-reasoner` (scheduled off 2026-07-24), `moonshot-v1-*` and `kimi-latest` (retired) are gone, and the current generations are DeepSeek V4.x, GLM-5.3, Kimi K3.1 and Qwen 3.8/3.7.
- **Choices worth a second look:** (a) thinking **off** by default (voice latency; DeepSeek's thinking-mode rule makes on a feature to ask for); (b) Kimi's default is `kimi-k3.1-pro`, not the faster highspeed model, because only the former is documented as reading images; (c) GLM's default `glm-5.3-flash` is chosen although its vision schema lists no `tool` role (unconfirmed; the function-calling page says it supports tools), with `glm-5.3` as the fallback; (d) Qwen's legacy `dashscope*.aliyuncs.com` hosts are the default because workspace hosts need an id only the user has, and the docs say the legacy ones remain functional; (e) an unlisted model is taken **not** to read images (safe: Screen off, one override), so a new vision model needs the override or a table edit; (f) the local presets guess vision from the model's name.
- **Alternatives:** a class per provider (rejected: the differences are data); a generic "OpenAI-compatible" preset only (what existed: no per-provider quirks, no key variable, no safety rules); LiteLLM or another gateway (a dependency and a hosted hop; the rule is no third-party dependencies and no hosted backend); default thinking on (slow and DeepSeek-hostile); sending the pictures anyway and letting the server fail mid-turn (rejected by the brief); allowing the coding-plan endpoints (cheaper, but against the vendors' stated terms).
- **Risks the user accepted:** no provider was called live, so every "documented" fact is the document's word as extracted by a page summariser and every test passes against our reading of it; quality on these models is unmeasured (Chilly's prompts were tried against Claude); hosted providers in the PRC and Singapore receive the user's prompts, tool results and screenshots, which the README says plainly; model ids will go stale (they are one environment variable away).
- **Status:** accepted by the user 2026-11-05. Built on `claude/chilly-models-679fce`, **uncommitted, unmerged, not built into the app, not live-verified.** Unit-tested: `selftest.py` 1323 checks (270 new), `xcrun swift test` 943 (1 new, 1 extended), ServeCheck ALL PASSED, `make_public_export.py --working-tree` passes. Not verified: any real provider (use `tools/model_smoke.py <provider>`), the Settings text and the Screen-off state on screen, the app against a non-Anthropic provider. **[Reconciled 2026-11-09: in `companion-ui` (`97c8b6a`). Any "not seen live" wording here still stands.]**


### D-148 · Close the open-source gaps in the repository itself: an honest README with a status table, a build-from-source path, CI for everything that runs offline, community files, and a demo kit that records only the real app in a separate account (accepted by the user 2026-11-05; written, not run on GitHub)
- **When / who:** 2026-11-05 · the user asked to take stock of what the public repository has and what is missing (`(not in this export)`) and then close what a session can; built by a side session (Claude Sonnet 5.5, worktree `chilly-oss-gaps-a76cc2`) from the orchestrating session's brief. Notes: `(not in this export)`. Builds on D-142 (the export tool and the MIT licence).
- **What:** (1) **README rewritten for a public reader**: what Chilly is, a status table that labels each feature *stable*, *experimental* (unit-tested, run live once and briefly) or *not live-tested*, the safety model (gate in code, taint, approvals that park as *Needs you*, the metadata-only audit log and `chilly --diagnose`), background jobs, browser reach, the providers and what each one sees, privacy, and no decision ids. Jobs and the audit log are *experimental*; browser reach, OpenAI, DeepSeek, GLM, Kimi, Qwen, Ollama and LM Studio and the newest gate refinements are *not live-tested*. A selftest pins these labels so a feature cannot become "stable" by an edit to prose. (2) **Distribution, honestly**: a *Build from source* section (macOS 14, Xcode, `xcrun swift`, `build.sh`, the self-signed certificate step and that ad-hoc signing resets permissions every rebuild, what each permission is for, Gatekeeper for a self-built app, and that there is no notarised download), and `docs/RELEASING.md` for the owner: versioning, tagging, building, Developer ID signing, notarisation and stapling as a checklist whose commands are all marked as the owner's to run. Nothing was signed or notarised. (3) **CI extended**: the browser extension's node tests (headless Chrome only), ServeCheck, the export check where the export tool exists, a warning for unfilled placeholders, failures turned into annotations, a step summary and uploaded logs. (4) **Community files**: `CODE_OF_CONDUCT.md` (an adapted, shortened Contributor Covenant 2.1 with attribution and a placeholder contact), issue forms (bug report asks for `chilly --diagnose` and warns against keys and personal text; feature request), a pull-request template with a privacy check, `CHANGELOG.md` (Keep a Changelog; an honest 0.1.0 entry) and `docs/ROADMAP.md` (intentions, not promises; Windows is not planned). (5) **A generic demo kit** in `demo/`: how to record a real demo in a separate standard macOS account, a read-only `check-isolation.sh` that takes the owner's username as an argument and uses only `test -r`, `test -x`, `ls -ld` and exit codes, a hardening checklist the owner applies to their own account, a `seed.sh` that writes invented files only into the demo account's own home (and refuses as root, as an administrator, or with any other `HOME`), and a three-minute run sheet. The README of the kit says in plain words that it reduces risk and does not guarantee it, and lists what it cannot protect against.
- **Why:** the README did not describe the two headline features, the safety model or how far each was tested, so a visitor could not tell what to trust; there was no honest install path; CI covered a third of what the tests cover; there were no community or release files; and the only demo existed in a synthetic environment, which D-182 rules out. All of it is writing and scripts a session can do without touching the owner's accounts, keys, GitHub or signing.
- **Choices worth a second look:** (a) the three labels, and putting the post-first-run gate refinements (D-146) under *not live-tested* even though the app was rebuilt with them; (b) the code of conduct is shortened and adapted, not the full Covenant text, so it credits the Covenant under CC BY 4.0 instead of claiming to be it; (c) the export check in CI runs only where the export tool exists (the private repository), because the tool names private material and is not exported, and it is reached by a glob so the workflow itself does not name an excluded path; (d) `check-isolation.sh` FAILs on a stock macOS home folder (mode 755) by design, so the owner must apply the hardening first; (e) `seed.sh` refuses any administrator account, which includes the owner's own, on purpose; (f) the entitlements, Gatekeeper wording and Developer ID commands are from general knowledge of Apple's tooling, not run or tested here, and say so; (g) `companion/tools/demo-video` (a generator of a synthetic demo video, from before D-182) was removed; the shared synthetic-screen helper stays because the overlay render tool uses it.
- **Alternatives:** the full Contributor Covenant text (not reproduced from memory); making the export tool public so CI could run it in the public repository (it lists the private material by name); a hosted demo environment or a recorded-from-a-simulator clip (D-182); a script that creates the demo account and sets permissions (needs an administrator and changes system settings, which only the owner does); merging CI into one job (the separate jobs make a failure readable).
- **Not done / owner only:** run CI on GitHub; the live verifications; notarise; the trademark check; fill the placeholder contacts; the repository name, settings and first push.
- **Status:** accepted by the user 2026-11-05. Written on `claude/chilly-oss-gaps-a76cc2`, uncommitted. Checked offline: `selftest.py` (new `selftest_oss.py`), the workflow and issue forms parse as YAML, the extension's node tests pass headless, the export check passes. **Not verified:** the workflow on GitHub; the scripts in a real second macOS account; any claim in `docs/RELEASING.md` about signing and notarisation. **[Reconciled 2026-11-09: its branch is in `companion-ui`. Any "not seen live" wording here still stands.]**


### D-149 · Worked figure examples by family, with a short build recipe, added to a turn only when the message asks to draw something (built, committed, app rebuilt)
- **When / who:** 2026-11-05 · the user asked how to get better figures from Haiku 5.5 without switching model, then asked for richer examples and said to go ahead; built by the orchestrating session (Claude Sonnet 5.5).
- **What:** `chilly/figure_examples.py` holds a recipe (body first, then big parts, then details; mirror, copies and around; no outlines or ground; the vertex budget) and five hand-built, rendered examples (airliner for long vehicles, house for buildings, Ferris wheel for wheels and rings, jet-engine cutaway for mechanisms, kettle for everyday objects). `guide_for(task)` picks the nearest family by keyword and adds the recipe and that one example to the turn's rules only when the figure setting is on and the message looks like a request to draw; otherwise nothing, so ordinary turns pay nothing. The example is told to teach technique, never to be copied. `CHILLY_FIGURE_GUIDE=0` turns it off (the eval's baseline).
- **Why:** a small model copies an example more faithfully than it follows a rule, and the prompt had one (a lamp). Two live rounds on Haiku 5.5 showed the nearest-family example fixed the flat bicycle wheels and the junk guitar without any bicycle or guitar in the prompt.
- **Alternatives:** one bigger example in the always-on rule (breaks the 2,900-character cap and the "not an airliner" pin, and costs every turn); examples for every request type (token cost, and the eval then measures copying); a repair pass by a second model call (not built; still open); switching model (the user chose not to).
- **Risks / open:** a family keyword can pick a poor neighbour (a rocket gets the airliner); wind turbine and piston asks were declined in all four runs by the prompt's toss-up rule, a separate decision; the REPL path has no task text, so only `--serve` and the one-shot run get the guide; two rounds of eight is a small sample.
- **Status:** built; selftest passes; Swift suite passes (949, run before this change; no Swift changed by it). Not committed, not built into the app, not live-verified in the app. **[Reconciled 2026-11-09: in `companion-ui` (`f6324d9`). Any "not seen live" wording here still stands.]**

**Update (same day):** a tie between families goes to the longer matched word ("jet engine" is an engine). Not done, because not 90% sure of a gain: loosening the draw-or-not rule for wind turbine and piston asks, a repair pass for parts dropped past the vertex budget, and per-turn rules for the terminal loop.

### D-150 · Raise the Anthropic reply limit from 4,096 to 8,192 tokens, so a rich figure is not cut off (done by Claude at the user's request to consider more headroom; unit-tested, live check pending)
- **What:** `chilly/providers.py` sends `max_tokens` 8,192 (`ANTHROPIC_MAX_TOKENS`), as the OpenAI-format provider already did.
- **Why:** in the guided Haiku 5.5 eval one microscope reply used exactly 4,096 output tokens and ended inside the figure block, so nothing drew; two more guided replies used 3,934 and 3,816. The richer figures the examples ask for need 3,000-4,000 tokens of JSON, and thinking counts toward the same limit. This, not the 120,000-vertex render budget (the largest figure in the eval was 36,455), is what capped figure detail.
- **Alternatives:** raising the vertex budget (no figure reached it; it is a frame-time limit); moving the guide into a cached block (see the finding on prompt caching).
- **Status:** selftest passes. Not live-verified: a limit is only a ceiling, so cost changes only when a reply needs the room.

**Update (2026-11-06), the draw-decision wording:** the figure rule's examples now read "what's inside a lock" and "what does a wind turbine look like" (2,854 of 2,900 characters). Live Haiku 5.5, eight things the prompt never mentions, twice, with the examples and the 8,192 limit: 15 of 16 drew a figure that parses (before: 11 of 16 over two earlier guided rounds). Wind turbine 2 of 2 (was 0 of 4), piston 1 of 2 (was 0 of 4), the other six 12 of 12. The piston cutaway is passable, not good: its labels sit on a casing, not the parts inside. One piston reply still offered a model instead of drawing one. The largest reply used 4,683 output tokens, so no reply was near the limit.

### D-151 · A private note the model keeps for the conversation (`keep_note`), so a game with a hidden answer survives between turns (done by Claude at the user's request; unit-tested, live check pending)
- **What:** the engine offers one in-memory tool, `keep_note(text)` (800 characters). The note is held by the turn and becomes the conversation's when the turn commits (a cancelled turn leaves it as it was). Every later turn's rules end with a short "A private note" section holding it, and a new conversation (`reset`) clears it. It is never shown, spoken or logged: no activity line, and the audit log still holds ids and codes only. The terminal loop does not offer it.
- **Why:** the hangman screenshots. The model chose the word in hidden reasoning, which is not kept; the next turn invented a new pattern, then admitted it. Keeping the state in a tool beats a hidden tag in the answer: no stripping from the panel, speech and drawing code in two languages, and it survives the talk-over cut-off that replaces an answer with what was heard (D-122) and history trimming.
- **Alternatives:** a hidden tag in the answer (more code, loses the state on a cut-off); asking the model to restate the word in the visible reply (gives the game away).
- **Status:** selftest passes. Live-checked on Haiku 5.5 with only `keep_note` enabled, four turns of hangman: it called the tool every turn and the word stayed fixed to the end (PLANET, then ORANGE and ROCKET in earlier tries). Two wording fixes came out of it: the tool's result says to write the reply now, and the rule says to call it before writing any reply (a reply written before the call was thrown away as text before a tool call, leaving an empty answer). Still wrong at times: the model places letters in the wrong position on the board (A in position 2, not 3), a plain Haiku slip the note cannot fix.
**Update (2026-11-06, after the user's first test in the app), D-151 and the spoken rule:** in the user's live hangman game the note kept LANTERN, but the model said T was not in it; asked "what was the word?" it refused because the game wasn't over; and "the letter T" was heard as "there are tea". The note rule now says to spell the word out with numbered places and check each guess against that list, never to hint at a letter not yet guessed, and that asking for the answer ends the game. The spoken rule now says to judge a mishearing against the conversation too ("there are tea" in a letter game is T; "a winter vine" after 3D models is likely a wind turbine) and to say what it took the words as. Live on Haiku 5.5, five spoken games (three before the no-hint line, two after): every letter claim right, "there are tea" read as T each time, the word revealed when asked; two of the first three named the missing letter, none of the last two did.

### D-152 · Words the conversation held back over another app's sound are kept in the box, not dropped (done by Claude at the user's request; unit-tested)
- **What:** when the menu's "Hold Back Words Heard Over Other Apps' Sound" holds an utterance back, the words now go into the input box (added to what is there) and the note says so ("press Return to send them"). Before, the live text showed, then vanished with a one-line note that also faded.
- **Why:** the user's report that what they said "shows for a bit, but is removed, and Chilly does not act". The voice log shows the setting is on (`holdBackOverOtherAppAudio` = 1) and 22 held-back utterances since 2026-10-31, the latest at 00:17 on 2026-11-06 right after "another app is playing out loud". The check counts any other process with audio output running, loud or not.
- **Not done:** the check itself is unchanged (it cannot tell a silent stream from sound without capturing audio); turning the menu item off is the other fix.

### D-153 · A same-account route for the demo: Chilly starts empty and the screen is kept clean, with no permission changes (the user's choice; built by Claude, tested on a scratch home)
- **When / who:** 2026-11-06 · the user said they will record the demo in their own account, without exposing anything and without changing permissions on files and folders.
- **What:** `demo/same-account.md` (what could leak in your own account, and what covers each), `demo/profile.sh aside|back` (moves everything in `~/chilly` except the on-device voice into `~/chilly-before-demo` and back; the demo's own files go to `~/chilly-demo-run-<time>`; refuses while Chilly runs or if a folder is already there; moves only), and `seed.sh --same-account` (drops only the administrator check). The run sheet's browser step is skipped on this route.
- **Why:** in one account Chilly's memory and recent conversation titles are part of every prompt and the panel lists them, so the model could say the user's name or past topics aloud; a fresh profile removes that without touching permissions. What remains is the screen (the screenshot sent each turn) and the cards, which the guide covers.
- **Weaker than D-148's separate account, said plainly in the guide:** nothing stops a read the user approves by mistake; the gate still refuses private places and asks for anything outside Chilly's folder.
- **Status:** `selftest_oss.py` runs `profile.sh` on a scratch home (aside, a refused second aside, back, refused while running). Not run on the real `~/chilly`; that is the user's step.

### D-160 · RealityKit was built and compared with SceneKit on the same figures: no visible gain, so the card stays on SceneKit and the effort goes to geometry (proposed by Claude after the user asked to go ahead with RealityKit)
- **When / who:** 2026-11-07 · the user asked to move the 3D figures to RealityKit, expecting a significant visual improvement; built and measured by Claude (Opus 5.5).
- **What was built:** `companion/Sources/ChillyApp/FigureReality.swift`, a RealityKit renderer (macOS 15+, `RealityRenderer`) that draws the same parts from the same prepared figure, with the same materials, studio light, key and rim lights, shadows, ink outline (inverted hull on the CPU), cut (triangles clipped on the CPU) and ground; `FigureScene` stays the logic (reveal, camera, framing, labels), so both renderers draw exactly the same picture. `tools/figure-render` gained `FIGURE_RENDER_COMPARE=1`, which writes SceneKit and RealityKit side by side for each figure and two more views. Not wired into the live card.
- **Result (five figures, three views each, by eye):** the two are nearly identical; labels and framing match to the pixel. SceneKit is slightly richer today: screen-space ambient occlusion, bloom and the key light's shadow on the ground, which RealityKit's offscreen path here does not offer (its grounding shadows did not show on the unlit ground). RealityKit's scene build was slower on the first figure (520 ms cold, 30–70 ms warm). Sheet: `(not in this export)`.
- **Why the picture did not change:** both are physically based renderers with image-based light and shadows; the figures look the way they do because of their geometry (primitives the model places), not the renderer.
- **Proposal:** keep SceneKit for the card; keep `FigureReality.swift` and the compare mode as the migration path when Apple's deprecation forces it; put the 3D effort into D-158 (higher-level parts, a checked example library, repair and the advisor).
- **Alternatives:** wire RealityKit into the card anyway (a CAMetalLayer view and a display link, macOS 15+ only with SceneKit kept for 14; no visible gain for the user today); delete the prototype (loses a working migration path).
- **Status:** proposed; the user's call.

### D-161 · Languages: Apple's frameworks only, global coverage, a language is offered only when both hearing and voice pass a quality bar; no Urdu-specific route (supersedes D-156's Urdu and cloud parts; the user's direction)
- **When / who:** 2026-11-07 · the user: no Urdu-specific or niche integrations; global coverage through what is widely integrated; Apple's frameworks if they help, but the quality must be very good, at least Kokoro's for English.
- **What:** hearing through SpeechAnalyzer (`SpeechTranscriber`, 30 locales, Apple's newer model; `DictationTranscriber`, 54 locales, as a second tier), models downloaded per language with the user's yes; replies in the language spoken; English keeps Kokoro. **Quality gates, checked in code or by a test before a language is offered:** speaking needs an Apple enhanced or premium voice installed for that language (on this Mac only compact voices are installed, in 49 languages, and those are below Kokoro, so the app offers the free download in System Settings instead of speaking with them); hearing is measured per language by a loopback test (an Apple voice reads fixed sentences into a file, each transcriber reads it back, word error rate) and then by the user's own speech.
- **Status:** proposed. The loopback test is written (`scratchpad/lang/loop.swift`, not kept) and not run: it would raise the Speech Recognition permission prompt for the test process, and non-English models need a download; both wait for the user's yes.

### D-163 · Where figure detail must come from (open; the user's call)
- **When / who:** 2026-11-07 · the user found the new figures basic; options laid out by Claude.
- **Options:** (A) detailed preset components generated in code (a mitochondrion with folded cristae, a wheel with tread and spokes, a gear with real teeth, a twisted propeller, a tree with branches and leaf clusters), the model placing them by name; (B) surface detail through materials: procedural bump and normal maps (pores, ribs, tread, panel lines), translucent membranes, rim light, gradients; (C) real CC0 models (Poly Haven, Kenney, Smithsonian) loaded with GLTFKit2, for common objects only, with named parts added by hand; (D) a stronger model for figure turns (Sonnet 5.5 or the advisor) for more parts and better proportions, still primitive-based; (E) text-to-3D (TRELLIS.2 and others), not now: NVIDIA GPUs or non-commercial dependencies on the Mac, and unlabelled meshes.
- **Claude's recommendation:** A with B, proven on two figures (the cell and a car) before more.
- **Status:** open.

### D-164 · Haiku 5.5 by default, Sonnet 5.5 only where checks show it is needed, and never on the path to the first spoken word; a speed budget measured per turn (proposed; the user agreed to the model plan and asked that it stay fast)
- **When / who:** 2026-11-07 · the user: stay on Haiku 5.5, engage Sonnet 5.5 where it is really worth it, and response time matters a lot.
- **Measured (`~/chilly/latency.jsonl`, 238 spoken turns, timings only):** with a screenshot (229 turns, the default) the first text arrives after a median 3.1 s (p90 8.1 s) and the first audio after 5.0 s (p90 12.8 s); without one, 1.3 s and 3.0 s. Cause found in code: `speaksWhileStreaming = shot == nil` (`CompanionModel.swift`), so screen turns wait for the whole answer before speaking. Kokoro takes a median 0.8 s from the first sentence to the first audio.
- **What, in order of expected gain:** (1) speak screen answers as they stream, with the marks joining their sentence when their tags arrive; (2) no thinking on spoken answers (Haiku 5.5 accepts thinking off at effort high or below), thinking kept for figures, plans and repairs; (3) Kokoro on the Neural Engine (FluidAudio, Apache-2.0; its own figure is 36–54 ms for 3.5 s of audio, unmeasured here); (4) the cache and connection warmed when the talk key goes down (a request with `max_tokens` 0); (5) escalation off the voice path: the answer is spoken first, a figure or plan is checked and repaired after, Sonnet 5.5 (advisor) only on a second failure, under a time cap, the panel saying it is refining.
- **Budget (to measure, not yet met):** first word heard ≤ 1.5 s median, ≤ 3 s p90 after the key is let go; first figure part ≤ 3 s; an escalated figure ≤ 10 s or Haiku's version stays. Every escalation logged with its cost and time.
- **Status:** proposed. Items 2 and 3 need a measurement (2 calls the API; the user's yes first).

**Update to D-164 (2026-11-07 ~16:10, the user's "start there"; built by Claude, uncommitted):** item 1 is built. An answer about the screen now speaks its first sentence while the rest is written (`CompanionModel.speaksWhileStreaming` no longer requires no screenshot). Its marks still arrive with the whole answer; the plan carries `spokenFirst` and `cueText`, and the overlay replays the voice's start and every word heard so far into the old-form sequence, each offset mapped from the voice's text into the marks' text by `SpokenAlignment` (white space is the only difference between a streamed answer's spoken text and the answer cleaned whole). Marks whose words were already said show at once; the rest keep their time on the voice. The beats form already replayed what was heard. Off switch: `defaults write com.chilly.app speakScreenAnswersEarly -bool NO`. Unit-tested (6 Core, 2 through the real `CompanionModel`); not run in the app, so the real voice and the marks together are unseen.

### D-165 · Drawing turns go to Sonnet 5.5 at low effort; everything else stays on Haiku 5.5 (proposed, from a live eval the user funded)
- **When / who:** 2026-11-07 · the user called a live Haiku figure of the Tesla Roadster "pathetic" (a box on a box) and allowed $16 of API credit to make things better; eval run by Claude.
- **What was done first:** a `car` example family (a 14-part sports car: a chained blob body, a glass blob cabin, mirrored and copied wheels with spinning rims and spokes) and a placement fix (a ring is copied with its part, so spokes copied to the rear wheel circle the rear hub; spin lines follow), both tested.
- **Eval (`(not in this export) --set push`, 8 cases: Roadster, sports car, heart inside, cell, motorcycle, drone, dolphin, espresso machine; typed, no screen, no tools; renders in `(not in this export)`):** Haiku 5.5 low $0.0021 a figure, median 14.1 s; Haiku 5.5 medium $0.0023, 15.5 s, one figure missing; **Sonnet 5.5 low $0.025, median 7.0 s**; Opus 5.5 low $0.052, 12.4 s. By eye: with the car example every model draws a smooth Roadster; Sonnet is the most consistent (no box bodies, the best dolphin and motorcycle); Opus is no better than Sonnet. Haiku writes about twice the output tokens for the same figure, which is why it is slower. Total spent: $0.65.
- **Proposal:** a turn the engine already classes as a drawing turn (the figure guide's trigger, `figure_examples.guide_for`) is sent to Sonnet 5.5 at low effort; the answer joins the conversation as usual and the next turn is Haiku again. About 2.5 cents per figure, faster than today. Off switch and model by setting.
- **Risks / open:** caches are per model (the drawing turn reads none of Haiku's cache; measured cost already includes that); one run per case is a small sample; Sonnet's thinking blocks are not carried back to Haiku (only text is kept in history).
- **Status:** proposed; the user's call.

### D-166 · Figure studio look: a dark studio to reflect, car paint, tinted glass, flat cut faces (built, uncommitted)
- **When / who:** 2026-11-07 ~18:50 PKT · the user ("Yes, renderer first") after calling even Opus's figures unrealistic; built by Claude.
- **What:** in `FigureStage.swift` only (SceneKit; no format or prompt change, no per-answer cost): (1) the reflection environment is a dark studio drawn once (1024×512: an overhead soft box, two long strip lights, two tall edge strips, a faint horizon, a dark floor) instead of an evenly lit grey room, at intensity 2.2; (2) `paint:` is base roughness 0.45 under a full clear coat at roughness 0.03; (3) glass is a tinted, mostly reflective blue-grey; (4) a cut part's inside is its own colour in shade, flat, without hatching; (5) the ground plane is twice as wide and fades out before its edge.
- **Why:** an evenly lit room reflects as flat plastic; bright shapes on a dark surround are what make paint, metal and glass read as real. The hatching drew rings on curved walls (the heart, the cell) that read as contour lines. Before/after: `(not in this export)`.
- **Result, honestly:** a modest step. Steel and car paint read as polished, glass as glass, cut walls as walls; the figures are still simple shapes, so they still look like models, not photos. The renders confirm the shapes are the bigger limit (D-165's eval and the "loft" idea).
- **Alternatives:** RealityKit (`FigureReality.swift`, dormant; no better by itself); real 3D assets or text-to-3D (realistic, but downloads, licences, cost, and no named parts to label or cut); a downloaded HDRI (licences and size; drawn in code instead).
- **Status:** built, 81/81 figure tests; not built into the app, not seen live, not committed. The dormant RealityKit renderer reads the same `FigureMaterials.environment`, so it gets the new studio too; not checked there. **[Reconciled 2026-11-09: in `companion-ui` (`468fa50`). Any "not seen live" wording here still stands.]**

### D-167 · Lofts: smooth bodies from cross-sections (built, uncommitted)
- **When / who:** 2026-11-07 ~19:35 PKT · the user ("Yes, add lofts") after D-166 showed the shapes, not the renderer, were the bigger limit; built by Claude.
- **What:** a figure part `{"kind":"loft","sections":[[z,y,w,h,square],...]}`: 2-24 cross-sections along the part's z, each centred at height y with half-width w and half-height h, its outline a superellipse from an oval (square 0) to a rounded box (square 1). The skin follows a Catmull-Rom curve through the sections (z kept straight so rings never fold), 6 rings a span, 48 round; open ends get flat caps, a 0-size section is a point. Written back to front it is reversed; z that goes back on itself, no section with both width and height, a single section, or negative sizes drop the part. Budget `((n-1)·6+1)·49 + 2·50`, the same in both parsers. Taught in the figure rule's kinds line and the recipe ("A streamlined body ... is a loft"); the car example's body and cabin are lofts. The ground glow now fades to clear, not black.
- **Why:** a car, a hull, a fuselage or a fish is a smooth shape whose profile changes along its length; balls (blob) make it lumpy and boxes make it a toy. Sections are numbers a model writes easily: where it is, how wide, how tall.
- **Eval (push set, typed, no screen; ~$0.20):** both models used lofts for the Roadster, the sports car and the dolphin unprompted by name. By eye the cars from both read as real sports cars, Haiku's as good as Sonnet's; the dolphins are smooth instead of lumpy. Haiku 5.5 low $0.0018 a figure, median 11.4 s; Sonnet 5.5 low ~$0.023, 7.4 s. 16/16 parsed. Grid: `(not in this export)`.
- **Alternatives:** subdivision surfaces (smoother joins, but a mesh to write); booleans for wheel arches (not in the grammar; parts only add); more blob balls (still lumpy).
- **Status:** built and tested (974/974 Swift, selftest, shared cases); not built into the app, not seen live, not committed. **[Reconciled 2026-11-09: in `companion-ui` (`468fa50`). Any "not seen live" wording here still stands.]**

**Update to D-165 (2026-11-07 ~19:35, Claude's advice after D-167's eval):** with lofts, Haiku's cars are as good as Sonnet's by eye, so the main reason to send drawing turns to Sonnet (quality) is gone for vehicles. What's left is speed: Sonnet 7.4 s against Haiku 11.4 s, at about 12 times the cost. Advice: stay on Haiku for drawing turns for now; D-165 stays proposed, not recommended.

### D-168 · Marks on Chilly's own picture add to it (built, uncommitted)
- **When / who:** 2026-11-07 ~20:15 PKT · the user ("Chilly does not work on something that it sees on the screen already... the text was gone by then"); built by Claude.
- **What:** a reply's new marks keep the picture already up, as edits do, when none of them draws (no path, line, shape, oval or words) and every one lands on a part of that picture still up (within 6 pt; the board offset counts too). Otherwise the D-129 rule stands: a new picture or marks elsewhere replace it. Highlights on plain pointer marks still replace them. The canvas rule now says marks that land on the drawing are added and it stays, so the model never redraws to mark up.
- **Why:** "highlight those lines" means the lines stay; the model wrote no `[EDIT:all:keep]`, so the highlights erased the words they marked, and the next turn's canvas showed only highlights, so the model redrew the text (and lost the highlights). Doing it in code makes it hold whatever the model writes.
- **Alternatives:** the prompt alone (it already offered `[EDIT:all:keep]`, unused here); keep every drawing until erased (clutters the screen with old pictures); keep on any overlap with any mark (highlights would pile up during ordinary pointing).
- **Status:** built and unit-tested (4 tests; 978/978 Swift, selftest); in the 20:19 build; not seen live; not committed. **[Reconciled 2026-11-09: in `companion-ui` (`468fa50`). Any "not seen live" wording here still stands.]**

### D-169 · The eval harness, v1: recorded turns as fixtures, code checks first, a split rubric by a different model, human labels to measure it (built, uncommitted; carries out D-155's first step)
- **When / who:** 2026-11-07 ~21:10–21:40 PKT · the user ("Start eval harness", after Claude recommended it as the next step because every later quality and speed change needs a measure); built by Claude (Opus 5.5).
- **What:** `evals/` (`fixtures.py`, `checks.py`, `rubrics.py`, `harness.py`, `import_legacy.py`, README) and `tools/eval.py`. One JSON fixture per recorded turn (request, reply, expectation, baseline verdict, optional human answers). Commands: `check` (offline replay through code checks; exit 1 on drift from the baseline), `rebaseline`, `record` (`--plan`, `--fake` localhost model, `--live`) through the real engine as the app runs it (figures, cards, streaming on), `compare` (two sets matched by question, pass rate, estimated cost per passing turn), `judge` (one yes/no question per call, never the reply's own model: Sonnet 5.5 judges Haiku, Opus 5.5 judges Sonnet; `--batch-out` writes Message Batches requests without sending), `label` and `agree` (Cohen's kappa against a person's answers), `capture` (one of the user's own turns from `answers.jsonl`, named by run id, into `evals/fixtures/private/`, left out of git and the export).
- **First fixtures (43):** the real model's replies already recorded by the feature evals: 10 card and 11 beats turns (Haiku 5.5 low, D-125, D-127), 11 figures each by Haiku 5.5 low and Sonnet 5.5 low (D-108 core and wide). Typed questions and synthetic screens only; none of the user's own turns.
- **Why this shape:** code checks are exact and free, so they come first; the judge only answers what code can't, one criterion per call against the halo effect, and never grades its own model (self-preference bias); a human-labelled set is the only way to know whether the judge can be trusted. Reusing the feature evals' rules (moved into one module) means the harness scores what was already agreed.
- **Alternatives:** promptfoo or Inspect AI (another dependency and runtime for 43 fixtures, and Chilly's checks need its own parsers anyway); a single 1–10 judge score (hides which criterion failed and can't be compared with a person); recording fixtures from the answer log automatically (the user's words and screens: private, and the log has no request text).
- **Export policy change (the owner's file):** `docs/tools/behaviour_eval/run.py` and `screens.swift` kept in the public export (`record` needs the engine driver); `(not in this export)` left out (it reads `docs/impl-notes`); `evals/fixtures/private/` and `evals/runs/` left out and allowed to be named.
- **Status:** built; unit-tested (32 selftest checks); no paid call made. Next: the user labels some fixtures (`tools/eval.py label`), then one paid judge run (~161 calls, ~35K input tokens) to measure agreement; then a `record --live` baseline before D-164 item 2 (thinking off) and D-158's repair loop.

**Update to D-169 (2026-11-07 ~21:45–22:05, the user's "Run the judge"):** the first paid judge run, `evals/runs/judge-20261107-first.json` (local, not in git): 161 calls (117 Sonnet 5.5 for Haiku's replies, 44 Opus 5.5 for Sonnet's), all ending in a readable verdict; 54,256 input and 28,704 output tokens, about $0.50 by list price (estimated by Claude, more than the ~$0.20 quoted: the judges wrote ~180 tokens of reasons each, not one line). **What it found that code can't:** figures' words describe the drawing instead of the subject in 6 of 22 (house, mug, bicycle and guitar from Sonnet: "seen from the side…"), and the labels miss a part a learner wants in 7 of 22 (bicycle without wheels, rocket without fins, microscope without the focus knob). Cards and beats: 1 NO each on fit and card value (a list card for cloud kinds; the bare three-states turn, which the code check also fails). **Two flaws in the harness, fixed (selftest, no new run):** the beats view hid the marks the engine drew, so the underline turn was judged as not underlining; and the judge marked screen turns dishonest because it can't see the screenshot (3 NOs). The system line now says screen claims don't count and marks listed are done, and asks for two sentences at most. **Not known yet:** whether the judge agrees with a person; no fixture has human labels.

### D-154 · Web search with a Claude model goes to Anthropic's own search tool (the user's choice; built, unit-tested, one live run)
- **When / who:** 2026-11-06 · the user's test showed every web search failing; offered a key of their own or Anthropic's search, they chose Anthropic's. Built by Claude.
- **What:** for the Claude provider, the `web_search` tool is sent as Anthropic's server tool `web_search_20250305` (the basic version every current model takes, called directly) with `max_uses` 3. The provider reads `server_tool_use` / `web_search_tool_result` blocks into a `searches` list (query, hosts, error code), keeps as the answer only the text after the last search (what came before is narration, and when streamed it is taken back with the existing delta reset), resumes a `pause_turn` up to three times by sending the paused content back, and keeps citations when it has to resend. The agent shows each search as a `web_search` step, logs it in the audit log like the engine's own, taints the turn as "a web page" and adds the hosts to those `web_fetch` may read unasked. `CHILLY_WEB_SEARCH=local` restores the engine's own search; other providers are unchanged. Search blocks are not kept in the conversation history (only the answer text is), so later turns don't pay for the results again.
- **Why:** with no Brave or SerpAPI key the engine scraped DuckDuckGo, which now answers automated requests with a bot challenge, so search failed every time and only the audit log showed it. Anthropic's search needs no new key and no new provider.
- **Cost:** $10 per 1,000 searches plus the results as input tokens; on Haiku 5.5 about 1 to 2 cents for a searched turn, at most 3 cents of search fees a request; turns without a search cost nothing more.
- **Alternatives:** a Brave Search key in `~/.chilly.env` (the user's to add); the dynamic-filtering version `web_search_20260209` (not for Haiku 5.5, and it runs code execution).
- **Status:** selftest covers the payload, the result parsing, the narration, `pause_turn`, streaming and the agent's taint. One live turn through the real engine on Haiku 5.5: one search, a `web` activity line, a dated answer with its source, one model call. Not yet used from the app.

### D-155 · Build the eval harness before the next quality work: recorded fixtures, code checks first, a split rubric, nightly on the Batch API (proposed)
- **When / who:** 2026-11-07 · proposed by Claude (Opus 5.5) in `(not in this export)` after the user asked how to give Haiku 5.5 "superpowers" with tooling; not yet accepted.
- **What:** fixtures recorded from real turns (figures, cards, walkthrough steps, languages), replayed offline with code checks (parse, geometry, label anchors, bounds), then a rubric split into criteria and judged by a different model; a nightly paid run on the Message Batches API (50% off) only with the user's yes.
- **Why:** every other change in the plan is a bet on evidence from other models; the existing evals are small and judged by eye (10/11, 22/33, 15/16).
- **Alternatives:** keep hand-run evals per feature (cheap, but no regression guard); adopt promptfoo or Inspect AI wholesale (MIT; a dependency outside the zero-dependency engine, fine for a `tools/` script).
- **Status:** proposed. **[Reconciled 2026-11-09: Step 1 built as D-169.]**

### D-157 · A walkthrough mode that keeps track of every step: Chilly points, the user clicks, a step ends only on visible evidence (proposed)
- **When / who:** 2026-11-07 · proposed by Claude; the review video's most praised moment; not yet accepted.
- **What:** a step plan with the evidence for each step; pointer grounded by Accessibility, then Apple Vision text boxes, then model coordinates; the user's click seen by a listen-only event tap, panels by Accessibility focus notifications, screen changes by ScreenCaptureKit frame info; step cap, loop breaker, re-plan; "Step n of m" with Back, Skip, Stop. App help text searched with SQLite FTS5.
- **Why:** it needs no new authority (Chilly does not click), and it is the one capability in the video Chilly lacks entirely.
- **Risks / open:** CapCut-style editors may expose little to Accessibility (undocumented; a ten-minute Accessibility Inspector look by the user decides).
- **Status:** proposed.

### D-158 · Figures from parts, examples and checks: higher-level parts in code, a retrieved library, plan-first schemas, repair once, then the advisor (proposed)
- **When / who:** 2026-11-07 · proposed by Claude; not yet accepted.
- **What:** code-side parts the model parameterises (organic blob by smooth union, scatter, sweep, array, lathe templates, spin and flow motion); 30 to 50 checked figures retrieved per message after the cache breakpoint; a `plan` field before geometry in a strict schema; code metrics on each figure; one repair with the exact error, then the advisor tool (Haiku 5.5 executor, Sonnet 5.5 advisor) or a higher per-message effort on a second failure.
- **Why:** organic and complex objects are the weakest figures (D-149 open); research favours retrieval plus code-checked repair over self-critique.
- **Alternatives:** switch the default to Sonnet 5.5 (the user chose not to, D-117); text-to-3D models (dense meshes with no named parts; licences mixed; Mac ports pull non-commercial dependencies); a curated CC0 model pack (kept as an option).
- **Status:** proposed.

### D-159 · Open-source shape: contributions as data packs with tests, and a dependency licence rule (proposed)
- **When / who:** 2026-11-07 · proposed by Claude; not yet accepted.
- **What:** figure examples, parts, app guides, voices and languages, providers and evals as packs, each with its own check in CI. The default build takes only MIT, BSD, Apache-2.0, MPL (file-level) and CC0; GPL, AGPL, non-commercial, research-only and territory-limited licences never ship inside the app.
- **Why:** the user wants people to "take this thing up and do wonders"; packs let them add knowledge without touching the engine or the gate.
- **Status:** proposed.

### D-174 · No Gemini voice stack: the Claude API stays the default brain, and any model can be plugged in through providers (the user's direction, 2026-11-08)
- **When / who:** 2026-11-08 · the user, after the round-9 list: "I'd like to stick with claude api instead of gemini", then "the provisions should be to use any model as such".
- **What:** (1) The other product's Gemini ears and mouth are **not** adopted; D-140's open voice item is closed as declined. Hearing and speaking stay on device: Apple's speech frameworks for hearing (D-161) and Kokoro/Apple voices for speaking. (2) The **brain** is chosen by provider, not hard-wired: Claude (Anthropic Messages API) is the default; OpenAI-format providers (OpenAI, DeepSeek, GLM, Kimi, Qwen, Ollama, LM Studio) are presets of one provider class (D-147). (3) Rule for every new feature: it must work, or degrade without an error, on a provider that lacks the Claude-only pieces. Today those are Anthropic's own web search (the engine's local search is the fallback, `CHILLY_WEB_SEARCH=local`), prompt caching and `output_config.effort` (never sent to other providers). (4) A hearing or speaking engine added later goes behind the same kind of seam as the brain (a small protocol with a local default), so no vendor is required.
- **Why:** one key to manage and a privacy story that does not add a second cloud service; the user wants the freedom to swap models, not a second default vendor.
- **Alternatives:** Gemini Live for hearing and a Gemini speech model for speaking (declined: a second vendor and key, audio leaves the Mac); Claude only (declined: D-147 already opened the door and the user wants it kept open).
- **Status:** accepted by the user 2026-11-08. No code change in this entry. Follow-up done 2026-11-08: `selftest_anyprovider.py` (46 checks, run from `selftest.py`) puts the full tool set (screen, drive, jobs, schedules, browser, active tab, notes: 36 tools) through the strict fake servers of six OpenAI-format providers, runs web search as the engine's own tool (no Anthropic server tool), shows a declined drive never starts whichever model asked, and a content-filter stop is told plainly. It found no gap; a planted bad tool name is caught by 6 checks. Still not tried: a real non-Claude model in the real app.


### D-175 · One hidden folder, `~/.chilly`, for everything Chilly writes, with a one-time move from `~/chilly` (the owner's direction; built, unit-tested, not live-verified)
- **When / who:** 2026-11-08 ~08:00–09:50 PKT · the owner, through the orchestrating session: Chilly should behave like Claude and Codex, which keep one hidden folder in the home folder (`~/(not in this export)`, `~/.codex`), not loose folders; privacy and security first, and no script or test may touch anything outside the Chilly-named folders. Built by the side session `chilly-home` (Claude Sonnet 5.5, worktree `chilly-home-65eb32` from `1012d5d`).
- **What:** (1) **One home, `~/.chilly/`** (created mode 0700): jobs, logs (`engine.log`, `events.jsonl`, `voice.log`, `latency.jsonl`), `answers.jsonl`, `policy.json`, schedules, memory, conversations, notes, skills, the on-device voice (`voice-venv`, `voices`), demo runs (`demo/`) and the export tool's default output (`exports/chilly-<sha>-<time>`). **Left where they are, on purpose:** `~/Library/Application Support/Chilly/Browser/link.json` (D-143: its own private place, kept out of the working folder so a file tool never reaches the token) and the key file `~/.chilly.env` (a separate follow-up: moving keys is its own change, and D-173 already offers the Keychain). (2) **One override:** `CHILLY_WORKDIR` (or `--workdir`) stays the only switch, with one meaning in the engine and the app. The app now resolves the folder in one place (`WorkingFolder.url()`) for every file it reads or writes, and passes it to the engine it starts (`CHILLY_WORKDIR=<that folder>`); before this, the app's memory and conversations ignored the override and used the default folder. Tests, the demo kit and the export tool point at a scratch folder with it. (3) **One-time move:** if `~/chilly` exists and `~/.chilly` does not, one atomic `rename` (same parent, so the same volume); if the rename is impossible, the engine copies to a temporary sibling, checks every path and size against the original, renames the copy into place and keeps the old folder (never deleted); the app, which cannot copy, keeps using `~/chilly` for that run and says so. Never overwrites or merges into an existing `~/.chilly`: if both exist, `~/.chilly` is used, nothing moves, and one plain line says "An old ~/chilly folder is still there; Chilly no longer uses it." once. Nothing happens when `CHILLY_WORKDIR` is set. A marker `~/.chilly/migrated_from` holds the kind and the date and nothing else; the audit log gets one `home_moved` event by kind only. The older `~/pal` moves the same way when there is no `~/chilly`. A `~/chilly` that is a link to a folder has the link renamed (its target untouched). No other name is ever looked at: look-alike folders, `~/.chilly.env`, `~/.ssh` and the browser link folder are tested to be untouched. (4) **Reach it without a visible folder:** Settings › "Show Chilly's folder" opens `~/.chilly` in Finder; a job's details have "Show in Finder" for that job's folder (`report.md`, `output/`). The one-line notice of the move shows on the status line at the launch that moved it, and in Settings under the button. Every user-facing string that said `~/chilly` says `~/.chilly`. (5) **The gate follows:** `~/.chilly` is the working folder, so a turn reads and lists inside it freely and writes new files there, an overwrite asks, and a job (whose working folder is its own `jobs/<id>/`) is asked before it reads or writes anywhere else in `~/.chilly` (`answers.jsonl`, `policy.json`, `events.jsonl`, `memory.jsonl`, by name, by `..` or through a symlink): exactly as for `~/chilly` before. **New:** while an old `~/chilly` holds Chilly's files (any of `answers.jsonl`, `policy.json`, `jobs`, `conversations`, logs, `memory.jsonl`, `output`), it is a private place, refused outright (never asked) to the file tools, asked by the shell, and refused to uploads, unless it is the working folder itself (`CHILLY_WORKDIR=~/chilly` still works). A folder called `chilly` that holds none of those (a clone of the code) is not touched by the rule. (6) **Demo kit and export tool:** `demo/profile.sh` no longer moves the real folder; `start` opens Chilly on a scratch folder `~/.chilly/demo/run-<time>` through `CHILLY_WORKDIR` (`open --env`) and `finish` only names it; `demo/seed.sh` keeps writing the visible `~/ChillyDemo` and gains `--in-chilly-home` (`~/.chilly/demo/ChillyDemo`, or under `CHILLY_WORKDIR`); the export tool's default is `<CHILLY_WORKDIR or ~/.chilly>/exports/`. The three that would create `~/.chilly` refuse while an old `~/chilly` waits to move.
- **Why:** a visible `~/chilly` plus export, demo and run folders is clutter in the user's home that a viewer of a recording sees; the privacy story is easier to tell when everything is in one private folder; and one resolver removes a real gap (the app's memory ignored `CHILLY_WORKDIR`, which is why the demo kit had to move the real folder).
- **Alternatives:** `~/Library/Application Support/Chilly` (Mac-native and already used for the browser link, but not what the owner asked for and not what Claude and Codex do); a symlink `~/chilly` to `~/.chilly` (keeps the visible entry); leaving the old folder in place and only using `~/.chilly` for new files (splits the data); moving `~/.chilly.env` too (a separate change); a migration in the engine only (the app writes a log line or a conversation before the engine starts, creates an empty `~/.chilly`, and the old folder is stranded: so the app has a Swift twin of the rename, tested against the same case table); copying instead of renaming (slower, and a failed copy risks the data).
- **Amended 2026-11-08 (the owner's additions, ~10:30 PKT):** the move must be complete and must not run under another Chilly. One rename takes the whole folder with every mode (tested on a populated fake `~/chilly`: nested job folders, 0600 and 0700 entries, hidden files, schedule files, links, a small venv, voices; nothing missing, modes and contents identical, same inode, `~/chilly` gone); the copy fallback now also compares modes and link targets. Before the rename a process check refuses while another Chilly engine or app of this user runs with this HOME (kind `busy`, one plain line, the old folder keeps being used for that run). Voice paths all go through the one path function; a moved venv still runs.
- **Status:** built and unit-tested on `claude/chilly-home-65eb32`, not merged, not pushed; **nothing live-verified**. Tests: `selftest_home.py` (the case table, the fallback, the gate's adversarial cases, the export default, a scan for leftover paths) and `HomeMigrationTests.swift` (the same table), all in temporary homes. Not tried live: the move on the real folder, `open --env` in `profile.sh start`, Finder opening a hidden folder, the Settings button and the job button, and the on-device voice after the move (its venv's `pip` scripts keep the old path in their first line; `python3` is a link and works). **[Reconciled 2026-11-09: in `companion-ui` (`aa34b2f`). Any "not seen live" wording here still stands.]**

### D-176 · A figure's words explain the thing, never the model: a rule in the prompt and a free code check (built, unit-tested; not measured on a live model)
- **When / who:** 2026-11-08 ~11:00–11:40 PKT · the user ("See if we still need this fix", then "Yes, add both"); found by the first judge run (D-169 update), checked and built by Claude (Opus 5.5).
- **Still needed?** Read by Claude, not by the judge (the newer evals kept only words and labels, so they can't be judged like for like): in 48 figure replies from 2026-11-07's figure and loft evals, made with that day's prompt and examples, the words talk about the model in about a third, most often on cars and on Haiku 5.5, the default ("I've drawn a sports car as a lit 3D model you can turn around on the board"). Missing labels, the other judge finding, look mostly fixed by the worked examples (only a Haiku medium dolphin with no labels, which the code check already fails), so no labels rule.
- **What:** the figure section says to answer "in a sentence or two about the thing itself, never about the model" (the section's cap raised from 3,000 to 3,050 characters so the rule reaches every figure turn); the drawing recipe adds the full rule (what it is, what its parts do, how it works; never that it was drawn or built, can be turned, which way it faces or which parts are labelled). `evals/checks.py` fails a figure whose words narrate the model (`FIGURE_NARRATION`: "I've drawn/built", "you can turn", "3D model", "in 3D", "labelled", "the model" but not "the Model 3", "seen from the side", "nose to the right", "on the board", "drawn here").
- **Measured (free):** on the 22 judged fixtures the check agrees with the judge on 3 of its 6 words NOs and flags nothing the judge passed; the other 3 (house, mug) list what the picture shows, a judgement left to the judge. On the 48 newer replies it flags 18, none wrongly by Claude's reading. Strict on purpose: one sentence about the model fails a reply that otherwise explains well, as the rule says "never". Three fixtures re-baselined to fail (bicycle, guitar, mug from Sonnet 5.5): replay 37/43.
- **Alternatives:** a labels rule too (not needed on the newer replies); the check as a note rather than a failure (wouldn't measure the rule); the rule in the recipe only (it goes only with messages that look like drawing requests).
- **Status:** built; selftest passes (2,170 checks; 3 new), export check passes. **Not measured:** whether Haiku 5.5 follows the rule. That needs a paid `tools/eval.py record --live --kind figure` (11 questions on Haiku 5.5 low, about 2 cents by Claude's estimate) and a replay; the user's call.

### D-178 · The product is Benji: rename from Chilly, built in an isolated candidate
- **When / who:** 2026-11-08 ~12:15–14:00 PKT · the owner decided the name and the local defaults; Claude (Opus 5.5) built the candidate.
- **What:** Chilly becomes **Benji** ("Hey Benji"): `Benji.app`, `python3 -m benji`, Swift `Benji`/`BenjiCore`/`BenjiApp`, `BENJI_*`, `~/.benji`, `~/.benji.env`, `xyz.heybenji.app`, Keychain service `xyz.heybenji.app.keys`, native host `xyz.heybenji.browser`, `~/Library/Application Support/Benji/Browser`. Intended domain heybenji.xyz, **not registered**. Data moves once by one atomic rename from `~/.chilly`, `~/chilly` or `~/pal`; settings are copied; `CHILLY_*`, `PAL_*` and the older key files stay readable; Keychain mode fails closed under every name; old Keychain items are read through and copied forward; browser hosts are re-registered and proven before the old one goes. The extension id and the signing certificate are unchanged. Sentinels became `BENJI-APPROVE` and `BENJI-EVENT` on both sides. Full reference: `docs/benji-rename.md`.
- **Why:** the owner's decision. A film character inspired the name; all copy and assets stay original with no implied link.
- **Alternatives:** a visible-only rename keeping `com.chilly.app` and `~/.chilly` (rejected: permanent inconsistency, and now is the cheapest moment); a `chilly` package shim for the old app (rejected: an old app can't speak the new sentinels, so it would fail in a worse way than a plain missing module).
- **Status:** Built and offline-tested in the detached worktree `(not in this export)`, **not applied**. Blocked on overlap with the owner's uncommitted work in the main checkout and the active `claude/chilly-durable-1` worktree. The `xyz.heybenji.*` identifiers need the owner's confirmation before the first real launch. **[Reconciled 2026-11-09: in `companion-ui` (`831b5aa`). Any "not seen live" wording here still stands.]**

### D-179 · Technical identifiers under emerssive.com, and the key file is renamed
- **When / who:** 2026-11-08 ~14:00–14:40 PKT · the owner, who holds emerssive.com; Claude advised the order.
- **What:** Replaces the proposed identifiers in D-178: bundle id `com.emerssive.heybenji.app`, Keychain service `com.emerssive.heybenji.app.keys`, native host `com.emerssive.heybenji.browser`. `~/.chilly.env` is now renamed to `~/.benji.env` once at first launch (link then unlink: never overwrites, same file and mode, no second copy of a key; not during a working-folder override or while another copy runs; both stay if `~/.benji.env` exists).
- **Why:** The owner chose the Emerssive namespace, which rests on a domain they hold rather than the unregistered heybenji.xyz, and wanted the key file renamed with nothing lost.
- **Alternatives:** `emerssive.heybenji.*` (rejected: reverse-DNS order would imply a domain under a nonexistent `.emerssive`); `xyz.heybenji.*` (superseded); leaving the old key file in place and reading it as a fallback (the owner chose a real rename).
- **Status:** In the same unapplied candidate as D-178. Tree `6ef70600`. **[Reconciled 2026-11-09: in `companion-ui` (`831b5aa`). Any "not seen live" wording here still stands.]**

### D-181 · Before going public: everything that belongs is merged; two old branches stay out (proposed, owner to confirm)
- **When / who:** 2026-11-09 ~13:15 PKT · the owner: "merge everything so that we could move ahead with the public open-source repository-related changes"; Claude (Opus 5.5) audited every branch and worktree.
- **What:** `companion-ui` (`d68f1ce`) is the line the public export is made from. Local `master` was fast-forwarded to it (`6c6f127..d68f1ce`, not pushed). Two branches with commits of their own were not merged: `chilly-parts` (D-105) and `origin/claude/brave-dijkstra-qlul13` (an October 30 `pal --serve` prototype, replaced by `benji/serve.py`).
- **Why:** `chilly-parts` adds 2D picture tags that D-107 moved away from and rewrites the screen rule on a 193-commit-old base (4 conflicting files). Its one live eval scored 17/27 with a regression whose fix was never re-evaluated, so merging it means an unmeasured prompt change just before release. Neither branch reaches the public tree: the export is one clean commit of `companion-ui`.
- **Alternatives:** resolve and merge `chilly-parts` (needs a paid live eval first); record it as merged with `-s ours` (rejected: the history would claim work that isn't there); take only its shorter screen rule (still wanted per D-105, a separate measured change).
- **Status:** the branches are left in place, nothing deleted. The owner can still ask for `chilly-parts` to be merged.
**Update to D-181 (2026-11-09, the owner):** accepted for `chilly-parts`: not needed now, do not merge, keep it on GitHub. It is already there as `chilly-parts` at `39b498a` in the private repository, so nothing was pushed. Its shorter screen rule stays a possible separate, measured change (D-105). The owner's reason named RealityKit; the app still renders figures with SceneKit (D-160), and the decision holds either way.

### D-183 · New builders get a `Benji Local Signing` certificate; the owner's Mac keeps its existing one; the README drops "Upgrading from Chilly"
- **When / who:** 2026-11-09 ~13:30 PKT · the owner's go-ahead on the two README fixes listed after the export check; built by Claude (Opus 5.5).
- **What:** `companion/build.sh` looks for `Benji Local Signing` first and falls back to `Chilly Local Signing` only when that is the one the Mac has; an explicit `BENJI_SIGN_IDENTITY` still wins. The README, `demo/README.md` and `docs/benji-rename.md` name the new certificate. The README's upgrade section is gone; the CHANGELOG and `docs/benji-rename.md` keep those facts.
- **Why:** an outside reader should never be told to create a certificate named after a product they have not heard of, or read an upgrade path they cannot have. Changing the certificate on the owner's Mac would make macOS ask for every permission again, so that Mac keeps its own.
- **Alternatives:** rename the owner's certificate too (resets every grant, no gain); keep the old name for everyone (the problem above); remove the fallback and set `BENJI_SIGN_IDENTITY` on the owner's Mac (a hidden setting that silently resets grants if it is lost).
- **Status:** unit-tested: selftest 2358 (4 new cases with a fake `security`), old-name check, ServeCheck, public export of the working tree. On the real Mac the selection resolves to `Chilly Local Signing`; `Benji.app` was not rebuilt. Committed on `claude/public-readme-signing`, not pushed.

### D-184 · Pilot REA on one web app and one Android app we own, scored against a sealed answer key (proposed, nothing run)
- **When / who:** 2026-11-09 ~15:30 PKT · the owner: "Yes, plan the pilot", after the stakeholder guide marked REA on web and mobile as untested; plan by Claude (Opus 5.5).
- **What:** `(not in this export)`. A separate session writes an answer key from source; one investigator uses REA on the build, one uses ordinary tools; neither reads the source; a third session scores. Each key has ten answerable questions and three that a build cannot answer. Headless browser with a temporary profile, a test APK, pinned REA 6.8.0, results outside the git repository.
- **Why:** first-hand evidence covers only a desktop app and a browser extension, where ordinary tools did most of the work, so the test has to show what REA adds.
- **Alternatives:** run REA and judge the output by reading it (rejected: no way to measure misses or invented answers); test someone else's app (rejected: no answer key, and the terms question, see `learnings-2026-11-09.md`).
- **Status:** proposed. Waiting on the owner's choice of apps and consent to download the JADX add-on.

### D-185 · A step's card names the app that will really get it, looking through see-through overlays
- **What:** for a click or scroll, the card's app now comes from `ScreenActionGeometry.windowOwner(… hit:)`. When Accessibility finds an app at the point, that app's window was at the point in the screenshot, and only non-normal windows (layer ≠ 0) were in front of it, the card names that app. Otherwise it names the front window as before. The unasked steps' same-app check (`sameApp`) uses the same rule.
- **Who:** Claude (Opus 5.5), on the owner's report of a refused double-click on a desktop folder.
- **Why:** the window list can't tell a click-through overlay from a window. The card said "double-click in Screenshot", the check at click time found the desktop's app, and the step was refused each time as "the app changed", though nothing had. The check itself stays strict: a step only ever acts in the app named on the card.
- **Alternatives:** relax the check at click time (rejected: the user would have approved one app and Benji would act in another); filter overlays by layer (rejected: real menus and popovers are non-zero layers too); a list of known overlay apps (rejected: goes stale).
- **Limits:** a normal window in front in the picture still wins, so a window that closed before the click is still "the app changed". If Benji's own panel covers the point too, Accessibility can't see past it and the step is still refused.
- **Status:** built and unit-tested, uncommitted; not live-verified.

### D-187 · App offers and a notch card: local integrations first, one new size of the notch object (proposed, owner to confirm)
- **What:** Benji notices the front app (`NSWorkspace` activation, no permission) and, after about 30 seconds in an app it has a skill for, offers it on a card: three example tasks, No, Not now, Turn on. At most one offer a day; Not now snoozes a week; No is never for that app; a Settings switch; gated on the quiet check (D-173). Detection stays on the Mac and nothing is sent until the user uses a task. The card is a new size of the one notch object, between Peek and Open, with No on the left and Yes on the right as on approval cards. Approvals stay in Open (D-88).
- **Integrations, in order:** before launch, Notes, Calendar and Mail (skills exist), Reminders, Music, Things, Obsidian and GitHub through `gh` (one skill file each). After the browser has been tested live, Google Docs, Gmail, Notion and Linear through the signed-in tab, with no OAuth. Not doing: Google sign-in or Composio-style connectors.
- **Who:** the owner, 2026-11-09: wants integrations picked for needing little from us, and likes cards around the notch; both before open-sourcing. Layout idea from the reference notes; design, copy and code are Benji's own (D-56).
- **Why:** skills are one file each and carry no accounts or backend. Hosted connectors contradict the roadmap's "no hosted service".
- **Clashes raised with the owner (push-back rule):** a separate strip would be a second surface against "one object"; unasked cards stretch "invisible until called", so only the first time in a supported app counts as a real event, and "I noticed you…" wording stays banned.
- **Alternatives:** a separate wide panel like the reference (rejected above); offers at Peek size only (the owner's option: less room, no three tasks); an MCP client now (rejected for launch: needs safety classes first).
- **Status:** proposed; nothing built. New AppleScript skills need one live try each by the owner.

### D-188 · After launch: the maintainer on camera beside the notch while the real app acts (proposed, build after open-sourcing)
- **What:** short bundled or release-hosted clips with timed cues that fire real app moments: first run (pausing for the user's first request), first approval, first job, key out of credit, and one per release. Skippable, replayable, captioned, muted with the Mac. Plan in `(not in this export)`.
- **Who:** the owner, 2026-11-09: "well-thought-through first, and build once we're done open sourcing".
- **Why:** a person builds trust and a live action proves the claim. Own script and footage (D-56); real screen only (D-182).
- **Alternatives:** no video (D-110, whose hands-on beats stay; this would amend it); streaming (rejected: no hosted backend).
- **Status:** proposed; not started.

### D-189 · Inside a drive, a drag on a native slider or pane divider is quiet; every other drag is still asked
- **What:** this replaces D-186's "always asked" for one case. Inside a drive a drag plans as quiet like a click (low confidence or an outbound word in its label still asks), and the app then looks at both ends. It stays quiet only if all of these hold: the start is an `AXSlider` or `AXSplitter`, in the app Benji looked at and **not in a web page**; the far end is in the same app and inside that slider's frame, or inside the divider's `AXSplitGroup`; no dialog over either end; no outbound word in the control's names or help text; and a slider must have a name that matches what Benji said it is moving. Anything else gets the card as before. A password, card or code field at either end is still refused. Outside a drive a drag is always asked. The consent card now says "scroll, click, type and move sliders".
- **Who:** the owner chose "Quiet sliders in drives" after Claude (Opus 5.5) gave its view, as the D-186 brief asked; built by Claude in the same side session.
- **Why:** a slider or divider can't carry a file, stays in one control, and dragging back undoes it, so a card on each is friction with little protection inside a goal the user already agreed to.
- **Why native only (tighter than what was first proposed):** a web page can make anything report itself as a slider, including a slide-to-pay or a CAPTCHA. The click rules already distrust names a page writes.
- **Why the far end is checked by frame:** a divider's far end is in the pane beside it, so "the same element at both ends" would never be true for one; and a frame needs no element identity to hold between two Accessibility lookups.
- **Alternatives:** keep everything asked (the owner chose otherwise); also quiet trim handles (rejected: on a canvas Accessibility can't say what they are); allow unnamed sliders (rejected: nothing to check against what Benji said).
- **Accepted risk:** a named slider can still be something like volume that takes effect at once. Benji shows the ring and the activity line first, and any input of the user's stops it.
- **Status:** built and unit-tested, uncommitted on `companion-ui`. `xcrun swift test` 1223/0; selftest in a throwaway home 2410 ok and 1 failed, the failure being the settings-migration check for `appOffers` and `appOffersRecord`, keys from the separate app-offers work (`AppOffers.swift`), not this change. **Not live-verified:** `Benji.app` doesn't have this yet, and which element a real slider's knob reports is unconfirmed; if it differs, the drag is asked rather than wrongly quiet.

**Update to D-187 (2026-11-09, the owner said "Yes, build it"):** built as a new `card` size of the notch, uncommitted, not live-tested. Changed from the proposal: "Turn on" became "Try it", because skills are always on and a Turn on button would promise a switch that doesn't exist; Try it only fills the message box. The Settings switch starts off, per the D-173 rule for unasked surfaces; the owner has not yet chosen whether new users get it on.

### D-190 · The pointer arrow is a smaller, filled arrowhead in the icon's deep mint (done, not seen live)
- **What:** 20 pt instead of 24, one solid shape, `#08968e` (new token `benji-mint-deep`), no outline or halo. Supersedes the look in D-180.
- **Who:** the owner, 2026-11-09: smaller, completely filled, a slightly darker colour from Benji's theme, "nothing outside of it". Reading that last phrase as both no outline and no colour from outside the theme is Claude's.
- **Why this colour:** the icon's own deep mint, readable on light and dark desktops without an outline.

### D-192 · Opus reviews only; Codex and Grok implement; Sonnet 5.5 reviews when Grok cannot (accepted; supersedes D-191's "small glue edits are fine")
- **When / who:** 2026-11-10 ~15:10 PKT · the owner: "for this conversation don't use opus for anything but review. Development is taken up by either codex or grok." After Grok 4.7 failed (one task at capacity, HTTP 500; one "model not accepted"; a medium run of about 90 minutes with no edit, then cancelled), the owner chose Claude Sonnet 5.5 as the cross-vendor reviewer. Recorded by grok-4.7-build-fast.
- **What:** Claude Opus 5.5 reviews diffs, runs the gates and makes the git commits the owner approves. Codex and Grok do every edit. When Grok is unavailable, Sonnet 5.5 is the cross-vendor reviewer. This supersedes the part of D-191 that allowed the orchestrator small glue edits.
- **Why:** the owner's direction. A second vendor still reads each diff.
- **Alternatives:** Opus keeps the small glue edits (D-191; the owner closed that); wait for Grok on every review (Grok was unavailable).
- **Status:** accepted, and followed for the rest of this session.

### D-193 · Esc inside the panel stops a running answer, then folds (built, unit-tested, not live-verified)
- **When / who:** 2026-11-10 · Codex (`gpt-6.1-sol`, high) built it. Opus 5.5 rejected the always-on global key monitor Codex added. Grok 4.7's review of the diff found two word-loss defects; those were fixed. Committed `9b2b937` at 21:16 PKT (`benji`, not pushed).
- **What:** Esc inside the panel stops a running answer, then folds the panel. The "Stop (Escape)" tooltip matches that.
- **Why:** the tooltip already promised it.
- **Alternatives:** an always-on system-wide key monitor. Rejected: Esc in another app would cancel Benji, or answer No.
- **Status:** built, unit-tested, not live-verified. `Benji.app` was not rebuilt, so the running app does not have this.

### D-194 · The shell gate fails closed (unit-tested, not live-verified)
- **When / who:** 2026-11-10 to 2026-11-11 · five rounds by Codex (`gpt-6.1-sol`, xhigh, then high). Grok 4.7 found parent-search, glob and spelling bypasses. Sonnet 5.5 found 7, then 4 and 3, then gaps in git and in names. Opus 5.5 checked a fixture home: 24 bypasses ask, and 26 everyday commands stay free. Committed `40ad21b` at 2026-11-11 13:32 PKT. `d836a9d` (14:50) is a one-line regex fix: Opus had not run the public-export check before committing `40ad21b`, and the link check failed.
- **What:** a command the gate cannot resolve exactly as the shell would is asked. Each command has an exact option grammar. A recursive pre-scan runs on a time budget. Credential and secret paths are refused.
- **Why:** patching the parser one spelling at a time did not close the holes. Fail-closed grammars did.
- **Alternatives:** keep adding spellings as reviews found them (five rounds of that did not finish).
- **Known limits:** hard links, secrets in `.gitconfig` URLs, name-only listings.
- **Status:** unit-tested, not live-verified. The working-tree public export passed later, on `01bfa52`, after `d836a9d`.

### D-195 · One key source at a time; setup's Test states what it sends (unit-tested, not live-verified)
- **When / who:** 2026-11-11 · Codex (`gpt-6.1-sol`, high, then medium). Three reviews by Sonnet 5.5. The orchestrator removed mixed key-source mode. The owner confirmed on 2026-11-11 (18:44 PKT) that an existing source this setup has not tested counts as ready ("Not tested here"). Committed `01bfa52` at 17:56 PKT (`benji`, not pushed).
- **What:** one key source at a time. Setup asks for a model before "All set." Save moves the key file's other keys in the same press, by name, never by value. Move to the Keychain leaves a different stored value in place. In key-file mode, the Keychain is read only when the user presses Look for a key in the Keychain, Save or Move. A pasted key is written last, and that write rolls back if it fails. Test is a button. It says what it sends. It runs in a separate process, makes one request, waits at most 60 seconds, and the request has no tools, no history and no screen.
- **Why:** setup said "All set." with no model step. The Test is a button the user presses, and it says what it sends.
- **Alternatives:** mixed key-source mode (the orchestrator removed it); Move overwrites a different Keychain value (rejected).
- **Status:** unit-tested, not live-verified. `Benji.app` was not rebuilt. The 'Not tested here' rule is confirmed by the owner.

### D-196 · Measure scoped figure examples before adoption; preserve Haiku and existing behavior
- **When / who:** 2026-11-12 17:01 PKT; Codex records the owner's bounded experiment and request to protect quality and speed.
- **What:** Haiku 5.5 remains default. Opus 5.5 may author examples under the owner's explicit exception; otherwise D-192 still applies. $20 working cap/$25 absolute ceiling; exact outbound disclosure before each authorized batch. Recorded API ledger $2.234325; no new calls in this offline step.
- **Why:** teacher quality does not prove student improvement. The latest 24-request pilot missed 7/12 per-case timing checks; quality remains unassessed. The scoped candidate preserves 14 tested baseline payloads and four prior target payloads; it still has non-figure/cabin routing limitations and does not reduce target payload sizes.
- **Performance finding:** helper links debug core while app build selects release. Five-repeat comparisons preserve exact mesh bytes; cell fresh-mesh medians 23–59 ms release versus 606–1,557 ms debug. Do not lower geometry detail based on the debug measurement.
- **Alternatives:** global example additions, model changes, lower mesh detail or immediate integration. Not selected now; caching and compact examples need controlled evaluation.
- **Status:** isolated experiment only. Nine offline tests pass; 100 mesh timings and 25 release renders complete. One compile's real-store metadata warning remains unresolved. Candidate not live-tested/adopted. Full gates, routing fixes, concealed quality/performance validation, rebuild/signing and owner live/release checks remain pending. Round 2: APPROVE for disclosure and documentation only, claude-opus-5-5, high effort requested. Reviewer used no tools and did not independently verify hashes or internal effort. Product integration and live calls remain unapproved. Private evidence path (ignored, not a published link): `tmp/figure-teacher-2026-11-12/followup-offline/report.html`.

### D-197 · Close the figure experiment with adoption held
- **When / who:** 2026-11-12 18:48 PKT; owner: "Go ahead and just close this ASAP." Codex performs the final offline fix and records the outcome.
- **What:** stop further example authoring and paid trials for this experiment; preserve the corrected candidate and evidence. Keep Haiku 5.5, product code and installed app unchanged. Recorded API total $2.234325, closeout $0.
- **Why:** substantial Haiku visual improvement is unproven and the earlier per-case speed gate failed 7/12 checks. Routing repairs do not change those target payloads or prove a speedup.
- **Alternative:** integrate immediately or extend the experiment with new paid comparisons. Not selected for this closeout.
- **Status:** final candidate passes 11 focused tests; no full product gates, live validation or adoption. Final Opus verification: APPROVE, claude-opus-5-5, high effort requested; internal effort and hashes not independently verified. Approval covers closeout, not integration or live calls. Original rebuild/signing/live/release work remains pending. Private evidence path: `tmp/figure-teacher-2026-11-12/closeout/closeout.html`.

### D-198 · Resume figure improvement and test reusable prompt caching (2026-11-12 19:14 PKT)

- **Who:** owner clarified completion intent; Codex implements; exact Opus 5.5/high requested for review.
- **Decision:** supersede D-197's experiment-stop decision. Keep Haiku at low effort and retain mesh detail. Test scoped teachers together with static figure-guidance caching before adoption.
- **Why:** narrowing examples does not fix the previous 7/12 per-case timing misses. Caching is already enabled, but changing context precedes uncached figure guidance. Separating stable guidance may reduce repeated input work; it cannot guarantee lower generation time.
- **Alternatives:** buy more teachers, reduce mesh detail, swap default model, or claim debug-to-release measurements as a shipped gain. None addresses the demonstrated provider-latency question with evidence.
- **Status:** isolated implementation and offline tests; independent review APPROVE (claude-opus-5-5, high effort requested; internal effort/hashes not independently verified); fresh exact live approval pending. No speed claim, teacher integration, main write, install or release. New 60-call stage preserves $2.234325 prior spend, $20 working/$25 absolute caps. Main advanced to `ef6704f`; reconcile before shared integration.

D-198 adoption gate: validate ordinary figure-on and synthetic screen-context behavior before integration; retain the full geometry and existing screen-vs-figure policy. Offline factory tests check instruction retention, not model behavior. Additional live requests require exact disclosure and approval.

### D-199 · Cache reuse observed, performance adoption held after 60 calls

- **When / who:** 2026-11-12 20:54 PKT; Codex records the owner's approved comparison. D-198 remains active; this is not a closeout.
- **Decision:** keep Haiku 5.5 and geometry detail unchanged. Hold the combined candidate because airplane fails both timing gates and the overall 17.12% completion-median improvement misses the 20% threshold. Quality still requires owner ratings. Stop additional teacher purchasing for now and prepare a separate performance experiment changing only thinking mode, with exact disclosure and approval before any call.
- **Evidence:** 60/60 valid replies, zero dropped parts, zero pending charges; stage $0.134269, cumulative $2.368594. Figure-prefix hits 4/5 per candidate case. Aggregate completion medians 18.46/15.30 seconds; airplane 31.32/38.62 seconds. Fifteen calls have at least 60 seconds outside the SSE-line interval, cause unproven. Release offscreen first-part median 59.9 ms across 60 primary views; not UI or startup latency.
- **Why:** cache reuse was observed; the combined candidate did not meet the speed gates, and this design cannot attribute timing to caching. The trial uses a 60-second socket timeout versus production 180; sequential address fallback is verified offline, but actual stall cause and production occurrence are unknown. Instrument connection phases before more performance inference. Thinking tokens consume 69.38% current and 63.34% candidate output; this motivates testing explicit thinking disabled, not assuming equivalent time savings. Broadly disabling thinking could hurt tool use. Preserve general behavior until separately validated.
- **Alternatives:** immediate integration, more teacher examples, lower mesh detail or a new default model. Rejected at this stage because they do not resolve the failed gate with evidence.
- **Status:** results analysis review APPROVE after the specified wording correction, claude-opus-5-5/high requested; internal effort, hashes and images not independently verified. No new call authorization, integration, commit, app installation or release. Ordinary figure-on, synthetic screen and tool-needed behavior remain gates. Main is `ef6704f`, assigned checkout `1561002`; reconcile before shared work. Private evidence: `tmp/figure-teacher-2026-11-12/performance-fix/analysis/results.html`.

### D-200 · Isolate thinking mode and record connection phases before another speed decision

- **When / who:** 2026-11-12 21:30 PKT; owner said go ahead with next steps; Codex prepares, Opus reviews.
- **Decision:** prepare 60 requests comparing the same scoped candidate with adaptive versus disabled thinking. Keep Haiku 5.5, low effort, guides, cache markers, output cap and mesh detail fixed; interleave cases. No new live authorization is inferred from preparation. First-arm order is 3/2 per case, 16/14 disabled/adaptive overall, with uneven repetitions; report metrics by pair position. Require the isolation wrapper for each call and stop on wrapper warnings.
- **Why:** the previous combined experiment failed performance gates and contained unexplained waits of at least 60 seconds outside the SSE interval. Separate DNS/TCP/TLS/header/first-data timing can test client hypotheses; thinking mode cannot remove a fixed connection timeout if that is the cause. Never exclude stalled calls from the primary metric.
- **Gates:** no listed disabled-arm critical defect absent from its paired adaptive output; every failed sample is critical, and any disabled failure blocks adoption even if both fail; no pair losing 3/20 or more, no per-case median quality loss; at least 20% lower aggregate completion median and no per-case timing failure, complete batch required. These conservative gates compare against the same-guide candidate only. Its original-product quality gate and ordinary/screen/tool validation remain separate.
- **Alternative:** change network preference, shorten timeouts, buy teachers or globally disable thinking. Not selected without evidence. The traced runner retains 60-second per-address/socket timeout; production remains 180 seconds. DNS may exceed those timers, so a stuck worker is joined and never automatically retried.
- **Status:** experiment-only code, 39 runner and eight phase tests, 60 accounting replays, 60 local rehearsals; review APPROVE, claude-opus-5-5/high requested; internal effort, hashes and ledger state not independently verified. Bound $5.782770; prior $2.368594, unchanged shared ledger, $20 working/$25 ceiling. Exact live disclosure/approval and a fresh private credential remain required. No main/app/default changes or new spend.

### D-201 · Keep thinking on; hold the figure experiment off the release line (2026-11-14 09:58 PKT)

- **When / who:** 2026-11-13 to 2026-11-14. The owner approved the 60 D-200 requests, chose to resume after the halt, then asked to finish and open-source as soon as possible. Sonnet 5.5 then Opus 5.5 ran the batch (Codex hit its usage limit); a separate Opus 5.5 high-effort agent reviewed.
- **Decision:** do not ship a thinking-off switch for figures. Leave the D-198 cache-ordering patch and the scoped teacher candidate on branch `codex/haiku-figure-example-trial`, unmerged. The public release is cut from `companion-ui` without them.
- **Evidence:** 60/60 calls ran, stage $0.106115, campaign $2.474709. Disabled thinking was much faster: engine-to-complete-figure median 5.25 s versus 15.05 s adaptive, first visible text 0.69 s versus 11.10 s, every case faster. But `think3-25-candidate` (airplane, thinking disabled) wrote a complete figure and then called `run_shell` with `echo noop`. By D-200 a failed disabled sample blocks the quality gate, and the latency gate needs all quality gates before a gain may be called useful. Owner blind ratings are optional and descriptive only (local page `tmp/figure-teacher-2026-11-12/thinking-comparison/analysis/rating.html`).
- **Process notes:** the runner halted at the failure, as designed. On the owner's choice the halt row was deleted and the remaining 11 ran; a `think3_halt_and_resume` ledger row was added afterwards to restore the record. The key file was kept through the halt and deleted only at the end, a deviation from the protocol's "remove after any stop". Pair 25's adaptive call ran 24 minutes after its partner, with a cold cache.
- **Why:** an unrequested shell call on a plain drawing turn is exactly the tool-use risk D-199 and D-200 named; in the product, tools run. The speed gain is real but cannot be adopted without a guard against stray tool calls and dedicated tool-behaviour tests. The cache patch's own gate (ordinary figure-on and screen-context behaviour) was never run live, and it missed the 20% speed target in D-199.
- **Alternatives:** ship thinking-off for figure turns only (rejected: no tool-behaviour evidence); merge the cache patch now (rejected: unvalidated gate, and not needed for the release); run a guarded thinking-off round before release (deferred: delays open-sourcing).
- **Status:** experiment closed; code held on its branch. Review: APPROVE WITH NOTES, claude-opus-5-5, high effort; its page and ledger notes were fixed. Not live-verified in the app.

### D-203 · Publish `umarali/benji`; the private repository becomes `umarali/HeyBenji` (2026-11-14 10:31 PKT)

- **Who:** the owner: publish from the latest commit, keep the two repositories in step, rename the private `umarali/chilly` to `umarali/HeyBenji` (still private), push the private branch, and keep the contribution workflow simple. Claude (Opus 5.5) carried it out.
- **Contribution workflow (CONTRIBUTING.md):** issue first for anything bigger than a small fix; fork and branch from `main`; one change with its tests; two checks (`selftest.py` and `xcrun swift test`, both through `tools/isolated_run.py`, plus the extension's node tests when it changed); a pull request that says what could not be checked; maintainer review; squash merge. Nothing else.
- **Keeping the two in step:** `umarali/benji` `main` starts as one export commit of `companion-ui`. After that, public changes land by pull request on `umarali/benji` and are cherry-picked into `companion-ui` (squash merges make each one commit). Private work that should go public goes out as an ordinary pull request. Never re-export over public history, never merge the private history into it. `docs/README.md` maps to the public `(not in this export)`, and the public `docs/decisions.md` is a trimmed snapshot. To check for drift, export `companion-ui` and diff it against public `main`.
- **Why:** one simple path that anyone can follow; the export already strips private material once, so later traffic stays small and reviewable.
- **Alternatives:** periodic re-exports with force-push (rejected: rewrites contributors' history); public-only development (rejected: some work stays private).
- **Status:** see the timeline and progress entries for what was pushed.

### D-204 · The project page is published by a workflow; a hardware timing check is not enforced on shared runners (2026-11-14 21:30 PKT)

- **Who:** the owner asked for GitHub Pages to be turned on and for a review of the public repository; Claude carried it out.
- **Project page:** GitHub Pages serves a branch only from `/` or `/docs`, so `.github/workflows/pages.yml` uploads `site/` and deploys it when `site/` changes on `main`. The page is `https://umarali.github.io/benji/`.
- **Timing check:** the gate gives a recursive shell scan 0.75 seconds and asks when that runs out. The selftest asserted that a 20,000-entry scan finishes inside that budget, which failed on `main` twice on GitHub's shared macOS runners (0.7503 s against 0.75 s) while the same commit passed as a pull request. On a shared runner (`CI` or `GITHUB_ACTIONS` set) the test now gives the scan a wide budget, still checks its answer, and prints the timing without judging it. On a real Mac the 0.75-second check is unchanged. The product's budget is unchanged.
- **Temp-folder cleanup:** `selftest_durable.py` removed a temporary folder while a stopped job's thread could still write one last file into it, which crashed the run once on Python 3.11. Those folders are now removed with `ignore_cleanup_errors=True`.
- **Why:** a required check that fails by chance teaches everyone to ignore it. A speed claim about a user's Mac cannot be judged on someone else's shared machine.
- **Alternatives:** raise the product's budget (rejected: it would make every user wait longer to hide a test problem); retry failed jobs (rejected: hides real failures).
- **Status:** see the pull request's checks.
