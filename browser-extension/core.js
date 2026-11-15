// What the extension does when Benji asks, kept apart from Chrome so test/core.test.mjs can run
// it against a fake `api`. The service worker is the only caller (service-worker.js).
//
// The rules, all here:
//   - one tab group, "Benji", is the only place this code opens a tab, lists tabs or reads one;
//   - a tab outside that group is never touched, whatever number it is asked about;
//   - every request carries the origins the job may use (`allow`); a page on any other origin is
//     neither opened nor read, and a page that moves to another origin while it is read returns nothing;
//   - reading runs one function in a page, `extract`, which returns visible text. Acting runs
//     `pageAct`, which lists and describes controls and only scrolls or focuses; a click, typed word
//     or key goes through Chrome's debugger, attached only for that step, on a tab in the group, on a
//     site the engine named for acting, and only if the extension's own class for the element
//     (act-rules.js) is not higher than the one the engine settled on. Nothing is done on a page that
//     is not the one that was looked at, and a page that moves to another site mid-step stops it.
// Origins are matched exactly (scheme, host, port) and only for https, the same rules as
// benji/browser.py; both run test/origin-cases.json.

import { parseUrl, originOf } from "./origin.js";
import { floor, higher, KEYS, RANK } from "./act-rules.js";
export { parseUrl, originOf };

export const GROUP_TITLE = "Benji";
export const GROUP_COLOR = "green";
export const MAX_GROUP_TABS = 12;
export const MAX_ALLOW = 20;
export const MAX_TEXT = 40000;
export const PAGE_WAIT_MS = 15000;
const GROUP_KEY = "benjiGroup";
const OPENED_KEY = "benjiOpened";
export const MAX_CONTROLS = 120;
export const STEP_SETTLE_MS = 8000;

// Virtual keys the debugger is given (no letters, no modifiers: text goes through browser_type).
const KEY_EVENTS = {
  Enter: { code: "Enter", vk: 13, text: "\r" }, Tab: { code: "Tab", vk: 9 }, Escape: { code: "Escape", vk: 27 },
  Backspace: { code: "Backspace", vk: 8 }, Delete: { code: "Delete", vk: 46 },
  PageUp: { code: "PageUp", vk: 33 }, PageDown: { code: "PageDown", vk: 34 }, End: { code: "End", vk: 35 },
  Home: { code: "Home", vk: 36 }, ArrowLeft: { code: "ArrowLeft", vk: 37 }, ArrowUp: { code: "ArrowUp", vk: 38 },
  ArrowRight: { code: "ArrowRight", vk: 39 }, ArrowDown: { code: "ArrowDown", vk: 40 },
};

/** A thing the extension will not do, said in words the job can show; never page text. */
export class Refusal extends Error {}

/** The origins a job may act on: a list (possibly empty) of clean origins, each also in `allow`. */
export function cleanActs(act, allow) {
  if (act === undefined || act === null) return [];
  if (!Array.isArray(act) || act.length > MAX_ALLOW) throw new Refusal("the list of sites to act on isn't usable");
  for (const item of act) {
    if (originOf(item) !== item || !allow.includes(item)) throw new Refusal("a site to act on isn't one this job can read");
  }
  return act;
}

/** `allow` as a clean list of origins, or a Refusal: the engine's list is checked, not trusted blindly. */
export function cleanAllow(allow) {
  if (!Array.isArray(allow) || allow.length === 0 || allow.length > MAX_ALLOW) {
    throw new Refusal("no sites were named for this request");
  }
  const origins = [];
  for (const item of allow) {
    const origin = originOf(item);
    if (origin === null || origin !== item) throw new Refusal("a site in the list isn't one Benji can use");
    origins.push(origin);
  }
  return origins;
}

function wholeNumber(value) {
  return Number.isInteger(value) && value >= 0 ? value : null;
}

export class Browser {
  /**
   * @param api   the parts of `chrome` used here: tabs, tabGroups, scripting, windows, storage.session
   * @param extract  the function run in a page; returns { text, truncated }
   * @param sleep    waits ms (replaced in tests)
   */
  constructor(api, extract, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), pageAct = null) {
    this.api = api;
    this.extract = extract;
    this.sleep = sleep;
    this.pageAct = pageAct;       // the function run in a page for acting; null: this build only reads
  }

  /** One request from Benji: { id, op, ... } in, { id, ok, ... } out. Never throws. */
  async handle(msg) {
    const id = msg && typeof msg.id === "string" ? msg.id : "";
    try {
      switch (msg.op) {
        case "open": return { id, ok: true, ...(await this.open(msg)) };
        case "tabs": return { id, ok: true, ...(await this.tabs(msg)) };
        case "read": return { id, ok: true, ...(await this.read(msg)) };
        case "look": return { id, ok: true, ...(await this.look(msg)) };
        case "scroll": return { id, ok: true, ...(await this.scroll(msg)) };
        case "target": return { id, ok: true, ...(await this.target(msg)) };
        case "do": return { id, ...(await this.act(msg)) };
        case "active": return { id, ok: true, ...(await this.active()) };
        case "read_active": return { id, ok: true, ...(await this.readActive(msg)) };
        case "close": return { id, ok: true, ...(await this.close()) };
        default: throw new Refusal("this extension doesn't do that");
      }
    } catch (e) {
      return { id, ok: false, error: e instanceof Refusal ? e.message : this.explain(e) };
    }
  }

  explain(e) {
    const text = String((e && e.message) || e || "");
    if (/cannot access|host permission|permissions? (?:is|are) required|extension manifest must request/i.test(text)) {
      return "The extension has no access to this site yet: open the Benji extension in Chrome and choose Allow.";
    }
    if (/no tab with id/i.test(text)) return "There is no tab with that number any more.";
    if (/another debugger|already attached/i.test(text)) {
      return "Chrome's debugger is already in use on that tab (are developer tools open?). Close them and try again.";
    }
    return "Chrome refused that step.";
  }

  async groupId() {
    const stored = await this.api.storage.session.get(GROUP_KEY);
    const id = stored ? stored[GROUP_KEY] : undefined;
    if (!Number.isInteger(id)) return null;
    let members;
    try {
      members = await this.api.tabs.query({ groupId: id });
    } catch {
      members = [];
    }
    if (members.length === 0) {          // the user closed the group: forget it
      await this.api.storage.session.remove(GROUP_KEY);
      return null;
    }
    return id;
  }

  async open(msg) {
    const allow = cleanAllow(msg.allow);
    const parsed = parseUrl(msg.url);
    if (parsed.error) throw new Refusal(parsed.error);
    if (!allow.includes(parsed.origin)) throw new Refusal(`${parsed.origin} isn't on this job's list`);
    let gid = await this.groupId();
    let windowId;
    if (gid !== null) {
      const members = await this.api.tabs.query({ groupId: gid });
      if (members.length >= MAX_GROUP_TABS) throw new Refusal(`Benji's tab group is full (${MAX_GROUP_TABS}); close some of its tabs`);
      windowId = members[0].windowId;
    } else {
      const win = await this.api.windows.getLastFocused({ windowTypes: ["normal"] });
      if (win && win.incognito) throw new Refusal("Benji doesn't use private windows");
      windowId = win ? win.id : undefined;
    }
    const created = await this.api.tabs.create({ url: msg.url.trim(), active: false, ...(windowId !== undefined ? { windowId } : {}) });
    await this.remember(created.id);
    gid = await this.api.tabs.group(gid === null ? { tabIds: [created.id] } : { tabIds: [created.id], groupId: gid });
    await this.api.tabGroups.update(gid, { title: GROUP_TITLE, color: GROUP_COLOR, collapsed: false });
    await this.api.storage.session.set({ [GROUP_KEY]: gid });
    const tab = await this.settle(created.id);
    if (!tab.url) throw new Refusal("The extension has no access to sites yet: open the Benji extension in Chrome and choose Allow.");
    return { tab: { id: tab.id, url: tab.url } };
  }

  async tabs(msg) {
    const allow = cleanAllow(msg.allow);
    const gid = await this.groupId();
    if (gid === null) return { tabs: [] };
    const members = await this.api.tabs.query({ groupId: gid });
    return {
      tabs: members.slice(0, 50).map((t) => {
        const origin = originOf(t.url || "");
        // A tab on a site outside the list is named by its origin alone: no path, no title.
        return origin !== null && allow.includes(origin)
          ? { id: t.id, url: t.url, title: t.title || "", active: Boolean(t.active) }
          : { id: t.id, url: origin ?? "", title: "", active: Boolean(t.active) };
      }),
    };
  }

  /** The tab, if it is in Benji's group and on an allowed origin; else a Refusal. */
  async guarded(tabId, allow, gid) {
    let tab;
    try {
      tab = await this.api.tabs.get(tabId);
    } catch {
      throw new Refusal("There is no tab with that number any more.");
    }
    if (tab.groupId !== gid) throw new Refusal("That tab isn't in Benji's tab group, so Benji won't read it.");
    if (tab.incognito) throw new Refusal("Benji doesn't use private windows");
    const origin = originOf(tab.url || "");
    if (origin === null) throw new Refusal("That tab isn't a page Benji can read.");
    if (!allow.includes(origin)) throw new Refusal(`That tab is at ${origin}, which isn't on this job's list.`);
    return { tab, origin };
  }

  async read(msg) {
    const allow = cleanAllow(msg.allow);
    const tabId = wholeNumber(msg.tab);
    if (tabId === null) throw new Refusal("tab must be a tab number");
    const max = Math.min(wholeNumber(msg.max) ?? MAX_TEXT, MAX_TEXT);
    const gid = await this.groupId();
    if (gid === null) throw new Refusal("Benji has no tab group yet: open a page first.");
    let { tab, origin } = await this.guarded(tabId, allow, gid);
    if (tab.status !== "complete") {
      await this.settle(tabId);
      ({ tab, origin } = await this.guarded(tabId, allow, gid));
    }
    // The main frame only: no all-frames option, no frame ids.
    const results = await this.api.scripting.executeScript({ target: { tabId }, func: this.extract, args: [max] });
    const result = results && results[0] && results[0].frameId === 0 ? results[0].result : null;
    if (!result || typeof result.text !== "string") throw new Refusal("The page gave no text.");
    // Read again: if the page moved to another site while it was read, nothing is returned.
    const after = await this.guarded(tabId, allow, gid).catch(() => null);
    if (after === null || after.origin !== origin) {
      throw new Refusal("The page moved to another site while it was read, so nothing was returned.");
    }
    return { url: after.tab.url, title: after.tab.title || "", text: result.text.slice(0, max), truncated: Boolean(result.truncated) || result.text.length > max };
  }

  /** The tabs this extension opened (for closing them when a job ends), kept for this browser session only. */
  async remember(tabId) {
    const stored = await this.api.storage.session.get(OPENED_KEY);
    const list = stored && Array.isArray(stored[OPENED_KEY]) ? stored[OPENED_KEY] : [];
    await this.api.storage.session.set({ [OPENED_KEY]: [...list, tabId].slice(-60) });
  }

  /** Close the tabs this extension opened that are still in the Benji group. A tab the user dragged
   *  in, or opened themselves, is not on the list and is left alone. */
  async close() {
    const stored = await this.api.storage.session.get(OPENED_KEY);
    const ids = stored && Array.isArray(stored[OPENED_KEY]) ? stored[OPENED_KEY] : [];
    const gid = await this.groupId();
    let closed = 0;
    if (gid !== null && ids.length > 0) {
      const mine = (await this.api.tabs.query({ groupId: gid })).filter((t) => ids.includes(t.id)).map((t) => t.id);
      if (mine.length > 0) {
        await this.api.tabs.remove(mine);
        closed = mine.length;
      }
    }
    await this.api.storage.session.remove(OPENED_KEY);
    return { closed };
  }

  // ---- looking and acting ---------------------------------------------------------------------

  /** Run pageAct in the tab's main frame. */
  async page(tabId, op, args) {
    if (typeof this.pageAct !== "function") throw new Refusal("This version of the extension can't look at controls.");
    const results = await this.api.scripting.executeScript({ target: { tabId }, func: this.pageAct, args: [op, args ?? {}] });
    const r = results && results[0] && results[0].frameId === 0 ? results[0].result : null;
    if (!r || typeof r !== "object") throw new Refusal("The page gave no answer.");
    if (typeof r.error === "string") throw new Refusal(r.error.slice(0, 200));
    return r;
  }

  /** The tab named by `msg.tab`, in the group, on an allowed origin, loaded. */
  async tabFor(msg) {
    const allow = cleanAllow(msg.allow);
    const tabId = wholeNumber(msg.tab);
    if (tabId === null) throw new Refusal("tab must be a tab number");
    const gid = await this.groupId();
    if (gid === null) throw new Refusal("Benji has no tab group yet: open a page first.");
    let got = await this.guarded(tabId, allow, gid);
    if (got.tab.status !== "complete") {
      await this.settle(tabId);
      got = await this.guarded(tabId, allow, gid);
    }
    return { allow, tabId, gid, ...got };
  }

  /** The tab is still in the group on the same origin it was; else a Refusal. */
  async stillThere(ctx) {
    const after = await this.guarded(ctx.tabId, ctx.allow, ctx.gid).catch(() => null);
    if (after === null || after.origin !== ctx.origin) {
      throw new Refusal("The page moved to another site while it was looked at, so nothing was returned.");
    }
    return after;
  }

  async look(msg) {
    const ctx = await this.tabFor(msg);
    const max = Math.min(wholeNumber(msg.max) ?? MAX_CONTROLS, MAX_CONTROLS);
    const r = await this.page(ctx.tabId, "list", { max });
    const after = await this.stillThere(ctx);
    const text = (v, n) => (typeof v === "string" ? v.slice(0, n) : "");
    const controls = (Array.isArray(r.controls) ? r.controls : []).slice(0, max).filter((c) => c && Number.isInteger(c.ref)).map((c) => ({
      ref: c.ref, sig: text(c.sig, 32), kind: text(c.kind, 12), name: text(c.name, 100), text: text(c.text, 100),
      href: text(c.href, 300), checked: c.checked === true, expanded: c.expanded === true,
      disabled: c.disabled === true, sensitive: c.sensitive === true,
    }));
    return { url: after.tab.url, controls, truncated: r.truncated === true };
  }

  async scroll(msg) {
    if (!["down", "up", "top", "bottom"].includes(msg.to)) throw new Refusal("to must be down, up, top or bottom");
    const ctx = await this.tabFor(msg);
    const r = await this.page(ctx.tabId, "scroll", { to: msg.to });
    const after = await this.stillThere(ctx);
    return { url: after.tab.url, atTop: r.atTop === true, atBottom: r.atBottom === true };
  }

  /** What is at the other end of a step, before anything is done and before the debugger is touched. */
  async target(msg) {
    if (!["click", "type", "key", "upload"].includes(msg.action)) throw new Refusal("not a step this extension does");
    const ctx = await this.tabFor(msg);
    let desc;
    if (msg.action === "key") {
      desc = (await this.page(ctx.tabId, "active", {})).desc ?? null;
    } else {
      const ref = wholeNumber(msg.ref);
      if (ref === null) throw new Refusal("ref must be a control number");
      const r = await this.page(ctx.tabId, "describe", { ref, sig: typeof msg.sig === "string" ? msg.sig : undefined });
      desc = r.desc;
      if (msg.action === "upload" && desc.kind !== "file") throw new Refusal("That control isn't a file input.");
    }
    const after = await this.stillThere(ctx);
    return { origin: ctx.origin, url: after.tab.url, desc };
  }

  /** One click, typed word, key press or upload. Looks at the element again and holds itself to the
   *  class the engine settled on; attaches the debugger for this step only, and always lets go. */
  async act(msg) {
    try {
      return { ok: true, ...(await this.actInner(msg)) };
    } catch (e) {
      if (e && e.canceled) return { ok: false, canceled: true, error: "The user pressed Cancel on Chrome's debugging bar." };
      const out = { ok: false, error: e instanceof Refusal ? e.message : this.explain(e) };
      if (e && e.moved) Object.assign(out, { moved: true, moved_to: e.movedTo ?? "" });
      return out;
    }
  }

  async actInner(msg) {
    const action = msg.action;
    if (!["click", "type", "key", "upload"].includes(action)) throw new Refusal("not a step this extension does");
    if (!(msg.cls in RANK) || msg.cls === "refused") throw new Refusal("the step has no usable class");
    const allow = cleanAllow(msg.allow);
    const acts = cleanActs(msg.act, allow);
    const ctx = await this.tabFor({ tab: msg.tab, allow });
    if (!acts.includes(ctx.origin)) throw new Refusal("This job isn't allowed to act on that site.");
    // Look again, right now: the element has to still be the one that was asked about.
    let subject;
    let point = null;
    let fileIndex = -1;
    if (action === "key") {
      if (!KEYS.includes(msg.key)) throw new Refusal("that key can't be pressed");
      subject = { key: msg.key, focus: (await this.page(ctx.tabId, "active", {})).desc ?? null };
    } else {
      const ref = wholeNumber(msg.ref);
      if (ref === null || typeof msg.sig !== "string") throw new Refusal("the step names no control");
      const r = await this.page(ctx.tabId, "describe", { ref, sig: msg.sig, aim: action === "click" });
      subject = r.desc;
      point = r.point ?? null;
      fileIndex = Number.isInteger(r.fileIndex) ? r.fileIndex : -1;
    }
    let mine;
    if (action === "upload") {
      if (subject.kind !== "file" || subject.sensitive === true || msg.cls !== "asked" || fileIndex < 0
        || typeof msg.path !== "string" || !msg.path.startsWith("/") || msg.path.length > 1000) {
        throw new Refusal("That isn't an upload Benji may do.");
      }
      mine = { cls: "asked" };
    } else {
      mine = floor(action, subject, ctx.origin);
      if (mine.cls === "refused") throw new Refusal("Benji won't do that on this page.");
    }
    if (higher(mine.cls, msg.cls)) throw new Refusal("The page is different from when this step was approved, so it was not done.");
    if (action === "click" && point === null) throw new Refusal("That control can't be clicked right now.");
    if (action === "type" && (typeof msg.text !== "string" || msg.text.length < 1 || msg.text.length > 2000)) throw new Refusal("text must be 1 to 2000 characters");
    if (typeof this.api.debugger?.attach !== "function") throw new Refusal("This browser can't run the debugger, so Benji can't act in it.");
    return await this.withDebugger(ctx, mine, async (cdp, guard) => {
      if (action === "click") {
        await guard();
        await cdp("Input.dispatchMouseEvent", { type: "mouseMoved", x: point.x, y: point.y });
        await guard();
        await cdp("Input.dispatchMouseEvent", { type: "mousePressed", x: point.x, y: point.y, button: "left", clickCount: 1 });
        await guard();
        await cdp("Input.dispatchMouseEvent", { type: "mouseReleased", x: point.x, y: point.y, button: "left", clickCount: 1 });
      } else if (action === "type") {
        await this.page(ctx.tabId, "focus", { ref: msg.ref, sig: msg.sig, replace: msg.replace === true });
        await guard();
        await cdp("Input.insertText", { text: msg.text });
      } else if (action === "key") {
        const k = KEY_EVENTS[msg.key];
        await guard();
        await cdp("Input.dispatchKeyEvent", { type: k.text ? "keyDown" : "rawKeyDown", key: msg.key, code: k.code,
          windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk, ...(k.text ? { text: k.text } : {}) });
        await cdp("Input.dispatchKeyEvent", { type: "keyUp", key: msg.key, code: k.code, windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk });
      } else {
        const doc = await cdp("DOM.getDocument", { depth: 0 });
        const found = await cdp("DOM.querySelectorAll", { nodeId: doc.root.nodeId, selector: "input[type=file]:not(:disabled)" });
        const nodeId = found.nodeIds[fileIndex];
        if (!Number.isInteger(nodeId) || nodeId === 0) throw new Refusal("That file input isn't on the page any more.");
        await guard();
        await cdp("DOM.setFileInputFiles", { files: [msg.path], nodeId });
      }
    }, msg.download === true);
  }

  /** Attach to the tab, run `step(cdp, guard)`, let the page settle, detach. `guard` throws if the
   *  tab is no longer on the origin the step started on. */
  async withDebugger(ctx, mine, step, downloadOk) {
    const target = { tabId: ctx.tabId };
    const dbg = this.api.debugger;
    const state = { canceled: false };
    const onDetach = (source, reason) => {
      if (source && source.tabId === ctx.tabId) state.canceled = reason === "canceled_by_user" || state.canceled;
    };
    dbg.onDetach?.addListener?.(onDetach);
    try {
      await dbg.attach(target, "1.3");
    } catch (e) {
      dbg.onDetach?.removeListener?.(onDetach);
      throw e;
    }
    const moved = (url) => {
      const e = new Refusal("The page moved to another site in the middle of the step, so the rest of it was not done.");
      e.moved = true;
      e.movedTo = originOf(url || "") ?? "";
      return e;
    };
    const cdp = async (method, params) => {
      try {
        return await dbg.sendCommand(target, method, params ?? {});
      } catch (e) {
        if (state.canceled) throw Object.assign(new Error("canceled"), { canceled: true });
        throw e;
      }
    };
    const guard = async () => {
      if (state.canceled) throw Object.assign(new Error("canceled"), { canceled: true });
      const now = await this.api.tabs.get(ctx.tabId);
      if (originOf(now.url || "") !== ctx.origin) throw moved(now.url);
    };
    try {
      const soft = (e) => { if (e && e.canceled) throw e; };       // a method this Chrome lacks is not a failure
      // The job's tabs open in the background, where Chrome may throttle a page or drop input meant
      // for it: for this step only, tell the page it has focus and is active (undone when we detach).
      await cdp("Emulation.setFocusEmulationEnabled", { enabled: true }).catch(soft);
      await cdp("Page.setWebLifecycleState", { state: "active" }).catch(soft);
      if (!downloadOk) await cdp("Page.setDownloadBehavior", { behavior: "deny" }).catch(soft);
      await step(cdp, guard);
      // A click may start a navigation a moment later: give it up to ~0.8 s to show (a status of
      // loading, or a new address) before waiting for the page to finish, so a redirect isn't missed.
      let seen = await this.api.tabs.get(ctx.tabId);
      for (let waited = 0; waited < 800 && seen.status === "complete" && seen.url === ctx.tab.url; waited += 100) {
        await this.sleep(100);
        seen = await this.api.tabs.get(ctx.tabId);
      }
      const end = await this.settle(ctx.tabId, STEP_SETTLE_MS);
      if (state.canceled) throw Object.assign(new Error("canceled"), { canceled: true });
      const endOrigin = originOf(end.url || "");
      const out = { url: String(end.url || "").slice(0, 300) };
      if (endOrigin !== ctx.origin) Object.assign(out, { moved: true, moved_to: endOrigin ?? "" });
      return out;
    } finally {
      dbg.onDetach?.removeListener?.(onDetach);
      try { await dbg.detach(target); } catch { /* already detached (Cancel, or the tab closed) */ }
    }
  }

  // ---- the page the user is looking at ---------------------------------------------------------

  /** Which site the tab in front is on: its number and origin only, never its address or title. */
  async active() {
    const [tab] = await this.api.tabs.query({ active: true, lastFocusedWindow: true, windowType: "normal" });
    if (!tab) throw new Refusal("No page is in front.");
    if (tab.incognito) throw new Refusal("Benji doesn't use private windows");
    return { tab: tab.id, origin: originOf(tab.url || "") };
  }

  async readActive(msg) {
    const origin = originOf(msg.origin);
    if (origin === null || origin !== msg.origin) throw new Refusal("not a site Benji can use");
    const tabId = wholeNumber(msg.tab);
    if (tabId === null) throw new Refusal("tab must be a tab number");
    const max = Math.min(wholeNumber(msg.max) ?? MAX_TEXT, MAX_TEXT);
    const check = async () => {
      const tab = await this.api.tabs.get(tabId).catch(() => null);
      const [front] = await this.api.tabs.query({ active: true, lastFocusedWindow: true, windowType: "normal" });
      if (!tab || !front || front.id !== tabId) throw new Refusal("The page in front is not the one you were asked about, so nothing was read.");
      if (tab.incognito) throw new Refusal("Benji doesn't use private windows");
      if (originOf(tab.url || "") !== origin) throw new Refusal("The page moved to another site, so nothing was read.");
      return tab;
    };
    let tab = await check();
    if (tab.status !== "complete") {
      await this.settle(tabId);
      tab = await check();
    }
    const results = await this.api.scripting.executeScript({ target: { tabId }, func: this.extract, args: [max] });
    const result = results && results[0] && results[0].frameId === 0 ? results[0].result : null;
    if (!result || typeof result.text !== "string") throw new Refusal("The page gave no text.");
    const after = await check();
    return { url: after.url, title: after.title || "", text: result.text.slice(0, max), truncated: Boolean(result.truncated) || result.text.length > max };
  }

  /** Wait (up to PAGE_WAIT_MS) for a tab to finish loading, then return it. */
  async settle(tabId, limit = PAGE_WAIT_MS) {
    let tab = await this.api.tabs.get(tabId);
    for (let waited = 0; tab.status !== "complete" && waited < limit; waited += 250) {
      await this.sleep(250);
      tab = await this.api.tabs.get(tabId);
    }
    return tab;
  }
}
