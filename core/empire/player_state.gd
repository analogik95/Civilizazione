class_name PlayerState
extends RefCounted

## Everything one participant owns that is not a city, unit or tile.
##
## Covers major civilizations, city-states and the barbarian pseudo-player;
## `kind` decides which rules apply. Keeping city-states in the same type means
## envoys, war and territory work uniformly instead of needing a parallel
## implementation.

enum Kind { MAJOR, CITY_STATE, BARBARIAN, FREE_CITY }

var id: int = -1
var kind: Kind = Kind.MAJOR
var leader_id: StringName = &""
var city_state_id: StringName = &""
var is_human: bool = false
var is_alive: bool = true

var color_primary: Color = Color.WHITE
var color_secondary: Color = Color.BLACK

# --- Treasury ---
var gold: float = 0.0
var faith: float = 0.0

## Yields banked this turn, recomputed from all cities each turn.
var yields_per_turn: Yields = Yields.new()

# --- Research ---
var techs: Dictionary = {}            # tech_id -> true
var civics: Dictionary = {}           # civic_id -> true
var current_tech: StringName = &""
var current_civic: StringName = &""
var tech_progress: float = 0.0
var civic_progress: float = 0.0
## Boosts already fired, so a Eureka never pays out twice.
var boosted_techs: Dictionary = {}
var boosted_civics: Dictionary = {}
## Running counters for boost triggers that need a tally ("kill 3 barbarians").
var boost_counters: Dictionary = {}

var era: int = EmpireDefs.Era.ANCIENT
var era_score: int = 0

# --- Government ---
var government_id: StringName = &"chiefdom"
## slot index -> policy id. Slot layout comes from the government def.
var slotted_policies: Dictionary = {}
var unlocked_policies: Dictionary = {}
var governor_titles: int = 0

# --- Diplomacy ---
var met_players: Dictionary = {}      # player_id -> true
var at_war_with: Dictionary = {}      # player_id -> true
var grievances: Dictionary = {}       # player_id -> float
var influence: float = 0.0            # accumulates into envoys
var envoys_available: int = 0
var envoys_sent: Dictionary = {}      # city_state player_id -> count
var suzerain_of: Dictionary = {}      # city_state player_id -> true

# --- Religion ---
var pantheon_id: StringName = &""
var religion_id: StringName = &""

# --- Strategic resources ---
var resource_stock: Dictionary = {}   # resource_id -> float

# --- Great People ---
var great_person_points: Dictionary = {}  # category -> float

# --- Territory bookkeeping ---
var capital_city_id: int = -1
## Original capitals this player currently holds, including their own. The
## Domination victory reads this.
var original_capitals_held: Dictionary = {}

# --- AI ---
var flavors: Dictionary = {}
var difficulty_bonus: float = 0.0


func _init(p_id: int = -1, p_kind: Kind = Kind.MAJOR) -> void:
	id = p_id
	kind = p_kind


func leader() -> EmpireDefs.LeaderDef:
	return ContentDB.get_leader(leader_id) if leader_id != &"" else null


func government() -> EmpireDefs.GovernmentDef:
	return ContentDB.get_government(government_id)


func is_major() -> bool:
	return kind == Kind.MAJOR


func has_tech(tech_id: StringName) -> bool:
	return techs.has(tech_id)


func has_civic(civic_id: StringName) -> bool:
	return civics.has(civic_id)


func is_at_war_with(other_id: int) -> bool:
	return at_war_with.has(other_id)


func is_at_war_with_anyone() -> bool:
	return not at_war_with.is_empty()


func has_met(other_id: int) -> bool:
	return met_players.has(other_id)


func flavor(key: String, fallback: float = 0.5) -> float:
	if flavors.has(key):
		return float(flavors[key])
	var l := leader()
	return l.flavor(key, fallback) if l != null else fallback


# -------------------------------------------------------------------------
# Research
# -------------------------------------------------------------------------

## Cost of a tree node for this player. Civ 6 shifts costs by up to 20% based on
## how far ahead of or behind the world era you are researching, which keeps a
## runaway leader from compounding and lets a straggler catch up.
func node_cost(node: EmpireDefs.TreeNodeDef, world_era: int) -> float:
	var base := float(node.cost)
	var era_delta := node.era - world_era
	var scale := clampf(1.0 + era_delta * 0.10, 0.8, 1.2)
	return base * scale


func is_boosted(kind_name: StringName, node_id: StringName) -> bool:
	return (boosted_techs if kind_name == &"tech" else boosted_civics).has(node_id)


## Record that a boost fired. Returns false if it had already fired, so callers
## can skip the notification.
func mark_boosted(kind_name: StringName, node_id: StringName) -> bool:
	var target := boosted_techs if kind_name == &"tech" else boosted_civics
	if target.has(node_id):
		return false
	target[node_id] = true
	return true


func bump_boost_counter(key: StringName, amount: int = 1) -> int:
	var value := int(boost_counters.get(key, 0)) + amount
	boost_counters[key] = value
	return value


# -------------------------------------------------------------------------
# Policies
# -------------------------------------------------------------------------

## Ordered slot descriptors for the current government, e.g.
## [&"military", &"military", &"economic", &"wildcard"].
func policy_slots() -> Array[StringName]:
	var out: Array[StringName] = []
	var g := government()
	if g == null:
		return out
	for _i in g.military_slots:
		out.append(&"military")
	for _i in g.economic_slots:
		out.append(&"economic")
	for _i in g.diplomatic_slots:
		out.append(&"diplomatic")
	for _i in g.wildcard_slots:
		out.append(&"wildcard")
	return out


func slotted_policy_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for value: Variant in slotted_policies.values():
		var name := StringName(str(value))
		if name != &"":
			out.append(name)
	return out


func can_slot(policy_id: StringName, slot_index: int) -> bool:
	var slots := policy_slots()
	if slot_index < 0 or slot_index >= slots.size():
		return false
	if not unlocked_policies.has(policy_id):
		return false
	if slotted_policy_ids().has(policy_id):
		return false
	var p := ContentDB.get_policy(policy_id)
	return p != null and p.fits_slot(slots[slot_index])


# -------------------------------------------------------------------------
# Resources
# -------------------------------------------------------------------------

func stock_of(resource_id: StringName) -> float:
	return float(resource_stock.get(resource_id, 0.0))


func add_stock(resource_id: StringName, amount: float) -> void:
	resource_stock[resource_id] = stock_of(resource_id) + amount


func can_afford_resource(resource_id: StringName, amount: int) -> bool:
	return resource_id == &"" or stock_of(resource_id) >= amount


func add_great_person_points(category: StringName, amount: float) -> void:
	great_person_points[category] = float(great_person_points.get(category, 0.0)) + amount


func to_dict() -> Dictionary:
	return {
		"id": id, "kind": kind, "leader": str(leader_id), "city_state": str(city_state_id),
		"human": is_human, "alive": is_alive,
		"gold": gold, "faith": faith,
		"techs": techs.keys().map(func(k: Variant) -> String: return str(k)),
		"civics": civics.keys().map(func(k: Variant) -> String: return str(k)),
		"current_tech": str(current_tech), "current_civic": str(current_civic),
		"tech_progress": tech_progress, "civic_progress": civic_progress,
		"boosted_techs": boosted_techs.keys().map(func(k: Variant) -> String: return str(k)),
		"boosted_civics": boosted_civics.keys().map(func(k: Variant) -> String: return str(k)),
		"boost_counters": boost_counters,
		"era": era, "era_score": era_score,
		"government": str(government_id), "slotted_policies": slotted_policies,
		"unlocked_policies": unlocked_policies.keys().map(func(k: Variant) -> String: return str(k)),
		"governor_titles": governor_titles,
		"met": met_players.keys(), "at_war": at_war_with.keys(), "grievances": grievances,
		"influence": influence, "envoys_available": envoys_available,
		"envoys_sent": envoys_sent, "suzerain_of": suzerain_of.keys(),
		"pantheon": str(pantheon_id), "religion": str(religion_id),
		"resource_stock": resource_stock, "great_person_points": great_person_points,
		"capital": capital_city_id,
		"original_capitals": original_capitals_held.keys(),
	}
