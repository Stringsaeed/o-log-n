#!/usr/bin/env python3
"""Draws Logn's app icon as an Icon Composer document: Support/AppIcon.icon.

The icon is a pen-and-ink drawing: a hatched ground, cross-hatched where it is
in shade, the two jaws left as bare paper inside an ink outline, and the gem in
blue ink. Icon Composer supplies the rounded shape, its edge and its shadow, so
the document holds only the drawing.

Every line is written out as plain geometry (no patterns, clips or filters), so
the result does not depend on which SVG features a renderer supports. The pen
wobble is baked into the points and is seeded, so the output is reproducible.

Run from the repository root:

    python3 scripts/make-icon.py        # writes Support/AppIcon.icon and assets/icon.svg
    scripts/make-icon-previews.sh       # refreshes the fallback .icns and the README image

scripts/bundle.sh compiles the document into the app with actool. The document
also opens in Icon Composer (Xcode > Open Developer Tool > Icon Composer), where
each layer's colour can be changed per appearance without redrawing anything.
"""
import json
import math
import os
import sys

SIZE = 1024

# Every layer is a single-colour shape; its colour is set per appearance in
# icon.json, so each one can be re-inked in Icon Composer without redrawing.
#   default  ink on paper
#   dark     the same drawing in chalk on a dark sheet
#   tinted   used by the tinted and clear modes, where brightness becomes
#            opacity: the jaws and gem stay solid, the hatching recedes
PAPER = {"default": "#f4f1e8", "dark": "#16150f"}
INK = {"default": "#17160f", "dark": "#ece8dc", "tinted": "#000000"}
HATCH = {"default": "#17160f", "dark": "#ece8dc", "tinted": "#7a7a7a"}
BODY = {"default": "#f4f1e8", "dark": "#16150f", "tinted": "#ffffff"}
GEM = {"default": "#1c3fb8", "dark": "#a3b8ff", "tinted": "#ffffff"}


def rng(seed):
    state = [seed]

    def nxt():
        state[0] = (state[0] * 16807) % 2147483647
        return state[0] / 2147483647

    return nxt


def cubic(p0, p1, p2, p3, t):
    u = 1 - t
    return (
        u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
        u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1],
    )


def boundary(p0, p1, p2, p3):
    """y of a left-to-right cubic at any x, by sampling."""
    pts = [cubic(p0, p1, p2, p3, i / 200) for i in range(201)]

    def y_at(x):
        if x <= pts[0][0]:
            return pts[0][1]
        for a, b in zip(pts, pts[1:]):
            if a[0] <= x <= b[0]:
                f = 0 if b[0] == a[0] else (x - a[0]) / (b[0] - a[0])
                return a[1] + (b[1] - a[1]) * f
        return pts[-1][1]

    return y_at


# Where the ground falls into shade: below this curve it is cross-hatched…
SHADE = boundary((-40, 700), (360, 930), (760, 640), (1064, 150))
# …and below this one, in the corner, a second pass of strokes deepens it.
DEEP = boundary((430, 1064), (760, 1050), (960, 880), (1064, 600))


def everywhere(x, y):
    return True


def in_shade(x, y):
    return y > SHADE(x)


def in_deep(x, y):
    return y > DEEP(x)


def hatch(angle_deg, spacing, width, inside, seed, shift=0.0, wobble=2.4, width_jitter=0.2, gap_jitter=0.12):
    """Ruled strokes at an angle, kept where `inside` holds. Returns SVG paths."""
    rnd = rng(seed)
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)  # along the stroke
    nx, ny = -dy, dx  # across strokes
    reach = SIZE * 1.5
    out = []
    offset = -reach + shift
    while offset < reach:
        offset += spacing * (1 + (rnd() - 0.5) * 2 * gap_jitter)
        w = width * (1 + (rnd() - 0.5) * 2 * width_jitter)
        phase, freq = rnd() * 6.28, 0.004 + rnd() * 0.004
        run = []
        runs = []
        step = 16
        s = -reach
        while s <= reach:
            # A slow sine wobble, different on every stroke: a hand, not a ruler.
            drift = math.sin(s * freq + phase) * wobble
            x = SIZE / 2 + dx * s + nx * (offset + drift)
            y = SIZE / 2 + dy * s + ny * (offset + drift)
            ok = -30 <= x <= SIZE + 30 and -30 <= y <= SIZE + 30 and inside(x, y)
            if ok:
                run.append((x, y))
            elif run:
                runs.append(run)
                run = []
            s += step
        if run:
            runs.append(run)
        for r in runs:
            if len(r) < 3:
                continue
            d = "M" + "L".join(f"{x:.1f} {y:.1f}" for x, y in r)
            out.append(f'<path d="{d}" stroke-width="{w:.1f}"/>')
    return out


def svg(body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">\n'
        + body
        + "\n</svg>\n"
    )


def ground():
    strokes = (
        hatch(-45, 36, 10.5, everywhere, seed=7)
        + hatch(45, 36, 10.5, in_shade, seed=23)
        # The deepest corner: a second pass of each direction, between the first.
        + hatch(-45, 36, 9, in_deep, seed=41, shift=18)
        + hatch(45, 36, 9, in_deep, seed=59, shift=18)
    )
    return svg('<g fill="none" stroke="#000" stroke-linecap="round" stroke-linejoin="round">\n' + "\n".join(strokes) + "\n</g>")


# The two jaws: tips at 0.30 / 0.70 of the canvas, waists at 0.44 / 0.56,
# running from 0.28 to 0.72 down it. The menu-bar glyph (StatusGlyph in
# Sources/OLogNApp/Views/Tokens.swift) is the same figure at its own scale.
def jaw(mirror):
    tip, waist = (0.70, 0.56) if mirror else (0.30, 0.44)
    p = [(tip, 0.28), (waist, 0.40), (waist, 0.60), (tip, 0.72)]
    q = [(x * SIZE, y * SIZE) for x, y in p]
    return f"M{q[0][0]:.0f} {q[0][1]:.0f}C{q[1][0]:.0f} {q[1][1]:.0f} {q[2][0]:.0f} {q[2][1]:.0f} {q[3][0]:.0f} {q[3][1]:.0f}"


JAWS = jaw(False) + jaw(True)


def jaw_line():
    return svg(f'<path d="{JAWS}" fill="none" stroke="#000" stroke-width="150" stroke-linecap="round"/>')


def jaw_body():
    return svg(f'<path d="{JAWS}" fill="none" stroke="#000" stroke-width="94" stroke-linecap="round"/>')


def gem_path(grow):
    cx, cy, w, h = SIZE / 2, SIZE / 2, 78 + grow, 116 + grow * 1.45
    return f"M{cx:.0f} {cy - h:.0f}L{cx + w:.0f} {cy:.0f}L{cx:.0f} {cy + h:.0f}L{cx - w:.0f} {cy:.0f}Z"


def gem_line():
    return svg(f'<path d="{gem_path(0)}" fill="#000" stroke="#000" stroke-width="26" stroke-linejoin="round"/>')


def gem_body():
    return svg(f'<path d="{gem_path(-2)}" fill="#000"/>')


def rgb(hex_colour):
    h = hex_colour.lstrip("#")
    r, g, b = (int(h[i : i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def fills(colours):
    """The default first, then one entry per appearance that differs."""
    out = [{"value": {"solid": rgb(colours["default"])}}]
    for appearance in ("dark", "tinted"):
        if appearance in colours:
            out.append({"appearance": appearance, "value": {"solid": rgb(colours[appearance])}})
    return out


# name, file stem, drawing, colours. Listed front to back.
LAYERS = [
    ("Gem", "gem", gem_body, GEM),
    ("Gem outline", "gem-line", gem_line, INK),
    ("Jaws", "jaws", jaw_body, BODY),
    ("Jaws outline", "jaws-line", jaw_line, INK),
]
GROUND = ("Hatching", "hatching", ground, HATCH)


def layer(name, stem, colours):
    # glass is off: this is a flat ink drawing, and Liquid Glass highlights on
    # the strokes would fight it. The system still shapes and lights the icon.
    return {"name": name, "image-name": f"{stem}.svg", "glass": False, "fill-specializations": fills(colours)}


def document():
    return {
        "fill-specializations": fills(PAPER),
        "groups": [
            {
                "name": "Mark",
                "layers": [layer(n, s, c) for n, s, _, c in LAYERS],
                "shadow": {"kind": "neutral", "opacity": 0.25},
                "translucency": {"enabled": False, "value": 0.5},
            },
            {
                "name": "Ground",
                "layers": [layer(GROUND[0], GROUND[1], GROUND[3])],
                "shadow": {"kind": "neutral", "opacity": 0},
                "translucency": {"enabled": False, "value": 0.5},
            },
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }


def inner(drawing):
    """The body of a layer's SVG, without its <svg> wrapper."""
    text = drawing()
    return text[text.index(">") + 1 : text.rindex("</svg>")].strip()


def flat_svg():
    """One flat SVG of the default appearance, for READMEs and the web."""
    radius = SIZE * 0.225
    parts = [f'<rect width="{SIZE}" height="{SIZE}" fill="{PAPER["default"]}"/>']
    for _, _, draw, colours in [GROUND] + LAYERS[::-1]:
        parts.append(inner(draw).replace("#000", colours["default"]))
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">\n'
        f'<clipPath id="shape"><rect width="{SIZE}" height="{SIZE}" rx="{radius:.0f}"/></clipPath>\n'
        f'<g clip-path="url(#shape)">\n' + "\n".join(parts) + "\n</g>\n</svg>\n"
    )


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    doc = os.path.join(root, "Support", "AppIcon.icon")
    assets = os.path.join(doc, "Assets")
    os.makedirs(assets, exist_ok=True)
    for _, stem, draw, _ in LAYERS + [GROUND]:
        with open(os.path.join(assets, f"{stem}.svg"), "w") as f:
            f.write(draw())
    with open(os.path.join(doc, "icon.json"), "w") as f:
        json.dump(document(), f, indent=2)
        f.write("\n")
    os.makedirs(os.path.join(root, "assets"), exist_ok=True)
    with open(os.path.join(root, "assets", "icon.svg"), "w") as f:
        f.write(flat_svg())
    print(doc)


if __name__ == "__main__":
    main()
