-- script/init.lua
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")

local Init = {}

function Init.setup()
    Exporter.init()

    storage.inventory_cache = storage.inventory_cache or {}
    storage.unit_groups = storage.unit_groups or {}
    storage.stats = storage.stats or {deaths = {}, kills = {}}

    CombatZones.init()
end

return Init