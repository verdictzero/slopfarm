#!/usr/bin/env python3
"""Bake the RGB->palette lookup table for the Game Boy (DMG) green palette, expanded to 16 shades.

Run from the project root:  python3 tools/gen_gameboy_lut.py

Overwrites:
  shaders/lut_512.png      the 64x64x64 cube the dither shader snaps through, so every colour in
                           the frame maps to the nearest of the 16 DMG greens.
  shaders/palette_512.png  a documentation-only swatch of the 16 shades (nothing samples it).

The same four hardware DMG blue-green anchors as the 4-shade palette, just interpolated into a
16-step ramp: a smoother monochrome Game Boy gradient, still pure green. Everything in the frame
(hearts, the pickup ribbon, the gold wand) snaps to a green shade — that IS the DMG screen.

The heavy work — nearest-colour mapping of the whole RGB cube in Oklab — is reused from
gen_palette_lut.build_lut; this file only swaps in the 16-colour palette.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_palette_lut import build_lut

# The four hardware Game Boy (DMG) blue-green shades, dark -> light, interpolated into 16.
GB_ANCHORS = [
    (0x08, 0x18, 0x20),
    (0x34, 0x68, 0x56),
    (0x88, 0xc0, 0x70),
    (0xe0, 0xf8, 0xd0),
]
COLORS = 16


def gameboy_palette(n=COLORS):
    anchors = np.array(GB_ANCHORS, dtype=np.float64)
    ap = np.linspace(0.0, 1.0, len(anchors))
    ts = np.linspace(0.0, 1.0, n)
    cols = np.stack([np.interp(ts, ap, anchors[:, c]) for c in range(3)], axis=-1)
    return np.clip(np.round(cols), 0, 255).astype(np.uint8)


def main():
    pal = gameboy_palette()
    print("gameboy DMG palette (%d shades):" % len(pal))
    for c in pal:
        print("  #%02x%02x%02x" % (int(c[0]), int(c[1]), int(c[2])))

    # Doc-only swatch: each shade a 16x16 block, two rows of eight.
    grid = pal.reshape(2, 8, 3)
    grid = np.repeat(np.repeat(grid, 16, axis=0), 16, axis=1)
    Image.fromarray(grid, "RGB").save("shaders/palette_512.png")

    Image.fromarray(build_lut(pal), "RGB").save("shaders/lut_512.png")
    print("wrote shaders/palette_512.png and shaders/lut_512.png")


if __name__ == "__main__":
    main()
