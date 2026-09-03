--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Dashboard.lua

    The live view: what is happening right now, at a glance.

    Rebuilt in 0.6.0 around a responsive grid and a declared widget list. The
    previous version placed everything at hand-written offsets for one window
    width, which is why it looked sparse on a wide monitor and cramped on a
    narrow one. Now the grid picks its column count from the width it is given,
    and each widget declares how much room it wants.

    Every widget is an entry in WIDGETS below. That list is the single place
    that knows what the dashboard contains: the layout editor in Settings, the
    show/hide state and the refresh loop all read it, so adding a widget is one
    entry rather than four edits that can disagree.

    Cost rules, unchanged from before and the reason this stays cheap:
      * nothing here samples anything - every number was produced by a module
        that owns it,
      * graphs and sparklines redraw on the shared round-robin budget, not on
        every refresh,
      * a hidden widget is not refreshed at all.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("dashboard", {})

local MAX_OVERHEAD_ROWS = 6
local OVERHEAD_ROW_HEIGHT = 15

--------------------------------------------------------------------------
-- KPI tiles
--------------------------------------------------------------------------
--
-- Twelve of them, compact. Six across on a wide window, three on a narrow one.

local CARDS = {
    { key = "fps", label = "FPS", unit = "", colorIndex = 1, worstIsLow = true,
      tooltip = "Frames per second, computed from the real per-frame delta rather than the client's smoothed GetFramerate value." },
    { key = "fpsAvg", label = "AVG FPS", unit = "", colorIndex = 1, worstIsLow = true,
      tooltip = "Mean frames per second across the whole session. An average hides the individual bad frame, which is why frame time matters more." },
    { key = "low1", label = "1% LOW", unit = "fps", colorIndex = 1, worstIsLow = true,
      tooltip = "The speed of the worst 1% of frames this session, derived from the frame time histogram. The gap between this and the average is what a stutter actually feels like." },
    { key = "low01", label = "0.1% LOW", unit = "fps", colorIndex = 1, worstIsLow = true,
      tooltip = "The worst 0.1% of frames. On a session of any length this is a handful of frames, and it is where freezes show up." },
    { key = "frame", label = "FRAME TIME", unit = "ms", colorIndex = 2,
      tooltip = "Average time to render one frame in the current sample window. 60 FPS is 16.67 ms, 120 FPS is 8.33 ms. This is the measurement everything else is judged against." },
    { key = "frameAvg", label = "AVG FRAME", unit = "ms", colorIndex = 2,
      tooltip = "Mean frame time across the session." },
    { key = "framePeak", label = "PEAK FRAME", unit = "ms", colorIndex = 2,
      tooltip = "The single longest frame measured this session." },
    { key = "latHome", label = "HOME LATENCY", unit = "ms", colorIndex = 3,
      tooltip = "Latency to the realm server, from GetNetStats. The client only refreshes this roughly every 30 seconds, so it is never a live figure." },
    { key = "latWorld", label = "WORLD LATENCY", unit = "ms", colorIndex = 3,
      tooltip = "Latency to the world server, from GetNetStats. Same 30-second refresh caveat." },
    { key = "cpu", label = "ADDON CPU", unit = "%", colorIndex = 5,
      tooltip = "Share of one CPU core spent inside addon Lua, across every loaded addon. Requires the client's scriptProfile CVar." },
    { key = "memory", label = "LUA MEMORY", unit = "", colorIndex = 4,
      tooltip = "The whole Lua heap, which includes the default UI as well as addons. Per-addon attribution is on the Memory page." },
    { key = "events", label = "EVENTS/SEC", unit = "", colorIndex = 6,
      tooltip = "Every event the client fired, counted through a frame with RegisterAllEvents. Depends on the event monitoring mode." },
}

--------------------------------------------------------------------------
-- Graphs.  Frame time first and widest: it is the important one.
--------------------------------------------------------------------------

local GRAPHS = {
    { key = "frame",   field = "frameMaxMs", title = "FRAME TIME  (worst frame per bucket)",
      colorIndex = 2, wide = true,
      format = function(v) return ("%.0f ms"):format(v) end },
    { key = "fps",     field = "fps",    title = "FPS", colorIndex = 1, worstIsLow = true,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "cpu",     field = "cpuMs",  title = "ADDON CPU", colorIndex = 5,
      format = function(v) return ("%.1f %%"):format(v) end },
    { key = "latency", field = "latW",   title = "WORLD LATENCY", colorIndex = 3,
      format = function(v) return ("%.0f ms"):format(v) end },
    { key = "events",  field = "events", title = "EVENTS / SEC", colorIndex = 6,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "memory",  field = "luaKB",  title = "LUA MEMORY", colorIndex = 4,
      format = function(v) return Fmt.Memory(v) end },
}

--------------------------------------------------------------------------
-- The widget catalogue
--------------------------------------------------------------------------
--
-- One entry per movable block. `sizes` maps the three sizes offered in the
-- layout editor to a column span, so "large" means the same thing everywhere.

local SMALL, MEDIUM, LARGE = "small", "medium", "large"

local WIDGETS = {
    { key = "kpi",        label = "Live metrics",       default = LARGE,
      spans = { small = 3, medium = 6, large = 6 } },
    { key = "health",     label = "Performance health", default = SMALL,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "session",    label = "Session summary",    default = SMALL,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "context",    label = "System and context", default = SMALL,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "graphs",     label = "Live graphs",        default = LARGE,
      spans = { small = 3, medium = 6, large = 6 } },
    { key = "topcpu",     label = "Top CPU addons",     default = SMALL,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "topmemory",  label = "Top memory addons",  default = SMALL,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "topevents",  label = "Top event activity", default = SMALL,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "incidents",  label = "Recent incidents",   default = MEDIUM,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "overhead",   label = "This addon's own cost", default = MEDIUM,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "errors",     label = "Lua errors",         default = MEDIUM,
      spans = { small = 2, medium = 3, large = 6 } },
    { key = "recenterrors", label = "Recent Lua errors", default = MEDIUM,
      spans = { small = 2, medium = 3, large = 6 } },
}

Page.WIDGETS = WIDGETS

--- The user's chosen size for a widget, defaulting to the one it declares.
local function sizeFor(spec)
    local sizes = WTM.db.profile.dashboard.sizes
    return sizes[spec.key] or spec.default
end

local function isHidden(spec)
    return WTM.db.profile.dashboard.hidden[spec.key] and true or false
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

function Page:Build(frame)
    self.cards, self.graphs, self.series = {}, {}, {}
    self.blocks = {}

    local scroll, canvas = UI.ScrollCanvas(frame, { padding = M.padding })
    self.scroll, self.canvas = scroll, canvas

    local grid = UI.Grid(canvas, { minColumnWidth = 190, maxColumns = 6 })
    self.grid = grid

    ------------------------------------------------------------------
    -- Banner
    ------------------------------------------------------------------
    local banner = UI.Panel(canvas, { color = "panelAlt" })
    banner.accent = banner:CreateTexture(nil, "ARTWORK")
    banner.accent:SetWidth(3)
    banner.accent:SetPoint("TOPLEFT")
    banner.accent:SetPoint("BOTTOMLEFT")

    banner.verdict = UI.Text(banner, "title", "textPrimary", "LEFT")
    banner.verdict:SetPoint("TOPLEFT", 16, -10)
    banner.verdict:SetPoint("RIGHT", banner, "RIGHT", -110, 0)

    banner.detail = UI.Text(banner, "small", "textSecondary", "LEFT")
    banner.detail:SetPoint("TOPLEFT", banner.verdict, "BOTTOMLEFT", 0, -4)
    banner.detail:SetPoint("RIGHT", banner, "RIGHT", -110, 0)

    banner.uptime = UI.Text(banner, "numeric", "textMuted", "RIGHT")
    banner.uptime:SetPoint("TOPRIGHT", -16, -12)
    banner.uptimeLabel = UI.Text(banner, "tiny", "textMuted", "RIGHT")
    banner.uptimeLabel:SetPoint("TOPRIGHT", -16, -28)
    banner.uptimeLabel:SetText("SESSION")
    self.banner = banner
    grid:Add(banner, { span = 6, height = 56, key = "banner" })

    ------------------------------------------------------------------
    -- Profiling notice: prominent, and never reloads on its own
    ------------------------------------------------------------------
    local notice = UI.Panel(canvas, { color = "panelAlt" })
    self.profilingNotice = notice

    notice.accent = notice:CreateTexture(nil, "ARTWORK")
    notice.accent:SetWidth(3)
    notice.accent:SetPoint("TOPLEFT")
    notice.accent:SetPoint("BOTTOMLEFT")
    notice.accent:SetColorTexture(Theme:Tone("warn"))

    notice.title = UI.Text(notice, "heading", "textPrimary", "LEFT")
    notice.title:SetPoint("TOPLEFT", 16, -10)
    notice.title:SetPoint("RIGHT", notice, "RIGHT", -300, 0)
    notice.title:SetText("Addon CPU profiling is disabled")

    notice.body = UI.Text(notice, "small", "textSecondary", "LEFT")
    notice.body:SetPoint("TOPLEFT", notice.title, "BOTTOMLEFT", 0, -4)
    notice.body:SetPoint("RIGHT", notice, "RIGHT", -300, 0)
    notice.body:SetHeight(30)
    UI.Wrap(notice.body, 2)
    notice.body:SetText("Everything else is recording normally. Per-addon CPU needs the client's scriptProfile CVar, which takes effect after a reload.")

    notice.enable = UI.Button(notice, "Enable profiling", function()
        local ok, err = WTM.Caps:SetCPUProfiling(true)
        if ok then
            Page:Refresh()
            WTM:Print("CPU profiling will be ON after the next |cff4c8dff/reload|r. Nothing has been reloaded for you.")
        else
            WTM:Print("Could not enable CPU profiling: " .. tostring(err))
        end
    end, { primary = true, height = 24 })
    notice.enable:SetPoint("RIGHT", -136, 0)

    -- Deliberately a SEPARATE button. Reloading the UI without being asked is
    -- exactly the kind of thing an addon should never do to someone mid-fight.
    notice.reload = UI.Button(notice, "Reload UI", function()
        WTM.Processes:ReloadUI()
    end, { height = 24 })
    notice.reload:SetPoint("RIGHT", -16, 0)
    notice.reload.tooltip = "Reloads the interface so the CVar takes effect. Queued until combat ends if you are fighting. Nothing reloads without this click."

    grid:Add(notice, { span = 6, height = 52, key = "notice" })

    ------------------------------------------------------------------
    -- KPI tiles, each its own grid cell so they reflow with the window
    ------------------------------------------------------------------
    for _, spec in ipairs(CARDS) do
        local card = UI.MetricCard(canvas, {
            label = spec.label, unit = spec.unit, colorIndex = spec.colorIndex,
            worstIsLow = spec.worstIsLow, tooltip = spec.tooltip,
            height = 74, sparkHeight = 14,
        })
        self.cards[spec.key] = card
        grid:Add(card, { span = 1, height = 74, key = "kpi" })
    end

    ------------------------------------------------------------------
    -- Health, session, context
    ------------------------------------------------------------------
    self.healthGauge = UI.Gauge(canvas, "PERFORMANCE HEALTH", { suffix = "/ 100" })
    grid:Add(self.healthGauge, { span = 2, height = 96, key = "health" })

    self.healthStats = UI.StatCard(canvas, "SPIKES", {
        "Last minute", "Last 5 minutes", "Session total", "Worst spike", "Time since last",
    })
    grid:Add(self.healthStats, { span = 2, height = 122, key = "health" })

    self.sessionCard = UI.StatCard(canvas, "SESSION SUMMARY", {
        "Duration", "Average FPS", "1% low", "0.1% low", "Worst frame",
        "Incidents", "Event storms", "Latency spikes", "Memory growth",
    })
    grid:Add(self.sessionCard, { span = 2, height = 9 * 16 + 40, key = "session" })

    self.contextCard = UI.StatCard(canvas, "SYSTEM AND CONTEXT", {
        "Zone", "Instance", "Difficulty", "Combat", "Group size",
        "Client", "scriptProfile",
    })
    grid:Add(self.contextCard, { span = 2, height = 7 * 16 + 40, key = "context" })

    ------------------------------------------------------------------
    -- Graphs
    ------------------------------------------------------------------
    for i, spec in ipairs(GRAPHS) do
        local graph = UI.Graph(canvas, {
            title = spec.title,
            valueFormat = spec.format,
            worstIsLow = spec.worstIsLow,
            minRange = 1,
            -- Scale frame time to the 95th percentile rather than the peak: a
            -- single 1252 ms freeze otherwise runs the axis to 1000 ms and
            -- flattens every real 8 ms variation into the baseline. Clipped
            -- points are drawn in the alert colour and the true peak is stated.
            softCeiling = (spec.key == "frame") and 0.95 or nil,
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
        grid:Add(graph, {
            span = spec.wide and 6 or 2,
            height = spec.wide and 190 or 150,
            key = "graphs",
        })
    end

    ------------------------------------------------------------------
    -- Top lists
    ------------------------------------------------------------------
    self.topCPU = UI.TopList(canvas, "TOP CPU ADDONS", {
        rows = 5, sparkline = true, colorIndex = 5, wideValue = true,
    })
    self.topCPU.onClick = function(entry)
        if entry and entry.record then UI.AddonDetail:Open(entry.record) end
    end
    grid:Add(self.topCPU, { span = 2, height = self.topCPU.naturalHeight, key = "topcpu" })

    self.topMemory = UI.TopList(canvas, "TOP MEMORY ADDONS", {
        rows = 5, sparkline = true, colorIndex = 4, wideValue = true,
    })
    self.topMemory.onClick = function(entry)
        if entry and entry.record then UI.AddonDetail:Open(entry.record) end
    end
    grid:Add(self.topMemory, { span = 2, height = self.topMemory.naturalHeight, key = "topmemory" })

    self.topEvents = UI.TopList(canvas, "TOP EVENT ACTIVITY", {
        rows = 5, wideValue = true,
    })
    self.topEvents.onClick = function(entry)
        UI.MainWindow:ShowPage("events")
    end
    grid:Add(self.topEvents, { span = 2, height = self.topEvents.naturalHeight, key = "topevents" })

    self.incidentList = UI.TopList(canvas, "RECENT INCIDENTS", {
        rows = 5, wideValue = true,
    })
    self.incidentList.onClick = function(entry)
        if entry and entry.cluster then
            UI.MainWindow:ShowPage("incidents")
            local page = UI.Pages.incidents
            if page and page.SelectCluster then page:SelectCluster(entry.cluster) end
        end
    end
    grid:Add(self.incidentList, { span = 3, height = self.incidentList.naturalHeight, key = "incidents" })

    ------------------------------------------------------------------
    -- Overhead
    ------------------------------------------------------------------
    local overhead = UI.Card(canvas, "THIS ADDON'S MEASURED OVERHEAD", {})
    self.overheadCard = overhead
    self.overheadRows = {}
    for i = 1, MAX_OVERHEAD_ROWS + 1 do
        local row = UI.StatRow(overhead.content, "")
        row:SetPoint("TOPLEFT", 0, -(i - 1) * OVERHEAD_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * OVERHEAD_ROW_HEIGHT)
        self.overheadRows[i] = row
    end
    grid:Add(overhead, {
        span = 3,
        height = OVERHEAD_ROW_HEIGHT * (MAX_OVERHEAD_ROWS + 1) + 40,
        key = "overhead",
    })

    ------------------------------------------------------------------
    -- Lua errors
    ------------------------------------------------------------------
    self.errorCard = UI.StatCard(canvas, "LUA ERRORS", {
        "Total", "Distinct", "Last minute", "Worst addon", "Handler",
    })
    grid:Add(self.errorCard, { span = 3, height = 5 * 16 + 40, key = "errors" })

    self.errorSpark = UI.Graph(canvas, {
        title = "ERRORS PER MINUTE",
        valueFormat = function(v) return ("%.1f"):format(v) end,
    })
    grid:Add(self.errorSpark, { span = 3, height = 120, key = "errors" })

    self.recentErrors = UI.TopList(canvas, "RECENT LUA ERRORS", {
        rows = 5, wideValue = true,
    })
    self.recentErrors.onClick = function(entry)
        if entry and entry.group then UI.ErrorDetail:Open(entry.group) end
    end
    grid:Add(self.recentErrors, {
        span = 3, height = self.recentErrors.naturalHeight, key = "recenterrors" })

    self:ApplyLayoutSettings()
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------

--- Applies the show/hide and size choices, then relays out. Called from
--- Settings when the user changes them, and once at build.
function Page:ApplyLayoutSettings()
    if not self.grid then return end

    for _, spec in ipairs(WIDGETS) do
        local hidden = isHidden(spec)
        local span   = spec.spans[sizeFor(spec)] or spec.spans.medium
        for _, cell in ipairs(self.grid.cells) do
            if cell.key == spec.key then
                cell.frame:SetShown(not hidden)
                -- KPI tiles and graphs are many cells under one key; their
                -- span comes from the cell, not from the widget size, so only
                -- single-cell widgets are resized here.
                if spec.key ~= "kpi" and spec.key ~= "graphs" then
                    cell.span = span
                end
            end
        end
    end

    self:OnLayout(true)
end

--- `force` is only passed when the set of visible cells has changed. A
--- relayout resizes every cell, and resizing a graph marks it dirty - so
--- forcing one on every refresh meant every graph redrew every refresh,
--- which is exactly the cost the redraw budget exists to bound.
function Page:OnLayout(force)
    if not self.grid then return end

    -- The notice only occupies space when there is something to say, and a
    -- change in that is itself a reason to relay out.
    local showNotice = not WTM.CPU.available
    local cell = self.grid:GetCell("notice")
    if cell and cell.frame:IsShown() ~= showNotice then
        cell.frame:SetShown(showNotice)
        force = true
    end

    self.scroll:SyncWidth()
    self.canvas:SetHeight(self.grid:Layout(force))
end

function Page:OnShow()
    self:OnLayout()
    self:Refresh()
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local clusterScratch, breakdownScratch = {}, {}
local errorRateValues, errorRateTimes = {}, {}
local errorEntryScratch = {}
local topCPUScratch, topMemScratch, topEventScratch = {}, {}, {}
local entryScratch = {}

local function resetEntries()
    for i = #entryScratch, 1, -1 do entryScratch[i] = nil end
    return entryScratch
end

function Page:Refresh()
    if not self.cards then return end
    self:OnLayout()

    local ft    = WTM.FrameTime.current
    local stats = WTM.FrameTime:GetSessionStats()
    local net   = WTM.Network.current
    local mem   = WTM.Memory.current
    local cards = self.cards

    ------------------------------------------------------------------
    -- KPI tiles
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[1]) then
        cards.fps:SetValue(Fmt.FPS(ft.fps), "",
            ft.fps >= 55 and "ok" or (ft.fps >= 30 and "warn" or "crit"))
        cards.fps:SetSub(("now"))
        cards.fps:SetRing(WTM.FrameTime.history.fps)

        cards.fpsAvg:SetValue(Fmt.FPS(stats.avgFPS), "")
        cards.fpsAvg:SetSub(("min %s"):format(Fmt.FPS(stats.minFPS)))

        local low1 = stats.low1
        local ratio = (stats.avgFPS > 0) and (low1 / stats.avgFPS) or 1
        cards.low1:SetValue(Fmt.FPS(low1), "fps",
            ratio >= 0.7 and "ok" or (ratio >= 0.5 and "warn" or "crit"))
        cards.low1:SetSub("worst 1% of frames")

        cards.low01:SetValue(Fmt.FPS(stats.low01), "fps")
        cards.low01:SetSub("worst 0.1% of frames")

        cards.frame:SetValue(("%.1f"):format(ft.avgMs), "ms",
            ft.avgMs <= 20 and "ok" or (ft.avgMs <= 40 and "warn" or "crit"))
        cards.frame:SetSub("now")
        cards.frame:SetRing(WTM.FrameTime.history.frameMs)

        cards.frameAvg:SetValue(("%.1f"):format(stats.avgMs or 0), "ms")
        cards.frameAvg:SetSub(("median %s"):format(Fmt.Ms(stats.medianMs or 0)))

        cards.framePeak:SetValue(("%.0f"):format(stats.maxMs or 0), "ms",
            (stats.maxMs or 0) >= 100 and "crit" or nil)
        cards.framePeak:SetSub("worst single frame")

        if WTM.Caps:Has("latency") then
            cards.latHome:SetAvailable()
            cards.latWorld:SetAvailable()
            cards.latHome:SetValue(tostring(net.latencyHome), "ms",
                net.latencyHome <= 80 and "ok" or (net.latencyHome <= 200 and "warn" or "crit"))
            cards.latWorld:SetValue(tostring(net.latencyWorld), "ms",
                net.latencyWorld <= 80 and "ok" or (net.latencyWorld <= 200 and "warn" or "crit"))
            local staleNote = WTM.Network:IsStale()
                and "reading is stale" or ("updated %s"):format(Fmt.Ago(GetTime() - net.lastChangeAt))
            cards.latHome:SetSub(staleNote)
            cards.latWorld:SetSub(staleNote)
            cards.latHome:SetRing(WTM.Network.history.home)
            cards.latWorld:SetRing(WTM.Network.history.world)
        else
            local why = WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT
            cards.latHome:SetUnavailable(why)
            cards.latWorld:SetUnavailable(why)
        end

        if WTM.CPU.available then
            cards.cpu:SetAvailable()
            local pct = WTM.CPU.current.totalPct
            cards.cpu:SetValue(("%.1f"):format(pct), "%",
                pct <= 8 and "ok" or (pct <= 20 and "warn" or "crit"))
            cards.cpu:SetSub(("across %d addons"):format(WTM.Processes:CountLoaded()))
            cards.cpu:SetRing(WTM.CPU.history)
        else
            cards.cpu:SetUnavailable(WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
        end

        cards.memory:SetAvailable()
        cards.memory:SetValue(Fmt.Memory(mem.luaKB), "")
        cards.memory:SetSub(("addons %s"):format(Fmt.Memory(mem.addonSumKB)))
        cards.memory:SetRing(WTM.Memory.history.lua)

        if WTM.Events:GetMode() ~= "OFF" and WTM.Events.available then
            cards.events:SetAvailable()
            cards.events:SetValue(Fmt.Comma(math.floor(WTM.Events.current.perSecond)), "")
            cards.events:SetSub(("%d distinct"):format(WTM.Events:GetDistinctCount()))
            cards.events:SetRing(WTM.Events.history)
        else
            cards.events:SetUnavailable(WTM.Events.available
                and "Event monitoring is off - enable it in Settings"
                or (WTM.Events.reason or C.TXT_UNAVAILABLE_CLIENT))
        end

        for _, card in pairs(cards) do card:Refresh() end
    end

    ------------------------------------------------------------------
    -- Banner
    ------------------------------------------------------------------
    local health, score, info = WTM.Diagnostics:ComputeHealth()
    self.banner.accent:SetColorTexture(Theme:Tone(health.tone))
    self.banner.verdict:SetText(("Performance: %s"):format(health.text))
    self.banner.verdict:SetTextColor(Theme:Tone(health.tone))

    local counts = WTM.SpikeDetector.counts
    local detail = ("%d spikes (%d freeze, %d heavy, %d stutter, %d minor)  -  %.1f/min  -  health %d/100")
        :format(WTM.SpikeDetector.total, counts.freeze, counts.heavy,
                counts.stutter, counts.minor, info.spikesPerMinute, score)
    local suppressedNote = WTM.Suppression:Describe()
    if suppressedNote then detail = detail .. "  -  " .. suppressedNote end
    self.banner.detail:SetText(UI.FitText(self.banner.detail, detail))
    self.banner.uptime:SetText(Fmt.Duration(info.duration))

    ------------------------------------------------------------------
    -- Profiling notice
    ------------------------------------------------------------------
    if not WTM.CPU.available then
        local canToggle = WTM.Caps:Has("toggleProfiling")
        self.profilingNotice.enable:SetEnabledState(canToggle,
            WTM.Caps:Note("toggleProfiling"))
        if WTM.Caps.pendingProfilingReload then
            self.profilingNotice.title:SetText("CPU profiling enabled - reload to apply")
            self.profilingNotice.body:SetText("The scriptProfile CVar is set. Per-addon CPU starts being measured after a reload; nothing reloads until you click.")
        end
    end

    ------------------------------------------------------------------
    -- Health widget
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[2]) then
        self.healthGauge:SetScore(score, health.text, health.tone, info.headline or "")

        local spikes = WTM.SpikeDetector
        self.healthStats:Set("Last minute", tostring(spikes:CountSince(60)))
        self.healthStats:Set("Last 5 minutes", tostring(spikes:CountSince(300)))
        self.healthStats:Set("Session total", tostring(spikes.total))
        local worst = spikes:WorstSpike()
        self.healthStats:Set("Worst spike", worst and Fmt.Ms(worst.frameMs) or "none",
            worst and (worst.frameMs >= 100) and "crit" or nil)
        self.healthStats:Set("Time since last", spikes.lastSpikeAt
            and Fmt.Duration(GetTime() - spikes.lastSpikeAt) or "never")
    end

    ------------------------------------------------------------------
    -- Session summary
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[3]) then
        local card = self.sessionCard
        card:Set("Duration", Fmt.Duration(info.duration))
        card:Set("Average FPS", Fmt.FPS(stats.avgFPS or 0))
        card:Set("1% low", Fmt.FPS(stats.low1 or 0))
        card:Set("0.1% low", Fmt.FPS(stats.low01 or 0))
        card:Set("Worst frame", Fmt.Ms(stats.maxMs or 0))
        card:Set("Incidents", tostring(#WTM.SpikeDetector.clusters))
        card:Set("Event storms", tostring(#WTM.Events.storms))
        card:Set("Latency spikes", tostring(WTM.Network.session.spikes or 0))
        card:Set("Memory growth",
            Fmt.MemoryDelta((mem.luaKB or 0) - (mem.luaStartKB or 0)))
    end

    ------------------------------------------------------------------
    -- Context
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[4]) then
        local state = WTM.Context.state
        local card = self.contextCard
        card:Set("Zone", state.zone or "unknown")
        card:Set("Instance", state.instanceType and state.instanceType ~= "none"
            and state.instanceType or "open world")
        card:Set("Difficulty", state.difficulty or "-")
        card:Set("Combat", state.combat and "in combat" or "out of combat",
            state.combat and "warn" or nil)
        card:Set("Group size", tostring(state.groupSize or 0))
        card:Set("Client", WTM.Compat.flavorName or "?")
        card:Set("scriptProfile", WTM.Caps:IsCPUProfilingEnabled() and "on" or "off",
            WTM.Caps:IsCPUProfilingEnabled() and "ok" or "muted")
    end

    ------------------------------------------------------------------
    -- Graphs
    ------------------------------------------------------------------
    local redraw = UI.MainWindow:ShouldRedrawGraphs()
    if not isHidden(WIDGETS[5]) then
        local now = GetTime()
        local rangeSeconds = 300
        for _, range in ipairs(C.TIME_RANGES) do
            if range.key == (WTM.db.profile.ui.timeRange or "5m") then
                rangeSeconds = range.seconds
            end
        end
        if rangeSeconds == 0 then
            rangeSeconds = math.max(60, now - (WTM.state.sessionStart or now))
        end
        local fromTime = now - rangeSeconds

        local graphCount = #self.graphs
        for graphIndex, graph in ipairs(self.graphs) do
            local spec = graph.spec
            local unavailable
            if spec.key == "cpu" and not WTM.CPU.available then
                unavailable = WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
            elseif spec.key == "latency" and not WTM.Caps:Has("latency") then
                unavailable = C.TXT_UNAVAILABLE_CLIENT
            elseif spec.key == "events" and WTM.Events:GetMode() == "OFF" then
                unavailable = "Event monitoring is off"
            end

            if unavailable then
                graph:ClearSeries()
                graph:SetTitle(spec.title .. "  -  " .. unavailable)
            else
                local series = self.series[spec.key]
                WTM.Recorder:GetSeries(spec.field, fromTime, now, 300, series.values, series.times)
                graph:SetSeries(1, series.values, series.times,
                    { label = spec.title, colorIndex = spec.colorIndex })
                graph:SetTitle(spec.title)
            end
            graph:SetTimeRange(fromTime, now)
            if redraw and UI.MainWindow:TakeGraphSlot(graphIndex, graphCount) then
                graph.dirty = true
                graph:Draw()
            end
        end
    end

    ------------------------------------------------------------------
    -- Top lists
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[6]) then
        local entries = resetEntries()
        if WTM.CPU.available then
            local top = WTM.CPU:GetTopConsumers(topCPUScratch, 5)
            for _, item in ipairs(top) do
                local record = WTM.Processes:Get(item.name)
                entries[#entries + 1] = {
                    name = item.title, value = ("%.2f %%"):format(item.pct),
                    tone = item.pct >= C.HIGH_CPU_PCT and "crit"
                        or (item.pct >= C.ELEVATED_CPU_PCT and "warn" or nil),
                    ring = record and record.cpuRing or nil,
                    record = record, entry = { record = record },
                    tooltipTitle = item.title,
                    tooltipLines = record and {
                        { "Current", ("%.2f %%"):format(record.cpuPct or 0) },
                        { "Average", ("%.2f %%"):format(
                            (record.cpuSamples or 0) > 0
                                and (record.cpuSumPct / record.cpuSamples) or 0) },
                        { "Peak", ("%.2f %%"):format(record.cpuPeakPct or 0) },
                        { C.TXT_CPU_WINDOW_NOTE, nil, "muted" },
                    } or nil,
                }
            end
        end
        self.topCPU:SetEntries(entries, WTM.CPU.available
            and "No addon has used measurable CPU yet."
            or (WTM.CPU.reason or C.TXT_REQUIRES_PROFILING))
        if redraw then self.topCPU:DrawSparklines() end
    end

    if not isHidden(WIDGETS[7]) then
        local entries = resetEntries()
        if WTM.Caps:Has("addonMemory") then
            local top = WTM.Memory:GetTopConsumers(topMemScratch, 5)
            for _, item in ipairs(top) do
                local record = WTM.Processes:Get(item.name)
                entries[#entries + 1] = {
                    name = item.title or item.name,
                    value = Fmt.Memory(item.memKB or 0),
                    ring = record and record.memRing or nil,
                    record = record, entry = { record = record },
                    tooltipTitle = item.title or item.name,
                    tooltipLines = record and {
                        { "Current", Fmt.Memory(record.memKB or 0) },
                        { "Since login", Fmt.MemoryDelta(
                            (record.memKB or 0) - (record.memStartKB or record.memKB or 0)) },
                        { "Per minute", Fmt.Memory(record.memGrowthKBPerMin or 0) },
                    } or nil,
                }
            end
        end
        self.topMemory:SetEntries(entries,
            WTM.Caps:Note("addonMemory") or C.TXT_UNAVAILABLE_CLIENT)
        if redraw then self.topMemory:DrawSparklines() end
    end

    if not isHidden(WIDGETS[8]) then
        local entries = resetEntries()
        if WTM.Events:GetMode() ~= "OFF" and WTM.Events.available then
            local top = WTM.Events:GetTopEvents(topEventScratch, 5)
            for _, item in ipairs(top) do
                entries[#entries + 1] = {
                    name = item.event,
                    value = Fmt.Rate(item.rate or 0),
                    tone = item.storming and "warn" or nil,
                    tooltipTitle = item.event,
                    tooltipLines = {
                        { "Rate now", Fmt.Rate(item.rate or 0) },
                        { "Peak rate", Fmt.Rate(item.peak or 0) },
                        { "Total", Fmt.Comma(item.total or 0) },
                    },
                }
            end
        end
        self.topEvents:SetEntries(entries,
            WTM.Events:GetMode() == "OFF"
                and "Event monitoring is off - enable it in Settings."
                or "No events counted yet.")
    end

    ------------------------------------------------------------------
    -- Recent incidents
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[9]) then
        local entries = resetEntries()
        local clusters = WTM.SpikeDetector.clusters
        for i = #clusters, math.max(1, #clusters - 4), -1 do
            local cluster = clusters[i]
            if cluster then
                local candidates = WTM.Correlation:ForSpike(cluster.peakSpike or cluster, clusterScratch)
                local suspect = candidates and candidates[1]
                entries[#entries + 1] = {
                    name = ("%s  %s"):format(
                        Fmt.Clock(cluster.startedAt, WTM.state.sessionEpoch, WTM.state.sessionStart),
                        cluster.label or "Stutter"),
                    value = Fmt.Ms(cluster.peakMs or 0),
                    tone = (cluster.peakMs or 0) >= 100 and "crit" or "warn",
                    cluster = cluster, entry = { cluster = cluster },
                    tooltipTitle = cluster.label or "Stutter cluster",
                    tooltipLines = {
                        { "Peak frame", Fmt.Ms(cluster.peakMs or 0) },
                        { "Duration", ("%.2f s"):format(cluster.duration or 0) },
                        { "Affected frames", tostring(cluster.frames or 0) },
                        -- An association, never a cause. The wording is the
                        -- same everywhere this appears.
                        { "Most associated", suspect
                            and ("%s (phi %.2f)"):format(suspect.title or suspect.name,
                                suspect.sessionPhi or suspect.phi or 0)
                            or "none stood out" },
                    },
                }
            end
        end
        self.incidentList:SetEntries(entries,
            "No stutter recorded. Incidents appear here with the seconds before and after them.")
    end

    ------------------------------------------------------------------
    -- Overhead breakdown
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[10]) then
        local breakdown = WTM.Overhead:GetBreakdown(breakdownScratch)
        local shown = math.min(#breakdown, MAX_OVERHEAD_ROWS)

        for i = 1, shown do
            local entry, row = breakdown[i], self.overheadRows[i]
            row:Show()
            row:SetLabel(entry.label)
            if entry.measured then
                row:Set(("%.3f ms/s"):format(entry.ms))
            else
                row:Set("not measured", "muted")
            end
            row.tooltip = entry.note
        end

        local totalRow = self.overheadRows[shown + 1]
        if totalRow then
            totalRow:Show()
            totalRow:SetLabel("|cffe6e9efTotal measured|r")
            totalRow:Set(("%.3f ms/s  (%.2f%% of a frame)")
                :format(WTM.Overhead.current.totalMsPerSec,
                        WTM.Overhead:GetFrameBudgetPercent()),
                WTM.Overhead.current.verdict == "ok" and "ok" or "warn")
            local sum, total, delta = WTM.Overhead:ReconcileBreakdown()
            totalRow.tooltip = ("Categories sum to %.3f ms/s against a measured total of %.3f ms/s (difference %.3f)."):
                format(sum, total, delta)
        end

        for i = shown + 2, #self.overheadRows do self.overheadRows[i]:Hide() end
    end

    ------------------------------------------------------------------
    -- Lua errors
    ------------------------------------------------------------------
    if not isHidden(WIDGETS[11]) then
        local Errors = WTM.Errors
        local stats  = Errors.stats

        if not WTM.Caps:Has("errorCapture") then
            self.errorCard:SetUnavailable("Total",
                "seterrorhandler is missing on this client")
        else
            self.errorCard:Set("Total", Fmt.Comma(stats.total),
                stats.total > 0 and "warn" or "ok")
        end
        self.errorCard:Set("Distinct", Fmt.Comma(#Errors.groups))
        local lastMinute = Errors:CountSince(60)
        self.errorCard:Set("Last minute", Fmt.Comma(lastMinute),
            lastMinute > 0 and "warn" or nil)

        local worstName, worstCount = Errors:WorstAddon()
        self.errorCard:Set("Worst addon", worstName
            and ("%s (%d)"):format(worstName, worstCount) or "none")

        -- Whether another error addon is also installed is the thing people
        -- actually want to know here, so it is on the dashboard rather than
        -- buried on a settings page.
        local chainState, chainTone = Errors:ShortChainState()
        self.errorCard:Set("Handler", chainState, chainTone)

        -- Not on the round-robin graph budget, because it does not need to be:
        -- this series only changes when an error arrives, and errors are rare.
        -- Redrawing on change costs less than a slot in the rotation and never
        -- takes one away from a graph whose data moves every tick.
        if self._errorTotalDrawn ~= stats.total then
            self._errorTotalDrawn = stats.total
            local values, times = Errors:RateSeries(errorRateValues, errorRateTimes)
            self.errorSpark:SetSeries(1, values, times,
                { label = "Errors/min", colorIndex = 2 })
            self.errorSpark:SetTimeRange(times[1], times[#times])
            self.errorSpark.dirty = true
            self.errorSpark:Draw()
        end
    end

    if not isHidden(WIDGETS[12]) then
        local entries = errorEntryScratch
        for i = #entries, 1, -1 do entries[i] = nil end

        local groups = WTM.Errors.groups
        for i = #groups, math.max(1, #groups - 4), -1 do
            local group = groups[i]
            if group then
                entries[#entries + 1] = {
                    name  = ("%s: %s"):format(group.addon or "Unknown",
                        Fmt.StripColors(group.message or "")),
                    value = group.count > 1 and ("x%d"):format(group.count)
                        or Fmt.Ago(group.lastAt),
                    tone  = group.internal and "crit"
                        or (group.count >= C.ERROR_REPEAT_THRESHOLD and "warn" or nil),
                    group = group,
                    entry = { group = group },
                    tooltipTitle = group.addon or "Unknown addon",
                    tooltipLines = {
                        { "Occurrences", Fmt.Comma(group.count) },
                        { "First seen", Fmt.Ago(group.firstAt) },
                        { "Where", ("%s:%s"):format(group.file or "?",
                            tostring(group.line or "?")) },
                    },
                }
            end
        end
        self.recentErrors:SetEntries(entries, WTM.Caps:Has("errorCapture")
            and "No Lua error has been captured this session."
            or "This client does not expose seterrorhandler, so no error can be captured.")
    end
end
