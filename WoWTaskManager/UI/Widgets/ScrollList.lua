--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/ScrollList.lua

    Virtualised list.  Only the rows actually on screen exist as frames, and
    they are recycled as you scroll - with 150 installed addons a naive list
    would create 150 row frames with a dozen font strings each, which is
    exactly the kind of thing this addon is supposed to catch in others.

    The caller supplies:
        createRow(parent)        -> row frame
        updateRow(row, data, i)  -> fill it in
    and then sets :SetData(array).
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics

function UI.ScrollList(parent, rowHeight, createRow, updateRow, onRowClick)
    local list = CreateFrame("Frame", nil, parent)
    list.rowHeight = rowHeight or M.rowHeight
    list.rows = {}
    list.data = {}
    list.offset = 0

    local viewport = CreateFrame("Frame", nil, list)
    viewport:SetPoint("TOPLEFT")
    viewport:SetPoint("BOTTOMRIGHT", -M.scrollbarWidth - 2, 0)
    viewport:SetClipsChildren(true)
    list.viewport = viewport

    ------------------------------------------------------------------
    -- Scrollbar: a 6px track with a flat thumb, no Blizzard arrows.
    ------------------------------------------------------------------
    local bar = CreateFrame("Frame", nil, list)
    bar:SetWidth(M.scrollbarWidth)
    bar:SetPoint("TOPRIGHT")
    bar:SetPoint("BOTTOMRIGHT")
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetAllPoints()
    bar.track:SetColorTexture(T("panelAlt", 0.5))

    local thumb = CreateFrame("Frame", nil, bar)
    thumb:SetWidth(M.scrollbarWidth)
    thumb.tex = thumb:CreateTexture(nil, "ARTWORK")
    thumb.tex:SetAllPoints()
    thumb.tex:SetColorTexture(T("borderStrong"))
    thumb:EnableMouse(true)
    list.scrollbar, list.thumb = bar, thumb

    local dragging, dragStartY, dragStartOffset
    thumb:SetScript("OnMouseDown", function()
        dragging = true
        local _, y = GetCursorPosition()
        dragStartY = y / UIParent:GetEffectiveScale()
        dragStartOffset = list.offset
        thumb.tex:SetColorTexture(T("accent"))
    end)
    thumb:SetScript("OnMouseUp", function()
        dragging = false
        thumb.tex:SetColorTexture(T("borderStrong"))
    end)
    thumb:SetScript("OnUpdate", function()
        if not dragging then return end
        local _, y = GetCursorPosition()
        y = y / UIParent:GetEffectiveScale()
        local trackHeight = bar:GetHeight()
        local total = #list.data * list.rowHeight
        local visible = viewport:GetHeight()
        if total <= visible or trackHeight <= 0 then return end
        local delta = (dragStartY - y) / trackHeight * total
        list:SetOffset(dragStartOffset + delta)
    end)

    ------------------------------------------------------------------
    -- Row pool
    ------------------------------------------------------------------

    local function AcquireRow(index)
        local row = list.rows[index]
        if row then return row end
        row = createRow(viewport)
        row:SetHeight(list.rowHeight)
        row:SetPoint("LEFT", viewport, "LEFT", 0, 0)
        row:SetPoint("RIGHT", viewport, "RIGHT", 0, 0)

        row.zebra = row:CreateTexture(nil, "BACKGROUND")
        row.zebra:SetAllPoints()
        row.zebra:SetColorTexture(T("panelAlt", 0))

        row.highlight = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(T("hover"))
        row.highlight:Hide()

        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            self.highlight:Show()
            if list.onRowEnter and self.data then list.onRowEnter(self, self.data) end
        end)
        row:SetScript("OnLeave", function(self)
            self.highlight:Hide()
            UI.HideTooltip()
            if list.onRowLeave then list.onRowLeave(self) end
        end)
        if onRowClick then
            row:SetScript("OnMouseUp", function(self, button)
                if self.data then onRowClick(self.data, button, self) end
            end)
        end

        list.rows[index] = row
        return row
    end

    ------------------------------------------------------------------
    -- Layout
    ------------------------------------------------------------------

    function list:Refresh()
        local height = viewport:GetHeight()
        if not height or height <= 0 then return end

        local total = #self.data
        local totalHeight = total * self.rowHeight
        local maxOffset = math.max(0, totalHeight - height)
        if self.offset > maxOffset then self.offset = maxOffset end
        if self.offset < 0 then self.offset = 0 end

        local firstIndex = math.floor(self.offset / self.rowHeight) + 1
        local visibleCount = math.ceil(height / self.rowHeight) + 1
        local pixelOffset = self.offset - (firstIndex - 1) * self.rowHeight

        for slot = 1, visibleCount do
            local dataIndex = firstIndex + slot - 1
            local entry = self.data[dataIndex]
            if entry then
                local row = AcquireRow(slot)
                row:SetPoint("TOPLEFT", viewport, "TOPLEFT", 0,
                    -((slot - 1) * self.rowHeight - pixelOffset))
                row.data = entry
                row.dataIndex = dataIndex
                row.zebra:SetColorTexture(T("panelAlt", (dataIndex % 2 == 0) and 0.35 or 0))
                row:Show()
                updateRow(row, entry, dataIndex)
            elseif self.rows[slot] then
                self.rows[slot]:Hide()
                self.rows[slot].data = nil
            end
        end
        for slot = visibleCount + 1, #self.rows do
            self.rows[slot]:Hide()
            self.rows[slot].data = nil
        end

        -- Scrollbar geometry
        if totalHeight <= height then
            bar:Hide()
        else
            bar:Show()
            local trackHeight = bar:GetHeight()
            local thumbHeight = math.max(24, trackHeight * (height / totalHeight))
            local travel = trackHeight - thumbHeight
            local progress = maxOffset > 0 and (self.offset / maxOffset) or 0
            thumb:SetHeight(thumbHeight)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOP", bar, "TOP", 0, -travel * progress)
        end
    end

    function list:SetOffset(offset)
        self.offset = offset
        self:Refresh()
    end

    function list:SetData(data)
        self.data = data or {}
        self:Refresh()
    end

    function list:ScrollToTop() self:SetOffset(0) end

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        self:SetOffset(self.offset - delta * self.rowHeight * 3)
    end)
    list:SetScript("OnSizeChanged", function(self) self:Refresh() end)

    return list
end
