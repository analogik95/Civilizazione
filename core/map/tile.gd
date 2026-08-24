class_name Tile
extends RefCounted

## One hex on the map.
##
## A tile is a stack: base terrain, an optional hills variant, an optional
## feature, an optional resource, an optional improvement or district, plus
## river and cliff edges that run *between* tiles rather than on them. Yields
## come from summing that stack — see base_yields().

var coord: Vector2i

# --- Terrain stack ---
var terrain_id: StringName = &"ocean"
var is_hills: bool = false
var feature_id: StringName = &""
var resource_id: StringName = &""
## Strategic resources carry a quantity; bonus and luxury resources are 1.
var resource_amount: int = 1
var natural_wonder_id: StringName = &""

# --- Player-made ---
var improvement_id: StringName = &""
var is_pillaged: bool = false
## Set when a district (including the City Center) occupies this tile.
var district_id: StringName = &""
var district_city_id: int = -1
var wonder_id: StringName = &""

# --- Edges, as bitmasks over Hex.DIRECTIONS ---
## A river along edge i is shared with the neighbour in direction i, so both
## tiles record it. Rivers grant fresh water and Commercial Hub adjacency.
var river_edges: int = 0
## Cliffs block movement across the edge and prevent amphibious landings.
var cliff_edges: int = 0

# --- Ownership / assignment ---
var owner_id: int = -1
var owning_city_id: int = -1
## Set when a citizen of the owning city is currently working this tile.
var worked_by_city_id: int = -1

# --- Generation + presentation ---
var elevation: float = 0.0
var continent_id: int = -1
var appeal: int = 0

# --- Barbarians ---
var barbarian_outpost: bool = false


func _init(p_coord: Vector2i = Vector2i.ZERO) -> void:
	coord = p_coord


func terrain() -> MapDefs.TerrainDef:
	return ContentDB.get_terrain(terrain_id)


func feature() -> MapDefs.FeatureDef:
	return ContentDB.get_feature(feature_id) if feature_id != &"" else null


func resource() -> MapDefs.ResourceDef:
	return ContentDB.get_resource(resource_id) if resource_id != &"" else null


func improvement() -> MapDefs.ImprovementDef:
	return ContentDB.get_improvement(improvement_id) if improvement_id != &"" else null


func is_water() -> bool:
	var t := terrain()
	return t != null and t.is_water


func is_land() -> bool:
	return not is_water()


func is_impassable() -> bool:
	var t := terrain()
	if t != null and t.is_impassable:
		return true
	var f := feature()
	if f != null and f.is_impassable:
		return true
	var nw := natural_wonder()
	return nw != null and nw.is_impassable


func natural_wonder() -> MapDefs.NaturalWonderDef:
	return ContentDB.natural_wonders.get(natural_wonder_id) if natural_wonder_id != &"" else null


func has_river() -> bool:
	return river_edges != 0


func has_river_on(direction: int) -> bool:
	return (river_edges & (1 << direction)) != 0


func set_river_on(direction: int, present: bool = true) -> void:
	if present:
		river_edges |= 1 << direction
	else:
		river_edges &= ~(1 << direction)


func has_cliff_on(direction: int) -> bool:
	return (cliff_edges & (1 << direction)) != 0


func has_district() -> bool:
	return district_id != &""


func is_city_center() -> bool:
	return district_id == &"city_center"


## Occupied by anything that stops another district or improvement going here.
func is_buildable() -> bool:
	return is_land() and not is_impassable() and not has_district() and wonder_id == &""


## The tile's own output, before city-level modifiers.
##
## Order matters and mirrors Civ 6: terrain base, +1 Production if hills, then
## the feature delta, then the resource, then the improvement. A natural wonder
## replaces the terrain yield outright.
func base_yields() -> Yields:
	var nw := natural_wonder()
	if nw != null:
		return nw.tile_yields()

	var out := Yields.new()
	var t := terrain()
	if t != null:
		out.accumulate(t.base_yields())
	if is_hills:
		out.add_kind(Yields.Kind.PRODUCTION, 1.0)

	var f := feature()
	if f != null:
		out.accumulate(f.yield_delta())

	var r := resource()
	if r != null:
		out.accumulate(r.tile_yields())

	if improvement_id != &"" and not is_pillaged:
		var imp := improvement()
		if imp != null:
			out.accumulate(imp.yield_delta())

	# A river running past the tile is worth a little Gold in its own right,
	# on top of the fresh water and Commercial Hub adjacency it enables.
	if has_river():
		out.add_kind(Yields.Kind.GOLD, 1.0)

	return out


## Movement points to enter this tile, ignoring roads. Hills and forest cost 2,
## which is what makes rough terrain worth routing around.
func movement_cost() -> int:
	if is_impassable():
		return 999
	var cost := 1
	var t := terrain()
	if t != null:
		cost = maxi(cost, t.movement_cost)
	if is_hills:
		cost = maxi(cost, 2)
	var f := feature()
	if f != null:
		cost = maxi(cost, f.movement_cost)
	return cost


## Percentage defence bonus for a unit standing here.
func defense_modifier() -> int:
	var total := 0
	var t := terrain()
	if t != null:
		total += t.defense_modifier
	if is_hills:
		total += 3
	var f := feature()
	if f != null:
		total += f.defense_modifier
	return total


## Static contribution this tile makes to its own Appeal, before neighbour
## effects. MapModel.recompute_appeal() adds the neighbour terms.
func self_appeal() -> int:
	var total := 0
	if terrain_id == &"mountains":
		total += 4
	if has_river():
		total += 1
	var f := feature()
	if f != null:
		total += f.appeal
	if improvement_id != &"" and not is_pillaged:
		var imp := improvement()
		if imp != null:
			total += imp.appeal
	if is_pillaged:
		total -= 1
	if has_district():
		var d := ContentDB.get_district(district_id)
		if d != null:
			total += d.appeal
	return total


func can_have_improvement(imp: MapDefs.ImprovementDef) -> bool:
	if imp == null or not is_buildable():
		return false
	if imp.requires_resource and resource_id == &"":
		return false
	if not imp.valid_resources.is_empty() and not imp.valid_resources.has(resource_id):
		return false
	if not imp.valid_terrain.is_empty() and not imp.valid_terrain.has(terrain_id):
		return false
	var f := feature()
	if f != null and f.blocks_improvement and not imp.valid_features.has(feature_id):
		return false
	return true


func to_dict() -> Dictionary:
	return {
		"coord": [coord.x, coord.y],
		"terrain": str(terrain_id), "hills": is_hills,
		"feature": str(feature_id), "resource": str(resource_id), "amount": resource_amount,
		"wonder": str(natural_wonder_id),
		"improvement": str(improvement_id), "pillaged": is_pillaged,
		"district": str(district_id), "district_city": district_city_id,
		"rivers": river_edges, "cliffs": cliff_edges,
		"owner": owner_id, "owning_city": owning_city_id, "worked_by": worked_by_city_id,
		"elevation": elevation, "continent": continent_id, "appeal": appeal,
		"outpost": barbarian_outpost,
	}


static func from_dict(d: Dictionary) -> Tile:
	var raw_coord: Array = d.get("coord", [0, 0])
	var t := Tile.new(Vector2i(int(raw_coord[0]), int(raw_coord[1])))
	t.terrain_id = StringName(str(d.get("terrain", "ocean")))
	t.is_hills = bool(d.get("hills", false))
	t.feature_id = StringName(str(d.get("feature", "")))
	t.resource_id = StringName(str(d.get("resource", "")))
	t.resource_amount = int(d.get("amount", 1))
	t.natural_wonder_id = StringName(str(d.get("wonder", "")))
	t.improvement_id = StringName(str(d.get("improvement", "")))
	t.is_pillaged = bool(d.get("pillaged", false))
	t.district_id = StringName(str(d.get("district", "")))
	t.district_city_id = int(d.get("district_city", -1))
	t.river_edges = int(d.get("rivers", 0))
	t.cliff_edges = int(d.get("cliffs", 0))
	t.owner_id = int(d.get("owner", -1))
	t.owning_city_id = int(d.get("owning_city", -1))
	t.worked_by_city_id = int(d.get("worked_by", -1))
	t.elevation = float(d.get("elevation", 0.0))
	t.continent_id = int(d.get("continent", -1))
	t.appeal = int(d.get("appeal", 0))
	t.barbarian_outpost = bool(d.get("outpost", false))
	return t
