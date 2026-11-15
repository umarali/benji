"""What Benji has on the user's screen at the moment: the app sends it as `canvas` in
each `send` over --serve, and the turn's rules list it for the model, so the model knows the
drawing is its own even though Benji's windows can be left out of its screenshots.

    {"parts": [{"id": "p1", "kind": "line", "label": "leg a", "box": [x1, y1, x2, y2]}, ...],
     "board": [x1, y1, x2, y2],                         # the drawing sits on Benji's board
     "figure": {"title": "An airliner", "parts": ["fuselage", ...], "labels": ["Cockpit", ...]},
     "card": {"title": "Sending a letter", "items": ["Post box", ...]}}

Boxes are pixels in this turn's screenshot (0,0 top-left), mapped by the app from where the parts
are at the time of the turn; a part with no `box` is up on another display. Anything malformed is left out; an empty
canvas is None, and the prompt then says nothing about a drawing.
"""

from __future__ import annotations

from dataclasses import dataclass

MAX_PARTS = 40
MAX_LABEL = 80
MAX_NAMES = 24


@dataclass(frozen=True)
class Part:
    id: str
    kind: str
    label: str
    box: tuple[int, int, int, int] | None


@dataclass(frozen=True)
class Canvas:
    parts: tuple[Part, ...] = ()
    board: tuple[int, int, int, int] | None = None
    figure_title: str = ""
    figure_parts: tuple[str, ...] = ()
    figure_labels: tuple[str, ...] = ()
    card_title: str = ""
    card_items: tuple[str, ...] = ()

    @property
    def has_figure(self) -> bool:
        return bool(self.figure_title or self.figure_parts)

    @property
    def has_card(self) -> bool:
        return bool(self.card_title or self.card_items)


def _text(v, limit: int = MAX_LABEL) -> str:
    return " ".join(v.split())[:limit] if isinstance(v, str) else ""


def _box(v) -> tuple[int, int, int, int] | None:
    if (isinstance(v, list) and len(v) == 4 and all(isinstance(n, int) and not isinstance(n, bool) for n in v)
            and v[0] <= v[2] and v[1] <= v[3]):
        return tuple(v)
    return None


def _names(v) -> tuple[str, ...]:
    if not isinstance(v, list):
        return ()
    return tuple(t for t in (_text(n, 40) for n in v[:MAX_NAMES]) if t)


def canvas_info(obj) -> Canvas | None:
    if not isinstance(obj, dict):
        return None
    parts = []
    for p in obj.get("parts") or []:
        if not isinstance(p, dict):
            continue
        pid, kind = _text(p.get("id"), 8), _text(p.get("kind"), 16).lower()
        if not pid or not kind:
            continue
        parts.append(Part(pid, kind, _text(p.get("label")), _box(p.get("box"))))
    figure = obj.get("figure") if isinstance(obj.get("figure"), dict) else {}
    card = obj.get("card") if isinstance(obj.get("card"), dict) else {}
    canvas = Canvas(parts=tuple(parts[:MAX_PARTS]), board=_box(obj.get("board")) if parts else None,
                    figure_title=_text(figure.get("title"), 60), figure_parts=_names(figure.get("parts")),
                    figure_labels=_names(figure.get("labels")),
                    card_title=_text(card.get("title"), 60), card_items=_names(card.get("items")))
    return canvas if canvas.parts or canvas.has_figure or canvas.has_card else None
