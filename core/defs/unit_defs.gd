## Unit and promotion definitions.

class_name UnitDefs

## Unit classes drive the rock-paper-scissors counter web: Anti-Cavalry beats
## cavalry, Melee beats Anti-Cavalry, and so on. Also decides which promotion
## tree a unit draws from and whether it exerts Zone of Control.
enum UnitClass {
	CIVILIAN,
	MELEE,
	RANGED,
	ANTI_CAVALRY,
	LIGHT_CAVALRY,
	HEAVY_CAVALRY,
	SIEGE,
	RECON,
	NAVAL_MELEE,
	NAVAL_RANGED,
	NAVAL_RAIDER,
	SUPPORT,
	RELIGIOUS,
	GREAT_PERSON,
}

const CLASS_NAMES := {
	"civilian": UnitClass.CIVILIAN,
	"melee": UnitClass.MELEE,
	"ranged": UnitClass.RANGED,
	"anti_cavalry": UnitClass.ANTI_CAVALRY,
	"light_cavalry": UnitClass.LIGHT_CAVALRY,
	"heavy_cavalry": UnitClass.HEAVY_CAVALRY,
	"siege": UnitClass.SIEGE,
	"recon": UnitClass.RECON,
	"naval_melee": UnitClass.NAVAL_MELEE,
	"naval_ranged": UnitClass.NAVAL_RANGED,
	"naval_raider": UnitClass.NAVAL_RAIDER,
	"support": UnitClass.SUPPORT,
	"religious": UnitClass.RELIGIOUS,
	"great_person": UnitClass.GREAT_PERSON,
}

## Classes that exert Zone of Control and can capture cities.
const MILITARY_CLASSES: Array[UnitClass] = [
	UnitClass.MELEE, UnitClass.RANGED, UnitClass.ANTI_CAVALRY,
	UnitClass.LIGHT_CAVALRY, UnitClass.HEAVY_CAVALRY, UnitClass.SIEGE,
	UnitClass.RECON, UnitClass.NAVAL_MELEE, UnitClass.NAVAL_RANGED,
	UnitClass.NAVAL_RAIDER,
]

## Class counter bonuses, as {attacker_class: {defender_class: strength}}.
## These are flat additions to Combat Strength before the damage curve runs, so
## a +10 counter bonus is worth roughly 1.5x damage.
const COUNTER_BONUSES := {
	UnitClass.MELEE: {UnitClass.ANTI_CAVALRY: 5.0},
	UnitClass.ANTI_CAVALRY: {
		UnitClass.LIGHT_CAVALRY: 10.0,
		UnitClass.HEAVY_CAVALRY: 10.0,
	},
}


static func parse_class(s: String) -> UnitClass:
	return CLASS_NAMES.get(s, UnitClass.CIVILIAN)


static func is_military(c: UnitClass) -> bool:
	return MILITARY_CLASSES.has(c)


static func counter_bonus(attacker: UnitClass, defender: UnitClass) -> float:
	var table: Variant = COUNTER_BONUSES.get(attacker)
	return float(table.get(defender, 0.0)) if table != null else 0.0


class UnitDef extends ContentDef:
	var unit_class: UnitClass
	var combat_strength: float
	var ranged_strength: float
	var range: int
	var movement: int
	var sight: int
	var cost: int
	var maintenance: int
	var required_tech: StringName
	var required_civic: StringName
	var required_resource: StringName
	var resource_cost: int
	var upgrades_to: StringName
	var era: int
	var charges: int
	var can_found_city: bool
	var can_build_improvements: bool
	var population_cost: int
	var ignores_zoc: bool
	var must_set_up_to_attack: bool

	func _parse(d: Dictionary) -> void:
		unit_class = UnitDefs.parse_class(str(d.get("class", "civilian")))
		combat_strength = get_float("combat_strength", 0.0)
		ranged_strength = get_float("ranged_strength", 0.0)
		range = get_int("range", 0)
		movement = get_int("movement", 2)
		sight = get_int("sight", 2)
		cost = get_int("cost", 40)
		maintenance = get_int("maintenance", 0)
		required_tech = get_name("required_tech")
		required_civic = get_name("required_civic")
		required_resource = get_name("required_resource")
		resource_cost = get_int("resource_cost", 0)
		upgrades_to = get_name("upgrades_to")
		era = get_int("era", 0)
		charges = get_int("charges", 0)
		can_found_city = get_bool("can_found_city")
		can_build_improvements = get_bool("can_build_improvements")
		population_cost = get_int("population_cost", 0)
		ignores_zoc = get_bool("ignores_zoc")
		must_set_up_to_attack = get_bool("must_set_up_to_attack")

	func is_military() -> bool:
		return UnitDefs.is_military(unit_class)

	func is_ranged() -> bool:
		return ranged_strength > 0.0 and range > 0

	func is_naval() -> bool:
		return unit_class in [
			UnitClass.NAVAL_MELEE, UnitClass.NAVAL_RANGED, UnitClass.NAVAL_RAIDER
		]


## A promotion a unit can take on levelling. Promotions form a small tree per
## unit class; `requires` names the promotion that must be taken first.
class PromotionDef extends ContentDef:
	var unit_class: UnitClass
	var requires: StringName
	var tier: int

	func _parse(d: Dictionary) -> void:
		unit_class = UnitDefs.parse_class(str(d.get("class", "melee")))
		requires = get_name("requires")
		tier = get_int("tier", 1)
