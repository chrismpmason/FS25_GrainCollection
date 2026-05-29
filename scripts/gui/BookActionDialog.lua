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

    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(string.format(
            g_i18n:getText("ui_book_dialog_title"), row.fillTypeTitle or "?"))
    end

    -- Single context line: volume + best buyer + £/L.
    if self.lineContext ~= nil then
        local volLabel = string.format("%s L",
            g_i18n:formatNumber(row.totalLitres or 0, 0))
        self.lineContext:setText(string.format(
            g_i18n:getText("ui_book_dialog_context"),
            volLabel,
            row.siloCount or 1,
            row.bestBuyerName or "?",
            (row.bestBuyerPrice or 0) * 1000))
    end

    -- Full descriptive label baked into each button.
    local curValue  = (row.totalLitres or 0) * (row.bestBuyerPrice or 0)
    local bestValue = (row.maxPricePerLitre or 0) * (row.totalLitres or 0)
                    * (row.bestPriceScale or 1.0)

    local nowText  = string.format(g_i18n:getText("ui_book_now_fmt"),
        g_i18n:formatMoney(curValue, 0, true, true))
    local bestText = string.format(g_i18n:getText("ui_book_best_fmt"),
        row.bestPeriodLabel or "?",
        g_i18n:formatMoney(bestValue, 0, true, true))

    -- [RECOMMENDED] tag goes to whichever option has the higher
    -- predicted payout. Both £0 (no buyer / no peak data) → no tag.
    -- Tie at non-zero → BOOK NOW wins (immediate is the safe pick
    -- when the seasonal forecast doesn't improve the outcome).
    local tag = g_i18n:getText("ui_book_recommended_tag")
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
    local cb = self.callback
    self:close()
    if cb ~= nil then cb("now") end
end

function BookActionDialog:onClickBookBest()
    local cb = self.callback
    self:close()
    if cb ~= nil then cb("best") end
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
