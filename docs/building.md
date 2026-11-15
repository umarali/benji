# Building from source

How to build and sign `Benji.app`, the permissions it asks for, how to run the checks, and where
things are in the repository. For a first setup, follow [Set up Benji on your Mac](setup.md)
instead: it covers the same build with a key and a first message.

## Requirements

| You need | Notes |
|---|---|
| macOS 14 or later | Apple silicon assumed. The layout is designed for a notched display; other displays are handled but less tested. |
| Python 3.11 or later | Check with `python3 --version`. The engine needs no packages. |
| Xcode 26 or later | The macOS 26 SDK, on a Mac supported by that Xcode release. See [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements). |
| A model | One API key (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or a key for DeepSeek, Z.ai, Moonshot or Alibaba Cloud), or a model running on your own computer. |

Optional: `ffmpeg` and a transcription key for the command-line voice flags; a web-search key for
reliable search; `tools/voice-setup.sh` for an on-device voice (about 400 MB).

## Build from source

There is no notarised download yet ([RELEASING.md](RELEASING.md) has the plan), so you build
`Benji.app` yourself:

```bash
git clone https://github.com/umarali/benji.git
cd benji
python3 tools/isolated_run.py -- python3 -m benji --version   # offline, no key needed
cd companion
./build.sh
open Benji.app
```

- Building and opening the app does not configure a model for you; the setup guide does.
- Keep the app inside this checkout: the engine is loaded from the repository, not bundled inside
  `Benji.app`. Set `BENJI_DIR` to point it at a different checkout.
- If you already run Benji, quit it yourself before opening another copy.
- Use **`xcrun swift`**, not plain `swift`, wherever you run Swift yourself. The `swift` first on
  your `PATH` can be an old standalone toolchain that cannot load this package; `xcrun` picks the
  one in your Xcode. `build.sh` already does.

### Code signing, and why it matters

macOS ties the permissions you grant (Accessibility, Screen Recording, Microphone) to an app's
signing identity. `build.sh` signs the app with a certificate named **"Benji Local Signing"** if
your login keychain has one. To create it:

1. Open **Keychain Access › Certificate Assistant › Create a Certificate…**.
2. Name: `Benji Local Signing`. Identity Type: *Self Signed Root*. Certificate Type: *Code Signing*.
   Create it.
3. Run `./build.sh`. The first `codesign` may ask for your login password; choose **Always Allow**.

Without it, `build.sh` signs **ad hoc**: the app runs, but the signature changes on every build,
so **macOS asks for every permission again after each rebuild**. Set `BENJI_SIGN_IDENTITY` to use
another identity (list yours with `security find-identity -v -p codesigning`).

### Permissions the app asks for

Benji works without the ones you decline.

| Permission | Why |
|---|---|
| Microphone, Speech Recognition | Talking: recorded only while you hold the talk key or the mic button, transcribed on this Mac |
| Accessibility | The Right ⌥ talk key, Esc to cancel, and screen control when you ask for it |
| Screen Recording | Screen context and pointing, only when you use the viewfinder or ask a screen question |
| Automation (per app) | AppleScript tasks you ask for; macOS asks the first time for each app, and Benji still asks you |

The first launch opens a small setup window for these. Reopen it from **Settings → Permissions →
Guided setup…**. The menu-bar icon also shows **Finish Setup…** while a permission is missing, and
**Show / Hide Benji** opens the panel.

### Gatekeeper

An app you build on your own Mac carries no download quarantine mark, so it opens normally. A copy
that is downloaded, AirDropped or unzipped from a download is quarantined, and because it is not
notarised, macOS refuses it ("cannot be verified"). On macOS 15 and later you approve it in
**System Settings › Privacy & Security › Open Anyway**; removing the quarantine mark with
`xattr -dr com.apple.quarantine Benji.app` also works. A quarantined copy has not been tested:
build it on the Mac you run it on.

## Run the checks

None of these needs a key or calls a live model. Run them from the repository root, through
`tools/isolated_run.py`, which gives each run a throwaway home folder so nothing touches your own
Benji folder or keys:

```bash
python3 tools/isolated_run.py -- python3 tests/selftest.py                    # the engine
python3 tools/isolated_run.py -- sh -c 'cd companion && xcrun swift test'     # the app's logic
node --test browser-extension/test/*.test.mjs                                 # the extension's rules
python3 -I companion/ServeCheck/run.py                                        # the app's backend against a real engine
```

The extension's page-text test starts Chrome **headless** with a throwaway profile if Chrome is
installed, and is skipped otherwise. All of this is checked on macOS only.
[tests/README.md](../tests/README.md) says which engine test file covers what.

## Where things are

```
benji/               the engine: agent loop, providers, tools and the approval gate, jobs, audit log, serve
companion/           Benji.app, a SwiftPM package: BenjiCore (logic, unit-tested) and BenjiApp (AppKit, SwiftUI)
browser-extension/   the optional Chromium extension, and its tests
tests/               the engine's offline checks
skills/              skills Benji can load (each one a folder with a SKILL.md)
evals/               the evaluation harness for model behaviour
tools/               the test isolator, the voice setup and other scripts
site/                the project page, published to GitHub Pages
docs/                these pages, the design system and the decision log
```

[How Benji works](architecture.md) explains how the parts fit together. The design system (name,
icon, colour and type tokens, the notch, motion, sound and the pointing overlay) is in
[design-system/](design-system/), and the decision log, trimmed for this repository, is
[decisions.md](decisions.md).
