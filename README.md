# FS25_GrainCollection

A small Farming Simulator 25 mod that lets you book **produce collections** from your on-farm silos and cow husbandries straight from the in-game menu. Click BOOK on a row, pick *Book Now* or *Book Best Price Month*, and the mod handles the rest. A 5% haulage fee comes off the sale price (same as the buyer-truck system the in-game economy already models).

Two product families ship today:

- **Grain** from on-farm silos — every sellable bulk fill type your silos hold (wheat, barley, canola, sunflowers, oat, sorghum…). Settled either instantly or, when AutoDrive is present, by a merchant truck driving silo → buyer.
- **Milk** from cow husbandries — pooled across every milking shed on your farm. Milk accumulates as your cows produce; the mod doesn't auto-sell it, so it pools until you book a collection. **Phase 1 settles milk instantly** (no AutoDrive milk tanker yet — that's planned). Cow milk only this release; buffalo / goat milk are a small config addition once they're proven.

Works on its own — no other mods required. If you also have **AutoDrive** installed and a waypoint network drawn, the mod adds a visual layer on top of **grain** sales: a merchant truck physically drives from your set arrival point to the silo to the best-paying buyer, multi-trip if needed. With AutoDrive you also choose which **merchant vehicle** does the run — a small rigid truck, a mid-size tractor + grain trailer, or a full semi rig (see *Choosing a merchant vehicle* below). The booking, the fee, the payout — all identical to the no-AutoDrive case. AutoDrive only changes what grain fulfilment *looks* like; milk always settles instantly in this release.

> **⚠ Public beta (v0.9.0.0).** Tested on Calmsden on my own save and it behaves, but the second pair of eyes are yours. Please file anything odd via [GitHub Issues](https://github.com/chrismpmason/FS25_GrainCollection/issues) — small details welcome (game version, AutoDrive version if used, map, what you did, what you saw).

## How it works

One booking system, two presentations.

When you click **BOOK** on a row — grain or milk — the same three-option dialog opens regardless of whether AutoDrive is installed:

- **Book Now** — collects this in-game month. The produce stays reserved in the menu from now until the due day; you can't double-book it.
- **Book Best Price Month** — schedules collection for the month the forecast says will pay best for that produce. Same reservation. (Milk has a full seasonal forecast curve too, so this works on milk just like grain.)
- **Cancel** — close the dialog.

Either way, the booking goes into a list. On the due in-game day, the mod settles it:

- **Grain, without AutoDrive** — grain leaves the silo instantly, money lands in your bank minus the 5% haulage fee, a *Collection complete* banner fires.
- **Grain, with AutoDrive ready** — a merchant truck spawns at your arrival point, drives to the silo, loads, drives to the best-paying buyer, despawns at the buyer. The fee, the payout, the banner are the same as the instant case. Settled at the truck's delivery, not at booking time.
- **Milk** — settles instantly from the husbandry's milk tank, regardless of AutoDrive. The 5% fee + banner are identical to the grain instant path. (A milk-tanker visual layer is planned for a later release.)

The **[RECOMMENDED]** tag on the dialog highlights whichever of *Book Now* or *Book Best Price Month* pays the higher projected total. If today's price beats the forecast, *Book Now* gets the tag; if the forecast peak is higher, *Book Best Price Month* does.

Either path uses **today's actual buyer price at the moment of fulfilment** — the dialog's number is the estimate, the payout is whatever the buyer is paying that in-game day.

## Installation

1. Download `FS25_GrainCollection.zip` from the [Releases page](https://github.com/chrismpmason/FS25_GrainCollection/releases).
2. Drop it into your FS25 mods folder: `Documents\My Games\FarmingSimulator2025\mods\`
3. Launch FS25, enable the mod in your savegame's mod list, load the save.
4. **Optional** — for the truck delivery on top, install [AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive) and draw a waypoint network covering your silos, your buyers, and at least one open spot for the merchant truck to spawn.

## Using it

Hit **F7** (or click the Produce Collection sidebar icon). You'll see a table of every produce type you've got stored, with current and forecast prices — grain rows from your silos plus a single Milk row pooling every cow husbandry on the farm.

- The **Volume** column shows what's currently bookable. Once a row is fully booked it reads `All booked (10,000 L)` and the BOOK button is inactive on that row until the booking settles or is cancelled.
- For milk, bookable = total milk across your cow husbandries minus any pending milk booking. Milk refills naturally as the cows produce, so the bookable number climbs back up between bookings.
- Click any row's **BOOK** button to open the booking dialog. Pick *Book Now* or *Book Best Price Month*.
- The **View Bookings (N)** button at the top right shows pending bookings (grain and milk in one list); click it to see them and cancel any you've changed your mind on. Cancelling releases the reservation immediately.

That's the whole player loop. The rest is just whether you've got AutoDrive set up to make grain deliveries visible.

### AutoDrive setup (only if you want the truck experience)

The **Merchant point** button at the top right opens a picker listing your AutoDrive markers. Pick the one you want the merchant truck to spawn at — somewhere with open space, off any roads or buildings. The choice is saved per-savegame.

That's the only one-time setup. After that the mod automatically picks the AutoDrive marker nearest each silo and each buyer at fulfilment time, so adding new silos or buyers doesn't need any reconfiguration on this side.

### Choosing a merchant vehicle

The **Vehicle** button at the top of the Produce Collection menu (only visible when AutoDrive is installed) opens a picker with three vanilla tiers:

| Tier | Vehicle | Capacity | Trips for a 54,000 L booking |
|------|---------|----------|------------------------------|
| Small | Lizard MultiPurpose (Extension) | 7,600 L | ~8 |
| Medium | Massey Ferguson 9S + Brantner Z 18051 | 19,600 L | 3 |
| Large | Volvo FH16 + Krampe SKS 30/1050 | ~59,400 L | 1 |

All three are base-game vehicles — no mod dependencies. The choice is saved per-savegame.

**The vehicle is captured when you BOOK.** Switching the picker afterwards only affects bookings made *from that point on*; any pending booking keeps the vehicle it was booked with. The pending-bookings list shows each booking's captured vehicle so there's no guessing. So if you book a large delivery on the Krampe and then drop the picker back to the Lizard for the next one, the Krampe still does the booked run.

Without AutoDrive there's no truck — bookings settle instantly and the picker has no effect (it's hidden).

### Merchant arrival marker placement

Pick a spot with enough open space for whichever merchant vehicle tier you're using. The small Lizard is ~6 m and forgiving — even tight yard markers usually work. The medium tractor + trailer combo is ~13 m and the large FH16 + Krampe semi is ~17 m; both need open road clearance and turning room on the AutoDrive route between spawn point, silo, and buyer.

Open fields, road junctions, and the entrance to your farm yard all work fine for the small rig. For the medium and large rigs, give them somewhere a real-world articulated truck could pull in and out of cleanly. Things to avoid at any tier:
- Inside buildings (the vehicle spawns at the marker position — it can't pass through walls)
- Directly on top of fences, hedges, or other physics objects
- Tight roads where the trailer's swept path would clip terrain (medium and large especially)

If the rig gets stuck during a journey, that's an AutoDrive routing issue — adjust your AutoDrive waypoints so the route works for the vehicle you've selected, or pick a smaller tier. The mod just hands AutoDrive your spawn marker and destination marker; AutoDrive does the actual driving.

> **Capacity vs booking size:** bigger tier = fewer trips. A 54,000 L booking runs as ~8 round trips on the small Lizard, 3 on the medium, 1 on the large (about 8 seconds between despawn and the next spawn when multi-trip). The booking pays once at the end for the whole booked amount — no partial payments per trip — so the only practical difference is wall-clock time and how much turning room your AutoDrive network has for the bigger rigs.

### Buyer marker placement

On arrival at a buyer, the truck stops when it gets within ~30 metres of the buyer's nearest AutoDrive marker — it doesn't try to reverse into the load bay. The grain is sold and the truck despawns wherever it stops.

If the buyer marker on your map happens to be inside a building footprint, or on the wrong side of a wall, the truck may "arrive" while still on an inaccessible side of the obstacle. Workaround: move (or add) an AutoDrive marker within ~50 metres of the buyer, placed somewhere the truck can actually reach from open road. The mod picks the nearest marker to the buyer for arrival.

### Note: grain transfer is instant on arrival (AutoDrive mode)

Grain is transferred directly when the truck reaches the silo (and sold directly when it reaches the buyer). You won't see grain physically pour into the trailer or tip out at the buyer — the transfer is instant on arrival. The truck spawns already loaded after the pickup. This is by design and keeps the mod reliable across all maps and vehicles.

## Compatibility

- **AutoDrive** — soft dependency. With it installed and a waypoint network drawn, bookings settle via the truck. Without it (or without waypoints), bookings settle instantly. Same fee, same payout, same banner either way. Tested against the FS25 AutoDrive release current as of May 2026.
- **Realistic Livestock**, **Red Tape**, other husbandry mods — no conflict. Husbandry mods change how animals are modelled (per-animal stats, breeding rules, mortality, etc.); this mod reads + drains two things on the placeable itself — grain silos (fill levels), and the husbandry's stock vanilla milk Storage. Realistic Livestock leaves that Storage untouched on this save — milk pools through the standard `spec_husbandry.storage` the vanilla cow barn uses — so the mod's milk read/drain works the same whether RL is loaded or not. (Plus the AutoDrive driving controller, when present, for the grain truck.)
- **Other AutoDrive-using mods** (Courseplay, etc.) — should coexist. The merchant truck is a transient AI-spawned vehicle, not one of your fleet, so it doesn't compete with player AutoDrive routes.
- **Multiplayer** — modDesc declares MP supported, but I've only tested singleplayer. Treat MP as alpha until someone runs a dedicated session.
- **Map compatibility** — anywhere FS25 runs. AutoDrive mode is tested on Calmsden.

## Known issues / things to keep an eye on

- (AutoDrive mode) The truck respects your AutoDrive routing. If a route segment can't physically fit the selected merchant vehicle, the rig will wedge — AutoDrive's responsibility, not the mod's. Fix it by adjusting the AutoDrive waypoints around the trouble spot, or pick a smaller tier from the Vehicle button.
- (AutoDrive mode) If the best buyer's nearest AutoDrive marker is on the wrong side of an obstacle, the truck will "arrive" without physically reaching the bay (see Buyer marker placement above). Move or add a marker to fix.
- (AutoDrive mode) Multi-trip cycles back automatically. Between despawn and the next spawn there's an 8-second pause — you'll see a blue notification "Grain collection continuing — XL of booking left, next truck arriving shortly" confirming it's still running.
- (Both modes) Reservation is a soft lock — it stops you double-booking the same grain through this menu, but it doesn't physically prevent you from driving a tractor up to the silo and emptying it yourself. If you empty a booked silo before fulfilment, the booking will settle for whatever's actually left.
- (Both modes) If anything else looks off — errors with the `[FS25_GrainCollection]` prefix in `log.txt`, money not arriving, etc. — please file an issue with the log snippet.

## Reporting bugs / requesting features

[GitHub Issues](https://github.com/chrismpmason/FS25_GrainCollection/issues). Please include:

- FS25 version
- Mod version (currently 0.9.0.0)
- Whether AutoDrive is installed, and which version
- Map
- Other mods you have active
- The relevant lines from `log.txt` (filter for `[FS25_GrainCollection]`)
- What you expected vs. what happened

Feature requests welcome — per-buyer marker overrides and additional vehicle tiers are on the list.

## License

MIT — see [LICENSE](LICENSE).

## Author

Chris Mason (Hartwell Farm).
