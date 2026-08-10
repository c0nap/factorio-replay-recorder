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
    -- date - via the backfill queue, not all at once - instead of waiting
    -- for new chunks to generate.
    if Config.full_recording_mode() then
        CombatZones.queue_full_recording_backfill()
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

-- Under full recording mode every generated chunk is conceptually
-- "active" without exception - short-circuiting here means callers never
-- need to consult storage.active_zones (which full recording mode no
-- longer populates at all - see activate_full_recording_chunk) to find
-- that out.
function CombatZones.is_zone_active(surface, position)
    if Config.full_recording_mode() then return true end
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

    -- Logistics.tick() re-samples this chunk's reachable networks on its
    -- own slow interval, without re-scanning this chunk's statics every
    -- time - it just needs to know which forces to check.
    storage.chunk_force_names[chunk_id(surface, chunk_x, chunk_y)] = force_names

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

-- Dumps a chunk's one-time static data if it hasn't been recorded yet.
-- Shared by both combat-triggered zone activation and full recording
-- mode - a chunk's statics/tiles/logistics roster only ever need
-- capturing once, regardless of which path first made it "known".
local function ensure_known(surface, chunk_x, chunk_y)
    local id = chunk_id(surface, chunk_x, chunk_y)
    if not storage.known_chunks[id] then
        dump_static_chunk_data(surface, chunk_x, chunk_y)
        storage.known_chunks[id] = true
    end
end

local function activate_zone(surface, chunk_x, chunk_y)
    local id = chunk_id(surface, chunk_x, chunk_y)
    local is_new = storage.active_zones[id] == nil
    ensure_known(surface, chunk_x, chunk_y)

    storage.active_zones[id] = {
        surface = surface,
        chunk_x = chunk_x,
        chunk_y = chunk_y,
        expires_at = game.tick + Config.zone_timeout_ticks()
    }

    -- Only on the chunk's first activation, not every subsequent hit that
    -- just extends its timeout - mirrors zone_expired's one-shot-per-chunk
    -- shape, so a viewer can bracket a zone's whole active lifetime from
    -- these two events without also seeing one zone_created per hit.
    if is_new then
        Exporter.log_event(game.tick, "zone_created", {chunk_id = id})
    end
end

-- Called whenever something combat-relevant happens (a hit, a death, a
-- projectile impact). Only actually opens/extends a recording zone if a
-- player is nearby, unless full recording mode is on, in which case every
-- chunk is already covered by Tracker.tick()'s whole-surface scan and
-- this is a no-op.
function CombatZones.trigger_combat_at(surface, position)
    if Config.full_recording_mode() then return end

    if not CombatZones.is_player_nearby(surface, position, Config.combat_radius()) then
        return
    end

    local cx, cy = chunk_of(position)
    activate_zone(surface, cx, cy)
end

-- Marks a chunk as known (dumping its one-time static data if that
-- hasn't happened yet) for full recording mode - deliberately does NOT
-- add an storage.active_zones entry the way combat-triggered activation
-- does. A save can easily have thousands of generated chunks; giving
-- each one its own permanent active_zones entry meant Tracker.tick()
-- (and, before this, Logistics/ItemChains/FluidChains.tick()) had to
-- issue several find_entities_filtered calls PER CHUNK, EVERY TICK -
-- fine for the handful of zones combat cropping keeps active, but with
-- a few hundred+ chunks that's enough engine-call overhead alone to
-- freeze the game, even with nothing physically happening in most of
-- them. Under full recording mode there's no cropping happening anyway
-- (is_zone_active() above already returns true unconditionally), so
-- there's nothing an active_zones entry would add other than that
-- per-chunk iteration cost - Tracker.tick()/FluidChains.tick() scan
-- each whole surface in one shot instead (see their full_recording_mode
-- branches), and Logistics.tick()/ItemChains.tick() simply have nothing
-- to iterate, which is correct: everything they'd otherwise report is
-- already covered by that whole-surface scan.
function CombatZones.activate_full_recording_chunk(surface, chunk_x, chunk_y)
    ensure_known(surface, chunk_x, chunk_y)
end

-- Queues every already-generated chunk for backfill instead of activating
-- them immediately: CombatZones.process_backfill_queue() (driven from
-- control.lua's on_tick) drains a bounded number per tick instead. A save
-- can easily have thousands of generated chunks by the time full recording
-- mode gets turned on; activating (and therefore dump_static_chunk_data-ing
-- - tiles, statics, logistics context) every single one of them
-- synchronously in the one tick this used to run in is exactly what froze
-- the game for multiple seconds. Queueing spreads that same total scan
-- cost - and, as a side effect, the resulting chunk_snapshot writes - out
-- over many ticks instead.
function CombatZones.queue_full_recording_backfill()
    storage.pending_backfill = storage.pending_backfill or {}

    -- game.surfaces is indexed by both numeric index and name, both
    -- pointing at the same LuaSurface - dedupe by surface.index so this
    -- doesn't walk every surface's chunks twice.
    local seen = {}
    for _, surface in pairs(game.surfaces) do
        if not seen[surface.index] then
            seen[surface.index] = true
            for chunk in surface.get_chunks() do
                table.insert(storage.pending_backfill, {surface = surface, chunk_x = chunk.x, chunk_y = chunk.y})
            end
        end
    end
end

-- Drains up to Config.chunk_backfill_per_tick() entries from the backfill
-- queue every tick - called unconditionally from control.lua's on_tick, a
-- no-op cost (one length check) once the queue is empty. ensure_known()'s
-- storage.known_chunks guard makes an already-activated or now-stale
-- (surface deleted) entry harmless to skip.
function CombatZones.process_backfill_queue()
    local queue = storage.pending_backfill
    if not queue or #queue == 0 then return end

    local n = Config.chunk_backfill_per_tick()
    for _ = 1, n do
        local entry = table.remove(queue)
        if not entry then break end
        if entry.surface.valid then
            CombatZones.activate_full_recording_chunk(entry.surface, entry.chunk_x, entry.chunk_y)
        end
    end
end

-- Called when full recording mode is switched back off. Full recording
-- activation no longer creates `permanent` active_zones entries at all
-- (see activate_full_recording_chunk), so this is normally a no-op now -
-- it's kept purely as a backward-compat cleanup pass for saves that had
-- full recording mode on under an older version of this mod, where such
-- entries could still exist and would otherwise keep "recording" forever
-- with no expires_at. Give any that turn up a normal timeout instead so
-- they wind down like any other zone.
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
