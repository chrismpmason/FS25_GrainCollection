# FS25_GrainCollection

A small Farming Simulator 25 mod that books a merchant haulier to come and collect grain from your on-farm silos. The truck spawns at your chosen merchant arrival point, drives to the silo, loads, drives to the best-paying buyer, sells, and despawns. Multi-trip for large silos.

> **⚠ Public beta (v0.5.99.47).** First release out in the wild. Tested across Dahiem, Calmsden and Hartwell on my own save and it behaves, but the second pair of eyes are yours. Please file anything odd via [GitHub Issues](https://github.com/chrismpmason/FS25_GrainCollection/issues) — small details welcome (game version, AutoDrive version, map, what you did, what you saw).

## REQUIRED: AutoDrive

**AutoDrive must be installed AND active on your map, with a waypoint network already drawn. This mod does not work without AutoDrive — the haulier truck drives along YOUR AutoDrive routes. No AutoDrive network = no deliveries. Draw routes connecting your merchant arrival point, your silos, and your buyers before using this mod.**

If AutoDrive is missing or your map has no waypoints, the BOOK button will toast an error and won't dispatch.

## What it does

Adds a **Produce Collection** tab to the in-game pause menu (F7). One row per grain you own, with live prices across every buyer on the map, the best buyer right now, and the best buyer this season. Click **BOOK** on any row and a merchant truck spawns at your set arrival point, drives to your silo, loads up, drives to the best-paying buyer, sells the load, and despawns. If there's more grain than the truck can carry in one go, a fresh truck appears about 8 seconds after the first one despawns, and keeps cycling until the silo is empty.

Useful if you'd rather plan your grain sales from the menu and watch the trucks come and go than spend an hour hauling trailers back and forth yourself.

## Installation

1. Install [AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive) (or the modhub version) and draw a waypoint network on your map. Mark your silos, mark your buyers, mark at least one open spot somewhere on the farm where a truck can spawn — this last one will be your "merchant arrival point".
2. Download `FS25_GrainCollection.zip` from the [Releases page](https://github.com/chrismpmason/FS25_GrainCollection/releases).
3. Drop it into your FS25 mods folder: `Documents\My Games\FarmingSimulator2025\mods\`
4. Launch FS25, enable the mod in your savegame's mod list, load the save.

## Setup

Once in-game:

1. Hit `F7` (or click the Produce Collection sidebar icon in the pause menu). You'll see a table of every grain you have stored.
2. The first time you click **BOOK** on any row, the mod will ask you to pick a **merchant arrival point** — choose one of your AutoDrive markers. Pick somewhere with open space (see below). This choice is saved per-savegame.
3. Click **BOOK** again. The truck spawns at your arrival point, drives to the silo, loads, drives to the best buyer, sells. Notifications show progress.

### Merchant arrival marker placement

Pick a spot with enough open space for the merchant vehicle to spawn cleanly. For v0.6 the mod uses a single vanilla **Lizard MultiPurpose (Extension)** truck — about 6 metres long, 7,600 L grain capacity. Vehicle selection (small / large / tractor + trailer) is on the v0.7 roadmap; for now the Lizard is fixed for universal map compatibility.

Open fields, road junctions, and the entrance to your farm yard all work fine. Even tight yard markers are usually OK at this size. Things to still avoid:
- Inside buildings (the truck spawns at the marker position — it can't pass through walls)
- Directly on top of fences, hedges, or other physics objects

If the truck gets stuck during a journey, that's an AutoDrive routing issue — adjust your AutoDrive waypoints so the route works for the vehicle. The mod just hands AutoDrive your spawn marker and destination marker; AutoDrive does the actual driving.

> **Note on capacity:** the Lizard's 7,600 L hold is small relative to a full silo, so a large collection runs as several back-to-back trips between the silo and the buyer. That's intentional for v0.6 — v0.7 will let you pick a larger combo (FH16 + Krampe-style semitrailer, ~59,000 L) when your AutoDrive network has the turning room for it.

### Buyer marker placement

On arrival at a buyer, the truck stops when it gets within ~30 metres of the buyer's nearest AutoDrive marker — it doesn't try to reverse into the load bay. The grain is sold and the truck despawns wherever it stops.

If the buyer marker on your map happens to be inside a building footprint, or on the wrong side of a wall, the truck may "arrive" while still on an inaccessible side of the obstacle. Workaround: move (or add) an AutoDrive marker within ~50 metres of the buyer, placed somewhere the truck can actually reach from open road. The mod picks the nearest marker to the buyer for arrival.

### Note: grain transfer is instant on arrival

Grain is transferred directly when the truck reaches the silo (and sold directly when it reaches the buyer). You won't see grain physically pour into the trailer or tip out at the buyer — the transfer is instant on arrival. The truck spawns already loaded after the pickup. This is by design and keeps the mod reliable across all maps and vehicles.

## Compatibility

- **AutoDrive** — required. Tested against the FS25 AutoDrive release current as of May 2026.
- **Realistic Livestock**, **Red Tape**, other husbandry mods — no conflict. Husbandry mods touch animal placeables; this mod only touches grain silos and the AutoDrive driving controller.
- **Other AutoDrive-using mods** (Courseplay, etc.) — should coexist. The merchant truck is a transient AI-spawned vehicle, not one of your fleet, so it doesn't compete with player AutoDrive routes.
- **Multiplayer** — modDesc declares MP supported, but I've only tested singleplayer. Treat MP as alpha until someone runs a dedicated session.
- **Map compatibility** — anywhere AutoDrive runs. Tested on Dahiem, Calmsden, Hartwell.

## Known issues / things to keep an eye on

- The truck respects your AutoDrive routing. If a route segment can't physically fit the Lizard MultiPurpose (rare at ~6 m, but possible), the truck will wedge — AutoDrive's responsibility, not the mod's. Fix it by adjusting the AutoDrive waypoints around the trouble spot.
- If the best buyer's nearest AutoDrive marker is on the wrong side of an obstacle, the truck will "arrive" without physically reaching the bay (see Buyer marker placement above). Move or add a marker to fix.
- Multi-trip cycles back automatically. Between despawn and the next spawn there's an 8-second pause — you'll see a blue notification "Grain collection continuing — XL left, next truck arriving shortly" confirming it's still running.
- If anything else looks off — truck not spawning, money not arriving, errors with the `[FS25_GrainCollection]` prefix in `log.txt` — please file an issue with the log snippet.

## Reporting bugs / requesting features

[GitHub Issues](https://github.com/chrismpmason/FS25_GrainCollection/issues). Please include:

- FS25 version
- Mod version (currently 0.5.99.47)
- AutoDrive version
- Map
- Other mods you have active
- The relevant lines from `log.txt` (filter for `[FS25_GrainCollection]`)
- What you expected vs. what happened

Feature requests welcome — vehicle selection (small / large / tractor + trailer combo) is the v0.7 headline, and per-buyer marker overrides are on the list after that.

## License

MIT — see [LICENSE](LICENSE).

## Author

Chris Mason (Hartwell Farm).
