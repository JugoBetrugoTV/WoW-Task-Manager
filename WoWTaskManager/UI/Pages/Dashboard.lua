--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Dashboard.lua

    The page you get from typing /wtm. It has to be useful within one second of
    opening, on any of the four clients, whether or not CPU profiling is on.

    Layout:
        health banner  -  verdict, spike counts, suppressed count, uptime
        metric row     -  FPS, frame time, 1% low, home/world latency,
                          addon CPU, addon memory, events/sec
        graph grid     -  frame time (largest, first), FPS, addon CPU,
                          latency, events, memory
        footer         -  measured overhead breakdown and recent incidents

    Frame time leads because it is the measurement everything else is judged
    against, and because FPS alone hides stutter: 118 FPS with a 90 ms hitch
    every ten seconds still reads as 118 FPS.

    Cards whose measurement this client cannot provide put themselves into an
    explained "unavailable" state instead of showing a zero.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics

-- How many overhead categories the card has room for, and how tall each row is.
-- The card is sized from these, so adding a category widens the card instead of
-- pushing a row off the bottom of it.
local MAX_OVERHEAD_ROWS  = 6
local OVERHEAD_ROW_HEIGHT = 15
local Fmt   = WTM.Format

local Page = UI.RegisterPage("dashboard", {})

--------------------------------------------------------------------------
-- Metric tiles
--------------------------------------------------------------------------

local CARDS = {
    { key = "fps", label = "FPS", unit = "", colorIndex = 1, worstIsLow = true,
      tooltip = "Frames per second, computed from the real per-frame delta rather than the client's smoothed GetFramerate value." },
    { key = "frame", label = "FRAME TIME", unit = "ms", colorIndex = 2,
      tooltip = "Average time to render one frame in the current sample window. 60 FPS is 16.67 ms, 120 FPS is 8.33 ms. This is the measurement everything else is judged against." },
    { key = "low1", label = "1% LOW", unit = "fps", colorIndex = 1, worstIsLow = true,
      tooltip = "The speed of the worst 1% of frames this session, derived from the frame time histogram. The gap between this and the average is what a stutter actually feels like." },
    { key = "latHome", label = "HOME LATENCY", unit = "ms", colorIndex = 3,
      tooltip = "Latency to the realm server, from GetNetStats. The client only refreshes this roughly every 30 seconds, so it is never a live figure." },
    { key = "latWorld", label = "WORLD LATENCY", unit = "ms", colorIndex = 3,
      tooltip = "Latency to the world server, from GetNetStats. Same 30-second refresh caveat." },
    { key = "cpu", label = "ADDON CPU", unit = "%", colorIndex = 5,
      tooltip = "Share of one CPU core spent inside addon Lua, across every loaded addon. Requires the client's scriptProfile CVar." },
    { key = "memory", label = "ADDON MEMORY", unit = "", colorIndex = 4,
      tooltip = "Lua memory attributed to addons by GetAddOnMemoryUsage. The total Lua heap, which includes the client's own use, is on the Memory page." },
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

function Page:Build(frame)
    local pad = M.padding
    self.cards  = {}
    self.graphs = {}
    self.series = {}

    ------------------------------------------------------------------
    -- Health banner
    ------------------------------------------------------------------
    local banner = UI.Panel(frame, {})
    banner:SetHeight(54)
    banner:SetPoint("TOPLEFT", pad, -pad)
    banner:SetPoint("TOPRIGHT", -pad, -pad)
    self.banner = banner

    banner.accent = banner:CreateTexture(nil, "ARTWORK")
    banner.accent:SetWidth(3)
    banner.accent:SetPoint("TOPLEFT")
    banner.accent:SetPoint("BOTTOMLEFT")

    banner.verdict = UI.Text(banner, "title", "textPrimary")
    banner.verdict:SetPoint("TOPLEFT", 18, -9)

    banner.detail = UI.Text(banner, "small", "textSecondary")
    banner.detail:SetPoint("TOPLEFT", banner.verdict, "BOTTOMLEFT", 0, -4)
    banner.detail:SetPoint("RIGHT", banner, "RIGHT", -240, 0)
    banner.detail:SetJustifyH("LEFT")

    banner.uptime = UI.Text(banner, "numeric", "textSecondary", "RIGHT")
    banner.uptime:SetPoint("TOPRIGHT", -18, -10)
    banner.uptimeLabel = UI.Text(banner, "tiny", "textMuted", "RIGHT")
    banner.uptimeLabel:SetPoint("TOPRIGHT", banner.uptime, "BOTTOMRIGHT", 0, -2)
    banner.uptimeLabel:SetText("SESSION")

    ------------------------------------------------------------------
    -- Profiling notice: prominent, and never reloads on its own
    ------------------------------------------------------------------
    self.profilingNotice = UI.Panel(frame, { color = "panelAlt" })
    self.profilingNotice:SetHeight(52)
    self.profilingNotice:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -10)
    self.profilingNotice:SetPoint("TOPRIGHT", banner, "BOTTOMRIGHT", 0, -10)

    local notice = self.profilingNotice
    notice.accent = notice:CreateTexture(nil, "ARTWORK")
    notice.accent:SetWidth(3)
    notice.accent:SetPoint("TOPLEFT")
    notice.accent:SetPoint("BOTTOMLEFT")
    notice.accent:SetColorTexture(Theme:Tone("warn"))

    notice.title = UI.Text(notice, "heading", "textPrimary")
    notice.title:SetPoint("TOPLEFT", 16, -10)
    notice.title:SetText("Addon CPU profiling is disabled")

    notice.body = UI.Text(notice, "small", "textSecondary")
    notice.body:SetPoint("TOPLEFT", notice.title, "BOTTOMLEFT", 0, -4)
    notice.body:SetPoint("RIGHT", notice, "RIGHT", -300, 0)
    notice.body:SetJustifyH("LEFT")
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

    ------------------------------------------------------------------
    -- Metric row
    ------------------------------------------------------------------
    local row = CreateFrame("Frame", nil, frame)
    row:SetHeight(78)
    self.cardRow = row

    for _, spec in ipairs(CARDS) do
        local card = UI.MetricCard(row, {
            label = spec.label, unit = spec.unit, colorIndex = spec.colorIndex,
            worstIsLow = spec.worstIsLow, tooltip = spec.tooltip,
            height = 78, sparkHeight = 16,
        })
        card:SetPoint("TOP")
        card:SetPoint("BOTTOM")
        self.cards[spec.key] = card
    end

    ------------------------------------------------------------------
    -- Graph grid
    ------------------------------------------------------------------
    local grid = CreateFrame("Frame", nil, frame)
    self.grid = grid

    for i, spec in ipairs(GRAPHS) do
        local graph = UI.Graph(grid, {
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
    end

    ------------------------------------------------------------------
    -- Footer: overhead + incidents
    ------------------------------------------------------------------
    local footer = CreateFrame("Frame", nil, frame)
    -- Tall enough for every breakdown row plus the total. It was 104, which fit
    -- four rows and a total into space for four - the overhead card overflowed
    -- its own card, which is the bug class this addon was reported for.
    footer:SetHeight(OVERHEAD_ROW_HEIGHT * (MAX_OVERHEAD_ROWS + 1) + 40)
    footer:SetPoint("BOTTOMLEFT", pad, pad)
    footer:SetPoint("BOTTOMRIGHT", -pad, pad)
    self.footer = footer

    self.overheadCard = UI.Card(footer, "THIS ADDON'S MEASURED OVERHEAD", {})
    self.overheadCard:SetPoint("TOPLEFT")
    self.overheadCard:SetPoint("BOTTOMLEFT")
    self.overheadCard:SetWidth(380)

    -- One row per breakdown category, plus one for the total.
    self.overheadRows = {}
    for i = 1, MAX_OVERHEAD_ROWS + 1 do
        local statRow = UI.StatRow(self.overheadCard.content, "")
        statRow:SetPoint("TOPLEFT", 0, -(i - 1) * OVERHEAD_ROW_HEIGHT)
        statRow:SetPoint("TOPRIGHT", 0, -(i - 1) * OVERHEAD_ROW_HEIGHT)
        self.overheadRows[i] = statRow
    end

    self.incidentCard = UI.Card(footer, "RECENT INCIDENTS", {})
    self.incidentCard:SetPoint("TOPLEFT", self.overheadCard, "TOPRIGHT", M.cardGap, 0)
    self.incidentCard:SetPoint("BOTTOM")
    self.incidentCard:SetWidth(430)

    self.incidentRows = {}
    for i = 1, 4 do
        local entry = CreateFrame("Button", nil, self.incidentCard.content)
        entry:SetHeight(16)
        entry:SetPoint("TOPLEFT", 0, -(i - 1) * 16)
        entry:SetPoint("TOPRIGHT", 0, -(i - 1) * 16)
        entry.kind = UI.Text(entry, "small", "textPrimary")
        entry.kind:SetPoint("LEFT")
        entry.detail = UI.Text(entry, "numericSm", "textMuted", "RIGHT")
        entry.detail:SetPoint("RIGHT")
        entry:SetScript("OnClick", function()
            UI.MainWindow:ShowPage("incidents")
        end)
        entry:SetScript("OnEnter", function(self)
            if not self.cluster then return end
            UI.Pages.incidents:ShowClusterTooltip(self, self.cluster)
        end)
        entry:SetScript("OnLeave", UI.HideTooltip)
        self.incidentRows[i] = entry
    end

    self.incidentEmpty = UI.Text(self.incidentCard.content, "small", "textMuted")
    self.incidentEmpty:SetPoint("TOPLEFT")
    self.incidentEmpty:SetPoint("RIGHT")
    self.incidentEmpty:SetJustifyH("LEFT")
    UI.Wrap(self.incidentEmpty)

    ------------------------------------------------------------------
    -- Top consumers, filling the remaining footer width
    ------------------------------------------------------------------
    self.topCard = UI.Card(footer, "TOP CONSUMERS", {})
    self.topCard:SetPoint("TOPLEFT", self.incidentCard, "TOPRIGHT", M.cardGap, 0)
    self.topCard:SetPoint("BOTTOMRIGHT")

    self.topRows = {}
    for i = 1, 4 do
        local row = CreateFrame("Button", nil, self.topCard.content)
        row:SetHeight(16)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * 16)
        row:SetWidth(230)
        row.label = UI.Text(row, "small", "textSecondary")
        row.label:SetPoint("LEFT")
        row.value = UI.Text(row, "numericSm", "textPrimary", "RIGHT")
        row.value:SetPoint("RIGHT")
        row:SetScript("OnClick", function(self)
            local record = self.addonName and WTM.Processes:Get(self.addonName)
            if record then UI.AddonDetail:Open(record) end
        end)
        self.topRows[i] = row
    end

    self.topMemRows = {}
    for i = 1, 4 do
        local row = CreateFrame("Button", nil, self.topCard.content)
        row:SetHeight(16)
        row:SetPoint("TOPLEFT", 250, -(i - 1) * 16)
        row:SetWidth(230)
        row.label = UI.Text(row, "small", "textSecondary")
        row.label:SetPoint("LEFT")
        row.value = UI.Text(row, "numericSm", "textPrimary", "RIGHT")
        row.value:SetPoint("RIGHT")
        row:SetScript("OnClick", function(self)
            local record = self.addonName and WTM.Processes:Get(self.addonName)
            if record then UI.AddonDetail:Open(record) end
        end)
        self.topMemRows[i] = row
    end

    self:OnLayout()
end

--------------------------------------------------------------------------

function Page:OnLayout()
    local frame = self.frame
    if not frame then return end
    local pad = M.padding
    local width = (frame:GetWidth() or 900) - pad * 2
    if width <= 0 then return end

    -- The profiling notice only occupies space when it is shown.
    local showNotice = not WTM.CPU.available
    self.profilingNotice:SetShown(showNotice)
    local topAnchor = showNotice and self.profilingNotice or self.banner

    self.cardRow:ClearAllPoints()
    self.cardRow:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -M.cardGap)
    self.cardRow:SetPoint("TOPRIGHT", topAnchor, "BOTTOMRIGHT", 0, -M.cardGap)

    local count = #CARDS
    local cardWidth = (width - M.cardGap * (count - 1)) / count
    local previous
    for _, spec in ipairs(CARDS) do
        local card = self.cards[spec.key]
        card:ClearAllPoints()
        card:SetPoint("TOP")
        card:SetPoint("BOTTOM")
        card:SetWidth(cardWidth)
        if previous then card:SetPoint("LEFT", previous, "RIGHT", M.cardGap, 0)
        else card:SetPoint("LEFT") end
        previous = card
    end

    self.grid:ClearAllPoints()
    self.grid:SetPoint("TOPLEFT", self.cardRow, "BOTTOMLEFT", 0, -M.cardGap)
    self.grid:SetPoint("TOPRIGHT", self.cardRow, "BOTTOMRIGHT", 0, -M.cardGap)
    self.grid:SetPoint("BOTTOM", self.footer, "TOP", 0, -M.cardGap)

    local gridWidth  = width
    local gridHeight = self.grid:GetHeight() or 260
    if gridHeight <= 0 then gridHeight = 260 end

    -- Frame time takes the full first row; the other five share two rows.
    local rowGap = M.cardGap
    local frameHeight = math.max(80, (gridHeight - rowGap * 2) * 0.42)
    local smallHeight = math.max(60, (gridHeight - rowGap * 2 - frameHeight) / 2)
    local smallWidth  = (gridWidth - rowGap * 2) / 3

    local frameGraph = self.graphs[1]
    frameGraph:ClearAllPoints()
    frameGraph:SetPoint("TOPLEFT", self.grid, "TOPLEFT")
    frameGraph:SetPoint("TOPRIGHT", self.grid, "TOPRIGHT")
    frameGraph:SetHeight(frameHeight)

    for i = 2, #self.graphs do
        local index = i - 2
        local column = index % 3
        local rowIndex = math.floor(index / 3)
        local graph = self.graphs[i]
        graph:ClearAllPoints()
        graph:SetSize(smallWidth, smallHeight)
        graph:SetPoint("TOPLEFT", self.grid, "TOPLEFT",
            column * (smallWidth + rowGap),
            -(frameHeight + rowGap + rowIndex * (smallHeight + rowGap)))
    end
end

function Page:OnShow()
    self:OnLayout()
    self:Refresh()
end

--------------------------------------------------------------------------

local clusterScratch, breakdownScratch = {}, {}
local topCPUScratch, topMemScratch = {}, {}

function Page:Refresh()
    if not self.cards then return end

    local ft    = WTM.FrameTime.current
    local stats = WTM.FrameTime:GetSessionStats()
    local net   = WTM.Network.current
    local mem   = WTM.Memory.current
    local cards = self.cards

    ------------------------------------------------------------------
    -- Tiles
    ------------------------------------------------------------------
    cards.fps:SetValue(Fmt.FPS(ft.fps), "",
        ft.fps >= 55 and "ok" or (ft.fps >= 30 and "warn" or "crit"))
    cards.fps:SetSub(("avg %s"):format(Fmt.FPS(stats.avgFPS)))
    cards.fps:SetRing(WTM.FrameTime.history.fps)

    cards.frame:SetValue(("%.1f"):format(ft.avgMs), "ms",
        ft.avgMs <= 20 and "ok" or (ft.avgMs <= 40 and "warn" or "crit"))
    cards.frame:SetSub(("worst %s"):format(Fmt.Ms(stats.maxMs)))
    cards.frame:SetRing(WTM.FrameTime.history.frameMs)

    local low1 = stats.low1
    local ratio = (stats.avgFPS > 0) and (low1 / stats.avgFPS) or 1
    cards.low1:SetValue(Fmt.FPS(low1), "fps",
        ratio >= 0.7 and "ok" or (ratio >= 0.5 and "warn" or "crit"))
    cards.low1:SetSub(("0.1%% low %s"):format(Fmt.FPS(stats.low01)))
    cards.low1:SetRing(WTM.FrameTime.history.fps)

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
        cards.cpu:SetSub(("across %d loaded addons"):format(WTM.Processes:CountLoaded()))
    else
        cards.cpu:SetUnavailable(WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
    end

    if WTM.Caps:Has("addonMemory") then
        cards.memory:SetAvailable()
        cards.memory:SetValue(Fmt.Memory(mem.addonSumKB), "")
        cards.memory:SetSub(("heap %s"):format(Fmt.Memory(mem.luaKB)))
        cards.memory:SetRing(WTM.Memory.history.lua)
    else
        cards.memory:SetUnavailable(C.TXT_UNAVAILABLE_CLIENT)
    end

    if WTM.Events:GetMode() ~= "OFF" and WTM.Events.available then
        cards.events:SetAvailable()
        cards.events:SetValue(Fmt.Comma(math.floor(WTM.Events.current.perSecond)), "")
        cards.events:SetSub(("%d distinct, %s mode")
            :format(WTM.Events:GetDistinctCount(), WTM.Events:GetMode():lower()))
        cards.events:SetRing(WTM.Events.history)
    else
        cards.events:SetUnavailable(WTM.Events.available
            and "Event monitoring is off - enable it in Settings"
            or (WTM.Events.reason or C.TXT_UNAVAILABLE_CLIENT))
    end

    for _, card in pairs(cards) do card:Refresh() end

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
    local showNotice = not WTM.CPU.available
    if showNotice ~= self.profilingNotice:IsShown() then
        self:OnLayout()
    end
    if showNotice then
        local canToggle = WTM.Caps:Has("toggleProfiling")
        self.profilingNotice.enable:SetEnabledState(canToggle,
            WTM.Caps:Note("toggleProfiling"))
        if WTM.Caps.pendingProfilingReload then
            self.profilingNotice.title:SetText("CPU profiling enabled - reload to apply")
            self.profilingNotice.body:SetText("The scriptProfile CVar is set. Per-addon CPU starts being measured after a reload; nothing reloads until you click.")
        end
    end

    ------------------------------------------------------------------
    -- Graphs
    ------------------------------------------------------------------
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

    local redraw = UI.MainWindow:ShouldRedrawGraphs()
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

    ------------------------------------------------------------------
    -- Overhead breakdown
    ------------------------------------------------------------------
    -- The categories are laid out first, then the total on the row after the
    -- last one used. The total is not pinned to a fixed row: doing that meant
    -- adding a category silently pushed one off the card.
    local breakdown = WTM.Overhead:GetBreakdown(breakdownScratch)
    local shown = math.min(#breakdown, MAX_OVERHEAD_ROWS)

    for i = 1, shown do
        local entry, statRow = breakdown[i], self.overheadRows[i]
        statRow:Show()
        statRow:SetLabel(entry.label)
        if entry.measured then
            statRow:Set(("%.3f ms/s"):format(entry.ms))
        else
            statRow:Set("not measured", "muted")
        end
        statRow.tooltip = entry.note
    end

    local totalRow = self.overheadRows[shown + 1]
    if totalRow then
        totalRow:Show()
        totalRow:SetLabel("|cffe6e9efTotal measured|r")
        totalRow:Set(("%.3f ms/s  (%.2f%% of a frame)")
            :format(WTM.Overhead.current.totalMsPerSec,
                    WTM.Overhead:GetFrameBudgetPercent()),
            WTM.Overhead.current.verdict == "ok" and "ok" or "warn")
        -- The categories reconcile against this number; say by how much rather
        -- than leaving the reader to add up the column.
        local sum, total, delta = WTM.Overhead:ReconcileBreakdown()
        totalRow.tooltip = ("Categories sum to %.3f ms/s against a measured total of %.3f ms/s (difference %.3f)."):
            format(sum, total, delta)
    end

    for i = shown + 2, #self.overheadRows do self.overheadRows[i]:Hide() end

    ------------------------------------------------------------------
    -- Top consumers
    ------------------------------------------------------------------
    local topCPU = WTM.CPU:GetTopConsumers(topCPUScratch, #self.topRows)
    for i, row in ipairs(self.topRows) do
        local entry = topCPU[i]
        row:SetShown(entry ~= nil or i == 1)
        row.addonName = entry and entry.name
        if entry then
            row.label:SetText("CPU  " .. Fmt.Truncate(entry.title, 18))
            row.value:SetText(("%.2f %%"):format(entry.pct))
            row.value:SetTextColor(Theme:Tone(
                entry.pct >= C.HIGH_CPU_PCT and "crit"
                or (entry.pct >= C.ELEVATED_CPU_PCT and "warn" or nil)))
            if entry.pct < C.ELEVATED_CPU_PCT then row.value:SetTextColor(T("textPrimary")) end
        elseif i == 1 then
            row.label:SetText(WTM.CPU.available
                and "No measurable addon CPU yet" or "CPU: profiling off")
            row.value:SetText("")
        end
    end

    local topMem = WTM.Memory:GetTopConsumers(topMemScratch, #self.topMemRows)
    for i, row in ipairs(self.topMemRows) do
        local entry = topMem[i]
        row:SetShown(entry ~= nil or i == 1)
        row.addonName = entry and entry.name
        if entry then
            row.label:SetText("MEM  " .. Fmt.Truncate(entry.title, 18))
            row.value:SetText(Fmt.Memory(entry.memKB))
            row.value:SetTextColor(T("textPrimary"))
        elseif i == 1 then
            row.label:SetText("Waiting for the first memory scan")
            row.value:SetText("")
        end
    end

    ------------------------------------------------------------------
    -- Recent incidents (clusters)
    ------------------------------------------------------------------
    local clusters = WTM.SpikeDetector:GetClusters(clusterScratch, #self.incidentRows)
    self.incidentEmpty:SetShown(#clusters == 0)
    if #clusters == 0 then
        self.incidentEmpty:SetText(WTM.SpikeDetector.suppressed > 0
            and ("No stutter recorded. %s"):format(WTM.Suppression:Describe() or "")
            or "No frame time spikes recorded yet.")
    end
    for i, entry in ipairs(self.incidentRows) do
        local cluster = clusters[i]
        entry:SetShown(cluster ~= nil)
        entry.cluster = cluster
        if cluster then
            entry.kind:SetText(("%s%s"):format(
                cluster.simulated and "|cffd29922SIMULATED|r " or "", cluster.label))
            entry.kind:SetTextColor(Theme:Tone(
                (cluster.kind == "freeze" or cluster.kind == "heavy") and "crit" or "warn"))
            entry.detail:SetText(("peak %s  %d frame%s  %s")
                :format(Fmt.Ms(cluster.peakMs), cluster.frames,
                        cluster.frames == 1 and "" or "s",
                        Fmt.Ago(GetTime() - cluster.endedAt)))
        end
    end
end
