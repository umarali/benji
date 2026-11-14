# Logos

Final artwork: the Exchange app icon and menu-bar glyphs (D-137, 2026-11-02, replacing Pebble v2) and the drawn wordmark (D-58). The app icon's sources live in the repo under `docs/design-work/icon/`.

**App icon** (1024 canvas, 824 × 824 continuous-corner tile at 100, 100, radius 185.4)
- The mark: two thick rounded elbows on opposite corners of a square, with equal gaps (48 units, about half a stroke). The light mint half is you (`#bdf6f1` to `#66d4cf`), the deep mint half is Benji (`#22c9bf` to `#08968e`). The mark spans 60% of the tile, on a gradient black tile (`#151d1e` to `#020303`, top to bottom).
- `benji-app-icon.svg`: default appearance.
- `benji-app-icon-dark.svg`: dark appearance; the art is already made for dark, so it is the same icon.
- `benji-app-icon-tinted.svg`: tinted input (light half white, deep half grey); macOS applies the tint.
- `benji-app-icon-clear.svg`: an approximation of the clear look for documentation only (white halves, the deep half at 62%); the real one comes from the system.
- The shipping icon is the layered `benji.icon` bundle built from the same numbers: one layer per elbow, compiled by `companion/make_icon.sh`.

**Menu-bar glyphs** (18 × 18 pt, single ink **black `#000000`**; use them as template images so macOS tints them; never colour them)
- `benji-menubar-glyph.svg`: idle. The two elbows, 1.75 pt stroke in an 11.5 pt box.
- `benji-menubar-glyph-working.svg`: while Benji is busy with a turn (listening, transcribing, working, speaking or awaiting approval) the halves close into one rounded square. A swap on a real event, not an animation.

**Wordmark** (lowercase "benji", custom-drawn, no font)
- `benji-wordmark.svg`: ink `#1d1d1f`, for light grounds.
- `benji-wordmark-dark.svg`: ink white at 0.92, for dark grounds.
- `benji-wordmark-mint.svg`: ink `benji-mint` `#66d4cf`, for `notch-black` and `notch-raised` only. Never on light grounds (1.8:1).
- `hey-benji-lockup.svg` / `hey-benji-lockup-dark.svg`: "Hey" + the wordmark, inks as above. In running text the phrase is always "Hey Benji".
- Clear space: 0.5 × the wordmark's x-height on every side. Minimum size: wordmark 48 px wide, lockup 120 px wide.

**Don't** set the name in a font and call it the wordmark, recolour or outline the marks, add glows or glass to the wordmark or the menu-bar glyphs, animate them, or swap a letter for a symbol.
