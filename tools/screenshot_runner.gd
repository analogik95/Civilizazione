extends Node

## Renders a real game to a PNG so the look can be checked without a desktop.
##
##   godot --rendering-driver opengl3 --path . -- --shot out=shot.png turns=30
##
## Run it under xvfb-run on a headless box. It is a development tool, not part
## of the game: it builds a game, advances it far enough to have something worth
## looking at, points a camera at the action and writes one frame to disk.

const SETTLE_FRAMES := 8


func run(options: Dictionary) -> bool:
	var out_path: String = str(options.get("out", "shot.png"))
	var turns := int(options.get("turns", 0))
	var seed_value := int(options.get("seed", 7))
	var civs := int(options.get("civs", 4))
	var map_size := StringName(str(options.get("map_size", "tiny")))
	var zoom := float(options.get("zoom", 26.0))
	var pitch := float(options.get("pitch", 52.0))

	GameSetup.new_game(Game, {
		"seed": seed_value, "civs": civs, "map_size": map_size,
		"city_states": int(options.get("city_states", 3)),
		"turn_limit": maxi(turns, 1), "headless": false,
	})
	TurnManager.start_game(Game)

	for _i in turns:
		AIController.take_turn(Game, Game.current_player())
		TurnManager.end_turn(Game)
		if Game.is_finished():
			break

	var world := HexWorld.new()
	world.name = "HexWorld"
	add_child(world)
	world.build(Game.map)

	var units := UnitRenderer.new()
	add_child(units)
	units.rebuild()

	var cities := CityRenderer.new()
	add_child(cities)
	cities.rebuild()

	_add_lighting()
	_add_camera(_focus_point(), zoom, pitch)

	# The renderer needs a few frames before the viewport holds a complete
	# image — multimesh uploads and shader compilation both land late.
	for _i in SETTLE_FRAMES:
		await get_tree().process_frame

	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(out_path)
	if error != OK:
		push_error("could not write %s (error %d)" % [out_path, error])
		return false

	print("wrote %s (%dx%d), turn %d, %d cities, %d units" % [
		out_path, image.get_width(), image.get_height(),
		Game.turn, Game.cities.size(), Game.units.size(),
	])
	print("  focus %v | city views %d | unit views %d | world layers %d" % [
		_focus_point(), cities.get_child_count(), units.get_child_count(),
		world.get_child_count(),
	])
	_print_terrain_census()
	return true


## What the generator actually produced. A map that looks wrong usually is
## wrong, and the histogram says so faster than staring at it does.
func _print_terrain_census() -> void:
	var terrain: Dictionary = {}
	var features: Dictionary = {}
	var hills := 0
	var total := 0
	for tile: Tile in Game.map.all_tiles():
		terrain[tile.terrain_id] = int(terrain.get(tile.terrain_id, 0)) + 1
		if tile.feature_id != &"":
			features[tile.feature_id] = int(features.get(tile.feature_id, 0)) + 1
		if tile.is_hills:
			hills += 1
		total += 1

	print("  terrain census of %d tiles:" % total)
	var names: Array = terrain.keys()
	names.sort_custom(func(a: Variant, b: Variant) -> bool: return terrain[a] > terrain[b])
	for name: Variant in names:
		print("    %-12s %5d  %5.1f%%" % [name, terrain[name], 100.0 * terrain[name] / total])
	print("    %-12s %5d  %5.1f%% (of land)" % ["hills", hills, 100.0 * hills / maxi(total, 1)])
	for name: Variant in features:
		print("    feature %-10s %5d" % [name, features[name]])


## Aim at the busiest part of the map: the largest city if any has been founded,
## otherwise wherever the most units are standing. Framing the geometric centre
## of a map is a good way to photograph open ocean.
func _focus_point() -> Vector3:
	var best_city: CityState = null
	for city: CityState in Game.cities.values():
		if best_city == null or city.population > best_city.population:
			best_city = city
	if best_city != null:
		return Hex.to_world(best_city.coord, ArtPalette.HEX_SIZE)

	var sum := Vector3.ZERO
	var count := 0
	for unit: UnitState in Game.units.values():
		sum += Hex.to_world(unit.coord, ArtPalette.HEX_SIZE)
		count += 1
	if count > 0:
		return sum / float(count)

	if Game.map != null:
		return Hex.to_world(
			MapModel.offset_to_axial(int(Game.map.width / 2.0), int(Game.map.height / 2.0)),
			ArtPalette.HEX_SIZE,
		)
	return Vector3.ZERO


func _add_camera(target: Vector3, distance: float, pitch_degrees: float) -> Camera3D:
	var camera := Camera3D.new()
	camera.name = "ShotCamera"
	camera.fov = 55.0
	camera.far = 4000.0
	# Must be in the tree before look_at — it resolves against global transforms.
	add_child(camera)

	var pitch := deg_to_rad(pitch_degrees)
	var offset := Vector3(0.0, sin(pitch), cos(pitch)) * distance
	camera.global_position = target + offset
	camera.look_at(target, Vector3.UP)
	camera.current = true
	return camera


func _add_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50.0, -40.0, 0.0)
	sun.light_energy = 1.0
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	add_child(sun)

	var world_environment := WorldEnvironment.new()
	world_environment.environment = build_environment()
	add_child(world_environment)


## Shared by the screenshot tool and the real game so what you see here is what
## the game looks like.
##
## The grade is deliberately restrained: a low-poly kit lit hard goes chalky,
## because every surface is a flat colour with no texture detail to hold the
## shading. Ambient stays low so faces actually differ in brightness, and the
## saturation lift puts back what tonemapping takes out.
static func build_environment() -> Environment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.38, 0.55, 0.72)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.50, 0.58, 0.72)
	environment.ambient_light_energy = 0.34

	environment.fog_enabled = true
	environment.fog_light_color = Color(0.52, 0.64, 0.78)
	environment.fog_density = 0.0018

	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.05
	environment.tonemap_white = 3.0

	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.16
	environment.adjustment_contrast = 1.06
	return environment
