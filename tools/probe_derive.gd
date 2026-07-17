extends SceneTree
## Times the plan's derived work — gates, tracks, trampling — because all three run on
## every live reload, and the designer's whole premise is that saving feels instant.
## Run:  godot-4 --headless --path . --script res://tools/probe_derive.gd
func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var plan := FarmPlan.load_from("res://farm/plan.json")
	var load_ms := Time.get_ticks_msec() - t0
	print("load_from (parse + gates + roads): %d ms | loaded=%s" % [load_ms, plan.loaded])
	print("  gates: %d, road cells: %d, structures: %d" % [
		plan.gates.size(), plan.roads.size(), plan.structures.size()])

	var t1 := Time.get_ticks_msec()
	var roads := FarmRoads.derive(plan)
	print("  FarmRoads.derive alone: %d ms -> %d cells" % [Time.get_ticks_msec() - t1, roads.size()])

	var fresh := FarmPlan.load_from("res://farm/plan.json")
	var t2 := Time.get_ticks_msec()
	fresh.trample_field()
	print("  trample_field alone: %d ms" % [Time.get_ticks_msec() - t2])
	var t3 := Time.get_ticks_msec()
	fresh.trample_field()
	print("  trample_field cached: %d ms" % [Time.get_ticks_msec() - t3])
	quit()
