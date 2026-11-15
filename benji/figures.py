"""The figure block: a fenced JSON block at the end of a reply that describes a 3D
figure as named parts. Parsed case for case like the app's BenjiCore/Figures/FigureGrammar.swift;
both reduce a block to the same canonical summary, checked on the shared cases in
companion/Tests/figure-cases.json. The grammar the model is taught is in benji/prompts.py (figure_rule)."""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field

from .pointing import parse_tags

MAX_PARTS = 40
MAX_LABELS = 12
MAX_VERTICES = 120_000
MAX_TITLE = 60
MAX_NAME = 40
MAX_LABEL_TEXT = 40
MAX_SIZE = 1000.0
MAX_SCALE = 100.0
MAX_PATH_CHARS = 2000
MAX_POINTS = 64
MAX_BLOCK_CHARS = 60_000    # characters of JSON in one block
MAX_BALLS = 16
MAX_SCATTER = 64
MAX_RPM = 120.0
MAX_SECTIONS = 24
LOFT_STEPS = 6              # rings between two loft sections
BLOB_BUDGET = 8000          # vertices of one blob at most (FigureBlob.swift coarsens its grid to fit)

KINDS = ("box", "cyl", "cone", "sphere", "torus", "capsule", "tube", "lathe", "extrude", "blob", "loft")
MATERIALS = ("steel", "aluminium", "chrome", "brass", "copper", "iron", "black", "rubber", "glass",
             "wood", "ceramic", "paper", "plastic", "matte")
COLOURS = ("red", "orange", "yellow", "green", "blue", "navy", "sky", "teal", "purple", "pink",
           "white", "grey", "gray", "black", "brown", "cream")
# Near names the model reaches for, read as the nearest colour above.
COLOUR_ALIASES = {"beige": "cream", "ivory": "cream", "tan": "brown", "silver": "grey", "gold": "yellow",
                  "maroon": "red", "crimson": "red", "lime": "green", "olive": "green", "cyan": "sky",
                  "turquoise": "teal", "magenta": "pink", "violet": "purple", "lavender": "purple",
                  "charcoal": "black"}
SIDES = ("left", "right", "top", "bottom")
AXES = {"x": (1.0, 0.0, 0.0), "y": (0.0, 1.0, 0.0), "z": (0.0, 0.0, 1.0),
        "-x": (-1.0, 0.0, 0.0), "-y": (0.0, -1.0, 0.0), "-z": (0.0, 0.0, -1.0)}

ROUND = 48          # segments around a round part (49 vertex columns: the seam is doubled)
ARC_STEPS = 4       # steps in a bevel arc

_FENCE = re.compile(r"(?m)^[ \t]*```[ \t]*([A-Za-z]*)[ \t]*\n(.*?)\n[ \t]*```[ \t]*$", re.S)
# ASCII only, so Swift reads the same tokens.
_PATH_TOKEN = re.compile(r"[ \t\r\n]*,?[ \t\r\n]*([MLHVCQZmlhvcqz]|-?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)")
_HEX = re.compile(r"#[0-9a-fA-F]{6}")


class _Invalid(Exception):
    """The whole block fails: left in the text."""


@dataclass
class Part:
    number: int                 # 1-based, in the order written
    name: str
    kind: str
    recipe: dict                # normalised shape keys (the mesh's cache key)
    mat: str
    at: tuple = (0.0, 0.0, 0.0)
    axis: tuple = (0.0, 1.0, 0.0)
    rot: tuple = (0.0, 0.0, 0.0)
    scale: tuple = (1.0, 1.0, 1.0)
    mirror: tuple = ()
    copies: dict | None = None
    around: dict | None = None
    parent: str | None = None
    scatter: dict | None = None     # copies at seeded random places and turns (organelles, rivets)
    spin: dict | None = None        # keeps turning once built (fans, wheels, rotors)
    cut_mark: bool = False      # the part said "cut": true or {...} itself
    instances: int = 1
    budget: int = 0

    @property
    def canonical(self) -> str:
        return canonical_json(dict(self.recipe, kind=self.kind))


@dataclass
class Figure:
    title: str
    parts: list[Part]
    labels: list[dict] = field(default_factory=list)
    view: dict = field(default_factory=lambda: {"turn": 30.0, "tilt": 20.0, "zoom": 1.0})
    cut: dict | None = None
    dropped: int = 0

    @property
    def vertices(self) -> int:
        return sum(p.budget * p.instances for p in self.parts)


# MARK: canonical numbers and JSON (the same bytes in Swift)

def canonical_number(x: float) -> str:
    """Rounded half away from zero to 4 decimals, without trailing zeros; -0 is 0."""
    n = math.floor(abs(x) * 10000 + 0.5)
    if n == 0:
        return "0"
    whole, frac = divmod(n, 10000)
    s = str(whole) + (("." + f"{frac:04d}".rstrip("0")) if frac else "")
    return "-" + s if x < 0 else s


def _string(s: str) -> str:
    out = ['"']
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def canonical_json(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return canonical_number(float(v))
    if isinstance(v, str):
        return _string(v)
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(canonical_json(x) for x in v) + "]"
    return "{" + ",".join(_string(k) + ":" + canonical_json(v[k]) for k in sorted(v)) + "}"


# MARK: finding the block

def parse_figure(text: str) -> tuple[str, Figure | None]:
    """The reply without its figure block (the words before and after it joined), and the figure;
    (text, None) when there is no block or it fails (then the text is returned unchanged)."""
    found = None
    for m in _FENCE.finditer(text):
        info = m.group(1).lower()
        # A block marked figure counts wherever it is; one marked json only at the very end.
        if info == "figure" or info == "json" and not parse_tags(text[m.end():])[0].strip():
            found = m
    if found is None:
        return text, None
    after = text[found.end():]
    figure = figure_from_json(found.group(2))
    if figure is None:
        return text, None
    before = text[:found.start()].rstrip()
    rest = after.strip()
    return (before + ("\n" + rest if rest else "")).strip(), figure


def figure_from_json(body: str) -> Figure | None:
    if len(body) > MAX_BLOCK_CHARS:
        return None
    try:
        obj = json.loads(body, parse_constant=_reject)
        _check_finite(obj)
        if not isinstance(obj, dict) or not isinstance(obj.get("parts"), list):
            raise _Invalid
        return _figure(obj)
    except (_Invalid, ValueError, RecursionError):
        return None


def _reject(_):
    raise _Invalid


def _check_finite(v) -> None:
    if isinstance(v, float) and not math.isfinite(v):
        raise _Invalid
    if isinstance(v, int) and not isinstance(v, bool) and abs(v) > 1e308:
        raise _Invalid
    if isinstance(v, list):
        for x in v:
            _check_finite(x)
    elif isinstance(v, dict):
        for x in v.values():
            _check_finite(x)


# MARK: values

def _num(v) -> float | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return float(v)


def _size(v) -> float | None:
    n = _num(v)
    return n if n is not None and 0 < n <= MAX_SIZE else None


def _coord(v) -> float | None:
    n = _num(v)
    return n if n is not None and abs(n) <= MAX_SIZE else None


def _vec3(v) -> tuple | None:
    if not isinstance(v, list) or len(v) != 3:
        return None
    xs = [_coord(x) for x in v]
    return None if any(x is None for x in xs) else tuple(xs)


def _direction(v) -> tuple | None:
    if isinstance(v, str):
        return AXES.get(v.strip().lower())
    vec = _vec3(v)
    if vec is None:
        return None
    length = math.sqrt(sum(x * x for x in vec))
    return None if length < 1e-9 else tuple(x / length for x in vec)


def _text(v, limit: int) -> str:
    if not isinstance(v, str):
        return ""
    return v.strip()[:limit].strip()


def _material(v) -> str:
    if not isinstance(v, str):
        return "matte"
    m = v.strip().lower()
    if m in MATERIALS:
        return m
    for prefix in ("paint:", "glow:"):
        if m.startswith(prefix):
            colour = m[len(prefix):].strip()
            colour = COLOUR_ALIASES.get(colour, colour)
            if colour in COLOURS or _HEX.fullmatch(colour):
                return prefix + colour
    return "matte"


# MARK: parts

def _figure(obj: dict) -> Figure:
    parts: list[Part] = []
    names: dict[str, Part] = {}
    dropped = 0
    total = 0
    for i, raw in enumerate(obj["parts"]):
        number = i + 1
        part = _part(raw, number, names) if i < MAX_PARTS else None
        if part is None:
            dropped += 1
            continue
        if total + part.budget * part.instances > MAX_VERTICES:
            dropped += 1
            continue
        total += part.budget * part.instances
        if part.name in names:
            part.name = f"{part.name} {number}"
        names[part.name] = part
        parts.append(part)
    if not parts:
        raise _Invalid
    figure = Figure(_text(obj.get("title"), MAX_TITLE), parts, dropped=dropped)
    figure.labels = _labels(obj.get("labels"), parts)
    figure.view = _view(obj.get("view"))
    figure.cut = _cut(obj.get("cut"), parts, figure.view)
    return figure


def _part(raw, number: int, earlier: dict[str, Part]) -> Part | None:
    if not isinstance(raw, dict):
        return None
    kind = raw.get("kind")
    kind = kind.strip().lower() if isinstance(kind, str) else ""
    if kind not in KINDS:
        return None
    at = (0.0, 0.0, 0.0)
    axis = (0.0, 1.0, 0.0)
    span = None
    if kind in ("cyl", "cone", "capsule") and "from" in raw and "to" in raw:
        a, b = _vec3(raw["from"]), _vec3(raw["to"])
        if a is None or b is None:
            return None
        d = tuple(b[k] - a[k] for k in range(3))
        span = math.sqrt(sum(x * x for x in d))
        if not 0 < span <= MAX_SIZE:
            return None
        at = tuple((a[k] + b[k]) / 2 for k in range(3))
        axis = tuple(x / span for x in d)
    else:
        if "at" in raw:
            at = _vec3(raw["at"])
            if at is None:
                return None
        if "axis" in raw:
            axis = _direction(raw["axis"]) or (0.0, 1.0, 0.0)
    recipe = _recipe(kind, raw, span)
    if recipe is None:
        return None
    name = _text(raw.get("name"), MAX_NAME) or f"part {number}"
    parent = raw.get("parent")
    parent_part = earlier.get(parent.strip()) if isinstance(parent, str) else None
    part = Part(number, name, kind, recipe, _material(raw.get("mat")), at=at, axis=axis,
                rot=_rot(raw.get("rot")), scale=_scale(raw.get("scale")), mirror=_mirror(raw.get("mirror")),
                copies=_copies(raw.get("copies")), around=_around(raw.get("around")),
                parent=parent_part.name if parent_part else None,
                scatter=_scatter(raw.get("scatter")), spin=_spin(raw.get("spin")),
                cut_mark=raw.get("cut") is True or isinstance(raw.get("cut"), dict))
    part.budget = budget(kind, recipe)
    part.instances = (2 ** len(part.mirror) * (part.copies["count"] if part.copies else 1)
                      * (part.around["count"] if part.around else 1)
                      * (part.scatter["count"] if part.scatter else 1)
                      * (parent_part.instances if parent_part else 1))
    return part


def _bevel(raw, smallest: float, default_share: float, cap: float) -> float:
    b = _num(raw.get("bevel"))
    if b is None or b < 0:
        b = smallest * default_share
    return min(b, cap)


def _recipe(kind: str, raw: dict, span: float | None) -> dict | None:
    if kind == "box":
        s = raw.get("size")
        size = (_size(s),) * 3 if _num(s) is not None else (tuple(_size(x) for x in s) if isinstance(s, list) and len(s) == 3 else None)
        if size is None or any(x is None for x in size):
            return None
        smallest = min(size)
        return {"size": list(size), "bevel": _bevel(raw, smallest, 0.06, smallest / 2)}
    if kind in ("cyl", "cone", "capsule", "sphere", "torus", "tube"):
        r = _size(raw.get("r"))
        if r is None:
            return None
    if kind in ("cyl", "cone", "capsule"):
        h = span if span is not None else _size(raw.get("h"))
        if h is None:
            return None
        if kind == "capsule":
            return {"r": r, "h": max(h, 2 * r)}
        smallest = min(2 * r, h)
        recipe = {"r": r, "h": h, "bevel": _bevel(raw, smallest, 0.06, min(r, h / 2))}
        if kind == "cone":
            r2 = _num(raw.get("r2"))
            recipe["r2"] = r2 if r2 is not None and 0 <= r2 <= MAX_SIZE else 0.0
        return recipe
    if kind == "sphere":
        return {"r": r}
    if kind == "torus":
        tube = _size(raw.get("tube"))
        if tube is None:
            tube = r / 4
        return {"r": r, "tube": tube} if tube < r else None
    if kind == "tube":
        path = raw.get("path")
        if not isinstance(path, list) or not 2 <= len(path) <= MAX_POINTS:
            return None
        points = [_vec3(p) for p in path]
        if any(p is None for p in points):
            return None
        recipe = {"r": r, "path": [list(p) for p in points]}
        # r2: the radius at the path's end, tapering from r (vessels, stems, horns, tails).
        r2 = _num(raw.get("r2"))
        if r2 is not None and 0 <= r2 <= MAX_SIZE and r2 != r:
            recipe["r2"] = r2
        return recipe
    if kind == "lathe":
        profile = raw.get("profile")
        if not isinstance(profile, list) or not 2 <= len(profile) <= MAX_POINTS:
            return None
        points = []
        for p in profile:
            if not isinstance(p, list) or len(p) != 2:
                return None
            r, y = _coord(p[0]), _coord(p[1])
            if r is None or y is None or r < 0:
                return None
            points.append([r, y])
        return {"profile": points}
    if kind == "blob":
        # Spheres that melt into one smooth body (cells, organs, bodies, rocks), meshed in Swift.
        balls = raw.get("balls")
        if not isinstance(balls, list) or not 1 <= len(balls) <= MAX_BALLS:
            return None
        out = []
        for b in balls:
            if not isinstance(b, list) or len(b) != 4:
                return None
            x, y, z, r = _coord(b[0]), _coord(b[1]), _coord(b[2]), _size(b[3])
            if None in (x, y, z, r):
                return None
            out.append([x, y, z, r])
        mean = sum(b[3] for b in out) / len(out)
        smooth = _num(raw.get("smooth"))
        smooth = smooth if smooth is not None and 0 <= smooth <= MAX_SIZE else 0.4 * mean
        wobble = _num(raw.get("wobble"))
        wobble = min(max(wobble if wobble is not None else 0.0, 0.0), 0.5)
        recipe = {"balls": out, "smooth": smooth, "wobble": wobble}
        if raw.get("chain") is True and len(out) > 1:
            recipe["chain"] = True      # the balls joined in order into one tapered limb
        return recipe
    if kind == "loft":
        # A smooth body through cross-sections along z (car bodies, hulls, fuselages, fish): each
        # [z, y, w, h] or [z, y, w, h, square], w and h half the width and height, square 0 (an
        # ellipse) to 1 (a rounded box). Meshed in Swift (FigureLoft.swift).
        sections = raw.get("sections")
        if not isinstance(sections, list) or not 2 <= len(sections) <= MAX_SECTIONS:
            return None
        out = []
        for q in sections:
            if not isinstance(q, list) or len(q) not in (4, 5):
                return None
            z, y, w, h = (_coord(v) for v in q[:4])
            if None in (z, y, w, h) or w < 0 or h < 0:
                return None
            square = 0.0
            if len(q) == 5:
                s = _num(q[4])
                if s is None:
                    return None
                square = min(max(s, 0.0), 1.0)
            out.append([z, y, w, h, square])
        # Written front to back or back to front, but always one way along z.
        rising = all(a[0] < b[0] for a, b in zip(out, out[1:]))
        falling = all(a[0] > b[0] for a, b in zip(out, out[1:]))
        if not (rising or falling) or not any(q[2] > 0 and q[3] > 0 for q in out):
            return None
        return {"sections": out if rising else out[::-1]}
    # extrude
    path = raw.get("path")
    if not isinstance(path, str) or len(path) > MAX_PATH_CHARS or path_points(path) is None:
        return None
    depth = _size(raw.get("depth"))
    depth = 0.2 if depth is None else depth
    return {"path": path.strip(" \t\r\n"), "depth": depth, "bevel": _bevel(raw, depth, 0.15, depth / 2)}


def _rot(v) -> tuple:
    n = _num(v)
    if n is not None:
        return (0.0, n, 0.0) if math.isfinite(n) and abs(n) <= 3600 else (0.0, 0.0, 0.0)
    if isinstance(v, list) and len(v) == 3:
        xs = [_num(x) for x in v]
        if all(x is not None and abs(x) <= 3600 for x in xs):
            return tuple(xs)
    return (0.0, 0.0, 0.0)


def _scale(v) -> tuple:
    n = _num(v)
    if n is not None:
        return (n,) * 3 if 0 < n <= MAX_SCALE else (1.0, 1.0, 1.0)
    if isinstance(v, list) and len(v) == 3:
        xs = [_num(x) for x in v]
        if all(x is not None and 0 < x <= MAX_SCALE for x in xs):
            return tuple(xs)
    return (1.0, 1.0, 1.0)


def _mirror(v) -> tuple:
    items = [v] if isinstance(v, str) else v if isinstance(v, list) else []
    out = []
    for a in ("x", "y", "z"):
        if any(isinstance(x, str) and x.strip().lower() == a for x in items):
            out.append(a)
    return tuple(out)


def _count(v, top: int) -> int | None:
    n = _num(v)
    if n is None or n != math.floor(n) or not 1 <= n <= top:
        return None
    return int(n)


def _copies(v) -> dict | None:
    if not isinstance(v, dict):
        return None
    count = _count(v.get("count"), 24)
    step = _vec3(v.get("step")) if "step" in v else (0.0, 0.0, 0.0)
    turn = _num(v.get("turn")) if "turn" in v else 0.0
    if count is None or step is None or turn is None or abs(turn) > 3600:
        return None
    return {"count": count, "step": step, "turn": turn}


def _around(v) -> dict | None:
    if not isinstance(v, dict):
        return None
    count = _count(v.get("count"), 64)
    axis = _direction(v["axis"]) if "axis" in v else (0.0, 1.0, 0.0)
    center = _vec3(v.get("center")) if "center" in v else (0.0, 0.0, 0.0)
    arc = _num(v.get("arc")) if "arc" in v else 360.0
    if count is None or axis is None or center is None or arc is None or not 0 < arc <= 360:
        return None
    return {"count": count, "axis": axis, "center": center, "arc": arc}


def _scatter(v) -> dict | None:
    """Copies at seeded random places inside an ellipsoid round the part, each turned at random."""
    if not isinstance(v, dict):
        return None
    count = _count(v.get("count"), MAX_SCATTER)
    if count is None:
        return None
    inside = (1.0, 1.0, 1.0)
    if "in" in v:
        r = v["in"]
        if _num(r) is not None:
            inside = (_size(r),) * 3
        elif isinstance(r, list) and len(r) == 3:
            inside = tuple(_size(x) for x in r)
        else:
            return None
        if any(x is None for x in inside):
            return None
    seed = 1
    if "seed" in v:
        s = _num(v["seed"])
        if s is None or s != math.floor(s) or not 0 <= s <= 1_000_000:
            return None
        seed = int(s)
    return {"count": count, "in": inside, "seed": seed}


def _spin(v) -> dict | None:
    """A turn that keeps going once the figure is built: rpm, or {rpm, axis, center}."""
    def rate(x):
        r = _num(x)
        return r if r is not None and r != 0 and abs(r) <= MAX_RPM else None
    if rate(v) is not None:
        return {"rpm": rate(v), "axis": None, "center": None}
    if not isinstance(v, dict) or rate(v.get("rpm")) is None:
        return None
    axis = _direction(v["axis"]) if "axis" in v else None
    center = _vec3(v["center"]) if "center" in v else None
    if ("axis" in v and axis is None) or ("center" in v and center is None):
        return None
    return {"rpm": rate(v.get("rpm")), "axis": axis, "center": center}


def _labels(v, parts: list[Part]) -> list[dict]:
    if not isinstance(v, list):
        return []
    by_name = {p.name: p for p in parts}
    by_number = {p.number: p for p in parts}
    out = []
    for raw in v:
        if len(out) == MAX_LABELS:
            break
        if not isinstance(raw, dict):
            continue
        ref = raw.get("part")
        n = _num(ref)
        part = by_name.get(ref.strip()) if isinstance(ref, str) else by_number.get(int(n)) if n is not None and n == math.floor(n) else None
        text = _text(raw.get("text"), MAX_LABEL_TEXT)
        if part is None or not text:
            continue
        side = raw.get("side")
        side = side.strip().lower() if isinstance(side, str) else ""
        out.append({"part": part.name, "text": text, "side": side if side in SIDES else ""})
    return out


def _clamp(v, lo: float, hi: float, default: float) -> float:
    n = _num(v)
    return default if n is None else min(max(n, lo), hi)


def _view(v) -> dict:
    v = v if isinstance(v, dict) else {}
    turn = _num(v.get("turn"))
    turn = 30.0 if turn is None else math.fmod(turn, 360.0)
    if turn > 180:
        turn -= 360
    elif turn < -180:
        turn += 360
    return {"turn": turn, "tilt": _clamp(v.get("tilt"), -80, 80, 20.0), "zoom": _clamp(v.get("zoom"), 0.5, 3, 1.0)}


def _toward_viewer(view: dict) -> tuple:
    """The level direction from the figure to the camera at its view."""
    t = view["turn"] * math.pi / 180
    return (math.sin(t), 0.0, math.cos(t))


def _cut(v, parts: list[Part], view: dict) -> dict | None:
    """The top-level cut, plus any part that asked to be cut itself; a part-level cut alone
    opens toward the viewer through the origin."""
    axis, at, listed = None, 0.0, None
    if isinstance(v, dict):
        # No axis (or "view"): cut away the half toward the viewer, so the inside faces the camera.
        raw = v.get("axis", "view")
        viewward = isinstance(raw, str) and raw.strip().lower() == "view"
        axis = _toward_viewer(view) if viewward else _direction(raw)
        at = _coord(v.get("at")) if "at" in v else 0.0
        listed = v.get("parts")
        if axis is None or at is None:
            axis, at, listed = None, 0.0, None
    marked = {p.name for p in parts if p.cut_mark}
    if axis is None:
        if not marked:
            return None
        axis, listed = _toward_viewer(view), []
    if isinstance(listed, list):
        chosen = [p.name for p in parts if p.name in marked
                  or any(isinstance(x, str) and x.strip() == p.name for x in listed)]
    else:
        chosen = [p.name for p in parts]
    return {"axis": axis, "at": at, "parts": chosen} if chosen else None


# MARK: extrude paths and vertex budgets

def path_points(path: str) -> int | None:
    """Outline points of an extrude path once flattened (M/L/H/V one each, C/Q eight each, a
    closing repeat of the subpath's first point not counted, subpaths under 3 points ignored);
    None when the path does not parse or has no outline."""
    tokens = []
    pos = 0
    s = path.strip(" \t\r\n")
    while pos < len(s):
        m = _PATH_TOKEN.match(s, pos)
        if m is None:
            return None
        tokens.append(m.group(1))
        pos = m.end()
    total = 0
    sub: list[tuple] = []
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    cmd = None
    i = 0

    def close():
        nonlocal sub, total
        n = sum(w for w, _ in sub)
        if len(sub) > 1 and sub[-1][1] == sub[0][1]:
            n -= 1
        if n >= 3:
            total += n
        sub = []

    def numbers(k):
        nonlocal i
        if i + k > len(tokens):
            return None
        try:
            vals = [float(t) for t in tokens[i:i + k]]
        except ValueError:
            return None
        i += k
        return vals

    while i < len(tokens):
        t = tokens[i]
        if t.isalpha():
            cmd = t
            i += 1
            if cmd in "Zz":
                close()
                cur = start
                continue
        elif cmd is None or cmd in "Zz":
            return None
        rel = cmd.islower()
        c = cmd.upper()
        arity = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "Q": 4}[c]
        vals = numbers(arity)
        if vals is None:
            return None
        ox, oy = cur if rel else (0.0, 0.0)
        if c == "H":
            cur = (vals[0] + (cur[0] if rel else 0.0), cur[1])
        elif c == "V":
            cur = (cur[0], vals[0] + (cur[1] if rel else 0.0))
        else:
            cur = (vals[-2] + ox, vals[-1] + oy)
        if any(abs(x) > MAX_SIZE for x in vals) or abs(cur[0]) > MAX_SIZE or abs(cur[1]) > MAX_SIZE:
            return None
        if c == "M":
            if sub:
                close()
            start = cur
            sub = [(1, cur)]
            cmd = "l" if rel else "L"
        else:
            sub.append((8 if c in "CQ" else 1, cur))
    close()
    return total if total >= 3 else None


def budget(kind: str, recipe: dict) -> int:
    """Vertices of one instance of a part's mesh: fixed by its recipe, an upper bound on what the
    mesh generators build (FigureMesh.swift, checked in FigureMeshTests)."""
    cols = ROUND + 1
    arc = ARC_STEPS + 1
    if kind == "box":
        return 600 if recipe["bevel"] > 0 else 24
    if kind == "cyl":
        return cols * 2 * ((2 + 2 * arc) if recipe["bevel"] > 0 else 4)
    if kind == "cone":
        tip = 1 if recipe["r2"] > 0 else 0
        return cols * 2 * ((2 + arc + tip) if recipe["bevel"] > 0 else (3 + tip))
    if kind in ("sphere", "torus"):
        return cols * 25
    if kind == "capsule":
        return cols * 26
    if kind == "tube":
        return 17 * ((len(recipe["path"]) - 1) * 4 + 1) + 36
    if kind == "lathe":
        return cols * 2 * len(recipe["profile"])
    if kind == "blob":
        return BLOB_BUDGET
    if kind == "loft":
        return ((len(recipe["sections"]) - 1) * LOFT_STEPS + 1) * cols + 2 * (cols + 1)
    m = path_points(recipe["path"]) or 0
    return 2 * m + 4 * m * (3 if recipe["bevel"] > 0 else 1)


# MARK: the summary both parsers agree on

def _part_summary(p: Part) -> dict:
    out = {"n": p.number, "name": p.name, "kind": p.kind, "mat": p.mat, "recipe": p.canonical,
           "at": list(p.at), "axis": list(p.axis), "rot": list(p.rot), "scale": list(p.scale),
           "mirror": list(p.mirror), "instances": p.instances, "budget": p.budget,
           "parent": p.parent,
           "copies": None if p.copies is None else dict(p.copies, step=list(p.copies["step"])),
           "around": None if p.around is None else dict(p.around, axis=list(p.around["axis"]),
                                                          center=list(p.around["center"]))}
    # Only when used, so summaries of figures without them are unchanged.
    if p.scatter is not None:
        out["scatter"] = dict(p.scatter, **{"in": list(p.scatter["in"])})
    if p.spin is not None:
        out["spin"] = {"rpm": p.spin["rpm"],
                       "axis": None if p.spin["axis"] is None else list(p.spin["axis"]),
                       "center": None if p.spin["center"] is None else list(p.spin["center"])}
    return out


def summary(text: str) -> str:
    """The canonical summary of a reply's figure, compared byte for byte with Swift's."""
    rest, fig = parse_figure(text)
    if fig is None:
        return canonical_json({"ok": False, "text": rest})
    return canonical_json({
        "ok": True, "text": rest, "title": fig.title, "dropped": fig.dropped, "vertices": fig.vertices,
        "parts": [_part_summary(p) for p in fig.parts],
        "labels": fig.labels, "view": fig.view,
        "cut": None if fig.cut is None else dict(fig.cut, axis=list(fig.cut["axis"])),
    })
