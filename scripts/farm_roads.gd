extends RefCounted
class_name FarmRoads
## Derives the farm's tracks: the ones nobody drew, joining the ones somebody did.
##
## This is deliberately NOT a road generator. The README's rule is that two systems
## inventing the same thing is incoherent — the plan already replaced the terrain's
## hash-invented pens outright, and a second opinion about where a road goes would be the
## same mistake. So nothing here decides where roads should BE. It only answers a question
## the plan already implies but does not spell out: the designer painted a trunk road,
## hung gates on the pens and dropped buildings in the yard, so what joins them up?
##
## That makes this the same kind of derivation as the fences. A fence is not authored
## either; it falls out of "this zone is fenced" plus the zone's shape. A spur falls out of
## "this gate exists" plus "that road exists". Retype a zone or move a barn and both re-derive.
##
## Roads are stamped into the ground-layer TEXTURE, not into the plan's cells. The cells
## are the designer's document and this must not write to it, but more practically: a cell
## carries a zone id, and a spur is not a zone. It has no contents, no fence and no name,
## and inventing 40 single-cell zones to say "road here" would put junk in the file the
## designer has to look at.

## Track width. One cell reads as a footpath from any distance and two is a cart track,
## which is what a spur to a gate is. The trunk the designer painted is 6 cells wide, so
## these stay visibly subordinate to it.
const SPUR_CELLS := 2

## What a spur is allowed to cross, as an A* weight. 1.0 is open ground.
##
## Crop is not solid, just expensive: making it impassable means a wheat field between a
## barn and the road leaves the barn unreachable and the spur silently missing. Expensive
## says "go round if there is any way round", which is what a farmer does, while still
## crossing if the field truly boxes it in.
const CROP_WEIGHT := 6.0
## Existing road is free, so spurs braid into one network instead of running parallel
## tracks a metre apart to the same place.
const ROAD_WEIGHT := 0.15


## Cells the derived network occupies, as a set of row*GRID+col indices.
##
## Greedy attachment, nearest-first: each destination joins whatever road already exists,
## including spurs added moments ago. That is what makes this a network and not a star —
## two gates on the same side of the farm share one track out to the trunk rather than each
## running their own the whole way.
##
## Nearest-first because the order changes the shape and one of the orders is right: taking
## a far gate first lays a long track across the middle of the farm, and everything else
## then hangs off that arbitrary spine. Growing outward from the trunk instead means each
## spur is the shortest honest join available when it is laid.
static func derive(plan: FarmPlan) -> PackedInt32Array:
	var network := PackedInt32Array()
	var trunk := _trunk_cells(plan)
	if trunk.is_empty():
		# No painted road means no network: there is nothing to join TO, and inventing a
		# trunk would be exactly the second opinion this file exists to avoid.
		return network

	var destinations := _destinations(plan)
	if destinations.is_empty():
		return network

	var astar := _build_astar(plan)
	# Reached: every cell a spur may terminate on. Seeded with the trunk, grown per spur.
	var reached := {}
	for cell in trunk:
		reached[cell] = true

	var pending := destinations.duplicate()
	while not pending.is_empty():
		var best_index := -1
		var best_target := Vector2i.ZERO
		var best_distance := INF
		for i in pending.size():
			var candidate: Vector2i = pending[i]
			var target := _nearest(candidate, reached)
			var d := Vector2(candidate - target).length()
			if d < best_distance:
				best_distance = d
				best_index = i
				best_target = target
		if best_index < 0:
			break
		var from: Vector2i = pending[best_index]
		pending.remove_at(best_index)

		var path := astar.get_id_path(from, best_target)
		if path.is_empty():
			# Boxed in with no route at all. Not fatal and not silent: a farm still renders
			# without one spur, but a designer who moved a barn into a walled corner should
			# be told rather than left wondering where the track went.
			push_warning("farm roads: no route from cell %s to the road network" % from)
			continue
		for point: Vector2i in path:
			var index := point.y * FarmPlan.GRID + point.x
			reached[index] = true
			network.append(index)
			# Later spurs are attracted to this one, so the network braids.
			astar.set_point_weight_scale(point, ROAD_WEIGHT)
	return _widen(network, plan)


## The painted trunk: cells of every zone whose ground the designer set to "road".
static func _trunk_cells(plan: FarmPlan) -> PackedInt32Array:
	var out := PackedInt32Array()
	var road_zones := {}
	for z in plan.zones:
		if String(z.get("ground", "")) == "road":
			road_zones[int(z.get("id", 0))] = true
	if road_zones.is_empty():
		return out
	for i in FarmPlan.GRID * FarmPlan.GRID:
		if road_zones.has(plan.cells[i]):
			out.append(i)
	return out


## Everything a track should reach: every gate, and every structure standing in the open.
##
## Structures inside a fenced zone are skipped rather than routed to. A trough in the
## middle of a cow pen does not want a road to it — it wants the pen's gate, which is
## already a destination — and routing to it would drive a gravel track through the herd.
static func _destinations(plan: FarmPlan) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var seen := {}
	for g in plan.gates:
		# The gate centre sits on the fence line, so its cell belongs to the pen and is
		# solid — _build_astar punches exactly these cells back out, which is what lets a
		# spur arrive at the gate without being allowed anywhere else inside.
		var cell := _clamp_cell(_cell_of(g["centre"]))
		if not seen.has(cell):
			seen[cell] = true
			out.append(cell)
	for s in plan.structures:
		var x := float(s.get("x", 0.0))
		var z := float(s.get("z", 0.0))
		var zone := plan.zone_at(x, z)
		var zone_data := plan.zone_of(zone)
		if bool(zone_data.get("fenced", false)):
			continue
		var cell := _clamp_cell(_cell_of(Vector2(x, z)))
		if not seen.has(cell):
			seen[cell] = true
			out.append(cell)
	return out


## AStarGrid2D, not a hand-rolled search: this runs on every live reload of the plan, and
## the designer's whole point is that saving feels instant. The engine's is C++ and solves
## this grid in single-digit milliseconds; the same loop in GDScript does not.
static func _build_astar(plan: FarmPlan) -> AStarGrid2D:
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, FarmPlan.GRID, FarmPlan.GRID)
	astar.cell_size = Vector2.ONE
	# Octile over Manhattan: a track that can only turn in right angles reads as plumbing.
	# AT_LEAST_ONE_WALKABLE, not ALWAYS: ALWAYS lets a path cut the diagonal between two
	# solid cells, i.e. squeeze a cart track through the corner where two pens touch.
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()

	# Zone id -> what crossing it costs, resolved before the sweep. One pass over the 65k
	# cells, not one per zone: this runs on every save, and the loop is the whole cost.
	var weights := {}
	var solid := {}
	for z in plan.zones:
		var zone_id := int(z.get("id", 0))
		var ground := String(z.get("ground", ""))
		if ground == "road":
			weights[zone_id] = ROAD_WEIGHT
		elif ground == "crop":
			weights[zone_id] = CROP_WEIGHT
		# Pen interiors are solid, so a spur goes to a pen's GATE and stops instead of
		# taking the shortcut straight through the fence to the trough. The gate cells
		# themselves are punched back out below, or every destination would be walled off
		# from its own path.
		if bool(z.get("fenced", false)):
			solid[zone_id] = true
	for i in FarmPlan.GRID * FarmPlan.GRID:
		var zone_id := plan.cells[i]
		if solid.has(zone_id):
			astar.set_point_solid(Vector2i(i % FarmPlan.GRID, i / FarmPlan.GRID), true)
		elif weights.has(zone_id):
			astar.set_point_weight_scale(
					Vector2i(i % FarmPlan.GRID, i / FarmPlan.GRID), weights[zone_id])

	for g in plan.gates:
		var cell := _clamp_cell(_cell_of(g["centre"]))
		astar.set_point_solid(cell, false)
	return astar


## The cell in `reached` nearest `from`, by straight-line distance.
static func _nearest(from: Vector2i, reached: Dictionary) -> Vector2i:
	var best := Vector2i.ZERO
	var best_distance := INF
	for index: int in reached:
		var cell := Vector2i(index % FarmPlan.GRID, index / FarmPlan.GRID)
		var d := Vector2(cell - from).length_squared()
		if d < best_distance:
			best_distance = d
			best = cell
	return best


## Fattens the one-cell path to SPUR_CELLS. Done after routing rather than by routing a
## wide agent: A* on a grid finds a line, and a track is a line with width — pathing a
## 2-cell-wide agent would need a clearance pass for the same result.
static func _widen(network: PackedInt32Array, plan: FarmPlan) -> PackedInt32Array:
	var out := {}
	var reach := SPUR_CELLS - 1
	for index in network:
		var col := index % FarmPlan.GRID
		var row := index / FarmPlan.GRID
		for dr in range(-reach, reach + 1):
			for dc in range(-reach, reach + 1):
				var c := col + dc
				var r := row + dr
				if c < 0 or c >= FarmPlan.GRID or r < 0 or r >= FarmPlan.GRID:
					continue
				# Never widen INTO a pen. The path itself only touches a pen at its gate,
				# but a 2-cell brush centred on that gate would smear road over the ground
				# either side of the posts.
				var zone := plan.zone_of(plan.cells[r * FarmPlan.GRID + c])
				if bool(zone.get("fenced", false)):
					continue
				out[r * FarmPlan.GRID + c] = true
	var packed := PackedInt32Array()
	for index: int in out:
		packed.append(index)
	return packed


static func _cell_of(at: Vector2) -> Vector2i:
	return Vector2i(
		int(floor((at.x - FarmPlan.ORIGIN) / FarmPlan.CELL_SIZE)),
		int(floor((at.y - FarmPlan.ORIGIN) / FarmPlan.CELL_SIZE)))


static func _clamp_cell(cell: Vector2i) -> Vector2i:
	return cell.clamp(Vector2i.ZERO, Vector2i(FarmPlan.GRID - 1, FarmPlan.GRID - 1))
