<div align=center>
  <h1>Factorio Replay Recorder</h1>
  <h4>A standalone telemetry exporter for visualizing combat and gameplay mechanics</h4>
</div>

<hr>

Factorio Replay Recorder extracts highly detailed, event-driven game state data (tiles, entities, projectiles, and AI behavior) and exports it into an independent JSON replay format. 

This data is designed to be ingested by standalone desktop visualizers, allowing you to replay, analyze, and map out combat encounters without running the Factorio engine.

*Inspired heavily by the incredible [Statorio](https://mods.factorio.com/mod/statorio) by chksm.*

## Features

* **Smart Spatial Cropping:** Automatically detects combat engagements. The mod only records coordinate and entity data when a player, vehicle, or defense perimeter is actively engaged, keeping file sizes incredibly small.
* **Sports-Style Scoring:** Player and vehicle deaths are treated as "goals." The replay automatically crops out the downtime during respawns and travel.
* **Environmental Context:** Dumps static maps of the battlefield upon engagement, including water, landfill, and contiguous defensive walls to visualize chokepoints.
* **Event-Driven Tracking:** Projectiles (bullets, rockets, spitter acid), logistics bot deployments, and inventory changes are recorded via events rather than tick-polling.
* **AI Clustering:** Nests are grouped into bases, and biter expansion parties are tracked as single AI nodes until they engage, mimicking the engine's internal logic.
* **Universal Mod Support:** Dynamically scans Factorio 2.0 prototypes to automatically support modded biters, new weapons, and custom combat vehicles based on their internal collision and class types.

## Output Format

Data is exported to Factorio's `script-output/` directory as a JSON stream, structured by tick:

```json
{
  "tick": 145022,
  "events": [
    {"type": "combat_zone_active", "chunk": [12, -4], "trigger": "player_fired"},
    {"type": "projectile", "name": "acid-stream", "origin": [14.2, -3.1], "target": [12.0, -4.5]},
    {"type": "inventory_delta", "entity": "player", "item": "piercing-rounds-magazine", "qty": -1}
  ]
}