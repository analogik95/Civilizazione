#!/usr/bin/env python3
"""Copies the CC0 art this project uses out of the downloaded Kenney packs.

The packs themselves are not vendored — they are large and mostly unused. This
script takes the specific models and sprites the game references and lays them
out under assets/art/ with the names the view layer expects, so an asset can be
swapped by changing one line here rather than by hunting through scene files.

    tools/setup_assets.sh          # downloads the packs, then runs this

Every pack below is Creative Commons Zero. See assets/art/CREDITS.md.
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

# pack directory name -> subdirectory holding the .glb files. Kenney is not
# consistent about naming this between packs, hence the table.
GLB_DIRS = {
    "hexagon-kit": "Models/GLB format",
    "nature-kit": "Models/GLTF format",
    "castle-kit": "Models/GLB format",
    "fantasy-town-kit": "Models/GLB format",
    "graveyard-kit": "Models/GLB format",
    "blocky-characters": "Models/GLB format",
}

# destination stem -> (pack, source stem)
#
# Terrain uses a handful of base hexes that the view layer tints per terrain
# type, which is both closer to Civ 6's flat colour treatment and far cheaper
# than a unique mesh per terrain.
TERRAIN = {
    "hex_grass": ("hexagon-kit", "grass"),
    "hex_grass_hill": ("hexagon-kit", "grass-hill"),
    "hex_grass_forest": ("hexagon-kit", "grass-forest"),
    "hex_dirt": ("hexagon-kit", "dirt"),
    "hex_dirt_lumber": ("hexagon-kit", "dirt-lumber"),
    "hex_sand": ("hexagon-kit", "sand"),
    "hex_sand_desert": ("hexagon-kit", "sand-desert"),
    "hex_sand_rocks": ("hexagon-kit", "sand-rocks"),
    "hex_stone": ("hexagon-kit", "stone"),
    "hex_stone_hill": ("hexagon-kit", "stone-hill"),
    "hex_stone_mountain": ("hexagon-kit", "stone-mountain"),
    "hex_stone_rocks": ("hexagon-kit", "stone-rocks"),
    "hex_water": ("hexagon-kit", "water"),
    "hex_water_rocks": ("hexagon-kit", "water-rocks"),
    "hex_water_island": ("hexagon-kit", "water-island"),
}

# Features are scattered as props on top of the base hex.
FEATURES = {
    "tree_oak": ("nature-kit", "tree_oak"),
    "tree_oak_dark": ("nature-kit", "tree_oak_dark"),
    "tree_default": ("nature-kit", "tree_default"),
    "tree_tall": ("nature-kit", "tree_tall"),
    "tree_pine_a": ("nature-kit", "tree_pineTallA"),
    "tree_pine_b": ("nature-kit", "tree_pineRoundC"),
    "tree_pine_small": ("nature-kit", "tree_pineSmallA"),
    "tree_palm_tall": ("nature-kit", "tree_palmDetailedTall"),
    "tree_palm_short": ("nature-kit", "tree_palmDetailedShort"),
    "tree_palm_bend": ("nature-kit", "tree_palmBend"),
    "bush": ("nature-kit", "plant_bushDetailed"),
    "bush_large": ("nature-kit", "plant_bushLarge"),
    "grass_tuft": ("nature-kit", "grass_leafs"),
    "cactus_tall": ("nature-kit", "cactus_tall"),
    "cactus_short": ("nature-kit", "cactus_short"),
    "rock_large": ("nature-kit", "rock_largeA"),
    "rock_small": ("nature-kit", "rock_smallA"),
    "rock_tall": ("nature-kit", "rock_tallC"),
    "stone_large": ("nature-kit", "stone_largeC"),
    "stone_flat": ("nature-kit", "stone_smallFlatA"),
    "mushroom": ("nature-kit", "mushroom_redGroup"),
    "log_stack": ("nature-kit", "log_stack"),
}

# Resource icons on the map.
RESOURCES = {
    "res_wheat": ("nature-kit", "crops_wheatStageB"),
    "res_corn": ("nature-kit", "crops_cornStageC"),
    "res_bamboo": ("nature-kit", "crops_bambooStageB"),
    "res_melon": ("nature-kit", "crop_melon"),
    "res_pumpkin": ("nature-kit", "crop_pumpkin"),
    "res_carrot": ("nature-kit", "crop_carrot"),
    "res_flower_purple": ("nature-kit", "flower_purpleB"),
    "res_flower_red": ("nature-kit", "flower_redB"),
    "res_flower_yellow": ("nature-kit", "flower_yellowB"),
    "res_mushroom_tan": ("nature-kit", "mushroom_tanGroup"),
    "res_stone_pile": ("nature-kit", "stone_smallB"),
    "res_rock_pile": ("nature-kit", "rock_smallD"),
}

# Improvements built by Builders.
IMPROVEMENTS = {
    "imp_farm": ("nature-kit", "crops_dirtDoubleRow"),
    "imp_farm_crop": ("nature-kit", "crops_wheatStageA"),
    "imp_mine": ("hexagon-kit", "building-mine"),
    "imp_quarry": ("hexagon-kit", "building-smelter"),
    "imp_pasture": ("hexagon-kit", "building-sheep"),
    "imp_camp": ("nature-kit", "campfire_logs"),
    "imp_plantation": ("nature-kit", "crops_leafsStageB"),
    "imp_fishing_boats": ("hexagon-kit", "building-dock"),
}

# One signature model per district.
DISTRICTS = {
    "dis_city_center": ("hexagon-kit", "building-village"),
    "dis_campus": ("hexagon-kit", "building-wizard-tower"),
    "dis_holy_site": ("graveyard-kit", "pillar-obelisk"),
    "dis_holy_altar": ("graveyard-kit", "altar-stone"),
    "dis_commercial_hub": ("hexagon-kit", "building-market"),
    "dis_harbor": ("hexagon-kit", "building-port"),
    "dis_theater_square": ("fantasy-town-kit", "fountain-round-detail"),
    "dis_encampment": ("hexagon-kit", "building-archery"),
    "dis_industrial_zone": ("hexagon-kit", "building-smelter"),
    "dis_aqueduct": ("hexagon-kit", "building-watermill"),
    "dis_entertainment": ("fantasy-town-kit", "fountain-square-detail"),
    "dis_government_plaza": ("hexagon-kit", "building-castle"),
}

# City centre grows through these as population rises, plus walls.
CITY = {
    "city_house_small": ("hexagon-kit", "unit-house"),
    "city_house_large": ("hexagon-kit", "unit-mansion"),
    "city_tower": ("hexagon-kit", "unit-tower"),
    "city_mill": ("hexagon-kit", "unit-mill"),
    "city_wall": ("castle-kit", "wall"),
    "city_wall_corner": ("castle-kit", "wall-corner"),
    "city_wall_gate": ("castle-kit", "wall-narrow-gate"),
    "city_wall_tower": ("hexagon-kit", "unit-wall-tower"),
    "city_keep": ("hexagon-kit", "building-tower"),
    "city_banner": ("castle-kit", "flag-wide"),
}

# Units. Characters carry the civ's colour; siege and ships are distinct models
# because a humanoid meeple reads badly for them.
UNITS = {
    "unit_settler": ("blocky-characters", "character-a"),
    "unit_builder": ("blocky-characters", "character-b"),
    "unit_trader": ("blocky-characters", "character-c"),
    "unit_warrior": ("blocky-characters", "character-d"),
    "unit_scout": ("blocky-characters", "character-e"),
    "unit_slinger": ("blocky-characters", "character-f"),
    "unit_archer": ("blocky-characters", "character-g"),
    "unit_spearman": ("blocky-characters", "character-h"),
    "unit_heavy_chariot": ("blocky-characters", "character-i"),
    "unit_horseman": ("blocky-characters", "character-j"),
    "unit_swordsman": ("blocky-characters", "character-k"),
    "unit_pikeman": ("blocky-characters", "character-l"),
    "unit_crossbowman": ("blocky-characters", "character-m"),
    "unit_musketman": ("blocky-characters", "character-n"),
    "unit_barbarian": ("blocky-characters", "character-o"),
    "unit_catapult": ("castle-kit", "siege-catapult"),
    "unit_trebuchet": ("castle-kit", "siege-trebuchet"),
    "unit_ram": ("castle-kit", "siege-ram"),
    "unit_galley": ("hexagon-kit", "unit-ship"),
    "unit_ship_large": ("hexagon-kit", "unit-ship-large"),
    "unit_cart": ("fantasy-town-kit", "cart"),
}

# Per-pack name for the shared palette atlas. Each must be exactly as long as
# "colormap.png" so the URI inside a .glb can be patched byte-for-byte — see
# _copy_glb_with_textures.
ATLAS_NAMES = {
    "hexagon-kit": "colorhex.png",
    "nature-kit": "colornat.png",
    "castle-kit": "colorcas.png",
    "fantasy-town-kit": "colorfan.png",
    "graveyard-kit": "colorgra.png",
    "blocky-characters": "colorblo.png",
}
assert all(len(n) == len("colormap.png") for n in ATLAS_NAMES.values())

GROUPS = {
    "terrain": TERRAIN,
    "features": FEATURES,
    "resources": RESOURCES,
    "improvements": IMPROVEMENTS,
    "districts": DISTRICTS,
    "city": CITY,
    "units": UNITS,
}


TEXTURE_URI = re.compile(rb'"uri"\s*:\s*"([^"]+\.png)"')


def copy_models(packs: Path, out_root: Path) -> tuple[int, list[str]]:
    copied = 0
    missing: list[str] = []
    for group, table in GROUPS.items():
        dest_dir = out_root / "models" / group
        dest_dir.mkdir(parents=True, exist_ok=True)

        for dest_stem, (pack, src_stem) in table.items():
            src = packs / pack / GLB_DIRS[pack] / f"{src_stem}.glb"
            if not src.exists():
                missing.append(f"{pack}:{src_stem}")
                continue
            _copy_glb_with_textures(src, dest_dir / f"{dest_stem}.glb", pack)
            copied += 1
    return copied, missing


def _copy_glb_with_textures(src: Path, dest: Path, pack: str) -> None:
    """Copy a .glb along with whatever external texture it references.

    Kenney splits three ways. Most packs UV-map every model onto one shared
    palette atlas named "Textures/colormap.png"; Blocky Characters gives each
    figure its own "Textures/texture-x.png"; Nature Kit uses vertex colours and
    references nothing. All three render as untextured grey if the referenced
    file is not copied alongside.

    The shared atlases collide: several packs ship a different colormap.png, and
    one destination group can draw from several packs. So a colormap is renamed
    to the pack's entry in ATLAS_NAMES and the URI inside the .glb is repointed
    to match. Every one of those names is exactly as long as "colormap.png", so
    the patch is a byte-for-byte swap that leaves the glTF JSON valid and every
    chunk length in the binary container correct — which a longer or shorter
    name would not.
    """
    data = src.read_bytes()
    texture_dir = dest.parent / "Textures"

    for match in TEXTURE_URI.finditer(data):
        uri = match.group(1).decode()
        source_texture = (src.parent / uri).resolve()
        if not source_texture.exists():
            continue

        if source_texture.name == "colormap.png":
            out_name = ATLAS_NAMES[pack]
            old = b'"' + uri.encode() + b'"'
            new = b'"Textures/' + out_name.encode() + b'"'
            assert len(new) == len(old), f"atlas name must match length: {out_name}"
            data = data.replace(old, new)
        else:
            out_name = source_texture.name

        texture_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_texture, texture_dir / out_name)

    dest.write_bytes(data)


# UI sprites: the 9-slice pieces the theme is built from, plus the icon sheets
# the HUD draws yields and actions from.
UI_SPRITES = [
    ("ui-pack", "PNG/Blue/Default/button_rectangle_depth_flat.png", "button_normal.png"),
    ("ui-pack", "PNG/Blue/Default/button_rectangle_depth_gloss.png", "button_hover.png"),
    ("ui-pack", "PNG/Blue/Default/button_rectangle_flat.png", "button_pressed.png"),
    ("ui-pack", "PNG/Grey/Default/button_rectangle_depth_flat.png", "button_disabled.png"),
    ("ui-pack", "PNG/Grey/Default/button_square_flat.png", "panel.png"),
    ("ui-pack", "PNG/Grey/Default/button_square_border.png", "panel_border.png"),
    ("ui-pack", "PNG/Grey/Default/input_rectangle.png", "panel_inset.png"),
    ("ui-pack", "PNG/Grey/Default/divider.png", "divider.png"),
    ("ui-pack", "PNG/Blue/Default/star.png", "star.png"),
    ("ui-pack", "PNG/Grey/Default/star_outline.png", "star_outline.png"),
]

# Icons the HUD maps to yields, actions and notifications. Kenney's icon packs
# are single-colour, so the theme tints them per yield.
UI_ICONS = [
    ("game-icons", "PNG/White/1x", [
        "star", "gauge", "hammer", "wrench", "gear", "home", "flag", "trophy",
        "shield", "sword", "heart", "lock", "unlock", "plus", "minus", "cross",
        "checkmark", "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
        "information", "exclamation", "question", "musicOn", "audioOn",
        "audioOff", "pause", "play", "fastForward", "save", "load", "book",
        "basket", "cart", "coin", "gem", "key", "map", "target", "timer",
        "user", "users", "wrench", "leaf", "fire", "water",
    ]),
]


def copy_ui(packs: Path, out_root: Path) -> tuple[int, list[str]]:
    dest_dir = out_root / "ui"
    dest_dir.mkdir(parents=True, exist_ok=True)
    copied = 0
    missing: list[str] = []

    for pack, rel, dest_name in UI_SPRITES:
        src = packs / pack / rel
        if not src.exists():
            # Pack layouts shift between releases; fall back to a filename search.
            matches = list((packs / pack).rglob(Path(rel).name))
            if not matches:
                missing.append(f"{pack}:{rel}")
                continue
            src = matches[0]
        shutil.copy2(src, dest_dir / dest_name)
        copied += 1

    icon_dir = out_root / "ui" / "icons"
    icon_dir.mkdir(parents=True, exist_ok=True)
    for pack, rel, names in UI_ICONS:
        base = packs / pack / rel
        for name in names:
            src = base / f"{name}.png"
            if not src.exists():
                matches = list((packs / pack).rglob(f"{name}.png"))
                if not matches:
                    continue  # icon sets vary; a missing icon is not fatal
                src = matches[0]
            shutil.copy2(src, icon_dir / f"{name}.png")
            copied += 1

    return copied, missing


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    packs = Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".assetcache"
    out_root = root / "assets" / "art"

    if not packs.is_dir():
        print(f"asset packs not found at {packs} — run tools/setup_assets.sh first")
        return 1

    models, missing_models = copy_models(packs, out_root)
    sprites, missing_ui = copy_ui(packs, out_root)

    print(f"copied {models} models, {sprites} ui sprites -> {out_root}")
    for name in missing_models + missing_ui:
        print(f"  MISSING {name}")
    return 1 if (missing_models or missing_ui) else 0


if __name__ == "__main__":
    raise SystemExit(main())
