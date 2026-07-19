extends Control
class_name DmgConsole
## An on-screen portrait Game Boy console faceplate + touch input, composited from a sprite skin: a
## cream case with a bezel-framed square LCD (your world seats in the glass), a directional D-pad,
## an A/B/C/X/Y/Z face-key cluster, twin analog thumbsticks, and START/SELECT pills. Keys and the
## D-pad swap to their pressed art on touch and the stick balls ride their sockets. Ported from
## slopfarm's console.
##
## SWAPPABLE ART: everything is loaded from `skin_dir` (default the bundled kit). Point it at your
## own folder with the same filenames + a `layout.json` (shell size, the `screen` bezel placement,
## and `glass_in_shell`) to reskin the whole shell. If the skin is missing it falls back to showing
## the world full-rect, so the screen is never black.
##
## INPUT (all generic — nothing game-specific):
##   move_vector      : Vector2  D-pad + left stick folded together, -1..1 per axis (y+ = up/forward)
##   look() -> Vector2: right-stick look accumulated since the last call (px/s x dt), for camera look
##   dpad_vector      : Vector2  the raw D-pad alone as -1/0/1 per axis (also folded into move_vector)
##   button_pressed(id) / button_released(id) signals, is_held(id)  — ids: a b c x y z start select

## True on a real handheld export (or with DMGKIT_TOUCH set); web is handled by an HTML shell.
static func is_console() -> bool:
	var web := OS.has_feature("web") or OS.has_environment("DMGKIT_GBSHELL")
	return not web and (OS.has_feature("mobile") or OS.has_environment("DMGKIT_TOUCH"))

signal button_pressed(id: String)
signal button_released(id: String)

## Folder of the skin sprites + layout.json. Swap for your own art.
@export_dir var skin_dir: String = "res://addons/dmgkit/console"

var move_vector := Vector2.ZERO
var dpad_vector := Vector2.ZERO

const DEAD := 0.16          # D-pad dead zone
const STICK_MAX := 0.34     # fraction of the socket the thumb can travel
## Right-stick look speed at full deflection, in shell px/s — integrated every frame so a held
## stick keeps turning the camera at a steady, frame-rate-independent rate (drained by look()).
const LOOK_UNITS_PER_SEC := 430.0

# Control layout in shell (448x900) units — matches slopfarm's pad.
const BTN_W := 80.0
const BTN_H := 83.0
const DPAD_W := 184.0
const STICK_W := 144.0
const BALL_W := 78.0
const BALL_H := 86.0
const BALL_DY := 4.0
const PILL_W := 108.0
const PILL_H := 49.4
# id, centre x, centre y. Saturn-pad arc: A/B on the right (accent), C/Z then X/Y stepping left.
const BUTTONS := [
	["x", 260.0, 560.0], ["c", 334.0, 540.0], ["a", 408.0, 520.0],
	["y", 260.0, 638.0], ["z", 334.0, 618.0], ["b", 408.0, 598.0],
]
const DPAD_C := Vector2(100.0, 566.0)
const STICK_L := Vector2(104.0, 752.0)
const STICK_R := Vector2(330.0, 752.0)
const PILL_SEL := Vector2(162.0, 856.0)
const PILL_START := Vector2(286.0, 856.0)

var _lcd_texture: Texture2D
var _shell_w := 448.0
var _shell_h := 900.0
var _case: Control
var _lcd: TextureRect

var _btns := {}             # id -> {node, idle, pressed}
var _dpad_node: TextureRect
var _dpad_tex := {}
var _pills := {}            # "start"/"select" -> {node, idle, pressed}
var _sticks := {}           # "left"/"right" -> {pivot, ball, idle, pressed}
var _held := {}
var _look_accum := Vector2.ZERO
var _lstick := Vector2.ZERO   # left-stick deflection, polled into move_vector each frame
var _rstick := Vector2.ZERO   # right-stick deflection, integrated into look each frame

var _dp_touch := -1
var _l_touch := -1
var _r_touch := -1
var _btn_touches := {}


## Point the LCD window at your world (a SubViewport's get_texture()).
func set_lcd(texture: Texture2D) -> void:
	_lcd_texture = texture
	if _lcd != null:
		_lcd.texture = texture


## Right-stick look delta accumulated since the last call, in stick units; cleared.
func look() -> Vector2:
	var d := _look_accum
	_look_accum = Vector2.ZERO
	return d


func is_held(id: String) -> bool:
	return _held.get(id, false)


func _process(delta: float) -> void:
	# D-pad and left stick fold into move_vector (forward = +y), clamped so a half-pushed stick still
	# walks at half pace. The right stick integrates into look at a steady rate, so holding it
	# deflected keeps turning the camera even after the finger stops sliding.
	var mv := Vector2(_lstick.x + dpad_vector.x, -_lstick.y + dpad_vector.y)
	if mv.length() > 1.0:
		mv = mv.normalized()
	move_vector = mv
	_look_accum += _rstick * LOOK_UNITS_PER_SEC * delta


func _asset(name: String) -> String:
	return skin_dir.path_join(name)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func _load_layout() -> Dictionary:
	var path := _asset("layout.json")
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}


func _build() -> void:
	var layout := _load_layout()
	if layout.is_empty():
		# No skin — present the world full-rect so the screen is never black.
		var fb := TextureRect.new()
		fb.texture = _lcd_texture
		fb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		fb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		fb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(fb)
		_lcd = fb          # so a later set_lcd() still updates the screen on the no-skin path
		return
	_shell_w = float(layout["shell"]["w"])
	_shell_h = float(layout["shell"]["h"])

	var room := ColorRect.new()
	room.color = Color(0.09, 0.09, 0.11)
	room.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	room.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(room)

	var fit := AspectRatioContainer.new()
	fit.ratio = _shell_w / _shell_h
	fit.stretch_mode = AspectRatioContainer.STRETCH_FIT
	fit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fit)

	_case = Control.new()
	_case.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fit.add_child(_case)

	_rect(load(_asset("case.png")), -4, -4, _shell_w + 8, _shell_h + 8)
	for pl in layout["placements"]:
		if String(pl["id"]) == "screen":
			_rect(load(_asset("bezel.png")), pl["x"], pl["y"], pl["w"], pl["h"])
			break
	var g: Dictionary = layout["glass_in_shell"]
	_lcd = _rect(_lcd_texture, g["x"], g["y"], g["w"], g["h"], true, true)
	_lcd.name = "Lcd"

	_build_brand(g)
	_build_dpad()
	_build_buttons()
	_build_sticks()
	_build_pills()


# ---- placement helpers ------------------------------------------------------
func _rect(tex: Texture2D, x: float, y: float, w: float, h: float,
		nearest := false, aspect := false) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if aspect else TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if nearest else CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_case.add_child(tr)
	tr.anchor_left = x / _shell_w
	tr.anchor_top = y / _shell_h
	tr.anchor_right = (x + w) / _shell_w
	tr.anchor_bottom = (y + h) / _shell_h
	tr.offset_left = 0.0; tr.offset_top = 0.0; tr.offset_right = 0.0; tr.offset_bottom = 0.0
	return tr


func _at(tex: Texture2D, cx: float, cy: float, w: float, h: float) -> TextureRect:
	return _rect(tex, cx - w * 0.5, cy - h * 0.5, w, h)


func _build_brand(g: Dictionary) -> void:
	var gl := float(g["x"])
	var gr := float(g["x"]) + float(g["w"])
	var y := 36.0
	var mp := _asset("brand_mark.png")
	if ResourceLoader.exists(mp):
		var m: Texture2D = load(mp)
		var mh := 15.0
		_rect(m, gl, y - mh * 0.5, mh * float(m.get_width()) / float(m.get_height()), mh)
	var pp := _asset("brand_power.png")
	if ResourceLoader.exists(pp):
		var pt: Texture2D = load(pp)
		var ph := 12.0
		_rect(pt, gr - ph * float(pt.get_width()) / float(pt.get_height()), y - ph * 0.5,
				ph * float(pt.get_width()) / float(pt.get_height()), ph)


func _build_dpad() -> void:
	for k in ["idle", "up", "down", "left", "right"]:
		_dpad_tex[k] = load(_asset("dpad_" + k + ".png"))
	_dpad_node = _at(_dpad_tex["idle"], DPAD_C.x, DPAD_C.y, DPAD_W, DPAD_W)


func _build_buttons() -> void:
	for e in BUTTONS:
		var id: String = e[0]
		var up := "btn_" + id.to_upper()
		var idle: Texture2D = load(_asset(up + "_idle.png"))
		var pressed: Texture2D = load(_asset(up + "_pressed.png"))
		var node := _at(idle, e[1], e[2], BTN_W, BTN_H)
		_btns[id] = {"node": node, "idle": idle, "pressed": pressed}


func _build_sticks() -> void:
	var pivot: Texture2D = load(_asset("stick_pivot.png"))
	var ball_idle: Texture2D = load(_asset("stick_ball.png"))
	var ball_pressed: Texture2D = load(_asset("stick_ball_pressed.png"))
	for side in ["left", "right"]:
		var c: Vector2 = STICK_L if side == "left" else STICK_R
		var pv := _at(pivot, c.x, c.y, STICK_W, STICK_W)
		var ball := _at(ball_idle, c.x, c.y + BALL_DY, BALL_W, BALL_H)
		_sticks[side] = {"pivot": pv, "ball": ball, "idle": ball_idle, "pressed": ball_pressed}


func _build_pills() -> void:
	var idle: Texture2D = load(_asset("pill_idle.png"))
	var pressed: Texture2D = load(_asset("pill_pressed.png"))
	for e in [["select", PILL_SEL], ["start", PILL_START]]:
		var node := _at(idle, e[1].x, e[1].y, PILL_W, PILL_H)
		_pills[e[0]] = {"node": node, "idle": idle, "pressed": pressed}


# ---- touch ------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_press(t.index, t.position)
		else:
			_release(t.index)
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _dp_touch:
			_update_dpad(d.position)
		elif d.index == _l_touch:
			_update_stick("left", d.position)
		elif d.index == _r_touch:
			_update_stick("right", d.position)


func _press(index: int, pos: Vector2) -> void:
	var best := ""
	var best_d := INF
	for id in _btns:
		var rect: Rect2 = _btns[id]["node"].get_global_rect()
		if rect.has_point(pos):
			var dd := pos.distance_squared_to(rect.get_center())
			if dd < best_d:
				best_d = dd
				best = id
	for id in _pills:
		if _pills[id]["node"].get_global_rect().has_point(pos):
			best = id
			break
	if best != "":
		_btn_touches[index] = best
		_button_down(best)
		return
	if _dp_touch == -1 and _dpad_node.get_global_rect().has_point(pos):
		_dp_touch = index
		_update_dpad(pos)
		return
	if _l_touch == -1 and _sticks["left"]["pivot"].get_global_rect().has_point(pos):
		_l_touch = index
		_update_stick("left", pos)
		return
	if _r_touch == -1 and _sticks["right"]["pivot"].get_global_rect().has_point(pos):
		_r_touch = index
		_update_stick("right", pos)


func _release(index: int) -> void:
	if index == _dp_touch:
		_dp_touch = -1
		dpad_vector = Vector2.ZERO
		_dpad_node.texture = _dpad_tex["idle"]
	elif index == _l_touch:
		_l_touch = -1
		_reset_stick("left")
	elif index == _r_touch:
		_r_touch = -1
		_reset_stick("right")
	elif _btn_touches.has(index):
		_button_up(_btn_touches[index])
		_btn_touches.erase(index)


func _button_down(id: String) -> void:
	_held[id] = true
	button_pressed.emit(id)
	if _btns.has(id):
		_btns[id]["node"].texture = _btns[id]["pressed"]
	elif _pills.has(id):
		_pills[id]["node"].texture = _pills[id]["pressed"]


func _button_up(id: String) -> void:
	_held[id] = false
	button_released.emit(id)
	if _btns.has(id):
		_btns[id]["node"].texture = _btns[id]["idle"]
	elif _pills.has(id):
		_pills[id]["node"].texture = _pills[id]["idle"]


func _update_dpad(pos: Vector2) -> void:
	var rect: Rect2 = _dpad_node.get_global_rect()
	var c := rect.get_center()
	var nx := (pos.x - c.x) / (rect.size.x * 0.5)
	var ny := (pos.y - c.y) / (rect.size.y * 0.5)
	dpad_vector = Vector2(
		(1.0 if nx > DEAD else 0.0) - (1.0 if nx < -DEAD else 0.0),
		(1.0 if ny < -DEAD else 0.0) - (1.0 if ny > DEAD else 0.0))   # y+ = up
	var t := "idle"
	if absf(ny) >= absf(nx):
		if ny < -DEAD: t = "up"
		elif ny > DEAD: t = "down"
	else:
		if nx < -DEAD: t = "left"
		elif nx > DEAD: t = "right"
	_dpad_node.texture = _dpad_tex[t]


func _update_stick(side: String, pos: Vector2) -> void:
	var s: Dictionary = _sticks[side]
	var rect: Rect2 = s["pivot"].get_global_rect()
	var c := rect.get_center()
	var max_r := rect.size.x * STICK_MAX
	var d := pos - c
	if d.length() > max_r:
		d = d.normalized() * max_r
	var ball: TextureRect = s["ball"]
	ball.offset_left = d.x; ball.offset_top = d.y; ball.offset_right = d.x; ball.offset_bottom = d.y
	ball.texture = s["pressed"]
	var v := d / max_r
	if side == "left":
		_lstick = v          # folded into move_vector in _process
	else:
		_rstick = v          # integrated into look in _process


func _reset_stick(side: String) -> void:
	var s: Dictionary = _sticks[side]
	var ball: TextureRect = s["ball"]
	ball.offset_left = 0.0; ball.offset_top = 0.0; ball.offset_right = 0.0; ball.offset_bottom = 0.0
	ball.texture = s["idle"]
	if side == "left":
		_lstick = Vector2.ZERO
	else:
		_rstick = Vector2.ZERO
