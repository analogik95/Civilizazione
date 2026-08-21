class_name CitySystem
extends RefCounted

## Founding cities, computing their yields, growing them, and turning
## production into things.
##
## The yield pipeline is the important part and runs in a fixed order:
##
##   1. worked tiles (the city centre always works its own tile for free)
##   2. district adjacency
##   3. buildings and wonders
##   4. flat modifier bonuses  (policy cards, beliefs, leader abilities)
##   5. percentage modifiers   (must see the finished flat total)
##   6. mood and loyalty multipliers
##
## Getting 4 and 5 the wrong way round is the classic bug: a +15% Science card
## would silently ignore the Library it was meant to amplify.

const BORDER_GROWTH_CULTURE_BASE := 15.0


# -------------------------------------------------------------------------
# Founding
# -------------------------------------------------------------------------

static func found_city(game: Node, player: PlayerState, coord: Vector2i, city_name: String = "") -> CityState:
	var map: MapModel = game.map
	var tile := map.get_tile(coord)
	if tile == null or not tile.is_land() or tile.has_district():
		return null

	var city := CityState.new(game.next_city_id(), player.id, coord)
	city.name = city_name if city_name != "" else _next_city_name(game, player)
	city.has_fresh_water = map.has_fresh_water(coord)
	city.is_coastal = map.is_coastal(coord)

	# The first city a player founds is their capital and gets the Palace.
	if player.capital_city_id < 0:
		city.is_capital = true
		player.capital_city_id = city.id
		city.buildings[&"palace"] = true
		player.original_capitals_held[player.id] = true

	# The City Center is itself a district, which is why building beside it
	# earns adjacency.
	city.districts[&"city_center"] = coord
	tile.district_id = &"city_center"
	tile.district_city_id = city.id

	game.register_city(city)

	# Claim the centre and its first ring immediately; the rest comes with
	# culture.
	for t in map.tiles_within(coord, 1):
		_claim_tile(game, city, t.coord)

	map.reveal_around(player.id, coord, 3)
	recompute(game, city)
	auto_assign_citizens(game, city)

	EventBus.city_founded.emit(city.id)
	return city


static func _claim_tile(game: Node, city: CityState, coord: Vector2i) -> void:
	var tile: Tile = game.map.get_tile(coord)
	if tile == null or tile.owner_id != -1:
		return
	tile.owner_id = city.owner_id
	tile.owning_city_id = city.id
	if not city.owned_tiles.has(coord):
		city.owned_tiles.append(coord)
	EventBus.tile_ownership_changed.emit(coord, city.owner_id)


## Expand the border to the best unclaimed tile in range, paid for by culture.
static func grow_border(game: Node, city: CityState) -> bool:
	var map: MapModel = game.map
	var best: Vector2i = Vector2i(-9999, -9999)
	var best_score := -INF

	for t in map.tiles_within(city.coord, MapModel.CITY_WORK_RADIUS):
		if t.owner_id != -1:
			continue
		var score := _tile_desirability(t)
		# Prefer tiles close to the centre so borders grow outward in rings
		# rather than reaching for a distant luxury first.
		score -= map.distance(city.coord, t.coord) * 0.5
		if score > best_score:
			best_score = score
			best = t.coord

	if best.x == -9999:
		return false
	_claim_tile(game, city, best)
	return true


static func _tile_desirability(tile: Tile) -> float:
	var y := tile.base_yields()
	var score := (
		y.get_kind(Yields.Kind.FOOD) * 1.0
		+ y.get_kind(Yields.Kind.PRODUCTION) * 1.1
		+ y.get_kind(Yields.Kind.GOLD) * 0.5
		+ y.get_kind(Yields.Kind.SCIENCE) * 0.9
		+ y.get_kind(Yields.Kind.CULTURE) * 0.9
		+ y.get_kind(Yields.Kind.FAITH) * 0.7
	)
	var res := tile.resource()
	if res != null:
		score += 3.0 if res.is_luxury() else (2.5 if res.is_strategic() else 1.0)
	return score


static func _next_city_name(game: Node, player: PlayerState) -> String:
	var leader := player.leader()
	var civ := leader.civilization if leader != null else "City"
	var count: int = game.cities_of(player.id).size() + 1
	return "%s %d" % [civ, count]


# -------------------------------------------------------------------------
# Citizen assignment
# -------------------------------------------------------------------------

## Put every citizen on the best available tile.
##
## Weighting shifts with the city's situation: a city that cannot feed itself
## values Food far above everything else, which stops the AI starving cities by
## chasing Science.
static func auto_assign_citizens(game: Node, city: CityState) -> void:
	var map: MapModel = game.map
	var starving := city.yields.get_kind(Yields.Kind.FOOD) < city.food_consumption()

	var candidates: Array = []
	for coord in city.owned_tiles:
		if coord == city.coord:
			continue   # the centre is worked for free
		var tile := map.get_tile(coord)
		if tile == null or tile.is_impassable():
			continue
		if tile.worked_by_city_id != -1 and tile.worked_by_city_id != city.id:
			continue
		candidates.append({"coord": coord, "score": _work_score(tile, starving)})

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"])

	# Release last turn's assignment before reassigning.
	for coord in city.worked_tiles:
		var tile := map.get_tile(coord)
		if tile != null and tile.worked_by_city_id == city.id:
			tile.worked_by_city_id = -1
	city.worked_tiles.clear()

	for i in mini(city.population, candidates.size()):
		var coord: Vector2i = candidates[i]["coord"]
		city.worked_tiles.append(coord)
		map.get_tile(coord).worked_by_city_id = city.id


static func _work_score(tile: Tile, starving: bool) -> float:
	var y := tile.base_yields()
	var food := y.get_kind(Yields.Kind.FOOD)
	var score := (
		food * (3.0 if starving else 1.2)
		+ y.get_kind(Yields.Kind.PRODUCTION) * 1.3
		+ y.get_kind(Yields.Kind.GOLD) * 0.6
		+ y.get_kind(Yields.Kind.SCIENCE) * 1.1
		+ y.get_kind(Yields.Kind.CULTURE) * 1.0
		+ y.get_kind(Yields.Kind.FAITH) * 0.8
	)
	# A district tile is worked automatically for its own output; putting a
	# citizen on it as well is what the specialist slots are for.
	if tile.has_district():
		score += 1.0
	return score


# -------------------------------------------------------------------------
# The yield pipeline
# -------------------------------------------------------------------------

static func recompute(game: Node, city: CityState) -> void:
	var map: MapModel = game.map
	var player: PlayerState = game.get_player(city.owner_id)
	if player == null:
		return

	var total := Yields.new()

	# 1. Worked tiles. The city centre always works its own tile, and gets a
	#    floor of 1 Food / 1 Production so a city on snow is still viable.
	var center := map.get_tile(city.coord)
	if center != null:
		var center_yield := center.base_yields()
		center_yield.set_kind(Yields.Kind.FOOD, maxf(center_yield.get_kind(Yields.Kind.FOOD), 1.0))
		center_yield.set_kind(Yields.Kind.PRODUCTION, maxf(center_yield.get_kind(Yields.Kind.PRODUCTION), 1.0))
		total.accumulate(center_yield)

	for coord in city.worked_tiles:
		var tile := map.get_tile(coord)
		if tile != null:
			total.accumulate(tile.base_yields())

	# 2. Districts: their own yield plus their adjacency.
	var housing := _base_housing(city)
	var amenities := 0.0

	for district_id: StringName in city.districts:
		var district := ContentDB.get_district(district_id)
		if district == null:
			continue
		var district_coord: Vector2i = city.districts[district_id]
		total.accumulate(district.base_yields())
		if district_id != &"city_center":
			total.accumulate(Adjacency.compute_yields(
				map, district_coord, district, city, player, game.modifiers
			))
		# An Aqueduct's whole purpose is Housing, and it gives more to a city
		# that had no fresh water of its own.
		if district_id == &"aqueduct":
			housing += 2.0 if city.has_fresh_water else 6.0

	# 3. Buildings and wonders.
	for building_id: StringName in city.buildings:
		var building := ContentDB.get_building(building_id)
		if building == null:
			continue
		total.accumulate(building.base_yields())
		housing += building.housing
		amenities += building.amenities

	for wonder_id: StringName in city.wonders:
		var wonder: CityDefs.WonderDef = ContentDB.wonders.get(wonder_id)
		if wonder != null:
			total.accumulate(wonder.base_yields())

	var ctx := {"player": player, "city": city, "tile": center}

	# 4. Flat modifier bonuses.
	total.accumulate(game.modifiers.city_flat_yields(ctx))
	housing += game.modifiers.city_housing(ctx)
	amenities += game.modifiers.city_amenities(ctx)

	# 5. Percentage modifiers, applied to the finished flat total.
	total.apply_percent(game.modifiers.city_yield_percent(ctx))

	# 6. Mood and loyalty scale everything except Food, which is governed by
	#    its own housing/mood growth multiplier instead.
	var scale := city.mood_yield_modifier() * city.loyalty_yield_modifier()
	if not is_equal_approx(scale, 1.0):
		var food := total.get_kind(Yields.Kind.FOOD)
		total = total.scaled(scale)
		total.set_kind(Yields.Kind.FOOD, food)

	amenities += _luxury_amenities(game, player, city)

	city.yields = total
	city.housing = housing
	city.amenities = amenities
	city.amenities_needed = city.compute_amenities_needed()
	city.mood = city.compute_mood()
	city.defense_strength = Combat.city_defense_strength(game, city)

	_sync_walls(city)


static func _base_housing(city: CityState) -> float:
	var housing := CityState.BASE_HOUSING_NO_WATER
	if city.has_fresh_water:
		housing = CityState.BASE_HOUSING_FRESH_WATER
	elif city.is_coastal:
		housing += CityState.BASE_HOUSING_COASTAL
	return housing


## Each distinct luxury a player controls supplies one Amenity to the cities
## that need it most, up to four of them.
static func _luxury_amenities(game: Node, player: PlayerState, city: CityState) -> float:
	var owned := luxuries_controlled(game, player)
	if owned.is_empty():
		return 0.0

	var cities: Array = game.cities_of(player.id)
	cities.sort_custom(func(a: CityState, b: CityState) -> bool:
		return a.compute_amenities_needed() > b.compute_amenities_needed())

	var rank := cities.find(city)
	if rank == -1 or rank >= 4:
		return 0.0
	return float(owned.size())


static func luxuries_controlled(game: Node, player: PlayerState) -> Dictionary:
	var owned := {}
	for city: CityState in game.cities_of(player.id):
		for coord in city.owned_tiles:
			var tile: Tile = game.map.get_tile(coord)
			if tile == null or tile.resource_id == &"" or tile.improvement_id == &"":
				continue
			var res := tile.resource()
			if res != null and res.is_luxury():
				owned[res.id] = true
	return owned


static func _sync_walls(city: CityState) -> void:
	var wall_hp := 0
	for building_id: StringName in city.buildings:
		var building := ContentDB.get_building(building_id)
		if building != null:
			wall_hp += building.defense
	if wall_hp != city.max_wall_hp:
		# Building new walls repairs and extends the existing pool.
		var gained := wall_hp - city.max_wall_hp
		city.max_wall_hp = wall_hp
		city.wall_hp = clampi(city.wall_hp + maxi(gained, 0), 0, wall_hp)


# -------------------------------------------------------------------------
# Per-turn processing
# -------------------------------------------------------------------------

static func process_turn(game: Node, city: CityState) -> void:
	var player: PlayerState = game.get_player(city.owner_id)
	if player == null:
		return

	city.turns_since_founded += 1
	recompute(game, city)

	_process_growth(game, city)
	_process_production(game, city, player)
	_process_border_growth(game, city)
	_process_healing(city)


static func _process_growth(game: Node, city: CityState) -> void:
	var surplus := city.yields.get_kind(Yields.Kind.FOOD) - city.food_consumption()
	surplus *= city.housing_growth_modifier() * city.mood_growth_modifier()

	city.food_stored += surplus

	if city.food_stored >= city.food_to_grow():
		city.food_stored -= city.food_to_grow()
		city.population += 1
		auto_assign_citizens(game, city)
		EventBus.city_population_changed.emit(city.id, city.population)
		EventBus.notification_posted.emit(
			city.owner_id, &"growth", "%s has grown to %d." % [city.name, city.population], city.coord
		)
	elif city.food_stored < 0.0:
		# Starvation: shrink rather than carry a negative store forward.
		city.food_stored = 0.0
		if city.population > 1:
			city.population -= 1
			auto_assign_citizens(game, city)
			EventBus.city_population_changed.emit(city.id, city.population)
			EventBus.notification_posted.emit(
				city.owner_id, &"starving", "%s is starving." % city.name, city.coord
			)


static func _process_production(game: Node, city: CityState, player: PlayerState) -> void:
	if city.production_item == &"":
		return

	var per_turn := city.yields.get_kind(Yields.Kind.PRODUCTION)
	var percent: float = game.modifiers.production_percent({
		"player": player, "city": city,
		"production_kind": _kind_name(city.production_kind),
		"production_item": city.production_item,
	})
	per_turn *= 1.0 + percent * 0.01

	city.production_progress += per_turn
	if city.production_progress < city.production_cost():
		return

	city.production_progress -= city.production_cost()
	_complete_production(game, city, player)


static func _kind_name(kind: CityState.ProductionKind) -> StringName:
	match kind:
		CityState.ProductionKind.UNIT: return &"unit"
		CityState.ProductionKind.BUILDING: return &"building"
		CityState.ProductionKind.DISTRICT: return &"district"
		CityState.ProductionKind.WONDER: return &"wonder"
	return &"project"


static func _complete_production(game: Node, city: CityState, player: PlayerState) -> void:
	var kind := city.production_kind
	var item := city.production_item

	match kind:
		CityState.ProductionKind.UNIT:
			UnitSystem.spawn(game, player, item, city.coord)
			var unit_def := ContentDB.get_unit(item)
			# A Settler costs a citizen, which is what stops runaway expansion
			# from being free.
			if unit_def != null and unit_def.population_cost > 0 and city.population > 1:
				city.population -= unit_def.population_cost
				auto_assign_citizens(game, city)
			if unit_def != null and unit_def.required_resource != &"":
				player.add_stock(unit_def.required_resource, -unit_def.resource_cost)

		CityState.ProductionKind.BUILDING:
			city.buildings[item] = true
			EventBus.building_built.emit(city.id, item)
			var building := ContentDB.get_building(item)
			if building != null and not building.modifiers.is_empty():
				game.modifiers.set_source(
					player.id, &"building", StringName("%s@%d" % [item, city.id]), building.modifiers
				)

		CityState.ProductionKind.DISTRICT:
			# The site was chosen when the district was queued.
			var coord: Vector2i = city.production_queue.pop_front() if not city.production_queue.is_empty() else city.coord
			_place_district(game, city, item, coord)

		CityState.ProductionKind.WONDER:
			city.wonders[item] = true
			var wonder: CityDefs.WonderDef = ContentDB.wonders.get(item)
			if wonder != null and not wonder.modifiers.is_empty():
				game.modifiers.set_source(player.id, &"wonder", item, wonder.modifiers)

	EventBus.city_production_completed.emit(city.id, _kind_name(kind), item)
	city.production_item = &""
	recompute(game, city)


static func _place_district(game: Node, city: CityState, district_id: StringName, coord: Vector2i) -> void:
	var tile: Tile = game.map.get_tile(coord)
	if tile == null or tile.has_district():
		return
	city.districts[district_id] = coord
	tile.district_id = district_id
	tile.district_city_id = city.id
	# Districts change the Appeal of everything around them, so refresh the
	# neighbourhood rather than just this tile.
	game.map.recompute_appeal_around(coord, 2)
	EventBus.district_built.emit(city.id, coord, district_id)


static func _process_border_growth(game: Node, city: CityState) -> void:
	# Culture spent on borders scales with how much territory the city already
	# holds, so sprawl slows naturally.
	var threshold := BORDER_GROWTH_CULTURE_BASE + city.owned_tiles.size() * 6.0
	var culture := city.yields.get_kind(Yields.Kind.CULTURE)
	if culture <= 0.0:
		return
	if city.turns_since_founded * culture >= threshold * (city.owned_tiles.size() - 6):
		grow_border(game, city)


static func _process_healing(city: CityState) -> void:
	if city.wall_hp < city.max_wall_hp:
		city.wall_hp = mini(city.max_wall_hp, city.wall_hp + 10)
	if city.center_hp < city.max_center_hp:
		city.center_hp = mini(city.max_center_hp, city.center_hp + 15)


# -------------------------------------------------------------------------
# Conquest
# -------------------------------------------------------------------------

static func capture_city(game: Node, city: CityState, new_owner: PlayerState) -> void:
	var old_owner_id := city.owner_id
	var old_owner: PlayerState = game.get_player(old_owner_id)

	# Detach every modifier the previous owner had sourced from this city.
	if old_owner != null:
		for building_id: StringName in city.buildings:
			game.modifiers.clear_source(
				old_owner_id, &"building", StringName("%s@%d" % [building_id, city.id])
			)
		if city.is_capital:
			old_owner.original_capitals_held.erase(old_owner_id)

	game.reassign_city(city, new_owner.id)
	# A captured city keeps its walls but starts badly disloyal, which is the
	# whole cost of conquest: holding it is harder than taking it.
	city.loyalty = 50.0
	city.center_hp = int(city.max_center_hp * 0.5)
	city.wall_hp = 0
	city.population = maxi(1, city.population - 1)
	city.is_capital = false

	for coord in city.owned_tiles:
		var tile: Tile = game.map.get_tile(coord)
		if tile != null:
			tile.owner_id = new_owner.id

	# The original capital is what the Domination victory tracks, so ownership
	# of it transfers with the city.
	if city.original_owner_id == old_owner_id:
		new_owner.original_capitals_held[old_owner_id] = true

	for building_id: StringName in city.buildings:
		var building := ContentDB.get_building(building_id)
		if building != null and not building.modifiers.is_empty():
			game.modifiers.set_source(
				new_owner.id, &"building", StringName("%s@%d" % [building_id, city.id]), building.modifiers
			)

	if old_owner != null and game.cities_of(old_owner_id).is_empty():
		old_owner.is_alive = false

	recompute(game, city)
	EventBus.city_captured.emit(city.id, old_owner_id, new_owner.id)


# -------------------------------------------------------------------------
# Build options
# -------------------------------------------------------------------------

## Everything this city could start producing right now.
static func available_production(game: Node, city: CityState) -> Array:
	var player: PlayerState = game.get_player(city.owner_id)
	if player == null:
		return []
	var out: Array = []

	for unit_def: UnitDefs.UnitDef in ContentDB.units.values():
		if not _unlocked(player, unit_def.required_tech, unit_def.required_civic):
			continue
		if not player.can_afford_resource(unit_def.required_resource, unit_def.resource_cost):
			continue
		out.append({"kind": CityState.ProductionKind.UNIT, "id": unit_def.id, "cost": unit_def.cost})

	for district_def: CityDefs.DistrictDef in ContentDB.districts.values():
		if district_def.id == &"city_center" or city.has_district(district_def.id):
			continue
		if not _unlocked(player, district_def.required_tech, district_def.required_civic):
			continue
		if district_def.is_specialty and not city.can_build_another_district():
			continue
		if district_def.one_per_civ and _player_has_district(game, player, district_def.id):
			continue
		if Adjacency.rank_sites(game.map, city, district_def, player, game.modifiers).is_empty():
			continue
		out.append({"kind": CityState.ProductionKind.DISTRICT, "id": district_def.id, "cost": district_def.cost})

	for building_def: CityDefs.BuildingDef in ContentDB.buildings.values():
		if city.has_building(building_def.id) or building_def.cost <= 0:
			continue
		if not _unlocked(player, building_def.required_tech, building_def.required_civic):
			continue
		if building_def.district_id != &"" and not city.has_district(building_def.district_id):
			continue
		if building_def.required_building != &"" and not city.has_building(building_def.required_building):
			continue
		out.append({"kind": CityState.ProductionKind.BUILDING, "id": building_def.id, "cost": building_def.cost})

	for wonder_def: CityDefs.WonderDef in ContentDB.wonders.values():
		if not _unlocked(player, wonder_def.required_tech, wonder_def.required_civic):
			continue
		if _wonder_built_anywhere(game, wonder_def.id):
			continue
		out.append({"kind": CityState.ProductionKind.WONDER, "id": wonder_def.id, "cost": wonder_def.cost})

	return out


static func _unlocked(player: PlayerState, tech: StringName, civic: StringName) -> bool:
	if tech != &"" and not player.has_tech(tech):
		return false
	if civic != &"" and not player.has_civic(civic):
		return false
	return true


static func _player_has_district(game: Node, player: PlayerState, district_id: StringName) -> bool:
	for city: CityState in game.cities_of(player.id):
		if city.has_district(district_id):
			return true
	return false


## Wonders are unique across the whole game, not merely per player.
static func _wonder_built_anywhere(game: Node, wonder_id: StringName) -> bool:
	for city: CityState in game.cities.values():
		if city.wonders.has(wonder_id):
			return true
	return false
