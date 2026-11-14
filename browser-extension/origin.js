// The one place a URL becomes an origin Benji may use (https, exact host and port, nothing local or
// odd). The same rules as benji/browser.py `parse_url`; both run test/origin-cases.json.

const LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const TLD = /^[a-z]{2,24}$/;
const LOCAL_SUFFIXES = [".localhost", ".local", ".internal", ".lan", ".home.arpa"];

/** { origin, path } for a URL that names a site Benji may use, else { error }. */
export function parseUrl(url) {
  if (typeof url !== "string" || url.trim() === "") return { error: "that isn't a URL" };
  const text = url.trim();
  if (text.length > 2000) return { error: "that URL is too long" };
  // eslint-disable-next-line no-control-regex
  if (/[\u0000- \u007f\\]/.test(text)) return { error: "that URL has spaces, control characters or a backslash" };
  const m = /^https:\/\/([^/?#]*)([^#]*)/i.exec(text);
  if (!m) return { error: "only https pages are supported" };
  let authority = m[1];
  if (authority.includes("@")) return { error: "a URL with a user name or password isn't supported" };
  let port = null;
  const colon = authority.lastIndexOf(":");
  if (colon >= 0 && !authority.startsWith("[")) {
    const digits = authority.slice(colon + 1);
    if (!/^[0-9]+$/.test(digits)) return { error: "that isn't a valid URL" };
    port = Number(digits);
    authority = authority.slice(0, colon);
    if (port < 1 || port > 65535) return { error: "that isn't a valid port" };
  }
  // eslint-disable-next-line no-control-regex
  if (authority === "" || authority.startsWith("[") || /[^\u0000-\u007f]/.test(authority)) {
    return { error: "only plain ASCII host names are supported" };
  }
  const host = authority.toLowerCase();
  const labels = host.split(".");
  if (labels.length < 2 || host.length > 253 || !labels.every((l) => LABEL.test(l))) {
    return { error: "that isn't a public host name" };
  }
  if (labels.some((l) => l.startsWith("xn--"))) return { error: "internationalised (punycode) names aren't supported" };
  if (!TLD.test(labels[labels.length - 1])) return { error: "that isn't a public host name" };
  if (LOCAL_SUFFIXES.some((s) => host.endsWith(s))) return { error: "that host is on this Mac or its local network" };
  const origin = `https://${host}${port !== null && port !== 443 ? `:${port}` : ""}`;
  return { origin, path: m[2] === "" ? "/" : m[2] };
}

export function originOf(url) {
  return parseUrl(url).origin ?? null;
}
