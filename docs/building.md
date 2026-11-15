# Building from source

What you need, how to build and sign `Benji.app`, the permissions it asks for, the offline checks, and how the repository is laid out. For a first setup, follow [Set up Benji on your Mac](setup.md) instead.

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

There is no notarised download yet (see [RELEASING.md](RELEASING.md) for the owner's plan), so
you build Benji.app yourself.

For the complete walkthrough, including where to put a key and how to start without voice or
screen permissions, follow [Set up Benji on your Mac](setup.md).

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

## Verify it works (no key needed)

```bash
python3 selftest.py                                        # offline engine checks: tools, gate, providers, jobs, logging
(cd companion && xcrun swift test)                         # unit tests for the app's logic, on a Mac
node --test browser-extension/test/*.test.mjs             # the extension's rules (some run a headless Chrome)
python3 -I companion/ServeCheck/run.py                     # the real app backend against a real engine and a fake model
```

None calls a live model. The page-text test starts Chrome **headless** with a throwaway profile if
Chrome is installed and is skipped otherwise. To keep the tests away from your own Benji data and
keys, run them through `tools/isolated_run.py` as [CONTRIBUTING.md](../CONTRIBUTING.md) shows. All of this
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
object, motion, sound and the pointing overlay) is in [design-system/](design-system/).
The decision log, trimmed for this repository, is [decisions.md](decisions.md).
The original design brief is [SPEC.md](../SPEC.md).
