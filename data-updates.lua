-- data-updates.lua
-- Runs in the same DATA stage as data.lua (see that file's header for the
-- stage split), but after every mod's own data.lua has already run - the
-- right stage for editing prototypes that already exist (vanilla or
-- other mods'), rather than defining new ones.
--
-- UNVERIFIED (PR #13): on real 2.0.76 data, effect_created/effect_expired
-- (script/tracker.lua's on_trigger_created_entity/on_entity_died) never
-- fired for either the flamethrower turret test or a real spitter/acid
-- fight - not "fired with the wrong entity.type", never fired AT ALL (the
-- probe in on_trigger_created_entity logs every distinct name/type it
-- ever sees, and produced zero lines across that whole session). One
-- explanation offered for that: on_trigger_created_entity only fires for
-- a create-entity trigger effect that has trigger_created_entity = true
-- set on it, and vanilla's flamethrower/spitter stream prototypes leave
-- that flag unset by default to save the event overhead. This file tries
-- exactly that - setting the flag on every stream's create-fire target
-- effect - on the theory that it's missing, not that this mod's own
-- entity.type filter is wrong. NOT independently confirmed. The existing
-- on_trigger_created_entity probe is the direct test: if this flag name/
-- placement is right, probe lines should start appearing for fire/acid
-- entities on the next real session; if it's wrong, nothing changes
-- (Factorio's data stage generally warns on an unrecognized prototype
-- property rather than failing outright, but if the game refuses to
-- start with this mod active, that itself is confirmation this specific
-- attempt is wrong - delete this file to revert).
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
