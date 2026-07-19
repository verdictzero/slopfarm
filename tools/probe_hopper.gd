extends SceneTree
## Drives the new "drop a horse into the grinder" flow headless: a body fed with feed_horse is
## taken over and animates DOWN the hopper (it is in _descending, not instantly a batch), the gore
## emitters stay OFF until the grinder is actually chewing, then the descent finishes into a batch,
## the grinder goes busy and the blood switches ON, and once processing ends the blood switches OFF.
## Run: godot --headless --path . --script res://tools/probe_hopper.gd

var _fail := 0


func report(ok: bool, msg: String) -> void:
	print(("  PASS " if ok else "  FAIL ") + msg)
	if not ok:
		_fail += 1


func finish() -> void:
	print("\n==== %s ====" % ("ALL PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	quit(1 if _fail else 0)


func _init() -> void:
	root.call_deferred("add_child", _Runner.new(self))


class _Runner:
	extends Node
	var p: SceneTree

	func _init(parent) -> void:
		p = parent

	func _ready() -> void:
		_run()

	func _find(node: Node) -> GlueFactory:
		if node is GlueFactory:
			return node
		for c in node.get_children():
			var hit := _find(c)
			if hit != null:
				return hit
		return null

	func _gore_on(factory: GlueFactory) -> bool:
		# True only if every gore emitter is currently emitting.
		if factory._gore.is_empty():
			return false
		for e in factory._gore:
			if not (e as CPUParticles3D).emitting:
				return false
		return true

	func _run() -> void:
		var main := (load("res://world.tscn") as PackedScene).instantiate()
		p.root.add_child(main)
		p.current_scene = main
		for i in 40:
			await p.physics_frame

		var factory := _find(main)
		p.report(factory != null, "the glue works exists")
		if factory == null:
			p.finish()
			return

		p.report(factory._gore.size() == 3, "three gore emitters were built")
		p.report(not _gore_on(factory), "blood is OFF at rest (no body in the grinder)")

		# A stand-in ragdoll body, right at the intake.
		var horse := RigidBody3D.new()
		horse.gravity_scale = 0.0
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1, 1, 2)
		col.shape = box
		horse.add_child(col)
		main.add_child(horse)
		horse.global_position = factory._feed_world

		var far := RigidBody3D.new()
		main.add_child(far)
		far.global_position = Vector3(9999, 0, 9999)
		p.report(not factory.feed_horse(far), "feed from across the map is refused")
		far.queue_free()

		p.report(factory.feed_horse(horse), "a horse dropped at the intake is accepted")
		p.report(factory._descending.size() == 1, "the horse is descending, not yet a batch")
		p.report(factory._batches.is_empty(), "no batch on the line yet (still going down)")
		p.report(horse.freeze, "the fed body was frozen for its scripted drop")

		# It should be hoisted up over the mouth then plunge deep in: track Y across the descent.
		var y_start := horse.global_position.y
		var y_min := y_start
		var y_peak := y_start
		var became_batch := false
		for i in 180:
			await p.process_frame
			if is_instance_valid(horse):
				y_min = minf(y_min, horse.global_position.y)
				y_peak = maxf(y_peak, horse.global_position.y)
			if not factory._batches.is_empty():
				became_batch = true
				break
		p.report(y_peak > y_start + 0.5, "the body was hoisted up over the hopper mouth")
		p.report(y_peak - y_min > 2.0, "then plunged deep down into the grinder")
		p.report(y_min < y_start, "it ended lower than it went in (swallowed)")
		p.report(became_batch, "after the drop it became a grinder batch")
		p.report(not is_instance_valid(horse) or horse.is_queued_for_deletion(),
				"the descended body was consumed (freed)")

		# While the grinder chews it, machine 0 is busy and the blood runs.
		var saw_blood := false
		var saw_busy := false
		for i in 120:
			await p.process_frame
			if bool(factory._machines[0]["busy"]):
				saw_busy = true
			if _gore_on(factory):
				saw_blood = true
			if saw_busy and saw_blood:
				break
		p.report(saw_busy, "the grinder went busy chewing the body")
		p.report(saw_blood, "blood erupted WHILE the grinder was processing")

		# Once it has moved on, the grinder frees and the blood stops again.
		var blood_stopped := false
		for i in 240:
			await p.process_frame
			if not bool(factory._machines[0]["busy"]) and not _gore_on(factory):
				blood_stopped = true
				break
		p.report(blood_stopped, "blood switched OFF again once the grinder was done")

		p.finish()
