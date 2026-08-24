extends Node

## Signal hub decoupling the simulation from the view and UI.
##
## The rule this enforces: core/ emits, view/ and ui/ listen. Nothing in core/
## ever holds a reference to a scene node, which is what lets the whole
## simulation run headless for AI-vs-AI soak testing.
##
## The modifier engine also listens here to invalidate its caches — see
## core/modifiers/modifier_engine.gd for which signals dirty which caches.

# --- Turn flow ---
signal turn_started(turn: int)
signal turn_ended(turn: int)
signal player_turn_started(player_id: int)
signal player_turn_ended(player_id: int)
signal game_over(winner_id: int, victory_type: StringName)

# --- Map ---
signal map_generated()
signal tile_changed(coord: Vector2i)
signal tile_ownership_changed(coord: Vector2i, owner_id: int)
signal tile_visibility_changed(player_id: int, coord: Vector2i)

# --- Cities ---
signal city_founded(city_id: int)
signal city_captured(city_id: int, old_owner: int, new_owner: int)
signal city_population_changed(city_id: int, population: int)
signal city_production_completed(city_id: int, item_kind: StringName, item_id: StringName)
signal district_built(city_id: int, coord: Vector2i, district_id: StringName)
signal building_built(city_id: int, building_id: StringName)

# --- Units ---
signal unit_created(unit_id: int)
signal unit_moved(unit_id: int, from: Vector2i, to: Vector2i)
signal unit_killed(unit_id: int, killer_id: int)
signal unit_promoted(unit_id: int, promotion_id: StringName)
signal combat_resolved(attacker_id: int, defender_id: int, attacker_damage: int, defender_damage: int)

# --- Empire ---
signal tech_researched(player_id: int, tech_id: StringName)
signal civic_researched(player_id: int, civic_id: StringName)
signal boost_triggered(player_id: int, kind: StringName, node_id: StringName)
signal era_changed(player_id: int, era: int)
signal government_changed(player_id: int, government_id: StringName)
signal policies_changed(player_id: int)

# --- Diplomacy / city-states ---
signal envoy_sent(player_id: int, city_state_id: int, total: int)
signal suzerain_changed(city_state_id: int, old_suzerain: int, new_suzerain: int)
signal war_declared(aggressor_id: int, target_id: int, war_type: StringName)
signal peace_made(a_id: int, b_id: int)

# --- Notifications for the player ---
signal notification_posted(player_id: int, kind: StringName, text: String, coord: Vector2i)
