extends Node
## Screenshots of the authored farm. Run:  godot-4 --path . tools/farmshot.tscn
const SHOT_DIR := "res://.shots"
@onready var main: Node3D = $Main
func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var terrain: TerrainManager = main.get_node("TerrainManager")
	terrain.chunks_per_frame = 60
	var player := terrain.player as Player
	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var views := [
		["farm_air", Vector3(20, 150, 90), Vector3(30, 0, -10)],
		["farm_yard", Vector3(-4, 6, 34), Vector3(34, 2, -18)],
		["farm_pen", Vector3(60, 5, 14), Vector3(100, 1, -18)],
		["farm_crop_in", Vector3(50, 1.7, 80), Vector3(90, 1.2, 130)],
		["farm_crop_edge", Vector3(20, 3.0, 34), Vector3(70, 0.5, 110)],
	]
	for v in views:
		var eye: Vector3 = v[1]
		var look: Vector3 = v[2]
		player.global_position = Vector3(eye.x, terrain.height_at(eye.x, eye.z) + eye.y, eye.z)
		player.look_at(Vector3(look.x, terrain.height_at(look.x, look.z) + look.y, look.z), Vector3.UP)
		var pitch := player.rotation.x
		player.rotation.x = 0.0
		player.camera.rotation.x = pitch
		for i in 40:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [SHOT_DIR, v[0]])
		print("shot: ", v[0], "  draws=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"  vram=", int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0), "MB")
	get_tree().quit()
