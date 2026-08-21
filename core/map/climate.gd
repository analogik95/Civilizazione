class_name Climate
extends RefCounted

## A water cycle, simulated over the map to decide where the rain falls.
##
## Assigning terrain straight from latitude gives neat horizontal stripes, and
## adding a noise field on top only makes the stripes lumpy — neither knows that
## a mountain range exists. Real climate is not a function of latitude alone; it
## is a function of where the wind carries water and what stops it.
##
## So this ports the water cycle from part 25 of Catlike Coding's hex map series.
## Each cycle, every cell:
##
##   1. **Evaporates.** Water tiles push clouds into the air. Land tiles give up
##      part of their moisture to become clouds.
##   2. **Precipitates.** Part of the cloud cover falls as rain.
##   3. **Lifts orographically.** The higher air rises, the less water it can
##      hold, so a cell above its elevation's carrying capacity dumps the excess
##      immediately. This is the step that produces rain shadows: wind hits a
##      range, is forced up, rains itself out on the windward slope, and arrives
##      on the far side dry.
##   4. **Disperses.** Remaining clouds spread to all six neighbours, weighted
##      heavily toward the prevailing wind.
##   5. **Runs off and seeps.** Moisture drains downhill and creeps sideways
##      across level ground.
##
## Run enough times, this settles into wet windward coasts, dry continental
## interiors, and deserts in the lee of mountains — the map explains itself.

const EVAPORATION := 0.5
const PRECIPITATION := 0.25
const RUNOFF := 0.25
const SEEPAGE := 0.125
const STARTING_MOISTURE := 0.1

## Direction the wind blows *toward*, as an index into Hex.DIRECTIONS.
const WIND_DIRECTION := 3
## How much more cloud goes downwind than to any other neighbour. At 1.0 the
## wind does nothing and moisture spreads evenly in all directions.
const WIND_STRENGTH := 4.0

## Enough passes for moisture to cross a continent and settle.
const CYCLES := 40

## Above this share of maximum elevation, air can hold no more water and the
## rest falls as rain. Lower values make ranges cast longer rain shadows.
const CLOUD_CEILING := 0.55

## How much colder the air gets at maximum elevation, as a fraction.
const LAPSE_RATE := 0.55
const TEMPERATURE_JITTER := 0.08


## Moisture per tile, in the range 0..1.
static func simulate(map: MapModel, rng: RandomNumberGenerator) -> Dictionary:
	var clouds: Dictionary = {}
	var moisture: Dictionary = {}
	var coords: Array = []

	for tile: Tile in map.all_tiles():
		coords.append(tile.coord)
		clouds[tile.coord] = 0.0
		# Oceans are an unlimited reservoir; land starts nearly dry and has to
		# be watered by the cycle, which is what makes interiors arid.
		moisture[tile.coord] = 1.0 if tile.is_water() else STARTING_MOISTURE

	for _cycle in CYCLES:
		var next_clouds: Dictionary = {}
		for coord: Vector2i in coords:
			next_clouds[coord] = 0.0

		for coord: Vector2i in coords:
			var tile := map.get_tile(coord)
			if tile == null:
				continue

			var cell_clouds: float = clouds[coord]
			var cell_moisture: float = moisture[coord]

			# 1. Evaporation.
			if tile.is_water():
				cell_clouds += EVAPORATION
				cell_moisture = 1.0
			else:
				var evaporated := cell_moisture * EVAPORATION
				cell_moisture -= evaporated
				cell_clouds += evaporated

			# 2. Precipitation.
			var rain := cell_clouds * PRECIPITATION
			cell_clouds -= rain
			cell_moisture += rain

			# 3. Orographic lift — the rain shadow term.
			var ceiling := (1.0 - tile.elevation) * CLOUD_CEILING + (1.0 - CLOUD_CEILING)
			if cell_clouds > ceiling:
				cell_moisture += cell_clouds - ceiling
				cell_clouds = ceiling

			# 4. Cloud dispersal, biased downwind.
			var share := cell_clouds / (5.0 + WIND_STRENGTH)
			var main := share * WIND_STRENGTH
			for direction in Hex.DIRECTION_COUNT:
				var neighbour := map.neighbor_in(coord, direction)
				if neighbour == null:
					continue
				var amount := main if direction == WIND_DIRECTION else share
				next_clouds[neighbour.coord] = float(next_clouds[neighbour.coord]) + amount
			cell_clouds = 0.0

			# 5. Runoff downhill, seepage across the level.
			if not tile.is_water():
				for direction in Hex.DIRECTION_COUNT:
					var neighbour := map.neighbor_in(coord, direction)
					if neighbour == null:
						continue
					var flow := 0.0
					if neighbour.elevation < tile.elevation - 0.001:
						flow = cell_moisture * RUNOFF / 6.0
					elif absf(neighbour.elevation - tile.elevation) <= 0.001:
						flow = cell_moisture * SEEPAGE / 6.0
					if flow <= 0.0:
						continue
					cell_moisture -= flow
					moisture[neighbour.coord] = minf(
						float(moisture[neighbour.coord]) + flow, 1.0
					)

			moisture[coord] = clampf(cell_moisture, 0.0, 1.0)
			clouds[coord] = cell_clouds

		for coord: Vector2i in coords:
			clouds[coord] = float(clouds[coord]) + float(next_clouds[coord])

	# A little jitter so equally-watered cells do not form flat plateaus of one
	# biome, and the band boundaries are not perfectly smooth curves.
	for coord: Vector2i in coords:
		moisture[coord] = clampf(
			float(moisture[coord]) + rng.randf_range(-0.02, 0.02), 0.0, 1.0
		)
	return moisture


## Temperature in 0..1, from latitude, altitude and a little noise.
##
## Latitude sets the base, altitude cools it — which is what keeps a tropical
## mountain from being jungle to its peak — and jitter stops the isotherms from
## being perfectly straight lines across the map.
static func temperature_of(
	map: MapModel, tile: Tile, jitter: FastNoiseLite
) -> float:
	var offset := MapModel.axial_to_offset(tile.coord)
	var latitude := absf(float(offset.y) / maxf(float(map.height - 1), 1.0) * 2.0 - 1.0)
	var value := 1.0 - latitude
	value *= 1.0 - tile.elevation * LAPSE_RATE
	value += jitter.get_noise_2d(offset.x, offset.y) * TEMPERATURE_JITTER
	return clampf(value, 0.0, 1.0)


# -------------------------------------------------------------------------
# Biomes
# -------------------------------------------------------------------------

## Temperature band edges, coldest first. These stay absolute: temperature comes
## from latitude and altitude, which mean the same thing on every map, and the
## poles should be frozen whatever else is going on.
const TEMPERATURE_BANDS := [0.12, 0.32, 0.62]

## Moisture band edges are *relative* instead — see moisture_bands().
const MOISTURE_BANDS := [0.14, 0.30, 0.58]

## Share of land falling in each moisture band, driest first. The simulation's
## absolute moisture depends on map size, land fraction and how much coastline
## there is, so fixed cutoffs make a big continent read as one huge desert while
## an archipelago comes out uniformly green. Splitting by percentile pins the
## *mix* of biomes and lets the simulation decide only where each one goes,
## which is the part it is actually good at.
const MOISTURE_QUANTILES := [0.22, 0.46, 0.74]


## Moisture band edges for this particular map, at the quantiles above.
static func moisture_bands(map: MapModel, moisture: Dictionary) -> Array:
	var land: PackedFloat32Array = []
	for tile: Tile in map.all_tiles():
		if tile.is_land():
			land.append(float(moisture.get(tile.coord, 0.0)))
	if land.is_empty():
		return MOISTURE_BANDS
	land.sort()

	var bands: Array = []
	for quantile: float in MOISTURE_QUANTILES:
		var index := clampi(int(land.size() * quantile), 0, land.size() - 1)
		bands.append(land[index])
	return bands

## [temperature band][moisture band] -> terrain.
##
## Read the bottom row left to right and it is the real world: a hot dry belt of
## desert, then savannah plains, then rainforest-grade grassland. The top two
## rows are polar and stay frozen however wet they are, because temperature, not
## rainfall, is what is scarce there.
const BIOMES := [
	[&"snow", &"snow", &"snow", &"snow"],
	[&"tundra", &"tundra", &"tundra", &"tundra"],
	[&"desert", &"plains", &"grassland", &"grassland"],
	[&"desert", &"desert", &"plains", &"grassland"],
]


static func _band(value: float, edges: Array) -> int:
	for i in edges.size():
		if value < float(edges[i]):
			return i
	return edges.size()


static func biome_for(
	temperature: float, moisture: float, bands: Array = MOISTURE_BANDS
) -> StringName:
	return BIOMES[_band(temperature, TEMPERATURE_BANDS)][_band(moisture, bands)]
