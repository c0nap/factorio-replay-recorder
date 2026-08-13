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
local Logistics = require("script.logistics")
local ItemChains = require("script.item_chains")
local FluidChains = require("script.fluid_chains")
local Init = require("script.init")
local Config = require("script.config")
local Diagnostics = require("script.diagnostics")
local BattlefieldMarker = require("script.battlefield_marker")

script.on_init(Init.on_init)
script.on_configuration_changed(Init.on_configuration_changed)

-- Combat & Death Hooks
script.on_event(defines.events.on_entity_died, Tracker.on_entity_died)
script.on_event(defines.events.on_player_died, Tracker.on_player_died)
script.on_event(defines.events.on_character_corpse_expired, Tracker.on_character_corpse_expired)
script.on_event(defines.events.on_entity_damaged, Tracker.on_entity_damaged)
script.on_event(defines.events.on_script_trigger_effect, Tracker.on_script_trigger_effect)
script.on_event(defines.events.on_trigger_created_entity, Tracker.on_trigger_created_entity)
script.on_event(defines.events.on_player_respawned, Tracker.on_player_respawned)
script.on_event(defines.events.on_object_destroyed, TrackerEvents.on_object_destroyed)

-- Inventory Hooks
script.on_event(defines.events.on_player_main_inventory_changed, TrackerEvents.on_player_inventory_changed)
script.on_event(defines.events.on_player_ammo_inventory_changed, TrackerEvents.on_player_inventory_changed)
script.on_event(defines.events.on_player_gun_inventory_changed, TrackerEvents.on_player_inventory_changed)
script.on_event(defines.events.on_player_dropped_item, TrackerEvents.on_player_dropped_item)

-- AI Group & Spawning Hooks
script.on_event(defines.events.on_unit_group_created, TrackerEvents.on_unit_group_created)
script.on_event(defines.events.on_unit_added_to_group, TrackerEvents.on_unit_added_to_group)
script.on_event(defines.events.on_unit_removed_from_group, TrackerEvents.on_unit_removed_from_group)
script.on_event(defines.events.on_entity_spawned, TrackerEvents.on_entity_spawned)

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
        CombatZones.queue_full_recording_backfill()
    else
        -- Switching back to cropped mode: zones full recording opened stay
        -- open forever otherwise, since they were marked permanent instead
        -- of given a timeout. Give them a normal timeout so they wind down
        -- like any other zone instead of recording everything forever.
        CombatZones.expire_permanent_zones()
    end
end)

-- Main Loop. Factorio runs at 60 ticks/second.
script.on_event(defines.events.on_tick, function()
    local diag = Diagnostics.start_tick()

    -- Flushes on the fixed interval as usual, but also early whenever the
    -- buffer has grown past Config.max_buffered_events() - e.g. during a
    -- full-recording backfill burst, where several chunk_snapshot events/
    -- tick would otherwise all pile up for a full flush_interval_ticks
    -- before the first flush call ever ran. Exporter.flush() itself caps
    -- how much it writes per call to that same limit, so this can fire on
    -- consecutive ticks to drain a large backlog in several small writes
    -- instead of waiting one at a time.
    --
    -- Deliberately checked BEFORE this tick's own backfill/scan work below,
    -- against whatever's left over from earlier ticks - real diagnostics
    -- data showed that checking it AFTER (the previous ordering) let a
    -- single tick's heavy backfill scan and the write it triggered stack
    -- into one frame, producing ticks over 450ms during a full-recording
    -- burst. Checking the carried-over buffer first instead means a tick
    -- whose own scan pushes the buffer over the threshold pays for that
    -- write NEXT tick, not the same one - halving the worst-case single-
    -- frame cost instead of just shrinking it.
    local write_profiler = nil
    if game.tick % Config.flush_interval_ticks() == 0 or #storage.replay_buffer >= Config.max_buffered_events() then
        write_profiler = Diagnostics.start_write(diag)
        Exporter.flush()
        if write_profiler then write_profiler.stop() end
    end

    Diagnostics.start_scan(diag)

    -- Drains a bounded number of chunks/tick from full recording mode's
    -- backfill queue (see CombatZones.queue_full_recording_backfill) - a
    -- no-op cost once the queue is empty, which is the common case.
    CombatZones.process_backfill_queue()

    CombatZones.tick()
    Tracker.tick()

    -- "Distant" data - logistics network contents, far-chain item
    -- rollups, fluid segments - is sampled far less often than the
    -- per-tick physical scan above; see Config.distant_sample_interval_ticks.
    --
    -- Under full recording mode, storage.active_zones stays empty (see
    -- CombatZones.activate_full_recording_chunk) - Logistics.tick()/
    -- ItemChains.tick() naturally become no-ops as a result, correctly:
    -- everything they'd otherwise report as "distant" is already covered
    -- directly by Tracker.tick()'s whole-surface scan when there's no
    -- cropping happening at all. FluidChains.tick() is the one exception
    -- (fluids have no per-tick Tier 1 equivalent) - it handles full
    -- recording mode internally instead of relying on active_zones.
    if game.tick % Config.distant_sample_interval_ticks() == 0 then
        Logistics.tick(storage.active_zones, CombatZones.is_zone_active, CombatZones.chunk_area)
        ItemChains.tick(storage.active_zones, CombatZones.is_zone_active, CombatZones.chunk_area)
        FluidChains.tick(storage.active_zones, CombatZones.chunk_area)
    end

    Diagnostics.end_scan(diag)
    Diagnostics.end_tick(diag, write_profiler)

    BattlefieldMarker.tick()
end)
