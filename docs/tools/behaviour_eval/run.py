#!/usr/bin/env python3
"""Live behaviour eval: does Benji draw, keep quiet about its tags, and answer spoken turns
briefly, with the real model?

It sends test requests through the real engine (`benji --serve`, the panel surface, the same
`send` the app writes: image, allow_pointing, spoken, screen geometry) and scores the answers.
Only synthetic screenshots (screens.swift draws them) and test text are sent. Nothing on this
Mac is captured, and the working folder is a temp one, so no memory reaches the model. Every
tool is switched off inside the engine for the eval, and any approval is answered No.

    python3 -I docs/tools/behaviour_eval/run.py --plan          # cases, call count; no API call
    python3 -I docs/tools/behaviour_eval/run.py --fake          # whole pipeline, localhost fake model
    python3 -I docs/tools/behaviour_eval/run.py --live --runs 3 # the real model (asks nothing: ask first)

The key stays in ~/.benji.env and is read by the engine only; this script never reads it.
Results (answers, marks, verdicts) go to --out as results.json and results.md.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path.insert(0, str(ROOT))

from benji import pointing  # noqa: E402

TAG_WORDS = re.compile(r"\[|\b(POINT|BOX|CIRCLE|ARROW|UNDERLINE|HIGHLIGHT|PATH|NOTE)\b|\btags?\b|coordinat|\bpixels?\b")
CANT_HEAR = re.compile(r"(can't|cannot|can not|unable to|not able to|don't have the ability to|no way to)\s+"
                       r"(hear|listen|process (audio|sound|voice))|only (work with|respond in|handle|read) text"
                       r"|responding in text|audio input", re.I)
FILLER = re.compile(r"I can see (that )?you|you'd like me to|^(Sure|Certainly|Of course|Absolutely)\b|I'd be happy"
                    r"|Let me know|Great question|Here's what I|I'll (go ahead and )?|\bfor you\b", re.I | re.M)
NOT_WORDS = re.compile(r"[\u2190-\u2BFF\U0001F000-\U0001FAFF]")   # arrows, symbols, emoji: read aloud badly
# What starts the engine for the eval: every tool answers that it is off, so nothing runs.
LAUNCHER = """
import sys
sys.path.insert(0, sys.argv[1])
import benji.tools as tools
tools.dispatch = lambda ctx, name, inp: "[eval] Tools are switched off for this evaluation; answer without them."
from benji.__main__ import main
sys.exit(main(["--serve"]))
"""


@dataclass
class Case:
    name: str
    screen: str          # which synthetic screenshot
    text: str
    spoken: bool
    check: str           # which scorer below
    draws: bool = True   # a request to draw: asking back counts as a failure


CASES = [
    Case("circle the notch", "desktop", "Circle around the notch.", True, "notch"),
    Case("circle the Save button", "desktop", "circle the Save button", False, "save"),
    Case("arrow name -> Save", "form", "draw an arrow from the name field to Save", False, "arrow"),
    Case("underline line 2", "document", "underline the second line", False, "underline"),
    Case("highlight the error", "form", "Highlight the error.", True, "error"),
    Case("smiley in empty area", "desktop", "draw a smiley in the empty area", False, "smiley"),
    Case("spoken: can you hear me", "desktop", "Hey, can you hear me?", True, "hear", draws=False),
    Case("spoken: 2+2", "desktop", "What's 2+2?", True, "math", draws=False),
    Case("typed: circle something", "single", "circle something", False, "something"),
]


# ---- scoring -------------------------------------------------------------------------------

def rect_of(t: pointing.Target) -> tuple[int, int, int, int]:
    xs, ys = t.coords[0::2], t.coords[1::2]
    return min(xs), min(ys), max(xs), max(ys)


def grow(b, d):
    return b[0] - d, b[1] - d, b[2] + d, b[3] + d


def inside(x, y, b):
    return b[0] <= x <= b[2] and b[1] <= y <= b[3]


def centre(b):
    return (b[0] + b[2]) / 2, (b[1] + b[3]) / 2


def area(b):
    return max(0, b[2] - b[0]) * max(0, b[3] - b[1])


def sentences(text: str) -> int:
    parts = [p for p in re.split(r"(?<=[.!?])\s+", text.strip()) if re.search(r"\w", p)]
    return len(parts)


def covered(r, box):
    """How much of `box` the rect `r` covers, 0 to 1."""
    i = (max(r[0], box[0]), max(r[1], box[1]), min(r[2], box[2]), min(r[3], box[3]))
    return area(i) / max(area(box), 1)


def loop_around(targets, box, kinds=("circle",), most=10.0):
    """A loop (or box) that covers most of the target and isn't far bigger than it."""
    for t in targets:
        if t.kind in kinds:
            r = rect_of(t)
            if covered(r, box) >= 0.7 and area(r) <= most * max(area(box), 1):
                return True
    return False


def score(case: Case, answer: str, targets: list[pointing.Target], tools: list[str], truth: dict) -> list[str]:
    """The reasons this answer fails; empty when it passes."""
    why = []
    size = truth["size"]
    pts = truth["display_points"]
    t = truth[case.screen]["targets"]
    screen = truth["screen"]

    for tg in targets:
        if pointing.mark_for(tg, tuple(size), tuple(pts)) is None:
            why.append(f"undrawable mark {tg.kind} {list(tg.coords)}")
    if TAG_WORDS.search(answer):
        why.append(f"tag or coordinate words: {TAG_WORDS.search(answer).group(0)!r}")
    if CANT_HEAR.search(answer):
        why.append("says it can't hear")
    if not re.search(r"\w", answer) or NOT_WORDS.search(answer):
        why.append("symbols or emoji instead of words")
    if FILLER.search(answer):
        why.append(f"filler: {FILLER.search(answer).group(0)!r}")
    if tools:
        why.append(f"used tools: {tools}")
    n = sentences(answer)
    if case.spoken and n > 3:
        why.append(f"{n} sentences spoken")
    if not case.spoken and n > 4:
        why.append(f"{n} sentences typed")
    if case.draws and "?" in answer:
        why.append("asked a question")
    if case.draws and not targets:
        why.append("no marks")

    kinds = [tg.kind for tg in targets]
    if case.check == "notch":
        n = screen["notch"]
        ok = False
        for tg in targets:
            if tg.kind in ("circle", "box", "highlight"):
                r = rect_of(tg)
                overlap = min(r[2], n[2]) - max(r[0], n[0])
                ok |= (overlap >= 0.8 * (n[2] - n[0]) and r[1] <= n[1] + 10 and n[3] - 5 <= r[3] <= n[3] + 70
                       and (r[2] - r[0]) <= 2.5 * (n[2] - n[0]))
            elif tg.kind in ("arrow", "point"):
                tip = tg.coords[-2:]
                ok |= inside(*tip, grow(n, 20))
        if not ok:
            why.append(f"no mark on the notch {n}: {kinds}")
    elif case.check == "save":
        if not loop_around(targets, t["save"]) or any(
                tg.kind == "circle" and inside(*centre(t["cancel"]), rect_of(tg)) for tg in targets):
            why.append(f"no loop on Save {t['save']}: {[list(x.coords) for x in targets]}")
    elif case.check == "arrow":
        arrows = [tg for tg in targets if tg.kind == "arrow"]
        if not any(inside(a.coords[0], a.coords[1], grow(t["name"], 40))
                   and inside(a.coords[2], a.coords[3], grow(t["save"], 30)) for a in arrows):
            why.append(f"no arrow from name {t['name']} to Save {t['save']}: {[list(a.coords) for a in arrows]}")
    elif case.check == "underline":
        line, below = t["lines"][1], t["lines"][2]
        ok = False
        for tg in targets:
            if tg.kind == "underline":
                x1, y1, x2, y2 = tg.coords
                y = (y1 + y2) / 2
                cover = min(max(x1, x2), line[2]) - max(min(x1, x2), line[0])
                ok |= (line[1] + 0.6 * (line[3] - line[1]) <= y <= below[1] + 6
                       and cover >= 0.7 * (line[2] - line[0]))
        if not ok:
            why.append(f"no underline under line 2 {line}: {[(x.kind, list(x.coords)) for x in targets]}")
    elif case.check == "error":
        zone = grow((t["email"][0], t["email"][1], t["email"][2], t["error"][3]), 12)
        if not any(tg.kind in ("highlight", "box", "circle", "underline") and inside(*centre(rect_of(tg)), zone)
                   and rect_of(tg)[3] - rect_of(tg)[1] <= 90 for tg in targets):
            why.append(f"no highlight on the error {t['error']}: {[(x.kind, list(x.coords)) for x in targets]}")
    elif case.check == "smiley":
        if len(targets) < 3 or "circle" not in kinds or not ({"path", "arc"} & set(kinds)):
            why.append(f"not a face: {kinds}")
        # Every mark in one empty area: the wallpaper on the right, or the editor's blank page.
        points = [p for tg in targets for p in zip(tg.coords[0::2], tg.coords[1::2])]
        if not any(all(inside(*p, grow(t[zone], 10)) for p in points) for zone in ("empty", "empty_page")):
            why.append(f"not inside one empty area {t['empty']} / {t['empty_page']}: "
                       f"{[(x.kind, list(x.coords)) for x in targets]}")
    elif case.check == "hear":
        if targets:
            why.append(f"drew unasked: {kinds}")
    elif case.check == "math":
        if targets:
            why.append(f"drew unasked: {kinds}")
        if not re.search(r"\b(4|four)\b", answer, re.I):
            why.append("no 4")
    elif case.check == "something":
        if not loop_around(targets, t["continue"], kinds=("circle", "box", "highlight")):
            why.append(f"no loop on Continue {t['continue']}: {[(x.kind, list(x.coords)) for x in targets]}")
    return why


# ---- running -------------------------------------------------------------------------------

def make_screens(out: Path) -> dict:
    src = out / "src"
    src.mkdir(parents=True, exist_ok=True)
    shutil.copy(HERE / "screens.swift", src / "main.swift")
    shutil.copy(ROOT / "companion/Sources/BenjiCore/Screen/ScreenshotGeometry.swift", src)
    exe = out / "screens"
    subprocess.run(["xcrun", "swiftc", "-o", str(exe), *map(str, sorted(src.glob("*.swift")))], check=True,
                   stderr=subprocess.DEVNULL)
    subprocess.run([str(exe), str(out)], check=True, stdout=subprocess.DEVNULL)
    return json.loads((out / "truth.json").read_text())


class Engine:
    """One `benji --serve` with the panel surface; events read on a thread."""

    def __init__(self, env: dict, workdir: Path):
        env = {**env, "BENJI_SURFACE": "panel", "BENJI_WORKDIR": str(workdir), "PYTHONUNBUFFERED": "1"}
        self.proc = subprocess.Popen([sys.executable, "-I", "-c", LAUNCHER, str(ROOT)], cwd=workdir, env=env,
                                     text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)
        self.events: list[dict] = []
        self.cv = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        self.write({"type": "hello", "protocol": 1})
        self.ready = self.wait(lambda e: e.get("type") in ("ready", "error"), 30)

    def _read(self):
        for line in iter(self.proc.stdout.readline, ""):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") == "approval":      # never approve anything
                self.write({"type": "approve", "id": e["id"], "request": e["request"], "decision": "no"})
            with self.cv:
                self.events.append(e)
                self.cv.notify_all()

    def write(self, obj: dict):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def wait(self, pred, timeout: float):
        end = time.time() + timeout
        with self.cv:
            while True:
                for e in self.events:
                    if pred(e):
                        return e
                left = end - time.time()
                if left <= 0:
                    return None
                self.cv.wait(left)

    def turn(self, turn_id: str, req: dict, timeout: float = 120) -> list[dict]:
        self.write({"type": "reset"})
        self.write({"type": "send", "id": turn_id, **req})
        done = self.wait(lambda e: e.get("type") == "done" and e.get("id") == turn_id, timeout)
        if done is None:
            self.write({"type": "cancel", "id": turn_id})
        with self.cv:
            return [e for e in self.events if e.get("id") == turn_id]

    def close(self):
        try:
            self.write({"type": "shutdown"})
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:  # noqa: BLE001
            self.proc.kill()


def fake_server():
    """A localhost OpenAI-compatible model that answers each case well, to check the pipeline."""
    canned = {
        "Circle around the notch.": "Circled the notch. [CIRCLE:563,0,767,44:notch]",
        "circle the Save button": "That's the blue Save button. [CIRCLE:596,264,700,314:Save button]",
        "draw an arrow from the name field to Save": "From the name field to Save. [ARROW:900,241,840,478:Save]",
        "underline the second line": "Underlined the second line. [UNDERLINE:160,186,769,186:second line]",
        "Highlight the error.": "The email address is invalid. [HIGHLIGHT:416,346,632,366:error]",
        "draw a smiley in the empty area": ("Here's a smiley. [CIRCLE:1000,300,1200,500:smiley] "
                                            "[CIRCLE:1050,360,1070,380:eye] [CIRCLE:1130,360,1150,380:eye] "
                                            "[PATH:1050,430,1100,460,1150,430:smile]"),
        "Hey, can you hear me?": "Yes, I can hear you. What can I do?",
        "What's 2+2?": "Four.",
        "circle something": "Circled the Continue button. [CIRCLE:585,548,745,608:Continue]",
    }

    class Fake(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            last = body["messages"][-1]["content"]
            text = last if isinstance(last, str) else " ".join(p.get("text", "") for p in last if p.get("type") == "text")
            out = json.dumps({"choices": [{"message": {"content": canned.get(text.strip(), "?")}}],
                              "usage": {"prompt_tokens": 10, "completion_tokens": 5}}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    httpd = HTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true", help="list the cases and the number of calls; no API call")
    mode.add_argument("--fake", action="store_true", help="run against a localhost fake model")
    mode.add_argument("--live", action="store_true", help="run against the real model in ~/.benji.env")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--only", help="run only cases whose name contains this")
    ap.add_argument("--out", default=None, help="where to write screens and results (default: a temp folder)")
    args = ap.parse_args()

    cases = [c for c in CASES if not args.only or args.only.lower() in c.name.lower()]
    if args.plan:
        for c in cases:
            print(f"  {c.name:28} {c.screen:9} {'spoken' if c.spoken else 'typed ':6} {c.text!r}")
        print(f"{len(cases)} cases x {args.runs} runs = {len(cases) * args.runs} model calls (more if it uses a tool)")
        return 0

    out = Path(args.out or tempfile.mkdtemp(prefix="benji-eval-"))
    out.mkdir(parents=True, exist_ok=True)
    truth = make_screens(out)
    workdir = Path(tempfile.mkdtemp(prefix="benji-eval-wd-"))

    env = {k: v for k, v in os.environ.items() if not k.startswith("BENJI_")}
    httpd = None
    if args.fake:
        httpd = fake_server()
        env = {k: v for k, v in env.items() if "API_KEY" not in k}
        env.update(BENJI_BASE_URL=f"http://127.0.0.1:{httpd.server_port}/v1", BENJI_MODEL="fake",
                   BENJI_PROVIDER="openai", OPENAI_API_KEY="unused-fake-server", HOME=str(workdir),
                   NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
    engine = Engine(env, workdir)
    if not engine.ready or engine.ready.get("type") != "ready":
        print("engine didn't start:", engine.ready)
        return 2
    print(f"engine: {engine.ready.get('provider')} {engine.ready.get('model')} -> {engine.ready.get('destination')}")

    results = []
    tokens = {"input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0, "calls": 0}
    try:
        for run in range(args.runs):
            for i, c in enumerate(cases):
                req = {"text": c.text, "image": str(out / truth[c.screen]["file"]), "allow_pointing": True,
                       "screen": truth["screen"]}
                if c.spoken:
                    req["spoken"] = True
                t0 = time.time()
                events = engine.turn(f"r{run}c{i}", req)
                answer = next((e for e in events if e["type"] == "answer"), None)
                for e in events:
                    if e["type"] == "usage":
                        for k in tokens:
                            tokens[k] += e.get(k, 0)
                tools = [e["name"] for e in events if e["type"] == "tool"]
                errors = [e["text"] for e in events if e["type"] == "error"]
                text = answer["text"] if answer else ""
                targets = [pointing.Target(t["kind"], tuple(t["coords"]), t["label"])
                           for t in (answer or {}).get("targets", [])]
                why = errors or score(c, text, targets, tools, truth) if answer else (errors or ["no answer"])
                results.append({"case": c.name, "run": run + 1, "spoken": c.spoken, "text": text,
                                "targets": (answer or {}).get("targets", []), "tools": tools,
                                "pass": not why, "why": why, "seconds": round(time.time() - t0, 1)})
                mark = "PASS" if not why else "FAIL"
                print(f"{mark} [{run + 1}] {c.name}: {text!r} {[(t.kind, list(t.coords)) for t in targets]}"
                      + ("" if not why else f"\n       why: {'; '.join(why)}"), flush=True)
    finally:
        engine.close()
        if httpd:
            httpd.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)

    rows = ["| case | pass | runs | failures |", "|---|---|---|---|"]
    for c in cases:
        mine = [r for r in results if r["case"] == c.name]
        ok = sum(r["pass"] for r in mine)
        fails = "; ".join(f"run {r['run']}: {', '.join(r['why'])}" for r in mine if not r["pass"])
        rows.append(f"| {c.name} | {ok}/{len(mine)} | {len(mine)} | {fails or '-'} |")
    passed = sum(r["pass"] for r in results)
    rows.append(f"| **all** | **{passed}/{len(results)}** ({100 * passed // max(len(results), 1)}%) | | |")
    table = "\n".join(rows)
    print("\n" + table)
    print(f"\ntokens: {tokens}")
    (out / "results.json").write_text(json.dumps({"results": results, "tokens": tokens,
                                                  "model": engine.ready.get("model")}, indent=2))
    (out / "results.md").write_text(table + f"\n\ntokens: {tokens}\n")
    print(f"results in {out}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
