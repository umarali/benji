# MicMeter

Four level bars beside the mic glyph while the microphone is on, driven by the real input level.

**Consumer provides:** a level from 0 to 1, computed from each audio buffer's RMS on a −50 to 0 dB scale (`MicLevel.normalized`).

**Use**
- Bars in `state-listening`, `radius-pill` ends, 3 pt wide and 2 pt apart, 3 to 14 pt tall in a fixed profile (0.55, 1.0, 0.8, 0.5 of the level): one real level, never independent bars.
- Smooth the level with a 35 ms attack and 140 ms release; redraw only when it changes by more than 1%, at most 48 fps.
- Fade in when the mic starts and out (`motion-fade`) the same frame it stops.
- The speaking meter is the same four bars in `benji-mint`, driven by the speech output level; with no level available, show the static `waveform` glyph instead.
- Under Reduce Motion, show a static level updated at most 4 times a second.

**Don't** animate bars when there's no input, or show them in any colour but `state-listening`: orange means the mic is on.
