"""Network helpers for the web tools: HTTP GET, HTML-to-text, and search.

Pure standard library. Search picks a provider by environment:
  BRAVE_API_KEY  -> Brave Search API
  SERPAPI_KEY    -> SerpAPI (Google)
  (neither)      -> DuckDuckGo HTML endpoint (no key, best-effort)
"""

from __future__ import annotations

import html
import http.client
import json
import os
import re
import socket
import urllib.error
import urllib.parse
import urllib.request

from .gate import host_refusal
from . import tls

USER_AGENT = "benji/0.1 (+https://localhost) python-urllib"
DEFAULT_TIMEOUT = 30


class WebError(RuntimeError):
    pass


def _check_url(url: str) -> None:
    """Refuse what isn't http(s), and any host on this Mac or its network:
    private, loopback and link-local addresses, by name or by what the name resolves to now."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise WebError(f"refusing non-http(s) URL: {url!r}")
    why = host_refusal(parsed.hostname, resolve=lambda *_: [])
    if why:
        raise WebError(f"refusing {url}: {why}")


class _CheckedRedirects(urllib.request.HTTPRedirectHandler):
    """Every redirect's target is checked like the first URL, before it is followed."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _check_url(urllib.parse.urljoin(req.full_url, newurl))
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _public_socket(address, timeout=DEFAULT_TIMEOUT, source_address=None):
    """Resolve once, check the whole answer, and connect without another name lookup.

    HTTPSConnection still owns TLS: its original hostname supplies SNI and certificate checks.
    """
    host, port = address
    infos = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
    why = host_refusal(host, resolve=lambda *_: infos)
    if why:
        raise WebError(f"refusing {host}: {why}")
    last_error = None
    for family, kind, proto, _, sockaddr in infos:
        sock = None
        try:
            sock = socket.socket(family, kind, proto)
            sock.settimeout(timeout)
            if source_address:
                sock.bind(source_address)
            sock.connect(sockaddr)
            return sock
        except OSError as e:
            last_error = e
            if sock is not None:
                sock.close()
    raise last_error or OSError("host has no usable addresses")


class _PublicHTTPConnection(http.client.HTTPConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = _public_socket


class _PublicHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = _public_socket


class _PublicHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        _check_url(req.full_url)
        return self.do_open(_PublicHTTPConnection, req)


class _PublicHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        _check_url(req.full_url)
        return self.do_open(_PublicHTTPSConnection, req, context=tls.context() or self._context)


# A proxy could resolve the hostname elsewhere and bypass the checked destination entirely.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _CheckedRedirects,
                                      _PublicHTTPHandler, _PublicHTTPSHandler)


def _get(url: str, headers: dict[str, str] | None = None, timeout: int = DEFAULT_TIMEOUT) -> str:
    _check_url(url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            charset = resp.headers.get_content_charset() or "utf-8"
            return resp.read().decode(charset, errors="replace")
    except tls.TrustError as e:
        raise WebError(str(e)) from None
    except urllib.error.HTTPError as e:
        raise WebError(f"HTTP {e.code} for {url}") from None
    except urllib.error.URLError as e:
        raise WebError(f"network error for {url}: {e.reason}") from None


_SCRIPT_STYLE = re.compile(r"<(script|style)\b[^>]*>.*?</\1>", re.I | re.S)
_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t\f\v]+")
_BLANKLINES = re.compile(r"\n\s*\n\s*\n+")


def html_to_text(doc: str) -> str:
    """Crude but dependency-free HTML → readable text."""
    doc = _SCRIPT_STYLE.sub(" ", doc)
    doc = re.sub(r"<(br|/p|/div|/li|/h[1-6]|/tr)\s*/?>", "\n", doc, flags=re.I)
    doc = _TAG.sub("", doc)
    doc = html.unescape(doc)
    doc = _WS.sub(" ", doc)
    doc = _BLANKLINES.sub("\n\n", doc)
    return doc.strip()


def fetch_text(url: str, max_chars: int = 12000) -> str:
    raw = _get(url)
    text = html_to_text(raw)
    if len(text) > max_chars:
        text = text[:max_chars] + f"\n... [truncated, {len(text) - max_chars} more chars]"
    return text


# --- search providers -------------------------------------------------------

def _search_brave(query: str, n: int, key: str) -> list[dict]:
    url = "https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode(
        {"q": query, "count": n})
    data = json.loads(_get(url, headers={"X-Subscription-Token": key, "Accept": "application/json"}))
    out = []
    for r in (data.get("web", {}).get("results") or [])[:n]:
        out.append({"title": r.get("title", ""), "url": r.get("url", ""),
                    "snippet": r.get("description", "")})
    return out


def _search_serpapi(query: str, n: int, key: str) -> list[dict]:
    url = "https://serpapi.com/search.json?" + urllib.parse.urlencode(
        {"q": query, "api_key": key, "engine": "google", "num": n})
    data = json.loads(_get(url))
    out = []
    for r in (data.get("organic_results") or [])[:n]:
        out.append({"title": r.get("title", ""), "url": r.get("link", ""),
                    "snippet": r.get("snippet", "")})
    return out


_DDG_RESULT = re.compile(
    r'result__a"[^>]*href="(?P<href>[^"]+)"[^>]*>(?P<title>.*?)</a>', re.S)
_DDG_SNIPPET = re.compile(r'result__snippet"[^>]*>(?P<snip>.*?)</a>', re.S)


def _search_ddg(query: str, n: int) -> list[dict]:
    url = "https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({"q": query})
    doc = _get(url)
    low = doc.lower()
    if "result__a" not in doc and ("challenge" in low or "anomaly" in low):
        raise WebError(
            "DuckDuckGo blocked this automated request (bot challenge). "
            "Set BRAVE_API_KEY or SERPAPI_KEY for reliable web search.")
    hrefs = list(_DDG_RESULT.finditer(doc))
    snippets = list(_DDG_SNIPPET.finditer(doc))
    out = []
    for i, m in enumerate(hrefs[:n]):
        href = m.group("href")
        # DDG wraps links as //duckduckgo.com/l/?uddg=<encoded-real-url>
        qs = urllib.parse.urlparse(href).query
        real = urllib.parse.parse_qs(qs).get("uddg", [href])
        url_ = real[0] if real else href
        title = html_to_text(m.group("title"))
        snip = html_to_text(snippets[i].group("snip")) if i < len(snippets) else ""
        out.append({"title": title, "url": url_, "snippet": snip})
    return out


def search(query: str, n: int = 5) -> tuple[str, list[dict]]:
    """Return (provider_name, results)."""
    brave = os.getenv("BRAVE_API_KEY", "").strip()
    serp = os.getenv("SERPAPI_KEY", "").strip()
    if brave:
        return "brave", _search_brave(query, n, brave)
    if serp:
        return "serpapi", _search_serpapi(query, n, serp)
    return "duckduckgo", _search_ddg(query, n)
