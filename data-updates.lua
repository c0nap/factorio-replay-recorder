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
-- CONFIRMED (PR #15) against the real FluidStreamPrototype docs: "action"
-- and "initial_action" are two DISTINCT fields - "action" fires every time
-- a particle lands, "initial_action" fires only for the first particle.
-- The earlier probe only ever checked .action (confirmed nil for both
-- acid streams) and never looked at .initial_action at all - which is
-- exactly the kind of once-only effect a splash/puddle spawn would use.
-- Every prototype-level field name is now scanned through the same
-- flag_field() helper.
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

-- RULED OUT (PR #15) against the real FluidStreamPrototype/AttackParameters/
-- AmmoType/Trigger docs together: an earlier round of this file also
-- scanned data.raw["unit"]/["turret"]/etc.'s attack_parameters.ammo_type.action,
-- on the theory that acid's on-hit effect might be defined on the
-- attacking unit rather than the stream. A real prototype dump proved
-- that's not it either - small-spitter's and medium-worm-turret's real
-- ammo_type.action is just
--   { type = "direct", action_delivery = { type = "stream", stream = "acid-stream-*" [, source_offset = ...] } }
-- with no source_effects/target_effects field at all. The actual fix
-- turned out to be much simpler and entirely on the stream prototype
-- itself (see CONFIRMED note above): "action" and "initial_action" are
-- two distinct FluidStreamPrototype fields, and only "action" was ever
-- being scanned. That's why this file no longer touches
-- data.raw["unit"]/["turret"] at all - removed as dead code once the real
-- fix was found, not left in as a hedge.
