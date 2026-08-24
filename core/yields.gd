class_name Yields
extends RefCounted

## The seven per-turn output channels a tile, district, building or city produces.
##
## Housing, Amenities and Loyalty are deliberately NOT yields — they are city
## stats with their own rules (soft caps, mood buckets, pressure) and live on
## CityState instead. Keeping them out of here stops them being accidentally
## swept up by percentage modifiers that should only touch real yields.
##
## Values are floats because adjacency in Civ 6 is granted in half-steps: a
## "minor" adjacency source is worth +0.5 and two of them make +1.

enum Kind { FOOD, PRODUCTION, GOLD, SCIENCE, CULTURE, FAITH, TOURISM }

const KIND_COUNT := 7

const KIND_NAMES: Array[StringName] = [
	&"food", &"production", &"gold", &"science", &"culture", &"faith", &"tourism",
]

var v: PackedFloat32Array


func _init(values: PackedFloat32Array = PackedFloat32Array()) -> void:
	if values.size() == KIND_COUNT:
		v = values.duplicate()
	else:
		v.resize(KIND_COUNT)


## Build from a dictionary such as {"food": 2, "production": 1}. Unknown keys
## raise loudly rather than being silently dropped — a typo in content data
## should fail at load, not produce a city that quietly under-yields.
static func from_dict(d: Dictionary) -> Yields:
	var y := Yields.new()
	for key: Variant in d:
		var name := StringName(str(key))
		var idx := KIND_NAMES.find(name)
		assert(idx != -1, "Unknown yield kind in content data: %s" % name)
		if idx != -1:
			y.v[idx] = float(d[key])
	return y


static func of(kind: Kind, amount: float) -> Yields:
	var y := Yields.new()
	y.v[kind] = amount
	return y


func get_kind(kind: Kind) -> float:
	return v[kind]


func set_kind(kind: Kind, amount: float) -> void:
	v[kind] = amount


func add_kind(kind: Kind, amount: float) -> void:
	v[kind] += amount


## In-place accumulate. The yield pipeline runs this across every worked tile of
## every city every turn, so it avoids allocating a result object.
func accumulate(other: Yields) -> void:
	for i in KIND_COUNT:
		v[i] += other.v[i]


func accumulate_scaled(other: Yields, factor: float) -> void:
	for i in KIND_COUNT:
		v[i] += other.v[i] * factor


func plus(other: Yields) -> Yields:
	var out := duplicate()
	out.accumulate(other)
	return out


func scaled(factor: float) -> Yields:
	var out := Yields.new()
	for i in KIND_COUNT:
		out.v[i] = v[i] * factor
	return out


## Apply a set of additive percentage modifiers, expressed as whole percents
## keyed by Kind (so +15 means +15%). Civ 6 stacks these additively against the
## base rather than multiplicatively, which is why they are summed by the
## caller before arriving here.
func apply_percent(percents: PackedFloat32Array) -> void:
	for i in KIND_COUNT:
		if percents[i] != 0.0:
			v[i] *= 1.0 + percents[i] * 0.01


func is_zero() -> bool:
	for i in KIND_COUNT:
		if not is_zero_approx(v[i]):
			return false
	return true


func duplicate() -> Yields:
	return Yields.new(v)


func to_dict() -> Dictionary:
	var d := {}
	for i in KIND_COUNT:
		if not is_zero_approx(v[i]):
			d[KIND_NAMES[i]] = v[i]
	return d


func _to_string() -> String:
	var parts: PackedStringArray = []
	for i in KIND_COUNT:
		if not is_zero_approx(v[i]):
			parts.append("%+.1f %s" % [v[i], KIND_NAMES[i]])
	return "[%s]" % ", ".join(parts) if parts.size() > 0 else "[-]"
