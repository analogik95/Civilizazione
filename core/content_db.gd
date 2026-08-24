extends Node

## Loads every JSON content file under data/ into typed defs and indexes them
## by id.
##
## Content is loaded once at boot and treated as immutable afterwards. If a file
## is malformed or references an id that does not exist, we fail loudly here
## rather than letting a typo surface hours later as a city that silently
## under-yields.

var terrain: Dictionary = {}          # StringName -> MapDefs.TerrainDef
var features: Dictionary = {}         # StringName -> MapDefs.FeatureDef
var resources: Dictionary = {}        # StringName -> MapDefs.ResourceDef
var improvements: Dictionary = {}     # StringName -> MapDefs.ImprovementDef
var natural_wonders: Dictionary = {}  # StringName -> MapDefs.NaturalWonderDef
var districts: Dictionary = {}        # StringName -> CityDefs.DistrictDef
var buildings: Dictionary = {}        # StringName -> CityDefs.BuildingDef
var wonders: Dictionary = {}          # StringName -> CityDefs.WonderDef
var units: Dictionary = {}            # StringName -> UnitDefs.UnitDef
var promotions: Dictionary = {}       # StringName -> UnitDefs.PromotionDef
var techs: Dictionary = {}            # StringName -> EmpireDefs.TreeNodeDef
var civics: Dictionary = {}           # StringName -> EmpireDefs.TreeNodeDef
var governments: Dictionary = {}      # StringName -> EmpireDefs.GovernmentDef
var policies: Dictionary = {}         # StringName -> EmpireDefs.PolicyDef
var leaders: Dictionary = {}          # StringName -> EmpireDefs.LeaderDef
var city_states: Dictionary = {}      # StringName -> EmpireDefs.CityStateDef

var _loaded := false
var load_errors: PackedStringArray = []

const DATA_ROOT := "res://data"

## file stem -> [target dictionary property, def class]
const MANIFEST := [
	["terrain", "terrain"],
	["features", "features"],
	["resources", "resources"],
	["improvements", "improvements"],
	["natural_wonders", "natural_wonders"],
	["districts", "districts"],
	["buildings", "buildings"],
	["wonders", "wonders"],
	["units", "units"],
	["promotions", "promotions"],
	["techs", "techs"],
	["civics", "civics"],
	["governments", "governments"],
	["policies", "policies"],
	["leaders", "leaders"],
	["city_states", "city_states"],
]


func _ready() -> void:
	load_all()


func load_all() -> bool:
	if _loaded:
		return load_errors.is_empty()
	load_errors.clear()

	_load_into("terrain", terrain, MapDefs.TerrainDef)
	_load_into("features", features, MapDefs.FeatureDef)
	_load_into("resources", resources, MapDefs.ResourceDef)
	_load_into("improvements", improvements, MapDefs.ImprovementDef)
	_load_into("natural_wonders", natural_wonders, MapDefs.NaturalWonderDef)
	_load_into("districts", districts, CityDefs.DistrictDef)
	_load_into("buildings", buildings, CityDefs.BuildingDef)
	_load_into("wonders", wonders, CityDefs.WonderDef)
	_load_into("units", units, UnitDefs.UnitDef)
	_load_into("promotions", promotions, UnitDefs.PromotionDef)
	_load_into("techs", techs, EmpireDefs.TreeNodeDef)
	_load_into("civics", civics, EmpireDefs.TreeNodeDef)
	_load_into("governments", governments, EmpireDefs.GovernmentDef)
	_load_into("policies", policies, EmpireDefs.PolicyDef)
	_load_into("leaders", leaders, EmpireDefs.LeaderDef)
	_load_into("city_states", city_states, EmpireDefs.CityStateDef)

	_validate()
	_loaded = true

	if not load_errors.is_empty():
		for err in load_errors:
			push_error("[ContentDB] %s" % err)
	return load_errors.is_empty()


func _load_into(stem: String, target: Dictionary, def_class: Variant) -> void:
	var path := "%s/%s.json" % [DATA_ROOT, stem]
	if not FileAccess.file_exists(path):
		load_errors.append("missing content file: %s" % path)
		return

	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		load_errors.append("could not parse %s as JSON" % path)
		return
	if not (parsed is Array):
		load_errors.append("%s must contain a top-level array" % path)
		return

	for record: Variant in parsed:
		if not (record is Dictionary):
			load_errors.append("%s: entry is not an object" % stem)
			continue
		var def: ContentDef = def_class.new(record)
		if def.id == &"":
			load_errors.append("%s: entry missing 'id'" % stem)
			continue
		if target.has(def.id):
			load_errors.append("%s: duplicate id '%s'" % [stem, def.id])
			continue
		target[def.id] = def


## Cross-reference check: every id a def points at must actually exist. This is
## what turns a silent content typo into a startup failure.
func _validate() -> void:
	_check_refs(features, "valid_terrain", terrain, "terrain")
	_check_refs(resources, "valid_terrain", terrain, "terrain")
	_check_refs(improvements, "valid_terrain", terrain, "terrain")
	_check_refs(buildings, "district", districts, "district")
	_check_refs(districts, "buildings", buildings, "building")

	for tree_name in ["techs", "civics"]:
		var tree: Dictionary = techs if tree_name == "techs" else civics
		for node: EmpireDefs.TreeNodeDef in tree.values():
			for prereq in node.prerequisites:
				if not tree.has(prereq):
					load_errors.append("%s '%s': unknown prerequisite '%s'" % [tree_name, node.id, prereq])

	for u: UnitDefs.UnitDef in units.values():
		if u.required_tech != &"" and not techs.has(u.required_tech):
			load_errors.append("unit '%s': unknown required_tech '%s'" % [u.id, u.required_tech])
		if u.upgrades_to != &"" and not units.has(u.upgrades_to):
			load_errors.append("unit '%s': unknown upgrades_to '%s'" % [u.id, u.upgrades_to])

	for p: EmpireDefs.PolicyDef in policies.values():
		if p.required_civic != &"" and not civics.has(p.required_civic):
			load_errors.append("policy '%s': unknown required_civic '%s'" % [p.id, p.required_civic])

	for g: EmpireDefs.GovernmentDef in governments.values():
		if g.required_civic != &"" and not civics.has(g.required_civic):
			load_errors.append("government '%s': unknown required_civic '%s'" % [g.id, g.required_civic])


func _check_refs(source: Dictionary, field: String, target: Dictionary, label: String) -> void:
	for def: ContentDef in source.values():
		for ref in def.get_names(field):
			if ref != &"" and not target.has(ref):
				load_errors.append("%s '%s': unknown %s '%s'" % [
					def.get_script().get_global_name(), def.id, label, ref
				])


# -------------------------------------------------------------------------
# Lookup helpers
# -------------------------------------------------------------------------

func get_terrain(id: StringName) -> MapDefs.TerrainDef:
	return terrain.get(id)

func get_feature(id: StringName) -> MapDefs.FeatureDef:
	return features.get(id)

func get_resource(id: StringName) -> MapDefs.ResourceDef:
	return resources.get(id)

func get_improvement(id: StringName) -> MapDefs.ImprovementDef:
	return improvements.get(id)

func get_district(id: StringName) -> CityDefs.DistrictDef:
	return districts.get(id)

func get_building(id: StringName) -> CityDefs.BuildingDef:
	return buildings.get(id)

func get_unit(id: StringName) -> UnitDefs.UnitDef:
	return units.get(id)

func get_tech(id: StringName) -> EmpireDefs.TreeNodeDef:
	return techs.get(id)

func get_civic(id: StringName) -> EmpireDefs.TreeNodeDef:
	return civics.get(id)

func get_government(id: StringName) -> EmpireDefs.GovernmentDef:
	return governments.get(id)

func get_policy(id: StringName) -> EmpireDefs.PolicyDef:
	return policies.get(id)

func get_leader(id: StringName) -> EmpireDefs.LeaderDef:
	return leaders.get(id)

func get_city_state(id: StringName) -> EmpireDefs.CityStateDef:
	return city_states.get(id)


## All resources of a category, for map generation.
func resources_of(category: MapDefs.ResourceDef.Category) -> Array:
	var out: Array = []
	for r: MapDefs.ResourceDef in resources.values():
		if r.category == category:
			out.append(r)
	return out


func units_available(tech_ids: Dictionary, civic_ids: Dictionary) -> Array:
	var out: Array = []
	for u: UnitDefs.UnitDef in units.values():
		if u.required_tech != &"" and not tech_ids.has(u.required_tech):
			continue
		if u.required_civic != &"" and not civic_ids.has(u.required_civic):
			continue
		out.append(u)
	return out
