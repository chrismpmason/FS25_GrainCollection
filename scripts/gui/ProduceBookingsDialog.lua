--
-- ProduceBookingsDialog.lua
-- v0.6 REPURPOSED: the merchant-arrival-point marker picker.
--
-- The file / class / registration name "ProduceBookingsDialog" is kept
-- as-is to avoid churn (and so the existing, working XML layout and GUI
-- registration need no changes) — but the seasonal-bookings feature it
-- was built for is retired. It now lists the player's AutoDrive markers;
-- selecting one stores it as the farm's merchant arrival marker via
-- GrainCollection:setMerchantMarker. A future cleanup pass may rename it.
--
-- XML method/element names are unchanged so ProduceBookingsDialog.xml
-- needs no edits: list = bookingsList, "Select" button = btnCancelBooking,
-- "Back" button = btnClose, empty text = noBookingsText, title =
-- dialogTitleElement, list cell attributes = title / subtitle.
--

ProduceBookingsDialog = {}
local ProduceBookingsDialog_mt = Class(ProduceBookingsDialog, MessageDialog)

function ProduceBookingsDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or ProduceBookingsDialog_mt)
    self.i18n = g_i18n
    self.markers = {}
    self.farmId = nil
    self.selectedIndex = 1
    self.onPicked = nil
    return self
end

function ProduceBookingsDialog:onCreate()
    ProduceBookingsDialog:superClass().onCreate(self)
end

function ProduceBookingsDialog:onGuiSetupFinished()
    ProduceBookingsDialog:superClass().onGuiSetupFinished(self)
    if self.bookingsList ~= nil then
        self.bookingsList:setDataSource(self)
        self.bookingsList:setDelegate(self)
    end
end

-- Populate the picker. markers = { {id, name, x, y, z}, ... } (from
-- GrainCollection:listADMarkers). onPicked(marker) is called after the
-- player confirms a choice.
function ProduceBookingsDialog:setMarkers(markers, farmId, onPicked)
    self.markers = markers or {}
    self.farmId = farmId
    self.onPicked = onPicked

    -- Pre-highlight the farm's current merchant marker, if one is set.
    self.selectedIndex = 1
    local currentId = nil
    if GrainCollection ~= nil and GrainCollection.getMerchantMarker ~= nil
            and farmId ~= nil then
        currentId = GrainCollection:getMerchantMarker(farmId)
    end
    if currentId ~= nil then
        for i, m in ipairs(self.markers) do
            if m.id == currentId then self.selectedIndex = i break end
        end
    end
    self:refresh()
end

function ProduceBookingsDialog:refresh()
    if self.noBookingsText ~= nil then
        self.noBookingsText:setVisible(#self.markers == 0)
        if #self.markers == 0 then
            self.noBookingsText:setText("No AutoDrive markers found — draw an AutoDrive network and place markers first.")
        end
    end
    if self.selectedIndex > #self.markers then
        self.selectedIndex = math.max(1, #self.markers)
    end
    if self.bookingsList ~= nil then
        self.bookingsList:reloadData()
        -- Highlight the pre-selected row on the list element itself, so
        -- the green highlight and getSelectedIndexInSection() agree from
        -- the start (before the player clicks anything).
        if #self.markers > 0 and self.bookingsList.setSelectedItem ~= nil then
            local idx = math.max(1, math.min(self.selectedIndex or 1, #self.markers))
            pcall(self.bookingsList.setSelectedItem, self.bookingsList, 1, idx)
        end
    end
    if self.btnCancelBooking ~= nil then
        self.btnCancelBooking.disabled = (#self.markers == 0)
    end
end

function ProduceBookingsDialog:onOpen()
    ProduceBookingsDialog:superClass().onOpen(self)
    -- Repurpose the dialog's static labels for the marker picker.
    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText("Choose merchant arrival point")
    end
    if self.btnCancelBooking ~= nil and self.btnCancelBooking.setText ~= nil then
        self.btnCancelBooking:setText("Select")
    end
    if self.bookingsList ~= nil then
        FocusManager:setFocus(self.bookingsList)
    end
end

function ProduceBookingsDialog:onClose()
    ProduceBookingsDialog:superClass().onClose(self)
end

-- ============================================================
-- SmoothList delegate
-- ============================================================

function ProduceBookingsDialog:getNumberOfSections() return 1 end

function ProduceBookingsDialog:getNumberOfItemsInSection(list, section)
    return #self.markers
end

function ProduceBookingsDialog:populateCellForItemInSection(list, section, index, cell)
    local m = self.markers[index]
    if m == nil then return end
    if cell:getAttribute("title") ~= nil then
        cell:getAttribute("title"):setText(tostring(m.name or "?"))
    end
    if cell:getAttribute("subtitle") ~= nil then
        cell:getAttribute("subtitle"):setText(
            string.format("(%.0f, %.0f)", m.x or 0, m.z or 0))
    end
end

-- SmoothList selection callback. The SmoothList notifies its delegate
-- through the FIXED method name `onListSelectionChanged` (SmoothListElement
-- :1938) — the XML `onSelectionChanged` attribute is NOT a real callback.
-- v0.5.99.46 wrongly named this `onBookingSelected`, so it never fired and
-- selectedIndex stayed at its default 1 — the picker always saved
-- markers[1]. (Fixed in v0.5.99.47.)
function ProduceBookingsDialog:onListSelectionChanged(list, section, index)
    if index == nil or index < 1 then return end
    self.selectedIndex = index
end

-- "Select" button (XML id btnCancelBooking) — confirm the highlighted
-- marker as the farm's merchant arrival point, then close.
function ProduceBookingsDialog:onClickCancelBooking()
    -- v0.5.99.47: read the highlighted row straight from the list element.
    -- self.bookingsList.selectedIndex is what drives the green highlight,
    -- so it is always the row the player actually picked — never trust a
    -- separately-mirrored field that may be stale.
    local idx = self.selectedIndex or 1
    if self.bookingsList ~= nil
            and self.bookingsList.getSelectedIndexInSection ~= nil then
        local ok, listIdx = pcall(self.bookingsList.getSelectedIndexInSection,
            self.bookingsList)
        if ok and type(listIdx) == "number" and listIdx >= 1 then
            idx = listIdx
        end
    end
    local m = self.markers[idx]
    if m == nil then return end
    print(("[marker-pick] confirmed: list index=%d -> marker id=%s '%s' (%.0f, %.0f)"):format(
        idx, tostring(m.id), tostring(m.name), m.x or 0, m.z or 0))
    if GrainCollection ~= nil and GrainCollection.setMerchantMarker ~= nil then
        GrainCollection:setMerchantMarker(self.farmId, m.id)
    end
    local cb = self.onPicked
    self:close()
    if cb ~= nil then
        local ok, err = pcall(cb, m)
        if not ok then
            print(("[%s] merchant-marker onPicked callback error: %s"):format(
                tostring(GrainCollection and GrainCollection.MOD_NAME or "FS25_GrainCollection"),
                tostring(err)))
        end
    end
end

function ProduceBookingsDialog:onClickClose()
    self:close()
end
