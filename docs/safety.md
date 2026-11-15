# Safety, background jobs and browser reach

How Benji limits what it can do, how a background job runs, and how a job may use your own browser.

## Safety model

Benji can run commands and change files, so the rules that limit it are in **code**, not only in the
prompt. A model that is persuaded by a web page still cannot widen what the code allows.

- **The gate.** Every tool call is classed *free* (read-only, inside the working folder), *quiet*,
  *asked* or *denied*. Destructive shell commands (`rm`, `mv`, `sudo`, `git push`…), overwrites,
  sends, writes outside the working folder, reads outside it and sensitive capabilities **ask first**
  (a card in the app, `y/N` in the terminal). Private locations (keys, mail, messages, browser data,
  Benji's own key file) are refused outright, including through a symlink. The shell is a read-only
  allowlist: a command is understood by a parser and anything it does not understand asks. `--yes`
  auto-approves; use it only where you trust everything the model might read.
- **Taint.** Once a turn has read something from outside (a web page, a browser tab, a file outside
  the working folder, an unverified skill), anything it then changes asks, whatever the model says.
  Looking at your screen is a weaker source and is tracked apart. Taint passes from a turn into a job
  it starts and back to a turn that reads the job's result.
- **Instructions are data.** The text of files, pages, command output and screenshots is treated as
  data, never as commands. That is a prompt rule backed by the code checks above; it is **not a
  sandbox**. Read what you approve. See [SECURITY.md](../SECURITY.md).
- **Job approvals park, they don't fail.** A job that needs your answer waits, with no timeout, as
  **Needs you** in its row. Only that row's own Yes/No buttons answer it: not a spoken "yes", not a
  key press, not Esc. Stop answers No.
- **A metadata-only audit log.** `events.jsonl` in the working folder records what ran, how the gate
  classed it and why, how each approval was answered, job states and errors. Every field is checked
  against a closed list before it is written, so it **cannot** hold message text, page text, file
  contents, addresses or keys. Logs are readable by you only. `benji --diagnose [--hours N]` prints a
  short report from it to read, or to paste into a bug report; the app has the same under
  Settings › General › Diagnostics. `BENJI_AUDIT=0` turns the log off.

## Background jobs

Ask for something to be done "in the background". Benji starts one job (one at a time), tells you in
a sentence, and carries on. The job:

- gets its **own folder** (`~/.benji/jobs/<id>/` with `report.md` and `output/`), up to 40
  tool steps, the usual non-screen tools, and **no** screen tools and no pointing;
- runs behind the **same gate and taint rules**, with its own folder as its working folder, so a
  write elsewhere or a read of your files outside it asks;
- shows as one **row** above the conversation: state (*working*, *needs you*, *done*, *failed*,
  *stopped*), what it is doing, Stop, a steer field, and when it ends its files and follow-up chips.
  The state is derived in code, never from what the model writes;
- starts after a 2.5-second peek ("Starting … · Esc cancels");
- does **not** survive quitting Benji: it is shown as *Didn't finish* afterwards and does not resume.
- is told what you agreed in the conversation (your last few messages, the sites and files you named), and the row
  shows you what it was told;
- re-reads its brief every ten steps and after any wait, and if it uses all its steps it stops, says plainly what is
  done and what is left, and asks you; **Continue** on the row starts another run of the same job;
- can be told to **repeat** ("every morning at 9", never more often than every 30 minutes). Benji asks on a card first.
  The same job then runs again, only while Benji is open and your Mac is awake (a run missed in sleep happens once),
  and a repeat run **only reads**: anything else waits for you. A repeat run with nothing new makes no sound. Three
  failed runs in a row pause it, the row has Pause, Resume and Delete, and Settings has one switch for every
  repeating job;
- remembers a "No" for 30 minutes, so the same action on the same thing is not asked again straight away.

Turn jobs off with `defaults write com.emerssive.heybenji.app backgroundJobs -bool NO`. **Experimental**: see the
[feature status](status.md).

## Browser reach

A background job whose record carries a **site grant** can open pages in your own browser and read their
visible text. With a separate **acting grant** for a site it can also click and type there.

- **Off by default.** Nothing is installed or registered until you turn on Settings › Browser, and then
  each browser (Chrome, Chrome Beta, Brave, Edge, Arc) is its own switch; Benji writes the connection
  file only for the ones you turn on, and turning the master switch off removes them all. Benji never
  changes a browser's own settings: you turn on Developer mode and load the extension yourself.
- **Our own extension** ([`browser-extension/`](../browser-extension/)), loaded unpacked for now (`chrome://extensions` ›
  Developer mode › Load unpacked). It requests `nativeMessaging`, `tabGroups`, `scripting`, `storage`,
  `alarms` and `debugger`, with site access as an *optional* permission that the browser asks you for.
  It does not request `tabs`. Because `debugger` is new in version 0.2.0, an older install is switched
  off by the browser until you approve it again on the extensions page. Its README lists each permission.
- **Per-job site grants.** When a job is started with sites, a card lists exactly those origins
  (https, exact host and port, no wildcards) and you say Yes or No. Another site, a subdomain or
  another port is another card. Nothing a page says can add one.
- **Acting is a second, separate yes** for each site, never implied by reading. Each click, typed word or
  key is then classed in code from what the page's element is, not from what the model called it: a link
  on the same site, a tab, a disclosure, a tick, a field your message named go ahead; a button that
  sends, pays, posts, deletes or confirms, a form post, Return, a link to another site, a download and
  anything Benji can't tell ask you every time; password, card-number and one-time-code fields are
  refused. **File uploads are always asked, one card per file naming the file and the site; keys, mail,
  messages, browser data and `.env` files are refused outright; there is no "always approve".**
- **The debugging bar is the stop button.** While a step runs, the browser shows a bar saying it is being
  debugged. Cancel on that bar stops the job. The extension attaches only for the step and lets go after.
- **The page in front.** Ask about the page you are looking at and a card shows its site first. In
  Settings you can set exact sites to "always allow reading" (reading only: acting, uploads and sends
  still ask).
- **What it cannot do:** run a script of the model's, read any tab outside its group, type into a
  password or card field, press shortcuts, or use a private window. A job's tabs are closed when it ends.
- **Page text is outside content:** reading it taints the job, so every change the job then makes asks.

Be aware: a granted site is read and acted on **as you**, with your cookies, so a signed-in page's text goes
to your model provider and a click is a click by you. **Not live-tested** in a real profile. Arc and the
other Chromium browsers are in the table but have not been tried. A Web Store build is not made yet.
See [ROADMAP.md](ROADMAP.md).
