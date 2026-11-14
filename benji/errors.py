"""Provider failures told apart in plain words (D-173, step 6): a key the provider refused, no
connection, too many requests, an account out of credit, a region the provider does not serve, and
a provider that is itself in trouble.

`explain(text)` reads a ProviderError's message, which carries the HTTP status and the host (see
benji/providers.py), and returns `(reason, words)`. The words say what happened and what to try,
and name only the status and the host: never the server's body, which can echo what was sent. A
message it cannot place comes back as `("other", text)` unchanged.
"""

from __future__ import annotations

import re

REASONS = ("auth", "network", "rate_limit", "quota", "region", "provider", "bad_request", "other", "safety")
WORTH_WAITING = ("network", "rate_limit", "provider")     # these pass by themselves; a job waits (D-177)

_STATUS = re.compile(r"\bHTTP (\d{3}) from (\S+?):?(?:\s|$)")
_NETWORK = re.compile(r"network error calling (\S+)|stream from (\S+) broke off")
_QUOTA = ("balance", "insufficient_quota", "exceeded_current_quota", "arrear", "recharge", "billing",
          "overdue", "out of credit", "insufficient funds", "credit")
_REGION = ("country", "region", "territory", "not available in your", "not supported in your", "geo",
           "location is not supported")


def _host(token: str) -> str:
    token = token.strip("'\":")
    if "//" in token:
        token = token.split("//", 1)[1]
    return token.split("/", 1)[0] or "the provider"


def explain(text: str) -> tuple[str, str]:
    low = text.lower()
    m = _STATUS.search(text)
    if m:
        status, host = int(m.group(1)), _host(m.group(2))
        if status == 401:
            return "auth", (f"{host} didn't accept the API key (HTTP 401). The key may be wrong, expired or "
                            "for a different provider. Check it, then try again.")
        if status == 429:
            if any(w in low for w in _QUOTA):
                return "quota", (f"{host} says the account is out of credit or over its limit (HTTP 429). "
                                 "Add credit or raise the limit, then try again.")
            return "rate_limit", (f"{host} says requests are coming too fast (HTTP 429). Wait a minute and try again.")
        if status == 402:
            return "quota", (f"{host} says the account needs payment before it can answer (HTTP 402).")
        if status == 403:
            if any(w in low for w in _REGION):
                return "region", (f"{host} refused the request because of where it came from (HTTP 403). It may "
                                  "not serve your country or network. Benji can't change that.")
            return "auth", (f"{host} refused this key's access (HTTP 403). The key may not be allowed to use "
                            "this model. Check the key and the model.")
        if status in (500, 502, 503, 504, 529):
            return "provider", (f"{host} is having trouble (HTTP {status}); it's not your key or your connection. "
                                "Try again shortly.")
        if status in (400, 404, 413, 422):
            return "bad_request", text
    m = _NETWORK.search(text)
    if m:
        host = _host(m.group(1) or m.group(2) or "")
        return "network", (f"Benji couldn't reach {host}. Check your internet connection (or the server's "
                           "address); nothing more was sent.")
    return "other", text
