extends Node3D
class_name DmgScatter
## Streams instances of your meshes across the terrain in tiles around a target node — grass, trees,
## rocks, props, whatever. Generalised from slopfarm's grass/tree scatter: it sows candidate points
## on a jittered grid per tile, keeps the ones that pass the placement rules, and draws each variant
## as one MultiMesh so a whole tile is a few draw calls. Tiles outside the radius are freed; nothing
## carries collision (scenery you walk through).
##
## Set the config fields (or the @export vars), assign `meshes`, then call setup(terrain, anchor).
## Placement rules, all optional:
##   - slope_max_degrees / min_height : skip steep ground and anything at/below a water line
##   - clump + clump_begin/full       : gather instances into stands (grove noise) instead of an even sprinkle
##   - add_exclusion(rect)            : keep clear of a footprint (a building, a road strip)
##   - allow_at = func(x, z) -> bool  : your own filter (zones, roads, towns, spawn clearings, …)

@export var tile_size: float = 48.0
## Tiles out from the anchor's tile to keep sown. tile_size * tile_radius should reach `cull`.
@export var tile_radius: int = 4
## Tiles built per frame while catching up. Low so a burst never hitches mesh generation.
@export var build_per_frame: int = 1
## Candidate spacing (metres) of the jittered sampling grid inside a tile.
@export var sample_spacing: float = 7.0
## Instances fade/drop past this range.
@export var cull: float = 190.0
@export var fade: float = 30.0

@export var seed: int = 1337
## Random per-instance uniform scale range.
@export var scale_jitter: Vector2 = Vector2(0.85, 1.2)
## Lift/drop applied to each instance's Y after snapping to the ground.
@export var y_offset: float = -0.1

@export_group("Placement")
## Skip ground steeper than this (0 = flat only, 90 = anywhere).
@export var slope_max_degrees: float = 30.0
## Skip anything at or below this height (a water/hollow line).
@export var min_height: float = -1e9
## Gather instances into stands using low-frequency noise instead of an even sprinkle.
@export var clump: bool = false
@export var clump_begin: float = 0.54
@export var clump_full: float = 0.74
@export var clump_frequency: float = 0.006
## Overall thinning applied everywhere (1 = as dense as the grid/clumping allow).
@export_range(0.0, 1.0) var density: float = 1.0

@export_group("Material")
## Material applied to every instance (as material_override). Leave null to use the default below.
@export var material: Material
## Only when `material` is null: if true, build a flat vertex-colour material (for DmgMeshKit
## meshes, the common case); if false, apply NO override so each mesh keeps its OWN material —
## which is what textured meshes (grass/leaf billboards, props with their own texture) need.
@export var vertex_color_material: bool = true

## One entry per variant. Assign before setup().
var meshes: Array = []
## Optional custom filter: func(x: float, z: float) -> bool. Return false to forbid placement there
## (roads, towns, authored zones, a clearing round the spawn — whatever your game needs).
var allow_at: Callable = Callable()

var _terrain: Node        # DmgTerrain (duck-typed: needs height_at(x, z))
var _anchor: Node3D
var _mat: Material         # null = leave each mesh's own material alone
var _clump_noise: FastNoiseLite
var _slope_min_cos := 0.5
var _exclusions: Array[Rect2] = []

var _tiles: Dictionary = {}
var _queue: Array[Vector2i] = []
var _queued: Dictionary = {}
var _center: Vector2i = Vector2i(2147483647, 2147483647)


## terrain must expose `height_at(x, z) -> float` (DmgTerrain does). anchor is the node streaming
## keys off (your player/camera).
func setup(terrain: Node, anchor: Node3D) -> void:
	_terrain = terrain
	_anchor = anchor
	_slope_min_cos = cos(deg_to_rad(clampf(slope_max_degrees, 0.0, 89.0)))

	# Choose the instance material: an explicit one, the flat vertex-colour default, or none (so
	# textured meshes keep their own material). See the exports above.
	if material != null:
		_mat = material
	elif vertex_color_material:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 1.0
		m.metallic = 0.0
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat = m
	else:
		_mat = null

	if clump:
		_clump_noise = FastNoiseLite.new()
		_clump_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_clump_noise.seed = seed + 137
		_clump_noise.frequency = clump_frequency
		_clump_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_clump_noise.fractal_octaves = 3


## Keep instances clear of an XZ footprint (world space). Rebuilds sown tiles.
func add_exclusion(rect: Rect2) -> void:
	_exclusions.append(rect)
	_clear_all()


func _physics_process(_delta: float) -> void:
	if _anchor == null or _terrain == null or meshes.is_empty():
		return
	var center := _tile_of(_anchor.global_position)
	if center != _center:
		_center = center
		_recompute()
	_process_queue()


func _tile_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / tile_size), floori(pos.z / tile_size))


func _in_range(tile: Vector2i) -> bool:
	var d := tile - _center
	return d.x * d.x + d.y * d.y <= tile_radius * tile_radius


func _recompute() -> void:
	for dz in range(-tile_radius, tile_radius + 1):
		for dx in range(-tile_radius, tile_radius + 1):
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
	while _queue.size() > 0 and built < build_per_frame:
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
	rng.seed = hash(tile) + seed

	var base_x := float(tile.x) * tile_size
	var base_z := float(tile.y) * tile_size
	var placed: Dictionary = {}   # variant -> Array[Transform3D]
	var steps := maxi(1, int(tile_size / sample_spacing))
	for iz in steps:
		for ix in steps:
			var x := base_x + (float(ix) + rng.randf()) * sample_spacing
			var z := base_z + (float(iz) + rng.randf()) * sample_spacing
			if not _allowed(x, z, rng):
				continue
			var h: float = _terrain.height_at(x, z)
			var v := rng.randi_range(0, meshes.size() - 1)
			var xf := Transform3D()
			xf.basis = Basis(Vector3.UP, rng.randf() * TAU).scaled(
					Vector3.ONE * rng.randf_range(scale_jitter.x, scale_jitter.y))
			xf.origin = Vector3(x, h + y_offset, z)
			if not placed.has(v):
				placed[v] = []
			placed[v].append(xf)

	for v: int in placed:
		var transforms: Array = placed[v]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[v]
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		if _mat != null:
			mmi.material_override = _mat   # null leaves each mesh's own material intact
		mmi.visibility_range_end = cull
		mmi.visibility_range_end_margin = fade
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mmi)


func _allowed(x: float, z: float, rng: RandomNumberGenerator) -> bool:
	if _excluded(x, z):
		return false
	if allow_at.is_valid() and not bool(allow_at.call(x, z)):
		return false
	var h: float = _terrain.height_at(x, z)
	if h <= min_height:
		return false
	# Slope from a forward difference of the height field.
	var e := 0.8
	var hx: float = _terrain.height_at(x + e, z) - h
	var hz: float = _terrain.height_at(x, z + e) - h
	var normal_y := e / sqrt(hx * hx + e * e + hz * hz)
	if normal_y < _slope_min_cos:
		return false
	var chance := density
	if clump:
		var g := _clump_noise.get_noise_2d(x, z) * 0.5 + 0.5
		chance *= smoothstep(clump_begin, clump_full, g)
	return rng.randf() < chance


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
