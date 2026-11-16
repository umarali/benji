"""Phone control: a small HTTP listener on 127.0.0.1 that relays a phone browser to the Mac app.

The app starts this process when the user turns phone control on, and stops it when they turn it off.
No agent, provider, configuration, file tool or saved credential lives here: the app owns every task.
A command from the phone is checked here, written to the app on stdout, and the app's snapshot of the
phone task comes back on stdin. Reach it from a phone through private Tailscale Serve only, never
Funnel or a public reverse proxy (docs/remote-control.md).
"""
from __future__ import annotations

import argparse
import hmac
import hashlib
import json
import re
import secrets
import socket
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

MAX_BODY = 24_000
# Command ids are never evicted, so an old retry can never run again; at the limit new commands are refused.
MAX_COMMANDS = 2048
MAX_CONNECTIONS = 16
MAX_HEAD = 16_384       # bytes of request line and headers together
IDLE_TIMEOUT = 3.0      # seconds a connection may send nothing
# Seconds from accepting a connection to having read its request line and headers, and to having
# read the whole request with its body, however slowly the bytes come: a client trickling bytes
# cannot keep a connection slot.
HEADER_DEADLINE = 3.0
REQUEST_DEADLINE = 10.0
EVICT_WAIT = 1.0        # seconds a new connection waits for the slot of one closed to make room
MAX_TASK = 6000
HEARTBEAT = 5.0     # seconds without a snapshot from the app before the Mac counts as not responding
ID = re.compile(r"^[A-Za-z0-9_-]{8,80}$")
ASSETS = {"/": ("index.html", "text/html; charset=utf-8"),
          "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/style.css": ("style.css", "text/css; charset=utf-8")}


def origin(value: str, port: int) -> str:
    """The one origin the listener answers: an HTTPS `*.ts.net` address with no path, or the exact
    loopback address for a test on this Mac."""
    local = f"http://127.0.0.1:{port}"
    if value == local:
        return value
    u = urlsplit(value)
    if (u.scheme != "https" or not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net", u.netloc)
            or u.path or u.query or u.fragment):
        raise ValueError("Use an https://machine.tailnet.ts.net origin, or the exact loopback URL.")
    return value


def command(value: object) -> dict:
    """A phone command, checked for its exact shape: `send`, `approve` or `stop`, with no other field."""
    if not isinstance(value, dict) or not isinstance(value.get("id"), str) or not ID.fullmatch(value["id"]):
        raise ValueError("Invalid command ID.")
    kind = value.get("op")
    expected = {"send": {"id", "op", "text"}, "stop": {"id", "op", "task"},
                "approve": {"id", "op", "task", "request", "approved"}}.get(kind)
    if expected is None or set(value) != expected:
        raise ValueError("Unsupported command.")
    if kind == "send":
        if not isinstance(value["text"], str) or not value["text"].strip() or len(value["text"]) > MAX_TASK:
            raise ValueError(f"Write a task of at most {MAX_TASK} characters.")
    else:
        if not isinstance(value["task"], str) or not ID.fullmatch(value["task"]):
            raise ValueError("Invalid task.")
    if kind == "approve" and (not isinstance(value["request"], str) or not ID.fullmatch(value["request"])
                              or type(value["approved"]) is not bool):
        raise ValueError("Invalid approval.")
    return value


class Relay:
    """The phone's side of the app: the app's last snapshot, and every command id seen this session
    with the app's answer to it. A retry with the same id gets the same receipt and is not sent again."""

    def __init__(self, emit, clock=time.monotonic):
        self.emit, self.clock = emit, clock
        self.token = secrets.token_urlsafe(32)
        self.lock = threading.RLock()
        self.last_seen = 0.0
        self.closed = False
        self.snapshot = {"available": False, "task": None}
        self.commands: dict[str, dict] = {}

    def receive(self, value: dict) -> None:
        with self.lock:
            if value.get("type") == "snapshot" and isinstance(value.get("state"), dict):
                self.snapshot = value["state"]
                self.last_seen = self.clock()
            elif value.get("type") == "result":
                item = self.commands.get(value.get("id"))
                if item and item["result"] is None:
                    item["result"] = {"ok": value.get("ok") is True,
                                      "message": str(value.get("message", ""))[:1000]}

    def state(self) -> dict:
        with self.lock:
            alive = not self.closed and self.last_seen > 0 and self.clock() - self.last_seen < HEARTBEAT
            return {"connected": alive, **self.snapshot, "available": alive and self.snapshot.get("available") is True}

    def submit(self, value: dict) -> tuple[int, dict]:
        with self.lock:
            previous = self.commands.get(value["id"])
            if previous:
                if previous["command"] != value:
                    return 409, {"message": "That command ID already names a different request."}
                return 200, self._receipt(value["id"], previous)
            if not self.state()["connected"]:
                return 503, {"message": "The Mac app is not responding. Reconnect before sending."}
            if len(self.commands) >= MAX_COMMANDS:
                return 429, {"message": "Restart phone control on the Mac to begin a new session."}
            item = {"command": value, "result": None}
            self.commands[value["id"]] = item
            # The id is kept even if the pipe breaks: a retry must not repeat an action that may have run.
            try:
                self.emit({"type": "command", **value})
            except (OSError, ValueError):
                self.closed = True
                return 503, {"message": "Mac connection lost. Check the task on the Mac before retrying."}
            return 202, self._receipt(value["id"], item)

    @staticmethod
    def _receipt(ident: str, item: dict) -> dict:
        return {"id": ident, "result": item["result"]}

    def receipt(self, ident: str) -> tuple[int, dict]:
        with self.lock:
            item = self.commands.get(ident)
            return (200, self._receipt(ident, item)) if item else (404, {"message": "Unknown command."})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False
    request_queue_size = 16

    def __init__(self, port: int, allowed_origin: str | None, relay: Relay):
        self.relay = relay
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        # Every open connection: when it was accepted, whether its headers are in, and its stop signal.
        self.open: dict[socket.socket, _Connection] = {}
        self.open_lock = threading.Lock()
        super().__init__(("127.0.0.1", port), Handler)
        try:
            # Port 0 (tests) binds a free port; the loopback origin then names the port it got.
            requested = None if allowed_origin == "http://127.0.0.1:0" and port == 0 else allowed_origin
            self.origin = origin(requested or f"http://127.0.0.1:{self.server_port}", self.server_port)
            self.host = urlsplit(self.origin).netloc
        except Exception:
            self.server_close()
            raise

    def server_bind(self):
        # HTTPServer.server_bind asks DNS for the host's full name, which can stall for many seconds
        # on some networks. The listener is always 127.0.0.1 and never uses that name.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            # Full: make room by closing the oldest connection still sending its headers, which a
            # real browser does at once, rather than turning the new one away.
            with self.open_lock:
                waiting = [c for c in self.open.values() if not c.headers_read]
                oldest = min(waiting, key=lambda c: c.accepted, default=None)
            if oldest is not None:
                oldest.stop()
            if oldest is None or not self.slots.acquire(timeout=EVICT_WAIT):
                self.shutdown_request(request)
                return
        with self.open_lock:
            self.open[request] = _Connection(request)
        try:
            super().process_request(request, client_address)
        except Exception:
            self._closed(request)
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._closed(request)

    def _closed(self, request) -> None:
        with self.open_lock:
            self.open.pop(request, None)
        self.slots.release()

    def handle_error(self, request, client_address):
        pass  # nothing is logged: no request data, no access key


class _Connection:
    """One accepted connection, as the listener tracks it to free its slot."""

    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.accepted = time.monotonic()
        self.headers_read = False
        self.expired = threading.Event()

    def stop(self) -> None:
        """Ends the connection: any further read refuses, and the socket is shut, so a read waiting
        on it returns and the connection's slot is freed."""
        self.expired.set()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


class _BoundedInput:
    """A connection's input that refuses to go past a byte limit, or on once the request's deadline
    has passed. Refusing ends the request: the connection is closed with no answer."""

    def __init__(self, raw, limit: int, expired: threading.Event):
        self.raw, self.left, self.expired = raw, limit, expired

    def allow(self, n: int) -> None:
        self.left += n

    def _take(self, data: bytes) -> bytes:
        if self.expired.is_set():
            raise TimeoutError("the request took too long")
        self.left -= len(data)
        if self.left < 0:
            raise ConnectionAbortedError("the request is too large")
        return data

    def readline(self, size: int = -1) -> bytes:
        return self._take(self.raw.readline(size))

    def read(self, size: int = -1) -> bytes:
        return self._take(self.raw.read(size))

    def __getattr__(self, name):
        return getattr(self.raw, name)


class Handler(BaseHTTPRequestHandler):
    server: Server
    server_version = "Benji"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(IDLE_TIMEOUT)
        with self.server.open_lock:
            self.tracked = self.server.open.get(self.request) or _Connection(self.request)
        self.rfile = _BoundedInput(self.rfile, MAX_HEAD, self.tracked.expired)
        self._arm(HEADER_DEADLINE)

    def _arm(self, seconds: float) -> None:
        """Ends the connection after `seconds` unless the request has been read (or answered) by then."""
        self.deadline = threading.Timer(max(seconds, 0.0), self.tracked.stop)
        self.deadline.daemon = True
        self.deadline.start()

    def parse_request(self):
        ok = super().parse_request()
        if ok:
            # Headers in: from here only a POST's body is still read, until the whole-request deadline.
            self.tracked.headers_read = True
            self.deadline.cancel()
            self._arm(REQUEST_DEADLINE - (time.monotonic() - self.tracked.accepted))
        return ok

    def finish(self):
        self.deadline.cancel()
        super().finish()

    def log_message(self, *_):
        pass

    def reply(self, status: int, body, mime="application/json; charset=utf-8", headers=None):
        self.deadline.cancel()      # the request has been read: from here only the answer is written
        raw = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        if status != 304:
            self.send_header("Content-Length", str(len(raw)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(raw)
        except OSError:
            pass

    def allowed(self, *, authenticated=False, mutation=False):
        """One exact Host, and an Origin (when sent) that is the listener's own. A cross-site request
        is refused, except a top-level page open of the page itself; the API needs the access key and
        every POST needs the Origin."""
        hosts = self.headers.get_all("Host", [])
        origins = self.headers.get_all("Origin", [])
        if hosts != [self.server.host] or (origins and origins != [self.server.origin]):
            self.reply(403, {"message": "Wrong host or origin."})
            return False
        navigation = (not authenticated and not mutation
                      and self.headers.get("Sec-Fetch-Mode") == "navigate"
                      and self.headers.get("Sec-Fetch-Dest") == "document")
        if not navigation and self.headers.get("Sec-Fetch-Site") not in (None, "same-origin", "none"):
            self.reply(403, {"message": "Open Benji's own page."})
            return False
        if mutation and origins != [self.server.origin]:
            self.reply(403, {"message": "Missing origin."})
            return False
        if authenticated:
            auth = self.headers.get_all("Authorization", [])
            expected = "Bearer " + self.server.relay.token
            if len(auth) != 1 or not hmac.compare_digest(auth[0].encode(), expected.encode()):
                self.reply(401, {"message": "Enter the current access key from the Mac."})
                return False
        return True

    def do_GET(self):
        if not self.allowed(authenticated=self.path.startswith("/api/")):
            return
        if self.path in ASSETS:
            name, mime = ASSETS[self.path]
            self.reply(200, (Path(__file__).with_name("remote_web") / name).read_bytes(), mime)
        elif self.path == "/api/state":
            raw = json.dumps(self.server.relay.state(), ensure_ascii=True, sort_keys=True).encode()
            etag = '"' + hashlib.sha256(raw).hexdigest() + '"'
            unchanged = self.headers.get("If-None-Match") == etag
            self.reply(304 if unchanged else 200, b"" if unchanged else raw, headers={"ETag": etag})
        elif self.path.startswith("/api/receipt/") and ID.fullmatch(self.path[len("/api/receipt/"):]):
            self.reply(*self.server.relay.receipt(self.path[len("/api/receipt/"):]))
        else:
            self.reply(404, {"message": "Not found."})

    def do_POST(self):
        if not self.allowed(authenticated=True, mutation=True):
            return
        if self.path != "/api/command":
            self.reply(404, {"message": "Not found."})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not lengths[0].isdigit():
            self.reply(400, {"message": "A bounded request body is required."})
            return
        size = int(lengths[0])
        if size < 2 or size > MAX_BODY:
            self.reply(413, {"message": "Request too large."})
            return
        if self.headers.get("Content-Type") != "application/json":
            self.reply(415, {"message": "Use JSON."})
            return
        self.rfile.allow(size)
        try:
            value = command(json.loads(self.rfile.read(size)))
        except (ValueError, UnicodeError, TypeError, RecursionError):
            self.reply(400, {"message": "Invalid command."})
            return
        self.reply(*self.server.relay.submit(value))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    write_lock = threading.Lock()

    def emit(value):
        with write_lock:
            sys.stdout.write(json.dumps(value, ensure_ascii=True) + "\n")
            sys.stdout.flush()

    relay = Relay(emit)
    try:
        server = Server(args.port, args.origin, relay)
    except (OSError, ValueError):
        emit({"type": "error", "message": f"Couldn't open phone control. Check the address and whether port {args.port} is free."})
        return 1
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
    worker.start()
    emit({"type": "ready", "token": relay.token, "origin": server.origin})
    try:
        # Only the app's snapshots and results arrive here. Nothing is imported from the engine and no file is written.
        while raw := sys.stdin.buffer.readline(2_000_001):
            if len(raw) > 2_000_000 or not raw.endswith(b"\n"):
                break
            try:
                value = json.loads(raw)
                if isinstance(value, dict):
                    relay.receive(value)
            except (ValueError, UnicodeError):
                break
    finally:
        relay.closed = True
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
