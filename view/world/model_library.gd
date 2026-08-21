class_name ModelLibrary
extends RefCounted

## Loads .glb art once and hands out the pieces the renderers need.
##
## Every model is loaded, stripped to its Mesh, and cached. Two details matter:
##
##  - The kits are authored at wildly different scales — a Kenney hex tile is
##    about one unit across while a Blocky Character is eight — so nothing is
##    used at its native size. `normalised_scale()` measures the mesh and
##    returns the factor that brings it to a requested world height, which
##    keeps the palette talking in world units instead of per-model magic
##    numbers.
##  - Terrain is tinted per tile, and the cheap way to do that is one MultiMesh
##    per model carrying a per-instance colour. That needs the material to read
##    vertex colours as albedo, which the imported material does not do by
##    default, so materials are duplicated and patched on the way out.

static var _mesh_cache: Dictionary = {}
static var _tinted_cache: Dictionary = {}


## The first Mesh found in a .glb, or null if the file is missing or empty.
static func load_mesh(path: String) -> Mesh:
	if _mesh_cache.has(path):
		return _mesh_cache[path]

	var mesh: Mesh = null
	if ResourceLoader.exists(path):
		var packed: PackedScene = load(path)
		if packed != null:
			var root: Node = packed.instantiate()
			mesh = _first_mesh(root)
			root.queue_free()

	if mesh == null:
		push_warning("ModelLibrary: no mesh in %s" % path)
	_mesh_cache[path] = mesh
	return mesh


static func _first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and node.mesh != null:
		# Bake the instance's own material down onto the mesh when the importer
		# put it there as an override, so callers only have to look in one place.
		var instance := node as MeshInstance3D
		var mesh := instance.mesh
		for surface in mesh.get_surface_count():
			var override := instance.get_surface_override_material(surface)
			if override != null and mesh.surface_get_material(surface) == null:
				mesh.surface_set_material(surface, override)
		return mesh
	for child in node.get_children():
		var found := _first_mesh(child)
		if found != null:
			return found
	return null


## A copy of `mesh` whose materials read per-instance vertex colour as albedo,
## so one MultiMesh can render the same model in many tints.
static func tintable_mesh(path: String) -> Mesh:
	if _tinted_cache.has(path):
		return _tinted_cache[path]

	var source := load_mesh(path)
	if source == null:
		_tinted_cache[path] = null
		return null

	# ArrayMesh is the only Mesh subclass whose surfaces can be rebuilt, and the
	# importer always produces one, so copy surface by surface rather than
	# mutating the shared cached mesh.
	var out := ArrayMesh.new()
	for surface in source.get_surface_count():
		out.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(surface)
		)
		var material := source.surface_get_material(surface)
		var tinted: StandardMaterial3D
		if material is StandardMaterial3D:
			tinted = (material as StandardMaterial3D).duplicate()
		else:
			tinted = StandardMaterial3D.new()
		tinted.vertex_color_use_as_albedo = true
		out.surface_set_material(surface, tinted)

	_tinted_cache[path] = out
	return out


## Scale factor bringing a mesh to `target_height` world units tall.
static func normalised_scale(mesh: Mesh, target_height: float) -> float:
	if mesh == null:
		return 1.0
	var height := mesh.get_aabb().size.y
	return target_height / height if height > 0.0001 else 1.0


## Scale factor bringing a mesh's *largest* dimension to `target`.
##
## The right measure for scattered props, because they are not all tall: a tree
## is height-dominant, but a crop row or a flat rock is a wide, low slab.
## Normalising those by height alone stretches them into spikes several tiles
## across, since a small height divides into a large scale factor.
static func normalised_max_scale(mesh: Mesh, target: float) -> float:
	if mesh == null:
		return 1.0
	var size := mesh.get_aabb().size
	var largest := maxf(size.x, maxf(size.y, size.z))
	return target / largest if largest > 0.0001 else 1.0


## Scale factor bringing a mesh to `target_width` across its widest horizontal
## axis — the right measure for tiles, which must tessellate exactly.
static func normalised_width_scale(mesh: Mesh, target_width: float) -> float:
	if mesh == null:
		return 1.0
	var size := mesh.get_aabb().size
	var width := maxf(size.x, size.z)
	return target_width / width if width > 0.0001 else 1.0


static func clear_cache() -> void:
	_mesh_cache.clear()
	_tinted_cache.clear()
