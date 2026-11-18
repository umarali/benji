"""Explicit, read-only job recovery. One private envelope is the run's authority.

This store orders process-crash recovery; it does not promise power-loss durability.
A checkpoint is a complete neutral conversation. Live cumulative authority can only
consume capacity or add taint, even when an incomplete batch is discarded.
"""
from __future__ import annotations

import copy
import functools
import stat
import hashlib
import json
import os
import threading
import uuid
from pathlib import Path

from . import audit, gate

VERSION = 1
MAX_BYTES = 2 * 1024 * 1024
MAX_MESSAGES = 500
COUNTERS = ("browser_unasked", "browser_opens", "browser_act_unasked", "screen_unasked")
# Audited handlers only. Shell allowlisting and free/quiet approval classes are NOT
# evidence of read-only semantics. Opening a signed-in page can change server state.
READ_ONLY = frozenset({"read_file", "list_dir", "search_files", "web_fetch", "web_search",
                       "recall", "find_jobs", "read_job", "list_skills", "read_skill",
                       "browser_tabs", "browser_read"})
STATE_KEYS = frozenset({"steps", "tool_calls", "tools_run", "max_steps", "max_tool_calls",
                        "user_text", "taints", "taint_notes", "search_hosts", "unattended", "limit_warned", *COUNTERS})
ENVELOPE_KEYS = frozenset({"version", "job", "run", "generation", "compatibility", "identity",
                           "phase", "effects_seen", "unsafe", "eligible", "checkpoint", "state", "digest"})
# Explicit inventory: a new context field requires a recovery audit, not silent omission.
CONTEXT_FIELDS = frozenset('''workdir skills_dir memory_path running stopped lock screen screen_size
screen_stopped screen_simple user_text screen_approve images taints taint_notes search_hosts
screen_unasked keep_note jobs live_job_ids start_job set_schedule schedule_offer unattended
browser_offer browser browser_link drive browser_unasked browser_opens browser_yes browser_refs
browser_act_unasked browser_always browser_approve on_gate on_user_stop browser_active browser_act_ok
browser_upload_ok browser_recent run scope denied_code escalated escalated_code last_host'''.split())


class Ineligible(ValueError):
    pass


def _bytes(value) -> bytes:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()


def _hash(value) -> str:
    return hashlib.sha256(_bytes(value)).hexdigest()


@functools.lru_cache(maxsize=1)
def compatibility() -> str:
    """An exact code match, intentionally stricter than cross-version migration."""
    root = Path(__file__).parent
    names = ["agent.py", "audit.py", "gate.py", "policy.py", "jobs.py", "recovery.py", "browser.py", "providers.py", "serve.py", "prompts.py"]
    files = [root / n for n in names] + sorted((root / "tools").glob("*.py"))
    return hashlib.sha256(b"".join(p.read_bytes() for p in files)).hexdigest()


def identity(agent) -> dict:
    from .providers import AnthropicProvider, OpenAIProvider
    p = agent.provider
    if not (type(p) in (AnthropicProvider, OpenAIProvider) or getattr(p, "recovery_neutral", False) is True):
        raise Ineligible("provider has no audited neutral continuation")
    if getattr(p, "replay", "none") != "none":
        raise Ineligible("provider requires omitted continuation state")
    # Hash configuration; never serialize the provider, its session or credentials.
    # The trusted system prompt/specs are regenerated with current policy and grants.
    config = [type(p).__module__, type(p).__qualname__, getattr(p, "url", ""),
              getattr(p, "thinking", "off"), getattr(p, "max_tokens", None), getattr(p, "vision", None)]
    return {"provider": str(getattr(p, "name", "")), "model": str(getattr(p, "model", "")), "config": _hash(config)}


def _private_content(value) -> bool:
    # Do not redact a continuation and then pretend it means the same thing. Reject
    # known credential forms, in addition to omitting all provider/session objects.
    if isinstance(value, str):
        return any(rx.search(value) for rx in (*audit._KEYS, audit._BEARER, audit._ASSIGNED))
    if isinstance(value, dict):
        sensitive = {"apikey", "accesstoken", "refreshtoken", "sessiontoken", "authorization", "password", "cookie", "setcookie"}
        return any("".join(c for c in str(k).lower() if c.isalnum()) in sensitive or _private_content(v) for k, v in value.items())
    if isinstance(value, list):
        return any(_private_content(v) for v in value)
    return False


def _messages(messages) -> list:
    if not isinstance(messages, list) or not 0 < len(messages) <= MAX_MESSAGES:
        raise Ineligible("missing or oversized conversation")
    if _private_content(messages):
        raise Ineligible("credential-shaped content")
    pending = []
    for m in messages:
        if not isinstance(m, dict):
            raise Ineligible("unknown message")
        role = m.get("role")
        keys = {"role", "text"} if role == "user" else {"role", "text", "tool_calls"} if role == "assistant" else {"role", "id", "name", "content"}
        if role not in ("user", "assistant", "tool") or set(m) - keys:
            raise Ineligible("image, reasoning or unknown message state")
        if role == "tool":
            if not pending or (m.get("id"), m.get("name")) != pending.pop(0) or not isinstance(m.get("content"), str):
                raise Ineligible("incomplete tool batch")
        else:
            if pending or not isinstance(m.get("text"), str):
                raise Ineligible("incomplete tool batch")
            if role == "assistant":
                calls = m.get("tool_calls", [])
                if not isinstance(calls, list):
                    raise Ineligible("unknown calls")
                for tc in calls:
                    if (not isinstance(tc, dict) or set(tc) != {"id", "name", "input"}
                            or not isinstance(tc["id"], str) or not isinstance(tc["name"], str)
                            or not isinstance(tc["input"], dict)):
                        raise Ineligible("unknown call state")
                    pending.append((tc["id"], tc["name"]))
    if pending:
        raise Ineligible("incomplete tool batch")
    # Only neutral schema is copied. No usage, provider responses, tokens or images.
    return copy.deepcopy(messages)


def state_of(agent) -> dict:
    c = agent.ctx
    if (set(c.__dataclass_fields__) != CONTEXT_FIELDS or set(vars(c)) != CONTEXT_FIELDS
            or c.drive is not None or c.screen is not None or c.images or c.browser_refs
            or c.screen_size is not None or c.screen_stopped or c.screen_simple or c.browser_active
            or c.keep_note is not None or c.start_job is not None or c.set_schedule is not None):
        raise Ineligible("context cannot be restored")
    if _private_content(c.user_text) or _private_content(c.taint_notes):
        raise Ineligible("credential-shaped intent")
    return {"steps": agent._steps, "tool_calls": agent._tool_calls, "tools_run": agent._tools_run,
            "max_steps": agent.max_steps, "max_tool_calls": agent.max_tool_calls,
            "user_text": c.user_text, "taints": sorted(c.taints), "taint_notes": dict(c.taint_notes),
            "search_hosts": sorted(c.search_hosts), "unattended": c.unattended, "limit_warned": agent._limit_warned,
            **{key: getattr(c, key) for key in COUNTERS}}


def _state(s) -> None:
    if not isinstance(s, dict) or set(s) != STATE_KEYS:
        raise Ineligible("unknown or missing context state")
    for k in ("steps", "tool_calls", "tools_run", "max_steps", "max_tool_calls", *COUNTERS):
        if type(s[k]) is not int or not 0 <= s[k] <= 10000:
            raise Ineligible("invalid budget")
    if type(s["unattended"]) is not bool or type(s["limit_warned"]) is not bool or not isinstance(s["user_text"], str):
        raise Ineligible("invalid intent")
    for k in ("taints", "search_hosts"):
        if not isinstance(s[k], list) or len(s[k]) > 1000 or not all(isinstance(v, str) for v in s[k]):
            raise Ineligible("invalid taint or search state")
    if set(s["taints"]) - set(gate.TAINT_KINDS):
        raise Ineligible("unknown taint")
    if not isinstance(s["taint_notes"], dict) or set(s["taint_notes"]) != set(s["taints"]) or not all(isinstance(v, str) for v in s["taint_notes"].values()):
        raise Ineligible("invalid taint notes")


def _merge(old, new):
    _state(old)
    _state(new)
    s = copy.deepcopy(new)
    for k in ("steps", "tool_calls", "tools_run", *COUNTERS):
        s[k] = max(old[k], new[k])
    for k in ("max_steps", "max_tool_calls"):
        s[k] = min(old[k], new[k])
    s["taints"] = sorted(set(old["taints"]) | set(new["taints"]))
    s["taint_notes"] = {**new["taint_notes"], **old["taint_notes"]}
    s["unattended"] = old["unattended"] or new["unattended"]
    s["limit_warned"] = old["limit_warned"] or new["limit_warned"]
    return s


class Recovery:
    def __init__(self, store):
        self.store = store
        self.lock = threading.RLock()

    def path(self, job):
        return self.store.record_path(job).with_name(job + ".recovery.json")

    def _write(self, e):
        e["digest"] = _hash({k: v for k, v in e.items() if k != "digest"})
        raw = _bytes(e)
        if len(raw) > MAX_BYTES:
            raise Ineligible("checkpoint too large")
        p = self.path(e["job"])
        # Fixed private filename covered by gate, no random unprotected temporary files.
        tmp = p.with_name(p.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as f:
                os.fchmod(f.fileno(), 0o600)
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, p)
            d = os.open(p.parent, os.O_RDONLY)
            try:
                os.fsync(d)
            finally:
                os.close(d)
        finally:
            tmp.unlink(missing_ok=True)

    def _load(self, record):
        p = self.path(record["id"])
        if p.is_symlink():
            raise Ineligible("linked authority")
        with p.open("rb") as f:
            info = os.fstat(f.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
                raise Ineligible("authority permissions")
            raw = f.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise Ineligible("oversized authority")
        def unique(pairs):
            obj = {}
            for key, value in pairs:
                if key in obj:
                    raise Ineligible("duplicate authority key")
                obj[key] = value
            return obj
        e = json.loads(raw, object_pairs_hook=unique)
        if (not isinstance(e, dict) or set(e) != ENVELOPE_KEYS or type(e["version"]) is not int or e["version"] != VERSION
                or e["job"] != record["id"] or type(e["run"]) is not int or e["run"] != record.get("run")
                or e["generation"] != record.get("recovery_generation") or not isinstance(e["generation"], str)
                or e["compatibility"] != compatibility()
                or e["digest"] != _hash({k: v for k, v in e.items() if k != "digest"})
                or e["phase"] not in ("clear", "request")
                or any(type(e[k]) is not bool for k in ("effects_seen", "unsafe", "eligible"))):
            raise Ineligible("authority mismatch")
        ident = e["identity"]
        if (not isinstance(ident, dict) or set(ident) != {"provider", "model", "config"}
                or not all(isinstance(v, str) for v in ident.values())):
            raise Ineligible("unknown provider identity")
        _state(e["state"])
        if e["checkpoint"] is not None:
            cp = e["checkpoint"]
            if not isinstance(cp, dict) or set(cp) != {"messages", "state", "steers"} or type(cp["steers"]) is not int:
                raise Ineligible("unknown checkpoint")
            _state(cp["state"])
            _messages(cp["messages"])
        return e

    def start(self, record, agent):
        with self.lock:
            self.delete(record)
            record["recovery_generation"] = str(uuid.uuid4())
            self.store.save(record)
            try:
                ident = identity(agent)
                state = state_of(agent)
            except Ineligible:
                return False
            e = dict(version=VERSION, job=record["id"], run=record["run"], generation=record["recovery_generation"],
                     compatibility=compatibility(), identity=ident, phase="clear", effects_seen=False,
                     unsafe=False, eligible=True, checkpoint=None, state=state)
            self._write(e)
            return True

    def checkpoint(self, record, agent):
        with self.lock:
            e = self._load(record)
            try:
                messages = _messages(agent.messages)
                state = state_of(agent)
                if identity(agent) != e["identity"]:
                    raise Ineligible("provider changed")
                updated = {**e, "state": _merge(e["state"], state)}
                if updated["eligible"] and not updated["effects_seen"]:
                    updated["checkpoint"] = {"messages": messages, "state": state, "steers": agent._steers_applied}
                self._write(updated)
            except Ineligible:
                # Recovery limits must not stop an otherwise valid live job. Keep
                # the last bounded state and irreversible markers, but drop Resume.
                e.update(eligible=False, checkpoint=None)
                self._write(e)

    def invalidate(self, record):
        with self.lock:
            e = self._load(record)
            e.update(eligible=False, checkpoint=None)
            self._write(e)

    def consume(self, record, agent):
        with self.lock:
            e = self._load(record)
            try:
                e["state"] = _merge(e["state"], state_of(agent))
            except Ineligible:
                e.update(eligible=False, checkpoint=None)
            self._write(e)

    def request(self, record, agent):
        with self.lock:
            e = self._load(record)
            try:
                e["state"] = _merge(e["state"], state_of(agent))
            except Ineligible:
                e.update(eligible=False, checkpoint=None)
            e["phase"] = "request"
            self._write(e)

    def complete(self, record, agent):
        """Clear a model request atomically with its cumulative search taint/hosts."""
        with self.lock:
            e = self._load(record)
            try:
                e["state"] = _merge(e["state"], state_of(agent))
            except Ineligible:
                e.update(eligible=False, checkpoint=None)
            e["phase"] = "clear"
            self._write(e)

    def before_dispatch(self, record, agent, name, inp=None):
        with self.lock:
            e = self._load(record)
            try:
                state = state_of(agent)
            except Ineligible:
                e.update(eligible=False, checkpoint=None, unsafe=True, effects_seen=True)
                self._write(e)
                return
            # Reserve before even a read. Errors and lost results still consume capacity.
            if name.startswith("browser_"):
                state["browser_unasked"] += 1
            if name == "browser_open":
                state["browser_opens"] += 1
            if name in ("browser_scroll", "browser_click", "browser_type", "browser_key", "browser_upload"):
                state["browser_act_unasked"] += 1
            if name in ("click", "scroll", "type_text", "press_key", "drag"):
                state["screen_unasked"] += 1
            # Pre-taint protects a crash after a result arrives but before its live batch settles.
            kind = "browser" if name.startswith("browser_") else "web" if name in ("web_search", "web_fetch") else None
            if name in ("read_file", "list_dir", "search_files"):
                from .tools.context import _within, _resolve
                if not _within(agent.ctx, _resolve(agent.ctx, (inp or {}).get("path", "."))):
                    kind = "file"
            if kind:
                state["taints"] = sorted(set(state["taints"]) | {kind})
                state["taint_notes"].setdefault(kind, "outside content in an interrupted batch")
            e["state"] = _merge(e["state"], state)
            if name not in READ_ONLY:
                e.update(effects_seen=True, unsafe=True)
                e["checkpoint"] = None
            self._write(e)

    def after_dispatch(self, record, agent):
        with self.lock:
            e = self._load(record)
            try:
                s = _merge(e["state"], state_of(agent))
            except Ineligible:
                e.update(eligible=False, checkpoint=None)
                self._write(e)
                return
            e["state"] = s
            self._write(e)

    def eligible(self, record):
        with self.lock:
            if record.get("status") != "failed" or record.get("ending") != "interrupted":
                return False
            try:
                e = self._load(record)
                return (e["phase"] == "clear" and e["eligible"] and not e["unsafe"]
                        and not e["effects_seen"] and e["checkpoint"] is not None)
            except (OSError, ValueError, TypeError, KeyError, RecursionError):
                return False

    def claim(self, record, run, generation, read_sites, act_sites):
        """Called only by the trusted job_resume request, with the server lock held."""
        from . import browser
        with self.lock:
            if not self.eligible(record) or type(run) is not int or run != record["run"] or generation != record.get("recovery_generation"):
                raise Ineligible("stale or ineligible recovery")
            old = record.get("browser") or {}
            for sites, key in ((read_sites, "origins"), (act_sites, "acts")):
                if not isinstance(sites, list) or any(not isinstance(s, str) or browser.origin_of(s) != s for s in sites) or len(set(sites)) != len(sites) or not set(sites) <= set(old.get(key, [])):
                    raise Ineligible("browser scope widened")
            if not set(act_sites) <= set(read_sites):
                raise Ineligible("acting requires separate read consent")
            e = self._load(record)
            # Consume the old generation BEFORE any worker or status change. A double click
            # or a process dying between the two files cannot claim the checkpoint twice.
            generation = str(uuid.uuid4())
            e["generation"] = generation
            self._write(e)
            record.update(recovery_generation=generation, status="queued", ending="", pending=None, error="")
            record["browser"] = {"origins": list(read_sites), "acts": list(act_sites), "history": []} if old else None
            self.store.save(record)
            return e

    def restore(self, record, agent, e):
        with self.lock:
            current = self._load(record)
            if current != e or identity(agent) != e["identity"]:
                raise Ineligible("continuation configuration changed")
            s = _merge(e["checkpoint"]["state"], e["state"])
            if agent.max_steps < s["max_steps"] or agent.max_tool_calls < s["max_tool_calls"]:
                raise Ineligible("budgets incompatible")
            agent.messages = _messages(e["checkpoint"]["messages"])
            for k in ("user_text", "taint_notes", "unattended", *COUNTERS):
                setattr(agent.ctx, k, copy.deepcopy(s[k]))
            agent.ctx.taints = set(s["taints"])
            agent.ctx.search_hosts = set(s["search_hosts"])
            for k, attr in (("steps", "_steps"), ("tool_calls", "_tool_calls"), ("tools_run", "_tools_run"), ("max_steps", "max_steps"), ("max_tool_calls", "max_tool_calls")):
                setattr(agent, attr, s[k])
            # Steers not incorporated into the complete checkpoint remain trusted intent.
            for steer in record.get("steers", [])[e["checkpoint"]["steers"]:]:
                text = steer["text"]
                agent.messages.append({"role": "user", "text": "The user steers this job: " + text})
                agent.ctx.user_text += "\n" + text
            agent._steers_applied = len(record.get("steers", []))
            agent._limit_warned = s["limit_warned"]
            agent._refresh_specs()

    def discard(self, record):
        """Delete private checkpoint text, retaining this run's irreversible markers."""
        with self.lock:
            try:
                e = self._load(record)
            except (OSError, ValueError, TypeError, KeyError, RecursionError):
                self.delete(record)
                return
            e.update(eligible=False, checkpoint=None)
            e["state"].update(user_text="", search_hosts=[], taint_notes={k: "outside content" for k in e["state"]["taints"]})
            try:
                self._write(e)
            except (OSError, Ineligible):
                self.delete(record)

    def delete(self, record):
        with self.lock:
            self.path(record["id"]).unlink(missing_ok=True)
            self.path(record["id"]).with_name(record["id"] + ".recovery.json.tmp").unlink(missing_ok=True)
