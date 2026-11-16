#!/usr/bin/env python3
"""The phone page in headless Chrome against the real listener (benji/remote.py), with the Mac played by
this script. Chrome runs headless with a throwaway profile; no model is called and nothing leaves 127.0.0.1.

    python3 tools/isolated_run.py -- python3 tools/test_remote_browser.py

Set CHROME to the browser's executable if it is not in /Applications. Without Chrome the check is skipped.
"""
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benji.remote import Relay, Server  # noqa: E402

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


class Browser:
    """Headless Chrome driven over its DevTools pipe (fds 3 and 4), one tab."""

    def __init__(self, path: str, profile: str):
        ir, iw = os.pipe()
        orr, ow = os.pipe()
        readfd, writefd = fcntl.fcntl(ir, fcntl.F_DUPFD, 10), fcntl.fcntl(ow, fcntl.F_DUPFD, 10)

        def child_fds():
            os.dup2(readfd, 3)
            os.dup2(writefd, 4)
        self.process = subprocess.Popen(
            [path, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
             "--use-mock-keychain", "--password-store=basic", "--disable-background-networking",
             f"--user-data-dir={profile}", "--remote-debugging-pipe", "about:blank"],
            preexec_fn=child_fds, pass_fds=(3, 4), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for fd in (ir, ow, readfd, writefd):
            os.close(fd)
        self.incoming = os.fdopen(orr, "rb", buffering=0)
        self.outgoing = os.fdopen(iw, "wb", buffering=0)
        self.replies, self.cv, self.serial, self.session = {}, threading.Condition(), 0, None
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        data = b""
        while chunk := self.incoming.read(1):
            if chunk != b"\0":
                data += chunk
                continue
            reply, data = json.loads(data), b""
            if "id" in reply:
                with self.cv:
                    self.replies[reply["id"]] = reply
                    self.cv.notify_all()

    def cdp(self, method, params=None, attached=True):
        self.serial += 1
        mid = self.serial
        request = {"id": mid, "method": method, "params": params or {}}
        if attached and self.session:
            request["sessionId"] = self.session
        self.outgoing.write(json.dumps(request).encode() + b"\0")
        with self.cv:
            if not self.cv.wait_for(lambda: mid in self.replies, timeout=10):
                raise AssertionError("DevTools timed out: " + method)
            reply = self.replies.pop(mid)
        if "error" in reply:
            raise AssertionError(reply["error"])
        return reply["result"]

    def open(self, url):
        tab = self.cdp("Target.createTarget", {"url": url}, False)["targetId"]
        self.session = self.cdp("Target.attachToTarget", {"targetId": tab, "flatten": True}, False)["sessionId"]

    def js(self, source):
        result = self.cdp("Runtime.evaluate", {"expression": source, "returnByValue": True, "awaitPromise": True})
        if "exceptionDetails" in result:
            raise AssertionError(result["exceptionDetails"])
        return result.get("result", {}).get("value")

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.outgoing.close()
        self.incoming.close()


def until(predicate, seconds=10.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.05)
    return False


def main() -> int:
    chrome_path = os.environ.get("CHROME", CHROME)
    if not Path(chrome_path).is_file():
        print("SKIP: the phone page check needs Chrome (set CHROME to its executable)")
        return 0
    events = []
    relay = Relay(events.append)
    server = Server(0, None, relay)
    state = {"available": True}
    stopping = threading.Event()

    def heartbeat():    # the Mac app's snapshot, as RemoteControl sends it every second
        while not stopping.is_set():
            relay.receive({"type": "snapshot", "state": json.loads(json.dumps(state))})
            stopping.wait(.1)
    threading.Thread(target=heartbeat, daemon=True).start()
    threading.Thread(target=server.serve_forever, daemon=True).start()

    count = 0

    def check(name, value):
        nonlocal count
        if not value:
            raise AssertionError(name)
        count += 1
        print("PASS", name)

    with tempfile.TemporaryDirectory(prefix="benji-phone-browser-", ignore_cleanup_errors=True) as profile:
        b = Browser(chrome_path, profile)
        js = b.js
        try:
            b.open(server.origin)
            check("the page loads", until(lambda: js("!!document.getElementById('connect')")))
            js("document.getElementById('key').value=" + json.dumps(relay.token) + ";document.getElementById('connect').click()")
            check("the access key connects through real HTTP",
                  until(lambda: js("!document.getElementById('controls').hidden && !document.getElementById('send').disabled")))
            check("the key field is cleared and nothing is saved to browser storage",
                  js("document.getElementById('key').value==='' && localStorage.length===0 && sessionStorage.length===0"))

            js("document.getElementById('prompt').value='Make a note';document.getElementById('send').click()")
            check("a task reaches the Mac once", until(lambda: len(events) == 1))
            first = events[0]
            task = {"id": first["id"], "text": first["text"], "running": True, "status": "Working",
                    "lines": [{"role": "assistant", "text": "<img src=x onerror=alert(1)>"}], "stream": "Writing…"}
            state.update(available=False, task=task)
            relay.receive({"type": "result", "id": first["id"], "ok": True, "message": "Received"})
            check("result text is shown as text, never as HTML",
                  until(lambda: js("document.getElementById('lines').textContent.includes('<img') && !document.querySelector('#lines img')")))

            task["approval"] = {"id": "approval-1234", "action": "write file", "target": "outside/notes.txt"}
            check("an approval shows its exact target",
                  until(lambda: js("!document.getElementById('approval').hidden && document.getElementById('target').textContent==='outside/notes.txt'")))
            js("document.getElementById('approve').click()")
            check("the answer names the task and the request",
                  until(lambda: len(events) == 2) and events[1]["task"] == first["id"]
                  and events[1]["request"] == "approval-1234" and events[1]["approved"] is True)
            check("Retry appears while the Mac has not acknowledged", until(lambda: js("!document.getElementById('retry').hidden")))
            js("document.getElementById('retry').click()")
            check("Retry sends the same command, so the Mac sees it once",
                  until(lambda: js("!document.getElementById('retry').hidden")) and len(events) == 2)
            relay.receive({"type": "result", "id": events[1]["id"], "ok": True, "message": "Approved"})

            # Approvals from the phone turned off on the Mac: the snapshot carries no request id.
            task["approval"] = {"action": "delete file", "target": "outside/old.txt"}
            check("with phone approvals off the approval shows, waiting for the Mac, with no buttons",
                  until(lambda: js("!document.getElementById('approval').hidden && document.getElementById('approval-actions').hidden"
                                   " && document.getElementById('target').textContent==='outside/old.txt'"
                                   " && document.getElementById('approval-hint').textContent.includes('on the Mac')")))
            js("document.getElementById('approve').click()")
            time.sleep(.3)
            check("... and nothing is sent for it", len(events) == 2)

            task.pop("approval")
            task.update(running=False, status="Done", stream="")
            state["available"] = True
            check("a finished task lets the next one be sent",
                  until(lambda: js("document.getElementById('task-status').textContent==='Done' && !document.getElementById('send').disabled")))

            # Hold back the next answer's HTTP response: the answer may or may not have arrived.
            js("document.getElementById('prompt').value='Stop example';document.getElementById('send').click()")
            check("a second task is sent", until(lambda: len(events) == 3))
            second = events[2]
            task = {"id": second["id"], "text": second["text"], "running": True, "status": "Needs your decision",
                    "lines": [], "stream": "",
                    "approval": {"id": "approval-5678", "action": "write file", "target": "outside/another.txt"}}
            state.update(available=False, task=task)
            relay.receive({"type": "result", "id": second["id"], "ok": True, "message": "Received"})
            check("its approval can be answered",
                  until(lambda: js("!document.getElementById('approve').disabled && document.getElementById('target').textContent==='outside/another.txt'")))
            js("window.originalFetch=window.fetch;window.fetch=async (...args)=>{const r=await originalFetch(...args);"
               "if(args[1]?.body && JSON.parse(args[1].body).op==='approve')await new Promise(resolve=>window.releaseApproval=resolve);return r;}")
            js("document.getElementById('approve').click()")
            check("the answer reaches the Mac while its response is held back",
                  until(lambda: len(events) == 4 and js("typeof window.releaseApproval==='function'")))
            check("Stop stays available meanwhile", js("!document.getElementById('stop').disabled"))
            js("document.getElementById('stop').click()")
            check("Stop reaches the same task without waiting for the answer's receipt",
                  until(lambda: len(events) == 5) and events[4]["op"] == "stop" and events[4]["task"] == second["id"])
            relay.receive({"type": "result", "id": events[4]["id"], "ok": True, "message": "Stopped"})
            task.pop("approval")
            task.update(running=False, status="Stopped")
            state["available"] = True
            check("the stop settles on its own",
                  until(lambda: js("document.getElementById('task-status').textContent==='Stopped' && !document.getElementById('send').disabled")))
            js("window.releaseApproval();window.fetch=window.originalFetch")
            check("a late answer's response cannot bring its buttons back",
                  until(lambda: js("document.getElementById('retry').hidden && !document.getElementById('send').disabled")))

            js("document.getElementById('disconnect').click()")
            check("Disconnect clears the shown result",
                  js("document.getElementById('controls').hidden && document.getElementById('lines').textContent===''"))
            print(f"{count} phone page checks passed")
        finally:
            b.close()
            stopping.set()
            server.shutdown()
            server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
