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

function Tracker.on_entity_died(event)
    local entity = event.entity
    if not entity.valid then return end

    -- Fire/acid patches expire on their own (their "health" is really a
    -- countdown timer). That's the "acid entity loses potency and fades"
    -- event from the design doc, but it isn't new combat, so it gets a
    -- light-weight record and does NOT open or extend a combat zone.
    if entity.type == "fire" then
        Exporter.log_event(game.tick, "effect_expired", {name = entity.name, position = entity.position})
        return
    end

    local cause = event.cause
    local killer_data = nil
    if cause and cause.valid then
        killer_data = {name = cause.name, type = cause.type, force = cause.force.name}
    end

    local scoreable = is_scoreable_kind(entity.type) and entity.force.name ~= "enemy"
    local was_in_zone = CombatZones.is_zone_active(entity.surface, entity.position)

    -- Deaths always try to open/extend a combat zone (gated internally on
    -- player proximity), same as before. What's new is that we only bother
    -- writing the death itself to the file if it happened somewhere we
    -- were already recording, or it's scoreboard-worthy, or the user asked
    -- for everything via full recording mode. Otherwise this is exactly
    -- the "entities never near a biter" case the design doc says to skip.
    CombatZones.trigger_combat_at(entity.surface, entity.position)
    local now_in_zone = CombatZones.is_zone_active(entity.surface, entity.position)

    local kind, size
    if entity.force.name == "enemy" then
        kind, size = record_kill_stat(entity)
    end

    if scoreable then
        record_score_event(entity, killer_data)
    end

    if not (was_in_zone or now_in_zone or scoreable or Config.full_recording_mode()) then
        return
    end

    Exporter.log_event(game.tick, "death_event", {
        victim = {
            name = entity.name,
            type = entity.type,
            force = entity.force.name,
            position = entity.position,
            hostile_kind = kind,
            hostile_size = size,
        },
        killer = killer_data
    })
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

    local was_in_zone = CombatZones.is_zone_active(surface, position)
    CombatZones.trigger_combat_at(surface, position)
    local now_in_zone = CombatZones.is_zone_active(surface, position)

    if not (was_in_zone or now_in_zone or Config.full_recording_mode()) then return end

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
}

function Tracker.on_entity_damaged(event)
    local entity = event.entity
    if not entity or not entity.valid then return end
    if not DAMAGE_TRACKED_TYPES[entity.type] then return end

    local was_in_zone = CombatZones.is_zone_active(entity.surface, entity.position)
    CombatZones.trigger_combat_at(entity.surface, entity.position)
    local now_in_zone = CombatZones.is_zone_active(entity.surface, entity.position)

    if not (was_in_zone or now_in_zone or Config.full_recording_mode()) then return end

    Exporter.log_event(game.tick, "damage_event", {
        target = entity.name,
        target_type = entity.type,
        position = entity.position,
        damage = event.final_damage_amount,
        dealer = event.cause and event.cause.name or "unknown"
    })
end

-- Combined trunk + ammo (+ trash, for spiders/tanks) contents for a
-- vehicle. There's no on_*_inventory_changed event for vehicles the way
-- there is for players, so this is diffed once per tick while the vehicle
-- is inside an active zone (see Tracker.tick), never map-wide.
local function vehicle_inventory_contents(entity)
    local slots
    if entity.type == "car" then
        slots = {defines.inventory.car_trunk, defines.inventory.car_ammo}
    else
        slots = {defines.inventory.spider_trunk, defines.inventory.spider_ammo, defines.inventory.spider_trash}
    end

    local contents = {}
    for _, slot in ipairs(slots) do
        local inv = entity.get_inventory(slot)
        if inv then
            for name, count in pairs(inv.get_contents()) do
                contents[name] = (contents[name] or 0) + count
            end
        end
    end
    return contents
end

local BELT_TYPES = {["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true}

local function log_belt_contents(entities)
    local belt_data = {}
    for _, ent in ipairs(entities) do
        if BELT_TYPES[ent.type] then
            local lines = {}
            for i = 1, ent.get_max_transport_line_index() do
                local line = ent.get_transport_line(i)
                local contents = line.get_contents()
                if next(contents) then
                    table.insert(lines, {line = i, contents = contents})
                end
            end
            if #lines > 0 then
                table.insert(belt_data, {id = ent.unit_number, name = ent.name, position = ent.position, lines = lines})
            end
        end
    end
    if #belt_data > 0 then
        Exporter.log_event(game.tick, "belt_contents", belt_data)
    end
end

function Tracker.tick()
    local mobile_data = {}

    for _, zone in pairs(storage.active_zones) do
        local top_left = {x = zone.chunk_x * 32, y = zone.chunk_y * 32}
        local bottom_right = {x = top_left.x + 32, y = top_left.y + 32}

        local entities = zone.surface.find_entities_filtered{
            area = {top_left, bottom_right},
            type = {"unit", "character", "car", "spider-vehicle", "locomotive",
                    "combat-robot", "construction-robot", "logistic-robot"}
        }

        for _, ent in ipairs(entities) do
            if ent.valid then
                local record = {
                    id = ent.unit_number or (ent.player and ent.player.index),
                    name = ent.name,
                    type = ent.type,
                    force = ent.force.name,
                    position = ent.position,
                    orientation = ent.orientation,
                    -- Ties biters/spitters back to the attack/expansion
                    -- party they belong to, so a viewer can render the
                    -- group as a single parented object.
                    group_id = ent.unit_group and ent.unit_group.valid and ent.unit_group.group_number or nil,
                }
                table.insert(mobile_data, record)

                if ent.type == "car" or ent.type == "spider-vehicle" then
                    TrackerEvents.log_inventory_delta("vehicle_" .. ent.unit_number, "vehicle", vehicle_inventory_contents(ent))
                end
            end
        end

        local belt_entities = zone.surface.find_entities_filtered{area = {top_left, bottom_right}, type = {"transport-belt", "underground-belt", "splitter"}}
        log_belt_contents(belt_entities)
    end

    if #mobile_data > 0 then
        Exporter.log_event(game.tick, "mobile_positions", mobile_data)
    end
end

return Tracker
