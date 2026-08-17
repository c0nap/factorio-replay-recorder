-- data-updates.lua
-- Runs in the same DATA stage as data.lua (see that file's header for the
-- stage split), but after every mod's own data.lua has already run - the
-- right stage for editing prototypes that already exist (vanilla or
-- other mods'), rather than defining new ones.
--
-- CONFIRMED (PR #15): on_trigger_created_entity only fires for a
-- create-entity trigger effect that has trigger_created_entity = true set
-- on it, and vanilla's flamethrower stream leaves that flag unset by
-- default; setting it here on every matching prototype's create-fire
-- target effect is what makes script/tracker.lua's on_trigger_created_entity
-- fire at all.
--
-- FIXED (PR #15): this loop used to only scan data.raw["stream"], which is
-- why effect_created only ever showed "flamethrower-turret" as a source
-- across multiple real checklist runs, even ones with confirmed acid
-- damage landing. A real run's damage_event data showed the actual acid
-- entities by name - "acid-stream-spitter-small", "acid-stream-worm-medium",
-- "acid-splash-fire-spitter-small", "acid-splash-fire-worm-medium" - and a
-- data-stage probe confirmed "acid-stream-spitter"/"acid-stream-worm" (the
-- names guessed before any of this was named-confirmed) don't exist under
-- data.raw["stream"] at all. Despite "stream" being in their prototype
-- NAME, biters' acid attacks are registered as data.raw["projectile"]
-- prototypes, not data.raw["stream"] - only the flamethrower's continuous
-- attack is an actual "stream" type. data.lua's separate script-trigger
-- injection loop already covers "projectile"/"artillery-projectile"/
-- "stream" uniformly (which is why projectile_impact/damage_event already
-- had full acid coverage); this loop is widened to match.
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

for _, p_type in pairs({"projectile", "artillery-projectile", "stream"}) do
    for _, prototype in pairs(data.raw[p_type] or {}) do
        enable_trigger_created_entity(prototype)
    end
end

-- CONFIRMING (PR #15): dumps the real action structure for the now-known
-- real acid entity names, under the now-known real data.raw key
-- ("projectile", not "stream"), so the next real run confirms the widened
-- loop above actually reaches a "create-fire" effect for them (the
-- traversal logic itself is generic/shared with the stream case, but that
-- was never directly verified for a projectile-shaped delivery). Remove
-- once effect_created shows more than one source in a real run.
local ACID_PROJECTILE_PROBE_NAMES = {"acid-stream-spitter-small", "acid-stream-worm-medium"}
for _, name in ipairs(ACID_PROJECTILE_PROBE_NAMES) do
    local projectile = data.raw["projectile"] and data.raw["projectile"][name]
    if projectile then
        log("[replay-recorder-probe] projectile prototype " .. name .. " action=" .. serpent.block(projectile.action))
    else
        log("[replay-recorder-probe] projectile prototype " .. name .. " not found in data.raw['projectile']")
    end
end
