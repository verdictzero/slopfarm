extends RefCounted
class_name WorldSites
## The geography of the wider world beyond the farm: where the towns sit and how the winding
## country roads reach them. One shared source of truth so the road builder, the town builder,
## the tree scatter (which keeps groves off the roads and out of the towns) and the truck spawn
## all agree on the same map without each inventing its own.
##
## Everything is deterministic and pure — positions are fixed constants and the winding of each
## road is a fixed sum of sines — so the world is the same every run and any system can ask for
## the same answer without coordinating.

## The crossroads hub just east of the farm, near the glue works, where every road begins.
const HUB := Vector2(150.0, 30.0)

## The towns. `pos` is the town centre in world XZ; `market` marks the ones that buy glue.
## Placed 480–560 units out on three different bearings, so from the farm they read as hazy
## silhouettes on the horizon in three directions.
const TOWNS := [
	{"name": "Tallowmarket", "pos": Vector2(470.0, 190.0), "market": true, "seed": 11},
	{"name": "Millbrook", "pos": Vector2(-250.0, 470.0), "market": true, "seed": 29},
	{"name": "Hobbs End", "pos": Vector2(-500.0, -230.0), "market": false, "seed": 53},
]

## Road width in world units (the drivable ribbon).
const ROAD_WIDTH := 7.0
## Half-width kept clear of trees/grass either side of a road centreline.
const ROAD_CLEARANCE := 8.0
## Radius around a town centre kept clear of wild trees (the town owns its own ground).
const TOWN_CLEAR_RADIUS := 46.0


## Coarse control points of the winding road from the hub to town `i`, in world XZ. The road
## builder smooths these into a curve. The wander is a tapered sum of sines keyed to the town's
## seed, so each road curves differently but always straightens out to meet its endpoints.
static func road_control_points(i: int) -> Array:
	var town: Dictionary = TOWNS[i]
	var a := HUB
	var b: Vector2 = town["pos"]
	var seed_val := float(town["seed"])
	var along := b - a
	var length := along.length()
	var dir := along / length
	var perp := Vector2(-dir.y, dir.x)
	var segments := 7
	var points: Array = []
	for k in segments + 1:
		var t := float(k) / float(segments)
		# Taper the wander to zero at both ends so the road actually reaches the hub and town.
		var taper := sin(t * PI)
		var wander := (sin(t * 6.28318 * 1.3 + seed_val)
				+ 0.5 * sin(t * 6.28318 * 2.7 + seed_val * 1.7)) * 0.5
		var offset := wander * taper * length * 0.16
		points.append(a.lerp(b, t) + perp * offset)
	return points


## Nearest distance from world XZ point `p` to any road centreline, for clearance tests. Uses
## the coarse control polyline (good enough for keeping trees off the verge).
static func distance_to_any_road(p: Vector2) -> float:
	var best := INF
	for i in TOWNS.size():
		var pts := road_control_points(i)
		for k in pts.size() - 1:
			best = minf(best, _dist_to_segment(p, pts[k], pts[k + 1]))
	return best


## Nearest distance from `p` to any town centre.
static func distance_to_any_town(p: Vector2) -> float:
	var best := INF
	for town in TOWNS:
		best = minf(best, p.distance_to(town["pos"]))
	return best


static func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
