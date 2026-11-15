"""What every tool call runs with: the turn's context (`Ctx`), output limits, and the shell capabilities that reach past the working folder."""

from __future__ import annotations

import os
import re
import signal
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .. import audit
from .. import browser as browser_mod
from .. import drive as drive_mod
from .. import gate
from .. import jobs as jobs_mod


MAX_OUTPUT = 16000  # chars returned to the model per tool call


@dataclass
class Ctx:
    workdir: Path
    skills_dir: Path | None = None
    memory_path: Path | None = None
    # Processes tools are running right now, so a cancelled turn can stop them (benji --serve).
    running: set = field(default_factory=set)
    stopped: bool = False
    lock: threading.Lock = field(default_factory=threading.Lock)
    # Screen actions (click, scroll, type_text, press_key, drag): the front-end's channel, set only for a
    # turn that carries a screenshot and a front-end that can act (benji --serve). It takes one
    # step and blocks until the app answers {status, text, image}. None: the tools refuse.
    screen: Callable[[dict], dict] | None = None
    screen_size: tuple[int, int] | None = None      # the screenshot's pixels, when the app said
    screen_stopped: bool = False                     # the user took over: no more steps this turn
    # Simple steps without a card: the app said it can (`screen_simple_steps`) and the
    # user hasn't chosen "Ask before every step". Off: every step is asked.
    screen_simple: bool = False
    user_text: str = ""                              # this turn's message (did it ask for text?)
    # Asks the user about a step the app found it must not do unasked: (reason) -> approved.
    screen_approve: Callable[[str], bool] | None = None
    images: list = field(default_factory=list)      # screenshots for the next tool result
    # The turn has taken in text from outside the user (a tainted turn): a web page or search
    # result, a file outside the working folder, AppleScript output, a screenshot. Once there is
    # any, every tool that changes something is asked. `taints` is which kinds (gate.TAINT_KINDS:
    # screen, web, browser, file), `taint_notes` the words for the card, kind to first
    # description. Starting a job after only the screen goes unasked (gate.taint_reason).
    taints: set = field(default_factory=set)
    taint_notes: dict = field(default_factory=dict)
    search_hosts: set = field(default_factory=set)  # hosts a web_search of this turn found
    screen_unasked: int = 0                          # free and quiet steps done this turn
    # Background jobs: the front-end's job store, for find_jobs and read_job, and
    # (a foreground turn only) what start_job calls: (title, brief) -> the tool's result. A job's
    # own turn has the store but no starter: a job doesn't start jobs.
    # The conversation's private note (a game's hidden answer, a score): what keep_note calls; None
    # when the front-end keeps no note (the terminal), and the tool is not offered.
    keep_note: Callable[[str], str] | None = None
    jobs: jobs_mod.JobStore | None = None
    live_job_ids: Callable[[], frozenset[str]] = frozenset
    start_job: Callable[..., str] | None = None
    # Schedules inside a job: what schedule_job calls, (job id or "", spec or None) ->
    # the tool's result; the front-end said it can show and carry out schedules; and, for a scheduled
    # run, that nobody is watching, so only read-class tools run unasked.
    set_schedule: Callable[..., str] | None = None
    schedule_offer: bool = False
    unattended: bool = False
    # Browser reach: the app's switch is on, so start_job may name sites (foreground turn);
    # for a job whose record carries a grant: the grant and the link to the extension.
    browser_offer: bool = False
    browser: browser_mod.Grant | None = None
    browser_link: Any = None                         # benji.browser_link.Link
    # Drive mode: the turn's drive state, set only for a foreground turn the user started whose
    # front-end can drive (Agent.allow_drive); a job's agent has none.
    drive: "drive_mod.Drive | None" = None
    browser_unasked: int = 0                         # quiet browser steps this job has taken
    browser_opens: int = 0                           # pages this job has opened
    # The user said yes to the card for the call about to run (tools.browser_approved); the
    # handler takes it, so a call that needs a yes and wasn't asked refuses.
    browser_yes: bool = False
    # Acting in the user's Chrome. The refs and signatures the last browser_look gave, per tab,
    # so a step is held to the control that was looked at; the unasked acting steps this job has
    # taken; the sites the user set to always allow reading (Settings, reading only); the agent's own
    # ask (a card, never answered by --yes); what to call when the user presses Cancel on Chrome's
    # debugging bar; and for a foreground turn, that read_active_tab is offered.
    browser_refs: dict = field(default_factory=dict)
    browser_act_unasked: int = 0
    browser_always: tuple = ()
    browser_approve: Callable[[str], bool] | None = None
    on_gate: Callable[[str, str], None] | None = None
    on_user_stop: Callable[[], None] | None = None
    browser_active: bool = False
    # Whether this job may look at controls and act (the app's hello said it can carry that out, and
    # policy.json hasn't switched it off), and whether it may upload. Both default on for a bare Ctx;
    # Agent.allow_browser sets them. A scheduled run (`unattended`) never acts or uploads whatever these say.
    browser_act_ok: bool = True
    browser_upload_ok: bool = True
    # The last in-handler card was not asked because the user said "not now" a moment ago (decline memory).
    browser_recent: bool = False
    # For the audit log: who is running (a turn's or a job's id), what the last call
    # refused for in its own handler, whether the app overruled a quiet screen step, and the host
    # the last call touched. Ids and codes only, never text.
    run: str = ""
    scope: str = "turn"
    denied_code: str = ""
    escalated: bool = False
    escalated_code: str = ""
    last_host: str = ""

    def begin_turn(self, user_text: str, screenshot: bool = False) -> None:
        """A new user turn: its message, and nothing outside read yet (a screenshot is)."""
        self.user_text = user_text
        self.taints, self.taint_notes = set(), {}
        self.search_hosts = set()
        self.screen_unasked = 0
        if screenshot:
            self.taint("the screen")

    @property
    def tainted(self) -> bool:
        return bool(self.taints)

    @property
    def taint_source(self) -> str:
        """What the turn read, in the card's words: each source once, in the order they came."""
        return _joined(self.taint_notes.values())

    def carried(self) -> tuple[set[str], str]:
        """What the next turn of the same conversation inherits: the kinds whose content stays in
        the messages, named as read earlier. A screenshot does not stay: it leaves the conversation
        when its turn ends."""
        kinds = self.taints - {gate.TAINT_SCREEN}
        notes = [note for kind, note in self.taint_notes.items() if kind in kinds]
        return kinds, gate.earlier_note(_joined(notes)) if kinds else ""

    def taint(self, source: str, host: str = "", code: str = "", kinds=None) -> None:
        """The turn read `source`, of the given kinds (default: the one `source` is). Each kind
        new to the turn is one `taint` event."""
        for kind in sorted(set(kinds) if kinds else {gate.taint_kind(source)}, key=gate.TAINT_KINDS.index):
            if kind in self.taints:
                continue
            self.taints.add(kind)
            self.taint_notes[kind] = source
            if kind in drive_mod.HOSTILE_TAINTS and self.drive is not None and self.drive.active:
                from .drive_mode import end_drive       # imported here: drive_mode needs Ctx
                end_drive(self, "tainted")      # outside content came in: the drive is over
            audit.event("taint", self.run, scope=self.scope, source=code or audit.taint_code(source), taint=kind,
                        host=audit.host_of(host) if host else None)

    def take_images(self) -> list:
        images, self.images = self.images, []
        return images

    def kill_running(self) -> None:
        """Stop every tool process (and its children) and refuse new ones."""
        with self.lock:
            self.stopped = True
            procs = list(self.running)
        for proc in procs:
            _kill_group(proc)


def _joined(notes) -> str:
    notes = list(dict.fromkeys(notes))
    if not notes:
        return ""
    return notes[0] if len(notes) <= 1 else ", ".join(notes[:-1]) + " and " + notes[-1]


def _kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def _run(ctx: Ctx, args, *, timeout: float, input: str | None = None, **kw) -> subprocess.CompletedProcess:
    """subprocess.run for tools: the process gets its own group, so a timeout, Ctrl-C or
    ctx.kill_running() stops its children too (a shell's `sleep`, a pipeline)."""
    with ctx.lock:
        if ctx.stopped:
            raise ToolCancelled
        # Never the API keys or Benji's own settings: a tool can print its env.
        kw.setdefault("env", gate.tool_env())
        proc = subprocess.Popen(args, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True, **kw)
        ctx.running.add(proc)
    try:
        out, err = proc.communicate(input=input, timeout=timeout)
    except BaseException:           # TimeoutExpired, KeyboardInterrupt: never leave it running
        _kill_group(proc)
        proc.wait()
        raise
    finally:
        with ctx.lock:
            ctx.running.discard(proc)
    return subprocess.CompletedProcess(args, proc.returncode, out, err)


class ToolCancelled(Exception):
    """A tool was asked to start after its turn was cancelled."""


def _truncate(s: str) -> str:
    if len(s) <= MAX_OUTPUT:
        return s
    head = s[: MAX_OUTPUT - 200]
    return f"{head}\n... [truncated {len(s) - len(head)} chars]"


def _resolve(ctx: Ctx, path: str) -> Path:
    p = Path(path).expanduser()
    return p if p.is_absolute() else (ctx.workdir / p)


def _within(ctx: Ctx, p: Path) -> bool:
    try:
        p.resolve().relative_to(ctx.workdir.resolve())
        return True
    except ValueError:
        return False


# --- sensitive shell capabilities --------------------------------------------
# Not destructive, but they reach past the working folder. A front-end such as the
# macOS app runs Benji as its child, and macOS lets a child use the app's privacy
# grants (Screen Recording, Accessibility), so these must never run unasked.
# Each entry: (what the user is asked to allow, pattern).
_SENSITIVE_SHELL = [
    ("take a screenshot or record the screen, camera or microphone",
     r"\bscreencapture\b|-f\s+avfoundation\b|\bimagesnap\b"),
    ("control other apps with osascript", r"\bosascript\b"),
    ("run a Shortcut", r"\bshortcuts\s+run\b"),
    ("send data over the network",
     r"\bcurl\b[^\n;&|]*\s(?:-[a-zA-Z]*[FTd]\b|--form\b|--upload-file\b|--data(?:-\w+)?\b"
     r"|-X\s*(?:POST|PUT|PATCH|DELETE)\b|--request\s+(?:POST|PUT|PATCH|DELETE)\b)"
     r"|\bwget\b[^\n;&|]*--post|\b(?:scp|sftp|rsync|ssh|ftp|nc|ncat|netcat|telnet)\b"),
    ("open an app, file or link", r"(?:^|[;&|(\n])\s*open\s"),
    ("read the clipboard", r"\bpbpaste\b"),
]
_SENSITIVE_SHELL_RE = [(why, re.compile(p)) for why, p in _SENSITIVE_SHELL]


def shell_sensitivity(command: str) -> str | None:
    """What a non-destructive command would do that needs the user's OK, or None."""
    for why, pattern in _SENSITIVE_SHELL_RE:
        if pattern.search(command):
            return why
    return None


def _with_note(reason: str, note: str) -> str:
    """`note` added to a card's action, before the ": " that starts its target (serve.py splits
    the reason there into the card's action and target)."""
    action, sep, target = reason.partition(": ")
    return f"{action} ({note}){sep}{target}"
