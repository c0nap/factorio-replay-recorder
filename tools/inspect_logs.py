#!/usr/bin/env python3
"""Summarizes this mod's per-tick performance timings from Factorio's own
log file (factorio-current.log), broken down into min/p50/mean/p95/max per
field - the same report tools/inspect_replay.py used to attempt from
replay.json, before it turned out LuaProfiler can't hand a raw duration
value back to Lua at all (confirmed against the real API docs: profiler
objects are only usable anywhere a LocalisedString is accepted -
game.print(), log(), GUI text - which does not include this mod's own JSON
event log). script/diagnostics.lua now writes a marked line to Factorio's
log file via log() instead, and this script reads that back.

Usage:
    python3 tools/inspect_logs.py
    python3 tools/inspect_logs.py --path /custom/path/factorio-current.log

With no arguments, it looks for factorio-current.log in the default
Factorio user data directory for your OS. Only present when the
rrec-diagnostics-enabled setting was on for the session you're inspecting -
see docs/testing-checklist.md's setup step. factorio-current.log only ever
holds the *current* session; pass --path pointing at
factorio-previous.log for the one before that.

Standard library only, no dependencies to install.
"""

import argparse
import os
import re
import sys

# The exact marker script/diagnostics.lua prefixes every line it logs
# with, so this can find them amid everything else Factorio (and every
# other mod) writes to the same log file.
LOG_MARKER = "[replay-recorder-diagnostics]"

# A LuaProfiler embedded in a LocalisedString resolves to text of the form
# "Duration: 0.085300ms" - confirmed against a real log sample, not
# guessed: the literal "Duration: " prefix, and no space between the
# number and its unit. Restricting the unit to a known token list (rather
# than a generic "rest of the word") avoids swallowing the next field's
# key into this one's capture.
UNIT = r"(?:ns|us|µs|μs|ms|s)"
DURATION = rf"Duration:\s*[\d.]+\s*{UNIT}"
# buffer_size/backfill_remaining are plain integers, not LuaProfiler
# durations - added after a round where "is the lag fix even doing
# anything" couldn't be answered from timings alone, since a save can
# silently keep an OLDER stored setting value across a mod update.
# Optional (the `?` groups) so a log from before they existed still
# parses instead of being counted as malformed.
FIELD_RE = re.compile(
    rf"tick=(?P<tick>\d+)"
    rf"\s+tick_time=(?P<tick_time>{DURATION})"
    rf"\s+scan_time=(?P<scan_time>{DURATION})"
    rf"(?:\s+write_time=(?P<write_time>{DURATION}))?"
    rf"(?:\s+buffer_size=(?P<buffer_size>\d+))?"
    rf"(?:\s+backfill_remaining=(?P<backfill_remaining>\d+))?"
)
DURATION_RE = re.compile(rf"^Duration:\s*([\d.]+)\s*({UNIT})$")
DURATION_UNIT_TO_MS = {
    "ns": 1e-6,
    "us": 1e-3,
    "µs": 1e-3,
    "μs": 1e-3,
    "ms": 1.0,
    "s": 1000.0,
    None: 1.0,
}


def default_log_path():
    """Best-effort guess at where Factorio's factorio-current.log lives,
    based on the documented per-OS user data directory - same convention
    tools/inspect_replay.py uses for replay.json, minus the script-output
    subfolder. If this guess is wrong for your setup, pass --path
    explicitly."""
    if sys.platform.startswith("win"):
        appdata = os.environ.get("APPDATA")
        if appdata:
            return os.path.join(appdata, "Factorio", "factorio-current.log")
    elif sys.platform == "darwin":
        return os.path.expanduser(
            "~/Library/Application Support/factorio/factorio-current.log"
        )
    return os.path.expanduser("~/.factorio/factorio-current.log")


def _parse_duration_ms(text):
    """Parses a LuaProfiler-style duration string ("5.432 ms") into a float
    number of milliseconds, or None if it doesn't match the expected shape."""
    match = DURATION_RE.match(text.strip())
    if not match:
        return None
    value = float(match.group(1))
    return value * DURATION_UNIT_TO_MS[match.group(2)]


def load_samples(path):
    """Reads factorio-current.log, returning (samples, malformed_count).
    A sample is a dict with tick (int), tick_time/scan_time/write_time
    (floats, milliseconds; write_time only on ticks that flushed), and
    buffer_size/backfill_remaining (ints, None on a log from before these
    existed). A line containing the marker that doesn't match the expected
    field shape is counted as malformed rather than silently skipped -
    Factorio's own log preamble format isn't something this script
    controls, so a real format change elsewhere is exactly the kind of
    thing worth surfacing instead of hiding."""
    samples = []
    malformed = 0

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if LOG_MARKER not in line:
                continue

            match = FIELD_RE.search(line)
            if not match:
                malformed += 1
                continue

            tick_time = _parse_duration_ms(match.group("tick_time"))
            scan_time = _parse_duration_ms(match.group("scan_time"))
            write_group = match.group("write_time")
            write_time = _parse_duration_ms(write_group) if write_group else None

            if tick_time is None or scan_time is None:
                malformed += 1
                continue

            buffer_size_group = match.group("buffer_size")
            backfill_remaining_group = match.group("backfill_remaining")

            samples.append({
                "tick": int(match.group("tick")),
                "tick_time": tick_time,
                "scan_time": scan_time,
                "write_time": write_time,
                "buffer_size": int(buffer_size_group) if buffer_size_group else None,
                "backfill_remaining": int(backfill_remaining_group) if backfill_remaining_group else None,
            })

    return samples, malformed


def _stats(values_ms):
    if not values_ms:
        return None
    ordered = sorted(values_ms)
    n = len(ordered)

    def percentile(p):
        return ordered[min(n - 1, int(p * n))]

    return {
        "count": n,
        "min": ordered[0],
        "max": ordered[-1],
        "mean": sum(ordered) / n,
        "p50": percentile(0.50),
        "p95": percentile(0.95),
    }


def top_slowest(samples, field, n):
    """Returns the n samples with the highest value for `field` (skipping
    samples where it's None, e.g. write_time on a non-flush tick), sorted
    slowest-first. A single min/p50/mean/p95/max line can't tell you
    whether the max was one freak tick or the tail of a longer stall -
    this is what actually answers that."""
    with_value = [s for s in samples if s[field] is not None]
    return sorted(with_value, key=lambda s: s[field], reverse=True)[:n]


def find_slow_streaks(samples, field, threshold_ms):
    """Groups consecutive-tick samples whose `field` value is at or above
    threshold_ms into runs ("streaks") - a single p95/max stat can't tell
    a one-tick freak spike apart from many back-to-back ticks each a
    little slow, which is what actually reads as a stutter to a player
    (e.g. "each tick taking maybe half a second for the span of multiple
    seconds"). A gap in tick numbers (a sample that didn't get logged)
    ends a streak rather than bridging it, since that's not something a
    player would perceive as one continuous stall.

    Returns a list of dicts: start_tick, end_tick, num_ticks, peak_ms,
    total_ms - sorted by total_ms descending (the streaks that add up to
    the most real stall time first, not just the single worst tick)."""
    streaks = []
    current = []

    def flush_current():
        if len(current) >= 2:
            values = [v for _, v in current]
            streaks.append({
                "start_tick": current[0][0],
                "end_tick": current[-1][0],
                "num_ticks": len(current),
                "peak_ms": max(values),
                "total_ms": sum(values),
            })

    for s in samples:
        value = s[field]
        if value is not None and value >= threshold_ms:
            if current and s["tick"] != current[-1][0] + 1:
                flush_current()
                current = []
            current.append((s["tick"], value))
        else:
            flush_current()
            current = []
    flush_current()

    return sorted(streaks, key=lambda st: st["total_ms"], reverse=True)


def _context_suffix(sample):
    """" (buffer_size=N, backfill_remaining=N)" for a slowest-tick line, or
    "" on a log from before those fields existed - lets a slow tick be
    read alongside what the buffer/backfill queue actually looked like at
    that moment, e.g. confirming whether Config.max_buffered_events()'s
    ACTUAL in-effect value (which an existing save can keep pinned to an
    older default across a mod update) matches what's expected."""
    parts = []
    if sample.get("buffer_size") is not None:
        parts.append(f"buffer_size={sample['buffer_size']}")
    if sample.get("backfill_remaining") is not None:
        parts.append(f"backfill_remaining={sample['backfill_remaining']}")
    return f" ({', '.join(parts)})" if parts else ""


def print_report(samples, malformed, top_n, streak_threshold_ms):
    print("=" * 70)
    print("Factorio Replay Recorder - performance diagnostics summary")
    print("=" * 70)

    if not samples:
        if malformed:
            # The marker was found, just not in the shape FIELD_RE expects -
            # a real format mismatch worth surfacing precisely, not the
            # generic "nothing here" message below.
            print(f"Found {malformed} line(s) with the diagnostics marker, but none")
            print("matched the expected field format. Factorio's LuaProfiler text")
            print("may have changed shape - paste a raw sample line if this shows up.")
        else:
            print("No diagnostics lines found. Either the recording you're")
            print("inspecting didn't have rrec-diagnostics-enabled turned on,")
            print("or --path isn't pointing at the right log file.")
        return

    ticks = [s["tick"] for s in samples]
    print(f"Samples: {len(samples)}")
    print(f"Tick range: {min(ticks)} - {max(ticks)}")
    if malformed:
        print(f"Malformed diagnostics line(s) skipped: {malformed}")

    labels = {
        "tick_time": "tick (whole on_tick handler)",
        "scan_time": "scan (CombatZones/Tracker/Logistics/ItemChains/FluidChains)",
        "write_time": "write (Exporter.flush - only present on flush ticks)",
    }
    print("\nPer-tick timings (milliseconds):")
    field_stats = {}
    for field, label in labels.items():
        stats = _stats([s[field] for s in samples if s[field] is not None])
        field_stats[field] = stats
        if not stats:
            continue
        print(f"  {label}:")
        print(
            f"    samples={stats['count']}  min={stats['min']:.3f}  p50={stats['p50']:.3f}  "
            f"mean={stats['mean']:.3f}  p95={stats['p95']:.3f}  max={stats['max']:.3f}"
        )

    backfill_samples = [s for s in samples if s["backfill_remaining"] is not None]
    if backfill_samples:
        draining = [s for s in backfill_samples if s["backfill_remaining"] > 0]
        max_buffer = max((s["buffer_size"] for s in backfill_samples if s["buffer_size"] is not None), default=None)
        print("\nBackfill queue:")
        if draining:
            span_ticks = draining[-1]["tick"] - draining[0]["tick"] + 1
            print(
                f"  draining across ticks {draining[0]['tick']}-{draining[-1]['tick']} "
                f"(~{span_ticks / 60:.1f}s @ 60 UPS), peak queue depth "
                f"{max(s['backfill_remaining'] for s in draining)} chunk(s)"
            )
        else:
            print("  never non-empty in this log (full recording mode wasn't turned on with")
            print("  already-generated chunks pending, or diagnostics started after backfill finished)")
        if max_buffer is not None:
            print(f"  peak buffer_size seen: {max_buffer} event(s) - compare against the")
            print("  rrec-max-buffered-events setting actually in effect for this save (an")
            print("  existing save can keep an older stored value across a mod update, even")
            print("  if this mod's own default changed)")

    print(f"\nSlowest {top_n} tick(s) by field (tick number: value ms):")
    for field, label in labels.items():
        if not field_stats.get(field):
            continue
        worst = top_slowest(samples, field, top_n)
        print(f"  {label}:")
        for s in worst:
            print(f"    tick {s['tick']}: {s[field]:.3f}ms{_context_suffix(s)}")

    print("\nSlow streaks (consecutive ticks at/above the threshold below -")
    print("this is what actually reads as a stutter, not just one freak tick):")
    for field, label in labels.items():
        stats = field_stats.get(field)
        if not stats:
            continue
        threshold = streak_threshold_ms if streak_threshold_ms is not None else stats["p95"]
        streaks = find_slow_streaks(samples, field, threshold)
        print(f"  {label} (threshold={threshold:.3f}ms):")
        if not streaks:
            print("    none - no two consecutive ticks both crossed the threshold")
            continue
        for st in streaks[:top_n]:
            span_ticks = st["end_tick"] - st["start_tick"] + 1
            print(
                f"    ticks {st['start_tick']}-{st['end_tick']} ({span_ticks} ticks, "
                f"~{span_ticks / 60:.2f}s @ 60 UPS): peak={st['peak_ms']:.3f}ms  "
                f"total={st['total_ms']:.3f}ms"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--path", "-p",
        help="Path to factorio-current.log. Defaults to the standard Factorio user data location for your OS.",
    )
    parser.add_argument(
        "--top-n", "-n", type=int, default=10,
        help="How many slowest ticks/streaks to list per field (default 10).",
    )
    parser.add_argument(
        "--slow-threshold-ms", type=float, default=None,
        help="Minimum value (ms) for a tick to count toward a slow streak. "
             "Defaults to that field's own p95 for this log, so it adapts "
             "to the session instead of using one fixed number for every save.",
    )
    args = parser.parse_args()

    path = args.path or default_log_path()

    if not os.path.isfile(path):
        print(f"Could not find a Factorio log file at:\n  {path}")
        print("\nIf that's not where your Factorio user data directory is,")
        print("pass the real location with --path, e.g.:")
        print("  python3 tools/inspect_logs.py --path /path/to/factorio-current.log")
        sys.exit(1)

    samples, malformed = load_samples(path)
    print(f"Reading: {path}\n")
    print_report(samples, malformed, args.top_n, args.slow_threshold_ms)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        sys.exit(1)
