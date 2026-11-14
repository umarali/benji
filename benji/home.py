"""Benji's one home folder, `~/.benji`, and the one-time move into it from the older names.

Everything Benji writes (jobs, logs, answers, policy, schedules, memory, skills, notes, exports)
lives in one hidden folder in the home folder. `BENJI_WORKDIR` (or `--workdir`, or the older
`CHILLY_WORKDIR` / `PAL_WORKDIR`) stays the single override, with the same meaning in the engine and the
app, and the migration below never runs when one of them is set.

The move into `~/.benji`, once, from the newest of `~/.chilly`, `~/chilly`, `~/pal` that is really a store
(`~/.chilly` holding anything; the other two, ordinary names, need a sign of the store and must not be a code clone):

  * the old folder is there and `~/.benji` is not (or is an empty folder): one atomic `rename` (same
    volume, same parent, same inode, so contents, ids, dates and modes are the very same files, and there
    is no second copy of anything private). If a rename is impossible the folder is copied to a
    temporary sibling, checked against the original (every path, type, size, mode, link target, date and
    file hash), and only then renamed into place; the old folder is kept. Nothing here deletes data.
  * both hold something: `~/.benji` is used, nothing is moved or merged, and one plain line says so, once per older store.
  * an old folder that is empty, as an old build recreates it after the move, is ignored: no conflict.
  * another Benji or Chilly app or engine is running with this home: nothing moves, the old folder keeps
    being used for this run, and one plain line says to quit it. Nothing is killed.
  * a marker `~/.benji/benji_migrated_from` holds only the kind of move, where from and the date.

Rollback: quit Benji, `rmdir ~/.chilly` if an old build recreated it empty, `mv ~/.benji ~/.chilly`, and `mv ~/.benji.env ~/.chilly.env`. Because the move is a rename there is no backup copy
of private data to leak or to go stale.

No other folder is ever looked at, listed or touched. The Swift twin (BenjiCore/HomeMigration.swift)
does the same for the app, which must not create `~/.benji` before it has run; both are tested against
companion/Tests/home-migration-cases.json.
"""

from __future__ import annotations

import hashlib
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

DIR_NAME = ".benji"
OLD_NAMES = (".chilly", "chilly", "pal")        # newest first; each is a name this store has had
MARKER = "benji_migrated_from"                  # the older `migrated_from` travels with the store, untouched
OLD_NOTED = "old_folder_noted_benji"            # + "-<name>": the "still there" line was shown for that folder (a date)
INCOMPLETE = ".benji-copy-incomplete"           # inside a temporary copy until it has been checked
DIR_MODE = 0o700
KEY_FILE = ".benji.env"
OLD_KEY_FILE = ".chilly.env"
KINDS = ("renamed", "copied", "left_old", "failed", "busy")
WORKDIR_VARIABLES = ("BENJI_WORKDIR", "CHILLY_WORKDIR", "PAL_WORKDIR")
GUARD_VARIABLE = "BENJI_MIGRATION_GUARD"
GUARD_EXIT = 96
IGNORED_WHEN_EMPTY = {".DS_Store"}
# What only Benji's own store holds. `~/chilly` and `~/pal` are ordinary names, so a folder called that is moved
# only with one of these in it, and never if it is a clone of the code.
STORE_SIGNS = ("answers.jsonl", "policy.json", "events.jsonl", "engine.log", "memory.jsonl", "voice.log", "latency.jsonl",
               "usage.jsonl")
NOT_A_STORE = (".git", "__main__.py", "chilly/__main__.py", "benji/__main__.py", "pal/__main__.py")


def notice_moved(old: str) -> str:
    return f"Benji moved its folder from ~/{old} to ~/{DIR_NAME}."


def notice_left_old(old: str) -> str:
    return f"An older ~/{old} folder still has files in it. Benji is using ~/{DIR_NAME}; nothing was merged or changed."


def notice_busy(old: str) -> str:
    return (f"Chilly or Benji is already running, so Benji did not move ~/{old} to ~/{DIR_NAME} yet; "
            "quit it and start Benji again.")


def notice_failed(old: str) -> str:
    return f"Benji could not move ~/{old} to ~/{DIR_NAME}, so it keeps using ~/{old} for now."


@dataclass(frozen=True)
class Result:
    kind: str = "none"
    notice: str = ""
    folder: Path | None = None      # the folder to use; differs from ~/.benji only for "failed" and "busy"


NONE = Result()
last: Result = NONE                 # what this process did, for `announce`


class MigrationGuardError(SystemExit):
    """A test tried to migrate something inside the owner's real home."""

    def __init__(self, path: Path):
        print(f"benji.home: refusing to migrate under the real home: {path}", flush=True)
        super().__init__(GUARD_EXIT)


def account_home() -> Path:
    """The real home, from the account record: `HOME` can be pointed anywhere, this can't."""
    return Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()


def check_guard(paths, env=None, real: Path | None = None) -> None:
    """With BENJI_MIGRATION_GUARD=abort (every test run sets it) stop dead if any source or destination
    resolves inside the real home. Unset in a real run, where moving the real folder is the point."""
    env = os.environ if env is None else env
    if env.get(GUARD_VARIABLE, "") != "abort":
        return
    real = real or account_home()
    for p in paths:
        resolved = Path(p).resolve()
        if resolved == real or real in resolved.parents:
            raise MigrationGuardError(resolved)


def home_dir(home: Path | None = None) -> Path:
    return (home or Path.home()) / DIR_NAME


_ENGINE = re.compile(r"(?:^|\s)-m\s+(?:benji|chilly|pal)(?:\s|$)")
_APP = re.compile(r"/(?:Benji|Chilly|PalCompanion|PalBar)\.app/Contents/MacOS/|/\.build/\S*/(?:BenjiApp|ChillyApp|PalCompanion)(?:\s|$)")
PROCESS_CHECK_FAILED = -1           # the check itself could not run: treated as "something may be running"


def other_processes(home: Path | None = None) -> list[int]:
    """Process ids of other Benji or Chilly engines or apps of this user that run with this home
    folder: a process whose command is `... -m benji ...` (or `-m chilly`) or one of the apps, with HOME
    equal to ours in its environment (`ps -E`; a process from another home, such as a test's, does not
    count). Never raises. Where `ps` cannot be run it answers [PROCESS_CHECK_FAILED]: a move that can't
    prove it is alone doesn't happen."""
    home = str((home or Path.home()))
    try:
        done = subprocess.run(["/bin/ps", "-E", "-ww", "-U", str(os.getuid()), "-o", "pid=,command="],
                              capture_output=True, text=True, errors="replace", timeout=10)
    except (OSError, subprocess.SubprocessError):
        return [PROCESS_CHECK_FAILED]
    if done.returncode != 0:
        return [PROCESS_CHECK_FAILED]
    out = done.stdout
    mine = {os.getpid(), os.getppid()}
    found = []
    for line in out.splitlines():
        pid_text, _, command = line.strip().partition(" ")
        if not pid_text.isdigit() or int(pid_text) in mine:
            continue
        if not (_ENGINE.search(command) or _APP.search(command)):
            continue
        if f" HOME={home} " in command + " " or " HOME=" not in command:
            found.append(int(pid_text))
    return found


def _today() -> str:
    return time.strftime("%Y-%m-%d")


def _exists(p: Path) -> bool:
    return os.path.lexists(p)           # a dangling link is still "there": never replace it


def _holds_something(folder: Path) -> bool:
    """A folder with anything in it but Finder's own note. Unreadable counts as holding something."""
    try:
        return bool(set(os.listdir(folder)) - IGNORED_WHEN_EMPTY)
    except OSError:
        return True


def write_marker(folder: Path, kind: str, source: str) -> None:
    """The marker: kind, where from and date, nothing else; never overwrites one that is there."""
    try:
        fd = os.open(folder / MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError:
        return
    with os.fdopen(fd, "w") as f:
        json.dump({"kind": kind, "from": source, "date": _today()}, f)
        f.write("\n")


def read_marker(folder: Path) -> dict:
    try:
        data = json.loads((folder / MARKER).read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _note_old(noted: Path) -> None:
    try:
        fd = os.open(noted, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError:
        return
    with os.fdopen(fd, "w") as f:
        f.write(_today() + "\n")


def _file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _tree(root: Path) -> dict[str, tuple]:
    """Every path under `root` (links not followed) as relative path -> (type, size, mode bits, link
    target, whole seconds of its date, file hash). The copy must match the original in all of them, or
    it is thrown away. Folder dates are left out: filling a folder changes its date."""
    out: dict[str, tuple] = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            p = Path(dirpath) / name
            st = os.lstat(p)
            kind = "d" if stat.S_ISDIR(st.st_mode) else "l" if stat.S_ISLNK(st.st_mode) else "f"
            out[str(p.relative_to(root))] = (kind, st.st_size if kind == "f" else 0,
                                             0 if kind == "l" else stat.S_IMODE(st.st_mode),
                                             os.readlink(p) if kind == "l" else "",
                                             int(st.st_mtime) if kind == "f" else 0,
                                             _file_hash(p) if kind == "f" else "")
    return out


def _copy_then_rename(old: Path, new: Path) -> bool:
    """The fallback when a rename is impossible: copy beside, check, then one rename into place.
    The old folder is never changed or removed. A temporary copy that an interrupted run left (it still
    holds the unfinished mark) is removed and started again; anything else at that name is left alone.
    False when anything fails (the copy is removed)."""
    temp = new.with_name(new.name + ".incoming")
    if _exists(temp):
        if temp.is_symlink() or not ((temp / INCOMPLETE).is_file() or (temp.is_dir() and not any(temp.iterdir()))):
            return False                # not ours: leave it alone
        shutil.rmtree(temp, ignore_errors=True)
        if _exists(temp):
            return False
    try:
        temp.mkdir(mode=DIR_MODE)
        (temp / INCOMPLETE).write_text("")
        shutil.copytree(old, temp, symlinks=True, dirs_exist_ok=True)
        copied = _tree(temp)
        copied.pop(INCOMPLETE, None)
        if _tree(old) != copied:
            raise OSError("the copy does not match the original")
        os.chmod(temp, DIR_MODE)
        os.rename(temp, new)
        (new / INCOMPLETE).unlink()             # last, so a crash at any point before can be cleaned up
        return True
    except (OSError, shutil.Error):
        shutil.rmtree(temp, ignore_errors=True)       # only what this function just made
        return False


def workdir_override(env=None) -> str:
    """The explicit working folder from the environment, newest name first; "" for none."""
    env = os.environ if env is None else env
    for name in WORKDIR_VARIABLES:
        value = env.get(name, "").strip()
        if value:
            return value
    return ""


def _is_store(folder: Path) -> bool:
    """Whether this old name really is Benji's. `~/.chilly` holding anything is. `~/chilly` and `~/pal` are
    ordinary names: they need a sign of the store and must not be a clone of the code."""
    if not os.path.isdir(folder) or not _holds_something(folder):
        return False
    if folder.name == OLD_NAMES[0]:
        return True
    return (not any(os.path.lexists(folder / part) for part in NOT_A_STORE)
            and any(os.path.lexists(folder / sign) for sign in STORE_SIGNS))


def _clear_empty(folder: Path) -> bool:
    """Take away a `~/.benji` that holds nothing, so a real store can move in. True when it's gone."""
    if folder.is_symlink():
        return False
    try:
        for name in IGNORED_WHEN_EMPTY & set(os.listdir(folder)):
            os.unlink(folder / name)
        os.rmdir(folder)
        return True
    except OSError:
        return False


def migrate(home: Path | None = None, environ: dict[str, str] | None = None, others=None) -> Result:
    """Move the old folder into `~/.benji` once. Does nothing when a working folder is set. Never raises
    (but for the test guard). Refuses ("busy") while another Benji or Chilly engine or app of this user
    runs with this home; `others` is that process check (a function of the home folder; tests pass their
    own). Touches only `~/.benji`, the old names, and one temporary sibling of `~/.benji`."""
    env = os.environ if environ is None else environ
    if workdir_override(env):
        return NONE
    home = home or Path.home()
    new = home_dir(home)
    check_guard([new, *(home / n for n in OLD_NAMES)], env)
    result = NONE
    label = OLD_NAMES[0]
    try:
        olds = [home / n for n in OLD_NAMES if _is_store(home / n)]
        if not olds:
            return NONE                 # no old store, or only an empty folder an old build made again
        old = olds[0]
        label = old.name
        new_is_empty = False
        if _exists(new):
            if not new.is_dir():
                return _remember(Result("failed", notice_failed(label), old))
            if _holds_something(new):
                for other in olds:      # each older store is mentioned once
                    noted = new / f"{OLD_NOTED}-{other.name}"
                    if not _exists(noted):
                        _note_old(noted)
                        if not read_marker(new):
                            write_marker(new, "left_old", other.name)
                        return _remember(Result("left_old", notice_left_old(other.name), new))
                return _remember(result)
            new_is_empty = True
        if (others or other_processes)(home):
            # Another Benji or Chilly holds the folder: moving it under a running engine could lose a write.
            return _remember(Result("busy", notice_busy(label), old))
        if new_is_empty and not _clear_empty(new):
            return _remember(Result("failed", notice_failed(label), old))
        how = ""
        try:                            # a link to a folder: the link itself is renamed, its target untouched
            os.rename(old, new)
            how = "renamed"
        except OSError:
            if not _exists(old) and _exists(new):
                return NONE             # another process finished this same move a moment ago
            how = "copied" if not old.is_symlink() and _copy_then_rename(old, new) else ""
        if not how:
            return _remember(Result("failed", notice_failed(label), old))
        if not new.is_symlink():        # a link's target is somebody's choice: its mode is left alone
            try:
                os.chmod(new, DIR_MODE)     # the folder itself only: what is inside is left as it was
            except OSError:
                pass
        write_marker(new, how, label)
        result = Result(how, notice_moved(label), new)
    except OSError:
        result = Result("failed", notice_failed(label), home / label)
    return _remember(result)


def migrate_key_file(home: Path | None = None, environ: dict[str, str] | None = None, others=None) -> str:
    """Rename `~/.chilly.env` to `~/.benji.env` once, losing nothing: "renamed", or "none", "busy", "failed".

    Link then unlink, because a plain rename would replace a `~/.benji.env` that appeared a moment ago. It is
    the same file, so its contents and private mode are kept and no second copy of a key is ever made. If
    `~/.benji.env` exists both stay and both are read, newest first; nothing is merged. Not while another
    Benji or Chilly runs, since an old build reads the old name. Any failure leaves the old file, which is
    still read. A link is moved as a link. Never raises (but for the test guard). Twin: HomeMigration.moveKeyFile."""
    env = os.environ if environ is None else environ
    if workdir_override(env):
        return "none"                   # the same rule as the data: a run told where to work moves nothing
    home = home or Path.home()
    old, new = home / OLD_KEY_FILE, home / KEY_FILE
    check_guard([old, new], env)
    try:
        if not _exists(old):
            return "none"
        before = os.lstat(old)
        if not (stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode)):
            return "none"
        half_done = False               # a run stopped between link and unlink leaves two names for one file
        if _exists(new):
            after = os.lstat(new)
            half_done = (after.st_dev, after.st_ino) == (before.st_dev, before.st_ino)
            if not half_done:
                return "none"
        if (others or other_processes)(home):
            return "busy"
        if not half_done:
            os.link(old, new, follow_symlinks=False)
        os.unlink(old)
        return "renamed"
    except OSError:
        return "failed"


def _remember(result: Result) -> Result:
    global last
    if result.kind != "none":
        last = result
    return result


def ensure(folder: Path) -> None:
    """Create `folder` mode 0700 if it is not there (only a folder this creates; one that exists is
    left as it is). Never raises."""
    try:
        if not folder.exists():
            folder.mkdir(mode=DIR_MODE, parents=True)
            if folder.name == DIR_NAME:
                os.chmod(folder, DIR_MODE)      # the umask must not widen it
    except OSError:
        pass


def announce() -> Result:
    """What the process did about the move, once: written to the audit log (the kind only) and
    returned for the caller to print or send. Call after `audit.configure`."""
    global last
    res, last = last, NONE
    if res.kind in KINDS:
        from . import audit
        audit.event("home_moved", how=res.kind)
    return res
