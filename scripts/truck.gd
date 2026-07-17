extends Node3D
class_name Truck
## A drivable delivery truck for carting glue from the works into town to sell. It is a custom,
## procedural, detailed model — cab, glazed windows, headlights, an open cargo bed marked GLUE,
## a fuel tank, an exhaust stack, bumpers, mudflaps and four wheels that roll and steer.
##
## Deliberately KINEMATIC and terrain-following rather than a physics vehicle: every frame it
## reads the pure height field under itself and sets its own transform, banking and pitching to
## the slope. That means it never relies on streamed collision (which only exists near the
## player) and can never get wedged, flipped or fall through freshly-built ground — the same
## robustness rule the rest of the game follows. It drives over everything; the trade-off for
## never being stuck is that it does not bump off buildings.

const MAX_SPEED := 36.0
const REVERSE_SPEED := 11.0
const ACCEL := 24.0
const BRAKE := 34.0
const DRAG := 7.0
const STEER_RATE := 1.7
## How far out the truck can roam before it stops, so it never drives into the unstreamed void.
const WORLD_LIMIT := 840.0
const RIDE_HEIGHT := 0.75
const WHEEL_RADIUS := 0.62

const CAB := Color(0.72, 0.18, 0.16)
const CAB_DK := Color(0.55, 0.13, 0.12)
const BED := Color(0.32, 0.33, 0.36)
const CHASSIS := Color(0.18, 0.18, 0.20)
const GLASS := Color(0.32, 0.44, 0.50)
const CHROME := Color(0.70, 0.71, 0.74)
const TIRE := Color(0.10, 0.10, 0.12)
const HUB := Color(0.66, 0.66, 0.70)
const LAMP := Color(0.95, 0.92, 0.70)
const SIGN := Color(0.86, 0.66, 0.12)

var _terrain: TerrainManager
var _mat: StandardMaterial3D
var _kit := MeshKit.new()
var _camera: Camera3D
var _driver: Node3D
## The driver's on-screen controls, if driving on a phone — the truck reads the thumb-stick for
## throttle and steering. Null when driving with a keyboard.
var _touch: TouchControls

var _speed := 0.0
var _heading := 0.0
var _steer := 0.0
## Wheel nodes: front two live under steer pivots so they turn; all four roll.
var _wheels: Array = []
var _steer_pivots: Array = []


## Builds the truck and parks it at world `at`, facing `heading` (radians). Call once from main.
func setup(terrain: TerrainManager, at: Vector3, heading: float) -> void:
	_terrain = terrain
	_heading = heading
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.8
	_mat.metallic = 0.0
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_build_body()
	_build_wheels()

	_camera = Camera3D.new()
	_camera.far = 5000.0
	_camera.top_level = true            # chase in world space, not bolted to the rolling body
	add_child(_camera)

	global_position = Vector3(at.x, terrain.height_at(at.x, at.z) + RIDE_HEIGHT, at.z)
	_orient(global_position)
	add_to_group("truck")


func is_driven() -> bool:
	return _driver != null


## Take the wheel. The truck's chase camera becomes current; the caller hides/parks its own view.
## `touch` is the driver's on-screen controls on a phone, or null for keyboard driving.
func enter(driver: Node3D, touch: TouchControls = null) -> void:
	_driver = driver
	_touch = touch
	_speed = 0.0
	if _camera != null:
		_place_camera(0.0, true)
		_camera.current = true


## Step out. Returns a clear spot beside the cab to drop the driver on.
func exit() -> Vector3:
	_driver = null
	var right := global_transform.basis.x
	var drop := global_position + right * 3.4 + Vector3.UP * 1.0
	drop.y = _terrain.height_at(drop.x, drop.z) + 1.5
	return drop


func _physics_process(delta: float) -> void:
	if _terrain == null:
		return
	if _driver != null:
		_drive(delta)
	_roll_wheels(delta)


func _drive(delta: float) -> void:
	var throttle := 0.0
	if Input.is_physical_key_pressed(KEY_W):
		throttle += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		throttle -= 1.0
	var steer_in := 0.0
	if Input.is_physical_key_pressed(KEY_A):
		steer_in += 1.0
	if Input.is_physical_key_pressed(KEY_D):
		steer_in -= 1.0
	# The touch thumb-stick drives too: push up to go, down to brake/reverse, left/right to steer.
	if _touch != null:
		throttle += _touch.move_vector.y
		steer_in -= _touch.move_vector.x
	throttle = clampf(throttle, -1.0, 1.0)
	steer_in = clampf(steer_in, -1.0, 1.0)
	_steer = lerpf(_steer, steer_in, clampf(delta * 8.0, 0.0, 1.0))

	if throttle > 0.0:
		_speed += ACCEL * delta
	elif throttle < 0.0:
		_speed -= BRAKE * delta
	else:
		_speed = move_toward(_speed, 0.0, DRAG * delta)
	_speed = clampf(_speed, -REVERSE_SPEED, MAX_SPEED)

	# Steering bites in proportion to how fast you are going, and reverses in reverse.
	if absf(_speed) > 0.3:
		var bite := clampf(absf(_speed) / 8.0, 0.0, 1.0) * signf(_speed)
		_heading += _steer * STEER_RATE * delta * bite

	var forward := -global_transform.basis.z
	var next := global_position + forward * _speed * delta
	if Vector2(next.x, next.z).length() > WORLD_LIMIT:
		_speed = 0.0
		next = global_position
	next.y = _terrain.height_at(next.x, next.z) + RIDE_HEIGHT
	global_position = next
	_orient(next)
	_place_camera(delta, false)


## Aligns the truck to the ground under it (pitch/roll from the local slope) and to its heading.
func _orient(at: Vector3) -> void:
	var yaw := Basis(Vector3.UP, _heading)
	var fwd := (yaw * Vector3.FORWARD)
	var right := (yaw * Vector3.RIGHT)
	var l := 2.2
	var hf := _terrain.height_at(at.x + fwd.x * l, at.z + fwd.z * l)
	var hb := _terrain.height_at(at.x - fwd.x * l, at.z - fwd.z * l)
	var hr := _terrain.height_at(at.x + right.x * l, at.z + right.z * l)
	var hl := _terrain.height_at(at.x - right.x * l, at.z - right.z * l)
	var fslope := Vector3(fwd.x * 2.0 * l, hf - hb, fwd.z * 2.0 * l).normalized()
	var up := Vector3(-(hr - hl), 2.0 * l, -(hf - hb)).normalized()
	if up.y < 0.2:
		up = Vector3.UP
	var target := Basis.looking_at(fslope, up)
	# Ease the orientation so it does not snap frame to frame on rough ground.
	var blended := global_transform.basis.get_rotation_quaternion().slerp(
			target.get_rotation_quaternion(), 0.35)
	global_transform.basis = Basis(blended)


func _place_camera(delta: float, snap: bool) -> void:
	if _camera == null:
		return
	var b := global_transform.basis
	var want := global_position + b.y * 3.4 - b.z * 9.5
	if snap or delta <= 0.0:
		_camera.global_position = want
	else:
		_camera.global_position = _camera.global_position.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	_camera.look_at(global_position + b.y * 1.6, Vector3.UP)


func _roll_wheels(delta: float) -> void:
	var spin := _speed * delta / WHEEL_RADIUS
	for w: Node3D in _wheels:
		w.rotate_x(spin)
	for p: Node3D in _steer_pivots:
		p.rotation.y = _steer * 0.5


# ---- model ------------------------------------------------------------------

func _build_body() -> void:
	_kit.begin()
	# Chassis rails.
	for sx in [-0.9, 0.9]:
		_kit.box(Vector3(sx, 0.55, 0.2), Vector3(0.25, 0.3, 6.4), CHASSIS)
	_kit.box(Vector3(0, 0.5, 0.2), Vector3(2.0, 0.2, 6.2), CHASSIS.darkened(0.1))
	# Cab (forward, -Z), with a sloped windscreen.
	_kit.box(Vector3(0, 1.5, -2.2), Vector3(2.3, 1.8, 1.9), CAB)
	_kit.box(Vector3(0, 2.3, -1.6), Vector3(2.1, 0.9, 0.9), CAB_DK)      # cab roof step
	_kit.box(Vector3(0, 1.9, -1.15), Vector3(1.9, 0.9, 0.16), GLASS)     # windscreen
	for sx in [-1.0, 1.0]:
		_kit.box(Vector3(sx * 1.16, 1.6, -2.2), Vector3(0.08, 0.9, 1.2), GLASS)  # side windows
	# Hood + grille + headlights + bumper.
	_kit.box(Vector3(0, 1.05, -3.1), Vector3(2.2, 0.9, 0.9), CAB)
	_kit.box(Vector3(0, 1.0, -3.58), Vector3(2.0, 0.7, 0.12), CHROME)    # grille
	for sx in [-0.7, 0.7]:
		_kit.box(Vector3(sx, 1.05, -3.6), Vector3(0.4, 0.4, 0.1), LAMP)  # headlight
	_kit.box(Vector3(0, 0.7, -3.66), Vector3(2.4, 0.35, 0.2), CHROME)    # front bumper
	# Cargo bed (open box, +Z) with a GLUE placard.
	_kit.box(Vector3(0, 0.85, 1.6), Vector3(2.4, 0.3, 4.0), BED.darkened(0.1))   # bed floor
	for sx in [-1.15, 1.15]:
		_kit.box(Vector3(sx, 1.4, 1.6), Vector3(0.14, 1.1, 4.0), BED)   # bed side
	_kit.box(Vector3(0, 1.4, 3.55), Vector3(2.4, 1.1, 0.14), BED)       # tailboard
	_kit.box(Vector3(0, 1.7, -0.35), Vector3(2.4, 1.7, 0.16), BED.darkened(0.15))  # headboard
	_kit.box(Vector3(0, 1.5, 3.63), Vector3(1.6, 0.7, 0.08), SIGN)      # GLUE placard
	# A couple of sacks riding in the bed.
	for sx in [-0.5, 0.6]:
		_kit.box(Vector3(sx, 1.3, 1.4 + sx), Vector3(0.8, 0.7, 0.7), Color(0.60, 0.50, 0.33))
	# Fuel tank + exhaust stack + mudflaps.
	_kit.cylinder(Vector3(-1.15, 0.8, -0.4), 0.35, 1.4, 8, CHROME.darkened(0.1))
	_kit.pipe(Vector3(1.1, 1.0, -1.6), Vector3(1.1, 3.0, -1.6), 0.12, 6, CHASSIS.lightened(0.2))
	for sz in [-2.9, 2.9]:
		for sx in [-1.25, 1.25]:
			_kit.box(Vector3(sx, 0.5, sz), Vector3(0.1, 0.7, 0.5), CHASSIS)   # mudflap
	var mesh := _kit.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	add_child(mi)


func _build_wheels() -> void:
	var wheel_mesh := _wheel_mesh()
	# (local x, z, is_front)
	var spots := [
		[-1.15, -2.4, true], [1.15, -2.4, true],
		[-1.15, 2.2, false], [1.15, 2.2, false],
	]
	for s in spots:
		var lx: float = s[0]
		var lz: float = s[1]
		var front: bool = s[2]
		var mount := Node3D.new()
		mount.position = Vector3(lx, WHEEL_RADIUS, lz)
		add_child(mount)
		var wheel := MeshInstance3D.new()
		wheel.mesh = wheel_mesh
		wheel.material_override = _mat
		mount.add_child(wheel)
		_wheels.append(wheel)
		if front:
			_steer_pivots.append(mount)


## A wheel lying on its axle (local X): a black tyre torus, a hub disk and spokes.
func _wheel_mesh() -> ArrayMesh:
	_kit.begin()
	# Torus in XZ plane, then the caller's mount keeps the axle along X — rotate the ring so its
	# axle is X by building it around the X axis directly.
	var sides := 12
	var tube := 10
	var R := WHEEL_RADIUS
	var rt := 0.24
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var c0 := Vector3(0, cos(a0), sin(a0))
		var c1 := Vector3(0, cos(a1), sin(a1))
		for j in tube:
			var b0 := TAU * float(j) / float(tube)
			var b1 := TAU * float(j + 1) / float(tube)
			var n0 := Vector3(sin(b0), 0, 0) * rt
			var n1 := Vector3(sin(b1), 0, 0) * rt
			var p00 := c0 * (R + cos(b0) * rt) + n0
			var p01 := c0 * (R + cos(b1) * rt) + n1
			var p10 := c1 * (R + cos(b0) * rt) + n0
			var p11 := c1 * (R + cos(b1) * rt) + n1
			_kit.quad(p00, p10, p11, p01, TIRE.lightened(0.05 * (j % 2)))
	# Hub + spokes on the outer face.
	_kit.cylinder(Vector3(0.0, 0, 0), 0.22, 0.5, 8, HUB)
	for k in 5:
		var a := TAU * float(k) / 5.0
		_kit.box(Vector3(0.12, cos(a) * R * 0.5, sin(a) * R * 0.5), Vector3(0.08, R * 0.9, 0.1), HUB.darkened(0.1))
	return _kit.commit()
