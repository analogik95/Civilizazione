class_name HexWorld
extends Node3D

## Renders the map.
##
## Everything static is drawn with MultiMeshInstance3D — one per model, carrying
## every tile that uses it as an instance. A standard map is several thousand
## tiles with several props each; as individual nodes that is tens of thousands
## of draw calls and an unusable frame rate, while as multimeshes it is a few
## dozen.
##
## The renderer owns no game state. It reads MapModel and rebuilds on
## EventBus.map_generated, then patches single tiles on tile_changed. Fog is a
## per-instance colour multiply rather than a second pass, which is why the
## instance colour carries both the terrain tint and the fog dim.

const PROP_SEED := 0x5EED       # scatter must be identical between rebuilds
const FOG_UNSEEN := Color(0.16, 0.17, 0.22)
const FOG_EXPLORED := 0.45      # brightness of explored-but-not-visible tiles

var map: MapModel = null
## Whose eyes we are drawing through. -1 shows everything, which is what the
## map editor and the AI-vs-AI observer mode want.
var viewing_player_id: int = -1

var _land: MeshInstance3D = null
var _water: MeshInstance3D = null
var _prop_layers: Dictionary = {}      # model stem -> MultiMeshInstance3D
## coord -> [[layer stem, instance index], ...] so a single tile can be repainted
## without rebuilding the whole map.
var _tile_instances: Dictionary = {}
var _rivers: MeshInstance3D = null
var _borders: MeshInstance3D = null


func _ready() -> void:
	EventBus.map_generated.connect(_on_map_generated)
	EventBus.tile_changed.connect(_on_tile_changed)
	EventBus.tile_ownership_changed.connect(func(_c: Vector2i, _o: int) -> void: refresh_borders())
	EventBus.tile_visibility_changed.connect(_on_visibility_changed)


func _on_map_generated() -> void:
	build(Game.map)


func build(p_map: MapModel) -> void:
	map = p_map
	_clear()
	if map == null:
		return

	_build_ground()

	# Props are bucketed by model and drawn as one multimesh each. Building them
	# incrementally would resize every multimesh once per tile, which is O(n^2)
	# in instance copies.
	var prop_buckets: Dictionary = {}
	for tile: Tile in map.all_tiles():
		_bucket_props(tile, prop_buckets)

	for key: String in prop_buckets:
		var parts := key.split("/", true, 1)
		_build_layer(key, parts[0], prop_buckets[key], _prop_layers)

	refresh_rivers()
	refresh_borders()
	refresh_fog()
	_add_wrap_copies()


func _clear() -> void:
	for child in get_children():
		child.queue_free()
	_prop_layers.clear()
	_tile_instances.clear()
	_land = null
	_water = null
	_rivers = null
	_borders = null


# -------------------------------------------------------------------------
# Bucketing
# -------------------------------------------------------------------------

## The land and water surfaces. Two meshes for the whole map, welded so that
## neighbouring hexes share their corner vertices — see TerrainMesh for why that
## matters.
func _build_ground() -> void:
	var land := TerrainMesh.build_land(map, ArtPalette.HEX_SIZE)
	if land != null:
		_land = MeshInstance3D.new()
		_land.name = "Land"
		_land.mesh = land
		add_child(_land)

	var water := TerrainMesh.build_water(map, ArtPalette.HEX_SIZE)
	if water != null:
		_water = MeshInstance3D.new()
		_water.name = "Water"
		_water.mesh = water
		_water.material_override = _water_material()
		_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_water)


## Features, resources, improvements and districts all become props standing on
## the tile surface. Scatter is derived from the coordinate so it is stable
## across rebuilds — props that jump when a neighbouring tile changes look like
## a bug even when nothing is wrong.
func _bucket_props(tile: Tile, buckets: Dictionary) -> void:
	if not map.has_tile(tile.coord):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(tile.coord) ^ PROP_SEED
	var surface := TerrainMesh.surface_height(tile)

	# Mountains are terrain, not props — see TerrainMesh's rock section. Nothing
	# else may stand on them.
	if tile.terrain_id == &"mountains":
		return

	# A district replaces the tile's natural dressing entirely.
	if tile.has_district():
		_add_prop(buckets, "districts", ArtPalette.district_model(tile.district_id),
			tile, _prop_transform(tile, Vector3.ZERO, 0.0, surface), ArtPalette.DISTRICT_SCALE)
		return

	# Rock formations where land meets sea, as in the reference shots — a bare
	# colour change at the waterline reads as a painted edge, not a coastline.
	# Land only: is_coastal is true for the water side of the shore as well, and
	# rocks scattered across open sea look like debris.
	if tile.is_land() and map.is_coastal(tile.coord) and rng.randf() < ArtPalette.SHORE_ROCK_CHANCE:
		_add_prop(buckets, "terrain",
			ArtPalette.variant(ArtPalette.SHORE_ROCK_MODELS, tile.coord, 13), tile,
			_prop_transform(tile, _scatter(rng, 0.62), rng.randf_range(0.0, TAU), surface),
			ArtPalette.SHORE_ROCK_SCALE)

	var spec := ArtPalette.feature_props(tile) if tile.is_land() else {}
	if not spec.is_empty():
		var models: Array = spec["models"]
		for i in int(spec["count"]):
			var offset := _scatter(rng, float(spec["jitter"]))
			var stem: String = models[rng.randi_range(0, models.size() - 1)]
			var scale: float = float(spec["scale"]) * rng.randf_range(0.82, 1.18)
			_add_prop(buckets, "features", stem, tile,
				_prop_transform(tile, offset, rng.randf_range(0.0, TAU), surface), scale)

	# Marine resources — Fish, Crabs, Pearls, Whales — sit on water tiles, and the
	# resource models are all land props. Planting one on the sea puts a flower
	# bobbing in the ocean, so water resources are left to the UI to indicate.
	if tile.resource_id != &"" and tile.is_land():
		_add_prop(buckets, "resources", ArtPalette.resource_model(tile.resource_id), tile,
			_prop_transform(tile, Vector3(0.0, 0.0, 0.22), 0.0, surface),
			ArtPalette.RESOURCE_SCALE)

	if tile.improvement_id != &"" and not tile.is_pillaged and tile.is_land():
		var improvement := ArtPalette.improvement_model(tile.improvement_id)
		if improvement != "":
			_add_prop(buckets, "improvements", improvement, tile,
				_prop_transform(tile, Vector3(0.0, 0.0, -0.18), 0.0, surface),
				ArtPalette.IMPROVEMENT_SCALE)


func _scatter(rng: RandomNumberGenerator, radius: float) -> Vector3:
	var angle := rng.randf_range(0.0, TAU)
	# sqrt keeps the scatter uniform over the disc instead of clumping at the
	# centre, which is what a plain uniform radius would do.
	var distance := sqrt(rng.randf()) * radius
	return Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)


## Props stand on the *perturbed* ground. The terrain mesh displaces every
## vertex horizontally, so placing anything at the ideal hex centre leaves it
## hovering beside the tile it belongs to.
func _prop_transform(tile: Tile, offset: Vector3, yaw: float, surface: float) -> Transform3D:
	var origin := TerrainMesh.perturb(Hex.to_world(tile.coord, ArtPalette.HEX_SIZE) + offset)
	origin.y = surface
	return Transform3D(Basis(Vector3.UP, yaw), origin)


func _add_prop(
	buckets: Dictionary, group: String, stem: String, tile: Tile,
	transform: Transform3D, target_height: float
) -> void:
	if stem == "":
		return
	var key := "%s/%s" % [group, stem]
	buckets.get_or_add(key, []).append({
		"coord": tile.coord,
		"transform": transform,
		"color": Color.WHITE,
		"height": target_height,
	})


# -------------------------------------------------------------------------
# Layer construction
# -------------------------------------------------------------------------

func _build_layer(key: String, group: String, entries: Array, registry: Dictionary) -> void:
	var stem := key.get_file() if key.contains("/") else key
	var mesh := ModelLibrary.tintable_mesh(ArtPalette.model_path(group, stem))
	if mesh == null:
		return

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = entries.size()

	for i in entries.size():
		var entry: Dictionary = entries[i]
		var transform: Transform3D = entry["transform"]
		var scale := Vector3.ONE * ModelLibrary.normalised_max_scale(mesh, float(entry["height"]))
		scale.y *= float(entry.get("y_scale", 1.0))
		transform.basis = transform.basis.scaled(scale)
		multimesh.set_instance_transform(i, transform)
		multimesh.set_instance_color(i, entry["color"])
		_tile_instances.get_or_add(entry["coord"], []).append([key, i])

	var instance := MultiMeshInstance3D.new()
	instance.name = key.replace("/", "_")
	instance.multimesh = multimesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(instance)
	registry[key] = instance


func _layer(key: String) -> MultiMeshInstance3D:
	return _prop_layers.get(key)


# -------------------------------------------------------------------------
# Incremental updates
# -------------------------------------------------------------------------

## A tile whose terrain or dressing changed needs its props rebuilt, which the
## multimesh layout cannot do in place — the tile may now need a model that has
## no layer yet. Rebuilding the whole map for one chopped forest is too coarse,
## so repaint what we can and defer a structural rebuild to the next full build.
func _on_tile_changed(coord: Vector2i) -> void:
	var tile := map.get_tile(coord) if map != null else null
	if tile == null:
		return
	_repaint_tile(tile)


func _repaint_tile(tile: Tile) -> void:
	var records: Array = _tile_instances.get(tile.coord, [])
	if records.is_empty():
		return
	var shade := _fog_only(tile)
	for record: Array in records:
		var layer := _layer(record[0])
		if layer != null:
			layer.multimesh.set_instance_color(record[1], shade)


func _fog_only(tile: Tile) -> Color:
	return _apply_fog(tile, Color.WHITE)


func _apply_fog(tile: Tile, base: Color) -> Color:
	if viewing_player_id < 0 or map == null:
		return base
	if not map.is_explored(viewing_player_id, tile.coord):
		return FOG_UNSEEN
	if not map.is_visible(viewing_player_id, tile.coord):
		return base.darkened(1.0 - FOG_EXPLORED)
	return base


func _on_visibility_changed(player_id: int, coord: Vector2i) -> void:
	if player_id != viewing_player_id or map == null:
		return
	var tile := map.get_tile(coord)
	if tile != null:
		_repaint_tile(tile)


## Repaint every tile — used after a turn change, when a whole player's
## visibility set has been recomputed at once.
func refresh_fog() -> void:
	if map == null:
		return
	for tile: Tile in map.all_tiles():
		_repaint_tile(tile)


func set_viewing_player(player_id: int) -> void:
	viewing_player_id = player_id
	refresh_fog()


# -------------------------------------------------------------------------
# Rivers and borders
# -------------------------------------------------------------------------

## Rivers run along tile *edges*, not through tile centres, so they cannot come
## from the tile kit — they are built as a ribbon of quads laid on the shared
## edge between the two tiles that record the river.
func refresh_rivers() -> void:
	if _rivers != null:
		_rivers.queue_free()
	_rivers = null
	if map == null:
		return

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var drawn := 0

	for tile: Tile in map.all_tiles():
		if tile.river_edges == 0:
			continue
		for direction in Hex.DIRECTION_COUNT:
			if not tile.has_river_on(direction):
				continue
			# Both tiles record the shared edge; draw it once, from the lower
			# coordinate, or the ribbon z-fights with itself.
			var other := map.neighbor_in(tile.coord, direction)
			if other != null and _edge_owner(tile.coord, other.coord) != tile.coord:
				continue
			_add_river_edge(surface, tile, direction)
			drawn += 1

	if drawn == 0:
		return

	surface.generate_normals()
	surface.set_material(_river_material())

	_rivers = MeshInstance3D.new()
	_rivers.name = "Rivers"
	_rivers.mesh = surface.commit()
	_rivers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_rivers)


## The sea animates in the shader too, reading the shore distance baked into the
## mesh by TerrainMesh.build_water.
static var _water_shader_material: ShaderMaterial = null

static func _water_material() -> ShaderMaterial:
	if _water_shader_material != null:
		return _water_shader_material
	_water_shader_material = ShaderMaterial.new()
	_water_shader_material.shader = load("res://view/world/water.gdshader")
	_water_shader_material.set_shader_parameter("wave_noise", _wave_texture())
	return _water_shader_material


static func _wave_texture() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.03
	noise.fractal_octaves = 3
	var texture := NoiseTexture2D.new()
	texture.noise = noise
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	return texture


## Rivers animate entirely in the shader, so the mesh is built once and never
## touched again — the terrain stays static while the water moves.
static var _river_shader_material: ShaderMaterial = null

static func _river_material() -> ShaderMaterial:
	if _river_shader_material != null:
		return _river_shader_material

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.05
	noise.fractal_octaves = 3

	var texture := NoiseTexture2D.new()
	texture.noise = noise
	texture.width = 256
	texture.height = 256
	texture.seamless = true

	_river_shader_material = ShaderMaterial.new()
	_river_shader_material.shader = load("res://view/world/river.gdshader")
	_river_shader_material.set_shader_parameter("flow_noise", texture)
	return _river_shader_material


## Deterministic tiebreak so a shared edge is drawn by exactly one of its tiles.
func _edge_owner(a: Vector2i, b: Vector2i) -> Vector2i:
	if a.x != b.x:
		return a if a.x < b.x else b
	return a if a.y < b.y else b


## Half-width of the river ribbon, in world units.
const RIVER_HALF_WIDTH := 0.16
## How far the water sits below the tile surface, so it reads as a cut channel
## rather than a painted stripe. Catlike drops the stream bed well under the
## cell for the same reason.
const RIVER_DEPTH := 0.06


func _add_river_edge(surface: SurfaceTool, tile: Tile, direction: int) -> void:
	var centre := Hex.to_world(tile.coord, ArtPalette.HEX_SIZE)

	# The two corners bounding edge `direction`, from the same helper the map
	# generator marks rivers with — so the ribbon lands on the edge that was
	# actually marked.
	#
	# This used to derive the corners as 30 degrees either side of the
	# direction's own angle, which is a different pair entirely: for direction 0
	# it gave -30 and +30 degrees where the real corners are 0 and 60. Every
	# ribbon was drawn on the wrong edge, cutting diagonally across a tile
	# instead of running along its border, which is why connected rivers still
	# rendered as scattered slivers.
	var pair := Hex.edge_corners(direction)
	var a := centre + Hex.corner_offset(pair.x, ArtPalette.HEX_SIZE)
	var b := centre + Hex.corner_offset(pair.y, ArtPalette.HEX_SIZE)

	# Sit the water on the ground the edge actually has, which is the welded
	# corner height rather than either tile's centre. Using a centre height
	# leaves the ribbon buried wherever the terrain rises between tile middles —
	# a mountain's crags do exactly that, and swallowed the rivers whole.
	var fallback := TerrainMesh.surface_height(tile)
	var height_a := TerrainMesh.corner_height_at(a, fallback) - RIVER_DEPTH
	var height_b := TerrainMesh.corner_height_at(b, fallback) - RIVER_DEPTH

	var flat_a := Vector3(a.x, height_a, a.z)
	var flat_b := Vector3(b.x, height_b, b.z)
	var along := (Vector3(b.x, 0.0, b.z) - Vector3(a.x, 0.0, a.z)).normalized()
	var across := along.cross(Vector3.UP).normalized() * RIVER_HALF_WIDTH

	var p0 := TerrainMesh.perturb(flat_a - across)
	var p1 := TerrainMesh.perturb(flat_a + across)
	var p2 := TerrainMesh.perturb(flat_b + across)
	var p3 := TerrainMesh.perturb(flat_b - across)

	# UV: X runs bank to bank and drives the pale edge shading, Y runs along the
	# ribbon and is what the shader scrolls to make the water flow.
	_river_vertex(surface, p0, Vector2(0.0, 0.0))
	_river_vertex(surface, p1, Vector2(1.0, 0.0))
	_river_vertex(surface, p2, Vector2(1.0, 1.0))
	_river_vertex(surface, p0, Vector2(0.0, 0.0))
	_river_vertex(surface, p2, Vector2(1.0, 1.0))
	_river_vertex(surface, p3, Vector2(0.0, 1.0))


func _river_vertex(surface: SurfaceTool, position: Vector3, uv: Vector2) -> void:
	surface.set_uv(uv)
	surface.add_vertex(position)


## Territory borders, drawn as a coloured strip along every edge where ownership
## changes — the same read as Civ 6's dashed frontier lines.
func refresh_borders() -> void:
	if _borders != null:
		_borders.queue_free()
	_borders = null
	if map == null:
		return

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var drawn := 0

	for tile: Tile in map.all_tiles():
		if tile.owner_id < 0:
			continue
		if viewing_player_id >= 0 and not map.is_explored(viewing_player_id, tile.coord):
			continue
		var owner: PlayerState = Game.get_player(tile.owner_id)
		var colour := owner.color_primary if owner != null else Color.WHITE
		for direction in Hex.DIRECTION_COUNT:
			var other := map.neighbor_in(tile.coord, direction)
			if other != null and other.owner_id == tile.owner_id:
				continue
			_add_border_edge(surface, tile, direction, colour)
			drawn += 1

	if drawn == 0:
		return

	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface.set_material(material)

	_borders = MeshInstance3D.new()
	_borders.name = "Borders"
	_borders.mesh = surface.commit()
	add_child(_borders)


func _add_border_edge(surface: SurfaceTool, tile: Tile, direction: int, colour: Color) -> void:
	var centre := Hex.to_world(tile.coord, ArtPalette.HEX_SIZE)
	var height := TerrainMesh.surface_height(tile) + 0.04

	var angle := PI / 3.0 * direction
	var a := centre + Vector3(
		cos(angle - PI / 6.0), 0.0, sin(angle - PI / 6.0)
	) * ArtPalette.HEX_SIZE * 0.94
	var b := centre + Vector3(
		cos(angle + PI / 6.0), 0.0, sin(angle + PI / 6.0)
	) * ArtPalette.HEX_SIZE * 0.94

	var along := (b - a).normalized()
	var across := along.cross(Vector3.UP).normalized() * 0.05

	surface.set_color(colour)
	var p0 := TerrainMesh.perturb(Vector3(a.x, height, a.z) - across)
	var p1 := TerrainMesh.perturb(Vector3(a.x, height, a.z) + across)
	var p2 := TerrainMesh.perturb(Vector3(b.x, height, b.z) + across)
	var p3 := TerrainMesh.perturb(Vector3(b.x, height, b.z) - across)

	surface.add_vertex(p0); surface.add_vertex(p1); surface.add_vertex(p2)
	surface.add_vertex(p0); surface.add_vertex(p2); surface.add_vertex(p3)


# -------------------------------------------------------------------------
# Wrapping
# -------------------------------------------------------------------------

## World-space offset of one full lap around the map.
##
## A wrapped map has no east or west edge in the simulation — a unit walking off
## one side arrives at the other — but the mesh stops dead at column zero, so
## the player sees the world end. Panning across the seam looked like falling
## off the map.
##
## Rather than teleport chunks as the camera moves, the whole world is drawn
## three times: once in place and once to either side. The copies share the same
## mesh and multimesh resources, so this costs draw calls but no extra memory,
## and the seam simply never appears.
func wrap_offset() -> Vector3:
	if map == null or not map.wrap_x:
		return Vector3.ZERO
	return Hex.to_world(MapModel.offset_to_axial(map.width, 0), ArtPalette.HEX_SIZE) \
		- Hex.to_world(MapModel.offset_to_axial(0, 0), ArtPalette.HEX_SIZE)


func _add_wrap_copies() -> void:
	var offset := wrap_offset()
	if offset == Vector3.ZERO:
		return

	var originals: Array[Node] = []
	for child in get_children():
		if child is MeshInstance3D or child is MultiMeshInstance3D:
			originals.append(child)

	for original: Node in originals:
		for direction in [-1.0, 1.0]:
			var copy: Node3D = null
			if original is MultiMeshInstance3D:
				var multi := MultiMeshInstance3D.new()
				multi.multimesh = (original as MultiMeshInstance3D).multimesh
				multi.material_override = (original as MultiMeshInstance3D).material_override
				copy = multi
			else:
				var mesh_instance := MeshInstance3D.new()
				mesh_instance.mesh = (original as MeshInstance3D).mesh
				mesh_instance.material_override = (original as MeshInstance3D).material_override
				mesh_instance.cast_shadow = (original as MeshInstance3D).cast_shadow
				copy = mesh_instance
			copy.name = "%s_wrap%d" % [original.name, int(direction)]
			copy.position = offset * direction
			add_child(copy)
