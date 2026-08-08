<div align=center>
  <h1>Factorio Replay Recorder</h1>
  <h4>A standalone telemetry exporter for visualizing combat and gameplay mechanics</h4>
</div>

<hr>

Factorio Replay Recorder extracts highly detailed, event-driven game state data (tiles, entities, projectiles, and AI behavior) and exports it into an independent JSON replay format.

This data is designed to be ingested by standalone desktop visualizers, allowing you to replay, analyze, and map out combat encounters without running the Factorio engine.

*Inspired heavily by the incredible [Statorio](https://mods.factorio.com/mod/statorio) by chksm.*

## Features

* **Smart Spatial Cropping:** Recording only turns on for a chunk once a player (on foot, driving, or piloting a vehicle) is actually within range of a fight there. Idle bases and biters that never see a player are never recorded.
* **Sports-Style Scoring:** Player and vehicle deaths are logged as `score_update` events, with a running per-force death count - think of it as the "goal" in a sports replay. `player_respawn` marks the moment play resumes.
* **Environmental Context:** The first time a chunk becomes relevant, its tiles (water, landfill, concrete, ...) and every building on it (walls, every turret type, nests, and anything else standing there) are dumped once, so a viewer can render the battlefield without re-recording it on every subsequent skirmish.
* **Event-Driven Tracking:** Projectile/stream impacts, fire and acid patches appearing and expiring, inventory changes, and belt contents are all recorded as diffs or one-shot events rather than by polling everything every tick.
* **AI Grouping:** Nests captured in a snapshot are clustered into rough "bases" by proximity; biters/spitters report the `unit_group` they belong to and, individually, the specific spawner they hatched from, so a viewer can render an attack/expansion party or a nest's offspring as one object.
* **Mod-Agnostic:** Nothing is matched by hardcoded entity name. Combat detection is wired up for every projectile/stream prototype in the data stage, and building capture works by *excluding* known mobile/decorative entity types rather than matching an allow-list - a mod's new biter, turret, or building shows up automatically.
* **Full Recording Mode:** A settings toggle to disable cropping entirely and record every chunk, every tick, for when you need everything and not just combat. It produces very large files - see [Settings](#settings) below.

## Settings

All settings live under *Settings > Mod Settings > Map* and can be changed without restarting Factorio.

| Setting | Default | What it does |
|---|---|---|
| Combat detection radius | 48 tiles | How close a player has to be to a fight before it starts recording. Lower = smaller files, higher = catches more of the action. |
| Zone timeout | 10 seconds | How long a chunk keeps recording after the last hit before it goes quiet again. |
| Full recording mode | Off | Disables cropping and records every generated chunk continuously. **Produces enormous files** (potentially gigabytes per hour) - meant for short recordings or debugging, not routine play. |

If you don't write Lua and just want to tune how aggressively replays are cropped, this is the only place you need to look - the settings menu is the supported way to change this mod's behavior, no code editing required.

## Output Format

Data is exported to Factorio's `script-output/replay.json` as newline-delimited JSON (JSONL) - one `{"tick": ..., "type": ..., "data": ...}` object per line, appended roughly once a second. Reading it as a stream (rather than one giant JSON document) is what lets a visualizer start rendering before a long recording has finished.

| `type` | Fired when | `data` contains |
|---|---|---|
| `chunk_snapshot` | A chunk records for the first time | `tiles`, `statics` (every building/turret/wall/nest, tagged `is_defense` for turrets/walls/gates and grouped into nest `cluster`s) |
| `mobile_positions` | Every tick a zone is active | Position/orientation of every unit, character, vehicle, wagon, and bot in the zone, tagged with `group_id` if part of a unit group and `spawner_id` for a biter/spitter's originating nest |
| `death_event` | Any tracked entity dies | Victim (with `hostile_kind`/`hostile_size` for biters/spitters/worms/spawners), killer if any, and `loot` (items dropped) when non-empty |
| `score_update` | A player or a manned/piloted vehicle dies | Force, killer, and that force's running death count |
| `player_respawn` | A player respawns after dying | Player index and new position - the "goal reset" marker |
| `damage_event` | A turret, wall, gate, character, vehicle, locomotive, or artillery wagon takes damage | Target, damage amount, `dealer` (who's responsible) and `dealt_by` (the specific projectile/flame/beam that hit) |
| `projectile_impact` | A tracked projectile/stream hits something | Weapon name, source, target position/entity |
| `effect_created` | A fire/acid patch is created (a spitter's acid, a flamethrower, ...) | Name, position, source entity if known |
| `effect_expired` | A fire/acid patch fades out on its own | Name, position |
| `inventory_delta` | A player's or vehicle's (car/spidertron/cargo-wagon/artillery-wagon) inventory changes | Owner, owner kind, list of `{item, delta}` changes |
| `belt_contents` | A belt's contents change while in an active zone | Per-line item counts, only for lines that changed |
| `unit_group_created` | A biter/spitter group forms up | Group id, force, position, human-readable state (`gathering`, `attacking_target`, ...) |
| `zone_expired` | A chunk stops recording after its timeout | Chunk id |

## For Modders

This mod is designed to need zero changes to support content added by other mods:

* **Combat detection** works off `data.lua`, which walks every `projectile`/`artillery-projectile`/`stream` prototype at the data stage and attaches a script trigger - it doesn't check names, so a modded weapon is covered the same way vanilla ones are.
* **Building/entity capture** (`script/combat_zones.lua`) works by *excluding* a small set of mobile and decorative entity types (see `script/classify.lua`) rather than matching an allow-list of "interesting" building types, so a new building type just shows up.
* **Hostile classification** (`script/classify.lua`) sorts kills into `biter`/`spitter`/`worm`/`spawner` using the entity's engine-assigned `type`, and best-effort tags a size (`small`/`medium`/`big`/`behemoth`) by matching those words in the prototype name - the same convention vanilla and most biter-expansion mods use. An unrecognized name is tagged `unknown` rather than guessed.

If you're adding a new mod and something isn't showing up in the replay, it's more likely a gap in this classification (worth a bug report) than something that needs a name added somewhere.

## Modding Conventions Used Here

If you're new to Factorio modding and browsing this codebase, a couple of things are Factorio-specific rather than this mod's own design:

* **`data.lua` vs `control.lua`** run in entirely separate phases - `data.lua` edits prototypes at game startup (no access to a running game), `control.lua` reacts to events while a save is being played (no access to prototypes). See the comment at the top of each for what's going on.
* **`storage`** is the mod's persistent state table - anything put in it is saved with the game and restored on load. It's why the mod checks `storage.x = storage.x or {}` on setup instead of always creating a fresh table: that pattern only initializes state the first time, and leaves it alone on every subsequent load.
* **`on_init` vs `on_configuration_changed`** - `on_init` only fires once, for a brand new save. `on_configuration_changed` fires whenever mods are added, removed, or updated on an *existing* save, and must be safe to run repeatedly without destroying anything already recorded.

## Testing

There's no automated test suite - the mod's behavior depends on a live
player character interacting with a running Factorio simulation, which
isn't something a headless CI job can easily stand in for. Instead:

* [`docs/testing-checklist.md`](docs/testing-checklist.md) walks through a
  set of console commands and in-game actions in a real (throwaway) save
  that exercise each feature - spawning a biter fight, killing a player to
  check the scoring/respawn flow, toggling full recording mode, and so on.
* [`tools/inspect_replay.py`](tools/inspect_replay.py) reads the
  `replay.json` that produces and prints a concise summary (event counts,
  tick range, scoreboard, kills by kind/size, and sample payloads) instead
  of you having to read raw JSONL by hand. No dependencies beyond Python's
  standard library:
  ```
  python3 tools/inspect_replay.py
  ```

## License

See [LICENSE](LICENSE).
