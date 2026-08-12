-- script/logistics.lua
-- "Storage within logistic reach of the battlefield" (design doc point 8),
-- split into two parts that mirror the rest of the mod's near/far split:
--
-- - `Logistics.context_for_area` runs once per newly-touched chunk (from
--   combat_zones.lua), and captures the STRUCTURAL ROSTER of a reachable
--   network - which containers exist, where, in what role - as part of
--   the one-time chunk_snapshot. No contents here; a roster doesn't go
--   stale the way contents do.
-- - `Logistics.tick` runs on a slow, configurable interval (see
--   script/config.lua), and diffs the CONTENTS of containers belonging to
--   networks that are both reachable from a currently active zone and
--   have recently shown robot activity - the "eligibility" gating this
--   needed, since a network's construction area reaching a zone doesn't
--   mean it's actually doing anything right now (a powered-down roboport,
--   or one with zero robots, has zero combat relevance despite being in
--   range).
--
-- There used to be a flat cap (300 containers) on the one-time roster to
-- bound file size. That's gone: a network reachable from the fight has
-- combat relevance regardless of size, so capping it drops real
-- information. Cost is bounded instead by NOT re-walking the whole
-- network every tick (only once per sample interval) and by diffing
-- contents (an unchanged container costs ~0 bytes between samples) -
-- rate, not size.
local TrackerEvents = require("script.tracker_events")
local Config = require("script.config")

local Logistics = {}

-- LuaSurface.find_logistic_networks_by_construction_area takes a single
-- point, not an area, so a chunk's roboport coverage is approximated by
-- sampling its corners and center.
local function sample_points(area)
    local tl, br = area[1], area[2]
    local mid = {x = (tl.x + br.x) / 2, y = (tl.y + br.y) / 2}
    return {tl, {x = br.x, y = tl.y}, {x = tl.x, y = br.y}, br, mid}
end

local function find_networks(surface, area, force_names)
    local by_id = {}
    for force_name in pairs(force_names) do
        for _, point in ipairs(sample_points(area)) do
            local ok, found = pcall(function()
                return surface.find_logistic_networks_by_construction_area(point, force_name)
            end)
            if ok and found then
                for _, network in ipairs(found) do
                    if network.valid then
                        by_id[network.network_id] = network
                    end
                end
            elseif not ok then
                log("[replay-recorder] Logistics: find_logistic_networks_by_construction_area failed: " .. tostring(found))
            end
        end
    end
    return by_id
end

local ROLES_BY_FIELD = {storages = "storage", providers = "provider", requesters = "requester"}

-- Roster only: which containers exist, where, in what role. No contents -
-- those are read separately (via Tracker's per-tick physical scan if the
-- container turns out to be physically inside a zone, or via
-- Logistics.tick below if it's genuinely distant).
local function collect_containers(network, out, seen)
    for field, role in pairs(ROLES_BY_FIELD) do
        for _, entity in ipairs(network[field]) do
            -- A player character can itself own a requester point
            -- (personal logistics requests), but the player's inventory
            -- is already tracked separately and in more detail via
            -- TrackerEvents' player inventory_delta - listing it again
            -- here would just be redundant, mostly-empty noise.
            if entity.valid and entity.type ~= "character" and not seen[entity.unit_number] then
                seen[entity.unit_number] = true
                table.insert(out, {
                    unit_number = entity.unit_number,
                    name = entity.name,
                    position = entity.position,
                    role = role,
                })
            end
        end
    end
end

-- One-time structural roster, called from combat_zones.lua's chunk
-- snapshot. Returns an array of per-network summaries reachable from
-- `area`, for each force name in `force_names` (a set, {name = true}):
-- {network_id, force, robots_at_capture = {logistic_robots,
-- construction_robots}, containers}. `robots_at_capture` is explicitly a
-- one-time snapshot value, not authoritative afterward - the ongoing
-- eligibility tracking in Logistics.tick is what's authoritative going
-- forward.
function Logistics.context_for_area(surface, area, force_names)
    local networks = find_networks(surface, area, force_names)
    local result = {}

    for _, network in pairs(networks) do
        local containers = {}
        collect_containers(network, containers, {})

        table.insert(result, {
            network_id = network.network_id,
            force = network.force.name,
            robots_at_capture = {
                logistic_robots = network.all_logistic_robots,
                construction_robots = network.all_construction_robots,
            },
            containers = containers,
        })
    end

    return result
end

-- Tier 2: for every logistics network reachable from a currently active
-- zone that's shown recent robot activity, diff the contents of its
-- containers - except ones physically inside an active zone right now,
-- since Tracker.tick()'s per-tick physical scan already covers those.
-- Takes CombatZones' is_zone_active/chunk_area as parameters rather than
-- requiring script.combat_zones directly: combat_zones.lua already
-- requires this module (for the one-time roster above), and Lua's
-- require() doesn't handle circular requires safely, so the dependency
-- only runs one way - this module never requires combat_zones.lua back.
--
-- `all_logistic_robots`/`all_construction_robots` (not `available_*`) is
-- deliberate: `available_*` dips every time a bot is mid-delivery, which
-- would make a busy, perfectly-active network flicker in and out of
-- eligibility. `all_*` is total network membership and only changes when
-- a bot is actually built or destroyed, so it doesn't flicker at all -
-- no smoothing needed on top of it.
function Logistics.tick(active_zones, is_zone_active, chunk_area_fn)
    storage.active_networks = storage.active_networks or {}

    -- 1. Sweep: drop networks that haven't shown activity within the
    -- window. A network seen with 0 robots this pass simply isn't
    -- refreshed below - it rides out its existing window instead of being
    -- dropped instantly. That's the hysteresis.
    for key, entry in pairs(storage.active_networks) do
        if game.tick >= entry.expires_at then
            storage.active_networks[key] = nil
        end
    end

    -- 2. Re-sample every currently active zone's reachable networks, and
    -- refresh the eligibility window for the ones still doing something.
    local networks_this_tick = {}
    for zone_id, zone in pairs(active_zones) do
        local force_names = storage.chunk_force_names[zone_id]
        if force_names then
            local area = chunk_area_fn(zone.chunk_x, zone.chunk_y)
            local found = find_networks(zone.surface, area, force_names)
            for network_id, network in pairs(found) do
                local key = zone.surface.name .. "_" .. network.force.name .. "_" .. network_id
                networks_this_tick[key] = network

                if (network.all_logistic_robots + network.all_construction_robots) > 0 then
                    storage.active_networks[key] = {
                        expires_at = game.tick + Config.network_activity_window_ticks()
                    }
                end
            end
        end
    end

    -- 3. For every network still eligible (post-sweep/refresh) that we
    -- have a live reference for this tick, diff its non-physical
    -- containers.
    local seen = {}
    for key in pairs(storage.active_networks) do
        local network = networks_this_tick[key]
        if network and network.valid then
            for field, role in pairs(ROLES_BY_FIELD) do
                for _, entity in ipairs(network[field]) do
                    if entity.valid and entity.type ~= "character"
                        and not seen[entity.unit_number]
                        and not is_zone_active(entity.surface, entity.position) then
                        seen[entity.unit_number] = true
                        TrackerEvents.log_inventory_delta(
                            "container_" .. entity.unit_number,
                            "container",
                            TrackerEvents.container_contents(entity)
                        )
                    end
                end
            end
        end
    end
end

return Logistics
