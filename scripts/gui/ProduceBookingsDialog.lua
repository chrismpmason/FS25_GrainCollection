--
-- ProduceBookingsDialog.lua
-- Modal list of pending bookings, opened from the "View Bookings (N)"
-- button on the Produce Collection tab. Lets the player cancel any
-- selected booking. Cancel calls GrainCollection:cancelBooking which is
-- the same back-end the v0.3.0 standalone Bookings tab used.
--

ProduceBookingsDialog = {}
local ProduceBookingsDialog_mt = Class(ProduceBookingsDialog, MessageDialog)

local function formatLitres(n)
    n = math.floor(n or 0)
    local body
    if g_i18n ~= nil and g_i18n.formatNumber ~= nil then
        local ok, s = pcall(g_i18n.formatNumber, g_i18n, n, 0)
        if ok and s ~= nil then body = s end
    end
    return (body or tostring(n)) .. " L"
end

function ProduceBookingsDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or ProduceBookingsDialog_mt)
    self.i18n = g_i18n
    self.bookings = {}
    self.selectedIndex = 1
    self.onChange = nil
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

function ProduceBookingsDialog:setBookings(bookings, onChange)
    self.bookings = bookings or {}
    self.onChange = onChange
    self:refresh()
end

function ProduceBookingsDialog:refresh()
    if self.noBookingsText ~= nil then
        self.noBookingsText:setVisible(#self.bookings == 0)
    end
    if self.bookingsList ~= nil then
        self.bookingsList:reloadData()
    end
    if self.selectedIndex > #self.bookings then
        self.selectedIndex = math.max(1, #self.bookings)
    end
    if self.btnCancelBooking ~= nil then
        self.btnCancelBooking.disabled = (#self.bookings == 0)
    end
end

function ProduceBookingsDialog:onOpen()
    ProduceBookingsDialog:superClass().onOpen(self)
    self:logDialogState()
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
    return #self.bookings
end

function ProduceBookingsDialog:populateCellForItemInSection(list, section, index, cell)
    local b = self.bookings[index]
    if b == nil then return end
    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(b.fillTypeIndex)
    local title = (ft and ft.title) or "?"

    if cell:getAttribute("title") ~= nil then
        cell:getAttribute("title"):setText(title)
    end
    if cell:getAttribute("subtitle") ~= nil then
        local whenLabel = b.targetMonthLabel
        if whenLabel == nil or whenLabel == "" then
            whenLabel = string.format("day %d", b.dueDay or 0)
        end
        cell:getAttribute("subtitle"):setText(string.format("%s   %s   ~%s",
            formatLitres(b.litres or 0),
            whenLabel,
            g_i18n:formatMoney(b.totalNet or 0, 0, true, true)))
    end
end

function ProduceBookingsDialog:onBookingSelected(list, section, index)
    if index == nil or index < 1 then return end
    self.selectedIndex = index
    if GrainCollection.DEBUG then
        local b = self.bookings[index]
        if b ~= nil then
            local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(b.fillTypeIndex)
            local ftTitle = (ft and ft.title) or "?"
            GrainCollection.dbg(("ProduceBookingsDialog row id=%s %s %sL %s ~£%s"):format(
                tostring(b.id), ftTitle,
                tostring(math.floor(b.litres or 0)),
                tostring(b.targetMonthLabel or ("day " .. tostring(b.dueDay))),
                tostring(math.floor(b.totalNet or 0))))
        end
    end
end

function ProduceBookingsDialog:onClickCancelBooking()
    local b = self.bookings[self.selectedIndex]
    if b == nil then return end
    GrainCollection:cancelBooking(b.id)
    self.bookings = GrainCollection.bookings or {}
    self:refresh()
    if self.onChange ~= nil then self.onChange() end
end

function ProduceBookingsDialog:onClickClose()
    self:close()
end

-- Verification log — fires on dialog open. Greppable prefix [GC-VERIFY].
-- v0.5.0 gated behind GrainCollection.DEBUG.
function ProduceBookingsDialog:logDialogState()
    if not GrainCollection.DEBUG then return end
    local lines = {}
    table.insert(lines, "[GC-VERIFY] ProduceBookingsDialog OPENED")
    table.insert(lines, "[GC-VERIFY]   frame name: ProduceBookingsDialog")
    table.insert(lines, ("[GC-VERIFY]   visible: %s"):format(tostring(self:getIsVisible())))
    table.insert(lines, ("[GC-VERIFY]   bookings count: %d"):format(#self.bookings))

    local btnLabel = function(b)
        if b == nil then return "<nil widget>" end
        return tostring(b.text or "<no text>")
    end
    table.insert(lines, ("[GC-VERIFY]   button[1] CancelBooking: %s (disabled=%s)"):format(
        btnLabel(self.btnCancelBooking),
        tostring(self.btnCancelBooking and self.btnCancelBooking.disabled)))
    table.insert(lines, ("[GC-VERIFY]   button[2] Close: %s"):format(btnLabel(self.btnClose)))

    for i, b in ipairs(self.bookings) do
        local nils = {}
        if b.fillTypeIndex        == nil then table.insert(nils, "fillTypeIndex") end
        if b.litres               == nil then table.insert(nils, "litres") end
        if b.dueDay               == nil then table.insert(nils, "dueDay") end
        if b.totalNet             == nil then table.insert(nils, "totalNet") end
        if b.unloadingStationName == nil then table.insert(nils, "unloadingStationName") end
        local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(b.fillTypeIndex)
        local ftTitle = (ft and ft.title) or "?"
        if #nils > 0 then
            table.insert(lines, ("[GC-VERIFY]   booking[%d] id=%s NIL: %s"):format(
                i, tostring(b.id), table.concat(nils, ",")))
        else
            table.insert(lines, ("[GC-VERIFY]   booking[%d] id=%s %s %sL %s ~£%s"):format(
                i, tostring(b.id), ftTitle,
                tostring(math.floor(b.litres or 0)),
                tostring(b.targetMonthLabel or ("day " .. tostring(b.dueDay))),
                tostring(math.floor(b.totalNet or 0))))
        end
    end
    for _, l in ipairs(lines) do print(l) end
end
