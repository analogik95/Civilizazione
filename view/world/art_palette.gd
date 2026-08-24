class_name ArtPalette
extends RefCounted

## The single place that decides what a piece of game content looks like.
##
## Nothing in core/ knows about art, and no scene file hard-codes a mesh path —
## everything visual resolves through the tables here, so re-skinning the game
## means editing this file and nothing else.
##
## The art is Kenney's CC0 kits (see assets/art/CREDITS.md). Two facts about
## those meshes drive the constants below:
##
##  - They are modelled **pointy-top** at a circumradius of 1/sqrt(3), while
##    Hex.to_world lays out a **flat-top** grid. Rotating a hex by 30 degrees
##    converts one orientation into the other, which is what MESH_YAW is for.
##  - Scaling by sqrt(3) takes that circumradius to 1.0, so HEX_SIZE is a clean
##    1.0 world unit and every other measurement here is in tile radii.
##
## Terrain is drawn from a handful of base hexes plus a per-terrain tint rather
## than a unique mesh per terrain. That is both far cheaper and closer to Civ 6,
## whose terrain reads as flat colour fields with props scattered on top.

const HEX_SIZE := 1.0
const MESH_YAW := PI / 6.0
const MESH_SCALE := 1.7320508075688772  # sqrt(3)

const MODEL_ROOT := "res://assets/art/models"

## Height of the flat tile surface props sit on, in world units.
const SURFACE_Y := 0.2 * MESH_SCALE
const HILL_SURFACE_Y := 0.8 * MESH_SCALE
const WATER_SURFACE_Y := 0.1 * MESH_SCALE


# -------------------------------------------------------------------------
# Terrain
# -------------------------------------------------------------------------

## terrain_id -> [flat model, hills model]. Only Grassland and Stone ship a
## hills variant in the kit, so the rest borrow one and lean on the tint.
const TERRAIN_MODELS := {
	&"grassland": ["hex_grass", "hex_grass_hill"],
	&"plains": ["hex_dirt", "hex_grass_hill"],
	&"desert": ["hex_sand", "hex_stone_hill"],
	&"tundra": ["hex_stone", "hex_stone_hill"],
	&"snow": ["hex_stone", "hex_stone_hill"],
	&"mountains": ["hex_stone_mountain", "hex_stone_mountain"],
	&"coast": ["hex_water", "hex_water"],
	&"ocean": ["hex_water", "hex_water"],
	&"lake": ["hex_water", "hex_water"],
}

## Albedo multiplier per terrain.
##
## The kit's atlas already colours each mesh correctly — grass is green, sand is
## tan, water is blue — so most of these are white or near it. Tints exist to
## separate terrains that *share* a mesh (Tundra and Snow are both the stone
## hex; Coast, Ocean and Lake are all the water hex), not to recolour art that
## is already right. Saturated multipliers on top of a coloured texture go neon
## very fast, so they stay close to 1.0.
const TERRAIN_TINTS := {
	&"grassland": Color(1.00, 1.00, 1.00),
	&"plains": Color(1.00, 1.00, 1.00),
	&"desert": Color(1.00, 1.00, 1.00),
	&"tundra": Color(1.02, 1.00, 0.94),
	&"snow": Color(1.45, 1.48, 1.55),
	&"mountains": Color(1.00, 1.00, 1.00),
	&"coast": Color(0.92, 1.00, 1.06),
	&"ocean": Color(0.52, 0.66, 0.86),
	&"lake": Color(0.86, 0.98, 1.04),
}

## Hills borrow another terrain's mesh, so they need their own tint to stop a
## Desert hill reading as a Grassland one.
const HILL_TINTS := {
	&"plains": Color(0.96, 0.88, 0.66),
	&"desert": Color(1.12, 1.02, 0.76),
	&"tundra": Color(0.88, 0.92, 0.94),
	&"snow": Color(1.10, 1.13, 1.16),
}


# -------------------------------------------------------------------------
# Features — scattered as several props per tile
# -------------------------------------------------------------------------

## feature_id -> {models, count, scale, jitter}
##   count  how many props to scatter on the tile
##   scale  target height in world units, before per-instance variation
##   jitter how far from tile centre they may stray, in tile radii
const FEATURE_PROPS := {
	# Counts are high on purpose. Civ 6's forest tiles carry a dozen or more
	# well-grown trees packed nearly to the tile edge, and that density is a
	# large part of why its ground looks like landscape rather than like a board
	# with markers on it. Seven small trees in the middle of a bare hexagon
	# reads as decoration; fourteen reaching the edges reads as a wood.
	&"woods": {
		"models": ["tree_oak", "tree_default", "tree_tall", "tree_oak_dark"],
		"count": 15, "scale": 0.66, "jitter": 0.76,
	},
	&"rainforest": {
		"models": ["tree_palm_tall", "tree_palm_short", "tree_palm_bend", "bush_large"],
		"count": 14, "scale": 0.68, "jitter": 0.76,
	},
	&"marsh": {
		"models": ["bush", "grass_tuft", "mushroom"],
		"count": 11, "scale": 0.26, "jitter": 0.74,
	},
	&"floodplains": {
		"models": ["grass_tuft", "bush"],
		"count": 8, "scale": 0.22, "jitter": 0.72,
	},
	&"oasis": {
		"models": ["tree_palm_short", "tree_palm_bend", "bush"],
		"count": 3, "scale": 0.46, "jitter": 0.34,
	},
	&"reef": {
		"models": ["rock_small", "stone_flat"],
		"count": 4, "scale": 0.18, "jitter": 0.44,
	},
	&"ice": {
		"models": ["stone_flat", "rock_small"],
		"count": 3, "scale": 0.22, "jitter": 0.42,
	},
	&"geothermal_fissure": {
		"models": ["rock_tall", "rock_large"],
		"count": 2, "scale": 0.40, "jitter": 0.30,
	},
}

## Pine forests read differently from oak ones; cold terrain swaps the model
## list so a Tundra Woods tile does not look like a Grassland one.
const COLD_WOODS := ["tree_pine_a", "tree_pine_b", "tree_pine_small"]
const COLD_TERRAIN := [&"tundra", &"snow"]


# -------------------------------------------------------------------------
# Sculpted landforms
# -------------------------------------------------------------------------

## Mountains, hills and shoreline rock are Blender-authored (see
## tools/blender/build_terrain_props.py) rather than raised terrain hexes.
##
## Raising the ground makes a mountain the shape of the tile it stands on,
## which is exactly the hexagonal chess-piece look Civ 6 does not have. Its
## mountains are sculpted rock with irregular ridges and snow caps, sitting on
## ground that stays walkable. Several variants each, picked by coordinate, so
## a range does not read as one mesh stamped in a row.
const MOUNTAIN_MODELS := ["mtn_peak_a", "mtn_peak_b", "mtn_peak_c", "mtn_ridge_a", "mtn_ridge_b"]
const HILL_MODELS := ["hill_a", "hill_b"]
const SHORE_ROCK_MODELS := ["rock_shore_a", "rock_shore_b"]

const MOUNTAIN_SCALE := 1.95
const HILL_SCALE := 1.55
const SHORE_ROCK_SCALE := 0.42

## Chance a coastal land tile grows a rock formation.
## Shore rocks are punctuation, not ground cover. At a third of coastal tiles
## they read as scattered debris strewn over the grass rather than as an
## occasional outcrop at the waterline.
const SHORE_ROCK_CHANCE := 0.08


## Deterministic variant choice — the same tile must pick the same model every
## rebuild or the mountains rearrange themselves whenever anything redraws.
static func variant(models: Array, coord: Vector2i, salt: int = 0) -> String:
	var index := absi(hash(Vector2i(coord.x, coord.y)) ^ salt) % models.size()
	return models[index]


# -------------------------------------------------------------------------
# Resources
# -------------------------------------------------------------------------

## Thirty resources share twelve models, grouped by what they physically are.
## The map only needs to say "there is something valuable here" — the tooltip
## and the yield panel carry the specifics.
const RESOURCE_MODELS := {
	&"wheat": "res_wheat", &"rice": "res_bamboo", &"maize": "res_corn",
	&"cattle": "res_carrot", &"sheep": "res_carrot", &"deer": "res_mushroom_tan",
	&"stone": "res_stone_pile", &"copper": "res_rock_pile",
	&"fish": "res_flower_purple", &"crabs": "res_flower_purple",
	&"wine": "res_flower_purple", &"incense": "res_flower_yellow",
	&"silk": "res_flower_purple", &"dyes": "res_flower_red",
	&"cotton": "res_flower_yellow", &"sugar": "res_bamboo",
	&"furs": "res_mushroom_tan", &"ivory": "res_stone_pile",
	&"silver": "res_rock_pile", &"gems": "res_rock_pile",
	&"marble": "res_stone_pile", &"salt": "res_stone_pile",
	&"pearls": "res_flower_purple", &"citrus": "res_melon",
	&"cocoa": "res_pumpkin", &"jade": "res_rock_pile",
	&"horses": "res_carrot", &"iron": "res_rock_pile",
	&"niter": "res_stone_pile", &"coal": "res_rock_pile",
}

const RESOURCE_SCALE := 0.30


# -------------------------------------------------------------------------
# Improvements and districts
# -------------------------------------------------------------------------

const IMPROVEMENT_MODELS := {
	&"farm": "imp_farm", &"mine": "imp_mine", &"quarry": "imp_quarry",
	&"pasture": "imp_pasture", &"camp": "imp_camp",
	&"plantation": "imp_plantation", &"fishing_boats": "imp_fishing_boats",
}

const IMPROVEMENT_SCALE := 0.46

const DISTRICT_MODELS := {
	&"city_center": "dis_city_center", &"campus": "dis_campus",
	&"holy_site": "dis_holy_site", &"commercial_hub": "dis_commercial_hub",
	&"harbor": "dis_harbor", &"theater_square": "dis_theater_square",
	&"encampment": "dis_encampment", &"industrial_zone": "dis_industrial_zone",
	&"aqueduct": "dis_aqueduct", &"entertainment_complex": "dis_entertainment",
	&"government_plaza": "dis_government_plaza",
}

const DISTRICT_SCALE := 0.72


# -------------------------------------------------------------------------
# Units
# -------------------------------------------------------------------------

const UNIT_MODELS := {
	&"settler": "unit_settler", &"builder": "unit_builder", &"trader": "unit_trader",
	&"warrior": "unit_warrior", &"scout": "unit_scout", &"slinger": "unit_slinger",
	&"archer": "unit_archer", &"spearman": "unit_spearman",
	&"heavy_chariot": "unit_heavy_chariot", &"horseman": "unit_horseman",
	&"swordsman": "unit_swordsman", &"catapult": "unit_catapult",
	&"galley": "unit_galley", &"pikeman": "unit_pikeman",
	&"crossbowman": "unit_crossbowman", &"musketman": "unit_musketman",
}

const UNIT_FALLBACK := "unit_warrior"
const UNIT_SCALE := 0.52


# -------------------------------------------------------------------------
# City centre
# -------------------------------------------------------------------------

## A city grows visibly: more and larger buildings as population rises.
const CITY_BUILDINGS := ["city_house_small", "city_house_large", "city_mill", "city_tower"]
const CITY_KEEP := "city_keep"
const CITY_BANNER := "city_banner"
const CITY_WALL := "city_wall"
const CITY_WALL_TOWER := "city_wall_tower"
const CITY_BUILDING_SCALE := 0.30


# -------------------------------------------------------------------------
# Lookup helpers
# -------------------------------------------------------------------------

static func model_path(group: String, stem: String) -> String:
	return "%s/%s/%s.glb" % [MODEL_ROOT, group, stem]


static func terrain_model(tile: Tile) -> String:
	var pair: Variant = TERRAIN_MODELS.get(tile.terrain_id)
	if pair == null:
		return "hex_grass"
	return pair[1] if tile.is_hills else pair[0]


static func terrain_tint(tile: Tile) -> Color:
	if tile.is_hills and HILL_TINTS.has(tile.terrain_id):
		return HILL_TINTS[tile.terrain_id]
	return TERRAIN_TINTS.get(tile.terrain_id, Color.WHITE)


## Vertical squash applied to a terrain mesh.
##
## The kit's mountain is a tall spire, drawn for a game where mountains are the
## point. Here a tile is two units across and mountains are one terrain among
## nine, so at full height they read as skyscrapers and hide everything behind
## them. Flattening them keeps the silhouette without letting it dominate.
const TERRAIN_HEIGHT_SCALES := {
	&"mountains": 0.52,
}


static func terrain_height_scale(tile: Tile) -> float:
	return TERRAIN_HEIGHT_SCALES.get(tile.terrain_id, 1.0)


## Height of the walkable surface, which props and units stand on.
static func surface_height(tile: Tile) -> float:
	if tile.is_water():
		return WATER_SURFACE_Y
	if tile.terrain_id == &"mountains":
		return 1.09 * MESH_SCALE * TERRAIN_HEIGHT_SCALES[&"mountains"]
	return HILL_SURFACE_Y if tile.is_hills else SURFACE_Y


## Scatter for tiles carrying no feature at all.
##
## Bare terrain in Civ 6 is never bare: grassland has tufts and the odd shrub,
## desert has stones and dead scrub, tundra has boulders. Without it every
## unforested tile here was an empty painted plane, which is most of what made
## the map look unfinished next to the real thing. Kept small and low-contrast
## so it dresses the ground without competing with anything a player has built.
const GROUND_COVER := {
	&"grassland": {
		"models": ["grass_tuft", "bush", "stone_flat"],
		"count": 5, "scale": 0.17, "jitter": 0.74,
	},
	&"plains": {
		"models": ["grass_tuft", "bush", "rock_small"],
		"count": 4, "scale": 0.16, "jitter": 0.74,
	},
	&"desert": {
		"models": ["rock_small", "stone_flat", "cactus_short"],
		"count": 3, "scale": 0.17, "jitter": 0.72,
	},
	&"tundra": {
		"models": ["rock_small", "stone_flat", "grass_tuft"],
		"count": 3, "scale": 0.18, "jitter": 0.72,
	},
	&"snow": {
		"models": ["stone_flat", "rock_small"],
		"count": 2, "scale": 0.16, "jitter": 0.70,
	},
}


## Dressing for a tile that has no feature of its own, or an empty dictionary
## when the tile is water, mountain, or already carrying something.
static func ground_cover(tile: Tile) -> Dictionary:
	if tile.feature_id != &"" or not tile.is_land():
		return {}
	if tile.terrain_id == &"mountains":
		return {}
	return GROUND_COVER.get(tile.terrain_id, {})


static func feature_props(tile: Tile) -> Dictionary:
	var spec: Variant = FEATURE_PROPS.get(tile.feature_id)
	if spec == null:
		return {}
	if tile.feature_id == &"woods" and COLD_TERRAIN.has(tile.terrain_id):
		var cold: Dictionary = (spec as Dictionary).duplicate()
		cold["models"] = COLD_WOODS
		return cold
	return spec


static func resource_model(resource_id: StringName) -> String:
	return RESOURCE_MODELS.get(resource_id, "res_stone_pile")


static func improvement_model(improvement_id: StringName) -> String:
	return IMPROVEMENT_MODELS.get(improvement_id, "")


static func district_model(district_id: StringName) -> String:
	return DISTRICT_MODELS.get(district_id, "dis_city_center")


static func unit_model(unit_id: StringName) -> String:
	return UNIT_MODELS.get(unit_id, UNIT_FALLBACK)


## World position of a tile's surface centre.
static func tile_position(tile: Tile) -> Vector3:
	var pos := Hex.to_world(tile.coord, HEX_SIZE)
	pos.y = surface_height(tile)
	return pos


## The look of the world: sky, ambient, tonemap.
##
## One source of truth, called by both the game scene and the screenshot runner.
## They used to be configured separately, which meant every screenshot was lit
## differently from the game it was supposed to be showing.
static func build_environment() -> Environment:
	var environment := Environment.new()

	# A sky rather than a flat colour. It is barely visible behind the map, but
	# it is what the ambient term is sampled from, so ground facing up picks up
	# skylight and ground facing sideways does not — most of the reason a hill
	# reads as a hill before its shadow is drawn.
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.30, 0.50, 0.76)
	sky_material.sky_horizon_color = Color(0.70, 0.79, 0.87)
	sky_material.ground_horizon_color = Color(0.70, 0.79, 0.87)
	sky_material.ground_bottom_color = Color(0.42, 0.41, 0.37)
	sky_material.sun_angle_max = 24.0
	sky_material.sun_curve = 0.18

	var sky := Sky.new()
	sky.sky_material = sky_material

	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	# An explicit colour, not the sky. Compatibility approximates sky ambient and
	# in practice ignored the energy set here entirely — lowering it changed
	# nothing measurable, which is how the shadows stayed washed out through
	# several rounds of tuning. A flat ambient colour it does honour.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.42, 0.47, 0.58)
	# Measured rather than guessed. Sampling a land region of a Civ 6 screenshot
	# gives a 5th-percentile luminance around 50 against a median of 140 — its
	# shadows are dark but its shadowed ground is still recognisably ground. The
	# same measurement here read 131 against 198 with ambient too high, and
	# crushed to black when it went too low. This is the value that lands on it.
	environment.ambient_light_energy = 0.17

	# Slight aerial perspective, so distance reads. Heavier than this and the
	# far side of a continent turns to milk.
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.60, 0.70, 0.83)
	environment.fog_density = 0.0006

	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 0.70
	environment.tonemap_white = 3.0

	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.18
	environment.adjustment_contrast = 1.10
	return environment


## The sun. Also shared, for the same reason.
##
## High and warm, with a shadow map tight enough that a tree and a unit both
## cast something you can see. Civ 6's ground reads as 3D mostly because of
## these shadows: without them a rolling landscape is just a colour gradient.
static func configure_sun(sun: DirectionalLight3D) -> void:
	sun.rotation_degrees = Vector3(-52.0, -42.0, 0.0)
	sun.light_color = Color(1.0, 0.96, 0.87)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	# Small bias on purpose. The defaults push a shadow far enough off its caster
	# that a tree's shadow lands outside the tree and disappears, which left the
	# ground looking unlit even with shadows switched on.
	sun.shadow_bias = 0.02
	sun.shadow_normal_bias = 0.6
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_split_1 = 0.05
	sun.directional_shadow_split_2 = 0.16
	sun.directional_shadow_split_3 = 0.42
	# Short, so the near splits stay high-resolution over the ground the player
	# is actually looking at rather than being spread over the whole continent.
	sun.directional_shadow_max_distance = 62.0
