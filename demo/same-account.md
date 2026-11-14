# Recording the demo in your own account

The safer route is a separate demo account ([README.md](README.md)). If you record in your own account
instead, no file or folder permissions change, so nothing stops Benji from seeing your files. Two things
keep the recording clean instead: Benji starts empty, and you control everything that is on screen.

## What could show, and what covers it

| What could leak | Where it comes from | What covers it |
|---|---|---|
| Your name, projects, past topics | Benji's memory and recent conversations are part of every prompt, and the model may say them aloud; the panel lists recent conversations | `profile.sh start` before you record |
| Old jobs, outputs, logs | `~/.benji` | the same: the demo run uses a scratch folder instead |
| Anything on the screen | each turn with screen context sends a screenshot of the whole display, and the model may read out what it sees | a clean desktop (below) |
| Your files | Benji can ask to read anything outside its folder; private places such as `~/.ssh` are refused in code | answer **No** to every card that names somewhere other than `~/BenjiDemo` |
| Notifications, menu bar, Dock, Finder sidebar | macOS | Focus and the checklist below |
| Your Chrome profile | the browser step | skip the browser step |
| Your account name | every card shows the full path (`/Users/<you>/BenjiDemo`), and an answer may quote one | cannot be avoided on this route: accept it, or blur it when you edit |

## Before

1. Quit Benji (its menu-bar icon, then Quit).
2. `bash demo/profile.sh start` makes an empty scratch folder, `~/.benji/demo/run-<time>`, and opens Benji on
   it (`BENJI_WORKDIR`, the one switch that says where Benji's folder is). Your real `~/.benji` is not
   moved, copied, read or changed. Benji then has no memory, no recent conversations and no jobs. (Before
   D-175 this step moved your folder aside and back; it no longer does.)
3. `bash demo/seed.sh --same-account` creates `~/BenjiDemo` with invented files. It stops if that
   folder already exists, and never deletes or overwrites anything. To keep the home folder clean, add
   `--in-benji-home` and the files go to `~/.benji/demo/BenjiDemo` instead (the run sheet then asks
   about "the BenjiDemo folder in Benji's folder", and the card will show that path).
4. Clean the screen:
   - make a new desktop (Mission Control, +) with a plain wallpaper and no windows, and record only there;
   - close every other app; turn on Do Not Disturb;
   - hide the Dock (⌥⌘D); leave only the menu-bar items you need;
   - move the files on your desktop into a folder for now, or use Finder's View › Hide Desktop Icons
     where your macOS has it;
   - in Finder windows on camera, hide the sidebar (⌥⌘S), which shows your account name.
5. Your own key in `~/.benji.env` is fine, as it is never shown. Set a spend limit for it in the
   Anthropic console first.
6. The Benji that `profile.sh start` opened is the one to record. The expanded panel's RECENT list should be empty. If it isn't, stop: it was not opened on the scratch folder (quit it and run step 2 again).

## While recording

A rehearsal against the real engine (2026-11-06, typed, no screen or voice) went as the run sheet says: one card for
`~/BenjiDemo`, the job asking twice in its row (the read, then the write into its own folder), 391 at once
while the job worked, and No on the Desktop write leaving no file. The answer to that No named
Benji's folder by its full path, your account name included.

- Follow [RUNSHEET.md](RUNSHEET.md), but **skip task 5** (the browser).
- Click **Yes** only on a card that names `~/BenjiDemo` or Benji's own folder. Anything else: **No**.
- If Benji says something personal, stop and record again; don't cut around it.

## After

1. Quit Benji, then `bash demo/profile.sh finish`. It only tells you where the demo's own files are
   (`~/.benji/demo/run-<time>`): look, then delete that folder yourself. Your own files were never touched.
2. Delete `~/BenjiDemo` yourself when you are done with it.
3. Before you share the recording, watch it once at full size: the menu bar, any notification, every
   card, and every word Benji says.
