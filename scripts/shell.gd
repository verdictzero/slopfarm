extends Control
class_name GBShell
## Root of main.tscn. Renders the whole game into a fixed 1080x1080 World SubViewport (so the dither
## post-process keeps running at native res), then presents it two ways:
##   - native mobile: a portrait Game Boy console composited from PNG assets (console_pad.gd), with
##     input injected into the player via a ShellInput found through the "player" group;
##   - desktop / web: the game fills the window through a single TextureRect, and window input is
##     forwarded into the SubViewport so mouse-look and the action keys keep working. Web is wrapped
##     by its own HTML shell and driven by GBShellInput, so no in-engine console is built there.

@onready var _world: SubViewport = $World
@onready var _display: Control = $Display

var _shell_input: ShellInput
var _forward_input := false
var _bare_lcd: TextureRect


func _ready() -> void:
	_world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var tex := _world.get_texture()
	if TouchControls.is_console():
		await _build_console(tex)
	else:
		_build_bare(tex)
		_forward_input = true


## Desktop / web: the game is sized to a whole multiple of the 1080x1080 buffer and centred, so
## NEAREST scaling stays crisp rather than shimmering at fractional factors (or fit whole to the
## window when the buffer is larger than it — see _fit_bare).
func _build_bare(tex: Texture2D) -> void:
	_bare_lcd = TextureRect.new()
	_bare_lcd.texture = tex
	_bare_lcd.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_bare_lcd.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bare_lcd.stretch_mode = TextureRect.STRETCH_SCALE
	_bare_lcd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_display.add_child(_bare_lcd)
	_fit_bare()
	get_viewport().size_changed.connect(_fit_bare)


func _fit_bare() -> void:
	if _bare_lcd == null:
		return
	var game := Vector2(_world.size)
	var view := get_viewport().get_visible_rect().size
	var raw := minf(view.x / game.x, view.y / game.y)
	# Integer-upscale when the buffer fits the window, so NEAREST stays crisp rather than shimmering
	# at fractional factors. When the buffer is LARGER than the window (the 1080 LCD in a small
	# desktop/web window), fall back to fit-to-view so the whole screen shows instead of being
	# clipped. The native console path scales into its glass rect and never comes through here.
	var s: float = floor(raw) if raw >= 1.0 else raw
	var dim := game * s
	_bare_lcd.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_bare_lcd.size = dim
	_bare_lcd.position = ((view - dim) * 0.5).round()


## Native mobile: the portrait console around the LCD, with input pushed to the player.
func _build_console(tex: Texture2D) -> void:
	# The input object lives OUTSIDE the SubViewport (as our child) so it is never dithered or
	# paused with the world, and its _process drives move/look every frame.
	_shell_input = ShellInput.new()
	add_child(_shell_input)

	var console := GBConsole.new()
	_display.add_child(console)
	console.setup(_shell_input, tex)

	# Find the player (it lives inside the SubViewport but shares this SceneTree) and hand it the
	# input source. It is normally already spawned by the time we get here; guard a late add_child.
	var players := get_tree().get_nodes_in_group("player")
	while players.is_empty():
		await get_tree().process_frame
		players = get_tree().get_nodes_in_group("player")
	players[0].set_input_source(_shell_input)


func _unhandled_input(event: InputEvent) -> void:
	# Desktop/web: the bare TextureRect does not route events, so hand mouse-motion and the action
	# keys to the game inside the SubViewport. The console path injects input directly, so skip it.
	if _forward_input:
		_world.push_input(event)
