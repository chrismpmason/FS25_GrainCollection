--
-- BookActionDialog.lua
-- Three-option confirmation modal opened from the Produce Collection tab's
-- [BOOK] button. Choices: Book Now / Book Best (recommended) / Cancel.
-- Calls back into the tab with the choice; this dialog does NOT book — it
-- only collects intent. Booking happens in InGameMenuProduceCollection.
--

BookActionDialog = {}
local BookActionDialog_mt = Class(BookActionDialog, MessageDialog)

function BookActionDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or BookActionDialog_mt)
    self.i18n = g_i18n
    self.row = nil
    self.callback = nil
    return self
end

function BookActionDialog:onCreate()
    BookActionDialog:superClass().onCreate(self)
end

function BookActionDialog:onGuiSetupFinished()
    BookActionDialog:superClass().onGuiSetupFinished(self)
end

function BookActionDialog:setBookData(row, callback)
    self.row = row
    self.callback = callback
    self.isBale = (row.productId == "bale")
    -- Bale rows default to every bookable bale; the stepper trims it.
    self.count = self.isBale and (row.baleAvailable or 0) or nil

    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(string.format(
            g_i18n:getText("ui_book_dialog_title"), row.fillTypeTitle or "?"))
    end

    local stepper = { self.btnCountMinus10, self.btnCountMinus1, self.countText,
                      self.btnCountPlus1, self.btnCountPlus10, self.btnCountAll }
    for _, el in pairs(stepper) do el:setVisible(self.isBale) end
    if self.btnCountAll ~= nil then self.btnCountAll:setText(g_i18n:getText("ui_gc_all")) end

    -- Book Best only means something with a real seasonal curve. Bale
    -- rows say whether they have one; other rows keep the button as-is.
    if self.btnBookBest ~= nil then
        self.btnBookBest:setVisible(row.hasForecast ~= false)
    end

    self:refreshLabels()
end

-- Context line + button labels. Split out so the bale stepper can redraw
-- the values as the count changes.
function BookActionDialog:refreshLabels()
    local row = self.row
    if row == nil then return end

    -- Litres this booking covers: the whole row, or the picked bales at
    -- the pool's average bale size (settlement pays actual litres).
    local litres = row.totalLitres or 0
    if self.isBale then
        litres = (self.count or 0) * (row.litresPerBale or 0)
    end

    if self.lineContext ~= nil then
        if self.isBale then
            self.lineContext:setText(string.format(
                g_i18n:getText("ui_book_bale_context"),
                row.baleAvailable or 0,
                g_i18n:formatNumber(row.totalLitres or 0, 0),
                row.siloCount or 1,
                row.bestBuyerName or "?",
                (row.bestBuyerPrice or 0) * 1000))
        else
            -- Single context line: volume + best buyer + £/L.
            local volLabel = string.format("%s L",
                g_i18n:formatNumber(row.totalLitres or 0, 0))
            self.lineContext:setText(string.format(
                g_i18n:getText("ui_book_dialog_context"),
                volLabel,
                row.siloCount or 1,
                row.bestBuyerName or "?",
                (row.bestBuyerPrice or 0) * 1000))
        end
    end

    if self.isBale and self.countText ~= nil then
        self.countText:setText(string.format(g_i18n:getText("ui_bale_count_fmt"),
            self.count or 0, row.baleAvailable or 0))
    end

    -- Full descriptive label baked into each button.
    local curValue  = litres * (row.bestBuyerPrice or 0)
    local bestValue = (row.maxPricePerLitre or 0) * litres
                    * (row.bestPriceScale or 1.0)
    if row.hasForecast == false then bestValue = 0 end

    local nowText  = string.format(g_i18n:getText("ui_book_now_fmt"),
        g_i18n:formatMoney(curValue, 0, true, true))
    local bestText = string.format(g_i18n:getText("ui_book_best_fmt"),
        row.bestPeriodLabel or "?",
        g_i18n:formatMoney(bestValue, 0, true, true))

    -- [RECOMMENDED] tag goes to whichever option has the higher
    -- predicted payout. Both £0 (no buyer / no peak data) → no tag.
    -- Tie at non-zero → BOOK NOW wins (immediate is the safe pick
    -- when the seasonal forecast doesn't improve the outcome).
    -- With BOOK BEST hidden (no price curve) there's nothing to compare.
    local tag = g_i18n:getText("ui_book_recommended_tag")
    if row.hasForecast == false then
        tag = ""
    end
    if bestValue > curValue and bestValue > 0 then
        bestText = bestText .. tag
    elseif curValue > 0 and curValue >= bestValue then
        nowText = nowText .. tag
    end

    if self.btnBookNow ~= nil then self.btnBookNow:setText(nowText)   end
    if self.btnBookBest ~= nil then self.btnBookBest:setText(bestText) end
    if self.btnCancel  ~= nil then self.btnCancel:setText(g_i18n:getText("ui_cancel")) end
end

function BookActionDialog:onOpen()
    BookActionDialog:superClass().onOpen(self)
    self:logDialogState()
end

function BookActionDialog:onClose()
    BookActionDialog:superClass().onClose(self)
end

function BookActionDialog:onClickBookNow()
    local cb, count = self.callback, self.count
    if self.isBale and (count or 0) < 1 then return end
    self:close()
    if cb ~= nil then cb("now", count) end
end

function BookActionDialog:onClickBookBest()
    local cb, count = self.callback, self.count
    if self.isBale and (count or 0) < 1 then return end
    self:close()
    if cb ~= nil then cb("best", count) end
end

-- Bale count stepper. Clamped to 1..available.
function BookActionDialog:stepCount(delta)
    if not self.isBale or self.row == nil then return end
    local maxCount = self.row.baleAvailable or 0
    local n = (self.count or 0) + delta
    if n > maxCount then n = maxCount end
    if n < 1 then n = math.min(1, maxCount) end
    self.count = n
    self:refreshLabels()
end

function BookActionDialog:onClickCountMinus10() self:stepCount(-10) end
function BookActionDialog:onClickCountMinus1()  self:stepCount(-1)  end
function BookActionDialog:onClickCountPlus1()   self:stepCount(1)   end
function BookActionDialog:onClickCountPlus10()  self:stepCount(10)  end
function BookActionDialog:onClickCountAll()
    if self.row ~= nil then self:stepCount((self.row.baleAvailable or 0) - (self.count or 0)) end
end

function BookActionDialog:onClickCancel()
    local cb = self.callback
    self:close()
    if cb ~= nil then cb("cancel") end
end

-- Verification log — fires on dialog open. Greppable prefix [GC-VERIFY].
-- v0.5.0 gates the entire body behind GrainCollection.DEBUG so production
-- log.txt stays quiet during normal play.
function BookActionDialog:logDialogState()
    if not GrainCollection.DEBUG then return end
    local lines = {}
    table.insert(lines, "[GC-VERIFY] BookActionDialog OPENED")
    table.insert(lines, "[GC-VERIFY]   frame name: BookActionDialog")
    table.insert(lines, ("[GC-VERIFY]   visible: %s"):format(tostring(self:getIsVisible())))

    local title = (self.dialogTitleElement and self.dialogTitleElement.text) or "<nil>"
    table.insert(lines, ("[GC-VERIFY]   title: %s"):format(tostring(title)))
    local ctx = (self.lineContext and self.lineContext.text) or "<nil>"
    table.insert(lines, ("[GC-VERIFY]   context: %s"):format(tostring(ctx)))

    local btnLabel = function(b)
        if b == nil then return "<nil widget>" end
        return tostring(b.text or "<no text>")
    end
    table.insert(lines, ("[GC-VERIFY]   button[1] BookNow:  %s"):format(btnLabel(self.btnBookNow)))
    table.insert(lines, ("[GC-VERIFY]   button[2] BookBest: %s"):format(btnLabel(self.btnBookBest)))
    table.insert(lines, ("[GC-VERIFY]   button[3] Cancel:   %s"):format(btnLabel(self.btnCancel)))

    local r = self.row or {}
    local nils = {}
    if r.fillTypeIndex   == nil then table.insert(nils, "fillTypeIndex") end
    if r.fillTypeTitle   == nil then table.insert(nils, "fillTypeTitle") end
    if r.totalLitres     == nil then table.insert(nils, "totalLitres") end
    if r.bestBuyerName   == nil then table.insert(nils, "bestBuyerName") end
    if r.bestBuyerPrice  == nil then table.insert(nils, "bestBuyerPrice") end
    if r.bestPeriod      == nil then table.insert(nils, "bestPeriod") end
    if r.bestPeriodLabel == nil then table.insert(nils, "bestPeriodLabel") end
    if #nils > 0 then
        table.insert(lines, ("[GC-VERIFY]   row NIL FIELDS: %s"):format(table.concat(nils, ", ")))
    else
        table.insert(lines, "[GC-VERIFY]   row NIL FIELDS: none")
    end
    table.insert(lines, ("[GC-VERIFY]   callback bound: %s"):format(tostring(self.callback ~= nil)))

    for _, l in ipairs(lines) do print(l) end
end
