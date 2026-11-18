# Set up Benji on your Mac

You build Benji from source: there is no signed download yet. This guide takes you from a fresh
clone to a first typed answer. Voice and screen access come later, when you want them.

[Check your Mac](#1-check-your-mac) · [Get the code](#2-get-the-code) ·
[Add a model key](#3-add-a-model-key) · [Build and open](#4-build-and-open-the-app) ·
[First message](#5-send-a-first-message) · [Permissions](#6-add-permissions-when-you-need-them) ·
[Fix a problem](#if-something-stops-you) · [Update](#update) · [Uninstall](#uninstall)

## 1. Check your Mac

You need macOS 14 or later, Python 3.11 or later, and Xcode 26 or later (the full app, not only the
command-line tools). Xcode 26 needs a recent macOS: check
[Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements/).

```bash
python3 --version
/usr/bin/env PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -lc 'python3 --version'
xcodebuild -version
xcrun --find swift
```

Both Python lines should say 3.11 or later. The second one matters because the app starts Python
through a zsh login shell: if it fails while the first works, your Python is set up only in
`~/.zshrc`. Move that setup to `~/.zprofile`.

- No Python, or an old one: install it from [python.org](https://www.python.org/downloads/macos/).
- No Xcode: install it, open it once, then in Xcode › Settings › Locations choose it under
  Command Line Tools.

The engine uses only Python's standard library, so there is nothing to `pip install`.

## 2. Get the code

```bash
git clone https://github.com/umarali/benji.git
cd benji
python3 tools/isolated_run.py -- python3 -m benji --version
```

This prints `Benji` and a version. It runs with a throwaway home folder, needs no key and makes no
model call. Stay in this folder for the next steps.

## 3. Add a model key

Benji reads keys from `~/.benji.env` in your home folder. This creates the file if you don't have
one yet, and opens it:

```bash
if [ ! -e "$HOME/.benji.env" ]; then
  (umask 077; cp .benji.env.example "$HOME/.benji.env")
fi
chmod 600 "$HOME/.benji.env"
nano "$HOME/.benji.env"
```

Put your Anthropic API key after `ANTHROPIC_API_KEY=`, then save (Control-O, Return) and exit
(Control-X). Keep the key out of Terminal commands, screenshots and bug reports.

To use another provider, or a model you run yourself with Ollama or LM Studio, see
[Choosing a model provider](configuration.md#choosing-a-model-provider). A local server must
already be running with a model loaded.

Check what Benji found:

```bash
python3 -m benji --print-provider
```

This shows the provider, model and host without sending anything. It does not check that the key
works; your first message does that. Before you send anything private, read [Privacy](privacy.md):
a hosted provider receives your messages and what the tools return.

**Or use the app instead.** Guided setup ends with a Model step that can save an Anthropic key to
the macOS Keychain or pick a local model. Its **Test** button sends one short fixed request, which
your provider may charge for. Keys in the Keychain are for the app; the command line still reads
`~/.benji.env`.

## 4. Build and open the app

```bash
cd companion
./build.sh
open Benji.app
```

The build ends with a `done` line. Benji's icon appears in the menu bar; choose
**Show / Hide Benji** to open the panel. If another copy of Benji is running, quit it first.

Keep `Benji.app` where it is. It loads its engine from this checkout, so a copy moved to
Applications on its own will not work.

Without a signing certificate the build is signed ad hoc, and macOS asks for permissions again
after each rebuild. To explicitly choose ad-hoc signing without certificate discovery, run
`BENJI_SIGN_IDENTITY=- ./build.sh`. [Code signing](building.md#code-signing-and-why-it-matters) shows how to make a
local certificate once.

## 5. Send a first message

If guided setup opens, you can close it with **Not now**. New installs send a screenshot with every
message, so for this first try set **Settings › Screen** to **Off** (or choose **Send without
screen** if a card asks). Then type:

> Reply with one short greeting. Do not use tools.

An answer in the panel means the key, the model and the app all work. If the provider reports an
error, fix the configuration it names and try again.

Next, ask for something small, such as listing the files in a folder you name. If a card asks
for approval, read it; choose **No** if you didn't expect it.

## 6. Add permissions when you need them

Each feature asks only for what it needs. Reopen guided setup from **Settings › Permissions ›
Guided setup…**; while a permission is missing, the menu-bar icon also shows **Finish Setup…**.
Grant access to **Benji**, not to Terminal.

| To | Grant |
|---|---|
| Type and read answers | Nothing |
| Talk with the mic button | Microphone and Speech Recognition (transcribed on your Mac) |
| Talk with the Right ⌥ key | Accessibility, plus the two above |
| Send your screen with a message | Screen Recording, then relaunch Benji when setup says so |
| Let Benji script an app | Automation for that app; macOS asks the first time |

If Benji is missing from the Accessibility list, guided setup shows an app tile you can drag in.
The [browser extension](../browser-extension/README.md) and the
[command-line voice](configuration.md#command-line-voice-optional) are separate and optional.

## If something stops you

| What you see | What to do |
|---|---|
| `No module named benji` | Run the command from the repository folder (the one that contains `benji/`). |
| An Xcode or SDK error while building | Check `xcodebuild -version` and the Command Line Tools choice in Xcode › Settings › Locations. |
| No API key found | Check `~/.benji.env` in your home folder (a copy in the repository is not read), then run `python3 -m benji --print-provider`. If you moved keys to the Keychain, the app ignores the file: see Settings › General › Your API key. |
| 401 or "authentication failed" | The key is wrong for that provider. Check it in the provider's account. |
| The command line works but the app finds no key | A key exported only in your Terminal does not reach the app. Use `~/.benji.env` or the Keychain. |
| The app uses a different model than the file says | A model chosen in guided setup takes precedence. See Settings › General › Model. |
| The engine fails to start, or finds an old Python | Run the second Python check in step 1 and fix your `~/.zprofile`, then quit and reopen Benji. |
| The app cannot find its engine | Move `Benji.app` back into `companion/` in the checkout. |
| The talk key does nothing | Grant Accessibility, or use the mic button. |
| Screen access still says off | Relaunch Benji after granting Screen Recording. |
| Permissions are asked again after a rebuild | The build was signed ad hoc: see [Code signing](building.md#code-signing-and-why-it-matters). |

For a bug report, run `python3 -m benji --diagnose` or use Settings › General › Diagnostics, read
the report, and [open an issue](https://github.com/umarali/benji/issues/new/choose) with your macOS,
Python and Xcode versions and the step that failed. Leave out keys and private conversation text.

## Update

Quit Benji, then from the repository folder:

```bash
git pull
(cd companion && ./build.sh)
open companion/Benji.app
```

## Uninstall

These steps remove the app and what it registered. Your data stays until you delete it.

1. In Settings › General, turn off **Open Benji at login**. If you used the browser extension,
   turn off Settings › Browser (this removes Benji from every browser), then remove the extension
   on the browser's extensions page.
2. Quit Benji (**Quit Benji** in the menu-bar menu) and delete the checkout folder. The app is
   inside it.
3. Remove Benji from each list in System Settings › Privacy & Security, or run
   `tccutil reset All com.emerssive.heybenji.app`.
4. Remove the app's settings: `defaults delete com.emerssive.heybenji.app`.

Then delete any of these you no longer want:

| Where | What it holds |
|---|---|
| `~/.benji` (or your `BENJI_WORKDIR`) | Conversations, memory, job folders and logs |
| `~/.benji.env` | Your API keys |
| Keychain Access, items named `com.emerssive.heybenji.app.keys` | Your API keys, if you moved them there |
| `~/Library/Application Support/Benji` | The browser link's files |
