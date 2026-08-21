class_name UnitSystem
extends RefCounted

## Unit movement, stacking, Zone of Control, and the actions units can take.
##
## Stacking follows Civ 6: at most one military and one civilian unit per tile.
## That single rule is what makes terrain matter — armies form fronts instead of
## collapsing into one invincible stack, and a chokepoint is genuinely a
## chokepoint.

static func spawn(game: Node, player: PlayerState, unit_id: StringName, coord: Vector2i) -> UnitState:
	var def := ContentDB.get_unit(unit_id)
	if def == null:
		return null

	# Find a free tile: the requested one if the right slot is open, otherwise
	# the nearest tile that can take it.
	var target := _find_spawn_tile(game, player, def, coord)
	if target.x == -9999:
		return null

	var unit := UnitState.new(game.next_unit_id(), player.id, unit_id)
	unit.coord = target
	if def.charges > 0:
		var bonus: float = game.modifiers.sum_scalar(
			ModifierEngine.EFFECT_BUILDER_CHARGES, {"player": player}
		)
		unit.charges = def.charges + int(bonus)

	game.register_unit(unit)
	game.map.reveal_around(player.id, target, def.sight)
	EventBus.unit_created.emit(unit.id)
	return unit


static func _find_spawn_tile(game: Node, player: PlayerState, def: UnitDefs.UnitDef, coord: Vector2i) -> Vector2i:
	for radius in 4:
		for candidate in Hex.within_radius(coord, radius):
			var tile: Tile = game.map.get_tile(candidate)
			if tile == null or tile.is_impassable():
				continue
			if tile.is_water() != def.is_naval():
				continue
			if _slot_occupied(game, candidate, def.is_military()):
				continue
			if tile.owner_id != -1 and tile.owner_id != player.id:
				continue
			return candidate
	return Vector2i(-9999, -9999)


static func _slot_occupied(game: Node, coord: Vector2i, military: bool) -> bool:
	var occupant: UnitState = game.military_unit_at(coord) if military else game.civilian_unit_at(coord)
	return occupant != null


# -------------------------------------------------------------------------
# Movement
# -------------------------------------------------------------------------

## Whether `unit` may enter `coord` this turn, ignoring movement cost.
static func can_enter(game: Node, unit: UnitState, coord: Vector2i) -> bool:
	var tile: Tile = game.map.get_tile(coord)
	if tile == null or tile.is_impassable():
		return false

	var def := unit.definition()
	if def == null:
		return false

	# Land units need embarkation tech to cross water; naval units can never
	# leave it.
	if tile.is_water() and not def.is_naval():
		var player: PlayerState = game.get_player(unit.owner_id)
		if player == null or not player.has_tech(&"sailing"):
			return false
	if not tile.is_water() and def.is_naval():
		# Naval units may enter a friendly coastal city, and nothing else.
		var city: CityState = game.city_at(coord)
		if city == null or city.owner_id != unit.owner_id:
			return false

	# Stacking: one military and one civilian per tile, and the slot is held
	# against everyone — a foreign unit blocks the tile even at peace, which is
	# what stops two civilizations' armies occupying the same ground.
	var blocker: UnitState = game.military_unit_at(coord) if def.is_military() else game.civilian_unit_at(coord)
	if blocker != null:
		return false

	# An enemy unit or city blocks entry — you attack it instead of walking in.
	for other: UnitState in game.units_at(coord):
		if _hostile(game, unit.owner_id, other.owner_id):
			return false
	var city: CityState = game.city_at(coord)
	if city != null and _hostile(game, unit.owner_id, city.owner_id):
		return false

	return true


static func _hostile(game: Node, a_id: int, b_id: int) -> bool:
	if a_id == b_id:
		return false
	var a: PlayerState = game.get_player(a_id)
	var b: PlayerState = game.get_player(b_id)
	if a == null or b == null:
		return false
	# Barbarians are permanently at war with everyone.
	if a.kind == PlayerState.Kind.BARBARIAN or b.kind == PlayerState.Kind.BARBARIAN:
		return true
	return a.is_at_war_with(b_id)


## Tiles adjacent to a hostile military unit or city lock a unit in place once
## it enters them. This is what stops an army from simply walking around a
## defensive line.
static func in_enemy_zoc(game: Node, unit: UnitState, coord: Vector2i) -> bool:
	var def := unit.definition()
	if def != null and def.ignores_zoc:
		return false
	for n in game.map.neighbors(coord):
		var enemy: UnitState = game.military_unit_at(n.coord)
		if enemy != null and _hostile(game, unit.owner_id, enemy.owner_id):
			return true
		var city: CityState = game.city_at(n.coord)
		if city != null and _hostile(game, unit.owner_id, city.owner_id):
			return true
	return false


## Move one tile. Returns false if the move is illegal or unaffordable.
static func step(game: Node, unit: UnitState, coord: Vector2i) -> bool:
	if unit.movement_left <= 0.0 or not can_enter(game, unit, coord):
		return false

	var tile: Tile = game.map.get_tile(coord)
	var cost := float(tile.movement_cost())

	# A unit with any movement left can always make at least one step, so a
	# single move point is never wasted against rough terrain.
	if cost > unit.movement_left and unit.movement_left < float(unit.definition().movement):
		return false

	var from := unit.coord
	var was_in_zoc := in_enemy_zoc(game, unit, from)

	game.move_unit(unit, coord)
	unit.movement_left = maxf(0.0, unit.movement_left - cost)
	unit.is_fortified = false
	unit.fortify_turns = 0
	unit.is_set_up = false

	# Entering a Zone of Control ends movement for the turn — though the unit
	# may still attack with what it has left.
	if not was_in_zoc and in_enemy_zoc(game, unit, coord):
		unit.movement_left = 0.0

	unit.is_embarked = tile.is_water() and not unit.definition().is_naval()

	game.map.reveal_around(unit.owner_id, coord, unit.definition().sight)
	EventBus.unit_moved.emit(unit.id, from, coord)
	return true


## Shortest path between two tiles for this unit, or an empty array if none
## exists. Breadth-first over movement cost; maps are small enough that this
## stays cheap and it avoids maintaining a separate AStar graph as terrain,
## borders and war declarations change.
static func find_path(game: Node, unit: UnitState, goal: Vector2i, limit: int = 60) -> Array[Vector2i]:
	var start := unit.coord
	if start == goal:
		return []

	var came_from := {start: start}
	var cost_so_far := {start: 0.0}
	var frontier: Array = [{"coord": start, "cost": 0.0}]
	var explored := 0

	while not frontier.is_empty() and explored < limit * 40:
		frontier.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["cost"] < b["cost"])
		var current: Dictionary = frontier.pop_front()
		var coord: Vector2i = current["coord"]
		explored += 1

		if coord == goal:
			return _reconstruct(came_from, start, goal)

		for n in game.map.neighbors(coord):
			# The goal itself may be occupied by an enemy — that is the point of
			# pathing to it — so only intermediate tiles must be enterable.
			if n.coord != goal and not can_enter(game, unit, n.coord):
				continue
			var new_cost: float = cost_so_far[coord] + float(n.movement_cost())
			if new_cost > limit:
				continue
			if cost_so_far.has(n.coord) and new_cost >= cost_so_far[n.coord]:
				continue
			cost_so_far[n.coord] = new_cost
			came_from[n.coord] = coord
			frontier.append({"coord": n.coord, "cost": new_cost + game.map.distance(n.coord, goal)})

	return [] as Array[Vector2i]


static func _reconstruct(came_from: Dictionary, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var current := goal
	while current != start:
		path.push_front(current)
		current = came_from[current]
		if path.size() > 200:
			break
	return path


## Walk as far along a path as this turn's movement allows.
static func move_along(game: Node, unit: UnitState, path: Array[Vector2i]) -> int:
	var steps := 0
	for coord in path:
		if unit.movement_left <= 0.0:
			break
		if not step(game, unit, coord):
			break
		steps += 1
	return steps


# -------------------------------------------------------------------------
# Attacking
# -------------------------------------------------------------------------

static func can_attack_tile(game: Node, unit: UnitState, coord: Vector2i) -> bool:
	if not unit.can_attack():
		return false
	var def := unit.definition()
	var distance: int = game.map.distance(unit.coord, coord)

	if def.is_ranged():
		if distance > def.range:
			return false
		# Siege engines must be set up before firing, so they cannot move and
		# shoot in the same turn.
		if def.must_set_up_to_attack and not unit.is_set_up:
			return false
	elif distance != 1:
		return false

	var target: UnitState = game.military_unit_at(coord)
	if target != null and _hostile(game, unit.owner_id, target.owner_id):
		return true
	var city: CityState = game.city_at(coord)
	if city != null and _hostile(game, unit.owner_id, city.owner_id):
		return true
	# An undefended civilian can be captured rather than attacked.
	var civilian: UnitState = game.civilian_unit_at(coord)
	return civilian != null and _hostile(game, unit.owner_id, civilian.owner_id)


static func attack(game: Node, unit: UnitState, coord: Vector2i) -> Dictionary:
	if not can_attack_tile(game, unit, coord):
		return {}

	var def := unit.definition()
	var ranged := def.is_ranged()

	var city: CityState = game.city_at(coord)
	if city != null and _hostile(game, unit.owner_id, city.owner_id):
		var result := Combat.resolve_city_attack(game, unit, city, ranged)
		if result.get("can_capture", false):
			var owner: PlayerState = game.get_player(unit.owner_id)
			CitySystem.capture_city(game, city, owner)
			step(game, unit, coord)
		_cleanup(game, unit)
		return result

	var target: UnitState = game.military_unit_at(coord)
	if target == null:
		# Undefended civilian: captured outright rather than fought.
		var civilian: UnitState = game.civilian_unit_at(coord)
		if civilian != null:
			_capture_civilian(game, unit, civilian)
			return {"captured": true}
		return {}

	var result := Combat.resolve_melee(game, unit, target) if not ranged \
		else Combat.resolve_ranged(game, unit, target)

	_cleanup(game, target)
	_cleanup(game, unit)

	# A melee attacker that clears the tile advances onto it.
	if not ranged and result.get("defender_died", false) and unit.is_alive():
		if game.civilian_unit_at(coord) == null and game.city_at(coord) == null:
			unit.movement_left = 1.0
			step(game, unit, coord)

	return result


static func _capture_civilian(game: Node, captor: UnitState, civilian: UnitState) -> void:
	# Settlers become Builders when captured, which stops capture being a free
	# way to plant cities deep in enemy land.
	var new_id := &"builder" if civilian.unit_id == &"settler" else civilian.unit_id
	var owner: PlayerState = game.get_player(captor.owner_id)
	var coord := civilian.coord
	game.unregister_unit(civilian)
	EventBus.unit_killed.emit(civilian.id, captor.id)
	spawn(game, owner, new_id, coord)
	captor.has_attacked = true
	captor.spend_all_movement()


static func _cleanup(game: Node, unit: UnitState) -> void:
	if unit != null and not unit.is_alive():
		game.unregister_unit(unit)
		EventBus.unit_killed.emit(unit.id, -1)


# -------------------------------------------------------------------------
# Actions
# -------------------------------------------------------------------------

static func fortify(unit: UnitState) -> void:
	unit.is_fortified = true
	unit.spend_all_movement()


static func set_up(unit: UnitState) -> void:
	unit.is_set_up = true
	unit.spend_all_movement()


## Spend a Builder charge on an improvement. Builders vanish once spent, which
## is what makes each charge a real decision rather than an afterthought.
static func build_improvement(game: Node, unit: UnitState, improvement_id: StringName) -> bool:
	if unit.charges <= 0 or unit.movement_left <= 0.0:
		return false
	var tile: Tile = game.map.get_tile(unit.coord)
	var improvement := ContentDB.get_improvement(improvement_id)
	if tile == null or improvement == null or not tile.can_have_improvement(improvement):
		return false

	var player: PlayerState = game.get_player(unit.owner_id)
	if player == null or tile.owner_id != player.id:
		return false
	if improvement.required_tech != &"" and not player.has_tech(improvement.required_tech):
		return false

	tile.improvement_id = improvement_id
	tile.is_pillaged = false
	if improvement.removes_feature and tile.feature_id != &"":
		var feature := tile.feature()
		if feature != null and feature.removable:
			tile.feature_id = &""

	game.map.recompute_appeal_around(unit.coord, 1)

	unit.charges -= 1
	unit.spend_all_movement()
	if unit.charges <= 0:
		game.unregister_unit(unit)
		EventBus.unit_killed.emit(unit.id, -1)

	EventBus.tile_changed.emit(tile.coord)
	return true


static func found_city(game: Node, unit: UnitState, city_name: String = "") -> CityState:
	var def := unit.definition()
	if def == null or not def.can_found_city:
		return null
	var player: PlayerState = game.get_player(unit.owner_id)
	if player == null or not can_found_city_at(game, player, unit.coord):
		return null

	var city := CitySystem.found_city(game, player, unit.coord, city_name)
	if city != null:
		game.unregister_unit(unit)
		EventBus.unit_killed.emit(unit.id, -1)
	return city


## Cities need breathing room — Civ 6 enforces a minimum distance so a player
## cannot carpet the map with size-1 cities.
static func can_found_city_at(game: Node, player: PlayerState, coord: Vector2i) -> bool:
	var tile: Tile = game.map.get_tile(coord)
	if tile == null or not tile.is_land() or tile.is_impassable() or tile.has_district():
		return false
	if tile.terrain_id == &"mountains" or tile.natural_wonder_id != &"":
		return false
	if tile.owner_id != -1 and tile.owner_id != player.id:
		return false
	for city: CityState in game.cities.values():
		if game.map.distance(city.coord, coord) < 4:
			return false
	return true


# -------------------------------------------------------------------------
# Turn processing
# -------------------------------------------------------------------------

static func begin_turn(game: Node, player: PlayerState) -> void:
	for unit: UnitState in game.units_of(player.id):
		unit.begin_turn()
		_apply_movement_modifiers(game, player, unit)
		_heal(game, unit)
		game.map.reveal_around(player.id, unit.coord, unit.definition().sight)


static func _apply_movement_modifiers(game: Node, player: PlayerState, unit: UnitState) -> void:
	var bonus: float = game.modifiers.sum_scalar(
		ModifierEngine.EFFECT_UNIT_MOVEMENT, {"player": player, "unit": unit}
	)
	for promotion_id: StringName in unit.promotions:
		var promotion: UnitDefs.PromotionDef = ContentDB.promotions.get(promotion_id)
		if promotion == null:
			continue
		for m in promotion.modifiers:
			if m.effect == ModifierEngine.EFFECT_UNIT_MOVEMENT:
				bonus += m.arg_float("amount")
	unit.movement_left += bonus


static func _heal(game: Node, unit: UnitState) -> void:
	if unit.hp >= UnitState.MAX_HP:
		return
	var tile: Tile = game.map.get_tile(unit.coord)
	var in_friendly := tile != null and tile.owner_id == unit.owner_id
	var city: CityState = game.city_at(unit.coord)
	var in_city := city != null and city.owner_id == unit.owner_id
	# Healing is decided by what the unit did *last* turn, so this reads the
	# flags before begin_turn resets them.
	unit.hp = mini(UnitState.MAX_HP, unit.hp + unit.heal_amount(in_friendly, in_city))


## Total gold upkeep for a player's army.
static func maintenance_cost(game: Node, player: PlayerState) -> float:
	var total := 0.0
	var per_unit: float = game.modifiers.sum_scalar(
		ModifierEngine.EFFECT_UNIT_MAINTENANCE, {"player": player}
	)
	for unit: UnitState in game.units_of(player.id):
		var def := unit.definition()
		if def != null:
			total += maxf(0.0, def.maintenance + per_unit)
	return total
