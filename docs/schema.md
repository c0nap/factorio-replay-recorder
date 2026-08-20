# Replay JSON Schema

This is the contract downstream tools (visualizers, converters, analyzers)
should code against. It covers the 0.1 release. Expect additions in later
0.x releases (see [`changelog.md`](../changelog.md)), but the shape
described here - the envelope, and the fields already documented for each
event `type` - is not expected to change out from under existing
consumers within the 0.x line.

## Envelope

`replay.json` is newline-delimited JSON (JSONL): one line per event, each
a JSON object shaped like

```json
{"tick": 41200, "type": "death_event", "data": {...}}
```

* `tick` - the Factorio game tick the event was recorded at.
* `type` - one of the event types below.
* `data` - a type-specific payload, documented per type.

Lines are appended in tick order as the mod flushes its buffer (see the
README's [Settings](../README.md#settings) table for the flush cadence).
Consume it as a stream rather than reading the whole file into memory at
once - that's what lets a visualizer start rendering before a long
recording has finished.

## Event categories

Every event type falls into one of two categories:

* **Lifecycle events** come in `_created`/`_expired` (or equivalent)
  pairs that bound how long something exists - a battlefield, a corpse, a
  ground item, a temporary effect. Between the two, the thing they
  describe is assumed to still exist unless a data event says otherwise.
* **Data events** are point-in-time facts or diffs: a position update, a
  damage instance, an inventory change. They don't imply anything about
  what exists - only lifecycle events do that.

`chunk_snapshot` is a special case: a one-time structural dump for a
chunk, not paired with an "unsnapshot" event, since what it describes
(tiles and buildings) doesn't expire the way a zone or a corpse does.

### Lifecycle events

| `type` | Fired when | `data` contains |
|---|---|---|
| `zone_created` | A chunk starts recording for the first time (not re-logged on every later hit that just extends its timeout) | Chunk id |
| `zone_expired` | A chunk stops recording after its timeout | Chunk id |
| `corpse_created` | A player character dies and their corpse appears | `owner` (`corpse_<id>`, the same key its `inventory_delta`/`corpse_expired` events use), position, `death_tick`, `player_index`/`player_name`, and `killer` if the death had one |
| `corpse_expired` | A player corpse times out or is fully looted | `owner` (`corpse_<id>`) |
| `ground_item_created` | A player manually drops an item on the ground | `owner` (`ground_item_<id>`, the same key its `inventory_delta` uses), position, `player_index` |
| `ground_item_removed` | A tracked ground item is picked up, mined, or destroyed | `owner` (`ground_item_<id>`) |
| `effect_created` | A fire/acid patch is created (a spitter's acid, a flamethrower, ...) | Name, position, source entity if known |
| `effect_expired` | A fire/acid patch fades out on its own | Name, position |
| `unit_group_created` | A biter/spitter group forms up | Group id, force, position, human-readable state (`gathering`, `attacking_target`, ...) |

### Data events

| `type` | Fired when | `data` contains |
|---|---|---|
| `chunk_snapshot` | A chunk records for the first time | `tiles`, `statics` (every building/turret/wall/nest, tagged `is_defense` for turrets/walls/gates and grouped into nest `cluster`s), and `logistics` - a one-time *roster* (no contents, not capped) of every storage/provider/requester container reachable by a logistics network touching this chunk, plus that network's robot counts *at capture time* (`robots_at_capture`). Contents aren't here - they arrive later via ongoing `inventory_delta` events. |
| `mobile_positions` | Every tick a zone is active | Position/orientation of every unit, character, vehicle, wagon, and bot in the zone, tagged with `group_id` if part of a unit group and `spawner_id` for a biter/spitter's originating nest |
| `death_event` | Any tracked entity dies | Victim (with `hostile_kind`/`hostile_size` for biters/spitters/worms/spawners), killer if any, and `loot` (items dropped) when non-empty |
| `score_update` | A player or a manned/piloted vehicle dies | Force, killer, and that force's running death count |
| `player_respawn` | A player respawns after dying | Player index and new position |
| `damage_event` | A turret, wall, gate, character, vehicle, locomotive, or artillery wagon takes damage | Target, damage amount, `dealer` (who's responsible) and `dealt_by` (the specific projectile/flame/beam that hit) |
| `projectile_impact` | A tracked projectile/stream hits something | Weapon name, source, target position/entity |
| `inventory_delta` | Any tracked owner's item contents change | `owner` (a stable key, e.g. `player_3`, `vehicle_118`, `container_204`), `owner_kind` (`player`/`vehicle`/`container`/`corpse`/`robot`/`inserter_hand`/`ground_item`), a list of `{item, delta}` changes, and `position` for owners (like corpses and ground items) that aren't otherwise position-tracked elsewhere |
| `fluid_delta` | A tracked fluid segment's contents change | `owner` (`fluid_<entity>_<fluidname>`), a list of `{fluid, delta}` changes, and the representative entity's `position` |
| `belt_contents` | A belt's contents change while in an active zone or reached by a chain walk | Per-line item counts, only for lines that changed |
| `item_distribution` | The far end of a belt/inserter chain has any tracked contents | Per (item, rough direction from the zone) entries: `approx_count`, a `centroid` position, and how many entities that estimate is built from |

Per-tick performance timings are never written here - they go to
Factorio's own log file instead. See the README's
[Performance diagnostics](../README.md#performance-diagnostics) section.

## Cross-referencing item location and motion

There's no dedicated "item moved" event. An item owned by a player,
vehicle, or robot shows up under that owner's `inventory_delta`
(`owner_kind` = `player`/`vehicle`/`robot`), and that same owner's
position is in every `mobile_positions` update (matched by `id`/`owner`).
To know where a player's ammo physically is at tick T, look up their
position in `mobile_positions` at T - the two streams are kept separate
deliberately (position every tick is cheap and needed for combat
rendering regardless of inventory; inventory only needs to be emitted
when it actually changes) rather than duplicating position onto every
item event.
