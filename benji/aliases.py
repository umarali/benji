"""The names Benji's settings have had: BENJI_* now, CHILLY_* and PAL_* from before the renames.

No imports from the package, so it can run first (`benji/__init__.py`), before anything reads a variable.
Everything else reads only the canonical BENJI_* names. The app's twin is BenjiCore/LegacyEnvironment.swift.
"""

import os

PREFIXES = ("BENJI_", "CHILLY_", "PAL_")        # newest first: the order they win in
KEY_SOURCE_NAMES = tuple(p + "KEY_SOURCE" for p in PREFIXES)
NOT_ADOPTED = {"CHILLY_DIR", "PAL_DIR"}         # an old value of this names the old code (AssistantLocator.swift)


def canonical_name(key: str) -> str:
    """`CHILLY_MODEL` -> `BENJI_MODEL`; a name that is not one of ours (ANTHROPIC_API_KEY) is unchanged."""
    for prefix in PREFIXES[1:]:
        if key.startswith(prefix):
            return PREFIXES[0] + key[len(prefix):]
    return key


def rank(key: str) -> int:
    """How new a name is: 0 for BENJI_* and for anything that is not one of ours."""
    for i, prefix in enumerate(PREFIXES):
        if key.startswith(prefix):
            return i
    return 0


def adopt(environ=None) -> None:
    """Give every older variable its BENJI_* name, unless that is already set: BENJI_* over CHILLY_* over
    PAL_*. A variable set to the empty string counts as set. The older names are left in place."""
    env = os.environ if environ is None else environ
    for prefix in PREFIXES[1:]:
        for key, value in list(env.items()):
            if key.startswith(prefix) and key not in NOT_ADOPTED:
                env.setdefault(PREFIXES[0] + key[len(prefix):], value)
