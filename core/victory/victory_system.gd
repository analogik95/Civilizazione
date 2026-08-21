class_name VictorySystem
extends RefCounted

## Victory conditions.
##
## Domination and Score are implemented here; the remaining four (Science,
## Culture, Religious, Diplomatic) each depend on systems still to be built and
## are stubbed with their real trigger conditions so wiring them up later is a
## matter of filling in the tracker rather than restructuring anything.

const VICTORY_DOMINATION := &"domination"
const VICTORY_SCORE := &"score"
const VICTORY_SCIENCE := &"science"
const VICTORY_CULTURE := &"culture"
const VICTORY_RELIGIOUS := &"religious"
const VICTORY_DIPLOMATIC := &"diplomatic"


static func check(game: Node) -> void:
	if game.is_finished():
		return
	if _check_domination(game):
		return
	if _check_last_standing(game):
		return


## Domination: hold every civilization's *original* capital. Note this tracks
## the original capital rather than the current one, so moving your seat of
## government after losing it does not save you.
static func _check_domination(game: Node) -> bool:
	var majors: Array = game.major_players()
	if majors.size() < 2:
		return false

	# Every original capital that exists in the game.
	var all_capitals := {}
	for player: PlayerState in game.players.values():
		if player.kind == PlayerState.Kind.MAJOR:
			all_capitals[player.id] = true

	for player: PlayerState in majors:
		var holds_all := true
		for capital_owner: Variant in all_capitals:
			if not player.original_capitals_held.has(capital_owner):
				holds_all = false
				break
		if holds_all:
			_declare(game, player.id, VICTORY_DOMINATION)
			return true
	return false


## The trivial case: everyone else has been eliminated.
static func _check_last_standing(game: Node) -> bool:
	var alive: Array = game.major_players()
	if alive.size() == 1 and game.players.values().size() > 1:
		_declare(game, alive[0].id, VICTORY_DOMINATION)
		return true
	return false


## Score victory at the turn limit. Weighted the way Civ 6 does: broad
## development rather than any single axis.
static func declare_score_victory(game: Node) -> void:
	var best_id := -1
	var best_score := -INF
	for player: PlayerState in game.major_players():
		var score := compute_score(game, player)
		if score > best_score:
			best_score = score
			best_id = player.id
	if best_id >= 0:
		_declare(game, best_id, VICTORY_SCORE)


static func compute_score(game: Node, player: PlayerState) -> float:
	var score := 0.0
	var cities: Array = game.cities_of(player.id)

	score += cities.size() * 10.0
	for city: CityState in cities:
		score += city.population * 4.0
		score += city.specialty_district_count() * 5.0
		score += city.buildings.size() * 2.0
		score += city.wonders.size() * 15.0

	score += player.techs.size() * 6.0
	score += player.civics.size() * 6.0
	score += player.era * 8.0
	score += player.era_score * 1.0
	score += player.suzerain_of.size() * 5.0
	return score


static func _declare(game: Node, winner_id: int, victory_type: StringName) -> void:
	game.phase = game.Phase.FINISHED
	game.winner_id = winner_id
	game.victory_type = victory_type
	EventBus.game_over.emit(winner_id, victory_type)


## Progress toward each victory, for the UI's victory screen and for the AI to
## judge how close a rival is.
static func progress_report(game: Node, player: PlayerState) -> Dictionary:
	var total_capitals := 0
	for other: PlayerState in game.players.values():
		if other.kind == PlayerState.Kind.MAJOR:
			total_capitals += 1

	return {
		VICTORY_DOMINATION: {
			"held": player.original_capitals_held.size(),
			"needed": total_capitals,
		},
		VICTORY_SCORE: {
			"score": compute_score(game, player),
			"turns_left": maxi(0, game.turn_limit - game.turn),
		},
	}
