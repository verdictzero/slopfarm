extends SceneTree
## Regression for the bug the review caught: opening the DMG menu WHILE DRIVING used to run the
## pinned driver through move_and_slide, which the truck's new solid collision box then depenetrated
## — flinging the driver (the world's streaming anchor) off the truck. Asserts:
##   - _toggle_menu() does nothing while driving (you can't open the menu at the wheel);
##   - even if _menu_open is forced true while driving, the driver stays pinned to the truck.
## Run: godot --headless --path . --script res://tools/probe_drive_menu.gd

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

	func _find(node: Node, want: String) -> Node:
		if (want == "Truck" and node is Truck) or (want == "Player" and node is Player):
			return node
		for c in node.get_children():
			var hit := _find(c, want)
			if hit != null:
				return hit
		return null

	func _run() -> void:
		var main := (load("res://world.tscn") as PackedScene).instantiate()
		p.root.add_child(main)
		p.current_scene = main
		for i in 40:
			await p.physics_frame

		var truck := _find(main, "Truck") as Truck
		var player := _find(main, "Player") as Player
		p.report(truck != null and player != null, "world has a truck and a player")
		if truck == null or player == null:
			p.finish()
			return

		# Sit the player on the truck and take the wheel, the way F does.
		player.global_position = truck.global_position + Vector3.UP * 1.0
		player._driving = truck
		truck.enter(player)
		for i in 10:
			await p.physics_frame

		# You cannot open the menu at the wheel.
		player._toggle_menu()
		p.report(not player._menu_open, "_toggle_menu() is a no-op while driving")

		# Force the menu open anyway (the state the old bug reached) and confirm the driver stays
		# pinned to the truck rather than being shoved out of the collision box.
		player._menu_open = true
		var max_off := 0.0
		for i in 40:
			await p.physics_frame
			var off := player.global_position.distance_to(truck.global_position + Vector3.UP * 1.0)
			max_off = maxf(max_off, off)
		p.report(max_off < 0.2, "the driver stays pinned to the truck with the menu open (off %.2f m)" % max_off)

		p.finish()
