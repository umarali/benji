"""The tools Benji can use: each one's schema and handler, and the decision whether a call runs,
asks or is refused (`decide`) before it runs (`dispatch`). One module per kind of tool; this
package exposes them all as `benji.tools`."""

from __future__ import annotations

import math
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable
from .. import audit
from .. import browser as browser_mod
from .. import browser_act
from .. import drive as drive_mod
from .. import gate, screen_class
from .. import jobs as jobs_mod
from .. import schedule as schedule_mod
from ..browser_link import LinkError

from .context import (  # noqa: F401
    Ctx, MAX_OUTPUT, ToolCancelled, _SENSITIVE_SHELL, _SENSITIVE_SHELL_RE, _kill_group,
    _resolve, _run, _truncate, _with_note, _within, shell_sensitivity,
)
from .shell_files import (  # noqa: F401
    _list_dir, _private, _read_file, _run_shell, _search_files, _write_file,
)
from .skills import (  # noqa: F401
    SKILL_PINS, UNVERIFIED_SKILL, _inside_dir, _list_skills, _parse_front_matter, _read_skill,
    skill_hash, skill_verified,
)
from .web_access import (  # noqa: F401
    _web_fetch, _web_search,
)
from .automation import (  # noqa: F401
    _AS_MUTATING, _AS_SENSITIVE, _brief, _list_shortcuts, _require_macos, _run_applescript,
    _run_shortcut, applescript_is_mutating, applescript_sensitivity,
)
from .screen_actions import (  # noqa: F401
    KEYS, MAX_SCROLL, MAX_TYPED_CHARS, MODIFIERS, SCREEN_TOOL_NAMES, SCROLL_DIRECTIONS,
    _KEY_ALIASES, _KEY_SHOWN, _MODIFIER_ALIASES, _key_name, _point, _screen_reason,
    _screen_step, _screen_tool, _whole, drive_live, drive_plan, key_may_commit,
    screen_plan, screen_reason, screen_step,
)
from .drive_mode import (  # noqa: F401
    DRIVE_CONSENT_TOOLS, DRIVE_TOOL_NAMES, _DRIVE_WHY, _drive_refusal, _end_drive_tool, _offer_drive,
    _start_drive, drive_declined, drive_granted, end_drive,
)
from .remember import (  # noqa: F401
    MAX_NOTE_CHARS, _keep_note, _recall, _remember,
)
from .background_jobs import (  # noqa: F401
    IN_JOB_REFUSAL, _find_jobs, _is_off, _read_job, _schedule_job, _start_job,
)
from .browser_tabs import (  # noqa: F401
    BROWSER_TOOL_NAMES, _ACT_ACTION, _act_allowed, _always, _ask_here, _browser_act,
    _browser_look, _browser_open, _browser_page_tool, _browser_read, _browser_scroll, _browser_tabs,
    _browser_tool, _read_active_tab, _refuse_browser, _taint_note, browser_approved, decline_target,
    never_auto_approved,
)
from .registry import (  # noqa: F401
    ACTIVE_TOOLS, BROWSER_TOOLS, DRIVE_TOOLS, JOB_TOOLS, NOTE_TOOLS, SCREEN_TOOLS,
    TOOLS, Tool, _BY_NAME, _INTENT, _PAGE_NOTE, _POINT,
    _REPEAT_SCHEMA, _STEP_NOTE,
)
from .approval import (  # noqa: F401
    ASKED, DENIED, Decision, FREE, OUTSIDE_CONTENT, QUIET,
    READ_CLASS, _DATA_CLOSE, _DATA_OPEN, _SHELL_PATH_CLASS, _browser_tool_offered, _decide,
    _decide_drive, _decide_tainted, _job_title, _taint_action, _taints, _unattended_action,
    as_data, decide, dispatch, is_tool, needs_approval, schedule_reason,
    tool_specs,
)
