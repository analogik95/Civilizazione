class_name YieldLens
extends Node3D

## Civ 6-style yields lens: one pip per yield point, floating over each tile.
##
## The point of the lens is comparison at a glance — which of these tiles is
## worth working, which is worth settling — so it draws quantity as countable
## marks rather than numbers. Six pips of production read as "more" faster than
## the digit 6 does at map zoom.
##
## Pips sit on the perturbed ground like every other overlay; placing them at
## the ideal hex centre leaves them hovering beside the tile they describe.

const PIP_RADIUS := 0.20
const PIP_SPACING := 0.44
const ROW_SPACING := 0.40
const PER_ROW := 3
const LIFT := 0.55
## Beyond this a tile is a wall of dots rather than information.
const MAX_PIPS_PER_KIND := 5

## Deliberately the same hues the HUD uses for the same yields, so the lens and
## the top bar teach each other.
const PIP_COLOR := {
	Yields.Kind.FOOD: Color(0.42, 0.82, 0.36),
	Yields.Kind.PRODUCTION: Color(0.95, 0.62, 0.26),
	Yields.Kind.GOLD: Color(1.0, 0.85, 0.30),
	Yields.Kind.SCIENCE: Color(0.45, 0.75, 1.0),
	Yields.Kind.CULTURE: Color(0.80, 0.50, 1.0),
	Yields.Kind.FAITH: Color(0.95, 0.95, 0.98),
}

## Draw order, so a tile's pips always read food-first regardless of what it has.
const KIND_ORDER := [
	Yields.Kind.FOOD, Yields.Kind.PRODUCTION, Yields.Kind.GOLD,
	Yields.Kind.SCIENCE, Yields.Kind.CULTURE, Yields.Kind.FAITH,
]

var active: bool = false
var viewing_player_id: int = -1

var _pip_mesh: BoxMesh = null


func _ready() -> void:
	EventBus.tile_changed.connect(func(_c: Vector2i) -> void:
		if active:
			rebuild())
	EventBus.turn_started.connect(func(_t: int) -> void:
		if active:
			rebuild())


func toggle() -> bool:
	set_active(not active)
	return active


func set_active(value: bool) -> void:
	active = value
	if active:
		rebuild()
	else:
		_clear()


## A flat quad, not a sphere.
##
## The lens can put ten thousand pips on a standard map, and each one is drawn
## unshaded on top of the terrain. A sphere is sixty-odd triangles of that; a
## box is twelve, and at this size nobody can tell the difference.
func _mesh() -> BoxMesh:
	if _pip_mesh == null:
		_pip_mesh = BoxMesh.new()
		_pip_mesh.size = Vector3(PIP_RADIUS * 2.0, PIP_RADIUS * 0.4, PIP_RADIUS * 2.0)
	return _pip_mesh


func _clear() -> void:
	for child in get_children():
		child.queue_free()


func rebuild() -> void:
	_clear()
	if not active or Game.map == null:
		return

	# One multimesh per yield kind: a few draw calls for the whole map instead
	# of one node per pip, which on a standard map would be tens of thousands.
	var batches: Dictionary = {}

	for tile: Tile in Game.map.all_tiles():
		if not tile.is_land() or tile.is_impassable():
			continue
		if viewing_player_id >= 0 and not Game.map.is_explored(viewing_player_id, tile.coord):
			continue

		var yields := tile.base_yields()
		var pips: Array = []
		for kind: Yields.Kind in KIND_ORDER:
			var amount := int(round(yields.get_kind(kind)))
			for _i in mini(amount, MAX_PIPS_PER_KIND):
				pips.append(kind)
		if pips.is_empty():
			continue

		var base := TerrainMesh.perturb(Hex.to_world(tile.coord, ArtPalette.HEX_SIZE))
		base.y = TerrainMesh.surface_height(tile) + LIFT

		var rows := int(ceil(float(pips.size()) / float(PER_ROW)))
		for index in pips.size():
			var row := index / PER_ROW
			var column := index % PER_ROW
			# Centre each row on the tile so the cluster stays balanced whether
			# it holds two pips or twelve.
			var in_row := mini(PER_ROW, pips.size() - row * PER_ROW)
			var x := (float(column) - (in_row - 1) * 0.5) * PIP_SPACING
			var z := (float(row) - (rows - 1) * 0.5) * ROW_SPACING
			batches.get_or_add(pips[index], []).append(base + Vector3(x, 0.0, z))

	for kind: Yields.Kind in batches:
		_build_batch(kind, batches[kind])


func _build_batch(kind: Yields.Kind, positions: Array) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _mesh()
	multimesh.instance_count = positions.size()
	for i in positions.size():
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, positions[i]))

	var material := StandardMaterial3D.new()
	material.albedo_color = PIP_COLOR.get(kind, Color.WHITE)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Lifted clear of the ground rather than drawn with depth testing off.
	# Disabling depth test forces every pip to overdraw whatever is behind it,
	# and with thousands of them that is what turns the lens into a slideshow.
	material.render_priority = 2

	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = material
	instance.name = "Pips%d" % kind
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
