-- script/diagnostics.lua
-- Optional per-tick performance timing, gated by the rrec-diagnostics-enabled
-- setting (see script/config.lua). Not a fix for anything - just a way to
-- get real numbers (elapsed tick time, scan compute time, JSON write time)
-- out of a save that's still seeing stalls, instead of guessing at which
-- part is actually slow. See control.lua's on_tick handler for how the
-- three brackets below line up against the work they're timing.
--
-- Confirmed against the real LuaProfiler docs: it does NOT expose a raw
-- time value to Lua at all (deliberately - "these objects don't allow
-- reading the raw time values from Lua"). A profiler is only usable
-- anywhere a LocalisedString is accepted - game.print(), log(), GUI text -
-- which does not include this mod's own JSON event log (storage.replay_buffer
-- -> Exporter -> replay.json is plain Lua tables through table_to_json, not
-- a LocalisedString consumer). An earlier version of this module tried
-- tostring(profiler) to embed a duration string into a replay.json event;
-- that produced the literal text "[LuaProfiler]" on a real run, not a
-- duration, because tostring() isn't one of the supported consumers either.
--
-- So this writes to Factorio's own log file (factorio-current.log) via
-- log(), which DOES accept a LocalisedString, instead of to replay.json.
-- tools/inspect_logs.py reads that file back for the same min/p50/mean/
-- p95/max breakdown tools/inspect_replay.py used to attempt from JSON.
local Config = require("script.config")

local Diagnostics = {}

-- Every line this module logs is prefixed with this exact marker so
-- tools/inspect_logs.py can find them amid everything else Factorio (and
-- every other mod) writes to the same log file.
local LOG_MARKER = "[replay-recorder-diagnostics]"

-- Call at the very start of on_tick. Returns nil (and every other function
-- below becomes a no-op) when diagnostics are off, so the disabled path is
-- just a handful of nil checks - no profiler objects ever get created.
function Diagnostics.start_tick()
    if not Config.diagnostics_enabled() then return nil end
    return {tick = game.create_profiler(), scan = game.create_profiler()}
end

-- Call once the tick's scan work (CombatZones/Tracker/Logistics/ItemChains/
-- FluidChains) is done, before any Exporter.flush().
function Diagnostics.end_scan(handles)
    if handles then handles.scan.stop() end
end

-- Call immediately before Exporter.flush(), only on ticks where a flush is
-- actually about to happen - returns the profiler to stop right after.
function Diagnostics.start_write(handles)
    if not handles then return nil end
    return game.create_profiler()
end

-- Call at the very end of on_tick, after Exporter.flush() (if this tick had
-- one) and its own start_write() profiler have both already been stopped.
-- `write_profiler` is nil on a tick with no flush, in which case write_time
-- is simply omitted from the line rather than reported as zero - there was
-- no write to time, not a write that took no time.
function Diagnostics.end_tick(handles, write_profiler)
    if not handles then return end
    handles.tick.stop()

    -- Factorio's "" LocalisedString form concatenates every element in
    -- order; a LuaProfiler dropped in as an element resolves to its
    -- formatted duration text, same as passing one straight to
    -- game.print(). Built as a table (not a single string) specifically
    -- so the profiler objects themselves are what's passed to log() -
    -- converting them to a string first is exactly the tostring() path
    -- that doesn't work.
    local message = {
        "", LOG_MARKER, " tick=", game.tick,
        " tick_time=", handles.tick,
        " scan_time=", handles.scan,
    }
    if write_profiler then
        table.insert(message, " write_time=")
        table.insert(message, write_profiler)
    end
    log(message)
end

return Diagnostics
