-- data-updates.lua
-- Runs in the same DATA stage as data.lua (see that file's header for the
-- stage split), but after every mod's own data.lua has already run - the
-- right stage for editing prototypes that already exist (vanilla or
-- other mods'), rather than defining new ones.
--
-- CONFIRMED (PR #13/#14): on_trigger_created_entity only fires for a
-- create-entity trigger effect that has trigger_created_entity = true set
-- on it, and vanilla's flamethrower/spitter/worm stream prototypes leave
-- that flag unset by default to save the event overhead - setting it here
-- on every stream's create-fire target effect is what makes
-- script/tracker.lua's on_trigger_created_entity fire at all for a
-- flame/acid patch. Verified against real 2.0.76 data: effect_created is
-- now recorded for the flamethrower turret, spitter, and worm turret
-- checklist steps (effect_expired - the fade-out side - is a separate,
-- still-open gap; see the TODO on TrackerEvents.on_object_destroyed).
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
