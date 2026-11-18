// The second function this extension runs inside a page (chrome.scripting.executeScript, main frame
// only), for acting: it lists a page's controls, describes one, focuses one, scrolls, and names
// the Nth file input. It must stand alone (Chrome sends its source text), so nothing outside it can
// be used. It reads no typed value (a field's value never leaves the page) and changes only what a
// person scrolling or tabbing would: the scroll position and the focus.
//
// A control's number (`ref`) is its place in document order among the controls listed; its `sig` is a
// token for that DOM node and its description. The engine keeps the pair from the last
// look, so a step on a page that changed since is refused rather than aimed at whatever is now there.
export function pageAct(op, args) {
  const SELECTOR = [
    "a[href]", "button", "input:not([type=hidden])", "select", "textarea", "summary",
    "[role=button]", "[role=link]", "[role=tab]", "[role=checkbox]", "[role=radio]", "[role=switch]",
    "[role=menuitem]", "[role=menuitemcheckbox]", "[role=menuitemradio]",
    "[contenteditable=true]", "[contenteditable='']",
  ].join(",");
  const TEXT_INPUT = new Set(["text", "search", "email", "url", "tel", "number", ""]);
  const SENSITIVE_AUTOCOMPLETE = /\b(cc-[a-z-]+|one-time-code|current-password|new-password)\b/i;
  const SENSITIVE_NAME = /pass(?:word|wd|code|phrase)|passcode|card[\s_.-]*(?:number|num|no)\b|\bcc[\s_.-]*(?:num|number)|cvv|cvc|security[\s_.-]*code|\botp\b|one[\s_.-]*time|verification[\s_.-]*code|\b2fa\b|\bpin[\s_.-]*(?:code)?\b|\biban\b|account[\s_.-]*number|routing[\s_.-]*number|\bssn\b|social[\s_.-]*security/i;
  const clip = (v, n) => String(v == null ? "" : v).split(/\s+/).filter(Boolean).join(" ").slice(0, n);

  const hiddenByStyle = (el) => {
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
      if (e.hasAttribute("hidden") || e.getAttribute("aria-hidden") === "true") return true;
      const s = getComputedStyle(e);
      if (s.display === "none" || s.visibility === "hidden" || s.visibility === "collapse") return true;
    }
    return false;
  };
  const isFileInput = (el) => el.tagName === "INPUT" && (el.type || "").toLowerCase() === "file";
  const sized = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const listed = () => Array.from(document.querySelectorAll(SELECTOR)).filter((el) => {
    if (isFileInput(el)) return !el.disabled;               // file inputs are often visually hidden
    if (hiddenByStyle(el)) return false;
    if (sized(el)) return true;
    // a checkbox or radio hidden behind its styled label is still a control
    return el.tagName === "INPUT" && ["checkbox", "radio"].includes((el.type || "").toLowerCase()) && !!(el.labels && el.labels.length);
  });

  const nameOf = (el) => {
    const aria = el.getAttribute("aria-label");
    if (aria && aria.trim()) return clip(aria, 100);
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const t = by.split(/\s+/).map((id) => { const n = document.getElementById(id); return n ? n.textContent : ""; }).join(" ");
      if (t.trim()) return clip(t, 100);
    }
    if (el.labels && el.labels.length) {
      const t = Array.from(el.labels).map((l) => l.textContent).join(" ");
      if (t.trim()) return clip(t, 100);
    }
    const tag = el.tagName;
    if (tag === "INPUT") {
      const type = (el.type || "").toLowerCase();
      if (["submit", "button", "reset", "image"].includes(type)) return clip(el.value || el.alt || el.title, 100);
      return clip(el.placeholder || el.title || el.getAttribute("name"), 100);
    }
    if (tag === "TEXTAREA" || tag === "SELECT") return clip(el.placeholder || el.title || el.getAttribute("name"), 100);
    const text = clip(el.innerText || el.textContent, 100);
    if (text) return text;
    const img = el.querySelector && el.querySelector("img[alt]");
    return clip((img && img.alt) || el.title, 100);
  };

  const kindOf = (el) => {
    const tag = el.tagName;
    const role = (el.getAttribute("role") || "").toLowerCase();
    const type = tag === "INPUT" ? (el.type || "text").toLowerCase() : "";
    if (isFileInput(el)) return "file";
    if (type === "checkbox" || ["checkbox", "switch", "menuitemcheckbox"].includes(role)) return "checkbox";
    if (type === "radio" || ["radio", "menuitemradio"].includes(role)) return "radio";
    if (tag === "SELECT") return "select";
    if (role === "tab") return "tab";
    if (tag === "SUMMARY" || (el.hasAttribute("aria-expanded") && (tag === "BUTTON" || role === "button" || tag === "A"))) return "disclosure";
    if (type === "submit" || type === "image") return "submit";
    if (type === "button" || type === "reset") return "button";
    if (tag === "BUTTON") {
      const bt = (el.getAttribute("type") || "submit").toLowerCase();
      return bt === "submit" && (el.form || el.closest("form")) ? "submit" : "button";
    }
    if (tag === "A" && el.hasAttribute("href")) return "link";
    if (role === "link") return el.hasAttribute("href") ? "link" : "button";
    if (tag === "TEXTAREA" || el.isContentEditable || el.getAttribute("contenteditable") === "" || el.getAttribute("contenteditable") === "true") return "text";
    if (tag === "INPUT" && TEXT_INPUT.has(type)) return "text";
    if (role === "button" || role === "menuitem") return "button";
    return "other";
  };

  // Chrome's isolated world persists between calls, but the page cannot access this map.
  // A signature binds a DOM node and its semantic description, not ordinary control state.
  const identities = globalThis.__benjiControlIdentities ??= new WeakMap();
  const sigOf = (el, d) => {
    // Ordinary state may change during interaction; disabled is always checked live.
    const snapshot = JSON.stringify({ ...d, checked: undefined, expanded: undefined, disabled: undefined });
    let prior = identities.get(el);
    if (!prior || prior.snapshot !== snapshot) {
      prior = { snapshot, sig: crypto.randomUUID().replaceAll("-", "") };
      identities.set(el, prior);
    }
    return prior.sig;
  };

  const describe = (el) => {
    const kind = kindOf(el);
    const tag = el.tagName.toLowerCase();
    const inputType = tag === "input" ? (el.type || "text").toLowerCase() : "";
    const name = nameOf(el);
    const d = {
      kind, tag, inputType, name,
      text: kind === "text" || kind === "select" ? "" : clip(el.innerText || el.textContent, 100),
      value: ["submit", "button"].includes(kind) && tag === "input" ? clip(el.value, 60) : "",
      href: kind === "link" && el.href ? String(el.href) : "",
      download: el.hasAttribute("download"),
      blank: (el.getAttribute("target") || "").toLowerCase() === "_blank",
      form: "",
      formAction: el.form ? String(el.hasAttribute("formaction") ? el.formAction : el.form.action) : "",
      formTarget: el.form ? String(el.hasAttribute("formtarget") ? el.formTarget : el.form.target) : "",
      disabled: !!el.disabled || el.getAttribute("aria-disabled") === "true",
      labelled: !!name,
      fieldName: clip(el.getAttribute("name") || el.id, 60),
      autocomplete: clip(el.getAttribute("autocomplete"), 60),
      placeholder: clip(el.getAttribute("placeholder"), 60),
      checked: !!el.checked || el.getAttribute("aria-checked") === "true",
      expanded: el.getAttribute("aria-expanded") === "true" || (tag === "summary" && !!(el.parentElement && el.parentElement.open)),
    };
    if (kind === "submit") {
      const form = el.form || el.closest("form");
      if (form) d.form = ((el.getAttribute("formmethod") || form.getAttribute("method") || "get").toLowerCase() === "post") ? "post" : "get";
    }
    d.sensitive = inputType === "password" || SENSITIVE_AUTOCOMPLETE.test(d.autocomplete)
      || (kind === "text" && SENSITIVE_NAME.test(d.fieldName + " " + d.name + " " + d.placeholder));
    d.sig = sigOf(el, d);
    return d;
  };

  const all = listed();
  const pick = (ref, sig) => {
    // A token names one node even if hover or focus changes earlier controls.
    const el = (typeof sig === "string" && all.find((e) => identities.get(e)?.sig === sig)) || all[ref];
    if (!el) return { error: "That control isn't on the page any more: look at the page again." };
    const d = describe(el);
    if (typeof sig === "string" && sig !== d.sig) return { error: "The page changed since it was listed: look at the page again." };
    return { el, d };
  };

  if (op === "list") {
    const max = Math.min(Number(args && args.max) || 120, 200);
    const controls = all.slice(0, max).map((el, ref) => {
      const d = describe(el);
      return { ref, sig: d.sig, kind: d.kind, name: d.name, text: d.text, href: d.href, checked: d.checked,
        expanded: d.expanded, disabled: d.disabled, sensitive: d.sensitive };
    });
    return { url: location.href, controls, truncated: all.length > max };
  }
  if (op === "describe") {
    const found = pick(Number(args.ref), args.sig);
    if (found.error) return found;
    const { el, d } = found;
    const out = { desc: d };
    if (d.kind === "file") {
      out.fileIndex = Array.from(document.querySelectorAll("input[type=file]")).filter((x) => !x.disabled).indexOf(el);
      return out;
    }
    if (args.aim) {
      const fixedPoint = args.point;
      if (fixedPoint !== undefined && (!fixedPoint || !Number.isFinite(fixedPoint.x) || !Number.isFinite(fixedPoint.y))) {
        return { error: "The click point is invalid." };
      }
      if (fixedPoint === undefined) el.scrollIntoView({ block: "center", inline: "center" });
      let target = el;
      let r = target.getBoundingClientRect();
      if ((r.width === 0 || r.height === 0) && el.labels && el.labels[0]) { target = el.labels[0]; r = target.getBoundingClientRect(); }
      if (r.width === 0 || r.height === 0) return { error: "That control has no size on the page, so it can't be clicked." };
      const x = fixedPoint === undefined ? Math.round(r.left + r.width / 2) : fixedPoint.x;
      const y = fixedPoint === undefined ? Math.round(r.top + r.height / 2) : fixedPoint.y;
      if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) return { error: "That control is outside the visible part of the page." };
      const hit = document.elementFromPoint(x, y);
      if (!hit || !(target.contains(hit) || (el.labels && Array.from(el.labels).some((l) => l.contains(hit))))) {
        return { error: "Something else is on top of that control right now, so it wasn't clicked." };
      }
      const after = pick(Number(args.ref), args.sig);
      if (after.error || after.el !== el) return { error: "The page changed since it was listed: look at the page again." };
      out.point = { x, y };
    }
    return out;
  }
  if (op === "focus") {
    const found = pick(Number(args.ref), args.sig);
    if (found.error) return found;
    const { el, d } = found;
    const identity = ["kind", "tag", "inputType", "fieldName", "form", "formAction", "formTarget", "href", "download", "blank"];
    const focusedField = () => {
      if (!el.isConnected || document.activeElement !== el) return null;
      const now = describe(el);
      if (now.kind !== "text" || now.sensitive || now.disabled || identity.some((key) => now[key] !== d[key])) return null;
      return now;
    };
    el.focus({ preventScroll: false });
    let after = focusedField();
    if (!after) return { error: "The field changed or wouldn't take the focus, so no text was entered." };
    if (args.replace) {
      if (typeof el.select === "function") el.select();
      else { const r = document.createRange(); r.selectNodeContents(el); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
      after = focusedField();
      if (!after) return { error: "The field changed during selection, so no text was entered." };
    }
    // Focus may clear a placeholder. Only this validated field gets a fresh continuation token.
    return { ok: true, sig: after.sig };
  }
  if (op === "validate") {
    const found = pick(Number(args.ref), args.sig);
    if (found.error) return found;
    if (found.d.kind !== "text" || found.d.sensitive || found.d.disabled) return { error: "That field cannot be typed into." };
    if (args.focus && document.activeElement !== found.el) return { error: "The page changed focus, so no text was entered." };
    return { ok: true };
  }
  if (op === "active") {
    const el = document.activeElement;
    if (!el || el === document.body || el === document.documentElement) return { desc: null };
    return { desc: describe(el) };
  }
  if (op === "scroll") {
    const root = document.scrollingElement || document.documentElement;
    const step = Math.max(200, Math.round(innerHeight * 0.85));
    const before = root.scrollTop;
    if (args.to === "down") root.scrollTop = before + step;
    else if (args.to === "up") root.scrollTop = Math.max(0, before - step);
    else if (args.to === "top") root.scrollTop = 0;
    else if (args.to === "bottom") root.scrollTop = root.scrollHeight;
    return { atTop: root.scrollTop <= 0, atBottom: root.scrollTop + innerHeight >= root.scrollHeight - 2 };
  }
  return { error: "unknown op" };
}
