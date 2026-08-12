-- script/item_chains.lua
-- Long-distance "what's feeding this fight" tracking (design doc: belts
-- should record "the contents within inserter reach - inserters chain
-- adjacent storage entities"). Starting from belts/inserters physically
-- in an active zone, follows belt-to-belt connections and inserter
-- pickup/drop targets outward, well past the zone's own chunk boundary -
-- a real supply line can run hundreds of tiles and dozens of entities
-- from the fight it's feeding.
--
-- Close hops get the same precise per-entity tracking as anything
-- physically in a zone (reusing the exact belt_contents/inventory_delta
-- mechanisms Tracker's per-tick physical scan uses). Hops beyond a
-- configurable threshold are rolled up into a compact "roughly this many
-- of this item, this direction from the zone" summary instead of one
-- event per distant entity - both the near/far split and rolling up
-- rather than capping mirror script/logistics.lua's Tier 2 design, for
-- the same reason: a supply chain can be far larger than the fight it's
-- feeding, and dropping data loses information a faithful replay needs,
-- so precision falling off with distance is the fix instead of a cap.
--
-- Runs on the same slow, configurable interval as Tier 2 logistics
-- sampling (Config.distant_sample_interval_ticks) - walking the whole
-- chain every tick would be wasted work between the rare moments a
-- supply line's contents actually change.
local TrackerEvents = require("script.tracker_events")
local Exporter = require("script.exporter")
local Config = require("script.config")

local ItemChains = {}

local BELT_TYPES = {["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true, ["linked-belt"] = true}
local CONTAINER_TYPES = {["container"] = true, ["logistic-container"] = true}

-- Every pcall below guards confirmed API against a genuinely exotic/mid-
-- tick-invalid entity - a real failure here would be notable, not routine,
-- so it's worth a breadcrumb rather than silently vanishing into "the
-- chain walk just found nothing" the way it used to.
local function log_fail(context, err)
    log("[replay-recorder] ItemChains: " .. context .. " failed: " .. tostring(err))
end

-- `belt_neighbours`'s confirmed shape: {inputs = array[LuaEntity], outputs
-- = array[LuaEntity]} - the belt-connectable entities that feed into or
-- take from this one. `underground_belt_neighbour`/`linked_belt_neighbour`
-- are separate singular fields for the OTHER end of an underground/linked
-- belt pair, which belt_neighbours does not include.
local function belt_neighbour_entities(entity)
    local out = {}
    local ok, neighbours = pcall(function() return entity.belt_neighbours end)
    if ok and neighbours then
        for _, e in ipairs(neighbours.inputs or {}) do
            if e.valid then table.insert(out, e) end
        end
        for _, e in ipairs(neighbours.outputs or {}) do
            if e.valid then table.insert(out, e) end
        end
    elseif not ok then
        log_fail(entity.name .. ".belt_neighbours", neighbours)
    end

    -- Both of these fields only exist on their one matching entity type -
    -- reading either on a plain transport-belt/splitter isn't a failure to
    -- guard against, it's the overwhelmingly common case (every ordinary
    -- belt segment), confirmed by a real log showing it firing on every
    -- single transport-belt processed. Checking entity.type first avoids
    -- both the pcall overhead and the log spam that produced.
    if entity.type == "underground-belt" then
        local ok2, underground = pcall(function() return entity.underground_belt_neighbour end)
        if ok2 and underground and underground.valid then
            table.insert(out, underground)
        elseif not ok2 then
            log_fail(entity.name .. ".underground_belt_neighbour", underground)
        end
    end

    if entity.type == "linked-belt" then
        local ok3, linked = pcall(function() return entity.linked_belt_neighbour end)
        if ok3 and linked and linked.valid then
            table.insert(out, linked)
        elseif not ok3 then
            log_fail(entity.name .. ".linked_belt_neighbour", linked)
        end
    end

    return out
end

-- Inserters have pickup_target/drop_target (confirmed, read directly in
-- inserter_targets below); chests have no equivalent "what am I connected
-- to" query, so discovering which inserters service a given chest means
-- searching a radius around it and keeping only the ones that actually
-- target it - there's no documented max-inserter-reach constant to
-- compute an exact bound from, so this stays a deliberate, user-tunable
-- search radius (Config.inserter_search_radius(), default 3) rather than
-- a silently hardcoded number. The radius only generates candidates - the
-- actual correctness comes entirely from the pickup_target/drop_target
-- identity check below, which is confirmed API, not a guess.
local function servicing_inserters(entity)
    local ok, found = pcall(function()
        return entity.surface.find_entities_filtered{
            position = entity.position, radius = Config.inserter_search_radius(), type = "inserter"
        }
    end)
    if not ok then
        log_fail("find_entities_filtered (servicing_inserters) around " .. entity.name, found)
        return {}
    end

    local out = {}
    for _, inserter in ipairs(found) do
        if inserter.valid then
            local pt_ok, pickup = pcall(function() return inserter.pickup_target end)
            if not pt_ok then log_fail("inserter.pickup_target", pickup) end
            local dt_ok, drop = pcall(function() return inserter.drop_target end)
            if not dt_ok then log_fail("inserter.drop_target", drop) end
            if (pt_ok and pickup == entity) or (dt_ok and drop == entity) then
                table.insert(out, inserter)
            end
        end
    end
    return out
end

local function inserter_targets(entity)
    local out = {}
    local pt_ok, pickup = pcall(function() return entity.pickup_target end)
    if pt_ok and pickup and pickup.valid then
        table.insert(out, pickup)
    elseif not pt_ok then
        log_fail("entity.pickup_target", pickup)
    end

    local dt_ok, drop = pcall(function() return entity.drop_target end)
    if dt_ok and drop and drop.valid then
        table.insert(out, drop)
    elseif not dt_ok then
        log_fail("entity.drop_target", drop)
    end

    -- No direct target entity (e.g. dropping onto a bare belt tile rather
    -- than a specific entity) - fall back to whatever's physically at the
    -- pickup/drop position.
    if not (pt_ok and pickup) then
        local pos_ok, pos = pcall(function() return entity.pickup_position end)
        if not pos_ok then log_fail("entity.pickup_position", pos) end
        if pos_ok and pos then
            local ok, near = pcall(function() return entity.surface.find_entities_filtered{position = pos, radius = 0.5} end)
            if not ok then log_fail("find_entities_filtered at pickup_position", near) end
            if ok then
                for _, e in ipairs(near) do
                    if e.valid and e.unit_number ~= entity.unit_number then table.insert(out, e) end
                end
            end
        end
    end
    if not (dt_ok and drop) then
        local pos_ok, pos = pcall(function() return entity.drop_position end)
        if not pos_ok then log_fail("entity.drop_position", pos) end
        if pos_ok and pos then
            local ok, near = pcall(function() return entity.surface.find_entities_filtered{position = pos, radius = 0.5} end)
            if not ok then log_fail("find_entities_filtered at drop_position", near) end
            if ok then
                for _, e in ipairs(near) do
                    if e.valid and e.unit_number ~= entity.unit_number then table.insert(out, e) end
                end
            end
        end
    end

    return out
end

local function neighbours_of(entity)
    if BELT_TYPES[entity.type] then return belt_neighbour_entities(entity) end
    if entity.type == "inserter" then return inserter_targets(entity) end
    if CONTAINER_TYPES[entity.type] then return servicing_inserters(entity) end
    return {}
end

-- North/south/east/west (+ diagonals) relative to a zone's center, used
-- to bucket the far-hop rollup so "a ton of yellow ammo to the north" and
-- "a little red ammo to the south" (the motivating example) come out as
-- separate entries. Uses plain sign/magnitude comparisons rather than
-- atan2-style trig specifically to sidestep any doubt about
-- math.atan's argument order/availability across Lua versions.
local function direction_of(dx, dy)
    local adx, ady = math.abs(dx), math.abs(dy)
    local ns = dy < 0 and "north" or "south"
    local ew = dx < 0 and "west" or "east"
    if adx < ady * 0.5 then return ns end
    if ady < adx * 0.5 then return ew end
    return ns .. ew
end

local function belt_line_contents(entity)
    local ok, out = pcall(function()
        local contents = {}
        for i = 1, entity.get_max_transport_line_index() do
            for name, count in pairs(TrackerEvents.flatten_contents(entity.get_transport_line(i).get_contents())) do
                contents[name] = (contents[name] or 0) + count
            end
        end
        return contents
    end)
    if not ok then log_fail(entity.name .. " belt line contents", out) end
    return ok and out or {}
end

-- Adds this entity's contents into the rollup accumulator, bucketed by
-- (item name, rough direction from the zone center).
local function accumulate_far(entity, zone_center, rollup)
    local contents
    if BELT_TYPES[entity.type] then
        contents = belt_line_contents(entity)
    elseif CONTAINER_TYPES[entity.type] then
        contents = TrackerEvents.container_contents(entity)
    elseif entity.type == "inserter" then
        contents = TrackerEvents.held_stack_contents(entity)
    else
        return
    end

    local dir = direction_of(entity.position.x - zone_center.x, entity.position.y - zone_center.y)
    for item, count in pairs(contents) do
        local key = item .. "|" .. dir
        local bucket = rollup[key]
        if not bucket then
            bucket = {item = item, direction = dir, approx_count = 0, sum_x = 0, sum_y = 0, entities_sampled = 0}
            rollup[key] = bucket
        end
        bucket.approx_count = bucket.approx_count + count
        bucket.sum_x = bucket.sum_x + entity.position.x
        bucket.sum_y = bucket.sum_y + entity.position.y
        bucket.entities_sampled = bucket.entities_sampled + 1
    end
end

-- Walks the chain outward from `seeds` (belts/inserters already
-- physically in the zone), tracking near hops precisely and rolling up
-- far hops, up to Config.chain_max_hops(). `is_zone_active` excludes
-- anything already covered by another active zone's own Tier 1 scan,
-- avoiding double-tracking where two zones' supply lines overlap.
local function walk_chain(seeds, zone_center, is_zone_active)
    local near_hops = Config.chain_near_hops()
    local max_hops = Config.chain_max_hops()
    local visited = {}
    local queue = {}
    local near_belts, near_containers, near_inserters = {}, {}, {}

    for _, seed in ipairs(seeds) do
        if seed.valid and seed.unit_number then
            visited[seed.unit_number] = true
            table.insert(queue, {entity = seed, hop = 0})
        end
    end

    local rollup = {}
    local head = 1
    while head <= #queue do
        local current = queue[head]
        head = head + 1

        for _, neighbour in ipairs(neighbours_of(current.entity)) do
            if neighbour.valid and neighbour.unit_number and not visited[neighbour.unit_number] then
                visited[neighbour.unit_number] = true
                local hop = current.hop + 1

                if hop <= max_hops then
                    if not is_zone_active(neighbour.surface, neighbour.position) then
                        if hop <= near_hops then
                            if BELT_TYPES[neighbour.type] then table.insert(near_belts, neighbour)
                            elseif CONTAINER_TYPES[neighbour.type] then table.insert(near_containers, neighbour)
                            elseif neighbour.type == "inserter" then table.insert(near_inserters, neighbour)
                            end
                        else
                            accumulate_far(neighbour, zone_center, rollup)
                        end
                    end
                    table.insert(queue, {entity = neighbour, hop = hop})
                end
            end
        end
    end

    if #near_belts > 0 then TrackerEvents.log_belt_contents(near_belts) end
    for _, c in ipairs(near_containers) do
        TrackerEvents.log_inventory_delta("container_" .. c.unit_number, "container", TrackerEvents.container_contents(c))
    end
    for _, i in ipairs(near_inserters) do
        TrackerEvents.log_inventory_delta("inserter_" .. i.unit_number, "inserter_hand", TrackerEvents.held_stack_contents(i))
    end

    return rollup
end

-- One chain walk per currently active zone, seeded from that zone's own
-- belts/inserters (containers physically in the zone are already found
-- by Tracker.tick()'s Tier 1 scan and don't need to be traversal seeds
-- themselves - they're reached anyway as neighbours of a seeded
-- inserter).
function ItemChains.tick(active_zones, is_zone_active, chunk_area_fn)
    for zone_id, zone in pairs(active_zones) do
        local area = chunk_area_fn(zone.chunk_x, zone.chunk_y)
        local ok, seeds = pcall(function()
            return zone.surface.find_entities_filtered{
                area = area, type = {"transport-belt", "underground-belt", "splitter", "inserter"}
            }
        end)
        if not ok then
            log_fail("find_entities_filtered (chain seeds) for zone " .. zone_id, seeds)
        end

        if ok and #seeds > 0 then
            local tl, br = area[1], area[2]
            local zone_center = {x = (tl.x + br.x) / 2, y = (tl.y + br.y) / 2}

            local rollup = walk_chain(seeds, zone_center, is_zone_active)

            local entries = {}
            for _, bucket in pairs(rollup) do
                table.insert(entries, {
                    item = bucket.item,
                    direction = bucket.direction,
                    approx_count = bucket.approx_count,
                    centroid = {x = bucket.sum_x / bucket.entities_sampled, y = bucket.sum_y / bucket.entities_sampled},
                    entities_sampled = bucket.entities_sampled,
                })
            end

            if #entries > 0 then
                Exporter.log_event(game.tick, "item_distribution", {
                    chunk = {zone.chunk_x, zone.chunk_y},
                    surface = zone.surface.name,
                    entries = entries,
                })
            end
        end
    end
end

return ItemChains
