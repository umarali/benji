"""Drive mode: the user lets Benji take over the screen for one stated goal.

A drive is not a mode the model can switch on. It is a consent the user gives on a card, for one
goal, inside one foreground turn they started, and it ends with that turn, with `end_drive`, with
the user's own input, or when a rule below ends it. Everything that decides what a drive may do
is here, as plain functions and one small state object, so every rule is tested without a model:

  who may drive      only a foreground turn the user started, with a screenshot the app can act
                     on and "Act on simple steps" on (never a background job; never a turn that
                     has read a web page, the browser or a file outside the working folder: the
                     screen alone is allowed). Checked when the tool is offered AND on every
                     call, because a turn can pick up outside content half-way, and the drive
                     then ends ("tainted").
  the consent        ONE card per drive, naming the goal, granted only by the app's own button or
                     key (the answer must say `via: card`; a spoken yes never grants), and
                     declined by itself after 45 s. `start_drive` without an `offer_drive` raises
                     the same card instead of failing. No "always approve": the consent is for
                     this goal and is gone when the drive ends.
  what a drive does  scrolling and pointing are free; clicks, typing and keys are quiet (done after
                     the usual visible beat, stopped by any input of the user's) EXCEPT what looks
                     destructive or outbound, which is asked on a card each time, and what must
                     never happen at all, which is refused. `plan_class` is the engine's class
                     from the step alone; `final_class` is the app's, after it looked with
                     Accessibility, and can only raise it. companion/Sources/BenjiCore/
                     DriveClass.swift mirrors both case for case (companion/Tests/drive-cases.json).
  what widens it     nothing. The class is decided from the step, the Accessibility element and the
                     consent, never from text the model read on the screen: screen text can claim
                     any permission, and none of it reaches a function here as an input.
"""

from __future__ import annotations

import re
import time
import unicodedata
from dataclasses import dataclass, field
from typing import Callable

from . import screen_class

FREE, QUIET, ASKED, DENIED = "free", "quiet", "asked", "denied"

CARD_SECONDS = 45.0         # the consent card declines itself after this long
OFFER_VALID_SECONDS = 120.0 # an agreed offer that is never started lapses
MAX_STEPS = 60              # screen steps in one drive
MAX_SECONDS = 600.0         # one drive's wall-clock length
MAX_GOAL_CHARS = 140
# A drive needs more model steps than a spoken turn's 20 (agent.MAX_STEPS); each screen step is one.
TURN_STEPS = 90
TURN_TOOL_CALLS = 100        # and the turn's cap on tool calls (agent.MAX_TOOL_CALLS is 30)

# Kinds of outside content that end a drive (or stop one starting). The screen alone does not.
HOSTILE_TAINTS = frozenset({"web", "browser", "file"})

# ---- why a drive ended --------------------------------------------------------------------------

END_REASONS = ("finished", "user_stop", "mouse", "typing", "click", "scroll", "limit", "time", "tainted",
               "turn_over", "app_stop", "error")

# What the user is told when code ended the drive (the model's own words, when it ended it, replace
# these). `spoken` is for the speaker, `written` for the notch and the panel.
END_LINES = {
    "user_stop": ("I've stopped and left the screen to you.", "Stopped: you took over."),
    "typing": ("You started typing, so I've stopped and left the screen to you.", "Stopped: you started typing."),
    "click": ("You used the mouse, so I've stopped and left the screen to you.", "Stopped: you used the mouse."),
    "scroll": ("You scrolled, so I've stopped and left the screen to you.", "Stopped: you scrolled."),
    "mouse": ("You've been moving the mouse, so I've handed the screen back.", "Handed back: you moved the mouse."),
    "app_stop": ("I've stopped and left the screen to you.", "Stopped: you took over."),
    "limit": ("I stopped after a long run of steps. Tell me if you want me to carry on.",
              "Stopped after {steps} steps. Say if you want more."),
    "time": ("I stopped because this has taken a long time. Tell me if you want me to carry on.",
             "Stopped: it was taking long."),
    "tainted": ("I've stopped driving because I read content from outside your screen. Ask me again if you want me to carry on.",
                "Stopped: Benji read outside content."),
    "turn_over": ("I'm done driving, and the screen is yours.", "Done: the screen is yours."),
    "error": ("Something went wrong, so I've stopped driving.", "Stopped: something went wrong."),
    "finished": ("Done. The screen is yours.", "Done: the screen is yours."),
}


def end_line(reason: str, steps: int = 0) -> tuple[str, str]:
    """(spoken, written) for a drive code ended."""
    spoken, written = END_LINES.get(reason, END_LINES["error"])
    return spoken, written.format(steps=steps)


# ---- text that must not fool a rule -------------------------------------------------------------
# A label can be written to slip past a word list: look-alike letters from other scripts, invisible
# characters, full-width forms, spaced-out letters, a word split in two. `skeleton` folds the first
# three away; `outbound_word` also reads the last two. The same table is in DriveClass.swift.

CONFUSABLES = {
    # Cyrillic
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "і": "i", "ј": "j", "ѕ": "s",
    "ԁ": "d", "һ": "h", "ԛ": "q", "ԝ": "w", "к": "k", "м": "m", "т": "t", "н": "h", "в": "b", "ь": "b",
    # Greek
    "α": "a", "ο": "o", "ρ": "p", "ν": "v", "ι": "i", "τ": "t", "υ": "u", "κ": "k", "χ": "x", "ε": "e",
    "γ": "y", "ω": "w",
    # Latin look-alikes
    "ı": "i", "ɩ": "i", "ł": "l", "ø": "o", "đ": "d", "ɡ": "g", "ƅ": "b", "ǀ": "l", "ꜱ": "s", "ɑ": "a",
}


def skeleton(text: str) -> str:
    """`text` lower-cased with compatibility forms folded (full-width, styled letters), accents and
    invisible characters dropped and look-alike letters of other scripts turned into the Latin letter."""
    out = []
    for ch in unicodedata.normalize("NFKD", str(text or "")).casefold():
        if unicodedata.category(ch) in ("Mn", "Cf", "Cc") and ch not in "\n\t":
            continue
        out.append(CONFUSABLES.get(ch, ch))
    return "".join(out)


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", skeleton(text))


# What may commit something outside the user's own screen or lose something: the words of
# screen_class.COMMIT_WORDS and the ones a drive adds, because a drive clicks more.
EXTRA_OUTBOUND = (
    "reply", "comment", "share", "tweet", "retweet", "forward", "invite", "book", "reserve", "order",
    "donate", "withdraw", "apply", "enroll", "register", "subscribe", "upload", "merge", "deploy",
    "empty", "reset", "wipe", "format", "uninstall", "revoke", "deactivate", "terminate", "end call",
    "leave meeting", "sign up", "signup", "unfollow", "block", "report", "authorize", "authorise",
)
OUTBOUND_WORDS = screen_class.COMMIT_WORDS + tuple(w for w in EXTRA_OUTBOUND if w not in screen_class.COMMIT_WORDS)


def _candidates(tokens: list[str]) -> list[str]:
    """The tokens, each pair of neighbours run together ("se" "nd") and each run of three or more
    single letters joined ("s" "e" "n" "d"): the ways a word is split to dodge a list."""
    cands = list(tokens)
    cands += [tokens[i] + tokens[i + 1] for i in range(len(tokens) - 1)]
    run: list[str] = []
    for t in tokens + [""]:
        if len(t) == 1:
            run.append(t)
            continue
        if len(run) >= 3:
            cands.append("".join(run))
        run = []
    return cands


def outbound_word(text: str) -> str | None:
    """The first outbound or destructive word or phrase in `text` (a button's title, a model's
    label), read through `skeleton` and the splitting tricks above, or None."""
    tokens = words(text)
    if not tokens:
        return None
    cands = _candidates(tokens)
    for entry in OUTBOUND_WORDS:
        parts = entry.split()
        if len(parts) == 1:
            if any(screen_class._matches(c, entry) for c in cands):
                return entry
            continue
        for i in range(len(tokens) - len(parts) + 1):
            if all(screen_class._matches(tokens[i + j], p) if j == len(parts) - 1 else tokens[i + j] == p
                   for j, p in enumerate(parts)):
                return entry
    return None


# ---- fields that are never typed into ---------------------------------------------------------

SECRET_PHRASES = (
    "password", "passwd", "passcode", "pass code", "cvv", "cvc", "otp", "one time", "verification code",
    "security code", "card number", "credit card", "debit card", "card no", "2fa", "authenticator",
    "pin code", "ssn", "social security", "routing number", "account number", "iban", "api key", "secret key",
    "recovery code", "backup code", "sms code", "login code", "sign in code",
)
MESSAGE_WORDS = frozenset({"message", "chat", "reply", "comment", "compose", "post", "tweet", "dm",
                           "caption", "body", "subject", "mail", "email", "write", "say"})
SEARCH_WORDS = frozenset({"search", "find", "address", "url", "location", "filter", "spotlight"})
TEXT_ROLES = screen_class.TEXT_ROLES
QUIET_DRAG_ROLES = frozenset({"AXSlider", "AXSplitter"})


def element_text(element: dict | None) -> str:
    """Everything Accessibility says names the element: title, description or placeholder, and the
    hints (help text, a web page's own id)."""
    if not element:
        return ""
    return " ".join(str(element.get(k) or "") for k in ("title", "description", "hints"))


def field_kind(element: dict | None) -> str:
    """What the focused field is for: secret, search, message or other."""
    if not element:
        return "other"
    if element.get("subrole") == "AXSecureTextField" or element.get("role") == "AXSecureTextField":
        return "secret"
    joined = " ".join(words(element_text(element)))
    padded = f" {joined} "
    if any(f" {' '.join(p.split())} " in padded for p in SECRET_PHRASES):
        return "secret"
    tokens = set(joined.split())
    if element.get("subrole") == "AXSearchField" or element.get("role") == "AXSearchField" or tokens & SEARCH_WORDS:
        return "search"
    if tokens & MESSAGE_WORDS:
        return "message"
    return "other"


def luhn_ok(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d = d * 2 - 9 if d * 2 > 9 else d * 2
        total += d
    return total % 10 == 0


def looks_like_card(text: str) -> bool:
    """Text that is a payment card number: 13 to 19 digits, spaces and dashes allowed, passing Luhn."""
    s = str(text or "").strip()
    if not re.fullmatch(r"[0-9][0-9 \-]{11,26}[0-9]", s):
        return False
    digits = re.sub(r"[ \-]", "", s)
    return 13 <= len(digits) <= 19 and luhn_ok(digits)


# ---- the classes --------------------------------------------------------------------------------

PRINTING_KEYS = frozenset([chr(c) for c in range(ord("a"), ord("z") + 1)] + [str(d) for d in range(10)]
                          + ["space", "minus", "equal", "comma", "period", "slash", "semicolon", "quote",
                             "left_bracket", "right_bracket", "backslash", "grave"])


def plan_class(step: dict) -> tuple[str, str]:
    """The engine's class for a step inside a drive, from the step alone, and why it is asked or
    refused. A click planned quiet is quiet only if the app, looking at the point, agrees."""
    kind = step.get("kind")
    if kind == "scroll":
        return FREE, ""
    if step.get("confidence") == "low":
        return ASKED, "Benji isn't sure this is what you want"
    if kind in ("click", "drag"):   # a drag planned quiet is quiet only on a real slider or divider
        word = outbound_word(step.get("label", ""))
        if word:
            return ASKED, f"“{word}” may send, buy, delete or commit something"
        return QUIET, ""
    if kind == "type_text":
        if looks_like_card(step.get("text", "")):
            return DENIED, "that is a card number, and Benji never types one"
        return QUIET, ""
    if kind == "press_key":
        key, mods = step.get("key"), list(step.get("modifiers") or [])
        if key in ("return", "enter") and mods:
            return ASKED, "this shortcut can send or submit"
        if "control" in mods:
            return ASKED, "a Control shortcut can stop a program"
        if "cmd" in mods and key in ("q", "w", "delete", "forward_delete"):
            return ASKED, "this shortcut can quit, close or erase something"
        if key in ("delete", "forward_delete") and mods:
            return ASKED, "Delete with a modifier can remove something"
        return QUIET, ""
    return ASKED, "Benji doesn't know this kind of step"


def _drag_class(label: str, element: dict | None, end_element: dict | None, same_app: bool,
                same_control: bool) -> tuple[str, str]:
    """A drag is quiet only on one native slider or split divider of the app Benji looked at, with
    the far end still on that control and no dialog open. It can't carry a file and dragging back
    undoes it. A web page can make anything report itself as a slider, so a page's never counts."""
    if (not same_app or not same_control or element is None or end_element is None
            or element.get("in_web_area") is not False or element.get("role") not in QUIET_DRAG_ROLES):
        return ASKED, screen_class.DRAG_WHY
    if element.get("in_sheet") or end_element.get("in_sheet"):
        return ASKED, "it's in a dialog"
    word = outbound_word(element_text(element))
    if word:
        return ASKED, f"“{word}” may send, buy, delete or commit something"
    if element.get("role") == "AXSlider":       # a divider has no name to check
        names = f"{element.get('title') or ''} {element.get('description') or ''}".strip()
        if not names:
            return ASKED, "nothing names this slider"
        if not screen_class.names_match(label, names):
            return ASKED, "what is there doesn't match what Benji named"
    return QUIET, ""


def final_class(step: dict, planned: str, element: dict | None = None, same_app: bool = True,
                end_element: dict | None = None, same_control: bool = False) -> tuple[str, str]:
    """The app's class at the point, after Accessibility: `element` is {role, subrole, title,
    description, hints, in_sheet, in_web_area} or None when nothing was found; `end_element` is the
    same for where a drag lets go, and `same_control` says it lets go still on the control it
    pressed. Never lower than `planned` (denied stays denied, asked stays asked)."""
    if planned in (ASKED, DENIED):
        return planned, ""
    if step.get("kind") == "drag":
        for at in (element, end_element):
            if at is not None and (at.get("role") in TEXT_ROLES or at.get("subrole") in TEXT_ROLES) and field_kind(at) == "secret":
                return DENIED, "that field is for a password, a card or a code, and Benji never types in one"
        return _drag_class(step.get("label", ""), element, end_element, same_app, same_control)
    if not same_app:
        return ASKED, "it's in another app than the one Benji looked at"
    kind = step.get("kind")
    if kind == "scroll":
        return planned, ""
    if kind == "click":
        if element is None:
            return ASKED, "Benji can't tell what is under the point"
        if element.get("in_sheet"):
            return ASKED, "it's in a dialog"
        if element.get("subrole") in screen_class.WINDOW_BUTTON_SUBROLES:
            return ASKED, "that closes, hides or resizes a window"
        text = element_text(element)
        word = outbound_word(text)
        if word:
            return ASKED, f"“{word}” may send, buy, delete or commit something"
        names = f"{element.get('title') or ''} {element.get('description') or ''}".strip()
        if element.get("role") in screen_class.BUTTON_ROLES | {"AXMenuButton"} and not names:
            return ASKED, "nothing names this button"
        if names and not screen_class.names_match(step.get("label", ""), names):
            return ASKED, "what is there doesn't match what Benji named"
        return planned, ""
    if kind == "type_text":
        if element is None or (element.get("role") not in TEXT_ROLES and element.get("subrole") not in TEXT_ROLES):
            return ASKED, "no text field has the keyboard"
        if field_kind(element) == "secret":
            return DENIED, "that field is for a password, a card or a code, and Benji never types in one"
        if element.get("in_sheet"):
            return ASKED, "it's in a dialog"
        return planned, ""
    if kind == "press_key":
        key, mods = step.get("key"), list(step.get("modifiers") or [])
        focused = field_kind(element) if element is not None else "other"
        if element is not None and focused == "secret" and (key in PRINTING_KEYS or key in ("return", "enter")):
            return DENIED, "that field is for a password, a card or a code, and Benji never types in one"
        if key in ("return", "enter"):
            if element is None:
                return ASKED, "Benji can't tell what Return would do"
            if element.get("in_sheet"):
                return ASKED, "a dialog is open, and Return can answer it"
            if element.get("role") in screen_class.BUTTON_ROLES:
                return ASKED, "a button has the keyboard, and Return can press it"
            is_text = element.get("role") in TEXT_ROLES or element.get("subrole") in TEXT_ROLES
            if is_text and focused == "search":
                return planned, ""
            if is_text and focused == "message":
                return ASKED, "Return in a message field can send it"
            return ASKED, "Return here may send or submit"
        if element is not None and element.get("in_sheet") and key == "space":
            return ASKED, "a dialog is open, and Space can answer it"
        if key == "space" and element is not None and element.get("role") in screen_class.BUTTON_ROLES:
            return ASKED, "a button has the keyboard, and Space can press it"
        if key in ("delete", "forward_delete") and not mods:
            is_text = element is not None and (element.get("role") in TEXT_ROLES or element.get("subrole") in TEXT_ROLES)
            if not is_text:
                return ASKED, "Delete outside a text field can remove something"
        if "cmd" in mods and key == "v" and focused == "secret":
            return DENIED, "that field is for a password, a card or a code, and Benji never types in one"
        return planned, ""
    return planned, ""


# ---- the state of one turn's drive ------------------------------------------------------------

def goal_key(goal: str) -> str:
    return " ".join(words(goal))


def clean_goal(goal: object) -> str:
    return " ".join(str(goal or "").split())[:MAX_GOAL_CHARS]


@dataclass
class Drive:
    """What a turn knows about its drive. Created only for a foreground turn the user started whose
    front-end can drive (Agent.allow_drive); a job's agent has none, so the tools refuse there."""
    notify: Callable[[dict], None] = lambda event: None
    clock: Callable[[], float] = time.monotonic
    scope: str = "turn"
    offered_goal: str = ""      # the goal the user agreed to on the card, until it is used
    offered_at: float = 0.0
    declined: bool = False      # the user said no or the card timed out: not asked again this turn
    yes: bool = False           # the user said yes on the card for the call about to run
    active: bool = False
    goal: str = ""
    steps: int = 0
    started_at: float = 0.0
    drives: int = 0
    ended: list = field(default_factory=list)   # {reason, spoken, written, steps} of each drive
    stopped: str = ""           # the user ended it (a reason): no more steps this turn

    def usable(self, taints: set[str], scope: str = "turn") -> tuple[bool, str]:
        """Whether a drive may begin or go on, and the code of the rule that says no."""
        if scope != "turn" or self.scope != "turn":
            return False, "drive_unusable"
        if self.stopped:
            return False, "drive_stopped"
        if self.declined:
            return False, "drive_declined"
        if set(taints) & HOSTILE_TAINTS:
            return False, "drive_tainted"
        return True, ""

    def live(self, taints: set[str]) -> bool:
        """A drive is on and nothing has ended it."""
        return self.active and not self.stopped and not (set(taints) & HOSTILE_TAINTS)

    def consented(self, goal: str) -> bool:
        return (bool(self.offered_goal) and goal_key(goal) == goal_key(self.offered_goal)
                and self.clock() - self.offered_at <= OFFER_VALID_SECONDS)

    def agree(self, goal: str) -> None:
        self.offered_goal, self.offered_at, self.declined = clean_goal(goal), self.clock(), False

    def decline(self) -> None:
        self.declined = True
        self.offered_goal = ""

    def begin(self, goal: str) -> None:
        self.active, self.goal, self.steps, self.started_at = True, clean_goal(goal), 0, self.clock()
        self.offered_goal = ""      # the consent is used: per drive, not remembered
        self.yes = False
        self.drives += 1
        self.notify({"state": "active", "goal": self.goal})

    def over_time(self) -> bool:
        return self.active and self.clock() - self.started_at > MAX_SECONDS

    def end(self, reason: str, spoken: str = "", written: str = "") -> dict | None:
        """End the drive (once) and tell the front-end. Without words from the model the line is the
        code's own (END_LINES)."""
        if not self.active:
            return None
        self.active = False
        self.yes = False
        if reason not in END_REASONS:
            reason = "error"
        if reason not in ("finished", "turn_over", "limit", "time", "tainted", "error"):
            self.stopped = reason       # the user's own input: nothing more this turn
        if not spoken:
            spoken, written_default = end_line(reason, self.steps)
            written = written or written_default
        record = {"reason": reason, "spoken": spoken, "written": written or spoken, "steps": self.steps}
        self.ended.append(record)
        self.notify({"state": "ended", "goal": self.goal, **record})
        self.offered_goal = ""
        return record
