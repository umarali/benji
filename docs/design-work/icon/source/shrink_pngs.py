#!/usr/bin/env python3
"""Losslessly re-compress the render sheets (zlib level 9). Palette quantising was tried and
dropped: it banded the icon's gradients, which is exactly what the sheets check.
Run after render.js:  python3 docs/design-work/icon/source/shrink_pngs.py"""
import glob, os
from PIL import Image
for p in sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "renders", "*.png"))):
    before = os.path.getsize(p)
    Image.open(p).convert("RGB").save(p, optimize=True, compress_level=9)
    print(f"{os.path.basename(p)}: {before // 1024} KB -> {os.path.getsize(p) // 1024} KB")
