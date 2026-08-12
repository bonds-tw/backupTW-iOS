#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
App icon generator for 有備而來 (bonds-tw / backupTW-iOS): 「方結」, the squared bond.

Same claim as knot.py -- two strands holding each other with nothing in between,
which is what offline peer-to-peer verification is (two phones, no server) and
what bonds-tw means -- but rebuilt on a square grid, and rebuilt around the
finding that killed the Bezier version.

--------------------------------------------------------------------------
WHY SQUARE
--------------------------------------------------------------------------
A curve has no privileged direction, so a curved strand's edge lands wherever it
lands relative to the pixel grid and every edge in the mark resolves to its own
shade of grey. Straight axis-aligned edges land on one boundary and hold a hard
value break through a LANCZOS downsample. And a grid lets every dimension be
specified rather than discovered: here one grid unit U = 64 design units =
exactly one device pixel at 16pt, every edge in the mark is an integer multiple
of U from the tile edge, and the smallest feature anywhere is 2U. Nothing has to
survive resampling that is smaller than a pixel, because nothing smaller than
two pixels was drawn.

--------------------------------------------------------------------------
WHY THE OVER/UNDER IS A VALUE BREAK AND NOT A GAP  (the big departure)
--------------------------------------------------------------------------
The first three drafts of this file did the obvious thing: one ink colour, and
the crossings carried by a 1U band of ground left open either side of the strand
that passes over -- knot.py's trick, but a full pixel wide instead of 0.44 of
one, and pixel-aligned. It is crisp at 48 and 29. It fails at 16, and the
arithmetic says why.

A gap crossing interrupts the under-strand for over-strand (2U) + two gaps (2U)
= 4U. The whole mark can only be about 12U across. So the under-strand is broken
across a third of its own length, twice, and at 16pt the eye has no continuity
left to work with: what survives is a bracket, a bracket, and two crumbs. Eleven
variants of that idea were rendered at 16px and every one of them read as
punctuation. Worse, the one-colour gap version of the *final* form below breaks
each band into rotationally-arranged L-shaped chunks and reads as a swastika --
rendered, looked at, and that is the end of that idea for a Taiwanese civil
tool.

So the crossings are carried by value instead. Where two bands cross, the one on
top simply covers the one underneath, and the two are told apart by a ~100-level
luma step across a straight edge. This is exactly the discipline that made
jar-evolved score 9 on this lens -- "two shapes and one hard value break rather
than structure carried by hairlines, gaps, or interior detail" -- and it costs
nothing: the interruption drops from 4U to 2U, which leaves room for the hole in
the middle to exist.

knot.py's author tried two colours and dropped them: "it split into an orange
half and a black half and stopped being one figure". That verdict was earned and
it does not transfer, for two reasons. It was amber on a *light* ground, where
the accent is only ~90 luma from the paper and the amber strand simply went
missing. And the two Bezier strands each occupied their own half of the tile, so
colouring them separately cut the figure in two. Here the ground is dark, so
both strands sit ~100 levels off it and ~100 off each other -- jar-evolved's
three-value ladder -- and, more importantly, the two strands are interleaved
across the whole mark rather than stacked in halves: strand A runs top-to-bottom
everywhere, strand B left-to-right everywhere. Neither can clump.

--------------------------------------------------------------------------
FORM
--------------------------------------------------------------------------
A 2x2 plain weave: the basic move a 中國結 is actually made of, and the smallest
figure in which two strands demonstrably pass through each other rather than
merely lie across each other.

Strand A is a staple: a base along the bottom and two legs standing up.
Strand B is a bracket: a spine down the right and two bars reaching left.
The legs and the bars cross at four points, and A is on top at two of them
(top-left, bottom-right) and underneath at the other two. That alternation is
the whole difference between linked and stacked.

The base is at the bottom and not the top because the first version had it at
the top, and a horizontal bar on top of two legs is a stool. Turned through 180
degrees the same drawing stops being furniture and starts being a knot; all four
orientations were rendered and looked at before picking this one.

Two forms were tried and rejected before this one, both rendered and looked at:

  * Two L-hooks tracing a broken ring. Economical, genuinely an interlock -- and
    two overlapping L-brackets around an empty square is the crop tool, in every
    photo editor there is. Distinctiveness is the only reason the knot survived
    the judging at all, so a form that hands it to a stock icon is disqualified
    however crisp it renders.
  * The same ring with the tails turned through 90 degrees. Not the crop tool
    any more, but the hooks read as feet, and the mark went 14U x 8U.

The crown and the spine are what stop this being a hash: they close the top and
the left, so the composition is shut on one diagonal and open on the other, and
the four ends leave in two directions rather than four. Four ends leaving in four
directions is the pinwheel this form has to stay away from.

Usage:   python3 knot-orthogonal.py <output-dir>
Writes:  knot-orthogonal-light.png
         knot-orthogonal-dark.png
         knot-orthogonal-tinted.png   (greyscale; iOS supplies the tint)
         knot-orthogonal-16.png       16px LANCZOS render, NEAREST-blown to 256
         knot-orthogonal-29.png       29px  "  (Settings list)
         knot-orthogonal-48.png       48px  "

Each icon file is 1024x1024 RGB, no alpha, no rounded corners -- full bleed,
iOS applies its own squircle. Everything is drawn at 4096 and LANCZOS-
downsampled, because ImageDraw has no antialiasing of its own.
Standard library + Pillow only; no external files, no fonts, no text.
"""

import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

try:  # Pillow >= 9.1
    LANCZOS = Image.Resampling.LANCZOS
    BICUBIC = Image.Resampling.BICUBIC
    NEAREST = Image.Resampling.NEAREST
except AttributeError:  # pragma: no cover - older Pillow
    LANCZOS = Image.LANCZOS
    BICUBIC = Image.BICUBIC
    NEAREST = Image.NEAREST

NAME = "bonds-square-knot"
SIZE = 1024
SS = 4                 # supersample factor
BIG = SIZE * SS        # 4096

# ---------------------------------------------------------------------------
# The grid.
#
# U is one device pixel at 16pt: 1024/16 = 64 design units. It is 1.81px at 29pt
# and 3.00px at 48pt. Everything below is an integer multiple of U, so every
# edge of the mark coincides with a pixel boundary in the 16pt render and no
# feature straddles a pixel and averages itself into mud.
# ---------------------------------------------------------------------------

U = 64.0

BAND = 2               # band width, in U. 128 design units = 2.00px at 16pt.
                       # One would be knot.py's grey wire. Three was tried: the
                       # weave closes up, the hole in the middle drops below 4U,
                       # and the mark stops being a weave and becomes a bolt.
CELL = 4               # clear span between the two legs, and between the two
                       # bars, in U. This is the hole in the middle of the knot
                       # and it is the single most durable feature in the mark:
                       # 4U = 4 device pixels at 16pt, enclosed on all four
                       # sides. Everything else here was sized around keeping it.
TAIL = 2               # how far each end runs past the last crossing. 2U is the
                       # least that reads as "this carries on"; it is also all
                       # there is, since every extra unit of tail is a unit off
                       # the hole at this overall size.

# Clearance between A's base and B's lower bar, and between B's spine and A's
# right leg, is zero -- they butt. With one colour that would be a fusion and
# that corner of the mark would go solid; with a value break it is a seam, and a
# seam costs nothing while a 1U channel of ground costs 2U on both overall
# dimensions. Rendered both: butted is bolder at 16 and identical at 48.

R_OUT = 20.0           # corner radius on the outer corners of each band. 0.31px
                       # at 16pt, so it exists only for the large sizes, where it
                       # keeps the mark from looking like it was drawn in a tile
                       # editor. Every corner it would round at a butt joint is
                       # buried inside the other band, so no joint gets softened.

# ---------------------------------------------------------------------------
# Geometry, in grid units, origin at the top-left crossing.
#
#        -2    0     2     6     8    10
#   -2         A-----+     +-----A            A = strand A (staple)
#    0         A     |     |     A            B = strand B (bracket)
#         BBBBBBBBBBBBBBBBBBBBBBBBBBBB       lower case = which one is on top
#    2         A a a |     | b b A    B          at that crossing
#              A     |  o  |     A    B       o = the hole, 4U x 4U
#    6         A     |     |     A    B
#         BBBBBBBBBBBBBBBBBBBBBBBBBBBB
#    8         A b b |     | a a A    B
#   10         AAAAAAAAAAAAAAAAAAAA
#
# Overall 12U x 12U = 768 design units, 75% of the tile, centred. The farthest
# any part of the mark gets from the centre is a band end at 384 units on one
# axis and 256 on the other: (384/512)^5 + (256/512)^5 = 0.27, well inside the
# iOS squircle, which only closes in past 1.0. Nothing is near a corner.
# ---------------------------------------------------------------------------

V0, V1 = 0, BAND + CELL            # left edges of A's two legs:   0 and 6
H0, H1 = 0, BAND + CELL            # top edges of B's two bars:    0 and 6
TOP = -TAIL                        # A's legs start here:         -2
LEFT = -TAIL                       # B's bars start here:         -2
BASE = H1 + BAND                   # A's base, top edge:           8
SPINE = V1 + BAND                  # B's spine, left edge:         8

A_CELLS = [
    (V0, TOP, V0 + BAND, BASE + BAND),     # left leg
    (V1, TOP, V1 + BAND, BASE + BAND),     # right leg
    (V0, BASE, V1 + BAND, BASE + BAND),    # base
]
B_CELLS = [
    (LEFT, H0, SPINE + BAND, H0 + BAND),   # upper bar
    (LEFT, H1, SPINE + BAND, H1 + BAND),   # lower bar
    (SPINE, H0, SPINE + BAND, H1 + BAND),  # spine
]

# The two crossings where A is on top. The other two -- (V1,H0) and (V0,H1) --
# need no mask at all: B is painted after A, so it covers them by default. Plain
# weave, and the pattern is forced: make A the top strand at three of the four
# and the two bands stop being linked and become one lying on the other.
A_OVER = [
    (V0, H0, V0 + BAND, H0 + BAND),        # top-left
    (V1, H1, V1 + BAND, H1 + BAND),        # bottom-right
]

MARK_W = (SPINE + BAND) - LEFT             # 12U
MARK_H = (BASE + BAND) - TOP               # 12U

# ---------------------------------------------------------------------------
# Ground treatment: a radial glow and nothing else.
#
# knot.py also carried a contact shadow. There is none here on purpose. A shadow
# under a band darkens the ground immediately around it, and around this mark
# the ground is doing structural work -- it is the hole, and the two notches
# under and to the right of the weave. At 16pt a shadow is only ever a tax on
# the one thing that has to survive. The glow is allowed because it is
# low-frequency: it blurs to a flat wash at small size instead of becoming
# texture.
# ---------------------------------------------------------------------------

GLOW_R = 430.0
GLOW_BLUR = 150.0


def hexc(s):
    """'#RRGGBB' -> (r, g, b)."""
    return (int(s[1:3], 16), int(s[3:5], 16), int(s[5:7], 16))


# ---------------------------------------------------------------------------
# Palettes. All three variants are dark-ground, which is a departure from
# knot.py and a borrowing from jar-evolved, for its reason and one of its own.
# Its reason: a dark tile keeps a hard edge against a light *and* a dark iOS
# wallpaper, and a warm figure on a dark field is the right picture for a
# civil-defence tool -- what you still have when the power and the network are
# gone. Its own reason: this design spends everything on a three-value ladder,
# and a dark ground is the only place both strands can sit ~100 luma from the
# ground and ~100 from each other. On paper-coloured ground the accent lands
# ~90 from the paper and the amber strand disappears, which is precisely how the
# two-colour Bezier knot died.
#
# Luma ladders (Rec.709):
#   light   ground  41  |  band B 145  |  band A 232      steps 104 / 87
#   dark    ground  24  |  band B 119  |  band A 208      steps  95 / 89
#   tinted  ground  30  |  band B 140  |  band A 255      steps 110 / 115
#
# tinted is strictly greyscale: iOS recolours it wholesale, so every bit of
# separation has to be carried by value. Because this mark carries *all* of its
# structure by value, the tinted variant is not a degraded copy of the other
# two -- it is the same drawing.
# ---------------------------------------------------------------------------

PALETTES = {
    "light": {
        "bg_top": hexc("#212C28"),      # dark surface token
        "bg_bot": hexc("#141C19"),      # dark surface token
        "glow": hexc("#5A4020"), "glow_a": 0.55,
        "a": hexc("#F3E7D4"),           # cream  -- the staple
        "b": hexc("#C98A34"),           # accent -- the bracket
    },
    "dark": {
        "bg_top": hexc("#131A17"),
        "bg_bot": hexc("#070B09"),
        "glow": hexc("#3D2C15"), "glow_a": 0.75,
        "a": hexc("#DFD0B6"),
        "b": hexc("#A9702A"),           # accent-deep, warmed
    },
    "tinted": {
        "bg_top": hexc("#1E1E1E"),
        "bg_bot": hexc("#0A0A0A"),
        "glow": hexc("#2C2C2C"), "glow_a": 0.80,
        "a": hexc("#FFFFFF"),
        "b": hexc("#8C8C8C"),
    },
}


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

OX = (SIZE / U - MARK_W) / 2.0 - LEFT      # grid -> centred 1024-space, in U
OY = (SIZE / U - MARK_H) / 2.0 - TOP


def place(cells):
    """Grid units -> 4096-space pixel boxes."""
    return [[(c[0] + OX) * U * SS, (c[1] + OY) * U * SS,
             (c[2] + OX) * U * SS, (c[3] + OY) * U * SS] for c in cells]


def big_mask():
    return Image.new("L", (BIG, BIG), 0)


def band_mask(cells):
    """Union of rounded rectangles. Taking the union rather than tracing one
    outline is what keeps the inside of each corner sharp: the rounding on the
    base's upper corners falls inside the legs and disappears, while the four
    free ends keep theirs."""
    m = big_mask()
    d = ImageDraw.Draw(m)
    for box in place(cells):
        d.rounded_rectangle(box, radius=R_OUT * SS, fill=255)
    return m


def square_mask(cells):
    """Hard-edged rectangles, for the crossing stencils. These have to be square:
    their edges sit exactly on the edges of the band that covers them, and a
    radius here would open a crescent of the wrong strand at each crossing."""
    m = big_mask()
    d = ImageDraw.Draw(m)
    for box in place(cells):
        d.rectangle(box, fill=255)
    return m


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
    """Geometry is identical across the three variants, so build it once.

    Paint order is A, then B. B covers A wherever they meet, which is the right
    answer at two of the four crossings; at the other two, B is stencilled away
    so that A shows through. Every boundary between the two masks is an exact
    multiple of 2U in 1024-space and therefore an exact multiple of 512 pixels
    at 4096, so the seam is a hard edge with no subpixel sliver of ground in it.
    """
    return {
        "a": band_mask(A_CELLS),
        "b": ImageChops.subtract(band_mask(B_CELLS), square_mask(A_OVER)),
        "glow": soft_mask(
            lambda d: d.ellipse(
                [SIZE / 2 - GLOW_R, SIZE / 2 - GLOW_R,
                 SIZE / 2 + GLOW_R, SIZE / 2 + GLOW_R], fill=255),
            GLOW_BLUR,
        ),
    }


def render(masks, pal):
    img = vgrad(pal["bg_top"], pal["bg_bot"])
    img.paste(pal["glow"], (0, 0), fade(masks["glow"], pal["glow_a"]))
    img.paste(pal["a"], (0, 0), masks["a"])
    img.paste(pal["b"], (0, 0), masks["b"])
    return img.resize((SIZE, SIZE), LANCZOS).convert("RGB")


def preview(img, px, out_path):
    """Downsample to px the way a device would, then NEAREST back up to 256 so a
    human can see exactly which pixels survive. This is the acceptance test, not
    a nicety, and every structural decision above came back from looking at it."""
    img.resize((px, px), LANCZOS).resize((256, 256), NEAREST).save(out_path, "PNG")
    return out_path


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: %s <output-dir> [--previews <dir>]\n"
                         % os.path.basename(argv[0]))
        return 2
    out_dir = argv[1]
    os.makedirs(out_dir, exist_ok=True)

    # Previews are the acceptance test, not an asset, and they must not be
    # written into the icon set: everything in `AppIcon.appiconset` that is not
    # in `Contents.json` is a file shipped in the bundle for nobody, and a
    # 16-pixel blow-up of the icon is exactly the sort of thing that gets
    # noticed a year later and cannot be explained. Off by default; pass
    # `--previews <dir>` to look.
    preview_dir = None
    if "--previews" in argv:
        index = argv.index("--previews")
        if index + 1 >= len(argv):
            sys.stderr.write("--previews needs a directory\n")
            return 2
        preview_dir = argv[index + 1]
        os.makedirs(preview_dir, exist_ok=True)

    masks = build_masks()
    rendered = {}
    for variant in ("light", "dark", "tinted"):
        img = render(masks, PALETTES[variant])
        rendered[variant] = img
        path = os.path.join(out_dir, "%s-%s.png" % (NAME, variant))
        img.save(path, "PNG")
        print(path)

    if preview_dir:
        for px in (16, 29, 48):
            print(preview(rendered["light"], px,
                          os.path.join(preview_dir, "%s-%d.png" % (NAME, px))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
