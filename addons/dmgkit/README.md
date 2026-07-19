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
| `DmgScatter` | `scripts/dmg_scatter.gd` | Streams instances of your meshes (grass, trees, rocks, props) across the terrain in tiles — clumping, slope/height/exclusion rules, MultiMesh per tile. |
| `DmgDither` | `scripts/dmg_dither.gd` | The signature green-LCD post-process as a drop-in node: dices the frame into LCD dots, ordered-dithers, snaps to the 64 DMG greens in `lut_512.png`. |
| `DmgMeshKit` | `scripts/dmg_mesh_kit.gd` | Procedural vertex-coloured mesh builder — `box/quad/cylinder/cone/pipe/sphere/torus/…` merged into one flat-shaded mesh. |
| `DmgUI` | `scripts/dmg_ui.gd` | The DMG HUD + two-column menu (readout chips, list/detail/stats/description), pixel font, DMG palette. Content is data you set. |
| `DmgTitle` | `scripts/dmg_title.gd` | A boot title card: a cover image (or a rendered title string) plus a blinking "PRESS START". |
| `DmgConsole` | `scripts/dmg_console.gd` | An on-screen portrait handheld faceplate + touch input, composited from a sprite skin (`console/`): D-pad, A/B/C/X/Y/Z cluster, twin analog sticks, START/SELECT. Swap `skin_dir` to reskin. |
| `DmgShell` | `scripts/dmg_shell.gd` | Renders your world into a fixed-resolution SubViewport (so the dither runs at constant "LCD" res) and presents it via `DmgConsole` (mobile) or a crisp bare LCD (desktop/web). |

Shaders + LUT live in `shaders/`, the pixel font (Press Start 2P, OFL) in `fonts/`. A runnable
example is in `demo/demo.tscn` — open it and press Play, or read `demo/demo.gd` as the wiring
reference.

## Quick start — world + look

```gdscript
extends Node3D

func _ready() -> void:
    var terrain := DmgTerrain.new()
    terrain.player = $Camera3D              # any Node3D; streaming keys off its position
    add_child(terrain)
    terrain.prime(Vector3.ZERO)             # solid ground around a point immediately

    # Scatter trees in clumps (or grass, rocks, props — any meshes).
    var scatter := DmgScatter.new()
    scatter.clump = true
    scatter.slope_max_degrees = 24.0
    scatter.meshes = [my_tree_mesh_a, my_tree_mesh_b]  # DmgMeshKit meshes get a vertex-colour material
    scatter.allow_at = func(x, z): return not is_on_a_road(x, z)   # optional custom filter
    add_child(scatter)
    scatter.setup(terrain, $Camera3D)
    # For TEXTURED meshes (grass/leaf billboards, props): set scatter.vertex_color_material = false
    # (keeps each mesh's own material) or assign scatter.material = your_material.

    # The green-LCD dither over the whole viewport. Anything on a CanvasLayer ABOVE layer 100
    # (HUD, menus) stays crisp on top of the dithered world.
    add_child(DmgDither.create(100, 3.0, 0.17))   # (layer, dots-per-pixel, dither strength)
```

`terrain.height_at(x, z)` is a pure function — safe to call before any chunk exists (e.g. to spawn
something on the ground). Tune terrain via its `@export` vars (chunk size, view distance, hills,
slope→dirt/rock cutoffs, seed). Tune the look via `DmgDither.grid_size` and `dither_strength`.

## HUD + menu

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
    {"title": "STATUS", "lines": ["SCORE   01200"],
        "stats": [["BEST", "09400"]], "desc": "HOW YOU ARE DOING"},
    {"title": "OPTIONS", "lines": ["SOUND   ON"], "desc": "TWEAK THE GAME"},
])
ui.item_activated.connect(func(index, id): print("chose ", id))
# Drive it from input: ui.toggle_menu(), ui.nav(+1)/ui.nav(-1), ui.activate().
```

A title card: `var t := DmgTitle.new(); t.title_text = "MY GAME"; add_child(t)` (or set
`t.image` / `t.image_path` for cover art); call `t.dismiss()` on first input.

## Handheld shell (fixed buffer + console)

`DmgShell` renders your world into a fixed SubViewport and presents it as a handheld:

```gdscript
var shell := DmgShell.new()
shell.buffer_size = Vector2i(720, 720)          # the "LCD" resolution the dither keys to
add_child(shell)
# Put your world (camera, terrain, a DmgDither, your DmgUI) under shell.world_viewport:
shell.world_viewport.add_child(my_world)
# On a handheld export, shell.console is a DmgConsole — read input from it:
#   shell.console.move_vector, shell.console.look(), is_held("a"), button_pressed signal.
```

`DmgConsole` is a portrait Game Boy faceplate composited from a **sprite skin** in `console/`
(the case, bezel, D-pad direction states, the A/B/C/X/Y/Z keys with idle/pressed art, twin analog
sticks, and START/SELECT pills), laid out from `console/layout.json`. It reads:

- `move_vector` — left analog stick (−1..1, y+ = forward)
- `look()` — right-stick delta since the last call (camera look)
- `dpad_vector` — the D-pad as −1/0/1 per axis
- `button_pressed(id)` / `button_released(id)` signals and `is_held(id)` — ids `a b c x y z start select`

**Swappable art:** point `skin_dir` at your own folder with the same filenames + a `layout.json`
(shell size, the `screen` bezel placement, and `glass_in_shell`) to reskin the whole shell. With no
skin it falls back to showing the world full-rect, so the screen is never black.

## Notes

- The LUT (`shaders/lut_512.png`) is imported **lossless, no VRAM compression** on purpose — VRAM
  compression would corrupt the 64-green palette. Its `.import` is committed; keep those settings.
- `DmgTerrainTextures` builds a six-layer atlas; the default `dmg_terrain.gdshader` only uses
  grass/dirt/rock (slope-based). The other layers are there if you want to add your own zone logic.
- Font sizes in `DmgUI` are pinned to Press Start 2P's native 8-px cell so glyphs stay on-grid.

## License

Press Start 2P is under the SIL Open Font License. The rest is the slopfarm repository's license.
