# Safety, background jobs and browser reach

How Benji limits what it can do, how a background job runs, and how a job may use your own browser.

**In short:**

- The rules that limit Benji are in **code**, not only in the prompt. A model persuaded by a web
  page still cannot widen what the code allows.
- Anything destructive or outward-facing asks you first. The file tools refuse private places such
  as keys and mail; a shell command that reads them asks.
- Background jobs and browser reach follow the same rules, and both are newer: see
  [Feature status](status.md).

## Safety model

### The gate

Every tool call is classed *free* (read-only, inside the working folder), *quiet*, *asked* or
*denied* before it runs.

- **Asks first** (a card in the app, `y/N` in the terminal): destructive shell commands (`rm`,
  `mv`, `sudo`, `git push`…), overwrites, sends, writes outside the working folder, reads outside
  it, and sensitive capabilities.
- **Refused outright** by the file tools, including through a symlink: private locations such as
  keys, mail, messages, browser data and Benji's own key file. A shell command that reads them
  asks, with a card naming what it would read.
- **The shell is a read-only allowlist.** A parser reads each command, and anything it does not
  understand asks.

`--yes` approves everything that would ask, including shell reads of private locations. Use it
only where you trust everything the model might read.

### Taint

Once a turn has read something from outside (a web page, a browser tab, a file outside the
working folder, an unverified skill), anything it then changes asks, whatever the model says.
Looking at your screen is a weaker source and is tracked apart. Outside content stays in the
conversation, so the turns after it are tainted too, until a new conversation starts; a
screenshot leaves the conversation with its turn, so it does not carry over. Taint passes
from a turn into a job it starts, and back to a turn that reads the job's result.

### Instructions are data

The text of files, pages, command output and screenshots is treated as data, never as commands.
That is a prompt rule backed by the code checks above. It is **not a sandbox**: read what you
approve. See [SECURITY.md](../.github/SECURITY.md).

### Job approvals wait for you

A job that needs your answer waits, with no timeout, as **Needs you** in its row. Only that row's
own Yes and No buttons answer it: not a spoken "yes", not a key press, not Esc. Stop answers No.

### The audit log

`events.jsonl` in the working folder records what ran, how the gate classed it and why, how each
approval was answered, job states and errors. Every field is checked against a closed list before
it is written, so the log **cannot** hold message text, page text, file contents, addresses or
keys. It is readable by you only.

- `benji --diagnose [--hours N]` prints a short report from it, to read or to paste into a bug
  report. The app has the same under Settings › General › Diagnostics.
- `BENJI_AUDIT=0` (or `false`, `no`, `off`) turns the log off.

## Background jobs

Ask for something to be done "in the background". Benji starts one job (one at a time), tells you
in a sentence, and carries on.

**What a job gets:** its own folder (`~/.benji/jobs/<id>/`, with `report.md` and `output/`), up to
40 tool steps and the usual tools, but **no** screen tools and no pointing. It runs behind the same
gate and taint rules, with its own folder as its working folder, so a write elsewhere or a read of
your files outside it asks.

**What you see:** one row above the conversation, with the state (*working*, *needs you*, *done*,
*failed*, *stopped*), what the job is doing, Stop, a field to steer it and, when it ends, its files
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
