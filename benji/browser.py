"""Browser reach (D-143, steps 1 to 3): what a background job may do in the user's Chrome, decided in code.

A job can read pages in Chrome only if its record carries a `browser` grant: the `https` origins the
user approved on a card when the job started. Acting (clicking, typing) needs a second, separate
entry in the same record, `acts`, given by its own card and never implied by reading (D-171). This
module is the grants and the read rules and nothing else (no sockets, no model): the acting rules are
in benji/browser_act.py, the extension, the host and the link elsewhere (browser-extension/,
benji/browser_host.py, benji/browser_link.py), and the tools are in benji/tools.py.

  parse_url     a URL as (origin, path-and-query), or why it can't name a site we will use: only
                `https`, no user name or password, no IP address, no local name, no internationalised
                or punycode name, no unusual characters. Nothing refused here can be asked about.
  normalize_sites  the origins a model proposes for a job, and what was wrong with the rest
  Grant         the origins one job may use; a yes on a card adds one, and nothing else can
  plan          free / quiet / asked / refused for one tool call, as screen_class does for screen steps

A site matches only by its exact origin: scheme, host and port. `https://www.example.com`,
`https://example.com:8443` and `https://example.com.evil.net` are not `https://example.com`. The
extension holds the same rules (browser-extension/core.js); both run the cases in
browser-extension/test/origin-cases.json.
"""

from __future__ import annotations

import ipaddress
import re
import threading
import time
import urllib.parse
from dataclasses import dataclass
from typing import Callable

from . import gate
from .screen_class import ASKED, FREE, QUIET

REFUSED = "refused"
TOOL_NAMES = ("browser_open", "browser_tabs", "browser_read")
# Step 2 (D-171): looking at a page's controls is a read; the rest act as the user.
LOOK_TOOL = "browser_look"
ACT_TOOL_NAMES = ("browser_scroll", "browser_click", "browser_type", "browser_key", "browser_upload")
JOB_TOOL_NAMES = TOOL_NAMES + (LOOK_TOOL,) + ACT_TOOL_NAMES      # offered to a job that has a grant
# Step 3: a foreground turn reads the page the user is looking at, on a card showing its site.
ACTIVE_TOOL = "read_active_tab"
MAX_ALWAYS = 50             # sites the user may mark "always allow reading" in Settings
MAX_ORIGINS = 5             # sites a job may be granted at the start
MAX_UNASKED = 40            # quiet browser steps in one job; the next is asked
MAX_OPENS = 6               # pages one job may open
MAX_PAGE_CHARS = 40000      # what the extension returns for one read (the model sees less: MAX_OUTPUT)
MAX_URL_CHARS = 2000

_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
_TLD = re.compile(r"^[a-z]{2,24}$")


def _no_dns(host, port):
    raise OSError("matching never resolves a name")


def parse_url(url: object) -> tuple[str | None, str, str]:
    """(origin, path-and-query, why not). `origin` is `https://host` or `https://host:port` in
    lower case; None with a reason when `url` can't name a site a job may use."""
    if not isinstance(url, str) or not url.strip():
        return None, "", "that isn't a URL"
    text = url.strip()
    if len(text) > MAX_URL_CHARS:
        return None, "", "that URL is too long"
    if any(ord(c) <= 0x20 or ord(c) == 0x7F or c == "\\" for c in text):
        return None, "", "that URL has spaces, control characters or a backslash"
    try:
        parts = urllib.parse.urlsplit(text)
        port = parts.port
    except ValueError:
        return None, "", "that isn't a valid URL"
    if parts.scheme.lower() != "https":
        return None, "", "only https pages are supported"
    if "@" in parts.netloc:
        return None, "", "a URL with a user name or password isn't supported"
    host = parts.netloc.rsplit(":", 1)[0] if port is not None else parts.netloc
    if not host or host.startswith("[") or not host.isascii():
        return None, "", "only plain ASCII host names are supported"
    host = host.lower()
    labels = host.split(".")
    if len(labels) < 2 or len(host) > 253 or not all(_LABEL.match(lbl) for lbl in labels):
        return None, "", "that isn't a public host name"
    if any(lbl.startswith("xn--") for lbl in labels):
        return None, "", "internationalised (punycode) names aren't supported"
    if not _TLD.match(labels[-1]):
        return None, "", "that isn't a public host name"
    try:
        ipaddress.ip_address(host)
        return None, "", "an IP address isn't supported"
    except ValueError:
        pass
    if gate.host_refusal(host, resolve=_no_dns):
        return None, "", "that host is on this Mac or its local network"
    if port is not None and not 1 <= port <= 65535:
        return None, "", "that isn't a valid port"
    origin = f"https://{host}" + (f":{port}" if port not in (None, 443) else "")
    path = urllib.parse.urlunsplit(("", "", parts.path or "/", parts.query, ""))
    return origin, path, ""


def origin_of(url: object) -> str | None:
    return parse_url(url)[0]


def normalize_sites(raw: object) -> tuple[list[str], list[str]]:
    """(the origins, what was wrong) for the `sites` a model proposed: origins or URLs, at most
    MAX_ORIGINS, no repeats."""
    if raw is None:
        return [], []
    if not isinstance(raw, list):
        return [], ["sites must be a list of https site addresses"]
    origins: list[str] = []
    problems: list[str] = []
    for item in raw:
        origin, _, why = parse_url(item)
        if origin is None:
            problems.append(f"{str(item)[:80]!r}: {why}")
        elif origin not in origins:
            origins.append(origin)
    if len(origins) > MAX_ORIGINS:
        problems.append(f"at most {MAX_ORIGINS} sites per job")
        origins = origins[:MAX_ORIGINS]
    return origins, problems


def host_label(origin: str) -> str:
    """An origin as the card writes it: the host, with a port only when it isn't 443."""
    return origin[len("https://"):] if isinstance(origin, str) and origin.startswith("https://") else str(origin)


def normalize_always(raw: object) -> list[str]:
    """The sites the user set, in Settings, to always allow reading: clean origins only (a bad one is
    dropped), no repeats, at most MAX_ALWAYS. Reading only: nothing here ever lets Benji click, type,
    upload or send."""
    if not isinstance(raw, list):
        return []
    out: list[str] = []
    for item in raw:
        origin = origin_of(item)
        if origin is not None and origin not in out:
            out.append(origin)
    return out[:MAX_ALWAYS]


def start_reason(title: str, origins: list[str]) -> str:
    """The card when a job is started with sites: one ': ', so the app splits it into the action
    and the list of sites."""
    name = " ".join(str(title or "").replace(": ", " – ").split())[:60] or "a job"
    return f"let the background job “{name}” read these sites in your signed-in Chrome: " + ", ".join(origins)


# ---- the grant --------------------------------------------------------------------------------

class Grant:
    """The origins one job may use. Built from the job's record; `add` is called only after the
    user said yes on a card (tools.browser_approved), and writes the change into the record."""

    def __init__(self, record: dict, changed: Callable[[], None] | None = None):
        self._record = record
        self._changed = changed or (lambda: None)
        self._lock = threading.Lock()

    @property
    def origins(self) -> list[str]:
        with self._lock:
            return list((self._record.get("browser") or {}).get("origins", []))

    def allows(self, url_or_origin: object) -> bool:
        origin = origin_of(url_or_origin)
        return origin is not None and origin in self.origins

    @property
    def title(self) -> str:
        return str(self._record.get("title") or "")

    @property
    def acts(self) -> list[str]:
        """The origins this job may click and type on: its own list, never filled from `origins`."""
        with self._lock:
            return list((self._record.get("browser") or {}).get("acts", []))

    def may_act(self, url_or_origin: object) -> bool:
        origin = origin_of(url_or_origin)
        return origin is not None and origin in self.origins and origin in self.acts

    def add_act(self, origin: str, how: str = "card") -> bool:
        """Let this job act on an origin it can already read. Called only after the user said yes on
        the acting card (tools._browser_act); refused for anything parse_url refuses, and for an
        origin the job can't read."""
        clean = origin_of(origin)
        if clean is None or clean != origin:
            return False
        with self._lock:
            grant = self._record.get("browser") or {}
            if clean not in grant.get("origins", []):
                return False
            if clean in grant.setdefault("acts", []):
                return True
            grant["acts"].append(clean)
            grant.setdefault("history", []).append({"origin": clean, "at": time.time(), "how": how, "kind": "act"})
        self._changed()
        return True

    def add(self, origin: str, how: str = "card") -> bool:
        """Add an origin the user approved. Refused (False) for anything parse_url refuses."""
        clean = origin_of(origin)
        if clean is None or clean != origin:
            return False
        with self._lock:
            grant = self._record.setdefault("browser", {"origins": [], "acts": [], "history": []})
            if clean in grant["origins"]:
                return True
            grant["origins"].append(clean)
            grant.setdefault("history", []).append({"origin": clean, "at": time.time(), "how": how})
        self._changed()
        return True


def new_record_grant(origins: list[str]) -> dict:
    """The `browser` field of a job started with these origins."""
    now = time.time()
    return {"origins": list(origins), "acts": [],
            "history": [{"origin": o, "at": now, "how": "start"} for o in origins]}


# ---- the class of one call ---------------------------------------------------------------------

@dataclass(frozen=True)
class Plan:
    cls: str                # free, quiet, asked or refused
    reason: str = ""        # asked: the card's words ("action: target"); refused: why
    origin: str = ""        # browser_open: the origin the url names
    code: str = ""          # the audit log's reason code (audit.GATE_CODES)
    match: str = ""         # the origin against the job's list: granted, not_listed, invalid or no_grant


def tab_number(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def plan(grant: Grant | None, name: str, inp: dict, unasked: int = 0, opens: int = 0,
         always: tuple | list = ()) -> Plan:
    """The class of one browser tool call, before anything is asked or sent to the extension.
    free: listing Benji's own tab group. quiet: reading, or opening a page on an origin the user
    approved for this job or set to "always allow reading" in Settings (step 3: reading only). asked:
    opening a page on any other origin, a URL that carries data out, or the 41st quiet step.
    refused: no grant, or an argument that can't be right."""
    if grant is None or not grant.origins:
        return Plan(REFUSED, "this job has no browser access: the user approves sites when a job starts",
                    code="browser_no_grant", match="no_grant")
    if name == "browser_tabs":
        return Plan(FREE, code="browser_tabs")
    if name == "browser_read":
        if tab_number(inp.get("tab")) is None:
            return Plan(REFUSED, "tab must be the number browser_tabs or browser_open gave", code="browser_bad_tab")
        if unasked >= MAX_UNASKED:
            return Plan(ASKED, f"keep reading pages in your Chrome (this job has done {MAX_UNASKED} steps without asking): "
                               f"tab {tab_number(inp.get('tab'))}", code="browser_step_cap")
        return Plan(QUIET, code="browser_granted")
    if name == "browser_open":
        url = inp.get("url")
        origin, _, why = parse_url(url)
        if origin is None:
            return Plan(REFUSED, why, code="browser_bad_url", match="invalid")
        if opens >= MAX_OPENS:
            return Plan(REFUSED, f"this job has opened {MAX_OPENS} pages; it can read or reuse those",
                        code="browser_open_cap", match="granted" if origin in grant.origins else "not_listed")
        if origin not in grant.origins and origin not in always:
            return Plan(ASKED, f"open a page in your signed-in Chrome and let this job use {origin} from now on: {url}",
                        origin, code="browser_new_origin", match="not_listed")
        carries = gate.url_review(str(url))
        if carries:
            rest = carries.removeprefix("fetch a URL ")
            return Plan(ASKED, f"open a Chrome page {rest}: {url}", origin, code="browser_url_review", match="granted")
        if unasked >= MAX_UNASKED:
            return Plan(ASKED, f"keep opening pages in your Chrome (this job has done {MAX_UNASKED} steps without asking): {url}",
                        origin, code="browser_step_cap", match="granted")
        if origin not in grant.origins:     # a site the user always allows reading: it joins this job's reading list
            return Plan(QUIET, origin=origin, code="browser_always", match="always")
        return Plan(QUIET, origin=origin, code="browser_granted", match="granted")
    return Plan(REFUSED, f"{name} isn't a browser tool", code="tool_refused")


def plan_active(origin: str | None, always: tuple | list = ()) -> Plan:
    """read_active_tab (step 3), once the extension has said which site the user's front tab is on:
    asked on a card that shows the site, every time, unless the user set that exact site to "always
    allow reading" in Settings. The origin is the extension's, parsed again here; a page that isn't
    one Benji can use is refused."""
    if origin is None:
        return Plan(REFUSED, "the tab in front isn't a page Benji can read (only plain https pages are used)",
                    code="browser_bad_url", match="invalid")
    if origin in always:
        return Plan(QUIET, origin=origin, code="browser_always", match="always")
    return Plan(ASKED, f"read the page you are looking at in Chrome ({host_label(origin)}) and send what it shows to the model: "
                       f"{host_label(origin)}", origin, code="browser_active_tab", match="not_listed")


# ---- what comes back from the extension -------------------------------------------------------

def tab_line(tab: dict, grant: Grant) -> str:
    """One tab for browser_tabs. A tab on a site off the job's list shows its origin only: not its
    title or path, which could say what the user has open."""
    number = tab.get("id")
    url = tab.get("url") if isinstance(tab.get("url"), str) else ""
    origin = origin_of(url)
    if origin is None:
        return f"- tab {number} · (not a page this job can use)"
    if origin not in grant.origins:
        return f"- tab {number} · {origin} (not on this job's list)"
    title = " ".join(str(tab.get("title") or "").split())[:120]
    return f"- tab {number} · {url[:300]}" + (f" · “{title}”" if title else "")


def clean_error(text: object) -> str:
    return " ".join(str(text or "the extension couldn't do that").split())[:300]
