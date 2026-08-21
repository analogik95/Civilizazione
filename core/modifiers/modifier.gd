class_name Modifier
extends RefCounted

## "Under condition X, adjust Y by Z."
##
## Every conditional bonus in the game is one of these: policy cards, religious
## beliefs, governor promotions, suzerain bonuses, wonders, leader abilities,
## Golden Age dedications, World Congress resolutions. Content authors add
## bonuses by writing modifier data, not by editing engine code — new *kinds* of
## effect need a handler in ModifierEngine, but new *content* never does.

## Which sort of subject this modifier is asking about. The engine only tests a
## modifier during queries whose scope matches, so a city modifier is never
## evaluated against a unit.
enum Scope { PLAYER, CITY, DISTRICT, PLOT, UNIT }

const SCOPE_NAMES := {
	"player": Scope.PLAYER,
	"city": Scope.CITY,
	"district": Scope.DISTRICT,
	"plot": Scope.PLOT,
	"unit": Scope.UNIT,
}

var id: StringName
var effect: StringName
var scope: Scope = Scope.PLAYER
var args: Dictionary = {}
var requirements: Array[Requirement] = []

## Free-text, shown in tooltips ("+1 Faith and +1 Gold in the Capital").
var description: String = ""

## Where this modifier came from, so the UI can attribute a yield to the policy
## card or belief responsible, and so the engine can detach it again when the
## card is unslotted or the city is lost.
var source_kind: StringName = &""
var source_id: StringName = &""


func _init(p_id: StringName = &"", p_effect: StringName = &"") -> void:
	id = p_id
	effect = p_effect


static func from_dict(d: Dictionary) -> Modifier:
	var m := Modifier.new(
		StringName(str(d.get("id", ""))),
		StringName(str(d.get("effect", ""))),
	)
	m.scope = SCOPE_NAMES.get(str(d.get("scope", "player")), Scope.PLAYER)
	m.args = d.get("args", {})
	m.description = str(d.get("description", ""))
	for req_data: Variant in d.get("requirements", []):
		m.requirements.append(Requirement.from_dict(req_data))
	return m


## True when every requirement passes. An empty requirement list means the
## modifier always applies within its scope.
func applies(ctx: Dictionary) -> bool:
	for req in requirements:
		if not req.evaluate(ctx):
			return false
	return true


func arg(key: String, fallback: Variant = null) -> Variant:
	return args.get(key, fallback)


func arg_float(key: String, fallback: float = 0.0) -> float:
	return float(args.get(key, fallback))


func arg_int(key: String, fallback: int = 0) -> int:
	return int(args.get(key, fallback))


func arg_name(key: String) -> StringName:
	return StringName(str(args.get(key, "")))


## Yields carried by the modifier, e.g. {"food": 1, "faith": 2}.
func arg_yields(key: String = "yields") -> Yields:
	var raw: Variant = args.get(key, {})
	return Yields.from_dict(raw) if raw is Dictionary else Yields.new()


func with_source(kind: StringName, source: StringName) -> Modifier:
	source_kind = kind
	source_id = source
	return self


func _to_string() -> String:
	return "<Modifier %s %s from %s:%s>" % [id, effect, source_kind, source_id]
