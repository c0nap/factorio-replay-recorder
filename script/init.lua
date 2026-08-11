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

    -- unit_number -> group's unique_id, kept up to date by
    -- TrackerEvents.on_unit_added_to_group/on_unit_removed_from_group.
    -- There's no property to read a unit's current group back off the
    -- entity itself, so this is this mod's own record of it.
    storage.unit_group_membership = storage.unit_group_membership or {}

    -- unit_number -> spawner's unit_number, kept up to date by
    -- TrackerEvents.on_entity_spawned. Gives precise nest lineage for a
    -- biter/spitter, on top of the rough proximity-based clustering chunk
    -- snapshots use to group spawners into "bases".
    storage.spawned_by = storage.spawned_by or {}

    -- "surface_force_networkid" -> {expires_at}. A logistics network's
    -- eligibility window for Tier 2 sampling - see script/logistics.lua.
    storage.active_networks = storage.active_networks or {}

    -- chunk_id -> the set of forces seen in that chunk's static dump, so
    -- Logistics.tick() knows which forces to re-check per active zone
    -- without re-scanning the chunk's statics every sample.
    storage.chunk_force_names = storage.chunk_force_names or {}

    -- Diff caches for belt lines and fluid segments - same lazy-init
    -- pattern as storage.inventory_cache, just made explicit here too.
    storage.belt_line_cache = storage.belt_line_cache or {}
    storage.fluid_cache = storage.fluid_cache or {}

    -- Confirmed against the real API: player corpses never go through
    -- on_post_entity_died at all (event.corpses is always empty for a
    -- player's own death), so the on_entity_died -> on_post_entity_died
    -- handoff this table existed for never actually worked - corpse
    -- creation is now handled entirely within Tracker.on_player_died
    -- instead, which needs no pending state of its own. Explicitly
    -- cleared here so saves from before this fix don't keep carrying the
    -- dead table around.
    storage.pending_corpse_info = nil

    -- unit_number -> true for every ground item-entity registered via
    -- script.register_on_object_destroyed, so TrackerEvents.on_object_destroyed
    -- (a global event covering every object ANY mod registers) knows which
    -- destroyed entities are actually ours to clean up, and
    -- ensure_ground_item_registered doesn't re-register one it's already
    -- watching. Entries are removed once on_object_destroyed fires for them.
    storage.registered_ground_items = storage.registered_ground_items or {}

    -- Full recording mode's backfill queue: an array of {surface, chunk_x,
    -- chunk_y} entries for already-generated chunks still waiting to be
    -- activated, drained a bounded number per tick by
    -- CombatZones.process_backfill_queue() - see script/combat_zones.lua.
    storage.pending_backfill = storage.pending_backfill or {}

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
