-- script/combat_zones.lua
-- Decides WHERE and WHEN the mod is allowed to record. This is the "smart
-- cropping" system: instead of tracking the whole map, we only turn on
-- recording for a 32x32 chunk once a fight involving an actual player (on
-- foot or driving a vehicle) breaks out near it, and we let that chunk go
-- quiet again once nothing has happened there for a while. Everything else
-- in the mod only records entities that live inside a chunk this module
-- currently considers "active".
local Exporter = require("script.exporter")
local Config = require("script.config")
local Classify = require("script.classify")
local Logistics = require("script.logistics")

local CombatZones = {}

function CombatZones.init()
    storage.active_zones = storage.active_zones or {}
    storage.known_chunks = storage.known_chunks or {}

    -- If the map already has generated chunks (e.g. the setting was turned
    -- on partway through an existing save), bring full recording mode up to
    -- date immediately instead of waiting for new chunks to generate.
    if Config.full_recording_mode() then
        CombatZones.activate_all_existing_chunks()
    end
end

local function chunk_id(surface, chunk_x, chunk_y)
    return string.format("%s_%d_%d", surface.name, chunk_x, chunk_y)
end

-- Factorio's chunk coordinates are tile-position divided by 32; floor
-- (not truncation) is required so negative coordinates round toward
-- negative infinity the same way the engine does, e.g. position -1 belongs
-- to chunk -1, not chunk 0.
local function chunk_of(position)
    return math.floor(position.x / 32), math.floor(position.y / 32)
end

-- A chunk is always 32x32 tiles - exposed so other modules that need the
-- area of an active zone (Tracker.tick) don't have to duplicate this math.
function CombatZones.chunk_area(chunk_x, chunk_y)
    local top_left = {x = chunk_x * 32, y = chunk_y * 32}
    return {top_left, {x = top_left.x + 32, y = top_left.y + 32}}
end

local function entity_is_player_controlled(entity)
    if entity.type == "character" then
        return entity.player ~= nil
    end
    if entity.type == "car" or entity.type == "spider-vehicle" then
        if entity.get_driver() ~= nil or entity.get_passenger() ~= nil then
            return true
        end
        -- A spidertron with autopilot engaged is still "the player" even
        -- with nobody sitting in it - Space Age lets players walk away
        -- from a spider they've sent to fight on its own. Without this an
        -- unmanned spidertron's entire battle would go unrecorded.
        return entity.type == "spider-vehicle" and entity.autopilot_destination ~= nil
    end
    return false
end

-- Is an actual player (walking, driving, or piloting) within `radius` tiles
-- of `position`? An unoccupied tank sitting near a nest does not count -
-- we only care about zones a player is, or very recently was, present for.
function CombatZones.is_player_nearby(surface, position, radius)
    local candidates = surface.find_entities_filtered{
        position = position,
        radius = radius,
        type = {"character", "car", "spider-vehicle"}
    }
    for _, entity in ipairs(candidates) do
        if entity_is_player_controlled(entity) then return true end
    end
    return false
end

function CombatZones.is_zone_active(surface, position)
    local cx, cy = chunk_of(position)
    return storage.active_zones[chunk_id(surface, cx, cy)] ~= nil
end

-- Convenience for event handlers: tries to open/extend a zone at `position`
-- and reports whether it's worth logging this event at all, i.e. the
-- position was already being recorded, or this event is what just opened
-- the zone. Combines what would otherwise be three near-identical lines
-- (check before, trigger, check after) at every call site.
function CombatZones.notify_and_check(surface, position)
    local was_active = CombatZones.is_zone_active(surface, position)
    CombatZones.trigger_combat_at(surface, position)
    return was_active or CombatZones.is_zone_active(surface, position)
end

-- Groups spawners that were captured in the same snapshot into rough nest
-- "bases" by simple single-linkage proximity. This only clusters spawners
-- we've actually recorded (i.e. ones near a fight a player took part in) -
-- clustering the whole map's nest layout would mean scanning terrain no
-- player ever visited, which is exactly what the cropping system exists to
-- avoid.
local NEST_CLUSTER_RADIUS = 20

local function cluster_spawners(spawners)
    local cluster_of = {}
    for i = 1, #spawners do cluster_of[i] = i end

    local function find(i)
        while cluster_of[i] ~= i do
            cluster_of[i] = cluster_of[cluster_of[i]]
            i = cluster_of[i]
        end
        return i
    end

    for i = 1, #spawners do
        for j = i + 1, #spawners do
            local dx = spawners[i].position.x - spawners[j].position.x
            local dy = spawners[i].position.y - spawners[j].position.y
            if (dx * dx + dy * dy) <= (NEST_CLUSTER_RADIUS * NEST_CLUSTER_RADIUS) then
                cluster_of[find(i)] = find(j)
            end
        end
    end

    for i = 1, #spawners do
        spawners[i].cluster = find(i)
    end
end

local function dump_static_chunk_data(surface, chunk_x, chunk_y)
    local area = CombatZones.chunk_area(chunk_x, chunk_y)

    -- 1. Tiles (water, landfill, concrete, etc). This is the ground-truth
    -- pathing layer: whether biters have a clear route to the player is a
    -- function of tile walkability, not any high-level "danger" score.
    local tiles = surface.find_tiles_filtered{area = area}
    local tile_data = {}
    for _, tile in ipairs(tiles) do
        table.insert(tile_data, {name = tile.name, position = tile.position})
    end

    -- 2. Every non-mobile, non-decorative entity in the chunk: walls,
    -- turrets of every kind, nests, and any building at all (furnaces,
    -- pipes, chests, ...). We deliberately do NOT keep an explicit allow
    -- list of "interesting" building types here - a fixed list would miss
    -- whatever an unusual early-game base (or a mod) throws down. Instead
    -- we exclude the small set of types that are either handled elsewhere
    -- (mobile units, fire/acid effects) or too noisy to be useful.
    local statics = surface.find_entities_filtered{area = area}
    local static_data = {}
    local spawners = {}

    for _, entity in ipairs(statics) do
        local etype = entity.type
        if not Classify.MOBILE_TYPES[etype] and not Classify.IGNORED_TYPES[etype] then
            -- Scanning every entity type on the map (rather than a fixed
            -- allow-list) means we will eventually run into some exotic
            -- vanilla or modded entity whose fields don't behave the way
            -- we expect. pcall keeps one oddball entity from throwing an
            -- error that would abort the whole chunk snapshot.
            local ok, record = pcall(function()
                return {
                    name = entity.name,
                    type = etype,
                    force = entity.force and entity.force.name or nil,
                    position = entity.position,
                    is_defense = Classify.DEFENSE_TYPES[etype] or nil,
                }
            end)
            if ok then
                table.insert(static_data, record)
                if etype == "unit-spawner" then
                    table.insert(spawners, record)
                end
            end
        end
    end

    cluster_spawners(spawners)

    -- 3. Storage/provider/requester containers within logistic reach of
    -- this chunk (design doc: "chests within logistic reach of the
    -- battlefield"), not just ones physically standing in it. Always
    -- checks "player" (the common single-force case, including chunks
    -- with no player buildings of their own but that a nearby roboport
    -- still reaches) plus any other non-enemy force actually seen here.
    local force_names = {player = true}
    for _, record in ipairs(static_data) do
        if record.force and record.force ~= "enemy" and record.force ~= "neutral" then
            force_names[record.force] = true
        end
    end

    -- This is new, less battle-tested integration territory (a whole
    -- separate API - logistics networks - rather than just more LuaEntity
    -- fields), so it's pcall-wrapped at the top level: if anything about
    -- it goes wrong, the rest of the chunk snapshot (tiles/statics, the
    -- part every consumer actually depends on) still gets written.
    local ok, logistics_context = pcall(Logistics.context_for_area, surface, area, force_names)

    Exporter.log_event(game.tick, "chunk_snapshot", {
        chunk = {chunk_x, chunk_y},
        surface = surface.name,
        tiles = tile_data,
        statics = static_data,
        logistics = ok and logistics_context or nil,
    })
end

local function activate_zone(surface, chunk_x, chunk_y, permanent)
    local id = chunk_id(surface, chunk_x, chunk_y)

    -- Only dump the (potentially large) static snapshot the first time a
    -- chunk becomes relevant. Per the design goal, once we've captured a
    -- battlefield's terrain and buildings we don't need to re-record them
    -- every time the fight there flares back up.
    if not storage.known_chunks[id] then
        dump_static_chunk_data(surface, chunk_x, chunk_y)
        storage.known_chunks[id] = true
    end

    storage.active_zones[id] = {
        surface = surface,
        chunk_x = chunk_x,
        chunk_y = chunk_y,
        -- `permanent` zones (full recording mode) never expire on their
        -- own; everything else times out `zone_timeout_ticks` after the
        -- last thing that happened in it. Using a flag instead of an
        -- infinite expires_at keeps the stored value a normal finite
        -- number (the save format has no business holding onto inf/NaN)
        -- and makes the "never expires" case explicit rather than
        -- implicit in a magic number.
        permanent = permanent or nil,
        expires_at = permanent and nil or (game.tick + Config.zone_timeout_ticks())
    }
end

-- Called whenever something combat-relevant happens (a hit, a death, a
-- projectile impact). Only actually opens/extends a recording zone if a
-- player is nearby, unless full recording mode is on, in which case every
-- chunk is already permanently active and this is a no-op.
function CombatZones.trigger_combat_at(surface, position)
    if Config.full_recording_mode() then return end

    if not CombatZones.is_player_nearby(surface, position, Config.combat_radius()) then
        return
    end

    local cx, cy = chunk_of(position)
    activate_zone(surface, cx, cy, false)
end

-- Marks a single chunk as active forever (used by full recording mode,
-- where cropping is disabled entirely and every generated chunk records).
function CombatZones.activate_full_recording_chunk(surface, chunk_x, chunk_y)
    activate_zone(surface, chunk_x, chunk_y, true)
end

function CombatZones.activate_all_existing_chunks()
    for _, surface in pairs(game.surfaces) do
        for chunk in surface.get_chunks() do
            CombatZones.activate_full_recording_chunk(surface, chunk.x, chunk.y)
        end
    end
end

-- Called when full recording mode is switched back off. Zones it opened
-- are marked `permanent` and have no expires_at, so without this they
-- would keep recording forever even after the user turned the crazy-file-
-- size mode back off. Give each one a normal timeout instead so it winds
-- down like any other zone.
function CombatZones.expire_permanent_zones()
    for _, zone in pairs(storage.active_zones) do
        if zone.permanent then
            zone.permanent = nil
            zone.expires_at = game.tick + Config.zone_timeout_ticks()
        end
    end
end

function CombatZones.tick()
    if Config.full_recording_mode() then return end

    for id, zone in pairs(storage.active_zones) do
        if not zone.permanent and zone.expires_at and game.tick >= zone.expires_at then
            storage.active_zones[id] = nil
            Exporter.log_event(game.tick, "zone_expired", {chunk_id = id})
        end
    end
end

return CombatZones
