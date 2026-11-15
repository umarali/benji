# Recording a real demo of Benji, safely

This folder is for the **owner** (the person whose Mac it is) who wants to record a short, honest demo of
the real app. The idea is simple: run Benji in a **separate, standard (non-admin) macOS user account**,
with invented files and a spending-capped key, so that a mistake, a surprising model or a hostile web
page during the recording can reach very little of your own account.

> **This reduces risk. It does not guarantee safety.** Read [What this protects against, and what it
> cannot](#what-this-protects-against-and-what-it-cannot) before you start.

It is generic: nothing here names a person, a machine or a path. Every script takes names from you
at run time.

## The rule for what you record

Only the **real app, on a real Mac, on its own screen, recorded live by you.** No synthetic or mocked
screens, no generated or composited footage, no clips edited to look like something that did not happen.
If a take goes wrong, show it going wrong or record again.

## What is in this folder

| File | What it is | Run by |
|---|---|---|
| [hardening-checklist.md](hardening-checklist.md) | Commands that tighten **your own** account (home folder to 700, secret folders, shared places, a spend-capped key, what to turn off) | You, in your own Terminal |
| `check-isolation.sh` | Read-only checks, run **inside the demo account**: can it get to your files? Every check must say PASS | You, in the demo account |
| `seed.sh` | Creates invented working files in the demo account's own home, and nothing else | You, in the demo account |
| [RUNSHEET.md](RUNSHEET.md) | The roughly three-minute live script: tasks in order, what to say, what the screen shows, what to do if it fails | You |
| [same-account.md](same-account.md) | Recording in **your own** account instead: no permissions change, so Benji starts empty and you keep the screen clean. Less protection than a separate account | You |
| `profile.sh` | For that route: opens Benji on an empty scratch folder (`start`, through `BENJI_WORKDIR`) so your memory, conversations, jobs and logs are not in the recording, and names that folder after (`finish`). Moves, copies and deletes nothing | You, in your own account |

## Step by step

Steps marked **OWNER (admin)** need an administrator on this Mac, and a session cannot do them for you
(creating accounts, changing privacy permissions). Do not enter an administrator password while the
screen is being recorded.

1. **Harden your own account.** Work through [hardening-checklist.md](hardening-checklist.md), steps 1 to
   7, in your own Terminal. This is mostly `chmod 700 ~` and looking at what is readable.
2. **OWNER (admin): create the demo account.** System Settings › Users & Groups › Add User…. Account type
   **Standard** (not Administrator). Full name "Benji Demo". Give it a password you will remember. Do not
   sign it in to iCloud or an Apple ID. Confirm it is Standard (checklist step 8).
3. **Get Benji into the demo account.** Benji needs the repository and a built `Benji.app`.
   - Log in as the demo user and follow [the setup guide](../docs/setup.md), steps 1, 2 and 4: check
     Python and Xcode, `git clone` the public repository into the demo account's home folder, run the
     offline check, then build. The build needs the full Xcode named in the guide, not only the
     command-line tools, and the Xcode licence must have been accepted once by an administrator.
   - Build **once** in the demo account. That account has no "Benji Local Signing" certificate, so the
     build is signed ad hoc, and an ad-hoc app **loses its permission grants every time it is rebuilt**.
     Build, grant permissions (next step), and do not rebuild until after the take.
4. **OWNER (admin): grant the permissions in the demo account.** Log in as the demo user, open
   `Benji.app` (menu-bar icon › **Finish Setup…**, shown while a permission is missing) and allow Microphone, Speech Recognition,
   Accessibility and Screen Recording. In a standard account macOS asks for an **administrator's**
   name and password for some of these (typically Accessibility and Screen Recording): enter it
   **before** you start recording, never during. The screen recorder (⇧⌘5) also needs Screen Recording
   permission for the demo user; that is the same kind of step.
5. **Put the demo key in, by hand.** Inside the demo account, create and open `~/.benji.env` with the
   commands in [step 3 of the setup guide](../docs/setup.md#3-choose-a-model), then type the
   spend-capped demo key you made in the checklist (step 5). Do not paste it from your own account.
6. **Seed the invented files.** Inside the demo account, from this folder: `bash seed.sh`. It refuses
   to run as an administrator or outside the account's own home, and it writes only `~/BenjiDemo` (or, with `--in-benji-home`, `~/.benji/demo/BenjiDemo`).
7. **Run the isolation check.** Still inside the demo account, from this folder:
   `bash check-isolation.sh <your-own-username>` (your short user name, the one in `/Users/`).
   Every line must say PASS. On any FAIL, **stop the demo**: log out, fix it on your own account
   (checklist), log back in and run it again. The check prints no file contents and no other account's
   name, so it is safe to show.
8. **Optional, the browser.** If you will show browser reach, set it up *now*: in the demo account,
   install Chrome, turn on Benji's Settings › Browser, load the extension from `browser-extension/` unpacked
   (README there), and Allow it. Use a Chrome profile with no sign-in. Check Settings › Browser says
   **Connected**. Skip it if any of this is a hassle: it is not live-tested yet.
9. **Log out of your own account** (Apple menu › Log Out) so nothing of yours is running, then log in as
   the demo user. (Fast user switching keeps your own apps running in the background: see below.)
10. **Record, following [RUNSHEET.md](RUNSHEET.md).** Use macOS's own recorder (⇧⌘5) inside the demo account.
11. **Clean up** (checklist step 10): revoke the demo key; delete the demo account or its files; remove
    anything left in `/Users/Shared`; review the recording before you share it.

## What this protects against, and what it cannot

**What it reduces:**

- Benji, or a model Benji was talking to, reading or changing **files in your own account** by mistake
  or on a page's instruction. Another account cannot open a home folder at mode 700, and the isolation
  check proves it for the places that matter, before you record.
- **Your keys, browser sessions and personal files appearing on screen**: they are not in the account
  being recorded.
- **Your own apps' notifications and previews** appearing on camera, if you log out of your account.
- Damage being **permanent**: the demo account's files are invented and can be deleted with it.
- A **runaway bill**, because the only key in the account is capped.

**What it cannot protect against:**

- **A macOS bug**, a sandbox or permission bypass, or a privilege escalation. A standard account is a
  boundary the operating system enforces; it is not a guarantee.
- **The demo account's own internet use.** Everything Benji does there that touches the network
  happens: the model provider receives the prompts, tool results and screenshots from the demo account; web
  pages it reads are real; a page it reads is real input.
- **The API key in that account.** Anything running as the demo user can read it. The spend cap, a new key
  just for this, and revoking it afterwards are the only protection.
- **Anything you place in that account.** Files you copy in, a clipboard you paste from, a login you
  enter, an iCloud or browser sign-in: they are exposed to Benji there, and they are on the recording.
- **Your approval clicks.** A Yes on a card lets Benji do that thing *as the demo user*. The cards exist
  to be read.
- **Your own account still running.** With fast user switching (switching users without logging out),
  your apps and any background agents keep running in the background. Log out of your account instead.
- **Shared and system-wide places**: `/Users/Shared`, `/tmp`, mounted drives and network shares, files
  readable by everyone elsewhere on the disk, and Time Machine or other backup software that reads all accounts.
- **The recording.** It shows exactly what is on screen, including a notification, a name or a key you
  forgot.
- **The check itself.** `check-isolation.sh` asks whether access *is allowed*; it does not and cannot
  prove nothing else is exposed. It also leaves one line in the system log when it tries `sudo -n`.

## What the scripts will never do

- `check-isolation.sh` never opens, lists or prints the contents of any file or folder, writes nothing, and
  runs only permission checks and exit codes.
- `seed.sh` writes only inside `~/BenjiDemo` (or, with `--in-benji-home`, `~/.benji/demo/BenjiDemo`) in the demo account's own home, refuses to run as an
  administrator or with a different `HOME`, and never deletes or overwrites anything.
- Neither names a person, machine or path. Both are checked by this repository's `selftest.py`.
