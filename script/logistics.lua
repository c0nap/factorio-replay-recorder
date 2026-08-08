-- script/logistics.lua
-- Captures "storage within logistic reach of the battlefield" (design
-- doc point 8): once per newly-touched chunk, finds every logistics
-- network whose construction (roboport) range reaches into that chunk,
-- and records the storage/provider/requester containers it owns, along
-- with their contents at that moment.
--
-- This is a one-time capture alongside the rest of the chunk snapshot,
-- not something diffed every tick like player/vehicle inventories. A
-- single logistics network can span an entire base, so continuously
-- tracking every container on it forever would work directly against the
-- "don't record what's far from the fight" goal the cropping system
-- exists for - a snapshot of what's reachable when the fight starts is
-- the intended scope here, not a live feed of the whole base's economy.
local TrackerEvents = require("script.tracker_events")

local Logistics = {}

-- LuaSurface.find_logistic_networks_by_construction_area takes a single
-- point, not an area, so a chunk's roboport coverage is approximated by
-- sampling its corners and center - cheap since this only runs once, the
-- first time a chunk is snapshotted.
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
            end
        end
    end
    return by_id
end

-- Container-like entities (chests, both plain and logistic variants)
-- expose their contents through defines.inventory.chest. pcall-guarded
-- because a network's `requesters` aren't limited to chests - a player
-- character with personal logistics requests is itself a requester point
-- owner, and doesn't have a chest inventory to read.
local function container_contents(entity)
    local ok, inv = pcall(function() return entity.get_inventory(defines.inventory.chest) end)
    if not ok or not inv then return nil end
    local contents = TrackerEvents.flatten_contents(inv.get_contents())
    return next(contents) and contents or nil
end

-- Caps how many containers get recorded per chunk snapshot. A logistics
-- network can span an entire base; without a cap, one chunk touching a
-- large, fully-connected network could dump thousands of chests into a
-- single event. This is a deliberate, documented tradeoff in favor of
-- file size, not an oversight.
local MAX_CONTAINERS = 300

local ROLES_BY_FIELD = {storages = "storage", providers = "provider", requesters = "requester"}

-- Returns true if the cap was hit (list is incomplete).
local function collect_containers(network, out, seen)
    for field, role in pairs(ROLES_BY_FIELD) do
        for _, entity in ipairs(network[field]) do
            if #out >= MAX_CONTAINERS then return true end
            -- A player character can itself own a requester point
            -- (personal logistics requests), but the player's inventory
            -- is already tracked separately and in more detail via
            -- TrackerEvents' player inventory_delta - listing it again
            -- here would just be redundant, mostly-empty noise.
            if entity.valid and entity.type ~= "character" and not seen[entity.unit_number] then
                seen[entity.unit_number] = true
                table.insert(out, {
                    name = entity.name,
                    position = entity.position,
                    role = role,
                    contents = container_contents(entity),
                })
            end
        end
    end
    return false
end

-- Returns an array of per-network summaries reachable from `area`, for
-- each force name in `force_names` (a set, {name = true}):
-- {network_id, force, available_logistic_robots,
--  available_construction_robots, containers, truncated?}
function Logistics.context_for_area(surface, area, force_names)
    local networks = find_networks(surface, area, force_names)
    local result = {}

    for _, network in pairs(networks) do
        local containers = {}
        local seen = {}
        local truncated = collect_containers(network, containers, seen)

        table.insert(result, {
            network_id = network.network_id,
            force = network.force.name,
            available_logistic_robots = network.available_logistic_robots,
            available_construction_robots = network.available_construction_robots,
            containers = containers,
            truncated = truncated or nil,
        })
    end

    return result
end

return Logistics
