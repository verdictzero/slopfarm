extends CanvasLayer
class_name GBUI
## The Game Boy (DMG) LCD interface, per design_handoff_glue_factory_ui: a capsule-digit HUD strip
## (MONEY on the left, GLUE on the right) and a two-column main menu (list + detail/stats + a
## description bar), all in the four-shade DMG green ramp with a scanline overlay on top.
##
## It lives on its own CanvasLayer ABOVE the dither post-process (layer 100) and the crosshair
## (110), so the readouts and the menu draw crisp in front of the palette-snapped world rather than
## being dithered with it. Everything is painted in one _draw() on a full-LCD Control — the capsule
## gloss, the panels and the scanlines are all procedural, so the only bundled asset is the pixel
## font (Press Start 2P). The owner (player.gd) pushes money/glue in and drives the menu through the
## small API at the bottom; navigation input still arrives through the existing pad/keys.

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

# --- geometry, in native LCD pixels (the world SubViewport is 360x360) -------
const PAD := 12.0            # inset from the LCD edge (design 20 @ 560, scaled)
const STRIP_GAP := 7.0       # gap under the HUD strip before the menu body
const CAP_H := 18.0          # capsule height
const CAP_W := 13.0          # digit / sign capsule width
const SEP_W := 8.0           # separator (comma) capsule width
const CAP_R := 5.0           # capsule corner radius
const CAP_GAP := 2.0         # gap between capsules in a row
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
	_lcd.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	if _lcd != null:
		_lcd.size = get_viewport().get_visible_rect().size
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
	_draw_scanlines(w, h)


## MONEY (capsule row, top-left) and GLUE (capsule row + unit tag, top-right).
func _draw_hud(w: float) -> void:
	# MONEY, left.
	_lcd.draw_string(_font, Vector2(PAD + 3, PAD + LABEL_FS), "MONEY",
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK_MID)
	var money_y := PAD + LABEL_FS + 5.0
	_draw_capsule_row(_money_caps(), PAD, money_y)

	# GLUE, right — label and row both right-aligned to the padding edge.
	var glue_caps := _glue_caps()
	var tag := "SAX"
	var tag_w := _font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS).x
	var row_w := _row_width(glue_caps) + 5.0 + tag_w
	var right := w - PAD
	var glue_x := right - row_w
	var label_w := _font.get_string_size("GLUE", HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS).x
	_lcd.draw_string(_font, Vector2(right - label_w - 3, PAD + LABEL_FS), "GLUE",
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK_MID)
	var end_x := _draw_capsule_row(glue_caps, glue_x, money_y)
	# Unit tag, vertically centred on the capsule row.
	_lcd.draw_string(_font, Vector2(end_x + 5, money_y + (CAP_H + LABEL_FS) * 0.5 - 1), tag,
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FS, INK_MID)


func _row_width(caps: Array) -> float:
	var x := 0.0
	for c in caps:
		x += float(c["w"]) + CAP_GAP
	return x - CAP_GAP if not caps.is_empty() else 0.0


func _draw_capsule_row(caps: Array, x: float, y: float) -> float:
	for c in caps:
		var cw: float = c["w"]
		_draw_capsule(x, y, cw, c["lit"], String(c["ch"]))
		x += cw + CAP_GAP
	return x - CAP_GAP


## One glossy LCD-segment capsule: a vertical three-stop gradient with rounded corners, a bright
## top inset, a dark bottom inset and a 1px ink drop, then the glyph centred in the variant's ink.
func _draw_capsule(x: float, y: float, w: float, lit: bool, ch: String) -> void:
	var hi := LIT_HI if lit else DIM_HI
	var mid := LIT_MID if lit else DIM_MID
	var lo := LIT_LO if lit else DIM_LO
	var rows := int(CAP_H)
	for i in rows:
		var t := float(i) / float(rows - 1)
		var col: Color
		if t < 0.42:
			col = hi.lerp(mid, t / 0.42)
		else:
			col = mid.lerp(lo, (t - 0.42) / 0.58)
		# Top inset highlight and bottom inset shade (the analog gloss).
		if i == 0:
			col = col.lerp(Color(1, 1, 1), 0.55 if lit else 0.28)
		elif i == 1:
			col = col.lerp(Color(1, 1, 1), 0.22 if lit else 0.12)
		if i == rows - 1:
			col = col.lerp(INK, 0.34 if lit else 0.46)
		elif i == rows - 2:
			col = col.lerp(INK, 0.14 if lit else 0.22)
		# Rounded corners: pull the row in near the top/bottom by the circle inset.
		var dy := minf(float(i), float(rows - 1 - i))
		var inset := 0.0
		if dy < CAP_R:
			inset = CAP_R - sqrt(maxf(0.0, CAP_R * CAP_R - (CAP_R - dy) * (CAP_R - dy)))
		_lcd.draw_rect(Rect2(x + inset, y + float(i), w - 2.0 * inset, 1.0), col)
	# Ink drop under the capsule.
	_lcd.draw_rect(Rect2(x + CAP_R, y + CAP_H, w - 2.0 * CAP_R, 1.0), INK)
	# Glyph, centred.
	var txt := INK if lit else LIT_HI
	var gw := _font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, DIGIT_FS).x
	var asc := _font.get_ascent(DIGIT_FS)
	var desc := _font.get_descent(DIGIT_FS)
	var gx := x + (w - gw) * 0.5
	var gy := y + (CAP_H - (asc + desc)) * 0.5 + asc - 1.0   # lift 1px off the shaded bottom
	_lcd.draw_string(_font, Vector2(round(gx), round(gy)), ch,
			HORIZONTAL_ALIGNMENT_LEFT, -1, DIGIT_FS, txt)


## MONEY capsules: a lit '-' (only when negative), a dim '$', then the magnitude in lit digits with
## dim thousands separators — matching the HTML reference (sign lit, currency/commas dim).
func _money_caps() -> Array:
	var caps: Array = []
	if money < 0:
		caps.append({"ch": "-", "lit": true, "w": CAP_W})
	caps.append({"ch": "$", "lit": false, "w": CAP_W})
	for ch in _grouped(str(absi(money))):
		if ch == ",":
			caps.append({"ch": ",", "lit": false, "w": SEP_W})
		else:
			caps.append({"ch": ch, "lit": true, "w": CAP_W})
	return caps


## GLUE capsules: at least three digits; leading zeros dim, the units digit and everything from the
## first significant digit onward lit.
func _glue_caps() -> Array:
	var digits := str(glue)
	while digits.length() < 3:
		digits = "0" + digits
	var first := digits.length() - 1
	for i in digits.length():
		if digits[i] != "0":
			first = i
			break
	var caps: Array = []
	for i in digits.length():
		caps.append({"ch": digits[i], "lit": i >= first, "w": CAP_W})
	return caps


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


func _draw_scanlines(w: float, h: float) -> void:
	var c := Color(INK.r, INK.g, INK.b, 0.05)
	var y := 0.0
	while y < h:
		_lcd.draw_rect(Rect2(0, y, w, 1.0), c)
		y += 4.0
	var x := 0.0
	while x < w:
		_lcd.draw_rect(Rect2(x, 0, 1.0, h), c)
		x += 4.0


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
