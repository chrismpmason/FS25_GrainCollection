--
-- DispatchSmokeTest.lua — merchant haulier dispatch.
--
-- Production dispatch system for the BOOK button in the Produce
-- Collection menu. Spawns the configured merchant vehicle at the
-- player-set merchant-arrival marker, lets AutoDrive path it to the
-- silo, direct-loads grain, lets AutoDrive path it to the buyer's
-- nearest marker, direct-sells, despawns. Loops for multi-trip
-- collections until the silo is empty or MAX_TRIPS is reached.
--
-- File name is historical (the v0.5 series was a smoke test for the
-- driving controller). v0.7 will rename to HaulierDispatch.
--

DispatchSmokeTest = {}
DispatchSmokeTest.MOD_NAME = g_currentModName or "FS25_GrainCollection"

DispatchSmokeTest.dispatchInProgress = false
DispatchSmokeTest.dispatchCount      = 0
DispatchSmokeTest.activeVehicle      = nil

-- Merchant vehicle: vanilla Lizard MultiPurpose "Dragon" with the
-- Extension configurationSet applied. Single vehicle (no trailer) so
-- it fits universally on tight maps. ~7,600 L grain capacity. The
-- configuration indices below match the vanilla XML's Extension set
-- (animation 2, cylindered 2, fillVolume 2, fillUnit 2, trailer 2,
-- dischargeable 2, tensionBelts 3). Applied via
-- VehicleLoadingData:setConfigurations at spawn time.
DispatchSmokeTest.VEHICLE_XML            = "data/vehicles/lizard/multiPurposeTruck/multiPurposeTruck.xml"
DispatchSmokeTest.VEHICLE_CONFIGURATIONS = {
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
DispatchSmokeTest.BUNDLE_XML_SUFFIX  = "fh16KrampeBundle.xml"
DispatchSmokeTest.BUNDLE_NAME        = "Grain Haulier (FH16 + SKS 30/1050)"

-- AutoDrive per-vehicle cornerSpeed index. Index 1 = 0.5 = "50%" —
-- corners taken at half AutoDrive's default cornering curve.
DispatchSmokeTest.AD_CORNER_SPEED_INDEX = 1

-- Multi-trip collection config.
DispatchSmokeTest.SPAWN_DISTANCE           = 50      -- metres back from the silo AI node
DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS   = 8000    -- ms; pause between trips
DispatchSmokeTest.MAX_TRIPS                = 10      -- runaway guard
DispatchSmokeTest.PRICE_PER_LITRE_FALLBACK = 0.30    -- £/L if economy lookup fails

-- Proximity arrival radii. AutoDrive can wedge trying to dock at tight
-- markers; we treat the leg as complete and stop AD cleanly once the
-- truck is within the leg's radius. Buyer wider than silo because
-- unload approach roads tend to be wider than silo aprons.
DispatchSmokeTest.ARRIVAL_RADIUS        = 20     -- silo leg
DispatchSmokeTest.BUYER_ARRIVAL_RADIUS  = 30     -- buyer leg
DispatchSmokeTest.proximityLogAcc       = 0

-- Collection (multi-trip) state. A "collection" = one BOOK click:
-- spawn → silo → load → buyer → sell → despawn, repeated until the
-- silo is empty or MAX_TRIPS is reached.
DispatchSmokeTest.tripState                  = "idle"  -- idle | active | between-trips
DispatchSmokeTest.tripNumber                 = 0
DispatchSmokeTest.tripSaleDone               = false
DispatchSmokeTest.tripLoadedLitres           = 0
DispatchSmokeTest.betweenTripsTimer          = nil
DispatchSmokeTest.collectionLoadingStation   = nil
DispatchSmokeTest.collectionUnloadingStation = nil
DispatchSmokeTest.collectionFillType         = nil
DispatchSmokeTest.collectionTotalLitres      = 0
DispatchSmokeTest.collectionTotalPaid        = 0
DispatchSmokeTest.collectionSpawn            = nil   -- {x, y, z, dirX, dirZ}
DispatchSmokeTest.collectionGrainStorage     = nil
DispatchSmokeTest.collectionGrainPlaceable   = nil

-- AutoDrive driving state.
DispatchSmokeTest.AD_MATCH_RADIUS   = 50     -- m; max silo/buyer -> marker distance
DispatchSmokeTest.adLeg             = nil    -- nil | "to-silo" | "to-buyer"
DispatchSmokeTest.adLegTruck        = nil
DispatchSmokeTest.adTrailer         = nil    -- nil for the Lizard; populated for v0.7 combo
DispatchSmokeTest.adSiloMarkerId    = nil
DispatchSmokeTest.adBuyerMarkerId   = nil    -- proximity-matched to best buyer
DispatchSmokeTest.adSpawnMarkerId   = nil    -- player-set merchant arrival marker
DispatchSmokeTest.adSiloMarkerPos   = nil    -- {x, z}
DispatchSmokeTest.adBuyerMarkerPos  = nil    -- {x, z}
DispatchSmokeTest.adSpawnMarkerPos  = nil    -- {x, y, z}
DispatchSmokeTest.adLegPollAcc      = 0

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
function DispatchSmokeTest:doDirectLoad(job)
    local src      = DispatchSmokeTest.collectionGrainStorage
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
    local srcKind  = (src.removeFillLevel ~= nil and "LoadingStation (removeFillLevel)")
        or (src.setFillLevel ~= nil and "Storage (setFillLevel)") or "unknown"
    logf("[direct-load] grain source = %s, fillType=%s, startLevel=%.0fL",
        srcKind, ftName, (src:getFillLevel(fillType, farmId)) or 0)

    for _, info in ipairs(nodes) do
        local v, fui = info.vehicle, info.fillUnitIndex
        if v ~= nil and fui ~= nil then
            local freeCap = (v.getFillUnitFreeCapacity and v:getFillUnitFreeCapacity(fui)) or 0
            local before  = (src:getFillLevel(fillType, farmId)) or 0
            local want    = math.min(freeCap, before)
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
                DispatchSmokeTest.tripLoadedLitres = DispatchSmokeTest.tripLoadedLitres + removed
                logf("[direct-load] fillUnit%d: want=%.0fL siloGave=%.0fL truckTook=%.0fL newTruckLevel=%.0fL siloLeft=%.0fL",
                    fui, want, removed, tAfter - tBefore, tAfter, afterSrc)
            else
                logf("[direct-load] fillUnit%d: nothing to transfer (freeCap=%.0fL siloLevel=%.0fL)",
                    fui, freeCap, before)
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

function DispatchSmokeTest:loadMap(name)
    logf("loaded — merchant haulier ready (AutoDrive)")
end

function DispatchSmokeTest:update(dt)
    -- Between-trips delay countdown for multi-trip collections.
    if DispatchSmokeTest.tripState == "between-trips"
            and DispatchSmokeTest.betweenTripsTimer ~= nil then
        DispatchSmokeTest.betweenTripsTimer = DispatchSmokeTest.betweenTripsTimer - (dt or 0)
        if DispatchSmokeTest.betweenTripsTimer <= 0 then
            DispatchSmokeTest.betweenTripsTimer = nil
            logf("[collection] between-trips delay elapsed — dispatching next trip")
            pcall(DispatchSmokeTest.startNextTrip, DispatchSmokeTest)
        end
    end

    -- AutoDrive per-frame leg poll. Self-gates on adLeg; no-op when idle.
    pcall(DispatchSmokeTest.updateAutoDrive, DispatchSmokeTest, dt)
end

-- v0.5.99.8: per-task lifecycle tracker. Called every frame while a job
-- is active. For each task in job.tasks we keep a record of how many
-- times we've observed it transition into isRunning=true and into
-- isFinished=true. Also logs every internal `state` change (e.g.
-- BOOK click entry point. Resolves the row's fillType + best buyer +
-- owned silo, matches AutoDrive markers, then kicks off the multi-trip
-- collection. Returns (ok, message, needsPicker) — the menu uses
-- needsPicker=true to open the marker picker when the player hasn't
-- yet set a merchant arrival point.
function DispatchSmokeTest:startCollectionFromMenu(row)
    if g_currentMission == nil or not g_currentMission:getIsClient() then
        return false, "Not in an active game"
    end
    if row == nil or row.fillTypeIndex == nil then
        return false, "Invalid produce row"
    end
    if DispatchSmokeTest.tripState ~= "idle" or DispatchSmokeTest.dispatchInProgress then
        logf("[BOOK] collection already running (state=%s, trip %d) — ignoring",
            tostring(DispatchSmokeTest.tripState), DispatchSmokeTest.tripNumber)
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

    DispatchSmokeTest.collectionLoadingStation   = loadingStation
    DispatchSmokeTest.collectionUnloadingStation = buyer
    DispatchSmokeTest.collectionFillType         = fillTypeIndex
    DispatchSmokeTest.collectionGrainStorage     = grainStorage
    DispatchSmokeTest.collectionGrainPlaceable   = grainPlaceable
    DispatchSmokeTest.collectionTotalLitres      = 0
    DispatchSmokeTest.collectionTotalPaid        = 0
    DispatchSmokeTest.tripNumber                 = 0
    DispatchSmokeTest.dispatchCount = DispatchSmokeTest.dispatchCount + 1

    logf("[BOOK] collection #%d START: fillType='%s' siloLevel=%.0fL silo='%s' buyer='%s'",
        DispatchSmokeTest.dispatchCount, ftName, fillLevel,
        tostring(loadingStation.getName and loadingStation:getName() or "?"),
        tostring(buyer.getName and buyer:getName() or "?"))

    -- Match three markers up front: silo (proximity), buyer (proximity to
    -- best buyer), spawn (player-chosen merchant arrival). If any fails
    -- we abort BEFORE spawning — matchADMarkers has toasted the player.
    if not DispatchSmokeTest:matchADMarkers(merchantId) then
        DispatchSmokeTest:endCollection("AutoDrive marker match failed")
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
    local sp = DispatchSmokeTest.adSpawnMarkerPos
    local sm = DispatchSmokeTest.adSiloMarkerPos
    if sp == nil then
        DispatchSmokeTest:endCollection("merchant marker has no position")
        return false, "The merchant arrival marker has no position"
    end
    local dirX, dirZ = 0, 1
    if sm ~= nil then
        local vx, vz = sm.x - sp.x, sm.z - sp.z
        local len = math.sqrt(vx * vx + vz * vz)
        if len > 0.01 then dirX, dirZ = vx / len, vz / len end
    end
    DispatchSmokeTest.collectionSpawn = { x = sp.x, z = sp.z, dirX = dirX, dirZ = dirZ }
    logf("[BOOK] spawn = merchant marker (%.1f, %.1f) heading=(%.2f, %.2f); despawn at buyer marker",
        sp.x, sp.z, dirX, dirZ)

    DispatchSmokeTest:startNextTrip()
    return true, string.format("Merchant dispatched to collect %s", ftName)
end

-- v0.5.99.30: F9 sets the merchant-truck PICKUP LOCATION — it captures
-- the player's current world position + facing and stores it (per farm,
-- persisted) via GrainCollection. The truck then spawns/despawns there.
-- (F9 and F10 previously both started a collection — F9 was redundant.)
function DispatchSmokeTest:resolveBundleStoreItem()
    if g_storeManager == nil then return nil end
    local suffix = DispatchSmokeTest.BUNDLE_XML_SUFFIX

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
                if item.name == DispatchSmokeTest.BUNDLE_NAME then
                    return item
                end
            end
        end
    end
    return nil
end

function DispatchSmokeTest:beginSpawn(overrideX, overrideZ, headingDirX, headingDirZ)
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

    logf("spawning merchant: Lizard MultiPurpose (Extension), pos=(%.1f, terrain, %.1f) farmId=%s",
        spawnX, spawnZ, tostring(farmId))

    -- v0.6.x: spawn the vanilla Lizard MultiPurpose with the Extension
    -- configurationSet (7,600 L BULK fillUnit, single vehicle, no
    -- trailer to attach — fits on tight maps). The FH16+Krampe bundle
    -- path stays in this file but is unreachable; v0.7 selection UI
    -- will reintroduce it.
    local data = VehicleLoadingData.new()
    local storeItem = nil
    if g_storeManager ~= nil and type(g_storeManager.getItemByXMLFilename) == "function" then
        local ok, item = pcall(g_storeManager.getItemByXMLFilename,
            g_storeManager, DispatchSmokeTest.VEHICLE_XML)
        if ok then storeItem = item end
    end
    if storeItem == nil then
        logf("ABORT: Lizard MultiPurpose store item not found at '%s' — vanilla install missing?",
            DispatchSmokeTest.VEHICLE_XML)
        gcToast("Merchant vehicle missing — cannot dispatch", "critical")
        return
    end
    data:setStoreItem(storeItem)
    -- Extension configurationSet — adds the bodyExtension, lifts BULK
    -- capacity from 3,500 L to 7,600 L. Per-config indices declared at
    -- VEHICLE_CONFIGURATIONS up top.
    if type(data.setConfigurations) == "function" then
        data:setConfigurations(DispatchSmokeTest.VEHICLE_CONFIGURATIONS)
    end
    if not data.isValid then
        logf("ABORT: VehicleLoadingData.isValid=false for Lizard MultiPurpose '%s'",
            tostring(storeItem.name))
        return
    end
    logf("[trip %d] vehicle resolved: '%s' (Extension config applied: fillUnit=%d)",
        DispatchSmokeTest.tripNumber, tostring(storeItem.name),
        DispatchSmokeTest.VEHICLE_CONFIGURATIONS.fillUnit)

    -- v0.6: sample actual terrain height at the spawn XZ rather than
    -- relying on the marker's stored Y. AutoDrive waypoints record Y at
    -- wheel/chassis height which can sit several metres off the ground,
    -- causing a visible drop on spawn. Pcall-guarded; on failure fall
    -- back to the marker Y (if known), otherwise nil for engine default.
    local markerY
    if DispatchSmokeTest.adSpawnMarkerPos ~= nil then
        markerY = DispatchSmokeTest.adSpawnMarkerPos.y
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
    logf("[BOOK] spawn Y: marker=%s terrain=%s using=%s",
        markerY  and string.format("%.2f", markerY)  or "?",
        terrainY and string.format("%.2f", terrainY) or "?",
        spawnY   and string.format("%.2f", spawnY)   or "default")

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
        logf("[trip %d] spawn at (%.1f, %.1f) heading-in=(%.2f, %.2f) negated=(%.2f, %.2f) yaw=%.3f rad",
            DispatchSmokeTest.tripNumber, spawnX, spawnZ,
            headingDirX, headingDirZ, hx, hz, ry)
    end
    data:setPropertyState(VehiclePropertyState.MISSION)
    data:setOwnerFarmId(farmId)
    data:setIsSaved(false)

    DispatchSmokeTest.dispatchInProgress = true
    data:load(DispatchSmokeTest.onSpawned, DispatchSmokeTest, nil)
end

-- v0.6 step 1: AutoDrive runtime probe. Confirms the spawned truck
-- carries the AutoDrive specialization (vehicle.ad) and dumps the
-- player's marker network plus the API surface the v0.6 AutoDrive
-- rework will build on. Pure diagnostics — starts/alters nothing.
-- One-line summary: AutoDrive detected? truck carries vehicle.ad?
-- waypoint network present? If the player has no marker network the
-- BOOK click later will toast a clean error from matchADMarkers.
function DispatchSmokeTest:probeAutoDrive(vehicle)
    local AD = (GrainCollection ~= nil) and GrainCollection.AD or nil
    local adAvail = (GrainCollection ~= nil) and GrainCollection.adAvailable
    local hasAd = vehicle ~= nil and vehicle.ad ~= nil
    local markers = {}
    if AD ~= nil and GrainCollection.listADMarkers ~= nil then
        local ok, mk = pcall(GrainCollection.listADMarkers, GrainCollection)
        if ok and mk ~= nil then markers = mk end
    end
    logf("[AD-probe] AutoDrive=%s truck.ad=%s markers=%d",
        tostring(adAvail and AD ~= nil), tostring(hasAd), #markers)
end

function DispatchSmokeTest:onSpawned(vehicles, loadState, args)
    local okState = (VehicleLoadingState ~= nil) and (loadState == VehicleLoadingState.OK)
    if not okState or vehicles == nil or #vehicles == 0 then
        DispatchSmokeTest.dispatchInProgress = false
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
    DispatchSmokeTest.adTrailer = trailer
    logf("merchant vehicle spawned: truck=%s trailer=%s (%d vehicle(s))",
        tostring(vehicle and vehicle.typeName),
        tostring(trailer and trailer.typeName), #vehicles)
    if vehicle ~= nil then
        logf("  truck rootNode=%s ownerFarmId=%s vehicle.ad=%s",
            tostring(vehicle.rootNode),
            tostring(vehicle.getOwnerFarmId and vehicle:getOwnerFarmId() or "?"),
            tostring(vehicle.ad ~= nil))
    end
    if trailer ~= nil then
        local attachedTo = (trailer.getAttacherVehicle ~= nil)
            and trailer:getAttacherVehicle() or nil
        logf("  trailer rootNode=%s attachedTo=%s",
            tostring(trailer.rootNode),
            attachedTo ~= nil and tostring(attachedTo.typeName) or "<NOT ATTACHED>")
    else
        logf("  WARNING: bundle spawned no trailer — grain capacity missing")
    end

    -- AutoDrive runtime probe — non-destructive, one-line summary.
    pcall(DispatchSmokeTest.probeAutoDrive, DispatchSmokeTest, vehicle)

    -- AutoDrive is the only driving controller in v0.6.x. Hand the truck
    -- to the trip executor.
    DispatchSmokeTest.activeVehicle = vehicle
    local okAD, errAD = pcall(DispatchSmokeTest.startAutoDriveTrip,
        DispatchSmokeTest, vehicle)
    if not okAD then
        logf("[AD-trip] startAutoDriveTrip EXCEPTION: %s", tostring(errAD))
        DispatchSmokeTest.dispatchInProgress = false
        pcall(DispatchSmokeTest.finishAutoDriveTrip, DispatchSmokeTest, vehicle)
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
DispatchSmokeTest.GRAIN_FILLTYPES = { "BARLEY", "CANOLA", "OAT", "WHEAT" }

-- Lazily-resolved set of allowed grain fill-type indices (stable per
-- session once the fill-type manager is up).
function DispatchSmokeTest:getGrainFillTypeSet()
    if DispatchSmokeTest._grainSet ~= nil then return DispatchSmokeTest._grainSet end
    local set = {}
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeIndexByName ~= nil then
        for _, name in ipairs(DispatchSmokeTest.GRAIN_FILLTYPES) do
            local idx = g_fillTypeManager:getFillTypeIndexByName(name)
            if idx ~= nil then set[idx] = name end
        end
    end
    DispatchSmokeTest._grainSet = set
    return set
end

-- v0.5.99.34 diagnostic helper: best-effort display name.
function DispatchSmokeTest:resolveLoadingStation(placeable, grainObj)
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
function DispatchSmokeTest:findLoadingStation(farmId, restrictFillTypeIndex)
    local grainSet = self:getGrainFillTypeSet()
    if restrictFillTypeIndex ~= nil then
        logf("[findLoadingStation] restricted to fillType index %s",
            tostring(restrictFillTypeIndex))
    end

    local gsParts = {}
    for idx, nm in pairs(grainSet) do
        table.insert(gsParts, string.format("%s(%s)", nm, tostring(idx)))
    end
    logf("[findLoadingStation] grain allow-set = {%s}", table.concat(gsParts, ", "))

    if GrainCollection == nil or GrainCollection.getOwnedSilos == nil then
        logf("[findLoadingStation] GrainCollection:getOwnedSilos unavailable — cannot discover grain")
        return nil, 0, nil
    end
    local ok, silos = pcall(GrainCollection.getOwnedSilos, GrainCollection, farmId)
    if not ok or type(silos) ~= "table" then
        logf("[findLoadingStation] getOwnedSilos failed: %s", tostring(silos))
        return nil, 0, nil
    end
    logf("[findLoadingStation] getOwnedSilos returned %d entr(ies)", #silos)

    -- Pick the grain entry with the most stock.
    local bestEntry = nil
    for _, e in ipairs(silos) do
        local fti = e.fillTypeIndex
        local lvl = e.fillLevel or 0
        if fti ~= nil and grainSet[fti] ~= nil and lvl > 0
                and (restrictFillTypeIndex == nil or fti == restrictFillTypeIndex) then
            local ftd = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fti)
            logf("[findLoadingStation] grain entry: placeable='%s' fillType=%s level=%.0fL",
                tostring(e.placeableName), (ftd and ftd.name) or tostring(fti), lvl)
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

    local ftd = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(bestEntry.fillTypeIndex)
    logf("[findLoadingStation] picked '%s' fillType=%s stock=%.0fL  loadingStation via %s  placeable=%s",
        tostring(bestEntry.placeableName), (ftd and ftd.name) or tostring(bestEntry.fillTypeIndex),
        bestEntry.fillLevel or 0, tostring(how), tostring(placeable ~= nil))

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
function DispatchSmokeTest:findUnloadingStation(fillTypeIndex, farmId, refX, refZ, loadingStation)
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
function DispatchSmokeTest:endCollection(reason)
    logf("[collection] COMPLETE (%s): %d trip(s), total %.0fL collected, total £%.2f paid",
        tostring(reason), DispatchSmokeTest.tripNumber,
        DispatchSmokeTest.collectionTotalLitres, DispatchSmokeTest.collectionTotalPaid)
    -- v0.6.x UX: final notification only when at least one trip sold
    -- something. Aborts before any sale (marker match failed, no spawn
    -- point, etc.) toasted their own error and shouldn't get a "complete"
    -- banner on top of that.
    if (DispatchSmokeTest.collectionTotalLitres or 0) > 0 then
        gcToast(string.format(
            "Grain collection complete — %sL sold for %s",
            g_i18n:formatNumber(DispatchSmokeTest.collectionTotalLitres, 0),
            g_i18n:formatMoney(DispatchSmokeTest.collectionTotalPaid, 0, true, true)), "ok")
    end
    DispatchSmokeTest.tripState                  = "idle"
    DispatchSmokeTest.betweenTripsTimer          = nil
    DispatchSmokeTest.collectionLoadingStation   = nil
    DispatchSmokeTest.collectionUnloadingStation = nil
    DispatchSmokeTest.collectionFillType         = nil
    DispatchSmokeTest.collectionSpawn            = nil
    DispatchSmokeTest.collectionGrainStorage     = nil
    DispatchSmokeTest.collectionGrainPlaceable   = nil
    DispatchSmokeTest.adLeg                      = nil
    DispatchSmokeTest.adLegTruck                 = nil
    DispatchSmokeTest.adTrailer                  = nil
    DispatchSmokeTest.adSiloMarkerId             = nil
    DispatchSmokeTest.adBuyerMarkerId            = nil
    DispatchSmokeTest.adSpawnMarkerId            = nil
    DispatchSmokeTest.adSiloMarkerPos            = nil
    DispatchSmokeTest.adBuyerMarkerPos           = nil
    DispatchSmokeTest.adSpawnMarkerPos           = nil
end

-- v0.5.99.27: dispatch the next trip — or finish if the silo is empty
-- / MAX_TRIPS reached. Spawns a fresh truck at SPAWN_POINT.
function DispatchSmokeTest:startNextTrip()
    local station  = DispatchSmokeTest.collectionLoadingStation
    local fillType = DispatchSmokeTest.collectionFillType
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    if station == nil or fillType == nil then
        DispatchSmokeTest:endCollection("no locked target")
        return
    end
    local siloLevel = (station.getFillLevel and station:getFillLevel(fillType, farmId)) or 0
    if siloLevel <= 0.5 then
        DispatchSmokeTest:endCollection("silo empty")
        return
    end
    if DispatchSmokeTest.tripNumber >= DispatchSmokeTest.MAX_TRIPS then
        DispatchSmokeTest:endCollection("MAX_TRIPS reached")
        return
    end
    local sp = DispatchSmokeTest.collectionSpawn
    if sp == nil then
        DispatchSmokeTest:endCollection("no derived spawn point")
        return
    end
    DispatchSmokeTest.tripNumber       = DispatchSmokeTest.tripNumber + 1
    DispatchSmokeTest.tripState        = "active"
    DispatchSmokeTest.tripSaleDone     = false
    DispatchSmokeTest.tripLoadedLitres = 0
    logf("[trip %d] dispatching — siloLevel now %.0fL, spawning truck at (%.1f, %.1f)",
        DispatchSmokeTest.tripNumber, siloLevel, sp.x, sp.z)

    local ok, err = pcall(DispatchSmokeTest.beginSpawn, DispatchSmokeTest,
        sp.x, sp.z, sp.dirX, sp.dirZ)
    if not ok then
        DispatchSmokeTest.dispatchInProgress = false
        logf("[trip %d] beginSpawn EXCEPTION: %s", DispatchSmokeTest.tripNumber, tostring(err))
        DispatchSmokeTest:endCollection("spawn failed")
    end
end

-- v0.5.99.27: despawn the truck once it has returned to DESPAWN_POINT.
function DispatchSmokeTest:despawnTruck(v)
    -- v0.6: the merchant vehicle is a combo — delete the trailer too.
    -- Delete the implement before the root; Vehicle:delete detaches it.
    local trailer = DispatchSmokeTest.adTrailer
    if trailer ~= nil and trailer ~= v and type(trailer.delete) == "function" then
        local ok, err = pcall(trailer.delete, trailer)
        if ok then logf("[trip %d] trailer despawned", DispatchSmokeTest.tripNumber)
        else logf("[trip %d] trailer delete failed: %s", DispatchSmokeTest.tripNumber, tostring(err)) end
    end
    DispatchSmokeTest.adTrailer = nil

    if v == nil then
        logf("[trip %d] despawnTruck: no vehicle", DispatchSmokeTest.tripNumber)
        return
    end
    if type(v.delete) == "function" then
        local ok, err = pcall(v.delete, v)
        if ok then logf("[trip %d] truck despawned", DispatchSmokeTest.tripNumber)
        else logf("[trip %d] truck delete failed: %s", DispatchSmokeTest.tripNumber, tostring(err)) end
    else
        logf("[trip %d] truck has no :delete() — cannot despawn", DispatchSmokeTest.tripNumber)
    end
end

-- Price per litre for a fill type. Prefers the buyer's effective price
-- (the API GrainCollection.lua's own getSellPointsForFillType uses),
-- then the fill type's base price, then a configured fallback.
local function gcGetPricePerLitre(station, fillType)
    if station ~= nil and station.getEffectiveFillTypePrice ~= nil then
        local ok, p = pcall(station.getEffectiveFillTypePrice, station, fillType)
        if ok and p and p > 0 then return p, "buyer" end
    end
    local ftDesc = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
    if ftDesc and ftDesc.pricePerLiter and ftDesc.pricePerLiter > 0 then
        return ftDesc.pricePerLiter, "fillType.pricePerLiter"
    end
    return DispatchSmokeTest.PRICE_PER_LITRE_FALLBACK, "fallback"
end

-- v0.5.99.27: the "sale". The truck has reached DESPAWN_POINT carrying
-- the grain doDirectLoad transferred into it. We do not physically
-- unload — the grain is sold directly: money is credited, the truck
-- (and its grain) despawns. Per-trip, immediate.
function DispatchSmokeTest:doDirectSale(job)
    local fillType = DispatchSmokeTest.collectionFillType
        or (job.fillTypeParameter and job.fillTypeParameter:getFillTypeIndex())
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    local buyer    = DispatchSmokeTest.collectionUnloadingStation

    -- v0.5.99.28: sell exactly what doDirectLoad pulled from the silo
    -- this trip. The previous approach summed truck fillUnit levels,
    -- which double-counted — the Lizard MultiPurpose exposes one
    -- physical cargo hold under multiple fillUnit indices, each
    -- reporting the full level (2000L hold -> 4000L sum -> 2x money).
    local litres = DispatchSmokeTest.tripLoadedLitres or 0

    local price, priceSrc = gcGetPricePerLitre(buyer, fillType)
    local payment   = litres * price
    local ftDesc    = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
    local ftName    = (ftDesc and ftDesc.title) or tostring(fillType)
    local buyerName = (buyer and buyer.getName and buyer:getName()) or "?"

    if payment > 0 and g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        local moneyType = (MoneyType and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER)) or nil
        pcall(g_currentMission.addMoney, g_currentMission, payment, farmId, moneyType, true, true)
    end
    DispatchSmokeTest.collectionTotalLitres = DispatchSmokeTest.collectionTotalLitres + litres
    DispatchSmokeTest.collectionTotalPaid   = DispatchSmokeTest.collectionTotalPaid + payment
    DispatchSmokeTest.tripSaleDone = true
    logf("[direct-sale] trip %d: sold %.0fL of %s to '%s' for £%.2f (price=%.3f/L src=%s)",
        DispatchSmokeTest.tripNumber, litres, ftName, buyerName, payment, price, priceSrc)
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
function DispatchSmokeTest:objectWorldXZ(obj)
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

function DispatchSmokeTest:objectName(obj)
    if obj == nil then return "?" end
    if obj.getName ~= nil then
        local ok, n = pcall(obj.getName, obj)
        if ok and n and n ~= "" then return n end
    end
    return "?"
end

-- Nearest marker (from GrainCollection:listADMarkers entries) to an XZ.
function DispatchSmokeTest:nearestMarker(markers, x, z)
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
function DispatchSmokeTest:matchADMarkers(merchantMarkerId)
    DispatchSmokeTest.adSiloMarkerId   = nil
    DispatchSmokeTest.adBuyerMarkerId  = nil
    DispatchSmokeTest.adSpawnMarkerId  = nil
    DispatchSmokeTest.adSiloMarkerPos  = nil
    DispatchSmokeTest.adBuyerMarkerPos = nil
    DispatchSmokeTest.adSpawnMarkerPos = nil

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

    local radius = DispatchSmokeTest.AD_MATCH_RADIUS

    -- Silo marker — nearest AutoDrive marker to the grain silo.
    local siloX, siloZ = self:objectWorldXZ(DispatchSmokeTest.collectionGrainPlaceable)
    if siloX == nil then
        logf("[AD-match] ABORT: silo world position unresolved")
        gcToast("Cannot dispatch — silo position unknown", "critical")
        return false
    end
    local siloName = self:objectName(DispatchSmokeTest.collectionGrainPlaceable)
    local siloM, siloD = self:nearestMarker(markers, siloX, siloZ)
    if siloM == nil or siloD > radius then
        logf("[AD-match] ABORT: no AutoDrive marker within %dm of silo '%s' at (%.1f, %.1f) — nearest %.0fm",
            radius, siloName, siloX, siloZ, siloD or -1)
        gcToast("No AutoDrive marker near the silo — please place one", "critical")
        return false
    end
    logf("[AD-match] silo='%s' marker=%s '%s' distance=%.1fm",
        siloName, tostring(siloM.id), tostring(siloM.name), siloD)

    -- Buyer marker — nearest AutoDrive marker to the best-buyer station.
    local buyerX, buyerZ = self:objectWorldXZ(DispatchSmokeTest.collectionUnloadingStation)
    if buyerX == nil then
        logf("[AD-match] ABORT: buyer world position unresolved")
        gcToast("Cannot dispatch — buyer position unknown", "critical")
        return false
    end
    local buyerName = self:objectName(DispatchSmokeTest.collectionUnloadingStation)
    local buyerM, buyerD = self:nearestMarker(markers, buyerX, buyerZ)
    if buyerM == nil or buyerD > radius then
        logf("[BOOK] aborted: no AutoDrive marker within %dm of %s at (%.1f, %.1f) — nearest %.0fm",
            radius, buyerName, buyerX, buyerZ, buyerD or -1)
        gcToast(string.format(
            "No AutoDrive marker near %s — place one near %s to enable haulier deliveries",
            buyerName, buyerName), "critical")
        return false
    end
    logf("[AD-match] buyer='%s' marker=%s '%s' distance=%.1fm",
        buyerName, tostring(buyerM.id), tostring(buyerM.name), buyerD)

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
        logf("[AD-match] spawn marker (player-set) = %s '%s'",
            tostring(spawnM.id), tostring(spawnM.name))
    end

    DispatchSmokeTest.adSiloMarkerId   = siloM.id
    DispatchSmokeTest.adBuyerMarkerId  = buyerM.id
    DispatchSmokeTest.adSiloMarkerPos  = { x = siloM.x, z = siloM.z }
    DispatchSmokeTest.adBuyerMarkerPos = { x = buyerM.x, z = buyerM.z }
    if spawnM ~= nil then
        DispatchSmokeTest.adSpawnMarkerId  = spawnM.id
        DispatchSmokeTest.adSpawnMarkerPos = { x = spawnM.x, y = spawnM.y, z = spawnM.z }
    end
    return true
end

-- Build a minimal job-shaped table so the unchanged doDirectLoad /
-- doDirectSale can run without a real AIJob. doDirectLoad needs
-- loadingNodeInfos (truck fill units) + fillTypeParameter; doDirectSale
-- only reads collection state, the shim is a harmless fallback there.
function DispatchSmokeTest:buildJobShim(vehicle)
    local infos = {}
    local fillType = DispatchSmokeTest.collectionFillType
    -- v0.6: the grain is held by the trailer (Krampe SKS), not the FH16.
    -- Search the trailer first, then the truck as a fallback (covers the
    -- legacy single-vehicle case). Stop at the first source that yields a
    -- grain-capable fill unit, so the truck's diesel/DEF units are never
    -- picked when a real grain trailer is present.
    local sources = {}
    if DispatchSmokeTest.adTrailer ~= nil then
        table.insert(sources, DispatchSmokeTest.adTrailer)
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
            getFillTypeIndex = function() return DispatchSmokeTest.collectionFillType end,
        },
        loadingStationParameter = {
            getLoadingStation = function() return DispatchSmokeTest.collectionLoadingStation end,
        },
    }
end

-- Distance from the truck to the current leg's destination marker.
function DispatchSmokeTest:adTruckDistanceToMarker(v, leg)
    if v == nil or v.rootNode == nil then return nil end
    local pos = (leg == "to-silo") and DispatchSmokeTest.adSiloMarkerPos
        or DispatchSmokeTest.adBuyerMarkerPos
    if pos == nil then return nil end
    local ok, tx, _, tz = pcall(getWorldTranslation, v.rootNode)
    if not ok or tx == nil then return nil end
    return math.sqrt((tx - pos.x) ^ 2 + (tz - pos.z) ^ 2)
end

-- Start AutoDrive driving the truck to a marker. Mirrors what the
-- player's "start" does: set DriveTo mode, set the first marker, start
-- the mode (DriveToMode:start calls startAutoDrive itself). Returns
-- true only if AutoDrive actually engaged (stateModule active).
function DispatchSmokeTest:adDriveTo(vehicle, markerId, label)
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
    logf("[AD-drive] %s: started -> marker=%s, AutoDrive active=%s",
        tostring(label), tostring(markerId), tostring(active))
    return active == true
end

-- Begin an AutoDrive trip with the freshly-spawned truck: drive to the
-- silo marker. Called from onSpawned in place of constructJob.
-- v0.6: set the merchant truck's per-vehicle AutoDrive cornerSpeed so it
-- takes corners at ~50% of AutoDrive's default cornering curve. AutoDrive
-- already detects corners itself — this only scales them. See
-- v0.6_AUTODRIVE_SPEED_CONTROL.md. Internal AD API: feature-detected.
function DispatchSmokeTest:applyHaulierCornerSpeed(truck)
    local AD = GrainCollection and GrainCollection.AD or nil
    if AD == nil or type(AD.setSettingState) ~= "function"
            or AD.settings == nil or AD.settings.cornerSpeed == nil then
        logf("[AD-speed] cornerSpeed setting unavailable — using AutoDrive defaults")
        return
    end
    if truck == nil or truck.ad == nil then
        logf("[AD-speed] no truck.ad — cannot set cornerSpeed")
        return
    end
    local idx = DispatchSmokeTest.AD_CORNER_SPEED_INDEX
    local ok, err = pcall(AD.setSettingState, "cornerSpeed", idx, truck)
    if not ok then
        logf("[AD-speed] setSettingState failed: %s", tostring(err))
        return
    end
    local val = "?"
    if type(AD.getSetting) == "function" then
        local okG, v = pcall(AD.getSetting, "cornerSpeed", truck)
        if okG and v ~= nil then val = tostring(v) end
    end
    logf("[AD-speed] cornerSpeed set to index %d (value %s) on merchant truck", idx, val)
end

function DispatchSmokeTest:startAutoDriveTrip(vehicle)
    DispatchSmokeTest.activeVehicle = vehicle
    DispatchSmokeTest.adLegTruck    = vehicle
    DispatchSmokeTest.adLeg         = nil
    DispatchSmokeTest.adLegPollAcc  = 0

    -- v0.6: corner this truck at 50% (per-vehicle AutoDrive setting).
    DispatchSmokeTest:applyHaulierCornerSpeed(vehicle)

    local siloMarker = DispatchSmokeTest.adSiloMarkerId
    if siloMarker == nil then
        logf("[AD-trip] ABORT: no silo marker matched (matchADMarkers not run?)")
        DispatchSmokeTest.dispatchInProgress = false
        DispatchSmokeTest:finishAutoDriveTrip(vehicle)
        return
    end
    logf("[AD-trip] trip %d: dispatching truck to silo marker %s",
        DispatchSmokeTest.tripNumber, tostring(siloMarker))
    if self:adDriveTo(vehicle, siloMarker, "to-silo") then
        DispatchSmokeTest.adLeg = "to-silo"
    else
        logf("[AD-trip] ABORT: could not start the drive to the silo")
        DispatchSmokeTest.dispatchInProgress = false
        DispatchSmokeTest:finishAutoDriveTrip(vehicle)
    end
end

-- Per-frame: poll the AutoDrive leg. stateModule:isActive() is true
-- while driving and flips false when the route ends. adDriveTo already
-- confirmed it was true at leg start, so the first false = leg done.
function DispatchSmokeTest:updateAutoDrive(dt)
    local leg = DispatchSmokeTest.adLeg
    if leg == nil then return end

    local v = DispatchSmokeTest.adLegTruck
    if v == nil or v.ad == nil or v.ad.stateModule == nil then
        logf("[AD-drive] truck / stateModule lost mid-leg — ending trip")
        DispatchSmokeTest.adLeg = nil
        DispatchSmokeTest:finishAutoDriveTrip(v)
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
    local radius = (leg == "to-silo") and DispatchSmokeTest.ARRIVAL_RADIUS
                                       or DispatchSmokeTest.BUYER_ARRIVAL_RADIUS
    local proximityArrived = dist ~= nil and dist <= radius

    if active and not proximityArrived then return end   -- still driving

    if proximityArrived and active then
        logf("[AD-drive] leg=%s proximity arrival (within %dm of marker, stopping AutoDrive)",
            leg, radius)
        if v.stopAutoDrive ~= nil then pcall(v.stopAutoDrive, v) end
    end

    logf("[AD-drive] leg=%s arrived (distance=%s)",
        leg, dist and string.format("%.1fm", dist) or "?")

    if leg == "to-silo" then
        DispatchSmokeTest.adLeg = nil   -- clear before re-entrant calls
        local shim = self:buildJobShim(v)
        logf("[AD-trip] trip %d: arrived at silo — direct-loading (%d fill unit(s))",
            DispatchSmokeTest.tripNumber, #shim.loadingNodeInfos)
        pcall(DispatchSmokeTest.doDirectLoad, DispatchSmokeTest, shim)

        local buyerMarker = DispatchSmokeTest.adBuyerMarkerId
        if buyerMarker ~= nil and self:adDriveTo(v, buyerMarker, "to-buyer") then
            DispatchSmokeTest.adLeg        = "to-buyer"
            DispatchSmokeTest.adLegPollAcc = 0
        else
            logf("[AD-trip] could not start the drive to the buyer — selling in place")
            pcall(DispatchSmokeTest.doDirectSale, DispatchSmokeTest, self:buildJobShim(v))
            DispatchSmokeTest:finishAutoDriveTrip(v)
        end
    elseif leg == "to-buyer" then
        DispatchSmokeTest.adLeg = nil
        logf("[AD-trip] trip %d: arrived at buyer — direct-selling",
            DispatchSmokeTest.tripNumber)
        pcall(DispatchSmokeTest.doDirectSale, DispatchSmokeTest, self:buildJobShim(v))
        DispatchSmokeTest:finishAutoDriveTrip(v)
    end
end

-- End an AutoDrive trip: stop AutoDrive if still running, despawn the
-- truck, then continue the multi-trip loop or finish the collection.
-- Mirrors the tail of onAIJobStopped.
function DispatchSmokeTest:finishAutoDriveTrip(truck)
    DispatchSmokeTest.adLeg              = nil
    DispatchSmokeTest.adLegTruck         = nil
    DispatchSmokeTest.dispatchInProgress = false

    if truck ~= nil then
        if truck.isServer and truck.stopAutoDrive ~= nil and truck.ad ~= nil
                and truck.ad.stateModule ~= nil and truck.ad.stateModule.isActive ~= nil then
            local okA, busy = pcall(truck.ad.stateModule.isActive, truck.ad.stateModule)
            if okA and busy then
                logf("[AD-trip] AutoDrive still active at trip end — stopping it before despawn")
                pcall(truck.stopAutoDrive, truck)
            end
        end
        DispatchSmokeTest:despawnTruck(truck)
    end

    if DispatchSmokeTest.tripState ~= "active" then return end

    if DispatchSmokeTest.tripSaleDone then
        local station  = DispatchSmokeTest.collectionLoadingStation
        local fillType = DispatchSmokeTest.collectionFillType
        local farmId   = g_currentMission and g_currentMission:getFarmId()
        local siloLevel = (station and station.getFillLevel
            and station:getFillLevel(fillType, farmId)) or 0
        if siloLevel > 0.5 and DispatchSmokeTest.tripNumber < DispatchSmokeTest.MAX_TRIPS then
            DispatchSmokeTest.tripState         = "between-trips"
            DispatchSmokeTest.betweenTripsTimer = DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS
            logf("[AD-trip] trip %d done; siloLevel=%.0fL remaining; next trip in %.0fs",
                DispatchSmokeTest.tripNumber, siloLevel,
                DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS / 1000)
            -- v0.6.x UX: tell the player the collection is still running
            -- so the gap between despawn and next spawn doesn't read as
            -- "finished after one trip".
            gcToast(string.format(
                "Grain collection continuing — %sL left, next truck arriving shortly",
                g_i18n:formatNumber(siloLevel, 0)), "info")
        else
            DispatchSmokeTest:endCollection(siloLevel <= 0.5 and "silo empty" or "MAX_TRIPS reached")
        end
    else
        logf("[AD-trip] trip %d FAILED before sale — ending collection",
            DispatchSmokeTest.tripNumber)
        DispatchSmokeTest:endCollection("trip failed")
    end
end


addModEventListener(DispatchSmokeTest)
