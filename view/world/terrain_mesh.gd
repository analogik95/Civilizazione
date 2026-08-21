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
## is the blend ring out to the shared corners.
const CORE_RADIUS := 0.58

## How far an edge vertex moves toward the average of its three tiles. 1.0 is a
## full average, which dissolves tile boundaries entirely.
const EDGE_BLEND := 0.62

## Height in world units for each terrain, before per-tile elevation noise.
## A tile is two units across, so a mountain at 1.9 stands about as tall as a
## tile is wide — dramatic in silhouette without blocking the tiles behind it.
const TERRAIN_HEIGHT := {
	&"ocean": -0.50, &"coast": -0.20, &"lake": -0.16,
	&"grassland": 0.0, &"plains": 0.02, &"desert": 0.0,
	&"tundra": 0.04, &"snow": 0.08, &"mountains": 1.90,
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

## Tile edges are darkened slightly, which draws the hex grid without a separate
## overlay pass. Civ 6 keeps a faint tile boundary visible for the same reason:
## the player is choosing which tile to work, and needs to see where one ends.
const EDGE_SHADE := 0.90

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
		var middle := Vector3(centre.x, height, centre.z)

		for i in 6:
			var j := (i + 1) % 6
			var inner_a := centre + offsets[i] * CORE_RADIUS
			inner_a.y = height
			var inner_b := centre + offsets[j] * CORE_RADIUS
			inner_b.y = height

			# Flat core.
			_tri(surface, middle, inner_a, inner_b, colour, colour, colour)

			var a_key := _key(centre + offsets[i])
			var b_key := _key(centre + offsets[j])
			var outer_a := centre + offsets[i]
			outer_a.y = float(corner_height[a_key]) / float(corner_count[a_key])
			var outer_b := centre + offsets[j]
			outer_b.y = float(corner_height[b_key]) / float(corner_count[b_key])

			# Corners average all three touching tiles, which washes the tile's
			# own identity out of its edge. Pulling the blend back toward this
			# tile keeps the transition soft without dissolving the boundary.
			var a_color := colour.lerp(
				(corner_color[a_key] as Color) / float(corner_count[a_key]), EDGE_BLEND
			).darkened(1.0 - EDGE_SHADE)
			var b_color := colour.lerp(
				(corner_color[b_key] as Color) / float(corner_count[b_key]), EDGE_BLEND
			).darkened(1.0 - EDGE_SHADE)

			# Blend ring, as two triangles.
			_tri(surface, inner_a, outer_a, outer_b, colour, a_color, b_color)
			_tri(surface, inner_a, outer_b, inner_b, colour, b_color, colour)
			emitted += 3

	if emitted == 0:
		return null

	surface.generate_normals()

	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.94
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	surface.set_material(material)
	return surface.commit()


## Emit one upward-facing triangle. Winding is a -> b -> c; with +Y up and
## Godot's counter-clockwise front faces, that order is what points the normal
## at the sky rather than at the sea floor.
static func _tri(
	surface: SurfaceTool,
	a: Vector3, b: Vector3, c: Vector3,
	a_color: Color, b_color: Color, c_color: Color
) -> void:
	surface.set_color(a_color)
	surface.add_vertex(a)
	surface.set_color(b_color)
	surface.add_vertex(b)
	surface.set_color(c_color)
	surface.add_vertex(c)


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
