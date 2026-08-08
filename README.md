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
| Full recording mode | Off | Disables cropping and records every generated chunk continuously. **Produces enormous files** (potentially gigabytes per hour) - meant for short recordings or debugging, not routine play. |

If you don't write Lua and just want to tune how aggressively replays are cropped, this is the only place you need to look - the settings menu is the supported way to change this mod's behavior, no code editing required.

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
| `inventory_delta` | Any tracked owner's item contents change | `owner` (a stable key, e.g. `player_3`, `vehicle_118`, `container_204`), `owner_kind` (`player`/`vehicle`/`container`/`corpse`/`robot`/`inserter_hand`), a list of `{item, delta}` changes, and `position` for owners (like corpses) that aren't otherwise position-tracked elsewhere |
| `fluid_delta` | A tracked fluid segment's contents change | `owner` (`fluid_<entity>_<fluidname>`), a list of `{fluid, delta}` changes, and the representative entity's `position` |
| `belt_contents` | A belt's contents change while in an active zone or reached by a chain walk | Per-line item counts, only for lines that changed |
| `item_distribution` | The far end of a belt/inserter chain has any tracked contents | Per (item, rough direction from the zone) entries: `approx_count`, a `centroid` position, and how many entities that estimate is built from |
| `unit_group_created` | A biter/spitter group forms up | Group id, force, position, human-readable state (`gathering`, `attacking_target`, ...) |
| `corpse_created` | A player character dies and their corpse appears | `owner` (`corpse_<id>`, the same key its `inventory_delta`/`corpse_expired` events use), position, `player_index`/`player_name`, `death_tick`, and `killer` |
| `corpse_expired` | A player corpse times out or is fully looted | `owner` (`corpse_<id>`) |
| `zone_expired` | A chunk stops recording after its timeout | Chunk id |

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

## Known Limitations

Documented here rather than left for someone to discover and assume is a bug. Most of the list from the previous round got resolved once real API docs came back - see below for what changed and why.

* **Ground items (`item-entity`) are the one remaining unimplemented piece of the original item-tracking scope** - what a container/corpse/belt/inserter holds is all covered; a loose stack sitting directly on the ground is not. What's confirmed so far (`to_be_looted`, `on_picked_up_item`) doesn't close the gap: `on_picked_up_item` only fires *after* something is picked up, so it can't tell a viewer about a stack nobody has walked over yet, and wiring it in would just duplicate what `on_player_main_inventory_changed` already reports. What's still needed: the `LuaEntity` property that exposes an item-entity's own stack (name/count/quality) while it's still sitting on the ground - something like `.stack`, not present in anything confirmed so far - plus, ideally, the event name(s) fired when a new ground stack *appears* (inserter overflow, explosion loot, a thrown capsule), since `on_picked_up_item` only covers the removal side.

Resolved this round, kept here briefly for context on what changed:

* ~~Corpse cache entries leak~~ - fixed via `on_character_corpse_expired` (see `corpse_expired` above), which clears the cache entry and is the correct hook (`on_entity_died` never fires for a corpse's own decay/looting-out - that event is about the *character* dying, not the corpse expiring later).
* ~~`belt_neighbours`/`FluidBoxNeighbourRecord` shapes unconfirmed~~ - both now read precisely (`belt_neighbours.inputs`/`.outputs`, `FluidBoxNeighbourRecord.entity`/`.index`) instead of guessing. The fluid-box fix wasn't just cosmetic: reading the *specific* connected fluidbox index (rather than every fluidbox on a neighbouring entity) is what actually prevents a multi-fluidbox entity like a pump from having its two independent sides merged into one reported segment - the previous "isn't guaranteed correctly segmented" caveat is resolved, not just documented around.
* ~~Personal logistics vs. base networks aren't distinguished~~ - turns out there's nothing to distinguish: the full `LuaLogisticNetwork` API has no network-type field: a personal (armor) roboport just joins whatever network already covers the character's position rather than creating a separate kind of network. The existing `entity.type ~= "character"` filter on container lists was already the right guard for the one place this could have mattered.
* ~~Inserter search radius was a silent hardcoded guess~~ - now a real setting (`rrec-inserter-search-radius`, default 3 tiles, see Settings above) instead of a hidden constant. The radius only narrows the *search*; correctness comes entirely from the exact `pickup_target`/`drop_target` match on each candidate, which was always confirmed API.

## License

See [LICENSE](LICENSE).
