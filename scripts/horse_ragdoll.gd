extends RigidBody3D
class_name HorseRagdoll
## A knocked-out cow. When a living FarmAnimal takes a hit it swaps itself for one of these:
## the same model, but limp, physics-driven and shovable. It flops from the blow that felled
## it, settles on the ground, and can then be picked up Half-Life style and carried to the
## glue factory's intake.
##
## Two layers make it read as floppy:
##
## - GROSS MOTION is one rigid box the size of the barrel. It tumbles, collides with the world,
##   and is what the player's grab drives around. A single body cannot explode or tangle the
##   way an articulated rag can, and — crucially — the horse rig hangs under an Armature scaled
##   0.01 (cm-authored bones), which is precisely the case where RigidBody/PhysicalBone physics
##   misbehaves. So no physics bodies go anywhere near that scaled skeleton.
##
## - FLOPPINESS is secondary motion driven straight onto the skeleton: each limb, the neck and
##   the tail spring toward the direction gravity (and the body's own acceleration) says they
##   should hang, lagging behind and swinging. It works purely in bone-local rotations, so the
##   0.01 armature scale is irrelevant, it is bounded (every deflection is clamped) so it cannot
##   blow up, and it drapes the actual skinned mesh rather than a stand-in.

## Physics layers. The cow rides layer 2 and only scans the world (layer 1): it rests on the
## terrain and can't be pushed through a wall, but it never collides with the player (layer 3),
## so a 45 kg body tumbling past can't wedge you into a fence. See Player._ready.
const WORLD_LAYER := 1
const RAGDOLL_LAYER := 2

## Floppiness tuning. Limbs aim at gravity-down blended against the body's acceleration (so they
## whip when the body is thrown or swung); RESPONSE is how fast they chase that aim (lower =
## looser), and each bone's deflection is hard-clamped to its own max angle so nothing inverts.
const GRAVITY_PULL := 1.0
const INERTIA := 0.05
const RESPONSE := 9.0
## Past this from the watched node the wobble stops running — a cow you cannot make out does not
## need its neck simulated. It holds whatever pose it last draped into.
const FLOP_RANGE := 60.0

## The bones that go limp, by name (robust to index shuffles on reimport), each with how far it
## follows the sag (0..1) and how far it may deflect from rest. Legs and tail are the loosest;
## the head lolls; hips/chest/hooves/ears are left rigid so the barrel tracks the collision box.
const FLOPPY := {
	"head": {"flop": 0.55, "max": 50.0},
	"tail1": {"flop": 0.8, "max": 65.0},
	"tail2": {"flop": 0.85, "max": 70.0},
	"tail3": {"flop": 0.85, "max": 75.0},
	"frontleg": {"flop": 0.7, "max": 52.0},
	"frontleg0": {"flop": 0.8, "max": 66.0},
	"frontleg1": {"flop": 0.85, "max": 74.0},
	"R_frontleg": {"flop": 0.7, "max": 52.0},
	"R_frontleg0": {"flop": 0.8, "max": 66.0},
	"R_frontleg1": {"flop": 0.85, "max": 74.0},
	"backleg": {"flop": 0.7, "max": 52.0},
	"backleg0": {"flop": 0.8, "max": 66.0},
	"backleg1": {"flop": 0.85, "max": 74.0},
	"R_backleg": {"flop": 0.7, "max": 52.0},
	"R_backleg0": {"flop": 0.8, "max": 66.0},
	"R_backleg1": {"flop": 0.85, "max": 74.0},
}

var species: StringName = &"horse"
var _watch: Node3D
var _launch := Vector3.ZERO
var _spin := Vector3.ZERO
var _carried := false
## Restored on release, since carrying floats the body by zeroing its gravity.
var _rest_gravity := 1.0
## Godot forbids touching global_transform before a node is in the tree, so the spawn
## transform is stashed here and applied on _ready.
var _pending_xform := Transform3D.IDENTITY

## Secondary-motion state.
var _skel: Skeleton3D
## One entry per floppy bone: {idx, rest_basis, rest_dir, flop, max, state}. `state` is the
## bone's current (smoothed) limb direction in its parent's space; the rest is constant.
var _floppy: Array = []
var _prev_vel := Vector3.ZERO
var _have_prev := false


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
	# Its own layer, scanning only the world: rests on terrain, blocked by walls, but never
	# collides with the player. This is half the fix for "keeps getting stuck in objects".
	body.collision_layer = RAGDOLL_LAYER
	body.collision_mask = WORLD_LAYER

	var scene_path := "res://models/%s.glb" % kind
	if ResourceLoader.exists(scene_path):
		var visual := (load(scene_path) as PackedScene).instantiate() as Node3D
		visual.scale = Vector3.ONE * model_scale
		_force_pixel_look(visual)
		body.add_child(visual)
		# Stop the walk clip dead: the ragdoll drives the skeleton itself, so an AnimationPlayer
		# still touching these bones would fight the wobble for them.
		var anim := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if anim != null:
			anim.stop()
		body._skel = visual.find_child("Skeleton3D", true, false) as Skeleton3D

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
	_build_floppy()
	# Fired here, not in create(): impulses need the body registered with the physics server,
	# which only happens once it is in the tree.
	apply_central_impulse(_launch)
	apply_torque_impulse(_spin * mass)


## Resolves the floppy bone names to indices and records each one's rest pose and the direction
## its limb points at rest (in the parent bone's space). Skeletons that lack a bone are simply
## skipped, so a different-species model with a different rig degrades to a stiff tumble rather
## than erroring.
func _build_floppy() -> void:
	if _skel == null:
		return
	for name in FLOPPY:
		var idx := _skel.find_bone(name)
		if idx < 0:
			continue
		var rest_basis := _skel.get_bone_rest(idx).basis.orthonormalized()
		# +Y is down-the-limb for this rig (every child bone rests at local +Y).
		var rest_dir := (rest_basis * Vector3.UP).normalized()
		_floppy.append({
			"idx": idx,
			"rest_basis": rest_basis,
			"rest_dir": rest_dir,
			"flop": float(FLOPPY[name]["flop"]),
			"max": deg_to_rad(float(FLOPPY[name]["max"])),
			"state": rest_dir,
		})


func _physics_process(delta: float) -> void:
	if _skel == null or _floppy.is_empty() or delta <= 0.0:
		return
	# A settled, unheld cow has already draped; leave it be until something moves it again.
	if sleeping and not _carried:
		_have_prev = false
		return
	# Distant cows are a few pixels tall in the fog — do not simulate a neck nobody can see.
	if _watch != null and global_position.distance_squared_to(_watch.global_position) \
			> FLOP_RANGE * FLOP_RANGE:
		return

	# The world direction the limbs want to hang: gravity, pushed off by the body's own
	# acceleration so they lag and whip when it is thrown or swung around on the grab.
	if not _have_prev:
		_prev_vel = linear_velocity
		_have_prev = true
	var accel := (linear_velocity - _prev_vel) / delta
	_prev_vel = linear_velocity
	var felt := Vector3.DOWN * GRAVITY_PULL - accel * INERTIA
	if felt.length() < 0.001:
		felt = Vector3.DOWN
	felt = felt.normalized()

	var skel_basis := _skel.global_transform.basis.orthonormalized()
	var chase := clampf(RESPONSE * delta, 0.0, 1.0)
	for f in _floppy:
		var idx: int = f["idx"]
		var parent := _skel.get_bone_parent(idx)
		# Parent pose is read fresh each bone (get_bone_global_pose recomputes on demand), and
		# bones are stored parent-before-child, so a chain dangles off its own updated links.
		var parent_world := skel_basis
		if parent >= 0:
			parent_world = (skel_basis * _skel.get_bone_global_pose(parent).basis.orthonormalized())
		# felt, expressed in the parent bone's space (orthonormal inverse == transpose).
		var target := (parent_world.inverse() * felt).normalized()
		var rest_dir: Vector3 = f["rest_dir"]
		var aim: Vector3 = rest_dir.lerp(target, f["flop"])
		if aim.length() < 0.001:
			aim = rest_dir
		aim = aim.normalized()
		f["state"] = (f["state"] as Vector3).lerp(aim, chase).normalized()
		var q := _arc(rest_dir, f["state"], f["max"])
		var new_basis := Basis(q) * (f["rest_basis"] as Basis)
		_skel.set_bone_pose_rotation(idx, new_basis.get_rotation_quaternion())


## Shortest-arc rotation carrying unit `from` onto unit `to`, clamped to `max_angle`. Clamping
## is the whole safety net: no matter how wild the target, a bone can never fold past its limit.
static func _arc(from: Vector3, to: Vector3, max_angle: float) -> Quaternion:
	var d := clampf(from.dot(to), -1.0, 1.0)
	var angle := acos(d)
	if angle < 0.0001:
		return Quaternion.IDENTITY
	var axis := from.cross(to)
	if axis.length() < 1e-5:
		# Near-antiparallel: any perpendicular axis will do.
		axis = from.cross(Vector3.UP)
		if axis.length() < 1e-5:
			axis = from.cross(Vector3.RIGHT)
	axis = axis.normalized()
	return Quaternion(axis, minf(angle, max_angle))


# ---- carry ------------------------------------------------------------------
# Half-Life style: the body stays a live RigidBody the whole time it is held. The player drives
# it toward a point in front of the camera by setting its velocity (see Player._drive_carried),
# so it still collides with the world — you can press it against a wall and it stays out — but
# gravity is switched off so it floats where you put it instead of sagging out of frame.

func grab() -> void:
	if _carried:
		return
	_carried = true
	_rest_gravity = gravity_scale
	gravity_scale = 0.0
	can_sleep = false
	sleeping = false


## Dropped or thrown: hand it back to gravity with a parting velocity.
func release(velocity: Vector3) -> void:
	if not _carried:
		return
	_carried = false
	gravity_scale = _rest_gravity
	can_sleep = true
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
