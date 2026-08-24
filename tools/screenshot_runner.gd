extends Node

## Renders a real game to a PNG so the look can be checked without a desktop.
##
##   godot --rendering-driver opengl3 --path . -- --shot out=shot.png turns=30
##
## Run it under xvfb-run on a headless box. It is a development tool, not part
## of the game: it builds a game, advances it far enough to have something worth
## looking at, points a camera at the action and writes one frame to disk.

const SETTLE_FRAMES := 8

var _focus_terrain: StringName = &""


func run(options: Dictionary) -> bool:
	var out_path: String = str(options.get("out", "shot.png"))
	var turns := int(options.get("turns", 0))
	var seed_value := int(options.get("seed", 7))
	var civs := int(options.get("civs", 4))
	var map_size := StringName(str(options.get("map_size", "tiny")))
	var zoom := float(options.get("zoom", 26.0))
	var pitch := float(options.get("pitch", 52.0))
	_focus_terrain = StringName(str(options.get("focus", "")))

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

	# `hide=Rivers,Borders` blanks named layers. Bisecting by hand is how you
	# find out which layer an unexplained mark on the map belongs to, and doing
	# it from the command line beats editing the renderer and rebuilding.
	for name: String in str(options.get("hide", "")).split(",", false):
		for child in world.get_children():
			if str(child.name).begins_with(name.strip_edges()) and child is Node3D:
				(child as Node3D).visible = false

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
	if options.has("layers"):
		for child in world.get_children():
			print("  child %s (%s)" % [child.name, child.get_class()])
	for layer: String in ["Land", "Water", "Rivers", "Borders"]:
		var node := world.get_node_or_null(NodePath(layer))
		var mesh: Mesh = (node as MeshInstance3D).mesh if node is MeshInstance3D else null
		print("  layer %-8s %s" % [
			layer,
			"absent" if mesh == null else "%d vertices" % mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),
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

	var river_tiles := 0
	var river_edges := 0
	for tile: Tile in Game.map.all_tiles():
		if tile.river_edges == 0:
			continue
		river_tiles += 1
		for d in Hex.DIRECTION_COUNT:
			if tile.has_river_on(d):
				river_edges += 1
	print("    river tiles  %5d, river edges %5d" % [river_tiles, river_edges])

	# Land must never render below the sea. This caught the elevation-scale bug
	# where the generator emitted raw noise and the renderer assumed 0..1.
	var lowest_land := INF
	var highest_water := -INF
	var land_elevation_min := INF
	var land_elevation_max := -INF
	for tile: Tile in Game.map.all_tiles():
		if tile.is_water():
			highest_water = maxf(highest_water, TerrainMesh.surface_height(tile))
		else:
			lowest_land = minf(lowest_land, TerrainMesh.surface_height(tile))
			land_elevation_min = minf(land_elevation_min, tile.elevation)
			land_elevation_max = maxf(land_elevation_max, tile.elevation)
	print("    land elevation %.3f..%.3f | lowest land y %.3f, highest water y %.3f%s" % [
		land_elevation_min, land_elevation_max, lowest_land, highest_water,
		"" if lowest_land > highest_water else "   <-- SEA ABOVE LAND",
	])


## Aim at the busiest part of the map: the largest city if any has been founded,
## otherwise wherever the most units are standing. Framing the geometric centre
## of a map is a good way to photograph open ocean.
func _focus_point() -> Vector3:
	# focus=<terrain> aims at the densest cluster of that terrain, which is how
	# you actually check whether mountains or ice render correctly.
	# focus=river aims at the densest river network on the map.
	if _focus_terrain == &"river":
		var best_river := Vector2i.ZERO
		var best_edges := 0
		for tile: Tile in Game.map.all_tiles():
			if tile.river_edges == 0:
				continue
			var edges := 0
			for other: Tile in Game.map.tiles_within(tile.coord, 3):
				for d in Hex.DIRECTION_COUNT:
					if other.has_river_on(d):
						edges += 1
			if edges > best_edges:
				best_edges = edges
				best_river = tile.coord
		if best_edges > 0:
			return Hex.to_world(best_river, ArtPalette.HEX_SIZE)

	if _focus_terrain != &"":
		var best := Vector2i.ZERO
		var best_score := -1
		for tile: Tile in Game.map.all_tiles():
			if tile.terrain_id != _focus_terrain:
				continue
			var score := 0
			for other: Tile in Game.map.tiles_within(tile.coord, 2):
				if other.terrain_id == _focus_terrain:
					score += 1
			if score > best_score:
				best_score = score
				best = tile.coord
		if best_score > 0:
			return Hex.to_world(best, ArtPalette.HEX_SIZE)

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
	ArtPalette.configure_sun(sun)
	add_child(sun)

	var world_environment := WorldEnvironment.new()
	world_environment.environment = ArtPalette.build_environment()
	add_child(world_environment)
