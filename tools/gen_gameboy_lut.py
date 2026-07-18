#!/usr/bin/env python3
"""Bake the RGB->palette lookup table for a 16-shade monochrome Game Boy green palette.

Run from the project root:  python3 tools/gen_gameboy_lut.py

Overwrites:
  shaders/lut_512.png      the 64x64x64 cube the dither shader snaps through, so every colour
                           in the frame maps to the nearest of 16 greens along the DMG gradient.
  shaders/palette_512.png  a documentation-only swatch of the 16 shades (nothing samples it).

The heavy work — nearest-colour mapping of the whole RGB cube in Oklab — is reused from
gen_palette_lut.build_lut; this file only swaps in the 16-colour palette.
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_palette_lut import build_lut

# Classic Game Boy (DMG) green gradient, dark -> light, interpolated into a smooth monochrome
# ramp: a deep bottle-green shadow up through the screen's mid greens to a pale phosphor white.
GB_ANCHORS = [
    (0x08, 0x18, 0x20),
    (0x25, 0x49, 0x38),
    (0x34, 0x68, 0x56),
    (0x60, 0x94, 0x60),
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
    palette = gameboy_palette()
    print("gameboy palette (%d shades):" % len(palette))
    for c in palette:
        print("  #%02x%02x%02x" % (int(c[0]), int(c[1]), int(c[2])))

    # Doc-only swatch: each shade a 16x16 block in a strip.
    strip = np.repeat(palette[None, :, :], 16, axis=0)
    strip = np.repeat(strip, 16, axis=1)
    Image.fromarray(strip, "RGB").save("shaders/palette_512.png")

    Image.fromarray(build_lut(palette), "RGB").save("shaders/lut_512.png")
    print("wrote shaders/palette_512.png and shaders/lut_512.png")


if __name__ == "__main__":
    main()
