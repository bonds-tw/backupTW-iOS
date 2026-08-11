#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
App icon generator for 有備而來 (bonds-tw / backupTW-iOS).

Direction: geometric reduction of the whitepaper's "小密封罐" metaphor.
The whole mark is two solid shapes -- a thick lid slab and a chamfered-shoulder
jar body -- held apart by a seal gap. No text, no outlines, no gradients on the
mark itself. Full-bleed square; iOS applies its own corner mask.

Drawn at 4096x4096 and LANCZOS-downsampled to 1024 (PIL's draw has no AA).

usage:  python3 make_icon_jar.py <output-dir>
"""

import math
import os
import sys

from PIL import Image, ImageDraw

# --------------------------------------------------------------------------- #
# output config
# --------------------------------------------------------------------------- #

NAME = "sealed-jar"
OUT_SIZE = 1024
SS = 4                          # supersample factor
S = OUT_SIZE * SS               # 4096
U = S / 1024.0                  # design units (1024-space) -> device pixels

# --------------------------------------------------------------------------- #
# palettes  (brand: ground/ink/accent from the bonds-tw site)
# --------------------------------------------------------------------------- #

PALETTES = {
    # pale ground, near-black jar, amber lid
    "light": {
        "bg_in":  "#F8F9F5",    # ground, lifted
        "bg_out": "#E3E8DF",    # ground, settled
        "body":   "#161C18",    # ink
        "lid":    "#9C6114",    # accent (honey / jar lid)
    },
    # dark surface, pale jar, brightened amber lid
    "dark": {
        "bg_in":  "#253029",
        "bg_out": "#101815",
        "body":   "#EDF0EA",
        "lid":    "#D28C2E",    # accent lifted for dark surfaces
    },
    # STRICT grayscale: separation is lightness-only, the system supplies hue
    "tinted": {
        "bg_in":  "#202020",
        "bg_out": "#0A0A0A",
        "body":   "#EDEDED",
        "lid":    "#A6A6A6",
    },
}

# --------------------------------------------------------------------------- #
# geometry, in 1024-space.
#
# Mark bbox: x 198..826 (61% wide), y 150..855 (69% tall). Centred on x, and
# riding 10 units above centre on y -- the body is the heavy element and sits
# low, so geometric centring reads as bottom-heavy. The worst-case corner of
# the body sits ~198px in from one edge and ~169px from the other, well clear
# of where the iOS squircle mask bites.
#
# Two shapes, six numbers between them:
#   lid     -- a thick slab, wider than the neck, narrower than the body
#   gap     -- the seal
#   body    -- vertical sides, chamfered shoulder, narrow neck
#
# The chamfered shoulder is doing the heavy lifting: a plain trapezoid + bar
# reads as a waste bin, and a bar floating over a wide flat top reads as a
# handbag handle. Sides that rise vertically and then cut in at ~52 degrees to
# a neck two-fifths the body width is the silhouette people file under "jar".
# --------------------------------------------------------------------------- #

CX = 512.0

# lid: a slab with a whisper of taper (honest at 1024, invisible at 60pt)
LID_TOP, LID_BOT = 150.0, 284.0
LID_HW_TOP, LID_HW_BOT = 250.0, 242.0
LID_R = 39.0

LID = [
    (CX - LID_HW_TOP, LID_TOP),
    (CX + LID_HW_TOP, LID_TOP),
    (CX + LID_HW_BOT, LID_BOT),
    (CX - LID_HW_BOT, LID_BOT),
]

# seal gap = 47 design units = 2.8pt on a 60pt icon (~8 device px at @3x).
# It survives the thumbnail, and even where it blurs the lid/body colour
# change carries the same message.
BODY_NECK_Y = 331.0            # = LID_BOT + 47
BODY_SHOULDER_Y = 449.0
BODY_BOT_Y = 855.0
BODY_HW_NECK = 160.0
BODY_HW_SHOULDER = 314.0
BODY_HW_BOT = 314.0            # sides perfectly vertical: a jar, not a pail
BODY_R = 58.0

BODY = [
    (CX - BODY_HW_BOT, BODY_BOT_Y),
    (CX - BODY_HW_SHOULDER, BODY_SHOULDER_Y),
    (CX - BODY_HW_NECK, BODY_NECK_Y),
    (CX + BODY_HW_NECK, BODY_NECK_Y),
    (CX + BODY_HW_SHOULDER, BODY_SHOULDER_Y),
    (CX + BODY_HW_BOT, BODY_BOT_Y),
]

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #


def hex_rgb(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def mix(a, b, t):
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    return (
        int(round(a[0] + (b[0] - a[0]) * t)),
        int(round(a[1] + (b[1] - a[1]) * t)),
        int(round(a[2] + (b[2] - a[2]) * t)),
    )


def smoothstep(t):
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    return t * t * (3.0 - 2.0 * t)


def background(c_in_hex, c_out_hex, grid=360):
    """Soft radial-plus-vertical wash, computed small and scaled up smoothly.

    Deliberately low-contrast: the background must never compete with the mark
    at 60pt, it only stops the icon reading as flat vinyl at 1024.
    """
    c_in = hex_rgb(c_in_hex)
    c_out = hex_rgb(c_out_hex)
    fx, fy = 0.50, 0.40                    # light source sits above centre
    px = []
    for j in range(grid):
        v = (j + 0.5) / grid
        lin = smoothstep((v - 0.02) / 0.96)
        for i in range(grid):
            u = (i + 0.5) / grid
            d = math.hypot(u - fx, (v - fy) * 0.92) / 0.80
            t = 0.72 * smoothstep(d) + 0.28 * lin
            px.append(mix(c_in, c_out, t))
    small = Image.new("RGB", (grid, grid))
    small.putdata(px)
    return small.resize((S, S), Image.BICUBIC)


def inset_convex(pts, d):
    """Offset every edge of a convex polygon inward by d; return new vertices."""
    n = len(pts)
    cx = sum(p[0] for p in pts) / n
    cy = sum(p[1] for p in pts) / n
    lines = []
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        L = math.hypot(dx, dy)
        if L < 1e-9:
            raise ValueError("degenerate edge in polygon")
        ux, uy = dx / L, dy / L
        nx, ny = -uy, ux
        mx, my = (x1 + x2) / 2.0, (y1 + y2) / 2.0
        if nx * (cx - mx) + ny * (cy - my) < 0.0:   # make the normal point inward
            nx, ny = -nx, -ny
        lines.append((x1 + nx * d, y1 + ny * d, ux, uy))

    out = []
    for i in range(n):
        ax, ay, aux, auy = lines[(i - 1) % n]
        bx, by, bux, buy = lines[i]
        den = bux * auy - aux * buy
        if abs(den) < 1e-9:                        # parallel: edges collinear
            out.append(((ax + bx) / 2.0, (ay + by) / 2.0))
            continue
        t = (bux * (by - ay) - buy * (bx - ax)) / den
        out.append((ax + t * aux, ay + t * auy))
    return out


def rounded_shape(draw, pts, radius, fill):
    """Convex polygon with uniformly rounded corners.

    Inset the outline by r, then dilate it back by r (fill + thick edges +
    corner discs) -- an exact Minkowski sum with a disc of radius r, which is
    precisely what "rounded corners" means. PIL has no rounded-polygon call.
    """
    r = int(round(radius))
    core = [(int(round(x)), int(round(y))) for x, y in inset_convex(pts, radius)]
    draw.polygon(core, fill=fill)
    if r <= 0:
        return
    n = len(core)
    for i in range(n):
        draw.line([core[i], core[(i + 1) % n]], fill=fill, width=2 * r)
    for (x, y) in core:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def scaled(pts):
    return [(x * U, y * U) for (x, y) in pts]


def build(pal):
    img = background(pal["bg_in"], pal["bg_out"])
    draw = ImageDraw.Draw(img)
    rounded_shape(draw, scaled(BODY), BODY_R * U, hex_rgb(pal["body"]))
    rounded_shape(draw, scaled(LID), LID_R * U, hex_rgb(pal["lid"]))
    return img.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS).convert("RGB")


# --------------------------------------------------------------------------- #


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: %s <output-dir>\n" % os.path.basename(sys.argv[0]))
        return 2
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    for variant in ("light", "dark", "tinted"):
        img = build(PALETTES[variant])
        path = os.path.join(out_dir, "%s-%s.png" % (NAME, variant))
        img.save(path, "PNG")
        print(path, img.size, img.mode)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
