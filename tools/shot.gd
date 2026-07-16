extends Node
## Screenshot rig for eyeballing terrain and the dither pass. Run:
##   godot-4 --path . --resolution 1280x720 tools/shot.tscn
## Writes .shots/*.png, then quits. Not shipped with the game.

const SHOT_DIR := "res://.shots"

@onready var main: Node3D = $Main

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

	var terrain: TerrainManager = main.get_node("TerrainManager")
	# This is a screenshot rig, not gameplay: stream everything in immediately rather
	# than trickling chunks over seconds.
	terrain.chunks_per_frame = 60

	var player := terrain.player as Player
	player.set_physics_process(false)
	# The player captures the mouse and yaws on any motion, so a stray twitch during a
	# run silently reframes the shot. Cut input off entirely.
	player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var dither: ColorRect = main.get_node("PostProcess/Dither")

	# Standing on the farm, turning around: does the horizon have hills on it?
	for i in 8:
		var yaw := TAU * float(i) / 8.0
		_place(player, terrain, Vector3.ZERO, yaw, -0.04)
		await _settle()
		await _capture("farm_yaw%d" % (i * 45))

	# Same view with the post-process off, to compare against.
	dither.visible = false
	_place(player, terrain, Vector3.ZERO, 0.0, -0.04)
	await _settle()
	await _capture("compare_nodither")
	dither.visible = true
	await _settle()
	await _capture("compare_dither")

	# Up high, to read the basin -> hills layout in one frame.
	_place(player, terrain, Vector3.ZERO, 0.0, -0.30, 150.0)
	await _settle()
	await _capture("overview")

	# Out in the hills, checking they hold up close and that LOD seams don't gape.
	_place(player, terrain, Vector3(0.0, 0.0, -560.0), 0.0, 0.0, 12.0)
	await _settle()
	await _capture("in_hills")

	get_tree().quit()

func _place(player: Player, terrain: TerrainManager, pos: Vector3, yaw: float,
		pitch: float, height: float = 2.0) -> void:
	player.global_position = Vector3(
		pos.x, terrain.height_at(pos.x, pos.z) + height, pos.z)
	player.rotation.y = yaw
	player.camera.rotation.x = pitch

func _settle() -> void:
	# Long enough for the build queue to drain and shadows to settle.
	for i in 40:
		await get_tree().process_frame

func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png("%s/%s.png" % [SHOT_DIR, name])
	print("shot: ", name)
