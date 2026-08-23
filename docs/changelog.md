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

*MVP*

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

</details>

<details>
<summary><strong>0.1.1</strong> — 2026-08-23</summary>

*Housekeeping*

Consistency and accuracy - no new tracked data.

**Changed**
- Now targets Factorio 2.0.77 (was 2.0.76). A small patch, and the last
  2.0.x release before 2.1 development began, so it rounds out the
  version this mod is built against.

**Fixed**
- Fluid tracking near flamethrower turrets and other multi-connection
  buildings (like pumps) is now accurate. It previously could suppress
  fluid data around a flamethrower turret, and could merge a pump's two
  independent sides into a single reading instead of keeping them
  separate.
- Every mod setting now shows a proper name and description in
  Factorio's settings menu - several previously showed only their raw
  internal ID (e.g. `rrec-chain-near-hops`).
- The schema reference now lists every field several event types
  actually contain - `chunk_snapshot`, `item_distribution`,
  `player_respawn`, and `damage_event` were all missing some.

**Added**
- A "Nest cluster radius" setting, so how nearby nests get grouped into
  a rough "base" in a chunk snapshot is now tunable, the same way combat
  detection radius already was.

**Removed**
- The `score_update` event. A running per-force death count isn't this
  recorder's job - `death_event` already names the victim's force and,
  when known, the killer's, so that attribution is still available. If
  you use `score_update` downstream, switch to reading force off
  `death_event` instead - `tools/inspect_replay.py` already does.
  - The testing checklist's check for `score_update` was removed with
    it, so a checklist run against 0.1.1 correctly shows 29/29 passing
    instead of 30/30. Expected, not a regression.

**Internal / code changes**

Implementation detail, not user-facing - kept here for anyone working
on the mod itself:

- `entity.fluids_count` counts some non-fluidbox storages (e.g. a
  turret's internal ammo buffer) that `entity.fluidbox` has no slot for
  - `fluid_chains.lua` now bounds every fluidbox loop with
  `#entity.fluidbox` instead, and walks the pipe network via
  `LuaFluidBox::get_pipe_connections` for the exact connected index
  instead of guessing a neighbor's whole range.
- Centralized composite-key building (`script/keys.lua`) and owner-key
  construction (`TrackerEvents.*_owner_key`) into shared helpers,
  replacing hand-rolled string concatenation spread across several
  files.
- Standardized `pcall` result-variable naming, and deduplicated a
  repeated search pattern in `item_chains.lua`.
- Routed remaining hardcoded tuning constants (backfill/flush timing,
  battlefield-marker styling) through `Config`; trimmed `config.lua`'s
  tuning-history comments.
- Removed dead code: `CombatZones.expire_permanent_zones` (no released
  version of this mod ever produced the state it cleaned up), and two
  functions only ever called within their own file are now local
  instead of public.
- Assorted stale-comment cleanup, including a leftover "goal reset"
  sports metaphor from the removed scoring framing.

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
- **Discovering which inserters service a distant chest.** Chests have
  no "what's connected to me" query, so `servicing_inserters` searches a
  configurable tile radius around a chest and filters candidates by
  their exact (confirmed) `pickup_target`/`drop_target`. That radius is
  the only heuristic part - and it's a harder tradeoff than it looks:
  a persistent reverse index built as inserters are discovered elsewhere
  (chunk snapshots, physical zone scans, chain walks) sounds like the
  "real" fix, but a chest reached via distant chain-walking is
  specifically one nothing else has touched yet, so its servicing
  inserter would often be missing from that index too - a live spatial
  query at the moment of need may genuinely be the right tool here. A
  full, unbounded per-lookup search isn't free either given how much
  effort already went into keeping full-recording-mode scans bounded
  elsewhere in this mod. One option that doesn't need new information:
  bound the search by the chest's containing chunk (already a meaningful
  unit everywhere else in this mod) instead of an arbitrary tile count -
  larger and more consistent than the current radius, but still a bound,
  not a real fix. Not implemented pending a decision on which tradeoff
  to take.

## v0.3 — Full Vanilla Coverage

Unreleased. The goal: record every prototype and data point vanilla
Factorio 2.0.77 has to offer - no mod-compatibility work yet, just
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

- **Multi-surface accuracy.** Most events don't carry an explicit
  surface field (only `chunk_snapshot` and `item_distribution` do), so
  downstream tooling like `tools/inspect_replay.py`'s battlefield
  clustering currently assumes a single surface - harmless today, but
  worth revisiting once Space Age's multiple real surfaces make that
  assumption wrong in practice.

## v0.5 — Multi-Version Support

Unreleased. The payoff for the hardening done in v0.2-v0.4: targeting
multiple Factorio versions (e.g. 2.1, 2.0.77, 1.1, 0.16) via small
per-version adapters, since a replay is tied to the exact version it was
recorded on and most replays anyone has aren't on the latest version.
Likely means maintaining more than one branch, with the release page
offering builds for each supported target version. This is the hard
problem the rest of the roadmap is building up to.

<!--
- Structure: an eventual major version gets a top-level header, with each mid version
  (v0.1, v0.2, ...) as a header under it. Once a mid version has shipped, each point
  release (0.1.0, 0.1.1, ...) gets its own collapsed-by-default expandable section
  under it. An unreleased mid version just needs its header and a short description —
  no expandable until something ships. All major versions should have a brief preface
  describing their overall goal.
- Goals and user-facing changes only, never a commit list. Propose mechanisms,
  refactors, and design changes, not how to implement them.
- Bug fixes belong here when they're user-facing. Internal corrections — a clarified
  preference, a fixed misconception, a comment, a changed function signature — don't.
- Keep it short. Implementation detail is for whoever does the work, not this
  document.
-->

