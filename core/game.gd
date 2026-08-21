extends Node

## Root of the running game: owns the map, the players, and the turn loop.
##
## Deliberately thin — it wires systems together and owns the master state, but
## the rules themselves live in the systems it delegates to. Everything here is
## engine-free enough to run under --headless for AI-vs-AI soak testing.

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
	for c: CityState in cities.values():
		if c.owner_id == player_id:
			out.append(c)
	return out


func units_of(player_id: int) -> Array[UnitState]:
	var out: Array[UnitState] = []
	for u: UnitState in units.values():
		if u.owner_id == player_id:
			out.append(u)
	return out


## Units standing on a tile. Civ 6 allows one military and one civilian to
## share a tile, so this can return up to two.
func units_at(coord: Vector2i) -> Array[UnitState]:
	var out: Array[UnitState] = []
	for u: UnitState in units.values():
		if u.coord == coord:
			out.append(u)
	return out


func military_unit_at(coord: Vector2i) -> UnitState:
	for u: UnitState in units.values():
		if u.coord == coord and u.definition().is_military():
			return u
	return null


func civilian_unit_at(coord: Vector2i) -> UnitState:
	for u: UnitState in units.values():
		if u.coord == coord and not u.definition().is_military():
			return u
	return null


func city_at(coord: Vector2i) -> CityState:
	for c: CityState in cities.values():
		if c.coord == coord:
			return c
	return null


func is_finished() -> bool:
	return phase == Phase.FINISHED
