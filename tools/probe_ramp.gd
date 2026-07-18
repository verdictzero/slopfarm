extends SceneTree
## Walks the player up the factory door ramp headless to prove it does not snag. Places the
## player at the foot of the ramp outside the door and drives it straight in for a few seconds,
## then checks it actually made it onto the factory floor rather than stalling on the slope.
## Run: godot --headless --path . --script res://tools/probe_ramp.gd

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

	func _first(node: Node, want) -> Node:
		if is_instance_of(node, want):
			return node
		for c in node.get_children():
			var hit := _first(c, want)
			if hit != null:
				return hit
		return null

	func _run() -> void:
		var main := (load("res://world.tscn") as PackedScene).instantiate()
		p.root.add_child(main)
		p.current_scene = main
		for i in 40:
			await p.physics_frame

		var player := _first(main, Player) as Player
		var factory := _first(main, GlueFactory) as GlueFactory
		var terrain := _first(main, TerrainManager) as TerrainManager
		if player == null or factory == null:
			p.report(false, "world booted")
			p.finish()
			return

		# The door is on the -X wall on the intake row. The ramp runs out from it to the west.
		var fc := factory.position
		var door_z := fc.z + GlueFactory.ROW_Z[0]
		var wall_x := fc.x - GlueFactory.WIDTH_X * 0.5
		var toe_x := wall_x - factory._ramp_len + 1.0
		# Prime collision around the ramp, then stand the player at its foot facing the door.
		terrain.prime(Vector3(toe_x, 0, door_z))
		for i in 10:
			await p.physics_frame
		var start := Vector3(toe_x, terrain.height_at(toe_x, door_z) + 1.2, door_z)
		player.global_position = start
		player.velocity = Vector3.ZERO
		# Drive it ourselves so the walk is deterministic (no key input headless).
		player.set_physics_process(false)
		var dt := 1.0 / 60.0
		var stuck_x := start.x
		var stalled := 0
		print("  start x=%.2f y=%.2f  wall_x=%.1f floor_y=%.2f ramp_len=%.1f" % [
				start.x, start.y, wall_x, fc.y, factory._ramp_len])
		# Success is reaching the floor just inside the door. Straight ahead beyond that is the
		# conveyor line (a solid you would walk around), so we stop the moment we are inside.
		var inside_x := wall_x + 1.5
		var reached := false
		var worst_stall := 0
		for i in 240:
			if not player.is_on_floor():
				player.velocity.y -= 22.0 * dt
			else:
				player.velocity.y = 0.0
			player.velocity.x = 9.0     # straight toward the door (+X)
			player.velocity.z = 0.0
			player.move_and_slide()
			await p.physics_frame
			if player.global_position.x >= inside_x and absf(player.global_position.y - fc.y) < 0.6:
				reached = true
				break
			# Watch for a stall on the way up: no eastward progress over many frames = snagged.
			if player.global_position.x > stuck_x + 0.05:
				stuck_x = player.global_position.x
				stalled = 0
			else:
				stalled += 1
				worst_stall = maxi(worst_stall, stalled)

		var here := player.global_position
		p.report(reached, "walked up the ramp and through the door onto the floor (x=%.1f y=%.2f)"
				% [here.x, here.y])
		p.report(absf(here.y - fc.y) < 0.6, "ended at floor height (y=%.2f, floor=%.2f)"
				% [here.y, fc.y])
		p.report(worst_stall < 60, "never snagged climbing the ramp (worst stall %d frames)" % worst_stall)

		p.finish()
