"""Checks Benji's folder, ~/.benji: the working folder and its override, what the approval gate
allows inside it (and the older data folder it still refuses while one exists), the policy file, and
the export tool's default. Called from selftest.py.

Every case runs against a temporary HOME (or a temporary BENJI_WORKDIR): nothing here looks at, lists,
reads or changes anything in the real home folder.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import stat
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

    def __init__(self, workdir: str | None = None):
        self.workdir = workdir

    def __enter__(self) -> Path:
        self.td = tempfile.TemporaryDirectory()
        self.saved = {k: os.environ.get(k) for k in ("HOME", "BENJI_WORKDIR")}
        self.home = Path(self.td.name).resolve() / "home"
        self.home.mkdir()
        os.environ["HOME"] = str(self.home)
        os.environ.pop("BENJI_WORKDIR", None)
        if self.workdir:
            os.environ["BENJI_WORKDIR"] = str(self.home.parent / self.workdir)
        return self.home

    def __exit__(self, *exc) -> None:
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.td.cleanup()


def run(check, here: Path) -> None:
    from benji import config
    from benji import browser_act as BA
    from benji import gate as G
    from benji import tools as T
    from benji import policy

    print("Benji's folder, ~/.benji:")
    # ---- workdir_path ---------------------------------------------------------------------------------
    with IsolatedHome() as home:
        wd = config.workdir_path()
        check("a fresh home: the default working folder is ~/.benji, made mode 700, no loose benji folder",
              wd == home / ".benji" and stat.S_IMODE(wd.stat().st_mode) == 0o700)
        check("--workdir wins, used as given", config.workdir_path(str(home / "x")) == home / "x" and not (home / "x").exists())
    with IsolatedHome("scratch") as home:
        wd = config.workdir_path()
        check("BENJI_WORKDIR is the one override: used as given, ~/.benji is not made",
              wd == home.parent / "scratch" and not (home / ".benji").exists())
    with IsolatedHome() as home:
        (home / ".benji").mkdir(mode=0o755)
        check("an existing ~/.benji keeps the mode its owner gave it", (config.workdir_path(), stat.S_IMODE((home / ".benji").stat().st_mode))[1] == 0o755)

    # ---- the gate: ~/.benji, and an older ~/.chilly data folder refused while it exists -------------------
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

    # ---- the policy file lives in ~/.benji --------------------------------------------------------
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
        with IsolatedHome("scratch") as home:
            check("export default follows BENJI_WORKDIR", exp._default_out_root() == home.parent / "scratch" / "exports")
