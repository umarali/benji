"""Drive mode: the user lets Benji take over the screen for one stated goal."""

from __future__ import annotations

from typing import Any

from .. import audit
from .. import drive as drive_mod
from .. import jobs as jobs_mod
from .context import Ctx


# offer_drive, start_drive and end_drive: the user lets Benji take over the screen for one stated
# goal. The rules are benji/drive.py's; this is the tool surface. offer_drive and start_drive are
# asked on the drive card (agent.py asks it, serve.py words it: 45 s, only the app's own button or
# key grants); the handlers below run only after a yes, or when the goal was already agreed to.

DRIVE_TOOL_NAMES = ("offer_drive", "start_drive", "end_drive")
DRIVE_CONSENT_TOOLS = ("offer_drive", "start_drive")


def _drive_refusal(ctx: Ctx) -> tuple[bool, str]:
    d = ctx.drive
    if d is None or ctx.screen is None:
        return False, "drive_unusable"
    if ctx.screen_stopped:
        return False, "drive_stopped"
    return d.usable(ctx.taints, ctx.scope)


_DRIVE_WHY = {
    "drive_unusable": "Driving the screen isn't available here (it needs a turn the user started, with the screen attached and "
                      "\"Act on simple steps\" on). Carry on without it.",
    "drive_stopped": "The user took the screen back this turn. Don't drive again in this turn.",
    "drive_declined": "The user said no to taking over the screen (or didn't answer). Don't ask again this turn.",
    "drive_tainted": "This turn has read content from outside the user's screen (a web page, their browser or a file), so "
                     "Benji won't take over the screen in it. Tell the user; they can ask again in a fresh message.",
}


def drive_granted(ctx: Ctx, name: str, tool_input: dict[str, Any]) -> None:
    """The user said yes on the drive card for exactly this goal (agent.py calls this after the card)."""
    d = ctx.drive
    if d is not None:
        goal = drive_mod.clean_goal(tool_input.get("goal"))
        d.agree(goal)
        d.yes = True
        audit.event("drive", ctx.run, state="granted", scope=ctx.scope)


def drive_declined(ctx: Ctx, timed_out: bool = False) -> None:
    d = ctx.drive
    if d is not None:
        d.decline()
        audit.event("drive", ctx.run, state="timeout" if timed_out else "declined", scope=ctx.scope)


def end_drive(ctx: Ctx, reason: str, spoken: str = "", written: str = "") -> dict | None:
    """End the turn's drive (once), tell the front-end and write it to the audit log."""
    d = ctx.drive
    if d is None:
        return None
    record = d.end(reason, spoken, written)
    if record is not None:
        audit.event("drive", ctx.run, state="ended", why=record["reason"], steps=min(record["steps"], 100_000),
                    scope=ctx.scope)
    return record


def _offer_drive(ctx: Ctx, goal: str = "") -> str:
    ok, code = _drive_refusal(ctx)
    if not ok:
        ctx.denied_code = code
        return f"[refused] {_DRIVE_WHY.get(code, _DRIVE_WHY['drive_unusable'])}"
    d, goal = ctx.drive, drive_mod.clean_goal(goal)
    if not goal:
        return "[error] say in goal what you will do with the screen, in a few words."
    if d.active:
        return f"[ok] Already driving: {d.goal}. Carry on with it."
    if not (d.yes or d.consented(goal)):
        ctx.denied_code = "tool_refused"
        return "[refused] The user's yes wasn't given, so nothing was agreed."
    d.yes = False
    return (f"[ok] The user agreed to you taking over the screen to: {d.offered_goal}. Call start_drive with "
            "the same goal when you are ready.")


def _start_drive(ctx: Ctx, goal: str = "") -> str:
    ok, code = _drive_refusal(ctx)
    if not ok:
        ctx.denied_code = code
        return f"[refused] {_DRIVE_WHY.get(code, _DRIVE_WHY['drive_unusable'])}"
    d, goal = ctx.drive, drive_mod.clean_goal(goal)
    if not goal:
        return "[error] say in goal what you will do with the screen, in a few words."
    if d.active:
        return f"[ok] Already driving: {d.goal}. Carry on with it."
    if not (d.yes or d.consented(goal)):
        ctx.denied_code = "tool_refused"
        return "[refused] This needs the user's yes on the drive card, and it wasn't given. Don't try it again."
    d.yes = False
    d.begin(goal)
    audit.event("drive", ctx.run, state="started", scope=ctx.scope)
    return ("[ok] Driving: " + d.goal + ". Scrolling is free; clicks, typing and keys go ahead one step at a time "
            "while the user watches, except anything that looks like sending, buying, paying, deleting, "
            "posting or confirming, which asks them each time. Never a password, card or code field. The "
            "user can stop with Esc, by typing or by pressing Stop. One step, then look at the new screenshot. "
            "When done, call end_drive with one plain sentence.")


def _end_drive_tool(ctx: Ctx, spoken: str = "", written: str = "") -> str:
    d = ctx.drive
    if d is None or not d.active:
        return "[ok] No drive is on."
    spoken = " ".join(str(spoken or "").split())[:jobs_mod.MAX_SPOKEN_CHARS]
    written = jobs_mod.spoken_from(str(written or ""), jobs_mod.MAX_WRITTEN_CHARS) or jobs_mod.written_from(spoken)
    end_drive(ctx, "finished", spoken, written)
    return "[ok] Drive over: the screen is the user's again. Your reply now is the last thing they read and hear."
