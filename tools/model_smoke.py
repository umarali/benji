#!/usr/bin/env python3
"""A five-minute live check of one model provider, for the person who has its key.

    python3 tools/model_smoke.py deepseek        # or glm, kimi, qwen, ollama, lmstudio, claude, openai

It starts the real engine (`python3 -m benji --serve`, the way the app does, with streaming on) in a
throwaway working folder and runs four small steps, each timed:

  1. a typed question                 "What is 7 times 6? Answer with just the number."   expect 42
  2. one tool call                    "List the files in your working folder..."          expect a list_dir step
  3. a background job                 "In the background, write output/smoke.txt..."      expect a finished job and the file
  4. a screenshot question            a generated solid-red picture, "what colour?"      expect "red"; skipped
                                      when the model can't read images (that is a result too)

It reads your key the way Benji does (the environment, then ~/.benji.env) and never prints it. It
prints the provider, host and model first, so you can see where the steps go; each step then prints
PASS or FAIL and a few words of what happened. Anything the engine asks to do that the steps don't
expect is answered No. At the end it prints `benji --diagnose` for the last hour (no message text).

Send back: the whole output of this script. It holds no key and no message text beyond the one-word
answers above. Nothing is sent anywhere by the script itself except to the provider you chose.

Options: --region cn|intl (GLM, Kimi, Qwen), --model ID, --thinking off|on|default, --keep (keep the folder).
Steps 1-3 cost a few cents or less on any hosted provider; step 4 sends one tiny picture.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def red_png(path: Path, size: int = 64) -> None:
    """A solid red square: a picture a model can only describe correctly if it can see it."""
    row = b"\x00" + b"\xe0\x10\x10" * size
    raw = zlib.compress(row * size)

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


class Engine:
    def __init__(self, workdir: Path, env: dict):
        self.proc = subprocess.Popen([sys.executable, "-m", "benji", "--serve", "--workdir", str(workdir)],
                                     cwd=HERE, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        self.events: "queue.Queue[dict]" = queue.Queue()
        self.log: list[dict] = []
        self.stderr: list[str] = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._err, daemon=True).start()

    def _read(self) -> None:
        for line in self.proc.stdout:
            try:
                self.events.put(json.loads(line))
            except ValueError:
                pass
        self.events.put({"type": "_eof"})

    def _err(self) -> None:
        for line in self.proc.stderr:
            self.stderr.append(line.rstrip())

    def send(self, **req) -> None:
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()

    def until(self, pred, timeout: float, on_approval=None):
        """Events until one satisfies `pred` (returned), the engine ends or the time runs out (None)."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                e = self.events.get(timeout=0.5)
            except queue.Empty:
                continue
            self.log.append(e)
            if e.get("type") == "approval" and on_approval:
                on_approval(e)
            if e.get("type") == "job" and e["job"].get("pending") and on_approval:
                on_approval({"id": e["job"]["id"], "request": e["job"]["pending"]["request"],
                             "action": e["job"]["pending"]["action"]})
            if e.get("type") == "_eof":
                return None
            if pred(e):
                return e
        return None

    def stop(self) -> None:
        try:
            self.send(type="shutdown")
            self.proc.wait(timeout=5)
        except Exception:      # noqa: BLE001
            self.proc.kill()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("provider", help="deepseek, glm, kimi, qwen, ollama, lmstudio, claude or openai")
    ap.add_argument("--model")
    ap.add_argument("--region")
    ap.add_argument("--thinking")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    env = dict(os.environ, BENJI_PROVIDER=args.provider, BENJI_STREAM="1", PYTHONPATH=str(HERE))
    for key, var in ((args.model, "BENJI_MODEL"), (args.region, "BENJI_REGION"), (args.thinking, "BENJI_THINKING")):
        if key:
            env[var] = key
    work = Path(tempfile.mkdtemp(prefix="benji-smoke-"))
    results: list[tuple[str, bool, str]] = []
    eng = Engine(work, env)
    try:
        eng.send(type="hello", protocol=1)
        ready = eng.until(lambda e: e.get("type") in ("ready", "error"), 30)
        if not ready or ready["type"] != "ready":
            why = ready.get("text") if ready else "\n".join(eng.stderr[-5:])
            print(f"The engine did not start: {why}")
            return 2
        host = ready.get("host") or "?"
        print(f"provider={ready['provider']}  model={ready['model']}  data goes to: {ready['destination']} ({host})  "
              f"reads images={ready.get('vision', True)}")
        print(f"engine line: {next((l for l in eng.stderr if 'sends to=' in l), '?')[:200]}")

        def unexpected(e):
            print(f"   (an unexpected approval card, answered No: {str(e.get('action'))[:80]})")
            eng.send(type="approve", id=e["id"], request=e["request"], decision="no")

        def turn(tid: str, text: str, **extra):
            t0 = time.time()
            eng.send(type="send", id=tid, text=text, **extra)
            end = eng.until(lambda e: e.get("type") == "done" and e.get("id") == tid, 150, unexpected)
            took = time.time() - t0
            mine = [e for e in eng.log if e.get("id") == tid]
            answer = next((e["text"] for e in mine if e.get("type") == "answer"), "")
            error = next((e["text"] for e in mine if e.get("type") == "error"), "")
            return end, answer, error, took, mine

        def record(name: str, ok: bool, note: str) -> None:
            results.append((name, ok, note))
            print(f"{'PASS' if ok else 'FAIL'}  {name}: {note}")

        end, answer, error, took, mine = turn("q1", "What is 7 times 6? Answer with just the number.")
        record("1 typed question", "42" in answer, f"{took:.1f}s, answer {answer[:60]!r}" + (f", error: {error[:200]}" if error else ""))

        end, answer, error, took, mine = turn("q2", "List the files in your working folder and tell me how many there are.")
        tools = [e["name"] for e in mine if e.get("type") == "tool"]
        record("2 one tool call", "list_dir" in tools and bool(answer),
               f"{took:.1f}s, tools {tools}, answer {answer[:60]!r}" + (f", error: {error[:200]}" if error else ""))

        t0 = time.time()
        eng.send(type="send", id="q3", text="In the background, write a file output/smoke.txt that says hello, then tell me it is done.",
                 jobs=True)
        fin = eng.until(lambda e: e.get("type") == "job" and e["job"]["state"] in ("done", "failed", "stopped"), 180, unexpected)
        wrote = list((work / "jobs").glob("*/output/smoke.txt")) if (work / "jobs").exists() else []
        states = [e["job"]["state"] for e in eng.log if e.get("type") == "job"]
        record("3 background job", bool(fin) and fin["job"]["state"] == "done" and bool(wrote),
               f"{time.time() - t0:.1f}s, states {list(dict.fromkeys(states))}, file {'made' if wrote else 'missing'}"
               + (f", error: {(fin['job'].get('error') or '')[:200]}" if fin and fin["job"]["state"] == "failed" else ""))

        if ready.get("vision", True):
            pic = work / "red.png"
            red_png(pic)
            end, answer, error, took, mine = turn("q4", "What colour is this picture? One word.", image=str(pic))
            record("4 screenshot question", "red" in answer.lower(),
                   f"{took:.1f}s, answer {answer[:60]!r}" + (f", error: {error[:200]}" if error else ""))
        else:
            print("SKIP  4 screenshot question: this model is not taken to read images (Benji keeps Screen off for it). "
                  "Try BENJI_VISION=1 only if its docs say it can.")
    finally:
        eng.stop()

    diag = subprocess.run([sys.executable, "-m", "benji", "--diagnose", "--hours", "1", "--workdir", str(work)],
                          cwd=HERE, env=env, capture_output=True, text=True)
    print("\n--- benji --diagnose (this run; no message text) ---")
    print(diag.stdout.strip() or diag.stderr.strip())
    usage = work / "usage.jsonl"
    if usage.exists():
        lines = [json.loads(l) for l in usage.read_text().splitlines() if l.strip()]
        print(f"\nusage.jsonl: {len(lines)} model calls; input {sum(l['input_tokens'] for l in lines)}, "
              f"output {sum(l['output_tokens'] for l in lines)}, cache read {sum(l['cache_read_tokens'] for l in lines)}")
    if args.keep:
        print(f"\nfolder kept: {work}")
    else:
        shutil.rmtree(work, ignore_errors=True)
    failed = [n for n, ok, _ in results if not ok]
    print("\nALL PASSED" if not failed else f"\nFAILED: {', '.join(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
