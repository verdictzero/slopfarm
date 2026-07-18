extends Control
class_name TouchControls
## The native mobile build's on-screen controls, drawn as a Game Boy handheld faceplate: a cream
## console case with a bezel-framed LCD window (the game shows through the window), a dark D-pad on
## the left wing, and labelled oxblood/plum face keys on the right — the landscape sibling of the
## web build's Game Boy shell (web/gb_shell.html), sharing its palette.
##
## Only the native mobile export uses this: the web build drives the game from the HTML shell
## through GBShellInput, and desktop shows no controls. So it is free to own the whole screen and
## paint the console body without a platform check.
##
## Input is unchanged from a plain thumb-pad: the D-pad is an analog nub (drag it to move), the
## LCD window is the look-drag area, and each face key is a tap. Multi-touch aware — the pad, the
## look drag and a key tap are tracked by their own finger index, so you can steer, look and jab a
## key at once. It exposes move_vector / jump_held / sprint / take_look() and fires a signal per
## action key, exactly as before, so nothing downstream knows the skin changed.

## Which input path this build uses. Web is checked FIRST so a phone browser (which is BOTH web and
## touch) drives the game from the HTML shell and never also raises the in-engine console.
static func is_web() -> bool:
	return OS.has_feature("web") or OS.has_environment("SLOPFARM_GBSHELL")
static func is_console() -> bool:
	# Deliberately NOT keyed on DisplayServer.is_touchscreen_available(): that fires on desktop
	# touchscreen laptops / 2-in-1s, which would hand a mouse+keyboard user the portrait phone
	# faceplate. Only a real handheld export (or the explicit preview flag) gets the console.
	return not is_web() and (OS.has_feature("mobile") or OS.has_environment("SLOPFARM_TOUCH"))

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

## Console palette, lifted from web/gb_shell.html so the two builds read as the same handheld.
const CASE := Color(0.796, 0.776, 0.729)
const CASE_HI := Color(0.871, 0.851, 0.804)
const CASE_LO := Color(0.643, 0.624, 0.573)
const CASE_EDGE := Color(0.561, 0.545, 0.498)
const BEZEL := Color(0.275, 0.267, 0.247)
const BEZEL_HI := Color(0.361, 0.353, 0.325)
const INK := Color(0.169, 0.169, 0.157)
const INK_HI := Color(0.290, 0.290, 0.271)
const OXBLOOD := Color(0.541, 0.122, 0.239)
const OXBLOOD_HI := Color(0.690, 0.204, 0.329)
const PLUM := Color(0.208, 0.196, 0.290)
const PLUM_HI := Color(0.318, 0.298, 0.431)
const LABEL := Color(0.431, 0.416, 0.373)
const BRAND := Color(0.176, 0.227, 0.525)

## Console geometry, filled by _layout() in viewport (640x360) space.
var _screen_rect := Rect2()
var _left_wing := 0.0
var _right_wing := 0.0
var _top_bar := 0.0
var _bottom_bar := 0.0

## D-pad (the analog move nub, skinned as a Game Boy cross).
var _stick_touch := -1
var _stick_center := Vector2.ZERO
var _stick_knob := Vector2.ZERO
const STICK_RADIUS := 46.0
const DPAD_ARM := 30.0

## Look drag.
var _look_touch := -1
var _look_last := Vector2.ZERO

## Face keys: each {id, pos, r, label, sub, color, hi, big, toggle}.
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

	# Cream wings hold the controls; the game shows through the LCD window between them.
	_left_wing = roundf(w * 0.185)
	_right_wing = roundf(w * 0.185)
	_top_bar = roundf(h * 0.05)
	_bottom_bar = roundf(h * 0.09)
	_screen_rect = Rect2(_left_wing, _top_bar,
			w - _left_wing - _right_wing, h - _top_bar - _bottom_bar)

	# D-pad on the left wing.
	_stick_center = Vector2(_left_wing * 0.5, h * 0.5)
	_stick_knob = _stick_center

	# Face keys on the right wing: an A/B diagonal of oxblood primaries, two plum keys above, a
	# RUN toggle low on the left wing, and START (respawn) as a pill on the bottom bar.
	var rc := w - _right_wing * 0.5   # right-wing centre column
	_buttons = [
		{"id": "hit", "pos": Vector2(rc + 20, h * 0.52), "r": 27.0,
			"label": "A", "sub": "HIT", "color": OXBLOOD, "hi": OXBLOOD_HI, "big": true, "toggle": false},
		{"id": "interact", "pos": Vector2(rc - 26, h * 0.40), "r": 23.0,
			"label": "B", "sub": "USE", "color": OXBLOOD, "hi": OXBLOOD_HI, "big": true, "toggle": false},
		{"id": "jump", "pos": Vector2(rc + 22, h * 0.26), "r": 18.0,
			"label": "X", "sub": "JUMP", "color": PLUM, "hi": PLUM_HI, "big": false, "toggle": false},
		{"id": "truck", "pos": Vector2(rc - 24, h * 0.20), "r": 18.0,
			"label": "Y", "sub": "DRIVE", "color": PLUM, "hi": PLUM_HI, "big": false, "toggle": false},
		{"id": "sprint", "pos": Vector2(_left_wing * 0.5, h * 0.80), "r": 20.0,
			"label": "RUN", "sub": "", "color": INK_HI, "hi": CASE_LO, "big": false, "toggle": true},
		{"id": "respawn", "pos": Vector2(w * 0.5 + 46, h - _bottom_bar * 0.5), "r": 15.0,
			"label": "START", "sub": "", "color": INK, "hi": INK_HI, "big": false, "toggle": false, "pill": true},
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
	# Keys win first — small precise targets.
	for b in _buttons:
		if pos.distance_to(b["pos"]) <= b["r"] + 6.0:
			_btn_touches[index] = b["id"]
			_press_button(b)
			queue_redraw()
			return
	# The D-pad claims the left wing if it is free.
	if _stick_touch == -1 and pos.x < _left_wing and pos.y > _top_bar:
		_stick_touch = index
		_update_stick(pos)
		return
	# A drag inside the LCD window looks around. Touches on the cream case do nothing.
	if _look_touch == -1 and _screen_rect.has_point(pos):
		_look_touch = index
		_look_last = pos


func _on_drag(index: int, pos: Vector2) -> void:
	if index == _stick_touch:
		_update_stick(pos)
	elif index == _look_touch:
		_look_accum += pos - _look_last
		_look_last = pos
	# Drags that began on a key do nothing (keys are taps).


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
		# Held keys release here.
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


# ---- drawing ----------------------------------------------------------------

func _draw() -> void:
	var w := size.x
	var h := size.y
	# Cream case: the four bars around the LCD window. Drawn opaque so only the window shows game.
	draw_rect(Rect2(0, 0, _left_wing, h), CASE)
	draw_rect(Rect2(w - _right_wing, 0, _right_wing, h), CASE)
	draw_rect(Rect2(0, 0, w, _top_bar), CASE)
	draw_rect(Rect2(0, h - _bottom_bar, w, _bottom_bar), CASE)
	# A soft bevel: light along the top of the case, shade along the bottom.
	draw_line(Vector2(0, 1), Vector2(w, 1), CASE_HI, 2.0)
	draw_line(Vector2(0, h - _bottom_bar + 1), Vector2(w, h - _bottom_bar + 1), CASE_HI, 1.0)
	draw_line(Vector2(0, h - 1), Vector2(w, h - 1), CASE_LO, 2.0)
	draw_line(Vector2(_left_wing - 1, _top_bar), Vector2(_left_wing - 1, h - _bottom_bar), CASE_EDGE, 1.0)
	draw_line(Vector2(w - _right_wing + 1, _top_bar), Vector2(w - _right_wing + 1, h - _bottom_bar), CASE_EDGE, 1.0)

	_draw_bezel()
	_draw_branding(w, h)
	_draw_dpad()
	for b in _buttons:
		_draw_key(b)


## A dark recessed frame hugging the LCD window, so the game reads as a screen behind glass.
## Drawn as an outline only — the window itself is never painted, so the game shows through.
func _draw_bezel() -> void:
	var frame := _screen_rect.grow(4.0)
	draw_rect(frame, BEZEL, false, 8.0)
	# Top catch-light along the upper lip of the bezel.
	draw_line(frame.position + Vector2(0, -3), frame.position + Vector2(frame.size.x, -3), BEZEL_HI, 1.0)


func _draw_branding(w: float, h: float) -> void:
	if _font == null:
		return
	# Wordmark on the top bar, and a "power" dot, echoing the web shell's POCKET GB-1 header.
	var fs := int(clampf(_top_bar * 0.62, 8.0, 13.0))
	draw_string(_font, Vector2(6, _top_bar * 0.5 + fs * 0.35), "POCKET",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL)
	var mark_x := 6.0 + _font.get_string_size("POCKET ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(mark_x, _top_bar * 0.5 + fs * 0.35), "GB-1",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, BRAND)
	draw_circle(Vector2(w - 14, _top_bar * 0.5), 3.0, OXBLOOD)
	draw_string(_font, Vector2(w - 60, _top_bar * 0.5 + fs * 0.35), "POWER",
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(fs * 0.7), LABEL)
	# "DOT MATRIX" tag under the left of the bezel, like the real front panel (kept clear of START).
	draw_string(_font, Vector2(_screen_rect.position.x + 2, _screen_rect.end.y + 6 + 8),
			"DOT MATRIX", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, LABEL)


## The D-pad: a dark cross with the analog nub riding on top so you can see the input.
func _draw_dpad() -> void:
	var c := _stick_center
	var arm := DPAD_ARM
	var thick := arm * 0.72
	# Cross body.
	draw_rect(Rect2(c.x - arm, c.y - thick * 0.5, arm * 2.0, thick), INK)
	draw_rect(Rect2(c.x - thick * 0.5, c.y - arm, thick, arm * 2.0), INK)
	# Bevels.
	draw_line(Vector2(c.x - arm, c.y - thick * 0.5), Vector2(c.x + arm, c.y - thick * 0.5), INK_HI, 1.0)
	draw_line(Vector2(c.x - thick * 0.5, c.y - arm), Vector2(c.x - thick * 0.5, c.y + arm), INK_HI, 1.0)
	draw_circle(c, thick * 0.34, INK_HI)
	# The nub: shows the current analog offset.
	draw_circle(_stick_knob, 9.0, CASE_HI)
	draw_arc(_stick_knob, 9.0, 0, TAU, 20, CASE_LO, 1.5)


## One face key: a coloured disc (or pill) with a top catch-light, a bold letter, and a small
## caption under it. Toggle keys glow when on.
func _draw_key(b: Dictionary) -> void:
	var pos: Vector2 = b["pos"]
	var r: float = b["r"]
	var col: Color = b["color"]
	if bool(b["toggle"]) and _button_on(String(b["id"])):
		col = OXBLOOD
	if b.get("pill", false):
		# START-style lozenge.
		var half := Vector2(r * 1.6, r * 0.55)
		draw_rect(Rect2(pos - half, half * 2.0), col)
		draw_circle(pos - Vector2(half.x, 0), half.y, col)
		draw_circle(pos + Vector2(half.x, 0), half.y, col)
	else:
		draw_circle(pos, r, col)
		draw_arc(pos, r - 1.0, PI * 1.05, TAU * 0.98, 24, b["hi"], 2.0)   # top catch-light
		draw_arc(pos, r, 0, TAU, 28, CASE_LO, 1.0)
	if _font == null:
		return
	var label := String(b["label"])
	var fs := int(r * (0.8 if bool(b["big"]) else 0.62))
	fs = maxi(fs, 9)
	var tw := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, pos + Vector2(-tw * 0.5, fs * 0.36), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.96, 0.94, 0.92))
	var sub := String(b["sub"])
	if sub != "":
		var sfs := 9
		var sw := _font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x
		draw_string(_font, pos + Vector2(-sw * 0.5, r + sfs + 1.0), sub,
				HORIZONTAL_ALIGNMENT_LEFT, -1, sfs, LABEL)


func _button_on(id: String) -> bool:
	if id == "sprint":
		return sprint
	return false
