-- script/combat_zones.lua
local Exporter = require("script.exporter")

local CombatZones = {}
local ZONE_TIMEOUT = 600 -- 10 seconds of no action before a zone goes to sleep

function CombatZones.init()
    storage.active_zones = storage.active_zones or {}
    storage.known_chunks = storage.known_chunks or {}
end

local function dump_static_chunk_data(surface, chunk_x, chunk_y)
    local top_left = {x = chunk_x * 32, y = chunk_y * 32}
    local bottom_right = {x = top_left.x + 32, y = top_left.y + 32}
    local area = {top_left, bottom_right}

    -- 1. Dump Tiles (Water, Landfill, etc.)
    local tiles = surface.find_tiles_filtered{area = area}
    local tile_data = {}
    for _, tile in ipairs(tiles) do
        table.insert(tile_data, {name = tile.name, position = tile.position})
    end

    -- 2. Dump Static Entities (Walls, Turrets, Trees, Rocks, Chests)
    local statics = surface.find_entities_filtered{
        area = area, 
        type = {"wall", "turret", "ammo-turret", "tree", "simple-entity", "container"}
    }
    local static_data = {}
    for _, ent in ipairs(statics) do
        table.insert(static_data, {
            name = ent.name,
            type = ent.type,
            force = ent.force.name,
            position = ent.position
        })
    end

    Exporter.log_event(game.tick, "chunk_snapshot", {
        chunk = {chunk_x, chunk_y},
        surface = surface.name,
        tiles = tile_data,
        statics = static_data
    })
end

function CombatZones.trigger_combat_at(surface, position)
    local chunk_x = math.floor(position.x / 32)
    local chunk_y = math.floor(position.y / 32)
    local chunk_id = string.format("%s_%d_%d", surface.name, chunk_x, chunk_y)

    -- If this chunk has never been recorded, dump its static background
    if not storage.known_chunks[chunk_id] then
        dump_static_chunk_data(surface, chunk_x, chunk_y)
        storage.known_chunks[chunk_id] = true
    end

    -- Activate or extend the combat timer
    storage.active_zones[chunk_id] = {
        surface = surface,
        chunk_x = chunk_x,
        chunk_y = chunk_y,
        expires_at = game.tick + ZONE_TIMEOUT
    }
end

function CombatZones.tick()
    -- Expire stale zones
    for id, zone in pairs(storage.active_zones) do
        if game.tick >= zone.expires_at then
            storage.active_zones[id] = nil
            Exporter.log_event(game.tick, "zone_expired", {chunk_id = id})
        end
    end
end

return CombatZones