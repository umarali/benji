"""Upgrade checks for the rename to Benji, on real temporary files (no source-string guesses but where the
check is about source). Called from selftest.py. Every home here is a throwaway folder; `BENJI_MIGRATION_GUARD`
is on for the whole run, so a slip that aimed a migration at the real home stops the run instead."""

from __future__ import annotations

import builtins
import errno
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import venv as _venv
from pathlib import Path

NAMES = ("HOME", "BENJI_WORKDIR", "CHILLY_WORKDIR", "PAL_WORKDIR", "BENJI_KEY_SOURCE", "CHILLY_KEY_SOURCE", "PAL_KEY_SOURCE",
         "BENJI_MODEL", "CHILLY_MODEL", "PAL_MODEL", "BENJI_BASE_URL", "BENJI_API_KEY", "CHILLY_API_KEY", "PAL_API_KEY",
         "ANTHROPIC_API_KEY", "BENJI_UP_A", "CHILLY_UP_A", "PAL_UP_A", "BENJI_UP_B", "CHILLY_UP_B", "PAL_UP_B")


class Home:
    """A throwaway HOME with the settings variables cleared, restored afterwards."""

    def __init__(self, **env):
        self.env = env

    def __enter__(self) -> Path:
        self.td = tempfile.TemporaryDirectory()
        self.saved = {k: os.environ.get(k) for k in NAMES}
        self.home = Path(self.td.name).resolve() / "home"
        self.home.mkdir()
        for k in NAMES:
            os.environ.pop(k, None)
        os.environ["HOME"] = str(self.home)
        os.environ.update(self.env)
        return self.home

    def __exit__(self, *exc) -> None:
        for k, v in self.saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v
        self.td.cleanup()


def write(path: Path, text: str, mode: int = 0o600) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    os.chmod(path, mode)
    return path


def old_install(home: Path, name: str = ".chilly") -> Path:
    """A representative old store: every kind of thing the app keeps, made up here."""
    root = home / name
    job = "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
    end = {"spoken": "done", "written": "done", "files": [{"name": "a.txt", "path": str(root / "jobs" / job / "output" / "a.txt")}]}
    files = {"memory.jsonl": '{"text": "the user likes tea", "at": "2026-10-30T10:00:00"}\n', "answers.jsonl": "{}\n",
             "policy.json": '{"disable": ["web"]}', "events.jsonl": "{}\n", "engine.log": "l\n", "voice.log": "v\n", "usage.jsonl": "{}\n",
             "conversations/11111111-1111-4111-8111-111111111111.json":
                 json.dumps({"id": "11111111-1111-4111-8111-111111111111", "title": "Tea", "started": "2026-10-30T10:00:00Z",
                             "updated": "2026-10-30T10:01:00Z", "lines": [{"role": "assistant", "text": "I'm Chilly, happy to help."}]}),
             f"jobs/{job}/job.json": json.dumps({"id": job, "title": "T", "status": "finished", "turn_end": end}),
             f"jobs/{job}/report.md": "r\n", f"jobs/{job}/output/a.txt": "made\n", f"jobs/{job}.schedule.json": "{}",
             "skills/mine/SKILL.md": "s\n", "notes/n.md": "n\n", "voices/voices-v1.0.bin": "V", "voices/kokoro-v1.0.onnx": "M"}
    for rel, text in files.items():
        write(root / rel, text)
    os.chmod(root, 0o700)
    return root


def run(check, here: Path) -> None:
    from benji import aliases, config, conversations, gate as G, home as H, jobs, memory, prompts, runtime_check as RC, voice

    print("the rename to Benji, upgrade paths:")

    # ---- settings: which name and which file wins ---------------------------------------------------------
    with Home(CHILLY_UP_A="process-chilly", PAL_UP_A="process-pal", PAL_UP_B="process-pal") as home:
        write(home / ".benji.env", "BENJI_UP_A=file-benji\nBENJI_UP_B=file-benji\n")
        config.load_dotenv()
        check("a real variable under an older name beats every file", os.environ["BENJI_UP_A"] == "process-chilly")
        check("... CHILLY_* over PAL_*, and PAL_* still counts", os.environ["BENJI_UP_B"] == "process-pal")
    with Home(BENJI_UP_A="process-benji", CHILLY_UP_A="process-chilly") as home:
        config.load_dotenv()
        check("BENJI_* wins over CHILLY_* in the environment", os.environ["BENJI_UP_A"] == "process-benji")
    with Home() as home:
        write(home / ".pal.env", "PAL_UP_A=pal\nPAL_UP_B=pal\n")
        write(home / ".chilly.env", "CHILLY_UP_A=chilly\nBENJI_UP_B=chilly-file\n")
        write(home / ".benji.env", "BENJI_UP_A=benji\n")
        config.load_dotenv()
        check("~/.benji.env beats ~/.chilly.env", os.environ["BENJI_UP_A"] == "benji")
        check("~/.chilly.env beats ~/.pal.env", os.environ["BENJI_UP_B"] == "chilly-file")
    with Home() as home:
        write(home / ".chilly.env", "PAL_UP_A=pal\nCHILLY_UP_A=chilly\nBENJI_UP_A=benji\nCHILLY_UP_B=chilly\nPAL_UP_B=pal\n")
        config.load_dotenv()
        check("within one file: BENJI_* over CHILLY_* over PAL_*, whatever the order",
              os.environ["BENJI_UP_A"] == "benji" and os.environ["BENJI_UP_B"] == "chilly")
    with Home() as home:
        cwd = Path.cwd()
        try:
            there = home / "elsewhere"
            write(there / ".benji.env", "BENJI_UP_A=hostile\n")
            write(there / ".chilly.env", "CHILLY_UP_B=hostile\n")
            os.chdir(there)
            config.load_dotenv()
            check("no env file is ever read from the current folder", "BENJI_UP_A" not in os.environ and "BENJI_UP_B" not in os.environ)
        finally:
            os.chdir(cwd)
    with Home(CHILLY_WORKDIR="/tmp/from-env") as home:
        check("an explicit --workdir beats the environment", config.workdir_path(str(home / "cli")) == home / "cli")
        check("CHILLY_WORKDIR is honoured as the working folder, and nothing moves", config.workdir_path() == Path("/tmp/from-env"))
    check("names are mapped narrowly", aliases.canonical_name("CHILLY_MODEL") == "BENJI_MODEL" and aliases.canonical_name("ANTHROPIC_API_KEY")
          == "ANTHROPIC_API_KEY" and aliases.canonical_name("PALLADIUM") == "PALLADIUM")

    # ---- the key file is renamed, and nothing is lost ------------------------------------------------------
    with Home() as home:
        old = write(home / ".chilly.env", "ANTHROPIC_API_KEY=fake-k\nBENJI_UP_A=1\n")
        inode = old.stat().st_ino
        check("~/.chilly.env becomes ~/.benji.env", H.migrate_key_file(others=lambda h: []) == "renamed" and not old.exists())
        new = home / ".benji.env"
        check("... the same file: contents, private mode, no second copy of a key",
              new.read_text() == "ANTHROPIC_API_KEY=fake-k\nBENJI_UP_A=1\n" and stat.S_IMODE(new.stat().st_mode) == 0o600 and new.stat().st_ino == inode)
        check("... once", H.migrate_key_file(others=lambda h: []) == "none")
    with Home() as home:
        write(home / ".chilly.env", "A=old\n")
        write(home / ".benji.env", "A=new\n")
        check("an existing ~/.benji.env is never replaced, and both stay",
              H.migrate_key_file(others=lambda h: []) == "none" and (home / ".chilly.env").read_text() == "A=old\n" and (home / ".benji.env").read_text() == "A=new\n")
    with Home() as home:
        write(home / ".chilly.env", "A=old\n")
        check("not while another copy runs", H.migrate_key_file(others=lambda h: [4242]) == "busy" and (home / ".chilly.env").exists() and not (home / ".benji.env").exists())
    with Home() as home:
        target = write(home / "elsewhere.env", "A=1\n")
        os.symlink(target, home / ".chilly.env")
        check("a link moves as a link, its target untouched",
              H.migrate_key_file(others=lambda h: []) == "renamed" and os.readlink(home / ".benji.env") == str(target) and target.read_text() == "A=1\n")
    with Home(CHILLY_WORKDIR="/tmp/w") as home:
        write(home / ".chilly.env", "A=old\n")
        check("a working-folder override moves no key file, under any of its names",
              H.migrate_key_file(others=lambda h: []) == "none" and (home / ".chilly.env").exists())
    with Home() as home:
        old = write(home / ".chilly.env", "A=old\n")
        os.link(old, home / ".benji.env")
        check("a move stopped between link and unlink is finished", H.migrate_key_file(others=lambda h: []) == "renamed" and not old.exists()
              and (home / ".benji.env").read_text() == "A=old\n")
    with Home() as home:
        write(home / ".chilly.env", "ANTHROPIC_API_KEY=fake\n")
        os.environ["PAL_KEY_SOURCE"] = "keychain"
        real_others = H.other_processes
        H.other_processes = lambda h=None: []
        try:
            config.load_dotenv()
        finally:
            H.other_processes = real_others
        check("Keychain mode with only the old file: moved, and still no key read from it",
              (home / ".benji.env").exists() and "ANTHROPIC_API_KEY" not in os.environ)
    with Home() as home:
        (home / ".chilly.env").mkdir()
        check("a folder of that name is left alone", H.migrate_key_file(others=lambda h: []) == "none" and (home / ".chilly.env").is_dir())
    with Home() as home:
        old = write(home / ".chilly.env", "A=old\n")
        real_link = os.link

        def no_link(*a, **k):
            raise OSError(errno.EPERM, "no hard links here")

        os.link = no_link
        try:
            check("if it can't be moved the old file stays and is still read",
                  H.migrate_key_file(others=lambda h: []) == "failed" and old.read_text() == "A=old\n" and not (home / ".benji.env").exists())
        finally:
            os.link = real_link
    with Home() as home:
        write(home / ".chilly.env", "BENJI_UP_A=through-startup\n")
        real_others = H.other_processes
        H.other_processes = lambda h=None: []
        try:
            config.load_dotenv()
        finally:
            H.other_processes = real_others
        check("startup moves it and reads it from the new name", os.environ["BENJI_UP_A"] == "through-startup" and (home / ".benji.env").exists() and not (home / ".chilly.env").exists())

    # ---- Keychain mode fails closed under every name ------------------------------------------------------
    for name in ("BENJI_KEY_SOURCE", "CHILLY_KEY_SOURCE", "PAL_KEY_SOURCE"):
        with Home(**{name: "keychain"}) as home:
            write(home / ".benji.env", "ANTHROPIC_API_KEY=fake-benji\nBENJI_UP_A=kept\n")
            write(home / ".chilly.env", "CHILLY_API_KEY=fake-chilly\n")
            write(home / ".pal.env", "OPENAI_API_KEY=fake-pal\n")
            config.load_dotenv()
            check(f"{name}=keychain keeps every key line of every file out, and other settings in",
                  config.keys_from_keychain() and all(k not in os.environ for k in ("ANTHROPIC_API_KEY", "BENJI_API_KEY", "OPENAI_API_KEY"))
                  and os.environ["BENJI_UP_A"] == "kept")
    with Home(BENJI_KEY_SOURCE="file", CHILLY_KEY_SOURCE="keychain") as home:
        write(home / ".benji.env", "ANTHROPIC_API_KEY=fake\n")
        config.load_dotenv()
        check("a conflict between the names fails closed", config.keys_from_keychain() and "ANTHROPIC_API_KEY" not in os.environ)
    with Home() as home:
        write(home / ".benji.env", "ANTHROPIC_API_KEY=fake\n")
        write(home / ".pal.env", "PAL_KEY_SOURCE=keychain\n")
        config.load_dotenv()
        check("Keychain mode named in any file fails closed for all of them too", config.keys_from_keychain() and "ANTHROPIC_API_KEY" not in os.environ)
    with Home(ANTHROPIC_API_KEY="fake-handed-over", BENJI_KEY_SOURCE="keychain") as home:
        config.load_dotenv()
        check("the key the app hands over is still there in Keychain mode", os.environ["ANTHROPIC_API_KEY"] == "fake-handed-over")
    with Home() as home:
        write(home / ".chilly.env", "ANTHROPIC_API_KEY=fake-legacy\nCHILLY_API_KEY=fake-own\n")
        config.load_dotenv()
        check("file mode still reads an older key file, and CHILLY_API_KEY is BENJI_API_KEY",
              os.environ["ANTHROPIC_API_KEY"] == "fake-legacy" and os.environ["BENJI_API_KEY"] == "fake-own")

    # ---- the guard: never the real home ---------------------------------------------------------------------
    with Home() as home:
        real = home.parent / "the-real-home"
        real.mkdir()
        guard = {H.GUARD_VARIABLE: "abort"}
        def stopped(paths, env=guard):
            try:
                H.check_guard(paths, env, real)
            except SystemExit as e:
                return e.code
            return None
        check("the guard stops a source inside the real home", stopped([real / ".chilly"]) == H.GUARD_EXIT)
        check("... and the real home itself", stopped([real]) == H.GUARD_EXIT)
        os.symlink(real, home / "innocent")
        check("... and a path that only resolves there through a link", stopped([home / "innocent" / ".chilly"]) == H.GUARD_EXIT)
        check("... leaves a throwaway home alone", stopped([home / ".chilly", home / ".benji"]) is None)
        check("... and is off in a real run", stopped([real / ".chilly"], {}) is None)
        saved = H.account_home
        H.account_home = lambda: real
        write(real / ".chilly/memory.jsonl", "m")
        try:
            try:
                H.migrate(home=real, environ=guard, others=lambda h: [])
                code = None
            except SystemExit as e:
                code = e.code
        finally:
            H.account_home = saved
        check("migrate itself aborts on the simulated real home and moves nothing",
              code == H.GUARD_EXIT and (real / ".chilly/memory.jsonl").exists() and not (real / ".benji").exists())
    check("the account's home is from the account record, not from HOME", str(H.account_home()) != "/tmp/not-a-home")
    saved_home = os.environ.get("HOME")
    os.environ["HOME"] = "/tmp/not-a-home"
    try:
        check("... even with HOME pointed elsewhere", H.account_home() != Path("/tmp/not-a-home").resolve())
    finally:
        if saved_home is not None:
            os.environ["HOME"] = saved_home

    # ---- failures on the way ----------------------------------------------------------------------------
    real_rename = os.rename

    def no_rename(frm, to):
        if str(frm).endswith("/.chilly"):
            raise OSError(errno.EXDEV, "cross-device")
        return real_rename(frm, to)

    with Home() as home:
        old = old_install(home)
        write(home / ".benji.incoming" / H.INCOMPLETE, "")
        write(home / ".benji.incoming" / "half.txt", "left by a crash")
        os.rename = no_rename
        try:
            res = H.migrate(others=lambda h: [])
        finally:
            os.rename = real_rename
        check("a copy an interrupted run left is cleared and the copy done again, the old folder kept",
              res.kind == "copied" and (home / ".benji/memory.jsonl").exists() and old.exists() and not (home / ".benji.incoming").exists()
              and not (home / ".benji/half.txt").exists() and not (home / ".benji" / H.INCOMPLETE).exists())
        check("the copy keeps dates and private modes",
              stat.S_IMODE((home / ".benji/memory.jsonl").stat().st_mode) == 0o600
              and int((home / ".benji/memory.jsonl").stat().st_mtime) == int((old / "memory.jsonl").stat().st_mtime))
    with Home() as home:
        old_install(home)
        write(home / ".benji.incoming" / "someones.txt", "not ours")
        os.rename = no_rename
        try:
            res = H.migrate(others=lambda h: [])
        finally:
            os.rename = real_rename
        check("something else at the temporary name is left alone, and the old folder stays in use",
              res.kind == "failed" and res.folder == home / ".chilly" and (home / ".benji.incoming/someones.txt").read_text() == "not ours")
    with Home() as home:
        old_install(home)
        real_tree = H._tree
        calls = []

        def tampered(root):
            found = real_tree(root)
            calls.append(root)
            if str(root).endswith(".incoming"):
                found["memory.jsonl"] = ("f", 0, 0, "", 0, "different")
            return found

        H._tree = tampered
        os.rename = no_rename
        try:
            res = H.migrate(others=lambda h: [])
        finally:
            os.rename, H._tree = real_rename, real_tree
        check("a copy that doesn't match is thrown away: no profile appears and the old folder is whole",
              res.kind == "failed" and not (home / ".benji").exists() and not (home / ".benji.incoming").exists()
              and (home / ".chilly/memory.jsonl").exists())
    with Home() as home:
        old_install(home)
        def raced(frm, to):
            if str(to).endswith("/.benji"):
                real_rename(frm, to)
                raise OSError(errno.ENOENT, "gone")
            return real_rename(frm, to)
        os.rename = raced
        try:
            res = H.migrate(others=lambda h: [])
        finally:
            os.rename = real_rename
        check("two starts racing: the one that loses just finds the move done", res.kind == "none" and (home / ".benji/memory.jsonl").exists())
    with Home() as home:
        old_install(home)
        real_run = subprocess.run

        def no_ps(*a, **k):
            if a and a[0][0] == "/bin/ps":
                raise OSError("no ps here")
            return real_run(*a, **k)

        subprocess.run = no_ps
        try:
            res = H.migrate()
        finally:
            subprocess.run = real_run
        check("a process check that can't run means no move: it can't prove it is alone", res.kind == "busy" and (home / ".chilly").exists())
    with Home() as home:
        root = old_install(home)
        before = (root / "memory.jsonl").stat().st_ino
        os.chmod(root / "notes", 0)
        try:
            res = H.migrate(others=lambda h: [])
            check("an unreadable folder inside doesn't stop the rename, and nothing is copied",
                  res.kind == "renamed" and (home / ".benji/memory.jsonl").stat().st_ino == before)
        finally:
            os.chmod(home / ".benji/notes", 0o700)

    with Home() as home:
        old_install(home)
        real_run = subprocess.run

        class Failed:
            returncode, stdout = 1, ""

        subprocess.run = lambda *a, **k: Failed() if a and a[0][0] == "/bin/ps" else real_run(*a, **k)
        try:
            res = H.migrate()
        finally:
            subprocess.run = real_run
        check("a ps that runs and fails also means no move", res.kind == "busy" and (home / ".chilly").exists())
    with Home() as home:
        env = {"CHILLY_DIR": "/old-code", "CHILLY_MODEL": "m"}
        aliases.adopt(env)
        check("an old code-folder setting isn't taken as the new one", "BENJI_DIR" not in env and env["BENJI_MODEL"] == "m")
    spec_run = __import__("importlib.util").util.spec_from_file_location("isolated_run", here / "tools" / "isolated_run.py")
    harness = __import__("importlib.util").util.module_from_spec(spec_run)
    spec_run.loader.exec_module(harness)
    needed = {".benji.incoming", ".chilly", ".chilly.env", "chilly", ".benji", ".benji.env", "pal", ".pal.env", "Library/Application Support/Chilly/Browser",
              "Library/Preferences/com.chilly.app.plist", "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.chilly.browser.json"}
    check("the test harness watches every old and new store", needed <= set(harness.WATCHED) and "com.chilly.app.keys" in harness.KEYCHAIN_SERVICES)
    cleaned = harness.clean_environment(Path("/tmp/x"))
    check("the test harness drops the older variable names too", harness.STRIP_PREFIXES == ("BENJI_", "CHILLY_", "PAL_"))
    check("the test harness sets both homes", cleaned["HOME"] == cleaned["CFFIXED_USER_HOME"] == "/tmp/x")

    # ---- old store and the running product -----------------------------------------------------------------
    with Home() as home:
        old_install(home)
        H.last = H.NONE
        wd = config.workdir_path()
        check("the first start lands on ~/.benji, private", wd == home / ".benji" and stat.S_IMODE(wd.stat().st_mode) == 0o700)
        check("memory carries over", "tea" in memory.digest(wd / "memory.jsonl"))
        store = jobs.JobStore(jobs.folder(wd))
        check("a moved store's job record then moves out of the job's folder (D-177)", store.migrate() == 1)
        record = store.all()[0]
        path = record["turn_end"]["files"][0]["path"]
        check("a finished job's file is found at its new place", path == str(wd / "jobs" / record["id"] / "output" / "a.txt") and Path(path).is_file())
        on_disk = json.loads(store.record_path(record["id"]).read_text())
        check("... the stored record keeps its words", "/.chilly/" in on_disk["turn_end"]["files"][0]["path"])
        write(wd / "jobs/aaaaaaaa-5b7d-4e8f-9a0b-1c2d3e4f5a6b/job.json",
              json.dumps({"id": "aaaaaaaa-5b7d-4e8f-9a0b-1c2d3e4f5a6b", "title": "L", "status": "running"}))
        store.migrate()
        lost = store.load("aaaaaaaa-5b7d-4e8f-9a0b-1c2d3e4f5a6b")
        check("a job interrupted by the upgrade is still reported as failed, not resumed", jobs.derive_state(lost, False) == "failed")
        digest = conversations.digest(conversations.folder(wd))
        check("the saved chat is there", "Tea" in digest)
        saved_chat = next((wd / "conversations").glob("*.json")).read_text()
        check("saved messages keep their words", "I'm Chilly" in saved_chat)

    for surface in prompts.SURFACES:
        text = prompts.system_prompt("/tmp/w", memory="- calls the assistant Chilly", surface=surface,
                                     past="- Chat titled: Hey Chilly, what's the weather?")
        check(f"the {surface} prompt says it is Benji and reads older mentions as itself",
              text.startswith("You are Benji") and prompts.IDENTITY in text and "- calls the assistant Chilly" in text)
    with Home() as home:
        H.last = H.NONE
        check("a fresh install starts clean: a private ~/.benji and no move", config.workdir_path() == home / ".benji" and H.last.kind == "none"
              and stat.S_IMODE((home / ".benji").stat().st_mode) == 0o700)
        check("... with nothing old made", not any((home / n).exists() for n in (".chilly", "chilly", "pal")))

    # ---- the wake word -------------------------------------------------------------------------------------
    print("the name it answers to:")
    check("Hey Benji is heard", voice.heard_wake_word("hey Benji, open Mail", "benji") == (True, "open Mail"))
    for said in ("hey chilly, open Mail", "hey chili open Mail", "hey chilli open Mail"):
        check(f"{said!r} is not a wake phrase", voice.heard_wake_word(said, "benji")[0] is False)
    main_py = (here / "benji" / "__main__.py").read_text()
    check("--wake defaults to benji and listening stays something you ask for",
          re.search(r'"--wake", default="benji"', main_py) and '"--listen"' in main_py and 'action="store_true"' in main_py)

    # ---- the voice after a move -----------------------------------------------------------------------------
    print("the on-device voice after the move:")
    def venv_store(home: Path, with_module: bool) -> Path:
        old = home / ".chilly"
        _venv.EnvBuilder(with_pip=False, symlinks=True).create(old / "voice-venv")
        write(old / "voices/kokoro-v1.0.onnx", "MODEL")
        if with_module:
            site = next((old / "voice-venv/lib").glob("python*/site-packages"))
            write(site / "kokoro_onnx.py", "OK = 1\n", 0o644)
        write(old / "voice-venv/bin/pip", f"#!{old}/voice-venv/bin/python3\nprint('pip')\n", 0o755)
        write(old / "voice-venv/bin/activate", f'VIRTUAL_ENV="{old}/voice-venv"\n', 0o644)
        return old

    with Home() as home:
        venv_store(home, True)
        H.migrate(others=lambda h: [])
        venv = home / ".benji/voice-venv"
        status = RC.after_move()
        check("the moved voice environment is repaired and proven by running it", status == "repaired")
        check("its scripts name the new place", f"#!{venv}/bin/python3" in (venv / "bin/pip").read_text() and str(venv) in (venv / "bin/activate").read_text()
              and ".chilly" not in (venv / "bin/pip").read_text())
        check("the script keeps its mode", stat.S_IMODE((venv / "bin/pip").stat().st_mode) == 0o755)
        check("the models are left as they were", (home / ".benji/voices/kokoro-v1.0.onnx").read_text() == "MODEL")
        check("the check runs once", RC.after_move() == "" and (home / ".benji" / RC.CHECKED).read_text().startswith("repaired "))
    with Home() as home:
        venv_store(home, True)
        H.migrate(others=lambda h: [])
        os.environ["BENJI_WORKDIR"] = str(home / ".benji")          # how the app starts its engine
        check("the check also runs when the app names the folder, as it always does", RC.after_move() == "repaired")
    with Home() as home:
        write(home / "chosen/voice-venv/bin/python3", "x", 0o755)
        os.environ["BENJI_WORKDIR"] = str(home / "chosen")
        check("a folder the user chose, with no marker, is never touched", RC.after_move() == "")
    with Home() as home:
        venv_store(home, True)
        H.migrate(others=lambda h: [])
        real_probe = RC.probe
        RC.probe = lambda v, m=RC.PROBE_MODULES: None
        try:
            check("a voice too slow to tell is not called broken, and is checked again next time",
                  RC.after_move() == "" and not (home / ".benji" / RC.CHECKED).exists())
        finally:
            RC.probe = real_probe
    with Home() as home:
        venv_store(home, False)
        H.migrate(others=lambda h: [])
        check("a voice that can't start is reported, not reinstalled", RC.after_move() == "broken" and "voice-setup.sh" in RC.NOTICE_BROKEN)
    with Home() as home:
        old_install(home)
        H.migrate(others=lambda h: [])
        check("no voice installed: nothing to check, no complaint", RC.after_move() == "absent")
    with Home() as home:
        check("no move: no check", RC.after_move(home / ".benji") == "")

    # ---- what must keep matching in source -----------------------------------------------------------------
    print("names that must stay paired:")
    launches = [here / "browser-extension" / "test" / n for n in ("e2e-headless.py", "page-actions.test.mjs", "page-text.test.mjs")]
    check("test Chrome never asks macOS for a keychain (a throwaway home has none, and macOS shows a dialog)",
          all("--use-mock-keychain" in p.read_text() for p in launches if p.is_file()))
    swift = here / "companion" / "Sources"
    keep = (swift / "BenjiApp/DefaultsMigration.swift").read_text()
    copied = set(re.findall(r'"([A-Za-z]+)"', keep))
    never = set(re.findall(r'"([A-Za-z]+)"', keep[keep.index("neverCopied"):keep.index("static func run")]))
    constants = {"palDoneKey": "migratedFromPalCompanion", "FigureSetting.migrationKey": "figureStageSensing"}
    used = set()
    for f in swift.rglob("*.swift"):
        text = f.read_text()
        used |= set(re.findall(r'forKey: *"([A-Za-z]+)"', text))
        used |= set(re.findall(r'static let (?:[a-zA-Z]*[kK]ey|defaultsKey) *= *"([A-Za-z]+)"', text))
    used -= {"ANTHROPIC_API_KEY", "keychain"}
    missing = sorted(used - copied - set(constants.values()) - {"migratedFromChillyApp"})
    check("every setting the app stores is copied across, or named as never copied", not missing)
    if missing:
        print("   ", missing)
    check("no permission note is on the copy list",
          not (never & set(re.findall(r'"([A-Za-z]+)"', keep[keep.index("static let settings"):keep.index("neverCopied")]))) and "screenRecordingConfirmed" in never)
    host = "com.emerssive.heybenji.browser"
    check("the native host has one name in Python, Swift and JavaScript",
          f'HOST_NAME = "{host}"' in (here / "benji/browser_link.py").read_text()
          and f'hostName = "{host}"' in (swift / "BenjiCore/Browser.swift").read_text()
          and f'HOST = "{host}"' in (here / "browser-extension/service-worker.js").read_text())
    for sentinel in ("BENJI-APPROVE", "BENJI-EVENT"):
        check(f"{sentinel} is paired in the engine and the app",
              sentinel in main_py and sentinel in (swift / "BenjiCore/EngineEvent.swift").read_text())
    legacy_front_end = here / ("menu" + "bar") / "PalBar.swift"  # not in the public export, nor named there
    if legacy_front_end.is_file():
        check("the legacy front end speaks the same approval sentinel", "BENJI-APPROVE" in legacy_front_end.read_text())
    ignored = (here / ".gitignore").read_text().split()
    check("the key files stay out of git under every name", all(n in ignored for n in (".benji.env", ".chilly.env", ".pal.env")))
    with Home() as home:
        private = [(home / n) for n in (".benji.env", ".chilly.env", ".pal.env", "Library/Application Support/Benji/Browser/link.json",
                                        "Library/Application Support/Chilly/Browser/link.json")]
        check("every key file and link folder is private to the tools, old names too", all(G.private_path(p, home) for p in private))
        env = {"BENJI_A": "1", "CHILLY_B": "2", "PAL_C": "3", "PATH": "/bin"}
        check("no Benji, Chilly or Pal variable reaches a tool", G.tool_env(env) == {"PATH": "/bin"})

    tool = here / "tools" / "check_old_names.py"
    if tool.is_file() and (here / ".git").exists():     # it stays in the maintainer's repository
        import importlib.util
        spec = importlib.util.spec_from_file_location("check_old_names", tool)
        names = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(names)
        check("every old name left in maintained source has a stated reason", not names.scan()[1])
