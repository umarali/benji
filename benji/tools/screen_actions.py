"""Acting on the screen: the steps the app carries out (click, type, scroll, keys) and how each one is decided."""

from __future__ import annotations

import math
from typing import Callable

from .. import drive as drive_mod
from .. import screen_class
from .automation import _brief
from .context import Ctx, ToolCancelled
from .drive_mode import end_drive


# Click, scroll, type and press keys in the app the user is looking at. The engine never
# touches the screen itself (no System Events, no cliclick): each step goes to the macOS app
# over `benji --serve` (Ctx.screen), which acts through Accessibility or synthetic input, checks
# its own refusals, and answers with a fresh screenshot. Only a turn with a screenshot is offered
# these tools. A step is free, quiet or asked (benji/screen_class.py): an asked step needs
# the user's OK, even with --yes; free and quiet ones go to the app unasked, with their class, and
# the app looks again at the point and answers "ask" when what is there must be asked about. The
# step's wire form is what companion/Sources/BenjiCore/Screen/ScreenAction.swift decodes.

SCREEN_TOOL_NAMES = ("click", "scroll", "type_text", "press_key", "drag")
MAX_TYPED_CHARS = 500
MAX_SCROLL = 10
SCROLL_DIRECTIONS = ("up", "down", "left", "right")
MODIFIERS = ("cmd", "shift", "option", "control")
_MODIFIER_ALIASES = {"command": "cmd", "⌘": "cmd", "meta": "cmd", "alt": "option", "opt": "option",
                     "⌥": "option", "ctrl": "control", "⌃": "control", "⇧": "shift"}
KEYS = frozenset(
    ["return", "enter", "tab", "space", "delete", "forward_delete", "escape", "up", "down", "left",
     "right", "home", "end", "page_up", "page_down", "minus", "equal", "comma", "period", "slash",
     "semicolon", "quote", "left_bracket", "right_bracket", "backslash", "grave"]
    + [chr(c) for c in range(ord("a"), ord("z") + 1)] + [str(d) for d in range(10)]
    + [f"f{n}" for n in range(1, 13)])
_KEY_ALIASES = {"backspace": "delete", "esc": "escape", "pageup": "page_up", "pagedown": "page_down",
                "forwarddelete": "forward_delete", "del": "forward_delete", "arrow_up": "up",
                "arrow_down": "down", "arrow_left": "left", "arrow_right": "right", "spacebar": "space",
                "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash", ";": "semicolon",
                "'": "quote", "[": "left_bracket", "]": "right_bracket", "\\": "backslash", "`": "grave"}
_KEY_SHOWN = {"cmd": "⌘", "shift": "⇧", "option": "⌥", "control": "⌃"}


def _whole(v) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and math.isfinite(v):
        return math.floor(v + 0.5)
    return None


def _point(inp: dict, size: tuple[int, int] | None) -> tuple[tuple[int, int] | None, str]:
    x, y = _whole(inp.get("x")), _whole(inp.get("y"))
    if x is None or y is None:
        return None, "x and y must be whole-number pixels in the screenshot"
    if x < 0 or y < 0 or (size is not None and (x > size[0] or y > size[1])):
        where = f" ({size[0]}x{size[1]})" if size else ""
        return None, f"{x},{y} is outside the screenshot{where}"
    return (x, y), ""


def _key_name(raw) -> str | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    k = raw.strip().lower()
    if len(k) > 1:
        k = k.replace(" ", "_").replace("-", "_")
    k = _KEY_ALIASES.get(k, k)
    return k if k in KEYS else None


def screen_step(name: str, inp: dict, size: tuple[int, int] | None = None) -> tuple[dict | None, str]:
    """The step a screen tool's arguments describe, as sent to the app, or (None, why not). The
    model's `intent` and `confidence` ride along when it gave them (older apps ignore them)."""
    if not isinstance(inp, dict):
        return None, "arguments must be an object"
    step, why = _screen_step(name, inp, size)
    if step is not None:
        intent = inp.get("intent")
        if isinstance(intent, str) and intent.strip():
            step["intent"] = _brief(" ".join(intent.split()), 100)
        if inp.get("confidence") in screen_class.CONFIDENCES:
            step["confidence"] = inp["confidence"]
    return step, why


def _screen_step(name: str, inp: dict, size: tuple[int, int] | None) -> tuple[dict | None, str]:
    if name == "click":
        at, why = _point(inp, size)
        if at is None:
            return None, why
        label = inp.get("label")
        if not isinstance(label, str) or not label.strip():
            return None, "say what you are clicking in label (e.g. \"Save button\")"
        button = inp.get("button", "left")
        if button not in ("left", "right"):
            return None, "button is left or right"
        return {"kind": "click", "x": at[0], "y": at[1], "button": button,
                "count": 2 if inp.get("double") is True else 1, "label": _brief(label, 80)}, ""
    if name == "scroll":
        at, why = _point(inp, size)
        if at is None:
            return None, why
        direction = inp.get("direction")
        if direction not in SCROLL_DIRECTIONS:
            return None, "direction is up, down, left or right"
        amount = _whole(inp.get("amount", 3))
        if amount is None or not 1 <= amount <= MAX_SCROLL:
            return None, f"amount is a whole number from 1 to {MAX_SCROLL}"
        label = inp.get("label")
        label = _brief(label, 80) if isinstance(label, str) and label.strip() else ""
        return {"kind": "scroll", "x": at[0], "y": at[1], "direction": direction, "amount": amount,
                "label": label}, ""
    if name == "type_text":
        text = inp.get("text")
        if not isinstance(text, str) or not text:
            return None, "text is the words to type"
        if len(text) > MAX_TYPED_CHARS:
            return None, f"type at most {MAX_TYPED_CHARS} characters in one step"
        if any(ord(c) < 32 or ord(c) == 127 for c in text):
            return None, "text can't hold a newline, tab or other control character: press Return or Tab with press_key as its own step"
        return {"kind": "type_text", "text": text}, ""
    if name == "press_key":
        key = _key_name(inp.get("key"))
        if key is None:
            return None, "unknown key; use a letter, digit, return, tab, space, delete, escape, an arrow, home, end, page_up, page_down or f1-f12"
        raw = inp.get("modifiers", [])
        if not isinstance(raw, list):
            return None, "modifiers is a list such as [\"cmd\", \"shift\"]"
        mods: list[str] = []
        for m in raw:
            m = m.strip().lower() if isinstance(m, str) else None
            m = _MODIFIER_ALIASES.get(m, m)
            if m not in MODIFIERS:
                return None, "modifiers are cmd, shift, option and control"
            if m not in mods:
                mods.append(m)
        mods.sort(key=MODIFIERS.index)
        return {"kind": "press_key", "key": key, "modifiers": mods}, ""
    if name == "drag":
        at, why = _point(inp, size)
        if at is None:
            return None, why
        to, why = _point({"x": inp.get("to_x"), "y": inp.get("to_y")}, size)
        if to is None:
            return None, why.replace("x and y", "to_x and to_y")
        if at == to:
            return None, "a drag needs two different points; to press in one place, use click"
        label = inp.get("label")
        if not isinstance(label, str) or not label.strip():
            return None, "say what moves and where to in label (e.g. \"report.pdf to the Trash\")"
        return {"kind": "drag", "x": at[0], "y": at[1], "to_x": to[0], "to_y": to[1], "label": _brief(label, 80)}, ""
    return None, f"not a screen action: {name}"


def key_may_commit(step: dict) -> bool:
    """A key that can send, submit, delete, close or quit something: the card says so. Mirrors
    ScreenStep.mayCommit in ScreenAction.swift."""
    if step.get("kind") != "press_key":
        return False
    key, mods = step.get("key"), set(step.get("modifiers", []))
    if key in ("return", "enter"):
        return True
    if "cmd" in mods and key in ("delete", "forward_delete", "q", "w", "s", "z", "x", "v"):
        return True
    return key in ("delete", "forward_delete") and bool(mods)


def drive_live(ctx: Ctx) -> bool:
    """A drive is on for this turn and nothing has ended it (no outside content read since)."""
    d = ctx.drive
    return d is not None and d.live(ctx.taints) and not ctx.screen_stopped


def drive_plan(ctx: Ctx, step: dict) -> tuple[str, str, str]:
    """(class, why, audit code) of a step inside a drive (benji/drive.py plan_class), after the
    drive's own limits. The consent covers scrolling, clicking, typing, keys and moving sliders; the class carves out
    what is asked each time or refused."""
    d = ctx.drive
    if d.steps >= drive_mod.MAX_STEPS:
        return drive_mod.DENIED, "this drive has reached its step limit", "drive_limit"
    cls, why = drive_mod.plan_class(step)
    code = {drive_mod.FREE: "drive_free", drive_mod.QUIET: "drive_quiet", drive_mod.ASKED: "drive_asked"}.get(cls, "drive_secret")
    return cls, why, code


def screen_plan(ctx: Ctx, step: dict) -> tuple[str, str]:
    """The step's class before anything is asked or done (screen_class.plan_class), and why it
    is asked. Without simple steps every step is asked. Inside a drive: drive_plan."""
    if drive_live(ctx):
        cls, why, _ = drive_plan(ctx, step)
        return cls, why
    asked_for_text = step["kind"] == "type_text" and screen_class.asks_for_text(ctx.user_text, step["text"])
    return screen_class.plan_class(step, ask_every_step=not ctx.screen_simple or screen_class.ask_forced(),
                                   asked_for_text=asked_for_text, unasked_so_far=ctx.screen_unasked)


def screen_reason(step: dict) -> str:
    """The approval reason for a step ("action: target"); the app words its own card from the
    step and names the app, and falls back to this."""
    intent = f" · {step['intent']}" if step.get("intent") else ""
    return _screen_reason(step) + intent


def _screen_reason(step: dict) -> str:
    kind = step["kind"]
    if kind == "click":
        verb = {(1, "left"): "click", (2, "left"): "double-click",
                (1, "right"): "right-click", (2, "right"): "right-click twice"}[(step["count"], step["button"])]
        return f"{verb} on the screen: {step['label']} at {step['x']},{step['y']}"
    if kind == "scroll":
        what = step["label"] or "the area"
        return f"scroll {step['direction']} on the screen: {what} at {step['x']},{step['y']}, {step['amount']} of {MAX_SCROLL}"
    if kind == "drag":
        return (f"drag on the screen: {step['label']} from {step['x']},{step['y']} to {step['to_x']},{step['to_y']} "
                "(this may move or delete something)")
    if kind == "type_text":
        return f"type into the focused field: “{_brief(step['text'], 120)}”"
    keys = "".join(_KEY_SHOWN[m] for m in step["modifiers"]) + step["key"].replace("_", " ").title()
    warn = " (this may send, submit, delete or close something)" if key_may_commit(step) else ""
    return f"press a key in the app in front: {keys}{warn}"


def _screen_tool(kind: str) -> Callable[..., str]:
    def handler(ctx: Ctx, **inp) -> str:
        if ctx.screen is None:
            return ("[error] Acting on the screen needs Benji's panel with the screen attached "
                    "(Screen set to Ask or On).")
        if ctx.screen_stopped:
            return ("[stopped] The user took over the screen during this turn. Don't act on the "
                    "screen again in this turn; say what is left to do.")
        step, why = screen_step(kind, inp, ctx.screen_size)
        if step is None:
            return f"[error] {why}"
        with ctx.lock:
            if ctx.stopped:
                raise ToolCancelled
        d = ctx.drive
        if d is not None and d.active and not drive_live(ctx) and not ctx.screen_stopped:
            end_drive(ctx, "tainted")           # outside content came in: the drive is over
        if d is not None and d.over_time():
            end_drive(ctx, "time")
        in_drive = drive_live(ctx)
        if in_drive:
            cls, drive_why, _ = drive_plan(ctx, step)
            if cls == drive_mod.DENIED:
                ctx.denied_code = "drive_limit" if d.steps >= drive_mod.MAX_STEPS else "drive_secret"
                if ctx.denied_code == "drive_limit":
                    end_drive(ctx, "limit")
                return f"[refused] {drive_why[:1].upper()}{drive_why[1:]}. Don't try this step again."
        else:
            cls, _ = screen_plan(ctx, step)
        send = (lambda *a: ctx.screen(*a, drive=True)) if in_drive else ctx.screen
        if cls == screen_class.ASKED:           # the agent asked first: this is the approved step
            result = (send(step, None) if in_drive else ctx.screen(step)) or {}
        else:
            result = send(step, cls) or {}
            if result.get("status") != "ask":   # one more unasked step this turn (at most 5; a drive has its own count)
                ctx.screen_unasked += 1
            if result.get("status") == "ask":   # the app looked and found it must be asked
                ctx.escalated = True
                why = str(result.get("text") or "").strip()
                ask = ctx.screen_approve
                if ask is None or not ask(screen_reason(step) + (f" (asked: {why})" if why else "")):
                    return "[declined] The user did not approve this step. Do not retry it; adapt."
                with ctx.lock:
                    if ctx.stopped:
                        raise ToolCancelled
                result = (send(step, None) if in_drive else ctx.screen(step)) or {}
        if in_drive and result.get("status") not in ("ask", "cancelled"):
            d.steps += 1
        status, text = result.get("status"), str(result.get("text") or "").strip()
        if status == "done":
            image = result.get("image")
            if image:
                ctx.images.append(image)
                return (f"[done] {text or 'Done.'} The screen as it is now is attached: use it, not "
                        "the earlier screenshot, for any next step.")
            return f"[done] {text or 'Done.'} (No new screenshot came back: look before another step.)"
        if status == "stopped":
            ctx.screen_stopped = True
            if in_drive:
                end_drive(ctx, "user_stop")
            return ("[stopped] Stopped: the user took over (moved the mouse, clicked, typed or pressed "
                    "Esc). Don't act on the screen again in this turn.")
        if status == "refused":
            return f"[refused] {text or 'Benji refused this step.'} Don't try this step again."
        if status == "cancelled":
            return "[cancelled] the turn was cancelled before this step ran"
        if status == "ask":                     # only an unasked step may be answered "ask"
            return "[error] Benji's app wanted to ask about an approved step; nothing was done."
        return f"[error] {text or 'the step failed'}"
    return handler
