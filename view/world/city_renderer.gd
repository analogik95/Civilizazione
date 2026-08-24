class_name CityRenderer
extends Node3D

## Draws city centres.
##
## A city is not one model — it is a cluster that visibly grows. Population
## decides how many houses stand in the ring, walls appear once the city has
## them, and a banner in the owner's colour marks it from across the map. That
## growth is the main thing that makes an empire readable at a glance, so it is
## worth more than a single detailed building would be.

const RING_RADIUS := 0.30
const MAX_BUILDINGS := 7
## Well clear of the unit flags below it — a garrison must not hide the banner
## of the city it is defending.
const BANNER_HEIGHT := 2.45

var _views: Dictionary = {}   # city_id -> Node3D


func _ready() -> void:
	EventBus.city_founded.connect(_on_city_founded)
	EventBus.city_population_changed.connect(_on_population_changed)
	EventBus.city_captured.connect(_on_city_captured)
	EventBus.district_built.connect(func(city_id: int, _c: Vector2i, _d: StringName) -> void:
		_rebuild_city(city_id))
	# What a city is building changes every time it finishes something and every
	# turn the estimate moves, but neither changes the buildings on the ground —
	# so retext the label instead of rebuilding the whole cluster.
	EventBus.city_production_completed.connect(
		func(city_id: int, _k: StringName, _i: StringName) -> void:
			_refresh_production(city_id))
	EventBus.turn_started.connect(func(_turn: int) -> void: _refresh_all_production())


func rebuild() -> void:
	for view: Node3D in _views.values():
		view.queue_free()
	_views.clear()
	for city: CityState in Game.cities.values():
		_create_view(city)


func _on_city_founded(city_id: int) -> void:
	var city: CityState = Game.get_city(city_id)
	if city != null:
		_create_view(city)


func _on_population_changed(city_id: int, _population: int) -> void:
	_rebuild_city(city_id)


func _on_city_captured(city_id: int, _old: int, _new: int) -> void:
	_rebuild_city(city_id)


func _rebuild_city(city_id: int) -> void:
	var view: Node3D = _views.get(city_id)
	if view != null:
		view.queue_free()
		_views.erase(city_id)
	var city: CityState = Game.get_city(city_id)
	if city != null:
		_create_view(city)


func _refresh_all_production() -> void:
	for city_id: int in _views:
		_refresh_production(city_id)


func _refresh_production(city_id: int) -> void:
	var view: Node3D = _views.get(city_id)
	var city: CityState = Game.get_city(city_id)
	if view == null or city == null:
		return
	var label: Label3D = view.get_node_or_null("Banner/Producing")
	if label != null:
		label.text = _production_text(city)


# -------------------------------------------------------------------------
# Construction
# -------------------------------------------------------------------------

func _create_view(city: CityState) -> void:
	var tile: Tile = Game.map.get_tile(city.coord) if Game.map != null else null
	if tile == null:
		return

	var owner: PlayerState = Game.get_player(city.owner_id)
	var colour := owner.color_primary if owner != null else Color.WHITE

	var root := Node3D.new()
	root.name = "City%d" % city.id
	var position := TerrainMesh.perturb(Hex.to_world(city.coord, ArtPalette.HEX_SIZE))
	position.y = TerrainMesh.surface_height(tile)
	root.position = position

	_add_keep(root, colour)
	_add_houses(root, city)
	if city.has_walls():
		_add_walls(root)
	_add_banner(root, colour)

	add_child(root)
	_views[city.id] = root


## The central keep, tinted with the owner's colour so ownership reads even
## when the banner is hidden behind terrain.
func _add_keep(root: Node3D, colour: Color) -> void:
	var mesh := ModelLibrary.tintable_mesh(ArtPalette.model_path("city", ArtPalette.CITY_KEEP))
	if mesh == null:
		return
	var instance := MeshInstance3D.new()
	instance.name = "Keep"
	instance.mesh = mesh
	instance.scale = Vector3.ONE * ModelLibrary.normalised_scale(mesh, 0.46)
	_tint(instance, colour.lerp(Color.WHITE, 0.35))
	root.add_child(instance)


## Houses ring the keep, one per two citizens, so a size-12 city is visibly a
## different place from a size-2 one.
func _add_houses(root: Node3D, city: CityState) -> void:
	var count := clampi(int(city.population / 2.0) + 1, 1, MAX_BUILDINGS)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(city.coord)

	for i in count:
		var stem: String = ArtPalette.CITY_BUILDINGS[i % ArtPalette.CITY_BUILDINGS.size()]
		var mesh := ModelLibrary.tintable_mesh(ArtPalette.model_path("city", stem))
		if mesh == null:
			continue
		var angle := TAU * float(i) / float(count) + rng.randf_range(-0.2, 0.2)
		var radius := RING_RADIUS + rng.randf_range(-0.05, 0.10)

		var instance := MeshInstance3D.new()
		instance.name = "House%d" % i
		instance.mesh = mesh
		instance.position = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		instance.rotation.y = -angle + PI * 0.5
		instance.scale = Vector3.ONE * ModelLibrary.normalised_scale(
			mesh, ArtPalette.CITY_BUILDING_SCALE * rng.randf_range(0.9, 1.15)
		)
		root.add_child(instance)


## Walls sit outside the houses, one segment per hex edge.
func _add_walls(root: Node3D) -> void:
	var mesh := ModelLibrary.tintable_mesh(ArtPalette.model_path("city", ArtPalette.CITY_WALL_TOWER))
	if mesh == null:
		return
	for direction in Hex.DIRECTION_COUNT:
		var angle := PI / 3.0 * direction
		var instance := MeshInstance3D.new()
		instance.name = "Wall%d" % direction
		instance.mesh = mesh
		instance.position = Vector3(cos(angle), 0.0, sin(angle)) * 0.58
		instance.rotation.y = -angle
		instance.scale = Vector3.ONE * ModelLibrary.normalised_scale(mesh, 0.34)
		root.add_child(instance)


## The banner above a city.
##
## A city is the thing a player looks for first when scanning the map, so it
## carries its whole identity overhead: name, population, and what it is
## building. The 3D keep below is scenery; this is the part that is actually
## read. Everything is billboarded, so it stays legible from any angle.
func _add_banner(root: Node3D, colour: Color) -> void:
	var city_id := int(str(root.name).trim_prefix("City"))
	var city: CityState = Game.get_city(city_id)
	if city == null:
		return

	var banner := ScreenScale.new()
	banner.name = "Banner"
	banner.position = Vector3(0.0, BANNER_HEIGHT, 0.0)
	root.add_child(banner)

	# Dark plate behind everything, so white text stays readable over a pale
	# banner colour or bright terrain.
	var plate := _banner_quad(Color(0.06, 0.08, 0.12, 0.90), Vector2(2.02, 0.62))
	plate.name = "Plate"
	banner.add_child(plate)

	# Owner-coloured strip down the left, the way Civ 6 marks whose city it is.
	var stripe := _banner_quad(colour, Vector2(0.52, 0.62))
	stripe.name = "Stripe"
	stripe.position = Vector3(-0.75, 0.0, 0.002)
	banner.add_child(stripe)

	var population := _label(str(city.population), 56, Color.WHITE)
	population.name = "Population"
	population.position = Vector3(-0.75, 0.0, 0.006)
	banner.add_child(population)

	var name_label := _label(city.name, 44, Color.WHITE)
	name_label.name = "CityName"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_label.position = Vector3(-0.44, 0.13, 0.006)
	banner.add_child(name_label)

	var producing := _label(_production_text(city), 34, Color(0.74, 0.82, 0.96))
	producing.name = "Producing"
	producing.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	producing.position = Vector3(-0.44, -0.16, 0.006)
	banner.add_child(producing)


## Banner text.
##
## The outline is what makes this legible, and it is also what broke the first
## version: an outline sized for a 48-pixel glyph is a black halo wide enough to
## swallow the glyph once the banner is drawn a dozen pixels tall. Scaling it
## with the font keeps the reading edge without eating the letters.
func _label(text: String, size: int, colour: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.pixel_size = 0.0046
	label.outline_size = maxi(2, size / 12)
	label.outline_modulate = Color(0.02, 0.03, 0.05, 0.95)
	label.modulate = colour
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 4
	label.outline_render_priority = 3
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return label


func _production_text(city: CityState) -> String:
	if city.production_item == &"":
		return "choosing..."
	var def: ContentDef = null
	match city.production_kind:
		CityState.ProductionKind.UNIT: def = ContentDB.get_unit(city.production_item)
		CityState.ProductionKind.BUILDING: def = ContentDB.get_building(city.production_item)
		CityState.ProductionKind.DISTRICT: def = ContentDB.get_district(city.production_item)
		CityState.ProductionKind.WONDER: def = ContentDB.wonders.get(city.production_item)
	var label := def.name if def != null else str(city.production_item)
	var turns := city.turns_until_production()
	return "%s  %s" % [label, "%d turns" % turns if turns > 0 else "-"]


func _banner_quad(colour: Color, size: Vector2) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 2

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _tint(instance: MeshInstance3D, colour: Color) -> void:
	var material := StandardMaterial3D.new()
	var source := instance.mesh.surface_get_material(0)
	if source is StandardMaterial3D:
		material = (source as StandardMaterial3D).duplicate()
	material.albedo_color = colour
	instance.material_override = material


func view_for(city_id: int) -> Node3D:
	return _views.get(city_id)
