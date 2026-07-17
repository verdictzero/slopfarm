extends Node3D
class_name FarmAnimal
## Makes one animal amble around its zone.
##
## Everything here is pinned to measurements taken off the actual clip, because the
## models ship with exactly one 1-second animation ("Armature|Unreal Take|baselayer")
## and no metadata about it:
##
## - It is a WALK, not an idle: the leg joints swing 170-180 degrees through the cycle.
## - It has NO root motion. The hips drift <0.04 over the cycle and return to where they
##   started, so it walks on the spot and this script is free to move the node without
##   the two fighting each other.
## - It does NOT loop (loop_mode = LOOP_NONE as imported). Left alone it plays once and
##   freezes mid-stride, which is what the farm shipped doing.
## - Stride is 0.91 m/cycle for a horse, measured as the fore-aft excursion of the feet
##   on the unscaled model. Walking faster than stride/cycle is what moonwalking IS, so
##   speed and playback rate are derived from each other rather than picked independently.
## - There is no idle pose to stand in, so standing means holding the frame where all
##   four feet are down: t=0.183 for a horse.

## Metres advanced per cycle of the clip, measured per species on the unscaled model.
## Playback rate is scaled from this, so any speed stays foot-locked.
const STRIDE := {&"horse": 0.91}
## Display size, as a multiple of the model's native size. The clip's foot excursion is in
## model space, so this multiplies into STRIDE: a 2x horse whose feet still only claim
## 0.91m a cycle skates. Speed follows stride, so a bigger animal also covers ground
## faster, which is what long legs do.
## Halved from 2.0 to 1.0 to make the herd 50% smaller — because stride, speed and the
## ragdoll's collision box all derive from this, the whole animal shrinks consistently
## (feet stay locked, the knocked-out body stays sized to the mesh) with the one edit.
const SCALE := {&"horse": 1.0}
## The frame where all four feet are planted — the only pose worth stopping on.
const STAND_FRAME := {&"horse": 0.183}

## How far an animal will wander from where it is before picking somewhere else.
const ROAM_RANGE := 14.0
const TURN_RATE := 1.6          # radians/sec — a horse does not pivot on the spot
const ARRIVED := 1.2

## Hits it takes before it drops. One: a single bop drops the animal straight into its
## floppy ragdoll, so knocking a cow over is immediate rather than a three-swing chore.
const HIT_POINTS := 1
## How hard the knockout throws the ragdoll away from the blow, and the lift on it — enough
## that it visibly flops rather than just tipping where it stood.
const KNOCK_FORCE := 6.5
const KNOCK_LIFT := 4.5

## Past this, an animal stops animating and stops walking.
##
## This is the single biggest cost on the farm. An animating skeleton is ~0.15 ms each:
## 76 of them measured 18.06 ms/frame against 12.50 ms for 38, while the whole wheat
## field costs less. (An earlier measurement claimed animals were free — that was taken
## while a LOOP_NONE bug had them frozen after one second, so nothing was skinning.)
##
## Dormant animals hold their pose and simply stop being simulated. At 55m a horse is a
## few pixels tall and the fog is closing in, so a frozen stride is not visible; the
## herd you can actually see is always live.
const ACTIVE_RANGE := 55.0

var species: StringName
var speed: float = 0.5
## STRIDE for this species with SCALE already folded in — the distance the feet actually
## claim per cycle at the size this animal is drawn.
var _stride: float = 0.6
var _home_cells: PackedVector2Array
var _terrain: TerrainManager
var _anim: AnimationPlayer
var _clip: StringName
var _target := Vector2.ZERO
var _standing := true
var _timer := 0.0
var _dormant := false
var _watch: Node3D
var _health := HIT_POINTS
var _rng := RandomNumberGenerator.new()


## `cells` are the world positions of the zone this animal belongs to; it will not leave
## them. Passing the zone's cells rather than a radius is what keeps an L-shaped pen from
## putting an animal in the notch.
func setup(kind: StringName, cells: PackedVector2Array, terrain: TerrainManager,
		rng_seed: int, watch: Node3D) -> void:
	species = kind
	_home_cells = cells
	_terrain = terrain
	# Whose distance decides whether this animal is worth simulating. Passed in rather
	# than fetched per frame: get_camera_3d() per animal per frame is 76 tree walks.
	_watch = watch
	_rng.seed = rng_seed
	_health = HIT_POINTS
	# Living animals answer to the player's swing; the ragdoll it becomes joins "ragdoll"
	# instead. Groups keep the player's melee and pickup checks decoupled from the farm's
	# node layout — no path-walking to find what is hittable.
	add_to_group("horse")

	# Size and stride are set together, before the AnimationPlayer bail-out below, so the
	# two can never disagree about how big this animal is.
	scale = Vector3.ONE * float(SCALE.get(species, 1.0))
	_stride = float(STRIDE.get(species, 0.6)) * scale.x
	# A little spread so a herd is not one organism.
	speed = _stride * _rng.randf_range(0.8, 1.25)

	_anim = find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim == null or _anim.get_animation_list().is_empty():
		push_warning("%s has no AnimationPlayer; it will stand still" % kind)
		return
	_clip = _anim.get_animation_list()[0]
	# The clip imports as LOOP_NONE, so it would play once and stop. The Animation is a
	# shared resource, so this also fixes every other animal of this species.
	_anim.get_animation(_clip).loop_mode = Animation.LOOP_LINEAR

	# Playback follows speed, so the feet stay locked to the ground at whatever speed this
	# one walks.
	_anim.play(_clip)
	_anim.speed_scale = speed / _stride
	_anim.seek(_rng.randf() * _anim.get_animation(_clip).length, true)
	_stand()


func _process(delta: float) -> void:
	# Distance culling, the same idea the crop uses — and for the same reason: the cost
	# is per-frame work for things you cannot make out.
	if _watch != null:
		var far := global_position.distance_squared_to(_watch.global_position) \
				> ACTIVE_RANGE * ACTIVE_RANGE
		if far != _dormant:
			_dormant = far
			if _dormant:
				# Hold the pose rather than snapping to the stand frame: a distant animal
				# visibly twitching as it goes dormant is worse than a frozen stride.
				if _anim != null:
					_anim.pause()
			elif not _standing and _anim != null:
				_anim.play(_clip)
				_anim.speed_scale = speed / _stride
		if _dormant:
			return

	_timer -= delta
	if _standing:
		if _timer <= 0.0:
			_walk()
		return

	var here := Vector2(global_position.x, global_position.z)
	if here.distance_to(_target) < ARRIVED or _timer <= 0.0:
		_stand()
		return

	# Turn toward the target rather than snapping: a herd of animals all instantly
	# facing the same way reads as a flock of arrows.
	var want := atan2(_target.x - here.x, _target.y - here.y)
	rotation.y = rotate_toward(rotation.y, want, TURN_RATE * delta)

	var forward := Vector2(sin(rotation.y), cos(rotation.y))
	var step := here + forward * speed * delta
	global_position = Vector3(step.x, _terrain.height_at(step.x, step.y), step.y)


## Takes a blow from `from_dir` (the direction the hit travels, i.e. away from the player).
## A few of these and the animal drops into a ragdoll; before that it bolts.
func take_hit(from_dir: Vector3, damage: int = 1) -> void:
	_health -= damage
	if _health <= 0:
		_knock_out(from_dir)
		return
	# Bolt away from the blow. Bypasses _walk's home-cell target so it can actually flee the
	# player rather than politely pick a nearby graze spot; a later _walk pulls it home.
	_dormant = false
	_standing = false
	var here := Vector2(global_position.x, global_position.z)
	var away := Vector2(from_dir.x, from_dir.z)
	if away.length() < 0.01:
		away = Vector2(0.0, 1.0)
	_target = here + away.normalized() * ROAM_RANGE
	_timer = 2.5
	if _anim != null:
		_anim.play(_clip)
		# A touch faster than an amble — spooked, not strolling.
		_anim.speed_scale = (speed * 1.6) / _stride


## Swaps this living animal for a knocked-out ragdoll and removes itself. The ragdoll is
## parented to the current scene, not to the farm: FarmBuilder wipes its own children on a
## plan reload, and a horse you dropped by the factory should not vanish because you saved
## the designer.
func _knock_out(from_dir: Vector3) -> void:
	var model_scale := float(SCALE.get(species, 1.0))
	var dir := from_dir
	if dir.length() < 0.01:
		dir = Vector3(0.0, 0.0, 1.0)
	var impulse := dir.normalized() * KNOCK_FORCE + Vector3.UP * KNOCK_LIFT
	# A scale-free transform: this node carries the model's display scale (SCALE), and the
	# ragdoll re-applies that to its own visual — inheriting it here would square it, and a
	# scaled RigidBody misbehaves besides. Position and yaw only.
	var placement := Transform3D(Basis(Vector3.UP, rotation.y), global_position)
	var ragdoll := HorseRagdoll.create(species, placement, model_scale, impulse, _watch)
	var host := get_tree().current_scene
	if host != null:
		host.add_child(ragdoll)
	queue_free()


func _stand() -> void:
	_standing = true
	_timer = _rng.randf_range(3.0, 11.0)
	if _anim != null:
		# Hold the all-feet-down frame. Pausing wherever it happened to be leaves a leg
		# hanging in the air.
		_anim.seek(STAND_FRAME.get(species, 0.2), true)
		_anim.pause()


func _walk() -> void:
	if _home_cells.is_empty():
		return
	# Pick a destination from the zone's own cells, so the animal cannot wander out of
	# its pen no matter what shape the pen is. Prefer somewhere nearby, so it ambles
	# rather than teleporting its intentions across the field.
	var here := Vector2(global_position.x, global_position.z)
	var target := _home_cells[_rng.randi_range(0, _home_cells.size() - 1)]
	for attempt in 6:
		var candidate := _home_cells[_rng.randi_range(0, _home_cells.size() - 1)]
		if here.distance_to(candidate) < ROAM_RANGE:
			target = candidate
			break
	_target = target
	_standing = false
	# Bounded so an unreachable target cannot strand it walking forever.
	_timer = here.distance_to(_target) / maxf(speed, 0.05) + 6.0
	if _anim != null:
		_anim.play(_clip)
		_anim.speed_scale = speed / _stride
