--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/Graph.lua

    The graph engine.  Built for the same constraint the rest of the addon is
    built for: it must not become the performance problem.

    How that is achieved:
      * The number of drawn elements is bound to the graph's PIXEL WIDTH, not
        to the number of data points.  A 700 px graph draws ~230 columns
        whether it is showing 300 samples or 30,000.
      * Downsampling keeps the extreme of each column (max for frame time, min
        for FPS) instead of the mean, so a 200 ms freeze survives being
        squeezed into one pixel column.  Averaging would erase exactly the
        events the graph exists to show.
      * Every texture and line comes from a pool and is recycled on redraw.
        The pool grows to the widest the graph has ever been and then stops.
      * Redraw only happens when the graph is visible and its data changed.

    Rendering uses frame:CreateLine when the client has it (all four target
    clients do) and falls back to stacked column textures otherwise, so the
    graph degrades into a slightly chunkier area chart rather than vanishing.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI     = WTM.UI
local Theme  = UI.Theme
local T      = Theme.Get
local M      = Theme.metrics
local MathU  = WTM.Math
local Fmt    = WTM.Format
local RegionPool = WTM.RegionPool

local COLUMN_WIDTH   = 3     -- pixels per rendered column
local GRID_LINES     = 4
local MIN_HEADROOM   = 1.15  -- keep the peak off the ceiling

--------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------

function UI.Graph(parent, opts)
    opts = opts or {}
    local graph = UI.Panel(parent, { color = opts.color or "panelBg", border = opts.border ~= false })
    graph.series = {}
    graph.padding = { left = opts.padLeft or 44, right = 8, top = 10, bottom = 18 }
    graph.showGrid = opts.showGrid ~= false
    graph.showAxis = opts.showAxis ~= false
    graph.valueFormat = opts.valueFormat or function(v) return ("%.0f"):format(v) end
    graph.minRange = opts.minRange or 1
    -- Which end of a bucket is the INTERESTING one when many samples collapse
    -- into one pixel column.  For frame time, latency, CPU, events and memory
    -- the worst value is the HIGH one, so the column keeps the maximum.  For
    -- FPS the worst value is the LOW one, so it keeps the minimum.
    --
    -- Getting this backwards silently deletes every spike from the graph - a
    -- bucket of 5 / 6 / 97 / 5 ms would render as 5 ms - so it is named for
    -- what it does rather than for a value judgement.
    graph.worstIsLow = opts.worstIsLow and true or false
    graph.fixedMax = opts.fixedMax
    -- Horizontal guides at values that mean something, e.g. 16.67 ms (60 FPS).
    -- They make "is this good" answerable at a glance without reading the axis.
    graph.referenceLines = opts.referenceLines
    graph.dirty = true

    ------------------------------------------------------------------
    -- Plot area
    ------------------------------------------------------------------
    local plot = CreateFrame("Frame", nil, graph)
    plot:SetPoint("TOPLEFT", graph.padding.left, -graph.padding.top)
    plot:SetPoint("BOTTOMRIGHT", -graph.padding.right, graph.padding.bottom)
    plot:SetClipsChildren(true)
    graph.plot = plot

    ------------------------------------------------------------------
    -- Pools
    ------------------------------------------------------------------
    graph.columnPool = RegionPool.New(plot,
        function(p)
            local texture = p:CreateTexture(nil, "ARTWORK")
            texture:SetWidth(COLUMN_WIDTH)
            return texture
        end,
        function(texture) texture:ClearAllPoints() end)

    graph.linePool = Theme:SupportsLines(plot) and RegionPool.New(plot,
        function(p)
            local line = p:CreateLine(nil, "OVERLAY")
            line:SetThickness(1.6)
            return line
        end,
        function(line) line:ClearAllPoints() end) or nil

    graph.gridPool = RegionPool.New(plot,
        function(p)
            local texture = p:CreateTexture(nil, "BACKGROUND")
            texture:SetHeight(1)
            return texture
        end,
        function(texture) texture:ClearAllPoints() end)

    graph.referencePool = RegionPool.New(plot,
        function(p)
            local texture = p:CreateTexture(nil, "ARTWORK")
            texture:SetHeight(1)
            return texture
        end,
        function(texture) texture:ClearAllPoints() end)

    graph.referenceLabels = {}
    for i = 1, 4 do
        local label = UI.Text(graph, "tiny", "textMuted", "LEFT")
        label:Hide()
        graph.referenceLabels[i] = label
    end

    graph.markerPool = RegionPool.New(plot,
        function(p)
            local texture = p:CreateTexture(nil, "OVERLAY")
            texture:SetSize(4, 4)
            texture:SetColorTexture(T("crit"))
            return texture
        end,
        function(texture) texture:ClearAllPoints() end)

    ------------------------------------------------------------------
    -- Axis labels (fixed count, created once)
    ------------------------------------------------------------------
    graph.axisLabels = {}
    for i = 1, GRID_LINES + 1 do
        local label = UI.Text(graph, "tiny", "textMuted", "RIGHT")
        label:SetPoint("RIGHT", plot, "TOPLEFT", -6, 0)
        graph.axisLabels[i] = label
    end

    graph.timeLabels = {}
    for i = 1, 4 do
        local label = UI.Text(graph, "tiny", "textMuted", "CENTER")
        graph.timeLabels[i] = label
    end

    ------------------------------------------------------------------
    -- Footer: min / avg / max
    ------------------------------------------------------------------
    graph.footer = UI.Text(graph, "tiny", "textMuted", "RIGHT")
    graph.footer:SetPoint("BOTTOMRIGHT", -graph.padding.right, 3)

    graph.titleText = UI.Text(graph, "heading", "textSecondary")
    graph.titleText:SetPoint("TOPLEFT", 10, -6)
    graph.titleText:SetText(opts.title or "")
    if opts.title then
        graph.padding.top = 26
        plot:SetPoint("TOPLEFT", graph.padding.left, -graph.padding.top)
    end

    ------------------------------------------------------------------
    -- Crosshair and hover readout
    ------------------------------------------------------------------
    local crosshair = plot:CreateTexture(nil, "OVERLAY")
    crosshair:SetWidth(1)
    crosshair:SetPoint("TOP", plot, "TOP")
    crosshair:SetPoint("BOTTOM", plot, "BOTTOM")
    crosshair:SetColorTexture(T("textMuted", 0.5))
    crosshair:Hide()
    graph.crosshair = crosshair

    plot:EnableMouse(true)
    plot:SetScript("OnEnter", function() graph.hovering = true end)
    plot:SetScript("OnLeave", function()
        graph.hovering = false
        crosshair:Hide()
        UI.HideTooltip()
    end)
    plot:SetScript("OnUpdate", function(self)
        if not graph.hovering then return end
        graph:UpdateHover()
    end)
    if opts.onSelect then
        plot:SetScript("OnMouseUp", function()
            if graph.hoverTime then opts.onSelect(graph.hoverTime, graph.hoverIndex) end
        end)
    end

    ------------------------------------------------------------------
    -- Series API
    ------------------------------------------------------------------

    --- values/times are arrays owned by the caller; the graph never copies them.
    function graph:SetSeries(index, values, times, opts2)
        opts2 = opts2 or {}
        local series = self.series[index]
        if not series then
            series = {}
            self.series[index] = series
        end
        series.values = values
        series.times  = times
        series.label  = opts2.label
        series.colorIndex = opts2.colorIndex or index
        series.fill   = opts2.fill ~= false
        series.hidden = opts2.hidden
        series.unit   = opts2.unit
        self.dirty = true
        return series
    end

    function graph:ClearSeries()
        for i = #self.series, 1, -1 do self.series[i] = nil end
        self.dirty = true
    end

    function graph:SetMarkers(markers)
        self.markers = markers
        self.dirty = true
    end

    function graph:SetTitle(text) self.titleText:SetText(text or "") end

    ------------------------------------------------------------------
    -- Scale
    ------------------------------------------------------------------
    -- Hysteresis: the axis only rescales when the data leaves a comfort band.
    -- Without it the ceiling twitches on every sample and the whole graph
    -- appears to breathe, which makes trends impossible to read.

    function graph:ComputeScale()
        local dataMax, dataMin = 0, math.huge
        for i = 1, #self.series do
            local series = self.series[i]
            if series.values and not series.hidden then
                for j = 1, #series.values do
                    local v = series.values[j]
                    if v > dataMax then dataMax = v end
                    if v < dataMin then dataMin = v end
                end
            end
        end
        if dataMin == math.huge then dataMin = 0 end
        if dataMax <= 0 then dataMax = self.minRange end

        local wanted = MathU.NiceCeil(dataMax * MIN_HEADROOM)
        if self.fixedMax then wanted = self.fixedMax end

        local current = self.scaleMax
        if not current then
            self.scaleMax = wanted
        elseif wanted > current or wanted < current * 0.55 then
            -- Grow immediately, shrink only once there is real headroom.
            self.scaleMax = wanted
        end
        self.scaleMin = 0
        self.dataMin, self.dataMax = dataMin, dataMax
        return self.scaleMin, self.scaleMax
    end

    ------------------------------------------------------------------
    -- Downsampling
    ------------------------------------------------------------------
    -- One value per rendered column, keeping the extreme rather than the mean.

    local scratchValues, scratchTimes = {}, {}

    local function Downsample(values, times, columns, keepMin)
        local n = #values
        for i = #scratchValues, 1, -1 do scratchValues[i] = nil end
        for i = #scratchTimes, 1, -1 do scratchTimes[i] = nil end
        if n == 0 then return scratchValues, scratchTimes end

        if n <= columns then
            for i = 1, n do
                scratchValues[i] = values[i]
                scratchTimes[i] = times and times[i] or i
            end
            return scratchValues, scratchTimes
        end

        local step = n / columns
        for c = 1, columns do
            local first = math.floor((c - 1) * step) + 1
            local last  = math.min(n, math.floor(c * step))
            if last < first then last = first end
            local best, bestT = values[first], times and times[first] or first
            for i = first + 1, last do
                local v = values[i]
                if (keepMin and v < best) or (not keepMin and v > best) then
                    best, bestT = v, times and times[i] or i
                end
            end
            scratchValues[c] = best
            scratchTimes[c]  = bestT
        end
        return scratchValues, scratchTimes
    end

    ------------------------------------------------------------------
    -- Draw
    ------------------------------------------------------------------

    function graph:Draw()
        if not self:IsVisible() then return end

        local width  = plot:GetWidth() or 0
        local height = plot:GetHeight() or 0
        if width < 8 or height < 8 then return end

        self.columnPool:ReleaseAll()
        self.gridPool:ReleaseAll()
        self.markerPool:ReleaseAll()
        self.referencePool:ReleaseAll()
        for i = 1, #self.referenceLabels do self.referenceLabels[i]:Hide() end
        if self.linePool then self.linePool:ReleaseAll() end

        local minValue, maxValue = self:ComputeScale()
        local range = math.max(self.minRange, maxValue - minValue)

        ------------------------------------------------------------
        -- Grid + axis
        ------------------------------------------------------------
        if self.showGrid then
            for i = 0, GRID_LINES do
                local fraction = i / GRID_LINES
                local line = self.gridPool:Acquire()
                line:SetColorTexture(T("borderSubtle", i == 0 and 0.9 or 0.45))
                line:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, height * fraction)
                line:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, height * fraction)

                local label = self.axisLabels[i + 1]
                if label then
                    label:ClearAllPoints()
                    label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, height * fraction)
                    label:SetText(self.valueFormat(minValue + range * fraction))
                    label:SetShown(self.showAxis)
                end
            end
            for i = GRID_LINES + 2, #self.axisLabels do self.axisLabels[i]:Hide() end
        end

        ------------------------------------------------------------
        -- Reference lines
        ------------------------------------------------------------
        if self.referenceLines and WTM.db.profile.ui.showReferenceLines then
            local shown = 0
            for i = 1, #self.referenceLines do
                local reference = self.referenceLines[i]
                local fraction = (reference.value - minValue) / range
                if fraction >= 0.02 and fraction <= 0.98 then
                    local line = self.referencePool:Acquire()
                    line:SetColorTexture(T("textMuted", 0.35))
                    line:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, height * fraction)
                    line:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, height * fraction)

                    shown = shown + 1
                    local label = self.referenceLabels[shown]
                    if label then
                        label:ClearAllPoints()
                        label:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 3, height * fraction + 1)
                        label:SetText(reference.label)
                        label:Show()
                    end
                end
            end
        end

        ------------------------------------------------------------
        -- Series
        ------------------------------------------------------------
        local columns = math.max(2, math.floor(width / COLUMN_WIDTH))
        local drewAnything = false

        for s = 1, #self.series do
            local series = self.series[s]
            if series.values and #series.values > 0 and not series.hidden then
                drewAnything = true
                local keepMin = self.worstIsLow
                local values, times = Downsample(series.values, series.times, columns, keepMin)
                local count = #values
                local r, g, b = Theme:Series(series.colorIndex)
                local columnWidth = width / math.max(1, count - 1)

                series.renderValues = series.renderValues or {}
                series.renderTimes  = series.renderTimes or {}
                for i = #series.renderValues, 1, -1 do series.renderValues[i] = nil end
                for i = #series.renderTimes, 1, -1 do series.renderTimes[i] = nil end

                local previousX, previousY
                for i = 1, count do
                    local value = values[i]
                    series.renderValues[i] = value
                    series.renderTimes[i]  = times[i]

                    local fraction = (value - minValue) / range
                    if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
                    local x = (i - 1) * columnWidth
                    local y = fraction * height

                    -- Area fill: one column texture per sample, pooled.
                    if series.fill then
                        local column = self.columnPool:Acquire()
                        column:SetColorTexture(r, g, b, 0.13)
                        column:ClearAllPoints()
                        column:SetWidth(math.max(1, columnWidth + 0.5))
                        column:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x - columnWidth / 2, 0)
                        column:SetHeight(math.max(1, y))
                    end

                    -- Line segment on top.
                    if self.linePool and previousX then
                        local line = self.linePool:Acquire()
                        line:SetColorTexture(r, g, b, 0.95)
                        line:SetStartPoint("BOTTOMLEFT", plot, previousX, previousY)
                        line:SetEndPoint("BOTTOMLEFT", plot, x, y)
                    elseif not self.linePool then
                        -- Column fallback: a bright cap on the fill reads as a
                        -- line without needing CreateLine at all.
                        local cap = self.columnPool:Acquire()
                        cap:SetColorTexture(r, g, b, 0.95)
                        cap:ClearAllPoints()
                        cap:SetWidth(math.max(1, columnWidth + 0.5))
                        cap:SetHeight(1.5)
                        cap:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x - columnWidth / 2, y)
                    end

                    previousX, previousY = x, y
                end

                -- Peak marker
                if WTM.db.profile.ui.showPeaks and count > 2 then
                    local peakIndex, peakValue = 1, values[1]
                    for i = 2, count do
                        local v = values[i]
                        if (keepMin and v < peakValue) or (not keepMin and v > peakValue) then
                            peakIndex, peakValue = i, v
                        end
                    end
                    local fraction = (peakValue - minValue) / range
                    fraction = math.max(0, math.min(1, fraction))
                    local dot = self.markerPool:Acquire()
                    dot:SetColorTexture(r, g, b, 1)
                    dot:ClearAllPoints()
                    dot:SetPoint("CENTER", plot, "BOTTOMLEFT",
                        (peakIndex - 1) * columnWidth, fraction * height)
                end

                series.columnWidth = columnWidth
                series.renderCount = count
            end
        end

        ------------------------------------------------------------
        -- Event markers along the bottom
        ------------------------------------------------------------
        if self.markers and self.fromTime and self.toTime then
            local span = self.toTime - self.fromTime
            if span > 0 then
                for i = 1, #self.markers do
                    local marker = self.markers[i]
                    local fraction = (marker.t - self.fromTime) / span
                    if fraction >= 0 and fraction <= 1 then
                        local def = WTM.C.MARKERS[marker.kind]
                        local tick = self.markerPool:Acquire()
                        tick:SetSize(2, height)
                        tick:SetColorTexture(Theme:Tone(def and def.tone or "muted", 0.28))
                        tick:ClearAllPoints()
                        tick:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", fraction * width, 0)
                    end
                end
            end
        end

        ------------------------------------------------------------
        -- Footer + time axis
        ------------------------------------------------------------
        local primary = self.series[1]
        if primary and primary.values and #primary.values > 0 then
            local lo, hi, sum = math.huge, -math.huge, 0
            for i = 1, #primary.values do
                local v = primary.values[i]
                if v < lo then lo = v end
                if v > hi then hi = v end
                sum = sum + v
            end
            self.footer:SetText(("min %s   avg %s   max %s")
                :format(self.valueFormat(lo), self.valueFormat(sum / #primary.values), self.valueFormat(hi)))
        else
            self.footer:SetText("")
        end

        if self.fromTime and self.toTime and self.showAxis then
            local span = self.toTime - self.fromTime
            for i = 1, #self.timeLabels do
                local fraction = (i - 1) / (#self.timeLabels - 1)
                local label = self.timeLabels[i]
                label:ClearAllPoints()
                label:SetPoint("TOP", plot, "BOTTOMLEFT", fraction * width, -3)
                local ago = span * (1 - fraction)
                label:SetText(ago < 1 and "now" or ("-" .. Fmt.Duration(ago)))
                label:Show()
            end
        else
            for i = 1, #self.timeLabels do self.timeLabels[i]:Hide() end
        end

        if not drewAnything then
            if not self.empty then
                self.empty = UI.EmptyState(plot, "Collecting data...")
                self.empty:SetAllPoints(plot)
            end
            self.empty:Show()
        elseif self.empty then
            self.empty:Hide()
        end

        self.dirty = false
    end

    --- Sets the time window the graph represents, used for the axis and markers.
    function graph:SetTimeRange(fromTime, toTime)
        self.fromTime, self.toTime = fromTime, toTime
        self.dirty = true
    end

    function graph:Update()
        if self.dirty then self:Draw() end
    end

    ------------------------------------------------------------------
    -- Hover readout
    ------------------------------------------------------------------

    function graph:UpdateHover()
        local primary
        for i = 1, #self.series do
            if self.series[i].renderCount and self.series[i].renderCount > 0 then
                primary = self.series[i]
                break
            end
        end
        if not primary then return end

        local x = GetCursorPosition() / UIParent:GetEffectiveScale() - plot:GetLeft()
        local width = plot:GetWidth()
        if x < 0 or x > width then return end

        local index = math.floor(x / (primary.columnWidth or 1) + 0.5) + 1
        index = math.max(1, math.min(primary.renderCount, index))

        crosshair:ClearAllPoints()
        crosshair:SetPoint("LEFT", plot, "BOTTOMLEFT", (index - 1) * primary.columnWidth, 0)
        crosshair:Show()

        self.hoverIndex = index
        self.hoverTime  = primary.renderTimes and primary.renderTimes[index]

        UI.TooltipClear(self.titleText:GetText() or "")
        if self.hoverTime and self.toTime then
            local ago = self.toTime - self.hoverTime
            UI.TooltipLine("Time", ago < 1 and "now" or ("-" .. Fmt.Duration(ago)))
        end
        for i = 1, #self.series do
            local series = self.series[i]
            if series.renderValues and series.renderValues[index] then
                UI.TooltipLine(series.label or ("Series " .. i),
                    self.valueFormat(series.renderValues[index]) .. (series.unit and (" " .. series.unit) or ""),
                    nil, nil)
            end
        end
        UI.TooltipShow(nil)
    end

    graph:SetScript("OnSizeChanged", function(self)
        self.dirty = true
        self:Draw()
    end)
    graph:SetScript("OnShow", function(self)
        self.dirty = true
        self:Draw()
    end)

    return graph
end

--------------------------------------------------------------------------
-- Sparkline: a tiny graph with no axis, used in the topbar
--------------------------------------------------------------------------

--- `worstIsLow` follows the same rule as UI.Graph: true only for series where
--- the low value is the bad one (FPS).  Everything else keeps its maximum so
--- spikes survive being squeezed into a 40-pixel strip.
function UI.Sparkline(parent, colorIndex, worstIsLow)
    local spark = CreateFrame("Frame", nil, parent)
    spark.pool = RegionPool.New(spark,
        function(p)
            local texture = p:CreateTexture(nil, "ARTWORK")
            return texture
        end,
        function(texture) texture:ClearAllPoints() end)
    spark.colorIndex = colorIndex or 1
    spark.worstIsLow = worstIsLow and true or false

    --- `ring` is a WTM.RingBuffer; nothing is copied out of it.
    function spark:SetRing(ring)
        self.ring = ring
    end

    function spark:Draw()
        if not self:IsVisible() or not self.ring then return end
        local width  = self:GetWidth() or 0
        local height = self:GetHeight() or 0
        local count  = self.ring.count
        if width < 4 or height < 2 or count < 2 then return end

        self.pool:ReleaseAll()

        local columns = math.min(count, math.floor(width / 2))
        if columns < 2 then return end
        local step = count / columns

        local lo, hi = math.huge, -math.huge
        for i = 1, count do
            local v = self.ring:Get(i)
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
        local range = math.max(0.0001, hi - lo)

        local r, g, b = Theme:Series(self.colorIndex)
        local columnWidth = width / columns

        for c = 1, columns do
            local first = math.floor((c - 1) * step) + 1
            local last  = math.min(count, math.floor(c * step))
            local best = self.ring:Get(first) or 0
            for i = first + 1, last do
                local v = self.ring:Get(i)
                if (self.worstIsLow and v < best) or (not self.worstIsLow and v > best) then
                    best = v
                end
            end
            local fraction = (best - lo) / range
            local column = self.pool:Acquire()
            column:SetColorTexture(r, g, b, 0.55)
            column:ClearAllPoints()
            column:SetWidth(math.max(1, columnWidth - 0.5))
            column:SetHeight(math.max(1, fraction * height))
            column:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", (c - 1) * columnWidth, 0)
        end
    end

    return spark
end
