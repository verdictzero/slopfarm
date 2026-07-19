extends Node3D
class_name DmgTerrain
## Streams flat-shaded, low-poly terrain chunks around the assigned player.
##
## The world is a flat farm basin at the origin, ringed by rolling hills. Terrain
## height is a pure function of world position, so chunks are deterministic and can be
## built, freed and rebuilt without any bookkeeping. That purity is also why the hills
## are placed relative to the *origin* rather than to the player: keyed to the player
## they would recede as you walked toward them, and every chunk would rebuild
## differently each step.
##
## Beyond the basin a low-frequency region mask -- not the ring alone -- decides where
## hills are allowed, so flat ground still dominates as you travel out instead of the
## world turning into endless hills.
##
## Distant chunks drop resolution and only the innermost chunks carry collision, which
## is what makes the draw distance affordable on the Pi.

@export_group("Chunks")
## World units per chunk side.
@export var chunk_size: float = 192.0
## Grid cells per side at full detail. Low values give the faceted, low-poly look.
@export var chunk_resolution: int = 32
## Radius (in chunks) of visible terrain around the player. Note the *guaranteed*
## radius is shorter than view_distance * chunk_size: a chunk just outside the circle
## can start much nearer once the player's offset within their own chunk is counted.
## At 6 / 192 terrain always exists to 960 units, which is what the fog's depth_end is
## pinned to. Raising this without moving the fog just shows the player the void.
@export var view_distance: int = 6
## Radius (in chunks) that receives collision. Kept small — you only collide nearby.
@export var collision_distance: int = 2
## How many chunks may be built per physics frame while streaming. Kept low so mesh
## generation (on the main thread) never spikes into a visible hitch.
@export var chunks_per_frame: int = 2

@export_group("Level of detail")
## Chunk ring at which resolution first halves, and then halves again. Both bands sit
## outside collision_distance, so a chunk never changes shape under the player's feet
## and only skirted (non-colliding) chunks ever meet a coarser neighbour.
@export var lod_band_1: int = 3
@export var lod_band_2: int = 5

@export_group("Terrain shape")
@export var noise_seed: int = 1337
## The farm. Dead flat out to here, in world units from the origin.
@export var plains_radius: float = 380.0
## Hills reach full height by this radius. This wants to be well inside the fog rather
## than merely inside the draw distance: ramp them in too gradually and they only get
## tall out where the haze has already washed them to grey, so the farm looks out at
## silhouettes instead of green country.
@export var hills_full_radius: float = 560.0
## Ring boundaries are displaced by up to this much, so the basin does not read as a
## circle drawn on a map. The gates share the warp, so a direction that pushes the
## basin out pushes its hills out by the same amount.
@export var ring_warp: float = 120.0

@export var plains_amplitude: float = 5.0
## Higher values push the plains noise toward zero: large dead-flat stretches with the
## occasional soft swell, rather than constant rolling.
@export var plains_flatness: float = 3.2
@export var hill_amplitude: float = 75.0
## Ground at or below this goes to bare dirt — trampled hollows in the pasture.
@export var water_level: float = -3.0

@export_group("Ground cover")
## Slope at which dirt starts showing through the grass, and where it takes over
## entirely. These are checked against the measured slope distribution of this terrain
## (tools/probe_slope.gd): steeper than 10 deg is ~17% of visible ground, 18 deg ~7%.
## A threshold outside that range is dead code — the previous rule wanted 53 deg, which
## this terrain never reaches.
@export var dirt_slope_begin_degrees: float = 10.0
@export var dirt_slope_full_degrees: float = 18.0
## Rock is reserved for the steepest ground: >22 deg is 4.4% of the world, >30 is 1.6%.
@export var rock_slope_begin_degrees: float = 22.0
@export var rock_slope_full_degrees: float = 32.0


# Region mask cutoffs. These sit above the middle of the mask's range on purpose:
# raised ground is the exception the mask has to argue for, which is what keeps flat
# ground dominant once you leave the basin. Lowering these floods the world with
# hills fast.
const HILL_MASK_BEGIN := 0.52
const HILL_MASK_END := 0.76

## Assign the node whose position drives streaming (set by main.gd).
var player: Node3D

var _plains_noise: FastNoiseLite
var _hill_noise: FastNoiseLite
var _region_noise: FastNoiseLite
var _warp_noise: FastNoiseLite
var _tint_noise: FastNoiseLite

var _material: ShaderMaterial
# Vector2i -> { "mesh": MeshInstance3D, "body": StaticBody3D | null, "lod": int }
var _chunks: Dictionary = {}
var _queued: Dictionary = {}
var _build_queue: Array[Vector2i] = []
var _center: Vector2i = Vector2i(2147483647, 2147483647)

# Scratch buffers for mesh building. Members rather than locals passed to helpers:
# GDScript's packed arrays are copy-on-write, so a helper writing into a passed-in
# array would quietly scribble on a copy.
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _write: int = 0

func _ready() -> void:
	_plains_noise = _make_noise(noise_seed, 0.0035, 3)
	# Low frequency and few octaves: long, smooth swells that read as *rolling* rather
	# than lumpy. Raising either turns the ring into noise-covered bumps.
	_hill_noise = _make_noise(noise_seed + 11, 0.0012, 3)
	# Region mask frequency is a balance, not a taste: too low and only a couple of
	# mask features fit around the ring, so whether the farm has a view at all comes
	# down to the seed. ~1250 units per feature fits several groups of hills around
	# the ring while still reading as distinct country rather than clutter.
	_region_noise = _make_noise(noise_seed + 29, 0.0008, 2)
	_warp_noise = _make_noise(noise_seed + 53, 0.0006, 2)
	# Drives the per-face tint, whose main job is hiding the 4-unit texture repeat.
	# ~35 units per feature, not 85: a hillside is only ~50 units across, so a coarser
	# tint holds one value over the whole face and the tiling shows through undisturbed.
	# The floor is the facet size (6 units) — below that the tint just aliases.
	_tint_noise = _make_noise(noise_seed + 97, 0.028, 3)

	_material = ShaderMaterial.new()
	_material.shader = load("res://addons/dmgkit/shaders/dmg_terrain.gdshader")

	_material.set_shader_parameter(&"ground_tex", DmgTerrainTextures.build(noise_seed))
	_material.set_shader_parameter(&"tile_world_units", DmgTerrainTextures.TILE_WORLD_UNITS)
	_material.set_shader_parameter(&"rock_tile_world_units", DmgTerrainTextures.ROCK_TILE_WORLD_UNITS)

	# Degrees are the readable unit to author in; cosines are what the fragment shader
	# can compare against a normal without paying for an acos. Convert once, here.
	_material.set_shader_parameter(&"dirt_begin_cos", cos(deg_to_rad(dirt_slope_begin_degrees)))
	_material.set_shader_parameter(&"dirt_full_cos", cos(deg_to_rad(dirt_slope_full_degrees)))
	_material.set_shader_parameter(&"rock_begin_cos", cos(deg_to_rad(rock_slope_begin_degrees)))
	_material.set_shader_parameter(&"rock_full_cos", cos(deg_to_rad(rock_slope_full_degrees)))

	_material.set_shader_parameter(&"water_level", water_level)

func _make_noise(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = seed_value
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5
	return noise

## World-space terrain height at a horizontal position. Pure — safe to call before
## any chunk exists (used to spawn the player on solid ground).
func height_at(world_x: float, world_z: float) -> float:
	var radius := sqrt(world_x * world_x + world_z * world_z)
	radius += _warp_noise.get_noise_2d(world_x, world_z) * ring_warp

	# Plains: raising a signed value to a power collapses everything near zero into
	# genuinely flat ground, leaving only the strongest noise as visible swells.
	var p := _plains_noise.get_noise_2d(world_x, world_z)
	var height := signf(p) * pow(absf(p), plains_flatness) * plains_amplitude

	# The mask decides *where* raised ground is allowed; the radial gate decides how
	# far from the farm it may start.
	var mask := _region_noise.get_noise_2d(world_x, world_z) * 0.5 + 0.5

	var hill_gate := smoothstep(plains_radius, hills_full_radius, radius)
	var hill_mask := smoothstep(HILL_MASK_BEGIN, HILL_MASK_END, mask)
	if hill_gate > 0.0 and hill_mask > 0.0:
		var h := _hill_noise.get_noise_2d(world_x, world_z) * 0.5 + 0.5
		height += h * hill_amplitude * hill_gate * hill_mask

	return height

## Synchronously build (with collision) the chunks immediately around a position so
## the player has solid ground the instant the game starts, then queue the rest.
func prime(world_pos: Vector3) -> void:
	var center := _chunk_coord(world_pos)
	for dz in range(-collision_distance, collision_distance + 1):
		for dx in range(-collision_distance, collision_distance + 1):
			var coord := center + Vector2i(dx, dz)
			if _in_radius(coord, center, collision_distance):
				if not _chunks.has(coord):
					_build_chunk(coord, 0)
				_ensure_collision(coord)
	_center = center
	_recompute_desired(center)

func _physics_process(_delta: float) -> void:
	if player == null:
		return
	var center := _chunk_coord(player.global_position)
	if center != _center:
		_center = center
		_recompute_desired(center)
	_process_build_queue()
	_update_collision(center)

func _chunk_coord(world_pos: Vector3) -> Vector2i:
	return Vector2i(floori(world_pos.x / chunk_size), floori(world_pos.z / chunk_size))

func _ring(coord: Vector2i, center: Vector2i) -> int:
	return maxi(absi(coord.x - center.x), absi(coord.y - center.y))

func _in_radius(coord: Vector2i, center: Vector2i, radius: int) -> bool:
	var dx := coord.x - center.x
	var dz := coord.y - center.y
	return dx * dx + dz * dz <= radius * radius

## Detail level for a chunk: 0 full, 1 half, 2 quarter resolution.
func _lod_for(coord: Vector2i, center: Vector2i) -> int:
	var ring := _ring(coord, center)
	if ring >= lod_band_2:
		return 2
	if ring >= lod_band_1:
		return 1
	return 0

func _recompute_desired(center: Vector2i) -> void:
	# Queue any in-range chunk we do not have, or that is now at the wrong detail
	# level. Existing chunks stay drawn until their rebuild comes up, so swapping
	# LOD never opens a hole.
	for dz in range(-view_distance, view_distance + 1):
		for dx in range(-view_distance, view_distance + 1):
			var coord := center + Vector2i(dx, dz)
			if not _in_radius(coord, center, view_distance) or _queued.has(coord):
				continue
			if not _chunks.has(coord) or _chunks[coord]["lod"] != _lod_for(coord, center):
				_queued[coord] = true
				_build_queue.append(coord)
	# Free chunks that fell out of range.
	for coord: Vector2i in _chunks.keys():
		if not _in_radius(coord, center, view_distance):
			_free_chunk(coord)
	# Build the nearest chunks first.
	_build_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a.x - center.x) * (a.x - center.x) + (a.y - center.y) * (a.y - center.y)
		var db := (b.x - center.x) * (b.x - center.x) + (b.y - center.y) * (b.y - center.y)
		return da < db)

func _process_build_queue() -> void:
	var built := 0
	while _build_queue.size() > 0 and built < chunks_per_frame:
		var coord: Vector2i = _build_queue.pop_front()
		_queued.erase(coord)
		if not _in_radius(coord, _center, view_distance):
			continue
		var lod := _lod_for(coord, _center)
		if _chunks.has(coord):
			if _chunks[coord]["lod"] == lod:
				continue
			_free_chunk(coord)
		_build_chunk(coord, lod)
		built += 1

func _build_chunk(coord: Vector2i, lod: int) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _generate_mesh(coord, lod)
	mesh_instance.material_override = _material
	mesh_instance.position = Vector3(coord.x * chunk_size, 0.0, coord.y * chunk_size)
	add_child(mesh_instance)
	_chunks[coord] = {"mesh": mesh_instance, "body": null, "lod": lod}

func _free_chunk(coord: Vector2i) -> void:
	var chunk: Dictionary = _chunks[coord]
	var mesh_instance: MeshInstance3D = chunk["mesh"]
	if is_instance_valid(mesh_instance):
		mesh_instance.queue_free()
	_chunks.erase(coord)

func _ensure_collision(coord: Vector2i) -> void:
	if not _chunks.has(coord):
		return
	var chunk: Dictionary = _chunks[coord]
	if chunk["body"] != null:
		return
	var mesh_instance: MeshInstance3D = chunk["mesh"]
	var shape := mesh_instance.mesh.create_trimesh_shape()
	if shape == null:
		return
	shape.backface_collision = true
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	# Parented to the (already positioned) mesh, so collision inherits its transform.
	mesh_instance.add_child(body)
	chunk["body"] = body

func _remove_collision(coord: Vector2i) -> void:
	var chunk: Dictionary = _chunks[coord]
	var body = chunk["body"]
	if body != null:
		if is_instance_valid(body):
			body.queue_free()
		chunk["body"] = null

func _update_collision(center: Vector2i) -> void:
	for coord: Vector2i in _chunks.keys():
		if _in_radius(coord, center, collision_distance):
			_ensure_collision(coord)
		elif _chunks[coord]["body"] != null:
			_remove_collision(coord)

func _generate_mesh(coord: Vector2i, lod: int) -> ArrayMesh:
	var res := maxi(2, chunk_resolution >> lod)
	var step := chunk_size / float(res)
	var base_x := coord.x * chunk_size
	var base_z := coord.y * chunk_size
	var stride := res + 1

	# Sample the height field once per grid vertex. Sampling per quad corner instead
	# would repeat every shared vertex four times, and the height field is now five
	# noise lookups deep.
	var grid := PackedFloat32Array()
	grid.resize(stride * stride)
	for j in stride:
		for i in stride:
			grid[j * stride + i] = height_at(base_x + i * step, base_z + j * step)

	# A coarse chunk's edge cuts corners its finer neighbour follows, leaving pinholes
	# along the seam. A downward skirt plugs them. Only LOD'd chunks get one: skirts
	# are vertical walls, and on a colliding chunk the player would walk into them.
	var skirted := lod > 0
	var triangles := res * res * 2 + (res * 8 if skirted else 0)
	_resize_scratch(triangles * 3)

	for j in res:
		for i in res:
			var x0 := i * step
			var z0 := j * step
			var x1 := x0 + step
			var z1 := z0 + step
			var p00 := Vector3(x0, grid[j * stride + i], z0)
			var p10 := Vector3(x1, grid[j * stride + i + 1], z0)
			var p01 := Vector3(x0, grid[(j + 1) * stride + i], z1)
			var p11 := Vector3(x1, grid[(j + 1) * stride + i + 1], z1)
			_add_surface_triangle(p00, p01, p11, base_x, base_z)
			_add_surface_triangle(p00, p11, p10, base_x, base_z)

	if skirted:
		var depth := step * 2.0
		for i in res:
			var xa := i * step
			var xb := xa + step
			# North (-Z) and south (+Z) edges. Each skirt borrows the normal of the
			# surface cell it hangs from, so it wears that cell's ground cover.
			_add_skirt_quad(
				Vector3(xa, grid[i], 0.0), Vector3(xb, grid[i + 1], 0.0),
				depth, _cell_normal(grid, stride, i, 0, step), base_x, base_z)
			_add_skirt_quad(
				Vector3(xb, grid[res * stride + i + 1], chunk_size),
				Vector3(xa, grid[res * stride + i], chunk_size),
				depth, _cell_normal(grid, stride, i, res - 1, step), base_x, base_z)
			# West (-X) and east (+X) edges.
			var za := i * step
			var zb := za + step
			_add_skirt_quad(
				Vector3(0.0, grid[(i + 1) * stride], zb), Vector3(0.0, grid[i * stride], za),
				depth, _cell_normal(grid, stride, 0, i, step), base_x, base_z)
			_add_skirt_quad(
				Vector3(chunk_size, grid[i * stride + res], za),
				Vector3(chunk_size, grid[(i + 1) * stride + res], zb),
				depth, _cell_normal(grid, stride, res - 1, i, step), base_x, base_z)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Surface normal of grid cell (i, j), read straight off the height samples the mesh is
## already built from — no extra noise lookups.
func _cell_normal(grid: PackedFloat32Array, stride: int, i: int, j: int, step: float) -> Vector3:
	var h := grid[j * stride + i]
	var gx := (grid[j * stride + i + 1] - h) / step
	var gz := (grid[(j + 1) * stride + i] - h) / step
	return Vector3(-gx, 1.0, -gz).normalized()

func _resize_scratch(vertex_count: int) -> void:
	_verts.resize(vertex_count)
	_normals.resize(vertex_count)
	_colors.resize(vertex_count)
	_write = 0

func _push(vertex: Vector3, normal: Vector3, color: Color) -> void:
	_verts[_write] = vertex
	_normals[_write] = normal
	_colors[_write] = color
	_write += 1

func _add_surface_triangle(a: Vector3, b: Vector3, c: Vector3, base_x: float, base_z: float) -> void:
	var normal := (b - a).cross(c - a).normalized()
	if normal.y < 0.0:
		normal = -normal
	var centre := (a + b + c) / 3.0
	var color := _tint_for(base_x + centre.x, base_z + centre.z, centre.y)
	# One normal + tint for the whole face; vertices are not shared, so the surface
	# stays crisply faceted (low-poly) instead of smooth-shaded.
	_push(a, normal, color)
	_push(b, normal, color)
	_push(c, normal, color)

## Drops a vertical quad from the edge segment a->b down by `depth`.
##
## `normal` is the ADJACENT SURFACE's normal, not the wall's own horizontal one. A skirt
## exists to plug a pinhole, so it should look like the ground above it — and the ground
## cover shader reads slope from the normal, so a horizontal normal would ask it for
## "vertical ground" and get pure rock. Every LOD seam would wear a grey speck.
func _add_skirt_quad(a: Vector3, b: Vector3, depth: float, normal: Vector3,
		base_x: float, base_z: float) -> void:
	var color := _tint_for(base_x + (a.x + b.x) * 0.5, base_z + (a.z + b.z) * 0.5,
			(a.y + b.y) * 0.5)
	var a_low := a - Vector3(0.0, depth, 0.0)
	var b_low := b - Vector3(0.0, depth, 0.0)
	_push(a, normal, color)
	_push(a_low, normal, color)
	_push(b_low, normal, color)
	_push(a, normal, color)
	_push(b_low, normal, color)
	_push(b, normal, color)

## Per-face tint, centred near white. This is NOT the ground's colour any more — the
## textures carry that, and which texture a face wears is decided in the shader from its
## slope. The tint has two jobs a fragment shader would have to pay for every pixel, and
## which per-face granularity (6-unit facets) is plenty for:
##
## 1. Break up texture tiling. The ground repeats every 4 units; without a large-scale
##    variation on top, the flat basin reads as a grid.
## 2. Dry the crests out, which used to be a colour band and is now a warm shift.
func _tint_for(world_x: float, world_z: float, height: float) -> Color:
	var variation := _tint_noise.get_noise_2d(world_x, world_z) * 0.5 + 0.5
	var brightness := 0.86 + 0.24 * variation
	var tint := Color(brightness, brightness, brightness)

	# Crests bleach and warm; hollows keep their colour. The divisor is scaled to the
	# height the terrain actually reaches (measured max 69.8, so saturating at ~70).
	# A divisor of 60 wanted height 100 and silently capped the effect at half strength.
	var dry := clampf((height - 40.0) / 30.0, 0.0, 1.0)
	tint.r *= 1.0 + 0.12 * dry
	tint.g *= 1.0 + 0.04 * dry
	tint.b *= 1.0 - 0.10 * dry
	return tint
