@tool
extends EditorPlugin
## dmgkit is a plain script/shader library — every piece is a global class_name (DmgTerrain,
## DmgDither, DmgMeshKit, DmgTerrainTextures) that is usable whether or not the plugin is "enabled".
## This EditorPlugin exists only so the kit shows up under Project > Plugins; it has no editor hooks.
func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	pass
