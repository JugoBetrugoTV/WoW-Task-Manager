--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Overview.lua

    What this session looked like, in sentences and summary numbers.

    The Dashboard answers "what is happening right now". This page answers
    "what happened", which is a different question and wants a different shape:
    settled totals rather than live gauges, and observations rather than dials.

    Every observation is a description of something measured, in the past
    tense, carrying the numbers it rests on. None of them says why. That
    distinction is the whole reason this page can exist without becoming a
    machine for generating plausible-sounding accusations.

    It reads from data other modules have already sampled and adds no sampling
    of its own.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("overview", {})

local observationScratch = {}

function Page:Build(frame)
    local scroll, canvas = UI.ScrollCanvas(frame, { padding = M.padding })
    self.scroll, self.canvas = scroll, canvas

    local grid = UI.Grid(canvas, { minColumnWidth = 300, maxColumns = 3 })
    self.grid = grid

    ------------------------------------------------------------------
    -- Health, front and centre
    ------------------------------------------------------------------
    self.health = UI.Gauge(canvas, "PERFORMANCE SCORE", { suffix = "/ 100" })
    grid:Add(self.health, { span = 1, height = 108, key = "score" })

    self.session = UI.StatCard(canvas, "SESSION", {
        "Duration", "Frames rendered", "Zone", "Client", "CPU profiling",
    })
    grid:Add(self.session, { span = 1, height = 108, key = "session" })

    self.headline = UI.StatusCard(canvas, "BIGGEST CONCERN", {
        "Spikes", "Worst frame", "Time since last",
    })
    grid:Add(self.headline, { span = 1, height = 108, key = "headline" })

    ------------------------------------------------------------------
    -- Observations: the part people actually read
    ------------------------------------------------------------------
    self.observations = UI.ObservationList(canvas, "TOP OBSERVATIONS", { rows = 8 })
    grid:Add(self.observations, { span = 2, height = 8 * 40 + 44, key = "observations" })

    ------------------------------------------------------------------
    -- Per-area summaries
    ------------------------------------------------------------------
    self.fps = UI.StatCard(canvas, "FRAME RATE", {
        "Average", "Minimum", "1% low", "0.1% low",
    })
    grid:Add(self.fps, { span = 1, height = 106, key = "fps" })

    -- NOT self.frame. That field belongs to MainWindow, which stores the
    -- page's own frame in it and hides THAT when you switch page. Assigning a
    -- card to it meant every switch hid this card and left the whole page
    -- drawn on top of wherever you went next.
    self.frameTime = UI.StatCard(canvas, "FRAME TIME", {
        "Average", "Median", "p95", "p99", "Worst",
    })
    grid:Add(self.frameTime, { span = 1, height = 122, key = "frame" })

    self.cpu = UI.StatCard(canvas, "ADDON CPU", {
        "Total now", "Busiest addon", "Its share", "Addons loaded",
    })
    grid:Add(self.cpu, { span = 1, height = 106, key = "cpu" })

    self.memory = UI.StatCard(canvas, "MEMORY", {
        "Lua heap now", "At login", "Growth", "Peak", "Observed decreases",
    })
    grid:Add(self.memory, { span = 1, height = 122, key = "memory" })

    self.latency = UI.StatCard(canvas, "LATENCY", {
        "Home", "World", "Average world", "Peak world", "Latency spikes",
    })
    grid:Add(self.latency, { span = 1, height = 122, key = "latency" })

    self.events = UI.StatCard(canvas, "EVENTS", {
        "Rate now", "Peak rate", "Total", "Distinct", "Storms",
    })
    grid:Add(self.events, { span = 1, height = 122, key = "events" })

    self.incidents = UI.StatCard(canvas, "INCIDENTS", {
        "Freeze", "Heavy stutter", "Stutter", "Minor", "Suppressed",
    })
    grid:Add(self.incidents, { span = 1, height = 122, key = "incidents" })

    self.overhead = UI.StatCard(canvas, "THIS ADDON'S OWN COST", {
        "Total measured", "Share of a frame", "Sampling", "UI", "Verdict",
    })
    grid:Add(self.overhead, { span = 1, height = 122, key = "overhead" })

    self.note = UI.Text(canvas, "tiny", "textMuted", "LEFT")
    self.note:SetHeight(30)
    UI.Wrap(self.note, 2)
    self.note:SetText("Everything on this page describes what was measured. Where two things are reported together, they occurred together - this addon does not decide what caused what.")
    grid:Add(self.note, { span = 3, height = 30, key = "note" })

    self:OnLayout()
end

function Page:OnLayout()
    if not self.grid then return end
    self.scroll:SyncWidth()
    local height = self.grid:Layout(true)
    self.canvas:SetHeight(height)
end

function Page:OnShow() self:Refresh() end

--------------------------------------------------------------------------

local function fmtPercentileMs(percentile)
    local value = WTM.FrameTime:GetPercentileMs(percentile)
    return value and Fmt.Ms(value) or "-"
end

function Page:Refresh()
    if not self.grid then return end
    self:OnLayout()

    local stats    = WTM.FrameTime:GetSessionStats()
    local duration = GetTime() - (WTM.state.sessionStart or GetTime())
    local health, score, info = WTM.Diagnostics:ComputeHealth()

    ------------------------------------------------------------------
    self.health:SetScore(score, health.text, health.tone,
        ("over %s of play"):format(Fmt.Duration(duration)))

    self.session:Set("Duration", Fmt.Duration(duration))
    self.session:Set("Frames rendered", Fmt.Comma(stats.frames or 0))
    self.session:Set("Zone", WTM.Context.state.zone or "unknown")
    self.session:Set("Client", WTM.Compat.flavorName or "?")
    self.session:Set("CPU profiling", WTM.CPU.available and "on" or "off",
        WTM.CPU.available and "ok" or "muted")

    ------------------------------------------------------------------
    local spikes = WTM.SpikeDetector
    local severe = (spikes.counts.freeze or 0) + (spikes.counts.heavy or 0)
    local sinceLast = spikes.lastSpikeAt and (GetTime() - spikes.lastSpikeAt) or nil
    self.headline:SetState(health.text, health.tone, info.headline or "")
    self.headline:Set("Spikes", tostring(spikes.total))
    self.headline:Set("Worst frame", Fmt.Ms(stats.maxMs or 0),
        (stats.maxMs or 0) >= 100 and "warn" or nil)
    self.headline:Set("Time since last",
        sinceLast and Fmt.Duration(sinceLast) or "never")

    ------------------------------------------------------------------
    WTM.Observations:Build(observationScratch)
    self.observations:SetObservations(observationScratch,
        "Nothing has been measured yet. Give it a minute of play.")

    ------------------------------------------------------------------
    self.fps:Set("Average", Fmt.FPS(stats.avgFPS or 0))
    self.fps:Set("Minimum", Fmt.FPS(stats.minFPS or 0))
    self.fps:Set("1% low", Fmt.FPS(stats.low1 or 0))
    self.fps:Set("0.1% low", Fmt.FPS(stats.low01 or 0))

    self.frameTime:Set("Average", Fmt.Ms(stats.avgMs or 0))
    self.frameTime:Set("Median", Fmt.Ms(stats.medianMs or 0))
    self.frameTime:Set("p95", fmtPercentileMs(0.95))
    self.frameTime:Set("p99", fmtPercentileMs(0.99))
    self.frameTime:Set("Worst", Fmt.Ms(stats.maxMs or 0))

    ------------------------------------------------------------------
    if WTM.CPU.available then
        local top = WTM.CPU:GetTopConsumers({}, 1)[1]
        self.cpu:Set("Total now", ("%.1f %%"):format(WTM.CPU.current.totalPct or 0))
        self.cpu:Set("Busiest addon", top and Fmt.Truncate(top.title, 20) or "none")
        self.cpu:Set("Its share", top and ("%.2f %%"):format(top.pct) or "-")
    else
        self.cpu:SetUnavailable("Total now", WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
        self.cpu:SetUnavailable("Busiest addon", WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
        self.cpu:SetUnavailable("Its share", WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
    end
    self.cpu:Set("Addons loaded", ("%d of %d")
        :format(WTM.Processes:CountLoaded(), #WTM.Processes.list))

    ------------------------------------------------------------------
    local mem = WTM.Memory.current
    self.memory:Set("Lua heap now", Fmt.Memory(mem.luaKB or 0))
    self.memory:Set("At login", Fmt.Memory(mem.luaStartKB or 0))
    local growth = (mem.luaKB or 0) - (mem.luaStartKB or 0)
    self.memory:Set("Growth", Fmt.MemoryDelta(growth), growth > 51200 and "warn" or nil)
    self.memory:Set("Peak", Fmt.Memory(mem.luaPeakKB or 0))
    -- Never "collections": WoW reports none, and this is the heap curve.
    self.memory:Set("Observed decreases", tostring(WTM.Memory.heapDrops.events or 0))

    ------------------------------------------------------------------
    if WTM.Caps:Has("latency") then
        local net = WTM.Network
        local samples = net.session.samples or 0
        self.latency:Set("Home", ("%d ms"):format(net.current.latencyHome or 0))
        self.latency:Set("World", ("%d ms"):format(net.current.latencyWorld or 0))
        self.latency:Set("Average world", samples > 0
            and ("%d ms"):format(net.session.sumWorld / samples) or "-")
        self.latency:Set("Peak world", ("%d ms"):format(net.session.peakWorld or 0))
        self.latency:Set("Latency spikes", tostring(net.session.spikes or 0))
    else
        local reason = WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT
        for _, label in ipairs({ "Home", "World", "Average world", "Peak world", "Latency spikes" }) do
            self.latency:SetUnavailable(label, reason)
        end
    end

    ------------------------------------------------------------------
    if WTM.Events:GetMode() ~= "OFF" and WTM.Events.available then
        self.events:Set("Rate now", Fmt.Rate(WTM.Events.current.perSecond or 0))
        self.events:Set("Peak rate", Fmt.Rate(WTM.Events.current.peakPerSecond or 0))
        self.events:Set("Total", Fmt.Comma(WTM.Events.current.total or 0))
        self.events:Set("Distinct", tostring(WTM.Events:GetDistinctCount()))
        self.events:Set("Storms", tostring(#WTM.Events.storms))
    else
        local reason = WTM.Events:GetMode() == "OFF"
            and "Event monitoring is switched off in Settings."
            or (WTM.Events.reason or C.TXT_UNAVAILABLE_CLIENT)
        for _, label in ipairs({ "Rate now", "Peak rate", "Total", "Distinct", "Storms" }) do
            self.events:SetUnavailable(label, reason)
        end
    end

    ------------------------------------------------------------------
    local counts = spikes.counts
    self.incidents:Set("Freeze", tostring(counts.freeze or 0),
        (counts.freeze or 0) > 0 and "crit" or nil)
    self.incidents:Set("Heavy stutter", tostring(counts.heavy or 0),
        (counts.heavy or 0) > 0 and "warn" or nil)
    self.incidents:Set("Stutter", tostring(counts.stutter or 0))
    self.incidents:Set("Minor", tostring(counts.minor or 0))
    self.incidents:Set("Suppressed", tostring(WTM.Suppression:TotalSuppressed()))

    ------------------------------------------------------------------
    local overhead = WTM.Overhead.current
    self.overhead:Set("Total measured", ("%.3f ms/s"):format(overhead.totalMsPerSec or 0))
    self.overhead:Set("Share of a frame", ("%.2f %%"):format(WTM.Overhead:GetFrameBudgetPercent()))
    self.overhead:Set("Sampling", ("%.3f ms/s"):format(overhead.samplingMsPerSec or 0))
    self.overhead:Set("UI", ("%.3f ms/s"):format(overhead.uiMsPerSec or 0))
    self.overhead:Set("Verdict", overhead.verdict == "ok" and "within budget" or "above budget",
        overhead.verdict == "ok" and "ok" or "warn")
end
