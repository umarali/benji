# The rename from Chilly to Benji

Decision: D-178 (2026-11-08). This is the working reference for the cutover. Status lines say what has and has not been tested.

## 1. Technical identifiers

Confirmed by the owner on 2026-11-08, under `emerssive.com`, a domain the owner holds. They don't depend on heybenji.xyz, which is the intended product domain and is not registered or configured. Changing a bundle id later repeats this whole migration and costs every user their macOS permissions again.

| What | New | Was |
|---|---|---|
| Product, call phrase | Benji, Hey Benji | Chilly, Hey Chilly |
| App, executable | Benji.app, Benji | Chilly.app, Chilly |
| Bundle id | `com.emerssive.heybenji.app` | `com.chilly.app` (`com.pal.companion` before) |
| Keychain service | `com.emerssive.heybenji.app.keys` | `com.chilly.app.keys` |
| Native-messaging host | `com.emerssive.heybenji.browser` | `com.chilly.browser` |
| Browser support folder | `~/Library/Application Support/Benji/Browser` | `.../Chilly/Browser` |
| Data folder | `~/.benji` | `~/.chilly`, `~/chilly`, `~/pal` |
| Key file | `~/.benji.env` | `~/.chilly.env` (renamed once), `~/.pal.env` (still read) |
| Python package, CLI | `benji`, `python3 -m benji` | `chilly` |
| Swift | `Benji`, `BenjiCore`, `BenjiApp`, `BenjiCoreTests`, `BenjiAppTests` | `Chilly*` |
| Environment prefix | `BENJI_` | `CHILLY_`, `PAL_` (still read) |
| Protocol sentinels | `BENJI-APPROVE`, `BENJI-EVENT` | `CHILLY-*`, changed on both sides together |
| Extension id | `oifkoajmlonknfkpeecajlncpjbjmfef` (unchanged: the manifest `key` was kept) | same |
| Signing certificate | `Benji Local Signing` for new setups; a Mac that only has `Chilly Local Signing` keeps it (another certificate would reset the permissions) | same |

Kept on purpose: provider variables (`ANTHROPIC_API_KEY` and the rest), audit and file formats, role names, the `migrated_from` marker that
travels with an old store.

## 2. What happens at first launch

In `main.swift`, in order, before anything can write: older environment names get their `BENJI_*` twins; the data folder moves; `~/.benji` is made if
it wasn't; settings are copied; old browser registrations are reconciled. The engine runs the same data-folder rule (`benji/home.py`), and is told
the folder by the app. Both are tested against `companion/Tests/home-migration-cases.json`.

| Situation | What happens |
|---|---|
| `~/.chilly` (or `~/chilly`, or `~/pal`) holds data, no `~/.benji` | One atomic rename. Same inode, so contents, dates, ids and modes are the same files. Folder made 0700. Marker `benji_migrated_from` (kind, source, date). |
| `~/.benji` exists but is empty | It gives way and the real store moves in. |
| Both hold data | `~/.benji` is used; nothing is moved or merged; one line per older store says so, once. |
| A folder merely called `~/chilly` or `~/pal` | Moved only if it holds a sign of the store and isn't a clone of the code. `~/.chilly` is always ours. |
| Old folder is empty (an old build recreated it) | Ignored: no notice, no conflict. |
| Chilly or Benji still running, or the check can't run | Nothing moves; the old folder is used for this run; one line says to quit it. Nothing is killed. |
| `BENJI_WORKDIR`, `CHILLY_WORKDIR` or `PAL_WORKDIR` set | Nothing moves. |
| Rename impossible (engine only) | Copy beside, verify every path, mode, date and hash, then rename. The old folder is kept. An interrupted copy is cleared and redone. |

**Settings.** `com.chilly.app`, then `com.pal.companion`, are copied once into `com.emerssive.heybenji.app`. A value already set in the new domain wins. The old domains are
left alone. Browser switches, per-site grants, the key source and earlier migration markers come across. Permission notes do not.

**Keychain.** Only in Keychain mode. New items first; a key found only under `com.chilly.app.keys` (or an account called `CHILLY_API_KEY`) is read, copied forward under
the new service and name, read back, and left in the old service as the way back. Denied or locked means the engine doesn't start: never a fallback
to a plaintext file. macOS will ask once per item, because the new app has a different identity: choose Always Allow.

**Key files.** `~/.chilly.env` is renamed to `~/.benji.env` once, before the engine starts: the same file, so its contents and private mode are kept and there is never a second copy of a key. If `~/.benji.env` already exists neither is touched and nothing is merged; a working-folder override means it isn't moved at all; while another Chilly or Benji runs it waits. Whatever stays is still read, ranked `~/.benji.env`, `~/.chilly.env`, `~/.pal.env`. Moving a plaintext key to the Keychain stays a button you press; if two lines give different values for one key, it moves nothing and says so.

**Browser.** For a browser you had turned on, the new host is registered and checked before the old manifest is removed. Only manifests naming our own old launcher are
removed. The old `link.json` is deleted, so the old token dies; the engine makes a new one. A browser that was off stays off.

**Voice.** The environment moves with the folder. Once after the move, its scripts are rewritten to name the new path and it is run to prove it works. A
broken one gets one line telling you to run `./voice-setup.sh`, which reuses your files. Nothing is downloaded by itself.

**Old chats and memory** keep their words. A rule in the system prompt says an older mention of Chilly means the assistant, and that it is Benji now.

## 3. Cutover, by the owner, in order

The installed `companion/Chilly.app` runs its engine from this checkout (`python3 -m chilly`), so the package move must not land while it is in use.

1. Commit or set aside the uncommitted work in the main checkout, then apply this candidate there.
2. Quit Chilly. Check nothing remains: `pgrep -fl 'Chilly.app|-m chilly'`.
3. `cd companion && ./build.sh` (without `run`), which builds `Benji.app` against the applied tree.
4. Turn off Chilly's "Open at login" if it was on. Then open `Benji.app`.
5. Grant again: Screen Recording, Accessibility, Microphone, Speech Recognition, Automation. If you use the Keychain, choose Always Allow at each prompt.
6. If you use the browser extension, press Reload on it in `chrome://extensions`. The old code calls the old host name until you do.
7. Turn "Open at login" back on in Benji's Settings if you want it.
8. Try a turn by voice and by typing, and read one old chat.
9. When you are happy, you may remove `companion/Chilly.app` and the old Keychain items.

## 4. Rollback

Quit Benji, then:

```bash
rmdir ~/.chilly 2>/dev/null; if [ ! -e ~/.chilly ]; then mv ~/.benji ~/.chilly; rm -f ~/.chilly/voice_runtime_checked; else echo "~/.chilly has files in it: stop and look"; fi
```

The first step matters: an old build recreates an empty `~/.chilly`, and `mv` onto an existing folder would nest the store inside it. If the folder has files, stop and decide what to keep.

Move the key file back too, or the old build won't find your key: `[ -e ~/.benji.env ] && [ ! -e ~/.chilly.env ] && mv ~/.benji.env ~/.chilly.env`.

Rebuild or reopen Chilly from a checkout that still has `chilly/`. The old settings domain and old Keychain items were never changed. After a copy-fallback move the old folder is still there, so don't run the folder command above; still run the key-file command, then reopen Chilly. If the voice was repaired during the move, its `pip` and `activate` scripts name `~/.benji`; the voice itself still works, and `./voice-setup.sh` rewrites them. Settings changed in Benji since the move stay in Benji's domain.

The old build after a move: it finds nothing to move, recreates an empty `~/.chilly`, and doesn't touch `~/.benji`. Benji ignores that empty folder.

## 5. Old names that remain

A maintainer check fails if an old name in maintained source has no stated reason, and it lists them all. In short: upgrade aliases, the folders
and services read during migration, private-path and secret rules, the signing certificate's real label, the repository's real address, tests of the upgrade, dated
implementation-note names used as provenance, and the frozen `PalBar`. Logs, decisions, research and recorded evals keep the words they were written in.

## 6. Not done here: separate owner actions

Domain purchase and DNS, publishing, renaming the GitHub repository or its remote, deployment, certificate or account changes, commits, pushes, trademark clearance, and
replacing the installed app.
