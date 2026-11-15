"""Code checks: what can be decided without a judge, for each kind of fixture. Each check reads the
reply with Benji's own parsers (`benji.figures`, `benji.pointing`) and returns a Verdict: the
failures (`why`), things worth seeing that don't fail a turn (`notes`) and numbers to track (`metrics`).

The rules are the ones the first evals of figures, cards and beats used when their recorded replies
were judged, gathered here so every kind is scored in one place.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

from benji import figures, pointing


@dataclass
class Verdict:
    why: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    metrics: dict = field(default_factory=dict)

    @property
    def passed(self) -> bool:
        return not self.why


def sentences(text: str) -> int:
    return len([p for p in re.split(r"(?<=[.!?…])\s+|\n+", text.strip()) if re.search(r"\w", p)])


# --- figures ------------------------------------------------------------------------------------

FIGURE_LEAKS = re.compile(r"\bJSON\b|\bfigure block\b|\bthe block\b|```", re.I)
# Words about the model instead of the thing: a metric, never a failure. Only precise phrases:
# "the model", "on the board", "you can turn the handlebar" and "each fuse is labelled with" are ordinary
# things to say about a device, so they don't count. English only.
FIGURE_NARRATION = re.compile(r"""
    \bI(?:'ve|\ have)?\ (?:drawn|built|modell?ed|rendered|sketched|labell?ed)\b
  | \byou\ can\ (?:turn|rotate|spin|drag)\ (?:it|around)\b
  | \blabell?ed(?=[.!?]|\s*$)
  | \b3-?D\ model\b
  | \bhere(?:'s|\ is)\b[^.!?\n]*\bin\ 3-?D\b
  | \bin\ the\ panel\b
  | \b(?:drawn|shown)\ here\b
  | \bseen\ from\ (?:the\ )?(?:side|front|above|below|behind)\b
  | \bnose\ (?:pointing\ )?to\ the\ (?:right|left)\b
""", re.I | re.X)


def check_figure(fx: dict) -> Verdict:
    v = Verdict()
    words, fig = figures.parse_figure(fx["reply"]["raw"])
    if fig is None:
        v.why.append("no figure block that parses")
        return v
    v.metrics = {"parts": len(fig.parts), "labels": len(fig.labels), "vertices": fig.vertices,
                 "dropped": fig.dropped, "kinds": sorted({p.kind for p in fig.parts})}
    if fig.dropped:
        v.why.append(f"{fig.dropped} part(s) dropped")
    if len(fig.parts) < 3:          # a mug is rightly 3-4 parts
        v.why.append(f"only {len(fig.parts)} parts")
    if not fig.labels:
        v.why.append("no labels")
    if not fig.title:
        v.why.append("no title")
    text = words.strip()
    if not text:
        v.why.append("no words, only the figure")
    if FIGURE_LEAKS.search(text):
        v.why.append("the words mention the block or JSON")
    v.metrics["narration"] = sorted({m.group(0).lower() for m in FIGURE_NARRATION.finditer(text)})
    if v.metrics["narration"]:
        v.notes.append(f"words about the model: {v.metrics['narration']}")
    if fx["request"].get("spoken") and sentences(text) > 3:
        v.why.append(f"spoken reply of {sentences(text)} sentences")
    boxes = [p.name for p in fig.parts if p.kind == "box"]
    if len(boxes) * 2 > len(fig.parts):        # the "box on a box" look: a figure built mostly of plain boxes
        v.notes.append(f"{len(boxes)} of {len(fig.parts)} parts are plain boxes")
    return v


# --- cards (the fenced `card` block) ----------------------------------------------------------

FENCE = re.compile(r"^[ \t]*```[ \t]*([A-Za-z]*)[ \t]*\n(.*?)\n[ \t]*```[ \t]*$", re.M | re.S)
CARD_LEAKS = re.compile(r"\bJSON\b|\bcard block\b|\bthe block\b|\blayout\b|```", re.I)
DRAWN = {"box", "shape", "line", "path", "oval", "arrow", "group", "note", "callout"}   # ink that builds a diagram


def find_card(raw: str):
    """The last `card` block (or a `json` one at the very end) as a dict, and the words without it.
    A light mirror of the app's ExplainCardGrammar.parse."""
    found = None
    for m in FENCE.finditer(raw):
        info = m.group(1).lower()
        at_end = not pointing.parse_tags(raw[m.end():])[0].strip()
        if info == "card" or (info == "json" and at_end):
            try:
                body = json.loads(m.group(2))
            except ValueError:
                continue
            if isinstance(body, dict) and "parts" not in body and isinstance(body.get("items"), list) and body["items"]:
                found = (m, body)
    if not found:
        return None, raw
    m, body = found
    return body, (raw[:m.start()].strip() + "\n" + raw[m.end():].strip()).strip()


def check_card(fx: dict) -> Verdict:
    v = Verdict()
    raw = fx["reply"]["raw"]
    expect = fx.get("expect", {})
    card, words = find_card(raw)
    words, targets = pointing.parse_tags(words)
    v.metrics = {"card": card is not None, "marks": len(targets)}
    if not expect.get("card", True):
        if card is not None:
            v.why.append("a card where none belongs")
        if expect.get("marks") == "point" and not targets:
            v.why.append("no mark on the line")
        if expect.get("marks") == "picture" and len(targets) < 3:
            v.why.append("no picture drawn")
        return v
    if card is None:
        v.why.append("no card block that parses" + (" (a ```card fence is there)" if "```card" in raw else ""))
    drawn = [t for t in targets if t.kind in DRAWN]
    if drawn:
        v.why.append(f"{len(drawn)} mark(s) drawn over the screen ({', '.join(sorted({t.kind for t in drawn}))})")
    text = words.strip()
    if not text:
        v.why.append("no words, only the card")
    if CARD_LEAKS.search(text):
        v.why.append("the words mention the block, JSON or layout")
    if fx["request"].get("spoken") and sentences(text) > 3:
        v.why.append(f"spoken reply of {sentences(text)} sentences")
    if card is not None:
        items = card["items"]
        v.metrics.update(items=len(items), layout=card.get("layout"))
        long = [i.get("label", "") for i in items if isinstance(i, dict) and len(i.get("label", "")) > 28]
        if long:
            v.why.append(f"labels over 28 characters: {long}")
        chips = card.get("chips") or []
        if not 1 <= len(chips) <= 3:
            v.notes.append(f"{len(chips)} chips")
        if any(len(c) > 48 for c in chips if isinstance(c, str)):
            v.why.append("a chip over 48 characters (it would be dropped)")
        if expect.get("layout") and card.get("layout") != expect["layout"]:
            v.notes.append(f"layout {card.get('layout')!r}, a person might pick {expect['layout']!r}")
    return v


# --- beats (card lines streamed between spoken sentences) -------------------------------------

BEATS_LEAKS = re.compile(r"\bJSON\b|\bthe card line\b|\bitem:|\bcard:|\bchips:|\btakeaway:|```", re.I)


def check_beats(fx: dict) -> Verdict:
    v = Verdict()
    events = fx["reply"]["events"]
    expect = fx.get("expect", {})
    answer = next((e for e in events if e.get("type") == "answer"), None)
    if answer is None:
        v.why = ["no answer"] + [e.get("text", "") for e in events if e.get("type") == "error"]
        return v
    words = answer.get("text", "")
    lines = [e for e in events if e.get("type") in ("card", "card_item", "card_takeaway", "card_chips")]
    head = next((e for e in lines if e["type"] == "card"), None)
    items = [e for e in lines if e["type"] == "card_item"]
    v.metrics = {"card": head is not None, "items": len(items), "sentences": sentences(words)}
    if not expect.get("card", True):
        if lines:
            v.why.append("a card where none belongs")
        if expect.get("marks") == "point" and not answer.get("targets"):
            v.why.append("no mark on the line")
        return v
    if head is None:
        v.why.append("no card line" + (" (items only)" if items else ""))
    elif head.get("at") != 0:
        v.why.append(f"the card line came after {head.get('at')} characters of words, not first")
    if len(items) < 2:
        v.why.append(f"{len(items)} item line(s)")
    if BEATS_LEAKS.search(words):
        v.why.append("the words mention or show the card lines")
    if items:
        ats = [e.get("at", 0) for e in items]
        ends, said = [], 0
        for s in re.split(r"(?<=\n)", words):
            said += len(s)
            if s.strip():
                ends.append(said)
        last = max(len(ends) - 1, 0)
        owners = [min(next((k for k, end in enumerate(ends) if end >= at), last), last) for at in ats]
        if ats[0] == 0:
            v.why.append("the first item came before any words")
        if len(set(owners)) < len(owners):
            v.notes.append(f"items share sentences: owners {owners}")
        if len(set(owners)) < max(2, (len(owners) + 1) // 2):
            v.why.append(f"items not spread over sentences: owners {owners}")
        long = [e["item"].get("label", "") for e in items if len(e.get("item", {}).get("label", "")) > 28]
        if long:
            v.why.append(f"labels over 28 characters: {long}")
    spoken = sentences(words)
    if fx["request"].get("spoken") and spoken > len(items) + 2:
        v.why.append(f"{spoken} spoken sentences for {len(items)} parts")
    return v


CHECKS = {"figure": check_figure, "card": check_card, "beats": check_beats}


def check(fx: dict) -> Verdict:
    try:
        return CHECKS[fx["kind"]](fx)
    except Exception as e:  # noqa: BLE001  (a check that crashes is a finding, not a harness crash)
        return Verdict(why=[f"check crashed: {type(e).__name__}: {e}"])
