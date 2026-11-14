# Run sheet: a three-minute live demo of the real app

Everything here is the real Benji on a real Mac, recorded live by you in the demo account, with its
own screen. No synthetic screens, no generated clips, no mock-ups: if a moment fails, the recording
shows it failing, and you either use the honest take or record again. About three minutes if nothing
goes wrong; plan for a second take.

Before you start: the demo account is set up, `check-isolation.sh` said PASS, `seed.sh` has run, Benji is
built and its permissions are granted (all in [README.md](README.md)), the demo key is in the demo
account's `~/.benji.env`, Do Not Disturb is on, and your own account is logged out. Start the screen
recording with **⇧⌘5** (macOS's built-in recorder) and choose the whole screen or the notch area.

What to expect is written as ranges, not promises: a model's wording varies, and a card may ask once
or twice. If a card is not what the sheet says, **read it, and answer No** unless you understand it.

## Opening (0:00–0:35)

- **0:00 Say:** "This is Benji. It lives in the notch of a Mac. This is a fresh account with made-up
  files." **Screen:** the notch, calm, then the open panel. One breath. Do not read any key or path aloud.
- **0:15 Hold Right ⌥ and ask:** "What files are in the BenjiDemo folder in my home folder?" **Screen:** the
  notch listens, then answers aloud and in the panel, naming `budget.csv`, `sales-q3.csv`, `README-first.txt`,
  `notes`, `receipts`, `bakery-site` (it may also mention the hidden marker file `.benji-demo-seed`).
  That folder is outside Benji's own working folder, so expect a **card** first, for `~/BenjiDemo`. That is
  worth showing: "it asks before reading outside its own folder." Click **Yes** (it is invented data).
  Say "in my home folder": asked only "my BenjiDemo folder", the model first asked to search the whole
  home folder (rehearsal, 2026-11-06). If a card ever names your whole home folder, click **No**; it then
  asks for the folder itself.

## The tasks, in order

### 1. A job in the background (0:35–1:10)

**Type** (in the panel): *In the background, read the budget file in my BenjiDemo folder and write a
three-line summary of where we overspent to a file called budget-summary.txt.*

- **Say:** "I'll hand this to a background job and carry on."
- **Screen:** a short peek, "Starting … · Esc cancels"; then a **row** above the conversation with a state
  and a changing line. Expect it to reach a card in the row ("Needs you") for the read outside its own
  folder and perhaps again for the write. These **wait for you**; nothing answers them but the row's own
  Yes/No buttons.
- **Do:** leave the row open and go on to task 2 while it works. When it shows **Needs you**, say "It stops and
  waits for me; it can't carry on without a click", read the one line it shows, then click **Yes** for the
  read of the invented budget file. Answer a write into its **own** job folder with Yes; anything else, No.
- **If it fails:** no row at all means jobs are off or the engine did not start: stop the take, quit Benji,
  check Settings and `defaults read com.emerssive.heybenji.app backgroundJobs` (it must not be 0), and start again.
  A row that says **Failed** with a plain reason is an honest result: say so and go on.
- **Stop it safely:** Esc during the first 2.5 s cancels with no model call; after that the row's **Stop**.

### 2. You are not blocked (1:10–1:25)

While the job is working, **hold Right ⌥**: "What is seventeen times twenty-three?"

- **Screen:** an answer straight away (391) while the job's row keeps working.
- **If it fails:** a long wait means a turn is stuck: say so, press Stop on the row, ask again.

### 3. A gated write, answered No (1:25–2:00)

**Type:** *Write a file called hello.txt on my Desktop that says hello.*

- **Say:** "Writing outside its own folder is something it must ask about."
- **Screen:** a **card** naming the action and the place. **Do:** click **No**. Say "No means no, and it
  carries on without it."
- **Check on camera (optional):** in Finder, the Desktop has no `hello.txt`.
- **If it fails:** if it writes without a card, **stop the recording and quit Benji**: that is a bug
  worth an issue, not a demo (see below). If the card names something you did not ask for, click No.

### 4. The job finishes (2:00–2:20)

- **Screen:** the row turns **Done**; its spoken or written line appears; open the row: the file
  (`budget-summary.txt`) and a chip or two. Click the file: Finder **reveals** it (it is not opened).
- **Say:** "It wrote its report and told me what it made."
- **If it is still working:** carry on with task 5 and come back; do not wait on camera for more than ten
  seconds. A job that fails or is stopped is a fine thing to show.

### 5. Browser, only if you have set it up beforehand (2:20–2:40, otherwise skip)

Only if the Benji extension is already loaded in the demo account's Chrome (no sign-in), Settings ›
Browser is on, and it showed **Connected** before you started. **Do not set it up on camera.**

**Type:** *In the background, open https://example.com and tell me what the page says.*

- **Screen:** a card listing exactly one site (`example.com`); click **Yes**. A tab group called Benji
  appears; the row says "Reading a page in Chrome" (never the address); the report says what the page
  says and notes it read outside content.
- **Say:** "It can read a site I approve, and only that one. It can't click or type."
- **If it fails:** skip it. A browser that is not connected is a normal state; do not debug it on camera.
  Use only a harmless public site; never a site you are signed in to.

### 6. The record: `benji --diagnose` (2:40–3:00)

In Terminal, in the folder where you cloned Benji:

```bash
python3 -m benji --diagnose --hours 1
```

- **Screen:** a short report: turns, tool calls by class, the denied or declined write with its reason code,
  approvals and who answered them (the row's buttons), the job's states.
- **Say:** "This is the whole record. It says what ran and what was allowed. It has no message text, no
  file contents and no keys in it."
- **If the report is empty or errors:** say so and stop; do not scroll through other files to find
  something to show.

Stop the recording (⌃⌘Esc, or the menu-bar stop button).

## If anything goes wrong

- **A card you do not understand:** click **No**.
- **Benji seems to be doing something you did not ask for:** click **Stop** on the row, or press **Esc**
  during a job's first 2.5 seconds; for a running turn use the panel's stop control or Esc.
- **Stop everything:** stop the recording; click Benji's menu-bar icon › **Quit**; if the app does not
  respond, Force Quit from the Apple menu (⌥⌘Esc). Then log out of the demo account (Apple menu ›
  Log Out). Nothing in this account is yours; the only things at stake are the demo key and what is on
  the recording.
- **Something private appeared on screen:** do not share the recording. Delete it, revoke the demo key and
  tell nobody the contents. Check `check-isolation.sh` again before the next take.
- **Found Benji doing something it should not:** that is a security report, not a public comment on the
  video. See [SECURITY.md](../SECURITY.md).

## After the take

1. Stop the screen recording and save it **inside the demo account** (its Movies folder).
2. Watch it once, with the sound on, for anything private (a notification, a file name, a key).
3. Revoke the demo API key, and follow "After the demo" in [hardening-checklist.md](hardening-checklist.md).
