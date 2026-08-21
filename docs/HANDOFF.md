# Civilizazione — developer handoff

Everything a new contributor (human or AI) needs to pick this up. Read this
before touching code.

---

## 1. What this project is

A Civilization VI–depth 4X turn-based strategy game in Godot 4.7, GDScript.

**It is not a Civ 6 asset copy.** No Firaxis/2K art, models, music, UI chrome,
leader portraits, or Civilopedia text is in this repository, and none may be
added. What *is* reproduced is the published *ruleset* — the same footing as
Unciv, Freeciv and Old World. Concretely:

- Historical civilizations and leaders (Rome, Mali, Persia…) are fine: they are
  history, not anyone's IP. Their in-game abilities here are our own design.
- Art must be CC0 (Kenney packs) or authored in Blender in this repo.
- Documented Civ 6 formulas (the combat curve, loyalty pressure, appeal
  modifiers) are game *rules*, and are implemented from published community
  research, not decompiled code.

The user asked for "an exact clone." That is what the boundary above allows:
same mechanics and same numbers, original presentation.

---

## 2. Current state

| Area | Status |
|---|---|
| Simulation core | **Working.** Full AI-vs-AI games run headless end to end. |
| Map generation | **Working.** Climate bands, rivers, continents, resources, natural wonders, fair starts. |
| Cities, districts, adjacency | **Working.** Yield pipeline, housing, amenities, growth, production, capture. |
| Units, combat, promotions | **Working.** Real damage curve, ZOC, stacking, city assault. |
| Tech + civic trees, Eurekas | **Working.** Ancient → Industrial content, live boost triggers. |
| Government + policy cards | **Working.** 7 governments, 24 cards, all as modifier data. |
| City-states, envoys, suzerainty | **Working.** |
| Loyalty | **Working.** Pressure formula, Free City revolts. |
| Barbarians | **Working.** Outposts, scouts, raids. |
| AI | **Working.** Flavour-weighted strategy + tactical combat. |
| Victory | Domination + Score only. Four others stubbed. |
| **3D view layer** | **Working.** Continuous hex terrain, rivers, shore foam, wrapping, unit + city renderers, hex grid, yields lens, territory borders. |
| **UI** | **Working.** Main menu, HUD, city panel, research/civic panel, unit actions, notifications. |
| Save/load | Serialisers exist on every state class; no file I/O yet. |
| Great People, Religion, Trade | Not built (points accumulate, nothing spends them). |
| Diplomacy, World Congress | Not built. |
| Era score, Golden Ages, Governors | Not built. |
| Climate, disasters, power | Not built. |

**The remaining gaps are content and polish, not structure.** The simulation is
complete and testable, and there is now a playable view over it. What is missing
is the systems listed as "Not built" above, four victory types, and save/load
file I/O.

The one deliberate omission worth naming: **there is no fog of war.** Civ 6's
whole art direction is cartographic — unexplored ground is blank parchment,
partially seen ground is drawn in pen-and-ink cross-hatch — and that is the
largest remaining visual gap between this and the real game. It is out of scope
by an explicit product decision, not an oversight: the whole map is visible.

---

## 3. Getting set up

```bash
./tools/setup_toolchain.sh          # fetches pinned Godot 4.7 + Blender 4.5.9 into .toolchain/
.toolchain/godot --headless --path . --import      # first-time asset import
```

Run things:

```bash
# Unit tests — 215 assertions on the formulas
.toolchain/godot --headless --path . -- --test

# Headless AI-vs-AI soak run
.toolchain/godot --headless --path . -- --sim turns=100 civs=5 map_size=small seed=7
.toolchain/godot --headless --path . -- --sim turns=150 civs=6 verbose=1

# Interactive
.toolchain/godot --path .

# Render one frame of a generated map, without booting the game scene
.toolchain/godot --path . -- --shot seed=7 map_size=small out=/tmp/map.png

# Boot the real scene and drive it: found a capital, run turns, screenshot each
# stage. This is the one that catches view bugs a green test suite does not.
.toolchain/godot --path . -- --play turns=5 seed=7 civs=4 map_size=tiny shots=/tmp/x
```

On a headless box, wrap the two rendering commands:

```bash
xvfb-run -a -s "-screen 0 1600x900x24" \
  .toolchain/godot --path . --rendering-driver opengl3 -- --play shots=/tmp/x
```

`--sim` options: `turns`, `civs`, `map_size` (duel/tiny/small/standard/large/huge),
`seed`, `verbose=1`.

**Look at the screenshots.** Every visual bug in this project so far — rivers on
the wrong edges, a lake in the middle of a desert, a white ring instead of a
shoreline, yield pips that read as orange debug boxes, city banner text
swallowed by its own outline — passed the test suite and was obvious in a
rendered frame. `--play` writing PNGs is not a formality; it is the only check
that covers the view layer.

---

## 4. Architecture — read this part properly

### 4.1 The modifier engine is the centrepiece

`core/modifiers/`. Civ 6 is mechanically an enormous pile of *conditional
modifiers*. A policy card, a religious belief, a governor promotion, a suzerain
bonus, a wonder, a leader ability, a Golden Age dedication and a World Congress
resolution are all the same thing: "under condition X, adjust Y by Z."

```
Modifier   = { effect, args, scope, requirements[], source }
Requirement = { type, args, inverse }
ModifierEngine.sum_scalar(effect, ctx) / sum_yields(effect, ctx)
```

**Adding new content never requires engine changes.** Write JSON. Adding a new
*kind* of effect means adding a constant and a consumer; adding a new *kind* of
condition means one `match` arm in `requirement.gd`.

Modifiers attach to a **source** (`set_source(player, kind, id, mods)`) and are
removed wholesale (`clear_source`). Nothing has to remember to undo a bonus by
hand — unslot a policy card, lose a city, lose a suzerainty, and the bonus
disappears with it.

If you find yourself writing `if player.government_id == ...` in a system file,
stop. It belongs in data.

### 4.2 The simulation never touches the engine

`core/` contains no scene, node, mesh or `Control` reference. It is plain
`RefCounted` objects. That is what lets a full game run under `--headless`, and
it is not negotiable — the soak runner is the only real regression net this
project has.

The view and UI **read** state and listen to `EventBus`. They never write to it
except by calling a system function.

### 4.3 The yield pipeline order is load-bearing

`CitySystem.recompute()` runs in this exact order:

1. Worked tiles (city centre always works its own, with a 1/1 floor)
2. District adjacency
3. Buildings and wonders
4. Flat modifier bonuses
5. **Percentage modifiers** — must see the finished flat total
6. Mood and loyalty multipliers (Food is exempt; it has its own growth
   multiplier)

Swapping 4 and 5 is the classic bug: a +15% Science card silently ignores the
Library it was meant to amplify.

### 4.4 Spatial indexes

`Game` maintains `_military_at`, `_civilian_at`, `_city_at`, `_units_by_player`,
`_cities_by_player`. **Never** write `unit.coord = x` or `game.units[id] = u`
directly — call `game.move_unit()`, `game.register_unit()`,
`game.unregister_unit()`, `game.register_city()`, `game.reassign_city()`.

Two bugs already came from getting this wrong:

- Indexing by **raw** axial coordinates let two units share a tile, because on a
  wrapping map one tile has several valid raw coordinates. All index keys go
  through `Game._key()` (which normalises) now.
- Positional lookups used to scan every unit. At thousands of calls per turn
  from pathfinding, that made turn resolution quadratic — 40 turns took 85
  seconds. With indexes, 100 turns take 48.

### 4.5 Determinism

`RNGService` splits randomness into named streams (`map`, `combat`, `ai`,
`barbarian`, …). Adding one die roll to the AI must not shift every subsequent
combat result. Always draw from the right stream. There is a determinism test;
keep it passing.

---

## 5. Layout

```
core/                 simulation — no engine dependencies
  game.gd             autoload: master state + spatial indexes
  turn_manager.gd     turn loop ordering
  game_setup.gd       new-game construction
  content_db.gd       autoload: loads data/*.json, validates cross-references
  event_bus.gd        autoload: signals (core emits, view/ui listen)
  rng_service.gd      autoload: seeded independent streams
  yields.gd           the 7-channel yield value type
  modifiers/          Modifier, Requirement, ModifierEngine
  defs/               typed wrappers over JSON content
  map/                Hex, Tile, MapModel, MapGenerator
  city/               CityState, CitySystem, Adjacency
  units/              UnitState, UnitSystem, Combat, BarbarianSystem
  empire/             PlayerState, ResearchSystem
  diplomacy/          CityStateSystem (envoys, suzerainty, loyalty)
  ai/                 AIController
  victory/            VictorySystem
data/                 all game content as JSON
tests/                test_runner.gd (unit tests), sim_runner.gd (soak)
tools/                setup_toolchain.sh, blender/ (asset generation)
legacy_prototype/     the original Python/Pygame prototype — reference only
view/  ui/            empty — this is the next milestone
```

---

## 6. Content authoring

All content is `data/*.json`, loaded by `ContentDB` into typed defs and
**cross-reference validated at startup**. A typo in a tech id fails the boot
rather than surfacing three hours later as a city that quietly under-yields.

Adding a unit is a JSON entry. Adding a policy card is a JSON entry with a
modifier. Adding a district means a JSON entry with an `adjacency` array:

```json
{ "kind": "terrain", "match": ["mountains"], "amount": 1 }
{ "kind": "feature",  "match": ["rainforest"], "amount": 1, "per": 2 }
{ "kind": "district", "amount": 1, "per": 2 }
{ "kind": "river",    "amount": 2 }
```

`per: 2` is how Civ 6's "+1 per **two** adjacent Rainforest" works.

Current content: 9 terrains, 8 features, 30 resources, 7 improvements, 8 natural
wonders, 11 districts, 22 buildings, 8 wonders, 16 units, 19 promotions, 25
techs, 15 civics, 7 governments, 24 policy cards, 8 leaders, 12 city-states.

---

## 7. Implemented Civ 6 formulas

Keep these exact. They are cross-corroborated; the research notes flag which
numbers are less certain.

| Rule | Implementation |
|---|---|
| Combat damage | `30 × e^(Δstrength/25) × rand(0.75,1.25)` — 30 HP at parity, doubling every ~17 strength |
| Corps / Army | +10 / +17 strength — tuned against that curve to give ~1.5× / ~2× damage |
| Promotions | 15 XP for level 2, +15 each level, max level 6, max 8 XP per combat |
| Class counters | Melee +5 vs anti-cavalry; anti-cavalry +10 vs cavalry |
| Amenities | 1 per 2 citizens starting at population 3 (first two are free) |
| Housing growth | ≥2 spare = 100%, 1 spare = 50%, at cap = 25%, 5 over = 0% |
| District allowance | 1 + floor(population / 3) specialty districts |
| Eureka / Inspiration | 40% of the node's cost, once only |
| Research cost | ±10% per era of distance from the world era, clamped to ±20% |
| Appeal | +4 mountain, +2 per adjacent natural wonder, ±1 per the documented list; five named tiers |
| Loyalty | `10 × (domestic − foreign) / (min + 0.5)`, capped ±20/turn, population × (10 − distance) |
| Suzerainty | 3+ envoys and more than any rival |
| City strength | best melee unit − 10, +2 per district, or the garrison if stronger |
| City ranged strike | range 2, best ranged unit's strength, floor of 3 |

---

## 8. The view layer

Built. The design reference is the twelve Civ 6 screenshots the user supplied
(see `docs/UI_REFERENCE.md`) — used for **information architecture**, what each
panel must show and where it sits. All chrome and art is CC0 or original.

### What is there

| File | Draws |
|---|---|
| `view/world/terrain_mesh.gd` | The ground: one continuous welded mesh, flat tile cores with blended edge rings, mountains as part of the mesh so ranges weld into ridges. |
| `view/world/terrain.gdshader` | Three octaves of world-space noise plus a hue drift and slope shading, so ground is a painted field rather than flat fill. |
| `view/world/hex_world.gd` | Composition of terrain, water, rivers, ice, territory borders, and the wrap laps. |
| `view/world/unit_renderer.gd` | One node per unit: model, owner-coloured flag with class icon, health bar, order badge. |
| `view/world/city_renderer.gd` | Keep + houses that grow with population + walls, under a banner carrying name, population and current production. |
| `view/world/screen_scale.gd` | Holds flags and banners near a constant screen size across the zoom range. |
| `view/overlays/hex_grid.gd` | Tile outlines, terrain-following, toggled with G. |
| `view/overlays/yield_lens.gd` | Civ 6-style yield icon badges per tile, toggled with Y. |
| `view/camera_rig.gd` | Pan, zoom, pitch, click-to-tile raycast. |
| `ui/` | Main menu, HUD, city panel, research panel, unit actions, notifications. |

### Three things that will bite you

**The corner lattice.** Anything drawn on a hex *edge* — rivers, the grid,
territory borders — must get its corner pair from `Hex.edge_corners(direction)`.
Deriving it as `angle ± 30°` looks right and is wrong: it picks the edge one
step round. That bug shipped twice, once in the river tracer and once in the
border renderer, and in both cases the geometry rendered fine and landed on the
wrong side of the tile.

**Perturbation order.** `TerrainMesh.perturb()` displaces a point horizontally
by noise sampled *at that point*. To sit on a terrain edge you must perturb the
true corner and inset afterwards; insetting first samples different noise and
slides the overlay off the ground it is tracing.

**Nothing rebuilds per frame.** Grid, borders and terrain are built once per map
(borders coalesce their rebuild through `request_border_refresh`). The yields
lens learned this the hard way: unshaded spheres with depth test off turned the
map into a slideshow on software rendering, and the fix was cheap billboarded
quads with depth test on.

### What is left visually

- Fog of war — out of scope by product decision, and the largest remaining gap.
- The wrap seam still shows a hairline. Folding world X alone is not the fix:
  one lap displaces in Z too, and welding on X alone tears the mesh.
- The polar ice shelf ends in a hard cut rather than breaking up into floes.

### Blender

`tools/setup_toolchain.sh` installs Blender 4.5.9. It runs headless and builds
models from Python:

```bash
.toolchain/blender/blender --background --python tools/blender/<script>.py
```

Author low-poly hex tiles, unit meeples and district blockouts, export `.glb`
into `assets/art/models/`. Keep the style deliberately distinct from Civ 6's.

---

## 9. Roadmap

M2 Great People, religion, trade routes · M3 diplomacy, World Congress,
espionage · M4 loyalty extras, governors, era score and Golden Ages · M5 climate,
disasters, power · M6 the remaining four victory conditions · M7 content breadth
to the Future era · M8 presentation polish.

`docs/` also holds the full Civ 6 systems research these were scoped from.

---

## 10. Working rules

- **Run the soak runner before every commit.** `--sim turns=100 civs=5` must end
  with "No state violations." It has caught every serious bug so far.
- **Run the unit tests too.** `--test` must stay at 0 failures.
- Add an invariant to `sim_runner._audit()` whenever you add state that could
  become inconsistent.
- Add an assertion to `test_runner.gd` whenever you implement a formula.
- **Render and look at it.** Any change to `view/` or `ui/` ends with a
  `--play ... shots=` run and an actual look at the PNGs. Every visual bug this
  project has had passed `--test`.
- Content goes in JSON, not in `if` statements.
- Never add Firaxis assets. Art is CC0 (credited in `assets/art/CREDITS.md`) or
  authored here. Rules are reimplemented from published community research.
