-- script/tracker.lua
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")

local Tracker = {}

function Tracker.on_entity_died(event)
    local entity = event.entity
    if not entity.valid then return end

    local cause = event.cause
    local killer_data = nil
    if cause and cause.valid then
        killer_data = {
            name = cause.name,
            type = cause.type,
            force = cause.force.name
        }
    end

    -- Record the death event (Functions as your "Goal" / respawn trigger)
    Exporter.log_event(game.tick, "death_event", {
        victim = {
            name = entity.name,
            type = entity.type,
            force = entity.force.name,
            position = entity.position
        },
        killer = killer_data
    })

    -- Deaths always trigger/extend the combat zone
    CombatZones.trigger_combat_at(entity.surface, entity.position)
end

function Tracker.on_script_trigger_effect(event)
    if event.effect_id == "replay_combat_trigger" then
        local surface = game.surfaces[event.surface_index]
        local position = event.target_position or (event.target_entity and event.target_entity.position)
        
        if position then
            CombatZones.trigger_combat_at(surface, position)
            -- Optionally log the projectile instantiation here
        end
    end
end

function Tracker.tick()
    local mobile_data = {}

    -- Only poll entities inside active zones to save CPU/File size
    for _, zone in pairs(storage.active_zones) do
        local top_left = {x = zone.chunk_x * 32, y = zone.chunk_y * 32}
        local bottom_right = {x = top_left.x + 32, y = top_left.y + 32}
        
        -- Track anything that can move or fight
        local entities = zone.surface.find_entities_filtered{
            area = {top_left, bottom_right},
            type = {"unit", "character", "car", "spider-vehicle", "locomotive"}
        }

        for _, ent in ipairs(entities) do
            table.insert(mobile_data, {
                id = ent.unit_number or ent.player and ent.player.index, -- Persist identity across ticks
                name = ent.name,
                type = ent.type,
                force = ent.force.name,
                position = ent.position,
                orientation = ent.orientation
            })
        end
    end

    if #mobile_data > 0 then
        Exporter.log_event(game.tick, "mobile_positions", mobile_data)
    end
end

return Tracker