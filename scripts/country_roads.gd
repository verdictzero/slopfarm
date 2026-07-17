extends Node3D
class_name CountryRoads
## Lays the winding country roads that run from the crossroads by the farm out to the distant
## towns. Each road is a smooth ribbon of gravel that follows the lie of the land — it drapes
## over the terrain rather than cutting into it, so, like every other structure in this world,
## it never has to touch the pure height field.
##
## The route is the coarse winding control line from WorldSites, smoothed with a Catmull-Rom
## pass into a flowing curve and then sampled cross-section by cross-section: at each step the
## ribbon's two edges are dropped onto the ground at their own height, so the road banks and
## rolls with the hills instead of floating flat across them. It carries no collision — the
## player walks and the truck drives on the terrain underneath; the ribbon is just the surface
## you can see you are meant to follow.

## Small lift above the ground so the ribbon never z-fights the terrain it lies on.
const LIFT := 0.14
## Fine samples per coarse control segment. More = smoother curve.
const SUBDIVS := 10
## Ribbon points per built mesh chunk, so a long road keeps several bounding boxes for culling.
const CHUNK_POINTS := 22

const GRAVEL := Color(0.44, 0.40, 0.34)
const GRAVEL_DK := Color(0.37, 0.34, 0.29)
const SHOULDER := Color(0.40, 0.36, 0.27)

var _terrain: TerrainManager
var _mat: StandardMaterial3D
var _kit := MeshKit.new()


## Builds every road. Call once from main after the terrain exists.
func setup(terrain: TerrainManager) -> void:
	_terrain = terrain
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 1.0
	_mat.metallic = 0.0
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	for i in WorldSites.TOWNS.size():
		_build_road(WorldSites.road_control_points(i))


func _build_road(control: Array) -> void:
	var fine := _smooth(control)
	if fine.size() < 2:
		return
	# Build the ribbon in chunks so a 500-unit road is several culled meshes, not one.
	var start := 0
	while start < fine.size() - 1:
		var stop := mini(start + CHUNK_POINTS, fine.size())
		_build_ribbon(fine, start, stop)
		start = stop - 1     # overlap one point so chunks share an edge with no gap


func _build_ribbon(fine: Array, from_i: int, to_i: int) -> void:
	_kit.begin()
	var half := WorldSites.ROAD_WIDTH * 0.5
	var shoulder := half + 1.2
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var prev_sl := Vector3.ZERO
	var prev_sr := Vector3.ZERO
	var have_prev := false
	for k in range(from_i, to_i):
		var c: Vector2 = fine[k]
		var tangent := _tangent(fine, k)
		var perp := Vector2(-tangent.y, tangent.x)
		var lc := c + perp * half
		var rc := c - perp * half
		var ls := c + perp * shoulder
		var rs := c - perp * shoulder
		var l := Vector3(lc.x, _terrain.height_at(lc.x, lc.y) + LIFT, lc.y)
		var r := Vector3(rc.x, _terrain.height_at(rc.x, rc.y) + LIFT, rc.y)
		var sl := Vector3(ls.x, _terrain.height_at(ls.x, ls.y) + LIFT * 0.5, ls.y)
		var sr := Vector3(rs.x, _terrain.height_at(rs.x, rs.y) + LIFT * 0.5, rs.y)
		if have_prev:
			var tone := GRAVEL if (k % 2 == 0) else GRAVEL_DK
			_kit.quad(prev_l, prev_r, r, l, tone)                     # road surface
			_kit.quad(prev_sl, prev_l, l, sl, SHOULDER)               # left shoulder
			_kit.quad(prev_r, prev_sr, sr, r, SHOULDER)               # right shoulder
		prev_l = l
		prev_r = r
		prev_sl = sl
		prev_sr = sr
		have_prev = true
	var mesh := _kit.commit()
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Catmull-Rom through the control points into a fine flowing polyline (XZ).
func _smooth(control: Array) -> Array:
	if control.size() < 2:
		return control.duplicate()
	var out: Array = []
	for i in control.size() - 1:
		var p0: Vector2 = control[maxi(i - 1, 0)]
		var p1: Vector2 = control[i]
		var p2: Vector2 = control[i + 1]
		var p3: Vector2 = control[mini(i + 2, control.size() - 1)]
		for s in SUBDIVS:
			var t := float(s) / float(SUBDIVS)
			out.append(_catmull(p0, p1, p2, p3, t))
	out.append(control[control.size() - 1])
	return out


func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1)
			+ (-p0 + p2) * t
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


## Unit tangent of the fine polyline at index k, from its neighbours.
func _tangent(fine: Array, k: int) -> Vector2:
	var a: Vector2 = fine[maxi(k - 1, 0)]
	var b: Vector2 = fine[mini(k + 1, fine.size() - 1)]
	var d := b - a
	if d.length() < 0.0001:
		return Vector2.RIGHT
	return d.normalized()
