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

local Tracker = {}

-- Entities whose death should be scored like a "goal against" their force -
-- the sports-scoreboard framing from the design doc. A vehicle counts too
-- (its "demolition" ends the fight for whoever was riding it), but an empty
-- vehicle wreck does not - only entities that fielded a player at some
-- point are worth putting on the scoreboard.
local function is_scoreable_kind(entity_type)
    return entity_type == "character" or entity_type == "car" or entity_type == "spider-vehicle"
end

local function record_score_event(entity, killer_data)
    storage.stats.deaths[entity.force.name] = (storage.stats.deaths[entity.force.name] or 0) + 1

    Exporter.log_event(game.tick, "score_update", {
        force = entity.force.name,
        entity = entity.name,
        entity_type = entity.type,
        position = entity.position,
        killer = killer_data,
        deaths_this_force = storage.stats.deaths[entity.force.name]
    })
end

local function record_kill_stat(entity)
    local kind = Classify.hostile_kind(entity.type, entity.name)
    if not kind then return end

    local size = Classify.size_of(entity.name)
    local key = kind .. "_" .. size
    storage.stats.kills[key] = (storage.stats.kills[key] or 0) + 1

    return kind, size
end

-- storage.inventory_cache key prefix per entity type whose owner_key is
-- "<prefix><unit_number>" - used to clean up on death so a long-dead
-- entity's cache entry doesn't linger for the rest of the save. item-entity
-- is deliberately NOT here - on_entity_died only covers destruction (fire/
-- explosion), not the far more common "picked up by walking over it" case,
-- so ground items use the strictly more general
-- register_on_object_destroyed/on_object_destroyed mechanism instead (see
-- TrackerEvents.on_object_destroyed), which covers every removal cause in
-- one place rather than needing two.
local CACHE_CLEANUP_PREFIX = {
    ["car"] = "vehicle_",
    ["spider-vehicle"] = "vehicle_",
    ["cargo-wagon"] = "vehicle_",
    ["artillery-wagon"] = "vehicle_",
    ["container"] = "container_",
    ["logistic-container"] = "container_",
    ["construction-robot"] = "robot_",
    ["logistic-robot"] = "robot_",
    ["inserter"] = "inserter_",
}

function Tracker.on_entity_died(event)
    local entity = event.entity
    if not entity.valid then return end

    -- CONFIRMED (PR #14 probe): on_entity_died never fires for a fire/acid
    -- patch's time-to-live expiry - a real session with both the
    -- flamethrower (step 12) and a spitter fight (step 14) produced zero
    -- on_entity_died lines for any fire-typed entity, despite
    -- on_trigger_created_entity confirming they were created. effect_expired
    -- is instead produced via register_on_object_destroyed - see
    -- on_trigger_created_entity below (where it's registered) and
    -- TrackerEvents.on_object_destroyed (where it actually fires). This
    -- branch is kept as a harmless no-op in case some other death path -
    -- an explosion clearing a patch early, say - ever does route a fire
    -- entity through on_entity_died after all: without it, a fire "victim"
    -- would otherwise fall through to the generic death_event/scoring
    -- logic below, which doesn't make sense for a patch that isn't a
    -- combat participant.
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

    local scoreable = is_scoreable_kind(entity.type) and entity.force.name ~= "enemy"

    -- Deaths always try to open/extend a combat zone (gated internally on
    -- player proximity), same as before. What's new is that we only bother
    -- writing the death itself to the file if it happened somewhere we
    -- were already recording, or it's scoreboard-worthy, or the user asked
    -- for everything via full recording mode. Otherwise this is exactly
    -- the "entities never near a biter" case the design doc says to skip.
    local in_zone = CombatZones.notify_and_check(entity.surface, entity.position)

    local kind, size
    if entity.force.name == "enemy" then
        kind, size = record_kill_stat(entity)
    end

    if scoreable then
        record_score_event(entity, killer_data)
    end

    local cleanup_prefix = CACHE_CLEANUP_PREFIX[entity.type]
    if cleanup_prefix and entity.unit_number then
        -- Otherwise every vehicle/container/robot/inserter that's ever
        -- been near a player leaves a permanent entry behind, growing the
        -- save forever over a long campaign even though the entity itself
        -- is gone for good. Corpses are deliberately not covered here -
        -- they don't fire on_entity_died when they eventually decay/expire,
        -- they fire on_character_corpse_expired instead (see
        -- Tracker.on_character_corpse_expired below).
        storage.inventory_cache[cleanup_prefix .. entity.unit_number] = nil
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

    if not (in_zone or scoreable or Config.full_recording_mode()) then
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
    return "corpse_" .. corpse.character_corpse_player_index .. "_" .. corpse.character_corpse_tick_of_death
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

    -- INVESTIGATING (PR #15): unconditional, not gated on entity.type -
    -- effect_created has shown ONLY "flamethrower-turret" as a source
    -- across every real checklist run so far, even ones with confirmed
    -- acid damage landing. If a spitter/worm's acid attack creates SOME
    -- entity via this event (even one whose type isn't "fire"), this
    -- catches it; if it never fires for acid at all, this stays silent
    -- for it and data-updates.lua's stream-action probe is the next
    -- place to look. Remove once resolved.
    storage.trigger_entity_probe_seen = storage.trigger_entity_probe_seen or {}
    local probe_key = entity.name .. "/" .. entity.type
    if not storage.trigger_entity_probe_seen[probe_key] then
        storage.trigger_entity_probe_seen[probe_key] = true
        local source_for_probe = event.source
        log("[replay-recorder-probe] on_trigger_created_entity: name=" .. entity.name .. " type=" .. entity.type
            .. " source=" .. ((source_for_probe and source_for_probe.valid) and source_for_probe.name or "nil"))
    end

    -- CONFIRMED (PR #13/#14 probes) for the flamethrower's flame patch:
    -- entity.type == "fire" on real 2.0.76 data. NOT independently
    -- confirmed for a spitter/worm's acid - see the investigation note in
    -- data-updates.lua, which is where that's being chased down now.
    -- Kept as `~= "fire"` rather than narrowing further since that's
    -- still the only confirmed shape either patch type could take.
    if entity.type ~= "fire" then return end

    local in_zone = CombatZones.notify_and_check(entity.surface, entity.position)
    if not (in_zone or Config.full_recording_mode()) then return end

    -- CONFIRMED (PR #14 probe): on_entity_died never fires for a fire/acid
    -- patch's time-to-live expiry (see Tracker.on_entity_died's fire
    -- branch), so effect_expired has to come from register_on_object_
    -- destroyed instead - the same mechanism TrackerEvents.ground_item_key
    -- uses for ground items, which fires regardless of WHY the entity
    -- disappeared. The entity is already gone by the time on_object_
    -- destroyed fires, so its name/position have to be cached now, at
    -- creation, in storage.registered_fire_effects - there's nothing left
    -- to read them off of once the event actually arrives.
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

-- FIXED (PR #15): "unit"/"unit-spawner" (biters/spitters/worms and their
-- nests as DAMAGE TARGETS, not dealers - they were always fine as a
-- `dealer` value, e.g. "small-biter" already showed up there) were never
-- in this list, so damage dealt TO one was silently dropped regardless of
-- who dealt it. This is more than a checklist-test gap: a real combat
-- replay wants "the tank shot at this biter three times before it died"
-- the same way it wants any other target's damage history, and it's what
-- was actually blocking the vehicle shot-vs-run-over check - shoot_target/
-- run_over_target are both small-biter (type "unit"), so damage_event
-- could never contain a "tank" dealer at all before this, regardless of
-- what the player did.
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

    -- CONFIRMED against the real 2.0.76 on_entity_damaged docs: `cause`
    -- is "the entity that originally triggered the events that led to
    -- this damage... (e.g. the character, turret, etc. that pulled the
    -- trigger)" and `source` is "the entity that is directly dealing the
    -- damage... (e.g. the projectile, flame, sticker, grenade, laser
    -- beam, etc.)" - both fields exist, both are nilable (LuaEntity?),
    -- and both mean exactly what this file already assumed before that
    -- was ever checked. A nil `source` is therefore an explicitly
    -- anticipated, normal case per the schema (not something we invented)
    -- - consistent with a bare physical collision having no discrete
    -- "delivery mechanism" entity the way a fired weapon does.
    --
    -- STILL OPEN: not the field mapping (settled above), but whether a
    -- real vehicle-vs-unit collision - now actually reachable at all
    -- since DAMAGE_TRACKED_TYPES gained "unit" above, having always
    -- silently dropped this exact combination before - really does
    -- produce a nil source in practice. That's runtime behavior, not
    -- documentation, so this probe stays for one more real vehicle-
    -- combat step to confirm it. Remove once confirmed.
    if event.cause and event.cause.valid and (event.cause.type == "car" or event.cause.type == "spider-vehicle") then
        storage.vehicle_damage_probe_seen = storage.vehicle_damage_probe_seen or {}
        local probe_key = tostring(entity.unit_number) .. "/" .. event.cause.name
        if not storage.vehicle_damage_probe_seen[probe_key] then
            storage.vehicle_damage_probe_seen[probe_key] = true
            local function safe_name(obj)
                local ok, v = pcall(function() return obj and obj.valid and obj.name or nil end)
                if not ok then return "ERROR(" .. tostring(v) .. ")" end
                return v or "nil"
            end
            local function safe_field(fn)
                local ok, v = pcall(fn)
                if not ok then return "ERROR(" .. tostring(v) .. ")" end
                if v == nil then return "nil" end
                return tostring(v)
            end
            log("[replay-recorder-probe] on_entity_damaged (vehicle cause): target=" .. entity.name
                .. " cause=" .. safe_name(event.cause)
                .. " source=" .. safe_name(event.source)
                .. " force=" .. safe_field(function() return event.force and event.force.name end)
                .. " damage_type=" .. safe_field(function() return event.damage_type and event.damage_type.name end)
                .. " original_damage_amount=" .. safe_field(function() return event.original_damage_amount end)
                .. " final_damage_amount=" .. safe_field(function() return event.final_damage_amount end)
                .. " final_health=" .. safe_field(function() return event.final_health end))
        end
    end

    -- `cause` is assumed to be who's responsible (the character/turret/
    -- biter/vehicle that pulled the trigger) and `source` the literal
    -- thing dealing the damage right now (the projectile/flame/sticker it
    -- fired) - NOT independently confirmed against the real event fields
    -- for this specific event, see the probe above.
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

-- INVESTIGATING (PR #15): reverse of defines.entity_status (built once, at
-- load time) so the inserter probe below can log LuaEntity.status as a
-- readable name (e.g. "no_power", "item_ingredient_shortage") instead of
-- a bare number - this is the API's own purpose-built answer to "why
-- isn't this thing working", which fuel/held-stack alone haven't settled
-- for step 5's feeder inserter (confirmed to have active burning fuel,
-- yet never once observed holding an item across three real runs).
local ENTITY_STATUS_NAMES = {}
for status_name, status_value in pairs(defines.entity_status) do
    ENTITY_STATUS_NAMES[status_value] = status_name
end

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
                TrackerEvents.log_inventory_delta("container_" .. ent.unit_number, "container", TrackerEvents.container_contents(ent))
            elseif ent.type == "inserter" then
                -- INVESTIGATING (PR #15): inserter_hand owner_kind has
                -- never once appeared across three real checklist runs,
                -- despite step 5's feeder burner-inserter having a real
                -- pickup source and drop target. Ruled out so far:
                -- fueling (a real run showed 500000 J of actively burning
                -- fuel and 2 more coal in reserve), pickup/drop reach and
                -- direction (both confirmed correct - 1 tile for burner
                -- and plain inserters alike, and step 4's already-passing
                -- distant-chest test proves the direction convention),
                -- and how we read the hand itself - CONFIRMED against the
                -- real 2.0.76 docs that `held_stack`/`valid_for_read`,
                -- exactly as read below, is the documented, correct way
                -- to check what an inserter is currently gripping, with
                -- no caveat about timing/animation phases. So this isn't
                -- a coding mistake in what we check; something about this
                -- specific inserter's real runtime state is the open
                -- question. LuaEntity.status below is the API's own
                -- purpose-built "why isn't this working" signal, the
                -- right next thing to check given held_stack itself is
                -- confirmed fine. Remove once resolved.
                storage.inserter_hand_probe_seen = storage.inserter_hand_probe_seen or {}
                local probe_state = storage.inserter_hand_probe_seen[ent.unit_number]
                if not probe_state then
                    storage.inserter_hand_probe_seen[ent.unit_number] = "first_seen"
                    local ok_burner, burner = pcall(function() return ent.burner end)
                    local fuel_desc = "no_burner"
                    if ok_burner and burner then
                        local ok_remaining, remaining = pcall(function() return burner.remaining_burning_fuel end)
                        local ok_inv, contents = pcall(function() return burner.inventory and burner.inventory.get_contents() end)
                        fuel_desc = "remaining_burning_fuel=" .. (ok_remaining and tostring(remaining) or "ERROR")
                            .. " fuel_inventory=" .. (ok_inv and serpent.line(contents) or "ERROR")
                    elseif not ok_burner then
                        fuel_desc = "burner_read_ERROR(" .. tostring(burner) .. ")"
                    end
                    log("[replay-recorder-probe] inserter first seen: name=" .. ent.name
                        .. " unit_number=" .. ent.unit_number .. " " .. fuel_desc)
                end

                local ok_stack, held = pcall(function() return ent.held_stack end)
                if ok_stack and held and held.valid_for_read and probe_state ~= "held_seen" then
                    storage.inserter_hand_probe_seen[ent.unit_number] = "held_seen"
                    log("[replay-recorder-probe] inserter hand non-empty: name=" .. ent.name
                        .. " unit_number=" .. ent.unit_number .. " item=" .. held.name .. " count=" .. held.count)
                end

                -- LuaEntity.status is the API's own designed answer to
                -- "why isn't this thing working" (no_power, waiting on
                -- ingredients, disabled, ...) - logged on every CHANGE
                -- (not every tick) so a burner-inserter's real state
                -- transitions over its whole 10-second window show up as
                -- a short, readable timeline instead of one snapshot.
                storage.inserter_status_probe_seen = storage.inserter_status_probe_seen or {}
                local ok_status, status = pcall(function() return ent.status end)
                if ok_status and status ~= nil then
                    local status_name = ENTITY_STATUS_NAMES[status] or ("unknown(" .. tostring(status) .. ")")
                    if storage.inserter_status_probe_seen[ent.unit_number] ~= status_name then
                        storage.inserter_status_probe_seen[ent.unit_number] = status_name
                        log("[replay-recorder-probe] inserter status changed: name=" .. ent.name
                            .. " unit_number=" .. ent.unit_number .. " status=" .. status_name .. " tick=" .. game.tick)
                    end
                end

                TrackerEvents.log_inventory_delta("inserter_" .. ent.unit_number, "inserter_hand", TrackerEvents.held_stack_contents(ent))
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
                TrackerEvents.log_inventory_delta("vehicle_" .. ent.unit_number, "vehicle", vehicle_inventory_contents(ent))
            elseif ent.type == "construction-robot" or ent.type == "logistic-robot" then
                local inv = ent.get_inventory(defines.inventory.robot_cargo)
                if inv then
                    TrackerEvents.log_inventory_delta("robot_" .. ent.unit_number, "robot", TrackerEvents.flatten_contents(inv.get_contents()))
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
