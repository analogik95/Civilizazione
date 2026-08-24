extends Node

## Seeded randomness, split into independent streams.
##
## Every consumer draws from a named stream rather than a single shared
## generator. Without this, adding one extra die roll to (say) the AI would
## shift every subsequent combat result, making "same seed reproduces the same
## game" impossible — and that reproducibility is what the determinism test and
## all AI debugging depend on.

var _streams: Dictionary = {}
var _master_seed: int = 0

const STREAM_MAP := &"map"
const STREAM_COMBAT := &"combat"
const STREAM_AI := &"ai"
const STREAM_BARBARIAN := &"barbarian"
const STREAM_GREAT_PEOPLE := &"great_people"
const STREAM_DISASTER := &"disaster"
const STREAM_MISC := &"misc"


func seed_game(master_seed: int) -> void:
	_master_seed = master_seed
	_streams.clear()


func get_master_seed() -> int:
	return _master_seed


func stream(name: StringName) -> RandomNumberGenerator:
	var rng: RandomNumberGenerator = _streams.get(name)
	if rng == null:
		rng = RandomNumberGenerator.new()
		# Hash the stream name into the seed so each stream is independent but
		# still fully determined by the master seed.
		rng.seed = hash(str(_master_seed) + "/" + str(name))
		_streams[name] = rng
	return rng


func randf_range_in(name: StringName, from: float, to: float) -> float:
	return stream(name).randf_range(from, to)


func randi_range_in(name: StringName, from: int, to: int) -> int:
	return stream(name).randi_range(from, to)


func chance(name: StringName, probability: float) -> bool:
	return stream(name).randf() < probability


func pick(name: StringName, options: Array) -> Variant:
	if options.is_empty():
		return null
	return options[stream(name).randi_range(0, options.size() - 1)]


## Weighted pick — the workhorse for AI decisions and content placement.
## `weights` must be the same length as `options`; non-positive weights are
## treated as ineligible.
func pick_weighted(name: StringName, options: Array, weights: PackedFloat32Array) -> Variant:
	if options.is_empty():
		return null
	var total := 0.0
	for w in weights:
		if w > 0.0:
			total += w
	if total <= 0.0:
		return null
	var roll := stream(name).randf() * total
	for i in options.size():
		if weights[i] <= 0.0:
			continue
		roll -= weights[i]
		if roll <= 0.0:
			return options[i]
	return options[options.size() - 1]


## Snapshot/restore so a save file reproduces the exact RNG position rather
## than restarting each stream from its seed.
func save_state() -> Dictionary:
	var out := {"master_seed": _master_seed, "streams": {}}
	for name: Variant in _streams:
		var rng: RandomNumberGenerator = _streams[name]
		out["streams"][str(name)] = {"seed": rng.seed, "state": rng.state}
	return out


func load_state(data: Dictionary) -> void:
	_master_seed = int(data.get("master_seed", 0))
	_streams.clear()
	var streams: Dictionary = data.get("streams", {})
	for name: Variant in streams:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(streams[name]["seed"])
		rng.state = int(streams[name]["state"])
		_streams[StringName(str(name))] = rng
