class_name HexGrid
extends Node3D

## The tile outlines.
##
## Without them the map is a continuous painted surface and there is no way to
## tell where one tile ends and the next begins — which matters more here than
## in most games, because every decision in a 4X is "which tile". A thin dark
## line at every edge turns terrain into a board you can count squares on.
##
## Built once per map as a single line mesh. Each segment is lifted onto the
## welded corner height and pushed through the same horizontal perturbation the
## ground uses, so the grid sits on the terrain instead of slicing through hills.

const LIFT := 0.045
const COLOR := Color(0.10, 0.13, 0.16, 0.30)
## Coastlines get a firmer line: the land/water boundary is the one edge players
## read constantly, for settling, embarking and naval movement.
const SHORE_COLOR := Color(0.08, 0.10, 0.14, 0.55)

var visible_grid: bool = true

var _mesh_instance: MeshInstance3D = null


func _ready() -> void:
	EventBus.map_generated.connect(func() -> void: rebuild())
	EventBus.tile_changed.connect(func(_c: Vector2i) -> void: rebuild())


func toggle() -> bool:
	visible_grid = not visible_grid
	if _mesh_instance != null:
		_mesh_instance.visible = visible_grid
	return visible_grid


func rebuild() -> void:
	if _mesh_instance != null:
		_mesh_instance.queue_free()
		_mesh_instance = null
	if Game.map == null:
		return

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_LINES)

	# Each edge is shared by two tiles. Drawing it from both doubles the line
	# count and makes the overlap read as a thicker, darker seam in some places
	# and not others, so only the lower coordinate emits it.
	for tile: Tile in Game.map.all_tiles():
		for direction in Hex.DIRECTION_COUNT:
			var neighbour := Game.map.neighbor_in(tile.coord, direction)
			if neighbour != null and not _owns_edge(tile.coord, neighbour.coord):
				continue

			var shore := neighbour != null and tile.is_water() != neighbour.is_water()
			var colour := SHORE_COLOR if shore else COLOR

			var centre := Hex.to_world(tile.coord, ArtPalette.HEX_SIZE)
			var pair := Hex.edge_corners(direction)
			var fallback := TerrainMesh.surface_height(tile)
			for index in [pair.x, pair.y]:
				var corner := centre + Hex.corner_offset(index, ArtPalette.HEX_SIZE)
				var point := TerrainMesh.perturb(corner)
				point.y = TerrainMesh.corner_height_at(corner, fallback) + LIFT
				surface.set_color(colour)
				surface.add_vertex(point)

	var mesh := surface.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Grid"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.visible = visible_grid
	add_child(_mesh_instance)


## Deterministic owner for a shared edge, so it is emitted exactly once.
static func _owns_edge(a: Vector2i, b: Vector2i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	return a.y < b.y
