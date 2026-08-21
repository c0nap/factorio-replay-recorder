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
happening. Establishes the [JSON schema](docs/schema.md) downstream
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

<details>
<summary><strong>0.1.1</strong> — planned</summary>

Projected housekeeping pass - consistency cleanup and paying down a
couple of documented workarounds, no new tracked data. Not yet released;
listed here ahead of time so it doesn't get lost.

**Housekeeping**
- Standardize chunk/network composite-key building into one shared
  helper instead of `combat_zones.lua`, `logistics.lua`, and others each
  formatting their own `<surface>_<x>_<y>`-style keys inline.
- Centralize the `vehicle_`/`container_`/`robot_`/`inserter_` owner-key
  prefixing (currently repeated independently in `tracker.lua`,
  `item_chains.lua`, and `logistics.lua`) alongside the inventory-diffing
  helpers in `tracker_events.lua` that actually consume those keys.
- Standardize `pcall` result-variable naming - `tracker_events.lua`,
  `item_chains.lua`, and `fluid_chains.lua` each use a different
  ok/value naming order for the same guard pattern.
- Move the remaining hardcoded tuning constants (`NEST_CLUSTER_RADIUS`,
  and `battlefield_marker.lua`'s recompute interval/TTL/line styling)
  behind `Config`, matching how every other tunable in the mod is
  exposed.
- Route the backfill/flush tick-alternation and the flush/distant-sample
  offset in `control.lua`'s `on_tick` through `Config` instead of the
  inline magic numbers they use today.
- Standardize `storage.*` nil-guarding - `tracker_events.lua`'s diff
  helpers each defensively re-initialize their own storage table before
  use, while most of `combat_zones.lua`/`tracker.lua` assume
  `Init.ensure_storage` already ran.
- Share one helper between `item_chains.lua`'s `inserter_targets()` and
  `servicing_inserters()` - both independently implement the same pcall
  + `find_entities_filtered` fallback pattern.
- Make `data.lua` log a mismatch the same way `data-updates.lua` already
  does, instead of silently returning on the same "not a table" case.
- Trim `config.lua`'s tuning-history comments (`chunk_backfill_per_tick`,
  `max_buffered_events`) down to a one-line pointer - they currently
  narrate several rounds of "lowered from X to Y" that belong in git
  history, not a getter's docstring.
- Switch `verify_checklist.py`'s import of `inspect_replay.py` from a
  manual `sys.path` insert to a normal package-relative import.
- Remove `inspect_logs.py`'s unreachable `None` fallback entry in
  `DURATION_UNIT_TO_MS` - the regex group it guards against is never
  actually optional.

**Known workarounds to revisit**
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

### Discrepancies between `docs/schema.md` and the current code

Found while auditing the schema doc against the real event payloads for
this PR. None of these are wrong claims - they're gaps where the schema
describes a subset of what an event actually carries. Worth closing
before downstream consumers start relying on the doc as-is:

- `chunk_snapshot`'s top-level `chunk` (`[chunk_x, chunk_y]`) and
  `surface` (surface name) fields aren't documented - only `tiles`,
  `statics`, and `logistics` are.
- `item_distribution` is documented as just its `entries` array; the
  same top-level `chunk`/`surface` wrapper fields `chunk_snapshot` has
  aren't mentioned.
- `score_update`'s actual payload also carries `entity`, `entity_type`,
  and `position` for what died - the schema only mentions force, killer,
  and the running death count.
- `player_respawn` also carries `force`, not just player index and
  position.
- `damage_event` also carries `target_type` and `position` - the schema
  only mentions target, damage, `dealer`, and `dealt_by`.
- More generally, the schema describes several events' list-shaped
  fields (`inventory_delta`/`fluid_delta`'s changes, `belt_contents`'
  per-belt entries, `mobile_positions`' per-entity fields) in prose
  rather than by their literal JSON key names - worth making the whole
  doc field-exact rather than descriptive, since it's meant to be a
  strict contract.

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
