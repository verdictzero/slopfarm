extends Control
class_name GBConsole
## Builds the portrait Game Boy console from the vector-derived UI kit (sprites/gb_ui/, buttons and
## controls with idle/pressed states) and turns touches into calls on a ShellInput. The case and the
## square screen come from layout.json (case.png / bezel.png / the glass rect); the controls are laid
## out here, over the lower half of the case, with the game LCD seated in the screen. Every key and
## pill swaps to its pressed art on touch, the D-pad shows the held direction, and the stick ball
## rides its socket, so the pad feels alive.

const ASSET_DIR := "res://sprites/gb_ui/"
const DEAD := 0.16          # D-pad dead zone
const STICK_MAX := 0.34     # fraction of the socket the thumb can travel

# Control layout, in shell (448x900) units: centres and sizes tuned to sit clear of the square
# screen and of each other, with room for the captions beneath.
const BTN_W := 62.0
const BTN_H := 64.6         # button art is 96x100
const DPAD_W := 150.0
const STICK_W := 116.0      # pivot socket art is 140x140 (square)
const BALL_W := 63.0        # ball art is 76x84; rides ~centred in the socket
const BALL_H := 69.6
const BALL_DY := 3.3        # the ball's rest centre sits a touch below the socket centre
const PILL_W := 84.0
const PILL_H := 38.4        # pill art is 140x64
const CAP_W := 88.0
const CAP_H := 13.8         # caption art is 140x22

# id, centre x, centre y, caption word
const BUTTONS := [
	["btn_X", 262.0, 528.0, "jump"],
	["btn_C", 330.0, 528.0, "drive"],
	["btn_A", 398.0, 528.0, "hit"],
	["btn_Y", 262.0, 614.0, "run"],
	["btn_Z", 330.0, 614.0, "reset"],
	["btn_B", 398.0, 614.0, "use"],
]
const DPAD_C := Vector2(104.0, 571.0)
const STICK_L := Vector2(104.0, 752.0)
const STICK_R := Vector2(330.0, 752.0)
const PILL_SEL := Vector2(178.0, 840.0)
const PILL_START := Vector2(272.0, 840.0)

var _pad: ShellInput
var _shell_w := 448.0
var _shell_h := 900.0
var _case: Control

var _btns := {}             # id -> {node, idle, pressed}
var _dpad_node: TextureRect
var _dpad_tex := {}         # "idle".."right" -> Texture2D
var _pills := {}            # id -> {node, idle, pressed}
var _sticks := {}           # "left"/"right" -> {pivot, ball, idle, pressed}

var _dp_touch := -1
var _l_touch := -1
var _r_touch := -1
var _btn_touches := {}      # touch index -> button/pill id


func setup(shell_input: ShellInput, world_texture: Texture2D) -> void:
	_pad = shell_input
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build(world_texture)


func _load_layout() -> Dictionary:
	var f := FileAccess.open(ASSET_DIR + "layout.json", FileAccess.READ)
	if f == null:
		push_error("gb_ui layout.json missing")
		return {}
	var data = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}


func _build(world_texture: Texture2D) -> void:
	var layout := _load_layout()
	if layout.is_empty():
		# No skin available — still present the game full-rect so the screen is never black.
		var fb := TextureRect.new()
		fb.texture = world_texture
		fb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		fb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		fb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(fb)
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

	# Cream body, then the screen bezel, then the game LCD seated over the glass.
	_rect(load(ASSET_DIR + "case.png"), -4, -4, _shell_w + 8, _shell_h + 8)
	for pl in layout["placements"]:
		if String(pl["id"]) == "screen":
			_rect(load(ASSET_DIR + "bezel.png"), pl["x"], pl["y"], pl["w"], pl["h"])
			break
	var g: Dictionary = layout["glass_in_shell"]
	var lcd := _rect(world_texture, g["x"], g["y"], g["w"], g["h"], true, true)
	lcd.name = "Lcd"

	_build_dpad()
	_build_buttons()
	_build_sticks()
	_build_pills()


# ---- placement helpers -----------------------------------------------------
## Place a texture by top-left (x,y,w,h) in shell units, via ratio anchors so it scales with the case.
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


## Place a texture centred at (cx,cy) in shell units.
func _at(tex: Texture2D, cx: float, cy: float, w: float, h: float) -> TextureRect:
	return _rect(tex, cx - w * 0.5, cy - h * 0.5, w, h)


func _caption(word: String, cx: float, cy: float) -> void:
	var path := ASSET_DIR + "cap_" + word + ".png"
	if ResourceLoader.exists(path):
		_at(load(path), cx, cy, CAP_W, CAP_H)


func _build_dpad() -> void:
	for k in ["idle", "up", "down", "left", "right"]:
		_dpad_tex[k] = load(ASSET_DIR + "dpad_" + k + ".png")
	_dpad_node = _at(_dpad_tex["idle"], DPAD_C.x, DPAD_C.y, DPAD_W, DPAD_W)
	_caption("move", DPAD_C.x, DPAD_C.y + DPAD_W * 0.5 + 9.0)


func _build_buttons() -> void:
	for e in BUTTONS:
		var id: String = e[0]
		var idle: Texture2D = load(ASSET_DIR + id + "_idle.png")
		var pressed: Texture2D = load(ASSET_DIR + id + "_pressed.png")
		var node := _at(idle, e[1], e[2], BTN_W, BTN_H)
		_btns[id] = {"node": node, "idle": idle, "pressed": pressed}
		_caption(String(e[3]), e[1], float(e[2]) + BTN_H * 0.5 + 8.0)


func _build_sticks() -> void:
	var pivot: Texture2D = load(ASSET_DIR + "stick_pivot.png")
	var ball_idle: Texture2D = load(ASSET_DIR + "stick_ball.png")
	var ball_pressed: Texture2D = load(ASSET_DIR + "stick_ball_pressed.png")
	for side in ["left", "right"]:
		var c: Vector2 = STICK_L if side == "left" else STICK_R
		var pv := _at(pivot, c.x, c.y, STICK_W, STICK_W)
		var ball := _at(ball_idle, c.x, c.y + BALL_DY, BALL_W, BALL_H)
		_sticks[side] = {"pivot": pv, "ball": ball, "idle": ball_idle, "pressed": ball_pressed}


func _build_pills() -> void:
	var idle: Texture2D = load(ASSET_DIR + "pill_idle.png")
	var pressed: Texture2D = load(ASSET_DIR + "pill_pressed.png")
	for e in [["pill_select", PILL_SEL, "select"], ["pill_start", PILL_START, "start"]]:
		var node := _at(idle, e[1].x, e[1].y, PILL_W, PILL_H)
		_pills[e[0]] = {"node": node, "idle": idle, "pressed": pressed}
		_caption(String(e[2]), e[1].x, e[1].y + PILL_H * 0.5 + 8.0)


# ---- touch -----------------------------------------------------------------
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
	# Face keys: pick the closest one hit (rects do not overlap, but be robust).
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
		_pad.dpad(false, false, false, false)
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
	match id:
		"btn_A": _pad.hit()
		"btn_B": _pad.use()
		"btn_C": _pad.drive()
		"btn_X": _pad.jump(true)
		"btn_Y": _pad.run()
		"btn_Z": _pad.reset_action()
		"pill_start": _pad.reset_action()
		"pill_select": pass
	if _btns.has(id):
		_btns[id]["node"].texture = _btns[id]["pressed"]
	elif _pills.has(id):
		_pills[id]["node"].texture = _pills[id]["pressed"]


func _button_up(id: String) -> void:
	if id == "btn_X":
		_pad.jump(false)
	if _btns.has(id):
		_btns[id]["node"].texture = _btns[id]["idle"]
	elif _pills.has(id):
		_pills[id]["node"].texture = _pills[id]["idle"]


func _update_dpad(pos: Vector2) -> void:
	var rect: Rect2 = _dpad_node.get_global_rect()
	var c := rect.get_center()
	var nx := (pos.x - c.x) / (rect.size.x * 0.5)
	var ny := (pos.y - c.y) / (rect.size.y * 0.5)
	_pad.dpad(ny < -DEAD, ny > DEAD, nx < -DEAD, nx > DEAD)
	# Show the dominant held direction.
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
	# Ride the ball on the socket by shifting its anchored rect (in screen px = case-local px).
	var ball: TextureRect = s["ball"]
	ball.offset_left = d.x; ball.offset_top = d.y; ball.offset_right = d.x; ball.offset_bottom = d.y
	ball.texture = s["pressed"]
	var v := d / max_r
	if side == "left":
		_pad.stick_left(v)
	else:
		_pad.stick_right(v)


func _reset_stick(side: String) -> void:
	var s: Dictionary = _sticks[side]
	var ball: TextureRect = s["ball"]
	ball.offset_left = 0.0; ball.offset_top = 0.0; ball.offset_right = 0.0; ball.offset_bottom = 0.0
	ball.texture = s["idle"]
	if side == "left":
		_pad.stick_left(Vector2.ZERO)
	else:
		_pad.stick_right(Vector2.ZERO)
