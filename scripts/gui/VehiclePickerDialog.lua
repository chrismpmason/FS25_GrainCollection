--
-- VehiclePickerDialog.lua  (v0.7 CP3)
-- Picker for the player's "default merchant vehicle" — the tier that
-- gets captured onto the next booking made from the Produce Collection
-- menu. Mirrors the ProduceBookingsDialog (merchant marker picker)
-- pattern: SmoothList of options, Select + Back buttons, shared
-- gc_bookingsDialog GUI profiles so the look matches.
--
-- Data source: Dispatch.FLEET (small / medium / large), each rendered
-- as a row with displayName + capacity. Current selection is pre-
-- highlighted from GrainCollection:getSelectedVehicleId(farmId).
--
-- On confirm: GrainCollection:setSelectedVehicleId persists the
-- choice; existing pending bookings are NOT changed (their vehicleId
-- was captured at BOOK time and lives on the booking record).
--

VehiclePickerDialog = {}
local VehiclePickerDialog_mt = Class(VehiclePickerDialog, MessageDialog)

local function formatCapacity(litres)
    litres = math.floor(litres or 0)
    if g_i18n ~= nil and g_i18n.formatNumber ~= nil then
        local ok, s = pcall(g_i18n.formatNumber, g_i18n, litres, 0)
        if ok and s ~= nil then return s .. " L" end
    end
    return tostring(litres) .. " L"
end


function VehiclePickerDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or VehiclePickerDialog_mt)
    self.i18n          = g_i18n
    self.entries       = {}
    self.farmId        = nil
    self.selectedIndex = 1
    self.onPicked      = nil
    return self
end


function VehiclePickerDialog:onCreate()
    VehiclePickerDialog:superClass().onCreate(self)
end


function VehiclePickerDialog:onGuiSetupFinished()
    VehiclePickerDialog:superClass().onGuiSetupFinished(self)
    if self.vehicleList ~= nil then
        self.vehicleList:setDataSource(self)
        self.vehicleList:setDelegate(self)
    end
end


-- Populate with the fleet table + pre-highlight the farm's current
-- selection. onPicked(entry) fires after the player confirms a choice.
function VehiclePickerDialog:setFleet(entries, farmId, onPicked)
    self.entries  = entries or {}
    self.farmId   = farmId
    self.onPicked = onPicked

    self.selectedIndex = 1
    local currentId = nil
    if GrainCollection ~= nil and GrainCollection.getSelectedVehicleId ~= nil
            and farmId ~= nil then
        currentId = GrainCollection:getSelectedVehicleId(farmId)
    end
    if currentId ~= nil then
        for i, e in ipairs(self.entries) do
            if e.id == currentId then self.selectedIndex = i break end
        end
    end
    self:refresh()
end


function VehiclePickerDialog:refresh()
    if self.vehicleList == nil then return end
    self.vehicleList:reloadData()
    if #self.entries > 0 and self.vehicleList.setSelectedItem ~= nil then
        local idx = math.max(1, math.min(self.selectedIndex or 1, #self.entries))
        pcall(self.vehicleList.setSelectedItem, self.vehicleList, 1, idx)
    end
    if self.btnSelect ~= nil then
        self.btnSelect.disabled = (#self.entries == 0)
    end
end


function VehiclePickerDialog:onOpen()
    VehiclePickerDialog:superClass().onOpen(self)
    if self.vehicleList ~= nil then
        FocusManager:setFocus(self.vehicleList)
    end
end


function VehiclePickerDialog:onClose()
    VehiclePickerDialog:superClass().onClose(self)
end


-- ============================================================
-- SmoothList delegate
-- ============================================================

function VehiclePickerDialog:getNumberOfSections() return 1 end

function VehiclePickerDialog:getNumberOfItemsInSection(list, section)
    return #self.entries
end

function VehiclePickerDialog:populateCellForItemInSection(list, section, index, cell)
    local e = self.entries[index]
    if e == nil then return end
    if cell:getAttribute("title") ~= nil then
        cell:getAttribute("title"):setText(tostring(e.displayName or e.id or "?"))
    end
    if cell:getAttribute("subtitle") ~= nil then
        -- v0.9: a fleet entry may carry a literal subtitle (e.g. the
        -- "Just sell" non-vehicle option). Vehicle tiers fall through
        -- to the capacity format so the column still reads "N L".
        local sub = e.subtitle or formatCapacity(e.capacity)
        cell:getAttribute("subtitle"):setText(sub)
    end
end


-- SmoothList calls this through the FIXED method name (NOT the XML
-- onSelectionChanged attribute — that one isn't a real callback, just
-- a label). Same lesson as the marker picker repurpose.
function VehiclePickerDialog:onListSelectionChanged(list, section, index)
    if index == nil or index < 1 then return end
    self.selectedIndex = index
end


function VehiclePickerDialog:onClickConfirm()
    local idx = self.selectedIndex or 1
    if self.vehicleList ~= nil
            and self.vehicleList.getSelectedIndexInSection ~= nil then
        local ok, listIdx = pcall(self.vehicleList.getSelectedIndexInSection,
            self.vehicleList)
        if ok and type(listIdx) == "number" and listIdx >= 1 then
            idx = listIdx
        end
    end
    local entry = self.entries[idx]
    if entry == nil then return end

    if GrainCollection ~= nil and GrainCollection.setSelectedVehicleId ~= nil then
        GrainCollection:setSelectedVehicleId(self.farmId, entry.id)
    end

    local cb = self.onPicked
    self:close()
    if cb ~= nil then
        local ok, err = pcall(cb, entry)
        if not ok then
            print(("[%s] VehiclePickerDialog onPicked callback error: %s"):format(
                tostring(GrainCollection and GrainCollection.MOD_NAME or "FS25_GrainCollection"),
                tostring(err)))
        end
    end
end


function VehiclePickerDialog:onClickClose()
    self:close()
end
