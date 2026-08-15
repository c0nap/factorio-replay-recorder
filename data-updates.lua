-- data-updates.lua
-- Runs in the same DATA stage as data.lua (see that file's header for the
-- stage split), but after every mod's own data.lua has already run - the
-- right stage for editing prototypes that already exist (vanilla or
-- other mods'), rather than defining new ones.
--
-- CONFIRMED for the flamethrower ONLY, not for acid - this is a
-- correction of an earlier over-broad claim here. on_trigger_created_entity
-- only fires for a create-entity trigger effect that has
-- trigger_created_entity = true set on it, and vanilla's flamethrower
-- stream leaves that flag unset by default; setting it here on every
-- stream's create-fire target effect is confirmed to be what makes
-- script/tracker.lua's on_trigger_created_entity fire for the
-- flamethrower's flame patch specifically.
--
-- INVESTIGATING (PR #15): effect_created has shown ONLY "flamethrower-
-- turret" as a source across every real checklist run so far, including
-- runs where a worm/spitter definitely landed acid damage on the player
-- (confirmed via damage_event) - the previous claim that this was also
-- confirmed for spitter/worm acid was wrong; re-checking the actual probe
-- evidence from when this was first added shows on_trigger_created_entity
-- never fired for acid even then, only for the flamethrower's "fire-flame".
-- The probe below dumps the acid streams' real action structure once, at
-- game load (no combat needed - just launch with this mod active and
-- check factorio-current.log), to find out whether their fire-creating
-- effect (if any) is even shaped like "create-fire", or something else
-- this loop never matches. Remove once resolved.
local ACID_STREAM_PROBE_NAMES = {"acid-stream-spitter", "acid-stream-worm", "flamethrower-fire-stream"}
for _, name in ipairs(ACID_STREAM_PROBE_NAMES) do
    local stream = data.raw["stream"] and data.raw["stream"][name]
    if stream then
        log("[replay-recorder-probe] stream prototype " .. name .. " action=" .. serpent.block(stream.action))
    else
        log("[replay-recorder-probe] stream prototype " .. name .. " not found in data.raw['stream']")
    end
end

local function enable_trigger_created_entity(prototype)
    if not prototype.action then return end

    local actions = prototype.action
    if not actions[1] then actions = {actions} end

    for _, action in pairs(actions) do
        if action.action_delivery then
            local deliveries = action.action_delivery
            if not deliveries[1] then deliveries = {deliveries} end

            for _, delivery in pairs(deliveries) do
                if delivery.target_effects then
                    local effects = delivery.target_effects
                    if not effects[1] then effects = {effects} end

                    for _, effect in pairs(effects) do
                        if effect.type == "create-fire" then
                            effect.trigger_created_entity = true
                        end
                    end
                end
            end
        end
    end
end

for _, stream in pairs(data.raw["stream"] or {}) do
    enable_trigger_created_entity(stream)
end
