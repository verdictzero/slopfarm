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
## The model's local origin sits at the ground (wheel-contact) plane and wheels mount at
## +WHEEL_RADIUS, so this is a small ground clearance, NOT a lift — the tyres stay planted rather
## than floating as they did before.
const RIDE_HEIGHT := 0.05
## Tyre outer radius. ~0.9 m diameter — a medium delivery truck, not the old 1.24 m monster wheels.
const WHEEL_RADIUS := 0.46

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
	var want := global_position + b.y * 3.8 - b.z * 9.0
	if snap or delta <= 0.0:
		_camera.global_position = want
	else:
		_camera.global_position = _camera.global_position.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	_camera.look_at(global_position + b.y * 1.5, Vector3.UP)


func _roll_wheels(delta: float) -> void:
	var spin := _speed * delta / WHEEL_RADIUS
	for w: Node3D in _wheels:
		w.rotate_x(spin)
	for p: Node3D in _steer_pivots:
		p.rotation.y = _steer * 0.5


# ---- model ------------------------------------------------------------------

## A medium flatbed delivery truck, ~6.0 m long / 1.9 m wide / 2.35 m tall, laid out front (-Z) to
## back: bumper, grille, short hood, sloped windscreen, cab, then the open bed. Everything sits on
## a ladder frame that rides on two axles. Built once at construction; the local origin is the
## ground plane (y = 0 = wheel contact).
func _build_body() -> void:
	_kit.begin()

	# --- Ladder chassis: two frame rails on the axle line, tied by cross-members. ---
	for sx in [-0.72, 0.72]:
		_kit.box(Vector3(sx, 0.66, 0.1), Vector3(0.16, 0.18, 5.7), CHASSIS)
	for cz in [-1.9, -0.4, 1.1, 2.6]:
		_kit.box(Vector3(0, 0.64, cz), Vector3(1.5, 0.12, 0.16), CHASSIS.darkened(0.1))

	# --- Cab: cabin, roof, hood ahead of it, and a windscreen that slopes UP-and-BACK from the
	#     cowl to the roof (the real geometry — the old one faced backwards at the rear of the cab).
	_kit.box(Vector3(0, 1.48, -1.32), Vector3(1.98, 1.46, 1.3), CAB)               # cabin
	_kit.box(Vector3(0, 2.2, -1.12), Vector3(1.9, 0.14, 0.98), CAB_DK)             # roof
	_kit.box(Vector3(0, 1.06, -2.5), Vector3(1.86, 0.66, 1.1), CAB)                # hood
	_kit.quad(Vector3(-0.86, 1.4, -1.97), Vector3(0.86, 1.4, -1.97),
			Vector3(0.86, 2.14, -1.62), Vector3(-0.86, 2.14, -1.62), GLASS)        # windscreen
	for sx in [-1.0, 1.0]:
		_kit.box(Vector3(sx, 1.72, -1.28), Vector3(0.05, 0.6, 1.0), GLASS)         # side window
	_kit.box(Vector3(0, 1.8, -0.69), Vector3(1.4, 0.5, 0.06), GLASS)               # rear window

	# --- Front end: grille, headlights, bumper. ---
	_kit.box(Vector3(0, 1.0, -3.06), Vector3(1.72, 0.72, 0.1), CHROME)             # grille
	for sx in [-0.62, 0.62]:
		_kit.box(Vector3(sx, 1.06, -3.09), Vector3(0.32, 0.3, 0.08), LAMP)         # headlight
	_kit.box(Vector3(0, 0.6, -3.14), Vector3(2.0, 0.26, 0.2), CHROME)              # bumper

	# --- Flatbed: deck, tall headboard behind the cab, low stake sides, tailboard, GLUE placard. ---
	_kit.box(Vector3(0, 0.82, 1.0), Vector3(2.16, 0.16, 3.8), BED.darkened(0.08))  # deck
	_kit.box(Vector3(0, 1.4, -0.78), Vector3(2.16, 1.16, 0.12), BED.darkened(0.15))  # headboard
	for sx in [-1.02, 1.02]:
		_kit.box(Vector3(sx, 1.16, 1.0), Vector3(0.12, 0.66, 3.8), BED)            # stake side
	_kit.box(Vector3(0, 1.16, 2.86), Vector3(2.16, 0.66, 0.12), BED)               # tailboard
	_kit.box(Vector3(0, 1.2, 2.92), Vector3(1.5, 0.5, 0.06), SIGN)                 # GLUE placard
	for s in [Vector2(-0.5, 0.4), Vector2(0.55, 1.3), Vector2(-0.1, 2.0)]:
		_kit.box(Vector3(s.x, 1.15, s.y), Vector3(0.68, 0.6, 0.6), Color(0.60, 0.50, 0.33))  # sacks

	# --- Running gear: a horizontal saddle fuel tank on the frame, a slim exhaust stack behind the
	#     cab, and mudflaps behind the rear wheels. ---
	_kit.pipe(Vector3(-0.84, 0.52, -0.2), Vector3(-0.84, 0.52, 1.1), 0.22, 10, CHROME.darkened(0.12))
	_kit.pipe(Vector3(0.86, 0.74, -0.7), Vector3(0.86, 2.05, -0.7), 0.08, 8, CHASSIS.lightened(0.25))
	for sx in [-0.72, 0.72]:
		_kit.box(Vector3(sx, 0.44, -3.2), Vector3(0.16, 0.5, 0.16), CHROME.darkened(0.2))  # bumper irons
	for sx in [-0.98, 0.98]:
		_kit.box(Vector3(sx, 0.28, 2.35), Vector3(0.1, 0.5, 0.36), CHASSIS)        # rear mudflap
	for sx in [-0.62, 0.62]:
		_kit.box(Vector3(sx, 1.1, 2.93), Vector3(0.28, 0.24, 0.06), CAB_DK)        # taillight

	var mesh := _kit.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	add_child(mi)


func _build_wheels() -> void:
	var wheel_mesh := _wheel_mesh()
	# (local x, z, is_front) — front axle under the cab, rear axle under the bed: ~3.75 m wheelbase.
	var spots := [
		[-0.92, -1.9, true], [0.92, -1.9, true],
		[-0.92, 1.85, false], [0.92, 1.85, false],
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


## A wheel on its axle (local X): a black tyre torus whose OUTER edge is exactly WHEEL_RADIUS (so it
## rolls right and sits on the ground), a steel rim disc across the axle, a hub cap, and lug bars.
func _wheel_mesh() -> ArrayMesh:
	_kit.begin()
	var sides := 14
	var tube := 8
	var rt := 0.14
	var R := WHEEL_RADIUS - rt            # tube centre, so the tyre's outer edge = WHEEL_RADIUS
	# Tyre: torus around the X axle (ring in the YZ plane).
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
	# Steel rim across the axle (a shallow disc, X = axle), then a small hub cap.
	_kit.pipe(Vector3(-0.09, 0, 0), Vector3(0.09, 0, 0), R, 12, HUB.darkened(0.15))
	_kit.pipe(Vector3(-0.13, 0, 0), Vector3(0.13, 0, 0), 0.09, 8, HUB)
	# Lug bars across the rim face.
	for k in 5:
		var a := TAU * float(k) / 5.0 + 0.3
		_kit.box(Vector3(0.1, cos(a) * R * 0.55, sin(a) * R * 0.55), Vector3(0.06, R * 0.7, 0.11), HUB.darkened(0.08))
	return _kit.commit()
