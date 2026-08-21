class_name MapModel
extends RefCounted

## The world: a rectangular field of hex tiles, addressed by axial coordinate.
##
## Storage is a Dictionary keyed by axial Vector2i. The rectangle itself is
## defined in odd-q offset space (column, row) because that is what makes a map
## "80 wide by 50 tall" mean something; conversions live here so the rest of the
## simulation only ever deals in axial.
##
## Maps wrap east-west like a globe but not north-south, so `wrap_x` folds the
## column back around while row stays clamped.

var width: int = 0
var height: int = 0
var wrap_x: bool = true

## Vector2i(axial) -> Tile
var tiles: Dictionary = {}

## Continent id -> array of axial coords.
var continents: Dictionary = {}

## player_id -> {axial: true} for tiles ever seen (explored) and currently
## visible. Explored controls the parchment fog; visible controls whether units
## and cities on the tile are drawn and targetable.
var explored: Dictionary = {}
var visible: Dictionary = {}

const CITY_WORK_RADIUS := 3


# -------------------------------------------------------------------------
# Coordinate conversion (odd-q offset <-> axial)
# -------------------------------------------------------------------------

static func offset_to_axial(col: int, row: int) -> Vector2i:
	return Vector2i(col, row - int((col - (col & 1)) / 2.0))


static func axial_to_offset(coord: Vector2i) -> Vector2i:
	return Vector2i(coord.x, coord.y + int((coord.x - (coord.x & 1)) / 2.0))


func setup(p_width: int, p_height: int, p_wrap_x: bool = true) -> void:
	width = p_width
	height = p_height
	wrap_x = p_wrap_x
	tiles.clear()
	for col in width:
		for row in height:
			var coord := offset_to_axial(col, row)
			tiles[coord] = Tile.new(coord)


## Fold an out-of-bounds coordinate back onto the map, or return a sentinel when
## it falls off the poles. Every neighbour lookup goes through here.
func normalize(coord: Vector2i) -> Vector2i:
	var off := axial_to_offset(coord)
	if off.y < 0 or off.y >= height:
		return Vector2i(-9999, -9999)
	if wrap_x:
		off.x = posmod(off.x, width)
	elif off.x < 0 or off.x >= width:
		return Vector2i(-9999, -9999)
	return offset_to_axial(off.x, off.y)


func has_tile(coord: Vector2i) -> bool:
	return tiles.has(normalize(coord))


func get_tile(coord: Vector2i) -> Tile:
	return tiles.get(normalize(coord))


func all_tiles() -> Array:
	return tiles.values()


## In-bounds neighbours only. Tiles at the poles have fewer than six.
func neighbors(coord: Vector2i) -> Array[Tile]:
	var out: Array[Tile] = []
	for direction in Hex.DIRECTION_COUNT:
		var t := get_tile(Hex.neighbor(coord, direction))
		if t != null:
			out.append(t)
	return out


func neighbor_in(coord: Vector2i, direction: int) -> Tile:
	return get_tile(Hex.neighbor(coord, direction))


## Distance accounting for east-west wrap, so two tiles either side of the
## seam are correctly adjacent rather than a map-width apart.
func distance(a: Vector2i, b: Vector2i) -> int:
	var direct := Hex.distance(a, b)
	if not wrap_x:
		return direct
	var shifted := b + offset_to_axial(width, 0) - offset_to_axial(0, 0)
	var wrapped := mini(Hex.distance(a, shifted), Hex.distance(a, b - (shifted - b)))
	return mini(direct, wrapped)


func tiles_within(center: Vector2i, radius: int) -> Array[Tile]:
	var out: Array[Tile] = []
	for coord in Hex.within_radius(center, radius):
		var t := get_tile(coord)
		if t != null:
			out.append(t)
	return out


# -------------------------------------------------------------------------
# Rivers
# -------------------------------------------------------------------------

## Rivers live on the edge between two tiles, so recording one has to update
## both sides or adjacency and fresh-water checks disagree depending on which
## tile you ask.
func set_river(coord: Vector2i, direction: int, present: bool = true) -> void:
	var a := get_tile(coord)
	var b := neighbor_in(coord, direction)
	if a == null or b == null:
		return
	a.set_river_on(direction, present)
	b.set_river_on(Hex.OPPOSITE[direction], present)


## Fresh water reaches a tile from an adjacent river, lake or oasis. It is the
## difference between a city starting at 3 Housing and one starting at 2.
func has_fresh_water(coord: Vector2i) -> bool:
	var tile := get_tile(coord)
	if tile == null:
		return false
	if tile.has_river() or tile.feature_id == &"oasis":
		return true
	for n in neighbors(coord):
		if n.terrain_id == &"lake" or n.feature_id == &"oasis":
			return true
	return false


func is_coastal(coord: Vector2i) -> bool:
	for n in neighbors(coord):
		if n.terrain_id == &"coast":
			return true
	return false


# -------------------------------------------------------------------------
# Appeal
# -------------------------------------------------------------------------

## Recompute Appeal for one tile from its own features plus its neighbours.
##
## Appeal drives Neighbourhood Housing, National Park eligibility and several
## civ bonuses. The modifier list mirrors Civ 6's: mountains and natural wonders
## lift it, industry and extraction sink it.
func recompute_appeal(coord: Vector2i) -> void:
	var tile := get_tile(coord)
	if tile == null:
		return

	var total := tile.self_appeal()

	for n in neighbors(coord):
		if n.natural_wonder_id != &"":
			total += 2
		if n.terrain_id == &"mountains" or n.terrain_id == &"coast":
			total += 1
		if n.feature_id == &"woods" or n.feature_id == &"oasis":
			total += 1
		if n.feature_id in [&"rainforest", &"marsh", &"floodplains"]:
			total -= 1
		if n.is_pillaged:
			total -= 1
		if n.improvement_id in [&"mine", &"quarry", &"oil_well"]:
			total -= 1
		if n.has_district():
			# Cultural and religious districts beautify; industry and military
			# do the opposite.
			if n.district_id in [&"holy_site", &"theater_square", &"entertainment_complex"]:
				total += 1
			elif n.district_id in [&"industrial_zone", &"encampment", &"aerodrome", &"spaceport"]:
				total -= 1
		if n.wonder_id != &"":
			total += 1

	tile.appeal = total


func recompute_appeal_around(coord: Vector2i, radius: int = 1) -> void:
	for t in tiles_within(coord, radius):
		recompute_appeal(t.coord)


func recompute_all_appeal() -> void:
	for coord: Vector2i in tiles:
		recompute_appeal(coord)


## The five named Appeal bands Civ 6 shows in the UI.
static func appeal_tier(appeal: int) -> StringName:
	if appeal >= 4:
		return &"breathtaking"
	if appeal >= 2:
		return &"charming"
	if appeal >= -1:
		return &"average"
	if appeal >= -3:
		return &"uninviting"
	return &"disgusting"


# -------------------------------------------------------------------------
# Visibility
# -------------------------------------------------------------------------

func is_explored(player_id: int, coord: Vector2i) -> bool:
	var set: Dictionary = explored.get(player_id, {})
	return set.has(normalize(coord))


func is_visible(player_id: int, coord: Vector2i) -> bool:
	var set: Dictionary = visible.get(player_id, {})
	return set.has(normalize(coord))


func reveal(player_id: int, coord: Vector2i) -> void:
	var norm := normalize(coord)
	if not tiles.has(norm):
		return
	var seen: Dictionary = explored.get_or_add(player_id, {})
	var now: Dictionary = visible.get_or_add(player_id, {})
	var was_new := not seen.has(norm)
	seen[norm] = true
	now[norm] = true
	if was_new:
		EventBus.tile_visibility_changed.emit(player_id, norm)


func clear_visibility(player_id: int) -> void:
	visible[player_id] = {}


## Reveal everything within `radius` of a point — a unit's sight, or a city's.
func reveal_around(player_id: int, coord: Vector2i, radius: int) -> void:
	for t in tiles_within(coord, radius):
		reveal(player_id, t.coord)


# -------------------------------------------------------------------------
# Serialisation
# -------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var tile_list: Array = []
	for t: Tile in tiles.values():
		tile_list.append(t.to_dict())
	var explored_out := {}
	for player_id: Variant in explored:
		var coords: Array = []
		for c: Vector2i in explored[player_id]:
			coords.append([c.x, c.y])
		explored_out[str(player_id)] = coords
	return {
		"width": width, "height": height, "wrap_x": wrap_x,
		"tiles": tile_list, "explored": explored_out,
	}


static func from_dict(d: Dictionary) -> MapModel:
	var m := MapModel.new()
	m.width = int(d.get("width", 0))
	m.height = int(d.get("height", 0))
	m.wrap_x = bool(d.get("wrap_x", true))
	for tile_data: Variant in d.get("tiles", []):
		var t := Tile.from_dict(tile_data)
		m.tiles[t.coord] = t
	for player_key: Variant in d.get("explored", {}):
		var set := {}
		for c: Variant in d["explored"][player_key]:
			set[Vector2i(int(c[0]), int(c[1]))] = true
		m.explored[int(str(player_key))] = set
	return m
