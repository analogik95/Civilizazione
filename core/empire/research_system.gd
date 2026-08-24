class_name ResearchSystem
extends RefCounted

## The technology and civic trees, and the boost system that makes them
## interesting.
##
## Every node carries a Eureka (tech) or Inspiration (civic): a specific action
## that, when performed, immediately grants 40% of the node's cost. That single
## mechanic is what stops research being a passive drip — it rewards playing
## toward what you are researching rather than merely waiting for it.
##
## Boosts can fire before you begin researching a node, banking the discount.

## Fraction of a node's cost a boost grants.
const BOOST_FRACTION := EmpireDefs.BOOST_FRACTION


static func begin_turn(game: Node, player: PlayerState) -> void:
	_advance(game, player, &"tech")
	_advance(game, player, &"civic")
	_update_era(game, player)


static func _advance(game: Node, player: PlayerState, kind: StringName) -> void:
	var is_tech := kind == &"tech"
	var current := player.current_tech if is_tech else player.current_civic

	if current == &"":
		current = choose_next(game, player, kind)
		if current == &"":
			return
		if is_tech:
			player.current_tech = current
		else:
			player.current_civic = current

	var node := ContentDB.get_tech(current) if is_tech else ContentDB.get_civic(current)
	if node == null:
		return

	var yield_kind := Yields.Kind.SCIENCE if is_tech else Yields.Kind.CULTURE
	var per_turn := player.yields_per_turn.get_kind(yield_kind)

	if is_tech:
		player.tech_progress += per_turn
	else:
		player.civic_progress += per_turn

	var cost := player.node_cost(node, world_era(game))
	var progress := player.tech_progress if is_tech else player.civic_progress

	if progress >= cost:
		_complete(game, player, kind, node, progress - cost)


static func _complete(game: Node, player: PlayerState, kind: StringName, node: EmpireDefs.TreeNodeDef, carry_over: float) -> void:
	var is_tech := kind == &"tech"
	if is_tech:
		player.techs[node.id] = true
		player.current_tech = &""
		player.tech_progress = carry_over
		EventBus.tech_researched.emit(player.id, node.id)
	else:
		player.civics[node.id] = true
		player.current_civic = &""
		player.civic_progress = carry_over
		# Civics are what hand out policy cards, governor titles and envoys.
		for policy_id in node.policies_unlocked:
			player.unlocked_policies[policy_id] = true
		player.governor_titles += node.governor_titles
		player.envoys_available += node.envoys
		EventBus.civic_researched.emit(player.id, node.id)

	game.modifiers.invalidate_all()

	EventBus.notification_posted.emit(
		player.id, &"research", "%s complete." % node.name, Vector2i.ZERO
	)


## Trigger a boost. Returns true if it fired for the first time.
static func trigger_boost(game: Node, player: PlayerState, kind: StringName, node_id: StringName) -> bool:
	var node := ContentDB.get_tech(node_id) if kind == &"tech" else ContentDB.get_civic(node_id)
	if node == null:
		return false
	if kind == &"tech" and player.has_tech(node_id):
		return false
	if kind == &"civic" and player.has_civic(node_id):
		return false
	if not player.mark_boosted(kind, node_id):
		return false

	# Some civs push the discount further — China's whole identity is that its
	# Eurekas pay out more than anyone else's.
	var extra: float = game.modifiers.sum_scalar(
		ModifierEngine.EFFECT_BOOST_PERCENT, {"player": player}
	)
	var fraction := BOOST_FRACTION + extra * 0.01
	var amount := player.node_cost(node, world_era(game)) * fraction

	if kind == &"tech":
		if player.current_tech == node_id:
			player.tech_progress += amount
	elif player.current_civic == node_id:
		player.civic_progress += amount

	EventBus.boost_triggered.emit(player.id, kind, node_id)
	EventBus.notification_posted.emit(
		player.id,
		&"boost",
		"%s: %s" % ["Eureka" if kind == &"tech" else "Inspiration", node.name],
		Vector2i.ZERO,
	)
	return true


## Fire every boost whose trigger the current game state now satisfies.
##
## Called after actions that could satisfy one. Evaluating the whole set is
## cheap — a few dozen nodes — and far more robust than trying to notify the
## exact node each action might have unlocked.
static func check_boosts(game: Node, player: PlayerState) -> void:
	for kind in [&"tech", &"civic"]:
		var tree: Dictionary = ContentDB.techs if kind == &"tech" else ContentDB.civics
		for node: EmpireDefs.TreeNodeDef in tree.values():
			if not node.has_boost() or player.is_boosted(kind, node.id):
				continue
			if _boost_satisfied(game, player, node):
				trigger_boost(game, player, kind, node.id)


static func _boost_satisfied(game: Node, player: PlayerState, node: EmpireDefs.TreeNodeDef) -> bool:
	var args := node.boost_args()
	var need := int(args.get("count", 1))

	match node.boost_type():
		&"BUILD_IMPROVEMENT":
			var wanted := StringName(str(args.get("improvement", "")))
			return _count_improvements(game, player, wanted) >= need

		&"IMPROVE_RESOURCE":
			var wanted_res := StringName(str(args.get("resource", "")))
			var wanted_imp := StringName(str(args.get("improvement", "")))
			return _count_improved_resources(game, player, wanted_res, wanted_imp) >= need

		&"BUILD_BUILDING":
			var wanted_building := StringName(str(args.get("building", "")))
			var count := 0
			for city: CityState in game.cities_of(player.id):
				if city.has_building(wanted_building):
					count += 1
			return count >= need

		&"BUILD_DISTRICT":
			var wanted_district := StringName(str(args.get("district", "")))
			var district_count := 0
			for city: CityState in game.cities_of(player.id):
				if wanted_district != &"":
					if city.has_district(wanted_district):
						district_count += 1
				else:
					district_count += city.specialty_district_count()
			return district_count >= need

		&"BUILD_WONDER":
			var wonders := 0
			for city: CityState in game.cities_of(player.id):
				wonders += city.wonders.size()
			return wonders >= need

		&"FOUND_COASTAL_CITY":
			for city: CityState in game.cities_of(player.id):
				if city.is_coastal:
					return true
			return false

		&"TOTAL_POPULATION":
			var population := 0
			for city: CityState in game.cities_of(player.id):
				population += city.population
			return population >= need

		&"MEET_CIVILIZATIONS":
			var met := 0
			for other_id: Variant in player.met_players:
				var other: PlayerState = game.get_player(other_id)
				if other != null and other.kind == PlayerState.Kind.MAJOR:
					met += 1
			return met >= need

		&"MEET_CITY_STATES":
			var met_states := 0
			for other_id: Variant in player.met_players:
				var other: PlayerState = game.get_player(other_id)
				if other != null and other.kind == PlayerState.Kind.CITY_STATE:
					met_states += 1
			return met_states >= need

		&"DISCOVER_CONTINENT":
			var seen := {}
			var explored: Dictionary = game.map.explored.get(player.id, {})
			for coord: Vector2i in explored:
				var tile: Tile = game.map.get_tile(coord)
				if tile != null and tile.continent_id != -1:
					seen[tile.continent_id] = true
			return seen.size() >= need

		&"DISCOVER_NATURAL_WONDER":
			var explored_tiles: Dictionary = game.map.explored.get(player.id, {})
			for coord: Vector2i in explored_tiles:
				var tile: Tile = game.map.get_tile(coord)
				if tile != null and tile.natural_wonder_id != &"":
					return true
			return false

		&"OWN_UNITS":
			var wanted_unit := StringName(str(args.get("unit", "")))
			var owned := 0
			for unit: UnitState in game.units_of(player.id):
				if wanted_unit == &"" or unit.unit_id == wanted_unit:
					owned += 1
			return owned >= need

		&"HAVE_TECH":
			return player.has_tech(StringName(str(args.get("tech", ""))))

		&"FOUND_PANTHEON":
			return player.pantheon_id != &""

		&"FOUND_RELIGION":
			return player.religion_id != &""

		&"AT_WAR_WITH_STRONGER":
			return player.is_at_war_with_anyone()

		# Counter-driven triggers are tallied by whatever performs the action
		# and read back here.
		&"KILL_UNITS":
			var owner := StringName(str(args.get("owner", "any")))
			return int(player.boost_counters.get(StringName("kills_%s" % owner), 0)) >= need

		&"KILL_WITH_UNIT":
			var with_unit := StringName(str(args.get("unit", "")))
			return int(player.boost_counters.get(StringName("kills_with_%s" % with_unit), 0)) >= need

		&"CLEAR_BARBARIAN_OUTPOST":
			return int(player.boost_counters.get(&"outposts_cleared", 0)) >= need

		&"EARN_GREAT_PERSON":
			var category := StringName(str(args.get("category", "")))
			return int(player.boost_counters.get(StringName("great_%s" % category), 0)) >= need

	return false


static func _count_improvements(game: Node, player: PlayerState, wanted: StringName) -> int:
	var count := 0
	for city: CityState in game.cities_of(player.id):
		for coord in city.owned_tiles:
			var tile: Tile = game.map.get_tile(coord)
			if tile == null or tile.improvement_id == &"":
				continue
			if wanted == &"" or tile.improvement_id == wanted:
				count += 1
	return count


static func _count_improved_resources(game: Node, player: PlayerState, resource: StringName, improvement: StringName) -> int:
	var count := 0
	for city: CityState in game.cities_of(player.id):
		for coord in city.owned_tiles:
			var tile: Tile = game.map.get_tile(coord)
			if tile == null or tile.improvement_id == &"" or tile.resource_id == &"":
				continue
			if resource != &"" and tile.resource_id != resource:
				continue
			if improvement != &"" and tile.improvement_id != improvement:
				continue
			count += 1
	return count


# -------------------------------------------------------------------------
# Selection
# -------------------------------------------------------------------------

static func available_nodes(player: PlayerState, kind: StringName) -> Array:
	var tree: Dictionary = ContentDB.techs if kind == &"tech" else ContentDB.civics
	var completed: Dictionary = player.techs if kind == &"tech" else player.civics
	var out: Array = []
	for node: EmpireDefs.TreeNodeDef in tree.values():
		if completed.has(node.id):
			continue
		var ready := true
		for prereq in node.prerequisites:
			if not completed.has(prereq):
				ready = false
				break
		if ready:
			out.append(node)
	return out


## Pick what to research next, weighted by the leader's flavours so a warlike
## civ climbs the military branch and a scientific one heads for Writing.
static func choose_next(game: Node, player: PlayerState, kind: StringName) -> StringName:
	var options := available_nodes(player, kind)
	if options.is_empty():
		return &""

	var best: EmpireDefs.TreeNodeDef = null
	var best_score := -INF
	for node: EmpireDefs.TreeNodeDef in options:
		var score := _score_node(game, player, node)
		if score > best_score:
			best_score = score
			best = node
	return best.id if best != null else &""


static func _score_node(game: Node, player: PlayerState, node: EmpireDefs.TreeNodeDef) -> float:
	# Cheap nodes first, so early research does not stall on an expensive one.
	var score := 100.0 / maxf(float(node.cost), 1.0)

	# An already-banked boost makes a node much more attractive.
	if player.is_boosted(&"tech", node.id) or player.is_boosted(&"civic", node.id):
		score += 3.0

	# Weight what it unlocks by what this leader cares about.
	for unlock in node.unlocks:
		if ContentDB.units.has(unlock):
			var unit_def: UnitDefs.UnitDef = ContentDB.units[unlock]
			score += player.flavor("military", 0.5) * (2.0 if unit_def.is_military() else 0.5)
		elif ContentDB.districts.has(unlock):
			score += _district_flavor(player, unlock) * 2.5
		elif ContentDB.buildings.has(unlock):
			score += 1.0

	if node.governor_titles > 0:
		score += 1.5
	if node.envoys > 0:
		score += player.flavor("diplomacy", 0.5) * 1.5
	if not node.policies_unlocked.is_empty():
		score += 1.0

	# Falling behind is expensive, so bias toward the current world era.
	var era_gap := node.era - world_era(game)
	score -= maxf(0.0, float(era_gap)) * 0.5

	return score


static func _district_flavor(player: PlayerState, district_id: StringName) -> float:
	match district_id:
		&"campus": return player.flavor("science", 0.5)
		&"holy_site": return player.flavor("faith", 0.5)
		&"commercial_hub": return player.flavor("gold", 0.5)
		&"theater_square": return player.flavor("culture", 0.5)
		&"encampment": return player.flavor("military", 0.5)
		&"industrial_zone": return player.flavor("production", 0.5)
		&"harbor": return player.flavor("naval", 0.5)
	return 0.5


# -------------------------------------------------------------------------
# Eras
# -------------------------------------------------------------------------

## A player enters an era when they research their first node from it.
static func _update_era(game: Node, player: PlayerState) -> void:
	var highest := 0
	for tech_id: StringName in player.techs:
		var tech := ContentDB.get_tech(tech_id)
		if tech != null:
			highest = maxi(highest, tech.era)
	for civic_id: StringName in player.civics:
		var civic := ContentDB.get_civic(civic_id)
		if civic != null:
			highest = maxi(highest, civic.era)

	if highest > player.era:
		player.era = highest
		game.modifiers.invalidate_all()
		EventBus.era_changed.emit(player.id, highest)
		EventBus.notification_posted.emit(
			player.id, &"era",
			"You have entered the %s Era." % EmpireDefs.ERA_NAMES[highest],
			Vector2i.ZERO,
		)


## The era most major civilizations are in — the reference point for
## era-relative research costs.
static func world_era(game: Node) -> int:
	var players: Array = game.major_players()
	if players.is_empty():
		return 0
	var total := 0
	for player: PlayerState in players:
		total += player.era
	return int(round(float(total) / float(players.size())))
