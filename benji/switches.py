"""Benji's on/off settings, read the same way everywhere.

`0`, `false`, `no` and `off` turn a setting off; `1`, `true`, `yes` and `on` turn it on (any case).
An unset or empty setting, or any other value, keeps the setting's default.
"""

from __future__ import annotations

import os

_OFF = ("0", "false", "no", "off")
_ON = ("1", "true", "yes", "on")


def switch(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if raw in _OFF:
        return False
    if raw in _ON:
        return True
    return default
