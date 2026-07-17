extends Node3D
class_name TerrainGrass
## Sows grass over the terrain's own grassland — everywhere the ground reads as grass but
## the farm plan did not author it. Short, medium and tall clumps mixed together, so the
## open country outside the pens is grass rather than a bare green carpet.
##
## Deliberately NOT the pasture scatter. FarmBuilder already tufts every pasture zone, and
## those pens are left exactly as they were; this fills the gap the pens never covered — the
## unpainted basin, the roadside verges, the lower hill slopes. The rule for "is this grass"
## is the terrain's own, not the plan's: low enough slope that the ground shader draws grass
## there, above the water line, and not inside any authored zone (which owns its own cover —
## a road, a crop field or a pasture must not sprout wild grass through it).
##
## Streamed in tiles around the player like the terrain chunks, and for the same reason: the
## world is unbounded, the cull is short, so only a handful of tiles near the player are ever
## worth having. Tiles build a couple per frame and free as the player walks off them.

## World units per tile. Matches the crop/grass culling block so a tile is a natural unit of
## "drop this whole patch when it is far enough away".
const TILE := 16.0
## How many tiles out from the player's tile to keep sown. The cull is ~26 m and a tile is
## 16, so two rings guarantees grass is always present out to the cull with margin.
const TILE_RADIUS := 2
## Tiles built per frame while catching up. Low so a burst of new tiles (spawn, teleport,
## plan reload) never spikes mesh generation into a visible hitch, the same budget idea the
## chunk streamer uses.
const BUILD_PER_FRAME := 2

## Clumps per square metre, summed across the tiers. Below the pasture's 5: this covers the
## whole visible basin, not a bounded pen, so it is bounded by being sparse the way the
## pasture is bounded by being small. Fill from near clumps is the cost, exactly as the
## README measures for the crop — density is the only real lever, so it is the low one.
const PER_SQUARE_METRE := 1.6
## Distant tiles drop whole past this. A touch beyond the pasture's 22 because the tall tier
## is ~0.9 m and stays legible slightly further out than a 0.4 m pasture tuft.
const CULL := 26.0
const FADE := 6.0
## Two arrangements per tier — enough that a patch does not read as one clump stamped over
## and over, without the VRAM of a dozen.
const VARIANTS_PER_TIER := 2

## Tier mix. Mostly short and medium with a scattering of tall, so the grass has relief
## without turning the basin into a hayfield you cannot see over. Indices are the tiers in
## GrassSprites; the weights sum to 1.
const TIER_WEIGHTS: Array[float] = [0.45, 0.4, 0.15]

var _terrain: TerrainManager
var _plan: FarmPlan
var _player: Node3D

## [tier][variant] -> QuadMesh. Built once; every tile's MultiMeshes reference these.
var _tier_meshes: Array = []
## Vector2i tile -> Node3D holding that tile's MultiMeshInstance3D children.
var _tiles: Dictionary = {}
var _queue: Array[Vector2i] = []
var _queued: Dictionary = {}
var _center: Vector2i = Vector2i(2147483647, 2147483647)

var _dirt_begin_cos: float = 0.985
var _water_level: float = -3.0
## XZ rectangles kept clear of grass — the factory floor, chiefly, so clumps do not grow up
## through a concrete slab that is not a plan zone.
var _exclusions: Array[Rect2] = []


## Wires up the world references and bakes the tier meshes. Call once, before the plan is
## handed over.
func setup(terrain: TerrainManager, player: Node3D) -> void:
	_terrain = terrain
	_player = player
	# Match the ground shader's grass/dirt threshold, so a clump only ever stands where the
	# ground under it is actually drawn as grass. Off by a degree and grass would fringe the
	# dirt on every bank.
	_dirt_begin_cos = cos(deg_to_rad(terrain.dirt_slope_begin_degrees))
	_water_level = terrain.water_level

	for tier in GrassSprites.TIER_COUNT:
		var meshes: Array[QuadMesh] = []
		# Sun baked into albedo, exactly as the pasture tuft does it (a lit billboard blazes
		# against the ground it stands in). GRASS_LIGHT is the one measured value for that,
		# so this borrows FarmBuilder's rather than inventing a second.
		for tex in GrassSprites.build_tier(tier, VARIANTS_PER_TIER, 4200 + tier * 17):
			meshes.append(GrassSprites.billboard_mesh(
					tex, GrassSprites.tier_height(tier), FarmBuilder.GRASS_LIGHT))
		_tier_meshes.append(meshes)


## The plan decides which ground is off-limits (authored zones own their own cover). A null
## plan is fine — then only the terrain's slope/water rules gate the grass. Clears the sown
## tiles so they re-sow against the new plan, since a repainted zone changes what is excluded.
func set_plan(plan: FarmPlan) -> void:
	_plan = plan
	_clear_all()


## Keep a rectangle of ground clear of grass. Used for the factory footprint.
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
	# Nearest first, so grass fills in around the player before the edges of the ring.
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
	# Recorded even if it ends up empty (a tile of pure dirt or road), so an empty patch is
	# not re-queued every time the player steps back onto its ring.
	_tiles[tile] = holder

	var rng := RandomNumberGenerator.new()
	# Deterministic per tile: walking off a patch and back must re-sow the same clumps, not
	# reshuffle the field under the player.
	rng.seed = hash(tile) + 1009

	var base_x := float(tile.x) * TILE
	var base_z := float(tile.y) * TILE
	var count := int(TILE * TILE * PER_SQUARE_METRE)

	# Vector2i(tier, variant) -> Array[Transform3D]. Gathered before any MultiMesh is made,
	# because instance_count has to be the number that SURVIVED the grass test — sizing to
	# `count` and skipping would leave rejects piled at the tile origin.
	var placed: Dictionary = {}
	for i in count:
		var x := base_x + rng.randf() * TILE
		var z := base_z + rng.randf() * TILE
		if _excluded(x, z):
			continue
		# Authored ground owns its cover: a road, crop or pasture must not grow wild grass.
		if _plan != null and _plan.zone_at(x, z) != 0:
			continue
		var h := _terrain.height_at(x, z)
		# At or below the water line the terrain goes to bare dirt (trampled hollows); grass
		# there would stand in the mud.
		if h <= _water_level:
			continue
		# Slope from a forward difference of the height field, matched to the shader's
		# grass/dirt cutoff — no grass on ground the shader is already drawing as dirt/rock.
		var e := 0.7
		var hx := _terrain.height_at(x + e, z) - h
		var hz := _terrain.height_at(x, z + e) - h
		var normal_y := e / sqrt(hx * hx + e * e + hz * hz)
		if normal_y < _dirt_begin_cos:
			continue

		var tier := _pick_tier(rng)
		var variant := rng.randi_range(0, VARIANTS_PER_TIER - 1)
		var xf := Transform3D().scaled(Vector3.ONE * rng.randf_range(0.8, 1.25))
		# Sunk a touch so the roots meet the soil rather than hovering on it, the same as the
		# pasture scatter.
		xf.origin = Vector3(x, h - 0.05, z)
		var key := Vector2i(tier, variant)
		if not placed.has(key):
			placed[key] = []
		placed[key].append(xf)

	for key: Vector2i in placed:
		var transforms: Array = placed[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _tier_meshes[key.x][key.y]
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_end = CULL
		mmi.visibility_range_end_margin = FADE
		# No dithered fade: at the cull a clump is a couple of pixels and popping is invisible
		# under the ordered dither, so a transparency pass would be pure cost.
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mmi)


func _pick_tier(rng: RandomNumberGenerator) -> int:
	var r := rng.randf()
	var acc := 0.0
	for tier in TIER_WEIGHTS.size():
		acc += TIER_WEIGHTS[tier]
		if r <= acc:
			return tier
	return GrassSprites.TIER_SHORT


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
