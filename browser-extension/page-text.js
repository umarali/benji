// The one function this extension runs inside a page (chrome.scripting.executeScript, main frame
// only). It must stand alone: Chrome sends its source text, so it can use nothing outside itself.
// It returns the text a person would see: no scripts, styles, hidden elements, frames, or any form
// control (typed values never leave the page). It changes nothing in the page.
export function visibleText(maxChars) {
  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "IFRAME", "OBJECT", "EMBED", "CANVAS",
    "SVG", "TEXTAREA", "INPUT", "SELECT", "OPTION"]);
  const hidden = new WeakMap();
  const isHidden = (el) => {
    if (hidden.has(el)) return hidden.get(el);
    let result = false;
    if (SKIP.has(el.tagName.toUpperCase()) || el.hasAttribute("hidden") || el.getAttribute("aria-hidden") === "true"
      || el.getAttribute("contenteditable") === "true" || el.getAttribute("contenteditable") === "") {
      result = true;
    } else {
      const style = getComputedStyle(el);
      result = style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse";
      if (!result && el.parentElement) result = isHidden(el.parentElement);
    }
    hidden.set(el, result);
    return result;
  };
  const blockOf = (el) => {
    for (let e = el; e; e = e.parentElement) {
      const d = getComputedStyle(e).display;
      if (!d.startsWith("inline") && d !== "contents") return e;
    }
    return document.body;
  };
  const root = document.body || document.documentElement;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const parts = [];
  let length = 0;
  let lastBlock = null;
  let truncated = false;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const el = node.parentElement;
    if (!el || isHidden(el)) continue;
    const text = node.nodeValue.replace(/\s+/g, " ");
    if (text.trim() === "") continue;
    const block = blockOf(el);
    const piece = (lastBlock !== null && block !== lastBlock ? "\n" : "") + (lastBlock === block ? text : text.trimStart());
    lastBlock = block;
    if (length + piece.length > maxChars) {
      parts.push(piece.slice(0, Math.max(0, maxChars - length)));
      truncated = true;
      break;
    }
    parts.push(piece);
    length += piece.length;
  }
  return { text: parts.join("").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim(), truncated };
}
