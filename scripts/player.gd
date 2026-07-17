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
## How near a ragdoll has to be to grab it.
const PICKUP_REACH := 3.5
## Where a carried ragdoll floats relative to the camera, and how hard a plain drop tosses it.
const CARRY_DISTANCE := 1.9
const CARRY_DROP := 0.7
const THROW_SPEED := 6.0
## Swing duration, seconds.
const SWING_TIME := 0.28

const WAND_SCENE := "res://models/heart_wand.glb"
## Resting pose of the wand in the camera's corner, and the height it is fitted to.
const WAND_REST := Vector3(0.34, -0.30, -0.62)
const WAND_REST_ROT := Vector3(0.0, 200.0, 8.0)
const WAND_HEIGHT := 0.42

@onready var camera: Camera3D = $Camera3D

var _pitch: float = 0.0
var _wand: Node3D
var _swing: float = 0.0
var _carried: HorseRagdoll


func _ready() -> void:
	camera.far = camera_far
	# Skip mouse capture when running with no display (headless validation).
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_spawn_wand()
	_spawn_crosshair()


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
			_attack()
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_interact()
	elif event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).physical_keycode == KEY_E:
			_interact()


func _process(delta: float) -> void:
	# Swing the wand: pitch it down through an arc and settle it back to rest.
	if _wand != null:
		if _swing > 0.0:
			_swing -= delta
			var arc := sin((1.0 - clampf(_swing / SWING_TIME, 0.0, 1.0)) * PI)
			_wand.rotation_degrees = WAND_REST_ROT + Vector3(-80.0 * arc, 0.0, 0.0)
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

	# A carried ragdoll rides in front of the camera. Driven after move_and_slide so it does
	# not lag a frame behind the player it is following.
	if _carried != null:
		if is_instance_valid(_carried):
			var forward := -camera.global_transform.basis.z
			var hold := camera.global_position + forward * CARRY_DISTANCE + Vector3.DOWN * CARRY_DROP
			_carried.global_transform = Transform3D(Basis(Vector3.UP, rotation.y), hold)
		else:
			_carried = null


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
		var to := animal.global_position + Vector3.UP * 0.8 - origin
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


func _interact() -> void:
	if _carried != null and is_instance_valid(_carried):
		# Carrying: try to feed the intake, otherwise set the horse down.
		if _feed_carried():
			_carried.queue_free()
			_carried = null
			return
		var forward := -camera.global_transform.basis.z
		_carried.release(forward * THROW_SPEED + Vector3.UP * 1.5)
		_carried = null
	else:
		_pickup()


func _feed_carried() -> bool:
	var at := _carried.global_position
	for node in get_tree().get_nodes_in_group("glue_factory"):
		var factory := node as GlueFactory
		if factory != null and factory.try_feed(at):
			return true
	return false


func _pickup() -> void:
	var origin := camera.global_position
	var best: HorseRagdoll = null
	var best_distance := PICKUP_REACH
	for node in get_tree().get_nodes_in_group("ragdoll"):
		var ragdoll := node as HorseRagdoll
		if ragdoll == null or ragdoll.is_carried():
			continue
		var distance := ragdoll.global_position.distance_to(origin)
		if distance < best_distance:
			best_distance = distance
			best = ragdoll
	if best != null:
		best.grab()
		_carried = best


# ---- setup ------------------------------------------------------------------

func _spawn_wand() -> void:
	if not ResourceLoader.exists(WAND_SCENE):
		return
	_wand = (load(WAND_SCENE) as PackedScene).instantiate() as Node3D
	_force_pixel_look(_wand)
	camera.add_child(_wand)
	_fit_height(_wand, WAND_HEIGHT)
	_wand.position = WAND_REST
	_wand.rotation_degrees = WAND_REST_ROT


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
