class_name Hex
extends RefCounted

## Flat-top hexagon grid maths on axial coordinates, following the standard
## Red Blob Games formulation. Axial (q, r) is stored in a Vector2i so tiles can
## be Dictionary keys; the third cube coordinate is always s = -q - r.
##
## Flat-top is the orientation Civ 6 uses, and the one the original Python
## prototype in legacy_prototype/ used, so its hex_to_pixel/pixel_to_hex/
## hex_round functions port across directly.
##
## Direction order is fixed and used everywhere adjacency matters (district
## adjacency, Zone of Control, river edges), so DIRECTIONS[i] and the river-edge
## bitmask bit i always refer to the same neighbour.

const DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0),    # 0 E
	Vector2i(1, -1),   # 1 NE
	Vector2i(0, -1),   # 2 NW
	Vector2i(-1, 0),   # 3 W
	Vector2i(-1, 1),   # 4 SW
	Vector2i(0, 1),    # 5 SE
]

const DIRECTION_COUNT := 6

## Opposite direction index, for resolving a river edge from either of the two
## tiles that share it.
const OPPOSITE: Array[int] = [3, 4, 5, 0, 1, 2]

const SQRT3 := 1.7320508075688772


static func neighbor(coord: Vector2i, direction: int) -> Vector2i:
	return coord + DIRECTIONS[direction]


static func neighbors(coord: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	out.resize(DIRECTION_COUNT)
	for i in DIRECTION_COUNT:
		out[i] = coord + DIRECTIONS[i]
	return out


static func to_cube(coord: Vector2i) -> Vector3i:
	return Vector3i(coord.x, coord.y, -coord.x - coord.y)


static func distance(a: Vector2i, b: Vector2i) -> int:
	var a_s := -a.x - a.y
	var b_s := -b.x - b.y
	return int((absi(a.x - b.x) + absi(a.y - b.y) + absi(a_s - b_s)) / 2.0)


## All tiles within `radius` rings of `center`, including the center itself.
## Used for city work radius (radius 3 in Civ 6), unit sight, and loyalty range.
static func within_radius(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dq in range(-radius, radius + 1):
		var lo := maxi(-radius, -dq - radius)
		var hi := mini(radius, -dq + radius)
		for dr in range(lo, hi + 1):
			out.append(center + Vector2i(dq, dr))
	return out


## Just the tiles exactly `radius` rings out.
static func ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	if radius <= 0:
		return [center] as Array[Vector2i]
	var out: Array[Vector2i] = []
	var coord := center + DIRECTIONS[4] * radius
	for direction in DIRECTION_COUNT:
		for _step in radius:
			out.append(coord)
			coord = neighbor(coord, direction)
	return out


## World-space position of a tile centre, for the 3D view. `size` is the
## circumradius (centre to corner). Y is left to the caller so terrain elevation
## can be applied on top.
static func to_world(coord: Vector2i, size: float) -> Vector3:
	var x := size * 1.5 * coord.x
	var z := size * SQRT3 * (float(coord.y) + coord.x * 0.5)
	return Vector3(x, 0.0, z)


static func from_world(pos: Vector3, size: float) -> Vector2i:
	var q := (2.0 / 3.0) * pos.x / size
	var r := (-1.0 / 3.0 * pos.x + SQRT3 / 3.0 * pos.z) / size
	return round_axial(q, r)


## Round fractional axial coordinates to the nearest real tile by rounding in
## cube space and correcting whichever component drifted furthest.
static func round_axial(fq: float, fr: float) -> Vector2i:
	var fs := -fq - fr
	var q := roundi(fq)
	var r := roundi(fr)
	var s := roundi(fs)

	var q_diff := absf(q - fq)
	var r_diff := absf(r - fr)
	var s_diff := absf(s - fs)

	if q_diff > r_diff and q_diff > s_diff:
		q = -r - s
	elif r_diff > s_diff:
		r = -q - s
	return Vector2i(q, r)


## Linear interpolation between two tiles, used for line-of-sight tracing on
## city ranged strikes.
static func line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var n := distance(a, b)
	if n == 0:
		return [a] as Array[Vector2i]
	var out: Array[Vector2i] = []
	# Nudge off exact edge cases so the line resolves consistently either way.
	var step := 1.0 / float(n)
	for i in range(n + 1):
		var t := step * i
		var fq := lerpf(float(a.x), float(b.x) + 1e-6, t)
		var fr := lerpf(float(a.y), float(b.y) + 1e-6, t)
		out.append(round_axial(fq, fr))
	return out
