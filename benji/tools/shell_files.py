"""Shell commands and files inside the working folder."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from .. import gate
from .context import Ctx, _resolve, _run, _truncate, _within


def _run_shell(ctx: Ctx, command: str, cwd: str | None = None) -> str:
    workdir = _resolve(ctx, cwd) if cwd else ctx.workdir
    try:
        proc = _run(ctx, command, shell=True, cwd=str(workdir), timeout=120)
    except subprocess.TimeoutExpired:
        return "[error] command timed out after 120s"
    out = (proc.stdout or "") + (("\n[stderr]\n" + proc.stderr) if proc.stderr else "")
    return _truncate(f"[exit {proc.returncode}]\n{out}".rstrip())


def _private(p: Path, ctx: Ctx | None = None) -> str | None:
    """The refusal for a private path, or None. Never asked: refused."""
    why = gate.private_path(p, workdir=ctx.workdir if ctx else None)
    return (f"[refused] {p} is private ({why}: keys, mail, messages, browser data or Benji's own "
            "settings). Benji never reads it; don't try another way.") if why else None


def _read_file(ctx: Ctx, path: str, offset: int = 0, limit: int = 2000) -> str:
    p = _resolve(ctx, path)
    refused = _private(p, ctx)
    if refused:
        return refused
    if not p.exists():
        return f"[error] no such file: {p}"
    if p.is_dir():
        return f"[error] {p} is a directory (use list_dir)"
    try:
        lines = p.read_text(errors="replace").splitlines()
    except Exception as e:  # noqa: BLE001
        return f"[error] could not read {p}: {e}"
    chunk = lines[offset: offset + limit]
    body = "\n".join(f"{offset + i + 1}\t{ln}" for i, ln in enumerate(chunk))
    return _truncate(body or "[empty]")


def _write_file(ctx: Ctx, path: str, content: str) -> str:
    p = _resolve(ctx, path)
    if gate.is_job_record(p):
        return _private(p, ctx) or "[refused] That is a Benji job's record."
    existed = p.exists()
    try:
        if _within(ctx, p):
            p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    except Exception as e:  # noqa: BLE001
        return f"[error] could not write {p}: {e}"
    verb = "overwrote" if existed else "wrote"
    return f"[ok] {verb} {p} ({len(content)} bytes)"


def _list_dir(ctx: Ctx, path: str = ".") -> str:
    p = _resolve(ctx, path)
    refused = _private(p, ctx)
    if refused:
        return refused
    if not p.exists():
        return f"[error] no such path: {p}"
    if not p.is_dir():
        return f"[error] not a directory: {p}"
    rows = []
    for entry in sorted(p.iterdir(), key=lambda e: (not e.is_dir(), e.name.lower())):
        kind = "dir " if entry.is_dir() else "file"
        try:
            size = entry.stat().st_size
        except OSError:
            size = 0
        rows.append(f"{kind}  {size:>12}  {entry.name}")
    return _truncate(f"{p}\n" + "\n".join(rows) if rows else f"{p}\n[empty]")


def _search_files(ctx: Ctx, query: str, path: str | None = None, content: bool = False) -> str:
    root = _resolve(ctx, path) if path else ctx.workdir
    refused = _private(root, ctx)
    if refused:
        return refused
    if not root.exists():
        return f"[error] no such path: {root}"
    has_rg = shutil.which("rg") is not None
    if content:
        if has_rg:
            cmd = ["rg", "--no-config", "-n", "--no-heading", "--color=never", "--null", "-S",
                   *[a for g in gate.SEARCH_EXCLUDES for a in ("-g", f"!{g}")], "--", query, str(root)]
        else:
            cmd = ["grep", "-rHnI", "--null", *[f"--exclude={g}" for g in gate.SEARCH_EXCLUDES], "--", query, str(root)]
    else:
        # Keep filenames delimited until after the privacy check: a name can contain ':' or a newline.
        cmd = ["rg", "--no-config", "--files", "--null", str(root)] if has_rg else [
            "find", str(root), "-iname", f"*{query}*", "-print0"]
    try:
        proc = _run(ctx, cmd, timeout=60)
    except subprocess.TimeoutExpired:
        return "[error] search timed out after 60s"
    rows = []
    if content:
        remaining = proc.stdout
        while remaining:
            name, sep, body = remaining.partition("\0")
            if not sep:
                break
            line, _, remaining = body.partition("\n")
            p = _resolve(ctx, name)
            # Both engines emit filename NUL line-number:line. Ignore any non-record output
            # (such as binary-file notices); never mistake a colon in a filename for that boundary.
            if gate.private_path(p, workdir=ctx.workdir):
                continue
            if line.partition(":")[0].isdigit() and p.is_file():
                rows.append(f"{name}:{line}")
    else:
        names = [name for name in proc.stdout.split("\0")
                 if name and not gate.private_path(_resolve(ctx, name), workdir=ctx.workdir)]
        if has_rg and names:
            # Preserve grep's filename-query syntax. Only checked names reach this process;
            # match whole original names even when a name spans more than one output line.
            try:
                matched = _run(ctx, ["grep", "-i", "--", query], input="\n".join(names) + "\n", timeout=60)
            except subprocess.TimeoutExpired:
                return "[error] search timed out after 60s"
            lines = set(matched.stdout.splitlines())
            rows = [name for name in names if any(line in lines for line in name.splitlines())]
        else:
            rows = names
    out = "\n".join(rows)
    if not out:
        return f"[no matches] {query!r} under {root}"
    return _truncate(out)
