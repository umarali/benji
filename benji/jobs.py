"""Background jobs, small (D-130 step 1): something the user asked for that keeps running while
they do other things.

A job is a folder, `<workdir>/jobs/<id>/`, with `report.md` (what the job found or made, written by
this module when it ends), `output/` and `tmp/`, and a record, `<workdir>/jobs/<id>.json`, BESIDE the
folder (D-177): the folder is the job's working folder, and the record holds what it is allowed to do,
so it is kept out of its reach and `gate.private_path` refuses it. The record
stores only the lifecycle the engine itself moved it through (`queued`, `running`, `finished`,
`failed`, `stopped`) and any pending approval; the state the panel shows (`queued`, `working`,
`needs-you`, `done`, `failed`, `stopped`) is derived from the record in `derive_state`, never
from anything the model wrote.

A job ends with a structured turn_end (D-118 step 3): a spoken line (for the speaker), a written
line (for the row, the peek and the report; code makes one from the spoken line when the model gave
none, D-146), the files it made (each one checked to exist on disk), and at most three next-step
chips. The model writes it as a JSON object at the end of its last message; `parse_turn_end` reads it
leniently, and a message without one still ends the job with a spoken line cut from its text.

The engine side (running a job as a second turn, the approval parking, the protocol events) is in
benji/serve.py; the tools that start a job and recall past ones are in benji/tools.py.

Second pass (D-172): a job has *runs*. The first run is the one the user started; a later run of the
same job (same folder, same history) is one the user asked to continue from the row, or one its
schedule (benji/schedule.py) started while nobody was watching (an *unattended* run: read-class
tools only, anything else parks as needs-you). Code, not the model, decides whether a repeat run
found anything new (`is_news`), re-reads the brief to a long job at fixed step intervals and when it
resumes from a park (`step_note`), builds the hand-off brief from the conversation (`handoff_brief`)
and words a failure plainly (`plain_failure`).
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import uuid
from pathlib import Path

from . import gate, home

VERSION = 1
STORED = ("queued", "running", "finished", "failed", "stopped")
STATES = ("queued", "working", "needs-you", "done", "failed", "stopped")
LIVE_STATES = ("queued", "working", "needs-you")
INTERRUPTED = "Benji restarted before this finished."
MAX_CHIPS = 3
MAX_CHIP_CHARS = 40
MAX_FILES = 8
MAX_SPOKEN_CHARS = 240
MAX_WRITTEN_CHARS = 140
MAX_TITLE_CHARS = 60
MAX_STEER_CHARS = 600
MAX_REPORT_CHARS = 12000
MIN_PREFIX = 6                  # the shortest id prefix read_job takes
REREAD_EVERY = 10               # a job's brief is read to it again every this many steps (and after a park)
LIMIT_WARN_LEFT = 3             # steps left when a job is told to start wrapping up
MAX_BRIEF_SHOWN = 700           # the brief the row and the start card show
MAX_SAID = 6                    # messages of the conversation a hand-off brief carries
MAX_SAID_CHARS = 400
MAX_HANDOFF_CHARS = 3000
MAX_ITEMS = 30                  # findings a repeat run lists for the "anything new?" comparison
MAX_ITEM_CHARS = 120
MAX_RUN_HISTORY = 50
RUN_KINDS = ("first", "scheduled", "continued")
STOP_REASONS = ("", "limit", "restart")
LIMIT_STOP = "Stopped at the step limit."
# A job waits out a bad connection (D-177): how long between tries, and how much awake time one outage
# may take before the job stops. A run nobody is watching gives up sooner, because it holds the one
# job slot.
WAIT_FIRST = 5.0
WAIT_MOST = 300.0
WAIT_LIMIT = 6 * 3600.0
WAIT_LIMIT_UNATTENDED = 15 * 60.0


def folder(workdir: str | Path) -> Path:
    return Path(workdir) / "jobs"


def valid_id(job_id: object) -> bool:
    """A job id is a canonical lower-case UUID: it names a folder, so nothing else is accepted."""
    if not isinstance(job_id, str):
        return False
    try:
        return str(uuid.UUID(job_id)) == job_id
    except ValueError:
        return False


def record_taints(record: dict) -> set[str]:
    """The kinds of outside content this job has taken in: the stored set, or, for a record from
    before the set was kept, the kinds its `tainted_by` words name."""
    stored = record.get("taints")
    if isinstance(stored, list):
        kinds = {k for k in stored if k in gate.TAINT_KINDS}
        if kinds or not record.get("tainted_by"):
            return kinds
    return gate.taint_kinds_in(str(record.get("tainted_by") or ""))


# ---- the displayed state, derived in code ----------------------------------------------------

def derive_state(record: dict, live: bool) -> str:
    """The state the panel shows. `live`: a worker in this process is running the job. Stored
    `queued` or `running` with no worker is a job the engine lost (it restarted): failed.
    A pending approval is what makes a running job `needs-you`."""
    stored = record.get("status")
    if stored == "stopped":
        return "stopped"
    if stored == "failed":
        return "failed"
    if stored == "finished":
        return "done"
    if stored in ("queued", "running") and not live:
        return "failed"
    if stored == "queued":
        return "queued"
    if stored == "running":
        return "needs-you" if record.get("pending") else "working"
    return "failed"             # a stored status this build doesn't know


def has_result(record: dict, state: str) -> bool:
    """A run that ended with a report the row shows: done, or stopped at the step limit."""
    return state == "done" or (state == "stopped" and record.get("stop_reason") == "limit")


def snapshot(record: dict, live: bool, line: str = "", schedule: dict | None = None,
             quiet: bool = False) -> dict:
    """The record as the `job` event the app shows: what the panel needs and nothing it mustn't
    (no taint source, no paths other than the files made; the sites it may use are shown). The
    brief IS shown, cut (D-172): the user sees what the job was told. `schedule`: the job's
    schedule as benji/schedule.shown made it, or None. `quiet`: a repeat run with nothing the user
    needs to hear about; the app makes no peek and no sound for it."""
    state = derive_state(record, live)
    pending = record.get("pending") if state == "needs-you" else None
    end = record.get("turn_end") or {}
    result = has_result(record, state)
    shown = {
        "id": record["id"],
        "title": record.get("title", ""),
        "state": state,
        "line": line if state == "working" else "",
        "pending": ({"request": pending.get("request", ""), "action": pending.get("action", ""),
                     "target": pending.get("target", "")} if isinstance(pending, dict) else None),
        "spoken": end.get("spoken", "") if result else "",
        "written": written_line(end) if result else "",
        "files": end.get("files", []) if result else [],
        "chips": end.get("chips", []) if result else [],
        "error": record.get("error", "") if state == "failed" else "",
        "tainted": bool(record_taints(record)),
        "taint": gate.taint_string(record_taints(record)),
        "sites": list((record.get("browser") or {}).get("origins", [])),
        "act_sites": list((record.get("browser") or {}).get("acts", [])),
        # D-172, all additive: an older app ignores them.
        "brief": str(record.get("brief") or "")[:MAX_BRIEF_SHOWN],
        "run": int(record.get("run") or 1),
        "done": end.get("done", "") if result else "",
        "left": end.get("left", "") if result else "",
        "ask": end.get("ask", "") if result else "",
        "stopped_at_limit": state == "stopped" and record.get("stop_reason") == "limit",
        "can_continue": state in ("failed", "stopped"),
        "unattended": bool(record.get("unattended")),
        "news": bool(record.get("news", True)),
        "quiet": bool(quiet),
        "schedule": schedule,
    }
    return shown


# ---- files made before the folder was renamed ----------------------------------------------------

def _current_paths(record: dict) -> dict:
    """A finished job's `turn_end.files` hold absolute paths, which name the folder as it was when the job
    ran. Read them as where the file is now, in the record as loaded only; the file on disk, the report and
    everything else keep their words. Only a path inside one of Benji's older default folders changes."""
    end = record.get("turn_end") if isinstance(record, dict) else None
    files = end.get("files") if isinstance(end, dict) else None
    if not isinstance(files, list):
        return record
    user_home = Path.home()
    for item in files:
        raw = item.get("path") if isinstance(item, dict) else None
        if not isinstance(raw, str):
            continue
        for name in home.OLD_NAMES:
            prefix = f"{user_home / name}/"
            if raw.startswith(prefix):
                moved = home.home_dir(user_home) / raw[len(prefix):]
                if not os.path.lexists(raw) and os.path.lexists(moved):
                    item["path"] = str(moved)
                break
    return record


# ---- the store --------------------------------------------------------------------------------

class JobStore:
    """`<workdir>/jobs/`: one folder per job."""

    def __init__(self, root: str | Path):
        self.root = Path(root)

    def path(self, job_id: str) -> Path:
        if not valid_id(job_id):
            raise ValueError(f"not a job id: {job_id!r}")
        return self.root / job_id

    def record_path(self, job_id: str) -> Path:
        """Beside the job's folder, never in it (D-177), like its schedule file."""
        if not valid_id(job_id):
            raise ValueError(f"not a job id: {job_id!r}")
        return self.root / f"{job_id}.json"

    def migrate(self) -> int:
        """At engine start, before any job runs: records from before D-177 move from `<id>/job.json`
        to beside the folder, and how many moved is returned. The old place is never read again, so
        a file a job later writes there means nothing. A link is not followed, and a record already
        beside its folder is not replaced."""
        try:
            folders = [p for p in self.root.iterdir() if p.is_dir() and valid_id(p.name)]
        except OSError:
            return 0
        moved = 0
        for where in folders:
            old, new = where / "job.json", self.record_path(where.name)
            if old.is_symlink() or not old.is_file() or os.path.lexists(new):
                continue
            try:
                os.replace(old, new)
                moved += 1
            except OSError as e:
                print(f"[Benji] job {where.name}: its record could not be moved ({type(e).__name__})", file=sys.stderr)
        return moved

    def create(self, title: str, brief: str, user_words: str, tainted_by: str = "",
               now: float | None = None, browser: dict | None = None, taints=None) -> dict:
        job_id = str(uuid.uuid4())
        where = self.path(job_id)
        for sub in ("output", "tmp"):
            (where / sub).mkdir(parents=True, exist_ok=True)
        record = {
            "version": VERSION, "id": job_id, "title": clean_title(title) or "Job",
            "brief": brief.strip(), "user_words": user_words.strip(),
            "created_at": time.time() if now is None else now, "started_at": None, "finished_at": None,
            "status": "queued", "pending": None, "tainted_by": tainted_by, "steers": [],
            # Which kinds of outside content the job has read or inherited (gate.TAINT_KINDS); the
            # rules read this set, `tainted_by` is only the words for a card.
            "taints": [k for k in gate.TAINT_KINDS if k in set(taints or [])],
            "turn_end": None, "error": "", "dismissed": False,
            # The sites this job may read in the user's Chrome (D-143): {origins, history}, or None.
            # Set only from a card the user answered; nothing a job reads can change it except
            # another card (benji/browser.py Grant.add).
            "browser": browser,
            # Runs (D-172): the number of the current run, which kind it is, whether nobody is
            # watching it (a scheduled run: read-class tools only), why a stopped run stopped
            # ("limit": the step cap), what the last run that finished found (hashes, for "anything
            # new?"), whether the latest finished run had news, and the hand-off brief's parts.
            "run": 1, "runs": [], "kind": "first", "unattended": False, "stop_reason": "",
            "last_result": None, "news": True, "handoff": None,
        }
        self.save(record)
        return record

    def load(self, job_id: str) -> dict | None:
        try:
            record = _current_paths(json.loads(self.record_path(job_id).read_text()))
        except (OSError, ValueError):
            return None
        return record if isinstance(record, dict) and record.get("id") == job_id else None

    def save(self, record: dict) -> None:
        """Written whole to a temporary file and renamed, so a crash never leaves half a record."""
        self.path(record["id"]).mkdir(parents=True, exist_ok=True)
        where = self.record_path(record["id"])
        tmp = where.with_name(where.name + ".tmp")
        tmp.write_text(json.dumps(record, ensure_ascii=False, indent=1))
        os.replace(tmp, where)

    def all(self) -> list[dict]:
        """Every readable record, newest first."""
        found = []
        try:
            names = [p.name[:-len(".json")] for p in self.root.iterdir() if p.name.endswith(".json")]
        except OSError:
            return []
        for name in names:
            record = self.load(name) if valid_id(name) else None
            if record is not None:
                found.append(record)
        found.sort(key=lambda r: r.get("created_at", 0), reverse=True)
        return found

    def latest(self) -> dict | None:
        """The newest job the user hasn't cleared."""
        return next((r for r in self.all() if not r.get("dismissed")), None)

    def recover(self) -> list[str]:
        """At start: a job stored as queued or running has no worker any more. It is marked failed
        ("Benji restarted…") so the record says what the derived state already would."""
        changed = []
        for record in self.all():
            if record.get("status") in ("queued", "running"):
                record.update(status="failed", pending=None, error=INTERRUPTED, finished_at=time.time())
                self.save(record)
                changed.append(record["id"])
        return changed

    def resolve(self, ident: str) -> dict | None:
        """A record by full id, or by a unique prefix of at least MIN_PREFIX characters."""
        ident = (ident or "").strip().lower()
        if valid_id(ident):
            return self.load(ident)
        if len(ident) < MIN_PREFIX or not re.fullmatch(r"[0-9a-f-]+", ident):
            return None
        hits = [r for r in self.all() if r["id"].startswith(ident)]
        return hits[0] if len(hits) == 1 else None

    def report_path(self, job_id: str) -> Path:
        return self.path(job_id) / "report.md"


def clean_title(title: str) -> str:
    return " ".join(str(title or "").split())[:MAX_TITLE_CHARS]


def brief_message(record: dict) -> str:
    """The job's first message of a run: the user's own words, which win, then the brief Benji
    wrote from them, then (for a later run) what kind of run this is and what the last one left."""
    words = record.get("user_words", "").strip()
    asked = f"The user's own words (they win over anything below):\n{words}\n\n" if words else ""
    return f"{asked}Brief, written by Benji from them:\n{record.get('brief', '').strip()}\n\n{run_note(record)}Work on it now."


def run_note(record: dict) -> str:
    """For a run after the first: which run, why it started, and what the last finished run said
    (the model's own earlier report: data to build on, not instructions)."""
    kind, n = record.get("kind", "first"), int(record.get("run") or 1)
    if kind == "first" and n <= 1:
        return ""
    last = record.get("last_result") or {}
    before = str(last.get("written") or "")[:300]
    prev = record.get("prev") or {}
    left = str(prev.get("left") or "")[:300]
    if kind == "scheduled":
        text = (f"This is run {n} of a job the user set to repeat. Nobody is watching it. You may read and search; "
                "anything that writes, runs a command or uses the browser waits for the user, so don't plan on it. "
                "Report only what is new since the last run, and list each finding in `items`.")
        if before:
            text += f"\nWhat the last run reported (data from your own earlier report): {before}"
    else:
        text = (f"This is run {n} of the same job: the user asked you to carry on after it stopped. Don't redo what "
                "is already in the folder; look at it, then finish what is left.")
        if left:
            text += f"\nWhat was left (data from your own earlier report): {left}"
        elif prev.get("error"):
            text += f"\nWhy the last run stopped: {prev['error']}"
    return text + "\n\n"


# ---- hand-off: the brief a foreground turn gives a job (D-172) ----------------------------------

_URL = re.compile(r"https?://[^\s<>\"')\]]+", re.IGNORECASE)
_BARE_HOST = re.compile(r"(?<![\w@/.-])(?:[a-z0-9-]+\.)+(?:com|org|net|io|co|app|dev|ai|edu|gov|uk|de|fr|info|me|us)\b", re.IGNORECASE)
_PATH_WORDS = re.compile(r"(?<![\w/])(?:~|/)[\w@+.,-]*(?:/[\w@+.,~-]+)+/?|(?<![\w/@.-])[\w.-]+\.(?:txt|md|pdf|csv|tsv|json|docx?|xlsx?|pptx?|py|js|ts|swift|html?|png|jpe?g|zip|rtf)\b")


def mentioned_sites(texts: list[str]) -> list[str]:
    """The sites the user's own words named (an address, or a bare name such as example.com), in
    order, no repeats."""
    import urllib.parse
    seen: list[str] = []
    for text in texts:
        found = [urllib.parse.urlsplit(u).hostname or "" for u in _URL.findall(text)]
        found += [h.lower() for h in _BARE_HOST.findall(_URL.sub(" ", text))]
        for host in found:
            host = host.lower().strip(".")
            if host and host not in seen:
                seen.append(host)
    return seen[:8]


def mentioned_files(texts: list[str]) -> list[str]:
    """Paths and file names in the user's own words. A private path (keys, credentials) is dropped,
    as everywhere; a name with a dot only, with no folder, stays ("notes.md")."""
    seen: list[str] = []
    for text in texts:
        for m in _PATH_WORDS.finditer(_URL.sub(" ", text)):
            raw = m.group(0).strip(" .,;:)")
            if not raw or raw in seen:
                continue
            if "/" in raw and gate.private_path(Path(raw).expanduser()):
                continue
            seen.append(raw[:160])
    return seen[:8]


def conversation_slice(messages: list[dict]) -> list[str]:
    """The last few things the USER said in this conversation, oldest first, each cut. Only the
    user's own messages: nothing an assistant, a tool or a page wrote."""
    said = []
    for m in messages:
        if m.get("role") != "user":
            continue
        text = " ".join(str(m.get("text") or "").split())
        if text and not text.startswith("[The user steers"):
            said.append(text[:MAX_SAID_CHARS])
    return said[-MAX_SAID:]


def handoff_brief(goal: str, done: str, said: list[str], current: str = "",
                  max_chars: int = MAX_HANDOFF_CHARS) -> tuple[str, dict]:
    """(the brief text, its parts) for a job started from a foreground turn: the goal as Benji
    stated it and what done means, then the conversation's last user messages, the sites and files
    they named. Built in code from the model's stated goal and a bounded slice of the conversation,
    so a job gets what was agreed and not only the last words."""
    asked = said + ([current[:MAX_SAID_CHARS]] if current.strip() else [])
    sites, files = mentioned_sites(asked), mentioned_files(asked)
    lines = [f"Goal (as Benji stated it): {goal.strip()}"]
    if done.strip():
        lines.append(f"Done means (as Benji stated it): {done.strip()}")
    if said:
        lines += ["What the user said in this conversation, oldest first (their words):"]
        lines += [f"  {i}. {t}" for i, t in enumerate(said, 1)]
    if sites:
        lines.append("Sites the user named: " + ", ".join(sites))
    if files:
        lines.append("Files the user named: " + ", ".join(files))
    text = "\n".join(lines)
    if len(text) > max_chars:
        text = text[:max_chars - 1].rstrip() + "…"
    return text, {"goal": goal.strip()[:1200], "done": done.strip()[:400], "said": said, "sites": sites, "files": files}


def earlier_said(messages: list[dict], current: str) -> list[str]:
    """The user's messages before this turn's own (which a job gets word for word as its own words)."""
    said = conversation_slice(messages)
    if said and said[-1] == " ".join(current.split())[:MAX_SAID_CHARS]:
        said = said[:-1]
    return said


# ---- long jobs: the brief read again (D-172) -----------------------------------------------------

RULES_TEXT = ("Rules that hold for the whole job: the user's own words win over the brief; anything that writes, "
              "sends or changes something outside your folder is asked on a card and may wait; if it is declined, "
              "adapt; you can't start another job or schedule anything; end with a short report that says what is "
              "done, what is left, and asks the user, then the JSON object.")


def reread_due(step: int, resumed: bool, every: int = REREAD_EVERY) -> bool:
    """After a tool step number `step` (1-based): read the brief again at fixed intervals, and
    whenever the job came back from a park. Code decides; the model is not asked."""
    return resumed or (step > 0 and every > 0 and step % every == 0)


def reread_message(record: dict, reason: str = "interval") -> str:
    """The brief, the rules and the grants, from the record, as text for the model to read again.
    Bounded; it names no outside content (the brief is Benji's, the words the user's)."""
    words = str(record.get("user_words") or "").strip()[:600]
    sites = list((record.get("browser") or {}).get("origins", []))
    steers = [str(s.get("text") or "")[:200] for s in (record.get("steers") or [])[-3:] if isinstance(s, dict)]
    lines = [f"[Benji reads this job's brief to you again" + (" now that you are back from waiting" if reason == "resume" else "")
             + " so it doesn't drift. It is not a new message from the user.]",
             f"Job: {record.get('title', '')}"]
    if words:
        lines.append(f"The user's own words: {words}")
    lines.append(f"Brief: {str(record.get('brief') or '').strip()[:1200]}")
    if steers:
        lines.append("Steers so far: " + " | ".join(steers))
    lines.append("Sites you may read in their Chrome: " + (", ".join(sites) if sites else "none"))
    if record.get("unattended"):
        lines.append("This run is unattended: only read and search; anything else waits for the user.")
    lines.append(RULES_TEXT)
    return "\n".join(lines)


def limit_warning(left: int) -> str:
    return (f"[Benji: you have {left} steps left in this run. Stop starting new work; make sure what you made is "
            "saved, then write the report: what is done, what is left, and a question for the user, then the JSON object.]")


def limit_prompt() -> str:
    return ("[Benji: this run is out of steps. Do not call any tool. Write the final report now in plain words: what "
            "is done, what is left, and one question for the user, then the JSON object with `done`, `left` and `ask`.]")


def limit_end(record: dict, job_folder: Path, text: str, steps: int, cap: int | None = None) -> tuple[str, dict]:
    """(report body, turn_end) for a run that hit the step cap, or that was warned it nearly had and
    wrapped up (`steps` then is fewer than `cap`, D-177). The model's wrap-up is used when it
    gave one; code always says plainly that this stopped at the limit, and fills `done`, `left` and
    `ask` itself when the model didn't, from what is on disk. Never a silent failure."""
    body, end = build_turn_end(text, job_folder) if text.strip() else ("", build_turn_end("", job_folder)[1])
    made = sorted(p.name for p in (job_folder / "output").glob("*") if p.is_file())[:6]
    if not end.get("done"):
        end["done"] = ("Made " + ", ".join(made) + ".") if made else "Nothing was saved to its folder yet."
    if not end.get("left"):
        end["left"] = "Whatever the brief asked for beyond that. Press Continue and it picks up from its folder."
    if not end.get("ask"):
        end["ask"] = "Want me to carry on from here?"
    cap = cap or steps
    early = steps < cap
    used = f"{steps} of its {cap} steps" if early else f"its {steps} steps"
    plain = f"{LIMIT_STOP} It used {used}. Done: {end['done']} Left: {end['left']}"
    end["written"] = spoken_from(plain, MAX_WRITTEN_CHARS)
    end["spoken"] = spoken_from(plain, MAX_SPOKEN_CHARS)
    how = f"It was told its steps were nearly out and stopped after {steps} of {cap}." if early else f"It used all {steps} steps of this run."
    lead = f"**{LIMIT_STOP}** {how}\n\n"
    return lead + (body or "(The job wrote no report of its own before it ran out.)"), end


# ---- failures, in plain words (D-172) ------------------------------------------------------------

def plain_failure(exc: BaseException | None, kind: str = "internal") -> str:
    """What the row says when a run fails: what happened and what the user can do, never a repr
    or a traceback. Provider errors are worded by providers.plain_message."""
    from .providers import ProviderError, plain_message
    if isinstance(exc, ProviderError):
        return plain_message(exc)
    return ("Something went wrong inside Benji before this finished. It is not something you did; "
            "Copy diagnostics in Settings has the details. You can press Continue to try again.")


# ---- repeat runs: anything new? (D-172) ----------------------------------------------------------

def _norm(text: object) -> str:
    return " ".join(str(text or "").casefold().split())


def _fp(text: object) -> str:
    import hashlib
    return hashlib.sha1(_norm(text).encode()).hexdigest()[:12]


def clean_items(raw: object) -> list[str]:
    """The findings a repeat run lists, as short strings: trimmed, no repeats, bounded."""
    if not isinstance(raw, list):
        return []
    items: list[str] = []
    for item in raw:
        if isinstance(item, (str, int, float)) and not isinstance(item, bool):
            text = " ".join(str(item).split())[:MAX_ITEM_CHARS]
            if text and _norm(text) not in {_norm(i) for i in items}:
                items.append(text)
        if len(items) == MAX_ITEMS:
            break
    return items


def result_of(end: dict) -> dict:
    """What a finished run is remembered by for the next comparison: hashes of its findings and of
    its written line (the findings' words themselves are in the report, not here)."""
    return {"fp": sorted({_fp(i) for i in end.get("items") or []}), "written_fp": _fp(written_line(end)),
            "written": written_line(end)[:300]}


def is_news(last: dict | None, end: dict) -> bool:
    """Did this run find anything the last one didn't? Decided here, from the two structured
    results, never from what the model says about it. The first run is news. With findings listed:
    news means a finding the last run didn't have (one that went away is not news). Without: the
    written line differs."""
    if not isinstance(last, dict) or not last:
        return True
    now = result_of(end)
    if now["fp"]:
        return bool(set(now["fp"]) - set(last.get("fp") or []))
    return now["written_fp"] != last.get("written_fp")


def begin_run(record: dict, kind: str, now: float, unattended: bool = False) -> None:
    """Make a finished or stopped job ready for another run of the same job: archive what the
    last run was, reset what belongs to one run (state, pending approval, end, error) and keep
    the folder, the brief, the steers and the taint."""
    end = record.get("turn_end") or {}
    # What the last run left, for the next run's first message (the model's own report: data).
    record["prev"] = {"left": str(end.get("left") or ""), "done": str(end.get("done") or ""),
                      "error": str(record.get("error") or "")[:300]}
    if record.get("started_at") is not None or record.get("status") in ("finished", "failed", "stopped"):
        runs = record.setdefault("runs", [])
        runs.append({"n": int(record.get("run") or 1), "kind": record.get("kind", "first"),
                     "at": record.get("started_at") or record.get("created_at"),
                     "ended": record.get("finished_at"), "status": record.get("status"),
                     "news": bool(record.get("news", True))})
        del runs[:-MAX_RUN_HISTORY]
        record["run"] = int(record.get("run") or 1) + 1
    record.update(kind=kind if kind in RUN_KINDS else "continued", unattended=bool(unattended), status="queued",
                  pending=None, turn_end=None, error="", started_at=None, finished_at=None,
                  stop_reason="", dismissed=False if not unattended else record.get("dismissed", False))


# ---- the turn_end -----------------------------------------------------------------------------

def parse_turn_end(text: str) -> tuple[str, dict | None]:
    """(the message without its turn_end, the turn_end object or None). Lenient: the object may
    be fenced or labelled, may come anywhere near the end, and need only name one of `spoken`,
    `files`, `chips`. The last such object wins."""
    decoder = json.JSONDecoder()
    start = len(text)
    while True:
        start = text.rfind("{", 0, start)
        if start < 0:
            return text.strip(), None
        try:
            obj, end = decoder.raw_decode(text, start)
        except ValueError:
            continue
        if isinstance(obj, dict) and any(k in obj for k in ("spoken", "written", "files", "chips", "done", "left", "ask", "items")):
            head, tail = text[:start], text[end:]
            head = re.sub(r"(?:`{3,}\s*(?:json|turn_end)?\s*|turn[_ ]end\s*:?\s*)\s*$", "", head,
                          flags=re.IGNORECASE)
            tail = re.sub(r"^\s*`{3,}", "", tail)
            return (head + tail).strip(), obj


def spoken_from(text: str, limit: int = MAX_SPOKEN_CHARS) -> str:
    """A spoken line cut from a message that gave none: its first sentences, at most `limit`."""
    flat = " ".join(re.sub(r"[#*_`>]+", " ", text).split())
    if len(flat) <= limit:
        return flat
    cut = flat[:limit]
    stop = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    return (cut[:stop + 1] if stop >= 60 else flat[:limit - 1].rstrip() + "…")


# The written line (D-146): what the row, the peek and the report show, while `spoken` is for the
# speaker. A voice line says "output slash tea dot txt"; the screen should say output/tea.txt.
_SAID_WORD = r"[A-Za-z0-9_~]+"
_SAID_SEP = r"(?:slash|dot|dash|underscore)"
_SAID_RUN = re.compile(rf"\b{_SAID_WORD}(?: {_SAID_SEP} {_SAID_WORD})+\b", re.IGNORECASE)
_SAID_EXT = re.compile(r" dot (?:txt|md|py|json|csv|tsv|pdf|html?|js|ts|swift|png|jpe?g|gif|docx?|xlsx?|pptx?|ya?ml|"
                       r"log|zip|rtf|xml|sh|toml|rb|go|rs|c|h|cpp)\b", re.IGNORECASE)
_SAID_SIGNS = {"slash": "/", "dot": ".", "dash": "-", "underscore": "_"}


def _written_run(m: re.Match) -> str:
    run = m.group(0)
    if " slash " not in run.lower() and not _SAID_EXT.search(run):
        return run                      # "will dot the": ordinary words, left alone
    out = re.sub(rf" ({_SAID_SEP}) ", lambda s: _SAID_SIGNS[s.group(1).lower()], run, flags=re.IGNORECASE)
    return re.sub(r"\btilde/", "~/", out, flags=re.IGNORECASE)


def written_from(spoken: str) -> str:
    """A written line made from a spoken one when the model gave none: spoken paths written as
    paths, markdown out, at most MAX_WRITTEN_CHARS cut at a sentence."""
    return spoken_from(_SAID_RUN.sub(_written_run, " ".join(str(spoken or "").split())), MAX_WRITTEN_CHARS)


def written_line(end: dict) -> str:
    """The line a done job shows: the turn_end's written line, or one made from its spoken line
    (a record from before the written line existed)."""
    return str(end.get("written") or "") or written_from(str(end.get("spoken") or ""))


def clean_chips(raw: object) -> list[str]:
    if not isinstance(raw, list):
        return []
    chips: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            continue
        chip = " ".join(item.split())[:MAX_CHIP_CHARS].strip()
        if chip and chip.casefold() not in {c.casefold() for c in chips}:
            chips.append(chip)
        if len(chips) == MAX_CHIPS:
            break
    return chips


def check_files(claimed: object, job_folder: Path) -> tuple[list[dict], int]:
    """([{name, path}] for the files that exist, how many claimed files don't). A relative path is
    the job's folder (then its output/). A private path is dropped, as everywhere."""
    if not isinstance(claimed, list):
        return [], 0
    found: list[dict] = []
    missing = 0
    seen: set[str] = set()
    for item in claimed[:MAX_FILES * 2]:
        raw = item.get("path") if isinstance(item, dict) else item
        if not isinstance(raw, str) or not raw.strip():
            continue
        given = Path(raw.strip()).expanduser()
        candidates = [given] if given.is_absolute() else [job_folder / given, job_folder / "output" / given]
        path = next((c for c in candidates if c.is_file()), None)
        if path is None:
            missing += 1
            continue
        if gate.private_path(path):
            continue
        real = str(path.resolve())
        if real in seen:
            continue
        seen.add(real)
        found.append({"name": path.name, "path": real})
        if len(found) == MAX_FILES:
            break
    return found, missing


def _line(raw: object, limit: int) -> str:
    return " ".join(str(raw or "").split())[:limit]


def ask_default(left: str) -> str:
    """The question a report ends with when the model asked none (D-172): a job reports back and
    asks, it never decides to go on by itself."""
    nothing = _norm(left).strip(" .") in ("", "nothing", "none", "nothing left", "nothing is left", "n/a")
    return "Anything you'd like changed, or should I do something next?" if nothing else "Want me to carry on with what's left?"


def build_turn_end(final_text: str, job_folder: Path) -> tuple[str, dict]:
    """(the report body, the turn_end) for a job's last message. The turn_end says what was done,
    what is left, and asks the user (D-172): code fills `ask` when the model didn't ask."""
    body, raw = parse_turn_end(final_text)
    raw = raw or {}
    spoken = " ".join(str(raw.get("spoken") or "").split())[:MAX_SPOKEN_CHARS] or spoken_from(body)
    written = spoken_from(str(raw.get("written") or ""), MAX_WRITTEN_CHARS) or written_from(spoken)
    files, missing = check_files(raw.get("files"), job_folder)
    done, left = _line(raw.get("done"), 240), _line(raw.get("left"), 240)
    ask = _line(raw.get("ask"), 160)
    if not ask.endswith("?"):
        ask = ask_default(left)
    return body, {"spoken": spoken, "written": written, "files": files, "missing_files": missing,
                  "chips": clean_chips(raw.get("chips")), "done": done, "left": left, "ask": ask,
                  "items": clean_items(raw.get("items"))}


# ---- the report and recall --------------------------------------------------------------------

def write_report(store: JobStore, record: dict, body: str, latest: bool = True) -> None:
    """report.md: what was asked, what came of it, the files. Written by code from the record and
    the job's last message, so a recall can rely on its shape. Every run also keeps its own copy
    in `reports/run-N.md` (the report history of a job that runs again); `latest` False (a repeat
    run that found nothing new) leaves report.md as it was, so recall still finds the last news."""
    end = record.get("turn_end") or {}
    run = int(record.get("run") or 1)
    lines = [f"# {record.get('title', 'Job')}", "",
             f"- Job: {record['id']}",
             f"- Run: {run}" + (" (scheduled, unattended)" if record.get("unattended") else ""),
             f"- Result: {derive_state(record, False)}" + (" (stopped at the step limit)" if record.get("stop_reason") == "limit" else ""),
             f"- Started: {_stamp(record.get('started_at') or record.get('created_at'))}",
             f"- Finished: {_stamp(record.get('finished_at'))}", ""]
    if record.get("user_words"):
        lines += ["## Asked", "", record["user_words"], ""]
    if written_line(end):
        lines += ["## In short", "", written_line(end), ""]
    if end.get("done"):
        lines += ["## Done", "", end["done"], ""]
    if end.get("left"):
        lines += ["## Left", "", end["left"], ""]
    if end.get("ask"):
        lines += ["## Question for you", "", end["ask"], ""]
    if body.strip():
        lines += ["## Report", "", body.strip(), ""]
    if end.get("files"):
        lines += ["## Files", ""] + [f"- {f['name']}: {f['path']}" for f in end["files"]] + [""]
    if record.get("steers"):
        lines += ["## Steered", ""] + [f"- {s.get('text', '')}" for s in record["steers"]] + [""]
    if record.get("error"):
        lines += ["## Problem", "", record["error"], ""]
    text = "\n".join(lines)
    history = store.path(record["id"]) / "reports"
    history.mkdir(exist_ok=True)
    (history / f"run-{run:04d}.md").write_text(text)
    if latest or not store.report_path(record["id"]).exists():
        store.report_path(record["id"]).write_text(text)


def _stamp(at: object) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(at)) if isinstance(at, (int, float)) else "-"


def _report_text(store: JobStore, record: dict) -> str:
    try:
        return store.report_path(record["id"]).read_text(errors="replace")[:MAX_REPORT_CHARS]
    except OSError:
        return ""


def find_jobs(store: JobStore, query: str = "", limit: int = 5,
              live_ids: frozenset[str] = frozenset()) -> list[dict]:
    """Past jobs that match `query` (simple local search: the query's words in the title, the
    ask and the report; a title hit counts double), best first; no query: the newest. Each is
    {id, title, state, day, snippet}. No embeddings."""
    words = {w for w in re.findall(r"[a-z0-9]+", (query or "").casefold()) if len(w) > 1}
    scored = []
    for record in store.all():
        report = _report_text(store, record)
        title = record.get("title", "").casefold()
        hay = f"{record.get('user_words', '')} {record.get('brief', '')} {report}".casefold()
        score = sum((2 if w in title else 0) + (1 if w in hay or w in title else 0) for w in words)
        if words and not score:
            continue
        scored.append((score, record.get("created_at", 0), record, report))
    scored.sort(key=lambda s: (s[0], s[1]), reverse=True)
    out = []
    for _, _, record, report in scored[:limit]:
        end = record.get("turn_end") or {}
        out.append({"id": record["id"], "title": record.get("title", ""),
                    "state": derive_state(record, record["id"] in live_ids), "day": _stamp(record.get("created_at"))[:10],
                    "snippet": "" if record.get("status") in ("queued", "running") else
                               written_line(end) or spoken_from(report)[:120]})
    return out


def read_job(store: JobStore, ident: str, live_ids: frozenset[str] = frozenset()) -> str | None:
    """The report (cut to MAX_REPORT_CHARS); queued/running jobs prepend their current state
    and label retained text as the previous report. With no report, return the current state;
    return None when no job has that id or unique id prefix."""
    record = store.resolve(ident)
    if record is None:
        return None
    report = _report_text(store, record)
    if not report:
        state = derive_state(record, record["id"] in live_ids)
        return f"# {record.get('title', 'Job')}\n\n- Result: {state}\n(no report was written)"
    if record.get("status") in ("queued", "running"):
        state = derive_state(record, record["id"] in live_ids)
        return f"- Current state: {state}\n\n## Previous report\n\n{report}"
    return report
