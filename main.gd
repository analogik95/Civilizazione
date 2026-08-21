extends Node

## Entry point. Dispatches to the interactive game, the headless soak runner, or
## the test suite based on user args after `--`:
##
##   godot --headless --path . -- --test
##   godot --headless --path . -- --sim turns=200 civs=6 seed=1234
##   godot --path .                      (normal play)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()

	if args.has("--test"):
		var runner: Node = preload("res://tests/test_runner.gd").new()
		add_child(runner)
		var failures: int = runner.run_all()
		get_tree().quit(1 if failures > 0 else 0)
		return

	if args.has("--sim"):
		var sim: Node = preload("res://tests/sim_runner.gd").new()
		add_child(sim)
		var ok: bool = sim.run(_parse_options(args))
		get_tree().quit(0 if ok else 1)
		return

	if args.has("--shot"):
		var shot: Node = preload("res://tools/screenshot_runner.gd").new()
		add_child(shot)
		var saved: bool = await shot.run(_parse_options(args))
		get_tree().quit(0 if saved else 1)
		return

	_start_interactive()


## Parse `key=value` arguments into a dictionary, leaving bare flags out.
func _parse_options(args: PackedStringArray) -> Dictionary:
	var out := {}
	for arg in args:
		var stripped := arg.trim_prefix("--")
		if stripped.contains("="):
			var parts := stripped.split("=", true, 1)
			out[parts[0]] = parts[1]
	return out


func _start_interactive() -> void:
	var menu_path := "res://ui/screens/main_menu.tscn"
	if ResourceLoader.exists(menu_path):
		get_tree().change_scene_to_file(menu_path)
	else:
		push_warning("Main menu scene not built yet — nothing to show.")
