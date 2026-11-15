"""Background jobs: starting, finding and reading them."""

from __future__ import annotations

from typing import Any

from .. import browser as browser_mod
from .. import jobs as jobs_mod
from .. import schedule as schedule_mod
from .context import Ctx, _truncate


IN_JOB_REFUSAL = ("[refused] A job can't start another job or change a schedule, and can't send itself more "
                  "work. Put what is left in your report and ask the user.")


def _start_job(ctx: Ctx, title: str, brief: str, sites: list | None = None, repeat: Any = None,
               done_when: str = "") -> str:
    yes, ctx.browser_yes = ctx.browser_yes, False
    if ctx.scope == "job":
        return IN_JOB_REFUSAL
    if ctx.start_job is None:
        return "[error] background jobs aren't available here"
    if not str(brief or "").strip():
        return "[error] start_job needs a brief"
    spec = None
    if repeat:
        if not ctx.schedule_offer:
            return "[error] Repeating jobs aren't available in this app; start the job without `repeat`."
        spec, problem = schedule_mod.clean_repeat(repeat)
        if spec is None:
            return f"[error] repeat: {problem}"
    extra: dict[str, Any] = {"done_when": str(done_when)} if str(done_when or "").strip() else {}
    if spec is not None:
        extra["repeat"] = spec
        if not yes:
            return "[refused] The user didn't approve repeating this job. Start it without `repeat`, or ask what to change."
    if not sites:
        return ctx.start_job(str(title or ""), str(brief), **extra)
    if not ctx.browser_offer:
        return "[error] Browser access for jobs is off in Benji's settings; start the job without sites."
    origins, problems = browser_mod.normalize_sites(sites)
    if problems or not origins:
        return "[error] sites: " + "; ".join(problems or ["none given"]) + ". Use https addresses of public sites."
    if not yes:
        return "[refused] The user didn't approve these sites. Start the job without them, or ask what to change."
    return ctx.start_job(str(title or ""), str(brief), sites=origins, **extra)


def _schedule_job(ctx: Ctx, repeat: Any, job: str = "") -> str:
    yes, ctx.browser_yes = ctx.browser_yes, False
    if ctx.scope == "job":
        return IN_JOB_REFUSAL
    if ctx.set_schedule is None or not ctx.schedule_offer:
        return "[error] repeating jobs aren't available here"
    if _is_off(repeat):
        spec = None
    else:
        spec, problem = schedule_mod.clean_repeat(repeat)
        if spec is None:
            return f"[error] repeat: {problem}"
    if not yes:
        return "[refused] The user didn't approve this change to the schedule. Leave it as it is."
    return ctx.set_schedule(str(job or ""), spec)


def _is_off(repeat: Any) -> bool:
    return repeat is None or (isinstance(repeat, str) and repeat.strip().lower() in ("off", "none", "stop", "never"))


def _find_jobs(ctx: Ctx, query: str = "") -> str:
    if ctx.jobs is None:
        return "[error] no jobs here"
    found = jobs_mod.find_jobs(ctx.jobs, str(query or ""), live_ids=ctx.live_job_ids())
    if not found:
        return f"[no jobs match {query!r}]" if query else "[no jobs yet]"
    return _truncate("\n".join(f"- {j['id']} \"{j['title']}\" ({j['state']}, {j['day']}): {j['snippet']}"
                               for j in found))


def _read_job(ctx: Ctx, id: str) -> str:
    if ctx.jobs is None:
        return "[error] no jobs here"
    record = ctx.jobs.resolve(str(id or ""))
    report = jobs_mod.read_job(ctx.jobs, str(id or ""), live_ids=ctx.live_job_ids())
    if record is None or report is None:
        return f"[error] no job with the id {id!r} (find_jobs lists them)"
    if record.get("tainted_by"):    # a report built on outside content is outside content
        ctx.taint(f"a past job's report (it read {record['tainted_by']})", kinds=jobs_mod.record_taints(record))
    return _truncate(report)
