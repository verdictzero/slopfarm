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
## Big off-road tyre: ~1.3 m diameter, like the lifted-Ram reference. Outer edge = WHEEL_RADIUS.
const WHEEL_RADIUS := 0.66
## Layout (local space, y = 0 = ground, -Z = forward). The body is LIFTED: it sits at FRAME_Y, a
## big gap above the axles at AXLE_Y, with the suspension bridging the gap — the monster-truck stance.
const TRACK := 1.2           # wheel-centre half-track (wide stance)
const AXLE_F := -2.05        # front axle z
const AXLE_R := 2.15         # rear axle z
const AXLE_Y := 0.66         # axle centre height (= WHEEL_RADIUS)
const FRAME_Y := 1.62        # top of the frame rails / underside of the body

const CAB := Color(0.52, 0.53, 0.57)     # gunmetal body
const CAB_DK := Color(0.38, 0.39, 0.43)  # shaded body / trim
const BED := Color(0.30, 0.31, 0.34)     # bed liner
const CHASSIS := Color(0.12, 0.12, 0.14) # frame, suspension, bumper, flares (matte black)
const GLASS := Color(0.20, 0.26, 0.30)   # dark tinted glass
const CHROME := Color(0.70, 0.71, 0.74)
const TIRE := Color(0.08, 0.08, 0.10)
const HUB := Color(0.16, 0.16, 0.18)     # black beadlock wheel
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
	_build_suspension()
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
	var drop := global_position + right * 3.8 + Vector3.UP * 1.0
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
	var want := global_position + b.y * 5.2 - b.z * 11.5
	if snap or delta <= 0.0:
		_camera.global_position = want
	else:
		_camera.global_position = _camera.global_position.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	_camera.look_at(global_position + b.y * 2.2, Vector3.UP)


func _roll_wheels(delta: float) -> void:
	var spin := _speed * delta / WHEEL_RADIUS
	for w: Node3D in _wheels:
		w.rotate_x(spin)
	for p: Node3D in _steer_pivots:
		p.rotation.y = _steer * 0.5


# ---- model ------------------------------------------------------------------

## A lifted crew-cab off-road pickup, after the Ram reference: a tall body (~3.0 m to the roof,
## ~3.3 m over the light bar) riding high on a big gap of exposed suspension over ~1.3 m tyres.
## Laid out front (-Z) to back: bull-bar bumper, RAM-style grille, hood, four-door cab, then a
## pickup bed with a tailgate. Local origin is the ground plane (y = 0 = wheel contact).
func _build_body() -> void:
	_kit.begin()
	var top := 2.98                                       # roofline
	# --- Lifted ladder frame + a skid under the engine. ---
	for sx in [-0.82, 0.82]:
		_kit.box(Vector3(sx, FRAME_Y - 0.12, 0.0), Vector3(0.18, 0.22, 6.0), CHASSIS)
	for cz in [AXLE_F, -0.4, 1.2, AXLE_R]:
		_kit.box(Vector3(0, FRAME_Y - 0.14, cz), Vector3(1.66, 0.14, 0.18), CHASSIS.lightened(0.06))

	# --- Crew cab: four-door cabin, roof, hood, sloped windscreen, two rows of side glass. ---
	var cab_lo := FRAME_Y                                 # body sits on the frame
	_kit.box(Vector3(0, (cab_lo + top) * 0.5, -0.55), Vector3(2.04, top - cab_lo, 2.7), CAB)  # cabin
	_kit.box(Vector3(0, top, -0.55), Vector3(1.98, 0.12, 2.5), CAB_DK)                        # roof
	_kit.box(Vector3(0, cab_lo + 0.55, -2.55), Vector3(1.96, 0.9, 1.3), CAB)                  # hood
	_kit.box(Vector3(0, cab_lo + 0.62, -2.62), Vector3(1.9, 0.2, 0.5), CAB_DK)                # hood scoop step
	# Windscreen (cowl -> roof) and backlight.
	_kit.quad(Vector3(-0.92, top - 0.72, -1.9), Vector3(0.92, top - 0.72, -1.9),
			Vector3(0.9, top - 0.04, -1.45), Vector3(-0.9, top - 0.04, -1.45), GLASS)
	_kit.box(Vector3(0, top - 0.42, 0.78), Vector3(1.7, 0.66, 0.06), GLASS)                   # backlight
	# Side glass: front + rear door windows each side (crew cab).
	for sx in [-1.03, 1.03]:
		_kit.box(Vector3(sx, top - 0.46, -1.35), Vector3(0.05, 0.6, 0.86), GLASS)             # front door
		_kit.box(Vector3(sx, top - 0.46, -0.2), Vector3(0.05, 0.6, 0.86), GLASS)              # rear door
	# Side mirrors on stalks.
	for sx in [-1.18, 1.18]:
		_kit.box(Vector3(sx, top - 0.62, -1.86), Vector3(0.28, 0.24, 0.12), CAB_DK)

	# --- Front end: RAM-style grille, headlights, and a bull-bar bumper with light pods + winch. ---
	_kit.box(Vector3(0, cab_lo + 0.5, -3.12), Vector3(1.7, 0.86, 0.14), CHASSIS.lightened(0.05))  # grille
	_kit.box(Vector3(0, cab_lo + 0.5, -3.19), Vector3(1.2, 0.34, 0.06), CHROME)                    # grille bar
	for sx in [-0.66, 0.66]:
		_kit.box(Vector3(sx, cab_lo + 0.56, -3.16), Vector3(0.34, 0.34, 0.08), LAMP)              # headlight
	_kit.box(Vector3(0, cab_lo + 0.02, -3.24), Vector3(1.94, 0.42, 0.28), CHASSIS)                # bumper
	_kit.box(Vector3(0, cab_lo - 0.08, -3.4), Vector3(0.8, 0.26, 0.14), CHROME.darkened(0.2))     # winch
	# Bull bar hoop over the bumper.
	for sx in [-0.55, 0.55]:
		_kit.pipe(Vector3(sx, cab_lo + 0.02, -3.3), Vector3(sx, cab_lo + 0.62, -3.24), 0.05, 6, CHASSIS)
	_kit.pipe(Vector3(-0.55, cab_lo + 0.62, -3.24), Vector3(0.55, cab_lo + 0.62, -3.24), 0.05, 6, CHASSIS)
	for sx in [-0.86, 0.86]:
		_kit.box(Vector3(sx, cab_lo + 0.02, -3.28), Vector3(0.16, 0.16, 0.06), LAMP)              # bumper light pod

	# --- Pickup bed: floor, tall body-colour bedsides, tailgate, GLUE decal, taillights. ---
	var bed_lo := FRAME_Y + 0.06
	_kit.box(Vector3(0, bed_lo + 0.08, 1.75), Vector3(2.0, 0.16, 2.6), BED)                       # bed floor
	for sx in [-0.98, 0.98]:
		_kit.box(Vector3(sx, bed_lo + 0.52, 1.75), Vector3(0.14, 0.88, 2.6), CAB)                 # bedside
	_kit.box(Vector3(0, bed_lo + 0.52, 3.05), Vector3(2.0, 0.88, 0.12), CAB)                      # tailgate
	_kit.box(Vector3(0, bed_lo + 0.5, 3.12), Vector3(1.3, 0.42, 0.05), SIGN)                      # GLUE decal
	for sx in [-0.7, 0.7]:
		_kit.box(Vector3(sx, bed_lo + 0.6, 3.11), Vector3(0.3, 0.42, 0.05), CAB_DK)               # taillight

	# --- Fender flares over each wheel (black, bulged) and a roof rack + light bar. ---
	for zc in [AXLE_F, AXLE_R]:
		for sx in [-1.06, 1.06]:
			_kit.box(Vector3(sx, FRAME_Y - 0.02, zc), Vector3(0.34, 0.24, 1.5), CHASSIS.lightened(0.04))
	_kit.box(Vector3(0, top + 0.1, -0.9), Vector3(1.86, 0.08, 2.0), CHASSIS.lightened(0.05))      # roof rack
	for sx in [-0.9, 0.9]:
		_kit.box(Vector3(sx, top + 0.06, -0.9), Vector3(0.06, 0.12, 2.0), CHASSIS)                # rack rails
	_kit.box(Vector3(0, top + 0.2, -1.86), Vector3(1.7, 0.14, 0.16), LAMP)                        # roof light bar

	var mesh := _kit.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	add_child(mi)


## The exposed lifted suspension bridging the big gap between the axles (AXLE_Y) and the frame
## (FRAME_Y): a solid axle beam + diff at each end, angled coilover shocks, control-arm links, a
## track bar and the driveshaft. This is the detail that makes the stance read as a real lift.
func _build_suspension() -> void:
	_kit.begin()
	for zc in [AXLE_F, AXLE_R]:
		# Solid axle tube across, with a diff pumpkin offset to one side.
		_kit.pipe(Vector3(-TRACK, AXLE_Y, zc), Vector3(TRACK, AXLE_Y, zc), 0.11, 8, CHASSIS.lightened(0.05))
		_kit.sphere(Vector3(0.24, AXLE_Y, zc), 0.24, 5, 7, CHASSIS.lightened(0.08))
		# Coilover shocks: axle up to the frame, one each side (angled inboard).
		for sx in [-0.78, 0.78]:
			_kit.pipe(Vector3(sx, AXLE_Y + 0.02, zc), Vector3(sx * 0.72, FRAME_Y - 0.02, zc + 0.28),
					0.07, 6, CHROME.darkened(0.1))
		# Control-arm links: axle to frame, fore/aft.
		for sx in [-0.5, 0.5]:
			_kit.pipe(Vector3(sx, AXLE_Y - 0.04, zc), Vector3(sx, FRAME_Y - 0.16, zc - signf(zc) * 0.9),
					0.05, 5, CHASSIS.lightened(0.03))
		# Track bar across.
		_kit.pipe(Vector3(-0.7, AXLE_Y + 0.06, zc + 0.16), Vector3(0.7, FRAME_Y - 0.2, zc + 0.16),
				0.04, 5, CHASSIS.lightened(0.03))
	# Driveshaft running between the two diffs, under the frame.
	_kit.pipe(Vector3(0.24, AXLE_Y + 0.08, AXLE_F + 0.3), Vector3(0.24, AXLE_Y + 0.12, AXLE_R - 0.3),
			0.05, 6, CHROME.darkened(0.15))
	var mesh := _kit.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	add_child(mi)


func _build_wheels() -> void:
	var wheel_mesh := _wheel_mesh()
	# (local x, z, is_front) — wide stance, ~4.2 m wheelbase.
	var spots := [
		[-TRACK, AXLE_F, true], [TRACK, AXLE_F, true],
		[-TRACK, AXLE_R, false], [TRACK, AXLE_R, false],
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


## A big off-road wheel on its axle (local X): a fat black tyre torus (outer edge = WHEEL_RADIUS)
## with chunky tread lugs, and a black beadlock rim with a ring of bolts — the mud-terrain look.
func _wheel_mesh() -> ArrayMesh:
	_kit.begin()
	var sides := 16
	var tube := 8
	var rt := 0.26                       # fat sidewall
	var half_w := 0.28                   # tyre half-width along the axle
	var R := WHEEL_RADIUS - rt            # tube centre, so the tyre's outer edge = WHEEL_RADIUS
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var c0 := Vector3(0, cos(a0), sin(a0))
		var c1 := Vector3(0, cos(a1), sin(a1))
		for j in tube:
			var b0 := TAU * float(j) / float(tube)
			var b1 := TAU * float(j + 1) / float(tube)
			var n0 := Vector3(sin(b0), 0, 0) * half_w
			var n1 := Vector3(sin(b1), 0, 0) * half_w
			var p00 := c0 * (R + cos(b0) * rt) + n0
			var p01 := c0 * (R + cos(b1) * rt) + n1
			var p10 := c1 * (R + cos(b0) * rt) + n0
			var p11 := c1 * (R + cos(b1) * rt) + n1
			_kit.quad(p00, p10, p11, p01, TIRE.lightened(0.05 * (j % 2)))
	# Chunky tread lugs around the tread face.
	for k in 12:
		var a := TAU * float(k) / 12.0
		var dir := Vector3(0, cos(a), sin(a))
		_kit.box(dir * (WHEEL_RADIUS - 0.03), Vector3(half_w * 1.7, 0.14, 0.16), TIRE.lightened(0.09))
	# Black beadlock rim across the axle, hub cap, and a ring of bolts.
	_kit.pipe(Vector3(-0.13, 0, 0), Vector3(0.13, 0, 0), R * 0.78, 14, HUB)
	_kit.pipe(Vector3(-0.17, 0, 0), Vector3(0.17, 0, 0), 0.1, 8, HUB.lightened(0.1))
	for k in 10:
		var a := TAU * float(k) / 10.0
		_kit.box(Vector3(0.15, cos(a) * R * 0.66, sin(a) * R * 0.66), Vector3(0.05, 0.07, 0.07), HUB.lightened(0.18))
	return _kit.commit()
