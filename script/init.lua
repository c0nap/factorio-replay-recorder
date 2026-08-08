-- script/init.lua
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")

local Init = {}

local function ensure_storage()
    -- Table only - never touches replay.json itself. Guards against a
    -- save that reaches on_configuration_changed without ever having run
    -- Exporter.init() (e.g. state lost some other way); flushing later
    -- would otherwise index a nil buffer and error.
    storage.replay_buffer = storage.replay_buffer or {}
    storage.inventory_cache = storage.inventory_cache or {}
    storage.stats = storage.stats or {deaths = {}, kills = {}}

    -- unit_number -> group_number, kept up to date by
    -- TrackerEvents.on_unit_added_to_group/on_unit_removed_from_group.
    -- There's no property to read a unit's current group back off the
    -- entity itself, so this is this mod's own record of it.
    storage.unit_group_membership = storage.unit_group_membership or {}

    -- Was written every time a biter unit group formed but never actually
    -- read back anywhere; dropping it stops it from growing forever across
    -- a long save. Explicitly cleared here so saves from before this fix
    -- don't keep carrying the stale table around.
    storage.unit_groups = nil
end

-- Brand new game/save only: reset all mod state and truncate replay.json.
function Init.on_init()
    ensure_storage()
    Exporter.init()
    CombatZones.init()
end

-- Fires on mod add/remove/update for an EXISTING save, not just new games.
-- Must only bring storage up to date - it must never touch replay.json,
-- or updating the mod (or any other mod) mid-campaign would silently
-- erase everything recorded so far.
function Init.on_configuration_changed()
    ensure_storage()
    CombatZones.init()
end

return Init
