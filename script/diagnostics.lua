-- script/diagnostics.lua
-- Optional per-tick performance timing, gated by the rrec-diagnostics-enabled
-- setting (see script/config.lua). Not a fix for anything - just a way to
-- get real numbers (elapsed tick time, scan compute time, JSON write time)
-- out of a save that's still seeing stalls, instead of guessing at which
-- part is actually slow. See control.lua's on_tick handler for how the
-- three brackets below line up against the work they're timing.
--
-- LuaProfiler's only reliably-documented output is its human-readable
-- string form (via tostring()/print, e.g. "5.432 ms") - there's no
-- confirmed numeric accessor to read a raw duration off it directly, so
-- that string is what gets logged as-is. tools/inspect_replay.py parses it
-- back into a number for statistics on the Python side, rather than this
-- module guessing at an unconfirmed API to avoid that parsing.
local Exporter = require("script.exporter")
local Config = require("script.config")

local Diagnostics = {}

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
-- is simply omitted from the event rather than reported as zero - there
-- was no write to time, not a write that took no time.
function Diagnostics.end_tick(handles, write_profiler)
    if not handles then return end
    handles.tick.stop()
    Exporter.log_event(game.tick, "diagnostics_tick", {
        tick_time = tostring(handles.tick),
        scan_time = tostring(handles.scan),
        write_time = write_profiler and tostring(write_profiler) or nil,
    })
end

return Diagnostics
