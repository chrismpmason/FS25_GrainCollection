--
-- InGameMenuProduceCollection.lua
-- v0.4.0 TSSC-pattern table. Tab is injected into the FS25 in-game menu by
-- GrainCollection:fixInGameMenu(). One row per fill type the farm holds,
-- with current/best price + best month + a BOOK button that opens
-- BookActionDialog (3-option modal).
--
-- All booking logic lives in GrainCollection.lua; this file is pure UI.
--

InGameMenuProduceCollection = {}
local InGameMenuProduceCollection_mt = Class(InGameMenuProduceCollection, TabbedMenuFrameElement)

-- v0.4.4: optional row padding for scrollbar verification. When DEBUG_PAD_ROWS
-- is true, reloadFromBackend duplicates the first row until the table has
-- DEBUG_PAD_TO entries, prefixed with "[debug]" so they're easy to spot.
-- Default off — flip to true and rebuild to exercise scrolling, then flip
-- back before shipping.
InGameMenuProduceCollection.DEBUG_PAD_ROWS = false
InGameMenuProduceCollection.DEBUG_PAD_TO   = 12

-- v0.4.1: consistent volume display. FS25's g_i18n:formatVolume() varies
-- between lowercase 'l' and uppercase 'L' depending on overload / locale,
-- so we format the number ourselves and append the unit once.
local function formatLitres(n)
    n = math.floor(n or 0)
    local body
    if g_i18n ~= nil and g_i18n.formatNumber ~= nil then
        local ok, s = pcall(g_i18n.formatNumber, g_i18n, n, 0)
        if ok and s ~= nil then body = s end
    end
    return (body or tostring(n)) .. " L"
end

InGameMenuProduceCollection.GOOD_THRESHOLD       = 0.90
InGameMenuProduceCollection.VERY_GOOD_THRESHOLD  = 0.95

-- Copied from TSSC for visual familiarity. [false]=normal palette, [true]=colour-blind.
InGameMenuProduceCollection.priceColours = {
    great  = { [false] = {0, 1, 0, 1},               [true] = {0.0470, 0.4823, 0.8627, 1} },
    veryGood = { [false] = {0.3763, 0.6038, 0.0782, 1}, [true] = {1, 0.7607, 0.0392, 1} },
    good   = { [false] = {0.9, 0.9, 0.1, 1},         [true] = {0, 0.6196, 0.4509, 1} },
    normal = { [false] = {1, 1, 1, 1},               [true] = {1, 1, 1, 1} },
}

function InGameMenuProduceCollection.new(i18n, customMt)
    local self = TabbedMenuFrameElement.new(nil, customMt or InGameMenuProduceCollection_mt)
    self.name = "InGameMenuProduceCollection"
    self.i18n = i18n
    self.rows = {}
    self.sortKey = "grain"
    self.sortAsc = true
    return self
end

function InGameMenuProduceCollection:copyAttributes(src)
    InGameMenuProduceCollection:superClass().copyAttributes(self, src)
    self.i18n = src.i18n
end

function InGameMenuProduceCollection:onGuiSetupFinished()
    InGameMenuProduceCollection:superClass().onGuiSetupFinished(self)
    if self.stockTable ~= nil then
        self.stockTable:setDataSource(self)
        self.stockTable:setDelegate(self)
    end
end

function InGameMenuProduceCollection:onFrameOpen()
    InGameMenuProduceCollection:superClass().onFrameOpen(self)
    self:reloadFromBackend()
    self:refreshSortIcons()
    if self.stockTable ~= nil then
        FocusManager:setFocus(self.stockTable)
    end
    self:logDialogState("Produce Collection tab")
end

-- Show exactly one sort indicator — the one matching current sortKey/sortAsc.
-- All eight indicator Bitmaps default to visible="false" in the XML; this
-- runs on frame open and after every toggleSort.
function InGameMenuProduceCollection:refreshSortIcons()
    local map = {
        grain     = { "iconGrainAscending",     "iconGrainDescending" },
        value     = { "iconValueAscending",     "iconValueDescending" },
        maxValue  = { "iconMaxValueAscending",  "iconMaxValueDescending" },
        bestMonth = { "iconBestMonthAscending", "iconBestMonthDescending" },
    }
    for k, names in pairs(map) do
        local asc, desc = self[names[1]], self[names[2]]
        if asc  ~= nil then asc:setVisible(k == self.sortKey and self.sortAsc) end
        if desc ~= nil then desc:setVisible(k == self.sortKey and not self.sortAsc) end
    end
end

function InGameMenuProduceCollection:onFrameClose()
    InGameMenuProduceCollection:superClass().onFrameClose(self)
end

-- ============================================================
-- Data
-- ============================================================

function InGameMenuProduceCollection:reloadFromBackend()
    local farmId = (g_currentMission and g_currentMission.getFarmId)
        and g_currentMission:getFarmId() or 1
    self.rows = GrainCollection:getAggregatedProduce(farmId) or {}

    -- v0.4.4 scrollbar verification: pad with duplicates if enabled.
    if InGameMenuProduceCollection.DEBUG_PAD_ROWS and #self.rows > 0 then
        local original = #self.rows
        local template = self.rows[1]
        local target   = InGameMenuProduceCollection.DEBUG_PAD_TO
        while #self.rows < target do
            local padded = {}
            for k, v in pairs(template) do padded[k] = v end
            padded.fillTypeTitle = "[debug] " .. tostring(padded.fillTypeTitle or "?")
            table.insert(self.rows, padded)
        end
        GrainCollection.dbg(("DEBUG_PAD_ROWS active: %d real -> %d total"):format(
            original, #self.rows))
    end

    self:applySort()
    self:updateFooter()
    self:updateViewBookingsLabel()
    if self.stockTable ~= nil then
        self.stockTable:reloadData()
    end
    if self.currentBalanceText ~= nil and g_currentMission ~= nil then
        self.currentBalanceText:setText(g_i18n:formatMoney(g_currentMission:getMoney(), 0, true))
    end

    -- Scrollability check: row count * row height vs the list's visible area.
    -- If content > visible, the SmoothList should activate its slider.
    local rowHeight = 32
    local listH = (self.stockTable and self.stockTable.size and self.stockTable.size[2]) or 0
    local contentH = #self.rows * rowHeight
    GrainCollection.dbg(("table: %d rows x %dpx = %dpx content, list visible ~%dpx, scrollable=%s"):format(
        #self.rows, rowHeight, contentH, listH, tostring(contentH > listH)))
end

function InGameMenuProduceCollection:applySort()
    local key = self.sortKey or "grain"
    local asc = self.sortAsc
    local cmp
    if key == "grain" then
        cmp = function(a, b) return string.lower(a.fillTypeTitle or "") < string.lower(b.fillTypeTitle or "") end
    elseif key == "value" then
        cmp = function(a, b) return (a.totalLitres * a.bestBuyerPrice) < (b.totalLitres * b.bestBuyerPrice) end
    elseif key == "maxValue" then
        cmp = function(a, b)
            return (a.maxPricePerLitre * a.totalLitres * a.bestPriceScale)
                 < (b.maxPricePerLitre * b.totalLitres * b.bestPriceScale)
        end
    elseif key == "bestMonth" then
        cmp = function(a, b) return (a.bestPeriod or 0) < (b.bestPeriod or 0) end
    else
        cmp = function(a, b) return string.lower(a.fillTypeTitle or "") < string.lower(b.fillTypeTitle or "") end
    end
    if not asc then
        local inner = cmp
        cmp = function(a, b) return inner(b, a) end
    end
    table.sort(self.rows, cmp)
end

function InGameMenuProduceCollection:updateFooter()
    local totalVol = 0
    local totalCur = 0
    local totalMax = 0
    for _, r in ipairs(self.rows) do
        totalVol = totalVol + (r.totalLitres or 0)
        if r.hasSellPoint then
            totalCur = totalCur + (r.totalLitres * r.bestBuyerPrice)
        end
        totalMax = totalMax + (r.maxPricePerLitre * r.totalLitres * (r.bestPriceScale or 1.0))
    end
    if self.totalVolume       ~= nil then self.totalVolume:setText(formatLitres(totalVol)) end
    if self.totalCurrentValue ~= nil then self.totalCurrentValue:setText(g_i18n:formatMoney(totalCur, 0, true, true)) end
    if self.totalMaxValue     ~= nil then self.totalMaxValue:setText(g_i18n:formatMoney(totalMax, 0, true, true)) end
end

-- v0.6: the former "View Bookings" button is repurposed as the merchant
-- arrival point indicator + picker entry. Its label shows the farm's
-- currently chosen AutoDrive marker (or "not set").
function InGameMenuProduceCollection:updateViewBookingsLabel()
    if self.viewBookingsButton == nil then return end
    local farmId = (g_currentMission and g_currentMission.getFarmId)
        and g_currentMission:getFarmId() or 1
    local name = "not set"
    if GrainCollection.getMerchantMarker ~= nil then
        local id = GrainCollection:getMerchantMarker(farmId)
        if id ~= nil then
            name = "id " .. tostring(id)
            local ok, markers = pcall(GrainCollection.listADMarkers, GrainCollection)
            if ok and markers ~= nil then
                for _, m in ipairs(markers) do
                    if m.id == id then name = m.name or name break end
                end
            end
        end
    end
    self.viewBookingsButton:setText("Merchant point: " .. name)
end

-- ============================================================
-- SmoothList delegate
-- ============================================================

function InGameMenuProduceCollection:getNumberOfSections() return 1 end

function InGameMenuProduceCollection:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function InGameMenuProduceCollection:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
    if row == nil then return end
    local cb = (g_gameSettings and g_gameSettings.getValue
                and g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE)) or false

    if cell:getAttribute("icon") ~= nil and row.hudOverlayFilename ~= nil then
        cell:getAttribute("icon"):setImageFilename(row.hudOverlayFilename)
    end
    if cell:getAttribute("grain") ~= nil then
        cell:getAttribute("grain"):setText(row.fillTypeTitle or "?")
    end
    if cell:getAttribute("volume") ~= nil then
        cell:getAttribute("volume"):setText(formatLitres(row.totalLitres or 0))
    end

    local curValue = (row.totalLitres or 0) * (row.bestBuyerPrice or 0)
    local maxValue = (row.maxPricePerLitre or 0) * (row.totalLitres or 0) * (row.bestPriceScale or 1.0)

    if cell:getAttribute("currentPrice") ~= nil then
        if row.hasSellPoint then
            cell:getAttribute("currentPrice"):setText(g_i18n:formatMoney(row.bestBuyerPrice * 1000, 0, true, true))
        else
            cell:getAttribute("currentPrice"):setText("-")
        end
    end
    if cell:getAttribute("currentValue") ~= nil then
        if row.hasSellPoint then
            cell:getAttribute("currentValue"):setText(g_i18n:formatMoney(curValue, 0, true, true))
            local colour = InGameMenuProduceCollection.priceColours.normal[cb]
            if maxValue > 0 then
                if curValue >= maxValue then
                    colour = InGameMenuProduceCollection.priceColours.great[cb]
                elseif curValue >= maxValue * InGameMenuProduceCollection.VERY_GOOD_THRESHOLD then
                    colour = InGameMenuProduceCollection.priceColours.veryGood[cb]
                elseif curValue >= maxValue * InGameMenuProduceCollection.GOOD_THRESHOLD then
                    colour = InGameMenuProduceCollection.priceColours.good[cb]
                end
            end
            cell:getAttribute("currentValue").textColor = colour
        else
            cell:getAttribute("currentValue"):setText("-")
            cell:getAttribute("currentValue").textColor = InGameMenuProduceCollection.priceColours.normal[cb]
        end
    end

    if cell:getAttribute("trend") ~= nil then
        local trend = cell:getAttribute("trend")
        local pt = row.priceTrend or 0
        if SellingStation ~= nil and Utils ~= nil and Utils.isBitSet ~= nil then
            if Utils.isBitSet(pt, SellingStation.PRICE_FALLING) then
                trend:applyProfile("gc_trendFalling")
            elseif Utils.isBitSet(pt, SellingStation.PRICE_CLIMBING) then
                trend:applyProfile("gc_trendClimbing")
            elseif Utils.isBitSet(pt, SellingStation.PRICE_GREAT_DEMAND) then
                trend:applyProfile("gc_trendGreatDemand")
            else
                trend:applyProfile("gc_trendArrow")
            end
        end
    end

    if cell:getAttribute("buyer") ~= nil then
        if row.hasSellPoint then
            cell:getAttribute("buyer"):setText(row.bestBuyerName or "?")
        else
            cell:getAttribute("buyer"):setText(g_i18n:getText("ui_no_sellpoint"))
        end
        -- v0.6: in-progress indicator. While the merchant haulier is
        -- collecting this grain, the row shows it (refreshed on menu
        -- open / reload — not a live per-frame update).
        if DispatchSmokeTest ~= nil and DispatchSmokeTest.tripState ~= nil
                and DispatchSmokeTest.tripState ~= "idle"
                and DispatchSmokeTest.collectionFillType == row.fillTypeIndex then
            cell:getAttribute("buyer"):setText("Merchant en route...")
        end
    end
    if cell:getAttribute("maxPrice") ~= nil then
        cell:getAttribute("maxPrice"):setText(
            g_i18n:formatMoney((row.maxPricePerLitre or 0) * 1000 * (row.bestPriceScale or 1.0), 0, true, true))
    end
    if cell:getAttribute("maxValue") ~= nil then
        cell:getAttribute("maxValue"):setText(g_i18n:formatMoney(maxValue, 0, true, true))
    end
    if cell:getAttribute("bestMonth") ~= nil then
        cell:getAttribute("bestMonth"):setText(row.bestPeriodLabel or "?")
        local env = g_currentMission and g_currentMission.environment
        if env and env.currentPeriod == row.bestPeriod then
            cell:getAttribute("bestMonth").textColor = InGameMenuProduceCollection.priceColours.great[cb]
        else
            cell:getAttribute("bestMonth").textColor = InGameMenuProduceCollection.priceColours.normal[cb]
        end
    end

end

-- ============================================================
-- Click handlers
-- ============================================================

function InGameMenuProduceCollection:onListSelectionChanged(list, section, index)
    GrainCollection.dbg(("onListSelectionChanged: section=%s index=%s rows=%d"):format(
        tostring(section), tostring(index), #self.rows))
    self.selectedIndex = index
end

-- Row click → dispatches the AutoDrive merchant haulier (v0.6). Hooked via
-- the SmoothList onClick="onListItemClicked" attribute in the XML. In-row
-- Bitmap onClicks do NOT fire (SmoothList consumes the click at row
-- level), so the whole row is the click target; the gc_bookButton Bitmap
-- is a visual affordance only.
function InGameMenuProduceCollection:onListItemClicked(list, section, index)
    GrainCollection.dbg(("onListItemClicked FIRED: section=%s index=%s rows=%d"):format(
        tostring(section), tostring(index), #self.rows))

    if index == nil or index < 1 then return end
    local row = self.rows[index]
    if row == nil then return end

    GrainCollection.dbg(("row hit: title=%s litres=%d hasSellPoint=%s"):format(
        tostring(row.fillTypeTitle),
        math.floor(row.totalLitres or 0),
        tostring(row.hasSellPoint)))

    if not row.hasSellPoint then
        if g_currentMission and g_currentMission.addIngameNotification then
            g_currentMission:addIngameNotification(
                FSBaseMission.INGAME_NOTIFICATION_INFO,
                g_i18n:getText("ui_no_sellpoint"))
        end
        return
    end

    -- v0.6: BOOK now dispatches the AutoDrive merchant haulier for this
    -- row's grain — the FH16 + Krampe combo drives buyer -> silo -> buyer.
    -- The seasonal BookActionDialog flow is superseded (its code remains
    -- but is no longer reached). Feature-detect the haulier entry point:
    -- if the module is absent or its API changed in a future FS25 build,
    -- log a warning and skip rather than crash.
    if DispatchSmokeTest == nil
            or type(DispatchSmokeTest.startCollectionFromMenu) ~= "function" then
        print(("[%s] ERROR: DispatchSmokeTest.startCollectionFromMenu unavailable — cannot dispatch"):format(
            GrainCollection.MOD_NAME))
        if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
            g_currentMission:addIngameNotification(
                FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                "Merchant haulier unavailable")
        end
        return
    end

    local pok, success, message, needsPicker = pcall(
        DispatchSmokeTest.startCollectionFromMenu, DispatchSmokeTest, row)
    if not pok then
        print(("[%s] startCollectionFromMenu threw: %s"):format(
            GrainCollection.MOD_NAME, tostring(success)))
        success, message, needsPicker = false, "Collection dispatch failed (internal error)", false
    end
    GrainCollection.dbg(("BOOK dispatch: success=%s message=%s needsPicker=%s"):format(
        tostring(success), tostring(message), tostring(needsPicker)))

    -- v0.6: no merchant arrival point set yet → open the picker dialog
    -- so the player can choose one, then click BOOK again.
    if needsPicker then
        if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
            g_currentMission:addIngameNotification(
                FSBaseMission.INGAME_NOTIFICATION_INFO,
                "Choose a merchant arrival point, then click BOOK again")
        end
        self:openMerchantMarkerPicker()
        return
    end

    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil
            and message ~= nil then
        g_currentMission:addIngameNotification(
            success and FSBaseMission.INGAME_NOTIFICATION_INFO
                or FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            tostring(message))
    end
    if success then
        self:reloadFromBackend()
    end
end

function InGameMenuProduceCollection:onBookConfirmed(row, choice)
    if choice ~= "now" and choice ~= "best" then return end
    local farmId = (g_currentMission and g_currentMission.getFarmId)
        and g_currentMission:getFarmId() or 1
    local leadDays = 0
    local monthLabel
    if choice == "now" then
        leadDays = 0
        monthLabel = GrainCollection:formatTargetMonth(
            (g_currentMission and g_currentMission.environment
              and g_currentMission.environment.currentPeriod) or 1)
    else
        leadDays = GrainCollection:leadDaysToPeriod(row.bestPeriod)
        monthLabel = row.bestPeriodLabel
    end
    local sellPoint = {
        name = row.bestBuyerName,
        pricePerLitre = row.bestBuyerPrice,
        station = row.bestBuyerStation,
    }
    local ok, errOrBooking = GrainCollection:bookCollection(
        farmId, row, sellPoint, leadDays, monthLabel)
    if ok then
        self:reloadFromBackend()
    else
        if g_currentMission and g_currentMission.addIngameNotification then
            g_currentMission:addIngameNotification(
                FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                tostring(errOrBooking or "Booking failed"))
        end
    end
end

-- v0.6: the "Merchant point" button opens the marker picker so the
-- player can set / change the merchant arrival point at any time.
-- (XML still binds onClick="onClickViewBookings" — name kept for churn.)
function InGameMenuProduceCollection:onClickViewBookings(button)
    self:openMerchantMarkerPicker()
end

-- Open the merchant-arrival-point picker (the repurposed
-- ProduceBookingsDialog). pcall-guarded — a GUI failure must not crash
-- the menu. Returns true if the dialog opened.
function InGameMenuProduceCollection:openMerchantMarkerPicker()
    if GrainCollection.bookingsDialog == nil or g_gui == nil then
        print(("[%s] ERROR: merchant-marker picker dialog not registered"):format(
            GrainCollection.MOD_NAME))
        return false
    end
    local farmId = (g_currentMission and g_currentMission.getFarmId)
        and g_currentMission:getFarmId() or 1
    local markers = {}
    if GrainCollection.listADMarkers ~= nil then
        local ok, mk = pcall(GrainCollection.listADMarkers, GrainCollection)
        if ok and mk ~= nil then markers = mk end
    end
    local ok, dialog = pcall(g_gui.showDialog, g_gui, "ProduceBookingsDialog")
    if not ok or dialog == nil then
        print(("[%s] ERROR: showDialog('ProduceBookingsDialog') failed: %s"):format(
            GrainCollection.MOD_NAME, tostring(dialog)))
        return false
    end
    if dialog.target ~= nil and dialog.target.setMarkers ~= nil then
        dialog.target:setMarkers(markers, farmId, function()
            self:reloadFromBackend()
        end)
    end
    return true
end

-- ============================================================
-- Sort handlers
-- ============================================================

local function toggleSort(self, key)
    if self.sortKey == key then
        self.sortAsc = not self.sortAsc
    else
        self.sortKey = key
        self.sortAsc = true
    end
    self:refreshSortIcons()
    self:applySort()
    if self.stockTable ~= nil then self.stockTable:reloadData() end
end

function InGameMenuProduceCollection:onClickGrainHeader()      toggleSort(self, "grain")     end
function InGameMenuProduceCollection:onClickValueHeader()      toggleSort(self, "value")     end
function InGameMenuProduceCollection:onClickMaxValueHeader()   toggleSort(self, "maxValue")  end
function InGameMenuProduceCollection:onClickBestMonthHeader()  toggleSort(self, "bestMonth") end

-- ============================================================
-- Debug log on frame open — verification guardrail
-- ============================================================

function InGameMenuProduceCollection:logDialogState(label)
    if not GrainCollection.DEBUG then return end
    local lines = {}
    table.insert(lines, ("[GC-VERIFY] %s OPENED"):format(label))
    table.insert(lines, ("[GC-VERIFY]   frame name: %s"):format(self.name or "<nil>"))
    table.insert(lines, ("[GC-VERIFY]   visible: %s"):format(tostring(self:getIsVisible())))
    table.insert(lines, ("[GC-VERIFY]   stock rows: %d"):format(#self.rows))
    local nilBuyer = 0
    local nilMonth = 0
    for _, r in ipairs(self.rows) do
        if r.bestBuyerName == nil or r.bestBuyerName == "" then nilBuyer = nilBuyer + 1 end
        if r.bestPeriodLabel == nil or r.bestPeriodLabel == "" then nilMonth = nilMonth + 1 end
    end
    table.insert(lines, ("[GC-VERIFY]   rows missing bestBuyerName: %d"):format(nilBuyer))
    table.insert(lines, ("[GC-VERIFY]   rows missing bestPeriodLabel: %d"):format(nilMonth))
    table.insert(lines, ("[GC-VERIFY]   pending bookings: %d"):format(
        (GrainCollection.bookings and #GrainCollection.bookings) or 0))

    -- v0.5.0 Phase 0: AutoDrive diagnostics. Phase 0 doesn't consume these
    -- for any behaviour change; the line is here so we can verify on-disk
    -- detection works before Phase 1 builds the dropdowns.
    local farmId = (g_currentMission and g_currentMission.getFarmId)
                   and g_currentMission:getFarmId() or 1
    local trucks  = GrainCollection:listADTrucks(farmId)
    local markers = GrainCollection:listADMarkers()
    local availableTrucks = 0
    for _, t in ipairs(trucks) do
        if t.available then availableTrucks = availableTrucks + 1 end
    end
    table.insert(lines, ("[GC-VERIFY]   AD=%s trucks=%d (available=%d) markers=%d"):format(
        tostring(GrainCollection.adAvailable),
        #trucks, availableTrucks, #markers))

    for _, l in ipairs(lines) do print(l) end
end
