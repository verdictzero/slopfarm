extends Node
## Boots main.tscn (the shell) and screenshots it, for eyeballing the native UI headless.
##   portrait console:  SLOPFARM_TOUCH=1 xvfb-run -a godot --path . --resolution 540x1170 tools/gb_shot.tscn
##   desktop fullscreen: xvfb-run -a godot --path . --resolution 960x540 tools/gb_shot.tscn
## Writes res://.shots/gb_console.png then quits. Not shipped with the game.
func _ready() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	for i in 20: await get_tree().process_frame
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		var pl = players[0]
		pl.set_physics_process(false)
		var cam := Vector3(90, 14, 40)
		var tgt := Vector3(230, 4, -8)
		pl.global_position = cam
		var dir := tgt - cam
		pl.rotation.y = atan2(-dir.x, -dir.z)
		pl.camera.rotation.x = atan2(dir.y, Vector2(dir.x, dir.z).length())
		if pl.terrain:
			pl.terrain.chunks_per_frame = 200
			pl.terrain.prime(cam)
	for i in 40: await get_tree().process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.shots"))
	get_viewport().get_texture().get_image().save_png("res://.shots/gb_console.png")
	get_tree().quit()
