# Ways to Use Replay Recorder

There are three ways to end up with a `replay.json`. They differ in who
they're for and how much they cost to run.

## 1. Recording during normal gameplay (not recommended)

Install the mod and play a save as usual. It records combat as it
happens, live.

This works, but it means the mod is doing recording work (chunk scans,
inventory diffing, JSON writes) during a session you're actually trying
to play, and you only get one take - if a scenario didn't produce what
you wanted, the only way to get another shot at it is to play it again.
For anything beyond casual curiosity, prefer option 2 or 3 below.

## 2. Playing back an in-game replay (recommended for most users)

Factorio can record your inputs for a save and play them back later,
deterministically re-simulating the same session from scratch. With
Replay Recorder installed:

1. When starting or saving the game you want recorded, enable Factorio's
   own **"Record replay information"** option.
2. Play the session normally (the mod does not need to be doing anything
   special here - this step is about getting a replay recorded by the
   game engine itself, not about this mod).
3. From the saves list, use the **Play** button on that save to watch the
   replay. Factorio re-simulates the entire session from the recorded
   inputs, tick by tick.
4. Because the mod is active during that re-simulation exactly as it
   would be during live play, it produces a fresh `replay.json` as a
   byproduct - without you having to play the session again yourself.

This is the best option if you're not comfortable with the command line:
no scripting, no headless setup, just the game's built-in Play button.
It's also the only way to get a `replay.json` out of a session you didn't
have this mod installed for in the first place, as long as a replay was
recorded for it.

## 3. Playing back via the headless Factorio client (best for testing and development)

Factorio also ships a headless server binary, intended for dedicated
multiplayer servers, that can run a save without a graphical client
attached. In principle, pointing it at a save with recorded replay data
and asking it to play that replay back would produce the same
`replay.json` as option 2, without launching the full game client at
all - useful for CI, batch-regenerating a replay after a mod change, or
scripting the [testing checklist](testing-checklist.md).

**This is not yet confirmed to work.** It's not established whether the
headless binary supports replay playback the same way the desktop client
does. Until that's confirmed, treat this as the goal for a future
release (see [`changelog.md`](changelog.md)) rather than a supported
workflow today - use option 2 in the meantime.
