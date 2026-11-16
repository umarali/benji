<p align="center">
  <img src="site/assets/benji-app-icon.svg" width="88" height="88" alt="">
</p>

<h1 align="center">Benji</h1>

<p align="center">
  A Mac assistant in your notch that sees your screen, talks, and asks before anything risky.<br>
  Bring your own model.
</p>

<p align="center">
  <a href="https://github.com/umarali/benji/actions/workflows/ci.yml"><img src="https://github.com/umarali/benji/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status"></a>
</p>

<p align="center">
  <a href="https://umarali.github.io/benji/">Website</a> &nbsp;·&nbsp;
  <a href="docs/setup.md">Setup guide</a> &nbsp;·&nbsp;
  <a href="docs/status.md">Feature status</a> &nbsp;·&nbsp;
  <a href="docs/README.md">Documentation</a>
</p>

<p align="center">
  <a href="https://umarali.github.io/benji/#demo"><img src="site/assets/benji-demo-jet-engine.jpg" width="820" alt="Benji in the notch of a Mac: a typed request opens a cut-away jet engine in 3D with its fan, compressor, combustion chamber, turbine and exhaust labelled, while Benji explains it aloud"></a>
  <br>
  <sub><a href="https://umarali.github.io/benji/#demo">Watch it with sound</a></sub>
</p>

> [!NOTE]
> Early software from one maintainer, used on one Mac. There is no signed download yet: you build it
> from source. [Feature status](docs/status.md) says what has been tried live and what has only been
> tested offline.

## What it does

- **Talk or type.** Hold Right ⌥ and speak, or type in the panel. Opening the panel starts
  listening, which you can turn off in Settings › Voice. Speech is transcribed on your Mac.
- **Get things done.** Run commands, read and write files, search the web, and script your apps
  with AppleScript and Shortcuts.
- **See your screen.** A screenshot goes with each message (Settings › Screen: Off, Ask or On).
  Benji can point at the control you need, or click, scroll and type there while you watch.
- **Draw it in 3D.** Ask how something works and Benji builds a labelled model you can turn.
- **Work in the background.** Hand off a longer task; it runs in its own folder while you carry on.
- **Ask before anything risky.** Deleting, sending, buying or writing outside its folder waits for
  your yes. The rules are in code, not only in the prompt.
- **Use your own model.** Claude by default; OpenAI, DeepSeek, GLM, Kimi or Qwen, or a model on
  your own Mac through Ollama or LM Studio.

Benji is a Swift app for the notch, a Python engine with no third-party dependencies, and an
optional browser extension.

## Quick start

You need macOS 14 or later, Python 3.11 or later, and Xcode 26 or later.

```bash
git clone https://github.com/umarali/benji.git
cd benji
python3 tools/isolated_run.py -- python3 -m benji --version   # offline, no key needed
cd companion && ./build.sh && open Benji.app
```

Keep the app inside the checkout: it loads its engine from there. The [setup guide](docs/setup.md)
covers the model key, a first message, and permissions.

## Safety and privacy

- **Rules in code.** Every tool call is checked before it runs. On screen, scrolling, tabs, links
  and menus go ahead while you watch; any step that could send, buy, delete or close something
  asks. After Benji reads a web page, every change it makes asks. Keys, mail, messages and
  browser data are never read without your yes.
- **Nothing of its own leaves your Mac.** No telemetry, no account, no hosted backend. Your
  requests go to the model provider you choose. A model you run yourself keeps the model's work
  on your Mac; web search and fetch still go out.
- **Your history stays on your Mac.** Conversations and the model's answers are saved in Benji's
  folder; the audit log records what ran, never what was said. Keys are never logged.

Details: [safety, background jobs and browser reach](docs/safety.md) · [privacy](docs/privacy.md)
· [reporting a vulnerability](.github/SECURITY.md)

## Documentation

| Guide | What it covers |
|---|---|
| [Setup guide](docs/setup.md) | From a fresh clone to a first message, with troubleshooting |
| [Feature status](docs/status.md) | What is stable, experimental or not yet tried live |
| [How Benji works](docs/architecture.md) | The app, the engine and how they talk; where the code and tests are |
| [Using and configuring](docs/configuration.md) | Features in detail, settings, model providers, voice, skills |
| [Safety, jobs and browser reach](docs/safety.md) | The approval gate, background jobs, the browser extension |
| [Privacy](docs/privacy.md) | What each provider receives and what stays on your Mac |
| [Building from source](docs/building.md) | Requirements, signing, permissions, offline checks, layout |
| [Model providers](docs/providers.md) | Defaults, regions and what has been checked for each |
| [Control Benji from your phone](docs/remote-control.md) | Send tasks from your phone over Tailscale, and answer approvals there |
| [Roadmap](docs/ROADMAP.md) · [Changelog](CHANGELOG.md) | What may come next, and what changed |

## Contributing

Issues and pull requests are welcome: see [CONTRIBUTING.md](.github/CONTRIBUTING.md) and the
[code of conduct](.github/CODE_OF_CONDUCT.md). Report security problems privately, as
[SECURITY.md](.github/SECURITY.md) describes.

Benji is released under the [MIT licence](LICENSE). Third-party credits are in
[THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).
