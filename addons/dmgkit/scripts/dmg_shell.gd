extends Control
class_name DmgShell
## Renders your game into a fixed-resolution SubViewport (so the dither runs at a constant "LCD"
## resolution no matter the window size), then presents it two ways:
##   - a real handheld export -> a DmgConsole faceplate with the world in its LCD window and touch input;
##   - desktop / web -> the buffer shown in a NEAREST-scaled TextureRect (integer-upscaled when it
##     fits, else fit-to-window), with window input forwarded into the SubViewport.
##
## Put your world under `world_viewport` (or set `world_scene`), including a DmgDither inside it so
## the buffer is dithered before it is presented. On console builds, read input from `console`.
## Generalised from slopfarm's shell.

## The LCD buffer size. Square by default, like a DMG-ish screen; the dither keys its dot grid to it.
@export var buffer_size := Vector2i(1080, 1080)
## Optional: a scene instantiated into the world viewport on ready. Otherwise add children yourself.
@export var world_scene: PackedScene

## The viewport your game renders into. Add your world here (camera, terrain, DmgDither, …).
var world_viewport: SubViewport
## The faceplate on console builds, else null. Read move_vector / take_look() / button signals from it.
var console: DmgConsole

var _bare: TextureRect
var _forward := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	world_viewport = SubViewport.new()
	world_viewport.size = buffer_size
	world_viewport.own_world_3d = true
	world_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	world_viewport.handle_input_locally = true
	add_child(world_viewport)

	if world_scene != null:
		world_viewport.add_child(world_scene.instantiate())

	var tex := world_viewport.get_texture()
	if DmgConsole.is_console():
		console = DmgConsole.new()
		console.set_lcd(tex)
		add_child(console)
	else:
		_build_bare(tex)
		_forward = true


func _build_bare(tex: Texture2D) -> void:
	_bare = TextureRect.new()
	_bare.texture = tex
	_bare.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_bare.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bare.stretch_mode = TextureRect.STRETCH_SCALE
	_bare.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bare)
	_fit_bare()
	get_viewport().size_changed.connect(_fit_bare)


func _fit_bare() -> void:
	if _bare == null:
		return
	var game := Vector2(buffer_size)
	var view := get_viewport().get_visible_rect().size
	var raw := minf(view.x / game.x, view.y / game.y)
	# Integer-upscale when the buffer fits, so NEAREST stays crisp; else fit the whole buffer in.
	var s: float = floor(raw) if raw >= 1.0 else raw
	var dim := game * s
	_bare.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bare.size = dim
	_bare.position = ((view - dim) * 0.5).round()


func _unhandled_input(event: InputEvent) -> void:
	# Desktop/web: hand mouse-motion and keys to the game inside the SubViewport.
	if _forward and world_viewport != null:
		world_viewport.push_input(event)
