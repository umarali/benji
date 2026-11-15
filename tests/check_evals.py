"""Checks the eval harness in evals/ and tools/eval.py. Called from selftest.py.

What is pinned here, and why:
  - every shared fixture is well formed and replays to its stored baseline (a parser or check change
    that alters a verdict must be seen and re-baselined on purpose: `tools/eval.py rebaseline`);
  - the checks catch what they claim to (each one shown failing on a planted reply);
  - the fixture validator refuses broken fixtures;
  - `record --fake` sends the fixtures' questions through the real engine and gets the baseline back;
  - the judge never grades its own model's reply, splits the rubric one question per call, reads its
    verdict only from the last line, and its agreement with a person is computed right;
  - a captured turn of the user's own lands in the private folder, which git and the export leave out.
No network beyond localhost, no API key, nothing read from the user's ~/.benji.
"""

from __future__ import annotations

import contextlib
import copy
import io
import json
import shutil
import tempfile
from pathlib import Path


def run(check, here: Path) -> None:
    from evals import checks, harness, rubrics
    from evals import fixtures as F

    print("eval harness:")
    fxs = F.load_dir(F.FIXTURES)
    kinds = {k: sum(f["kind"] == k for f in fxs) for k in F.KINDS}
    check("at least 40 shared fixtures, of every kind", len(fxs) >= 40 and all(kinds.values()))
    check("no shared fixture is a private one or came from the user's answer log",
          all(not f["id"].startswith("private/") and "answers.jsonl" not in f["reply"].get("source", "") for f in fxs))
    results = harness.run_checks(fxs)
    drift = [r["id"] for r in results if r["drift"]]
    check("every shared fixture replays to its stored baseline" + (f" (drift: {drift})" if drift else ""), not drift)
    check("the baselines hold known failures too (the checks are not all-pass)",
          any(not r["pass"] for r in results) and sum(r["pass"] for r in results) > len(results) // 2)

    # ---- the checks fail on what they claim to -------------------------------------------------
    def first(kind, case=None):
        return copy.deepcopy(next(f for f in fxs if f["kind"] == kind and (case is None or f["case"] == case)
                                  and (f.get("baseline") or {}).get("pass")))

    fig = first("figure")
    fig["reply"]["raw"] = "Here is the JSON for it.\n" + fig["reply"]["raw"].split("\n", 1)[1]
    check("figure: words that mention JSON fail", "the words mention the block or JSON" in checks.check(fig).why)
    block = first("figure")["reply"]["raw"]
    block = block[block.index("```"):]

    def said(words):
        f = first("figure")
        f["reply"]["raw"] = words + "\n" + block
        return checks.check(f)

    check("figure: words about the model are counted",
          all(said(w).metrics["narration"] for w in (
              "I've drawn a sports car as a lit 3D model.", "Here's a bicycle seen from the side.",
              "The group head, portafilter and steam wand are labelled.", "A mug. It's drawn here as a ring of wall.",
              "Here's a sports car in 3D, nose to the right.", "A turbine you can turn it around to see.")))
    check("figure: counted, but never a failure", said("I've drawn it as a 3D model.").passed
          and any(n.startswith("words about the model") for n in said("I've drawn it.").notes))
    ordinary = ("The capacitors on the board smooth the power supply.", "To steer, you can turn the handlebar left or right.",
                "You can spin the wheel freely when the clutch is out.", "The spine is labelled by its vertebrae.",
                "Each fuse is labelled with its rating.", "The figure eight is a basic skating move.",
                "The drawing board tilts so an architect can work standing.", "The model year changed the grille.",
                "A 3D printer builds objects in 3D.", "I've made it clearer: the left ventricle is the thickest.",
                "Bohr's model pictures electrons in orbits; the model is simple.", "The front to the left brings rain.",
                "The Model 3 is Tesla's small sedan.", "This is a simplified version: the outer wall is cut open.",
                "A wind turbine turns the wind's push into electricity.")
    check("figure: ordinary sentences about a device, and caveats, are not counted",
          not any(said(w).metrics["narration"] for w in ordinary))
    fig = first("figure")
    fig["reply"]["raw"] = "A plane."
    check("figure: no block fails", checks.check(fig).why == ["no figure block that parses"])
    card = first("card", "compare")
    card["reply"]["raw"] = card["reply"]["raw"].replace('"label":"iCloud Drive"', '"label":"' + "x" * 40 + '"')
    check("card: a label over 28 characters fails", any("over 28" in w for w in checks.check(card).why))
    card = first("card", "point, no card")
    card["reply"]["raw"] = "The second line is underlined."
    check("card: a control with no mark fails", checks.check(card).why == ["no mark on the line"])
    beats = first("beats", "how it works")
    beats["reply"]["events"] = [e for e in beats["reply"]["events"] if e["type"] != "card"]
    check("beats: items with no card line fail", any(w.startswith("no card line") for w in checks.check(beats).why))
    beats = first("beats", "how it works")
    for e in beats["reply"]["events"]:
        if e["type"] == "card":
            e["at"] = 12
    check("beats: a card line after the first words fails",
          any("not first" in w for w in checks.check(beats).why))
    broken = first("figure")
    broken["reply"]["raw"] = None
    check("a check that crashes is a failure, not a harness crash", checks.check(broken).why[0].startswith("check crashed"))

    # ---- the validator ----------------------------------------------------------------------------
    good = {k: v for k, v in first("card").items() if not k.startswith("_")}

    def refused(change) -> bool:
        bad = copy.deepcopy(good)
        change(bad)
        try:
            F.validate(bad)
        except F.FixtureError:
            return True
        return False

    check("validator: a good fixture passes", F.validate(copy.deepcopy(good)) is not None)
    check("validator: refuses a wrong schema, kind, screen or empty request",
          refused(lambda f: f.update(schema=2)) and refused(lambda f: f.update(kind="poem"))
          and refused(lambda f: f["request"].update(screen="/Users/someone/Desktop/shot.png"))
          and refused(lambda f: f["request"].update(text=" ")))
    check("validator: refuses human labels that are not true/false",
          refused(lambda f: f.update(human={"by": "x", "answers": {"honest": "yes"}})))
    check("validator: a beats fixture needs events", refused(lambda f: f.update(kind="beats")))

    # ---- record --fake: the real engine, a localhost model -----------------------------------------
    tmp = Path(tempfile.mkdtemp(prefix="benji-eval-test-"))
    try:
        run_dir = tmp / "run"
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = harness.main(["record", "--fake", "--kind", "figure", "--model", "claude-haiku-5-5",
                                 "--out", str(run_dir)])
        recorded = F.load_dir(run_dir, private=True)
        check("record --fake: every figure question asked once, through the real engine",
              code == 0 and len(recorded) == kinds["figure"] // 2 and all(f["reply"]["model"] == "fake" for f in recorded))
        base = {f["case"]: f["baseline"]["pass"] for f in fxs if f["kind"] == "figure" and f["reply"]["model"] == "claude-haiku-5-5"}
        check("record --fake: the engine gives the recorded verdicts back",
              all(f["baseline"]["pass"] == base[f["case"]] for f in recorded))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            harness.main(["compare", str(F.FIXTURES), str(run_dir), "--a-model", "claude-haiku-5-5", "--kind", "figure"])
        check("compare: matched by question, nothing fixed or broken", "0 fixed, 0 broken" in out.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = harness.main(["compare", str(F.FIXTURES), str(run_dir), "--kind", "figure"])
        check("compare: two models answering one question is refused, not silently mixed",
              code == 2 and "more than once" in out.getvalue())
        beats = first("beats", "how it works")
        raw = harness.beats_raw(beats["reply"]["events"])
        check("beats: the rebuilt reply starts with the card line and keeps every item",
              raw.startswith("card: ") and raw.count("\nitem: ") == sum(e["type"] == "card_item" for e in beats["reply"]["events"]))

        # ---- the judge -----------------------------------------------------------------------------
        sonnet = next(f for f in fxs if f["reply"]["model"] == "claude-sonnet-5-5")
        check("judge: never the model that wrote the reply",
              rubrics.judge_model("claude-haiku-5-5") == "claude-sonnet-5-5"
              and rubrics.judge_model("claude-sonnet-5-5") == "claude-opus-5-5"
              and harness.judge_calls([sonnet], None)[0]["judge"] == "claude-opus-5-5")
        try:
            rubrics.judge_model("claude-sonnet-5-5", "claude-sonnet-5-5")
            self_judged = True
        except ValueError:
            self_judged = False
        check("judge: asking a model to judge itself is refused", not self_judged)
        point = next(f for f in fxs if f["id"] == "beats/point")
        check("judge: a beats reply shows the marks the engine drew (the first live run missed them)",
              "Marks on the screen: underline" in rubrics.shown(point))
        check("judge: told it can't see the screenshot, so screen claims don't count against a reply",
              "cannot see any screenshot" in rubrics.SYSTEM)
        calls = harness.judge_calls(fxs, None)
        check("judge: one call per fixture and question", len(calls) == sum(len(rubrics.QUESTIONS[f["kind"]]) for f in fxs)
              and all(c["prompt"].count("Question:") == 1 for c in calls))
        check("judge: the verdict is read from the last line only",
              rubrics.parse("Clear and short.\nVERDICT: YES") is True
              and rubrics.parse("It says VERDICT: YES about one part, but\nVERDICT: NO") is False
              and rubrics.parse("VERDICT: YES\nActually I'm not sure.") is None
              and rubrics.parse("looks fine") is None)
        batch = tmp / "batch.jsonl"
        with contextlib.redirect_stdout(io.StringIO()):
            harness.main(["judge", "--kind", "card", "--batch-out", str(batch)])
        lines = [json.loads(x) for x in batch.read_text().splitlines()]
        check("judge --batch-out: Message Batches lines with short ids and a map, nothing sent",
              lines and all(set(x) == {"custom_id", "params"} and len(x["custom_id"]) <= 64 for x in lines)
              and len(json.loads(Path(str(batch) + ".map.json").read_text())) == len(lines))

        class FakeProvider:            # stands in for AnthropicProvider: no network
            def __init__(self, key, model):
                self.model = model

            def complete(self, system, neutral, tools):
                assert not tools and system == rubrics.SYSTEM
                return {"text": "Fine.\nVERDICT: YES", "usage": {"input_tokens": 100, "output_tokens": 10}}

        import os
        from benji import config, providers
        real, saved_key = providers.AnthropicProvider, os.environ.get("ANTHROPIC_API_KEY")
        real_dotenv = config.load_dotenv
        providers.AnthropicProvider = FakeProvider
        config.load_dotenv = lambda: None        # never read the user's ~/.benji.env in a test
        os.environ["ANTHROPIC_API_KEY"] = "test-not-a-key"
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                code = harness.main(["judge", "--live", "--kind", "card", "--limit", "2", "--out", str(tmp / "j.json")])
        finally:
            providers.AnthropicProvider = real
            config.load_dotenv = real_dotenv
            if saved_key is None:
                os.environ.pop("ANTHROPIC_API_KEY", None)
            else:
                os.environ["ANTHROPIC_API_KEY"] = saved_key
        judged = json.loads((tmp / "j.json").read_text())
        check("judge --live (fake provider): verdicts and tokens saved",
              code == 0 and len(judged["results"]) == 8 and all(r["verdict"] is True for r in judged["results"])
              and judged["usage"]["input_tokens"] == 800)

        # ---- label and agree -----------------------------------------------------------------------
        lab = tmp / "lab"
        shutil.copytree(F.FIXTURES / "card", lab / "card")
        answers = iter(["y", "n", "y", "s"] + ["q"])
        with contextlib.redirect_stdout(io.StringIO()):
            harness.cmd_label(type("A", (), {"dir": str(lab), "private": False, "kind": None, "model": None,
                                             "only": "compare", "by": "test", "again": False})(),
                              ask=lambda prompt: next(answers))
        labelled = next(f for f in F.load_dir(lab) if f["case"] == "compare")
        check("label: a person's answers are stored, skips left out",
              labelled["human"]["answers"] == {"fits-request": True, "card-earns-place": False, "labels-clear": True})
        judged = [{"fixture": "card/compare", "question": q, "verdict": v}
                  for q, v in (("fits-request", True), ("card-earns-place", True), ("labels-clear", True), ("honest", True))]
        stats = harness.agreement(judged, F.load_dir(lab))
        check("agree: pairs only where both answered; raw agreement right",
              stats["all"]["pairs"] == 3 and stats["all"]["agree"] == round(2 / 3, 3)
              and stats["card-earns-place"]["agree"] == 0.0)
        many = [{"fixture": f"x{i}", "question": "q", "verdict": i % 2 == 0} for i in range(10)]
        people = [{"id": f"x{i}", "human": {"answers": {"q": i % 2 == 0 if i < 8 else i % 2 == 1}}} for i in range(10)]
        k = harness.agreement(many, people)["q"]
        check("agree: Cohen's kappa (8 of 10 agree, balanced: 0.6)", k["agree"] == 0.8 and k["kappa"] == 0.6)

        # ---- capture: the user's own turn, private -------------------------------------------------
        log = tmp / "answers.jsonl"
        log.write_text(json.dumps({"time": "2026-11-07T20:10:00+0500", "run": "t9", "status": "ok",
                                   "model": "claude-haiku-5-5", "spoken": True, "screen": {"w": 1}, "canvas": None,
                                   "raw": "A cell.\n" + fig_block(fxs), "events": []}) + "\n")
        saved = F.PRIVATE
        F.PRIVATE = tmp / "private"
        try:
            path = harness.capture(log, "t9", "Show me a cell.", "figure", "cell", False)
            got = F.load(path)
        finally:
            F.PRIVATE = saved
        check("capture: the turn becomes a private fixture with the request given and the screen not kept",
              path.parent.parent == tmp / "private" and got["id"].startswith("private/")
              and got["request"]["real_screen"] is True and got["request"]["screen"] is None and got["baseline"] is not None)
        try:
            harness.capture(log, "t404", "x", "figure", None, False)
            missing = False
        except F.FixtureError:
            missing = True
        check("capture: an unknown turn is refused", missing)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    ignored = (here / ".gitignore").read_text()
    check("private fixtures and runs are kept out of git", "evals/fixtures/private/" in ignored and "evals/runs/" in ignored)


def fig_block(fxs) -> str:
    """A figure block from a recorded reply (a known-good one), for the capture case."""
    from evals import fixtures as F  # noqa: F401
    raw = next(f for f in fxs if f["kind"] == "figure" and f["baseline"]["pass"])["reply"]["raw"]
    return raw[raw.index("```"):]
