# Benji

[![ci](https://github.com/umarali/benji/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/umarali/benji/actions/workflows/ci.yml)
[Project page](https://umarali.github.io/benji/)

**Benji** is a voice-first assistant for the Mac that lives in the notch. Hold a key and say what
you want, or type it. Benji runs an LLM tool-use loop that can run commands, read and write files,
search the web, script your apps and, when you ask, look at your screen and point at what you should
click. It asks before anything destructive or outward-facing, and it can take a longer task off your
hands and work on it in the background.

- **Benji.app** (`companion/`): the notch app, written in Swift (SwiftPM, macOS 14+).
- **`benji`** (`benji/`): the Python engine and command line the app drives. Claude by default;
  OpenAI, DeepSeek, GLM (Z.ai), Kimi (Moonshot), Qwen (Alibaba Cloud), a model on your own
  computer (Ollama, LM Studio) or any OpenAI-compatible server instead. **No third-party Python
  dependencies** (standard library only).
- **`browser-extension/`**: a small Chromium extension that lets a background job read pages you
  approved in your own browser and, with a second yes per site, click and type there. Off by default.

> **Early software from one maintainer.** It is developed and used on one Mac (Apple silicon, a
> notched display, recent macOS), mostly against Anthropic's API. Some features have had one short
> live run and some have never been run live. The [status table](#status) says which, per feature.
> There is **no signed or notarised download yet**: you build it yourself
> ([Build from source](#build-from-source)).

## Start here

[Set up Benji on your Mac](docs/setup.md) walks through the source build, model configuration,
a first typed message and optional permissions. Start with the offline check. It needs no key
and makes no model request.

The app currently needs Terminal and Xcode to build. If you need an installable download,
there is not one yet. The [status table](#status) separates everyday use from features that
have only been tested offline.

## What it does

- **Talk or type.** Hold **Right ⌥**, speak, release (or tap once to start and again to send), or
  type in the panel. Speech is transcribed on your Mac with Apple's on-device recognition.
  Spoken answers are read aloud.
  In the panel, **Esc** stops an answer in progress, then folds it; otherwise it folds or closes the
  panel. On a foreground approval it means **No**; in Settings it goes back; in the conversation
  list it goes home.
- **Do things.** Shell commands, files in a working folder (`~/.benji` by default), web search and
  fetch, AppleScript and Shortcuts, skills (folders of instructions you can add) and a small
  memory of durable facts.
- **See your screen when you ask.** The viewfinder button sends one screenshot with the **next
  message only**; the answer may point at a control with a ring or outline a region. No continuous
  capture.
  If Screen Recording is off, your message stays pending on the screen-confirmation card. Choose
  **Send without screen** to send your message alone, or Cancel to put it back in an empty
  composer. A draft already in the composer is kept.
- **Background jobs.** "In the background, find three options and write a comparison to a file."
  The job runs in its own folder while you keep talking to Benji, behind the same safety rules as
  everything else. See [Background jobs](#background-jobs).
- **Use your own browser** (optional). A job can open pages you approved in your signed-in browser,
  read their text and, once you allow it for that site, click and type, with a card for anything that
  sends, pays, posts, deletes or uploads. "Summarise this page" reads the page in front of you after a
  card. See [Browser reach](#browser-reach).
- **Your choice of model.** See [Choosing a model provider](#choosing-a-model-provider) and, for
  what each provider is sent, [Privacy](#privacy).

## Status

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
| Notarised download, other Macs and macOS versions | Not available / untested | See [Build from source](#build-from-source) |

Offline checks run in [GitHub Actions](https://github.com/umarali/benji/actions): engine selftests
on macOS with Python 3.11 and 3.12 (through `tools/isolated_run.py`, as in the contribution guide),
Swift tests and ServeCheck on `macos-26`, extension tests, and repository checks.
Details per feature are in the [docs](docs/README.md) and [docs/providers.md](docs/providers.md).

## Safety model

Benji can run commands and change files, so the rules that limit it are in **code**, not only in the
prompt. A model that is persuaded by a web page still cannot widen what the code allows.

- **The gate.** Every tool call is classed *free* (read-only, inside the working folder), *quiet*,
  *asked* or *denied*. Destructive shell commands (`rm`, `mv`, `sudo`, `git push`…), overwrites,
  sends, writes outside the working folder, reads outside it and sensitive capabilities **ask first**
  (a card in the app, `y/N` in the terminal). Private locations (keys, mail, messages, browser data,
  Benji's own key file) are refused outright, including through a symlink. The shell is a read-only
  allowlist: a command is understood by a parser and anything it does not understand asks. `--yes`
  auto-approves; use it only where you trust everything the model might read.
- **Taint.** Once a turn has read something from outside (a web page, a browser tab, a file outside
  the working folder, an unverified skill), anything it then changes asks, whatever the model says.
  Looking at your screen is a weaker source and is tracked apart. Taint passes from a turn into a job
  it starts and back to a turn that reads the job's result.
- **Instructions are data.** The text of files, pages, command output and screenshots is treated as
  data, never as commands. That is a prompt rule backed by the code checks above; it is **not a
  sandbox**. Read what you approve. See [SECURITY.md](SECURITY.md).
- **Job approvals park, they don't fail.** A job that needs your answer waits, with no timeout, as
  **Needs you** in its row. Only that row's own Yes/No buttons answer it: not a spoken "yes", not a
  key press, not Esc. Stop answers No.
- **A metadata-only audit log.** `events.jsonl` in the working folder records what ran, how the gate
  classed it and why, how each approval was answered, job states and errors. Every field is checked
  against a closed list before it is written, so it **cannot** hold message text, page text, file
  contents, addresses or keys. Logs are readable by you only. `benji --diagnose [--hours N]` prints a
  short report from it to read, or to paste into a bug report; the app has the same under
  Settings › General › Diagnostics. `BENJI_AUDIT=0` turns the log off.

## Background jobs

Ask for something to be done "in the background". Benji starts one job (one at a time), tells you in
a sentence, and carries on. The job:

- gets its **own folder** (`~/.benji/jobs/<id>/` with `report.md` and `output/`), up to 40
  tool steps, the usual non-screen tools, and **no** screen tools and no pointing;
- runs behind the **same gate and taint rules**, with its own folder as its working folder, so a
  write elsewhere or a read of your files outside it asks;
- shows as one **row** above the conversation: state (*working*, *needs you*, *done*, *failed*,
  *stopped*), what it is doing, Stop, a steer field, and when it ends its files and follow-up chips.
  The state is derived in code, never from what the model writes;
- starts after a 2.5-second peek ("Starting … · Esc cancels");
- does **not** survive quitting Benji: it is shown as *Didn't finish* afterwards and does not resume.
- is told what you agreed in the conversation (your last few messages, the sites and files you named), and the row
  shows you what it was told;
- re-reads its brief every ten steps and after any wait, and if it uses all its steps it stops, says plainly what is
  done and what is left, and asks you; **Continue** on the row starts another run of the same job;
- can be told to **repeat** ("every morning at 9", never more often than every 30 minutes). Benji asks on a card first.
  The same job then runs again, only while Benji is open and your Mac is awake (a run missed in sleep happens once),
  and a repeat run **only reads**: anything else waits for you. A repeat run with nothing new makes no sound. Three
  failed runs in a row pause it, the row has Pause, Resume and Delete, and Settings has one switch for every
  repeating job;
- remembers a "No" for 30 minutes, so the same action on the same thing is not asked again straight away.

Turn jobs off with `defaults write com.emerssive.heybenji.app backgroundJobs -bool NO`. **Experimental**: see the
[status table](#status).

## Browser reach

A background job whose record carries a **site grant** can open pages in your own browser and read their
visible text. With a separate **acting grant** for a site it can also click and type there.

- **Off by default.** Nothing is installed or registered until you turn on Settings › Browser, and then
  each browser (Chrome, Chrome Beta, Brave, Edge, Arc) is its own switch; Benji writes the connection
  file only for the ones you turn on, and turning the master switch off removes them all. Benji never
  changes a browser's own settings: you turn on Developer mode and load the extension yourself.
- **Our own extension** (`browser-extension/`), loaded unpacked for now (`chrome://extensions` ›
  Developer mode › Load unpacked). It requests `nativeMessaging`, `tabGroups`, `scripting`, `storage`,
  `alarms` and `debugger`, with site access as an *optional* permission that the browser asks you for.
  It does not request `tabs`. Because `debugger` is new in version 0.2.0, an older install is switched
  off by the browser until you approve it again on the extensions page. Its README lists each permission.
- **Per-job site grants.** When a job is started with sites, a card lists exactly those origins
  (https, exact host and port, no wildcards) and you say Yes or No. Another site, a subdomain or
  another port is another card. Nothing a page says can add one.
- **Acting is a second, separate yes** for each site, never implied by reading. Each click, typed word or
  key is then classed in code from what the page's element is, not from what the model called it: a link
  on the same site, a tab, a disclosure, a tick, a field your message named go ahead; a button that
  sends, pays, posts, deletes or confirms, a form post, Return, a link to another site, a download and
  anything Benji can't tell ask you every time; password, card-number and one-time-code fields are
  refused. **File uploads are always asked, one card per file naming the file and the site; keys, mail,
  messages, browser data and `.env` files are refused outright; there is no "always approve".**
- **The debugging bar is the stop button.** While a step runs, the browser shows a bar saying it is being
  debugged. Cancel on that bar stops the job. The extension attaches only for the step and lets go after.
- **The page in front.** Ask about the page you are looking at and a card shows its site first. In
  Settings you can set exact sites to "always allow reading" (reading only: acting, uploads and sends
  still ask).
- **What it cannot do:** run a script of the model's, read any tab outside its group, type into a
  password or card field, press shortcuts, or use a private window. A job's tabs are closed when it ends.
- **Page text is outside content:** reading it taints the job, so every change the job then makes asks.

Be aware: a granted site is read and acted on **as you**, with your cookies, so a signed-in page's text goes
to your model provider and a click is a click by you. **Not live-tested** in a real profile. Arc and the
other Chromium browsers are in the table but have not been tried. A Web Store build is not made yet.
See [docs/ROADMAP.md](docs/ROADMAP.md).

## Privacy

- **No telemetry, no account, no hosted backend.** Benji talks to the model provider you
  configured and to nothing else of its own. `benji --print-provider` shows where your data
  goes, with no API call.
- **What the provider sees.** With a hosted provider, your messages, what the tools return (file
  text, web pages, command output, browser page text) and, when Screen is on, the screenshot are sent
  to that company's servers, in the country the [provider table](#choosing-a-model-provider) names,
  under its terms. The gate, taint rules and audit log work the same for every provider but cannot
  make a hosted model forget what it was sent. **Only a model you run yourself** (Ollama, LM Studio)
  keeps everything on your Mac. DeepSeek's own policy says personal data is stored in the People's
  Republic of China; Z.ai, Moonshot and Alibaba Cloud name Singapore for their international
  platforms (details in the table).
- **Keys** are read from the environment or `.benji.env` files and are never logged or written to
  disk by Benji. A provider's key is sent only to that provider's own host (a different
  `BENJI_BASE_URL` needs its own `BENJI_API_KEY`), and plain `http://` is refused except to your own
  computer.
- **Local files.** Memory (`memory.jsonl`), token counts (`usage.jsonl`, counts only), saved
  conversations, `answers.jsonl` (the model's raw answers: the one content log), job folders, the
  audit log and `engine.log` live in the working folder, `~/.benji` by default: one hidden folder, not
  loose folders. Log files are written readable by you only. Settings ›
  "Show Benji's folder" opens it. An older `~/benji` is moved into it once, on the first start; if both
  exist, `~/.benji` is used and nothing is merged. The key file `~/.benji.env` and the browser link's
  private folder stay where they are.
- **Screen.** One screenshot of the display the panel is on (Benji's own windows left out),
  downscaled, sent with the next message only; you see a thumbnail of exactly what was sent and the
  file is deleted after the reply. A model that cannot read images is never sent one.
- **Voice.** Transcription is on-device (Apple). Cloud transcription exists only for the optional
  command-line `--voice` / `--listen` flags.

## Requirements

- A Mac with **macOS 14 or later** (Apple silicon assumed; the layout is designed for a notched
  display, other displays are handled but less tested).
- **Python 3.11 or later** (`python3 --version`).
- To build the app: **Xcode 26 or later** (macOS 26 SDK), on a Mac supported by that Xcode release. See [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements).
- One model API key (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or a key for DeepSeek, Z.ai, Moonshot or
  Alibaba Cloud), or a model running on your own computer.
- Optional: `ffmpeg` and a transcription key for the command-line voice flags; a web-search key for
  reliable search; `./voice-setup.sh` for an on-device voice (about 400 MB).

## Build from source

There is no notarised download yet (see [docs/RELEASING.md](docs/RELEASING.md) for the owner's plan), so
you build Benji.app yourself.

For the complete walkthrough, including where to put a key and how to start without voice or
screen permissions, follow [Set up Benji on your Mac](docs/setup.md).

```bash
git clone https://github.com/umarali/benji.git
cd benji
python3 tools/isolated_run.py -- python3 -m benji --version
cd companion
./build.sh
open Benji.app
```

The version check is offline. Building and opening the app does not configure a model for you.
Keep the app inside this checkout: its Python engine is loaded from the repository, not bundled
inside `Benji.app`. If you already run Benji, quit it yourself before opening another copy.

Use **`xcrun swift`**, not plain `swift`, wherever you run Swift yourself: the `swift` first on a
Mac's `PATH` can be an old standalone toolchain that cannot load this package, while `xcrun`
picks the one in your Xcode. `build.sh` already does.

**Code signing, and why it matters.** macOS ties the permissions you grant (Accessibility, Screen
Recording, Microphone) to an app's signing identity. `build.sh` signs the app with a certificate
named **"Benji Local Signing"** if your login keychain has one:

1. Open **Keychain Access › Certificate Assistant › Create a Certificate…**.
2. Name: `Benji Local Signing`. Identity Type: *Self Signed Root*. Certificate Type: *Code Signing*.
   Create it.
3. Run `./build.sh`. The first `codesign` may ask for your login password; choose **Always Allow**.

Without it, `build.sh` signs **ad hoc**: the app runs, but the signature changes on every build, so
**macOS asks for every permission again after each rebuild**. Set `BENJI_SIGN_IDENTITY` to use another
identity (list yours with `security find-identity -v -p codesigning`).

**Permissions the app asks for, and why.** Benji works without the ones you decline.

| Permission | Why |
|---|---|
| Microphone, Speech Recognition | Talking: recorded only while you hold the talk key or the mic button, transcribed on this Mac |
| Accessibility | The Right ⌥ talk key, Esc to cancel, and screen control when you ask for it |
| Screen Recording | Screen context and pointing, only when you use the viewfinder or ask a screen question |
| Automation (per app) | AppleScript tasks you ask for; macOS asks the first time for each app, and Benji still asks you |

The first launch opens a small setup window for these. Reopen it from **Settings → Permissions →
Guided setup…**. The menu also shows **Finish Setup…** while a permission is missing.

**Gatekeeper.** An app you build on your own Mac carries no download quarantine mark, so it opens
normally. A copy that is downloaded, AirDropped or unzipped from a download is quarantined, and
because it is not notarised macOS will refuse it ("cannot be verified"). On macOS 15 and later you
approve it in **System Settings › Privacy & Security › Open Anyway**; removing the quarantine mark with
`xattr -dr com.apple.quarantine Benji.app` also works. We have not tested a quarantined copy: build
it on the Mac you run it on.

The app finds the `benji` package from where it was built; set `BENJI_DIR` to point it at a
different checkout. Use the menu-bar icon to **Show / Hide Benji**.

## Using it

- **Talk:** hold **Right ⌥**, speak, release; or tap it once to start and again to send. The key needs
  Accessibility; the mic button in the panel works without it. `defaults write com.emerssive.heybenji.app talkKey
  off` turns the key off.
- **Type:** open the panel and use the composer.
- **Screen context:** the viewfinder button includes the screen with the **next message only**.
- **Command line:** `python3 -m benji "…"` for one task, `python3 -m benji` for a REPL,
  `./benji.sh "…"` through the launcher, `--image shot.png` to attach an image.
- **Persistent mode:** `python3 -m benji --serve` stays running and speaks JSON lines over
  stdin/stdout; the app uses it. The protocol is in [docs/proposal-serve.md](docs/proposal-serve.md).

## Configuration

```bash
export BENJI_PROVIDER=claude   # or openai, deepseek, glm, kimi, qwen, ollama, lmstudio (else detected from the key present)
export BENJI_MODEL=...         # exact model id, if the default is rejected
export BENJI_EFFORT=low        # Claude only: low (default), medium, high, xhigh, max
export BENJI_WORKDIR=~/.benji  # working folder (default ~/.benji)
```

Defaults are `claude-haiku-5-5` and `gpt-4o`, at effort `low`. `BENJI_MODEL=claude-sonnet-5-5`
gives better-assembled 3D figures at roughly twelve times the cost. If your account uses
different ids, set `BENJI_MODEL`.

### Choosing a model provider

Benji's other providers are presets: each sets the address, the key variable and a default model,
and `BENJI_MODEL` and `BENJI_BASE_URL` still override them. Model ids change quickly, so every
default below is just what the provider's own documentation named on 2026-11-05; if one is rejected,
set `BENJI_MODEL` to a current id from the provider's model list.

| `BENJI_PROVIDER` | Key variable | Default model | Data goes to | Reads images (Screen) |
|---|---|---|---|---|
| `claude` (default) | `ANTHROPIC_API_KEY` | `claude-haiku-5-5` | `api.anthropic.com` | yes |
| `openai` | `OPENAI_API_KEY` | `gpt-4o` | `api.openai.com` | yes |
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-flash` | `api.deepseek.com` (its privacy policy says personal data is stored in the People's Republic of China) | `deepseek-flash` yes, `deepseek-v4-pro` no |
| `glm` | `ZAI_API_KEY` (or `ZHIPUAI_API_KEY`) | `glm-5.3-flash` | `api.z.ai` ("generally processed in Singapore", per its policy); `BENJI_REGION=cn`: `open.bigmodel.cn` (China) | `glm-5.3-flash` yes, `glm-5.3` no |
| `kimi` | `MOONSHOT_API_KEY` | `kimi-k3.1-pro` | `api.moonshot.ai` (stored in Singapore, per its policy); `BENJI_REGION=cn`: `api.moonshot.cn` | `kimi-k3.1-pro` yes |
| `qwen` | `DASHSCOPE_API_KEY` | `qwen3.8-flash` | `dashscope-intl.aliyuncs.com` (Alibaba Cloud's Singapore region); `BENJI_REGION=cn`: `dashscope.aliyuncs.com` (Beijing region). Its docs say data is stored in the region you pick and say nothing firmer about where it is processed | `qwen3.8-flash` yes |
| `ollama` | none | name one with `BENJI_MODEL` | `localhost:11434`, your computer | only models whose name says so (`llava`, `-vl`, `vision`, `gemma3`…) |
| `lmstudio` | none | name one with `BENJI_MODEL` | `localhost:1234`, your computer | same |

```bash
export BENJI_PROVIDER=deepseek
export DEEPSEEK_API_KEY=...        # in ~/.benji.env is better than your shell history
python3 -m benji --print-provider # shows the provider, model, host and whether Screen can work, no API call
```

- **Hosted providers are always https.** Plain `http://` is accepted only for `ollama` and
  `lmstudio` on `localhost` or `127.0.0.1` (a custom server may also be a private address, `.local`
  or `.ts.net`). GLM and Kimi also sell "coding plan" subscriptions on separate endpoints that their
  terms limit to their listed coding tools; Benji refuses those endpoints.
- **Regions.** GLM, Kimi and Qwen run an international and a China platform, with separate accounts
  and keys that do not work on the other. `BENJI_REGION=intl` (default) or `cn` picks the platform.
  Alibaba's documentation now prefers workspace-specific hosts
  (`https://<workspace-id>.<region>.maas.aliyuncs.com/compatible-mode/v1`); set that as
  `BENJI_BASE_URL` and the same `DASHSCOPE_API_KEY` is used for it.
- **Thinking.** Several of these models think before answering, which is slow for a voice
  assistant, so Benji asks them not to (`BENJI_THINKING=off`, the default). GLM-5.3 and Kimi K3
  cannot switch thinking off; Benji asks for the lowest effort there instead. `BENJI_THINKING=on`
  asks for more, and `default` leaves the provider's own setting. What a model thinks is never
  shown, spoken or logged.
- **Screen and images.** A model that cannot read images cannot be sent your screen. Benji decides
  from the table above (and a name check for local models); if it says the model cannot, Screen
  stays off for the session and Settings › Screen says why. `BENJI_VISION=1` or `0` overrides the
  table when you know better.
- **Output length.** `BENJI_MAX_TOKENS` (default 8192; 16000 for Kimi) sets the limit sent as the
  provider's own parameter; models that count their thinking against it need room.
- **Rate limits.** A 429 or a 5xx is retried twice with a short wait; a refused balance or quota is
  not, and the message says what the provider said.
- **Pricing and quality differ.** Benji's prompts were written and tried against Claude; other models
  may handle tools, the approval wording or pointing less well. Expect to try a stronger model if
  one misbehaves.
- **Not live-tested by the maintainer.** See [Status](#status) and
  [docs/providers.md](docs/providers.md); `tools/model_smoke.py <provider>` is a five-minute live check
  you can run with your own key.

Open-weight or other models, on any server that speaks the OpenAI Chat Completions format
(OpenRouter, Together, Groq, llama.cpp, MLX, or Ollama / LM Studio at another address):

```bash
export BENJI_BASE_URL=https://openrouter.ai/api/v1   # or http://localhost:11434/v1 (Ollama)
export BENJI_MODEL=...         # required: the model id as that server lists it
export BENJI_API_KEY=...       # that server's key; leave unset for a local server
```

With a Claude model, web search is Anthropic's own: it needs no extra key and runs inside the model
call, at Anthropic's price per search (at the time of writing $10 per 1,000 searches, plus the results as
input tokens), at most three a request. With any other provider, or with `BENJI_WEB_SEARCH=local`,
Benji searches itself: DuckDuckGo with no key, which often blocks automated requests (Benji says
so when it does), so set `BRAVE_API_KEY` or `SERPAPI_KEY` for reliable search. `web_fetch` (reading a
known URL) needs no key.

Prompt caching and streaming are on by default (`BENJI_PROMPT_CACHE=0`, `BENJI_STREAM=0` turn
them off). `BENJI_USAGE_LOG=0` turns the token log off; `benji --usage` summarises it without an
API call.

## Command-line voice (optional)

```bash
python3 -m benji --speak "what's on my calendar today?"   # speak the answer (macOS `say`)
python3 -m benji --voice                                  # speak one task (needs ffmpeg + a transcription key)
python3 -m benji --listen                                 # always-listening loop with a wake word
./voice-setup.sh                                           # optional on-device voice (Kokoro), downloads ~400 MB
```

The app does not need these: it transcribes on-device. `--voice` and `--listen` need `ffmpeg` and
`OPENAI_API_KEY` (Whisper) or `DEEPGRAM_API_KEY`.

## macOS automation, skills and memory

- `run_applescript` drives apps through their scripting (read Calendar, create a Note…);
  read-only scripts run freely, ones that change state or send are gated. `run_shortcut` runs
  a Shortcut by name (always gated). macOS asks for Automation permission per app.
- **Skills** are folders `skills/<name>/SKILL.md` with front-matter (`name`, `description`,
  `when_to_use`) and instructions. Benji sees titles and descriptions and loads a skill's full
  text before using it. Drop in a folder to add one.
- **Memory:** `remember` and `recall` keep durable facts in `<workdir>/memory.jsonl`, one
  human-readable JSON line per fact, never secrets. A short digest is added to the prompt.

## Verify it works (no key needed)

```bash
python3 selftest.py                                        # offline engine checks: tools, gate, providers, jobs, logging
(cd companion && xcrun swift test)                         # unit tests for the app's logic, on a Mac
node --test browser-extension/test/*.test.mjs             # the extension's rules (some run a headless Chrome)
python3 -I companion/ServeCheck/run.py                     # the real app backend against a real engine and a fake model
```

None calls a live model. The page-text test starts Chrome **headless** with a throwaway profile if
Chrome is installed and is skipped otherwise. To keep the tests away from your own Benji data and
keys, run them through `tools/isolated_run.py` as [CONTRIBUTING.md](CONTRIBUTING.md) shows. All of this
is checked on macOS only.

## Layout

```
./
├── README.md, SPEC.md, LICENSE, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md, CHANGELOG.md, THIRD_PARTY_NOTICES.md
├── selftest.py, selftest_*.py   # offline engine checks
├── benji.sh          # launcher (python3 -m benji)
├── skills/            # installed skills (each: <name>/SKILL.md)
├── benji/            # the engine: agent loop, providers, tools and gate, jobs, audit log, browser link, serve
├── companion/         # Benji.app (SwiftPM): BenjiCore (pure logic, tested) + BenjiApp (AppKit/SwiftUI)
├── browser-extension/ # the Chrome extension for browser reach, and its tests
├── demo/              # how to record a real demo safely, in a separate macOS account
├── site/              # the project page, published to GitHub Pages
└── docs/              # design system, decision log, serve protocol, providers, releasing, roadmap
```

## Design system

Benji's design system (name and wordmark, the Exchange icon, colour and type tokens, the notch
object, motion, sound and the pointing overlay) is in [docs/design-system/](docs/design-system/).
The decision log, trimmed for this repository, is [docs/decisions.md](docs/decisions.md).
The original design brief is [SPEC.md](SPEC.md).

## Contributing, security, licence

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md); what changed per version is in [CHANGELOG.md](CHANGELOG.md),
and where it may go next in [docs/ROADMAP.md](docs/ROADMAP.md). Benji is released under the
[MIT licence](LICENSE); third-party credits and licences are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
