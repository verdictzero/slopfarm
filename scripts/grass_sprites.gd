extends RefCounted
class_name GrassSprites
## Builds the grass tufts the pasture is scattered with, at startup.
##
## Generated, not authored, for the same reason TerrainTextures is generated: a tuft is a
## dozen tapered lines whose entire art direction is "tones off the grass ramp", so a
## committed PNG would buy nothing and add a binary plus a hand-written .import to keep
## honest. The wheat next door IS authored art, and the difference is real — a wheat plant
## has a silhouette somebody had to decide, and a clump of grass does not.
##
## Drawn to an alpha-cutout RGBA image rather than built as geometry: these are scattered
## tens of thousands of times, and a MultiMesh of quads is one draw call per block where
## real blades would be a vertex budget all of their own.

## Tuft side in pixels. Deliberately tiny: at 640x360 a tuft five metres away is about 24
## pixels tall, so 32 is already more than the screen can show.
const SIZE := 32
## Pixels per world metre, which fixes SIZE at 0.4m. Ankle-high on the player — grass, not
## pampas. This is NOT the crop's 212: a tuft drawn at the wheat's scale would be a 1.5m
## reed bed, and the two are separate numbers because they are separate plants.
const PIXELS_PER_METRE := 80.0

## Blades per tuft. Each sprite is a CLUMP, the same trick the crop uses — the field reads
## as full at a density the frame can actually afford, because one instance is many blades.
const BLADES := Vector2i(7, 11)

# ---- height tiers ------------------------------------------------------------
# The pasture tuft above is one fixed size (0.4 m). Open grassland outside the pens wants
# more than that — short, medium and tall clumps scattered together read as wild ground
# rather than a mown paddock. These tiers are what TerrainGrass sows over the terrain's
# own grass; the pens keep the single pasture tuft, which is deliberately left alone.
#
# The art is still the same 32x32 clump; a tier is a taller blade fill plus a larger world
# quad, not a bigger texture. World height (not PIXELS_PER_METRE) is what separates them,
# so a tall tuft is the same handful of texels stretched — which stays honest under the
# nearest-neighbour magnify.
const TIER_SHORT := 0
const TIER_MEDIUM := 1
const TIER_TALL := 2
const TIER_COUNT := 3

## World height of each tier's quad, in metres. All below the crop's 1.5 m — this is
## grass, not a reed bed — and spanning ankle to shin so the mix has visible relief.
const TIER_HEIGHT: Array[float] = [0.28, 0.52, 0.9]
## Blades per clump per tier: taller grass is fuller, so a lone tall blade does not read
## as a stray reed.
const TIER_BLADES: Array[Vector2i] = [Vector2i(4, 7), Vector2i(6, 10), Vector2i(9, 14)]
## How much of the image height the blades fill, per tier. Short grass sits low in its
## quad; tall grass runs nearly the full height.
const TIER_FILL: Array[Vector2] = [Vector2(0.45, 0.7), Vector2(0.6, 0.92), Vector2(0.78, 1.0)]
## Maximum blade lean per tier. Taller blades stand straighter — a tall clump leaning like
## a short one reads as flattened grass.
const TIER_LEAN: Array[float] = [9.0, 8.0, 6.5]


## `variants` tufts, each a different arrangement of the same idea. Pasture path — one size.
static func build(variants: int, seed_value: int) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	for v in variants:
		out.append(ImageTexture.create_from_image(
			_tuft(seed_value + v * 131, BLADES, Vector2(0.5, 1.0), 10.0)))
	return out


## `variants` tufts drawn to one height tier's recipe. Used by TerrainGrass, which sows all
## three tiers over open grassland.
static func build_tier(tier: int, variants: int, seed_value: int) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	for v in variants:
		out.append(ImageTexture.create_from_image(
			_tuft(seed_value + v * 131, TIER_BLADES[tier], TIER_FILL[tier], TIER_LEAN[tier])))
	return out


static func tier_height(tier: int) -> float:
	return TIER_HEIGHT[tier]


## A grass billboard quad sized in WORLD units, with the same house material every scattered
## plant wears (Y-billboard, alpha-scissor cutout, nearest filtering, sun baked into albedo
## so an unlit billboard does not blaze against the ground). FarmBuilder builds the pasture
## tuft's quad from PIXELS_PER_METRE; the tiers are sized by height instead, so this takes a
## metre height rather than a pixel scale — the one real difference between the two paths.
static func billboard_mesh(tex: Texture2D, world_height: float, light: Color) -> QuadMesh:
	var mesh := QuadMesh.new()
	var aspect := float(tex.get_width()) / float(tex.get_height())
	mesh.size = Vector2(world_height * aspect, world_height)
	# Pivot at the base so the clump stands on the ground rather than sinking to its middle.
	mesh.center_offset = Vector3(0.0, mesh.size.y * 0.5, 0.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.albedo_color = light
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	return mesh


static func _tuft(seed_value: int, blades: Vector2i, fill: Vector2, lean_max: float) -> Image:
	var image := Image.create_empty(SIZE, SIZE, true, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var count := rng.randi_range(blades.x, blades.y)
	for blade in count:
		# Blades fan from a common root, so the tuft has a base rather than being a cloud
		# of grass in the air.
		var root := float(SIZE) * 0.5 + rng.randf_range(-3.5, 3.5)
		var lean := rng.randf_range(-lean_max, lean_max)
		var height := rng.randf_range(fill.x, fill.y) * float(SIZE - 2)
		# Tones 1..3 of the ramp, never 0: the darkest is the ground's shadow tone, and a
		# blade wearing it vanishes into the pasture it stands in.
		var tone: Color = TerrainTextures.GRASS_RAMP[rng.randi_range(1, 3)]
		_blade(image, root, lean, height, tone)

	# Mipmaps for the same reason the ground has them: without them a tuft is sub-pixel
	# within a few metres and the pasture crawls as you walk. The cutout does mean alpha
	# averages down with distance and tufts thin out — which is free distance fade, and
	# why the cull below can be as short as it is.
	image.generate_mipmaps()
	return image


## One blade: a quadratic bend from root to tip, tapering 2px to 1px.
static func _blade(image: Image, root: float, lean: float, height: float, tone: Color) -> void:
	var steps := int(height * 2.0)
	for i in steps + 1:
		var t := float(i) / float(maxi(steps, 1))
		# t*t, not t: a blade leaves the ground vertical and bends over as it rises. A
		# linear lean is a straight diagonal, which reads as straw.
		var x := root + lean * t * t
		var y := float(SIZE - 1) - height * t
		# Darker at the root, where a real tuft is in its own shade.
		var shade := tone.darkened(0.4 * (1.0 - t))
		_plot(image, int(x), int(y), shade)
		if t < 0.55:
			_plot(image, int(x) + 1, int(y), shade)


static func _plot(image: Image, x: int, y: int, color: Color) -> void:
	if x < 0 or x >= SIZE or y < 0 or y >= SIZE:
		return
	image.set_pixel(x, y, Color(color.r, color.g, color.b, 1.0))
