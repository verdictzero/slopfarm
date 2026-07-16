# slopfarm

Chunk-based procedural low-poly landscape with a first-person controller, rendered
through an ordered-dither pass down to a custom 512-colour palette.

Targets the Raspberry Pi 5 (Broadcom V3D, OpenGL ES 3.1).

## The world

A dead-flat farm basin sits at the origin, ringed by rolling hills. Height is a pure
function of world position (`TerrainManager.height_at`), so chunks are deterministic
and can be built, freed and rebuilt with no bookkeeping.

The hills are placed relative to the **origin**, not the player — keyed to the player
they would recede as you walked toward them, and every chunk would rebuild differently
each step. Past the ring, a low-frequency region mask (not the ring alone) decides
where hills are allowed, so flat ground still dominates as you travel out.

`tools/probe_terrain.gd` checks that as numbers rather than vibes:

    godot-4 --headless --path . --script res://tools/probe_terrain.gd

## The farm designer

    python3 tools/farm_designer.py        # needs PySide6 + numpy

A top-down grid editor for `farm/plan.json`. Paint zones, say what each zone is and what
lives in it, drop structures, save. **Leave the game running while you edit** — it polls
the plan's modified time once a second and rebuilds itself, which is what makes this a
sidecar rather than a build step.

The plan is plain JSON and hand-editable; the app is a convenience, not the format's
owner. Rows are run-length encoded so a change to one pen touches a few lines rather than
rewriting 65k integers.

| | |
|---|---|
| **Zones** | Cells store a zone *id*; zones carry the meaning (ground, contents, fenced). Retyping a zone repaints every cell that belongs to it. Zone 0 = "not authored". |
| **Ground** | `pasture`, `dirt`, `road`, `crop` — indices into the ground texture array. |
| **Contents** | `cow` / `horse` + a count, scattered over that zone's cells (not its bounding box, so an L-shaped pen doesn't put a cow in the notch). |
| **Fenced** | Derived, not drawn: a post-and-rail fence is generated along every cell edge where the zone meets something else, merged to one mesh per zone. |
| **Structures** | Points with a yaw: barn, shed, silo, coop, trough, haystack, well. Procedural geometry — there is no building art. One merged mesh each, so one draw call each, and a trimesh body off that same mesh so you can't walk through them. |

Load-bearing decisions:

- **The plan overrides the *base* ground only.** Slope rules still apply on top, so a road
  climbing a bank still washes to dirt and rock the way the bank does. It replaced the old
  hash-generated pens outright — two systems inventing pens would be incoherent. A missing
  or broken plan is not fatal: the terrain's own rules are a complete fallback and the
  game still boots.
- **Nothing flattens the terrain.** `height_at` stays a pure function of position, so a
  reload rebuilds no chunks, re-derives no collision and never moves the player. The basin
  is flat enough to afford it (p90 3.7°), and structures carry a foundation skirt that
  sinks into the ground so the residual slop never shows as a gap. This is *why* live
  reload is cheap and safe.
- **The zone map is a runtime-generated R8 texture**, not a committed PNG — an imported
  one would be VRAM-compressed and mipmapped by default, silently corrupting the data.
  The shader reads it with `texelFetch`, not `texture()`: the read sits behind an early-out,
  i.e. inside non-uniform control flow, where the implicit derivative is undefined — the
  same rule the ground samples are held to. Fetching by integer cell also avoids an
  off-by-one where a pixel landing exactly on the far edge addressed texel 256 of 256.
- **The grid is 256×256 at 2 units** = a 512-unit square, chosen so its corners (362) sit
  inside the flat basin (380). Every cell is guaranteed to be on flat ground.
- **PySide6, not tkinter — because of zoom, not the blit.** Blitting the 256×256 grid
  costs tkinter 1.27 ms against Qt's 0.04 ms, which is a 32× gap but not a *reason*: 1.27
  ms is perfectly usable. The disqualifier is that `PhotoImage.zoom` scales on the CPU —
  2.90 / 11.42 / **52.21** ms at 3× / 6× / 12× — so it degrades exactly as you zoom in to
  place a fence. Qt hands scaling to the blitter, so pan and zoom stay flat.

The animals were unusable as shipped and are fixed at import, not in code:
`nodes/root_scale` (cow 90, horse 190 — they are authored at different scales, so there is
no one number; measured against a 1.5 m reference post) and `process/size_limit=256` on
their textures. Those textures are 4096² and 8192², which cost **53 MB of VRAM** in a game
that renders at 640×360 with a 512-colour palette and 32×32 ground textures.

## Ground cover

`scripts/terrain_textures.gd` builds three 32×32 textures from tileable value noise at
startup (~48 ms) — no committed binaries, and no `.import` file to keep honest.
`shaders/terrain.gdshader` picks between them per pixel from world-space planar UVs.

Two non-obvious decisions, both measured:

- **Textures are posterised to 4 tones, not smooth noise.** Everything is snapped to a
  512-colour palette downstream. A smooth-noise texture measured 131 unique colours in
  and 8 arbitrary ones out, which reads as speckle under the Bayer dither; a 4-tone ramp
  goes 4 → 4, so what is authored is what ships. Low contrast here is a *correctness*
  problem, not a taste one — a swing smaller than one palette cell is invisible.
- **The sampler is `filter_nearest_mipmap_anisotropic`.** Ground is only ever seen at a
  grazing angle, where a pixel's footprint along the view direction grows as *distance
  squared* while the lateral one grows linearly. An isotropic sampler takes the larger
  derivative and drops to a tiny mip early: measured, detail (stddev of luminance) fell
  from 6.5 at 6 units to 1.8 by ~40 units — the texture was gone long before the fog at
  200 could hide its absence. Anisotropic restores 1.3–1.8× of it through 10–35 units.
  `nearest` still governs magnification, so the chunky look up close is untouched.

Cover fractions are checked, not eyeballed (`tools/probe_cover.gd`), because a slope
threshold outside the terrain's real range is silently dead code — an earlier rule wanted
53°, on terrain that never exceeds 49°:

| region | grass | dirt | rock |
|---|---|---|---|
| farmyard | 73.8% | 26.2% (23.8 from plots) | 0% |
| basin | 90.6% | 9.4% | 0% |
| hills | 85.2% | 12.0% (12.9 from slope) | 2.8% |
| all visible | 86.0% | 11.6% | 2.4% |

**Slope rules texture the hills, not the farm.** The basin is p90 3.7° and maxes at 11°,
and dirt starts at 10° — so slope paints *0.0%* of where the player actually lives. The
farm's variety comes entirely from the enclosure plots and the per-face tint. Neither is
decoration; taking either away leaves a uniform green carpet.

The tint (`_tint_for`) is the other thing doing real work: it is the only *non-repeating*
macro field, which is what stops a 4-unit texture repeat reading as a grid. It is baked
per face, so it costs nothing per fragment. Rock tiles coarser (11 units) than grass and
dirt (4) because it only ever appears on distant hillsides seen close to face-on, where a
4-unit repeat tiled a dozen times across one slope and read as woven fabric.

## The palette and dither

`tools/gen_palette_lut.py` generates both committed PNGs in `shaders/` — rerun it after
changing the palette:

    python3 tools/gen_palette_lut.py     # needs numpy + pillow

- **`palette_512.png`** — 512 colours as 31 hue-shifted ramps plus 16 greys, reference
  only. Ramps shift toward blue as they darken and toward yellow as they lighten, with
  saturation peaking in the midtones. Channels land on a 5-bit ladder (15-bit-era
  colour). Leftover slots go where the palette is thinnest, by farthest-point insertion.
- **`lut_512.png`** — the lookup table the shader actually samples: a 64×64×64 RGB cube
  flattened to an 8×8 grid of blue slices, each cell pre-solved (in Oklab) to the
  nearest palette entry. This turns a 512-way search into one texture fetch.

`shaders/dither_lut.gdshader` adds an 8×8 Bayer offset per pixel and then snaps via the
LUT. The offset is what breaks quantisation into a pattern instead of flat banding.
A screen-space pattern depends on pixel position, so this step cannot itself be baked
into a colour-indexed table.

### Load-bearing settings

`project.godot` cannot hold comments — Godot rewrites the file and strips them — so the
reasoning lives here. These are measurements, not preferences:

| setting | why |
|---|---|
| `rendering_method=gl_compatibility` | The Pi's Vulkan (V3DV) driver is experimental; never Mobile/Forward+. |
| `anisotropic_filtering_level=2` (4×) | The ground sampler asks for anisotropic filtering; without this the request is a no-op and the terrain texture dies by ~40 units. Pinned rather than left to the engine default. |
| viewport `640×360` + `stretch/mode=viewport` + `scale_mode=integer` | The post-process shades a quarter of the fragments (it cost ~6 ms of an 18 ms frame at 720p), and the dither lands on real pixels that scale up as crisp squares. Replaces `scaling_3d/scale=0.5`, which rendered 3D at this size but blurred it on the way up. |
| `directional_shadow/size=1024` | 2048 was the single biggest cost in the frame (~7 ms): 4.2M depth samples per split × 2 splits, an order of magnitude more fill than the colour pass. |
| `lut_512.png` import: no VRAM compression, no mipmaps, `detect_3d/compress_to=0` | A LUT is data, not a picture. ETC2 or mipmaps corrupt the mapping, and `detect_3d` would silently re-import it compressed once it's used from a 3D scene. |

Fog `depth_end` is pinned to the **guaranteed** terrain radius, which is shorter than
`view_distance * chunk_size`: a chunk just outside the streamed circle can start much
nearer once the player's offset within their own chunk is counted (at 6 / 192 that's
960 units, not 1152). If the fog is not opaque by then, the world visibly ends. Change
`view_distance` or `chunk_size` and `main.gd`'s `fog_depth_end` must move too.

Also note `fog_density` **multiplies** the begin/end ramp in `FOG_MODE_DEPTH` — it is
not a per-unit rate. It needs to be ~1.0; at small values the fog is effectively absent.

## Tools

Development only, not shipped. `.shots/` is gitignored.

| | |
|---|---|
| `tools/farm_designer.py` | The farm editor. `tools/farm_plan.py` is the shared schema. |
| `tools/gen_palette_lut.py` | Regenerates the palette and bakes the LUT. |
| `tools/farmshot.tscn` | Screenshots of the authored farm. |
| `tools/probe_terrain.gd` | Terrain shape statistics, headless. |
| `tools/probe_slope.gd` | Slope distribution — run before touching any slope threshold. |
| `tools/probe_cover.gd` | What the grass/dirt/rock rules actually claim, area-weighted. |
| `tools/shot.tscn` | Screenshots into `.shots/`. |
| `tools/perf.tscn` | Frame timing while walking out from the farm. |
| `tools/isolate.tscn` | `-- mode=<full\|nopost\|noshadow\|...>`, one config per process. |

Perf tools report **median** frame time, not mean, and disable vsync. Background load
can only ever make a frame slower, so on a busy desktop the mean measures whatever else
is running — during development a browser at ~95% CPU made an *empty* scene appear to
cost 15 ms/frame. Measure with the machine as quiet as possible.
