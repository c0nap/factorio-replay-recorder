-- script/classify.lua
-- Shared rules for sorting entities into buckets the rest of the mod cares
-- about. Kept in one place so "what counts as a building" or "what counts
-- as a hostile" is defined once instead of drifting between files.

local Classify = {}

-- Entities that move under their own power (or a driver's). These are polled
-- every tick by Tracker instead of being dumped once as part of the static
-- battlefield snapshot.
Classify.MOBILE_TYPES = {
    ["unit"] = true,
    ["character"] = true,
    ["car"] = true,
    ["spider-vehicle"] = true,
    ["locomotive"] = true,
    ["cargo-wagon"] = true,
    ["fluid-wagon"] = true,
    ["artillery-wagon"] = true,
    ["combat-robot"] = true,
    ["construction-robot"] = true,
    ["logistic-robot"] = true,
}

-- Transient or purely decorative entities that never belong in a replay:
-- they either produce their own dedicated events (fire/acid, handled by
-- Tracker.on_entity_died) or carry no information a combat viewer needs.
Classify.IGNORED_TYPES = {
    ["resource"] = true,
    ["fish"] = true,
    ["corpse"] = true,
    ["character-corpse"] = true,
    ["particle-source"] = true,
    ["smoke"] = true,
    ["smoke-with-trigger"] = true,
    ["explosion"] = true,
    ["speech-bubble"] = true,
    ["flying-text"] = true,
    ["highlight-box"] = true,
    ["cliff"] = true,
    ["rail-remnants"] = true,
    ["item-entity"] = true,
    ["fire"] = true, -- logged separately as short-lived "effect_expired" events
    ["stream"] = true, -- the in-flight acid/particle stream itself, not its impact
}

-- Best-effort size tag parsed from the prototype name. Factorio has no
-- built-in "size" field for biters/spitters/worms, but vanilla (and most
-- mods that add more of them) name prototypes like "medium-biter" or
-- "behemoth-worm-turret", so a substring match is a decent, mod-agnostic
-- approximation. Anything that doesn't match is tagged "unknown" rather
-- than guessed, so the stats never silently lie.
local SIZE_TAGS = {"behemoth", "big", "medium", "small"}

function Classify.size_of(name)
    for _, tag in ipairs(SIZE_TAGS) do
        if name:find(tag, 1, true) then return tag end
    end
    return "unknown"
end

-- Coarse hostile category, derived from the engine-assigned entity type
-- (not the name) so it works for modded enemies too.
function Classify.hostile_kind(entity_type, name)
    if entity_type == "unit-spawner" then return "spawner" end
    if entity_type == "turret" then return "worm" end -- vanilla worms are plain "turret"; player turrets are ammo/electric/fluid-turret
    if entity_type == "unit" then
        if name:find("spitter", 1, true) then return "spitter" end
        if name:find("biter", 1, true) then return "biter" end
        return "unit"
    end
    return nil
end

-- True for entity types that can soak turret/wall damage as part of a
-- defensive perimeter, used to decide whether a chunk's static dump should
-- include an entity for chokepoint analysis.
Classify.DEFENSE_TYPES = {
    ["wall"] = true,
    ["turret"] = true,
    ["ammo-turret"] = true,
    ["electric-turret"] = true,
    ["fluid-turret"] = true,
    ["gate"] = true,
}

return Classify
