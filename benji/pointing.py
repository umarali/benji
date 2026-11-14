"""The pointing and drawing tags Benji may end a screen-context answer with (D-66, D-67).

  [POINT:x,y:label]              something about the size of a control: a ring
  [BOX:x1,y1,x2,y2:label]        something larger, top-left and bottom-right corners: a region
  [CIRCLE:x1,y1,x2,y2:label]     a hand-drawn loop around that box
  [ARROW:x1,y1,x2,y2:label]      an arrow from x1,y1 to the tip at x2,y2
  [UNDERLINE:x1,y1,x2,y2:label]  a line under text, from x1,y1 to x2,y2
  [HIGHLIGHT:x1,y1,x2,y2:label]  a translucent marker over that box
  [GROUP:x1,y1,x2,y2:label]      a dashed rounded box around a whole region
  [NOTE:x,y:text]                a short note (at most 40 characters) beside x,y
  [CALLOUT:x,y:text]             a label pill (at most 40 characters) beside x,y, pointing to it
and the parts of a picture (D-97):
  [PATH:x1,y1,x2,y2,...:label]   a freehand line through 2 to 40 points, sharp turns kept sharp
  [LINE:x1,y1,x2,y2,...:label]   straight segments through 2 to 40 points
  [SHAPE:x1,y1,x2,y2,...:label]  a closed outline through 3 to 40 points
  [OVAL:x1,y1,x2,y2:label]       an ellipse filling that box
  [TEXT:x,y:size:words]          handwriting (at most 80 characters) from x,y; size small,
                                 medium or large, optional (chilly-whiteboard)
and edits of the drawing already up, by part id (chilly-whiteboard):
  [EDIT:p3:move dx,dy] [EDIT:p3:scale f] [EDIT:p3:relabel text] [EDIT:p3:erase]
  [EDIT:p3:recolor name] [EDIT:all:erase] [EDIT:all:keep] (add to it without changing a part)

Coordinates are pixels in the screenshot that was sent (0,0 top-left). Tags are only read at
the very end of the answer, in the order the user should look at them: at most six (twenty
when the answer draws a picture with PATH, LINE, SHAPE or OVAL), of which at most three are
POINT or BOX. A tag that doesn't parse ends the trailing run and stays in
the text; one that parses but can't be drawn (outside the image, too big, too small) is
removed and dropped. The companion parses these in companion/Sources/BenjiCore/Pointing.swift;
this module mirrors it case for case, and selftest.py runs the same cases as the Core unit tests.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

MAX_TARGETS = 3               # POINT and BOX tags kept
MAX_MARKS = 6                 # tags kept in all
MAX_DRAWING_MARKS = 20        # tags kept in all when the answer draws a picture
RING_MAX_SIDE = 44.0          # pt: a box no bigger than this on both sides gets a ring
MAX_AREA_FRACTION = 1 / 3     # a box covering more of the display gets no mark
MAX_SIDE_FRACTION = 0.8       # nor one wider or taller than this share of the display

MAX_PATH_POINTS = 40          # path, line and shape
MAX_NOTE_CHARS = 40           # Unicode scalars, counted the same way in Swift
MIN_CIRCLE_SIDE = 24.0        # pt: a smaller loop is grown to this around its centre
MIN_HIGHLIGHT_SIDE = 6.0      # pt: a thinner highlight is dropped
MIN_ARROW_LENGTH = 24.0       # pt
MIN_LINE_LENGTH = 8.0         # pt: underline and path
MAX_LINE_FRACTION = 0.8       # arrow and underline: at most this share of the display's long side
MAX_PATH_FRACTION = 3         # path, line, shape: total length at most this share of the long side
MIN_OVAL_SIDE = 6.0           # pt: a thinner oval is grown to this around its centre
MIN_GROUP_SIDE = 12.0         # pt: a thinner dashed group is dropped
MAX_GROUP_AREA_FRACTION = 0.5  # a group may run the display's full height, but cover at most half

MAX_TEXT_CHARS = 80          # a TEXT tag's words
TEXT_SIZES = ("small", "medium", "large")

POINTER_KINDS = ("point", "box")
SKETCH_KINDS = ("circle", "arrow", "underline", "highlight", "path", "line", "shape", "oval", "group",
                "note", "callout", "text")
# A picture's parts: up to twenty tags, and it stays up. Words written on the screen are a part too.
DRAWING_KINDS = ("path", "line", "shape", "oval", "text")
_ARITY = {"POINT": 2, "BOX": 4, "CIRCLE": 4, "ARROW": 4, "UNDERLINE": 4, "HIGHLIGHT": 4, "OVAL": 4,
          "GROUP": 4, "NOTE": 2, "CALLOUT": 2, "TEXT": 2}
_MIN_POINTS = {"PATH": 2, "LINE": 2, "SHAPE": 3}

_NUMBER = re.compile(r"-?[0-9]{1,6}(\.[0-9]+)?")


@dataclass(frozen=True)
class Target:
    kind: str                 # "point", "box", or one of SKETCH_KINDS
    coords: tuple[int, ...]   # screenshot pixels: (x, y), (x1, y1, x2, y2) or (x1, y1, x2, y2, ...)
    label: str = ""           # a NOTE's or CALLOUT's text


@dataclass(frozen=True)
class Mark:
    kind: str                       # "ring", "region", or one of SKETCH_KINDS
    geometry: tuple[float, ...]     # display points, top-left origin:
    #   ring (cx, cy); region, circle, highlight, oval, group (x, y, w, h);
    #   arrow, underline (x1, y1, x2, y2); path, line, shape (x1, y1, x2, y2, ...); note, callout (x, y)
    label: str = ""
    size: str = ""                  # a TEXT mark's size


def text_label(label: str) -> tuple[str, str]:
    """A TEXT tag's label as (size, words): "large:a² + b² = c²" or just the words (medium)."""
    head, sep, rest = label.partition(":")
    if sep and head.strip().lower() in TEXT_SIZES:
        return head.strip().lower(), rest.strip()
    return "medium", label.strip()


def parse_tags(text: str) -> tuple[str, list[Target]]:
    """Return the answer without its trailing tags, and the targets in order (at most six, or
    twenty in a drawing; at most three of them POINT or BOX). A tag followed by more text
    doesn't count; a malformed tag ends the trailing run."""
    rest = text
    found: list[Target] = []
    while True:
        trimmed = rest.rstrip()
        open_at = trimmed.rfind("[")
        if not trimmed.endswith("]") or open_at < 0:
            break
        target = _target(trimmed[open_at + 1:-1])
        if target is None:
            break
        found.insert(0, target)
        rest = trimmed[:open_at]
    if not found:
        return text, []
    return rest.strip(), capped(found)


def capped(found: list[Target]) -> list[Target]:
    """At most six (twenty when any of them draws a picture), of which at most three POINT or
    BOX, in order."""
    limit = MAX_DRAWING_MARKS if any(t.kind in DRAWING_KINDS for t in found) else MAX_MARKS
    kept: list[Target] = []
    pointers = 0
    for t in found:
        if len(kept) == limit:
            break
        if t.kind in POINTER_KINDS:
            if pointers == MAX_TARGETS:
                continue
            pointers += 1
        kept.append(t)
    return kept


def _target(body: str) -> Target | None:
    if "]" in body or ":" not in body:
        return None
    kind, after = body.split(":", 1)
    coords_part, label = (after.split(":", 1) + [""])[:2]
    numbers = [_number(s) for s in coords_part.split(",")]
    if any(n is None for n in numbers):
        return None
    kind = kind.strip().upper()
    n = len(numbers)
    if kind in _MIN_POINTS:
        if n < 2 * _MIN_POINTS[kind] or n % 2:
            return None
    elif _ARITY.get(kind) != n:
        return None
    return Target(kind.lower(), tuple(numbers), label.strip())


def _number(s: str) -> int | None:
    t = s.strip()
    if not _NUMBER.fullmatch(t):
        return None
    return math.floor(float(t) + 0.5)


def _too_big(w: float, h: float, dw: float, dh: float) -> bool:
    return w * h > dw * dh * MAX_AREA_FRACTION or w > dw * MAX_SIDE_FRACTION or h > dh * MAX_SIDE_FRACTION


def mark_for(target: Target, pixel_size: tuple[float, float],
             display_size: tuple[float, float]) -> Mark | None:
    """The mark for one target on a display of `display_size` points, given the size of the
    image that was sent. None when outside the image or too big or small to draw (say it in words)."""
    pw, ph = pixel_size
    dw, dh = display_size
    if pw <= 0 or ph <= 0:
        return None

    def to_points(x: int, y: int) -> tuple[float, float] | None:
        if x < 0 or y < 0 or x > pw or y > ph:
            return None
        return x * dw / pw, y * dh / ph

    points = [to_points(target.coords[i], target.coords[i + 1]) for i in range(0, len(target.coords), 2)]
    if any(p is None for p in points):
        return None
    label = target.label
    kind = target.kind

    if kind == "text":
        size, words = text_label(label)
        if not 0 < len(words) <= MAX_TEXT_CHARS:
            return None
        return Mark("text", points[0], words, size)

    if kind in ("point", "note", "callout"):
        if kind != "point" and not 0 < len(label) <= MAX_NOTE_CHARS:
            return None
        return Mark("ring" if kind == "point" else kind, points[0], label)

    if kind in ("arrow", "underline"):
        (x1, y1), (x2, y2) = points
        length = math.hypot(x2 - x1, y2 - y1)
        shortest = MIN_ARROW_LENGTH if kind == "arrow" else MIN_LINE_LENGTH
        if length < shortest or length > max(dw, dh) * MAX_LINE_FRACTION:
            return None
        return Mark(kind, (x1, y1, x2, y2), label)

    if kind in ("path", "line", "shape"):
        if len(points) > MAX_PATH_POINTS:
            return None
        xs, ys = [p[0] for p in points], [p[1] for p in points]
        ring = points + [points[0]] if kind == "shape" else points
        length = sum(math.hypot(ring[i + 1][0] - ring[i][0], ring[i + 1][1] - ring[i][1])
                     for i in range(len(ring) - 1))
        if (length < MIN_LINE_LENGTH or length > max(dw, dh) * MAX_PATH_FRACTION
                or _too_big(max(xs) - min(xs), max(ys) - min(ys), dw, dh)):
            return None
        return Mark(kind, tuple(v for p in points for v in p), label)

    # box, circle, highlight, oval, group: corners in either order
    (ax, ay), (bx, by) = points
    x, y = min(ax, bx), min(ay, by)
    w, h = abs(ax - bx), abs(ay - by)
    if kind == "box" and w <= RING_MAX_SIDE and h <= RING_MAX_SIDE:
        return Mark("ring", (x + w / 2, y + h / 2), label)
    if kind == "circle":
        if w < MIN_CIRCLE_SIDE:
            x, w = x + w / 2 - MIN_CIRCLE_SIDE / 2, MIN_CIRCLE_SIDE
        if h < MIN_CIRCLE_SIDE:
            y, h = y + h / 2 - MIN_CIRCLE_SIDE / 2, MIN_CIRCLE_SIDE
    if kind == "oval":
        if w < MIN_OVAL_SIDE:
            x, w = x + w / 2 - MIN_OVAL_SIDE / 2, MIN_OVAL_SIDE
        if h < MIN_OVAL_SIDE:
            y, h = y + h / 2 - MIN_OVAL_SIDE / 2, MIN_OVAL_SIDE
    if kind == "highlight" and (w < MIN_HIGHLIGHT_SIDE or h < MIN_HIGHLIGHT_SIDE):
        return None
    if kind == "group":
        if w < MIN_GROUP_SIDE or h < MIN_GROUP_SIDE or w * h > dw * dh * MAX_GROUP_AREA_FRACTION:
            return None
        return Mark("group", (x, y, w, h), label)
    if _too_big(w, h, dw, dh):
        return None
    return Mark("region" if kind == "box" else kind, (x, y, w, h), label)


def marks_for(targets: list[Target], pixel_size: tuple[float, float],
              display_size: tuple[float, float]) -> list[Mark]:
    """Marks for an ordered answer, skipping targets that get none."""
    marks = (mark_for(t, pixel_size, display_size) for t in capped(targets))
    return [m for m in marks if m is not None]


@dataclass(frozen=True)
class ScreenInfo:
    """What the companion says about the screenshot it sent (`screen` in a send request, or
    --screen one-shot), worked out in companion/Sources/BenjiCore/ScreenshotGeometry.swift.
    All lengths are pixels in that screenshot, 0,0 top-left."""
    width: int
    height: int
    notch: tuple[int, int, int, int] | None = None  # x1, y1, x2, y2; None: no hardware notch
    menu_bar: int = 0                                # height of the menu-bar strip; 0: hidden
    built_in: bool | None = None                     # the Mac's own display, or an external one
    displays: int = 0                                # how many displays the Mac has; 0: not said


def screen_info(obj) -> ScreenInfo | None:
    """A ScreenInfo from the companion's JSON object, or None when it isn't usable. A part that
    doesn't fit the image (a notch outside it, a menu bar taller than it) is left out."""
    if not isinstance(obj, dict):
        return None

    def whole(v) -> int | None:
        return v if isinstance(v, int) and not isinstance(v, bool) else None

    w, h = whole(obj.get("width")), whole(obj.get("height"))
    if w is None or h is None or w <= 0 or h <= 0:
        return None
    notch = None
    raw = obj.get("notch")
    if isinstance(raw, list) and len(raw) == 4 and all(whole(v) is not None for v in raw):
        x1, y1, x2, y2 = raw
        if 0 <= x1 < x2 <= w and 0 <= y1 < y2 <= h:
            notch = (x1, y1, x2, y2)
    menu_bar = whole(obj.get("menu_bar")) or 0
    if not 0 <= menu_bar < h:
        menu_bar = 0
    display = obj.get("display")
    built_in = True if display == "built-in" else False if display == "external" else None
    displays = whole(obj.get("displays")) or 0
    return ScreenInfo(w, h, notch, menu_bar, built_in, max(displays, 0))


# ---- edits and tags between sentences (chilly-whiteboard) ---------------------------------------

EDIT_OPS = ("move", "scale", "relabel", "erase", "recolor", "keep")
COLORS = ("mint", "red", "orange", "yellow", "green", "blue", "purple", "pink", "white")
MAX_EDIT_MOVE = 4000          # pixels either way
MIN_EDIT_SCALE, MAX_EDIT_SCALE = 0.2, 5.0
MAX_EDITS = 20

_PART_ID = re.compile(r"p([1-9][0-9]{0,2})", re.I)
_TAG_ANYWHERE = re.compile(r"\[([^\[\]\n]{1,2000})\]")


@dataclass(frozen=True)
class Edit:
    """A change to a part of the drawing already up: `part` "p3" (or "all": erase or keep the whole
    drawing), `op` one of EDIT_OPS, `numbers` (move: dx, dy in screenshot pixels; scale: the factor)
    and `text` (relabel's words, recolor's colour name). A reply with any edit adds its own new
    parts to the drawing instead of replacing it."""
    part: str
    op: str
    numbers: tuple[float, ...] = ()
    text: str = ""

    def event(self) -> dict:
        return {"part": self.part, "op": self.op, "args": list(self.numbers), "text": self.text}


def parse_edit(body: str) -> Edit | None:
    """`body` is the tag without brackets, e.g. "EDIT:p3:move 10,-20". None unless well formed."""
    kind, sep, rest = body.partition(":")
    if not sep or kind.strip().upper() != "EDIT":
        return None
    part, sep, action = rest.partition(":")
    m = _PART_ID.fullmatch(part.strip())
    whole = part.strip().lower() == "all"
    if not sep or (m is None and not whole):
        return None
    op, _, arg = action.strip().partition(" ")
    op, arg = op.lower(), arg.strip()
    if whole:
        return Edit("all", op) if op in ("erase", "keep") and not arg else None
    pid = "p" + m.group(1)
    if op == "move":
        nums = [_number(v) for v in arg.split(",")]
        if len(nums) != 2 or any(n is None or abs(n) > MAX_EDIT_MOVE for n in nums) or nums == [0, 0]:
            return None
        return Edit(pid, op, (float(nums[0]), float(nums[1])))
    if op == "scale":
        if not re.fullmatch(r"[0-9]{1,2}(\.[0-9]{1,3})?", arg):
            return None
        f = float(arg)
        return Edit(pid, op, (f,)) if MIN_EDIT_SCALE <= f <= MAX_EDIT_SCALE and f != 1 else None
    if op == "relabel":
        return Edit(pid, op, (), arg) if 0 < len(arg) <= MAX_TEXT_CHARS else None
    if op == "erase":
        return Edit(pid, op) if not arg else None
    if op == "recolor":
        return Edit(pid, op, (), arg.lower()) if arg.lower() in COLORS else None
    return None


def _tag(body: str) -> Target | Edit | None:
    return parse_edit(body) or _target(body)


def split_tags(text: str) -> tuple[str, list[tuple[Target, int]], list[tuple[Edit, int]]]:
    """Every tag in the answer, wherever it stands (the beats form puts each right after the
    sentence it belongs to), taken out of the text: the text as shown and spoken, the targets
    (capped as `capped` does) and the edits, each with its place, the number of characters of that
    text before it. A tag alone on its line goes with its line break; a tag inside a line takes the
    spaces before it. Tags only at the end come out exactly as `parse_tags` gives them, all placed
    at the end. A bracket that isn't a well-formed tag stays as text."""
    rest, trailing = _trailing(text)
    pieces: list[str] = []
    found: list[tuple[object, int]] = []
    said, i = 0, 0
    tags = [(m, t) for m in _TAG_ANYWHERE.finditer(rest) if (t := _tag(m.group(1))) is not None]
    for k, (m, tag) in enumerate(tags):
        line_start = rest.rfind("\n", 0, m.start()) + 1
        line_end = rest.find("\n", m.end())
        line_end = len(rest) if line_end < 0 else line_end
        # A line of nothing but tags goes with its line break, once its last tag is out.
        bare = rest[line_start:line_end]
        for other, _ in tags:
            if line_start <= other.start() < line_end:
                bare = bare.replace(other.group(0), "", 1)
        alone = not bare.strip()
        before = rest[i:max(i, line_start)] if alone else rest[i:m.start()].rstrip(" \t")
        pieces.append(before)
        said += len(before)
        found.append((tag, said))
        i = m.end()
        last_on_line = k + 1 == len(tags) or tags[k + 1][0].start() >= line_end
        if alone and last_on_line:
            i = min(line_end + 1, len(rest))
    if not found and not any(isinstance(t, Edit) for t in trailing):
        kept = [t for t in trailing if isinstance(t, Target)]
        return (rest.strip(), [(t, len(rest.strip())) for t in capped(kept)], []) if kept else (text, [], [])
    pieces.append(rest[i:])
    joined = "".join(pieces)
    lead = len(joined) - len(joined.lstrip())
    shown = joined.strip()
    placed = [(t, min(max(at - lead, 0), len(shown))) for t, at in found] + [(t, len(shown)) for t in trailing]
    targets = [(t, at) for t, at in placed if isinstance(t, Target)]
    keep = {id(t) for t in capped([t for t, _ in targets])}
    edits = [(t, at) for t, at in placed if isinstance(t, Edit)][:MAX_EDITS]
    return shown, [(t, at) for t, at in targets if id(t) in keep], edits


def _trailing(text: str) -> tuple[str, list]:
    """The trailing run of tags (targets and edits) and the text before it, stripped."""
    rest = text
    found: list = []
    while True:
        trimmed = rest.rstrip()
        open_at = trimmed.rfind("[")
        if not trimmed.endswith("]") or open_at < 0:
            break
        tag = _tag(trimmed[open_at + 1:-1])
        if tag is None:
            break
        found.insert(0, tag)
        rest = trimmed[:open_at]
    return (rest.strip(), found) if found else (text, [])


def said_length(text: str) -> int:
    """How many characters of `text` are said once its tags are out, as `split_tags` takes them out
    of a longer reply that goes on after it (for placing card lines among text that holds tags)."""
    end = "\u0001"     # keeps the tags at its end from counting as the reply's trailing tags
    return len(split_tags(text + end)[0]) - len(end) + (len(text) - len(text.lstrip()))


def strip_tags(text: str) -> str:
    """The text with every well-formed tag taken out, as `split_tags` shows it."""
    return split_tags(text)[0]
