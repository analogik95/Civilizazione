class_name GameSetup
extends RefCounted

## Builds a new game: map, players, city-states, barbarians, starting units.

const DEFAULT_CITY_STATE_COUNT := 6
const STARTING_GOLD := 50.0

## Difficulty bonuses go to the AI, as in Civ 6 — the ladder works by giving
## opponents a head start rather than by making their decision logic sharper.
const DIFFICULTY_YIELD_BONUS := {
	&"settler": -0.2, &"chieftain": -0.1, &"warlord": 0.0,
	&"prince": 0.0, &"king": 0.15, &"emperor": 0.3,
	&"immortal": 0.5, &"deity": 0.8,
}


static func new_game(game: Node, options: Dictionary = {}) -> void:
	var seed_value := int(options.get("seed", randi()))
	var civ_count := int(options.get("civs", 6))
	var city_state_count := int(options.get("city_states", DEFAULT_CITY_STATE_COUNT))
	var map_size := StringName(str(options.get("map_size", "standard")))
	var difficulty := StringName(str(options.get("difficulty", "prince")))
	var human_player := int(options.get("human", 0))

	game.reset()
	game.headless = bool(options.get("headless", false))
	game.turn_limit = int(options.get("turn_limit", 500))

	RNGService.seed_game(seed_value)
	BarbarianSystem.reset()

	var generator := MapGenerator.new()
	game.map = generator.generate(map_size)

	_create_players(game, civ_count, difficulty, human_player)
	_create_city_states(game, city_state_count)
	_create_barbarians(game)
	_create_free_cities(game)

	_place_starts(game, generator, civ_count, city_state_count)

	game.phase = game.Phase.SETUP


static func _create_players(game: Node, count: int, difficulty: StringName, human_player: int) -> void:
	var available: Array = ContentDB.leaders.values()
	var shuffled := available.duplicate()
	for i in range(shuffled.size() - 1, 0, -1):
		var j := RNGService.randi_range_in(RNGService.STREAM_MISC, 0, i)
		var tmp: Variant = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = tmp

	var bonus: float = DIFFICULTY_YIELD_BONUS.get(difficulty, 0.0)

	for i in count:
		var player := PlayerState.new(i, PlayerState.Kind.MAJOR)
		var leader: EmpireDefs.LeaderDef = shuffled[i % shuffled.size()]
		player.leader_id = leader.id
		player.is_human = i == human_player
		player.color_primary = leader.color_primary
		player.color_secondary = leader.color_secondary
		player.gold = STARTING_GOLD
		player.difficulty_bonus = 0.0 if player.is_human else bonus

		game.players[player.id] = player
		game.player_order.append(player.id)

		game.modifiers.set_source(player.id, &"leader", leader.id, leader.modifiers)

		var government := ContentDB.get_government(&"chiefdom")
		if government != null:
			game.modifiers.set_source(player.id, &"government", government.id, government.modifiers)

		# The AI's head start is a flat yield multiplier applied through the
		# same modifier system as everything else, so it shows up in tooltips
		# rather than being hidden in the simulation.
		if not is_zero_approx(player.difficulty_bonus):
			var handicap := Modifier.new(&"difficulty_handicap", ModifierEngine.EFFECT_CITY_YIELD_PERCENT)
			handicap.scope = Modifier.Scope.CITY
			var percent := player.difficulty_bonus * 100.0
			handicap.args = {"percent": {
				"production": percent, "gold": percent,
				"science": percent, "culture": percent,
			}}
			handicap.description = "Difficulty handicap"
			game.modifiers.set_source(player.id, &"difficulty", &"handicap", [handicap] as Array[Modifier])


static func _create_city_states(game: Node, count: int) -> void:
	var available: Array = ContentDB.city_states.values()
	if available.is_empty():
		return
	var shuffled := available.duplicate()
	for i in range(shuffled.size() - 1, 0, -1):
		var j := RNGService.randi_range_in(RNGService.STREAM_MISC, 0, i)
		var tmp: Variant = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = tmp

	var next_id: int = game.player_order.size()
	for i in mini(count, shuffled.size()):
		var def: EmpireDefs.CityStateDef = shuffled[i]
		var player := PlayerState.new(next_id + i, PlayerState.Kind.CITY_STATE)
		player.city_state_id = def.id
		player.color_primary = Color(0.65, 0.65, 0.7)
		game.players[player.id] = player
		game.player_order.append(player.id)


static func _create_barbarians(game: Node) -> void:
	var id: int = game.player_order.size() + 100
	var player := PlayerState.new(id, PlayerState.Kind.BARBARIAN)
	player.color_primary = Color(0.75, 0.2, 0.15)
	# Barbarians keep pace enough to stay a threat past the opening.
	player.techs[&"archery"] = true
	player.techs[&"bronze_working"] = true
	game.players[id] = player


static func _create_free_cities(game: Node) -> void:
	var id: int = game.player_order.size() + 101
	var player := PlayerState.new(id, PlayerState.Kind.FREE_CITY)
	player.color_primary = Color(0.5, 0.5, 0.5)
	game.players[id] = player


static func _place_starts(game: Node, generator: MapGenerator, civ_count: int, city_state_count: int) -> void:
	var total := civ_count + city_state_count
	var starts := generator.choose_start_positions(total)

	var index := 0
	for player_id in game.player_order:
		if index >= starts.size():
			break
		var player: PlayerState = game.players[player_id]
		var coord: Vector2i = starts[index]
		index += 1

		if player.kind == PlayerState.Kind.MAJOR:
			UnitSystem.spawn(game, player, &"settler", coord)
			UnitSystem.spawn(game, player, &"warrior", coord)
			# Higher difficulties hand the AI extra opening units, matching how
			# Civ 6 scales its ladder.
			if player.difficulty_bonus >= 0.3:
				UnitSystem.spawn(game, player, &"builder", coord)
			if player.difficulty_bonus >= 0.5:
				UnitSystem.spawn(game, player, &"settler", coord)
			game.map.reveal_around(player.id, coord, 4)
		else:
			# City-states start as a founded city rather than a settler.
			var city := CitySystem.found_city(game, player, coord, _city_state_name(player))
			if city != null:
				city.population = 3
				CitySystem.auto_assign_citizens(game, city)
			UnitSystem.spawn(game, player, &"warrior", coord)
			game.map.reveal_around(player.id, coord, 3)


static func _city_state_name(player: PlayerState) -> String:
	var def := ContentDB.get_city_state(player.city_state_id)
	return def.name if def != null else "City-State"
