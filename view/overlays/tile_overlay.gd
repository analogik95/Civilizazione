class_name TileOverlay
extends Node3D

## Paints a translucent hex over a set of tiles — movement range, attack
## targets, district placement candidates.
##
## Kept separate from HexWorld because HexWorld draws the world and nothing
## else; selection feedback is transient view state that changes many times per
## turn and should not touch the terrain build.
##
## Overlays sit on the perturbed surface, not the ideal hex centre. The terrain
## mesh displaces every vertex horizontally, so a highlight placed at the raw
## grid position visibly floats beside the tile it is meant to mark.

const LIFT := 0.06

var _mesh: Mesh = null


func _make_mesh() -> Mesh:
	if _mesh != null:
		return _mesh
	var cylinder := CylinderMesh.new()
	cylinder.radial_segments = 6
	cylinder.top_radius = ArtPalette.HEX_SIZE * 0.86
	cylinder.bottom_radius = ArtPalette.HEX_SIZE * 0.86
	cylinder.height = 0.02
	_mesh = cylinder
	return _mesh


func show_tiles(coords: Array, colour: Color) -> void:
	clear()
	if coords.is_empty():
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Draw over the ground rather than z-fighting with it.
	material.no_depth_test = false
	material.render_priority = 1

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _make_mesh()
	multimesh.instance_count = coords.size()

	for i in coords.size():
		var coord: Vector2i = coords[i]
		var tile: Tile = Game.map.get_tile(coord)
		var position := TerrainMesh.perturb(Hex.to_world(coord, ArtPalette.HEX_SIZE))
		position.y = (TerrainMesh.surface_height(tile) if tile != null else 0.0) + LIFT
		# The hex mesh is pointy-top by default; the grid is flat-top.
		multimesh.set_instance_transform(
			i, Transform3D(Basis(Vector3.UP, deg_to_rad(30)), position)
		)

	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = material
	add_child(instance)


func clear() -> void:
	for child in get_children():
		child.queue_free()
