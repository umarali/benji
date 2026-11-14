// What a click, a typed word or a key press is classed as, from the element and the page alone.
// This is the extension's half of the rule (benji/browser_act.py `floor` is the engine's half; both
// run test/act-cases.json). The engine decides the class and the extension looks again right before
// it acts: if its own class is higher than the one the engine settled on, it does nothing.
//
// Classes: free < quiet < asked < refused. Nothing here is decided by what the model called the
// control: only by what the page's own element is.

import { originOf } from "./origin.js";

export const FREE = "free";
export const QUIET = "quiet";
export const ASKED = "asked";
export const REFUSED = "refused";
export const RANK = { free: 0, quiet: 1, asked: 2, refused: 3 };

export const FREE_KEYS = ["PageUp", "PageDown", "Home", "End"];
export const QUIET_KEYS = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Tab", "Escape"];
export const ASKED_KEYS = ["Enter", "Backspace", "Delete"];
export const KEYS = [...FREE_KEYS, ...QUIET_KEYS, ...ASKED_KEYS];
const CHECK_KINDS = ["checkbox", "radio", "select", "tab", "disclosure"];
const KIND_WORD = { link: "link", checkbox: "checkbox", radio: "option", select: "menu", tab: "tab",
  disclosure: "section header", text: "field", submit: "button", button: "button" };

const COMMIT = /\b(submit|send|post|publish|buy|purchas|pay|checkout|check out|order|confirm|delete|remov|eras|discard|sign out|signout|log out|logout|unsubscrib|subscrib|accept|agree|allow|install|transfer|withdraw|donat|authori[sz]|place order|wire|empty|clear all|reset|deactivat|cancel (?:my |your )?(?:account|subscription|order))/i;
const SENSITIVE_AUTOCOMPLETE = /\b(cc-[a-z-]+|one-time-code|current-password|new-password)\b/i;
const SENSITIVE_NAME = /pass(?:word|wd|code|phrase)|passcode|card[\s_.-]*(?:number|num|no)\b|\bcc[\s_.-]*(?:num|number)|cvv|cvc|security[\s_.-]*code|\botp\b|one[\s_.-]*time|verification[\s_.-]*code|\b2fa\b|\bpin[\s_.-]*(?:code)?\b|\biban\b|account[\s_.-]*number|routing[\s_.-]*number|\bssn\b|social[\s_.-]*security/i;
const DOWNLOAD_EXT = /\.(?:zip|dmg|pkg|exe|msi|app|tar|gz|tgz|rar|7z|iso|apk|csv|xlsx?|docx?|pptx?|pdf|mp[34]|mov)(?:$|[?#])/i;

const clip = (v, n) => String(v ?? "").split(/\s+/).filter(Boolean).join(" ").slice(0, n);
const label = (d) => clip(d.name || d.text, 80);
const verdict = (cls, code, extra = {}) => ({ cls, code, leaves: "", download: false, ...extra });

/** A password, card-number or one-time-code field, by what the page says it is. */
export function sensitive(desc) {
  if (!desc || typeof desc !== "object") return false;
  if (desc.sensitive === true) return true;
  if (String(desc.inputType ?? "").toLowerCase() === "password") return true;
  if (SENSITIVE_AUTOCOMPLETE.test(String(desc.autocomplete ?? ""))) return true;
  const hint = ["fieldName", "name", "placeholder"].map((k) => String(desc[k] ?? "")).join(" ");
  return desc.kind === "text" && SENSITIVE_NAME.test(hint);
}

export function commitWord(desc) {
  const m = COMMIT.exec(["name", "text", "value"].map((k) => String(desc[k] ?? "")).join(" "));
  return m ? m[1].toLowerCase() : "";
}

function scheme(href) {
  const m = /^([a-z][a-z0-9+.-]*):/i.exec(href || "");
  return m ? m[1].toLowerCase() : "";
}

function looksLikeDownload(href) {
  const noHash = String(href).split("#")[0];
  const q = noHash.indexOf("?");
  const path = (q >= 0 ? noHash.slice(0, q) : noHash).replace(/^[a-z][a-z0-9+.-]*:\/\/[^/]*/i, "");
  return DOWNLOAD_EXT.test(path + (q >= 0 ? "?" : ""));
}

/** The class of `action` (click, type or key) on `desc` (for a key: { key, focus }) on a page whose
 *  origin is `tabOrigin`. Returns { cls, code, leaves, download }. */
export function floor(action, desc, tabOrigin) {
  const d = desc && typeof desc === "object" ? desc : {};
  if (action === "key") return floorKey(String(d.key ?? ""), d.focus && typeof d.focus === "object" ? d.focus : null);
  if (sensitive(d)) return verdict(REFUSED, "browser_act_refused");
  if (d.disabled === true) return verdict(REFUSED, "browser_act_refused");
  const kind = String(d.kind ?? "");
  const name = label(d);
  if (kind === "file") return verdict(REFUSED, "browser_act_refused");
  if (!name && !((kind === "checkbox" || kind === "radio") && d.labelled === true)) return verdict(REFUSED, "browser_act_refused");
  if (action === "type") return kind === "text" ? verdict(QUIET, "browser_act_quiet") : verdict(REFUSED, "browser_act_refused");
  // a click
  const word = commitWord(d);
  if (kind === "link") {
    const href = String(d.href ?? "");
    const sch = scheme(href);
    if (!["https", "http", "mailto", "tel"].includes(sch)) return verdict(REFUSED, "browser_act_refused");
    if (word) return verdict(ASKED, "browser_act_asked");
    if (sch === "mailto" || sch === "tel") return verdict(ASKED, "browser_act_asked");
    if (d.download === true || looksLikeDownload(href)) return verdict(ASKED, "browser_act_asked", { download: true });
    const target = originOf(href);
    if (target === null) return verdict(ASKED, "browser_act_asked");
    if (target !== tabOrigin) return verdict(ASKED, "browser_act_leaves", { leaves: target });
    if (d.blank === true) return verdict(ASKED, "browser_act_asked");
    return verdict(QUIET, "browser_act_quiet");
  }
  if (kind === "submit" || kind === "button") return verdict(ASKED, "browser_act_asked");
  if (CHECK_KINDS.includes(kind)) return word ? verdict(ASKED, "browser_act_asked") : verdict(QUIET, "browser_act_quiet");
  if (kind === "text") return verdict(QUIET, "browser_act_quiet");
  return verdict(ASKED, "browser_act_asked");
}

function floorKey(key, focus) {
  if (!KEYS.includes(key)) return verdict(REFUSED, "browser_act_refused");
  if (focus !== null && sensitive(focus)) return verdict(REFUSED, "browser_act_refused");
  if (FREE_KEYS.includes(key)) return verdict(FREE, "browser_act_free");
  if (QUIET_KEYS.includes(key)) return verdict(QUIET, "browser_act_quiet");
  return verdict(ASKED, "browser_act_asked");
}

export const higher = (a, b) => RANK[a] > RANK[b];
export { KIND_WORD, clip };
