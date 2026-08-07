-- script/exporter.lua
-- The only module that touches disk. Everything else in the mod calls
-- Exporter.log_event() to queue a line of output; this module batches
-- those lines in storage.replay_buffer (so it survives a save/reload) and
-- writes them out to script-output/replay.json as newline-delimited JSON
-- (JSONL) whenever Exporter.flush() is called - see control.lua's on_tick
-- handler for the flush schedule.
local Exporter = {}

-- Starts a fresh replay.json for a new game. Only call this for a true
-- on_init - see Init.on_init in script/init.lua for why.
function Exporter.init()
    storage.replay_buffer = storage.replay_buffer or {}
    helpers.write_file("replay.json", "", false)
end

function Exporter.log_event(tick, event_type, payload)
    table.insert(storage.replay_buffer, {
        tick = tick,
        type = event_type,
        data = payload
    })
end

function Exporter.flush()
    if #storage.replay_buffer == 0 then return end

    -- Batch write as JSON Lines (JSONL) for easier streaming in external
    -- apps. Built as an array and joined once with table.concat rather than
    -- repeated `..` concatenation - Lua strings are immutable, so appending
    -- in a loop copies the whole (growing) string on every iteration and
    -- gets quadratically slower during a big fight with thousands of events
    -- queued up between flushes.
    local lines = {}
    for i, entry in ipairs(storage.replay_buffer) do
        lines[i] = helpers.table_to_json(entry)
    end

    helpers.write_file("replay.json", table.concat(lines, "\n") .. "\n", true) -- true = append
    storage.replay_buffer = {}
end

return Exporter