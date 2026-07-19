extends RefCounted
class_name DmgMeshKit
## Procedural flat-shaded mesh primitives, factored out so the glue factory can build its
## machines the same way FarmBuilder builds its barns: one merged, vertex-coloured mesh per
## object, so each is a single draw call and a trimesh body falls straight out of it.
##
## This is the same toolkit FarmBuilder grew inline; it lives here so a second builder does
## not re-invent it. Flat-shaded on purpose — one normal per face, no shared vertices — which
## is what keeps everything faceted and on-style under the palette.
##
## Usage: begin(), lay down primitives, commit() -> ArrayMesh. Colours are baked per vertex;
## the caller draws with a material that reads vertex colour as albedo.

var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()


func begin() -> void:
	_verts.clear()
	_normals.clear()
	_colors.clear()


func commit() -> ArrayMesh:
	if _verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ---- imported-model helpers -------------------------------------------------
# Shared by anything that drops a .glb into the world (the factory's grinder, the player's
# wand): drag it into the house pixel style, and scale/ground it without knowing its authored
# scale or pivot — the assets ship at arbitrary sizes.

## Nearest filtering + double-sided on every material, since a .glb arrives with the
## importer's defaults, not this game's. The same pass FarmBuilder runs on the animals.
static func force_pixel_look(node: Node) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		for surface in mesh_instance.mesh.get_surface_count():
			for mat in [mesh_instance.mesh.surface_get_material(surface),
					mesh_instance.get_surface_override_material(surface)]:
				var base := mat as BaseMaterial3D
				if base != null:
					base.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
					base.cull_mode = BaseMaterial3D.CULL_DISABLED
	for child in node.get_children():
		force_pixel_look(child)


## Combined mesh bounds of a node and its descendants, in the node's own space.
static func local_aabb(root: Node) -> AABB:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	var has := false
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	for mi in meshes:
		if mi.mesh == null:
			continue
		var xform := _relative_xform(mi, root)
		var local := mi.mesh.get_aabb()
		for i in 8:
			var corner := local.position + Vector3(
					local.size.x if (i & 1) else 0.0,
					local.size.y if (i & 2) else 0.0,
					local.size.z if (i & 4) else 0.0)
			var world := xform * corner
			if not has:
				lo = world
				hi = world
				has = true
			else:
				lo = Vector3(minf(lo.x, world.x), minf(lo.y, world.y), minf(lo.z, world.z))
				hi = Vector3(maxf(hi.x, world.x), maxf(hi.y, world.y), maxf(hi.z, world.z))
	if not has:
		return AABB()
	return AABB(lo, hi - lo)


## Scales `node` to `target_height` and positions it so its base rests on `ground_y` and its
## footprint is centred over (cx, cz) — regardless of the model's pivot. This is what makes
## dropping an unknown-scale .glb in a known spot safe.
static func place_upright(node: Node3D, cx: float, cz: float, ground_y: float,
		target_height: float) -> void:
	var a := local_aabb(node)
	var s := 1.0
	if a.size.y > 0.0001:
		s = target_height / a.size.y
	node.scale = Vector3.ONE * s
	node.position = Vector3(
			cx - s * (a.position.x + a.size.x * 0.5),
			ground_y - s * a.position.y,
			cz - s * (a.position.z + a.size.z * 0.5))


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null:
		out.append(mesh_instance)
	for child in node.get_children():
		_collect_meshes(child, out)


static func _relative_xform(node: Node, root: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var walk := node
	while walk != null and walk != root:
		var spatial := walk as Node3D
		if spatial != null:
			xform = spatial.transform * xform
		walk = walk.get_parent()
	return xform


func tri(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for v in [a, b, c]:
		_verts.append(v)
		_normals.append(normal)
		_colors.append(color)


func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	tri(a, b, c, color)
	tri(a, c, d, color)


## Axis-aligned box centred on `at`, `size` full extents. Faces shaded a little differently
## so a plain box still reads as a solid rather than a silhouette.
func box(at: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	var p := [
		at + Vector3(-h.x, -h.y, -h.z), at + Vector3(h.x, -h.y, -h.z),
		at + Vector3(h.x, -h.y, h.z), at + Vector3(-h.x, -h.y, h.z),
		at + Vector3(-h.x, h.y, -h.z), at + Vector3(h.x, h.y, -h.z),
		at + Vector3(h.x, h.y, h.z), at + Vector3(-h.x, h.y, h.z),
	]
	quad(p[4], p[5], p[6], p[7], color)                       # top
	quad(p[1], p[0], p[3], p[2], color.darkened(0.35))        # bottom
	quad(p[0], p[1], p[5], p[4], color.darkened(0.12))        # -Z
	quad(p[2], p[3], p[7], p[6], color.darkened(0.12))        # +Z
	quad(p[3], p[0], p[4], p[7], color.darkened(0.22))        # -X
	quad(p[1], p[2], p[6], p[5], color.darkened(0.22))        # +X


func cylinder(at: Vector3, radius: float, height: float, sides: int, color: Color) -> void:
	var half := height * 0.5
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0) * radius, 0, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		var shade := color.darkened(0.18 * (0.5 + 0.5 * sin(a0)))
		quad(at + p0 + Vector3(0, -half, 0), at + p1 + Vector3(0, -half, 0),
				at + p1 + Vector3(0, half, 0), at + p0 + Vector3(0, half, 0), shade)
		tri(at + Vector3(0, half, 0), at + p0 + Vector3(0, half, 0),
				at + p1 + Vector3(0, half, 0), color)
		tri(at + Vector3(0, -half, 0), at + p1 + Vector3(0, -half, 0),
				at + p0 + Vector3(0, -half, 0), color.darkened(0.3))


func cone(base: Vector3, radius: float, height: float, sides: int, color: Color) -> void:
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		tri(base + Vector3(0, height, 0),
				base + Vector3(cos(a0) * radius, 0, sin(a0) * radius),
				base + Vector3(cos(a1) * radius, 0, sin(a1) * radius),
				color.darkened(0.14 * (0.5 + 0.5 * sin(a0))))


## A square-section beam between two points — a pipe, a rail, a strut.
func rail(from: Vector3, to: Vector3, thickness: float, color: Color) -> void:
	var along := to - from
	if along.length() < 0.001:
		return
	var dir := along.normalized()
	var side := dir.cross(Vector3.UP)
	if side.length() < 0.001:
		# Vertical run: cross(UP) collapses, so pick any horizontal axis for the section.
		side = Vector3.RIGHT
	side = side.normalized() * thickness
	var up := dir.cross(side).normalized() * thickness
	var p := [from - side - up, from + side - up, from + side + up, from - side + up,
			to - side - up, to + side - up, to + side + up, to - side + up]
	quad(p[3], p[2], p[6], p[7], color)                  # top
	quad(p[1], p[0], p[4], p[5], color.darkened(0.3))    # bottom
	quad(p[0], p[3], p[7], p[4], color.darkened(0.15))
	quad(p[2], p[1], p[5], p[6], color.darkened(0.15))
	quad(p[4], p[5], p[6], p[7], color.darkened(0.2))    # far cap
	quad(p[1], p[2], p[3], p[0], color.darkened(0.2))    # near cap


## A round pipe (capped cylinder) running between two arbitrary points — the workhorse for
## detail: handrails, conduit, steam lines, tree limbs, axles. `sides` sets how round it reads.
func pipe(from: Vector3, to: Vector3, radius: float, sides: int, color: Color) -> void:
	var along := to - from
	var length := along.length()
	if length < 0.0001:
		return
	var dir := along / length
	# Any two axes perpendicular to the run give the tube's cross-section ring.
	var side := dir.cross(Vector3.UP)
	if side.length() < 0.001:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := dir.cross(side).normalized()
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var r0 := (side * cos(a0) + up * sin(a0)) * radius
		var r1 := (side * cos(a1) + up * sin(a1)) * radius
		var shade := color.darkened(0.16 * (0.5 + 0.5 * sin(a0)))
		quad(from + r0, from + r1, to + r1, to + r0, shade)
		tri(to, to + r0, to + r1, color)
		tri(from, from + r1, from + r0, color.darkened(0.28))


## A faceted sphere (UV sphere) — domes, valve balls, tree canopies, headlamps. Low `rings`
## and `segments` keep it on-style and cheap.
func sphere(center: Vector3, radius: float, rings: int, segments: int, color: Color) -> void:
	for r in rings:
		var v0 := PI * float(r) / float(rings)
		var v1 := PI * float(r + 1) / float(rings)
		var y0 := cos(v0)
		var y1 := cos(v1)
		var s0 := sin(v0)
		var s1 := sin(v1)
		for s in segments:
			var u0 := TAU * float(s) / float(segments)
			var u1 := TAU * float(s + 1) / float(segments)
			var p00 := center + Vector3(cos(u0) * s0, y0, sin(u0) * s0) * radius
			var p10 := center + Vector3(cos(u1) * s0, y0, sin(u1) * s0) * radius
			var p01 := center + Vector3(cos(u0) * s1, y1, sin(u0) * s1) * radius
			var p11 := center + Vector3(cos(u1) * s1, y1, sin(u1) * s1) * radius
			var shade := color.darkened(0.14 * (0.5 - 0.5 * y0))
			if r == 0:
				tri(p00, p11, p01, shade)
			elif r == rings - 1:
				tri(p00, p10, p01, shade)
			else:
				quad(p00, p10, p11, p01, shade)


## A torus ring — machine rims, flywheels, tyres, pipe flanges. `ring_radius` is the big
## circle, `tube_radius` the cross-section, in the XZ plane with `axis` up by default.
func torus(center: Vector3, ring_radius: float, tube_radius: float, ring_sides: int,
		tube_sides: int, color: Color) -> void:
	for i in ring_sides:
		var a0 := TAU * float(i) / float(ring_sides)
		var a1 := TAU * float(i + 1) / float(ring_sides)
		var c0 := Vector3(cos(a0), 0, sin(a0))
		var c1 := Vector3(cos(a1), 0, sin(a1))
		for j in tube_sides:
			var b0 := TAU * float(j) / float(tube_sides)
			var b1 := TAU * float(j + 1) / float(tube_sides)
			var p00 := center + c0 * (ring_radius + cos(b0) * tube_radius) + Vector3.UP * sin(b0) * tube_radius
			var p01 := center + c0 * (ring_radius + cos(b1) * tube_radius) + Vector3.UP * sin(b1) * tube_radius
			var p10 := center + c1 * (ring_radius + cos(b0) * tube_radius) + Vector3.UP * sin(b0) * tube_radius
			var p11 := center + c1 * (ring_radius + cos(b1) * tube_radius) + Vector3.UP * sin(b1) * tube_radius
			quad(p00, p10, p11, p01, color.darkened(0.14 * (0.5 + 0.5 * sin(b0))))


## A flat disk facing +Y (or -Y), for tank tops, gauge faces, wheel hubs.
func disk(center: Vector3, radius: float, sides: int, color: Color, up := true) -> void:
	for i in sides:
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var p0 := center + Vector3(cos(a0) * radius, 0, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		if up:
			tri(center, p0, p1, color)
		else:
			tri(center, p1, p0, color.darkened(0.2))


## A ramp wedge: a `width`(x) by `length`(z) slab whose top rises from `y_low` at -Z to
## `y_high` at +Z, resting on a base at `y_base`. Centred on (cx, cz). Used for the doorway
## threshold so the player can walk up onto the factory floor.
func ramp(cx: float, cz: float, width: float, length: float, y_base: float,
		y_low: float, y_high: float, color: Color) -> void:
	var hw := width * 0.5
	var hl := length * 0.5
	var a := Vector3(cx - hw, y_low, cz - hl)
	var b := Vector3(cx + hw, y_low, cz - hl)
	var c := Vector3(cx + hw, y_high, cz + hl)
	var d := Vector3(cx - hw, y_high, cz + hl)
	quad(a, b, c, d, color)                                                    # sloped top
	quad(Vector3(cx - hw, y_base, cz - hl), Vector3(cx - hw, y_base, cz + hl),
			Vector3(cx + hw, y_base, cz + hl), Vector3(cx + hw, y_base, cz - hl),
			color.darkened(0.35))                                             # bottom
	# Side triangles (the wedge profile) and the two ends.
	tri(a, Vector3(cx - hw, y_base, cz - hl), Vector3(cx - hw, y_base, cz + hl), color.darkened(0.22))
	tri(a, Vector3(cx - hw, y_base, cz + hl), d, color.darkened(0.22))
	tri(b, c, Vector3(cx + hw, y_base, cz + hl), color.darkened(0.22))
	tri(b, Vector3(cx + hw, y_base, cz + hl), Vector3(cx + hw, y_base, cz - hl), color.darkened(0.22))
	quad(a, Vector3(cx - hw, y_base, cz - hl), Vector3(cx + hw, y_base, cz - hl), b, color.darkened(0.12))  # low end
	quad(d, c, Vector3(cx + hw, y_base, cz + hl), Vector3(cx - hw, y_base, cz + hl), color.darkened(0.12))  # high end
