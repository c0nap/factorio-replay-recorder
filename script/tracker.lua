-- script/tracker.lua
-- Per-tick and per-event recording of everything happening inside active
-- combat zones: unit/vehicle/bot positions, deaths, damage, inventories,
-- and belt contents. CombatZones decides WHERE/WHEN we record; this module
-- decides WHAT gets written once a zone is open.
local Exporter = require("script.exporter")
local CombatZones = require("script.combat_zones")
local TrackerEvents = require("script.tracker_events")
local Classify = require("script.classify")
local Config = require("script.config")
local Keys = require("script.keys")

local Tracker = {}

-- Entity types worth recording a death_event for even outside an active
-- zone (see the `always_record` check in on_entity_died below) - a vehicle
-- counts too (its "demolition" ends the fight for whoever was riding it),
-- but an empty vehicle wreck does not. Keeping score/a running death tally
-- isn't this mod's job; death_event's own victim.force/killer.force fields
-- already carry the force attribution a downstream tool needs to compute
-- that itself, so these deaths just need to reliably show up in the file.
local function is_always_recorded_kind(entity_type)
    return entity_type == "character" or entity_type == "car" or entity_type == "spider-vehicle"
end

local function record_kill_stat(entity)
    local kind = Classify.hostile_kind(entity.type, entity.name)
    if not kind then return end

    local size = Classify.size_of(entity.name)
    local key = Keys.join(kind, size)
    storage.stats.kills[key] = (storage.stats.kills[key] or 0) + 1

    return kind, size
end

-- storage.inventory_cache owner-key constructor per entity type - used to
-- clean up on death so a long-dead entity's cache entry doesn't linger for
-- the rest of the save. Reuses the same TrackerEvents.*_owner_key
-- constructors every owner-key call site does, so a cleanup entry can
-- never drift out of sync with how the key was actually built. item-entity
-- is deliberately NOT here - on_entity_died only covers destruction (fire/
-- explosion), not the far more common "picked up by walking over it" case,
-- so ground items use the strictly more general
-- register_on_object_destroyed/on_object_destroyed mechanism instead (see
-- TrackerEvents.on_object_destroyed), which covers every removal cause in
-- one place rather than needing two.
local CACHE_CLEANUP_KEY_FN = {
    ["car"] = TrackerEvents.vehicle_owner_key,
    ["spider-vehicle"] = TrackerEvents.vehicle_owner_key,
    ["cargo-wagon"] = TrackerEvents.vehicle_owner_key,
    ["artillery-wagon"] = TrackerEvents.vehicle_owner_key,
    ["container"] = TrackerEvents.container_owner_key,
    ["logistic-container"] = TrackerEvents.container_owner_key,
    ["construction-robot"] = TrackerEvents.robot_owner_key,
    ["logistic-robot"] = TrackerEvents.robot_owner_key,
    ["inserter"] = TrackerEvents.inserter_owner_key,
}

function Tracker.on_entity_died(event)
    local entity = event.entity
    if not entity.valid then return end

    -- on_entity_died never fires for a fire/acid patch's time-to-live
    -- expiry - effect_expired is produced via register_on_object_destroyed
    -- instead (see on_trigger_created_entity below). This branch is a
    -- harmless no-op guard in case some other death path (e.g. an
    -- explosion clearing a patch early) ever does route a fire entity
    -- through on_entity_died: without it, a fire "victim" would otherwise
    -- fall through to the generic death_event logic below, which doesn't
    -- make sense for a patch that isn't a combat participant.
    if entity.type == "fire" then
        return
    end

    local cause = event.cause
    local killer_data = nil
    if cause and cause.valid then
        killer_data = {name = cause.name, type = cause.type, force = cause.force.name}
    elseif event.force then
        -- No specific killer entity available (e.g. it died/despawned
        -- before this event ran), but the event can still carry which
        -- force did the killing - worth keeping rather than dropping the
        -- attribution entirely.
        killer_data = {force = event.force.name}
    end

    local always_record = is_always_recorded_kind(entity.type) and entity.force.name ~= "enemy"

    -- Deaths always try to open/extend a combat zone (gated internally on
    -- player proximity), same as before. What's new is that we only bother
    -- writing the death itself to the file if it happened somewhere we
    -- were already recording, or it's a death worth recording regardless
    -- of zone, or the user asked for everything via full recording mode.
    -- Otherwise this is exactly the "entities never near a biter" case the
    -- design doc says to skip.
    local in_zone = CombatZones.notify_and_check(entity.surface, entity.position)

    local kind, size
    if entity.force.name == "enemy" then
        kind, size = record_kill_stat(entity)
    end

    local cleanup_key_fn = CACHE_CLEANUP_KEY_FN[entity.type]
    if cleanup_key_fn and entity.unit_number then
        -- Otherwise every vehicle/container/robot/inserter that's ever
        -- been near a player leaves a permanent entry behind, growing the
        -- save forever over a long campaign even though the entity itself
        -- is gone for good. Corpses are deliberately not covered here -
        -- they don't fire on_entity_died when they eventually decay/expire,
        -- they fire on_character_corpse_expired instead (see
        -- Tracker.on_character_corpse_expired below).
        storage.inventory_cache[cleanup_key_fn(entity.unit_number)] = nil
    end

    if entity.type == "unit" and entity.unit_number then
        -- on_unit_removed_from_group isn't guaranteed to fire on death (as
        -- opposed to a unit leaving a group while still alive), so this is
        -- cleared explicitly here too - otherwise storage.unit_group_membership
        -- leaks one entry per biter/spitter that ever died in a group, forever.
        -- (Lua errors on assigning through a nil key, not just no-ops, so the
        -- unit_number check guards that too.)
        storage.unit_group_membership[entity.unit_number] = nil
        storage.spawned_by[entity.unit_number] = nil
    end

    if not (in_zone or always_record or Config.full_recording_mode()) then
        return
    end

    -- Every death carries a `loot` inventory (what it drops) - usually
    -- empty for a plain biter, but meaningful for a player or vehicle
    -- losing their held items in a fight. Only included when non-empty to
    -- avoid padding every single death_event with an empty object.
    local loot = event.loot and TrackerEvents.flatten_contents(event.loot.get_contents())
    if loot and not next(loot) then loot = nil end

    Exporter.log_event(game.tick, "death_event", {
        victim = {
            name = entity.name,
            type = entity.type,
            force = entity.force.name,
            position = entity.position,
            hostile_kind = kind,
            hostile_size = size,
        },
        killer = killer_data,
        loot = loot,
    })
end

-- A character-corpse's unit_number can't be relied on as an identity key -
-- confirmed by a real crash in an earlier round ("attempt to concatenate
-- field 'unit_number' (a nil value)" on an actual corpse in a live game),
-- and every corpse-owner_kind/corpse_created/corpse_expired check stayed
-- at 0 events in the session right after that crash was patched by simply
-- requiring corpse.unit_number to be truthy before using it - consistent
-- with unit_number never actually being populated on this entity type, not
-- just occasionally nil. character_corpse_player_index and
-- character_corpse_tick_of_death are used instead everywhere a corpse
-- needs a stable identity: a single player can only die once per game
-- tick, so the pair uniquely and stably identifies one corpse for its
-- whole lifetime regardless of whether unit_number is ever populated.
local function corpse_owner_key(corpse)
    return Keys.join("corpse", corpse.character_corpse_player_index, corpse.character_corpse_tick_of_death)
end

-- Player corpses do NOT go through on_entity_died/on_post_entity_died at
-- all - confirmed against the real API/developer statements: the generic
-- entity death system is entirely unaware of the character death system,
-- so on_post_entity_died's `event.corpses` is always empty for a player's
-- own death (that's the actual reason corpse_created stayed at 0 events
-- across every earlier attempt built on that event - not a bug in the
-- pending-info handoff, the handoff's source event never fires with
-- useful data in the first place). on_player_died is the correct event,
-- but its payload only carries `player_index`/`cause` - not the corpse
-- itself - so the corpse has to be looked up by hand right after.
function Tracker.on_player_died(event)
    local player = game.get_player(event.player_index)
    if not player then return end

    local cause = event.cause
    local killer_data = nil
    if cause and cause.valid then
        killer_data = {name = cause.name, type = cause.type, force = cause.force.name}
    end

    -- character_corpse_player_index/character_corpse_tick_of_death are
    -- confirmed properties specific to the character-corpse entity type
    -- (distinct from - and not overlapping with - the generic decorative
    -- "corpse" type biters/vehicles leave behind). Matching on both the
    -- player index AND this tick (corpse creation happens right before
    -- on_player_died fires, same tick) picks out the corpse THIS death
    -- just created, not a still-unlooted one left over from an earlier
    -- death this same player never fully cleared.
    local corpses = player.surface.find_entities_filtered{type = "character-corpse"}

    for _, corpse in pairs(corpses) do
        if corpse.valid and corpse.character_corpse_player_index == event.player_index
            and corpse.character_corpse_tick_of_death == game.tick then
            Exporter.log_event(game.tick, "corpse_created", {
                owner = corpse_owner_key(corpse),
                position = corpse.position,
                player_index = event.player_index,
                player_name = player.name,
                death_tick = corpse.character_corpse_tick_of_death,
                killer = killer_data,
            })
            break
        end
    end
end

-- Fires when a character corpse times out or is fully looted (not when
-- mined - see on_pre_player_mined_item for that, not hooked here since
-- mining a corpse is rare and the cache entry would just get overwritten
-- by the next scan anyway). This is the actual fix for the "corpse cache
-- entries leak forever" gap: without this, storage.inventory_cache["corpse_"
-- ..id] has no event that ever tells us the corpse is gone for good.
function Tracker.on_character_corpse_expired(event)
    local corpse = event.corpse
    if not corpse or not corpse.valid then return end

    local owner_key = corpse_owner_key(corpse)
    storage.inventory_cache[owner_key] = nil
    Exporter.log_event(game.tick, "corpse_expired", {owner = owner_key})
end

function Tracker.on_player_respawned(event)
    local player = game.players[event.player_index]
    if not player then return end

    -- The "goal reset": mark the point a player re-enters play after dying
    -- so a viewer can jump straight from the death to the respawn instead
    -- of sitting through empty downtime. The combat zone itself doesn't
    -- follow the player to their spawn point - it naturally stops
    -- recording that area once no player is near it, per is_player_nearby.
    Exporter.log_event(game.tick, "player_respawn", {
        player_index = event.player_index,
        force = player.force.name,
        position = player.character and player.character.position or nil
    })
end

function Tracker.on_script_trigger_effect(event)
    -- effect_id is "replay_combat_trigger:<projectile-or-stream-name>", set
    -- up in data.lua, so we know not just THAT something hit but WHAT hit.
    local weapon_name = event.effect_id:match("^replay_combat_trigger:(.+)$")
    if not weapon_name then return end

    local surface = game.surfaces[event.surface_index]
    if not surface then return end

    local target_entity = event.target_entity
    local position = event.target_position or (target_entity and target_entity.valid and target_entity.position)
    if not position then return end

    local in_zone = CombatZones.notify_and_check(surface, position)
    if not (in_zone or Config.full_recording_mode()) then return end

    local source_entity = event.source_entity
    Exporter.log_event(game.tick, "projectile_impact", {
        weapon = weapon_name,
        source = (source_entity and source_entity.valid) and {
            name = source_entity.name,
            position = source_entity.position
        } or nil,
        target_position = position,
        target = (target_entity and target_entity.valid) and target_entity.name or nil
    })
end

-- The creation half of "an acid entity loses potency and fades away" from
-- the design doc ("a spitter shoots acid at a tile") - also where the
-- fade-out half gets set up, via TrackerEvents.on_object_destroyed.
function Tracker.on_trigger_created_entity(event)
    local entity = event.entity
    if not entity or not entity.valid then return end

    -- Both the flamethrower's flame patch and a spitter/worm's acid splash
    -- are entity.type == "fire" on real 2.0.76 data.
    if entity.type ~= "fire" then return end

    local in_zone = CombatZones.notify_and_check(entity.surface, entity.position)
    if not (in_zone or Config.full_recording_mode()) then return end

    -- on_entity_died never fires for a fire/acid patch's expiry (see
    -- Tracker.on_entity_died's fire branch), so effect_expired comes from
    -- register_on_object_destroyed instead - the same mechanism
    -- TrackerEvents.ground_item_key uses for ground items. The entity is
    -- already gone by the time that event fires, so its name/position
    -- have to be cached now, at creation, in storage.registered_fire_effects.
    local ok, registration_number = pcall(function() return script.register_on_object_destroyed(entity) end)
    if ok then
        storage.registered_fire_effects[registration_number] = {name = entity.name, position = entity.position}
    else
        log("[replay-recorder] Tracker: register_on_object_destroyed failed for " .. entity.name .. ": " .. tostring(registration_number))
    end

    local source = event.source
    Exporter.log_event(game.tick, "effect_created", {
        name = entity.name,
        position = entity.position,
        source = (source and source.valid) and source.name or nil
    })
end

-- "unit"/"unit-spawner" (biters/spitters/worms and their nests) need to be
-- tracked as damage TARGETS here too, not just as `dealer` values - a real
-- combat replay wants "the tank shot at this biter three times before it
-- died" the same way it wants any other target's damage history.
local DAMAGE_TRACKED_TYPES = {
    ["turret"] = true,
    ["ammo-turret"] = true,
    ["electric-turret"] = true,
    ["fluid-turret"] = true,
    ["wall"] = true,
    ["gate"] = true,
    ["character"] = true,
    ["car"] = true,
    ["spider-vehicle"] = true,
    ["locomotive"] = true,
    ["artillery-wagon"] = true,
    ["unit"] = true,
    ["unit-spawner"] = true,
}

function Tracker.on_entity_damaged(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    if not DAMAGE_TRACKED_TYPES[entity.type] then return end

    local in_zone = CombatZones.notify_and_check(entity.surface, entity.position)
    if not (in_zone or Config.full_recording_mode()) then return end

    -- `cause` is the entity that triggered the damage (character, turret,
    -- vehicle, ...); `source` is what's directly dealing it (a projectile,
    -- flame, sticker, ...) - for a bare physical collision (e.g. a vehicle
    -- running something over), `source` equals `cause` rather than being
    -- nil, since the vehicle itself is "directly dealing" the damage when
    -- nothing more specific is involved. tools/verify_checklist.py's
    -- shot-vs-run-over check relies on this: dealt_by == dealer means a
    -- bare collision, dealt_by naming something else means a weapon hit.
    Exporter.log_event(game.tick, "damage_event", {
        target = entity.name,
        target_type = entity.type,
        position = entity.position,
        damage = event.final_damage_amount,
        dealer = event.cause and event.cause.name or "unknown",
        dealt_by = event.source and event.source.name or nil,
    })
end

-- Which inventory slots to combine per vehicle type, confirmed against the
-- real defines.inventory list (car_trash and the wagon inventories were
-- previously missed - cars/tanks were undercounting their own trash slot,
-- and cargo/artillery wagons weren't tracked at all despite trains being
-- explicitly a "combat vehicle" per the design doc). fluid-wagon has no
-- item inventory - fluids aren't part of this mod's item-based inventory
-- tracking, so it's deliberately absent here and only gets position
-- tracking via mobile_positions.
local VEHICLE_INVENTORY_SLOTS = {
    ["car"] = {defines.inventory.car_trunk, defines.inventory.car_ammo, defines.inventory.car_trash},
    ["spider-vehicle"] = {defines.inventory.spider_trunk, defines.inventory.spider_ammo, defines.inventory.spider_trash},
    ["cargo-wagon"] = {defines.inventory.cargo_wagon},
    ["artillery-wagon"] = {defines.inventory.artillery_wagon_ammo},
}

-- There's no on_*_inventory_changed event for vehicles the way there is
-- for players, so this is diffed once per tick while the vehicle is
-- inside an active zone (see Tracker.tick), never map-wide.
local function vehicle_inventory_contents(entity)
    local slots = VEHICLE_INVENTORY_SLOTS[entity.type]
    if not slots then return {} end

    local contents = {}
    for _, slot in ipairs(slots) do
        local inv = entity.get_inventory(slot)
        if inv then
            for name, count in pairs(TrackerEvents.flatten_contents(inv.get_contents())) do
                contents[name] = (contents[name] or 0) + count
            end
        end
    end
    return contents
end

-- Ties a biter/spitter back to the attack/expansion party it belongs to,
-- so a viewer can render the group as a single parented object.
--
-- There is no `unit_group` property on LuaEntity to read this back off the
-- unit directly - group membership is only ever announced through the
-- on_unit_added_to_group/on_unit_removed_from_group events (see
-- TrackerEvents), which keep storage.unit_group_membership up to date.
-- This just reads that record.
local function unit_group_id(ent)
    if ent.type ~= "unit" then return nil end
    return storage.unit_group_membership[ent.unit_number]
end

-- Everything "physically here" that isn't already covered by the mobile
-- loop or belt loop above: chests, corpses, inserter hands, and ground
-- items. Read every tick, same as belts - these are cheap, bounded-by-
-- chunk-size queries, and (design doc) items in a chest or an inserter's
-- grip are exactly the "immediately here on the battlefield" tier, not
-- the "probably on the way" one that script/logistics.lua and
-- script/item_chains.lua sample on a slow interval instead.
local PHYSICAL_ITEM_TYPES = {"container", "logistic-container", "character-corpse", "inserter", "item-entity"}

local function scan_physical_items(surface, area)
    local entities = surface.find_entities_filtered{area = area, type = PHYSICAL_ITEM_TYPES}

    for _, ent in ipairs(entities) do
        if ent.valid and ent.type == "character-corpse" then
            -- Keyed separately from the unit_number-gated branch below -
            -- see corpse_owner_key's comment for why a corpse can't be
            -- gated on ent.unit_number the way everything else here is.
            -- Corpses aren't in the static chunk dump (they're dynamic -
            -- they appear and eventually decay) and inventory_delta
            -- carries no position field otherwise, so this is the only
            -- place a corpse's location is ever reported. Not redundant
            -- with death_event's `loot`: loot is what was dropped at the
            -- moment of death, this is what happens to that pile
            -- afterward (looting, partial decay).
            TrackerEvents.log_inventory_delta(corpse_owner_key(ent), "corpse", TrackerEvents.corpse_contents(ent), {position = ent.position})
        elseif ent.valid and ent.type == "item-entity" then
            -- Also keyed separately, and for the same reason as corpses -
            -- item-entity is CONFIRMED to never have a unit_number, unlike
            -- every other type below. TrackerEvents.ground_item_key
            -- registers it for on_object_destroyed (idempotently - see
            -- its own comment) and hands back the resulting stable key.
            -- Same "no other position channel" situation as corpses too -
            -- item-entities are dynamic (not in the static chunk dump)
            -- and inventory_delta otherwise carries no position.
            local owner_key = TrackerEvents.ground_item_key(ent)
            if owner_key then
                TrackerEvents.log_inventory_delta(owner_key, "ground_item", TrackerEvents.ground_item_contents(ent), {position = ent.position})
            end
        elseif ent.valid and ent.unit_number then
            if ent.type == "container" or ent.type == "logistic-container" then
                TrackerEvents.log_inventory_delta(TrackerEvents.container_owner_key(ent.unit_number), "container", TrackerEvents.container_contents(ent))
            elseif ent.type == "inserter" then
                TrackerEvents.log_inventory_delta(TrackerEvents.inserter_owner_key(ent.unit_number), "inserter_hand", TrackerEvents.held_stack_contents(ent))
            end
        end
    end
end

local MOBILE_ENTITY_TYPES = {"unit", "character", "car", "spider-vehicle", "locomotive",
        "cargo-wagon", "fluid-wagon", "artillery-wagon",
        "combat-robot", "construction-robot", "logistic-robot"}
local BELT_ENTITY_TYPES = {"transport-belt", "underground-belt", "splitter"}

local function process_mobile_entities(entities, mobile_data)
    for _, ent in ipairs(entities) do
        if ent.valid then
            local record = {
                id = ent.unit_number or (ent.player and ent.player.index),
                name = ent.name,
                type = ent.type,
                force = ent.force.name,
                position = ent.position,
                orientation = ent.orientation,
                group_id = unit_group_id(ent),
                spawner_id = storage.spawned_by[ent.unit_number],
            }
            table.insert(mobile_data, record)

            if VEHICLE_INVENTORY_SLOTS[ent.type] then
                TrackerEvents.log_inventory_delta(TrackerEvents.vehicle_owner_key(ent.unit_number), "vehicle", vehicle_inventory_contents(ent))
            elseif ent.type == "construction-robot" or ent.type == "logistic-robot" then
                local inv = ent.get_inventory(defines.inventory.robot_cargo)
                if inv then
                    TrackerEvents.log_inventory_delta(TrackerEvents.robot_owner_key(ent.unit_number), "robot", TrackerEvents.flatten_contents(inv.get_contents()))
                end
            end
        end
    end
end

-- One tick's worth of scanning for a given surface, restricted to `area`
-- if given, or the whole surface if `area` is nil (Lua's table
-- constructor drops a nil-valued key entirely, so `{area = nil, ...}`
-- and `{...}` with no area key at all are the same call - `find_entities_
-- filtered` treats a missing area as "search everywhere"). Shared by both
-- Tracker.tick() branches below so the actual scanning logic - what a
-- mobile entity's record looks like, how belts/physical items get diffed
-- - only exists once regardless of which query strategy found them.
local function tick_area(surface, area, mobile_data)
    process_mobile_entities(surface.find_entities_filtered{area = area, type = MOBILE_ENTITY_TYPES}, mobile_data)

    local belt_entities = surface.find_entities_filtered{area = area, type = BELT_ENTITY_TYPES}
    TrackerEvents.log_belt_contents(belt_entities)

    scan_physical_items(surface, area)
end

function Tracker.tick()
    local mobile_data = {}

    if Config.full_recording_mode() then
        -- Every generated chunk is active under full recording (see
        -- CombatZones.activate_full_recording_chunk), and there's no
        -- storage.active_zones entry per chunk to loop over anymore -
        -- looping 3 find_entities_filtered calls per chunk, every tick,
        -- is exactly what made a save with more than a couple hundred
        -- generated chunks freeze solid. One whole-surface query per
        -- type finds exactly the same entities a per-chunk loop would,
        -- through 3 engine calls total (per surface) instead of 3 per
        -- chunk.
        --
        -- game.surfaces is indexed by BOTH numeric index and name, both
        -- pointing at the same LuaSurface - `seen` dedupes by
        -- surface.index so a naive `pairs()` walk doesn't scan (and
        -- double-report) every surface twice.
        local seen = {}
        for _, surface in pairs(game.surfaces) do
            if not seen[surface.index] then
                seen[surface.index] = true
                tick_area(surface, nil, mobile_data)
            end
        end
    else
        for _, zone in pairs(storage.active_zones) do
            tick_area(zone.surface, CombatZones.chunk_area(zone.chunk_x, zone.chunk_y), mobile_data)
        end
    end

    if #mobile_data > 0 then
        Exporter.log_event(game.tick, "mobile_positions", mobile_data)
    end
end

return Tracker
