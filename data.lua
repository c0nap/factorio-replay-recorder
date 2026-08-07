-- data.lua
-- Inject script triggers into all weapons/projectiles so we can track combat without polling.

local function inject_script_trigger(prototype)
    if not prototype.action then return end

    -- Factorio actions can be a single table or an array of tables
    local actions = prototype.action
    if not actions[1] then actions = {actions} end

    for _, action in pairs(actions) do
        if action.action_delivery then
            local deliveries = action.action_delivery
            if not deliveries[1] then deliveries = {deliveries} end
            
            for _, delivery in pairs(deliveries) do
                -- Append a script trigger effect to the delivery. The
                -- weapon's own prototype name is baked into the effect_id
                -- (rather than sent as separate data, which script triggers
                -- don't support) so control.lua can tell WHICH projectile
                -- or stream hit, not just that something did.
                delivery.target_effects = delivery.target_effects or {}
                table.insert(delivery.target_effects, {
                    type = "script",
                    effect_id = "replay_combat_trigger:" .. prototype.name
                })
            end
        end
    end
end

for _, p_type in pairs({"projectile", "artillery-projectile", "stream"}) do
    for _, item in pairs(data.raw[p_type] or {}) do
        inject_script_trigger(item)
    end
end