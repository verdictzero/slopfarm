extends Control
class_name TitleScreen
## Boot splash over the whole shell: the SlopFarm title art (already drawn in the DMG green ramp)
## with a blinking PRESS START, dismissed by the first tap / click / key / pad button. The tree is
## paused while it shows — the world sits frozen at spawn behind it — and this node keeps processing
## so it still catches that first input. GBShell adds it on boot (skipped when SLOPFARM_NOTITLE is
## set, so the screenshot rigs see the game directly).

const IMAGE := "res://sprites/title_screen.png"
const BG := Color(0.42, 0.55, 0.24)      # a mid DMG green, framing the square art in letterbox
const INK := Color(0.06, 0.22, 0.06)     # dark green, for PRESS START

var _hint: Label


func _ready() -> void:
	# Keep running while the rest of the tree is paused, so the first input still reaches us.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# The whole square title always shown (contained, never cropped), centred in the window.
	var art := TextureRect.new()
	art.texture = load(IMAGE)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
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
	_hint.offset_top = -70.0
	_hint.offset_bottom = -34.0
	_hint.modulate = INK
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := load("res://fonts/PressStart2P-Regular.ttf")
	if f != null:
		_hint.add_theme_font_override("font", f)
		_hint.add_theme_font_size_override("font_size", 16)
	add_child(_hint)

	# Slow blink for the prompt (steps, like a handheld).
	var blink := Timer.new()
	blink.wait_time = 0.5
	blink.autostart = true
	add_child(blink)
	blink.timeout.connect(func() -> void: _hint.visible = not _hint.visible)

	get_tree().paused = true


func _input(event: InputEvent) -> void:
	var go: bool = (event is InputEventKey and event.pressed and not (event as InputEventKey).echo) \
			or (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
			or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed) \
			or (event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed)
	if go:
		get_viewport().set_input_as_handled()
		_dismiss()


func _dismiss() -> void:
	if not is_inside_tree():
		return
	get_tree().paused = false
	queue_free()
