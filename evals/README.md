# Eval harness

Measures Benji's replies, so a change to the prompt, the model, a parser or a tool can be judged by
numbers before anyone tries it live. Any change meant to improve replies (prompts, figure parts and
examples, thinking settings, languages) should be scored here.

**Order of trust:** code checks first (cheap, exact, offline). Then a judge model for what code can't
decide, one yes/no question per call, never the model that wrote the reply. Then a person's answers to
the same questions, to measure how often the judge agrees with a person.

## Commands

```bash
python3 -I tools/eval.py list                       # fixtures by kind and model
python3 -I tools/eval.py check                      # replay recorded replies through the code checks (offline)
python3 -I tools/eval.py check --kind figure -v     # every result, with notes
python3 -I tools/eval.py rebaseline                 # after a deliberate change to a check or parser
python3 -I tools/eval.py record --plan              # what a new run would ask; no call
python3 -I tools/eval.py record --fake              # the whole pipeline against a localhost model
python3 -I tools/eval.py record --live --use-model claude-haiku-5-5 --effort low   # paid: spends API credit
python3 -I tools/eval.py compare evals/fixtures evals/runs/<run> --a-model claude-haiku-5-5
python3 -I tools/eval.py judge --plan               # the split rubric, prompts shown; no call
python3 -I tools/eval.py judge --batch-out batch.jsonl   # Message Batches requests (50% off); nothing sent
python3 -I tools/eval.py judge --live               # paid: spends API credit
python3 -I tools/eval.py label                      # your own yes/no answers to the rubric
python3 -I tools/eval.py agree evals/runs/judge-<stamp>.json
```

`check` exits 1 when any fixture's verdict differs from its stored baseline (drift): a parser or check
change that alters a verdict has to be seen and re-baselined on purpose. `--strict` also fails on
fixtures that fail. `tests/selftest.py` runs the replay, so drift fails the selftest.

## Fixtures

One JSON file per recorded turn: what was asked, one model's reply, what is expected, the baseline
verdict and, optionally, a person's rubric answers. The format is at the top of `fixtures.py`.

| Kind | What the checks read | Checks (from the feature evals) |
|---|---|---|
| `figure` | the reply's `figure` block, through `benji.figures` | parses, nothing dropped, ≥ 3 parts, labels, a title, words that don't mention the block. Counted separately, never a failure: words about the model (precise English phrases such as "I've drawn", "3D model", "seen from the side") |
| `card` | the fenced `card` block and the pointing tags | a card when one belongs and none when it doesn't, no diagram drawn over the screen, labels ≤ 28 characters, chips ≤ 48, short spoken replies |
| `beats` | the turn's events (card lines streamed between sentences) | the card line first, items spread over sentences, no card-line text spoken, sentences per part |

The recorded fixtures are real model replies to typed questions on synthetic screens, each with a
human label.

**Your own turns** go in `evals/fixtures/private/`, which git ignores:

```bash
python3 -I tools/eval.py capture --answers ~/.benji/answers.jsonl --run t26 --request "what you said" --kind card
```

The answer log keeps the reply but not the request, so you type the request. The screenshot isn't kept
either, so a captured turn can be checked and judged but not asked again.

## Recording a new run

`record` asks each question once through the real engine (`benji --serve`, the behaviour eval's
driver: every tool off, approvals answered No, a temporary working folder, no memory), with figures,
cards and streaming on as the app runs it. The fixtures' screens are the behaviour eval's synthetic
ones; nothing on the Mac is captured. Each turn is written as a fixture under `evals/runs/<stamp>-<model>/`
with its tokens and time. `compare` matches two sets by question and prints pass rates and an estimated
cost per passing turn (Anthropic's list prices, cache reads 0.1×, writes 1.25×).

## Not built yet

- Judging a figure's render: the judge reads parts and labels as text only.
- Submitting the batch file and a nightly schedule (the file is written; sending it is up to you).
- Turn-level timing fixtures (first word, first mark): `~/.benji/latency.jsonl` holds them, unimported.
- Walkthrough and language fixtures: those features don't exist yet.
