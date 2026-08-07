-- script/config.lua
-- Single point of access for the user-configurable mod settings (see
-- settings.lua). Nothing else in the mod should read `settings.global`
-- directly, so a setting only ever has to be looked up by name in one place.

local Config = {}

function Config.full_recording_mode()
    return settings.global["rrec-full-recording-mode"].value
end

function Config.combat_radius()
    return settings.global["rrec-combat-radius"].value
end

function Config.zone_timeout_ticks()
    return settings.global["rrec-zone-timeout-seconds"].value * 60
end

return Config
