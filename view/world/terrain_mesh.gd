class_name TerrainMesh
extends RefCounted

## Builds the landscape as one continuous surface.
##
## The obvious way to draw a hex map is one solid tile mesh per hex. It is also
## wrong: every tile boundary becomes a vertical wall, and the map reads as a
## tray of blocks rather than as terrain. Civilization VI does not do that — it
## renders a single joined mesh where the vertices shared between neighbouring
## hexes are welded together, so height and colour blend across the seam and
## adjacent mountains form one continuous ridge.
##
## That is what this builds:
##
##   - Every hex contributes six triangles: centre to each pair of corners.
##   - A corner is shared by three hexes. Its height and colour are the average
##     of those three, accumulated in a first pass and welded by quantised
##     position. This is the whole trick — the averaging is what turns a step
##     into a slope.
##   - The centre vertex keeps the tile's own height and colour, so each hex
##     still reads as itself while its edges melt into its neighbours.
##
## Water is a separate flat surface, because a shoreline should be a hard edge
## where land rises out of it, not a blend into blue.

## Quantisation used to weld shared corners. Corner positions are computed
## independently by each of the three hexes that touch them and will not be
## bit-identical, so they are snapped to a grid before being used as a key.
const WELD := 1000.0

## Fraction of the tile that stays flat at its own height and colour.
##
## Catlike Coding settles on 0.75 and this did too, on the reasoning that a 4X
## player is choosing tiles and each one must read as itself. Comparing the
## result against Civilization VI shows that reasoning is simply wrong: Civ 6's
## ground has *no* visible hexagons anywhere. It is one continuous rolling
## landscape, and tile identity comes from what stands on the land — props,
## improvements, borders, an optional grid overlay — never from the land's own
## colour. A 0.72 core is what made this map read as coloured paper hexagons.
##
## Small enough now that the flat part is a hint of a plateau rather than a
## facet, with the rest a smooth ramp to the shared rim.
const CORE_RADIUS := 0.26

## Rings of geometry between the flat core and the rim.
##
## The blend has to be *geometry*, not just vertex colours across one big
## triangle: with a single ring the shading gradient is linear over the whole
## half-tile and the eye reads the change of slope at the ring boundary as an
## edge. Three rings is where the banding stops being visible.
const RIM_RINGS := 3

## How far out the tile keeps its own colour before crossing to its neighbour's.
## Higher than CORE_RADIUS on purpose — see _fan_vertex.
const COLOR_HOLD := 0.52

# -------------------------------------------------------------------------
# Perturbation
# -------------------------------------------------------------------------
#
# The single technique that stops a hex map from looking like a hex map, taken
# from part 4 of Catlike Coding's series.
#
# Every mesh vertex is displaced horizontally by a noise function *of its own
# position*. Because the displacement depends only on where the vertex is, two
# hexes computing the same shared corner independently arrive at the same
# displaced point — so the mesh never cracks, but no hexagon is a regular
# hexagon any more. Coastlines stop being staircases, tile boundaries stop being
# straight lines, and the grid dissolves into terrain while every cell stays
# exactly where the simulation thinks it is.
#
# Note this is applied to *presentation only*. Hex.to_world remains the
# authoritative position, and anything placed on the map — props, units, cities,
# rivers, borders — must run through perturb() as well or it will float away
# from the ground it is standing on.

## Horizontal displacement in world units.
##
## Catlike displaces by up to 0.4 of the hex radius, reading a Perlin *texture*
## whose samples cover the full 0..1 range and are remapped to -1..1. Simplex
## noise does not behave like that — FastNoiseLite rarely returns anything near
## +/-1 — and the 3D sampling used for wrapping (see _field) is tamer again than
## the 2D it replaced. So the constant does not mean what it says: read it as
## whatever lands the *measured* mean displacement near 0.3 of a hex radius,
## which is what this value does. Change it by measuring, not by reasoning.
const PERTURB_STRENGTH := 0.92

## Noise frequency, tuned against the width of the blend ring.
##
## This is the constraint Catlike means by "points that lie close together tend
## to stick together, instead of being distorted in opposite directions". The
## ring between the flat core and the tile rim is only (1 - CORE_RADIUS) wide.
## If the noise varies appreciably over that distance, the outer ring can be
## pushed past the inner one, the ring triangles invert, and the mesh tears into
## dark slivers. A wavelength of several hex radii keeps each tile's vertices
## moving as a group while the coastline still wanders over larger scales.
const PERTURB_FREQUENCY := 0.18

## World width of one lap around a wrapping map, or 0 for a map with edges.
##
## The perturbation has to be periodic over this distance or the map cannot be
## welded shut. The wrap copies are the same mesh translated by one lap, so a
## corner shared across the seam is sampled at x and at x + span; if those give
## different displacements the two sides pull apart and the sea shows a pale
## crack down the join. Set by HexWorld when it builds a map.
static var wrap_span := 0.0

static var _noise_x: FastNoiseLite = null
static var _noise_z: FastNoiseLite = null


static func _ensure_noise() -> void:
	if _noise_x != null:
		return
	_noise_x = FastNoiseLite.new()
	_noise_x.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_x.frequency = PERTURB_FREQUENCY
	_noise_x.seed = 1
	_noise_z = FastNoiseLite.new()
	_noise_z.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_z.frequency = PERTURB_FREQUENCY
	# A different seed, or X and Z would displace identically and every vertex
	# would slide along the same diagonal.
	_noise_z.seed = 7331


## Sample the displacement field, wrapping in x when the map does.
##
## On a wrapping map the field is read off a cylinder rather than off a plane:
## x becomes an angle and the noise is sampled in 3D on a circle of matching
## circumference. That is periodic *and* continuous — folding x with a modulo
## would also make the two seam edges agree, but it puts a hard discontinuity
## through the middle of the seam column, which tears those tiles instead.
static func _field(noise: FastNoiseLite, x: float, z: float) -> float:
	if wrap_span <= 0.0:
		return noise.get_noise_2d(x, z)
	var radius := wrap_span / TAU
	var angle := x / radius
	return noise.get_noise_3d(cos(angle) * radius, sin(angle) * radius, z)


## Displace a point horizontally by noise sampled at that point. Height is left
## alone: terrain height is decided by the tile, and nudging it here would open
## gaps between the ground and anything standing on it.
static func perturb(position: Vector3) -> Vector3:
	_ensure_noise()
	return Vector3(
		position.x + _field(_noise_x, position.x, position.z) * PERTURB_STRENGTH,
		position.y,
		position.z + _field(_noise_z, position.x, position.z) * PERTURB_STRENGTH,
	)


## Where a tile centre actually ends up on screen, for placing anything that
## stands on it.
static func tile_center(coord: Vector2i, size: float) -> Vector3:
	var centre := Hex.to_world(coord, size)
	return perturb(centre)

# The rim blend used to be a tunable (EDGE_BLEND, last set to 0.74). It cannot
# be: a rim vertex is shared with the neighbouring tile, so anything short of a
# full average gives the two tiles different colours at the same point and draws
# a seam along every edge. Dissolving the tile boundary is the goal, not a side
# effect — see CORE_RADIUS.

## Height in world units for each terrain, before per-tile elevation noise.
##
## Mountains stand well above everything else and are impassable, so they are
## allowed to dominate. Their jagged detail and snow line come from the rock
## section below; this is just the base height the crags are built on.
const TERRAIN_HEIGHT := {
	&"ocean": -0.50, &"coast": -0.20, &"lake": -0.16,
	&"grassland": 0.0, &"plains": 0.02, &"desert": 0.0,
	&"tundra": 0.04, &"snow": 0.08, &"mountains": 2.30,
}

const HILL_HEIGHT := 0.62

## How much of the generator's own elevation field shows through.
##
## Was 0.42, which over a tile two units across is a gradient of a few degrees —
## invisible. Civ 6's ground visibly rolls: you can see valleys and highland
## from the shading alone, before any mountain is involved. Now that the mesh is
## smooth rather than stepped there is nothing to fight, so the field can drive
## real relief.
const ELEVATION_RELIEF := 0.95

## Base colours. These replace the kit's texture atlas entirely for the ground —
## a continuous mesh cannot use per-tile textured blocks — so they carry the
## whole look of the landscape.
## Measured against Civ 6, not picked by eye. Averaged over a land region its
## ground comes out around RGB (141,134,85) — red marginally *above* green and
## blue far below both, a warm khaki world. These were green-dominant, which is
## most of why the two look nothing alike side by side.
const TERRAIN_COLOR := {
	# Grassland stays green. The measured *average* of a Civ 6 land region is
	# warm khaki, but that average is a map with tan plains and pale desert in
	# it — not a map where everything is khaki. Matching the average by making
	# every biome yellow produced one flat mustard continent, which is further
	# from the reference than the green one was.
	&"grassland": Color(0.40, 0.53, 0.19),
	&"plains": Color(0.68, 0.58, 0.27),
	&"desert": Color(0.84, 0.74, 0.47),
	&"tundra": Color(0.56, 0.53, 0.41),
	&"snow": Color(0.76, 0.79, 0.83),
	&"mountains": Color(0.46, 0.44, 0.43),
	&"coast": Color(0.16, 0.42, 0.58),
	&"ocean": Color(0.06, 0.18, 0.36),
	&"lake": Color(0.17, 0.44, 0.62),
}

## Features recolour the ground under them, the way Civ 6 darkens a Woods tile
## rather than only planting trees on it.
const FEATURE_COLOR := {
	&"woods": Color(0.24, 0.35, 0.13),
	&"rainforest": Color(0.20, 0.33, 0.13),
	&"marsh": Color(0.38, 0.44, 0.26),
	&"floodplains": Color(0.58, 0.64, 0.28),
	&"oasis": Color(0.50, 0.64, 0.30),
	&"ice": Color(0.82, 0.87, 0.92),
}

const MOUNTAIN_COLOR_TOP := Color(0.94, 0.95, 0.97)

# -------------------------------------------------------------------------
# Per-tile tint
# -------------------------------------------------------------------------
#
# The shader already breaks the ground up with world-space noise, but that noise
# ignores tile boundaries by design — which means a run of grassland is one
# continuous green field with the *same* base under all of it. Civ 6's ground is
# not that uniform: neighbouring tiles of the same terrain are visibly different
# shades, which is what stops a continent reading as one sheet of coloured
# paper. So each tile also gets its own small, permanent shift in hue,
# saturation and value, keyed to its coordinate.
#
# The shift is applied before the corner averaging in build_land, so adjacent
# tiles still blend into each other at their shared edge rather than butting up
# as two flat patches.

## Hue rotation, in turns. Small: enough to separate a yellow-green tile from a
## blue-green one, not enough to make grassland look like tundra.
const TILE_HUE := 0.014
const TILE_SATURATION := 0.08
const TILE_VALUE := 0.07


## A stable -1..1 offset per tile. Two coordinate hashes rather than one so the
## hue and value shifts are independent — a single value applied to both makes
## every light tile also the same hue, which reads as a pattern.
static func _tile_jitter(coord: Vector2i, salt: int) -> float:
	var h := hash(Vector3i(coord.x, coord.y, salt * 7919))
	return float(h % 2000) / 1000.0 - 1.0

# -------------------------------------------------------------------------
# Rock
# -------------------------------------------------------------------------
#
# Mountains are part of the terrain mesh, not models standing on it. That is
# what lets neighbouring mountain hexes merge: they share corner vertices, so
# the corner-averaging in build_land welds their ridgelines into one unbroken
# wall the way Civ 6's does. A per-tile prop cannot do that — every peak stays
# its own island no matter how it is sculpted.
#
# The jag terms below are what keep it from being a smooth dome. Each is a
# deterministic offset per (tile, vertex), so the crags are stable across
# rebuilds and two tiles always agree about the corner they share.

## Extra height on the peak vertex, in world units.
const PEAK_JAG := 0.95
## How far the peak slides off the tile centre, in tile radii.
const PEAK_DRIFT := 0.34

## Ridges, not noise.
##
## Randomising every spoke independently gives a crumpled paper bag: lots of
## detail, no structure, and nothing that reads as a mountain. Real peaks have a
## handful of major ridges running from the summit to the base with gullies
## between them, so the variation around the tile is a low-frequency wave —
## three ridges per peak, phase-shifted per tile so no two are alike — with a
## little noise on top for texture.
const RIDGE_COUNT := 3.0
const RIDGE_DEPTH := 0.62
const CORE_JAG := 0.16

## How steeply the flanks fall away. Below 1 the profile is convex — a steep
## shoulder under a sharp summit, rather than the smooth dome a linear ramp
## gives.
const PEAK_FALLOFF := 0.62

## Grey-brown cliff, snow only on the caps.
##
## The spread between these is what separates a mountain from a lump. An earlier
## ramp ran from mid-grey to near-white over a band most vertices never reached,
## so every peak came out the same flat grey — polystyrene, not rock. The dark
## end is now genuinely dark and the snow line sits low enough that real peaks
## actually cross it.
const ROCK_LOW := Color(0.33, 0.30, 0.29)
const ROCK_MID := Color(0.47, 0.45, 0.45)
const ROCK_HIGH := Color(0.64, 0.63, 0.64)
const ROCK_SNOW := Color(0.93, 0.95, 0.97)

## The rock ramp, expressed relative to the mountain's own base height.
##
## Absolute world heights were tried twice and mis-set twice: the band that
## mountain geometry occupies moves whenever TERRAIN_HEIGHT or ELEVATION_RELIEF
## changes, so a ramp pinned to fixed Y values silently drifts until every peak
## is uniformly black or uniformly white. Measuring from the tile's own base
## makes it immune to that. SKIRT is how far below the base the ramp starts —
## roughly where a mountain meets the land around it.
const ROCK_SKIRT := 1.30

## Per-vertex lightening on rock, so two faces of the same crag at the same
## height are not the same grey and the facets read as facets.
const ROCK_FACET := 0.13


## Cliff colour at a world height. Used for every vertex of a rocky tile, so the
## snow line follows the actual geometry rather than the tile it belongs to —
## which is why a ridge's snow runs continuously across tile boundaries.
static func rock_color_at(y: float, base: float, facet: float = 0.0) -> Color:
	var low := base - ROCK_SKIRT
	var high := base + PEAK_JAG
	var t := clampf((y - low) / maxf(high - low, 0.001), 0.0, 1.0)
	var colour: Color
	if t < 0.42:
		colour = ROCK_LOW.lerp(ROCK_MID, t / 0.42)
	elif t < 0.68:
		colour = ROCK_MID.lerp(ROCK_HIGH, (t - 0.42) / 0.26)
	else:
		colour = ROCK_HIGH.lerp(ROCK_SNOW, (t - 0.68) / 0.32)
	if facet == 0.0:
		return colour
	var scale := 1.0 + facet * ROCK_FACET
	return Color(
		clampf(colour.r * scale, 0.0, 1.0),
		clampf(colour.g * scale, 0.0, 1.0),
		clampf(colour.b * scale, 0.0, 1.0),
		colour.a
	)


static func is_rocky(tile: Tile) -> bool:
	return tile.terrain_id == &"mountains"


## Deterministic per-vertex offset in -1..1. Hashing the coordinate with the
## vertex index means the same tile produces the same crag every rebuild, and
## adjacent tiles never disagree about a shared corner.
static func _jag(coord: Vector2i, index: int) -> float:
	var h := hash(Vector3i(coord.x, coord.y, index))
	return float(h % 2000) / 1000.0 - 1.0

## Pack ice on polar water. Opaque, and slightly blue so it separates from the
## snow terrain it usually borders.
const ICE_COLOR := Color(0.78, 0.84, 0.90, 1.0)


## Height of a tile's centre vertex.
static func height_of(tile: Tile) -> float:
	var height: float = TERRAIN_HEIGHT.get(tile.terrain_id, 0.0)
	if tile.is_hills:
		height += HILL_HEIGHT
	# Elevation is 0 at the waterline and 1 at the highest land. Only land takes
	# relief from it; lifting the sea floor would poke it through the water
	# plane. This used to remap as (elevation - 0.5), which assumed a 0..1 field
	# the generator was not actually producing, and put most coastal land
	# *below* sea level — so the sea rendered standing above the beach.
	if not tile.is_water():
		height += maxf(tile.elevation, 0.0) * ELEVATION_RELIEF
	return height


static func color_of(tile: Tile) -> Color:
	var colour: Color = TERRAIN_COLOR.get(tile.terrain_id, Color(0.5, 0.5, 0.5))
	if tile.feature_id != &"" and FEATURE_COLOR.has(tile.feature_id):
		colour = colour.lerp(FEATURE_COLOR[tile.feature_id], 0.75)
	# Snow-cap the peaks so a mountain range has a silhouette rather than being
	# one flat grey mass.
	if tile.terrain_id == &"mountains":
		colour = colour.lerp(MOUNTAIN_COLOR_TOP, 0.18)
	elif tile.is_hills:
		# Hill crowns catch the light, which is how a hill reads as raised ground
		# from directly above — where its height alone tells you nothing.
		colour = colour.lightened(0.07)
	return _tinted(colour, tile.coord)


## Give a tile its own shade of its terrain. Ice and open water are left alone:
## a mottled ice shelf reads as damage, and the sea is drawn by its own shader.
static func _tinted(colour: Color, coord: Vector2i) -> Color:
	var hue_shift := _tile_jitter(coord, 1) * TILE_HUE
	var saturation_shift := _tile_jitter(coord, 2) * TILE_SATURATION
	var value_shift := _tile_jitter(coord, 3) * TILE_VALUE
	return Color.from_hsv(
		fposmod(colour.h + hue_shift, 1.0),
		clampf(colour.s * (1.0 + saturation_shift), 0.0, 1.0),
		clampf(colour.v * (1.0 + value_shift), 0.0, 1.0),
		colour.a
	)


# -------------------------------------------------------------------------
# Building
# -------------------------------------------------------------------------

## The six corner offsets of a flat-top hex, at the given circumradius.
static func corner_offsets(size: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in 6:
		var angle := PI / 3.0 * i
		out.append(Vector3(cos(angle), 0.0, sin(angle)) * size)
	return out


## Corners are keyed by rounded world position so the three tiles sharing one
## can find each other.
##
## Note this deliberately does NOT fold X across the wrap seam. Folding only X
## is wrong — one lap of the map displaces a tile in Z as well, by half a map
## width, so corners folded on X alone weld to partners half a continent away
## in Z and tear the mesh open. The seam copies are exact translations of the
## same geometry, so they already line up; the two sides simply do not share
## averaged corner data, which is invisible next to the tear that folding
## caused.
static func _key(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x * WELD), roundi(position.z * WELD))


## The welded corner heights from the last build_land, keyed the same way.
##
## Anything that has to sit exactly on a tile *edge* — rivers above all — needs
## the height the ground actually ended up at there, which is the average over
## the three tiles meeting at that corner. Using the tile centre's height
## instead leaves a river buried inside a mountain whose crags rise well above
## its base.
static var corner_heights: Dictionary = {}


## Ground height at a corner, or `fallback` if that corner is not on the map.
static func corner_height_at(position: Vector3, fallback: float) -> float:
	var value: Variant = corner_heights.get(_key(position))
	return float(value) if value != null else fallback


## Build the land surface for every non-water tile.
static func build_land(map: MapModel, size: float) -> ArrayMesh:
	var offsets := corner_offsets(size)

	# Pass one: accumulate every hex's contribution to the points it shares with
	# its neighbours — the six corners, shared with two other tiles each, and the
	# six edge midpoints, shared with one.
	#
	# The midpoints are what make the surface genuinely smooth. Without them a
	# tile edge is a straight chord between two corner heights while the tile on
	# the other side draws the same chord, so the two agree — but the *slope*
	# changes across it, and a crease in the shading is exactly as legible as a
	# drawn line. Six more shared points turn each crease into a curve.
	var corner_height: Dictionary = {}
	var corner_color: Dictionary = {}
	var corner_count: Dictionary = {}

	for tile: Tile in map.all_tiles():
		var centre := Hex.to_world(tile.coord, size)
		var height := height_of(tile)
		var colour := color_of(tile)
		for i in 6:
			var j := (i + 1) % 6
			for point: Vector3 in [
				centre + offsets[i],
				centre + (offsets[i] + offsets[j]) * 0.5,
			]:
				var key := _key(point)
				corner_height[key] = float(corner_height.get(key, 0.0)) + height
				corner_color[key] = (corner_color.get(key, Color(0, 0, 0, 0)) as Color) + colour
				corner_count[key] = int(corner_count.get(key, 0)) + 1

	corner_heights.clear()
	for key: Variant in corner_height:
		corner_heights[key] = float(corner_height[key]) / float(corner_count[key])

	# Pass two: each tile is a small flat core and a fan of rings out to the rim.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted := 0

	for tile: Tile in map.all_tiles():
		if tile.is_water():
			continue
		var centre := Hex.to_world(tile.coord, size)
		var height := height_of(tile)
		var colour := color_of(tile)
		var rocky := is_rocky(tile)

		# Mountains are jagged rather than flat-topped, and their peak is offset
		# from the tile centre so a range does not read as a row of identical
		# cones sitting on their own hexes.
		var apex := height
		var apex_offset := Vector3.ZERO
		if rocky:
			apex += _jag(tile.coord, 0) * PEAK_JAG
			apex_offset = Vector3(_jag(tile.coord, 7), 0.0, _jag(tile.coord, 8)) * PEAK_DRIFT * size

		var base_height := height
		var middle := Vector3(centre.x + apex_offset.x, apex, centre.z + apex_offset.z)
		var middle_color := colour if not rocky else rock_color_at(apex, height, _jag(tile.coord, 9))

		# The twelve rim directions, alternating corner and edge midpoint. Their
		# heights and colours are the shared averages, so two tiles always agree
		# about the boundary between them.
		var rim: Array = []
		for i in 6:
			var j := (i + 1) % 6
			for point: Vector3 in [
				centre + offsets[i],
				centre + (offsets[i] + offsets[j]) * 0.5,
			]:
				var key := _key(point)
				var rim_y := float(corner_height[key]) / float(corner_count[key])
				var rim_color: Color = (
					rock_color_at(rim_y, height) if rocky
					else (corner_color[key] as Color) / float(corner_count[key])
				)
				rim.append([point - centre, rim_y, rim_color])

		for k in 12:
			var a: Array = rim[k]
			var b: Array = rim[(k + 1) % 12]

			# Core: a twelve-sided sliver at the tile's own height and colour.
			var core_a := _fan_vertex(
				centre, a, middle.y, middle_color, tile, k, CORE_RADIUS, rocky, base_height
			)
			var core_b := _fan_vertex(
				centre, b, middle.y, middle_color, tile, k + 1, CORE_RADIUS, rocky, base_height
			)
			_tri(surface, middle, core_a[0], core_b[0], middle_color, core_a[1], core_b[1])
			emitted += 1

			# Rings out to the rim.
			var inner_a := core_a
			var inner_b := core_b
			for ring in RIM_RINGS:
				var t := CORE_RADIUS + (1.0 - CORE_RADIUS) * float(ring + 1) / float(RIM_RINGS)
				var outer_a := _fan_vertex(
					centre, a, middle.y, middle_color, tile, k, t, rocky, base_height
				)
				var outer_b := _fan_vertex(
					centre, b, middle.y, middle_color, tile, k + 1, t, rocky, base_height
				)
				_tri(surface, inner_a[0], outer_a[0], outer_b[0], inner_a[1], outer_a[1], outer_b[1])
				_tri(surface, inner_a[0], outer_b[0], inner_b[0], inner_a[1], outer_b[1], inner_b[1])
				emitted += 2
				inner_a = outer_a
				inner_b = outer_b

	if emitted == 0:
		return null

	surface.generate_normals()
	surface.set_material(ground_material())
	return surface.commit()


## One vertex along the ray from a tile centre to one of its rim points.
##
## `t` runs 0 at the centre to 1 at the rim. Height and colour ease from the
## tile's own values to the shared rim values, so the surface is continuous
## across every edge and has no flat facet to give the hexagon away.
static func _fan_vertex(
	centre: Vector3, rim: Array, core_y: float, core_color: Color,
	tile: Tile, spoke: int, t: float, rocky: bool, base: float
) -> Array:
	var direction: Vector3 = rim[0]
	var rim_y: float = rim[1]
	var rim_color: Color = rim[2]

	# Height and colour ease on different curves, and they have to.
	#
	# Landform wants to be smooth from the tile centre outward, or hills read as
	# plateaus. Colour does not: blended over the same distance every biome
	# bleeds into its neighbours until the map is watercolour and no tile is
	# recognisably grassland or desert any more. So colour holds the tile's own
	# value across most of the tile and then crosses quickly — soft seam, intact
	# interior, which is what Civ 6's ground actually does.
	var blend := smoothstep(CORE_RADIUS, 1.0, t)
	var colour_blend := smoothstep(COLOR_HOLD, 1.0, t)
	var y := lerpf(core_y, rim_y, blend)

	# Crags are interior-only: a rim point is shared with the neighbour, and a
	# per-tile offset applied there would pull the two apart into a crack.
	if rocky:
		var steep := pow(blend, PEAK_FALLOFF)
		y = lerpf(core_y, rim_y, steep)
		var angle := atan2(direction.z, direction.x)
		var phase := _jag(tile.coord, 5) * PI
		var ridge := cos(angle * RIDGE_COUNT + phase)
		var fade := steep * (1.0 - steep) * 4.0
		y -= (1.0 - ridge) * 0.5 * RIDGE_DEPTH * fade
		y += _jag(tile.coord, spoke + 11) * CORE_JAG * (1.0 - steep)

	var point := centre + direction * t
	point.y = y
	return [
		point,
		rock_color_at(y, base, _jag(tile.coord, spoke + 11)) if rocky
		else core_color.lerp(rim_color, colour_blend),
	]


## The ground material: vertex colour for the biome, world-space noise on top to
## break up the tiles. Built once and shared.
static var _ground_material: ShaderMaterial = null

## World-space frequencies for the ground shader's three noise octaves. Held
## here rather than read back off the material, because a ShaderMaterial only
## reports parameters that have been set on it — the shader's own defaults are
## not readable — and because they have to be snapped to the wrap period before
## the first sample is ever taken.
const GROUND_COARSE_SCALE := 0.035
const GROUND_MEDIUM_SCALE := 0.13
const GROUND_FINE_SCALE := 0.34

static var _ground_material_span := -1.0


static func ground_material() -> ShaderMaterial:
	# Rebuilt when the map's lap width changes: the scales below are snapped to
	# it, so a cached material from a differently sized map would seam.
	if _ground_material != null and is_equal_approx(_ground_material_span, wrap_span):
		return _ground_material
	_ground_material_span = wrap_span

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 4

	var texture := NoiseTexture2D.new()
	texture.noise = noise
	texture.width = 512
	texture.height = 512
	texture.seamless = true
	texture.generate_mipmaps = true

	_ground_material = ShaderMaterial.new()
	_ground_material.shader = load("res://view/world/terrain.gdshader")
	_ground_material.set_shader_parameter("noise_texture", texture)
	# The shader samples this texture in world space, so on a wrapping map the
	# two sides of the seam only match if the texture repeats a whole number of
	# times per lap. Snapping each scale to the nearest one that does costs a
	# fraction of a percent of frequency and makes the colour seam vanish.
	_ground_material.set_shader_parameter("coarse_scale", _seam_safe_scale(GROUND_COARSE_SCALE))
	_ground_material.set_shader_parameter("medium_scale", _seam_safe_scale(GROUND_MEDIUM_SCALE))
	_ground_material.set_shader_parameter("fine_scale", _seam_safe_scale(GROUND_FINE_SCALE))
	return _ground_material


## Round a world-space texture scale so one lap spans an exact number of tiles
## of the noise texture. Left alone on maps that do not wrap.
static func _seam_safe_scale(scale: float) -> float:
	if wrap_span <= 0.0 or scale <= 0.0:
		return scale
	return maxf(roundf(wrap_span * scale), 1.0) / wrap_span


## Emit one upward-facing triangle. Winding is a -> b -> c; with +Y up and
## Godot's counter-clockwise front faces, that order is what points the normal
## at the sky rather than at the sea floor.
##
## Every vertex is perturbed on the way out. Doing it here rather than at each
## call site guarantees no vertex escapes un-displaced, which would tear the
## mesh — and because perturb() depends only on the position handed to it, the
## three tiles meeting at a corner still land on exactly the same point.
static func _tri(
	surface: SurfaceTool,
	a: Vector3, b: Vector3, c: Vector3,
	a_color: Color, b_color: Color, c_color: Color
) -> void:
	surface.set_color(a_color)
	surface.add_vertex(perturb(a))
	surface.set_color(b_color)
	surface.add_vertex(perturb(b))
	surface.set_color(c_color)
	surface.add_vertex(perturb(c))


## How many tiles of open water separate each water tile from the nearest land.
##
## This is the one thing the water shader cannot work out for itself, so it is
## measured here and baked into the mesh — Catlike's series encodes the same
## quantity into shore-water UVs. A plain breadth-first search from every coastal
## tile outward is enough; the map is small and this runs once per generation.
static func shore_distances(map: MapModel) -> Dictionary:
	var distance: Dictionary = {}
	var frontier: Array[Vector2i] = []

	for tile: Tile in map.all_tiles():
		if not tile.is_water():
			continue
		for neighbour: Tile in map.neighbors(tile.coord):
			if neighbour.is_land():
				distance[tile.coord] = 0.0
				frontier.append(tile.coord)
				break

	var head := 0
	while head < frontier.size():
		var coord := frontier[head]
		head += 1
		var next := float(distance[coord]) + 1.0
		for neighbour: Tile in map.neighbors(coord):
			if not neighbour.is_water() or distance.has(neighbour.coord):
				continue
			distance[neighbour.coord] = next
			frontier.append(neighbour.coord)

	return distance


## Water beyond this many tiles from land is open sea and needs no shore detail.
const OPEN_SEA_DISTANCE := 6.0


## A single sheet at sea level covering every water tile.
##
## Drawn flat rather than blended into the land, so the coastline stays a
## definite edge — but each vertex carries its distance from shore in UV.y, and
## its world position in UV2, which is what lets the shader break foam against
## the coast and animate the surface without the pattern swimming as the camera
## moves.
static func build_water(map: MapModel, size: float) -> ArrayMesh:
	var offsets := corner_offsets(size)
	var distance := shore_distances(map)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted := 0

	# Shore distance has to vary *within* a tile, not just between tiles. Held
	# constant per tile there is no gradient for the surf to break against and
	# the whole first ring of water renders as solid foam. So corners are
	# averaged over the tiles that touch them, with land counted as -1: a corner
	# against the coast lands below zero, the tile centre sits at its own
	# distance, and each shore tile gets a ramp from beach to open water.
	var corner_shore: Dictionary = {}
	var corner_total: Dictionary = {}
	# Corner heights are averaged for the same reason, and for a second one that
	# matters more: coast, deep ocean and pack ice each sit at a different level,
	# so giving every vertex of a tile that tile's own level opens a vertical
	# crack at each boundary between them. You see the sky through it — a web of
	# pale hairlines tracing hex edges across open water, which is exactly what
	# it looked like. Averaging welds the surface shut while leaving each tile
	# centre at its own height, so the shallows still step up visibly.
	var corner_level: Dictionary = {}
	var corner_level_total: Dictionary = {}
	for tile: Tile in map.all_tiles():
		var value := -1.0
		if tile.is_water():
			value = minf(float(distance.get(tile.coord, OPEN_SEA_DISTANCE)), OPEN_SEA_DISTANCE)
		var tile_centre := Hex.to_world(tile.coord, size)
		for i in 6:
			var key := _key(tile_centre + offsets[i])
			corner_shore[key] = float(corner_shore.get(key, 0.0)) + value
			corner_total[key] = int(corner_total.get(key, 0)) + 1
			if tile.is_water():
				corner_level[key] = float(corner_level.get(key, 0.0)) + _water_level(tile)
				corner_level_total[key] = int(corner_level_total.get(key, 0)) + 1

	for tile: Tile in map.all_tiles():
		if not tile.is_water():
			continue
		var centre := Hex.to_world(tile.coord, size)
		# Coast sits fractionally higher than deep ocean, which combined with the
		# colour difference gives the shallows a visible band.
		# Land at the waterline sits at exactly 0, so the sea has to be clearly
		# under that or the beach has no visible step at all.
		var level := _water_level(tile)
		var colour := Color.WHITE
		var shore: float = minf(float(distance.get(tile.coord, OPEN_SEA_DISTANCE)), OPEN_SEA_DISTANCE)

		# Ice is a feature sitting on polar water. Without this it is skipped
		# entirely — the land pass ignores water tiles — and the poles render as
		# open ocean. It floats just above the surface, is opaque, and is pushed
		# out past the foam range so no surf breaks through it.
		var is_ice := tile.feature_id == &"ice"
		if is_ice:
			colour = ICE_COLOR
			shore = OPEN_SEA_DISTANCE

		for i in 6:
			var j := (i + 1) % 6
			var a := centre + offsets[i]
			var b := centre + offsets[j]
			var shore_a := shore if is_ice else _corner_shore(corner_shore, corner_total, a)
			var shore_b := shore if is_ice else _corner_shore(corner_shore, corner_total, b)
			var level_a := _corner_shore(corner_level, corner_level_total, a)
			var level_b := _corner_shore(corner_level, corner_level_total, b)
			_water_tri(surface,
				Vector3(centre.x, level, centre.z),
				Vector3(a.x, level_a, a.z),
				Vector3(b.x, level_b, b.z),
				colour, shore, shore_a, shore_b, is_ice)
			emitted += 1

	if emitted == 0:
		return null

	surface.generate_normals()
	return surface.commit()


## Surface height of a water tile. Coast sits fractionally higher than deep
## ocean, and pack ice floats above both, so the shallows and the floes read as
## raised even before their colour is taken into account. Land at the waterline
## sits at exactly 0, so the sea has to be clearly under that or the beach has
## no visible step at all.
static func _water_level(tile: Tile) -> float:
	if tile.feature_id == &"ice":
		return -0.07
	return -0.12 if tile.terrain_id != &"ocean" else -0.17


static func _corner_shore(sums: Dictionary, counts: Dictionary, position: Vector3) -> float:
	var key := _key(position)
	var total: Variant = counts.get(key)
	if total == null or int(total) == 0:
		return 0.0
	return float(sums[key]) / float(total)


## Like _tri, but carrying the per-vertex shore distance and world position the
## water shader needs. Vertex colour is reused as an ice mask: the shader leaves
## any vertex flagged as ice alone rather than running surf over it.
static func _water_tri(
	surface: SurfaceTool,
	a: Vector3, b: Vector3, c: Vector3,
	colour: Color, shore_a: float, shore_b: float, shore_c: float, is_ice: bool
) -> void:
	var vertices: Array[Vector3] = [a, b, c]
	var shores: Array[float] = [shore_a, shore_b, shore_c]
	for i in 3:
		var placed := perturb(vertices[i])
		surface.set_color(Color(colour.r, colour.g, colour.b, 1.0 if is_ice else 0.0))
		surface.set_uv(Vector2(0.0, shores[i]))
		surface.set_uv2(Vector2(placed.x, placed.z))
		surface.add_vertex(placed)


## Surface height at a tile centre, for placing props and units.
static func surface_height(tile: Tile) -> float:
	if tile == null:
		return 0.0
	if tile.is_water():
		return -0.12
	return height_of(tile)
