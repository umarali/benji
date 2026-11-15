# Benji's browser extension

Lets a background job of Benji's read pages in your own browser, signed in as you, on the sites you
approved for that job, and, for a site you allowed it to act on, click and type there. It opens pages in a
tab group called **Benji**, lists that group's tabs, returns the visible text and address of one, lists a
page's controls, and clicks, types, presses keys, scrolls and gives a page a file. It also reads the page in
front of you when you ask about it and a card shows its site first. It cannot run a script of the model's,
open a page you didn't allow, act on a site you didn't allow acting on, or touch a tab outside its group,
except to read the page in front when you ask, as above.

**Upgrading from 0.1.0:** this version asks for the new `debugger` permission, so the browser turns the
extension off until you approve it. Open the extensions page (`chrome://extensions`), find Benji and choose
to enable it again. Nothing else changes until you do, and Benji never does this for you.

## Load it (unpacked, for now)

1. Turn on **Settings, Browser** in the Benji app, then turn on the browser you use (Chrome, Chrome Beta,
   Brave, Edge or Arc). Only then is Benji's connection registered with that browser; nothing is written
   for a browser you didn't turn on, and Benji never changes a browser's own settings.
2. In that browser open its extensions page (`chrome://extensions`, `brave://extensions`, `edge://extensions`,
   `arc://extensions`), turn on **Developer mode**, choose **Load unpacked** and pick this folder.
3. Open the Benji extension from the toolbar and choose **Allow Benji to read pages**. The browser asks
   once; "Remove access" takes it back.

The extension's id is fixed by the `key` in `manifest.json`, so Benji can name exactly this extension and
no other when it registers with Chrome.

## What each permission is for

| Permission | Why | What it doesn't give |
|---|---|---|
| `nativeMessaging` | Talk to Benji's host program on this Mac (the only way out; no network access of its own). | Nothing else can talk to the host: Chrome starts it only for this extension's id. |
| `tabGroups` | Name and colour the "Benji" tab group. | Doesn't read tabs. |
| `scripting` | Run two fixed functions in a page, main frame only: one returns its visible text, one lists its controls, describes one, focuses a field or scrolls. | Nothing the model wrote is run; neither function reads a form value, and they change only the scroll position and the focus. |
| `debugger` | Click, type, press a key or give a file input a file, through the browser's debugging protocol, for one step at a time (attached, acted, detached). While attached the browser shows a bar; **Cancel on it stops the job**. | It is never attached outside a step, never on a tab outside the group, never on a site the job wasn't allowed to act on, and it blocks downloads unless you said yes to that one. |
| `storage` | Remember the group's number for this browser session only. | No page data is stored. |
| `alarms` | Reconnect every 30 seconds if Benji wasn't running when Chrome started. | |
| optional `https://*/*` | Lets `scripting` and the tab list see pages. Asked for in the popup, by Chrome's own dialog; nothing can be read until you grant it. | Even granted, the code reads only tabs in the Benji group on origins Benji's engine names for the current job, and drops the text if the page moved to another site while it was read. |

Not requested: `tabs`, `cookies`, `history`, `webRequest`, `downloads`, content scripts, host access at
install. Only `https` pages with no user name, IP address, local name or internationalised name are used.

## Files

- `manifest.json`, `service-worker.js` (the connection), `core.js` (the operations, testable without
  Chrome), `origin.js` (what counts as a site), `act-rules.js` (what a click, a word or a key is classed
  as), `page-text.js` and `page-actions.js` (the two functions run in a page), `popup.*` (status and the Allow button).
- `test/*.test.mjs`, `test/origin-cases.json`, `test/act-cases.json`: `node --test browser-extension/test/*.test.mjs`
  (`page-text` and `page-actions` need Chrome and run it headless with a throwaway profile; all run from
  `tests/selftest.py`). The two case files are shared with the Python engine, which must give the same answers.
- `test/e2e-headless.py`: a by-hand check of read, look, click, type, upload, keys, the front tab and close in
  a headless Chrome with a throwaway profile.

## A second extension id (the Web Store seam)

Today one id is trusted: the one the browser derives from the `key` in `manifest.json`. A Web Store build would
have another id, and choosing it is a decision of its own. When it is made, add the id in three places that
a test keeps in step: `EXTENSION_IDS` in `benji/browser_link.py`, `ALLOWED_EXTENSION_IDS` in
`benji/browser_host.py` and `BrowserExtension.ids` in `companion/Sources/BenjiCore/Jobs/Browser.swift`. The
registration then names every id in `allowed_origins`. Nothing else in the rules depends on the id.
