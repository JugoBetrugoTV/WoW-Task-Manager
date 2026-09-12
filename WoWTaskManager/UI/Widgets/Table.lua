--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/Table.lua

    Sortable, virtualised data table built on UI.ScrollList.

    Columns are declared once with a width, a justification, a value getter and
    an optional tone getter.  The table never stores a copy of the data - it
    holds the caller's array and re-reads it on every refresh, so a process
    list of 150 addons refreshing twice a second allocates nothing.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics

--- columns = {
---   { key = "cpu", title = "CPU %", width = 70, justify = "RIGHT",
---     value = function(row) return "12.4" end,
---     tone  = function(row) return "warn" end,
---     bar   = function(row) return 0.42 end,        -- optional magnitude bar
---     sort  = "cpu",                                 -- sort key passed back
---     tooltip = "What this column means" },
---   ...
--- }
function UI.Table(parent, columns, opts)
    opts = opts or {}
    local widget = CreateFrame("Frame", nil, parent)
    widget.columns = columns
    widget.sortKey = opts.defaultSort
    widget.sortAscending = opts.defaultAscending or false

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------
    local header = CreateFrame("Frame", nil, widget)
    header:SetHeight(M.headerHeight)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    UI.Border(header, "B", "borderSubtle")
    widget.header = header
    header.cells = {}

    local function LayoutHeader()
        local x = 0
        local flexTotal = 0
        for _, column in ipairs(columns) do
            if column.flex then flexTotal = flexTotal + column.flex end
        end
        local fixed = 0
        for _, column in ipairs(columns) do
            if not column.flex then fixed = fixed + (column.width or 80) end
        end
        local available = math.max(0, (widget:GetWidth() or 600) - fixed - M.scrollbarWidth - 2)

        for i, column in ipairs(columns) do
            local width = column.flex and (available * column.flex / math.max(1, flexTotal))
                or (column.width or 80)
            column._x = x
            column._w = width
            local cell = header.cells[i]
            if cell then
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", header, "TOPLEFT", x, 0)
                cell:SetSize(width, M.headerHeight)
            end
            x = x + width
        end
    end
    widget.LayoutHeader = LayoutHeader

    for i, column in ipairs(columns) do
        local cell = CreateFrame("Button", nil, header)
        cell.text = UI.Text(cell, "small", "textMuted", column.justify or "LEFT")
        cell.text:SetPoint("LEFT", column.justify == "RIGHT" and 0 or 6, 0)
        cell.text:SetPoint("RIGHT", column.justify == "RIGHT" and -8 or 0, 0)
        cell.text:SetText(column.title or column.key)

        cell.arrow = UI.Text(cell, "tiny", "accent", column.justify or "LEFT")
        cell.arrow:SetPoint(column.justify == "RIGHT" and "RIGHT" or "LEFT",
                            cell.text, column.justify == "RIGHT" and "LEFT" or "RIGHT",
                            column.justify == "RIGHT" and -3 or 3, 0)
        cell.arrow:SetText("")

        if column.sort then
            cell:SetScript("OnClick", function()
                if widget.sortKey == column.sort then
                    widget.sortAscending = not widget.sortAscending
                else
                    widget.sortKey = column.sort
                    widget.sortAscending = false
                end
                widget:UpdateHeader()
                if opts.onSort then opts.onSort(widget.sortKey, widget.sortAscending) end
            end)
            cell:SetScript("OnEnter", function(self)
                self.text:SetTextColor(T("textPrimary"))
                if column.tooltip then UI.ShowTooltip(self, column.title, column.tooltip) end
            end)
            cell:SetScript("OnLeave", function(self)
                self.text:SetTextColor(T(widget.sortKey == column.sort and "accent" or "textMuted"))
                UI.HideTooltip()
            end)
        elseif column.tooltip then
            cell:SetScript("OnEnter", function(self) UI.ShowTooltip(self, column.title, column.tooltip) end)
            cell:SetScript("OnLeave", UI.HideTooltip)
        end

        header.cells[i] = cell
    end

    function widget:UpdateHeader()
        for i, column in ipairs(columns) do
            local cell = header.cells[i]
            local active = column.sort and self.sortKey == column.sort
            cell.text:SetTextColor(T(active and "accent" or "textMuted"))
            cell.arrow:SetText(active and (self.sortAscending and "^" or "v") or "")
        end
    end

    ------------------------------------------------------------------
    -- Rows
    ------------------------------------------------------------------

    local function CreateRow(rowParent)
        local row = CreateFrame("Button", nil, rowParent)
        row.cells = {}
        for i, column in ipairs(columns) do
            local cell = CreateFrame("Frame", nil, row)
            cell:SetPoint("TOP")
            cell:SetPoint("BOTTOM")
            cell.text = UI.Text(cell, column.font or (column.justify == "RIGHT" and "numeric" or "body"),
                                "textPrimary", column.justify or "LEFT")
            cell.text:SetPoint("LEFT", column.justify == "RIGHT" and 0 or 6, 0)
            cell.text:SetPoint("RIGHT", column.justify == "RIGHT" and -8 or 0, 0)
            if column.bar then
                cell.bar = UI.MiniBar(cell, 2)
                cell.bar:SetPoint("BOTTOMLEFT", 6, 3)
                cell.bar:SetPoint("BOTTOMRIGHT", -8, 3)
            end
            row.cells[i] = cell
        end
        return row
    end

    local function UpdateRow(row, data, index)
        for i, column in ipairs(columns) do
            local cell = row.cells[i]
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", row, "TOPLEFT", column._x or 0, 0)
            cell:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", column._x or 0, 0)
            cell:SetWidth(column._w or 80)

            local ok, value = pcall(column.value, data, index)
            cell.text:SetText(ok and value or "")

            if column.tone then
                local okTone, tone = pcall(column.tone, data, index)
                cell.text:SetTextColor(Theme:Tone(okTone and tone or "muted"))
                if not okTone or not tone then cell.text:SetTextColor(T("textPrimary")) end
            else
                cell.text:SetTextColor(T("textPrimary"))
            end

            if cell.bar then
                local okBar, fraction, barTone = pcall(column.bar, data, index)
                cell.bar:SetValue(okBar and fraction or 0, barTone)
            end
        end
        if opts.onUpdateRow then opts.onUpdateRow(row, data, index) end
    end

    widget.list = UI.ScrollList(widget, opts.rowHeight or M.rowHeight,
        CreateRow, UpdateRow, opts.onRowClick)
    widget.list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
    widget.list:SetPoint("BOTTOMRIGHT")
    widget.list.onRowEnter = opts.onRowEnter
    widget.list.onRowLeave = opts.onRowLeave

    ------------------------------------------------------------------

    function widget:SetData(data)
        self.list:SetData(data)
    end

    function widget:Refresh()
        self.list:Refresh()
    end

    widget:SetScript("OnSizeChanged", function(self)
        LayoutHeader()
        self.list:Refresh()
    end)

    widget.empty = UI.EmptyState(widget, opts.emptyMessage or "No rows")
    widget.empty:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -20)
    widget.empty:SetPoint("BOTTOMRIGHT")
    widget.empty:Hide()

    function widget:SetEmpty(shown, message)
        if message then self.empty:SetMessage(message) end
        self.empty:SetShown(shown)
        self.list:SetShown(not shown)
    end

    LayoutHeader()
    widget:UpdateHeader()
    return widget
end
