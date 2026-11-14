"""The split rubric: yes/no questions a judge answers one per call, about what code can't decide.

One question per call keeps one criterion from colouring another (the halo effect) and makes each
answer checkable against a person's answer to the same question. Every question is phrased so that
"yes" is the good answer. The judge is always a different model from the one that wrote the reply
(self-preference bias, arxiv.org/abs/2306.05685), it gives one line of reasons before its verdict
(reasoning before the answer), and its verdict is the last word: YES or NO.

The judge reads text only: the request and the reply as the app would show it. A figure is judged from
its parts and labels, not its render; judging the picture itself needs the render tool and is not built.
"""

from __future__ import annotations

import json
import re

from benji import figures, pointing

from . import checks

QUESTIONS: dict[str, list[tuple[str, str]]] = {
    "figure": [
        ("parts-cover", "Do the figure's named parts include the main parts a person would expect to see in "
                        "this subject (no obvious part missing)?"),
        ("labels-useful", "Are the labels on the parts a learner would most want named?"),
        ("words-explain", "Do the spoken or written words explain the subject itself, rather than describe the "
                          "figure, the block or the drawing process?"),
        ("honest", "Is everything the words state about the subject true (no invented facts)?"),
    ],
    "card": [
        ("fits-request", "Does the reply answer what the person asked, at the length they would want?"),
        ("card-earns-place", "If there is a card: does it add structure the words alone would not give "
                             "(steps, a flow, a comparison)? If there is no card: is that right for this request?"),
        ("labels-clear", "Are the card's labels and notes short, plain and correct? Answer YES if there is no card."),
        ("honest", "Is everything the reply states true (no invented facts)?"),
    ],
    "beats": [
        ("fits-request", "Does the spoken answer answer what the person asked, briefly enough to listen to?"),
        ("items-match", "Does each card item name what the sentence around it is saying? Answer YES if there "
                        "is no card."),
        ("honest", "Is everything the reply states true (no invented facts)?"),
    ],
}

SYSTEM = ("You grade one reply from Benji, a voice and screen assistant for a Mac, against one question. "
          "Be strict and literal. You cannot see any screenshot the person attached: never count a claim "
          "about what is on their screen against the reply, and take marks listed as drawn there as done. "
          "Write at most two sentences of reasons, then on the last line write exactly "
          "VERDICT: YES or VERDICT: NO.")

VERDICT = re.compile(r"VERDICT:\s*(YES|NO)\s*\W*\s*\Z", re.I)


def shown(fx: dict) -> str:
    """The reply as the person would meet it, in plain text: words, then the card or the figure's parts."""
    kind = fx["kind"]
    if kind == "beats":
        events = fx["reply"]["events"]
        answer = next((e for e in events if e.get("type") == "answer"), {})
        items = [e["item"] for e in events if e.get("type") == "card_item"]
        head = next((e["card"] for e in events if e.get("type") == "card"), None)
        out = "Spoken: " + answer.get("text", "").strip()
        marks = answer.get("targets") or []
        if marks:
            out += f"\nMarks on the screen: {', '.join(t['kind'] + ' ' + repr(t['label']) for t in marks)}"
        if head:
            out += f"\nCard: {head.get('title', '')} ({head.get('layout', '')})" + "".join(
                f"\n  - {i.get('label', '')}: {i.get('note', '')}" for i in items)
        return out
    raw = fx["reply"]["raw"]
    if kind == "card":
        card, words = checks.find_card(raw)
        words, targets = pointing.parse_tags(words)
        out = "Words: " + words.strip()
        if targets:
            out += f"\nMarks on the screen: {', '.join(t.kind + ' ' + repr(t.label) for t in targets)}"
        if card:
            out += "\nCard: " + json.dumps(card, ensure_ascii=False)
        return out
    words, fig = figures.parse_figure(raw)
    out = "Words: " + words.strip()
    if fig:
        out += f"\nFigure title: {fig.title}\nParts: " + ", ".join(f"{p.name} ({p.kind})" for p in fig.parts)
        out += "\nLabels: " + ", ".join(l["text"] for l in fig.labels)
    return out


def prompt(fx: dict, qid: str) -> str:
    question = dict(QUESTIONS[fx["kind"]])[qid]
    screen = fx["request"].get("screen")
    context = (f"The person {'said' if fx['request'].get('spoken') else 'typed'}: {fx['request']['text']!r}"
               + (f" (with a screenshot of a {screen} attached)" if screen else ""))
    return f"{context}\n\nBenji's reply:\n{shown(fx)}\n\nQuestion: {question}"


def parse(text: str) -> bool | None:
    """True for YES, False for NO, None when the judge didn't end with a verdict."""
    m = VERDICT.search(text.strip())
    return None if m is None else m.group(1).upper() == "YES"


def judge_model(reply_model: str, wanted: str | None = None) -> str:
    """A judge that is not the model that wrote the reply."""
    if wanted:
        if wanted == reply_model:
            raise ValueError(f"the judge must not be the model that wrote the reply ({reply_model})")
        return wanted
    return "claude-opus-5-5" if reply_model == "claude-sonnet-5-5" else "claude-sonnet-5-5"
