class_name UnitRenderer
extends Node3D

## Draws units, one node each.
##
## Unlike terrain there are only ever tens to low hundreds of these, so they are
## real nodes rather than multimesh instances — they need to move smoothly,
## carry a health bar, and be pickable, none of which a multimesh gives you.
##
## Owner colour is applied as an albedo tint on a duplicated material. The kit
## models are all one shared atlas, so tinting the whole model is what makes two
## civilizations' warriors tell apart at a glance.

const MOVE_TIME := 0.28
const HEALTH_BAR_WIDTH := 0.56
const FLAG_SIZE := 0.46
## How high the flag floats over the unit. Kept well under the city banner's
## height so a garrison never covers the banner of the city it is sitting in.
const FLAG_HEIGHT := 0.50
const FLAG_SELECTED_LIFT := 0.20
## Flags of units sharing a tile fan out sideways. The camera never yaws, so
## world +X is always screen-right and a plain X offset is a screen offset.
const FLAG_FAN := 0.40
## Which icon a unit shows. Grouped by class, which is how the units group
## mechanically too — a Warrior and a Swordsman fight the same way and should
## read the same way on the map.
const CLASS_ICON := {
	UnitDefs.UnitClass.MELEE: "melee",
	UnitDefs.UnitClass.RANGED: "ranged",
	UnitDefs.UnitClass.ANTI_CAVALRY: "anti_cavalry",
	UnitDefs.UnitClass.LIGHT_CAVALRY: "cavalry",
	UnitDefs.UnitClass.HEAVY_CAVALRY: "cavalry",
	UnitDefs.UnitClass.SIEGE: "siege",
	UnitDefs.UnitClass.RECON: "recon",
	UnitDefs.UnitClass.NAVAL_MELEE: "naval",
	UnitDefs.UnitClass.NAVAL_RANGED: "naval",
	UnitDefs.UnitClass.NAVAL_RAIDER: "naval",
}
## Civilians are told apart by what they do, not by a shared "civilian" glyph.
const UNIT_ICON := {
	&"settler": "settler",
	&"builder": "builder",
	&"trader": "trader",
}
const STACK_OFFSET := Vector3(0.0, 0.0, 0.26)

var _views: Dictionary = {}   # unit_id -> Node3D
var viewing_player_id: int = -1


func _ready() -> void:
	EventBus.unit_created.connect(_on_unit_created)
	EventBus.unit_moved.connect(_on_unit_moved)
	EventBus.unit_killed.connect(_on_unit_killed)
	EventBus.combat_resolved.connect(_on_combat_resolved)


## Rebuild from scratch — used on load and after a full turn resolution, where
## following every individual signal would be slower than starting over.
func rebuild() -> void:
	for view: Node3D in _views.values():
		view.queue_free()
	_views.clear()
	for unit: UnitState in Game.units.values():
		_create_view(unit)
	refresh_flag_layout()


func _on_unit_created(unit_id: int) -> void:
	var unit: UnitState = Game.get_unit(unit_id)
	if unit != null:
		_create_view(unit)
		_relayout_tile(unit.coord)


func _on_unit_killed(unit_id: int, _killer_id: int) -> void:
	var view: Node3D = _views.get(unit_id)
	if view == null:
		return
	var unit: UnitState = Game.get_unit(unit_id)
	var coord := unit.coord if unit != null else Vector2i.MAX
	_views.erase(unit_id)
	# Sink and fade rather than vanish, so a kill reads as an event.
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(view, "position:y", view.position.y - 0.4, 0.32)
	tween.tween_property(view, "scale", Vector3.ONE * 0.1, 0.32)
	tween.chain().tween_callback(view.queue_free)
	if coord != Vector2i.MAX:
		_relayout_tile(coord)


func _on_unit_moved(unit_id: int, from: Vector2i, to: Vector2i) -> void:
	var view: Node3D = _views.get(unit_id)
	var unit: UnitState = Game.get_unit(unit_id)
	if view == null or unit == null:
		return
	var target := _position_for(unit, to)
	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(view, "position", target, MOVE_TIME)
	view.look_at_from_position(view.position, target, Vector3.UP, true)
	# Only the two tiles involved can have changed how many flags they carry.
	# Re-fanning every unit here made turn resolution quadratic once already.
	_relayout_tile(from)
	_relayout_tile(to)


func _on_combat_resolved(attacker_id: int, defender_id: int, _a: int, _d: int) -> void:
	for id in [attacker_id, defender_id]:
		_refresh_health(id)


func _refresh_health(unit_id: int) -> void:
	var view: Node3D = _views.get(unit_id)
	var unit: UnitState = Game.get_unit(unit_id)
	if view == null or unit == null:
		return
	var bar: Node3D = view.get_node_or_null("Flag/Health")
	if bar != null:
		_update_health_bar(bar, unit)


# -------------------------------------------------------------------------
# Construction
# -------------------------------------------------------------------------

func _create_view(unit: UnitState) -> void:
	var stem := ArtPalette.unit_model(unit.unit_id)
	var mesh := ModelLibrary.tintable_mesh(ArtPalette.model_path("units", stem))
	if mesh == null:
		return

	var root := Node3D.new()
	root.name = "Unit%d" % unit.id
	root.position = _position_for(unit, unit.coord)

	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
	var factor := ModelLibrary.normalised_max_scale(mesh, ArtPalette.UNIT_SCALE)
	body.scale = Vector3.ONE * factor
	body.set_instance_shader_parameter("albedo", _colour_for(unit))
	_tint(body, _colour_for(unit))
	root.add_child(body)

	root.add_child(_build_flag(unit))

	add_child(root)
	_views[unit.id] = root


## Civilian units keep their natural colours so they read as non-combat; a
## military unit takes its owner's primary colour.
func _colour_for(unit: UnitState) -> Color:
	var owner: PlayerState = Game.get_player(unit.owner_id)
	if owner == null:
		return Color.WHITE
	if not unit.is_military():
		return owner.color_primary.lerp(Color.WHITE, 0.55)
	return owner.color_primary.lerp(Color.WHITE, 0.15)


func _tint(instance: MeshInstance3D, colour: Color) -> void:
	var material := StandardMaterial3D.new()
	var source := instance.mesh.surface_get_material(0)
	if source is StandardMaterial3D:
		material = (source as StandardMaterial3D).duplicate()
	material.albedo_color = colour
	instance.material_override = material


func _build_health_bar(unit: UnitState) -> Node3D:
	var bar := Node3D.new()
	bar.name = "Health"
	# Directly under the flag face, the way Civ 6 hangs the bar off the flag
	# rather than floating it over the model.
	bar.position = Vector3(0.0, -FLAG_SIZE * 0.68, 0.006)

	var background := _quad(Color(0.08, 0.08, 0.10, 0.85), HEALTH_BAR_WIDTH)
	background.name = "Back"
	bar.add_child(background)

	var fill := _quad(Color(0.30, 0.85, 0.35), HEALTH_BAR_WIDTH)
	fill.name = "Fill"
	fill.position.z = 0.001
	bar.add_child(fill)

	_update_health_bar(bar, unit)
	return bar


## A flat quad that always faces the camera, so the bar stays readable at any
## rotation without needing a Sprite3D and a texture per colour.
func _quad(colour: Color, width: float) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(width, 0.09)

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 2

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _update_health_bar(bar: Node3D, unit: UnitState) -> void:
	var fill: MeshInstance3D = bar.get_node_or_null("Fill")
	if fill == null:
		return
	var fraction := clampf(float(unit.hp) / float(UnitState.MAX_HP), 0.0, 1.0)
	fill.scale.x = maxf(fraction, 0.001)
	# Shift left as it shrinks so the bar drains from one end rather than
	# collapsing toward its centre.
	fill.position.x = -HEALTH_BAR_WIDTH * (1.0 - fraction) * 0.5

	var material := fill.material_override as StandardMaterial3D
	if material != null:
		material.albedo_color = (
			Color(0.30, 0.85, 0.35) if fraction > 0.6
			else Color(0.95, 0.78, 0.20) if fraction > 0.3
			else Color(0.90, 0.25, 0.20)
		)
	bar.visible = fraction < 1.0


## Military and civilian units share a tile, so they are nudged apart.
func _position_for(unit: UnitState, coord: Vector2i) -> Vector3:
	var tile: Tile = Game.map.get_tile(coord) if Game.map != null else null
	var position := TerrainMesh.perturb(Hex.to_world(coord, ArtPalette.HEX_SIZE))
	position.y = TerrainMesh.surface_height(tile) if tile != null else 0.0
	if not unit.is_military():
		position += STACK_OFFSET
	else:
		position -= STACK_OFFSET
	return position


func view_for(unit_id: int) -> Node3D:
	return _views.get(unit_id)


# -------------------------------------------------------------------------
# Flags
# -------------------------------------------------------------------------

## The flag above a unit.
##
## A bare model on a hex tells you almost nothing: at map zoom every unit is a
## few pixels of silhouette, and two civilizations' armies are indistinguishable
## because the colour is on a shape too small to see. Civ 6 solves this by
## putting the identity above the unit instead of on it — an owner-coloured
## flag carrying a class icon, readable at any zoom because it is billboarded
## and never foreshortens.
func _build_flag(unit: UnitState) -> Node3D:
	var flag := ScreenScale.new()
	flag.name = "Flag"
	flag.position = Vector3(_fan_offset(unit), ArtPalette.UNIT_SCALE + FLAG_HEIGHT, 0.0)

	var owner: PlayerState = Game.get_player(unit.owner_id)
	var colour := owner.color_primary if owner != null else Color.WHITE

	# A darker plate a shade larger than the flag gives it an outline, which is
	# what keeps a dark-blue flag visible against deep ocean.
	var rim := _flag_quad(Color(0.05, 0.06, 0.09), FLAG_SIZE * 1.16)
	rim.name = "Rim"
	flag.add_child(rim)

	var face := _flag_quad(colour, FLAG_SIZE)
	face.name = "Face"
	face.position.z = 0.002
	flag.add_child(face)

	var icon := _icon_quad(unit, FLAG_SIZE * 0.80)
	if icon != null:
		icon.name = "Icon"
		icon.position.z = 0.004
		flag.add_child(icon)

	flag.add_child(_build_health_bar(unit))

	var badge := _order_badge(unit)
	if badge != null:
		flag.add_child(badge)

	return flag


## Units sharing a tile fan their flags apart. Without this a settler escorted
## by a warrior shows one flag with another exactly behind it, and the escort is
## invisible — the case that matters most, because it is the one you must not
## leave undefended.
func _fan_offset(unit: UnitState) -> float:
	var here: Array = Game.units_at(unit.coord)
	if here.size() < 2:
		return 0.0
	var ids: Array[int] = []
	for other: UnitState in here:
		ids.append(other.id)
	ids.sort()
	var index := ids.find(unit.id)
	if index < 0:
		return 0.0
	return (float(index) - float(ids.size() - 1) * 0.5) * FLAG_FAN


## A corner pip for a standing order, so you can see at a glance which units are
## dug in and which are merely idle.
func _order_badge(unit: UnitState) -> MeshInstance3D:
	var colour := Color.TRANSPARENT
	if unit.is_fortified:
		colour = Color(0.42, 0.72, 0.98)
	elif unit.is_sleeping:
		colour = Color(0.62, 0.62, 0.68)
	if colour.a == 0.0:
		return null
	var badge := _flag_quad(colour, FLAG_SIZE * 0.30)
	badge.name = "Order"
	badge.position = Vector3(FLAG_SIZE * 0.50, FLAG_SIZE * 0.50, 0.006)
	var material := badge.material_override as StandardMaterial3D
	if material != null:
		material.render_priority = 5
	return badge


func _rim_mesh(size: float) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	return mesh


func _flag_quad(colour: Color, size: float) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.render_priority = 3

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _icon_quad(unit: UnitState, size: float) -> MeshInstance3D:
	var stem: String = UNIT_ICON.get(unit.unit_id, CLASS_ICON.get(unit.unit_class(), ""))
	if stem == "":
		return null
	var path := "res://assets/art/ui/units/%s.svg" % stem
	if not ResourceLoader.exists(path):
		return null

	var instance := _flag_quad(Color.WHITE, size)
	var material := instance.material_override as StandardMaterial3D
	material.albedo_texture = load(path)
	material.render_priority = 4
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return instance


## Lift the selected unit's flag and brighten it, rather than ringing the model.
## A ring on the ground is invisible the moment the unit stands in forest.
func set_selected(unit_id: int) -> void:
	for id: int in _views:
		var view: Node3D = _views[id]
		var flag: Node3D = view.get_node_or_null("Flag")
		if flag == null:
			continue
		var chosen := id == unit_id
		flag.position.y = ArtPalette.UNIT_SCALE + FLAG_HEIGHT + (FLAG_SELECTED_LIFT if chosen else 0.0)
		var face: MeshInstance3D = flag.get_node_or_null("Face")
		if face == null:
			continue
		var unit: UnitState = Game.get_unit(id)
		var owner: PlayerState = Game.get_player(unit.owner_id) if unit != null else null
		var base := owner.color_primary if owner != null else Color.WHITE
		var material := face.material_override as StandardMaterial3D
		if material != null:
			# Deliberately unchanged. Lightening the face toward white was the
			# first attempt and it erased the white class icon printed on it —
			# the selected unit became the one you could no longer identify.
			material.albedo_color = base
		var rim: MeshInstance3D = flag.get_node_or_null("Rim")
		if rim == null:
			continue
		rim.mesh = _rim_mesh(FLAG_SIZE * (1.34 if chosen else 1.16))
		var rim_material := rim.material_override as StandardMaterial3D
		if rim_material != null:
			rim_material.albedo_color = (
				Color(1.0, 0.96, 0.72) if chosen else Color(0.05, 0.06, 0.09)
			)


## Flags fan out by how many units stand on a tile, so an arrival or a departure
## re-lays out the flags of everyone still standing there.
func _relayout_tile(coord: Vector2i) -> void:
	for unit: UnitState in Game.units_at(coord):
		_place_flag(unit)


func _place_flag(unit: UnitState) -> void:
	var view: Node3D = _views.get(unit.id)
	if view == null:
		return
	var flag: Node3D = view.get_node_or_null("Flag")
	if flag != null:
		flag.position.x = _fan_offset(unit)


## Re-fan every flag on the map. Only worth it after a wholesale rebuild; a
## single move touches two tiles and should go through _relayout_tile.
func refresh_flag_layout() -> void:
	for id: int in _views:
		var unit: UnitState = Game.get_unit(id)
		if unit != null:
			_place_flag(unit)
