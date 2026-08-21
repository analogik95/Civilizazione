extends Node3D

## Composition root for a running game: world, actors, camera, HUD, and the
## input handling that turns clicks into simulation commands.
##
## All player intent funnels through here. The view never mutates state itself —
## it calls UnitSystem/CitySystem and lets the resulting EventBus signals update
## what is drawn.

@onready var _world: HexWorld = $HexWorld
@onready var _units: UnitRenderer = $UnitRenderer
@onready var _cities: CityRenderer = $CityRenderer
@onready var _overlay: TileOverlay = $TileOverlay
@onready var _camera_rig: Node3D = $CameraRig
@onready var _hud: Control = $UI/HUD
@onready var _environment: WorldEnvironment = $WorldEnvironment

## The ring drawn under the selected unit. Parented to the unit's own view so it
## follows the movement tween for free.
var _selection_ring: Node3D = null

var _human_id: int = 0
var _selected_unit: UnitState = null
## Tiles the selected unit can reach this turn, cached so the overlay does not
## re-path on every mouse move.
var _reachable: Array[Vector2i] = []


func _ready() -> void:
	_human_id = _find_human()

	# Same grade the screenshot tool uses, so a screenshot is an honest preview.
	_environment.environment = ArtPalette.build_environment()

	_world.viewing_player_id = _human_id
	_world.build(Game.map)
	_units.viewing_player_id = _human_id
	_units.rebuild()
	_cities.rebuild()
	_camera_rig.set_map_bounds(Game.map)

	_hud.setup(_human_id)
	_hud.end_turn_pressed.connect(_on_end_turn)
	_hud.action_requested.connect(_on_action)
	_hud.next_unit_pressed.connect(_select_next_idle_unit)

	EventBus.player_turn_started.connect(_on_player_turn_started)
	EventBus.game_over.connect(_on_game_over)
	# The city renderer redraws itself on population change; nothing to do here.

	# Open on the capital, or the first unit if no city exists yet.
	var start := _starting_focus()
	if start.x != -9999:
		_camera_rig.focus_on(start)

	_select_next_idle_unit()
	_hud.refresh()


func _find_human() -> int:
	for player: PlayerState in Game.players.values():
		if player.is_human:
			return player.id
	return Game.player_order[0] if not Game.player_order.is_empty() else 0


func _starting_focus() -> Vector2i:
	var cities: Array = Game.cities_of(_human_id)
	if not cities.is_empty():
		return (cities[0] as CityState).coord
	var units: Array = Game.units_of(_human_id)
	if not units.is_empty():
		return (units[0] as UnitState).coord
	return Vector2i(-9999, -9999)


# -------------------------------------------------------------------------
# Input
# -------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _is_human_turn():
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			_on_click(_camera_rig.tile_under(button.position))

	elif event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_SPACE:
				_on_end_turn()
			KEY_TAB:
				_select_next_idle_unit()
			KEY_F:
				if _selected_unit != null:
					UnitSystem.fortify(_selected_unit)
					_refresh_selection()
			KEY_B:
				_on_action(&"found_city")
			KEY_ESCAPE:
				_clear_selection()


func _on_click(coord: Vector2i) -> void:
	if coord.x == -9999 or Game.map.get_tile(coord) == null:
		return

	# Clicking an own unit selects it.
	var military := Game.military_unit_at(coord)
	var civilian := Game.civilian_unit_at(coord)
	for candidate in [military, civilian]:
		if candidate != null and candidate.owner_id == _human_id and candidate != _selected_unit:
			_select(candidate)
			return

	# With a unit selected, a click is an order: attack if the tile is a legal
	# target, otherwise move as far along the path as movement allows.
	if _selected_unit != null:
		if UnitSystem.can_attack_tile(Game, _selected_unit, coord):
			UnitSystem.attack(Game, _selected_unit, coord)
			_refresh_selection()
			return
		var path := UnitSystem.find_path(Game, _selected_unit, coord)
		if not path.is_empty():
			UnitSystem.move_along(Game, _selected_unit, path)
			_refresh_selection()
			return

	# Otherwise, a click on a city opens it.
	var city := Game.city_at(coord)
	if city != null and city.owner_id == _human_id:
		_hud.open_city(city)


func _select(unit: UnitState) -> void:
	_selected_unit = unit
	_attach_selection_ring(unit)
	_update_reachable()
	_hud.set_selected_unit(unit)


func _clear_selection() -> void:
	_selected_unit = null
	_attach_selection_ring(null)
	_overlay.clear()
	_hud.set_selected_unit(null)


## Move the selection ring onto a unit's view node, so it tracks the unit
## through its movement animation without any per-frame work here.
func _attach_selection_ring(unit: UnitState) -> void:
	if _selection_ring != null:
		_selection_ring.queue_free()
		_selection_ring = null
	if unit == null:
		return

	var view: Node3D = _units.view_for(unit.id)
	if view == null:
		return

	var ring := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = ArtPalette.HEX_SIZE * 0.34
	mesh.outer_radius = ArtPalette.HEX_SIZE * 0.44
	mesh.rings = 6
	ring.mesh = mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.93, 0.42)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = material
	ring.position.y = 0.06

	view.add_child(ring)
	_selection_ring = ring


func _refresh_selection() -> void:
	if _selected_unit != null and not _selected_unit.is_alive():
		_clear_selection()
		return
	if _selected_unit != null:
		_update_reachable()
		_hud.set_selected_unit(_selected_unit)
	_hud.refresh()


## Flood-fill the tiles this unit can still reach, and paint them.
func _update_reachable() -> void:
	_reachable.clear()
	if _selected_unit == null or _selected_unit.movement_left <= 0.0:
		_overlay.clear()
		return

	var budget := _selected_unit.movement_left
	var costs := {_selected_unit.coord: 0.0}
	var frontier: Array[Vector2i] = [_selected_unit.coord]

	while not frontier.is_empty():
		var coord: Vector2i = frontier.pop_front()
		for neighbour in Game.map.neighbors(coord):
			if not UnitSystem.can_enter(Game, _selected_unit, neighbour.coord):
				continue
			var cost: float = costs[coord] + float(neighbour.movement_cost())
			if cost > budget:
				continue
			if costs.has(neighbour.coord) and costs[neighbour.coord] <= cost:
				continue
			costs[neighbour.coord] = cost
			_reachable.append(neighbour.coord)
			frontier.append(neighbour.coord)

	_overlay.show_tiles(_reachable, Color(0.42, 0.78, 1.0, 0.26))


func _select_next_idle_unit() -> void:
	# Cycle to the next unit that still has orders to give, which is how a turn
	# actually gets played.
	var units: Array = Game.units_of(_human_id)
	units.sort_custom(func(a: UnitState, b: UnitState) -> bool: return a.id < b.id)

	var start := 0
	if _selected_unit != null:
		start = units.find(_selected_unit) + 1

	for offset in units.size():
		var unit: UnitState = units[(start + offset) % units.size()]
		if unit.movement_left > 0.0 and not unit.is_sleeping and not unit.is_fortified:
			_select(unit)
			_camera_rig.focus_on(unit.coord)
			return

	_clear_selection()


# -------------------------------------------------------------------------
# Actions
# -------------------------------------------------------------------------

func _on_action(action: StringName) -> void:
	if _selected_unit == null:
		return

	match action:
		&"found_city":
			var city := UnitSystem.found_city(Game, _selected_unit)
			if city != null:
				_clear_selection()
				_hud.open_city(city)
			else:
				_hud.notify("A city cannot be founded here.")
		&"fortify":
			UnitSystem.fortify(_selected_unit)
		&"sleep":
			_selected_unit.is_sleeping = true
			_selected_unit.spend_all_movement()
		&"skip":
			_selected_unit.spend_all_movement()
		&"build":
			_build_best_improvement()

	_refresh_selection()
	if _selected_unit == null or _selected_unit.movement_left <= 0.0:
		_select_next_idle_unit()


## Build whichever improvement suits this tile — the player picks the tile, the
## game picks the sensible improvement for what is on it.
func _build_best_improvement() -> void:
	var player: PlayerState = Game.get_player(_human_id)
	var tile: Tile = Game.map.get_tile(_selected_unit.coord)
	if tile == null:
		return

	var best: MapDefs.ImprovementDef = null
	var best_value := -INF
	for improvement: MapDefs.ImprovementDef in ContentDB.improvements.values():
		if improvement.required_tech != &"" and not player.has_tech(improvement.required_tech):
			continue
		if not tile.can_have_improvement(improvement):
			continue
		var gain := improvement.yield_delta()
		var value := (
			gain.get_kind(Yields.Kind.FOOD)
			+ gain.get_kind(Yields.Kind.PRODUCTION) * 1.1
			+ gain.get_kind(Yields.Kind.GOLD) * 0.6
		)
		if tile.resource_id != &"" and improvement.requires_resource:
			value += 5.0
		if value > best_value:
			best_value = value
			best = improvement

	if best == null:
		_hud.notify("Nothing useful can be built on this tile.")
		return
	if not UnitSystem.build_improvement(Game, _selected_unit, best.id):
		_hud.notify("This tile cannot be improved.")


# -------------------------------------------------------------------------
# Turn flow
# -------------------------------------------------------------------------

func _is_human_turn() -> bool:
	var current: PlayerState = Game.current_player()
	return current != null and current.id == _human_id and not Game.is_finished()


func _on_end_turn() -> void:
	if not _is_human_turn():
		return
	_clear_selection()
	TurnManager.end_turn(Game)
	_run_ai_until_human()


## Resolve every AI player between now and the human's next turn, so control
## comes back without the player clicking through anything.
func _run_ai_until_human() -> void:
	var guard := 0
	while not Game.is_finished() and not _is_human_turn() and guard < 200:
		guard += 1
		var current: PlayerState = Game.current_player()
		if current != null and current.is_alive and current.kind == PlayerState.Kind.MAJOR:
			AIController.take_turn(Game, current)
		TurnManager.end_turn(Game)
		# Yield so the frame can present; a long AI phase should not freeze the
		# window.
		if guard % 4 == 0:
			await get_tree().process_frame

	_world.build(Game.map)
	_units.rebuild()
	_cities.rebuild()
	_hud.refresh()
	_select_next_idle_unit()


func _on_player_turn_started(player_id: int) -> void:
	if player_id == _human_id:
		_hud.refresh()


func _on_game_over(winner_id: int, victory_type: StringName) -> void:
	var winner: PlayerState = Game.get_player(winner_id)
	var leader := winner.leader() if winner != null else null
	var name := leader.civilization if leader != null else "Someone"
	var outcome := "You have won" if winner_id == _human_id else "%s has won" % name
	_hud.show_game_over("%s a %s victory on turn %d." % [outcome, victory_type, Game.turn])
