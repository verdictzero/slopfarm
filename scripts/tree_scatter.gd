extends Node3D
class_name TreeScatter
## Sows procedural trees across the countryside in natural groves, streamed in tiles around the
## player exactly like TerrainGrass. Where the grass fills the ground, this fills the skyline:
## clumps of conifers, oaks, poplars and scrub standing on the grassland out to a good distance,
## so the world beyond the farm reads as wooded country rolling toward the towns.
##
## Groves, not an even sprinkle. A low-frequency "grove" noise decides where woods are ALLOWED,
## the same trick the terrain uses for its hills — so trees gather into stands with open meadow
## between them, and the stands land in different places every run's worth of world rather than
## dusting one tree per acre everywhere. Within a stand a finer jitter varies the density so the
## edges are ragged, not a circle of trees.
##
## Trees are scenery, not obstacles: like the grass and crops they carry no collision, so a herd,
## the player or the truck pass through them and nothing can wedge on a trunk. Each is a merged,
## vertex-coloured, flat-shaded mesh built once through MeshKit; a tile draws each variant as one
## MultiMesh, so a whole stand is a handful of draw calls.

## World units per tile.
const TILE := 48.0
## Tiles out from the player's tile to keep sown. TILE*RADIUS reaches the cull with margin.
const TILE_RADIUS := 4
## Tiles built per frame while catching up — low, so a burst never hitches mesh generation.
const BUILD_PER_FRAME := 1
## Candidate spacing (metres) of the jittered sampling grid inside a tile.
const SAMPLE_SPACING := 7.0
## Trees fade out and drop past this range. Tall trunks stay legible far further than grass.
const CULL := 190.0
const FADE := 30.0

## Grove gate. A candidate only becomes a tree where the grove noise clears this, so trees
## clump. Higher = fewer, tighter stands.
const GROVE_BEGIN := 0.54
const GROVE_FULL := 0.74
const TREE_VARIANTS := 4

var _terrain: TerrainManager
var _plan: FarmPlan
var _player: Node3D
var _mat: StandardMaterial3D
var _grove_noise: FastNoiseLite

## One ArrayMesh per variant; every tile's MultiMeshes reference these.
var _variant_meshes: Array = []
var _tiles: Dictionary = {}
var _queue: Array[Vector2i] = []
var _queued: Dictionary = {}
var _center: Vector2i = Vector2i(2147483647, 2147483647)

var _dirt_begin_cos := 0.985
var _water_level := -3.0
var _exclusions: Array[Rect2] = []


## Wires up the world references and bakes the tree meshes. Call once, before the plan loads.
func setup(terrain: TerrainManager, player: Node3D) -> void:
	_terrain = terrain
	_player = player
	# Trees may stand on slightly steeper ground than grass tolerates, so subtract a couple of
	# degrees off the grass cutoff — a wooded bank still reads as grass under the shader.
	_dirt_begin_cos = cos(deg_to_rad(terrain.dirt_slope_begin_degrees + 6.0))
	_water_level = terrain.water_level

	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 1.0
	_mat.metallic = 0.0
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_grove_noise = FastNoiseLite.new()
	_grove_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_grove_noise.seed = terrain.noise_seed + 137
	_grove_noise.frequency = 0.006
	_grove_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_grove_noise.fractal_octaves = 3

	var kit := MeshKit.new()
	for v in TREE_VARIANTS:
		_variant_meshes.append(_build_tree(kit, v))


func set_plan(plan: FarmPlan) -> void:
	_plan = plan
	_clear_all()


func add_exclusion(rect: Rect2) -> void:
	_exclusions.append(rect)
	_clear_all()


func _physics_process(_delta: float) -> void:
	if _player == null or _terrain == null:
		return
	var center := _tile_of(_player.global_position)
	if center != _center:
		_center = center
		_recompute()
	_process_queue()


func _tile_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / TILE), floori(pos.z / TILE))


func _in_range(tile: Vector2i) -> bool:
	var d := tile - _center
	return d.x * d.x + d.y * d.y <= TILE_RADIUS * TILE_RADIUS


func _recompute() -> void:
	for dz in range(-TILE_RADIUS, TILE_RADIUS + 1):
		for dx in range(-TILE_RADIUS, TILE_RADIUS + 1):
			var tile := _center + Vector2i(dx, dz)
			if _in_range(tile) and not _tiles.has(tile) and not _queued.has(tile):
				_queued[tile] = true
				_queue.append(tile)
	for tile: Vector2i in _tiles.keys():
		if not _in_range(tile):
			_free_tile(tile)
	_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a.x - _center.x) * (a.x - _center.x) + (a.y - _center.y) * (a.y - _center.y)
		var db := (b.x - _center.x) * (b.x - _center.x) + (b.y - _center.y) * (b.y - _center.y)
		return da < db)


func _process_queue() -> void:
	var built := 0
	while _queue.size() > 0 and built < BUILD_PER_FRAME:
		var tile: Vector2i = _queue.pop_front()
		_queued.erase(tile)
		if not _in_range(tile) or _tiles.has(tile):
			continue
		_build_tile(tile)
		built += 1


func _build_tile(tile: Vector2i) -> void:
	var holder := Node3D.new()
	add_child(holder)
	_tiles[tile] = holder

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(tile) + 7723

	var base_x := float(tile.x) * TILE
	var base_z := float(tile.y) * TILE
	# variant -> Array[Transform3D]
	var placed: Dictionary = {}
	var steps := int(TILE / SAMPLE_SPACING)
	for iz in steps:
		for ix in steps:
			var x := base_x + (float(ix) + rng.randf()) * SAMPLE_SPACING
			var z := base_z + (float(iz) + rng.randf()) * SAMPLE_SPACING
			if not _is_woodland(x, z, rng):
				continue
			var h := _terrain.height_at(x, z)
			var v := rng.randi_range(0, TREE_VARIANTS - 1)
			var xf := Transform3D()
			xf.basis = Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.8, 1.5))
			xf.origin = Vector3(x, h - 0.1, z)
			if not placed.has(v):
				placed[v] = []
			placed[v].append(xf)

	for v: int in placed:
		var transforms: Array = placed[v]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _variant_meshes[v]
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _mat
		mmi.visibility_range_end = CULL
		mmi.visibility_range_end_margin = FADE
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		# Shadows off, like the grass and crops — shadow maps are the frame's biggest cost.
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mmi)


## Is (x,z) somewhere a tree may stand: inside a grove, on unclaimed grassland, above water, off
## the roads and clear of the towns.
func _is_woodland(x: float, z: float, rng: RandomNumberGenerator) -> bool:
	if _excluded(x, z):
		return false
	# Authored ground owns its cover — no wild trees through a pen, crop or road.
	if _plan != null and _plan.zone_at(x, z) != 0:
		return false
	var at := Vector2(x, z)
	if WorldSites.distance_to_any_road(at) < WorldSites.ROAD_CLEARANCE:
		return false
	if WorldSites.distance_to_any_town(at) < WorldSites.TOWN_CLEAR_RADIUS:
		return false
	var h := _terrain.height_at(x, z)
	if h <= _water_level:
		return false
	# Slope from a forward difference, matched (looser by a few degrees) to the grass cutoff.
	var e := 0.8
	var hx := _terrain.height_at(x + e, z) - h
	var hz := _terrain.height_at(x, z + e) - h
	var normal_y := e / sqrt(hx * hx + e * e + hz * hz)
	if normal_y < _dirt_begin_cos:
		return false
	# The grove gate: soft-thresholded noise, so stands have ragged edges rather than hard rims.
	var g := _grove_noise.get_noise_2d(x, z) * 0.5 + 0.5
	var density := smoothstep(GROVE_BEGIN, GROVE_FULL, g)
	return rng.randf() < density


func _excluded(x: float, z: float) -> bool:
	var at := Vector2(x, z)
	for rect in _exclusions:
		if rect.has_point(at):
			return true
	return false


func _free_tile(tile: Vector2i) -> void:
	var holder: Node3D = _tiles[tile]
	if is_instance_valid(holder):
		holder.queue_free()
	_tiles.erase(tile)


func _clear_all() -> void:
	for tile: Vector2i in _tiles.keys():
		_free_tile(tile)
	_queue.clear()
	_queued.clear()
	_center = Vector2i(2147483647, 2147483647)


# ---- tree meshes ------------------------------------------------------------

const BARK := Color(0.34, 0.24, 0.16)
const BARK_DK := Color(0.26, 0.18, 0.12)


func _build_tree(kit: MeshKit, variant: int) -> ArrayMesh:
	kit.begin()
	match variant:
		0: _tree_conifer(kit)
		1: _tree_oak(kit)
		2: _tree_poplar(kit)
		_: _tree_scrub(kit)
	return kit.commit()


## A conifer: a tapered bark trunk and three stacked cones of dark needle foliage.
func _tree_conifer(kit: MeshKit) -> void:
	var green := Color(0.16, 0.34, 0.18)
	kit.cylinder(Vector3(0, 1.4, 0), 0.28, 2.8, 6, BARK)
	kit.cone(Vector3(0, 2.2, 0), 2.0, 2.4, 8, green.darkened(0.06))
	kit.cone(Vector3(0, 3.6, 0), 1.6, 2.4, 8, green)
	kit.cone(Vector3(0, 5.0, 0), 1.1, 2.4, 8, green.lightened(0.06))
	kit.cone(Vector3(0, 6.3, 0), 0.6, 1.6, 8, green.lightened(0.1))


## A broadleaf oak: a stout trunk, a few branches, and a rounded canopy of overlapping spheres.
func _tree_oak(kit: MeshKit) -> void:
	var green := Color(0.26, 0.42, 0.20)
	kit.cylinder(Vector3(0, 1.6, 0), 0.38, 3.2, 6, BARK)
	for k in 3:
		var a := TAU * float(k) / 3.0 + 0.5
		kit.pipe(Vector3(0, 2.6, 0), Vector3(cos(a) * 1.3, 3.9, sin(a) * 1.3), 0.14, 5, BARK_DK)
	kit.sphere(Vector3(0, 4.4, 0), 2.1, 3, 8, green)
	kit.sphere(Vector3(-1.2, 3.9, 0.6), 1.5, 3, 7, green.darkened(0.06))
	kit.sphere(Vector3(1.1, 4.1, -0.5), 1.5, 3, 7, green.lightened(0.06))
	kit.sphere(Vector3(0.2, 5.3, 0.2), 1.4, 3, 7, green.lightened(0.1))


## A poplar: a slim, very tall trunk with a narrow columnar crown of stacked small spheres.
func _tree_poplar(kit: MeshKit) -> void:
	var green := Color(0.30, 0.45, 0.22)
	kit.cylinder(Vector3(0, 2.6, 0), 0.24, 5.2, 6, BARK.lightened(0.04))
	for k in 5:
		var y := 3.2 + float(k) * 1.1
		var r := 1.3 - float(k) * 0.16
		kit.sphere(Vector3(0, y, 0), r, 3, 7, green.lightened(0.03 * k))


## Low scrub: a short trunk and a wide, low tangle of foliage balls.
func _tree_scrub(kit: MeshKit) -> void:
	var green := Color(0.32, 0.40, 0.20)
	kit.cylinder(Vector3(0, 0.5, 0), 0.24, 1.0, 5, BARK)
	kit.sphere(Vector3(0, 1.3, 0), 1.5, 3, 8, green)
	kit.sphere(Vector3(-1.0, 1.0, 0.4), 1.1, 3, 7, green.darkened(0.05))
	kit.sphere(Vector3(0.9, 1.1, -0.5), 1.1, 3, 7, green.lightened(0.05))
