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
---   justify         stretch every row to the full width (default true)
---   equalHeights    give cells in a row the row's height (default true)
---
--- Cells are added with :Add(frame, opts) where opts may carry:
---   span    how many columns the cell occupies (clamped to the column count)
---   height  the cell's height; defaults to the grid's rowHeight
---   key     a name for show/hide and lookups
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
        justify        = opts.justify ~= false,
        equalHeights   = opts.equalHeights ~= false,
        columns        = 0,
        height         = 0,
    }

    function grid:Add(frame, cellOpts)
        cellOpts = cellOpts or {}
        local height = cellOpts.height or self.rowHeight

        -- A widget that knows how tall it needs to be is never given less.
        -- Seven cards across the addon carried a hand-written height that had
        -- fallen behind the rows inside them - "SELECTED RANGE" was 48 px
        -- short - and the rows past the bottom edge were simply clipped away
        -- with nothing to say they existed. The call sites keep their numbers
        -- as the intent; this is the floor.
        local natural = frame.naturalHeight
        if natural and natural > height then height = natural end

        self.cells[#self.cells + 1] = {
            frame  = frame,
            span   = cellOpts.span or 1,
            height = height,
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

    --- Splits the visible cells into rows.
    ---
    --- Two rules on top of plain left-to-right packing, both from what the
    --- grid looked like at 1280 px with five columns:
    ---   * a run of single-column tiles is spread evenly over the rows it
    ---     needs - twelve tiles come out 4+4+4, never 5+5+2 with two orphans;
    ---   * a cell that does not fit what is left of a row starts the next one
    ---     rather than being squeezed.
    function grid:BuildRows(columns)
        local visible = {}
        for _, cell in ipairs(self.cells) do
            if cell.frame:IsShown() then visible[#visible + 1] = cell end
        end

        local rows, row, used = {}, {}, 0
        local function close()
            if #row > 0 then rows[#rows + 1] = { cells = row, used = used } end
            row, used = {}, 0
        end
        local function spanOf(cell) return math.max(1, math.min(columns, cell.span)) end

        local i = 1
        while i <= #visible do
            local cell = visible[i]
            local runLength = 0
            if used == 0 and spanOf(cell) == 1 then
                local j = i
                while j <= #visible and spanOf(visible[j]) == 1 do j = j + 1 end
                runLength = j - i
            end

            if runLength > columns then
                local rowCount = math.ceil(runLength / columns)
                local base, extra = math.floor(runLength / rowCount), runLength % rowCount
                for r = 1, rowCount do
                    for _ = 1, base + (r <= extra and 1 or 0) do
                        row[#row + 1] = visible[i]
                        used = used + 1
                        i = i + 1
                    end
                    close()
                end
            else
                local span = spanOf(cell)
                if used > 0 and used + span > columns then close() end
                row[#row + 1] = cell
                used = used + span
                i = i + 1
                if used >= columns then close() end
            end
        end
        close()
        return rows
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

        local y = self.padding
        for _, row in ipairs(self:BuildRows(columns)) do
            local cells = row.cells
            local rowHeight = 0
            for _, cell in ipairs(cells) do rowHeight = math.max(rowHeight, cell.height) end

            -- Justified, a row that does not use every column shares the
            -- leftover between its cells in proportion to their spans, so no
            -- row ends in an empty column.
            local unit = columnWidth
            if self.justify and row.used < columns then
                unit = (usable - self.gap * (#cells - 1)) / row.used
            end

            local x = self.padding
            for _, cell in ipairs(cells) do
                local span = math.max(1, math.min(columns, cell.span))
                local cellWidth = self.justify and row.used < columns
                    and unit * span
                    or (columnWidth * span + self.gap * (span - 1))

                -- Equal heights make a row read as one band. A cell far
                -- shorter than its neighbours keeps its own height instead:
                -- a three-row card stretched to a list's height is mostly
                -- empty box, which is worse than a gap.
                local cellHeight = cell.height
                if self.equalHeights and cell.height >= rowHeight * 0.6 then
                    cellHeight = rowHeight
                end

                cell.frame:ClearAllPoints()
                cell.frame:SetPoint("TOPLEFT", self.parent, "TOPLEFT", x, -y)
                cell.frame:SetWidth(cellWidth)
                cell.frame:SetHeight(cellHeight)
                x = x + cellWidth + self.gap
            end
            y = y + rowHeight + self.gap
        end

        if y > self.padding then y = y - self.gap end
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

--- The width for a list-or-detail side column, as a share of what is there.
---
--- Eight pages had a side column and eight different hard-coded widths - 196,
--- 230, 250, 280, 300, 320, 330, 380 - for what is visually the same thing. A
--- fixed width is wrong at both ends: at the minimum window size it eats half
--- the page, and at 1920 it is a sliver beside an enormous pane.
---
--- A share of the available width, clamped so it never becomes unreadably
--- narrow or absurdly wide, behaves at both.
function UI.SideColumnWidth(available, opts)
    opts = opts or {}
    if not available or available <= 0 then return opts.min or M.sideColumnMin end
    local width = available * (opts.fraction or M.sideColumnFraction)
    return math.max(opts.min or M.sideColumnMin,
                    math.min(opts.max or M.sideColumnMax, width))
end

--- Lays a row of equal cards out, wrapping onto more rows rather than letting
--- each card shrink below the width its own heading needs.
---
--- Both pages that show a card row divided the available width by the number
--- of cards and stopped there. Six error cards in a 940 px window came out
--- about 105 px each, and at that width every heading trimmed to four letters
--- and a full stop: "UNIQ...", "TOTA...", "WORS...". The information was
--- there and unreadable.
---
--- Returns the total height the row now needs, so the caller can resize the
--- container and re-anchor whatever sits below it.
---
--- `cards` is an ordered array. Anchors are set on each card; nothing else
--- about them is touched.
function UI.LayoutCardRow(container, cards, opts)
    opts = opts or {}
    local gap       = opts.gap or M.cardGap
    local minWidth  = opts.minWidth or M.cardMinWidth
    local rowHeight = opts.rowHeight or M.cardHeight

    local count = #cards
    if count == 0 then return 0 end
    local width = container:GetWidth() or 0
    if width <= 0 then return rowHeight end

    -- How many fit on one row at the minimum width, capped at the number of
    -- cards and floored at one - a container narrower than one card still has
    -- to put that card somewhere.
    local perRow = math.floor((width + gap) / (minWidth + gap))
    perRow = math.max(1, math.min(count, perRow))

    -- Spread the cards evenly over the rows they need, so eight cards over two
    -- rows come out 4 + 4 rather than 7 + 1.
    local rows = math.ceil(count / perRow)
    perRow = math.ceil(count / rows)

    local cardWidth = (width - gap * (perRow - 1)) / perRow
    for index, card in ipairs(cards) do
        local row    = math.floor((index - 1) / perRow)
        local column = (index - 1) % perRow
        card:ClearAllPoints()
        card:SetWidth(cardWidth)
        card:SetHeight(rowHeight)
        card:SetPoint("TOPLEFT", container, "TOPLEFT",
            column * (cardWidth + gap), -row * (rowHeight + gap))
    end

    return rows * rowHeight + (rows - 1) * gap
end

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
