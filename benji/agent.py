"""The agentic tool-use loop, independent of any provider."""

from __future__ import annotations

import inspect

import time
from pathlib import Path
from typing import Callable

import hashlib

from . import audit
from . import drive as drive_mod
from . import errors as errors_mod
from . import gate as gate_mod
from . import jobs as jobs_mod
from . import policy as policy_mod
from . import tools as tools_mod
from . import usage as usage_mod
from .providers import Abort, ProviderError, streaming_enabled

MAX_STEPS = 20  # safety bound on tool-call iterations per user turn
JOB_MAX_STEPS = 40  # a background job may take more steps than a spoken turn
MAX_TOOL_CALLS = 30  # tool calls in one turn, across all its steps; past it a call is "superseded"
JOB_MAX_TOOL_CALLS = 100
CANCELLED = "[Benji] cancelled."
STOPPED_AT_MAX = "[Benji] stopped: hit the maximum"
LIMIT_MARK = "\n[Benji] wrap-up:\n"      # after STOPPED_AT_MAX: what a job's tool-less last call said
RECENT_DECLINE = ("[declined] The user said not now to this a few minutes ago, so it was not asked again. "
                  "Do not retry it; adapt, or tell the user what you could not do.")
# A second screen step in one reply would act on a screenshot that is already out of date.
SCREEN_SAME_AS_BEFORE = "[the screen looks exactly the same as in the picture above; no new picture was attached]"
SCREEN_ONE_AT_A_TIME = ("[skipped] One screen step at a time: this one wasn't done. Look at the new "
                        "screenshot first, then ask for the next step.")


SUPERSEDED = ("[superseded] This turn has already used its {n} tool calls, so this call was not run. "
              "Stop calling tools and answer the user with what you have; say plainly what is left undone.")


def _image_hash(images: list[dict]) -> str:
    """A short fingerprint of the picture(s) sent: the same bytes are not sent twice in a turn."""
    h = hashlib.sha256()
    for image in images:
        h.update(str(image.get("media_type", "")).encode())
        h.update(str(image.get("data", "")).encode())
    return h.hexdigest()


def taint_now(ctx) -> str | None:
    """The kinds of outside content the turn has taken in so far, as the audit log's closed string."""
    return gate_mod.taint_string(ctx.taints) or None


class Agent:
    def __init__(self, provider, system_prompt: str, workdir: Path,
                 approve: Callable[[str], bool], auto_approve: bool = False,
                 on_tool: Callable[[str, dict], None] | None = None,
                 skills_dir: Path | None = None,
                 memory_path: Path | None = None,
                 usage_path: Path | None = None,
                 cancelled: Callable[[], bool] | None = None,
                 policy: policy_mod.Policy | None = None):
        self.provider = provider
        self.system_prompt = system_prompt
        self.ctx = tools_mod.Ctx(workdir=workdir, skills_dir=skills_dir, memory_path=memory_path)
        self.approve = approve
        self.auto_approve = auto_approve
        self.on_tool = on_tool or (lambda name, inp: None)
        # Called after each tool with its result (the --serve activity line); set by the caller.
        self.on_tool_done: Callable[[str, dict, str], None] = lambda name, inp, result: None
        self.messages: list[dict] = []
        # True when this agent keeps one conversation across turns (the command-line REPL): outside
        # content an earlier turn read stays in `messages`, so the next turn inherits its taint.
        self.carry_taint = False
        # The user's policy.json: what it switches off is neither offered nor run. It can only
        # restrict; the agent never reads it again mid-turn.
        self.policy = policy or policy_mod.NONE
        self.specs = self.policy.filter_specs(tools_mod.tool_specs())
        self.max_tool_calls = MAX_TOOL_CALLS     # a turn's tool calls, all steps together
        self._tool_calls = 0
        self._last_image = ""                   # the hash of the screenshot the model last saw this turn
        self.cancelled = cancelled or (lambda: False)   # checked before every model and tool call
        self.usage_path = usage_path        # None: don't log token usage
        self.last_usage: dict = {}          # token sums over the last send()
        # Streamed text (set by the caller). Without on_text, or with BENJI_STREAM=0, or with a
        # provider that can't stream, every model call is one blocking complete().
        self.on_text: Callable[[str], None] | None = None
        # Called when text already streamed turns out to come before a tool call: it isn't the answer.
        self.on_text_dropped: Callable[[], None] = lambda: None
        self._abort = Abort()               # stop() closes a stream in flight
        # A job's turn: what the user said to steer it, taken between steps. Returns the new
        # messages, oldest first, and forgets them. None: this isn't a job.
        self.poll_steer: Callable[[], list[str]] | None = None
        # A job's step hook: called after each tool step with its number, returns text to put
        # in front of the model with the tool results (the brief read again, a warning that the
        # steps are nearly out), or "". And: when the steps run out, one tool-less call asks the
        # model for its report instead of ending in silence.
        self.on_step: Callable[[int], str] | None = None
        self.wrap_at_limit = False
        # A job waits out a bad connection: for at most this many awake seconds per outage (0:
        # not at all, as a spoken turn), telling `on_wait` why ("network", "rate_limit", "provider")
        # and, with "", that it is back. The clock and the sleep are replaceable for the tests.
        self.patience = 0.0
        self.on_wait: Callable[[str], None] = lambda reason: None
        self.wait_clock: Callable[[], float] = time.monotonic      # stops while the Mac sleeps
        self.wait_sleep: Callable[[float], None] = time.sleep
        # Decline memory: where a "not now" is kept (benji.gate.DeclineMemory), under which
        # scope, and how the last approval was answered ("yes", "no", "timeout", "cancelled"), so only
        # the user's own No is remembered.
        self.declines = None
        self.decline_scope = ""
        self.last_answer: Callable[[], str] = lambda: "no"
        self.max_steps = MAX_STEPS
        self._screen_on, self._jobs_on, self._can_start_job = False, False, False
        self._browser_on, self._sites_on = False, False
        self._notes_on = False
        self._drive_on = False
        # Drive mode: shows the drive card for a goal and returns the user's answer. Set by allow_drive.
        self.drive_consent: Callable[[str], bool] | None = None
        self._schedules_on = False
        # For the audit log: the call this agent is deciding on (tool, reason code), which the
        # front-end's approval event names.
        self.gate_now: tuple[str, str] = ("", "")
        self._tools_run = 0
        self._steps = 0
        self._steers_applied = 0
        self._limit_warned = False
        self.recovery = None
        self.recovery_record = None

    def set_run(self, run_id: str, scope: str = "turn") -> None:
        """The id (a turn's or a job's) and scope every event of this agent carries."""
        self.ctx.run, self.ctx.scope = run_id, scope

    def send(self, user_text: str, images: list[dict] | None = None, user_words: str | None = None,
             tainted_by: str = "", taints=None) -> str:
        """Run one user turn (see _send), writing its start and end to the audit log: the status,
        how long it took, how many tools and model calls. Job turns and one-shot runs too."""
        started, self._tools_run, self._tool_calls, self._last_image = time.monotonic(), 0, 0, ""
        audit.event("turn_start", self.ctx.run, scope=self.ctx.scope, screen=bool(images), jobs=self._jobs_on)
        status, code = "ok", None
        try:
            answer = self._send(user_text, images, user_words, tainted_by, taints)
            answer = self._close_drive(answer)
            if answer == CANCELLED:
                status = "cancelled"
            elif answer.startswith(STOPPED_AT_MAX):
                status, code = "error", "out_of_steps"
            return answer
        except ProviderError:
            status, code = "error", "provider"
            raise
        except BaseException:
            status, code = "error", "internal"
            raise
        finally:
            if self.ctx.drive is not None and self.ctx.drive.active:     # a turn that ends, ends its drive
                tools_mod.end_drive(self.ctx, "error" if status == "error" else "turn_over")
            audit.event("turn_end", self.ctx.run, scope=self.ctx.scope, status=status, code=code,
                        ms=int((time.monotonic() - started) * 1000), tools=self._tools_run,
                        calls=self.last_usage.get("calls", 0))

    def _send(self, user_text: str, images: list[dict] | None = None, user_words: str | None = None,
              tainted_by: str = "", taints=None) -> str:
        """Run one user turn to completion; return the assistant's final text.
        `images` are attachments from benji.images.load_image (vision turns). A job's first message
        is a brief: `user_words` are the user's own words it came from (what the gate compares
        `remember` and named sites against), and `tainted_by` the outside content the turn that
        started it had read, `taints` which kinds. The job inherits the starting turn's taint; the
        gate's rules read the kinds, and the words are shown on the card."""
        message: dict = {"role": "user", "text": user_text}
        if self.carry_taint and not (tainted_by or taints):
            # Outside content an earlier turn read is still in this conversation's messages.
            taints, tainted_by = self.ctx.carried()
        # A turn with an image has taken in outside text from the start (see gate.taint_reason).
        self.ctx.begin_turn(user_text if user_words is None else user_words, screenshot=bool(images))
        if tainted_by or taints:
            self.ctx.taint(tainted_by or "outside content", code="inherited",
                           kinds=set(taints) if taints else gate_mod.taint_kinds_in(tainted_by))
        if images:
            message["images"] = images
            self._last_image = _image_hash(images)
        self.messages.append(message)
        self.last_usage = {"calls": 0, **{k: 0 for k in usage_mod.FIELDS}}

        self._steps = 0
        return self._loop()

    def resume(self, recovery, record: dict, envelope: dict) -> str:
        """A continuation of the same run. Never enters send() or begin_turn()."""
        recovery.restore(record, self, envelope)
        self.recovery, self.recovery_record = recovery, record
        self.last_usage = {"calls": 0, **{k: 0 for k in usage_mod.FIELDS}}
        started, tools_before = time.monotonic(), self._tools_run
        audit.event("turn_start", self.ctx.run, scope=self.ctx.scope, screen=False, jobs=self._jobs_on)
        status, code = "ok", None
        try:
            answer = self._loop()
            if answer == CANCELLED:
                status = "cancelled"
            elif answer.startswith(STOPPED_AT_MAX):
                status, code = "error", "out_of_steps"
            return answer
        except ProviderError:
            status, code = "error", "provider"
            raise
        except BaseException:
            status, code = "error", "internal"
            raise
        finally:
            audit.event("turn_end", self.ctx.run, scope=self.ctx.scope, status=status, code=code,
                        ms=int((time.monotonic() - started) * 1000), tools=self._tools_run - tools_before,
                        calls=self.last_usage.get("calls", 0))

    def _loop(self) -> str:
        while self._steps < self.max_steps:      # a drive raises the budget
            if self.recovery is not None and not self.cancelled():
                self.recovery.checkpoint(self.recovery_record, self)
            self._steps += 1
            step = self._steps
            if self.cancelled():
                return CANCELLED
            resp = self._call_model_patiently()
            self._note_usage(resp.get("usage"))
            for search in resp.get("searches", []):
                self._server_search(search)
            if resp.get("cancelled"):
                return CANCELLED
            tool_calls = resp.get("tool_calls", [])

            reply = {"role": "assistant", "text": resp.get("text", ""), "tool_calls": tool_calls}
            if resp.get("reasoning"):
                # An open model's reasoning, which a provider hands over only when its server wants it
                # sent back with the tool calls. In memory only: never shown, spoken, logged or saved.
                reply["reasoning"] = resp["reasoning"]
            self.messages.append(reply)

            if not tool_calls:
                steered = self._steers()
                if not steered:
                    return resp.get("text", "")
                self.messages.append({"role": "user", "text": steered})
                continue

            acted = False       # a screen step was done in this batch: the screen has changed
            for tc in tool_calls:
                if self.cancelled():
                    return CANCELLED
                name, inp = tc["name"], tc.get("input", {})
                if not isinstance(inp, dict):
                    # Valid JSON that is not an object (null, a list, a number): nothing can run on it.
                    result = f"[error] the arguments for {name} must be a JSON object; nothing ran"
                    self.on_tool_done(name, {}, result)
                    self.messages.append({"role": "tool", "id": tc["id"], "name": name, "content": result})
                    continue
                if acted and name in tools_mod.SCREEN_TOOL_NAMES:
                    result = SCREEN_ONE_AT_A_TIME
                    audit.event("tool", self.ctx.run, tool=name, gate="denied", code="screen_one_at_a_time",
                                scope=self.ctx.scope, tainted=self.ctx.tainted, taint=taint_now(self.ctx),
                                result="refused", ms=0)
                else:
                    self.on_tool(name, inp)
                    result = self._run_tool(name, inp)
                    acted = acted or (name in tools_mod.SCREEN_TOOL_NAMES and result.startswith("[done]"))
                self.on_tool_done(name, inp, result)
                message = {"role": "tool", "id": tc["id"], "name": name,
                           "content": tools_mod.as_data(name, result)}
                images = self.ctx.take_images()
                if images and _image_hash(images) == self._last_image:
                    # The step changed nothing on screen: the picture the model already has stays,
                    # and the same bytes are not sent again.
                    message["content"] += "\n" + SCREEN_SAME_AS_BEFORE
                elif images:        # a screen step's fresh screenshot replaces the step before's
                    self._forget_step_screenshots()
                    message["images"] = images
                    self._last_image = _image_hash(images)
                self.messages.append(message)
            self._steer_after_tools()
            self._step_note(step)

        if self.wrap_at_limit and self.messages and self.messages[-1].get("role") == "tool":
            return STOPPED_AT_MAX + " number of tool steps for this turn." + LIMIT_MARK + self._wrap_up()
        return STOPPED_AT_MAX + " number of tool steps for this turn."

    def allow_screen_actions(self, channel, size: tuple[int, int] | None = None, simple: bool = False) -> None:
        """Offer the screen tools this turn (click, scroll, type_text, press_key, drag); `channel` takes
        one step (and, for a step not asked about, its class) to the front-end and returns its
        result (benji/serve.py). `simple`: free and quiet steps go without a card."""
        self.ctx.screen, self.ctx.screen_size = channel, size
        self.ctx.screen_simple = simple
        self.ctx.screen_approve = self.approve      # never auto-approved: a screen step acts as the user
        self._screen_on = True
        self._refresh_specs()

    def allow_drive(self, consent: Callable[[str], bool], notify: Callable[[dict], None]) -> None:
        """Offer offer_drive, start_drive and end_drive this turn. Only after allow_screen_actions
        (a screenshot the app can act on), only for a foreground turn the user started: serve.py never
        calls it for a job. `consent(goal)` shows the drive card and returns the user's answer (only
        the app's own button or key says yes); `notify(event)` tells the front-end the drive began or
        ended."""
        if self.ctx.screen is None:
            return
        self.ctx.drive = drive_mod.Drive(notify=notify, scope=self.ctx.scope)
        self.drive_consent = consent
        self._drive_on = True
        self._refresh_specs()

    def _close_drive(self, answer: str) -> str:
        """The turn is over: a drive still on ends, with the code's line, and a turn that said nothing
        says that line, so the end of a drive is always written and spoken."""
        d = self.ctx.drive
        if d is None:
            return answer
        if d.active:
            tools_mod.end_drive(self.ctx, "turn_over")
        if d.ended and not answer.strip() and answer != CANCELLED:
            return d.ended[-1]["spoken"]
        return answer

    def allow_jobs(self, store, start: Callable[..., str] | None = None, sites: bool = False,
                   schedule: Callable[..., str] | None = None) -> None:
        """Offer the job tools this turn: find_jobs and read_job over `store`, and,
        for a foreground turn, start_job, which calls `start(title, brief)` (and `sites=` when the
        job is to read sites in the user's Chrome: `sites` says the app's browser switch is on)."""
        self.ctx.jobs, self.ctx.start_job = store, start
        self.ctx.browser_offer = sites and start is not None
        # A policy.json that switches off schedule_job (or start_job, or the jobs family) takes repeat away too.
        allowed = not (self.policy.blocks("schedule_job") or self.policy.blocks("start_job"))
        self.ctx.set_schedule, self.ctx.schedule_offer = schedule, schedule is not None and start is not None and allowed
        self._jobs_on, self._can_start_job, self._sites_on = True, start is not None, self.ctx.browser_offer
        self._schedules_on = self.ctx.schedule_offer
        self._refresh_specs()

    def allow_notes(self, keep: Callable[[str], str]) -> None:
        """Offer keep_note this turn: `keep(text)` stores the conversation's private note and returns
        the tool's result (benji/serve.py)."""
        self.ctx.keep_note = keep
        self._notes_on = True
        self._refresh_specs()

    def allow_browser(self, grant, link, always=(), on_user_stop=None, act: bool = True, upload: bool = True) -> None:
        """Offer the job's browser tools: `grant` is the job's approved sites and, apart
        from them, the sites it may click and type on, `link` the connection to the extension, `always`
        the sites the user set to always allow reading, `on_user_stop` what runs when the user presses
        Cancel on Chrome's debugging bar. Never a foreground turn. Its cards come through this agent's
        own `approve`, and are never answered by --yes. `act` and `upload`: the app said it can carry out
        looking and acting / uploading (its hello) and policy.json hasn't switched them off; without them
        those tools are neither offered nor run."""
        self.ctx.browser, self.ctx.browser_link = grant, link
        self.ctx.browser_always = tuple(always)
        self.ctx.browser_act_ok = bool(act) and not self._policy_blocks_acting()
        self.ctx.browser_upload_ok = bool(upload) and not self.policy.blocks("browser_upload")
        self.ctx.browser_approve = self._browser_ask
        self.ctx.on_gate = self._set_gate
        self.ctx.on_user_stop = on_user_stop
        self._browser_on = True
        self._refresh_specs()

    def allow_active_tab(self, link, always=()) -> None:
        """Offer read_active_tab to this foreground turn: the page the user is looking
        at, read after a card that shows its site, unless they set that site to always allow."""
        self.ctx.browser_link, self.ctx.browser_always = link, tuple(always)
        self.ctx.browser_approve = self._browser_ask
        self.ctx.on_gate = self._set_gate
        self.ctx.browser_active = True
        self._refresh_specs()

    def _set_gate(self, tool: str, code: str) -> None:
        self.gate_now = (tool, code)

    def _policy_blocks_acting(self) -> bool:
        return self.policy.blocks("browser_look")

    def _browser_ask(self, tool: str, reason: str) -> bool:
        """A card a browser tool asks for once it has looked at the page (the acting grant, a send, an
        upload, the front tab). It follows the same memory as any card: after a No, the same
        thing on the same page is not asked again for a while, and the model is told so."""
        if self.declines is not None and self.declines.blocked(self.decline_scope, tool, reason):
            self.ctx.browser_recent = True
            return False
        answer = self.approve(reason)
        if not answer and self.declines is not None and self.last_answer() == "no":
            self.declines.note(self.decline_scope, tool, reason)
        return answer

    def _refresh_specs(self) -> None:
        self.specs = self.policy.filter_specs(tools_mod.tool_specs(screen=self._screen_on, jobs=self._jobs_on,
                                          start_job=self._can_start_job, browser=self._browser_on,
                                          sites=self._sites_on, notes=self._notes_on, schedules=self._schedules_on,
                                          drive=self._drive_on, active_tab=self.ctx.browser_active,
                                          browser_act=self.ctx.browser_act_ok, browser_upload=self.ctx.browser_upload_ok))

    def _steers(self) -> str:
        """What the user said to steer this job since the last step, as one message, or ''."""
        said = self.poll_steer() if self.poll_steer else []
        if not said:
            return ""
        self._steers_applied += len(said)
        for text in said:
            self.ctx.user_text += "\n" + text      # the user's own words, for the gate's comparisons
        return "[The user steers this job: " + " | ".join(said) + "] Take it into account from here."

    def _steer_after_tools(self) -> None:
        """A steer between tool steps goes in with the tool results (a tool result must follow its
        call at once, so it rides on the last one) and reaches the model on its next call."""
        self._add_to_last_tool(self._steers())

    def _add_to_last_tool(self, text: str) -> None:
        """Words for the model, put on the last tool result (a tool result must follow its call at once)."""
        if text and self.messages and self.messages[-1].get("role") == "tool":
            last = self.messages[-1]
            self.messages[-1] = {**last, "content": last.get("content", "") + "\n\n" + text}

    def _step_note(self, step: int) -> None:
        if self.on_step is not None:
            self._add_to_last_tool(self.on_step(step))

    def _wrap_up(self) -> str:
        """The last call of a job that ran out of steps: it may not use a tool, only report. Its
        tool calls (it may try) are dropped. A failed call is no report, and code says so."""
        self._add_to_last_tool(jobs_mod.limit_prompt())
        try:
            resp = self._call_model_patiently()
        except ProviderError:
            return ""
        self._note_usage(resp.get("usage"))
        if resp.get("cancelled"):
            return ""
        return resp.get("text", "") or ""

    def _forget_step_screenshots(self) -> None:
        for i, m in enumerate(self.messages):
            if m.get("role") == "tool" and m.get("images"):
                kept = {k: v for k, v in m.items() if k != "images"}
                kept["content"] = kept.get("content", "") + "\n[that screenshot omitted: a newer one follows]"
                self.messages[i] = kept

    def stop(self) -> None:
        """Kill any tool process this agent is running and refuse new ones (a cancelled turn);
        close a streaming model call in flight."""
        self.ctx.kill_running()
        self._abort.fire()

    def _call_model_patiently(self) -> dict:
        """A model call that, for a job, waits out failures that pass by themselves (a dropped
        network, a rate limit, a provider outage). Repeating it is safe:
        a reply joins the conversation only once it has fully arrived, and no tool runs until then.
        Stopping the job ends the wait; running out of patience raises the last error, as a failure
        that doesn't wait does."""
        if self.patience <= 0:
            return self._call_model()
        began, attempt = None, 0
        while True:
            try:
                resp = self._call_model()
            except ProviderError as e:
                reason = errors_mod.explain(str(e))[0]
                now = self.wait_clock()
                began = now if began is None else began
                if reason not in errors_mod.WORTH_WAITING or now - began >= self.patience:
                    raise
                self.on_wait(reason)
                if not self._pause(min(jobs_mod.WAIT_MOST, jobs_mod.WAIT_FIRST * 2 ** attempt)):
                    return {"cancelled": True}
                attempt += 1
                continue
            if began is not None:
                self.on_wait("")
            return resp

    def _pause(self, seconds: float) -> bool:
        """Wait `seconds`, looking for a stop four times a second. False: the job was stopped."""
        end = self.wait_clock() + seconds
        while (left := end - self.wait_clock()) > 0:
            if self.cancelled():
                return False
            self.wait_sleep(min(0.25, left))
        return not self.cancelled()

    def _call_model(self) -> dict:
        if self.recovery is not None:
            self.recovery.request(self.recovery_record, self)
        resp = self._provider_call()
        if self.recovery is not None and not resp.get("cancelled"):
            if resp.get("reasoning") or set(resp) - {"text", "tool_calls", "usage", "cancelled", "searches"}:
                self.recovery.invalidate(self.recovery_record)
            self.recovery.phase(self.recovery_record, "clear")
        return resp

    def _provider_call(self) -> dict:
        stream = getattr(self.provider, "stream", None)
        if self.on_text is None or stream is None or not streaming_enabled():
            return self.provider.complete(self.system_prompt, self.messages, self.specs)
        streamed = []

        def text(piece: str) -> None:
            streamed.append(piece)
            self.on_text(piece)

        def dropped() -> None:
            streamed.clear()
            self.on_text_dropped()

        extra = {"on_drop": dropped} if "on_drop" in inspect.signature(stream).parameters else {}
        resp = stream(self.system_prompt, self.messages, self.specs, on_text=text,
                      cancelled=self.cancelled, abort=self._abort, **extra)
        if streamed and resp.get("tool_calls"):
            self.on_text_dropped()
        return resp

    def _server_search(self, search: dict) -> None:
        """A search the provider ran on its own side inside the model call: shown, logged and
        tainting the turn just as the engine's own web_search would be; its hosts may be fetched
        unasked like any search's."""
        inp = {"query": search.get("query", "")}
        hosts = [h for h in search.get("hosts", []) if isinstance(h, str) and h]
        error = search.get("error", "")
        self.on_tool("web_search", inp)
        if not error:
            self.ctx.search_hosts.update(hosts)
            self.ctx.taint("a web page", hosts[0] if hosts else "")
        audit.event("tool", self.ctx.run, tool="web_search", gate="free", code="read_only", scope=self.ctx.scope,
                    tainted=self.ctx.tainted, taint=taint_now(self.ctx), result="error" if error else "ok", ms=0)
        self.on_tool_done("web_search", inp, f"[error] web search failed ({error})" if error
                          else f"[search via Anthropic] {len(hosts)} site(s)")

    def _note_usage(self, usage: dict | None) -> None:
        if not usage:
            return
        self.last_usage["calls"] += 1
        for k in usage_mod.FIELDS:
            self.last_usage[k] += usage.get(k, 0)
        if self.usage_path is not None:
            usage_mod.record(self.usage_path, getattr(self.provider, "name", "?"),
                             getattr(self.provider, "model", "?"), usage)

    def _run_tool(self, name: str, inp: dict) -> str:
        ctx, started = self.ctx, time.monotonic()
        # Two limits that come before the gate and can only say no: the user's policy.json,
        # and the turn's cap on tool calls.
        if self.policy.blocks(name):
            return self._stopped_early(name, "policy_blocked", policy_mod.refusal(name, self.policy))
        self._tool_calls += 1
        if self.recovery is not None:
            self.recovery.consume(self.recovery_record, self)
        if self._tool_calls > self.max_tool_calls:
            return self._stopped_early(name, "tool_cap", SUPERSEDED.format(n=self.max_tool_calls))
        decision = tools_mod.decide(ctx, name, inp)
        tainted, taint, ctx.escalated, ctx.escalated_code = ctx.tainted, taint_now(ctx), False, ""
        label = name if tools_mod.is_tool(name) else "unknown"
        self.gate_now = (label, decision.code)
        declined = auto = False
        # An asked screen step is always asked, even with --yes: it acts as the user, in their
        # apps. Free and quiet steps aren't asked here; the app may still send them back.
        # The same for the user's browser, and for naming sites a job may read in it.
        recent = False
        ctx.browser_recent = False
        if decision.required and name in tools_mod.DRIVE_CONSENT_TOOLS:
            # The drive card, never auto-approved and never a spoken yes: one per drive, for this goal.
            # A "no" is remembered like any other, under one key for offer_drive and start_drive
            # so declining the one doesn't leave the other asking, and it is also remembered for the
            # rest of this turn (Drive.declined). Nothing here lets a decline be asked again in the window.
            target = tools_mod.decline_target(ctx, "start_drive", inp)
            if self.declines is not None and self.declines.blocked(self.decline_scope, "start_drive", target):
                declined = recent = True
            elif self.drive_consent is None or not self.drive_consent(drive_mod.clean_goal(inp.get("goal"))):
                declined = True
                tools_mod.drive_declined(ctx)
                if self.declines is not None and self.last_answer() == "no":
                    self.declines.note(self.decline_scope, "start_drive", target)
            else:
                tools_mod.drive_granted(ctx, name, inp)
        elif decision.required and (not self.auto_approve or tools_mod.never_auto_approved(name, inp)):
            target = tools_mod.decline_target(ctx, name, inp)
            if self.declines is not None and self.declines.blocked(self.decline_scope, name, target):
                declined = recent = True        # the user said not now a moment ago: not asked again
            elif not self.approve(decision.reason):
                declined = True
                if self.declines is not None and self.last_answer() == "no":
                    self.declines.note(self.decline_scope, name, target)
            elif name in tools_mod.BROWSER_TOOL_NAMES or name in ("start_job", "schedule_job"):
                tools_mod.browser_approved(ctx, name, inp)     # a yes, for exactly this call
        elif decision.required:
            auto = True
        if recent:
            result = RECENT_DECLINE
        elif declined:
            result = "[declined] The user did not approve this action. Do not retry it; adapt."
        else:
            tracked = self.recovery is not None and decision.cls != tools_mod.DENIED
            if tracked:
                self.recovery.before_dispatch(self.recovery_record, self, name, inp)
            try:
                result = tools_mod.dispatch(ctx, name, inp)
            finally:
                if tracked:
                    self.recovery.after_dispatch(self.recovery_record, self)
            if ctx.browser_recent and result.startswith("[declined]"):
                result, recent = RECENT_DECLINE, True      # a browser card the user said "not now" to a moment ago
            if name == "start_drive" and ctx.drive is not None and ctx.drive.active:
                # a drive is many small steps: the turn's model-step budget and tool cap grow with it
                self.max_steps = max(self.max_steps, drive_mod.TURN_STEPS)
                self.max_tool_calls = max(self.max_tool_calls, drive_mod.TURN_TOOL_CALLS)
        self._tools_run += 1
        self._audit_tool(label, name, inp, decision, result, tainted, taint, auto, started, recent)
        return result

    def _stopped_early(self, name: str, code: str, result: str) -> str:
        """A call stopped before the gate looked at it: never run, never asked, one audit line."""
        label = name if tools_mod.is_tool(name) else "unknown"
        audit.event("tool", self.ctx.run, tool=label, gate="denied", code=code, scope=self.ctx.scope,
                    tainted=self.ctx.tainted, taint=taint_now(self.ctx), result="refused", ms=0)
        return result

    def _audit_tool(self, label: str, name: str, inp: dict, decision, result: str, tainted: bool,
                    taint: str, auto: bool, started: float, recent: bool = False) -> None:
        """One `tool` event per call: the class the gate gave it (free, quiet, asked, denied), the
        rule's code, and how it ended. A call that was free or quiet and then refused by the tool
        itself (a blocked host, a page off the job's list) is a denial."""
        ctx = self.ctx
        cls, code = decision.cls, decision.code
        text = result if isinstance(result, str) else ""
        if text.startswith("[declined]"):
            outcome = "declined"
        elif text.startswith("[refused]") or ctx.denied_code:
            outcome = "refused"
        elif text.startswith("[cancelled]"):
            outcome = "cancelled"
        elif text.startswith("[stopped]"):
            outcome = "stopped"
        elif text.startswith("[error]"):
            outcome = "error"
        else:
            outcome = "ok"
        if outcome == "refused" and cls in (tools_mod.FREE, tools_mod.QUIET):
            cls, code = tools_mod.DENIED, ctx.denied_code or "tool_refused"
        if ctx.escalated:
            cls, code = tools_mod.ASKED, ctx.escalated_code or "screen_app_escalated"
        if recent:
            cls, code = tools_mod.DENIED, "recent_decline"
        host = ctx.last_host or (audit.host_of(inp.get("url")) if name == "web_fetch" and isinstance(inp, dict) else None)
        audit.event("tool", ctx.run, tool=label, gate=cls, code=code, scope=ctx.scope, tainted=tainted,
                    taint=taint or None, result=outcome, ms=int((time.monotonic() - started) * 1000), path=decision.path or None,
                    host=host or None, auto=True if auto else None)
