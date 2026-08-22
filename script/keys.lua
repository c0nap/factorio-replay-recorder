-- script/keys.lua
-- Tiny shared helper for the underscore-joined composite string keys used
-- throughout this mod as storage table keys (chunk ids, network ids,
-- owner keys, ...). Every call site used to concatenate its own
-- "a_b_c"-shaped key by hand with `..`; this is the one place that
-- pattern lives now.
local Keys = {}

function Keys.join(...)
    return table.concat({...}, "_")
end

return Keys
