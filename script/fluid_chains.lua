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
-- Multi-fluidbox entities (a pump has two, one per side) are correctly
-- segmented: get_fluid_box_neighbours(index) returns FluidBoxNeighbourRecord
-- entries ({entity, index}) naming the SPECIFIC fluidbox index on the
-- neighbouring entity that's connected - the discovery walk below only
-- ever follows that exact index, never every fluidbox the neighbour
-- happens to have, so a pump's two independent sides can never be merged
-- into one reported segment.
local TrackerEvents = require("script.tracker_events")
local Config = require("script.config")

local FluidChains = {}

local FLUID_SEED_TYPES = {"pipe", "pipe-to-ground", "storage-tank", "pump", "fluid-turret"}

-- FluidBoxNeighbourRecord's confirmed shape: {entity = LuaEntity, index =
-- FluidStorageIndex} - the specific neighbouring fluidbox this one is
-- connected to, not just "some fluidbox on that entity".
local function fluidbox_neighbours(entity, index)
    local ok, neighbours = pcall(function() return entity.get_fluid_box_neighbours(index) end)
    if not ok then
        log("[replay-recorder] FluidChains: " .. entity.name .. ".get_fluid_box_neighbours failed: " .. tostring(neighbours))
    end
    if not ok or not neighbours then return {} end

    local out = {}
    for _, record in ipairs(neighbours) do
        if record.entity and record.entity.valid and record.index then
            table.insert(out, {entity = record.entity, index = record.index})
        end
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

            -- Only the SPECIFIC fluidbox index each neighbour record
            -- names, not every fluidbox the neighbouring entity happens
            -- to have - this is what keeps a multi-fluidbox entity's
            -- independent sides from ever being merged into one segment.
            for _, neighbour in ipairs(fluidbox_neighbours(current.entity, current.index)) do
                if neighbour.entity.unit_number then
                    table.insert(stack, neighbour)
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
-- Every pcall in this function guards against an exotic/mid-tick-invalid
-- entity throwing an error that would otherwise abort fluid tracking for
-- the whole tick - see the file-level comment. That safety net has a cost:
-- a genuine bug here (a wrong assumption about the API, not an exotic
-- entity) fails exactly as silently as the exotic-entity case it's meant
-- to tolerate - zero fluid_delta events, no visible error anywhere. log()
-- on the failure path costs nothing when nothing's failing, and turns a
-- silent "why didn't this work" into a concrete error message in
-- factorio-current.log the next time it reproduces.
local function process_zone(surface, area, visited_boxes, reported)
    local ok, seeds = pcall(function()
        return surface.find_entities_filtered{area = area, type = FLUID_SEED_TYPES}
    end)
    if not ok then
        log("[replay-recorder] FluidChains: find_entities_filtered failed: " .. tostring(seeds))
        return
    end

    for _, seed in ipairs(seeds) do
        if seed.valid and seed.unit_number then
            local count_ok, count = pcall(function() return seed.fluids_count end)
            if not count_ok then
                log("[replay-recorder] FluidChains: " .. seed.name .. ".fluids_count failed: " .. tostring(count))
            end
            if count_ok and count then
                for index = 1, count do
                    local key = seed.unit_number .. "_" .. index
                    if not visited_boxes[key] then
                        local component = discover_component(seed, index, visited_boxes)
                        local rep = component[1]
                        if rep then
                            local has_ok, has_segment = pcall(function() return rep.entity.has_fluid_segment(rep.index) end)
                            if not has_ok then
                                log("[replay-recorder] FluidChains: " .. rep.entity.name .. ".has_fluid_segment failed: " .. tostring(has_segment))
                            end
                            if has_ok and has_segment then
                                local fluid_ok, fluid = pcall(function() return rep.entity.get_fluid_segment_fluid(rep.index) end)
                                if not fluid_ok then
                                    log("[replay-recorder] FluidChains: " .. rep.entity.name .. ".get_fluid_segment_fluid failed: " .. tostring(fluid))
                                end
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

-- Unlike Logistics.tick()/ItemChains.tick(), fluids have no Tier 1
-- per-tick equivalent anywhere in Tracker.tick() - this is the only
-- place fluid_delta ever comes from, so it can't just be skipped under
-- full recording mode the way those two effectively are (they become
-- no-ops once storage.active_zones stops being populated per-chunk - see
-- CombatZones.activate_full_recording_chunk - since everything they'd
-- otherwise report is already covered by Tracker.tick()'s whole-surface
-- scan). Fluids still need an explicit whole-surface seed search here to
-- keep working at all once that population stops.
function FluidChains.tick(active_zones, chunk_area_fn)
    local visited_boxes = {}
    local reported = {}

    if Config.full_recording_mode() then
        -- game.surfaces is indexed by both numeric index and name, both
        -- pointing at the same LuaSurface - dedupe by surface.index so
        -- this doesn't scan every surface twice (visited_boxes/reported
        -- would prevent duplicate fluid_delta output either way, but
        -- there's no reason to pay for the redundant scan itself).
        local seen = {}
        for _, surface in pairs(game.surfaces) do
            if not seen[surface.index] then
                seen[surface.index] = true
                process_zone(surface, nil, visited_boxes, reported)
            end
        end
    else
        for zone_id, zone in pairs(active_zones) do
            local area = chunk_area_fn(zone.chunk_x, zone.chunk_y)
            process_zone(zone.surface, area, visited_boxes, reported)
        end
    end
end

return FluidChains
