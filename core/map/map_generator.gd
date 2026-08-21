class_name MapGenerator
extends RefCounted

## Builds a world from a seed.
##
## The pipeline is: elevation -> land/sea -> hills and mountains -> erosion ->
## climate -> biomes -> rivers -> features ->
## continents -> resources -> natural wonders -> start positions.
##
## Climate is a simulated water cycle rather than a latitude lookup, so the map
## explains itself: wet windward coasts, dry interiors, and deserts in the lee
## of mountain ranges. See core/map/climate.gd.

const MAP_SIZES := {
	&"duel": Vector2i(44, 26),
	&"tiny": Vector2i(60, 38),
	&"small": Vector2i(74, 46),
	&"standard": Vector2i(84, 54),
	&"large": Vector2i(96, 60),
	&"huge": Vector2i(106, 66),
}

## Fraction of the map that should end up as land.
const LAND_FRACTION := 0.36

var map: MapModel
var _rng: RandomNumberGenerator


func generate(size: StringName = &"standard", options: Dictionary = {}) -> MapModel:
	_rng = RNGService.stream(RNGService.STREAM_MAP)
	var dims: Vector2i = MAP_SIZES.get(size, MAP_SIZES[&"standard"])
	if options.has("width"):
		dims = Vector2i(int(options["width"]), int(options["height"]))

	map = MapModel.new()
	map.setup(dims.x, dims.y, true)

	# Order matters more than it looks. Relief has to exist before the climate
	# runs, or the water cycle has no mountains to rain against and produces no
	# rain shadows; and the climate has to exist before terrain is assigned, or
	# biomes fall back to latitude stripes. Erosion sits between the two so the
	# ranges the wind meets are the eroded ones.
	_generate_elevation()
	_assign_land_and_sea()
	_place_hills_and_mountains()
	_erode()

	# The water cycle runs twice, either side of the rivers.
	#
	# The first pass tells the river tracer where the rain falls, so headwaters
	# rise in wet uplands. Carving then adds lakes and river tiles that were not
	# there when it ran — and a lake the climate never saw is a lake whose
	# surroundings keep whatever moisture they had, which is exactly how a lake
	# ends up ringed by desert. The second pass sees them as the water bodies
	# they are and greens the land around them.
	_assign_climate()
	_trace_rivers()
	_prune_drowned_rivers()
	_assign_climate()

	_place_features()
	_identify_continents()
	_place_resources()
	_place_natural_wonders()

	map.recompute_all_appeal()
	EventBus.map_generated.emit()
	return map


# -------------------------------------------------------------------------
# Elevation
# -------------------------------------------------------------------------

func _generate_elevation() -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = _rng.randi()
	noise.frequency = 0.035
	noise.fractal_octaves = 5
	noise.fractal_lacunarity = 2.1
	noise.fractal_gain = 0.5

	# A second, coarser field breaks the map into a few large landmasses rather
	# than scattering many equal-sized islands.
	var continental := FastNoiseLite.new()
	continental.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	continental.seed = _rng.randi()
	continental.frequency = 0.012

	for coord: Vector2i in map.tiles:
		var tile: Tile = map.tiles[coord]
		var off := MapModel.axial_to_offset(coord)

		# Sample on a cylinder so the east and west edges join seamlessly.
		var theta := TAU * float(off.x) / float(map.width)
		var nx := cos(theta) * map.width / TAU
		var nz := sin(theta) * map.width / TAU
		var ny := float(off.y)

		var detail := noise.get_noise_3d(nx, ny, nz)
		var broad := continental.get_noise_3d(nx, ny, nz)
		var elevation := broad * 0.65 + detail * 0.35

		# Push the poles down so the map ends in ocean rather than a wall of
		# land running off the top and bottom edges.
		var lat := _latitude(off.y)
		elevation -= pow(absf(lat), 6.0) * 0.5

		tile.elevation = elevation


## -1 at the south pole, 0 at the equator, +1 at the north pole.
func _latitude(row: int) -> float:
	return (float(row) / float(map.height - 1)) * 2.0 - 1.0


func _assign_land_and_sea() -> void:
	# Pick the sea level that yields the target land fraction, rather than
	# hardcoding a threshold that drifts with noise settings.
	var elevations: PackedFloat32Array = []
	for tile: Tile in map.tiles.values():
		elevations.append(tile.elevation)
	elevations.sort()
	var index := int(elevations.size() * (1.0 - LAND_FRACTION))
	var sea_level: float = elevations[clampi(index, 0, elevations.size() - 1)]

	# Rescale elevation so it means something absolute: 0 at the waterline, 1 at
	# the highest land, negative under the sea.
	#
	# Until now this held raw noise, roughly -1.5..1 with the shoreline wherever
	# the land fraction happened to put it. Every consumer then had to guess a
	# range, and they guessed differently — the renderer assumed 0..1 and placed
	# land at (elevation - 0.5), which for a typical coastal tile came out below
	# the water plane and drew the sea standing above the beach. Normalising once
	# here means elevation reads the same to the climate model, the renderer and
	# the AI.
	var highest := sea_level
	for value in elevations:
		highest = maxf(highest, value)
	var span := maxf(highest - sea_level, 0.0001)

	for tile: Tile in map.tiles.values():
		tile.elevation = (tile.elevation - sea_level) / span

	sea_level = 0.0
	_sea_level = sea_level

	for tile: Tile in map.tiles.values():
		tile.terrain_id = &"grassland" if tile.elevation > sea_level else &"ocean"

	# Ocean adjacent to land becomes Coast: shallow, workable, and the
	# precondition for Harbours.
	for tile: Tile in map.tiles.values():
		if tile.terrain_id != &"ocean":
			continue
		for n in map.neighbors(tile.coord):
			if n.terrain_id != &"ocean" and n.terrain_id != &"coast":
				tile.terrain_id = &"coast"
				break

	_carve_lakes()


## Small landlocked depressions become lakes, which supply fresh water inland.
func _carve_lakes() -> void:
	for tile: Tile in map.tiles.values():
		if tile.terrain_id != &"ocean" and tile.terrain_id != &"coast":
			continue
		if _is_connected_to_ocean(tile.coord):
			continue
		tile.terrain_id = &"lake"


func _is_connected_to_ocean(start: Vector2i) -> bool:
	# A water body touching the map's north or south edge, or larger than a
	# small pond, counts as sea rather than lake.
	var seen := {start: true}
	var frontier: Array[Vector2i] = [start]
	var count := 0
	while not frontier.is_empty() and count < 24:
		var coord: Vector2i = frontier.pop_back()
		count += 1
		var off := MapModel.axial_to_offset(coord)
		if off.y <= 0 or off.y >= map.height - 1:
			return true
		for n in map.neighbors(coord):
			if seen.has(n.coord) or not n.is_water():
				continue
			seen[n.coord] = true
			frontier.append(n.coord)
	return count >= 24


# -------------------------------------------------------------------------
# Climate
# -------------------------------------------------------------------------

## Moisture for every tile, kept so rivers can start where the rain actually
## falls rather than at an arbitrary high point.
var _moisture: Dictionary = {}

## The elevation the shoreline landed on. Kept because "how high is this tile"
## only means anything relative to the sea, and several later passes need it.
var _sea_level: float = 0.0


## Terrain comes out of the simulated climate rather than straight off the
## latitude, which is what lets a mountain range put a desert behind it.
## Mountains keep their own terrain — they are relief, not a biome.
func _assign_climate() -> void:
	_moisture = Climate.simulate(map, _rng)

	var jitter := FastNoiseLite.new()
	jitter.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	jitter.seed = _rng.randi()
	jitter.frequency = 0.06

	var bands := Climate.moisture_bands(map, _moisture)

	for tile: Tile in map.tiles.values():
		if tile.is_water() or tile.terrain_id == &"mountains":
			continue
		var temperature := Climate.temperature_of(map, tile, jitter)
		tile.terrain_id = Climate.biome_for(
			temperature, float(_moisture.get(tile.coord, 0.0)), bands
		)


# -------------------------------------------------------------------------
# Erosion
# -------------------------------------------------------------------------

## Fraction of erodible cells to wear away. 0 disables erosion entirely.
const EROSION_PERCENTAGE := 55

## Share of land tiles that become river headwaters.
const RIVER_PERCENTAGE := 0.05
## Minimum tiles between two headwaters, so rivers do not braid off one hillside.
const RIVER_SPACING := 3
## Shortest run worth keeping, in edges.
const MIN_RIVER_LENGTH := 6
## How much uphill a step may go before the walk refuses it.
const LEVEL_TOLERANCE := 0.004

## Elevation gap that counts as a cliff, and so as erodible.
const CLIFF_GAP := 0.16


## Knock the sharp edges off the terrain by moving material downhill.
##
## Raw noise produces cliffs everywhere: isolated spikes and sheer drops that
## look like nothing on Earth. Erosion, from part 24 of Catlike Coding's series,
## finds every cell standing well above a neighbour and moves a slice of it into
## that neighbour — so total landmass is conserved and the shape is redistributed
## rather than flattened. Coastlines come out less jagged and ranges gain
## foothills instead of ending in a wall.
func _erode() -> void:
	if EROSION_PERCENTAGE <= 0:
		return

	var erodible: Array[Tile] = []
	for tile: Tile in map.tiles.values():
		if _is_erodible(tile):
			erodible.append(tile)

	var target_count := int(erodible.size() * (100 - EROSION_PERCENTAGE) / 100.0)
	# Erosion can create new erodible cells as it goes, so the loop is bounded
	# rather than run to exhaustion.
	var guard := erodible.size() * 4

	while erodible.size() > target_count and guard > 0:
		guard -= 1
		var index := _rng.randi_range(0, erodible.size() - 1)
		var tile := erodible[index]
		var target := _erosion_target(tile)
		if target == null:
			erodible.remove_at(index)
			continue

		var moved := (tile.elevation - target.elevation) * 0.35
		tile.elevation -= moved
		target.elevation += moved

		if not _is_erodible(tile):
			erodible.remove_at(index)
		# The receiving cell may now tower over one of *its* neighbours.
		if _is_erodible(target) and not erodible.has(target):
			erodible.append(target)


func _is_erodible(tile: Tile) -> bool:
	if tile.is_water():
		return false
	for neighbour: Tile in map.neighbors(tile.coord):
		if neighbour.is_land() and tile.elevation - neighbour.elevation > CLIFF_GAP:
			return true
	return false


## A random neighbour at the foot of the cliff, so material lands somewhere
## plausible instead of always the same way.
func _erosion_target(tile: Tile) -> Tile:
	var candidates: Array[Tile] = []
	for neighbour: Tile in map.neighbors(tile.coord):
		if neighbour.is_land() and tile.elevation - neighbour.elevation > CLIFF_GAP:
			candidates.append(neighbour)
	if candidates.is_empty():
		return null
	return candidates[_rng.randi_range(0, candidates.size() - 1)]


func _place_hills_and_mountains() -> void:
	# Elevation is relative to the land it sits in, so mountain ranges follow
	# the high spine of a continent instead of clustering at one pole.
	var land_elevations: PackedFloat32Array = []
	for tile: Tile in map.tiles.values():
		if tile.is_land():
			land_elevations.append(tile.elevation)
	if land_elevations.is_empty():
		return
	land_elevations.sort()

	var hill_line: float = land_elevations[int(land_elevations.size() * 0.55)]
	var mountain_line: float = land_elevations[int(land_elevations.size() * 0.80)]

	for tile: Tile in map.tiles.values():
		if not tile.is_land() or tile.terrain_id == &"lake":
			continue
		if tile.elevation >= mountain_line:
			tile.terrain_id = &"mountains"
		elif tile.elevation >= hill_line:
			tile.is_hills = true

	_thin_mountains()


## Carve the inside out of mountain masses so ranges read as ridges.
##
## Thresholding elevation alone produces blobs: every tile in a high region
## qualifies, so a plateau becomes one solid impassable mass tens of tiles
## across — which is both ugly and unplayable, since nothing can cross it and
## no city can work it.
##
## Real ranges are lines. Keeping only tiles with open ground on at least two
## sides erodes each blob down to its outline, which is a ridge, and the
## interior falls back to hills — high, rough, but passable and workable.
func _thin_mountains() -> void:
	var demoted: Array[Tile] = []
	for tile: Tile in map.tiles.values():
		if tile.terrain_id != &"mountains":
			continue
		var mountain_neighbours := 0
		for n in map.neighbors(tile.coord):
			if n.terrain_id == &"mountains":
				mountain_neighbours += 1
		if mountain_neighbours >= 6:
			demoted.append(tile)

	for tile in demoted:
		tile.terrain_id = &"grassland"   # the climate pass will assign its biome
		tile.is_hills = true


# -------------------------------------------------------------------------
# Rivers
# -------------------------------------------------------------------------

## Rivers start high and follow the steepest downhill neighbour to the sea,
## marking the edge they cross. Because they run along edges rather than
## occupying tiles, a river tile keeps its own yields and gains fresh water,
## +1 Appeal, and Commercial Hub adjacency.
## Rivers begin where the rain does.
##
## Picking the highest tiles gives every range a river regardless of whether any
## water falls there, which is how you end up with streams pouring out of a
## desert massif. Catlike's series scores an origin by moisture times relative
## elevation, so a source needs both the rainfall to feed it and the height to
## run downhill from — and the climate simulation above is what makes that score
## mean something.
## Rivers, seeded where the rain actually falls.
##
## Ported from part 26 of Catlike Coding's hex map series. Origins are weighted
## by moisture and height, so rivers start in wet uplands rather than on
## whichever peak happened to be tallest — a dry mountain in a rain shadow
## should not be a headwater, and before this every mountain was one.
##
## A river then walks downhill to the sea. When it cannot, it has found a basin,
## and a lake forms there instead — which is where most of the map's lakes now
## come from.
## Rivers, traced over the corner lattice.
##
## A river in this model runs *along* tile edges, so its path is a walk from
## corner to corner: each step crosses exactly one hex edge, and consecutive
## steps share the corner between them. That makes the river connected by
## construction.
##
## Tracing over tiles instead — walk downhill tile to tile, mark an edge per
## step — cannot work, and is what produced the disconnected slivers this
## replaces: a river running straight through a hex enters and leaves by
## opposite edges, and opposite edges of a hexagon share no vertex.
func _trace_rivers() -> void:
	_build_corner_lattice()
	if _corner_elevation.is_empty():
		return

	# Score headwaters by moisture and height, so rivers rise in wet uplands
	# rather than on whichever peak happened to be tallest. A mountain sitting
	# in a rain shadow is not a source.
	var scored: Array = []
	for tile: Tile in map.all_tiles():
		if not tile.is_land() or tile.terrain_id == &"mountains":
			continue
		if _touches_water(tile):
			continue   # a river starting here would be one tile long
		var weight := float(_moisture.get(tile.coord, 0.0)) * (0.35 + clampf(tile.elevation, 0.0, 1.0))
		if weight > 0.0:
			scored.append({"tile": tile, "weight": weight})

	if scored.is_empty():
		return

	# Ranked rather than thresholded: elevation is normalised and moisture
	# rarely tops 0.5, so any absolute cutoff either passes everything or almost
	# nothing.
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["weight"] > b["weight"])

	var land_count := 0
	for tile: Tile in map.all_tiles():
		if tile.is_land():
			land_count += 1

	var budget := maxi(3, int(land_count * RIVER_PERCENTAGE))
	var pool := maxi(1, int(scored.size() * 0.5))
	var placed := 0

	for _attempt in pool * 4:
		if placed >= budget:
			break
		var source: Tile = scored[_rng.randi_range(0, pool - 1)]["tile"]
		if source.is_water() or _near_river(source.coord, RIVER_SPACING):
			continue
		if _trace_one_river(source):
			placed += 1


## Corner elevations and the links between them.
##
## Every corner is shared by up to three tiles, so it is keyed by welded world
## position; its elevation is the mean of the tiles touching it. Each link is
## one hex edge, carrying the tile and direction needed to mark it.
var _corner_elevation: Dictionary = {}
var _corner_links: Dictionary = {}     # key -> [{to, tile, direction}, ...]
var _corner_is_water: Dictionary = {}
var _corner_position: Dictionary = {}


func _build_corner_lattice() -> void:
	_corner_elevation.clear()
	_corner_links.clear()
	_corner_is_water.clear()
	_corner_position.clear()

	var totals: Dictionary = {}
	var counts: Dictionary = {}

	for tile: Tile in map.all_tiles():
		var centre := Hex.to_world(tile.coord, 1.0)
		for i in 6:
			var position := centre + Hex.corner_offset(i, 1.0)
			var key := Hex.corner_key(position)
			totals[key] = float(totals.get(key, 0.0)) + tile.elevation
			counts[key] = int(counts.get(key, 0)) + 1
			_corner_position[key] = position
			if tile.is_water():
				_corner_is_water[key] = true

	for key: Vector2i in totals:
		_corner_elevation[key] = float(totals[key]) / float(counts[key])

	# One link per hex edge. Each edge is walked twice, once from either side,
	# which is what gives both corners a link back to the other.
	for tile: Tile in map.all_tiles():
		var centre := Hex.to_world(tile.coord, 1.0)
		for direction in Hex.DIRECTION_COUNT:
			if map.neighbor_in(tile.coord, direction) == null:
				continue
			var pair := Hex.edge_corners(direction)
			var a := Hex.corner_key(centre + Hex.corner_offset(pair.x, 1.0))
			var b := Hex.corner_key(centre + Hex.corner_offset(pair.y, 1.0))
			_corner_links.get_or_add(a, []).append({
				"to": b, "tile": tile.coord, "direction": direction,
			})


## Walk downhill from the source tile's highest corner to the sea, marking the
## edge crossed at every step.
func _trace_one_river(source: Tile) -> bool:
	var current := _highest_corner_of(source)
	if current == Vector2i.MAX:
		return false

	var visited := {current: true}
	var steps: Array = []

	for _step in 120:
		var links: Array = _corner_links.get(current, [])
		var best_key := Vector2i.MAX
		var best_link: Dictionary = {}
		var here: float = float(_corner_elevation.get(current, 0.0))
		var best_elevation := INF

		for link: Dictionary in links:
			var to: Vector2i = link["to"]
			if visited.has(to):
				continue
			var elevation := float(_corner_elevation.get(to, INF))
			# Strictly downhill would stall on the first flat corner, and
			# corner elevations are three-tile averages so ties are common.
			# Allowing a level step lets a river cross a plain to reach the sea
			# instead of dying two edges from its source.
			if elevation > here + LEVEL_TOLERANCE:
				continue
			if elevation < best_elevation:
				best_elevation = elevation
				best_key = to
				best_link = link

		if best_key == Vector2i.MAX:
			# Trapped. A genuine depression becomes a lake; anything shorter is
			# discarded rather than left as a stub in a field.
			if steps.size() >= MIN_RIVER_LENGTH and _is_basin(current):
				_form_lake(current)
				_commit_river(steps)
				return true
			return false

		steps.append(best_link)
		visited[best_key] = true
		current = best_key

		# Reaching water is the river mouth.
		if _corner_is_water.has(current):
			# A two-edge trickle beside the coast is not a river. Rejecting
			# short runs is what stops the map filling with blue slivers.
			if steps.size() < MIN_RIVER_LENGTH:
				return false
			_commit_river(steps)
			return true

	return false


func _highest_corner_of(tile: Tile) -> Vector2i:
	var centre := Hex.to_world(tile.coord, 1.0)
	var best := Vector2i.MAX
	var best_elevation := -INF
	for i in 6:
		var key := Hex.corner_key(centre + Hex.corner_offset(i, 1.0))
		if _corner_is_water.has(key):
			continue
		var elevation := float(_corner_elevation.get(key, -INF))
		if elevation > best_elevation:
			best_elevation = elevation
			best = key
	return best


## True when every neighbouring corner sits higher — a real depression, not
## merely a spot the walk could not leave because it had been there already.
func _is_basin(key: Vector2i) -> bool:
	var here := float(_corner_elevation.get(key, 0.0))
	for link: Dictionary in _corner_links.get(key, []):
		if float(_corner_elevation.get(link["to"], INF)) < here:
			return false
	return true


func _commit_river(steps: Array) -> void:
	for link: Dictionary in steps:
		map.set_river(link["tile"], int(link["direction"]), true)


## Flood a basin. The three tiles meeting at the corner are candidates; only
## those genuinely lower than their own surroundings are drowned, so a lake
## never spills across a slope.
func _form_lake(key: Vector2i) -> void:
	var position: Vector3 = _corner_position.get(key, Vector3.ZERO)
	var seeds: Array[Tile] = []
	for i in 6:
		var tile := map.get_tile(Hex.from_world(position + Hex.corner_offset(i, 0.55), 1.0))
		if tile != null and tile.is_land() and tile.terrain_id != &"mountains" and not seeds.has(tile):
			seeds.append(tile)
	if seeds.is_empty():
		return

	seeds.sort_custom(func(a: Tile, b: Tile) -> bool: return a.elevation < b.elevation)
	var floor_tile: Tile = seeds[0]
	_drown(floor_tile, floor_tile.elevation)

	# Extend only into neighbours that are themselves hollows, so a lake follows
	# the shape of the basin instead of spreading at random.
	for neighbour in map.neighbors(floor_tile.coord):
		if not neighbour.is_land() or neighbour.terrain_id == &"mountains":
			continue
		if neighbour.elevation <= floor_tile.elevation + 0.015 and _is_hollow(neighbour):
			_drown(neighbour, floor_tile.elevation)


func _drown(tile: Tile, level: float) -> void:
	tile.terrain_id = &"lake"
	tile.feature_id = &""
	tile.is_hills = false
	tile.improvement_id = &""
	tile.elevation = level - 0.01


## A tile lower than most of what surrounds it.
func _is_hollow(tile: Tile) -> bool:
	var higher := 0
	for n in map.neighbors(tile.coord):
		if n.elevation > tile.elevation:
			higher += 1
	return higher >= 4


## Drop river edges that ended up between two water tiles.
##
## Forming a lake drowns the ground a chain was running over, and an edge with
## water on both sides is not a river any more — it is just lake. Left in place
## these show up as blue slivers stranded in open water, and as isolated edges
## in the river-continuity test.
func _prune_drowned_rivers() -> void:
	for tile: Tile in map.all_tiles():
		if tile.river_edges == 0 or not tile.is_water():
			continue
		for direction in Hex.DIRECTION_COUNT:
			if not tile.has_river_on(direction):
				continue
			var neighbour := map.neighbor_in(tile.coord, direction)
			if neighbour != null and neighbour.is_water():
				map.set_river(tile.coord, direction, false)

	_prune_stranded_rivers()


## Remove river edges that touch no other river edge at either end.
##
## The corner walk produces connected chains, but a handful of edges still end
## up alone once lakes have been carved and drowned edges removed. A single
## isolated edge is not a river — it is a blue dash lying in a field, which is
## exactly what the old tracer produced everywhere and what the continuity test
## guards against. Cheaper to sweep them up here than to special-case every way
## one can arise.
func _prune_stranded_rivers() -> void:
	var uses: Dictionary = {}
	var edges: Array = []

	for tile: Tile in map.all_tiles():
		for direction in Hex.DIRECTION_COUNT:
			if not tile.has_river_on(direction):
				continue
			var centre := Hex.to_world(tile.coord, 1.0)
			var pair := Hex.edge_corners(direction)
			var a := Hex.corner_key(centre + Hex.corner_offset(pair.x, 1.0))
			var b := Hex.corner_key(centre + Hex.corner_offset(pair.y, 1.0))
			var key := [a, b] if a < b else [b, a]
			if edges.any(func(e: Array) -> bool: return e[2] == key):
				continue
			edges.append([tile.coord, direction, key])
			uses[a] = int(uses.get(a, 0)) + 1
			uses[b] = int(uses.get(b, 0)) + 1

	for edge: Array in edges:
		var key: Array = edge[2]
		if int(uses.get(key[0], 0)) < 2 and int(uses.get(key[1], 0)) < 2:
			map.set_river(edge[0], int(edge[1]), false)


func _touches_water(tile: Tile) -> bool:
	for n in map.neighbors(tile.coord):
		if n.is_water():
			return true
	return false


func _near_river(coord: Vector2i, radius: int) -> bool:
	for tile in map.tiles_within(coord, radius):
		if tile.has_river():
			return true
	return false


func _place_features() -> void:
	var forest_noise := FastNoiseLite.new()
	forest_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	forest_noise.seed = _rng.randi()
	forest_noise.frequency = 0.08

	for tile: Tile in map.tiles.values():
		var off := MapModel.axial_to_offset(tile.coord)
		var lat := absf(_latitude(off.y))
		var density := forest_noise.get_noise_2d(off.x, off.y) * 0.5 + 0.5

		if tile.terrain_id == &"coast":
			if lat > 0.9:
				tile.feature_id = &"ice"
			elif density > 0.78 and _rng.randf() < 0.35:
				tile.feature_id = &"reef"
			continue
		if tile.terrain_id == &"ocean" and lat > 0.93:
			tile.feature_id = &"ice"
			continue
		if not tile.is_land() or tile.terrain_id == &"mountains":
			continue

		# Floodplains only form on flat river tiles, and outrank other features
		# because they are what makes a desert river valley worth settling.
		if tile.has_river() and not tile.is_hills and tile.terrain_id in [&"desert", &"grassland", &"plains"]:
			if _rng.randf() < 0.55:
				tile.feature_id = &"floodplains"
				continue

		match tile.terrain_id:
			&"desert":
				if not tile.is_hills and _rng.randf() < 0.04:
					tile.feature_id = &"oasis"
			&"grassland", &"plains":
				if lat < 0.22 and density > 0.5:
					tile.feature_id = &"rainforest"
				elif density > 0.58:
					tile.feature_id = &"woods"
				elif tile.terrain_id == &"grassland" and not tile.is_hills and _rng.randf() < 0.04:
					tile.feature_id = &"marsh"
			&"tundra":
				if density > 0.66:
					tile.feature_id = &"woods"

		if tile.feature_id == &"" and _rng.randf() < 0.006:
			tile.feature_id = &"geothermal_fissure"


# -------------------------------------------------------------------------
# Continents
# -------------------------------------------------------------------------

## Flood-fill landmasses so the game can tell "home continent" from "foreign",
## seed each with its own luxury resources, and award the Era Score moment for
## discovering a new one.
func _identify_continents() -> void:
	var next_id := 0
	for tile: Tile in map.tiles.values():
		if not tile.is_land() or tile.continent_id != -1:
			continue
		var members: Array[Vector2i] = []
		var frontier: Array[Vector2i] = [tile.coord]
		tile.continent_id = next_id
		while not frontier.is_empty():
			var coord: Vector2i = frontier.pop_back()
			members.append(coord)
			for n in map.neighbors(coord):
				if n.is_land() and n.continent_id == -1:
					n.continent_id = next_id
					frontier.append(n.coord)
		# Anything smaller than this is an island, not a continent — it stays
		# unassigned so it does not get its own exclusive luxury set.
		if members.size() < 12:
			for coord in members:
				map.get_tile(coord).continent_id = -1
		else:
			map.continents[next_id] = members
			next_id += 1


# -------------------------------------------------------------------------
# Resources
# -------------------------------------------------------------------------

func _place_resources() -> void:
	var luxuries := ContentDB.resources_of(MapDefs.ResourceDef.Category.LUXURY)
	var continent_ids: Array = map.continents.keys()

	# Give each continent its own luxury set, so trading across the ocean is
	# worth doing and exploration has an economic payoff.
	var luxury_by_continent := {}
	if not luxuries.is_empty() and not continent_ids.is_empty():
		var shuffled := luxuries.duplicate()
		_shuffle(shuffled)
		for i in continent_ids.size():
			var assigned: Array = []
			for j in 4:
				assigned.append(shuffled[(i * 4 + j) % shuffled.size()])
			luxury_by_continent[continent_ids[i]] = assigned

	for tile: Tile in map.tiles.values():
		if tile.resource_id != &"" or tile.terrain_id == &"mountains":
			continue

		var pool: Array = []
		if tile.continent_id != -1 and luxury_by_continent.has(tile.continent_id) and _rng.randf() < 0.10:
			pool = luxury_by_continent[tile.continent_id]
		elif _rng.randf() < 0.30:
			pool = ContentDB.resources_of(MapDefs.ResourceDef.Category.BONUS)
		elif _rng.randf() < 0.14:
			pool = ContentDB.resources_of(MapDefs.ResourceDef.Category.STRATEGIC)
		if pool.is_empty():
			continue

		var valid: Array = []
		var weights := PackedFloat32Array()
		for res: MapDefs.ResourceDef in pool:
			if not _resource_fits(res, tile):
				continue
			valid.append(res)
			weights.append(res.frequency)
		if valid.is_empty():
			continue

		var chosen: MapDefs.ResourceDef = RNGService.pick_weighted(RNGService.STREAM_MAP, valid, weights)
		if chosen == null:
			continue
		tile.resource_id = chosen.id
		tile.resource_amount = _rng.randi_range(2, 6) if chosen.is_strategic() else 1


func _resource_fits(res: MapDefs.ResourceDef, tile: Tile) -> bool:
	if not res.valid_terrain.is_empty() and not res.valid_terrain.has(tile.terrain_id):
		return false
	if not res.valid_features.is_empty():
		if not res.valid_features.has(tile.feature_id):
			return false
	elif tile.feature_id in [&"ice", &"marsh"]:
		return false
	# A resource that needs hills should only appear on them, and vice versa.
	if res.get_bool("requires_hills") and not tile.is_hills:
		return false
	if res.get_bool("requires_flat") and tile.is_hills:
		return false
	return true


func _place_natural_wonders() -> void:
	var pool: Array = ContentDB.natural_wonders.values()
	if pool.is_empty():
		return
	var target := clampi(int(map.width * map.height / 900.0), 2, 6)
	var placed: Array[Vector2i] = []
	var shuffled := pool.duplicate()
	_shuffle(shuffled)

	for wonder: MapDefs.NaturalWonderDef in shuffled:
		if placed.size() >= target:
			break
		for _attempt in 200:
			var tile: Tile = RNGService.pick(RNGService.STREAM_MAP, map.tiles.values())
			if tile == null or tile.natural_wonder_id != &"" or tile.resource_id != &"":
				continue
			if wonder.requires_water and not tile.is_water():
				continue
			if wonder.requires_land and not tile.is_land():
				continue
			if tile.terrain_id == &"mountains":
				continue
			# Keep wonders apart so no single start position collects them all.
			var too_close := false
			for other in placed:
				if map.distance(other, tile.coord) < 8:
					too_close = true
					break
			if too_close:
				continue
			tile.natural_wonder_id = wonder.id
			tile.feature_id = &""
			placed.append(tile.coord)
			break


func _shuffle(array: Array) -> void:
	for i in range(array.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = array[i]
		array[i] = array[j]
		array[j] = tmp


# -------------------------------------------------------------------------
# Start positions
# -------------------------------------------------------------------------

## Score every land tile as a capital site, then place players greedily,
## maximising the distance between starts so nobody is boxed in at turn one.
func choose_start_positions(count: int) -> Array[Vector2i]:
	var scored: Array = []
	for tile: Tile in map.tiles.values():
		var score := _score_start(tile)
		if score > 0.0:
			scored.append({"coord": tile.coord, "score": score})
	if scored.is_empty():
		return []

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] > b["score"])

	var chosen: Array[Vector2i] = []
	# Only consider strong sites, so "far apart" never wins out over "viable".
	var pool_size := mini(scored.size(), maxi(count * 40, 200))

	for _i in count:
		var best: Vector2i = Vector2i(-9999, -9999)
		var best_value := -INF
		for j in pool_size:
			var candidate: Vector2i = scored[j]["coord"]
			if chosen.has(candidate):
				continue
			var nearest := INF
			for other in chosen:
				nearest = minf(nearest, float(map.distance(candidate, other)))
			# Early picks are driven by tile quality; later picks weigh
			# separation heavily so players are not stacked together.
			var value: float = scored[j]["score"]
			if not chosen.is_empty():
				if nearest < 8.0:
					continue
				value += nearest * 3.0
			if value > best_value:
				best_value = value
				best = candidate
		if best.x == -9999:
			break
		chosen.append(best)

	return chosen


func _score_start(tile: Tile) -> float:
	if not tile.is_land() or tile.is_impassable() or tile.terrain_id == &"snow":
		return 0.0
	if tile.natural_wonder_id != &"":
		return 0.0

	var score := 8.0
	if map.has_fresh_water(tile.coord):
		score += 6.0
	if map.is_coastal(tile.coord):
		score += 3.0
	if tile.is_hills:
		score += 2.0   # defensible, and +1 production on the city centre

	# Survey the workable radius: a capital lives off its surroundings, not
	# its own tile.
	var food := 0.0
	var production := 0.0
	var luxuries := 0
	for neighbour in map.tiles_within(tile.coord, MapModel.CITY_WORK_RADIUS):
		if neighbour.coord == tile.coord:
			continue
		var y := neighbour.base_yields()
		food += y.get_kind(Yields.Kind.FOOD)
		production += y.get_kind(Yields.Kind.PRODUCTION)
		var res := neighbour.resource()
		if res != null and res.is_luxury():
			luxuries += 1
		if neighbour.terrain_id == &"mountains":
			score += 0.4   # Campus and Holy Site adjacency

	score += food * 0.35 + production * 0.45 + luxuries * 2.0
	return score
