extends SceneTree
## Boots the real game headless and drives the reworked interactions end to end, so a change
## that parses but breaks at runtime is caught. Checks: the world boots; the player is on its
## own collision layer; a bopped cow becomes a ragdoll; grab floats it and drives it toward a
## hold point while colliding; release hands it back to gravity; respawn warps to spawn.
## Run: godot --headless --path . --script res://tools/probe_boot.gd

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

	func _find(node: Node, type) -> Node:
		if is_instance_of(node, type):
			return node
		for c in node.get_children():
			var hit := _find(c, type)
			if hit != null:
				return hit
		return null

	func _run() -> void:
		var main := (load("res://main.tscn") as PackedScene).instantiate()
		# Make it the current scene, the way the engine does when it autoloads main_scene: a
		# knocked-out cow parents its ragdoll to get_tree().current_scene, so this has to be set.
		p.root.add_child(main)
		p.current_scene = main
		# Let the farm build and terrain prime.
		for i in 40:
			await p.physics_frame

		var player := _find(main, Player) as Player
		p.report(player != null, "world booted with a player")
		if player == null:
			p.finish()
			return
		p.report(player.collision_layer == 0b100 and player.collision_mask == 0b001,
				"player on its own layer (layer=%d mask=%d)" % [player.collision_layer, player.collision_mask])

		var horses := p.get_nodes_in_group("horse")
		p.report(horses.size() > 0, "cows spawned (%d in the herd)" % horses.size())
		if horses.is_empty():
			p.finish()
			return

		# Bop one: a single hit should retire the living animal and leave a ragdoll behind.
		var victim := horses[0] as FarmAnimal
		victim.take_hit(Vector3(0, 0, 1))
		await p.physics_frame
		await p.physics_frame
		var rags := p.get_nodes_in_group("ragdoll")
		p.report(rags.size() > 0, "one hit auto-ragdolled the cow (%d ragdoll)" % rags.size())
		if rags.is_empty():
			p.finish()
			return
		var rag := rags[0] as HorseRagdoll

		# Put it a known distance in front (in open air, above ground) so the carry test is
		# deterministic rather than depending on which distant pen the cow spawned in. Placed
		# beyond the hold point so the drive has to reel it IN toward the camera.
		var look := -player.camera.global_transform.basis.z
		rag.global_position = player.camera.global_position + look * 6.0
		await p.physics_frame

		# Grab it: gravity off, still colliding, and the player drives it toward the hold point.
		rag.grab()
		p.report(rag.is_carried() and rag.gravity_scale == 0.0, "grab floats the cow (gravity off)")
		p.report(rag.collision_mask == HorseRagdoll.WORLD_LAYER,
				"held cow still collides with the world (mask=%d)" % rag.collision_mask)
		# Simulate the player carrying it: the drive should reel it in to the hold point.
		player.set("_carried", rag)
		var before := rag.global_position.distance_to(player.camera.global_position)
		for i in 60:
			await p.physics_frame
		var after := rag.global_position.distance_to(player.camera.global_position)
		p.report(rag.global_position.is_finite(), "carried cow stayed finite while driven")
		p.report(after < before and after <= Player.CARRY_DISTANCE + 1.0,
				"carry reeled the cow to the hold point (%.2f m -> %.2f m from camera)" % [before, after])

		# Release: gravity back, a parting toss.
		rag.release(Vector3(0, 1, 0))
		player.set("_carried", null)
		p.report(not rag.is_carried() and rag.gravity_scale == 1.0, "release hands it back to gravity")

		# Respawn failsafe: warp home.
		player.global_position = Vector3(300, 200, 300)
		await p.physics_frame
		player.call("_respawn")
		await p.physics_frame
		var home := player.global_position.distance_to(player.spawn_point)
		p.report(home < 5.0, "respawn warped the player home (%.1f m from spawn)" % home)

		p.finish()
