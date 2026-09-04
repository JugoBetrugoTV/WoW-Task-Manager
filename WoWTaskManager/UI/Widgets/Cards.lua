--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/Cards.lua

    The reusable panels every page is assembled from.

    Written against two constraints that come from what this addon is:

      * Nothing here creates frames while refreshing. Rows and bars are built
        once, at the size the widget was declared with, and then only have
        their text and colour changed. A widget library that allocated per
        update would make the diagnostic tool the thing worth diagnosing.

      * Nothing here invents a value. Where a number cannot be measured on this
        client, the widget shows the reason rather than a plausible zero, and
        says whether a figure is measured or heuristic.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

--------------------------------------------------------------------------
-- Stat card: a compact label / value pair grid
--------------------------------------------------------------------------

--- A titled card holding N label-and-value rows. The workhorse for summaries.
---
--- Rows are created once from `labels`; :Set(label, value, tone) updates one.
--- `opts.scroll` puts the rows in a scroll canvas, for a card whose height is
--- decided by the panel around it rather than by its own contents. Without it
--- a card shorter than its rows simply clips the last few away, and nothing on
--- screen says they exist - which is what the timeline inspector did at the
--- minimum window size, hiding three of its seven rows.
function UI.StatCard(parent, title, labels, opts)
    opts = opts or {}
    local card = UI.Card(parent, title, {})
    card.rows = {}

    local rowHeight = opts.rowHeight or 16
    local host = card.content
    if opts.scroll then
        local scroll, canvas = UI.ScrollCanvas(card.content, { step = rowHeight * 3 })
        card.scroll, card.canvas = scroll, canvas
        canvas:SetHeight(#labels * rowHeight)
        host = canvas
    end

    for i, label in ipairs(labels) do
        local row = UI.StatRow(host, label)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * rowHeight)
        card.rows[label] = row
    end

    --- The height this card needs for its rows, so a grid can be told. A
    --- scrolling card does not claim one: it is meant to be given less.
    if not opts.scroll then
        card.naturalHeight = #labels * rowHeight + 40
    end

    function card:Set(label, value, tone)
        local row = self.rows[label]
        if row then row:Set(value, tone) end
    end

    function card:SetUnavailable(label, reason)
        local row = self.rows[label]
        if row then
            row:Set("unavailable", "muted")
            row.tooltip = reason
        end
    end

    return card
end

--------------------------------------------------------------------------
-- Top list: a ranked table of N entries
--------------------------------------------------------------------------

--- "Top 5 by CPU", "Top events", "Recent incidents" - the same shape each
--- time: a rank, a name, a value, an optional second line, an optional
--- sparkline, and an optional click.
---
--- Rows are pre-created. Feeding it fewer entries hides the surplus rather
--- than destroying them.
function UI.TopList(parent, title, opts)
    opts = opts or {}
    local rows = opts.rows or 5
    local rowHeight = opts.rowHeight or 20
    local card = UI.Card(parent, title, {})
    card.rows = {}
    card.naturalHeight = rows * rowHeight + 44

    for i = 1, rows do
        local row = CreateFrame("Button", nil, card.content)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * rowHeight)

        row.rank = UI.Text(row, "tiny", "textMuted", "LEFT")
        row.rank:SetPoint("LEFT", 0, 0)
        row.rank:SetWidth(14)
        row.rank:SetText(tostring(i))

        -- Value first so the name can be bounded against it: two labels each
        -- anchored to one edge grow towards each other and collide.
        row.value = UI.Text(row, "numericSm", "textPrimary", "RIGHT")
        row.value:SetPoint("RIGHT", 0, 0)
        row.value:SetPoint("LEFT", row, "CENTER", opts.wideValue and -30 or 10, 0)

        row.name = UI.Text(row, "small", "textSecondary", "LEFT")
        row.name:SetPoint("LEFT", row.rank, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row.value, "LEFT", -6, 0)

        if opts.sparkline then
            row.spark = UI.Sparkline(row, opts.colorIndex or 1, opts.worstIsLow)
            row.spark:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
            row.spark:SetWidth(46)
            row.spark:SetPoint("TOP", 0, -3)
            row.spark:SetPoint("BOTTOM", 0, 3)
            row.name:SetPoint("RIGHT", row.spark, "LEFT", -6, 0)
        end

        row.highlight = row:CreateTexture(nil, "BACKGROUND")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(T("hover", 0.6))
        row.highlight:Hide()

        row:SetScript("OnEnter", function(self)
            self.highlight:Show()
            if self.tooltipTitle then
                UI.TooltipClear(self.tooltipTitle)
                for _, line in ipairs(self.tooltipLines or {}) do
                    UI.TooltipLine(line[1], line[2], line[3])
                end
                UI.TooltipShow(self)
            end
        end)
        row:SetScript("OnLeave", function(self)
            self.highlight:Hide()
            UI.HideTooltip()
        end)
        row:SetScript("OnClick", function(self)
            if card.onClick and self.entry then card.onClick(self.entry) end
        end)

        row:Hide()
        card.rows[i] = row
    end

    card.empty = UI.Text(card.content, "small", "textMuted", "LEFT")
    card.empty:SetPoint("TOPLEFT", 0, -2)
    card.empty:SetPoint("RIGHT", card.content, "RIGHT", 0, 0)
    card.empty:SetHeight(28)
    UI.Wrap(card.empty, 2)
    card.empty:Hide()

    --- `entries` is a list of { name, value, sub, tone, ring, entry, tooltip }.
    function card:SetEntries(entries, emptyMessage)
        local shown = 0
        for i, row in ipairs(self.rows) do
            local entry = entries and entries[i]
            if entry then
                shown = shown + 1
                row:Show()
                row.entry = entry.entry or entry
                row.name:SetText(UI.FitText(row.name, entry.name or "?"))
                row.value:SetText(UI.FitText(row.value, entry.value or "-"))
                if entry.tone then
                    row.value:SetTextColor(Theme:Tone(entry.tone))
                else
                    row.value:SetTextColor(T("textPrimary"))
                end
                row.tooltipTitle = entry.tooltipTitle or entry.name
                row.tooltipLines = entry.tooltipLines
                if row.spark then
                    row.spark:SetRing(entry.ring)
                    row.spark:SetShown(entry.ring ~= nil)
                end
            else
                row:Hide()
            end
        end
        self.empty:SetShown(shown == 0)
        if shown == 0 then
            self.empty:SetText(emptyMessage or "Nothing recorded yet.")
        end
    end

    --- Redraws the sparklines. Separate from SetEntries because drawing is the
    --- expensive half and goes through the window's redraw budget.
    function card:DrawSparklines()
        for _, row in ipairs(self.rows) do
            if row:IsShown() and row.spark and row.spark:IsShown() then
                row.spark:Draw()
            end
        end
    end

    return card
end

--------------------------------------------------------------------------
-- Gauge: a 0..100 score
--------------------------------------------------------------------------

--- A horizontal bar with a number on it. Not an arc: an arc needs a rotated
--- texture per segment, and this addon draws enough textures already.
function UI.Gauge(parent, title, opts)
    opts = opts or {}
    local card = UI.Card(parent, title, {})
    card.naturalHeight = opts.height or 92

    card.value = UI.Text(card.content, "display", "textPrimary", "LEFT")
    card.value:SetPoint("TOPLEFT", 0, 0)
    card.value:SetText("-")

    card.suffix = UI.Text(card.content, "small", "textMuted", "LEFT")
    card.suffix:SetPoint("BOTTOMLEFT", card.value, "BOTTOMRIGHT", 4, 4)
    card.suffix:SetText(opts.suffix or "/ 100")

    card.state = UI.Text(card.content, "title", "textSecondary", "RIGHT")
    card.state:SetPoint("TOPRIGHT", 0, -4)
    card.state:SetPoint("LEFT", card.value, "RIGHT", 40, 0)

    local track = CreateFrame("Frame", nil, card.content)
    track:SetHeight(6)
    track:SetPoint("BOTTOMLEFT", 0, 14)
    track:SetPoint("BOTTOMRIGHT", 0, 14)
    UI.Fill(track, "panelAlt")
    card.track = track

    card.bar = track:CreateTexture(nil, "ARTWORK")
    card.bar:SetPoint("TOPLEFT")
    card.bar:SetPoint("BOTTOMLEFT")
    card.bar:SetWidth(1)

    card.sub = UI.Text(card.content, "tiny", "textMuted", "LEFT")
    card.sub:SetPoint("BOTTOMLEFT", 0, 0)
    card.sub:SetPoint("RIGHT", card.content, "RIGHT", 0, 0)
    card.sub:SetHeight(12)

    function card:SetScore(score, stateText, tone, sub)
        score = math.max(0, math.min(100, score or 0))
        self.value:SetText(("%d"):format(score))
        self.value:SetTextColor(Theme:Tone(tone))
        self.state:SetText(UI.FitText(self.state, stateText or ""))
        self.state:SetTextColor(Theme:Tone(tone))
        self.bar:SetColorTexture(Theme:Tone(tone))
        local width = self.track:GetWidth() or 0
        self.bar:SetWidth(math.max(1, width * score / 100))
        self.sub:SetText(UI.FitText(self.sub, sub or ""))
    end

    return card
end

--------------------------------------------------------------------------
-- Mini histogram: labelled buckets
--------------------------------------------------------------------------

--- A fixed set of named buckets with a bar and a count each. Used for frame
--- pacing, where the bucket boundaries are the point and a free-scaled
--- histogram would hide them.
function UI.BucketBars(parent, title, buckets, opts)
    opts = opts or {}
    local rowHeight = opts.rowHeight or 18
    local card = UI.Card(parent, title, {})
    card.bars = {}
    card.naturalHeight = #buckets * rowHeight + 44

    for i, bucket in ipairs(buckets) do
        local row = CreateFrame("Frame", nil, card.content)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * rowHeight)

        row.label = UI.Text(row, "tiny", "textMuted", "LEFT")
        row.label:SetPoint("LEFT", 0, 0)
        row.label:SetWidth(opts.labelWidth or 78)
        row.label:SetText(bucket.label)

        row.value = UI.Text(row, "numericSm", "textSecondary", "RIGHT")
        row.value:SetPoint("RIGHT", 0, 0)
        row.value:SetWidth(opts.valueWidth or 62)

        local track = CreateFrame("Frame", nil, row)
        track:SetHeight(8)
        track:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
        track:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
        UI.Fill(track, "panelAlt")
        row.track = track

        row.bar = track:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT")
        row.bar:SetPoint("BOTTOMLEFT")
        row.bar:SetWidth(1)
        row.bar:SetColorTexture(Theme:Tone(bucket.tone or "info"))

        row.tone = bucket.tone
        card.bars[i] = row
    end

    --- `values` is a list of numbers, one per bucket, and `total` the divisor
    --- for the percentage. Passing total = 0 shows every bar empty rather than
    --- dividing by zero.
    function card:SetValues(values, total, formatter)
        total = math.max(1, total or 0)
        for i, row in ipairs(self.bars) do
            local value = values[i] or 0
            local fraction = value / total
            local width = row.track:GetWidth() or 0
            row.bar:SetWidth(math.max(1, width * math.min(1, fraction)))
            row.value:SetText(formatter and formatter(value, fraction)
                or ("%.1f%%"):format(fraction * 100))
        end
    end

    return card
end

--------------------------------------------------------------------------
-- Trend card: a value against an earlier value
--------------------------------------------------------------------------

--- Shows a current value and how it compares to a reference, with the sign
--- spelled out. The comparison is stated as a change, never as an improvement
--- or a regression - which of the two it is depends on the metric, and on
--- things this addon cannot see.
function UI.TrendCard(parent, opts)
    opts = opts or {}
    local card = UI.Panel(parent, {})
    card.naturalHeight = opts.height or 74

    card.label = UI.Text(card, "small", "textMuted", "LEFT")
    card.label:SetPoint("TOPLEFT", 12, -10)
    card.label:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.label:SetText(opts.label or "")

    card.value = UI.Text(card, "metric", "textPrimary", "LEFT")
    card.value:SetPoint("TOPLEFT", 11, -26)
    card.value:SetText("-")

    card.delta = UI.Text(card, "small", "textMuted", "RIGHT")
    card.delta:SetPoint("BOTTOMRIGHT", -12, 12)

    card.sub = UI.Text(card, "tiny", "textMuted", "LEFT")
    card.sub:SetPoint("BOTTOMLEFT", 12, 8)
    card.sub:SetPoint("RIGHT", card.delta, "LEFT", -6, 0)
    card.sub:SetHeight(12)

    --- `betterIsHigher` decides only the COLOUR, and only where the caller is
    --- certain: pass nil for a metric where neither direction is obviously
    --- good and the delta stays neutral.
    function card:SetTrend(value, delta, betterIsHigher, sub)
        self.value:SetText(UI.FitText(self.value, value or "-"))
        if delta == nil then
            self.delta:SetText("")
        else
            local sign = delta > 0 and "+" or ""
            self.delta:SetText(("%s%s"):format(sign, delta))
            if betterIsHigher == nil then
                self.delta:SetTextColor(T("textMuted"))
            else
                local good = (delta > 0) == (betterIsHigher and true or false)
                self.delta:SetTextColor(Theme:Tone(good and "ok" or "warn"))
            end
        end
        self.sub:SetText(UI.FitText(self.sub, sub or ""))
    end

    return card
end

--------------------------------------------------------------------------
-- Comparison card: two sessions side by side
--------------------------------------------------------------------------

--- Rows of { metric, A, B, delta }. The delta column is the reason this exists;
--- everything else is a table.
function UI.ComparisonCard(parent, title, metrics, opts)
    opts = opts or {}
    local rowHeight = opts.rowHeight or 18
    local card = UI.Card(parent, title, {})
    card.rows = {}
    card.naturalHeight = (#metrics + 1) * rowHeight + 44

    local function makeRow(index, isHeader)
        local row = CreateFrame("Frame", nil, card.content)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", 0, -(index - 1) * rowHeight)

        local style = isHeader and "tiny" or "small"
        row.label = UI.Text(row, style, isHeader and "textMuted" or "textSecondary", "LEFT")
        row.label:SetPoint("LEFT", 0, 0)
        row.label:SetPoint("RIGHT", row, "CENTER", -30, 0)

        row.delta = UI.Text(row, isHeader and "tiny" or "numericSm", "textMuted", "RIGHT")
        row.delta:SetPoint("RIGHT", 0, 0)
        row.delta:SetWidth(74)

        row.b = UI.Text(row, isHeader and "tiny" or "numericSm", "textSecondary", "RIGHT")
        row.b:SetPoint("RIGHT", row.delta, "LEFT", -8, 0)
        row.b:SetWidth(70)

        row.a = UI.Text(row, isHeader and "tiny" or "numericSm", "textSecondary", "RIGHT")
        row.a:SetPoint("RIGHT", row.b, "LEFT", -8, 0)
        row.a:SetWidth(70)
        return row
    end

    card.header = makeRow(1, true)
    card.header.label:SetText("METRIC")
    card.header.delta:SetText("CHANGE")

    for i, metric in ipairs(metrics) do
        local row = makeRow(i + 1, false)
        row.labelFull = metric.label
        row.label:SetText(metric.label)
        row.metric = metric
        -- The label is set once, before the row has a width. Refit it whenever
        -- the row is resized, or a long metric name stays unfitted forever and
        -- is cut off at the narrowest window size.
        row:SetScript("OnSizeChanged", function(self)
            self.label:SetText(UI.FitText(self.label, self.labelFull or ""))
        end)
        card.rows[metric.key] = row
    end

    function card:SetHeaders(aLabel, bLabel)
        self.header.a:SetText(UI.FitText(self.header.a, aLabel or "A"))
        self.header.b:SetText(UI.FitText(self.header.b, bLabel or "B"))
    end

    --- `delta` may be nil where a comparison is not meaningful (one side has no
    --- data), and then the cell is blank rather than showing a made-up zero.
    function card:SetRow(key, aValue, bValue, delta, betterIsHigher)
        local row = self.rows[key]
        if not row then return end
        row.a:SetText(UI.FitText(row.a, aValue or "-"))
        row.b:SetText(UI.FitText(row.b, bValue or "-"))
        if delta == nil then
            row.delta:SetText("")
            return
        end
        row.delta:SetText(UI.FitText(row.delta, delta))
        if betterIsHigher == nil then
            row.delta:SetTextColor(T("textMuted"))
        else
            local rose = tostring(delta):sub(1, 1) == "+"
            row.delta:SetTextColor(Theme:Tone(
                (rose == (betterIsHigher and true or false)) and "ok" or "warn"))
        end
    end

    return card
end

--------------------------------------------------------------------------
-- Observation list: sentences, with a severity and the evidence behind them
--------------------------------------------------------------------------

--- The shape every finding in this addon takes: a tone, a headline, the
--- evidence it rests on, and - where it is an association rather than a
--- measurement - a note saying so.
function UI.ObservationList(parent, title, opts)
    opts = opts or {}
    local rows = opts.rows or 6
    local rowHeight = opts.rowHeight or 40
    local card = UI.Card(parent, title, {})
    card.rows = {}
    card.naturalHeight = rows * rowHeight + 44

    for i = 1, rows do
        local row = CreateFrame("Frame", nil, card.content)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * rowHeight)

        row.accent = row:CreateTexture(nil, "ARTWORK")
        row.accent:SetWidth(2)
        row.accent:SetPoint("TOPLEFT", 0, -2)
        row.accent:SetPoint("BOTTOMLEFT", 0, 2)

        row.title = UI.Text(row, "small", "textPrimary", "LEFT")
        row.title:SetPoint("TOPLEFT", 8, -2)
        row.title:SetPoint("RIGHT", row, "RIGHT", -60, 0)

        row.badge = UI.Text(row, "tiny", "textMuted", "RIGHT")
        row.badge:SetPoint("TOPRIGHT", 0, -3)
        row.badge:SetWidth(56)

        row.detail = UI.Text(row, "tiny", "textMuted", "LEFT")
        row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
        row.detail:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.detail:SetHeight(rowHeight - 20)
        UI.Wrap(row.detail, 2)
        row.detail:SetJustifyV("TOP")

        row:Hide()
        card.rows[i] = row
    end

    card.empty = UI.Text(card.content, "small", "textMuted", "LEFT")
    card.empty:SetPoint("TOPLEFT", 0, -2)
    card.empty:SetPoint("RIGHT", card.content, "RIGHT", 0, 0)
    card.empty:SetHeight(30)
    UI.Wrap(card.empty, 2)
    card.empty:Hide()

    --- `list` entries: { tone, title, detail, badge }.
    function card:SetObservations(list, emptyMessage)
        local shown = 0
        for i, row in ipairs(self.rows) do
            local entry = list and list[i]
            if entry then
                shown = shown + 1
                row:Show()
                row.accent:SetColorTexture(Theme:Tone(entry.tone or "muted"))
                row.title:SetText(UI.FitText(row.title, entry.title or ""))
                row.title:SetTextColor(Theme:Tone(entry.tone or nil))
                if not entry.tone then row.title:SetTextColor(T("textPrimary")) end
                row.detail:SetText(entry.detail or "")
                row.badge:SetText(UI.FitText(row.badge, entry.badge or ""))
            else
                row:Hide()
            end
        end
        self.empty:SetShown(shown == 0)
        if shown == 0 then self.empty:SetText(emptyMessage or "Nothing to report.") end
    end

    return card
end

--------------------------------------------------------------------------
-- Status card: one word, one colour, a few supporting numbers
--------------------------------------------------------------------------

function UI.StatusCard(parent, title, labels, opts)
    opts = opts or {}
    local card = UI.Card(parent, title, {})
    card.rows = {}
    local rowHeight = opts.rowHeight or 16
    card.naturalHeight = #labels * rowHeight + 66

    card.state = UI.Text(card.content, "title", "textPrimary", "LEFT")
    card.state:SetPoint("TOPLEFT", 0, 0)
    card.state:SetPoint("RIGHT", card.content, "RIGHT", 0, 0)

    card.note = UI.Text(card.content, "tiny", "textMuted", "LEFT")
    card.note:SetPoint("TOPLEFT", card.state, "BOTTOMLEFT", 0, -2)
    card.note:SetPoint("RIGHT", card.content, "RIGHT", 0, 0)
    card.note:SetHeight(12)

    for i, label in ipairs(labels) do
        local row = UI.StatRow(card.content, label)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -30 - (i - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", 0, -30 - (i - 1) * rowHeight)
        card.rows[label] = row
    end

    function card:SetState(text, tone, note)
        self.state:SetText(UI.FitText(self.state, text or ""))
        self.state:SetTextColor(Theme:Tone(tone))
        self.note:SetText(UI.FitText(self.note, note or ""))
    end

    function card:Set(label, value, tone)
        local row = self.rows[label]
        if row then row:Set(value, tone) end
    end

    return card
end
