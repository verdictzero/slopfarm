extends CanvasLayer
class_name DmgTitle
## A boot title card in the DMG style, drawn on its own CanvasLayer above everything (default 130).
## Give it a title image (fills the screen, KEEP_ASPECT_COVERED) or just a title string it renders in
## the pixel font, plus a blinking hint line ("PRESS START"). Pure visual — call dismiss() (or free
## it) when the player starts.
##
## Set `image` to a Texture2D (or `image_path`) for cover art; leave both empty to draw `title_text`.

const FONT_PATH := "res://addons/dmgkit/fonts/PressStart2P-Regular.ttf"
const LCD_BG := Color("9bbc0f")   # DMG lightest green
const INK := Color("0f380f")      # DMG darkest green

@export var title_text: String = "DMGKIT"
@export var hint_text: String = "PRESS START"
@export_file("*.png") var image_path: String = ""
## Set directly in code instead of image_path if you already have the texture.
var image: Texture2D

@export var ink: Color = INK
@export var title_layer: int = 130

var _hint: Label


func _ready() -> void:
	layer = title_layer

	if image == null and image_path != "":
		image = load(image_path) as Texture2D

	if image != null:
		var art := TextureRect.new()
		art.texture = image
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(art)
	else:
		# No art: a flat DMG-green field with the title in the pixel font.
		var bg := ColorRect.new()
		bg.color = LCD_BG
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)

		var title := Label.new()
		title.text = title_text
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		title.offset_bottom = -60.0
		title.modulate = ink
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_apply_font(title, 48)
		add_child(title)

	_hint = Label.new()
	_hint.text = hint_text
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_top = -120.0
	_hint.offset_bottom = -66.0
	_hint.modulate = ink
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_font(_hint, 28)
	add_child(_hint)

	var blink := Timer.new()
	blink.wait_time = 0.5
	blink.autostart = true
	add_child(blink)
	blink.timeout.connect(func() -> void: _hint.visible = not _hint.visible)


func _apply_font(label: Label, size: int) -> void:
	var f := load(FONT_PATH)
	if f != null:
		label.add_theme_font_override("font", f)
		label.add_theme_font_size_override("font_size", size)


func dismiss() -> void:
	queue_free()
