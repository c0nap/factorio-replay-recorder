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

return Config
