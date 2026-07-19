extends Node3D
## dmgkit demo / usage example: streamed low-poly terrain under the green-LCD dither, with a camera
## slowly orbiting so you can watch chunks stream in. Everything is built in code here so this file
## doubles as the "how do I wire it up" reference — in a real game you would drop the same nodes into
## your scene and point DmgTerrain.player at your character.

var _cam: Camera3D
var _anchor: Node3D
var _ui: DmgUI
var _t := 0.0


func _ready() -> void:
	# A little sky + ambient so the world is lit before the palette snaps it to greens.
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.66, 0.32)
	e.ambient_light_color = Color(0.62, 0.70, 0.42)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -37.0, 0.0)
	sun.light_energy = 1.15
	add_child(sun)

	# 1) The streaming terrain. It builds/frees chunks around whatever node you set as `player`.
	_anchor = Node3D.new()
	add_child(_anchor)

	var terrain := DmgTerrain.new()
	terrain.player = _anchor
	add_child(terrain)
	terrain.prime(Vector3.ZERO)   # solid ground the instant we start

	# 2) The camera.
	_cam = Camera3D.new()
	_cam.far = 4000.0
	add_child(_cam)
	_cam.current = true

	# 3) The signature green-LCD dither over the whole viewport. Anything on a CanvasLayer above
	#    layer 100 (a HUD, a menu) stays crisp on top of the dithered world.
	add_child(DmgDither.create(100, 3.0, 0.17))

	# 4) A crisp DMG HUD + menu (layer 112, above the dither). Content is plain data — nothing here
	#    is game-specific. Call ui.open_menu() / ui.nav() / ui.activate() to drive the menu.
	_ui = DmgUI.new()
	add_child(_ui)
	_ui.set_readouts([
		{"label": "SCORE", "value": "01200", "side": 0},
		{"label": "LIVES", "value": "03", "unit": "x", "side": 1},
	])
	_ui.set_menu_items([
		{"title": "STATUS", "lines": ["SCORE   01200", "LIVES   3"],
			"stats": [["BEST", "09400"], ["TIME", "02:14"]], "desc": "HOW YOU ARE DOING"},
		{"title": "OPTIONS", "lines": ["SOUND   ON", "SHAKE   OFF"], "desc": "TWEAK THE GAME"},
		{"title": "QUIT", "lines": ["LEAVE TO DESKTOP"], "desc": "PRESS A TO QUIT"},
	])


func _process(delta: float) -> void:
	_t += delta * 0.12
	var r := 130.0
	var eye := Vector3(cos(_t) * r, 58.0, sin(_t) * r)
	_cam.global_position = eye
	# Stream ground around the camera by moving the anchor under it.
	_anchor.global_position = Vector3(eye.x, 0.0, eye.z)
	_cam.look_at(Vector3(0.0, 8.0, 0.0), Vector3.UP)
