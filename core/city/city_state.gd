class_name CityState
extends RefCounted

## A city: its citizens, its districts, its production, and the three soft caps
## (Housing, Amenities, Loyalty) that decide whether it thrives or unravels.
##
## The yield pipeline runs in a fixed order — worked tiles, then districts and
## their adjacency, then buildings, then flat modifier bonuses, then percentage
## modifiers. Order matters: percentages must see the finished flat total, or a
## +15% Science card would silently ignore a Library.

## What a city can be putting production into.
enum ProductionKind { UNIT, BUILDING, DISTRICT, WONDER, PROJECT }

## Amenity balance buckets. Below Content, yields and growth take a penalty;
## above it they get a bonus.
enum Mood { ECSTATIC, HAPPY, CONTENT, DISPLEASED, UNHAPPY, IN_REVOLT }

const BASE_HOUSING_NO_WATER := 2.0
const BASE_HOUSING_FRESH_WATER := 3.0
const BASE_HOUSING_COASTAL := 1.0
## Growth stops entirely this far above the Housing cap.
const HOUSING_HARD_STOP := 5.0
## Citizens are free of Amenity demand up to this population.
const FREE_AMENITY_POPULATION := 2
const MAX_LOYALTY := 100.0

var id: int = -1
var owner_id: int = -1
var original_owner_id: int = -1
var name: String = ""
var coord: Vector2i = Vector2i.ZERO
var is_capital: bool = false

var population: int = 1
var food_stored: float = 0.0

## Tiles this city owns, and the subset its citizens are currently working.
var owned_tiles: Array[Vector2i] = []
var worked_tiles: Array[Vector2i] = []

## district_id -> coord. One entry per built district, including city_center.
var districts: Dictionary = {}
var buildings: Dictionary = {}        # building_id -> true
var wonders: Dictionary = {}          # wonder_id -> true

# --- Production ---
var production_kind: ProductionKind = ProductionKind.UNIT
var production_item: StringName = &""
var production_progress: float = 0.0
## Queued (kind, item) pairs after the current item.
var production_queue: Array = []

# --- Derived, recomputed each turn ---
var yields: Yields = Yields.new()
var housing: float = 0.0
var amenities: float = 0.0
var amenities_needed: float = 0.0
var mood: Mood = Mood.CONTENT
var defense_strength: float = 0.0
var wall_hp: int = 0
var max_wall_hp: int = 0
var center_hp: int = 200
var max_center_hp: int = 200

# --- Rise and Fall ---
var loyalty: float = MAX_LOYALTY
var loyalty_per_turn: float = 0.0
var governor_id: StringName = &""
var governor_turns: int = 0

# --- Religion ---
var majority_religion: StringName = &""
var religious_pressure: Dictionary = {}   # religion_id -> float

# --- Cached geography ---
var has_fresh_water: bool = false
var is_coastal: bool = false

var turns_since_founded: int = 0
var is_razing: bool = false


func _init(p_id: int = -1, p_owner: int = -1, p_coord: Vector2i = Vector2i.ZERO) -> void:
	id = p_id
	owner_id = p_owner
	original_owner_id = p_owner
	coord = p_coord


func has_district(district_id: StringName) -> bool:
	return districts.has(district_id)


func has_building(building_id: StringName) -> bool:
	return buildings.has(building_id)


func district_coord(district_id: StringName) -> Vector2i:
	return districts.get(district_id, Vector2i(-9999, -9999))


## Specialty districts only — the City Center does not count against the
## population-gated district allowance.
func specialty_district_count() -> int:
	var count := 0
	for district_id: StringName in districts:
		var d := ContentDB.get_district(district_id)
		if d != null and d.is_specialty:
			count += 1
	return count


## How many specialty districts this city may hold. Civ 6 grants one per three
## citizens, so a size-1 city gets one and a size-7 city gets three.
func district_allowance() -> int:
	return 1 + int(floor(population / 3.0))


func can_build_another_district() -> bool:
	return specialty_district_count() < district_allowance()


# -------------------------------------------------------------------------
# Growth
# -------------------------------------------------------------------------

## Food needed to add the next citizen. Rises steeply so large cities need
## dedicated food infrastructure rather than coasting on their tiles.
func food_to_grow() -> float:
	return 15.0 + 8.0 * (population - 1) + pow(population - 1, 1.5)


## Food consumed by the existing population, at 2 per citizen.
func food_consumption() -> float:
	return population * 2.0


## Growth multiplier from Housing pressure. Civ 6 slows growth as a city
## approaches its Housing cap and halts it entirely well past it — the
## mechanism that makes Housing infrastructure mandatory rather than optional.
func housing_growth_modifier() -> float:
	var headroom := housing - population
	if headroom >= 2.0:
		return 1.0
	if headroom >= 1.0:
		return 0.5
	if headroom >= 0.0:
		return 0.25
	if headroom > -HOUSING_HARD_STOP:
		return 0.1
	return 0.0


## Growth and yield multiplier from the Amenity mood.
func mood_growth_modifier() -> float:
	match mood:
		Mood.ECSTATIC: return 1.2
		Mood.HAPPY: return 1.1
		Mood.CONTENT: return 1.0
		Mood.DISPLEASED: return 0.85
		Mood.UNHAPPY: return 0.7
		Mood.IN_REVOLT: return 0.0
	return 1.0


func mood_yield_modifier() -> float:
	match mood:
		Mood.ECSTATIC: return 1.10
		Mood.HAPPY: return 1.05
		Mood.CONTENT: return 1.0
		Mood.DISPLEASED: return 0.85
		Mood.UNHAPPY: return 0.70
		Mood.IN_REVOLT: return 0.40
	return 1.0


## Loyalty below full drags on yields, and a city in open disloyalty barely
## functions — the pressure that makes far-flung conquests expensive to hold.
func loyalty_yield_modifier() -> float:
	if loyalty >= 100.0:
		return 1.0
	if loyalty >= 75.0:
		return 1.0
	if loyalty >= 50.0:
		return 0.75
	if loyalty >= 25.0:
		return 0.5
	return 0.25


## Amenities this city demands: one per two citizens past the first two.
func compute_amenities_needed() -> float:
	return maxf(0.0, ceilf((population - FREE_AMENITY_POPULATION) / 2.0))


func compute_mood() -> Mood:
	var balance := amenities - amenities_needed
	if balance >= 3.0:
		return Mood.ECSTATIC
	if balance >= 1.0:
		return Mood.HAPPY
	if balance >= 0.0:
		return Mood.CONTENT
	if balance >= -2.0:
		return Mood.DISPLEASED
	if balance >= -4.0:
		return Mood.UNHAPPY
	return Mood.IN_REVOLT


func turns_until_growth() -> int:
	var surplus := yields.get_kind(Yields.Kind.FOOD) - food_consumption()
	surplus *= housing_growth_modifier() * mood_growth_modifier()
	if surplus <= 0.01:
		return -1
	return int(ceil((food_to_grow() - food_stored) / surplus))


func turns_until_production() -> int:
	var per_turn := yields.get_kind(Yields.Kind.PRODUCTION)
	if per_turn <= 0.01 or production_item == &"":
		return -1
	return int(ceil((production_cost() - production_progress) / per_turn))


func production_cost() -> float:
	match production_kind:
		ProductionKind.UNIT:
			var u := ContentDB.get_unit(production_item)
			return float(u.cost) if u != null else 0.0
		ProductionKind.BUILDING:
			var b := ContentDB.get_building(production_item)
			return float(b.cost) if b != null else 0.0
		ProductionKind.DISTRICT:
			var d := ContentDB.get_district(production_item)
			return float(d.cost) if d != null else 0.0
		ProductionKind.WONDER:
			var w: CityDefs.WonderDef = ContentDB.wonders.get(production_item)
			return float(w.cost) if w != null else 0.0
	return 0.0


# -------------------------------------------------------------------------
# Defence
# -------------------------------------------------------------------------

## City Combat Strength tracks the best melee unit the owner can field, minus a
## constant, plus a bonus per district — so a developed city is genuinely harder
## to take than a fresh one even without walls.
func compute_defense_strength(best_melee_strength: float, garrison: UnitState) -> float:
	var base := maxf(best_melee_strength - 10.0, 10.0)
	base += specialty_district_count() * 2.0
	if garrison != null and garrison.is_military():
		base = maxf(base, garrison.base_combat_strength())
	return base


func has_walls() -> bool:
	return max_wall_hp > 0


func is_defeated() -> bool:
	return center_hp <= 0


func set_production(kind: ProductionKind, item: StringName) -> void:
	if production_kind == kind and production_item == item:
		return
	production_kind = kind
	production_item = item
	production_progress = 0.0


func to_dict() -> Dictionary:
	var district_out := {}
	for district_id: StringName in districts:
		var c: Vector2i = districts[district_id]
		district_out[str(district_id)] = [c.x, c.y]
	return {
		"id": id, "owner": owner_id, "original_owner": original_owner_id,
		"name": name, "coord": [coord.x, coord.y], "capital": is_capital,
		"population": population, "food_stored": food_stored,
		"owned_tiles": owned_tiles.map(func(c: Vector2i) -> Array: return [c.x, c.y]),
		"worked_tiles": worked_tiles.map(func(c: Vector2i) -> Array: return [c.x, c.y]),
		"districts": district_out,
		"buildings": buildings.keys().map(func(k: Variant) -> String: return str(k)),
		"wonders": wonders.keys().map(func(k: Variant) -> String: return str(k)),
		"production_kind": production_kind, "production_item": str(production_item),
		"production_progress": production_progress, "production_queue": production_queue,
		"loyalty": loyalty, "governor": str(governor_id), "governor_turns": governor_turns,
		"majority_religion": str(majority_religion), "religious_pressure": religious_pressure,
		"wall_hp": wall_hp, "max_wall_hp": max_wall_hp,
		"center_hp": center_hp, "max_center_hp": max_center_hp,
		"turns_since_founded": turns_since_founded,
	}


static func from_dict(d: Dictionary) -> CityState:
	var raw_coord: Array = d.get("coord", [0, 0])
	var c := CityState.new(int(d.get("id", -1)), int(d.get("owner", -1)), Vector2i(int(raw_coord[0]), int(raw_coord[1])))
	c.original_owner_id = int(d.get("original_owner", c.owner_id))
	c.name = str(d.get("name", ""))
	c.is_capital = bool(d.get("capital", false))
	c.population = int(d.get("population", 1))
	c.food_stored = float(d.get("food_stored", 0.0))
	for t: Variant in d.get("owned_tiles", []):
		c.owned_tiles.append(Vector2i(int(t[0]), int(t[1])))
	for t: Variant in d.get("worked_tiles", []):
		c.worked_tiles.append(Vector2i(int(t[0]), int(t[1])))
	for district_id: Variant in d.get("districts", {}):
		var dc: Array = d["districts"][district_id]
		c.districts[StringName(str(district_id))] = Vector2i(int(dc[0]), int(dc[1]))
	for b: Variant in d.get("buildings", []):
		c.buildings[StringName(str(b))] = true
	for w: Variant in d.get("wonders", []):
		c.wonders[StringName(str(w))] = true
	c.production_kind = d.get("production_kind", ProductionKind.UNIT) as ProductionKind
	c.production_item = StringName(str(d.get("production_item", "")))
	c.production_progress = float(d.get("production_progress", 0.0))
	c.production_queue = d.get("production_queue", [])
	c.loyalty = float(d.get("loyalty", MAX_LOYALTY))
	c.governor_id = StringName(str(d.get("governor", "")))
	c.governor_turns = int(d.get("governor_turns", 0))
	c.majority_religion = StringName(str(d.get("majority_religion", "")))
	c.religious_pressure = d.get("religious_pressure", {})
	c.wall_hp = int(d.get("wall_hp", 0))
	c.max_wall_hp = int(d.get("max_wall_hp", 0))
	c.center_hp = int(d.get("center_hp", 200))
	c.max_center_hp = int(d.get("max_center_hp", 200))
	c.turns_since_founded = int(d.get("turns_since_founded", 0))
	return c
