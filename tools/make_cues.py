#!/usr/bin/env python3
"""Benji's own quiet cues, synthesised from plain sine tones (D-173, step 7).

Writes companion/Resources/Cues/*.wav (48 kHz, 16-bit, mono) and Cues/manifest.json. Standard
library only. Nothing here is sampled, traced or copied from any recording or any other product
(D-56): every sound is a few sine partials with a raised-cosine attack and an exponential
decay, as the design work wrote it down (the sound notes, D-61, D-65). The
notes, timings and levels are that document's; this script is the part that ships.

    python3 tools/make_cues.py            # write the files
    python3 tools/make_cues.py --check    # render again and say whether the files on disk are exactly these

The five cues, by meaning:
    listening-on   a short glide up        the microphone opened
    listening-off  the same, mirrored       the microphone closed
    done           two notes up a third     a job finished, or an answer arrived unspoken
    approval       the same note twice      something is waiting for the user's Yes or No
    error          two notes down, muted    something failed

Every file starts and ends on a sample of exactly zero, peaks at or below -18 dBFS and has no DC
offset (tests: selftest_quiet.py and CueFilesTests.swift measure them). Each variant of a cue is
gain-matched by momentary loudness (ITU-R BS.1770 K-weighting, 400 ms), so the variants differ only
in pitch by a little, never in meaning. No drawing sounds, no loops, no speech.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import struct
import sys
import wave
from pathlib import Path

SR = 48_000
PEAK_CEILING_DBFS = -18.0
HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "companion" / "Resources" / "Cues"

# ---- pitches: one small set, so cues that follow each other never clash --------------------------

_SEMIS = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3, "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}


def hz(name: str) -> float:
    letter, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((_SEMIS[letter] + 12 * (octave - 4)) / 12)


def shift(freq: float, semitones: float) -> float:
    return freq * 2 ** (semitones / 12)


# Timbres: (partial ratio, level in dB under the fundamental, decay-time scale). Round and
# fundamental-led, a little second harmonic, a faint short two-octave edge; the error cue has no edge.
TIMBRE = {
    "clear": [(1.0, 0.0, 1.0), (2.0, -18.0, 0.55), (4.0, -34.0, 0.18)],
    "round": [(1.0, 0.0, 1.0), (2.0, -16.0, 0.60), (3.0, -28.0, 0.40), (4.0, -33.0, 0.20)],
    "plain": [(1.0, 0.0, 1.0), (2.0, -17.0, 0.55), (3.0, -30.0, 0.35)],
    "felt": [(1.0, 0.0, 1.0), (2.0, -22.0, 0.50)],
}

DONE_BOUNCE_PEAK = 0.080     # the second note of Done lands where the checkmark's bounce peaks
OPEN_CONTENT_IN = 0.177      # the second note of Needs-approval lands as the card fades in
CONTENT_FADE_POINT = 0.085   # the second note of Error


def note(t_peak, f0, f1=None, glide=0.0, amp=1.0, attack=0.006, tau=0.1, timbre="round"):
    return {"t0": t_peak - attack, "f0": f0, "f1": f1 or f0, "glide": glide, "amp": amp, "attack": attack,
            "tau": tau, "partials": [(r, 10 ** (db / 20), ts) for r, db, ts in TIMBRE[timbre]]}


def specs() -> list[dict]:
    A4, Fs4, D5, Fs5, E5, A5 = (hz(x) for x in ("A4", "F#4", "D5", "F#5", "E5", "A5"))
    return [
        {"id": "listening-on", "name": "Listening on", "duration": 0.13, "fade": 0.02, "relative_db": -4.0,
         "variants": [[note(0.006, Fs5, A5, glide=0.060, tau=0.045, timbre="clear")],
                      [note(0.006, shift(Fs5, .35), shift(A5, .35), glide=0.050, tau=0.045, timbre="clear")]]},
        {"id": "listening-off", "name": "Listening off", "duration": 0.13, "fade": 0.02, "relative_db": -6.0,
         "variants": [[note(0.006, A5, Fs5, glide=0.060, tau=0.040, timbre="clear")],
                      [note(0.006, shift(A5, .35), shift(Fs5, .35), glide=0.050, tau=0.040, timbre="clear")]]},
        {"id": "done", "name": "Done", "duration": 0.52, "fade": 0.03, "relative_db": 0.0,
         "variants": [[note(0.006, shift(D5, st), amp=0.75, tau=0.090),
                       note(DONE_BOUNCE_PEAK, shift(Fs5, st), amp=1.0, tau=0.130)] for st in (0.0, 2.0, -2.0)]},
        {"id": "approval", "name": "Needs approval", "duration": 0.48, "fade": 0.03, "relative_db": 1.0,
         "variants": [[note(0.006, shift(E5, st), amp=0.85, tau=0.070, timbre="plain"),
                       note(OPEN_CONTENT_IN, shift(E5, st), amp=1.0, tau=0.100, timbre="plain")]
                      for st in (0.0, 2.0)]},
        {"id": "error", "name": "Error", "duration": 0.42, "fade": 0.03, "relative_db": -1.0,
         "variants": [[note(0.010, shift(A4, st), amp=0.85, attack=0.010, tau=0.080, timbre="felt"),
                       note(CONTENT_FADE_POINT, shift(Fs4, st), amp=1.0, attack=0.010, tau=0.120, timbre="felt")]
                      for st in (0.0, -2.0)]},
    ]


# ---- rendering --------------------------------------------------------------------------------

def _phase(tl: float, f0: float, f1: float, glide: float) -> float:
    """Cycles at time tl for a pitch that glides f0 -> f1 along a raised cosine over `glide` seconds."""
    if glide <= 0 or f0 == f1:
        return f0 * tl
    df = f1 - f0
    if tl < glide:
        return f0 * tl + df * (tl / 2 - glide / (2 * math.pi) * math.sin(math.pi * tl / glide))
    return f0 * tl + df * (glide / 2 + (tl - glide))


def render(cue: dict, notes: list, gain: float = 1.0) -> list[float]:
    count = int(round(cue["duration"] * SR))
    y = [0.0] * count
    for nt in notes:
        for i in range(count):
            tl = i / SR - nt["t0"]
            if tl < 0:
                continue
            cyc = _phase(tl, nt["f0"], nt["f1"], nt["glide"])
            att = 0.5 - 0.5 * math.cos(math.pi * tl / nt["attack"]) if tl < nt["attack"] else 1.0
            rest = max(tl - nt["attack"], 0.0)
            acc = 0.0
            for ratio, level, tscale in nt["partials"]:
                acc += level * att * math.exp(-rest / (nt["tau"] * tscale)) * math.sin(2 * math.pi * ratio * cyc)
            y[i] += nt["amp"] * acc
    fade = int(round(cue["fade"] * SR))
    for k in range(fade):                    # raised-cosine fade to exactly zero
        y[count - fade + k] *= 0.5 + 0.5 * math.cos(math.pi * (k + 1) / fade)
    return [v * gain for v in y]


# ITU-R BS.1770 K-weighting at 48 kHz; momentary loudness is a 400 ms window.
_K = [([1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585]),
      ([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])]


def _biquad(x: list[float], b, a) -> list[float]:
    out, x1, x2, y1, y2 = [], 0.0, 0.0, 0.0, 0.0
    for xi in x:
        yi = b[0] * xi + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
        out.append(yi)
        x2, x1, y2, y1 = x1, xi, y1, yi
    return out


def momentary_max_lufs(x: list[float]) -> float:
    win, hop = int(0.4 * SR), int(0.01 * SR)
    z = [0.0] * win + x + [0.0] * win
    for b, a in _K:
        z = _biquad(z, b, a)
    cum = [0.0]
    for v in z:
        cum.append(cum[-1] + v * v)
    best = max((cum[s + win] - cum[s]) / win for s in range(0, len(z) - win + 1, hop))
    return -0.691 + 10 * math.log10(max(best, 1e-20))


def to_pcm16(y: list[float], seed: int) -> list[int]:
    """TPDF dither of +-1 LSB so the quiet tails don't turn into truncation buzz; both ends stay 0."""
    rng = random.Random(seed)
    out = [max(-32768, min(32767, round(v * 32767 + (rng.random() - rng.random())))) for v in y]
    out[0] = out[-1] = 0
    return out


def build() -> dict[str, bytes]:
    """File name -> the bytes of that WAV, and 'manifest.json' -> its text."""
    cues = specs()
    reference = -30.0                        # Done at full gain sits here; the rest are relative to it
    for cue in cues:
        cue["gains"] = [10 ** ((reference + cue["relative_db"] - momentary_max_lufs(render(cue, v))) / 20)
                        for v in cue["variants"]]
    peak = max(max(abs(s) for s in render(c, v, g)) for c in cues for v, g in zip(c["variants"], c["gains"]))
    trim = min(0.0, PEAK_CEILING_DBFS - 0.5 - 20 * math.log10(peak))        # 0.5 dB left for the dither
    files: dict[str, bytes] = {}
    entries = []
    for ci, cue in enumerate(cues):
        names = []
        for vi, (notes, g) in enumerate(zip(cue["variants"], cue["gains"]), start=1):
            samples = to_pcm16(render(cue, notes, round(g * 10 ** (trim / 20), 6)), seed=1000 * ci + vi)
            name = f"benji-{cue['id']}-{vi}.wav"
            files[name] = _wav(samples)
            names.append(name)
        entries.append({"id": cue["id"], "name": cue["name"], "duration_ms": round(cue["duration"] * 1000), "files": names})
    files["manifest.json"] = (json.dumps({"sample_rate": SR, "peak_ceiling_dbfs": PEAK_CEILING_DBFS, "cues": entries},
                                         indent=1) + "\n").encode()
    return files


def _wav(samples: list[int]) -> bytes:
    import io
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    return buf.getvalue()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="say whether the files on disk are exactly what this renders")
    ap.add_argument("--out", type=Path, default=OUT, help="where to write (default: companion/Resources/Cues)")
    args = ap.parse_args(argv)
    files = build()
    if args.check:
        stale = [n for n, data in files.items() if not (args.out / n).is_file() or (args.out / n).read_bytes() != data]
        extra = sorted(p.name for p in args.out.glob("*") if p.is_file() and p.name not in files) if args.out.is_dir() else []
        if stale or extra:
            print(f"cues out of date: {', '.join(stale + extra)}; run tools/make_cues.py", file=sys.stderr)
            return 1
        print(f"{len(files) - 1} cue files match")
        return 0
    args.out.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (args.out / name).write_bytes(data)
    print(f"wrote {len(files) - 1} cue files and manifest.json to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
