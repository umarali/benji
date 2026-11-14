"""Benji command-line entry point.

    python3 -m benji                 # interactive REPL
    python3 -m benji "do a thing"    # one-shot
    python3 -m benji --yes ...       # auto-approve side effects (use with care)
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import signal
import sys
import tempfile

from . import __version__, answer_log, audit, conversations, jobs, memory, schedule, usage, voice
from . import policy as policy_mod
from .agent import Agent
from .browser_link import Link
from .config import load_config, load_dotenv, workdir_path
from .history import HistoryError, read_history
from .images import ImageError, load_image
from .pointing import screen_info
from .prompts import SystemPrompt, TurnInfo, job_rules, surface_from_env, system_prompt
from .providers import ProviderError, effort_for, effort_level, make_provider

# A front-end (e.g. the menu-bar app) sets BENJI_APPROVAL_IO=1 and handles approval
# over stdio: Benji writes a sentinel-tagged request on stdout and reads y/n on stdin.
APPROVE_SENTINEL = "\x01BENJI-APPROVE\x01"
# With BENJI_EVENTS=1, Benji also emits structured UI events on stdout as one JSON
# object per line, sentinel-wrapped so they never collide with normal text.
EVENT_SENTINEL = "\x01BENJI-EVENT\x01"


def _emit_event(obj: dict) -> None:
    if os.environ.get("BENJI_EVENTS") == "1":
        sys.stdout.write(f"{EVENT_SENTINEL}{json.dumps(obj, ensure_ascii=False)}\x01\n")
        sys.stdout.flush()


def _approve(reason: str) -> bool:
    if os.environ.get("BENJI_APPROVAL_IO") == "1":
        # Front-end handles the prompt. Emit the request, then block on the reply.
        # One line on the wire: a whole AppleScript on the card keeps its line breaks as ⏎.
        sys.stdout.write(f"{APPROVE_SENTINEL}{' ⏎ '.join(reason.splitlines())}\x01\n")
        sys.stdout.flush()
        try:
            ans = sys.stdin.readline().strip().lower()
        except (EOFError, OSError):
            return False
        return ans in ("y", "yes")
    if not sys.stdin.isatty():
        print(f"\n[Benji] approval needed to {reason}\n      non-interactive; denying.", file=sys.stderr)
        return False
    ans = input(f"\n[Benji] Approve: {reason}\n      [y/N] ").strip().lower()
    return ans in ("y", "yes")


def _on_tool(name: str, inp: dict) -> None:
    detail = inp.get("command") or inp.get("path") or inp.get("query") or inp.get("url") or ""
    print(f"  · {name} {detail}".rstrip(), file=sys.stderr)
    _emit_event({"type": "tool", "name": name, "detail": str(detail)})


def one_shot_turn(args, remembered: tuple[int, bool] | None = None) -> TurnInfo:
    """--allow-pointing, --screen and --spoken for a one-shot run (the companion's one-shot backend).
    `remembered`: how many earlier exchanges the run was given and whether older ones were dropped,
    when a front-end keeps the conversation (None in the terminal's own loop)."""
    pointing = getattr(args, "allow_pointing", False)
    screen = None
    if pointing and getattr(args, "screen", None):
        try:
            screen = screen_info(json.loads(args.screen))
        except ValueError:
            screen = None
    kept, dropped = remembered if remembered is not None else (None, False)
    task = " ".join(args.task) if getattr(args, "task", None) else ""
    return TurnInfo(pointing, getattr(args, "spoken", False), screen, history=kept, history_dropped=dropped, task=task)


def build_agent(args, remembered: tuple[int, bool] | None = None) -> Agent:
    cfg = load_config(workdir=args.workdir, model=args.model, auto_approve=args.yes)
    provider = make_provider(cfg.provider, cfg.api_key, cfg.model, cfg.base_url, **_provider_options(cfg))
    print(startup_line(cfg), file=sys.stderr)
    audit.configure(cfg.workdir / audit.FILE_NAME)
    announce_home()
    audit.event("engine_start", mode="oneshot" if args.task else "repl", version=__version__, **_where(cfg))
    agent = Agent(
        provider=provider,
        system_prompt=SystemPrompt(system_prompt(str(cfg.workdir), memory=memory.digest(cfg.memory_path),
                                                 surface=surface_from_env(),
                                                 past=conversations.digest(conversations.folder(cfg.workdir),
                                                                           drop_newest=bool(remembered and remembered[0]))),
                                   one_shot_turn(args, remembered).rules(surface_from_env())),
        workdir=cfg.workdir,
        approve=_approve,
        auto_approve=cfg.auto_approve,
        on_tool=_on_tool,
        skills_dir=cfg.skills_dir,
        memory_path=cfg.memory_path,
        usage_path=cfg.usage_path,
        policy=policy_mod.load(cfg.workdir),
    )
    agent.set_run("c" + secrets.token_hex(4), "turn")      # a command-line run: its own id in the audit log
    return agent


def serve_main(args) -> int:
    """`benji --serve`: one Agent per turn over a shared provider; see benji/serve.py."""
    from . import serve
    requests, events = serve.isolate_stdio()
    emit = serve.stream_emitter(events)
    audit.configure(workdir_path(args.workdir) / audit.FILE_NAME)
    home_notice = announce_home()

    def startup_error(text: str) -> int:
        # The engine's stderr is kept in engine.log (D-144): a setting's value in the text can be a
        # URL with a key in it.
        print(audit.redact(text), file=sys.stderr)
        audit.error("startup", "startup")
        audit.event("engine_exit", clean=False, code=2)
        emit({"type": "error", "code": "startup", "text": text})
        return 2

    if args.yes or args.task or args.image or args.history or args.screen or args.spoken:
        return startup_error("[Benji] --serve takes no task, --image, --history, --screen, --spoken or --yes; "
                             "send them as requests instead.")
    try:
        cfg = load_config(workdir=args.workdir, model=args.model)
        provider = make_provider(cfg.provider, cfg.api_key, cfg.model, cfg.base_url, **_provider_options(cfg))
    except (SystemExit, ProviderError) as e:
        return startup_error(str(e))
    print(startup_line(cfg, serving=True), file=sys.stderr)
    _policy = policy_mod.load(cfg.workdir)
    if _policy.active:      # names of families only: the file's other content is never echoed
        print(f"[Benji] policy.json switches off: {_policy.summary()}"
              + ("  (the file could not be read, so the strict reading applies)" if _policy.unreadable else ""),
              file=sys.stderr)

    past: list[str] = []   # the recent titles, read at each conversation's first turn

    def recent_titles(turn_info) -> str:
        # Read again only when a conversation starts (or the engine does), so the prompt's base
        # stays the same through a conversation and is read from cache (D-111, D-121).
        if not past or not turn_info.history:
            past[:] = [conversations.digest(conversations.folder(cfg.workdir), drop_newest=bool(turn_info.history))]
        return past[0]

    def make_agent(approve, on_tool, cancelled, turn_info):
        surface = surface_from_env()
        prompt = system_prompt(str(cfg.workdir), memory=memory.digest(cfg.memory_path), surface=surface,
                               past=recent_titles(turn_info))
        return Agent(provider=provider,
                     system_prompt=SystemPrompt(prompt, turn_info.rules(surface)),
                     workdir=cfg.workdir, approve=approve, auto_approve=False,
                     on_tool=on_tool, skills_dir=cfg.skills_dir,
                     memory_path=cfg.memory_path, usage_path=cfg.usage_path,
                     cancelled=cancelled, policy=policy_mod.load(cfg.workdir))

    def make_job_agent(record, approve, on_tool, cancelled):
        # A job works in its own folder (D-130 step 1): that is its working folder, so anything
        # outside it is asked about as it is for any turn. No screen, no pointing.
        where = job_store.path(record["id"])
        prompt = system_prompt(str(where), memory=memory.digest(cfg.memory_path), surface=surface_from_env())
        sites = list((record.get("browser") or {}).get("origins", [])) if browser_link.running else []
        repeating = schedule.load(schedule.file_for(job_store.root, record['id']))[0] is not None
        rules = job_rules(str(where), sites, unattended=bool(record.get("unattended")), repeating=repeating)
        return Agent(provider=provider, system_prompt=SystemPrompt(prompt, rules),
                     workdir=where, approve=approve, auto_approve=False, on_tool=on_tool,
                     skills_dir=cfg.skills_dir, memory_path=cfg.memory_path, usage_path=cfg.usage_path,
                     cancelled=cancelled, policy=policy_mod.load(cfg.workdir))

    browser_link = Link()       # off until the app's switch says so (D-143); its folder is private
    info = {"version": __version__, "provider": cfg.provider, "model": cfg.model,
            "destination": cfg.destination, "host": cfg.host, "vision": cfg.vision, "effort": _effort(cfg)}
    if home_notice:
        info["home_notice"] = home_notice       # the one line about the move to ~/.benji, in the first run only
    serve.stop_on_signals()
    answers = cfg.workdir / answer_log.FILE_NAME if answer_log.enabled() else None
    job_store = jobs.JobStore(jobs.folder(cfg.workdir))
    job_store.migrate()         # before any job runs: records move out of the jobs' own folders (D-177)
    audit.event("engine_start", mode="serve", version=__version__, jobs=True, browser=True, **_where(cfg))
    try:
        code = serve.run(serve.Server(make_agent, emit, info, answer_log_path=answers,
                                      make_job_agent=make_job_agent, job_store=job_store,
                                      browser_link=browser_link,
                                      policy_for=lambda: policy_mod.load(cfg.workdir)), requests)
    except BaseException as e:
        print(audit.safe_traceback(e), file=sys.stderr)
        audit.error("serve", "internal", e)
        audit.event("engine_exit", clean=False, error_type=type(e).__name__)
        raise
    audit.event("engine_exit", clean=code == 0, code=code)
    return code


def announce_home() -> str:
    """The one-time move to ~/.benji, reported once: the audit log gets the kind, stderr (and so
    engine.log) the plain line, and the line is returned for the app's `ready`. Then the check that the
    on-device voice still works from the new place, once."""
    from . import home, runtime_check
    found = home.announce()
    notice = found.notice
    voice = runtime_check.after_move()
    if voice == "broken":
        notice = f"{notice} {runtime_check.NOTICE_BROKEN}".strip()
    if voice:
        audit.event("voice_checked", status=voice)
    if notice:
        print(f"[Benji] {notice}", file=sys.stderr)
    return notice


def startup_line(cfg, serving: bool = False) -> str:
    """The first line on stderr: which provider and model, which HOST the data goes to (never a key),
    whether the model reads images and how it thinks, and the working folder (D-147)."""
    extra = ""
    if cfg.preset is not None:
        extra = f"  thinking={cfg.thinking}"
    if not cfg.vision:
        extra += "  screen=off (this model can't read images)"
    return (f"Benji {__version__}{' serving' if serving else ''}  ·  provider={cfg.provider}  model={cfg.model}  "
            f"sends to={cfg.sends_to}{extra}  workdir={cfg.workdir}")


def _provider_options(cfg) -> dict:
    return {"thinking": cfg.thinking, "max_tokens": cfg.max_tokens, "vision": cfg.vision}


def _where(cfg) -> dict:
    """provider, model and host for the audit log's engine_start (the host only when it is a dotted
    name: localhost is not one, and the provider says it is this computer)."""
    out = {"provider": cfg.provider}
    if audit._MODEL.match(cfg.model):       # an odd name would make the whole event refused
        out["model"] = cfg.model
    if "." in cfg.host and ":" not in cfg.host:
        out["host"] = cfg.host
    elif "." in cfg.host:
        out["host"] = cfg.host.rsplit(":", 1)[0]
    return out


def _effort(cfg) -> str | None:
    """The effort sent with each request, or None when none is (not Claude, or a model without it)."""
    return effort_for(cfg.model, effort_level()) if cfg.provider == "claude" else None


def _sigterm_to_interrupt(signum, frame):
    raise KeyboardInterrupt  # lets a front-end stop the loop cleanly via SIGTERM


def listen_loop(agent, args, run_one) -> None:
    """Continuously listen; on the wake word, run the spoken task and speak the answer."""
    args.speak = True  # answers are always spoken in listen mode
    wake = (args.wake or "").strip()
    try:
        signal.signal(signal.SIGTERM, _sigterm_to_interrupt)
    except (ValueError, OSError):
        pass

    if voice.transcription_provider() is None:
        print("[Benji] voice input needs a transcription key (OPENAI_API_KEY or DEEPGRAM_API_KEY).",
              file=sys.stderr)
        return

    wake_msg = f"wake word '{wake}'" if wake else "no wake word (any speech)"
    print(f"[Benji] listening — {wake_msg}, {args.voice_seconds}s windows. Ctrl-C to stop.",
          file=sys.stderr)
    try:
        while True:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
                wav = tf.name
            try:
                try:
                    voice.record(wav, seconds=args.voice_seconds)
                except voice.VoiceError as e:
                    print(f"[Benji] {e}", file=sys.stderr)
                    return
                if voice.rms_energy(wav) < args.listen_threshold:
                    continue  # silence — skip without spending a transcription call
                try:
                    _, text = voice.transcribe(wav)
                except voice.VoiceError as e:
                    print(f"[Benji] transcription failed: {e}", file=sys.stderr)
                    continue
                matched, task = voice.heard_wake_word(text.strip(), wake)
                if not matched or not task:
                    continue
                print(f"\n[Benji] ▶ {task}", file=sys.stderr)
                run_one(task)
            finally:
                try:
                    os.unlink(wav)
                except OSError:
                    pass
    except KeyboardInterrupt:
        print("\n[Benji] stopped listening.", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="benji", description="A local terminal personal assistant.")
    parser.add_argument("task", nargs="*", help="One-shot task. Omit for an interactive REPL.")
    parser.add_argument("--workdir", help="Working folder (default: $BENJI_WORKDIR or ~/.benji).")
    parser.add_argument("--model", help="Override the model id (else $BENJI_MODEL or a default).")
    parser.add_argument("--yes", action="store_true", help="Auto-approve side-effecting actions.")
    parser.add_argument("--speak", action="store_true", help="Speak the final answer aloud (macOS).")
    parser.add_argument("--voice", action="store_true",
                        help="Capture a spoken task from the mic (needs ffmpeg + a transcription key).")
    parser.add_argument("--voice-seconds", type=int, default=6, help="Recording length for --voice.")
    parser.add_argument("--say-voice", help="macOS voice name for --speak (e.g. Samantha).")
    parser.add_argument("--listen", action="store_true",
                        help="Always-listening loop: say the wake word, then your task (Ctrl-C to stop).")
    parser.add_argument("--wake", default="benji",
                        help="Wake word for --listen (default 'benji'; empty acts on any speech).")
    parser.add_argument("--listen-threshold", type=float, default=0.02,
                        help="Silence gate for --listen (RMS 0..1; higher ignores quieter audio).")
    parser.add_argument("--transcribe", metavar="WAV",
                        help="Transcribe an audio file and print the text (needs a transcription key). "
                             "Used by the companion app's push-to-talk; needs no model key.")
    parser.add_argument("--image", metavar="PATH", action="append", default=[],
                        help="Attach an image (png/jpeg/gif/webp) to a one-shot task. Repeatable.")
    parser.add_argument("--history", metavar="JSON",
                        help="Earlier exchanges for context: a JSON list of {user, assistant}. One-shot only.")
    parser.add_argument("--history-dropped", action="store_true",
                        help="With --history: the front-end has already dropped older exchanges of this "
                             "conversation, so the model is told they are gone.")
    parser.add_argument("--allow-pointing", action="store_true",
                        help="The attached image is the user's screen; the answer may end with pointing and drawing "
                             "tags (benji/pointing.py).")
    parser.add_argument("--screen", metavar="JSON",
                        help="With --allow-pointing: what the screenshot holds, as the companion works it out "
                             "(size, notch, menu bar, display; ScreenshotGeometry.swift).")
    parser.add_argument("--spoken", action="store_true",
                        help="The user spoke this task (the companion's voice input); the answer will be read aloud.")
    parser.add_argument("--serve", action="store_true",
                        help="Stay running and speak JSON lines over stdio for a front-end "
                             "(docs/proposal-serve.md).")
    parser.add_argument("--usage", action="store_true",
                        help="Summarise Benji's logged token usage (workdir/usage.jsonl) and exit (no API call).")
    parser.add_argument("--diagnose", action="store_true",
                        help="Print a short report of what Benji logged lately (events.jsonl, engine.log): "
                             "errors, denials, approvals, failed jobs, slow turns. No message text. No API call.")
    parser.add_argument("--hours", type=float, default=24.0, metavar="N",
                        help="With --diagnose: how far back to look (default 24).")
    parser.add_argument("--print-provider", action="store_true",
                        help="Print the configured provider and model as JSON and exit (no API call).")
    parser.add_argument("--tts", action="store_true",
                        help="Run the on-device Kokoro speech service: JSON lines on stdio "
                             "(benji/tts.py). Needs ./voice-setup.sh and its venv's Python; no key.")
    parser.add_argument("--version", action="version", version=f"Benji {__version__}")
    args = parser.parse_args(argv)

    if args.tts:
        from . import tts
        return tts.main()

    if args.print_provider:
        try:
            cfg = load_config(workdir=args.workdir, model=args.model)
        except SystemExit as e:
            print(str(e), file=sys.stderr)
            return 2
        print(json.dumps({"provider": cfg.provider, "model": cfg.model, "images": cfg.vision,
                          "destination": cfg.destination, "host": cfg.host, "effort": _effort(cfg)}))
        return 0

    if args.serve:
        return serve_main(args)

    if args.diagnose:
        from . import diagnose
        print(diagnose.report(workdir_path(args.workdir), hours=args.hours))
        return 0

    if args.usage:
        load_dotenv()
        print(usage.summary(workdir_path(args.workdir) / "usage.jsonl"))
        return 0

    # Validate attachments before spending an API call.
    images: list[dict] = []
    for path in args.image:
        try:
            images.append(load_image(path))
        except ImageError as e:
            print(f"[Benji] {e}", file=sys.stderr)
            _emit_event({"type": "error", "text": str(e)})
            return 2
    history: list[dict] = []
    dropped = getattr(args, "history_dropped", False)
    if args.history:
        try:
            history, dropped_here = read_history(args.history)
            dropped = dropped or dropped_here
        except HistoryError as e:
            print(f"[Benji] {e}", file=sys.stderr)
            _emit_event({"type": "error", "text": str(e)})
            return 2
        if not args.task:
            print("[Benji] --history needs a one-shot task", file=sys.stderr)
            return 2
    if images and not args.task:
        print("[Benji] --image needs a one-shot task, e.g. benji --image shot.png \"what's this?\"",
              file=sys.stderr)
        return 2

    # Transcription-only mode: no model/provider key required, just a STT key.
    if args.transcribe:
        try:
            _, text = voice.transcribe(args.transcribe)
        except voice.VoiceError as e:
            print(f"[Benji] {e}", file=sys.stderr)
            return 2
        print(text)
        return 0

    if args.voice or args.listen:
        args.spoken = True      # the task comes from the mic and the answer is spoken
    try:
        # The companion keeps the conversation: the model is told how much of it this run has.
        kept_by_front_end = bool(args.task) and (bool(args.history) or surface_from_env() == "panel")
        agent = build_agent(args, (len(history) // 2, dropped) if kept_by_front_end else None)
    except (SystemExit, ProviderError) as e:
        print(str(e), file=sys.stderr)
        return 2
    agent.messages.extend(history)

    def run_one(text: str, attachments: list[dict] | None = None) -> None:
        # Only a terminal sees the answer as it streams; a pipe (the companion's one-shot backend)
        # gets the same single print as before streaming existed.
        shown: list[str] = []
        if sys.stdout.isatty():
            def show(piece: str) -> None:
                shown.append(piece)
                sys.stdout.write(piece)
                sys.stdout.flush()

            def dropped() -> None:
                if shown:
                    sys.stdout.write("\n")
                    shown.clear()
            agent.on_text, agent.on_text_dropped = show, dropped
        try:
            answer = agent.send(text, images=attachments)
        except ProviderError as e:
            if shown:
                print()
            print(f"\n[Benji] provider error:\n{e}\n"
                  f"[Benji] if this is a model-not-found error, set BENJI_MODEL to a valid id.",
                  file=sys.stderr)
            _emit_event({"type": "error", "text": str(e)})
            return
        if shown and "".join(shown) == answer:
            print()                 # already on screen
        else:
            if shown:
                print()
            print(answer)
        _emit_event({"type": "answer", "text": answer})
        u = agent.last_usage
        if u.get("calls") and os.environ.get("BENJI_EVENTS") != "1":
            print(f"[Benji] tokens: {u['input_tokens']:,} in, {u['output_tokens']:,} out "
                  f"({u['calls']} call{'s' if u['calls'] != 1 else ''})", file=sys.stderr)
        if args.speak:
            print(voice.speak(answer, voice=args.say_voice), file=sys.stderr)

    def capture_spoken() -> str | None:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
            wav = tf.name
        try:
            print(f"[Benji] listening for {args.voice_seconds}s…", file=sys.stderr)
            voice.record(wav, seconds=args.voice_seconds)
            provider, text = voice.transcribe(wav)
            print(f"[Benji] heard (via {provider}): {text}", file=sys.stderr)
            return text
        except voice.VoiceError as e:
            print(f"[Benji] voice input unavailable: {e}", file=sys.stderr)
            return None

    if args.listen:
        listen_loop(agent, args, run_one)
        return 0

    if args.voice:
        spoken = capture_spoken()
        if spoken:
            run_one(spoken)
        return 0

    if args.task:
        run_one(" ".join(args.task), images or None)
        return 0

    print("Benji — type a task, or Ctrl-D / 'exit' to quit.", file=sys.stderr)
    while True:
        try:
            text = input("\nbenji› ").strip()
        except EOFError:
            print()
            break
        if text.lower() in ("exit", "quit"):
            break
        if text:
            run_one(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
