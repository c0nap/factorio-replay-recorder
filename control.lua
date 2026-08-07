-- control.lua
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")
local Tracker = require("script.tracker")

local function on_init()
    Exporter.init()
    CombatZones.init()
end

script.on_init(on_init)
script.on_configuration_changed(on_init)

-- Hook Combat Events
script.on_event(defines.events.on_entity_died, Tracker.on_entity_died)
script.on_event(defines.events.on_script_trigger_effect, Tracker.on_script_trigger_effect)

-- Main Loop
script.on_event(defines.events.on_tick, function()
    CombatZones.tick()
    Tracker.tick()
    
    -- Flush JSON buffer to disk every 60 ticks (1 second) to minimize I/O overhead
    if game.tick % 60 == 0 then
        Exporter.flush()
    end
end)