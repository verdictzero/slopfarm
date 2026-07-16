extends CharacterBody3D
class_name Player
## Minimal first-person controller: WASD to move, mouse to look,
## Shift to sprint, Space to jump, Esc to release the mouse.

@export var walk_speed: float = 9.0
@export var sprint_speed: float = 18.0
@export var jump_velocity: float = 7.0
@export var gravity: float = 22.0
@export var mouse_sensitivity: float = 0.0025
## Camera far plane — pushed out for the long draw distance.
@export var camera_far: float = 5000.0

@onready var camera: Camera3D = $Camera3D

var _pitch: float = 0.0

func _ready() -> void:
	camera.far = camera_far
	# Skip mouse capture when running with no display (headless validation).
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.4, 1.4)
		camera.rotation.x = _pitch
	elif event.is_action_pressed(&"ui_cancel"):
		# Toggle the mouse capture (Esc).
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		# Click back into the window to recapture the mouse.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif Input.is_physical_key_pressed(KEY_SPACE):
		velocity.y = jump_velocity

	var input := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		input.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		input.y += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		input.x += 1.0
	input = input.normalized()

	var speed := sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()
