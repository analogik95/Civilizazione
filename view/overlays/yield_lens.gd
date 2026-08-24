class_name YieldLens
extends Node3D

## Civ 6-style yields lens: one icon per yield point, floating over each tile.
##
## The point of the lens is comparison at a glance — which of these tiles is
## worth working, which is worth settling — so it draws quantity as countable
## marks rather than numbers. Three wheat sheaves read as "more" faster than the
## digit 3 does at map zoom.
##
## They have to be *icons*, not coloured shapes. The first version drew flat
## boxes, and a box tells you nothing about which yield it stands for — you have
## to be told that orange means production, and then remember it. A hammer does
## not need explaining.
##
## Icons sit on the perturbed ground like every other overlay; placing them at
## the ideal hex centre leaves them hovering beside the tile they describe.

## Small, and clustered tight.
##
## The first plated version drew each pip at 0.46 with the cluster spread over
## most of the tile, and the map vanished under a carpet of badges — Civ 6's sit
## at roughly a quarter of a tile and take up a corner of it, so the ground
## stays visible underneath. A lens you have to turn off to see the map is not
## doing its job.
const ICON_SIZE := 0.30
## Gap between the columns, one per yield kind.
const COLUMN_SPACING := 0.30
## Gap between pips stacked within a column.
const STACK_SPACING := 0.27
const LIFT := 0.58
## Beyond this a tile is a wall of dots rather than information.
const MAX_PIPS_PER_KIND := 5

## The icon carries its own colour, so the material stays plain white and one
## shader path serves every kind.
const ICON_PATH := {
	Yields.Kind.FOOD: "res://assets/art/ui/yields/food.svg",
	Yields.Kind.PRODUCTION: "res://assets/art/ui/yields/production.svg",
	Yields.Kind.GOLD: "res://assets/art/ui/yields/gold.svg",
	Yields.Kind.SCIENCE: "res://assets/art/ui/yields/science.svg",
	Yields.Kind.CULTURE: "res://assets/art/ui/yields/culture.svg",
	Yields.Kind.FAITH: "res://assets/art/ui/yields/faith.svg",
}

## Draw order, so a tile's pips always read food-first regardless of what it has.
const KIND_ORDER := [
	Yields.Kind.FOOD, Yields.Kind.PRODUCTION, Yields.Kind.GOLD,
	Yields.Kind.SCIENCE, Yields.Kind.CULTURE, Yields.Kind.FAITH,
]

var active: bool = false
var viewing_player_id: int = -1

var _quad_mesh: QuadMesh = null
var _materials: Dictionary = {}


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


## One quad, shared by every icon. The lens can put thousands of these on a
## standard map, so the mesh is two triangles and the only per-kind cost is the
## material.
func _mesh() -> QuadMesh:
	if _quad_mesh == null:
		_quad_mesh = QuadMesh.new()
		_quad_mesh.size = Vector2(ICON_SIZE, ICON_SIZE)
	return _quad_mesh


## Billboarded so icons face the camera at every zoom and pitch. Lying flat on
## the ground they foreshorten to slivers the moment the camera tilts, which is
## half of why the boxes were unreadable.
func _material(kind: Yields.Kind) -> StandardMaterial3D:
	if _materials.has(kind):
		return _materials[kind]

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Keep the size constant in world space rather than screen space, so a tile
	# with six icons never swamps its neighbours when zoomed in.
	material.billboard_keep_scale = true
	material.render_priority = 2
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	var path: String = ICON_PATH.get(kind, "")
	if path != "" and ResourceLoader.exists(path):
		material.albedo_texture = load(path)
	else:
		push_warning("YieldLens: missing icon %s" % path)
		material.albedo_color = Color(1, 0, 1)

	_materials[kind] = material
	return material


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

		# One column per yield kind, pips stacked within it — the way Civ 6 groups
		# three food into one badge of three wheat rather than three loose marks.
		# Flattening every pip into rows of three mixed the kinds together and
		# made a tile's yields something you had to count rather than read.
		var yields := tile.base_yields()
		var columns: Array = []
		for kind: Yields.Kind in KIND_ORDER:
			var amount := mini(int(round(yields.get_kind(kind))), MAX_PIPS_PER_KIND)
			if amount > 0:
				columns.append([kind, amount])
		if columns.is_empty():
			continue

		var base := TerrainMesh.perturb(Hex.to_world(tile.coord, ArtPalette.HEX_SIZE))
		base.y = TerrainMesh.surface_height(tile) + LIFT

		for index in columns.size():
			var kind: Yields.Kind = columns[index][0]
			var amount: int = columns[index][1]
			var x := (float(index) - (columns.size() - 1) * 0.5) * COLUMN_SPACING
			for pip in amount:
				var z := (float(pip) - (amount - 1) * 0.5) * STACK_SPACING
				batches.get_or_add(kind, []).append(base + Vector3(x, 0.0, z))

	for kind: Yields.Kind in batches:
		_build_batch(kind, batches[kind])


func _build_batch(kind: Yields.Kind, positions: Array) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _mesh()
	multimesh.instance_count = positions.size()
	for i in positions.size():
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, positions[i]))

	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.material_override = _material(kind)
	instance.name = "Icons%d" % kind
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
