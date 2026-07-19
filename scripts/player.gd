extends CharacterBody3D
class_name Player
## First-person controller with the farm's one bit of agency bolted on: a heart wand to
## clout horses with, and the hands to carry a knocked-out one to the glue factory.
##
## WASD to move, mouse to look, Shift to sprint, Space to jump, Esc to release the mouse.
## Left-click swings the wand; a horse in front takes the hit and, after a few, drops into a
## ragdoll. E (or right-click) picks a ragdoll up, and pressing it again by the factory
## intake feeds it in — or drops it if you are nowhere near.

@export var walk_speed: float = 9.0
@export var sprint_speed: float = 18.0
@export var jump_velocity: float = 7.0
@export var gravity: float = 22.0
@export var mouse_sensitivity: float = 0.0025
## Look sensitivity for a touch drag, in radians per screen unit (the 640x360 virtual space).
@export var touch_look_sensitivity: float = 0.006
## Camera far plane — pushed out for the long draw distance.
@export var camera_far: float = 5000.0

## How far the wand reaches, and how tight the swing's forward cone is (a dot product against
## the look direction — ~0.5 is about a 60-degree half-angle).
const HIT_REACH := 4.5
const HIT_CONE := 0.5
## How near a ragdoll has to be to grab it, and how tightly the grab has to be aimed at it.
## You grab what the crosshair is on, Half-Life style, not merely the nearest body.
const PICKUP_REACH := 4.0
const PICKUP_CONE := 0.55
## Where a carried cow floats relative to the camera. Held well out ahead and slung low so
## the long body clears the crosshair, and turned side-on (see _drive_carried) so it lies
## across the view rather than pointing down it — you can see past it while you carry it.
const CARRY_DISTANCE := 3.8
const CARRY_DROP := 1.15
## Half-Life carry, all as velocities the player writes onto the held RigidBody each frame:
## STIFFNESS pulls it to the hold point (capped by MAX_SPEED so it never rockets), and TURN
## rights it to face forward (capped by TURN_MAX). It stays dynamic throughout, so it keeps
## colliding with the world while you carry it.
const CARRY_STIFFNESS := 14.0
const CARRY_MAX_SPEED := 22.0
const CARRY_TURN := 8.0
const CARRY_TURN_MAX := 12.0
## Parting velocities: a gentle set-down on drop, a proper punt on throw.
const DROP_SPEED := 1.5
const THROW_SPEED := 12.0
## Swing duration, seconds. Longer than a flick so the arc has time to read.
const SWING_TIME := 0.42

## Glue trade. How near the factory dock you load finished sacks, how near a town market you
## sell them, how much each sack fetches, and how near the truck you have to be to climb in.
const COLLECT_RADIUS := 8.0
const SELL_RADIUS := 8.0
const TRUCK_ENTER_RADIUS := 5.5
const GLUE_PRICE := 12

const WAND_SCENE := "res://models/heart_wand.glb"
## Resting pose of the wand in the camera's corner, and the height it is fitted to. The wand is
## held out ahead pointing away from you — the heart (the model's +Y tip) leads, so both the
## rest pose and the swing send it into the world rather than back at your face. Bigger than it
## was (0.42) so it actually reads as a wand and not a splinter.
const WAND_REST := Vector3(0.30, -0.30, -0.55)
const WAND_REST_ROT := Vector3(-58.0, 12.0, 8.0)
const WAND_HEIGHT := 0.62
## The swing is a big, multi-axis arc, not a flat pitch: a quick wind-up, then a down-and-across
## chop with a twist and a forward lunge, easing into a follow-through. Pitch drives the tip toward
## the ground (negative), yaw sweeps it across the view, roll twists the heart over, and MOVE
## lunges the whole wand down-left-forward through the arc before it settles back to rest.
const SWING_PITCH := -98.0
const SWING_YAW := -30.0
const SWING_ROLL := 26.0
const SWING_WINDUP := 24.0
const SWING_MOVE := Vector3(-0.06, -0.15, -0.24)

## Gold handle, red heart.
const WAND_GOLD := Color(0.83, 0.63, 0.19)
const WAND_RED := Color(0.78, 0.11, 0.11)

@onready var camera: Camera3D = $Camera3D

var _pitch: float = 0.0
var _wand: Node3D
var _swing: float = 0.0
var _carried: HorseRagdoll
## Wand effects: a tip marker the hearts puff from, and the gravity-gun pickup ribbon.
var _wand_tip: Node3D
var _hearts: CPUParticles3D
var _ribbon: MeshInstance3D
var _ribbon_mesh: ImmediateMesh
var _ribbon_t: float = 0.0

## The glue economy: sacks currently carried and money earned. The truck the player is driving,
## if any (while set, movement is handed to it and the player rides along as the streaming
## anchor so terrain, grass and trees keep building around the truck).
var glue: int = 0
var money: int = 0
var _driving: Truck

## HUD. The DMG capsule readouts and the main menu live on the GBUI layer; the crosshair and the
## contextual prompt stay on their own layer under it.
var _gbui: GBUI
var _prompt_label: Label
var _menu_open := false
## Rising-edge memory for D-pad/stick menu navigation (up = -1, down = +1).
var _nav_prev := 0

## On-screen touch controls, present only on touch devices (phones). Null on desktop.
var _touch: TouchControls

## Where R sends the player, and the terrain to rebuild solid ground around it on the way.
## Both are set by main.gd once the world exists; safe to leave unset (R just no-ops).
var spawn_point: Vector3
var terrain: TerrainManager


func _ready() -> void:
	# Joined so the outer shell can find us across the game SubViewport boundary (same SceneTree).
	add_to_group("player")
	camera.far = camera_far
	_tune_collision()
	# Pick the input scheme. In the Game Boy web shell the on-screen pad drives the game (and the
	# mouse is left alone so it never fights the shell). On a phone, raise the in-engine touch
	# controls. On desktop, capture the mouse as before (but never when headless).
	if _use_gb_shell():
		_spawn_gb_shell_input()
	elif _is_mobile():
		# The native portrait console (shell.gd) builds the controls OUTSIDE the game SubViewport and
		# hands them over via set_input_source(); do not raise the old in-viewport faceplate here.
		pass
	elif DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_spawn_wand()
	_spawn_crosshair()


## Whether this build should show touch controls: a real touch device, or an explicitly mobile
## export (so it is right in the APK even on a device that also reports a mouse).
func _is_mobile() -> bool:
	# Defer to the one predicate the shell also uses, so the two never drift: the shell builds the
	# console exactly when this is true, and we skip self-spawning to await its injection.
	return TouchControls.is_console()


## Whether input comes from the Game Boy HTML shell. True for any web export (the web build only
## ever runs inside that shell); SLOPFARM_GBSHELL forces it on for previewing on a desktop build.
func _use_gb_shell() -> bool:
	return OS.has_feature("web") or OS.has_environment("SLOPFARM_GBSHELL")


## Reads the shell's on-screen pad through GameBoyUI and drives the player through the same
## surface the touch controls use, so nothing downstream (movement, the truck, the actions) has
## to know the difference. No CanvasLayer: it draws nothing.
func _spawn_gb_shell_input() -> void:
	_touch = GBShellInput.new()
	add_child(_touch)
	_touch.hit_pressed.connect(_primary_action)
	_touch.interact_pressed.connect(_interact)
	_touch.truck_pressed.connect(_toggle_truck)
	_touch.respawn_pressed.connect(_respawn)
	_touch.menu_pressed.connect(_toggle_menu)


## Called by the native portrait console (shell.gd) to hand us the input source it built outside the
## game SubViewport. A ShellInput IS-A TouchControls, so this mirrors what the self-spawned schemes
## wire up and nothing downstream (movement, look, truck, the actions) knows the difference.
func set_input_source(src: TouchControls) -> void:
	_touch = src
	src.hit_pressed.connect(_primary_action)
	src.interact_pressed.connect(_interact)
	src.truck_pressed.connect(_toggle_truck)
	src.respawn_pressed.connect(_respawn)
	src.menu_pressed.connect(_toggle_menu)


## Raises the on-screen controls on its own CanvasLayer, ABOVE the dither post-process (100) so
## the buttons stay crisp in front of the palette snap, and wires each button to its action.
## Unused on the native console path (shell.gd injects instead); kept for reference/fallback.
func _spawn_touch_controls() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 115
	add_child(layer)
	_touch = TouchControls.new()
	layer.add_child(_touch)
	_touch.hit_pressed.connect(_primary_action)
	_touch.interact_pressed.connect(_interact)
	_touch.truck_pressed.connect(_toggle_truck)
	_touch.respawn_pressed.connect(_respawn)
	_touch.menu_pressed.connect(_toggle_menu)


## Keeps the capsule from snagging. Two parts: a slightly fatter safe margin and a longer floor
## snap so it slides off trimesh corners and stair-steps instead of catching on seams; and the
## player's own physics layer (3), scanning only the world (1), so a knocked-out cow (layer 2)
## can never shove it into geometry. The failsafe for whatever still wedges it is _respawn.
func _tune_collision() -> void:
	collision_layer = 0b100
	collision_mask = 0b001
	safe_margin = 0.04
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(50.0)
	wall_min_slide_angle = deg_to_rad(12.0)
	max_slides = 6
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING


func _unhandled_input(event: InputEvent) -> void:
	# While the menu is up it owns the keyboard: up/down move the selection, Enter/Space confirm,
	# Esc/Tab/Backspace close. (Pad and web-shell navigation come per-frame from move_vector.)
	if _menu_open and event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_UP, KEY_W:
				_gbui.nav(-1)
			KEY_DOWN, KEY_S:
				_gbui.nav(1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_gbui.activate()
			KEY_TAB, KEY_ESCAPE, KEY_BACKSPACE:
				_toggle_menu()
		return

	# Mouse-look and click-to-capture belong to the plain desktop scheme only, and never while the
	# menu is up. When an on-screen input layer is present — the phone touch pad or the Game Boy
	# shell — that pad drives the camera, and grabbing pointer-lock here would fight the shell, so
	# the mouse is left alone.
	if _touch == null and not _menu_open:
		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var motion := event as InputEventMouseMotion
			rotate_y(-motion.relative.x * mouse_sensitivity)
			_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.4, 1.4)
			camera.rotation.x = _pitch
			return
		if event.is_action_pressed(&"ui_cancel"):
			# Toggle the mouse capture (Esc).
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			var button := event as InputEventMouseButton
			# A click outside capture just recaptures the mouse; it is not also a swing.
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				return
			if button.button_index == MOUSE_BUTTON_LEFT:
				_primary_action()
			elif button.button_index == MOUSE_BUTTON_RIGHT:
				_interact()
			return
	# The action keys work in every scheme, so a real keyboard drives the game on desktop and in
	# the web shell alike.
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).physical_keycode
		if key == KEY_E:
			_interact()
		elif key == KEY_F:
			# Climb into the nearest truck, or step out of the one you are driving.
			_toggle_truck()
		elif key == KEY_R:
			# The failsafe: warp back to the start if you ever get wedged in the scenery.
			_respawn()
		elif key == KEY_TAB:
			# Raise the DMG main menu (Start, on the console pad and web shell).
			_toggle_menu()


## The primary action (left-click, or the touch HIT button): swing the wand, or punt a carried
## cow. Idle behind the wheel.
func _primary_action() -> void:
	# With the menu up, HIT (A / left-click) confirms the selected entry instead of swinging.
	if _menu_open:
		_gbui.activate()
		return
	if _driving != null:
		return
	if _carried != null and is_instance_valid(_carried):
		_throw()
	else:
		_attack()


## START (console pill / web START / Tab): raise or dismiss the DMG main menu. Opening it drops any
## mouse capture and freezes the player until it is closed.
func _toggle_menu() -> void:
	if _gbui == null:
		return
	_menu_open = not _menu_open
	_gbui.toggle_menu()
	_nav_prev = 0
	if _menu_open and _touch == null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Result of confirming a menu entry: the two action rows do something, the two info rows just stay
## on screen.
func _on_menu_item(id: String) -> void:
	match id:
		"RESPAWN":
			_toggle_menu()
			_respawn()
		"RESUME":
			_toggle_menu()


func _process(delta: float) -> void:
	# While the menu is open the pad/stick drives the selection instead of the camera: push up/down
	# past a deadzone to step one entry, released before it repeats (rising-edge only).
	if _menu_open:
		if _touch != null:
			_touch.take_look()   # drain look so it does not snap the camera when the menu closes
			var v := _touch.move_vector.y
			var dir := 1 if v > 0.5 else (-1 if v < -0.5 else 0)
			if dir != 0 and dir != _nav_prev:
				_gbui.nav(-dir)   # stick up (+y forward) moves the selection up (toward index 0)
			_nav_prev = dir
		_update_hud()
		return
	# Apply any touch look-drag accumulated this frame, mirroring the mouse look.
	if _touch != null:
		var look := _touch.take_look()
		if look != Vector2.ZERO:
			rotate_y(-look.x * touch_look_sensitivity)
			_pitch = clampf(_pitch - look.y * touch_look_sensitivity, -1.4, 1.4)
			camera.rotation.x = _pitch
	# Swing the wand through its organic arc, or hold it at rest.
	if _wand != null:
		if _swing > 0.0:
			_swing -= delta
			var t := 1.0 - clampf(_swing / SWING_TIME, 0.0, 1.0)   # 0 -> 1 over the swing
			# A brief wind-up (tip pulls up/back), then the main arc — delayed so the wind-up leads,
			# and a smooth sine so it accelerates down and eases through the follow-through.
			var wind := 1.0 - smoothstep(0.0, 0.16, t)
			var arc := sin(clampf((t - 0.10) / 0.90, 0.0, 1.0) * PI)
			_wand.rotation_degrees = WAND_REST_ROT + Vector3(
					SWING_PITCH * arc - SWING_WINDUP * wind, SWING_YAW * arc, SWING_ROLL * arc)
			_wand.position = WAND_REST + SWING_MOVE * arc + Vector3.UP * (0.05 * wind)
		else:
			_wand.rotation_degrees = WAND_REST_ROT
			_wand.position = WAND_REST
	# Keep the (top-level) heart emitter parked on the wand tip in world space.
	if _hearts != null and _wand_tip != null:
		_hearts.global_position = _wand_tip.global_position
	_update_ribbon()
	_update_hud()


## Refreshes the money/glue readout and the contextual prompt for whatever is in reach.
func _update_hud() -> void:
	if _gbui == null:
		return
	_gbui.set_money(money)
	_gbui.set_glue(glue)
	# The contextual prompt is hidden behind the menu while it is open.
	_prompt_label.text = "" if _menu_open else _context_prompt()


func _context_prompt() -> String:
	if _driving != null:
		return "F  step out of truck"
	if _carried != null and is_instance_valid(_carried):
		return "E  feed intake     LMB  throw"
	# Loading glue at the factory dock.
	for node in get_tree().get_nodes_in_group("glue_factory"):
		var factory := node as GlueFactory
		if factory != null and global_position.distance_to(factory.dock_world()) <= COLLECT_RADIUS:
			if factory.ready_glue() > 0:
				return "E  load %d sacks of glue" % factory.ready_glue()
	# Selling at a market.
	if glue > 0:
		for node in get_tree().get_nodes_in_group("glue_market"):
			var marker := node as Node3D
			if marker != null and global_position.distance_to(marker.global_position) <= SELL_RADIUS:
				return "E  sell %d sacks  ($%d)" % [glue, glue * GLUE_PRICE]
	# Boarding a truck.
	for node in get_tree().get_nodes_in_group("truck"):
		var truck := node as Truck
		if truck != null and global_position.distance_to(truck.global_position) <= TRUCK_ENTER_RADIUS:
			return "F  drive truck"
	return ""


func _physics_process(delta: float) -> void:
	# The menu freezes play: bleed off horizontal motion and let gravity settle the player, but take
	# no move/jump input while it is up.
	if _menu_open:
		velocity.x = move_toward(velocity.x, 0.0, 40.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 40.0 * delta)
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		return
	# While driving, hand movement to the truck and ride along on top of it. The player is the
	# world's streaming anchor, so pinning it to the truck is what keeps terrain, grass and trees
	# building around the truck as it drives off toward the towns.
	if _driving != null:
		if is_instance_valid(_driving):
			velocity = Vector3.ZERO
			global_position = _driving.global_position + Vector3.UP * 1.0
			return
		_driving = null

	var jump := Input.is_physical_key_pressed(KEY_SPACE) or (_touch != null and _touch.jump_held)
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif jump:
		velocity.y = jump_velocity

	var input := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		input.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input.y += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		input.x += 1.0
	# Fold in the touch thumb-stick (its y is forward-positive; ours is forward-negative).
	if _touch != null:
		input.x += _touch.move_vector.x
		input.y -= _touch.move_vector.y
	# Clamp rather than normalize, so a half-pushed stick still walks at half pace.
	if input.length() > 1.0:
		input = input.normalized()

	var sprinting := Input.is_physical_key_pressed(KEY_SHIFT) or (_touch != null and _touch.sprint)
	var speed := sprint_speed if sprinting else walk_speed
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()

	# A carried cow rides in front of the camera. Driven after move_and_slide so it does not
	# lag a frame behind the player it is following.
	if _carried != null:
		if is_instance_valid(_carried):
			_drive_carried()
		else:
			_carried = null


## Half-Life hold: instead of teleporting the body to the hold point (which would drag it
## through walls), push it there with velocity so physics still stops it against the world.
## STIFFNESS closes the gap, TURN rights it to face forward, both capped so a grab from across
## the reach eases in rather than snapping. Because it stays a live body, its limbs keep
## flopping and it bumps off anything you swing it into.
func _drive_carried() -> void:
	var forward := -camera.global_transform.basis.z
	var hold := camera.global_position + forward * CARRY_DISTANCE + Vector3.DOWN * CARRY_DROP
	var to := hold - _carried.global_position
	var vel := to * CARRY_STIFFNESS
	if vel.length() > CARRY_MAX_SPEED:
		vel = vel.normalized() * CARRY_MAX_SPEED
	_carried.linear_velocity = vel

	# Right it toward facing the way the player faces, upright. Angular velocity from the
	# shortest-arc error, so it turns smoothly and can still be jostled by a collision.
	# Turned 90 degrees off the player's facing so the body lies ACROSS the view — nose-to-tail
	# spanning left-to-right in front of you rather than jutting down your sightline.
	var target := Basis(Vector3.UP, rotation.y + PI * 0.5).get_rotation_quaternion()
	var current := _carried.global_transform.basis.get_rotation_quaternion()
	var error := (target * current.inverse()).normalized()
	if error.w < 0.0:
		error = -error
	var angle := 2.0 * acos(clampf(error.w, -1.0, 1.0))
	var axis := Vector3(error.x, error.y, error.z)
	if axis.length() > 1e-4 and angle > 1e-4:
		var spin := axis.normalized() * (angle * CARRY_TURN)
		if spin.length() > CARRY_TURN_MAX:
			spin = spin.normalized() * CARRY_TURN_MAX
		_carried.angular_velocity = spin
	else:
		_carried.angular_velocity = Vector3.ZERO


# ---- wand pickup ribbon -----------------------------------------------------

## Shown only while carrying: a pink energy ribbon from the wand tip to the body, redrawn each
## frame — wavy and pulsing, billboarded at the camera, like the Half-Life 2 gravity gun's beam.
func _update_ribbon() -> void:
	if _ribbon == null:
		return
	var active := _wand_tip != null and _carried != null and is_instance_valid(_carried)
	_ribbon.visible = active
	if not active:
		return
	_ribbon_t += get_process_delta_time() * 10.0
	_build_ribbon(_wand_tip.global_position, _carried.global_position + Vector3.UP * 0.25)


func _build_ribbon(a: Vector3, b: Vector3) -> void:
	_ribbon_mesh.clear_surfaces()
	var beam := b - a
	var length := beam.length()
	if length < 0.05:
		return
	var dir := beam / length
	var cam := camera.global_position
	const SEGS := 16
	_ribbon_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in SEGS + 1:
		var f := float(i) / float(SEGS)
		var p := a.lerp(b, f)
		# Ribbon lies in the plane facing the camera: `side` gives it width, `up` carries the wander.
		var view := (cam - p).normalized()
		var side := dir.cross(view)
		side = side.normalized() if side.length() > 1e-4 else Vector3.RIGHT
		var up := side.cross(dir).normalized()
		var env := sin(f * PI)                          # fades the wander + width to zero at the ends
		var wig := (sin(f * 20.0 + _ribbon_t) * 0.06 + sin(f * 8.0 - _ribbon_t * 1.6) * 0.05) * length * 0.18 * env
		p += up * wig
		var w := 0.035 + 0.09 * env
		var pulse := 0.5 + 0.5 * sin(f * 26.0 - _ribbon_t * 3.0)
		var col := Color(1.0, 0.5, 0.78, 0.4 + 0.6 * pulse * env)
		_ribbon_mesh.surface_set_color(col)
		_ribbon_mesh.surface_add_vertex(p + side * w)
		_ribbon_mesh.surface_set_color(col)
		_ribbon_mesh.surface_add_vertex(p - side * w)
	_ribbon_mesh.surface_end()


# ---- actions ----------------------------------------------------------------

func _attack() -> void:
	if _swing <= 0.0:
		_swing = SWING_TIME
	# Heart particles puff out of the wand's tip on every swing. Park the (top-level) emitter on the
	# tip first, since restart() emits immediately at the emitter's current world position.
	if _hearts != null:
		if _wand_tip != null:
			_hearts.global_position = _wand_tip.global_position
		_hearts.restart()
		_hearts.emitting = true
	# The nearest living horse inside the wand's reach and forward cone takes the hit.
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var best: FarmAnimal = null
	var best_distance := HIT_REACH + 1.0
	for node in get_tree().get_nodes_in_group("horse"):
		var animal := node as FarmAnimal
		if animal == null:
			continue
		# Aim at the barrel, not the hooves, so looking at the animal counts as looking at it.
		# Half the old height: the cows are half the size they were.
		var to := animal.global_position + Vector3.UP * 0.5 - origin
		var distance := to.length()
		if distance > HIT_REACH or distance < 0.01:
			continue
		if forward.dot(to / distance) < HIT_CONE:
			continue
		if distance < best_distance:
			best_distance = distance
			best = animal
	if best != null:
		best.take_hit(forward)


## E / right-click. Behind the wheel it does nothing (F gets you out). Carrying a cow: feed the
## intake if you are on it, otherwise set it down. Otherwise, in order: load finished glue at the
## factory dock, sell your load at a town market, or grab the ragdoll you are looking at.
func _interact() -> void:
	# With the menu up, USE (B / E / right-click) backs out of it.
	if _menu_open:
		_toggle_menu()
		return
	if _driving != null:
		return
	if _carried != null and is_instance_valid(_carried):
		if _feed_carried():
			_carried.queue_free()
			_carried = null
			return
		var forward := -camera.global_transform.basis.z
		_carried.release(forward * DROP_SPEED + Vector3.UP * 0.5)
		_carried = null
		return
	if _try_load_glue():
		return
	if _try_sell_glue():
		return
	_pickup()


## Load finished sacks off the factory dock into the truck-load you carry. True if any moved.
func _try_load_glue() -> bool:
	for node in get_tree().get_nodes_in_group("glue_factory"):
		var factory := node as GlueFactory
		if factory == null:
			continue
		if global_position.distance_to(factory.dock_world()) <= COLLECT_RADIUS and factory.ready_glue() > 0:
			glue += factory.collect_glue()
			return true
	return false


## Sell the glue you are carrying at the nearest town market you are standing at. True if sold.
func _try_sell_glue() -> bool:
	if glue <= 0:
		return false
	for node in get_tree().get_nodes_in_group("glue_market"):
		var marker := node as Node3D
		if marker != null and global_position.distance_to(marker.global_position) <= SELL_RADIUS:
			money += glue * GLUE_PRICE
			glue = 0
			return true
	return false


## F: get into the nearest truck, or out of the one being driven. Entering hands the view to the
## truck's chase camera; leaving restores the first-person camera and drops the player beside it.
func _toggle_truck() -> void:
	if _driving != null and is_instance_valid(_driving):
		var drop := _driving.exit()
		_driving = null
		velocity = Vector3.ZERO
		global_position = drop
		camera.current = true
		return
	var best: Truck = null
	var best_d := TRUCK_ENTER_RADIUS
	for node in get_tree().get_nodes_in_group("truck"):
		var truck := node as Truck
		if truck == null:
			continue
		var d := global_position.distance_to(truck.global_position)
		if d < best_d:
			best_d = d
			best = truck
	if best != null:
		_driving = best
		best.enter(self, _touch)


## Left-click while carrying: punt the cow. Feeding still wins if you are right at the intake,
## so you can lob the last step into it; otherwise it sails off where you are looking.
func _throw() -> void:
	if _carried == null or not is_instance_valid(_carried):
		return
	if _feed_carried():
		_carried.queue_free()
		_carried = null
		return
	var forward := -camera.global_transform.basis.z
	_carried.release(forward * THROW_SPEED + Vector3.UP * 2.0)
	_carried = null


func _feed_carried() -> bool:
	var at := _carried.global_position
	for node in get_tree().get_nodes_in_group("glue_factory"):
		var factory := node as GlueFactory
		if factory != null and factory.try_feed(at):
			return true
	return false


## Grab the cow the crosshair is on — nearest ragdoll inside the reach AND the look cone, so
## you pick up what you are aiming at rather than whatever happens to be closest to the camera.
func _pickup() -> void:
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var best: HorseRagdoll = null
	var best_distance := PICKUP_REACH
	for node in get_tree().get_nodes_in_group("ragdoll"):
		var ragdoll := node as HorseRagdoll
		if ragdoll == null or ragdoll.is_carried():
			continue
		var to := ragdoll.global_position + Vector3.UP * 0.3 - origin
		var distance := to.length()
		if distance > PICKUP_REACH or distance < 0.01:
			continue
		if forward.dot(to / distance) < PICKUP_CONE:
			continue
		if distance < best_distance:
			best_distance = distance
			best = ragdoll
	if best != null:
		best.grab()
		_carried = best


## The failsafe (R): drop whatever you are holding and warp back to the start, rebuilding solid
## ground there first so you land on collision rather than falling through freshly-streamed
## terrain. This is the one guaranteed way out of anything the scenery manages to trap you in.
func _respawn() -> void:
	if _carried != null and is_instance_valid(_carried):
		_carried.release(Vector3.ZERO)
	_carried = null
	velocity = Vector3.ZERO
	var target := spawn_point
	if terrain != null:
		terrain.prime(target)
		target.y = terrain.height_at(target.x, target.z) + 3.0
	global_position = target


# ---- setup ------------------------------------------------------------------

func _spawn_wand() -> void:
	if not ResourceLoader.exists(WAND_SCENE):
		return
	var model := (load(WAND_SCENE) as PackedScene).instantiate() as Node3D
	_force_pixel_look(model)
	_paint_wand(model)
	# The swing rotates a PIVOT placed at the wand's near (handle) end — the end closest to the
	# player, opposite the +Y heart — so the wand swings from the hand and the heart tip sweeps the
	# arc, rather than spinning about the model's own centre. The model hangs off the pivot, dropped
	# so its base centre sits on the pivot origin.
	_wand = Node3D.new()
	camera.add_child(_wand)
	_wand.add_child(model)
	_fit_height(model, WAND_HEIGHT)
	var s := model.scale.x
	var b := _local_aabb(model)   # unscaled model bounds; scale by s to reach pivot (parent) space
	model.position = -Vector3(b.get_center().x, b.position.y, b.get_center().z) * s
	_wand.position = WAND_REST
	_wand.rotation_degrees = WAND_REST_ROT
	_spawn_wand_fx()


## Effects hung off the wand: a tip marker at the heart, a heart-particle puff for swings, and the
## pink pickup ribbon.
func _spawn_wand_fx() -> void:
	var bounds := _local_aabb(_wand)
	_wand_tip = Node3D.new()
	_wand_tip.position = Vector3(bounds.get_center().x, bounds.position.y + bounds.size.y, bounds.get_center().z)
	_wand.add_child(_wand_tip)

	_hearts = CPUParticles3D.new()
	_hearts.emitting = false
	_hearts.one_shot = true
	_hearts.explosiveness = 0.9
	_hearts.amount = 16
	_hearts.lifetime = 0.75
	_hearts.local_coords = false
	_hearts.direction = Vector3(0.0, 1.0, 0.0)
	_hearts.spread = 55.0
	_hearts.initial_velocity_min = 1.2
	_hearts.initial_velocity_max = 2.8
	_hearts.gravity = Vector3(0.0, -1.6, 0.0)
	# top_level so the wand's large model scale does NOT multiply the particle size; we drive its
	# world position to the tip each frame instead (see _process).
	_hearts.top_level = true
	# 75% smaller than they were (0.14/0.24).
	_hearts.scale_amount_min = 0.035
	_hearts.scale_amount_max = 0.06
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(0.7, 0.9))
	shrink.add_point(Vector2(1.0, 0.0))
	_hearts.scale_amount_curve = shrink
	_hearts.mesh = _heart_particle_mesh()
	# Parented to the UNSCALED camera (not the wand, which is scaled ~12x to size the model), so the
	# particles are their intended size; _process drives the emitter to the tip in world space.
	camera.add_child(_hearts)

	_ribbon_mesh = ImmediateMesh.new()
	_ribbon = MeshInstance3D.new()
	_ribbon.mesh = _ribbon_mesh
	_ribbon.material_override = _ribbon_material()
	_ribbon.top_level = true            # verts built in world space
	_ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ribbon.visible = false
	add_child(_ribbon)


func _heart_particle_mesh() -> Mesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var m := StandardMaterial3D.new()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = load("res://sprites/heart_particle.png")
	m.albedo_color = Color(1.0, 0.32, 0.5, 0.5)   # 50% opaque; the palette snaps the hue to a green
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	quad.material = m
	return quad


func _ribbon_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD    # energy glow
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1.0, 0.4, 0.72)          # pink
	return m


## Repaints the wand model: the shaft ("wand") gold and metallic, the "heart" a flat red. Set as
## surface overrides, which beat the .glb's own materials, and run after _force_pixel_look so the
## nearest-filter/double-sided house style is already on them and these just recolour.
func _paint_wand(node: Node) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		if node.name == "heart":
			mesh_instance.set_surface_override_material(0, _wand_mat(WAND_RED, 0.0, 0.55))
		elif node.name == "wand":
			mesh_instance.set_surface_override_material(0, _wand_mat(WAND_GOLD, 0.65, 0.35))
	for child in node.get_children():
		_paint_wand(child)


func _wand_mat(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = roughness
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## A minimal crosshair so the wand and the pickup can actually be aimed. Its own CanvasLayer,
## ABOVE the dither post-process (layer 100), so the HUD draws in front of the palette snap and
## stays crisp rather than being dithered and mapped to greens with the rest of the frame.
func _spawn_crosshair() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# These overlays are sized in the same 360-tall design space as the GBUI. The world SubViewport
	# now renders at 3x that, so scale every fixed offset and font size by the buffer/design ratio to
	# hold their apparent size (a clean 3x at 1080, a no-op at the old 360).
	var s := maxf(1.0, get_viewport().get_visible_rect().size.y / GBUI.DESIGN)
	var fs := int(round(8.0 * s))
	var layer := CanvasLayer.new()
	layer.layer = 110
	add_child(layer)
	var dot := ColorRect.new()
	dot.color = Color(0.808, 0.886, 0.478, 0.75)   # lit_hi green
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchored to the screen centre and given a fixed offset box, so it stays put at any window size
	# rather than depending on a preset's kept offsets.
	dot.anchor_left = 0.5
	dot.anchor_top = 0.5
	dot.anchor_right = 0.5
	dot.anchor_bottom = 0.5
	dot.offset_left = -2.0 * s
	dot.offset_top = -2.0 * s
	dot.offset_right = 2.0 * s
	dot.offset_bottom = 2.0 * s
	layer.add_child(dot)

	# The DMG LCD interface (capsule MONEY/GLUE readouts + the main menu) on its own layer, above
	# the dither and this crosshair. It owns the pixel font, which the prompt/hint borrow.
	_gbui = GBUI.new()
	add_child(_gbui)
	_gbui.glue_price = GLUE_PRICE
	_gbui.item_activated.connect(_on_menu_item)
	var gb_font := _gbui.get_font()

	# The respawn failsafe, spelled out in the corner so "press R if you get stuck" does not
	# have to be documented anywhere the player will not see it.
	var hint := Label.new()
	hint.text = "R  respawn"
	hint.modulate = Color(0.808, 0.886, 0.478, 0.7)   # lit_hi green
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.anchor_left = 0.0
	hint.anchor_top = 1.0
	hint.anchor_right = 0.0
	hint.anchor_bottom = 1.0
	hint.offset_left = 6.0 * s
	hint.offset_top = -18.0 * s
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	if gb_font != null:
		hint.add_theme_font_override("font", gb_font)
		hint.add_theme_font_size_override("font_size", fs)
	layer.add_child(hint)

	# Context prompt, just under the crosshair — pixel font, bright DMG green so it reads over the
	# mid-tone world.
	_prompt_label = Label.new()
	_prompt_label.modulate = Color(0.808, 0.886, 0.478)   # lit_hi green
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.anchor_left = 0.5
	_prompt_label.anchor_right = 0.5
	_prompt_label.anchor_top = 0.5
	_prompt_label.anchor_bottom = 0.5
	_prompt_label.offset_left = -170.0 * s
	_prompt_label.offset_right = 170.0 * s
	_prompt_label.offset_top = 20.0 * s
	if gb_font != null:
		_prompt_label.add_theme_font_override("font", gb_font)
		_prompt_label.add_theme_font_size_override("font_size", fs)
	layer.add_child(_prompt_label)


## Uniformly scales a model so its combined mesh bounds stand `target` metres tall. The .glb
## assets ship at whatever scale they were authored, so fitting by height is how the wand
## comes out hand-sized rather than guessing a scale per model.
func _fit_height(node: Node3D, target: float) -> void:
	var bounds := _local_aabb(node)
	if bounds.size.y > 0.0001:
		node.scale = Vector3.ONE * (target / bounds.size.y)


## Combined mesh bounds of `node` and its descendants, in `node`'s own space. Gathers every
## MeshInstance's corners rather than trusting one surface — a model can be several meshes.
func _local_aabb(root: Node) -> AABB:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	var has := false
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	for mi in meshes:
		if mi.mesh == null:
			continue
		var xform := _relative_xform(mi, root)
		var local := mi.mesh.get_aabb()
		for i in 8:
			var corner := local.position + Vector3(
					local.size.x if (i & 1) else 0.0,
					local.size.y if (i & 2) else 0.0,
					local.size.z if (i & 4) else 0.0)
			var world := xform * corner
			if not has:
				lo = world
				hi = world
				has = true
			else:
				lo = Vector3(minf(lo.x, world.x), minf(lo.y, world.y), minf(lo.z, world.z))
				hi = Vector3(maxf(hi.x, world.x), maxf(hi.y, world.y), maxf(hi.z, world.z))
	if not has:
		return AABB()
	return AABB(lo, hi - lo)


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		out.append(mesh_instance)
	for child in node.get_children():
		_collect_meshes(child, out)


func _relative_xform(node: Node, root: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var walk := node
	while walk != null and walk != root:
		var spatial := walk as Node3D
		if spatial != null:
			xform = spatial.transform * xform
		walk = walk.get_parent()
	return xform


static func _force_pixel_look(node: Node) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		for surface in mesh_instance.mesh.get_surface_count():
			for mat in [mesh_instance.mesh.surface_get_material(surface),
					mesh_instance.get_surface_override_material(surface)]:
				var base := mat as BaseMaterial3D
				if base != null:
					base.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
					base.cull_mode = BaseMaterial3D.CULL_DISABLED
	for child in node.get_children():
		_force_pixel_look(child)
