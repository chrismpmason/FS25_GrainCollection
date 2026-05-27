# FS25 Grain Collection

An in-game mod for **Farming Simulator 25** that adds a Produce Collection menu for managing your grain sales.

## What it does

- Shows a clean table of all your stored grain across every silo on the map
- Compares live prices at every buyer right now
- Tells you the best buyer this month — and the best month overall
- Lets you **book** a collection: pick BOOK NOW for instant fulfilment, or BOOK BEST to schedule for the optimal month
- Mod handles the timing, payment, and silo drain automatically on the due date

No more manually checking buyer prices and driving back and forth to compare. Set it and forget it.

## Installation

1. Download the latest `FS25_GrainCollection.zip` from the [Releases page](../../releases)
2. Place it in your FS25 mods folder:
   `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`
3. Enable the mod in your save's mod list
4. Press **F7** in-game to open the Produce Collection menu (or find it in the in-game menu sidebar)

### Merchant arrival marker placement

When you set the merchant arrival point (via the picker in Produce Collection), pick a spot with enough open space for the merchant vehicle to spawn cleanly. The default vehicle is a Volvo FH16 + Krampe SKS 30/1050 trailer combo — roughly 18 metres long.

Open fields, road junctions, and the entrance to your farm yard work well. Avoid:
- Inside tight farm buildings or barns
- Between hedges, fences, or close-packed structures
- The exact load bay of a buyer (those are usually too tight for a full combo)

If the truck gets stuck during a journey, that's an AutoDrive routing issue — adjust your AutoDrive waypoints so the route works for an 18m vehicle. The mod just hands AutoDrive your spawn marker and destination marker; AutoDrive does the actual driving.

## Compatibility

- FS25 (base game)
- Compatible with AutoDrive (detection support; full integration coming in v0.6)
- Tested on Saxlingham map

## Status

**v0.5.0.1** — feature-complete for grain collection. Buyer-haulier model (merchants send their own trucks to collect from your silo) coming in v0.6.

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Licence

MIT — see [LICENSE](LICENSE)

## Credits

Developed by Chris Mason for the Hartwell Farm YouTube series.