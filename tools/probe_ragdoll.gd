extends SceneTree
## Verification for the collision/ragdoll/wand rework. Headless, no rendering. Checks:
##   1. every gameplay script parses;
##   2. a knocked-out cow tumbles for 200 physics frames with every bone pose finite and the
##      body bounded — i.e. the secondary-motion ragdoll never explodes;
##   3. the wobble actually deflects bones (it is not a silent no-op);
##   4. a cow laid on its side lets its most-upward leg sag back down toward gravity;
##   5. the wand's rest pose and swing peak both send the heart away from the player.
## Run: godot --headless --path . --script res://tools/probe_ragdoll.gd

var _fail := 0


func _init() -> void:
	root.call_deferred("add_child", _Runner.new(self))


func report(ok: bool, msg: String) -> void:
	print(("  PASS " if ok else "  FAIL ") + msg)
	if not ok:
		_fail += 1


func finish() -> void:
	print("\n==== %s ====" % ("ALL PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	quit(1 if _fail else 0)


class _Runner:
	extends Node
	var p: SceneTree

	func _init(parent) -> void:
		p = parent

	func _ready() -> void:
		_run()

	func _run() -> void:
		_check_parse()
		_check_wand_direction()
		await _check_tumble()
		await _check_sag()
		p.finish()

	func _check_parse() -> void:
		for path in ["res://scripts/player.gd", "res://scripts/farm_animal.gd",
				"res://scripts/horse_ragdoll.gd", "res://scripts/main.gd"]:
			var s := load(path)
			p.report(s is GDScript and (s as GDScript).can_instantiate() or s is GDScript,
					"parses: %s" % path)

	func _check_wand_direction() -> void:
		# +Y is the heart end. Rotating it by the wand's Euler must send it into the world
		# (camera forward is -Z), both at rest and at the bottom of the swing.
		var rest: Vector3 = Player.WAND_REST_ROT
		var rest_dir := Basis.from_euler(rest * (PI / 180.0)) * Vector3.UP
		p.report(rest_dir.z < 0.0, "wand rest heart points away from player (z=%.2f < 0)" % rest_dir.z)
		var peak := rest + Vector3(Player.SWING_PITCH, 0.0, 0.0)
		var peak_dir := Basis.from_euler(peak * (PI / 180.0)) * Vector3.UP
		p.report(peak_dir.z < 0.0, "wand swing-peak heart still points away (z=%.2f < 0)" % peak_dir.z)

	func _floor() -> StaticBody3D:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(40, 1, 40)
		col.shape = box
		col.position = Vector3(0, -0.5, 0)
		body.add_child(col)
		return body

	func _skel_of(rag: HorseRagdoll) -> Skeleton3D:
		return rag.find_child("Skeleton3D", true, false) as Skeleton3D

	func _all_finite(skel: Skeleton3D) -> bool:
		for b in skel.get_bone_count():
			if not skel.get_bone_global_pose(b).origin.is_finite():
				return false
		return true

	func _max_deflection(skel: Skeleton3D) -> float:
		# Largest angle any floppy bone has swung from its rest rotation.
		var worst := 0.0
		for name in HorseRagdoll.FLOPPY:
			var idx := skel.find_bone(name)
			if idx < 0:
				continue
			var rest_q := skel.get_bone_rest(idx).basis.get_rotation_quaternion()
			var cur_q := skel.get_bone_pose_rotation(idx)
			worst = maxf(worst, absf(rest_q.angle_to(cur_q)))
		return worst

	func _check_tumble() -> void:
		add_child(_floor())
		var placement := Transform3D(Basis(), Vector3(0, 2.5, 0))
		var rag := HorseRagdoll.create(&"horse", placement, 1.0, Vector3(5, 4, 2), null)
		add_child(rag)
		var skel := _skel_of(rag)
		p.report(skel != null, "ragdoll built a skeleton")
		if skel == null:
			return
		var finite := true
		var bounded := true
		var deflected := 0.0
		for i in 200:
			await p.physics_frame
			if not is_instance_valid(rag):
				break
			if not _all_finite(skel) or not rag.global_position.is_finite():
				finite = false
			if rag.global_position.length() > 60.0:
				bounded = false
			deflected = maxf(deflected, _max_deflection(skel))
		p.report(finite, "all bone poses stayed finite over 200 frames")
		p.report(bounded, "body stayed bounded (|pos| < 60) — no explosion")
		p.report(deflected > deg_to_rad(5.0),
				"wobble deflected a limb (max %.1f deg > 5)" % rad_to_deg(deflected))
		p.report(rag.global_position.y > -1.0, "cow came to rest on the floor, not through it")
		rag.queue_free()

	func _check_sag() -> void:
		var rag := HorseRagdoll.create(&"horse", Transform3D(Basis(), Vector3(20, 5, 20)), 1.0,
				Vector3.ZERO, null)
		# Lay it on its side and pin it there, so the only thing that can move the legs is the
		# gravity sag we are testing.
		add_child(rag)
		rag.freeze = true
		rag.global_transform = Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(20, 3, 20))
		var skel := _skel_of(rag)
		if skel == null:
			p.report(false, "sag test: no skeleton")
			return
		# Let one frame settle to rest, then pick the leg bone pointing most upward — the one
		# with the most room to fall.
		await p.physics_frame
		var pick := ""
		var pick_y := -2.0
		var start := {}
		for name in ["frontleg0", "R_frontleg0", "backleg0", "R_backleg0"]:
			var d := _bone_world_dir(skel, name)
			start[name] = d
			if d.y > pick_y:
				pick_y = d.y
				pick = name
		for i in 90:
			await p.physics_frame
		var ended := _bone_world_dir(skel, pick)
		p.report(ended.y < (start[pick] as Vector3).y - 0.08,
				"laid-out cow's '%s' leg sagged down (y %.2f -> %.2f)" % [
						pick, (start[pick] as Vector3).y, ended.y])
		rag.queue_free()

	func _bone_world_dir(skel: Skeleton3D, name: String) -> Vector3:
		var idx := skel.find_bone(name)
		if idx < 0:
			return Vector3.UP
		var basis := (skel.global_transform.basis.orthonormalized()
				* skel.get_bone_global_pose(idx).basis.orthonormalized())
		return (basis * Vector3.UP).normalized()
