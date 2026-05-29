--
-- PendingBookingsDialog.lua
-- Lists pending bookings for the player's farm and lets them cancel
-- the highlighted one. Opened from the "View Bookings" button on the
-- Produce Collection tab. Cancellation removes the booking record
-- (GrainCollection:cancelBooking) and the menu's reservation
-- accounting picks up the change on the next reloadFromBackend.
--
-- Mirrors the ProduceBookingsDialog (marker picker) pattern: shared
-- guiProfiles (gc_bookingsDialog / gc_bookingsList / gc_bookingsListItem)
-- so the dialog looks consistent with the picker.
--

PendingBookingsDialog = {}
local PendingBookingsDialog_mt = Class(PendingBookingsDialog, MessageDialog)

local function formatLitres(n)
    n = math.floor(n or 0)
    local body
    if g_i18n ~= nil and g_i18n.formatNumber ~= nil then
        local ok, s = pcall(g_i18n.formatNumber, g_i18n, n, 0)
        if ok and s ~= nil then body = s end
    end
    return (body or tostring(n)) .. " L"
end


function PendingBookingsDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or PendingBookingsDialog_mt)
    self.i18n = g_i18n
    self.bookings = {}
    self.selectedIndex = 1
    self.onChange = nil
    return self
end


function PendingBookingsDialog:onCreate()
    PendingBookingsDialog:superClass().onCreate(self)
end


function PendingBookingsDialog:onGuiSetupFinished()
    PendingBookingsDialog:superClass().onGuiSetupFinished(self)
    if self.bookingsList ~= nil then
        self.bookingsList:setDataSource(self)
        self.bookingsList:setDelegate(self)
    end
end


-- Populate with the current farm's bookings, sorted by due day.
-- onChange() fires after a successful cancellation so the parent menu
-- can reloadFromBackend (refresh the reservation accounting).
function PendingBookingsDialog:setBookings(bookings, onChange)
    local list = {}
    for _, b in ipairs(bookings or {}) do
        table.insert(list, b)
    end
    table.sort(list, function(a, b) return (a.dueDay or 0) < (b.dueDay or 0) end)
    self.bookings = list
    self.onChange = onChange
    self.selectedIndex = 1
    self:refresh()
end


function PendingBookingsDialog:refresh()
    if self.emptyText ~= nil then
        self.emptyText:setVisible(#self.bookings == 0)
    end
    if self.selectedIndex > #self.bookings then
        self.selectedIndex = math.max(1, #self.bookings)
    end
    if self.bookingsList ~= nil then
        self.bookingsList:reloadData()
        if #self.bookings > 0 and self.bookingsList.setSelectedItem ~= nil then
            local idx = math.max(1, math.min(self.selectedIndex or 1, #self.bookings))
            pcall(self.bookingsList.setSelectedItem, self.bookingsList, 1, idx)
        end
    end
    if self.btnCancelSelected ~= nil then
        self.btnCancelSelected.disabled = (#self.bookings == 0)
    end
end


function PendingBookingsDialog:onOpen()
    PendingBookingsDialog:superClass().onOpen(self)
    if self.bookingsList ~= nil then
        FocusManager:setFocus(self.bookingsList)
    end
end


function PendingBookingsDialog:onClose()
    PendingBookingsDialog:superClass().onClose(self)
end


-- ============================================================
-- SmoothList delegate
-- ============================================================

function PendingBookingsDialog:getNumberOfSections() return 1 end

function PendingBookingsDialog:getNumberOfItemsInSection(list, section)
    return #self.bookings
end

function PendingBookingsDialog:populateCellForItemInSection(list, section, index, cell)
    local b = self.bookings[index]
    if b == nil then return end

    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(b.fillTypeIndex)
    local grainName = (ft and ft.title) or "?"
    local title = string.format("%s — %s", grainName, formatLitres(b.litres))

    if cell:getAttribute("title") ~= nil then
        cell:getAttribute("title"):setText(title)
    end
    if cell:getAttribute("subtitle") ~= nil then
        local month = b.targetMonthLabel or ""
        local buyer = b.unloadingStationName or "?"
        local pay = ""
        if g_i18n and g_i18n.formatMoney and b.totalNet ~= nil then
            pay = string.format(" · ~%s",
                g_i18n:formatMoney(b.totalNet, 0, true, true))
        end
        cell:getAttribute("subtitle"):setText(
            string.format("Due: %s · Buyer: %s%s", month, buyer, pay))
    end
end


-- SmoothList calls this through the FIXED method name (NOT the XML
-- onSelectionChanged attribute — that one isn't a real callback, just
-- a label). Same lesson as the marker picker repurpose.
function PendingBookingsDialog:onListSelectionChanged(list, section, index)
    if index == nil or index < 1 then return end
    self.selectedIndex = index
end


function PendingBookingsDialog:onClickCancelSelected()
    -- Read the live selected index off the list element — same as the
    -- marker picker. self.selectedIndex is a fallback.
    local idx = self.selectedIndex or 1
    if self.bookingsList ~= nil
            and self.bookingsList.getSelectedIndexInSection ~= nil then
        local ok, listIdx = pcall(self.bookingsList.getSelectedIndexInSection,
            self.bookingsList)
        if ok and type(listIdx) == "number" and listIdx >= 1 then
            idx = listIdx
        end
    end
    local b = self.bookings[idx]
    if b == nil then return end

    if GrainCollection ~= nil and GrainCollection.cancelBooking ~= nil then
        local ok = GrainCollection:cancelBooking(b.id)
        if not ok then
            print(("[%s] cancelBooking returned false for id=%s"):format(
                tostring(GrainCollection.MOD_NAME or "FS25_GrainCollection"),
                tostring(b.id)))
        end
    end

    -- Pull the freshly-cancelled booking out of the local view and
    -- refresh in place. Player can keep cancelling more before closing.
    table.remove(self.bookings, idx)
    if self.selectedIndex > #self.bookings then
        self.selectedIndex = math.max(1, #self.bookings)
    end
    self:refresh()

    if self.onChange ~= nil then
        local ok, err = pcall(self.onChange)
        if not ok then
            print(("[%s] onChange callback error: %s"):format(
                tostring(GrainCollection and GrainCollection.MOD_NAME or "FS25_GrainCollection"),
                tostring(err)))
        end
    end
end


function PendingBookingsDialog:onClickClose()
    self:close()
end
