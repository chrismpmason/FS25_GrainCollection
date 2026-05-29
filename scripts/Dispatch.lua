--
-- Dispatch.lua — merchant haulier dispatch (AutoDrive path).
--
-- Production dispatch for the AutoDrive fulfilment mode. When a booking
-- reaches its due hour and the player has AutoDrive set up,
-- GrainCollection:processCollection hands the booking here via
-- Dispatch:startCollectionForBooking. We spawn the merchant vehicle
-- at the player's arrival marker, let AutoDrive drive it to the silo,
-- direct-load grain (capped to the booked amount), let AutoDrive
-- drive it to the buyer's nearest marker, despawn, and settle the
-- payout once at the end via GrainCollection:settleBookingPayout —
-- the same shared helper the instant path uses, so the two routes
-- pay identical nets to the penny.
--
-- For booked totals larger than one truck load the dispatcher loops
-- multi-trip until the booking is fulfilled (or MAX_TRIPS / silo-empty
-- ends it).
--

Dispatch = {}
Dispatch.MOD_NAME = g_currentModName or "FS25_GrainCollection"

Dispatch.dispatchInProgress = false
Dispatch.dispatchCount      = 0
Dispatch.activeVehicle      = nil

-- Merchant vehicle: vanilla Lizard MultiPurpose "Dragon" with the
-- Extension configurationSet applied. Single vehicle (no trailer) so
-- it fits universally on tight maps. ~7,600 L grain capacity. The
-- configuration indices below match the vanilla XML's Extension set
-- (animation 2, cylindered 2, fillVolume 2, fillUnit 2, trailer 2,
-- dischargeable 2, tensionBelts 3). Applied via
-- VehicleLoadingData:setConfigurations at spawn time.
Dispatch.VEHICLE_XML            = "data/vehicles/lizard/multiPurposeTruck/multiPurposeTruck.xml"
Dispatch.VEHICLE_CONFIGURATIONS = {
    animation     = 2,
    cylindered    = 2,
    fillVolume    = 2,
    fillUnit      = 2,
    trailer       = 2,
    dischargeable = 2,
    tensionBelts  = 3,
}

-- v0.7: FH16+Krampe combo, reserved for the vehicle-selection feature.
-- The bundle XML stays in vehicles/ and the resolveBundleStoreItem
-- helper stays defined below, but neither is currently spawned. The
-- modDesc <storeItem> entry is commented out so the bundle does not
-- load. Restore by re-enabling the storeItem and routing beginSpawn
-- through resolveBundleStoreItem for whichever vehicle the player
-- picks.
Dispatch.BUNDLE_XML_SUFFIX  = "fh16KrampeBundle.xml"
Dispatch.BUNDLE_NAME        = "Grain Haulier (FH16 + SKS 30/1050)"

-- AutoDrive per-vehicle cornerSpeed index. Index 1 = 0.5 = "50%" —
-- corners taken at half AutoDrive's default cornering curve.
Dispatch.AD_CORNER_SPEED_INDEX = 1

-- Multi-trip collection config.
Dispatch.SPAWN_DISTANCE           = 50      -- metres back from the silo AI node
Dispatch.BETWEEN_TRIPS_DELAY_MS   = 8000    -- ms; pause between trips
Dispatch.MAX_TRIPS                = 10      -- runaway guard
Dispatch.PRICE_PER_LITRE_FALLBACK = 0.30    -- £/L if economy lookup fails

-- Proximity arrival radii. AutoDrive can wedge trying to dock at tight
-- markers; we treat the leg as complete and stop AD cleanly once the
-- truck is within the leg's radius. Buyer wider than silo because
-- unload approach roads tend to be wider than silo aprons.
Dispatch.ARRIVAL_RADIUS        = 20     -- silo leg
Dispatch.BUYER_ARRIVAL_RADIUS  = 30     -- buyer leg
Dispatch.proximityLogAcc       = 0

-- Collection (multi-trip) state. A "collection" = one BOOK click:
-- spawn → silo → load → buyer → sell → despawn, repeated until the
-- silo is empty or MAX_TRIPS is reached.
Dispatch.tripState                  = "idle"  -- idle | active | between-trips
Dispatch.tripNumber                 = 0
Dispatch.tripSaleDone               = false
Dispatch.tripLoadedLitres           = 0
Dispatch.betweenTripsTimer          = nil
Dispatch.collectionLoadingStation   = nil
Dispatch.collectionUnloadingStation = nil
Dispatch.collectionFillType         = nil
Dispatch.collectionTotalLitres      = 0
Dispatch.collectionTotalPaid        = 0
Dispatch.collectionSpawn            = nil   -- {x, y, z, dirX, dirZ}
Dispatch.collectionGrainStorage     = nil
Dispatch.collectionGrainPlaceable   = nil
-- v0.6.x CP3 booking-driven dispatch. When a GrainCollection booking
-- reaches its due hour and AutoDrive is ready, processCollection hands
-- it off to startCollectionForBooking, which sets these two fields.
-- collectionLitresCap bounds the multi-trip total at the booked amount
-- (the silo may hold more — only deliver what was actually booked).
-- collectionBookingId is removed from GrainCollection.bookings when
-- endCollection runs, so the reservation is released.
Dispatch.collectionBookingId        = nil
Dispatch.collectionLitresCap        = nil
-- v0.6.x haulage parity: booking-time price estimate, snapshotted at
-- dispatch. Used as the fallback in endCollection's live-price lookup
-- so a transient station-query failure doesn't drop the payout to £0.
Dispatch.collectionBookingPriceEst  = nil

-- AutoDrive driving state.
Dispatch.AD_MATCH_RADIUS   = 50     -- m; max silo/buyer -> marker distance
Dispatch.adLeg             = nil    -- nil | "to-silo" | "to-buyer"
Dispatch.adLegTruck        = nil
Dispatch.adTrailer         = nil    -- nil for the Lizard; populated for v0.7 combo
Dispatch.adSiloMarkerId    = nil
Dispatch.adBuyerMarkerId   = nil    -- proximity-matched to best buyer
Dispatch.adSpawnMarkerId   = nil    -- player-set merchant arrival marker
Dispatch.adSiloMarkerPos   = nil    -- {x, z}
Dispatch.adBuyerMarkerPos  = nil    -- {x, z}
Dispatch.adSpawnMarkerPos  = nil    -- {x, y, z}
Dispatch.adLegPollAcc      = 0

local function logf(fmt, ...)
    print(string.format("[FS25_GrainCollection][Dispatch] " .. fmt, ...))
end

-- v0.5.99.8: resolve a task's class name. Direct reference comparison
-- against the job's named task slots always works; ClassUtil falls back
-- if we somehow see a task not on the known list. The post-setValues
-- dump in v0.5.99.7 was printing class=? because pcall(ClassUtil.getClassNameByObject)
-- returned an empty string on these task instances — direct comparison
-- side-steps whatever ClassUtil quirk is at play.
-- (FillUnit.lua:1485).
function Dispatch:doDirectLoad(job)
    local src      = Dispatch.collectionGrainStorage
        or (job.loadingStationParameter and job.loadingStationParameter:getLoadingStation())
    local fillType = job.fillTypeParameter and job.fillTypeParameter:getFillTypeIndex()
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    local nodes    = job.loadingNodeInfos or {}
    if src == nil or fillType == nil or #nodes == 0 then
        logf("[direct-load] ABORT: grainSource=%s fillType=%s loadingNodeInfos=%d",
            tostring(src), tostring(fillType), #nodes)
        return
    end
    if src.getFillLevel == nil then
        logf("[direct-load] ABORT: grain source has no getFillLevel")
        return
    end
    local toolType = (ToolType ~= nil and ToolType.TRIGGER) or nil
    local ftDesc   = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
    local ftName   = (ftDesc and ftDesc.name) or tostring(fillType)
    for _, info in ipairs(nodes) do
        local v, fui = info.vehicle, info.fillUnitIndex
        if v ~= nil and fui ~= nil then
            local freeCap = (v.getFillUnitFreeCapacity and v:getFillUnitFreeCapacity(fui)) or 0
            local before  = (src:getFillLevel(fillType, farmId)) or 0
            local want    = math.min(freeCap, before)
            -- v0.6.x CP3: when booking-driven, cap the take so total
            -- delivered ≤ booking.litres. Previous trips count via
            -- collectionTotalLitres; this trip so far via tripLoadedLitres.
            if Dispatch.collectionLitresCap ~= nil then
                local remaining = Dispatch.collectionLitresCap
                    - (Dispatch.collectionTotalLitres or 0)
                    - (Dispatch.tripLoadedLitres or 0)
                want = math.min(want, math.max(0, remaining))
            end
            if want > 0 then
                -- Drain the silo FIRST; add to the truck only what the
                -- silo actually gave up (measured by the level delta).
                if src.removeFillLevel ~= nil then
                    local ok, err = pcall(src.removeFillLevel, src, fillType, want, farmId)
                    if not ok then logf("[direct-load] removeFillLevel failed: %s", tostring(err)) end
                elseif src.setFillLevel ~= nil then
                    local ok, err = pcall(src.setFillLevel, src, before - want, fillType)
                    if not ok then logf("[direct-load] setFillLevel failed: %s", tostring(err)) end
                else
                    logf("[direct-load] grain source exposes neither removeFillLevel nor setFillLevel")
                end
                local afterSrc = (src:getFillLevel(fillType, farmId)) or 0
                local removed  = before - afterSrc
                local tBefore  = (v.getFillUnitFillLevel and v:getFillUnitFillLevel(fui)) or 0
                if removed > 0 and v.addFillUnitFillLevel ~= nil then
                    local ok, err = pcall(v.addFillUnitFillLevel, v, farmId, fui, removed, fillType, toolType, nil)
                    if not ok then logf("[direct-load] addFillUnitFillLevel failed: %s", tostring(err)) end
                end
                local tAfter = (v.getFillUnitFillLevel and v:getFillUnitFillLevel(fui)) or 0
                -- v0.5.99.28: accumulate the authoritative amount actually
                -- taken FROM THE SILO (the source level delta cannot be
                -- fooled by duplicate fillUnit indices).
                Dispatch.tripLoadedLitres = Dispatch.tripLoadedLitres + removed
            end
        end
    end
end

-- Direct UNLOAD: truck fill units -> unloadStation. UnloadingStation's
-- add-fill API is not in the public dataS dump (the file is stripped),
-- so the destination add is best-effort: try station:addFillLevel,
-- then storage iteration (targetStorages/sourceStorages/storages —
-- mirrors LoadingStation:removeFillLevel + GrainCollection.lua's own
-- proven storage:setFillLevel drain). Whatever path works is logged;
-- In-game toast helper. Uses g_currentMission:addIngameNotification
-- ("ok" = green, "info" = blue, "critical" = red). pcall-wrapped so a
-- missing API never breaks the dispatch flow.
local function gcToast(text, severity)
    if g_currentMission == nil or g_currentMission.addIngameNotification == nil then return end
    if FSBaseMission == nil then return end
    local kind = FSBaseMission.INGAME_NOTIFICATION_OK
    if severity == "info" then
        kind = FSBaseMission.INGAME_NOTIFICATION_INFO
    elseif severity == "critical" then
        kind = FSBaseMission.INGAME_NOTIFICATION_CRITICAL
    end
    pcall(g_currentMission.addIngameNotification, g_currentMission, kind, text)
end

function Dispatch:loadMap(name)
    logf("loaded — merchant haulier ready (AutoDrive)")
end

function Dispatch:update(dt)
    -- Between-trips delay countdown for multi-trip collections.
    if Dispatch.tripState == "between-trips"
            and Dispatch.betweenTripsTimer ~= nil then
        Dispatch.betweenTripsTimer = Dispatch.betweenTripsTimer - (dt or 0)
        if Dispatch.betweenTripsTimer <= 0 then
            Dispatch.betweenTripsTimer = nil
            pcall(Dispatch.startNextTrip, Dispatch)
        end
    end

    -- AutoDrive per-frame leg poll. Self-gates on adLeg; no-op when idle.
    pcall(Dispatch.updateAutoDrive, Dispatch, dt)
end

-- v0.5.99.8: per-task lifecycle tracker. Called every frame while a job
-- is active. For each task in job.tasks we keep a record of how many
-- times we've observed it transition into isRunning=true and into
-- isFinished=true. Also logs every internal `state` change (e.g.
-- v0.6.x CP3: walk the unloading stations and return the one whose name
-- matches `name`. Used by startCollectionForBooking to convert the
-- booking's stored station name back into a live station object.
function Dispatch:resolveStationByName(name)
    if name == nil or name == "" then return nil end
    if g_currentMission == nil or g_currentMission.storageSystem == nil
            or g_currentMission.storageSystem.getUnloadingStations == nil then
        return nil
    end
    for _, station in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        local stationName
        if station.getName ~= nil then
            local ok, n = pcall(station.getName, station)
            if ok and n then stationName = n end
        end
        if stationName == nil and station.owningPlaceable ~= nil
                and station.owningPlaceable.getName ~= nil then
            local ok, n = pcall(station.owningPlaceable.getName, station.owningPlaceable)
            if ok and n then stationName = n end
        end
        if stationName == name then return station end
    end
    return nil
end


-- v0.6.x CP3: fulfilment-time entry for a Phase 1 booking. Resolves the
-- booked station back from its name, builds a row-shaped object that the
-- existing dispatcher understands, sets the booking-cap state, and calls
-- startCollectionFromMenu. Returns (ok, message) — on failure the caller
-- (GrainCollection:processCollection) falls back to the instant path.
-- The booking-cap state is cleared on early failure so subsequent
-- bookings aren't tainted.
function Dispatch:startCollectionForBooking(booking)
    if booking == nil or booking.fillTypeIndex == nil then
        return false, "Invalid booking"
    end
    if Dispatch.tripState ~= "idle" or Dispatch.dispatchInProgress then
        return false, "A collection is already in progress"
    end

    local buyer = self:resolveStationByName(booking.unloadingStationName)
    if buyer == nil then
        logf("[BOOK-AD] booked buyer '%s' not found",
            tostring(booking.unloadingStationName))
        return false, "Booked buyer not found"
    end

    local row = {
        fillTypeIndex    = booking.fillTypeIndex,
        bestBuyerStation = buyer,
        bestBuyerName    = booking.unloadingStationName,
        hasSellPoint     = true,
    }

    -- Set cap + booking id BEFORE startCollectionFromMenu so the cap is
    -- in place when the first doDirectLoad fires. If startCollectionFromMenu
    -- fails early (no merchant marker, no silo, etc.) we clear them so
    -- the caller's fallback path runs with clean state.
    Dispatch.collectionBookingId        = booking.id
    Dispatch.collectionLitresCap        = booking.litres
    Dispatch.collectionBookingPriceEst  = booking.pricePerLitre

    local ok, msg = self:startCollectionFromMenu(row)
    if not ok then
        Dispatch.collectionBookingId = nil
        Dispatch.collectionLitresCap = nil
        return false, msg
    end
    return true
end


-- BOOK click entry point. Resolves the row's fillType + best buyer +
-- owned silo, matches AutoDrive markers, then kicks off the multi-trip
-- collection. Returns (ok, message, needsPicker) — the menu uses
-- needsPicker=true to open the marker picker when the player hasn't
-- yet set a merchant arrival point.
function Dispatch:startCollectionFromMenu(row)
    if g_currentMission == nil or not g_currentMission:getIsClient() then
        return false, "Not in an active game"
    end
    if row == nil or row.fillTypeIndex == nil then
        return false, "Invalid produce row"
    end
    if Dispatch.tripState ~= "idle" or Dispatch.dispatchInProgress then
        logf("[BOOK] collection already running (state=%s, trip %d) — ignoring",
            tostring(Dispatch.tripState), Dispatch.tripNumber)
        return false, "A collection is already in progress"
    end

    local farmId        = g_currentMission:getFarmId()
    local fillTypeIndex = row.fillTypeIndex
    local ft     = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local ftName = (ft and ft.title) or tostring(fillTypeIndex)

    -- Grain-only guard (the haulier collects grain).
    local grainSet = self:getGrainFillTypeSet()
    if grainSet[fillTypeIndex] == nil then
        return false, "Only grain can be collected (Barley, Canola, Oat, Wheat)"
    end

    -- v0.6: the merchant arrival marker (per farm) is the SPAWN point
    -- only — despawn happens at the buyer marker. If unset, return
    -- needsPicker=true so the menu opens the marker picker rather than
    -- dispatching to a bad point.
    local merchantId = nil
    if GrainCollection ~= nil and GrainCollection.getMerchantMarker ~= nil then
        merchantId = GrainCollection:getMerchantMarker(farmId)
    end
    if merchantId == nil then
        return false, "Choose a merchant arrival point first", true
    end

    -- The buyer is the row's best buyer — not a proximity pick.
    local buyer = row.bestBuyerStation
    if buyer == nil or not row.hasSellPoint then
        return false, "No buyer available for " .. ftName
    end

    -- The silo holding THIS fill type (most stock).
    local loadingStation, fillLevel, _, grainStorage, grainPlaceable =
        self:findLoadingStation(farmId, fillTypeIndex)
    if loadingStation == nil then
        return false, "No reachable silo holds " .. ftName
    end

    Dispatch.collectionLoadingStation   = loadingStation
    Dispatch.collectionUnloadingStation = buyer
    Dispatch.collectionFillType         = fillTypeIndex
    Dispatch.collectionGrainStorage     = grainStorage
    Dispatch.collectionGrainPlaceable   = grainPlaceable
    Dispatch.collectionTotalLitres      = 0
    Dispatch.collectionTotalPaid        = 0
    Dispatch.tripNumber                 = 0
    Dispatch.dispatchCount = Dispatch.dispatchCount + 1

    -- Match three markers up front: silo (proximity), buyer (proximity to
    -- best buyer), spawn (player-chosen merchant arrival). If any fails
    -- we abort BEFORE spawning — matchADMarkers has toasted the player.
    if not Dispatch:matchADMarkers(merchantId) then
        Dispatch:endCollection("AutoDrive marker match failed")
        return false, "Could not match AutoDrive markers — see log"
    end

    -- v0.6 (restored): one-way trip. Spawn at the player's merchant
    -- arrival marker, drive to the silo (load), drive to the buyer
    -- (sale + despawn). Heading on spawn faces the silo so the truck
    -- noses out the right way.
    -- HISTORY: v0.5.99.46 used a return-to-spawn workaround — spawn
    -- and despawn were both the merchant marker, buyer was purely
    -- financial. Future cleanup pass can drop this HISTORY block once
    -- the restored flow has soaked.
    local sp = Dispatch.adSpawnMarkerPos
    local sm = Dispatch.adSiloMarkerPos
    if sp == nil then
        Dispatch:endCollection("merchant marker has no position")
        return false, "The merchant arrival marker has no position"
    end
    local dirX, dirZ = 0, 1
    if sm ~= nil then
        local vx, vz = sm.x - sp.x, sm.z - sp.z
        local len = math.sqrt(vx * vx + vz * vz)
        if len > 0.01 then dirX, dirZ = vx / len, vz / len end
    end
    Dispatch.collectionSpawn = { x = sp.x, z = sp.z, dirX = dirX, dirZ = dirZ }

    Dispatch:startNextTrip()
    return true, string.format("Merchant dispatched to collect %s", ftName)
end

-- v0.5.99.30: F9 sets the merchant-truck PICKUP LOCATION — it captures
-- the player's current world position + facing and stores it (per farm,
-- persisted) via GrainCollection. The truck then spawns/despawns there.
-- (F9 and F10 previously both started a collection — F9 was redundant.)
function Dispatch:resolveBundleStoreItem()
    if g_storeManager == nil then return nil end
    local suffix = Dispatch.BUNDLE_XML_SUFFIX

    if type(g_storeManager.getItemByXMLFilename) == "function" then
        for _, name in ipairs({ suffix, "vehicles/" .. suffix }) do
            local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, name)
            if ok and item ~= nil then return item end
        end
    end

    local items = nil
    if type(g_storeManager.getItems) == "function" then
        local ok, r = pcall(g_storeManager.getItems, g_storeManager)
        if ok then items = r end
    end
    items = items or g_storeManager.items
    if type(items) == "table" then
        for _, item in pairs(items) do
            if type(item) == "table" then
                local fn = item.xmlFilename
                if type(fn) == "string"
                        and string.find(fn:lower(), suffix:lower(), 1, true) ~= nil then
                    return item
                end
                if item.name == Dispatch.BUNDLE_NAME then
                    return item
                end
            end
        end
    end
    return nil
end

function Dispatch:beginSpawn(overrideX, overrideZ, headingDirX, headingDirZ)
    if not g_currentMission:getIsServer() then
        logf("ABORT: not server — AISystem:startJob requires isServer (line 541 of AISystem.lua)")
        return
    end

    local spawnX, spawnZ
    if overrideX ~= nil and overrideZ ~= nil then
        spawnX, spawnZ = overrideX, overrideZ
    else
        local playerNode = (g_localPlayer ~= nil and g_localPlayer.getCurrentRootNode)
                            and g_localPlayer:getCurrentRootNode() or nil
        if playerNode == nil then
            logf("ABORT: cannot resolve player root node")
            return
        end
        local px, _, pz = getWorldTranslation(playerNode)
        local _, ry, _  = getWorldRotation(playerNode)
        spawnX = px + math.sin(ry) * 10
        spawnZ = pz + math.cos(ry) * 10
    end
    local farmId = g_currentMission:getFarmId()

    -- v0.6.x: spawn the vanilla Lizard MultiPurpose with the Extension
    -- configurationSet (7,600 L BULK fillUnit, single vehicle, no
    -- trailer to attach — fits on tight maps). The FH16+Krampe bundle
    -- path stays in this file but is unreachable; v0.7 selection UI
    -- will reintroduce it.
    local data = VehicleLoadingData.new()
    local storeItem = nil
    if g_storeManager ~= nil and type(g_storeManager.getItemByXMLFilename) == "function" then
        local ok, item = pcall(g_storeManager.getItemByXMLFilename,
            g_storeManager, Dispatch.VEHICLE_XML)
        if ok then storeItem = item end
    end
    if storeItem == nil then
        logf("ABORT: Lizard MultiPurpose store item not found at '%s' — vanilla install missing?",
            Dispatch.VEHICLE_XML)
        gcToast("Merchant vehicle missing — cannot dispatch", "critical")
        return
    end
    data:setStoreItem(storeItem)
    -- Extension configurationSet — adds the bodyExtension, lifts BULK
    -- capacity from 3,500 L to 7,600 L. Per-config indices declared at
    -- VEHICLE_CONFIGURATIONS up top.
    if type(data.setConfigurations) == "function" then
        data:setConfigurations(Dispatch.VEHICLE_CONFIGURATIONS)
    end
    if not data.isValid then
        logf("ABORT: VehicleLoadingData.isValid=false for Lizard MultiPurpose '%s'",
            tostring(storeItem.name))
        return
    end

    -- v0.6: sample actual terrain height at the spawn XZ rather than
    -- relying on the marker's stored Y. AutoDrive waypoints record Y at
    -- wheel/chassis height which can sit several metres off the ground,
    -- causing a visible drop on spawn. Pcall-guarded; on failure fall
    -- back to the marker Y (if known), otherwise nil for engine default.
    local markerY
    if Dispatch.adSpawnMarkerPos ~= nil then
        markerY = Dispatch.adSpawnMarkerPos.y
    end
    local terrainY
    if g_terrainNode ~= nil then
        local okT, ty = pcall(getTerrainHeightAtWorldPos, g_terrainNode, spawnX, 0, spawnZ)
        if okT and type(ty) == "number" then terrainY = ty end
    end
    local spawnY
    if terrainY ~= nil then
        spawnY = terrainY + 0.1   -- small lift so the chassis doesn't clip
    elseif markerY ~= nil then
        logf("[BOOK] WARN terrain sample failed at (%.1f, %.1f) — falling back to marker Y", spawnX, spawnZ)
        spawnY = markerY
    else
        logf("[BOOK] WARN terrain sample failed at (%.1f, %.1f) and no marker Y — using engine default", spawnX, spawnZ)
    end

    data:setPosition(spawnX, spawnY, spawnZ)
    -- v0.5.99.29: face the truck along the heading. yaw rotates around
    -- Y, forward = (sin(ry), cos(ry)), so ry = atan2(dirX, dirZ).
    -- v0.5.99.31: the truck spawned 180° opposite the player's F9
    -- facing (the player capture round-trips ry cleanly, so the flip
    -- is a coordinate-system quirk — player-character forward sign or
    -- the truck model's forward axis). Negate the heading to correct
    -- it. The [pickup] (capture) and [trip] (spawn) log lines record
    -- the raw values either side of the conversion for confirmation.
    if headingDirX ~= nil and headingDirZ ~= nil and data.setRotation ~= nil then
        local hx, hz = -headingDirX, -headingDirZ
        local ry = math.atan2(hx, hz)
        data:setRotation(0, ry, 0)
    end
    data:setPropertyState(VehiclePropertyState.MISSION)
    data:setOwnerFarmId(farmId)
    data:setIsSaved(false)

    Dispatch.dispatchInProgress = true
    data:load(Dispatch.onSpawned, Dispatch, nil)
end

function Dispatch:onSpawned(vehicles, loadState, args)
    local okState = (VehicleLoadingState ~= nil) and (loadState == VehicleLoadingState.OK)
    if not okState or vehicles == nil or #vehicles == 0 then
        Dispatch.dispatchInProgress = false
        logf("ABORT: spawn failed (loadState=%s vehicles=%d)",
            tostring(loadState), vehicles and #vehicles or 0)
        return
    end
    -- Identify the motorized truck (the AutoDrive root) and any grain
    -- trailer. The v0.6.x Lizard MultiPurpose spawns as a single
    -- motorized vehicle (trailer stays nil → adTrailer = nil → the
    -- truck's own fillUnits are used). The v0.7 bundle path will spawn
    -- two and this same loop picks truck + trailer.
    local truck, trailer
    for _, v in ipairs(vehicles) do
        if v ~= nil then
            if v.spec_motorized ~= nil then
                truck = truck or v
            else
                trailer = trailer or v
            end
        end
    end
    local vehicle = truck or vehicles[1]
    Dispatch.adTrailer = trailer

    -- v0.6.x: capacity check is layout-agnostic. The Lizard MultiPurpose
    -- is a rigid truck — grain rides on its own bed, no trailer needed.
    -- A tractor + trailer combo (reserved for v0.7) puts grain on the
    -- trailer. Either is fine; what matters is that SOMETHING in the
    -- bundle has a fillUnit that can hold the booked grain. Only warn
    -- when no vehicle in the bundle can carry it (e.g. wrong storeItem
    -- registered). Mirrors buildJobShim's source-resolution logic.
    local fillType = Dispatch.collectionFillType
    local grainCapable = false
    for _, v in ipairs(vehicles) do
        if v ~= nil and v.getFillUnits ~= nil then
            local okU, fillUnits = pcall(v.getFillUnits, v)
            if okU and fillUnits ~= nil then
                for _, fu in ipairs(fillUnits) do
                    if (fu.capacity or 0) > 0 then
                        local supports = fu.supportedFillTypes == nil
                            or fillType == nil
                            or fu.supportedFillTypes[fillType]
                        if supports then
                            grainCapable = true
                            break
                        end
                    end
                end
            end
        end
        if grainCapable then break end
    end
    if not grainCapable then
        logf("WARNING: no spawned vehicle has a fillUnit that can hold the booked grain")
    end

    -- AutoDrive is the only driving controller in v0.6.x. Hand the truck
    -- to the trip executor.
    Dispatch.activeVehicle = vehicle
    local okAD, errAD = pcall(Dispatch.startAutoDriveTrip,
        Dispatch, vehicle)
    if not okAD then
        logf("[AD-trip] startAutoDriveTrip EXCEPTION: %s", tostring(errAD))
        Dispatch.dispatchInProgress = false
        pcall(Dispatch.finishAutoDriveTrip, Dispatch, vehicle)
    end
end

-- =============================================================
-- Step 2: find stations + fillType, build job, validate, start
-- =============================================================

local function worldDistanceTo(obj, x, z)
    if obj == nil or obj.owningPlaceable == nil then
        if obj and obj.position then return math.sqrt((obj.position.x - x)^2 + (obj.position.z - z)^2) end
        return math.huge
    end
    local ox, _, oz = getWorldTranslation(obj.owningPlaceable.rootNode or 0)
    if ox == nil then return math.huge end
    return math.sqrt((ox - x)^2 + (oz - z)^2)
end

-- v0.5.99.33: the mod collects GRAIN only. Allow-list of grain fill
-- type internal names — the produce the Produce Collection menu
-- tracks. (No exact existing list to reuse: the menu's rows come from
-- getOwnedSilos, i.e. "whatever's in a spec_silo placeable that has a
-- sell point" — that already excludes lime stations because they
-- aren't spec_silo, but findLoadingStation iterates ALL loading
-- stations, which is how it could otherwise grab a Lime Station.)
Dispatch.GRAIN_FILLTYPES = { "BARLEY", "CANOLA", "OAT", "WHEAT" }

-- Lazily-resolved set of allowed grain fill-type indices (stable per
-- session once the fill-type manager is up).
function Dispatch:getGrainFillTypeSet()
    if Dispatch._grainSet ~= nil then return Dispatch._grainSet end
    local set = {}
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeIndexByName ~= nil then
        for _, name in ipairs(Dispatch.GRAIN_FILLTYPES) do
            local idx = g_fillTypeManager:getFillTypeIndexByName(name)
            if idx ~= nil then set[idx] = name end
        end
    end
    Dispatch._grainSet = set
    return set
end

-- v0.5.99.34 diagnostic helper: best-effort display name.
function Dispatch:resolveLoadingStation(placeable, grainObj)
    if placeable ~= nil then
        if placeable.spec_silo ~= nil and placeable.spec_silo.loadingStation ~= nil then
            return placeable.spec_silo.loadingStation, "spec_silo.loadingStation"
        end
        if placeable.spec_loadingStation ~= nil
                and placeable.spec_loadingStation.loadingStation ~= nil then
            return placeable.spec_loadingStation.loadingStation, "spec_loadingStation.loadingStation"
        end
    end
    if grainObj ~= nil and grainObj.getAITargetPositionAndDirection ~= nil
            and grainObj.removeFillLevel ~= nil then
        return grainObj, "grain object is itself a LoadingStation"
    end
    if g_currentMission.storageSystem ~= nil
            and g_currentMission.storageSystem.getLoadingStations ~= nil then
        for _, st in pairs(g_currentMission.storageSystem:getLoadingStations()) do
            if placeable ~= nil and st.owningPlaceable == placeable then
                return st, "global registry (owningPlaceable match)"
            end
            local srcs = st.sourceStorages
            if grainObj ~= nil and type(srcs) == "table" then
                for _, s in pairs(srcs) do
                    if s == grainObj then
                        return st, "global registry (sourceStorages match)"
                    end
                end
            end
        end
    end
    return nil, "none"
end

-- v0.5.99.37: grain discovery now reuses GrainCollection:getOwnedSilos
-- — the mod's own, proven finder (the F7 Produce Collection menu uses
-- it and correctly shows the Calmsden farmSilo01/02 oat). The old
-- getLoadingStations() + getAISupportedFillTypes() scan returned {}
-- for modded silos whose load triggers carry no aiNode.
-- Returns: loadingStation, fillLevel, fillTypeIndex, grainStorage, placeable.
-- restrictFillTypeIndex (optional): when set, only silos holding that
-- exact fill type are considered — used by the menu BOOK flow, where the
-- player picked a specific grain row. nil => best grain across the farm.
function Dispatch:findLoadingStation(farmId, restrictFillTypeIndex)
    local grainSet = self:getGrainFillTypeSet()

    if GrainCollection == nil or GrainCollection.getOwnedSilos == nil then
        logf("[findLoadingStation] GrainCollection:getOwnedSilos unavailable — cannot discover grain")
        return nil, 0, nil
    end
    local ok, silos = pcall(GrainCollection.getOwnedSilos, GrainCollection, farmId)
    if not ok or type(silos) ~= "table" then
        logf("[findLoadingStation] getOwnedSilos failed: %s", tostring(silos))
        return nil, 0, nil
    end

    -- Pick the grain entry with the most stock.
    local bestEntry = nil
    for _, e in ipairs(silos) do
        local fti = e.fillTypeIndex
        local lvl = e.fillLevel or 0
        if fti ~= nil and grainSet[fti] ~= nil and lvl > 0
                and (restrictFillTypeIndex == nil or fti == restrictFillTypeIndex) then
            if bestEntry == nil or lvl > (bestEntry.fillLevel or 0) then
                bestEntry = e
            end
        end
    end
    if bestEntry == nil then
        logf("[findLoadingStation] no grain found via getOwnedSilos")
        return nil, 0, nil
    end

    -- Resolve a LoadingStation for the AIJobLoadAndDeliver scaffolding.
    local station, how = self:resolveLoadingStation(bestEntry.placeable, bestEntry.storage)
    if station == nil then
        logf("[findLoadingStation] grain at '%s' but NO LoadingStation resolvable — skipping (the AI job needs one)",
            tostring(bestEntry.placeableName))
        return nil, 0, nil
    end
    -- The silo placeable's world position is the drive-to target. If
    -- getOwnedSilos found the storage without an owningPlaceable, recover
    -- the placeable from the resolved station.
    local placeable = bestEntry.placeable
    if placeable == nil and station ~= nil then
        placeable = station.owningPlaceable
    end

    return station, bestEntry.fillLevel or 0, bestEntry.fillTypeIndex,
        bestEntry.storage, placeable
end

-- v0.5.99.26: pick a real BUYER for the unload, not the loading silo.
-- The loading silo is itself an UnloadingStation and, being closest,
-- was previously chosen for both ends — grain just round-tripped.
-- Now: exclude the loading station's placeable; prefer a station named
-- "Animal Dealer Grain"; else the closest other accepting station;
-- final fallback (warned) is the loading station itself so the test
-- never crashes.
-- Returns: station, distance, pickLabel ("named" / "closest" / "fallback-same").
function Dispatch:findUnloadingStation(fillTypeIndex, farmId, refX, refZ, loadingStation)
    if g_currentMission.storageSystem == nil
            or g_currentMission.storageSystem.getUnloadingStations == nil then
        return nil
    end
    local PREFER_NAME = "animal dealer grain"
    local loadingPlaceable = loadingStation and loadingStation.owningPlaceable or nil

    local others, sameAsLoading = {}, {}
    for _, st in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        local accessible = g_currentMission.accessHandler == nil
            or g_currentMission.accessHandler:canPlayerAccess(st)
        if accessible and st.isa ~= nil and st:isa(UnloadingStation)
                and st.getAISupportedFillTypes ~= nil then
            local supported = st:getAISupportedFillTypes() or {}
            if supported[fillTypeIndex] then
                local isSame = (st == loadingStation)
                    or (loadingPlaceable ~= nil and st.owningPlaceable == loadingPlaceable)
                local entry = { st = st, dist = worldDistanceTo(st, refX, refZ) }
                table.insert(isSame and sameAsLoading or others, entry)
            end
        end
    end

    -- Preferred: a different-placeable station whose name matches.
    for _, e in ipairs(others) do
        local nm = (e.st.getName and e.st:getName()) or ""
        if string.find(string.lower(nm), PREFER_NAME, 1, true) then
            return e.st, e.dist, "named"
        end
    end
    -- Else: the closest different-placeable accepting station.
    local best, bestDist = nil, math.huge
    for _, e in ipairs(others) do
        if e.dist < bestDist then best, bestDist = e.st, e.dist end
    end
    if best ~= nil then return best, bestDist, "closest" end
    -- Final fallback: the loading station itself (caller logs a warning).
    local fb, fbDist = nil, math.huge
    for _, e in ipairs(sameAsLoading) do
        if e.dist < fbDist then fb, fbDist = e.st, e.dist end
    end
    if fb ~= nil then return fb, fbDist, "fallback-same" end
    return nil
end

-- v0.5.99.27: end the collection — log totals, reset state to idle.
function Dispatch:endCollection(reason)
    logf("[collection] COMPLETE (%s): %d trip(s), total %.0fL collected",
        tostring(reason), Dispatch.tripNumber,
        Dispatch.collectionTotalLitres)

    -- v0.6.x haulage-parity refactor: settle ONCE at the end via the
    -- shared GrainCollection helper. Both fulfilment paths feed the
    -- helper the booked litres and the live price queried at fulfilment
    -- moment, so the net payout is identical to the instant path's.
    -- Skip the settle on aborts that delivered nothing (marker match
    -- failed, no spawn point, etc. — those have already toasted their
    -- own error and shouldn't get a "Collection complete" banner).
    local bookingId = Dispatch.collectionBookingId
    if bookingId ~= nil
            and (Dispatch.collectionTotalLitres or 0) > 0
            and GrainCollection ~= nil
            and type(GrainCollection.settleBookingPayout) == "function" then
        -- Chargeable = min(delivered, booked). Caps any upward
        -- floating-point drift in the silo drain (the instant path
        -- does the same cap), and naturally handles silos-ran-short
        -- (delivered < booked → pay for what actually moved).
        local cap        = Dispatch.collectionLitresCap or 0
        local delivered  = Dispatch.collectionTotalLitres or 0
        local chargeable = math.min(delivered, cap)

        local farmId   = g_currentMission and g_currentMission:getFarmId()
        local fillType = Dispatch.collectionFillType
        local buyer    = Dispatch.collectionUnloadingStation
        local buyerName = (buyer and buyer.getName and buyer:getName()) or "?"
        local pricePerLitre = GrainCollection:getLiveSalePrice(buyer, fillType,
            Dispatch.collectionBookingPriceEst)

        local _, _, net = GrainCollection:settleBookingPayout(
            chargeable, pricePerLitre, fillType, farmId, buyerName)
        Dispatch.collectionTotalPaid = net or 0
    end

    -- Booking-driven cleanup: remove the booking record so the
    -- reservation is released and hourChanged doesn't replay it.
    -- Fires even on partial / failed dispatches once the chain started.
    if bookingId ~= nil and GrainCollection ~= nil
            and type(GrainCollection.removeBookingById) == "function" then
        local ok, err = pcall(GrainCollection.removeBookingById, GrainCollection, bookingId)
        if not ok then
            logf("[collection] removeBookingById failed for id=%s: %s",
                tostring(bookingId), tostring(err))
        end
    end
    Dispatch.tripState                  = "idle"
    Dispatch.betweenTripsTimer          = nil
    Dispatch.collectionLoadingStation   = nil
    Dispatch.collectionUnloadingStation = nil
    Dispatch.collectionFillType         = nil
    Dispatch.collectionSpawn            = nil
    Dispatch.collectionGrainStorage     = nil
    Dispatch.collectionGrainPlaceable   = nil
    Dispatch.collectionBookingId        = nil
    Dispatch.collectionLitresCap        = nil
    Dispatch.collectionBookingPriceEst  = nil
    Dispatch.adLeg                      = nil
    Dispatch.adLegTruck                 = nil
    Dispatch.adTrailer                  = nil
    Dispatch.adSiloMarkerId             = nil
    Dispatch.adBuyerMarkerId            = nil
    Dispatch.adSpawnMarkerId            = nil
    Dispatch.adSiloMarkerPos            = nil
    Dispatch.adBuyerMarkerPos           = nil
    Dispatch.adSpawnMarkerPos           = nil
end

-- v0.5.99.27: dispatch the next trip — or finish if the silo is empty
-- / MAX_TRIPS reached. Spawns a fresh truck at SPAWN_POINT.
function Dispatch:startNextTrip()
    local station  = Dispatch.collectionLoadingStation
    local fillType = Dispatch.collectionFillType
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    if station == nil or fillType == nil then
        Dispatch:endCollection("no locked target")
        return
    end
    local siloLevel = (station.getFillLevel and station:getFillLevel(fillType, farmId)) or 0
    if siloLevel <= 0.5 then
        Dispatch:endCollection("silo empty")
        return
    end
    if Dispatch.tripNumber >= Dispatch.MAX_TRIPS then
        Dispatch:endCollection("MAX_TRIPS reached")
        return
    end
    local sp = Dispatch.collectionSpawn
    if sp == nil then
        Dispatch:endCollection("no derived spawn point")
        return
    end
    Dispatch.tripNumber       = Dispatch.tripNumber + 1
    Dispatch.tripState        = "active"
    Dispatch.tripSaleDone     = false
    Dispatch.tripLoadedLitres = 0

    local ok, err = pcall(Dispatch.beginSpawn, Dispatch,
        sp.x, sp.z, sp.dirX, sp.dirZ)
    if not ok then
        Dispatch.dispatchInProgress = false
        logf("[trip %d] beginSpawn EXCEPTION: %s", Dispatch.tripNumber, tostring(err))
        Dispatch:endCollection("spawn failed")
    end
end

-- v0.5.99.27: despawn the truck once it has returned to DESPAWN_POINT.
function Dispatch:despawnTruck(v)
    -- v0.6: the merchant vehicle is a combo — delete the trailer too.
    -- Delete the implement before the root; Vehicle:delete detaches it.
    local trailer = Dispatch.adTrailer
    if trailer ~= nil and trailer ~= v and type(trailer.delete) == "function" then
        local ok, err = pcall(trailer.delete, trailer)
        if not ok then
            logf("[trip %d] trailer delete failed: %s", Dispatch.tripNumber, tostring(err))
        end
    end
    Dispatch.adTrailer = nil

    if v == nil then
        logf("[trip %d] despawnTruck: no vehicle", Dispatch.tripNumber)
        return
    end
    if type(v.delete) == "function" then
        local ok, err = pcall(v.delete, v)
        if not ok then
            logf("[trip %d] truck delete failed: %s", Dispatch.tripNumber, tostring(err))
        end
    else
        logf("[trip %d] truck has no :delete() — cannot despawn", Dispatch.tripNumber)
    end
end

-- v0.6.x haulage-parity refactor: the per-trip "sale" no longer pays.
-- It just records the litres dropped at the buyer this trip and marks
-- the trip sale-complete so finishAutoDriveTrip knows to continue the
-- multi-trip loop. The actual payment fires once at endCollection —
-- booking.litres × live price − 5% fee — via
-- GrainCollection:settleBookingPayout, the same shared helper the
-- instant path uses, so both routes pay the same net to the penny.
function Dispatch:doDirectSale(job)
    local litres = Dispatch.tripLoadedLitres or 0
    Dispatch.collectionTotalLitres = Dispatch.collectionTotalLitres + litres
    Dispatch.tripSaleDone = true
end

-- =============================================================
-- v0.6 AUTODRIVE DRIVING PATH
-- =============================================================
-- AutoDrive replaces AIJobLoadAndDeliver as the driving controller.
-- The truck spawns at the F9 pickup point; AutoDrive paths it to a
-- map marker near the silo (direct-load fires on arrival), then to a
-- marker near the buyer (direct-sale fires on arrival), then the
-- truck despawns. Multi-trip reuses the existing startNextTrip /
-- between-trips machinery. doDirectLoad / doDirectSale are unchanged
-- — they are fed a minimal job-shaped shim instead of a real AIJob.

-- World XZ of a placeable or station. Placeables expose rootNode;
-- stations usually expose it via owningPlaceable (mirrors worldDistanceTo).
function Dispatch:objectWorldXZ(obj)
    if obj == nil then return nil, nil end
    local node = obj.rootNode
    if node == nil and obj.owningPlaceable ~= nil then
        node = obj.owningPlaceable.rootNode
    end
    if node == nil then return nil, nil end
    local ok, x, _, z = pcall(getWorldTranslation, node)
    if not ok or x == nil then return nil, nil end
    return x, z
end

function Dispatch:objectName(obj)
    if obj == nil then return "?" end
    if obj.getName ~= nil then
        local ok, n = pcall(obj.getName, obj)
        if ok and n and n ~= "" then return n end
    end
    return "?"
end

-- Nearest marker (from GrainCollection:listADMarkers entries) to an XZ.
function Dispatch:nearestMarker(markers, x, z)
    local best, bestD = nil, math.huge
    for _, m in ipairs(markers) do
        local d = math.sqrt((m.x - x) ^ 2 + (m.z - z) ^ 2)
        if d < bestD then best, bestD = m, d end
    end
    return best, bestD
end

-- v0.6 (restored): proximity-match the silo + best-buyer + look up the
-- player's merchant-arrival marker by id. Three-marker trip:
--   spawn = adSpawnMarker (player-chosen)  -> truck appears here
--   silo  = adSiloMarker  (proximity, 50m) -> drive leg 1 + direct-load
--   buyer = adBuyerMarker (proximity, 50m) -> drive leg 2 + direct-sale,
--                                              despawn at buyer
-- merchantMarkerId is the player's chosen AD marker id from the picker.
-- When nil (legacy F10 dev path) spawn is supplied separately via
-- collectionSpawn and adSpawnMarker* stay nil.
-- HISTORY: v0.5.99.46 collapsed buyer onto the merchant marker ("return
-- to spawn" workaround) — buyer was purely financial, truck never
-- physically visited it. Restored to physical buyer delivery here.
function Dispatch:matchADMarkers(merchantMarkerId)
    Dispatch.adSiloMarkerId   = nil
    Dispatch.adBuyerMarkerId  = nil
    Dispatch.adSpawnMarkerId  = nil
    Dispatch.adSiloMarkerPos  = nil
    Dispatch.adBuyerMarkerPos = nil
    Dispatch.adSpawnMarkerPos = nil

    if GrainCollection == nil or not GrainCollection.adAvailable then
        logf("[AD-match] ABORT: AutoDrive not available")
        gcToast("AutoDrive not available — cannot dispatch", "critical")
        return false
    end

    local markers = {}
    if GrainCollection.listADMarkers ~= nil then
        local ok, mk = pcall(GrainCollection.listADMarkers, GrainCollection)
        if ok and mk ~= nil then markers = mk end
    end
    if #markers == 0 then
        logf("[AD-match] ABORT: no AutoDrive markers on this map")
        gcToast("No AutoDrive markers — draw an AutoDrive network first", "critical")
        return false
    end

    local radius = Dispatch.AD_MATCH_RADIUS

    -- Silo marker — nearest AutoDrive marker to the grain silo.
    local siloX, siloZ = self:objectWorldXZ(Dispatch.collectionGrainPlaceable)
    if siloX == nil then
        logf("[AD-match] ABORT: silo world position unresolved")
        gcToast("Cannot dispatch — silo position unknown", "critical")
        return false
    end
    local siloName = self:objectName(Dispatch.collectionGrainPlaceable)
    local siloM, siloD = self:nearestMarker(markers, siloX, siloZ)
    if siloM == nil or siloD > radius then
        logf("[AD-match] ABORT: no AutoDrive marker within %dm of silo '%s' at (%.1f, %.1f) — nearest %.0fm",
            radius, siloName, siloX, siloZ, siloD or -1)
        gcToast("No AutoDrive marker near the silo — please place one", "critical")
        return false
    end

    -- Buyer marker — nearest AutoDrive marker to the best-buyer station.
    local buyerX, buyerZ = self:objectWorldXZ(Dispatch.collectionUnloadingStation)
    if buyerX == nil then
        logf("[AD-match] ABORT: buyer world position unresolved")
        gcToast("Cannot dispatch — buyer position unknown", "critical")
        return false
    end
    local buyerName = self:objectName(Dispatch.collectionUnloadingStation)
    local buyerM, buyerD = self:nearestMarker(markers, buyerX, buyerZ)
    if buyerM == nil or buyerD > radius then
        logf("[BOOK] aborted: no AutoDrive marker within %dm of %s at (%.1f, %.1f) — nearest %.0fm",
            radius, buyerName, buyerX, buyerZ, buyerD or -1)
        gcToast(string.format(
            "No AutoDrive marker near %s — place one near %s to enable haulier deliveries",
            buyerName, buyerName), "critical")
        return false
    end

    -- Spawn marker — player's merchant-arrival marker (id lookup, no
    -- proximity match — the player picked it deliberately).
    local spawnM
    if merchantMarkerId ~= nil then
        for _, m in ipairs(markers) do
            if m.id == merchantMarkerId then spawnM = m break end
        end
        if spawnM == nil then
            logf("[AD-match] ABORT: merchant arrival marker id=%s no longer exists",
                tostring(merchantMarkerId))
            gcToast("Merchant arrival marker no longer exists — pick another", "critical")
            return false
        end
    end

    Dispatch.adSiloMarkerId   = siloM.id
    Dispatch.adBuyerMarkerId  = buyerM.id
    Dispatch.adSiloMarkerPos  = { x = siloM.x, z = siloM.z }
    Dispatch.adBuyerMarkerPos = { x = buyerM.x, z = buyerM.z }
    if spawnM ~= nil then
        Dispatch.adSpawnMarkerId  = spawnM.id
        Dispatch.adSpawnMarkerPos = { x = spawnM.x, y = spawnM.y, z = spawnM.z }
    end
    return true
end

-- Build a minimal job-shaped table so the unchanged doDirectLoad /
-- doDirectSale can run without a real AIJob. doDirectLoad needs
-- loadingNodeInfos (truck fill units) + fillTypeParameter; doDirectSale
-- only reads collection state, the shim is a harmless fallback there.
function Dispatch:buildJobShim(vehicle)
    local infos = {}
    local fillType = Dispatch.collectionFillType
    -- v0.6: the grain is held by the trailer (Krampe SKS), not the FH16.
    -- Search the trailer first, then the truck as a fallback (covers the
    -- legacy single-vehicle case). Stop at the first source that yields a
    -- grain-capable fill unit, so the truck's diesel/DEF units are never
    -- picked when a real grain trailer is present.
    local sources = {}
    if Dispatch.adTrailer ~= nil then
        table.insert(sources, Dispatch.adTrailer)
    end
    if vehicle ~= nil then
        table.insert(sources, vehicle)
    end
    for _, src in ipairs(sources) do
        if src.getFillUnits ~= nil then
            local ok, fillUnits = pcall(src.getFillUnits, src)
            if ok and fillUnits ~= nil then
                for index, fu in ipairs(fillUnits) do
                    if (fu.capacity or 0) > 0 then
                        local supports = fu.supportedFillTypes == nil
                            or fillType == nil
                            or fu.supportedFillTypes[fillType]
                        if supports then
                            table.insert(infos, { vehicle = src, fillUnitIndex = index })
                        end
                    end
                end
            end
        end
        if #infos > 0 then break end
    end
    return {
        loadingNodeInfos = infos,
        fillTypeParameter = {
            getFillTypeIndex = function() return Dispatch.collectionFillType end,
        },
        loadingStationParameter = {
            getLoadingStation = function() return Dispatch.collectionLoadingStation end,
        },
    }
end

-- Distance from the truck to the current leg's destination marker.
function Dispatch:adTruckDistanceToMarker(v, leg)
    if v == nil or v.rootNode == nil then return nil end
    local pos = (leg == "to-silo") and Dispatch.adSiloMarkerPos
        or Dispatch.adBuyerMarkerPos
    if pos == nil then return nil end
    local ok, tx, _, tz = pcall(getWorldTranslation, v.rootNode)
    if not ok or tx == nil then return nil end
    return math.sqrt((tx - pos.x) ^ 2 + (tz - pos.z) ^ 2)
end

-- Start AutoDrive driving the truck to a marker. Mirrors what the
-- player's "start" does: set DriveTo mode, set the first marker, start
-- the mode (DriveToMode:start calls startAutoDrive itself). Returns
-- true only if AutoDrive actually engaged (stateModule active).
function Dispatch:adDriveTo(vehicle, markerId, label)
    local AD = GrainCollection and GrainCollection.AD or nil
    if AD == nil or vehicle == nil or vehicle.ad == nil
            or vehicle.ad.stateModule == nil then
        logf("[AD-drive] ABORT (%s): AD=%s vehicle.ad=%s",
            tostring(label), tostring(AD ~= nil),
            tostring(vehicle ~= nil and vehicle.ad ~= nil))
        return false
    end
    if not vehicle.isServer then
        logf("[AD-drive] ABORT (%s): not server — AutoDrive start is server-only", tostring(label))
        return false
    end
    local sm = vehicle.ad.stateModule

    if AD.MODE_DRIVETO ~= nil and sm.setMode ~= nil then
        pcall(sm.setMode, sm, AD.MODE_DRIVETO)
    end
    if sm.setFirstMarker == nil then
        logf("[AD-drive] ABORT (%s): stateModule has no setFirstMarker", tostring(label))
        return false
    end
    pcall(sm.setFirstMarker, sm, markerId)
    if sm.getFirstMarker == nil or sm:getFirstMarker() == nil then
        logf("[AD-drive] ABORT (%s): marker id=%s did not resolve to a map marker",
            tostring(label), tostring(markerId))
        return false
    end

    local mode = sm.getCurrentMode and sm:getCurrentMode() or nil
    if mode == nil or mode.start == nil then
        logf("[AD-drive] ABORT (%s): no current mode to start", tostring(label))
        return false
    end
    local okS, errS = pcall(mode.start, mode)
    if not okS then
        logf("[AD-drive] ABORT (%s): mode:start threw %s", tostring(label), tostring(errS))
        return false
    end

    local active = sm.isActive and sm:isActive() or false
    return active == true
end

-- Begin an AutoDrive trip with the freshly-spawned truck: drive to the
-- silo marker. Called from onSpawned in place of constructJob.
-- v0.6: set the merchant truck's per-vehicle AutoDrive cornerSpeed so it
-- takes corners at ~50% of AutoDrive's default cornering curve. AutoDrive
-- already detects corners itself — this only scales them. See
-- v0.6_AUTODRIVE_SPEED_CONTROL.md. Internal AD API: feature-detected.
function Dispatch:applyHaulierCornerSpeed(truck)
    local AD = GrainCollection and GrainCollection.AD or nil
    if AD == nil or type(AD.setSettingState) ~= "function"
            or AD.settings == nil or AD.settings.cornerSpeed == nil then
        return
    end
    if truck == nil or truck.ad == nil then return end
    local idx = Dispatch.AD_CORNER_SPEED_INDEX
    local ok, err = pcall(AD.setSettingState, "cornerSpeed", idx, truck)
    if not ok then
        logf("[AD-speed] setSettingState failed: %s", tostring(err))
    end
end

function Dispatch:startAutoDriveTrip(vehicle)
    Dispatch.activeVehicle = vehicle
    Dispatch.adLegTruck    = vehicle
    Dispatch.adLeg         = nil
    Dispatch.adLegPollAcc  = 0

    -- v0.6: corner this truck at 50% (per-vehicle AutoDrive setting).
    Dispatch:applyHaulierCornerSpeed(vehicle)

    local siloMarker = Dispatch.adSiloMarkerId
    if siloMarker == nil then
        logf("[AD-trip] ABORT: no silo marker matched (matchADMarkers not run?)")
        Dispatch.dispatchInProgress = false
        Dispatch:finishAutoDriveTrip(vehicle)
        return
    end
    if self:adDriveTo(vehicle, siloMarker, "to-silo") then
        Dispatch.adLeg = "to-silo"
    else
        logf("[AD-trip] ABORT: could not start the drive to the silo")
        Dispatch.dispatchInProgress = false
        Dispatch:finishAutoDriveTrip(vehicle)
    end
end

-- Per-frame: poll the AutoDrive leg. stateModule:isActive() is true
-- while driving and flips false when the route ends. adDriveTo already
-- confirmed it was true at leg start, so the first false = leg done.
function Dispatch:updateAutoDrive(dt)
    local leg = Dispatch.adLeg
    if leg == nil then return end

    local v = Dispatch.adLegTruck
    if v == nil or v.ad == nil or v.ad.stateModule == nil then
        logf("[AD-drive] truck / stateModule lost mid-leg — ending trip")
        Dispatch.adLeg = nil
        Dispatch:finishAutoDriveTrip(v)
        return
    end
    local sm = v.ad.stateModule
    local active = sm.isActive and sm:isActive() or false

    -- Per-leg proximity arrival. AutoDrive can wedge trying to dock at
    -- tight silo / buyer markers; once the truck is within the leg's
    -- arrival radius we treat the leg as complete and stop AD cleanly.
    -- The natural AD-reports-arrived path (active=false) still triggers
    -- the same finish branch for clean docks.
    local dist = self:adTruckDistanceToMarker(v, leg)
    local radius = (leg == "to-silo") and Dispatch.ARRIVAL_RADIUS
                                       or Dispatch.BUYER_ARRIVAL_RADIUS
    local proximityArrived = dist ~= nil and dist <= radius

    if active and not proximityArrived then return end   -- still driving

    if proximityArrived and active and v.stopAutoDrive ~= nil then
        pcall(v.stopAutoDrive, v)
    end

    if leg == "to-silo" then
        Dispatch.adLeg = nil   -- clear before re-entrant calls
        local shim = self:buildJobShim(v)
        pcall(Dispatch.doDirectLoad, Dispatch, shim)

        local buyerMarker = Dispatch.adBuyerMarkerId
        if buyerMarker ~= nil and self:adDriveTo(v, buyerMarker, "to-buyer") then
            Dispatch.adLeg        = "to-buyer"
            Dispatch.adLegPollAcc = 0
        else
            logf("[AD-trip] could not start the drive to the buyer — selling in place")
            pcall(Dispatch.doDirectSale, Dispatch, self:buildJobShim(v))
            Dispatch:finishAutoDriveTrip(v)
        end
    elseif leg == "to-buyer" then
        Dispatch.adLeg = nil
        pcall(Dispatch.doDirectSale, Dispatch, self:buildJobShim(v))
        Dispatch:finishAutoDriveTrip(v)
    end
end

-- End an AutoDrive trip: stop AutoDrive if still running, despawn the
-- truck, then continue the multi-trip loop or finish the collection.
-- Mirrors the tail of onAIJobStopped.
function Dispatch:finishAutoDriveTrip(truck)
    Dispatch.adLeg              = nil
    Dispatch.adLegTruck         = nil
    Dispatch.dispatchInProgress = false

    if truck ~= nil then
        if truck.isServer and truck.stopAutoDrive ~= nil and truck.ad ~= nil
                and truck.ad.stateModule ~= nil and truck.ad.stateModule.isActive ~= nil then
            local okA, busy = pcall(truck.ad.stateModule.isActive, truck.ad.stateModule)
            if okA and busy then
                logf("[AD-trip] AutoDrive still active at trip end — stopping it before despawn")
                pcall(truck.stopAutoDrive, truck)
            end
        end
        Dispatch:despawnTruck(truck)
    end

    if Dispatch.tripState ~= "active" then return end

    if Dispatch.tripSaleDone then
        local station  = Dispatch.collectionLoadingStation
        local fillType = Dispatch.collectionFillType
        local farmId   = g_currentMission and g_currentMission:getFarmId()
        local siloLevel = (station and station.getFillLevel
            and station:getFillLevel(fillType, farmId)) or 0
        -- v0.6.x CP3: booking-driven cap — stop when delivered enough.
        local capReached = Dispatch.collectionLitresCap ~= nil
            and (Dispatch.collectionTotalLitres or 0)
                >= Dispatch.collectionLitresCap
        if siloLevel > 0.5
                and Dispatch.tripNumber < Dispatch.MAX_TRIPS
                and not capReached then
            Dispatch.tripState         = "between-trips"
            Dispatch.betweenTripsTimer = Dispatch.BETWEEN_TRIPS_DELAY_MS
            local remainingText
            if Dispatch.collectionLitresCap ~= nil then
                local rem = Dispatch.collectionLitresCap
                    - (Dispatch.collectionTotalLitres or 0)
                remainingText = string.format("%sL of booking left", g_i18n:formatNumber(rem, 0))
            else
                remainingText = string.format("%sL left", g_i18n:formatNumber(siloLevel, 0))
            end
            gcToast(string.format(
                "Grain collection continuing — %s, next truck arriving shortly",
                remainingText), "info")
        else
            local reason
            if capReached then reason = "booking fulfilled"
            elseif siloLevel <= 0.5 then reason = "silo empty"
            else reason = "MAX_TRIPS reached" end
            Dispatch:endCollection(reason)
        end
    else
        logf("[AD-trip] trip %d FAILED before sale — ending collection",
            Dispatch.tripNumber)
        Dispatch:endCollection("trip failed")
    end
end


addModEventListener(Dispatch)
