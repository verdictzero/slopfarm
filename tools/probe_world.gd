extends SceneTree
## Drives the wider world headless: roads and towns build, the market marker exists, trees
## stream, and the sell loop works end to end — board the truck, it follows the terrain, step
## out, load glue at the dock, sell it at a market for money.
## Run: godot --headless --path . --script res://tools/probe_world.gd

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
		for i in 60:
			await p.physics_frame

		var player := _first(main, Player) as Player
		var factory := _first(main, GlueFactory) as GlueFactory
		var truck := _first(main, Truck) as Truck
		var roads := _first(main, CountryRoads)
		var towns := _first(main, TownBuilder)
		var trees := _first(main, TreeScatter)
		p.report(player != null and factory != null, "world booted with player and works")
		p.report(roads != null, "country roads built")
		p.report(towns != null, "towns built")
		p.report(truck != null, "truck spawned")
		p.report(p.get_nodes_in_group("glue_market").size() >= 2, "market depots registered (%d)"
				% p.get_nodes_in_group("glue_market").size())
		if player == null or truck == null or factory == null:
			p.finish()
			return
		# Trees stream around the player.
		for i in 30:
			await p.physics_frame
		p.report(trees != null and trees._tiles.size() > 0, "tree tiles streamed (%d)"
				% (trees._tiles.size() if trees != null else 0))

		# Board the truck.
		player.global_position = truck.global_position + Vector3(2, 1, 0)
		await p.physics_frame
		player._toggle_truck()
		p.report(truck.is_driven() and player._driving == truck, "boarding hands control to the truck")

		# Drive it: give it throttle and let it roll; it must move, stay finite, and ride on the
		# terrain surface.
		var start := truck.global_position
		truck._speed = 18.0
		for i in 30:
			await p.physics_frame
		var here := truck.global_position
		var ride := here.y - truck._terrain.height_at(here.x, here.z)
		p.report(here.is_finite() and start.distance_to(here) > 2.0, "the truck drove off (%.1f m)"
				% start.distance_to(here))
		p.report(absf(ride - Truck.RIDE_HEIGHT) < 0.6, "the truck rides on the ground (%.2f m up)" % ride)

		# Step out.
		player._toggle_truck()
		p.report(not truck.is_driven() and player._driving == null, "stepping out returns control")

		# Load glue off the dock.
		factory._glue_ready = 4
		player.global_position = factory.dock_world()
		await p.physics_frame
		player._interact()
		p.report(player.glue == 4 and factory.ready_glue() == 0, "loaded glue off the dock")

		# Sell it at a market.
		var market := p.get_nodes_in_group("glue_market")[0] as Node3D
		player.global_position = market.global_position
		await p.physics_frame
		player.money = 0
		player._interact()
		p.report(player.glue == 0 and player.money == 4 * Player.GLUE_PRICE,
				"sold the load for $%d" % player.money)

		p.finish()
