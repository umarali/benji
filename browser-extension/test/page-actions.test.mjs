// Runs pageAct (page-actions.js) in a real, headless Chrome with a throwaway profile, on a page with
// the controls it must list, name, classify and leave out. Skipped when Chrome isn't installed (set
// CHROME to use another binary). Headless only, no extension loaded, no network, nothing of the
// user's profile.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { floor } from "../act-rules.js";

const CHROME = process.env.CHROME || [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
].find((p) => existsSync(p));

const source = readFileSync(new URL("../page-actions.js", import.meta.url), "utf8").replace("export function", "function");
const BODY = `
<a href="/pricing">Pricing</a>
<a href="https://other.example/docs" aria-label="Other docs">x</a>
<a href="javascript:alert(1)">Run it</a>
<a href="/files/report.zip" download>Report</a>
<button type="button">Plain</button>
<button aria-expanded="false" type="button">More details</button>
<details><summary>Shipping</summary><p>Info</p></details>
<form method="post" action="/checkout"><label for="q">Search</label><input id="q" name="q" value="TYPED-VALUE" placeholder="PLACEHOLDER">
  <input type="password" name="pw" aria-label="Password" value="SECRET-PW">
  <input name="cardnum" aria-label="Card number" autocomplete="cc-number">
  <button>Place order</button></form>
<label><input type="checkbox" class="hide"> Show archived</label>
<div role="tab">Reviews</div>
<select aria-label="Sort"><option>One</option></select>
<input type="file" style="display:none" aria-label="Attach a file">
<input type="file" disabled>
<p style="display:none"><a href="/hidden">HIDDEN-LINK</a></p>
<button aria-hidden="true">HIDDEN-BUTTON</button>
<button id="covered" style="position:absolute;left:300px;top:300px;width:80px;height:30px">Covered</button>
<div style="position:absolute;left:290px;top:290px;width:200px;height:60px;background:#ccc"></div>
<div style="height:3000px"></div>
<style>.hide{position:absolute;opacity:0;width:0;height:0}</style>
`;

function run(script) {
  const dir = mkdtempSync(join(tmpdir(), "benji-page-actions-"));
  try {
    const page = join(dir, "page.html");
    writeFileSync(page, `<!doctype html><meta charset="utf-8"><body>${BODY}<script>
${source}
const out = {};
${script}
document.documentElement.setAttribute("data-r", btoa(unescape(encodeURIComponent(JSON.stringify(out)))));
</script></body>`);
    const dom = execFileSync(CHROME, [
      "--headless=new", "--use-mock-keychain", "--password-store=basic", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions",
      "--window-size=900,700", `--user-data-dir=${join(dir, "profile")}`, "--virtual-time-budget=1500", "--dump-dom", `file://${page}`,
    ], { encoding: "utf8", timeout: 60000, stdio: ["ignore", "pipe", "ignore"] });
    const m = /data-r="([^"]*)"/.exec(dom);
    assert.ok(m, "the page produced a result");
    return JSON.parse(decodeURIComponent(escape(Buffer.from(m[1], "base64").toString("binary"))));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
const skip = !CHROME && "no Chrome here";
const byName = (controls, name) => controls.find((c) => c.name === name);

test("list: the controls a person could use, named as the page names them, and nothing hidden or typed", { skip }, () => {
  const out = run(`out.list = pageAct("list", {max: 200});`);
  const { controls } = out.list;
  const names = controls.map((c) => c.name);
  for (const n of ["Pricing", "Other docs", "Run it", "Report", "Plain", "More details", "Shipping", "Search", "Password", "Card number", "Place order",
    "Show archived", "Reviews", "Sort", "Attach a file"]) assert.ok(names.includes(n), `lists ${n}: ${names}`);
  assert.ok(!JSON.stringify(out).includes("HIDDEN-"), "hidden elements are left out");
  assert.ok(!JSON.stringify(out).includes("TYPED-VALUE") && !JSON.stringify(out).includes("SECRET-PW"), "no typed value leaves the page");
  assert.equal(controls.filter((c) => c.kind === "file").length, 1, "the disabled file input is left out");
  assert.deepEqual(controls.map((c) => c.ref), controls.map((_, i) => i), "refs are the place in the list");
  const kind = (n) => byName(controls, n).kind;
  assert.deepEqual(["Pricing", "Plain", "More details", "Shipping", "Search", "Place order", "Show archived", "Reviews", "Sort", "Attach a file"].map(kind),
    ["link", "button", "disclosure", "disclosure", "text", "submit", "checkbox", "tab", "select", "file"]);
  assert.equal(byName(controls, "Password").sensitive, true);
  assert.equal(byName(controls, "Card number").sensitive, true);
  assert.equal(byName(controls, "Search").sensitive, false);
  assert.equal(controls.find((c) => c.href.endsWith("/pricing")).href.startsWith("file://"), true, "links come out absolute");
});

test("describe: what the engine classifies on, agreeing with the shared rules", { skip }, () => {
  const out = run(`
    const list = pageAct("list", {max: 200}).controls;
    const idx = (n) => list.find((c) => c.name === n);
    out.d = {};
    for (const n of ["Pricing", "Run it", "Report", "Plain", "Place order", "Password", "Search", "Show archived", "Attach a file"]) {
      const c = idx(n); out.d[n] = pageAct("describe", {ref: c.ref, sig: c.sig}).desc;
    }
    out.stale = pageAct("describe", {ref: idx("Pricing").ref, sig: "0000000000000000"});
    out.gone = pageAct("describe", {ref: 999, sig: "x"});
    out.fileIndex = pageAct("describe", {ref: idx("Attach a file").ref, sig: idx("Attach a file").sig}).fileIndex;
  `);
  const tab = "https://other.example";
  // The test page is a file: URL; the rules are for https pages, so a link's address is moved there.
  const onWeb = (d) => (d.href ? { ...d, href: d.href.replace(/^file:\/\/[^/]*\/[^?#]*?(?=\/[^/]*$)/, tab) } : d);
  const cls = (n, action = "click") => floor(action, onWeb(out.d[n]), tab).cls;
  assert.equal(out.d["Place order"].form, "post");
  assert.equal(cls("Place order"), "asked");
  assert.equal(cls("Plain"), "asked");
  assert.equal(cls("Run it"), "refused", "a javascript: link");
  assert.equal(cls("Report"), "asked", "a download");
  assert.equal(cls("Password"), "refused");
  assert.equal(cls("Password", "type"), "refused");
  assert.equal(cls("Search", "type"), "quiet");
  assert.equal(cls("Show archived"), "quiet");
  assert.equal(cls("Attach a file"), "refused");
  assert.match(out.stale.error, /page changed/);
  assert.match(out.gone.error, /isn't on the page/);
  assert.equal(out.fileIndex, 0);
});

test("describe with aim: finds the point to click, scrolls to it, and refuses a control something is covering", { skip }, () => {
  const out = run(`
    const list = pageAct("list", {max: 200}).controls;
    const get = (n) => { const c = list.find((x) => x.name === n); return pageAct("describe", {ref: c.ref, sig: c.sig, aim: true}); };
    out.plain = get("Plain"); out.covered = get("Covered"); out.hiddenBox = get("Show archived");
  `);
  assert.ok(out.plain.point && out.plain.point.x > 0 && out.plain.point.y > 0, "a point inside the page");
  assert.match(out.covered.error, /on top of that control/);
  assert.ok(out.hiddenBox.point, "a checkbox hidden behind its label is clicked through the label");
});

test("focus, active, scroll: only the focus and the scroll position change; no value is returned", { skip }, () => {
  const out = run(`
    const list = pageAct("list", {max: 200}).controls;
    const q = list.find((x) => x.name === "Search");
    out.focus = pageAct("focus", {ref: q.ref, sig: q.sig, replace: true});
    out.active = pageAct("active", {});
    out.sel = [document.getElementById("q").selectionStart, document.getElementById("q").selectionEnd];
    out.value = document.getElementById("q").value;
    out.down = pageAct("scroll", {to: "down"}); out.y1 = document.scrollingElement.scrollTop;
    out.bottom = pageAct("scroll", {to: "bottom"}); out.top = pageAct("scroll", {to: "top"});
    out.unknown = pageAct("fly", {});
  `);
  assert.equal(out.focus.ok, true);
  assert.equal(out.active.desc.name, "Search");
  assert.deepEqual(out.sel, [0, 11], "replace selects what is there");
  assert.equal(out.value, "TYPED-VALUE", "nothing was changed");
  assert.ok(!JSON.stringify(out.active).includes("TYPED-VALUE"));
  assert.ok(out.y1 > 100);
  assert.equal(out.bottom.atBottom, true);
  assert.equal(out.top.atTop, true);
  assert.equal(out.unknown.error, "unknown op");
});

test("sig: the same control gives the same signature on every look; a different control, a different one", { skip }, () => {
  const out = run(`
    const a = pageAct("list", {max: 200}).controls, b = pageAct("list", {max: 200}).controls;
    out.same = JSON.stringify(a.map((c) => c.sig)) === JSON.stringify(b.map((c) => c.sig));
    out.distinct = new Set(a.map((c) => c.sig)).size;
    out.n = a.length;
  `);
  assert.equal(out.same, true);
  assert.equal(out.distinct, out.n, "every control on this page is told apart");
});
