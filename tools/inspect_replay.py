#!/usr/bin/env python3
"""Summarizes a Factorio Replay Recorder output file (replay.json) so you
don't have to read raw JSONL by hand to tell whether a test scenario
produced the events it should have.

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
"""

import argparse
import collections
import json
import os
import sys


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
            f"(~{span / 60:.1f}s of recorded activity, at 60 ticks/sec)"
        )

    print("\nEvent counts by type:")
    for event_type, count in counts.most_common():
        print(f"  {event_type:<20} {count}")

    _summarize_chunks(events)
    _summarize_scores(events)
    _summarize_kills(events)

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


def _summarize_chunks(events):
    chunks = set()
    for e in events:
        if e.get("type") == "chunk_snapshot":
            data = e.get("data", {})
            chunk = data.get("chunk")
            surface = data.get("surface")
            if chunk is not None:
                chunks.add((surface, tuple(chunk)))
    if chunks:
        print(f"\nDistinct chunks snapshotted: {len(chunks)}")
        for surface, chunk in sorted(chunks):
            print(f"  surface={surface} chunk={list(chunk)}")


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
        "--limit", "-n", type=int, default=2,
        help="Number of sample payloads to print per event type (default: 2).",
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
