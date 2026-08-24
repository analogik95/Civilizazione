class_name TurnManager
extends RefCounted

## Drives the turn loop.
##
## Order within a player's turn matters: yields are recomputed before research
## consumes them, cities are processed before the treasury settles, and victory
## is checked last so a conquest registers on the turn it happens.

static func start_game(game: Node) -> void:
	game.phase = game.Phase.PLAYING
	game.turn = 1
	game.current_player_index = 0
	_begin_player_turn(game, game.current_player())
	EventBus.turn_started.emit(game.turn)


## End the current player's turn and hand control to the next. AI players
## resolve immediately, so control returns to a human without them having to
## click through anything.
static func end_turn(game: Node) -> void:
	if game.is_finished():
		return

	var player: PlayerState = game.current_player()
	if player != null:
		_end_player_turn(game, player)
		EventBus.player_turn_ended.emit(player.id)

	# Advance to the next living player, wrapping into a new game turn.
	var guard := 0
	while guard < game.player_order.size() * 2:
		guard += 1
		game.current_player_index += 1
		if game.current_player_index >= game.player_order.size():
			game.current_player_index = 0
			_advance_game_turn(game)
			if game.is_finished():
				return
		var next: PlayerState = game.current_player()
		if next != null and next.is_alive:
			_begin_player_turn(game, next)
			EventBus.player_turn_started.emit(next.id)
			return


static func _advance_game_turn(game: Node) -> void:
	EventBus.turn_ended.emit(game.turn)
	game.turn += 1

	BarbarianSystem.process_turn(game)

	if game.turn > game.turn_limit:
		VictorySystem.declare_score_victory(game)
		return

	EventBus.turn_started.emit(game.turn)


static func _begin_player_turn(game: Node, player: PlayerState) -> void:
	if player == null or not player.is_alive:
		return

	game.map.clear_visibility(player.id)

	UnitSystem.begin_turn(game, player)

	for city: CityState in game.cities_of(player.id):
		game.map.reveal_around(player.id, city.coord, 3)
		CitySystem.recompute(game, city)

	_recompute_player_yields(game, player)
	ResearchSystem.begin_turn(game, player)
	_meet_neighbours(game, player)
	ResearchSystem.check_boosts(game, player)


static func _end_player_turn(game: Node, player: PlayerState) -> void:
	for city: CityState in game.cities_of(player.id):
		CitySystem.process_turn(game, city)

	_settle_treasury(game, player)
	_accumulate_influence(game, player)
	_accumulate_great_people(game, player)
	CityStateSystem.process_loyalty(game, player)

	ResearchSystem.check_boosts(game, player)
	VictorySystem.check(game)


## Sum every city's output into the player's per-turn totals.
static func _recompute_player_yields(game: Node, player: PlayerState) -> void:
	var total := Yields.new()
	for city: CityState in game.cities_of(player.id):
		total.accumulate(city.yields)
	player.yields_per_turn = total


static func _settle_treasury(game: Node, player: PlayerState) -> void:
	_recompute_player_yields(game, player)

	var income := player.yields_per_turn.get_kind(Yields.Kind.GOLD)
	var upkeep := UnitSystem.maintenance_cost(game, player) + _building_maintenance(game, player)
	player.gold += income - upkeep
	player.faith += player.yields_per_turn.get_kind(Yields.Kind.FAITH)

	# Bankruptcy disbands units rather than allowing unbounded debt, which is
	# what keeps army size tethered to economy.
	if player.gold < 0.0:
		_handle_bankruptcy(game, player)

	_accumulate_strategic_resources(game, player)


static func _building_maintenance(game: Node, player: PlayerState) -> float:
	var total := 0.0
	for city: CityState in game.cities_of(player.id):
		for building_id: StringName in city.buildings:
			var building := ContentDB.get_building(building_id)
			if building != null:
				total += building.maintenance
	return total


static func _handle_bankruptcy(game: Node, player: PlayerState) -> void:
	var units: Array = game.units_of(player.id)
	units = units.filter(func(u: UnitState) -> bool: return u.definition().maintenance > 0)
	if units.is_empty():
		player.gold = 0.0
		return

	units.sort_custom(func(a: UnitState, b: UnitState) -> bool:
		return a.definition().combat_strength < b.definition().combat_strength)

	var disbanded: UnitState = units[0]
	game.unregister_unit(disbanded)
	EventBus.unit_killed.emit(disbanded.id, -1)
	EventBus.notification_posted.emit(
		player.id, &"bankruptcy",
		"Treasury empty — %s was disbanded." % disbanded.definition().name,
		disbanded.coord,
	)
	player.gold = 0.0


## Improved strategic resources accumulate into a per-player stockpile that
## unit production draws down.
static func _accumulate_strategic_resources(game: Node, player: PlayerState) -> void:
	for city: CityState in game.cities_of(player.id):
		for coord in city.owned_tiles:
			var tile: Tile = game.map.get_tile(coord)
			if tile == null or tile.resource_id == &"" or tile.improvement_id == &"" or tile.is_pillaged:
				continue
			var res := tile.resource()
			if res != null and res.is_strategic():
				player.add_stock(res.id, 1.0)


static func _accumulate_influence(game: Node, player: PlayerState) -> void:
	if player.kind != PlayerState.Kind.MAJOR:
		return

	var government := player.government()
	var per_turn := government.influence_per_turn if government != null else 0.0
	per_turn += game.modifiers.sum_scalar(
		ModifierEngine.EFFECT_INFLUENCE_PER_TURN, {"player": player}
	)

	player.influence += per_turn
	# Every 100 influence converts into an envoy to spend on a city-state.
	while player.influence >= 100.0:
		player.influence -= 100.0
		player.envoys_available += 1
		EventBus.notification_posted.emit(
			player.id, &"envoy", "An Envoy is available.", Vector2i.ZERO
		)


## Districts and their buildings generate Great Person points by category.
static func _accumulate_great_people(game: Node, player: PlayerState) -> void:
	if player.kind != PlayerState.Kind.MAJOR:
		return

	var percent: float = game.modifiers.sum_scalar(
		ModifierEngine.EFFECT_GREAT_PERSON_PERCENT, {"player": player}
	)
	var scale := 1.0 + percent * 0.01

	for city: CityState in game.cities_of(player.id):
		for district_id: StringName in city.districts:
			var district := ContentDB.get_district(district_id)
			if district == null:
				continue
			for category: Variant in district.great_person_points:
				player.add_great_person_points(
					StringName(str(category)), float(district.great_person_points[category]) * scale
				)
		for building_id: StringName in city.buildings:
			var building := ContentDB.get_building(building_id)
			if building == null:
				continue
			for category: Variant in building.great_person_points:
				player.add_great_person_points(
					StringName(str(category)), float(building.great_person_points[category]) * scale
				)


## Two players meet when their units or cities come within sight of each other.
## Meeting matters: it unlocks the Writing eureka and opens diplomacy.
static func _meet_neighbours(game: Node, player: PlayerState) -> void:
	var explored: Dictionary = game.map.explored.get(player.id, {})

	for other: PlayerState in game.players.values():
		if other.id == player.id or player.has_met(other.id):
			continue
		if other.kind == PlayerState.Kind.BARBARIAN:
			continue

		var found := false
		for city: CityState in game.cities_of(other.id):
			if explored.has(city.coord):
				found = true
				break
		if not found:
			for unit: UnitState in game.units_of(other.id):
				if explored.has(unit.coord):
					found = true
					break
		if not found:
			continue

		player.met_players[other.id] = true
		other.met_players[player.id] = true
		var label := "civilization" if other.kind == PlayerState.Kind.MAJOR else "city-state"
		EventBus.notification_posted.emit(
			player.id, &"met", "You have met a new %s." % label, Vector2i.ZERO
		)
