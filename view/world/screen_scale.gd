class_name ScreenScale
extends Node3D

## Keeps its children at a roughly constant size on screen.
##
## Flags and banners are labels, not scenery: a unit flag that is 40 pixels tall
## when you are inspecting a city and 4 pixels tall when you are looking at the
## continent has stopped doing its job at exactly the zoom where you most need
## to know whose army that is. Civ 6 solves this by holding flags near a fixed
## screen size and letting them detach from the world scale — so this node
## scales itself by camera distance, clamped at both ends so the flags neither
## swell to cover the map when zoomed right in nor shrink away when zoomed out.

## Camera distance at which the node renders at its authored size.
@export var reference := 15.0
@export var min_scale := 0.80
@export var max_scale := 2.10

var _camera: Camera3D = null


func _process(_delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return
	var distance := _camera.global_position.distance_to(global_position)
	var factor := clampf(distance / reference, min_scale, max_scale)
	scale = Vector3(factor, factor, factor)
