# Set up Benji on your Mac

Check that the engine starts offline, then build the app. Once you choose a model,
you can try a typed message and add voice or screen access when you need them.

Benji is early software. There is **no signed or notarised download yet**. This guide uses
Terminal to build the app from source, for developers comfortable with that workflow. The maintainer
uses an Apple silicon Mac; other Macs and displays have not had the same live checks. See the [feature status](status.md).

[Check your Mac](#1-check-your-mac) · [Get the code](#2-get-the-code-and-run-an-offline-check) ·
[Choose a model](#3-choose-a-model) · [Build and open](#4-build-and-open-the-app) ·
[First message](#5-try-one-typed-message) · [Permissions](#6-add-permissions-when-you-need-them) ·
[Fix a problem](#if-something-stops-you)

## 1. Check your Mac

You need Python 3.11 or later and Xcode 26 or later. Benji targets macOS 14 or later,
but **building it requires a Mac that can run your Xcode version**. Check
[Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements/) before
installing Xcode. The command-line tools alone are not the documented build setup.

Open Terminal and run:

```bash
python3 --version
/usr/bin/env PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -lc 'command -v python3; python3 --version'
xcodebuild -version
xcrun --find swift
```

Check that both Python checks report at least 3.11 and Xcode at least 26.
The app starts its engine through a non-interactive zsh login shell. The second command
checks that kind of shell from a minimal PATH, so an export in your current Terminal
does not hide missing login-shell setup. It is a diagnostic, not a test of the app itself.
If you use a Python version manager, make Python available in the login-shell PATH,
for example through `~/.zprofile`, rather than only `~/.zshrc`.
See [zsh's startup-file rules](https://zsh.sourceforge.io/Doc/Release/Files.html).

If Python is missing or too old, install a supported Python from [python.org](https://www.python.org/downloads/macos/).
If Xcode is missing, install it, open it once and finish its setup. In Xcode Settings →
Locations, select the installed Xcode under Command Line Tools, then run the checks again.

The Python engine uses the standard library. You do not need `pip install` for typed requests.
Voice extras and the browser extension can wait.

## 2. Get the code and run an offline check

If you already have a checkout, use that folder instead of cloning over it.
Otherwise choose a folder where you want to keep Benji's source, then run:

```bash
git clone https://github.com/umarali/benji.git
cd benji
python3 tools/isolated_run.py -- python3 -m benji --version
python3 tools/isolated_run.py -- python3 -m benji --diagnose
```

The version check should print `Benji` and a version number. The diagnostics command runs
with an empty temporary home, so `events.jsonl: not found` is expected. These are real
engine commands. They prove Python can start Benji and produce a report, **not that a
model has answered**. They need no key, make no model call and request no Mac permissions.

Keep this Terminal in the repository folder for the next step.

## 3. Choose a model

For a first typed message without granting permissions, configure the engine's existing
key file. Benji reads this file from your home folder, not from the repository.

Run this from the repository folder. It creates the file only if it does not already exist:

```bash
if [ ! -e "$HOME/.benji.env" ]; then
  (umask 077; cp .benji.env.example "$HOME/.benji.env")
fi
chmod 600 "$HOME/.benji.env"
nano "$HOME/.benji.env"
```

For Anthropic, put your API key after `ANTHROPIC_API_KEY=` in the editor. Do not put it in a
Terminal command, a screenshot or a bug report. Save with Control-O, press Return, then
exit with Control-X. Use a key from your provider's API account.

For another provider or a model you already run locally, use the settings in
[Choosing a model provider](configuration.md#choosing-a-model-provider). Local servers must
already be running with a model loaded. Benji does not install or download a model for you.
Those provider integrations are not live-tested; the README gives the evidence for each.

Now check the selected destination:

```bash
python3 -m benji --print-provider
```

This prints provider, model and destination metadata, without making a model request. A
successful result means Benji found configuration, not that the key is valid or the server
is reachable. Environment variables override file settings, so this reports the configuration
seen by your Terminal. For the app, use the file or its Keychain setup, not a key exported
only in your current Terminal. A hosted provider receives your messages and tool results when you send a
request. Read [Privacy](privacy.md) before sending private material.

### If you prefer the app's key form

The source version also has a Model step in its guided setup. It can save an Anthropic
key to the macOS Keychain or select an existing local model. Saving an Anthropic key
selects Anthropic and switches the app to Keychain mode for all keys. Read the disclosure
before saving; existing file keys may be moved. The standalone CLI does not automatically
use the app's Keychain configuration.

In [public source commit 0c40144](https://github.com/umarali/benji/tree/0c4014443eb15a2ef735f778d6176a3ef994aac0),
the editable Model step appears after the earlier permission
steps have advanced. "All steps" shows the checklist, not the model editor. Use the file
route above if you want to leave permissions off. You can close setup with **Not now**.

Opening model setup checks configuration. **Test** sends a small real request to the
displayed model and may incur provider charges. It sends the fixed connection-test text,
without your conversation, files or screen. "Not tested here" is not a successful test.

## 4. Build and open the app

From the repository folder:

```bash
cd companion
./build.sh
open Benji.app
```

The build should finish with a `done` line naming `Benji.app`. If it fails, stop and use the
troubleshooting table below. Opening the app should add Benji's icon to the menu bar.
Choose **Show / Hide Benji** to open the panel. If you already run another copy, quit it
yourself before opening this one.

Keep `Benji.app` in `companion/` and keep the repository. The app loads its Python engine
from this checkout; copying just the app to Applications is not a complete installation.
`build.sh` uses `xcrun swift` to select Xcode's Swift toolchain.

The build uses a local signing certificate if one exists, otherwise an ad hoc signature.
Ad hoc rebuilds can make macOS ask for permissions again. You do not need to create a
certificate for the first typed message. See the README's
[code-signing instructions](building.md#build-from-source) if you rebuild regularly.

## 5. Try one typed message

This is a **user-run live check**, not an offline demo. The earlier checks did not perform it.

Close guided setup with **Not now** if you are leaving permissions off. New installs send a
screenshot with every message, so set **Settings › Screen** to **Off** first (or choose **Send
without screen** if a card asks). Open the panel from the menu-bar icon and type:

> Reply with one short greeting. Do not use tools.

Send it once. A successful check is a visible answer in the conversation. The wording may
vary. If an unexpected action asks for approval, choose **No**. If the provider reports an
error, use that error to fix the configuration before trying again.

This tests typed input, the configured model and the reply path. It does not verify voice,
screen access, app control or background jobs. Your request goes to the model you chose.

## 6. Add permissions when you need them

Use the menu-bar icon → **Settings… → Permissions → Guided setup…** to reopen setup. The menu-bar icon also
shows **Finish Setup…** while a permission is missing. Grant access to **Benji itself**, not Terminal. The app reports what macOS has granted; declining a
permission leaves its related feature unavailable.

| What you want to try | Permission or setup |
|---|---|
| Type and read an answer | Model configuration. No microphone or screen access needed. |
| Speak using the mic button | Microphone and Speech Recognition. Transcription is on-device. |
| Use the Right Option talk key | Accessibility, as well as the voice permissions. |
| Include your screen with a message | Screen Recording. Settings › Screen chooses Off, Ask or On. |
| Ask Benji to script another app | Automation for that app. macOS asks when the task needs it. |

For Accessibility, guided setup opens System Settings and offers an app tile to drag into
the list if Benji is missing. For Screen Recording, follow the relaunch instruction after
enabling it. The small Accessibility helper window has offline checks; its native interaction on other
Macs is not verified. The [status table](status.md) records these limits.

The [browser extension](../browser-extension/README.md) and
[command-line voice extras](configuration.md#command-line-voice-optional) are separate optional
setups. Neither is needed for the first message.

## If something stops you

| What you see | What to check next |
|---|---|
| `No module named benji` | Run the Python command from the repository folder, which contains `benji/`. Keep the app beside its source checkout. |
| Xcode or SDK error during the build | Recheck `xcodebuild -version` and the Command Line Tools selection in Xcode Settings. Use `xcrun swift`, not a standalone `swift` from another installation. |
| No API key found | Edit the home-folder `.benji.env`, save it, then run `python3 -m benji --print-provider` from the repository. A file beside the code is not loaded. If Keychain mode was selected, file keys are ignored. Check Settings → General → Your API key and use that configured storage. The standalone CLI does not read the app's Keychain. |
| Provider says 401 or authentication failed | Check the key in the provider's account and the selected provider. Detection alone does not validate a key. Never include the key in an issue. |
| CLI works but the app cannot find a key | A key exported only in the current Terminal is not reliable app configuration. Use the home-folder file or the app's Keychain setup. Shell startup settings can also override the file. |
| CLI works but the app uses another model | A source selected in guided setup takes precedence over provider settings in the file. Check the app's Settings → General model-source information. Quit and reopen the app after changing file configuration. |
| App opens but the engine fails or finds an old Python | Run the login-shell Python check in step 1. Put your Python installation or version manager on the login-shell PATH, for example in `~/.zprofile`. A setup only in `~/.zshrc` does not normally reach the app's non-interactive shell. Quit and reopen Benji after changing it. |
| App opens but cannot find its engine | Restore the app to `companion/` inside the checkout. Moving only `Benji.app` does not move the engine. |
| Talk key does nothing | Check Accessibility, or use the panel's mic button with voice permissions. Typed input remains available. |
| Screen access still says off | Follow the setup relaunch instruction after enabling Benji in System Settings. |
| Permissions were lost after a rebuild | Check whether the build was signed ad hoc. See the signing instructions linked above. |
| macOS blocks a downloaded copy | This guide supports building on your own Mac. There is no notarised download; do not treat a shared app bundle as a supported installer. |

For a bug report, run `python3 -m benji --diagnose` from the repository folder, or use
Settings → General → Diagnostics. Review the report before sharing it. Include your macOS,
Python and Xcode versions and the step that failed. Do not attach keys or private conversation
text. [Open a bug report](https://github.com/umarali/benji/issues/new/choose).

## Uninstall

These steps remove the app and what it registered, and keep your data until you choose to delete it.

1. In Settings › General, turn off **Open Benji at login**. If you used browser reach, turn off
   Settings › Browser, which removes Benji's registration from every browser, then remove the
   extension on the browser's extensions page.
2. Quit Benji from the menu-bar icon (**Quit Benji**), then delete the checkout folder. The app is
   inside it.
3. To remove the permissions you granted, remove Benji from each list in System Settings › Privacy
   & Security, or run `tccutil reset All com.emerssive.heybenji.app`.
4. To remove the app's settings: `defaults delete com.emerssive.heybenji.app`.

Your data is still on your Mac after these steps. Delete these only if you no longer want them:

| Where | What it holds |
|---|---|
| `~/.benji` (or your `BENJI_WORKDIR`) | Conversations, memory, job folders and logs |
| `~/.benji.env` | Your API keys |
| Keychain Access, items named `com.emerssive.heybenji.app.keys` | Your API keys, if you moved them to the Keychain |
| `~/Library/Application Support/Benji` | The browser link's private files |
