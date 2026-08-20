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
    return False, "every chunk_snapshot had an empty logistics list - the roboport in step 6 probably isn't reachable from the zone chunk"


def check_kill_classification(events):
    kinds = set(_values(events, "death_event", ["victim", "hostile_kind"]))
    required = {"biter", "spitter", "worm", "spawner"}
    missing = required - kinds
    if missing:
        return False, f"missing hostile_kind(s): {', '.join(sorted(missing))} (saw: {', '.join(sorted(kinds)) or 'none'})"
    return True, f"saw {', '.join(sorted(kinds))}"


# Deliberately a name allowlist, not "anything with 'turret' in it": a
# real run showed both of these checks passing purely because the
# player-hostile medium-worm-turret (spawned in the same step for kill-
# classification coverage) dealt damage / got killed - "turret" matches
# its name too, so the checks were satisfied without the PLAYER's own
# gun/flamethrower turret ever proving anything. Only the turrets this
# mod's checklist actually places for the player count here.
PLAYER_TURRET_NAMES = {"gun-turret", "laser-turret", "flamethrower-turret"}


def check_turret_damage(events):
    dealers = {d for d in _values(events, "damage_event", ["dealer"]) if d}
    turret_dealers = dealers & PLAYER_TURRET_NAMES
    if not turret_dealers:
        return False, (
            f"no damage_event dealt by a player-placed turret ({', '.join(sorted(PLAYER_TURRET_NAMES))}) "
            f"(dealers seen: {', '.join(sorted(dealers)) or 'none'}) - note a worm turret also has "
            "'turret' in its name but doesn't count here"
        )
    return True, f"saw {', '.join(sorted(turret_dealers))}"


def check_turret_destroyed(events):
    victims = set()
    for e in events:
        if e.get("type") != "death_event":
            continue
        victim = e.get("data", {}).get("victim", {})
        name = victim.get("name")
        if name in PLAYER_TURRET_NAMES:
            victims.add(name)
    if not victims:
        return False, (
            f"no death_event with a player-placed turret ({', '.join(sorted(PLAYER_TURRET_NAMES))}) as "
            "victim - the weak turret in step 12 should get destroyed by the behemoth"
        )
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


def check_inserter_chest_disambiguation(events):
    """Step 5: two independent inserter+chest pairs, placed within each
    other's search radius so each chest is a real candidate for the
    *other* inserter too. iron-plate should land on one container owner,
    copper-plate on a different one - never both on the same owner key,
    which would mean the chain walk merged or misattributed the pair."""
    owners_with_item = collections.defaultdict(set)
    for e in events:
        if e.get("type") != "inventory_delta" or e.get("data", {}).get("owner_kind") != "container":
            continue
        owner = e["data"].get("owner")
        for change in e["data"].get("changes", []):
            item = change.get("item")
            if item and change.get("delta", 0) > 0:
                owners_with_item[owner].add(item)

    iron_owners = {o for o, items in owners_with_item.items() if "iron-plate" in items}
    copper_owners = {o for o, items in owners_with_item.items() if "copper-plate" in items}

    if not iron_owners:
        return False, "no container owner ever received iron-plate (chest_a)"
    if not copper_owners:
        return False, "no container owner ever received copper-plate (chest_b)"
    overlap = iron_owners & copper_owners
    if overlap:
        return False, f"iron-plate and copper-plate landed on the same container owner ({', '.join(sorted(overlap))}) - chest_a/chest_b got merged"
    return True, f"iron-plate -> {', '.join(sorted(iron_owners))}, copper-plate -> {', '.join(sorted(copper_owners))}"


def check_owner_kinds(events):
    kinds = set(_values(events, "inventory_delta", ["owner_kind"]))
    required = {"player", "vehicle", "container", "corpse", "robot", "inserter_hand", "ground_item"}
    missing = required - kinds
    if missing:
        return False, f"missing owner_kind(s): {', '.join(sorted(missing))} (saw: {', '.join(sorted(kinds)) or 'none'})"
    return True, f"saw {', '.join(sorted(kinds))}"


def check_acid_source_diversity(events):
    """Step 14 merges the worm and spitter acid tests so both patches are
    live at once - a source-name count of >= 2 confirms two genuinely
    distinct attackers created fire/acid, not just repeated hits from one
    (step 12's flamethrower is a third possible source, so this is a
    floor, not an exact count)."""
    sources = {v for v in _values(events, "effect_created", ["source"]) if v}
    if len(sources) < 2:
        return False, (
            f"expected effect_created from at least 2 distinct sources (the worm and spitter "
            f"in step 14, plus step 12's flamethrower), saw: {', '.join(sorted(sources)) or 'none'}"
        )
    return True, f"saw sources: {', '.join(sorted(sources))}"


def check_vehicle_combat_credit_diversity(events):
    """Step 16: the tank should credit damage two different ways - a
    dealt_by projectile for the shot target, and a bare collision for the
    run-over target. Checking for both, rather than just any damage_event
    with dealer=tank, is what actually confirms both mechanisms fired
    instead of one masking the other.

    A bare vehicle collision reports BOTH cause and source as the vehicle
    itself (dealer=tank, dealt_by=tank), never a nil dealt_by, so the
    distinguishing signal is whether dealt_by names a DIFFERENT entity (a
    fired projectile/stream - the "shot" case) or the same entity as the
    dealer (a bare collision, nothing more specific "dealt" it)."""
    shot = False
    ran_over = False
    for e in events:
        if e.get("type") != "damage_event":
            continue
        data = e.get("data", {})
        dealer = data.get("dealer")
        dealt_by = data.get("dealt_by")
        if dealer != "tank" or not dealt_by:
            continue
        if dealt_by == dealer:
            ran_over = True
        else:
            shot = True

    if not shot:
        return False, "no damage_event dealt by the tank via a projectile (dealt_by != dealer) - the shot target"
    if not ran_over:
        return False, "no damage_event dealt by the tank as a bare collision (dealt_by == dealer) - the run-over target"
    return True, "saw both a projectile-dealt hit and a bare collision credited to the tank"


# (check name, checklist step to re-run on failure, check function)
# Step numbers below match docs/testing-checklist.md's current order (a
# dedicated zone-lifecycle step 2, full recording mode turned on as early
# as steps 3-7's near/far tests allow at step 8, ground items/robot cargo/
# basic fluids moved after it since they no longer need their own
# zone-opening kill, and the old spitter-acid step folded into the worm/
# spawner kill-classification step - see that file's step 3/8/14 notes).
CHECKS = [
    ("chunk_snapshot recorded", "1-2", present("chunk_snapshot")),
    ("chunk_snapshot has non-empty statics", "12", check_statics_nonempty),
    ("chunk_snapshot has non-empty tiles", "1-2", check_tiles_nonempty),
    ("chunk_snapshot has a non-empty logistics roster", "6", check_logistics_nonempty),
    ("inserter-to-chest servicing disambiguates a nearby pair", "5", check_inserter_chest_disambiguation),
    ("zone_created recorded", "1-2", present("zone_created")),
    ("zone_expired recorded", "3-7", present("zone_expired")),
    ("mobile_positions recorded", "1-2", present("mobile_positions")),
    ("death_event recorded", "12", present("death_event")),
    ("kill classification covers biter/spitter/worm/spawner", "14", check_kill_classification),
    ("score_update recorded", "18", present("score_update")),
    ("player_respawn recorded", "18", present("player_respawn")),
    ("damage_event recorded", "12", present("damage_event")),
    ("damage_event includes turret-dealt damage", "12", check_turret_damage),
    ("death_event includes a turret being destroyed", "12", check_turret_destroyed),
    ("projectile_impact recorded", "12, 16", present("projectile_impact")),
    ("effect_created recorded (fire/acid)", "12, 14", present("effect_created")),
    ("effect_expired recorded (fire/acid fading)", "12, 14", present("effect_expired")),
    ("acid effect diversity (worm + spitter sources)", "14", check_acid_source_diversity),
    ("vehicle diversity (car + spidertron seen)", "13, 17", check_vehicle_diversity),
    ("vehicle combat damage/kill credit diversity (shot vs. run over)", "16", check_vehicle_combat_credit_diversity),
    ("belt_contents recorded", "3", present("belt_contents")),
    ("item_distribution recorded (long-chain rollup)", "3-4", present("item_distribution")),
    ("fluid_delta recorded", "7, 11", present("fluid_delta")),
    ("inventory_delta owner_kind coverage", "3-18", check_owner_kinds),
    ("corpse_created recorded", "18", present("corpse_created")),
    ("corpse_expired recorded", "18", present("corpse_expired")),
    ("ground_item_created recorded", "9", present("ground_item_created")),
    ("ground_item_removed recorded", "9", present("ground_item_removed")),
    ("unit_group_created recorded", "19", present("unit_group_created")),
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
