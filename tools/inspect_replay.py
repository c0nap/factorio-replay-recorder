#!/usr/bin/env python3
"""Summarizes a Factorio Replay Recorder output file (replay.json) so you
don't have to read raw JSONL by hand to tell what a session recorded.

Usage:
    python3 tools/inspect_replay.py
    python3 tools/inspect_replay.py --path /custom/path/replay.json
    python3 tools/inspect_replay.py --type death_event --limit 5

With no arguments, it looks for replay.json in the default Factorio
script-output directory for your OS. The mod writes newline-delimited JSON
(JSONL) - one `{"tick": ..., "type": ..., "data": ...}` object per line -
so this script parses it as a stream rather than a single JSON document.

Nothing here talks to Factorio or the mod directly; it only reads the file
the mod already wrote. Standard library only, no dependencies to install.

For a pass/fail check against a specific test scenario (docs/testing-
checklist.md), use tools/verify_checklist.py instead - this script is a
general-purpose summary, not a test runner.

For per-tick performance timings (rrec-diagnostics-enabled), see
tools/inspect_logs.py instead - those are written to Factorio's own log
file, not to replay.json (LuaProfiler can't hand a raw duration value to
Lua for embedding in a JSON event; see script/diagnostics.lua).
"""

import argparse
import collections
import json
import math
import os
import re
import sys

CHUNK_SIZE = 32
TICKS_PER_SECOND = 60
CHUNK_ID_RE = re.compile(r"^(.*)_(-?\d+)_(-?\d+)$")


def default_replay_path():
    """Best-effort guess at where Factorio's script-output/replay.json
    lives, based on the documented per-OS user data directory. If this
    guess is wrong for your setup, pass --path explicitly."""
    if sys.platform.startswith("win"):
        appdata = os.environ.get("APPDATA")
        if appdata:
            return os.path.join(appdata, "Factorio", "script-output", "replay.json")
    elif sys.platform == "darwin":
        return os.path.expanduser(
            "~/Library/Application Support/factorio/script-output/replay.json"
        )
    # Linux, and the Windows fallback if APPDATA wasn't set for some reason.
    return os.path.expanduser("~/.factorio/script-output/replay.json")


def load_events(path):
    """Reads a JSONL replay file, returning (events, malformed_line_count).
    A malformed line (e.g. one Factorio was still writing when this ran)
    is skipped rather than aborting the whole read."""
    events = []
    malformed = 0

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                malformed += 1

    return events, malformed


def truncate(obj, max_items=5):
    """Recursively shortens long lists in a parsed JSON value so a sample
    event (which might carry a mobile_positions array with hundreds of
    entries) prints as a few representative items instead of a wall of
    text."""
    if isinstance(obj, list):
        shown = [truncate(item, max_items) for item in obj[:max_items]]
        if len(obj) > max_items:
            shown.append("... {} more item(s)".format(len(obj) - max_items))
        return shown
    if isinstance(obj, dict):
        return {key: truncate(value, max_items) for key, value in obj.items()}
    return obj


def find_positions(obj):
    """Yields every {"x": ..., "y": ...} dict found anywhere inside a
    parsed JSON value. Generic on purpose: different event types carry
    position at different nesting depths (top-level, per-entity in
    mobile_positions, nested under `victim`/`source`, ...), and walking
    for the shape rather than hardcoding a field path per event type means
    this doesn't need updating every time an event's schema changes."""
    if isinstance(obj, dict):
        x, y = obj.get("x"), obj.get("y")
        if (
            set(obj.keys()) == {"x", "y"}
            and isinstance(x, (int, float))
            and isinstance(y, (int, float))
        ):
            yield obj
            return
        for value in obj.values():
            yield from find_positions(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from find_positions(value)


def _chunk_snapshot_chunks(events):
    """{(surface, cx, cy): first_tick} for every chunk ever snapshotted -
    chunk_snapshot fires exactly once per chunk, the first time it becomes
    active, making this the precise, authoritative set of "chunks that
    were ever part of a recorded battlefield" (no position-guessing
    needed for cluster membership, only for the activity breakdown
    below)."""
    chunks = {}
    for e in events:
        if e.get("type") != "chunk_snapshot":
            continue
        data = e.get("data", {})
        chunk = data.get("chunk")
        surface = data.get("surface")
        tick = e.get("tick")
        if chunk is None or surface is None or tick is None:
            continue
        key = (surface, chunk[0], chunk[1])
        if key not in chunks or tick < chunks[key]:
            chunks[key] = tick
    return chunks


def _zone_expiry_ticks(events):
    """{(surface, cx, cy): [expiry ticks]} parsed from zone_expired's
    chunk_id string, in the same "<surface>_<cx>_<cy>" format
    combat_zones.lua's chunk_id() builds it in."""
    expiries = collections.defaultdict(list)
    for e in events:
        if e.get("type") != "zone_expired":
            continue
        chunk_id = e.get("data", {}).get("chunk_id")
        tick = e.get("tick")
        if not chunk_id or tick is None:
            continue
        m = CHUNK_ID_RE.match(chunk_id)
        if not m:
            continue
        surface, cx, cy = m.group(1), int(m.group(2)), int(m.group(3))
        expiries[(surface, cx, cy)].append(tick)
    return expiries


def _cluster_battlefields(chunk_first_tick):
    """Groups chunk_snapshot chunks into connected components (8-connected
    adjacency, same surface) - each component is one "battlefield": a
    spatially contiguous area that was ever recorded, regardless of how
    many separate times it went quiet and reactivated in between."""
    parent = {key: key for key in chunk_first_tick}

    def find(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    by_surface = collections.defaultdict(list)
    for surface, cx, cy in chunk_first_tick:
        by_surface[surface].append((cx, cy))

    for surface, coords in by_surface.items():
        coord_set = set(coords)
        for cx, cy in coords:
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    if (cx + dx, cy + dy) in coord_set:
                        union((surface, cx, cy), (surface, cx + dx, cy + dy))

    clusters = collections.defaultdict(list)
    for key in chunk_first_tick:
        clusters[find(key)].append(key)
    return list(clusters.values())


def _battlefield_stats(events):
    """One entry per spatially-connected cluster of ever-active chunks:
    chunk count/bounding box, activity time span, and a rough breakdown of
    what happened there. Returns None if there's nothing to cluster."""
    chunk_first_tick = _chunk_snapshot_chunks(events)
    if not chunk_first_tick:
        return None

    zone_expiries = _zone_expiry_ticks(events)
    clusters = _cluster_battlefields(chunk_first_tick)

    all_ticks = [e.get("tick") for e in events if isinstance(e.get("tick"), (int, float))]
    max_tick = max(all_ticks) if all_ticks else 0

    stats = []
    # Keyed by (cx, cy) only (surface dropped) - most events don't carry
    # an explicit surface field to cross-reference against, so this
    # assumes one global grid. Correct for the common single-surface
    # case; an approximation (could misattribute across surfaces sharing
    # the same chunk coordinates) if multiple surfaces are in play.
    chunk_to_cluster = {}
    for idx, chunks in enumerate(clusters):
        surface = chunks[0][0]
        cxs = [c[1] for c in chunks]
        cys = [c[2] for c in chunks]
        expiry_ticks = [t for c in chunks for t in zone_expiries.get(c, [])]
        stats.append({
            "surface": surface,
            "chunk_count": len(chunks),
            "bbox": (min(cxs), max(cxs), min(cys), max(cys)),
            "first_tick": min(chunk_first_tick[c] for c in chunks),
            "last_tick": max(expiry_ticks) if expiry_ticks else max_tick,
            "still_active": not expiry_ticks,
            "events": collections.Counter(),
        })
        for c in chunks:
            chunk_to_cluster[(c[1], c[2])] = idx

    for e in events:
        etype = e.get("type")
        if etype in ("chunk_snapshot", "zone_expired"):
            continue  # structural facts, not "activity", already counted above
        touched = set()
        for pos in find_positions(e.get("data")):
            cx = math.floor(pos["x"] / CHUNK_SIZE)
            cy = math.floor(pos["y"] / CHUNK_SIZE)
            idx = chunk_to_cluster.get((cx, cy))
            if idx is not None:
                touched.add(idx)
        for idx in touched:
            stats[idx]["events"][etype] += 1

    return stats


def _print_battlefields(events, max_shown=15):
    stats = _battlefield_stats(events)
    if not stats:
        print("\nBattlefields found: 0 (no chunk_snapshot events)")
        return

    print(f"\nBattlefields found: {len(stats)}")
    ranked = sorted(stats, key=lambda c: sum(c["events"].values()), reverse=True)
    for i, c in enumerate(ranked[:max_shown], 1):
        min_cx, max_cx, min_cy, max_cy = c["bbox"]
        span_s = (c["last_tick"] - c["first_tick"]) / TICKS_PER_SECOND
        active_note = " [still active at end of recording]" if c["still_active"] else ""
        print(
            f"  #{i} {c['surface']}: {c['chunk_count']} chunk(s) "
            f"(bbox {max_cx - min_cx + 1}x{max_cy - min_cy + 1}), "
            f"ticks {c['first_tick']}-{c['last_tick']} (~{span_s:.0f}s){active_note}"
        )
        top = ", ".join(f"{n} {t}" for t, n in c["events"].most_common(5))
        if top:
            print(f"      {top}")
    if len(ranked) > max_shown:
        print(f"  ... and {len(ranked) - max_shown} more (smaller/quieter)")


def summarize(events, malformed, sample_limit, only_type):
    counts = collections.Counter(e.get("type", "<missing type>") for e in events)

    print("=" * 70)
    print("Factorio Replay Recorder - replay.json summary")
    print("=" * 70)

    if not events:
        print("No events found in the file (it may be empty, or nothing")
        print("in-game has triggered the mod's cropping system yet).")
        return

    ticks = [e.get("tick") for e in events if isinstance(e.get("tick"), (int, float))]
    print(f"Total events: {len(events)}")
    if malformed:
        print(f"Skipped malformed lines: {malformed}")
    if ticks:
        span = max(ticks) - min(ticks)
        print(
            f"Tick range: {min(ticks)} - {max(ticks)} "
            f"(~{span / TICKS_PER_SECOND:.1f}s of recorded activity, at {TICKS_PER_SECOND} ticks/sec)"
        )

    print("\nEvent counts by type:")
    for event_type, count in counts.most_common():
        print(f"  {event_type:<20} {count}")

    _print_battlefields(events)
    _summarize_owner_kinds(events)
    _summarize_scores(events)
    _summarize_kills(events)
    _summarize_combat_diversity(events)

    types_to_sample = [only_type] if only_type else [t for t, _ in counts.most_common()]
    print("\nSample payloads:")
    for event_type in types_to_sample:
        matching = [e for e in events if e.get("type") == event_type]
        if not matching:
            print(f"\n-- {event_type}: no events of this type found --")
            continue
        print(f"\n-- {event_type} (showing {min(sample_limit, len(matching))} of {len(matching)}) --")
        for event in matching[:sample_limit]:
            print(json.dumps(truncate(event), indent=2))


def _summarize_owner_kinds(events):
    kinds = collections.Counter()
    for e in events:
        if e.get("type") == "inventory_delta":
            kind = e.get("data", {}).get("owner_kind")
            if kind:
                kinds[kind] += 1
    if kinds:
        print("\ninventory_delta owner kinds seen:")
        for kind, count in kinds.most_common():
            print(f"  {kind:<15} {count}")


def _summarize_scores(events):
    latest_by_force = {}
    for e in events:
        if e.get("type") == "score_update":
            data = e.get("data", {})
            force = data.get("force")
            if force is not None:
                latest_by_force[force] = data.get("deaths_this_force")
    if latest_by_force:
        print("\nScoreboard (latest deaths_this_force per force):")
        for force, deaths in latest_by_force.items():
            print(f"  {force}: {deaths}")


def _summarize_kills(events):
    kills = collections.Counter()
    for e in events:
        if e.get("type") == "death_event":
            victim = e.get("data", {}).get("victim", {})
            kind = victim.get("hostile_kind")
            if kind:
                kills[(kind, victim.get("hostile_size"))] += 1
    if kills:
        print("\nHostile kills by kind/size:")
        for (kind, size), count in sorted(kills.items()):
            print(f"  {kind}/{size}: {count}")


def _summarize_combat_diversity(events):
    """Distinct-value breakdowns for the fields a few checklist checks
    hinge on (weapon, effect source, damage dealer/dealt_by) - added
    because "does this ever show more than one value" is exactly the
    question those checks ask, and a single sample payload per event type
    can't answer it. This reads data the mod is already recording; no new
    probe or replay is needed to get it."""
    weapons = collections.Counter()
    for e in events:
        if e.get("type") == "projectile_impact":
            weapon = e.get("data", {}).get("weapon")
            if weapon:
                weapons[weapon] += 1
    if weapons:
        print("\nprojectile_impact weapons seen:")
        for weapon, count in weapons.most_common():
            print(f"  {weapon:<30} {count}")

    effect_sources = collections.Counter()
    for e in events:
        if e.get("type") == "effect_created":
            data = e.get("data", {})
            effect_sources[(data.get("name"), data.get("source"))] += 1
    if effect_sources:
        print("\neffect_created (name, source) pairs seen:")
        for (name, source), count in effect_sources.most_common():
            print(f"  name={name!r:<20} source={source!r:<25} {count}")

    damage_pairs = collections.Counter()
    for e in events:
        if e.get("type") == "damage_event":
            data = e.get("data", {})
            damage_pairs[(data.get("dealer"), data.get("dealt_by"))] += 1
    if damage_pairs:
        print("\ndamage_event (dealer, dealt_by) pairs seen:")
        for (dealer, dealt_by), count in damage_pairs.most_common():
            print(f"  dealer={dealer!r:<20} dealt_by={dealt_by!r:<25} {count}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--path", "-p",
        help="Path to replay.json. Defaults to the standard Factorio script-output location for your OS.",
    )
    parser.add_argument(
        "--type", "-t",
        help="Only show sample payloads for this event type (counts/summary sections still cover everything).",
    )
    parser.add_argument(
        "--limit", "-n", type=int, default=1,
        help="Number of sample payloads to print per event type (default: 1).",
    )
    args = parser.parse_args()

    path = args.path or default_replay_path()

    if not os.path.isfile(path):
        print(f"Could not find a replay file at:\n  {path}")
        print("\nIf that's not where your Factorio user data directory is,")
        print("pass the real location with --path, e.g.:")
        print("  python3 tools/inspect_replay.py --path /path/to/replay.json")
        sys.exit(1)

    events, malformed = load_events(path)
    print(f"Reading: {path}\n")
    summarize(events, malformed, args.limit, args.type)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # Happens if output is piped into something like `head` that closes
        # the pipe early - not a real failure, so exit quietly instead of
        # printing a traceback.
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        sys.exit(1)
