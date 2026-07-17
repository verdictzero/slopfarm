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
## Swing duration, seconds.
const SWING_TIME := 0.28

const WAND_SCENE := "res://models/heart_wand.glb"
## Resting pose of the wand in the camera's corner, and the height it is fitted to. The wand is
## held out ahead pointing away from you — the heart (the model's +Y tip) leads, so both the
## rest pose and the swing send it into the world rather than back at your face. Bigger than it
## was (0.42) so it actually reads as a wand and not a splinter.
const WAND_REST := Vector3(0.30, -0.30, -0.55)
const WAND_REST_ROT := Vector3(-58.0, 12.0, 8.0)
const WAND_HEIGHT := 0.62
## How far the swing pitches the heart down-and-forward through its arc (degrees). Negative
## keeps the tip going away from the player and toward the ground — a forward chop.
const SWING_PITCH := -55.0

## Gold handle, red heart.
const WAND_GOLD := Color(0.83, 0.63, 0.19)
const WAND_RED := Color(0.78, 0.11, 0.11)

@onready var camera: Camera3D = $Camera3D

var _pitch: float = 0.0
var _wand: Node3D
var _swing: float = 0.0
var _carried: HorseRagdoll

## Where R sends the player, and the terrain to rebuild solid ground around it on the way.
## Both are set by main.gd once the world exists; safe to leave unset (R just no-ops).
var spawn_point: Vector3
var terrain: TerrainManager


func _ready() -> void:
	camera.far = camera_far
	_tune_collision()
	# Skip mouse capture when running with no display (headless validation).
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_spawn_wand()
	_spawn_crosshair()


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
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.4, 1.4)
		camera.rotation.x = _pitch
	elif event.is_action_pressed(&"ui_cancel"):
		# Toggle the mouse capture (Esc).
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var button := event as InputEventMouseButton
		# A click outside capture just recaptures the mouse; it is not also a swing.
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if button.button_index == MOUSE_BUTTON_LEFT:
			# Left click swings the wand — or, when you are carrying a cow, punts it.
			if _carried != null and is_instance_valid(_carried):
				_throw()
			else:
				_attack()
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_interact()
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).physical_keycode
		if key == KEY_E:
			_interact()
		elif key == KEY_R:
			# The failsafe: warp back to the start if you ever get wedged in the scenery.
			_respawn()


func _process(delta: float) -> void:
	# Swing the wand: pitch it down through an arc and settle it back to rest.
	if _wand != null:
		if _swing > 0.0:
			_swing -= delta
			var arc := sin((1.0 - clampf(_swing / SWING_TIME, 0.0, 1.0)) * PI)
			_wand.rotation_degrees = WAND_REST_ROT + Vector3(SWING_PITCH * arc, 0.0, 0.0)
		else:
			_wand.rotation_degrees = WAND_REST_ROT


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif Input.is_physical_key_pressed(KEY_SPACE):
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
	input = input.normalized()

	var speed := sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
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


# ---- actions ----------------------------------------------------------------

func _attack() -> void:
	if _swing <= 0.0:
		_swing = SWING_TIME
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


## E / right-click. Not carrying: grab what you are looking at. Carrying: feed the intake if
## you are on it, otherwise set the cow down gently at your feet.
func _interact() -> void:
	if _carried != null and is_instance_valid(_carried):
		if _feed_carried():
			_carried.queue_free()
			_carried = null
			return
		var forward := -camera.global_transform.basis.z
		_carried.release(forward * DROP_SPEED + Vector3.UP * 0.5)
		_carried = null
	else:
		_pickup()


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
	_wand = (load(WAND_SCENE) as PackedScene).instantiate() as Node3D
	_force_pixel_look(_wand)
	_paint_wand(_wand)
	camera.add_child(_wand)
	_fit_height(_wand, WAND_HEIGHT)
	_wand.position = WAND_REST
	_wand.rotation_degrees = WAND_REST_ROT


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
## below the dither post-process (layer 100), so the dither still passes over the whole frame.
func _spawn_crosshair() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var dot := ColorRect.new()
	dot.color = Color(0.9, 0.9, 0.9, 0.6)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchored to the screen centre and given a fixed 4x4 offset box, so it stays put at any
	# window size rather than depending on a preset's kept offsets.
	dot.anchor_left = 0.5
	dot.anchor_top = 0.5
	dot.anchor_right = 0.5
	dot.anchor_bottom = 0.5
	dot.offset_left = -2.0
	dot.offset_top = -2.0
	dot.offset_right = 2.0
	dot.offset_bottom = 2.0
	layer.add_child(dot)

	# The respawn failsafe, spelled out in the corner so "press R if you get stuck" does not
	# have to be documented anywhere the player will not see it.
	var hint := Label.new()
	hint.text = "R  respawn"
	hint.modulate = Color(0.9, 0.9, 0.9, 0.45)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.anchor_left = 0.0
	hint.anchor_top = 1.0
	hint.anchor_right = 0.0
	hint.anchor_bottom = 1.0
	hint.offset_left = 6.0
	hint.offset_top = -22.0
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(hint)


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
