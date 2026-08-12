-- script/fluid_chains.lua
-- Fluid equivalent of item_chains.lua - piped fuel reaching into or near
-- a zone, most notably flamethrower turret fuel (the design doc's
-- explicit ask). Pipes, storage tanks, pumps, and flamethrower turrets
-- ("fluid-turret") physically in a zone are the seeds; this follows the
-- pipe network outward from there the same way item_chains follows belts
-- and inserters.
--
-- UNVERIFIED (PR #13): every method this file previously called directly
-- on LuaEntity (get_fluid_box_neighbours/has_fluid_segment/
-- get_fluid_segment_fluid) errored with "LuaEntity doesn't contain key
-- ..." on a real 2.0.76 run, despite matching real API docs fetched
-- earlier in this project - a genuine, unresolved contradiction. This
-- rewrite switches to a different shape - fluid methods living on
-- `entity.fluidbox` (a LuaFluidBox wrapper) instead of on LuaEntity
-- directly - on the theory that the docs fetched (and the ones this is
-- now based on) describe a different Factorio version than 2.0.76 is
-- running. That theory is NOT independently confirmed - it's the
-- explicit direction to try next, to be reverted if it turns out no
-- better than what was here before. Every call below is still
-- pcall-guarded and still logs on failure, same as before, so a wrong
-- guess here fails exactly as visibly as the last one did.
--
-- Assumed shape, per that direction:
--   entity.fluidbox[index]                    -> {name, amount, temperature} or nil
--   entity.fluidbox.get_connections(index)     -> array of LuaFluidBox (connected boxes, not entities)
--   connected_box.owner                        -> the LuaEntity that box belongs to
--   entity.fluidbox.get_fluid_segment_id(index)      -> a value, or nil if not part of a segment
--   entity.fluidbox.get_fluid_segment_contents(index) -> {[fluid_name] = amount, ...} (a dict,
--       possibly more than one fluid name - unlike the single-Fluid-struct shape tried before)
--
-- One real gap in the above: nothing above says how to recover the
-- INDEX of a connected box within its owner (only `.owner`, the entity).
-- Rather than guess a reverse lookup that was never described, a
-- discovered neighbour entity has ALL of its own indices (1..fluids_count)
-- enqueued for the walk, not just the one actually connected. This is a
-- real precision loss versus the previous (confirmed-2.1-shape) code,
-- which tracked the exact connected index and so could never merge a
-- multi-fluidbox entity's independent sides (a pump's two ends) into one
-- reported segment - this version can, for exactly that kind of entity,
-- until a real reverse-index lookup is confirmed.
local TrackerEvents = require("script.tracker_events")
local Config = require("script.config")

local FluidChains = {}

local FLUID_SEED_TYPES = {"pipe", "pipe-to-ground", "storage-tank", "pump", "fluid-turret"}

-- Returns the LuaEntity owners of every box connected to (entity, index),
-- deduplicated by unit_number - see the file-level comment for why this
-- can't narrow down to the exact connected index the way the previous
-- (confirmed-2.1-shape) version could.
local function connected_owners(entity, index)
    local ok, boxes = pcall(function() return entity.fluidbox.get_connections(index) end)
    if not ok then
        log("[replay-recorder] FluidChains: " .. entity.name .. ".fluidbox.get_connections failed: " .. tostring(boxes))
    end
    if not ok or not boxes then return {} end

    local out = {}
    local seen = {}
    for _, box in ipairs(boxes) do
        local owner_ok, owner = pcall(function() return box.owner end)
        if not owner_ok then
            log("[replay-recorder] FluidChains: connected box.owner failed: " .. tostring(owner))
        end
        if owner_ok and owner and owner.valid and owner.unit_number and not seen[owner.unit_number] then
            seen[owner.unit_number] = true
            table.insert(out, owner)
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
-- start_index) via entity.fluidbox.get_connections, marking each as
-- visited in the shared `visited_boxes` set (shared across the whole
-- tick, so a second zone whose walk reaches the same pipe run doesn't
-- re-read it either). Returns the component as an array; the caller
-- reads the segment's fluid from just the first member.
local function discover_component(start_entity, start_index, visited_boxes)
    local component = {}
    local stack = {{entity = start_entity, index = start_index}}

    while #stack > 0 do
        local current = table.remove(stack)
        local key = current.entity.unit_number .. "_" .. current.index
        if not visited_boxes[key] then
            visited_boxes[key] = true
            table.insert(component, current)

            for _, neighbour_entity in ipairs(connected_owners(current.entity, current.index)) do
                local count_ok, count = pcall(function() return neighbour_entity.fluids_count end)
                if count_ok and count then
                    for n_index = 1, count do
                        local n_key = neighbour_entity.unit_number .. "_" .. n_index
                        if not visited_boxes[n_key] then
                            table.insert(stack, {entity = neighbour_entity, index = n_index})
                        end
                    end
                end
            end
        end
    end

    return component
end

-- TEMPORARY (PR #13): a live console probe already confirmed entity.fluidbox
-- exists (userdata) while every LuaEntity-level segment method
-- (get_fluid_box_neighbours/has_fluid_segment/get_fluid_segment_fluid/
-- get_fluid_segment_id/get_fluid_segment_contents) errors with "doesn't
-- contain key" - but that probe used a freshly created, EMPTY tank, so
-- entity.fluidbox[1] came back ambiguous (nil-because-empty and
-- nil-because-not-indexable-that-way both hit the same branch). This
-- probes the real thing instead: the first seed actually encountered
-- during real play with fluid already in it (every checklist fluid step
-- inserts fluid before this ever runs), pcall-guarding each candidate
-- separately so nil and ERROR are never conflated. Also now the
-- authoritative check on whether THIS rewrite's assumed shape is right -
-- if get_connections/get_fluid_segment_id/get_fluid_segment_contents come
-- back ERROR here too, the wrapper theory is wrong, not just the exact
-- method names. Logs once per session. Remove once the real shape is
-- confirmed either way.
local function probe_fluidbox_shape(entity)
    if storage.fluid_api_probe_done then return end
    storage.fluid_api_probe_done = true

    local function p(name, fn)
        local ok, v = pcall(fn)
        if not ok then return name .. "=ERROR(" .. tostring(v) .. ")" end
        if v == nil then return name .. "=nil" end
        return name .. "=" .. tostring(v) .. "(" .. type(v) .. ")"
    end

    local parts = {p("entity.fluidbox", function() return entity.fluidbox end)}

    local ok_box, box = pcall(function() return entity.fluidbox and entity.fluidbox[1] end)
    if ok_box and box ~= nil then
        table.insert(parts, p("fluidbox[1]", function() return box end))
        table.insert(parts, p("fluidbox[1].owner", function() return box.owner end))
        table.insert(parts, p("fluidbox[1].amount", function() return box.amount end))
        table.insert(parts, p("fluidbox[1].name", function() return box.name end))
        table.insert(parts, p("fluidbox[1].get_connections", function() return box.get_connections end))
        table.insert(parts, p("fluidbox[1].get_fluid_segment_contents", function() return box.get_fluid_segment_contents end))
        table.insert(parts, p("fluidbox[1].get_fluid_segment_id", function() return box.get_fluid_segment_id end))
    else
        table.insert(parts, ok_box and "fluidbox[1]=nil" or ("fluidbox[1]=ERROR(" .. tostring(box) .. ")"))
    end

    table.insert(parts, p("fluidbox.get_connections(1)", function() return entity.fluidbox.get_connections(1) end))
    table.insert(parts, p("fluidbox.get_fluid_segment_contents(1)", function() return entity.fluidbox.get_fluid_segment_contents(1) end))
    table.insert(parts, p("fluidbox.get_fluid_segment_id(1)", function() return entity.fluidbox.get_fluid_segment_id(1) end))

    log("[replay-recorder-probe] fluidbox shape on " .. entity.name .. ": " .. table.concat(parts, " | "))
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
            local count_ok, count = pcall(function() return seed.fluids_count end)
            if not count_ok then
                log("[replay-recorder] FluidChains: " .. seed.name .. ".fluids_count failed: " .. tostring(count))
            end
            if count_ok and count and count > 0 then
                probe_fluidbox_shape(seed)
                for index = 1, count do
                    local key = seed.unit_number .. "_" .. index
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
                                        local report_key = rep.entity.unit_number .. "_" .. fluid_name
                                        if not reported[report_key] then
                                            reported[report_key] = true
                                            TrackerEvents.log_fluid_delta(
                                                "fluid_" .. rep.entity.unit_number .. "_" .. fluid_name,
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
