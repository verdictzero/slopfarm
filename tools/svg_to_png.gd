extends SceneTree
## Rasterises an SVG to a PNG with Godot's own renderer (ThorVG), so a PNG icon comes out matching
## exactly how the engine draws the vector. This is how icon.png (the Android launcher icon) is
## kept in step with icon.svg — rerun it after editing the icon.
##
##   godot --headless --path . --script tools/svg_to_png.gd -- res://icon.svg res://icon.png 1.0
##
## Args after `--`: source svg, destination png, scale (svg is 512x512, so scale 1.0 = 512px).
## Defaults to icon.svg -> icon.png at scale 1.0 when no arguments are given.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var src: String = args[0] if args.size() > 0 else "res://icon.svg"
	var dst: String = args[1] if args.size() > 1 else "res://icon.png"
	var scale: float = args[2].to_float() if args.size() > 2 else 1.0

	var svg := FileAccess.get_file_as_string(src)
	if svg.is_empty():
		push_error("svg_to_png: could not read %s" % src)
		quit(1)
		return

	var img := Image.new()
	var err := img.load_svg_from_string(svg, scale)
	if err != OK:
		push_error("svg_to_png: raster failed for %s (%d)" % [src, err])
		quit(1)
		return

	err = img.save_png(dst)
	if err != OK:
		push_error("svg_to_png: could not write %s (%d)" % [dst, err])
		quit(1)
		return

	print("svg_to_png: wrote %s  %dx%d" % [dst, img.get_width(), img.get_height()])
	quit(0)
