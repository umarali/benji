"""Which screen steps Benji does without a card.

Every screen step (benji/tools/screen_actions.py: click, scroll, type_text, press_key, drag) is one of three classes:

  free    done at once, after the usual 0.6 s ring: a scroll, a plain navigation key
  quiet   done after a visible 1.2 s beat ("Clicking Settings · Esc stops") that any input of
          the user's stops: a click on a named tab, link, menu item, disclosure, checkbox,
          radio or pop-up whose title matches what the model named; typing the user asked for
          into a text field; a letter, digit or shortcut that isn't in the commit list, with no
          dialog up and no button holding the keyboard; at most 5 unasked steps a turn
  asked   the approval card: anything that may send, buy, delete, close or agree; every drag;
          Space; a click on a plain button, with nothing readable under it or in a dialog; another
          app than the screenshot's; a step the model isn't sure of; every step when the user chose
          "Ask before every step"

It is decided in two stages, both in code, never by the model alone:

  plan_class   the engine, before anything is asked or done: the step, the model's stated
               confidence, the setting, and whether the user's message asked for text
  final_class  the app, at the point, after looking with Accessibility: what is really there
               (role, title, a sheet or dialog above it) and whether it is the screenshot's app.
               It never lowers the planned class.

companion/Sources/BenjiCore/Screen/ScreenStepClass.swift mirrors this case for case; both run the
shared cases in companion/Tests/screen-class-cases.json.
"""

from __future__ import annotations

import re

from .switches import switch

FREE, QUIET, ASKED = "free", "quiet", "asked"
CONFIDENCES = ("high", "medium", "low")
_ORDER = {FREE: 0, QUIET: 1, ASKED: 2}

# Words on a click's target (the model's label, or the element's title and description) that
# mean the click may commit something. A word matches with the endings below ("Sending",
# "Deleted", "Closes"); phrases match as consecutive words.
COMMIT_WORDS = (
    "send", "submit", "post", "publish", "buy", "purchase", "pay", "checkout", "check out",
    "place order", "order now", "confirm", "delete", "remove", "trash", "discard", "erase",
    "sign out", "log out", "close", "quit", "accept", "agree", "allow", "install", "update",
    "upgrade", "unsubscribe", "transfer",
)
_ENDINGS = ("", "e", "s", "es", "d", "ed", "ing", "ment")

# A click is quiet only on one of these, and never on a window's close, minimise or zoom button:
# a tab, menu item, disclosure, link, checkbox, radio or pop-up. A plain button is asked, whatever
# its title: a page can call Pay "Read more". A text
# field is here too: clicking one only puts the caret in it, the step before typing.
QUIET_ROLES = frozenset({
    "AXLink", "AXDisclosureTriangle", "AXMenuItem", "AXMenuBarItem", "AXCheckBox",
    "AXRadioButton", "AXPopUpButton", "AXTab",
})
# Roles that press when they have the keyboard: any key then is asked.
BUTTON_ROLES = frozenset({"AXButton", "AXMenuButton", "AXPopUpButton"})
# At most this many free or quiet steps in one turn; the next is asked.
MAX_UNASKED_STEPS = 5
WINDOW_BUTTON_SUBROLES = frozenset({"AXCloseButton", "AXMinimizeButton", "AXZoomButton",
                                    "AXFullScreenButton"})
TEXT_ROLES = frozenset({"AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"})
QUIET_CLICK_ROLES = QUIET_ROLES | TEXT_ROLES
# Why a drag is asked (outside a drive always; inside one, unless benji/drive.py finds a real slider or
# divider): it can move a file, or delete one by dropping it on the Trash.
DRAG_WHY = "a drag can move or delete something"
# Plain navigation keys: free when pressed without modifiers.
NAV_KEYS = frozenset({"up", "down", "left", "right", "page_up", "page_down", "home", "end", "tab"})
# Words of a label that say what kind of thing it is, not which one ("Save button").
_KIND_WORDS = frozenset({
    "a", "an", "the", "button", "link", "tab", "menu", "item", "icon", "checkbox", "check", "box",
    "radio", "toggle", "switch", "option", "field", "label", "on", "in", "of", "to", "for", "at",
    "this", "that", "pop", "up", "popup",
})
# Verbs in the user's own message that ask for text to be entered.
_ENTRY_WORDS = frozenset({"type", "write", "enter", "fill", "input", "search", "put", "rename",
                          "paste", "spell", "address"})


def ask_forced() -> bool:
    """BENJI_SCREEN_ASK=1: the engine asks before every step, whatever the app says."""
    return switch("BENJI_SCREEN_ASK", False)


def _words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", (text or "").casefold())


def _matches(word: str, base: str) -> bool:
    stem = base[:-1] if base.endswith("e") else base
    return word == base or (word.startswith(stem) and word[len(stem):] in _ENDINGS)


def commit_word(text: str) -> str | None:
    """The first commit word or phrase in `text`, or None."""
    words = _words(text)
    for entry in COMMIT_WORDS:
        parts = entry.split()
        for i in range(len(words) - len(parts) + 1):
            if all(_matches(words[i + j], p) if j == len(parts) - 1 else words[i + j] == p
                   for j, p in enumerate(parts)):
                return entry
    return None


def names_match(label: str, names: str) -> bool:
    """The model's label and what Accessibility calls the element share a word that names it
    (case-folded; kind words such as "button" or "second" don't count)."""
    wanted = {w for w in _words(label) if w not in _KIND_WORDS}
    return bool(wanted & set(_words(names)))


def asks_for_text(user_text: str, typed: str) -> bool:
    """The user's message asked for text to be entered: it says to type, write, enter, fill or
    search, or it holds the very words being typed."""
    said = " ".join(_words(user_text))
    if any(w in _ENTRY_WORDS for w in said.split()):
        return True
    typed_words = " ".join(_words(typed))
    return bool(typed_words) and f" {typed_words} " in f" {said} "


def stricter(a: str, b: str) -> str:
    return a if _ORDER[a] >= _ORDER[b] else b


def plan_class(step: dict, ask_every_step: bool = False, asked_for_text: bool = False,
               unasked_so_far: int = 0) -> tuple[str, str]:
    """The engine's class for a step (benji/tools/screen_actions.py's wire form with `confidence`), and why
    it is asked when it is. A click planned quiet is quiet only if the app confirms it.
    `unasked_so_far`: free and quiet steps already done this turn; the sixth is asked."""
    if ask_every_step:
        return ASKED, "you chose to be asked before every step"
    if step.get("confidence") != "high":
        return ASKED, "Benji isn't sure this is what you want"
    if unasked_so_far >= MAX_UNASKED_STEPS:
        return ASKED, f"Benji has taken {MAX_UNASKED_STEPS} steps without asking this turn"
    kind = step.get("kind")
    if kind == "scroll":
        return FREE, ""
    if kind == "drag":
        return ASKED, DRAG_WHY
    if kind == "press_key":
        key, mods = step.get("key"), list(step.get("modifiers") or [])
        if key in ("return", "enter"):
            return ASKED, "Return can send or submit"
        if key == "escape":
            return ASKED, "Escape can close a dialog of yours"
        if key == "space":
            return ASKED, "Space can press a button"
        if key in ("delete", "forward_delete"):
            return ASKED, "Delete can remove something"
        if "cmd" in mods and key in ("q", "w", "s", "z", "x", "v"):
            return ASKED, "this shortcut can quit, close, save or change something"
        if "control" in mods:
            return ASKED, "a Control shortcut can stop a program"
        if key in NAV_KEYS and not mods:
            return FREE, ""
        return QUIET, ""
    if kind == "type_text":
        return (QUIET, "") if asked_for_text else (ASKED, "your message didn't ask for this text")
    if kind == "click":
        word = commit_word(step.get("label", ""))
        if word:
            return ASKED, f"“{word}” may commit something"
        return QUIET, ""
    return ASKED, "Benji doesn't know this kind of step"


def final_class(step: dict, planned: str, element: dict | None = None, same_app: bool = True) -> tuple[str, str]:
    """The app's class at the point: `element` is what Accessibility found there (a click: under
    the point; typing: the field with the keyboard), as {role, subrole, title, description,
    in_sheet, in_web_area}, or None when nothing was found. Never lower than `planned`. Without
    `in_web_area` (an older app) the element may be in a web page."""
    if planned == ASKED:
        return ASKED, ""
    if not same_app:
        return ASKED, "it's in another app than the one Benji looked at"
    kind = step.get("kind")
    if kind == "drag":
        return ASKED, DRAG_WHY
    if kind == "click":
        if element is None:
            return ASKED, "Benji can't tell what is under the point"
        if element.get("in_sheet"):
            return ASKED, "it's in a dialog"
        if element.get("role") == "AXButton" and element.get("in_web_area", True):
            return ASKED, "it's a button in a web page, and a page can name its buttons anything"
        if element.get("role") not in QUIET_CLICK_ROLES or element.get("subrole") in WINDOW_BUTTON_SUBROLES:
            return ASKED, "only tabs, links, menu items, checkboxes and fields are clicked without asking"
        names = f"{element.get('title') or ''} {element.get('description') or ''}"
        word = commit_word(names)
        if word:
            return ASKED, f"“{word}” may commit something"
        if not names_match(step.get("label", ""), names):
            return ASKED, "what is there doesn't match what Benji named"
        return planned, ""
    if kind == "type_text":
        if element is None or (element.get("role") not in TEXT_ROLES and element.get("subrole") not in TEXT_ROLES):
            return ASKED, "no text field has the keyboard"
        return planned, ""
    if kind == "press_key" and element is not None:     # what has the keyboard
        if element.get("in_sheet"):
            return ASKED, "a dialog is open, and a key can answer it"
        if element.get("role") in BUTTON_ROLES:
            return ASKED, "a button has the keyboard, and a key can press it"
    return planned, ""
