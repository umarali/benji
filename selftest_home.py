"""Checks for D-175, the engine side: Benji's one hidden home folder (~/.benji), the one-time move
into it from ~/.chilly, the gate's rules for both folders, and the export tool's default. Called from
selftest.py.

Every case runs against a temporary HOME (or a temporary BENJI_WORKDIR): nothing here looks at, lists,
reads or moves anything in the real home folder. The move's cases are in companion/Tests/home-migration-cases.json,
the table the app's Swift twin is tested against too.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def build(home: Path, spec: dict) -> None:
    for d in spec.get("dirs", []):
        (home / d).mkdir(parents=True, exist_ok=True)
    for rel, text in spec.get("files", {}).items():
        (home / rel).parent.mkdir(parents=True, exist_ok=True)
        (home / rel).write_text(text)
    for rel, target in spec.get("links", {}).items():
        (home / rel).parent.mkdir(parents=True, exist_ok=True)
        os.symlink(home / target, home / rel)


class IsolatedHome:
    """HOME and BENJI_WORKDIR pointed at a temporary folder for the length of the block."""

    def __init__(self, workdir: str | None = None, name: str = "BENJI_WORKDIR"):
        self.workdir = workdir
        self.name = name

    def __enter__(self) -> Path:
        self.td = tempfile.TemporaryDirectory()
        self.saved = {k: os.environ.get(k) for k in ("HOME", "BENJI_WORKDIR", "CHILLY_WORKDIR", "PAL_WORKDIR")}
        self.home = Path(self.td.name).resolve() / "home"
        self.home.mkdir()
        os.environ["HOME"] = str(self.home)
        for k in ("BENJI_WORKDIR", "CHILLY_WORKDIR", "PAL_WORKDIR"):
            os.environ.pop(k, None)
        if self.workdir:
            os.environ[self.name] = str(self.home.parent / self.workdir)
        return self.home

    def __exit__(self, *exc) -> None:
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.td.cleanup()


def run(check, here: Path) -> None:
    from benji import audit, config, home as H
    from benji import gate as G
    from benji import tools as T
    from benji import browser_act as BA
    from benji import policy

    print("Benji's one home folder, ~/.benji (D-175):")
    table = json.loads((here / "companion" / "Tests" / "home-migration-cases.json").read_text())

    # ---- the move, case by case (the table the Swift twin is tested against too) ----------------------
    for case in table["cases"]:
        with IsolatedHome(case.get("workdir_env"), case.get("workdir_name", "BENJI_WORKDIR")) as home:
            build(home, case["before"])
            kinds, notices = [], []
            for n in range(case.get("runs", 1)):
                H.last = H.NONE
                res = H.migrate(others=(lambda h: list(case["others"])) if case.get("others") else (lambda h: []))
                kinds.append(res.kind)
                notices.append(bool(res.notice))
                if n == 0 and case.get("afterFirstRun"):
                    build(home, case["afterFirstRun"])
            marker = H.read_marker(home / ".benji").get("kind")
            ok = kinds[0] == case["kind"] and notices[0] == case["notice"]
            if case.get("runs", 1) > 1:
                ok &= kinds[1] == case["secondKind"] and (notices[1] == case.get("secondNotice", False))
            if case.get("runs", 1) > 2:
                ok &= kinds[2] == case["thirdKind"]
            ok &= all(os.path.lexists(home / p) for p in case.get("exist", []))
            ok &= not any(os.path.lexists(home / p) for p in case.get("absent", []))
            ok &= all((home / p).read_text() == t for p, t in case.get("content", {}).items())
            if "marker" in case:
                ok &= marker == case["marker"]
            if "markerFrom" in case:
                ok &= H.read_marker(home / ".benji").get("from") == case["markerFrom"]
            if case.get("mode700"):
                ok &= stat.S_IMODE((home / ".benji").stat().st_mode) == 0o700
            check("move: " + case["name"], ok)
            if not ok:
                print("   got", kinds, notices, marker)

    # ---- a populated ~/.chilly moves whole: nothing missing, modes identical, no copy -----------------------
    def snapshot(root: Path) -> dict:
        out = {}
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            for name in dirnames + filenames:
                p = Path(dirpath) / name
                st = os.lstat(p)
                if stat.S_ISLNK(st.st_mode):
                    out[str(p.relative_to(root))] = ("l", os.readlink(p))
                elif stat.S_ISDIR(st.st_mode):
                    out[str(p.relative_to(root))] = ("d", stat.S_IMODE(st.st_mode))
                else:
                    out[str(p.relative_to(root))] = ("f", stat.S_IMODE(st.st_mode), p.read_bytes())
        return out

    with IsolatedHome() as home:
        old = home / ".chilly"
        jid = "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
        files = {"answers.jsonl": (0o600, "a\n"), "policy.json": (0o644, "{}"), "events.jsonl": (0o600, "e"), "events.jsonl.1": (0o600, "e1"),
                 "engine.log": (0o600, "l"), "voice.log": (0o600, "v"), "latency.jsonl": (0o600, "t"), "usage.jsonl": (0o644, "u"),
                 "memory.jsonl": (0o600, "m"), ".hidden": (0o644, "h"), f"jobs/{jid}/job.json": (0o600, "{}"),
                 f"jobs/{jid}/report.md": (0o644, "r"), f"jobs/{jid}/output/a/b/deep.txt": (0o600, "d"), f"jobs/{jid}/tmp/.keep": (0o644, ""),
                 f"jobs/{jid}.schedule.json": (0o600, "{}"), "skills/mine/SKILL.md": (0o644, "s"), "notes/n.md": (0o600, "n"),
                 "conversations/c.json": (0o600, "{}"), "output/old.txt": (0o644, "o"), "tmp/x": (0o644, "x"),
                 "voices/kokoro-v1.0.onnx": (0o644, "MODEL"), "voices/voices-v1.0.bin": (0o644, "VOICES")}
        for rel, (mode, text) in files.items():
            f = old / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(text)
            os.chmod(f, mode)
        os.chmod(old / "notes", 0o700)
        os.chmod(old / f"jobs/{jid}", 0o700)
        os.symlink("answers.jsonl", old / "link-to-answers")
        os.symlink("../../policy.json", old / f"jobs/{jid}/up-link")
        os.symlink(str(home / "elsewhere-target"), old / "dangling-abs")
        # a small venv whose python is a relative link chain ending outside it, like the real one
        import venv as _venv
        _venv.EnvBuilder(with_pip=False, symlinks=True).create(old / "voice-venv")
        os.chmod(old, 0o755)
        before = snapshot(old)
        inode = os.stat(old / "answers.jsonl").st_ino
        found = H.migrate(others=lambda h: [])
        after = snapshot(home / ".benji")
        for marker in (H.MARKER,):
            after.pop(marker, None)
        venv_rel = {k for k in before if k.startswith("voice-venv")}
        check("a populated ~/.chilly moves by rename: kind renamed, ~/.chilly no longer exists", found.kind == "renamed" and not os.path.lexists(old))
        check("nothing is missing or extra: every file, folder and link (hidden ones, nested job folders, schedule files, skills, notes, logs, the venv) is there",
              set(after) == set(before))
        check("every file's content and every folder's and file's mode is identical (0600 stays 0600, 0700 stays 0700), links point where they did",
              all(after[k] == before[k] for k in before))
        check("it was a rename, not a copy: the same inode, so the 425 MB of voices and the venv are never copied",
              os.stat(home / ".benji/answers.jsonl").st_ino == inode)
        check("the folder itself is tightened to 0700 and holds a marker; the 0600 files inside are still 0600",
              stat.S_IMODE((home / ".benji").stat().st_mode) == 0o700 and (home / ".benji" / H.MARKER).is_file()
              and stat.S_IMODE((home / ".benji/answers.jsonl").stat().st_mode) == 0o600
              and stat.S_IMODE((home / f".benji/jobs/{jid}").stat().st_mode) == 0o700)
        # the voice: every path function resolves under ~/.benji, and the moved venv still runs python
        from benji import tts
        wd = config.workdir_path()
        check("the voice paths resolve under ~/.benji after the move", tts.voices_dir() == home / ".benji/voices"
              and tts.venv_python() == home / ".benji/voice-venv/bin/python3" and wd == home / ".benji")
        probe = subprocess.run([str(tts.venv_python()), "-c", "import sys; print(sys.prefix)"], capture_output=True, text=True, timeout=30)
        check("a venv still works after being moved: its python finds its own new location (python -m, not a console script)",
              probe.returncode == 0 and Path(probe.stdout.strip()).resolve() == (home / ".benji/voice-venv").resolve())
            # nothing in the code runs a venv console script by path (only `python3 -m ...`)
    scripts = []
    for sub, pat in (("benji", "*.py"), ("companion/Sources", "*.swift")):
        for f in (here / sub).rglob(pat):
            for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
                if "voice-venv" in line and "bin/" in line and "bin/python3" not in line:
                    scripts.append(f"{f.relative_to(here)}:{n}")
    check("no code names a venv's pip, activate or other console script by path", not scripts)

    # ---- the marker: kind and date, nothing else; the audit event: the kind, nothing else ---------------
    with IsolatedHome() as home:
        build(home, {"files": {".chilly/answers.jsonl": "private words CANARY-home-71c3"}})
        wd = config.workdir_path()
        data = json.loads((wd / H.MARKER).read_text())
        check("the marker holds the kind and the date and nothing else",
              wd == home / ".benji" and set(data) == {"kind", "from", "date"} and data["from"] == ".chilly" and data["kind"] == "renamed"
              and len(data["date"]) == 10)
        check("the marker is mode 600", stat.S_IMODE((wd / H.MARKER).stat().st_mode) == 0o600)
        audit.configure(wd / audit.FILE_NAME)
        res = H.announce()
        audit.configure(None)
        lines = (wd / audit.FILE_NAME).read_text().splitlines() if (wd / audit.FILE_NAME).exists() else []
        events = [json.loads(l) for l in lines]
        check("one audit event, kind home_moved, how renamed, no path and none of the folder's content",
              len(events) == 1 and events[0]["kind"] == "home_moved" and events[0]["how"] == "renamed"
              and "CANARY-home-71c3" not in "".join(lines) and str(home) not in "".join(lines)
              and res.kind == "renamed")
        try:
            audit.validate_line(lines[0])
            valid = True
        except ValueError:
            valid = False
        check("... and it passes the audit log's own schema check", valid)
        check("announce reports a move once", H.announce().kind == "none")
        check("the notice is a plain line naming both folders", "~/.benji" in res.notice and "~/.chilly" in res.notice)

    # ---- never anything but the Benji-named folders ----------------------------------------------------
    with IsolatedHome() as home:
        decoys = {"Documents/tax.txt": "D", "benji-notes/a": "N", "Benji2/b": "B", ".benji.env": "KEY=1",
                  ".ssh/id_rsa": "S", "Library/Application Support/Benji/Browser/link.json": "{}"}
        build(home, {"files": {".chilly/answers.jsonl": "A", **decoys}})
        before = {p: (home / p).stat().st_mtime_ns for p in decoys}
        seen_rename, seen_scan = [], []
        real_rename, real_scandir, real_listdir = os.rename, os.scandir, os.listdir
        os.rename = lambda a, b, *x, **k: (seen_rename.append((str(a), str(b))), real_rename(a, b, *x, **k))[1]
        os.scandir = lambda p=".", *x, **k: (seen_scan.append(str(p)), real_scandir(p, *x, **k))[1]
        os.listdir = lambda p=".", *x, **k: (seen_scan.append(str(p)), real_listdir(p, *x, **k))[1]
        try:
            H.migrate(others=lambda h: [])
        finally:
            os.rename, os.scandir, os.listdir = real_rename, real_scandir, real_listdir
        check("the move renames exactly ~/.chilly to ~/.benji and never lists the home folder",
              seen_rename == [(str(home / ".chilly"), str(home / ".benji"))] and str(home) not in seen_scan)
        check("look-alike folders, the key file, ~/.ssh and the browser link folder are untouched",
              all((home / p).stat().st_mtime_ns == m for p, m in before.items())
              and all((home / p).read_text() == d for p, d in decoys.items()))

    # ---- the copy fallback: copy, verify, keep the old folder -------------------------------------------
    with IsolatedHome() as home:
        build(home, {"files": {".chilly/answers.jsonl": "A", ".chilly/jobs/x/report.md": "R"}, "links": {".chilly/ln": ".chilly/answers.jsonl"}})
        real_rename = os.rename

        def no_dir_rename(a, b, *x, **k):
            if str(a) == str(home / ".chilly"):
                raise OSError(18, "Invalid cross-device link")
            return real_rename(a, b, *x, **k)
        os.rename = no_dir_rename
        try:
            res = H.migrate(others=lambda h: [])
        finally:
            os.rename = real_rename
        check("when the rename is impossible the folder is copied, checked and renamed into place, kind copied",
              res.kind == "copied" and (home / ".benji/jobs/x/report.md").read_text() == "R"
              and (home / ".benji/ln").is_symlink() and H.read_marker(home / ".benji").get("kind") == "copied"
              and stat.S_IMODE((home / ".benji").stat().st_mode) == 0o700)
        check("the copy fallback never deletes or changes the old folder",
              (home / ".chilly/answers.jsonl").read_text() == "A" and (home / ".chilly/jobs/x/report.md").read_text() == "R"
              and not (home / ".benji.incoming").exists())
    with IsolatedHome() as home:
        build(home, {"files": {".chilly/answers.jsonl": "A"}})
        real_rename, real_tree = os.rename, H._tree
        os.rename = lambda a, b, *x, **k: (_ for _ in ()).throw(OSError(18, "x")) if str(a) == str(home / ".chilly") else real_rename(a, b, *x, **k)
        H._tree = lambda root: {"x": ("f", 1)} if root.name.endswith(".incoming") else real_tree(root)
        try:
            res = H.migrate(others=lambda h: [])
        finally:
            os.rename, H._tree = real_rename, real_tree
        check("a copy that does not match the original is thrown away: nothing in ~/.benji, the old folder kept, kind failed",
              res.kind == "failed" and not (home / ".benji").exists() and not (home / ".benji.incoming").exists()
              and (home / ".chilly/answers.jsonl").read_text() == "A")
        H.last = H.NONE
        os.rename = lambda a, b, *x, **k: (_ for _ in ()).throw(OSError(13, "x")) if str(a) == str(home / ".chilly") else real_rename(a, b, *x, **k)
        H._tree = lambda root: {"x": ("f", 1)} if root.name.endswith(".incoming") else real_tree(root)
        try:
            wd = config.workdir_path()
        finally:
            os.rename, H._tree = real_rename, real_tree
        check("when the move fails the process keeps using the old folder and creates no ~/.benji", wd == home / ".chilly" and not (home / ".benji").exists())

    # ---- the real engine, started the way the app starts it, in a temporary HOME ------------------------
    from benji import serve as S

    def start_engine(home: Path, extra: dict | None = None) -> dict:
        env = {"PATH": os.environ.get("PATH", ""), "HOME": str(home), "ANTHROPIC_API_KEY": "unused-no-call-made", **(extra or {})}
        proc = subprocess.Popen([sys.executable, "-m", "benji", "--serve"], cwd=here, env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            proc.stdin.write(json.dumps({"type": "hello", "protocol": S.PROTOCOL}) + "\n")
            proc.stdin.flush()
            ready = json.loads(proc.stdout.readline())
            proc.stdin.write(json.dumps({"type": "shutdown"}) + "\n")
            proc.stdin.flush()
            proc.wait(timeout=20)
        finally:
            if proc.poll() is None:
                proc.kill()
        ready["_stderr"] = proc.stderr.read()
        return ready

    with IsolatedHome() as home:
        build(home, {"files": {".chilly/answers.jsonl": "A", ".chilly/memory.jsonl": "M"}})
        first = start_engine(home)
        events = [json.loads(l) for l in (home / ".benji" / audit.FILE_NAME).read_text().splitlines()]
        check("the engine moves ~/.chilly to ~/.benji at its first start, says so once in `ready`, and nothing stays loose",
              first.get("type") == "ready" and first.get("home_notice") == H.notice_moved(".chilly")
              and (home / ".benji/answers.jsonl").read_text() == "A" and not (home / ".chilly").exists())
        check("... its stderr (so engine.log) carries the plain line, and the audit log one home_moved event by kind",
              H.notice_moved(".chilly") in first["_stderr"] and [e["how"] for e in events if e["kind"] == "home_moved"] == ["renamed"])
        second = start_engine(home)
        check("the second start moves nothing and has no notice", "home_notice" not in second and H.notice_moved(".chilly") not in second["_stderr"])
        (home / ".chilly").mkdir()
        (home / ".chilly" / "answers.jsonl").write_text("OLD")
        third = start_engine(home)
        fourth = start_engine(home)
        check("with an old ~/.chilly beside ~/.benji the engine uses ~/.benji, merges nothing, and says so once",
              third.get("home_notice") == H.notice_left_old(".chilly") and "home_notice" not in fourth
              and (home / ".benji/answers.jsonl").read_text() == "A" and (home / ".chilly/answers.jsonl").read_text() == "OLD")
    # ---- another Benji running with this home: the real process check, with throwaway processes --------
    import time as _time

    def fake_benji(home_value: str, tail: list[str]) -> subprocess.Popen:
        return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", *tail],
                                env={"PATH": os.environ.get("PATH", ""), "HOME": home_value}, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)

    with IsolatedHome() as home:
        build(home, {"files": {".chilly/answers.jsonl": "A"}})
        mine = fake_benji(str(home), ["-m", "benji", "--serve"])
        elsewhere = fake_benji(str(home.parent / "someone-else"), ["-m", "benji", "--serve"])
        unrelated = fake_benji(str(home), ["--serve"])
        try:
            _time.sleep(0.6)
            seen = H.other_processes(home)
            check("the process check finds a Benji engine running with this home, and not one with another home or an unrelated process",
                  mine.pid in seen and elsewhere.pid not in seen and unrelated.pid not in seen)
            res = H.migrate()
            check("with that engine running the real check refuses: kind busy, one plain line, nothing moved or made",
                  res.kind == "busy" and res.notice == H.notice_busy(".chilly") and "~/.chilly" in res.notice and "\n" not in res.notice
                  and (home / ".chilly/answers.jsonl").read_text() == "A" and not (home / ".benji").exists())
            H.last = H.NONE
            check("... and the process keeps using the old folder for this run", config.workdir_path() == home / ".chilly" and not (home / ".benji").exists())
            busy = start_engine(home)
            check("an engine started meanwhile says so in `ready` and in its log line, and moves nothing",
                  busy.get("home_notice") == H.notice_busy(".chilly") and H.notice_busy(".chilly") in busy["_stderr"] and not (home / ".benji").exists())
        finally:
            for pr in (mine, elsewhere, unrelated):
                pr.kill()
                pr.wait()
        _time.sleep(0.3)
        after = H.migrate()
        check("once it has stopped the move goes ahead", after.kind == "renamed" and (home / ".benji/answers.jsonl").read_text() == "A"
              and not (home / ".chilly").exists())

    with IsolatedHome("scratch") as home:
        build(home, {"files": {".chilly/answers.jsonl": "A"}})
        started = start_engine(home, {"BENJI_WORKDIR": os.environ["BENJI_WORKDIR"]})
        check("started with BENJI_WORKDIR (as the app starts it) the engine moves nothing and makes no ~/.benji",
              "home_notice" not in started and (home / ".chilly/answers.jsonl").exists() and not (home / ".benji").exists())

    # ---- workdir_path ---------------------------------------------------------------------------------
    with IsolatedHome() as home:
        wd = config.workdir_path()
        check("a fresh home: the default working folder is ~/.benji, made mode 700, no loose benji folder",
              wd == home / ".benji" and stat.S_IMODE(wd.stat().st_mode) == 0o700 and not (home / ".chilly").exists())
        check("--workdir wins and moves nothing", config.workdir_path(str(home / "x")) == home / "x" and not (home / "x").exists())
    with IsolatedHome("scratch") as home:
        build(home, {"files": {".chilly/answers.jsonl": "A"}})
        wd = config.workdir_path()
        check("BENJI_WORKDIR is the one override: used as given, ~/.chilly stays, ~/.benji is not made",
              wd == home.parent / "scratch" and (home / ".chilly/answers.jsonl").exists() and not (home / ".benji").exists())
    with IsolatedHome() as home:
        (home / ".benji").mkdir(mode=0o755)
        check("an existing ~/.benji keeps the mode its owner gave it", (config.workdir_path(), stat.S_IMODE((home / ".benji").stat().st_mode))[1] == 0o755)

    # ---- the gate: ~/.benji, as ~/.chilly was; the old ~/.chilly refused while it exists --------------------
    with IsolatedHome() as home:
        benji = home / ".benji"
        job = benji / "jobs" / "j1"
        build(home, {"files": {
            ".benji/answers.jsonl": "what I said", ".benji/policy.json": '{"disable": []}', ".benji/events.jsonl": "",
            ".benji/memory.jsonl": "m", ".benji/jobs/j1/report.md": "r", ".benji/jobs/j1/output/a.txt": "a",
            ".benji.env": "ANTHROPIC_API_KEY=x", ".ssh/id_rsa": "S",
            ".chilly/answers.jsonl": "OLD CANARY-old-5e2a", ".chilly/policy.json": "{}", ".chilly/jobs/j0/report.md": "old",
            "mycode/chilly/notes.txt": "n",
        }, "links": {".benji/jobs/j1/to_answers": ".benji/answers.jsonl", ".benji/jobs/j1/to_policy": ".benji/policy.json",
                     ".benji/jobs/j1/to_old": ".chilly/answers.jsonl", ".benji/jobs/j1/to_ssh": ".ssh/id_rsa"}})
        turn = T.Ctx(workdir=benji)
        turn.begin_turn("what did I ask yesterday")
        jobctx = T.Ctx(workdir=job, scope="job")
        jobctx.begin_turn("work in your folder")
        dec = lambda ctx, name, **inp: T.decide(ctx, name, inp)

        # a normal turn works in ~/.benji as it did in ~/.chilly
        check("a turn reads and lists inside ~/.benji freely, as it did inside ~/.chilly",
              dec(turn, "read_file", path=str(benji / "answers.jsonl")).cls == T.FREE
              and dec(turn, "list_dir", path=".").cls == T.FREE and dec(turn, "read_file", path="output/../memory.jsonl").cls == T.FREE)
        check("a turn overwriting policy.json or answers.jsonl is asked, a new file inside is not",
              dec(turn, "write_file", path=str(benji / "policy.json"), content="x").cls == T.ASKED
              and dec(turn, "write_file", path=str(benji / "answers.jsonl"), content="x").cls == T.ASKED
              and dec(turn, "write_file", path="output/new.txt", content="x").cls == T.FREE)
        check("a turn writing beside ~/.benji (the home folder, ~/.benji.env, ~/.ssh) is asked or refused, never free",
              dec(turn, "write_file", path=str(home / "loose.txt"), content="x").cls == T.ASKED
              and dec(turn, "write_file", path=str(home / ".benji.env"), content="x").cls == T.ASKED
              and dec(turn, "read_file", path=str(home / ".benji.env")).cls == T.DENIED
              and dec(turn, "read_file", path=str(home / ".ssh" / "id_rsa")).cls == T.DENIED)

        # a job is in its own folder: the rest of ~/.benji is outside it
        outside = [str(benji / "answers.jsonl"), str(benji / "policy.json"), "../../answers.jsonl", "../../policy.json",
                   "output/../../../answers.jsonl", str(job / ".." / ".." / "events.jsonl"), "../../memory.jsonl"]
        check("a job reading ~/.benji/answers.jsonl, policy.json, events.jsonl or memory.jsonl is asked, by name, by .. and by a path that climbs out",
              all(dec(jobctx, "read_file", path=p).cls == T.ASKED and dec(jobctx, "read_file", path=p).code == "read_outside_folder"
                  for p in outside))
        check("a job listing or searching ~/.benji or its parent folder is asked",
              all(dec(jobctx, n, path=p).cls == T.ASKED for n in ("list_dir", "search_files") for p in (str(benji), "..", "../..")))
        check("a symlink inside a job's folder to answers.jsonl or policy.json does not lead around the gate: asked",
              all(dec(jobctx, "read_file", path=p).cls == T.ASKED for p in ("to_answers", "to_policy"))
              and dec(jobctx, "write_file", path="to_policy", content="{}").cls == T.ASKED
              and dec(jobctx, "write_file", path="to_policy", content="{}").code == "write_outside_folder")
        check("a symlink inside a job's folder to a key or to the old folder is refused outright",
              dec(jobctx, "read_file", path="to_ssh").cls == T.DENIED and dec(jobctx, "read_file", path="to_old").cls == T.DENIED)
        check("a job writing outside its own folder is asked: ../, ../../policy.json, the home folder, ~/.benji",
              all(dec(jobctx, "write_file", path=p, content="x").cls == T.ASKED and dec(jobctx, "write_file", path=p, content="x").code == "write_outside_folder"
                  for p in ("../sibling.txt", "../../policy.json", str(home / "loose.txt"), str(benji / "new-policy.json"), "output/../../x")))
        check("a job writing inside its folder (output/, report.md) is not asked",
              dec(jobctx, "write_file", path="output/b.txt", content="x").cls == T.FREE
              and dec(jobctx, "write_file", path="notes.md", content="x").cls == T.FREE)
        shell = lambda ctx, c: T.decide(ctx, "run_shell", {"command": c})
        check("a job's shell reading ../../answers.jsonl or ~/.benji/policy.json is asked, and in its folder is not",
              shell(jobctx, "cat ../../answers.jsonl").cls == T.ASKED and shell(jobctx, f"cat {benji}/policy.json").cls == T.ASKED
              and shell(jobctx, "ls output").cls == T.FREE and shell(jobctx, "cat to_answers").cls == T.ASKED)
        check("the shell's environment has no BENJI_ variable: a tool cannot learn the override",
              "BENJI_WORKDIR" not in G.tool_env({"BENJI_WORKDIR": "/x", "PATH": "/bin"}) and "PATH" in G.tool_env({"BENJI_WORKDIR": "/x", "PATH": "/bin"}))

        # the old folder: refused outright, from a turn and a job, however it is named
        old_paths = [str(home / ".chilly" / "answers.jsonl"), "~/.chilly/policy.json", str(home / ".chilly"),
                     str(benji / ".." / ".chilly" / "answers.jsonl"), str(job / ".." / ".." / ".." / ".chilly" / "jobs" / "j0" / "report.md"),
                     str(home / ".CHILLY" / "answers.jsonl")]
        if not (home / ".CHILLY").exists():          # a case-sensitive volume has no ~/.CHILLY
            old_paths = old_paths[:-1]
        check("the old ~/.chilly, while it holds Benji's files, is refused outright (never asked) for a turn and for a job, whatever the spelling",
              all(dec(c, n, path=p).cls == T.DENIED and dec(c, n, path=p).code == "private_path"
                  for c in (turn, jobctx) for n in ("read_file", "list_dir", "search_files") for p in old_paths))
        out = T._read_file(turn, str(home / ".chilly" / "answers.jsonl"))
        check("the file tool refuses it with the reason and shows none of the content",
              out.startswith("[refused]") and "CANARY-old-5e2a" not in out and "~/.chilly" in out)
        check("the shell asks before reading it, naming a private path",
              shell(turn, f"cat {home}/.chilly/answers.jsonl").code == "shell_private_path"
              and shell(jobctx, "cat ~/.chilly/answers.jsonl").code == "shell_private_path")
        check("a browser upload of a file from ~/.chilly is refused, one from the job's output is not (the upload card still asks)",
              BA.vet_upload(str(home / ".chilly" / "answers.jsonl"), job, home)[0] is None
              and "private" in BA.vet_upload(str(home / ".chilly" / "answers.jsonl"), job, home)[1]
              and BA.vet_upload("output/a.txt", job, home)[0] is not None)
        check("G.private_path names the old folder and not ~/.benji", G.private_path(home / ".chilly" / "x.txt", home) == "~/.chilly"
              and G.private_path(benji / "answers.jsonl", home) is None and G.private_path(benji, home) is None)
        check("the key file and ~/.ssh stay private beside the new folder",
              G.private_path(home / ".benji.env", home) == "~/.benji.env" and G.private_path(home / ".ssh" / "x", home))
        check("~/.benji does not hide a key-shaped name inside it: id_rsa and a .pem are still private there",
              G.private_path(benji / "output" / "id_rsa", home) and G.private_path(benji / "output" / "a.pem", home))

        # the old folder is left alone when it IS the working folder, and when it is not Benji's at all
        legacy_turn = T.Ctx(workdir=home / ".chilly")
        legacy_turn.begin_turn("x")
        legacy_job = T.Ctx(workdir=home / ".chilly" / "jobs" / "j0", scope="job")
        legacy_job.begin_turn("x")
        check("BENJI_WORKDIR=~/.chilly still works: a turn there reads its own folder, a job there stays in its own",
              T.decide(legacy_turn, "read_file", {"path": "answers.jsonl"}).cls == T.FREE
              and T.decide(legacy_job, "read_file", {"path": "report.md"}).cls == T.FREE
              and T.decide(legacy_job, "read_file", {"path": "../../answers.jsonl"}).cls == T.ASKED
              and "CANARY-old-5e2a" in T._read_file(legacy_turn, "answers.jsonl"))
        check("a folder called chilly that holds none of Benji's files (a clone of the code, say) is not private",
              G.private_path(home / "mycode" / "chilly" / "notes.txt", home) is None)
        (home / "mycode" / "chilly" / "jobs").mkdir()
        check("... and ~/mycode/chilly is never the old folder, even with a jobs folder in it", G.private_path(home / "mycode" / "chilly" / "notes.txt", home) is None)
        shutil.rmtree(home / ".chilly")
        check("once ~/.chilly is gone it is just an ordinary path again",
              dec(turn, "read_file", path=str(home / ".chilly" / "answers.jsonl")).code == "read_outside_folder")

    # ---- the policy file lives in the new home --------------------------------------------------------
    with IsolatedHome() as home:
        wd = config.workdir_path()
        (wd / "policy.json").write_text('{"disable": ["web"]}')
        check("policy.json is read from ~/.benji", policy.load(wd).active and policy.load(config.workdir_path()).blocks("web_fetch"))

    # ---- the export tool's default (the tool is not part of the public export, so this runs only where it is) --
    tool = here / "tools" / ("make_public_" + "export.py")
    if tool.is_file():
        spec = importlib.util.spec_from_file_location("make_public_export", tool)
        exp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(exp)
        with IsolatedHome() as home:
            check("export default: ~/.benji/exports", exp._default_out_root() == home / ".benji" / "exports")
            (home / ".chilly").mkdir()
            (home / ".chilly" / "memory.jsonl").write_text("m")
            try:
                exp._check_default_home(home / ".benji")
                refused = False
            except SystemExit as e:
                refused = "still Benji's folder" in str(e)
            check("the export tool will not make ~/.benji while an old ~/.chilly is waiting to move", refused and not (home / ".benji").exists())
        with IsolatedHome("scratch") as home:
            check("export default follows BENJI_WORKDIR", exp._default_out_root() == home.parent / "scratch" / "exports")

    # ---- no code or text still points at a loose ~/.chilly -----------------------------------------------
    print("no leftover ~/.chilly in code (D-175):")
    allowed = {"benji/home.py", "benji/gate.py", "benji/config.py", "benji/aliases.py", "demo/profile.sh", "demo/seed.sh",
               "demo/check-isolation.sh", "companion/Sources/BenjiCore/HomeMigration.swift"}
    bad = []
    for sub, pats in (("benji", ("*.py",)), ("companion/Sources", ("*.swift",)), ("demo", ("*.sh",))):
        for pat in pats:
            for f in (here / sub).rglob(pat):
                rel = f.relative_to(here).as_posix()
                if rel in allowed:
                    continue
                text = f.read_text(errors="replace")
                for n, line in enumerate(text.splitlines(), 1):
                    if "~/.chilly" in line or "~/chilly" in line or "~/benji" in line.replace("~/.benji", "") or 'appendingPathComponent(".chilly")' in line \
                            or 'home() / ".chilly"' in line or '"$HOME/.chilly"' in line:
                        bad.append(f"{rel}:{n}")
    check("no source file builds or shows a ~/.chilly path (the move, the gate and the demo guards are the only ones that name it)", not bad)
    if bad:
        print("   ", bad[:12])
