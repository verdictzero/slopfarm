extends RefCounted
class_name FarmPlan
## Loads the farm plan authored by tools/farm_designer.py.
##
## The plan is what the terrain used to guess. Ground cover inside the plan's square is
## authored; outside it, and on any cell left unpainted, the terrain's own slope rules
## still apply — the plan overrides the BASE ground, it does not switch the rules off.
## So a road laid across a slope still picks up dirt and rock the way the hill does.
##
## The zone map reaches the shader as a runtime-generated R8 ImageTexture. Runtime, not
## a committed PNG: an imported texture would be VRAM-compressed and mipmapped by
## default, which silently corrupts data (the same trap lut_512.png has to defeat with a
## hand-written .import). Nothing here touches the import pipeline.

## Must match tools/farm_plan.py.
const VERSION := 1
const CELL_SIZE := 2.0
const GRID := 256
const EXTENT := CELL_SIZE * GRID     # 512 world units
const ORIGIN := -EXTENT / 2.0        # -256

## Ground name -> Texture2DArray layer. Order must match GROUND_TYPES in farm_plan.py.
const GROUND_LAYER := {
	"pasture": TerrainTextures.LAYER_PASTURE,
	"dirt": TerrainTextures.LAYER_DIRT,
	"road": TerrainTextures.LAYER_ROAD,
	"crop": TerrainTextures.LAYER_CROP,
}

var zones: Array[Dictionary] = []
var structures: Array[Dictionary] = []
## GRID*GRID zone ids, row-major. Zone 0 means "not authored".
var cells: PackedByteArray = PackedByteArray()
var source_path: String = ""
var loaded: bool = false
var error: String = ""


## Reads the plan, or returns an empty-but-valid plan whose zone map is all "natural".
## A missing or broken plan must never stop the game booting — the terrain's own rules
## are a complete fallback.
static func load_from(path: String) -> FarmPlan:
	var plan := FarmPlan.new()
	plan.source_path = path
	plan.cells.resize(GRID * GRID)
	plan.cells.fill(0)

	if not FileAccess.file_exists(path):
		plan.error = "no plan at %s — using bare terrain" % path
		return plan

	var text := FileAccess.get_file_as_string(path)
	var doc = JSON.parse_string(text)
	if typeof(doc) != TYPE_DICTIONARY:
		plan.error = "%s is not valid JSON" % path
		return plan
	if doc.get("version") != VERSION:
		plan.error = "plan version %s, expected %d" % [doc.get("version"), VERSION]
		return plan
	var world: Dictionary = doc.get("world", {})
	if int(world.get("grid", 0)) != GRID or absf(float(world.get("cell_size", 0.0)) - CELL_SIZE) > 0.001:
		# Mismatched geometry would silently misplace every zone, so refuse it loudly
		# rather than render a farm that is subtly in the wrong place.
		plan.error = "plan grid %s@%s does not match this build (%d@%s)" % [
			world.get("grid"), world.get("cell_size"), GRID, CELL_SIZE]
		return plan

	for z: Dictionary in doc.get("zones", []):
		plan.zones.append(z)
	for s: Dictionary in doc.get("structures", []):
		plan.structures.append(s)

	var rows: Array = doc.get("cells", [])
	if rows.size() != GRID:
		plan.error = "plan has %d rows, expected %d" % [rows.size(), GRID]
		return plan
	for r in GRID:
		if not plan._decode_row(String(rows[r]), r):
			return plan

	plan.loaded = true
	return plan


func _decode_row(text: String, row: int) -> bool:
	var at := 0
	for part in text.split(",", false):
		var bits := part.split(":")
		if bits.size() != 2:
			error = "row %d: malformed run %s" % [row, part]
			return false
		var value := int(bits[0])
		var run := int(bits[1])
		if at + run > GRID:
			error = "row %d overruns the grid" % row
			return false
		for i in run:
			cells[row * GRID + at + i] = value
		at += run
	if at != GRID:
		error = "row %d decodes to %d cells, expected %d" % [row, at, GRID]
		return false
	return true


func zone_of(zone_id: int) -> Dictionary:
	for z in zones:
		if int(z.get("id", -1)) == zone_id:
			return z
	return {}


## Zone id at a world position, or 0 outside the plan's square.
func zone_at(world_x: float, world_z: float) -> int:
	var col := int(floor((world_x - ORIGIN) / CELL_SIZE))
	var row := int(floor((world_z - ORIGIN) / CELL_SIZE))
	if col < 0 or col >= GRID or row < 0 or row >= GRID:
		return 0
	return cells[row * GRID + col]


static func cell_to_world(col: int, row: int) -> Vector2:
	return Vector2(ORIGIN + (col + 0.5) * CELL_SIZE, ORIGIN + (row + 0.5) * CELL_SIZE)


## Bakes cells -> ground layer into an R8 texture for the terrain shader.
##
## The texture stores the LAYER, not the zone id: the shader only ever needs to know
## which ground to draw, and resolving zone -> ground here means retyping a zone in the
## designer does not need the shader to know anything about zones.
func ground_layer_texture() -> ImageTexture:
	var lut := PackedByteArray()
	lut.resize(256)
	lut.fill(TerrainTextures.LAYER_PASTURE)
	for z in zones:
		var ground := String(z.get("ground", "pasture"))
		lut[int(z.get("id", 0))] = GROUND_LAYER.get(ground, TerrainTextures.LAYER_PASTURE)

	var data := PackedByteArray()
	data.resize(GRID * GRID)
	for i in GRID * GRID:
		data[i] = lut[cells[i]]
	var image := Image.create_from_data(GRID, GRID, false, Image.FORMAT_R8, data)
	return ImageTexture.create_from_image(image)


## Cells belonging to a zone, as world positions. Used to scatter its contents.
func zone_cells(zone_id: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for row in GRID:
		for col in GRID:
			if cells[row * GRID + col] == zone_id:
				out.append(cell_to_world(col, row))
	return out


## Cell edges where `zone_id` meets anything else — where a fence would stand.
## Returns [from, to] world-space pairs, one per exposed cell edge.
func zone_border_edges(zone_id: int) -> Array[PackedVector2Array]:
	var edges: Array[PackedVector2Array] = []
	var half := CELL_SIZE * 0.5
	for row in GRID:
		for col in GRID:
			if cells[row * GRID + col] != zone_id:
				continue
			var c := cell_to_world(col, row)
			# A neighbour outside the grid counts as different, so a zone painted to the
			# plan's edge is still fenced along it.
			var west := col > 0 and cells[row * GRID + col - 1] == zone_id
			var east := col < GRID - 1 and cells[row * GRID + col + 1] == zone_id
			var north := row > 0 and cells[(row - 1) * GRID + col] == zone_id
			var south := row < GRID - 1 and cells[(row + 1) * GRID + col] == zone_id
			if not west:
				edges.append(PackedVector2Array([c + Vector2(-half, -half), c + Vector2(-half, half)]))
			if not east:
				edges.append(PackedVector2Array([c + Vector2(half, -half), c + Vector2(half, half)]))
			if not north:
				edges.append(PackedVector2Array([c + Vector2(-half, -half), c + Vector2(half, -half)]))
			if not south:
				edges.append(PackedVector2Array([c + Vector2(-half, half), c + Vector2(half, half)]))
	return edges
