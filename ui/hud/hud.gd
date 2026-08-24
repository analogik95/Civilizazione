extends Control

## The in-game HUD.
##
## Layout follows the information architecture of the reference screenshots: a
## yield strip across the top with the turn counter at its right, a research
## tracker top-left, the selected unit and End Turn bottom-right, and a city
## summary strip along the bottom when a city is open. The chrome is original —
## only the arrangement is borrowed, because that arrangement is what makes a
## 4X readable.
##
## Everything here is built in code rather than a .tscn so the whole layout is
## reviewable in one place.

signal end_turn_pressed()
signal next_unit_pressed()
signal action_requested(action: StringName)
signal lens_toggled()

const PANEL_BG := Color(0.09, 0.11, 0.16, 0.92)
const PANEL_EDGE := Color(0.42, 0.52, 0.68, 0.85)
const ACCENT := Color(0.95, 0.83, 0.45)
const TEXT_DIM := Color(0.72, 0.78, 0.88)

var _human_id: int = 0
var _selected_unit: UnitState = null
var _open_city: CityState = null

var _yield_bar: HBoxContainer
var _turn_label: Label
var _research_panel: VBoxContainer
var _unit_panel: PanelContainer
var _unit_title: Label
var _unit_stats: Label
var _action_bar: HBoxContainer
var _city_panel: PanelContainer
var _city_body: VBoxContainer
var _toast: Label
var _lens_button: Button
var _game_over: PanelContainer


func setup(human_id: int) -> void:
	_human_id = human_id
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


# -------------------------------------------------------------------------
# Construction
# -------------------------------------------------------------------------

func _styled_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _label(text: String, size: int = 14, color: Color = Color.WHITE, wrap: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _button(text: String, tooltip: String = "") -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.custom_minimum_size = Vector2(0, 30)
	button.add_theme_font_size_override("font_size", 13)
	return button


func _build() -> void:
	_build_top_bar()
	_build_research_tracker()
	_build_unit_panel()
	_build_city_panel()
	_build_toast()


func _build_top_bar() -> void:
	var panel := _styled_panel()
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_bottom = 34
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	panel.add_child(row)

	_yield_bar = HBoxContainer.new()
	_yield_bar.add_theme_constant_override("separation", 16)
	row.add_child(_yield_bar)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_turn_label = _label("", 14, ACCENT)
	row.add_child(_turn_label)


func _build_research_tracker() -> void:
	var panel := _styled_panel()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 8
	panel.offset_top = 42
	panel.custom_minimum_size = Vector2(230, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	_research_panel = VBoxContainer.new()
	_research_panel.add_theme_constant_override("separation", 6)
	panel.add_child(_research_panel)


func _build_unit_panel() -> void:
	_unit_panel = _styled_panel()
	_unit_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_unit_panel.offset_left = -300
	_unit_panel.offset_top = -168
	_unit_panel.offset_right = -8
	_unit_panel.offset_bottom = -8
	_unit_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_unit_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_unit_panel.add_child(column)

	_unit_title = _label("No unit selected", 16, ACCENT)
	column.add_child(_unit_title)

	_unit_stats = _label("", 12, TEXT_DIM)
	column.add_child(_unit_stats)

	_action_bar = HBoxContainer.new()
	_action_bar.add_theme_constant_override("separation", 4)
	column.add_child(_action_bar)

	column.add_child(HSeparator.new())

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	column.add_child(buttons)

	_lens_button = _button("Yields (Y)", "Show each tile's yields as coloured pips.")
	_lens_button.toggle_mode = true
	_lens_button.pressed.connect(func() -> void: lens_toggled.emit())
	_action_bar.get_parent().add_child(_lens_button)
	_action_bar.get_parent().move_child(_lens_button, _action_bar.get_index() + 1)

	var next_unit := _button("Next Unit  (Tab)")
	next_unit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next_unit.pressed.connect(func() -> void: next_unit_pressed.emit())
	buttons.add_child(next_unit)

	var end_turn := _button("End Turn  (Space)")
	end_turn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	end_turn.add_theme_color_override("font_color", ACCENT)
	end_turn.pressed.connect(func() -> void: end_turn_pressed.emit())
	buttons.add_child(end_turn)


func _build_city_panel() -> void:
	_city_panel = _styled_panel()
	_city_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_city_panel.offset_left = 8
	_city_panel.offset_top = -215
	_city_panel.offset_right = 400
	_city_panel.offset_bottom = 235
	_city_panel.visible = false
	_city_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_city_panel)

	var scroll := ScrollContainer.new()
	# Vertical only: the horizontal bar was clipping the yield line rather than
	# letting it wrap, so "Housing" and "Faith" ran off the edge.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_city_panel.add_child(scroll)

	_city_body = VBoxContainer.new()
	_city_body.add_theme_constant_override("separation", 5)
	_city_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_city_body)


func _build_toast() -> void:
	_toast = _label("", 14, ACCENT)
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_top = 46
	_toast.offset_left = -260
	_toast.offset_right = 260
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0
	add_child(_toast)


# -------------------------------------------------------------------------
# Refresh
# -------------------------------------------------------------------------

func refresh() -> void:
	var player: PlayerState = Game.get_player(_human_id)
	if player == null:
		return

	_refresh_yields(player)
	_refresh_research(player)
	if _open_city != null:
		_refresh_city()


func _refresh_yields(player: PlayerState) -> void:
	for child in _yield_bar.get_children():
		child.queue_free()

	var per_turn := player.yields_per_turn
	var upkeep := UnitSystem.maintenance_cost(Game, player)
	var net_gold := per_turn.get_kind(Yields.Kind.GOLD) - upkeep

	# Treasury totals show the stock; the rest show per-turn flow, which is what
	# actually drives decisions.
	_add_yield("Gold", "%d (%+d)" % [int(player.gold), int(round(net_gold))], Color(1.0, 0.85, 0.35))
	_add_yield("Faith", "%d (%+d)" % [
		int(player.faith), int(round(per_turn.get_kind(Yields.Kind.FAITH)))
	], Color(0.85, 0.80, 1.0))
	_add_yield("Science", "%+d" % int(round(per_turn.get_kind(Yields.Kind.SCIENCE))), Color(0.55, 0.80, 1.0))
	_add_yield("Culture", "%+d" % int(round(per_turn.get_kind(Yields.Kind.CULTURE))), Color(0.85, 0.60, 1.0))
	_add_yield("Envoys", str(player.envoys_available), Color(0.70, 0.90, 0.75))

	var leader := player.leader()
	_turn_label.text = "%s   %s Era   Turn %d / %d" % [
		leader.civilization if leader != null else "?",
		EmpireDefs.ERA_NAMES[player.era], Game.turn, Game.turn_limit,
	]


func _add_yield(name: String, value: String, color: Color) -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.add_child(_label(name, 12, TEXT_DIM))
	box.add_child(_label(value, 14, color))
	_yield_bar.add_child(box)


func _refresh_research(player: PlayerState) -> void:
	for child in _research_panel.get_children():
		child.queue_free()

	_research_panel.add_child(_label("RESEARCH", 11, TEXT_DIM))
	_add_research_row(player, &"tech")
	_research_panel.add_child(HSeparator.new())
	_research_panel.add_child(_label("CIVIC", 11, TEXT_DIM))
	_add_research_row(player, &"civic")


func _add_research_row(player: PlayerState, kind: StringName) -> void:
	var is_tech := kind == &"tech"
	var id := player.current_tech if is_tech else player.current_civic
	if id == &"":
		_research_panel.add_child(_label("—", 13, TEXT_DIM))
		return

	var node := ContentDB.get_tech(id) if is_tech else ContentDB.get_civic(id)
	if node == null:
		return

	var progress := player.tech_progress if is_tech else player.civic_progress
	var cost := player.node_cost(node, ResearchSystem.world_era(Game))
	var per_turn := player.yields_per_turn.get_kind(
		Yields.Kind.SCIENCE if is_tech else Yields.Kind.CULTURE
	)
	var turns := int(ceil((cost - progress) / per_turn)) if per_turn > 0.01 else -1

	_research_panel.add_child(_label(
		"%s   %s" % [node.name, "%d turns" % turns if turns > 0 else "—"], 13
	))

	var bar := ProgressBar.new()
	bar.max_value = cost
	bar.value = progress
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 6)
	_research_panel.add_child(bar)

	# The boost hint is the whole point of the tracker: it tells the player what
	# action would cut this research by 40%.
	if node.has_boost():
		var boosted := player.is_boosted(kind, node.id)
		_research_panel.add_child(_label(
			("Boosted!" if boosted else "To Boost: %s" % node.boost_text),
			11,
			ACCENT if boosted else TEXT_DIM,
		))


# -------------------------------------------------------------------------
# Unit panel
# -------------------------------------------------------------------------

func set_selected_unit(unit: UnitState) -> void:
	_selected_unit = unit
	for child in _action_bar.get_children():
		child.queue_free()

	if unit == null:
		_unit_title.text = "No unit selected"
		_unit_stats.text = "Click one of your units, or press Tab."
		return

	var def := unit.definition()
	_unit_title.text = def.name if def != null else "Unit"

	var lines: PackedStringArray = []
	lines.append("HP %d/100     Moves %.0f/%d" % [unit.hp, unit.movement_left, def.movement])
	if def.combat_strength > 0.0:
		var line := "Strength %d" % int(def.combat_strength)
		if def.is_ranged():
			line += "     Ranged %d (range %d)" % [int(def.ranged_strength), def.range]
		lines.append(line)
	if def.charges > 0:
		lines.append("Charges %d" % unit.charges)
	if unit.level > 1 or unit.pending_promotions > 0:
		lines.append("Level %d     XP %d%s" % [
			unit.level, unit.xp,
			"     PROMOTION AVAILABLE" if unit.pending_promotions > 0 else "",
		])
	if unit.is_fortified:
		lines.append("Fortified")
	_unit_stats.text = "\n".join(lines)

	_build_actions(unit, def)


func _build_actions(unit: UnitState, def: UnitDefs.UnitDef) -> void:
	if def.can_found_city:
		var found := _button("Found City (B)")
		var legal := UnitSystem.can_found_city_at(Game, Game.get_player(_human_id), unit.coord)
		found.disabled = not legal
		found.pressed.connect(func() -> void: action_requested.emit(&"found_city"))
		_action_bar.add_child(found)

	if def.can_build_improvements:
		var build := _button("Build")
		build.disabled = unit.charges <= 0 or unit.movement_left <= 0.0
		build.pressed.connect(func() -> void: action_requested.emit(&"build"))
		_action_bar.add_child(build)

	if def.is_military():
		var fortify := _button("Fortify (F)")
		fortify.pressed.connect(func() -> void: action_requested.emit(&"fortify"))
		_action_bar.add_child(fortify)

	var skip := _button("Skip")
	skip.pressed.connect(func() -> void: action_requested.emit(&"skip"))
	_action_bar.add_child(skip)


# -------------------------------------------------------------------------
# City panel
# -------------------------------------------------------------------------

func open_city(city: CityState) -> void:
	_open_city = city
	_city_panel.visible = true
	_refresh_city()


func close_city() -> void:
	_open_city = null
	_city_panel.visible = false


func _refresh_city() -> void:
	for child in _city_body.get_children():
		child.queue_free()

	var city := _open_city
	if city == null:
		return

	var header := HBoxContainer.new()
	header.add_child(_label(city.name, 17, ACCENT))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close := _button("X")
	close.custom_minimum_size = Vector2(26, 24)
	close.pressed.connect(close_city)
	header.add_child(close)
	_city_body.add_child(header)

	# The four numbers the reference HUD puts under a city banner.
	_city_body.add_child(_label(
		"Population %d     Loyalty %d     Districts %d/%d     Housing %d/%d" % [
			city.population, int(city.loyalty),
			city.specialty_district_count(), city.district_allowance(),
			city.population, int(city.housing),
		], 12, TEXT_DIM), true)

	var mood_names := ["Ecstatic", "Happy", "Content", "Displeased", "Unhappy", "In Revolt"]
	_city_body.add_child(_label(
		"Amenities %d/%d  (%s)" % [
			int(city.amenities), int(city.amenities_needed), mood_names[city.mood]
		], 12, TEXT_DIM))

	var y := city.yields
	_city_body.add_child(_label(
		"Food %+.1f   Prod %.1f   Gold %.1f   Sci %.1f   Cult %.1f   Faith %.1f" % [
			y.get_kind(Yields.Kind.FOOD) - city.food_consumption(),
			y.get_kind(Yields.Kind.PRODUCTION), y.get_kind(Yields.Kind.GOLD),
			y.get_kind(Yields.Kind.SCIENCE), y.get_kind(Yields.Kind.CULTURE),
			y.get_kind(Yields.Kind.FAITH),
		], 12, Color.WHITE, true))

	var growth := city.turns_until_growth()
	_city_body.add_child(_label(
		"Growth in %s" % ("%d turns" % growth if growth > 0 else "—"), 12, TEXT_DIM))

	_city_body.add_child(HSeparator.new())

	if city.production_item != &"":
		var turns := city.turns_until_production()
		_city_body.add_child(_label("Producing: %s   %s" % [
			_display_name(city.production_kind, city.production_item),
			"%d turns" % turns if turns > 0 else "—",
		], 13))
		var bar := ProgressBar.new()
		bar.max_value = city.production_cost()
		bar.value = city.production_progress
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 6)
		_city_body.add_child(bar)
	else:
		_city_body.add_child(_label("Choose production", 13, ACCENT))

	_city_body.add_child(HSeparator.new())
	_city_body.add_child(_label("PRODUCTION", 11, TEXT_DIM))

	# Grouped the way the reference production panel groups them.
	var options := CitySystem.available_production(Game, city)
	for group in [
		[CityState.ProductionKind.DISTRICT, "Districts"],
		[CityState.ProductionKind.BUILDING, "Buildings"],
		[CityState.ProductionKind.UNIT, "Units"],
		[CityState.ProductionKind.WONDER, "Wonders"],
	]:
		var kind: CityState.ProductionKind = group[0]
		var matching := options.filter(func(o: Dictionary) -> bool: return o["kind"] == kind)
		if matching.is_empty():
			continue
		_city_body.add_child(_label(group[1], 11, TEXT_DIM))
		for option: Dictionary in matching:
			_city_body.add_child(_production_button(city, option))


func _production_button(city: CityState, option: Dictionary) -> Button:
	var kind: CityState.ProductionKind = option["kind"]
	var item: StringName = option["id"]
	var cost := float(option["cost"])
	var per_turn := city.yields.get_kind(Yields.Kind.PRODUCTION)
	var turns := int(ceil(cost / per_turn)) if per_turn > 0.01 else -1

	var label := "%s   %s" % [
		_display_name(kind, item), "%d turns" % turns if turns > 0 else "%d prod" % int(cost)
	]

	# A district's whole value is where it goes, so show the adjacency the best
	# available site would deliver before committing.
	if kind == CityState.ProductionKind.DISTRICT:
		var district := ContentDB.get_district(item)
		var sites := Adjacency.rank_sites(
			Game.map, city, district, Game.get_player(_human_id), Game.modifiers
		)
		if not sites.is_empty() and float(sites[0]["adjacency"]) > 0.0:
			label += "   (+%d adjacency)" % int(sites[0]["adjacency"])

	var button := _button(label)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(func() -> void: _choose_production(city, kind, item))
	return button


func _choose_production(city: CityState, kind: CityState.ProductionKind, item: StringName) -> void:
	if kind == CityState.ProductionKind.DISTRICT:
		var district := ContentDB.get_district(item)
		var sites := Adjacency.rank_sites(
			Game.map, city, district, Game.get_player(_human_id), Game.modifiers
		)
		if sites.is_empty():
			notify("There is nowhere to put that district.")
			return
		city.production_queue = [sites[0]["coord"]]
	city.set_production(kind, item)
	_refresh_city()


func _display_name(kind: CityState.ProductionKind, item: StringName) -> String:
	var def: ContentDef = null
	match kind:
		CityState.ProductionKind.UNIT: def = ContentDB.get_unit(item)
		CityState.ProductionKind.BUILDING: def = ContentDB.get_building(item)
		CityState.ProductionKind.DISTRICT: def = ContentDB.get_district(item)
		CityState.ProductionKind.WONDER: def = ContentDB.wonders.get(item)
	return def.name if def != null else str(item)


# -------------------------------------------------------------------------
# Messages
# -------------------------------------------------------------------------

func notify(message: String) -> void:
	_toast.text = message
	_toast.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(1.6)
	tween.tween_property(_toast, "modulate:a", 0.0, 0.6)


func show_game_over(message: String) -> void:
	if _game_over != null:
		return
	_game_over = _styled_panel()
	_game_over.set_anchors_preset(Control.PRESET_CENTER)
	_game_over.offset_left = -260
	_game_over.offset_top = -70
	_game_over.offset_right = 260
	_game_over.offset_bottom = 70
	_game_over.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_game_over)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_game_over.add_child(column)

	var title := _label("Game Over", 22, ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var body := _label(message, 14)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(body)

	var quit := _button("Back to Menu")
	quit.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://ui/screens/main_menu.tscn"))
	column.add_child(quit)


func set_lens_active(on: bool) -> void:
	if _lens_button != null:
		_lens_button.button_pressed = on
