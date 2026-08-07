-- settings.lua
-- Defines the mod's settings, editable from Settings > Mod Settings > Map.
-- These are "runtime-global" settings: they apply to the whole save, and
-- (unlike "startup" settings) can be changed mid-game without restarting.

data:extend({
    {
        type = "bool-setting",
        name = "rrec-full-recording-mode",
        setting_type = "runtime-global",
        default_value = false,
        order = "a"
    },
    {
        type = "double-setting",
        name = "rrec-combat-radius",
        setting_type = "runtime-global",
        default_value = 48,
        minimum_value = 8,
        maximum_value = 256,
        order = "b"
    },
    {
        type = "double-setting",
        name = "rrec-zone-timeout-seconds",
        setting_type = "runtime-global",
        default_value = 10,
        minimum_value = 1,
        maximum_value = 300,
        order = "c"
    }
})
