extends Node

## Boots the real interactive scene and drives it, so the playable path is
## verified rather than assumed.
##
##   godot --path . -- --play turns=10 shots=/tmp/play
##
## The screenshot runner proves the *world renderer* works. This proves the
## thing a player actually launches works: main menu -> game view -> HUD ->
## selection -> orders -> end turn. Those are different code paths, and only
## this one exercises the scene files, the camera rig and the HUD.

const SETTLE_FRAMES := 12

var _shots: String = ""
var _index: int = 0


func run(options: Dictionary) -> bool:
	_shots = str(options.get("shots", ""))
	var turns := int(options.get("turns", 6))
	var seed_value := int(options.get("seed", 7))
	var civs := int(options.get("civs", 4))
	var map_size := StringName(str(options.get("map_size", "tiny")))

	print("\n=== Playtest: %d turns, seed %d ===\n" % [turns, seed_value])

	GameSetup.new_game(Game, {
		"seed": seed_value, "civs": civs, "map_size": map_size,
		"turn_limit": 500, "human": 0,
	})
	TurnManager.start_game(Game)

	var scene: PackedScene = load("res://view/game_view.tscn")
	if scene == null:
		printerr("FAIL: game_view.tscn did not load")
		return false

	var view: Node = scene.instantiate()
	add_child(view)
	await _settle()

	if not _check_scene(view):
		return false
	await _shot("boot")

	# Play the opening the way a person would: settle the capital, then run a
	# few turns and confirm the loop keeps returning control.
	if not await _found_capital(view):
		return false
	await _shot("founded")

	for i in turns:
		view.call("_on_end_turn")
		await _settle()
		if Game.is_finished():
			break

	await _shot("turns")

	# The yields lens is view state, so the only way to know it works is to turn
	# it on and look at the result — over our own land, which is the only ground
	# the lens draws on, since it reports what the viewing player can see.
	view.call("_toggle_yield_lens")
	await _settle()
	await _shot("lens")
	view.call("_toggle_yield_lens")
	await _settle()

	# A foreign capital at a wide zoom: the one frame that shows whether banners
	# and flags stay readable when you pull back to look at the whole map, and
	# whether two civilizations' colours actually tell apart.
	await _look_at_rival(view)
	await _shot("rival")

	var human_cities: int = Game.city_count_of(0)
	print("After %d turns: turn %d, human holds %d cities, %d units on the map." % [
		turns, Game.turn, human_cities, Game.units.size()
	])

	if Game.turn <= 1:
		printerr("FAIL: ending turns did not advance the game")
		return false
	if human_cities < 1:
		printerr("FAIL: the human player never founded a city")
		return false

	print("\nPlaytest passed.\n")
	return true


## Every node game_view.gd reaches for by path must exist, or the scene file and
## the script have drifted apart — which fails at runtime, not at import.
func _check_scene(view: Node) -> bool:
	var required := [
		"HexWorld", "UnitRenderer", "CityRenderer", "TileOverlay",
		"CameraRig", "CameraRig/Camera3D", "UI/HUD", "WorldEnvironment", "Sun",
	]
	var ok := true
	for path in required:
		if view.get_node_or_null(NodePath(path)) == null:
			printerr("FAIL: game_view.tscn is missing node '%s'" % path)
			ok = false
	return ok


## Drive the settler through the HUD's own action path, so the button players
## press is the one under test.
func _found_capital(view: Node) -> bool:
	for attempt in 12:
		var settler: UnitState = null
		for unit: UnitState in Game.units_of(0):
			if unit.definition().can_found_city:
				settler = unit
				break
		if settler == null:
			printerr("FAIL: the human player has no settler")
			return false

		view.call("_select", settler)
		await _settle(2)

		if UnitSystem.can_found_city_at(Game, Game.get_player(0), settler.coord):
			view.call("_on_action", &"found_city")
			await _settle()
			if Game.city_count_of(0) > 0:
				print("Capital founded on attempt %d." % (attempt + 1))
				return true

		# Nudge it somewhere legal and try again.
		var moved := false
		for neighbour in Game.map.neighbors(settler.coord):
			if UnitSystem.step(Game, settler, neighbour.coord):
				moved = true
				break
		if not moved:
			printerr("FAIL: settler is stuck and cannot found a city")
			return false
		await _settle(2)

	printerr("FAIL: could not found a capital in 12 attempts")
	return false


## Point the camera at the nearest city that is not the human's, pulled back far
## enough to take in the ground around it.
func _look_at_rival(view: Node) -> void:
	var rig: Node = view.get_node_or_null("CameraRig")
	if rig == null:
		return
	for city: CityState in Game.cities.values():
		if city.owner_id == 0:
			continue
		rig.call("focus_on", city.coord)
		rig.call("set_zoom", 22.0)
		await _settle()
		return
	# No rival has settled yet — still worth the wide shot of our own ground.
	rig.call("set_zoom", 22.0)
	await _settle()


func _settle(frames: int = SETTLE_FRAMES) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(label: String) -> void:
	if _shots == "":
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	_index += 1
	var path := "%s_%d_%s.png" % [_shots, _index, label]
	image.save_png(path)
	print("  saved %s" % path)
