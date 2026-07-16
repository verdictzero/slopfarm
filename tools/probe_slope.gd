extends SceneTree
## Slope distribution of the terrain, so texture slope rules get thresholds that the
## ground actually reaches. Run:
##   godot-4 --headless --path . --script res://tools/probe_slope.gd
##
## This exists because a previous slope rule (rock below normal.y 0.6, i.e. steeper
## than 53 degrees) was dead code: rolling hills never get near it.

func _init() -> void:
	var terrain = load("res://scripts/terrain_manager.gd").new()
	terrain._ready()

	# Sample at the mesh's own facet size, not an arbitrary epsilon: the shader reads
	# per-face normals, so this is the slope it will actually see.
	var step: float = terrain.chunk_size / float(terrain.chunk_resolution)

	var bands := [[0.0, 380.0, "farm basin"], [380.0, 700.0, "hill ring"],
			[700.0, 960.0, "outer visible"], [960.0, 3000.0, "far country"]]
	print("band              p50    p75    p90    p95    p99    max   (degrees from level)")
	for band in bands:
		var inner: float = band[0]
		var outer: float = band[1]
		var slopes: Array[float] = []
		for i in 12000:
			var angle := TAU * float(i) * 0.61803398875
			var t := float(i) / 12000.0
			var r: float = sqrt(inner * inner + t * (outer * outer - inner * inner))
			var x := cos(angle) * r
			var z := sin(angle) * r
			var h: float = terrain.height_at(x, z)
			var hx: float = terrain.height_at(x + step, z)
			var hz: float = terrain.height_at(x, z + step)
			var grad := Vector2(hx - h, hz - h) / step
			slopes.append(rad_to_deg(atan(grad.length())))
		slopes.sort()
		print("%-14s %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f" % [
			band[2],
			slopes[int(slopes.size() * 0.50)], slopes[int(slopes.size() * 0.75)],
			slopes[int(slopes.size() * 0.90)], slopes[int(slopes.size() * 0.95)],
			slopes[int(slopes.size() * 0.99)], slopes[slopes.size() - 1]])

	# What fraction of the *visible* world would each rule claim? Weighted by area
	# across the whole draw distance, which is what the player actually sees.
	print("")
	print("share of visible ground a slope rule would claim (0-960 units, area-weighted):")
	var thresholds := [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 15.0, 18.0, 22.0, 26.0, 30.0]
	var counts := {}
	for th: float in thresholds:
		counts[th] = 0
	var total := 0
	for i in 40000:
		var angle := TAU * float(i) * 0.61803398875
		var r: float = sqrt(float(i) / 40000.0) * 960.0
		var x := cos(angle) * r
		var z := sin(angle) * r
		var h: float = terrain.height_at(x, z)
		var grad := Vector2(terrain.height_at(x + step, z) - h,
				terrain.height_at(x, z + step) - h) / step
		var deg := rad_to_deg(atan(grad.length()))
		for th: float in thresholds:
			if deg > th:
				counts[th] += 1
		total += 1
	for th: float in thresholds:
		print("  steeper than %4.1f deg: %5.1f%%" % [th, 100.0 * counts[th] / total])

	quit()
