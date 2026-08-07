-- script/tracker_events.lua
local Exporter = require("script.exporter")

local TrackerEvents = {}

-- Helper to diff inventories
local function log_inventory_delta(player_index, current_contents)
    local previous = storage.player_inventories[player_index] or {}
    local deltas = {}
    
    -- Find new or increased items
    for item, count in pairs(current_contents) do
        local prev_count = previous[item] or 0
        if count ~= prev_count then
            table.insert(deltas, {item = item, delta = count - prev_count})
        end
    end
    
    -- Find removed items
    for item, prev_count in pairs(previous) do
        if not current_contents[item] then
            table.insert(deltas, {item = item, delta = -prev_count})
        end
    end
    
    if #deltas > 0 then
        Exporter.log_event(game.tick, "inventory_delta", {
            player_index = player_index,
            changes = deltas
        })
    end
    
    -- Update cache
    storage.player_inventories[player_index] = current_contents
end

function TrackerEvents.on_player_inventory_changed(event)
    local player = game.players[event.player_index]
    if not player or not player.connected then return end
    
    -- Get main, ammo, and gun inventories
    local inv_main = player.get_inventory(defines.inventory.character_main)
    local inv_ammo = player.get_inventory(defines.inventory.character_ammo)
    
    local combined_contents = {}
    if inv_main then
        for name, count in pairs(inv_main.get_contents()) do
            combined_contents[name] = count
        end
    end
    if inv_ammo then
        for name, count in pairs(inv_ammo.get_contents()) do
            combined_contents[name] = (combined_contents[name] or 0) + count
        end
    end
    
    log_inventory_delta(event.player_index, combined_contents)
end

function TrackerEvents.on_unit_group_created(event)
    local group = event.group
    if not group or not group.valid then return end
    
    -- Store the group ID to track high-level movement
    storage.unit_groups[group.group_number] = {
        force = group.force.name,
        state = group.state
    }
    
    Exporter.log_event(game.tick, "unit_group_created", {
        group_id = group.group_number,
        force = group.force.name,
        position = group.position
    })
end

return TrackerEvents