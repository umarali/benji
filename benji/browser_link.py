"""The local link between Benji's engine and the browser extension (D-143, step 1).

The engine is the server: a TCP listener on 127.0.0.1 only, on a port the system picks, behind a
token made fresh for each run. The native-messaging host (benji/browser_host.py, started by
Chrome when the extension connects) is the client: it reads the port and token from `link.json`,
says hello with the token and the extension's origin, and from then on relays lines between the
engine and the extension.

  - `link.json` is the only place the token is kept: a private folder (0700), the file 0600, written
    whole and renamed, removed when the link stops. It is not in the job record, an event, an
    argument, the environment of any tool or any log; `gate.private_path` keeps every file tool away
    from the folder.
  - A connection that doesn't say hello within a few seconds, says it badly, has the wrong token or
    names another extension is closed without a word. A second good connection replaces the first.
  - The engine only ever sends requests {id, op, ...} and only ever believes replies that carry the id
    of a request it sent. Anything else the host or a page sends is dropped.

Nothing in this module reads or decides anything about pages: that is benji/browser.py (rules) and
benji/tools.py (the tools).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import itertools
import json
import os
import queue
import secrets
import socket
import threading
from pathlib import Path
from typing import Callable

from . import audit

PROTOCOL = 1
HOST_NAME = "com.emerssive.heybenji.browser"
# The one extension this build talks to: the id Chrome derives from the `key` in
# browser-extension/manifest.json (selftest.py checks they agree). A Web Store build would be another id.
EXTENSION_IDS = ("oifkoajmlonknfkpeecajlncpjbjmfef",)
LINK_FILE = "link.json"
MAX_LINE = 2_000_000            # bytes in one line from the host
MAX_HELLO = 4096
CALL_TIMEOUT = 40.0             # seconds one request may take (a page load is up to 15)


class LinkError(Exception):
    """The extension can't be reached, or didn't answer; the text is for the model and the user."""


def default_dir() -> Path:
    override = os.environ.get("BENJI_BROWSER_DIR") or os.environ.get("CHILLY_BROWSER_DIR")
    return Path(override) if override else Path.home() / "Library" / "Application Support" / "Benji" / "Browser"


def extension_id_from_key(key_b64: str) -> str:
    """The id Chrome gives an extension whose manifest has this `key`: the first 16 bytes of the
    SHA-256 of the public key, each hex digit written as a letter from a to p."""
    digest = hashlib.sha256(base64.b64decode(key_b64)).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def origin_for(extension_id: str) -> str:
    return f"chrome-extension://{extension_id}/"


def _end(sock: socket.socket | None) -> None:
    """Close a connection so its other end sees it end at once. (A plain close() waits for every
    file object made from the socket, such as the reading thread's, so the peer would never know.)"""
    if sock is None:
        return
    for action in (lambda: sock.shutdown(socket.SHUT_RDWR), sock.close):
        try:
            action()
        except OSError:
            pass


class Link:
    """Off until `start()`. States for the app: off, waiting (listening, no extension yet),
    connected."""

    def __init__(self, directory: str | Path | None = None, allowed_ids=EXTENSION_IDS,
                 on_state: Callable[[str], None] | None = None, handshake_timeout: float = 5.0):
        self.dir = Path(directory) if directory else default_dir()
        self._origins = {origin_for(i) for i in allowed_ids}
        self.on_state = on_state or (lambda state: None)    # the engine sets it: one event per change
        self._handshake_timeout = handshake_timeout
        self._token = ""
        self._server: socket.socket | None = None
        self._conn: socket.socket | None = None
        self._pending: dict[str, queue.Queue] = {}
        self._ids = itertools.count(1)
        self._lock = threading.RLock()
        self._send_lock = threading.Lock()
        self._state = "off"
        self._rejected = "bad_hello"

    def __repr__(self) -> str:                  # never the token
        return f"<Link {self._state}>"

    @property
    def state(self) -> str:
        return self._state

    @property
    def running(self) -> bool:
        return self._server is not None

    @property
    def connected(self) -> bool:
        return self._conn is not None

    @property
    def path(self) -> Path:
        return self.dir / LINK_FILE

    # ---- start and stop ---------------------------------------------------------------------

    def start(self) -> None:
        with self._lock:
            if self._server is not None:
                return
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.bind(("127.0.0.1", 0))
            server.listen(4)
            self._token = secrets.token_urlsafe(32)
            self._server = server
            self._write_file(server.getsockname()[1])
            threading.Thread(target=self._accept_loop, args=(server,), daemon=True).start()
        self._set_state("waiting")

    def stop(self) -> None:
        with self._lock:
            server, conn = self._server, self._conn
            self._server, self._conn = None, None
            token, self._token = self._token, ""
            pending, self._pending = self._pending, {}
        _end(server)
        _end(conn)
        for q in pending.values():
            q.put(None)
        if token:
            self._remove_file(token)
        self._set_state("off")

    def _write_file(self, port: int) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        tmp = self.dir / (LINK_FILE + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"protocol": PROTOCOL, "port": port, "token": self._token, "pid": os.getpid()}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    def _remove_file(self, token: str) -> None:
        """Remove link.json if it is still ours (a newer engine's file stays)."""
        try:
            if json.loads(self.path.read_text()).get("token") == token:
                self.path.unlink()
        except (OSError, ValueError, AttributeError):
            pass

    def _set_state(self, state: str) -> None:
        if state != self._state:
            self._state = state
            audit.event("browser_link", state=state)
            self.on_state(state)

    # ---- the host's connection ----------------------------------------------------------------

    def _accept_loop(self, server: socket.socket) -> None:
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return                          # closed by stop()
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _read_line(self, reader, limit: int) -> bytes | None:
        line = reader.readline(limit + 1)
        return line if line.endswith(b"\n") and len(line) <= limit else None

    def _serve(self, conn: socket.socket) -> None:
        try:
            conn.settimeout(self._handshake_timeout)
            reader = conn.makefile("rb")
            line = self._read_line(reader, MAX_HELLO)
            hello = self._check_hello(line)
            if hello is None:
                conn.close()
                audit.event("browser_link", state="rejected", code=self._rejected)
                return
            conn.sendall(b'{"ready": true}\n')
            conn.settimeout(None)
        except (OSError, ValueError):
            try:
                conn.close()
            except OSError:
                pass
            return
        with self._lock:
            if self._server is None:
                conn.close()
                return
            old, self._conn = self._conn, conn
        _end(old)
        self._set_state("connected")
        try:
            while True:
                line = self._read_line(reader, MAX_LINE)
                if line is None:
                    break
                self._deliver(line)
        except (OSError, ValueError):
            pass
        with self._lock:
            mine = self._conn is conn
            if mine:
                self._conn = None
            pending, self._pending = (self._pending, {}) if mine else ({}, self._pending)
        for q in pending.values():
            q.put(None)
        _end(conn)
        if mine and self._server is not None:
            self._set_state("waiting")

    def _check_hello(self, line: bytes | None) -> dict | None:
        """The host's first line, if it is a good hello: the right token and an allowed extension.
        Why it wasn't (audit.LINK_CODES, never the token or the origin) is left in `_rejected`."""
        self._rejected = "bad_hello"
        if line is None:
            return None
        try:
            hello = json.loads(line).get("hello")
            token, origin, protocol = hello.get("token"), hello.get("origin"), hello.get("protocol")
        except (ValueError, AttributeError):
            return None
        with self._lock:
            ours = self._token
        if not (isinstance(token, str) and ours and hmac.compare_digest(token.encode("utf-8", "replace"), ours.encode())):
            self._rejected = "bad_token"
            return None
        if protocol != PROTOCOL:
            self._rejected = "bad_protocol"
            return None
        if origin not in self._origins:
            self._rejected = "bad_origin"
            return None
        return hello

    def _deliver(self, line: bytes) -> None:
        """A line from the extension: only a reply to a request we sent is believed."""
        try:
            msg = json.loads(line)
        except ValueError:
            return
        if not isinstance(msg, dict) or not isinstance(msg.get("id"), str):
            return
        with self._lock:
            q = self._pending.pop(msg["id"], None)
        if q is not None:
            q.put(msg)

    # ---- requests -----------------------------------------------------------------------------

    def call(self, op: str, params: dict | None = None, timeout: float = CALL_TIMEOUT) -> dict:
        """One request to the extension; its reply {ok, ...}. Raises LinkError when the extension
        isn't connected, doesn't answer, or the link stops meanwhile."""
        with self._lock:
            conn = self._conn
            if self._server is None:
                raise LinkError("Browser access is off in Benji's settings.")
            if conn is None:
                raise LinkError("Benji's Chrome extension isn't connected. Chrome has to be open with the "
                                "Benji extension turned on; tell the user.")
            request_id = str(next(self._ids))
            answers: queue.Queue = queue.Queue(maxsize=1)
            self._pending[request_id] = answers
        line = (json.dumps({**(params or {}), "id": request_id, "op": op}, ensure_ascii=False) + "\n").encode()
        try:
            with self._send_lock:
                conn.sendall(line)
            reply = answers.get(timeout=timeout)
        except (OSError, queue.Empty) as e:
            with self._lock:
                self._pending.pop(request_id, None)
            raise LinkError("Chrome didn't answer in time." if isinstance(e, queue.Empty)
                            else "The connection to Chrome ended.") from None
        if reply is None:
            raise LinkError("The connection to Chrome ended.")
        return reply
