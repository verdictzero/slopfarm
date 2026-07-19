extends SceneTree
## Checks the truck's new collision body and its (already-fixed) chase-camera direction:
##   - it carries an AnimatableBody3D on the world layer so the player and ragdolls bump it;
##   - a body pushed at its flank is actually stopped by that box (it is solid, not a ghost);
##   - the chase camera sits BEHIND the truck and looks the way the truck faces (not backwards).
## Run: godot --headless --path . --script res://tools/probe_truck.gd

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

	func _find(node: Node) -> Truck:
		if node is Truck:
			return node
		for c in node.get_children():
			var hit := _find(c)
			if hit != null:
				return hit
		return null

	func _find_col_body(node: Node) -> AnimatableBody3D:
		if node is AnimatableBody3D:
			return node
		for c in node.get_children():
			var hit := _find_col_body(c)
			if hit != null:
				return hit
		return null

	func _run() -> void:
		var main := (load("res://world.tscn") as PackedScene).instantiate()
		p.root.add_child(main)
		p.current_scene = main
		for i in 40:
			await p.physics_frame

		var truck := _find(main)
		p.report(truck != null, "the truck exists")
		if truck == null:
			p.finish()
			return

		# --- collision body ---
		var body := _find_col_body(truck)
		p.report(body != null, "the truck has a kinematic collision body")
		if body == null:
			p.finish()
			return
		p.report((body.collision_layer & 1) != 0, "the collision body is on the world layer (1)")
		var has_box := false
		for c in body.get_children():
			var cs := c as CollisionShape3D
			if cs != null and cs.shape is BoxShape3D:
				has_box = true
		p.report(has_box, "the collision body is a box shape")

		# --- solidity at spawn: the box is registered where the truck is ---
		_check_solid(truck, "at spawn")

		# --- solidity while DRIVING: move the truck the way _drive does and re-check it follows ---
		truck.global_position = truck.global_position + Vector3(60.0, 0.0, -40.0)
		await p.physics_frame
		await p.physics_frame
		_check_solid(truck, "after it drove off")

		# --- a body shoved at the flank is actually stopped ---
		var probe := CharacterBody3D.new()
		probe.collision_layer = 0
		probe.collision_mask = 1        # scans the world layer, where the truck body lives
		var pcol := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 0.4
		pcol.shape = sph
		probe.add_child(pcol)
		main.add_child(probe)
		var b := truck.global_transform.basis
		var side := b.x.normalized()
		probe.global_position = truck.global_position + b.y * 1.85 + side * 2.0
		await p.physics_frame
		var hit := probe.move_and_collide(-side * 1.6)
		var stopped := hit != null and truck.is_ancestor_of(hit.get_collider())
		p.report(stopped, "a body pushed into the truck flank is stopped by it")
		probe.queue_free()

		# --- chase camera direction (the fix): behind the truck, looking where it faces ---
		truck._place_camera(0.0, true)
		var cam := truck._camera as Camera3D
		p.report(cam != null, "the truck has a chase camera")
		if cam != null:
			var forward := -truck.global_transform.basis.z
			var to_cam := cam.global_position - truck.global_position
			p.report(to_cam.dot(forward) < 0.0, "the camera sits BEHIND the truck")
			var cam_forward := -cam.global_transform.basis.z
			p.report(cam_forward.dot(forward) > 0.5, "the camera looks the way the truck faces")

		p.finish()

	## Shape-query the truck's body centre and confirm the truck's own collision box is found there.
	func _check_solid(truck: Truck, label: String) -> void:
		var b := truck.global_transform.basis
		var center := truck.global_position + b.y * 1.85 - b.z * 0.3
		var qbox := BoxShape3D.new()
		qbox.size = Vector3(1.0, 1.0, 1.0)
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = qbox
		params.collision_mask = 1
		params.transform = Transform3D(Basis.IDENTITY, center)
		var hit_truck := false
		for r in truck.get_world_3d().direct_space_state.intersect_shape(params, 8):
			if truck.is_ancestor_of(r["collider"]):
				hit_truck = true
		p.report(hit_truck, "the collision box tracks the truck body (%s)" % label)
