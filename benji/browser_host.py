"""Benji's native-messaging host (D-143, step 1). Chrome starts this when the Benji extension
connects; it is a relay and nothing else. Run as a script, by the launcher the app writes when the
user turns on Settings, Browser:  python3 -I benji/browser_host.py chrome-extension://<id>/

  Chrome (extension)  <-- 4-byte length + JSON on stdin/stdout -->  this host
  this host           <-- JSON lines over 127.0.0.1, with a token -->  the engine (benji/browser_link.py)

It reads the engine's port and token from link.json, checks the caller is our extension, says hello,
and then copies messages both ways. It reads no page, runs no command and writes nothing to disk.
Standard output is Chrome's channel: nothing else may print. Standard error says only fixed words,
never the token.

Standard library only, and no import from this package, so `python3 -I` can run it from anywhere.
"""

import json
import os
import socket
import stat
import struct
import sys
import threading
from pathlib import Path

PROTOCOL = 1
# The same id as benji/browser_link.py EXTENSION_IDS (selftest.py checks they agree).
ALLOWED_EXTENSION_IDS = ("oifkoajmlonknfkpeecajlncpjbjmfef",)
MAX_TO_EXTENSION = 1_000_000        # Chrome refuses a longer message from a host
MAX_FROM_EXTENSION = 8_000_000
MAX_LINE = 2_000_000
CONNECT_TIMEOUT = 3.0
HELLO_TIMEOUT = 5.0


def link_dir() -> Path:
    override = os.environ.get("BENJI_BROWSER_DIR") or os.environ.get("CHILLY_BROWSER_DIR")
    return Path(override) if override else Path.home() / "Library" / "Application Support" / "Benji" / "Browser"


def read_link(directory: Path) -> tuple[int, str]:
    """(port, token) from link.json, if it is ours alone: a regular file, owned by this user,
    readable by nobody else. Raises ValueError (with a fixed message) otherwise."""
    path = directory / "link.json"
    try:
        info = os.stat(path)
    except OSError:
        raise ValueError("Benji isn't running or browser access is off") from None
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Benji's link file isn't private, so it wasn't used")
    try:
        data = json.loads(path.read_text())
        port, token = data["port"], data["token"]
    except (OSError, KeyError, TypeError, ValueError):
        raise ValueError("Benji isn't running or browser access is off") from None
    if not (isinstance(port, int) and 1 <= port <= 65535 and isinstance(token, str) and token):
        raise ValueError("Benji isn't running or browser access is off")
    return port, token


class Frames:
    """Chrome's native-messaging framing: a 4-byte length in the machine's byte order, then UTF-8 JSON."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self._lock = threading.Lock()

    def read(self):
        head = self.reader.read(4)
        if len(head) < 4:
            return None
        (size,) = struct.unpack("=I", head)
        if size > MAX_FROM_EXTENSION:
            return None
        body = self.reader.read(size)
        return body if len(body) == size else None

    def write(self, obj: dict) -> bool:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        if len(body) > MAX_TO_EXTENSION:
            return False
        with self._lock:
            self.writer.write(struct.pack("=I", len(body)) + body)
            self.writer.flush()
        return True


def say(frames: Frames, reason: str) -> None:
    try:
        frames.write({"type": "unavailable", "reason": reason})
    except (OSError, ValueError):
        pass


def main(argv: list[str], stdin=None, stdout=None) -> int:
    frames = Frames(stdin or sys.stdin.buffer, stdout or sys.stdout.buffer)
    origin = next((a for a in argv[1:] if a.startswith("chrome-extension://")), "")
    if origin not in {f"chrome-extension://{i}/" for i in ALLOWED_EXTENSION_IDS}:
        say(frames, "this host only serves Benji's own extension")
        return 2
    try:
        port, token = read_link(link_dir())
        sock = socket.create_connection(("127.0.0.1", port), timeout=CONNECT_TIMEOUT)
    except (ValueError, OSError) as e:
        say(frames, str(e) if isinstance(e, ValueError) else "Benji isn't running or browser access is off")
        return 1
    try:
        sock.settimeout(HELLO_TIMEOUT)
        sock.sendall(json.dumps({"hello": {"token": token, "origin": origin, "protocol": PROTOCOL}}).encode() + b"\n")
        reader = sock.makefile("rb")
        answer = reader.readline(MAX_LINE + 1)
        if json.loads(answer).get("ready") is not True:
            raise ValueError
        sock.settimeout(None)
    except (OSError, ValueError, AttributeError):
        say(frames, "Benji's engine didn't accept this connection")
        return 1
    token = ""                                  # not needed again
    frames.write({"type": "ready"})

    def to_extension() -> None:
        try:
            while True:
                line = reader.readline(MAX_LINE + 1)
                if not line.endswith(b"\n") or len(line) > MAX_LINE:
                    break
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if isinstance(msg, dict) and not frames.write(msg):
                    frames.write({"id": msg.get("id", ""), "ok": False, "error": "message too large"})
        except (OSError, ValueError):
            pass
        os._exit(0)                             # the engine went away: end, so Chrome sees the port close

    threading.Thread(target=to_extension, daemon=True).start()
    try:
        while True:
            body = frames.read()
            if body is None:
                break
            try:
                msg = json.loads(body)
            except ValueError:
                continue
            if isinstance(msg, dict):
                sock.sendall(json.dumps(msg, ensure_ascii=False).encode() + b"\n")
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
