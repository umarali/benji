// Run with: node --test browser-extension/test/act.test.mjs   (no packages; Node 20 or newer)
// Acting and the front-tab read (D-171) against a fake `chrome`: the debugger is a recorder, the page is
// a script. The real page function is tried in a real headless Chrome in page-actions.test.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Browser } from "../core.js";
import { floor, KEYS } from "../act-rules.js";

const cases = JSON.parse(readFileSync(new URL("./act-cases.json", import.meta.url), "utf8"));
const A = "https://example.com";
const O = "https://other.org";

test("act cases: floor gives the same answers as benji/browser_act.py for every shared case", () => {
  assert.ok(cases.floor.length >= 60);
  for (const c of cases.floor) {
    const v = floor(c.action, c.desc, c.tab);
    assert.deepEqual([v.cls, v.code, v.leaves, v.download], [c.cls, c.code, c.leaves, c.download], c.name);
  }
});

test("floor: every key the extension can press is one of the thirteen, and nothing else is", () => {
  assert.equal(KEYS.length, 13);
  for (const k of ["a", "Space", "Control+a", "F5", "Meta"]) assert.equal(floor("key", { key: k, focus: null }, A).cls, "refused", k);
});

const LINK = { kind: "link", tag: "a", name: "Pricing", text: "Pricing", href: `${A}/pricing`, sig: "s1" };
const SEND = { kind: "submit", tag: "button", name: "Send", text: "Send", form: "post", sig: "s2" };
const FIELD = { kind: "text", tag: "input", inputType: "text", name: "Search", fieldName: "q", sig: "s3" };
const FILE = { kind: "file", tag: "input", inputType: "file", name: "Attach", sig: "s4" };

// A fake of the parts of `chrome` the acting code uses; `page` scripts what pageAct answers.
function fake({ page = {}, tabUrl = `${A}/start`, failAttach = null } = {}) {
  const st = {
    tabs: [{ id: 5, url: tabUrl, title: "T", status: "complete", groupId: 7, windowId: 1, incognito: false, active: false },
      { id: 6, url: `${A}/mine`, title: "Mine", status: "complete", groupId: -1, windowId: 1, incognito: false, active: true }],
    session: { benjiGroup: 7 }, calls: [], attached: 0, detached: 0, listeners: [], pageCalls: [], removed: [], afterCommand: null,
  };
  const dbg = {
    attach: async (target, version) => { if (failAttach) throw new Error(failAttach); st.attached++; st.calls.push(["attach", target.tabId, version]); },
    detach: async () => { st.detached++; },
    sendCommand: async (target, method, params) => {
      st.calls.push([method, params]);
      if (st.afterCommand) await st.afterCommand(method, params);
      if (method === "DOM.getDocument") return { root: { nodeId: 1 } };
      if (method === "DOM.querySelectorAll") return { nodeIds: [11, 12] };
      return {};
    },
    onDetach: { addListener: (f) => st.listeners.push(f), removeListener: (f) => { st.listeners = st.listeners.filter((x) => x !== f); } },
  };
  const api = {
    windows: { getLastFocused: async () => ({ id: 1 }) },
    storage: { session: {
      get: async (k) => ({ [k]: st.session[k] }),
      set: async (o) => { Object.assign(st.session, o); },
      remove: async (k) => { delete st.session[k]; },
    } },
    tabs: {
      get: async (id) => { const t = st.tabs.find((x) => x.id === id); if (!t) throw new Error(`No tab with id: ${id}.`); return { ...t }; },
      query: async (q) => {
        if (q.groupId !== undefined) return st.tabs.filter((t) => t.groupId === q.groupId).map((t) => ({ ...t }));
        if (q.active) return st.tabs.filter((t) => t.active).map((t) => ({ ...t }));
        return [];
      },
      remove: async (ids) => { st.removed.push(...ids); st.tabs = st.tabs.filter((t) => !ids.includes(t.id)); },
    },
    tabGroups: {},
    scripting: { executeScript: async (inj) => {
      if (inj.func.name === "visibleText") return [{ frameId: 0, result: { text: "Front page text", truncated: false } }];
      const [op, args] = inj.args;
      st.pageCalls.push([op, args]);
      const r = typeof page[op] === "function" ? page[op](args, st) : page[op];
      return [{ frameId: 0, result: r ?? { error: "unscripted" } }];
    } },
    debugger: dbg,
  };
  const pageAct = function pageAct() {};
  const b = new Browser(api, function visibleText() {}, async () => {}, pageAct);
  return { b, st };
}
const doMsg = (over) => ({ id: "1", op: "do", tab: 5, ref: 0, sig: "s1", action: "click", allow: [A, O], act: [A], cls: "quiet", ...over });

test("look: lists a page's controls, keeping only the fields it expects, in the group and on an allowed site", async () => {
  const { b } = fake({ page: { list: { controls: [{ ref: 0, sig: "s1", kind: "link", name: "Pricing", href: `${A}/pricing`, secret: "x" }, { nope: 1 }], truncated: false, url: A } } });
  const r = await b.handle({ id: "1", op: "look", tab: 5, allow: [A] });
  assert.equal(r.ok, true);
  assert.equal(r.controls.length, 1);
  assert.deepEqual(Object.keys(r.controls[0]).sort(), ["checked", "disabled", "expanded", "href", "kind", "name", "ref", "sensitive", "sig", "text"]);
  const own = await b.handle({ id: "2", op: "look", tab: 6, allow: [A] });
  assert.equal(own.ok, false);
  assert.match(own.error, /isn't in Benji's tab group/);
  const off = await b.handle({ id: "3", op: "look", tab: 5, allow: [O] });
  assert.equal(off.ok, false);
});

test("target: the element is described without the debugger; a changed page is refused", async () => {
  const { b, st } = fake({ page: { describe: (a) => (a.sig === "s1" ? { desc: LINK } : { error: "The page changed since it was listed: look at the page again." }) } });
  const ok = await b.handle({ id: "1", op: "target", tab: 5, ref: 0, sig: "s1", action: "click", allow: [A] });
  assert.equal(ok.ok, true);
  assert.equal(ok.origin, A);
  assert.equal(ok.desc.kind, "link");
  const stale = await b.handle({ id: "2", op: "target", tab: 5, ref: 0, sig: "zzz", action: "click", allow: [A] });
  assert.equal(stale.ok, false);
  assert.match(stale.error, /page changed/);
  assert.equal(st.attached, 0, "no debugger for a look");
});

test("do: a click is a move, a press and a release at the control, with the debugger attached for the step only", async () => {
  const { b, st } = fake({ page: { describe: { desc: LINK, point: { x: 40, y: 50 } } } });
  const r = await b.handle(doMsg({}));
  assert.equal(r.ok, true);
  assert.equal(r.moved, undefined);
  const events = st.calls.filter((c) => c[0] === "Input.dispatchMouseEvent").map((c) => c[1].type);
  assert.deepEqual(events, ["mouseMoved", "mousePressed", "mouseReleased"]);
  assert.equal(st.attached, 1);
  assert.equal(st.detached, 1);
  assert.equal(st.listeners.length, 0, "the detach listener is removed");
  assert.equal(st.calls.find((c) => c[0] === "Page.setDownloadBehavior")[1].behavior, "deny", "downloads are blocked unless approved");
});

test("do: acting without an acting grant does nothing and never attaches", async () => {
  for (const act of [undefined, [], [O]]) {
    const { b, st } = fake({ page: { describe: { desc: LINK, point: { x: 1, y: 1 } } } });
    const r = await b.handle(doMsg({ act }));
    assert.equal(r.ok, false, JSON.stringify(act));
    assert.match(r.error, /isn't allowed to act/);
    assert.equal(st.attached, 0);
  }
  const { b } = fake();
  assert.equal((await b.handle(doMsg({ act: ["https://evil.test"] }))).ok, false, "an acting site that isn't also readable");
});

test("do: the page now is more than what was approved, so it is not done (the extension may only raise)", async () => {
  const { b, st } = fake({ page: { describe: { desc: SEND, point: { x: 1, y: 1 } } } });
  const r = await b.handle(doMsg({ sig: "s2", cls: "quiet" }));
  assert.equal(r.ok, false);
  assert.match(r.error, /different from when this step was approved/);
  assert.equal(st.attached, 0);
  const yes = await b.handle(doMsg({ sig: "s2", cls: "asked" }));
  assert.equal(yes.ok, true, "with the user's yes, the same click goes ahead");
});

test("do: a password field is refused whatever class is claimed", async () => {
  const pw = { kind: "text", tag: "input", inputType: "password", name: "Password", sig: "p" };
  for (const action of ["click", "type"]) {
    const { b, st } = fake({ page: { describe: { desc: pw, point: { x: 1, y: 1 } } } });
    const r = await b.handle(doMsg({ action, sig: "p", cls: "asked", text: "hunter2" }));
    assert.equal(r.ok, false, action);
    assert.equal(st.attached, 0);
  }
});

test("do: a page that moves to another site in the middle of a click stops the rest of it", async () => {
  const { b, st } = fake({ page: { describe: { desc: LINK, point: { x: 40, y: 50 } } } });
  st.afterCommand = async (method) => {
    if (method === "Input.dispatchMouseEvent" && st.calls.filter((c) => c[0] === method).length === 1) {
      st.tabs.find((t) => t.id === 5).url = `${O}/landed`;      // the page redirected itself after the first event
    }
  };
  const r = await b.handle(doMsg({}));
  assert.equal(r.ok, false);
  assert.equal(r.moved, true);
  assert.equal(r.moved_to, O);
  assert.match(r.error, /moved to another site in the middle/);
  assert.equal(st.calls.filter((c) => c[0] === "Input.dispatchMouseEvent").length, 1, "no press or release reached the new site");
  assert.equal(st.detached, 1);
});

test("do: a click that lands on another site is reported, and the site is named", async () => {
  const { b, st } = fake({ page: { describe: { desc: { ...LINK, href: `${O}/x`, sig: "s1" }, point: { x: 1, y: 1 } } } });
  st.afterCommand = async (method, params) => {
    if (method === "Input.dispatchMouseEvent" && params.type === "mouseReleased") st.tabs.find((t) => t.id === 5).url = `${O}/x`;
  };
  const r = await b.handle(doMsg({ cls: "asked", allow: [A, O] }));
  assert.equal(r.ok, true);
  assert.equal(r.moved, true);
  assert.equal(r.moved_to, O);
});

test("do: Cancel on the debugger bar ends the step and says so", async () => {
  const { b, st } = fake({ page: { describe: { desc: LINK, point: { x: 1, y: 1 } } } });
  st.afterCommand = async (method) => {
    if (method === "Input.dispatchMouseEvent") for (const f of st.listeners) f({ tabId: 5 }, "canceled_by_user");
  };
  const r = await b.handle(doMsg({}));
  assert.equal(r.ok, false);
  assert.equal(r.canceled, true);
  assert.equal(st.detached, 1);
  assert.equal(st.calls.filter((c) => c[0] === "Input.dispatchMouseEvent").length, 1, "nothing more is sent after Cancel");
});

test("do: a tab outside the group, or one with another debugger on it, is never driven", async () => {
  const { b, st } = fake({ page: { describe: { desc: LINK, point: { x: 1, y: 1 } } } });
  assert.equal((await b.handle(doMsg({ tab: 6 }))).ok, false);
  assert.equal(st.attached, 0);
  const busy = fake({ page: { describe: { desc: LINK, point: { x: 1, y: 1 } } }, failAttach: "Another debugger is already attached to the tab with id: 5." });
  const r = await busy.b.handle(doMsg({}));
  assert.equal(r.ok, false);
  assert.match(r.error, /developer tools/);
  assert.equal(busy.st.listeners.length, 0);
});

test("do: type focuses the field, then inserts the text; length and kind are checked", async () => {
  const { b, st } = fake({ page: { describe: { desc: FIELD }, focus: { ok: true } } });
  const r = await b.handle(doMsg({ action: "type", sig: "s3", text: "blue shoes", replace: true, cls: "quiet" }));
  assert.equal(r.ok, true);
  assert.deepEqual(st.pageCalls.find((c) => c[0] === "focus")[1], { ref: 0, sig: "s3", replace: true });
  assert.deepEqual(st.calls.find((c) => c[0] === "Input.insertText")[1], { text: "blue shoes" });
  for (const text of ["", "x".repeat(2001), 5]) assert.equal((await b.handle(doMsg({ action: "type", sig: "s3", text }))).ok, false);
});

test("do: keys: Enter needs the user's yes; PageDown and the arrows don't; a letter is refused", async () => {
  const mk = () => fake({ page: { active: { desc: FIELD } } });
  const enter = await mk().b.handle(doMsg({ action: "key", key: "Enter", cls: "quiet" }));
  assert.equal(enter.ok, false);
  const m = mk();
  const asked = await m.b.handle(doMsg({ action: "key", key: "Enter", cls: "asked" }));
  assert.equal(asked.ok, true);
  assert.deepEqual(m.st.calls.filter((c) => c[0] === "Input.dispatchKeyEvent").map((c) => c[1].type), ["keyDown", "keyUp"]);
  assert.equal(m.st.calls.find((c) => c[0] === "Input.dispatchKeyEvent")[1].text, "\r");
  assert.equal((await mk().b.handle(doMsg({ action: "key", key: "PageDown", cls: "free" }))).ok, true);
  assert.equal((await mk().b.handle(doMsg({ action: "key", key: "ArrowDown", cls: "quiet" }))).ok, true);
  assert.equal((await mk().b.handle(doMsg({ action: "key", key: "a", cls: "asked" }))).ok, false);
  assert.equal((await mk().b.handle(doMsg({ action: "key", key: "Control+a", cls: "asked" }))).ok, false);
  const pw = fake({ page: { active: { desc: { kind: "text", inputType: "password", name: "Password" } } } });
  assert.equal((await pw.b.handle(doMsg({ action: "key", key: "Tab", cls: "asked" }))).ok, false, "no key at all in a password field");
});

test("do: an upload gives the chosen input exactly one path, and only with a yes", async () => {
  const mk = () => fake({ page: { describe: { desc: FILE, fileIndex: 1 } } });
  const m = mk();
  const r = await m.b.handle(doMsg({ action: "upload", sig: "s4", cls: "asked", path: "/tmp/scratch/report.pdf" }));
  assert.equal(r.ok, true);
  const set = m.st.calls.find((c) => c[0] === "DOM.setFileInputFiles")[1];
  assert.deepEqual(set, { files: ["/tmp/scratch/report.pdf"], nodeId: 12 }, "the second file input, one file");
  for (const bad of [{ cls: "quiet" }, { cls: "free" }, { path: "relative.pdf" }, { path: undefined }, { path: "/x".repeat(600) }]) {
    const n = mk();
    const out = await n.b.handle(doMsg({ action: "upload", sig: "s4", cls: "asked", path: "/tmp/a.pdf", ...bad }));
    assert.equal(out.ok, false, JSON.stringify(bad).slice(0, 60));
    assert.equal(n.st.calls.some((c) => c[0] === "DOM.setFileInputFiles"), false);
  }
  const notFile = fake({ page: { describe: { desc: LINK, fileIndex: -1 } } });
  assert.equal((await notFile.b.handle(doMsg({ action: "upload", sig: "s1", cls: "asked", path: "/tmp/a.pdf" }))).ok, false);
  const clickFile = fake({ page: { describe: { desc: FILE, fileIndex: 0, point: { x: 1, y: 1 } } } });
  assert.equal((await clickFile.b.handle(doMsg({ action: "click", sig: "s4", cls: "asked" }))).ok, false, "a click can't open a file chooser");
});

test("scroll: moves the page and needs no debugger", async () => {
  const { b, st } = fake({ page: { scroll: { atTop: false, atBottom: true } } });
  const r = await b.handle({ id: "1", op: "scroll", tab: 5, to: "bottom", allow: [A] });
  assert.equal(r.ok, true);
  assert.equal(r.atBottom, true);
  assert.equal(st.attached, 0);
  assert.equal((await b.handle({ id: "2", op: "scroll", tab: 5, to: "sideways", allow: [A] })).ok, false);
});

test("a build without the debugger can't act, and says so", async () => {
  const { b } = fake({ page: { describe: { desc: LINK, point: { x: 1, y: 1 } } } });
  b.api.debugger = undefined;
  const r = await b.handle(doMsg({}));
  assert.equal(r.ok, false);
  assert.match(r.error, /can't run the debugger/);
});

test("active: names the front tab's site and nothing else; a private window is refused", async () => {
  const { b, st } = fake();
  const r = await b.handle({ id: "1", op: "active" });
  assert.deepEqual([r.ok, r.tab, r.origin], [true, 6, A]);
  assert.equal("url" in r || "title" in r, false);
  st.tabs.find((t) => t.id === 6).url = "chrome://settings";
  assert.equal((await b.handle({ id: "2", op: "active" })).origin, null);
  st.tabs.find((t) => t.id === 6).incognito = true;
  assert.equal((await b.handle({ id: "3", op: "active" })).ok, false);
});

test("read_active: reads the front tab only if it is still in front on the site the card named", async () => {
  const { b, st } = fake();
  const ok = await b.handle({ id: "1", op: "read_active", tab: 6, origin: A });
  assert.equal(ok.ok, true);
  assert.equal(ok.text, "Front page text");
  assert.equal((await b.handle({ id: "2", op: "read_active", tab: 6, origin: O })).ok, false, "another site than the card named");
  assert.equal((await b.handle({ id: "3", op: "read_active", tab: 5, origin: A })).ok, false, "a tab that isn't in front, even in the group");
  st.tabs.find((t) => t.id === 6).active = false;
  st.tabs.find((t) => t.id === 5).active = true;
  assert.equal((await b.handle({ id: "4", op: "read_active", tab: 6, origin: A })).ok, false, "the user switched tabs after the card");
  assert.equal((await b.handle({ id: "5", op: "read_active", tab: 5, origin: "https://EXAMPLE.com" })).ok, false);
});

test("read_active: a page that moves to another site while it is read returns nothing", async () => {
  const { b, st } = fake();
  const real = b.api.scripting.executeScript;
  b.api.scripting.executeScript = async (inj) => { const out = await real(inj); st.tabs.find((t) => t.id === 6).url = `${O}/x`; return out; };
  const r = await b.handle({ id: "1", op: "read_active", tab: 6, origin: A });
  assert.equal(r.ok, false);
  assert.equal("text" in r, false);
});

test("close: closes the tabs this extension opened, and leaves one the user dragged in", async () => {
  const { b, st } = fake();
  st.tabs.push({ id: 9, url: `${A}/a`, groupId: 7, windowId: 1, incognito: false, status: "complete" },
    { id: 10, url: `${A}/dragged`, groupId: 7, windowId: 1, incognito: false, status: "complete" });
  st.session.benjiOpened = [5, 9, 77];
  const r = await b.handle({ id: "1", op: "close" });
  assert.equal(r.ok, true);
  assert.equal(r.closed, 2);
  assert.deepEqual(st.removed.sort(), [5, 9]);
  assert.ok(st.tabs.some((t) => t.id === 10) && st.tabs.some((t) => t.id === 6));
  assert.equal(st.session.benjiOpened, undefined);
  assert.equal((await b.handle({ id: "2", op: "close" })).closed, 0, "nothing left to close");
});
