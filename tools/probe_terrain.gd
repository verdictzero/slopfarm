extends SceneTree
## Headless sanity check on the height field's shape. Run:
##   godot-4 --headless --path . --script res://tools/probe_terrain.gd
## Reports height and slope statistics per radial band, so "flat dominates near the
## farm, hills only far out" can be checked as numbers rather than vibes.

func _init() -> void:
	var terrain = load("res://scripts/terrain_manager.gd").new()
	terrain._ready()  # Not in the tree, so wire up the noise by hand.

	print("band(units)     mean|h|   max h   flat%   hill%  (flat = slope < 4 deg, hill = h > 30)")
	var bands := [[0, 380], [380, 700], [700, 960], [960, 2000], [2000, 4000]]
	for band in bands:
		var inner: float = band[0]
		var outer: float = band[1]
		var sum_abs := 0.0
		var max_h := -1e9
		var flat := 0
		var hilly := 0
		var samples := 0
		# Even-ish area sampling across the annulus.
		for i in 4000:
			var angle := TAU * float(i) * 0.61803398875
			var t := float(i) / 4000.0
			var r: float = sqrt(inner * inner + t * (outer * outer - inner * inner))
			var x := cos(angle) * r
			var z := sin(angle) * r
			var h: float = terrain.height_at(x, z)
			var hx: float = terrain.height_at(x + 6.0, z)
			var hz: float = terrain.height_at(x, z + 6.0)
			var slope: float = Vector2(hx - h, hz - h).length() / 6.0
			sum_abs += absf(h)
			max_h = maxf(max_h, h)
			if slope < tan(deg_to_rad(4.0)):
				flat += 1
			if h > 30.0:
				hilly += 1
			samples += 1
		print("%5d-%-5d %9.1f %7.1f %6.1f %6.1f" % [
			inner, outer, sum_abs / samples, max_h,
			100.0 * flat / samples, 100.0 * hilly / samples])

	# Area coverage does not answer the question that matters: standing on the farm and
	# turning around, how much of the horizon actually has something on it? Walk each
	# sightline out through the ring and record the tallest thing along it.
	var dirs := 720
	var with_prominent := 0
	var with_hill := 0
	var empty_run := 0
	var worst_run := 0
	for d in dirs:
		var angle := TAU * float(d) / float(dirs)
		var peak := -1e9
		for step in 60:
			var r := 380.0 + float(step) * 10.0  # 380 -> 980
			peak = maxf(peak, terrain.height_at(cos(angle) * r, sin(angle) * r))
		if peak > 55.0:
			with_prominent += 1
		if peak > 25.0:
			with_hill += 1
		if peak > 25.0:
			empty_run = 0
		else:
			empty_run += 1
			worst_run = maxi(worst_run, empty_run)
	print("")
	print("from the farm, looking out through the 380-980 ring:")
	print("  %.1f%% of sightlines end in a prominent hill (peak > 55)" % (100.0 * with_prominent / dirs))
	print("  %.1f%% end in at least some rise (peak > 25)" % (100.0 * with_hill / dirs))
	print("  widest gap of flat horizon: %.0f degrees" % (360.0 * worst_run / dirs))

	quit()
