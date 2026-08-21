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
const BANNER_HEIGHT := 0.95

var _views: Dictionary = {}   # city_id -> Node3D


func _ready() -> void:
	EventBus.city_founded.connect(_on_city_founded)
	EventBus.city_population_changed.connect(_on_population_changed)
	EventBus.city_captured.connect(_on_city_captured)
	EventBus.district_built.connect(func(city_id: int, _c: Vector2i, _d: StringName) -> void:
		_rebuild_city(city_id))


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
	var position := Hex.to_world(city.coord, ArtPalette.HEX_SIZE)
	position.y = ArtPalette.surface_height(tile)
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


## A real flag on a pole in the owner's colour. An earlier version billboarded a
## flat quad, which read as a coloured rectangle floating over the rooftops
## rather than as part of the city.
func _add_banner(root: Node3D, colour: Color) -> void:
	var mesh := ModelLibrary.tintable_mesh(
		ArtPalette.model_path("city", ArtPalette.CITY_BANNER)
	)
	if mesh == null:
		return
	var instance := MeshInstance3D.new()
	instance.name = "Banner"
	instance.mesh = mesh
	instance.position = Vector3(0.0, BANNER_HEIGHT * 0.42, 0.0)
	instance.scale = Vector3.ONE * ModelLibrary.normalised_max_scale(mesh, 0.55)
	_tint(instance, colour)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(instance)


func _tint(instance: MeshInstance3D, colour: Color) -> void:
	var material := StandardMaterial3D.new()
	var source := instance.mesh.surface_get_material(0)
	if source is StandardMaterial3D:
		material = (source as StandardMaterial3D).duplicate()
	material.albedo_color = colour
	instance.material_override = material


func view_for(city_id: int) -> Node3D:
	return _views.get(city_id)
