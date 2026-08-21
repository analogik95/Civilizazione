extends Node

## Headless AI-vs-AI soak runner.
##
##   godot --headless --path . -- --sim turns=200 civs=6 seed=1234
##
## This is the primary regression net. A rules engine this size cannot be
## validated by playing it — the point is to run whole games with nobody
## watching and assert that the simulation never reaches a state it should not:
## negative populations, units on impassable tiles, cities with more districts
## than their population allows, orphaned tile ownership.
##
## It also catches the failure that matters most in a 4X: an AI that stops
## doing anything. A game where nobody founds a second city or researches past
## the Ancient era is technically valid and completely broken, so the run
## reports progress statistics and fails if the world flatlines.

var _violations: PackedStringArray = []


func run(options: Dictionary) -> bool:
	var turns := int(options.get("turns", 150))
	var civs := int(options.get("civs", 6))
	var seed_value := int(options.get("seed", 20260821))
	var map_size := StringName(str(options.get("map_size", "small")))
	# Command-line options arrive as strings, so "verbose=0" must not read as true.
	var verbose := str(options.get("verbose", "0")) in ["1", "true", "yes"]

	print("\n=== Simulation: %d turns, %d civs, seed %d, %s map ===\n" % [
		turns, civs, seed_value, map_size
	])

	var start_time := Time.get_ticks_msec()

	GameSetup.new_game(Game, {
		"seed": seed_value, "civs": civs, "map_size": map_size,
		"headless": true, "turn_limit": turns, "human": -1,
	})
	TurnManager.start_game(Game)

	var turn_guard := 0
	var max_steps := turns * (Game.player_order.size() + 2)

	while Game.turn <= turns and not Game.is_finished() and turn_guard < max_steps:
		turn_guard += 1
		var player: PlayerState = Game.current_player()
		if player != null and player.is_alive and player.kind == PlayerState.Kind.MAJOR:
			AIController.take_turn(Game, player)
		TurnManager.end_turn(Game)

		if Game.turn % 25 == 0 and Game.current_player_index == 0:
			_audit(Game)
			if verbose:
				_print_snapshot(Game)

	var elapsed := Time.get_ticks_msec() - start_time

	_audit(Game)
	_print_summary(Game, elapsed)

	var progressed := _check_progress(Game, turns)

	if not _violations.is_empty():
		printerr("\n%d state violations:" % _violations.size())
		for violation in _violations:
			printerr("  %s" % violation)
		return false

	print("\nNo state violations.\n")
	return progressed


# -------------------------------------------------------------------------
# Invariants
# -------------------------------------------------------------------------

func _flag(message: String) -> void:
	# Cap the list: one systemic bug can otherwise produce thousands of lines.
	if _violations.size() < 40:
		_violations.append(message)


func _audit(game: Node) -> void:
	for city: CityState in game.cities.values():
		if city.population < 1:
			_flag("city %d (%s) has population %d" % [city.id, city.name, city.population])
		if city.owner_id < 0 or not game.players.has(city.owner_id):
			_flag("city %d has no valid owner" % city.id)
		if city.specialty_district_count() > city.district_allowance():
			_flag("city %d has %d districts but allows %d" % [
				city.id, city.specialty_district_count(), city.district_allowance()
			])
		if city.center_hp < 0 or city.center_hp > city.max_center_hp:
			_flag("city %d centre HP out of range: %d" % [city.id, city.center_hp])
		if city.loyalty < 0.0 or city.loyalty > CityState.MAX_LOYALTY:
			_flag("city %d loyalty out of range: %.1f" % [city.id, city.loyalty])
		for kind in Yields.KIND_COUNT:
			if city.yields.v[kind] < 0.0:
				_flag("city %d has negative %s" % [city.id, Yields.KIND_NAMES[kind]])

		var tile: Tile = game.map.get_tile(city.coord)
		if tile == null or not tile.is_city_center():
			_flag("city %d is not standing on its own city centre" % city.id)

	for unit: UnitState in game.units.values():
		if unit.hp <= 0:
			_flag("dead unit %d still in the game" % unit.id)
		if not game.players.has(unit.owner_id):
			_flag("unit %d has no valid owner" % unit.id)
		var unit_tile: Tile = game.map.get_tile(unit.coord)
		if unit_tile == null:
			_flag("unit %d is off the map at %s" % [unit.id, unit.coord])
		elif unit_tile.is_impassable():
			_flag("unit %d is standing on impassable terrain" % unit.id)
		elif unit_tile.is_water() and not unit.definition().is_naval() and not unit.is_embarked:
			_flag("land unit %d is in water without being embarked" % unit.id)

	# Stacking: at most one military and one civilian per tile.
	var military_at := {}
	var civilian_at := {}
	for unit: UnitState in game.units.values():
		var bucket := military_at if unit.definition().is_military() else civilian_at
		if bucket.has(unit.coord):
			_flag("two %s units stacked at %s" % [
				"military" if unit.definition().is_military() else "civilian", unit.coord
			])
		bucket[unit.coord] = unit.id

	for player: PlayerState in game.players.values():
		if player.gold < -0.01:
			_flag("player %d has negative gold: %.1f" % [player.id, player.gold])


# -------------------------------------------------------------------------
# Progress
# -------------------------------------------------------------------------

## A game where nothing happens is valid but broken. These thresholds are
## deliberately low — they catch an AI that has stopped functioning, not one
## that is merely playing badly.
func _check_progress(game: Node, turns: int) -> bool:
	if game.is_finished():
		print("Game ended early with a %s victory for player %d." % [game.victory_type, game.winner_id])
		return true

	var ok := true
	var total_cities := 0
	var max_techs := 0
	var max_era := 0
	var total_districts := 0

	for player: PlayerState in game.major_players():
		total_cities += game.cities_of(player.id).size()
		max_techs = maxi(max_techs, player.techs.size())
		max_era = maxi(max_era, player.era)
		for city: CityState in game.cities_of(player.id):
			total_districts += city.specialty_district_count()

	var majors: int = game.major_players().size()

	if turns >= 60 and total_cities <= majors:
		printerr("FAIL: after %d turns nobody founded a second city" % turns)
		ok = false
	if turns >= 60 and max_techs < 4:
		printerr("FAIL: after %d turns the research leader has only %d techs" % [turns, max_techs])
		ok = false
	if turns >= 100 and total_districts == 0:
		printerr("FAIL: after %d turns no districts have been built" % turns)
		ok = false
	if turns >= 120 and max_era < 1:
		printerr("FAIL: after %d turns nobody has left the Ancient era" % turns)
		ok = false

	return ok


# -------------------------------------------------------------------------
# Reporting
# -------------------------------------------------------------------------

func _print_snapshot(game: Node) -> void:
	print("-- turn %d --" % game.turn)
	for player: PlayerState in game.major_players():
		var leader := player.leader()
		print("   %-14s cities %2d  units %2d  techs %2d  civics %2d  gold %5d" % [
			leader.civilization if leader != null else "?",
			game.cities_of(player.id).size(),
			game.units_of(player.id).size(),
			player.techs.size(), player.civics.size(), int(player.gold),
		])


func _print_summary(game: Node, elapsed_ms: int) -> void:
	print("\n=== Final state (turn %d, %.1fs) ===" % [game.turn, elapsed_ms / 1000.0])
	print("%-16s %-14s %5s %5s %5s %6s %6s %5s %7s" % [
		"CIVILIZATION", "GOVERNMENT", "CITY", "POP", "DIST", "TECHS", "CIVICS", "ERA", "SCORE"
	])

	var players: Array = game.major_players()
	players.sort_custom(func(a: PlayerState, b: PlayerState) -> bool:
		return VictorySystem.compute_score(game, a) > VictorySystem.compute_score(game, b))

	for player: PlayerState in players:
		var leader := player.leader()
		var cities: Array = game.cities_of(player.id)
		var population := 0
		var districts := 0
		for city: CityState in cities:
			population += city.population
			districts += city.specialty_district_count()

		print("%-16s %-14s %5d %5d %5d %6d %6d %5s %7d" % [
			leader.civilization if leader != null else "?",
			player.government_id,
			cities.size(), population, districts,
			player.techs.size(), player.civics.size(),
			EmpireDefs.ERA_NAMES[player.era],
			int(VictorySystem.compute_score(game, player)),
		])

	var suzerainties := 0
	for player: PlayerState in players:
		suzerainties += player.suzerain_of.size()

	print("\nWorld: %d cities, %d units, %d suzerainties, world era %s" % [
		game.cities.size(), game.units.size(), suzerainties,
		EmpireDefs.ERA_NAMES[ResearchSystem.world_era(game)],
	])
