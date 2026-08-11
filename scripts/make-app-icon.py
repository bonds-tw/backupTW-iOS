#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
App icon generator for 有備而來 (bonds-tw / backupTW-iOS).

The mark is the whitepaper's 小密封罐 seen head-on: a wide amber screw band
clamped down onto a glass jar, with a single person mark held inside the glass.
Identity, sealed shut, carried on the body -- nothing leaks, nothing phones home.

Usage:   python3 sealed_jar_icon.py <output-dir>
Writes:  bonds-sealed-jar-light.png
         bonds-sealed-jar-dark.png
         bonds-sealed-jar-tinted.png    (greyscale; iOS supplies the tint)

Each file is 1024x1024 RGB with no alpha and no rounded corners -- the artwork
runs full bleed and iOS applies its own mask. Everything is drawn at 4096x4096
and LANCZOS-downsampled, because ImageDraw has no antialiasing of its own.
Standard library + Pillow only; no external files, no fonts, no text.
"""

import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

try:  # Pillow >= 9.1
    LANCZOS = Image.Resampling.LANCZOS
    BICUBIC = Image.Resampling.BICUBIC
except AttributeError:  # pragma: no cover - older Pillow
    LANCZOS = Image.LANCZOS
    BICUBIC = Image.BICUBIC

NAME = "bonds-sealed-jar"
SIZE = 1024
SS = 4                 # supersample factor
BIG = SIZE * SS        # 4096

# ---------------------------------------------------------------------------
# Geometry, in final 1024-pt units (multiplied by SS at draw time).
# The mark spans y 118..906 and x 224..800: 118u of air top and bottom, 224u
# left and right, so nothing comes near the corners the squircle bites off.
# ---------------------------------------------------------------------------

CX = 512.0

NECK_HW = 191.0        # half-width of the glass neck
BODY_HW = 288.0        # half-width of the jar body
NECK_TOP = 230.0       # tucked up under the band
NECK_BOT = 385.0       # where the shoulder begins to flare
SHOULDER_BOT = 474.0   # where the body reaches full width
BODY_BOT = 906.0
BASE_R = 110.0         # base fillet
SHOULDER_RX = BODY_HW - NECK_HW        # 97
SHOULDER_RY = SHOULDER_BOT - NECK_BOT  # 89

LID_HW = 248.0         # the screw band
LID_TOP = 118.0
LID_BOT = 287.0
LID_R = 49.0           # top corners only; the bottom edge is squared off

RING_HW = 220.0        # lit rim peeking out from under the band
RING_TOP = 236.0
RING_BOT = 317.0
RING_R = 25.0

HEAD_CY = 550.0        # the person mark sealed inside the glass
HEAD_R = 74.0
BUST_RX = 178.0
BUST_RY = 155.0
BUST_BASE = 817.0      # flat bottom of the shoulders

GLEAM_BOX = (260.0, 448.0, 315.0, 756.0)   # glass highlight down the left wall
GLEAM_R = 27.0
GLEAM_BLUR = 14.0

GLOW_RX, GLOW_RY = 382.0, 350.0            # warm halo behind the jar
GLOW_CY = 506.0
GLOW_BLUR = 150.0

SHADOW_DY = 22.0                           # contact shadow
SHADOW_BLUR = 26.0

ARC_STEPS = 120
BUST_STEPS = 200


def hexc(s):
    """'#RRGGBB' -> (r, g, b)."""
    return (int(s[1:3], 16), int(s[3:5], 16), int(s[5:7], 16))


# ---------------------------------------------------------------------------
# Palettes. light/dark use the bonds-tw site tokens (ground / ink / ink-soft /
# accent / accent-bg and the dark surfaces). tinted is strictly greyscale, so
# the separation is carried by value alone and survives iOS recolouring it.
# ---------------------------------------------------------------------------

PALETTES = {
    "light": {
        "bg_top": hexc("#F7F8F5"),
        "bg_bot": hexc("#E3E8E0"),
        "glow": hexc("#F3E7D4"), "glow_a": 0.60,
        "shadow": hexc("#161C18"), "shadow_a": 0.17,
        "jar": hexc("#161C18"),
        "gleam": hexc("#4C564F"), "gleam_a": 0.60,
        "glyph": hexc("#F3E7D4"),
        "ring": hexc("#C98A34"),
        "lid": hexc("#9C6114"),
    },
    "dark": {
        "bg_top": hexc("#212C28"),
        "bg_bot": hexc("#141C19"),
        "glow": hexc("#33291B"), "glow_a": 0.85,
        "shadow": hexc("#080C0A"), "shadow_a": 0.45,
        "jar": hexc("#F0E4D0"),
        "gleam": hexc("#FFFCF5"), "gleam_a": 0.75,
        "glyph": hexc("#1A2320"),
        "ring": hexc("#E0A458"),
        "lid": hexc("#C0781A"),
    },
    "tinted": {
        "bg_top": hexc("#242424"),
        "bg_bot": hexc("#101010"),
        "glow": hexc("#333333"), "glow_a": 0.70,
        "shadow": hexc("#000000"), "shadow_a": 0.45,
        "jar": hexc("#A6A6A6"),
        "gleam": hexc("#D2D2D2"), "gleam_a": 0.60,
        "glyph": hexc("#2E2E2E"),
        "ring": hexc("#FFFFFF"),
        "lid": hexc("#E8E8E8"),
    },
}


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

def ell_arc(cx, cy, rx, ry, a0, a1, steps=ARC_STEPS):
    """Points along an elliptical arc. Degrees, 0 deg = 3 o'clock, y grows down.

    Sweep direction matters: pick endpoints that keep the arc inside the
    quadrant you want, otherwise the outline folds back and self-intersects."""
    pts = []
    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * float(i) / steps)
        pts.append((cx + rx * math.cos(a), cy + ry * math.sin(a)))
    return pts


def jar_outline(dy=0.0):
    """Closed silhouette: neck -> flared shoulder -> straight body -> round base."""
    pts = [(CX - NECK_HW, NECK_TOP + dy)]
    # left shoulder, bulging outward (top-left quadrant, 270 -> 180)
    pts += ell_arc(CX - NECK_HW, SHOULDER_BOT + dy, SHOULDER_RX, SHOULDER_RY, 270, 180)
    # bottom-left fillet (180 -> 90)
    pts += ell_arc(CX - BODY_HW + BASE_R, BODY_BOT - BASE_R + dy, BASE_R, BASE_R, 180, 90)
    # bottom-right fillet (90 -> 0)
    pts += ell_arc(CX + BODY_HW - BASE_R, BODY_BOT - BASE_R + dy, BASE_R, BASE_R, 90, 0)
    # right shoulder (top-right quadrant, 0 -> -90). Writing 0 -> 270 here would
    # sweep the long way round and fold the polygon back through the body.
    pts += ell_arc(CX + NECK_HW, SHOULDER_BOT + dy, SHOULDER_RX, SHOULDER_RY, 0, -90)
    pts.append((CX + NECK_HW, NECK_TOP + dy))
    return pts


def bust_outline():
    """Half-ellipse closed by a flat bottom -- shoulders of the person mark."""
    return ell_arc(CX, BUST_BASE, BUST_RX, BUST_RY, 180, 360, BUST_STEPS)


def scaled(pts, k):
    return [(x * k, y * k) for (x, y) in pts]


def big_mask():
    return Image.new("L", (BIG, BIG), 0)


def soft_mask(paint, blur):
    """Draw at 1024, blur, then upscale -- soft shapes carry no high frequencies,
    and blurring 1M pixels instead of 16.7M keeps this quick."""
    m = Image.new("L", (SIZE, SIZE), 0)
    paint(ImageDraw.Draw(m))
    if blur > 0:
        m = m.filter(ImageFilter.GaussianBlur(blur))
    return m.resize((BIG, BIG), BICUBIC)


def fade(mask, alpha):
    return mask.point([int(round(i * alpha)) for i in range(256)])


def vgrad(c_top, c_bot):
    """Full-bleed vertical background ramp."""
    strip = Image.new("RGB", (1, 512))
    px = strip.load()
    for i in range(512):
        t = i / 511.0
        px[0, i] = (
            int(round(c_top[0] + (c_bot[0] - c_top[0]) * t)),
            int(round(c_top[1] + (c_bot[1] - c_top[1]) * t)),
            int(round(c_top[2] + (c_bot[2] - c_top[2]) * t)),
        )
    return strip.resize((BIG, BIG), BICUBIC)


def build_masks():
    """Geometry is identical across the three variants, so build it once."""
    m = {}

    jar = big_mask()
    ImageDraw.Draw(jar).polygon(scaled(jar_outline(), SS), fill=255)
    m["jar"] = jar

    glyph = big_mask()
    dg = ImageDraw.Draw(glyph)
    dg.ellipse(
        [(CX - HEAD_R) * SS, (HEAD_CY - HEAD_R) * SS,
         (CX + HEAD_R) * SS, (HEAD_CY + HEAD_R) * SS],
        fill=255,
    )
    dg.polygon(scaled(bust_outline(), SS), fill=255)
    m["glyph"] = glyph

    ring = big_mask()
    ImageDraw.Draw(ring).rounded_rectangle(
        [(CX - RING_HW) * SS, RING_TOP * SS, (CX + RING_HW) * SS, RING_BOT * SS],
        radius=RING_R * SS, fill=255,
    )
    m["ring"] = ring

    # Band: rounded on top, squared along the bottom so it sits flat on the rim.
    lid = big_mask()
    dl = ImageDraw.Draw(lid)
    dl.rounded_rectangle(
        [(CX - LID_HW) * SS, LID_TOP * SS, (CX + LID_HW) * SS, LID_BOT * SS],
        radius=LID_R * SS, fill=255,
    )
    dl.rectangle(
        [(CX - LID_HW) * SS, (LID_BOT - LID_R) * SS, (CX + LID_HW) * SS, LID_BOT * SS],
        fill=255,
    )
    m["lid"] = lid

    # Glass gleam, intersected with the jar so it can never spill past the edge.
    gleam = soft_mask(
        lambda d: d.rounded_rectangle(list(GLEAM_BOX), radius=GLEAM_R, fill=255),
        GLEAM_BLUR,
    )
    m["gleam"] = ImageChops.darker(gleam, jar)

    # Contact shadow: jar + band, nudged down and blurred.
    def paint_shadow(d):
        d.polygon(jar_outline(SHADOW_DY), fill=255)
        d.rounded_rectangle(
            [CX - LID_HW, LID_TOP + SHADOW_DY, CX + LID_HW, LID_BOT + SHADOW_DY],
            radius=LID_R, fill=255,
        )

    m["shadow"] = soft_mask(paint_shadow, SHADOW_BLUR)

    m["glow"] = soft_mask(
        lambda d: d.ellipse(
            [CX - GLOW_RX, GLOW_CY - GLOW_RY, CX + GLOW_RX, GLOW_CY + GLOW_RY],
            fill=255,
        ),
        GLOW_BLUR,
    )
    return m


def render(masks, pal):
    img = vgrad(pal["bg_top"], pal["bg_bot"])
    img.paste(pal["glow"], (0, 0), fade(masks["glow"], pal["glow_a"]))
    img.paste(pal["shadow"], (0, 0), fade(masks["shadow"], pal["shadow_a"]))
    img.paste(pal["jar"], (0, 0), masks["jar"])
    img.paste(pal["gleam"], (0, 0), fade(masks["gleam"], pal["gleam_a"]))
    img.paste(pal["glyph"], (0, 0), masks["glyph"])
    img.paste(pal["ring"], (0, 0), masks["ring"])
    img.paste(pal["lid"], (0, 0), masks["lid"])
    return img.resize((SIZE, SIZE), LANCZOS).convert("RGB")


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: %s <output-dir>\n" % os.path.basename(argv[0]))
        return 2
    out_dir = argv[1]
    os.makedirs(out_dir, exist_ok=True)

    masks = build_masks()
    for variant in ("light", "dark", "tinted"):
        path = os.path.join(out_dir, "%s-%s.png" % (NAME, variant))
        render(masks, PALETTES[variant]).save(path, "PNG")
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
