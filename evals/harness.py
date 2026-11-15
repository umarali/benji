"""The eval harness's commands. Run them through tools/eval.py (see evals/README.md).

Nothing here calls a paid API unless a command is given --live, and every --live run is started by
hand, never by a script or the selftest. `check`, `compare`, `list`, `agree` and `label` never touch the network; `record
--fake` and the selftest use a localhost model.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from . import checks, rubrics
from . import fixtures as F

REPO = F.ROOT.parent
BEHAVIOUR = REPO / "docs/tools/behaviour_eval/run.py"

# Dollars per million tokens (Anthropic's reference, 2026-10-06; Haiku's rate is for prompts up to
# 100K tokens). Cache reads are billed at 0.1x and cache writes at 1.25x the input rate. An estimate.
PRICES = {"claude-haiku-5-5": (0.10, 0.50), "claude-sonnet-5-5": (2.0, 10.0), "claude-opus-5-5": (4.0, 20.0)}

# The engine's switches when it is asked again: as the app runs it (figures, cards and streaming on).
APP_ENV = {"BENJI_FIGURES": "1", "BENJI_CARDS": "1", "BENJI_STREAM": "1"}
PASS_THROUGH = ("BENJI_MODEL", "BENJI_EFFORT", "BENJI_FIGURE_GUIDE")


def cost(model: str, usage: dict) -> float | None:
    rate = PRICES.get(model)
    if rate is None or not usage:
        return None
    i, o = rate
    return (usage.get("input_tokens", 0) * i + usage.get("output_tokens", 0) * o
            + usage.get("cache_read_tokens", 0) * i * 0.1 + usage.get("cache_write_tokens", 0) * i * 1.25) / 1e6


def _load(folder: str | None, private: bool) -> list[dict]:
    return F.load_dir(Path(folder) if folder else F.FIXTURES, private=private)


def _pick(args, fxs: list[dict]) -> list[dict]:
    return F.select(fxs, kind=args.kind, model=args.model, only=args.only)


def _table(rows: list[list[str]]) -> str:
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip() for r in rows)


# --- list -------------------------------------------------------------------------------------

def cmd_list(args) -> int:
    fxs = _pick(args, _load(args.dir, args.private))
    groups: dict[tuple, list[dict]] = {}
    for f in fxs:
        groups.setdefault((f["kind"], f["reply"]["model"], f["reply"].get("effort", "")), []).append(f)
    rows = [["kind", "model", "effort", "fixtures", "baseline pass", "human-labelled"]]
    for (kind, model, effort), group in sorted(groups.items()):
        rows.append([kind, model, effort or "-", str(len(group)),
                     str(sum(bool((g.get("baseline") or {}).get("pass")) for g in group)),
                     str(sum(g.get("human") is not None for g in group))])
    print(_table(rows))
    print(f"{len(fxs)} fixtures")
    return 0


# --- check: replay the recorded replies through the code checks -------------------------------

def run_checks(fxs: list[dict]) -> list[dict]:
    out = []
    for f in fxs:
        v = checks.check(f)
        base = f.get("baseline")
        drift = base is not None and (base["pass"] != v.passed or sorted(base["why"]) != sorted(v.why))
        out.append({"id": f["id"], "kind": f["kind"], "model": f["reply"]["model"], "pass": v.passed,
                    "why": v.why, "notes": v.notes, "metrics": v.metrics, "drift": drift,
                    "baseline": base, "usage": f["reply"].get("usage") or {}})
    return out


def summary(results: list[dict]) -> str:
    groups: dict[tuple, list[dict]] = {}
    for r in results:
        groups.setdefault((r["kind"], r["model"]), []).append(r)
    rows = [["kind", "model", "pass", "rate", "est. $ per passing turn"]]
    for (kind, model), group in sorted(groups.items()):
        passed = sum(r["pass"] for r in group)
        costs = [cost(model, r["usage"]) for r in group]
        per = (f"{sum(costs) / passed:.4f}" if passed and all(c is not None for c in costs) else "-")
        rows.append([kind, model, f"{passed}/{len(group)}", f"{passed / len(group):.0%}", per])
    out = _table(rows)
    for (kind, model), group in sorted(groups.items()):       # a metric, not part of the pass rate
        if kind == "figure":
            n = sum(bool(r["metrics"].get("narration")) for r in group)
            out += f"\nfigure words about the model, {model}: {n}/{len(group)}"
    return out


def cmd_check(args) -> int:
    fxs = _pick(args, _load(args.dir, args.private))
    if not fxs:
        print("no fixtures match")
        return 2
    results = run_checks(fxs)
    for r in results:
        if r["pass"] and not r["drift"] and not args.verbose:
            continue
        mark = "PASS" if r["pass"] else "FAIL"
        print(f"{mark}{' DRIFT' if r['drift'] else ''} {r['id']} ({r['model']})"
              + "".join(f"\n       why: {w}" for w in r["why"])
              + "".join(f"\n       note: {n}" for n in r["notes"])
              + (f"\n       baseline: {r['baseline']}" if r["drift"] else ""))
    print(summary(results))
    drifted = [r["id"] for r in results if r["drift"]]
    failed = [r["id"] for r in results if not r["pass"]]
    print(f"{len(results) - len(failed)}/{len(results)} pass; {len(drifted)} drifted from their baseline")
    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
    return 1 if drifted or (args.strict and failed) else 0


def cmd_rebaseline(args) -> int:
    """Store today's verdicts as the baseline, after a deliberate change to a check or a parser."""
    fxs = _pick(args, _load(args.dir, args.private))
    changed = 0
    for f, r in zip(fxs, run_checks(fxs)):
        if r["drift"] or f.get("baseline") is None:
            f["baseline"] = {"pass": r["pass"], "why": r["why"]}
            F.save(f, Path(f["_path"]))
            changed += 1
            print(f"baseline {'set' if r['baseline'] is None else 'changed'}: {f['id']} -> "
                  f"{'pass' if r['pass'] else 'fail: ' + '; '.join(r['why'])}")
    print(f"{changed} baseline(s) written")
    return 0


# --- compare two sets (a baseline and a new run) -------------------------------------------

def cmd_compare(args) -> int:
    def by_question(folder: str, model: str | None) -> dict:
        out: dict = {}
        for f in F.select(F.load_dir(Path(folder), private=True), kind=args.kind, model=model, only=args.only):
            key = f"{f['kind']}/{F.slug(f['case'])}"
            if key in out:
                raise F.FixtureError(f"{folder} answers {key} more than once (models "
                                     f"{out[key]['reply']['model']}, {f['reply']['model']}): pick one with --a-model or --b-model")
            out[key] = {**f, "id": key}
        return out

    a, b = by_question(args.a, args.a_model), by_question(args.b, args.b_model)
    shared = sorted(set(a) & set(b))
    if not shared:
        print("the two sets share no questions")
        return 2
    ra = {r["id"]: r for r in run_checks([a[i] for i in shared])}
    rb = {r["id"]: r for r in run_checks([b[i] for i in shared])}
    rows = [["fixture", Path(args.a).name, Path(args.b).name, "why (second set)"]]
    for i in shared:
        x, y = ra[i], rb[i]
        if x["pass"] != y["pass"] or args.verbose:
            rows.append([i, "pass" if x["pass"] else "FAIL", "pass" if y["pass"] else "FAIL", "; ".join(y["why"])])
    if len(rows) > 1:
        print(_table(rows))
    print(f"\n{Path(args.a).name}:\n{summary(list(ra.values()))}\n\n{Path(args.b).name}:\n{summary(list(rb.values()))}")
    better = sum(not ra[i]["pass"] and rb[i]["pass"] for i in shared)
    worse = sum(ra[i]["pass"] and not rb[i]["pass"] for i in shared)
    print(f"\n{len(shared)} shared: {better} fixed, {worse} broken")
    only = sorted(set(a) ^ set(b))
    if only:
        print(f"{len(only)} in one set only: {', '.join(only[:8])}{' ...' if len(only) > 8 else ''}")
    return 0


# --- record: ask the fixtures' questions again, through the real engine -----------------------

def _behaviour():
    if not BEHAVIOUR.exists():
        raise F.FixtureError(f"record needs the engine driver in {BEHAVIOUR.relative_to(REPO)}, which this copy lacks")
    spec = importlib.util.spec_from_file_location("benji_behaviour_eval", BEHAVIOUR)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod                            # dataclasses look their module up here
    spec.loader.exec_module(mod)
    return mod


def beats_raw(events: list[dict]) -> str:
    """The reply as the model wrote it, rebuilt from a beats turn's events: the spoken words with each
    card line put back on its own line at the place (`at`) the engine saw it."""
    answer = next((e for e in events if e.get("type") == "answer"), {})
    words = answer.get("text", "")
    lines = []
    for e in events:
        t = e.get("type")
        if t == "card":
            lines.append((e.get("at", 0), "card: " + json.dumps(e["card"], ensure_ascii=False)))
        elif t == "card_item":
            lines.append((e.get("at", 0), "item: " + json.dumps(e["item"], ensure_ascii=False)))
        elif t == "card_takeaway":
            lines.append((e.get("at", len(words)), "takeaway: " + e.get("text", "")))
        elif t == "card_chips":
            lines.append((e.get("at", len(words)), "chips: " + json.dumps(e.get("chips", []), ensure_ascii=False)))
    out, said = [], 0
    for at, line in sorted(lines, key=lambda x: x[0]):
        at = min(max(at, said), len(words))
        chunk = words[said:at]
        out.append(chunk if not chunk or chunk.endswith("\n") else chunk + "\n")
        out.append(line + "\n")
        said = at
    out.append(words[said:])
    tags = "".join(f"[{t['kind'].upper()}:{','.join(map(str, t['coords']))}:{t['label']}]"
                   for t in answer.get("targets", []))      # the engine sends trailing tags as targets
    return "".join(out).rstrip("\n") + (" " + tags if tags else "")


class FakeModel:
    """A localhost OpenAI-format model. The harness sets `reply` before each turn: the fixture's own
    recorded reply, so `record --fake` should give the baseline verdicts back (a pipeline check)."""

    def __init__(self):
        self.reply = ""
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers["content-length"]))
                out = json.dumps({"choices": [{"message": {"content": fake.reply}}],
                                  "usage": {"prompt_tokens": 10, "completion_tokens": 5}}).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

        self.httpd = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    @staticmethod
    def recorded(f: dict) -> str:
        return beats_raw(f["reply"]["events"]) if f["kind"] == "beats" else f["reply"]["raw"]


def cmd_record(args) -> int:
    fxs, seen = [], set()
    for f in _pick(args, _load(args.dir, args.private)):
        key = (f["kind"], f["case"], f["request"]["text"])
        if not f["request"].get("real_screen") and key not in seen:      # each question once
            seen.add(key)
            fxs.append(f)
    if not fxs:
        print("no fixtures match (fixtures from a real screen can't be asked again: the screen isn't kept)")
        return 2
    if args.plan:
        for f in fxs:
            r = f["request"]
            print(f"  {f['kind'] + '/' + F.slug(f['case']):32} {'spoken' if r.get('spoken') else 'typed':6} "
                  f"{r.get('screen') or 'no screen':10} {r['text']!r}")
        print(f"{len(fxs)} fixtures x {args.runs} run(s) = {len(fxs) * args.runs} model calls")
        return 0
    if not args.live and not args.fake:
        print("say --plan, --fake (a localhost model) or --live (the real model: the user's call)")
        return 2
    beh = _behaviour()
    stamp = time.strftime("%Y%m%d-%H%M")
    workdir = Path(tempfile.mkdtemp(prefix="benji-eval-wd-"))
    shots = Path(tempfile.mkdtemp(prefix="benji-eval-screens-"))
    env = {k: v for k, v in os.environ.items() if not k.startswith("BENJI_") or k in PASS_THROUGH}
    env.update(APP_ENV)
    if args.use_model:
        env["BENJI_MODEL"] = args.use_model
    if args.effort:
        env["BENJI_EFFORT"] = args.effort
    fake = None
    if args.fake:
        fake = FakeModel()
        env = {k: v for k, v in env.items() if "API_KEY" not in k}
        env.update(BENJI_BASE_URL=f"http://127.0.0.1:{fake.httpd.server_port}/v1", BENJI_MODEL="fake",
                   BENJI_PROVIDER="openai", OPENAI_API_KEY="unused-fake-server", HOME=str(workdir),
                   BENJI_STREAM="0", NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
    truth = beh.make_screens(shots) if any(f["request"].get("screen") for f in fxs) else None
    engine = beh.Engine(env, workdir)
    if not engine.ready or engine.ready.get("type") != "ready":
        print("engine didn't start:", engine.ready)
        return 2
    model, effort = engine.ready.get("model"), engine.ready.get("effort")
    out = Path(args.out) if args.out else F.RUNS / f"{stamp}-{F.slug(str(model))}-{effort or 'default'}"
    print(f"engine: {engine.ready.get('provider')} {model} effort {effort}; writing to {out}")
    written = 0
    try:
        for run in range(args.runs):
            for n, f in enumerate(fxs):
                r = f["request"]
                req = {"text": r["text"]}
                if r.get("screen"):
                    req.update(image=str(shots / truth[r["screen"]]["file"]), allow_pointing=True, screen=truth["screen"])
                if r.get("spoken"):
                    req["spoken"] = True
                if fake:
                    fake.reply = fake.recorded(f)
                t0 = time.time()
                events = engine.turn(f"r{run}c{n}", req)
                answer = next((e for e in events if e["type"] == "answer"), None)
                usage = {k: 0 for k in ("calls", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")}
                for e in events:
                    if e["type"] == "usage":
                        for k in usage:
                            usage[k] += e.get(k, 0)
                raw = (answer or {}).get("text", "") + "".join(
                    f"[{t['kind'].upper()}:{','.join(map(str, t['coords']))}:{t['label']}]"
                    for t in (answer or {}).get("targets", []))
                rid = f"{f['kind']}/{F.slug(f['case'])}" + ("" if args.runs == 1 else f"-{run + 1}")
                new = {"schema": F.SCHEMA, "id": rid,
                       "kind": f["kind"], "case": f["case"], "request": r, "expect": f.get("expect", {}),
                       "reply": {"model": str(model), "effort": effort or "", "recorded": time.strftime("%Y-%m-%d"),
                                 "source": f"record from {f['id']}", "raw": raw,
                                 "events": [e for e in events if e["type"] != "delta"] if f["kind"] == "beats" else None,
                                 "usage": usage, "seconds": round(time.time() - t0, 1)},
                       "baseline": None, "human": None}
                v = checks.check(new)
                new["baseline"] = {"pass": v.passed, "why": v.why}
                F.save(new, out / f["kind"] / f"{F.slug(new['id'].split('/', 1)[-1])}.json")
                written += 1
                print(f"{'PASS' if v.passed else 'FAIL'} {new['id']}" + "".join(f"\n       why: {w}" for w in v.why), flush=True)
    finally:
        engine.close()
        if fake:
            fake.httpd.shutdown()
        shutil.rmtree(workdir, ignore_errors=True)
        shutil.rmtree(shots, ignore_errors=True)
    print(f"{written} fixture(s) in {out}; compare with: tools/eval.py compare evals/fixtures {out}")
    return 0


# --- judge: the split rubric, by a different model ------------------------------------------

def judge_calls(fxs: list[dict], judge: str | None) -> list[dict]:
    calls = []
    for f in fxs:
        model = rubrics.judge_model(f["reply"]["model"], judge)
        for qid, _ in rubrics.QUESTIONS[f["kind"]]:
            calls.append({"fixture": f["id"], "question": qid, "judge": model, "prompt": rubrics.prompt(f, qid)})
    return calls


def cmd_judge(args) -> int:
    fxs = _pick(args, _load(args.dir, args.private))
    if args.limit:
        fxs = fxs[:args.limit]
    try:
        calls = judge_calls(fxs, args.judge)
    except ValueError as e:
        print(e)
        return 2
    chars = sum(len(c["prompt"]) + len(rubrics.SYSTEM) for c in calls)
    print(f"{len(calls)} judge calls over {len(fxs)} fixtures, about {chars // 4:,} input tokens; "
          f"judges: {sorted({c['judge'] for c in calls})}")
    if args.batch_out:
        # Message Batches API request lines (50% of the price, results within a day). Submitting them
        # is not built: the file is for the user to send, or for a nightly job once one is decided.
        lines = []
        for n, c in enumerate(calls):
            lines.append({"custom_id": f"c{n:04d}", "params": {
                "model": c["judge"], "max_tokens": 300, "system": rubrics.SYSTEM,
                "messages": [{"role": "user", "content": c["prompt"]}]}})
        Path(args.batch_out).write_text("".join(json.dumps(x) + "\n" for x in lines))
        Path(args.batch_out + ".map.json").write_text(json.dumps(
            {f"c{n:04d}": {"fixture": c["fixture"], "question": c["question"]} for n, c in enumerate(calls)}, indent=1))
        print(f"batch requests in {args.batch_out} (and its .map.json); nothing sent")
        return 0
    if not args.live:
        for c in calls[:3]:
            print(f"\n--- {c['fixture']} / {c['question']} ({c['judge']})\n{c['prompt']}")
        print("\n(--plan only: no call made. --live calls the judge: the user's call.)")
        return 0
    from benji import config, providers
    config.load_dotenv()
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        print("no ANTHROPIC_API_KEY in the environment or ~/.benji.env")
        return 2
    results, usage = [], {"input_tokens": 0, "output_tokens": 0}
    for c in calls:
        reply = providers.AnthropicProvider(key, c["judge"]).complete(
            rubrics.SYSTEM, [{"role": "user", "text": c["prompt"]}], [])
        text = reply.get("text", "")
        for k in usage:
            usage[k] += (reply.get("usage") or {}).get(k, 0)
        results.append({**{k: c[k] for k in ("fixture", "question", "judge")},
                        "verdict": rubrics.parse(text), "reasons": text.strip()})
        print(f"{'YES' if results[-1]['verdict'] else 'NO ' if results[-1]['verdict'] is False else '?? '} "
              f"{c['fixture']} / {c['question']}", flush=True)
    out = Path(args.out or F.RUNS / f"judge-{time.strftime('%Y%m%d-%H%M')}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"results": results, "usage": usage}, indent=2, ensure_ascii=False) + "\n")
    print(f"results in {out}; tokens {usage}")
    return 0


# --- label and agree: a person's answers, and how often the judge matches them --------------

def cmd_label(args, ask=input) -> int:
    fxs = _pick(args, _load(args.dir, args.private))
    done = 0
    for f in fxs:
        if f.get("human") and not args.again:
            continue
        print(f"\n=== {f['id']} ({f['reply']['model']})\n{rubrics.prompt(f, rubrics.QUESTIONS[f['kind']][0][0]).rsplit(chr(10) + chr(10) + 'Question:', 1)[0]}")
        answers = {}
        for qid, question in rubrics.QUESTIONS[f["kind"]]:
            a = ask(f"{question} [y/n/s=skip/q=quit] ").strip().lower()
            if a == "q":
                return 0 if done else 1
            if a in ("y", "n"):
                answers[qid] = a == "y"
        if answers:
            f["human"] = {"by": args.by, "date": time.strftime("%Y-%m-%d"), "answers": answers}
            F.save(f, Path(f["_path"]))
            done += 1
    print(f"{done} fixture(s) labelled")
    return 0


def agreement(judged: list[dict], fxs: list[dict]) -> dict:
    """Per question and overall: pairs, raw agreement and Cohen's kappa between judge and person."""
    human = {f["id"]: (f.get("human") or {}).get("answers", {}) for f in fxs}
    pairs: dict[str, list[tuple[bool, bool]]] = {}
    for r in judged:
        h = human.get(r["fixture"], {}).get(r["question"])
        if h is not None and r.get("verdict") is not None:
            pairs.setdefault(r["question"], []).append((r["verdict"], h))

    def stats(ps):
        n = len(ps)
        if not n:
            return {"pairs": 0}
        agree = sum(a == b for a, b in ps) / n
        pj, ph = sum(a for a, _ in ps) / n, sum(b for _, b in ps) / n
        chance = pj * ph + (1 - pj) * (1 - ph)
        kappa = None if chance == 1 else (agree - chance) / (1 - chance)
        return {"pairs": n, "agree": round(agree, 3), "kappa": None if kappa is None else round(kappa, 3)}

    out = {q: stats(ps) for q, ps in sorted(pairs.items())}
    out["all"] = stats([p for ps in pairs.values() for p in ps])
    return out


def cmd_agree(args) -> int:
    judged = json.loads(Path(args.results).read_text())["results"]
    stats = agreement(judged, _load(args.dir, args.private))
    if not stats["all"]["pairs"]:
        print("no fixture has both a judge verdict and a person's answer; label some with `tools/eval.py label`")
        return 2
    rows = [["question", "pairs", "agree", "kappa"]] + [
        [q, str(s["pairs"]), f"{s.get('agree', 0):.0%}", "-" if s.get("kappa") is None else f"{s['kappa']:.2f}"]
        for q, s in stats.items()]
    print(_table(rows))
    return 0


# --- capture: one of the user's own turns, as a private fixture ------------------------------

def capture(answers: Path, run: str, request: str, kind: str, case: str | None, spoken: bool) -> Path:
    from benji import answer_log
    rec = next((r for r in answer_log.read(answers) if r.get("run") == run), None)
    if rec is None:
        raise F.FixtureError(f"no turn {run!r} in that answer log")
    name = case or F.slug(request)[:40]
    fx = {"schema": F.SCHEMA, "id": f"private/{kind}/{name}", "kind": kind, "case": name,
          "request": {"text": request, "screen": None, "spoken": bool(rec.get("spoken", spoken)),
                      "real_screen": bool(rec.get("screen"))},
          "expect": {}, "reply": {"model": rec.get("model") or "unknown", "effort": "",
                                  "recorded": str(rec.get("time", ""))[:10], "source": f"answers.jsonl {run}",
                                  "raw": rec.get("raw") or "", "events": rec.get("events") or []},
          "baseline": None, "human": None}
    v = checks.check(fx)
    fx["baseline"] = {"pass": v.passed, "why": v.why}
    path = F.PRIVATE / kind / f"{name}.json"
    F.save(fx, path)
    return path


def cmd_capture(args) -> int:
    try:
        path = capture(Path(args.answers).expanduser(), args.run, args.request, args.kind, args.case, args.spoken)
    except (F.FixtureError, OSError) as e:
        print(e)
        return 2
    print(f"private fixture in {path} (kept out of git and the public export)")
    return 0


# --- the command line ----------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="tools/eval.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--dir", help="fixtures folder (default evals/fixtures)")
        p.add_argument("--private", action="store_true", help="include evals/fixtures/private")
        p.add_argument("--kind", choices=F.KINDS)
        p.add_argument("--model", help="only replies by this model")
        p.add_argument("--only", help="only fixture ids containing this")
        return p

    common(sub.add_parser("list", help="fixtures by kind and model"))
    p = common(sub.add_parser("check", help="replay recorded replies through the code checks (offline)"))
    p.add_argument("--strict", action="store_true", help="exit 1 on any failing fixture, not only on drift")
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument("--json", help="write every result here")
    common(sub.add_parser("rebaseline", help="store today's verdicts as the baseline"))
    p = sub.add_parser("compare", help="two fixture sets side by side, matched by question")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--kind", choices=F.KINDS)
    p.add_argument("--only", help="only questions containing this")
    p.add_argument("--a-model", help="in the first set, only replies by this model")
    p.add_argument("--b-model", help="in the second set, only replies by this model")
    p.add_argument("--verbose", "-v", action="store_true")
    p = common(sub.add_parser("record", help="ask the fixtures' questions again through the engine"))
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--fake", action="store_true")
    mode.add_argument("--live", action="store_true")
    p.add_argument("--use-model", help="the model to ask (BENJI_MODEL); --model filters the fixtures")
    p.add_argument("--effort")
    p.add_argument("--runs", type=int, default=1)
    p.add_argument("--out")
    p = common(sub.add_parser("judge", help="the split rubric, judged by a different model"))
    p.add_argument("--judge", help="judge model (default Sonnet 5.5, or Opus 5.5 for Sonnet's replies)")
    p.add_argument("--live", action="store_true")
    p.add_argument("--batch-out", help="write Message Batches requests here instead; nothing is sent")
    p.add_argument("--limit", type=int)
    p.add_argument("--out")
    p = common(sub.add_parser("label", help="answer the rubric yourself, to measure the judge"))
    p.add_argument("--by", default="user")
    p.add_argument("--again", action="store_true")
    p = common(sub.add_parser("agree", help="judge against the human labels"))
    p.add_argument("results")
    p = sub.add_parser("capture", help="one of your own turns from answers.jsonl, as a private fixture")
    p.add_argument("--answers", required=True, help="path to an answers.jsonl (never read unless named)")
    p.add_argument("--run", required=True, help="the turn's run id in that log")
    p.add_argument("--request", required=True, help="what you said or typed (the log doesn't keep it)")
    p.add_argument("--kind", choices=F.KINDS, required=True)
    p.add_argument("--case")
    p.add_argument("--spoken", action="store_true")
    args = ap.parse_args(argv)
    try:
        handler = {"list": cmd_list, "check": cmd_check, "rebaseline": cmd_rebaseline, "compare": cmd_compare,
                   "record": cmd_record, "judge": cmd_judge, "label": cmd_label, "agree": cmd_agree,
                   "capture": cmd_capture}[args.cmd]
        return handler(args)
    except F.FixtureError as e:
        print(f"fixture error: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
