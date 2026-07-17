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


## `variants` tufts, each a different arrangement of the same idea.
static func build(variants: int, seed_value: int) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	for v in variants:
		out.append(ImageTexture.create_from_image(_tuft(seed_value + v * 131)))
	return out


static func _tuft(seed_value: int) -> Image:
	var image := Image.create_empty(SIZE, SIZE, true, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var count := rng.randi_range(BLADES.x, BLADES.y)
	for blade in count:
		# Blades fan from a common root, so the tuft has a base rather than being a cloud
		# of grass in the air.
		var root := float(SIZE) * 0.5 + rng.randf_range(-3.5, 3.5)
		var lean := rng.randf_range(-10.0, 10.0)
		var height := rng.randf_range(0.5, 1.0) * float(SIZE - 2)
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
