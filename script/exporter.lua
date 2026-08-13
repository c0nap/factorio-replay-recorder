-- script/exporter.lua
-- The only module that touches disk. Everything else in the mod calls
-- Exporter.log_event() to queue a line of output; this module batches
-- those lines in storage.replay_buffer (so it survives a save/reload) and
-- writes them out to script-output/replay.json as newline-delimited JSON
-- (JSONL) whenever Exporter.flush() is called - see control.lua's on_tick
-- handler for the flush schedule.
local Config = require("script.config")

local Exporter = {}

-- Starts a fresh replay.json for a new game. Only call this for a true
-- on_init - see Init.on_init in script/init.lua for why.
function Exporter.init()
    storage.replay_buffer = storage.replay_buffer or {}
    helpers.write_file("replay.json", "", false)
end

-- TEMPORARY (PR #13): corpse_created/ground_item_created stayed at 0
-- events in real sessions despite upstream evidence they were actually
-- called (a matching probe, in corpse_created's case). One theory
-- offered is that something in this file - the buffer, or
-- helpers.table_to_json - is silently dropping them. This is directly
-- checkable: log_event already unconditionally appends to
-- storage.replay_buffer, and flush() already unconditionally writes
-- whatever's in it, so there's no code path that filters by event_type
-- anywhere in this file - but tracing it explicitly, rather than relying
-- on reading the code, is what actually settles it instead of asserting
-- it. Remove once corpse_created/ground_item_created are confirmed
-- working end-to-end.
local TRACED_EVENT_TYPES = {corpse_created = true, corpse_expired = true, ground_item_created = true}

function Exporter.log_event(tick, event_type, payload)
    table.insert(storage.replay_buffer, {
        tick = tick,
        type = event_type,
        data = payload
    })
    if TRACED_EVENT_TYPES[event_type] then
        log("[replay-recorder-probe] Exporter.log_event: buffered " .. event_type .. " at tick " .. tostring(tick)
            .. " (buffer now " .. #storage.replay_buffer .. " entries)")
    end
end

-- Real diagnostics data confirmed this is where a full-recording backfill
-- burst actually hurts: the earlier chunk-backfill-per-tick fix keeps the
-- SCAN side cheap (dump_static_chunk_data's engine calls, spread across
-- many ticks), but every one of those scans still queues a full
-- chunk_snapshot (tiles + statics + logistics) into storage.replay_buffer,
-- and flush() used to serialize+write the ENTIRE buffer in one call
-- regardless of how large it had grown - on a real run this meant one
-- single flush call taking 8.3+ SECONDS once ~800 accumulated
-- chunk_snapshots all landed in the same flush window. Capping how many
-- entries get written per call (oldest first, FIFO) and leaving the rest
-- queued - combined with control.lua flushing early once the backlog
-- crosses that same cap, instead of only on the fixed timer - turns one
-- multi-second freeze into many small, bounded ones instead.
function Exporter.flush()
    local buffer = storage.replay_buffer
    if #buffer == 0 then return end

    local limit = Config.max_buffered_events()
    local n = math.min(limit, #buffer)

    -- Batch write as JSON Lines (JSONL) for easier streaming in external
    -- apps. Built as an array and joined once with table.concat rather than
    -- repeated `..` concatenation - Lua strings are immutable, so appending
    -- in a loop copies the whole (growing) string on every iteration and
    -- gets quadratically slower during a big fight with thousands of events
    -- queued up between flushes.
    local lines = {}
    for i = 1, n do
        lines[i] = helpers.table_to_json(buffer[i])
        if TRACED_EVENT_TYPES[buffer[i].type] then
            log("[replay-recorder-probe] Exporter.flush: writing " .. buffer[i].type .. " from tick " .. tostring(buffer[i].tick)
                .. " - serialized length " .. #lines[i])
        end
    end

    helpers.write_file("replay.json", table.concat(lines, "\n") .. "\n", true) -- true = append

    if n == #buffer then
        storage.replay_buffer = {}
    else
        -- Overflow beyond the cap stays queued for the next flush instead
        -- of being written now (defeating the whole point) or dropped
        -- (losing data) - shifted down to the front so ordering in the
        -- file stays FIFO/chronological across multiple capped flushes.
        local remaining = {}
        for i = n + 1, #buffer do
            table.insert(remaining, buffer[i])
        end
        storage.replay_buffer = remaining
    end
end

return Exporter