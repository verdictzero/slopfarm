extends Node3D
class_name TownBuilder
## Raises the distant towns: little clusters of procedural buildings standing where the winding
## roads end. From the farm they read as hazy silhouettes on the horizon; up close they are
## streets of cottages, shops, a church tower and — in the market towns — a glue market where
## the player sells what the works turned out.
##
## Built the same way as the farm and the factory: each building is one merged, vertex-coloured,
## flat-shaded mesh through MeshKit, sitting ON the terrain with a foundation skirt that sinks
## below the ground so no daylight shows under a wall on a slope. Buildings carry a trimesh body
## so the player on foot cannot walk through them; they are spaced generously so nothing wedges.
##
## The market towns drop a marker into the "glue_market" group at their depot door — that is what
## the player's sell interaction homes in on.

const FOUNDATION_SINK := 3.0

# Palettes — a handful of wall and roof tones mixed through a town so it is not one colour.
const WALLS: Array[Color] = [
	Color(0.80, 0.76, 0.66), Color(0.74, 0.66, 0.55), Color(0.68, 0.62, 0.58),
	Color(0.82, 0.72, 0.60), Color(0.60, 0.52, 0.48),
]
const ROOFS: Array[Color] = [
	Color(0.44, 0.26, 0.22), Color(0.38, 0.36, 0.40), Color(0.52, 0.40, 0.24),
	Color(0.34, 0.30, 0.30),
]
const TIMBER := Color(0.32, 0.24, 0.17)
const STONE := Color(0.60, 0.60, 0.62)
const WINDOW := Color(0.20, 0.24, 0.28)
const DOOR := Color(0.30, 0.20, 0.14)
const MARKET_WALL := Color(0.72, 0.44, 0.26)
const MARKET_SIGN := Color(0.86, 0.66, 0.12)

var _terrain: TerrainManager
var _mat: StandardMaterial3D
var _kit := MeshKit.new()


## Builds every town. Call once from main after the terrain exists.
func setup(terrain: TerrainManager) -> void:
	_terrain = terrain
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 1.0
	_mat.metallic = 0.0
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	for town in WorldSites.TOWNS:
		_build_town(town)


func _build_town(town: Dictionary) -> void:
	var center: Vector2 = town["pos"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(town["seed"]) * 733 + 17

	# The depot faces the road, i.e. the hub. Put it on the near edge so the road arrives at it.
	var to_hub := (WorldSites.HUB - center).normalized()
	if bool(town["market"]):
		var depot_at := center + to_hub * 30.0
		_build_market(depot_at, center, town)

	# A ring of plots around the square, plus a couple set in near the middle. Each building
	# faces the town centre. Jittered so the streets are not a perfect wheel.
	var plots := 11
	for k in plots:
		var a := TAU * float(k) / float(plots) + rng.randf_range(-0.18, 0.18)
		# Skip the wedge the depot occupies so nothing overlaps it.
		if bool(town["market"]) and absf(_angle_diff(a, to_hub.angle())) < 0.45:
			continue
		var radius := rng.randf_range(20.0, 38.0)
		var at := center + Vector2(cos(a), sin(a)) * radius
		var yaw := at.angle_to_point(center)   # face the square
		_build_dwelling(at, yaw, rng)
	# Two inner buildings flanking the square.
	for s: float in [-1.0, 1.0]:
		var at := center + Vector2(to_hub.y, -to_hub.x) * (12.0 * s)
		_build_dwelling(at, at.angle_to_point(center), rng)


# ---- buildings --------------------------------------------------------------

## Places one building of a random archetype at world XZ `at`, yawed to `yaw`.
func _build_dwelling(at: Vector2, yaw: float, rng: RandomNumberGenerator) -> void:
	var base_y := _terrain.height_at(at.x, at.y)
	_kit.begin()
	var kind := rng.randi_range(0, 2)
	match kind:
		0: _cottage(rng)
		1: _shop(rng)
		_: _tower(rng)
	_emit_building(Vector3(at.x, base_y, at.y), yaw)


## A timber-framed cottage: plaster walls, a gable roof, a door, windows, corner timbers and a
## chimney with a wisp of a cap.
func _cottage(rng: RandomNumberGenerator) -> void:
	var w := rng.randf_range(6.0, 8.0)
	var d := rng.randf_range(5.0, 7.0)
	var h := rng.randf_range(3.4, 4.2)
	var wall: Color = WALLS[rng.randi_range(0, WALLS.size() - 1)]
	var roof: Color = ROOFS[rng.randi_range(0, ROOFS.size() - 1)]
	_walls(w, h, d, wall)
	_gable_roof(w, d, h, 2.2, roof)
	_facade(w, d, h)
	# Corner timbers.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_kit.box(Vector3(sx * (w * 0.5 - 0.15), (h - FOUNDATION_SINK) * 0.5, sz * (d * 0.5 - 0.15)),
					Vector3(0.3, h + FOUNDATION_SINK, 0.3), TIMBER)
	# Chimney.
	_kit.box(Vector3(w * 0.3, h + 1.2, -d * 0.25), Vector3(0.8, 2.6, 0.8), STONE.darkened(0.1))
	_kit.box(Vector3(w * 0.3, h + 2.5, -d * 0.25), Vector3(1.0, 0.3, 1.0), STONE.darkened(0.2))


## A shop: a taller storefront with a big glazed front, an awning and a hanging sign.
func _shop(rng: RandomNumberGenerator) -> void:
	var w := rng.randf_range(6.5, 8.5)
	var d := rng.randf_range(6.0, 7.5)
	var h := rng.randf_range(4.4, 5.4)
	var wall: Color = WALLS[rng.randi_range(0, WALLS.size() - 1)]
	var roof: Color = ROOFS[rng.randi_range(0, ROOFS.size() - 1)]
	_walls(w, h, d, wall)
	# Shallow hipped-ish cap (a low box roof + ridge trim).
	_kit.box(Vector3(0, h + 0.3, 0), Vector3(w + 0.6, 0.6, d + 0.6), roof)
	_kit.box(Vector3(0, h + 0.75, 0), Vector3(w - 1.0, 0.3, d - 1.0), roof.darkened(0.1))
	# Glazed shopfront on +Z, an awning over it, and a hanging sign.
	_kit.box(Vector3(0, 1.6, d * 0.5 - 0.05), Vector3(w - 1.6, 2.4, 0.2), WINDOW)
	_kit.box(Vector3(0, 3.0, d * 0.5 + 0.5), Vector3(w - 0.8, 0.2, 1.2), roof.lightened(0.1))
	_kit.box(Vector3(w * 0.3, 2.6, d * 0.5 + 0.9), Vector3(0.1, 1.0, 1.4), TIMBER)
	_kit.box(Vector3(w * 0.3, 2.0, d * 0.5 + 0.9), Vector3(0.6, 0.8, 0.1), WALLS[0])
	_facade_door(d, 0.0)


## A church-ish tower: a tall stone tower with a spire, and a lower nave beside it.
func _tower(rng: RandomNumberGenerator) -> void:
	var tw := rng.randf_range(3.6, 4.6)
	var th := rng.randf_range(8.0, 11.0)
	_walls(tw, th, tw, STONE)
	# Belfry openings near the top and a spire.
	for s in [-1.0, 1.0]:
		_kit.box(Vector3(s * tw * 0.5, th - 1.4, 0), Vector3(0.15, 1.4, 1.0), WINDOW)
		_kit.box(Vector3(0, th - 1.4, s * tw * 0.5), Vector3(1.0, 1.4, 0.15), WINDOW)
	_kit.cone(Vector3(0, th, 0), tw * 0.72, 3.4, 4, ROOFS[1])
	_kit.box(Vector3(0, th + 3.6, 0), Vector3(0.2, 0.9, 0.2), MARKET_SIGN)   # finial
	# Lower nave off the -X side.
	var nave_w := tw * 1.6
	var nave_d := tw + 1.0
	_kit.box(Vector3(-tw * 0.5 - nave_w * 0.5, (4.0 - FOUNDATION_SINK) * 0.5, 0),
			Vector3(nave_w, 4.0 + FOUNDATION_SINK, nave_d), STONE.lightened(0.04))
	_gable_at(Vector3(-tw * 0.5 - nave_w * 0.5, 4.0, 0), nave_w, nave_d, 1.6, ROOFS[3])
	_kit.box(Vector3(-tw * 0.5 - nave_w, 1.4, 0), Vector3(0.2, 2.0, 1.0), DOOR)   # arched door


## The prominent glue market / depot: a big steel-and-timber trade hall with wide doors, a stack
## of glue sacks on the dock and a bright signboard. Drops a "glue_market" marker at its door.
func _build_market(at: Vector2, center: Vector2, town: Dictionary) -> void:
	var base_y := _terrain.height_at(at.x, at.y)
	var yaw := at.angle_to_point(center)   # its back to the square, doors to the road
	_kit.begin()
	var w := 12.0
	var d := 10.0
	var h := 6.5
	_walls(w, h, d, MARKET_WALL)
	_gable_roof(w, d, h, 3.0, ROOFS[0])
	# Big cargo doors on the road side (-Z, toward the road/hub after the yaw), framed hazard.
	_kit.box(Vector3(0, 2.4, d * 0.5 - 0.05), Vector3(6.0, 4.8, 0.2), Color(0.14, 0.12, 0.12))
	for sx in [-1.0, 1.0]:
		_kit.box(Vector3(sx * 3.2, 2.4, d * 0.5 + 0.05), Vector3(0.4, 5.0, 0.4), MARKET_SIGN)
	_kit.box(Vector3(0, 5.2, d * 0.5 + 0.1), Vector3(6.6, 0.5, 0.4), MARKET_SIGN)
	# Signboard over the doors.
	_kit.box(Vector3(0, h + 1.6, d * 0.5 - 0.2), Vector3(8.0, 2.0, 0.4), Color(0.15, 0.12, 0.10))
	_kit.box(Vector3(0, h + 1.6, d * 0.5 - 0.0), Vector3(7.0, 1.3, 0.2), MARKET_SIGN)
	# A loading dock and a stack of sacks out front.
	_kit.box(Vector3(0, 0.4, d * 0.5 + 2.0), Vector3(8.0, 0.8, 3.0), STONE.darkened(0.1))
	for sx in range(-2, 3):
		for sy in range(0, 2):
			_kit.box(Vector3(float(sx) * 1.2, 1.2 + float(sy) * 0.7, d * 0.5 + 2.0),
					Vector3(0.9, 0.7, 0.7), Color(0.60, 0.50, 0.33).lightened(0.03 * ((sx + sy) % 2)))
	_emit_building(Vector3(at.x, base_y, at.y), yaw)

	# The sell point: a marker at the door, in world space, that the player's sell action finds.
	var door_local := Vector3(0, 1.2, d * 0.5 + 2.0).rotated(Vector3.UP, yaw)
	var marker := Node3D.new()
	marker.position = Vector3(at.x, base_y, at.y) + door_local
	marker.set_meta("town", String(town["name"]))
	marker.add_to_group("glue_market")
	add_child(marker)


# ---- building primitives ----------------------------------------------------

## Four walls `height` above the base, carried FOUNDATION_SINK below it so a sloped footprint
## shows no gap. Same construction as FarmBuilder's structures.
func _walls(width: float, height: float, depth: float, color: Color) -> void:
	var wy := (height - FOUNDATION_SINK) * 0.5
	var wh := height + FOUNDATION_SINK
	var hx := width * 0.5
	var hz := depth * 0.5
	_kit.box(Vector3(-hx, wy, 0), Vector3(0.3, wh, depth), color.darkened(0.06))
	_kit.box(Vector3(hx, wy, 0), Vector3(0.3, wh, depth), color.darkened(0.06))
	_kit.box(Vector3(0, wy, -hz), Vector3(width, wh, 0.3), color)
	_kit.box(Vector3(0, wy, hz), Vector3(width, wh, 0.3), color)


## A gable roof over a width×depth building whose walls top out at `wall_h`, ridge running along
## X, rising `rise` above the eaves, with a small overhang.
func _gable_roof(width: float, depth: float, wall_h: float, rise: float, color: Color) -> void:
	_gable_at(Vector3.ZERO, width, depth, rise, color, wall_h)


func _gable_at(base: Vector3, width: float, depth: float, rise: float, color: Color, wall_h := 4.0) -> void:
	var hx := width * 0.5 + 0.4
	var hz := depth * 0.5 + 0.4
	var ey := base.y + wall_h
	var ridge := ey + rise
	var l0 := base + Vector3(-hx, ey, -hz)
	var l1 := base + Vector3(hx, ey, -hz)
	var r0 := base + Vector3(-hx, ey, hz)
	var r1 := base + Vector3(hx, ey, hz)
	var rk0 := base + Vector3(-hx, ridge, 0)
	var rk1 := base + Vector3(hx, ridge, 0)
	_kit.quad(l0, l1, rk1, rk0, color)                        # -Z pitch
	_kit.quad(rk0, rk1, r1, r0, color.lightened(0.04))        # +Z pitch
	_kit.tri(l0, rk0, r0, color.darkened(0.1))                # -X gable end
	_kit.tri(l1, r1, rk1, color.darkened(0.1))                # +X gable end
	_kit.box(base + Vector3(0, ridge, 0), Vector3(width + 0.8, 0.25, 0.25), color.darkened(0.2))  # ridge


## A door and two windows on the +Z face, at height `wall_h` context.
func _facade(width: float, depth: float, wall_h: float) -> void:
	_facade_door(depth, 0.0)
	for sx in [-1.0, 1.0]:
		_kit.box(Vector3(sx * width * 0.26, 2.2, depth * 0.5 - 0.02), Vector3(1.1, 1.1, 0.16), WINDOW)
		_kit.box(Vector3(sx * width * 0.26, 2.2, depth * 0.5 + 0.06), Vector3(1.3, 1.3, 0.08), TIMBER)  # frame


func _facade_door(depth: float, offset_x: float) -> void:
	_kit.box(Vector3(offset_x, 1.1, depth * 0.5 - 0.02), Vector3(1.2, 2.2, 0.18), DOOR)
	_kit.box(Vector3(offset_x, 1.15, depth * 0.5 + 0.07), Vector3(1.45, 2.45, 0.08), TIMBER)  # frame


func _emit_building(origin: Vector3, yaw: float) -> void:
	var mesh := _kit.commit()
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	mi.position = origin
	mi.rotation.y = yaw
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	var shape := mesh.create_trimesh_shape()
	if shape != null:
		var body := StaticBody3D.new()
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		mi.add_child(body)


func _angle_diff(a: float, b: float) -> float:
	var d := fmod(a - b + PI, TAU) - PI
	return d
