"""Browser reach: opening, listing, reading and acting on tabs of sites the user granted."""

from __future__ import annotations

import urllib.parse
from typing import Any, Callable

from .. import audit
from .. import browser as browser_mod
from .. import browser_act
from .. import drive as drive_mod
from .. import screen_class
from ..browser_link import LinkError
from .context import Ctx, ToolCancelled, _resolve, _truncate, _with_note
from .drive_mode import DRIVE_TOOL_NAMES
from .screen_actions import SCREEN_TOOL_NAMES


BROWSER_TOOL_NAMES = browser_mod.TOOL_NAMES        # open, tabs and read, classed by browser_mod.plan


def browser_approved(ctx: Ctx, name: str, tool_input: dict[str, Any]) -> None:
    """The user said yes on the card for this call. Only here can a site join a job's grant, and
    only for the origin the card named."""
    ctx.browser_yes = True
    if name == "browser_open" and ctx.browser is not None:
        origin = browser_mod.origin_of(tool_input.get("url"))
        if origin is not None and ctx.browser.add(origin, "card"):
            audit.event("browser_grant", ctx.run, job=ctx.run, host=audit.host_of(origin), how="card")


def decline_target(ctx: Ctx, name: str, inp: dict[str, Any]) -> str:
    """What a "not now" is about, for decline memory: the thing the call acts on, normalised (a
    resolved path, a command, a host, an origin, a title). Hashed by the memory; not logged."""
    inp = inp if isinstance(inp, dict) else {}
    if name in ("write_file", "read_file", "list_dir", "search_files"):
        return str(_resolve(ctx, inp.get("path") or "."))
    if name == "run_shell":
        return str(inp.get("command", ""))
    if name == "web_fetch":
        return urllib.parse.urlsplit(str(inp.get("url", ""))).hostname or str(inp.get("url", ""))
    if name in BROWSER_TOOL_NAMES:
        return browser_mod.origin_of(inp.get("url")) or str(inp.get("tab", ""))
    if name in DRIVE_TOOL_NAMES:
        return drive_mod.goal_key(inp.get("goal"))     # offer and start share one key; extra arguments don't change it
    if name == "start_job":
        return str(inp.get("title", "")) + str(inp.get("repeat", "")) + str(inp.get("sites", ""))
    if name == "schedule_job":
        return str(inp.get("job", "")) + str(inp.get("repeat", ""))
    for key in ("text", "script", "name", "title"):
        if key in inp:
            return str(inp[key])
    return repr(sorted(inp.items(), key=lambda kv: kv[0]))


def _always(ctx: Ctx) -> tuple:
    """The user's "always allow reading" sites, for a call that reads. Not for a scheduled run: nobody is
    there to have meant it."""
    return () if ctx.unattended else ctx.browser_always


def _act_allowed(ctx: Ctx, name: str) -> bool:
    """May this job look at controls, act or upload? Never a scheduled run; never when the app didn't say it
    can carry acting out, or policy.json switched acting (or uploads) off (both set on the Ctx)."""
    if ctx.unattended or not ctx.browser_act_ok:
        return False
    return ctx.browser_upload_ok if name == "browser_upload" else True


def never_auto_approved(name: str, tool_input: dict[str, Any]) -> bool:
    """Calls the user answers even when the front-end would otherwise approve for them: they act
    as the user, in their apps or their browser."""
    return (name in SCREEN_TOOL_NAMES or name in BROWSER_TOOL_NAMES or name in DRIVE_TOOL_NAMES
            or name in browser_mod.JOB_TOOL_NAMES or name == browser_mod.ACTIVE_TOOL
            or (name == "start_job" and bool(tool_input.get("sites") or tool_input.get("repeat")))
            or name == "schedule_job")


def _browser_tool(name: str) -> Callable[..., str]:
    def handler(ctx: Ctx, **inp) -> str:
        yes, ctx.browser_yes = ctx.browser_yes, False
        # A model can't pass a grant, a site list or an option: only the arguments below are read.
        inp = {k: v for k, v in inp.items() if k in ("url", "tab")}
        plan = browser_mod.plan(ctx.browser, name, inp, ctx.browser_unasked, ctx.browser_opens, _always(ctx))
        if ctx.unattended and plan.code == "browser_new_origin":
            return _refuse_browser(ctx, name, "unattended_change",
                                   "a repeat run that nobody is watching opens only the sites its job was already approved to read")
        if name == "browser_open":
            ctx.last_host = audit.host_of(browser_mod.origin_of(inp.get("url"))) or ""
        if plan.cls == browser_mod.REFUSED:
            ctx.denied_code = plan.code or "tool_refused"
            audit.event("browser_refuse", ctx.run, tool=name, code=ctx.denied_code, host=ctx.last_host or None,
                        match=plan.match or None)
            return f"[refused] {plan.reason}. Don't try this again."
        if plan.cls == screen_class.ASKED and not yes:
            ctx.denied_code = "tool_refused"
            return "[refused] This needs the user's yes on a card, and it wasn't asked. Don't try it again."
        link, grant = ctx.browser_link, ctx.browser
        if link is None or not link.running:
            return "[error] Browser access is off in Benji's settings; tell the user, and carry on without it."
        with ctx.lock:
            if ctx.stopped:
                raise ToolCancelled
        if plan.code == "browser_always" and name == "browser_open" and grant.add(plan.origin, "always"):
            audit.event("browser_grant", ctx.run, job=ctx.run, host=audit.host_of(plan.origin), how="always")
        try:
            if name == "browser_open":
                out = _browser_open(ctx, link, grant, str(inp["url"]).strip())
            elif name == "browser_tabs":
                out = _browser_tabs(link, grant)
            else:
                out = _browser_read(ctx, link, grant, browser_mod.tab_number(inp["tab"]))
        except LinkError as e:
            return f"[error] {e}"
        if plan.cls == screen_class.QUIET and not out.startswith("[error]"):
            ctx.browser_unasked += 1
        return out
    return handler


def _browser_open(ctx: Ctx, link, grant: browser_mod.Grant, url: str) -> str:
    reply = link.call("open", {"url": url, "allow": grant.origins, "job": ctx.run})
    if reply.get("ok") is not True:
        return f"[error] {browser_mod.clean_error(reply.get('error'))}"
    ctx.browser_opens += 1
    tab = reply.get("tab") if isinstance(reply.get("tab"), dict) else {}
    final = tab.get("url") if isinstance(tab.get("url"), str) else ""
    note = ""
    if not grant.allows(final):
        where = browser_mod.origin_of(final)
        note = (f" It ended at {where}, which isn't on this job's list, so browser_read will refuse it."
                if where else " It didn't end on a page this job can read.")
    return f"[ok] Opened tab {tab.get('id')} at {final[:300]}.{note}"


def _browser_tabs(link, grant: browser_mod.Grant) -> str:
    reply = link.call("tabs", {"allow": grant.origins})
    if reply.get("ok") is not True:
        return f"[error] {browser_mod.clean_error(reply.get('error'))}"
    tabs = [t for t in reply.get("tabs", []) if isinstance(t, dict)][:50]
    if not tabs:
        return "[no tabs] Benji's tab group has no pages open; browser_open one."
    return _truncate("\n".join(browser_mod.tab_line(t, grant) for t in tabs))


def _browser_read(ctx: Ctx, link, grant: browser_mod.Grant, tab: int) -> str:
    reply = link.call("read", {"tab": tab, "allow": grant.origins, "max": browser_mod.MAX_PAGE_CHARS})
    if reply.get("ok") is not True:
        return f"[error] {browser_mod.clean_error(reply.get('error'))}"
    url = reply.get("url") if isinstance(reply.get("url"), str) else ""
    text = reply.get("text") if isinstance(reply.get("text"), str) else ""
    ctx.last_host = audit.host_of(browser_mod.origin_of(url)) or ""
    if not grant.allows(url):       # the extension checked; this is the second lock, and drops the text
        ctx.denied_code = "browser_not_listed"
        audit.event("browser_refuse", ctx.run, tool="browser_read", code="browser_not_listed",
                    host=ctx.last_host or None, match="not_listed" if ctx.last_host else "invalid")
        return ("[refused] That tab is on a site that isn't on this job's list, so what it holds was "
                "not read. To use it, browser_open it (the user is asked).")
    title = " ".join(str(reply.get("title") or "").split())[:200]
    more = " [the page was longer; this is the start of it]" if reply.get("truncated") else ""
    return _truncate(f"[read tab {tab} · {url[:300]}]{more}\ntitle: {title}\n\n{text}")


# --- browser reach: looking, acting, the front tab ----------------------------------

_ACT_ACTION = {"browser_click": "click", "browser_type": "type", "browser_key": "key", "browser_upload": "upload"}


def _refuse_browser(ctx: Ctx, name: str, code: str, why: str, origin: str = "") -> str:
    ctx.denied_code = code
    ctx.last_host = audit.host_of(origin) or ctx.last_host
    audit.event("browser_refuse", ctx.run, tool=name, code=code, host=ctx.last_host or None,
                match="granted" if origin else None)
    return f"[refused] {why}. Don't try this again."


def _ask_here(ctx: Ctx, tool: str, code: str, reason: str) -> bool:
    """A card for a step whose class is only known after the page's element was looked at. It goes
    through the agent's own approve (never --yes), and shows in the audit log as an ask."""
    ask = ctx.browser_approve
    ctx.browser_recent = False
    if ask is None:
        return False
    if ctx.on_gate:
        ctx.on_gate(tool, code)
    ctx.escalated, ctx.escalated_code = True, code
    answer = ask(tool, reason)
    with ctx.lock:
        if ctx.stopped:
            raise ToolCancelled
    return bool(answer)


def _taint_note(ctx: Ctx) -> str:
    return f"Benji read {ctx.taint_source} this turn" if ctx.tainted else ""


def _browser_page_tool(name: str) -> Callable[..., str]:
    """browser_look, browser_scroll, browser_click, browser_type, browser_key and browser_upload."""
    allowed = set(browser_act._ARGS[name])

    def handler(ctx: Ctx, **inp) -> str:
        inp = {k: v for k, v in inp.items() if k in allowed}      # a model can't pass a grant or an option
        clean, why, code = browser_act.check_args(name, inp)
        if clean is None:
            return _refuse_browser(ctx, name, code, why)
        grant, link = ctx.browser, ctx.browser_link
        if grant is None or not grant.origins:
            return _refuse_browser(ctx, name, "browser_no_grant", "this job has no browser access: the user approves sites when a job starts")
        if not _act_allowed(ctx, name):
            return _refuse_browser(ctx, name, "unattended_change" if ctx.unattended else "tool_refused",
                                   "a repeat run that nobody is watching only reads" if ctx.unattended
                                   else "acting in the browser isn't available here")
        if link is None or not link.running:
            return "[error] Browser access is off in Benji's settings; tell the user, and carry on without it."
        with ctx.lock:
            if ctx.stopped:
                raise ToolCancelled
        try:
            if name == "browser_look":
                return _browser_look(ctx, link, grant, clean["tab"])
            if name == "browser_scroll":
                return _browser_scroll(ctx, link, grant, clean)
            return _browser_act(ctx, link, grant, name, clean)
        except LinkError as e:
            return f"[error] {e}"
    return handler


def _browser_look(ctx: Ctx, link, grant: browser_mod.Grant, tab: int) -> str:
    if ctx.browser_unasked >= browser_mod.MAX_UNASKED:
        if not _ask_here(ctx, "browser_look", "browser_step_cap",
                         f"keep looking at pages in your Chrome (this job has done {browser_mod.MAX_UNASKED} steps without asking): tab {tab}"):
            return "[declined] The user did not approve this action. Do not retry it; adapt."
    reply = link.call("look", {"tab": tab, "allow": grant.origins, "max": browser_act.MAX_LOOK})
    if reply.get("ok") is not True:
        return f"[error] {browser_mod.clean_error(reply.get('error'))}"
    url = reply.get("url") if isinstance(reply.get("url"), str) else ""
    ctx.last_host = audit.host_of(browser_mod.origin_of(url)) or ""
    if not grant.allows(url):       # the second lock, as for browser_read
        return _refuse_browser(ctx, "browser_look", "browser_not_listed",
                               "That tab is on a site that isn't on this job's list, so nothing was listed")
    controls = [c for c in reply.get("controls", []) if isinstance(c, dict)] if isinstance(reply.get("controls"), list) else []
    lines, sigs = browser_act.look_lines(controls, browser_mod.origin_of(url) or "")
    ctx.browser_refs[tab] = sigs
    ctx.browser_unasked += 1
    more = " [more controls than this are on the page; scroll and look again]" if reply.get("truncated") else ""
    if not lines:
        return f"[looked at tab {tab} · {url[:300]}] no controls the job can use here."
    return _truncate(f"[looked at tab {tab} · {url[:300]}]{more}\n" + "\n".join(lines))


def _browser_scroll(ctx: Ctx, link, grant: browser_mod.Grant, a: dict) -> str:
    reply = link.call("scroll", {"tab": a["tab"], "to": a["to"], "allow": grant.origins})
    if reply.get("ok") is not True:
        return f"[error] {browser_mod.clean_error(reply.get('error'))}"
    edge = " (now at the top)" if reply.get("atTop") else " (now at the bottom)" if reply.get("atBottom") else ""
    return f"[ok] Scrolled tab {a['tab']} {a['to']}{edge}."


def _browser_act(ctx: Ctx, link, grant: browser_mod.Grant, name: str, a: dict) -> str:
    """One click, typed word, key press or upload. The extension looks at the element first (no
    debugger yet); the class comes from code (browser_act); acting on a site is a card of its own the
    first time; the step is a card when the class is asked; the extension looks again before acting and
    refuses if anything is higher than what was settled here."""
    action, tab = _ACT_ACTION[name], a["tab"]
    sig = None
    if "ref" in a:
        sig = ctx.browser_refs.get(tab, {}).get(a["ref"])
        if sig is None:
            return (f"[error] ref {a['ref']} isn't one of tab {tab}'s controls as last listed: use browser_look again "
                    "(the page may have changed).")
    upload = None
    if action == "upload":
        upload, why = browser_act.vet_upload(a.get("path"), ctx.workdir)
        if upload is None:
            return _refuse_browser(ctx, name, "private_path" if "private" in why else "browser_bad_args", why)
    probe = link.call("target", {"tab": tab, "ref": a.get("ref"), "sig": sig, "action": action, "allow": grant.origins})
    if probe.get("ok") is not True:
        return f"[error] {browser_mod.clean_error(probe.get('error'))}"
    origin = browser_mod.origin_of(probe.get("origin"))
    desc = probe.get("desc") if isinstance(probe.get("desc"), dict) else None
    if origin is None or origin != probe.get("origin") or origin not in grant.origins:      # the second lock
        return _refuse_browser(ctx, name, "browser_not_listed", "That tab is on a site that isn't on this job's list")
    ctx.last_host = audit.host_of(origin) or ""
    # What the step is, from the element and the page (never from the model's words).
    if action == "upload":
        if not desc or desc.get("kind") != "file" or browser_act.sensitive(desc):
            return _refuse_browser(ctx, name, "browser_act_refused", "that control isn't a file input", origin)
        verdict = browser_act.Verdict(browser_act.ASKED, "browser_upload", "upload a file")
    else:
        subject = {"key": a.get("key"), "focus": desc} if action == "key" else desc
        verdict = browser_act.classify(action, subject, origin, text=a.get("text", ""), user_text=ctx.user_text,
                                       unasked=ctx.browser_act_unasked)
        if verdict.cls == browser_act.QUIET and ctx.browser_unasked >= browser_mod.MAX_UNASKED:
            verdict = browser_act.Verdict(browser_act.ASKED, "browser_act_cap", verdict.what,
                                          f"this job has taken {browser_mod.MAX_UNASKED} steps in your Chrome without asking")
    if verdict.cls == browser_act.REFUSED:
        return _refuse_browser(ctx, name, verdict.code, verdict.why, origin)
    # Acting on a site is its own card, once per job and site, and never implied by reading.
    if not grant.may_act(origin):
        if not _ask_here(ctx, name, "browser_act_grant", browser_act.grant_card(grant.title, origin)):
            return "[declined] The user did not allow this job to act on that site. Do not retry it; adapt."
        if not grant.add_act(origin, "act_card"):
            return _refuse_browser(ctx, name, "browser_not_listed", "That site isn't one this job can read, so it can't act on it", origin)
        audit.event("browser_grant", ctx.run, job=ctx.run, host=audit.host_of(origin), how="act_card")
    if verdict.cls == browser_act.ASKED:
        if upload is not None:
            reason = browser_act.upload_card(upload, origin, str((desc or {}).get("name") or ""), _taint_note(ctx))
        else:
            detail = (str(desc.get("href") or "")[:300] if desc and desc.get("kind") == "link" and action == "click"
                      else str(a.get("text") or "")[:300] if action == "type" else a.get("key") or "")
            reason = browser_act.card(verdict, origin, detail, _taint_note(ctx))
        if not _ask_here(ctx, name, verdict.code, reason):
            return "[declined] The user did not approve this action. Do not retry it; adapt."
        if verdict.leaves and not grant.allows(verdict.leaves) and grant.add(verdict.leaves, "card"):
            audit.event("browser_grant", ctx.run, job=ctx.run, host=audit.host_of(verdict.leaves), how="card")
    params = {"tab": tab, "ref": a.get("ref"), "sig": sig, "action": action, "text": a.get("text"), "replace": a.get("replace"),
              "key": a.get("key"), "path": str(upload.path) if upload else None, "allow": grant.origins, "act": grant.acts,
              "cls": verdict.cls, "download": bool(verdict.download and verdict.cls == browser_act.ASKED)}
    reply = link.call("do", {k: v for k, v in params.items() if v is not None}, timeout=60)
    if reply.get("canceled") is True:       # Cancel on Chrome's debugging bar is the user's Stop
        if ctx.on_user_stop:
            ctx.on_user_stop()
        return "[stopped] The user pressed Cancel on Chrome's debugging bar, which stops this job. Do nothing more."
    where = browser_mod.origin_of(reply.get("moved_to")) if isinstance(reply.get("moved_to"), str) else None
    if reply.get("ok") is not True:
        extra = f" (the tab is now at {where})" if where and where != origin else ""
        return f"[error] {browser_mod.clean_error(reply.get('error'))}{extra}"
    if verdict.cls == browser_act.QUIET:
        ctx.browser_unasked += 1
        ctx.browser_act_unasked += 1
    if where and where != origin:
        ctx.browser_refs.pop(tab, None)
    elif action == "click":
        ctx.browser_refs.pop(tab, None)         # a click may change the page: look again before the next step
    done = {"click": "Clicked", "type": "Typed into", "key": "Pressed a key in", "upload": "Gave the file to"}[action]
    out = f"[ok] {done} tab {tab} on {browser_mod.host_label(origin)}."
    if where and where != origin:
        out += (f" The tab moved to {browser_mod.host_label(where)}"
                + ("." if grant.allows(where) else ", which isn't on this job's list, so browser_read will refuse it and acting there "
                   "isn't allowed."))
    if reply.get("note"):
        out += " " + browser_mod.clean_error(reply.get("note"))
    return out + " Use browser_look before the next step if the page changed."


def _read_active_tab(ctx: Ctx) -> str:
    """The page the user is looking at. The extension names the site only; the card shows it;
    then the same text rules as browser_read apply, held to that one tab and that one site."""
    link = ctx.browser_link
    if not ctx.browser_active or link is None or not link.running:
        return "[error] Browser access is off in Benji's settings; tell the user, and carry on without it."
    with ctx.lock:
        if ctx.stopped:
            raise ToolCancelled
    try:
        found = link.call("active", {})
        if found.get("ok") is not True:
            return f"[error] {browser_mod.clean_error(found.get('error'))}"
        origin = browser_mod.origin_of(found.get("origin")) if isinstance(found.get("origin"), str) else None
        if origin is not None and origin != found.get("origin"):
            origin = None
        plan = browser_mod.plan_active(origin, ctx.browser_always)
        tab = browser_mod.tab_number(found.get("tab"))
        if plan.cls == browser_mod.REFUSED or tab is None:
            return _refuse_browser(ctx, browser_mod.ACTIVE_TOOL, plan.code or "browser_bad_url",
                                   plan.reason or "the tab in front isn't one Benji can read")
        ctx.last_host = audit.host_of(origin) or ""
        if plan.cls == screen_class.ASKED:
            reason = plan.reason
            if ctx.tainted:
                reason = _with_note(reason, _taint_note(ctx))
            if not _ask_here(ctx, browser_mod.ACTIVE_TOOL, plan.code, reason):
                return "[declined] The user did not approve this action. Do not retry it; adapt."
        reply = link.call("read_active", {"tab": tab, "origin": origin, "max": browser_mod.MAX_PAGE_CHARS})
    except LinkError as e:
        return f"[error] {e}"
    if reply.get("ok") is not True:
        return f"[error] {browser_mod.clean_error(reply.get('error'))}"
    url = reply.get("url") if isinstance(reply.get("url"), str) else ""
    text = reply.get("text") if isinstance(reply.get("text"), str) else ""
    if browser_mod.origin_of(url) != origin:        # the second lock: the page moved while it was read
        return _refuse_browser(ctx, browser_mod.ACTIVE_TOOL, "browser_not_listed",
                               "The page in front moved to another site, so what it held was not read", origin)
    title = " ".join(str(reply.get("title") or "").split())[:200]
    more = " [the page was longer; this is the start of it]" if reply.get("truncated") else ""
    return _truncate(f"[read the page in front · {url[:300]}]{more}\ntitle: {title}\n\n{text}")
