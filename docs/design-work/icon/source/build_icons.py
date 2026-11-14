#!/usr/bin/env python3
"""Build every Benji icon SVG (Exchange, D-137) from one set of numbers.

Run from anywhere:  python3 docs/design-work/icon/source/build_icons.py
Writes into docs/design-work/icon/ (flat previews, layers/, benji.icon/, menu-bar glyphs).
Nothing else is touched. Edit the constants below, re-run, then re-render with render.js.

The mark: two thick rounded elbows on opposite corners of a square with equal gaps. The light
mint half is you, the deep mint half is Benji. The geometry below is the approved artwork in
the maintainer's icon directions, round 3, refined (drawn on the 1024 canvas, inside the tile);
the layers re-express it in Icon Composer's full-bleed 1024 space.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)  # docs/design-work/icon

# ---------------------------------------------------------------- grid
CANVAS = 1024          # macOS icon canvas
TILE_X = TILE_Y = 100  # rounded square origin on the canvas
TILE = 824             # rounded square size
RADIUS = 185.4         # continuous-corner radius of the macOS 26 / Big Sur grid
LAYER_SCALE = TILE / CANVAS  # layer art is drawn full-bleed 1024 and mapped onto the tile

# ---------------------------------------------------------------- the mark (canvas space, on the tile)
STROKE = 100           # elbow thickness
LO, HI = 316, 708      # the square's centre line (392 units, 60% of the tile width at 824)
CORNER = 130           # a corner's curve starts this far from the corner ...
HANDLE = 35            # ... and its control points sit this far from the corner
ARM_END = 560          # where each elbow's long arms stop; the gap is 48 units on both opposite corners
SHADOW = dict(dy=12, std=14, opacity=0.5)   # the flat previews' drop shadow (the system draws its own)


def elbow(corner):
    """The two elbows as canvas-space point lists: ('M', p) / ('V'|'H', n) / ('C', c1, c2, p)."""
    if corner == "you":    # top-left, light
        return [("M", (LO, ARM_END)), ("V", LO + CORNER),
                ("C", (LO, LO + HANDLE), (LO + HANDLE, LO), (LO + CORNER, LO)), ("H", ARM_END)]
    # benji: bottom-right, deep
    return [("M", (HI, 1024 - ARM_END)), ("V", HI - CORNER),
            ("C", (HI, HI - HANDLE), (HI - HANDLE, HI), (HI - CORNER, HI)), ("H", 1024 - ARM_END)]


# ---------------------------------------------------------------- colours per appearance
# Gradients run along each elbow in canvas space; (x1, y1, x2, y2).
GRAD = {"you": (316, 300, 600, 600), "benji": (440, 440, 720, 720)}
APPEARANCES = {
    # light half = you, deep half = Benji; tile = gradient black
    "default": dict(tile=("#151d1e", "#020303"), you=("#bdf6f1", "#66d4cf"),
                    benji=("#22c9bf", "#08968e"), benji_opacity=1.0),
    # the art is already made for dark; the dark appearance is the same icon
    "dark":    dict(tile=("#151d1e", "#020303"), you=("#bdf6f1", "#66d4cf"),
                    benji=("#22c9bf", "#08968e"), benji_opacity=1.0),
    # tinted: the grayscale input the system tints; light half white, deep half grey
    "tinted":  dict(tile=("#1c1c1c", "#050505"), you=("#ffffff", "#e6e6e6"),
                    benji=("#a8a8a8", "#8a8a8a"), benji_opacity=1.0),
    # clear (a preview of the glass look): white halves, the deep half at lower opacity
    "clear":   dict(tile=("#000000", "#000000"), you=("#ffffff", "#f2f2f2"),
                    benji=("#ffffff", "#ffffff"), benji_opacity=0.62),
}
# the solid the tinted input uses per layer (the system maps luminance to the user's tint)
TINT_SOLID = {"you": "#ffffff", "benji": "#999999"}
HAIRLINE = 0.09        # the tile's faint top edge (white opacity)

# ---------------------------------------------------------------- helpers
def fmt(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def to_layer(p):
    """Canvas point -> Icon Composer's full-bleed layer space (the tile fills the layer)."""
    x, y = p
    return (512 + (x - 512) / LAYER_SCALE, 512 + (y - 512) / LAYER_SCALE)


def path_d(segs, tx=lambda p: p):
    out = []
    for seg in segs:
        k = seg[0]
        if k == "M":
            x, y = tx(seg[1]); out.append(f"M{fmt(x)} {fmt(y)}")
        elif k == "V":   # straight arms: the transform is separable, so move one coordinate
            out.append(f"V{fmt(tx((0, seg[1]))[1])}")
        elif k == "H":
            out.append(f"H{fmt(tx((seg[1], 0))[0])}")
        else:
            pts = [tx(p) for p in seg[1:]]
            out.append("C" + " ".join(f"{fmt(a)} {fmt(b)}" for a, b in pts))
    return " ".join(out)


def _bez(p0, c1, c2, p1, t):
    u = 1 - t
    return tuple(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d
                 for a, b, c, d in zip(p0, c1, c2, p1))


def _bez_tan(p0, c1, c2, p1, t):
    u = 1 - t
    v = tuple(3 * u * u * (b - a) + 6 * u * t * (c - b) + 3 * t * t * (d - c)
              for a, b, c, d in zip(p0, c1, c2, p1))
    n = (v[0] ** 2 + v[1] ** 2) ** 0.5
    return (v[0] / n, v[1] / n)


ARC_K = 0.5522847498   # cubic fit of a quarter circle
OFFSET_SAMPLES = 24    # points along each offset of a corner; Hermite cubics join them


def stroke_outline(which, width, tx=lambda p: p):
    """The elbow's stroke (round caps) as one closed filled outline.

    Icon Composer fills the layer's path (it closes an open stroke with a chord), so the layers
    and previews use this outline, not a stroked centre line. Straight arms are exact; the corner
    offsets are sampled and joined with cubics (error far below a pixel at 1024).
    """
    segs = elbow(which)
    p0 = segs[0][1]
    arm1 = segs[1]
    cb = segs[2]
    arm2 = segs[3]
    horiz_first = arm1[0] == "H"
    p1 = (p0[0], arm1[1]) if arm1[0] == "V" else (arm1[1], p0[1])
    c1, c2, p2 = cb[1], cb[2], cb[3]
    p3 = (p2[0], arm2[1]) if arm2[0] == "V" else (arm2[1], p2[1])
    r = width / 2
    t0 = (p1[0] - p0[0], p1[1] - p0[1]); n0 = (t0[0] ** 2 + t0[1] ** 2) ** 0.5; t0 = (t0[0] / n0, t0[1] / n0)
    t3 = (p3[0] - p2[0], p3[1] - p2[1]); n3 = (t3[0] ** 2 + t3[1] ** 2) ** 0.5; t3 = (t3[0] / n3, t3[1] / n3)

    def side(pt, tan, sign):
        return (pt[0] + sign * r * -tan[1], pt[1] + sign * r * tan[0])

    def offset_curve(sign):
        pts = []
        for i in range(OFFSET_SAMPLES + 1):
            t = i / OFFSET_SAMPLES
            pts.append(side(_bez(p0=p1, c1=c1, c2=c2, p1=p2, t=t), _bez_tan(p1, c1, c2, p2, t), sign))
        return pts

    def hermite(pts, tin, tout):
        """Cubic pieces through pts; end tangents are the arm directions."""
        m = []
        for i, p in enumerate(pts):
            if i == 0:
                d = ((pts[1][0] - p[0]) ** 2 + (pts[1][1] - p[1]) ** 2) ** 0.5
                m.append((tin[0] * d, tin[1] * d))
            elif i == len(pts) - 1:
                d = ((p[0] - pts[-2][0]) ** 2 + (p[1] - pts[-2][1]) ** 2) ** 0.5
                m.append((tout[0] * d, tout[1] * d))
            else:
                m.append(((pts[i + 1][0] - pts[i - 1][0]) / 2, (pts[i + 1][1] - pts[i - 1][1]) / 2))
        out = []
        for i in range(len(pts) - 1):
            a, b = pts[i], pts[i + 1]
            out.append(("C", (a[0] + m[i][0] / 3, a[1] + m[i][1] / 3),
                        (b[0] - m[i + 1][0] / 3, b[1] - m[i + 1][1] / 3), b))
        return out

    def cap(pt, tan, frm_sign, forward):
        """Semicircle at pt from the +/- offset point round the tip (pt + r*tan if forward)."""
        n = (-tan[1], tan[0])
        s = frm_sign
        tip_dir = 1 if forward else -1
        A = (pt[0] + s * r * n[0], pt[1] + s * r * n[1])
        apex = (pt[0] + tip_dir * r * tan[0], pt[1] + tip_dir * r * tan[1])
        B = (pt[0] - s * r * n[0], pt[1] - s * r * n[1])
        k = ARC_K * r
        return [("C", (A[0] + tip_dir * k * tan[0], A[1] + tip_dir * k * tan[1]),
                 (apex[0] + s * k * n[0], apex[1] + s * k * n[1]), apex),
                ("C", (apex[0] - s * k * n[0], apex[1] - s * k * n[1]),
                 (B[0] + tip_dir * k * tan[0], B[1] + tip_dir * k * tan[1]), B)]

    left, right = offset_curve(+1), offset_curve(-1)
    path = [("M", side(p0, t0, +1)), ("L", side(p1, t0, +1))]
    path += hermite(left, t0, t3)
    path += [("L", side(p3, t3, +1))]
    path += cap(p3, t3, +1, True)
    path += [("L", side(p2, t3, -1))]
    path += hermite(right[::-1], (-t3[0], -t3[1]), (-t0[0], -t0[1]))
    path += [("L", side(p0, t0, -1))]
    path += cap(p0, (-t0[0], -t0[1]), +1, True)   # round the start: tip points back along -t0
    path.append(("Z",))
    out = []
    for seg in path:
        k = seg[0]
        if k == "Z":
            out.append("Z")
        elif k in ("M", "L"):
            x, y = tx(seg[1]); out.append(f"{k}{fmt(x)} {fmt(y)}")
        else:
            out.append("C" + " ".join(f"{fmt(a)} {fmt(b)}" for a, b in (tx(p) for p in seg[1:])))
    return " ".join(out)


def squircle_d(x, y, size, r):
    """Continuous-corner rounded square (Apple-style; PaintCode's published fit of
    UIBezierPath continuous corners). Corner reaches 1.5287 r along each edge."""
    X0, Y0, X1, Y1 = x, y, x + size, y + size

    def tr(a, b): return (X1 - a * r, Y0 + b * r)
    def br(a, b): return (X1 - b * r, Y1 - a * r)
    def bl(a, b): return (X0 + a * r, Y1 - b * r)
    def tl(a, b): return (X0 + b * r, Y0 + a * r)

    corner = [  # (kind, points) in corner-local coefficients, edge-start -> edge-end
        ("C", [(1.08849323, 0), (0.86840689, 0), (0.66993427, 0.065496)]),
        ("L", [(0.63149399, 0.074911)]),
        ("C", [(0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399)]),
        ("L", [(0.065496, 0.66993427)]),
        ("C", [(0, 0.86840701), (0, 1.08849299), (0, 1.52866483)]),
    ]
    parts = []
    start = tl(0, 1.52866483)  # (x0 + 1.5287 r, y0) on the top edge
    parts.append(f"M{fmt(start[0])} {fmt(start[1])}")
    for fn in (tr, br, bl, tl):
        p0 = fn(1.52866483, 0)
        parts.append(f"L{fmt(p0[0])} {fmt(p0[1])}")
        for kind, pts in corner:
            mapped = [fn(a, b) for a, b in pts]
            parts.append(kind + " ".join(f"{fmt(px)} {fmt(py)}" for px, py in mapped))
    parts.append("Z")
    return " ".join(parts)


def lin_grad(gid, x1, y1, x2, y2, c0, c1, tx=lambda p: p):
    (x1, y1), (x2, y2) = tx((x1, y1)), tx((x2, y2))
    return (f'<linearGradient id="{gid}" x1="{fmt(x1)}" y1="{fmt(y1)}" x2="{fmt(x2)}" y2="{fmt(y2)}" '
            f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{c0}"/>'
            f'<stop offset="1" stop-color="{c1}"/></linearGradient>')


def svg(w, h, body, title=None):
    t = f"\n  <title>{title}</title>" if title else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">{t}\n'
            + body + "\n</svg>\n")


def write(rel, text):
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)
    print("wrote", rel)


def elbow_path(which, gid, opacity=1.0, tx=to_layer):
    op = f' fill-opacity="{opacity:g}"' if opacity != 1.0 else ""
    return f'<path d="{stroke_outline(which, STROKE, tx)}" fill="url(#{gid})"{op}/>'


def mark_defs(c):
    """The two elbow gradients in layer space (the previews and layers share them)."""
    return (lin_grad("a", *GRAD["you"], *c["you"], tx=to_layer)
            + lin_grad("b", *GRAD["benji"], *c["benji"], tx=to_layer))


SQ = squircle_d(TILE_X, TILE_Y, TILE, RADIUS)
SQ_EDGE = squircle_d(TILE_X + 1.5, TILE_Y + 1.5, TILE - 3, RADIUS - 1.5)
GROUP = f'translate({TILE_X} {TILE_Y}) scale({LAYER_SCALE})'

# ---------------------------------------------------------------- flat app-icon previews
names = {"default": "benji-app-icon.svg", "dark": "benji-app-icon-dark.svg",
         "tinted": "benji-app-icon-tinted.svg"}
titles = {"default": "Benji app icon (default appearance)",
          "dark": "Benji app icon (dark appearance; the same art as default)",
          "tinted": "Benji app icon (tinted appearance: grayscale input the system tints)"}
sh = SHADOW
shadow_filter = (f'<filter id="s" x="-20%" y="-20%" width="140%" height="150%">'
                 f'<feDropShadow dx="0" dy="{fmt(sh["dy"] / LAYER_SCALE)}" stdDeviation="{fmt(sh["std"] / LAYER_SCALE)}" '
                 f'flood-color="#000" flood-opacity="{sh["opacity"]:g}"/></filter>')
for key in ("default", "dark", "tinted"):
    c = APPEARANCES[key]
    body = (f"  <defs>{lin_grad('t', 0, TILE_Y, 0, TILE_Y + TILE, *c['tile'])}"
            f"{mark_defs(c)}{shadow_filter}</defs>\n"
            "  <!-- macOS grid: 824 x 824 continuous-corner square (r 185.4) at 100,100; gradient black -->\n"
            f'  <path d="{SQ}" fill="url(#t)"/>\n'
            f'  <path d="{SQ_EDGE}" fill="none" stroke="#ffffff" stroke-opacity="{HAIRLINE}" stroke-width="3"/>\n'
            "  <!-- layer art is 1024 full-bleed, mapped onto the tile -->\n"
            f'  <g transform="{GROUP}" filter="url(#s)">\n'
            f'    {elbow_path("you", "a")}\n'
            f'    {elbow_path("benji", "b")}\n'
            "  </g>")
    write(names[key], svg(CANVAS, CANVAS, body, titles[key]))

# Clear: an approximation of the system's clear (glass) look, for previews only.
c = APPEARANCES["clear"]
clear_body = (
    f"  <defs>{mark_defs(c)}{shadow_filter}</defs>\n"
    "  <!-- preview approximation: the system draws the clear appearance itself -->\n"
    f'  <path d="{SQ}" fill="#ffffff" fill-opacity="0.2"/>\n'
    f'  <path d="{SQ_EDGE}" fill="none" stroke="#ffffff" stroke-opacity="0.45" stroke-width="3"/>\n'
    f'  <g transform="{GROUP}" filter="url(#s)">\n'
    f'    {elbow_path("you", "a")}\n'
    f'    {elbow_path("benji", "b", c["benji_opacity"])}\n'
    "  </g>")
write("benji-app-icon-clear.svg", svg(CANVAS, CANVAS, clear_body,
                                       "Benji app icon (clear appearance, preview approximation)"))

# ---------------------------------------------------------------- layers (for Icon Composer)
d = APPEARANCES["default"]
layer_you = svg(CANVAS, CANVAS, f"  <defs>{lin_grad('a', *GRAD['you'], *d['you'], tx=to_layer)}</defs>\n"
                f'  {elbow_path("you", "a")}')
layer_benji = svg(CANVAS, CANVAS, f"  <defs>{lin_grad('b', *GRAD['benji'], *d['benji'], tx=to_layer)}</defs>\n"
                   f'  {elbow_path("benji", "b")}')
layer_bg = svg(CANVAS, CANVAS,
               f"  <defs>{lin_grad('t', 0, 0, 0, CANVAS, *d['tile'], tx=lambda p: p)}</defs>\n"
               "  <!-- Optional. benji.icon uses its document fill (a gradient black) instead. "
               "Full bleed: the system applies the icon shape. -->\n"
               f'  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#t)"/>')
for folder in ("layers", "benji.icon/Assets"):
    write(f"{folder}/elbow-you.svg", layer_you)
    write(f"{folder}/elbow-benji.svg", layer_benji)
write("layers/background.svg", layer_bg)


def ext_srgb(hexc):
    r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def gradient_fill(pair):
    # the tile's gradient runs top to bottom, as in the previews (y 100 -> 924 of 1024)
    return {"linear-gradient": [ext_srgb(pair[0]), ext_srgb(pair[1])],
            "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}}}


def layer(name, image, key, opacity_by_appearance):
    tinted = TINT_SOLID[key]
    return {
        "image-name": image, "name": name, "glass": True,
        # the default art carries its own gradient; only the tinted input is overridden, with
        # a solid grey the system maps to the user's tint (the clear appearance is system glass)
        "fill-specializations": [{"appearance": "tinted", "value": {"solid": ext_srgb(tinted)}}],
        "opacity-specializations": [
            {"value": opacity_by_appearance["default"]},
            {"appearance": "dark", "value": opacity_by_appearance["dark"]},
            {"appearance": "tinted", "value": opacity_by_appearance["tinted"]},
        ],
    }


A = APPEARANCES
icon_json = {
    "fill-specializations": [
        {"value": gradient_fill(A["default"]["tile"])},
        {"appearance": "dark", "value": gradient_fill(A["dark"]["tile"])},
        {"appearance": "tinted", "value": gradient_fill(A["tinted"]["tile"])},
    ],
    "groups": [  # front to back (assumed Icon Composer order: first = topmost)
        {
            "name": "Benji",
            "layers": [layer("elbow-benji", "elbow-benji.svg", "benji",
                             {k: A[k]["benji_opacity"] for k in ("default", "dark", "tinted")})],
            "lighting": "combined",
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.0},
            "specular": True,
        },
        {
            "name": "You",
            "layers": [layer("elbow-you", "elbow-you.svg", "you", {"default": 1.0, "dark": 1.0, "tinted": 1.0})],
            "lighting": "combined",
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.0},
            "specular": True,
        },
    ],
    "supported-platforms": {"squares": ["macOS"]},
}
write("benji.icon/icon.json", json.dumps(icon_json, indent=2) + "\n")

# ---------------------------------------------------------------- menu-bar glyphs (18 x 18 pt template)
# The same two elbows on an 11.5 pt box (3.25 .. 14.75), 1.75 pt stroke, one ink. While Benji is
# busy with a turn the halves close into one rounded square (a swap, not an animation).
GBOX, GX0, GSTROKE, GCLOSED_R = 11.5, 3.25, 1.75, 3.6
K = GBOX / (HI - LO)   # the icon's square, scaled into the glyph box


def to_glyph(p):
    x, y = p
    return (GX0 + (x - LO) * K, GX0 + (y - LO) * K)


def glyph_path_d():
    return [path_d(elbow(which), to_glyph) for which in ("you", "benji")]


G_COMMON = f'fill="none" stroke="#000000" stroke-width="{GSTROKE:g}"'
idle_paths = "".join(f'<path d="{d}"/>' for d in glyph_path_d())
write("benji-menubar-glyph.svg", svg(
    18, 18,
    f'  <g {G_COMMON} stroke-linecap="round" stroke-linejoin="round">{idle_paths}</g>',
    "Benji menu-bar glyph, idle (template image: single ink, macOS tints it)"))
write("benji-menubar-glyph-working.svg", svg(
    18, 18,
    f'  <rect x="{GX0:g}" y="{GX0:g}" width="{GBOX:g}" height="{GBOX:g}" rx="{GCLOSED_R:g}" {G_COMMON}/>',
    "Benji menu-bar glyph, working (halves closed; template image)"))
