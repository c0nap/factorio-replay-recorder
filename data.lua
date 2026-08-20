-- data.lua
-- Factorio mods run in two completely separate phases. This file runs
-- during the DATA stage, at game startup, before any save is loaded - it
-- can edit the prototypes that define what every projectile, entity, and
-- item IS, but has no access to the running game (no `game`, no players,
-- no storage). control.lua runs during the CONTROL stage, while a save is
-- actually being played, and is the mirror image: it can react to events
-- and read live game state, but can't touch prototypes anymore.
--
-- We use the data stage here to attach a "script" trigger effect to every
-- projectile and stream (acid, flamethrower fire, bullets, rockets, ...)
-- in the game, vanilla and modded alike. That effect does nothing by
-- itself, but it makes Factorio fire the on_script_trigger_effect event
-- (handled in script/tracker.lua) whenever one of these hits something -
-- which is how the mod tracks combat without polling every projectile in
-- the game on every tick.

-- Every level checks type(...) == "table" before indexing into it - some
-- vanilla prototypes (atomic bombs, capsules, lasers, ...) have an
-- action/delivery/effects shape this wrapping logic doesn't expect, and
-- pairs() over those can yield a non-table value that would otherwise
-- crash the data stage entirely.
local function inject_script_trigger(prototype)
    if not prototype.action then return end

    -- Factorio actions can be a single table or an array of tables
    local actions = prototype.action
    if type(actions) == "table" and not actions[1] then actions = {actions} end
    if type(actions) ~= "table" then return end

    for _, action in pairs(actions) do
        if type(action) == "table" and action.action_delivery then
            local deliveries = action.action_delivery
            if type(deliveries) == "table" and not deliveries[1] then deliveries = {deliveries} end

            if type(deliveries) == "table" then
                for _, delivery in pairs(deliveries) do
                    if type(delivery) == "table" then
                        -- Append a script trigger effect to the delivery. The
                        -- weapon's own prototype name is baked into the effect_id
                        -- (rather than sent as separate data, which script triggers
                        -- don't support) so control.lua can tell WHICH projectile
                        -- or stream hit, not just that something did.
                        if type(delivery.target_effects) ~= "table" then
                            delivery.target_effects = {}
                        end
                        table.insert(delivery.target_effects, {
                            type = "script",
                            effect_id = "replay_combat_trigger:" .. prototype.name
                        })
                    end
                end
            end
        end
    end
end

for _, p_type in pairs({"projectile", "artillery-projectile", "stream"}) do
    for _, item in pairs(data.raw[p_type] or {}) do
        inject_script_trigger(item)
    end
end