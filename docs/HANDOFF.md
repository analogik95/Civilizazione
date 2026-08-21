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
| **3D view layer** | **Not built.** |
| **UI** | **Not built.** |
| Save/load | Serialisers exist on every state class; no file I/O yet. |
| Great People, Religion, Trade | Not built (points accumulate, nothing spends them). |
| Diplomacy, World Congress | Not built. |
| Era score, Golden Ages, Governors | Not built. |
| Climate, disasters, power | Not built. |

**The single most important gap: there is no view layer and no UI.** The game
is a complete, correct, testable simulation that currently has no way for a
human to see or play it. That is the next milestone.

---

## 3. Getting set up

```bash
./tools/setup_toolchain.sh          # fetches pinned Godot 4.7 + Blender 4.5.9 into .toolchain/
.toolchain/godot --headless --path . --import      # first-time asset import
```

Run things:

```bash
# Unit tests — 212 assertions on the formulas
.toolchain/godot --headless --path . -- --test

# Headless AI-vs-AI soak run
.toolchain/godot --headless --path . -- --sim turns=100 civs=5 map_size=small seed=7
.toolchain/godot --headless --path . -- --sim turns=150 civs=6 verbose=1

# Interactive (currently does nothing — no UI yet)
.toolchain/godot --path .
```

`--sim` options: `turns`, `civs`, `map_size` (duel/tiny/small/standard/large/huge),
`seed`, `verbose=1`.

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

## 8. Next milestone: the view layer and UI

This is the highest-value work available and the reason a build is not yet
playable. The design reference is the twelve Civ 6 screenshots the user supplied
(see `docs/UI_REFERENCE.md`): use them for **information architecture** — what
each panel must show and where it sits — and build the chrome from CC0/original
art.

Suggested order:

1. **`view/world/hex_world.gd`** — `Node3D` + `MultiMeshInstance3D` per terrain
   type, positioned via `Hex.to_world(coord, size)`. Rebuild on
   `EventBus.map_generated`, patch single tiles on `tile_changed`.
2. **Camera rig** — pan (WASD/edge), zoom, and a click-to-tile raycast using
   `Hex.from_world()`.
3. **Fog** — unexplored renders as flat parchment, explored-but-not-visible
   dimmed. `MapModel.explored` / `.visible` already track this per player.
4. **Unit and city views** — one node per `UnitState`/`CityState`, driven by
   `unit_created` / `unit_moved` / `unit_killed` / `city_founded`.
5. **HUD** — top yield bar, turn counter, End Turn button, unit action bar.
6. **City screen** — the panel in the screenshots showing Loyalty / Districts /
   Amenities / Housing, turns-to-growth, turns-to-production, and the production
   list from `CitySystem.available_production()`.
7. **District placement preview** — hover a site and show the adjacency it would
   deliver. `Adjacency.rank_sites()` already returns exactly this, ranked.
8. **Tech and civic trees** — era-banded columns, node = name + turns + unlocks +
   "To Boost:" hint, highlighted when boosted. `EmpireDefs.TreeNodeDef.boost_text`
   is already populated.
9. **Government screen** — slot rows by type from `PlayerState.policy_slots()`,
   available cards filtered by `PolicyDef.fits_slot()`.

Everything those screens need is already queryable from the simulation. None of
it requires a rules change.

### Blender

`tools/setup_toolchain.sh` installs Blender 4.5.9. It runs headless and builds
models from Python:

```bash
.toolchain/blender/blender --background --python tools/blender/<script>.py
```

Author low-poly hex tiles, unit meeples and district blockouts, export `.glb`
into `assets/art/models/`. Keep the style deliberately distinct from Civ 6's.

---

## 9. Roadmap after the UI

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
- Content goes in JSON, not in `if` statements.
- Never add Firaxis assets.
