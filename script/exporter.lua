-- script/exporter.lua
local Exporter = {}

function Exporter.init()
    storage.replay_buffer = storage.replay_buffer or {}
    -- Clear previous run file
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

    -- Batch write as JSON Lines (JSONL) for easier streaming in external apps
    local output = ""
    for _, entry in ipairs(storage.replay_buffer) do
        output = output .. helpers.table_to_json(entry) .. "\n"
    end

    helpers.write_file("replay.json", output, true) -- true = append
    storage.replay_buffer = {}
end

return Exporter