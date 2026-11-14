"""Benji — a local, terminal-first personal assistant (M0 walking skeleton)."""

from . import aliases

__version__ = "0.1.0"

aliases.adopt()         # first, so every later read of a BENJI_* variable also sees its older names
