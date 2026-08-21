extends Node3D

## Strategic camera: pan with WASD or by dragging, zoom with the wheel.
##
## The rig is a pivot at ground level with the camera pulled back along a fixed
## pitch, so zooming moves the camera toward the pivot rather than changing the
## viewing angle. Pitch flattens slightly as you zoom out, which is what makes a
## wide view read as a map rather than a diorama.

const PAN_SPEED := 18.0
const DRAG_SENSITIVITY := 0.022
const ZOOM_STEP := 2.5
const ZOOM_MIN := 6.0
const ZOOM_MAX := 46.0
const PITCH_NEAR := 42.0
const PITCH_FAR := 62.0

@export var bounds_margin := 6.0

var _distance := 20.0
var _dragging := false
var _bounds := Rect2(Vector2.ZERO, Vector2.ZERO)

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_apply()


## Constrain panning to the generated map plus a margin, so the player cannot
## lose the world off-screen.
func set_map_bounds(map: MapModel) -> void:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for tile: Tile in map.all_tiles():
		var world := Hex.to_world(tile.coord, 1.0)
		min_x = minf(min_x, world.x)
		max_x = maxf(max_x, world.x)
		min_z = minf(min_z, world.z)
		max_z = maxf(max_z, world.z)
	_bounds = Rect2(
		Vector2(min_x - bounds_margin, min_z - bounds_margin),
		Vector2(max_x - min_x + bounds_margin * 2.0, max_z - min_z + bounds_margin * 2.0)
	)


func focus_on(coord: Vector2i) -> void:
	var target := Hex.to_world(coord, 1.0)
	var tween := create_tween()
	tween.tween_property(self, "position", Vector3(target.x, 0.0, target.z), 0.3) \
		.set_trans(Tween.TRANS_SINE)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					_distance = clampf(_distance - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
					_apply()
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					_distance = clampf(_distance + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
					_apply()
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = button.pressed

	elif event is InputEventMouseMotion and _dragging:
		var motion := (event as InputEventMouseMotion).relative
		# Scale drag with zoom so the ground keeps pace with the cursor.
		var scale := _distance * DRAG_SENSITIVITY
		_translate(Vector3(-motion.x * scale, 0.0, -motion.y * scale))


func _process(delta: float) -> void:
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		direction.z -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		direction.z += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		direction.x += 1.0

	if direction != Vector3.ZERO:
		# Pan faster when zoomed out, so crossing the map takes the same effort
		# at every zoom level.
		_translate(direction.normalized() * PAN_SPEED * delta * (_distance / 18.0))


func _translate(offset: Vector3) -> void:
	position += offset
	if _bounds.size != Vector2.ZERO:
		position.x = clampf(position.x, _bounds.position.x, _bounds.position.x + _bounds.size.x)
		position.z = clampf(position.z, _bounds.position.y, _bounds.position.y + _bounds.size.y)


func _apply() -> void:
	var t := (_distance - ZOOM_MIN) / (ZOOM_MAX - ZOOM_MIN)
	var pitch := lerpf(PITCH_NEAR, PITCH_FAR, t)
	var radians := deg_to_rad(pitch)
	_camera.position = Vector3(0.0, sin(radians) * _distance, cos(radians) * _distance)
	_camera.look_at(global_position, Vector3.UP)


## Which tile is under a screen position, or a sentinel if the ray misses the
## ground plane.
func tile_under(screen_position: Vector2) -> Vector2i:
	var origin := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.0001:
		return Vector2i(-9999, -9999)
	var distance := -origin.y / direction.y
	if distance < 0.0:
		return Vector2i(-9999, -9999)
	return Hex.from_world(origin + direction * distance, 1.0)
