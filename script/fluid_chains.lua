-- script/fluid_chains.lua
-- Fluid equivalent of item_chains.lua - piped fuel reaching into or near
-- a zone, most notably flamethrower turret fuel (the design doc's
-- explicit ask). Pipes, storage tanks, pumps, and flamethrower turrets
-- ("fluid-turret") physically in a zone are the seeds; this follows the
-- pipe network outward from there the same way item_chains follows belts
-- and inserters.
--
-- Unlike belts and inserters, this turns out to be simpler than it
-- sounds: Factorio 2.0 already groups directly-connected pipes into
-- "fluid segments" internally, and LuaEntity::get_fluid_segment_fluid
-- reads an entire connected segment's contents in ONE call - there's no
-- need to walk pipe-by-pipe to add up contents the way belt lines do.
-- Because reading a segment is O(1) regardless of how physically long it
-- is, there's also no near/far precision split the way item_chains has -
-- a segment's total is the precise answer, not an estimate, no matter
-- how far it reaches. Everything here runs on the same slow interval as
-- Tier 2 logistics and item chains (Config.distant_sample_interval_ticks).
--
-- The one real wrinkle: there's no confirmed stable segment identifier
-- to key an "already reported this segment" set by. A single segment is
-- usually made of many individual pipe entities (a straight run of 50
-- pipes is one segment), and naively reading+reporting from every member
-- would report the same physical amount 50 times. So this discovers a
-- segment's full membership first (walking get_fluid_box_neighbours) and
-- only reads/reports it once, from a single representative member, using
-- that discovery walk itself as the de-dup mechanism instead of an ID.
--
-- Caveat, stated rather than hidden: a multi-fluidbox entity (a pump has
-- two, one per side) COULD belong to two different segments on its two
-- sides, and this walk doesn't try to distinguish that - it treats
-- everything reachable through get_fluid_box_neighbours from a given
-- fluidbox as one component. Worst case for getting that wrong is a
-- handful of redundant events around pumps/multi-box entities, not the
-- 50x duplication a long plain pipe run would produce without this.
local TrackerEvents = require("script.tracker_events")

local FluidChains = {}

local FLUID_SEED_TYPES = {"pipe", "pipe-to-ground", "storage-tank", "pump", "fluid-turret"}

-- FluidBoxNeighbourRecord's exact field name for the neighbouring entity
-- isn't confirmed, so this tries the plausible shapes rather than assume
-- one: a record with an .owner or .entity field, or the record itself
-- being the entity.
local function neighbour_entity_of(record)
    if type(record) ~= "table" then return nil end
    local candidate = record.owner or record.entity or record[1] or record
    if type(candidate) == "table" then
        local ok, valid = pcall(function() return candidate.valid end)
        if ok and valid then return candidate end
    end
    return nil
end

local function fluidbox_neighbours(entity, index)
    local ok, neighbours = pcall(function() return entity.get_fluid_box_neighbours(index) end)
    if not ok or not neighbours then return {} end

    local out = {}
    for _, record in ipairs(neighbours) do
        local owner = neighbour_entity_of(record)
        if owner then table.insert(out, owner) end
    end
    return out
end

-- Fluid amounts fluctuate continuously even at equilibrium (simulation
-- noise), and this runs on a rate-limited interval already - rounding to
-- the nearest whole unit avoids the diff cache flagging a "change" every
-- single sample from float jitter alone.
local function rounded(amount)
    return math.floor(amount + 0.5)
end

-- Discovers every {entity, index} reachable from (start_entity,
-- start_index) via get_fluid_box_neighbours, marking each as visited in
-- the shared `visited_boxes` set (shared across the whole tick, so a
-- second zone whose walk reaches the same pipe run doesn't re-read it
-- either). Returns the component as an array; the caller reads the
-- segment's fluid from just the first member.
local function discover_component(start_entity, start_index, visited_boxes)
    local component = {}
    local stack = {{entity = start_entity, index = start_index}}

    while #stack > 0 do
        local current = table.remove(stack)
        local key = current.entity.unit_number .. "_" .. current.index
        if not visited_boxes[key] then
            visited_boxes[key] = true
            table.insert(component, current)

            for _, neighbour in ipairs(fluidbox_neighbours(current.entity, current.index)) do
                local ok, count = pcall(function() return neighbour.fluids_count end)
                if ok and count and neighbour.unit_number then
                    for i = 1, count do
                        table.insert(stack, {entity = neighbour, index = i})
                    end
                end
            end
        end
    end

    return component
end

-- One walk per currently active zone, seeded from pipes/tanks/pumps/
-- flamethrower turrets physically in it. `visited_boxes`/`reported` are
-- shared across every zone processed in this call (passed in from
-- FluidChains.tick, not per-zone), so two zones reaching into the same
-- pipe network don't double-report it.
local function process_zone(surface, area, visited_boxes, reported)
    local ok, seeds = pcall(function()
        return surface.find_entities_filtered{area = area, type = FLUID_SEED_TYPES}
    end)
    if not ok then return end

    for _, seed in ipairs(seeds) do
        if seed.valid and seed.unit_number then
            local count_ok, count = pcall(function() return seed.fluids_count end)
            if count_ok and count then
                for index = 1, count do
                    local key = seed.unit_number .. "_" .. index
                    if not visited_boxes[key] then
                        local component = discover_component(seed, index, visited_boxes)
                        local rep = component[1]
                        if rep then
                            local has_ok, has_segment = pcall(function() return rep.entity.has_fluid_segment(rep.index) end)
                            if has_ok and has_segment then
                                local fluid_ok, fluid = pcall(function() return rep.entity.get_fluid_segment_fluid(rep.index) end)
                                if fluid_ok and fluid then
                                    local report_key = rep.entity.unit_number .. "_" .. fluid.name
                                    if not reported[report_key] then
                                        reported[report_key] = true
                                        TrackerEvents.log_fluid_delta(
                                            "fluid_" .. rep.entity.unit_number .. "_" .. fluid.name,
                                            {[fluid.name] = rounded(fluid.amount)},
                                            {position = rep.entity.position}
                                        )
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function FluidChains.tick(active_zones, chunk_area_fn)
    local visited_boxes = {}
    local reported = {}

    for zone_id, zone in pairs(active_zones) do
        local area = chunk_area_fn(zone.chunk_x, zone.chunk_y)
        process_zone(zone.surface, area, visited_boxes, reported)
    end
end

return FluidChains
