class_name BarbarianSystem
extends RefCounted

## Barbarians.
##
## Outposts spawn in territory nobody is watching, and each one sends out a
## scout. If that scout finds a city and gets home, the outpost starts producing
## a raid aimed at it — which makes intercepting scouts a real defensive play
## rather than flavour. Outposts also arm themselves from local geography:
## horses nearby means cavalry raids.

const MAX_OUTPOSTS_PER_PLAYER := 2
const SPAWN_CHANCE_PER_TURN := 0.12
const RAID_SIZE_MIN := 3
const RAID_SIZE_MAX := 6
## Hard ceiling on the standing barbarian army. Without it, outposts that go
## unchallenged accumulate units indefinitely and the map fills with them.
const MAX_UNITS_PER_OUTPOST := 4
## Outposts stop appearing once the map is well settled and watched.
const MIN_DISTANCE_FROM_CITY := 4

## outpost coord -> {"scout_out": bool, "target": Vector2i, "raid_remaining": int}
static var _outposts: Dictionary = {}


static func reset() -> void:
	_outposts.clear()


static func process_turn(game: Node) -> void:
	var barbarian: PlayerState = _barbarian_player(game)
	if barbarian == null:
		return

	_prune_destroyed_outposts(game)
	_maybe_spawn_outpost(game, barbarian)
	_spawn_raid_units(game, barbarian)
	_act(game, barbarian)


static func _barbarian_player(game: Node) -> PlayerState:
	for player: PlayerState in game.players.values():
		if player.kind == PlayerState.Kind.BARBARIAN:
			return player
	return null


static func _prune_destroyed_outposts(game: Node) -> void:
	for coord: Vector2i in _outposts.keys():
		var tile: Tile = game.map.get_tile(coord)
		if tile == null or not tile.barbarian_outpost:
			_outposts.erase(coord)


static func _maybe_spawn_outpost(game: Node, barbarian: PlayerState) -> void:
	var major_count: int = game.major_players().size()
	if _outposts.size() >= major_count * MAX_OUTPOSTS_PER_PLAYER:
		return
	if not RNGService.chance(RNGService.STREAM_BARBARIAN, SPAWN_CHANCE_PER_TURN):
		return

	var candidates: Array[Vector2i] = []
	for tile: Tile in game.map.all_tiles():
		if not tile.is_land() or tile.is_impassable() or tile.has_district():
			continue
		if tile.barbarian_outpost or tile.owner_id != -1:
			continue
		if _visible_to_anyone(game, tile.coord):
			continue
		if _too_close_to_city(game, tile.coord):
			continue
		candidates.append(tile.coord)

	if candidates.is_empty():
		return

	var coord: Vector2i = RNGService.pick(RNGService.STREAM_BARBARIAN, candidates)
	game.map.get_tile(coord).barbarian_outpost = true
	_outposts[coord] = {"scout_out": false, "target": Vector2i(-9999, -9999), "raid_remaining": 0}

	# Each outpost starts with a scout to find targets and one defender.
	UnitSystem.spawn(game, barbarian, &"scout", coord)
	UnitSystem.spawn(game, barbarian, _melee_unit_for(game, coord), coord)
	_outposts[coord]["scout_out"] = true


## Outposts near horses field cavalry; everything else gets infantry. Ties the
## threat you face to the ground you left unwatched.
static func _melee_unit_for(game: Node, coord: Vector2i) -> StringName:
	for tile in game.map.tiles_within(coord, 6):
		if tile.resource_id == &"horses":
			return &"heavy_chariot"
	return &"warrior"


static func _visible_to_anyone(game: Node, coord: Vector2i) -> bool:
	for player: PlayerState in game.players.values():
		if player.kind != PlayerState.Kind.BARBARIAN and game.map.is_visible(player.id, coord):
			return true
	return false


static func _too_close_to_city(game: Node, coord: Vector2i) -> bool:
	for city: CityState in game.cities.values():
		if game.map.distance(city.coord, coord) < MIN_DISTANCE_FROM_CITY:
			return true
	return false


static func _spawn_raid_units(game: Node, barbarian: PlayerState) -> void:
	# Barbarians are a pressure that should force a standing defence, not an
	# unbounded flood that decides the game on its own.
	var ceiling: int = maxi(1, _outposts.size()) * MAX_UNITS_PER_OUTPOST
	if game.unit_count_of(barbarian.id) >= ceiling:
		return

	for coord: Vector2i in _outposts:
		var data: Dictionary = _outposts[coord]
		if int(data.get("raid_remaining", 0)) <= 0:
			continue
		if game.unit_count_of(barbarian.id) >= ceiling:
			return
		data["raid_remaining"] = int(data["raid_remaining"]) - 1
		# Mix melee and ranged so a raid is not trivially countered by one
		# unit type.
		var unit_id := _melee_unit_for(game, coord)
		if RNGService.chance(RNGService.STREAM_BARBARIAN, 0.35):
			unit_id = &"archer" if barbarian.has_tech(&"archery") else &"slinger"
		UnitSystem.spawn(game, barbarian, unit_id, coord)


static func _act(game: Node, barbarian: PlayerState) -> void:
	for unit: UnitState in game.units_of(barbarian.id):
		if not unit.is_alive():
			continue
		if unit.unit_class() == UnitDefs.UnitClass.RECON:
			_act_scout(game, unit)
		else:
			_act_raider(game, unit)


## A scout hunts for a city, then runs home to report it. Killing it before it
## returns prevents the raid entirely.
static func _act_scout(game: Node, unit: UnitState) -> void:
	var target := _nearest_enemy_city(game, unit)

	if target.x != -9999 and not _carrying_report(unit):
		unit.automation = &"reporting"
		_remember_target(game, unit, target)

	if unit.automation == &"reporting":
		var home := _nearest_outpost(game, unit.coord)
		if home.x != -9999:
			if game.map.distance(unit.coord, home) <= 1:
				_report_target(game, unit, home)
				return
			var path := UnitSystem.find_path(game, unit, home)
			UnitSystem.move_along(game, unit, path)
			return

	_wander(game, unit)


static func _carrying_report(unit: UnitState) -> bool:
	return unit.automation == &"reporting"


static func _remember_target(game: Node, unit: UnitState, target: Vector2i) -> void:
	var home := _nearest_outpost(game, unit.coord)
	if home.x != -9999 and _outposts.has(home):
		_outposts[home]["target"] = target


static func _report_target(game: Node, unit: UnitState, home: Vector2i) -> void:
	unit.automation = &""
	if not _outposts.has(home):
		return
	var data: Dictionary = _outposts[home]
	if data.get("target", Vector2i(-9999, -9999)).x == -9999:
		return
	# The report triggers a wave over the following turns.
	data["raid_remaining"] = RNGService.randi_range_in(
		RNGService.STREAM_BARBARIAN, RAID_SIZE_MIN, RAID_SIZE_MAX
	)


static func _act_raider(game: Node, unit: UnitState) -> void:
	# Attack anything adjacent first.
	for n in game.map.neighbors(unit.coord):
		if UnitSystem.can_attack_tile(game, unit, n.coord):
			UnitSystem.attack(game, unit, n.coord)
			return

	var home := _nearest_outpost(game, unit.coord)
	var target := Vector2i(-9999, -9999)
	if home.x != -9999 and _outposts.has(home):
		target = _outposts[home].get("target", Vector2i(-9999, -9999))
	if target.x == -9999:
		target = _nearest_enemy_city(game, unit)

	if target.x != -9999:
		var path := UnitSystem.find_path(game, unit, target)
		if not path.is_empty():
			UnitSystem.move_along(game, unit, path)
			# Attack on arrival if the move brought it into range.
			for n in game.map.neighbors(unit.coord):
				if UnitSystem.can_attack_tile(game, unit, n.coord):
					UnitSystem.attack(game, unit, n.coord)
					return
			return

	_wander(game, unit)


static func _wander(game: Node, unit: UnitState) -> void:
	var options: Array[Vector2i] = []
	for n in game.map.neighbors(unit.coord):
		if UnitSystem.can_enter(game, unit, n.coord):
			options.append(n.coord)
	if options.is_empty():
		return
	var destination: Vector2i = RNGService.pick(RNGService.STREAM_BARBARIAN, options)
	UnitSystem.step(game, unit, destination)


static func _nearest_enemy_city(game: Node, unit: UnitState) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_distance := 999
	for city: CityState in game.cities.values():
		var owner: PlayerState = game.get_player(city.owner_id)
		if owner == null or owner.kind == PlayerState.Kind.BARBARIAN:
			continue
		if not game.map.is_explored(unit.owner_id, city.coord):
			continue
		var distance: int = game.map.distance(unit.coord, city.coord)
		if distance < best_distance:
			best_distance = distance
			best = city.coord
	return best


static func _nearest_outpost(game: Node, coord: Vector2i) -> Vector2i:
	var best := Vector2i(-9999, -9999)
	var best_distance := 999
	for outpost: Vector2i in _outposts:
		var distance: int = game.map.distance(coord, outpost)
		if distance < best_distance:
			best_distance = distance
			best = outpost
	return best


## Clearing an outpost is worth gold and fires the Military Tradition
## inspiration.
static func clear_outpost(game: Node, player: PlayerState, coord: Vector2i) -> void:
	var tile: Tile = game.map.get_tile(coord)
	if tile == null or not tile.barbarian_outpost:
		return
	tile.barbarian_outpost = false
	_outposts.erase(coord)
	player.gold += 50.0
	player.bump_boost_counter(&"outposts_cleared")
	EventBus.notification_posted.emit(
		player.id, &"outpost_cleared", "Barbarian outpost destroyed.", coord
	)
