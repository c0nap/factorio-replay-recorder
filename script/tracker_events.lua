-- script/tracker_events.lua
-- Handles things that are naturally "events" rather than per-tick state:
-- inventory changes, biter unit groups forming up, and which group each
-- unit currently belongs to. Recording these as diffs/one-shot events
-- (instead of re-dumping a full inventory or group roster every tick) is
-- what keeps the replay file small.
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
-- owns the inventory (a player index, or a vehicle's unit_number) so
-- players and vehicles can share this same helper.
function TrackerEvents.log_inventory_delta(owner_key, owner_kind, current_contents)
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
        Exporter.log_event(game.tick, "inventory_delta", {
            owner = owner_key,
            owner_kind = owner_kind,
            changes = deltas
        })
    end

    storage.inventory_cache[owner_key] = current_contents
end

function TrackerEvents.on_player_inventory_changed(event)
    local player = game.players[event.player_index]
    if not player or not player.connected or not player.character then return end

    local inv_main = player.get_inventory(defines.inventory.character_main)
    local inv_ammo = player.get_inventory(defines.inventory.character_ammo)
    local inv_guns = player.get_inventory(defines.inventory.character_guns)

    local combined_contents = {}
    for _, inv in ipairs({inv_main, inv_ammo, inv_guns}) do
        if inv then
            for name, count in pairs(TrackerEvents.flatten_contents(inv.get_contents())) do
                combined_contents[name] = (combined_contents[name] or 0) + count
            end
        end
    end

    TrackerEvents.log_inventory_delta("player_" .. event.player_index, "player", combined_contents)
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
        group_id = group.group_number,
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
function TrackerEvents.on_unit_added_to_group(event)
    if not event.unit or not event.unit.valid then return end
    storage.unit_group_membership[event.unit.unit_number] = event.group.group_number
end

function TrackerEvents.on_unit_removed_from_group(event)
    if not event.unit or not event.unit.valid then return end
    storage.unit_group_membership[event.unit.unit_number] = nil
end

return TrackerEvents
