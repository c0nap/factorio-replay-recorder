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
                        if effect.type == "create-fire" or effect.type == "create-entity" then
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
