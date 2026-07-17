extends RefCounted
class_name FarmPlan
## Loads the farm plan authored by tools/farm_designer.py.
##
## The plan is what the terrain used to guess. Ground cover inside the plan's square is
## authored; outside it, and on any cell left unpainted, the terrain's own slope rules
## still apply — the plan overrides the BASE ground, it does not switch the rules off.
## So a road laid across a slope still picks up dirt and rock the way the hill does.
##
## The zone map reaches the shader as a runtime-generated R8 ImageTexture. Runtime, not
## a committed PNG: an imported texture would be VRAM-compressed and mipmapped by
## default, which silently corrupts data (the same trap lut_512.png has to defeat with a
## hand-written .import). Nothing here touches the import pipeline.

## Must match tools/farm_plan.py.
const VERSION := 1
const CELL_SIZE := 2.0
const GRID := 256
const EXTENT := CELL_SIZE * GRID     # 512 world units
const ORIGIN := -EXTENT / 2.0        # -256

## Ground name -> Texture2DArray layer. Order must match GROUND_TYPES in farm_plan.py.
const GROUND_LAYER := {
	"pasture": TerrainTextures.LAYER_PASTURE,
	"dirt": TerrainTextures.LAYER_DIRT,
	"road": TerrainTextures.LAYER_ROAD,
	"crop": TerrainTextures.LAYER_CROP,
	"mud": TerrainTextures.LAYER_MUD,
}

## A field gate is 4m — two cells. Wide enough to read as a gate rather than a missing
## post, and to drive a cart through, which is what the derived road aims at.
const GATE_CELLS := 2

## How far trampling reaches from a gate or a trough, in world units. Past this an
## enclosure is just grazed; within it the ground is churned to mud.
const TRAMPLE_RADIUS := 11.0
## Trampling along the inside of the fence line, where stock walk the boundary. Weaker
## than a gate and much tighter — a fence is walked, not milled around.
const FENCE_TRAMPLE_RADIUS := 3.0
const FENCE_TRAMPLE_STRENGTH := 0.45

var zones: Array[Dictionary] = []
var structures: Array[Dictionary] = []
## GRID*GRID zone ids, row-major. Zone 0 means "not authored".
var cells: PackedByteArray = PackedByteArray()
var source_path: String = ""
var loaded: bool = false
var error: String = ""

## Derived, not authored — the same standing as the fences. One gate per fenced zone,
## as {zone, from, to, centre, edges}: `edges` are the fence segments it replaces, and
## `centre` is what the road network drives to and the trample map churns around.
##
## Held on the plan rather than worked out in FarmBuilder because three things need the
## same answer: the fence (to leave a hole), the roads (to aim at it), and the trample map
## (to muddy it). Derived twice is derived differently the day one of them changes.
var gates: Array[Dictionary] = []

## The derived track network joining gates and buildings to the authored trunk road, as
## row*GRID+col indices. See FarmRoads — these are stamped over the ground layer map on
## the way to the shader, and never written back into `cells`.
var roads: PackedInt32Array = PackedInt32Array()


## Reads the plan, or returns an empty-but-valid plan whose zone map is all "natural".
## A missing or broken plan must never stop the game booting — the terrain's own rules
## are a complete fallback.
static func load_from(path: String) -> FarmPlan:
	var plan := FarmPlan.new()
	plan.source_path = path
	plan.cells.resize(GRID * GRID)
	plan.cells.fill(0)

	if not FileAccess.file_exists(path):
		plan.error = "no plan at %s — using bare terrain" % path
		return plan

	var text := FileAccess.get_file_as_string(path)
	var doc = JSON.parse_string(text)
	if typeof(doc) != TYPE_DICTIONARY:
		plan.error = "%s is not valid JSON" % path
		return plan
	if doc.get("version") != VERSION:
		plan.error = "plan version %s, expected %d" % [doc.get("version"), VERSION]
		return plan
	var world: Dictionary = doc.get("world", {})
	if int(world.get("grid", 0)) != GRID or absf(float(world.get("cell_size", 0.0)) - CELL_SIZE) > 0.001:
		# Mismatched geometry would silently misplace every zone, so refuse it loudly
		# rather than render a farm that is subtly in the wrong place.
		plan.error = "plan grid %s@%s does not match this build (%d@%s)" % [
			world.get("grid"), world.get("cell_size"), GRID, CELL_SIZE]
		return plan

	for z: Dictionary in doc.get("zones", []):
		plan.zones.append(z)
	for s: Dictionary in doc.get("structures", []):
		plan.structures.append(s)

	var rows: Array = doc.get("cells", [])
	if rows.size() != GRID:
		plan.error = "plan has %d rows, expected %d" % [rows.size(), GRID]
		return plan
	for r in GRID:
		if not plan._decode_row(String(rows[r]), r):
			return plan

	plan.loaded = true
	# Order matters: roads aim at gates, so the gates have to exist first.
	plan._derive_gates()
	plan.roads = FarmRoads.derive(plan)
	return plan


func _decode_row(text: String, row: int) -> bool:
	var at := 0
	for part in text.split(",", false):
		var bits := part.split(":")
		if bits.size() != 2:
			error = "row %d: malformed run %s" % [row, part]
			return false
		var value := int(bits[0])
		var run := int(bits[1])
		if at + run > GRID:
			error = "row %d overruns the grid" % row
			return false
		for i in run:
			cells[row * GRID + at + i] = value
		at += run
	if at != GRID:
		error = "row %d decodes to %d cells, expected %d" % [row, at, GRID]
		return false
	return true


func zone_of(zone_id: int) -> Dictionary:
	for z in zones:
		if int(z.get("id", -1)) == zone_id:
			return z
	return {}


## Zone id at a world position, or 0 outside the plan's square.
func zone_at(world_x: float, world_z: float) -> int:
	var col := int(floor((world_x - ORIGIN) / CELL_SIZE))
	var row := int(floor((world_z - ORIGIN) / CELL_SIZE))
	if col < 0 or col >= GRID or row < 0 or row >= GRID:
		return 0
	return cells[row * GRID + col]


static func cell_to_world(col: int, row: int) -> Vector2:
	return Vector2(ORIGIN + (col + 0.5) * CELL_SIZE, ORIGIN + (row + 0.5) * CELL_SIZE)


## Bakes cells -> ground layer into an R8 texture for the terrain shader.
##
## The texture stores the LAYER, not the zone id: the shader only ever needs to know
## which ground to draw, and resolving zone -> ground here means retyping a zone in the
## designer does not need the shader to know anything about zones.
func ground_layer_texture() -> ImageTexture:
	var lut := PackedByteArray()
	lut.resize(256)
	lut.fill(TerrainTextures.LAYER_PASTURE)
	for z in zones:
		var ground := String(z.get("ground", "pasture"))
		lut[int(z.get("id", 0))] = GROUND_LAYER.get(ground, TerrainTextures.LAYER_PASTURE)

	var data := PackedByteArray()
	data.resize(GRID * GRID)
	for i in GRID * GRID:
		data[i] = lut[cells[i]]
	# The derived tracks go on LAST, over whatever the zone underneath was painted: a spur
	# only exists where something drove, and something driving over a pasture makes it a
	# track. Stamped here rather than into `cells` because `cells` is the designer's
	# document — a track is not a zone, and writing one in would put a zone id in the file
	# that has no zone to go with it.
	for index in roads:
		data[index] = TerrainTextures.LAYER_ROAD
	var image := Image.create_from_data(GRID, GRID, false, Image.FORMAT_R8, data)
	return ImageTexture.create_from_image(image)


# ---- trampling --------------------------------------------------------------

## Structures stock crowd around. A trough and a feeder are stood at for hours a day;
## a haystack is not, and a barn is somewhere they are led past.
const TRAMPLE_STRUCTURES := ["trough", "hay_feeder"]


## Where stock have churned the ground, 0..1 per cell, row-major.
##
## Only zones that actually hold animals are trampled — an empty pen is fenced grass, not
## a mud bath. Three sources, because these are the three places stock stand rather than
## graze: the gate they queue at, the troughs they crowd, and the fence line they walk.
## Everything between stays pasture, which is what keeps West Pasture reading as a 200x150m
## field rather than a bog with animals in it.
##
## The noise modulates the RADIUS, not the result. A clean radial falloff quantises to
## visible concentric rings under the Bayer dither — the palette has ~4 usable steps across
## this ramp, so a smooth gradient becomes four hard circles. Perturbing the radius makes
## those steps wander instead, which is the same trick the ground textures use to survive
## the 512-colour snap.
## Cached: the shader's trample texture and the grass scatter both want this, and it is
## ~60ms of noise and distance work per plan load. Only ever built from immutable plan
## data, so it can never go stale within a plan's life.
var _trample: PackedFloat32Array = PackedFloat32Array()


func trample_field() -> PackedFloat32Array:
	if _trample.is_empty():
		_trample = _build_trample_field()
	return _trample


## Trampling at a world position, 0 outside the plan. Nearest-cell, which is also what the
## shader reads now — see the trample_map note in terrain.gdshader: interpolating this is
## invisible once the 512-colour palette has quantised the ramp to about four steps.
func trample_at(world_x: float, world_z: float) -> float:
	var col := int(floor((world_x - ORIGIN) / CELL_SIZE))
	var row := int(floor((world_z - ORIGIN) / CELL_SIZE))
	if col < 0 or col >= GRID or row < 0 or row >= GRID:
		return 0.0
	return trample_field()[row * GRID + col]


func _build_trample_field() -> PackedFloat32Array:
	var field := PackedFloat32Array()
	field.resize(GRID * GRID)
	field.fill(0.0)

	# Deterministic from the plan's path, like FarmBuilder's layout rng: the same plan must
	# muddy the same puddles every run, or reloading to check a fence would move the mud.
	var noise := FastNoiseLite.new()
	noise.seed = hash(source_path) + 7
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.06

	for z in zones:
		if String(z.get("contents", "none")) == "none" or int(z.get("count", 0)) <= 0:
			continue
		var zone_id := int(z.get("id", 0))
		var points := _trample_points(zone_id)
		for row in GRID:
			for col in GRID:
				var index := row * GRID + col
				if cells[index] != zone_id:
					continue
				var at := cell_to_world(col, row)
				# +-35% on the reach, so the mud spreads and pinches instead of ringing.
				var wobble := 1.0 + 0.35 * noise.get_noise_2d(at.x, at.y)
				var t := 0.0
				for p: Vector2 in points:
					t = maxf(t, 1.0 - clampf(at.distance_to(p) / (TRAMPLE_RADIUS * wobble), 0.0, 1.0))
				var fence := _fence_distance(col, row, zone_id)
				if fence < FENCE_TRAMPLE_RADIUS * wobble:
					t = maxf(t, FENCE_TRAMPLE_STRENGTH
							* (1.0 - fence / (FENCE_TRAMPLE_RADIUS * wobble)))
				field[index] = clampf(t, 0.0, 1.0)
	return field


## The gate and the troughs of one zone — everything stock mill around.
func _trample_points(zone_id: int) -> Array:
	var points := []
	for g in gates:
		if int(g.get("zone", -1)) == zone_id:
			points.append(g["centre"])
	for s in structures:
		if not String(s.get("type", "")) in TRAMPLE_STRUCTURES:
			continue
		var at := Vector2(float(s.get("x", 0.0)), float(s.get("z", 0.0)))
		# Inside THIS zone: a trough on the yard side of a fence is not the pen's trough,
		# and would otherwise muddy a pen it does not belong to.
		if zone_at(at.x, at.y) == zone_id:
			points.append(at)
	return points


## Roughly how far this cell is from its zone's fence, in world units, giving up past the
## trample radius. Bounded on purpose: a full distance transform would answer for cells
## 200m into a field, and every one of those answers is "further than 3m, so zero".
func _fence_distance(col: int, row: int, zone_id: int) -> float:
	var limit := int(ceil(FENCE_TRAMPLE_RADIUS / CELL_SIZE)) + 1
	for step in range(1, limit + 1):
		for d: Vector2i in [Vector2i(-step, 0), Vector2i(step, 0), Vector2i(0, -step), Vector2i(0, step)]:
			var c := col + d.x
			var r := row + d.y
			# Off the grid counts as outside, so a zone painted to the plan's edge is still
			# walked along that edge — it is fenced there (zone_border_edges agrees).
			if c < 0 or c >= GRID or r < 0 or r >= GRID or cells[r * GRID + c] != zone_id:
				# The fence stands on the cell edge, half a cell before the neighbour's centre.
				return (float(step) - 0.5) * CELL_SIZE
	return INF


## The trample field as the R8 texture the terrain shader samples.
func trample_texture() -> ImageTexture:
	var field := trample_field()
	var data := PackedByteArray()
	data.resize(GRID * GRID)
	for i in GRID * GRID:
		data[i] = int(round(field[i] * 255.0))
	var image := Image.create_from_data(GRID, GRID, false, Image.FORMAT_R8, data)
	return ImageTexture.create_from_image(image)


## Cells belonging to a zone, as world positions. Used to scatter its contents.
func zone_cells(zone_id: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for row in GRID:
		for col in GRID:
			if cells[row * GRID + col] == zone_id:
				out.append(cell_to_world(col, row))
	return out


# ---- gates ------------------------------------------------------------------

## Puts one gate in each fenced zone, on the stretch of fence nearest the road.
##
## Nearest the road, not a fixed compass point: a gate exists to be driven through, so it
## belongs where the traffic already is. A zone with no road anywhere falls back to the
## side facing the plan's centre, which is where the yard is.
func _derive_gates() -> void:
	var road := cells_with_ground("road")
	for z in zones:
		if not bool(z.get("fenced", false)):
			continue
		var zone_id := int(z.get("id", 0))
		var edges := zone_border_edges(zone_id)
		if edges.is_empty():
			continue
		var gate := _gate_on(edges, road)
		if gate.is_empty():
			continue
		gate["zone"] = zone_id
		gates.append(gate)


## Picks the gate opening: the border edge nearest `targets`, widened along the fence to
## GATE_CELLS by taking colinear neighbours.
func _gate_on(edges: Array[PackedVector2Array], targets: PackedVector2Array) -> Dictionary:
	var seed_index := -1
	var best := INF
	for i in edges.size():
		var mid: Vector2 = (edges[i][0] + edges[i][1]) * 0.5
		var d := _distance_to_nearest(mid, targets)
		if d < best:
			best = d
			seed_index = i
	if seed_index < 0:
		return {}

	# Grow along the fence from the seed. Colinear-and-touching, so the opening is one
	# straight gap: two separate 2m holes on different sides of a pen are not a gate.
	var chosen: Array[PackedVector2Array] = [edges[seed_index]]
	var span := PackedVector2Array([edges[seed_index][0], edges[seed_index][1]])
	while chosen.size() < GATE_CELLS:
		var grown := false
		for i in edges.size():
			if edges[i] in chosen:
				continue
			var extended := _extend_span(span, edges[i])
			if extended.is_empty():
				continue
			span = extended
			chosen.append(edges[i])
			grown = true
			break
		if not grown:
			break

	return {
		"from": span[0],
		"to": span[1],
		"centre": (span[0] + span[1]) * 0.5,
		"edges": chosen,
	}


## `span` extended by `edge` if they are colinear and share an endpoint, else empty.
func _extend_span(span: PackedVector2Array, edge: PackedVector2Array) -> PackedVector2Array:
	var along := (span[1] - span[0]).normalized()
	var edge_along := (edge[1] - edge[0]).normalized()
	# Colinear means parallel AND on the same line — two opposite sides of a 2m-wide pen
	# are parallel and touch nothing, but a pen one cell wide would offer both.
	if absf(along.dot(edge_along)) < 0.999:
		return PackedVector2Array()
	if absf((edge[0] - span[0]).cross(along)) > 0.001:
		return PackedVector2Array()
	for a in [span[0], span[1]]:
		for b in [edge[0], edge[1]]:
			if not a.is_equal_approx(b):
				continue
			var far_span := span[1] if a == span[0] else span[0]
			var far_edge := edge[1] if b == edge[0] else edge[0]
			return PackedVector2Array([far_span, far_edge])
	return PackedVector2Array()


func _distance_to_nearest(at: Vector2, targets: PackedVector2Array) -> float:
	if targets.is_empty():
		# No road: aim at the plan's centre, which is where the yard and the buildings are.
		return at.length()
	var best := INF
	for t in targets:
		best = minf(best, at.distance_squared_to(t))
	return sqrt(best)


## Cells of every zone painted with `ground`, as world positions. Subsampled: this feeds
## nearest-target searches over a road that can be a thousand cells long, and a track's
## position is smooth, so every 4th cell answers "which way is the road" identically for a
## sixteenth of the work.
func cells_with_ground(ground: String, stride: int = 4) -> PackedVector2Array:
	var wanted := {}
	for z in zones:
		if String(z.get("ground", "")) == ground:
			wanted[int(z.get("id", 0))] = true
	var out := PackedVector2Array()
	if wanted.is_empty():
		return out
	for row in range(0, GRID, stride):
		for col in range(0, GRID, stride):
			if wanted.has(cells[row * GRID + col]):
				out.append(cell_to_world(col, row))
	return out


## Cell edges where `zone_id` meets anything else — where a fence would stand.
## Returns [from, to] world-space pairs, one per exposed cell edge.
func zone_border_edges(zone_id: int) -> Array[PackedVector2Array]:
	var edges: Array[PackedVector2Array] = []
	var half := CELL_SIZE * 0.5
	for row in GRID:
		for col in GRID:
			if cells[row * GRID + col] != zone_id:
				continue
			var c := cell_to_world(col, row)
			# A neighbour outside the grid counts as different, so a zone painted to the
			# plan's edge is still fenced along it.
			var west := col > 0 and cells[row * GRID + col - 1] == zone_id
			var east := col < GRID - 1 and cells[row * GRID + col + 1] == zone_id
			var north := row > 0 and cells[(row - 1) * GRID + col] == zone_id
			var south := row < GRID - 1 and cells[(row + 1) * GRID + col] == zone_id
			if not west:
				edges.append(PackedVector2Array([c + Vector2(-half, -half), c + Vector2(-half, half)]))
			if not east:
				edges.append(PackedVector2Array([c + Vector2(half, -half), c + Vector2(half, half)]))
			if not north:
				edges.append(PackedVector2Array([c + Vector2(-half, -half), c + Vector2(half, -half)]))
			if not south:
				edges.append(PackedVector2Array([c + Vector2(-half, half), c + Vector2(half, half)]))
	return edges
