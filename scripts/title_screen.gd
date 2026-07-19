extends CanvasLayer
class_name TitleScreen
## The boot title, drawn INSIDE the Game Boy screen: its own layer in the world SubViewport, above
## the HUD (112) and crosshair (110), so it fills the LCD and the console/bezel shows around it.
## Pure visual — the player owns it and dismisses it on the first action, freezing play until then.
## Blinking PRESS START, in the DMG pixel font.

const IMAGE := "res://sprites/title_screen.png"
const INK := Color(0.06, 0.22, 0.06)   # dark green, matching the art's outlines

var _hint: Label


func _ready() -> void:
	layer = 130

	var art := TextureRect.new()
	art.texture = load(IMAGE)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# The LCD is square and so is the art, so COVER fills it edge to edge with no crop.
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)

	_hint = Label.new()
	_hint.text = "PRESS START"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_top = -120.0
	_hint.offset_bottom = -66.0
	_hint.modulate = INK
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := load("res://fonts/PressStart2P-Regular.ttf")
	if f != null:
		_hint.add_theme_font_override("font", f)
		_hint.add_theme_font_size_override("font_size", 28)
	add_child(_hint)

	var blink := Timer.new()
	blink.wait_time = 0.5
	blink.autostart = true
	add_child(blink)
	blink.timeout.connect(func() -> void: _hint.visible = not _hint.visible)


func dismiss() -> void:
	queue_free()
