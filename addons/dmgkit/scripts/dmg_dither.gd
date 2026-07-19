extends CanvasLayer
class_name DmgDither
## dmgkit's signature green-LCD post-process, as a drop-in node.
##
## Add a DmgDither anywhere in a Viewport (the root viewport, or a SubViewport you render the world
## into) and everything drawn BELOW its layer is re-rendered in the 64 Game Boy greens baked into
## lut_512.png, diced into a grid of "LCD dots" and ordered-dithered between the palette steps. UI or
## HUD you want to stay crisp (undithered) simply lives on a CanvasLayer with a HIGHER layer number.
##
## It builds its own BackBufferCopy + full-rect ColorRect running dmg_dither.gdshader, so there is
## nothing to wire in the scene — just drop it in (or call DmgDither.create()).

const SHADER := "res://addons/dmgkit/shaders/dmg_dither.gdshader"
const LUT := "res://addons/dmgkit/shaders/lut_512.png"

## Native buffer pixels per LCD dot. At a 1080-tall buffer, 3 gives a 360-dot grid. 1 is a
## full-resolution per-pixel dither.
@export var grid_size: float = 3.0:
	set(v):
		grid_size = v
		if _mat != null:
			_mat.set_shader_parameter(&"grid_size", v)
## How hard the ordered dither pushes between palette steps (0 = hard-snap, no dither).
@export var dither_strength: float = 0.17:
	set(v):
		dither_strength = v
		if _mat != null:
			_mat.set_shader_parameter(&"dither_strength", v)
## CanvasLayer ordering. Everything below this layer is dithered; put crisp UI above it.
@export var post_layer: int = 100:
	set(v):
		post_layer = v
		layer = v

var _mat: ShaderMaterial


## Convenience constructor: DmgDither.create(100, 3.0, 0.17).
static func create(at_layer: int = 100, dots: float = 3.0, strength: float = 0.17) -> DmgDither:
	var d := DmgDither.new()
	d.post_layer = at_layer
	d.grid_size = dots
	d.dither_strength = strength
	return d


func _ready() -> void:
	layer = post_layer

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER)
	_mat.set_shader_parameter(&"lut_tex", load(LUT))
	_mat.set_shader_parameter(&"grid_size", grid_size)
	_mat.set_shader_parameter(&"dither_strength", dither_strength)

	# The back buffer copy has to sit BEFORE the ColorRect in tree order so the ColorRect's
	# hint_screen_texture sees the freshly-copied frame.
	var copy := BackBufferCopy.new()
	copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(copy)

	var rect := ColorRect.new()
	rect.material = _mat
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
