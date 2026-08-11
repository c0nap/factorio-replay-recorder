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
* **Logistic Reach:** A chunk snapshot captures the roster of every storage/provider/requester container reachable by a logistics network that touches it - not just the chests physically standing in that chunk. Their contents are then sampled on a slow, configurable interval (not every tick - a shared network can span an entire base) for as long as the network keeps showing robot activity, so supply lines feeding the battlefield stay visible even when the depot itself is elsewhere.
* **Physical Item Tracking:** Containers, corpses, and inserter hands physically inside a zone are diffed every tick, the same way belts already were - chests, what's mid-transfer, and what a fallen player dropped are all part of "immediately here on the battlefield." A player's corpse also gets a one-time `corpse_created` record (who died, when, and to what) and a `corpse_expired` record once it's gone, so a viewer can show "this is Alice's corpse from tick 41200" rather than just an anonymous chest-like object.
* **Long-Distance Supply Chains:** Belts and inserters are followed outward from a zone - well past its chunk boundary - via belt-to-belt connections and inserter pickup/drop targets. Close hops get tracked precisely; distant hops are rolled up into a compact "roughly this many of this item, this direction from the fight" summary instead of one event per far-off entity, so a huge buffer chest 40 belts away shows up as one line, not forty.
* **Fluid Chains:** Pipes, storage tanks, pumps, and flamethrower turret fuel are tracked the same way, following the pipe network's own internal "fluid segments" - each connected run of pipe is read and reported once, however long it is, not once per pipe.
* **Ground Items:** Loose item stacks lying on the ground (`item-entity`) inside an active zone are diffed every tick just like a chest, via the `.stack` property `ItemEntity` types expose. A player manually dropping one also gets a one-time `ground_item_created` provenance record (who dropped it, when, where), and a `ground_item_removed` record once it's gone - picked up, mined, or destroyed, tracked via `register_on_object_destroyed` regardless of which.
* **Item Motion Is Implicit:** There's no separate "item moved" event - an item owned by a player, vehicle, or robot is tracked under that owner's `inventory_delta`, and that owner's position is tracked every tick via `mobile_positions`. Cross-referencing the two (by `owner`/`id`) tells a viewer where those items physically are at any moment, including while their owner is moving.
* **Full Recording Mode:** A settings toggle to disable cropping entirely and record every chunk, every tick, for when you need everything and not just combat. It produces very large files - see [Settings](#settings) below.

## Settings

All settings live under *Settings > Mod Settings > Map* and can be changed without restarting Factorio.

| Setting | Default | What it does |
|---|---|---|
| Combat detection radius | 48 tiles | How close a player has to be to a fight before it starts recording. Lower = smaller files, higher = catches more of the action. |
| Zone timeout | 10 seconds | How long a chunk keeps recording after the last hit before it goes quiet again. |
| Distant sample interval | 5 seconds | How often logistics network contents, far-chain item rollups, and fluid segments are re-sampled. These are all "probably on the way, not immediately here" data - lower for fresher distant data at the cost of file size, higher to shrink it. |
| Network activity window | 30 seconds | How long a logistics network keeps counting as reachable after it was last seen with any robots, so a network doesn't flicker in and out just because its robots are all briefly mid-delivery. |
| Chain near hops | 5 | Belt/inserter chain hops within this distance of a zone get exact per-entity tracking; beyond it, they're rolled up into a compact summary instead. |
| Chain max hops | 30 | Absolute limit on how far a belt/inserter chain walk follows outward from a zone, near or far. |
| Inserter search radius | 3 tiles | How far to search around a chest for inserters that service it (chests have no "what's connected to me" query of their own). The radius only narrows the search - matches are confirmed via each candidate's exact `pickup_target`/`drop_target`, so a too-large radius costs a little performance, not correctness. |
| Chunk backfill per tick | 20 chunks | When full recording mode turns on with already-generated chunks in the save, how many of them get scanned and captured per tick while catching up. Lower spreads the catch-up out over more ticks (smoother, slower to finish); higher finishes faster at the cost of more work per tick. See [Full Recording Mode](#full-recording-mode-performance) below. |
| Flush interval | 1 second | How often the buffered event queue gets serialized and written to `replay.json`, at most - see "Max buffered events" below for the other trigger. Larger values batch more events into fewer, bigger writes; smaller values write more often in smaller chunks. |
| Max buffered events | 25 events | Caps how many buffered events a single flush serializes+writes, and triggers an early flush - before the flush interval above is even up - once the buffer grows past this size. See [Full Recording Mode](#full-recording-mode-performance) below. |
| Full recording mode | Off | Disables cropping and records every generated chunk continuously. **Produces enormous files** (potentially gigabytes per hour) - meant for short recordings or debugging, not routine play. |
| Diagnostics enabled | Off | Writes per-tick timing to Factorio's own log file, not `replay.json` (see [Performance diagnostics](#performance-diagnostics) below). |
| Battlefield marker enabled | Off | Draws a cyan line around the exterior perimeter of whatever chunks are currently recording (see [Battlefield marker](#battlefield-marker) below). A no-op under full recording mode. |

If you don't write Lua and just want to tune how aggressively replays are cropped, this is the only place you need to look - the settings menu is the supported way to change this mod's behavior, no code editing required.

### Full recording mode performance

Turning full recording mode on mid-save backfills every already-generated
chunk, not just new ones - captured gradually via the "chunk backfill per
tick" setting above (20 chunks/tick by default) rather than all at once,
so the scanning itself (tiles/statics/logistics per chunk) doesn't freeze
the game the way it originally did.

That fixed the scan side, but a real diagnostics run (see [Performance
diagnostics](#performance-diagnostics)) showed a second, separate freeze
downstream of it: every one of those ~800 scanned chunks queues a full
`chunk_snapshot` event, and `Exporter.flush()` used to write the *entire*
buffered queue in one call regardless of size - one single flush call took
**8.3 seconds** on that run, dwarfing the scan cost (which stayed under
20ms per tick the whole time). It's IO-bound, not scan-bound: the backfill
finishes queuing all ~800 chunks well before the first fixed-interval
flush would even fire, so that first flush had the entire backlog to
write in one shot.

"Max buffered events" fixes this directly: `Exporter.flush()` now writes
at most that many entries per call (oldest first), and `control.lua`
flushes early - not just on the fixed interval - the moment the buffer
crosses that same size. A large backlog drains as several small, bounded
writes instead of one massive one. New chunks generated after the initial
backfill (walking into unexplored territory) are still captured
immediately, one at a time, as they generate.

### Performance diagnostics

Turning on "Diagnostics enabled" measures three timings every tick via
`game.create_profiler()`: `tick_time` (the whole `on_tick` handler),
`scan_time` (everything except the JSON write -
`CombatZones`/`Tracker`/`Logistics`/`ItemChains`/`FluidChains`), and
`write_time` (`Exporter.flush()` alone, present only on ticks where a
flush actually happened) - answering "is a stall scan-bound or IO-bound"
with real numbers instead of a guess.

These do **not** go into `replay.json`. `LuaProfiler` doesn't expose raw
time values to Lua at all - confirmed in the real API docs, not a bug on
either end - it's only usable anywhere a `LocalisedString` is accepted
(`game.print()`, `log()`, GUI text), which does not include this mod's
own JSON event log. So `script/diagnostics.lua` writes a marked line
straight to Factorio's own log file via `log()` instead - the profiler
objects go in as `LocalisedString` elements, the same way they'd be
passed to `game.print()`, and Factorio resolves them into formatted
duration text on the way into the log. Run
[`tools/inspect_logs.py`](tools/inspect_logs.py) to break that log data
down into the same min/p50/mean/p95/max report per field:
```
python3 tools/inspect_logs.py
```
It defaults to the standard per-OS `factorio-current.log` location (see
`docs/testing-checklist.md`'s setup step for the exact paths); pass
`--path` if that's wrong for your setup, e.g. to point at
`factorio-previous.log` for the session before the current one.

### Battlefield marker

Turning on "Battlefield marker enabled" draws a cyan line around the
exterior perimeter of whatever chunks are currently active
(`storage.active_zones`) - recomputed every second via `rendering.draw_line`,
non-destructively (it never touches real map tiles). A no-op under full
recording mode, since every chunk is "the zone" then and a border around
everything would be meaningless. Purely a visual aid for manual testing -
it has no effect on what gets recorded.

## Output Format

Data is exported to Factorio's `script-output/replay.json` as newline-delimited JSON (JSONL) - one `{"tick": ..., "type": ..., "data": ...}` object per line, appended roughly once a second. Reading it as a stream (rather than one giant JSON document) is what lets a visualizer start rendering before a long recording has finished.

| `type` | Fired when | `data` contains |
|---|---|---|
| `chunk_snapshot` | A chunk records for the first time | `tiles`, `statics` (every building/turret/wall/nest, tagged `is_defense` for turrets/walls/gates and grouped into nest `cluster`s), and `logistics` - a one-time *roster* (no contents, not capped) of every storage/provider/requester container reachable by a logistics network touching this chunk, plus that network's robot counts *at capture time* (`robots_at_capture`). Contents aren't here - they arrive later via ongoing `inventory_delta` events (see below), since a roster is a structural fact but contents go stale. |
| `mobile_positions` | Every tick a zone is active | Position/orientation of every unit, character, vehicle, wagon, and bot in the zone, tagged with `group_id` if part of a unit group and `spawner_id` for a biter/spitter's originating nest |
| `death_event` | Any tracked entity dies | Victim (with `hostile_kind`/`hostile_size` for biters/spitters/worms/spawners), killer if any, and `loot` (items dropped) when non-empty |
| `score_update` | A player or a manned/piloted vehicle dies | Force, killer, and that force's running death count |
| `player_respawn` | A player respawns after dying | Player index and new position - the "goal reset" marker |
| `damage_event` | A turret, wall, gate, character, vehicle, locomotive, or artillery wagon takes damage | Target, damage amount, `dealer` (who's responsible) and `dealt_by` (the specific projectile/flame/beam that hit) |
| `projectile_impact` | A tracked projectile/stream hits something | Weapon name, source, target position/entity |
| `effect_created` | A fire/acid patch is created (a spitter's acid, a flamethrower, ...) | Name, position, source entity if known |
| `effect_expired` | A fire/acid patch fades out on its own | Name, position |
| `inventory_delta` | Any tracked owner's item contents change | `owner` (a stable key, e.g. `player_3`, `vehicle_118`, `container_204`), `owner_kind` (`player`/`vehicle`/`container`/`corpse`/`robot`/`inserter_hand`/`ground_item`), a list of `{item, delta}` changes, and `position` for owners (like corpses and ground items) that aren't otherwise position-tracked elsewhere |
| `fluid_delta` | A tracked fluid segment's contents change | `owner` (`fluid_<entity>_<fluidname>`), a list of `{fluid, delta}` changes, and the representative entity's `position` |
| `belt_contents` | A belt's contents change while in an active zone or reached by a chain walk | Per-line item counts, only for lines that changed |
| `item_distribution` | The far end of a belt/inserter chain has any tracked contents | Per (item, rough direction from the zone) entries: `approx_count`, a `centroid` position, and how many entities that estimate is built from |
| `unit_group_created` | A biter/spitter group forms up | Group id, force, position, human-readable state (`gathering`, `attacking_target`, ...) |
| `corpse_created` | A player character dies and their corpse appears | `owner` (`corpse_<id>`, the same key its `inventory_delta`/`corpse_expired` events use), position, `death_tick`, `player_index`/`player_name`, and `killer` if the death had one |
| `corpse_expired` | A player corpse times out or is fully looted | `owner` (`corpse_<id>`) |
| `ground_item_created` | A player manually drops an item on the ground | `owner` (`ground_item_<id>`, the same key its `inventory_delta` uses), position, `player_index` |
| `ground_item_removed` | A tracked ground item is picked up, mined, or destroyed | `owner` (`ground_item_<id>`) |
| `zone_created` | A chunk starts recording for the first time (not re-logged on every later hit that just extends its timeout) | Chunk id |
| `zone_expired` | A chunk stops recording after its timeout | Chunk id |

Per-tick performance timings are *not* in this table - they never go into
`replay.json` at all, see [Performance diagnostics](#performance-diagnostics)
above for where they actually end up and why.

**Cross-referencing item location and motion:** there's no dedicated "item moved" event. An item owned by a player, vehicle, or robot shows up under that owner's `inventory_delta` (`owner_kind` = `player`/`vehicle`/`robot`), and that same owner's position is in every `mobile_positions` update (matched by `id`/`owner`). To know where a player's ammo physically is at tick T, look up their position in `mobile_positions` at T - the two streams are deliberately kept separate (position every tick is cheap and needed for combat rendering regardless of inventory; inventory only needs to be emitted when it actually changes) rather than duplicating position onto every item event.

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

* [`docs/testing-checklist.md`](docs/testing-checklist.md) is a short,
  heavily console-scripted list of scenarios to run through in a real
  (throwaway) save, covering every event type the mod can produce.
* [`tools/verify_checklist.py`](tools/verify_checklist.py) checks the
  resulting `replay.json` against that checklist and prints a pass/fail
  line per scenario - this is the thing to run (and paste, if something
  fails) instead of raw JSON:
  ```
  python3 tools/verify_checklist.py
  ```
* [`tools/inspect_replay.py`](tools/inspect_replay.py) is a general-purpose
  summary for anything not tied to the checklist - event counts, tick
  range, battlefield count/duration/bounding box, scoreboard, kills by
  kind/size, and a sample payload per event type. No dependencies beyond
  Python's standard library for either script:
  ```
  python3 tools/inspect_replay.py
  ```
* [`tools/inspect_logs.py`](tools/inspect_logs.py) summarizes per-tick
  performance timings (only present when "Diagnostics enabled" was on)
  from Factorio's own log file - see
  [Performance diagnostics](#performance-diagnostics) for why those don't
  live in `replay.json`:
  ```
  python3 tools/inspect_logs.py
  ```

## License

See [LICENSE](LICENSE).
