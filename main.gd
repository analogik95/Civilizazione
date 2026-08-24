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
		var runner: Node = _load_tool("res://tests/test_runner.gd")
		if runner == null:
			get_tree().quit(1)
			return
		add_child(runner)
		var failures: int = runner.run_all()
		get_tree().quit(1 if failures > 0 else 0)
		return

	if args.has("--sim"):
		var sim: Node = _load_tool("res://tests/sim_runner.gd")
		if sim == null:
			get_tree().quit(1)
			return
		add_child(sim)
		var ok: bool = sim.run(_parse_options(args))
		get_tree().quit(0 if ok else 1)
		return

	if args.has("--shot"):
		var shot: Node = _load_tool("res://tools/screenshot_runner.gd")
		if shot == null:
			get_tree().quit(1)
			return
		add_child(shot)
		var saved: bool = await shot.run(_parse_options(args))
		get_tree().quit(0 if saved else 1)
		return

	if args.has("--play"):
		var play: Node = _load_tool("res://tools/playtest_runner.gd")
		if play == null:
			get_tree().quit(1)
			return
		add_child(play)
		var passed: bool = await play.run(_parse_options(args))
		get_tree().quit(0 if passed else 1)
		return

	_start_interactive()


## Development tools live outside the shipped build.
##
## They must be loaded at runtime, not preloaded: preload resolves when the
## script is parsed, so preloading a file the export filter strips stops main.gd
## compiling at all — which shipped a binary that failed on launch rather than
## one merely missing its test runner.
func _load_tool(path: String) -> Node:
	if not ResourceLoader.exists(path):
		printerr("%s is not present in this build (development tool)." % path)
		return null
	var script: GDScript = load(path)
	return script.new() if script != null else null


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
