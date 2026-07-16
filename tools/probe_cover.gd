extends SceneTree
## What the ground-cover rules actually claim, area-weighted over the visible world.
## Run:  godot-4 --headless --path . --script res://tools/probe_cover.gd
##
## Mirrors the arithmetic in shaders/terrain.gdshader exactly. A rule that claims ~0%
## is dead code; one that claims ~100% has quietly replaced the default. Both have
## happened here, so this is checked rather than eyeballed.

func _init() -> void:
	var terrain = load("res://scripts/terrain_manager.gd").new()
	terrain._ready()

	var step: float = terrain.chunk_size / float(terrain.chunk_resolution)
	var dirt_begin_cos: float = cos(deg_to_rad(terrain.dirt_slope_begin_degrees))
	var dirt_full_cos: float = cos(deg_to_rad(terrain.dirt_slope_full_degrees))
	var rock_begin_cos: float = cos(deg_to_rad(terrain.rock_slope_begin_degrees))
	var rock_full_cos: float = cos(deg_to_rad(terrain.rock_slope_full_degrees))
	var water: float = terrain.water_level

	for band: Array in [[0.0, 210.0, "farmyard"], [0.0, 380.0, "basin"],
			[380.0, 960.0, "hills"], [0.0, 960.0, "ALL VISIBLE"]]:
		var inner: float = band[0]
		var outer: float = band[1]
		var grass_sum := 0.0
		var dirt_sum := 0.0
		var rock_sum := 0.0
		var from_slope := 0.0
		var from_hollow := 0.0
		var from_plot := 0.0
		var samples := 0
		for i in 30000:
			var angle := TAU * float(i) * 0.61803398875
			var t := float(i) / 30000.0
			var r: float = sqrt(inner * inner + t * (outer * outer - inner * inner))
			var x := cos(angle) * r
			var z := sin(angle) * r

			var h: float = terrain.height_at(x, z)
			# Face normal the way the mesh builds it, from the facet's own corners.
			var hx: float = terrain.height_at(x + step, z)
			var hz: float = terrain.height_at(x, z + step)
			var normal := Vector3(-(hx - h) / step, 1.0, -(hz - h) / step).normalized()
			var up := clampf(normal.y, 0.0, 1.0)

			var to_dirt := 1.0 - smoothstep(dirt_full_cos, dirt_begin_cos, up)
			var to_rock := 1.0 - smoothstep(rock_full_cos, rock_begin_cos, up)
			var hollow := 1.0 - smoothstep(water, water + 3.0, h)
			var plot: float = _plot_mask(x, z, terrain)

			from_slope += to_dirt
			from_hollow += hollow
			from_plot += plot

			to_dirt = maxf(to_dirt, maxf(plot, hollow))
			to_rock = minf(to_rock, 1.0 - plot)
			# Same mix order as the shader: grass -> dirt, then that -> rock.
			var g := (1.0 - to_dirt) * (1.0 - to_rock)
			var d := to_dirt * (1.0 - to_rock)
			grass_sum += g
			dirt_sum += d
			rock_sum += to_rock
			samples += 1

		print("%-12s grass %5.1f%%  dirt %5.1f%%  rock %5.1f%%   (dirt comes from: slope %4.1f%%, hollow %4.1f%%, plots %4.1f%%)" % [
			band[2], 100.0 * grass_sum / samples, 100.0 * dirt_sum / samples,
			100.0 * rock_sum / samples, 100.0 * from_slope / samples,
			100.0 * from_hollow / samples, 100.0 * from_plot / samples])

	quit()


func _plot_mask(x: float, z: float, terrain) -> float:
	var cell: Vector2 = Vector2(floorf(x / float(terrain.plot_cell)), floorf(z / float(terrain.plot_cell)))
	var centre: Vector2 = (cell + Vector2(0.5, 0.5)) * float(terrain.plot_cell)
	var centre_r: float = centre.length()
	if centre_r >= terrain.yard_radius:
		return 0.0
	var h1 := _hash22(cell)
	var h2 := _hash22(cell + Vector2(31.7, 17.3))
	var falloff: float = 1.0 - clampf((centre_r / float(terrain.yard_radius) - 0.35) / 0.65, 0.0, 1.0)
	if h1.x >= terrain.plot_density * falloff:
		return 0.0
	var margin: Vector2 = Vector2(0.05, 0.05) + 0.13 * Vector2(h1.y, h2.x)
	var local: Vector2 = Vector2(x / float(terrain.plot_cell) - cell.x, z / float(terrain.plot_cell) - cell.y)
	if local.x > margin.x and local.x < 1.0 - margin.x \
			and local.y > margin.y and local.y < 1.0 - margin.y:
		return 1.0
	return 0.0


func _hash22(p: Vector2) -> Vector2:
	var p3 := Vector3(p.x * 0.1031, p.y * 0.1030, p.x * 0.0973)
	p3 = Vector3(p3.x - floorf(p3.x), p3.y - floorf(p3.y), p3.z - floorf(p3.z))
	var d: float = p3.dot(Vector3(p3.y, p3.z, p3.x) + Vector3(33.33, 33.33, 33.33))
	p3 += Vector3(d, d, d)
	var a := (p3.x + p3.y) * p3.z
	var b := (p3.x + p3.z) * p3.y
	return Vector2(a - floorf(a), b - floorf(b))
