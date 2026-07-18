extends TouchControls
class_name GBShellInput
## Web input bridge: drives the game from the on-screen Game Boy shell (the custom HTML export
## shell in web/gb_shell.html) instead of from real screen-touch. It subclasses TouchControls on
## purpose, so the player and the truck consume it through the exact same surface —
## move_vector, jump_held, sprint, take_look(), and the four action signals — with no
## special-casing. The only difference is where the input comes from: each frame it reads
## window.GameBoyUI through JavaScriptBridge rather than InputEventScreenTouch, and it draws
## nothing (the pad lives in the HTML around the canvas, not on the game surface).
##
## The shell exposes window.gbSnapshot(): a compact CSV of the whole pad in a fixed order,
##   up,down,left,right, A,B,C,X,Y,Z,START,SELECT, Lx,Ly,Rx,Ry
## with booleans as 0/1 and sticks as -1..1. Stick Y is DOWN-positive (it comes straight from
## pointer coordinates), the same convention the touch thumb-stick uses.
##
## Pad -> game:
##   D-pad + left stick -> move            right stick -> look
##   A -> hit  (swing wand / throw)        B -> use   (pick up / feed / load / sell)
##   X -> jump (held)                      Y -> sprint (held)
##   C -> drive truck (toggle)             Z -> respawn
##   START / SELECT -> reserved (SELECT long-press toggles the shell's dev HUD, handled shell-side)

## Look speed from the right stick, in the screen-drag units take_look() returns. The player turns
## that into radians via touch_look_sensitivity (~0.006 rad/unit), so ~430 units/s is about
## 2.6 rad/s of yaw at full deflection — brisk but controllable.
const LOOK_UNITS_PER_SEC := 430.0

## Number of fields in a gbSnapshot() row; anything shorter is treated as no input.
const SNAPSHOT_FIELDS := 16

## Rising-edge memory for the momentary action buttons, so each press fires its signal once.
var _prev_a := false
var _prev_b := false
var _prev_c := false
var _prev_z := false


func _ready() -> void:
	# Deliberately skip TouchControls._ready(): there is no on-screen stick or button cluster to
	# lay out here and no viewport-touch geometry to track — this source only reads GameBoyUI.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


## Nothing to paint: the controls are HTML around the canvas, not drawn on the game.
func _draw() -> void:
	pass


## Ignore engine input events; this source is fed entirely from the HTML shell.
func _input(_event: InputEvent) -> void:
	pass


func _process(delta: float) -> void:
	var snap: Variant = null
	if OS.has_feature("web"):
		# Evaluate in the global context so window.gbSnapshot resolves. Returns "" until the shell
		# is wired up, and null when off the web (JavaScriptBridge is a no-op there) — both fall
		# through to the idle reset below, so a desktop build with SLOPFARM_GBSHELL just sits idle.
		snap = JavaScriptBridge.eval("(window.gbSnapshot ? window.gbSnapshot() : '')", true)
	if typeof(snap) != TYPE_STRING or snap == "":
		_go_idle()
		return
	var f := (snap as String).split(",")
	if f.size() < SNAPSHOT_FIELDS:
		_go_idle()
		return

	var up := f[0] == "1"
	var down := f[1] == "1"
	var left := f[2] == "1"
	var right := f[3] == "1"
	var a := f[4] == "1"
	var b := f[5] == "1"
	var c := f[6] == "1"
	var x := f[7] == "1"
	var y := f[8] == "1"
	var z := f[9] == "1"
	var lx := f[12].to_float()
	var ly := f[13].to_float()
	var rx := f[14].to_float()
	var ry := f[15].to_float()

	# Move: D-pad + left stick in TouchControls' convention (x = strafe right-positive,
	# y = forward-positive). GameBoyUI stick Y is down-positive, so forward-positive = -ly.
	var mx := lx + (1.0 if right else 0.0) - (1.0 if left else 0.0)
	var my := -ly + (1.0 if up else 0.0) - (1.0 if down else 0.0)
	move_vector = Vector2(mx, my)
	if move_vector.length() > 1.0:
		move_vector = move_vector.normalized()

	# Look: accumulate the right stick as if it were a screen drag, so the inherited take_look()
	# hands it to the player exactly like a touch look-drag.
	if rx != 0.0 or ry != 0.0:
		_look_accum += Vector2(rx, ry) * LOOK_UNITS_PER_SEC * delta

	jump_held = x
	sprint = y

	# Momentary actions fire once, on the press edge.
	if a and not _prev_a:
		hit_pressed.emit()
	if b and not _prev_b:
		interact_pressed.emit()
	if c and not _prev_c:
		truck_pressed.emit()
	if z and not _prev_z:
		respawn_pressed.emit()
	_prev_a = a
	_prev_b = b
	_prev_c = c
	_prev_z = z


## Return to neutral when the shell is not (yet) feeding input, releasing any held state so a
## dropped connection can never leave the player walking or a button stuck down.
func _go_idle() -> void:
	move_vector = Vector2.ZERO
	jump_held = false
	sprint = false
	_prev_a = false
	_prev_b = false
	_prev_c = false
	_prev_z = false
