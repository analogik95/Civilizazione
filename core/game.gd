extends Node

## Root of the running game: owns the map, the players, and the turn loop.
##
## Deliberately thin — it wires systems together and owns the master state, but
## the rules themselves live in the systems it delegates to. Everything here is
## engine-free enough to run under --headless for AI-vs-AI soak testing.
##
## Spatial indexes matter more than they look. "What is standing on this tile?"
## is asked thousands of times per turn — once per neighbour per pathfinding
## step — so scanning every unit each time turns an O(n) question into an O(n²)
## turn. The indexes below are maintained on every move, spawn and death, and
## every positional lookup goes through them.

signal state_ready()

enum Phase { NONE, SETUP, PLAYING, FINISHED }

var phase: Phase = Phase.NONE
var turn: int = 1
var turn_limit: int = 500

var map: MapModel = null
var modifiers: ModifierEngine = null

## player_id -> PlayerState. Includes AI players, city-states and the
## barbarian pseudo-player, all distinguished by PlayerState.kind.
var players: Dictionary = {}
var player_order: Array[int] = []
var current_player_index: int = 0

var cities: Dictionary = {}   # city_id -> CityState
var units: Dictionary = {}    # unit_id -> UnitState

# --- Indexes, maintained by register/unregister/move below ---
var _military_at: Dictionary = {}      # coord -> UnitState
var _civilian_at: Dictionary = {}      # coord -> UnitState
var _city_at: Dictionary = {}          # coord -> CityState
var _units_by_player: Dictionary = {}  # player_id -> {unit_id: UnitState}
var _cities_by_player: Dictionary = {} # player_id -> {city_id: CityState}

var _next_city_id: int = 1
var _next_unit_id: int = 1

var winner_id: int = -1
var victory_type: StringName = &""

## Set when running headless from tests/sim_runner.gd, so systems can skip
## presentation-only work.
var headless: bool = false


func reset() -> void:
	phase = Phase.NONE
	turn = 1
	map = null
	modifiers = ModifierEngine.new()
	players.clear()
	player_order.clear()
	current_player_index = 0
	cities.clear()
	units.clear()
	_military_at.clear()
	_civilian_at.clear()
	_city_at.clear()
	_units_by_player.clear()
	_cities_by_player.clear()
	_next_city_id = 1
	_next_unit_id = 1
	winner_id = -1
	victory_type = &""


func next_city_id() -> int:
	var id := _next_city_id
	_next_city_id += 1
	return id


func next_unit_id() -> int:
	var id := _next_unit_id
	_next_unit_id += 1
	return id


# -------------------------------------------------------------------------
# Index maintenance
# -------------------------------------------------------------------------

## Coordinates are normalised before they reach an index. On a wrapping map the
## same tile can be named by more than one raw axial coordinate, and indexing by
## the raw value lets two units occupy one tile while each believes it is alone.
func _key(coord: Vector2i) -> Vector2i:
	return map.normalize(coord) if map != null else coord


func register_unit(unit: UnitState) -> void:
	unit.coord = _key(unit.coord)
	units[unit.id] = unit
	_units_by_player.get_or_add(unit.owner_id, {})[unit.id] = unit
	_occupancy_for(unit)[unit.coord] = unit


func unregister_unit(unit: UnitState) -> void:
	units.erase(unit.id)
	var owned: Dictionary = _units_by_player.get(unit.owner_id, {})
	owned.erase(unit.id)
	var slot := _occupancy_for(unit)
	if slot.get(_key(unit.coord)) == unit:
		slot.erase(_key(unit.coord))


## Move a unit's index entry. Call this instead of assigning unit.coord.
func move_unit(unit: UnitState, to: Vector2i) -> void:
	var slot := _occupancy_for(unit)
	if slot.get(unit.coord) == unit:
		slot.erase(unit.coord)
	unit.coord = _key(to)
	slot[unit.coord] = unit


func _occupancy_for(unit: UnitState) -> Dictionary:
	var def := unit.definition()
	return _military_at if def != null and def.is_military() else _civilian_at


func register_city(city: CityState) -> void:
	city.coord = _key(city.coord)
	cities[city.id] = city
	_cities_by_player.get_or_add(city.owner_id, {})[city.id] = city
	_city_at[city.coord] = city


func reassign_city(city: CityState, new_owner_id: int) -> void:
	var old: Dictionary = _cities_by_player.get(city.owner_id, {})
	old.erase(city.id)
	city.owner_id = new_owner_id
	_cities_by_player.get_or_add(new_owner_id, {})[city.id] = city


# -------------------------------------------------------------------------
# Lookups
# -------------------------------------------------------------------------

func get_player(id: int) -> PlayerState:
	return players.get(id)


func get_city(id: int) -> CityState:
	return cities.get(id)


func get_unit(id: int) -> UnitState:
	return units.get(id)


func current_player() -> PlayerState:
	if player_order.is_empty():
		return null
	return players.get(player_order[current_player_index])


## Major civilizations only — excludes city-states and barbarians. Victory
## checks, the World Congress and diplomacy all operate on this set.
func major_players() -> Array[PlayerState]:
	var out: Array[PlayerState] = []
	for p: PlayerState in players.values():
		if p.kind == PlayerState.Kind.MAJOR and p.is_alive:
			out.append(p)
	return out


func cities_of(player_id: int) -> Array[CityState]:
	var out: Array[CityState] = []
	for c: CityState in _cities_by_player.get(player_id, {}).values():
		out.append(c)
	return out


func units_of(player_id: int) -> Array[UnitState]:
	var out: Array[UnitState] = []
	for u: UnitState in _units_by_player.get(player_id, {}).values():
		out.append(u)
	return out


func city_count_of(player_id: int) -> int:
	return _cities_by_player.get(player_id, {}).size()


func unit_count_of(player_id: int) -> int:
	return _units_by_player.get(player_id, {}).size()


## Units standing on a tile. Civ 6 allows one military and one civilian to
## share a tile, so this returns at most two.
func units_at(coord: Vector2i) -> Array[UnitState]:
	var out: Array[UnitState] = []
	var key := _key(coord)
	var military: UnitState = _military_at.get(key)
	if military != null:
		out.append(military)
	var civilian: UnitState = _civilian_at.get(key)
	if civilian != null:
		out.append(civilian)
	return out


func military_unit_at(coord: Vector2i) -> UnitState:
	return _military_at.get(_key(coord))


func civilian_unit_at(coord: Vector2i) -> UnitState:
	return _civilian_at.get(_key(coord))


func city_at(coord: Vector2i) -> CityState:
	return _city_at.get(_key(coord))


func is_finished() -> bool:
	return phase == Phase.FINISHED
