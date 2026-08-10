# Manual In-Game Test Checklist

Generates a `replay.json` that exercises every event type the mod can
produce, then hands off to two scripts that check it for you - you should
not need to read raw JSON to know whether something worked.

This is a throwaway test save - don't run it against your real base.
Console commands (`/c ...`) permanently disable achievements for a save
the moment you use one; that's expected and harmless here.

**Time budget:** every step below is one console command plus at most a
few seconds of waiting. Most steps need no manual action at all - kills,
damage, and destruction are scripted (weak/one-hit targets, no precision
combat required) so you're not fighting to land a hit on one thing without
also killing another. The two exceptions that genuinely need you to play
are the isolated spitter fight (step 9) and driving a vehicle into an
enemy (step 10) - both called out explicitly below.

This revision changed nearly every step and added several new ones -
run the whole list this round. Once it's confirmed clean, future rounds
can go back to skipping whatever's still passing.

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
Factorio makes you type the very first console command of a session a
second time as a misfire guard - just run the same line again if nothing
seems to happen. Cheat mode is worth its own line since you'll type it
twice either way.
```
/c game.player.force.research_all_technologies(); game.speed=3; settings.global["rrec-distant-sample-interval-seconds"] = {value = 1}; settings.global["rrec-chain-near-hops"] = {value = 1}; settings.global["rrec-chain-max-hops"] = {value = 50}; settings.global["rrec-diagnostics-enabled"] = {value = true}; settings.global["rrec-battlefield-marker-enabled"] = {value = true}
```
Speeds up the slow-sample systems (logistics/item/fluid chains normally
sample every 5s; this drops it to 1s) and sets the near/far chain split so
a single hop already counts as "far" - makes the rollup steps below
produce visible results without needing a huge base. Also turns on the
optional per-tick performance timings and the in-game battlefield
perimeter marker (a cyan line traced around the exterior edge of whatever
chunks are currently recording - see step 7).

The performance timings don't go into `replay.json` - `LuaProfiler`
can't hand a raw duration value back to Lua at all, only to things like
`game.print()`/`log()`, so they're written straight to Factorio's own log
file instead. Find it at:
* **Windows:** `%APPDATA%\Factorio\factorio-current.log`
* **macOS:** `~/Library/Application Support/factorio/factorio-current.log`
* **Linux:** `~/.factorio/factorio-current.log`

and summarize it the same way as the other tools, after you're done:
```
python3 tools/inspect_logs.py
```

## 2. Long-chain rollup via belts (`item_distribution`)

Tests: a belt chain running far past a zone's own chunk gets rolled up
into a compact "approximately this much, this direction" summary instead
of being tracked (or dropped) per-entity. Has to run *before* full
recording mode - it specifically needs the far end of the chain to be in a
chunk that isn't already being recorded for some other reason, which full
recording mode would defeat.

```
/c local surface = game.player.surface; local base = game.player.position; local far_belt; for i = 0, 35 do far_belt = surface.create_entity{name = "transport-belt", position = {base.x + i, base.y + 20}, direction = defines.direction.east, force = "player"} or far_belt end; far_belt.get_transport_line(1).insert_at_back{name = "iron-plate", count = 5}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y + 20}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 3. Distant chest via an inserter chain

Tests: the same rollup mechanism as step 2, but reached by following an
inserter's `drop_target` to a chest, not just belt-to-belt - this is the
"chests, inserter chaining" path, separate code from the belt walk above.
The inserter sits one tile inside its chunk's edge and drops across the
boundary, so the chest lands in a chunk that was never itself active -
if the chest sat in the same chunk as the zone, this would just exercise
the direct physical scan instead of the chain traversal it's meant to
prove.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor(base.y / 32) * 32; local ins = surface.create_entity{name = "inserter", position = {ccx + 31, ccy + 16}, direction = defines.direction.east, force = "player"}; local chest = surface.create_entity{name = "iron-chest", position = {ccx + 32, ccy + 16}, force = "player"}; chest.get_inventory(defines.inventory.chest).insert{name = "copper-plate", count = 30}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 4. Distant logistics network (roboport)

Tests: a roboport network reachable from a zone's chunk but not
physically standing in it - the one-time network roster (which containers
exist, in what role) plus the ongoing Tier 2 content sampling for
providers/requesters. Same boundary-straddling idea as step 3: the
roboport sits just inside its chunk, its chests just outside it.

```
/c local surface = game.player.surface; local base = game.player.position; local ccx = math.floor(base.x / 32) * 32; local ccy = math.floor((base.y - 96) / 32) * 32; local rp = surface.create_entity{name = "roboport", position = {ccx + 31, ccy + 16}, force = "player"}; rp.insert{name = "construction-robot", count = 2}; local provider = surface.create_entity{name = "passive-provider-chest", position = {ccx + 34, ccy + 16}, force = "player"}; provider.get_inventory(defines.inventory.chest).insert{name = "iron-plate", count = 20}; local requester = surface.create_entity{name = "requester-chest", position = {ccx + 37, ccy + 16}, force = "player"}; local b = surface.create_entity{name = "small-biter", position = {ccx + 31, ccy + 15}, force = "enemy"}; b.die()
```
Wait a couple of seconds. If the provider chest doesn't show up in the
network roster, the roboport's construction range doesn't reach as far as
assumed here - move the chests closer to the roboport and re-run.
Roboports need electricity to actually operate (charge/dispatch robots),
which this scripted setup doesn't wire up - see the not-covered-yet note
below. The roster/reachability checks above don't depend on that.

## 5. Distant fluid chain

Tests: fluid segments have no near/far split at all (`get_fluid_segment_fluid`
reads a whole connected segment in one call, however far it physically
runs) - this proves that still works while cropped, i.e. the segment's far
end doesn't need its own active zone to be read correctly.

```
/c local surface = game.player.surface; local base = game.player.position; local pipe; for i = 0, 35 do pipe = surface.create_entity{name = "pipe", position = {base.x + i, base.y - 60}, force = "player"} or pipe end; local tank = surface.create_entity{name = "storage-tank", position = {base.x - 2, base.y - 60}, force = "player"}; tank.insert_fluid{name = "water", amount = 300}; local b = surface.create_entity{name = "small-biter", position = {base.x, base.y - 61}, force = "enemy"}; b.die()
```
Wait a couple of seconds.

## 6. Cropping & zone expiry

Tests: a zone that's gone quiet stops recording after its timeout instead
of recording forever. Continue right on from the steps above - no new
setup needed.

**Action:** Walk (or `/c game.player.teleport({game.player.position.x + 100, game.player.position.y})`)
at least 50 tiles from where step 2's biter died, then wait ~15 real
seconds without any further combat there (`/c game.speed=5` first if
you'd rather not wait; reset with `/c game.speed=3` after).

## 7. Full recording mode

Tests: every chunk gets recorded regardless of nearby combat once this is
on.

```
/c settings.global["rrec-full-recording-mode"] = {value = true}
```
**Action:** Walk into a chunk you haven't touched yet, where nothing is
fighting - just stand there a couple of seconds. Everything records
regardless of nearby combat from here on, so you don't need to babysit
zone activity for the rest of this list.

If you turned on the battlefield marker in step 1, you'll notice its cyan
outline disappears the moment full recording mode comes on - that's by
design, not a bug: every chunk is "the zone" under full recording, so a
border around everything would be meaningless. It was tracing the
exterior perimeter of whatever chunks were actively recording during
steps 2-6; there's nothing left to outline once that distinction goes
away.

## 8. Turrets: damage, kills, and destruction

Tests: a turret's own attacks being recorded (`damage_event`/`death_event`
with the turret as dealer/killer), a turret itself being destroyed
(`death_event` with the turret as victim), fire creation/fade-out
(`effect_created`/`effect_expired`) from the flamethrower's flame patch,
and hostile-kind classification for worm turrets and spawners
specifically (biter/spitter classification is already exercised
elsewhere). Everything except the last part is scripted with one-hit-point
targets and turrets placed well apart so each only ever fights its own
target - no precision combat needed, just place, wait, and watch.

```
/c game.player.insert{name="stone-wall", count=5}; game.player.insert{name="gate", count=2}
```
**Action:** Place the wall and gate anywhere nearby (just needs to exist
in the chunk snapshot) - nothing hostile exists yet, so there's no rush.
Once they're down, run the next command.

```
/c local p = game.player.position; local surface = game.player.surface; local gt = surface.create_entity{name="gun-turret", position={p.x, p.y}, force="player"}; gt.get_inventory(defines.inventory.turret_ammo).insert{name="firearm-magazine", count=10}; local gt_target = surface.create_entity{name="small-biter", position={p.x + 6, p.y}, force="enemy"}; gt_target.health = 1; local ft = surface.create_entity{name="flamethrower-turret", position={p.x + 40, p.y}, force="player"}; ft.insert_fluid{name="crude-oil", amount=100}; local ft_target = surface.create_entity{name="small-biter", position={p.x + 46, p.y}, force="enemy"}; ft_target.health = 1; local doomed = surface.create_entity{name="gun-turret", position={p.x + 80, p.y}, force="player"}; doomed.health = 1; surface.create_entity{name="behemoth-biter", position={p.x + 84, p.y}, force="enemy"}; local spawner = surface.create_entity{name="biter-spawner", position={p.x - 40, p.y}, force="enemy"}; spawner.health = 1; local ok, worm = pcall(function() return surface.create_entity{name="medium-worm-turret", position={p.x - 46, p.y}, force="enemy"} end); if ok and worm then worm.health = 1 end
```
**Action:** Land one hit each on the spawner and the worm (if it was
created - not all versions ship "medium-worm-turret") - both sit well
away from everything else, so there's nothing to accidentally kill
alongside them. Then wait ~10 seconds - the gun turret and flamethrower
turret each kill their own one-hit-point target on their own, and the
behemoth destroys the one-hit-point turret. Wait a further ~10 seconds
after that for the flamethrower's fire patch to fade.

Laser turrets need electricity to fire, which this scripted setup doesn't
wire up (see the not-covered-yet note below) - the gun and flamethrower
turrets above are ammo/fluid-powered, not electric, so they don't need
it. A turret should just fire at anything hostile in range once it has
ammo - the last two real runs produced turret kills/destruction but no
turret-dealt `damage_event`, so this round switches the gun turret's ammo
insert from the generic `.insert{}` convenience method to explicitly
inserting into `defines.inventory.turret_ammo`, in case that's the actual
gap. If this run still shows no turret-dealt damage, that's worth
reporting back rather than assumed fixed.

## 9. Spitter acid (isolated fight)

Tests: acid damage and the resulting fire/acid patch, from an actual live
fight rather than a scripted one-shot - split out on its own so it's not
competing with the turret setup above.

```
/c local p = game.player.position; game.player.surface.create_entity{name="small-spitter", position={p.x + 12, p.y}, force="enemy"}
```
**Action:** Walk over and fight it normally - let it get a couple of acid
hits in on you before it dies. Wait ~10 seconds afterward for the acid
patch to fade.

## 10. Vehicles: fuel, ammo, damage, destruction, cargo

Tests: vehicle inventories (fuel/ammo/trunk) being tracked, a vehicle
damaging/killing an enemy, a vehicle being damaged and destroyed, and an
unmanned autopilot spidertron still counting as player-controlled.

```
/c local surface = game.player.surface; game.player.insert{name="car", count=1}; game.player.insert{name="tank", count=1}; game.player.insert{name="solid-fuel", count=20}; game.player.insert{name="firearm-magazine", count=40}; game.player.insert{name="cannon-shell", count=10}
```
**Action:** Place the car and tank, fuel one with the solid-fuel, and load
ammo into its trunk - nothing hostile exists yet, so there's no rush.
Once that's done, run the next command.

```
/c local p = game.player.position; local surface = game.player.surface; local prey = surface.create_entity{name="small-biter", position={p.x + 10, p.y + 5}, force="enemy"}; prey.health = 1; local weak_car = surface.create_entity{name="car", position={p.x + 20, p.y}, force="player"}; weak_car.health = 1; surface.create_entity{name="small-biter", position={p.x + 22, p.y}, force="enemy"}
```
**Action:** Either shoot or drive over `prey` (the one-health biter) -
this is the one vehicle action that needs to be done live, since running
someone over isn't something worth scripting around. `weak_car` is
destroyed automatically by an ordinary small biter - a one-health car
doesn't need a behemoth to kill it, and a behemoth spawned this close
would just as easily turn on you instead. Wait ~5 seconds for that one.
```
/c local p = game.player.position; local surface = game.player.surface; local st = surface.create_entity{name="spidertron", position={p.x + 2, p.y}, force = game.player.force}; st.insert{name="rocket", count=20}; local target = surface.create_entity{name="small-biter", position={p.x + 30, p.y}, force="enemy"}; target.health = 1; st.autopilot_destination = {target.position.x, target.position.y}
```
Sends an armed, unmanned spidertron on autopilot toward a weak biter -
autopilot is what makes an empty spidertron still count as
player-controlled for recording purposes. Spidertrons fire rockets, not
bullets, so it's loaded with `rocket` rather than firearm-magazine - if
that item name is wrong for your game version, swap in whatever your
spidertron's weapon slot actually accepts. Wait ~5 seconds for it to
arrive and kill the target.

## 11. Player death, respawn, and corpse lifecycle

Tests: a corpse's provenance (`corpse_created`, who died and to what),
its contents being tracked while it exists (`inventory_delta` with
`owner_kind = corpse`, including a partial change - not just its full
disappearance), and eventual removal (`corpse_expired`).

```
/c game.player.insert{name="iron-plate", count=20}; game.player.insert{name="firearm-magazine", count=10}; game.player.character.health = 5; game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 1, game.player.position.y}, force="enemy"}
```
**Action:** Let the biter kill you, then click Respawn. Wait ~2 seconds so
the corpse gets scanned at least once with its full contents.
```
/c local c = game.player.surface.find_entities_filtered{type = "character-corpse"}[1]; if c then c.get_inventory(defines.inventory.character_corpse).remove{name = "iron-plate", count = 5} end
```
Removes part of the corpse's contents - a partial change, not a full
clear, to prove ongoing diffing rather than just creation/removal. Wait a
couple of seconds.
```
/c local c = game.player.surface.find_entities_filtered{type = "character-corpse"}[1]; if c then c.get_inventory(defines.inventory.character_corpse).clear() end
```
Empties the rest of the corpse's contents. Whether this specific action
is what fires `corpse_expired` (vs. the corpse's normal timeout) is still
being confirmed - if `corpse_expired` doesn't show up afterward, that's
useful information for the next round, not a step to just re-run blindly.

## 12. Ground items

Tests: an item stack dropped on the ground being tracked
(`ground_item_created`, ongoing `inventory_delta` with
`owner_kind = ground_item`), and its removal (`ground_item_removed`) once
it's gone.

```
/c game.player.insert{name="iron-plate", count=10}
```
**Action:** Open your inventory, pick up the iron-plate stack (click it
so it's on your cursor), then press **Z** once or twice to drop a couple
of plates on the ground in front of you, then close your inventory.
```
/c local items = game.player.surface.find_entities_filtered{type = "item-entity", position = game.player.position, radius = 10}; for _, i in ipairs(items) do i.destroy() end
```
Destroys every dropped item-entity near you, not just the first one
found - if you dropped more than one stack, this clears all of them.

## 13. Fluids

Tests: a fluid-holding entity appearing and its contents being tracked -
our script records the storage tank entity and the fluid inserted into it
as a `fluid_delta`. No action required.

```
/c local tank = game.player.surface.create_entity{name = "storage-tank", position = {game.player.position.x - 3, game.player.position.y}, force = "player"}; tank.insert_fluid{name = "water", amount = 500}
```

## 14. Robot cargo

Tests: a bot's carried inventory being tracked the same way an inserter's
held stack is. No action required.

```
/c local bot = game.player.surface.create_entity{name = "logistic-robot", position = game.player.position, force = "player"}; bot.get_inventory(defines.inventory.robot_cargo).insert{name = "iron-plate", count = 5}
```

## 15. Unit group formation

Tests: biters forming up into a group is recorded as `unit_group_created`.
No action required.

```
/c local g = game.player.surface.create_unit_group{position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u1 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 10, game.player.position.y}, force = "enemy"}; local u2 = game.player.surface.create_entity{name = "small-biter", position = {game.player.position.x + 11, game.player.position.y}, force = "enemy"}; g.add_member(u1); g.add_member(u2)
```

## 16. Full recording mode off + reload regression

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
If everything's green, that's the whole report; if something's missing it
tells you which step to look at again.

For a broader look at what got recorded (battlefield count/duration,
scoreboard, sample payloads per event type):
```
python3 tools/inspect_replay.py
```
Both default to the standard Factorio `script-output` location for your
OS; pass `--path` if that's wrong for your setup.

If you turned on diagnostics in step 1, break down the per-tick timing
data (written to Factorio's own log file, not `replay.json` - see step 1
for why and exactly where to find it):
```
python3 tools/inspect_logs.py
```

---

## Not covered by this checklist (future work)

Noted rather than silently skipped:

* **Landmines** - not confirmed whether this mod tracks them at all
  (damage attribution, or even placement).
* **Flame damage attribution** - step 8 confirms a fire patch is created
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
