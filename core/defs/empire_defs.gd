## Tech, civic, government, policy card, leader and city-state definitions.

class_name EmpireDefs

enum Era { ANCIENT, CLASSICAL, MEDIEVAL, RENAISSANCE, INDUSTRIAL, MODERN, ATOMIC, INFORMATION, FUTURE }

const ERA_NAMES: Array[String] = [
	"Ancient", "Classical", "Medieval", "Renaissance", "Industrial",
	"Modern", "Atomic", "Information", "Future",
]

## A Eureka (tech) or Inspiration (civic) grants this fraction of the node's
## remaining cost the moment its trigger fires. Civ 6 settled on 40% from Rise
## and Fall onward.
const BOOST_FRACTION := 0.40


## A node in either the technology or the civic tree. The two trees are
## structurally identical — they differ only in whether Science or Culture pays
## for them and whether the boost is called a Eureka or an Inspiration — so one
## class covers both.
class TreeNodeDef extends ContentDef:
	var era: int
	var cost: int
	var prerequisites: Array[StringName]
	## What firing the boost requires, e.g.
	## {"type": "KILL_UNITS", "args": {"count": 3, "class": "barbarian"}}
	var boost: Dictionary
	var boost_text: String
	## Content unlocked on completion, purely for UI display — the actual gating
	## lives on each unlocked item's required_tech/required_civic field.
	var unlocks: Array[StringName]
	## Civics only: policy cards granted, and governor titles awarded.
	var policies_unlocked: Array[StringName]
	var governor_titles: int
	var envoys: int

	func _parse(d: Dictionary) -> void:
		era = get_int("era", 0)
		cost = get_int("cost", 25)
		prerequisites = get_names("prerequisites")
		boost = d.get("boost", {})
		boost_text = str(d.get("boost_text", ""))
		unlocks = get_names("unlocks")
		policies_unlocked = get_names("policies")
		governor_titles = get_int("governor_titles", 0)
		envoys = get_int("envoys", 0)

	func has_boost() -> bool:
		return not boost.is_empty()

	func boost_type() -> StringName:
		return StringName(str(boost.get("type", "")))

	func boost_args() -> Dictionary:
		return boost.get("args", {})


## A government. Its slot layout is the real mechanical content — how many
## Military/Economic/Diplomatic/Wildcard cards it can hold — plus a legacy bonus
## expressed as modifiers.
class GovernmentDef extends ContentDef:
	var required_civic: StringName
	var tier: int
	var military_slots: int
	var economic_slots: int
	var diplomatic_slots: int
	var wildcard_slots: int
	var influence_per_turn: float

	func _parse(d: Dictionary) -> void:
		required_civic = get_name("required_civic")
		tier = get_int("tier", 0)
		var slots: Dictionary = raw.get("slots", {})
		military_slots = int(slots.get("military", 0))
		economic_slots = int(slots.get("economic", 0))
		diplomatic_slots = int(slots.get("diplomatic", 0))
		wildcard_slots = int(slots.get("wildcard", 0))
		influence_per_turn = get_float("influence_per_turn", 0.0)

	func total_slots() -> int:
		return military_slots + economic_slots + diplomatic_slots + wildcard_slots

	func slots_of(kind: StringName) -> int:
		match kind:
			&"military": return military_slots
			&"economic": return economic_slots
			&"diplomatic": return diplomatic_slots
			&"wildcard": return wildcard_slots
		return 0


## A policy card. Slots into a government slot of matching type (or any
## Wildcard slot) and contributes its modifiers while slotted.
class PolicyDef extends ContentDef:
	enum Kind { MILITARY, ECONOMIC, DIPLOMATIC, WILDCARD, DARK }

	const KIND_NAMES := {
		"military": Kind.MILITARY,
		"economic": Kind.ECONOMIC,
		"diplomatic": Kind.DIPLOMATIC,
		"wildcard": Kind.WILDCARD,
		"dark": Kind.DARK,
	}

	var kind: Kind
	var required_civic: StringName
	## Card that renders this one obsolete once researched.
	var obsolete_civic: StringName

	func _parse(d: Dictionary) -> void:
		kind = KIND_NAMES.get(str(d.get("kind", "economic")), Kind.ECONOMIC)
		required_civic = get_name("required_civic")
		obsolete_civic = get_name("obsolete_civic")

	func kind_name() -> StringName:
		for key: Variant in KIND_NAMES:
			if KIND_NAMES[key] == kind:
				return StringName(str(key))
		return &"economic"

	## Wildcard slots take any card; typed slots only take their own kind.
	func fits_slot(slot_kind: StringName) -> bool:
		return slot_kind == &"wildcard" or slot_kind == kind_name()


## A playable civilization plus its leader. Uniques (unit, building/district,
## leader ability) are expressed as modifiers and id overrides, so adding a new
## civ is content work rather than engine work.
class LeaderDef extends ContentDef:
	var civilization: String
	var unique_units: Array[StringName]
	var unique_buildings: Array[StringName]
	var unique_districts: Array[StringName]
	var start_bias: Array[StringName]
	var agenda: StringName
	var agenda_text: String
	## AI weighting: military, expansion, science, culture, faith, gold,
	## production, wonder, naval, diplomacy — each 0..1.
	var flavors: Dictionary
	var color_primary: Color
	var color_secondary: Color

	func _parse(d: Dictionary) -> void:
		civilization = str(d.get("civilization", name))
		unique_units = get_names("unique_units")
		unique_buildings = get_names("unique_buildings")
		unique_districts = get_names("unique_districts")
		start_bias = get_names("start_bias")
		agenda = get_name("agenda")
		agenda_text = str(d.get("agenda_text", ""))
		flavors = d.get("flavors", {})
		color_primary = Color(str(d.get("color_primary", "#3d6ea5")))
		color_secondary = Color(str(d.get("color_secondary", "#f0e6d2")))

	func flavor(key: String, fallback: float = 0.5) -> float:
		return float(flavors.get(key, fallback))


## A city-state. `type` selects the envoy bonus track; `suzerain_modifiers` is
## the unique bonus its suzerain receives.
class CityStateDef extends ContentDef:
	enum Type { TRADE, CULTURAL, MILITARISTIC, RELIGIOUS, SCIENTIFIC, INDUSTRIAL }

	const TYPE_NAMES := {
		"trade": Type.TRADE,
		"cultural": Type.CULTURAL,
		"militaristic": Type.MILITARISTIC,
		"religious": Type.RELIGIOUS,
		"scientific": Type.SCIENTIFIC,
		"industrial": Type.INDUSTRIAL,
	}

	## Yield kind each city-state type feeds through its envoy track.
	const TYPE_YIELD := {
		Type.TRADE: Yields.Kind.GOLD,
		Type.CULTURAL: Yields.Kind.CULTURE,
		Type.MILITARISTIC: Yields.Kind.PRODUCTION,
		Type.RELIGIOUS: Yields.Kind.FAITH,
		Type.SCIENTIFIC: Yields.Kind.SCIENCE,
		Type.INDUSTRIAL: Yields.Kind.PRODUCTION,
	}

	var type: Type
	var suzerain_modifiers: Array[Modifier] = []
	var suzerain_text: String

	func _parse(d: Dictionary) -> void:
		type = TYPE_NAMES.get(str(d.get("type", "trade")), Type.TRADE)
		suzerain_text = str(d.get("suzerain_text", ""))
		for mod_data: Variant in d.get("suzerain_modifiers", []):
			suzerain_modifiers.append(Modifier.from_dict(mod_data))

	func envoy_yield_kind() -> Yields.Kind:
		return TYPE_YIELD.get(type, Yields.Kind.GOLD)
