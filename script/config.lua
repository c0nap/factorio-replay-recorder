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

return Config
