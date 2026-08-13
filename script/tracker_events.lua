-- script/tracker_events.lua
-- Shared diffing/reading helpers plus the handful of things that are
-- naturally "events" rather than per-tick state: inventory changes, biter
-- unit groups forming up, which group each unit currently belongs to, and
-- which spawner a unit came from. Recording state as diffs/one-shot
-- events (instead of re-dumping a full inventory or group roster every
-- tick) is what keeps the replay file small - this file is where that
-- diffing logic lives so every other module (Tracker, Logistics,
-- ItemChains, FluidChains) shares one implementation instead of five
-- slightly-different copies.
local Exporter = require("script.exporter")

local TrackerEvents = {}

-- Factorio 2.0's quality system changed what LuaInventory.get_contents()
-- (and LuaTransportLine.get_contents()) returns: instead of a simple
-- {name -> count} table, it's now an array of {name, count, quality}
-- entries - one per name/quality combination, so a stack of legendary
-- iron plates and a stack of normal iron plates show up as two separate
-- entries. This mod doesn't track quality as its own dimension, so this
-- flattens the array back into a plain {name -> count} table, merging all
-- qualities of an item into one total - matching the name -> count
-- semantics everything downstream (log_inventory_delta, belt diffing)
-- expects.
function TrackerEvents.flatten_contents(get_contents_result)
    local flat = {}
    for _, stack in pairs(get_contents_result) do
        flat[stack.name] = (flat[stack.name] or 0) + stack.count
    end
    return flat
end

-- Diffs `current_contents` (a name -> count table, e.g. from
-- flatten_contents above) against whatever we last saw for `owner_key`,
-- and logs only the items that changed. `owner_key` identifies whoever
-- owns the inventory (a player index, a vehicle's/container's/inserter's
-- unit_number) so every kind of item owner can share this one helper.
-- `extra_fields`, if given, is merged into the logged event's data table -
-- used for things like a corpse's position, which has nowhere else to be
-- reported (see Tracker's corpse tracking).
function TrackerEvents.log_inventory_delta(owner_key, owner_kind, current_contents, extra_fields)
    storage.inventory_cache = storage.inventory_cache or {}
    local previous = storage.inventory_cache[owner_key] or {}
    local deltas = {}

    for item, count in pairs(current_contents) do
        local prev_count = previous[item] or 0
        if count ~= prev_count then
            table.insert(deltas, {item = item, delta = count - prev_count})
        end
    end

    for item, prev_count in pairs(previous) do
        if not current_contents[item] then
            table.insert(deltas, {item = item, delta = -prev_count})
        end
    end

    if #deltas > 0 then
        local payload = {
            owner = owner_key,
            owner_kind = owner_kind,
            changes = deltas
        }
        if extra_fields then
            for key, value in pairs(extra_fields) do
                payload[key] = value
            end
        end
        Exporter.log_event(game.tick, "inventory_delta", payload)
    end

    storage.inventory_cache[owner_key] = current_contents
end

-- Fluid equivalent of log_inventory_delta, kept as a separate event type
-- (fluid_delta, not inventory_delta) and a separate cache namespace -
-- fluid amounts are continuous floats, not discrete item counts, and
-- fluid/item names could in principle collide, so the two streams are
-- deliberately never merged into one. See script/fluid_chains.lua.
function TrackerEvents.log_fluid_delta(owner_key, current_fluids, extra_fields)
    storage.fluid_cache = storage.fluid_cache or {}
    local previous = storage.fluid_cache[owner_key] or {}
    local deltas = {}

    for name, amount in pairs(current_fluids) do
        local prev_amount = previous[name] or 0
        if amount ~= prev_amount then
            table.insert(deltas, {fluid = name, delta = amount - prev_amount})
        end
    end

    for name, prev_amount in pairs(previous) do
        if not current_fluids[name] then
            table.insert(deltas, {fluid = name, delta = -prev_amount})
        end
    end

    if #deltas > 0 then
        local payload = {owner = owner_key, changes = deltas}
        if extra_fields then
            for key, value in pairs(extra_fields) do
                payload[key] = value
            end
        end
        Exporter.log_event(game.tick, "fluid_delta", payload)
    end

    storage.fluid_cache[owner_key] = current_fluids
end

-- A container-like entity's full contents as a flat {name -> count}
-- table (always a table, never nil, so callers can feed it straight into
-- log_inventory_delta - an entity that just lost everything still needs a
-- real {} to diff against, not nil). Reads the main "chest" inventory
-- plus, for logistic containers, their trash slot. pcall-guarded per read
-- because a logistics network's requesters/providers/storages aren't
-- limited to plain chests - see script/logistics.lua.
function TrackerEvents.container_contents(entity)
    local contents = {}

    local ok_chest, chest = pcall(function() return entity.get_inventory(defines.inventory.chest) end)
    if ok_chest and chest then
        for name, count in pairs(TrackerEvents.flatten_contents(chest.get_contents())) do
            contents[name] = (contents[name] or 0) + count
        end
    elseif not ok_chest then
        log("[replay-recorder] TrackerEvents: " .. entity.name .. ".get_inventory(chest) failed: " .. tostring(chest))
    end

    local ok_trash, trash = pcall(function() return entity.get_inventory(defines.inventory.logistic_container_trash) end)
    if ok_trash and trash then
        for name, count in pairs(TrackerEvents.flatten_contents(trash.get_contents())) do
            contents[name] = (contents[name] or 0) + count
        end
    elseif not ok_trash then
        log("[replay-recorder] TrackerEvents: " .. entity.name .. ".get_inventory(logistic_container_trash) failed: " .. tostring(trash))
    end

    return contents
end

-- A character-corpse's dropped-item inventory, same always-a-table
-- contract as container_contents.
function TrackerEvents.corpse_contents(entity)
    local ok, inv = pcall(function() return entity.get_inventory(defines.inventory.character_corpse) end)
    if ok and inv then
        return TrackerEvents.flatten_contents(inv.get_contents())
    elseif not ok then
        log("[replay-recorder] TrackerEvents: " .. entity.name .. ".get_inventory(character_corpse) failed: " .. tostring(inv))
    end
    return {}
end

-- An inserter's hand: LuaItemStack, not an inventory - `held_stack`
-- always exists as an object, but `valid_for_read` says whether it's
-- currently holding anything. Same always-a-table contract as the above.
function TrackerEvents.held_stack_contents(entity)
    local ok, stack = pcall(function() return entity.held_stack end)
    if ok and stack and stack.valid_for_read then
        return {[stack.name] = stack.count}
    elseif not ok then
        log("[replay-recorder] TrackerEvents: " .. entity.name .. ".held_stack failed: " .. tostring(stack))
    end
    return {}
end

-- A ground item-entity's stack ("stack" is only readable when entity.type
-- == "item-entity"). Same shape/contract as held_stack_contents above -
-- a single-item table, or {} if it's somehow not valid for reading.
function TrackerEvents.ground_item_contents(entity)
    local ok, stack = pcall(function() return entity.stack end)
    if ok and stack and stack.valid_for_read then
        return {[stack.name] = stack.count}
    elseif not ok then
        log("[replay-recorder] TrackerEvents: " .. entity.name .. ".stack failed: " .. tostring(stack))
    end
    return {}
end

-- Registers a ground item-entity for on_object_destroyed, the one time we
-- see it (storage.registered_ground_items guards against re-registering
-- every tick it's re-scanned - register_on_object_destroyed is idempotent
-- per its own docs, but there's no reason to call it repeatedly). This is
-- what closes the gap on_entity_died couldn't: register_on_object_destroyed
-- fires regardless of WHY the object was removed (picked up by walking
-- over it, mined, burned, ...), not just combat destruction.
function TrackerEvents.ensure_ground_item_registered(entity)
    if not entity.unit_number or storage.registered_ground_items[entity.unit_number] then return end

    local ok, err = pcall(function() script.register_on_object_destroyed(entity) end)
    if ok then
        storage.registered_ground_items[entity.unit_number] = true
    else
        log("[replay-recorder] TrackerEvents: register_on_object_destroyed failed for " .. entity.name .. ": " .. tostring(err))
    end
end

-- Fires for ANY object this mod has registered via
-- register_on_object_destroyed, regardless of mod or object type (the
-- registry is global, per its docs) - so this only acts when the
-- destroyed object is a LuaEntity (defines.target_type.entity) whose
-- useful_id (== the entity's former unit_number for entity targets) is
-- one we actually registered ourselves, via storage.registered_ground_items.
-- Clears the cache entry (the actual fix for the leak) and emits a
-- one-time ground_item_removed event, mirroring corpse_expired.
--
-- TODO (PR #14, blocked on API confirmation): this whole useful_id-keyed
-- scheme is currently dead - item-entity (ground items) confirmed to
-- never have a unit_number, so ensure_ground_item_registered's unit_number
-- guard means register_on_object_destroyed is never actually called for
-- one, and ground_item_removed stays at 0 events. The fix needs
-- confirmation of what register_on_object_destroyed returns and what
-- on_object_destroyed's payload looks like for a target with no
-- unit_number (registration_number instead of useful_id, most likely) -
-- once confirmed, this same mechanism is also the fix for Tracker.
-- on_entity_died's fire/acid effect_expired gap (fire entities never fire
-- on_entity_died on expiry either, and may have the same no-unit_number
-- situation as ground items).
function TrackerEvents.on_object_destroyed(event)
    if event.type ~= defines.target_type.entity then return end
    if not storage.registered_ground_items[event.useful_id] then return end

    storage.registered_ground_items[event.useful_id] = nil
    storage.inventory_cache["ground_item_" .. event.useful_id] = nil
    Exporter.log_event(game.tick, "ground_item_removed", {owner = "ground_item_" .. event.useful_id})
end

local function belt_line_contents_equal(a, b)
    a, b = a or {}, b or {}
    for item, count in pairs(a) do
        if b[item] ~= count then return false end
    end
    for item, count in pairs(b) do
        if a[item] ~= count then return false end
    end
    return true
end

-- Belts are extremely common near any base, so if every belt's full
-- contents were logged on every tick a fight was active, belt spam alone
-- could dwarf the rest of the replay. Instead, cache each line's last-seen
-- contents and only write out lines that actually changed since - the
-- same "diff, don't dump" approach used for inventories. Shared between
-- Tracker's per-tick physical scan and ItemChains' near-hop belts so both
-- write through the same cache and don't fight each other over the same
-- belt.
function TrackerEvents.log_belt_contents(entities)
    storage.belt_line_cache = storage.belt_line_cache or {}
    local belt_data = {}

    for _, ent in ipairs(entities) do
        if ent.valid then
            local lines = {}
            for i = 1, ent.get_max_transport_line_index() do
                local cache_key = ent.unit_number .. "_" .. i
                local contents = TrackerEvents.flatten_contents(ent.get_transport_line(i).get_contents())
                if not belt_line_contents_equal(storage.belt_line_cache[cache_key], contents) then
                    table.insert(lines, {line = i, contents = contents})
                    storage.belt_line_cache[cache_key] = contents
                end
            end
            if #lines > 0 then
                table.insert(belt_data, {id = ent.unit_number, name = ent.name, position = ent.position, lines = lines})
            end
        end
    end

    if #belt_data > 0 then
        Exporter.log_event(game.tick, "belt_contents", belt_data)
    end
end

function TrackerEvents.on_player_inventory_changed(event)
    local player = game.players[event.player_index]
    if not player or not player.connected or not player.character then return end

    local inv_main = player.get_inventory(defines.inventory.character_main)
    local inv_ammo = player.get_inventory(defines.inventory.character_ammo)
    local inv_guns = player.get_inventory(defines.inventory.character_guns)
    local inv_trash = player.get_inventory(defines.inventory.character_trash)

    -- NOT `ipairs({inv_main, inv_ammo, inv_guns, inv_trash})`: any of
    -- these can individually be nil, and ipairs stops dead at the first
    -- nil slot in the array regardless of what comes after it - a nil
    -- inv_main would have silently dropped ammo/guns/trash from tracking
    -- entirely. Building the list by only inserting the truthy ones
    -- avoids ever putting a nil in the array in the first place.
    local inventories = {}
    if inv_main then table.insert(inventories, inv_main) end
    if inv_ammo then table.insert(inventories, inv_ammo) end
    if inv_guns then table.insert(inventories, inv_guns) end
    if inv_trash then table.insert(inventories, inv_trash) end

    local combined_contents = {}
    for _, inv in ipairs(inventories) do
        for name, count in pairs(TrackerEvents.flatten_contents(inv.get_contents())) do
            combined_contents[name] = (combined_contents[name] or 0) + count
        end
    end

    TrackerEvents.log_inventory_delta("player_" .. event.player_index, "player", combined_contents)
end

-- One-time record of a ground item's origin, mirroring corpse_created -
-- the ongoing contents (what it currently holds) are tracked separately
-- via Tracker's per-tick physical scan (ground_item_<id> inventory_delta),
-- same split as corpses. This only covers manual player drops -
-- on_player_dropped_item is the only creation-side event confirmed so
-- far; an item-entity that appears some other way (inserter overflow,
-- explosion debris) still gets picked up by the per-tick scan the moment
-- it's physically in an active zone, just without this provenance record.
function TrackerEvents.on_player_dropped_item(event)
    local entity = event.entity
    if not entity or not entity.valid then return end

    -- unit_number is no longer required to log this creation event - a
    -- corpse in an earlier round turned out to only sometimes have one,
    -- and requiring it there silently rejected every real corpse.
    -- CONFIRMED: item-entity (ground items) never has a unit_number at
    -- all, not just sometimes. ensure_ground_item_registered still gates
    -- on unit_number and so never actually registers a ground item for
    -- removal tracking - this creation event no longer silently
    -- disappears because of it, but ongoing content/removal tracking for
    -- ground items is a real, known gap (see the TODO on TrackerEvents.
    -- on_object_destroyed) until that's redesigned around a key that
    -- doesn't need one.
    TrackerEvents.ensure_ground_item_registered(entity)
    local owner_key
    if entity.unit_number then
        owner_key = "ground_item_" .. entity.unit_number
    else
        owner_key = "ground_item_dropped_" .. event.player_index .. "_" .. game.tick
        log("[replay-recorder] TrackerEvents: dropped item-entity (" .. entity.name .. ") has no unit_number - "
            .. "ground_item_created still recorded via " .. owner_key .. ", but ongoing content/removal tracking "
            .. "for it needs a stable id this doesn't have")
    end
    Exporter.log_event(game.tick, "ground_item_created", {
        owner = owner_key,
        position = entity.position,
        player_index = event.player_index,
    })
end

-- Human-readable form of defines.group_state, so consumers of the JSON
-- don't need to know the engine's internal numeric IDs. We surface the
-- raw state rather than guessing "expansion vs. attack" ourselves: the API
-- doesn't expose that distinction directly, and a group's state naturally
-- tells the same story (a group quietly "gathering" or "moving" reads very
-- differently from one "attacking_target").
local GROUP_STATE_NAMES = {
    [defines.group_state.gathering] = "gathering",
    [defines.group_state.moving] = "moving",
    [defines.group_state.attacking_distraction] = "attacking_distraction",
    [defines.group_state.attacking_target] = "attacking_target",
    [defines.group_state.finished] = "finished",
    [defines.group_state.pathfinding] = "pathfinding",
    [defines.group_state.wander_in_group] = "wander_in_group",
}

function TrackerEvents.on_unit_group_created(event)
    local group = event.group
    if not group or not group.valid then return end

    Exporter.log_event(game.tick, "unit_group_created", {
        group_id = group.unique_id,
        force = group.force.name,
        position = group.position,
        state = GROUP_STATE_NAMES[group.state] or "unknown"
    })
end

-- There is no `unit.unit_group` property to read a unit's group back off
-- of - group membership is only ever announced through these two events.
-- storage.unit_group_membership is this mod's own record of "which group
-- is this unit currently in", kept up to date here and read back in
-- Tracker.tick() to tag each biter/spitter with its group_id.
--
-- `group` here is a LuaCommandable, not a dedicated "unit group" class -
-- there's no `group_number` field on it (that was another wrong guess,
-- caught before it shipped a crash: LuaCommandable's actual identifier
-- field is `unique_id`).
function TrackerEvents.on_unit_added_to_group(event)
    if not event.unit or not event.unit.valid then return end
    if not event.group or not event.group.valid then return end
    storage.unit_group_membership[event.unit.unit_number] = event.group.unique_id
end

function TrackerEvents.on_unit_removed_from_group(event)
    if not event.unit or not event.unit.valid then return end
    storage.unit_group_membership[event.unit.unit_number] = nil
end

-- Ties a freshly spawned biter/spitter back to the specific spawner that
-- made it, giving nest lineage that's precise (an actual parent-child
-- link from the engine) rather than the proximity guess chunk snapshots
-- use to cluster spawners into rough "bases". Read back in Tracker.tick()
-- as each unit's spawner_id.
function TrackerEvents.on_entity_spawned(event)
    local entity, spawner = event.entity, event.spawner
    if not entity or not entity.valid then return end
    if not spawner or not spawner.valid then return end
    storage.spawned_by[entity.unit_number] = spawner.unit_number
end

return TrackerEvents
