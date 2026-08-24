extends SceneTree
func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		var image := Image.new()
		if image.load(arg) == OK:
			image.save_png(arg.get_basename() + ".png")
			print("converted ", arg)
	quit()
