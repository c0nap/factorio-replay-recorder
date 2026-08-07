-- script/init.lua
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")

local Init = {}

function Init.setup()
    Exporter.init()
    CombatZones.init()
    
    -- Initialize storage for new tracking systems
    storage.player_inventories = storage.player_inventories or {}
    storage.unit_groups = storage.unit_groups or {}
end

return Init