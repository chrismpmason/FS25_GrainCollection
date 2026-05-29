# FS25_GrainCollection

A small Farming Simulator 25 mod that lets you book grain collections from your on-farm silos straight from the in-game menu. Click BOOK on a grain row, pick *Book Now* or *Book Best Price Month*, and the mod handles the rest. A 5% haulage fee comes off the sale price (same as the buyer-truck system the in-game economy already models).

Works on its own — no other mods required. If you also have **AutoDrive** installed and a waypoint network drawn, the mod adds a visual layer on top: a merchant truck physically drives from your set arrival point to the silo to the best-paying buyer, multi-trip if needed. The booking, the fee, the payout — all identical to the no-AutoDrive case. AutoDrive only changes what fulfilment *looks* like.

> **⚠ Public beta (v0.6.0.0).** First release out in the wild. Tested across Calmsden and Dahiem on my own save and it behaves, but the second pair of eyes are yours. Please file anything odd via [GitHub Issues](https://github.com/chrismpmason/FS25_GrainCollection/issues) — small details welcome (game version, AutoDrive version if used, map, what you did, what you saw).

## How it works

One booking system, two presentations.

When you click **BOOK** on a grain row, the same three-option dialog opens regardless of whether AutoDrive is installed:

- **Book Now** — collects this in-game month. The grain stays locked in the silo from now until the due day; you can't double-book it.
- **Book Best Price Month** — schedules collection for the month the forecast says will pay best for that grain. Same grain reservation.
- **Cancel** — close the dialog.

Either way, the booking goes into a list. On the due in-game day, the mod settles it:

- **Without AutoDrive** — grain leaves the silo instantly, money lands in your bank minus the 5% haulage fee, a *Collection complete* banner fires.
- **With AutoDrive ready** — a merchant truck spawns at your arrival point, drives to the silo, loads, drives to the best-paying buyer, despawns at the buyer. The fee, the payout, the banner are the same as the instant case. Settled at the truck's delivery, not at booking time.

The **[RECOMMENDED]** tag on the dialog highlights whichever of *Book Now* or *Book Best Price Month* pays the higher projected total. If today's price beats the forecast, *Book Now* gets the tag; if the forecast peak is higher, *Book Best Price Month* does.

Either path uses **today's actual buyer price at the moment of fulfilment** — the dialog's number is the estimate, the payout is whatever the buyer is paying that in-game day.

## Installation

1. Download `FS25_GrainCollection.zip` from the [Releases page](https://github.com/chrismpmason/FS25_GrainCollection/releases).
2. Drop it into your FS25 mods folder: `Documents\My Games\FarmingSimulator2025\mods\`
3. Launch FS25, enable the mod in your savegame's mod list, load the save.
4. **Optional** — for the truck delivery on top, install [AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive) and draw a waypoint network covering your silos, your buyers, and at least one open spot for the merchant truck to spawn.

## Using it

Hit **F7** (or click the Produce Collection sidebar icon). You'll see a table of every grain you've got stored, with current and forecast prices.

- The **Volume** column shows what's currently bookable. Once a grain row is fully booked it reads `All booked (10,000 L)` and the BOOK button is inactive on that row until the booking settles or is cancelled.
- Click any row's **BOOK** button to open the booking dialog. Pick *Book Now* or *Book Best Price Month*.
- The **View Bookings (N)** button at the top right shows pending bookings; click it to see the list and cancel any you've changed your mind on. Cancelling releases the reservation immediately.

That's the whole player loop. The rest is just whether you've got AutoDrive set up to make the delivery visible.

### AutoDrive setup (only if you want the truck experience)

The **Merchant point** button at the top right opens a picker listing your AutoDrive markers. Pick the one you want the merchant truck to spawn at — somewhere with open space, off any roads or buildings. The choice is saved per-savegame.

That's the only one-time setup. After that the mod automatically picks the AutoDrive marker nearest each silo and each buyer at fulfilment time, so adding new silos or buyers doesn't need any reconfiguration on this side.

### Merchant arrival marker placement

Pick a spot with enough open space for the merchant vehicle to spawn cleanly. For v0.6 the mod uses a single vanilla **Lizard MultiPurpose (Extension)** truck — about 6 metres long, 7,600 L grain capacity. Vehicle selection (small / large / tractor + trailer) is on the v0.7 roadmap; for now the Lizard is fixed for universal map compatibility.

Open fields, road junctions, and the entrance to your farm yard all work fine. Even tight yard markers are usually OK at this size. Things to still avoid:
- Inside buildings (the truck spawns at the marker position — it can't pass through walls)
- Directly on top of fences, hedges, or other physics objects

If the truck gets stuck during a journey, that's an AutoDrive routing issue — adjust your AutoDrive waypoints so the route works for the vehicle. The mod just hands AutoDrive your spawn marker and destination marker; AutoDrive does the actual driving.

> **Capacity vs booking size:** the Lizard's 7,600 L hold is small relative to a full silo, so a large booking runs as several back-to-back trips between the silo and the buyer (about 8 seconds between despawn and the next spawn). The booking pays once at the end for the whole booked amount — you don't get partial payments per trip. v0.7 will let you pick a larger combo (FH16 + Krampe-style semitrailer, ~59,000 L) when your AutoDrive network has the turning room for it.

### Buyer marker placement

On arrival at a buyer, the truck stops when it gets within ~30 metres of the buyer's nearest AutoDrive marker — it doesn't try to reverse into the load bay. The grain is sold and the truck despawns wherever it stops.

If the buyer marker on your map happens to be inside a building footprint, or on the wrong side of a wall, the truck may "arrive" while still on an inaccessible side of the obstacle. Workaround: move (or add) an AutoDrive marker within ~50 metres of the buyer, placed somewhere the truck can actually reach from open road. The mod picks the nearest marker to the buyer for arrival.

### Note: grain transfer is instant on arrival (AutoDrive mode)

Grain is transferred directly when the truck reaches the silo (and sold directly when it reaches the buyer). You won't see grain physically pour into the trailer or tip out at the buyer — the transfer is instant on arrival. The truck spawns already loaded after the pickup. This is by design and keeps the mod reliable across all maps and vehicles.

## Compatibility

- **AutoDrive** — soft dependency. With it installed and a waypoint network drawn, bookings settle via the truck. Without it (or without waypoints), bookings settle instantly. Same fee, same payout, same banner either way. Tested against the FS25 AutoDrive release current as of May 2026.
- **Realistic Livestock**, **Red Tape**, other husbandry mods — no conflict. Husbandry mods touch animal placeables; this mod only touches grain silos (and, when present, the AutoDrive driving controller).
- **Other AutoDrive-using mods** (Courseplay, etc.) — should coexist. The merchant truck is a transient AI-spawned vehicle, not one of your fleet, so it doesn't compete with player AutoDrive routes.
- **Multiplayer** — modDesc declares MP supported, but I've only tested singleplayer. Treat MP as alpha until someone runs a dedicated session.
- **Map compatibility** — anywhere FS25 runs. AutoDrive mode is tested on Calmsden and Dahiem.

## Known issues / things to keep an eye on

- (AutoDrive mode) The truck respects your AutoDrive routing. If a route segment can't physically fit the Lizard MultiPurpose (rare at ~6 m, but possible), the truck will wedge — AutoDrive's responsibility, not the mod's. Fix it by adjusting the AutoDrive waypoints around the trouble spot.
- (AutoDrive mode) If the best buyer's nearest AutoDrive marker is on the wrong side of an obstacle, the truck will "arrive" without physically reaching the bay (see Buyer marker placement above). Move or add a marker to fix.
- (AutoDrive mode) Multi-trip cycles back automatically. Between despawn and the next spawn there's an 8-second pause — you'll see a blue notification "Grain collection continuing — XL of booking left, next truck arriving shortly" confirming it's still running.
- (Both modes) Reservation is a soft lock — it stops you double-booking the same grain through this menu, but it doesn't physically prevent you from driving a tractor up to the silo and emptying it yourself. If you empty a booked silo before fulfilment, the booking will settle for whatever's actually left.
- (Both modes) If anything else looks off — errors with the `[FS25_GrainCollection]` prefix in `log.txt`, money not arriving, etc. — please file an issue with the log snippet.

## Reporting bugs / requesting features

[GitHub Issues](https://github.com/chrismpmason/FS25_GrainCollection/issues). Please include:

- FS25 version
- Mod version (currently 0.6.0.0)
- Whether AutoDrive is installed, and which version
- Map
- Other mods you have active
- The relevant lines from `log.txt` (filter for `[FS25_GrainCollection]`)
- What you expected vs. what happened

Feature requests welcome — vehicle selection (small / large / tractor + trailer combo) is the v0.7 headline, and per-buyer marker overrides are on the list after that.

## License

MIT — see [LICENSE](LICENSE).

## Author

Chris Mason (Hartwell Farm).
