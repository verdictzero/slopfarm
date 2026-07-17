extends SceneTree
## Drives the reworked glue factory headless: the world boots, the works exists, a feed at the
## intake is accepted and spawns a batch, the batch advances along the winding belt, and the
## glue-economy hooks (ready_glue / collect_glue / dock_world) behave.
## Run: godot --headless --path . --script res://tools/probe_factory.gd

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

	func _find(node: Node, cls: String) -> Node:
		if node.get_class() == cls or (node.get_script() != null and node.is_class(cls)):
			pass
		if node is GlueFactory:
			return node
		for c in node.get_children():
			var hit := _find(c, cls)
			if hit != null:
				return hit
		return null

	func _run() -> void:
		var main := (load("res://main.tscn") as PackedScene).instantiate()
		p.root.add_child(main)
		p.current_scene = main
		for i in 40:
			await p.physics_frame

		var factory := _find(main, "GlueFactory") as GlueFactory
		p.report(factory != null, "the glue works exists")
		if factory == null:
			p.finish()
			return

		p.report(factory.ready_glue() == 0, "dock starts empty")
		p.report(factory.dock_world().is_finite(), "dock has a world position")

		# Feed from far away is refused; feed at the intake is accepted.
		p.report(not factory.try_feed(Vector3(9999, 0, 9999)), "feed from across the map is refused")
		var accepted := factory.try_feed(factory._feed_world)
		p.report(accepted, "feed at the intake hopper is accepted")

		var batches: Array = factory._batches
		p.report(batches.size() == 1, "the feed spawned one batch on the line")

		# Let it ride the belt a while; it must advance past the first machines and stay finite.
		var start_at := int(batches[0]["at"]) if not batches.is_empty() else 0
		for i in 240:
			await p.process_frame
		var moved := false
		var finite := true
		if not factory._batches.is_empty():
			var b: Dictionary = factory._batches[0]
			moved = int(b["at"]) > start_at
			finite = (b["node"] as Node3D).position.is_finite()
		else:
			moved = true   # already finished the whole line
		p.report(moved, "the batch advanced along the winding belt")
		p.report(finite, "the product stayed finite while conveyed")

		# collect_glue drains the dock counter.
		var before := factory.ready_glue()
		var taken := factory.collect_glue()
		p.report(taken == before and factory.ready_glue() == 0, "collect_glue drains the dock")

		p.finish()
