class_name CityStateSystem
extends RefCounted

## City-states, envoys, suzerainty — and the loyalty pressure that decides
## whether a city stays yours.
##
## Envoys buy escalating yield bonuses; three or more, and more than anyone
## else, makes you suzerain and hands you that city-state's unique bonus. This
## gives a peaceful player something to compete over that is not territory.

## Envoy counts at which the generic type bonus steps up.
const ENVOY_THRESHOLDS: Array[int] = [1, 3, 6]
const ENVOYS_FOR_SUZERAIN := 3

## Loyalty pressure falls off with distance and stops entirely past this range.
const LOYALTY_RANGE := 9
const MAX_LOYALTY_SWING := 20.0


static func send_envoy(game: Node, player: PlayerState, city_state: PlayerState) -> bool:
	if player.envoys_available <= 0 or city_state.kind != PlayerState.Kind.CITY_STATE:
		return false
	if not player.has_met(city_state.id):
		return false

	player.envoys_available -= 1
	var total := int(player.envoys_sent.get(city_state.id, 0)) + 1
	player.envoys_sent[city_state.id] = total

	_apply_envoy_bonuses(game, player, city_state, total)
	_recompute_suzerain(game, city_state)

	EventBus.envoy_sent.emit(player.id, city_state.id, total)
	return true


## Envoys grant a yield in each city with the matching district, stepping up at
## 1, 3 and 6 envoys.
static func _apply_envoy_bonuses(game: Node, player: PlayerState, city_state: PlayerState, total: int) -> void:
	var def := ContentDB.get_city_state(city_state.city_state_id)
	if def == null:
		return

	var steps := 0
	for threshold in ENVOY_THRESHOLDS:
		if total >= threshold:
			steps += 1
	if steps <= 0:
		return

	var kind := def.envoy_yield_kind()
	var amount := float(steps)

	var modifier := Modifier.new(
		StringName("envoy_%s" % city_state.city_state_id),
		ModifierEngine.EFFECT_CITY_YIELD_FLAT,
	)
	modifier.scope = Modifier.Scope.CITY
	modifier.args = {"yields": {Yields.KIND_NAMES[kind]: amount}}
	modifier.description = "+%d %s from Envoys with %s" % [
		int(amount), Yields.KIND_NAMES[kind], def.name
	]

	# Militaristic and industrial city-states pay out where the matching
	# district exists, rather than empire-wide.
	var required_district := _district_for(def.type)
	if required_district != &"":
		modifier.requirements.append(
			Requirement.new(&"CITY_HAS_DISTRICT", {"district": str(required_district)})
		)

	game.modifiers.set_source(
		player.id, &"envoy", city_state.city_state_id, [modifier] as Array[Modifier]
	)


static func _district_for(type: EmpireDefs.CityStateDef.Type) -> StringName:
	match type:
		EmpireDefs.CityStateDef.Type.SCIENTIFIC: return &"campus"
		EmpireDefs.CityStateDef.Type.CULTURAL: return &"theater_square"
		EmpireDefs.CityStateDef.Type.RELIGIOUS: return &"holy_site"
		EmpireDefs.CityStateDef.Type.TRADE: return &"commercial_hub"
		EmpireDefs.CityStateDef.Type.MILITARISTIC: return &"encampment"
		EmpireDefs.CityStateDef.Type.INDUSTRIAL: return &"industrial_zone"
	return &""


## Suzerainty goes to whoever has the most envoys, provided they have at least
## three. A tie leaves the incumbent in place.
static func _recompute_suzerain(game: Node, city_state: PlayerState) -> void:
	var current := -1
	for player: PlayerState in game.players.values():
		if player.suzerain_of.has(city_state.id):
			current = player.id
			break

	var best_id := -1
	var best_count := 0
	for player: PlayerState in game.players.values():
		if player.kind != PlayerState.Kind.MAJOR:
			continue
		var count := int(player.envoys_sent.get(city_state.id, 0))
		if count >= ENVOYS_FOR_SUZERAIN and count > best_count:
			best_count = count
			best_id = player.id

	if best_id == current:
		return

	var def := ContentDB.get_city_state(city_state.city_state_id)

	if current >= 0:
		var previous: PlayerState = game.get_player(current)
		if previous != null:
			previous.suzerain_of.erase(city_state.id)
			game.modifiers.clear_source(current, &"suzerain", city_state.city_state_id)

	if best_id >= 0:
		var winner: PlayerState = game.get_player(best_id)
		if winner != null:
			winner.suzerain_of[city_state.id] = true
			if def != null and not def.suzerain_modifiers.is_empty():
				game.modifiers.set_source(
					best_id, &"suzerain", city_state.city_state_id, def.suzerain_modifiers
				)
			EventBus.notification_posted.emit(
				best_id, &"suzerain",
				"You are now Suzerain of %s." % (def.name if def != null else "a city-state"),
				Vector2i.ZERO,
			)

	EventBus.suzerain_changed.emit(city_state.id, current, best_id)


# -------------------------------------------------------------------------
# Loyalty
# -------------------------------------------------------------------------

## Recompute loyalty for each of a player's cities.
##
## Every nearby city exerts pressure proportional to its population and inverse
## to its distance. A city surrounded by foreign population drifts away from its
## owner and eventually revolts — which is what makes a distant conquest a
## liability rather than a prize.
static func process_loyalty(game: Node, player: PlayerState) -> void:
	if player.kind != PlayerState.Kind.MAJOR:
		return

	for city: CityState in game.cities_of(player.id):
		var domestic := 0.0
		var foreign := 0.0

		for other: CityState in game.cities.values():
			var distance: int = game.map.distance(city.coord, other.coord)
			if distance > LOYALTY_RANGE:
				continue
			# Population weighted by proximity: 10 at the city itself, falling
			# to 1 at the edge of range.
			var weight := float(other.population) * float(10 - distance)
			if weight <= 0.0:
				continue
			if other.owner_id == player.id:
				domestic += weight
			else:
				var other_owner: PlayerState = game.get_player(other.owner_id)
				if other_owner != null and other_owner.kind == PlayerState.Kind.MAJOR:
					foreign += weight

		var pressure := 10.0 * (domestic - foreign) / (minf(domestic, foreign) + 0.5)
		pressure = clampf(pressure, -MAX_LOYALTY_SWING, MAX_LOYALTY_SWING)

		# Contentment holds a city together; misery pulls it apart.
		match city.mood:
			CityState.Mood.ECSTATIC: pressure += 6.0
			CityState.Mood.HAPPY: pressure += 3.0
			CityState.Mood.DISPLEASED: pressure -= 3.0
			CityState.Mood.UNHAPPY: pressure -= 6.0
			CityState.Mood.IN_REVOLT: pressure -= 10.0

		if city.governor_id != &"":
			pressure += 8.0
		if city.is_capital:
			pressure += 10.0

		pressure += game.modifiers.sum_scalar(
			ModifierEngine.EFFECT_CITY_LOYALTY, {"player": player, "city": city}
		)

		city.loyalty_per_turn = pressure
		city.loyalty = clampf(city.loyalty + pressure, 0.0, CityState.MAX_LOYALTY)

		if city.loyalty <= 0.0:
			_revolt(game, city)
		elif city.loyalty < 50.0 and pressure < 0.0:
			EventBus.notification_posted.emit(
				player.id, &"loyalty",
				"%s is losing loyalty (%d)." % [city.name, int(city.loyalty)],
				city.coord,
			)


## A city that runs out of loyalty declares itself free.
static func _revolt(game: Node, city: CityState) -> void:
	var free_player := _free_city_player(game)
	if free_player == null:
		return
	var old_owner := city.owner_id
	CitySystem.capture_city(game, city, free_player)
	city.loyalty = 40.0
	EventBus.notification_posted.emit(
		old_owner, &"revolt", "%s has revolted and is now a Free City." % city.name, city.coord
	)


static func _free_city_player(game: Node) -> PlayerState:
	for player: PlayerState in game.players.values():
		if player.kind == PlayerState.Kind.FREE_CITY:
			return player
	return null


# -------------------------------------------------------------------------
# AI envoy spending
# -------------------------------------------------------------------------

## Spend banked envoys on whichever city-state best matches this leader's
## priorities, preferring ones where suzerainty is actually within reach.
static func ai_spend_envoys(game: Node, player: PlayerState) -> void:
	while player.envoys_available > 0:
		var best: PlayerState = null
		var best_score := -INF

		for city_state: PlayerState in game.players.values():
			if city_state.kind != PlayerState.Kind.CITY_STATE:
				continue
			if not player.has_met(city_state.id) or not city_state.is_alive:
				continue

			var def := ContentDB.get_city_state(city_state.city_state_id)
			if def == null:
				continue

			var mine := int(player.envoys_sent.get(city_state.id, 0))
			var score := _type_appeal(player, def.type) * 4.0

			# Finishing a suzerainty is worth far more than a fourth envoy
			# somewhere already locked up.
			if player.suzerain_of.has(city_state.id):
				score -= 3.0
			elif mine + 1 >= ENVOYS_FOR_SUZERAIN and mine + 1 > _rival_max(game, player, city_state):
				score += 8.0

			# Diminishing returns past the last threshold.
			if mine >= ENVOY_THRESHOLDS[-1]:
				score -= 4.0

			if score > best_score:
				best_score = score
				best = city_state

		if best == null or not send_envoy(game, player, best):
			return


static func _rival_max(game: Node, player: PlayerState, city_state: PlayerState) -> int:
	var most := 0
	for other: PlayerState in game.players.values():
		if other.id == player.id or other.kind != PlayerState.Kind.MAJOR:
			continue
		most = maxi(most, int(other.envoys_sent.get(city_state.id, 0)))
	return most


static func _type_appeal(player: PlayerState, type: EmpireDefs.CityStateDef.Type) -> float:
	match type:
		EmpireDefs.CityStateDef.Type.SCIENTIFIC: return player.flavor("science", 0.5)
		EmpireDefs.CityStateDef.Type.CULTURAL: return player.flavor("culture", 0.5)
		EmpireDefs.CityStateDef.Type.RELIGIOUS: return player.flavor("faith", 0.5)
		EmpireDefs.CityStateDef.Type.TRADE: return player.flavor("gold", 0.5)
		EmpireDefs.CityStateDef.Type.MILITARISTIC: return player.flavor("military", 0.5)
		EmpireDefs.CityStateDef.Type.INDUSTRIAL: return player.flavor("production", 0.5)
	return 0.5
