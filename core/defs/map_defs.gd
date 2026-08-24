## Terrain, feature, resource and improvement definitions.
##
## Grouped in one file because they are all small and always used together by
## the map generator and the tile yield pipeline.

class_name MapDefs


## A base terrain: Grassland, Plains, Desert, Tundra, Snow, Coast, Ocean.
## Hills are a *variant* of a land terrain rather than a terrain of their own
## (matching Civ 6), so a tile carries terrain_id + is_hills and picks up the
## hills yield bonus and defence modifier on top of the base.
class TerrainDef extends ContentDef:
	var is_water: bool
	var is_impassable: bool
	var movement_cost: int
	var defense_modifier: int
	var appeal: int

	func _parse(d: Dictionary) -> void:
		is_water = get_bool("is_water")
		is_impassable = get_bool("is_impassable")
		movement_cost = get_int("movement_cost", 1)
		defense_modifier = get_int("defense_modifier", 0)
		appeal = get_int("appeal", 0)

	func base_yields() -> Yields:
		return get_yields()

	## Which terrains this may sit on when generating hills.
	func allows_hills() -> bool:
		return not is_water and not is_impassable


## A terrain feature: Woods, Rainforest, Marsh, Floodplains, Oasis, Reef, Ice.
## Features sit on top of a base terrain, adjust its yields, and can usually be
## removed by a Builder for a one-off yield.
class FeatureDef extends ContentDef:
	var valid_terrain: Array[StringName]
	var movement_cost: int
	var defense_modifier: int
	var appeal: int
	var removable: bool
	var is_impassable: bool
	var requires_river: bool
	var requires_coast: bool
	var blocks_improvement: bool

	func _parse(d: Dictionary) -> void:
		valid_terrain = get_names("valid_terrain")
		movement_cost = get_int("movement_cost", 1)
		defense_modifier = get_int("defense_modifier", 0)
		appeal = get_int("appeal", 0)
		removable = get_bool("removable", true)
		is_impassable = get_bool("is_impassable")
		requires_river = get_bool("requires_river")
		requires_coast = get_bool("requires_coast")
		blocks_improvement = get_bool("blocks_improvement")

	func yield_delta() -> Yields:
		return get_yields()


## A map resource. `category` is bonus | luxury | strategic, which decides what
## it does: bonus gives local yields only, luxury supplies Amenities to the
## player's neediest cities, strategic accumulates in a per-player stockpile and
## gates unit production.
class ResourceDef extends ContentDef:
	enum Category { BONUS, LUXURY, STRATEGIC }

	var category: Category
	var valid_terrain: Array[StringName]
	var valid_features: Array[StringName]
	var improvement_id: StringName
	var reveal_tech: StringName
	var frequency: float
	var harvest_yield: Yields

	func _parse(d: Dictionary) -> void:
		match str(d.get("category", "bonus")):
			"luxury": category = Category.LUXURY
			"strategic": category = Category.STRATEGIC
			_: category = Category.BONUS
		valid_terrain = get_names("valid_terrain")
		valid_features = get_names("valid_features")
		improvement_id = get_name("improvement")
		reveal_tech = get_name("reveal_tech")
		frequency = get_float("frequency", 1.0)
		harvest_yield = get_yields("harvest_yield")

	func tile_yields() -> Yields:
		return get_yields()

	func is_luxury() -> bool:
		return category == Category.LUXURY

	func is_strategic() -> bool:
		return category == Category.STRATEGIC


## A tile improvement built by a Builder: Farm, Mine, Pasture, Plantation,
## Quarry, Camp, Fishing Boats.
class ImprovementDef extends ContentDef:
	var required_tech: StringName
	var valid_terrain: Array[StringName]
	var valid_features: Array[StringName]
	var valid_resources: Array[StringName]
	var requires_resource: bool
	var appeal: int
	var removes_feature: bool

	func _parse(d: Dictionary) -> void:
		required_tech = get_name("required_tech")
		valid_terrain = get_names("valid_terrain")
		valid_features = get_names("valid_features")
		valid_resources = get_names("valid_resources")
		requires_resource = get_bool("requires_resource")
		appeal = get_int("appeal", 0)
		removes_feature = get_bool("removes_feature", true)

	func yield_delta() -> Yields:
		return get_yields()


## A named map feature occupying one or more tiles with fixed high yields, such
## as a mountain range or reef system. Grants Appeal to everything around it and
## major adjacency to a Holy Site.
class NaturalWonderDef extends ContentDef:
	var tile_count: int
	var is_impassable: bool
	var requires_water: bool
	var requires_land: bool

	func _parse(d: Dictionary) -> void:
		tile_count = get_int("tile_count", 1)
		is_impassable = get_bool("is_impassable", true)
		requires_water = get_bool("requires_water")
		requires_land = get_bool("requires_land", true)

	func tile_yields() -> Yields:
		return get_yields()
