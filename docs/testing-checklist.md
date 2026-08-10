# Manual In-Game Test Checklist

Generates a `replay.json` that exercises every event type the mod can
produce, then hands off to two scripts that check it for you - you should
not need to read raw JSON to know whether something worked.

This is a throwaway test save - don't run it against your real base.
Console commands (`/c ...`) permanently disable achievements for a save
the moment you use one; that's expected and harmless here.

**Time budget:** every step below is a console block plus at most a few
seconds of waiting or one small manual action (drag an item, click
Respawn). The whole list should run well under 15 minutes.

**Already confirmed working, safe to skip if you're short on time:** steps
3, 4, 6, and 12 (cropping/zone expiry, full recording mode on/off,
vehicles/patrol, mod-reload regression). Steps 2, 5, 7, 8, 9, 10, and 11
are new or have new pieces folded in - run those.

---

## Before you start

1. **Install the mod.** Copy this repo's contents into a folder named
   `factorio-replay-recorder_0.1.0` (matching `info.json`) inside your
   Factorio `mods` directory - see the README's install section.
2. **Start a new save.**
3. **Open the console.** Press `` ` `` or `~` (rebindable under Settings
   → Controls → Toggle chat and Lua console if that doesn't work).

## 1. Setup

```
/c game.player.cheat_mode=true
```
Factorio makes you type the very first console command a second time as a
misfire guard - just run the same line again if nothing seems to happen.
```
/c game.player.force.research_all_technologies()
/c game.speed=3
/c settings.global["rrec-distant-sample-interval-seconds"] = {value = 1}
/c settings.global["rrec-chain-near-hops"] = {value = 1}
/c settings.global["rrec-chain-max-hops"] = {value = 50}
```
The last three speed up sampling and shrink the near/far chain split so
the later steps don't need real waiting or dozens of hand-placed entities.
Every command below is a single line starting with `/c` - paste it into
the console and press Enter.

---

## 2. Long-chain rollup (`item_distribution`)

This one has to run *before* full recording mode is turned on - it
specifically needs a chunk that is **not** actively recording at the far
end of the chain, which full recording mode would defeat.

One line, same reason as the spidertron/unit-group steps - local
variables don't carry over between separate `/c` commands, and re-finding
the far belt by position afterward (in a second command, using a
freshly-read `game.player.position` that may no longer exactly match
where it was placed) is exactly what broke this the first time around.
Keeping a direct reference to the belt as it's created sidesteps that
entirely - no re-lookup needed, and `or far_belt` keeps the *last
successfully placed* belt if the very last position happened to be
blocked by something:
```
/c local surface = game.player.surface; local base = game.player.position; local far_belt; for i = 0, 35 do far_belt = surface.create_entity{name = "transport-belt", position = {base.x + i, base.y + 20}, direction = defines.direction.east, force = "player"} or far_belt end; far_belt.get_transport_line(1).insert_at_back{name = "iron-plate", count = 5}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y + 20}, force = "enemy"}; b.die()
```
Killing the biter via `die()` (rather than requiring you to walk over and
fight it) opens a zone right at the *start* of the belt line, 36 tiles
from the far end, with no travel needed - just wait a couple of seconds.

## 3. Cropping & zone expiry

Continue right on from step 2 - no new setup needed.

**Action:** Walk (or `/c game.player.teleport({game.player.position.x + 100, game.player.position.y})`)
at least 50 tiles from where the biter died, then wait ~15 real seconds
without any further combat there (`/c game.speed=5` first if you'd rather
not wait; reset with `/c game.speed=3` after).

## 4. Full recording mode

```
/c settings.global["rrec-full-recording-mode"] = {value = true}
```
**Action:** Walk into a chunk you haven't touched yet, where nothing is
fighting - just stand there a couple of seconds. Everything from here on
records regardless of nearby combat, so you don't need to babysit zone
activity for the rest of this list.

This is also the step that exercises the perf fix for the freezing you
ran into on a save with a lot of already-generated chunks: enabling this
should no longer stall the game, and turning it back off (step 12) should
recover immediately instead of staying laggy for a while afterward.

## 5. Combat, turrets, walls, kill classification, fire/acid

```
/c game.player.insert{name="stone-wall", count=10}
/c game.player.insert{name="gate", count=2}
/c game.player.insert{name="gun-turret", count=1}
/c game.player.insert{name="laser-turret", count=1}
/c game.player.insert{name="flamethrower-turret", count=1}
/c game.player.insert{name="firearm-magazine", count=50}
```
**Action:** Place the wall, a gate, and all three turrets near you.
```
/c local ft = game.player.surface.find_entities_filtered{type = "fluid-turret", position = game.player.position, radius = 20}[1]; ft.insert_fluid{name = "crude-oil", amount = 100}
/c local b = game.player.surface.create_entity{name = "behemoth-biter", position = {game.player.position.x + 4, game.player.position.y}, force = "enemy"}; b.health = 1
/c local w = game.player.surface.create_entity{name = "medium-worm-turret", position = {game.player.position.x + 4, game.player.position.y + 3}, force = "enemy"}; w.health = 1
/c local s = game.player.surface.create_entity{name = "biter-spawner", position = {game.player.position.x + 4, game.player.position.y - 3}, force = "enemy"}; s.health = 1
/c local sp = game.player.surface.create_entity{name = "small-spitter", position = {game.player.position.x + 6, game.player.position.y}, force = "enemy"}
```
**Action:** Land a hit on each of the four hostiles (one-shots the three
already at 1 health), and let the spitter get a couple of acid hits in on
you or a turret before it dies too. Wait ~10 seconds afterward for the
acid patches to fade.

If `medium-worm-turret` errors on your game version, skip that line - it
won't affect the others.

## 6. Vehicles, wagons, and patrol

```
/c game.player.insert{name="car", count=1}
/c game.player.insert{name="tank", count=1}
```
**Action:** Place both and drive one near the fight from step 5.
```
/c local st = game.player.surface.create_entity{name="spidertron", position={game.player.position.x + 2, game.player.position.y}, force = game.player.force}; st.autopilot_destination = {st.position.x + 15, st.position.y}
```
Exercises the unmanned-spidertron-still-counts-as-a-player fix.

## 7. Player death, respawn, and corpse lifecycle

```
/c game.player.character.health = 5
/c game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 1, game.player.position.y}, force="enemy"}
```
**Action:** Let the biter kill you, then click Respawn.
```
/c local c = game.player.surface.find_entities_filtered{type = "character-corpse"}[1]; if c then c.get_inventory(defines.inventory.character_corpse).clear() end
```
Clearing a corpse's inventory is one of the two things that expire it
(the other is a timeout) - if `corpse_expired` doesn't show up in the
file right away, it'll still show up on its own after a short wait.

## 8. Ground items

**Action:** Open your inventory and drag one item stack out onto the
ground near you (this is the one event that genuinely needs a player
action - there's no scripted equivalent for the drop-item input).
```
/c game.player.surface.find_entities_filtered{type = "item-entity", position = game.player.position, radius = 10}[1].destroy()
```
Destroying it (rather than walking over it) is a reliable, scriptable way
to trigger the removal side - either cause is covered the same way.

## 9. Fluids

```
/c local tank = game.player.surface.create_entity{name = "storage-tank", position = {game.player.position.x - 3, game.player.position.y}, force = "player"}; tank.insert_fluid{name = "water", amount = 500}
```

## 10. Robot cargo

```
/c local bot = game.player.surface.create_entity{name = "logistic-robot", position = game.player.position, force = "player"}; bot.get_inventory(defines.inventory.robot_cargo).insert{name = "iron-plate", count = 5}
```

## 11. Unit group formation

One line, same reason as the spidertron step above - local variables
don't carry over between separate `/c` commands, and `create_unit_group`
returns the group directly rather than something you look back up:
```
/c local g = game.player.surface.create_unit_group{position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u1 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u2 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 11, game.player.position.y}, force = "enemy"}; g.add_member(u1); g.add_member(u2)
```

## 12. Full recording mode off + reload regression

```
/c settings.global["rrec-full-recording-mode"] = {value = false}
```
**Action:** Exit to the main menu (no need to close Factorio), go to
**Mods**, toggle any other installed mod on/off (or this mod off then
back on), then reload your save.

---

## After you're done

```
python3 tools/verify_checklist.py
```
Checks the replay for every event type/scenario above and prints a
pass/fail line for each - this is the thing to paste back, not raw JSON.
If everything's green, that's the whole report; if something's missing it
tells you which step to look at again.

For a broader look at what got recorded (battlefield count/duration,
scoreboard, sample payloads per event type):
```
python3 tools/inspect_replay.py
```
Both default to the standard Factorio `script-output` location for your
OS; pass `--path` if that's wrong for your setup.

---

## Not covered by this checklist (future work)

Noted rather than silently skipped:

* **Landmines** - not confirmed whether this mod tracks them at all
  (damage attribution, or even placement).
* **Flame damage attribution** - does a fire patch actually generate
  `damage_event`s against the entities/players standing in it, the way a
  direct hit does, or does fire damage bypass that path entirely?
* **Terrain/obstacle completeness** - trees, rocks, cliffs, and plain
  ground/water tiles aren't currently distinguished as combat-relevant
  obstacles the way buildings are; neither are other non-combat buildings
  (assemblers, furnaces, etc.) beyond being generically dumped as
  `statics` if not filtered out. Their *contents* don't matter (they're
  obstacles, not storage), just their presence/position for pathing and
  chokepoint analysis.
* **Gates as obstacles** - should probably be tagged `is_defense` and
  treated the same as walls, rather than left to fall through as an
  ungrouped static.
