class_name ModifierEngine
extends RefCounted

## Holds every active Modifier in the game and answers "what is the total bonus
## to X here?".
##
## Modifiers arrive attached to a *source* — a slotted policy card, a completed
## building, a founded belief, a governor promotion, a suzerainty. When a source
## goes away (card unslotted, city captured, suzerainty lost) the engine drops
## its modifiers wholesale, so nothing has to remember to undo a bonus by hand.
##
## Queries come in two shapes:
##   sum_scalar(effect, ctx)  — additive numeric bonuses (combat strength, housing)
##   sum_yields(effect, ctx)  — additive yield bundles (+1 Faith, +1 Gold)
## Systems wrap these in named helpers below for readability at the call site.

## Per player: {source_key: Array[Modifier]}
var _sources: Dictionary = {}
## Per player: {effect: Array[Modifier]} — rebuilt lazily from _sources.
var _index: Dictionary = {}
var _index_dirty: Dictionary = {}

## Bumped whenever anything changes; cached query results carry the generation
## they were computed at and are recomputed when stale. Cheaper and far less
## error-prone than tracking which specific caches each event invalidates.
var _generation: int = 0
var _cache: Dictionary = {}


func _source_key(kind: StringName, id: StringName) -> String:
	return "%s/%s" % [kind, id]


## Replace all modifiers contributed by one source for one player.
func set_source(player_id: int, kind: StringName, source_id: StringName, mods: Array[Modifier]) -> void:
	var by_source: Dictionary = _sources.get_or_add(player_id, {})
	var tagged: Array[Modifier] = []
	for m in mods:
		tagged.append(m.with_source(kind, source_id))
	by_source[_source_key(kind, source_id)] = tagged
	_invalidate(player_id)


func clear_source(player_id: int, kind: StringName, source_id: StringName) -> void:
	var by_source: Dictionary = _sources.get(player_id, {})
	if by_source.erase(_source_key(kind, source_id)):
		_invalidate(player_id)


func clear_player(player_id: int) -> void:
	_sources.erase(player_id)
	_invalidate(player_id)


func _invalidate(player_id: int) -> void:
	_index_dirty[player_id] = true
	_generation += 1
	_cache.clear()


## Any game event that could change a requirement outcome — a tech researched, a
## district built, a war declared — calls this. Deliberately coarse.
func invalidate_all() -> void:
	for player_id: Variant in _index_dirty:
		_index_dirty[player_id] = true
	_generation += 1
	_cache.clear()


func _effects_for(player_id: int, effect: StringName) -> Array:
	if _index_dirty.get(player_id, true):
		_rebuild_index(player_id)
	var by_effect: Dictionary = _index.get(player_id, {})
	return by_effect.get(effect, [])


func _rebuild_index(player_id: int) -> void:
	var by_effect: Dictionary = {}
	for mods: Variant in _sources.get(player_id, {}).values():
		for m: Modifier in mods:
			by_effect.get_or_add(m.effect, []).append(m)
	_index[player_id] = by_effect
	_index_dirty[player_id] = false


func _player_id_from(ctx: Dictionary) -> int:
	var player: Variant = ctx.get("player")
	return player.id if player != null else -1


# -------------------------------------------------------------------------
# Generic queries
# -------------------------------------------------------------------------

## Sum the "amount" argument of every matching modifier.
func sum_scalar(effect: StringName, ctx: Dictionary) -> float:
	var player_id := _player_id_from(ctx)
	if player_id < 0:
		return 0.0
	var total := 0.0
	for m: Modifier in _effects_for(player_id, effect):
		if m.applies(ctx):
			total += m.arg_float("amount")
	return total


## Sum the "yields" argument of every matching modifier.
func sum_yields(effect: StringName, ctx: Dictionary) -> Yields:
	var out := Yields.new()
	var player_id := _player_id_from(ctx)
	if player_id < 0:
		return out
	for m: Modifier in _effects_for(player_id, effect):
		if m.applies(ctx):
			out.accumulate(m.arg_yields())
	return out


## Sum percentage adjustments per yield kind. Civ 6 stacks these additively —
## two +15% Science cards give +30%, not +32.25%.
func sum_yield_percent(effect: StringName, ctx: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(Yields.KIND_COUNT)
	var player_id := _player_id_from(ctx)
	if player_id < 0:
		return out
	for m: Modifier in _effects_for(player_id, effect):
		if not m.applies(ctx):
			continue
		var percents: Variant = m.arg("percent", {})
		if percents is Dictionary:
			for key: Variant in percents:
				var idx := Yields.KIND_NAMES.find(StringName(str(key)))
				if idx != -1:
					out[idx] += float(percents[key])
	return out


## Every matching modifier, for tooltips that need to attribute each contribution
## to its source rather than just show a total.
func collect(effect: StringName, ctx: Dictionary) -> Array[Modifier]:
	var out: Array[Modifier] = []
	var player_id := _player_id_from(ctx)
	if player_id < 0:
		return out
	for m: Modifier in _effects_for(player_id, effect):
		if m.applies(ctx):
			out.append(m)
	return out


func has_any(effect: StringName, ctx: Dictionary) -> bool:
	var player_id := _player_id_from(ctx)
	if player_id < 0:
		return false
	for m: Modifier in _effects_for(player_id, effect):
		if m.applies(ctx):
			return true
	return false


## Memoised scalar query for hot per-turn paths. `key` must uniquely identify
## the subject (e.g. "city:12"); contexts that vary per call (unit combat) must
## not use this.
func cached_scalar(key: String, effect: StringName, ctx: Dictionary) -> float:
	var full_key := "%s|%s" % [key, effect]
	var entry: Variant = _cache.get(full_key)
	if entry != null and entry["gen"] == _generation:
		return entry["value"]
	var value := sum_scalar(effect, ctx)
	_cache[full_key] = {"gen": _generation, "value": value}
	return value


# -------------------------------------------------------------------------
# Named helpers — the vocabulary the rest of the simulation speaks
# -------------------------------------------------------------------------

const EFFECT_CITY_YIELD_FLAT := &"ADJUST_CITY_YIELD_FLAT"
const EFFECT_CITY_YIELD_PERCENT := &"ADJUST_CITY_YIELD_PERCENT"
const EFFECT_CITY_YIELD_PER_POP := &"ADJUST_CITY_YIELD_PER_POPULATION"
const EFFECT_CITY_HOUSING := &"ADJUST_CITY_HOUSING"
const EFFECT_CITY_AMENITIES := &"ADJUST_CITY_AMENITIES"
const EFFECT_CITY_LOYALTY := &"ADJUST_CITY_LOYALTY_PER_TURN"
const EFFECT_DISTRICT_ADJACENCY := &"ADJUST_DISTRICT_ADJACENCY"
const EFFECT_PRODUCTION_PERCENT := &"ADJUST_PRODUCTION_PERCENT"
const EFFECT_UNIT_COMBAT_STRENGTH := &"ADJUST_UNIT_COMBAT_STRENGTH"
const EFFECT_UNIT_MOVEMENT := &"ADJUST_UNIT_MOVEMENT"
const EFFECT_UNIT_EXPERIENCE_PERCENT := &"ADJUST_UNIT_EXPERIENCE_PERCENT"
const EFFECT_UNIT_MAINTENANCE := &"ADJUST_UNIT_MAINTENANCE"
const EFFECT_INFLUENCE_PER_TURN := &"ADJUST_INFLUENCE_PER_TURN"
const EFFECT_GREAT_PERSON_PERCENT := &"ADJUST_GREAT_PERSON_POINTS_PERCENT"
const EFFECT_BOOST_PERCENT := &"ADJUST_BOOST_PERCENT"
const EFFECT_BUILDER_CHARGES := &"ADJUST_BUILDER_CHARGES"
const EFFECT_TRADE_CAPACITY := &"ADJUST_TRADE_CAPACITY"
const EFFECT_SETTLER_COST_PERCENT := &"ADJUST_SETTLER_COST_PERCENT"


func city_flat_yields(ctx: Dictionary) -> Yields:
	var out := sum_yields(EFFECT_CITY_YIELD_FLAT, ctx)
	var city: Variant = ctx.get("city")
	if city != null:
		out.accumulate(sum_yields(EFFECT_CITY_YIELD_PER_POP, ctx).scaled(city.population))
	return out


func city_yield_percent(ctx: Dictionary) -> PackedFloat32Array:
	return sum_yield_percent(EFFECT_CITY_YIELD_PERCENT, ctx)


func city_housing(ctx: Dictionary) -> float:
	return sum_scalar(EFFECT_CITY_HOUSING, ctx)


func city_amenities(ctx: Dictionary) -> float:
	return sum_scalar(EFFECT_CITY_AMENITIES, ctx)


func district_adjacency(ctx: Dictionary) -> float:
	return sum_scalar(EFFECT_DISTRICT_ADJACENCY, ctx)


func unit_combat_strength(ctx: Dictionary) -> float:
	return sum_scalar(EFFECT_UNIT_COMBAT_STRENGTH, ctx)


func production_percent(ctx: Dictionary) -> float:
	return sum_scalar(EFFECT_PRODUCTION_PERCENT, ctx)
