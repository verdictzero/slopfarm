extends Node
## Perf harness for the Pi. Run:
##   godot-4 --path . tools/perf.tscn
## Vsync off so numbers show headroom rather than a 60 fps ceiling. Every pass warms
## the chunk cache first: measuring a cold cache measures mesh generation, not
## rendering, and whichever pass runs second inherits the first one's warm chunks.

const SAMPLE_SECONDS := 8.0

@onready var main: Node3D = $Main

var _terrain: TerrainManager
var _player: Player

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	_terrain = main.get_node("TerrainManager")
	_player = _terrain.player as Player
	_player.set_physics_process(false)
	_player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# The view that actually matters: standing on the farm, looking out at the hills.
	await _pass("farm, eye height, static", Vector3.ZERO, 2.0, false)
	await _pass("farm, eye height, walking", Vector3.ZERO, 2.0, true)
	await _pass("elevated +40, static", Vector3.ZERO, 40.0, false)

	get_tree().quit()

func _pass(label: String, origin: Vector3, height: float, walk: bool) -> void:
	# Warm the cache at this spot before timing anything.
	_terrain.chunks_per_frame = 60
	_place(origin, height)
	for i in 90:
		await get_tree().process_frame
	_terrain.chunks_per_frame = 2

	var elapsed := 0.0
	var draws := 0.0
	var frames := 0
	var travelled := 0.0
	var deltas: Array[float] = []

	while elapsed < SAMPLE_SECONDS:
		await get_tree().process_frame
		var delta := get_process_delta_time()
		elapsed += delta
		frames += 1
		deltas.append(delta * 1000.0)
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		if walk:
			# Sprint speed, so chunk crossings and LOD rebuilds happen under measurement.
			travelled += 18.0 * delta
			_place(origin + Vector3(0.0, 0.0, -travelled), height)

	# Median, not mean: this box runs a browser and the editor, and background load can
	# only add time. The mean chases whatever else is running.
	deltas.sort()
	var median := deltas[deltas.size() / 2]
	var p90 := deltas[int(deltas.size() * 0.90)]
	var vram: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	print("%-26s | median %5.2f ms (%5.1f fps) | p90 %5.2f ms | draws %5.1f | vram %4.1f MB" % [
		label, median, 1000.0 / median, p90, draws / frames, vram])

func _place(pos: Vector3, height: float) -> void:
	_player.global_position = Vector3(pos.x, _terrain.height_at(pos.x, pos.z) + height, pos.z)
	_player.rotation.y = deg_to_rad(-70.0)
	_player.camera.rotation.x = 0.02
