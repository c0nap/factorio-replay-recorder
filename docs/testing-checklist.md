# Manual In-Game Test Checklist

A checklist for exercising the mod in a real Factorio save, since there's
no headless/automated way to drive an actual player character through
combat. Each scenario below is: a console command (or two) to set the
scene, a short action to take, and what should show up in `replay.json`
afterward. Run through them in order, in one continuous session, then
check the results with `tools/inspect_replay.py` (see the end of this
doc).

This is a throwaway test save - don't run it against your real base.
Console commands (`/c ...`) permanently disable achievements for a save
the moment you use one; that's expected and harmless here.

## Before you start

1. **Install the mod.** Copy this repo's contents into a folder named
   `factorio-replay-recorder_0.1.0` (matching `info.json`) inside your
   Factorio `mods` directory - see the README's install section.
2. **Start a new save.** If you want the option to replay this exact
   session later through Factorio's own replay viewer (a good way to
   double check the mod against something you already did), check
   **Record replay** in the top-right of the New Game screen before
   creating it.
3. **Open the console.** Press `` ` `` or `~` (rebindable under Settings
   → Controls → Toggle chat and Lua console if that doesn't work).
4. **Enable cheat mode** (infinite items, instant building/crafting - it
   does *not* make you invincible, so death/respawn testing still works):
   ```
   /c game.player.cheat_mode=true
   ```
   Factorio makes you type the very first console command a second time
   as a misfire guard - just run the same line again if nothing seems to
   happen.
5. **Unlock every technology**, so turrets/vehicles that need research
   (laser turrets, spidertrons, ...) are placeable:
   ```
   /c game.player.force.research_all_technologies()
   ```
6. *(Optional)* Speed the game up while you wait out timers:
   `/c game.speed=5`, and set it back with `/c game.speed=1` when you're
   done waiting.

Every command below is a single line starting with `/c` - paste it into
the console and press Enter. If any one line errors in red, that's fine,
just skip it and move to the next; it won't affect anything else on this
list.

---

## 1. Combat detection & chunk snapshot

```
/c game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 3, game.player.position.y}, force="enemy"}
```

**Action:** Kill it (walk up and punch it, or shoot it if you're armed).

**Expect in replay.json:**
- One `chunk_snapshot` for the chunk you're standing in.
- `mobile_positions` entries while the biter was alive and nearby.
- A `death_event` with `victim.type = "unit"`, `hostile_kind = "biter"`,
  `hostile_size = "small"`.

## 2. Zone expiry

Continue right on from scenario 1 - no new setup needed.

**Action:** Walk (or use `/c game.player.teleport({game.player.position.x + 100, game.player.position.y})`)
at least 50 tiles from where the biter died, then wait about 15 real
seconds without any further combat there (use `/c game.speed=5` first if
you'd rather not wait; reset with `/c game.speed=1` after).

**Expect:** A `zone_expired` event for that chunk, roughly 10 in-game
seconds after the last hit (the default zone timeout).

## 3. Player death & respawn (the "goal")

```
/c game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 1, game.player.position.y}, force="enemy"}
/c game.player.character.health = 5
```

**Action:** Let the biter hit you until you die (don't fight back), then
click Respawn on the death screen.

**Expect:**
- A `death_event` with `victim.type = "character"`.
- A `score_update` with `force = "player"` and `deaths_this_force`
  incrementing.
- A `player_respawn` event once you respawn.

If you'd rather skip the wait, `/c game.player.character.die()` also
triggers the death/score chain (just without a killer attributed, since
there wasn't a real attacker).

## 4. Defensive perimeter (walls + every turret type)

```
/c game.player.insert{name="stone-wall", count=10}
/c game.player.insert{name="gun-turret", count=2}
/c game.player.insert{name="laser-turret", count=2}
/c game.player.insert{name="firearm-magazine", count=50}
```

**Action:** Place a wall segment and both turrets near you, then spawn a
fresh biter to attack them:
```
/c game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 5, game.player.position.y}, force="enemy"}
```

**Expect:** The `chunk_snapshot`'s `statics` list includes entries for
`type = "wall"`, `type = "ammo-turret"` (gun turret), and
`type = "electric-turret"` (laser turret), each tagged
`"is_defense": true`. `damage_event` entries as the biter hits them.

## 5. Full recording mode

Open **Settings → Mod Settings → Map** and check **Full recording mode**,
or via console:
```
/c settings.global["rrec-full-recording-mode"] = {value = true}
```

**Action:** Walk into a chunk you haven't touched yet, where nothing is
fighting - just stand there a couple of seconds.

**Expect:** A `chunk_snapshot` and `mobile_positions` for that chunk
despite there being no combat at all.

Afterward, uncheck the setting again (or
`/c settings.global["rrec-full-recording-mode"] = {value = false}`) and
confirm nothing errors.

## 6. Vehicle tracking & inventory

```
/c game.player.insert{name="car", count=1}
```

**Action:** Place the car, get in, and drive it next to a freshly spawned
biter:
```
/c game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 5, game.player.position.y}, force="enemy"}
```
Then get out, open the car's inventory, and drag some ammo into its
trunk.

**Expect:** `mobile_positions` entries with `type = "car"`, and an
`inventory_delta` with `owner_kind = "vehicle"` once you moved items into
the trunk.

## 7. Autopilot spidertron (optional, needs Spidertron unlocked)

This one exercises a specific bugfix: an unmanned spidertron fighting
under autopilot should still count as "a player is here." One line
creates the spidertron and sends it off under autopilot (it has to be one
line - console variables don't persist between separate `/c` commands):
```
/c local st = game.player.surface.create_entity{name="spidertron", position={game.player.position.x + 2, game.player.position.y}, force = game.player.force}; st.autopilot_destination = {st.position.x + 15, st.position.y}
```

**Action:** Step well away from the spidertron yourself (further than the
combat radius setting, default 48 tiles), then put a biter in its path:
```
/c game.player.surface.create_entity{name="small-biter", position={game.player.position.x + 17, game.player.position.y}, force="enemy"}
```

**Expect:** `mobile_positions` entries with `type = "spider-vehicle"`
even though no player is riding it.

## 8. Belt content diffing

```
/c game.player.insert{name="transport-belt", count=5}
/c game.player.insert{name="iron-plate", count=20}
```

**Action:** Place a short line of belts inside a chunk that's already an
active combat zone (e.g. near scenario 1 or 4's fight). Manually drop a
few iron plates onto the belt by hand (hold the stack, click the belt
tiles), then wait a few seconds without adding anything more.

**Expect:** `belt_contents` events when you add items, but they should
stop appearing once the belt's contents stop changing - not one every
single tick. Use `python3 tools/inspect_replay.py --type belt_contents`
to see all of them at once and eyeball this.

## 9. Weapon-tagged projectile impacts

```
/c game.player.insert{name="pistol", count=1}
/c game.player.insert{name="firearm-magazine", count=20}
```

**Action:** Equip the pistol and shoot a spawned biter a few times.

**Expect:** `projectile_impact` events with a `weapon` field naming the
projectile prototype. It may not exactly match the magazine's item name
(e.g. a "firearm-magazine" fires a differently-named bullet prototype) -
that's expected, it's identifying the projectile, not the ammo item.

## 10. Fire/acid patches fading

```
/c game.player.surface.create_entity{name="small-spitter", position={game.player.position.x + 6, game.player.position.y}, force="enemy"}
```

**Action:** Stay in range and let it spit acid at you a couple of times,
then step back and wait 15-20 seconds for the acid patches to fade on
their own.

**Expect:** `effect_expired` events once the acid/fire entities time out.

## 11. Kill classification across hostile kinds/sizes

Each entity is force-killed with one hit by setting its health to 1 right
after creation:
```
/c local b = game.player.surface.create_entity{name="behemoth-biter", position={game.player.position.x + 3, game.player.position.y}, force="enemy"}; b.health = 1
/c local w = game.player.surface.create_entity{name="medium-worm-turret", position={game.player.position.x + 3, game.player.position.y + 3}, force="enemy"}; w.health = 1
/c local s = game.player.surface.create_entity{name="biter-spawner", position={game.player.position.x + 3, game.player.position.y - 3}, force="enemy"}; s.health = 1
```

**Action:** Land one hit on each.

**Expect:** Three `death_event`s with `hostile_kind` values `"biter"`,
`"worm"`, and `"spawner"` respectively.

If `medium-worm-turret` errors on your game version, skip that line - it
won't affect the others.

## 12. Player inventory deltas

```
/c game.player.insert{name="iron-plate", count=50}
/c game.player.remove_item{name="iron-plate", count=20}
```

**Expect:** `inventory_delta` events with `owner_kind = "player"`
reflecting the `+50` then `-20` changes.

## Optional: configuration-changed regression check

Exit to the main menu (no need to close Factorio), go to **Mods**,
toggle any other installed mod on/off (or this mod off then back on),
then reload your save.

**Expect:** The save loads without errors, and `replay.json` still
contains everything recorded before this step - it should **not** have
been truncated.

---

## After you're done

Run the inspector script against the output:
```
python3 tools/inspect_replay.py
```
If it can't find the file automatically, pass its location directly, e.g.
`python3 tools/inspect_replay.py --path "C:\Users\<you>\AppData\Roaming\Factorio\script-output\replay.json"`.

Share the printed summary (and, if something looks off, the output of
`--type <the event type in question> --limit 5` for a closer look).
