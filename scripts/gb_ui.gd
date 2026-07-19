extends CanvasLayer
class_name GBUI
## The Game Boy (DMG) LCD interface, per design_handoff_glue_factory_ui: a HUD strip of dark-on-light
## readout chips (MONEY on the left, GLUE on the right) and a two-column main menu (list +
## detail/stats + a description bar), in the DMG green ramp.
##
## It lives on its own CanvasLayer ABOVE the dither post-process (layer 100) and the crosshair
## (110), so the readouts and the menu draw crisp in front of the palette-snapped world rather than
## being dithered with it. Everything is painted in one _draw() on a full-LCD Control — the chips
## and the panels are all procedural, so the only bundled asset is the pixel font (Press Start 2P).
## The owner (player.gd) pushes money/glue in and drives the menu through the small API at the
## bottom; navigation input still arrives through the existing pad/keys.

# --- DMG palette (design tokens; greens only) --------------------------------
const LCD_BG := Color("9bbc0f")      # lightest green, screen background
const LCD_BG_ALT := Color("a8c520")  # menu list-panel fill (slightly lighter)
const INK := Color("0f380f")         # darkest: borders, title bars, primary text
const INK_MID := Color("306230")     # secondary text / labels / unselected entries
const INK_SOFT := Color("1b4a1b")    # gradient base
const LIT_HI := Color("cfe27a")      # lit capsule gradient top / light-on-dark text
const LIT_MID := Color("9bbc0f")     # lit capsule gradient mid
const LIT_LO := Color("6b8f1f")      # lit capsule gradient low
const DIM_HI := Color("4d7a1f")      # dim capsule gradient top
const DIM_MID := Color("306230")     # dim capsule gradient mid
const DIM_LO := Color("1b4a1b")      # dim capsule gradient low
const CHIP_BG := LCD_BG              # readout chip background: the DMG lightest green (#9bbc0f)
const SHADOW := INK                  # chip drop-shadow colour (darkest green)

# --- geometry, in DESIGN pixels (a 360-tall LCD) -----------------------------
# Everything below is authored against a 360-pixel-tall screen. The world SubViewport now renders
# at 3x that (1080), so _on_resize draws the whole interface in this design space and scales it up
# to fill the buffer — the layout is written once and stays sharp at any density.
const DESIGN := 360.0
const PAD := 12.0            # inset from the LCD edge (design 20 @ 560, scaled)
const STRIP_GAP := 7.0       # gap under the HUD strip before the menu body
const CAP_H := 18.0          # capsule height
const CAP_W := 13.0          # digit / sign capsule width
const SEP_W := 8.0           # separator (comma) capsule width
const CAP_R := 5.0           # capsule corner radius
const CAP_GAP := 2.0         # gap between capsules in a row
const CHIP_PAD_X := 5.0      # text inset inside a white readout chip
const CHIP_PAD_Y := 3.0
const SHADOW_OFF := Vector2(-1.0, 1.0)   # drop shadow: one design pixel down-left
const DIGIT_FS := 8          # capsule glyph font size (Press Start 2P native cell)
const LABEL_FS := 8          # HUD label / unit-tag font size
const TITLE_FS := 8          # panel title-bar font size
const LIST_FS := 10          # menu list entry font size
const DETAIL_FS := 8         # subitem / stat font size

# --- state (owner writes these) ----------------------------------------------
var money := 0
var glue := 0
var glue_price := 0          # for the STATUS "WORTH" line; set by the owner at setup
var menu_open := false
var menu_index := 0

const ITEMS := ["STATUS", "CONTROLS", "RESPAWN", "RESUME"]

signal item_activated(id: String)

var _font: FontFile
var _lcd: Control
var _blink := true

# Prebuilt panel styleboxes (rounded fill + border), painted with draw_style_box.
var _sb_left: StyleBoxFlat
var _sb_right: StyleBoxFlat
var _sb_title: StyleBoxFlat
var _sb_desc: StyleBoxFlat


func _ready() -> void:
	layer = 112
	_font = _load_font()
	_build_styleboxes()

	_lcd = Control.new()
	_lcd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lcd.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Top-left anchored (not full-rect): _on_resize drives size and scale by hand so the design-space
	# drawing scales up to the buffer without the preset's anchors fighting the manual size.
	_lcd.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_lcd.draw.connect(_draw_lcd)
	add_child(_lcd)

	get_viewport().size_changed.connect(_on_resize)
	_on_resize()

	# Slow blink for the selection caret (steps, not a fade), like a real handheld menu.
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
	# Draw in the 360-tall design space and scale the whole LCD up to fill the (square) buffer, so
	# every capsule, panel and glyph stays proportional and crisp instead of shrinking on a bigger
	# buffer. At the old 360 buffer s is 1 and this is a no-op; at 1080 it is a clean 3x.
	var vp := get_viewport().get_visible_rect().size
	var s := maxf(1.0, vp.y / DESIGN)
	_lcd.scale = Vector2(s, s)
	_lcd.size = vp / s
	_lcd.queue_redraw()


## Load the pixel font and pin the crisp render params (the .import already does this; setting them
## here too keeps a stray default from ever softening the glyphs).
func _load_font() -> FontFile:
	var res := load("res://fonts/PressStart2P-Regular.ttf")
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

	# The menu is a full-screen state: cover the world with the LCD background, then paint the two
	# columns and the description bar under the (always-on) HUD strip.
	if menu_open:
		_lcd.draw_rect(Rect2(0, 0, w, h), LCD_BG)
		_draw_menu(w, h)

	_draw_hud(w)


## MONEY (top-left) and GLUE (top-right): each a dark-on-white readout chip with a drop shadow.
func _draw_hud(w: float) -> void:
	var chip_y := PAD + LABEL_FS + 5.0

	# MONEY, left: dark label above a white value chip.
	_lcd.draw_string(_font, Vector2(PAD + 1, PAD + LABEL_FS), "MONEY",
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK)
	_draw_chip(_money_str(), PAD, chip_y)

	# GLUE, right: label + white chip + unit tag, right-aligned to the padding edge.
	var glue_txt := _glue_str()
	var tag := "SAX"
	var tag_w := _font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS).x
	var block_w := _chip_width(glue_txt) + 5.0 + tag_w
	var right := w - PAD
	var glue_x := right - block_w
	var label_w := _font.get_string_size("GLUE", HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS).x
	_lcd.draw_string(_font, Vector2(right - label_w - 1, PAD + LABEL_FS), "GLUE",
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK)
	var chip_end := _draw_chip(glue_txt, glue_x, chip_y)
	# Unit tag, dark, vertically centred on the chip.
	var chip_h := DIGIT_FS + 2.0 * CHIP_PAD_Y
	_lcd.draw_string(_font, Vector2(chip_end + 5, chip_y + (chip_h + LABEL_FS) * 0.5 - 1), tag,
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK)


func _chip_width(text: String) -> float:
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, DIGIT_FS).x + 2.0 * CHIP_PAD_X


## A readout chip: dark text on a white box, the box carrying a single-pixel drop shadow one design
## pixel down-and-left. Returns the box's right edge so the caller can place a trailing tag.
func _draw_chip(text: String, x: float, y: float) -> float:
	var box := Rect2(x, y, _chip_width(text), DIGIT_FS + 2.0 * CHIP_PAD_Y)
	_lcd.draw_rect(Rect2(box.position + SHADOW_OFF, box.size), SHADOW)   # drop shadow, behind
	_lcd.draw_rect(box, CHIP_BG)                                        # light-green background
	var asc := _font.get_ascent(DIGIT_FS)
	var desc := _font.get_descent(DIGIT_FS)
	var ty := y + (box.size.y - (asc + desc)) * 0.5 + asc
	_lcd.draw_string(_font, Vector2(round(x + CHIP_PAD_X), round(ty)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, DIGIT_FS, INK)
	return box.position.x + box.size.x


## MONEY as dark text: a leading '-' only when negative, the '$', then the grouped magnitude.
func _money_str() -> String:
	return ("-$" if money < 0 else "$") + _grouped(str(absi(money)))


## GLUE as dark text: at least three digits, zero-padded.
func _glue_str() -> String:
	var digits := str(glue)
	while digits.length() < 3:
		digits = "0" + digits
	return digits


## Insert thousands separators: "1234567" -> "1,234,567".
func _grouped(digits: String) -> String:
	var out := ""
	var n := digits.length()
	for i in n:
		if i > 0 and (n - i) % 3 == 0:
			out += ","
		out += digits[i]
	return out


# --- menu --------------------------------------------------------------------
func _draw_menu(w: float, h: float) -> void:
	# Body sits under the HUD strip; the description bar is pinned to the bottom.
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
	for i in ITEMS.size():
		var selected := i == menu_index
		var col := INK if selected else INK_MID
		# Blinking caret on the selected row.
		if selected and _blink:
			_lcd.draw_string(_font, Vector2(r.position.x + 10, y + LIST_FS), ">",
					HORIZONTAL_ALIGNMENT_LEFT, -1, LIST_FS, INK)
		_lcd.draw_string(_font, Vector2(r.position.x + 22, y + LIST_FS), ITEMS[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, LIST_FS, col)
		y += LIST_FS + 11.0


func _draw_detail_panel(r: Rect2) -> void:
	_lcd.draw_style_box(_sb_right, r)
	_draw_dither(r.grow(-3.0))
	var title_h := TITLE_FS + 12.0
	_draw_title(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, title_h),
			ITEMS[menu_index] + " > INFO")

	var sub := _detail_sub()
	var y := r.position.y + title_h + 12.0
	for line in sub:
		_lcd.draw_string(_font, Vector2(r.position.x + 12, y + DETAIL_FS), line,
				HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FS, INK)
		y += DETAIL_FS + 9.0

	# Stats block pinned to the bottom, above a divider.
	var stats := _detail_stats()
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
			"> " + _detail_desc(), HORIZONTAL_ALIGNMENT_LEFT, -1, DETAIL_FS, LIT_HI)


func _draw_title(r: Rect2, text: String) -> void:
	_lcd.draw_style_box(_sb_title, r)
	_lcd.draw_string(_font, Vector2(r.position.x + 8, r.position.y + (r.size.y + TITLE_FS) * 0.5 - 1),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_FS, LIT_MID)


## A faint 45deg dither tile over the detail panel, matching the reference's checker texture.
func _draw_dither(r: Rect2) -> void:
	var c := Color(INK.r, INK.g, INK.b, 0.09)
	var y := r.position.y
	while y < r.end.y:
		var x := r.position.x + (0.0 if int((y - r.position.y) / 2.0) % 2 == 0 else 2.0)
		while x < r.end.x:
			_lcd.draw_rect(Rect2(x, y, 2.0, 2.0), c)
			x += 4.0
		y += 2.0


# --- per-item detail content -------------------------------------------------
func _detail_sub() -> Array:
	match ITEMS[menu_index]:
		"STATUS":
			return ["MONEY  $%s" % _grouped(str(absi(money))) if money >= 0 else "MONEY  -$%s" % _grouped(str(absi(money))),
					"GLUE   %d SAX" % glue]
		"CONTROLS":
			return ["MOVE   DPAD/WASD", "LOOK   RSTICK/MOUSE", "A/LMB  HIT", "B/E    USE"]
		"RESPAWN":
			return ["WARP TO SPAWN POINT", "", "CLEARS A STUCK STATE"]
		"RESUME":
			return ["BACK TO THE FACTORY", "", "KEEP MAKING GLUE"]
	return []


func _detail_stats() -> Array:
	match ITEMS[menu_index]:
		"STATUS":
			return [["MONEY", ("$%s" % _grouped(str(absi(money)))) if money >= 0 else ("-$%s" % _grouped(str(absi(money))))],
					["GLUE", str(glue)],
					["WORTH", "$%s" % _grouped(str(money + glue * glue_price))]]
		"CONTROLS":
			return [["JUMP", "X/SPC"], ["DRIVE", "C/F"], ["MENU", "START"]]
	return []


func _detail_desc() -> String:
	match ITEMS[menu_index]:
		"STATUS": return "YOUR TAKINGS AND GLUE ON HAND"
		"CONTROLS": return "HOW TO PLAY. START OPENS THIS MENU"
		"RESPAWN": return "PRESS A / ENTER TO WARP HOME"
		"RESUME": return "PRESS A / ENTER TO RESUME PLAY"
	return ""


# =============================================================================
# API for the owner (player.gd)
# =============================================================================
func set_money(v: int) -> void:
	if v != money:
		money = v
		_lcd.queue_redraw()


func set_glue(v: int) -> void:
	if v != glue:
		glue = v
		_lcd.queue_redraw()


func open_menu() -> void:
	menu_open = true
	_lcd.queue_redraw()


func close_menu() -> void:
	menu_open = false
	_lcd.queue_redraw()


func toggle_menu() -> void:
	menu_open = not menu_open
	_lcd.queue_redraw()


func nav(dir: int) -> void:
	if not menu_open:
		return
	menu_index = wrapi(menu_index + dir, 0, ITEMS.size())
	_lcd.queue_redraw()


func activate() -> void:
	if menu_open:
		item_activated.emit(ITEMS[menu_index])


func selected() -> String:
	return ITEMS[menu_index]


func get_font() -> FontFile:
	return _font
