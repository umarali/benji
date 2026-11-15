"""On-device speech with Kokoro, an optional extra (`tools/voice-setup.sh`).

`python -m benji --tts` is a small speech service. It loads the model once, then reads
JSON lines on stdin and streams audio back sentence by sentence, so speech starts while
the rest of the answer is still being synthesized. Text never leaves the Mac.

  in:  {"type":"speak","id":"7","text":"...","voice":"af_heart","speed":1.0}
       {"type":"stop"}                       drop whatever is queued or being spoken
  out: {"type":"ready","sample_rate":24000,"voices":[...],"model":"kokoro-v1.0.onnx","load_ms":900}
       {"type":"audio","id":"7","seq":0,"text":"First sentence.","pcm16":"<base64 little-endian int16 mono>"}
         (text: the sentence this audio speaks, so the app can follow along)
       {"type":"done","id":"7","stopped":false}
       {"type":"error","id":"7","text":"..."}   (no id: the service can't start)

This module is standard-library only. `kokoro_onnx` and `numpy` are imported lazily and
exist only in the isolated venv (~/.benji/voice-venv); the plain engine never needs them.
"""

from __future__ import annotations

import base64
import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from typing import Callable, Iterable, TextIO

from .config import workdir_path

DEFAULT_VOICE = "af_heart"
MODEL_FILES = ("kokoro-v1.0.onnx", "kokoro-v1.0.int8.onnx")   # preference order
VOICES_FILE = "voices-v1.0.bin"
SAMPLE_RATE = 24000
_VOICE_NAME = re.compile(r"^[a-z]{2}_[a-z0-9]+$")

# Synthesizes one sentence: (text, voice, speed) -> little-endian int16 mono PCM.
Synth = Callable[[str, str, float], bytes]


class TTSError(RuntimeError):
    pass


def voices_dir() -> Path:
    return workdir_path() / "voices"


def venv_python() -> Path:
    return workdir_path() / "voice-venv" / "bin" / "python3"


def model_path(directory: Path) -> Path | None:
    """The model to load: $BENJI_KOKORO_MODEL (a file name in `directory`), else the
    first of MODEL_FILES that exists."""
    chosen = os.getenv("BENJI_KOKORO_MODEL", "").strip()
    names = [Path(chosen).name] if chosen else list(MODEL_FILES)
    return next((directory / n for n in names if (directory / n).is_file()), None)


def installed() -> bool:
    d = voices_dir()
    return venv_python().exists() and model_path(d) is not None and (d / VOICES_FILE).is_file()


# --- text --------------------------------------------------------------------------

_SENTENCE_END = re.compile(r"(?<=[.!?…])[\"')\]]*\s+|\n+")
_CLAUSE_END = re.compile(r"(?<=[,;:—])\s+")


def sentences(text: str, max_chars: int = 220) -> list[str]:
    """Split plain text into speakable pieces: sentences, with overlong ones broken at
    clause boundaries. Very short pieces are joined to the next so prosody holds."""
    pieces: list[str] = []
    for s in _SENTENCE_END.split(text):
        s = s.strip()
        if not s:
            continue
        if len(s) <= max_chars:
            pieces.append(s)
            continue
        current = ""
        for clause in _CLAUSE_END.split(s):
            if current and len(current) + 1 + len(clause) > max_chars:
                pieces.append(current)
                current = clause
            else:
                current = f"{current} {clause}".strip()
        if current:
            pieces.append(current)
    merged: list[str] = []
    for p in pieces:
        if merged and len(merged[-1]) < 12:
            merged[-1] = f"{merged[-1]} {p}"
        else:
            merged.append(p)
    return merged


# --- the service ---------------------------------------------------------------------

class Service:
    """Turns speak requests into streamed audio. `handle` runs on the reader thread;
    `run` synthesizes on its own thread. A stop bumps the generation, so the sentence
    being synthesized is the last one produced for anything queued before it."""

    def __init__(self, synth: Synth, out: TextIO, voices: Iterable[str] = ()):
        self.synth = synth
        self.out = out
        self.voices = set(voices)
        self.jobs: queue.Queue = queue.Queue()
        self.generation = 0
        self.write_lock = threading.Lock()

    def emit(self, obj: dict) -> None:
        with self.write_lock:
            self.out.write(json.dumps(obj) + "\n")
            self.out.flush()

    def handle(self, line: str) -> None:
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            self.emit({"type": "error", "text": "unreadable request"})
            return
        kind = msg.get("type") if isinstance(msg, dict) else None
        if kind == "stop":
            self.generation += 1
        elif kind == "speak":
            self.jobs.put((self.generation, msg))
        else:
            self.emit({"type": "error", "text": f"unknown request type: {kind!r}"})

    def close(self) -> None:
        self.jobs.put(None)

    def run(self) -> None:
        while (job := self.jobs.get()) is not None:
            generation, msg = job
            self.speak(generation, msg)

    def speak(self, generation: int, msg: dict) -> None:
        from .voice import to_plain

        rid = str(msg.get("id", ""))
        voice = str(msg.get("voice") or DEFAULT_VOICE)
        if not _VOICE_NAME.match(voice) or (self.voices and voice not in self.voices):
            self.emit({"type": "error", "id": rid, "text": f"unknown Kokoro voice: {voice}"})
            return
        try:
            speed = min(2.0, max(0.5, float(msg.get("speed", 1.0))))
        except (TypeError, ValueError):
            speed = 1.0
        seq = 0
        for piece in sentences(to_plain(str(msg.get("text", "")))):
            if generation != self.generation:
                break
            try:
                pcm = self.synth(piece, voice, speed)
            except Exception as e:   # the model failing must not kill the service
                self.emit({"type": "error", "id": rid, "text": f"Kokoro failed: {e}"})
                return
            if generation != self.generation:
                break
            if pcm:
                self.emit({"type": "audio", "id": rid, "seq": seq, "text": piece,
                           "pcm16": base64.b64encode(pcm).decode("ascii")})
                seq += 1
        self.emit({"type": "done", "id": rid, "stopped": generation != self.generation})


def serve(synth: Synth, inp: TextIO, out: TextIO, ready: dict | None = None,
          voices: Iterable[str] = ()) -> None:
    """Run the protocol until stdin closes. Work already queued finishes first."""
    service = Service(synth, out, voices)
    worker = threading.Thread(target=service.run, daemon=True)
    worker.start()
    if ready is not None:
        service.emit(ready)
    for line in inp:
        if line.strip():
            service.handle(line)
    service.close()
    worker.join()


def offline() -> None:
    """Speech is local by design: nothing here may reach the network. Turn off any hub
    downloads or telemetry a library might try, keep phoneme/text debug logs off, and make
    Python-level internet sockets fail (Unix-domain sockets still work)."""
    import socket

    os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TRANSFORMERS_OFFLINE="1",
                      DO_NOT_TRACK="1", LOG_LEVEL="WARNING")

    def refuse(*_args, **_kwargs):
        raise OSError("Benji's speech service is offline-only")

    def guarded(method):
        def call(self, *args, **kwargs):
            if self.family in (socket.AF_INET, socket.AF_INET6):
                refuse()
            return method(self, *args, **kwargs)
        return call

    for name in ("connect", "connect_ex", "sendto"):
        setattr(socket.socket, name, guarded(getattr(socket.socket, name)))
    socket.getaddrinfo = refuse
    socket.create_connection = refuse


def load_kokoro() -> tuple[Synth, list[str], dict]:
    """Load the model (from the voice venv) and warm it up. Raises TTSError."""
    d = voices_dir()
    model = model_path(d)
    if model is None or not (d / VOICES_FILE).is_file():
        raise TTSError(f"Kokoro model files aren't in {d}. Run tools/voice-setup.sh.")
    try:
        import numpy as np                 # optional extra: only in the voice venv
        from kokoro_onnx import Kokoro
    except ImportError:
        raise TTSError("kokoro-onnx isn't installed in this Python. Run tools/voice-setup.sh "
                       f"and start the service with {venv_python()}.") from None
    started = time.monotonic()
    kokoro = Kokoro(str(model), str(d / VOICES_FILE))

    def synth(text: str, voice: str, speed: float) -> bytes:
        audio, _ = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
        return (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()

    synth("Ready.", DEFAULT_VOICE, 1.0)    # the first inference is slow; pay it now
    voices = list(kokoro.get_voices())
    ready = {"type": "ready", "sample_rate": SAMPLE_RATE, "voices": voices,
             "model": model.name, "load_ms": round((time.monotonic() - started) * 1000)}
    return synth, voices, ready


def main() -> int:
    """`python -m benji --tts`: the speech service on stdin/stdout."""
    offline()
    try:
        synth, voices, ready = load_kokoro()
    except Exception as e:
        print(json.dumps({"type": "error", "text": str(e)}), flush=True)
        return 2
    serve(synth, sys.stdin, sys.stdout, ready, voices)
    return 0


# --- client, for the CLI's --speak ----------------------------------------------------

def speak_blocking(text: str, voice: str = DEFAULT_VOICE, engine_dir: Path | None = None) -> None:
    """Speak through the service in the voice venv, playing each sentence with `afplay`
    as it arrives. Raises TTSError when Kokoro isn't usable (the caller falls back)."""
    if not installed():
        raise TTSError("Kokoro isn't installed (tools/voice-setup.sh).")
    root = engine_dir or Path(__file__).resolve().parent.parent
    proc = subprocess.Popen([str(venv_python()), "-m", "benji", "--tts"], cwd=root, text=True,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    assert proc.stdin and proc.stdout
    proc.stdin.write(json.dumps({"type": "speak", "id": "1", "text": text, "voice": voice}) + "\n")
    proc.stdin.close()
    player: subprocess.Popen | None = None
    played = 0
    with tempfile.TemporaryDirectory(prefix="benji-tts-") as td:
        try:
            for line in proc.stdout:
                msg = json.loads(line)
                if msg.get("type") == "error":
                    if played:
                        break
                    raise TTSError(msg.get("text", "Kokoro failed"))
                if msg.get("type") != "audio":
                    continue
                path = Path(td) / f"{msg['seq']}.wav"
                with wave.open(str(path), "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(SAMPLE_RATE)
                    w.writeframes(base64.b64decode(msg["pcm16"]))
                if player:
                    player.wait()
                player = subprocess.Popen(["afplay", str(path)])
                played += 1
            if player:
                player.wait()
        except KeyboardInterrupt:
            if player:
                player.terminate()
            raise
        finally:
            proc.kill()
            proc.wait()
