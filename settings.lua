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
    },
    {
        type = "double-setting",
        name = "rrec-distant-sample-interval-seconds",
        setting_type = "runtime-global",
        default_value = 5,
        minimum_value = 1,
        maximum_value = 300,
        order = "d"
    },
    {
        type = "double-setting",
        name = "rrec-network-activity-window-seconds",
        setting_type = "runtime-global",
        default_value = 30,
        minimum_value = 5,
        maximum_value = 600,
        order = "e"
    },
    {
        type = "int-setting",
        name = "rrec-chain-near-hops",
        setting_type = "runtime-global",
        default_value = 5,
        minimum_value = 1,
        maximum_value = 50,
        order = "f"
    },
    {
        type = "int-setting",
        name = "rrec-chain-max-hops",
        setting_type = "runtime-global",
        default_value = 30,
        minimum_value = 1,
        maximum_value = 200,
        order = "g"
    },
    {
        type = "int-setting",
        name = "rrec-inserter-search-radius",
        setting_type = "runtime-global",
        default_value = 3,
        minimum_value = 1,
        maximum_value = 10,
        order = "h"
    },
    {
        type = "int-setting",
        name = "rrec-chunk-backfill-per-tick",
        setting_type = "runtime-global",
        default_value = 20,
        minimum_value = 1,
        maximum_value = 500,
        order = "i"
    },
    {
        type = "double-setting",
        name = "rrec-flush-interval-seconds",
        setting_type = "runtime-global",
        default_value = 1,
        minimum_value = 0.1,
        maximum_value = 60,
        order = "j"
    },
    {
        type = "bool-setting",
        name = "rrec-diagnostics-enabled",
        setting_type = "runtime-global",
        default_value = false,
        order = "k"
    }
})
