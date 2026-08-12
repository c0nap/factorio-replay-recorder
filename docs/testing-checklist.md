# Manual In-Game Test Checklist

Generates a `replay.json` that exercises every event type the mod can
produce, then hands off to two scripts that check it for you - you should
not need to read raw JSON to know whether something worked.

This is a throwaway test save - don't run it against your real base.
Console commands (`/c ...`) permanently disable achievements for a save
the moment you use one; that's expected and harmless here.

Most kills/damage/destruction below are scripted with weak/one-hit
targets placed apart from each other, so you're not fighting to land a
hit on one thing without also killing another. Steps that need you to
actually do something say **Action:** explicitly. Steps marked
**Cleanup:** leave a hostile alive on purpose (it has no reason to die on
its own) - clear it before moving on so it doesn't wander into a later
test.

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
Type this one twice - Factorio's misfire guard on the first console
command of a session.
```
/c game.player.force.research_all_technologies(); game.speed=3; settings.global["rrec-distant-sample-interval-seconds"] = {value = 1}; settings.global["rrec-chain-near-hops"] = {value = 1}; settings.global["rrec-chain-max-hops"] = {value = 50}; settings.global["rrec-diagnostics-enabled"] = {value = true}; settings.global["rrec-battlefield-marker-enabled"] = {value = true}
```
Turns on diagnostics and the battlefield marker (cyan outline around
active zones). See "After you're done" below for where the diagnostics
data ends up and how to read it.

## 2. Ground items

Tests: a dropped item stack being tracked (`ground_item_created`, ongoing
`inventory_delta` with `owner_kind = ground_item`), and its removal
(`ground_item_removed`). Placed first since it's the simplest event this
checklist produces - a plain item sitting on the ground - and everything
after it builds on more complex tracking (belts, inserter chains).

```
/c local b = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 1, game.player.position.y}, force = "enemy"}; b.die(); game.player.insert{name = "iron-plate", count = 10}
```
The scripted biter kill just opens a recording zone at your position -
nothing to clean up from it.

**Action:** Open your inventory, pick up the iron-plate stack (click it
so it's on your cursor), then press **Z** once or twice to drop a couple
of plates on the ground in front of you, then close your inventory.
Confirm you actually see the plates land before continuing - this is the
one step driven entirely by a manual UI action, not a script.
```
/c local items = game.player.surface.find_entities_filtered{type = "item-entity", position = game.player.position, radius = 10}; for _, i in ipairs(items) do i.destroy() end
```

## 3. Long-chain rollup via belts (`item_distribution`)

Tests: a belt chain running far past a zone's own chunk gets rolled up
into a compact "approximately this much, this direction" summary. Must
run *before* full recording mode - the far end of the chain needs to be
in a chunk that isn't otherwise being recorded, which full recording
mode would defeat.

```
/c local surface = game.player.surface; local base = game.player.position; local far_belt; for i = 0, 35 do far_belt = surface.create_entity{name = "transport-belt", position = {base.x + i, base.y + 20}, direction = defines.direction.east, force = "player"} or far_belt end; far_belt.get_transport_line(1).insert_at_back{name = "iron-plate", count = 5}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y + 20}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 4. Distant chest via an inserter chain

Tests: the same rollup mechanism, reached by following an inserter's
`drop_target` to a chest instead of belt-to-belt. The inserter sits one
tile inside its chunk's edge and drops across the boundary, so the chest
lands in a chunk that was never itself active.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor(base.y / 32) * 32; local ins = surface.create_entity{name = "inserter", position = {ccx + 31, ccy + 16}, direction = defines.direction.east, force = "player"}; local chest = surface.create_entity{name = "iron-chest", position = {ccx + 32, ccy + 16}, force = "player"}; chest.get_inventory(defines.inventory.chest).insert{name = "copper-plate", count = 30}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

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
`owner_kind = inserter_hand` is never exercised anywhere.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor((base.y + 96) / 32) * 32; local ins_a = surface.create_entity{name = "inserter", position = {ccx + 10, ccy + 10}, direction = defines.direction.east, force = "player"}; local chest_a = surface.create_entity{name = "iron-chest", position = {ccx + 11, ccy + 10}, force = "player"}; chest_a.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 40}; local ins_b = surface.create_entity{name = "inserter", position = {ccx + 10, ccy + 12}, direction = defines.direction.south, force = "player"}; local chest_b = surface.create_entity{name = "iron-chest", position = {ccx + 10, ccy + 13}, force = "player"}; chest_b.get_inventory(defines.inventory.chest).insert{name = "copper-plate", count = 40}; local src = surface.create_entity{name = "iron-chest", position = {ccx + 16, ccy + 10}, force = "player"}; src.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 20}; local dst = surface.create_entity{name = "iron-chest", position = {ccx + 18, ccy + 10}, force = "player"}; local feeder = surface.create_entity{name = "burner-inserter", position = {ccx + 17, ccy + 10}, direction = defines.direction.east, force = "player"}; feeder.insert{name = "coal", count = 2}; local b = surface.create_entity{name = "small-biter", position = {ccx + 10, ccy + 9}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 6. Robot cargo

Tests: a bot's carried inventory being tracked. Placed before the
roboport network test below since it's the simpler of the two - a single
bot's inventory, no network roster involved.

```
/c local b = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 1, game.player.position.y}, force = "enemy"}; b.die(); local bot = game.player.surface.create_entity{name = "logistic-robot", position = game.player.position, force = "player"}; bot.get_inventory(defines.inventory.robot_cargo).insert{name = "iron-plate", count = 5}
```

## 7. Distant logistics network (roboport)

Tests: a roboport network reachable from a zone's chunk but not
physically standing in it - the one-time network roster plus ongoing
content sampling for providers/requesters.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor((base.y - 96) / 32) * 32; local rp = surface.create_entity{name = "roboport", position = {ccx + 31, ccy + 16}, force = "player"}; rp.insert{name = "construction-robot", count = 2}; local provider = surface.create_entity{name = "passive-provider-chest", position = {ccx + 34, ccy + 16}, force = "player"}; provider.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 20}; local requester = surface.create_entity{name = "requester-chest", position = {ccx + 37, ccy + 16}, force = "player"}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 8. Fluids

Tests: a fluid-holding entity appearing and its contents being tracked.
Placed before the distant fluid chain below since it's the simpler of
the two - one tank, right next to you, no piped segment to traverse.

```
/c local b = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 1, game.player.position.y}, force = "enemy"}; b.die(); local tank = game.player.surface.create_entity{name = "storage-tank", position = {game.player.position.x - 3, game.player.position.y}, force = "player"}; tank.insert_fluid{name = "water", amount = 500}
```

## 9. Distant fluid chain

Tests: fluid segments have no near/far split - `get_fluid_segment_contents`
reads a whole connected segment in one call however far it physically
runs, even while cropped. (Note: as of PR #13 this is an attempted 2.0
API shape, not yet confirmed against real data - see fluid_chains.lua's
file header.)

```
/c local surface = game.player.surface; local base = game.player.position; local pipe; for i = 0, 35 do pipe = surface.create_entity{name = "pipe", position = {base.x + i, base.y - 60}, force = "player"} or pipe end; local tank = surface.create_entity{name = "storage-tank", position = {base.x - 2, base.y - 60}, force = "player"}; tank.insert_fluid{name = "water", amount = 300}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y - 61}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 10. Full recording mode

Tests: every chunk gets recorded regardless of nearby combat.

```
/c settings.global["rrec-full-recording-mode"] = {value = true}
```

## 11. Turrets: damage, kills, and destruction

Tests: turret-dealt `damage_event`/`death_event`, a turret itself being
destroyed, and fire creation/fade-out (`effect_created`/`effect_expired`)
from the flamethrower's flame patch. Fully scripted, no action required -
turrets and their one-hit-point targets are placed away from the player
so nothing blocks your movement, and each turret only ever fights its own
target.

```
/c local p = game.player.position; local surface = game.player.surface; local gt = surface.create_entity{name="gun-turret", position={p.x + 10, p.y}, force="player"}; gt.get_inventory(defines.inventory.turret_ammo).insert{name="firearm-magazine", count=10}; local gt_target = surface.create_entity{name="small-biter", position={p.x + 16, p.y}, force="enemy"}; gt_target.health = 1; local ft = surface.create_entity{name="flamethrower-turret", position={p.x + 50, p.y}, force="player"}; ft.insert_fluid{name="crude-oil", amount=100}; local ft_target = surface.create_entity{name="small-biter", position={p.x + 50, p.y - 10}, force="enemy"}; ft_target.health = 1; local doomed = surface.create_entity{name="gun-turret", position={p.x + 90, p.y}, force="player"}; doomed.health = 1; surface.create_entity{name="behemoth-biter", position={p.x + 94, p.y}, force="enemy"}
```
Wait ~10 seconds for the kills/destruction, then ~10 more for the flame
patch to fade.

**Cleanup:** the behemoth-biter has no reason to die once it's destroyed
the weak turret - clear it before it wanders into a later step:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 12. Vehicle destruction

Tests: a vehicle being damaged and destroyed, and (via a plain parked
car alongside it) vehicle-type diversity for the checklist as a whole.
Fully scripted, no action required.

```
/c local p = game.player.position; local surface = game.player.surface; local weak_tank = surface.create_entity{name="tank", position={p.x + 40, p.y - 40}, force="player"}; weak_tank.health = 1; surface.create_entity{name="small-biter", position={p.x + 42, p.y - 40}, force="enemy"}; surface.create_entity{name="car", position={p.x + 46, p.y - 40}, force="player"}
```
Wait ~5 seconds.

**Cleanup:** the biter survives after destroying the one-hit-point tank -
clear it:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 13. Kill classification: worm and spawner

Tests: `hostile_kind` classification for worm turrets and spawners
(biter/spitter classification is exercised elsewhere).

```
/c local p = game.player.position; local surface = game.player.surface; local spawner = surface.create_entity{name="biter-spawner", position={p.x - 40, p.y}, force="enemy"}; spawner.health = 1; local worm = surface.create_entity{name="medium-worm-turret", position={p.x - 46, p.y}, force="enemy"}; worm.health = 1
```
**Action:** Land one hit each - both are isolated, nothing else nearby to
accidentally kill.

## 14. Walls and gates: damage and destruction

Tests: `damage_event`/`death_event` for walls and gates specifically, not
just turrets. Biters generally ignore a bare wall/gate with nothing
behind it - each one here has a turret boxed in behind it (walls on the
other three sides) so the only way to it is through the wall/gate being
tested, giving the biter a real reason to attack it. The boxed-in turrets
are deliberately left unarmed (they're bait, not meant to fight back), so
both attacking biters are expected to survive. Fully scripted, no action
required.

```
/c local p = game.player.position; local surface = game.player.surface; local wx, wy = p.x - 60, p.y + 15; surface.create_entity{name="gun-turret", position={wx, wy}, force="player"}; surface.create_entity{name="stone-wall", position={wx - 1, wy}, force="player"}; surface.create_entity{name="stone-wall", position={wx + 1, wy}, force="player"}; surface.create_entity{name="stone-wall", position={wx, wy - 1}, force="player"}; local test_wall = surface.create_entity{name="stone-wall", position={wx, wy + 1}, force="player"}; test_wall.health = 1; surface.create_entity{name="small-biter", position={wx, wy + 3}, force="enemy"}; local gx, gy = p.x - 60, p.y - 15; surface.create_entity{name="gun-turret", position={gx, gy}, force="player"}; surface.create_entity{name="stone-wall", position={gx - 1, gy}, force="player"}; surface.create_entity{name="stone-wall", position={gx + 1, gy}, force="player"}; surface.create_entity{name="stone-wall", position={gx, gy - 1}, force="player"}; local test_gate = surface.create_entity{name="gate", position={gx, gy + 1}, force="player"}; test_gate.health = 1; surface.create_entity{name="small-biter", position={gx, gy + 3}, force="enemy"}
```
Wait ~10 seconds.

**Cleanup:** both biters are still alive (and may still be chewing on the
unarmed bait turrets) - clear them:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 15. Spitter acid (isolated fight)

Tests: acid damage and the resulting fire/acid patch, from a real fight.

```
/c local p = game.player.position; game.player.surface.create_entity{name="small-spitter", position={p.x + 12, p.y}, force="enemy"}
```
**Action:** Walk over and fight it normally - let it get a couple of acid
hits in on you before it dies. Wait ~10 seconds afterward for the acid
patch to fade.

## 16. Vehicle combat: shooting vs. running over

Tests: vehicle fuel/ammo/trunk inventory tracking, and a vehicle
damaging/killing an enemy via both its weapon and physically running one
over - two separate targets, one on each side, so both are confirmed
independently and you know which is which. (`car` diversity coverage
already comes from step 12 - no need to place one here too.)

```
/c local surface = game.player.surface; game.player.insert{name="tank", count=1}; game.player.insert{name="solid-fuel", count=20}; game.player.insert{name="firearm-magazine", count=40}; game.player.insert{name="cannon-shell", count=10}
```
**Action:** Place the tank, fuel it, and load its ammo.
```
/c local p = game.player.position; local surface = game.player.surface; local shoot_target = surface.create_entity{name="small-biter", position={p.x - 10, p.y + 5}, force="enemy"}; shoot_target.health = 1; local run_over_target = surface.create_entity{name="small-biter", position={p.x + 10, p.y + 5}, force="enemy"}; run_over_target.health = 1
```
**Action:** From the tank, shoot the biter on your **left/west**
(`shoot_target`), then drive over the biter on your **right/east**
(`run_over_target`).

## 17. Spidertron autopilot

Tests: an unmanned, autopilot-driven spidertron still counts as
player-controlled. Fully scripted, no action required.

```
/c local p = game.player.position; local surface = game.player.surface; local st = surface.create_entity{name="spidertron", position={p.x + 2, p.y}, force = game.player.force}; st.insert{name="rocket", count=20}; local target = surface.create_entity{name="small-biter", position={p.x + 30, p.y}, force="enemy"}; target.health = 1; st.autopilot_destination = {target.position.x, target.position.y}
```
Wait ~5 seconds.

## 18. Player death, respawn, and corpse lifecycle

Tests: corpse provenance (`corpse_created`), its contents changing while
it exists (`inventory_delta` with `owner_kind = corpse`, a partial change
first), and removal (`corpse_expired`).

```
/c game.player.insert{name="iron-plate", count=20}; game.player.insert{name="firearm-magazine", count=10}; game.player.character.health = 5; game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 1, game.player.position.y}, force="enemy"}
```
**Action:** Let the biter kill you, then click Respawn. Wait ~2 seconds.
```
/c local c = game.player.surface.find_entities_filtered{type = "character-corpse"}[1]; if c then c.get_inventory(defines.inventory.character_corpse).remove{name = "iron-plate", count = 5} end
```
Wait a couple of seconds.
```
/c local c = game.player.surface.find_entities_filtered{type = "character-corpse"}[1]; if c then c.get_inventory(defines.inventory.character_corpse).clear() end
```

**Cleanup:** the biter that killed you is still alive near your death
spot (you've respawned elsewhere, so it's out of sight, not gone) -
clear it:
```
/c for _, e in ipairs(game.player.surface.find_entities_filtered{force = "enemy"}) do e.destroy() end
```

## 19. Unit group formation

Tests: biters forming up into a group is recorded as `unit_group_created`.

```
/c local g = game.player.surface.create_unit_group{position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u1 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u2 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 11, game.player.position.y}, force = "enemy"}; g.add_member(u1); g.add_member(u2)
```

**Cleanup:** the group and its members just sit there gathering forever -
clear them:
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

---

## Not covered by this checklist (future work)

Noted rather than silently skipped:

* **Landmines** - not confirmed whether this mod tracks them at all
  (damage attribution, or even placement).
* **Flame damage attribution** - step 11 confirms a fire patch is created
  and later fades (`effect_created`/`effect_expired`), but not whether
  standing in it generates its own `damage_event`s against whoever's in
  it, the way a direct hit does, or whether fire damage bypasses that
  path entirely.
* **Capsules** - poison capsules, slowdown capsules, and defender/
  distractor/destroyer combat robots thrown by the player aren't exercised
  anywhere in this checklist; unconfirmed whether their effects/spawned
  units are tracked the way turret and unit-group activity are.
* **Terrain/obstacle completeness** - trees, rocks, cliffs, and plain
  ground/water tiles aren't currently distinguished as combat-relevant
  obstacles the way buildings are; neither are other non-combat buildings
  (assemblers, furnaces, etc.) beyond being generically dumped as
  `statics` if not filtered out. Their *contents* don't matter (they're
  obstacles, not storage), just their presence/position for pathing and
  chokepoint analysis.
* **Electricity** - laser turrets, (non-burner) inserters, pumps, and
  roboports all need a real electric network to actually operate, which
  this checklist doesn't wire up anywhere. Gun and flamethrower turrets
  are ammo/fluid-powered so they're unaffected, and steps 4/7 (the
  distant inserter and roboport tests) only depend on static
  position/target-resolution properties rather than anything requiring
  power to be flowing - but it's unconfirmed whether that holds for
  everything else these unpowered entities are asked to do here.
* **Laser turrets** - not exercised anywhere in this checklist (they need
  the electric network above to fire); unconfirmed whether their damage/
  destruction is tracked the same way gun/flamethrower turrets are.
* **Health regeneration** - neither the player's natural health
  regeneration nor biters' (both passive, no item/action involved)
  produce any event here; unconfirmed whether either is tracked at all,
  or how it'd be distinguished from healing-item/repair-pack effects if
  so.
* **Repairs** - repair packs (player-applied) and construction bots
  (automatic, for player-force structures) aren't exercised anywhere;
  unconfirmed whether a repaired entity's health increase is tracked as
  its own event or is indistinguishable from any other health change.
* **Status effects** - a player gooed/slowed by spitter acid, and a biter
  slowed by a thrown slowdown capsule, aren't exercised anywhere;
  unconfirmed whether either is tracked as a distinct event or state, as
  opposed to just the damage_event from the acid hit itself.
