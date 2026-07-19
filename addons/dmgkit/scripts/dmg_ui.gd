extends CanvasLayer
class_name DmgUI
## The Game Boy (DMG) LCD interface from slopfarm, generalised: a HUD strip of dark-on-light readout
## chips and a two-column main menu (list + detail/stats + a description bar), all in the DMG green
## ramp and the Press Start 2P pixel font.
##
## The LOOK is fixed (that's the point); the CONTENT is data you set from your game:
##   - readouts: the HUD chips  -> set_readouts([...])
##   - menu_items: the menu     -> set_menu_items([...])
## Nothing here knows what a "money" or a "glue" is.
##
## It lives on its own CanvasLayer (default 112). Put it ABOVE a DmgDither (layer 100) and the
## readouts and menu draw crisp in front of the palette-snapped world instead of being dithered with
## it. Navigation input is pushed in by the owner via nav()/activate()/toggle_menu().
##
## readouts: Array of { "label": String, "value": String, "unit": String = "", "side": int }
##           side 0 = pack from the left, side 1 = pack from the right.
## menu_items: Array of { "title": String, "id": String = title,
##                        "lines": Array[String] = [], "stats": Array = [[k,v],...], "desc": String }

# --- DMG palette (greens only) -----------------------------------------------
const LCD_BG := Color("9bbc0f")
const LCD_BG_ALT := Color("a8c520")
const INK := Color("0f380f")
const INK_MID := Color("306230")
const LIT_HI := Color("cfe27a")
const LIT_MID := Color("9bbc0f")
const CHIP_BG := LCD_BG
const SHADOW := INK

# --- geometry, in DESIGN pixels (a 360-tall LCD) -----------------------------
const DESIGN := 360.0
const PAD := 12.0
const STRIP_GAP := 7.0
const CAP_H := 18.0
const CHIP_PAD_X := 5.0
const CHIP_PAD_Y := 3.0
const SHADOW_OFF := Vector2(-1.0, 1.0)
const DIGIT_FS := 8
const LABEL_FS := 8
const TITLE_FS := 8
const LIST_FS := 8            # native 8-px cell — off-grid sizes rasterise unevenly
const DETAIL_FS := 8

const FONT_PATH := "res://addons/dmgkit/fonts/PressStart2P-Regular.ttf"

# --- state -------------------------------------------------------------------
## HUD chips. See the class doc for the shape.
var readouts: Array = []
## Menu entries. See the class doc for the shape.
var menu_items: Array = []
var menu_open := false
var menu_index := 0
## CanvasLayer ordering. Keep above your DmgDither's layer so the UI stays crisp.
@export var ui_layer: int = 112

signal item_activated(index: int, id: String)

var _font: FontFile
var _lcd: Control
var _blink := true
var _sb_left: StyleBoxFlat
var _sb_right: StyleBoxFlat
var _sb_title: StyleBoxFlat
var _sb_desc: StyleBoxFlat


func _ready() -> void:
	layer = ui_layer
	_font = _load_font()
	_build_styleboxes()

	_lcd = Control.new()
	_lcd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lcd.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_lcd.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_lcd.draw.connect(_draw_lcd)
	add_child(_lcd)

	get_viewport().size_changed.connect(_on_resize)
	_on_resize()

	var blink := Timer.new()
	blink.wait_time = 0.53
	blink.autostart = true
	add_child(blink)
	blink.timeout.connect(func() -> void:
		_blink = not _blink
		if menu_open:
			_lcd.queue_redraw())


func _on_resize() -> void:
	if _lcd == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var s := maxf(1.0, vp.y / DESIGN)
	_lcd.scale = Vector2(s, s)
	_lcd.size = vp / s
	_lcd.queue_redraw()


func _load_font() -> FontFile:
	var res := load(FONT_PATH)
	if res is FontFile:
		var f: FontFile = (res as FontFile).duplicate()
		f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		f.hinting = TextServer.HINTING_NONE
		f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		f.force_autohinter = false
		f.generate_mipmaps = false
		return f
	return null


func _build_styleboxes() -> void:
	_sb_left = _panel_box(LCD_BG_ALT, INK, 2, 4)
	_sb_right = _panel_box(LCD_BG, INK, 2, 4)
	_sb_desc = _panel_box(INK, INK, 2, 4)
	_sb_title = StyleBoxFlat.new()
	_sb_title.bg_color = INK
	_sb_title.corner_radius_top_left = 3
	_sb_title.corner_radius_top_right = 3


func _panel_box(fill: Color, border: Color, bw: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_border_width_all(bw)
	sb.border_color = border
	sb.set_corner_radius_all(radius)
	return sb


# =============================================================================
# Drawing
# =============================================================================
func _draw_lcd() -> void:
	if _font == null:
		return
	var w := _lcd.size.x
	var h := _lcd.size.y
	if menu_open:
		_lcd.draw_rect(Rect2(0, 0, w, h), LCD_BG)
		_draw_menu(w, h)
	_draw_hud(w)


## Lays the readout chips: side 0 packs from the left edge, side 1 from the right.
func _draw_hud(w: float) -> void:
	var chip_y := PAD + LABEL_FS + 5.0
	var left_x := PAD
	var right_x := w - PAD
	for r in readouts:
		var label := String(r.get("label", ""))
		var value := String(r.get("value", ""))
		var unit := String(r.get("unit", ""))
		var side := int(r.get("side", 0))
		var chip_w := _chip_width(value)
		var unit_w := 0.0
		if unit != "":
			unit_w = 5.0 + _font.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS).x
		var block_w := maxf(chip_w + unit_w, _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS).x)
		var bx := left_x
		if side == 1:
			bx = right_x - block_w
		# Label above, chip below, optional unit tag after the chip.
		var label_x := bx
		if side == 1:
			label_x = bx + block_w - _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS).x
		_lcd.draw_string(_font, Vector2(label_x + (1 if side == 0 else -1), PAD + LABEL_FS), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK)
		var chip_end := _draw_chip(value, bx, chip_y)
		if unit != "":
			var chip_h := DIGIT_FS + 2.0 * CHIP_PAD_Y
			_lcd.draw_string(_font, Vector2(chip_end + 5, chip_y + (chip_h + LABEL_FS) * 0.5 - 1),
					unit, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK)
		if side == 0:
			left_x += block_w + 14.0
		else:
			right_x -= block_w + 14.0


func _chip_width(text: String) -> float:
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, DIGIT_FS).x + 2.0 * CHIP_PAD_X


func _draw_chip(text: String, x: float, y: float) -> float:
	var box := Rect2(x, y, _chip_width(text), DIGIT_FS + 2.0 * CHIP_PAD_Y)
	_lcd.draw_rect(Rect2(box.position + SHADOW_OFF, box.size), SHADOW)
	_lcd.draw_rect(box, CHIP_BG)
	var asc := _font.get_ascent(DIGIT_FS)
	var desc := _font.get_descent(DIGIT_FS)
	var ty := y + (box.size.y - (asc + desc)) * 0.5 + asc
	_lcd.draw_string(_font, Vector2(round(x + CHIP_PAD_X), round(ty)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, DIGIT_FS, INK)
	return box.position.x + box.size.x


# --- menu --------------------------------------------------------------------
func _draw_menu(w: float, h: float) -> void:
	var body_top := PAD + LABEL_FS + 5.0 + CAP_H + STRIP_GAP
	var desc_h := DETAIL_FS + 14.0
	var desc_top := h - PAD - desc_h
	var body_bottom := desc_top - STRIP_GAP
	var left_w := 118.0
	var col_gap := 8.0

	var left := Rect2(PAD, body_top, left_w, body_bottom - body_top)
	var right := Rect2(PAD + left_w + col_gap, body_top,
			w - PAD - (PAD + left_w + col_gap), body_bottom - body_top)

	_draw_list_panel(left)
	_draw_detail_panel(right)
	_draw_desc_bar(Rect2(PAD, desc_top, w - 2.0 * PAD, desc_h))


func _draw_list_panel(r: Rect2) -> void:
	_lcd.draw_style_box(_sb_left, r)
	var title_h := TITLE_FS + 12.0
	_draw_title(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, title_h), "MENU")
	var y := r.position.y + title_h + 12.0
	for i in menu_items.size():
		var selected := i == menu_index
		var col := INK if selected else INK_MID
		if selected and _blink:
			_lcd.draw_string(_font, Vector2(r.position.x + 10, y + LIST_FS), ">",
					HORIZONTAL_ALIGNMENT_LEFT, -1, LIST_FS, INK)
		_lcd.draw_string(_font, Vector2(r.position.x + 22, y + LIST_FS), String(menu_items[i].get("title", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, LIST_FS, col)
		y += LIST_FS + 11.0


func _draw_detail_panel(r: Rect2) -> void:
	_lcd.draw_style_box(_sb_right, r)
	var title_h := TITLE_FS + 12.0
	var item: Dictionary = _item(menu_index)
	_draw_title(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, title_h),
			String(item.get("title", "")) + " > INFO")

	var y := r.position.y + title_h + 12.0
	for line in item.get("lines", []):
		_lcd.draw_string(_font, Vector2(r.position.x + 12, y + DETAIL_FS), String(line),
				HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FS, INK)
		y += DETAIL_FS + 9.0

	var stats: Array = item.get("stats", [])
	if not stats.is_empty():
		var block_h := stats.size() * (DETAIL_FS + 8.0) + 10.0
		var sy := r.position.y + r.size.y - block_h
		_lcd.draw_rect(Rect2(r.position.x + 2, sy, r.size.x - 4, 2), INK)
		sy += 10.0
		for row in stats:
			_lcd.draw_string(_font, Vector2(r.position.x + 12, sy + DETAIL_FS), String(row[0]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FS, INK_MID)
			var vw := _font.get_string_size(String(row[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FS).x
			_lcd.draw_string(_font, Vector2(r.position.x + r.size.x - 12 - vw, sy + DETAIL_FS),
					String(row[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FS, INK)
			sy += DETAIL_FS + 8.0


func _draw_desc_bar(r: Rect2) -> void:
	_lcd.draw_style_box(_sb_desc, r)
	_lcd.draw_string(_font, Vector2(r.position.x + 10, r.position.y + (r.size.y + DETAIL_FS) * 0.5 - 1),
			"> " + String(_item(menu_index).get("desc", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FS, LIT_HI)


func _draw_title(r: Rect2, text: String) -> void:
	_lcd.draw_style_box(_sb_title, r)
	_lcd.draw_string(_font, Vector2(r.position.x + 8, r.position.y + (r.size.y + TITLE_FS) * 0.5 - 1),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_FS, LIT_MID)


func _item(i: int) -> Dictionary:
	if i >= 0 and i < menu_items.size():
		return menu_items[i]
	return {}


# =============================================================================
# API
# =============================================================================
## Replace the HUD chips. See the class doc for the item shape.
func set_readouts(list: Array) -> void:
	readouts = list
	if _lcd != null:
		_lcd.queue_redraw()


## Replace the menu entries. See the class doc for the item shape.
func set_menu_items(list: Array) -> void:
	menu_items = list
	menu_index = clampi(menu_index, 0, maxi(0, list.size() - 1))
	if _lcd != null:
		_lcd.queue_redraw()


func open_menu() -> void:
	menu_open = true
	if _lcd != null:
		_lcd.queue_redraw()


func close_menu() -> void:
	menu_open = false
	if _lcd != null:
		_lcd.queue_redraw()


func toggle_menu() -> void:
	menu_open = not menu_open
	if _lcd != null:
		_lcd.queue_redraw()


func nav(dir: int) -> void:
	if not menu_open or menu_items.is_empty():
		return
	menu_index = wrapi(menu_index + dir, 0, menu_items.size())
	_lcd.queue_redraw()


func activate() -> void:
	if menu_open and not menu_items.is_empty():
		item_activated.emit(menu_index, String(_item(menu_index).get("id", _item(menu_index).get("title", ""))))


func selected_index() -> int:
	return menu_index


func get_font() -> FontFile:
	return _font
