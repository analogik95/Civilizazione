extends Node

## Minimal assertion harness. Deliberately dependency-free — a rules engine this
## size needs its formulas pinned down, but not a whole test framework.
##
##   godot --headless --path . -- --test

var _failures: int = 0
var _assertions: int = 0
var _current_suite: String = ""
var _suite_failures: int = 0


func run_all() -> int:
	print("\n=== Civilizazione test suite ===\n")

	_run_suite("content", _test_content)
	_run_suite("hex maths", _test_hex)
	_run_suite("yields", _test_yields)
	_run_suite("modifier engine", _test_modifiers)
	_run_suite("map generation", _test_map_generation)
	_run_suite("appeal", _test_appeal)
	_run_suite("combat formula", _test_combat)
	_run_suite("city rules", _test_city_rules)
	_run_suite("district adjacency", _test_adjacency)
	_run_suite("research and boosts", _test_research)
	_run_suite("determinism", _test_determinism)

	print("\n=== %d assertions, %d failures ===\n" % [_assertions, _failures])
	return _failures


func _run_suite(name: String, fn: Callable) -> void:
	_current_suite = name
	_suite_failures = _failures
	fn.call()
	var status := "ok" if _failures == _suite_failures else "FAIL"
	print("  [%s] %s" % [status, name])


func check(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures += 1
		printerr("    FAIL (%s): %s" % [_current_suite, message])


func check_near(actual: float, expected: float, tolerance: float, message: String) -> void:
	check(absf(actual - expected) <= tolerance,
		"%s — expected %.3f +/- %.3f, got %.3f" % [message, expected, tolerance, actual])


# -------------------------------------------------------------------------

func _test_content() -> void:
	var ok := ContentDB.load_all()
	for err in ContentDB.load_errors:
		printerr("    content error: %s" % err)
	check(ok, "all content files load without errors")
	check(ContentDB.terrain.size() >= 8, "terrain types loaded")
	check(ContentDB.units.size() >= 10, "units loaded")
	check(ContentDB.districts.has(&"campus"), "campus district exists")
	check(ContentDB.techs.has(&"bronze_working"), "bronze working tech exists")
	check(ContentDB.policies.size() >= 20, "policy cards loaded")
	check(ContentDB.leaders.size() >= 6, "leaders loaded")

	# Every policy must reference a civic that exists, or a player could unlock
	# a card that can never be slotted.
	for p: EmpireDefs.PolicyDef in ContentDB.policies.values():
		check(p.required_civic == &"" or ContentDB.civics.has(p.required_civic),
			"policy %s has a valid civic" % p.id)


func _test_hex() -> void:
	check(Hex.distance(Vector2i(0, 0), Vector2i(0, 0)) == 0, "distance to self is zero")
	check(Hex.distance(Vector2i(0, 0), Vector2i(1, 0)) == 1, "adjacent tiles are distance 1")
	check(Hex.distance(Vector2i(0, 0), Vector2i(3, -1)) == 3, "known distance")

	for direction in Hex.DIRECTION_COUNT:
		var n := Hex.neighbor(Vector2i.ZERO, direction)
		check(Hex.distance(Vector2i.ZERO, n) == 1, "direction %d yields a neighbour" % direction)
		var back := Hex.neighbor(n, Hex.OPPOSITE[direction])
		check(back == Vector2i.ZERO, "opposite direction %d returns home" % direction)

	check(Hex.within_radius(Vector2i.ZERO, 1).size() == 7, "radius 1 covers 7 tiles")
	check(Hex.within_radius(Vector2i.ZERO, 2).size() == 19, "radius 2 covers 19 tiles")
	check(Hex.within_radius(Vector2i.ZERO, 3).size() == 37, "radius 3 covers 37 tiles")
	check(Hex.ring(Vector2i.ZERO, 2).size() == 12, "ring 2 has 12 tiles")

	# World-space round trip must land back on the same tile.
	for q in range(-4, 5):
		for r in range(-4, 5):
			var coord := Vector2i(q, r)
			var world := Hex.to_world(coord, 1.0)
			check(Hex.from_world(world, 1.0) == coord, "world round trip for %s" % coord)


func _test_yields() -> void:
	var a := Yields.from_dict({"food": 2, "production": 1})
	check_near(a.get_kind(Yields.Kind.FOOD), 2.0, 0.001, "food parsed")
	check_near(a.get_kind(Yields.Kind.GOLD), 0.0, 0.001, "unset yields are zero")

	var b := Yields.from_dict({"food": 1})
	a.accumulate(b)
	check_near(a.get_kind(Yields.Kind.FOOD), 3.0, 0.001, "accumulate adds")

	# Percentage modifiers stack additively, not multiplicatively: two +15%
	# cards give +30%, matching how Civ 6 sums them.
	var c := Yields.from_dict({"science": 10})
	var percents := PackedFloat32Array()
	percents.resize(Yields.KIND_COUNT)
	percents[Yields.Kind.SCIENCE] = 30.0
	c.apply_percent(percents)
	check_near(c.get_kind(Yields.Kind.SCIENCE), 13.0, 0.001, "+30% applied additively")


func _test_modifiers() -> void:
	var engine := ModifierEngine.new()
	var player := PlayerState.new(0)
	var city := CityState.new(1, 0)
	city.is_capital = true

	var capital_only := Modifier.from_dict({
		"id": "test_capital", "effect": "ADJUST_CITY_YIELD_FLAT", "scope": "city",
		"args": {"yields": {"faith": 1, "gold": 1}},
		"requirements": [{"type": "CITY_IS_CAPITAL", "args": {}}],
	})
	engine.set_source(0, &"policy", &"god_king", [capital_only] as Array[Modifier])

	var ctx := {"player": player, "city": city}
	var result := engine.city_flat_yields(ctx)
	check_near(result.get_kind(Yields.Kind.FAITH), 1.0, 0.001, "capital modifier applies to the capital")

	# The same modifier must not fire for a non-capital.
	var other := CityState.new(2, 0)
	var other_result := engine.city_flat_yields({"player": player, "city": other})
	check_near(other_result.get_kind(Yields.Kind.FAITH), 0.0, 0.001, "capital modifier skips other cities")

	# Removing the source removes the bonus, with nothing to undo by hand.
	engine.clear_source(0, &"policy", &"god_king")
	check_near(engine.city_flat_yields(ctx).get_kind(Yields.Kind.FAITH), 0.0, 0.001,
		"clearing the source removes its modifier")

	# Inverse requirements.
	var not_at_war := Modifier.from_dict({
		"id": "test_peace", "effect": "ADJUST_CITY_YIELD_FLAT", "scope": "city",
		"args": {"yields": {"science": 5}},
		"requirements": [{"type": "PLAYER_AT_WAR", "args": {}, "inverse": true}],
	})
	engine.set_source(0, &"suzerain", &"geneva", [not_at_war] as Array[Modifier])
	check_near(engine.city_flat_yields(ctx).get_kind(Yields.Kind.SCIENCE), 5.0, 0.001,
		"inverse requirement passes at peace")
	player.at_war_with[1] = true
	engine.invalidate_all()
	check_near(engine.city_flat_yields(ctx).get_kind(Yields.Kind.SCIENCE), 0.0, 0.001,
		"inverse requirement fails at war")


func _test_map_generation() -> void:
	RNGService.seed_game(12345)
	var generator := MapGenerator.new()
	var map := generator.generate(&"tiny")

	check(map.tiles.size() == map.width * map.height, "every tile in the rectangle exists")

	var land := 0
	var water := 0
	var mountains := 0
	var river_tiles := 0
	var resource_tiles := 0
	for tile: Tile in map.tiles.values():
		if tile.is_land():
			land += 1
		else:
			water += 1
		if tile.terrain_id == &"mountains":
			mountains += 1
		if tile.has_river():
			river_tiles += 1
		if tile.resource_id != &"":
			resource_tiles += 1

	var land_fraction := float(land) / float(map.tiles.size())
	check(land_fraction > 0.2 and land_fraction < 0.6,
		"land fraction is plausible (got %.2f)" % land_fraction)
	check(mountains > 0, "some mountains generated")
	check(river_tiles > 0, "some rivers generated")
	check(resource_tiles > 20, "resources placed (got %d)" % resource_tiles)

	# A river recorded from one side must be visible from the other.
	for tile: Tile in map.tiles.values():
		if not tile.has_river():
			continue
		for direction in Hex.DIRECTION_COUNT:
			if not tile.has_river_on(direction):
				continue
			var neighbour := map.neighbor_in(tile.coord, direction)
			if neighbour != null:
				check(neighbour.has_river_on(Hex.OPPOSITE[direction]),
					"river edge is symmetric at %s" % tile.coord)
			break
		break

	var starts := generator.choose_start_positions(4)
	check(starts.size() == 4, "found 4 start positions")
	for i in starts.size():
		var tile := map.get_tile(starts[i])
		check(tile != null and tile.is_land(), "start %d is on land" % i)
		check(not tile.is_impassable(), "start %d is passable" % i)
		for j in range(i + 1, starts.size()):
			check(map.distance(starts[i], starts[j]) >= 8,
				"starts %d and %d are far enough apart" % [i, j])


func _test_appeal() -> void:
	var map := MapModel.new()
	map.setup(10, 10, false)

	var center := MapModel.offset_to_axial(5, 5)
	var tile := map.get_tile(center)
	tile.terrain_id = &"grassland"

	map.recompute_appeal(center)
	var baseline := tile.appeal

	# A mountain next door should lift Appeal by exactly 1.
	var neighbour := map.neighbor_in(center, 0)
	neighbour.terrain_id = &"mountains"
	map.recompute_appeal(center)
	check(tile.appeal == baseline + 1, "adjacent mountain adds +1 Appeal")

	# A mine next door should sink it back.
	var other := map.neighbor_in(center, 1)
	other.terrain_id = &"grassland"
	other.improvement_id = &"mine"
	map.recompute_appeal(center)
	check(tile.appeal == baseline, "adjacent mine cancels the mountain")

	check(MapModel.appeal_tier(5) == &"breathtaking", "appeal 5 is breathtaking")
	check(MapModel.appeal_tier(2) == &"charming", "appeal 2 is charming")
	check(MapModel.appeal_tier(0) == &"average", "appeal 0 is average")
	check(MapModel.appeal_tier(-2) == &"uninviting", "appeal -2 is uninviting")
	check(MapModel.appeal_tier(-5) == &"disgusting", "appeal -5 is disgusting")


func _test_combat() -> void:
	# The damage curve: 30 at parity, doubling roughly every +17 strength.
	RNGService.seed_game(999)

	var at_parity := Combat.expected_damage(0.0)
	check_near(at_parity, 30.0, 0.01, "equal strength deals 30 damage")

	var plus_17 := Combat.expected_damage(17.0)
	check_near(plus_17 / at_parity, 2.0, 0.06, "+17 strength roughly doubles damage")

	var minus_17 := Combat.expected_damage(-17.0)
	check_near(minus_17 / at_parity, 0.5, 0.03, "-17 strength roughly halves damage")

	# Corps and Army bonuses are tuned against that same curve.
	check_near(Combat.expected_damage(10.0) / at_parity, 1.49, 0.06, "Corps (+10) is about 1.5x damage")

	# Randomness must stay inside the documented band.
	var min_seen := 999.0
	var max_seen := 0.0
	for _i in 400:
		var roll := Combat.roll_damage(0.0)
		min_seen = minf(min_seen, roll)
		max_seen = maxf(max_seen, roll)
	check(min_seen >= 30.0 * 0.75 - 0.5, "damage never falls below the -25%% band (got %.1f)" % min_seen)
	check(max_seen <= 30.0 * 1.25 + 0.5, "damage never exceeds the +25%% band (got %.1f)" % max_seen)

	# Class counters.
	check_near(UnitDefs.counter_bonus(UnitDefs.UnitClass.ANTI_CAVALRY, UnitDefs.UnitClass.HEAVY_CAVALRY),
		10.0, 0.001, "anti-cavalry gets +10 against heavy cavalry")
	check_near(UnitDefs.counter_bonus(UnitDefs.UnitClass.MELEE, UnitDefs.UnitClass.ANTI_CAVALRY),
		5.0, 0.001, "melee gets +5 against anti-cavalry")
	check_near(UnitDefs.counter_bonus(UnitDefs.UnitClass.HEAVY_CAVALRY, UnitDefs.UnitClass.MELEE),
		0.0, 0.001, "cavalry gets no bonus against melee")


func _test_city_rules() -> void:
	var city := CityState.new(1, 0)

	# Amenities: the first two citizens are free, then one per two citizens.
	city.population = 2
	check_near(city.compute_amenities_needed(), 0.0, 0.001, "size 2 needs no amenities")
	city.population = 3
	check_near(city.compute_amenities_needed(), 1.0, 0.001, "size 3 needs 1 amenity")
	city.population = 5
	check_near(city.compute_amenities_needed(), 2.0, 0.001, "size 5 needs 2 amenities")
	city.population = 21
	check_near(city.compute_amenities_needed(), 10.0, 0.001, "size 21 needs 10 amenities")

	# Housing pressure throttles growth as the cap approaches.
	city.population = 4
	city.housing = 10.0
	check_near(city.housing_growth_modifier(), 1.0, 0.001, "plenty of housing means full growth")
	city.housing = 5.0
	check_near(city.housing_growth_modifier(), 0.5, 0.001, "1 below the cap halves growth")
	city.housing = 4.0
	check_near(city.housing_growth_modifier(), 0.25, 0.001, "at the cap growth is quartered")
	city.housing = 2.0
	check_near(city.housing_growth_modifier(), 0.1, 0.001, "over the cap growth crawls")
	# Growth stops dead once the city is a full 5 citizens past its Housing.
	city.population = 5
	city.housing = 0.0
	check_near(city.housing_growth_modifier(), 0.0, 0.001, "5 over the cap stops growth entirely")

	# Mood buckets.
	city.population = 5
	city.amenities_needed = 2.0
	city.amenities = 5.0
	check(city.compute_mood() == CityState.Mood.ECSTATIC, "+3 surplus is ecstatic")
	city.amenities = 2.0
	check(city.compute_mood() == CityState.Mood.CONTENT, "balanced is content")
	city.amenities = 0.0
	check(city.compute_mood() == CityState.Mood.DISPLEASED, "-2 is displeased")

	# District allowance grows one per three citizens.
	city.population = 1
	check(city.district_allowance() == 1, "size 1 allows 1 district")
	city.population = 3
	check(city.district_allowance() == 2, "size 3 allows 2 districts")
	city.population = 6
	check(city.district_allowance() == 3, "size 6 allows 3 districts")

	# Growth cost must rise with size, or large cities snowball.
	city.population = 1
	var small := city.food_to_grow()
	city.population = 10
	check(city.food_to_grow() > small * 3.0, "growth cost climbs steeply with size")


func _test_adjacency() -> void:
	var map := MapModel.new()
	map.setup(12, 12, false)
	var center := MapModel.offset_to_axial(6, 6)

	for tile: Tile in map.tiles.values():
		tile.terrain_id = &"grassland"

	# A Campus gains +1 Science per adjacent mountain.
	map.neighbor_in(center, 0).terrain_id = &"mountains"
	map.neighbor_in(center, 1).terrain_id = &"mountains"
	var campus := ContentDB.get_district(&"campus")
	check_near(Adjacency.compute(map, center, campus), 2.0, 0.001, "two mountains give +2 Campus adjacency")

	# Rainforest pays out only in pairs.
	map.neighbor_in(center, 2).feature_id = &"rainforest"
	check_near(Adjacency.compute(map, center, campus), 2.0, 0.001, "one rainforest alone adds nothing")
	map.neighbor_in(center, 3).feature_id = &"rainforest"
	check_near(Adjacency.compute(map, center, campus), 3.0, 0.001, "two rainforest tiles add +1")

	# A Commercial Hub wants a river.
	var hub := ContentDB.get_district(&"commercial_hub")
	var river_site := MapModel.offset_to_axial(3, 3)
	check_near(Adjacency.compute(map, river_site, hub), 0.0, 0.001, "no river means no hub adjacency")
	map.set_river(river_site, 0, true)
	check_near(Adjacency.compute(map, river_site, hub), 2.0, 0.001, "a river gives +2 hub adjacency")


func _test_research() -> void:
	var player := PlayerState.new(0)
	player.leader_id = &"rome_caesar"

	var tech := ContentDB.get_tech(&"bronze_working")
	check(tech != null, "bronze working loaded")
	check(tech.has_boost(), "bronze working has a Eureka")

	# A boost pays out 40% of the node's cost, and only once.
	check(player.mark_boosted(&"tech", &"bronze_working"), "boost fires the first time")
	check(not player.mark_boosted(&"tech", &"bronze_working"), "boost does not fire twice")
	check(player.is_boosted(&"tech", &"bronze_working"), "boost is recorded")

	# Cost scales with how far ahead of the world era you are researching.
	var behind := player.node_cost(tech, 3)
	var ahead := player.node_cost(tech, 0)
	check(behind < ahead, "researching a stale tech is cheaper than a cutting-edge one")

	# Policy slots follow the government.
	player.government_id = &"chiefdom"
	check(player.policy_slots().size() == 2, "chiefdom has 2 slots")
	player.government_id = &"oligarchy"
	check(player.policy_slots().size() == 4, "oligarchy has 4 slots")
	check(player.policy_slots().count(&"wildcard") == 1, "oligarchy has 1 wildcard slot")

	# A military card fits a military slot and a wildcard, but not an economic one.
	var discipline := ContentDB.get_policy(&"discipline")
	check(discipline.fits_slot(&"military"), "military card fits a military slot")
	check(discipline.fits_slot(&"wildcard"), "military card fits a wildcard slot")
	check(not discipline.fits_slot(&"economic"), "military card does not fit an economic slot")


func _test_determinism() -> void:
	# The same seed must produce the same world, or AI debugging and save/reload
	# both become guesswork.
	var signatures: Array[String] = []
	for _run in 2:
		RNGService.seed_game(777)
		var map := MapGenerator.new().generate(&"duel")
		var parts: PackedStringArray = []
		var coords: Array = map.tiles.keys()
		coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.x < b.x if a.x != b.x else a.y < b.y)
		for coord: Vector2i in coords:
			var tile: Tile = map.tiles[coord]
			parts.append("%s%s%s%d" % [tile.terrain_id, tile.feature_id, tile.resource_id, tile.river_edges])
		signatures.append("".join(parts).md5_text())
	check(signatures[0] == signatures[1], "same seed produces an identical map")

	# Separate streams must not interfere: drawing from one should not shift
	# the other.
	RNGService.seed_game(555)
	var combat_first := RNGService.stream(RNGService.STREAM_COMBAT).randf()
	RNGService.seed_game(555)
	RNGService.stream(RNGService.STREAM_AI).randf()
	RNGService.stream(RNGService.STREAM_MAP).randf()
	var combat_after := RNGService.stream(RNGService.STREAM_COMBAT).randf()
	check_near(combat_first, combat_after, 0.0000001, "RNG streams are independent")
