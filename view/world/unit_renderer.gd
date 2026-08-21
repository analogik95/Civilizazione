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
const HEALTH_BAR_WIDTH := 0.62
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


func _on_unit_created(unit_id: int) -> void:
	var unit: UnitState = Game.get_unit(unit_id)
	if unit != null:
		_create_view(unit)


func _on_unit_killed(unit_id: int, _killer_id: int) -> void:
	var view: Node3D = _views.get(unit_id)
	if view == null:
		return
	_views.erase(unit_id)
	# Sink and fade rather than vanish, so a kill reads as an event.
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(view, "position:y", view.position.y - 0.4, 0.32)
	tween.tween_property(view, "scale", Vector3.ONE * 0.1, 0.32)
	tween.chain().tween_callback(view.queue_free)


func _on_unit_moved(unit_id: int, _from: Vector2i, to: Vector2i) -> void:
	var view: Node3D = _views.get(unit_id)
	var unit: UnitState = Game.get_unit(unit_id)
	if view == null or unit == null:
		return
	var target := _position_for(unit, to)
	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(view, "position", target, MOVE_TIME)
	view.look_at_from_position(view.position, target, Vector3.UP, true)


func _on_combat_resolved(attacker_id: int, defender_id: int, _a: int, _d: int) -> void:
	for id in [attacker_id, defender_id]:
		_refresh_health(id)


func _refresh_health(unit_id: int) -> void:
	var view: Node3D = _views.get(unit_id)
	var unit: UnitState = Game.get_unit(unit_id)
	if view == null or unit == null:
		return
	var bar: Node3D = view.get_node_or_null("Health")
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

	var health := _build_health_bar(unit)
	root.add_child(health)

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
	bar.position = Vector3(0.0, ArtPalette.UNIT_SCALE + 0.22, 0.0)

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
	var position := Hex.to_world(coord, ArtPalette.HEX_SIZE)
	position.y = TerrainMesh.surface_height(tile) if tile != null else 0.0
	if not unit.is_military():
		position += STACK_OFFSET
	else:
		position -= STACK_OFFSET
	return position


func view_for(unit_id: int) -> Node3D:
	return _views.get(unit_id)
