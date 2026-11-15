"""Benji's folder, `~/.benji`.

Everything Benji writes (jobs, logs, answers, policy, schedules, memory, skills, notes, exports)
lives in one hidden folder in the home folder. `BENJI_WORKDIR` (or `--workdir`) is the single
override, with the same meaning in the engine and the app.
"""

from __future__ import annotations

import os
import pwd
from pathlib import Path

DIR_NAME = ".benji"
DIR_MODE = 0o700
WORKDIR_VARIABLE = "BENJI_WORKDIR"


def account_home() -> Path:
    """The real home, from the account record: `HOME` can be pointed anywhere, this can't."""
    return Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()


def home_dir(home: Path | None = None) -> Path:
    return (home or Path.home()) / DIR_NAME


def workdir_override(env=None) -> str:
    """The explicit working folder from the environment; "" for none."""
    env = os.environ if env is None else env
    return env.get(WORKDIR_VARIABLE, "").strip()


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
