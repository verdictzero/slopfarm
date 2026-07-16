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

var _terrain: TerrainManager
var _material: StandardMaterial3D
## One quad per sprite variant, each sized to its own art so the plants keep their
## real proportions instead of all being stretched into the same rectangle.
var _crop_meshes: Array[QuadMesh] = []
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

	for path: String in CROP_SPRITES:
		var tex: Texture2D = load(path)
		var mesh := QuadMesh.new()
		mesh.size = Vector2(tex.get_width(), tex.get_height()) / CROP_PIXELS_PER_METRE
		# Pivot at the base: the art has roots at the bottom, so it should stand on the
		# ground rather than be centred in it.
		mesh.center_offset = Vector3(0.0, mesh.size.y * 0.5, 0.0)

		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		# Bakes the sunlight in. See CROP_LIGHT and the UNSHADED note below.
		mat.albedo_color = CROP_LIGHT
		# Y-billboard: the plant turns to face the camera but stays standing. A full
		# billboard would lie it over as you look down.
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		# Without this, billboarding discards the per-instance scale and every plant in
		# the field comes out exactly the same height.
		mat.billboard_keep_scale = true
		# Scissor, not blend: blending tens of thousands of quads would need per-instance
		# depth sorting, and it is the expensive path on a tiled GPU. A hard cutout also
		# suits a game that quantises to 512 colours.
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.roughness = 1.0
		# UNSHADED, with the sun baked into albedo_color instead.
		#
		# A billboard cannot be lit correctly: its normal is whatever direction the
		# camera is, so it catches the sun head-on while the ground it stands in does
		# not. Lit, the crop measured 5.2x the brightness of the ground underneath it —
		# neon yellow in a dark field, with the cull boundary drawn across it in
		# fluorescent marker. The sun does not move here, so baking is free.
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material = mat
		_crop_meshes.append(mesh)


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

	var stats := {"structures": 0, "fences": 0, "animals": 0, "crop_blocks": 0, "draws": 0}
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
		# A "crop" zone grows standing crop, from the ground type alone — the designer
		# does not have to also remember to tick something.
		if String(z.get("ground", "")) == "crop":
			stats.crop_blocks += _add_crop(plan, zone_id)
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
		"barn": _barn()
		"shed": _shed()
		"silo": _silo()
		"coop": _coop()
		"trough": _trough()
		"haystack": _haystack()
		"well": _well()
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
	_gable(Vector3(0, 8.0, 0), 18.0, 12.0, 4.5, PAINT.roof)
	_box(Vector3(0, 2.4, 6.05), Vector3(5.0, 4.8, 0.3), PAINT.wall_wood)  # door


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
	_cone(Vector3(0, height, 0), radius + 0.2, 3.4, 12, PAINT.roof)


func _coop() -> void:
	_walls(3.5, 2.0, 2.8, PAINT.wall_wood)
	_gable(Vector3(0, 2.0, 0), 3.5, 2.8, 1.1, PAINT.roof)


func _trough() -> void:
	_box(Vector3(0, 0.35, 0), Vector3(4.0, 0.7, 1.0), PAINT.wall_wood)
	_box(Vector3(0, 0.62, 0), Vector3(3.4, 0.2, 0.6), Color(0.16, 0.20, 0.22))  # water


func _haystack() -> void:
	_cylinder(Vector3(0, 1.1, 0), 1.9, 2.2, 8, PAINT.straw)
	_cone(Vector3(0, 2.2, 0), 2.0, 1.1, 8, PAINT.straw)


func _well() -> void:
	var wall := 1.1
	_cylinder(Vector3(0, (wall - FOUNDATION_SINK) * 0.5, 0), 1.2,
			wall + FOUNDATION_SINK, 8, PAINT.stone)
	_box(Vector3(-1.0, 1.7, 0), Vector3(0.2, 2.4, 0.2), PAINT.post)
	_box(Vector3(1.0, 1.7, 0), Vector3(0.2, 2.4, 0.2), PAINT.post)
	_box(Vector3(0, 3.0, 0), Vector3(2.8, 0.2, 1.8), PAINT.roof)


# ---- fences -----------------------------------------------------------------

## One merged mesh per fenced zone: a pen's fence is ~100 short segments, and that has to
## be one draw call, not a hundred.
func _add_fence(plan: FarmPlan, zone_id: int) -> bool:
	var edges := plan.zone_border_edges(zone_id)
	if edges.is_empty():
		return false
	_begin()
	for edge in edges:
		var a: Vector2 = edge[0]
		var b: Vector2 = edge[1]
		_fence_run(a, b)
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
		# can be any shape, and an L-shaped pen must not put a cow in the notch.
		var at := cells[_rng.randi_range(0, cells.size() - 1)]
		at += Vector2(_rng.randf_range(-0.8, 0.8), _rng.randf_range(-0.8, 0.8))
		var node := packed.instantiate() as Node3D
		node.position = Vector3(at.x, _terrain.height_at(at.x, at.y), at.y)
		node.rotation.y = _rng.randf_range(0.0, TAU)
		# The imported .glb root is a plain Node3D, so the behaviour script goes on it
		# directly — no wrapper node, no extra transform to keep in sync.
		node.set_script(load("res://scripts/farm_animal.gd"))
		add_child(node)
		(node as FarmAnimal).setup(StringName(species), cells, _terrain, _rng.randi(), _terrain.player)
		placed += 1
	return placed


# ---- standing crop ----------------------------------------------------------

## Scatters standing crop over a zone, as one MultiMesh per CROP_BLOCK-sized tile.
##
## Blocks rather than one giant MultiMesh: Godot culls per GeometryInstance3D, so a
## single field-wide MultiMesh is all-or-nothing and would draw every stalk in the field
## whenever any part of it is on screen. Per block, visibility_range_end drops distant
## tiles wholesale, which is the only reason the density is affordable.
func _add_crop(plan: FarmPlan, zone_id: int) -> int:
	var cells := plan.zone_cells(zone_id)
	if cells.is_empty():
		return 0

	# Dictionary of Array (not PackedVector2Array): packed arrays are copy-on-write, so
	# appending through a dictionary lookup would scribble on a temporary.
	var blocks := {}
	for c in cells:
		var key := Vector2i(floori(c.x / CROP_BLOCK), floori(c.y / CROP_BLOCK))
		if not blocks.has(key):
			blocks[key] = []
		blocks[key].append(c)

	var cell_area: float = FarmPlan.CELL_SIZE * FarmPlan.CELL_SIZE
	var made := 0
	for key: Vector2i in blocks:
		var block: Array = blocks[key]
		var count := int(block.size() * cell_area * CROP_PER_SQUARE_METRE)
		if count <= 0:
			continue
		# One MultiMesh per variant per block. A MultiMesh carries a single mesh, so
		# mixing the four sprites means four of them; they share the block's culling, so
		# a distant block still drops all four at once.
		for variant in _crop_meshes.size():
			made += _crop_block(block, _crop_meshes[variant], count / _crop_meshes.size())
	return made


func _crop_block(block: Array, mesh: QuadMesh, count: int) -> int:
		if count <= 0:
			return 0
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = count
		for i in count:
			var at: Vector2 = block[_rng.randi_range(0, block.size() - 1)]
			at += Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
			var xf := Transform3D()
			xf = xf.scaled(Vector3.ONE * _rng.randf_range(0.75, 1.3))
			# Sunk slightly, so the roots meet the soil instead of hovering on it.
			xf.origin = Vector3(at.x, _terrain.height_at(at.x, at.y) - 0.06, at.y)
			mm.set_instance_transform(i, xf)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_end = CROP_CULL
		mmi.visibility_range_end_margin = CROP_FADE
		# No fade: dithered fade costs a transparency pass, and at this distance the
		# stalks are a couple of pixels tall — popping is invisible under the dither.
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
