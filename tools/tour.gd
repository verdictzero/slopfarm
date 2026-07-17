extends Node
## Screenshot tour of the reworked world, for eyeballing the factory, gore, truck, trees and a
## town. Run under a virtual display (software GL):
##   xvfb-run -a godot --path . --resolution 1280x720 tools/tour.tscn
## Writes .shots/tour_*.png then quits. Not shipped with the game.

const SHOT_DIR := "res://.shots"

@onready var main: Node3D = $Main


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var terrain: TerrainManager = main.get_node("TerrainManager")
	terrain.chunks_per_frame = 80
	var player := terrain.player as Player
	if player == null:
		await get_tree().process_frame
		player = terrain.player as Player
	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# (camera pos, look-at target, settle frames, name)
	var shots := [
		[Vector3(10, 8, 5), Vector3(45, 6, -28), 90, "farm_buildings"],
		[Vector3(120, 10, -70), Vector3(210, 8, -20), 90, "factory_approach"],
		[Vector3(176, 7, -26), Vector3(172, 5, -26), 70, "grinder_gore"],
		[Vector3(158, 9, -20), Vector3(210, 1, 6), 90, "belt_interior"],
		[Vector3(144, 3, 12), Vector3(150, 1, 5), 70, "truck"],
		[Vector3(90, 14, 40), Vector3(230, 4, -8), 90, "works_wide"],
		[Vector3(430, 12, 150), Vector3(470, 4, 190), 120, "town_tallowmarket"],
		[Vector3(60, 6, 120), Vector3(120, 3, 200), 140, "groves"],
	]
	for s in shots:
		_aim(player, terrain, s[0], s[1])
		await _settle(int(s[2]))
		await _capture(String(s[3]))
	get_tree().quit()


func _aim(player: Player, terrain: TerrainManager, cam: Vector3, target: Vector3) -> void:
	# Keep the camera above the ground under it, in case a viewpoint was placed low on a slope.
	var floor_y := terrain.height_at(cam.x, cam.z) + 1.5
	cam.y = maxf(cam.y, floor_y)
	player.global_position = cam
	var dir := target - cam
	player.rotation.y = atan2(-dir.x, -dir.z)
	var horiz := Vector2(dir.x, dir.z).length()
	player.camera.rotation.x = atan2(dir.y, horiz)


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png("%s/tour_%s.png" % [SHOT_DIR, name])
	print("shot: ", name)
