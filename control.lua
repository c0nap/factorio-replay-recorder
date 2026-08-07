-- control.lua
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")
local Tracker = require("script.tracker")
local TrackerEvents = require("script.tracker_events")
local Init = require("script.init")

script.on_init(Init.setup)
script.on_configuration_changed(Init.setup)

-- Combat & Death Hooks
script.on_event(defines.events.on_entity_died, Tracker.on_entity_died)
script.on_event(defines.events.on_entity_damaged, Tracker.on_entity_damaged)
script.on_event(defines.events.on_script_trigger_effect, Tracker.on_script_trigger_effect)

-- Inventory Hooks
script.on_event(defines.events.on_player_main_inventory_changed, TrackerEvents.on_player_inventory_changed)
script.on_event(defines.events.on_player_ammo_inventory_changed, TrackerEvents.on_player_inventory_changed)
script.on_event(defines.events.on_player_gun_inventory_changed, TrackerEvents.on_player_inventory_changed)

-- AI Group Hooks
script.on_event(defines.events.on_unit_group_created, TrackerEvents.on_unit_group_created)

-- Main Loop
script.on_event(defines.events.on_tick, function()
    CombatZones.tick()
    Tracker.tick()
    
    -- Flush JSON buffer to disk every 60 ticks (1 second)
    if game.tick % 60 == 0 then
        Exporter.flush()
    end
end)