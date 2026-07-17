extends SceneTree
## Audits every 3D material the game actually renders, for texture filter and culling.
## Run:  godot-4 --headless --path . --script res://tools/probe_filter.gd
##
## Filtering on a 3D material is a MATERIAL property, not an import setting — a .glb's
## materials are built by the importer with engine defaults, so they never appear in a
## .import file and are easy to miss when auditing the look. This is the audit.
const FILTERS := ["NEAREST", "LINEAR", "NEAREST_MIPMAP", "LINEAR_MIPMAP",
	"NEAREST_MIPMAP_ANISO", "LINEAR_MIPMAP_ANISO"]
const CULL := ["BACK", "FRONT", "DISABLED"]

func _init() -> void:
	var builder := FarmBuilder.new()
	builder._ready()
	print("FarmBuilder._material (structures, fences, gates): filter=%s cull=%s" % [
		FILTERS[builder._material.texture_filter], CULL[builder._material.cull_mode]])
	for m: QuadMesh in builder._crop_meshes:
		var mat := m.material as BaseMaterial3D
		print("crop billboard: filter=%s cull=%s" % [FILTERS[mat.texture_filter], CULL[mat.cull_mode]])
		break
	for m: QuadMesh in builder._grass_meshes:
		var mat := m.material as BaseMaterial3D
		print("grass billboard: filter=%s cull=%s" % [FILTERS[mat.texture_filter], CULL[mat.cull_mode]])
		break
	for species in ["horse"]:
		var node := (load("res://models/%s.glb" % species) as PackedScene).instantiate()
		builder._force_pixel_look(node)
		_walk(node, species)
	quit()

func _walk(node: Node, label: String) -> void:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s) as BaseMaterial3D
			if m != null:
				print("%s: filter=%s cull=%s" % [label, FILTERS[m.texture_filter], CULL[m.cull_mode]])
	for child in node.get_children():
		_walk(child, label)
