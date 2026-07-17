extends Node3D
## Boots the world: sky + fog environment, sun, terrain streaming, the player, and the
## authored farm.

const PLAYER_SCENE := preload("res://player.tscn")
## Authored by tools/farm_designer.py. Missing or broken is fine — the terrain's own
## rules are a complete fallback, and the game still boots.
const FARM_PLAN_PATH := "res://farm/plan.json"
## How often to notice the designer saved. Cheap: a modified-time stat, not a re-parse.
const PLAN_POLL_SECONDS := 1.0

@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var terrain: TerrainManager = $TerrainManager

var _farm: FarmBuilder
var _plan_modified_at: int = 0
var _plan_poll: float = 0.0

func _ready() -> void:
	_setup_environment()
	_setup_sun()

	var player := PLAYER_SCENE.instantiate() as Player
	add_child(player)

	# Spawn slightly off the origin so the player lands inside a chunk rather than
	# on the seam where four chunks meet. height_at() is pure noise, so it is valid
	# before any chunk mesh exists.
	var spawn_x := 24.0
	var spawn_z := 40.0
	var spawn_height := terrain.height_at(spawn_x, spawn_z) + 3.0
	player.global_position = Vector3(spawn_x, spawn_height, spawn_z)

	terrain.player = player
	# Build solid ground around the spawn before the first physics frame.
	terrain.prime(player.global_position)

	_farm = FarmBuilder.new()
	_farm.name = "Farm"
	add_child(_farm)
	_load_farm_plan()

## Re-reads the plan when the designer saves it. This is what makes the designer a
## sidecar rather than a build step: nothing here rebuilds a chunk, re-derives collision
## or moves the player, because the plan deliberately does not feed height_at.
func _process(delta: float) -> void:
	_plan_poll -= delta
	if _plan_poll > 0.0:
		return
	_plan_poll = PLAN_POLL_SECONDS
	var modified := FileAccess.get_modified_time(FARM_PLAN_PATH)
	if modified != 0 and modified != _plan_modified_at:
		_load_farm_plan()

func _load_farm_plan() -> void:
	_plan_modified_at = FileAccess.get_modified_time(FARM_PLAN_PATH)
	var plan := FarmPlan.load_from(FARM_PLAN_PATH)
	if not plan.loaded:
		# Loud, but not fatal: a farm that fails to parse should say so and leave you
		# standing on plain terrain, not crash the game you were about to test it in.
		push_warning("farm plan not applied: %s" % plan.error)
	terrain.apply_farm_plan(plan)
	var stats := _farm.rebuild(plan, terrain)
	print("farm plan: %s | %d structures, %d fences, %d animals, %d crop blocks, %d grass blocks, %d nodes" % [
		"loaded" if plan.loaded else plan.error,
		stats.structures, stats.fences, stats.animals, stats.crop_blocks,
		stats.grass_blocks, stats.draws])

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.30, 0.52, 0.86)
	sky_material.sky_horizon_color = Color(0.72, 0.82, 0.90)
	sky_material.sky_curve = 0.12
	sky_material.ground_bottom_color = Color(0.30, 0.33, 0.30)
	sky_material.ground_horizon_color = Color(0.72, 0.82, 0.90)
	sky_material.sun_angle_max = 30.0

	var sky := Sky.new()
	sky.sky_material = sky_material
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	# The fog has two jobs that pull against each other: hide the streaming edge, but
	# leave the hills (380-700 out) legible as hazy silhouettes. So it stays thin well
	# past the basin and only closes up over the last few hundred units.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	# Matches the sky's horizon colour, so terrain fading out is indistinguishable
	# from sky rather than dissolving into a differently-coloured band.
	env.fog_light_color = Color(0.72, 0.82, 0.90)
	env.fog_sun_scatter = 0.2
	# In FOG_MODE_DEPTH density scales the begin/end ramp -- it is a multiplier, not a
	# per-unit rate. It has to be ~1.0 or the ramp never reaches full opacity: at the
	# 0.0022 this used to be set to, the fog was effectively absent and hid nothing.
	env.fog_density = 1.0
	env.fog_depth_begin = 200.0
	# Must reach full fog before the nearest point terrain can be missing, or the world
	# visibly ends. That distance is NOT view_distance * chunk_size: a chunk just
	# outside the streamed circle can start far nearer once the player's offset inside
	# their own chunk is counted. At view_distance 6 / chunk_size 192 the guarantee is
	# 960 units, so this sits just inside it. Change either and this must move too.
	env.fog_depth_end = 920.0
	# Fog builds late rather than linearly, which buys the aerial-perspective read:
	# near ranges keep their colour while far ones wash to sky.
	env.fog_depth_curve = 2.8
	env.fog_aerial_perspective = 0.5

	world_environment.environment = env

func _setup_sun() -> void:
	sun.rotation_degrees = Vector3(-52.0, -130.0, 0.0)
	sun.light_energy = 1.1
	sun.light_color = Color(1.0, 0.97, 0.90)
	sun.shadow_enabled = true
	# 2 splits over a short distance is plenty on the Pi: nearby terrain gets crisp
	# shadows, and the fog swallows everything past the shadowed range anyway.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 200.0
