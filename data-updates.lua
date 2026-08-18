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
-- CORRECTED (PR #15): a previous round of this comment claimed acid
-- attacks live under data.raw["projectile"] instead of data.raw["stream"],
-- based on a probe reporting "acid-stream-spitter"/"acid-stream-worm" not
-- found under data.raw["stream"]. That was the wrong conclusion - those
-- exact names were never real (real Factorio prototype names carry a size
-- suffix - confirmed against the actual data.raw index the repo owner
-- provided: "acid-stream-spitter-small", "acid-stream-worm-medium", etc.
-- all exist right where they belong, under data.raw["stream"]). The loop
-- below already iterates every prototype in data.raw["stream"]
-- unconditionally (not filtered by name), so it was already calling
-- enable_trigger_created_entity on the real acid stream prototypes the
-- whole time - the table/name mixup was never the actual bug.
--
-- Also also scans "projectile"/"artillery-projectile" as a harmless
-- superset (matches data.lua's own script-trigger injection scope, and
-- would catch any other vanilla/modded prototype using this kind of
-- effect under those categories too) - kept, but it is not what fixes
-- the acid case either.
-- FIXED (post-PR #15, real crash): widening the scan below to
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
-- silently drops) whichever prototype had the unexpected shape, so a
-- future data-stage log tells us which one it was instead of us needing
-- to guess again.
local function enable_trigger_created_entity(prototype_name, prototype)
    if not prototype.action then return end

    local actions = prototype.action
    if type(actions) == "table" and not actions[1] then actions = {actions} end
    if type(actions) ~= "table" then
        log("[replay-recorder] data-updates: " .. prototype_name .. ".action is a " .. type(actions) .. ", not a table - skipped")
        return
    end

    for _, action in pairs(actions) do
        if type(action) ~= "table" then
            log("[replay-recorder] data-updates: " .. prototype_name .. " has a non-table action entry (" .. type(action) .. ") - skipped")
        elseif action.action_delivery then
            local deliveries = action.action_delivery
            if type(deliveries) == "table" and not deliveries[1] then deliveries = {deliveries} end

            if type(deliveries) ~= "table" then
                log("[replay-recorder] data-updates: " .. prototype_name .. ".action_delivery is a " .. type(deliveries) .. ", not a table - skipped")
            else
                for _, delivery in pairs(deliveries) do
                    if type(delivery) ~= "table" then
                        log("[replay-recorder] data-updates: " .. prototype_name .. " has a non-table delivery entry (" .. type(delivery) .. ") - skipped")
                    elseif delivery.target_effects then
                        local effects = delivery.target_effects
                        if type(effects) == "table" and not effects[1] then effects = {effects} end

                        if type(effects) ~= "table" then
                            log("[replay-recorder] data-updates: " .. prototype_name .. ".target_effects is a " .. type(effects) .. ", not a table - skipped")
                        else
                            for _, effect in pairs(effects) do
                                if type(effect) ~= "table" then
                                    log("[replay-recorder] data-updates: " .. prototype_name .. " has a non-table target_effects entry (" .. type(effect) .. ") - skipped")
                                -- "create-fire" is confirmed correct (see above).
                                -- "create-entity" is added as a schema-informed
                                -- but NOT yet proven extension: the real 2.0.76
                                -- TriggerEffectItem type list includes both
                                -- CreateFireTriggerEffectItem and
                                -- CreateEntityTriggerEffectItem as distinct,
                                -- equally-real types, and trigger_created_entity
                                -- conceptually reads as a flag any entity-creating
                                -- effect could plausibly support, not just the
                                -- fire-specific one. Since the table/type-string
                                -- checks are now both confirmed correct and the
                                -- acid case still doesn't fire, the remaining
                                -- possibility is that acid's fire-creating effect
                                -- (if it has one) uses this type instead. Narrow
                                -- back to just "create-fire" if a real run's probe
                                -- dump (below) shows acid actually uses neither.
                                elseif effect.type == "create-fire" or effect.type == "create-entity" then
                                    effect.trigger_created_entity = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

for _, p_type in pairs({"projectile", "artillery-projectile", "stream"}) do
    for prototype_name, prototype in pairs(data.raw[p_type] or {}) do
        enable_trigger_created_entity(prototype_name, prototype)
    end
end

-- CONFIRMING (PR #15): dumps the real action structure for the confirmed-
-- real acid stream prototypes, under the confirmed-real data.raw key
-- ("stream", per the actual data.raw index). This is the one remaining
-- piece nothing else can substitute for - it's prototype DATA, not
-- documented schema, so no API reference page can answer it. Only
-- requires relaunching Factorio with the mod active (data stage runs at
-- startup, before any save loads) - no checklist playthrough needed.
-- Remove once effect_created shows more than one source in a real run.
local ACID_STREAM_PROBE_NAMES = {"acid-stream-spitter-small", "acid-stream-worm-medium"}
for _, name in ipairs(ACID_STREAM_PROBE_NAMES) do
    local stream = data.raw["stream"] and data.raw["stream"][name]
    if stream then
        log("[replay-recorder-probe] stream prototype " .. name .. " action=" .. serpent.block(stream.action))
    else
        log("[replay-recorder-probe] stream prototype " .. name .. " not found in data.raw['stream']")
    end
end
