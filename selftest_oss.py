"""Checks for the open-source release files and the demo kit. Called from selftest.py.

What is pinned here, and why:
  - the demo kit's scripts hold no personal name or path, never read file contents, and refuse what
    they should (check-isolation.sh run against a fake /Users, seed.sh with a different HOME);
  - the README's honesty labels, so a feature cannot quietly become "stable" in the status table;
  - the release and community files exist and say what they must (placeholders, not real contacts);
  - the CI workflow is well formed and starts no visible browser.
No network, no API, no real account: the isolation check only ever looks at a fake users folder in a
temporary directory, with a fake `sudo` first on its PATH. Those cases change modes on throwaway
folders; BENJI_TEST_NO_CHMOD=1 skips them for a run that must not change any file mode.
"""

from __future__ import annotations

import getpass
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

BASH = shutil.which("bash")
# Commands that read, list or copy file contents; none may appear as a command in the demo scripts.
READERS = ("cat", "head", "tail", "less", "more", "strings", "xxd", "od", "hexdump", "base64", "grep", "egrep", "fgrep",
           "awk", "sed", "cp", "mv", "rm", "tee", "touch", "ln", "dd", "open", "find", "xargs", "curl", "wget", "python3",
           "python", "osascript")


def _code_lines(text: str) -> list[str]:
    """Shell lines that are code: comments, blank lines and here-document bodies removed."""
    out = []
    end = None
    for line in text.splitlines():
        s = line.strip()
        if end is not None:
            if s == end:
                end = None
            continue
        if not s or s.startswith("#"):
            continue
        out.append(s)
        m = re.search(r"<<-?\s*['\"]?([A-Z_]+)['\"]?", s)
        if m:
            end = m.group(1)
    return out


def _commands_used(text: str, names: tuple[str, ...]) -> list[str]:
    """Which of `names` appear as a command (at the start of a line or after | ; & ( or $( ), ignoring text inside
    quotes that is only a message."""
    found = []
    for line in _code_lines(text):
        if line.startswith(("echo ", "printf ", "die ", "usage ")):
            continue
        for name in names:
            if re.search(r"(^|[|;&(]\s*|\$\(\s*)" + re.escape(name) + r"(\s|$)", line):
                found.append(f"{name}: {line}")
    return found


def _check_sign_identity(check, here: Path) -> None:
    """build.sh's choice of certificate, with a fake `security`: a new Mac gets the Benji name, and a Mac
    with only the older certificate keeps it, because another one would reset every permission."""
    text = (here / "companion" / "build.sh").read_text()
    start = text.index('SIGN_ID="${BENJI_SIGN_IDENTITY')
    block = text[start:text.index('if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then', start)]
    with tempfile.TemporaryDirectory() as td:
        fake = Path(td) / "security"
        fake.write_text('#!/bin/sh\ncase ",$HAVE," in *",$3,"*) exit 0;; esac\nexit 1\n')
        fake.chmod(0o755)

        def chosen(have: str, **extra: str) -> str:
            env = {"PATH": f"{td}:/usr/bin:/bin", "HAVE": have, **extra}
            return subprocess.run([BASH, "-c", block + 'printf %s "$SIGN_ID"'], env=env, capture_output=True,
                                  text=True, check=True).stdout

        old, new = "Chilly Local Signing", "Benji Local Signing"
        check("build.sh: a Mac with neither certificate looks for the Benji name", chosen("") == new)
        check("build.sh: a Mac with only the older certificate keeps it", chosen(old) == old)
        check("build.sh: with both, the Benji certificate is used", chosen(f"{old},{new}") == new)
        check("build.sh: BENJI_SIGN_IDENTITY still wins", chosen(old, BENJI_SIGN_IDENTITY="Mine") == "Mine")


def run(check, here: Path) -> None:
    demo = here / "demo"
    iso = (demo / "check-isolation.sh").read_text()
    seed = (demo / "seed.sh").read_text()

    # ---- the demo kit: static rules --------------------------------------------------------------------
    print("demo kit (static):")
    check("the demo kit has all five files",
          all((demo / n).is_file() for n in ("README.md", "check-isolation.sh", "hardening-checklist.md", "seed.sh", "RUNSHEET.md")))
    check("both scripts are executable and say bash", all(os.access(demo / n, os.X_OK) for n in ("check-isolation.sh", "seed.sh"))
          and iso.startswith("#!/bin/bash") and seed.startswith("#!/bin/bash"))
    everything = {n: (demo / n).read_text() for n in ("README.md", "check-isolation.sh", "hardening-checklist.md", "seed.sh", "RUNSHEET.md")}
    # No name is spelled out here: the check uses whoever runs the test, so the owner's name is caught
    # on the owner's Mac and a contributor's on theirs.
    me, home = getpass.getuser(), str(Path.home())
    named = [n for n, t in everything.items()
             if home in t or (len(me) >= 4 and re.search(r"(?<![A-Za-z0-9])" + re.escape(me) + r"(?![A-Za-z0-9])", t))]
    check("no demo file names the person running this test, or their home folder", not named)
    personal = []
    for n, t in everything.items():
        for m in re.finditer(r"/Users/([A-Za-z0-9._$<{-]*)", t):
            name = m.group(1)
            if name and name not in ("Shared", "Guest") and not name.startswith(("$", "<", "{")):
                personal.append(f"{n}: /Users/{name}")
    check("no demo file holds a /Users/<name> path (only $variables, <placeholders>, Shared and Guest)", not personal)
    if personal:
        print("   ", personal[:5])
    check("the scripts take the owner's name as an argument and read nothing about it from the machine",
          "OWNER=\"$1\"" in iso and "dscl" not in iso and "dscl" not in seed)
    bad = _commands_used(iso, READERS) + _commands_used(seed, tuple(c for c in READERS if c not in ("cat",)))
    bad += [f"cat: {l}" for l in _code_lines(seed) if re.match(r"cat\b", l) and not re.match(r'cat > "\$d/[^"]+" <<', l)]
    check("neither script runs a command that reads or copies file contents (no cat, head, grep, awk, find, cp, ...)", not bad)
    if bad:
        print("   ", bad[:5])
    check("check-isolation.sh uses only test -r, test -x, ls -ld and exit codes to look at the owner's things",
          "test -r" in iso and "test -x" in iso and "ls -ld" in iso)
    writes = [l for l in _code_lines(iso) if re.search(r"(^|[;&|]\s*)(mkdir|touch|tee|chmod|chown|mv|cp|rm)\b", l)]
    file_redirects = [l for l in _code_lines(iso) if not l.startswith(("echo", "usage")) and re.search(r"(?<![0-9&])>{1,2}\s*(?!/dev/null|&)[^\s]", l)]
    check("check-isolation.sh writes nothing: no redirect to a file, no mkdir, touch, chmod, rm", not writes and not file_redirects)
    if writes or file_redirects:
        print("   ", (writes + file_redirects)[:4])
    check("check-isolation.sh asks about the owner's home, .ssh, .aws, .config, keychains, browser profiles, other users, sudo and dslocal",
          all(s in iso for s in ('"$OH"', "/.ssh", "/.aws", "/.config", "Library/Keychains", "Application Support/Google/Chrome",
                                 "Application Support/Firefox", "Library/Safari", "sudo -n true", "dslocal")))
    check("check-isolation.sh prints PASS or FAIL per check, exits non-zero on FAIL, and tells you to stop the demo",
          "  PASS  " in iso and "  FAIL  " in iso and "exit 1" in iso and "STOP THE DEMO" in iso)
    check("check-isolation.sh labels things OWNER / OTHER-n instead of printing account names", "OWNER's" in iso and "OTHER-$i" in iso)
    check("seed.sh refuses root, an administrator, a HOME that is not the account's own, and an existing folder; it never deletes",
          all(s in seed for s in ("refusing to run as root", "an administrator", "is not this account's own home folder",
                                  "already exists", "never deletes")) and not re.search(r"(^|[;&|\s])rm\s", "\n".join(_code_lines(seed))))
    targets = re.findall(r'(?:mkdir|>)\s*("[^"]+")', "\n".join(_code_lines(seed)))
    check("every path seed.sh creates is under its target folder ($d or $out, set from $HOME/BenjiDemo)",
          targets and all(t.startswith(('"$d', '"$out')) for t in targets))
    check("seed.sh holds no key-shaped string, no real-looking email (only example.com) and no 'real' phone number",
          not re.search(r"sk-[A-Za-z0-9]{12}|AKIA[0-9A-Z]{12}|ghp_", seed)
          and all(a.endswith("@example.com") for a in re.findall(r"[\w.+-]+@[\w.-]+\.[a-z]+", seed))
          and all(re.fullmatch(r"555-01\d\d", p) for p in re.findall(r"\b555-\d{4}\b", seed)))

    # ---- check-isolation.sh against a fake /Users --------------------------------------------------------
    print("check-isolation.sh against a fake users folder:")
    if BASH is None or os.geteuid() == 0:
        print("  skip  needs bash and a non-root user")
    elif os.environ.get("BENJI_TEST_NO_CHMOD") == "1":
        # These cases set modes (000 / 755) on throwaway folders in the temp directory, and make a fake
        # `sudo` executable. A restricted run that must not change any file mode skips them.
        print("  skip  BENJI_TEST_NO_CHMOD=1: the cases that change file modes on temporary folders")
    else:
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            (t / "users" / "zzowner" / ".ssh").mkdir(parents=True)
            (t / "users" / "zzowner" / ".ssh" / "id_canary").write_text("CANARY-ISO-5d1f")
            (t / "users" / "zzother").mkdir()
            (t / "users" / "Shared").mkdir()
            (t / "home").mkdir()
            (t / "dsl").mkdir()
            (t / "bin").mkdir()
            sudo = t / "bin" / "sudo"
            sudo.write_text("#!/bin/sh\nexit 1\n")      # a fake `sudo` that refuses; the real one is never run
            sudo.chmod(0o755)
            env = dict(os.environ, PATH=f"{t / 'bin'}:{os.environ.get('PATH', '')}", HOME=str(t / "home"),
                       BENJI_DEMO_USERS_DIR=str(t / "users"), BENJI_DEMO_DSLOCAL=str(t / "dsl"))

            def go(*args: str) -> subprocess.CompletedProcess:
                return subprocess.run([BASH, str(demo / "check-isolation.sh"), *args], env=env, capture_output=True, text=True, timeout=60)

            def line(out: str, label: str) -> str:
                for l in out.splitlines():
                    if label in l:
                        return l.strip()
                return ""

            r = go()
            check("without an owner name it prints a usage line and exits 2", r.returncode == 2 and "usage" in r.stderr)
            for bad_name in ("../x", "a b", "-n", ""):
                check(f"a bad owner name ({bad_name!r}) is refused with exit 2", go(bad_name).returncode == 2)
            r = go("zzmissing")
            check("a name with no home folder fails loudly (a typo must not look like a pass)",
                  r.returncode == 1 and "STOP THE DEMO" in r.stdout and "PASS  the owner's" not in r.stdout)

            for d in ("zzowner", "zzother"):
                (t / "users" / d).chmod(0o755)
            r = go("zzowner")
            out = r.stdout
            check("open folders (755): the owner's home, .ssh and another user's home each FAIL, and the run exits 1",
                  r.returncode == 1 and line(out, "OWNER's home folder").startswith("FAIL")
                  and line(out, "OWNER's .ssh").startswith("FAIL") and line(out, "another user's home folder (OTHER-1)").startswith("FAIL")
                  and "STOP THE DEMO" in out)
            for d in ("zzowner", "zzother"):
                (t / "users" / d).chmod(0o000)
            r = go("zzowner")
            out = r.stdout
            try:
                check("closed folders (000): the owner's home, .ssh, .aws, .config, keychains, Chrome profile and another user's home all PASS",
                      all(line(out, lab).startswith("PASS") for lab in ("OWNER's home folder", "OWNER's .ssh", "OWNER's .aws", "OWNER's .config",
                                                                        "OWNER's keychain folder", "OWNER's Chrome profile folder",
                                                                        "another user's home folder (OTHER-1)")))
                check("with the fake refusing sudo and an unreadable dslocal those two PASS too", line(out, "sudo -n true").startswith("PASS")
                      and line(out, "dslocal").startswith("PASS"))
                check("the output never prints the owner's or another account's name, or the canary file's content",
                      "zzowner" not in out + r.stderr and "zzother" not in out + r.stderr and "CANARY-ISO" not in out + r.stderr)
                check("a Shared folder is not treated as another user's home", "Shared" not in out)
            finally:
                for d in ("zzowner", "zzother"):
                    (t / "users" / d).chmod(0o755)
            # sudo that works must FAIL
            sudo.write_text("#!/bin/sh\nexit 0\n")
            for d in ("zzowner", "zzother"):
                (t / "users" / d).chmod(0o000)
            r = go("zzowner")
            for d in ("zzowner", "zzother"):
                (t / "users" / d).chmod(0o755)
            check("a sudo that works without a password FAILs and stops the demo", line(r.stdout, "sudo").startswith("FAIL") and r.returncode == 1)
            r = subprocess.run([BASH, str(demo / "check-isolation.sh"), os.environ.get("USER") or "x"],
                               env=dict(env, HOME=str(t / "home")), capture_output=True, text=True, timeout=60)
            check("run as the owner's own account it refuses and checks nothing", r.returncode == 1 and "owner account" in r.stdout
                  and "RESULT: FAIL" in r.stdout)

    # ---- profile.sh (recording in your own account) ---------------------------------------------------------
    print("profile.sh:")
    if BASH is None:
        print("  skip  needs bash")
    else:
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            (t / "bin").mkdir()
            shim = t / "bin" / "pgrep"
            shim.write_text("#!/bin/sh\nexit 1\n")
            shim.chmod(0o755)
            opened = t / "opened.txt"
            (t / "bin" / "open").write_text(f'#!/bin/sh\nprintf \'%s\\n\' "$@" > "{opened}"\n')
            (t / "bin" / "open").chmod(0o755)
            home = t / "home"
            for d in (".benji/conversations", ".benji/jobs", ".benji/voices", ".benji/voice-venv"):
                (home / d).mkdir(parents=True)
            (home / ".benji/memory.jsonl").write_text("mine")
            (home / ".benji/.hidden").write_text("x")
            before = sorted(p.relative_to(home).as_posix() for p in home.rglob("*"))
            env_p = dict(os.environ, HOME=str(home), PATH=f"{t / 'bin'}:{os.environ.get('PATH', '')}")
            env_p.pop("BENJI_WORKDIR", None)
            run_p = lambda *a: subprocess.run([BASH, str(demo / "profile.sh"), *a], env=env_p, capture_output=True, text=True, timeout=60)
            r = run_p("start")
            runs = sorted((home / ".benji/demo").glob("run-*")) if (home / ".benji/demo").is_dir() else []
            check("start makes one empty scratch folder under ~/.benji/demo and leaves every real file where it was",
                  r.returncode == 0 and len(runs) == 1 and (home / ".benji/memory.jsonl").read_text() == "mine"
                  and sorted(p.relative_to(home).as_posix() for p in home.rglob("*") if "demo" not in p.parts) == before
                  and sorted(p.name for p in runs[0].iterdir()) == ["voice-venv", "voices"]
                  and all((runs[0] / n).is_symlink() for n in ("voice-venv", "voices")))
            check("start opens Benji with BENJI_WORKDIR set to that folder, through open --env",
                  runs and opened.is_file() and f"BENJI_WORKDIR={runs[0]}" in opened.read_text() and "--env" in opened.read_text())
            check("the scratch folder is private (mode 700)", runs and (runs[0].stat().st_mode & 0o777) == 0o700)
            src = (demo / "profile.sh").read_text()
            check("profile.sh no longer moves, copies or deletes anything of the real folder (no mv, cp, rm, rmdir)",
                  not re.search(r"(^|[;&|\s])(mv|cp|rm|rmdir)\s", "\n".join(_code_lines(src))))
            r = run_p("finish")
            check("finish only says where the demo folder is and that the real files were not touched",
                  r.returncode == 0 and "never touched" in r.stdout and (home / ".benji/memory.jsonl").read_text() == "mine")
            r = run_p("aside")
            check("the old verbs are gone: aside is refused", r.returncode != 0 and "usage" in r.stderr)
            shutil.rmtree(home / ".benji")
            (home / "benji").mkdir()
            r = run_p("start")
            check("with an old ~/benji and no ~/.benji it refuses and creates nothing (the folder must move first)",
                  r.returncode != 0 and "still Benji's folder" in r.stderr and not (home / ".benji").exists())
            shim.write_text("#!/bin/sh\nexit 0\n")
            r = run_p("start")
            check("it refuses while Benji is running", r.returncode != 0 and "quit Benji" in r.stderr)
    check("seed.sh --same-account drops only the administrator check",
          "--same-account) same_account=1" in (demo / "seed.sh").read_text()
          and '[ "$same_account" = 1 ] && return 0' in (demo / "seed.sh").read_text())

    # ---- seed.sh -------------------------------------------------------------------------------------------
    print("seed.sh:")
    if BASH is None:
        print("  skip  needs bash")
    else:
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            fake_home = t / "elsewhere"
            fake_home.mkdir()
            r = subprocess.run([BASH, str(demo / "seed.sh")], env=dict(os.environ, HOME=str(fake_home)), capture_output=True, text=True, timeout=60)
            check("with a HOME that is not the account's own home it refuses, exits non-zero and creates nothing",
                  r.returncode != 0 and "refusing" in r.stderr and list(fake_home.iterdir()) == [])
            r = subprocess.run([BASH, str(demo / "seed.sh")], env={k: v for k, v in os.environ.items() if k != "HOME"},
                               capture_output=True, text=True, timeout=60)
            check("with no HOME it refuses", r.returncode != 0)
            r = subprocess.run([BASH, str(demo / "seed.sh"), "--in-benji-home"], env=dict(os.environ, HOME=str(fake_home)),
                               capture_output=True, text=True, timeout=60)
            check("--in-benji-home with a HOME that is not the account's own refuses and creates nothing (no ~/.benji either)",
                  r.returncode != 0 and "refusing" in r.stderr and list(fake_home.iterdir()) == [])
            r = subprocess.run([BASH, str(demo / "seed.sh"), "--bogus"], env=dict(os.environ, HOME=str(fake_home)),
                               capture_output=True, text=True, timeout=60)
            check("an unknown option is refused and names the two real ones",
                  r.returncode != 0 and "--in-benji-home" in r.stderr and "--same-account" in r.stderr)
            seed_src = (demo / "seed.sh").read_text()
            check("--in-benji-home targets ${BENJI_WORKDIR:-$HOME/.benji}/demo/BenjiDemo and refuses to make ~/.benji while an older folder waits to move",
                  'benji_home="${BENJI_WORKDIR:-${CHILLY_WORKDIR:-${PAL_WORKDIR:-$HOME/.benji}}}"' in seed_src and 'target="$benji_home/demo/$SEED_NAME"' in seed_src
                  and "still Benji's folder" in seed_src)
            check("the visible ~/BenjiDemo stays the default (the run sheet asks about it in the home folder)",
                  'target="$HOME/$SEED_NAME"' in seed_src)
            for odd in ("/", "/tmp", "/private/tmp", "/var/root", "/Users/Shared", "/Users/Guest"):
                r = subprocess.run([BASH, str(demo / "seed.sh")], env=dict(os.environ, HOME=odd), capture_output=True, text=True, timeout=60)
                check(f"HOME={odd} is refused", r.returncode != 0 and "refusing" in r.stderr)
            out = t / "BenjiDemo"
            r = subprocess.run([BASH, "-c", f'source "{demo / "seed.sh"}"; write_files "{out}"'], capture_output=True, text=True, timeout=60)
            files = sorted(p.relative_to(out).as_posix() for p in out.rglob("*") if p.is_file()) if out.is_dir() else []
            check("write_files makes the project folder, notes, CSVs, PDFs and a marker in the folder it is given, and nowhere else",
                  r.returncode == 0 and {"budget.csv", "sales-q3.csv", "notes/todo.txt", "bakery-site/index.html", ".benji-demo-seed"} <= set(files)
                  and sum(f.endswith(".pdf") for f in files) == 3 and sorted(p.name for p in t.iterdir()) == ["BenjiDemo", "elsewhere"])
            if out.is_dir():
                rows = (out / "budget.csv").read_text().splitlines()
                check("the budget CSV is a table: a header and 18 rows of four fields",
                      rows[0] == "month,category,planned,actual" and len(rows) == 19 and all(len(x.split(",")) == 4 for x in rows))
                sales = (out / "sales-q3.csv").read_text().splitlines()
                check("the sales CSV has 3 items x 14 days and the totals multiply out",
                      len(sales) == 1 + 42 and all(abs(int(s.split(",")[2]) * float(s.split(",")[3]) - float(s.split(",")[4])) < 0.01 for s in sales[1:]))
                ok_pdf = True
                for pdf in (out / "receipts").glob("*.pdf"):
                    b = pdf.read_bytes()
                    m = re.search(rb"startxref\n(\d+)", b)
                    offs = [int(x) for x in re.findall(rb"(\d{10}) 00000 n", b)]
                    ok_pdf &= bool(m) and b[int(m.group(1)):].startswith(b"xref") and b.startswith(b"%PDF-1.4") \
                        and all(b[o:].startswith(b"%d 0 obj" % i) for i, o in enumerate(offs, 1)) and len(offs) == 5
                check("the three PDFs are well-formed (header, object offsets and the xref table agree)", ok_pdf)
                blob = "\n".join(p.read_text(errors="replace") for p in out.rglob("*") if p.is_file() and p.suffix != ".pdf") + "".join(
                    p.read_bytes().decode("latin-1") for p in (out / "receipts").glob("*.pdf"))
                check("the seeded files are invented: no key, no /Users path, only example.com addresses, 555-01xx numbers",
                      not re.search(r"sk-[A-Za-z0-9]{10}|/Users/|AKIA", blob)
                      and all(a.endswith("@example.com") for a in re.findall(r"[\w.+-]+@[\w.-]+\.[a-z]+", blob))
                      and all(re.fullmatch(r"555-01\d\d", p) for p in re.findall(r"\b555-\d{4}\b", blob)) and "made up" in blob.lower())

    # ---- the README, release and community files -------------------------------------------------------------
    print("release and community files:")
    readme = (here / "README.md").read_text()
    check("the README holds no decision ids", not re.search(r"\bD-\d+\b", readme))
    rows = {m.group(1).strip(): m.group(2).strip() for m in re.finditer(r"^\| ([^|]+) \| (Stable|Experimental|Not live-tested|Not available / untested) \|", readme, re.M)}

    def label(sub: str) -> str:
        for k, v in rows.items():
            if sub.lower() in k.lower():
                return v
        return ""
    check("the status table labels jobs and logging 'Experimental'", label("Background jobs") == "Experimental"
          and label("audit log") == "Experimental")
    check("the status table labels the browser and every provider but Claude 'Not live-tested'",
          label("Browser reach") == "Not live-tested" and label("OpenAI provider") == "Not live-tested"
          and label("DeepSeek, GLM, Kimi") == "Not live-tested" and label("Ollama and LM Studio") == "Not live-tested")
    check("the status table never marks jobs, browser or the new providers 'Stable'",
          not any(v == "Stable" and re.search(r"job|browser|deepseek|glm|kimi|qwen|ollama|openai|audit", k, re.I) for k, v in rows.items()))
    check("the README says how to build from source: xcrun swift, build.sh, the local certificate, ad-hoc resets, Gatekeeper, RELEASING",
          all(s in readme for s in ("xcrun swift", "./build.sh", "Benji Local Signing", "ad hoc", "Gatekeeper", "docs/RELEASING.md", "no notarised download")))
    check("the README never sends a new user to the old certificate name or an upgrade they can't have",
          "Chilly" not in readme and "~/.chilly" not in readme)
    _check_sign_identity(check, here)
    check("the README explains the safety model, jobs, browser reach, and what each provider sees",
          all(s in readme for s in ("## Safety model", "## Background jobs", "## Browser reach", "What the provider sees", "benji --diagnose")))
    releasing = (here / "docs" / "RELEASING.md").read_text()
    risky = [l for l in releasing.splitlines() if re.search(r"^(codesign|xcrun notarytool|xcrun stapler|git tag|git push|ditto|security find|spctl)", l.strip())]
    check("every signing, notarising, tagging and pushing command in RELEASING.md is marked as the owner's",
          risky and all("(owner)" in l or l.rstrip().endswith("\\") for l in risky))
    check("RELEASING.md covers versioning, tagging, build, Developer ID signing, notarisation, stapling and release notes",
          all(s in releasing for s in ("Versioning", "Tag", "Developer ID", "notarytool", "stapler", "Release notes format", "0.1.0")))
    coc = (here / "CODE_OF_CONDUCT.md").read_text()
    check("CODE_OF_CONDUCT.md credits the Contributor Covenant 2.1 with its URL and names a real contact (D-202)",
          "contributor-covenant.org/version/2/1/code_of_conduct" in coc and "CC BY 4.0" in coc and "OWNER-" "TODO" not in coc
          and re.search(r"[\w.+-]+@[\w-]+\.[a-z]{2,}", coc))
    bug = (here / ".github" / "ISSUE_TEMPLATE" / "bug_report.yml").read_text()
    check("the bug report asks for benji --diagnose and warns against keys and personal text",
          "benji --diagnose" in bug and re.search(r"Do not paste API keys", bug) and "personal text" in bug)
    check("the feature request, issue chooser and PR template exist",
          (here / ".github" / "ISSUE_TEMPLATE" / "feature_request.yml").is_file() and (here / ".github" / "ISSUE_TEMPLATE" / "config.yml").is_file()
          and "no message text" in (here / ".github" / "pull_request_template.md").read_text().lower())
    cl = (here / "CHANGELOG.md").read_text()
    check("CHANGELOG.md is Keep a Changelog: an Unreleased section and a 0.1.0 entry that names what is not live-tested",
          "keepachangelog.com" in cl and "## [Unreleased]" in cl and "## [0.1.0]" in cl and "Not live-tested" in cl.replace("not live-tested", "Not live-tested"))
    rm = (here / "docs" / "ROADMAP.md").read_text()
    check("ROADMAP.md says it is intentions, lists browser step 2 per-action classing, live verification and notarised builds, and says Windows is not planned",
          "intentions, not promises" in rm and "per-action classing" in rm and "Live verification" in rm and "Notarised builds" in rm and "Windows" in rm and "Not planned" in rm)
    sec = (here / "SECURITY.md").read_text()
    check("the private contacts are filled in (D-202): no placeholder, a real address in both files",
          "OWNER-" "TODO" not in sec + coc and re.search(r"[\w.+-]+@(?!example\.)[\w-]+\.[a-z]{2,}", sec) and re.search(r"[\w.+-]+@(?!example\.)[\w-]+\.[a-z]{2,}", coc))

    # ---- CI ---------------------------------------------------------------------------------------------------
    print("CI workflow:")
    ci_path = here / ".github" / "workflows" / "ci.yml"
    ci = ci_path.read_text()
    check("ci.yml has no tab characters and uses read-only permissions", "\t" not in ci and "contents: read" in ci)
    check("ci.yml runs the engine selftest, the extension's node tests, the Swift tests with xcrun, ServeCheck and the export check",
          all(s in ci for s in ("python3 selftest.py", "node --test browser-extension/test/core.test.mjs", "page-text.test.mjs",
                                "xcrun swift test", "companion/ServeCheck/run.py", "make_public_")))
    check("ci.yml starts no visible browser (no headed mode, no headless: false, no xvfb, no browser launched by hand)",
          not re.search(r"--headed|headless:\s*false|xvfb|google-chrome\s+--|chromium\s+--|playwright|puppeteer|cypress|selenium", ci, re.I))
    check("ci.yml makes failures easy to read: it greps FAIL lines into annotations and a summary, and uploads the logs",
          "::error" in ci and "GITHUB_STEP_SUMMARY" in ci and "upload-artifact" in ci)
    ruby = shutil.which("ruby")
    if ruby:
        paths = [ci_path, *(here / ".github" / "ISSUE_TEMPLATE").glob("*.yml")]
        res = subprocess.run([ruby, "-ryaml", "-e", "ARGV.each{|f| YAML.load_file(f)}; puts 'ok'", *map(str, paths)],
                             capture_output=True, text=True, timeout=60)
        check("the workflow and the issue forms parse as YAML (ruby's Psych)", res.stdout.strip() == "ok")
        res = subprocess.run([ruby, "-ryaml", "-e",
                              "d=YAML.load_file(ARGV[0]); j=d['jobs']; bad=j.flat_map{|k,v| v['steps'].reject{|s| s['run']||s['uses']}.map{k}}; "
                              "puts((bad.empty? && j.keys.sort==%w[browser-extension hygiene selftest swift-tests]) ? 'ok' : bad.inspect+j.keys.inspect)",
                              str(ci_path)], capture_output=True, text=True, timeout=60)
        check("every workflow step runs something or uses an action, and the four jobs are there", res.stdout.strip() == "ok")
    else:
        print("  skip  no ruby to parse the YAML (the workflow has never run on GitHub either way)")
