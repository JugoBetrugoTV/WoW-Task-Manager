--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/FrameAnalysis.lua

    Everything about frame time in one place.

    Frame time is the signal this addon exists for. FPS is an average and hides
    the frame that ruined the pull; frame time shows it. So this page is built
    around the distribution rather than the mean: percentiles, pacing bands,
    and the clusters of bad frames that a player experiences as one stutter.

    The pacing bands are descriptive groupings, not a claim about perception.
    Where the frames fell is a measurement; whether it felt bad is not something
    this addon can see.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("frames", {})

local seriesValues, seriesTimes = {}, {}
local markerScratch = {}
local bandCounts = {}

function Page:Build(frame)
    local scroll, canvas = UI.ScrollCanvas(frame, { padding = M.padding })
    self.scroll, self.canvas = scroll, canvas

    local grid = UI.Grid(canvas, { minColumnWidth = 260, maxColumns = 4 })
    self.grid = grid

    ------------------------------------------------------------------
    -- Percentiles: the numbers that describe the distribution
    ------------------------------------------------------------------
    self.now = UI.StatCard(canvas, "RIGHT NOW", {
        "Frame time", "FPS", "Rolling baseline", "Worst in window",
    })
    grid:Add(self.now, { span = 1, height = 106, key = "now" })

    self.percentiles = UI.StatCard(canvas, "DISTRIBUTION", {
        "Average", "Median", "p95", "p99", "p99.9",
    })
    grid:Add(self.percentiles, { span = 1, height = 122, key = "percentiles" })

    self.lows = UI.StatCard(canvas, "LOWS", {
        "1% low", "0.1% low", "Worst frame", "Frames measured",
    })
    grid:Add(self.lows, { span = 1, height = 106, key = "lows" })

    self.pacingScore = UI.Gauge(canvas, "FRAME PACING", { suffix = "% stable" })
    grid:Add(self.pacingScore, { span = 1, height = 106, key = "pacing" })

    ------------------------------------------------------------------
    -- The big graph
    ------------------------------------------------------------------
    self.graph = UI.Graph(canvas, {
        title = "FRAME TIME (worst frame per bucket)",
        unit = "ms", showReferenceLines = true,
    })
    grid:Add(self.graph, { span = 4, height = 220, key = "graph" })

    ------------------------------------------------------------------
    -- Distribution shapes
    ------------------------------------------------------------------
    self.histogram = UI.Histogram(canvas, { title = "FRAME TIME HISTOGRAM" })
    grid:Add(self.histogram, { span = 2, height = 190, key = "histogram" })

    self.bands = UI.BucketBars(canvas, "PACING BANDS", C.FRAME_PACING_BANDS, {
        labelWidth = 92, valueWidth = 96,
    })
    grid:Add(self.bands, { span = 2, height = self.bands.naturalHeight, key = "bands" })

    ------------------------------------------------------------------
    -- Clusters
    ------------------------------------------------------------------
    self.clusters = UI.TopList(canvas, "STUTTER CLUSTERS", {
        rows = 8, wideValue = true,
    })
    self.clusters.onClick = function(entry)
        if entry and entry.cluster then
            UI.MainWindow:ShowPage("incidents")
            local page = UI.Pages.incidents
            if page and page.SelectCluster then page:SelectCluster(entry.cluster) end
        end
    end
    grid:Add(self.clusters, { span = 2, height = self.clusters.naturalHeight, key = "clusters" })

    self.pacingNote = UI.Card(canvas, "HOW TO READ THIS", {})
    self.pacingNote.body = UI.Text(self.pacingNote.content, "small", "textMuted", "LEFT")
    self.pacingNote.body:SetPoint("TOPLEFT")
    self.pacingNote.body:SetPoint("BOTTOMRIGHT")
    UI.Wrap(self.pacingNote.body, 0)
    self.pacingNote.body:SetJustifyV("TOP")
    self.pacingNote.body:SetText(
        "A stutter is not a low average. It is a small number of frames that took far longer than the ones around them, which is why the percentiles matter more than the mean.\n\n" ..
        "1% low is the average of the worst 1% of frames, expressed as FPS. The gap between it and the average is what a stutter feels like.\n\n" ..
        "Clusters group bad frames that arrived close together: several slow frames in a row are experienced as one stutter, not as five.\n\n" ..
        "The bands are groupings of measured frame times. Where a frame landed is measured; whether you noticed it is not something this addon can see.")
    grid:Add(self.pacingNote, { span = 2, height = self.clusters.naturalHeight, key = "note" })

    self:OnLayout()
end

--- `force` is only passed when the set of visible cells has changed. A
--- relayout resizes every cell, and a resize is not free - doing it on every
--- refresh made the grid itself the most expensive thing on the page.
function Page:OnLayout(force)
    if not self.grid then return end
    self.scroll:SyncWidth()
    self.canvas:SetHeight(self.grid:Layout(force))
end

function Page:OnShow() self:Refresh() end

--------------------------------------------------------------------------

--- Counts measured frames into the pacing bands. Reads the histogram the frame
--- time module already maintains rather than walking a series.
local function CountBands(out)
    for i = 1, #C.FRAME_PACING_BANDS do out[i] = 0 end
    local histogram = WTM.FrameTime:GetHistogram()
    local total = 0
    for bucket = 1, #histogram do
        local count = histogram[bucket] or 0
        if count > 0 then
            local ms = WTM.Math.HistogramValue(bucket)
            for band = 1, #C.FRAME_PACING_BANDS do
                if ms < C.FRAME_PACING_BANDS[band].max then
                    out[band] = out[band] + count
                    break
                end
            end
            total = total + count
        end
    end
    return total
end

function Page:Refresh()
    if not self.grid then return end
    self:OnLayout()

    local stats = WTM.FrameTime:GetSessionStats()
    local cur   = WTM.FrameTime.current

    ------------------------------------------------------------------
    self.now:Set("Frame time", Fmt.Ms(cur.avgMs or 0))
    self.now:Set("FPS", Fmt.FPS(cur.fps or 0))
    self.now:Set("Rolling baseline", Fmt.Ms(cur.baselineMs or 0))
    self.now:Set("Worst in window", Fmt.Ms(cur.maxMs or 0))

    local function pct(p)
        local value = WTM.FrameTime:GetPercentileMs(p)
        return value and Fmt.Ms(value) or "-"
    end
    self.percentiles:Set("Average", Fmt.Ms(stats.avgMs or 0))
    self.percentiles:Set("Median", Fmt.Ms(stats.medianMs or 0))
    self.percentiles:Set("p95", pct(0.95))
    self.percentiles:Set("p99", pct(0.99))
    self.percentiles:Set("p99.9", pct(0.999))

    self.lows:Set("1% low", Fmt.FPS(stats.low1 or 0))
    self.lows:Set("0.1% low", Fmt.FPS(stats.low01 or 0))
    self.lows:Set("Worst frame", Fmt.Ms(stats.maxMs or 0),
        (stats.maxMs or 0) >= 100 and "crit" or nil)
    self.lows:Set("Frames measured", Fmt.Comma(stats.frames or 0))

    ------------------------------------------------------------------
    local total = CountBands(bandCounts)
    local stable = (bandCounts[1] or 0) + (bandCounts[2] or 0) + (bandCounts[3] or 0)
    local stablePct = total > 0 and (stable / total * 100) or 0

    local band = C.HEALTH.CRITICAL
    if stablePct >= 98 then band = C.HEALTH.EXCELLENT
    elseif stablePct >= 92 then band = C.HEALTH.GOOD
    elseif stablePct >= 80 then band = C.HEALTH.DEGRADED
    elseif stablePct >= 60 then band = C.HEALTH.POOR end

    self.pacingScore:SetScore(stablePct, band.text, band.tone,
        total > 0 and ("%s of %s frames at 30 FPS or better")
            :format(Fmt.Comma(stable), Fmt.Comma(total)) or "no frames measured yet")

    self.bands:SetValues(bandCounts, total, function(value, fraction)
        return ("%s  %.1f%%"):format(Fmt.Comma(value), fraction * 100)
    end)

    ------------------------------------------------------------------
    -- Clusters, newest first.
    local entries = {}
    local clusters = WTM.SpikeDetector.clusters
    for i = #clusters, math.max(1, #clusters - 7), -1 do
        local cluster = clusters[i]
        if cluster then
            entries[#entries + 1] = {
                name = ("%s  %s"):format(
                    Fmt.Clock(cluster.startedAt, WTM.state.sessionEpoch, WTM.state.sessionStart),
                    cluster.label or "Stutter"),
                value = Fmt.Ms(cluster.peakMs or 0),
                tone = (cluster.peakMs or 0) >= 100 and "crit" or "warn",
                cluster = cluster,
                entry = { cluster = cluster },
                tooltipTitle = cluster.label or "Stutter cluster",
                tooltipLines = {
                    { "Peak frame", Fmt.Ms(cluster.peakMs or 0) },
                    { "Duration", ("%.2f s"):format(cluster.duration or 0) },
                    { "Affected frames", tostring(cluster.frames or 0) },
                    { "State", cluster.closed and "closed" or "still open" },
                },
            }
        end
    end
    self.clusters:SetEntries(entries,
        "No stutter clusters yet. A cluster is several bad frames close together, recorded as one incident.")

    ------------------------------------------------------------------
    -- Graph and histogram, both on the shared redraw budget.
    local redraw = UI.MainWindow:ShouldRedrawGraphs()
    if redraw then
        local now = GetTime()
        local from = now - math.max(60, math.min(1800,
            now - (WTM.state.sessionStart or now)))
        WTM.Recorder:GetSeries("frameAvgMs", from, now, 400, seriesValues, seriesTimes)
        self.graph:SetSeries(1, seriesValues, seriesTimes,
            { label = "Frame time", colorIndex = 2 })
        self.graph:SetTimeRange(from, now)
        WTM.Context:GetMarkersInRange(from, now, markerScratch)
        self.graph:SetMarkers(markerScratch)

        if UI.MainWindow:TakeGraphSlot(1, 2) then
            self.graph.dirty = true
            self.graph:Draw()
        end
        if UI.MainWindow:TakeGraphSlot(2, 2) then
            self.histogram:SetHistogram(
                WTM.FrameTime:GetHistogram(), WTM.Math.HistogramValue,
                WTM.FrameTime:GetPercentileMs(0.99),
                ("1%% low  %s"):format(Fmt.Ms(WTM.FrameTime:GetPercentileMs(0.99) or 0)))
            self.histogram.dirty = true
            self.histogram:Draw()
        end
    end
end
