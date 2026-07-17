extends Control
class_name TouchControls
## On-screen touch controls for phones: a left thumb-stick to move, a right-side drag area to
## look, and a cluster of action buttons (hit, interact, jump, drive, respawn) plus a sprint
## toggle. Drawn procedurally and driven entirely from raw screen-touch events, so it works the
## same whether the game is showing the first-person view or the truck.
##
## It exposes its state (move_vector, jump, sprint, accumulated look) for the player and truck to
## read, and fires a signal per action button. Multi-touch aware: the stick, the look drag and a
## button tap are tracked by their own finger index, so you can steer and look and jab a button
## at once. Only shown on touch devices; on desktop nothing here is created.

signal hit_pressed
signal interact_pressed
signal truck_pressed
signal respawn_pressed

## -1..1 on each axis: x = strafe (right positive), y = forward (up/forward positive).
var move_vector := Vector2.ZERO
var jump_held := false
var sprint := false

var _look_accum := Vector2.ZERO

var _font: Font
const FONT_SIZE := 18

## Stick.
var _stick_touch := -1
var _stick_center := Vector2.ZERO
var _stick_knob := Vector2.ZERO
const STICK_RADIUS := 60.0

## Look drag.
var _look_touch := -1
var _look_last := Vector2.ZERO

## Buttons: each {id, pos, r, label, toggle}. `id` is emitted / handled on press.
var _buttons: Array = []
## Touch index -> button id, for taps currently held on a button (so a drag off it does nothing).
var _btn_touches: Dictionary = {}


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Lay out against the viewport, which in "viewport" stretch mode is the 640x360 space that
	# screen-touch positions also arrive in — a Control directly under a CanvasLayer does not get
	# its own rect sized for us, so we read the viewport directly.
	get_viewport().size_changed.connect(_layout)
	_layout()


func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _layout() -> void:
	var vp := _viewport_size()
	size = vp
	var w := vp.x
	var h := vp.y
	_stick_center = Vector2(w * 0.16, h * 0.72)
	_stick_knob = _stick_center
	_buttons = [
		{"id": "hit", "pos": Vector2(w - 62, h - 62), "r": 42.0, "label": "HIT", "toggle": false},
		{"id": "interact", "pos": Vector2(w - 150, h - 92), "r": 38.0, "label": "USE", "toggle": false},
		{"id": "jump", "pos": Vector2(w - 128, h - 190), "r": 34.0, "label": "JMP", "toggle": false},
		{"id": "truck", "pos": Vector2(w - 60, h - 158), "r": 34.0, "label": "DRV", "toggle": false},
		{"id": "sprint", "pos": Vector2(w * 0.16, h * 0.34), "r": 26.0, "label": "RUN", "toggle": true},
		{"id": "respawn", "pos": Vector2(w - 34, 34), "r": 22.0, "label": "R", "toggle": false},
	]
	queue_redraw()


## Returns the look movement accumulated since the last call, in screen pixels, and clears it.
func take_look() -> Vector2:
	var d := _look_accum
	_look_accum = Vector2.ZERO
	return d


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_on_press(t.index, t.position)
		else:
			_on_release(t.index)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_on_drag(d.index, d.position)


func _on_press(index: int, pos: Vector2) -> void:
	# Buttons win first — small precise targets.
	for b in _buttons:
		if pos.distance_to(b["pos"]) <= b["r"]:
			_btn_touches[index] = b["id"]
			_press_button(b)
			queue_redraw()
			return
	# The thumb-stick claims the lower-left region if it is free.
	var vp := _viewport_size()
	if _stick_touch == -1 and pos.x < vp.x * 0.42 and pos.y > vp.y * 0.30:
		_stick_touch = index
		_update_stick(pos)
		return
	# Anything else is a look drag.
	if _look_touch == -1:
		_look_touch = index
		_look_last = pos


func _on_drag(index: int, pos: Vector2) -> void:
	if index == _stick_touch:
		_update_stick(pos)
	elif index == _look_touch:
		_look_accum += pos - _look_last
		_look_last = pos
	# Drags that began on a button do nothing (buttons are taps).


func _on_release(index: int) -> void:
	if index == _stick_touch:
		_stick_touch = -1
		move_vector = Vector2.ZERO
		_stick_knob = _stick_center
		queue_redraw()
	elif index == _look_touch:
		_look_touch = -1
	elif _btn_touches.has(index):
		var id: String = _btn_touches[index]
		_btn_touches.erase(index)
		# Held buttons release here.
		if id == "jump":
			jump_held = false
		queue_redraw()


func _press_button(b: Dictionary) -> void:
	match String(b["id"]):
		"hit": hit_pressed.emit()
		"interact": interact_pressed.emit()
		"truck": truck_pressed.emit()
		"respawn": respawn_pressed.emit()
		"jump": jump_held = true
		"sprint": sprint = not sprint


func _update_stick(pos: Vector2) -> void:
	var off := pos - _stick_center
	if off.length() > STICK_RADIUS:
		off = off.normalized() * STICK_RADIUS
	_stick_knob = _stick_center + off
	# y is inverted: dragging up (screen -y) means forward (+y).
	move_vector = Vector2(off.x / STICK_RADIUS, -off.y / STICK_RADIUS)
	queue_redraw()


func _draw() -> void:
	# Thumb-stick: a base ring and the knob.
	draw_circle(_stick_center, STICK_RADIUS, Color(1, 1, 1, 0.08))
	draw_arc(_stick_center, STICK_RADIUS, 0, TAU, 40, Color(1, 1, 1, 0.35), 2.0)
	draw_circle(_stick_knob, 26.0, Color(1, 1, 1, 0.22))
	draw_arc(_stick_knob, 26.0, 0, TAU, 24, Color(1, 1, 1, 0.5), 2.0)
	# Buttons.
	for b in _buttons:
		var lit := bool(b["toggle"]) and _button_on(b["id"])
		var fill := Color(0.9, 0.7, 0.2, 0.30) if lit else Color(1, 1, 1, 0.12)
		draw_circle(b["pos"], b["r"], fill)
		draw_arc(b["pos"], b["r"], 0, TAU, 32, Color(1, 1, 1, 0.45), 2.0)
		if _font != null:
			var text := String(b["label"])
			var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE).x
			draw_string(_font, b["pos"] + Vector2(-tw * 0.5, FONT_SIZE * 0.35), text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(1, 1, 1, 0.85))


func _button_on(id: String) -> bool:
	if id == "sprint":
		return sprint
	return false
