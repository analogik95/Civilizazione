class_name UnitState
extends RefCounted

## One unit on the map.
##
## Combat Strength is a *stat*, HP is a separate 0-100 pool. A unit at 1 HP
## still fights at close to full strength — the damage curve only reads the
## strength difference — which is why wounded units stay dangerous and why
## retreating to heal is a real decision rather than a formality.

## Merging units trades numbers for a strength bonus, tuned against the damage
## curve: +10 is roughly 1.5x damage, +17 roughly 2x.
enum Formation { NONE, CORPS, ARMY }

const MAX_HP := 100
const MAX_LEVEL := 6
## XP for the first promotion; each subsequent level costs 15 more than the last.
const XP_PER_LEVEL := 15
## A single combat can never award more than this, so grinding a weak target
## cannot fast-track a unit to max level.
const MAX_XP_PER_COMBAT := 8

var id: int = -1
var owner_id: int = -1
var unit_id: StringName = &""
var coord: Vector2i = Vector2i.ZERO

var hp: int = MAX_HP
var movement_left: float = 0.0
var has_attacked: bool = false
var is_fortified: bool = false
var fortify_turns: int = 0
var is_embarked: bool = false
var is_set_up: bool = false

var xp: int = 0
var level: int = 1
var promotions: Dictionary = {}       # promotion_id -> true
var pending_promotions: int = 0

var formation: Formation = Formation.NONE

## Builders and similar carry a finite number of uses and vanish when spent.
var charges: int = 0

## Religious units track a separate strength used only in theological combat.
var religious_strength: float = 0.0
var religion_id: StringName = &""

## Set when the unit is asleep/skipping so the "unit needs orders" cycle skips it.
var is_sleeping: bool = false
var automation: StringName = &""


func _init(p_id: int = -1, p_owner: int = -1, p_unit_id: StringName = &"") -> void:
	id = p_id
	owner_id = p_owner
	unit_id = p_unit_id
	var def := definition()
	if def != null:
		movement_left = float(def.movement)
		charges = def.charges
		religious_strength = def.get_float("religious_strength", 0.0)


func definition() -> UnitDefs.UnitDef:
	return ContentDB.get_unit(unit_id)


func unit_class() -> UnitDefs.UnitClass:
	var def := definition()
	return def.unit_class if def != null else UnitDefs.UnitClass.CIVILIAN


func is_alive() -> bool:
	return hp > 0


func is_military() -> bool:
	var def := definition()
	return def != null and def.is_military()


func is_civilian() -> bool:
	return not is_military()


func can_attack() -> bool:
	return is_military() and not has_attacked and movement_left > 0.0 and is_alive()


func has_moved() -> bool:
	var def := definition()
	return def != null and movement_left < float(def.movement)


## Flat Combat Strength bonus from the formation, tuned against the damage curve.
func formation_bonus() -> float:
	match formation:
		Formation.CORPS: return 10.0
		Formation.ARMY: return 17.0
	return 0.0


## Fortifying is worth up to +6 after two turns dug in.
func fortify_bonus() -> float:
	if not is_fortified:
		return 0.0
	return 3.0 if fortify_turns < 2 else 6.0


## Base strength before terrain, promotions and modifier-engine bonuses.
func base_combat_strength() -> float:
	var def := definition()
	if def == null:
		return 0.0
	return def.combat_strength + formation_bonus()


func base_ranged_strength() -> float:
	var def := definition()
	if def == null:
		return 0.0
	return def.ranged_strength + formation_bonus()


## XP needed to go from `level` to the next one. Level 1->2 costs 15, 2->3
## costs 30, and so on.
static func xp_for_level(target_level: int) -> int:
	return XP_PER_LEVEL * (target_level - 1)


func award_xp(amount: int) -> bool:
	if level >= MAX_LEVEL:
		return false
	xp += mini(amount, MAX_XP_PER_COMBAT)
	var gained := false
	while level < MAX_LEVEL and xp >= xp_for_level(level + 1):
		xp -= xp_for_level(level + 1)
		level += 1
		pending_promotions += 1
		gained = true
	return gained


func has_promotion(promotion_id: StringName) -> bool:
	return promotions.has(promotion_id)


## Promotions available to take now: right class, prerequisite satisfied, not
## already taken.
func available_promotions() -> Array[UnitDefs.PromotionDef]:
	var out: Array[UnitDefs.PromotionDef] = []
	if pending_promotions <= 0:
		return out
	var my_class := unit_class()
	for p: UnitDefs.PromotionDef in ContentDB.promotions.values():
		if p.unit_class != my_class or promotions.has(p.id):
			continue
		if p.requires != &"" and not promotions.has(p.requires):
			continue
		out.append(p)
	return out


func take_promotion(promotion_id: StringName) -> bool:
	if pending_promotions <= 0 or promotions.has(promotion_id):
		return false
	promotions[promotion_id] = true
	pending_promotions -= 1
	return true


## Heal rate depends on where the unit spent the turn. Sitting still in your own
## territory recovers meaningfully faster than limping through enemy land.
func heal_amount(in_friendly_territory: bool, in_city: bool) -> int:
	if has_moved() or has_attacked:
		return 0
	if in_city:
		return 20
	if in_friendly_territory:
		return 15
	return 10


func begin_turn() -> void:
	var def := definition()
	if def != null:
		movement_left = float(def.movement)
	has_attacked = false
	if is_fortified:
		fortify_turns += 1


func spend_all_movement() -> void:
	movement_left = 0.0


func to_dict() -> Dictionary:
	return {
		"id": id, "owner": owner_id, "unit": str(unit_id),
		"coord": [coord.x, coord.y],
		"hp": hp, "movement_left": movement_left,
		"has_attacked": has_attacked, "fortified": is_fortified, "fortify_turns": fortify_turns,
		"embarked": is_embarked, "set_up": is_set_up,
		"xp": xp, "level": level,
		"promotions": promotions.keys().map(func(k: Variant) -> String: return str(k)),
		"pending_promotions": pending_promotions,
		"formation": formation, "charges": charges,
		"religion": str(religion_id), "religious_strength": religious_strength,
		"sleeping": is_sleeping, "automation": str(automation),
	}


static func from_dict(d: Dictionary) -> UnitState:
	var u := UnitState.new(int(d.get("id", -1)), int(d.get("owner", -1)), StringName(str(d.get("unit", ""))))
	var c: Array = d.get("coord", [0, 0])
	u.coord = Vector2i(int(c[0]), int(c[1]))
	u.hp = int(d.get("hp", MAX_HP))
	u.movement_left = float(d.get("movement_left", 0.0))
	u.has_attacked = bool(d.get("has_attacked", false))
	u.is_fortified = bool(d.get("fortified", false))
	u.fortify_turns = int(d.get("fortify_turns", 0))
	u.is_embarked = bool(d.get("embarked", false))
	u.is_set_up = bool(d.get("set_up", false))
	u.xp = int(d.get("xp", 0))
	u.level = int(d.get("level", 1))
	for p: Variant in d.get("promotions", []):
		u.promotions[StringName(str(p))] = true
	u.pending_promotions = int(d.get("pending_promotions", 0))
	u.formation = d.get("formation", Formation.NONE) as Formation
	u.charges = int(d.get("charges", 0))
	u.religion_id = StringName(str(d.get("religion", "")))
	u.religious_strength = float(d.get("religious_strength", 0.0))
	u.is_sleeping = bool(d.get("sleeping", false))
	u.automation = StringName(str(d.get("automation", "")))
	return u
