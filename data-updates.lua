-- data-updates.lua
-- Runs in the same DATA stage as data.lua (see that file's header for the
-- stage split), but after every mod's own data.lua has already run - the
-- right stage for editing prototypes that already exist (vanilla or
-- other mods'), rather than defining new ones.
--
-- CONFIRMED (PR #15): on_trigger_created_entity only fires for a
-- create-entity trigger effect that has trigger_created_entity = true set
-- on it, and vanilla's flamethrower stream leaves that flag unset by
-- default; setting it here on every stream's create-fire target effect is
-- what makes script/tracker.lua's on_trigger_created_entity fire for the
-- flamethrower's flame patch.
--
-- CORRECTED (PR #15): a previous round of this comment claimed acid
-- attacks live under data.raw["projectile"] instead of data.raw["stream"],
-- and widened the loop below to match - based on a probe reporting
-- "acid-stream-spitter"/"acid-stream-worm" not found under data.raw
-- ["stream"]. That was the wrong conclusion: those exact names were never
-- real (real Factorio prototype names carry a size suffix - confirmed
-- against the actual data.raw index: "acid-stream-spitter-small",
-- "acid-stream-worm-medium", etc. all exist right where they belong,
-- under data.raw["stream"]). The loop below already iterates every
-- prototype in data.raw["stream"] unconditionally (not filtered by name),
-- so it was ALREADY calling enable_trigger_created_entity on the real
-- acid stream prototypes the whole time - widening to also scan
-- data.raw["projectile"] didn't fix anything, since that was never where
-- the problem was. The real question - now that the right prototypes are
-- confirmed to already be in scope - is why this function's traversal
-- doesn't find a "create-fire" effect for them the way it does for
-- flamethrower-fire-stream. The projectile/artillery-projectile scan is
-- left in below since it's a harmless superset (matches data.lua's own
-- script-trigger injection scope, and would catch any other vanilla/
-- modded prototype using a create-fire effect under those categories
-- too), but it is NOT the fix for this bug.
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

-- CONFIRMING (PR #15): dumps the real action structure for the confirmed-
-- real acid stream prototypes, under the confirmed-real data.raw key
-- ("stream", per the actual data.raw index - not "projectile", which was
-- this file's own wrong guess last round). This tells us directly whether
-- their fire-creating effect is even shaped like "create-fire" the way
-- flamethrower-fire-stream's is, which enable_trigger_created_entity's
-- traversal only actually matches on. Remove once effect_created shows
-- more than one source in a real run.
local ACID_STREAM_PROBE_NAMES = {"acid-stream-spitter-small", "acid-stream-worm-medium"}
for _, name in ipairs(ACID_STREAM_PROBE_NAMES) do
    local stream = data.raw["stream"] and data.raw["stream"][name]
    if stream then
        log("[replay-recorder-probe] stream prototype " .. name .. " action=" .. serpent.block(stream.action))
    else
        log("[replay-recorder-probe] stream prototype " .. name .. " not found in data.raw['stream']")
    end
end

-- INVESTIGATING (PR #15, inserter_hand): step 5's feeder burner-inserter
-- has confirmed-active fuel and a pickup/drop geometry already validated
-- for a PLAIN "inserter" (step 4's working distant-chest test relies on
-- entity.drop_target resolving correctly for that exact 1-tile-east
-- placement) - but "burner-inserter" is a different prototype, and its
-- own declared reach was never independently checked. If it's shorter
-- than 1 tile, our exact adjacent placement would be silently out of
-- range. Dumps both prototypes' pickup_position/insert_position for
-- direct comparison - field names are a best guess (pcall-guarded so a
-- wrong one just reports nil/ERROR instead of crashing the whole probe,
-- same lesson as the acid-stream name guess above). Remove once resolved.
local function dump_inserter_reach(name)
    local prototype = data.raw["inserter"] and data.raw["inserter"][name]
    if not prototype then
        log("[replay-recorder-probe] inserter prototype " .. name .. " not found in data.raw['inserter']")
        return
    end
    local ok_pickup, pickup = pcall(function() return prototype.pickup_position end)
    local ok_insert, insert = pcall(function() return prototype.insert_position end)
    log("[replay-recorder-probe] inserter prototype " .. name
        .. " pickup_position=" .. (ok_pickup and serpent.line(pickup) or ("ERROR(" .. tostring(pickup) .. ")"))
        .. " insert_position=" .. (ok_insert and serpent.line(insert) or ("ERROR(" .. tostring(insert) .. ")")))
end
dump_inserter_reach("inserter")
dump_inserter_reach("burner-inserter")
