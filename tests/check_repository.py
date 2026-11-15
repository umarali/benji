"""Checks the repository itself: the README and its reference pages, the release and community files,
and the CI workflow. Called from selftest.py.

What is pinned here, and why:
  - the README's honesty labels, so a feature cannot quietly become "stable" in the status table;
  - the release and community files exist and say what they must;
  - the CI workflow is well formed and starts no visible browser.
No network, no API.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

BASH = shutil.which("bash")


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

    # ---- the README, release and community files -------------------------------------------------------------
    print("release and community files:")
    readme = (here / "README.md").read_text()
    # The README is the short front page; the reference text it links to lives in these pages.
    pages = {n: (here / "docs" / f"{n}.md").read_text() for n in ("status", "safety", "privacy", "configuration", "building")}
    front = readme + "".join(pages.values())
    check("the README and its reference pages hold no decision ids", not re.search(r"\bD-\d+\b", front))
    check("the README links each reference page", all(f"docs/{n}.md" in readme for n in pages))
    rows = {m.group(1).strip(): m.group(2).strip() for m in re.finditer(r"^\| ([^|]+) \| (Stable|Experimental|Not live-tested|Not available / untested) \|", pages["status"], re.M)}

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
    check("the build page says how to build from source: xcrun swift, build.sh, the local certificate, ad-hoc resets, Gatekeeper, RELEASING",
          all(s in pages["building"] for s in ("xcrun swift", "./build.sh", "Benji Local Signing", "ad hoc", "Gatekeeper", "RELEASING.md", "no notarised download")))
    check("the README and its pages never send a new user to the old certificate name or an upgrade they can't have",
          "Chilly" not in front and "~/.chilly" not in front)
    _check_sign_identity(check, here)
    check("the reference pages explain the safety model, jobs, browser reach, and what each provider sees",
          all(s in pages["safety"] for s in ("## Safety model", "## Background jobs", "## Browser reach", "benji --diagnose"))
          and "What the provider sees" in pages["privacy"])
    releasing = (here / "docs" / "RELEASING.md").read_text()
    risky = [l for l in releasing.splitlines() if re.search(r"^(codesign|xcrun notarytool|xcrun stapler|git tag|git push|ditto|security find|spctl)", l.strip())]
    check("every signing, notarising, tagging and pushing command in RELEASING.md is marked as the owner's",
          risky and all("(owner)" in l or l.rstrip().endswith("\\") for l in risky))
    check("RELEASING.md covers versioning, tagging, build, Developer ID signing, notarisation, stapling and release notes",
          all(s in releasing for s in ("Versioning", "Tag", "Developer ID", "notarytool", "stapler", "Release notes format", "0.1.0")))
    coc = (here / ".github" / "CODE_OF_CONDUCT.md").read_text()
    check("CODE_OF_CONDUCT.md credits the Contributor Covenant 2.1 with its URL and names a real contact",
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
    check("ROADMAP.md says it is intentions, lists per-action classing in the browser, live verification and notarised builds, and says Windows is not planned",
          "intentions, not promises" in rm and "per-action classing" in rm and "Live verification" in rm and "Notarised builds" in rm and "Windows" in rm and "Not planned" in rm)
    sec = (here / ".github" / "SECURITY.md").read_text()
    check("the private contacts are filled in: no placeholder, a real address in both files",
          "OWNER-" "TODO" not in sec + coc and re.search(r"[\w.+-]+@(?!example\.)[\w-]+\.[a-z]{2,}", sec) and re.search(r"[\w.+-]+@(?!example\.)[\w-]+\.[a-z]{2,}", coc))

    # ---- CI ---------------------------------------------------------------------------------------------------
    print("CI workflow:")
    ci_path = here / ".github" / "workflows" / "ci.yml"
    ci = ci_path.read_text()
    check("ci.yml has no tab characters and uses read-only permissions", "\t" not in ci and "contents: read" in ci)
    check("ci.yml runs the engine selftest, the extension's node tests, the Swift tests with xcrun, ServeCheck and the export check",
          all(s in ci for s in ("python3 tests/selftest.py", "node --test browser-extension/test/core.test.mjs", "page-text.test.mjs",
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
