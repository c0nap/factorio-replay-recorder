-- script/config.lua
-- Single point of access for the user-configurable mod settings (see
-- settings.lua). Nothing else in the mod should read `settings.global`
-- directly, so a setting only ever has to be looked up by name in one place.

local Config = {}

function Config.full_recording_mode()
    return settings.global["rrec-full-recording-mode"].value
end

function Config.combat_radius()
    return settings.global["rrec-combat-radius"].value
end

function Config.zone_timeout_ticks()
    return settings.global["rrec-zone-timeout-seconds"].value * 60
end

-- How often "distant" data (logistics network contents, far-chain item
-- rollups, fluid segments) is sampled. Deliberately slow and shared
-- across all three, since none of them need per-tick freshness the way
-- something physically in a zone does - see script/logistics.lua,
-- script/item_chains.lua, script/fluid_chains.lua.
function Config.distant_sample_interval_ticks()
    return settings.global["rrec-distant-sample-interval-seconds"].value * 60
end

-- How long a logistics network keeps counting as "active" (eligible for
-- Tier 2 sampling) after it was last seen with any robots, to smooth over
-- robots being temporarily mid-flight rather than flickering the network
-- in and out of relevance every sample.
function Config.network_activity_window_ticks()
    return settings.global["rrec-network-activity-window-seconds"].value * 60
end

-- Belt/inserter chain hops within this distance of a zone get precise
-- per-entity tracking; beyond it (up to chain_max_hops), entities are
-- rolled up into a compact directional summary instead - see
-- script/item_chains.lua.
function Config.chain_near_hops()
    return settings.global["rrec-chain-near-hops"].value
end

-- Absolute cap on how many hops a chain walk (belt/inserter or fluid
-- segment) will follow outward from a zone, regardless of near/far.
function Config.chain_max_hops()
    return settings.global["rrec-chain-max-hops"].value
end

-- Search radius (in tiles) used to find which inserters service a given
-- chest - chests have no "what am I connected to" query of their own, and
-- there's no documented max-inserter-reach constant, so this stays a
-- user-tunable candidate-generation bound rather than a hardcoded guess.
-- See script/item_chains.lua's servicing_inserters.
function Config.inserter_search_radius()
    return settings.global["rrec-inserter-search-radius"].value
end

-- How many already-generated chunks CombatZones.process_backfill_queue()
-- activates (scans tiles/statics/logistics for) per tick when full
-- recording mode's backfill queue is draining - see
-- script/combat_zones.lua. Turning full recording mode on mid-save with
-- hundreds of existing chunks used to scan+dump every single one of them
-- synchronously in the one tick the setting changed, which is exactly
-- what froze the game for multiple seconds; draining a bounded number per
-- tick instead spreads that same total cost across many ticks so no
-- single tick pays for more than this many chunks' worth of engine calls.
-- Tuning history (why the default landed at 2) is in git log/PR history,
-- not here. NOTE: an existing save keeps whatever value this setting was
-- last explicitly set to, even across a mod update that changes this
-- default - if a real run doesn't show the expected drop, check
-- diagnostics_enabled's log output (includes backfill_remaining) to
-- confirm the ACTUAL in-effect value, not just this file's default.
function Config.chunk_backfill_per_tick()
    return settings.global["rrec-chunk-backfill-per-tick"].value
end

-- How often Exporter.flush() serializes the buffered event queue to
-- replay.json. Larger values batch more events into a single write (fewer,
-- bigger flushes); smaller values flush more often (more, smaller
-- flushes). Kept configurable rather than control.lua's previous hardcoded
-- 60-tick constant so a save that's still seeing single-tick stalls during
-- heavy combat can trade flush frequency against per-flush size without a
-- code change.
function Config.flush_interval_ticks()
    return math.max(1, math.floor(settings.global["rrec-flush-interval-seconds"].value * 60))
end

-- Gates script/diagnostics.lua's per-tick timing instrumentation. Off by
-- default - the profiler brackets it wraps every tick with, and the extra
-- diagnostics_tick event this produces every single tick, are only worth
-- paying for while actively chasing a performance problem.
function Config.diagnostics_enabled()
    return settings.global["rrec-diagnostics-enabled"].value
end

-- Gates script/battlefield_marker.lua's exterior-perimeter overlay. Off
-- by default - it's a visual aid for manual testing, not something a
-- routine recording needs running.
function Config.battlefield_marker_enabled()
    return settings.global["rrec-battlefield-marker-enabled"].value
end

-- Caps how many entries Exporter.flush() serializes+writes in a single
-- call, and (see control.lua's on_tick) triggers an early flush once
-- storage.replay_buffer crosses this size rather than waiting for the
-- next fixed-interval flush. Confirmed via real diagnostics data (not a
-- guess) that a single flush call writing an unbounded backlog - e.g. the
-- ~800 chunk_snapshot events a full-recording backfill burst can queue up
-- before the first flush even fires - is what actually froze the game for
-- multiple seconds, not the backfill's own per-chunk scanning. See
-- control.lua's on_tick for the other half of this fix: a flush is
-- alternated onto its own tick, never sharing one with a backfill scan.
-- Tuning history (why the default landed at 2) is in git log/PR history,
-- not here. NOTE: an existing save keeps whatever value this setting was
-- last explicitly set to, even across a mod update that changes this
-- default - if a real run doesn't show the expected drop, check
-- diagnostics_enabled's log output (includes buffer_size) to confirm the
-- ACTUAL in-effect value, not just this file's default.
function Config.max_buffered_events()
    return settings.global["rrec-max-buffered-events"].value
end

-- Radius (tiles) single-linkage nest clustering uses to group spawners
-- captured in the same chunk_snapshot into rough "bases" - see
-- script/combat_zones.lua's cluster_spawners. User-tunable like
-- combat_radius/inserter_search_radius since it directly shapes what a
-- viewer sees (the `cluster` field on spawner statics), not a cosmetic
-- constant.
function Config.nest_cluster_radius()
    return settings.global["rrec-nest-cluster-radius"].value
end

-- Internal tuning constants below this point are NOT backed by a mod
-- setting - unlike everything above, none of them affect what ends up in
-- replay.json, so there's nothing here worth exposing in the settings
-- menu. They're centralized here anyway so nothing in the mod hardcodes
-- its own copy.

-- Backfill/flush tick alternation (see control.lua's on_tick): every Nth
-- tick alternates between draining the full-recording backfill queue and
-- checking for a threshold-triggered flush, so the two heaviest per-tick
-- operations never land in the same tick.
function Config.backfill_flush_alternation_period()
    return 2
end

-- The fixed-interval flush is offset by this fraction of its own period
-- rather than checked at game.tick % interval == 0 directly, so it
-- doesn't land on the same tick as the distant-sample interval every
-- single time when the two are configured to the same period - see
-- control.lua's on_tick.
function Config.flush_stagger_fraction()
    return 0.5
end

-- script/battlefield_marker.lua's redraw cadence, marker lifetime, and
-- line styling - purely cosmetic (the marker is a manual-testing visual
-- aid with no effect on what gets recorded, see the README), so these
-- stay plain constants rather than settings.global-backed like the marker
-- on/off toggle itself (Config.battlefield_marker_enabled()).
function Config.battlefield_marker_recompute_interval_ticks()
    return 60
end

function Config.battlefield_marker_time_to_live_ticks()
    return 90
end

function Config.battlefield_marker_line_color()
    return {r = 0.2, g = 1, b = 1, a = 1}
end

function Config.battlefield_marker_line_width()
    return 3
end

return Config
