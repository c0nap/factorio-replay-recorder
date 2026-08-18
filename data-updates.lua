-- data-updates.lua
-- Runs in the same DATA stage as data.lua (see that file's header for the
-- stage split), but after every mod's own data.lua has already run - the
-- right stage for editing prototypes that already exist (vanilla or
-- other mods'), rather than defining new ones.
--
-- CONFIRMED (PR #15) against the real 2.0.76 API docs: on_trigger_created_entity
-- only fires for a create-entity-shaped trigger effect that has
-- trigger_created_entity = true set on it, and vanilla's flamethrower
-- stream leaves that flag unset by default; setting it here on every
-- matching prototype's effect is what makes script/tracker.lua's
-- on_trigger_created_entity fire at all. "create-fire" is confirmed to
-- still be a real 2.0.76 TriggerEffectItem type (CreateFireTriggerEffectItem
-- appears in the type's own children list), so that string was never
-- wrong - independently double-confirmed by a real data-stage probe dump
-- of flamethrower-fire-stream's actual action table, which contains a
-- literal `type = "create-fire"` entry that this loop successfully flags.
--
-- CONFIRMED (PR #15) against the real AttackParameters/AmmoType/Trigger/
-- TriggerDelivery API docs, resolving the acid case: a data-stage probe
-- proved data.raw["stream"]["acid-stream-spitter-small" /
-- "acid-stream-worm-medium"].action is nil - unlike flamethrower-fire-
-- stream, which sets a real action directly on its own StreamPrototype
-- (a field the docs confirm exists independently of AttackParameters).
-- Acid's actual on-hit action lives one level up instead, on the
-- ATTACKING UNIT's own prototype:
--   unit.attack_parameters.ammo_type.action        -- Trigger (TriggerItem+)
--     .action_delivery                             -- TriggerDelivery (e.g. type="stream")
--       .target_effects                            -- TriggerEffect (TriggerEffectItem+)
-- the exact same target_effects shape the entity-level scan below already
-- flags, just reached through a different prototype path. flag_target_effects()
-- is shared by both paths so "create-fire"/"create-entity" get the same
-- trigger_created_entity = true treatment either way.
local function flag_target_effects(context_name, effects)
    if type(effects) == "table" and not effects[1] then effects = {effects} end

    if type(effects) ~= "table" then
        log("[replay-recorder] data-updates: " .. context_name .. ".target_effects is a " .. type(effects) .. ", not a table - skipped")
        return
    end

    for _, effect in pairs(effects) do
        if type(effect) ~= "table" then
            log("[replay-recorder] data-updates: " .. context_name .. " has a non-table target_effects entry (" .. type(effect) .. ") - skipped")
        -- "create-fire" is confirmed correct (see above). "create-entity"
        -- is kept as a harmless superset (a real, distinct 2.0.76
        -- TriggerEffectItem type) - not itself proven necessary for any
        -- currently-tracked weapon, but costs nothing to also flag.
        elseif effect.type == "create-fire" or effect.type == "create-entity" then
            effect.trigger_created_entity = true
        end
    end
end

-- Shared traversal: given something shaped like a TriggerItem
-- (action.action_delivery -> TriggerDelivery -> target_effects), walk
-- every level defensively - see the FIXED note below for why every level
-- needs a type(...) == "table" check rather than assuming array shape.
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

-- FIXED (post-PR #15, real crash): widening the entity-level scan below to
-- "projectile"/"artillery-projectile" (on top of "stream") meant this
-- traversal started running against ~30 vanilla prototypes it had never
-- actually been exercised on before (atomic bombs, capsules, lasers,
-- rockets, ...) - previously the only real-world input was the
-- flamethrower's stream, which happens to have a shape this code's
-- wrapping logic handles fine. One of those other prototypes doesn't:
-- Factorio failed to load with "attempt to index local 'effect' (a
-- boolean value)" at the effect.type check, meaning pairs() over some
-- delivery's target_effects yielded a plain `true`/`false` for some key,
-- not a TriggerEffectItem table - PROVING the shape assumption held for
-- flamethrower does not hold universally. Every level now checks
-- type(...) == "table" before indexing into it, and logs (rather than
-- silently drops) whichever prototype had the unexpected shape.
local function enable_trigger_created_entity(prototype_name, prototype)
    if not prototype.action then return end

    local actions = prototype.action
    if type(actions) == "table" and not actions[1] then actions = {actions} end
    if type(actions) ~= "table" then
        log("[replay-recorder] data-updates: " .. prototype_name .. ".action is a " .. type(actions) .. ", not a table - skipped")
        return
    end

    for _, action in pairs(actions) do
        flag_action(prototype_name, action)
    end
end

for _, p_type in pairs({"projectile", "artillery-projectile", "stream"}) do
    for prototype_name, prototype in pairs(data.raw[p_type] or {}) do
        enable_trigger_created_entity(prototype_name, prototype)
    end
end

-- Unit-level scan (acid spitters/worms, and anything else whose real
-- on-hit action lives on attack_parameters.ammo_type.action rather than
-- on the stream/projectile prototype itself - see the CONFIRMED note
-- above for the doc-backed path).
local function enable_trigger_created_entity_for_unit(prototype_name, prototype)
    local attack_parameters = prototype.attack_parameters
    if type(attack_parameters) ~= "table" then return end

    local ammo_types = attack_parameters.ammo_type
    if not ammo_types then return end
    if type(ammo_types) == "table" and not ammo_types[1] then ammo_types = {ammo_types} end

    if type(ammo_types) ~= "table" then
        log("[replay-recorder] data-updates: " .. prototype_name .. ".attack_parameters.ammo_type is a " .. type(ammo_types) .. ", not a table - skipped")
        return
    end

    for _, ammo_type in pairs(ammo_types) do
        if type(ammo_type) ~= "table" then
            log("[replay-recorder] data-updates: " .. prototype_name .. " has a non-table ammo_type entry (" .. type(ammo_type) .. ") - skipped")
        elseif ammo_type.action then
            local actions = ammo_type.action
            if type(actions) == "table" and not actions[1] then actions = {actions} end

            if type(actions) ~= "table" then
                log("[replay-recorder] data-updates: " .. prototype_name .. ".attack_parameters.ammo_type.action is a " .. type(actions) .. ", not a table - skipped")
            else
                for _, action in pairs(actions) do
                    flag_action(prototype_name, action)
                end
            end
        end
    end
end

for prototype_name, prototype in pairs(data.raw["unit"] or {}) do
    enable_trigger_created_entity_for_unit(prototype_name, prototype)
end

-- CONFIRMING (PR #15): a real checklist run after the unit-level scan
-- above showed damage_event now crediting 'acid-splash-fire-spitter-small'
-- / 'acid-splash-fire-worm-medium' as real, distinct damage sources - so
-- those entities ARE being created - but on_trigger_created_entity's own
-- probe log still only ever fires for flamethrower's fire-flame, never
-- for either acid entity. Two real unknowns remain, and both are
-- prototype DATA, not documented schema, so neither can be settled by a
-- doc page - only a relaunch-only dump can:
--   1. Which data.raw category actually holds "medium-worm-turret"? Worms
--      are stationary, unlike mobile biters/spitters ("unit"), so they
--      may live under "turret" or one of its ammo/electric/fluid
--      subtypes instead - if so, the unit-only scan above never even
--      looked at them. Widened below as a harmless superset in the
--      meantime (costs nothing if a category is absent or wrong, same
--      reasoning already used for projectile/artillery-projectile).
--   2. What does small-spitter's real attack_parameters.ammo_type.action
--      structure actually look like? If "acid-splash-fire-spitter-small"
--      is created via a "create-sticker" effect rather than "create-fire"/
--      "create-entity", the current type-string filter in
--      flag_target_effects would walk right past it even with the right
--      prototype in view - or the effect may be nested somewhere this
--      code's action/action_delivery/target_effects path doesn't reach at
--      all. Remove this whole probe once effect_created shows an acid
--      source in a real run.
for _, p_type in pairs({"turret", "ammo-turret", "electric-turret", "fluid-turret"}) do
    for prototype_name, prototype in pairs(data.raw[p_type] or {}) do
        enable_trigger_created_entity_for_unit(prototype_name, prototype)
    end
end

local ATTACK_PARAMETERS_PROBE_NAMES = {"small-spitter", "medium-worm-turret"}
for _, name in ipairs(ATTACK_PARAMETERS_PROBE_NAMES) do
    local found_category, found_prototype = nil, nil
    for category_name, category in pairs(data.raw) do
        if type(category) == "table" and category[name] then
            found_category, found_prototype = category_name, category[name]
            break
        end
    end

    if found_prototype then
        log("[replay-recorder-probe] prototype " .. name .. " found under data.raw['" .. found_category
            .. "'], attack_parameters=" .. serpent.block(found_prototype.attack_parameters))
    else
        log("[replay-recorder-probe] prototype " .. name .. " not found in any data.raw category")
    end
end
