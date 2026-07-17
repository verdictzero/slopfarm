extends RigidBody3D
class_name HorseRagdoll
## A knocked-out horse. When a living FarmAnimal takes one hit too many it swaps itself for
## one of these: the same model, but limp, physics-driven and shovable. It flops from the
## blow that felled it, settles on the ground, and can then be picked up and carried to the
## glue factory's intake.
##
## This is a single-body ragdoll, not a per-bone one. The horse rig ships with one animation
## and no physical skeleton, so a full articulated ragdoll would be a rig authoring job; a
## capsule-ish body with the mesh riding on it tumbles convincingly enough at this scale and
## under this palette, and — unlike a bone chain — it cannot explode or tangle.

## Set on the shared clip so a dazed horse holds a feet-planted pose rather than freezing
## mid-stride. Mirrors FarmAnimal's stand frame.
const STAND_FRAME := {&"horse": 0.183}

var species: StringName = &"horse"
var _watch: Node3D
var _launch := Vector3.ZERO
var _spin := Vector3.ZERO
var _carried := false
## Saved so grabbing (which zeroes them to stop the body shoving the player) can restore the
## body's normal collisions on release.
var _rest_layer := 1
var _rest_mask := 1
## Godot forbids touching global_transform before a node is in the tree, so the spawn
## transform is stashed here and applied on _ready.
var _pending_xform := Transform3D.IDENTITY


## Builds a ragdoll from a species, a world transform to inherit, the model scale the living
## animal was drawn at, and the impulse that knocked it down. Returned detached — the caller
## adds it to the tree, which is when the impulse actually fires.
static func create(kind: StringName, world_xform: Transform3D, model_scale: float,
		impulse: Vector3, watch: Node3D) -> HorseRagdoll:
	var body := HorseRagdoll.new()
	body.species = kind
	body._watch = watch
	body._launch = impulse
	# A bit of tumble off the hit, biased by which way it was struck.
	body._spin = Vector3(impulse.z, impulse.x, -impulse.x) * 0.4 + Vector3(0.6, 1.1, 0.4)
	body.mass = 45.0
	body.linear_damp = 0.4
	body.angular_damp = 0.7
	body.can_sleep = true
	body._pending_xform = world_xform

	var scene_path := "res://models/%s.glb" % kind
	if ResourceLoader.exists(scene_path):
		var visual := (load(scene_path) as PackedScene).instantiate() as Node3D
		visual.scale = Vector3.ONE * model_scale
		_force_pixel_look(visual)
		body.add_child(visual)
		# Freeze the legs in a planted pose so the flop is the body tumbling, not a walk
		# cycle playing on a corpse.
		var anim := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if anim != null and not anim.get_animation_list().is_empty():
			var clip := anim.get_animation_list()[0]
			anim.play(clip)
			anim.seek(STAND_FRAME.get(kind, 0.2), true)
			anim.pause()

	# A single box roughly the size of a horse's barrel. Sized generously rather than fitted
	# to the mesh AABB: the exact bounds do not matter for a body whose whole job is to fall
	# over, and a fixed box has no way to come out degenerate.
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.3, 1.5, 2.6) * model_scale * 0.5
	var col := CollisionShape3D.new()
	col.shape = shape
	# Lift the box to sit around the body, since the model's origin is at the hooves.
	col.position = Vector3(0, 0.7 * model_scale, 0)
	body.add_child(col)
	return body


func _ready() -> void:
	global_transform = _pending_xform
	add_to_group("ragdoll")
	# Fired here, not in create(): impulses need the body registered with the physics server,
	# which only happens once it is in the tree.
	apply_central_impulse(_launch)
	apply_torque_impulse(_spin * mass)


## Picked up: go kinematic and stop colliding with anything so it rides in front of the
## player instead of fighting the capsule. The player then drives its transform each frame.
func grab() -> void:
	if _carried:
		return
	_carried = true
	_rest_layer = collision_layer
	_rest_mask = collision_mask
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	collision_layer = 0
	collision_mask = 0
	sleeping = false


## Dropped or thrown: hand it back to physics with a parting velocity.
func release(velocity: Vector3) -> void:
	if not _carried:
		return
	_carried = false
	freeze = false
	collision_layer = _rest_layer
	collision_mask = _rest_mask
	linear_velocity = velocity
	angular_velocity = Vector3(0.4, 1.0, 0.4)
	sleeping = false


func is_carried() -> bool:
	return _carried


# ---- pixel look -------------------------------------------------------------
# Same drag-into-house-style pass FarmBuilder does on the living animals: nearest filtering
# and double-sided, since a .glb's materials arrive with the importer's defaults, not this
# game's. Static and local so the ragdoll does not depend on a FarmBuilder instance.
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
