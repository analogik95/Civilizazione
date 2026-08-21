## District, building and wonder definitions.

class_name CityDefs


## A district occupies a whole tile inside the city's work radius and hosts a
## tiered chain of buildings. Its adjacency bonus is recomputed from the six
## surrounding tiles whenever anything nearby changes — this is Civ 6's
## signature placement puzzle and the reason district siting matters more than
## build order.
class DistrictDef extends ContentDef:
	## Adjacency sources, each: {"kind": ..., "match": [...], "amount": 0.5|1|2,
	## "per": 1}. `kind` is one of terrain, feature, resource, district, river,
	## natural_wonder, improvement. `per` groups sources that only pay out in
	## pairs (Campus gets +1 per *two* adjacent Rainforest tiles).
	var adjacency_rules: Array = []

	var required_tech: StringName
	var required_civic: StringName
	var cost: int
	## Extra citizens needed per district beyond the first. Civ 6 gates district
	## count by population in steps of roughly 3.
	var population_cost: int
	var one_per_civ: bool
	var requires_coast: bool
	var requires_river: bool
	var requires_adjacent_city_center: bool
	var is_specialty: bool
	## Great Person points this district generates per turn, keyed by category.
	var great_person_points: Dictionary
	var buildings: Array[StringName]
	var defense: int
	var appeal: int

	func _parse(d: Dictionary) -> void:
		adjacency_rules = d.get("adjacency", [])
		required_tech = get_name("required_tech")
		required_civic = get_name("required_civic")
		cost = get_int("cost", 54)
		population_cost = get_int("population_cost", 3)
		one_per_civ = get_bool("one_per_civ")
		requires_coast = get_bool("requires_coast")
		requires_river = get_bool("requires_river")
		requires_adjacent_city_center = get_bool("requires_adjacent_city_center")
		is_specialty = get_bool("is_specialty", true)
		great_person_points = d.get("great_person_points", {})
		buildings = get_names("buildings")
		defense = get_int("defense", 0)
		appeal = get_int("appeal", 0)

	## Yield produced by the district itself, before adjacency. Most specialty
	## districts produce nothing on their own; a Holy Site is the notable
	## exception at +2 Faith.
	func base_yields() -> Yields:
		return get_yields()

	## Which yield kind this district's adjacency feeds.
	func adjacency_yield() -> Yields.Kind:
		var key := StringName(str(raw.get("adjacency_yield", "science")))
		var idx := Yields.KIND_NAMES.find(key)
		return (idx if idx != -1 else Yields.Kind.SCIENCE) as Yields.Kind


## A building constructed inside a district (or the City Center). Buildings are
## tiered: a Library requires a Campus, a University requires the Library.
class BuildingDef extends ContentDef:
	var district_id: StringName
	var required_tech: StringName
	var required_civic: StringName
	var required_building: StringName
	var cost: int
	var maintenance: int
	var housing: float
	var amenities: float
	var citizen_slots: int
	var defense: int
	var great_person_points: Dictionary

	func _parse(d: Dictionary) -> void:
		district_id = get_name("district")
		required_tech = get_name("required_tech")
		required_civic = get_name("required_civic")
		required_building = get_name("required_building")
		cost = get_int("cost", 60)
		maintenance = get_int("maintenance", 1)
		housing = get_float("housing", 0.0)
		amenities = get_float("amenities", 0.0)
		citizen_slots = get_int("citizen_slots", 0)
		defense = get_int("defense", 0)
		great_person_points = d.get("great_person_points", {})

	func base_yields() -> Yields:
		return get_yields()


## A wonder: one per game across all players, built on a tile like a district
## but with placement requirements of its own.
class WonderDef extends ContentDef:
	var required_tech: StringName
	var required_civic: StringName
	var cost: int
	var requires_adjacent_district: StringName
	var valid_terrain: Array[StringName]
	var valid_features: Array[StringName]
	var requires_river: bool
	var requires_coast: bool
	var era: int

	func _parse(d: Dictionary) -> void:
		required_tech = get_name("required_tech")
		required_civic = get_name("required_civic")
		cost = get_int("cost", 180)
		requires_adjacent_district = get_name("requires_adjacent_district")
		valid_terrain = get_names("valid_terrain")
		valid_features = get_names("valid_features")
		requires_river = get_bool("requires_river")
		requires_coast = get_bool("requires_coast")
		era = get_int("era", 0)

	func base_yields() -> Yields:
		return get_yields()
