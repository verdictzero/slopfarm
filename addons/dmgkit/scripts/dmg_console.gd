extends Control
class_name DmgConsole
## An on-screen Game Boy handheld faceplate + touch input, drawn PROCEDURALLY (no bundled art): a
## cream case with a bezel-framed LCD window showing your world texture, an analog D-pad on the left
## wing, and configurable face keys on the right. Generalised from slopfarm's touch console.
##
## "Swappable art" here means the look is data, not baked PNGs:
##   - every colour is an exported field (case/bezel/ink/accent) — restyle the whole shell by setting them;
##   - `buttons` is a config array (id, label, caption, position as size-fractions, radius, colour, …);
##   - set `faceplate` to a Texture2D to paint a custom shell behind the procedural controls;
##   - `brand_text` / `brand_sub` set the wordmark.
##
## Input (multi-touch aware): drag the D-pad to move, drag inside the LCD to look, tap the keys.
## Read `move_vector`, call `take_look()`, connect `button_pressed(id)` / `button_released(id)`, and
## check `is_held(id)` / `is_toggled(id)`.

## True on a real handheld export (or with DMGKIT_TOUCH set). Web is handled by the HTML shell, so it
## is excluded here. Deliberately NOT keyed on a touchscreen being present (desktop 2-in-1s).
static func is_console() -> bool:
	var web := OS.has_feature("web") or OS.has_environment("DMGKIT_GBSHELL")
	return not web and (OS.has_feature("mobile") or OS.has_environment("DMGKIT_TOUCH"))

signal button_pressed(id: String)
signal button_released(id: String)

## -1..1 per axis: x = strafe (right +), y = forward (up/forward +).
var move_vector := Vector2.ZERO

# --- skin (all overridable) --------------------------------------------------
@export var case_color := Color(0.796, 0.776, 0.729)
@export var case_hi := Color(0.871, 0.851, 0.804)
@export var case_lo := Color(0.643, 0.624, 0.573)
@export var case_edge := Color(0.561, 0.545, 0.498)
@export var bezel_color := Color(0.275, 0.267, 0.247)
@export var bezel_hi := Color(0.361, 0.353, 0.325)
@export var ink := Color(0.169, 0.169, 0.157)
@export var ink_hi := Color(0.290, 0.290, 0.271)
@export var label_color := Color(0.431, 0.416, 0.373)
@export var brand_color := Color(0.176, 0.227, 0.525)
@export var accent := Color(0.541, 0.122, 0.239)          # face-key / power dot colour
@export var accent_hi := Color(0.690, 0.204, 0.329)
@export var brand_text := "POCKET"
@export var brand_sub := "DMG-1"
## Optional painted shell behind the procedural controls (stretched to fill).
@export var faceplate: Texture2D

## Face keys. Positions are FRACTIONS of the full size so they scale to any screen. Each:
## {id, label, sub, fx, fy, r, big, toggle, pill}. Leave null to use the classic A/B/START/SELECT set.
var buttons: Array = []

const STICK_RADIUS := 46.0
const DPAD_ARM := 30.0

var _font: Font
var _lcd: TextureRect
var _lcd_texture: Texture2D
var _screen_rect := Rect2()
var _left_wing := 0.0
var _right_wing := 0.0
var _top_bar := 0.0
var _bottom_bar := 0.0
var _resolved: Array = []       # buttons with absolute positions filled in

var _stick_touch := -1
var _stick_center := Vector2.ZERO
var _stick_knob := Vector2.ZERO
var _look_touch := -1
var _look_last := Vector2.ZERO
var _look_accum := Vector2.ZERO
var _btn_touches: Dictionary = {}
var _held: Dictionary = {}
var _toggles: Dictionary = {}


## Point the LCD window at the world. Pass a SubViewport's get_texture().
func set_lcd(texture: Texture2D) -> void:
	_lcd_texture = texture
	if _lcd != null:
		_lcd.texture = texture


func take_look() -> Vector2:
	var d := _look_accum
	_look_accum = Vector2.ZERO
	return d


func is_held(id: String) -> bool:
	return _held.get(id, false)


func is_toggled(id: String) -> bool:
	return _toggles.get(id, false)


func _default_buttons() -> Array:
	return [
		{"id": "a", "label": "A", "sub": "", "fx": 0.93, "fy": 0.52, "r": 27.0, "big": true},
		{"id": "b", "label": "B", "sub": "", "fx": 0.855, "fy": 0.40, "r": 23.0, "big": true},
		{"id": "start", "label": "START", "sub": "", "fx": 0.545, "fy": 0.955, "r": 15.0, "pill": true},
		{"id": "select", "label": "SELECT", "sub": "", "fx": 0.44, "fy": 0.955, "r": 15.0, "pill": true},
	]


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if buttons.is_empty():
		buttons = _default_buttons()

	_lcd = TextureRect.new()
	_lcd.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_lcd.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_lcd.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_lcd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _lcd_texture != null:
		_lcd.texture = _lcd_texture
	add_child(_lcd)

	get_viewport().size_changed.connect(_layout)
	_layout()


func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _layout() -> void:
	var vp := _viewport_size()
	size = vp
	var w := vp.x
	var h := vp.y

	_left_wing = roundf(w * 0.185)
	_right_wing = roundf(w * 0.185)
	_top_bar = roundf(h * 0.05)
	_bottom_bar = roundf(h * 0.09)
	_screen_rect = Rect2(_left_wing, _top_bar, w - _left_wing - _right_wing, h - _top_bar - _bottom_bar)

	if _lcd != null:
		_lcd.position = _screen_rect.position
		_lcd.size = _screen_rect.size

	_stick_center = Vector2(_left_wing * 0.5, h * 0.5)
	_stick_knob = _stick_center

	_resolved = []
	for b in buttons:
		var e: Dictionary = (b as Dictionary).duplicate()
		e["pos"] = Vector2(float(b["fx"]) * w, float(b["fy"]) * h)
		_resolved.append(e)
	queue_redraw()


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
	for b in _resolved:
		if pos.distance_to(b["pos"]) <= float(b["r"]) + 6.0:
			var id := String(b["id"])
			_btn_touches[index] = id
			_held[id] = true
			if bool(b.get("toggle", false)):
				_toggles[id] = not _toggles.get(id, false)
			button_pressed.emit(id)
			queue_redraw()
			return
	if _stick_touch == -1 and pos.x < _left_wing and pos.y > _top_bar:
		_stick_touch = index
		_update_stick(pos)
		return
	if _look_touch == -1 and _screen_rect.has_point(pos):
		_look_touch = index
		_look_last = pos


func _on_drag(index: int, pos: Vector2) -> void:
	if index == _stick_touch:
		_update_stick(pos)
	elif index == _look_touch:
		_look_accum += pos - _look_last
		_look_last = pos


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
		_held[id] = false
		button_released.emit(id)
		queue_redraw()


func _update_stick(pos: Vector2) -> void:
	var off := pos - _stick_center
	if off.length() > STICK_RADIUS:
		off = off.normalized() * STICK_RADIUS
	_stick_knob = _stick_center + off
	move_vector = Vector2(off.x / STICK_RADIUS, -off.y / STICK_RADIUS)
	queue_redraw()


# ---- drawing ----------------------------------------------------------------

func _draw() -> void:
	var w := size.x
	var h := size.y
	if faceplate != null:
		draw_texture_rect(faceplate, Rect2(0, 0, w, h), false)
	else:
		# Cream case: the four bars around the LCD window.
		draw_rect(Rect2(0, 0, _left_wing, h), case_color)
		draw_rect(Rect2(w - _right_wing, 0, _right_wing, h), case_color)
		draw_rect(Rect2(0, 0, w, _top_bar), case_color)
		draw_rect(Rect2(0, h - _bottom_bar, w, _bottom_bar), case_color)
		draw_line(Vector2(0, 1), Vector2(w, 1), case_hi, 2.0)
		draw_line(Vector2(0, h - _bottom_bar + 1), Vector2(w, h - _bottom_bar + 1), case_hi, 1.0)
		draw_line(Vector2(0, h - 1), Vector2(w, h - 1), case_lo, 2.0)
		draw_line(Vector2(_left_wing - 1, _top_bar), Vector2(_left_wing - 1, h - _bottom_bar), case_edge, 1.0)
		draw_line(Vector2(w - _right_wing + 1, _top_bar), Vector2(w - _right_wing + 1, h - _bottom_bar), case_edge, 1.0)

	# Bezel around the LCD window.
	var frame := _screen_rect.grow(4.0)
	draw_rect(frame, bezel_color, false, 8.0)
	draw_line(frame.position + Vector2(0, -3), frame.position + Vector2(frame.size.x, -3), bezel_hi, 1.0)

	_draw_branding(w, h)
	_draw_dpad()
	for b in _resolved:
		_draw_key(b)


func _draw_branding(w: float, h: float) -> void:
	if _font == null or faceplate != null:
		return
	var fs := int(clampf(_top_bar * 0.62, 8.0, 13.0))
	draw_string(_font, Vector2(6, _top_bar * 0.5 + fs * 0.35), brand_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, label_color)
	var mark_x := 6.0 + _font.get_string_size(brand_text + " ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(mark_x, _top_bar * 0.5 + fs * 0.35), brand_sub,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, brand_color)
	draw_circle(Vector2(w - 14, _top_bar * 0.5), 3.0, accent)


func _draw_dpad() -> void:
	var c := _stick_center
	var arm := DPAD_ARM
	var thick := arm * 0.72
	draw_rect(Rect2(c.x - arm, c.y - thick * 0.5, arm * 2.0, thick), ink)
	draw_rect(Rect2(c.x - thick * 0.5, c.y - arm, thick, arm * 2.0), ink)
	draw_line(Vector2(c.x - arm, c.y - thick * 0.5), Vector2(c.x + arm, c.y - thick * 0.5), ink_hi, 1.0)
	draw_line(Vector2(c.x - thick * 0.5, c.y - arm), Vector2(c.x - thick * 0.5, c.y + arm), ink_hi, 1.0)
	draw_circle(c, thick * 0.34, ink_hi)
	draw_circle(_stick_knob, 9.0, case_hi)
	draw_arc(_stick_knob, 9.0, 0, TAU, 20, case_lo, 1.5)


func _draw_key(b: Dictionary) -> void:
	var pos: Vector2 = b["pos"]
	var r: float = b["r"]
	var col := accent
	if bool(b.get("toggle", false)) and _toggles.get(String(b["id"]), false):
		col = accent_hi
	elif bool(b.get("pill", false)):
		col = ink
	if bool(b.get("pill", false)):
		var half := Vector2(r * 1.6, r * 0.55)
		draw_rect(Rect2(pos - half, half * 2.0), col)
		draw_circle(pos - Vector2(half.x, 0), half.y, col)
		draw_circle(pos + Vector2(half.x, 0), half.y, col)
	else:
		draw_circle(pos, r, col)
		draw_arc(pos, r - 1.0, PI * 1.05, TAU * 0.98, 24, accent_hi, 2.0)
		draw_arc(pos, r, 0, TAU, 28, case_lo, 1.0)
	if _font == null:
		return
	var label := String(b["label"])
	var fs := maxi(int(r * (0.8 if bool(b.get("big", false)) else 0.62)), 9)
	var tw := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, pos + Vector2(-tw * 0.5, fs * 0.36), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.96, 0.94, 0.92))
	var sub := String(b.get("sub", ""))
	if sub != "":
		var sw := _font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		draw_string(_font, pos + Vector2(-sw * 0.5, r + 9 + 1.0), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, label_color)
