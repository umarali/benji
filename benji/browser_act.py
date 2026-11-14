"""Browser reach, step 2 (acting): what a click, a typed word or a key press in the user's Chrome is
classed as, decided in code from what the page's element is, never from what the model called it.

Only rules and small helpers live here (no sockets, no model): the tools are in benji/tools.py, the
link to the extension in benji/browser_link.py, the grants in benji/browser.py. The extension holds
the same floor rules in JavaScript (browser-extension/core.js `floor`); both run the cases in
browser-extension/test/act-cases.json.

How a step is decided (D-171):
  1. The extension looks at the element (no debugger yet) and returns a *descriptor*: kind, accessible
     name, link target, form method, and whether it is a password, card number or one-time-code field.
  2. `floor` turns the descriptor into a class that depends only on the element and the page:
     free, quiet, asked or refused. `classify` raises it with what only the engine knows: the user's
     own words, how many unasked steps the job has taken.
  3. The extension looks again right before it acts and refuses if its own `floor` is higher than the
     class the engine settled on, or if the element is no longer the one that was looked at. The
     engine plans; the extension may only raise.

Free: scrolling, keys that only move around. Quiet: following a link on the same site, switching a tab,
opening a disclosure, ticking a checkbox, filling a field the user's words named. Asked, every time: a
button or control named or typed submit/send/buy/pay/delete/post/confirm, a form post, Return, a click
that leaves the site, a new tab, any download, any upload, a button Benji can't tell the effect of.
Refused: password, card-number and one-time-code fields; a file chooser (use browser_upload); an
element Benji can't name; a `javascript:` link; any key that isn't a plain navigation key or Return.
"""

from __future__ import annotations

import re
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

from . import browser as browser_mod
from . import gate
from .screen_class import ASKED, FREE, QUIET

REFUSED = browser_mod.REFUSED
RANK = {FREE: 0, QUIET: 1, ASKED: 2, REFUSED: 3}

MAX_ACT_UNASKED = 12        # quiet acting steps one job takes before the next is asked
MAX_TYPED = 2000            # characters one browser_type may enter
MAX_UPLOAD_BYTES = 50 * 1024 * 1024
MAX_LOOK = 120              # controls browser_look lists
SIG_CHARS = 16

SCROLL_TO = ("down", "up", "top", "bottom")
FREE_KEYS = ("PageUp", "PageDown", "Home", "End")
QUIET_KEYS = ("ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Tab", "Escape")
ASKED_KEYS = ("Enter", "Backspace", "Delete")
KEYS = FREE_KEYS + QUIET_KEYS + ASKED_KEYS

# Words that make a click a commitment, matched at the start of a word on the element's name and text.
_COMMIT = re.compile(
    r"\b(submit|send|post|publish|buy|purchas|pay|checkout|check out|order|confirm|delete|remov|eras|discard|"
    r"sign out|signout|log out|logout|unsubscrib|subscrib|accept|agree|allow|install|transfer|withdraw|donat|"
    r"authori[sz]|place order|wire|empty|clear all|reset|deactivat|cancel (?:my |your )?(?:account|subscription|order))",
    re.IGNORECASE)
# Fields Benji never types into and never focuses (any case): by type, by autocomplete token, by name.
_SENSITIVE_AUTOCOMPLETE = re.compile(r"\b(cc-[a-z-]+|one-time-code|current-password|new-password)\b", re.IGNORECASE)
_SENSITIVE_NAME = re.compile(
    r"pass(?:word|wd|code|phrase)|passcode|card[\s_.-]*(?:number|num|no)\b|\bcc[\s_.-]*(?:num|number)|cvv|cvc|"
    r"security[\s_.-]*code|\botp\b|one[\s_.-]*time|verification[\s_.-]*code|\b2fa\b|\bpin[\s_.-]*(?:code)?\b|"
    r"\biban\b|account[\s_.-]*number|routing[\s_.-]*number|\bssn\b|social[\s_.-]*security",
    re.IGNORECASE)
_DOWNLOAD_EXT = re.compile(r"\.(?:zip|dmg|pkg|exe|msi|app|tar|gz|tgz|rar|7z|iso|apk|csv|xlsx?|docx?|pptx?|pdf|mp[34]|mov)(?:$|[?#])",
                           re.IGNORECASE)
TEXT_KINDS = ("text",)
CHECK_KINDS = ("checkbox", "radio", "select", "tab", "disclosure")


@dataclass(frozen=True)
class Verdict:
    cls: str                 # free, quiet, asked or refused
    code: str                # the audit log's reason code (audit.GATE_CODES)
    what: str = ""           # the card's words for what the step does ("press the button “Send”")
    why: str = ""            # asked: why this one is asked ("it looks like it sends or pays"); refused: why not
    leaves: str = ""         # a click that moves to another site: that site's origin (a yes adds it to reading)
    download: bool = False   # a yes also allows the download this click starts


def _clip(value: object, n: int) -> str:
    return " ".join(str(value or "").split())[:n]


def _label(desc: dict) -> str:
    return _clip(desc.get("name") or desc.get("text"), 80)


def sensitive(desc: dict | None) -> bool:
    """A password, card-number or one-time-code field, by what the page says it is (the descriptor
    carries the page's own words for the field; the extension checks them too)."""
    if not isinstance(desc, dict):
        return False
    if desc.get("sensitive") is True:
        return True
    if str(desc.get("inputType") or "").lower() == "password":
        return True
    if _SENSITIVE_AUTOCOMPLETE.search(str(desc.get("autocomplete") or "")):
        return True
    hint = " ".join(str(desc.get(k) or "") for k in ("fieldName", "name", "placeholder"))
    return bool(desc.get("kind") == "text" and _SENSITIVE_NAME.search(hint))


def commit_word(desc: dict) -> str:
    found = _COMMIT.search(" ".join(str(desc.get(k) or "") for k in ("name", "text", "value")))
    return found.group(1).lower() if found else ""


def link_scheme(href: str) -> str:
    return urllib.parse.urlsplit(href).scheme.lower() if href else ""


def tail_looks_like_download(href: str) -> bool:
    return bool(_DOWNLOAD_EXT.search(urllib.parse.urlsplit(href).path + ("?" if "?" in href else "")))


def floor(action: str, desc: dict | None, tab_origin: str) -> Verdict:
    """The class of a click, a typed word or a key that depends only on the element and the page.
    `action` is click, type or key; `desc` the element looked at (for a key: the focused element, or
    None for the page); `tab_origin` the origin of the page it is on. Shared cases with the extension."""
    desc = desc if isinstance(desc, dict) else {}
    kind = str(desc.get("kind") or "")
    if action == "key":
        return _floor_key(str(desc.get("key") or ""), desc.get("focus") if isinstance(desc.get("focus"), dict) else None)
    if sensitive(desc):
        return Verdict(REFUSED, "browser_act_refused",
                       why="that is a password, card number or one-time-code field; Benji never types into one or clicks it")
    if desc.get("disabled") is True:
        return Verdict(REFUSED, "browser_act_refused", why="that control is switched off on the page")
    name = _label(desc)
    if kind == "file":
        return Verdict(REFUSED, "browser_act_refused", why="a file chooser can't be driven by a click; use browser_upload")
    if not name and not (kind in ("checkbox", "radio") and desc.get("labelled") is True):
        return Verdict(REFUSED, "browser_act_refused", why="Benji can't name that element, so it won't act on it")
    if action == "type":
        if kind != "text":
            return Verdict(REFUSED, "browser_act_refused", why="that isn't a text field")
        return Verdict(QUIET, "browser_act_quiet", f"type into the field “{name}”")
    # a click
    word = commit_word(desc)
    what = f"click the {_KIND_WORD.get(kind, 'control')} “{name}”" if name else f"click the {_KIND_WORD.get(kind, 'control')}"
    if kind == "link":
        href = str(desc.get("href") or "")
        scheme = link_scheme(href)
        if scheme not in ("https", "http", "mailto", "tel"):
            return Verdict(REFUSED, "browser_act_refused", why="that link runs a script or opens something Benji can't see")
        if word:
            return Verdict(ASKED, "browser_act_asked", what, f"it is named “{word}”, which looks like it sends, pays or changes something")
        if scheme in ("mailto", "tel"):
            return Verdict(ASKED, "browser_act_asked", what, "it opens another app on your Mac")
        if desc.get("download") is True or tail_looks_like_download(href):
            return Verdict(ASKED, "browser_act_asked", what, "it looks like a download", download=True)
        target = browser_mod.origin_of(href)
        if target is None:
            return Verdict(ASKED, "browser_act_asked", what, "it goes to an address Benji doesn't use")
        if target != tab_origin:
            return Verdict(ASKED, "browser_act_leaves", what, f"it leaves {browser_mod.host_label(tab_origin)} for {browser_mod.host_label(target)}",
                           leaves=target)
        if desc.get("blank") is True:
            return Verdict(ASKED, "browser_act_asked", what, "it opens a new tab, which Benji can't keep inside its tab group")
        return Verdict(QUIET, "browser_act_quiet", what)
    if kind in ("submit", "button"):
        if word:
            return Verdict(ASKED, "browser_act_asked", what, f"it is named “{word}”, which looks like it sends, pays or changes something")
        if kind == "submit" or desc.get("form"):
            how = "a form post" if desc.get("form") == "post" else "a form submission"
            return Verdict(ASKED, "browser_act_asked", what, f"it sends {how}")
        return Verdict(ASKED, "browser_act_asked", what, "Benji can't tell what pressing it does")
    if kind in CHECK_KINDS:
        if word:
            return Verdict(ASKED, "browser_act_asked", what, f"it is named “{word}”, which looks like it agrees to or allows something")
        return Verdict(QUIET, "browser_act_quiet", what)
    if kind in TEXT_KINDS:
        return Verdict(QUIET, "browser_act_quiet", f"click into the field “{name}”")
    return Verdict(ASKED, "browser_act_asked", what, "Benji can't tell what clicking it does")


_KIND_WORD = {"link": "link", "checkbox": "checkbox", "radio": "option", "select": "menu", "tab": "tab",
              "disclosure": "section header", "text": "field", "submit": "button", "button": "button"}


def _floor_key(key: str, focus: dict | None) -> Verdict:
    if key not in KEYS:
        return Verdict(REFUSED, "browser_act_refused", why="only Enter, Backspace, Delete, Tab, Escape, the arrow keys and "
                       "PageUp/PageDown/Home/End can be pressed; use browser_type for text")
    if focus is not None and sensitive(focus):
        return Verdict(REFUSED, "browser_act_refused", why="the focus is in a password, card number or one-time-code field")
    what = f"press {key}" + (f" in the field “{_label(focus)}”" if focus and focus.get("kind") == "text" and _label(focus) else "")
    if key in FREE_KEYS:
        return Verdict(FREE, "browser_act_free", what)
    if key in QUIET_KEYS:
        return Verdict(QUIET, "browser_act_quiet", what)
    where = "in a field" if focus and focus.get("kind") == "text" else "on the page"
    return Verdict(ASKED, "browser_act_asked", what, f"{key} {where} can send or delete something")


def classify(action: str, desc: dict | None, tab_origin: str, *, text: str = "", user_text: str = "",
             unasked: int = 0, cap: int = MAX_ACT_UNASKED) -> Verdict:
    """`floor`, raised by what only the engine knows. Typed text is quiet only when it is the user's
    own words or goes in a short, plain way into a field the user's words named; the unasked-step cap
    makes the next quiet step asked."""
    v = floor(action, desc, tab_origin)
    if v.cls == REFUSED:
        return v
    if action == "type":
        if len(text) > MAX_TYPED or not text:
            return Verdict(REFUSED, "browser_bad_args", why=f"text must be 1 to {MAX_TYPED} characters")
        label = _label(desc or {})
        said = gate.said_by_user(text, user_text)
        named = bool(label) and gate.said_by_user(label, user_text)
        plain = len(text) <= 120 and not gate.hosts_in(text) and "@" not in text
        if not (said or (named and plain)):
            v = Verdict(ASKED, "browser_act_asked", v.what, "the words to type didn't come from your message")
    if v.cls == QUIET and unasked >= cap:
        v = Verdict(ASKED, "browser_act_cap", v.what, f"this job has taken {cap} steps in your Chrome without asking")
    return v


def higher(a: str, b: str) -> bool:
    return RANK[a] > RANK[b]


def card(v: Verdict, origin: str, detail: str = "", tainted_note: str = "") -> str:
    """The card for an asked step, as 'action: target' (the app splits it at the first ': ')."""
    site = browser_mod.host_label(origin)
    note = f" ({tainted_note})" if tainted_note else ""
    action = f"{v.what} on {site}{note}" + (f", because {v.why}" if v.why else "") + " – this acts as you in your signed-in Chrome"
    return f"{action}: {detail or site}"


def grant_card(title: str, origin: str) -> str:
    name = " ".join(str(title or "").replace(": ", " – ").split())[:60] or "a job"
    return (f"let the background job “{name}” click, type and press keys on this site in your signed-in Chrome "
            f"(this is separate from reading it, and only for this job): {origin}")


# ---- uploads ------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Upload:
    path: Path               # the resolved file Chrome will be given
    name: str
    size: int
    inside: bool             # inside the job's working folder


def vet_upload(raw: object, workdir: Path, home: Path | None = None) -> tuple[Upload | None, str]:
    """(the file, why not). The same read rules as the file tools: a private path (keys, mail,
    messages, browser data, `.env`, Benji's own folder) is refused outright, as written and as
    resolved; a file outside the working folder is allowed only because every upload is asked."""
    if not isinstance(raw, str) or not raw.strip() or len(raw) > 1000 or "\0" in raw or "\n" in raw:
        return None, "path must be one file path"
    given = Path(raw.strip()).expanduser()
    given = given if given.is_absolute() else workdir / given
    if gate.private_path(given, home, workdir):
        return None, f"that file is private ({gate.private_path(given, home, workdir)}); Benji never uploads keys, mail, messages, browser data or settings"
    try:
        resolved = given.resolve(strict=True)
    except OSError:
        return None, "no such file"
    if gate.private_path(resolved, home, workdir):
        return None, f"that file is private ({gate.private_path(resolved, home, workdir)}); Benji never uploads keys, mail, messages, browser data or settings"
    if not resolved.is_file():
        return None, "that is not a regular file"
    try:
        size = resolved.stat().st_size
    except OSError:
        return None, "no such file"
    if size > MAX_UPLOAD_BYTES:
        return None, f"that file is over {MAX_UPLOAD_BYTES // (1024 * 1024)} MB"
    try:
        resolved.relative_to(workdir.resolve())
        inside = True
    except ValueError:
        inside = False
    return Upload(resolved, resolved.name, size, inside), ""


def size_words(n: int) -> str:
    if n < 1024:
        return f"{n} bytes"
    if n < 1024 * 1024:
        return f"{n / 1024:.0f} KB"
    return f"{n / (1024 * 1024):.1f} MB"


def upload_card(up: Upload, origin: str, field: str, tainted_note: str = "") -> str:
    """One card per file: its name and size, the site, and where it is from."""
    note = f" ({tainted_note})" if tainted_note else ""
    where = "in the job's folder" if up.inside else "from outside the job's folder"
    label = f" into “{_clip(field, 60)}”" if field else ""
    return (f"upload the file “{up.name}” ({size_words(up.size)}, {where}) to {browser_mod.host_label(origin)}{label}{note} "
            f"in your signed-in Chrome – the site gets the whole file: {up.path}")


# ---- what the extension says back, kept short ----------------------------------------------------

def look_lines(controls: list, tab_origin: str) -> tuple[list[str], dict[int, str]]:
    """browser_look's text, and {ref: signature} so a later step can be held to the control that was
    looked at. A link to another site shows that site only."""
    lines: list[str] = []
    sigs: dict[int, str] = {}
    for c in controls[:MAX_LOOK]:
        if not isinstance(c, dict) or not isinstance(c.get("ref"), int) or isinstance(c.get("ref"), bool):
            continue
        sig = c.get("sig")
        if isinstance(sig, str) and 0 < len(sig) <= 64:
            sigs[c["ref"]] = sig
        kind = _clip(c.get("kind"), 12) or "control"
        label = _clip(c.get("name") or c.get("text"), 80)
        bits = []
        if c.get("sensitive"):
            bits.append("protected field: Benji never types here")
        if c.get("kind") == "link":
            target = browser_mod.origin_of(c.get("href"))
            if target is None:
                bits.append("goes to an address Benji doesn't use")
            elif target != tab_origin:
                bits.append(f"leaves for {browser_mod.host_label(target)}")
            else:
                bits.append("same site")
        for flag, word in (("checked", "ticked"), ("expanded", "open"), ("disabled", "off")):
            if c.get(flag) is True:
                bits.append(word)
        lines.append(f"[{c['ref']}] {kind} “{label}”" + (f" ({'; '.join(bits)})" if bits else ""))
    return lines, sigs


# ---- arguments ----------------------------------------------------------------------------------

_ARGS = {
    "browser_look": ("tab",),
    "browser_scroll": ("tab", "to"),
    "browser_click": ("tab", "ref"),
    "browser_type": ("tab", "ref", "text", "replace"),
    "browser_key": ("tab", "key"),
    "browser_upload": ("tab", "ref", "path"),
}


def ref_number(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if 0 <= value < 100_000 else None
    if isinstance(value, str) and value.strip().isdigit() and len(value.strip()) <= 5:
        return int(value.strip())
    return None


def check_args(name: str, inp: dict) -> tuple[dict | None, str, str]:
    """(clean arguments, why not, the audit code). Only the arguments each tool declares are read: a
    model can't pass a grant, an origin list, a class or an option to the extension."""
    if name not in _ARGS:
        return None, f"{name} isn't a browser tool", "tool_refused"
    out: dict = {}
    tab = browser_mod.tab_number(inp.get("tab"))
    if tab is None:
        return None, "tab must be the number browser_tabs or browser_open gave", "browser_bad_tab"
    out["tab"] = tab
    if "ref" in _ARGS[name]:
        ref = ref_number(inp.get("ref"))
        if ref is None:
            return None, "ref must be a number from browser_look", "browser_bad_ref"
        out["ref"] = ref
    if name == "browser_scroll":
        to = inp.get("to", "down")
        if to not in SCROLL_TO:
            return None, f"to must be one of {', '.join(SCROLL_TO)}", "browser_bad_args"
        out["to"] = to
    if name == "browser_type":
        text = inp.get("text")
        if not isinstance(text, str) or not 1 <= len(text) <= MAX_TYPED or "\0" in text:
            return None, f"text must be 1 to {MAX_TYPED} characters", "browser_bad_args"
        out["text"] = text
        out["replace"] = inp.get("replace") is True
    if name == "browser_key":
        key = inp.get("key")
        if key not in KEYS:
            return None, ("key must be one of " + ", ".join(KEYS) + "; use browser_type for text, and there are no shortcuts"), "browser_bad_args"
        out["key"] = key
    if name == "browser_upload":
        out["path"] = inp.get("path")
    return out, "", ""
