"""The rules behind the approval gate that aren't about one tool's own work. Pure functions, so
selftest.py checks each rule alone; benji/tools/approval.py (`decide` and `dispatch`) applies them.

  shell_review     run_shell runs unasked only when every simple command in it is on a short
                   read-only list and every path it names is inside the working folder;
                   joined by ; && || | is fine, and so is a redirect to /dev/null or 2>&1
  shell_danger     what a command does that makes it asked first, in the card's words
  private_path     paths the read tools refuse outright, never asking
  url_review       web_fetch: hosts it refuses (private, loopback, link-local, .local) and URLs
                   it asks about (a long or blob-carrying path or query)
  taint_reason     once a turn has taken in outside text, what is asked that wasn't; the
                   sources a turn has are a small closed set (screen, web, browser, file)
  said_by_user     whether a fact to remember is in the user's own message
  tool_env         the environment tool processes get: no API keys, no BENJI_*

The gate lives in code, so a model that ignores or is talked out of the prompt's DATA rule still
can't act unasked: the prompt rule is a second line of defence, never the only one.
"""

from __future__ import annotations

import fnmatch
import ipaddress
import os
import re
import socket
import time
import unicodedata
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

# --- run_shell allowlist --------------------------------------------------------------------

# Commands that only read. Each has its own idea of which arguments are paths (`_paths`).
SHELL_READ_ONLY = frozenset({
    "ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "date", "pwd", "echo", "file",
    "stat", "du", "df", "which", "git",
})
GIT_READ_ONLY = frozenset({"status", "log", "diff", "show", "branch"})
_GIT_BRANCH_FLAGS = frozenset({"-a", "-r", "-v", "-vv", "-l", "--all", "--remotes", "--list",
                               "--verbose", "--show-current", "--no-color", "--color", "--merged"})
_GIT_REFUSED = ("--output", "--no-index", "--ext-diff", "--textconv", "--exec")
_FIND_REFUSED = frozenset({"-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fprint0",
                           "-fprintf", "-fls", "-rm"})
_SEPARATORS = (";", "&&", "||", "|", "&", "\n")
MAX_SHELL_CHARS = 4000      # a longer command is asked about, not parsed (and not run through the regexes)


class _Unclear(Exception):
    """The command uses shell syntax whose effect can't be read off its text."""


@dataclass
class _Redir:
    """A redirection: `fd` the number or `&` written before the operator, `op` the operator
    (`>`, `>>`, `>&`, `>|`), `target` the word after it, `start`/`end` its place in the text."""
    fd: str
    op: str
    start: int
    target: str | None = None
    end: int = 0

    @property
    def harmless(self) -> bool:
        """Writes nowhere: to /dev/null, or stderr joined to stdout (`2>&1`)."""
        return self.target == "/dev/null" or (self.fd == "2" and self.op == ">&" and self.target == "1")


@dataclass
class _Simple:
    argv: list[str] = field(default_factory=list)
    redirs: list[_Redir] = field(default_factory=list)
    globs: set[int] = field(default_factory=set)  # unquoted: may change argument slots


@dataclass
class Parsed:
    """A command read into simple commands. `scrubbed` is the text with the harmless redirects
    blanked, for the denylist's text patterns, which would otherwise see `2>/dev/null` as a write."""
    commands: list[_Simple]
    scrubbed: str
    compound: bool


def _odd_space(c: str) -> bool:
    """A character the shell treats as part of a word but Python as a space (a no-break space, a
    line separator, a control character): outside quotes the two readings could differ."""
    return c not in " \t\n" and (c.isspace() or unicodedata.category(c) in ("Cc", "Cf", "Zs", "Zl", "Zp"))


def parse(command: str) -> Parsed:
    """The simple commands in `command`, each as its words with quotes removed and its redirects.
    Raises _Unclear for a subshell, backticks, `$(`, a variable, `$'…'`, a here-document, input
    redirection, braces, a word-initial comment, a backslash-newline, an odd space character,
    an unclosed quote or a command that is too long."""
    if "\\\n" in command:
        raise _Unclear("a backslash-newline changes shell words")
    if len(command) > MAX_SHELL_CHARS:
        raise _Unclear(f"it is over {MAX_SHELL_CHARS} characters long")
    commands: list[_Simple] = [_Simple()]
    word: list[str] = []
    in_word = False
    word_quoted = False
    word_start = 0
    i, n = 0, len(command)
    quote = ""

    def end_word(at: int) -> None:
        nonlocal word, in_word, word_quoted
        if in_word:
            text = "".join(word)
            if any(c in text for c in "*?[") and "\\" in command[word_start:at]:
                raise _Unclear("escapes in a glob cannot be expanded safely")
            cur = commands[-1]
            if cur.redirs and cur.redirs[-1].target is None:
                cur.redirs[-1].target, cur.redirs[-1].end = text, at
            else:
                if word_glob:
                    cur.globs.add(len(cur.argv))
                cur.argv.append(text)
        word, in_word, word_quoted = [], False, False

    def open_redirect(fd: str, start: int) -> None:
        cur = commands[-1]
        if cur.redirs and cur.redirs[-1].target is None:
            raise _Unclear("a redirect has nothing to write to")
        cur.redirs.append(_Redir(fd, ">", start))

    while i < n:
        c = command[i]
        if not in_word:
            word_glob = False
        if quote == "'":
            if c == "'":
                quote = ""
            else:
                word.append(c)
            i += 1
            continue
        if c == "`":
            raise _Unclear("backticks run a command inside the command")
        if c == "$" and i + 1 < n and (command[i + 1] in "({'\"" or command[i + 1].isalnum()
                                       or command[i + 1] in "_@*#?!$-"):
            nxt = command[i + 1]
            raise _Unclear("$(…) runs a command inside the command" if nxt == "("
                           else "$'…' spells out characters that can't be checked first" if nxt in "'\""
                           else "a variable fills in text that can't be checked first")
        if quote == '"':
            if c == '"':
                quote = ""
            elif c == "\\" and i + 1 < n:
                word.append(command[i + 1])
                i += 1
            else:
                word.append(c)
            i += 1
            continue
        if c == "#" and not in_word:
            raise _Unclear("a shell comment can hide the rest of a line")
        if _odd_space(c):
            raise _Unclear("it has an unusual space or control character")
        if c in "'\"":
            if not in_word:
                word_start = i
            quote, in_word, word_quoted = c, True, True
        elif c == "\\" and i + 1 < n:
            if not in_word:
                word_start = i
            word.append(command[i + 1])
            in_word = word_quoted = True
            i += 1
        elif c in "()":
            raise _Unclear("a subshell runs commands that can't be checked one by one")
        elif c == "<":
            raise _Unclear("a here-document or process substitution runs text that can't be checked first"
                           if command.startswith(("<<", "<("), i) else "redirection reads a file")
        elif c == ">" or command.startswith("&>", i):
            if c == ">" and in_word and not word_quoted and "".join(word).isdigit():
                fd, start = "".join(word), word_start
                word, in_word = [], False
            else:
                end_word(i)
                fd, start = "", i
            if c == "&":
                fd, i = "&", i + 1
            open_redirect(fd, start)
            redirect = commands[-1].redirs[-1]
            i += 1
            for op in (">", "&", "|"):
                if command.startswith(op, i):
                    redirect.op = ">>" if op == ">" else ">" + op
                    i += 1
                    break
            continue
        elif c in "{}":
            raise _Unclear("braces expand into words that can't be checked first")
        elif c.isspace() and c != "\n":
            end_word(i)
        elif command.startswith(_SEPARATORS, i):
            end_word(i)
            if commands[-1].redirs and commands[-1].redirs[-1].target is None:
                raise _Unclear("a redirect has nothing to write to")
            sep = next(s for s in sorted(_SEPARATORS, key=len, reverse=True) if command.startswith(s, i))
            commands.append(_Simple())
            i += len(sep)
            continue
        else:
            if not in_word:
                word_start = i
            word.append(c)
            if c in "*?[":
                word_glob = True
            in_word = True
        i += 1
    if quote:
        raise _Unclear("a quote is never closed")
    end_word(n)
    if commands[-1].redirs and commands[-1].redirs[-1].target is None:
        raise _Unclear("a redirect has nothing to write to")
    kept = [c for c in commands if c.argv or c.redirs]
    blank = list(command)
    for c in kept:
        for r in c.redirs:
            if r.harmless:
                blank[r.start:r.end] = " " * (r.end - r.start)
    return Parsed(kept, "".join(blank), len(kept) > 1)


# These commands have no file-valued options in the subset accepted here. Unknown
# flags ask rather than guessing whether an attached suffix is another input path.
_PLAIN_FLAGS = {
    "cat": frozenset("Abenstuv"), "head": frozenset("qv"), "tail": frozenset("FfqrRv"),
    "wc": frozenset("clmwL"), "ls": frozenset("ABCFGHILOPRSTUWX@abcdefghiklmnopqrstuvwxy1%,"),
    "stat": frozenset("FHLlnqrsx"), "du": frozenset("AHLPacghklmnrsx"),
    "df": frozenset("HPIabcghiklmnY,"),
}

# Format strings, masks, type filters and numeric limits do not name input files.
_PLAIN_VALUES = {"ls": frozenset("D"), "stat": frozenset("ft"),
                 "du": frozenset("BdIt"), "df": frozenset("T")}


def _find_roots(args: list[str]) -> list[str]:
    roots, i = [], 0
    # BSD find's getopt-style leading flags precede both roots and expression.
    while i < len(args):
        a = args[i]
        if a == "--":
            i += 1
            break
        if not a.startswith("-") or a == "-":
            break
        if not all(c in "EHLPXdsxf" for c in a[1:].split("f", 1)[0]):
            break                       # the expression has begun
        i += 1
        for j, flag in enumerate(a[1:], 2):
            if flag == "f":
                value = a[j:]
                if not value:
                    if i == len(args):
                        raise _Unclear("find -f has no path")
                    value, i = args[i], i + 1
                roots.append(value)
                break
            if flag not in "EHLPXdsx":
                raise _Unclear("find has an unrecognised leading option")
    for a in args[i:]:
        if a.startswith("-") or a in ("(", "!", ")"):
            break
        roots.append(a)
    # No attached path-bearing extension is interpreted as an expression option.
    if any(a.startswith("-") and ("=" in a or "/" in a or "~" in a) for a in args[i:]):
        raise _Unclear("find has an unrecognised attached option value")
    return roots or ["."]


def _git_paths(args: list[str], globs: set[int]) -> list[str] | str:
    """Consume known non-path values; check every other operand, including REV:path.
    A ref may be mistaken for a local filename. That conservative check is intentional.
    """
    if not args or args[0] not in GIT_READ_ONLY:
        return "only git status, log, diff, show and branch run without asking"
    if args[0] == "branch" and any(a not in _GIT_BRANCH_FLAGS for a in args[1:]):
        return "git branch with a name or option can create, rename or delete a branch"
    flags = _GIT_BRANCH_FLAGS | {
        "--oneline", "--short", "--porcelain", "--long", "--graph", "--all", "--patch", "--no-patch",
        "--stat", "--shortstat", "--numstat", "--summary", "--name-only", "--name-status",
        "--abbrev-commit", "--no-abbrev-commit", "--decorate", "--no-decorate", "--relative",
        "--cached", "--staged", "--check", "-p", "-s", "-u", "-w", "-b", "-M", "-z", "-sb",
    }
    text_values = {"--format", "--pretty", "--since", "--until", "--author", "--grep"}
    paths, options, i = [], True, 1
    while i < len(args):
        a, index = args[i], i + 1
        i += 1
        if options and a == "--":
            options = False
            continue
        if options and a.startswith("-"):
            if index in globs:
                raise _Unclear("a glob can change git options")
            if any(a.startswith(r) for r in _GIT_REFUSED) or a.startswith((
                    "-c", "-C", "--config-env", "--git-dir", "--work-tree")):
                return "this git option changes configuration, writes a file or runs another program"
            if a in flags or re.fullmatch(r"-[0-9]+", a):
                continue
            name, eq, value = a.partition("=")
            if name in text_values:
                if not eq:
                    if i == len(args) or i + 1 in globs:
                        raise _Unclear("a git option has no fixed value")
                    i += 1
                continue
            count = re.fullmatch(r"-(n|U)([0-9]*)", a)
            if count:
                value = count[2]
                if not value:
                    if i == len(args) or i + 1 in globs:
                        raise _Unclear("a git count has no fixed value")
                    value, i = args[i], i + 1
                if not value.isascii() or not value.isdigit():
                    raise _Unclear("a git count is not a plain number")
                continue
            raise _Unclear("git has an unrecognised option or attached value")
        # Git's pathspec magic can change the root and matching semantics.
        # Reject it, including a magic path embedded in a revision expression.
        if not options:
            path = a
        elif re.match(r":[0-3]:", a):
            path = a[3:]             # index-stage spelling, e.g. :0:.env
        elif a.startswith(":") and not a.startswith(":("):
            path = a[1:]
        else:
            path = a.split(":", 1)[1] if ":" in a and not a.startswith(":(") else a
        if path.startswith((":", "(")) or a.startswith(":(") or not path:
            raise _Unclear("git pathspec magic or an empty tree path cannot be checked safely")
        paths.append(a)
        if path != a:
            paths.append(path)
    return paths


def _in_git_worktree(cwd: Path) -> bool:
    # Metadata only, no git process/config/hooks. A .git file also covers linked worktrees.
    return any((parent / ".git").is_dir() or (parent / ".git").is_file()
               for parent in (cwd, *cwd.parents))


def _find_references(args: list[str]) -> list[str]:
    paths, i = [], 0
    while i < len(args):
        a = args[i]
        i += 1
        if a in ("-newer", "-anewer", "-cnewer") or re.fullmatch(r"-newer[A-Za-z]{2}", a):
            if i == len(args) or args[i].startswith("-"):
                raise _Unclear("a find reference test has no fixed path")
            paths.append(args[i])
            i += 1
    return paths


def _paths(argv: list[str], globs: set[int] | None = None) -> list[str] | str:
    """Read path operands without discarding dash-prefixed names after `--`."""
    prog, args = argv[0], argv[1:]
    globs = globs or set()
    if prog in ("echo", "pwd", "which"):
        return []
    if prog == "date":
        # -r accepts either seconds or a file on BSD. Ask for both spellings,
        # including clusters, instead of guessing which interpretation date uses.
        for a in args:
            if a.startswith("+"):
                continue
            if a.startswith("-") and a != "-" and all(c in "jnRu" for c in a[1:]):
                continue
            raise _Unclear("date has a file, clock-setting or unrecognised option")
        return []
    if prog == "find":
        if globs:
            raise _Unclear("a glob can change find's roots or expression")
        roots = _find_roots(args)
        if any(a in _FIND_REFUSED for a in args):
            return "find with -exec, -delete, -ok or -fprint runs a program or changes files"
        return roots
    if prog == "git":
        return _git_paths(args, globs)
    positional, options, i = [], True, 0
    while i < len(args):
        a, index = args[i], i + 1
        i += 1
        if options and a == "--":
            options = False
            continue
        if not options or not a.startswith("-") or a == "-":
            positional.append(a)
            continue
        if index in globs:
            raise _Unclear("a glob can change command options")
        if prog in ("ls", "du", "df") and (a == "--si" and prog != "ls"
                                           or prog == "ls" and (a == "--color" or a.startswith("--color="))):
            continue
        if prog in ("head", "tail"):
            if a[1:].isdigit():
                continue
            long_count = re.fullmatch(r"--(?:lines|bytes)=([+-]?[0-9]+)", a)
            if long_count:
                continue
            # A count can follow harmless flags in a cluster: -qn5, -fn5.
            count = re.fullmatch(r"-([" + "".join(sorted(_PLAIN_FLAGS[prog])) + r"]*)(?:n|c)(.*)", a)
            if count:
                value = count[2]
                if not value:
                    if i == len(args) or i + 1 in globs:
                        raise _Unclear("a line/byte count has no fixed value")
                    value, i = args[i], i + 1
                if not re.fullmatch(r"[+-]?[0-9]+", value):
                    raise _Unclear("a line/byte count is not a plain number")
                continue
        if a.startswith("--"):
            raise _Unclear(f"{prog} has an unrecognised option or attached value")
        for j, flag in enumerate(a[1:], 2):
            if flag in _PLAIN_VALUES.get(prog, ()):
                if not a[j:]:
                    if i == len(args):
                        raise _Unclear("a metadata option has no value")
                    if i + 1 in globs:
                        raise _Unclear("a glob can change a metadata option's value")
                    i += 1
                break
            if flag not in _PLAIN_FLAGS.get(prog, ()):
                raise _Unclear(f"{prog} has an unrecognised option or attached value")
    return positional or ["."]


@dataclass
class _Reader:
    paths: list[str] = field(default_factory=list)
    reads: list[str] = field(default_factory=list)
    recursive: bool = False
    follow: bool = False
    names_only: bool = False
    refused: str = ""


# Exact, deliberately bounded option grammar, not a guess from the first bare word.
# Unknown options (including BSD's accepted long prefixes) must ask. Values are consumed
# in attached, =value and separate forms before deciding which word is the pattern/root.
# BSD grep's color/colour/context accept optional values only with '='. Every
# accepted rg 14 long value option requires its argument, including color/context.
_READER_LONG_FLAGS = {
    "grep": frozenset("extended-regexp fixed-strings basic-regexp ignore-case word-regexp "
                      "line-regexp null-data no-messages invert-match version help byte-offset line-number "
                      "line-buffered with-filename no-filename only-matching quiet silent "
                      "text recursive count files-with-matches "
                      "files-without-match null".split()),
    "file": frozenset("brief checking-printout no-dereference dereference mime mime-type mime-encoding "
                      "keep-going list no-buffer no-pad raw special-files version print0 extension help".split()),
    "rg": frozenset("hidden no-hidden follow no-follow unrestricted text binary search-zip crlf null-data "
                    "ignore-case case-sensitive smart-case fixed-strings word-regexp line-regexp multiline "
                    "multiline-dotall no-unicode unicode pcre2 no-pcre2 line-number no-line-number "
                    "column no-column with-filename no-filename heading no-heading count count-matches "
                    "files-with-matches files-without-match only-matching quiet no-messages messages "
                    "no-ignore no-ignore-vcs no-ignore-parent no-ignore-global no-ignore-dot no-ignore-files "
                    "no-config files null stats debug trace help version vimgrep json trim passthru "
                    "line-buffered block-buffered mmap no-mmap byte-offset invert-match".split()),
}
_READER_LONG_OPTIONAL = {"grep": frozenset({"color", "colour", "context"}),
                         "rg": frozenset(), "file": frozenset()}
_READER_LONG_VALUES = {
    "grep": frozenset("regexp file max-count after-context before-context directories devices "
                      "binary-files exclude include exclude-dir label".split()),
    "file": frozenset("magic-file files-from exclude exclude-quiet separator parameter".split()),
    "rg": frozenset("regexp file max-count after-context before-context context glob iglob type type-not "
                    "type-add type-clear threads sort sortr max-depth max-filesize encoding color colors "
                    "replace path-separator ignore-file pre pre-glob hostname-bin engine regex-size-limit "
                    "dfa-size-limit max-columns field-match-separator field-context-separator".split()),
}
_READER_SHORT_FLAGS = {"file": frozenset("bcdDEhiIkLlNnrsv0"), "grep": frozenset("EFGPinwxyvVbHhILlqRsScrUuazoZN"),
                       "rg": frozenset("0123456789iIsSwxFvznNHlLqcuUaobPrpT.")}
_READER_SHORT_VALUES = {"file": frozenset("mMfeFP"), "grep": frozenset("efmABCdD"), "rg": frozenset("efmABCgGtTjEMr")}


def _reader(simple: _Simple) -> _Reader:
    prog, args = simple.argv[0], simple.argv[1:]
    plan = _Reader(recursive=prog == "rg")
    positional: list[tuple[int, str]] = []
    explicit, options, i = False, True, 0

    def option(name: str, value: str | None) -> None:
        nonlocal explicit
        if prog == "file":
            if name in ("-m", "-M", "--magic-file"):
                plan.reads.extend(value.split(os.pathsep))
            if name in ("-f", "--files-from"):
                plan.reads.append(value)
                plan.refused = "file with a filename list reads additional unchecked paths"
            return
        if name in ("-e", "--regexp", "-f", "--file"):
            explicit = True
        if name in ("-f", "--file", "--ignore-file", "--pre-glob", "--exclude-from"):
            plan.reads.append(value)
        if name in ("--pre", "--hostname-bin"):
            plan.refused = f"{prog} with {name} runs another program"
        if name in ("-r", "-R", "--recursive", "--dereference-recursive") and prog == "grep":
            plan.recursive = True
        if (prog == "grep" and name in ("-R", "-S", "--dereference-recursive")) or \
                (prog == "rg" and name in ("-L", "--follow")):
            plan.follow = True
        if prog == "grep" and name in ("-d", "--directories"):
            if value not in ("read", "skip", "recurse"):
                raise _Unclear("grep has an unknown directory mode")
            plan.recursive |= value == "recurse"
        if prog == "rg" and name == "--files":
            plan.names_only = True

    while i < len(args):
        a, index = args[i], i + 1
        i += 1
        if options and a == "--":
            options = False
            continue
        if options and a.startswith("-") and a != "-":
            if index in simple.globs:
                raise _Unclear("a glob can change search options")
            if a.startswith("--"):
                name, eq, value = a[2:].partition("=")
                if name in _READER_LONG_OPTIONAL[prog]:
                    option("--" + name, value if eq else None)
                    continue
                if name in _READER_LONG_FLAGS[prog] and not eq:
                    option("--" + name, None)
                    continue
                if name not in _READER_LONG_VALUES[prog]:
                    raise _Unclear(f"{prog} has an unrecognised or abbreviated option")
                if not eq:
                    if i == len(args):
                        raise _Unclear("a search option has no value")
                    if i + 1 in simple.globs:
                        raise _Unclear("a glob can change a search option's value")
                    value, i = args[i], i + 1
                option("--" + name, value)
            else:
                if prog == "grep" and a[1:].isascii() and a[1:].isdigit():
                    continue
                for j, flag in enumerate(a[1:], 2):
                    if flag in _READER_SHORT_VALUES[prog]:
                        value = a[j:]
                        if not value:
                            if i == len(args):
                                raise _Unclear("a search option has no value")
                            if i + 1 in simple.globs:
                                raise _Unclear("a glob can change a search option's value")
                            value, i = args[i], i + 1
                        option("-" + flag, value)
                        break
                    if flag not in _READER_SHORT_FLAGS[prog]:
                        raise _Unclear(f"{prog} has an unrecognised short option")
                    option("-" + flag, None)
        else:
            positional.append((index, a))
    if prog != "file" and not explicit and not plan.names_only and positional:
        index, _ = positional.pop(0)
        if index in simple.globs:
            raise _Unclear("a glob can change the search pattern and roots")
    plan.paths = [a for _, a in positional] or ["."]
    return plan


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (ValueError, OSError, RuntimeError):
        return False


_WRITES = "run a compound command that writes to a file", "run a command that writes to a file"


_MAX_GLOB_MATCHES = 1024
_SHELL_SCAN_LIMIT = 4096
_SHELL_SCAN_SECONDS = 0.75
_SHELL_TOTAL_SCAN_SECONDS = 1.5


def _shell_paths(raw: str, cwd: Path) -> list[Path]:
    """Expand a path glob using directory entries only, within a fixed inspection budget.
    Quotes are already removed by parse; inspecting quoted globs too is conservative.
    """
    if "{" in raw or "}" in raw:
        raise _Unclear("braces in a path cannot be expanded safely")
    if raw.startswith("~") and raw != "~" and not raw.startswith("~/"):
        raise _Unclear("this tilde expansion cannot be resolved safely")
    # fnmatch's bracket grammar is not the shell's (POSIX classes, ^/! and escapes).
    # Even simple brackets ask until we implement the complete shell grammar.
    if any(c in raw for c in "[]\\"):
        raise _Unclear("brackets or escapes in a path cannot be expanded safely")
    p = Path(os.path.expanduser(raw))
    p = p if p.is_absolute() else cwd / p
    if not any(c in str(p) for c in "*?["):
        return [p]
    candidates = [Path(p.anchor)]
    inspected = 0
    try:
        for part in p.parts[1:]:
            if not any(c in part for c in "*?["):
                candidates = [item / part for item in candidates]
                continue
            if "**" in part:
                raise _Unclear("a recursive glob cannot be expanded safely")
            # bash 3.2's .* includes . and ..; scandir omits both. Ask rather than
            # silently losing a path that can step back into a private directory.
            if part.startswith(".") and any(fnmatch.fnmatchcase(dot, part) for dot in (".", "..")):
                raise _Unclear("a dot glob may expand to the current or parent directory")
            matches = []
            for folder in candidates:
                try:
                    with os.scandir(folder) as entries:
                        for entry in entries:
                            inspected += 1
                            if inspected > _SHELL_SCAN_LIMIT:
                                raise _Unclear("a path glob needs too many directory entries")
                            if entry.name.startswith(".") and not part.startswith("."):
                                continue
                            if fnmatch.fnmatchcase(entry.name, part):
                                if entry.name.startswith("-"):
                                    raise _Unclear("a path glob may introduce command options")
                                matches.append(folder / entry.name)
                                if len(matches) > _MAX_GLOB_MATCHES:
                                    raise _Unclear("a path glob has too many matches")
                except (FileNotFoundError, NotADirectoryError):
                    continue
            candidates = matches
        candidates = [p for p in candidates if os.path.lexists(p)]
    except (OSError, RuntimeError, ValueError) as e:
        raise _Unclear("a path glob could not be inspected safely") from e
    if not candidates:
        raise _Unclear("a path glob has no matches")
    return candidates


class _OutsidePath(Exception):
    """A recursive reader would follow a target outside the working folder."""


def _recursive_private(path: Path, workdir: Path, follow: bool = True, deadline: float | None = None,
                       names_only: bool = False) -> str | None:
    # Also cover private names anywhere (.ssh, .env, keys), including directory links a
    # recursive reader may follow. Cache private roots once per traversal: resolving them
    # per entry makes ordinary repos exceed a 4096-entry cap. Do not prune .git,
    # node_modules, hidden entries or ignored content: any can contain private names.
    deadline = deadline if deadline is not None else time.monotonic() + _SHELL_SCAN_SECONDS
    roots = [(Path.home() / rel, f"~/{rel}") for rel in _PRIVATE_UNDER_HOME] + _relocated_private()
    roots = [(p, label) for root, label in roots for p in _private_spellings(root)]
    why = None if names_only else (private_path(path, workdir=workdir) or _private_ancestor(path, roots))
    if why:
        return why
    if not _inside(path, workdir):
        raise _OutsidePath(str(path))
    root_parts = list(dict.fromkeys((_fold_parts(p), label) for p, label in roots))

    def classify(p: Path) -> str | None:
        # p is absolute and resolved through its parent; only links need resolve().
        folded = _fold_parts(p)
        for prefix, label in root_parts:
            if folded[:len(prefix)] == prefix:
                return label
        for part in folded:
            if part in _PRIVATE_DIRS:
                return part
        if _names_job_record(p):
            return "a Benji job's record"
        for pattern in _PRIVATE_NAMES:
            if fnmatch.fnmatchcase(folded[-1], pattern):
                return pattern
        return None

    try:
        pending, visited = [path.resolve()], set()
        while pending:
            if time.monotonic() >= deadline:
                raise _Unclear("a recursive reader exceeded the metadata inspection time budget")
            folder = pending.pop()
            if folder in visited:
                continue
            visited.add(folder)
            try:
                with os.scandir(folder) as entries:
                    for entry in entries:
                        if time.monotonic() >= deadline:
                            raise _Unclear("a recursive reader exceeded the metadata inspection time budget")
                        is_link = entry.is_symlink()
                        # grep -r and default rg skip directory links discovered in a tree.
                        # Command-line roots were resolved above and are always inspected.
                        is_dir = entry.is_dir()
                        if is_link and is_dir and not follow:
                            continue
                        p = folder / entry.name
                        why = None if names_only else classify(p)
                        if is_link and not names_only:
                            why = why or private_path(p, workdir=workdir) or _private_ancestor(p, roots)
                        if why:
                            return why
                        if is_link and not _inside(p, workdir):
                            raise _OutsidePath(str(p))
                        # A nested older Benji folder needs the same signature check as private_path.
                        if not names_only and entry.name.casefold() in LEGACY_HOME_NAMES:
                            why = private_path(p, workdir=workdir)
                            if why:
                                return why
                        if is_dir:
                            pending.append(p.resolve() if is_link else p)
            except (FileNotFoundError, NotADirectoryError):
                continue
    except (OSError, RuntimeError, ValueError) as e:
        raise _Unclear("a recursive reader's paths could not be inspected safely") from e
    return None


def shell_check(command: str, workdir: Path, cwd: Path | None = None) -> tuple[str, str] | None:
    """Fail closed even if filesystem inspection or an unforeseen checker error fails."""
    try:
        if len(command) > MAX_SHELL_CHARS:
            raise _Unclear(f"it is over {MAX_SHELL_CHARS} characters long")
        if "\0" in command or any(0xD800 <= ord(c) <= 0xDFFF for c in command):
            raise _Unclear("a NUL or lone surrogate cannot be passed safely to the shell")
        return _shell_check(command, workdir, cwd)
    except _Unclear as e:
        return f"run a command that Benji can't check first ({e})", "shell_unclear"
    except Exception:
        # Do not include exception text: an unexpected filesystem error may expose data.
        return "run a command that Benji couldn't check safely", "shell_unclear"


def _shell_check(command: str, workdir: Path, cwd: Path | None = None) -> tuple[str, str] | None:
    """None when `command` may run without a card: every simple command in it is read-only (joined
    by ; && || |), the only redirects are to /dev/null or `2>&1`, and every path it names is inside
    `workdir`. Otherwise (what it would do, for the card, naming what was seen; a reason code for
    the audit log, audit.GATE_CODES). The caller checks the destructive and sensitive patterns
    first, for their own wording."""
    total_deadline = time.monotonic() + _SHELL_TOTAL_SCAN_SECONDS
    cwd = cwd or workdir
    if not _inside(cwd, workdir):
        return f"run a command outside the working folder (in {cwd})", "shell_cwd_outside"
    try:
        parsed = parse(command)
    except _Unclear as e:
        return f"run a command that Benji can't check first ({e})", "shell_unclear"
    for simple in parsed.commands:
        if any(not r.harmless for r in simple.redirs):
            return _WRITES[0 if parsed.compound else 1], "shell_writes_file"
        if not simple.argv:
            continue
        argv = simple.argv
        prog = argv[0]
        if prog not in SHELL_READ_ONLY:
            return f"run `{prog}`, a command that is not on the read-only list", "shell_not_listed"
        try:
            reader = _reader(simple) if prog in ("grep", "rg", "file") else None
            paths = reader.paths if reader else _paths(argv, simple.globs)
            reference_paths = _find_references(argv[1:]) if prog == "find" else []
        except _Unclear as e:
            return f"run a command that Benji can't check first ({e})", "shell_unclear"
        if reader and reader.refused and prog != "file":
            return f"run `{prog}`: {reader.refused}", "shell_args"
        recursive = reader.recursive if reader else False
        # find's action is still refused below; inspect its traversal roots first so a
        # private reader (-exec, or a pipe to xargs) gets the same private-path card.
        if prog == "find":
            recursive = any(a in ("-exec", "-execdir", "-ok", "-okdir") for a in argv[1:]) or any(
                c.argv[:1] == ["xargs"] for c in parsed.commands)
        scan_paths = paths
        if isinstance(paths, str):
            if prog != "find" or not recursive:
                return f"run `{' '.join(argv[:2])}`: {paths}", "shell_args"
            scan_paths = _find_roots(argv[1:])
        try:
            expanded = [(raw, p) for raw in scan_paths for p in _shell_paths(raw, cwd)]
            reads = [(raw, p) for raw in (reader.reads if reader else reference_paths) for p in _shell_paths(raw, cwd)]
            # Accepted limit: ls/find/du and rg --files only list private file NAMES.
            # File-valued search options still read content and are checked independently.
            names_only = prog in ("ls", "du", "df", "stat") or (prog == "find" and not recursive) or \
                (reader is not None and reader.names_only)
            deadline = min(time.monotonic() + _SHELL_SCAN_SECONDS, total_deadline)
            for raw, p in expanded:
                if recursive and (not names_only or (reader and reader.follow)):
                    if time.monotonic() >= total_deadline:
                        raise _Unclear("recursive readers exceeded the command inspection time budget")
                    why = _recursive_private(p, workdir, reader.follow if reader else True, deadline, names_only)
                    if time.monotonic() >= total_deadline:
                        raise _Unclear("recursive readers exceeded the command inspection time budget")
                else:
                    why = None if names_only else private_path(p, workdir=workdir)
                if why:
                    return f"read private files ({why}) with `{prog}`", "shell_private_path"
            for raw, p in reads:
                why = private_path(p, workdir=workdir)
                if why:
                    return f"read private files ({why}) with `{prog}`", "shell_private_path"
        except _OutsidePath as e:
            return f"read outside the working folder ({e}) with `{prog}`", "shell_outside_path"
        except _Unclear as e:
            return f"run a command that Benji can't check first ({e})", "shell_unclear"
        if isinstance(paths, str):
            return f"run `{' '.join(argv[:2])}`: {paths}", "shell_args"
        for raw, p in expanded + reads:
            if not _inside(p, workdir):
                return f"read outside the working folder ({raw}) with `{prog}`", "shell_outside_path"
        if prog == "git" and argv[1:2] == ["diff"] and paths and not _in_git_worktree(cwd):
            raise _Unclear("git diff outside a worktree may implicitly read files with --no-index")
        if reader and reader.refused:
            return f"run `{prog}`: {reader.refused}", "shell_args"
    return None


def shell_review(command: str, workdir: Path, cwd: Path | None = None) -> str | None:
    """shell_check's reason for the card, or None when the command may run without one."""
    found = shell_check(command, workdir, cwd)
    return found[0] if found else None


# What in a command's text makes it asked before anything else is looked at, each with what the
# card says it does and which of them really delete, overwrite or change permissions (only those
# are "potentially destructive"). (pattern, programs that confirm it, what it does, destructive).
_DANGER = [
    (r"\brm\b", ("rm",), "deletes files", True),
    (r"\brmdir\b", ("rmdir",), "deletes folders", True),
    (r"\bmv\b", ("mv",), "moves files, and can overwrite one", True),
    (r"\bdd\b", ("dd",), "writes straight to a file or disk", True),
    (r"\bmkfs\b", ("mkfs",), "erases a disk", True),
    (r"\bshred\b", ("shred",), "destroys files", True),
    (r"\bsudo\b", ("sudo", "doas"), "uses administrator rights", False),
    (r"\bchmod\b\s+-R", ("chmod",), "changes permissions", True),
    (r"\bchown\b", ("chown",), "changes who owns files", True),
    (r"\bkill(all)?\b", ("kill", "killall"), "stops running programs", False),
    (r"\bshutdown\b", ("shutdown",), "shuts the Mac down", False),
    (r"\breboot\b", ("reboot",), "restarts the Mac", False),
    (r"\bgit\s+push\b", ("git",), "sends commits to a remote", False),
    (r"\bgit\s+reset\s+--hard", ("git",), "throws away changes in a repository", True),
    (r"\bgit\s+clean\b", ("git",), "deletes untracked files", True),
    (r"\bnpm\s+publish\b", ("npm",), "publishes a package", False),
    (r"\bcurl\b.*\|\s*(sh|bash|zsh)\b", ("curl",), "downloads a script and runs it", False),
    (r">\s*\S", (), "writes to a file", False),
    (r">>\s*\S", (), "writes to a file", False),
]
_DANGER_RE = [(re.compile(p), progs, what, destructive) for p, progs, what, destructive in _DANGER]
_WRAPPERS = frozenset({"xargs", "env", "sudo", "doas", "time", "nice", "nohup", "command", "exec",
                       "builtin", "timeout", "watch"})


def _program(word: str) -> str:
    return word.rsplit("/", 1)[-1]


def shell_danger(command: str) -> tuple[str, str] | None:
    """(what the card says, audit code) when `command` has text that is asked before anything else:
    it deletes, overwrites or changes permissions (shell_destructive, "a potentially destructive
    shell command"), does something else that needs a yes (shell_system_action), or writes to a file
    with `>` (shell_writes_file). A harmless redirect (`2>/dev/null`, `2>&1`) is not looked at. A
    word such as `rm` that is only an argument (`grep rm notes`) still asks, but is called a
    command that contains it, not a deletion. None: nothing in the text, the other checks go on."""
    if len(command) > MAX_SHELL_CHARS:
        return "run a command too long for Benji to check first", "shell_unclear"
    try:
        parsed = parse(command)
    except _Unclear:
        parsed, text = None, command
    else:
        text = parsed.scrubbed
    for rx, progs, what, destructive in _DANGER_RE:
        found = rx.search(text)
        if not found:
            continue
        if not progs:           # a redirect
            if parsed is not None and any(not r.harmless for c in parsed.commands for r in c.redirs):
                return _WRITES[0 if parsed.compound else 1], "shell_writes_file"
            return "run a command with a `>` in it, which can write a file", "shell_writes_file"
        spoken = {_program(w) for c in (parsed.commands if parsed else [])
                  for w in c.argv[:2 if c.argv[:1] and _program(c.argv[0]) in _WRAPPERS else 1]}
        if parsed is not None and not spoken & set(progs):
            word = " ".join(found.group(0).split())
            return f"run a command that contains `{word}` (a command that {what})", "shell_system_action"
        if destructive:
            return "run a potentially destructive shell command", "shell_destructive"
        return f"run a command that {what}", "shell_system_action"
    return None


# Environment variables tool processes never see: the model's and search keys, and Benji's own
# settings (BENJI_*, plus CHILLY_* and PAL_*, older names for the same settings that may still be set).
_KEY_VARS = frozenset({"ANTHROPIC_API_KEY", "OPENAI_API_KEY", "BRAVE_API_KEY", "SERPAPI_KEY",
                       "DEEPSEEK_API_KEY", "ZAI_API_KEY", "ZHIPUAI_API_KEY", "MOONSHOT_API_KEY",
                       "DASHSCOPE_API_KEY"})


def tool_env(environ: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ if environ is None else environ)
    return {k: v for k, v in env.items()
            if k not in _KEY_VARS and not k.endswith("_API_KEY")
            and not k.startswith(("BENJI_", "CHILLY_", "PAL_"))}


# --- private paths --------------------------------------------------------------------------

# Under the home folder: never read by a tool, whatever the user or a page says.
# `.chilly.env` and `.pal.env` are older names of Benji's key file, refused because they may still
# hold keys.
_PRIVATE_UNDER_HOME = (
    ".ssh", ".aws", ".gnupg", ".benji.env", ".chilly.env", ".pal.env",
    ".config/git/credentials", ".config/gh", ".docker/config.json", ".npmrc", ".pypirc",
    ".kube/config", ".config/gcloud", ".azure",
    ".config/op", ".cargo/credentials", ".cargo/credentials.toml", ".terraform.d/credentials.tfrc.json",
    "Library/Keychains", "Library/Messages", "Library/Mail", "Library/Cookies",
    "Library/Application Support/Google/Chrome", "Library/Application Support/Google/Chrome Beta",
    "Library/Application Support/Google/Chrome Canary", "Library/Application Support/Google/Chrome Dev",
    "Library/Application Support/Google/Chrome for Testing", "Library/Application Support/Chromium",
    "Library/Application Support/Firefox/Profiles",
    "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge",
    "Library/Application Support/Microsoft Edge Beta", "Library/Application Support/Microsoft Edge Dev",
    "Library/Application Support/Microsoft Edge Canary", "Library/Application Support/gh",
    "Library/Application Support/Arc", "Library/Safari", "Library/Containers/com.apple.Safari",
    "Library/Containers/com.apple.SafariTechnologyPreview",
    # Benji's own support folder: the browser link's token is kept here. `Chilly` is an older name of
    # the same folder and can still hold an old token until the app has cleared it.
    "Library/Application Support/Benji", "Library/Application Support/Chilly",
    # A half-made copy of the store, while a move that couldn't be a rename is under way.
    ".benji.incoming",
)
# Anywhere: a folder or file with one of these names.
_PRIVATE_DIRS = frozenset({".ssh", ".gnupg", ".aws"})


def _env_private_globs() -> tuple[str, ...]:
    """Portable exclude globs for .env.*, except the three public template names.
    Split at each template prefix so grep, rg and fnmatch use exactly the same list.
    """
    public = (".env.example", ".env.sample", ".env.template")
    patterns, pending = [], [".env."]
    while pending:
        prefix = pending.pop()
        if prefix not in public:
            patterns.append(prefix)
        next_chars = sorted({name[len(prefix)] for name in public
                             if name.startswith(prefix) and len(name) > len(prefix)})
        if next_chars:
            patterns.append(prefix + "[!" + "".join(next_chars) + "]*")
            pending.extend(prefix + char for char in next_chars)
        else:
            patterns.append(prefix + "?*")
    return tuple(patterns)


_PRIVATE_NAMES = (".benji.env", ".chilly.env", ".pal.env", ".env", ".envrc", ".npmrc", ".pypirc",
                  ".netrc", ".git-credentials", "*.pem", "*.key", "*.p12", "*.pfx", "id_rsa*",
                  "id_ed25519*", "id_ecdsa*", "id_dsa*", *_env_private_globs())


# Older names of Benji's data folder (`~/.chilly`, `~/chilly`, `~/pal`). Benji doesn't use them, but
# one can still hold what it kept there: answers, logs, policy, memory, jobs. So each is refused like
# any private place, but only while it looks like Benji's (it holds one of the files below; a plain
# folder of someone's own that is called ~/chilly, such as a clone of the code, is not touched), and
# not when it is the working folder itself (BENJI_WORKDIR=~/chilly is allowed).
LEGACY_HOME_NAMES = (".chilly", "chilly", "pal")
_LEGACY_SIGNS = ("answers.jsonl", "policy.json", "events.jsonl", "engine.log", "memory.jsonl", "jobs",
                 "conversations", "voice.log", "latency.jsonl", "usage.jsonl", "output")


def _legacy_home(folder: Path) -> bool:
    try:
        return any(os.path.lexists(folder / sign) for sign in _LEGACY_SIGNS)
    except OSError:
        return False


# A job's record and schedule, beside its folder: they say what the job may do, so no tool reads or writes them.
_JOB_RECORD = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\.[a-z]+)?\.json(\.tmp)?")


def _names_job_record(p: Path) -> bool:
    return p.parent.name.casefold() == "jobs" and _JOB_RECORD.fullmatch(p.name.casefold()) is not None


def is_job_record(path: Path) -> bool:
    """A job's record or schedule, as written or through a link. Writing one is refused outright, not
    asked: what a job may do is changed only by the engine, on the user's cards."""
    try:
        return _names_job_record(Path(path)) or _names_job_record(Path(path).resolve())
    except OSError:
        return _names_job_record(Path(path))


def _private_spellings(path: Path) -> tuple[Path, ...]:
    """Lexical and symlink-resolved spellings, with the macOS data-volume alias removed."""
    p = Path(os.path.expanduser(str(path)))
    p = p if p.is_absolute() else Path.cwd() / p
    seen = [p]
    try:
        seen.append(p.resolve())
    except (OSError, RuntimeError):
        pass
    out = []
    for item in seen:
        parts = item.parts
        if tuple(part.casefold() for part in parts[:4]) == ("/", "system", "volumes", "data"):
            item = Path("/", *parts[4:])
        out.append(item)
    return tuple(out)


def _relative_private(path: Path, root: Path) -> tuple[str, ...] | None:
    """Component boundaries, including a case-insensitive home prefix on macOS."""
    parts, prefix = path.parts, root.parts
    if _fold_parts(path)[:len(prefix)] == _fold_parts(root):
        return parts[len(prefix):]
    return None


def _fold_parts(path: Path) -> tuple[str, ...]:
    # APFS/HFS can open NFC and NFD spellings of the same name. Normalize both sides,
    # including the complete home prefix, before case-insensitive component comparison.
    return tuple(unicodedata.normalize("NFC", part).casefold() for part in path.parts)


def _relocated_private() -> list[tuple[Path, str]]:
    # Read at check time: the engine can change environments without re-importing the gate.
    roots = []
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        roots.extend((Path(xdg) / rel, f"$XDG_CONFIG_HOME/{rel}") for rel in ("git/credentials", "gh"))
    gh = os.environ.get("GH_CONFIG_DIR")
    if gh:
        roots.append((Path(gh), "$GH_CONFIG_DIR"))
    for var, suffix in (("DOCKER_CONFIG", "config.json"), ("CLOUDSDK_CONFIG", ""),
                        ("AWS_SHARED_CREDENTIALS_FILE", ""), ("AWS_CONFIG_FILE", "")):
        value = os.environ.get(var)
        if value:
            roots.append((Path(value) / suffix, f"${var}" + (f"/{suffix}" if suffix else "")))
    roots.extend((Path(value), "$KUBECONFIG") for value in os.environ.get("KUBECONFIG", "").split(os.pathsep)
                 if value)
    return roots


def private_path(path: Path, home: Path | None = None, workdir: Path | None = None) -> str | None:
    """What makes `path` private, checked as written and resolved so links cannot bypass it.
    `workdir` exempts an older Benji folder that is the working folder (see LEGACY_HOME_NAMES).
    Known limits: ordinary-name hard links, secrets in .gitconfig URLs, and other accounts' homes.
    """
    home = home or Path.home()
    roots = _private_spellings(home)
    relocated = [(p, label) for root, label in _relocated_private() for p in _private_spellings(root)]
    for p in _private_spellings(path):
        folded = _fold_parts(p)
        for root in roots:
            rel = _relative_private(p, root)
            if rel is None:
                continue
            rel_folded = "/".join(part.casefold() for part in rel)
            for private in _PRIVATE_UNDER_HOME:
                f = private.casefold()
                if rel_folded == f or rel_folded.startswith(f + "/"):
                    return f"~/{private}"
            if rel and rel[0].casefold() in LEGACY_HOME_NAMES and _legacy_home(root / rel[0]) \
                    and not (workdir is not None and (_inside(p, workdir) or _inside(workdir, root / rel[0]))):
                return f"~/{rel[0]}"
        for root, label in relocated:
            if _relative_private(p, root) is not None:
                return label
        for part in folded:
            if part in _PRIVATE_DIRS:
                return part
        name = folded[-1]
        if _names_job_record(p):
            return "a Benji job's record"
        for pattern in _PRIVATE_NAMES:
            if fnmatch.fnmatchcase(name, pattern):
                return pattern
    return None


def _private_ancestor(path: Path, roots: list[tuple[Path, str]]) -> str | None:
    """A recursive reader at this path would enter a known private home/config location."""
    for p in _private_spellings(path):
        for root, label in roots:
            if _relative_private(root, p) is not None:
                return label
    return None


# Globs search_files leaves out, so a search inside the working folder can't read them either.
SEARCH_EXCLUDES = _PRIVATE_NAMES


# --- web_fetch hosts and URLs ---------------------------------------------------------------

MAX_URL_TAIL = 200
_BASE64_RUN = re.compile(r"[A-Za-z0-9+/=_-]{32,}")
_HEX_RUN = re.compile(r"[0-9a-fA-F]{32,}")


def _blocked_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip.split("%", 1)[0])
    except ValueError:
        return True
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    return not addr.is_global or addr.is_multicast


def host_refusal(host: str | None, resolve=socket.getaddrinfo) -> str | None:
    """Why web_fetch must not reach `host`: a private, loopback, link-local or .local address,
    by name or by what it resolves to now. None: a public host."""
    if not host:
        return "the URL has no host"
    h = host.strip("[]").rstrip(".").casefold()
    if h == "localhost" or h.endswith((".localhost", ".local", ".internal", ".lan", ".home.arpa")):
        return f"{host} is on this Mac or its local network"
    try:
        ipaddress.ip_address(h.split("%", 1)[0])
        literal = True
    except ValueError:
        literal = False
    if literal:
        return f"{host} is a private or local address" if _blocked_ip(h) else None
    try:
        infos = resolve(h, None)
    except (OSError, UnicodeError):
        return None                     # it won't connect either; the request reports that
    if any(_blocked_ip(info[4][0]) for info in infos):
        return f"{host} points to a private or local address"
    return None


def url_review(url: str) -> str | None:
    """Why fetching `url` should be asked about first: its path and query are long, or carry what
    looks like encoded data (base64 or hex), the shape of a page being made to send something."""
    parts = urllib.parse.urlsplit(url)
    tail = parts.path + (("?" + parts.query) if parts.query else "")
    if len(tail) > MAX_URL_TAIL:
        return f"fetch a URL with a long path or query ({len(tail)} characters), which can carry data out"
    decoded = urllib.parse.unquote(tail)
    for run in _BASE64_RUN.findall(decoded):
        if re.search(r"[a-z]", run) and re.search(r"[A-Z]", run) and re.search(r"\d", run):
            return "fetch a URL that carries what looks like encoded data"
    if any(re.search(r"\d", r) and re.search(r"[a-fA-F]", r) for r in _HEX_RUN.findall(decoded)):
        return "fetch a URL that carries what looks like encoded data"
    return None


_HOST_IN_TEXT = re.compile(r"(?<![\w.-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,})(?![\w-])", re.I)


def hosts_in(text: str) -> set[str]:
    """The host names written in `text` (example.com, docs.python.org), lower-cased."""
    return {m.group(1).casefold().rstrip(".") for m in _HOST_IN_TEXT.finditer(text or "")}


def host_named(host: str, named: set[str]) -> bool:
    """`host` is one of `named`, or a subdomain of one (www.example.com for example.com)."""
    h = (host or "").casefold().rstrip(".")
    return any(h == n or h.endswith("." + n) for n in named)


# --- tainted turns --------------------------------------------------------------------------

# What a turn has taken in from outside the user, as a small closed set. `screen`: it looked
# at a screenshot. `web`: a page, a fetch or a search result. `browser`: a page in the user's
# Chrome. `file`: anything else that comes from outside: a file outside the working folder, an
# app's content (AppleScript output), the output of a command that isn't read-only, a skill that
# isn't verified. Every rule below is decided from this set, never from text the model wrote.
TAINT_SCREEN, TAINT_WEB, TAINT_BROWSER, TAINT_FILE = "screen", "web", "browser", "file"
TAINT_KINDS = (TAINT_SCREEN, TAINT_WEB, TAINT_BROWSER, TAINT_FILE)


def taint_kind(source: str) -> str:
    """Which of TAINT_KINDS a description of a source ("a web page", "the screen", …) is. Anything
    that isn't plainly the screen, a web page or the browser is a file: the strong kind."""
    s = (source or "").lower()
    if "web page" in s:
        return TAINT_WEB
    if "browser" in s:
        return TAINT_BROWSER
    if s.startswith("the screen"):
        return TAINT_SCREEN
    return TAINT_FILE


def taint_kinds_in(text: str) -> set[str]:
    """The kinds named in a stored description (a job record from before the set was kept): every
    kind it mentions; none mentioned, or text that is only a word of its own, is `file`."""
    s = (text or "").lower()
    if not s.strip():
        return set()
    found = {k for k, needle in ((TAINT_SCREEN, "screen"), (TAINT_WEB, "web page"), (TAINT_BROWSER, "browser")) if needle in s}
    return found or {TAINT_FILE}


def taint_string(kinds) -> str:
    """The set as one canonical string for the audit log and the app: kinds in TAINT_KINDS order
    joined by `+` ("screen+web"); empty for none."""
    return "+".join(k for k in TAINT_KINDS if k in set(kinds))


def screen_only(kinds) -> bool:
    """Tainted by the screen and nothing else: the one case that is weaker than a web page."""
    kinds = set(kinds)
    return bool(kinds) and kinds <= {TAINT_SCREEN}


# Tools that change something and that the gate otherwise lets through in some cases: once the
# turn is tainted, each asks. run_shell off the read-only list and mutating AppleScript are asked
# by their own rules already, tainted or not; an allowlisted read or a read-only script still runs.
TAINT_ASKED = frozenset({"write_file", "run_shortcut", "remember", "start_job"})
# Asked calls whose card says the turn has read outside content.
TAINT_NOTED = TAINT_ASKED | {"run_shell", "run_applescript", "web_fetch",
                             "browser_open", "browser_read", "schedule_job"}


def taint_code(name: str) -> str:
    """The audit code for a call that taint_reason made asked."""
    return "tainted_site" if name == "web_fetch" else "tainted_change"


def taint_reason(name: str, tool_input: dict, *, user_text: str, search_hosts: set[str],
                 taints=None) -> str | None:
    """For a turn that has read outside content: why this call, which the gate would otherwise
    let through, is asked. None: it may still go unasked (a read, a fetch of a host the user
    named or a search found, and, when the screen is the only source, starting a job: the job
    asks for each change itself). `taints` None means the sources aren't known: as strong as a web page."""
    if name == "start_job" and taints is not None and screen_only(taints):
        return None
    if name in TAINT_ASKED:
        return "it changes something"
    if name == "web_fetch":
        host = urllib.parse.urlsplit(str(tool_input.get("url", ""))).hostname or ""
        if host_named(host, hosts_in(user_text)) or host.casefold() in search_hosts:
            return None
        return "your message didn't name this site and no search this turn found it"
    return None


# --- remember only what the user said ----------------------------------------------------

_FILLER = frozenset({
    "a", "an", "the", "is", "are", "was", "were", "be", "been", "am", "i", "me", "my", "mine",
    "you", "your", "user", "users", "s", "they", "them", "their", "theirs", "to", "of", "in", "on",
    "for", "and", "or", "with", "at", "by", "as", "that", "this", "it", "its", "has", "have", "had",
    "do", "does", "remember", "please", "benji", "should", "would", "always", "never", "not",
})
_ENDINGS = ("", "s", "es", "d", "ed", "ing", "e", "ly", "r", "er")


def _word_matches(a: str, b: str) -> bool:
    if a == b:
        return True
    short, long_ = sorted((a, b), key=len)
    stem = short[:-1] if short.endswith("e") else short
    return len(stem) >= 3 and long_.startswith(stem) and long_[len(stem):] in _ENDINGS


def said_by_user(fact: str, user_text: str) -> bool:
    """Every content word of `fact` is in the user's own message (with endings: "prefers" and
    "prefer"). Filler such as "the user's" and "is" doesn't count; a fact of filler only is not
    said."""
    words = lambda t: re.findall(r"[a-z0-9]+", (t or "").casefold())
    content = [w for w in words(fact) if w not in _FILLER]
    said = words(user_text)
    return bool(content) and all(any(_word_matches(w, s) for s in said) for w in content)


# --- decline memory: "not now" is remembered for a while -------------------------------------

DECLINE_SECONDS = 30 * 60
_DECLINE_CAP = 200


class DeclineMemory:
    """When the user answers No to an asked action, the same kind of action on the same target is
    not asked again for 30 minutes, unless the user steers the job to go ahead (`clear`). It is
    decided here from the card's result (the app's own No), never from model text. Held in memory
    only, so a restart forgets it and the action is asked again (the safe direction). Keys are
    hashes of the tool and its normalised target, so no command, path or address sits in here.
    `scope` is a job's id, or "fg" for the foreground conversation. The clock is passed in."""

    def __init__(self, clock=None):
        import time as _time
        self.clock = clock or _time.time
        self._until: dict[str, dict[str, float]] = {}

    @staticmethod
    def key(tool: str, target: str) -> str:
        import hashlib
        norm = " ".join(str(target or "").split()).casefold()
        return hashlib.sha256(f"{tool}\0{norm}".encode()).hexdigest()[:20]

    def note(self, scope: str, tool: str, target: str) -> None:
        held = self._until.setdefault(scope, {})
        if len(held) >= _DECLINE_CAP:
            held.pop(next(iter(held)))
        held[self.key(tool, target)] = self.clock() + DECLINE_SECONDS

    def blocked(self, scope: str, tool: str, target: str) -> bool:
        held = self._until.get(scope)
        if not held:
            return False
        k, now = self.key(tool, target), self.clock()
        until = held.get(k)
        if until is None:
            return False
        if until <= now or until - now > DECLINE_SECONDS:     # over, or the clock went back
            del held[k]
            return False
        return True

    def clear(self, scope: str) -> None:
        self._until.pop(scope, None)


# --- an answer-style preference, kept only when the user says so -------------------------------

# Three styles, each one fixed line of plain text in the user's memory (Settings › Memory shows and
# deletes it like any other line). The model may only save exactly one of these lines, and only for a
# message in which the user asked for that style to stay ("from now on", "always", "remember");
# nothing else about it is trusted. Saved through the ordinary `remember` call, so a turn that has
# read outside content still asks first (TAINT_ASKED) and the memory's own refusals still apply.
STYLE_LINES = {
    "short": "Prefers short answers.",
    "yes_no": "Prefers a yes or no first, then the reason.",
    "simple": "Prefers simple words.",
}
_KEEP = re.compile(r"\b(from now on|always|every time|each time|going forward|in future|in the future|remember|keep)\b", re.I)
_STYLE_ASKS = {
    "short": re.compile(r"\b(shorter|short answers?|keep (it|them|answers?) short|brief(er)?|concise|less wordy|fewer words)\b", re.I),
    "yes_no": re.compile(r"\b(yes[ /]or[ /]no first|(start|begin|lead) with (a )?(yes|no)|yes[ /]no first|answer yes or no first)\b", re.I),
    "simple": re.compile(r"\b(simpler|simple|plain|easy|everyday) (words|language|english|terms)|\bno jargon\b|\bwithout jargon\b", re.I),
}


def style_lines_said(user_text: str) -> set[str]:
    """The style lines the user's own message asks to keep: a style named AND a cue that it should
    stay. A message that merely contains the word "short" asks for nothing."""
    text = user_text or ""
    if not _KEEP.search(text):
        return set()
    return {STYLE_LINES[k] for k, rx in _STYLE_ASKS.items() if rx.search(text)}
