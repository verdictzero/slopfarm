extends RefCounted
class_name DmgTerrainTextures
## Builds the low-res ground textures from tileable value noise, as one Texture2DArray.
##
## Generated at startup rather than baked to PNGs: these are six 32x32 images, about
## 6k texels of cheap noise, which costs milliseconds. Committing binaries and
## hand-writing .import files to defeat VRAM compression -- the dance lut_512.png has
## to do -- would buy nothing and adds two more things to keep in sync.
##
## Two decisions here are measured rather than tasteful:
##
## Tones are quantised to a four-step ramp per material. Everything downstream gets
## snapped to a 512-colour palette, and smooth noise gradations do not survive that:
## measured, a smooth-noise texture went from 131 unique colours to 8 arbitrary ones,
## which reads as speckle under the Bayer dither. A texture built from four chosen
## tones goes 4 -> 4, so what is authored here is what ships.
##
## The noise is tileable by construction -- the value-noise lattice wraps at `period`,
## and each octave doubles the period along with the frequency. FastNoiseLite cannot do
## this (it has no seamless mode; NoiseTexture2D's `seamless` flag is a separate,
## slower cross-blend), and a seam repeated across a flat plain would be glaring.
##
## All six layers live in ONE Texture2DArray so a shader can pick a layer by an index read from a
## texture, keeping the cost flat however many ground types you offer (a sampler cannot be indexed
## dynamically). The default dmg_terrain.gdshader only samples grass/dirt/rock by slope; the other
## three (road/crop/mud) are here as an extension hook for your own zone/paint shader.

## Texture side in pixels. Low-res on purpose: this is the "nearest neighbour" look.
const SIZE := 32
## World units per texture repeat for grass and dirt. At 32px this puts one texel at
## roughly 2.3 game pixels when the ground is 15 units away, which is where the player
## mostly looks. Larger tiles read as blobs; smaller ones stop reading as pixel art.
const TILE_WORLD_UNITS := 4.0
## Rock repeats coarser. It only ever appears on the steepest ~2% of ground -- distant
## hillsides seen close to face-on -- where a 4-unit repeat tiles about a dozen times
## across one slope and reads as woven fabric rather than stone.
const ROCK_TILE_WORLD_UNITS := 11.0

# Layer indices into the array. The default shader uses PASTURE (grass, index 0), DIRT (1) and
# ROCK (5); ROAD/CROP/MUD (2/3/4) are extra ground types you can index from your own zone shader.
const LAYER_PASTURE := 0
const LAYER_DIRT := 1
const LAYER_ROAD := 2
const LAYER_CROP := 3
const LAYER_MUD := 4
const LAYER_ROCK := 5
const LAYER_COUNT := 6

# Four tones per material, dark to light. These are albedo, so lighting scales them
# before the palette sees them -- they are deliberately mid-range, not near-white.
const GRASS_RAMP: Array[Color] = [
	Color(0.20, 0.31, 0.13), Color(0.27, 0.42, 0.17),
	Color(0.34, 0.51, 0.21), Color(0.43, 0.60, 0.27),
]
const DIRT_RAMP: Array[Color] = [
	Color(0.28, 0.19, 0.12), Color(0.36, 0.26, 0.16),
	Color(0.45, 0.33, 0.21), Color(0.54, 0.41, 0.28),
]
const ROCK_RAMP: Array[Color] = [
	Color(0.28, 0.27, 0.27), Color(0.37, 0.36, 0.35),
	Color(0.46, 0.45, 0.43), Color(0.56, 0.55, 0.52),
]
# Pale, cool and gritty, so a road reads as laid rather than as worn earth.
const ROAD_RAMP: Array[Color] = [
	Color(0.31, 0.30, 0.28), Color(0.42, 0.41, 0.38),
	Color(0.53, 0.51, 0.47), Color(0.64, 0.62, 0.57),
]
# Golden-green: a planted field, not bare tilth. Standing crop is furrows of colour from
# above, and the game has no props to stand up in it.
const CROP_RAMP: Array[Color] = [
	Color(0.29, 0.30, 0.13), Color(0.42, 0.40, 0.17),
	Color(0.56, 0.50, 0.21), Color(0.69, 0.62, 0.28),
]
# Darker, wetter and greyer than dirt, which is the whole point of having both: mud is
# blended ON TOP of dirt around a gate (see the trample map), so if it read as just more
# dirt the trampling would be invisible exactly where it is strongest. Measured against
# DIRT_RAMP this is ~0.6x the luminance and half the saturation.
const MUD_RAMP: Array[Color] = [
	Color(0.16, 0.13, 0.11), Color(0.22, 0.18, 0.15),
	Color(0.29, 0.24, 0.19), Color(0.36, 0.31, 0.25),
]

# Lattice period across one tile. 4 gives features a few texels across at this size.
const BASE_PERIOD := 4


## The ground atlas: one Texture2DArray, LAYER_* indexed.
static func build(noise_seed: int) -> Texture2DArray:
	var images: Array[Image] = []
	images.resize(LAYER_COUNT)
	images[LAYER_PASTURE] = _make(&"grass", GRASS_RAMP, noise_seed + 101)
	images[LAYER_DIRT] = _make(&"dirt", DIRT_RAMP, noise_seed + 211)
	images[LAYER_ROAD] = _make(&"road", ROAD_RAMP, noise_seed + 419)
	images[LAYER_CROP] = _make(&"crop", CROP_RAMP, noise_seed + 523)
	images[LAYER_MUD] = _make(&"mud", MUD_RAMP, noise_seed + 631)
	images[LAYER_ROCK] = _make(&"rock", ROCK_RAMP, noise_seed + 307)

	var array := Texture2DArray.new()
	var err := array.create_from_images(images)
	if err != OK:
		push_error("ground texture array failed to build: %d" % err)
	return array


static func _make(kind: StringName, ramp: Array[Color], seed_value: int) -> Image:
	var field := PackedFloat32Array()
	field.resize(SIZE * SIZE)
	var lowest := 1e9
	var highest := -1e9
	for j in SIZE:
		for i in SIZE:
			var u := float(i) / float(SIZE) * float(BASE_PERIOD)
			var v := float(j) / float(SIZE) * float(BASE_PERIOD)
			var value := _material_field(kind, u, v, seed_value)
			field[j * SIZE + i] = value
			lowest = minf(lowest, value)
			highest = maxf(highest, value)

	# Stretch to the full ramp: raw fBm clusters around the middle, which would leave
	# the darkest and lightest tones unused and the texture flat.
	var span := maxf(highest - lowest, 0.0001)
	var image := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for j in SIZE:
		for i in SIZE:
			var t := (field[j * SIZE + i] - lowest) / span
			var step := clampi(int(t * ramp.size()), 0, ramp.size() - 1)
			image.set_pixel(i, j, ramp[step])

	# Mipmaps are not a betrayal of "nearest neighbour": the sampler uses
	# filter_nearest_mipmap_anisotropic, so magnification stays hard-edged (the retro
	# look) while minification stops the texture aliasing into noise. Without them a
	# texel is already sub-pixel by ~40 units out and the ground crawls as you walk.
	image.generate_mipmaps()
	return image


## Per-material noise recipe. Each returns roughly 0..1 before ramp stretching.
static func _material_field(kind: StringName, u: float, v: float, seed_value: int) -> float:
	match kind:
		&"grass":
			# Broad clumps plus a fine speckle, so it reads as blades rather than fog.
			return 0.55 * _fbm(u, v, BASE_PERIOD, 3, seed_value) \
				+ 0.45 * _fbm(u * 4.0, v * 4.0, BASE_PERIOD * 4, 2, seed_value + 7)
		&"dirt":
			# Coarser and lumpier: clods and the odd pale pebble.
			return 0.60 * _fbm(u, v, BASE_PERIOD, 3, seed_value) \
				+ 0.40 * _fbm(u * 3.0, v * 3.0, BASE_PERIOD * 3, 2, seed_value + 13)
		&"road":
			# High-frequency and low-structure: loose gravel, no clumping.
			return 0.35 * _fbm(u, v, BASE_PERIOD, 2, seed_value) \
				+ 0.65 * _fbm(u * 5.0, v * 5.0, BASE_PERIOD * 5, 2, seed_value + 17)
		&"crop":
			# Furrows. u spans BASE_PERIOD across the tile, so a whole number of cycles
			# over that span keeps the rows tiling — one ridge per world unit at a
			# 4-unit tile. The noise stops it reading as a barcode.
			var furrow := 0.5 + 0.5 * sin(u * TAU)
			return 0.60 * furrow + 0.40 * _fbm(u * 2.0, v * 2.0, BASE_PERIOD * 2, 3, seed_value)
		&"mud":
			# Broad wallows with hoof pocking on top. The pocking is squared to bias it dark:
			# churned ground is mostly hollows with the odd ridge between them, and a
			# symmetric noise reads as gravel instead of as mud.
			var wallow := _fbm(u, v, BASE_PERIOD, 2, seed_value)
			var pock := _fbm(u * 6.0, v * 6.0, BASE_PERIOD * 6, 2, seed_value + 23)
			return 0.60 * wallow + 0.40 * pock * pock
		_:
			# Rock gets ridges: 1 - |signed noise| creates creases that read as cracks.
			var crack := 1.0 - absf(_fbm(u * 2.0, v * 2.0, BASE_PERIOD * 2, 3, seed_value + 19) * 2.0 - 1.0)
			return 0.65 * _fbm(u, v, BASE_PERIOD, 4, seed_value) + 0.35 * crack


## Fractal value noise. `period` is the lattice wrap, doubled per octave alongside the
## frequency so every octave -- and therefore the sum -- tiles.
static func _fbm(x: float, y: float, period: int, octaves: int, seed_value: int) -> float:
	var total := 0.0
	var amplitude := 1.0
	var normaliser := 0.0
	var frequency := 1.0
	var wrap := period
	for octave in octaves:
		total += _value_noise(x * frequency, y * frequency, wrap, seed_value + octave * 101) * amplitude
		normaliser += amplitude
		amplitude *= 0.5
		frequency *= 2.0
		wrap *= 2
	return total / normaliser


static func _value_noise(x: float, y: float, period: int, seed_value: int) -> float:
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - float(x0)
	var fy := y - float(y0)
	var u := fx * fx * (3.0 - 2.0 * fx)
	var v := fy * fy * (3.0 - 2.0 * fy)
	# posmod, not %, so the lattice wraps correctly for negative coordinates.
	var a := _hash01(posmod(x0, period), posmod(y0, period), seed_value)
	var b := _hash01(posmod(x0 + 1, period), posmod(y0, period), seed_value)
	var c := _hash01(posmod(x0, period), posmod(y0 + 1, period), seed_value)
	var d := _hash01(posmod(x0 + 1, period), posmod(y0 + 1, period), seed_value)
	return lerpf(lerpf(a, b, u), lerpf(c, d, u), v)


static func _hash01(ix: int, iy: int, seed_value: int) -> float:
	# GDScript ints are 64-bit; mask back to 32 so the mixing actually overflows the way
	# the constants assume.
	var h: int = (ix * 374761393 + iy * 668265263 + seed_value * 1274126177) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return float((h ^ (h >> 16)) & 0x7FFFFFFF) / 2147483647.0
