-- data-updates.lua
-- Runs in the same DATA stage as data.lua (see that file's header for the
-- stage split), but after every mod's own data.lua has already run - the
-- right stage for editing prototypes that already exist (vanilla or
-- other mods'), rather than defining new ones.
--
-- on_trigger_created_entity only fires for a create-entity-shaped trigger
-- effect that has trigger_created_entity = true set on it; vanilla
-- prototypes leave that flag unset by default, so setting it here on every
-- matching effect is what makes script/tracker.lua's on_trigger_created_entity
-- fire at all.
local function flag_target_effects(context_name, effects)
    if type(effects) == "table" and not effects[1] then effects = {effects} end

    if type(effects) ~= "table" then
        log("[replay-recorder] data-updates: " .. context_name .. ".target_effects is a " .. type(effects) .. ", not a table - skipped")
        return
    end

    for _, effect in pairs(effects) do
        if type(effect) ~= "table" then
            log("[replay-recorder] data-updates: " .. context_name .. " has a non-table target_effects entry (" .. type(effect) .. ") - skipped")
        -- "create-entity" is a distinct TriggerEffectItem type from
        -- "create-fire" - flagged as a harmless superset even though no
        -- currently-tracked weapon happens to use it.
        elseif effect.type == "create-fire" or effect.type == "create-entity" then
            effect.trigger_created_entity = true
        end
    end
end

-- Shared traversal: given something shaped like a TriggerItem
-- (action.action_delivery -> TriggerDelivery -> target_effects), walk
-- every level defensively. Every type(...) == "table" check below exists
-- because some vanilla prototypes (atomic bombs, capsules, lasers, ...)
-- have an action/delivery/effects shape this wrapping logic doesn't
-- expect, and pairs() over those can yield a non-table value that would
-- otherwise crash the data stage entirely.
local function flag_action(context_name, action)
    if type(action) ~= "table" then
        log("[replay-recorder] data-updates: " .. context_name .. " has a non-table action entry (" .. type(action) .. ") - skipped")
        return
    end
    if not action.action_delivery then return end

    local deliveries = action.action_delivery
    if type(deliveries) == "table" and not deliveries[1] then deliveries = {deliveries} end

    if type(deliveries) ~= "table" then
        log("[replay-recorder] data-updates: " .. context_name .. ".action_delivery is a " .. type(deliveries) .. ", not a table - skipped")
        return
    end

    for _, delivery in pairs(deliveries) do
        if type(delivery) ~= "table" then
            log("[replay-recorder] data-updates: " .. context_name .. " has a non-table delivery entry (" .. type(delivery) .. ") - skipped")
        elseif delivery.target_effects then
            flag_target_effects(context_name, delivery.target_effects)
        end
    end
end

-- FluidStreamPrototype's "action" and "initial_action" are two distinct
-- fields - "action" fires every time a particle lands, "initial_action"
-- fires only for the first one (e.g. a splash/puddle spawn). Both need
-- scanning to catch every weapon that creates an entity on impact.
local function flag_field(prototype_name, field_name, field_value)
    if not field_value then return end

    local actions = field_value
    if type(actions) == "table" and not actions[1] then actions = {actions} end
    if type(actions) ~= "table" then
        log("[replay-recorder] data-updates: " .. prototype_name .. "." .. field_name .. " is a " .. type(actions) .. ", not a table - skipped")
        return
    end

    for _, action in pairs(actions) do
        flag_action(prototype_name, action)
    end
end

local function enable_trigger_created_entity(prototype_name, prototype)
    flag_field(prototype_name, "action", prototype.action)
    flag_field(prototype_name, "initial_action", prototype.initial_action)
end

for _, p_type in pairs({"projectile", "artillery-projectile", "stream"}) do
    for prototype_name, prototype in pairs(data.raw[p_type] or {}) do
        enable_trigger_created_entity(prototype_name, prototype)
    end
end
