#!/usr/bin/env python3
"""Generates icon.svg — the project's application icon.

The old icon was a 1 MB raster of the painted SlopFarm wordmark. This replaces
it with a hand-built, path/rect-only SVG, which is the right shape for an app
icon: it scales to any launcher size, weighs a couple of kilobytes, and — unlike
raster autotrace or an <text> element — renders identically in every SVG
backend, including Godot's (ThorVG has no font engine, so text is out).

The mark is a blocky "SLOP / FARM" set in a 5x7 pixel font. Pixel letterforms
suit a game that snaps everything to nearest-neighbour and a 512-colour palette,
and they cash out as plain <rect>s. A brown drop-shadow layer under the orange
one gives the carved-wood read the original logo had, on the same teal field.

    python3 tools/gen_icon.py     # writes icon.svg + icon.svg.import

Rerun after editing the letterforms or palette below.
"""

import hashlib
import os

# 5x7 pixel glyphs. '#' is an on-pixel; only the letters the wordmark needs.
GLYPHS = {
    "S": ["#####", "#....", "#....", "#####", "....#", "....#", "#####"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "O": ["#####", "#...#", "#...#", "#...#", "#...#", "#...#", "#####"],
    "P": ["#####", "#...#", "#...#", "#####", "#....", "#....", "#...."],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "R": ["#####", "#...#", "#...#", "#####", "#.#..", "#..#.", "#...#"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
}

ROWS = ["SLOP", "FARM"]

CANVAS = 512
CELL = 18            # pixel size of one glyph cell
LETTER_GAP = 1       # cells between letters
ROW_GAP = 2          # cells between the two words
SHADOW = 0.34        # drop-shadow offset, in cells
RADIUS = 3           # rounded corner on each pixel, world units

# Palette lifted off the original wordmark: teal field, warm orange wood, and a
# dark burnt-umber shadow. Mid-range on purpose, the same reason the in-game
# paints avoid near-white — the icon reads at 16 px too.
TEAL = "#33b4c4"
TEAL_EDGE = "#2a97a5"
ORANGE = "#e9631f"
ORANGE_TOP = "#f4863b"
SHADOW_COL = "#5a2913"

GLYPH_W = 5
GLYPH_H = 7


def _row_cells(word):
    """(col, row) on-pixels for one word, origin at the word's top-left cell."""
    cells = []
    for i, ch in enumerate(word):
        glyph = GLYPHS[ch]
        base = i * (GLYPH_W + LETTER_GAP)
        for r, line in enumerate(glyph):
            for c, px in enumerate(line):
                if px == "#":
                    cells.append((base + c, r))
    return cells


def _all_cells():
    """Every on-pixel across both stacked words, centred on the canvas."""
    word_w = max(len(w) for w in ROWS) * (GLYPH_W + LETTER_GAP) - LETTER_GAP
    total_h = len(ROWS) * GLYPH_H + (len(ROWS) - 1) * ROW_GAP
    x0 = (CANVAS - word_w * CELL) / 2.0
    y0 = (CANVAS - total_h * CELL) / 2.0

    out = []
    for ri, word in enumerate(ROWS):
        row_w = len(word) * (GLYPH_W + LETTER_GAP) - LETTER_GAP
        # Centre each word within the widest word's box.
        wx0 = x0 + (word_w - row_w) * CELL / 2.0
        wy0 = y0 + ri * (GLYPH_H + ROW_GAP) * CELL
        for (c, r) in _row_cells(word):
            out.append((wx0 + c * CELL, wy0 + r * CELL))
    return out


def _rects(cells, dx, dy, fill):
    parts = []
    for (x, y) in cells:
        parts.append(
            '<rect x="%.2f" y="%.2f" width="%d" height="%d" rx="%d" fill="%s"/>'
            % (x + dx, y + dy, CELL, CELL, RADIUS, fill))
    return "\n".join(parts)


def build_svg():
    cells = _all_cells()
    sh = SHADOW * CELL
    lines = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d">' % (CANVAS, CANVAS, CANVAS, CANVAS),
        '<rect x="6" y="6" width="%d" height="%d" rx="72" fill="%s" '
        'stroke="%s" stroke-width="6"/>' % (CANVAS - 12, CANVAS - 12, TEAL, TEAL_EDGE),
        "<!-- drop shadow -->",
        _rects(cells, sh, sh, SHADOW_COL),
        "<!-- wood face -->",
        _rects(cells, 0.0, 0.0, ORANGE),
        "<!-- top highlight: the upper third of every pixel, one shade up -->",
    ]
    # A thin highlight bar across the top of each pixel gives the planks a lit
    # edge without a per-pixel gradient the importer would have to rasterise.
    hi = []
    for (x, y) in cells:
        hi.append(
            '<rect x="%.2f" y="%.2f" width="%d" height="%.2f" rx="%d" fill="%s"/>'
            % (x, y, CELL, CELL * 0.32, RADIUS, ORANGE_TOP))
    lines.append("\n".join(hi))
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def godot_import(source_res_path):
    """A Godot 4 texture .import for an SVG, with the deterministic cache path.

    The cache filename is md5(res-path); Godot rebuilds the actual cache on first
    import (it is gitignored), so committing this is just declaring the settings —
    chiefly no VRAM compression and no mipmaps, so the icon stays crisp.
    """
    digest = hashlib.md5(source_res_path.encode("utf-8")).hexdigest()
    dest = "res://.godot/imported/%s-%s.ctex" % (os.path.basename(source_res_path), digest)
    return "\n".join([
        "[remap]",
        "",
        'importer="texture"',
        'type="CompressedTexture2D"',
        'uid="uid://bslopfarmicon01"',
        'path="%s"' % dest,
        "metadata={",
        '"vram_texture": false',
        "}",
        "",
        "[deps]",
        "",
        'source_file="%s"' % source_res_path,
        'dest_files=["%s"]' % dest,
        "",
        "[params]",
        "",
        "compress/mode=0",
        "compress/high_quality=false",
        "compress/lossy_quality=0.7",
        "compress/hdr_compression=1",
        "compress/normal_map=0",
        "compress/channel_pack=0",
        "mipmaps/generate=false",
        "mipmaps/limit=-1",
        "roughness/mode=0",
        'roughness/src_normal=""',
        "process/fix_alpha_border=true",
        "process/premult_alpha=false",
        "process/normal_map_invert_y=false",
        "process/hdr_as_srgb=false",
        "process/hdr_clamp_exposure=false",
        "process/size_limit=0",
        "detect_3d/compress_to=1",
        "svg/scale=1.0",
        "editor/scale_with_editor_scale=false",
        "editor/convert_colors_with_editor_theme=false",
        "",
    ])


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    svg_path = os.path.join(root, "icon.svg")
    import_path = os.path.join(root, "icon.svg.import")
    with open(svg_path, "w") as f:
        f.write(build_svg())
    with open(import_path, "w") as f:
        f.write(godot_import("res://icon.svg"))
    print("wrote", svg_path)
    print("wrote", import_path)


if __name__ == "__main__":
    main()
