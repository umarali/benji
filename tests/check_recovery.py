"""Recovery at real filesystem/process boundaries. Offline providers; no GUI or network."""
from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


def _call(name, inp, ident="c1"):
    return {"text": "", "tool_calls": [{"id": ident, "name": name, "input": inp}]}


class Neutral:
    name, model, recovery_neutral = "offline", "recovery-fixture", True

    def __init__(self, scenario="approval", root=None):
        self.scenario, self.root, self.calls = scenario, root, 0
        self.search_returned = False

    def complete(self, system, messages, tools):
        self.calls += 1
        if self.scenario in ("server_search", "wrapup_search", "failed_search"):
            if self.scenario == "wrapup_search" and "this run is out of steps" not in str(messages[-1]):
                return _call("list_dir", {"path": "."})
            self.search_returned = True
            return {"text": "SEARCH-RESPONSE-CANARY", "tool_calls": [], "searches": [
                {"query": "offline query", "hosts": ["result.example"],
                 "error": "unavailable" if self.scenario == "failed_search" else ""}]}
        if self.scenario == "search_resume":
            if self.calls == 1:
                return _call("write_file", {"path": "output/search.txt", "content": "offline fixture"})
            return {"text": "Done.", "tool_calls": []}
        if self.scenario == "request" or (self.scenario == "wrapup" and "this run is out of steps" in str(messages[-1])):
            _barrier("model")
        if self.scenario == "wrapup":
            return _call("list_dir", {"path": "."})
        if self.scenario == "browser" and not any(m.get("name") == "browser_read" for m in messages):
            return _call("browser_read", {"tab": 1})
        if self.scenario == "browser":
            return _call("write_file", {"path": str(self.root / "effect"), "content": "x"})
        if self.scenario == "reasoning":
            return {**_call("write_file", {"path": str(self.root / "effect"), "content": "x"}), "reasoning": "PRIVATE-REASONING-CANARY"}
        if self.scenario == "finish":
            return {"text": "Done.", "tool_calls": []}
        if self.scenario == "partial":
            return {"text": "", "tool_calls": [{"id": str(i), "name": "list_dir", "input": {"path": "."}} for i in (1, 2)]}
        if not any(m.get("role") == "tool" and m.get("name") == "list_dir" for m in messages):
            return _call("list_dir", {"path": "." if self.scenario == "read_gap" else str(self.root / "outside")})
        return _call("write_file", {"path": str(self.root / "effect"), "content": "written once"})


def _barrier(at):
    print(json.dumps({"type": "test_boundary", "at": at}), flush=True)
    threading.Event().wait(30)
    raise RuntimeError("test boundary was not killed")


def worker(root: Path, scenario: str):
    from benji.agent import Agent
    from benji.jobs import JobStore
    from benji.serve import Server, run
    from benji import tools
    store = JobStore(root / "jobs")
    provider = Neutral(scenario, root)
    def make_job(record, approve, on_tool, cancelled):
        a = Agent(provider, "offline recovery fixture", store.path(record["id"]), approve=approve,
                  on_tool=on_tool, cancelled=cancelled)
        return a
    class Browser:
        running, connected = True, False
        def stop(self):
            self.running = False
        def call(self, method, payload, **kw):
            return {"ok": True, "url": "https://read.example/", "text": "offline page", "title": "fixture"}
    srv = Server(lambda *a: None, lambda e: print(json.dumps(e), flush=True), {},
                 make_job_agent=make_job, job_store=store, job_beat=0, schedule_tick=None, browser_link=Browser())
    original = tools.dispatch
    calls = [0]
    def dispatch(ctx, name, inp):
        calls[0] += 1
        if scenario == "partial" and calls[0] == 2:
            _barrier("partial")
        result = original(ctx, name, inp)
        if (name == "write_file" and scenario == "result_gap") or (name == "list_dir" and scenario == "read_gap"):
            _barrier("result_gap")
        return result
    tools.dispatch = dispatch
    before = store.recovery.before_dispatch
    def before_dispatch(record, agent, name, inp=None):
        if scenario == "write_failure" and name == "write_file":
            old_write = store.recovery._write
            store.recovery._write = lambda e: (_ for _ in ()).throw(OSError("injected marker write failure"))
            try:
                before(record, agent, name, inp)
            finally:
                store.recovery._write = old_write
        else:
            before(record, agent, name, inp)
        if name == "write_file" and scenario == "dispatch_gap":
            _barrier("dispatch_gap")
    store.recovery.before_dispatch = before_dispatch
    checkpoint = store.recovery.checkpoint
    def save_checkpoint(record, agent):
        checkpoint(record, agent)
        if scenario == "checkpoint_gap":
            _barrier("checkpoint")
    store.recovery.checkpoint = save_checkpoint
    write = store.recovery._write
    def write_envelope(envelope):
        write(envelope)
        if envelope["phase"] == "clear" and (provider.search_returned or
                (scenario == "clear_gap" and provider.calls)):
            _barrier("clear")
    store.recovery._write = write_envelope
    request_model = store.recovery.request
    def mark_request(record, agent):
        if scenario == "phase_failure":
            old_write = store.recovery._write
            store.recovery._write = lambda e: (_ for _ in ()).throw(OSError("injected model marker failure"))
            try:
                request_model(record, agent)
            finally:
                store.recovery._write = old_write
        else:
            request_model(record, agent)
    store.recovery.request = mark_request
    handle = srv.handle
    def request(req):
        if req.get("type") == "test_start":
            srv._begin_run(store.load(req["job"]))
            return True
        if req.get("type") == "test_probe":
            print(json.dumps({"type": "test_probe", "model_calls": provider.calls, "tool_calls": calls[0]}), flush=True)
            return True
        return handle(req)
    srv.handle = request
    return run(srv)


class Process:
    def __init__(self, root, scenario="approval", caps=None):
        self.items, self.q = [], queue.Queue()
        self.p = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--worker", str(root), scenario],
                                  cwd=HERE, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True)
        def read():
            for line in self.p.stdout:
                self.q.put(json.loads(line))
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()
        self.send(type="hello", protocol=1, capabilities=["jobs", "job_resume"] if caps is None else caps)
        self.wait(lambda e: e.get("type") == "ready")

    def start(self, job):
        self.send(type="test_start", job=job)
        self.job("working")

    def send(self, **req):
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()

    def wait(self, predicate):
        while True:
            try:
                e = self.q.get(timeout=8)
            except queue.Empty:
                raise AssertionError(f"no expected event; last events: {self.items[-4:]}") from None
            self.items.append(e)
            if predicate(e):
                return e

    def job(self, state):
        while True:
            job = self.wait(lambda e: e.get("type") == "job" and e["job"]["state"] == state)["job"]
            if state == "needs-you" and job["pending"]["action"].startswith("list a folder"):
                self.send(type="approve", id=job["id"], request=job["pending"]["request"], decision="yes")
                continue
            return job

    def kill(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait(timeout=8)
        self.p.stdin.close()
        self.thread.join(timeout=1)
        self.p.stdout.close()

    def close(self):
        if self.p.poll() is None:
            self.send(type="shutdown")
        self.p.wait(timeout=8)
        self.p.stdin.close()
        self.thread.join(timeout=1)
        self.p.stdout.close()


def _seed(root):
    from benji.jobs import JobStore
    (root / "outside").mkdir()
    store = JobStore(root / "jobs")
    record = store.create("Offline recovery", "Read the folder, then write outside it.", "do the job")
    return store, record


def _resume(p, job, **changes):
    p.send(**{"type": "job_resume", "job": job["id"], "run": job["run"],
              "generation": job["recovery_generation"], "read_sites": [], "act_sites": [], **changes})


def run(check, here=None):
    from benji import gate
    from benji.agent import Agent
    from benji import recovery as R

    print("job recovery: process kills, storage and explicit trusted requests:")
    for scenario in ("approval", "partial", "request", "wrapup", "checkpoint_gap", "clear_gap", "read_gap", "reasoning", "dispatch_gap", "result_gap"):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            store, rec = _seed(root)
            p = Process(root, scenario)
            try:
                p.start(rec["id"])
                if scenario in ("partial", "request", "wrapup", "checkpoint_gap", "clear_gap", "read_gap"):
                    p.wait(lambda e: e.get("type") == "test_boundary")
                else:
                    parked = p.job("needs-you")
                    if scenario == "approval":
                        p.send(type="job_steer", job=rec["id"], text="Keep this entirely offline.")
                        p.send(type="test_probe")
                        p.wait(lambda e: e.get("type") == "test_probe")
                    if scenario in ("dispatch_gap", "result_gap"):
                        p.send(type="approve", id=rec["id"], request=parked["pending"]["request"], decision="yes")
                        p.wait(lambda e: e.get("type") == "test_boundary")
            finally:
                p.kill()
            p = Process(root)
            try:
                lost = p.job("failed")
                p.send(type="test_probe")
                probe = p.wait(lambda e: e.get("type") == "test_probe")
                check(f"{scenario}: startup makes zero model calls and tool dispatches", probe["model_calls"] == 0 and probe["tool_calls"] == 0)
                check(f"{scenario}: startup only reports failure and never dispatches",
                      not (root / "effect").exists() if scenario != "result_gap" else (root / "effect").read_text() == "written once")
                check(f"{scenario}: eligibility is conservative after a process kill",
                      lost["can_resume"] is (scenario in ("approval", "partial", "checkpoint_gap", "clear_gap", "read_gap")) and lost["pending"] is None)
                if lost["can_resume"]:
                    envelope = store.recovery._load(store.load(rec["id"]))
                    cp = envelope["checkpoint"]["messages"]
                    check(f"{scenario}: only the preceding complete batch is saved",
                          not any(m.get("role") == "assistant" and any(c["name"] == "write_file" for c in m.get("tool_calls", [])) for m in cp)
                          and R._messages(cp) == cp)
                    if scenario in ("approval", "partial"):
                        check(f"{scenario}: consumed step/tool capacity and taint survive rollback",
                              envelope["state"]["steps"] >= 1 and envelope["state"]["tool_calls"] >= 2
                              and (scenario == "partial" or "file" in envelope["state"]["taints"]))
                    _resume(p, lost, generation="stale")
                    p.wait(lambda e: e.get("type") == "error")
                    _resume(p, lost, read_sites=["https://widen.example"])
                    p.wait(lambda e: e.get("type") == "error")
                    _resume(p, lost)
                    fresh = p.job("needs-you")
                    check(f"{scenario}: explicit Resume preserves run and asks afresh",
                          fresh["run"] == lost["run"] and fresh["pending"]["request"] != (parked["pending"]["request"] if scenario == "approval" else ""))
                    if scenario == "approval":
                        check("an unconsumed trusted steer survives checkpoint rollback",
                              "Keep this entirely offline." in store.recovery._load(store.load(rec["id"]))["state"]["user_text"])
                        p.send(type="approve", id=rec["id"], request=parked["pending"]["request"], decision="yes")
                        p.wait(lambda e: e.get("type") == "error")
                        check("an old approval id grants no authority", not (root / "effect").exists())
                    p.send(type="job_stop", job=rec["id"])
                    p.job("stopped")
                    check(f"{scenario}: user Stop deletes checkpoint contents and disables Resume",
                          not store.recovery.eligible(store.load(rec["id"])) and store.recovery._load(store.load(rec["id"]))["checkpoint"] is None)
                if scenario == "reasoning":
                    check("provider reasoning never reaches the recovery file",
                          b"PRIVATE-REASONING-CANARY" not in store.recovery.path(rec["id"]).read_bytes())
            finally:
                p.kill()

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        store, rec = _seed(root)
        p = Process(root, "write_failure")
        try:
            p.start(rec["id"])
            parked = p.job("needs-you")
            p.send(type="approve", id=rec["id"], request=parked["pending"]["request"], decision="yes")
            p.job("failed")
            check("marker write failure prevents the actual write", not (root / "effect").exists())
        finally:
            p.kill()

    for scenario in ("phase_failure", "finish"):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            store, rec = _seed(root)
            p = Process(root, scenario)
            try:
                p.start(rec["id"])
                p.job("failed" if scenario == "phase_failure" else "done")
                p.send(type="test_probe")
                probe = p.wait(lambda e: e.get("type") == "test_probe")
                if scenario == "phase_failure":
                    check("an unresolved-marker write failure prevents a model call", probe["model_calls"] == 0)
                check(f"{scenario}: an ordinary ending removes checkpoint contents",
                      store.recovery._load(store.load(rec["id"]))["checkpoint"] is None)
            finally:
                p.kill()

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        store, rec = _seed(root)
        p = Process(root)
        p.start(rec["id"])
        parked = p.job("needs-you")
        p.send(type="approve", id=rec["id"], request=parked["pending"]["request"], decision="yes")
        p.job("needs-you")
        p.close()
        p = Process(root)
        check("graceful quit after a dispatched effect never offers Resume", not p.job("failed")["can_resume"]
              and (root / "effect").read_text() == "written once")
        p.kill()

    # Graceful quit and old clients use the actual hello/job_resume protocol too.
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        store, rec = _seed(root)
        p = Process(root)
        p.start(rec["id"])
        p.job("needs-you")
        p.close()
        p = Process(root, caps=["jobs"])
        lost = p.job("failed")
        check("an older client never receives an enabled Resume", not lost["can_resume"])
        p.send(type="job_resume", job=rec["id"], run=1, generation=store.load(rec["id"])["recovery_generation"], read_sites=[], act_sites=[])
        p.wait(lambda e: e.get("type") == "error")
        p.kill()
        p = Process(root)
        lost = p.job("failed")
        check("graceful interrupted quit is eligible under the same checks", lost["can_resume"])
        kept = store.recovery._load(store.load(rec["id"]))["checkpoint"]["messages"]
        check("graceful quit does not save a decline the user never gave",
              not any(tc["name"] == "write_file" for m in kept for tc in m.get("tool_calls", [])))
        p.send(type="job_continue", job=rec["id"])
        p.job("needs-you")
        check("Continue is a new run and invalidates the old generation",
              store.load(rec["id"])["run"] == 2 and store.load(rec["id"])["recovery_generation"] != lost["recovery_generation"])
        p.kill()

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        store, rec = _seed(root)
        rec["browser"] = {"origins": ["https://read.example", "https://other.example"],
                          "acts": ["https://read.example"], "history": []}
        store.save(rec)
        p = Process(root, "browser")
        p.start(rec["id"])
        p.job("needs-you")
        p.kill()
        p = Process(root, "browser")
        lost = p.job("failed")
        check("browser reads reserve cumulative capacity before a crash",
              store.recovery._load(store.load(rec["id"]))["state"]["browser_unasked"] == 1)
        _resume(p, lost, read_sites=["https://other.example"], act_sites=["https://read.example"])
        p.wait(lambda e: e.get("type") == "error")
        _resume(p, lost, read_sites=["https://other.example"], act_sites=[])
        p.job("needs-you")
        kept = store.load(rec["id"])["browser"]
        check("Resume installs only separately confirmed subsets, dropping revoked read/act grants",
              kept["origins"] == ["https://other.example"] and kept["acts"] == [] and kept["history"] == [])
        p.kill()

    print("job recovery: server searches survive rollback at the durable model-response boundary:")
    for scenario in ("server_search", "wrapup_search", "failed_search"):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            store, rec = _seed(root)
            p = Process(root, scenario)
            try:
                p.start(rec["id"])
                p.wait(lambda e: e.get("type") == "test_boundary" and e["at"] == "clear")
            finally:
                p.kill()
            p = Process(root, "search_resume")
            try:
                lost = p.job("failed")
                check(f"{scenario}: a completed read-only model call remains resumable", lost["can_resume"])
                envelope = store.recovery._load(store.load(rec["id"]))
                searched = scenario != "failed_search"
                check(f"{scenario}: persisted taint and search hosts reflect successful searches",
                      ("web" in envelope["state"]["taints"]) is searched
                      and ("result.example" in envelope["state"]["search_hosts"]) is searched)
                check(f"{scenario}: rollback omits the unsaved search response",
                      "SEARCH-RESPONSE-CANARY" not in json.dumps(envelope["checkpoint"]["messages"]))
                if scenario != "wrapup_search":
                    _resume(p, lost)
                    outcome = p.wait(lambda e: e.get("type") == "job"
                                     and e["job"]["state"] in ("needs-you", "done"))["job"]
                    if searched:
                        check("successful server search still asks before an otherwise free write after Resume",
                              outcome["state"] == "needs-you"
                              and not (store.path(rec["id"]) / "output/search.txt").exists())
                        if outcome["state"] == "needs-you":
                            p.send(type="approve", id=rec["id"], request=outcome["pending"]["request"], decision="yes")
                            p.job("done")
                    else:
                        check("a failed search does not add a new approval to a free write", outcome["state"] == "done")
                    check(f"{scenario}: the resumed write finishes under its existing approval rules",
                          (store.path(rec["id"]) / "output/search.txt").read_text() == "offline fixture")
            finally:
                p.kill()

    print("job recovery: private authority rejects incompatible storage and preserves cumulative limits:")
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        store, rec = _seed(root)
        a = Agent(Neutral(), "sys", store.path(rec["id"]), approve=lambda _: True)
        a.messages = [{"role": "user", "text": "go"}]
        a.ctx.begin_turn("go")
        a.ctx.unattended = True
        assert store.recovery.start(rec, a)
        store.recovery.checkpoint(rec, a)
        rec.update(status="failed", ending="interrupted")
        store.save(rec)
        path = store.recovery.path(rec["id"])
        original = path.read_bytes()
        check("authority and its temporary name are private and the file is owner-only",
              gate.private_path(path) is not None and gate.private_path(path.with_name(path.name + ".tmp")) is not None
              and path.stat().st_mode & 0o777 == 0o600)
        for label, raw in (("corrupt", b"{"), ("oversized", b" " * (R.MAX_BYTES + 1)),
                           ("legacy", b'{"version":0}')):
            path.write_bytes(raw)
            check(f"{label} authority cannot Resume", not store.recovery.eligible(rec))
        path.write_bytes(original)
        for label, change in (("unknown schema", lambda e: e.update(new_state=True)),
                              ("changed version", lambda e: e.update(version=2)),
                              ("tool compatibility", lambda e: e.update(compatibility="old")),
                              ("missing counter", lambda e: e["state"].pop("browser_opens")),
                              ("unknown context", lambda e: e["state"].update(new_context=True)),
                              ("unresolved call", lambda e: e.update(phase="request"))):
            e = json.loads(original)
            change(e)
            store.recovery._write(e)
            check(f"{label} fails closed", not store.recovery.eligible(rec))
        path.write_bytes(original)
        a._steps, a._tool_calls = 3, 4
        for k in R.COUNTERS:
            setattr(a.ctx, k, 7)
        a.ctx.taint("a web page")
        store.recovery.consume(rec, a)
        e = store.recovery._load(rec)
        b = Agent(Neutral(), "sys", store.path(rec["id"]), approve=lambda _: True)
        store.recovery.restore(rec, b, e)
        check("rollback never restores capacity or drops unattended restriction/taint",
              b._steps == 3 and b._tool_calls == 4 and b.ctx.unattended and b.ctx.taints == {"web"}
              and all(getattr(b.ctx, k) == 7 for k in R.COUNTERS))
        # Exercise the Agent interface, including returned errors/refusals and exceptions.
        from benji import tools
        original_dispatch = tools.dispatch
        a.recovery, a.recovery_record = store.recovery, rec
        for outcome in ("success", "error", "refused", "cancelled", "exception"):
            path.write_bytes(original)
            def dispatch(ctx, name, inp):
                if outcome == "exception":
                    raise RuntimeError("injected dispatch exception")
                if outcome == "cancelled":
                    return "[cancelled] injected post-dispatch outcome"
                if outcome == "refused":
                    return "[refused] injected post-dispatch outcome"
                return original_dispatch(ctx, name, inp)
            tools.dispatch = dispatch
            try:
                try:
                    result = a._run_tool("write_file", {"path": "output/check.txt", "content": None if outcome == "error" else "x"})
                except RuntimeError:
                    result = "exception"
            finally:
                tools.dispatch = original_dispatch
            e = store.recovery._load(rec)
            check(f"Agent keeps possible effect authority after {outcome}", e["effects_seen"] and e["unsafe"]
                  and not store.recovery.eligible(rec) and (outcome != "error" or result.startswith("[error]")))
        path.write_bytes(original)
        a.approve = lambda _: False
        declined = a._run_tool("write_file", {"path": str(root / "declined"), "content": "x"})
        refused = a._run_tool("read_file", {"path": str(path)})
        check("a declined approval and private-path gate refusal grant no dispatch authority",
              declined.startswith("[declined]") and refused.startswith("[refused]")
              and not store.recovery._load(rec)["effects_seen"] and not (root / "declined").exists())
        path.write_bytes(original)
        # Large multilingual research must lose Resume, not abort its live job.
        path.write_bytes(original)
        a.provider = Neutral("finish", root)
        # Keep the same provider identity and exercise the actual loop checkpoint boundary.
        a.messages = [{"role": "user", "text": "go"}]
        for i in range(64):
            a.messages.extend([
                {"role": "assistant", "text": "", "tool_calls": [
                    {"id": f"large-{i}", "name": "web_fetch", "input": {"url": "https://example.test"}}]},
                {"role": "tool", "id": f"large-{i}", "name": "web_fetch", "content": "页" * 16000},
            ])
        try:
            reply = a._loop()
        except R.Ineligible:
            reply = None
        check("a 3 MiB conversation finishes its live job without Resume",
              reply == "Done." and a.provider.calls == 1 and not store.recovery.eligible(rec)
              and store.recovery._load(rec)["checkpoint"] is None)
        path.write_bytes(original)
        a.messages = [{"role": "user", "text": "go"}]
        for key in R.COUNTERS:
            setattr(a.ctx, key, 0)
        for _ in range(3):
            store.recovery.before_dispatch(rec, a, "browser_read", {"tab": 1})
            store.recovery.after_dispatch(rec, a)
        check("recovery reservations preserve live browser quota behavior",
              a.ctx.browser_unasked == 0 and store.recovery._load(rec)["state"]["browser_unasked"] >= 1)
        path.write_bytes(original)
        write = store.recovery._write
        def full_disk(_):
            raise OSError("injected full disk")
        store.recovery._write = full_disk
        try:
            try:
                store.recovery.discard(rec)
                discarded = not path.exists()
            except OSError:
                discarded = False
        finally:
            store.recovery._write = write
        check("discard deletes authority if its small replacement cannot be written", discarded)
        path.write_bytes(original)
        path.chmod(0o600)
        for bad in ([{"role": "user", "text": "Authorization: Bearer FAKE-TOKEN-CANARY"}],
                    [{"role": "user", "text": "x", "images": [{"data": "IMAGE-CANARY"}]}],
                    [{"role": "assistant", "text": "x", "reasoning": "REASON-CANARY"}],
                    [{"role": "assistant", **_call("list_dir", {"path": "."})} ]):
            a.messages = bad
            store.recovery.checkpoint(rec, a)
            check("omitted or incomplete conversation is ineligible and never saved", not store.recovery.eligible(rec)
                  and b"CANARY" not in path.read_bytes())
            path.write_bytes(original)
        path.write_bytes(original)
        check("legacy failed endings never offer Resume", not store.recovery.eligible({**rec, "ending": "unknown"}))
        a.provider.replay = "required"
        check("providers requiring omitted state cannot start recovery authority", not store.recovery.start(rec, a))
        store.recovery.delete(rec)
        check("deletion removes recovery data", not path.exists())
        path.write_bytes(original)
        store.delete(rec["id"])
        check("deleting an ended job removes its folder, record and adjacent recovery data",
              not path.exists() and not store.path(rec["id"]).exists() and store.load(rec["id"]) is None)
        live = store.create("Live", "brief", "words")
        try:
            store.delete(live["id"])
            refused = False
        except ValueError:
            refused = True
        check("job deletion refuses a live lifecycle", refused and store.path(live["id"]).exists())


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        raise SystemExit(worker(Path(sys.argv[2]), sys.argv[3]))
    counts = [0, 0]
    def check(label, condition):
        counts[not condition] += 1
        print(("ok " if condition else "FAIL ") + label)
    run(check)
    print(f"{counts[0]} passed, {counts[1]} failed")
    raise SystemExit(bool(counts[1]))
