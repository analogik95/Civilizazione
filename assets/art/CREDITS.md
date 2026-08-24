# Art credits

Every model and sprite in this directory is **Creative Commons Zero (CC0)** —
public domain, free for commercial use, no attribution required. We credit the
authors anyway.

## Kenney — www.kenney.nl

All current art comes from Kenney's CC0 asset packs:

| Pack | Used for |
|---|---|
| [Hexagon Kit](https://kenney.nl/assets/hexagon-kit) | hex terrain tiles, districts, improvements, ships |
| [Nature Kit](https://kenney.nl/assets/nature-kit) | trees, rocks, crops, features |
| [Castle Kit](https://kenney.nl/assets/castle-kit) | city walls, towers, siege engines |
| [Fantasy Town Kit](https://kenney.nl/assets/fantasy-town-kit) | fountains, carts, town props |
| [Graveyard Kit](https://kenney.nl/assets/graveyard-kit) | obelisks and altars for Holy Sites |
| [Blocky Characters](https://kenney.nl/assets/blocky-characters) | unit figures |
| [UI Pack](https://kenney.nl/assets/ui-pack) | panels, buttons, sliders |
| [Game Icons](https://kenney.nl/assets/game-icons) | yield and action icons |

License: <http://creativecommons.org/publicdomain/zero/1.0/>

If Kenney's work is useful to you, consider supporting it:
<https://kenney.nl/donate>.

## How this directory is produced

The packs are **not** committed — only the curated subset the game actually
references. To rebuild it:

```bash
./tools/setup_assets.sh
```

That downloads the packs into `.assetcache/` (gitignored) and then runs
`tools/vendor_assets.py`, which copies the specific files listed in its
manifest into `assets/art/` under the names the view layer expects. Swapping an
asset means editing one line of that manifest.

## Adding art

Anything added here must be CC0, or authored in this repository with Blender
(see `tools/blender/`). **No Firaxis or 2K assets, ever** — no ripped models,
textures, music, UI chrome, leader portraits or Civilopedia text. The rules this
game implements are published game mechanics; the presentation must be our own.
