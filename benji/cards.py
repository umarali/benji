"""Explanation-card lines in a reply, read as it streams.

When the app can show cards, the model writes the card as lines of their own between its
spoken sentences, so the app can draw each part on the sentence that talks about it:

    card: {"title":"Sending a letter","heading":"Four hands, one envelope","layout":"flow"}
    You drop the letter in a post box.
    item: {"label":"Post box","note":"you drop it in","icon":"envelope"}
    A machine at the sorting office reads the postcode.
    item: {"label":"Sorting","note":"read by postcode","icon":"tray.2"}
    takeaway: The postcode does most of the work.
    chips: ["Why postcodes?","How long does it take?"]

A line is a card line when, after any indent, it starts with one of the four words and a colon,
and the rest is a JSON object (card, item), a JSON array (chips) or text (takeaway). The word may
be in any case and wrapped in bold (`**Takeaway:**`). `takeaway:` and `chips:` also count later in
a line, after a sentence's end ("That's the rule. Takeaway: …"; without this, a reply
says "Takeaway:" aloud and shows it twice): the words before it are spoken, the rest is the card
line. A card line is never spoken or shown; a card line whose JSON is broken is dropped too.
Everything else is spoken text, newlines included. The app's BenjiCore/Drawing/ExplainCard.swift reads the same lines out of a
finished answer.
"""

from __future__ import annotations

import json
import re

KINDS = ("card", "item", "takeaway", "chips")
_HEADS = tuple(k + ":" for k in KINDS)
# A card line's head: the word, in any case, maybe in bold, then its colon (and a bold end).
_HEAD = re.compile(r"[*_]{0,2}(card|item|takeaway|chips)[*_]{0,2}:[*_]{0,2}", re.I)
# takeaway: and chips: later in a line, after a sentence's end and a space.
_INLINE = re.compile(r"(?<=[.!?])[\"'”)]*\s+(?=[*_]{0,2}(?:takeaway|chips)[*_]{0,2}:)", re.I)
_INLINE_WORDS = ("takeaway:", "chips:")


def card_line(line: str) -> tuple[str, object] | None | bool:
    """What a complete line (no newline) is: (kind, value) for a card line, False for a card line
    that is broken (dropped), None for spoken text."""
    s = line.strip()
    head = _HEAD.match(s)
    if head is None:
        return None
    kind, rest = head.group(1).lower(), s[head.end():].strip()
    if kind == "takeaway":
        if rest.startswith('"'):
            try:
                rest = json.loads(rest)
            except ValueError:
                rest = rest.strip('"')
        return (kind, rest) if isinstance(rest, str) and rest.strip() else False
    want = list if kind == "chips" else dict
    if not rest.startswith("[" if want is list else "{"):
        return None     # "Item: one more thing" is a sentence, not a card line
    try:
        value = json.loads(rest)
    except ValueError:
        return False
    return (kind, value) if isinstance(value, want) else False


def _could_be_card_line(partial: str) -> bool:
    """A line still being written that may yet turn out to be a card line."""
    s = partial.lstrip().lstrip("*_").lower()
    return any(h.startswith(s) or s.startswith(h) for h in _HEADS)


def inline_split(line: str) -> int | None:
    """Where a `takeaway:` or `chips:` card line starts later in a complete line (the whitespace
    before it is dropped), or None. Only after a sentence's end, and only when the rest reads as
    a card line ("Chips: salt and vinegar" stays text)."""
    for m in _INLINE.finditer(line):
        if m.start() > 0 and line[:m.start()].strip() and card_line(line[m.end():]) is not None:
            return m.start()
    return None


def _held_tail(line: str) -> int:
    """How much of a line still being written must wait because a `takeaway:` or `chips:` may be
    starting at its end: from the space after the last sentence end, when what follows could
    still grow into one of those words. Returns where the text that is certainly spoken ends."""
    m = re.search(r"(?<=[.!?])[\"'”)]*\s+([*_]{0,2}[A-Za-z]*[*_]{0,2}:?[*_]{0,2})$", line)
    if m is None:
        return len(line)
    word = m.group(1).replace("*", "").replace("_", "").lower()
    if any(w.startswith(word) or word.startswith(w) for w in _INLINE_WORDS):
        return m.start()
    return len(line)


class CardLines:
    """Splits a reply, as it streams, into spoken text and card lines. feed() takes each piece and
    returns what it settles, in order: ("text", str) and (kind, value). A line that could still
    become a card line is held until its newline; so is the end of a line where a `takeaway:` or
    `chips:` may be starting. finish() settles the last one. Feeding a whole reply in any pieces
    gives the same spoken text and the same card lines."""

    def __init__(self):
        self.line = ""      # the current line so far
        self.sent = 0       # how much of it has gone out as spoken text

    def feed(self, piece: str) -> list[tuple[str, object]]:
        out: list[tuple[str, object]] = []
        while piece:
            nl = piece.find("\n")
            chunk, piece = (piece, "") if nl < 0 else (piece[:nl], piece[nl + 1:])
            self.line += chunk
            if nl < 0:
                out += self._stream()
            else:
                out += self._settle("\n")
        return _merged(out)

    def finish(self) -> list[tuple[str, object]]:
        out = self._settle("") if self.line else []
        self.line, self.sent = "", 0
        return _merged(out)

    def reset(self) -> None:
        self.line, self.sent = "", 0

    def _stream(self) -> list[tuple[str, object]]:
        """The line isn't finished: send what is certainly spoken."""
        if self.sent == 0 and _could_be_card_line(self.line):
            return []
        safe = self.line[:_held_tail(self.line)]
        # A marker that is there already holds the rest of the line, whatever follows it.
        cut = next((m.start() for m in _INLINE.finditer(safe) if safe[:m.start()].strip()), None)
        if cut is not None:
            safe = safe[:cut]
        if len(safe) <= self.sent:
            return []
        text, self.sent = safe[self.sent:], len(safe)
        return [("text", text)]

    def _settle(self, end: str) -> list[tuple[str, object]]:
        line, sent = self.line, self.sent
        self.line, self.sent = "", 0
        if sent == 0:
            found = card_line(line)
            if found is False:
                return []
            if found is not None:
                return [found]
        cut = inline_split(line)
        if cut is None or cut < sent:
            return [("text", line[sent:] + end)]
        out: list[tuple[str, object]] = [("text", line[sent:cut] + end)]
        found = card_line(line[cut:])
        return out + ([found] if found else [])


def _merged(out: list[tuple[str, object]]) -> list[tuple[str, object]]:
    merged: list[tuple[str, object]] = []
    for kind, value in out:
        if kind == "text" and merged and merged[-1][0] == "text":
            merged[-1] = ("text", merged[-1][1] + value)
        elif kind != "text" or value:
            merged.append((kind, value))
    return merged


def split(text: str) -> tuple[str, list[tuple[str, object, int]]]:
    """A whole reply: its spoken text (card lines taken out) and its card lines in order, each
    with where it stood in the spoken text (characters said before it)."""
    scanner = CardLines()
    spoken, found = "", []
    for kind, value in scanner.feed(text) + scanner.finish():
        if kind == "text":
            spoken += value
        else:
            found.append((kind, value, len(spoken)))
    return spoken, found


def event(kind: str, value: object, at: int) -> dict:
    """The --serve event for one card line (without the turn id). `at`: characters of spoken text
    before it, so an app that gets the lines only with the answer can still place them."""
    key = {"card": ("card", "card"), "item": ("card_item", "item"),
           "takeaway": ("card_takeaway", "text")}.get(kind, ("card_chips", "chips"))
    return {"type": key[0], key[1]: value, "at": at}
