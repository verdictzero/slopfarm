extends Node3D
class_name GlueFactory
## A player-traversable glue works standing just east of the farm, and the pipeline that
## runs inside it. Feed a knocked-out horse into the intake at the door end and it is carried
## down the line — grinder, renderer, chemistry soak, extraction, filtration, evaporator,
## chill-extruder, drying tunnel, mill — each machine transforming the stream and handing it
## to the next along a conveyor, until sacks of granulated glue stack on the pallet at the
## far end. The nine unit operations are the ones in glue_factory_pipeline_notes.txt.
##
## Everything is procedural, built the same way FarmBuilder builds the farm: one merged,
## vertex-coloured mesh per object through MeshKit, with a trimesh body off that same mesh so
## the machines and walls are solid. It sits ON the flat basin like every farm structure —
## the floor slab is a foundation that reaches below the ground, and a ramp at the door lifts
## the player the last few centimetres onto it.

# ---- placement --------------------------------------------------------------
## World centre. East of the authored farm — the horse pen ends at x≈129, so the door end
## here (x≈139) is right next to it, which is the whole point: knock a horse out by the pen
## and it is a short carry to the intake. Well inside the flat basin (radius ~215 < 380).
const CENTER := Vector3(175.0, 0.0, -15.0)

const WIDTH_X := 72.0        # long axis, the direction the pipeline runs
const DEPTH_Z := 26.0        # hall width; machines run down the centre, aisles either side
const WALL_H := 8.0
const WALL_T := 0.5
const DOOR_W := 8.0
const DOOR_H := 5.0
## The floor slab doubles as a foundation, reaching this far below the top surface so no
## daylight shows under the walls where the basin dips. Same idea as FarmBuilder's skirt.
const FOUNDATION_SINK := 2.5
const RAMP_LEN := 6.0

# ---- machines ---------------------------------------------------------------
const MACHINE_COUNT := 9
## Machines are laid along local X, evenly spaced, with the intake at the -X (door) end.
const MACHINE_X0 := -30.0
const MACHINE_DX := 7.5
## Where a product rides on the conveyor, and how far the inlet/outlet sit from a machine's
## centre along the line.
const ITEM_Y := 1.1
const MACHINE_REACH := 2.6

## Belt speed, metres/second, between machines and out to the pallet.
const CONVEYOR_SPEED := 3.2
## Seconds each machine holds a batch. Roughly tracks the notes — the wet stages (soak,
## extraction, evaporation) are the slow ones.
const PROCESS_TIME: Array[float] = [1.6, 2.2, 2.6, 3.0, 2.0, 3.0, 2.0, 3.0, 1.8]
const MACHINE_NAMES: Array[String] = [
	"grinder", "renderer", "chemistry soak", "extraction", "filter press",
	"evaporator", "chill-extruder", "drying tunnel", "mill and pack",
]

## How near the intake the player has to be, carrying a ragdoll, to feed it in.
const FEED_RADIUS := 5.5
## Cap on batches in flight, so a mob of feeds cannot spawn unbounded product nodes. Feeding
## while full is refused (the player keeps carrying).
const MAX_ACTIVE := 12
## Finished sacks cycle through this many pallet slots; the oldest is freed as new ones land.
const SACK_CAP := 24

# ---- palette ----------------------------------------------------------------
const FLOOR := Color(0.33, 0.33, 0.35)
const FLOOR_TOP := Color(0.40, 0.40, 0.43)
const WALL := Color(0.49, 0.49, 0.52)
const ROOF := Color(0.21, 0.21, 0.24)
const RAMP := Color(0.37, 0.36, 0.35)
const METAL := Color(0.50, 0.51, 0.54)
const DARK := Color(0.27, 0.27, 0.30)
# The notes' three phase bands: coral mechanical front end, teal wet chemistry, amber finish.
const BAND_CORAL := Color(0.72, 0.34, 0.27)
const BAND_TEAL := Color(0.24, 0.50, 0.50)
const BAND_AMBER := Color(0.72, 0.55, 0.24)
const TALLOW := Color(0.80, 0.74, 0.42)

## One colour per stream, 0..9, dark meat through to burlap. Baked into each stream's own
## little mesh as vertex colour, so a single material draws them all.
const STREAM_COLORS: Array[Color] = [
	Color(0.45, 0.16, 0.14),  # 0 whole/chunked horse (intake)
	Color(0.52, 0.22, 0.19),  # 1 ground particulate
	Color(0.62, 0.50, 0.47),  # 2 defatted solids
	Color(0.70, 0.72, 0.66),  # 3 conditioned (limed) matrix
	Color(0.66, 0.48, 0.22),  # 4 dilute gelatin liquor
	Color(0.76, 0.60, 0.28),  # 5 clarified liquor
	Color(0.50, 0.36, 0.16),  # 6 concentrated syrup
	Color(0.82, 0.74, 0.40),  # 7 gelled noodles
	Color(0.70, 0.55, 0.30),  # 8 dried gelatin
	Color(0.60, 0.50, 0.33),  # 9 sacked glue granules
]

var _terrain: TerrainManager
var _player: Node3D
var _kit := MeshKit.new()
var _mat: StandardMaterial3D

## Each: {center, inlet, outlet, busy, name}. inlet/outlet are local Vector3 on the belt.
var _machines: Array = []
var _stream_meshes: Array = []      # ArrayMesh per stream 0..9
var _tallow_mesh: ArrayMesh
var _batches: Array = []            # products in flight
var _byproducts: Array = []         # tallow drums sliding to the bin
var _sacks: Array = []              # parked finished sacks, cycled through SACK_CAP slots
var _sack_count := 0
var _spinners: Array = []           # {node, speed} — rotating machine parts
var _feed_world: Vector3
var _floor_y := 0.0
var _ground_out_y := 0.0            # local y of the ground just outside the door (for the ramp)
var _footprint := Rect2()


## Builds the whole works and wires it to the world. Call once from main.
func setup(terrain: TerrainManager, player: Node3D) -> void:
	_terrain = terrain
	_player = player

	# Floor sits at or above the highest ground under the footprint, so the terrain never
	# poked up through the slab; the door ramp makes up the small step to the ground outside.
	var highest := -1e9
	for sx in [-0.5, 0.0, 0.5]:
		for sz in [-0.5, 0.0, 0.5]:
			var wx := CENTER.x + sx * WIDTH_X
			var wz := CENTER.z + sz * DEPTH_Z
			highest = maxf(highest, terrain.height_at(wx, wz))
	_floor_y = highest + 0.05
	position = Vector3(CENTER.x, _floor_y, CENTER.z)
	_ground_out_y = terrain.height_at(CENTER.x - WIDTH_X * 0.5 - RAMP_LEN, CENTER.z) - _floor_y

	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 1.0
	_mat.metallic = 0.0
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_build_streams()
	_build_shell()
	_build_machines()
	_build_conveyors()
	_build_lights()

	_feed_world = to_global(_machines[0]["inlet"])
	_footprint = Rect2(CENTER.x - WIDTH_X * 0.5 - 1.0, CENTER.z - DEPTH_Z * 0.5 - 1.0,
			WIDTH_X + 2.0, DEPTH_Z + 2.0)
	add_to_group("glue_factory")


## The XZ rectangle the building covers, so TerrainGrass can keep grass off the slab.
func footprint() -> Rect2:
	return _footprint


## Feed a carried horse into the intake. True if it was accepted (the caller then consumes
## the ragdoll); false if too far from the intake or the line is full.
func try_feed(world_pos: Vector3) -> bool:
	if _machines.is_empty():
		return false
	if world_pos.distance_to(_feed_world) > FEED_RADIUS:
		return false
	if _active_count() >= MAX_ACTIVE:
		return false
	_spawn_batch()
	return true


func _active_count() -> int:
	return _batches.size()


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
	node.position = _machines[0]["inlet"]
	# stage = the stream it currently IS; machine = the machine it is heading to be worked by.
	_batches.append({
		"node": node, "stage": 0, "machine": 0, "state": "wait",
		"from": Vector3.ZERO, "to": Vector3.ZERO, "progress": 0.0, "timer": 0.0, "slot": 0,
	})


## Advances one batch. Returns true when it is finished and should be dropped from the list
## (its node lives on as a parked sack).
func _update_batch(b: Dictionary, dt: float) -> bool:
	match b["state"]:
		"wait":
			var m: Dictionary = _machines[b["machine"]]
			(b["node"] as Node3D).position = m["inlet"]
			(b["node"] as MeshInstance3D).visible = true
			if not m["busy"]:
				m["busy"] = true
				b["state"] = "process"
				b["timer"] = PROCESS_TIME[b["machine"]]
				# Hidden while inside the machine; it reappears, transformed, at the outlet.
				(b["node"] as MeshInstance3D).visible = false
			return false
		"process":
			b["timer"] -= dt
			if b["timer"] <= 0.0:
				var done: Dictionary = _machines[b["machine"]]
				done["busy"] = false
				b["stage"] = b["machine"] + 1
				(b["node"] as MeshInstance3D).mesh = _stream_meshes[b["stage"]]
				(b["node"] as Node3D).position = done["outlet"]
				(b["node"] as MeshInstance3D).visible = true
				if b["stage"] == 2:
					# Rendering throws off tallow as a byproduct — it leaves the glue line here.
					_spawn_tallow(done["outlet"])
				if b["stage"] <= 8:
					b["from"] = done["outlet"]
					b["machine"] = b["stage"]
					b["to"] = _machines[b["machine"]]["inlet"]
					b["progress"] = 0.0
					b["state"] = "move"
				else:
					b["from"] = done["outlet"]
					b["slot"] = _sack_count
					_sack_count += 1
					b["to"] = _sack_slot(b["slot"])
					b["progress"] = 0.0
					b["state"] = "output"
			return false
		"move":
			if _advance(b, dt):
				b["state"] = "wait"
			return false
		"output":
			if _advance(b, dt):
				_park_sack(b["node"], b["slot"])
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
	mover["progress"] += CONVEYOR_SPEED * dt / length
	var t := clampf(mover["progress"], 0.0, 1.0)
	(mover["node"] as Node3D).position = from.lerp(to, t)
	return mover["progress"] >= 1.0


func _spawn_tallow(at: Vector3) -> void:
	var node := MeshInstance3D.new()
	node.material_override = _mat
	node.mesh = _tallow_mesh
	add_child(node)
	node.position = at
	# Off to a bin on the -Z side by the renderer, then collected (freed) on arrival.
	var bin := Vector3(_machines[1]["center"].x, 0.6, -DEPTH_Z * 0.5 + 3.0)
	_byproducts.append({"node": node, "from": at, "to": bin, "progress": 0.0})


## Pallet slots, cycled through SACK_CAP positions. In the +Z aisle by the mill end, clear
## of the machine line (which runs down z≈0), so the growing stack does not clip a plinth.
func _sack_slot(index: int) -> Vector3:
	var i := index % SACK_CAP
	var col := i % 6
	var row := (i / 6) % 4
	var origin := Vector3(28.0, 0.45, 6.0)
	return origin + Vector3(float(col) * 0.9, 0.0, float(row) * 0.9)


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
	for i in STREAM_COLORS.size():
		_stream_meshes.append(_stream_mesh(i))
	_kit.begin()
	_kit.cylinder(Vector3(0, 0.35, 0), 0.4, 0.7, 8, TALLOW)
	_tallow_mesh = _kit.commit()


## A small item for one stream, centred on the origin so it can be positioned anywhere on the
## belt. The shape hints at the state of matter: lumps early, a pail of liquor through the wet
## middle, a gel loaf, brittle shards, and a tied sack at the end.
func _stream_mesh(stream: int) -> ArrayMesh:
	var c: Color = STREAM_COLORS[stream]
	_kit.begin()
	match stream:
		0:
			_kit.box(Vector3(0, 0.3, 0), Vector3(0.7, 0.6, 0.5), c)
		1, 2:
			_kit.box(Vector3(0, 0.2, 0), Vector3(0.6, 0.4, 0.6), c)
			_kit.box(Vector3(0.12, 0.42, -0.08), Vector3(0.28, 0.2, 0.24), c.lightened(0.1))
		3, 4, 5, 6:
			# A pail of liquor: a short can with a darker meniscus.
			_kit.cylinder(Vector3(0, 0.3, 0), 0.34, 0.6, 8, METAL.darkened(0.1))
			_kit.cylinder(Vector3(0, 0.58, 0), 0.3, 0.06, 8, c)
		7:
			# Gelled noodles: a soft loaf with ridges.
			_kit.box(Vector3(0, 0.22, 0), Vector3(0.6, 0.4, 0.5), c)
			for k in 3:
				_kit.rail(Vector3(-0.28, 0.44, -0.16 + k * 0.16),
						Vector3(0.28, 0.44, -0.16 + k * 0.16), 0.05, c.lightened(0.08))
		8:
			for k in 3:
				_kit.box(Vector3(-0.16 + k * 0.16, 0.16 + k * 0.04, 0),
						Vector3(0.24, 0.3, 0.4), c.darkened(0.05 * k))
		_:
			# A burlap sack: body plus a pinched, tied neck.
			_kit.box(Vector3(0, 0.35, 0), Vector3(0.6, 0.7, 0.46), c)
			_kit.box(Vector3(0, 0.74, 0), Vector3(0.34, 0.18, 0.28), c.darkened(0.18))
	return _kit.commit()


# ---- building shell ---------------------------------------------------------

func _build_shell() -> void:
	# Floor + foundation.
	_kit.begin()
	_kit.box(Vector3(0, -FOUNDATION_SINK * 0.5, 0), Vector3(WIDTH_X, FOUNDATION_SINK, DEPTH_Z), FLOOR)
	_kit.box(Vector3(0, -0.05, 0), Vector3(WIDTH_X, 0.1, DEPTH_Z), FLOOR_TOP)
	_emit(true)

	# Walls, as one mesh + one body. -X wall is split around the doorway.
	_kit.begin()
	var wy := (WALL_H - FOUNDATION_SINK) * 0.5
	var wh := WALL_H + FOUNDATION_SINK
	var hx := WIDTH_X * 0.5
	var hz := DEPTH_Z * 0.5
	# +X wall (far end), and the two long side walls.
	_kit.box(Vector3(hx, wy, 0), Vector3(WALL_T, wh, DEPTH_Z), WALL)
	_kit.box(Vector3(0, wy, -hz), Vector3(WIDTH_X, wh, WALL_T), WALL)
	_kit.box(Vector3(0, wy, hz), Vector3(WIDTH_X, wh, WALL_T), WALL)
	# -X wall (door end): a panel each side of the door, plus a lintel over it.
	var side_len := hz - DOOR_W * 0.5
	var side_c := -(hz + DOOR_W * 0.5) * 0.5
	_kit.box(Vector3(-hx, wy, side_c), Vector3(WALL_T, wh, side_len), WALL)
	_kit.box(Vector3(-hx, wy, -side_c), Vector3(WALL_T, wh, side_len), WALL)
	_kit.box(Vector3(-hx, (DOOR_H + WALL_H) * 0.5, 0), Vector3(WALL_T, WALL_H - DOOR_H, DOOR_W), WALL)
	_emit(true)

	# Flat roof.
	_kit.begin()
	_kit.box(Vector3(0, WALL_H + 0.2, 0), Vector3(WIDTH_X + 1.0, 0.4, DEPTH_Z + 1.0), ROOF)
	_emit(false)

	_build_ramp()


## A wedge threshold from the ground outside the door up to the floor. The floor is a few cm
## above the basin here, and the player has no step-up, so a ramp is what lets them walk in.
func _build_ramp() -> void:
	var x_out := -WIDTH_X * 0.5 - RAMP_LEN
	var x_in := -WIDTH_X * 0.5 + 0.4
	var y_out := minf(_ground_out_y, 0.0) - 0.02
	var y_base := y_out - 0.6
	var hw := DOOR_W * 0.5
	_kit.begin()
	var t0 := Vector3(x_out, y_out, -hw)
	var t1 := Vector3(x_out, y_out, hw)
	var t2 := Vector3(x_in, 0.0, hw)
	var t3 := Vector3(x_in, 0.0, -hw)
	_kit.quad(t0, t1, t2, t3, RAMP)                                   # sloped top
	var b0 := Vector3(x_out, y_base, -hw)
	var b1 := Vector3(x_out, y_base, hw)
	var b2 := Vector3(x_in, y_base, hw)
	var b3 := Vector3(x_in, y_base, -hw)
	_kit.quad(b3, b2, b1, b0, RAMP.darkened(0.35))                    # bottom
	_kit.quad(t0, t3, b3, b0, RAMP.darkened(0.15))                    # -Z side
	_kit.quad(t2, t1, b1, b2, RAMP.darkened(0.15))                    # +Z side
	_kit.quad(t1, t0, b0, b1, RAMP.darkened(0.2))                     # low end
	_kit.quad(t3, t2, b2, b3, RAMP.darkened(0.2))                     # high end (at door sill)
	_emit(true)


func _build_lights() -> void:
	# A few unshadowed omnis so the hall reads under its roof. Sky ambient already lifts the
	# interior; these just keep the machines legible. Shadowless on purpose — shadow maps are
	# the single most expensive thing in this game's frame (see the README).
	for x in [-24.0, 0.0, 24.0]:
		var light := OmniLight3D.new()
		light.position = Vector3(x, WALL_H - 1.2, 0)
		light.omni_range = 30.0
		light.light_energy = 2.2
		light.shadow_enabled = false
		add_child(light)


# ---- machines ---------------------------------------------------------------

func _build_machines() -> void:
	for k in MACHINE_COUNT:
		var mx := MACHINE_X0 + float(k) * MACHINE_DX
		_machines.append({
			"center": Vector3(mx, 0, 0),
			"inlet": Vector3(mx - MACHINE_REACH, ITEM_Y, 0),
			"outlet": Vector3(mx + MACHINE_REACH, ITEM_Y, 0),
			"busy": false,
			"name": MACHINE_NAMES[k],
		})
		_build_machine(k, mx)


func _band(k: int) -> Color:
	if k <= 1:
		return BAND_CORAL
	if k <= 5:
		return BAND_TEAL
	return BAND_AMBER


func _build_machine(k: int, mx: float) -> void:
	var band := _band(k)
	_kit.begin()
	_kit.box(Vector3(mx, 0.3, 0), Vector3(5.0, 0.6, 5.0), DARK)   # plinth, shared by all
	match k:
		0: _m_grinder(mx, band)
		1: _m_renderer(mx, band)
		2: _m_soak(mx, band)
		3: _m_extraction(mx, band)
		4: _m_filter(mx, band)
		5: _m_evaporator(mx, band)
		6: _m_extruder(mx, band)
		7: _m_dryer(mx, band)
		8: _m_mill(mx, band)
	_emit(true)

	# The grinder is the one machine with a shipped model — meat_grinder.glb drops in as its
	# body, the rest are procedural. Placed after the procedural intake/spout so those stay
	# the pipeline's anchor points.
	if k == 0:
		_place_intake_model(mx)

	# Moving parts, as separate nodes pivoted in place so they spin rather than orbit.
	match k:
		2: _add_spinner(Vector3(mx, 3.4, 0), _spin_paddle(), 2.2)
		8: _add_spinner(Vector3(mx, 3.1, 0), _spin_cyl(0.9, 1.4, METAL.darkened(0.1)), 1.6)


func _m_grinder(mx: float, band: Color) -> void:
	# No procedural housing here — meat_grinder.glb is the body (see _place_intake_model).
	# These are the intake mouth (the horse goes in the -X side, facing the door) and the
	# output spout, kept procedural so they line up exactly with the conveyor in/outlet.
	_kit.box(Vector3(mx - 2.4, 1.6, 0), Vector3(1.6, 1.8, 2.6), DARK)
	_kit.box(Vector3(mx - 2.4, 2.9, 0), Vector3(2.1, 0.7, 2.9), METAL)
	_kit.box(Vector3(mx + 2.3, 1.0, 0), Vector3(1.2, 0.8, 1.2), METAL)


## Drops the shipped grinder model onto the plinth as the intake machine's body, fitted to
## the machines' scale and given a plain box body so the player cannot walk through it. If the
## asset is missing the machine is still functional — just the intake mouth and spout.
func _place_intake_model(mx: float) -> void:
	var path := "res://models/meat_grinder.glb"
	if not ResourceLoader.exists(path):
		return
	var model := (load(path) as PackedScene).instantiate() as Node3D
	MeshKit.force_pixel_look(model)
	add_child(model)
	MeshKit.place_upright(model, mx, 0.0, 0.6, 3.4)
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.2, 3.2, 3.2)
	col.shape = box
	col.position = Vector3(mx, 2.0, 0)
	body.add_child(col)
	add_child(body)


func _m_renderer(mx: float, band: Color) -> void:
	_kit.cylinder(Vector3(mx, 2.2, 0), 1.8, 3.4, 12, band)
	_kit.cone(Vector3(mx, 3.9, 0), 1.8, 0.7, 12, band.darkened(0.12))
	_kit.rail(Vector3(mx + 1.1, 3.6, 0), Vector3(mx + 1.1, 6.2, 0), 0.18, METAL)   # steam stack
	_kit.cylinder(Vector3(mx, 0.95, -2.3), 0.7, 1.4, 8, TALLOW.darkened(0.1))       # tallow drum
	_kit.box(Vector3(mx + 2.1, 1.0, 0), Vector3(1.0, 0.8, 1.0), METAL)


func _m_soak(mx: float, band: Color) -> void:
	_kit.cylinder(Vector3(mx, 1.9, 0), 1.9, 3.0, 12, band)
	_kit.cylinder(Vector3(mx, 3.45, 0), 1.95, 0.2, 12, METAL)       # rim
	_kit.rail(Vector3(mx, 3.4, 0), Vector3(mx, 4.4, 0), 0.12, METAL)  # stirrer mast


func _m_extraction(mx: float, band: Color) -> void:
	_kit.cylinder(Vector3(mx, 2.6, 0), 1.5, 4.6, 12, band)
	_kit.cylinder(Vector3(mx, 1.6, 0), 1.55, 0.25, 12, METAL)
	_kit.cylinder(Vector3(mx, 3.4, 0), 1.55, 0.25, 12, METAL)
	_kit.cone(Vector3(mx, 4.9, 0), 1.5, 0.7, 12, band.darkened(0.12))
	# Staged heat pipes down one side.
	_kit.rail(Vector3(mx - 1.7, 0.6, 1.2), Vector3(mx - 1.7, 4.4, 1.2), 0.1, METAL.darkened(0.1))


func _m_filter(mx: float, band: Color) -> void:
	# A plate-and-frame press: end frames with a stack of plates squeezed between.
	for x in [mx - 2.0, mx + 2.0]:
		_kit.box(Vector3(x, 1.7, 0), Vector3(0.35, 3.0, 3.2), METAL.darkened(0.1))
	_kit.box(Vector3(mx, 3.2, 0), Vector3(4.4, 0.3, 3.2), METAL)     # top beam
	for i in 7:
		var x := mx - 1.5 + float(i) * 0.5
		_kit.box(Vector3(x, 1.7, 0), Vector3(0.2, 2.6, 2.8), band.darkened(0.06 * (i % 2)))


func _m_evaporator(mx: float, band: Color) -> void:
	_kit.cylinder(Vector3(mx, 3.3, 0), 1.1, 5.8, 12, band)
	_kit.cone(Vector3(mx, 6.2, 0), 1.1, 1.0, 12, band.darkened(0.12))
	_kit.box(Vector3(mx, 0.9, 0), Vector3(2.6, 0.8, 2.6), METAL.darkened(0.1))
	# Condenser return running down the side.
	_kit.rail(Vector3(mx + 1.4, 0.7, 0), Vector3(mx + 1.4, 5.8, 0), 0.14, METAL)


func _m_extruder(mx: float, band: Color) -> void:
	_kit.box(Vector3(mx, 1.7, 0), Vector3(3.2, 2.6, 3.0), band)      # chiller
	_kit.box(Vector3(mx + 1.9, 1.6, 0), Vector3(1.2, 1.4, 2.4), METAL)  # extruder head
	# Noodle spouts hanging from the head.
	for i in 5:
		var z := -0.9 + float(i) * 0.45
		_kit.rail(Vector3(mx + 2.4, 1.5, z), Vector3(mx + 2.4, 0.95, z), 0.06, STREAM_COLORS[7])


func _m_dryer(mx: float, band: Color) -> void:
	_kit.box(Vector3(mx, 1.5, 0), Vector3(5.0, 2.2, 3.0), band)      # tunnel
	_kit.box(Vector3(mx, 0.95, 0), Vector3(5.2, 0.16, 1.4), DARK)    # the belt line through it
	# Dark mouths at each end.
	for x in [mx - 2.5, mx + 2.5]:
		_kit.box(Vector3(x, 1.1, 0), Vector3(0.1, 1.0, 1.6), Color(0.1, 0.1, 0.12))


func _m_mill(mx: float, band: Color) -> void:
	_kit.box(Vector3(mx, 1.7, 0), Vector3(3.0, 2.6, 3.0), band)
	_kit.box(Vector3(mx + 1.9, 1.1, 0), Vector3(1.2, 1.2, 1.2), METAL)  # bagging chute
	_kit.box(Vector3(mx, 3.3, 0), Vector3(2.2, 0.5, 2.2), METAL.darkened(0.1))  # drum housing


# ---- conveyors --------------------------------------------------------------

func _build_conveyors() -> void:
	_kit.begin()
	# Intake stub (door side of the grinder) then a belt between every pair of machines.
	var first: Vector3 = _machines[0]["inlet"]
	_belt(Vector3(first.x - 2.0, ITEM_Y, 0), first)
	for k in MACHINE_COUNT - 1:
		_belt(_machines[k]["outlet"], _machines[k + 1]["inlet"])
	# Discharge belt from the mill out toward the pallet in the +Z aisle.
	var last: Vector3 = _machines[MACHINE_COUNT - 1]["outlet"]
	_belt(last, Vector3(30.0, ITEM_Y, 6.0))
	_emit(true)


## A conveyor run: a belt slab on legs, with a low side rail each side.
func _belt(from: Vector3, to: Vector3) -> void:
	var mid := (from + to) * 0.5
	var span := to - from
	var length := Vector2(span.x, span.z).length()
	if length < 0.2:
		return
	var horizontal := absf(span.x) >= absf(span.z)
	var belt_size := Vector3(length + 0.4, 0.16, 1.2) if horizontal else Vector3(1.2, 0.16, length + 0.4)
	_kit.box(Vector3(mid.x, ITEM_Y - 0.25, mid.z), belt_size, DARK)
	var frame_size := Vector3(length + 0.4, 0.5, 1.4) if horizontal else Vector3(1.4, 0.5, length + 0.4)
	_kit.box(Vector3(mid.x, ITEM_Y - 0.55, mid.z), frame_size, METAL.darkened(0.15))
	# Legs.
	for t in [0.2, 0.8]:
		var leg := from.lerp(to, t)
		_kit.box(Vector3(leg.x, (ITEM_Y - 0.8) * 0.5, leg.z),
				Vector3(0.24, ITEM_Y - 0.8, 0.24), METAL.darkened(0.2))


# ---- spinner meshes ---------------------------------------------------------

func _spin_cyl(radius: float, height: float, color: Color) -> ArrayMesh:
	_kit.begin()
	_kit.cylinder(Vector3.ZERO, radius, height, 8, color)
	return _kit.commit()


func _spin_paddle() -> ArrayMesh:
	_kit.begin()
	_kit.rail(Vector3(0, -0.6, 0), Vector3(0, 0.6, 0), 0.1, METAL)   # shaft
	_kit.box(Vector3(0, -0.5, 0), Vector3(1.8, 0.5, 0.14), METAL.darkened(0.1))  # blade
	return _kit.commit()


func _add_spinner(pivot: Vector3, mesh: ArrayMesh, speed: float) -> void:
	if mesh == null:
		return
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = _mat
	node.position = pivot
	add_child(node)
	_spinners.append({"node": node, "speed": speed})


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
