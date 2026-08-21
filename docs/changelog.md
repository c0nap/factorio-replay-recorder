# Changelog

Goals and user-facing changes only. For exact implementation history, see
the git log.

# 1.0 — Public Release

Everything before 1.0 is building and hardening the core recorder:
settle the event contract, make the codebase easy to keep developing,
capture everything vanilla Factorio has to offer, generalize that
capture to handle mods, and finally stretch across multiple Factorio
versions. 1.0 is the point this mod is considered stable and complete
enough to publish to the Factorio mod portal and forums.

## v0.1 — Core Recording

The foundation: track what's moving (characters, vehicles, biters),
what's changing hands (inventories, fluids), and what's happening to
whom (attacks, effects), cropped to wherever combat is actually
happening. Establishes the [JSON schema](schema.md) downstream
tools can start building against.

<details>
<summary><strong>0.1.0</strong> — 2026-08-21</summary>

**Added**
- Recording turns on for a chunk only once a player (on foot, driving,
  piloting a vehicle, or an unmanned autopilot spidertron) is actually
  near a fight there, so idle bases and unseen biters are never
  recorded.
- Mod settings for combat detection radius, zone timeout, and a full
  recording mode that disables cropping entirely.
- Player and vehicle deaths are logged as scoreboard events, with
  respawn marked as a "goal reset" - a sports-replay framing for combat
  outcomes.
- Chunk snapshots capture every building, turret, wall, and nest
  automatically on first visit, including modded ones, instead of
  needing a maintained list of "interesting" entity types.
- Weapon and stream impacts record the specific projectile/stream that
  hit.
- Vehicles get the same inventory tracking as players.
- Combat, construction, and logistic robots are tracked as mobile
  entities; belts, chests, corpses, and inserter hands physically on the
  battlefield report their contents too.
- Kills are classified by hostile kind and size.
- Nests are grouped into rough bases by proximity, and biters/spitters
  report which group and nest they belong to, so a viewer can render an
  attack party or a nest's offspring as one object.
- **Resources feeding a fight have strategic value even before they're
  physically present in the battlefield's own chunks.** Belt and
  inserter chains, fluid networks (pipes, tanks, flamethrower fuel), and
  reachable logistics networks (storage/provider/requester chests) are
  all back-traversed outward from a zone - trading some performance for
  that accuracy - with close hops tracked exactly and distant hops
  rolled up into a compact per-direction summary.
- Ground items dropped by a player are tracked from creation to removal,
  the same way a corpse's contents are tracked from death to decay.

**Fixed**
- Recording no longer resets when mod settings change mid-campaign.
- Full recording mode's zones correctly stop recording again after the
  setting is turned back off.
- Reduced memory growth during long sessions.
- Large recordings export noticeably faster.

</details>

<details open>
<summary><strong>0.1.1</strong> — in progress</summary>

Consistency cleanup and closing the schema-accuracy gaps found while
writing `docs/schema.md`. No new tracked data. Not yet released; kept
open by default here since it isn't done yet.

**Changed**
- Centralized composite-key building (`script/keys.lua`) and owner-key
  construction (`vehicle_`/`container_`/`robot_`/`inserter_`/
  `ground_item_` prefixes) into two shared helpers, replacing hand-rolled
  concatenation that used to live independently in `combat_zones.lua`,
  `logistics.lua`, `tracker.lua`, and `item_chains.lua`.
- Standardized `pcall` result-variable naming across `tracker_events.lua`/
  `item_chains.lua`, and deduplicated `item_chains.lua`'s belt/inserter
  fallback search into one shared helper.
- Promoted nest cluster radius to a real user-facing setting (it directly
  shapes recorded data, like combat radius does); moved the battlefield
  marker's purely-cosmetic constants (redraw cadence, TTL, line styling)
  behind `Config` instead of leaving them hardcoded.
- Routed `control.lua`'s backfill/flush tick-alternation and flush
  stagger fraction through named `Config` getters instead of inline
  magic numbers; trimmed `config.lua`'s multi-round tuning-history
  comments down to a pointer at git history.
- `docs/schema.md` now documents fields it was missing (`chunk_snapshot`/
  `item_distribution`'s `chunk`/`surface` wrapper, `player_respawn`'s
  `force`, `damage_event`'s `target_type`/`position`) and names the
  literal JSON keys for its list-shaped fields instead of describing them
  in prose.

**Removed**
- `score_update` - keeping a running per-force death tally isn't this
  recorder's job. `death_event` already names the victim's force and,
  when known, the killer's, which is the attribution a downstream tool
  actually needs; `tools/inspect_replay.py`'s scoreboard summary is now
  computed straight from `death_event` instead of a dedicated event.

**Planned (not yet implemented)**
- `fluid_chains.lua` can't recover which exact fluidbox index a
  connection belongs to, so a discovered neighbor has its *entire* index
  range enqueued rather than just the connected one - a real precision
  loss for any entity with independent multi-fluidbox sides (e.g. a
  pump), pending a confirmed reverse-index lookup.
- `fluid_chains.lua` also mutes (rather than resolves) a real engine
  inconsistency where `entity.fluids_count` over-reports valid indices
  for some entity types - logged once per entity name, then silently
  skipped from there on.
- `inspect_replay.py`'s battlefield-cluster lookup keys on chunk
  coordinates alone, dropping the surface - activity on two surfaces
  that happen to share chunk coordinates can be misattributed to the
  wrong cluster.

</details>

## v0.2 — Development Process

Unreleased. Not about new tracked data - about making sure development
can keep moving without friction:

- Factorio-API-specific code (prototype names, defines, API shapes) gets
  isolated into its own layer instead of being spread through every
  module, in prep for the per-version adapters v0.5 will need - without
  committing to multi-version support yet.
- A confirmed way to drive recording through the headless Factorio
  client, so a replay can be regenerated without a graphical session.
- Re-running the same recorded replay multiple times to see how much
  more can be extracted from a single session, rather than treating each
  recording as a one-shot capture.
- Turning the testing checklist into a reusable "ideal replay" fixture -
  a known-good recording exercising every event type, kept around for
  testing going forward instead of re-generated by hand each time.

### Open design questions

Flagged for discussion, not decided:

- **Zone/chunk granularity.** A battlefield is usually a cluster of
  conjoined chunks, but today each chunk tracks its own independent
  activity and expiry. Should a zone's snapshot extend to its quiet
  interior chunks, and should the whole zone's expiry timer pool across
  its chunks rather than expiring piecemeal - while still keeping
  per-tick recording itself event-driven and lean for chunks with
  nothing happening? Performance vs. accuracy, not yet decided.
- **Repetitive/low-value zones.** Should a base's fortified perimeter
  keep getting recorded indefinitely just because a player passes near
  it, even when nothing's happening there? Filtering that out might not
  be a decision this mod should make on the user's behalf - but the
  tooling to let someone discard macro-area or low-value zone data after
  the fact should exist either way.
- **Endgame tools changing combat's shape.** Artillery and similar
  endgame tools turn combat from reactive (waiting for an attack) to
  offensive (walls advancing on nests) without the player necessarily
  being nearby. Same question as above: something this mod filters, or
  something downstream tooling should let a user opt in/out of for
  artillery-triggered chunks specifically?
- **Zone activation radius and biter pathing.** Should activating a zone
  also pull in nearby nests/bases within some radius, so a fight that
  draws reinforcements from a nearby cluster doesn't miss them? This
  needs to be pathing-aware, not just distance-based - a nest cut off on
  a sea-locked island within that radius can't actually reach the fight
  and shouldn't count.
- **Belt/inserter rollup vs. delivery-rate estimation.** The current
  far-hop rollup sums what's physically sitting in the chain right now.
  Estimating delivery rate instead (how much is arriving over time)
  might be more useful in some cases - though it doesn't translate to
  fluids, which share their levels proportionally across a segment
  rather than moving in discrete units. Worth reconsidering alongside
  the chain-walk approach, not a replacement for it yet.

## v0.3 — Full Vanilla Coverage

Unreleased. The goal: record every prototype and data point vanilla
Factorio 2.0.76 has to offer - no mod-compatibility work yet, just
closing what the 0.1 testing checklist flagged as gaps:

- **Landmines** - not confirmed whether this mod tracks them at all
  (damage attribution, or even placement).
- **Flame damage attribution** - a fire patch's creation/expiry is
  tracked, but not whether standing in it generates its own damage
  events the way a direct hit does, or whether fire damage bypasses that
  path entirely.
- **Capsules** - poison capsules, slowdown capsules, and defender/
  distractor/destroyer combat robots thrown by the player aren't
  exercised or confirmed tracked anywhere yet.
- **Terrain/obstacle completeness** - trees, rocks, cliffs, and plain
  ground/water tiles aren't currently distinguished as combat-relevant
  obstacles the way buildings are; neither are non-combat buildings,
  beyond being generically dumped as statics.
- **Electricity** - laser turrets, non-burner inserters, pumps, and
  roboports all need a real electric network to operate; unconfirmed
  whether anything about them behaves differently unpowered vs. powered
  as far as this mod's tracking goes.
- **Laser turrets** - not exercised anywhere yet; unconfirmed whether
  their damage/destruction is tracked the same way gun/flamethrower
  turrets are.
- **Health regeneration** - neither the player's nor biters' passive
  regen produce any event today; unconfirmed whether either is tracked
  at all, or how it'd be distinguished from healing/repair effects if
  so.
- **Repairs** - repair packs and construction-bot auto-repair aren't
  exercised anywhere; unconfirmed whether a repaired entity's health
  increase is tracked as its own event or is indistinguishable from any
  other health change.
- **Status effects** - a player gooed/slowed by acid, or a biter slowed
  by a capsule, aren't exercised anywhere; unconfirmed whether either is
  tracked as a distinct event/state or just shows up as the underlying
  `damage_event`.

## v0.4 — Mod-Agnostic Detection

Unreleased. Expands the prototype detection system built for v0.3's
vanilla pass so it holds up against mods instead of just vanilla data -
automating official API polling where possible so the mod needs less
hand-maintained knowledge of exact prototype names/fields, and handling
Space Age and the quality system as the first real test of that
generalization. Lays the groundwork v0.5's multi-version adapters will
build on, without committing to multi-version support itself yet.

## v0.5 — Multi-Version Support

Unreleased. The payoff for the hardening done in v0.2-v0.4: targeting
multiple Factorio versions (e.g. 2.1, 2.0.76, 1.1, 0.16) via small
per-version adapters, since a replay is tied to the exact version it was
recorded on and most replays anyone has aren't on the latest version.
Likely means maintaining more than one branch, with the release page
offering builds for each supported target version. This is the hard
problem the rest of the roadmap is building up to.
