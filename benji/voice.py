"""Voice input and output, standard library only.

- speak(): on-device speech with Kokoro when installed (benji/tts.py), else macOS `say`; no key.
- record(): capture mic audio via ffmpeg (if installed).
- transcribe(): speech-to-text via OpenAI Whisper or Deepgram (needs a key).

Each piece degrades with a clear message when its dependency/key is missing.
"""

from __future__ import annotations

import array
import json
import math
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

from . import tls
import uuid
import wave

OPENAI_TRANSCRIBE = "https://api.openai.com/v1/audio/transcriptions"
DEEPGRAM_LISTEN = "https://api.deepgram.com/v1/listen"


class VoiceError(RuntimeError):
    pass


# --- text-to-speech ---------------------------------------------------------

_MD_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")


# Emoji so `say` doesn't read "smiling face" aloud: pictographs, symbols drawn as emoji
# (with U+FE0F), keycaps, skin tones, flags and the joiners between them.
_EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "\u2B00-\u2BFF\uFE0F\u200D\u20E3\U000E0020-\U000E007F]")


def to_plain(text: str) -> str:
    """Strip common Markdown so speech doesn't read out asterisks and backticks."""
    text = _MD_LINK.sub(r"\1", text)
    text = re.sub(r"`{1,3}", "", text)
    text = re.sub(r"\*\*|__|\*|_", "", text)
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.M)
    text = re.sub(r"^\s*[-*]\s+", "", text, flags=re.M)
    text = _EMOJI.sub("", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    text = re.sub(r" +([.,!?;:])", r"\1", text)
    return text.strip()


def speak(text: str, voice: str | None = None) -> str:
    """Speak with Kokoro when it's installed (on-device, see benji/tts.py), else `say`.
    BENJI_TTS=say, or a --say-voice, keeps `say`."""
    if sys.platform != "darwin":
        return "[voice] speaking is macOS-only (uses `say`)."
    plain = to_plain(text)
    if not plain:
        return "[voice] nothing to speak."
    if voice is None and os.getenv("BENJI_TTS", "").lower() not in ("say", "system"):
        from . import tts
        if tts.installed():
            try:
                tts.speak_blocking(plain, os.getenv("BENJI_KOKORO_VOICE") or tts.DEFAULT_VOICE)
                return "[voice] spoken (Kokoro)."
            except tts.TTSError as e:
                print(f"[voice] Kokoro unavailable, using `say`: {e}", file=sys.stderr)
    cmd = ["say"] + (["-v", voice] if voice else [])
    try:
        subprocess.run(cmd, input=plain, text=True, timeout=120)
    except FileNotFoundError:
        return "[voice] `say` not found."
    except subprocess.TimeoutExpired:
        return "[voice] speech timed out."
    return "[voice] spoken."


# --- recording --------------------------------------------------------------

def record(out_path: str, seconds: int = 6, device: str = ":0") -> str:
    """Record from the mic to a wav file using ffmpeg's avfoundation input."""
    if sys.platform != "darwin":
        return "[voice] recording path here assumes macOS/avfoundation."
    if shutil.which("ffmpeg") is None:
        raise VoiceError("ffmpeg is not installed (needed to record audio). "
                         "Install it (e.g. `brew install ffmpeg`) or pass an audio file.")
    cmd = ["ffmpeg", "-y", "-f", "avfoundation", "-i", device,
           "-t", str(seconds), "-ar", "16000", "-ac", "1", out_path]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=seconds + 30)
    except subprocess.TimeoutExpired:
        raise VoiceError("recording timed out") from None
    if proc.returncode != 0:
        raise VoiceError(f"ffmpeg failed: {proc.stderr[-400:]}")
    return out_path


# --- speech-to-text ---------------------------------------------------------

def _multipart(fields: dict[str, str], file_field: str, filename: str,
               file_bytes: bytes, content_type: str = "audio/wav") -> tuple[str, bytes]:
    boundary = "benji" + uuid.uuid4().hex
    parts: list[bytes] = []
    for k, v in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; "
        f"filename=\"{filename}\"\r\nContent-Type: {content_type}\r\n\r\n".encode())
    parts.append(file_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return boundary, b"".join(parts)


def _transcribe_openai(path: str, key: str, model: str = "whisper-1") -> str:
    with open(path, "rb") as f:
        audio = f.read()
    boundary, body = _multipart({"model": model}, "file", os.path.basename(path), audio)
    req = urllib.request.Request(
        OPENAI_TRANSCRIBE, data=body, method="POST",
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with tls.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read()).get("text", "").strip()
    except tls.TrustError as e:
        raise VoiceError(str(e)) from None
    except urllib.error.HTTPError as e:
        raise VoiceError(f"OpenAI transcription HTTP {e.code}: {e.read().decode(errors='replace')[:300]}") from None


def _transcribe_deepgram(path: str, key: str) -> str:
    with open(path, "rb") as f:
        audio = f.read()
    req = urllib.request.Request(
        DEEPGRAM_LISTEN + "?smart_format=true", data=audio, method="POST",
        headers={"Authorization": f"Token {key}", "Content-Type": "audio/wav"})
    try:
        with tls.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
        return data["results"]["channels"][0]["alternatives"][0]["transcript"].strip()
    except tls.TrustError as e:
        raise VoiceError(str(e)) from None
    except (urllib.error.HTTPError, KeyError, IndexError) as e:
        raise VoiceError(f"Deepgram transcription failed: {e}") from None


def transcription_provider() -> str | None:
    if os.getenv("OPENAI_API_KEY"):
        return "openai"
    if os.getenv("DEEPGRAM_API_KEY"):
        return "deepgram"
    return None


def transcribe(path: str) -> tuple[str, str]:
    """Return (provider, transcript)."""
    prov = transcription_provider()
    if prov == "openai":
        return "openai", _transcribe_openai(path, os.environ["OPENAI_API_KEY"])
    if prov == "deepgram":
        return "deepgram", _transcribe_deepgram(path, os.environ["DEEPGRAM_API_KEY"])
    raise VoiceError("no transcription key found. Set OPENAI_API_KEY or DEEPGRAM_API_KEY "
                     "to use voice input.")


# --- always-listening helpers ----------------------------------------------

def rms_energy(path: str) -> float:
    """Normalized RMS loudness (0..~1) of a WAV, for a cheap silence gate."""
    try:
        with wave.open(path, "rb") as w:
            width = w.getsampwidth()
            frames = w.readframes(w.getnframes())
    except (wave.Error, OSError):
        return 0.0
    if not frames or width != 2:          # we record 16-bit PCM
        return 0.0
    samples = array.array("h")
    samples.frombytes(frames[: len(frames) - (len(frames) % 2)])
    if not samples:
        return 0.0
    total = sum(s * s for s in samples)
    return math.sqrt(total / len(samples)) / 32768.0


def heard_wake_word(transcript: str, wake: str) -> tuple[bool, str]:
    """If `wake` is empty, always match. Otherwise match it near the start and
    return the remainder (the actual task). Returns (matched, task)."""
    text = transcript.strip()
    if not wake:
        return True, text
    idx = text.lower().find(wake.lower())
    if idx != -1 and idx <= 12:           # allow a little leading noise
        return True, text[idx + len(wake):].lstrip(" ,.:;!?-—")
    return False, ""
