class_name Adjacency
extends RefCounted

## Computes a district's adjacency bonus from the six tiles around it.
##
## This is the placement puzzle at the centre of the game: a Campus wedged
## against three mountains is worth several times one dropped on open grassland,
## so where a district goes matters more than when it is built. Rules are data,
## not code — a district's `adjacency` array in data/districts.json lists what it
## cares about and how much each source is worth.
##
## Sources come in three sizes, mirroring Civ 6: major (+2), standard (+1) and
## minor (+0.5). Some sources only pay out in groups — a Campus gets +1 per
## *two* adjacent Rainforest tiles — which the `per` field expresses.

## Recompute for a district placed (or being considered) at `coord`.
## `city` and `engine` are optional; pass them to include modifier-engine
## bonuses such as the Natural Philosophy policy card.
static func compute(
	map: MapModel,
	coord: Vector2i,
	district: CityDefs.DistrictDef,
	city: CityState = null,
	player: PlayerState = null,
	engine: ModifierEngine = null,
) -> float:
	if district == null or district.adjacency_rules.is_empty():
		return 0.0

	var neighbours := map.neighbors(coord)
	var self_tile := map.get_tile(coord)
	var total := 0.0

	for rule: Variant in district.adjacency_rules:
		if not (rule is Dictionary):
			continue
		var kind := StringName(str(rule.get("kind", "")))
		var amount := float(rule.get("amount", 1.0))
		var per := maxi(1, int(rule.get("per", 1)))
		var wanted := _names(rule.get("match", []))

		var matches := 0
		match kind:
			&"terrain":
				for n in neighbours:
					if wanted.has(n.terrain_id):
						matches += 1
			&"feature":
				for n in neighbours:
					if wanted.has(n.feature_id):
						matches += 1
			&"natural_wonder":
				for n in neighbours:
					if n.natural_wonder_id != &"":
						matches += 1
			&"resource":
				for n in neighbours:
					if n.resource_id != &"" and (wanted.is_empty() or wanted.has(n.resource_id)):
						matches += 1
			&"sea_resource":
				for n in neighbours:
					if n.resource_id != &"" and n.is_water():
						matches += 1
			&"improvement":
				for n in neighbours:
					if wanted.has(n.improvement_id) and not n.is_pillaged:
						matches += 1
			&"wonder":
				for n in neighbours:
					if n.wonder_id != &"":
						matches += 1
			&"district":
				for n in neighbours:
					if not n.has_district():
						continue
					if wanted.is_empty() or wanted.has(n.district_id):
						matches += 1
			&"river":
				# The river is on this tile's own edge, not a neighbour's.
				if self_tile != null and self_tile.has_river():
					matches = 1

		total += floor(float(matches) / float(per)) * amount

	# A Government Plaza next door strengthens whatever is built beside it.
	for n in neighbours:
		if not n.has_district():
			continue
		var neighbour_def := ContentDB.get_district(n.district_id)
		if neighbour_def != null:
			total += neighbour_def.get_float("amplifies_adjacent_districts", 0.0)

	if engine != null and player != null:
		total += engine.district_adjacency({
			"player": player, "city": city, "tile": self_tile,
			"district_id": district.id,
		})

	return total


static func _names(value: Variant) -> Array:
	var out: Array = []
	if value is Array:
		for item: Variant in value:
			out.append(StringName(str(item)))
	elif str(value) != "":
		out.append(StringName(str(value)))
	return out


## The yield a district's adjacency actually produces.
static func compute_yields(
	map: MapModel,
	coord: Vector2i,
	district: CityDefs.DistrictDef,
	city: CityState = null,
	player: PlayerState = null,
	engine: ModifierEngine = null,
) -> Yields:
	var amount := compute(map, coord, district, city, player, engine)
	var out := Yields.new()
	if not is_zero_approx(amount):
		out.set_kind(district.adjacency_yield(), amount)
	return out


## Score every legal site for a district in one city, best first. Drives both
## the player's placement preview and the AI's siting decisions.
static func rank_sites(
	map: MapModel,
	city: CityState,
	district: CityDefs.DistrictDef,
	player: PlayerState = null,
	engine: ModifierEngine = null,
) -> Array:
	var out: Array = []
	for coord in city.owned_tiles:
		if not is_valid_site(map, city, coord, district):
			continue
		out.append({
			"coord": coord,
			"adjacency": compute(map, coord, district, city, player, engine),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["adjacency"] > b["adjacency"])
	return out


static func is_valid_site(
	map: MapModel, city: CityState, coord: Vector2i, district: CityDefs.DistrictDef
) -> bool:
	var tile := map.get_tile(coord)
	if tile == null or not tile.is_buildable():
		return false
	if tile.coord == city.coord:
		return false   # the City Center already occupies it
	if district.requires_coast and not map.is_coastal(coord):
		return false
	if district.requires_river and not tile.has_river():
		return false
	if district.requires_adjacent_city_center:
		if map.distance(coord, city.coord) != 1:
			return false
	# Aqueducts additionally need a water source to draw from.
	if district.id == &"aqueduct" and not map.has_fresh_water(coord):
		return false
	return true
