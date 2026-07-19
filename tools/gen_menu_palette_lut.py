#!/usr/bin/env python3
"""Bake the RGB->palette lookup table for the Game Boy greens the MENU is painted in.

Run from the project root:  python3 tools/gen_menu_palette_lut.py

Overwrites:
  shaders/lut_512.png      the 64x64x64 cube the dither shader snaps through, so every colour in
                           the frame maps to the nearest of the 64 menu greens.
  shaders/palette_512.png  a documentation-only swatch of the 64 shades (nothing samples it).

Why these greens: the LCD interface (scripts/gb_ui.gd) is hand-tokened in the classic DMG
"pea-green" ramp -- INK #0f380f at the dark end up to the lit-capsule highlight #cfe27a. The world
post-process, though, was snapping to the *other* DMG set (the blue-green "pocket" shades
#081820..#e0f8d0), so the world and the menu chrome were two different greens. This rebuilds the
palette straight from the eight distinct green design tokens in gb_ui.gd, so the dithered world and
the menu are finally one screen.

The eight tokens are only a spine: we walk them in Oklab (perceptually even steps, not raw RGB) and
resample to 64 shades, dark -> light -- a near-continuous monochrome green ramp. The endpoints land
exactly on the menu's darkest and lightest greens; the ramp passes through every token in between.
The heavy work -- nearest-colour mapping of the whole RGB cube in Oklab -- is reused from
gen_palette_lut.build_lut; this file only supplies the 64-colour palette.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_palette_lut import build_lut, to_oklab, srgb_to_linear

# The distinct green design tokens from scripts/gb_ui.gd, darkest -> lightest. These are the
# greens the player already sees every time the menu opens; the world now snaps to the same ramp.
#   INK #0f380f  INK_SOFT #1b4a1b  INK_MID #306230  DIM_HI #4d7a1f
#   LIT_LO #6b8f1f  LCD_BG #9bbc0f  LCD_BG_ALT #a8c520  LIT_HI #cfe27a
MENU_GREENS = [
    "0f380f",
    "1b4a1b",
    "306230",
    "4d7a1f",
    "6b8f1f",
    "9bbc0f",
    "a8c520",
    "cfe27a",
]
COLORS = 64


def hex_to_rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * (c ** (1.0 / 2.4)) - 0.055)


def oklab_to_srgb8(lab):
    """Oklab -> sRGB bytes. The inverse of gen_palette_lut.to_oklab, so interpolation can happen
    in the same perceptual space the LUT's nearest-colour search uses."""
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    rgb = np.stack([linear_to_srgb(r), linear_to_srgb(g), linear_to_srgb(bl)], axis=-1)
    return np.clip(np.round(rgb * 255.0), 0, 255).astype(np.uint8)


def menu_palette(n=COLORS):
    anchors = np.array([hex_to_rgb(h) for h in MENU_GREENS], dtype=np.uint8)
    lab = to_oklab(anchors)                       # spine in perceptual space
    ap = np.linspace(0.0, 1.0, len(anchors))      # anchor positions along the ramp
    ts = np.linspace(0.0, 1.0, n)                 # 16 even samples, dark -> light
    ramp = np.stack([np.interp(ts, ap, lab[:, c]) for c in range(3)], axis=-1)
    return oklab_to_srgb8(ramp)


def main():
    pal = menu_palette()
    print("menu DMG green palette (%d shades), dark -> light:" % len(pal))
    for i in range(0, len(pal), 8):
        print("  " + "  ".join("#%02x%02x%02x" % (int(c[0]), int(c[1]), int(c[2]))
                               for c in pal[i:i + 8]))

    # Doc-only swatch: each shade a 16x16 block, four rows of sixteen (dark -> light).
    grid = pal.reshape(4, 16, 3)
    grid = np.repeat(np.repeat(grid, 16, axis=0), 16, axis=1)
    Image.fromarray(grid, "RGB").save("shaders/palette_512.png")

    Image.fromarray(build_lut(pal), "RGB").save("shaders/lut_512.png")
    print("wrote shaders/palette_512.png and shaders/lut_512.png")


if __name__ == "__main__":
    main()
