extends Control

## Title screen and new-game setup.
##
## Options mirror the reference create-game screen: opponent count, map size,
## difficulty, turn limit, and an explicit seed so a map worth replaying can be
## replayed exactly.

const MAP_SIZES: Array[StringName] = [&"duel", &"tiny", &"small", &"standard", &"large", &"huge"]
const DIFFICULTIES: Array[StringName] = [
	&"settler", &"chieftain", &"warlord", &"prince", &"king", &"emperor", &"immortal", &"deity",
]

var _civs_slider: HSlider
var _map_option: OptionButton
var _difficulty_option: OptionButton
var _turns_option: OptionButton
var _seed_field: LineEdit
var _civs_label: Label
var _status: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var background := ColorRect.new()
	background.color = Color(0.06, 0.08, 0.13)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(460, 0)
	column.add_theme_constant_override("separation", 12)
	center.add_child(column)

	var title := Label.new()
	title.text = "CIVILIZAZIONE"
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(0.95, 0.83, 0.45))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "A turn-based game of empire"
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", Color(0.62, 0.70, 0.82))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(subtitle)

	column.add_child(_spacer(18))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 10)
	column.add_child(grid)

	# Opponents
	_civs_label = _field_label("Civilizations: 6")
	grid.add_child(_civs_label)
	_civs_slider = HSlider.new()
	_civs_slider.min_value = 2
	_civs_slider.max_value = 8
	_civs_slider.step = 1
	_civs_slider.value = 6
	_civs_slider.custom_minimum_size = Vector2(240, 0)
	_civs_slider.value_changed.connect(func(v: float) -> void:
		_civs_label.text = "Civilizations: %d" % int(v))
	grid.add_child(_civs_slider)

	grid.add_child(_field_label("Map size"))
	_map_option = OptionButton.new()
	for size in MAP_SIZES:
		_map_option.add_item(str(size).capitalize())
	_map_option.selected = 2   # small — the size that plays best at this stage
	grid.add_child(_map_option)

	grid.add_child(_field_label("Difficulty"))
	_difficulty_option = OptionButton.new()
	for difficulty in DIFFICULTIES:
		_difficulty_option.add_item(str(difficulty).capitalize())
	_difficulty_option.selected = 3   # prince — no handicap either way
	grid.add_child(_difficulty_option)

	grid.add_child(_field_label("Turn limit"))
	_turns_option = OptionButton.new()
	for limit in [100, 200, 300, 500]:
		_turns_option.add_item(str(limit))
	_turns_option.selected = 1
	grid.add_child(_turns_option)

	grid.add_child(_field_label("Seed"))
	_seed_field = LineEdit.new()
	_seed_field.placeholder_text = "leave blank for random"
	grid.add_child(_seed_field)

	column.add_child(_spacer(14))

	var play := Button.new()
	play.text = "Begin"
	play.custom_minimum_size = Vector2(0, 44)
	play.add_theme_font_size_override("font_size", 18)
	play.pressed.connect(_start_game)
	column.add_child(play)

	var quit := Button.new()
	quit.text = "Quit"
	quit.custom_minimum_size = Vector2(0, 32)
	quit.pressed.connect(func() -> void: get_tree().quit())
	column.add_child(quit)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", Color(0.62, 0.70, 0.82))
	column.add_child(_status)

	var controls := Label.new()
	controls.text = "WASD or drag to pan  ·  wheel to zoom  ·  Tab next unit  ·  Space end turn"
	controls.add_theme_font_size_override("font_size", 11)
	controls.add_theme_color_override("font_color", Color(0.45, 0.52, 0.62))
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(controls)


func _field_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	return label


func _spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


func _start_game() -> void:
	_status.text = "Generating world..."
	# Let the status paint before the generator blocks the frame.
	await get_tree().process_frame

	var seed_text := _seed_field.text.strip_edges()
	var seed_value := int(seed_text) if seed_text.is_valid_int() else randi()

	GameSetup.new_game(Game, {
		"seed": seed_value,
		"civs": int(_civs_slider.value),
		"map_size": MAP_SIZES[_map_option.selected],
		"difficulty": DIFFICULTIES[_difficulty_option.selected],
		"turn_limit": int(_turns_option.get_item_text(_turns_option.selected)),
		"human": 0,
	})
	TurnManager.start_game(Game)

	get_tree().change_scene_to_file("res://view/game_view.tscn")
