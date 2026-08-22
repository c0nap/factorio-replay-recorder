-- script/battlefield_marker.lua
-- Optional visual aid, gated by rrec-battlefield-marker-enabled (off by
-- default): draws a border around the exterior perimeter of however many
-- adjacent chunks are currently "active" (storage.active_zones), so it's
-- obvious in-game where the recorded battlefield actually is instead of
-- having to remember coordinates. A no-op under full recording mode -
-- every chunk is "the zone" then, so a border around everything would be
-- meaningless (and storage.active_zones stays empty in that mode anyway,
-- see script/combat_zones.lua).
--
-- Recomputed on a fixed interval and drawn with a self-expiring
-- time_to_live, rather than event-driven off zone_created/zone_expired
-- with individually tracked+destroyed lines: LuaRenderObject's own
-- instance API (specifically how to .destroy() one) isn't something this
-- mod has confirmed docs for, so this sidesteps ever needing it - every
-- redraw is a fresh, disposable set of rendering.draw_line calls, with
-- time_to_live set comfortably longer than the recompute interval so
-- there's no visible gap between one border expiring and the next
-- appearing.
local Config = require("script.config")
local Keys = require("script.keys")

local BattlefieldMarker = {}

local CHUNK_SIZE = 32

-- One entry per chunk-adjacent direction: the neighbouring chunk offset
-- to check, and the two chunk-local corners (in tiles, relative to the
-- chunk's own top-left) bounding the edge on that side - drawn only when
-- that specific neighbour isn't itself part of the active set.
local EDGES = {
    {dx = 0, dy = -1, from = {0, 0}, to = {CHUNK_SIZE, 0}},          -- north
    {dx = 0, dy = 1, from = {0, CHUNK_SIZE}, to = {CHUNK_SIZE, CHUNK_SIZE}}, -- south
    {dx = -1, dy = 0, from = {0, 0}, to = {0, CHUNK_SIZE}},          -- west
    {dx = 1, dy = 0, from = {CHUNK_SIZE, 0}, to = {CHUNK_SIZE, CHUNK_SIZE}}, -- east
}

-- Groups storage.active_zones by surface (chunk coordinates alone aren't
-- unique across surfaces), keyed by "chunk_x_chunk_y" within each group
-- for quick neighbour lookups.
local function group_by_surface()
    local by_surface = {}
    for _, zone in pairs(storage.active_zones) do
        local group = by_surface[zone.surface.index]
        if not group then
            group = {surface = zone.surface, chunks = {}}
            by_surface[zone.surface.index] = group
        end
        group.chunks[Keys.join(zone.chunk_x, zone.chunk_y)] = true
    end
    return by_surface
end

local function draw_perimeter(group)
    for key in pairs(group.chunks) do
        local cx, cy = key:match("^(-?%d+)_(-?%d+)$")
        cx, cy = tonumber(cx), tonumber(cy)
        local base_x, base_y = cx * CHUNK_SIZE, cy * CHUNK_SIZE

        for _, edge in ipairs(EDGES) do
            local neighbour_key = Keys.join(cx + edge.dx, cy + edge.dy)
            if not group.chunks[neighbour_key] then
                rendering.draw_line{
                    color = Config.battlefield_marker_line_color(),
                    width = Config.battlefield_marker_line_width(),
                    from = {base_x + edge.from[1], base_y + edge.from[2]},
                    to = {base_x + edge.to[1], base_y + edge.to[2]},
                    surface = group.surface,
                    time_to_live = Config.battlefield_marker_time_to_live_ticks(),
                    draw_on_ground = true,
                }
            end
        end
    end
end

-- Call unconditionally from control.lua's on_tick - everything below is
-- either a settings-lookup short-circuit or gated on the recompute
-- interval, so the cost when disabled (the common case) is a couple of
-- cheap checks.
function BattlefieldMarker.tick()
    if not Config.battlefield_marker_enabled() then return end
    if Config.full_recording_mode() then return end
    if game.tick % Config.battlefield_marker_recompute_interval_ticks() ~= 0 then return end

    for _, group in pairs(group_by_surface()) do
        draw_perimeter(group)
    end
end

return BattlefieldMarker
