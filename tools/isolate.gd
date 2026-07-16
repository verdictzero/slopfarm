extends Node
## Measures ONE configuration per process. Run:
##   godot-4 --path . tools/isolate.tscn -- mode=<mode>
## Modes: full, nopost, noterrain, skyonly, empty, noshadow, nofog, near, notex
##
## Compare modes only across runs taken back to back: this box's load moves enough that
## a number from ten minutes ago is not a baseline for a number from now.
##
## Reports the viewport's measured GPU and CPU render time, not wall-clock fps. This
## box runs a browser and the Godot editor, so wall-clock frame time mostly measures
## whoever else is using the cores; GPU time is what our rendering actually costs.

const SAMPLE_SECONDS := 6.0

@onready var main: Node3D = $Main

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var mode := "full"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("mode="):
			mode = arg.split("=")[1]

	var terrain: TerrainManager = main.get_node("TerrainManager")
	var player := terrain.player as Player
	var sun: DirectionalLight3D = main.get_node("Sun")
	var env: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var post: CanvasLayer = main.get_node("PostProcess")

	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	match mode:
		"nopost":
			post.get_parent().remove_child(post)
		"noterrain":
			terrain.visible = false
		"skyonly":
			terrain.visible = false
			post.get_parent().remove_child(post)
		"empty":
			terrain.visible = false
			post.get_parent().remove_child(post)
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0.7, 0.8, 0.9)
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.fog_enabled = false
			sun.shadow_enabled = false
		"noshadow":
			sun.shadow_enabled = false
		"nofog":
			env.fog_enabled = false
		"near":
			terrain.view_distance = 4
		"notex", "notex_fill":
			# Baseline for the ground-cover shader's cost: same geometry, same vertex
			# data, but a stock material with zero texture samples and no plot maths.
			var plain := StandardMaterial3D.new()
			plain.vertex_color_use_as_albedo = true
			plain.roughness = 1.0
			plain.cull_mode = BaseMaterial3D.CULL_DISABLED
			# Future chunks...
			terrain.set("_material", plain)
			# ...and the ones prime() already built, which hold their own override.
			for child in terrain.get_children():
				if child is MeshInstance3D:
					(child as MeshInstance3D).material_override = plain

	var viewport_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)

	terrain.chunks_per_frame = 60
	player.global_position = Vector3(0.0, terrain.height_at(0.0, 0.0) + 2.0, 0.0)
	player.rotation.y = deg_to_rad(-70.0)
	player.camera.rotation.x = 0.02

	# Stress view: straight down, so terrain covers 100% of the screen instead of the
	# ~50% a normal view gives. Per-fragment costs that vanish into vsync pacing at
	# normal coverage show up here, and halving the delta approximates the real cost.
	if mode.ends_with("_fill"):
		player.global_position = Vector3(0.0, terrain.height_at(0.0, 0.0) + 9.0, 0.0)
		player.camera.rotation.x = -1.55
	for i in 180:
		await get_tree().process_frame
	terrain.chunks_per_frame = 2

	var elapsed := 0.0
	var cpu := 0.0
	var draws := 0.0
	var frames := 0
	var deltas: Array[float] = []
	while elapsed < SAMPLE_SECONDS:
		await get_tree().process_frame
		var delta := get_process_delta_time()
		elapsed += delta
		deltas.append(delta * 1000.0)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		frames += 1

	# Other processes can only ever make a frame slower, never faster, so under
	# contention the fast tail is the honest estimate of our own cost. The mean just
	# measures the browser.
	deltas.sort()
	var best := deltas[0]
	var p10 := deltas[int(deltas.size() * 0.10)]
	var median := deltas[deltas.size() / 2]
	print("RESULT %-10s | best %5.2f ms (%5.1f fps) | p10 %5.2f | median %5.2f | rendercpu %4.2f | draws %5.1f" % [
		mode, best, 1000.0 / best, p10, median, cpu / frames, draws / frames])
	get_tree().quit()
