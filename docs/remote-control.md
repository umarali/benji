# Control Benji from your phone

Send a text task from your phone's browser to Benji on your Mac, watch it work, answer its
approvals and stop it. Phone control is off until you turn it on, and off again every time Benji
starts.

**Not live-tested.** The listener, the app's side, the engine's side and the phone page have
automated checks, the page in headless Chrome. A real phone, a real Tailscale connection and a
real model have not been tried together. See [Feature status](status.md).

[Set up](#set-up) · [What to expect](#what-to-expect) · [Approvals](#approvals) ·
[Privacy and access](#privacy-and-access) · [If the model rejects its API key](#if-the-model-rejects-its-api-key) ·
[How it works](#how-it-works) · [For contributors](#for-contributors)

## Set up

You need Benji built from source ([Set up Benji on your Mac](setup.md)) and Tailscale on your Mac
and your phone. Benji does not install or set up Tailscale for you. Phone control needs no new
macOS permission.

1. Install Tailscale on your Mac and phone, and sign both in to the same private network (your
   tailnet). On an iPhone, install [Tailscale from the App Store](https://tailscale.com/docs/install/ios)
   and allow its VPN configuration. You don't need a Benji app on the phone.
2. On the Mac, run:

   ```sh
   tailscale serve --bg 8765
   ```

   If Terminal says `tailscale: command not found`, the Mac app has the same command at
   `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. Follow Tailscale's prompt to turn on
   HTTPS if it asks. This uses the default HTTPS route, so check first that no other app uses it.
   Use **Serve**, which stays inside your tailnet, never **Funnel**, which is public. See the
   [Serve guide](https://tailscale.com/docs/features/tailscale-serve) and the
   [command reference](https://tailscale.com/docs/reference/tailscale-cli/serve).
3. In Benji's menu choose **Phone Control…** (or **Settings…**, then **Phone**). Paste the HTTPS
   address Tailscale printed, such as `https://your-mac.your-tailnet.ts.net`, with no path. A
   trailing slash is fine.
4. Choose **Turn on phone control**. Benji shows an access key.
5. On the phone, open the same address in Safari, with Tailscale connected, and enter the access
   key. **Copy address** and **Copy access key** put them on the clipboard if that is easier.

The key is new each time you turn phone control on. Benji keeps it in memory only, and the phone
page keeps it in the page's memory: reloading the page asks for it again.

To try it on the Mac alone, keep `http://127.0.0.1:8765` as the address and open it in a browser
on the Mac. A phone cannot reach that address.

To check it away from home, turn off Wi-Fi on the phone, keep Tailscale connected, and open the
address over mobile data. Check that the page connects before you send a task: a task calls your
model and may use its tools, just as on the Mac.

**When you are done,** remove the route with `tailscale serve --https=443 off`, if it is the one
you set up for Benji. Tailscale keeps the route after Benji stops, and another program that later
listens on port 8765 would be reachable from your tailnet.

The app loads the listener and the phone page from the checkout it was built in, including
`benji/remote_web/`. Keep `Benji.app` in the checkout, as for the engine.

## What to expect

- **One task at a time.** The phone can send a task only while the Mac is free: not while Benji
  is answering, listening, waiting on a screen card or running a background job. There is no
  queue.
- **Text only.** A phone task runs as text even if Settings › Screen is on. It gets no screenshot
  and cannot act on the screen, start a background job or a schedule, use the browser extension,
  show a card or draw. Its answer is not read aloud. The usual text tools can still read and write
  files and run commands, under the same approval rules as on the Mac. This is not a sandbox.
- **One conversation.** The task goes into the conversation open on the Mac, with its model. The
  model sees the earlier messages and can mention them, but the phone shows only its own task.
  Whatever an earlier message read from outside (a web page, say) still makes the phone task ask
  before it changes anything, and the other way round. That holds after Benji or its engine
  restarts, when you reopen the conversation, and when you cut off a spoken answer. The task
  appears in the Mac's panel and its saved conversation.
- **What the phone shows:** the last 20 lines of the task, each cut to 2,000 characters with a
  note when it is longer. The full result is on the Mac. A task can be up to 6,000 characters.
- **Stop this task** works even while an answer to an approval is still on its way. It cancels the
  phone's task on the Mac; it cannot undo what is already done. It needs a working connection.
- **Retry the same request** sends the same request again, with the same id, after a connection
  failed. It never starts a second task. If in doubt, check the Mac before sending the task again
  as a new one.
- Keep Safari open to follow the task. A locked or backgrounded phone may stop updating, and the
  Mac's sleep cuts the connection. Reopen the page and check the state before sending again.
- **Disconnect** clears the result and the key from the page. A task already running continues.
- On the Mac, the talk key stops the phone's task and takes over. While the phone's task runs, a
  message typed on the Mac is not sent: it stays in the box.
- **Turn off and stop phone task** revokes the key and stops the phone's running task. It does not
  stop a task you started on the Mac afterwards. Quitting Benji stops the listener too.
- A session remembers up to 2,048 requests, so that a retry is never run twice. At that limit, turn
  phone control off and on again. There is no offline queue, no restart recovery, no user accounts
  and no remote wake.

## Approvals

An ordinary approval of the phone's task shows on the phone with its action and its exact target.
It can be answered once, from the Mac's card or from the phone, whichever is first. The Mac's
timeout still applies, and an answer to an earlier request can never answer a new one. The audit
log records who answered: the Mac's card, the phone, the timeout or a stop. It never records the
action, the target or the key.

**Answer approvals from the phone**, in Settings › Phone, is on by default. Turn it off and the
phone still sends tasks, follows them and can stop them, but an approval shows on the phone as
waiting for the Mac, with no buttons, and only the Mac's card can answer it. The Mac refuses an
answer from the phone while the switch is off, whatever the page sends. A change applies to the
next approval at once, without turning phone control off.

Some approvals always stay on the Mac: a background job's, a screen step's or a drive's, and one
whose description is too long to show in full on the phone.

## Privacy and access

The listener binds to `127.0.0.1:8765` only. Private Tailscale Serve gives it HTTPS and carries it
to your tailnet. The listener accepts one exact Host and Origin, needs the access key on every
request for data, and gives no other website access. It takes at most 16 connections at once. A
request's headers, at most 16 KB, must arrive within 3 seconds and the whole request within 10,
or the connection is closed. When all 16 are in use, the oldest one still sending its headers is
closed to make room, so a slow client cannot hold the listener.

**Anyone with network access and the key can read the phone's current result, send tasks and, while
the approvals switch is on, approve ordinary actions.** Treat the key as control of Benji, not as a
read-only link.

- The Host and Origin checks protect against other web pages in a browser. They do not identify a
  person or a device: the access key is the credential. If you lose the phone or the key is copied,
  turn phone control off on the Mac and on again. You cannot revoke a single browser.
- Benji does not check your Tailscale settings and cannot tell if you used Funnel by mistake.
- Keep the software on your Mac, and your tailnet, trusted. Listening on `127.0.0.1` does not keep
  out a malicious program on the Mac itself.
- Benji adds no hosted backend and no account. Tailscale has its own account, servers and privacy
  terms. Tasks and results travel between your own devices.
- Your model provider receives the phone's tasks, the conversation and tool output, as it does for
  the Mac: see [Privacy](privacy.md). A model you run yourself keeps the model's work on your Mac,
  but phone control still uses the network.
- The listener writes no log of requests or keys, and the phone page saves nothing to browser
  storage. Screenshots, browser extensions and the phone's memory can still expose what the page
  shows.
- **Copy access key** puts the key on the clipboard, and Universal Clipboard may copy it to your
  other Apple devices. Don't paste it into messages, shared notes or a URL.

## If the model rejects its API key

The phone uses the model and the API key set up on your Mac. A 401 or "authentication failed" on
the phone means your model provider refused that key. The phone's access key has nothing to do
with it.

Fix it on the Mac:

- **Settings › General › Your API key** says where the key is kept.
- If it is in `~/.benji.env`, put the new key there, as in [Add a model key](setup.md#3-add-a-model-key).
  If you moved keys to the Keychain, the app no longer reads that file.
- **Settings › General › Model** shows the model in use and where your messages go.

Then send a short message from the Mac to check the key before you try the phone again.

## How it works

```
 Safari on your phone ── your tailnet, HTTPS ──▶ Tailscale Serve on your Mac
                                                        │ http://127.0.0.1:8765
                                                        ▼
                                  benji/remote.py: checks the key, Host, Origin and limits
                                                        │ its stdin and stdout
                                                        ▼
                     Benji.app: owns the task and its approvals ──▶ the engine, as for any message
```

`benji/remote.py` is a relay, not another engine. The app starts it when you turn phone control
on. It reads no key and imports nothing from the engine. A request from the phone is checked
there, then handed to the app over the child process's pipe; the app checks it again against what
the Mac is doing and sends a snapshot of the phone's task back every second. The app sends the
task to the engine as a `send` marked `remote_text`, and the engine keeps nothing of that request
but its id and its words.

A new task is taken only while the Mac is free. An approval names both the task and the current
request. A retry keeps its request id, so a lost response never repeats an action. Closing Safari
is not a stop. Turning phone control off revokes the key and cancels the phone's task.

## For contributors

The phone can send only three commands: `send`, `approve` and `stop`. A native phone app or
another client should use the same rules: the app owns the task, every command has an id, and an
answer names its task and request. Other websites are kept out by the origin check. The HTTP
interface is not a public API yet and may change.

`GET /api/state` answers with an `ETag`, and an unchanged state is answered with no body. The key,
Host and Origin are checked before that answer too. This saves sending the same state again, not
the work of making it.

The checks, from the repository root:

```sh
python3 tools/isolated_run.py -- python3 tests/selftest.py        # includes tests/check_remote.py
python3 tools/isolated_run.py -- sh -c 'cd companion && xcrun swift test --filter "Phone|RemoteControl"'
python3 -I companion/ServeCheck/run.py
python3 tools/isolated_run.py -- python3 tools/test_remote_browser.py
```

The last one runs Chrome headless with a throwaway profile, and skips if Chrome is not installed.
