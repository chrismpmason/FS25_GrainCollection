--
-- GrainCollection.lua
-- Core logic for booking and processing produce collections.
--
-- Author: Chris Mason
--

GrainCollection = {}
GrainCollection.MOD_NAME = g_currentModName or "FS25_GrainCollection"
-- IMPORTANT: capture at script-load time. g_currentModDirectory is a global
-- that gets reassigned as each mod loads — by runtime it points elsewhere.
GrainCollection.MOD_DIR  = g_currentModDirectory or ""
-- v0.5.0: flip to true for verbose diagnostics. End-user builds ship with
-- DEBUG=false so log.txt stays quiet during normal play. The dbg() helper
-- and most [GC-VERIFY] / spec-debug print clusters gate on this.
GrainCollection.DEBUG = false

function GrainCollection.dbg(msg)
    if GrainCollection.DEBUG then
        print("[FS25_GrainCollection][dbg] " .. tostring(msg))
    end
end

GrainCollection.HAULAGE_FEE = 0.05         -- 5% deduction from sell-point price (instant path only)
GrainCollection.MIN_LOAD_LITRES = 100      -- noise floor; below this, hide from menu
GrainCollection.MAX_LEAD_DAYS = 365        -- up to a full year ahead (seasonal planning)
GrainCollection.SAVEGAME_KEY = "grainCollection"

-- v0.5.0 AutoDrive integration constants (Phase 0 plumbing — read but not
-- consumed by any logic yet; tunable in one place per the locked design.)
GrainCollection.AD_ARRIVAL_THRESHOLD_M     = 30   -- "actually at sell point" check
GrainCollection.AD_ROUTE_TIMEOUT_HOURS     = 6    -- en-route >this -> mark failed
GrainCollection.AD_POLL_INTERVAL_SECONDS   = 5    -- isActive() polling cadence

-- v0.5.0 cached AutoDrive singletons. Populated by detectAutoDrive() at
-- loadMap end. adAvailable gates every AD-dependent code path so the mod
-- behaves identically to v0.4.x when AD is absent.
GrainCollection.AD            = nil
GrainCollection.ADGraph       = nil
GrainCollection.adAvailable   = false
GrainCollection.lastUsedTruck = {}    -- [farmId] = objectId, for default selection

-- v0.4.1: consistent uppercase-L volume formatting. FS25's formatVolume
-- varies between 'l' and 'L' depending on overload; we sidestep it.
local function formatLitres(n)
    n = math.floor(n or 0)
    local body
    if g_i18n ~= nil and g_i18n.formatNumber ~= nil then
        local ok, s = pcall(g_i18n.formatNumber, g_i18n, n, 0)
        if ok and s ~= nil then body = s end
    end
    return (body or tostring(n)) .. " L"
end

-- Valid lead-day stops for the booking cycler. Adaptive to the player's
-- days-per-period setting so each "monthly" click moves exactly one in-game
-- month forward, regardless of game speed.
function GrainCollection:getLeadDaySteps()
    local env = g_currentMission and g_currentMission.environment
    local dpp = (env and env.daysPerPeriod) or 1
    if dpp < 1 then dpp = 1 end

    local stops = {}
    local seen = {}
    local function add(d)
        if d > GrainCollection.MAX_LEAD_DAYS then return end
        if not seen[d] then
            table.insert(stops, d)
            seen[d] = true
        end
    end

    -- Short-term stops (only those that fall before the first monthly stop)
    for _, d in ipairs({0, 1, 3, 7}) do
        if d < dpp then add(d) end
    end

    -- Monthly cadence — one full year forward
    for i = 0, 12 do add(i * dpp) end

    table.sort(stops)
    return stops
end

function GrainCollection:cycleLeadDays(currentLeadDays, direction)
    local steps = self:getLeadDaySteps()
    if #steps == 0 then return 0 end
    local idx = 1
    for i, v in ipairs(steps) do
        if v == currentLeadDays then idx = i; break end
        if v > currentLeadDays then idx = i; break end
    end
    idx = ((idx - 1 + (direction or 1)) % #steps) + 1
    return steps[idx]
end

-- ============================================================
-- Aggregation + TSSC-style price projection
-- ============================================================

local MONTH_NAMES = {
    "Mar", "Apr", "May", "Jun", "Jul", "Aug",
    "Sep", "Oct", "Nov", "Dec", "Jan", "Feb",
}

-- Per-month projected price for a fill type, using the same seasonal factor
-- table the vanilla Prices menu uses. Returns (maxPrice, meanPrice, bestPeriod).
function GrainCollection:getMaxMeanAndMonth(fillType)
    if fillType == nil then return 0, 0, 1 end
    local maxPrice = 0
    local maxPeriod = 1
    local total = 0
    local periodCount = 0
    local base = fillType.pricePerLiter or 0
    local factors = fillType.economy and fillType.economy.factors
    local from = (SeasonPeriod and SeasonPeriod.EARLY_SPRING) or 1
    local to   = (SeasonPeriod and SeasonPeriod.LATE_WINTER)  or 12
    for period = from, to do
        local f = (factors and factors[period]) or 1.0
        local p = base * f
        total = total + p
        periodCount = periodCount + 1
        if p > maxPrice then
            maxPrice = p
            maxPeriod = period
        end
    end
    local mean = (periodCount > 0) and (total / periodCount) or 0
    return maxPrice, mean, maxPeriod
end

-- Convert a target season period (1..12) into leadDays from today, wrapping
-- to next year if the target is earlier in the calendar. <=0 means
-- "day 1 of the current period already passed" — clamped to 0 by the
-- caller so collection fires on the next tick.
function GrainCollection:leadDaysToPeriod(targetPeriod)
    local env = g_currentMission and g_currentMission.environment
    if env == nil then return 0 end
    local dpp = env.daysPerPeriod or 1
    if dpp < 1 then dpp = 1 end
    local cp  = env.currentPeriod or 1
    local cdip = env.currentDayInPeriod or env.currentDayOffset or 1
    local steps = (targetPeriod or cp) - cp
    if steps < 0 then steps = steps + 12 end
    local leadDays = (steps * dpp) - (cdip - 1)
    if leadDays < 0 then leadDays = 0 end
    if leadDays > GrainCollection.MAX_LEAD_DAYS then
        leadDays = GrainCollection.MAX_LEAD_DAYS
    end
    return leadDays
end

-- "Sep Y1" / "Apr Y2" style label for a target period, year computed from
-- how far past period 12 we wrap.
function GrainCollection:formatTargetMonth(targetPeriod)
    local env = g_currentMission and g_currentMission.environment
    local cp = (env and env.currentPeriod) or 1
    local steps = (targetPeriod or cp) - cp
    if steps < 0 then steps = steps + 12 end
    local raw = cp + steps
    local idx = ((raw - 1) % 12) + 1
    local yearsForward = math.floor((raw - 1) / 12)
    return string.format("%s Y%d", MONTH_NAMES[idx] or "?", yearsForward + 1)
end

-- Per-station priceScale read from XML, e.g. Train Stations with elevated
-- prices. Cached per session.
GrainCollection.stationPriceScale = {}
function GrainCollection:getStationPriceScale(station)
    if station == nil then return 1.0 end
    local key = tostring(station)
    local cached = GrainCollection.stationPriceScale[key]
    if cached ~= nil then return cached end

    local scale = 1.0
    local xmlFile = station.owningPlaceable and station.owningPlaceable.xmlFile
    if xmlFile ~= nil and xmlFile.iterate ~= nil then
        local maxScale = 0
        local ok = pcall(function()
            xmlFile:iterate("placeable.sellingStation.fillType", function(_, k)
                local s = xmlFile:getValue(k .. "#priceScale", 1)
                if s ~= nil and s > maxScale then maxScale = s end
            end)
        end)
        if ok and maxScale > 0 then scale = maxScale end
    end
    GrainCollection.stationPriceScale[key] = scale
    return scale
end

-- One row per owned fill type. Combines:
--   * total volume across silos (sum of getOwnedSilos entries)
--   * best current sell point + per-litre price + priceScale + trend bits
--   * best projected price/month from getMaxMeanAndMonth
-- Filtered to types where total >= MIN_LOAD_LITRES.
function GrainCollection:getAggregatedProduce(farmId)
    local entries = self:getOwnedSilos(farmId) or {}
    local byType = {}
    local order = {}
    for _, e in ipairs(entries) do
        local agg = byType[e.fillTypeIndex]
        if agg == nil then
            local fillType = g_fillTypeManager
                and g_fillTypeManager:getFillTypeByIndex(e.fillTypeIndex)
            local maxPrice, meanPrice, bestPeriod = self:getMaxMeanAndMonth(fillType)

            local bestPrice = 0
            local bestStation = ""
            local bestStationRef = nil
            local bestPriceScale = 1.0
            local priceTrend = 0
            local greatDemand = false
            for _, sp in ipairs(e.sellPoints or {}) do
                if sp.pricePerLitre and sp.pricePerLitre > bestPrice then
                    bestPrice = sp.pricePerLitre
                    bestStation = sp.name or ""
                    bestStationRef = sp.station
                    bestPriceScale = self:getStationPriceScale(sp.station)
                    if sp.station and sp.station.getCurrentPricingTrend then
                        local okT, t = pcall(sp.station.getCurrentPricingTrend,
                            sp.station, e.fillTypeIndex)
                        if okT and t then priceTrend = t end
                    end
                    if sp.station and sp.station.greatDemandFillType == e.fillTypeIndex then
                        greatDemand = true
                    end
                end
            end

            agg = {
                fillTypeIndex      = e.fillTypeIndex,
                fillTypeTitle      = (fillType and fillType.title) or "?",
                hudOverlayFilename = fillType and fillType.hudOverlayFilename or nil,
                totalLitres        = 0,
                siloCount          = 0,
                sellPoints         = e.sellPoints,

                bestBuyerName      = bestStation,
                bestBuyerStation   = bestStationRef,
                bestBuyerPrice     = bestPrice,
                bestPriceScale     = bestPriceScale,
                priceTrend         = priceTrend,
                greatDemand        = greatDemand,

                maxPricePerLitre   = maxPrice,
                meanPricePerLitre  = meanPrice,
                bestPeriod         = bestPeriod,
                bestPeriodLabel    = self:formatTargetMonth(bestPeriod),

                hasSellPoint       = (#e.sellPoints > 0 and bestPrice > 0),
            }
            byType[e.fillTypeIndex] = agg
            table.insert(order, agg)
        end
        agg.totalLitres = agg.totalLitres + (e.fillLevel or 0)
        agg.siloCount = agg.siloCount + 1
    end

    local out = {}
    for _, agg in ipairs(order) do
        if agg.totalLitres >= GrainCollection.MIN_LOAD_LITRES then
            table.insert(out, agg)
        end
    end
    return out
end

-- Module-level state: list of pending bookings.
GrainCollection.bookings = {}
GrainCollection.nextId = 1

-- ============================================================
-- Lifecycle
-- ============================================================

function GrainCollection:loadMap(name)
    if FSBaseMission ~= nil and FSBaseMission.saveSavegame ~= nil then
        FSBaseMission.saveSavegame = Utils.appendedFunction(
            FSBaseMission.saveSavegame, GrainCollection.onSave)
    end

    if g_messageCenter ~= nil and MessageType ~= nil and MessageType.HOUR_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, GrainCollection.hourChanged, GrainCollection)
    end

    self:loadFromXML()

    -- Inject the Produce Collection tab into the in-game menu using the
    -- Courseplay/TSStockCheck pattern. The Bookings list + BOOK action are
    -- modal dialogs reachable from the tab.
    GrainCollection.guiRegistered = false
    self:registerGui()

    -- v0.5.0 Phase 0: AutoDrive detection. Populates GrainCollection.AD /
    -- ADGraph / adAvailable. Phase 0 doesn't consume these yet — Phase 1
    -- will read them when building the booking-dialog adContext.
    self:detectAutoDrive()

    -- Defer input registration to first update tick — g_inputBinding isn't
    -- always ready at loadMap time in heavily-modded environments.
    GrainCollection.inputRegistered = false

    print(("[%s] loaded. %d pending booking(s) restored."):format(
        GrainCollection.MOD_NAME, #GrainCollection.bookings))
end

function GrainCollection:update(dt)
    if not GrainCollection.inputRegistered then
        if g_currentMission ~= nil and g_inputBinding ~= nil
           and InputAction ~= nil and InputAction.GRAINCOLLECTION_TOGGLE_MENU ~= nil then
            GrainCollection:registerInputAction()
            GrainCollection.inputRegistered = true
        end
    end
end

function GrainCollection:registerInputAction()
    local success, eventId = g_inputBinding:registerActionEvent(
        InputAction.GRAINCOLLECTION_TOGGLE_MENU,
        GrainCollection,
        GrainCollection.onToggleMenu,
        false, true, false, true)
    if success then
        g_inputBinding:setActionEventTextVisibility(eventId, true)
        if g_i18n ~= nil then
            local label = g_i18n:getText("action_open_menu")
            if label ~= nil and label ~= "" then
                g_inputBinding:setActionEventText(eventId, label)
            end
        end
        print(("[%s] F7 input action registered (eventId=%s)"):format(
            GrainCollection.MOD_NAME, tostring(eventId)))
    else
        print(("[%s] WARNING: F7 registerActionEvent FAILED"):format(
            GrainCollection.MOD_NAME))
    end
end

-- F7 opens the in-game menu and navigates straight to our injected tab.
function GrainCollection:onToggleMenu(actionName, inputValue)
    if g_currentMission == nil or not g_currentMission:getIsClient() then return end
    print(("[%s] F7 pressed -> opening InGameMenu on Produce Collection tab"):format(
        GrainCollection.MOD_NAME))

    pcall(function()
        g_gui:changeScreen(nil, InGameMenu)
        local inGameMenu = g_gui.screenControllers[InGameMenu]
        if inGameMenu == nil then return end
        local page = inGameMenu[GrainCollection.INJECTED_PAGE_NAME or ""]
        if page == nil then return end
        if inGameMenu.pagingElement and inGameMenu.pagingElement.setPage then
            inGameMenu.pagingElement:setPage(page)
        elseif inGameMenu.setSelectedPage then
            inGameMenu:setSelectedPage(page)
        end
    end)
end

-- ============================================================
-- In-game menu injection (Courseplay pattern via TSStockCheck)
-- ============================================================

GrainCollection.INJECTED_PAGE_NAME = "pageProduceCollection"

function GrainCollection:registerGui()
    if GrainCollection.guiRegistered then return end
    if g_gui == nil or TabbedMenuFrameElement == nil or InGameMenu == nil then
        print(("[%s] g_gui / TabbedMenuFrameElement / InGameMenu not ready; skipping registerGui"):format(
            GrainCollection.MOD_NAME))
        return
    end

    local modDir = GrainCollection.MOD_DIR

    -- Custom profiles for our list/header/colour-coded cells.
    local okProf, errProf = pcall(function()
        g_gui:loadProfiles(modDir .. "gui/guiProfiles.xml")
    end)
    if not okProf then
        print(("[%s] ERROR loading guiProfiles.xml: %s"):format(
            GrainCollection.MOD_NAME, tostring(errProf)))
    end

    -- Main tab (TabbedMenuFrameElement)
    local okFrame, errFrame = pcall(function()
        local frame = InGameMenuProduceCollection.new(g_i18n)
        g_gui:loadGui(modDir .. "gui/InGameMenuProduceCollection.xml",
            "InGameMenuProduceCollection", frame, true)
        GrainCollection.produceCollectionFrame = frame
    end)
    if not okFrame then
        print(("[%s] ERROR loading main tab GUI: %s"):format(
            GrainCollection.MOD_NAME, tostring(errFrame)))
        return
    end

    -- Modal: list of pending bookings, with Cancel.
    pcall(function()
        local bookingsDialog = ProduceBookingsDialog.new(g_i18n)
        g_gui:loadGui(modDir .. "gui/ProduceBookingsDialog.xml",
            "ProduceBookingsDialog", bookingsDialog)
        GrainCollection.bookingsDialog = bookingsDialog
    end)

    -- Modal: BOOK action with 3 choices (now / best / cancel).
    pcall(function()
        local bookActionDialog = BookActionDialog.new(g_i18n)
        g_gui:loadGui(modDir .. "gui/BookActionDialog.xml",
            "BookActionDialog", bookActionDialog)
        GrainCollection.bookActionDialog = bookActionDialog
    end)

    -- Splice the main tab into the in-game menu's paging element just
    -- before pageStatistics (matches TSStockCheck placement).
    self:fixInGameMenu()

    GrainCollection.guiRegistered = true
end

function GrainCollection:fixInGameMenu()
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil then
        print(("[%s] ERROR: screenControllers[InGameMenu] nil; tab injection aborted"):format(
            GrainCollection.MOD_NAME))
        return
    end
    if GrainCollection.produceCollectionFrame == nil then return end

    local pageName = GrainCollection.INJECTED_PAGE_NAME
    local frame = GrainCollection.produceCollectionFrame

    -- Find pageStatistics index; fall back to position 2 if not present.
    local insertAt = 0
    for i = 1, #inGameMenu.pagingElement.elements do
        if inGameMenu.pagingElement.elements[i] == inGameMenu["pageStatistics"] then
            insertAt = i
            break
        end
    end
    if insertAt == 0 then insertAt = 2 end

    if inGameMenu.controlIDs ~= nil then
        inGameMenu.controlIDs[pageName] = nil
    end
    inGameMenu[pageName] = frame
    inGameMenu.pagingElement:addElement(inGameMenu[pageName])
    inGameMenu:exposeControlsAsFields(pageName)

    -- Move into position in elements / pages / pageFrames.
    for i = 1, #inGameMenu.pagingElement.elements do
        if inGameMenu.pagingElement.elements[i] == inGameMenu[pageName] then
            table.remove(inGameMenu.pagingElement.elements, i)
            table.insert(inGameMenu.pagingElement.elements, insertAt, inGameMenu[pageName])
            break
        end
    end
    for i = 1, #inGameMenu.pagingElement.pages do
        if inGameMenu.pagingElement.pages[i].element == inGameMenu[pageName] then
            local pg = inGameMenu.pagingElement.pages[i]
            table.remove(inGameMenu.pagingElement.pages, i)
            table.insert(inGameMenu.pagingElement.pages, insertAt, pg)
            break
        end
    end

    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()

    inGameMenu:registerPage(inGameMenu[pageName], insertAt, function() return true end)
    local iconFileName = Utils.getFilename('icon_grainCollection.dds', GrainCollection.MOD_DIR)

    -- v0.4.3 BUG-FIX: UVs MUST be in 1024-reference space, NOT the icon's
    -- actual pixel dimensions. GuiUtils.getUVs divides by 1024 to produce
    -- normalised [0..1] UVs. Always pass {0,0,1024,1024} to show the whole
    -- texture regardless of the icon's actual size.
    inGameMenu:addPageTab(inGameMenu[pageName], iconFileName,
        GuiUtils.getUVs({0, 0, 1024, 1024}))

    for i = 1, #inGameMenu.pageFrames do
        if inGameMenu.pageFrames[i] == inGameMenu[pageName] then
            table.remove(inGameMenu.pageFrames, i)
            table.insert(inGameMenu.pageFrames, insertAt, inGameMenu[pageName])
            break
        end
    end

    inGameMenu:rebuildTabList()
    print(("[%s] Produce Collection tab injected at position %d"):format(
        GrainCollection.MOD_NAME, insertAt))
end

-- ============================================================
-- v0.5.0 Phase 0: AutoDrive detection + enumeration helpers
-- ============================================================
-- All three functions are SAFE TO CALL whether AutoDrive is installed or
-- not. listADTrucks / listADMarkers return empty tables when adAvailable
-- is false. Phase 0 reads but does not branch on these; v0.4.x flow
-- continues untouched.

function GrainCollection:detectAutoDrive()
    -- Primary detection: the Courseplay pattern. FS25 wraps every mod's
    -- globals in a namespace named after the zip filename, so AutoDrive's
    -- globals live at FS25_AutoDrive.AutoDrive / .ADGraphManager.
    if g_modIsLoaded and g_modIsLoaded["FS25_AutoDrive"] then
        if FS25_AutoDrive and FS25_AutoDrive.AutoDrive
                and FS25_AutoDrive.ADGraphManager then
            GrainCollection.AD          = FS25_AutoDrive.AutoDrive
            GrainCollection.ADGraph     = FS25_AutoDrive.ADGraphManager
            GrainCollection.adAvailable = true
            print(("[%s] AD=true source=FS25_AutoDrive.AutoDrive"):format(
                GrainCollection.MOD_NAME))
            return
        end
    end

    -- Fallback: bare global. Lua mod globals can also be reachable as
    -- _G.AutoDrive when the namespace wrapper isn't populated (player
    -- renamed the mod folder, AD loaded out of order, etc.).
    if _G.AutoDrive ~= nil and _G.ADGraphManager ~= nil then
        GrainCollection.AD          = _G.AutoDrive
        GrainCollection.ADGraph     = _G.ADGraphManager
        GrainCollection.adAvailable = true
        print(("[%s] AD=true source=bare_global (renamed folder?)"):format(
            GrainCollection.MOD_NAME))
        return
    end

    GrainCollection.adAvailable = false
    print(("[%s] AD=false (FS25_AutoDrive not installed or not loaded yet)"):format(
        GrainCollection.MOD_NAME))
end

-- Returns a list of AD-equipped vehicles owned by farmId, each entry:
--   { object, name, available, objectId }
-- - available = not currently routing (stateModule:isActive() == false)
-- - objectId  = NetworkUtil.getObjectId(vehicle), for save/load survival
-- Empty list if AD absent. Phase 1 reads this to build the Truck dropdown.
function GrainCollection:listADTrucks(farmId)
    if not GrainCollection.adAvailable then return {} end
    local out = {}
    local vehicles = (g_currentMission and g_currentMission.vehicleSystem
                      and g_currentMission.vehicleSystem.vehicles) or {}
    for _, v in pairs(vehicles) do
        if v.ad ~= nil then
            local owner = 0
            if v.getOwnerFarmId ~= nil then
                local okO, fid = pcall(v.getOwnerFarmId, v)
                if okO and fid ~= nil then owner = fid end
            end
            if owner == farmId or owner == 0 then
                local available = true
                if v.ad.stateModule and v.ad.stateModule.isActive then
                    local okA, busy = pcall(v.ad.stateModule.isActive, v.ad.stateModule)
                    if okA and busy then available = false end
                end
                local name = "?"
                if v.getName ~= nil then
                    local okN, n = pcall(v.getName, v)
                    if okN and n and n ~= "" then name = n end
                end
                local objectId = -1
                if NetworkUtil ~= nil and NetworkUtil.getObjectId ~= nil then
                    local okI, id = pcall(NetworkUtil.getObjectId, v)
                    if okI and id ~= nil then objectId = id end
                end
                table.insert(out, {
                    object    = v,
                    name      = name,
                    available = available,
                    objectId  = objectId,
                })
            end
        end
    end
    return out
end

-- ============================================================
-- v0.5.0 Phase 1: trailer-compat default-truck picker + slim marker list
-- ============================================================

-- True if the vehicle has any attached unit with fillUnit capacity.
-- fillTypeIndex non-nil  -> require that specific fillType be supported.
-- fillTypeIndex nil      -> any non-zero capacity satisfies.
local function vehicleHasCompatibleTrailer(vehicle, fillTypeIndex)
    if vehicle == nil then return false end
    if GrainCollection.AD == nil or GrainCollection.AD.getAllUnits == nil then return false end
    local ok, units = pcall(GrainCollection.AD.getAllUnits, vehicle)
    if not ok or units == nil then return false end
    for _, u in pairs(units) do
        if u ~= vehicle and u.getFillUnits ~= nil then
            local okU, fillUnits = pcall(u.getFillUnits, u)
            if okU and fillUnits ~= nil then
                for _, fu in pairs(fillUnits) do
                    if (fu.capacity or 0) > 0 then
                        if fillTypeIndex == nil then return true end
                        if fu.supportedFillTypes ~= nil
                                and fu.supportedFillTypes[fillTypeIndex] then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Phase 1 default-truck picker per locked spec. Layered fallback:
--   (a) AD-equipped + grain-compatible trailer  -> reason="grain-compatible"
--   (b) AD-equipped + any trailer               -> reason="first-trailer"
--   (c) AD-equipped, no trailer                 -> reason="first-any"
--   (d) nothing                                 -> reason="none", vehicle=nil
-- Most-recently-used tiebreak for (a): GrainCollection.lastUsedTruck[farmId]
-- is consulted first; Phase 2 maintains that map on successful dispatch.
function GrainCollection:getDefaultHaulageTruck(farmId, fillTypeIndex)
    if not GrainCollection.adAvailable then
        return { vehicle = nil, reason = "none" }
    end
    local trucks = self:listADTrucks(farmId)
    local lastUsedId = GrainCollection.lastUsedTruck[farmId]

    local grainCompat, anyTrailer, anyTruck = nil, nil, nil
    local grainCompatLastUsed = nil
    for _, t in ipairs(trucks) do
        if t.available then
            if anyTruck == nil then anyTruck = t end
            if vehicleHasCompatibleTrailer(t.object, fillTypeIndex) then
                if t.objectId == lastUsedId then
                    grainCompatLastUsed = t
                elseif grainCompat == nil then
                    grainCompat = t
                end
            elseif vehicleHasCompatibleTrailer(t.object, nil) and anyTrailer == nil then
                anyTrailer = t
            end
        end
    end

    if grainCompatLastUsed ~= nil then
        return { vehicle = grainCompatLastUsed.object, reason = "grain-compatible" }
    end
    if grainCompat ~= nil then
        return { vehicle = grainCompat.object, reason = "grain-compatible" }
    end
    if anyTrailer ~= nil then
        return { vehicle = anyTrailer.object, reason = "first-trailer" }
    end
    if anyTruck ~= nil then
        return { vehicle = anyTruck.object, reason = "first-any" }
    end
    return { vehicle = nil, reason = "none" }
end

-- Slim marker list for the dropdowns: { {id, name}, ... } sorted by name.
-- Uses Phase 0's listADMarkers under the hood, drops x/y/z.
function GrainCollection:getADMarkerList()
    local full = self:listADMarkers()
    local out = {}
    for _, m in ipairs(full) do
        table.insert(out, { id = m.id, name = m.name })
    end
    return out
end

-- ============================================================

-- Returns a list of AutoDrive map markers, each entry:
--   { id, name, x, y, z }
-- Empty list if AD absent. Phase 1 reads this to build From/To dropdowns.
function GrainCollection:listADMarkers()
    if not GrainCollection.adAvailable then return {} end
    if GrainCollection.AD == nil or GrainCollection.AD.GetAvailableDestinations == nil then
        return {}
    end
    local out = {}
    local ok, dests = pcall(GrainCollection.AD.GetAvailableDestinations, GrainCollection.AD)
    if not ok or dests == nil then return out end
    for id, d in pairs(dests) do
        table.insert(out, {
            id   = id,
            name = d.name or "?",
            x    = d.x or 0,
            y    = d.y or 0,
            z    = d.z or 0,
        })
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

-- ============================================================
-- Sell-point discovery
-- ============================================================

-- Best-effort station name. Stations vary widely in how they expose this.
local function stationName(station)
    if station == nil then return "Sell Point" end
    if station.getName ~= nil then
        local ok, n = pcall(station.getName, station)
        if ok and n and n ~= "" then return n end
    end
    if station.owningPlaceable ~= nil and station.owningPlaceable.getName ~= nil then
        local ok, n = pcall(station.owningPlaceable.getName, station.owningPlaceable)
        if ok and n and n ~= "" then return n end
    end
    if station.stationName then return station.stationName end
    return "Sell Point"
end

-- Returns a list of { name, pricePerLitre, station } for every unloading
-- station that accepts the given fill type, sorted by price desc.
function GrainCollection:getSellPointsForFillType(fillTypeIndex)
    local out = {}
    if g_currentMission == nil or g_currentMission.storageSystem == nil
            or g_currentMission.storageSystem.getUnloadingStations == nil then
        return out
    end

    for _, station in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        if station.acceptedFillTypes ~= nil
                and station.acceptedFillTypes[fillTypeIndex]
                and station.getEffectiveFillTypePrice ~= nil then
            local ok, price = pcall(station.getEffectiveFillTypePrice, station, fillTypeIndex)
            if ok and price and price > 0 then
                table.insert(out, {
                    name = stationName(station),
                    pricePerLitre = price,
                    station = station,
                })
            end
        end
    end

    table.sort(out, function(a, b) return a.pricePerLitre > b.pricePerLitre end)
    return out
end

-- ============================================================
-- Silo discovery
-- ============================================================

-- v0.5.0: explicit category filter. A placeable counts as a grain-eligible
-- silo if at least one of its storage units supports a fill type that has
-- registered sell points on this map. Cleanly excludes diesel tanks
-- (DIESEL has no sell points) without relying on the side-effect of
-- "sellPoints=0 -> drop row" later in the pipeline.
function GrainCollection:isGrainEligibleSilo(placeable)
    if placeable == nil or placeable.spec_silo == nil then return false end
    local storages = placeable.spec_silo.storages
    if storages == nil then return false end
    for _, storage in ipairs(storages) do
        local supported = nil
        if storage.getSupportedFillTypes ~= nil then
            local ok, st = pcall(storage.getSupportedFillTypes, storage)
            if ok and st ~= nil then supported = st end
        end
        if supported == nil then supported = storage.fillLevels end
        if supported ~= nil then
            for fillTypeIndex, _ in pairs(supported) do
                local sellPoints = self:getSellPointsForFillType(fillTypeIndex)
                if sellPoints ~= nil and #sellPoints > 0 then
                    return true
                end
            end
        end
    end
    return false
end

-- Returns a table of silo entries the farm can sell from.
-- Each entry: { storage, placeable, placeableName, fillTypeIndex, fillLevel, sellPoints }
function GrainCollection:getOwnedSilos(farmId)
    local results = {}
    local debug = {}
    local seenStorages = {}
    local sellPointsCache = {}

    table.insert(debug, ("getOwnedSilos called, farmId=%s"):format(tostring(farmId)))

    local function getSellPoints(fillTypeIndex)
        if sellPointsCache[fillTypeIndex] == nil then
            sellPointsCache[fillTypeIndex] = self:getSellPointsForFillType(fillTypeIndex)
        end
        return sellPointsCache[fillTypeIndex]
    end

    local function processStorage(storage, placeable, sourceLabel)
        if storage == nil or seenStorages[storage] then return end
        seenStorages[storage] = true

        local placeableName = "Silo"
        if placeable ~= nil then
            if placeable.getName ~= nil then
                placeableName = placeable:getName() or "Silo"
            elseif placeable.name ~= nil then
                placeableName = placeable.name
            end
        end

        local ownerFarm = "?"
        if storage.getOwnerFarmId ~= nil then
            ownerFarm = tostring(storage:getOwnerFarmId())
        elseif storage.ownerFarmId ~= nil then
            ownerFarm = tostring(storage.ownerFarmId)
        end
        if ownerFarm == "?" and placeable ~= nil then
            if placeable.getOwnerFarmId ~= nil then
                ownerFarm = tostring(placeable:getOwnerFarmId())
            elseif placeable.ownerFarmId ~= nil then
                ownerFarm = tostring(placeable.ownerFarmId)
            end
        end

        local fillLevels = nil
        if storage.getFillLevels ~= nil then
            fillLevels = storage:getFillLevels()
        elseif storage.fillLevels ~= nil then
            fillLevels = storage.fillLevels
        end

        if fillLevels == nil then
            table.insert(debug, ("  [%s] %s owner=%s NO fillLevels"):format(sourceLabel, placeableName, ownerFarm))
            return
        end

        -- Match if owner is this farm, unknown owner, or owner 0 (custom maps).
        local farmMatch = (ownerFarm == tostring(farmId)) or (ownerFarm == "?") or (ownerFarm == "0")
        table.insert(debug, ("  [%s] %s owner=%s match=%s"):format(
            sourceLabel, placeableName, ownerFarm, tostring(farmMatch)))
        if not farmMatch then return end

        for fillTypeIndex, fillLevel in pairs(fillLevels) do
            if fillLevel and fillLevel >= GrainCollection.MIN_LOAD_LITRES then
                local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                local typeName = fillType and fillType.name or "?"
                local sellPoints = getSellPoints(fillTypeIndex)
                table.insert(debug, ("    fillType=%s amount=%d sellPoints=%d"):format(
                    typeName, math.floor(fillLevel), #sellPoints))

                if #sellPoints > 0 then
                    table.insert(results, {
                        storage = storage,
                        placeable = placeable,
                        placeableName = placeableName,
                        fillTypeIndex = fillTypeIndex,
                        fillLevel = fillLevel,
                        sellPoints = sellPoints,
                    })
                end
            end
        end
    end

    -- Path 1: global storage registry (vanilla).
    if g_currentMission ~= nil and g_currentMission.storageSystem ~= nil
            and g_currentMission.storageSystem.getStorages ~= nil then
        local storages = g_currentMission.storageSystem:getStorages()
        table.insert(debug, ("storageSystem path: found %d storage(s)"):format(#storages))
        for _, storage in ipairs(storages) do
            processStorage(storage, storage.owningPlaceable, "storageSystem")
        end
    end

    -- Path 2: walk placeables (custom maps that skip the global registry).
    local placeables = {}
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        if g_currentMission.placeableSystem.getPlaceables ~= nil then
            placeables = g_currentMission.placeableSystem:getPlaceables() or {}
        elseif g_currentMission.placeableSystem.placeables ~= nil then
            placeables = g_currentMission.placeableSystem.placeables or {}
        end
    end

    table.insert(debug, ("placeableSystem path: found %d placeable(s)"):format(#placeables))

    for _, placeable in ipairs(placeables) do
        -- v0.5.0: explicit grain-eligibility gate. Skip the entire
        -- placeable if none of its storages support a sellable fill type
        -- (e.g. diesel tanks: DIESEL has no sell points on this map).
        if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil
                and self:isGrainEligibleSilo(placeable) then
            for _, storage in ipairs(placeable.spec_silo.storages) do
                processStorage(storage, placeable, "spec_silo")
            end
        end

        if placeable.storage ~= nil and type(placeable.storage) == "table"
                and (placeable.storage.fillLevels or placeable.storage.getFillLevels) then
            processStorage(placeable.storage, placeable, "placeable.storage")
        end

        if placeable.spec_loadingStation ~= nil
                and placeable.spec_loadingStation.loadingStation ~= nil then
            local ls = placeable.spec_loadingStation.loadingStation
            if ls.getAllFillLevels ~= nil then
                local allLevels = ls:getAllFillLevels(farmId) or {}
                for fillTypeIndex, fillLevel in pairs(allLevels) do
                    if fillLevel and fillLevel >= GrainCollection.MIN_LOAD_LITRES then
                        local sellPoints = getSellPoints(fillTypeIndex)
                        if #sellPoints > 0 then
                            local key = tostring(ls) .. ":" .. tostring(fillTypeIndex)
                            if not seenStorages[key] then
                                seenStorages[key] = true
                                local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                                table.insert(debug, ("  [loadingStation] %s %s amount=%d sellPoints=%d"):format(
                                    placeable.getName and placeable:getName() or "?",
                                    fillType and fillType.name or "?",
                                    math.floor(fillLevel), #sellPoints))
                                table.insert(results, {
                                    storage = ls,
                                    placeable = placeable,
                                    placeableName = placeable.getName and placeable:getName() or "Silo",
                                    fillTypeIndex = fillTypeIndex,
                                    fillLevel = fillLevel,
                                    sellPoints = sellPoints,
                                    viaLoadingStation = true,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    if GrainCollection.DEBUG then
        for _, line in ipairs(debug) do
            print(("[%s] %s"):format(GrainCollection.MOD_NAME, line))
        end
        print(("[%s] getOwnedSilos found %d eligible entry(ies)"):format(
            GrainCollection.MOD_NAME, #results))
    end

    return results
end

-- ============================================================
-- MoneyType routing
-- ============================================================
-- We can't know which MoneyType constants exist in a given runtime, so we
-- resolve them lazily and fall back to SOLD_PRODUCTS if a preferred one is
-- missing. A startup log dump tells us what was resolved.

local CROP_NAMES = {
    WHEAT=true, BARLEY=true, OAT=true, OATS=true, CANOLA=true, MAIZE=true,
    SOYBEAN=true, SUNFLOWER=true, SORGHUM=true, RYE=true,
    POTATO=true, SUGARBEET=true, SUGARBEET_CUT=true, SUGARCANE=true,
    COTTON=true, GRAPE=true, OLIVE=true,
    GREEN_BEANS=true, PEAS=true, SPINACH=true, PARSNIP=true, CARROT=true,
    BEETROOT=true, RED_CABBAGE=true, RICE=true, RICELONGGRAIN=true,
}
local MILK_NAMES = { MILK=true, GOATMILK=true, BUFFALOMILK=true }
local EGG_NAMES  = { EGG=true }
local WOOL_NAMES = { WOOL=true }
local WOOD_NAMES = { WOODCHIPS=true }
local CROP_CATEGORIES = {
    GRAIN=true, CEREAL=true, ROOT_CROP=true, VEGETABLE=true,
}

function GrainCollection:resolveMoneyTypes()
    if GrainCollection.moneyTypeCache ~= nil then return end
    if MoneyType == nil then
        GrainCollection.moneyTypeCache = {}
        return
    end
    local cache = {
        harvest = MoneyType.HARVEST_INCOME,
        milk    = MoneyType.SOLD_MILK,
        wool    = MoneyType.SOLD_WOOL,
        eggs    = MoneyType.SOLD_EGGS,
        wood    = MoneyType.SOLD_WOOD,
        default = MoneyType.SOLD_PRODUCTS,
    }
    GrainCollection.moneyTypeCache = cache
    for _, k in ipairs({"harvest", "milk", "wool", "eggs", "wood", "default"}) do
        print(("[%s] MoneyType.%-7s -> %s"):format(
            GrainCollection.MOD_NAME, k, tostring(cache[k])))
    end
end

function GrainCollection:getMoneyTypeForFillType(fillTypeIndex)
    self:resolveMoneyTypes()
    local cache = GrainCollection.moneyTypeCache or {}
    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if ft == nil then return cache.default end

    local name = ft.name
    if MILK_NAMES[name] and cache.milk    then return cache.milk    end
    if EGG_NAMES[name]  and cache.eggs    then return cache.eggs    end
    if WOOL_NAMES[name] and cache.wool    then return cache.wool    end
    if WOOD_NAMES[name] and cache.wood    then return cache.wood    end
    if CROP_NAMES[name] and cache.harvest then return cache.harvest end

    if CROP_CATEGORIES[ft.categoryName] and cache.harvest then
        return cache.harvest
    end
    return cache.default
end

-- ============================================================
-- Notifications
-- ============================================================

-- Big green banner like the "Special Offer" notification. Falls back
-- silently if the HUD API isn't available on this runtime.
function GrainCollection:showBanner(text, color, duration)
    color = color or {0.05, 0.65, 0.05, 1}
    duration = duration or 8000
    if g_currentMission == nil or g_currentMission.hud == nil then return end

    local hud = g_currentMission.hud
    if hud.addSideNotification ~= nil then
        local ok = pcall(hud.addSideNotification, hud, color, text, duration)
        if ok then return end
    end
    if hud.sideNotifications ~= nil and hud.sideNotifications.addNotification ~= nil then
        pcall(hud.sideNotifications.addNotification,
            hud.sideNotifications, text, color, duration)
    end
end

-- ============================================================
-- Pricing
-- ============================================================

function GrainCollection:calculateQuote(fillTypeIndex, litres, pricePerLitre)
    pricePerLitre = pricePerLitre or 0
    local gross = pricePerLitre * litres
    local fee   = gross * GrainCollection.HAULAGE_FEE
    local net   = gross - fee
    return {
        pricePerLitre = pricePerLitre,
        gross = gross,
        fee = fee,
        net = net,
    }
end

-- ============================================================
-- Booking
-- ============================================================

-- v0.4.0 (TSSC-pattern): take an aggregated produce entry (one fillType,
-- summed across silos) + a target leadDays. monthLabel is purely for
-- display ("Sep Y1"). Fulfilment drains across every owned silo holding
-- the fill type until booked litres are satisfied.
function GrainCollection:bookCollection(farmId, aggregate, sellPoint, leadDays, monthLabel)
    if aggregate == nil or (aggregate.totalLitres or 0) < GrainCollection.MIN_LOAD_LITRES then
        return false, "Not enough produce of that type"
    end
    if sellPoint == nil then
        return false, "No sell point selected"
    end

    leadDays = math.max(0, math.min(GrainCollection.MAX_LEAD_DAYS, leadDays or 0))
    local env = g_currentMission.environment
    local dueDay = env.currentDay + leadDays

    local quote = self:calculateQuote(
        aggregate.fillTypeIndex, aggregate.totalLitres, sellPoint.pricePerLitre)

    local booking = {
        id                   = GrainCollection.nextId,
        farmId               = farmId,
        fillTypeIndex        = aggregate.fillTypeIndex,
        litres               = aggregate.totalLitres,
        dueDay               = dueDay,
        pricePerLitre        = quote.pricePerLitre,
        totalNet             = quote.net,
        unloadingStationName = sellPoint.name,
        targetMonthLabel     = monthLabel or "",
    }
    GrainCollection.nextId = GrainCollection.nextId + 1
    table.insert(GrainCollection.bookings, booking)

    print(("[%s] booked: id=%d dueDay=%d (today=%d, lead=%d, %s) litres=%d -> %s net=£%d"):format(
        GrainCollection.MOD_NAME, booking.id, dueDay, env.currentDay, leadDays,
        booking.targetMonthLabel,
        math.floor(booking.litres), tostring(booking.unloadingStationName),
        math.floor(booking.totalNet)))

    if g_server ~= nil then
        g_server:broadcastEvent(GrainCollectionEvent.new("book", booking))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(
            GrainCollectionEvent.new("book", booking))
    end

    g_currentMission:addIngameNotification(
        FSBaseMission.INGAME_NOTIFICATION_OK,
        string.format(g_i18n:getText("notify_booked"),
            formatLitres(booking.litres),
            booking.targetMonthLabel,
            g_i18n:formatMoney(booking.totalNet)))

    return true, booking
end

function GrainCollection:cancelBooking(bookingId)
    for i, b in ipairs(GrainCollection.bookings) do
        if b.id == bookingId then
            table.remove(GrainCollection.bookings, i)
            g_currentMission:addIngameNotification(
                FSBaseMission.INGAME_NOTIFICATION_INFO,
                g_i18n:getText("notify_cancelled"))
            return true
        end
    end
    return false
end

-- ============================================================
-- Tick: check for due collections
-- ============================================================

function GrainCollection:hourChanged()
    if g_server == nil then return end
    if g_currentMission == nil or g_currentMission.environment == nil then return end

    local currentDay = g_currentMission.environment.currentDay
    local currentHour = g_currentMission.environment.currentHour

    if #GrainCollection.bookings > 0 then
        print(("[%s] hour tick: day=%d hour=%d, %d pending booking(s)"):format(
            GrainCollection.MOD_NAME, currentDay, currentHour, #GrainCollection.bookings))
    end

    local readyToProcess = (currentHour >= 9)

    local toProcess = {}
    for i, b in ipairs(GrainCollection.bookings) do
        if b.dueDay <= currentDay and readyToProcess then
            table.insert(toProcess, i)
        end
    end

    if #toProcess == 0 then return end

    print(("[%s] processing %d collection(s) at day=%d hour=%d"):format(
        GrainCollection.MOD_NAME, #toProcess, currentDay, currentHour))

    for i = #toProcess, 1, -1 do
        local idx = toProcess[i]
        self:processCollection(GrainCollection.bookings[idx])
        table.remove(GrainCollection.bookings, idx)
    end
end

function GrainCollection:processCollection(booking)
    print(("[%s] processCollection: id=%d fillType=%d booked=%d -> %s"):format(
        GrainCollection.MOD_NAME, booking.id, booking.fillTypeIndex,
        math.floor(booking.litres or 0), tostring(booking.unloadingStationName)))

    -- Aggregated bookings rescan and drain across all silos holding the
    -- fill type, in discovery order, until booking.litres is satisfied.
    local entries = self:getOwnedSilos(booking.farmId)
    local matching = {}
    for _, e in ipairs(entries) do
        if e.fillTypeIndex == booking.fillTypeIndex then
            table.insert(matching, e)
        end
    end

    if #matching == 0 then
        print(("[%s]   FAILED: no silos hold fillType=%d for farm %d"):format(
            GrainCollection.MOD_NAME, booking.fillTypeIndex, booking.farmId))
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_INFO,
            "Produce collection failed: no produce found")
        return
    end

    -- Option C pricing: re-query the booked station for TODAY's price. Fall
    -- back to the booking-time estimate if the station can't be resolved.
    local livePrice = nil
    if booking.unloadingStationName ~= nil and booking.unloadingStationName ~= ""
            and g_currentMission ~= nil and g_currentMission.storageSystem ~= nil
            and g_currentMission.storageSystem.getUnloadingStations ~= nil then
        for _, station in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
            if stationName(station) == booking.unloadingStationName
                    and station.acceptedFillTypes
                    and station.acceptedFillTypes[booking.fillTypeIndex]
                    and station.getEffectiveFillTypePrice ~= nil then
                local ok, p = pcall(station.getEffectiveFillTypePrice,
                    station, booking.fillTypeIndex)
                if ok and p and p > 0 then
                    livePrice = p
                    break
                end
            end
        end
    end
    local effectivePrice = livePrice or booking.pricePerLitre or 0
    print(("[%s]   pricing: estimate=£%.3f/L live=%s effective=£%.3f/L"):format(
        GrainCollection.MOD_NAME,
        booking.pricePerLitre or 0,
        livePrice and string.format("£%.3f/L", livePrice) or "n/a",
        effectivePrice))

    -- Drain across matching silos until target satisfied.
    local target = booking.litres or 0
    local actualLitres = 0
    for _, e in ipairs(matching) do
        if target <= 0 then break end
        local storage = e.storage
        local available = e.fillLevel or 0
        if storage ~= nil and available > 0 then
            local take = math.min(available, target)
            local removed = false
            if storage.setFillLevel ~= nil then
                local ok, err = pcall(storage.setFillLevel, storage,
                    available - take, booking.fillTypeIndex)
                if ok then removed = true
                else print(("[%s]   setFillLevel failed on %s: %s"):format(
                    GrainCollection.MOD_NAME, e.placeableName or "?", tostring(err))) end
            end
            if not removed and storage.changeFillLevels ~= nil then
                local delta = {[booking.fillTypeIndex] = -take}
                local ok, err = pcall(storage.changeFillLevels, storage, delta)
                if ok then removed = true
                else print(("[%s]   changeFillLevels failed on %s: %s"):format(
                    GrainCollection.MOD_NAME, e.placeableName or "?", tostring(err))) end
            end
            if removed then
                actualLitres = actualLitres + take
                target = target - take
                print(("[%s]   drained %d L from %s (remaining target: %d L)"):format(
                    GrainCollection.MOD_NAME, math.floor(take),
                    e.placeableName or "?", math.floor(target)))
            end
        end
    end

    if actualLitres < GrainCollection.MIN_LOAD_LITRES then
        print(("[%s]   not enough produce at collection time (%dL across %d silo(s))"):format(
            GrainCollection.MOD_NAME, math.floor(actualLitres), #matching))
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_INFO,
            "Collection cancelled — not enough in silos")
        return
    end

    local quote = self:calculateQuote(
        booking.fillTypeIndex, actualLitres, effectivePrice)

    local moneyType = self:getMoneyTypeForFillType(booking.fillTypeIndex)
        or MoneyType.SOLD_PRODUCTS
    g_currentMission:addMoney(quote.net, booking.farmId, moneyType, true, true)

    print(("[%s]   collection complete: paid £%d to farm %d (moneyType=%s)"):format(
        GrainCollection.MOD_NAME, math.floor(quote.net), booking.farmId,
        tostring(moneyType)))

    local ft = g_fillTypeManager:getFillTypeByIndex(booking.fillTypeIndex)
    local fillTitle = (ft and ft.title) or "Produce"
    local bannerText = string.format(g_i18n:getText("notify_banner"),
        formatLitres(actualLitres),
        fillTitle,
        g_i18n:formatMoney(quote.net))

    self:showBanner(bannerText)
    g_currentMission:addIngameNotification(
        FSBaseMission.INGAME_NOTIFICATION_OK, bannerText)
end

-- ============================================================
-- Save / Load
-- ============================================================

function GrainCollection.onSave()
    GrainCollection:saveToXML()
end

function GrainCollection:getSaveXMLPath()
    if g_currentMission.missionInfo == nil then return nil end
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then return nil end
    return savegameDir .. "/" .. GrainCollection.SAVEGAME_KEY .. ".xml"
end

function GrainCollection:saveToXML()
    local path = self:getSaveXMLPath()
    if path == nil then return end

    local xml = createXMLFile("grainCollectionSave", path, "grainCollection")
    setXMLInt(xml, "grainCollection#nextId", GrainCollection.nextId)

    for i, b in ipairs(GrainCollection.bookings) do
        local key = string.format("grainCollection.booking(%d)", i - 1)
        setXMLInt(xml,    key .. "#id",                   b.id)
        setXMLInt(xml,    key .. "#farmId",               b.farmId)
        setXMLInt(xml,    key .. "#fillTypeIndex",        b.fillTypeIndex)
        setXMLFloat(xml,  key .. "#litres",               b.litres)
        setXMLInt(xml,    key .. "#dueDay",               b.dueDay)
        setXMLFloat(xml,  key .. "#pricePerLitre",        b.pricePerLitre)
        setXMLFloat(xml,  key .. "#totalNet",             b.totalNet)
        setXMLString(xml, key .. "#unloadingStationName", b.unloadingStationName or "")
        setXMLString(xml, key .. "#targetMonthLabel",     b.targetMonthLabel or "")
    end

    saveXMLFile(xml)
    delete(xml)
end

function GrainCollection:loadFromXML()
    local path = self:getSaveXMLPath()
    if path == nil or not fileExists(path) then return end

    local xml = loadXMLFile("grainCollectionLoad", path)
    GrainCollection.nextId = getXMLInt(xml, "grainCollection#nextId") or 1
    GrainCollection.bookings = {}

    local i = 0
    while true do
        local key = string.format("grainCollection.booking(%d)", i)
        if not hasXMLProperty(xml, key) then break end

        table.insert(GrainCollection.bookings, {
            id                   = getXMLInt(xml,    key .. "#id"),
            farmId               = getXMLInt(xml,    key .. "#farmId"),
            fillTypeIndex        = getXMLInt(xml,    key .. "#fillTypeIndex"),
            litres               = getXMLFloat(xml,  key .. "#litres"),
            dueDay               = getXMLInt(xml,    key .. "#dueDay"),
            pricePerLitre        = getXMLFloat(xml,  key .. "#pricePerLitre"),
            totalNet             = getXMLFloat(xml,  key .. "#totalNet"),
            unloadingStationName = getXMLString(xml, key .. "#unloadingStationName") or "",
            targetMonthLabel     = getXMLString(xml, key .. "#targetMonthLabel") or "",
        })
        i = i + 1
    end

    delete(xml)
end

-- ============================================================
-- Register the mod with the engine
-- ============================================================

addModEventListener(GrainCollection)
