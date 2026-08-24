class_name ContentDef
extends RefCounted

## Base for every piece of game content loaded from data/*.json.
##
## Content is JSON rather than .tres because there is a lot of it — hundreds of
## techs, civics, units, buildings, policy cards and beliefs — and JSON stays
## readable, diffable and hand-editable at that volume. ContentDB parses it into
## these typed wrappers once at boot so the rest of the simulation never touches
## raw dictionaries.

var id: StringName
var name: String
var description: String = ""
var icon: StringName = &""

## Modifiers this content grants while active. A policy card's bonus, a
## building's yield, a leader's unique ability all live here.
var modifiers: Array[Modifier] = []

## Everything from the source record, for fields a subclass does not model
## explicitly. Lets content carry experimental data without an engine change.
var raw: Dictionary = {}


func _init(d: Dictionary = {}) -> void:
	raw = d
	id = StringName(str(d.get("id", "")))
	name = str(d.get("name", id))
	description = str(d.get("description", ""))
	icon = StringName(str(d.get("icon", "")))
	for mod_data: Variant in d.get("modifiers", []):
		modifiers.append(Modifier.from_dict(mod_data))
	_parse(d)


## Subclasses override to pull out their own fields.
func _parse(_d: Dictionary) -> void:
	pass


func get_int(key: String, fallback: int = 0) -> int:
	return int(raw.get(key, fallback))


func get_float(key: String, fallback: float = 0.0) -> float:
	return float(raw.get(key, fallback))


func get_bool(key: String, fallback: bool = false) -> bool:
	return bool(raw.get(key, fallback))


func get_name(key: String, fallback: String = "") -> StringName:
	return StringName(str(raw.get(key, fallback)))


func get_yields(key: String = "yields") -> Yields:
	var v: Variant = raw.get(key, {})
	return Yields.from_dict(v) if v is Dictionary else Yields.new()


## Read a list of ids, normalising to StringName.
func get_names(key: String) -> Array[StringName]:
	var out: Array[StringName] = []
	var v: Variant = raw.get(key, [])
	if v is Array:
		for item: Variant in v:
			out.append(StringName(str(item)))
	elif str(v) != "":
		out.append(StringName(str(v)))
	return out


func _to_string() -> String:
	return "<%s %s>" % [get_script().get_global_name(), id]
