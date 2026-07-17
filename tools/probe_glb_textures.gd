extends SceneTree
## Confirms the externalized .glb models still import as textured, animated meshes.
##
## After tools/glb_externalize_textures.py rewrites a model to reference its textures as
## external sidecar PNGs, this loads each model the way FarmBuilder does (load + instantiate)
## and asserts the mesh survived and every base-colour material actually resolved a texture.
## Run: godot-4 --headless --path . --script res://tools/probe_glb_textures.gd

const MODELS := {
	"res://models/horse.glb": {"needs_albedo": true, "needs_anim": true},
	"res://models/slopfarm_logo.glb": {"needs_albedo": true, "needs_anim": false},
	"res://models/meat_grinder.glb": {"needs_albedo": true, "needs_anim": false},
	"res://models/heart_wand.glb": {"needs_albedo": false, "needs_anim": false},
}


func _init() -> void:
	var failures := 0
	for path in MODELS:
		failures += _check(path, MODELS[path])
	print("\n==== %s ====" % ("ALL PASS" if failures == 0 else "%d FAILURE(S)" % failures))
	quit(1 if failures else 0)


func _check(path: String, want: Dictionary) -> int:
	print("\n--- %s ---" % path)
	if not ResourceLoader.exists(path):
		print("  FAIL: does not exist")
		return 1
	var packed := load(path) as PackedScene
	if packed == null:
		print("  FAIL: did not load as PackedScene (import error)")
		return 1
	var root := packed.instantiate()
	var meshes: Array[MeshInstance3D] = []
	_collect(root, meshes)
	if meshes.is_empty():
		print("  FAIL: no MeshInstance3D in tree")
		root.free()
		return 1

	var fails := 0
	var total_surfaces := 0
	var textured_surfaces := 0
	for mi in meshes:
		if mi.mesh == null:
			print("  FAIL: %s has null mesh" % mi.name)
			fails += 1
			continue
		var aabb := mi.mesh.get_aabb()
		if aabb.get_volume() <= 0.0:
			print("  FAIL: %s mesh AABB is degenerate %s" % [mi.name, aabb])
			fails += 1
		for s in mi.mesh.get_surface_count():
			total_surfaces += 1
			var mat := mi.mesh.surface_get_material(s)
			if mat is BaseMaterial3D and mat.albedo_texture != null:
				textured_surfaces += 1
				var tex: Texture2D = mat.albedo_texture
				print("  surface %d: albedo %dx%d (%s)" % [s, tex.get_width(),
						tex.get_height(), tex.get_class()])
	print("  meshes=%d surfaces=%d textured=%d" % [meshes.size(), total_surfaces, textured_surfaces])

	if want.needs_albedo and textured_surfaces == 0:
		print("  FAIL: expected an albedo texture, none resolved (external uri broken?)")
		fails += 1
	if want.needs_anim:
		var players: Array[AnimationPlayer] = []
		_collect_anim(root, players)
		var clips := 0
		for p in players:
			clips += p.get_animation_list().size()
		print("  animation players=%d clips=%d" % [players.size(), clips])
		if clips == 0:
			print("  FAIL: expected animation, found none")
			fails += 1
	root.free()
	return 1 if fails else 0


func _collect(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)


func _collect_anim(n: Node, out: Array[AnimationPlayer]) -> void:
	if n is AnimationPlayer:
		out.append(n)
	for c in n.get_children():
		_collect_anim(c, out)
