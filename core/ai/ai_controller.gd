class_name AIController
extends RefCounted

## The AI opponent.
##
## A utility AI, not a search: each candidate action is scored against the
## leader's flavour weights and the current game state, and the best is taken.
## That is the right shape for a 4X — the branching factor makes lookahead
## hopeless, and flavour weighting is what makes Norway play differently from
## Mali rather than every opponent converging on the same optimal line.
##
## Tactical combat does read the damage curve directly: the AI checks what a
## fight would actually cost before committing, which is why it focuses wounded
## targets and pulls damaged units out rather than trading evenly.

static func take_turn(game: Node, player: PlayerState) -> void:
	if not player.is_alive:
		return

	_choose_research(game, player)
	_manage_policies(game, player)
	_manage_cities(game, player)
	_command_units(game, player)
	CityStateSystem.ai_spend_envoys(game, player)


# -------------------------------------------------------------------------
# Research and government
# -------------------------------------------------------------------------

static func _choose_research(game: Node, player: PlayerState) -> void:
	if player.current_tech == &"":
		player.current_tech = ResearchSystem.choose_next(game, player, &"tech")
	if player.current_civic == &"":
		player.current_civic = ResearchSystem.choose_next(game, player, &"civic")


static func _manage_policies(game: Node, player: PlayerState) -> void:
	_maybe_change_government(game, player)

	var slots := player.policy_slots()
	if slots.is_empty():
		return

	# Rebuild the whole loadout each time: cheap, and it keeps cards current as
	# priorities shift (a peaceful builder swaps to military cards at war).
	var chosen: Dictionary = {}
	var used: Dictionary = {}

	for slot_index in slots.size():
		var slot_kind := slots[slot_index]
		var best: EmpireDefs.PolicyDef = null
		var best_score := -INF

		for policy_id: StringName in player.unlocked_policies:
			if used.has(policy_id):
				continue
			var policy := ContentDB.get_policy(policy_id)
			if policy == null or not policy.fits_slot(slot_kind):
				continue
			var score := _score_policy(game, player, policy)
			if score > best_score:
				best_score = score
				best = policy

		if best != null:
			chosen[slot_index] = str(best.id)
			used[best.id] = true

	player.slotted_policies = chosen
	_sync_policy_modifiers(game, player)


static func _score_policy(game: Node, player: PlayerState, policy: EmpireDefs.PolicyDef) -> float:
	var score := 1.0
	var at_war := player.is_at_war_with_anyone()

	for modifier in policy.modifiers:
		match modifier.effect:
			ModifierEngine.EFFECT_CITY_YIELD_FLAT:
				var yields := modifier.arg_yields()
				score += yields.get_kind(Yields.Kind.PRODUCTION) * 2.0 * player.flavor("production", 0.5)
				score += yields.get_kind(Yields.Kind.FOOD) * 2.0
				score += yields.get_kind(Yields.Kind.SCIENCE) * 2.0 * player.flavor("science", 0.5)
				score += yields.get_kind(Yields.Kind.CULTURE) * 2.0 * player.flavor("culture", 0.5)
				score += yields.get_kind(Yields.Kind.GOLD) * 1.2 * player.flavor("gold", 0.5)
				score += yields.get_kind(Yields.Kind.FAITH) * 1.5 * player.flavor("faith", 0.5)
			ModifierEngine.EFFECT_UNIT_COMBAT_STRENGTH:
				score += modifier.arg_float("amount") * (1.2 if at_war else 0.3) * player.flavor("military", 0.5)
			ModifierEngine.EFFECT_PRODUCTION_PERCENT:
				score += modifier.arg_float("amount") * 0.06
			ModifierEngine.EFFECT_CITY_HOUSING:
				score += modifier.arg_float("amount") * 2.0
			ModifierEngine.EFFECT_CITY_AMENITIES:
				score += modifier.arg_float("amount") * 2.0
			ModifierEngine.EFFECT_INFLUENCE_PER_TURN:
				score += modifier.arg_float("amount") * 1.5 * player.flavor("diplomacy", 0.5)
			ModifierEngine.EFFECT_UNIT_MAINTENANCE:
				score += absf(modifier.arg_float("amount")) * game.units_of(player.id).size() * 0.3

		# A card whose requirements nothing currently satisfies is dead weight.
		if not modifier.requirements.is_empty() and not _any_city_satisfies(game, player, modifier):
			score *= 0.25

	return score


static func _any_city_satisfies(game: Node, player: PlayerState, modifier: Modifier) -> bool:
	var cities: Array = game.cities_of(player.id)
	if cities.is_empty():
		return true
	for city: CityState in cities:
		if modifier.applies({"player": player, "city": city}):
			return true
	# Unit- and production-scoped cards cannot be judged from city state alone.
	return modifier.scope != Modifier.Scope.CITY


static func _sync_policy_modifiers(game: Node, player: PlayerState) -> void:
	game.modifiers.clear_source(player.id, &"policies", &"active")
	var all: Array[Modifier] = []
	for policy_id in player.slotted_policy_ids():
		var policy := ContentDB.get_policy(policy_id)
		if policy != null:
			all.append_array(policy.modifiers)
	if not all.is_empty():
		game.modifiers.set_source(player.id, &"policies", &"active", all)


static func _maybe_change_government(game: Node, player: PlayerState) -> void:
	var best: EmpireDefs.GovernmentDef = null
	var best_score := -INF

	for government: EmpireDefs.GovernmentDef in ContentDB.governments.values():
		if government.required_civic != &"" and not player.has_civic(government.required_civic):
			continue
		# More slots is almost always better; break ties on thematic fit.
		var score := float(government.total_slots()) * 2.0
		score += government.military_slots * player.flavor("military", 0.5)
		score += government.economic_slots * player.flavor("gold", 0.5)
		score += government.diplomatic_slots * player.flavor("diplomacy", 0.5)
		if score > best_score:
			best_score = score
			best = government

	if best == null or best.id == player.government_id:
		return

	player.government_id = best.id
	player.slotted_policies.clear()
	game.modifiers.set_source(player.id, &"government", best.id, best.modifiers)
	EventBus.government_changed.emit(player.id, best.id)


# -------------------------------------------------------------------------
# Cities
# -------------------------------------------------------------------------

static func _manage_cities(game: Node, player: PlayerState) -> void:
	for city: CityState in game.cities_of(player.id):
		if city.production_item == &"":
			_choose_production(game, player, city)


static func _choose_production(game: Node, player: PlayerState, city: CityState) -> void:
	var options := CitySystem.available_production(game, city)
	if options.is_empty():
		return

	var best: Dictionary = {}
	var best_score := -INF
	for option: Dictionary in options:
		var score := _score_production(game, player, city, option)
		if score > best_score:
			best_score = score
			best = option

	if best.is_empty():
		return

	var kind: CityState.ProductionKind = best["kind"]
	var item: StringName = best["id"]

	# A district has to be sited before it is queued, so the completion step
	# knows where to put it.
	if kind == CityState.ProductionKind.DISTRICT:
		var district := ContentDB.get_district(item)
		var sites := Adjacency.rank_sites(game.map, city, district, player, game.modifiers)
		if sites.is_empty():
			return
		city.production_queue = [sites[0]["coord"]]

	city.set_production(kind, item)


static func _score_production(game: Node, player: PlayerState, city: CityState, option: Dictionary) -> float:
	var kind: CityState.ProductionKind = option["kind"]
	var item: StringName = option["id"]
	var cost := float(option["cost"])

	# Everything is scored as value-per-production, so a cheap useful thing
	# beats an expensive marginal one.
	var value := 0.0

	match kind:
		CityState.ProductionKind.UNIT:
			value = _score_unit(game, player, city, item)
		CityState.ProductionKind.DISTRICT:
			value = _score_district(game, player, city, item)
		CityState.ProductionKind.BUILDING:
			value = _score_building(player, item)
		CityState.ProductionKind.WONDER:
			value = 30.0 * player.flavor("wonder", 0.5)

	return value / maxf(cost, 1.0) * 100.0


static func _score_unit(game: Node, player: PlayerState, city: CityState, unit_id: StringName) -> float:
	var def := ContentDB.get_unit(unit_id)
	if def == null:
		return 0.0

	var own_units: Array = game.units_of(player.id)
	var city_count: int = game.cities_of(player.id).size()

	if def.can_found_city:
		# Expansion is the strongest early play, but only while there is
		# somewhere worth settling and the empire can absorb it.
		var settlers := own_units.filter(func(u: UnitState) -> bool:
			return u.definition().can_found_city).size()
		if settlers >= 2 or _find_settle_site(game, player, city.coord).x == -9999:
			return 0.0
		var appetite := player.flavor("expansion", 0.5) * 60.0
		return maxf(0.0, appetite - city_count * 6.0 - settlers * 25.0)

	if def.can_build_improvements:
		var builders := own_units.filter(func(u: UnitState) -> bool:
			return u.definition().can_build_improvements).size()
		var wanted := maxi(1, int(city_count * 0.75))
		return 35.0 if builders < wanted else 0.0

	if def.is_military():
		var military := own_units.filter(func(u: UnitState) -> bool:
			return u.definition().is_military()).size()
		var wanted_military := maxi(2, city_count * 2)
		var score := def.combat_strength * 0.6 * player.flavor("military", 0.5)

		if military < wanted_military:
			score += 25.0
		else:
			score *= 0.3
		if player.is_at_war_with_anyone():
			score *= 2.0
		# Ranged units are disproportionately useful against barbarians and
		# cities, so the AI should not build pure melee.
		if def.is_ranged():
			score *= 1.25
		if def.is_naval() and not city.is_coastal:
			return 0.0
		return score

	if unit_id == &"trader":
		return 20.0 * player.flavor("gold", 0.5)

	return 5.0


static func _score_district(game: Node, player: PlayerState, city: CityState, district_id: StringName) -> float:
	var district := ContentDB.get_district(district_id)
	if district == null:
		return 0.0

	# The adjacency the best available site would actually deliver — this is
	# what makes the AI site districts rather than scatter them.
	var sites := Adjacency.rank_sites(game.map, city, district, player, game.modifiers)
	if sites.is_empty():
		return 0.0
	var adjacency := float(sites[0]["adjacency"])

	var flavor := 0.5
	match district_id:
		&"campus": flavor = player.flavor("science", 0.5)
		&"holy_site": flavor = player.flavor("faith", 0.5)
		&"commercial_hub": flavor = player.flavor("gold", 0.5)
		&"theater_square": flavor = player.flavor("culture", 0.5)
		&"encampment": flavor = player.flavor("military", 0.5)
		&"industrial_zone": flavor = player.flavor("production", 0.5)
		&"harbor": flavor = player.flavor("naval", 0.5)
		&"government_plaza": flavor = 0.9
		&"aqueduct":
			# Only worth it when Housing is actually the constraint.
			return 45.0 if city.housing - city.population < 2.0 else 5.0
		&"entertainment_complex":
			return 50.0 if city.amenities < city.amenities_needed else 5.0

	return (20.0 + adjacency * 12.0) * flavor


static func _score_building(player: PlayerState, building_id: StringName) -> float:
	var building := ContentDB.get_building(building_id)
	if building == null:
		return 0.0

	var y := building.base_yields()
	var score := (
		y.get_kind(Yields.Kind.SCIENCE) * 6.0 * player.flavor("science", 0.5)
		+ y.get_kind(Yields.Kind.CULTURE) * 6.0 * player.flavor("culture", 0.5)
		+ y.get_kind(Yields.Kind.PRODUCTION) * 7.0 * player.flavor("production", 0.5)
		+ y.get_kind(Yields.Kind.GOLD) * 4.0 * player.flavor("gold", 0.5)
		+ y.get_kind(Yields.Kind.FAITH) * 5.0 * player.flavor("faith", 0.5)
		+ y.get_kind(Yields.Kind.FOOD) * 6.0
	)
	score += building.housing * 8.0
	score += building.amenities * 8.0
	if building.defense > 0:
		score += building.defense * 0.3 * (1.0 + player.flavor("military", 0.5))
	return score


# -------------------------------------------------------------------------
# Units
# -------------------------------------------------------------------------

static func _command_units(game: Node, player: PlayerState) -> void:
	# Military first, so escorts are in place before settlers move out.
	var units: Array = game.units_of(player.id)
	units.sort_custom(func(a: UnitState, b: UnitState) -> bool:
		return int(a.definition().is_military()) > int(b.definition().is_military()))

	for unit: UnitState in units:
		if not unit.is_alive():
			continue
		var def := unit.definition()
		if def == null:
			continue
		if def.can_found_city:
			_act_settler(game, player, unit)
		elif def.can_build_improvements:
			_act_builder(game, player, unit)
		elif def.unit_class == UnitDefs.UnitClass.RECON:
			_act_scout(game, player, unit)
		elif def.is_military():
			_act_military(game, player, unit)


static func _act_settler(game: Node, player: PlayerState, unit: UnitState) -> void:
	if UnitSystem.can_found_city_at(game, player, unit.coord):
		var here := _score_settle_site(game, player, unit.coord)
		# Settle here if it is decent; hunting for perfection wastes turns.
		if here > 45.0:
			UnitSystem.found_city(game, unit)
			return

	var target := _find_settle_site(game, player, unit.coord)
	if target.x == -9999:
		if UnitSystem.can_found_city_at(game, player, unit.coord):
			UnitSystem.found_city(game, unit)
		return

	if target == unit.coord:
		UnitSystem.found_city(game, unit)
		return

	var path := UnitSystem.find_path(game, unit, target)
	UnitSystem.move_along(game, unit, path)

	if unit.coord == target and UnitSystem.can_found_city_at(game, player, unit.coord):
		UnitSystem.found_city(game, unit)


static func _find_settle_site(game: Node, player: PlayerState, from: Vector2i) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_score := 40.0   # a floor, so the AI does not settle junk

	var explored: Dictionary = game.map.explored.get(player.id, {})
	for coord: Vector2i in explored:
		if not UnitSystem.can_found_city_at(game, player, coord):
			continue
		var distance: int = game.map.distance(from, coord)
		if distance > 14:
			continue
		var score := _score_settle_site(game, player, coord) - distance * 2.0
		if score > best_score:
			best_score = score
			best = coord
	return best


static func _score_settle_site(game: Node, player: PlayerState, coord: Vector2i) -> float:
	var map: MapModel = game.map
	var tile := map.get_tile(coord)
	if tile == null:
		return 0.0

	var score := 30.0
	if map.has_fresh_water(coord):
		score += 20.0
	if map.is_coastal(coord):
		score += 10.0 * (0.5 + player.flavor("naval", 0.5))
	if tile.is_hills:
		score += 6.0

	for neighbour in map.tiles_within(coord, MapModel.CITY_WORK_RADIUS):
		if neighbour.coord == coord:
			continue
		# Tiles already owned by someone else are worthless to a new city.
		if neighbour.owner_id != -1 and neighbour.owner_id != player.id:
			score -= 3.0
			continue
		var y := neighbour.base_yields()
		score += y.get_kind(Yields.Kind.FOOD) * 1.4
		score += y.get_kind(Yields.Kind.PRODUCTION) * 1.6
		var res := neighbour.resource()
		if res != null:
			score += 6.0 if res.is_luxury() else (5.0 if res.is_strategic() else 2.0)
		if neighbour.terrain_id == &"mountains":
			score += 1.5   # future Campus and Holy Site adjacency

	return score


static func _act_builder(game: Node, player: PlayerState, unit: UnitState) -> void:
	var target := _find_improvement_target(game, player, unit)
	if target.is_empty():
		UnitSystem.fortify(unit)
		return

	var coord: Vector2i = target["coord"]
	if unit.coord != coord:
		var path := UnitSystem.find_path(game, unit, coord)
		UnitSystem.move_along(game, unit, path)
	if unit.coord == coord:
		UnitSystem.build_improvement(game, unit, target["improvement"])


static func _find_improvement_target(game: Node, player: PlayerState, unit: UnitState) -> Dictionary:
	var best: Dictionary = {}
	var best_score := 0.0

	for city: CityState in game.cities_of(player.id):
		for coord in city.owned_tiles:
			var tile: Tile = game.map.get_tile(coord)
			if tile == null or tile.improvement_id != &"" or tile.has_district():
				continue

			for improvement: MapDefs.ImprovementDef in ContentDB.improvements.values():
				if improvement.required_tech != &"" and not player.has_tech(improvement.required_tech):
					continue
				if not tile.can_have_improvement(improvement):
					continue

				var gain := improvement.yield_delta()
				var score := (
					gain.get_kind(Yields.Kind.FOOD) * 3.0
					+ gain.get_kind(Yields.Kind.PRODUCTION) * 3.5
					+ gain.get_kind(Yields.Kind.GOLD) * 1.5
				)
				# Improving a resource is worth far more than a bare farm: it
				# unlocks luxuries and strategic stockpiles.
				var res := tile.resource()
				if res != null:
					score += 10.0 if res.is_strategic() else (9.0 if res.is_luxury() else 4.0)
				score -= game.map.distance(unit.coord, coord) * 0.7

				if score > best_score:
					best_score = score
					best = {"coord": coord, "improvement": improvement.id}

	return best


static func _act_scout(game: Node, player: PlayerState, unit: UnitState) -> void:
	# Head for the nearest unexplored tile — frontier-seeking rather than
	# random walking, which is what actually reveals a map.
	var target := _nearest_unexplored(game, player, unit.coord)
	if target.x == -9999:
		_act_military(game, player, unit)
		return
	var path := UnitSystem.find_path(game, unit, target)
	if path.is_empty():
		_wander(game, unit)
		return
	UnitSystem.move_along(game, unit, path)


static func _nearest_unexplored(game: Node, player: PlayerState, from: Vector2i) -> Vector2i:
	var explored: Dictionary = game.map.explored.get(player.id, {})
	var best := Vector2i(-9999, -9999)
	var best_distance := 999

	# Look for explored tiles that still border darkness, which is where a
	# scout can actually reach and reveal from.
	for coord: Vector2i in explored:
		var tile: Tile = game.map.get_tile(coord)
		if tile == null or tile.is_impassable() or tile.is_water():
			continue
		var frontier := false
		for n in game.map.neighbors(coord):
			if not explored.has(n.coord):
				frontier = true
				break
		if not frontier:
			continue
		var distance: int = game.map.distance(from, coord)
		if distance > 0 and distance < best_distance:
			best_distance = distance
			best = coord
	return best


## Tactical layer. Reads the actual damage curve to decide whether a fight is
## worth taking, rather than charging whatever is nearest.
static func _act_military(game: Node, player: PlayerState, unit: UnitState) -> void:
	# Badly wounded units withdraw and heal instead of trading themselves away.
	if unit.hp < 40:
		var refuge := _nearest_friendly_city(game, player, unit.coord)
		if refuge.x != -9999 and game.map.distance(unit.coord, refuge) > 0:
			var path := UnitSystem.find_path(game, unit, refuge)
			UnitSystem.move_along(game, unit, path)
			return
		UnitSystem.fortify(unit)
		return

	var attack := _best_attack(game, unit)
	if not attack.is_empty():
		UnitSystem.attack(game, unit, attack["coord"])
		return

	# Clear an adjacent barbarian outpost — worth gold and an inspiration.
	for n in game.map.neighbors(unit.coord):
		if n.barbarian_outpost and game.military_unit_at(n.coord) == null:
			if UnitSystem.step(game, unit, n.coord):
				BarbarianSystem.clear_outpost(game, player, n.coord)
				return

	var threat := _nearest_threat(game, player, unit.coord)
	if threat.x != -9999:
		var path := UnitSystem.find_path(game, unit, threat)
		if not path.is_empty():
			UnitSystem.move_along(game, unit, path)
			var followup := _best_attack(game, unit)
			if not followup.is_empty():
				UnitSystem.attack(game, unit, followup["coord"])
			return

	# Nothing to do: garrison the nearest city that has no defender.
	var undefended := _nearest_undefended_city(game, player, unit.coord)
	if undefended.x != -9999 and unit.coord != undefended:
		var path := UnitSystem.find_path(game, unit, undefended)
		UnitSystem.move_along(game, unit, path)
		return

	UnitSystem.fortify(unit)


## Score every attack this unit could make and return the best, or nothing if
## none are worth the damage taken.
static func _best_attack(game: Node, unit: UnitState) -> Dictionary:
	if not unit.can_attack():
		return {}

	var def := unit.definition()
	var reach: int = def.range if def.is_ranged() else 1
	var best: Dictionary = {}
	var best_score := 0.0

	for coord in Hex.within_radius(unit.coord, reach):
		if not UnitSystem.can_attack_tile(game, unit, coord):
			continue

		var score := 0.0
		var target: UnitState = game.military_unit_at(coord)
		var city: CityState = game.city_at(coord)

		if target != null:
			var attacker_strength := Combat.effective_strength(game, unit, target, true, def.is_ranged())
			var defender_strength := Combat.effective_strength(game, target, unit, false)
			var damage_dealt := Combat.expected_damage(attacker_strength - defender_strength)
			var damage_taken := 0.0 if def.is_ranged() \
				else Combat.expected_damage(defender_strength - attacker_strength)

			score = damage_dealt - damage_taken * 1.2
			# Finishing a wounded unit is worth much more than chipping a
			# healthy one — it removes it from the board.
			if damage_dealt >= target.hp:
				score += 45.0
			# Never trade a unit away for a poor exchange.
			if damage_taken >= unit.hp:
				score -= 80.0
		elif city != null:
			var city_strength := Combat.city_defense_strength(game, city)
			var strength := Combat.effective_strength(game, unit, null, true, def.is_ranged(), city)
			score = Combat.expected_damage(strength - city_strength) * 0.8
			# Taking a city is the whole point, so weight the killing blow
			# heavily — but only a melee unit can actually do it.
			if city.center_hp <= 0 and not def.is_ranged():
				score += 200.0
		else:
			score = 20.0   # an undefended civilian, free to capture

		if score > best_score:
			best_score = score
			best = {"coord": coord, "score": score}

	return best


static func _nearest_threat(game: Node, player: PlayerState, from: Vector2i) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_distance := 12

	for unit: UnitState in game.units.values():
		if unit.owner_id == player.id or not unit.definition().is_military():
			continue
		var owner: PlayerState = game.get_player(unit.owner_id)
		if owner == null:
			continue
		var hostile := owner.kind == PlayerState.Kind.BARBARIAN or player.is_at_war_with(unit.owner_id)
		if not hostile or not game.map.is_explored(player.id, unit.coord):
			continue
		var distance: int = game.map.distance(from, unit.coord)
		if distance < best_distance:
			best_distance = distance
			best = unit.coord

	# At war, an enemy city outranks a wandering unit as an objective.
	for city: CityState in game.cities.values():
		if not player.is_at_war_with(city.owner_id):
			continue
		if not game.map.is_explored(player.id, city.coord):
			continue
		var distance: int = game.map.distance(from, city.coord)
		if distance < best_distance + 4:
			best_distance = distance
			best = city.coord

	return best


static func _nearest_friendly_city(game: Node, player: PlayerState, from: Vector2i) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_distance := 999
	for city: CityState in game.cities_of(player.id):
		var distance: int = game.map.distance(from, city.coord)
		if distance < best_distance:
			best_distance = distance
			best = city.coord
	return best


static func _nearest_undefended_city(game: Node, player: PlayerState, from: Vector2i) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_distance := 999
	for city: CityState in game.cities_of(player.id):
		if game.military_unit_at(city.coord) != null:
			continue
		var distance: int = game.map.distance(from, city.coord)
		if distance < best_distance:
			best_distance = distance
			best = city.coord
	return best


static func _wander(game: Node, unit: UnitState) -> void:
	var options: Array[Vector2i] = []
	for n in game.map.neighbors(unit.coord):
		if UnitSystem.can_enter(game, unit, n.coord):
			options.append(n.coord)
	if options.is_empty():
		return
	UnitSystem.step(game, unit, RNGService.pick(RNGService.STREAM_AI, options))
