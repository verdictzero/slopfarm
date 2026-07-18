extends Control
class_name GBConsole
## Builds the portrait Game Boy console from the PNG assets extracted from the web shell
## (sprites/gb_ui/ + layout.json, produced by tools/gen_gb_ui_assets.js) and turns touches on the
## D-pad, analog sticks, face keys and pills into calls on a ShellInput. Every part is composited at
## the exact web-relative position recorded in layout.json, so the native console reads as the web
## one. The game's LCD is a TextureRect showing the world SubViewport, seated over the bezel's glass.

const ASSET_DIR := "res://sprites/gb_ui/"
const DEAD := 0.16          # D-pad dead zone, matches the web shell
const STICK_MAX := 0.30     # fraction of stick width the thumb can travel, matches the web shell

# The transparent capture margins tools/gen_gb_ui_assets.js bakes around each part, in layout px
# [left, top, right, bottom]. Stripped at hit-test time so a part's touch target is its drawn glyph,
# not its padded rect (which would overlap its neighbours). Keep in sync with the generator.
const _PADS := {
	"btn": [14.0, 6.0, 14.0, 24.0],   # bottom margin also clips the baked caption below the disc
	"pill": [14.0, 14.0, 14.0, 14.0],
	"dpad": [10.0, 10.0, 10.0, 10.0],
	"stick": [10.0, 10.0, 10.0, 10.0],
}

var _pad: ShellInput
var _shell_w := 448.0
var _shell_h := 900.0
var _case: Control                       # sized to the fitted case rect by the AspectRatioContainer
var _nodes := {}                         # interactive id -> TextureRect (queried by global rect)
var _place := {}                         # interactive id -> its layout.json placement (for hit-tests)

# multi-touch tracking
var _dp_touch := -1
var _lstick_touch := -1
var _rstick_touch := -1
var _btn_touches := {}                   # touch index -> button id


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

	# Dim "room" behind the console, echoing the web page backdrop.
	var room := ColorRect.new()
	room.color = Color(0.09, 0.09, 0.11)
	room.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	room.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(room)

	# Fit the fixed 448x900 case into whatever portrait rect the device gives us.
	var fit := AspectRatioContainer.new()
	fit.ratio = _shell_w / _shell_h
	fit.stretch_mode = AspectRatioContainer.STRETCH_FIT
	fit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fit)

	_case = Control.new()
	_case.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fit.add_child(_case)

	# The cream body, placed at its true capture offset so the 456x908 texture maps 1:1: its 4px
	# margin sits outside the shell box and the body aligns exactly with every other part.
	_sprite("case.png", -4, -4, _shell_w + 8, _shell_h + 8)

	# Screen bezel (with green glass) first, then the game LCD seated over the glass hole.
	var glass: Dictionary = layout["glass_in_shell"]
	for pl in layout["placements"]:
		var id := String(pl["id"])
		if id == "screen":
			_sprite(String(pl["asset"]), pl["x"], pl["y"], pl["w"], pl["h"])
			break
	var lcd := _sprite_tex(world_texture, glass["x"], glass["y"], glass["w"], glass["h"], true, true)
	lcd.name = "Lcd"

	# Every other part at its recorded position; keep refs to the interactive ones.
	for pl in layout["placements"]:
		var id := String(pl["id"])
		if id == "screen":
			continue
		var tr := _sprite(String(pl["asset"]), pl["x"], pl["y"], pl["w"], pl["h"])
		if id == "dpad" or id.begins_with("btn_") or id.begins_with("pill_") or id.begins_with("stick_"):
			_nodes[id] = tr
			_place[id] = pl
		if id.begins_with("stick_"):
			# A centred nub so the socket does not read as empty (static for now).
			var nw := float(pl["w"]) * 0.52
			var nh := float(pl["h"]) * 0.52
			_sprite("stick_nub.png", float(pl["x"]) + (float(pl["w"]) - nw) * 0.5,
					float(pl["y"]) + (float(pl["h"]) - nh) * 0.5, nw, nh)


func _sprite(tex_name: String, x: float, y: float, w: float, h: float,
		nearest := false, aspect := false) -> TextureRect:
	return _sprite_tex(load(ASSET_DIR + tex_name), x, y, w, h, nearest, aspect)


func _sprite_tex(tex: Texture2D, x: float, y: float, w: float, h: float,
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
		elif d.index == _lstick_touch:
			_update_stick("left", d.position)
		elif d.index == _rstick_touch:
			_update_stick("right", d.position)


## Drawn (opaque) region of an interactive part in global coords: its scaled rect with the capture
## margin stripped, so overlapping padded rects stop stealing each other's taps.
func _hit_region(id: String) -> Rect2:
	var r: Rect2 = _nodes[id].get_global_rect()
	var pl: Dictionary = _place[id]
	var pad: Array = _PADS["dpad"]
	if id.begins_with("btn_"): pad = _PADS["btn"]
	elif id.begins_with("pill_"): pad = _PADS["pill"]
	elif id.begins_with("stick_"): pad = _PADS["stick"]
	var fl: float = pad[0] / float(pl["w"])
	var ft: float = pad[1] / float(pl["h"])
	var fr: float = pad[2] / float(pl["w"])
	var fb: float = pad[3] / float(pl["h"])
	return Rect2(r.position.x + fl * r.size.x, r.position.y + ft * r.size.y,
			r.size.x * (1.0 - fl - fr), r.size.y * (1.0 - ft - fb))


func _press(index: int, pos: Vector2) -> void:
	# Face keys / pills: their padded rects overlap, so among the ones whose DRAWN region is hit,
	# take the closest — a tap resolves to the key you touched, not the first in the list.
	var best_id := ""
	var best_d := INF
	for id in ["btn_A", "btn_B", "btn_C", "btn_X", "btn_Y", "btn_Z", "pill_start", "pill_select"]:
		if not _nodes.has(id):
			continue
		var region := _hit_region(id)
		if region.has_point(pos):
			var d := pos.distance_squared_to(region.get_center())
			if d < best_d:
				best_d = d
				best_id = id
	if best_id != "":
		_btn_touches[index] = best_id
		_button_down(best_id)
		return
	if _dp_touch == -1 and _nodes.has("dpad") and _hit_region("dpad").has_point(pos):
		_dp_touch = index
		_update_dpad(pos)
		return
	if _lstick_touch == -1 and _nodes.has("stick_left") and _hit_region("stick_left").has_point(pos):
		_lstick_touch = index
		_update_stick("left", pos)
		return
	if _rstick_touch == -1 and _nodes.has("stick_right") and _hit_region("stick_right").has_point(pos):
		_rstick_touch = index
		_update_stick("right", pos)


func _release(index: int) -> void:
	if index == _dp_touch:
		_dp_touch = -1
		_pad.dpad(false, false, false, false)
	elif index == _lstick_touch:
		_lstick_touch = -1
		_pad.stick_left(Vector2.ZERO)
	elif index == _rstick_touch:
		_rstick_touch = -1
		_pad.stick_right(Vector2.ZERO)
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
	if _nodes.has(id):
		_nodes[id].modulate = Color(0.82, 0.82, 0.82)


func _button_up(id: String) -> void:
	if id == "btn_X":
		_pad.jump(false)
	if _nodes.has(id):
		_nodes[id].modulate = Color.WHITE


func _update_dpad(pos: Vector2) -> void:
	var rect := _hit_region("dpad")
	var c := rect.get_center()
	var nx := (pos.x - c.x) / (rect.size.x * 0.5)
	var ny := (pos.y - c.y) / (rect.size.y * 0.5)
	_pad.dpad(ny < -DEAD, ny > DEAD, nx < -DEAD, nx > DEAD)


func _update_stick(side: String, pos: Vector2) -> void:
	var rect := _hit_region("stick_" + side)
	var c := rect.get_center()
	var max_r := rect.size.x * STICK_MAX
	var d := pos - c
	if d.length() > max_r:
		d = d.normalized() * max_r
	var v := d / max_r  # -1..1, y down-positive (as the web sticks report)
	if side == "left":
		_pad.stick_left(v)
	else:
		_pad.stick_right(v)
