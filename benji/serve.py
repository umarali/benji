"""`benji --serve`: one long-lived Benji that speaks JSON lines over stdio (D-34, D-72).

The design is in docs/proposal-serve.md. In short: the front-end writes requests to
stdin (hello, send, approve, cancel, cut_off, restore, reset, shutdown) and reads events from stdout
(ready, tool, approval, delta, answer, usage, error, done), one JSON object per line. When the
app shows explanation cards, the card lines of a reply come as `card`, `card_item`,
`card_takeaway` and `card_chips` events as each line closes, then `card_end`, and are never in
the deltas or the answer's text (benji/cards.py).
A screen step (click, scroll, type_text, press_key, drag; D-123) is acted on by the app, not here: after
its approval the engine sends `screen_action` and waits for the app's `screen_result`. A simple
step (D-126: `mode` free or quiet, only when the app's `send` said `screen_simple_steps`) goes
unasked, and the app may answer "ask", after which the engine asks as usual. Nothing else
goes to stdout; logs go to stderr. One foreground turn runs at a time, in a worker thread, on a copy of
the conversation that is committed only when the turn ends ok, so a cancelled turn leaves no
trace. Approvals wait for the matching `approve`; no answer in time means deny, and every
approval ends with an `approval_result`. Benji's own approval timeout is longer than the
companion's, so the companion's decision (or its timeout) always arrives first.
A background job (D-130 step 1, benji/jobs.py) is a second turn in the same process, started by
the foreground turn's `start_job` tool when the app's `send` said `jobs`. It has its own Agent
(so its own taint, folder and context) and its own _Turn, found by `approve` under the job's id. Its
progress is one event, `job`, a snapshot of the job as the panel shows it (state derived in
code, the approval it waits on, the files it made); the app steers it with `job_steer`, stops it
with `job_stop` and clears it with `job_dismiss`. A job's approval never times out: it parks the job
as `needs-you` until the user answers or stops it.
"""

from __future__ import annotations

import json
import os
import queue
import signal
import sys
import threading
import time
import traceback
from dataclasses import replace
from typing import Callable

from . import answer_log, audit
from . import drive as drive_mod
from . import browser as browser_mod
from . import errors as errors_mod
from . import policy as policy_mod
from . import cards as cards_mod
from . import gate as gate_mod
from . import jobs as jobs_mod
from . import pointing
from . import schedule as schedule_mod
from . import tools as tools_mod
from .agent import CANCELLED, JOB_MAX_STEPS, JOB_MAX_TOOL_CALLS, LIMIT_MARK, STOPPED_AT_MAX, Agent
from .history import HistoryError, history_from_exchanges, kept_count
from .images import ImageError, load_image
from .prompts import TurnInfo
from . import providers as providers_mod
from .providers import ProviderError

PROTOCOL = 1
# What the engine can do beyond protocol 1, said in `ready` (D-173). An app that does not know a name
# ignores it; an engine that does not send the list is an older one.
ENGINE_CAPS = ("hello_caps", "prewarm", "policy", "tool_cap", "image_hash", "error_reasons")
# What an app may say it can carry out, in `hello`. The engine offers a tool only if the app can do
# it; an app that sends no list (an older one) is taken to be able to do what its `send` says.
# "browser_act": the app can show and answer the acting cards of a job (a second grant per site, a send, a
# debugging bar's Cancel) and "browser_upload": the upload card; the engine offers those tools only if said (D-171).
APP_CAPS = ("pointing", "screen_actions", "cards", "figures", "jobs", "browser", "prewarm", "schedules", "drive",
            "browser_act", "browser_upload")
PREWARM_QUIET_SECONDS = 240.0   # a warm-up is skipped when the last call was more recent than this
PREWARM_MIN_GAP = 30.0
APPROVAL_TIMEOUT = 90.0         # seconds; longer than the companion's own 60 s on purpose
OLD_TOOL_RESULT_CHARS = 2000    # tool results from earlier turns are cut to this
SCREEN_STEP_TIMEOUT = 30.0      # seconds the app has to act on one approved step and look again
# "ask": the app looked at an unasked step (free or quiet, D-126) and found it must be asked first.
SCREEN_STATUSES = ("done", "refused", "stopped", "failed", "ask")

JOB_BEAT = 2.5                  # seconds a job waits, visibly, before it starts: Esc cancels it
SCHEDULE_TICK = 30.0            # seconds between looks at the schedules, while the engine runs (D-172)
# What the panel says while a job waits out a bad connection (D-177), by errors.WORTH_WAITING.
JOB_WAIT_LINES = {"network": "Waiting for a connection", "rate_limit": "Waiting for the model service",
                  "provider": "Waiting for the model service"}
# What the panel says a job is doing, by tool: never a command, a path or a query (D-98).
JOB_LINES = {
    "web_search": "Searching the web", "web_fetch": "Reading a page", "run_shell": "Running a command",
    "write_file": "Writing a file", "read_file": "Reading a file", "list_dir": "Looking through files",
    "search_files": "Looking through files", "run_applescript": "Using an app", "run_shortcut": "Running a Shortcut",
    "remember": "Noting something", "recall": "Checking notes", "find_jobs": "Checking past jobs",
    "read_job": "Reading a past job", "read_skill": "Checking a skill", "list_skills": "Checking a skill",
    # Never the address (D-98): a page is named by what the job is doing, not where.
    "browser_open": "Opening a page in Chrome", "browser_read": "Reading a page in Chrome",
    "browser_tabs": "Looking at its Chrome tabs",
    "browser_look": "Looking at a page in Chrome", "browser_scroll": "Scrolling a page in Chrome",
    "browser_click": "Clicking in Chrome", "browser_type": "Typing in Chrome", "browser_key": "Pressing a key in Chrome",
    "browser_upload": "Giving a page a file in Chrome",
}

# make_agent(approve, on_tool, cancelled, turn_info) -> a fresh Agent for one turn
AgentFactory = Callable[[Callable[[str], bool], Callable[[str, dict], None], Callable[[], bool], TurnInfo], Agent]
# make_job_agent(record, approve, on_tool, cancelled) -> an Agent working in the job's folder
JobAgentFactory = Callable[[dict, Callable[[str], bool], Callable[[str, dict], None], Callable[[], bool]], Agent]


class _Turn:
    def __init__(self, turn_id: str):
        self.id = turn_id
        self.cancelled = threading.Event()
        self.finished = threading.Event()
        self.approvals: dict[str, queue.Queue] = {}
        self.screen_steps: dict[str, queue.Queue] = {}  # screen_action requests waiting for the app
        self.next_step = 0
        self.asking_step: dict | None = None    # the screen step the next approval is for
        self.agent: Agent | None = None     # set once the worker has built it
        self.next_request = 0
        self.committed = False              # its result is in history: too late to cancel
        self.text = ""                      # the user's message, kept if the turn is cut off
        self.lock = threading.Lock()
        self.log: list[dict] = []           # the events sent, for the answer log
        self.raw: str | None = None         # the model's answer before anything was taken out
        self.screen: dict | None = None     # what the app said about the screen and its canvas
        self.canvas: dict | None = None
        self.jobs = False                   # the app shows background jobs: start_job is offered
        self.drive_cards: set[str] = set()  # approval requests that only the app's own card may answer (D-170)
        self.schedules = False              # the app can show and carry out schedules (D-172)
        self.last_why = ""                  # how the last approval was answered: yes, no, timeout, cancelled
        self.note: str | None = None        # the note this turn asked to keep; kept once the turn commits


class _JobRun:
    """A background job's current run in this process: its record, its turn (the job's id is the
    turn's id, so `approve` finds it), and what the user has said to steer it."""

    def __init__(self, record: dict, beat: float | None = None):
        self.record = record
        self.turn = _Turn(record["id"])
        self.live = True            # a worker is on it
        self.line = ""              # what it is doing, from JOB_LINES
        self.waiting = ""           # why it is waiting out a bad connection, or "" (D-177)
        self.step = 0               # the last tool step it finished
        self.warned = False         # code told it the steps are nearly out (D-177)
        self.steers: list[str] = []
        self.agent: Agent | None = None
        self.audited = ""           # the last state written to the audit log
        self.beat = beat            # seconds of beat before it starts; None: the server's
        self.resumed = False        # it came back from a park: its brief is read to it again (D-172)
        self.switch_off = False     # stopped because the user turned all schedules off
        self.auto_paused = False    # this run's failure paused the schedule


# The job states of the panel, as the audit log words them (audit.JOB_STATES).
_AUDIT_STATE = {"working": "running", "done": "finished"}


class Server:
    def __init__(self, make_agent: AgentFactory, emit: Callable[[dict], None], info: dict,
                 approval_timeout: float = APPROVAL_TIMEOUT, answer_log_path=None,
                 make_job_agent: JobAgentFactory | None = None, job_store: jobs_mod.JobStore | None = None,
                 job_beat: float = JOB_BEAT, browser_link=None, policy_for=None, warm=None,
                 clock: Callable[[], float] = time.time, schedule_tick: float | None = SCHEDULE_TICK, tz=None,
                 drive_wait: float = drive_mod.CARD_SECONDS + 2):
        self.make_agent = make_agent
        self.make_job_agent = make_job_agent    # None: no jobs (the engine says so by not offering them)
        self.job_store = job_store
        self.job_beat = job_beat
        # The drive card declines itself after drive.CARD_SECONDS in the app; the engine waits a
        # little longer so the app's own No always arrives first (D-170).
        self.drive_wait = drive_wait
        self.job_run: _JobRun | None = None     # the one job, queued, working or parked
        # Schedules (D-172): off until the app says `schedules_set` true (an app that doesn't know
        # them never turns them on). The clock and the time zone are passed in for the tests.
        self.clock = clock
        self.tz = tz
        self.schedule_tick = schedule_tick      # None: no looking thread (the tests call schedule_tick_once)
        self.schedules_on = False
        self._tick_thread: threading.Thread | None = None
        self._tick_stop = threading.Event()
        # "Not now" is remembered for 30 minutes (D-172): in memory, per job, "fg" for the conversation.
        self.declines = gate_mod.DeclineMemory(clock)
        # The link to the browser extension (benji/browser_link.py), or None: off until the app
        # says `browser_set` (D-143). Its state goes to the app as `browser` events.
        self.browser_link = browser_link
        self.browser_always: list[str] = []     # sites the user set to always allow reading (Settings; D-171)
        if browser_link is not None:
            browser_link.on_state = lambda state: self._emit({"type": "browser", "state": state})
        self.exiting = False
        # The user's policy.json, read again at each turn (it can only restrict); and the warm-up
        # itself, replaceable in tests (D-173).
        self.policy_for = policy_for or (lambda: policy_mod.NONE)
        self.warm = warm or _resolve_host
        self.app_caps: frozenset | None = None   # what the app said it can do in `hello`; None: nothing said
        self.last_call_at = 0.0                 # when a turn last ran (monotonic): a warm-up is for a cold start
        self.last_prewarm_at = 0.0
        self.answer_log_path = answer_log_path   # answers.jsonl, or None (BENJI_ANSWER_LOG=0)
        self._emit = emit
        self.info = info                    # provider, model, destination, version
        self.approval_timeout = approval_timeout
        self.history: list[dict] = []       # committed conversation (neutral messages)
        self.earlier_dropped = False        # older exchanges of this conversation are gone
        self.last_committed: str | None = None   # the turn whose answer ends the history
        self.note = ""                      # the conversation's private note (keep_note), given back each turn
        self.turn: _Turn | None = None
        self.greeted = False
        self.lock = threading.RLock()   # guards history, the current turn, and turn events

    # ---- output ---------------------------------------------------------------

    def emit(self, event: dict, turn: _Turn | None = None) -> None:
        """Send an event. Events from a cancelled turn are dropped, except its own `done`."""
        with self.lock:
            if turn is not None and turn.cancelled.is_set():
                return
            if turn is not None:
                turn.log.append(event)
            self._emit(event)

    def error(self, code: str, text: str, turn_id: str | None = None) -> None:
        if code in audit.ERROR_CODES:       # the code and where it came from; `text` can quote the user
            audit.error("serve", code, run=turn_id if isinstance(turn_id, str) and audit._ID.match(turn_id) else "")
        event = {"type": "error", "code": code, "text": text}
        if turn_id is not None:
            event["id"] = turn_id
        self._emit(event)

    # ---- input ----------------------------------------------------------------

    def handle_line(self, line: str) -> bool:
        """Handle one request line. Returns False when the server should stop."""
        line = line.strip()
        if not line:
            return True
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            self.error("bad_request", "not a JSON object")
            return True
        if not isinstance(req, dict) or not isinstance(req.get("type"), str):
            self.error("bad_request", "a request is a JSON object with a string 'type'")
            return True
        return self.handle(req)

    def handle(self, req: dict) -> bool:
        kind = req["type"]
        if kind == "hello":
            if req.get("protocol") != PROTOCOL:
                self.error("protocol", f"this Benji speaks protocol {PROTOCOL}")
                return True
            self.greeted = True
            self.app_caps = _app_caps(req.get("capabilities"))
            self._emit({"type": "ready", "protocol": PROTOCOL, **self.info,
                        "approval_timeout": self.approval_timeout, "jobs": self._jobs_on(),
                        "browser": self._jobs_on() and self.browser_link is not None,
                        "schedules": self._jobs_on(), "capabilities": list(ENGINE_CAPS)})
            self._show_last_job()
            return True
        if not self.greeted:
            self.error("protocol", "send hello first")
            return True
        handler = {
            "send": self._send, "approve": self._approve, "cancel": self._cancel,
            "cut_off": self._cut_off, "restore": self._restore, "reset": self._reset,
            "screen_result": self._screen_result, "job_steer": self._job_steer,
            "job_stop": self._job_stop, "job_dismiss": self._job_dismiss, "browser_set": self._browser_set,
            "browser_always": self._browser_always_set,
            "drive_stop": self._drive_stop,
            "job_continue": self._job_continue, "job_schedule": self._job_schedule,
            "schedules_set": self._schedules_set,
            "prewarm": self._prewarm,
        }.get(kind)
        if kind == "shutdown":
            self._cancel_current()
            return False
        if handler is None:
            self.error("bad_request", f"unknown request type: {kind}")
            return True
        try:
            handler(req)
        except Exception as e:  # noqa: BLE001 — a bad request must not take the server down
            print(audit.safe_traceback(e), file=sys.stderr)     # no message: it can quote what the user typed
            audit.error("serve", "internal", e)
            self.error("internal", f"{type(e).__name__}: {e}",
                       req["id"] if isinstance(req.get("id"), str) else None)
        return True


    # ---- background jobs (D-130 step 1) ---------------------------------------

    def _jobs_on(self) -> bool:
        return self.job_store is not None and self.make_job_agent is not None

    def _live_job_ids(self) -> frozenset[str]:
        with self.lock:
            run = self.job_run
            return frozenset({run.record["id"]}) if run is not None and run.live else frozenset()

    def _turn_for(self, turn_id: str) -> _Turn | None:
        """The foreground turn, or the job, that has this id."""
        t = self.turn
        if t is not None and t.id == turn_id:
            return t
        run = self.job_run
        return run.turn if run is not None and run.turn.id == turn_id else None

    def _job_folder(self, record: dict):
        return self.job_store.path(record["id"])

    def _sched_file(self, record: dict):
        """Where the job's schedule is kept: beside its folder, never in it (schedule.file_for)."""
        return schedule_mod.file_for(self.job_store.root, record["id"])

    def _schedule_of(self, record: dict) -> dict | None:
        """The job's schedule as the app shows it, or None. A schedule file that can't be read is
        moved aside and reported once (it is gone, not guessed at)."""
        state, problem = schedule_mod.load(self._sched_file(record))
        if problem:
            audit.event("job_schedule", record["id"], job=record["id"], action="bad_file")
        return schedule_mod.shown(state, self.schedules_on)

    def _quiet(self, run: _JobRun, state: str) -> bool:
        """A repeat run that nothing needs the user for: no peek, no sound (D-172). Needs-you is
        never quiet; a finished run is quiet only if it found nothing new; a failure is quiet unless
        it just paused the schedule."""
        record = run.record
        if not record.get("unattended") or state == "needs-you":
            return False
        if state == "done":
            return not record.get("news", True)
        if state == "failed":
            return not run.auto_paused
        return True

    def _snapshot(self, run: _JobRun) -> dict:
        snap = jobs_mod.snapshot(run.record, run.live, run.line, schedule=self._schedule_of(run.record))
        snap["quiet"] = self._quiet(run, snap["state"])
        return snap

    def _job_changed(self, run: _JobRun, code: str | None = None) -> None:
        """Save the record and tell the app what the job is now. A change of state is also written
        to the audit log (once per state: a progress line is not a state)."""
        with self.lock:
            self.job_store.save(run.record)
            snap = self._snapshot(run)
            self._emit({"type": "job", "job": snap})
            state = _AUDIT_STATE.get(snap["state"], snap["state"])
            if state == "failed" and run.record.get("error") == jobs_mod.INTERRUPTED:
                state, code = "interrupted", "interrupted"
            if state != run.audited:
                run.audited = state
                audit.event("job_state", run.record["id"], job=run.record["id"], state=state,
                            code=code if state in ("failed", "interrupted", "stopped") else None)

    def _emit_record(self, record: dict) -> None:
        """A `job` event for a job that has no run in this process (its schedule changed, say)."""
        live = self.job_run is not None and self.job_run.record["id"] == record["id"] and self.job_run.live
        if live:
            self._job_changed(self.job_run)
            return
        self._emit({"type": "job", "job": jobs_mod.snapshot(record, False, schedule=self._schedule_of(record))})

    def _show_last_job(self) -> None:
        """At the app's `hello`: a job the engine lost in a restart is marked failed, and the
        newest job the user hasn't cleared is shown (the row survives an app restart)."""
        if not self._jobs_on():
            return
        for lost in self.job_store.recover():
            audit.event("job_state", lost, job=lost, state="interrupted", code="interrupted")
        record = self.job_store.latest()
        if record is not None:
            self._emit_record(record)

    def _start_job(self, turn: _Turn, agent: Agent, title: str, brief: str, sites=None, repeat=None,
                   done_when: str = "") -> str:
        """start_job's handler, on the foreground turn's worker: make the job and its folder, and
        start it after a short beat in which the user can cancel. The job inherits the turn's taint.
        `sites`: origins the user approved on the card for this job to read in their Chrome (tools.py
        asked before calling here); only if the browser switch is still on. `repeat`: a schedule the
        user approved on the card. The brief is built here, in code, from the model's stated goal and
        a bounded slice of what the user said in this conversation (D-172)."""
        with self.lock:
            if sites and not self.browser_on:
                return "[error] Browser access for jobs was turned off; start the job without sites."
            run = self.job_run
            if run is not None and run.live:
                return (f"[refused] A job is already running ({run.record['title']}). Tell the user it has "
                        "to finish or be stopped before another one starts; don't start it.")
            tainted = agent.ctx.taint_source if agent.ctx.tainted else ""
            text, parts = jobs_mod.handoff_brief(brief, done_when, jobs_mod.earlier_said(agent.messages, turn.text),
                                                 current=turn.text)
            record = self.job_store.create(title, text, user_words=turn.text, tainted_by=tainted,
                                           taints=agent.ctx.taints,
                                           browser=browser_mod.new_record_grant(sites) if sites else None)
            record["handoff"] = parts
            for origin in sites or []:
                audit.event("browser_grant", record["id"], job=record["id"], host=audit.host_of(origin), how="start")
            if repeat is not None:
                self._write_schedule(record, repeat)
            self._begin_run(record)
        again = f" It repeats: {schedule_mod.describe(repeat).lower()}, while Benji is open." if repeat else ""
        return (f"[ok] Job started: {record['title']}.{again} It begins in a moment, the user can cancel it, and "
                "it keeps going while they do other things. Say so in one short sentence; don't wait for it.")

    def _begin_run(self, record: dict, beat: float | None = None) -> _JobRun:
        """Make the record's current run live and start its worker. Under the lock."""
        with self.lock:
            run = self.job_run = _JobRun(record, beat)
            self._job_changed(run)
        threading.Thread(target=self._run_job, daemon=True, args=(run,)).start()
        return run

    def _run_job(self, run: _JobRun) -> None:
        record, turn = run.record, run.turn
        if turn.cancelled.wait(self.job_beat if run.beat is None else run.beat):   # the beat: Esc (job_stop) ends it here
            self._finish_job(run, "stopped")
            return
        with self.lock:
            record.update(status="running", started_at=time.time())
            self._job_changed(run)
        folder = self.job_store.path(record["id"])
        agent = None
        try:
            def on_tool(name: str, inp: dict) -> None:
                run.line = JOB_LINES.get(name, "Working")
                self._job_changed(run)
            agent = self.make_job_agent(record, lambda reason: self._ask_job(run, reason), on_tool,
                                        turn.cancelled.is_set)
            agent.ctx.live_job_ids = self._live_job_ids
            agent.allow_jobs(self.job_store)            # recall, not start: a job doesn't start jobs
            if record.get("browser") and self.browser_on:   # its approved sites, if the switch is still on
                agent.allow_browser(browser_mod.Grant(record, lambda: self._job_changed(run)), self.browser_link,
                                    always=self.browser_always, on_user_stop=lambda: self._stop_job(run),
                                    act=self._app_can("browser_act"), upload=self._app_can("browser_upload"))
            agent.set_run(record["id"], "job")
            agent.ctx.unattended = bool(record.get("unattended"))    # nobody watching: only reading runs unasked
            agent.max_steps = JOB_MAX_STEPS
            agent.wrap_at_limit = True
            agent.patience = jobs_mod.WAIT_LIMIT_UNATTENDED if record.get("unattended") else jobs_mod.WAIT_LIMIT
            agent.on_wait = lambda reason: self._job_waiting(run, reason)
            agent.on_step = lambda step: self._job_step_note(run, step)
            agent.declines, agent.decline_scope = self.declines, record["id"]
            agent.last_answer = lambda: run.turn.last_why
            agent.max_tool_calls = JOB_MAX_TOOL_CALLS
            agent.poll_steer = lambda: self._take_steers(run)
            agent.on_tool_done = lambda name, inp, result: self._job_tool_done(run, name, inp, result)
            with self.lock:
                run.agent = agent
                if turn.cancelled.is_set():
                    agent.stop()
            answer = agent.send(jobs_mod.brief_message(record), user_words=record["user_words"],
                                tainted_by=record["tainted_by"], taints=jobs_mod.record_taints(record))
        except ProviderError as e:
            audit.error("job", "provider", e, record["id"])
            self._finish_job(run, "failed", error=jobs_mod.plain_failure(e), agent=agent, code="provider_error")
        except Exception as e:  # noqa: BLE001 — a job never takes the server down
            print(audit.safe_traceback(e), file=sys.stderr)
            audit.error("job", "internal", e, record["id"])
            self._finish_job(run, "failed", error=jobs_mod.plain_failure(e), agent=agent, code="internal_error")
        else:
            if turn.cancelled.is_set() or answer == CANCELLED:
                self._finish_job(run, "stopped", agent=agent)
            elif answer.startswith(STOPPED_AT_MAX):
                # The step cap: not a silent failure. The job's last, tool-less call (or code, if that
                # gave nothing) says what is done and what is left; the row says it stopped at the limit.
                wrap = answer.split(LIMIT_MARK, 1)[1] if LIMIT_MARK in answer else ""
                self._finish_job(run, "stopped", answer=wrap, agent=agent, folder=folder, code="step_limit", limit=True)
            elif run.warned:
                # Code told it the steps were nearly out and it did as told, so the run ended before the
                # cap: still the limit, not "done" (D-177). Decided from the warning, never from its words.
                self._finish_job(run, "stopped", answer=answer, agent=agent, folder=folder, code="step_limit", limit=True)
            else:
                self._finish_job(run, "finished", answer=answer, agent=agent, folder=folder)
        if agent is not None and agent.last_usage.get("calls"):
            print(f"[Benji] job {record['id']}: {agent.last_usage['calls']} model calls", file=sys.stderr)

    def _job_waiting(self, run: _JobRun, reason: str) -> None:
        """The job is waiting out a bad connection, or ("") is back. The row stays `working` and says so."""
        with self.lock:
            was, run.waiting = run.waiting, reason
            if reason == was:
                return
            run.line = JOB_WAIT_LINES.get(reason, "Working")
            self._job_changed(run)
            audit.event("job_wait", run.record["id"], job=run.record["id"], state="waiting" if reason else "back",
                        reason=reason or was)

    def _job_step_note(self, run: _JobRun, step: int) -> str:
        """What goes in front of a running job after step `step` (D-172): its brief, rules and grants
        read to it again at fixed intervals and whenever it comes back from a park, and a warning when
        the steps are nearly out. Decided in code from the step count and the park."""
        with self.lock:
            resumed, run.resumed = run.resumed, False
            run.step = step
            parts = []
            if jobs_mod.reread_due(step, resumed):
                reason = "resume" if resumed else "interval"
                parts.append(jobs_mod.reread_message(run.record, reason))
                audit.event("job_reread", run.record["id"], job=run.record["id"], reason=reason)
            if JOB_MAX_STEPS - step == jobs_mod.LIMIT_WARN_LEFT:
                run.warned = True
                parts.append(jobs_mod.limit_warning(jobs_mod.LIMIT_WARN_LEFT))
        return "\n\n".join(parts)

    def _finish_job(self, run: _JobRun, status: str, error: str = "", answer: str = "",
                    agent: Agent | None = None, folder=None, code: str | None = None, limit: bool = False) -> None:
        record = run.record
        with self.lock:
            body = ""
            if status == "finished":
                body, record["turn_end"] = jobs_mod.build_turn_end(answer, folder)
            elif limit and folder is not None:
                body, record["turn_end"] = jobs_mod.limit_end(record, folder, answer, run.step or JOB_MAX_STEPS, JOB_MAX_STEPS)
                record["stop_reason"] = "limit"
            if self.exiting and status == "stopped":
                status, error = "failed", jobs_mod.INTERRUPTED
            self._note_job_taint(run, agent)
            now = time.time()
            record.update(status=status, pending=None, error=error, finished_at=now)
            news = True
            if status == "finished":
                news = jobs_mod.is_news(record.get("last_result"), record["turn_end"])
                record["last_result"] = jobs_mod.result_of(record["turn_end"])
                if news:
                    record["dismissed"] = False     # news is worth the row coming back
            elif limit:
                record["last_result"] = jobs_mod.result_of(record["turn_end"])
            record["news"] = news
            run.live = False
            run.line = ""
            self._close_job_tabs(record)
            self._run_schedule(run, status, self.clock())
            try:
                # A repeat run with nothing new, or a failed one after a good report, keeps its own
                # copy in reports/ but leaves report.md (what recall reads) as it was.
                keep = news and (status != "failed" or not record.get("last_result"))
                jobs_mod.write_report(self.job_store, record, body, latest=keep)
            except OSError as e:
                print(f"[Benji] job {record['id']}: no report ({type(e).__name__})", file=sys.stderr)
                audit.error("job", "job_report", e, record["id"])
            outcome = ("limit" if limit else "stopped" if status == "stopped" else "failed" if status == "failed"
                       else "news" if news else "nothing_new")
            audit.event("job_run", record["id"], job=record["id"], how=record.get("kind", "first"),
                        outcome=outcome, n=int(record.get("run") or 1))
            self._job_changed(run, code)

    def _close_job_tabs(self, record: dict) -> None:
        """A job that used Chrome has ended, however it ended: ask the extension to close the tabs this
        job opened (only those; one the user dragged into the group stays). Best effort, off this thread."""
        link = self.browser_link
        if not record.get("browser") or link is None or not link.connected:
            return

        def close() -> None:
            try:
                link.call("close", {}, timeout=15)
            except Exception:  # noqa: BLE001 — a missed close is not an error worth more than a left-open tab
                pass
        threading.Thread(target=close, daemon=True).start()

    def _run_schedule(self, run: _JobRun, status: str, now: float) -> None:
        """The run ended: plan the schedule's next run from now, count a failure, and pause it
        after three in a row. A run the user stopped, or that stopped because all schedules went
        off, is neither a success nor a failure. Under the lock."""
        record = run.record
        state, problem = schedule_mod.load(self._sched_file(record))
        if problem:
            audit.event("job_schedule", record["id"], job=record["id"], action="bad_file")
        if state is None:
            return
        if status == "finished":
            schedule_mod.after_run(state, now, True, self.tz)
        elif status == "failed" and record.get("error") != jobs_mod.INTERRUPTED:
            if schedule_mod.after_run(state, now, False, self.tz):
                run.auto_paused = True
                audit.event("job_schedule", record["id"], job=record["id"], action="auto_paused")
        else:
            schedule_mod.skip_run(state, now, self.tz)
        schedule_mod.save(self._sched_file(record), state)

    def _note_job_taint(self, run: _JobRun, agent: Agent | None) -> None:
        """The job's record keeps what it has read: the kinds (the rules' input) and the words for a card."""
        if agent is None or not agent.ctx.tainted:
            return
        record = run.record
        if agent.ctx.taints != jobs_mod.record_taints(record) or not record.get("tainted_by"):
            record["taints"] = [k for k in gate_mod.TAINT_KINDS if k in agent.ctx.taints]
            record["tainted_by"] = agent.ctx.taint_source

    def _job_tool_done(self, run: _JobRun, name: str, inp: dict, result: str) -> None:
        self._note_job_taint(run, run.agent)      # the row says so as soon as it is true
        event = activity_for(name, inp, result)
        run.line = f"Saved {event['name']}" if event and event.get("name") else ""
        self._job_changed(run)

    def _ask_job(self, run: _JobRun, reason: str) -> bool:
        """A job's approve callback: park the job as needs-you and wait. No timeout: an answer
        that doesn't come leaves the job parked, not failed or declined; stopping the job answers No."""
        turn, record = run.turn, run.record
        if turn.cancelled.is_set():
            return False
        with turn.lock:
            turn.next_request += 1
            request = f"a{turn.next_request}"
            answers: queue.Queue = queue.Queue(maxsize=1)
            turn.approvals[request] = answers
        action, _, target = reason.partition(": ")
        asked_at = time.monotonic()
        tool, code = run.agent.gate_now if run.agent is not None else ("", "")
        audit.event("approval_asked", record["id"], request=request, scope="job", tool=tool or None, code=code or None)
        with self.lock:
            record["pending"] = {"request": request, "action": action, "target": target, "asked_at": time.time()}
            self._job_changed(run)
        decision, why = False, "cancelled"
        while True:
            try:
                decision, why = answers.get(timeout=0.25), None
                break
            except queue.Empty:
                if turn.cancelled.is_set():
                    break
        with turn.lock:
            turn.approvals.pop(request, None)
        why = why or ("yes" if decision else "no")
        turn.last_why = why                 # decline memory reads this: only the user's own No counts
        with self.lock:
            record["pending"] = None
            run.resumed = True              # back from a park: the brief is read to it again (D-172)
            self._job_changed(run)
        # The card's words hold commands and paths: the engine's log gets the tool and the rule, never them.
        print(f"[Benji] job approval {request} ({why}): {tool}/{code}", file=sys.stderr)
        audit.event("approval_answered", record["id"], request=request, scope="job",
                    who="stop" if why == "cancelled" else "row", decision="yes" if decision else "no",
                    waited_ms=int((time.monotonic() - asked_at) * 1000))
        return decision

    def _take_steers(self, run: _JobRun) -> list[str]:
        with self.lock:
            said, run.steers = run.steers, []
        return said

    # ---- continue, schedules (D-172) ------------------------------------------------

    def _write_schedule(self, record: dict, spec: dict) -> bool:
        """Create or change the job's schedule from a spec the user approved on a card. True when
        there was one before. Under the lock."""
        folder, now = self._sched_file(record), self.clock()
        state, _ = schedule_mod.load(folder)
        existed = state is not None
        if state is None:
            state = schedule_mod.new_state(spec, now, self.tz)
        else:
            state["spec"] = spec
            schedule_mod.resume(state, now, self.tz)
        schedule_mod.save(folder, state)
        audit.event("job_schedule", record["id"], job=record["id"], action="changed" if existed else "set")
        return existed

    def _set_schedule(self, ident: str, spec: dict | None) -> str:
        """schedule_job's handler (the card was answered Yes): set, change or remove a schedule."""
        with self.lock:
            record = self.job_store.resolve(ident) if ident else self.job_store.latest()
            if record is None:
                return "[error] no such job (find_jobs lists them)"
            folder = self._sched_file(record)
            if spec is None:
                schedule_mod.remove(folder)
                audit.event("job_schedule", record["id"], job=record["id"], action="removed")
                self._emit_record(self.job_store.load(record["id"]) or record)
                return f"[ok] “{record['title']}” no longer repeats."
            self._write_schedule(record, spec)
            self._emit_record(self.job_store.load(record["id"]) or record)
        note = "" if self.schedules_on else " Schedules are turned off in Benji's settings, so it waits until they are on."
        return (f"[ok] “{record['title']}” will repeat: {schedule_mod.describe(spec).lower()}. It runs only while Benji is open "
                f"and the Mac is awake, and only reads; anything else waits for the user.{note}")

    def _job_schedule(self, req: dict) -> None:
        """The row's schedule buttons: pause, resume or delete. The user's own button, so no card."""
        job_id, action = req.get("job"), req.get("action")
        record = self.job_store.load(job_id) if self._jobs_on() and isinstance(job_id, str) and jobs_mod.valid_id(job_id) else None
        if record is None or action not in ("pause", "resume", "delete"):
            self.error("bad_request", "job_schedule needs a 'job' and an 'action' of pause, resume or delete",
                       job_id if isinstance(job_id, str) else None)
            return
        with self.lock:
            folder = self._sched_file(record)
            state, problem = schedule_mod.load(folder)
            if problem:
                audit.event("job_schedule", record["id"], job=record["id"], action="bad_file")
            if state is None and action != "delete":
                self.error("bad_request", "job_schedule: this job has no schedule", job_id)
            elif action == "delete":
                schedule_mod.remove(folder)
                audit.event("job_schedule", record["id"], job=record["id"], action="removed")
            elif action == "pause":
                schedule_mod.pause(state, "user")
                schedule_mod.save(folder, state)
                audit.event("job_schedule", record["id"], job=record["id"], action="paused")
            else:
                schedule_mod.resume(state, self.clock(), self.tz)
                schedule_mod.save(folder, state)
                audit.event("job_schedule", record["id"], job=record["id"], action="resumed")
            self._emit_record(record)

    def _job_continue(self, req: dict) -> None:
        """Continue a job that stopped or didn't finish, from the row: another run of the same job,
        in its folder, told what was done. The user's own button; it also lifts any "not now"."""
        job_id = req.get("job")
        record = self.job_store.load(job_id) if self._jobs_on() and isinstance(job_id, str) and jobs_mod.valid_id(job_id) else None
        with self.lock:
            run = self.job_run
            if record is None or record.get("status") not in ("failed", "stopped"):
                self.error("bad_request", "job_continue: no such stopped job", job_id if isinstance(job_id, str) else None)
                return
            if run is not None and run.live:
                self.error("bad_request", "job_continue: another job is running", job_id)
                return
            self.declines.clear(record["id"])
            jobs_mod.begin_run(record, "continued", self.clock(), unattended=False)
            self._begin_run(record)

    def _schedules_set(self, req: dict) -> None:
        """The app's global switch for schedules (Settings): `enabled` true lets due schedules run
        while the engine is up; false turns them all off at once, and stops a repeat run in flight.
        Nothing else, and no page or model text, can turn it on."""
        enabled = req.get("enabled")
        if not isinstance(enabled, bool):
            self.error("bad_request", "schedules_set needs a boolean 'enabled'")
            return
        if not self._jobs_on():
            self.error("bad_request", "this engine has no jobs")
            return
        with self.lock:
            changed = enabled != self.schedules_on
            self.schedules_on = enabled
            run = self.job_run
            if not enabled and run is not None and run.live and run.record.get("unattended"):
                run.switch_off = True
                self._stop_job(run)
            if changed:
                audit.event("job_schedule", action="switch_on" if enabled else "switch_off")
        if enabled and self.schedule_tick and (self._tick_thread is None or not self._tick_thread.is_alive()):
            self._tick_thread = threading.Thread(target=self._tick_loop, daemon=True)
            self._tick_thread.start()

    def _schedules_blocked(self) -> bool:
        """The user's policy.json switches off jobs or schedule_job, or the app said (in `hello`) that
        it cannot carry schedules out: nothing repeats. Both only ever remove (D-173)."""
        policy = self.policy_for()
        if policy.blocks_family("jobs") or policy.blocks("schedule_job") or policy.blocks("start_job"):
            return True
        return self.app_caps is not None and "schedules" not in self.app_caps

    def _tick_loop(self) -> None:
        while not self._tick_stop.wait(self.schedule_tick):
            try:
                self.schedule_tick_once()
            except Exception as e:  # noqa: BLE001 — a bad schedule never takes the engine down
                print(audit.safe_traceback(e), file=sys.stderr)
                audit.error("serve", "internal", e)

    def schedule_tick_once(self, now: float | None = None) -> list[str]:
        """Look at every job's schedule once; start at most one due run, unattended, when no job is
        running. Returns the ids started (the tests drive this with a fake clock). A run missed
        while the Mac slept or Benji was closed is caught up once, because a run plans its next one
        from the time it ran; a clock that went back is brought in (schedule.clamp)."""
        if not self.schedules_on or not self._jobs_on() or self._schedules_blocked():
            return []
        now = self.clock() if now is None else now
        started: list[str] = []
        with self.lock:
            busy = self.job_run is not None and self.job_run.live
            for record in sorted(self.job_store.all(), key=lambda r: r.get("created_at", 0)):
                folder = self._sched_file(record)
                state, problem = schedule_mod.load(folder)
                if problem:
                    audit.event("job_schedule", record["id"], job=record["id"], action="bad_file")
                if state is None:
                    continue
                if schedule_mod.clamp(state, now, self.tz):
                    schedule_mod.save(folder, state)
                    audit.event("job_schedule", record["id"], job=record["id"], action="clock_back")
                if busy or started or not schedule_mod.is_due(state, now):
                    continue
                if record.get("status") in ("queued", "running"):
                    continue                    # a record with no worker: hello's recover() settles it
                state["next_at"] = schedule_mod.next_after(state["spec"], now, self.tz)   # this slot is used
                schedule_mod.save(folder, state)
                jobs_mod.begin_run(record, "scheduled", now, unattended=True)
                audit.event("job_schedule", record["id"], job=record["id"], action="started")
                self._begin_run(record, beat=0.0)
                started.append(record["id"])
        return started

    def _live_job(self, req: dict, kind: str) -> _JobRun | None:
        job_id = req.get("job")
        run = self.job_run
        if not isinstance(job_id, str) or run is None or run.record["id"] != job_id or not run.live:
            self.error("bad_request", f"{kind}: no such job is running", job_id if isinstance(job_id, str) else None)
            return None
        return run

    def _job_steer(self, req: dict) -> None:
        text = req.get("text")
        if not isinstance(text, str) or not text.strip():
            self.error("bad_request", "job_steer needs a string 'job' and non-empty 'text'")
            return
        run = self._live_job(req, "job_steer")
        if run is None:
            return
        said = " ".join(text.split())[:jobs_mod.MAX_STEER_CHARS]
        self.declines.clear(run.record["id"])       # the user steered it on: a "not now" no longer holds (D-172)
        with self.lock:
            run.steers.append(said)
            run.record["steers"].append({"at": time.time(), "text": said})
            self.job_store.save(run.record)

    def _job_stop(self, req: dict) -> None:
        run = self._live_job(req, "job_stop")
        if run is None:
            return
        self._stop_job(run)

    def _stop_job(self, run: _JobRun) -> None:
        """Stop the job: kill its tool processes, cut a model call off, answer a waiting approval No.
        Its worker then ends it as `stopped`."""
        turn = run.turn
        with self.lock:
            turn.cancelled.set()
            if run.agent is not None:
                run.agent.stop()
        with turn.lock:
            for answers in turn.approvals.values():
                try:
                    answers.put_nowait(False)
                except queue.Full:
                    pass

    def _job_dismiss(self, req: dict) -> None:
        job_id = req.get("job")
        record = self.job_store.load(job_id) if self._jobs_on() and isinstance(job_id, str) and jobs_mod.valid_id(job_id) else None
        run = self.job_run
        if record is None or (run is not None and run.record["id"] == job_id and run.live):
            self.error("bad_request", "job_dismiss: no such finished job", job_id if isinstance(job_id, str) else None)
            return
        record["dismissed"] = True
        self.job_store.save(record)

    # ---- browser reach (D-143) ---------------------------------------------------

    @property
    def browser_on(self) -> bool:
        return self._jobs_on() and self.browser_link is not None and self.browser_link.running

    def _browser_set(self, req: dict) -> None:
        """The app's switch (Settings, Browser): `enabled` true opens the link for the extension's
        host, false closes it at once (a job in the middle of a read is told so). Nothing else, and
        no page, can turn it on."""
        enabled = req.get("enabled")
        if not isinstance(enabled, bool):
            self.error("bad_request", "browser_set needs a boolean 'enabled'")
            return
        if self.browser_link is None or not self._jobs_on():
            self.error("bad_request", "this engine has no browser link")
            return
        if enabled:
            try:
                self.browser_link.start()
            except OSError as e:
                print(f"[Benji] browser link: {type(e).__name__}", file=sys.stderr)   # never more than the kind
                self.error("browser", "Benji couldn't open the browser link.")      # logged by error()
        else:
            self.browser_link.stop()

    def _browser_always_set(self, req: dict) -> None:
        """The sites the user set, in Settings, to always allow reading (reading only: a card is still
        asked for acting, uploading and sending). Checked here, not trusted: a name that isn't an exact
        https origin is dropped, and the app is told what was kept."""
        raw = req.get("sites")
        if not isinstance(raw, list):
            self.error("bad_request", "browser_always needs a list 'sites'")
            return
        self.browser_always = browser_mod.normalize_always(raw)
        self._emit({"type": "browser_always", "sites": list(self.browser_always)})

    # ---- what the app can do, the user's policy, the warm-up (D-173) ------------------------------

    def _limited(self, info: TurnInfo) -> TurnInfo:
        """The turn's info with what the app said it cannot do (in `hello`) and what the user's
        policy.json switches off taken out. Both only ever remove; an app that said nothing is
        taken at its `send`."""
        caps = self.app_caps
        if caps is not None:
            changes: dict = {}
            if info.screen_actions and "screen_actions" not in caps:
                changes.update(screen_actions=False, screen_simple_steps=False)
            if info.jobs and "jobs" not in caps:
                changes.update(jobs=False)
            if info.browser and "browser" not in caps:
                changes.update(browser=False)
            if info.schedules and "schedules" not in caps:      # D-172: the app must say it can carry schedules out
                changes.update(schedules=False)
            if info.drive and "drive" not in caps:              # D-170: and that it can carry a drive out
                changes.update(drive=False)
            if info.allow_pointing and "pointing" not in caps:
                changes.update(allow_pointing=False, screen=None, screen_actions=False, screen_simple_steps=False)
            if info.cards and "cards" not in caps:
                changes.update(cards=False)
            if info.figures and "figures" not in caps:
                changes.update(figures=False)
            if changes:
                info = replace(info, **changes)
        return self.policy_for().restrict_turn(info)

    def _app_can(self, name: str) -> bool:
        """The app said, in `hello`, that it can carry this out. An app that sent no list (an older one) cannot
        be assumed to show the acting cards, so for acting the engine is stricter than for the older features."""
        return self.app_caps is not None and name in self.app_caps

    def _prewarm(self, req: dict) -> None:
        """The talk key went down: resolve the provider's host name now if the last call was a while
        ago, so the first call of the turn doesn't wait for it. Nothing is sent to the provider, no key
        is read; the time it took is the only thing written to the audit log (kind and number)."""
        now = time.monotonic()
        host = str(self.info.get("host") or "")
        recent = self.last_call_at and now - self.last_call_at < PREWARM_QUIET_SECONDS
        crowded = self.last_prewarm_at and now - self.last_prewarm_at < PREWARM_MIN_GAP
        if not host or recent or crowded or self.busy() or _on_this_mac(host):
            audit.event("prewarm", skipped=True)
            return
        self.last_prewarm_at = now
        threading.Thread(target=self._warm_host, args=(host,), daemon=True).start()

    def _warm_host(self, host: str) -> None:
        started, ok = time.monotonic(), True
        try:
            self.warm(host)
        except Exception:  # noqa: BLE001 — a warm-up that fails changes nothing
            ok = False
        audit.event("prewarm", skipped=False, ms=int((time.monotonic() - started) * 1000), ok=ok)

    def busy(self) -> bool:
        t = self.turn
        return t is not None and not t.finished.is_set() and not t.cancelled.is_set()

    # ---- requests -------------------------------------------------------------

    def _send(self, req: dict) -> None:
        turn_id, text = req.get("id"), req.get("text")
        if not isinstance(turn_id, str) or not turn_id or not isinstance(text, str) or not text.strip():
            self.error("bad_request", "send needs a string 'id' and non-empty 'text'",
                       turn_id if isinstance(turn_id, str) else None)
            return
        with self.lock:
            if self.busy():
                self.error("busy", "a turn is already running", turn_id)
                return
            images = []
            if req.get("image") is not None:
                try:
                    images.append(load_image(str(req["image"])))
                except ImageError as e:
                    self.error("bad_request", str(e), turn_id)
                    self._emit({"type": "done", "id": turn_id, "status": "error"})
                    return
            turn = _Turn(turn_id)
            turn.text = text
            turn.screen = req.get("screen") if isinstance(req.get("screen"), dict) else None
            turn.canvas = req.get("canvas") if isinstance(req.get("canvas"), dict) else None
            turn.jobs = req.get("jobs") is True and self._jobs_on()
            turn.schedules = turn.jobs and req.get("schedules") is True
            self.declines.clear("fg")       # a new message from the user: a "not now" from before no longer holds
            self.turn = turn
            self.last_call_at = time.monotonic()
            prior = trimmed(self.history)
            kept = _exchange_count(prior)
            self.earlier_dropped = self.earlier_dropped or kept < _exchange_count(self.history)
            info = replace(TurnInfo.from_request(req), history=kept, history_dropped=self.earlier_dropped,
                           browser=turn.jobs and self.browser_on, task=text, notes=True, note=self.note,
                           schedules=turn.schedules)
            info = self._limited(info)
            turn.jobs = turn.jobs and info.jobs
            turn.schedules = turn.jobs and turn.schedules and info.schedules
            self._emit({"type": "accepted", "id": turn_id})   # the app marks the message as heard
        worker = threading.Thread(target=self._run_turn, daemon=True,
                                  args=(turn, text, images, prior, info))
        worker.start()

    def _run_turn(self, turn: _Turn, text: str, images: list[dict], prior: list[dict],
                  info: TurnInfo) -> None:
        agent = None
        status = "ok"
        try:
            size = (info.screen.width, info.screen.height) if info.screen else None

            def on_tool(name: str, inp: dict) -> None:
                # A screen step's approval carries the step, so the app can word its card and
                # name the app it would act in.
                turn.asking_step = (tools_mod.screen_step(name, inp, size)[0]
                                    if info.screen_actions and name in tools_mod.SCREEN_TOOL_NAMES else None)
                self.emit({"type": "tool", "id": turn.id, "name": name, "detail": str(_tool_detail(inp))}, turn)
            agent = self.make_agent(
                lambda reason: self._ask(turn, reason),
                on_tool,
                turn.cancelled.is_set,
                info,
            )
            agent.set_run(turn.id, "turn")
            agent.declines, agent.decline_scope = self.declines, "fg"
            agent.last_answer = lambda: turn.last_why
            if info.screen_actions:
                agent.allow_screen_actions(
                    lambda step, mode=None, drive=False: self._screen_step(turn, step, mode, drive), size,
                    simple=info.screen_simple_steps)
            if info.drive and info.screen_actions and info.screen_simple_steps:
                # A drive (D-170): a foreground turn only (a job's agent never gets this), asked on its own card.
                agent.allow_drive(lambda goal: self._ask(turn, f"take over your screen: {goal}", drive_goal=goal),
                                  lambda event: self.emit({"type": "drive", "id": turn.id, **event}, turn))
            if turn.jobs:
                agent.ctx.live_job_ids = self._live_job_ids
                agent.allow_jobs(self.job_store,
                                 lambda title, brief, sites=None, repeat=None, done_when="": self._start_job(
                                     turn, agent, title, brief, sites, repeat, done_when),
                                 sites=self.browser_on,
                                 schedule=(lambda ident, spec: self._set_schedule(ident, spec)) if turn.schedules else None)
                if self.browser_on and info.browser and self._app_can("browser_act"):    # "summarise this page": the front tab, after a card (D-171, step 3)
                    agent.allow_active_tab(self.browser_link, self.browser_always)
            agent.allow_notes(lambda text: self._keep_note(turn, text))
            agent.messages = prior
            agent.on_tool_done = lambda name, inp, result: self._activity(turn, name, inp, result)
            deltas = Deltas(lambda event: self.emit({"type": event.pop("type"), "id": turn.id, **event}, turn),
                            info.allow_pointing, cards=info.cards)
            agent.on_text, agent.on_text_dropped = deltas.add, deltas.drop
            with self.lock:
                turn.agent = agent
                if turn.cancelled.is_set():
                    agent.stop()
            answer = agent.send(text, images=images or None)
        except ProviderError as e:
            audit.error("turn", "provider", e, turn.id)
            if providers_mod.is_safety_stop(e):         # the filter's stop is told as that, plainly (D-172)
                reason, words = "safety", providers_mod.SAFETY_STOP
            else:
                reason, words = errors_mod.explain(str(e))      # a refused key, no connection, a limit, a region... in plain words
            self.emit({"type": "error", "id": turn.id, "code": "provider", "reason": reason, "text": words}, turn)
            status = "error"
        except Exception as e:  # noqa: BLE001 — never let a turn take the server down
            print(audit.safe_traceback(e), file=sys.stderr)
            audit.error("turn", "internal", e, turn.id)
            self.emit({"type": "error", "id": turn.id, "code": "internal", "text": repr(e)}, turn)
            status = "error"
        else:
            with self.lock:
                if turn.cancelled.is_set():
                    return              # `done {cancelled}` was already sent
                self.history = committed(agent.messages)
                self.last_committed = turn.id
                if turn.note is not None:
                    self.note = turn.note
                turn.committed = True   # from here a cancel can't take it back
            turn.raw = answer
            answer = deltas.card_lines(answer)
            event = {"type": "answer", "id": turn.id, "text": answer, "targets": []}
            if info.allow_pointing:
                event.update(answer_marks(answer))
            deltas.finish(event["text"])
            self.emit(event, turn)
        self.last_call_at = time.monotonic()
        if agent is not None and agent.last_usage.get("calls"):
            self.emit({"type": "usage", "id": turn.id, **agent.last_usage}, turn)
        with self.lock:
            if turn.cancelled.is_set():
                return
            turn.finished.set()
            self._emit({"type": "done", "id": turn.id, "status": status})
        answer_log.record(self.answer_log_path, run=turn.id, raw=turn.raw, events=turn.log, screen=turn.screen,
                          canvas=turn.canvas, spoken=info.spoken, model=str(self.info.get("model", "")),
                          status=status)

    def _keep_note(self, turn: _Turn, text: str) -> str:
        """keep_note's store: held by the turn, and the conversation's once the turn commits, so a
        cancelled turn leaves the note as it was."""
        turn.note = text
        return ("[ok] noted. The user can't see it: now write your reply to them." if text
                else "[ok] note cleared. Now write your reply to the user.")

    def _activity(self, turn: _Turn, name: str, inp: dict, result: str) -> None:
        event = activity_for(name, inp, result)
        if event is not None:
            self.emit({"type": "activity", "id": turn.id, **event}, turn)

    def _ask(self, turn: _Turn, reason: str, drive_goal: str | None = None) -> bool:
        """The agent's approve callback: emit an approval and wait for the answer. The drive card
        (`drive_goal`, D-170) says so, names the goal, declines itself after drive.CARD_SECONDS, and
        only an answer that says it came from the app's own card (`via: card`) counts."""
        if turn.cancelled.is_set():
            return False
        with turn.lock:
            turn.next_request += 1
            request = f"a{turn.next_request}"
            answers: queue.Queue = queue.Queue(maxsize=1)
            turn.approvals[request] = answers
            if drive_goal is not None:
                turn.drive_cards.add(request)
        action, _, target = reason.partition(": ")
        event = {"type": "approval", "id": turn.id, "request": request, "action": action, "target": target}
        if drive_goal is not None:
            event["drive"] = {"goal": drive_goal, "seconds": drive_mod.CARD_SECONDS}
        step, turn.asking_step = turn.asking_step, None
        if step is not None:
            event["screen"] = step
        asked_at = time.monotonic()
        tool, code = turn.agent.gate_now if turn.agent is not None else ("", "")
        audit.event("approval_asked", turn.id, request=request, scope="turn", tool=tool or None, code=code or None)
        self.emit(event, turn)
        try:
            decision, why = answers.get(timeout=self.drive_wait if drive_goal is not None else self.approval_timeout), None
        except queue.Empty:
            decision, why = False, "timeout"
        with turn.lock:
            turn.approvals.pop(request, None)
            turn.drive_cards.discard(request)
            if why == "timeout":            # an answer that slipped in just before the pop
                try:
                    decision, why = answers.get_nowait(), None
                except queue.Empty:
                    pass
        if turn.cancelled.is_set():
            decision, why = False, "cancelled"
        why = why or ("yes" if decision else "no")
        turn.last_why = why
        self.emit({"type": "approval_result", "id": turn.id, "request": request,
                   "approved": decision, "why": why}, turn)
        print(f"[Benji] approval {request} ({why}): {tool}/{code}", file=sys.stderr)   # never the card's words
        audit.event("approval_answered", turn.id, request=request, scope="turn",
                    who={"timeout": "timeout", "cancelled": "stop"}.get(why, "card"),
                    decision="yes" if decision else "no", waited_ms=int((time.monotonic() - asked_at) * 1000))
        return decision

    def _screen_step(self, turn: _Turn, step: dict, mode: str | None = None, drive: bool = False) -> dict:
        """Ask the app to act on one step and wait for its result: {status, text, image} with
        `image` loaded (the screen after the step), or a failure. `mode` "free" or "quiet": the
        step wasn't asked about (D-126); the app checks it again and may answer "ask"."""
        if turn.cancelled.is_set():
            return {"status": "cancelled"}
        with turn.lock:
            turn.next_step += 1
            request = f"s{turn.next_step}"
            answers: queue.Queue = queue.Queue(maxsize=1)
            turn.screen_steps[request] = answers
        event = {"type": "screen_action", "id": turn.id, "request": request, "step": step}
        if mode is not None:
            event["mode"] = mode
        if drive:
            event["drive"] = True       # inside a consented drive: the app checks it by the drive's rules
        self.emit(event, turn)
        try:
            result = answers.get(timeout=SCREEN_STEP_TIMEOUT)
        except queue.Empty:
            result = {"status": "failed", "text": "Benji's app didn't answer in time; the step may not have happened."}
        with turn.lock:
            turn.screen_steps.pop(request, None)
        if turn.cancelled.is_set():
            return {"status": "cancelled"}
        image = None
        if result.get("status") == "done" and isinstance(result.get("image"), str):
            try:
                image = load_image(result["image"])
            except ImageError as e:
                print(f"[Benji] screen step {request}: {type(e).__name__}", file=sys.stderr)
                audit.error("turn", "image", e, turn.id)
        print(f"[Benji] screen step {request} ({result.get('status')}): {step.get('kind')}", file=sys.stderr)
        return {"status": result.get("status"), "text": result.get("text", ""), "image": image}

    def _screen_result(self, req: dict) -> None:
        turn_id, request, status = req.get("id"), req.get("request"), req.get("status")
        if not isinstance(turn_id, str) or not isinstance(request, str) or status not in SCREEN_STATUSES:
            self.error("bad_request", "screen_result needs a string 'id' and 'request' and a status of "
                       + ", ".join(SCREEN_STATUSES), turn_id if isinstance(turn_id, str) else None)
            return
        text, image = req.get("text"), req.get("image")
        result = {"status": status, "text": text if isinstance(text, str) else "",
                  "image": image if isinstance(image, str) else None}
        t = self.turn
        if t is None or t.id != turn_id:
            self.error("bad_request", "no such screen step is waiting", turn_id)
            return
        with t.lock:                    # same lock as _screen_step's pop
            answers = t.screen_steps.get(request)
            if answers is None:
                self.error("bad_request", "no such screen step is waiting", turn_id)
                return
            try:
                answers.put_nowait(result)
            except queue.Full:
                self.error("bad_request", "that screen step was already answered", turn_id)

    def _approve(self, req: dict) -> None:
        turn_id, request, decision = req.get("id"), req.get("request"), req.get("decision")
        if not isinstance(turn_id, str) or not isinstance(request, str):
            self.error("bad_request", "approve needs a string 'id' and 'request'",
                       turn_id if isinstance(turn_id, str) else None)
            return
        t = self._turn_for(turn_id)
        if t is None:
            self.error("bad_request", "no such approval is waiting", turn_id)
            return
        # Only the words "y" or "yes" approve; anything else (JSON true included) is a No.
        yes = isinstance(decision, str) and decision.strip().lower() in ("y", "yes")
        with t.lock:                    # same lock as _ask's pop: an answer is used or refused
            answers = t.approvals.get(request)
            if answers is None:
                self.error("bad_request", "no such approval is waiting", turn_id)
                return
            if request in t.drive_cards and yes and req.get("via") != "card":
                # A drive is agreed on the app's own card, by its button or key; nothing else (a spoken
                # yes, a script, a page) grants it (D-130, D-170). The card stays up and keeps waiting.
                self.error("bad_request", "a drive can only be agreed on the card", turn_id)
                return
            try:
                answers.put_nowait(yes)
            except queue.Full:
                self.error("bad_request", "that approval was already answered", turn_id)

    def _cancel(self, req: dict) -> None:
        t = self.turn
        if t is None or req.get("id") != t.id or t.finished.is_set() or t.cancelled.is_set():
            self.error("bad_request", "no such turn is running",
                       req["id"] if isinstance(req.get("id"), str) else None)
            return
        if t.committed:
            self.error("bad_request", "that turn is already finishing", t.id)
            return
        self._cancel_current()

    def _drive_stop(self, req: dict) -> None:
        """The user ended the drive (Esc, typing, a click, the Stop button, a long move of the mouse):
        the app says why. The drive ends at once and the turn takes no more screen steps. Nothing
        happens when no drive is on (a stray Esc)."""
        turn_id, reason = req.get("id"), req.get("reason", "user_stop")
        t = self.turn
        if not isinstance(turn_id, str) or t is None or t.id != turn_id or t.agent is None:
            self.error("bad_request", "drive_stop: no such turn is running", turn_id if isinstance(turn_id, str) else None)
            return
        if reason not in ("user_stop", "mouse", "typing", "click", "scroll", "app_stop"):
            reason = "user_stop"
        ctx = t.agent.ctx
        if ctx.drive is not None and ctx.drive.active:
            ctx.screen_stopped = True
            tools_mod.end_drive(ctx, reason)

    def _cancel_current(self) -> None:
        with self.lock:
            t = self.turn
            if t is None or t.finished.is_set() or t.cancelled.is_set() or t.committed:
                return
            t.cancelled.set()
            if t.agent is not None:
                t.agent.stop()          # kills a running tool process and its children
            self._emit({"type": "done", "id": t.id, "status": "cancelled"})
        with t.lock:                    # a waiting approval is answered "no" at once
            for answers in t.approvals.values():
                try:
                    answers.put_nowait(False)
                except queue.Full:
                    pass
            for steps in t.screen_steps.values():   # and a screen step stops waiting
                try:
                    steps.put_nowait({"status": "cancelled"})
                except queue.Full:
                    pass

    def _cut_off(self, req: dict) -> None:
        """The user cut the spoken answer of turn `id` off (D-122): the conversation keeps `reply`
        (what was said aloud, marked by the app) as that turn's answer, so the next turn doesn't
        assume the user heard the rest. A turn still running stops as for `cancel`, and its message
        stays with `reply` as the answer (its tool calls and results so far are not kept). A
        finished turn has its final answer replaced. Anything else (an older turn, a reset since) is
        refused with the turn's id, which the app drops."""
        turn_id, reply = req.get("id"), req.get("reply")
        if not isinstance(turn_id, str) or not turn_id or not isinstance(reply, str) or not reply.strip():
            self.error("bad_request", "cut_off needs a string 'id' and non-empty 'reply'",
                       turn_id if isinstance(turn_id, str) else None)
            return
        with self.lock:
            t = self.turn
            if t is not None and t.id == turn_id and not t.committed and self.busy():
                self._cancel_current()
                self.history = self.history + [
                    {"role": "user", "text": t.text},
                    {"role": "assistant", "text": reply, "tool_calls": []},
                ]
                self.last_committed = turn_id
                return
            last = self.history[-1] if self.history else None
            if turn_id == self.last_committed and last is not None and last.get("role") == "assistant":
                self.history = self.history[:-1] + [{**last, "text": reply}]
                return
        self.error("bad_request", "no answer of that turn to cut off", turn_id)

    def _restore(self, req: dict) -> None:
        if self.busy():
            self.error("busy", "can't restore while a turn is running")
            return
        try:
            self.history, dropped = history_from_exchanges(req.get("exchanges"))
        except HistoryError as e:
            self.error("bad_request", str(e))
            return
        # The app has already dropped older ones itself when it says so.
        self.earlier_dropped = dropped or req.get("dropped") is True

    def _reset(self, req: dict) -> None:
        if self.busy():
            self.error("busy", "can't reset while a turn is running")
            return
        self.history = []
        self.earlier_dropped = False
        self.last_committed = None
        self.note = ""


class Deltas:
    """The `delta` events of one turn (D-104). Text streams as the model writes it; when it turns
    out to come before a tool call, `delta_reset` takes it back. finish() makes the deltas after
    the last `delta_reset` join to exactly the answer's text: it sends what is missing, or a
    reset and the whole answer. With pointing, text that could still turn out to be trailing
    tags (and whitespace before them) is held back until it can't, so tags never stream.
    With `cards`, card lines are taken out first and sent as card events as each one closes
    (benji/cards.py); a reset takes those back too."""

    HOLD_UNCLOSED = 200     # an unclosed "[" further back than this is just text

    def __init__(self, emit: Callable[[dict], None], pointing: bool, cards: bool = False):
        self.emit, self.pointing = emit, pointing
        self.raw = ""       # model text since the last reset
        self.sent = ""      # what the deltas since the last reset say
        self.used = False   # any delta sent this turn
        self.lines = cards_mod.CardLines() if cards else None
        self.carded = 0     # card events sent since the last reset
        self.said = ""      # spoken text since the last reset (tags still in it)

    def add(self, piece: str) -> None:
        if self.lines is None:
            return self._add(piece)
        for kind, value in self.lines.feed(piece):
            if kind == "text":
                self.said += value
                self._add(value)
            else:
                self._card(kind, value, self._said_length(self.said))

    def card_lines(self, answer: str) -> str:
        """The answer's spoken text. Its card lines not yet sent go now (all of them when nothing
        streamed), then `card_end` when the reply had any."""
        if self.lines is None:
            return answer
        spoken, found = cards_mod.split(answer)
        for kind, value, at in found[self.carded:]:
            self._card(kind, value, self._said_length(spoken[:at]))
        if found:
            self.emit({"type": "card_end"})
        return spoken

    def _said_length(self, text: str) -> int:
        """Characters of `text` the user is shown: its tags don't count (they come out of the words)."""
        return pointing.said_length(text) if self.pointing else len(text)

    def _card(self, kind: str, value: object, at: int) -> None:
        self.carded += 1
        self.emit(cards_mod.event(kind, value, at))

    def _add(self, piece: str) -> None:
        self.raw += piece
        # Tags anywhere come out of the words (the beats form puts them between sentences).
        shown = pointing.strip_tags(self.raw[:self._stable(self.raw)]) if self.pointing else self.raw
        if len(shown) > len(self.sent) and shown.startswith(self.sent):
            self._send(shown[len(self.sent):])
            self.sent = shown

    def drop(self) -> None:
        if self.sent or self.carded:
            self.emit({"type": "delta_reset"})
        self.raw = self.sent = self.said = ""
        self.carded = 0
        if self.lines is not None:
            self.lines.reset()

    def finish(self, answer: str) -> None:
        if not self.used:
            return
        if answer.startswith(self.sent):
            if len(answer) > len(self.sent):
                self._send(answer[len(self.sent):])
        else:
            self.emit({"type": "delta_reset"})
            if answer:
                self._send(answer)
        self.sent = answer

    def _send(self, text: str) -> None:
        self.used = True
        self.emit({"type": "delta", "text": text})

    @classmethod
    def _stable(cls, text: str) -> int:
        """How much of `text` can't become part of a trailing tag run (pointing.parse_tags)."""
        end = len(text)
        while True:
            end = len(text[:end].rstrip())
            head = text[:end]
            if head.endswith("]") and "[" in head:
                end = head.rfind("[")
                continue
            start = head.rfind("[")
            tail = head[start:]
            if start >= 0 and "]" not in tail and "\n" not in tail and len(tail) <= cls.HOLD_UNCLOSED:
                end = start
                continue
            return end


def answer_marks(text: str) -> dict:
    """The answer's text and marks for the `answer` event, with pointing on: every tag taken out
    wherever it stands. `targets` as before; in the beats form (any tag before the end of the
    words) each target also has `at`, the characters of text before it, and edits of the drawing
    already up come as `edits` (chilly-whiteboard). Tags only at the end give the event as before."""
    shown, targets, edits = pointing.split_tags(text)
    beats = any(at < len(shown) for _, at in targets + edits)
    out: dict = {"text": shown, "targets": []}
    for t, at in targets:
        target = {"kind": t.kind, "coords": list(t.coords), "label": t.label}
        if beats:
            target["at"] = at
        out["targets"].append(target)
    if edits:
        out["edits"] = [{**e.event(), **({"at": at} if beats else {})} for e, at in edits]
    return out


def _app_caps(value: object) -> frozenset | None:
    """The names in the app's `hello.capabilities` that the engine knows, or None when it sent no
    usable list (an older app, or something that is not a list of short lowercase names)."""
    if not isinstance(value, list) or len(value) > 64:
        return None
    if not all(isinstance(x, str) and 0 < len(x) <= 32 for x in value):
        return None
    return frozenset(x for x in value if x in APP_CAPS)


def _on_this_mac(host: str) -> bool:
    from .config import _is_private_host
    name = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
    return _is_private_host(name.strip("[]").lower())


def _resolve_host(host: str) -> None:
    import socket
    name, _, port = host.partition(":") if host.count(":") == 1 else (host, "", "")
    socket.getaddrinfo(name, int(port) if port.isdigit() else 443, type=socket.SOCK_STREAM)


def _exchange_count(messages: list[dict]) -> int:
    return sum(m.get("role") == "user" for m in messages)


def _settled(m: dict) -> dict:
    """A message as the conversation keeps it: no screenshot ("[screenshot omitted]" in its
    place), a long tool result cut. Applying it twice changes nothing."""
    if m.get("role") == "user" and m.get("images"):
        m = {k: v for k, v in m.items() if k != "images"}
        m["text"] = m.get("text", "") + "\n[screenshot omitted]"
    elif m.get("role") == "tool" and m.get("images"):     # a screen step's screenshot (D-123)
        m = {k: v for k, v in m.items() if k != "images"}
        m["content"] = m.get("content", "") + "\n[screenshot omitted]"
    elif m.get("role") == "tool" and len(m.get("content", "")) > OLD_TOOL_RESULT_CHARS:
        m = {**m, "content": m["content"][:OLD_TOOL_RESULT_CHARS] + "\n[…cut]"}
    return m


def committed(messages: list[dict]) -> list[dict]:
    """The finished turn as it is kept: its screenshot dropped and long tool results cut once,
    here, so the conversation sent on every later turn is the same text and stays cacheable."""
    return [_settled(m) for m in messages]


def trimmed(messages: list[dict]) -> list[dict]:
    """A bounded copy of the committed conversation for the next turn: the recent exchanges that
    history.kept_count keeps (each sized by its user and assistant text, not its tool calls or
    results). Committed messages are already settled; anything else (an older history) is
    settled the same way, which leaves committed ones as they are."""
    starts = [i for i, m in enumerate(messages) if m.get("role") == "user"]
    sizes = [sum(len(m.get("text") or "") for m in messages[a:b] if m.get("role") in ("user", "assistant"))
             for a, b in zip(starts, starts[1:] + [len(messages)])]
    kept = kept_count(sizes)
    keep = messages[starts[len(starts) - kept]:] if kept < len(starts) else messages
    return [dict(_settled(m)) for m in keep]


# What the panel may say a tool did (D-98): a kind, and for a saved file its name only. Never a
# command, a path, contents or a query: those stay in the approval card and the engine's logs.
_ACTIVITY_KINDS = {
    "run_shell": "command", "write_file": "file_saved", "read_file": "file_read",
    "list_dir": "files_looked", "search_files": "files_looked", "web_fetch": "web",
    "web_search": "web", "run_applescript": "automation", "run_shortcut": "shortcut",
    "remember": "remembered", **{name: "screen" for name in tools_mod.SCREEN_TOOL_NAMES},
}
_DID_NOT_RUN = ("[declined]", "[error]", "[cancelled]", "[refused]")


def activity_for(name: str, inp: dict, result: str) -> dict | None:
    """The `activity` event for a tool that actually ran, or None (declined, failed, cancelled,
    or a tool not worth a line, like reading a skill)."""
    kind = _ACTIVITY_KINDS.get(name)
    if kind is None or not isinstance(result, str) or result.startswith(_DID_NOT_RUN):
        return None
    if kind == "screen" and not result.startswith("[done]"):    # refused, stopped or failed
        return None
    event = {"kind": kind}
    if kind == "file_saved":
        file_name = os.path.basename(str(inp.get("path", "")).rstrip("/"))
        if file_name:
            event["name"] = file_name
    return event


def _tool_detail(inp: dict) -> str:
    return inp.get("command") or inp.get("path") or inp.get("query") or inp.get("url") or ""


def run(server: Server, inp=None) -> int:
    """Read requests until shutdown, end of input or SIGTERM/SIGINT. Every way out cancels a
    running turn, which denies a waiting approval and kills the turn's tool processes."""
    inp = inp or sys.stdin
    try:
        for line in iter(inp.readline, ""):
            if not server.handle_line(line):
                break
    except KeyboardInterrupt:       # SIGTERM or SIGINT, via stop_on_signals()
        pass
    server._cancel_current()
    server.exiting = True           # a job stopped by quitting is interrupted, not stopped by the user
    if server.job_run is not None and server.job_run.live:
        server._stop_job(server.job_run)
        time.sleep(0.2)             # let its worker write the record
    if server.browser_link is not None:
        server.browser_link.stop()  # removes link.json: the token dies with the engine
    return 0


def isolate_stdio():
    """Give the protocol private copies of stdin and stdout, then point fd 1 at stderr and
    fd 0 at /dev/null, so a stray print, or anything a tool starts, can neither write into the
    event stream nor read requests meant for Benji. Returns (requests_in, events_out)."""
    proto_in = os.fdopen(os.dup(0), "r", encoding="utf-8", errors="replace")
    proto_out = os.fdopen(os.dup(1), "w", encoding="utf-8", errors="replace")
    sys.stdout.flush()
    os.dup2(2, 1)
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    os.close(devnull)
    sys.stdout = sys.stderr
    return proto_in, proto_out


def stop_on_signals() -> None:
    """SIGTERM and SIGINT end the read loop (as KeyboardInterrupt in the main thread)."""
    def interrupt(signum, frame):
        raise KeyboardInterrupt
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, interrupt)
        except (ValueError, OSError):
            pass


def stream_emitter(out=None) -> Callable[[dict], None]:
    """Write events as JSON lines. If the front-end has gone (broken pipe), stop writing."""
    lock = threading.Lock()
    dead = False

    def emit(event: dict) -> None:
        nonlocal dead
        line = json.dumps(event, ensure_ascii=False)
        with lock:
            if dead:
                return
            stream = out or sys.stdout
            try:
                stream.write(line + "\n")
                stream.flush()
            except (OSError, ValueError):
                dead = True
    return emit


# First-run model setup uses the same configuration and provider path as a conversation, but
# never builds an Agent: no history, memory, tools, screenshot, audit log or answer log is read.
MODEL_SETUP_SYSTEM = "This is a connection test. Reply OK."
MODEL_SETUP_MESSAGE = "Reply OK."


def model_setup(expected: dict | None = None) -> dict:
    """None probes only. Metadata from that probe explicitly authorizes one provider completion.

    Refuse changed configuration before sending anything, so the destination on the setup button
    is the destination actually tested. Only metadata and redacted errors return to the app.
    """
    from .config import load_config, is_secret_name
    from . import aliases
    from . import presets
    from urllib.parse import urlparse

    def safe(text):
        text = str(text)
        for name, value in os.environ.items():
            if is_secret_name(name) and value:
                text = text.replace(value, "[key]")
        return audit.redact(text)

    inherited = {aliases.canonical_name(name): os.environ[name]
                 for name in sorted(os.environ, key=aliases.rank, reverse=True)}
    keychain_names = set(os.getenv("BENJI_SETUP_KEYCHAIN_KEYS", "").split(","))
    try:
        cfg = load_config()
        local = bool(cfg.preset and cfg.preset.local and presets.is_local_host(urlparse(cfg.base_url).hostname))
        key_name = None
        if cfg.api_key:
            if cfg.preset and not cfg.preset.local and cfg.preset.is_own_host(urlparse(cfg.base_url).hostname or ""):
                key_name = next((name for name in cfg.preset.key_envs if os.getenv(name, "").strip()), None)
            elif cfg.base_url:
                key_name = "BENJI_API_KEY"
            else:
                key_name = "ANTHROPIC_API_KEY" if cfg.provider == "claude" else "OPENAI_API_KEY"
        origin = "local model settings" if local and not cfg.api_key else "server settings"
        if key_name:
            handed = inherited.get(key_name, "").strip() == cfg.api_key
            origin = "Keychain" if handed and key_name in keychain_names else ("engine environment" if handed else "key file")
        source = {
            "provider": cfg.provider, "model": safe(cfg.model),
            "destination": safe(cfg.destination), "host": safe(cfg.host),
            "origin": origin, "local": local,
            "usesKey": bool(cfg.api_key),
        }
        if key_name:
            source["keyVariable"] = key_name
        if expected is not None:
            if expected != source:
                return {"ok": False, "error": "Model settings changed. Check the source again before testing."}
            provider = providers_mod.make_provider(cfg.provider, cfg.api_key, cfg.model, cfg.base_url,
                                                   thinking=cfg.thinking, max_tokens=cfg.max_tokens, vision=cfg.vision)
            if isinstance(provider, providers_mod.OpenAIProvider):
                provider.max_tokens = min(provider.max_tokens, 256 if local else 64)
            answer = provider.complete(MODEL_SETUP_SYSTEM, [{"role": "user", "text": MODEL_SETUP_MESSAGE}], [])
            if not answer.get("text", "").strip() or answer.get("tool_calls"):
                return {"ok": False, "error": "The server connected but returned no text within the test limit. Try again; a reasoning model may need more output tokens."}
        return {"ok": True, "source": source}
    except (SystemExit, ProviderError, OSError, ValueError) as error:
        _, words = errors_mod.explain(str(error))
        if isinstance(error, SystemExit) and str(error).startswith("No API key found."):
            words = "No model key found. Add an Anthropic API key or use a local model."
        elif isinstance(error, SystemExit) and "BENJI_BASE_URL" in str(error) and "%" in os.getenv("BENJI_BASE_URL", ""):
            words = "Use a plain http or https server address. For a local model, use localhost, 127.0.0.1 or ::1 without percent encoding."
        elif isinstance(error, TimeoutError) or "timed out" in str(error).lower():
            words = "The test timed out. The request may have reached the model."
        return {"ok": False, "error": safe(words)[:300]}


def model_setup_main() -> None:
    """Private app entry point. A JSON null probes; the source object from a probe requests Test.
    The key is inherited through the usual key environment, never stdin or command arguments.
    """
    # One attempt, no continuation, 64 hosted / 256 local output tokens and a 60 s request
    # timeout, shorter than the app's 90 s deadline. Restore globals for in-process tests.
    limits = (providers_mod.RETRIES, providers_mod.MAX_CONTINUATIONS, providers_mod.ANTHROPIC_MAX_TOKENS,
              providers_mod.TIMEOUT)
    try:
        providers_mod.RETRIES = 0
        providers_mod.MAX_CONTINUATIONS = 0
        providers_mod.ANTHROPIC_MAX_TOKENS = 64
        providers_mod.TIMEOUT = 60
        expected = json.loads(sys.stdin.read(16384))
        if expected is not None and not isinstance(expected, dict):
            raise ValueError("invalid setup request")
        reply = model_setup(expected)
    except Exception:
        reply = {"ok": False, "error": "Benji couldn't finish the model check. Check the engine configuration and try again."}
    finally:
        (providers_mod.RETRIES, providers_mod.MAX_CONTINUATIONS, providers_mod.ANTHROPIC_MAX_TOKENS,
         providers_mod.TIMEOUT) = limits
    # A leading newline also separates the reply from a login profile that printed no newline.
    print("\n" + json.dumps(reply), flush=True)
