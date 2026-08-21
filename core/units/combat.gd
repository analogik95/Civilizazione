class_name Combat
extends RefCounted

## Combat resolution.
##
## Everything runs off one exponential curve:
##
##     damage = 30 * e^(strength_difference / 25) * random(0.75, 1.25)
##
## At equal strength both sides take about 30 of 100 HP, so a straight fight
## takes three or four rounds. Every ~17 points of strength difference doubles
## or halves the damage, which is why the Corps (+10) and Army (+17) bonuses are
## worth roughly 1.5x and 2x — those numbers were picked against this curve, not
## independently of it.
##
## The consequence worth understanding: strength differences compound viciously.
## A unit one era ahead does not win slightly more often, it wins without taking
## meaningful damage.

const BASE_DAMAGE := 30.0
const STRENGTH_SCALE := 25.0
const RANDOM_MIN := 0.75
const RANDOM_MAX := 1.25
## Ranged attackers take no return fire; melee attackers do, at a reduced rate.
const MELEE_COUNTER_FACTOR := 1.0
const MAX_DAMAGE := 99.0


## Average damage for a given strength difference, before the random term.
## Used by the AI to evaluate a fight and by the UI to preview one.
static func expected_damage(strength_difference: float) -> float:
	return BASE_DAMAGE * exp(strength_difference / STRENGTH_SCALE)


static func roll_damage(strength_difference: float) -> float:
	var multiplier := RNGService.randf_range_in(RNGService.STREAM_COMBAT, RANDOM_MIN, RANDOM_MAX)
	return clampf(expected_damage(strength_difference) * multiplier, 1.0, MAX_DAMAGE)


## Total Combat Strength for a unit in a specific situation: base stat, plus
## formation, fortification, terrain, class counters, promotions and every
## modifier the engine can find.
static func effective_strength(
	game: Node,
	unit: UnitState,
	opponent: UnitState,
	is_attacking: bool,
	ranged: bool = false,
	opponent_city: CityState = null,
) -> float:
	var def := unit.definition()
	if def == null:
		return 0.0

	var strength := unit.base_ranged_strength() if ranged else unit.base_combat_strength()
	strength += unit.fortify_bonus()

	# Terrain defence only helps the side standing on it.
	var tile: Tile = game.map.get_tile(unit.coord)
	if tile != null and not is_attacking:
		strength += tile.defense_modifier()

	# Class counters — the rock-paper-scissors layer.
	if opponent != null:
		strength += UnitDefs.counter_bonus(unit.unit_class(), opponent.unit_class())

	var player: PlayerState = game.get_player(unit.owner_id)
	if player == null:
		return strength

	var opponent_owner: PlayerState = null
	if opponent != null:
		opponent_owner = game.get_player(opponent.owner_id)
	elif opponent_city != null:
		opponent_owner = game.get_player(opponent_city.owner_id)

	var in_friendly := tile != null and tile.owner_id == unit.owner_id

	var ctx := {
		"player": player,
		"unit": unit,
		"tile": tile,
		"opponent": opponent,
		"is_attacking": is_attacking,
		"in_friendly_territory": in_friendly,
		"opponent_is_barbarian": opponent_owner != null and opponent_owner.kind == PlayerState.Kind.BARBARIAN,
		"opponent_is_city": opponent_city != null,
	}

	strength += game.modifiers.unit_combat_strength(ctx)
	strength += _promotion_strength(game, unit, ctx)
	return strength


## Promotions live on the unit rather than the player, so they are collected
## separately from the player-scoped modifier index.
static func _promotion_strength(game: Node, unit: UnitState, ctx: Dictionary) -> float:
	var total := 0.0
	for promotion_id: StringName in unit.promotions:
		var promotion: UnitDefs.PromotionDef = ContentDB.promotions.get(promotion_id)
		if promotion == null:
			continue
		for m in promotion.modifiers:
			if m.effect == ModifierEngine.EFFECT_UNIT_COMBAT_STRENGTH and m.applies(ctx):
				total += m.arg_float("amount")
	return total


## A melee exchange. Both sides take damage; the attacker moves in if the
## defender dies and the tile is free.
static func resolve_melee(game: Node, attacker: UnitState, defender: UnitState) -> Dictionary:
	var attacker_strength := effective_strength(game, attacker, defender, true)
	var defender_strength := effective_strength(game, defender, attacker, false)

	var damage_to_defender := roll_damage(attacker_strength - defender_strength)
	var damage_to_attacker := roll_damage(defender_strength - attacker_strength) * MELEE_COUNTER_FACTOR

	defender.hp = maxi(0, defender.hp - int(round(damage_to_defender)))
	attacker.hp = maxi(0, attacker.hp - int(round(damage_to_attacker)))

	attacker.has_attacked = true
	attacker.spend_all_movement()
	attacker.is_fortified = false

	_award_experience(game, attacker, defender_strength, attacker_strength)
	_award_experience(game, defender, attacker_strength, defender_strength)

	EventBus.combat_resolved.emit(
		attacker.id, defender.id, int(round(damage_to_attacker)), int(round(damage_to_defender))
	)

	return {
		"attacker_damage": int(round(damage_to_attacker)),
		"defender_damage": int(round(damage_to_defender)),
		"attacker_died": not attacker.is_alive(),
		"defender_died": not defender.is_alive(),
	}


## A ranged attack. The defender takes damage and cannot answer, which is what
## makes archers and siege worth their cost despite fragile melee stats.
static func resolve_ranged(game: Node, attacker: UnitState, defender: UnitState) -> Dictionary:
	var attacker_strength := effective_strength(game, attacker, defender, true, true)
	var defender_strength := effective_strength(game, defender, attacker, false)

	var damage := roll_damage(attacker_strength - defender_strength)
	defender.hp = maxi(0, defender.hp - int(round(damage)))

	attacker.has_attacked = true
	attacker.spend_all_movement()

	_award_experience(game, attacker, defender_strength, attacker_strength)

	EventBus.combat_resolved.emit(attacker.id, defender.id, 0, int(round(damage)))

	return {
		"attacker_damage": 0,
		"defender_damage": int(round(damage)),
		"attacker_died": false,
		"defender_died": not defender.is_alive(),
	}


## An attack on a city. Walls absorb damage first and must be broken before the
## centre can be touched — and only a melee unit can actually take the city, so
## bombardment alone will never finish the job.
static func resolve_city_attack(
	game: Node, attacker: UnitState, city: CityState, ranged: bool
) -> Dictionary:
	var attacker_strength := effective_strength(game, attacker, null, true, ranged, city)
	var city_strength := city_defense_strength(game, city)

	var damage := int(round(roll_damage(attacker_strength - city_strength)))
	var wall_damage := 0
	var center_damage := 0

	if city.wall_hp > 0 and not _bypasses_walls(attacker):
		wall_damage = mini(city.wall_hp, damage)
		city.wall_hp -= wall_damage
		# Some damage bleeds through even intact walls, but only a trickle.
		center_damage = int((damage - wall_damage) * 1.0) + int(wall_damage * 0.15)
	else:
		center_damage = damage

	city.center_hp = maxi(0, city.center_hp - center_damage)

	# The city shoots back at anything in range, including ranged attackers.
	var return_damage := 0
	if city.has_walls() or city.center_hp > 0:
		var distance: int = game.map.distance(attacker.coord, city.coord)
		if distance <= city_strike_range(city):
			return_damage = int(round(roll_damage(city_strike_strength(game, city) - _defensive_strength(game, attacker))))
			attacker.hp = maxi(0, attacker.hp - return_damage)

	attacker.has_attacked = true
	attacker.spend_all_movement()
	_award_experience(game, attacker, city_strength, attacker_strength)

	return {
		"wall_damage": wall_damage,
		"center_damage": center_damage,
		"attacker_damage": return_damage,
		"attacker_died": not attacker.is_alive(),
		"city_fell": city.center_hp <= 0,
		"can_capture": city.center_hp <= 0 and not ranged and attacker.is_military(),
	}


static func _bypasses_walls(attacker: UnitState) -> bool:
	# Siege units hit the walls themselves rather than being stopped by them.
	return attacker.unit_class() == UnitDefs.UnitClass.SIEGE


static func _defensive_strength(game: Node, unit: UnitState) -> float:
	return effective_strength(game, unit, null, false)


## City Combat Strength, tracking the best melee unit its owner can field plus a
## bonus per district — so a developed city resists a siege even without a
## garrison.
static func city_defense_strength(game: Node, city: CityState) -> float:
	var owner: PlayerState = game.get_player(city.owner_id)
	var best := 10.0
	if owner != null:
		for unit_def: UnitDefs.UnitDef in ContentDB.units.values():
			if unit_def.unit_class != UnitDefs.UnitClass.MELEE:
				continue
			if unit_def.required_tech != &"" and not owner.has_tech(unit_def.required_tech):
				continue
			best = maxf(best, unit_def.combat_strength)

	var strength := city.compute_defense_strength(best, game.military_unit_at(city.coord))

	if owner != null:
		strength += game.modifiers.sum_scalar(
			ModifierEngine.EFFECT_UNIT_COMBAT_STRENGTH, {"player": owner, "city": city}
		)
	return strength


## Cities with walls can strike back at range 2, using the best ranged unit
## their owner has access to.
static func city_strike_strength(game: Node, city: CityState) -> float:
	var owner: PlayerState = game.get_player(city.owner_id)
	var best := 3.0   # a floor, so even a city with no ranged tech is not defenceless
	if owner != null:
		for unit_def: UnitDefs.UnitDef in ContentDB.units.values():
			if not unit_def.is_ranged():
				continue
			if unit_def.required_tech != &"" and not owner.has_tech(unit_def.required_tech):
				continue
			best = maxf(best, unit_def.ranged_strength)
	return best


static func city_strike_range(_city: CityState) -> int:
	return 2


## XP scales with how much tougher the opponent was, capped so farming weak
## targets cannot fast-track a unit to maximum level.
static func _award_experience(game: Node, unit: UnitState, opponent_strength: float, own_strength: float) -> void:
	if not unit.is_alive() or not unit.is_military():
		return
	var ratio := opponent_strength / maxf(own_strength, 1.0)
	var base := clampi(int(round(2.0 + ratio * 3.0)), 1, UnitState.MAX_XP_PER_COMBAT)

	var player: PlayerState = game.get_player(unit.owner_id)
	if player != null:
		var percent: float = game.modifiers.sum_scalar(
			ModifierEngine.EFFECT_UNIT_EXPERIENCE_PERCENT, {"player": player, "unit": unit}
		)
		base = int(round(base * (1.0 + percent * 0.01)))

	if unit.award_xp(base):
		EventBus.unit_promoted.emit(unit.id, &"")
