--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/Layout.lua

    A responsive grid, and the scroll container that usually holds one.

    Every page before this one placed its panels at hand-written offsets, which
    is why the window looked half-empty at 1900 px and cramped at 940: the
    layout was written for one width and simply stretched. A grid that picks its
    column count from the width it is actually given fixes both ends at once -
    more columns and more information when there is room, fewer when there is
    not, and never a panel that has run out of space.

    It is deliberately a *layout* and nothing else. It creates no frames of its
    own beyond the ones handed to it, and it only does work when the width
    actually changes - a reflow on every refresh would be exactly the kind of
    per-frame cost this addon is supposed to be measuring, not causing.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI    = WTM.UI
local Theme = UI.Theme
local M     = Theme.metrics

--------------------------------------------------------------------------
-- Grid
--------------------------------------------------------------------------

--- Creates a responsive grid inside `parent`.
---
---   minColumnWidth  the narrowest a column may become before the grid drops
---                   to fewer columns (default 240)
---   maxColumns      the most it will ever use, however wide the window is
---   gap             space between cells
---   padding         inset from the parent's edges
---
--- Cells are added with :Add(frame, opts) where opts may carry:
---   span    how many columns the cell occupies (clamped to the column count)
---   height  the cell's height; defaults to the grid's rowHeight
---   fill    true to stretch the cell to the remaining width of its row
function UI.Grid(parent, opts)
    opts = opts or {}
    local grid = {
        parent         = parent,
        cells          = {},
        minColumnWidth = opts.minColumnWidth or 240,
        maxColumns     = opts.maxColumns or 4,
        gap            = opts.gap or M.cardGap,
        padding        = opts.padding or 0,
        rowHeight      = opts.rowHeight or M.cardHeight,
        columns        = 0,
        height         = 0,
    }

    function grid:Add(frame, cellOpts)
        cellOpts = cellOpts or {}
        self.cells[#self.cells + 1] = {
            frame  = frame,
            span   = cellOpts.span or 1,
            height = cellOpts.height or self.rowHeight,
            fill   = cellOpts.fill,
            -- A cell can be hidden without being removed, which is what the
            -- dashboard's show/hide settings need.
            key    = cellOpts.key,
        }
        return frame
    end

    function grid:Clear()
        for i = #self.cells, 1, -1 do self.cells[i] = nil end
    end

    --- How many columns fit in `width`.
    function grid:ColumnsFor(width)
        if not width or width <= 0 then return 1 end
        local usable = width - self.padding * 2
        local n = math.floor((usable + self.gap) / (self.minColumnWidth + self.gap))
        return math.max(1, math.min(self.maxColumns, n))
    end

    --- Places every visible cell. Returns the total height used, so the caller
    --- can size a scroll canvas around it.
    ---
    --- `force` re-lays out even when the width has not changed; pages call it
    --- after showing or hiding cells.
    function grid:Layout(force)
        local width = self.parent:GetWidth() or 0
        if width <= 0 then return self.height end

        local columns = self:ColumnsFor(width)
        if not force and columns == self.columns and width == self.lastWidth then
            return self.height
        end
        self.columns, self.lastWidth = columns, width

        local usable = width - self.padding * 2
        local columnWidth = (usable - self.gap * (columns - 1)) / columns

        local col, y, rowHeight = 0, self.padding, 0
        for _, cell in ipairs(self.cells) do
            if cell.frame:IsShown() then
                local span = math.max(1, math.min(columns, cell.span))
                -- A cell that does not fit in what is left of this row starts
                -- a new one, rather than being squeezed.
                if col > 0 and col + span > columns then
                    y = y + rowHeight + self.gap
                    col, rowHeight = 0, 0
                end

                local cellWidth = columnWidth * span + self.gap * (span - 1)
                if cell.fill then
                    cellWidth = usable - (columnWidth + self.gap) * col
                end

                cell.frame:ClearAllPoints()
                cell.frame:SetPoint("TOPLEFT", self.parent, "TOPLEFT",
                    self.padding + col * (columnWidth + self.gap), -y)
                cell.frame:SetWidth(cellWidth)
                cell.frame:SetHeight(cell.height)

                rowHeight = math.max(rowHeight, cell.height)
                col = col + span
                if col >= columns then
                    y = y + rowHeight + self.gap
                    col, rowHeight = 0, 0
                end
            end
        end

        if col > 0 then y = y + rowHeight end
        self.height = y + self.padding
        return self.height
    end

    --- Shows or hides one cell by key, then re-lays out.
    function grid:SetCellShown(key, shown)
        for _, cell in ipairs(self.cells) do
            if cell.key == key then cell.frame:SetShown(shown) end
        end
        self:Layout(true)
    end

    function grid:GetCell(key)
        for _, cell in ipairs(self.cells) do
            if cell.key == key then return cell end
        end
    end

    return grid
end

--------------------------------------------------------------------------
-- Scroll container
--------------------------------------------------------------------------

--- A scroll frame with a canvas inside it, which is what every page that has
--- more content than height needs. Returns the scroll frame and the canvas.
---
--- The wheel step is deliberately large: these pages are tall, and a step of
--- one text line turns reading them into a chore.
function UI.ScrollCanvas(parent, opts)
    opts = opts or {}
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", opts.padding or 0, -(opts.padding or 0))
    scroll:SetPoint("BOTTOMRIGHT", -(opts.padding or 0), opts.padding or 0)

    local canvas = CreateFrame("Frame", nil, scroll)
    canvas:SetSize(1, 1)
    scroll:SetScrollChild(canvas)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local offset = self:GetVerticalScroll() - delta * (opts.step or 48)
        local maximum = math.max(0, (canvas:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.max(0, math.min(maximum, offset)))
    end)

    --- Keeps the canvas as wide as the viewport, which is what makes a grid
    --- inside it responsive rather than fixed.
    function scroll:SyncWidth()
        local width = self:GetWidth()
        if width and width > 0 then canvas:SetWidth(width) end
    end

    scroll:SetScript("OnSizeChanged", function(self) self:SyncWidth() end)
    scroll:SyncWidth()

    return scroll, canvas
end

--------------------------------------------------------------------------
-- Section heading
--------------------------------------------------------------------------

--- A heading with a rule, used to break a long page into named parts.
function UI.SectionHeading(parent, title)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(22)

    frame.text = UI.Text(frame, "small", "accent", "LEFT")
    frame.text:SetPoint("LEFT", 0, 0)
    frame.text:SetText((title or ""):upper())

    frame.rule = frame:CreateTexture(nil, "ARTWORK")
    frame.rule:SetHeight(1)
    frame.rule:SetPoint("LEFT", frame.text, "RIGHT", 10, 0)
    frame.rule:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    frame.rule:SetColorTexture(Theme.Get("borderSubtle"))

    function frame:SetTitle(text) self.text:SetText((text or ""):upper()) end
    return frame
end
