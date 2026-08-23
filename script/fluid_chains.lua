-- script/fluid_chains.lua
-- Fluid equivalent of item_chains.lua - piped fuel reaching into or near
-- a zone, most notably flamethrower turret fuel (the design doc's
-- explicit ask). Pipes, storage tanks, pumps, and flamethrower turrets
-- ("fluid-turret") physically in a zone are the seeds; this follows the
-- pipe network outward from there the same way item_chains follows belts
-- and inserters.
--
-- Fluid methods live on `entity.fluidbox` (a LuaFluidBox wrapper), not on
-- LuaEntity directly, on real 2.0.77 data:
--   entity.fluidbox[index]                       -> {name, amount, temperature} or nil
--   #entity.fluidbox                             -> count of fluidbox-backed storages (CONFIRMED,
--       LuaFluidBox's own `#` length operator - see fluidbox_count below)
--   entity.fluidbox.get_pipe_connections(index)   -> array[PipeConnection] (CONFIRMED,
--       LuaFluidBox::get_pipe_connections docs) - each carries `target` (the connected
--       LuaFluidBox, if any) and `target_fluidbox_index` (that box's exact index within
--       ITS owner), which is what connected_boxes below uses to walk the network without
--       guessing - see connected_boxes' own comment.
--   entity.fluidbox.get_fluid_segment_id(index)      -> a value, or nil if not part of a segment
--   entity.fluidbox.get_fluid_segment_contents(index) -> {[fluid_name] = amount, ...} (a dict,
--       possibly more than one fluid name - unlike the single-Fluid-struct shape tried before)
--
-- CONFIRMED root cause of the "index out of range" mismatch this file used
-- to just detect-and-mute: LuaEntity::fluids_count's own docs say it
-- "covers other fluid storages like fluid turret's internal buffer and
-- fluid wagon's fluid since they are not fluidbox and cannot be exposed
-- through LuaFluidBox" - i.e. fluids_count counts MORE than entity.fluidbox
-- actually has slots for (a flamethrower-turret's internal ammo buffer
-- being exactly the extra index that was going out of range). fluidbox_count
-- below uses `#entity.fluidbox` instead everywhere this file bounds a loop
-- over fluidbox-specific calls, so the mismatch can't occur in the first
-- place - see fluidbox_count's own comment.
local TrackerEvents = require("script.tracker_events")
local Config = require("script.config")
local Keys = require("script.keys")

local FluidChains = {}

local FLUID_SEED_TYPES = {"pipe", "pipe-to-ground", "storage-tank", "pump", "fluid-turret"}

-- The exact count of fluidbox-backed storages on `entity`, via LuaFluidBox's
-- own `#` (length) operator - CONFIRMED distinct from (and <=) fluids_count,
-- see the file-level comment. Returns 0 (not an error) for an entity with
-- no fluidbox at all, so callers can loop `for i = 1, fluidbox_count(e) do`
-- unconditionally instead of separately guarding "does this entity even
-- have a fluidbox".
local function fluidbox_count(entity)
    local ok, box = pcall(function() return entity.fluidbox end)
    if not ok or not box then return 0 end
    local ok2, count = pcall(function() return #box end)
    if not ok2 then
        log("[replay-recorder] FluidChains: #" .. entity.name .. ".fluidbox failed: " .. tostring(count))
        return 0
    end
    return count
end

-- Returns {entity, index} for every fluidbox connected to (entity, index),
-- deduplicated by (owner unit_number, index) - CONFIRMED via
-- LuaFluidBox::get_pipe_connections(index), whose PipeConnection results
-- carry the connected box's owner (`target.owner`) AND its exact
-- `target_fluidbox_index`, so the walk can enqueue precisely the box that's
-- actually connected instead of every index a neighbour entity happens to
-- have (the old get_connections-based version could only get `.owner` back,
-- not an index, and had to guess by trying the neighbour's entire fluidbox
-- range - see git history). A connection with no `target` (a dangling pipe
-- end) or no `target_fluidbox_index` is simply skipped.
local function connected_boxes(entity, index)
    local ok, connections = pcall(function() return entity.fluidbox.get_pipe_connections(index) end)
    if not ok then
        log("[replay-recorder] FluidChains: " .. entity.name .. ".fluidbox.get_pipe_connections failed: " .. tostring(connections))
    end
    if not ok or not connections then return {} end

    local out = {}
    local seen = {}
    for _, connection in ipairs(connections) do
        local target, target_index = connection.target, connection.target_fluidbox_index
        if target and target_index then
            local owner_ok, owner = pcall(function() return target.owner end)
            if not owner_ok then
                log("[replay-recorder] FluidChains: connected target.owner failed: " .. tostring(owner))
            end
            if owner_ok and owner and owner.valid and owner.unit_number then
                local dedup_key = Keys.join(owner.unit_number, target_index)
                if not seen[dedup_key] then
                    seen[dedup_key] = true
                    table.insert(out, {entity = owner, index = target_index})
                end
            end
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
-- start_index) via entity.fluidbox.get_pipe_connections, marking each as
-- visited in the shared `visited_boxes` set (shared across the whole
-- tick, so a second zone whose walk reaches the same pipe run doesn't
-- re-read it either). Returns the component as an array; the caller
-- reads the segment's fluid from just the first member.
local function discover_component(start_entity, start_index, visited_boxes)
    local component = {}
    local stack = {{entity = start_entity, index = start_index}}

    while #stack > 0 do
        local current = table.remove(stack)
        local key = Keys.join(current.entity.unit_number, current.index)
        if not visited_boxes[key] then
            visited_boxes[key] = true
            table.insert(component, current)

            for _, neighbour in ipairs(connected_boxes(current.entity, current.index)) do
                local n_key = Keys.join(neighbour.entity.unit_number, neighbour.index)
                if not visited_boxes[n_key] then
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
            for index = 1, fluidbox_count(seed) do
                local key = Keys.join(seed.unit_number, index)
                if not visited_boxes[key] then
                    local component = discover_component(seed, index, visited_boxes)
                    local rep = component[1]
                    if rep then
                        local seg_id_ok, seg_id = pcall(function() return rep.entity.fluidbox.get_fluid_segment_id(rep.index) end)
                        if not seg_id_ok then
                            log("[replay-recorder] FluidChains: " .. rep.entity.name .. ".fluidbox.get_fluid_segment_id failed: " .. tostring(seg_id))
                        end
                        if seg_id_ok and seg_id ~= nil then
                            local contents_ok, contents = pcall(function() return rep.entity.fluidbox.get_fluid_segment_contents(rep.index) end)
                            if not contents_ok then
                                log("[replay-recorder] FluidChains: " .. rep.entity.name .. ".fluidbox.get_fluid_segment_contents failed: " .. tostring(contents))
                            end
                            if contents_ok and contents then
                                for fluid_name, amount in pairs(contents) do
                                    local report_key = Keys.join(rep.entity.unit_number, fluid_name)
                                    if not reported[report_key] then
                                        reported[report_key] = true
                                        TrackerEvents.log_fluid_delta(
                                            Keys.join("fluid", rep.entity.unit_number, fluid_name),
                                            {[fluid_name] = rounded(amount)},
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
