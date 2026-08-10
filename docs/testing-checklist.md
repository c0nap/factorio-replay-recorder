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
actually do something say **Action:** explicitly.

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
active zones). Diagnostics write to Factorio's own log file, not
`replay.json`:
* **Windows:** `%APPDATA%\Factorio\factorio-current.log`
* **macOS:** `~/Library/Application Support/factorio/factorio-current.log`
* **Linux:** `~/.factorio/factorio-current.log`

Summarize it with `python3 tools/inspect_logs.py` after you're done.

## 2. Long-chain rollup via belts (`item_distribution`)

Tests: a belt chain running far past a zone's own chunk gets rolled up
into a compact "approximately this much, this direction" summary. Must
run *before* full recording mode - the far end of the chain needs to be
in a chunk that isn't otherwise being recorded, which full recording
mode would defeat.

```
/c local surface = game.player.surface; local base = game.player.position; local far_belt; for i = 0, 35 do far_belt = surface.create_entity{name = "transport-belt", position = {base.x + i, base.y + 20}, direction = defines.direction.east, force = "player"} or far_belt end; far_belt.get_transport_line(1).insert_at_back{name = "iron-plate", count = 5}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y + 20}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 3. Distant chest via an inserter chain

Tests: the same rollup mechanism, reached by following an inserter's
`drop_target` to a chest instead of belt-to-belt. The inserter sits one
tile inside its chunk's edge and drops across the boundary, so the chest
lands in a chunk that was never itself active.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor(base.y / 32) * 32; local ins = surface.create_entity{name = "inserter", position = {ccx + 31, ccy + 16}, direction = defines.direction.east, force = "player"}; local chest = surface.create_entity{name = "iron-chest", position = {ccx + 32, ccy + 16}, force = "player"}; chest.get_inventory(defines.inventory.chest).insert{name = "copper-plate", count = 30}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 4. Distant logistics network (roboport)

Tests: a roboport network reachable from a zone's chunk but not
physically standing in it - the one-time network roster plus ongoing
content sampling for providers/requesters.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor((base.y - 96) / 32) * 32; local rp = surface.create_entity{name = "roboport", position = {ccx + 31, ccy + 16}, force = "player"}; rp.insert{name = "construction-robot", count = 2}; local provider = surface.create_entity{name = "passive-provider-chest", position = {ccx + 34, ccy + 16}, force = "player"}; provider.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 20}; local requester = surface.create_entity{name = "requester-chest", position = {ccx + 37, ccy + 16}, force = "player"}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait a couple of seconds. If the provider chest doesn't show up in the
network roster, move the chests closer to the roboport and re-run.

## 5. Distant fluid chain

Tests: fluid segments have no near/far split - `get_fluid_segment_fluid`
reads a whole connected segment in one call however far it physically
runs, even while cropped.

```
/c local surface = game.player.surface; local base = game.player.position; local pipe; for i = 0, 35 do pipe = surface.create_entity{name = "pipe", position = {base.x + i, base.y - 60}, force = "player"} or pipe end; local tank = surface.create_entity{name = "storage-tank", position = {base.x - 2, base.y - 60}, force = "player"}; tank.insert_fluid{name = "water", amount = 300}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y - 61}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 6. Full recording mode

Tests: every chunk gets recorded regardless of nearby combat.

```
/c settings.global["rrec-full-recording-mode"] = {value = true}
```

## 7. Turrets: damage, kills, and destruction

Tests: turret-dealt `damage_event`/`death_event`, a turret itself being
destroyed, and fire creation/fade-out (`effect_created`/`effect_expired`)
from the flamethrower's flame patch. Fully scripted, no action required -
turrets and their one-hit-point targets are placed away from the player
so nothing blocks your movement, and each turret only ever fights its own
target.

```
/c local p = game.player.position; local surface = game.player.surface; local gt = surface.create_entity{name="gun-turret", position={p.x + 10, p.y}, force="player"}; gt.get_inventory(defines.inventory.turret_ammo).insert{name="firearm-magazine", count=10}; local gt_target = surface.create_entity{name="small-biter", position={p.x + 16, p.y}, force="enemy"}; gt_target.health = 1; local ft = surface.create_entity{name="flamethrower-turret", position={p.x + 50, p.y}, force="player"}; ft.insert_fluid{name="crude-oil", amount=100}; local ft_target = surface.create_entity{name="small-biter", position={p.x + 56, p.y}, force="enemy"}; ft_target.health = 1; local doomed = surface.create_entity{name="gun-turret", position={p.x + 90, p.y}, force="player"}; doomed.health = 1; surface.create_entity{name="behemoth-biter", position={p.x + 94, p.y}, force="enemy"}
```
Wait ~10 seconds for the kills/destruction, then ~10 more for the flame
patch to fade.

Laser turrets need electricity to fire, which this scripted setup doesn't
wire up - the gun and flamethrower turrets above are ammo/fluid-powered
so they don't need it. Not required for this checklist.

## 8. Vehicle destruction

Tests: a vehicle being damaged and destroyed. Fully scripted, no action
required.

```
/c local p = game.player.position; local surface = game.player.surface; local weak_tank = surface.create_entity{name="tank", position={p.x + 130, p.y}, force="player"}; weak_tank.health = 1; surface.create_entity{name="small-biter", position={p.x + 132, p.y}, force="enemy"}
```
Wait ~5 seconds.

## 9. Kill classification: worm and spawner

Tests: `hostile_kind` classification for worm turrets and spawners
(biter/spitter classification is exercised elsewhere).

```
/c local p = game.player.position; local surface = game.player.surface; local spawner = surface.create_entity{name="biter-spawner", position={p.x - 40, p.y}, force="enemy"}; spawner.health = 1; local worm = surface.create_entity{name="medium-worm-turret", position={p.x - 46, p.y}, force="enemy"}; worm.health = 1
```
**Action:** Land one hit each - both are isolated, nothing else nearby to
accidentally kill.

## 10. Walls and gates: damage and destruction

Tests: `damage_event`/`death_event` for walls and gates specifically, not
just turrets. Fully scripted, no action required.

```
/c local p = game.player.position; local surface = game.player.surface; local wall = surface.create_entity{name="stone-wall", position={p.x + 160, p.y}, force="player"}; wall.health = 1; local gate = surface.create_entity{name="gate", position={p.x + 162, p.y}, force="player"}; gate.health = 1; surface.create_entity{name="small-biter", position={p.x + 161, p.y + 2}, force="enemy"}
```
Wait ~10 seconds.

## 11. Spitter acid (isolated fight)

Tests: acid damage and the resulting fire/acid patch, from a real fight.

```
/c local p = game.player.position; game.player.surface.create_entity{name="small-spitter", position={p.x + 12, p.y}, force="enemy"}
```
**Action:** Walk over and fight it normally - let it get a couple of acid
hits in on you before it dies. Wait ~10 seconds afterward for the acid
patch to fade.

## 12. Vehicle combat: shooting vs. running over

Tests: vehicle fuel/ammo/trunk inventory tracking, and a vehicle
damaging/killing an enemy via both its weapon and physically running one
over - two separate targets so both are confirmed independently.

```
/c local surface = game.player.surface; game.player.insert{name="car", count=1}; game.player.insert{name="tank", count=1}; game.player.insert{name="solid-fuel", count=20}; game.player.insert{name="firearm-magazine", count=40}; game.player.insert{name="cannon-shell", count=10}
```
**Action:** Place the car nearby (just needs to exist). Place the tank,
fuel it, and load its ammo - the tank is what you'll drive next.
```
/c local p = game.player.position; local surface = game.player.surface; local shoot_target = surface.create_entity{name="small-biter", position={p.x + 10, p.y + 5}, force="enemy"}; shoot_target.health = 1; local run_over_target = surface.create_entity{name="small-biter", position={p.x + 15, p.y + 5}, force="enemy"}; run_over_target.health = 1
```
**Action:** From the tank, shoot `shoot_target`, then drive over
`run_over_target`.

## 13. Spidertron autopilot

Tests: an unmanned, autopilot-driven spidertron still counts as
player-controlled. Fully scripted, no action required.

```
/c local p = game.player.position; local surface = game.player.surface; local st = surface.create_entity{name="spidertron", position={p.x + 2, p.y}, force = game.player.force}; st.insert{name="rocket", count=20}; local target = surface.create_entity{name="small-biter", position={p.x + 30, p.y}, force="enemy"}; target.health = 1; st.autopilot_destination = {target.position.x, target.position.y}
```
Wait ~5 seconds.

## 14. Player death, respawn, and corpse lifecycle

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

## 15. Ground items

Tests: a dropped item stack being tracked (`ground_item_created`, ongoing
`inventory_delta` with `owner_kind = ground_item`), and its removal
(`ground_item_removed`).

```
/c game.player.insert{name="iron-plate", count=10}
```
**Action:** Open your inventory, pick up the iron-plate stack (click it
so it's on your cursor), then press **Z** once or twice to drop a couple
of plates on the ground in front of you, then close your inventory.
```
/c local items = game.player.surface.find_entities_filtered{type = "item-entity", position = game.player.position, radius = 10}; for _, i in ipairs(items) do i.destroy() end
```

## 16. Fluids

Tests: a fluid-holding entity appearing and its contents being tracked.

```
/c local tank = game.player.surface.create_entity{name = "storage-tank", position = {game.player.position.x - 3, game.player.position.y}, force = "player"}; tank.insert_fluid{name = "water", amount = 500}
```

## 17. Robot cargo

Tests: a bot's carried inventory being tracked.

```
/c local bot = game.player.surface.create_entity{name = "logistic-robot", position = game.player.position, force = "player"}; bot.get_inventory(defines.inventory.robot_cargo).insert{name = "iron-plate", count = 5}
```

## 18. Unit group formation

Tests: biters forming up into a group is recorded as `unit_group_created`.

```
/c local g = game.player.surface.create_unit_group{position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u1 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u2 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 11, game.player.position.y}, force = "enemy"}; g.add_member(u1); g.add_member(u2)
```

## 19. Full recording mode off + reload regression

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

If you turned on diagnostics in step 1:
```
python3 tools/inspect_logs.py
```

---

## Not covered by this checklist (future work)

Noted rather than silently skipped:

* **Landmines** - not confirmed whether this mod tracks them at all
  (damage attribution, or even placement).
* **Flame damage attribution** - step 7 confirms a fire patch is created
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
  are ammo/fluid-powered so they're unaffected, and steps 3/4 (the
  distant inserter and roboport tests) only depend on static
  position/target-resolution properties rather than anything requiring
  power to be flowing - but it's unconfirmed whether that holds for
  everything else these unpowered entities are asked to do here.
