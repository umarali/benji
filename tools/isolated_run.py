#!/usr/bin/env python3
"""Run a test command so it cannot reach the owner's real Benji data.

    python3 tools/isolated_run.py -- python3 selftest.py
    python3 tools/isolated_run.py --home /tmp/fake -- xcrun swift test --skip-build

Why this exists: on macOS `HOME` alone is not enough. Python's `Path.home()` follows it, but Foundation's
`homeDirectoryForCurrentUser` ignores it and answers from the account record unless `CFFIXED_USER_HOME`
is set too. `UserDefaults` is not redirected by either: it still reaches the user's real preferences,
so settings migration is only ever tested through an injected store, never against a real domain.

What it does:
  * finds the owner's real home from the account record (never from an overridable `HOME`);
  * makes a throwaway home outside it, and sets `HOME` and `CFFIXED_USER_HOME` to that folder;
  * removes every Benji/Benji/Pal variable and every key variable from the environment;
  * sets `BENJI_MIGRATION_GUARD=abort`, which makes the migration code in this tree refuse any source or
    destination under the real home;
  * proves the Python path resolves to the throwaway home before it runs anything (and the Foundation
    path too, with --probe-swift);
  * takes a metadata fingerprint of the real stores (lstat only, nothing is opened) and fails with exit
    97 if the command changed any of them. This is also what protects a build too old to hold the guard.
  * removes only the throwaway `UserDefaults` suites this run's tests created in the real Preferences
    folder (random-UUID names, and never a real settings file). They can't be redirected; see above.
"""

from __future__ import annotations

import argparse
import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

GUARD_VARIABLE = "BENJI_MIGRATION_GUARD"
EXIT_REAL_HOME_CHANGED = 97
EXIT_NOT_ISOLATED = 98

SUITE = re.compile(r"^(?:chilly|benji)-[a-z0-9-]*-?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist$")
STRIP_PREFIXES = ("BENJI_", "CHILLY_", "PAL_")
STRIP_SUFFIXES = ("_API_KEY",)
STRIP_NAMES = {"SERPAPI_KEY"}

# Relative to the real home. Fingerprinted before and after; never opened.
WATCHED = (
    ".benji", ".benji.env", ".benji.incoming", ".chilly", ".chilly.env", "chilly", "pal", ".pal.env",
    "Library/Application Support/Benji", "Library/Application Support/Benji/Browser",
    "Library/Application Support/Chilly", "Library/Application Support/Chilly/Browser",
    "Library/Preferences/com.emerssive.heybenji.app.plist", "Library/Preferences/com.chilly.app.plist",
    "Library/Preferences/com.pal.companion.plist",
    "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.emerssive.heybenji.browser.json",
    "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.chilly.browser.json",
    "Library/LaunchAgents",
)
# Keychain services whose items (attributes only, never a value) are compared before and after. The login
# keychain's own file can't be fingerprinted: every other app on the Mac writes to it.
KEYCHAIN_SERVICES = ("com.emerssive.heybenji.app.keys", "com.chilly.app.keys")
# Folders whose direct entries are also fingerprinted (names and lstat only).
SHALLOW = (".benji", ".chilly")


def account_home() -> Path:
    return Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()


def _stat_line(path: Path) -> tuple | None:
    try:
        st = os.lstat(path)
    except OSError:
        return None
    return (st.st_mode, st.st_ino, st.st_size, st.st_mtime_ns)


def fingerprint(real: Path) -> dict[str, tuple | None]:
    seen: dict[str, tuple | None] = {rel: _stat_line(real / rel) for rel in WATCHED}
    for rel in SHALLOW:
        try:
            names = sorted(os.listdir(real / rel))
        except OSError:
            continue
        for name in names:
            seen[f"{rel}/{name}"] = _stat_line(real / rel / name)
    for service in KEYCHAIN_SERVICES:
        listed = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service],
                                capture_output=True, text=True)
        seen[f"keychain:{service}"] = (listed.returncode, hash(listed.stdout))
    return seen


def preference_suites(real: Path) -> set[str]:
    try:
        return {n for n in os.listdir(real / "Library/Preferences") if SUITE.match(n)}
    except OSError:
        return set()


def clean_environment(fake: Path) -> dict[str, str]:
    env = {}
    for key, value in os.environ.items():
        if key.startswith(STRIP_PREFIXES) or key.endswith(STRIP_SUFFIXES) or key in STRIP_NAMES:
            continue
        env[key] = value
    env["HOME"] = str(fake)
    env["CFFIXED_USER_HOME"] = str(fake)
    env[GUARD_VARIABLE] = "abort"
    return env


def under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent)
        return True
    except ValueError:
        return False


def prove_python(env: dict[str, str], fake: Path) -> None:
    got = subprocess.run([sys.executable, "-I", "-c", "from pathlib import Path; print(Path.home())"],
                         env=env, capture_output=True, text=True, check=True).stdout.strip()
    if Path(got).resolve() != fake.resolve():
        sys.exit(f"isolated_run: Python resolves home to {got}, not the throwaway one; nothing was run")


def prove_swift(env: dict[str, str], fake: Path) -> None:
    with tempfile.TemporaryDirectory() as td:
        source = Path(td) / "probe.swift"
        source.write_text('import Foundation\nprint(FileManager.default.homeDirectoryForCurrentUser.path)\n')
        binary = Path(td) / "probe"
        subprocess.run(["xcrun", "swiftc", str(source), "-o", str(binary)], check=True, capture_output=True)
        got = subprocess.run([str(binary)], env=env, capture_output=True, text=True, check=True).stdout.strip()
    if Path(got).resolve() != fake.resolve():
        sys.exit(f"isolated_run: Foundation resolves home to {got}, not the throwaway one; nothing was run")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", help="Use this throwaway folder as the home (made if missing; kept).")
    parser.add_argument("--probe-swift", action="store_true", help="Also prove Foundation's home resolves here.")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no command given")

    real = account_home()
    if args.home:
        fake = Path(args.home).expanduser()
        fake.mkdir(parents=True, exist_ok=True)
    else:
        fake = Path(tempfile.mkdtemp(prefix="benji-isolated-", dir="/private/tmp"))
    if under(fake, real) or real == fake.resolve():
        print(f"isolated_run: {fake} is inside the real home, refused", file=sys.stderr)
        return EXIT_NOT_ISOLATED

    env = clean_environment(fake)
    prove_python(env, fake)
    if args.probe_swift:
        prove_swift(env, fake)

    before, suites = fingerprint(real), preference_suites(real)
    code = subprocess.run(command, env=env).returncode
    time.sleep(1.5)                     # cfprefsd writes suites a moment after the process ends
    for name in preference_suites(real) - suites:
        try:
            os.unlink(real / "Library/Preferences" / name)
        except OSError:
            pass
    after = fingerprint(real)
    changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
    if changed:
        print("isolated_run: THE REAL HOME CHANGED during this run:", file=sys.stderr)
        for key in changed:
            print(f"  {key}", file=sys.stderr)
        return EXIT_REAL_HOME_CHANGED
    if not args.home:
        shutil.rmtree(fake, ignore_errors=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
