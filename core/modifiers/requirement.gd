class_name Requirement
extends RefCounted

## A single condition guarding a Modifier.
##
## Requirements are evaluated against a context Dictionary supplied by whatever
## query is running — it may carry any of: player, city, tile, coord, unit,
## opponent, district_id, production_kind. A requirement that asks for something
## the context does not carry evaluates false rather than erroring, so a
## city-scoped requirement can never accidentally pass during a unit query.

var type: StringName
var args: Dictionary
var inverse: bool


func _init(p_type: StringName, p_args: Dictionary = {}, p_inverse: bool = false) -> void:
	type = p_type
	args = p_args
	inverse = p_inverse


static func from_dict(d: Dictionary) -> Requirement:
	return Requirement.new(
		StringName(str(d.get("type", ""))),
		d.get("args", {}),
		bool(d.get("inverse", false)),
	)


func evaluate(ctx: Dictionary) -> bool:
	var result := _evaluate_inner(ctx)
	return not result if inverse else result


func _arg(key: String, fallback: Variant = null) -> Variant:
	return args.get(key, fallback)


## Content data writes ids as plain strings; comparisons here are all against
## StringName, so normalise once.
func _arg_name(key: String) -> StringName:
	return StringName(str(args.get(key, "")))


func _arg_names(key: String) -> Array:
	var raw: Variant = args.get(key, [])
	if raw is Array:
		var out: Array = []
		for item: Variant in raw:
			out.append(StringName(str(item)))
		return out
	return [StringName(str(raw))]


func _evaluate_inner(ctx: Dictionary) -> bool:
	var player: Variant = ctx.get("player")
	var city: Variant = ctx.get("city")
	var tile: Variant = ctx.get("tile")
	var unit: Variant = ctx.get("unit")

	match type:
		# ---- Player ----
		&"PLAYER_HAS_TECH":
			return player != null and player.has_tech(_arg_name("tech"))
		&"PLAYER_HAS_CIVIC":
			return player != null and player.has_civic(_arg_name("civic"))
		&"PLAYER_GOVERNMENT_IS":
			return player != null and player.government_id == _arg_name("government")
		&"PLAYER_ERA_AT_LEAST":
			return player != null and player.era >= int(_arg("era", 0))
		&"PLAYER_AT_WAR":
			return player != null and player.is_at_war_with_anyone()
		&"PLAYER_HAS_PANTHEON":
			return player != null and player.pantheon_id != &""

		# ---- City ----
		&"CITY_IS_CAPITAL":
			return city != null and city.is_capital
		&"CITY_HAS_DISTRICT":
			return city != null and city.has_district(_arg_name("district"))
		&"CITY_HAS_BUILDING":
			return city != null and city.has_building(_arg_name("building"))
		&"CITY_POPULATION_AT_LEAST":
			return city != null and city.population >= int(_arg("population", 1))
		&"CITY_HAS_FRESH_WATER":
			return city != null and city.has_fresh_water
		&"CITY_IS_COASTAL":
			return city != null and city.is_coastal
		&"CITY_FOLLOWS_RELIGION":
			return city != null and city.majority_religion == _arg_name("religion")
		&"CITY_HAS_GOVERNOR":
			return city != null and city.governor_id != &""

		# ---- Tile / plot ----
		&"TILE_TERRAIN_IS":
			return tile != null and _arg_names("terrain").has(tile.terrain_id)
		&"TILE_FEATURE_IS":
			return tile != null and _arg_names("feature").has(tile.feature_id)
		&"TILE_HAS_RESOURCE":
			if tile == null or tile.resource_id == &"":
				return false
			var wanted := _arg_names("resource")
			return wanted.is_empty() or wanted.has(tile.resource_id)
		&"TILE_HAS_RIVER":
			return tile != null and tile.has_river()
		&"TILE_IS_HILLS":
			return tile != null and tile.is_hills
		&"TILE_APPEAL_AT_LEAST":
			return tile != null and tile.appeal >= int(_arg("appeal", 0))
		&"TILE_HAS_IMPROVEMENT":
			if tile == null or tile.improvement_id == &"":
				return false
			var wanted_imp := _arg_names("improvement")
			return wanted_imp.is_empty() or wanted_imp.has(tile.improvement_id)

		# ---- Unit ----
		&"UNIT_CLASS_IS":
			return unit != null and _arg_names("unit_class").has(unit.unit_class())
		&"UNIT_IS_ATTACKING":
			return bool(ctx.get("is_attacking", false))
		&"UNIT_IN_FRIENDLY_TERRITORY":
			return bool(ctx.get("in_friendly_territory", false))
		&"UNIT_HEALTH_ABOVE":
			return unit != null and unit.hp > int(_arg("hp", 0))
		&"OPPONENT_CLASS_IS":
			var opponent: Variant = ctx.get("opponent")
			return opponent != null and _arg_names("unit_class").has(opponent.unit_class())
		&"OPPONENT_IS_BARBARIAN":
			return bool(ctx.get("opponent_is_barbarian", false))
		&"OPPONENT_IS_CITY":
			return bool(ctx.get("opponent_is_city", false))

		# ---- Production context ----
		&"PRODUCTION_KIND_IS":
			return _arg_names("kind").has(StringName(str(ctx.get("production_kind", ""))))
		&"PRODUCTION_ITEM_IS":
			return _arg_names("item").has(StringName(str(ctx.get("production_item", ""))))

	push_error("Unknown requirement type: %s" % type)
	return false
