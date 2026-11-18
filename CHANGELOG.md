# Changelog

Notable changes to Benji. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/) with the pre-1.0 meaning described in
[docs/RELEASING.md](docs/RELEASING.md). Each feature carries its label from
[Feature status](docs/status.md): **Stable**, **Experimental** or **Not live-tested**.

## [Unreleased]

### Added

- **Phone control** (Settings › Phone, off by default): send text tasks from your phone's browser
  over your own Tailscale network, follow them, stop them and, unless you turn it off, answer
  their approvals. *Experimental.* See [Control Benji from your phone](docs/remote-control.md).

### Fixed

- Browser control signatures bind to the listed DOM node and safety fields. Controls are checked
  again after debugger setup and hover, and typing checks the focused field. Ordinary expanded
  and checked state changes remain usable. These checks do not make validation and input atomic.
- Ending a browser job closes only tabs that job opened. Update the engine and extension together:
  the new extension refuses opens from an older engine that supplies no job owner.
- Web fetch connects only to validated public DNS answers, including redirects. It now bypasses
  environment proxies so they cannot independently resolve an unchecked destination.

- Outside content a conversation read keeps making changes ask after the engine restarts, after
  you reopen the conversation, and after you cut off a spoken answer.
- With keys in the Keychain, macOS no longer asks for the keychain password on most actions:
  Settings counts the keys by name instead of reading them.
- On a narrow panel, the approval and screen cards no longer push the panel past its edges.

## [0.1.0] - not yet released

The first public version. It is **early software**: used on one Mac (Apple silicon, notched
display) against Anthropic's API. There is no signed or notarised download; you build it from source.

### Added

- **The notch app** (SwiftPM, macOS 14+): typed and spoken requests (hold Right ⌥), on-device
  transcription, spoken answers, saved conversations, permission setup and settings. *Stable.*
- **The engine** (Python, standard library only): a tool-use loop with shell, files, web search and
  fetch, AppleScript, Shortcuts, skills and a small memory; command-line use and `benji --serve`
  for the app. *Stable.*
- **The approval gate, in code**: destructive commands, overwrites, sends, and reads and writes
  outside the working folder ask first; file tools refuse private locations and the shell asks;
  after a turn reads outside content, anything it changes asks, and so do the turns after it. *Stable*; the most recent refinements are *not live-tested*.
- **Screen context and drawing**: a screenshot with each message (Off, Ask or On), pointing with rings
  and regions, explanation cards and 3D figures. *Stable* with Claude. Worked figure examples,
  added when you ask to draw something, are *experimental*.
- **Background jobs**: one at a time, in their own folder, behind the same gate; approvals wait as
  *Needs you* and are answered only by the job's own buttons. *Experimental.* Repeating jobs,
  Continue and the brief built from the conversation are *not live-tested*.
- **Browser reach** through an optional extension: a job reads, and with a second yes acts on, only
  the sites you granted it; uploads and anything that sends, pays, posts or deletes always ask.
  *Not live-tested.*
- **A metadata-only audit log** that cannot hold message text, and `benji --diagnose`. *Experimental.*
- **Model providers**: Claude (default, *stable*); OpenAI, DeepSeek, GLM, Kimi, Qwen, Ollama and
  LM Studio (*not live-tested*; `tools/model_smoke.py` is a live check for your own key).
- **Smaller features**, all *not live-tested*: app offers (off by default), keys in the macOS
  Keychain, a local policy file that can only switch tools off, and sound cues for jobs (off by
  default).

### Security

- API keys are sent only to their provider's own host; plain `http://` is refused except to your
  own computer, or to a custom server on a private address or a `.local` or `.ts.net` host.
- Log files are written readable by you only.

### Known limits

- No notarised build and no installer. A self-built app signed ad hoc loses its permissions on
  every rebuild (see [Building from source](docs/building.md#code-signing-and-why-it-matters)).
- Jobs are stopped by quitting Benji and do not resume; one job at a time.
- Browser reach has never been used in a real browser profile, and a site with an international
  domain name cannot be granted.
- Only one Mac, one macOS version and one display setup have been tried.

[Unreleased]: https://github.com/umarali/benji/commits/main
[0.1.0]: #010---not-yet-released
