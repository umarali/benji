# Safety, background jobs and browser reach

How Benji limits what it can do, how a background job runs, and how a job may use your own browser.

**In short:**

- The rules that limit Benji are in **code**, not only in the prompt. A model persuaded by a web
  page still cannot widen what the code allows.
- Anything destructive or outward-facing asks you first. Keys, mail, messages and browser data
  are never read without your yes.
- Background jobs and browser reach follow the same rules. Both are newer: see
  [Feature status](status.md).

## What runs, what asks, what is refused

Before any tool call runs, the code (`benji/gate.py`, the "gate") puts it in one of four groups:

- **Runs:** reading files and writing new ones inside the working folder, a shell command on the
  read-only allowlist, a read-only AppleScript, a web search or page fetch, remembering something
  you just said.
- **Runs after a short pause you can stop:** some screen steps, such as a click on a named tab or
  link (see [Acting on your screen](#acting-on-your-screen)).
- **Asks** (a card in the app, `y/N` in the terminal, or the phone page for a task sent from
  your phone: see [Control Benji from your phone](remote-control.md#approvals)): destructive commands (`rm`, `mv`, `sudo`,
  `git push`…), overwriting a file, sends, reading or writing outside the working folder, and any
  shell command the parser does not fully understand.
- **Refused:** the file tools never open keys, mail, messages, browser data or Benji's own key
  file, even through a symlink. A shell command that reads them asks, and the card says what it
  would read.

The working folder is Benji's folder (`~/.benji`) for a conversation, and a job's own folder for a
background job.

`--yes` on the command line answers yes to everything that would ask. Use it only where you trust
everything the model might read.

## After Benji reads something from outside

Once a turn has read a web page, a browser tab, a file outside the working folder, the output of
AppleScript or of a command that is not read-only, or an unverified skill, everything it then
changes asks, even what would otherwise run, such as writing a file in
the working folder. (The code calls this *taint*.)

- It lasts for the rest of the conversation, because what was read stays in it. A new conversation
  starts clean.
- It is saved with the conversation, so it still applies after Benji restarts and when you reopen
  the conversation. An answer you cut off while it is still being written keeps the taint of what
  it had read, since the words you heard stay in the conversation. A conversation saved by a version of Benji from before this was kept has no
  record of it, and opens clean.
- A screenshot counts too, for its own turn: writing a file, running a Shortcut or remembering
  something then asks. It does not carry to the next turn, because the picture is not kept.
- A job started by such a turn inherits it, and so does a turn that reads the job's result.

The text of files, pages, command output and screenshots is treated as data, never as
instructions. That is a prompt rule backed by the checks above. It is **not a sandbox**: read
what you approve. See [SECURITY.md](../.github/SECURITY.md).

## Acting on your screen

With a screenshot, Benji can point at things, and also click, scroll and type for you. Settings ›
Screen › Acting on your screen has two choices:

- **Act on simple steps** (the default): scrolling, tabs, links and menus happen while you watch.
  A click is ringed for about a second first. Anything that could send, buy, delete or close
  something asks, and so does every drag.
- **Ask before every step:** every click, scroll or key waits for your OK.

Moving the mouse, typing or pressing Esc stops Benji at once. A turn can take at most five steps
without asking.

**Drive:** for a longer task on screen ("fill in this form"), Benji asks once, on a card that names
the goal, and then works toward it. Only the card's button grants it, never a spoken yes, and the
card declines itself after 45 seconds. A drive ends with its turn, when you stop it, or as soon as
the turn reads a web page, a browser tab or a file outside the working folder.

## Job approvals wait for you

A job that needs your answer waits, with no timeout, as **Needs you** in its row. Only that row's
own Yes and No buttons answer it: not a spoken "yes", not a key press, not Esc. Stop answers No.

## The audit log

`events.jsonl` in Benji's folder records what ran, how it was classed and why, how each approval
was answered, job states and errors. Every field is checked against a closed list before it is
written: the log cannot hold message text, page text, file contents, file names, full web
addresses, keys or screenshots. It can hold a host name, such as the provider's or a site a job
was allowed to open. It is readable by you only.

- `benji --diagnose [--hours N]` prints a short report from it, to read or to paste into a bug
  report. The app has the same under Settings › General › Diagnostics.
- `BENJI_AUDIT=0` turns the log off.

## Background jobs

Ask for something to be done "in the background". Benji starts one job (one at a time), tells you
in a sentence, and carries on.

**What a job gets:** its own folder (`~/.benji/jobs/<id>/`, with `report.md` and `output/`), up to
40 tool steps and the usual tools, but **no** screen tools and no pointing. It runs behind the same
gate and taint rules, with its own folder as its working folder, so a write elsewhere or a read of
your files outside it asks.

**What you see:** one row above the conversation, with the state (*Starting*, *Working*, *Needs
you*, *Done*, *Didn't finish*, *Stopped*), what the job is doing, Stop, a field to steer it and, when it ends, its files
and follow-up chips. The state comes from the code, never from what the model writes. A job starts
after a 2.5-second peek ("Starting … · Esc cancels").

**How it keeps on track:**

- It is told what you agreed in the conversation (your last few messages, the sites and files you
  named), and the row shows you what it was told.
- It re-reads its brief every ten steps and after any wait.
- If it uses all its steps, it stops, says plainly what is done and what is left, and asks you.
  **Continue** on the row starts another run of the same job.
- It remembers a "No" for 30 minutes, so the same action on the same thing is not asked again
  straight away.

**Repeating jobs:** tell a job to repeat ("every morning at 9", never more often than every 30
minutes) and Benji asks on a card first.

- A repeat runs only while Benji is open and your Mac is awake. A run missed during sleep happens
  once.
- A repeat run **only reads**: anything else waits for you. A run with nothing new makes no sound.
- Three failed runs in a row pause it. The row has Pause, Resume and Delete, and Settings has one
  switch for every repeating job.

**Limits:** a job does **not** survive quitting Benji. It is shown as *Didn't finish* afterwards
and does not resume.

Turn jobs off with `defaults write com.emerssive.heybenji.app backgroundJobs -bool NO`.
Background jobs are **experimental**: see [Feature status](status.md).

## Browser reach

A background job that has a **site grant** can open pages in your own browser and read their
visible text. With a separate **acting grant** for a site, it can also click and type there.

### Turning it on

- **Off by default.** Nothing is installed or registered until you turn on Settings › Browser.
  Each browser (Chrome, Chrome Beta, Brave, Edge, Arc) then has its own switch. Benji writes the
  connection file only for the ones you turn on, and turning the main switch off removes them all.
- **You load the extension yourself.** Benji never changes a browser's settings: turn on
  Developer mode in `chrome://extensions`, choose Load unpacked, and pick
  [`browser-extension/`](../browser-extension/).
- **Its permissions:** `nativeMessaging`, `tabGroups`, `scripting`, `storage`, `alarms` and
  `debugger`, with site access as an *optional* permission that the browser asks you for. It does
  not request `tabs`. Because `debugger` is new in version 0.2.0, the browser switches off an older
  install until you approve it again on the extensions page. The extension's README explains each
  permission.

### What a job may do

- **Read only the sites you grant.** When a job starts with sites, a card lists exactly those
  origins (https, exact host and port, no wildcards) and you say Yes or No. Another site, a
  subdomain or another port is another card. Nothing a page says can add one.
- **Act only after a second, separate yes** for each site. Reading never implies acting. Each
  step is then classed in code from what the page's element actually is, not from what the model
  called it:

| Goes ahead | Asks you every time | Refused |
|---|---|---|
| A link on the same site, a tab, a disclosure, a tick box, a field your message named | A button that sends, pays, posts, deletes or confirms; a form post; Return; a link to another site; a download; anything Benji can't tell | Password, card-number and one-time-code fields |

- **File uploads always ask**, one card per file, naming the file and the site. Keys, mail,
  messages, browser data and `.env` files are refused outright. There is no "always approve".
- **The page in front:** ask about the page you are looking at, and a card shows its site first.
  In Settings you can mark exact sites "always allow reading". That covers reading only: acting,
  uploads and sends still ask.

### What a job cannot do

Run a script of the model's, read any tab outside its group, type into a password or card field,
press shortcuts, or use a private window. A job's tabs are closed when it ends.

### Stopping it

While a step runs, the browser shows a bar saying it is being debugged. **Cancel** on that bar
stops the job. The extension attaches only for the step and lets go after.

### Before you turn it on

- A granted site is read and acted on **as you**, with your cookies: a signed-in page's text goes
  to your model provider, and a click is a click by you.
- Page text is outside content, so reading it taints the job: every change to files, apps or
  commands then asks, and browser actions follow the table above.
- Browser reach is **not live-tested** in a real profile. Arc and the other Chromium browsers have
  a switch but have not been tried. There is no Web Store build yet; see [ROADMAP.md](ROADMAP.md).
