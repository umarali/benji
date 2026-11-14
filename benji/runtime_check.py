"""After the data folder has moved, check once that the on-device voice still works from its new place.

The voice environment (`voice-venv`) moves with the folder. Its `python3` is a link and finds its new
location by itself, but pip's and activate's scripts carry the old absolute path in them. So, once:

  * bounded repair: the scripts directly in `voice-venv/bin` that name the old folder, and `pyvenv.cfg`, are
    rewritten to name the new one. Nothing else is changed and nothing is downloaded.
  * a real probe: `voice-venv/bin/python3` is run and must say its prefix is the new place and be able to
    import Kokoro. With a timeout, so a broken environment can't hold up the first start.
  * a report: the kind goes in a small file, and a broken environment gets one plain line saying what to run.

Only after a move this store has a marker for, and only once. Models, voices and the voice choice are never
touched. Never raises.
"""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

from . import home

CHECKED = "voice_runtime_checked"
VENV = "voice-venv"
PROBE_MODULES = ("kokoro_onnx",)
PROBE_SECONDS = 20
MAX_SCRIPT_BYTES = 128_000
NOTICE_BROKEN = ("Benji's on-device voice did not survive the folder move. Your models and voices are safe; "
                 "run ./voice-setup.sh again to repair it (it reuses the files you already have).")


def _write_status(folder: Path, status: str) -> None:
    try:
        fd = os.open(folder / CHECKED, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError:
        return
    with os.fdopen(fd, "w") as f:
        f.write(f"{status} {time.strftime('%Y-%m-%d')}\n")


def repair_paths(venv: Path, old: str, new: str) -> int:
    """Name the new folder in the environment's own scripts. How many files changed."""
    changed = 0
    old_bytes, new_bytes = old.encode(), new.encode()
    targets = [p for p in (venv / "bin").iterdir() if p.is_file() and not p.is_symlink()]
    targets.append(venv / "pyvenv.cfg")
    for path in targets:
        try:
            if not path.is_file() or path.stat().st_size > MAX_SCRIPT_BYTES:
                continue
            data = path.read_bytes()
            if old_bytes not in data:
                continue
            mode = path.stat().st_mode & 0o777
            temp = path.with_name(path.name + ".benji-new")
            temp.write_bytes(data.replace(old_bytes, new_bytes))
            os.chmod(temp, mode)
            os.replace(temp, path)
            changed += 1
        except OSError:
            continue
    return changed


def probe(venv: Path, modules=PROBE_MODULES) -> bool | None:
    """True when the moved environment runs from where it now is and can import the voice; None if it
    didn't answer in time, which says nothing either way."""
    code = "import sys\n" + "".join(f"import {m}\n" for m in modules) + "print(sys.prefix)"
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "")}
    try:
        done = subprocess.run([str(venv / "bin" / "python3"), "-I", "-c", code], env=env, capture_output=True,
                              text=True, timeout=PROBE_SECONDS)
    except subprocess.TimeoutExpired:
        return None
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0 and Path(done.stdout.strip()).resolve() == venv.resolve()


def after_move(folder: Path | None = None, modules=PROBE_MODULES) -> str:
    """Run once after a move. The status: "absent", "ok", "repaired", "broken", or "" if nothing was due."""
    # The app always names the folder through BENJI_WORKDIR, so the override can't mean "not moved": the
    # marker decides. A folder a user chose by hand has no marker and is never touched.
    if folder is None:
        chosen = home.workdir_override()
        folder = Path(chosen).expanduser() if chosen else home.home_dir()
    home.check_guard([folder])
    try:
        marker = home.read_marker(folder)
        if marker.get("kind") not in ("renamed", "copied") or os.path.lexists(folder / CHECKED):
            return ""
        venv = folder / VENV
        if not venv.is_dir():
            status = "absent"
        else:
            old = str(folder.parent / str(marker.get("from", "")) / VENV)
            repaired = repair_paths(venv, old, str(venv)) if marker.get("from") else 0
            proven = probe(venv, modules)
            if proven is None:
                return ""               # too slow to tell this time: try again at the next start
            status = "broken" if not proven else "repaired" if repaired else "ok"
        _write_status(folder, status)
        return status
    except OSError:
        return ""
