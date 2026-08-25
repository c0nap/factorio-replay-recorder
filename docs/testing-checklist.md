# Ideal Replay Checklist

A step-by-step recipe for recording an "ideal replay" - a single
`replay.json` that exercises every event type this mod can produce.
Following it once, in a throwaway save, produces a complete reference
replay; two scripts then check it for completeness, so you don't need to
read raw JSON to confirm it's ready to use.

This is a throwaway test save - don't run it against your real base.
Console commands (`/c ...`) permanently disable achievements for a save
the moment you use one; that's expected and harmless here.

Most kills/damage/destruction below are scripted with weak/one-hit
targets placed apart from each other, so you're not fighting to land a
hit on one thing without also killing another. Steps that need you to
actually do something say **Action:** explicitly. Steps marked
**Cleanup:** leave something alive/active on purpose (it has no reason to
go away on its own) - clear it before moving on so it doesn't interfere
with a later test. This matters for more than just biters: a still-armed
turret from an earlier step will happily fire at whatever gets spawned
near it next, so cleanup steps also remove player-placed turrets, not
just enemies.

---

## Before you start

1. **Install the mod.** Copy this repo's contents into a folder named
   `replay-recorder_<version>`, matching the `name`/`version` in
   `info.json` (e.g. `replay-recorder_0.1.1`), inside your Factorio
   `mods` directory - see the README's [Installation](../README.md#installation)
   section.
2. **Start a new save.** Pick a spawn with a reasonably large flat/land
   area if you can - step 1 below clears trees near you, but not water,
   and a scripted `create_entity` on a water tile can silently fail to
   place anything.
3. **Open the console.** Press `` ` `` or `~` (rebindable under Settings
   → Controls → Toggle chat and Lua console if that doesn't work).

## 1. Setup

```
/c game.player.cheat_mode=true
```
Type this command twice - Factorio has a misfire guard for the first console
command of a session.
```
/c game.player.force.research_all_technologies(); game.speed=3; settings.global["rrec-combat-radius"] = {value = 100}; settings.global["rrec-distant-sample-interval-seconds"] = {value = 1}; settings.global["rrec-chain-near-hops"] = {value = 1}; settings.global["rrec-chain-max-hops"] = {value = 50}; settings.global["rrec-chunk-backfill-per-tick"] = {value = 2}; settings.global["rrec-max-buffered-events"] = {value = 2}; settings.global["rrec-diagnostics-enabled"] = {value = true}; settings.global["rrec-battlefield-marker-enabled"] = {value = true}
```
Turns on diagnostics and the battlefield marker (cyan outline around
active zones). Also widens the combat radius to 100 tiles - steps 4-7
below each place their scripted kill a chunk or two from where you're
standing, and the default radius (48) can be too short for that kill to
open a zone at all, which means neither the marker nor the distant-chain
recording those steps are testing would ever kick in. The chunk-backfill
and max-buffered-events settings are pinned explicitly too, not left to
the mod's own defaults - an existing save keeps whatever value it last
had for a setting even after a mod update changes that default, so
setting them here guarantees this run actually exercises the current
full-recording throttling rather than silently running on stale numbers.
See "After you're done" below for where the diagnostics data ends up and
how to read it.
```
/c local p = game.player.position; for _, t in ipairs(game.player.surface.find_entities_filtered{position = p, radius = 150, type = "tree"}) do t.destroy() end
```
Clears trees within 150 tiles - everything below stays within that
radius of wherever you're standing right now, and a tree sitting on a
scripted entity's exact spawn tile can block it from being created at
all. Doesn't touch water - if your immediate surroundings are mostly
water, moving somewhere drier first will save you trouble.

## 2. Zone lifecycle

Tests: the basic `zone_created`/`zone_expired` lifecycle in isolation,
before anything else runs - if this doesn't work, nothing downstream
will either, so it's worth knowing immediately rather than diagnosing it
through eighteen other steps' noise.

```
/c local b = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 1, game.player.position.y}, force = "enemy"}; b.die()
```
Wait until the cyan outline disappears - confirms `zone_expired` fired on
its own, not just `zone_created`.

## 3. Long-chain rollup via belts (`item_distribution`)

Tests: a belt chain running far past a zone's own chunk gets rolled up
into a compact "approximately this much, this direction" summary. Must
run *before* full recording mode (step 8) - the far end of the chain
needs to be in a chunk that isn't otherwise being recorded, which full
recording mode would defeat. This is why steps 3-7 all come before full
recording gets turned on, even though "turn full recording on as early
as possible" is otherwise the goal from here down: under full recording,
`storage.active_zones` never gets populated (see `CombatZones.
activate_full_recording_chunk`), so `ItemChains.tick()`/`Logistics.tick()`/
the fluid-chain walk below would find nothing to walk from and these
five steps would produce nothing to check.

```
/c local surface = game.player.surface; local base = game.player.position; local far_belt; for i = 0, 35 do far_belt = surface.create_entity{name = "transport-belt", position = {base.x + i, base.y + 20}, direction = defines.direction.east, force = "player"} or far_belt end; far_belt.get_transport_line(1).insert_at_back{name = "iron-plate", count = 5}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y + 20}, force = "enemy"}; b.die()
```
Wait until the cyan outline disappears.

## 4. Distant chest via an inserter chain

Tests: the same rollup mechanism, reached by following an inserter's
`drop_target` to a chest instead of belt-to-belt. The inserter sits one
tile inside its chunk's edge and drops across the boundary, so the chest
lands in a chunk that was never itself active.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor(base.y / 32) * 32; local ins = surface.create_entity{name = "inserter", position = {ccx + 31, ccy + 16}, direction = defines.direction.east, force = "player"}; local chest = surface.create_entity{name = "iron-chest", position = {ccx + 32, ccy + 16}, force = "player"}; chest.get_inventory(defines.inventory.chest).insert{name = "copper-plate", count = 30}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait until the cyan outline disappears.

## 5. Inserter-to-chest servicing under ambiguity

Tests: `servicing_inserters`' search-radius heuristic (candidate chests
within a configurable radius of a servicing inserter, narrowed down to an
exact match via `pickup_target`/`drop_target` identity) doesn't
misattribute a nearby chest actually served by a *different* inserter.
Two independent inserter+chest pairs, placed within each other's default
3-tile search radius so each is a real candidate for the other's chest,
not just an easy isolated case. Also includes a third, self-fueled
`burner-inserter` actually carrying an item between two chests - none of
this checklist's other scripted inserters ever have a real item source
behind them to pick up from, so without this, `inventory_delta` with
`owner_kind = inserter_hand` is never exercised anywhere. Anchored 1
chunk (32 tiles) from the player via `ccx`/`ccy` - close enough that the
cyan outline is easy to see, and well within the widened combat radius
from step 1.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor((base.y + 32) / 32) * 32; local ins_a = surface.create_entity{name = "inserter", position = {ccx + 10, ccy + 10}, direction = defines.direction.east, force = "player"}; local chest_a = surface.create_entity{name = "iron-chest", position = {ccx + 11, ccy + 10}, force = "player"}; chest_a.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 40}; local ins_b = surface.create_entity{name = "inserter", position = {ccx + 10, ccy + 12}, direction = defines.direction.south, force = "player"}; local chest_b = surface.create_entity{name = "iron-chest", position = {ccx + 10, ccy + 13}, force = "player"}; chest_b.get_inventory(defines.inventory.chest).insert{name = "copper-plate", count = 40}; local src = surface.create_entity{name = "iron-chest", position = {ccx + 18, ccy + 10}, force = "player"}; src.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 20}; local dst = surface.create_entity{name = "iron-chest", position = {ccx + 16, ccy + 10}, force = "player"}; local feeder = surface.create_entity{name = "burner-inserter", position = {ccx + 17, ccy + 10}, direction = defines.direction.east, force = "player"}; feeder.insert{name = "coal", count = 2}; local b = surface.create_entity{name = "small-biter", position = {ccx + 10, ccy + 9}, force = "enemy"}; b.die()
```
Wait until the cyan outline disappears - a freshly placed burner-inserter
needs to ignite its fuel and complete a swing first, which the zone's
normal timeout comfortably covers.

## 6. Distant logistics network (roboport)

Tests: a roboport network reachable from a zone's chunk but not
physically standing in it - the one-time network roster plus ongoing
content sampling for providers/requesters. Anchored 1 chunk (32 tiles)
from the player, same reasoning as step 5.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor((base.y - 32) / 32) * 32; local rp = surface.create_entity{name = "roboport", position = {ccx + 31, ccy + 16}, force = "player"}; rp.insert{name = "construction-robot", count = 2}; local provider = surface.create_entity{name = "passive-provider-chest", position = {ccx + 34, ccy + 16}, force = "player"}; provider.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 20}; local requester = surface.create_entity{name = "requester-chest", position = {ccx + 37, ccy + 16}, force = "player"}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait until the cyan outline disappears.

## 7. Distant fluid chain

Tests: fluid segments have no near/far split - `get_fluid_segment_contents`
reads a whole connected segment in one call however far it physically
runs, even while cropped. The storage tank is a 3x3 building whose fluid
ports sit only on its corner tiles, not its center row, so it's placed
one tile off the pipe run's y-coordinate - lining a corner port up with
the pipe instead of the tank's unconnected center. Anchored 1 chunk (32
tiles) from the player via `ccx`/`ccy`, same reasoning as steps 5-6.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor((base.y - 32) / 32) * 32; local pipe; for i = 0, 35 do pipe = surface.create_entity{name = "pipe", position = {ccx + i, ccy + 16}, force = "player"} or pipe end; local tank = surface.create_entity{name = "storage-tank", position = {ccx - 2, ccy + 15}, force = "player"}; tank.insert_fluid{name = "water", amount = 300}; local b = surface.create_entity{name = "small-biter", position = {ccx, ccy + 15}, force = "enemy"}; b.die()
```
Wait until the cyan outline disappears.

## 8. Full recording mode

Tests: every chunk gets recorded regardless of nearby combat. Turned on
here - as early as it can be without breaking steps 3-7 above (see step
3's note) - so everything from here down runs under full recording,
matching how you'd actually use this mode in practice.

```
/c settings.global["rrec-full-recording-mode"] = {value = true}
```

## 9. Ground items

Tests: a dropped item stack being tracked (`ground_item_created`, ongoing
`inventory_delta` with `owner_kind = ground_item`), and its removal
(`ground_item_removed`) via two different causes. Placed here (simplest
event this checklist produces) rather than needing its own zone-opening
kill, since full recording mode already covers the whole surface from
step 8 on.

```
/c game.player.insert{name = "iron-plate", count = 10}
```
**Action:** Open your inventory, pick up the iron-plate stack (click it
so it's on your cursor), then press **Z** several times to drop the
plates on the ground in front of you, then close your inventory. Confirm
you actually see the plates land before continuing - this is the one
step driven entirely by a manual UI action, not a script. A ground item
is always exactly one unit (dropping a stack scatters it into that many
separate single-item piles, never one multi-count pile), so you should
see one pile per plate, not a single stack icon.

**Action:** Walk over (or hover and press **F** on) a few of the piles to
pick them up by hand - confirms `ground_item_removed` fires for a manual
pickup, not just the scripted `destroy()` below, both routing through the
same `register_on_object_destroyed` mechanism.

```
/c local items = game.player.surface.find_entities_filtered{type = "item-entity", position = game.player.position, radius = 10}; for _, i in ipairs(items) do i.destroy() end
```
Removes whichever piles you didn't already pick up by hand.

## 10. Robot cargo

Tests: a bot's carried inventory being tracked.

```
/c local bot = game.player.surface.create_entity{name = "logistic-robot", position = game.player.position, force = "player"}; bot.get_inventory(defines.inventory.robot_cargo).insert{name = "iron-plate", count = 5}
```

## 11. Fluids

Tests: a fluid entity's contents being tracked, deliberately as simple as
possible. Worth having alongside step 7's more complex version precisely
because it's simple - if step 7 ever fails, this tells you immediately
whether the fluid API itself broke or just the distant-chain logic on
top of it. Sits here rather than earlier only because full recording mode
already covers it without needing its own zone-opening kill.

```
/c local tank = game.player.surface.create_entity{name = "storage-tank", position = {game.player.position.x - 3, game.player.position.y}, force = "player"}; tank.insert_fluid{name = "water", amount = 500}
```

## 12. Turrets: damage, kills, and destruction

Tests: turret-dealt `damage_event`/`death_event`, a turret itself being
destroyed, and fire creation/fade-out (`effect_created`/`effect_expired`)
from the flamethrower's flame patch. Fully scripted, no action required -
turrets and their one-hit-point targets are placed away from the player
so nothing blocks your movement, and each turret only ever fights its own
target. `ft_target` is fully boxed in on all four sides 10 tiles from the
flamethrower turret - the box only blocks the biter's own movement, not
the flame itself, so it can't wander out of the stream's range before
taking a hit. This biter exists purely to take flame damage and die -
turret-taking-damage variety already comes from the 1-health `doomed`
turret below.

```
/c local p = game.player.position; local surface = game.player.surface; local gt = surface.create_entity{name="gun-turret", position={p.x + 10, p.y}, force="player"}; gt.get_inventory(defines.inventory.turret_ammo).insert{name="firearm-magazine", count=10}; local gt_target = surface.create_entity{name="small-biter", position={p.x + 16, p.y}, force="enemy"}; gt_target.health = 1; local ft = surface.create_entity{name="flamethrower-turret", position={p.x + 50, p.y}, force="player"}; ft.insert_fluid{name="crude-oil", amount=100}; local ft_target = surface.create_entity{name="small-biter", position={p.x + 50, p.y - 10}, force="enemy"}; ft_target.health = 1; for dx = -1, 1 do for dy = -1, 1 do if math.max(math.abs(dx), math.abs(dy)) == 1 then surface.create_entity{name = "stone-wall", position = {p.x + 50 + dx, p.y - 10 + dy}, force = "player"} end end end; local doomed = surface.create_entity{name="gun-turret", position={p.x + 90, p.y}, force="player"}; doomed.health = 1; surface.create_entity{name="behemoth-biter", position={p.x + 94, p.y}, force="enemy"}
```
Wait ~10 seconds for the kills/destruction, then ~10 more for the flame
patch to fade.

**Cleanup:** clear the behemoth-biter and your own turrets:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end; for _, e in ipairs(game.player.surface.find_entities_filtered{force = "player", type = {"ammo-turret", "electric-turret", "fluid-turret"}}) do e.destroy() end
```

## 13. Vehicle destruction

Tests: a vehicle being damaged and destroyed, and (via a plain parked
car alongside it) vehicle-type diversity for the checklist as a whole.
Fully scripted, no action required.

```
/c local p = game.player.position; local surface = game.player.surface; local weak_tank = surface.create_entity{name="tank", position={p.x + 40, p.y - 40}, force="player"}; weak_tank.health = 1; surface.create_entity{name="behemoth-biter", position={p.x + 42, p.y - 40}, force="enemy"}; surface.create_entity{name="car", position={p.x + 46, p.y - 40}, force="player"}
```
Wait ~5 seconds.

**Cleanup:** clear the biter:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 14. Kill classification: worm, spawner, and spitter acid

Tests: `hostile_kind` classification for worm turrets and spawners
(biter classification is exercised elsewhere), plus real acid damage and
the resulting fire/acid patches from both a worm and a spitter. Combined
into one step so both acid streams are live at once - the automated check
looks for two distinct acid sources fading, not just that some fire-typed
effect existed at all. All three are 1 HP, same as everywhere else in
this checklist - confirmed by real playtesting that even a 1-HP worm/
spitter still gets its acid attack off before dying (you're the only
damage source in this step, so there's no race against anything else
that would make higher health necessary). The spitter is positioned to
the left with the other two rather than off on its own.

```
/c local p = game.player.position; local surface = game.player.surface; local spawner = surface.create_entity{name="biter-spawner", position={p.x - 40, p.y}, force="enemy"}; spawner.health = 1; local worm = surface.create_entity{name="medium-worm-turret", position={p.x - 46, p.y}, force="enemy"}; worm.health = 1; local spitter = surface.create_entity{name="small-spitter", position={p.x - 12, p.y}, force="enemy"}; spitter.health = 1
```
**Action:** Approach the worm turret and let it land its acid attack on
you before your own hit kills it - it's 1 HP, so any hit ends it, meaning
you have to let it fire first rather than closing in and one-shotting it
on sight. Then do the same with the spitter. You need damage from **both**
acid types before either attacker dies, or the acid-diversity check below
has nothing to compare. Once you've taken both hits, kill the spawner,
worm, and spitter (any order). Wait ~20 seconds after the last kill for
both acid patches to fully fade.

## 15. Walls and gates: damage and destruction

Tests: `damage_event`/`death_event` for walls and gates specifically, not
just turrets. Biters generally ignore a bare wall/gate with nothing
behind it, so each one here has a turret boxed in behind it - but turrets
are a 2x2 footprint and walls/gates are 1x1, so a single wall tile on
each side leaves gaps at the corners a biter can slip through without
ever touching the wall. Each turret sits inside a full ring at radius 2
(5x5, one tile deep), every tile 1 HP so the test doesn't depend on the
biter picking exactly one intended tile first. The first ring is entirely
stone-wall; the second is entirely gate - not one gated tile in an
otherwise-wall ring, which let a biter that didn't happen to target that
one tile chew through a wall instead and pass the check for the wrong
reason. The two setups are far apart so the two biters can't wander over
and help each other instead of attacking their own turret. The boxed-in
turrets are deliberately left unarmed (bait, not meant to fight back), so
both attacking biters are expected to survive. Fully scripted, no action
required.

```
/c local p = game.player.position; local surface = game.player.surface; local function ring(cx, cy, turret_name, ring_name) local turret = surface.create_entity{name = turret_name, position = {cx, cy}, force = "player"}; for dx = -2, 2 do for dy = -2, 2 do if math.max(math.abs(dx), math.abs(dy)) == 2 then surface.create_entity{name = ring_name, position = {cx + dx, cy + dy}, force = "player"}.health = 1 end end end; return turret end; ring(p.x - 60, p.y + 40, "gun-turret", "stone-wall"); surface.create_entity{name = "small-biter", position = {p.x - 60, p.y + 36}, force = "enemy"}; ring(p.x - 60, p.y - 40, "gun-turret", "gate"); surface.create_entity{name = "small-biter", position = {p.x - 60, p.y - 44}, force = "enemy"}
```
Wait ~10 seconds.

**Cleanup:** clear both biters:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 16. Vehicle combat: shooting vs. running over

Tests: vehicle fuel/ammo/trunk inventory tracking, and a vehicle
damaging/killing an enemy via both its weapon and physically running one
over - two separate targets, one on each side, so both are confirmed
independently and you know which is which, and the automated check looks
for both kinds of damage credit (a fired-projectile hit vs. a bare
collision) rather than just one or the other. The tank spawns already
fueled and loaded with cannon shells - no separate firearm-magazine
ammo, since the cannon alone is enough to exercise both credit paths.
(`car` diversity coverage already comes from step 13 - no need to place
one here too.)

```
/c local p = game.player.position; local surface = game.player.surface; local tank = surface.create_entity{name="tank", position={p.x, p.y + 3}, force=game.player.force}; tank.insert{name="solid-fuel", count=20}; tank.insert{name="cannon-shell", count=10}; local shoot_target = surface.create_entity{name="small-biter", position={p.x - 10, p.y + 5}, force="enemy"}; shoot_target.health = 1; local run_over_target = surface.create_entity{name="small-biter", position={p.x + 10, p.y + 5}, force="enemy"}; run_over_target.health = 1
```
**Action:** Get in the tank (walk up to it and press **Enter**). From
inside, shoot the biter on your **left/west** (`shoot_target`) with the
cannon, then drive the tank directly over the biter on your **right/east**
(`run_over_target`). Both credits (a
fired-projectile hit and a bare collision) are required for the check
below to pass.

## 17. Spidertron autopilot

Tests: an unmanned, autopilot-driven spidertron still counts as
player-controlled. Fully scripted, no action required.

```
/c local p = game.player.position; local surface = game.player.surface; local st = surface.create_entity{name="spidertron", position={p.x + 2, p.y}, force = game.player.force}; st.insert{name="rocket", count=20}; local target = surface.create_entity{name="small-biter", position={p.x + 30, p.y}, force="enemy"}; target.health = 1; st.autopilot_destination = {target.position.x, target.position.y}
```
Wait ~5 seconds.

**Cleanup:** clear the spidertron:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{type = "spider-vehicle", force = "player"}) do e.destroy() end; for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 18. Player death, respawn, and corpse lifecycle

Tests: corpse provenance (`corpse_created`), its contents changing while
it exists (`inventory_delta` with `owner_kind = corpse`, a partial change
first), and removal (`corpse_expired`).

```
/c game.player.insert{name="iron-plate", count=20}; game.player.insert{name="firearm-magazine", count=10}; game.player.character.health = 5; game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 1, game.player.position.y}, force="enemy"}
```
**Cleanup:** clear the biter:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

**Action:** Let the biter kill you, then click Respawn. Wait ~2 seconds.
```
/c local c = game.player.surface.find_entities_filtered{type = "character-corpse"}[1]; if c then c.get_inventory(defines.inventory.character_corpse).remove{name = "iron-plate", count = 5} end
```
Wait a moment - just long enough for the partial removal to get scanned
as its own `inventory_delta` before the next command clears the rest.
```
/c local c = game.player.surface.find_entities_filtered{type = "character-corpse"}[1]; if c then c.get_inventory(defines.inventory.character_corpse).clear() end
```

## 19. Unit group formation

Tests: biters forming up into a group is recorded as `unit_group_created`.

```
/c local g = game.player.surface.create_unit_group{position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u1 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u2 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 11, game.player.position.y}, force = "enemy"}; g.add_member(u1); g.add_member(u2)
```

**Cleanup:** clear the group:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 20. Full recording mode off + reload regression

Tests: turning full recording back off doesn't leave anything stuck
recording forever, and the mod survives a reload without losing state.

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

For a broader look at what got recorded (battlefield count/duration,
scoreboard, sample payloads per event type):
```
python3 tools/inspect_replay.py
```
Both default to the standard Factorio `script-output` location for your
OS; pass `--path` if that's wrong for your setup.

If you turned on diagnostics in step 1, it was written to Factorio's own
log file, not `replay.json`:
* **Windows:** `%APPDATA%\Factorio\factorio-current.log`
* **macOS:** `~/Library/Application Support/factorio/factorio-current.log`
* **Linux:** `~/.factorio/factorio-current.log`

Summarize it with:
```
python3 tools/inspect_logs.py
```
