# Proposal: persistent `chilly --serve` (D-34, D-72)

_Status: **increment 1 (Python) built** 2026-10-31 ~00:31 PKT (`chilly/serve.py`, `chilly --serve`,
offline self-test); **increments 2–3 (Swift) built** 2026-10-31 ~03:40 PKT on the Mac
(`ServeProtocol.swift` in Core, `ServeBackend` in the app, behind
`defaults write com.chilly.app backendMode serve`; D-79). Not yet tried in the running app.
Proposed ~00:26 PKT in a cloud session. Where the build differs from the text below, see
"As built" at the end._

## Why

Today the companion starts a new `python3 -m chilly "<task>"` for every message. That works, but:

- **Context is thin.** Follow-ups only see the last 10 exchanges as plain text (`--history`,
  D-49): no tool calls, no tool results, no earlier screenshots. "Now do the same for the other
  folder" works only if the answer happened to spell out what was done.
- **Every message pays start-up costs:** a login shell, Python start, `.chilly.env`, the memory
  digest, a fresh TLS connection.
- **Conversation mode (D-43)** needs a process that stays alive between spoken turns.
- The protocol is sentinel-tagged lines mixed with stderr (`2>&1`), so an unexpected log line
  can look like output.

A persistent process that keeps one `Agent` and speaks JSON lines over stdio fixes all four.

## Shape

- `chilly --serve` reads **requests** from stdin and writes **events** to stdout, one JSON object
  per line (UTF-8, `\n`-terminated). Nothing else is written to stdout. Human-readable logs go
  to stderr, which the app reads separately (no `2>&1`).
- Started by the companion on its first message, kept for the app's lifetime, ended by
  `shutdown` or stdin closing. No socket, no port: only the parent process can talk to it.
- One turn at a time. A `send` while a turn runs is answered with
  `error {code: "busy"}`; the app already ignores input while working.
- The one-shot CLI, `CHILLY_EVENTS=1` and `CHILLY_APPROVAL_IO=1` stay exactly as they are, so the
  current app keeps working and the switch can be made behind a setting.

## Messages (protocol version 1)

Requests (app → Chilly):

| `type` | Fields | Meaning |
|---|---|---|
| `hello` | `protocol` | First line. Chilly answers `ready` or `error {code: "protocol"}` |
| `send` | `id`, `text`, `image?` (path), `allow_pointing?` | Run one turn |
| `approve` | `id`, `request`, `decision` (`"yes"` / `"no"`) | Answer an approval. Only the string `"y"`/`"yes"` approves; anything else, JSON `true` included, is a No |
| `cancel` | `id` | Stop the turn |
| `restore` | `exchanges: [{user, assistant}]` | Seed context after a restart (same shape as `--history`) |
| `reset` | | New conversation: forget context (memory facts stay) |
| `shutdown` | | Exit after the current turn is cancelled |

Events (Chilly → app):

| `type` | Fields | When |
|---|---|---|
| `ready` | `protocol`, `version`, `provider`, `model`, `destination`, `approval_timeout` | After `hello` |
| `accepted` | `id` | The turn was taken (first event of a turn; added by D-98, older apps ignore it) |
| `tool` | `id`, `name`, `detail` | A tool starts (as today) |
| `activity` | `id`, `kind`, `name?` | A tool that actually ran (not declined, failed or cancelled): `command`, `file_saved` (+ `name`, the file name only), `file_read`, `files_looked`, `web`, `automation`, `shortcut`, `remembered`. Never a command, path, contents or query (D-98) |
| `approval` | `id`, `request`, `action`, `target` | A gated action waits for `approve` |
| `approval_result` | `id`, `request`, `approved`, `why` (`yes` / `no` / `timeout`) | How each approval ended (not sent for a cancelled turn) |
| `delta` | `id`, `text` | A piece of the answer as the model writes it (D-104; older apps ignore it). The deltas after the turn's last `delta_reset` join to exactly the `answer`'s `text`. With `allow_pointing`, tags never stream. Not sent with `CHILLY_STREAM=0`, nor for a cancelled turn |
| `delta_reset` | `id` | Forget the deltas so far: that text came before a tool call, so it isn't the answer (D-104) |
| `answer` | `id`, `text`, `targets` | The final answer. With `allow_pointing`, Chilly strips the tags itself (`chilly/pointing.py`) and sends `targets` as `[{kind, coords, label}]`, so the app no longer parses text |
| `usage` | `id`, `calls`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens` | Per-turn totals (also logged to `usage.jsonl`) |
| `error` | `id?`, `code`, `text` | `busy`, `provider`, `bad_request`, `protocol`, `internal`; `startup` (before `ready`, then Chilly exits 2: bad flags or config) |
| `done` | `id`, `status` (`ok` / `cancelled` / `error`) | Always last for a turn |

Example:

```
→ {"type":"hello","protocol":1}
← {"type":"ready","protocol":1,"version":"0.1.0","provider":"claude","model":"claude-sonnet-4-5","destination":"Anthropic","approval_timeout":90.0}
→ {"type":"send","id":"t1","text":"tidy my Downloads"}
← {"type":"tool","id":"t1","name":"list_dir","detail":"~/Downloads"}
← {"type":"approval","id":"t1","request":"a1","action":"move files","target":"~/Downloads/Archive"}
→ {"type":"approve","id":"t1","request":"a1","decision":"yes"}
← {"type":"approval_result","id":"t1","request":"a1","approved":true,"why":"yes"}
← {"type":"answer","id":"t1","text":"Moved 12 files to Archive.","targets":[]}
← {"type":"usage","id":"t1","calls":3,"input_tokens":5120,"output_tokens":210,"cache_read_tokens":0,"cache_write_tokens":0}
← {"type":"done","id":"t1","status":"ok"}
```

## How it works inside

- **Two threads.** The main thread reads stdin and dispatches; each turn runs in a worker
  thread. An approval inside the turn waits on a queue for the matching `approve`; no answer
  means **deny** (as today). Chilly's own timeout (90 s, sent in `ready`) is a backstop longer
  than the app's 60 s, so the app's decision or its own timeout always arrives first and the
  two never race (D-77). An answer that arrives just as Chilly times out is either used or
  refused with `bad_request`, never silently dropped.
- **Once a turn's result is committed it can't be cancelled** (`bad_request`, "already
  finishing"), so the app never sees `done {cancelled}` for a turn whose answer is in context.
- **Cancel that never leaves a mess.** A model call blocks in `urllib` for up to 180 s and
  can't be interrupted from another thread. So a turn works on a **copy** of the conversation
  and commits it only when it ends `ok`. On `cancel`, Chilly sends `done {status: "cancelled"}` at
  once, bumps a turn counter, and drops whatever the old worker returns later. A running tool
  subprocess (`run_shell`, `osascript`) is killed. The cancelled turn leaves no trace in the
  context.
- **Context stays bounded.** Keep the last 10 exchanges (as `--history` does). Screenshots
  stay only in the turn that sent them; earlier ones become `[screenshot omitted]`. Tool
  results from earlier turns are cut to 2,000 characters. Later, Anthropic prompt caching
  (`cache_control` on the system prompt and the history) would cut repeat input cost; the usage
  log already records cache reads and writes so the saving can be measured.
- **The system prompt is built per turn:** the memory digest can change between turns, and the
  pointing rule is added only to turns with `allow_pointing`.
- **Config** (`.chilly.env`, keys, model) is read once at start. A changed key needs a restart,
  which the app can trigger (`shutdown`, then start again).

## Failure and restart

- If Chilly exits unexpectedly, the app shows the error for the turn in flight, restarts Chilly on
  the next message, and sends `restore` with its own `ConversationMemory` (the app stays the
  source of truth for what the user saw). Context degrades to today's level, never worse.
- Malformed request lines get `error {code: "bad_request"}` and are otherwise ignored. A bug
  in a request handler or while building a turn becomes `error {code: "internal"}` (and that
  turn's `done {status: "error"}`); Chilly keeps serving.
- SIGTERM, SIGINT, end of input and `shutdown` all cancel the running turn (denying a waiting
  approval and killing its tool processes) and exit 0. If the app's end of the pipe is gone,
  Chilly stops writing instead of crashing.
- A protocol mismatch (`hello` with an unknown version) makes the app fall back to one-shot mode.

## Safety

- Same approval gate and `--yes` rules as today; `--serve` never auto-approves.
- No network listener. Requests come only from the parent's pipe.
- **The event stream can't be corrupted or read by tools:** at start Chilly keeps private copies
  of stdin and stdout for the protocol, then points fd 1 at stderr and fd 0 at `/dev/null`, so
  a stray `print` or anything a tool starts can't write events or read requests (D-77).
- Image paths are read once per turn and never echoed back. Message text is never logged
  (consistent with D-35).

## Build order (each a small, verified increment)

1. **Python:** `chilly/serve.py` with a `Server(agent_factory, stdin, stdout)` class and the
   `--serve` flag; offline self-test that drives it through in-memory streams with a fake
   provider (send, tool, approval yes/no/timeout, cancel mid-call with a late result
   discarded, busy, reset, restore, bad request, shutdown). _Cloud-session work._
2. **Core:** `ServeProtocol.swift`: encode requests, decode events, unit-tested against the
   same example lines. _Cloud-session work (Linux `swift test`)._
3. **App:** a `ServeBackend` beside `OneShotBackend`, chosen by
   `defaults write com.chilly.app backendMode serve`; one-shot stays the default.
   _Needs the Mac._
4. Live check on the Mac (follow-ups that need earlier tool results, cancel mid-run, approval
   timeout, crash and restore), then make `serve` the default. Conversation mode (D-43) builds
   on this.

## Alternatives considered

- **Keep one-shot and pass richer history** (tool calls and results in `--history`): simpler,
  but start-up cost stays, and replaying tool results through a file grows quickly.
- **A local HTTP or Unix-socket server:** reachable by other local processes, so it needs
  authentication; stdio has none of that exposure.
- **Reuse the `\x01PAL-…` sentinels:** compatible with today's parser, but the mixed stream is
  the fragility being removed.

## Open questions for the user

1. Build it now (increments 1–2 in a cloud session), or after the Mac work on the notch?
2. Should context survive an app restart (write it to disk), or is starting fresh fine? This
   proposal starts fresh, with `ConversationMemory` as the safety net, to keep less on disk.

## As built (increment 1, 2026-10-31)

- **One Agent per turn.** Each turn gets a fresh `Agent` over the shared provider, seeded with
  the trimmed committed conversation; on `ok` its messages become the new conversation. The
  system prompt (memory digest, pointing rule) is built per turn, as proposed.
- **Cancel stops everything the turn started.** The agent loop checks a `cancelled` flag before
  every model call and every tool call, a waiting approval is answered no, the late result is
  dropped, and a tool process already running is killed with its children (D-75, added ~00:50).
  A model call already in flight can't be interrupted; its answer is just discarded.
- **Busy rules.** `send`, `restore` and `reset` are refused with `busy` while a turn runs. After a
  `cancel` the server is free at once, even if the old worker is still waiting on the network.
- **A bad image** gives `error {bad_request}` and `done {error}` without any model call.
- `--serve` refuses a task, `--image`, `--history` and `--yes` on the command line.
- **Tested** offline in `selftest.py` (21 checks): order of events, context carried between
  turns, approval yes / no / timeout, busy, cancel (immediate `done`, late result dropped, no
  trace in context, waiting approval denied), pointing targets, provider error, bad image,
  restore, reset, shutdown, trimming, and one run through real stdio. **Not tested** against the
  real API, and not used by the app.

## As built (increments 2–3, 2026-10-31, D-79)

- **Core:** `ServeProtocol.swift`: `ServeRequest.line()` (sorted-key JSON, one line) and
  `ServeEvent.decode(_:)` (nil for a non-JSON line, `.unknown` for a newer event type; targets
  `{kind, coords, label}` become `PointingTarget`s, malformed ones dropped, at most three).
  `ServeProtocol.approvalTimeout(engineTimeout:)` keeps the app's alert at 60 s and always at least
  5 s below the timeout Chilly announces in `ready`. 11 XCTests, using the proposal's example
  lines and lines from the live run.
- **App:** a `CompanionBackend` protocol with two implementations: `OneShotBackend` (one-shot, still
  the default; it now writes and removes its own `--history` file) and `ServeBackend`, picked
  at launch by `defaults write com.chilly.app backendMode serve`. `ServeBackend` starts
  `chilly --serve` on the first message, holds requests until `ready`, sends `restore` with the
  app's recent exchanges whenever it (re)starts Chilly, maps `answer.targets` straight to the
  overlay (no text parsing), answers approvals by request id, sends `reset` on New
  conversation and `shutdown` on quit, and reports an unexpected exit as an error for the turn
  in flight (with Chilly's last stderr line). A `protocol` error before `ready` switches to
  one-shot runs for the rest of the session. SIGPIPE is ignored so a write to a dead Chilly can't
  kill the app.
- **Checked end to end without the GUI or the API:** `companion/ServeCheck/run.py` compiles the
  app's own `ServeBackend.swift` and `OneShotBackend.swift` with Core and a driver, and runs them
  against a real `chilly --serve` whose model is a localhost fake (15 checks: context, approve,
  deny, cancel, pointing targets, reset, restart + restore after a crash, crash mid-turn,
  shutdown, the one-shot history file). **Not checked:** the protocol-mismatch fallback, and
  anything in the running app (the alert, the overlay, voice turns).

## As built: streaming (D-104, 2026-10-31)

- **`delta {id, text}`** is sent for each piece of assistant text as it streams in, before
  `answer`. `answer` still carries the full text, unchanged, so an app that ignores `delta` works
  as before (the current app decodes it as `.unknown`).
- **`delta_reset {id}`**: Claude often writes a sentence ("Let me look.") and then calls a tool.
  That text has already streamed, but it isn't the answer (the answer is the text of the last
  model call, as before streaming), so Chilly takes it back with `delta_reset` before the `tool`
  event. Rule for a front-end: **the deltas after the last `delta_reset` join to exactly the
  `answer` text.** Chilly guarantees it: before `answer` it sends what is missing, or a reset and
  the whole answer (e.g. the "stopped: maximum tool steps" message).
- **Pointing turns:** text that could still turn out to be trailing tags (and the whitespace
  before them) is held back until more text proves otherwise, so tags never appear in a delta.
- **Cancel:** `done {cancelled}` is still immediate, and no `delta` follows it (the same gate as
  every other event). The stream's connection is shut down at once, which also stops the model.
- A server that answers a streaming request with plain JSON (e.g. a test fake, some local
  servers) still works: its text arrives as one `delta`.
- **Streaming is off unless `CHILLY_STREAM=1`** (opt-in until a live call has proved it, 2026-10-31). Off: no `delta` events, one
  blocking request per model call, exactly as before.

## As built: background jobs (D-130 step 1, D-141, 2026-11-04)

A job is a second turn in the same process. Additions, all optional for an
older app (an engine without `jobs` in `ready` offers none; an app that doesn't send `jobs: true` is never
offered `start_job`):

| Direction | `type` | Fields | Meaning |
|---|---|---|---|
| app → | `send` | `jobs: true` | The app shows jobs: the foreground turn may call `start_job` |
| app → | `job_stop` | `job` | Stop the job (also the beat's Esc) |
| app → | `job_steer` | `job`, `text` | Steer a running job; taken between its tool steps |
| app → | `job_dismiss` | `job` | Hide a job that is over |
| app → | `approve` | `id` = the job's id, `request`, `decision` | A job's approval is the ordinary `approve` naming the job; it has no timeout |
| → app | `ready` | `jobs` | The engine can run jobs |
| → app | `job` | `job: {id, title, state, line, pending{request, action, target}, spoken, files[{name, path}], chips[], error, tainted}` | The job as it is now, on every change; `state` is derived in code: `queued`, `working`, `needs-you`, `done`, `failed`, `stopped` |

A job emits no `tool`, `delta`, `approval` or `done` events; its whole story is `job` snapshots.

## As built: jobs, second pass (D-172, 2026-11-07)

Runs, schedules, continue, a hand-off brief. Every addition is optional for an older app or engine: an engine without
`schedules` in `ready` is never sent the schedule requests, an app that does not send `schedules: true` is never offered
`repeat`, and an engine runs no schedule until the app has sent `schedules_set` true.

| Direction | `type` | Fields | Meaning |
|---|---|---|---|
| app → | `send` | `schedules: true` (with `jobs`) | The app can show and carry out schedules: `start_job` may carry `repeat`, and `schedule_job` is offered. Each is asked on a card |
| app → | `job_continue` | `job` | Another run of a job that failed or stopped (the same job, folder and history). Refused for any other state or while a job is running |
| app → | `job_schedule` | `job`, `action`: `pause`, `resume`, `delete` | The row's own schedule buttons; no card, the user pressed it |
| app → | `schedules_set` | `enabled` (boolean) | The one switch for every schedule (Settings). True lets due schedules run while the engine is up; false stops a repeat run in flight and runs none. Anything but a boolean is `bad_request` |
| → app | `ready` | `schedules` | The engine carries out schedules |
| → app | `job` | `brief`, `run`, `done`, `left`, `ask`, `stopped_at_limit`, `can_continue`, `unattended`, `news`, `quiet`, `schedule: {text, next, paused, reason, last, switch_on}` | New fields on the snapshot. `brief` is what the job was told (cut to 700 characters). `quiet`: a repeat run with nothing the user needs to hear; the app makes no peek, sound or thread entry. `stopped` with `stopped_at_limit` is a run that used all its steps and reported |

A schedule is kept as `jobs/<id>.schedule.json`, beside the job's folder and never in it, so a job cannot write its own schedule.

## As built: browser reach for jobs (D-143, step 1, 2026-11-04)

Read-only pages in the user's Chrome for a background job. Optional for an older app or engine (an engine without
`browser` in `ready` has no link; an app that never sends `browser_set` never opens one).

| Direction | `type` | Fields | Meaning |
|---|---|---|---|
| app → | `browser_set` | `enabled` (boolean) | The user's switch (Settings › Browser): true opens the engine's local link for the extension's host, false closes it at once. Anything but a boolean is `bad_request` |
| → app | `ready` | `browser` | The engine has a browser link it can open |
| → app | `browser` | `state`: `off`, `waiting` or `connected` | The link as it is now, on every change (waiting: listening, no extension connected) |
| → app | `job` | `sites: [origin]` | The https origins the user approved for this job to read; a card adds one during the job |

The job's tools (`browser_open`, `browser_tabs`, `browser_read`) are not events: they are tool calls inside the
job's turn, and a card to add a site is an ordinary parked approval of that job. `start_job` gains an optional
`sites` list (only when the switch is on); naming sites is always asked on the foreground card, which lists them.
The link itself (engine ↔ native-messaging host, 127.0.0.1 and a per-run token) is not part of this protocol.

## As built: capabilities, prewarm, policy and the tool cap (D-173, 2026-11-07)

All additive; an old app and an old engine still work together.

- `hello` may carry `"capabilities": [...]` (names from `pointing, screen_actions, cards, figures, jobs,
  browser, prewarm`). The engine keeps the names it knows, ignores a list that is not a list of up to 64 short
  strings (as if absent), and from then offers a turn only what the app listed: no `screen_actions`, no screen
  tools, whatever `send` says; no `cards`, no card lines; and so on. No list: the `send` flags decide, as before.
- `ready` gains `"capabilities": [...]` (`hello_caps, prewarm, policy, tool_cap, image_hash, error_reasons`).
  The app sends `prewarm` only to an engine that lists it.
- `{"type": "prewarm"}` (app → engine, no reply): on a talk-key press. If the last call was over four
  minutes ago, no turn is running, and the provider is not a server on this Mac, the engine resolves the
  provider's host name once. One audit event, `prewarm` (`skipped`, and `ms` and `ok` when it ran). Nothing is
  sent to the provider.
- Within a turn, a screen step whose returned picture is byte-identical to the one the model already has
  is not attached again; the tool result says the screen is the same.
- The error event keeps `code`, adds `reason` (`auth, network, rate_limit, quota, region, provider,
  bad_request, other`) and its `text` is plain words (status and host only).
- `~/chilly/policy.json` (`{"disable": [...]}`, restrict only) is read at each turn; a tool it switches off
  is neither offered nor run (`policy_blocked`); a turn's 31st tool call (101st for a job) returns
  `[superseded]` and is not run (`tool_cap`).

