<div align=center>
  <h1>Replay Recorder</h1>
  <h4>A standalone telemetry exporter for visualizing combat and gameplay mechanics</h4>
</div>

<hr>

Replay Recorder extracts detailed, event-driven game state (tiles, entities, projectiles, and AI behavior) and exports it into an independent JSON replay format.

That data is designed to be ingested by standalone desktop visualizers, so you can replay, analyze, and map out combat encounters without running the Factorio engine itself.

*Inspired heavily by the incredible [Statorio](https://mods.factorio.com/mod/statorio) by chksm.*

## Features

* **Smart Spatial Cropping:** Recording only turns on for a chunk once a player (on foot, driving, or piloting a vehicle) is actually within range of a fight there. Idle bases and biters that never see a player are never recorded.
* **Sports-Style Scoring:** Player and vehicle deaths are logged as `score_update` events, with a running per-force death count - think of it as the "goal" in a sports replay. `player_respawn` marks the moment play resumes.
* **Environmental Context:** The first time a chunk becomes relevant, its tiles (water, landfill, concrete, ...) and every building on it (walls, every turret type, nests, and anything else standing there) are dumped once, so a viewer can render the battlefield without re-recording it on every subsequent skirmish.
* **Event-Driven Tracking:** Projectile/stream impacts, fire and acid patches appearing and expiring, inventory changes, and belt contents are all recorded as diffs or one-shot events rather than by polling everything every tick.
* **AI Grouping:** Nests captured in a snapshot are clustered into rough "bases" by proximity; biters/spitters report the `unit_group` they belong to and, individually, the specific spawner they hatched from, so a viewer can render an attack/expansion party or a nest's offspring as one object.
* **Mod-Agnostic:** Nothing is matched by hardcoded entity name. Combat detection is wired up for every projectile/stream prototype in the data stage, and building capture works by *excluding* known mobile/decorative entity types rather than matching an allow-list - a mod's new biter, turret, or building shows up automatically.
* **Logistic Reach:** A chunk snapshot captures the roster of every storage/provider/requester container reachable by a logistics network that touches it - not just the chests physically standing in that chunk. Their contents are then sampled on a slow, configurable interval for as long as the network keeps showing robot activity, so supply lines feeding the battlefield stay visible even when the depot itself is elsewhere.
* **Physical Item Tracking:** Containers, corpses, and inserter hands physically inside a zone are diffed every tick, the same way belts already were - chests, what's mid-transfer, and what a fallen player dropped are all part of "immediately here on the battlefield." A player's corpse also gets a one-time `corpse_created` record and a `corpse_expired` record once it's gone.
* **Long-Distance Supply Chains:** Belts and inserters are followed outward from a zone - well past its chunk boundary - via belt-to-belt connections and inserter pickup/drop targets. Close hops get tracked precisely; distant hops are rolled up into a compact "roughly this many of this item, this direction from the fight" summary instead of one event per far-off entity.
* **Fluid Chains:** Pipes, storage tanks, pumps, and flamethrower turret fuel are tracked the same way, following the pipe network's own internal "fluid segments" - each connected run of pipe is read and reported once, however long it is.
* **Ground Items:** Loose item stacks lying on the ground inside an active zone are diffed every tick just like a chest. A player manually dropping one gets a one-time `ground_item_created` provenance record, and a `ground_item_removed` record once it's gone.
* **Item Motion Is Implicit:** There's no separate "item moved" event - an item's owner is tracked under that owner's `inventory_delta`, and that owner's position is tracked every tick via `mobile_positions`. Cross-referencing the two tells a viewer where those items physically are at any moment, including while their owner is moving.
* **Full Recording Mode:** A settings toggle to disable cropping entirely and record every chunk, every tick, for when you need everything and not just combat. It produces very large files - see [Settings](#settings) below.

## Installation

1. Download a release zip from the [Releases](../../releases) page (or build one yourself - see [`docs/packaging.md`](docs/packaging.md)).
2. Extract it into your Factorio `mods` directory, so you end up with a `mods/replay-recorder_<version>/` folder containing `info.json`.
3. Enable the mod from Factorio's in-game Mods menu.

Not yet available on the Factorio mod portal - see [`changelog.md`](docs/changelog.md) for the roadmap to 1.0.

## Usage

There are three ways to produce a `replay.json` with this mod, ranging
from "just play the game" to a not-yet-confirmed headless workflow meant
for automated testing. See [`docs/usage.md`](docs/usage.md) for the full
breakdown of each and when to use it:

1. Recording live during normal gameplay (not recommended).
2. Playing back a Factorio-recorded replay via the in-game **Play**
   button (recommended for most users).
3. Playing back a replay via the headless Factorio client (most
   efficient for testing and development - not yet confirmed to work).

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
| Inserter search radius | 3 tiles | How far to search around a chest for inserters that service it. The radius only narrows the search - matches are confirmed via each candidate's exact `pickup_target`/`drop_target`, so a too-large radius costs a little performance, not correctness. |
| Chunk backfill per tick | 2 chunks | When full recording mode turns on with already-generated chunks in the save, how many of them get scanned and captured per tick while catching up. See [Full recording mode performance](#full-recording-mode-performance) below. |
| Flush interval | 1 second | How often the buffered event queue gets serialized and written to `replay.json`, at most - see "Max buffered events" below for the other trigger. |
| Max buffered events | 2 events | Caps how many buffered events a single flush serializes+writes, and triggers an early flush once the buffer grows past this size. See [Full recording mode performance](#full-recording-mode-performance) below. |
| Full recording mode | Off | Disables cropping and records every generated chunk continuously. **Produces enormous files** (potentially gigabytes per hour) - meant for short recordings or debugging, not routine play. |
| Diagnostics enabled | Off | Writes per-tick timing to Factorio's own log file, not `replay.json` (see [Performance diagnostics](#performance-diagnostics) below). |
| Battlefield marker enabled | Off | Draws a cyan line around the exterior perimeter of whatever chunks are currently recording (see [Battlefield marker](#battlefield-marker) below). A no-op under full recording mode. |

If you don't write Lua and just want to tune how aggressively replays are cropped, this is the only place you need to look - the settings menu is the supported way to change this mod's behavior, no code editing required.

### Full recording mode performance

Turning full recording mode on mid-save backfills every already-generated
chunk, throttled by "Chunk backfill per tick" so the scan itself doesn't
freeze the game. That scan still queues a full `chunk_snapshot` event per
chunk, so "Max buffered events" caps how many entries `Exporter.flush()`
writes per call and triggers an early flush the moment the buffer crosses
that size - a large backlog drains as several small, bounded writes
instead of one write that can stall for multiple seconds.

While backfill is active, `control.lua`'s `on_tick` alternates: even
ticks drain the backfill queue, odd ticks check for a flush - so the two
heaviest operations never land in the same game tick (which runs as one
atomic, uninterruptible unit of work regardless of internal ordering).
New chunks generated after the initial backfill are still captured
immediately as they generate.

A save can keep an older stored setting value even after a mod update
changes the default - see [Performance diagnostics](#performance-diagnostics)
below to confirm what's actually in effect for a given save rather than
assuming the current defaults took hold.

The fixed-interval flush is also staggered half a period away from the
distant-sample interval, since both commonly run on the same cadence and
would otherwise land on the same tick every time, compounding two
separate periodic costs instead of spreading them out.

### Performance diagnostics

Turning on "Diagnostics enabled" measures three timings every tick via
`game.create_profiler()`: `tick_time` (the whole `on_tick` handler),
`scan_time` (everything except the JSON write), and `write_time`
(`Exporter.flush()` alone, present only on ticks where a flush actually
happened) - answering "is a stall scan-bound or IO-bound" with real
numbers. Each line also carries `buffer_size` (events currently queued)
and `backfill_remaining` (chunks left in the full-recording backfill
queue), so a real run can confirm the settings above are actually in
effect for that save.

These never go into `replay.json` - `LuaProfiler` values are only usable
as `LocalisedString` elements (`game.print()`, `log()`, GUI text), so
`script/diagnostics.lua` writes a marked line to Factorio's own log file
instead. Run [`tools/inspect_logs.py`](tools/inspect_logs.py) to
summarize it:
```
python3 tools/inspect_logs.py
```
Beyond a min/p50/mean/p95/max summary per field, it reports a dedicated
backfill-queue summary (drain time, peak depth, peak buffer size), the
slowest N individual ticks per field (`--top-n`, default 10), and any
"slow streaks" - runs of consecutive ticks each at or above a threshold
(each field's own p95 by default, or `--slow-threshold-ms` to set one
explicitly).

It defaults to the standard per-OS `factorio-current.log` location (see
[`docs/testing-checklist.md`](docs/testing-checklist.md)'s setup step for
the exact paths); pass `--path` if that's wrong for your setup, e.g. to
point at `factorio-previous.log` for the session before the current one.

### Battlefield marker

Turning on "Battlefield marker enabled" draws a cyan line around the
exterior perimeter of whatever chunks are currently active, recomputed
every second via `rendering.draw_line`, non-destructively (it never
touches real map tiles). A no-op under full recording mode, since every
chunk is "the zone" then and a border around everything would be
meaningless. Purely a visual aid for manual testing - it has no effect on
what gets recorded.

## Output Format

Data is exported to Factorio's `script-output/replay.json` as
newline-delimited JSON (JSONL) - one `{"tick": ..., "type": ..., "data":
...}` object per line, appended roughly once a second. Reading it as a
stream (rather than one giant JSON document) is what lets a visualizer
start rendering before a long recording has finished.

See [`docs/schema.md`](docs/schema.md) for the full event-type
reference - the contract this mod's output follows, and the thing to
build a downstream consumer against.

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
  kind/size, and a sample payload per event type:
  ```
  python3 tools/inspect_replay.py
  ```
* [`tools/inspect_logs.py`](tools/inspect_logs.py) summarizes per-tick
  performance timings (only present when "Diagnostics enabled" was on) -
  see [Performance diagnostics](#performance-diagnostics) above:
  ```
  python3 tools/inspect_logs.py
  ```

None of these need dependencies beyond Python's standard library.

## Releasing

See [`docs/packaging.md`](docs/packaging.md) for how to build a release
zip and cut a GitHub release.

## Changelog

See [`changelog.md`](docs/changelog.md) for released changes and the roadmap
toward 1.0.

## License

See [LICENSE](LICENSE).

<!--
Guidance for coding agents working on this repo (not rendered content for
end users - kept here rather than deleted so it survives across sessions):

FACTS TO STOP RE-DISCOVERING:
- This mod targets Factorio 2.0.76 specifically, not 2.1 ("latest") - 2.1
  changed parts of this API. Every lua-api.factorio.com link MUST read
  https://lua-api.factorio.com/2.0.76/... - never .../latest/...
- You (the agent) are unable to fetch lua-api.factorio.com yourself - outbound
  access to it is blocked in this environment. You cannot verify a class
  property, event field, or prototype type against the real docs on your
  own, no matter how confident you feel about it from training data.

THE COST ORDER - cheapest first, use the cheapest tool that can actually
answer the question:
1. Reason from what this repo's OWN code/history/tests already prove.
   A check that's been passing every round already demonstrates something
   real (e.g. step 4's passing item_distribution check proves inserter
   drop_target direction for THIS exact placement pattern) - use it
   before inventing a new probe to re-confirm the same fact.
2. Ask the repo owner for a specific doc lookup: an exact class/event/type
   page URL plus an exact property/field name to search for (e.g. "LuaEntity
   class page, the `held_stack` property" or "on_entity_damaged event, full
   field list"). This is a schema question - "what CAN this contain, what
   does the API guarantee" - and costs the owner a Ctrl+F, seconds of
   their time. Prefer this over guessing, and prefer it over writing a
   runtime probe for anything that is genuinely documented API structure
   rather than live game data.
3. A relaunch-only data-stage probe (log() calls in data.lua/data-updates.lua,
   or anything that runs before a save loads) - for questions that are
   actual DATA, not schema (a specific vanilla prototype's real field
   values, e.g. a stream's real action table) - lua-api.factorio.com
   documents the FORMAT prototypes can take, never the actual values
   vanilla uses, so no doc lookup can substitute here. Still slightly cheaper
   than an in-game session: no save load, no combat, just launching
   Factorio with the mod active.
4. A full manual checklist playthrough (docs/testing-checklist.md) - only
   for questions that are genuinely live gameplay behavior (does a real
   entity's real runtime state do X during actual combat) that can't be
   observed at load time. This costs the owner real, significant time and
   effort. Never ask for this as a first resort, and never ask for it to
   confirm something a doc lookup or relaunch-only probe could answer
   instead - check that you've exhausted 1-3 first.

WHEN YOU GET AN ANSWER: cross-check it against whatever runtime evidence
already exists before proposing a fix, and say plainly which parts are now
confirmed vs. which remain open. A "CONFIRMED" comment in this codebase
must be backed by either real doc text someone actually pasted back, or
real log/probe output someone actually observed - never by "it's confirmed
for case A, so it probably also holds for case B". If you
aren't sure whether something is confirmed or assumed, say assumed.
-->
