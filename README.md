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
| **Ground** | `pasture`, `dirt`, `road`, `crop`, `mud` — indices into the ground texture array. Append-only: the integers are in `plan.json`, so reordering silently repaints every zone. |
| **Contents** | `horse` + a count, scattered over that zone's cells (not its bounding box, so an L-shaped pen doesn't put an animal in the notch). They walk: wander to a spot in their zone, amble there, stand a while, repeat. |
| **Growing** | The ground type alone decides what grows — painting a zone *is* saying what it is. A `crop` zone grows wheat from `sprites/wheat_plant_*.png`; a `pasture` zone grows grass tufts generated at startup (`GrassSprites`). Both go through the same scatter: Y-billboarded, one MultiMesh per variant per 16 m block, culled per block by distance. |
| **Fenced** | Derived, not drawn: a post-and-rail fence is generated along every cell edge where the zone meets something else, merged to one mesh per zone — gate included. |
| **Structures** | Points with a yaw, all procedural geometry — there is no building art. One merged mesh each, so one draw call each, and a trimesh body off that same mesh so you can't walk through them. The yard: `house`, `barn`, `shed`, `silo`, `coop`, `well`. Grain: `granary`, `corn_crib`, `grain_bin`. Machinery and livestock: `machine_shed`, `stable`, `pigsty`. Landmarks: `windmill`, `water_tower`. Clutter: `trough`, `haystack`, `hay_feeder`, `compost_heap`, `fuel_tank`, `log_pile`. |

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

### What the plan implies but doesn't say

Three things are *derived* from the plan rather than authored in it, on the same footing as
the fences. A fence isn't drawn either — it falls out of "this zone is fenced" plus the
zone's shape. These fall out the same way, and re-derive when you move what they hang off.

This is the README's own rule about not letting two systems invent the same thing, applied
rather than repeated. None of these decides where anything *should be*; each answers a
question the plan already implies:

- **Gates** (`FarmPlan._derive_gates`). One per fenced zone, on the stretch of fence
  nearest the road — a gate exists to be driven through, so it belongs where the traffic
  already is. The fence leaves those cells empty and hangs a leaf in the hole, swung nearly
  flat: a shut gate is a fence with extra steps, and reads as nothing from ten metres.
  Held on the plan rather than worked out in `FarmBuilder` because *three* things need the
  same answer — the fence (to leave a hole), the roads (to aim at it) and the trample map
  (to muddy it). Derived twice is derived differently the day one of them changes.
- **Tracks** (`FarmRoads`). The designer paints a trunk road, hangs gates and drops
  buildings; this joins them up. Greedy nearest-first attachment via `AStarGrid2D` — C++,
  because this runs on every save and the same loop in GDScript does not finish in time.
  Each spur joins whatever road already exists, so two gates on one side of the farm share
  a track out instead of running parallel. Pen interiors are solid and only the gate cell is punched walkable, so
  a spur arrives *at* the gate and stops rather than driving through the herd. Crop is
  expensive but not solid — impassable would mean a barn behind a wheat field silently
  loses its track. **No trunk means no network**: inventing one would be exactly the second
  opinion this avoids.
- **Trampling** (`FarmPlan.trample_field`). Only zones that actually hold animals — an
  empty pen is fenced grass. Three sources, because they're the three places stock stand
  rather than graze: the gate they queue at, the troughs and feeders they crowd, and the
  fence line they walk. The noise modulates the *radius*, not the result: the palette has
  about four usable steps across this ramp, so a clean radial falloff quantises into four
  hard concentric rings under the dither. Perturbing the radius makes the steps wander.

Tracks are stamped into the ground-layer **texture**, never back into `cells`. `cells` is
the designer's document, and a spur is not a zone — it has no contents, no fence and no
name, so writing one in would put zone ids in the file with no zone to go with them.

All three run on every save, so `tools/probe_derive.gd` keeps them honest:

    godot-4 --headless --path . --script res://tools/probe_derive.gd

| | |
|---|---|
| parse + gates + tracks | 115 ms |
| ...of which `FarmRoads.derive` | 90 ms (479 cells, 21 structures) |
| `trample_field` | 77 ms, then 0 cached |

**The track cost scales with destination count, not farm size** — one A* run plus a nearest
scan per gate and per open-air structure. It was 36 ms at 7 structures and 90 ms at 21, so
a yard with a hundred props is the thing that would make saving hurt, not a bigger map.
`trample_field` is cached because the shader's texture and the grass scatter both want it,
and paying 77 ms twice a save for the same immutable answer is just a bug with good manners.

Mud is the one ground type that is **blended** rather than chosen, which is why it costs
the shader a fourth sample where every other type shares one indexed fetch. It rides a
separate `trample_map`, read by `texelFetch` on the integer cell exactly like `zone_map`.

`trample_map` was briefly `filter_linear`, on the reasoning that trampling is a physical
gradient and wants interpolating across cells where a pen's edge does not. **That was wrong,
and the measurement says so**: rendered both ways the mud is indistinguishable — mean |d/dx|
33.53 linear vs 33.46 nearest standing on it, identical max, and `texelFetch` comes out
bit-identical to the nearest sampler. The reason is one this file already knew: the palette
has ~4 usable steps across that ramp, so it quantises the blend *coarser than the 2 m cell
grid the interpolation was smoothing*. Linear bought sub-cell smoothness that the 512-colour
snap then threw away.

That generalises, and it is worth stating once: **this game snaps everything to 512 colours,
so any gradient finer than a palette step is invisible by construction.** Smoothing below
that resolution is never a trade-off here — it is just cost.

The blend is what makes this survive contact with a 200×150 m grazing field: forcing every
animal zone to mud would turn West Pasture into a bog with animals in it. Grass thins by the
same field — the probability a tuft is skipped *is* the trample value, so the grass fades
out exactly as the mud fades in, and a hard threshold would draw a visible contour around
every gate.

### Animals and crop, and what they cost

Everything about the walk is measured off the one clip the models ship with
(`Armature|Unreal Take|baselayer`, 1.0 s), because nothing documents it:

- It's a **walk**, not an idle — the leg joints swing 170–180° through the cycle.
- It has **no root motion**, so the script moves the node and the clip does the legs.
- It **doesn't loop** as imported (`LOOP_NONE`). Left alone it plays once and freezes
  mid-stride, which is what the farm shipped doing.
- **Stride is 0.91 m/cycle for the horse**, measured as the fore-aft excursion
  of the feet in world space. Walking faster than stride/cycle *is* moonwalking, so speed
  and playback rate are derived from each other, never picked separately.
- There's no idle pose, so **standing** means holding the frame where all four feet are
  down: t=0.183 for the horse.

**An animating skeleton is the most expensive thing on the farm** — ~0.15 ms each. 76 of
them measured 18.06 ms/frame against 12.50 ms for 38, while the entire wheat field cost
less. (An earlier measurement found animals free; that was taken while the `LOOP_NONE`
bug had them frozen, so nothing was skinning.) Both are distance-culled: animals go
dormant past 55 m, crop blocks are dropped past 34 m. That's worth ~5.4 ms and is what
lets 76 animals and a full-density field coexist.

Counter-intuitively, **crop density matters and crop cull distance barely does**: the cost
is fill from *near* sprites, which are never culled. Culling 46→30 m bought 1 ms and then
hit a floor; halving density bought 4 ms. Crop is unshaded with the sun baked in, because
a billboard's normal faces the camera — lit, the stalks measured 5.2× the brightness of
the ground they stand in, i.e. neon yellow in a dark field.

**Pasture grass takes that measurement as its brief.** It goes over ~40,000 m² of pasture
where the whole wheat field is 12,500, and it can only afford that by being *small* rather
than by being far away: a tuft is 0.4 m against the wheat's 1.5 m, roughly 14× less fill
each. Density (5/m²) is set for the look and the cull (22 m) is short because a 0.4 m tuft
is sub-pixel at 640×360 long before then — the mipmapped cutout has already thinned it to
nothing by ~20 m, which is free distance fade.

Grass is baked at `GRASS_LIGHT` 0.50, and that number is measured the same way the crop's
was: lit pasture renders (33,49,25), and at 0.72 the tufts came out (66,74,41) — 1.5–2× the
ground. That's the crop's neon-field failure again, just quieter, and it read as pale sprigs
scattered *on* pasture rather than as the pasture itself.

| grass | median | draws | VRAM |
|---|---|---|---|
| standing in the pasture, on | 3.33 ms | 230 | 41.0 MB |
| standing in the pasture, off | 2.78 ms | 212 | 31.9 MB |

So **+0.55 ms and +9.1 MB**, in the worst case the harness has (deep in West Pasture with
nothing else to draw). Everywhere else it's inside the noise — the "farm, eye height" pass
came out *faster* with grass on, which is the honest measure of this box's noise floor
(~0.4 ms). **These are dev-box numbers, not Pi numbers**, unlike every other measurement
here: this box renders the farm in ~2.4 ms where the Pi took 18. Treat the delta as a
ratio, not a budget, and re-measure on the Pi before trusting it.

The VRAM is the part worth knowing: 5/m² over 40,000 m² is ~204k instances × 48 bytes of
transform ≈ 9.8 MB, which is what the +9.1 measures. Those buffers exist for the whole
pasture even though only a 22 m circle is ever drawn — the cull drops *draws*, not memory.
Density is the only lever on it, which is the same conclusion the crop reached by a
different road.

(`tools/probe_cover.gd` and the cover table above model the *slope* rules, which none of
this changed. Neither models the trample blend or the derived tracks, so both now describe
the ground's base rules rather than every pixel of it.)

The horse was also unusable as shipped and is fixed at import, not in code:
`nodes/root_scale` 190 (authored small; measured against a 1.5 m reference post) and
`process/size_limit=256` on its texture — which shipped as an 8192² PNG embedded in the
`.glb`, 49 MB of dead weight in a game that renders at 640×360 with a 512-colour palette and
32×32 ground textures. `tools/glb_externalize_textures.py` extracts that texture to a 256²
external sidecar and strips the embedded copy (`horse.glb`: 49 MB → 265 KB), so the clamp is
belt-and-suspenders rather than load-bearing. The logo and meat grinder models got the same
treatment.

### Wild grass off the pens

The pasture scatter above stops at the fence — it only sows zones the designer painted
`pasture`. Everywhere else the ground *reads* as grass (the flat basin, the verges, the
lower slopes) it was a bare texture. `scripts/terrain_grass.gd` fills that in with short,
medium and tall clumps (`GrassSprites` grew three height tiers for it), streamed in 16 m
tiles around the player exactly like the terrain chunks and freed the same way — the world
is unbounded and the cull is short, so only a handful of tiles near the player are ever
worth having.

Two rules keep it from fighting the systems already there. It skips any cell the plan
authored (`FarmPlan.zone_at != 0`), so a road, a crop field or a pasture keeps its own
cover and the pens are left exactly as they were — the task was to add grass to the *terrain*,
not to re-tuft the paddocks. And it takes the ground shader's own grass test — slope under
the dirt threshold, above the water line — so a clump only ever stands where the ground
under it is actually drawn as grass, never fringing a bank the shader is painting dirt. The
factory hands it its footprint as an exclusion so grass does not grow up through the slab.

## The glue works

East of the farm, next to the horse pen it feeds from, stands a walk-in factory
(`scripts/glue_factory.gd`). It is built the way the farm is — procedural, one merged
vertex-coloured mesh per object through `scripts/mesh_kit.gd` (the primitives FarmBuilder
grew inline, factored out so a second builder does not re-invent them), each with a trimesh
body off that same mesh. It sits on the flat basin like every farm structure: the floor slab
is a foundation reaching below the ground, and a wedge ramp at the door makes up the last few
centimetres, because the player has no step-up.

Inside are the nine unit operations from `glue_factory_pipeline_notes.txt`, in a line down
the centre with aisles either side — grinder, renderer, chemistry soak, extraction, filter
press, evaporator, chill-extruder, drying tunnel, mill. They wear the notes' three phase
colours (coral mechanical front, teal wet chemistry, amber finish). The shipped
`meat_grinder.glb` is the grinder's body, fitted and grounded by `MeshKit.place_upright`
regardless of its authored scale; the rest are procedural, three of them with a part that
spins.

The pipeline is a small state machine per batch. Feed a horse at the intake and a batch
enters the grinder; each machine holds it for a dwell, transforms the stream to the next of
ten appearances (chunks → mince → defatted solids → limed matrix → liquor → clarified liquor
→ syrup → gelled noodles → dried shards → a sacked granule), and hands it down a conveyor to
the next machine, which will not take it until it is free. Rendering sheds a tallow drum to a
side bin; the mill stacks finished sacks on a pallet at the far end. A machine processes one
batch at a time, so a queue of horses actually queues.

## Clouting horses

The player carries the shipped `heart_wand.glb` (fitted to hand size by mesh bounds, since
the asset ships at an arbitrary scale). Left-click swings it; the nearest living horse inside
the wand's reach and forward cone takes the hit. Hitting is a scripted cone test over the
`horse` group, not a physics ray — the animals are cheap `Node3D`s with no body, and a group
lookup keeps the check decoupled from the farm's node layout.

A few hits and the animal drops. `FarmAnimal` swaps itself for a `HorseRagdoll` — the same
model, gone limp on a single physics body that flops from the blow and settles. Not a
per-bone ragdoll: the rig ships with one clip and no physical skeleton, so a single capsule-ish
body with the mesh riding it tumbles well enough at this scale and, unlike a bone chain,
cannot explode. The ragdoll is parented to the scene rather than the farm, so a plan reload
(which wipes and rebuilds the farm) does not delete a horse you dropped by the factory.

E (or right-click) picks a ragdoll up — it goes kinematic and stops colliding so it rides in
front of the camera instead of fighting the player capsule — and pressing it again at the
intake feeds it in, or sets it down anywhere else. That closes the loop the factory was built
for: knock a horse out by the pen, carry it next door, and watch it come out the far end as
sacks.

## The icon

`icon.svg` replaces the old 1 MB raster wordmark, generated by `tools/gen_icon.py`. It is a
blocky "SLOP / FARM" set in a 5×7 pixel font and emitted as plain `<rect>`s — pixel
letterforms suit a game that snaps everything to nearest-neighbour, and rects (not an
`<text>` element or a raster autotrace) render identically in every SVG backend including
Godot's, which has no font engine. A brown drop-shadow layer under the orange one keeps the
carved-wood read of the original on the same teal field.

    python3 tools/gen_icon.py     # writes icon.svg + icon.svg.import

`icon.png` is that same icon rasterised at 512×512 (`tools/svg_to_png.gd`, through Godot's own
ThorVG renderer so it matches exactly), and it is what the Android preset uses for the APK
launcher icon. Rerun `tools/svg_to_png.gd` after editing the vector to keep the two in step:

    godot --headless --path . --script tools/svg_to_png.gd    # icon.svg -> icon.png

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

### Every texture is nearest-filtered, and one of them wasn't

The look depends on it end to end, so it is worth writing down as a rule rather than a
habit: **nothing in this game is ever smoothed.** `tools/probe_filter.gd` audits it.

The upscale itself is free — with `stretch/mode=viewport`, Godot's GL Compatibility
renderer hardcodes the blit to `GL_NEAREST` (`_blit_render_target_to_screen`), so 640×360 →
1280×720 arrives as crisp squares with no setting involved. `rendering/scaling_3d` cannot do
this: its modes are Bilinear/FSR only, which is exactly why it was dropped (see the table
below).

Everything upstream of the blit asks for nearest explicitly — the ground
(`filter_nearest_mipmap_anisotropic`), the zone and trample maps, both dither fetches, and
the crop/grass billboards (`NEAREST_WITH_MIPMAPS`).

**The animals were smoothed for months.** `horse.glb` came out of the importer
at `LINEAR_MIPMAP` — the only linear-filtered art in the game. It hid because texture
filtering on a 3D material is a **material** property, not an import setting, so it never
appears in a `.import` file next to the `compress/mode` and `mipmaps/generate` lines you'd
actually think to audit. `FarmBuilder._force_pixel_look` drags it into line at
instantiate; the materials come off the `.glb` shared, so it reaches every animal,
the same way the walk's `LOOP_LINEAR` fix does.

The moral is the same one `lut_512.png`'s hand-written `.import` exists to enforce, one
level further in: **the importer's defaults are not this game's defaults**, and the settings
it does not write down are the ones that bite.

Structure materials are `CULL_DISABLED`. Most of what `FarmBuilder` builds is a closed box
that never shows a backface, but not all of it — the machine shed's roof is a single `_quad`
and every `_gable` is two, so one-sided they vanish from under the eaves. Measured, it costs
nothing detectable (identical medians on every pass that has structures in view).

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

## Toolchain on Claude Code web

Web sessions run in a fresh, ephemeral container, so the engine and the Android
toolchain have to be reinstalled each time. `.claude/hooks/session-start.sh` (a
SessionStart hook registered in `.claude/settings.json`) does that, and the
container-state cache makes it effectively persistent — the first session on an
environment pays the download, later ones find everything under `/opt` and skip in
seconds. It is idempotent and web-only (`CLAUDE_CODE_REMOTE`).

The one wrinkle worth writing down: **Godot is only distributed from github.com,
which this environment's egress policy blocks** (403 at the agent proxy). Docker Hub
is reachable, and `barichello/godot-ci:4.7` carries the identical official binary
plus the export templates, so `.claude/hooks/pull_godot.py` pulls them out of that
image's layers over the registry HTTP API — no docker daemon needed. The Android SDK
comes straight from `dl.google.com`, which the policy allows.

What lands, matched to the project's Godot 4.7 Android build template:

| | |
|---|---|
| Godot 4.7 editor (headless-capable) | `/opt/godot/godot`, symlinked onto `PATH` |
| Export templates (Android + Linux) | `~/.local/share/godot/export_templates/4.7.stable/` |
| Android SDK: platform-tools, `platforms;android-36`, `build-tools;36.1.0`, `ndk;29.0.14206865` | `/opt/android-sdk` |
| Debug keystore + editor settings for headless Android export | `/root/debug.keystore`, `editor_settings-4.tres` |

`GODOT`, `ANDROID_HOME`, `ANDROID_NDK_ROOT`, `JAVA_HOME` and the `PATH` additions are
written to `$CLAUDE_ENV_FILE` for the session. A full APK export additionally needs
Gradle/Maven reachable at build time, which depends on the same egress policy.

## Tools

Development only, not shipped. `.shots/` is gitignored.

| | |
|---|---|
| `tools/farm_designer.py` | The farm editor. `tools/farm_plan.py` is the shared schema. |
| `tools/gen_palette_lut.py` | Regenerates the palette and bakes the LUT. |
| `tools/farmshot.tscn` | Screenshots of the authored farm. |
| `tools/probe_terrain.gd` | Terrain shape statistics, headless. |
| `tools/probe_slope.gd` | Slope distribution — run before touching any slope threshold. |
| `tools/probe_derive.gd` | Times gates, tracks and trampling — run before adding anything the plan derives, since all of it runs on every save. |
| `tools/probe_filter.gd` | Audits every 3D material's texture filter and cull mode. Filtering is a *material* property, not an import setting, so a `.glb`'s materials never show up in a `.import` file to be eyeballed — this is how you find the one that is quietly linear. |
| `tools/probe_cover.gd` | What the grass/dirt/rock rules actually claim, area-weighted. |
| `tools/shot.tscn` | Screenshots into `.shots/`. |
| `tools/perf.tscn` | Frame timing while walking out from the farm. |
| `tools/isolate.tscn` | `-- mode=<full\|nopost\|noshadow\|...>`, one config per process. |

Perf tools report **median** frame time, not mean, and disable vsync. Background load
can only ever make a frame slower, so on a busy desktop the mean measures whatever else
is running — during development a browser at ~95% CPU made an *empty* scene appear to
cost 15 ms/frame. Measure with the machine as quiet as possible.
