--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Performance.lua

    Large live graphs plus the frame time analyzer.

    The analyzer is the reason this page exists.  FPS on its own is an average
    and averages hide stutter: 118 FPS with a 90 ms hitch every ten seconds
    still reads as "118 FPS".  The distribution and the percentiles are what
    actually describe how the game felt.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format
local MathU = WTM.Math

local Page = UI.RegisterPage("performance", {})

local GRAPHS = {
    { key = "fps",     field = "fps",        title = "FPS",              colorIndex = 1, worstIsLow = true,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "frame",   field = "frameMaxMs", title = "FRAME TIME (worst per bucket)", colorIndex = 2,
      format = function(v) return ("%.0f ms"):format(v) end },
    { key = "latency", field = "latW",       title = "WORLD LATENCY",    colorIndex = 3,
      format = function(v) return ("%.0f ms"):format(v) end },
    { key = "memory",  field = "luaKB",      title = "LUA MEMORY",       colorIndex = 4,
      format = function(v) return Fmt.Memory(v) end },
    { key = "cpu",     field = "cpuMs",      title = "ADDON CPU",        colorIndex = 5,
      format = function(v) return ("%.1f %%"):format(v) end },
    { key = "events",  field = "events",     title = "EVENT RATE",       colorIndex = 6,
      format = function(v) return ("%.0f/s"):format(v) end },
}

function Page:Build(frame)
    local pad = M.padding
    self.series = {}

    ------------------------------------------------------------------
    -- Range selector
    ------------------------------------------------------------------
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(26)
    toolbar:SetPoint("TOPLEFT", pad, -pad)
    toolbar:SetPoint("TOPRIGHT", -pad, -pad)

    local label = UI.Text(toolbar, "small", "textMuted")
    label:SetPoint("LEFT")
    label:SetText("RANGE")

    self.rangeButtons = {}
    local previous
    for _, range in ipairs(C.TIME_RANGES) do
        local button = UI.Button(toolbar, range.label, function()
            self:SetRange(range.key)
        end, { height = 22, minWidth = 52, style = "small" })
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("LEFT", label, "RIGHT", 10, 0)
        end
        button.rangeKey = range.key
        self.rangeButtons[range.key] = button
        previous = button
    end

    self.coverage = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.coverage:SetPoint("RIGHT")

    ------------------------------------------------------------------
    -- Analyzer strip
    ------------------------------------------------------------------
    local analyzer = UI.Panel(frame, {})
    analyzer:SetHeight(104)
    analyzer:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -10)
    analyzer:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -10)
    self.analyzer = analyzer

    local title = UI.Text(analyzer, "heading", "textSecondary")
    title:SetPoint("TOPLEFT", M.padding, -8)
    title:SetText("FRAME TIME ANALYZER")

    -- Percentile readouts
    self.percentiles = {}
    local specs = {
        { key = "avg",    label = "AVERAGE" },
        { key = "median", label = "MEDIAN" },
        { key = "low1",   label = "1% LOW" },
        { key = "low01",  label = "0.1% LOW" },
        { key = "worst",  label = "WORST FRAME" },
        { key = "count",  label = "FRAMES" },
    }
    local previousStat
    for i, spec in ipairs(specs) do
        local group = UI.LabeledValue(analyzer, spec.label, "metric")
        group:SetWidth(120)
        group:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
        if previousStat then
            group:ClearAllPoints()
            group:SetPoint("LEFT", previousStat, "RIGHT", 18, 0)
        end
        previousStat = group
        self.percentiles[spec.key] = group
    end

    -- Distribution bar
    self.distribution = CreateFrame("Frame", nil, analyzer)
    self.distribution:SetHeight(16)
    self.distribution:SetPoint("BOTTOMLEFT", M.padding, 10)
    self.distribution:SetPoint("BOTTOMRIGHT", -M.padding, 10)
    self.distSegments = {}
    for i = 1, 5 do
        local segment = CreateFrame("Frame", nil, self.distribution)
        segment.tex = segment:CreateTexture(nil, "ARTWORK")
        segment.tex:SetAllPoints()
        segment:SetPoint("TOP")
        segment:SetPoint("BOTTOM")
        segment:EnableMouse(true)
        segment:SetScript("OnEnter", function(self)
            if not self.info then return end
            UI.ShowTooltip(self, self.info.label,
                ("%s of frames (%s frames)"):format(
                    Fmt.Percent(self.info.pct), Fmt.Comma(self.info.count)))
        end)
        segment:SetScript("OnLeave", UI.HideTooltip)
        self.distSegments[i] = segment
    end

    ------------------------------------------------------------------
    -- Graph grid
    ------------------------------------------------------------------
    local grid = CreateFrame("Frame", nil, frame)
    grid:SetPoint("TOPLEFT", analyzer, "BOTTOMLEFT", 0, -M.cardGap)
    grid:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
    self.grid = grid

    self.graphs = {}
    for i, spec in ipairs(GRAPHS) do
        local graph = UI.Graph(grid, {
            title = spec.title,
            valueFormat = spec.format,
            worstIsLow = spec.worstIsLow,
            minRange = 1,
            referenceLines = (spec.key == "frame") and {
                { value = 1000 / 60,  label = "60 fps  16.7 ms" },
                { value = 1000 / 144, label = "144 fps  6.9 ms" },
            } or (spec.key == "fps") and {
                { value = 60,  label = "60 fps" },
                { value = 144, label = "144 fps" },
            } or nil,
        })
        graph.spec = spec
        self.graphs[i] = graph
        self.series[spec.key] = { values = {}, times = {} }
    end

    self:OnLayout()
    self:SetRange(WTM.db.profile.ui.timeRange or "5m")
end

function Page:OnLayout()
    if not self.grid then return end
    local width  = self.grid:GetWidth()
    local height = self.grid:GetHeight()
    if not width or width <= 0 then return end

    local columns = 2
    local rows = math.ceil(#self.graphs / columns)
    local graphWidth  = (width - M.cardGap * (columns - 1)) / columns
    local graphHeight = (height - M.cardGap * (rows - 1)) / rows

    for i, graph in ipairs(self.graphs) do
        local column = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        graph:ClearAllPoints()
        graph:SetSize(graphWidth, graphHeight)
        graph:SetPoint("TOPLEFT", self.grid, "TOPLEFT",
            column * (graphWidth + M.cardGap),
            -row * (graphHeight + M.cardGap))
    end
end

function Page:SetRange(key)
    self.range = key
    WTM.db.profile.ui.timeRange = key
    for rangeKey, button in pairs(self.rangeButtons) do
        button:SetSelected(rangeKey == key)
    end
    self:Refresh()
end

function Page:OnShow()
    self:OnLayout()
    self:Refresh()
end

--------------------------------------------------------------------------

local markerScratch = {}

function Page:Refresh()
    if not self.graphs then return end

    ------------------------------------------------------------------
    -- Analyzer
    ------------------------------------------------------------------
    local stats = WTM.FrameTime:GetSessionStats()
    self.percentiles.avg:Set(("%.1f"):format(stats.avgMs), "ms")
    self.percentiles.median:Set(("%.1f"):format(stats.medianMs), "ms")
    self.percentiles.low1:Set(Fmt.FPS(stats.low1), "fps")
    self.percentiles.low01:Set(Fmt.FPS(stats.low01), "fps")
    self.percentiles.worst:Set(("%.0f"):format(stats.maxMs), "ms")
    self.percentiles.count:Set(Fmt.Comma(stats.frames), "")

    self.percentiles.low1.value:SetTextColor(Theme:Tone(
        (stats.avgFPS > 0 and stats.low1 / stats.avgFPS < 0.6) and "warn" or "ok"))

    local distribution, total = WTM.FrameTime:GetStutterDistribution(self._dist or {})
    self._dist = distribution
    local tones = { "ok", "warn", "warn", "crit", "crit" }
    local x = 0
    local width = self.distribution:GetWidth() or 400
    for i, segment in ipairs(self.distSegments) do
        local info = distribution[i]
        segment.info = info
        if info and info.pct > 0 then
            local segmentWidth = math.max(1, width * info.pct / 100)
            segment:ClearAllPoints()
            segment:SetPoint("TOPLEFT", self.distribution, "TOPLEFT", x, 0)
            segment:SetWidth(segmentWidth)
            segment.tex:SetColorTexture(Theme:Tone(tones[i], 0.75))
            segment:Show()
            x = x + segmentWidth + 1
        else
            segment:Hide()
        end
    end

    ------------------------------------------------------------------
    -- Graphs
    ------------------------------------------------------------------
    local now = GetTime()
    local rangeSeconds
    for _, range in ipairs(C.TIME_RANGES) do
        if range.key == self.range then rangeSeconds = range.seconds end
    end
    if not rangeSeconds or rangeSeconds == 0 then
        rangeSeconds = math.max(60, now - (WTM.state.sessionStart or now))
    end
    local fromTime = now - rangeSeconds

    WTM.Context:GetMarkersInRange(fromTime, now, markerScratch)

    for i, graph in ipairs(self.graphs) do
        local spec = graph.spec
        local series = self.series[spec.key]

        if spec.key == "cpu" and not WTM.CPU.available then
            graph:ClearSeries()
            graph:SetTitle(spec.title .. "   -   " .. (WTM.CPU.reason or C.TXT_REQUIRES_PROFILING))
        elseif spec.key == "latency" and not WTM.Caps:Has("latency") then
            graph:ClearSeries()
            graph:SetTitle(spec.title .. "   -   " .. C.TXT_UNAVAILABLE_CLIENT)
        elseif spec.key == "events" and not WTM.Events.available then
            graph:ClearSeries()
            graph:SetTitle(spec.title .. "   -   " .. C.TXT_UNAVAILABLE_CLIENT)
        else
            WTM.Recorder:GetSeries(spec.field, fromTime, now, 300, series.values, series.times)
            graph:SetSeries(1, series.values, series.times, {
                label = spec.title, colorIndex = spec.colorIndex,
            })
            graph:SetTitle(spec.title)
        end

        graph:SetTimeRange(fromTime, now)
        graph:SetMarkers(markerScratch)
        graph.dirty = true
        graph:Draw()
    end

    self.coverage:SetText(("history covers %s   -   %d buckets stored")
        :format(Fmt.Duration(WTM.Recorder:GetCoverage()), WTM.Recorder:CountBuckets()))
end
