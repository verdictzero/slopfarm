extends Node3D
class_name GlueFactory
## A big, player-traversable glue works standing east of the farm, and the winding pipeline
## that runs inside it. Feed a knocked-out horse into the marked intake hopper at the door and
## it drops into the grinder — which erupts with blood and gore — and is then carried down a
## long serpentine conveyor that switchbacks across the whole hall, machine to machine, each
## transforming the stream and handing it to the next, until sacks of granulated glue stack on
## the loading dock at the far end for the player to cart into town and sell.
##
## Every machine here is CUSTOM and PROCEDURAL — built the way FarmBuilder builds the farm: one
## merged, vertex-coloured mesh per object through MeshKit, with a trimesh body off that same
## mesh so the machines and walls are solid. Nothing is loaded from a .glb: the grinder, the
## tanks, the columns, the press, the extruder, the mill and the bagger are all modelled here
## from boxes, cylinders, cones, pipes, spheres and torii, greebled with motors, gauges, valve
## wheels, ladders and pipe runs so each reads as a real, detailed piece of plant.
##
## It sits ON the flat basin like every farm structure — the floor slab is a foundation that
## reaches below the ground, and a long gentle ramp at the door lifts the player onto it without
## a lip to snag on.

# ---- placement --------------------------------------------------------------
## World centre. East of the authored farm — the horse pen ends around x≈129, so the door end
## here is a short carry from the intake. Well inside the flat basin (radius ~230 < 380).
const CENTER := Vector3(212.0, 0.0, -8.0)

const WIDTH_X := 118.0       # long axis, the direction the pipeline broadly runs
const DEPTH_Z := 56.0        # hall width; the belt switchbacks across it in four rows
const WALL_H := 12.0
const WALL_T := 0.6
const DOOR_W := 10.0
const DOOR_H := 6.0
## The floor slab doubles as a foundation, reaching this far below the top surface so no
## daylight shows under the walls where the basin dips. Same idea as FarmBuilder's skirt.
const FOUNDATION_SINK := 3.0

# ---- pipeline ---------------------------------------------------------------
## Where a product rides on the conveyor.
const ITEM_Y := 1.2
## The four switchback rows the belt runs down, by local Z. The belt enters at the door on the
## first row and snakes across the hall, reversing direction each row.
const ROW_Z: Array[float] = [-18.0, -6.0, 6.0, 18.0]
## Machine X positions on each row, already in travel order (rows alternate direction). The
## grinder is first, hard by the door; the bagger is last, by the dock.
const ROW_XS: Array = [
	[-40.0, -16.0, 8.0, 32.0],     # row 0, running +X from the door
	[32.0, 8.0, -16.0, -40.0],     # row 1, running -X
	[-40.0, -16.0, 8.0, 32.0],     # row 2, running +X
	[32.0, 8.0, -16.0],            # row 3, running -X to the dock (3 machines)
]
## X the belt turns around at, just past the outermost machines, at each end of a row.
const TURN_X := 46.0

## Belt speed, metres/second, along the whole winding run.
const CONVEYOR_SPEED := 5.0

## The 15 unit operations, in order. Front-end mechanical (coral), wet chemistry (teal),
## dry finish (amber).
const MACHINE_NAMES: Array[String] = [
	"grinder", "bone separator", "renderer", "degreaser",
	"lime soak", "wash tank", "extraction vat", "clarifier",
	"filter press", "evaporator", "vacuum concentrator", "chill extruder",
	"drying tunnel", "hammer mill", "bagging & pack",
]
## Archetype (visual builder) per machine, indexed to MACHINE_NAMES.
const MACHINE_KIND: Array[String] = [
	"grinder", "crusher", "cooker", "tank",
	"tank", "tank", "column", "tank",
	"press", "column", "column", "extruder",
	"tunnel", "mill", "bagger",
]
## Seconds each machine holds a batch. Wet stages are the slow ones.
const PROCESS_TIME: Array[float] = [
	1.4, 1.6, 2.2, 2.0,
	2.6, 2.2, 3.0, 2.4,
	2.6, 3.0, 2.8, 2.0,
	2.8, 1.8, 1.6,
]

## How near the intake hopper the player has to be, carrying a ragdoll, to feed it in.
const FEED_RADIUS := 6.5
## Cap on batches in flight, so a mob of feeds cannot spawn unbounded product nodes.
const MAX_ACTIVE := 16
## Finished sacks cycle through this many dock slots; the oldest frees as new ones land.
const SACK_CAP := 30

# ---- palette ----------------------------------------------------------------
const FLOOR := Color(0.32, 0.32, 0.34)
const FLOOR_TOP := Color(0.39, 0.39, 0.42)
const WALL := Color(0.47, 0.47, 0.51)
const WALL_TRIM := Color(0.55, 0.55, 0.60)
const ROOF := Color(0.20, 0.20, 0.23)
const RAMP := Color(0.36, 0.35, 0.34)
const METAL := Color(0.52, 0.53, 0.57)
const METAL_DK := Color(0.34, 0.35, 0.39)
const DARK := Color(0.24, 0.24, 0.27)
const RUST := Color(0.46, 0.30, 0.20)
const HAZARD := Color(0.86, 0.66, 0.12)
const GLASS := Color(0.55, 0.70, 0.72)
const BAND_CORAL := Color(0.72, 0.34, 0.27)
const BAND_TEAL := Color(0.24, 0.50, 0.50)
const BAND_AMBER := Color(0.74, 0.55, 0.22)
const TALLOW := Color(0.80, 0.74, 0.42)
const BLOOD := Color(0.42, 0.05, 0.05)
const GORE := Color(0.55, 0.12, 0.12)

var _terrain: TerrainManager
var _player: Node3D
var _kit := MeshKit.new()
## A second kit for standalone sub-meshes (spinners, particle bits) so building one never
## clears the machine geometry the main kit is midway through accumulating.
var _sub := MeshKit.new()
var _mat: StandardMaterial3D

## Ordered belt nodes: each {pos, machine} where machine is the machine index or -1 for a
## plain corner/lead waypoint. Products walk this list from intake to dock.
var _nodes: Array = []
## Per machine: {busy, name, kind, center, node} — center is its local pivot on the belt.
var _machines: Array = []
var _stream_meshes: Array = []      # one item mesh per stream phase 0..15
var _tallow_mesh: ArrayMesh
var _batches: Array = []            # products in flight
var _byproducts: Array = []         # tallow drums sliding to the bin
var _sacks: Array = []              # parked finished sacks, cycled through SACK_CAP slots
var _sack_count := 0
var _spinners: Array = []           # {node, speed} — rotating machine parts
var _feed_world: Vector3
var _dock_world: Vector3
var _floor_y := 0.0
var _ground_out_y := 0.0            # local y of the ground just outside the door (for the ramp)
var _footprint := Rect2()
var _ramp_len := 14.0

## Finished sacks waiting on the dock to be carted off and sold. Read/zeroed by the economy.
var _glue_ready := 0


## Builds the whole works and wires it to the world. Call once from main.
func setup(terrain: TerrainManager, player: Node3D) -> void:
	_terrain = terrain
	_player = player

	# Floor sits at or above the highest ground under the footprint, so terrain never pokes up
	# through the slab; the door ramp makes up the step to the ground outside.
	var highest := -1e9
	for sx: float in [-0.5, -0.25, 0.0, 0.25, 0.5]:
		for sz: float in [-0.5, 0.0, 0.5]:
			var wx := CENTER.x + sx * WIDTH_X
			var wz := CENTER.z + sz * DEPTH_Z
			highest = maxf(highest, terrain.height_at(wx, wz))
	_floor_y = highest + 0.05
	position = Vector3(CENTER.x, _floor_y, CENTER.z)

	# The ramp is sized to whatever step the terrain leaves at the door so its slope stays
	# gentle (~12 deg or less) no matter how the basin dips — a long shallow wedge the capsule
	# walks straight up instead of snagging on. Sampled a little way out from the door.
	var door_ground := terrain.height_at(CENTER.x - WIDTH_X * 0.5 - 4.0, CENTER.z - 18.0)
	_ground_out_y = door_ground - _floor_y
	var rise := absf(_ground_out_y)
	_ramp_len = maxf(12.0, rise * 5.0)

	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 1.0
	_mat.metallic = 0.0
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_build_streams()
	_build_nodes()
	_build_shell()
	_build_machines()
	_build_conveyors()
	_build_lights()
	_build_gore()

	_feed_world = to_global(_machines[0]["center"] + Vector3(0, 2.2, 0))
	_dock_world = to_global(Vector3(-46.0, 1.0, 18.0))
	_footprint = Rect2(CENTER.x - WIDTH_X * 0.5 - _ramp_len, CENTER.z - DEPTH_Z * 0.5 - 1.0,
			WIDTH_X + _ramp_len + 2.0, DEPTH_Z + 2.0)
	add_to_group("glue_factory")


## The XZ rectangle the building covers, so TerrainGrass/trees keep clear of the slab.
func footprint() -> Rect2:
	return _footprint


## World position of the loading dock where finished glue stacks (for the sell loop / signage).
func dock_world() -> Vector3:
	return _dock_world


## How many sacks of finished glue are waiting on the dock right now.
func ready_glue() -> int:
	return _glue_ready


## Take all the glue waiting on the dock (returns how many sacks) and clear the pile. Called
## when the player loads up to cart it into town.
func collect_glue() -> int:
	var n := _glue_ready
	_glue_ready = 0
	return n


## Feed a carried horse into the intake. True if it was accepted (the caller then consumes the
## ragdoll); false if too far from the hopper or the line is full.
func try_feed(world_pos: Vector3) -> bool:
	if _machines.is_empty():
		return false
	if world_pos.distance_to(_feed_world) > FEED_RADIUS:
		return false
	if _batches.size() >= MAX_ACTIVE:
		return false
	_spawn_batch()
	return true


func _process(delta: float) -> void:
	for s in _spinners:
		(s["node"] as Node3D).rotate_y(s["speed"] * delta)

	var survivors := []
	for b in _batches:
		if not _update_batch(b, delta):
			survivors.append(b)
	_batches = survivors

	var kept := []
	for p in _byproducts:
		if _advance(p, delta):
			(p["node"] as Node3D).queue_free()
		else:
			kept.append(p)
	_byproducts = kept


# ---- pipeline simulation ----------------------------------------------------

func _spawn_batch() -> void:
	var node := MeshInstance3D.new()
	node.material_override = _mat
	node.mesh = _stream_meshes[0]
	add_child(node)
	node.position = _nodes[0]["pos"]
	# node = the belt node it is currently AT; it advances toward node+1.
	_batches.append({
		"node": node, "stage": 0, "at": 0, "state": "move",
		"from": Vector3.ZERO, "to": Vector3.ZERO, "progress": 0.0, "timer": 0.0, "slot": 0,
	})
	_begin_move(_batches.back())


## Sets a batch moving from its current node toward the next one.
func _begin_move(b: Dictionary) -> void:
	var i: int = b["at"]
	if i + 1 >= _nodes.size():
		# Reached the dock end — park it as a finished sack.
		b["from"] = _nodes[i]["pos"]
		b["slot"] = _sack_count
		_sack_count += 1
		b["to"] = _sack_slot(b["slot"])
		b["progress"] = 0.0
		b["state"] = "output"
		return
	b["from"] = _nodes[i]["pos"]
	b["to"] = _nodes[i + 1]["pos"]
	b["progress"] = 0.0
	b["state"] = "move"


## Advances one batch. Returns true when finished and should be dropped from the list (its node
## lives on as a parked sack).
func _update_batch(b: Dictionary, dt: float) -> bool:
	match b["state"]:
		"move":
			if _advance(b, dt):
				b["at"] = int(b["at"]) + 1
				var node: Dictionary = _nodes[b["at"]]
				if int(node["machine"]) >= 0:
					b["state"] = "arrive"
				else:
					_begin_move(b)
			return false
		"arrive":
			var m: Dictionary = _machines[int(_nodes[b["at"]]["machine"])]
			if not m["busy"]:
				m["busy"] = true
				b["state"] = "process"
				b["timer"] = PROCESS_TIME[int(m["index"])]
				(b["node"] as MeshInstance3D).visible = false   # hidden inside the machine
			return false
		"process":
			b["timer"] = float(b["timer"]) - dt
			if b["timer"] <= 0.0:
				var mi := int(_nodes[b["at"]]["machine"])
				var m: Dictionary = _machines[mi]
				m["busy"] = false
				b["stage"] = int(b["stage"]) + 1
				(b["node"] as MeshInstance3D).mesh = _stream_meshes[mini(int(b["stage"]), _stream_meshes.size() - 1)]
				(b["node"] as MeshInstance3D).visible = true
				(b["node"] as Node3D).position = _nodes[b["at"]]["pos"]
				if String(m["name"]) == "degreaser":
					_spawn_tallow(_nodes[b["at"]]["pos"])
				_begin_move(b)
			return false
		"output":
			if _advance(b, dt):
				_park_sack(b["node"], b["slot"])
				_glue_ready += 1
				return true
			return false
	return false


## Moves a mover from `from` toward `to` at belt speed. Returns true on arrival.
func _advance(mover: Dictionary, dt: float) -> bool:
	var from: Vector3 = mover["from"]
	var to: Vector3 = mover["to"]
	var length := from.distance_to(to)
	if length < 0.001:
		(mover["node"] as Node3D).position = to
		return true
	mover["progress"] = float(mover["progress"]) + CONVEYOR_SPEED * dt / length
	var t := clampf(mover["progress"], 0.0, 1.0)
	(mover["node"] as Node3D).position = from.lerp(to, t)
	return mover["progress"] >= 1.0


func _spawn_tallow(at: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.material_override = _mat
	node.mesh = _tallow_mesh
	add_child(node)
	node.position = at
	# Off to a drum bin on the -Z wall by the degreaser, then collected (freed) on arrival.
	var bin := Vector3(at.x, 0.7, -DEPTH_Z * 0.5 + 3.0)
	_byproducts.append({"node": node, "from": at, "to": bin, "progress": 0.0})


## Dock slots, cycled through SACK_CAP positions, stacked by the -X wall on the last row.
func _sack_slot(index: int) -> Vector3:
	var i := index % SACK_CAP
	var col := i % 5
	var row := (i / 5) % 3
	var layer := (i / 15) % 2
	var origin := Vector3(-50.0, 0.5 + float(layer) * 0.75, 14.0)
	return origin + Vector3(float(col) * 0.95, 0.0, float(row) * 0.95)


func _park_sack(node: Node3D, slot: int) -> void:
	node.position = _sack_slot(slot)
	node.rotation.y = float(slot) * 1.3
	var idx := slot % SACK_CAP
	if _sacks.size() <= idx:
		_sacks.resize(idx + 1)
	var old = _sacks[idx]
	if old != null and is_instance_valid(old) and old != node:
		old.queue_free()
	_sacks[idx] = node


# ---- stream item meshes -----------------------------------------------------

func _build_streams() -> void:
	for stage in 16:
		_stream_meshes.append(_stream_mesh(stage))
	_kit.begin()
	_kit.cylinder(Vector3(0, 0.4, 0), 0.42, 0.8, 10, TALLOW)
	_kit.torus(Vector3(0, 0.8, 0), 0.42, 0.06, 10, 5, TALLOW.darkened(0.2))
	_tallow_mesh = _kit.commit()


## Colour for a stream stage 0..15: dark meat → coral → teal → amber → burlap.
func _stream_color(stage: int) -> Color:
	var t := clampf(float(stage) / 15.0, 0.0, 1.0)
	if t < 0.25:
		return Color(0.45, 0.16, 0.14).lerp(BAND_CORAL, t / 0.25)
	if t < 0.55:
		return BAND_CORAL.lerp(BAND_TEAL, (t - 0.25) / 0.30)
	if t < 0.85:
		return BAND_TEAL.lerp(BAND_AMBER, (t - 0.55) / 0.30)
	return BAND_AMBER.lerp(Color(0.60, 0.50, 0.33), (t - 0.85) / 0.15)


## An item for one stream stage, centred on the origin so it can ride anywhere on the belt.
## The shape hints at the state of matter across the line: lumps, a pail of liquor, a gelled
## loaf, dry shards, and finally a tied sack.
func _stream_mesh(stage: int) -> ArrayMesh:
	var c := _stream_color(stage)
	_kit.begin()
	if stage == 0:
		_kit.box(Vector3(0, 0.3, 0), Vector3(0.75, 0.6, 0.55), c)
		_kit.box(Vector3(0.12, 0.5, -0.1), Vector3(0.3, 0.25, 0.28), c.lightened(0.1))
	elif stage <= 2:
		_kit.box(Vector3(0, 0.22, 0), Vector3(0.62, 0.42, 0.62), c)
		_kit.box(Vector3(-0.1, 0.44, 0.08), Vector3(0.3, 0.22, 0.26), c.lightened(0.12))
		_kit.box(Vector3(0.16, 0.4, -0.1), Vector3(0.22, 0.18, 0.2), c.darkened(0.08))
	elif stage <= 10:
		# A pail of liquor: a short can with a darker meniscus and a handle.
		_kit.cylinder(Vector3(0, 0.32, 0), 0.36, 0.62, 10, METAL.darkened(0.1))
		_kit.disk(Vector3(0, 0.63, 0), 0.32, 10, c)
		_kit.pipe(Vector3(-0.34, 0.5, 0), Vector3(0.34, 0.5, 0), 0.03, 5, METAL_DK)
	elif stage == 11:
		# Gelled noodles: a soft loaf with ridges.
		_kit.box(Vector3(0, 0.24, 0), Vector3(0.62, 0.44, 0.52), c)
		for k in 4:
			_kit.pipe(Vector3(-0.28, 0.47, -0.18 + k * 0.12), Vector3(0.28, 0.47, -0.18 + k * 0.12), 0.04, 5, c.lightened(0.1))
	elif stage <= 13:
		# Dry brittle shards stacked.
		for k in 3:
			_kit.box(Vector3(-0.16 + k * 0.16, 0.16 + k * 0.05, 0), Vector3(0.26, 0.32, 0.42), c.darkened(0.05 * k))
	else:
		# A burlap sack of finished glue: body plus a pinched, tied neck.
		_kit.box(Vector3(0, 0.36, 0), Vector3(0.64, 0.72, 0.5), c)
		_kit.box(Vector3(0, 0.78, 0), Vector3(0.36, 0.2, 0.3), c.darkened(0.2))
		_kit.pipe(Vector3(-0.16, 0.7, 0), Vector3(0.16, 0.7, 0), 0.03, 5, c.darkened(0.3))
	return _kit.commit()


# ---- building shell ---------------------------------------------------------

func _build_shell() -> void:
	var hx := WIDTH_X * 0.5
	var hz := DEPTH_Z * 0.5

	# Floor + foundation, with a painted border strip.
	_kit.begin()
	_kit.box(Vector3(0, -FOUNDATION_SINK * 0.5, 0), Vector3(WIDTH_X, FOUNDATION_SINK, DEPTH_Z), FLOOR)
	_kit.box(Vector3(0, -0.05, 0), Vector3(WIDTH_X, 0.1, DEPTH_Z), FLOOR_TOP)
	_emit(true)

	# Walls, one mesh + one body. Door in the -X wall aligned to the intake row (z = ROW_Z[0]).
	_kit.begin()
	var wy := (WALL_H - FOUNDATION_SINK) * 0.5
	var wh := WALL_H + FOUNDATION_SINK
	var door_z := ROW_Z[0]
	# +X wall and the two long side walls.
	_kit.box(Vector3(hx, wy, 0), Vector3(WALL_T, wh, DEPTH_Z), WALL)
	_kit.box(Vector3(0, wy, -hz), Vector3(WIDTH_X, wh, WALL_T), WALL)
	_kit.box(Vector3(0, wy, hz), Vector3(WIDTH_X, wh, WALL_T), WALL)
	# -X wall (door end): a panel each side of the door plus a lintel over it.
	var door_lo := door_z - DOOR_W * 0.5
	var door_hi := door_z + DOOR_W * 0.5
	var neg_len := door_lo - (-hz)
	_kit.box(Vector3(-hx, wy, (-hz + door_lo) * 0.5), Vector3(WALL_T, wh, neg_len), WALL)
	var pos_len := hz - door_hi
	_kit.box(Vector3(-hx, wy, (door_hi + hz) * 0.5), Vector3(WALL_T, wh, pos_len), WALL)
	_kit.box(Vector3(-hx, (DOOR_H + WALL_H) * 0.5, door_z), Vector3(WALL_T, WALL_H - DOOR_H, DOOR_W), WALL)
	# Pilaster trim up the wall corners and a cornice band, so the shell is not four blank slabs.
	for cx in [-hx, hx]:
		for cz in [-hz, hz]:
			_kit.box(Vector3(cx, wy, cz), Vector3(1.2, wh, 1.2), WALL_TRIM)
	_kit.box(Vector3(0, WALL_H - 0.4, -hz), Vector3(WIDTH_X, 0.8, 1.0), WALL_TRIM)
	_kit.box(Vector3(0, WALL_H - 0.4, hz), Vector3(WIDTH_X, 0.8, 1.0), WALL_TRIM)
	# High clerestory windows down the long walls, as inset glass strips.
	for wx2 in range(-4, 5):
		var gx := float(wx2) * 12.0
		_kit.box(Vector3(gx, WALL_H - 2.6, -hz + 0.2), Vector3(6.0, 2.4, 0.2), GLASS)
		_kit.box(Vector3(gx, WALL_H - 2.6, hz - 0.2), Vector3(6.0, 2.4, 0.2), GLASS)
	_emit(true)

	# Roof: a low double-pitch with ridge beams and roof vents, not a flat slab.
	_kit.begin()
	var ridge := WALL_H + 3.0
	_kit.quad(Vector3(-hx - 0.6, WALL_H, -hz - 0.6), Vector3(hx + 0.6, WALL_H, -hz - 0.6),
			Vector3(hx + 0.6, ridge, 0), Vector3(-hx - 0.6, ridge, 0), ROOF)
	_kit.quad(Vector3(-hx - 0.6, ridge, 0), Vector3(hx + 0.6, ridge, 0),
			Vector3(hx + 0.6, WALL_H, hz + 0.6), Vector3(-hx - 0.6, WALL_H, hz + 0.6), ROOF.lightened(0.04))
	# Gable ends filling the triangle under the ridge.
	for gx2 in [-hx - 0.6, hx + 0.6]:
		_kit.tri(Vector3(gx2, WALL_H, -hz - 0.6), Vector3(gx2, WALL_H, hz + 0.6), Vector3(gx2, ridge, 0), ROOF.darkened(0.1))
	_kit.box(Vector3(0, ridge, 0), Vector3(WIDTH_X + 1.2, 0.5, 0.6), METAL_DK)   # ridge beam
	for vx in [-36.0, -12.0, 12.0, 36.0]:
		_kit.box(Vector3(vx, ridge + 0.5, 0), Vector3(3.0, 1.2, 2.4), METAL)       # roof vent
		_kit.box(Vector3(vx, ridge + 1.2, 0), Vector3(3.4, 0.3, 2.8), METAL_DK)
	_emit(false)

	_build_intake_facade(door_z)
	_build_ramp(door_z)
	_build_signage()


## The unmissable input point: a hazard-striped portal around the door and a big steel intake
## hopper right inside it, so it is obvious where the horse goes.
func _build_intake_facade(door_z: float) -> void:
	var hx := WIDTH_X * 0.5
	_kit.begin()
	# Hazard frame around the doorway.
	_kit.box(Vector3(-hx - 0.3, DOOR_H + 0.3, door_z), Vector3(0.8, 0.8, DOOR_W + 1.2), HAZARD)
	for dz in [door_z - DOOR_W * 0.5 - 0.3, door_z + DOOR_W * 0.5 + 0.3]:
		_kit.box(Vector3(-hx - 0.3, DOOR_H * 0.5 + 0.3, dz), Vector3(0.8, DOOR_H + 0.6, 0.8), HAZARD)
	_emit(false)


## A wedge threshold from the ground outside up to the floor, laid out long and shallow with
## no vertical lip, so the capsule walks straight up it instead of snagging. It overlaps onto
## the slab and runs a little wider than the door so you cannot walk off its side into the jamb.
func _build_ramp(door_z: float) -> void:
	var hx := WIDTH_X * 0.5
	var x_out := -hx - _ramp_len
	var x_in := -hx + 1.2                       # overlaps onto the floor slab
	var y_out := minf(_ground_out_y, 0.0) - 0.02
	var y_base := y_out - 1.0
	var hw := DOOR_W * 0.5 + 1.5                 # wider than the door
	var zc := door_z
	_kit.begin()
	var t0 := Vector3(x_out, y_out, zc - hw)
	var t1 := Vector3(x_out, y_out, zc + hw)
	var t2 := Vector3(x_in, 0.0, zc + hw)
	var t3 := Vector3(x_in, 0.0, zc - hw)
	_kit.quad(t0, t1, t2, t3, RAMP)                                   # sloped top
	var b0 := Vector3(x_out, y_base, zc - hw)
	var b1 := Vector3(x_out, y_base, zc + hw)
	var b2 := Vector3(x_in, y_base, zc + hw)
	var b3 := Vector3(x_in, y_base, zc - hw)
	_kit.quad(b3, b2, b1, b0, RAMP.darkened(0.35))                    # bottom
	_kit.quad(t0, t3, b3, b0, RAMP.darkened(0.15))                    # -Z side
	_kit.quad(t2, t1, b1, b2, RAMP.darkened(0.15))                    # +Z side
	_kit.quad(t1, t0, b0, b1, RAMP.darkened(0.2))                     # low end
	# Kerb rails so it reads as a loading ramp (kept low and outside the walk surface).
	_kit.box(Vector3((x_out + x_in) * 0.5, y_out * 0.5 + 0.1, zc - hw), Vector3(_ramp_len, 0.3, 0.3), HAZARD)
	_kit.box(Vector3((x_out + x_in) * 0.5, y_out * 0.5 + 0.1, zc + hw), Vector3(_ramp_len, 0.3, 0.3), HAZARD)
	_emit(true)


## A rooftop sign and a dock placard, so the works reads as a place and the dock as the spot
## the finished glue leaves from.
func _build_signage() -> void:
	var hx := WIDTH_X * 0.5
	_kit.begin()
	# Big rooftop letters block over the door end.
	_kit.box(Vector3(-hx + 6.0, WALL_H + 5.0, 0), Vector3(1.0, 3.0, 22.0), DARK)
	_kit.box(Vector3(-hx + 5.4, WALL_H + 5.0, 0), Vector3(0.4, 2.2, 20.0), HAZARD)
	_emit(false)


func _build_lights() -> void:
	# A grid of unshadowed omnis so the big hall reads under its roof. Shadowless on purpose —
	# shadow maps are the single most expensive thing in this game's frame (see the README).
	for x in [-42.0, -21.0, 0.0, 21.0, 42.0]:
		for z in [-14.0, 14.0]:
			var light := OmniLight3D.new()
			light.position = Vector3(x, WALL_H - 1.0, z)
			light.omni_range = 26.0
			light.light_energy = 1.9
			light.shadow_enabled = false
			add_child(light)


# ---- belt nodes -------------------------------------------------------------

## Builds the ordered node list the products walk: a lead-in from the door, each machine on its
## row in travel order, and the U-turn corners between rows, ending at the dock lead-out.
func _build_nodes() -> void:
	var mi := 0
	# Lead-in stub from the door to the first machine.
	_nodes.append({"pos": Vector3(-WIDTH_X * 0.5 + 4.0, ITEM_Y, ROW_Z[0]), "machine": -1})
	for r in ROW_Z.size():
		var z: float = ROW_Z[r]
		var dir := 1.0 if (r % 2 == 0) else -1.0
		var xs: Array = ROW_XS[r]
		for k in xs.size():
			var mx: float = xs[k]
			_machines.append({
				"busy": false, "name": MACHINE_NAMES[mi], "kind": MACHINE_KIND[mi],
				"index": mi, "center": Vector3(mx, 0.0, z), "node": _nodes.size(),
			})
			_nodes.append({"pos": Vector3(mx, ITEM_Y, z), "machine": mi})
			mi += 1
		# U-turn to the next row, unless this is the last row.
		if r < ROW_Z.size() - 1:
			var tx := TURN_X * dir
			_nodes.append({"pos": Vector3(tx, ITEM_Y, z), "machine": -1})
			_nodes.append({"pos": Vector3(tx, ITEM_Y, ROW_Z[r + 1]), "machine": -1})
	# Lead-out to the dock.
	_nodes.append({"pos": Vector3(-WIDTH_X * 0.5 + 6.0, ITEM_Y, ROW_Z[ROW_Z.size() - 1]), "machine": -1})


# ---- machines ---------------------------------------------------------------

func _band(index: int) -> Color:
	if index <= 3:
		return BAND_CORAL
	if index <= 10:
		return BAND_TEAL
	return BAND_AMBER


func _build_machines() -> void:
	for m in _machines:
		var mx: float = (m["center"] as Vector3).x
		var mz: float = (m["center"] as Vector3).z
		var band := _band(int(m["index"]))
		_kit.begin()
		# Shared plinth with a chamfered base and anchor bolts.
		_kit.box(Vector3(mx, 0.35, mz), Vector3(5.4, 0.7, 5.4), DARK)
		_kit.box(Vector3(mx, 0.72, mz), Vector3(4.8, 0.1, 4.8), METAL_DK)
		for bx in [-2.2, 2.2]:
			for bz in [-2.2, 2.2]:
				_kit.box(Vector3(mx + bx, 0.75, mz + bz), Vector3(0.35, 0.2, 0.35), METAL)
		match String(m["kind"]):
			"grinder": _m_grinder(mx, mz, band)
			"crusher": _m_crusher(mx, mz, band)
			"cooker": _m_cooker(mx, mz, band)
			"tank": _m_tank(mx, mz, band)
			"column": _m_column(mx, mz, band)
			"press": _m_press(mx, mz, band)
			"extruder": _m_extruder(mx, mz, band)
			"tunnel": _m_tunnel(mx, mz, band)
			"mill": _m_mill(mx, mz, band)
			"bagger": _m_bagger(mx, mz, band)
		_emit(true)


# ---- greeble helpers --------------------------------------------------------

## A drive motor: finned body, end bell and a stub shaft. Reads as the thing that turns a machine.
func _motor(at: Vector3, size: float, color: Color) -> void:
	_kit.cylinder(at, size * 0.5, size * 1.3, 8, color)
	_kit.disk(at + Vector3(0, size * 0.65, 0), size * 0.52, 8, color.lightened(0.06))
	for k in 6:
		var a := TAU * float(k) / 6.0
		var off := Vector3(cos(a), 0, sin(a)) * size * 0.55
		_kit.box(at + off, Vector3(0.08, size * 1.2, 0.08), color.darkened(0.15))   # cooling fin
	_kit.cylinder(at + Vector3(0, -size * 0.8, 0), size * 0.16, size * 0.5, 6, METAL)  # shaft


## A dial gauge mounted on the +X face of a body at `at`: a shallow housing, a pale face and a
## red needle. Kept as boxes so it reads cleanly at any angle without a fiddly oriented disk.
func _gauge(at: Vector3, r: float) -> void:
	_kit.box(at, Vector3(0.12, r * 2.0, r * 2.0), METAL_DK)
	_kit.box(at + Vector3(0.07, 0, 0), Vector3(0.05, r * 1.7, r * 1.7), Color(0.9, 0.9, 0.84))
	_kit.box(at + Vector3(0.11, r * 0.4, r * 0.25), Vector3(0.03, r * 1.1, 0.05), Color(0.72, 0.1, 0.1))


## A hand valve wheel — a torus rim with spokes and a hub — on top of a short riser.
func _valve_wheel(at: Vector3, r: float, color: Color) -> void:
	_kit.torus(at, r, r * 0.16, 8, 5, color)
	_kit.cylinder(at, r * 0.14, r * 0.4, 6, METAL)
	for k in 3:
		var a := PI * float(k) / 3.0
		_kit.pipe(at + Vector3(cos(a) * r, 0, sin(a) * r), at + Vector3(-cos(a) * r, 0, -sin(a) * r), r * 0.05, 4, color.darkened(0.1))


## A ladder + rungs up the side of a tall body from `base` up `height`, on the +X side offset dx.
func _ladder(base: Vector3, height: float, color: Color) -> void:
	_kit.pipe(base + Vector3(0, 0, -0.35), base + Vector3(0, height, -0.35), 0.06, 5, color)
	_kit.pipe(base + Vector3(0, 0, 0.35), base + Vector3(0, height, 0.35), 0.06, 5, color)
	var rungs := int(height / 0.5)
	for k in rungs:
		var y := 0.4 + float(k) * 0.5
		_kit.pipe(base + Vector3(0, y, -0.35), base + Vector3(0, y, 0.35), 0.04, 4, color.lightened(0.05))


## A run of pipe through a list of points, with a sphere elbow at each interior joint.
func _pipe_run(points: Array, r: float, color: Color) -> void:
	for k in points.size() - 1:
		_kit.pipe(points[k], points[k + 1], r, 6, color)
	for k in range(1, points.size() - 1):
		_kit.sphere(points[k], r * 1.25, 3, 5, color.lightened(0.05))


## A flange ring of bolt cubes around a rim.
func _flange(center: Vector3, radius: float, count: int, color: Color) -> void:
	for k in count:
		var a := TAU * float(k) / float(count)
		_kit.box(center + Vector3(cos(a) * radius, 0, sin(a) * radius), Vector3(0.14, 0.16, 0.14), color)


## A wall/side control panel with indicator lights.
func _control_panel(at: Vector3, color: Color) -> void:
	_kit.box(at, Vector3(0.3, 1.2, 1.6), METAL_DK)
	for k in 3:
		var lz := -0.5 + float(k) * 0.5
		var lit: Color = [Color(0.2, 0.8, 0.3), Color(0.85, 0.7, 0.15), Color(0.85, 0.2, 0.2)][k]
		_kit.box(at + Vector3(0.18, 0.35, lz), Vector3(0.06, 0.16, 0.16), lit)
	_kit.box(at + Vector3(0.18, -0.2, 0), Vector3(0.06, 0.3, 1.0), Color(0.12, 0.12, 0.14))


func _add_spinner(pivot: Vector3, mesh: ArrayMesh, speed: float) -> void:
	if mesh == null:
		return
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _mat
	node.position = pivot
	add_child(node)
	_spinners.append({"node": node, "speed": speed})


# ---- machine archetypes -----------------------------------------------------

func _m_grinder(mx: float, mz: float, band: Color) -> void:
	# A big custom meat grinder: a wide intake hopper you drop the horse into, a heavy geared
	# body, a screw auger, and a spout that feeds the belt. Fully modelled, no imported mesh.
	# Intake hopper (inverted pyramid) — the marked input point.
	var top := 4.2
	var mouth := 2.4
	var hy := 3.0
	var ry := 5.4
	for i in 4:
		var a0 := PI * 0.5 * float(i)
		var a1 := PI * 0.5 * float(i + 1)
		var c0 := Vector3(cos(a0), 0, sin(a0))
		var c1 := Vector3(cos(a1), 0, sin(a1))
		var base := Vector3(mx, hy, mz)
		var t0 := base + c0 * top * 0.7071 + Vector3(0, ry - hy, 0)
		var t1 := base + c1 * top * 0.7071 + Vector3(0, ry - hy, 0)
		var m0 := base + c0 * mouth * 0.7071
		var m1 := base + c1 * mouth * 0.7071
		_kit.quad(t0, t1, m1, m0, RUST.lightened(0.05 * (i % 2)))
	# Hazard rim around the hopper mouth so the input reads at a glance.
	_kit.torus(Vector3(mx, ry, mz), top * 0.72, 0.2, 12, 5, HAZARD)
	# Heavy grinder body under the hopper.
	_kit.box(Vector3(mx, 1.9, mz), Vector3(4.2, 2.4, 3.2), METAL_DK)
	_kit.cylinder(Vector3(mx, 1.9, mz), 1.7, 3.2, 12, METAL)
	_flange(Vector3(mx, 3.5, mz), 1.7, 12, DARK)
	# Output throat + spout onto the belt.
	_kit.cylinder(Vector3(mx, 1.1, mz), 0.9, 1.4, 8, METAL)
	_kit.cone(Vector3(mx, 0.4, mz), 0.9, 0.7, 8, METAL_DK)
	# Drive train: a big motor and a reduction gearbox with an exposed gear.
	_motor(Vector3(mx - 2.6, 2.4, mz + 1.4), 1.0, band)
	_kit.box(Vector3(mx - 2.4, 1.6, mz - 1.4), Vector3(1.4, 1.4, 1.2), METAL_DK)
	_kit.torus(Vector3(mx - 2.4, 2.4, mz - 1.4), 0.7, 0.16, 12, 5, METAL)
	_gauge(Vector3(mx + 2.15, 2.4, mz), 0.4)
	_control_panel(Vector3(mx + 2.4, 1.6, mz + 1.6), band)
	# The auger screw, spinning inside the throat (a helix approximated by a twisted blade set).
	var screw := _screw_mesh(band)
	_add_spinner(Vector3(mx, 1.9, mz), screw, 4.5)


func _m_crusher(mx: float, mz: float, band: Color) -> void:
	# Bone separator: a ribbed drum between end bearings, fed from a chute, driven by a belt.
	_kit.box(Vector3(mx, 1.6, mz), Vector3(4.6, 2.2, 3.6), band)
	for ex in [-2.1, 2.1]:
		_kit.cylinder(Vector3(mx + ex, 2.6, mz), 0.6, 0.6, 8, METAL_DK)   # bearing block
	var drum := _drum_mesh(1.0, 3.0, band.darkened(0.1))
	var sp := MeshInstance3D.new()
	sp.mesh = drum
	sp.material_override = _mat
	sp.position = Vector3(mx, 2.6, mz)
	sp.rotation.z = PI * 0.5
	add_child(sp)
	_spinners.append({"node": sp, "speed": 3.0})
	# Feed chute and discharge grate.
	_kit.box(Vector3(mx, 3.4, mz - 1.0), Vector3(2.0, 1.0, 1.4), METAL_DK)
	_kit.box(Vector3(mx, 0.9, mz), Vector3(3.6, 0.2, 2.2), DARK)
	_motor(Vector3(mx - 2.4, 1.6, mz + 1.6), 0.9, METAL)
	_gauge(Vector3(mx + 2.35, 2.0, mz + 1.0), 0.35)


func _m_cooker(mx: float, mz: float, band: Color) -> void:
	# Renderer: a jacketed cooking vessel with a domed lid, a steam stack and a condenser line.
	_kit.cylinder(Vector3(mx, 2.4, mz), 1.9, 3.6, 14, band)
	_flange(Vector3(mx, 0.7, mz), 1.9, 14, METAL_DK)
	_kit.sphere(Vector3(mx, 4.2, mz), 1.9, 3, 12, band.darkened(0.1))    # domed lid
	_kit.disk(Vector3(mx, 4.3, mz), 0.6, 8, METAL)                        # manway
	_kit.pipe(Vector3(mx + 1.2, 4.3, mz), Vector3(mx + 1.2, 8.0, mz), 0.22, 8, METAL)   # steam stack
	_kit.torus(Vector3(mx + 1.2, 8.0, mz), 0.3, 0.1, 8, 5, METAL_DK)
	_pipe_run([Vector3(mx - 1.9, 3.4, mz), Vector3(mx - 2.6, 3.4, mz), Vector3(mx - 2.6, 0.9, mz)], 0.14, METAL)
	_ladder(Vector3(mx, 0.7, mz + 2.0), 3.4, METAL_DK)
	_valve_wheel(Vector3(mx - 2.6, 1.2, mz), 0.5, band)
	_gauge(Vector3(mx + 1.95, 3.0, mz - 0.8), 0.4)
	# Byproduct/steam stirrer paddle on top.
	_add_spinner(Vector3(mx, 4.2, mz), _paddle_mesh(band), 1.5)


func _m_tank(mx: float, mz: float, band: Color) -> void:
	# Stirred process tank: cylindrical vessel, conical bottom, rim rail, a stirrer mast with a
	# motor, valve wheels and a sight glass. Used for soak / wash / clarify / degrease stages.
	_kit.cylinder(Vector3(mx, 2.2, mz), 1.95, 3.2, 14, band)
	_kit.cone(Vector3(mx, 0.4, mz), 1.95, -1.0, 14, band.darkened(0.12))   # coned bottom (apex down)
	_kit.torus(Vector3(mx, 3.85, mz), 1.98, 0.12, 16, 5, METAL)            # rim rail
	_kit.disk(Vector3(mx, 3.85, mz), 1.9, 14, band.lightened(0.05))
	# Sight glass strip.
	_kit.box(Vector3(mx + 1.9, 2.2, mz), Vector3(0.12, 2.4, 0.5), GLASS)
	# Stirrer: mast + motor on a bridge; the paddle spins.
	_kit.box(Vector3(mx, 4.4, mz), Vector3(4.0, 0.3, 0.5), METAL_DK)       # bridge
	_motor(Vector3(mx, 4.9, mz), 0.7, band.darkened(0.1))
	_add_spinner(Vector3(mx, 2.4, mz), _paddle_mesh(METAL), 2.4)
	_valve_wheel(Vector3(mx - 2.0, 1.0, mz + 1.0), 0.45, band)
	_pipe_run([Vector3(mx, 0.2, mz), Vector3(mx + 2.4, 0.2, mz), Vector3(mx + 2.4, 1.4, mz)], 0.13, METAL)
	_gauge(Vector3(mx + 1.97, 3.2, mz - 0.9), 0.38)
	_control_panel(Vector3(mx - 2.6, 1.6, mz - 1.4), band)


func _m_column(mx: float, mz: float, band: Color) -> void:
	# Tall column: extraction / evaporator / concentrator. A slim tall vessel with tray flanges,
	# a top head, a reboiler at the base, a condenser return line and a full-height ladder+cage.
	_kit.cylinder(Vector3(mx, 4.0, mz), 1.2, 7.0, 12, band)
	for k in 5:
		_kit.torus(Vector3(mx, 1.6 + float(k) * 1.3, mz), 1.24, 0.1, 12, 5, METAL)   # tray flanges
	_kit.sphere(Vector3(mx, 7.6, mz), 1.2, 3, 12, band.darkened(0.1))     # top head
	_kit.box(Vector3(mx, 1.0, mz), Vector3(2.6, 1.2, 2.6), METAL_DK)      # reboiler skirt
	_pipe_run([Vector3(mx + 1.2, 7.2, mz), Vector3(mx + 2.4, 7.2, mz), Vector3(mx + 2.4, 1.2, mz), Vector3(mx + 1.4, 1.2, mz)], 0.15, METAL)
	_ladder(Vector3(mx - 1.2, 1.2, mz), 6.6, METAL_DK)
	_valve_wheel(Vector3(mx + 1.4, 2.2, mz + 1.2), 0.4, band)
	_gauge(Vector3(mx + 1.25, 4.5, mz - 0.7), 0.36)
	_flange(Vector3(mx, 0.5, mz), 1.3, 12, DARK)


func _m_press(mx: float, mz: float, band: Color) -> void:
	# Plate-and-frame filter press: two heavy end frames, a stack of plates squeezed between on
	# tie-bars, a hydraulic ram at one end and drip trays below.
	for ex in [-2.2, 2.2]:
		_kit.box(Vector3(mx + ex, 2.0, mz), Vector3(0.5, 3.4, 3.6), METAL_DK)
	for tb in [1.4, -1.4]:
		_kit.pipe(Vector3(mx - 2.2, 2.0 + tb, mz), Vector3(mx + 2.2, 2.0 + tb, mz), 0.12, 6, METAL)  # tie-bar
	for i in 11:
		var x := mx - 1.7 + float(i) * 0.34
		_kit.box(Vector3(x, 2.0, mz), Vector3(0.22, 3.0, 3.0), band.darkened(0.05 * (i % 2)))
		_kit.box(Vector3(x, 2.0, mz + 1.55), Vector3(0.18, 2.6, 0.12), METAL)   # plate handle rib
	_kit.cylinder(Vector3(mx - 3.0, 2.0, mz), 0.5, 0.8, 8, band)          # hydraulic ram
	_kit.pipe(Vector3(mx - 3.0, 2.0, mz), Vector3(mx - 2.2, 2.0, mz), 0.25, 8, METAL)
	_kit.box(Vector3(mx, 0.7, mz), Vector3(4.4, 0.15, 2.0), DARK)         # drip tray
	_gauge(Vector3(mx - 3.05, 2.6, mz), 0.35)


func _m_extruder(mx: float, mz: float, band: Color) -> void:
	# Chill extruder: a jacketed chiller block, a die head with many noodle strands hanging, and
	# a screw drive. The strands are the gelled-noodle stream made visible.
	_kit.box(Vector3(mx, 2.0, mz), Vector3(3.4, 2.8, 3.2), band)
	_kit.box(Vector3(mx, 3.6, mz), Vector3(2.6, 0.6, 2.6), METAL_DK)      # coolant manifold
	for cz in [-0.9, 0.0, 0.9]:
		_kit.pipe(Vector3(mx - 1.7, 3.6, mz + cz), Vector3(mx - 2.6, 3.6, mz + cz), 0.1, 5, METAL)
	# Die head + hanging noodles.
	var head := Vector3(mx + 2.1, 1.9, mz)
	_kit.box(head, Vector3(1.2, 1.6, 2.6), METAL)
	for i in 9:
		var z := -1.0 + float(i) * 0.25
		_kit.pipe(Vector3(head.x + 0.6, 1.6, mz + z), Vector3(head.x + 0.6, 0.9, mz + z), 0.05, 4, _stream_color(11))
	_motor(Vector3(mx - 2.2, 2.4, mz + 1.4), 0.9, band.darkened(0.1))
	_kit.torus(Vector3(mx - 1.7, 2.0, mz), 0.6, 0.14, 10, 5, METAL)       # drive sheave
	_gauge(Vector3(mx + 1.75, 2.6, mz - 1.0), 0.35)


func _m_tunnel(mx: float, mz: float, band: Color) -> void:
	# Drying tunnel: a long insulated box the belt runs through, ribbed with expansion bands,
	# dark mouths at each end, roof blowers and a duct.
	_kit.box(Vector3(mx, 1.8, mz), Vector3(5.2, 2.6, 3.2), band)
	for k in 5:
		_kit.box(Vector3(mx - 2.0 + float(k) * 1.0, 1.8, mz), Vector3(0.12, 2.7, 3.3), band.darkened(0.08))  # ribs
	_kit.box(Vector3(mx, 1.1, mz), Vector3(5.4, 0.18, 1.5), DARK)         # belt line through it
	for ex in [-2.6, 2.6]:
		_kit.box(Vector3(mx + ex, 1.3, mz), Vector3(0.12, 1.2, 1.8), Color(0.08, 0.08, 0.1))  # dark mouth
	for bx in [-1.4, 1.4]:
		_kit.box(Vector3(mx + bx, 3.4, mz), Vector3(1.2, 0.9, 1.6), METAL)   # roof blower
		_kit.disk(Vector3(mx + bx, 3.9, mz), 0.5, 8, METAL_DK)
	_pipe_run([Vector3(mx - 1.4, 3.85, mz), Vector3(mx + 1.4, 3.85, mz)], 0.2, METAL_DK)
	_control_panel(Vector3(mx + 2.7, 1.6, mz + 1.4), band)


func _m_mill(mx: float, mz: float, band: Color) -> void:
	# Hammer mill: a squat armoured body with a heavy driven drum, an inlet throat, a screened
	# discharge and a big flywheel driven by a belt off the motor.
	_kit.box(Vector3(mx, 1.7, mz), Vector3(3.2, 2.6, 3.0), band)
	_kit.cylinder(Vector3(mx, 2.6, mz), 1.4, 2.2, 12, band.darkened(0.08))
	_kit.box(Vector3(mx, 3.4, mz), Vector3(1.4, 0.9, 1.4), METAL_DK)      # inlet throat
	_kit.box(Vector3(mx + 1.7, 1.1, mz), Vector3(1.0, 1.0, 1.2), METAL)   # discharge
	# Flywheel on the +Z face + motor + drive belt.
	var fly := MeshInstance3D.new()
	fly.mesh = _flywheel_mesh(band)
	fly.material_override = _mat
	fly.position = Vector3(mx, 2.6, mz + 1.7)
	fly.rotation.x = PI * 0.5
	add_child(fly)
	_spinners.append({"node": fly, "speed": 5.0})
	_motor(Vector3(mx - 1.9, 1.4, mz + 1.9), 0.9, METAL)
	_kit.pipe(Vector3(mx - 1.9, 2.0, mz + 1.9), Vector3(mx, 2.6, mz + 1.9), 0.06, 5, DARK)  # drive belt
	_gauge(Vector3(mx + 1.65, 2.4, mz - 0.8), 0.34)


func _m_bagger(mx: float, mz: float, band: Color) -> void:
	# Bagging & pack: a surge hopper, a weigh head, a fill chute and a little roller table where
	# the tied sacks come off — the end of the line, feeding the dock.
	_kit.box(Vector3(mx, 2.6, mz), Vector3(2.6, 3.0, 2.6), band)
	_kit.cone(Vector3(mx, 4.1, mz), 1.6, 1.0, 8, band.darkened(0.1))      # surge hopper top
	_kit.box(Vector3(mx, 1.0, mz), Vector3(1.2, 1.0, 1.2), METAL)         # weigh head
	_kit.cylinder(Vector3(mx, 0.5, mz), 0.5, 0.8, 8, METAL_DK)            # fill chute
	# Roller table out the +X side toward the dock.
	_kit.box(Vector3(mx + 2.2, 0.9, mz), Vector3(2.0, 0.2, 1.4), METAL_DK)
	for k in 5:
		_kit.pipe(Vector3(mx + 1.4 + float(k) * 0.4, 1.0, mz - 0.7), Vector3(mx + 1.4 + float(k) * 0.4, 1.0, mz + 0.7), 0.08, 6, METAL)
	_control_panel(Vector3(mx - 1.6, 1.6, mz + 1.6), band)
	_gauge(Vector3(mx + 1.35, 2.6, mz), 0.36)


# ---- spinner sub-meshes -----------------------------------------------------

func _screw_mesh(color: Color) -> ArrayMesh:
	# A crude auger: a central shaft with blades set at rising angles, so it reads as a screw
	# when it spins. Uses _sub so it does not disturb the machine mesh mid-build.
	_sub.begin()
	_sub.cylinder(Vector3.ZERO, 0.25, 2.6, 6, METAL)
	for k in 8:
		var y := -1.1 + float(k) * 0.3
		var a := float(k) * 0.8
		var blade := Vector3(cos(a), 0, sin(a)) * 1.3
		_sub.box(Vector3(blade.x * 0.5, y, blade.z * 0.5), Vector3(1.3, 0.08, 0.5), color.lightened(0.05))
	return _sub.commit()


func _paddle_mesh(color: Color) -> ArrayMesh:
	_sub.begin()
	_sub.pipe(Vector3(0, -0.8, 0), Vector3(0, 0.8, 0), 0.12, 6, METAL)   # shaft
	for k in 2:
		var a := PI * float(k)
		_sub.box(Vector3(cos(a) * 0.8, -0.6, sin(a) * 0.8), Vector3(1.5, 0.5, 0.16), color.darkened(0.08))
	return _sub.commit()


func _drum_mesh(radius: float, length: float, color: Color) -> ArrayMesh:
	# A ribbed drum, built lying along Y (the caller rotates it onto its axis).
	_sub.begin()
	_sub.cylinder(Vector3.ZERO, radius, length, 12, color)
	for k in 8:
		var a := TAU * float(k) / 8.0
		var off := Vector3(cos(a), 0, sin(a)) * radius
		_sub.box(Vector3(off.x, 0, off.z), Vector3(0.14, length, 0.14), color.lightened(0.08))  # rib
	return _sub.commit()


func _flywheel_mesh(color: Color) -> ArrayMesh:
	_sub.begin()
	_sub.torus(Vector3.ZERO, 1.2, 0.2, 14, 6, color.darkened(0.1))
	_sub.cylinder(Vector3.ZERO, 0.25, 0.3, 8, METAL)
	for k in 4:
		var a := PI * 0.5 * float(k)
		_sub.pipe(Vector3.ZERO, Vector3(cos(a), 0, sin(a)) * 1.15, 0.08, 4, METAL_DK)  # spoke
	return _sub.commit()


# ---- conveyors --------------------------------------------------------------

func _build_conveyors() -> void:
	_kit.begin()
	for i in _nodes.size() - 1:
		_belt(_nodes[i]["pos"], _nodes[i + 1]["pos"])
	_emit(true)


## A conveyor run between two belt points: a slatted belt slab on a frame with legs, side rails,
## and rollers across it. Extended a touch past each end so the switchback corners fill in.
func _belt(from: Vector3, to: Vector3) -> void:
	var mid := (from + to) * 0.5
	var span := to - from
	var length := Vector2(span.x, span.z).length()
	if length < 0.2:
		return
	var horizontal := absf(span.x) >= absf(span.z)
	var pad := 1.4
	var belt_size := Vector3(length + pad, 0.18, 1.4) if horizontal else Vector3(1.4, 0.18, length + pad)
	_kit.box(Vector3(mid.x, ITEM_Y - 0.28, mid.z), belt_size, DARK)
	var frame_size := Vector3(length + pad, 0.5, 1.7) if horizontal else Vector3(1.7, 0.5, length + pad)
	_kit.box(Vector3(mid.x, ITEM_Y - 0.6, mid.z), frame_size, METAL_DK)
	# Side rails.
	var rail_off := Vector3(0, ITEM_Y - 0.15, 0.75) if horizontal else Vector3(0.75, ITEM_Y - 0.15, 0)
	var rail_size := Vector3(length + pad, 0.12, 0.12) if horizontal else Vector3(0.12, 0.12, length + pad)
	_kit.box(Vector3(mid.x, 0, mid.z) + rail_off, rail_size, METAL)
	_kit.box(Vector3(mid.x, 0, mid.z) - rail_off + Vector3(0, ITEM_Y - 0.15, 0), rail_size, METAL)
	# Rollers across the belt.
	var rollers := int(length / 1.2)
	for k in rollers:
		var t := (float(k) + 0.5) / float(maxi(rollers, 1))
		var p := from.lerp(to, t)
		if horizontal:
			_kit.pipe(Vector3(p.x, ITEM_Y - 0.18, p.z - 0.7), Vector3(p.x, ITEM_Y - 0.18, p.z + 0.7), 0.09, 6, METAL)
		else:
			_kit.pipe(Vector3(p.x - 0.7, ITEM_Y - 0.18, p.z), Vector3(p.x + 0.7, ITEM_Y - 0.18, p.z), 0.09, 6, METAL)
	# Legs.
	for t in [0.15, 0.85]:
		var leg := from.lerp(to, t)
		_kit.box(Vector3(leg.x, (ITEM_Y - 0.85) * 0.5, leg.z), Vector3(0.26, ITEM_Y - 0.85, 0.26), METAL_DK)


# ---- gore -------------------------------------------------------------------

## Tons of blood and gore at the grinder mouth: a fine crimson spray plus coarser dark chunks,
## both erupting from the intake and raining onto the belt below. CPUParticles so it renders
## reliably under the Compatibility renderer.
func _build_gore() -> void:
	var mouth: Vector3 = (_machines[0]["center"] as Vector3) + Vector3(0, 4.6, 0)

	# Fine blood spray — lots of small bright particles, arcing out and falling.
	var spray := CPUParticles3D.new()
	spray.position = mouth
	spray.amount = 260
	spray.lifetime = 1.6
	spray.mesh = _gore_particle_mesh(0.09, BLOOD.lightened(0.05))
	spray.material_override = _particle_mat()
	spray.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	spray.emission_sphere_radius = 1.1
	spray.direction = Vector3(0, 1, 0)
	spray.spread = 55.0
	spray.gravity = Vector3(0, -12.0, 0)
	spray.initial_velocity_min = 3.0
	spray.initial_velocity_max = 8.0
	spray.scale_amount_min = 0.6
	spray.scale_amount_max = 1.6
	spray.color = GORE
	_apply_gore_ramp(spray, BLOOD)
	add_child(spray)

	# Coarser gore chunks — fewer, bigger, darker, tumbling.
	var chunks := CPUParticles3D.new()
	chunks.position = mouth
	chunks.amount = 90
	chunks.lifetime = 2.0
	chunks.mesh = _gore_particle_mesh(0.22, GORE.darkened(0.15))
	chunks.material_override = _particle_mat()
	chunks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	chunks.emission_sphere_radius = 0.9
	chunks.direction = Vector3(0, 1, 0)
	chunks.spread = 42.0
	chunks.gravity = Vector3(0, -14.0, 0)
	chunks.initial_velocity_min = 2.0
	chunks.initial_velocity_max = 6.0
	chunks.angular_velocity_min = -360.0
	chunks.angular_velocity_max = 360.0
	chunks.scale_amount_min = 0.7
	chunks.scale_amount_max = 2.0
	chunks.color = GORE.darkened(0.1)
	_apply_gore_ramp(chunks, GORE.darkened(0.2))
	add_child(chunks)

	# A slow, constant drip down the grinder throat onto the belt.
	var drip := CPUParticles3D.new()
	drip.position = _machines[0]["center"] + Vector3(0, 1.4, 0)
	drip.amount = 40
	drip.lifetime = 1.4
	drip.mesh = _gore_particle_mesh(0.07, BLOOD)
	drip.material_override = _particle_mat()
	drip.direction = Vector3(0, -1, 0)
	drip.spread = 12.0
	drip.gravity = Vector3(0, -16.0, 0)
	drip.initial_velocity_min = 0.5
	drip.initial_velocity_max = 1.5
	drip.color = BLOOD
	add_child(drip)


func _gore_particle_mesh(size: float, color: Color) -> ArrayMesh:
	_sub.begin()
	_sub.box(Vector3.ZERO, Vector3(size, size, size * 1.4), color)
	return _sub.commit()


func _particle_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_is_srgb = false
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _apply_gore_ramp(p: CPUParticles3D, base: Color) -> void:
	var ramp := Gradient.new()
	ramp.set_color(0, base.lightened(0.1))
	ramp.set_color(1, base.darkened(0.4))
	ramp.add_point(0.7, base)
	p.color_ramp = ramp


# ---- emit -------------------------------------------------------------------

## Commits the current MeshKit buffer as a child MeshInstance3D, optionally with a static
## trimesh body so the player cannot walk through it.
func _emit(collide: bool) -> MeshInstance3D:
	var mesh := _kit.commit()
	if mesh == null:
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	add_child(mi)
	if collide:
		var shape := mesh.create_trimesh_shape()
		if shape != null:
			var body := StaticBody3D.new()
			var col := CollisionShape3D.new()
			col.shape = shape
			body.add_child(col)
			mi.add_child(body)
	return mi
