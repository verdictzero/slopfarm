extends Node3D
class_name FarmBuilder
## Builds everything the farm plan asks for that is not ground: structures, the fences
## around fenced zones, and the animals that live in them.
##
## Everything sits ON the terrain rather than flattening it. That is a deliberate choice
## with a big payoff: TerrainManager.height_at stays a pure function of position, so the
## plan can be reloaded at runtime without rebuilding a single chunk, re-deriving
## collision, or moving the player. The basin is flat enough to afford it — measured p90
## slope 3.7 degrees, max 11 — and structures carry a foundation skirt that sinks into
## the ground, so the residual centimetre of slop never shows as a gap.

## Structures are merged to ONE mesh each, so a barn is one draw call rather than five.
## They are not merged with EACH OTHER: separate meshes keep their own bounding boxes and
## so keep frustum culling, which matters more than the handful of calls it costs.

## How far a building's base sinks below its origin. Buildings sit on the terrain rather
## than flattening it (see the class comment), so the base has to reach below the ground
## at the footprint's lowest corner or you see daylight under the wall. Measured worst
## relief across a 16x10 footprint anywhere in the basin is 2.21 units, so this clears it.
const FOUNDATION_SINK := 2.5

## How far the gate leaf is swung back from shut. Near-flat against the fence: the gap has
## to stay walkable and drivable (the derived road aims at it), and a leaf at 45 degrees
## juts into exactly the space the track uses.
const GATE_SWING_DEGREES := 78.0

# Palette-friendly, mid-range albedo. Anything near-white loses its shape once the
# 512-colour snap and the Bayer dither get to it.
const PAINT := {
	"wall_red": Color(0.42, 0.16, 0.13),
	"wall_wood": Color(0.36, 0.26, 0.17),
	"roof": Color(0.20, 0.20, 0.23),
	"metal": Color(0.50, 0.51, 0.54),
	"straw": Color(0.62, 0.50, 0.20),
	"stone": Color(0.40, 0.39, 0.37),
	"post": Color(0.30, 0.22, 0.14),
	# The house is the one building that is not a working shed, and limewash is what says
	# so. Still mid-range, not white: see the note above.
	"wall_cream": Color(0.60, 0.56, 0.46),
	# Windows are a hole, not a highlight. A bright pane would bloom into a white blob
	# once the palette snaps it, and at 640x360 a window is four pixels.
	"window": Color(0.14, 0.17, 0.21),
	"brick": Color(0.40, 0.24, 0.19),
	"muck": Color(0.24, 0.19, 0.13),
	"log_end": Color(0.47, 0.37, 0.25),
}

## Standing crop. Each sprite is a CLUMP of stalks, not one stalk, which is what lets the
## density stay affordable while the field still reads as full.
const CROP_BLOCK := 16.0            # world units per culling block
const CROP_PER_SQUARE_METRE := 1.2
## Blocks past this are dropped whole. The ground underneath is already a crop texture
## with furrows, so a distant field still reads as a field — it just stops having stalks.
##
## Note this is a weak lever: culling 46 -> 30 bought 1ms and then hit a floor, because
## the cost is fill from NEAR sprites, which are never culled. Density is the real knob.
const CROP_CULL := 34.0
const CROP_FADE := 6.0

## The authored wheat art. Four variants, mixed through the field.
const CROP_SPRITES := [
	"res://sprites/wheat_plant_1.png",
	"res://sprites/wheat_plant_2.png",
	"res://sprites/wheat_plant_3.png",
	"res://sprites/wheat_plant_4.png",
]
## Pixels per world metre for the sprites. The tallest plant (318px) becomes a 1.5m
## stand of wheat, and the others keep their true proportions against it.
const CROP_PIXELS_PER_METRE := 212.0
## Sunlight baked into the sprites, since a billboard cannot be lit (see below). The lit
## crop ground measures (71,75,37) at its brightest and standing crop wants to sit just
## above that; at 1.0 the art renders around (213,180,28) — a neon field.
const CROP_LIGHT := Color(0.62, 0.62, 0.62)

## Pasture grass. Same machinery as the crop (see _scatter), different numbers, and the
## numbers are the whole story — the README's measurement is that crop DENSITY dominates
## the frame while cull distance hits a floor almost immediately, because the cost is fill
## from near sprites that are never culled.
##
## So grass is bounded by being small rather than by being far away: a tuft is 0.4m against
## the wheat's 1.5m, which is ~14x less fill each, and that is what pays for putting it
## over 40,000 m² of pasture when the whole wheat field is 12,500.
const GRASS_VARIANTS := 4
const GRASS_BLOCK := 16.0
const GRASS_PER_SQUARE_METRE := 5.0
## Shorter than the crop's 34: a 0.4m tuft is sub-pixel at 640x360 well before then, and
## the mipmapped cutout has already thinned it to nothing by ~20m anyway.
const GRASS_CULL := 22.0
## Baked sun, exactly as the crop does and for the same reason — a billboard's normal
## faces the camera, so lighting it makes it blaze against the ground it stands in.
##
## Measured, not picked: lit pasture renders (33,49,25), and grass has to sit just above
## that the way the crop sits just above crop ground. At 0.72 the tufts measured (66,74,41)
## — 1.5-2x the ground, which is the same neon-field failure as the crop's, just quieter:
## it read as pale sprigs scattered ON pasture rather than as the pasture itself.
const GRASS_LIGHT := Color(0.50, 0.50, 0.50)

var _terrain: TerrainManager
var _material: StandardMaterial3D
## One quad per sprite variant, each sized to its own art so the plants keep their
## real proportions instead of all being stretched into the same rectangle.
var _crop_meshes: Array[QuadMesh] = []
## The same, for pasture grass. Generated art rather than loaded — see GrassSprites.
var _grass_meshes: Array[QuadMesh] = []
var _rng := RandomNumberGenerator.new()

# Scratch for mesh building, member-held for the same copy-on-write reason as the terrain.
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 1.0
	_material.metallic = 0.0
	# Carries no texture today — structures are flat-shaded vertex colour — so this filters
	# nothing. Set anyway so that EVERY material in the game reads nearest, with no
	# exceptions to reason about: the animals were smoothed for exactly as long as they
	# were the one material nobody had said this about. tools/probe_filter.gd audits it.
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	# Double-sided. Most of what this file builds is a closed box that never shows a
	# backface, but not all of it: the machine shed's roof is a single _quad, and every
	# _gable is two — one-sided, they vanish when seen from under the eaves or through a
	# doorway. Set on the shared material rather than per-structure because the exceptions
	# are the interesting ones, and a rule with a list of exceptions is a rule you get
	# wrong the next time someone adds a roof.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	for path: String in CROP_SPRITES:
		_crop_meshes.append(_billboard_mesh(load(path), CROP_PIXELS_PER_METRE, CROP_LIGHT))
	for tex: Texture2D in GrassSprites.build(GRASS_VARIANTS, 1301):
		_grass_meshes.append(_billboard_mesh(tex, GrassSprites.PIXELS_PER_METRE, GRASS_LIGHT))


## A billboard quad sized to its own art, with the material every scattered plant wants.
##
## Sized from the texture rather than given a size: the wheat variants are different
## heights and stretching them all into one rectangle throws that away. Grass comes through
## the same path, which is what keeps the two plants one system with two sets of numbers.
func _billboard_mesh(tex: Texture2D, pixels_per_metre: float, light: Color) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(tex.get_width(), tex.get_height()) / pixels_per_metre
	# Pivot at the base: the art has roots at the bottom, so it should stand on the ground
	# rather than be centred in it.
	mesh.center_offset = Vector3(0.0, mesh.size.y * 0.5, 0.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	# Bakes the sunlight in. See CROP_LIGHT/GRASS_LIGHT and the UNSHADED note below.
	mat.albedo_color = light
	# Y-billboard: the plant turns to face the camera but stays standing. A full billboard
	# would lie it over as you look down.
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	# Without this, billboarding discards the per-instance scale and every plant in the
	# field comes out exactly the same height.
	mat.billboard_keep_scale = true
	# Scissor, not blend: blending tens of thousands of quads would need per-instance depth
	# sorting, and it is the expensive path on a tiled GPU. A hard cutout also suits a game
	# that quantises to 512 colours.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	# UNSHADED, with the sun baked into albedo_color instead.
	#
	# A billboard cannot be lit correctly: its normal is whatever direction the camera is,
	# so it catches the sun head-on while the ground it stands in does not. Lit, the crop
	# measured 5.2x the brightness of the ground underneath it — neon yellow in a dark
	# field, with the cull boundary drawn across it in fluorescent marker. The sun does not
	# move here, so baking is free.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	return mesh


## Rebuilds the whole farm from a plan. Safe to call repeatedly — this is what live
## reload does, and it is why nothing here is allowed to touch the height field.
func rebuild(plan: FarmPlan, terrain: TerrainManager) -> Dictionary:
	_terrain = terrain
	for child in get_children():
		# remove_child first: queue_free only *schedules* deletion, so on a live reload
		# the old farm would linger in the tree — drawn over the new one for a frame,
		# and counted alongside it — until the end of the frame.
		remove_child(child)
		child.queue_free()

	var stats := {"structures": 0, "fences": 0, "animals": 0, "crop_blocks": 0,
			"grass_blocks": 0, "draws": 0}
	if not plan.loaded:
		return stats

	# Deterministic: the same plan must lay out the same farm every run, or reloading to
	# check a change would also reshuffle everything you did not change.
	_rng.seed = hash(plan.source_path) + 99
	for s in plan.structures:
		if _add_structure(String(s.get("type", "")), float(s.get("x", 0.0)),
				float(s.get("z", 0.0)), float(s.get("yaw", 0.0))):
			stats.structures += 1

	for z in plan.zones:
		var zone_id := int(z.get("id", 0))
		if bool(z.get("fenced", false)):
			if _add_fence(plan, zone_id):
				stats.fences += 1
		# Ground type alone decides what grows: a "crop" zone grows wheat and a "pasture"
		# zone grows grass, so the designer does not have to also remember to tick
		# something. Painting a zone IS saying what it is.
		var ground := String(z.get("ground", ""))
		if ground == "crop":
			stats.crop_blocks += _scatter(plan, zone_id, _crop_meshes,
					CROP_PER_SQUARE_METRE, CROP_BLOCK, CROP_CULL, false)
		elif ground == "pasture":
			stats.grass_blocks += _scatter(plan, zone_id, _grass_meshes,
					GRASS_PER_SQUARE_METRE, GRASS_BLOCK, GRASS_CULL, true)
		var species := String(z.get("contents", "none"))
		var count := int(z.get("count", 0))
		if species != "none" and count > 0:
			stats.animals += _add_animals(plan, zone_id, species, count)

	stats.draws = get_child_count()
	return stats


# ---- structures -------------------------------------------------------------

func _add_structure(type: String, x: float, z: float, yaw: float) -> bool:
	_begin()
	match type:
		"house": _house()
		"barn": _barn()
		"shed": _shed()
		"silo": _silo()
		"coop": _coop()
		"well": _well()
		"granary": _granary()
		"corn_crib": _corn_crib()
		"grain_bin": _grain_bin()
		"machine_shed": _machine_shed()
		"stable": _stable()
		"pigsty": _pigsty()
		"windmill": _windmill()
		"water_tower": _water_tower()
		"trough": _trough()
		"haystack": _haystack()
		"hay_feeder": _hay_feeder()
		"compost_heap": _compost_heap()
		"fuel_tank": _fuel_tank()
		"log_pile": _log_pile()
		_:
			push_warning("farm plan has unknown structure type '%s'" % type)
			return false
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _commit()
	mesh_instance.material_override = _material
	mesh_instance.position = Vector3(x, _terrain.height_at(x, z), z)
	mesh_instance.rotation.y = deg_to_rad(yaw)
	add_child(mesh_instance)
	_add_collision(mesh_instance)
	return true


## Walls standing `height` above the origin, with the base carried FOUNDATION_SINK below
## it. Centring the box on height/2 (as this used to) tops the walls out ABOVE `height`
## and sinks only half as far as asked, so the gable then sits buried in the wall and the
## foundation is short.
func _walls(width: float, height: float, depth: float, color: Color) -> void:
	_box(Vector3(0, (height - FOUNDATION_SINK) * 0.5, 0),
			Vector3(width, height + FOUNDATION_SINK, depth), color)


func _barn() -> void:
	# 18 x 12 on plan, 12.5 to the ridge — a working barn, not a shed with delusions.
	_walls(18.0, 8.0, 12.0, PAINT.wall_red)
	# A stone foundation course, so the barn stands on something rather than growing out of grass.
	_box(Vector3(0, -0.1, 0), Vector3(18.4, 1.4, 12.4), PAINT.stone.darkened(0.04))
	_gable(Vector3(0, 8.0, 0), 18.0, 12.0, 4.5, PAINT.roof)
	# Eaves trim down both long walls, and a ridge cupola vent with its own little cap — the
	# silhouette detail that tops a real barn.
	for z in [-6.2, 6.2]:
		_box(Vector3(0, 8.0, z), Vector3(18.6, 0.3, 0.4), PAINT.wall_wood.darkened(0.1))
	_box(Vector3(0, 12.9, 0), Vector3(1.8, 1.7, 1.8), PAINT.wall_red)
	_box(Vector3(0, 13.1, 0), Vector3(0.5, 0.6, 0.5), PAINT.window)          # louvre
	_cone(Vector3(0, 13.75, 0), 1.5, 1.1, 4, PAINT.roof)
	# The big sliding door: an X-brace across the leaf and a track rail above it.
	_box(Vector3(0, 2.4, 6.05), Vector3(5.0, 4.8, 0.3), PAINT.wall_wood)
	_rail(Vector3(-2.3, 0.3, 6.22), Vector3(2.3, 4.6, 6.22), 0.12, PAINT.post)
	_rail(Vector3(2.3, 0.3, 6.22), Vector3(-2.3, 4.6, 6.22), 0.12, PAINT.post)
	_box(Vector3(0, 5.0, 6.2), Vector3(6.0, 0.25, 0.18), PAINT.metal)
	# A hayloft door high in the +X gable with a hoist beam jutting out over it.
	_box(Vector3(9.05, 6.6, 0), Vector3(0.2, 2.0, 1.8), PAINT.wall_wood.darkened(0.12))
	_box(Vector3(9.9, 9.4, 0), Vector3(1.8, 0.26, 0.26), PAINT.post)
	# Windows: a pair on each long wall and one high in each gable end.
	for x in [-6.2, 6.2]:
		_box(Vector3(x, 4.2, 6.06), Vector3(1.3, 1.5, 0.14), PAINT.window)
		_box(Vector3(x, 4.2, -6.06), Vector3(1.3, 1.5, 0.14), PAINT.window)
	for z in [-3.4, 3.4]:
		_box(Vector3(-9.06, 4.4, z), Vector3(0.14, 1.4, 1.4), PAINT.window)


func _shed() -> void:
	_walls(6.5, 3.2, 5.0, PAINT.wall_wood)
	# A lean-to: one flat pitch, so it reads as a shed and not a small barn.
	_box(Vector3(0, 3.4, 0), Vector3(7.2, 0.3, 5.8), PAINT.roof)


func _silo() -> void:
	# The landmark. A real farm silo is 15-25m and visible from the far side of the
	# valley; at the old 10.6 it was shorter than the barn's ridge and read as a bin.
	var height := 22.0
	var radius := 4.0
	_cylinder(Vector3(0, (height - FOUNDATION_SINK) * 0.5, 0), radius,
			height + FOUNDATION_SINK, 12, PAINT.metal)
	# Steel hoop bands, the stave seams of a real silo, banded up the drum.
	for i in 7:
		_cylinder(Vector3(0, 2.4 + float(i) * 2.8, 0), radius + 0.09, 0.35, 12,
				PAINT.metal.darkened(0.16))
	# A capped roof: an eaves ring, the cone, and a breather cap on top.
	_cylinder(Vector3(0, height + 0.1, 0), radius + 0.28, 0.5, 12, PAINT.metal.darkened(0.1))
	_cone(Vector3(0, height + 0.3, 0), radius + 0.2, 3.4, 12, PAINT.roof)
	_cylinder(Vector3(0, height + 3.7, 0), 0.42, 0.9, 8, PAINT.metal)
	_cone(Vector3(0, height + 4.6, 0), 0.5, 0.5, 8, PAINT.roof)
	# The unloading chute running the full height of the +Z side, with a ladder up beside it.
	_box(Vector3(0, height * 0.5, radius + 0.32), Vector3(1.0, height, 0.5), PAINT.metal.darkened(0.08))
	for lx in [1.1, 1.7]:
		_box(Vector3(lx, height * 0.5, radius + 0.12), Vector3(0.09, height, 0.09), PAINT.post)
	for i in int(height / 0.7):
		_box(Vector3(1.4, 1.2 + float(i) * 0.7, radius + 0.12), Vector3(0.6, 0.08, 0.09), PAINT.post)


func _coop() -> void:
	_walls(3.5, 2.0, 2.8, PAINT.wall_wood)
	_gable(Vector3(0, 2.0, 0), 3.5, 2.8, 1.1, PAINT.roof)


func _well() -> void:
	var wall := 1.1
	_cylinder(Vector3(0, (wall - FOUNDATION_SINK) * 0.5, 0), 1.2,
			wall + FOUNDATION_SINK, 8, PAINT.stone)
	_box(Vector3(-1.0, 1.7, 0), Vector3(0.2, 2.4, 0.2), PAINT.post)
	_box(Vector3(1.0, 1.7, 0), Vector3(0.2, 2.4, 0.2), PAINT.post)
	_box(Vector3(0, 3.0, 0), Vector3(2.8, 0.2, 1.8), PAINT.roof)


## The farmhouse. 10 x 8 on plan, 8.5 to the ridge — deliberately SMALLER than the barn.
## On a working farm the barn is the big building; a house that out-scales it reads as a
## manor with some sheds, which is a different place entirely.
func _house() -> void:
	_walls(10.0, 5.5, 8.0, PAINT.wall_cream)
	_box(Vector3(0, -0.1, 0), Vector3(10.3, 1.1, 8.3), PAINT.stone.darkened(0.05))  # base course
	_gable(Vector3(0, 5.5, 0), 10.0, 8.0, 3.0, PAINT.roof)
	_box(Vector3(0, 6.9, 0), Vector3(10.9, 0.26, 0.34), PAINT.roof.darkened(0.25))   # ridge cap
	# The front door, framed, under a little porch gable carried on two posts.
	_box(Vector3(0, 1.1, 4.05), Vector3(1.2, 2.2, 0.3), PAINT.wall_wood)
	_box(Vector3(0, 1.2, 4.12), Vector3(1.55, 2.6, 0.1), PAINT.post)
	for px in [-0.95, 0.95]:
		_box(Vector3(px, 1.15, 4.85), Vector3(0.14, 2.3, 0.14), PAINT.post)
	_gable(Vector3(0, 2.5, 4.85), 2.5, 1.7, 0.7, PAINT.roof)
	# Two floors of windows, which is the cheapest thing that says "lived in" rather than
	# "stored in" — every other building here has one storey and no glass. Framed, with shutters.
	for x in [-3.2, 3.2]:
		for y in [1.6, 4.0]:
			_box(Vector3(x, y, 4.05), Vector3(1.1, 1.1, 0.16), PAINT.window)
			_box(Vector3(x, y, 4.11), Vector3(1.35, 1.35, 0.08), PAINT.post)
			for sx in [-0.72, 0.72]:
				_box(Vector3(x + sx, y, 4.08), Vector3(0.28, 1.15, 0.09), PAINT.wall_wood)
		_box(Vector3(x, 2.8, -4.05), Vector3(1.1, 1.1, 0.16), PAINT.window)
	# The chimney does the real work: at 100m the house is a silhouette, and this is the
	# only line in it that is not a shed. Topped with a pot.
	_box(Vector3(-3.8, 7.4, 0), Vector3(0.9, 4.4, 0.9), PAINT.brick)
	_cylinder(Vector3(-3.8, 9.75, 0), 0.3, 0.7, 6, PAINT.brick.darkened(0.16))


# ---- storage and grain ------------------------------------------------------

## Raised on staddle stones, and that is the whole point of the building: a granary keeps
## grain off the ground away from vermin, so it has to visibly STAND OFF it. No foundation
## skirt here for the same reason — daylight under this one is the feature.
func _granary() -> void:
	for x in [-2.2, 2.2]:
		for z in [-1.5, 1.5]:
			_cylinder(Vector3(x, 0.35, z), 0.28, 0.7, 6, PAINT.stone)
			# The mushroom cap: what actually stops the rats, and the silhouette everyone
			# recognises a staddle stone by.
			_cylinder(Vector3(x, 0.78, z), 0.5, 0.16, 6, PAINT.stone)
	_box(Vector3(0, 2.1, 0), Vector3(5.4, 2.4, 3.8), PAINT.wall_wood)
	_gable(Vector3(0, 3.3, 0), 5.4, 3.8, 1.4, PAINT.roof)
	_box(Vector3(0, 1.7, 1.95), Vector3(1.0, 1.6, 0.2), PAINT.wall_red)
	# Steps, because a raised door needs them and their absence is the first thing that
	# reads as wrong once the building is off the ground.
	for i in 3:
		_box(Vector3(0, 0.2 + float(i) * 0.22, 2.5 - float(i) * 0.3),
				Vector3(1.2, 0.16, 0.36), PAINT.stone)


## Long, narrow and slatted. A crib dries maize on the cob, so it is built one arm's reach
## wide and full of gaps — the slats ARE the structure, not a texture on a box. Long in X
## like the barn, because _gable runs its ridge along X and yaw handles the rest.
func _corn_crib() -> void:
	for x in [-2.7, 0.0, 2.7]:
		for z in [-1.1, 1.1]:
			_box(Vector3(x, 0.1, z), Vector3(0.2, 1.2, 0.2), PAINT.post)
	_box(Vector3(0, 0.75, 0), Vector3(6.2, 0.24, 2.6), PAINT.wall_wood)
	# Horizontal boards with a gap between each. Seven courses at 0.32 leaves the gaps
	# wide enough to survive the 640x360 viewport — closer spacing aliases into a solid wall.
	for i in 7:
		var y := 1.0 + float(i) * 0.32
		for z in [-1.25, 1.25]:
			_box(Vector3(0, y, z), Vector3(6.2, 0.18, 0.1), PAINT.wall_wood)
	for x in [-3.05, 3.05]:
		_box(Vector3(x, 1.95, 0), Vector3(0.12, 2.3, 2.6), PAINT.wall_wood)
	_gable(Vector3(0, 3.1, 0), 6.2, 2.6, 1.0, PAINT.roof)


## The modern bin standing next to the old silo: squat, wide and metal, where the silo is
## tall and narrow. Half the silo's height on purpose — two landmarks of the same size
## would just read as a pair.
func _grain_bin() -> void:
	var height := 6.5
	var radius := 3.2
	_cylinder(Vector3(0, (height - FOUNDATION_SINK) * 0.5, 0), radius,
			height + FOUNDATION_SINK, 12, PAINT.metal)
	_cone(Vector3(0, height, 0), radius + 0.15, 1.7, 12, PAINT.metal.darkened(0.12))
	# The ladder up the side: the one thing that gives a smooth metal drum a sense of scale.
	_box(Vector3(0, height * 0.5, radius + 0.06), Vector3(0.44, height, 0.06), PAINT.post)


# ---- machinery and livestock ------------------------------------------------

## Three walls and a roof: the fourth side is how the tractor gets in, and that opening is
## the entire difference between this and a barn. The roof falls to the open front so the
## rain runs off away from the machinery rather than into it.
func _machine_shed() -> void:
	var width := 12.0
	var height := 4.6
	var depth := 7.0
	_box(Vector3(0, (height - FOUNDATION_SINK) * 0.5, -depth * 0.5),
			Vector3(width, height + FOUNDATION_SINK, 0.3), PAINT.wall_wood)
	for x in [-width * 0.5, width * 0.5]:
		_box(Vector3(x, (height - FOUNDATION_SINK) * 0.5, 0),
				Vector3(0.3, height + FOUNDATION_SINK, depth), PAINT.wall_wood)
	# Piers, not walls, down the open front — otherwise the roof floats.
	for x in [-width * 0.5 + 0.15, 0.0, width * 0.5 - 0.15]:
		_box(Vector3(x, (height - 0.6 - FOUNDATION_SINK) * 0.5, depth * 0.5 - 0.15),
				Vector3(0.3, height - 0.6 + FOUNDATION_SINK, 0.3), PAINT.post)
	_quad(Vector3(-width * 0.5 - 0.3, height + 0.3, -depth * 0.5 - 0.3),
			Vector3(width * 0.5 + 0.3, height + 0.3, -depth * 0.5 - 0.3),
			Vector3(width * 0.5 + 0.3, height - 0.5, depth * 0.5 + 0.3),
			Vector3(-width * 0.5 - 0.3, height - 0.5, depth * 0.5 + 0.3), PAINT.roof)


func _stable() -> void:
	_walls(9.0, 3.6, 5.5, PAINT.wall_wood)
	_gable(Vector3(0, 3.6, 0), 9.0, 5.5, 1.8, PAINT.roof)
	# Split doors with the top leaf open — the detail that says stable rather than shed.
	# The opening is drawn as a dark recess rather than a swung leaf: at this size a leaf
	# is two pixels of edge, and the hole is what actually reads.
	for x in [-2.6, 0.0, 2.6]:
		_box(Vector3(x, 0.55, 2.8), Vector3(1.3, 1.9, 0.25), PAINT.wall_red)
		_box(Vector3(x, 2.05, 2.72), Vector3(1.3, 1.1, 0.1), PAINT.window)


## Mostly a walled yard with a shelter in one corner, and the walls are pig-height. That
## is what makes it a sty: waist-high walls you can see over are not a small barn.
func _pigsty() -> void:
	var width := 7.0
	var depth := 5.0
	for z in [-depth * 0.5, depth * 0.5]:
		_box(Vector3(0, 0.1, z), Vector3(width, 2.4, 0.35), PAINT.brick)
	for x in [-width * 0.5, width * 0.5]:
		_box(Vector3(x, 0.1, 0), Vector3(0.35, 2.4, depth), PAINT.brick)
	_box(Vector3(-1.9, 0.5, 0), Vector3(3.0, 3.2, depth - 0.7), PAINT.brick)
	_box(Vector3(-1.9, 2.2, 0), Vector3(3.4, 0.2, depth - 0.3), PAINT.roof)


# ---- water and wind ---------------------------------------------------------

## A landmark, sized like the silo and for the same reason: it has to read from the far
## side of the basin or it is just a shed with a hat.
func _windmill() -> void:
	# 3:1 tall to wide. At the 2.5:1 this started as, the tower read as the silo with
	# sails glued on — the two are the same height, the same grey and 100m apart, so the
	# proportion is the only thing telling them apart at distance.
	var tower := 12.0
	_cylinder(Vector3(0, (tower - FOUNDATION_SINK) * 0.5, 0), 2.0,
			tower + FOUNDATION_SINK, 10, PAINT.stone)
	_cone(Vector3(0, tower, 0), 2.2, 2.0, 10, PAINT.roof)

	# Sails. Each is a common sail: a whip (the spine), one leading-edge rail, and rungs
	# between them — a one-sided ladder, which is what a real sail's frame is and what
	# carries the canvas.
	#
	# Built as a ladder rather than a spine with cross-slats because the first version was
	# the latter and read, at 640x360, as four small crosses floating beside the tower: a
	# 0.07 slat is sub-pixel past ten metres, so nothing joined the tips into a shape. The
	# leading edge is what makes the sail a surface instead of a scatter.
	#
	# The 45-degree offset is load-bearing, not aesthetic: _rail takes its cross-section
	# from dir.cross(UP), which collapses to zero for a vertical arm, so sails at
	# 0/90/180/270 would build two of the four as degenerate geometry.
	var hub := Vector3(0, tower - 1.0, 2.5)
	for i in 4:
		var angle := TAU * float(i) / 4.0 + PI * 0.25
		var out := Vector3(cos(angle), sin(angle), 0.0)
		var across := Vector3(-out.y, out.x, 0.0) * 0.95
		var tip := hub + out * 6.4
		_rail(hub, tip, 0.16, PAINT.wall_wood)
		_rail(hub + out * 1.3 + across, tip + across, 0.11, PAINT.wall_wood)
		for j in 7:
			var along := hub + out * (1.3 + float(j) * 0.84)
			_rail(along, along + across, 0.09, PAINT.wall_wood)
	_cylinder(hub + Vector3(0, 0, -0.4), 0.45, 0.9, 8, PAINT.post)

	# A gallery at half height. Without it the tower is a smooth grey drum — which is
	# exactly what the silo already is, 100m away and the same colour.
	for i in 12:
		var a0 := TAU * float(i) / 12.0
		var a1 := TAU * float(i + 1) / 12.0
		var r := 2.3
		_rail(Vector3(cos(a0) * r, 5.4, sin(a0) * r),
				Vector3(cos(a1) * r, 5.4, sin(a1) * r), 0.09, PAINT.post)
		_box(Vector3(cos(a0) * r, 5.0, sin(a0) * r), Vector3(0.1, 0.8, 0.1), PAINT.post)


## A tank on a trestle. The legs are most of the silhouette, so they are braced rather than
## left as four bare posts — an unbraced trestle reads as scaffolding.
func _water_tower() -> void:
	var legs := 9.0
	var spread := 2.5
	var corners := [
		Vector2(-spread, -spread), Vector2(spread, -spread),
		Vector2(spread, spread), Vector2(-spread, spread),
	]
	for c: Vector2 in corners:
		_box(Vector3(c.x, (legs - FOUNDATION_SINK) * 0.5, c.y),
				Vector3(0.34, legs + FOUNDATION_SINK, 0.34), PAINT.post)
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		_rail(Vector3(a.x, 1.4, a.y), Vector3(b.x, 5.4, b.y), 0.08, PAINT.post)
		_rail(Vector3(a.x, 5.4, a.y), Vector3(b.x, 1.4, b.y), 0.08, PAINT.post)
		_rail(Vector3(a.x, 8.6, a.y), Vector3(b.x, 8.6, b.y), 0.1, PAINT.post)
	_cylinder(Vector3(0, legs + 1.7, 0), 2.9, 3.4, 10, PAINT.metal)
	_cone(Vector3(0, legs + 3.4, 0), 3.0, 1.2, 10, PAINT.roof)


# ---- yard clutter -----------------------------------------------------------

func _trough() -> void:
	_box(Vector3(0, 0.35, 0), Vector3(4.0, 0.7, 1.0), PAINT.wall_wood)
	_box(Vector3(0, 0.62, 0), Vector3(3.4, 0.2, 0.6), Color(0.16, 0.20, 0.22))  # water


func _haystack() -> void:
	_cylinder(Vector3(0, 1.1, 0), 1.9, 2.2, 8, PAINT.straw)
	_cone(Vector3(0, 2.2, 0), 2.0, 1.1, 8, PAINT.straw)


## A ring feeder, and the ring is the point: stock eat through it instead of treading the
## hay into the mud. Also a trample source — see FarmPlan.TRAMPLE_STRUCTURES, which is why
## the ground around one of these goes to mud.
func _hay_feeder() -> void:
	var radius := 1.5
	for i in 10:
		var angle := TAU * float(i) / 10.0
		_box(Vector3(cos(angle) * radius, 0.55, sin(angle) * radius),
				Vector3(0.09, 1.1, 0.09), PAINT.metal)
	for y in [0.15, 1.05]:
		for i in 10:
			var a0 := TAU * float(i) / 10.0
			var a1 := TAU * float(i + 1) / 10.0
			_rail(Vector3(cos(a0) * radius, y, sin(a0) * radius),
					Vector3(cos(a1) * radius, y, sin(a1) * radius), 0.06, PAINT.metal)
	_cylinder(Vector3(0, 0.5, 0), radius * 0.78, 1.0, 8, PAINT.straw)


## A muck heap in a three-sided timber bay. The open side faces +X so a loader can get at
## it, which is also why the heap is mounded off-centre toward that side.
func _compost_heap() -> void:
	for z in [-1.8, 1.8]:
		_box(Vector3(0, 0.25, z), Vector3(4.0, 1.8, 0.2), PAINT.wall_wood)
	_box(Vector3(-2.0, 0.25, 0), Vector3(0.2, 1.8, 3.8), PAINT.wall_wood)
	_box(Vector3(0.1, 0.55, 0), Vector3(3.4, 1.4, 3.2), PAINT.muck)
	_box(Vector3(0.3, 1.15, 0), Vector3(2.4, 0.5, 2.2), PAINT.muck.darkened(0.12))


## Bulk diesel in a bund. Vertical rather than the usual horizontal drum: every helper in
## this file builds along Y, and a lying cylinder would need an arbitrary rotation that
## nothing else here wants. The bund is not decoration — a fuel tank without one is the
## detail a farmer would notice missing.
func _fuel_tank() -> void:
	_box(Vector3(0, 0.2, 0), Vector3(3.0, 0.6, 2.4), PAINT.stone)
	_cylinder(Vector3(0, 1.7, 0), 0.9, 2.4, 10, PAINT.metal.darkened(0.28))
	_cylinder(Vector3(0, 2.95, 0), 0.92, 0.12, 10, PAINT.metal)
	_box(Vector3(1.1, 1.0, 0), Vector3(0.14, 0.6, 0.14), PAINT.post)


## Cordwood stacked between two stakes, tapering as it rises the way a real stack does.
## The logs are square beams, not cylinders: flat-shaded at this size an 8-sided cylinder
## IS flats, and a beam is two triangles a face instead of sixteen for the same read.
func _log_pile() -> void:
	for row in 4:
		var y := 0.22 + float(row) * 0.38
		var count := 5 - row
		for i in count:
			var z := (float(i) - float(count - 1) * 0.5) * 0.42
			_rail(Vector3(-1.6, y, z), Vector3(1.6, y, z), 0.18, PAINT.log_end)
	for x in [-1.75, 1.75]:
		_box(Vector3(x, 0.7, 0), Vector3(0.12, 2.4, 0.12), PAINT.post)


# ---- fences -----------------------------------------------------------------

## One merged mesh per fenced zone: a pen's fence is ~100 short segments, and that has to
## be one draw call, not a hundred. The gate is part of that same mesh — it is a hole in
## this fence and a thing hung in the hole, so splitting it out would buy a draw call and
## cost the guarantee that the two always agree about where the hole is.
func _add_fence(plan: FarmPlan, zone_id: int) -> bool:
	var edges := plan.zone_border_edges(zone_id)
	if edges.is_empty():
		return false
	var gate := {}
	for g in plan.gates:
		if int(g.get("zone", -1)) == zone_id:
			gate = g
	var gate_edges: Array = gate.get("edges", [])

	_begin()
	for edge in edges:
		# The gate's own edges get no fence: that gap IS the gate.
		if edge in gate_edges:
			continue
		var a: Vector2 = edge[0]
		var b: Vector2 = edge[1]
		_fence_run(a, b)
	if not gate.is_empty():
		_gate(gate["from"], gate["to"])
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _commit()
	mesh_instance.material_override = _material
	add_child(mesh_instance)
	_add_collision(mesh_instance)
	return true


## Solid geometry from the mesh that was just built. Without this a barn is a hologram —
## you walk through your own farm, and a pen does not pen anything in.
##
## Trimesh off the merged mesh rather than hand-authored primitives: the mesh is already
## the exact shape, it is static, and there are only ~10 of these. The whole farm is a
## handful of static bodies parked near the origin, so the broadphase never notices.
func _add_collision(mesh_instance: MeshInstance3D) -> void:
	var shape := mesh_instance.mesh.create_trimesh_shape()
	if shape == null:
		return
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	# Parented to the already-placed mesh, so it inherits position and yaw.
	mesh_instance.add_child(body)


func _fence_run(a: Vector2, b: Vector2) -> void:
	# Built in world space (the parent is at the origin), so each post can sit at its own
	# ground height and the fence follows the ground instead of floating over a dip.
	var post_a := Vector3(a.x, _terrain.height_at(a.x, a.y), a.y)
	var post_b := Vector3(b.x, _terrain.height_at(b.x, b.y), b.y)
	_box_world(post_a + Vector3(0, 0.6, 0), Vector3(0.16, 1.6, 0.16), PAINT.post)
	for height in [0.55, 1.05]:
		var from := post_a + Vector3(0, height, 0)
		var to := post_b + Vector3(0, height, 0)
		_rail(from, to, 0.07, PAINT.wall_wood)


## A field gate standing open in the gap the fence left for it.
##
## Standing OPEN, not shut, for two reasons that agree: a shut gate is a fence with extra
## steps — nothing about it reads as a gate from ten metres — and the derived road drives
## straight through this opening, so a leaf across it would be a wall with a track painted
## up to it. Swung nearly flat against the fence line leaves the gap clear and still says
## gate, because the leaf is visibly hinged and visibly not the fence.
func _gate(from: Vector2, to: Vector2) -> void:
	var hinge := Vector3(from.x, _terrain.height_at(from.x, from.y), from.y)
	var latch := Vector3(to.x, _terrain.height_at(to.x, to.y), to.y)
	# Hanging posts: taller and thicker than the fence's, which is what a real one is —
	# the fence carries only its own rails, this carries a swinging leaf.
	for post in [hinge, latch]:
		_box_world(post + Vector3(0, 0.75, 0), Vector3(0.24, 2.0, 0.24), PAINT.post)

	var span := latch - hinge
	var width := Vector2(span.x, span.z).length()
	if width < 0.01:
		return
	var shut := Vector3(span.x, 0.0, span.z).normalized()
	var open_dir := shut.rotated(Vector3.UP, deg_to_rad(GATE_SWING_DEGREES))
	var tip := hinge + open_dir * width

	# Three bars and a diagonal, which is what a gate IS: the brace is not decoration, it
	# is the only reason a real one does not sag into a parallelogram.
	for height in [0.35, 0.8, 1.25]:
		_rail(hinge + Vector3(0, height, 0), tip + Vector3(0, height, 0), 0.05, PAINT.wall_wood)
	_rail(hinge + Vector3(0, 0.35, 0), tip + Vector3(0, 1.25, 0), 0.05, PAINT.wall_wood)
	# The far stile, so the leaf ends in a frame rather than three bars stopping in mid-air.
	_box_world(tip + Vector3(0, 0.8, 0), Vector3(0.1, 1.0, 0.1), PAINT.wall_wood)


# ---- animals ----------------------------------------------------------------

func _add_animals(plan: FarmPlan, zone_id: int, species: String, count: int) -> int:
	var scene_path := "res://models/%s.glb" % species
	if not ResourceLoader.exists(scene_path):
		push_warning("farm plan wants '%s' but %s does not exist" % [species, scene_path])
		return 0
	var packed: PackedScene = load(scene_path)
	var cells := plan.zone_cells(zone_id)
	if cells.is_empty():
		return 0

	var placed := 0
	for i in count:
		# Pick a cell at random rather than a random point in the bounding box: a zone
		# can be any shape, and an L-shaped pen must not put an animal in the notch.
		var at := cells[_rng.randi_range(0, cells.size() - 1)]
		at += Vector2(_rng.randf_range(-0.8, 0.8), _rng.randf_range(-0.8, 0.8))
		var node := packed.instantiate() as Node3D
		_force_pixel_look(node)
		node.position = Vector3(at.x, _terrain.height_at(at.x, at.y), at.y)
		node.rotation.y = _rng.randf_range(0.0, TAU)
		# The imported .glb root is a plain Node3D, so the behaviour script goes on it
		# directly — no wrapper node, no extra transform to keep in sync.
		node.set_script(load("res://scripts/farm_animal.gd"))
		add_child(node)
		(node as FarmAnimal).setup(StringName(species), cells, _terrain, _rng.randi(), _terrain.player)
		placed += 1
	return placed


## Drags an imported model's materials into this game's house style: nearest filtering and
## double-sided, the same as everything FarmBuilder makes itself.
##
## Both are PINNED here rather than left to the asset, and the filter is why. The animals
## were the one thing on the farm being smoothed — every sampler this project writes by
## hand asks for nearest, but a .glb's materials are built by the importer with engine
## defaults, which means LINEAR_MIPMAP. It hid because filtering on a 3D material is a
## MATERIAL property, not an import setting, so it never appears in a .import file to be
## audited. That is the trap the README's note about lut_512.png's import defeats, one
## level further in.
##
## Culling is pinned for the same reason even though it changes nothing today: horse.glb
## happens to arrive CULL_DISABLED because its glTF sets `doubleSided`, which is the
## asset's opinion, not ours — exactly the kind of incidental default that was linear
## last week. tools/probe_filter.gd audits it.
##
## Materials come off the .glb as SHARED resources, so this reaches every animal of the
## species — the same reason the walk's LOOP_LINEAR fix only has to be applied once (see
## FarmAnimal.setup). It is re-applied per animal anyway because it is idempotent and a
## cheap property set, and "runs once, on the first one" is the kind of cleverness that
## breaks the day someone reorders the loop.
func _force_pixel_look(node: Node) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		for surface in mesh_instance.mesh.get_surface_count():
			# Both slots: the importer puts materials on the mesh's surfaces, but an
			# override on the instance would silently win over anything set here.
			for mat in [mesh_instance.mesh.surface_get_material(surface),
					mesh_instance.get_surface_override_material(surface)]:
				var base := mat as BaseMaterial3D
				if base != null:
					base.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
					base.cull_mode = BaseMaterial3D.CULL_DISABLED
	for child in node.get_children():
		_force_pixel_look(child)


# ---- scattered billboards: standing crop and pasture grass -------------------

## Scatters billboards over a zone, as one MultiMesh per variant per BLOCK-sized tile.
##
## Blocks rather than one giant MultiMesh: Godot culls per GeometryInstance3D, so a single
## field-wide MultiMesh is all-or-nothing and would draw every stalk in the field whenever
## any part of it is on screen. Per block, visibility_range_end drops distant tiles
## wholesale, which is the only reason the density is affordable.
##
## Shared by the crop and the grass because the machinery is identical and only the numbers
## differ. `thin_by_trample` is the one real difference: grass does not grow where the herd
## has churned the ground to mud, and wheat is never trampled because nothing walks in it.
func _scatter(plan: FarmPlan, zone_id: int, meshes: Array[QuadMesh], per_square_metre: float,
		block_size: float, cull: float, thin_by_trample: bool) -> int:
	var cells := plan.zone_cells(zone_id)
	if cells.is_empty():
		return 0

	# Dictionary of Array (not PackedVector2Array): packed arrays are copy-on-write, so
	# appending through a dictionary lookup would scribble on a temporary.
	var blocks := {}
	for c in cells:
		var key := Vector2i(floori(c.x / block_size), floori(c.y / block_size))
		if not blocks.has(key):
			blocks[key] = []
		blocks[key].append(c)

	var cell_area: float = FarmPlan.CELL_SIZE * FarmPlan.CELL_SIZE
	var made := 0
	for key: Vector2i in blocks:
		var block: Array = blocks[key]
		var count := int(block.size() * cell_area * per_square_metre)
		if count <= 0:
			continue
		# One MultiMesh per variant per block. A MultiMesh carries a single mesh, so mixing
		# the sprites means one each; they share the block's culling, so a distant block
		# still drops them all at once.
		for variant in meshes.size():
			made += _billboard_block(plan, block, meshes[variant],
					count / meshes.size(), cull, thin_by_trample)
	return made


func _billboard_block(plan: FarmPlan, block: Array, mesh: QuadMesh, count: int, cull: float,
		thin_by_trample: bool) -> int:
	if count <= 0:
		return 0
	# Gathered before the MultiMesh is made, because instance_count has to be the number
	# that SURVIVED thinning: sizing it to `count` up front and skipping instances leaves
	# the rest at the identity transform, i.e. a pile of grass stacked at the world origin.
	var placed: Array[Transform3D] = []
	for i in count:
		var at: Vector2 = block[_rng.randi_range(0, block.size() - 1)]
		at += Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		# Thinned against trampling as a coin flip per tuft, not a hard cutoff: a threshold
		# draws a visible contour around every gate where the grass stops dead. The
		# probability IS the trample value, so grass thins out exactly as the mud fades in
		# and the two transitions are one transition.
		if thin_by_trample and _rng.randf() < plan.trample_at(at.x, at.y):
			continue
		var xf := Transform3D()
		xf = xf.scaled(Vector3.ONE * _rng.randf_range(0.75, 1.3))
		# Sunk slightly, so the roots meet the soil instead of hovering on it.
		xf.origin = Vector3(at.x, _terrain.height_at(at.x, at.y) - 0.06, at.y)
		placed.append(xf)
	if placed.is_empty():
		return 0

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = placed.size()
	for i in placed.size():
		mm.set_instance_transform(i, placed[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.visibility_range_end = cull
	mmi.visibility_range_end_margin = CROP_FADE
	# No fade: dithered fade costs a transparency pass, and at this distance the stalks are
	# a couple of pixels tall — popping is invisible under the dither.
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return 1


# ---- mesh scratch -----------------------------------------------------------

func _begin() -> void:
	_verts.clear()
	_normals.clear()
	_colors.clear()


func _commit() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _tri(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for v in [a, b, c]:
		_verts.append(v)
		_normals.append(normal)
		_colors.append(color)


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	_tri(a, b, c, color)
	_tri(a, c, d, color)


## Axis-aligned box centred on `at`. `size` is full extents. Flat-shaded to match the
## terrain: one normal per face, no shared vertices.
func _box(at: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	var p := [
		at + Vector3(-h.x, -h.y, -h.z), at + Vector3(h.x, -h.y, -h.z),
		at + Vector3(h.x, -h.y, h.z), at + Vector3(-h.x, -h.y, h.z),
		at + Vector3(-h.x, h.y, -h.z), at + Vector3(h.x, h.y, -h.z),
		at + Vector3(h.x, h.y, h.z), at + Vector3(-h.x, h.y, h.z),
	]
	_quad(p[4], p[5], p[6], p[7], color)                       # top
	_quad(p[1], p[0], p[3], p[2], color.darkened(0.35))        # bottom
	_quad(p[0], p[1], p[5], p[4], color.darkened(0.12))        # -Z
	_quad(p[2], p[3], p[7], p[6], color.darkened(0.12))        # +Z
	_quad(p[3], p[0], p[4], p[7], color.darkened(0.22))        # -X
	_quad(p[1], p[2], p[6], p[5], color.darkened(0.22))        # +X


func _box_world(at: Vector3, size: Vector3, color: Color) -> void:
	_box(at, size, color)


## Two roof planes meeting at a ridge.
func _gable(base: Vector3, width: float, depth: float, height: float, color: Color) -> void:
	var hw := width * 0.5 + 0.4
	var hd := depth * 0.5 + 0.4
	var ridge_a := base + Vector3(-hw, height, 0)
	var ridge_b := base + Vector3(hw, height, 0)
	_quad(base + Vector3(-hw, 0, -hd), base + Vector3(hw, 0, -hd), ridge_b, ridge_a, color)
	_quad(ridge_a, ridge_b, base + Vector3(hw, 0, hd), base + Vector3(-hw, 0, hd), color)
	_tri(base + Vector3(-hw, 0, -hd), ridge_a, base + Vector3(-hw, 0, hd), color.darkened(0.2))
	_tri(base + Vector3(hw, 0, -hd), base + Vector3(hw, 0, hd), ridge_b, color.darkened(0.2))


func _cylinder(at: Vector3, radius: float, height: float, sides: int, color: Color) -> void:
	var half := height * 0.5
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * radius, 0, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		var shade := color.darkened(0.18 * (0.5 + 0.5 * sin(a0)))
		_quad(at + p0 + Vector3(0, -half, 0), at + p1 + Vector3(0, -half, 0),
				at + p1 + Vector3(0, half, 0), at + p0 + Vector3(0, half, 0), shade)
		_tri(at + Vector3(0, half, 0), at + p0 + Vector3(0, half, 0),
				at + p1 + Vector3(0, half, 0), color)


func _cone(base: Vector3, radius: float, height: float, sides: int, color: Color) -> void:
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		_tri(base + Vector3(0, height, 0),
				base + Vector3(cos(a0) * radius, 0, sin(a0) * radius),
				base + Vector3(cos(a1) * radius, 0, sin(a1) * radius),
				color.darkened(0.14 * (0.5 + 0.5 * sin(a0))))


## A square-section beam between two points — a fence rail.
func _rail(from: Vector3, to: Vector3, thickness: float, color: Color) -> void:
	var along := to - from
	if along.length() < 0.001:
		return
	var dir := along.normalized()
	var side := dir.cross(Vector3.UP).normalized() * thickness
	var up := Vector3(0, thickness, 0)
	var p := [from - side - up, from + side - up, from + side + up, from - side + up,
			to - side - up, to + side - up, to + side + up, to - side + up]
	_quad(p[3], p[2], p[6], p[7], color)                  # top
	_quad(p[1], p[0], p[4], p[5], color.darkened(0.3))    # bottom
	_quad(p[0], p[3], p[7], p[4], color.darkened(0.15))
	_quad(p[2], p[1], p[5], p[6], color.darkened(0.15))
