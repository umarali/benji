"""Log files only this user can read (D-144). Every file Benji appends a log to in the working
folder is created mode 0600, and one that already exists with a wider mode (answers.jsonl from before
this change was 0644) is tightened the first time it is written. The folder is never widened: a
folder this creates is 0700, one that exists is left as it is.

Rotation keeps `keep` older copies (`name.1` is the newest), each 0600, so a log is bounded at about
`max_bytes * (keep + 1)`.
"""

from __future__ import annotations

import os
import stat
import threading
from pathlib import Path

FILE_MODE = 0o600
DIR_MODE = 0o700

_lock = threading.Lock()
_tightened: set[str] = set()        # paths whose older copies this process has already checked


def tighten(path: str | Path) -> bool:
    """Make an existing regular file 0600 if it is wider. True when it changed. Never follows a
    symlink, never touches anything that isn't a plain file, never raises."""
    try:
        st = os.lstat(path)
        if stat.S_ISREG(st.st_mode) and st.st_mode & 0o077:
            os.chmod(path, FILE_MODE)
            return True
    except OSError:
        pass
    return False


def _size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def rotate(path: Path, keep: int) -> None:
    """name -> name.1 -> name.2 ... name.<keep>; the oldest is dropped. Each copy is 0600."""
    oldest = path.with_name(f"{path.name}.{keep}")
    try:
        oldest.unlink()
    except OSError:
        pass
    for i in range(keep - 1, 0, -1):
        src, dst = path.with_name(f"{path.name}.{i}"), path.with_name(f"{path.name}.{i + 1}")
        if src.exists():
            os.replace(src, dst)
            tighten(dst)
    os.replace(path, path.with_name(f"{path.name}.1"))
    tighten(path.with_name(f"{path.name}.1"))


def append(path: str | Path, text: str, *, max_bytes: int | None = None, keep: int = 1) -> None:
    """Append `text` to `path` (created 0600). Past `max_bytes` the file is rotated first. Raises
    OSError; callers decide what a failed log write means (for every log here: report, go on)."""
    path = Path(path)
    data = text.encode("utf-8")
    with _lock:
        if not path.parent.exists():
            path.parent.mkdir(parents=True, mode=DIR_MODE, exist_ok=True)
        key = str(path)
        if key not in _tightened:
            _tightened.add(key)
            for i in range(1, keep + 1):
                tighten(path.with_name(f"{path.name}.{i}"))
        size = _size(path)
        if max_bytes is not None and size > 0 and size + len(data) > max_bytes:
            rotate(path, keep)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), FILE_MODE)
        try:
            if os.fstat(fd).st_mode & 0o077:
                os.fchmod(fd, FILE_MODE)
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
        finally:
            os.close(fd)
