#!/usr/bin/env python3
"""Generates the 512-colour retro palette and bakes the RGB->palette lookup table.

Run from the project root:  python3 tools/gen_palette_lut.py

Writes two PNGs into shaders/:
  palette_512.png  32x16 reference swatch, one texel per palette entry (documentation
                   only -- nothing samples it at runtime).
  lut_512.png      the actual lookup table: a 64x64x64 RGB cube flattened into an 8x8
                   grid of 64x64 slices. Cell (r,g,b) holds the palette entry nearest
                   to that colour, so the dither shader replaces a per-pixel search
                   over 512 candidates with a single texture fetch.

The palette is hue-shifted ramps rather than a uniform RGB cube: 31 hues x 16 shades
plus 16 greys. Shades push toward blue as they darken and toward yellow as they
lighten, and saturation peaks in the midtones -- the way hand-authored pixel-art
ramps behave, and the reason the output reads as "retro" rather than merely
quantised. Channels land on a 5-bit ladder as a nod to 15-bit era hardware.
"""

import math
import numpy as np
from PIL import Image

PALETTE_SIZE = 512
LUT_SIZE = 64  # cells per axis; 64^3 slices tile exactly into 512x512
LUT_TILES = 8  # 8x8 grid of slices

# Hue anchors, deliberately not evenly spaced: the terrain is greens, browns, rock
# and sky, so those bands get more ramps than magenta ever will.
HUES = [
    0, 12, 24, 34, 44,            # reds -> oranges -> browns
    52, 60, 70,                   # yellows
    80, 92, 104, 116, 128, 140,   # yellow-greens -> greens
    152, 164, 176,                # green-cyans
    186, 196,                     # cyans / teals
    206, 214, 222, 230, 240,      # blues
    252, 264, 276,                # indigo -> violet
    292, 310,                     # purples / magentas
    330, 348,                     # pinks
]
SHADES = 16
GREYS = 16

SHADOW_HUE = 250.0  # what darks drift toward
LIGHT_HUE = 48.0    # what lights drift toward
HUE_SHIFT = 0.16    # how far along that drift a ramp end travels


def hue_toward(h, target, amount):
    """Rotate h toward target along the shortest arc."""
    delta = ((target - h + 180.0) % 360.0) - 180.0
    return (h + delta * amount) % 360.0


def hsl_to_rgb(h, s, light):
    c = (1.0 - abs(2.0 * light - 1.0)) * s
    hp = (h % 360.0) / 60.0
    x = c * (1.0 - abs(hp % 2.0 - 1.0))
    if hp < 1: rgb = (c, x, 0)
    elif hp < 2: rgb = (x, c, 0)
    elif hp < 3: rgb = (0, c, x)
    elif hp < 4: rgb = (0, x, c)
    elif hp < 5: rgb = (x, 0, c)
    else: rgb = (c, 0, x)
    m = light - c / 2.0
    return tuple(min(1.0, max(0.0, v + m)) for v in rgb)


def snap5(rgb):
    """Quantise to 5 bits per channel (15-bit colour), then back to 8-bit."""
    return tuple(int(round(round(v * 31.0) / 31.0 * 255.0)) for v in rgb)


def build_palette():
    entries = []

    # Greys: cool in shadow, and near-neutral through the highlights. Warm highlights
    # are right for a lit object's ramp but wrong for the neutral axis: near white all
    # 31 hue ramps converge here, so whatever tint these carry becomes the tint of
    # every washed-out pixel in the frame. A warmer setting visibly pinks the sky.
    for i in range(GREYS):
        t = i / (GREYS - 1)
        light = 0.02 + 0.98 * (t ** 1.15)
        if t < 0.5:
            h, s = SHADOW_HUE, 0.10 * (0.5 - t) * 2.0
        else:
            h, s = LIGHT_HUE, 0.015 * (t - 0.5) * 2.0
        entries.append(snap5(hsl_to_rgb(h, s, light)))

    # Hue ramps.
    for base_hue in HUES:
        for j in range(SHADES):
            t = j / (SHADES - 1)
            # Exponent below 1 crowds the ramp toward its light end. This is a fit to
            # the content, not a style choice: a daylight scene is sky, fog and lit
            # ground, with almost nothing genuinely dark, so spacing shades evenly
            # spends half the palette where the game never goes. Measured against a
            # real frame, 0.8 cuts mean error 21% and the 99th percentile 28% versus
            # an even 1.1 -- most visibly on the sky, which otherwise has no pale
            # saturated blue to land on and drifts warm.
            light = 0.05 + 0.92 * (t ** 0.8)

            shadow_pull = max(0.0, (0.5 - t) * 2.0)
            light_pull = max(0.0, (t - 0.5) * 2.0)
            h = hue_toward(base_hue, SHADOW_HUE, HUE_SHIFT * shadow_pull)
            h = hue_toward(h, LIGHT_HUE, HUE_SHIFT * light_pull)

            # Saturation arcs up through the midtones, and highlights wash out a little
            # harder than shadows do. Only a little: fading them hard is what starved
            # the pale end of colour in the first place.
            s = 0.85 * (math.sin(math.pi * (0.15 + 0.7 * t)) ** 0.7)
            s *= 1.0 - 0.15 * (max(0.0, (t - 0.6) / 0.4) ** 1.5)

            entries.append(snap5(hsl_to_rgb(h, s, light)))

    # The 5-bit snap collides neighbours at the washed-out ends of ramps, so the
    # ramps alone land short of 512. Spend the leftover slots where the palette is
    # thinnest -- farthest-point insertion over the 15-bit cube -- which both fills
    # the count and pulls down the worst-case LUT error.
    seen, unique = set(), []
    for e in entries:
        if e not in seen:
            seen.add(e)
            unique.append(e)
    dropped = len(entries) - len(unique)

    filler = PALETTE_SIZE - len(unique)
    if filler > 0:
        ladder = np.round(np.linspace(0, 31, 32) / 31.0 * 255.0).astype(np.uint8)
        cr, cg, cb = np.meshgrid(ladder, ladder, ladder, indexing="ij")
        cands = np.stack([cr, cg, cb], axis=-1).reshape(-1, 3)
        cands_lab = to_oklab(cands)

        chosen_lab = to_oklab(np.array(unique, dtype=np.uint8))
        # Distance from every candidate to the nearest colour already in the palette.
        min_d = np.full(len(cands), np.inf)
        for start in range(0, len(chosen_lab), 128):
            block = chosen_lab[start:start + 128]
            d = ((cands_lab[:, None, :] - block[None, :, :]) ** 2).sum(axis=-1)
            min_d = np.minimum(min_d, d.min(axis=1))

        for _ in range(filler):
            pick = int(min_d.argmax())
            unique.append(tuple(int(v) for v in cands[pick]))
            # Only the new colour can shrink the gaps, so update against it alone.
            d = ((cands_lab - cands_lab[pick]) ** 2).sum(axis=-1)
            min_d = np.minimum(min_d, d)

    print(f"palette: {len(unique)} colours ({dropped} ramp duplicates dropped, {filler} gap-filling added)")
    return np.array(unique[:PALETTE_SIZE], dtype=np.uint8)


def srgb_to_linear(c):
    c = c.astype(np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_oklab(rgb8):
    """sRGB bytes -> Oklab. Nearest-colour picked perceptually, not in raw RGB."""
    c = srgb_to_linear(rgb8)
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = np.cbrt(l), np.cbrt(m), np.cbrt(s)
    return np.stack([
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    ], axis=-1)


def build_lut(palette):
    axis = np.linspace(0.0, 255.0, LUT_SIZE)
    # Index order must match the shader: x=red, y=green, slice=blue.
    b, g, r = np.meshgrid(axis, axis, axis, indexing="ij")
    grid = np.stack([r, g, b], axis=-1).reshape(-1, 3).astype(np.uint8)

    grid_lab = to_oklab(grid)
    pal_lab = to_oklab(palette)

    nearest = np.empty(len(grid_lab), dtype=np.int32)
    for start in range(0, len(grid_lab), 8192):
        chunk = grid_lab[start:start + 8192]
        d = ((chunk[:, None, :] - pal_lab[None, :, :]) ** 2).sum(axis=-1)
        nearest[start:start + 8192] = d.argmin(axis=1)

    mapped = palette[nearest].reshape(LUT_SIZE, LUT_SIZE, LUT_SIZE, 3)  # [b][g][r]

    # Tile the blue slices into an 8x8 grid.
    side = LUT_SIZE * LUT_TILES
    out = np.zeros((side, side, 3), dtype=np.uint8)
    for slice_index in range(LUT_SIZE):
        tx = (slice_index % LUT_TILES) * LUT_SIZE
        ty = (slice_index // LUT_TILES) * LUT_SIZE
        out[ty:ty + LUT_SIZE, tx:tx + LUT_SIZE] = mapped[slice_index]

    used = len(np.unique(nearest))
    print(f"lut: {side}x{side}, {used}/{PALETTE_SIZE} palette entries reachable")
    return out


def main():
    palette = build_palette()

    swatch = palette.reshape(16, 32, 3)
    Image.fromarray(swatch, "RGB").save("shaders/palette_512.png")

    Image.fromarray(build_lut(palette), "RGB").save("shaders/lut_512.png")
    print("wrote shaders/palette_512.png and shaders/lut_512.png")


if __name__ == "__main__":
    main()
