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

## Fraction of the tile that stays flat at its own height and colour. The rest
## is the blend ring out to the shared corners. Catlike Coding's hex map series
## settles on 0.75 for the same split; much below that and the flat core gets
## too small to read as a tile.
const CORE_RADIUS := 0.72

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
## +/-1, and in practice this map sees around 0.4 of the nominal range. So the
## constant is scaled up to land in the same place: measured displacement comes
## out near 0.3 of a hex radius, not the 0.7 the number suggests.
const PERTURB_STRENGTH := 0.72

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


## Displace a point horizontally by noise sampled at that point. Height is left
## alone: terrain height is decided by the tile, and nudging it here would open
## gaps between the ground and anything standing on it.
static func perturb(position: Vector3) -> Vector3:
	_ensure_noise()
	return Vector3(
		position.x + _noise_x.get_noise_2d(position.x, position.z) * PERTURB_STRENGTH,
		position.y,
		position.z + _noise_z.get_noise_2d(position.x, position.z) * PERTURB_STRENGTH,
	)


## Where a tile centre actually ends up on screen, for placing anything that
## stands on it.
static func tile_center(coord: Vector2i, size: float) -> Vector3:
	var centre := Hex.to_world(coord, size)
	return perturb(centre)

## How far an edge vertex moves toward the average of its three tiles. 1.0 is a
## full average, which dissolves tile boundaries entirely.
const EDGE_BLEND := 0.62

## Height in world units for each terrain, before per-tile elevation noise.
##
## Mountains stand well above everything else and are impassable, so they are
## allowed to dominate. Their jagged detail and snow line come from the rock
## section below; this is just the base height the crags are built on.
const TERRAIN_HEIGHT := {
	&"ocean": -0.50, &"coast": -0.20, &"lake": -0.16,
	&"grassland": 0.0, &"plains": 0.02, &"desert": 0.0,
	&"tundra": 0.04, &"snow": 0.08, &"mountains": 1.55,
}

const HILL_HEIGHT := 0.62

## How much of the generator's own elevation field shows through. Keeps a
## continent from being a uniform slab without letting it fight the terrain
## heights above.
const ELEVATION_RELIEF := 0.42

## Base colours. These replace the kit's texture atlas entirely for the ground —
## a continuous mesh cannot use per-tile textured blocks — so they carry the
## whole look of the landscape.
const TERRAIN_COLOR := {
	&"grassland": Color(0.33, 0.54, 0.20),
	&"plains": Color(0.66, 0.58, 0.26),
	&"desert": Color(0.84, 0.71, 0.42),
	&"tundra": Color(0.55, 0.55, 0.45),
	&"snow": Color(0.80, 0.84, 0.89),
	&"mountains": Color(0.46, 0.44, 0.43),
	&"coast": Color(0.20, 0.52, 0.70),
	&"ocean": Color(0.09, 0.26, 0.47),
	&"lake": Color(0.22, 0.54, 0.74),
}

## Civilization VI draws no hex grid on the ground at all. The terrain is one
## organic field, and the grid is implied by borders, districts and
## improvements — by what is *on* the land rather than by the land itself.
## Darkening tile edges here was making every hex read as a discrete patch, so
## edges are left unshaded and the grid is drawn as a toggleable overlay
## instead, the way the real game does it.
const EDGE_SHADE := 1.0

## Features recolour the ground under them, the way Civ 6 darkens a Woods tile
## rather than only planting trees on it.
const FEATURE_COLOR := {
	&"woods": Color(0.26, 0.44, 0.20),
	&"rainforest": Color(0.20, 0.44, 0.20),
	&"marsh": Color(0.36, 0.46, 0.30),
	&"floodplains": Color(0.52, 0.66, 0.30),
	&"oasis": Color(0.46, 0.66, 0.34),
	&"ice": Color(0.88, 0.93, 0.97),
}

const MOUNTAIN_COLOR_TOP := Color(0.94, 0.95, 0.97)

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
## Height variation around the inner ring, which is what facets the sides.
const CORE_JAG := 0.68

## Grey-brown cliff, snow only on the caps.
const ROCK_LOW := Color(0.26, 0.23, 0.21)
const ROCK_MID := Color(0.40, 0.37, 0.34)
const ROCK_HIGH := Color(0.54, 0.52, 0.51)
const ROCK_SNOW := Color(0.92, 0.94, 0.96)

## World heights the rock ramp is keyed to. Snow starts high so a mountain is
## mostly cliff with a cap, not a white cone.
const ROCK_BASE_Y := 0.60
const ROCK_SNOW_Y := 2.25


## Cliff colour at a world height. Used for every vertex of a rocky tile, so the
## snow line follows the actual geometry rather than the tile it belongs to —
## which is why a ridge's snow runs continuously across tile boundaries.
static func rock_color_at(y: float) -> Color:
	var t := clampf((y - ROCK_BASE_Y) / maxf(ROCK_SNOW_Y - ROCK_BASE_Y, 0.001), 0.0, 1.0)
	if t < 0.45:
		return ROCK_LOW.lerp(ROCK_MID, t / 0.45)
	if t < 0.86:
		return ROCK_MID.lerp(ROCK_HIGH, (t - 0.45) / 0.41)
	return ROCK_HIGH.lerp(ROCK_SNOW, (t - 0.86) / 0.14)


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
const ICE_COLOR := Color(0.84, 0.89, 0.94, 1.0)


## Height of a tile's centre vertex.
static func height_of(tile: Tile) -> float:
	var height: float = TERRAIN_HEIGHT.get(tile.terrain_id, 0.0)
	if tile.is_hills:
		height += HILL_HEIGHT
	# Elevation is 0..1 from the generator. Only land takes relief from it;
	# blending the sea floor upward would poke it through the water plane.
	if not tile.is_water():
		height += (tile.elevation - 0.5) * 2.0 * ELEVATION_RELIEF
	return height


static func color_of(tile: Tile) -> Color:
	var colour: Color = TERRAIN_COLOR.get(tile.terrain_id, Color(0.5, 0.5, 0.5))
	if tile.feature_id != &"" and FEATURE_COLOR.has(tile.feature_id):
		colour = colour.lerp(FEATURE_COLOR[tile.feature_id], 0.75)
	# Snow-cap the peaks so a mountain range has a silhouette rather than being
	# one flat grey mass.
	if tile.terrain_id == &"mountains":
		colour = colour.lerp(MOUNTAIN_COLOR_TOP, 0.55)
	elif tile.is_hills:
		colour = colour.darkened(0.06)
	return colour


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

	# Pass one: accumulate every hex's contribution to each shared corner.
	var corner_height: Dictionary = {}
	var corner_color: Dictionary = {}
	var corner_count: Dictionary = {}

	for tile: Tile in map.all_tiles():
		var centre := Hex.to_world(tile.coord, size)
		var height := height_of(tile)
		var colour := color_of(tile)
		for i in 6:
			var key := _key(centre + offsets[i])
			corner_height[key] = float(corner_height.get(key, 0.0)) + height
			corner_color[key] = (corner_color.get(key, Color(0, 0, 0, 0)) as Color) + colour
			corner_count[key] = int(corner_count.get(key, 0)) + 1

	corner_heights.clear()
	for key: Variant in corner_height:
		corner_heights[key] = float(corner_height[key]) / float(corner_count[key])

	# Pass two: each tile is a flat core plus a blend ring.
	#
	# Averaging every vertex would smooth the map into mush, with no tile
	# readable as itself — and a 4X map has to stay legible, because the player
	# is choosing which tile to work. So the inner hexagon keeps the tile's own
	# flat height and colour, and only the outer ring interpolates to the shared
	# corners. That is the Civ 6 compromise: flat readable ground, soft seams.
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

		var middle := Vector3(centre.x + apex_offset.x, apex, centre.z + apex_offset.z)
		var middle_color := colour if not rocky else rock_color_at(apex)

		for i in 6:
			var j := (i + 1) % 6

			# On rocky tiles the inner ring varies per corner, which is what turns
			# a smooth dome into a faceted crag. On everything else it stays flat,
			# so ordinary terrain keeps its readable tile core.
			var inner_a := centre + offsets[i] * CORE_RADIUS
			inner_a.y = height + (_jag(tile.coord, i + 1) * CORE_JAG if rocky else 0.0)
			var inner_b := centre + offsets[j] * CORE_RADIUS
			inner_b.y = height + (_jag(tile.coord, j + 1) * CORE_JAG if rocky else 0.0)

			var inner_a_color := colour if not rocky else rock_color_at(inner_a.y)
			var inner_b_color := colour if not rocky else rock_color_at(inner_b.y)

			# Core.
			_tri(surface, middle, inner_a, inner_b, middle_color, inner_a_color, inner_b_color)

			var a_key := _key(centre + offsets[i])
			var b_key := _key(centre + offsets[j])
			var outer_a := centre + offsets[i]
			outer_a.y = float(corner_height[a_key]) / float(corner_count[a_key])
			var outer_b := centre + offsets[j]
			outer_b.y = float(corner_height[b_key]) / float(corner_count[b_key])

			# Corners average all three touching tiles, which washes the tile's
			# own identity out of its edge. Pulling the blend back toward this
			# tile keeps the transition soft without dissolving the boundary.
			#
			# On rock this averaging is the whole point: it is what makes two
			# adjacent mountain hexes share a corner height and flow into one
			# unbroken ridge, instead of standing as two separate peaks.
			var a_color: Color
			var b_color: Color
			if rocky:
				a_color = rock_color_at(outer_a.y)
				b_color = rock_color_at(outer_b.y)
			else:
				a_color = colour.lerp(
					(corner_color[a_key] as Color) / float(corner_count[a_key]), EDGE_BLEND
				).darkened(1.0 - EDGE_SHADE)
				b_color = colour.lerp(
					(corner_color[b_key] as Color) / float(corner_count[b_key]), EDGE_BLEND
				).darkened(1.0 - EDGE_SHADE)

			# Blend ring, as two triangles.
			_tri(surface, inner_a, outer_a, outer_b, inner_a_color, a_color, b_color)
			_tri(surface, inner_a, outer_b, inner_b, inner_a_color, b_color, inner_b_color)
			emitted += 3

	if emitted == 0:
		return null

	surface.generate_normals()
	surface.set_material(ground_material())
	return surface.commit()


## The ground material: vertex colour for the biome, world-space noise on top to
## break up the tiles. Built once and shared.
static var _ground_material: ShaderMaterial = null

static func ground_material() -> ShaderMaterial:
	if _ground_material != null:
		return _ground_material

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
	return _ground_material


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


## A single translucent sheet at sea level covering every water tile. Drawn flat
## rather than blended into the land so the coastline reads as a definite edge.
static func build_water(map: MapModel, size: float) -> ArrayMesh:
	var offsets := corner_offsets(size)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted := 0

	for tile: Tile in map.all_tiles():
		if not tile.is_water():
			continue
		var centre := Hex.to_world(tile.coord, size)
		# Coast sits fractionally higher than deep ocean, which combined with the
		# colour difference gives the shallows a visible band.
		var level: float = -0.06 if tile.terrain_id != &"ocean" else -0.09
		var colour: Color = TERRAIN_COLOR.get(tile.terrain_id, TERRAIN_COLOR[&"ocean"])
		colour.a = 0.86

		# Ice is a feature sitting on polar water. Without this it is skipped
		# entirely — the land pass ignores water tiles — and the poles render as
		# open ocean. It floats just above the surface and is opaque.
		if tile.feature_id == &"ice":
			colour = ICE_COLOR
			level += 0.05

		for i in 6:
			var a := centre + offsets[i]
			var b := centre + offsets[(i + 1) % 6]
			_tri(surface,
				Vector3(centre.x, level, centre.z),
				Vector3(a.x, level, a.z),
				Vector3(b.x, level, b.z),
				colour, colour, colour)
			emitted += 1

	if emitted == 0:
		return null

	surface.generate_normals()

	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1, 1, 1, 0.92)
	material.roughness = 0.12
	material.metallic = 0.25
	surface.set_material(material)
	return surface.commit()


## Surface height at a tile centre, for placing props and units.
static func surface_height(tile: Tile) -> float:
	if tile == null:
		return 0.0
	if tile.is_water():
		return -0.06
	return height_of(tile)
