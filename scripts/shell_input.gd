extends TouchControls
class_name ShellInput
## Input surface for the native portrait Game Boy console. It lives OUTSIDE the game SubViewport (a
## child of the shell UI) so its _process runs unpaused and undithered, and it IS-A TouchControls so
## the player and truck read it through the exact same interface (move_vector / jump_held / sprint /
## take_look() / the four action signals) with zero retyping. console_pad.gd drives it through the
## write-API below; the per-frame math mirrors gb_bridge.gd's, reading local fields instead of the
## web shell's gbSnapshot.

## Right-stick look speed, in 640x360 screen pixels per second at full deflection. Matches gb_bridge.
const LOOK_UNITS_PER_SEC := 430.0

var _up := false
var _down := false
var _left := false
var _right := false
var _lstick := Vector2.ZERO
var _rstick := Vector2.ZERO


func _ready() -> void:
	# Inert base: the console's visuals are separate PNG nodes, so we skip TouchControls' faceplate
	# layout/paint and never read raw events (console_pad feeds us).
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(false)


func _draw() -> void:
	# Inert: never paint the inherited TouchControls faceplate. Without this, its _draw would render
	# a stray D-pad/bezel fragment at (0,0) over the console (the node is never laid out).
	pass


# ---- write API, called by console_pad.gd ----------------------------------
func dpad(up: bool, down: bool, left: bool, right: bool) -> void:
	_up = up; _down = down; _left = left; _right = right

func stick_left(v: Vector2) -> void:
	_lstick = v

func stick_right(v: Vector2) -> void:
	_rstick = v

func jump(down: bool) -> void:
	jump_held = down

func run() -> void:
	# Toggle on the press edge only (console_pad calls this once per tap), matching the native
	# faceplate — deliberately unlike the web bridge, which holds sprint while Y is down.
	sprint = not sprint

func hit() -> void:
	hit_pressed.emit()

func use() -> void:
	interact_pressed.emit()

func drive() -> void:
	truck_pressed.emit()

func reset_action() -> void:
	respawn_pressed.emit()

func menu() -> void:
	menu_pressed.emit()


func _process(delta: float) -> void:
	# D-pad and left stick both fold into move_vector (forward = +y); clamp so a half-pushed stick
	# still walks at half pace. Right stick accumulates look, drained by the inherited take_look().
	var mx := _lstick.x + (1.0 if _right else 0.0) - (1.0 if _left else 0.0)
	var my := -_lstick.y + (1.0 if _up else 0.0) - (1.0 if _down else 0.0)
	var mv := Vector2(mx, my)
	if mv.length() > 1.0:
		mv = mv.normalized()
	move_vector = mv
	_look_accum += _rstick * LOOK_UNITS_PER_SEC * delta
