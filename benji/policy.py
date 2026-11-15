"""A local policy file that can only restrict.

`policy.json` in Benji's working folder (`~/.benji/policy.json`) lists tool families to switch off:

    {"disable": ["shell", "web"]}

It narrows what the engine offers and runs, and nothing else: no key in it can enable a tool, widen
a folder, skip an approval or turn a switch on. Unknown keys are ignored (so a future or hostile
file cannot do more than the one thing above), a family or tool name it does not know is ignored,
and a file that exists but cannot be read as the format above is read the strict way: every
family that reaches outside Benji (shell, files, web, apps, screen, browser, jobs) is off. A
missing file changes nothing. Nothing remote ever supplies this file; the model can only narrow it
too, since the only thing it can write there is more `disable`.

The families are the ones the audit log and the Settings page use, in plain words.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

FILE_NAME = "policy.json"
MAX_BYTES = 8192

# family -> the tools in it. Every tool the engine can offer is in exactly one family.
FAMILIES: dict[str, tuple[str, ...]] = {
    "shell": ("run_shell",),
    "files": ("read_file", "write_file", "list_dir", "search_files"),
    "web": ("web_fetch", "web_search"),
    "apps": ("run_applescript", "run_shortcut", "list_shortcuts"),
    "screen": ("click", "scroll", "type_text", "press_key", "drag"),
    "drive": ("offer_drive", "start_drive", "end_drive"),
    # Reading and acting are separate switches: "browser" is open, tabs, read and the front-tab read;
    # "browser_act" is looking at controls, scrolling, clicking, typing and keys; "browser_upload" is the one
    # tool that gives a page a file. Acting and uploading also go when "browser" goes (they need it).
    "browser": ("browser_open", "browser_tabs", "browser_read", "read_active_tab"),
    "browser_act": ("browser_look", "browser_scroll", "browser_click", "browser_type", "browser_key"),
    "browser_upload": ("browser_upload",),
    "jobs": ("start_job", "schedule_job", "find_jobs", "read_job"),
    "memory": ("remember", "recall", "keep_note"),
    "skills": ("list_skills", "read_skill"),
}
# What the strict reading of an unreadable file switches off: everything that reaches outside Benji.
STRICT = ("shell", "files", "web", "apps", "screen", "drive", "browser", "browser_act", "browser_upload", "jobs")

_FAMILY_OF = {tool: family for family, tools in FAMILIES.items() for tool in tools}


@dataclass(frozen=True)
class Policy:
    families: frozenset = frozenset()       # families switched off
    tools: frozenset = frozenset()          # single tools switched off
    unreadable: bool = False                # the file was there but not in the format: read strictly

    def blocks(self, tool: str) -> bool:
        family = _FAMILY_OF.get(tool, "")
        if family in ("browser_act", "browser_upload") and "browser" in self.families:
            return True                 # acting and uploading need reading: no reading, no acting
        if tool == "browser_upload" and (self.blocks("browser_look") or "browser_act" in self.families):
            return True                 # and an upload is an acting step: no acting, no upload
        return tool in self.tools or family in self.families

    def blocks_family(self, family: str) -> bool:
        return family in self.families

    @property
    def active(self) -> bool:
        return bool(self.families or self.tools)

    def filter_specs(self, specs: list[dict]) -> list[dict]:
        return [s for s in specs if not self.blocks(s.get("name", ""))]

    def restrict_turn(self, info):
        """A TurnInfo with what this policy switches off taken out (it only ever turns things off)."""
        from dataclasses import replace
        changes = {}
        if self.blocks_family("screen") and info.screen_actions:
            changes.update(screen_actions=False, screen_simple_steps=False)
        # A drive goes when the screen goes, or when the drive tools are switched off.
        if info.drive and (self.blocks_family("screen") or self.blocks_family("drive")
                           or any(self.blocks(t) for t in FAMILIES["drive"])):
            changes.update(drive=False)
        if self.blocks_family("jobs") and info.jobs:
            changes.update(jobs=False)
        # Schedules go when jobs go, or when start_job or schedule_job alone is switched off.
        if info.schedules and (self.blocks_family("jobs") or self.blocks("schedule_job") or self.blocks("start_job")):
            changes.update(schedules=False)
        if self.blocks_family("browser") and info.browser:
            changes.update(browser=False)
        if self.blocks("keep_note") and info.notes:
            changes.update(notes=False)
        return replace(info, **changes) if changes else info

    def summary(self) -> str:
        """Names only, for the engine's start line and the audit log's plain words."""
        names = sorted(self.families) + sorted(self.tools)
        return ", ".join(names) if names else "nothing"


NONE = Policy()


def load(workdir: str | os.PathLike | None) -> Policy:
    """The policy in `workdir`/policy.json. Never raises: a missing file is no policy, an unreadable
    one is the strict policy."""
    if workdir is None:
        return NONE
    path = Path(workdir) / FILE_NAME
    try:
        if not path.exists():
            return NONE
        with open(path, "rb") as f:
            raw = f.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError("too large")
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            raise ValueError("not an object")
        listed = data.get("disable", [])
        if not isinstance(listed, list) or not all(isinstance(x, str) for x in listed):
            raise ValueError("disable is a list of names")
    except (OSError, ValueError, UnicodeDecodeError):
        return Policy(families=frozenset(STRICT), unreadable=True)
    names = {x.strip().lower() for x in listed}
    return Policy(families=frozenset(n for n in names if n in FAMILIES),
                  tools=frozenset(n for n in names if n in _FAMILY_OF))


def refusal(tool: str, policy: Policy) -> str:
    """What the model is told when a call is stopped by the policy (never run, never asked)."""
    why = "the strict reading of an unreadable policy.json" if policy.unreadable else "the user's policy.json"
    return (f"[refused] {tool} is switched off by {why}. Don't try another way round it; "
            "tell the user it's switched off if they ask for it.")
