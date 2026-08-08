-- control.lua
-- This is the mod's entry point: Factorio loads control.lua once and runs
-- everything below for the lifetime of the game. It doesn't contain any
-- recording logic itself - it just wires Factorio's events to the module
-- that handles them (see script/*.lua) and drives the two things that have
-- to happen on a schedule: CombatZones/Tracker polling entities every
-- tick, and the JSON buffer being flushed to disk periodically.
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")
local Tracker = require("script.tracker")
local TrackerEvents = require("script.tracker_events")
local Init = require("script.init")
local Config = require("script.config")

script.on_init(Init.on_init)
script.on_configuration_changed(Init.on_configuration_changed)

-- Combat & Death Hooks
script.on_event(defines.events.on_entity_died, Tracker.on_entity_died)
script.on_event(defines.events.on_entity_damaged, Tracker.on_entity_damaged)
script.on_event(defines.events.on_script_trigger_effect, Tracker.on_script_trigger_effect)
script.on_event(defines.events.on_player_respawned, Tracker.on_player_respawned)

-- Inventory Hooks
script.on_event(defines.events.on_player_main_inventory_changed, TrackerEvents.on_player_inventory_changed)
script.on_event(defines.events.on_player_ammo_inventory_changed, TrackerEvents.on_player_inventory_changed)
script.on_event(defines.events.on_player_gun_inventory_changed, TrackerEvents.on_player_inventory_changed)

-- AI Group Hooks
script.on_event(defines.events.on_unit_group_created, TrackerEvents.on_unit_group_created)
script.on_event(defines.events.on_unit_added_to_group, TrackerEvents.on_unit_added_to_group)
script.on_event(defines.events.on_unit_removed_from_group, TrackerEvents.on_unit_removed_from_group)

-- Full Recording Mode: every newly generated chunk is activated immediately
-- rather than waiting for combat, and flipping the setting on mid-game
-- back-fills every chunk that already exists.
script.on_event(defines.events.on_chunk_generated, function(event)
    if Config.full_recording_mode() then
        CombatZones.activate_full_recording_chunk(event.surface, event.position.x, event.position.y)
    end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
    if event.setting ~= "rrec-full-recording-mode" then return end

    if Config.full_recording_mode() then
        CombatZones.activate_all_existing_chunks()
    else
        -- Switching back to cropped mode: zones full recording opened stay
        -- open forever otherwise, since they were marked permanent instead
        -- of given a timeout. Give them a normal timeout so they wind down
        -- like any other zone instead of recording everything forever.
        CombatZones.expire_permanent_zones()
    end
end)

-- Main Loop. Factorio runs at 60 ticks/second, so this is once a second.
local FLUSH_INTERVAL_TICKS = 60

script.on_event(defines.events.on_tick, function()
    CombatZones.tick()
    Tracker.tick()

    if game.tick % FLUSH_INTERVAL_TICKS == 0 then
        Exporter.flush()
    end
end)
