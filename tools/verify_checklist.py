#!/usr/bin/env python3
"""Checks a replay.json against every scenario in docs/testing-checklist.md
and prints a pass/fail line for each - this is the thing to paste back
when asking whether a test session worked, instead of raw JSON or the
full output of inspect_replay.py.

Usage:
    python3 tools/verify_checklist.py
    python3 tools/verify_checklist.py --path /custom/path/replay.json

Exits 0 if every check passes, 1 otherwise (so it's also usable as a
simple pass/fail gate, not just a human-readable report).

Standard library only, no dependencies to install.
"""

import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inspect_replay import default_replay_path, load_events  # noqa: E402


def _count(events, etype):
    return sum(1 for e in events if e.get("type") == etype)


def _values(events, etype, path):
    """Yields data[path[0]][path[1]]... for every event of the given
    type, skipping anything that doesn't resolve (missing key, wrong
    shape, etc.) rather than erroring."""
    for e in events:
        if e.get("type") != etype:
            continue
        v = e.get("data", {})
        for key in path:
            if not isinstance(v, dict):
                v = None
                break
            v = v.get(key)
        if v is not None:
            yield v


def present(etype):
    def fn(events):
        n = _count(events, etype)
        if n == 0:
            return False, "0 events of this type"
        return True, f"{n} event(s)"
    return fn


def check_statics_nonempty(events):
    for e in events:
        if e.get("type") == "chunk_snapshot" and e.get("data", {}).get("statics"):
            return True, f"e.g. {len(e['data']['statics'])} statics in one snapshot"
    return False, "every chunk_snapshot had an empty statics list"


def check_tiles_nonempty(events):
    for e in events:
        if e.get("type") == "chunk_snapshot" and e.get("data", {}).get("tiles"):
            return True, f"e.g. {len(e['data']['tiles'])} tiles in one snapshot"
    return False, "every chunk_snapshot had an empty tiles list"


def check_logistics_nonempty(events):
    for e in events:
        if e.get("type") == "chunk_snapshot" and e.get("data", {}).get("logistics"):
            return True, f"e.g. {len(e['data']['logistics'])} network(s) in one snapshot"
    return False, "every chunk_snapshot had an empty logistics list - the roboport in step 4 probably isn't reachable from the zone chunk"


def check_kill_classification(events):
    kinds = set(_values(events, "death_event", ["victim", "hostile_kind"]))
    required = {"biter", "spitter", "worm", "spawner"}
    missing = required - kinds
    if missing:
        return False, f"missing hostile_kind(s): {', '.join(sorted(missing))} (saw: {', '.join(sorted(kinds)) or 'none'})"
    return True, f"saw {', '.join(sorted(kinds))}"


def check_turret_damage(events):
    dealers = {d for d in _values(events, "damage_event", ["dealer"]) if d}
    turret_dealers = {d for d in dealers if "turret" in d}
    if not turret_dealers:
        return False, f"no damage_event dealt by anything with 'turret' in its name (dealers seen: {', '.join(sorted(dealers)) or 'none'})"
    return True, f"saw {', '.join(sorted(turret_dealers))}"


def check_turret_destroyed(events):
    victims = set()
    for e in events:
        if e.get("type") != "death_event":
            continue
        victim = e.get("data", {}).get("victim", {})
        vtype = victim.get("type")
        if vtype and "turret" in vtype:
            victims.add(victim.get("name") or vtype)
    if not victims:
        return False, "no death_event with a turret-typed victim (the weak turret in step 8 should get destroyed by the behemoth)"
    return True, f"saw {', '.join(sorted(victims))}"


def check_vehicle_diversity(events):
    types = set()
    for e in events:
        if e.get("type") != "mobile_positions":
            continue
        for entry in e.get("data", []):
            t = entry.get("type")
            if t:
                types.add(t)
    required = {"car", "spider-vehicle"}
    missing = required - types
    if missing:
        return False, f"missing mobile entity type(s): {', '.join(sorted(missing))} (saw: {', '.join(sorted(types)) or 'none'})"
    return True, f"saw {', '.join(sorted(types))}"


def check_owner_kinds(events):
    kinds = set(_values(events, "inventory_delta", ["owner_kind"]))
    required = {"player", "vehicle", "container", "corpse", "robot", "inserter_hand", "ground_item"}
    missing = required - kinds
    if missing:
        return False, f"missing owner_kind(s): {', '.join(sorted(missing))} (saw: {', '.join(sorted(kinds)) or 'none'})"
    return True, f"saw {', '.join(sorted(kinds))}"


# (check name, checklist step to re-run on failure, check function)
CHECKS = [
    ("chunk_snapshot recorded", "1-2", present("chunk_snapshot")),
    ("chunk_snapshot has non-empty statics", "8", check_statics_nonempty),
    ("chunk_snapshot has non-empty tiles", "1-2", check_tiles_nonempty),
    ("chunk_snapshot has a non-empty logistics roster", "4", check_logistics_nonempty),
    ("zone_expired recorded", "6", present("zone_expired")),
    ("mobile_positions recorded", "1-2", present("mobile_positions")),
    ("death_event recorded", "8", present("death_event")),
    ("kill classification covers biter/spitter/worm/spawner", "8-9", check_kill_classification),
    ("score_update recorded", "11", present("score_update")),
    ("player_respawn recorded", "11", present("player_respawn")),
    ("damage_event recorded", "8", present("damage_event")),
    ("damage_event includes turret-dealt damage", "8", check_turret_damage),
    ("death_event includes a turret being destroyed", "8", check_turret_destroyed),
    ("projectile_impact recorded", "8", present("projectile_impact")),
    ("effect_created recorded (fire/acid)", "8-9", present("effect_created")),
    ("effect_expired recorded (fire/acid fading)", "8-9", present("effect_expired")),
    ("vehicle diversity (car + spidertron seen)", "10", check_vehicle_diversity),
    ("belt_contents recorded", "2", present("belt_contents")),
    ("item_distribution recorded (long-chain rollup)", "2-3", present("item_distribution")),
    ("fluid_delta recorded", "5, 13", present("fluid_delta")),
    ("inventory_delta owner_kind coverage", "3-4, 8-14", check_owner_kinds),
    ("corpse_created recorded", "11", present("corpse_created")),
    ("corpse_expired recorded", "11", present("corpse_expired")),
    ("ground_item_created recorded", "12", present("ground_item_created")),
    ("ground_item_removed recorded", "12", present("ground_item_removed")),
    ("unit_group_created recorded", "15", present("unit_group_created")),
]


def run_checks(events):
    results = []
    for name, step, fn in CHECKS:
        try:
            passed, detail = fn(events)
        except Exception as exc:  # a check itself misbehaving shouldn't kill the whole report
            passed, detail = False, f"check errored: {exc}"
        results.append((name, step, passed, detail))
    return results


def print_report(results):
    print("=" * 70)
    print("Factorio Replay Recorder - checklist verification")
    print("=" * 70)

    for name, step, passed, detail in results:
        mark = "PASS" if passed else "FAIL"
        print(f"[{mark}] {name}")
        print(f"       {detail}")

    passed_count = sum(1 for _, _, p, _ in results if p)
    print(f"\n{passed_count}/{len(results)} checks passed")

    failed = [(name, step) for name, step, passed, _ in results if not passed]
    if failed:
        print("\nRe-run these checklist steps:")
        for name, step in failed:
            print(f"  step {step}: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--path", "-p",
        help="Path to replay.json. Defaults to the standard Factorio script-output location for your OS.",
    )
    args = parser.parse_args()

    path = args.path or default_replay_path()

    if not os.path.isfile(path):
        print(f"Could not find a replay file at:\n  {path}")
        print("\nIf that's not where your Factorio user data directory is,")
        print("pass the real location with --path, e.g.:")
        print("  python3 tools/verify_checklist.py --path /path/to/replay.json")
        sys.exit(1)

    events, malformed = load_events(path)
    print(f"Reading: {path}")
    if malformed:
        print(f"(skipped {malformed} malformed line(s))")
    if not events:
        print("\nNo events in this file - nothing to check. Run through")
        print("docs/testing-checklist.md first.")
        sys.exit(1)

    results = run_checks(events)
    print_report(results)
    sys.exit(0 if all(passed for _, _, passed, _ in results) else 1)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        sys.exit(1)
