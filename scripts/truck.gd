extends Node3D
class_name Truck
## A drivable truck for carting glue from the works into town to sell — a lifted monster crew-cab
## pickup after the Ram reference: a tall gunmetal body riding high on a big gap of exposed
## suspension (coilovers, solid axles, links) over huge Mammoth off-road tyres, with a bull-bar
## bumper, RAM-style grille, a roof-rack light bar, tow mirrors and a pickup bed. Built procedurally
## from MeshKit primitives; the four wheels roll and the fronts steer.
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
## Huge Mammoth-MT off-road tyre, ~1.72 m diameter, after the lifted-Ram reference — nearly as tall
## as the body side. The tyre's OUTER edge is WHEEL_RADIUS so it rolls right and sits on the ground.
const WHEEL_RADIUS := 0.86
## Layout (local space, y = 0 = ground, -Z = forward). The body rides HIGH at FRAME_Y on a tall
## open gap above the axles at AXLE_Y that the exposed suspension bridges — the monster stance.
## The tyres sit well outboard of the body on a wide track (they stick out past the fenders), and
## the wheelbase is long so the truck reads longer than it is tall.
const TRACK := 1.48          # wheel-centre half-track (wide stance, tyres proud of the body)
const AXLE_F := -2.35        # front axle z
const AXLE_R := 2.75         # rear axle z (long ~5.1 m wheelbase)
const AXLE_Y := 0.86         # axle centre height (= WHEEL_RADIUS)
const FRAME_Y := 2.12        # underside of the body / fender line — a big lift over the ~1.72 m tyres

const CAB := Color(0.50, 0.51, 0.55)     # gunmetal body
const CAB_DK := Color(0.36, 0.37, 0.41)  # shaded body / trim
const BED := Color(0.28, 0.29, 0.32)     # bed liner
const CHASSIS := Color(0.11, 0.11, 0.13) # frame, suspension, bumper, flares (matte black)
const GLASS := Color(0.19, 0.24, 0.28)   # dark tinted glass
const CHROME := Color(0.70, 0.71, 0.74)
const TIRE := Color(0.07, 0.07, 0.09)
const HUB := Color(0.15, 0.15, 0.17)     # black beadlock wheel
const SPRING := Color(0.74, 0.60, 0.28)  # FOX coilover spring (gold), a bright accent in the gap
const LAMP := Color(0.96, 0.94, 0.74)
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
	var drop := global_position + right * 4.6 + Vector3.UP * 1.0
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
	var l := 2.6
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
	var want := global_position + b.y * 6.6 - b.z * 13.5
	if snap or delta <= 0.0:
		_camera.global_position = want
	else:
		_camera.global_position = _camera.global_position.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	_camera.look_at(global_position + b.y * 2.6, Vector3.UP)


func _roll_wheels(delta: float) -> void:
	var spin := _speed * delta / WHEEL_RADIUS
	for w: Node3D in _wheels:
		w.rotate_x(spin)
	for p: Node3D in _steer_pivots:
		p.rotation.y = _steer * 0.5


# ---- model ------------------------------------------------------------------

## A lifted crew-cab off-road pickup, faithfully after the Ram reference: a tall, slab-sided body
## riding high on a big open gap of exposed suspension over ~1.5 m Mammoth tyres. Front (-Z) to
## back: heavy steel bull-bar bumper (winch, shackles, light pods), tall RAM grille, hood, a
## four-door crew cab under a roof-rack light bar, then a pickup bed. Origin = ground (y = 0).
func _build_body() -> void:
	_kit.begin()
	var lo := FRAME_Y            # body underside / rocker line (a big lift over the axles)
	var belt := 2.95            # bottom of the thin side-glass ribbon
	var roof := 3.45            # roofline
	var hw := 1.02              # body half-width
	var cab_f := -2.3           # cab front (cowl)
	var cab_b := 0.45           # cab back
	var bed_b := 3.2            # tailgate

	# --- Lifted ladder frame (narrow, inboard), cross-members, transfer-case skid. ---
	for sx in [-0.46, 0.46]:
		_kit.box(Vector3(sx, lo - 0.15, 0.1), Vector3(0.16, 0.26, 6.9), CHASSIS.lightened(0.05))
	for cz in [AXLE_F, -0.6, 1.3, AXLE_R]:
		_kit.box(Vector3(0, lo - 0.17, cz), Vector3(1.0, 0.14, 0.2), CHASSIS.lightened(0.08))
	_kit.box(Vector3(0.1, lo - 0.36, -0.3), Vector3(0.62, 0.5, 0.9), CHASSIS.lightened(0.05))    # t-case

	# --- Crew cab: tall FULL-WIDTH slab body under a thin glass ribbon; long hood ahead. ---
	_kit.box(Vector3(0, (lo + roof) * 0.5, (cab_f + cab_b) * 0.5), Vector3(2.0 * hw, roof - lo, cab_b - cab_f), CAB)  # cab
	_kit.box(Vector3(0, roof, (cab_f + cab_b) * 0.5 + 0.05), Vector3(1.98, 0.12, cab_b - cab_f - 0.2), CAB_DK)        # roof
	_kit.box(Vector3(0, (lo + 0.14 + belt) * 0.5, -2.92), Vector3(1.98, belt - lo - 0.14, 1.24), CAB)                # hood
	_kit.box(Vector3(0, belt - 0.06, -2.98), Vector3(1.5, 0.16, 0.5), CAB_DK)                     # hood bulge
	# Windscreen (cowl -> roof front) and backlight.
	_kit.quad(Vector3(-0.94, belt, cab_f), Vector3(0.94, belt, cab_f),
			Vector3(0.92, roof - 0.07, cab_f + 0.5), Vector3(-0.92, roof - 0.07, cab_f + 0.5), GLASS)
	_kit.box(Vector3(0, belt + 0.2, cab_b - 0.04), Vector3(1.7, 0.4, 0.06), GLASS)               # backlight
	# Side glass: thin front + rear door ribbon each side.
	for sx in [-hw - 0.005, hw + 0.005]:
		_kit.box(Vector3(sx, belt + 0.2, -1.4), Vector3(0.04, 0.4, 1.02), GLASS)                 # front door
		_kit.box(Vector3(sx, belt + 0.2, -0.15), Vector3(0.04, 0.4, 1.02), GLASS)                # rear door
	# Tow mirrors on stalks, sticking out past the body.
	for sx in [-hw, hw]:
		_kit.box(Vector3(sx + signf(sx) * 0.2, belt - 0.12, cab_f + 0.1), Vector3(0.18, 0.36, 0.14), CAB_DK)
		_kit.box(Vector3(sx + signf(sx) * 0.36, belt - 0.06, cab_f + 0.1), Vector3(0.1, 0.4, 0.28), CAB_DK)

	# --- Front: dominant RAM grille block, flanking headlights, heavy bumper + bull-bar hoop. ---
	_kit.box(Vector3(0, 2.72, -3.56), Vector3(1.02, 0.48, 0.16), CHASSIS.lightened(0.11))        # grille block
	for gy in [2.58, 2.72, 2.86]:
		_kit.box(Vector3(0, gy, -3.63), Vector3(0.86, 0.1, 0.06), CHROME.darkened(0.05))         # grille slats
	for sx in [-0.76, 0.76]:
		_kit.box(Vector3(sx, 2.74, -3.52), Vector3(0.42, 0.34, 0.1), LAMP)                       # headlight
	_kit.box(Vector3(0, 2.24, -3.66), Vector3(2.08, 0.5, 0.32), CHASSIS.lightened(0.02))         # steel bumper
	_kit.box(Vector3(0, 2.28, -3.82), Vector3(0.7, 0.28, 0.14), CHASSIS.lightened(0.09))         # winch
	_kit.box(Vector3(0, 2.28, -3.9), Vector3(0.36, 0.08, 0.04), CHROME)                          # fairlead
	for sx in [-0.42, 0.42]:
		_kit.box(Vector3(sx, 2.06, -3.84), Vector3(0.1, 0.18, 0.06), CHROME)                     # D-ring shackle
	for sx in [-0.94, 0.94]:
		_kit.box(Vector3(sx, 2.22, -3.78), Vector3(0.22, 0.22, 0.06), LAMP)                      # bumper light pod
	# Tubular bull-bar hoop standing proud of the grille.
	for sx in [-0.52, 0.52]:
		_kit.pipe(Vector3(sx, 2.48, -3.8), Vector3(sx, 3.2, -3.68), 0.05, 6, CHASSIS.lightened(0.09))
	_kit.pipe(Vector3(-0.52, 3.2, -3.68), Vector3(0.52, 3.2, -3.68), 0.05, 6, CHASSIS.lightened(0.09))
	_kit.pipe(Vector3(0, 2.48, -3.82), Vector3(0, 3.2, -3.68), 0.05, 6, CHASSIS.lightened(0.09))

	# --- Pickup bed: floor, tall bedsides stepped down from the cab, tailgate, GLUE decal, lights. ---
	var bed_c := (cab_b + bed_b) * 0.5 + 0.1
	var bed_len := bed_b - cab_b - 0.1
	_kit.box(Vector3(0, lo + 0.14, bed_c), Vector3(2.0 * hw, 0.16, bed_len), BED)                # bed floor
	for sx in [-hw + 0.02, hw - 0.02]:
		_kit.box(Vector3(sx, belt - 0.36, bed_c), Vector3(0.12, belt - lo - 0.3, bed_len), CAB)  # bedside
	_kit.box(Vector3(0, belt - 0.36, bed_b), Vector3(2.0 * hw, belt - lo - 0.3, 0.12), CAB)      # tailgate
	_kit.box(Vector3(0, belt - 0.42, bed_b + 0.07), Vector3(1.3, 0.44, 0.05), SIGN)             # GLUE decal
	for sx in [-0.78, 0.78]:
		_kit.box(Vector3(sx, belt - 0.16, bed_b - 0.02), Vector3(0.34, 0.42, 0.06), CAB_DK)      # taillight

	# --- Black arched fender flares bulging over each wheel (outboard of the bodywork). ---
	for zc in [AXLE_F, AXLE_R]:
		for sx in [-1.18, 1.18]:
			_kit.box(Vector3(sx, lo + 0.06, zc), Vector3(0.52, 0.24, 1.98), CHASSIS.lightened(0.03))  # arch top
			for dz in [-0.9, 0.9]:
				_kit.box(Vector3(sx, lo - 0.3, zc + dz), Vector3(0.48, 0.62, 0.26), CHASSIS.lightened(0.02))  # return

	# --- Roof rack + a wide triple light bar raised on brackets across the front of the roof. ---
	_kit.box(Vector3(0, roof + 0.08, (cab_f + cab_b) * 0.5 + 0.1), Vector3(1.9, 0.06, cab_b - cab_f - 0.1), CHASSIS.lightened(0.05))
	for sx in [-0.92, 0.92]:
		_kit.box(Vector3(sx, roof + 0.06, (cab_f + cab_b) * 0.5), Vector3(0.06, 0.12, cab_b - cab_f - 0.2), CHASSIS)
	for sx in [-0.72, 0.72]:
		_kit.box(Vector3(sx, roof + 0.16, cab_f + 0.12), Vector3(0.08, 0.18, 0.06), CHASSIS.lightened(0.05))  # bracket
	for lx in [-0.72, 0.0, 0.72]:
		_kit.box(Vector3(lx, roof + 0.28, cab_f + 0.1), Vector3(0.66, 0.12, 0.14), LAMP)         # triple light bar (wide)

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
		var inner := signf(zc)                      # +1 rear, -1 front: link toward the wheelbase centre
		# Solid axle tube across the full track, with a big round diff pumpkin dead-centre.
		_kit.pipe(Vector3(-TRACK, AXLE_Y, zc), Vector3(TRACK, AXLE_Y, zc), 0.13, 8, CHASSIS.lightened(0.14))
		_kit.sphere(Vector3(0.28, AXLE_Y, zc), 0.32, 7, 9, CHASSIS.lightened(0.18))
		_kit.pipe(Vector3(0.28, AXLE_Y, zc - inner * 0.3), Vector3(0.28, AXLE_Y, zc - inner * 0.6), 0.1, 6, CHASSIS.lightened(0.14))  # diff snout
		# FOX coilovers: a tall gold spring each side from the axle up to the frame (near vertical).
		for sx in [-0.62, 0.62]:
			_kit.pipe(Vector3(sx, AXLE_Y + 0.05, zc), Vector3(sx * 0.82, FRAME_Y + 0.06, zc + inner * 0.14),
					0.11, 8, SPRING)
			_kit.box(Vector3(sx * 0.82, FRAME_Y + 0.02, zc + inner * 0.14), Vector3(0.2, 0.12, 0.2), CHASSIS.lightened(0.1))  # top mount
		# Radius-arm links: axle down to a frame mount toward the wheelbase centre.
		for sx in [-0.44, 0.44]:
			_kit.pipe(Vector3(sx, AXLE_Y - 0.06, zc), Vector3(sx * 0.78, FRAME_Y - 0.3, zc + inner * 1.2),
					0.08, 6, CHASSIS.lightened(0.12))
		# Track bar, angled across the axle.
		_kit.pipe(Vector3(-0.66, AXLE_Y + 0.02, zc - inner * 0.26), Vector3(0.7, FRAME_Y - 0.34, zc - inner * 0.26),
				0.06, 6, CHASSIS.lightened(0.12))
	# Front steering: a tie rod across ahead of the axle, with a FOX stabilizer damper on it.
	_kit.pipe(Vector3(-0.9, AXLE_Y + 0.08, AXLE_F - 0.32), Vector3(0.9, AXLE_Y + 0.08, AXLE_F - 0.32), 0.06, 6, CHASSIS.lightened(0.13))
	_kit.pipe(Vector3(-0.12, AXLE_Y + 0.16, AXLE_F - 0.36), Vector3(0.5, AXLE_Y + 0.16, AXLE_F - 0.36), 0.06, 6, SPRING.darkened(0.15))
	# Driveshaft between the two diffs, under the frame.
	_kit.pipe(Vector3(0.28, AXLE_Y + 0.08, AXLE_F + 0.4), Vector3(0.28, AXLE_Y + 0.12, AXLE_R - 0.4), 0.06, 6, CHROME.darkened(0.15))
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
	var sides := 20
	var tube := 8
	var rt := 0.34                       # fat sidewall bulge
	var half_w := 0.42                   # tyre half-width along the axle (very wide Mammoth)
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
	# Big blocky tread lugs that PROTRUDE past the tyre so the silhouette scallops (Mammoth-MT).
	for k in 20:
		var a := TAU * float(k) / 20.0
		var dir := Vector3(0, cos(a), sin(a))
		var off := half_w * 0.5 * (1.0 if k % 2 == 0 else -1.0)
		_kit.box(dir * (WHEEL_RADIUS - 0.04) + Vector3(off, 0, 0), Vector3(half_w * 0.86, 0.24, 0.26), TIRE.lightened(0.12))
	# Beadlock wheel: a deep black rim face, a BRIGHT machined bead ring + bolt heads (the contrast
	# that makes the wheel read as a disc, not a void), and a hub.
	_kit.pipe(Vector3(-0.12, 0, 0), Vector3(0.12, 0, 0), R * 0.7, 16, HUB)                          # rim face
	_kit.pipe(Vector3(0.12, 0, 0), Vector3(0.2, 0, 0), R * 0.82, 18, HUB.lightened(0.42))          # bright bead ring
	_kit.pipe(Vector3(-0.16, 0, 0), Vector3(0.16, 0, 0), 0.14, 8, HUB.lightened(0.3))              # hub cap
	for k in 12:
		var a := TAU * float(k) / 12.0
		_kit.box(Vector3(0.21, cos(a) * R * 0.72, sin(a) * R * 0.72), Vector3(0.05, 0.07, 0.07), HUB.lightened(0.55))  # bright bolts
	return _kit.commit()
