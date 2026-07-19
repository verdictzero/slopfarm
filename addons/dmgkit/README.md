# dmgkit

A self-contained Godot 4 toolkit for the Game Boy **DMG** look, extracted from *slopfarm*. Every
piece is a plain global `class_name` with **no gameplay dependencies** — drop the `addons/dmgkit/`
folder into any project and use the classes directly (the plugin doesn't even need to be "enabled").

Built for the **GL Compatibility (mobile)** renderer.

## What's in it

| Class | File | What it is |
|-------|------|------------|
| `DmgTerrain` | `scripts/dmg_terrain.gd` | Streams flat-shaded, low-poly terrain chunks around a target node. Pure height field (deterministic), LOD rings, skirts, near-only collision. |
| `DmgTerrainTextures` | `scripts/dmg_terrain_textures.gd` | Builds the ground texture atlas (grass/dirt/road/crop/mud/rock) from tileable value noise, quantised to 4-tone ramps so it survives the palette snap. |
| `DmgDither` | `scripts/dmg_dither.gd` | The signature green-LCD post-process as a drop-in node: dices the frame into LCD dots, ordered-dithers, snaps to the 64 DMG greens in `lut_512.png`. |
| `DmgMeshKit` | `scripts/dmg_mesh_kit.gd` | Procedural vertex-coloured mesh builder — `box/quad/cylinder/cone/pipe/sphere/torus/…` merged into one flat-shaded mesh. |
| `DmgUI` | `scripts/dmg_ui.gd` | The DMG HUD + two-column menu (readout chips, list/detail/stats/description), pixel font, DMG palette. Content is data you set — nothing game-specific baked in. |
| `DmgTitle` | `scripts/dmg_title.gd` | A boot title card: a cover image (or a rendered title string) plus a blinking "PRESS START". |

Shaders + LUT live in `shaders/`, the pixel font (Press Start 2P, OFL) in `fonts/`. A runnable
example is in `demo/demo.tscn` (open it and press Play, or it doubles as the copy-paste wiring
reference in `demo/demo.gd`).

## Quick start

```gdscript
extends Node3D

func _ready() -> void:
    # 1) Streamed terrain that follows a node (your player/camera rig).
    var terrain := DmgTerrain.new()
    terrain.player = $Camera3D          # any Node3D; streaming keys off its position
    add_child(terrain)
    terrain.prime(Vector3.ZERO)         # build solid ground around a point immediately

    # 2) The green-LCD dither over the whole viewport. Anything on a CanvasLayer ABOVE
    #    layer 100 (HUD, menus) stays crisp on top of the dithered world.
    add_child(DmgDither.create(100, 3.0, 0.17))   # (layer, dots-per-pixel, dither strength)
```

`terrain.height_at(x, z)` is a pure function — safe to call before any chunk exists (e.g. to spawn
something on the ground). Tune terrain via its exported `@export` vars (chunk size, view distance,
hill amplitude, slope→dirt/rock cutoffs, seed, …). Tune the look via `DmgDither.grid_size` (native
pixels per LCD dot) and `DmgDither.dither_strength`.

### HUD + menu

`DmgUI` is a CanvasLayer (default layer 112) — keep it above the dither so it stays crisp. It draws
only what you give it:

```gdscript
var ui := DmgUI.new()
add_child(ui)
ui.set_readouts([
    {"label": "SCORE", "value": "01200", "side": 0},              # side 0 = left
    {"label": "LIVES", "value": "03", "unit": "x", "side": 1},    # side 1 = right
])
ui.set_menu_items([
    {"title": "STATUS", "lines": ["SCORE   01200", "LIVES   3"],
        "stats": [["BEST", "09400"], ["TIME", "02:14"]], "desc": "HOW YOU ARE DOING"},
    {"title": "OPTIONS", "lines": ["SOUND   ON"], "desc": "TWEAK THE GAME"},
])
ui.item_activated.connect(func(index, id): print("chose ", id))
# Drive it from your input: ui.toggle_menu(), ui.nav(+1)/ui.nav(-1), ui.activate().
```

A title card:

```gdscript
var title := DmgTitle.new()
title.title_text = "MY GAME"        # or set title.image / image_path for cover art
add_child(title)
# ... on first input: title.dismiss()
```

Font sizes are pinned to Press Start 2P's native 8-px cell so glyphs stay on-grid and crisp.

### Rendering into a fixed buffer (the crisp-pixels trick)

*slopfarm* renders the world into a fixed 1080×1080 `SubViewport` and shows that with `NEAREST`
filtering, so the dither runs at a constant resolution regardless of window size. Put `DmgDither`
inside that SubViewport (or your root viewport) — everything below its layer is dithered.

## Notes

- The LUT (`shaders/lut_512.png`) is imported **lossless, no VRAM compression** on purpose — VRAM
  compression would corrupt the 64-green palette. Its `.import` is committed; keep those settings.
- `DmgTerrainTextures` builds a six-layer atlas; the default `dmg_terrain.gdshader` only uses
  grass/dirt/rock (slope-based). The other layers are there if you want to add your own zone logic.
- Not included: slopfarm's on-screen **phone console bezel** (the painted Game Boy shell around the
  LCD with the D-pad/A/B chrome) and its touch input. That is ~1.2 MB of game-specific art rather
  than reusable engine, so it stays in the game. `DmgUI`/`DmgTitle` are the reusable interface; wire
  them to whatever input your project uses.

## License

Same as the slopfarm repository.
