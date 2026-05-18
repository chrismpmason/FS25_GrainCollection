# FS25 Produce Collection — Roadmap

## Shipped

### 0.1.x — Proof of concept (grain only)
- F7 opens a lightweight `renderText` overlay.
- Discovers owned silos via `storageSystem` + placeable walk (covers vanilla and custom maps like Daheim).
- Restricted to grain/cereal fill types.
- Book a collection N days out (0–7); on the due day at 9am the grain is removed and the farm is paid the going rate minus 5% haulage.
- Save/load persists pending bookings; minimal MP event so clients see bookings.
- Final 0.1 release was 0.1.7 — booking/processing confirmed working end-to-end on Daheim.

### 0.2.x — All produce, sell-point selection, finance routing, better notifications
- 0.2.0: dropped grain-only filter — any fill type accepted by at least one unloading station is eligible. Per-silo sell-point list (sorted by price); player picks which sell point. New keymap on the old overlay: ↑/↓ silo, ←/→ sell point, `[ ]` lead days. `MIN_LOAD_LITRES` lowered to 100 L (noise floor).
- 0.2.1: route money into the correct Finance category per fill type (HARVEST_INCOME / SOLD_MILK / SOLD_WOOL / SOLD_EGGS / SOLD_WOOD with `SOLD_PRODUCTS` fallback); big green side-notification banner on collection complete; one-time startup log dump showing which MoneyType constants resolved.

### 0.5.0.1 — Hotfix: remove leftover Phase 1 dialog artifacts
The abandoned-v0.5-AutoDrive Phase 1 work left `From silo:` / `To buyer:` MultiTextOption widgets in `BookActionDialog`. v0.5.0.0's polish pass kept them (intent: silent plumbing for v0.6 to reuse) but at runtime the widgets defaulted to visible with a stray AD marker name ("Animal Dealer Bales") and overlapped the Cancel button. Fix: strip the four picker `<Text>`/`<MultiTextOption>` elements from `BookActionDialog.xml`, restore v0.4.2 vertical positioning of the five remaining widgets (title -30, context -85, btnNow -140, btnBest -200, btnCancel -290), revert the profile height 460 → 400. `BookActionDialog.lua` now has zero AD references — `populateADPickers`, `setPickersVisible`, `onPickerFromChanged`, `onPickerToChanged`, `resolvePickerSelection`, `logPhase1Book` and their call sites all removed. Four i18n keys (`ui_from`, `ui_to`, `ui_no_markers`, `ui_no_truck`) removed. `GrainCollection.lua` AD detection + helpers stay shipped (silent, no UI surface) for v0.6 to consume.

### 0.5.0 — Polish & Stability (shipped)

The original v0.5 AutoDrive dispatch plan was scrapped — AutoDrive's native loop-collection feature already covers it. v0.6 will be the buyer-haulier model instead. The AD detection helpers from v0.5 Phase 0 stay in place for v0.6 to reuse, but no new AD work shipped in v0.5.

What v0.5.0 actually delivers — polish only, no end-user behavioural change:

- `GrainCollection.DEBUG` flag (default `false`) + `GrainCollection.dbg()` helper. Every `[GC-VERIFY]` diagnostic line in the codebase now gates on `DEBUG`. End-user `log.txt` stays quiet during normal play; flip the flag to surface the full diagnostic stream.
- Load-time AD-detection lines keep printing unconditionally but lost the `[GC-VERIFY]` prefix: `[FS25_GrainCollection] AD=true source=...`. Booking confirmations, fulfilment lifecycle, F7 input registration, and tab-injection lines all stay unconditional (useful info even in production).
- Removed entirely: the `icon path=… exists=… size=-1` verify line and the `UVs passed to addPageTab: …` line. `size=-1` was a sandbox artifact (`io` not available), and the icon either renders or it doesn't — the verify line was noise.
- `GrainCollection:isGrainEligibleSilo(placeable)` filter — placeable is grain-eligible if at least one of its storages supports a fill type with registered sell points. Cleanly excludes diesel tanks (DIESEL has no sell points) at the placeable-walk gate instead of the previous side-effect "sellPoints=0 → drop row" behaviour. End-user result identical.
- Removed three duplicate l10n entries (`ui_balance`, `button_back`, `ui_total`) — vanilla FS25 already provides them. Removes our duplicate-key warnings from `log.txt` on load.

The two diagnostic helpers from Phase 0 (`listADTrucks(farmId)`, `listADMarkers()`) and the Phase 1 dialog plumbing (`getDefaultHaulageTruck`, `getADMarkerList`, From/To picker rows in BookActionDialog) all stay shipped — even though they're not yet consumed for dispatch. v0.6's buyer-haulier model will read from these.

**(Historical) Phase 1 — BookActionDialog From/To pickers.** UI-only; selections logged but NOT persisted in booking records (Phase 2's job). Auto-selects haulage truck via layered fallback (grain-compatible trailer > any trailer > any AD-equipped vehicle); the truck picker itself is not exposed in this phase. Dialog height grows from 400 → 460 to fit the two `MultiTextOption` picker rows between the context line and button stack. Pickers default `visible="false"` and are revealed only when AD detected + truck resolves + ≥1 marker exists. Two new log lines: `[GC-VERIFY] Phase1 dialog: AD=… truck=… reason=… markers=…` on open, `[GC-VERIFY] Phase1 book(now|best): truck=… from=… to=…` on confirm. Booking record schema untouched (Phase 2).

**Phase 0 — Detection plumbing.** Adds three AD-aware functions to `scripts/GrainCollection.lua` and a diagnostic log line; no UI, no behaviour change, no dispatch.

- `GrainCollection:detectAutoDrive()` — runs at end of `loadMap`. Caches `GrainCollection.AD` (FS25_AutoDrive.AutoDrive), `GrainCollection.ADGraph` (FS25_AutoDrive.ADGraphManager), `GrainCollection.adAvailable` flag. Primary path uses `g_modIsLoaded["FS25_AutoDrive"]` + the namespace wrapper; fallback checks bare `_G.AutoDrive` for renamed mod folders.
- `GrainCollection:listADTrucks(farmId)` — walks `g_currentMission.vehicleSystem.vehicles`, filters to AD-equipped (`vehicle.ad ~= nil`) farm-owned vehicles. Returns `{object, name, available, objectId}` per truck. `available = not stateModule:isActive()`.
- `GrainCollection:listADMarkers()` — wraps `AutoDrive:GetAvailableDestinations()`. Returns `{id, name, x, y, z}` per marker, sorted alphabetically by name.
- New config constants (one place to tune in v0.5.x): `AD_ARRIVAL_THRESHOLD_M=30`, `AD_ROUTE_TIMEOUT_HOURS=6`, `AD_POLL_INTERVAL_SECONDS=5`.
- `[GC-VERIFY] AD=true|false trucks=N (available=N) markers=M` log line added to `InGameMenuProduceCollection:logDialogState` so detection success can be confirmed from `log.txt` without entering the booking flow.
- Phase 0 does NOT yet read these values for any branching. v0.4.x behaviour is identical with or without AD installed.

Phases 1-4 to follow: dialog pickers (Phase 1) → debug-flag-gated dispatch (Phase 2) → verification gate (Phase 2.5) → polling + completion + 0%-haulage-on-AD branching (Phase 3) → edge cases + ship (Phase 4). See `v0.5_AUTODRIVE_DESIGN.md`.

### 0.4.4 — View Bookings button repositioned + scrollbar verification
- **View Bookings button**: relocated from a free-floating sibling of the header panel (at Y=-100, in the table area, fine with 2 rows but collided with row 3+'s BOOK column once Saxlingham loaded with 4 grain types) to inside `fs25_menuHeaderPanel`, anchored middle-right with X=-310 to clear the BALANCE pill. Now lives in the header bar regardless of row count.
- **Scrollbar diagnostic**: `reloadFromBackend` now emits a `[GC-VERIFY] table: N rows x 32px = Mpx content, list visible ~Lpx, scrollable=...` line so scrolling activation can be confirmed from log.txt.
- **Debug row pad**: optional `DEBUG_PAD_ROWS` flag (default off) in `InGameMenuProduceCollection.lua` that duplicates the first row up to 12 entries for manual scroll testing. Flip to true, build, test, flip back before shipping.

### 0.4.3 — Empty-state centering + sidebar tab icon restyle
Two cosmetic fixes consolidated into one release.

- **Empty-state centering**: "No pending bookings." was rendering bottom-left in `ProduceBookingsDialog`, overlapping the button strip. Cause was the same `fs25_dialogContentContainer` auto-layout interference fixed for BookActionDialog in v0.4.2. Fix: new `gc_emptyState` profile (`anchorMiddleCenter pivotMiddleCenter`) AND the Text widget moved out of the content container to sit as a direct sibling of `dialogElement`, so its anchor resolves against the dialog frame directly.
- **Sidebar tab icon**: replaced the coloured "GRAIN" badge with a 128×128 white-line-art DDS (silo with dome top + horizontal collection arrow) on transparent background. Matches the FS25 sidebar convention (map / calendar / papers / cow icons) so the engine's selection-state tint actually works. First attempt at the icon (uncompressed A8R8G8B8, no mipmaps) was silently rejected by FS25's UI texture loader — sidebar slot rendered blank. **Fix**: encoded as **BC1/DXT1 with full 8-level mipmap chain**, matching TSStockCheck's header structure exactly (`dwFlags=0xA1007`, `caps=0x401008`). Generator script (`build_icon.ps1`) ships in the repo: PowerShell + System.Drawing for the line art, hand-rolled BC1 encoder (transparency mode: `c0=0x0000`, `c1=0xFFFF`, white=index 1, transparent=index 3), then concatenated with a DDS header matching the proven sidebar convention. Re-runnable any time. UV coordinates in `GrainCollection:fixInGameMenu` updated from `{0,0,1024,1024}` to `{0,0,128,128}` to match new dimensions.
- **Load-time verification**: `[GC-VERIFY] icon path=… exists=…` line emitted from `fixInGameMenu` so icon-load success can be confirmed from `log.txt`.

### 0.4.2 — Text polish
- **BOOK dialog layout**: removed the `fs25_dialogContentContainer` wrapper from `BookActionDialog.xml`. The container's internal anchor logic was repositioning the context line on top of the BOOK BEST button. Title + context + 3 buttons now sit directly under `dialogElement` with explicit `position` + `size` per widget. Dialog height bumped 340 → 400 for safe spacing.
- **Resolved-position logging**: `BookActionDialog:logDialogState()` now prints each widget's `absPosition` and `size` so layout regressions can be diagnosed from `log.txt` without screenshots.
- **Bookings dialog width**: dialog 780 → 920, list 740 → 880, subtitle column 440 → 560. Long prices like `~£12,345` no longer truncate.
- **Price precision**: dialog context line dropped from `%.3f` to `%.2f` (e.g. `£0.59/L`). Main table keeps integer rounding; notifications stay integer.
- **Bookings row click logging**: row selection in `ProduceBookingsDialog` now emits `[GC-VERIFY]` lines matching the main table's diagnostic robustness.

### 0.4.1 — Polish pass on the v0.4.0 table
Visual fixes only — no logic changes. Shipped after v0.4.0 proved the booking flow works end-to-end.
- **BookActionDialog**: removed `fs25_dialogButtonBox` + `buttonOK`/`buttonBack` (whose embedded keyboard-hint icons split long button labels across two lines). Replaced with three vertically-stacked custom-profile Buttons (`gc_dialogButtonWide` / `Recommended` / `Cancel`) each carrying the full descriptive label ("BOOK NOW — collected this month, ~£X"). Dialog shrunk from 640×400 to 720×340; content fills the body.
- **Table headers / rows**: shifted Best Month column from x=1150 to x=1180 and BOOK column from x=1260 to x=1300, eliminating the "MAX VALUEBEST MONTH" / "£167Jan Y1" collisions.
- **Sort indicators**: defaulted all 8 sort-direction Bitmaps to `visible="false"` in XML; added `refreshSortIcons()` that shows the active one on frame open + after each sort toggle. Removes the stray ▪ markers.
- **View Bookings button**: converted from `<Bitmap onClick>` (fragile, was anchored middle-left which positioned it into the sidebar) to a real `<Button>` widget anchored top-right via `anchorTopRight pivotTopRight`.
- **Unit consistency**: `formatLitres()` helper replaces `g_i18n:formatVolume()` everywhere — FS25's volume formatter varies between 'l' and 'L' depending on overload, so we format the number ourselves and append " L" once.

### 0.4.0 — TSStockCheck-pattern table + Book button
Pivoted away from the custom standalone TabbedMenu (which had hit the same row-rendering bug twice across two sessions of wizard iteration) and instead adopted the proven TSStockCheck (4.9★, 1,558 ratings) pattern: **inject a single info-dense table tab into the in-game menu next to Prices, then add a BOOK button per row.** TSStockCheck tells you when to sell — we tell you when to sell *and* let you book it.

Architecture:
- Tab injection via the Courseplay/TSStockCheck `fixInGameMenu` pattern. Slotted just before `pageStatistics`. Custom `guiProfiles.xml` loaded at startup; main frame + two modal dialogs registered in `loadMap`.
- Aggregated bookings (per-fillType, summed across silos) restored as the data model. Booking record schema: `fillTypeIndex, litres, dueDay, pricePerLitre, totalNet, unloadingStationName, targetMonthLabel`. MP event + save XML updated to match. Fulfilment drains across every matching silo until the booked total is satisfied.
- **Per-month price projection** now uses vanilla `fillType.economy.factors[period]` (the TSStockCheck finding) — so the "Max Value" and "Best Month" columns are real seasonal-curve projections, not "no projection available" as v0.3.0 thought.
- Colour coding copied from TSStockCheck (0.90 yellow / 0.95 dark green / ≥1.0 bright green, with colour-blind palette swap).
- BOOK button per row → 3-option modal: Book Now, Book {bestMonth} [recommended], Cancel. Modal calls back into the tab with the choice; tab calls `GrainCollection:bookCollection`.
- "View Bookings (N)" header button → modal listing pending bookings with Cancel + Close.
- F7 kept as a one-line shortcut: opens InGameMenu and selects the Produce Collection page.
- Verification guardrail: each dialog logs `[GC-VERIFY]` lines on open (frame name, visible state, button labels, nil-field check) so render success can be confirmed from `log.txt` rather than by code inspection.

Deleted: `GrainCollectionMenu.{lua,xml}`, `GrainCollectionSilosFrame.{lua,xml}`, `GrainCollectionBookingsFrame.{lua,xml}`.
New: `InGameMenuProduceCollection.{lua,xml}`, `BookActionDialog.{lua,xml}`, `ProduceBookingsDialog.{lua,xml}`, `guiProfiles.xml`.

### 0.3.0 — Native FS25 GUI rewrite
Replaced the `renderText` overlay with a proper full-screen `TabbedMenu` panel modelled on EasyDevControls. Shipped after four phases of testing:

- **Phase 1**: empty `TabbedMenu` loads from a keybind. Verified registration + frame indexing.
- **Phase 2**: Silos tab populated with a native `SmoothList`. Sell-points + price discovery surfaced inline.
- **Phase 3**: per-silo detail pane (sell-point cycler + date cycler + estimated quote). Interaction migrated to the bottom button strip (native FS25 pattern) after in-body widgets caused auto-booking and rendering issues.
- **Phase 3.5**: extended lead-day range from 7 → 365 days with a staggered step ladder. Switched pricing to Option C — booking shows an estimate; the actual payout uses the collection-day price (re-queries the booked station's live `getEffectiveFillTypePrice` with a graceful fallback). The MIN_LOAD_LITRES guard still gates collection so an emptied silo just cancels with a notification.
- **Phase 3.6**: adaptive date cadence — ladder built from `env.daysPerPeriod` so each "monthly" click moves exactly one in-game month regardless of game speed. Date labels became `"May Y1"` / `"Jan Y2"` instead of `"In 90 days"`.
- **Phase 4**: Bookings tab (list + Cancel on the bottom strip). F7 cut over to the new menu. Old overlay (`GrainCollectionGui.lua`) deleted. F8 dev keybind removed.

Other 0.3.0 details: `g_currentMission.environment` reads (`daysPerPeriod`, `currentPeriod`, `currentDayInPeriod`, `currentYear`) used to compute future-period labels. Build script (`build.ps1`) uses `System.IO.Compression.ZipArchive` directly so entries use forward slashes (PowerShell's `Compress-Archive` writes backslashes that FS25 can't read).

## Active roadmap

### 0.5.0 — Physical truck integration via AutoDrive  **← next active milestone**
Until now collections are purely abstract: the silo decrements and money appears. Make it feel real by routing a truck. This is the feature that gets the mod shared on YouTube and r/farmingsimulator — Courseplay/AutoDrive content is the dominant FS Lua-mod content category, and a "merchant truck actually drives up to your farm" pitch is concrete enough to clip.

- Detect **AutoDrive** on load. Check `g_modIsLoaded["FS22_AutoDrive"]` / `["FS25_AutoDrive"]` and the global `AutoDrive` table for presence; cache the resolved version. Surface AD-dependent UI only when AD is present; otherwise stay on the v0.3.0 instant-collection path.
- Player places a **pickup waypoint** near each silo (an AD destination marker) — explicit, because real silo yards are tight and we can't safely auto-pathfind a truck in. Remember the waypoint name per `placeableId` in the save XML.
- On the booked hour, spawn or route a truck. Two implementation options to evaluate first session:
  - **(a) AD-driven**: tell AutoDrive to dispatch one of the player's existing trucks to the pickup waypoint, then to the sell point. Minimal new code; depends on AD's vehicle picker.
  - **(b) Mod-spawned**: spawn a dedicated merchant truck at the AD network's spawn waypoint, route via AD, despawn at end of trip. More work, fully self-contained, doesn't tie up the player's vehicles.
- Cinematic fill at the silo (mod-driven, not via vanilla trigger), then route to the chosen sell point and do a cinematic unload.
- Optional polish: loading animation, dust particles, idle engine SFX at the silo while filling.
- Fallback stays intact: if AutoDrive isn't installed, the v0.3.0 instant-collection flow runs unchanged.

### 0.5.x — Multi-trip and multi-truck collections
A single small truck can't move 50,000 L of wheat in one go. The booking should reflect that.
- A booking with `litres > truck_capacity` spawns either multiple trips by one truck, or a convoy of multiple trucks (player-configurable per booking).
- Settings: max trucks per booking, max trips per truck, default truck capacity (or auto-detect from the chosen vehicle).
- Trips spread across **realistic working-day hours** (e.g. 7am–6pm), not all bunched at 9am — staggered arrivals look like a working hauler.
- Pricing still uses Option C per trip; haulage fee applies per-trip rather than per-booking only if we want to discourage micro-trips later.
- Depends on 0.5.0 being solid (multi-truck without physical trucks doesn't really mean anything).

### 0.6.x — Polish on the v0.4.0 table
Revisit only after AutoDrive integration ships.
- "Sell Points" matrix: matrix of all sell points × all fill types with current prices, like vanilla Prices but cross-tabulated.
- "Settings" tab/dialog: haulage %, min load litres, max lead days exposed to the player.
- Custom 64×64 tab icons (placeholder reuses the 1024×1024 mod icon).
- Per-silo drill-down dialog (TSStockCheck has one — shows which silos hold the selected grain). Useful for verifying aggregated bookings.
- All-sell-points dialog ranked by price (also from TSStockCheck) — answers "where would I get the best deal RIGHT NOW for this grain".
- Distance column (calculated from player position to best buyer, like TSStockCheck does via `calcDistanceFrom`).
- Multi-language i18n (TSStockCheck ships de/es/fr/pl/ru — we have en only).

## Open questions / risks
- ~~**Price forecasting**: vanilla FS25 doesn't expose a `getPricePerLitre(fillType, futureDay)` API…~~ **Resolved in 0.3.0**: the in-game Prices menu already shows the seasonal curve, so the player has the forecast — the mod just needs to honour the collection-day price (Option C), which it does.
- **AutoDrive compatibility surface**: AD's API shifts between major versions. v0.5.0 needs a compatibility check on load and a graceful fallback if the AD version we expect isn't present.
- **Husbandry sources**: milk/eggs/wool currently work only if they land in a normal storage placeable. Direct husbandry pickup (milk in the dairy itself) needs separate discovery paths and is parked until there's user demand.
- **Multiplayer**: event sync code exists but no real MP testing yet. Treat as alpha until someone runs a dedicated session.
