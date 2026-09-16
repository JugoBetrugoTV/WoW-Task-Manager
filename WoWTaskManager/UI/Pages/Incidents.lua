--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Incidents.lua

    Clickable stutter incidents and their full diagnostic record.

    The single most important thing on this page is how addon CPU is worded.

    GetAddOnCPUUsage is CUMULATIVE and is read on an interval. If the sampler
    ran 1.4 seconds apart and an addon's counter moved by 31 ms, the only true
    statement is:

        "31 ms of CPU within a 1.4 s observation window"

    NOT:

        "31 ms of this 84 ms frame"

    The API cannot attribute CPU to a single frame, so this page never implies
    that it can. Every CPU figure here names its window, and the window bounds
    are shown next to the numbers rather than buried in a tooltip.

    Likewise the correlation figure is a phi coefficient with its sample count,
    never a percentage of blame.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("incidents", {})

local clusterList = {}

--------------------------------------------------------------------------

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Top: a visual strip across every recorded cluster, so a run of bad
    -- ones reads as a run at a glance, before scrolling the list below.
    -- Severity sets both the tick's colour and its height, the same
    -- encoding the graph engine's own incident markers use.
    ------------------------------------------------------------------
    self.timelineStrip = UI.Panel(frame, {})
    self.timelineStrip:SetHeight(56)
    self.timelineStrip:SetPoint("TOPLEFT", pad, -pad)
    self.timelineStrip:SetPoint("TOPRIGHT", -pad, -pad)

    self.timelineTitle = UI.Text(self.timelineStrip, "heading", "textSecondary")
    self.timelineTitle:SetPoint("TOPLEFT", 10, -6)
    self.timelineTitle:SetText("INCIDENT TIMELINE")

    self.timelineRange = UI.Text(self.timelineStrip, "tiny", "textMuted", "RIGHT")
    self.timelineRange:SetPoint("TOPRIGHT", -8, -7)

    local timelinePlot = CreateFrame("Frame", nil, self.timelineStrip)
    timelinePlot:SetPoint("TOPLEFT", 10, -22)
    timelinePlot:SetPoint("BOTTOMRIGHT", -10, 8)
    timelinePlot:SetClipsChildren(true)
    self.timelinePlot = timelinePlot

    self.timelineBase = timelinePlot:CreateTexture(nil, "BACKGROUND")
    self.timelineBase:SetPoint("BOTTOMLEFT")
    self.timelineBase:SetPoint("BOTTOMRIGHT")
    self.timelineBase:SetHeight(1)
    self.timelineBase:SetColorTexture(T("borderSubtle"))

    -- One small clickable button per cluster, not a plain texture: the strip
    -- is only useful if a spotted cluster can be jumped to and hovered for
    -- its summary, same as clicking the row it stands in for below.
    self.timelinePool = WTM.RegionPool.New(timelinePlot,
        function(p)
            local btn = CreateFrame("Button", nil, p)
            btn:SetWidth(4)
            btn.tex = btn:CreateTexture(nil, "ARTWORK")
            btn.tex:SetAllPoints()
            btn:SetScript("OnEnter", function(self)
                if self.cluster then Page:ShowClusterTooltip(self, self.cluster) end
            end)
            btn:SetScript("OnLeave", UI.HideTooltip)
            btn:SetScript("OnClick", function(self)
                if self.cluster then Page:Select(self.cluster) end
            end)
            return btn
        end,
        function(btn) btn:ClearAllPoints() btn.cluster = nil end)

    self.timelineEmpty = UI.Text(timelinePlot, "tiny", "textMuted")
    self.timelineEmpty:SetPoint("LEFT")
    self.timelineEmpty:SetText("No stutter recorded yet.")
    self.timelineEmpty:Hide()

    ------------------------------------------------------------------
    -- Left: cluster list
    ------------------------------------------------------------------
    self.listCard = UI.Card(frame, "STUTTER CLUSTERS", {})
    self.listCard:SetWidth(UI.SideColumnWidth(frame:GetWidth()))
    self.listCard:SetPoint("TOPLEFT", self.timelineStrip, "BOTTOMLEFT", 0, -M.cardGap)
    self.listCard:SetPoint("BOTTOMLEFT", pad, pad)

    self.list = UI.ScrollList(self.listCard.content, 50,
        function(parent)
            local row = CreateFrame("Button", nil, parent)
            row.accent = row:CreateTexture(nil, "ARTWORK")
            row.accent:SetWidth(2)
            row.accent:SetPoint("TOPLEFT", 0, -4)
            row.accent:SetPoint("BOTTOMLEFT", 0, 4)

            row.title = UI.Text(row, "body", "textPrimary")
            row.title:SetPoint("TOPLEFT", 10, -6)

            row.detail = UI.Text(row, "small", "textMuted")
            row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)

            row.peak = UI.Text(row, "numeric", "textPrimary", "RIGHT")
            row.peak:SetPoint("TOPRIGHT", -6, -6)

            row.ago = UI.Text(row, "numericSm", "textMuted", "RIGHT")
            row.ago:SetPoint("TOPRIGHT", row.peak, "BOTTOMRIGHT", 0, -3)
            return row
        end,
        function(row, cluster)
            local tone = (cluster.kind == "freeze" or cluster.kind == "heavy") and "crit" or "warn"
            row.accent:SetColorTexture(Theme:Tone(tone))
            row.title:SetText(("%s%s"):format(
                cluster.simulated and "|cffd29922SIMULATED|r " or "", cluster.label))
            row.title:SetTextColor(Theme:Tone(tone))
            row.detail:SetText(("%d frame%s over %.1fs%s")
                :format(cluster.frames, cluster.frames == 1 and "" or "s",
                        cluster.duration or 0,
                        cluster.closed and "" or "  (open)"))
            row.peak:SetText(Fmt.Ms(cluster.peakMs))
            row.ago:SetText(Fmt.Ago(GetTime() - cluster.endedAt))
        end,
        function(cluster) Page:Select(cluster) end)
    self.list:SetAllPoints(self.listCard.content)

    self.listEmpty = UI.Text(self.listCard.content, "small", "textMuted")
    self.listEmpty:SetPoint("TOPLEFT")
    self.listEmpty:SetPoint("RIGHT")
    self.listEmpty:SetJustifyH("LEFT")
    UI.Wrap(self.listEmpty)

    ------------------------------------------------------------------
    -- Right: detail
    ------------------------------------------------------------------
    local detail = CreateFrame("Frame", nil, frame)
    detail:SetPoint("TOPLEFT", self.listCard, "TOPRIGHT", M.cardGap, 0)
    detail:SetPoint("BOTTOMRIGHT", -pad, pad)
    self.detail = detail

    local header = UI.Panel(detail, {})
    header:SetHeight(70)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    self.header = header

    header.accent = header:CreateTexture(nil, "ARTWORK")
    header.accent:SetWidth(3)
    header.accent:SetPoint("TOPLEFT")
    header.accent:SetPoint("BOTTOMLEFT")

    header.title = UI.Text(header, "title", "textPrimary")
    header.title:SetPoint("TOPLEFT", 18, -10)

    header.sub = UI.Text(header, "small", "textSecondary")
    header.sub:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -4)
    header.sub:SetPoint("RIGHT", header, "RIGHT", -220, 0)
    header.sub:SetJustifyH("LEFT")

    header.peak = UI.Text(header, "metric", "textPrimary", "RIGHT")
    header.peak:SetPoint("TOPRIGHT", -18, -10)
    header.peakLabel = UI.Text(header, "tiny", "textMuted", "RIGHT")
    header.peakLabel:SetPoint("TOPRIGHT", header.peak, "BOTTOMRIGHT", 0, -2)
    header.peakLabel:SetText("PEAK FRAME TIME")

    ------------------------------------------------------------------
    -- Incident graph (from the flight recorder)
    ------------------------------------------------------------------
    self.graph = UI.Graph(detail, {
        title = "FRAME TIME AROUND THE SPIKE  (flight recorder)",
        valueFormat = function(v) return ("%.0f ms"):format(v) end,
    })
    self.graph:SetHeight(150)
    self.graph:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -M.cardGap)
    self.graph:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -M.cardGap)
    self.graphValues, self.graphTimes = {}, {}

    self.coverage = UI.Text(detail, "tiny", "textMuted")
    self.coverage:SetPoint("TOPLEFT", self.graph, "BOTTOMLEFT", 2, -3)
    self.coverage:SetPoint("RIGHT", self.graph, "RIGHT", -2, 0)
    self.coverage:SetJustifyH("LEFT")
    self.coverage:SetHeight(24)
    UI.Wrap(self.coverage, 2)

    ------------------------------------------------------------------
    -- Fact grid + CPU table
    ------------------------------------------------------------------
    local body = CreateFrame("Frame", nil, detail)
    body:SetPoint("TOPLEFT", self.coverage, "BOTTOMLEFT", -2, -M.paddingSmall)
    body:SetPoint("BOTTOMRIGHT")
    self.body = body

    self.factsCard = UI.Card(body, "INCIDENT", {})
    self.factsCard:SetWidth(300)
    self.factsCard:SetPoint("TOPLEFT")
    self.factsCard:SetPoint("BOTTOMLEFT")

    -- Fifteen facts in a card that stretches to whatever the panel leaves it.
    -- At the minimum window size that is about 206 px, which fits eleven of
    -- them; the other four were clipped off the bottom with nothing to say
    -- they existed. They scroll now, so the height of the window decides how
    -- many are visible at once rather than how many exist.
    local factScroll, factCanvas = UI.ScrollCanvas(self.factsCard.content, { step = 48 })
    self.factScroll = factScroll

    self.factRows = {}
    local FACTS = {
        "Timestamp", "Severity", "Frame time", "FPS equivalent", "Rolling baseline",
        "Home latency", "World latency", "Event rate", "Event storms",
        "Lua memory", "Memory growth", "Combat", "Zone", "Instance", "Group",
    }
    local FACT_PITCH, FACT_HEIGHT = 16, 18
    for i, label in ipairs(FACTS) do
        local row = UI.StatRow(factCanvas, label)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * FACT_PITCH)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * FACT_PITCH)
        self.factRows[label] = row
    end
    factCanvas:SetHeight((#FACTS - 1) * FACT_PITCH + FACT_HEIGHT)

    self.cpuCard = UI.Card(body, "ADDON CPU WITHIN THE OBSERVATION WINDOW", {})
    self.cpuCard:SetPoint("TOPLEFT", self.factsCard, "TOPRIGHT", M.cardGap, 0)
    self.cpuCard:SetPoint("BOTTOMRIGHT")

    self.windowText = UI.Text(self.cpuCard.content, "small", "textSecondary")
    self.windowText:SetPoint("TOPLEFT")
    self.windowText:SetPoint("RIGHT")
    self.windowText:SetJustifyH("LEFT")
    -- An explanation rather than a label: clipping it to one line would cut off
    -- the half that says what the number means.
    self.windowText:SetHeight(28)
    UI.Wrap(self.windowText, 2)

    self.cpuRows = {}
    for i = 1, 5 do
        local row = CreateFrame("Button", nil, self.cpuCard.content)
        row:SetHeight(17)
        row:SetPoint("TOPLEFT", 0, -22 - (i - 1) * 17)
        row:SetPoint("TOPRIGHT", 0, -22 - (i - 1) * 17)
        -- Value first, then the name bounded against it: anchored to one edge
        -- each, a long addon name and a long measurement grow towards each
        -- other and overlap in the middle.
        row.value = UI.Text(row, "numericSm", "textSecondary", "RIGHT")
        row.value:SetPoint("RIGHT")
        row.value:SetPoint("LEFT", row, "CENTER", -20, 0)
        row.name = UI.Text(row, "small", "textPrimary")
        row.name:SetPoint("LEFT")
        row.name:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
        row:SetScript("OnClick", function(self)
            if not self.entryName then return end
            local record = WTM.Processes:Get(self.entryName)
            if record then UI.AddonDetail:Open(record) end
        end)
        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            UI.TooltipClear(self.entry.title or self.entry.name)
            UI.TooltipLine("CPU within the window", Fmt.Ms(self.entry.deltaMs))
            UI.TooltipLine("Window length", ("%.2f s"):format(self.windowSeconds or 0))
            UI.TooltipLine("Vs its own average", ("%+.2f %%"):format(self.entry.excess))
            UI.TooltipLine("", "")
            UI.TooltipLine(C.TXT_CPU_WINDOW_NOTE, nil, "muted")
            UI.TooltipShow(self)
        end)
        row:SetScript("OnLeave", UI.HideTooltip)
        self.cpuRows[i] = row
    end

    self.cpuNote = UI.Text(self.cpuCard.content, "tiny", "textMuted")
    self.cpuNote:SetPoint("BOTTOMLEFT")
    self.cpuNote:SetPoint("BOTTOMRIGHT")
    self.cpuNote:SetJustifyH("LEFT")
    UI.Wrap(self.cpuNote)

    self.emptyState = UI.EmptyState(detail, "No incidents recorded yet")
    self.emptyState:SetAllPoints(detail)
end

--------------------------------------------------------------------------

--- The side column is a share of the page, not a fixed number of pixels, so
--- it has to be recomputed whenever the window changes size.
function Page:OnLayout()
    if not self.listCard or not self.frame then return end
    self.listCard:SetWidth(UI.SideColumnWidth(self.frame:GetWidth()))
end

function Page:OnShow() self:OnLayout() self:Refresh() end

--- The name other pages use when they hand an incident over. Kept distinct
--- from Select so a rename here cannot silently break a cross-page jump.
function Page:SelectCluster(cluster)
    self:Select(cluster)
end

function Page:Select(cluster)
    self.selected = cluster
    self:RefreshDetail()
end

--- Shared with the dashboard's incident list.
function Page:ShowClusterTooltip(anchor, cluster)
    UI.TooltipClear(("%s%s"):format(
        cluster.simulated and "SIMULATED " or "", cluster.label))
    UI.TooltipLine("Peak frame time", Fmt.Ms(cluster.peakMs))
    UI.TooltipLine("Affected frames", tostring(cluster.frames))
    UI.TooltipLine("Duration", ("%.2f s"):format(cluster.duration or 0))
    UI.TooltipLine("When", Fmt.Ago(GetTime() - cluster.endedAt))
    if cluster.context and cluster.context.zone then
        UI.TooltipLine("Zone", cluster.context.zone)
    end
    UI.TooltipLine("", "")
    UI.TooltipLine("Click to open the incident", nil, "muted")
    UI.TooltipShow(anchor)
end

--- Redraws the strip of clickable ticks above the list. One tick per cluster
--- in `clusterList`, positioned by time and sized/coloured by severity - the
--- same encoding the graph engine's own incident markers use, so a reader
--- who has seen one already knows how to read the other.
function Page:RefreshTimelineStrip()
    local plot = self.timelinePlot
    if not plot then return end
    self.timelinePool:ReleaseAll()

    local count = #clusterList
    if count == 0 then
        self.timelineEmpty:Show()
        self.timelineRange:SetText("")
        return
    end
    self.timelineEmpty:Hide()

    local width = plot:GetWidth() or 0
    if width < 8 then return end

    local now = GetTime()
    local oldest = now
    for i = 1, count do
        local startedAt = clusterList[i].startedAt
        if startedAt and startedAt < oldest then oldest = startedAt end
    end
    local span = math.max(1, now - oldest)

    for i = 1, count do
        local cluster = clusterList[i]
        if cluster.startedAt then
            local fraction = (cluster.startedAt - oldest) / span
            fraction = math.max(0, math.min(1, fraction))
            local order = C.SPIKE_ORDER[cluster.kind] or 1
            local tone = (cluster.kind == "freeze" or cluster.kind == "heavy") and "crit" or "warn"

            local tick = self.timelinePool:Acquire()
            tick:SetHeight(10 + order * 6)
            tick.tex:SetColorTexture(Theme:Tone(tone, cluster.closed and 0.85 or 1))
            tick:ClearAllPoints()
            tick:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", fraction * math.max(0, width - 4), 0)
            tick.cluster = cluster
        end
    end

    self.timelineRange:SetText(("%s ago  -  now"):format(Fmt.Duration(span)))
end

--------------------------------------------------------------------------

function Page:Refresh()
    if not self.list then return end

    WTM.SpikeDetector:GetClusters(clusterList, 60)
    self.list:SetData(clusterList)
    self:RefreshTimelineStrip()

    local empty = #clusterList == 0
    self.listEmpty:SetShown(empty)
    self.list:SetShown(not empty)
    if empty then
        local suppressed = WTM.Suppression:Describe()
        self.listEmpty:SetText(suppressed
            and ("No stutter recorded yet.\n\n" .. suppressed)
            or "No stutter recorded yet.\n\nSpikes appear here as clusters: several bad frames close together are one incident, with the peak, the duration and how many frames were affected.")
    end

    if not self.selected and clusterList[1] then
        self.selected = clusterList[1]
    end
    self:RefreshDetail()
end

local cpuScratch = {}

function Page:RefreshDetail()
    local cluster = self.selected
    local show = cluster ~= nil

    self.emptyState:SetShown(not show)
    self.header:SetShown(show)
    self.graph:SetShown(show)
    self.coverage:SetShown(show)
    self.body:SetShown(show)
    if not show then return end

    local spike = cluster.peakSpike or (cluster.spikes and cluster.spikes[1])
    if not spike then return end

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------
    local tone = (cluster.kind == "freeze" or cluster.kind == "heavy") and "crit" or "warn"
    self.header.accent:SetColorTexture(Theme:Tone(tone))
    self.header.title:SetText(("%s%s"):format(
        cluster.simulated and "|cffd29922SIMULATED  |r" or "", cluster.label))
    self.header.title:SetTextColor(Theme:Tone(tone))
    self.header.peak:SetText(Fmt.Ms(cluster.peakMs))

    self.header.sub:SetText(UI.FitText(self.header.sub,
        ("%s  -  %d affected frame%s over %.2f s  -  %s")
        :format(Fmt.Clock(cluster.startedAt, WTM.state.sessionEpoch, WTM.state.sessionStart),
                cluster.frames, cluster.frames == 1 and "" or "s",
                cluster.duration or 0,
                cluster.closed and "closed" or "still open")))

    ------------------------------------------------------------------
    -- Flight recorder graph
    ------------------------------------------------------------------
    local incident = spike.incidentId and WTM.FlightRecorder:GetIncident(spike.incidentId)
    local values, times = self.graphValues, self.graphTimes
    for i = #values, 1, -1 do values[i] = nil end
    for i = #times, 1, -1 do times[i] = nil end

    if incident then
        for i = 1, #incident.samples do
            values[i] = incident.samples[i].frameMaxMs
            times[i]  = incident.samples[i].t
        end
        self.graph:SetSeries(1, values, times, { label = "frame time", colorIndex = 2 })
        self.graph:SetTimeRange(times[1] or 0, times[#times] or 0)
        self.graph:SetTitle("FRAME TIME AROUND THE SPIKE  (flight recorder)")
        self.coverage:SetText(WTM.FlightRecorder:DescribeCoverage(incident))
    else
        self.graph:ClearSeries()
        self.graph:SetTitle("FRAME TIME AROUND THE SPIKE  -  no flight recorder capture")
        self.coverage:SetText(WTM.db.profile.flightRecorder.enabled
            and ("This spike was below the capture threshold (%s and above are captured). Change it in Settings.")
                :format(WTM.db.profile.spikes.captureFrom)
            or "The flight recorder is disabled in Settings, so no capture was taken.")
    end
    self.graph.dirty = true
    self.graph:Draw()

    ------------------------------------------------------------------
    -- Facts
    ------------------------------------------------------------------
    local function fact(key, value, factTone)
        local row = self.factRows[key]
        if row then row:Set(value, factTone) end
    end

    local context = spike.context or {}
    fact("Timestamp",       Fmt.Clock(spike.t, WTM.state.sessionEpoch, WTM.state.sessionStart))
    fact("Severity",        spike.label, tone)
    fact("Frame time",      Fmt.Ms(spike.frameMs), tone)
    fact("FPS equivalent",  Fmt.FPS(spike.fps))
    fact("Rolling baseline", Fmt.Ms(spike.baselineMs))

    if WTM.Caps:Has("latency") then
        local staleSuffix = spike.latStale and (" (%s old)"):format(Fmt.Duration(spike.latAgeSec or 0)) or ""
        fact("Home latency",  ("%d ms%s"):format(spike.latHome, staleSuffix),
             spike.latStale and "muted" or nil)
        fact("World latency", ("%d ms%s"):format(spike.latWorld, staleSuffix),
             spike.latStale and "muted" or nil)
    else
        fact("Home latency",  C.TXT_UNAVAILABLE_CLIENT, "muted")
        fact("World latency", C.TXT_UNAVAILABLE_CLIENT, "muted")
    end

    fact("Event rate", Fmt.Rate(spike.eventRate))
    local storms = spike.storms or {}
    if #storms > 0 then
        fact("Event storms", ("%s at %s"):format(storms[1].event, Fmt.Rate(storms[1].peakRate)), "warn")
    else
        fact("Event storms", "none active", "muted")
    end

    fact("Lua memory", Fmt.Memory(spike.memoryTotalKB or spike.luaKB))
    fact("Memory growth", ("%s/min"):format(Fmt.Memory(spike.memoryGrowthKBPerMin or 0)))

    fact("Combat", context.combat and "in combat" or "out of combat",
         context.combat and "warn" or "muted")
    fact("Zone", context.zone or "unknown")
    fact("Instance", (context.instanceType and context.instanceType ~= "none")
        and (context.instanceName or context.instanceType) or "open world")
    fact("Group", (context.groupSize or 0) > 1
        and ("%d players"):format(context.groupSize) or "solo")

    ------------------------------------------------------------------
    -- CPU, always framed by its observation window
    ------------------------------------------------------------------
    if spike.cpuUnavailable then
        self.windowText:SetText("|cffd29922" .. spike.cpuUnavailable .. "|r")
        for _, row in ipairs(self.cpuRows) do row:Hide() end
        self.cpuNote:SetText("Without the client's scriptProfile CVar there is no per-addon CPU data for this incident. Nothing is estimated in its place.")
        return
    end

    local window = spike.cpuWindow
    local seconds = window and window.seconds or 0
    self.windowText:SetText(("CPU sampled over a |cffe6e9ef%.2f s|r window ending at the spike.")
        :format(seconds))

    local entries = spike.cpu or {}
    for i, row in ipairs(self.cpuRows) do
        local entry = entries[i]
        row:SetShown(entry ~= nil)
        row.entry = entry
        row.entryName = entry and entry.name
        row.windowSeconds = seconds
        if entry then
            row.name:SetText(Fmt.Truncate(entry.title or entry.name, 26))
            -- The wording that matters: CPU *within the window*, never
            -- "of this frame".
            row.value:SetText(("%s within %.1f s  (%+.1f%%)")
                :format(Fmt.Ms(entry.deltaMs), seconds, entry.excess))
            row.value:SetTextColor(Theme:Tone(entry.excess > 1 and "warn" or "muted"))
        end
    end

    if #entries == 0 then
        self.cpuNote:SetText("No addon was above its own average CPU in this window. That is a real result: it points at work outside addon Lua - the engine, asset streaming, or the server.")
    else
        self.cpuNote:SetText(C.TXT_CPU_WINDOW_NOTE)
    end
end
