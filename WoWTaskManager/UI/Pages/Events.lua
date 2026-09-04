--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Events.lua

    What the client is firing, how often, and what it costs.

    The "listeners" column is the one place in the addon where a number is
    openly heuristic: WoW offers no API that maps an event to the addons
    handling it.  What we can do is walk named frames, ask each one
    IsEventRegistered (which is exact), and match the frame name against the
    list of loaded addons (which is not).  The page says so, shows how many
    frames could not be attributed, and never presents the result as a
    measurement.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("events", {})

local viewData = {}
local listenerScratch = {}

local COLUMNS = {
    { key = "event", title = "Event", flex = 3, sort = "name",
      value = function(row) return row.event end,
      tooltip = "Every event the client fired, observed through a frame with RegisterAllEvents." },
    { key = "rate", title = "Calls/s", width = 84, justify = "RIGHT", sort = "rate",
      value = function(row) return ("%.1f"):format(row.rate) end,
      tone = function(row)
          if row.baseline > 0 and row.rate > row.baseline * WTM.db.profile.events.stormMultiplier then
              return "crit"
          end
          if row.rate > 100 then return "warn" end
          return nil
      end,
      bar = function(row) return row.rate / 400, "accent" end,
      tooltip = "Calls per second in the last sampling window." },
    { key = "baseline", title = "Normal/s", width = 84, justify = "RIGHT",
      value = function(row) return ("%.1f"):format(row.baseline) end,
      tone = function() return "muted" end,
      tooltip = "Rolling average rate for this event, used as the reference for storm detection." },
    { key = "peak", title = "Peak/s", width = 76, justify = "RIGHT", sort = "peak",
      value = function(row) return ("%.0f"):format(row.peak) end,
      tooltip = "Highest rate seen this session." },
    { key = "total", title = "Total", width = 90, justify = "RIGHT", sort = "total",
      value = function(row) return Fmt.Comma(row.total) end,
      tooltip = "Total occurrences since the session started." },
    { key = "cpu", title = "CPU ms", width = 78, justify = "RIGHT",
      value = function(row)
          -- In DETAILED mode this comes from the cached per-event sample; in
          -- NORMAL mode it is read on demand. Either way it is total handler
          -- time across ALL addons, which the API does not break down further.
          local ms = WTM.Events:GetEventCPU(row.event)
          if not ms then ms = WTM.CPU:GetEventCPU(row.event) end
          return ms and ("%.0f"):format(ms) or "-"
      end,
      tone = function() return WTM.CPU.available and nil or "muted" end,
      tooltip = "Total handler time across ALL addons for this event, from GetEventCPUUsage. Requires the scriptProfile CVar. This is not per-addon - the API does not break it down." },
    { key = "last", title = "Last", width = 72, justify = "RIGHT", sort = "last",
      value = function(row) return row.lastAgo and Fmt.Ago(row.lastAgo) or "-" end,
      tone = function() return "muted" end },
}

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Toolbar
    ------------------------------------------------------------------
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(28)
    toolbar:SetPoint("TOPLEFT", pad, -pad)
    toolbar:SetPoint("TOPRIGHT", -pad, -pad)
    self.toolbar = toolbar

    self.search = UI.SearchBox(toolbar, "Filter events", function(text)
        self.filter = text
        self:Rebuild()
    end)
    self.search:SetPoint("LEFT")
    self.search:SetWidth(220)

    self.attributeButton = UI.Button(toolbar, "Attribute to addons", function(button)
        local ok, err = WTM.Processes:ScanFrames(true)
        if not ok then WTM:Print(err) end
        self.showListeners = true
        button:SetSelected(true)
        self:Rebuild()
    end, { height = 24 })
    self.attributeButton:SetPoint("LEFT", self.search, "RIGHT", 8, 0)
    self.attributeButton.tooltip =
        "Scans every named frame and records which of the busiest events it listens for. The event registration itself is exact; matching a frame to an addon is a name-prefix heuristic and anonymous frames cannot be matched at all."

    -- Mode buttons rather than a pause toggle, so this page and Settings
    -- cannot disagree about what the event monitor is doing.
    self.modeButtons = {}
    local previous = self.attributeButton
    for _, mode in ipairs(C.EVENT_MODES) do
        local button = UI.Button(toolbar, mode:sub(1, 1) .. mode:sub(2):lower(), function()
            local actual, err = WTM.Events:SetMode(mode)
            if err then WTM:Print(("Event monitoring: %s"):format(err)) end
            Page:UpdateModeButtons()
            Page:Rebuild()
        end, { height = 24, minWidth = 64, style = "small" })
        button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        button.mode = mode
        button.tooltip = C.EVENT_MODE_LABELS[mode]
        self.modeButtons[#self.modeButtons + 1] = button
        previous = button
    end
    self.modeAnchor = previous

    self.summary = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.summary:SetPoint("RIGHT")
    self.summary:SetPoint("LEFT", self.modeAnchor, "RIGHT", 12, 0)

    ------------------------------------------------------------------
    -- Rate summary and the events-per-second graph
    ------------------------------------------------------------------
    local rateRow = CreateFrame("Frame", nil, frame)
    -- Tall enough for the cards inside it. This was 120, and the storm card
    -- needs 124, so its fourth row was clipped away.
    rateRow:SetHeight(124)
    rateRow:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -10)
    rateRow:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -10)
    self.rateRow = rateRow

    self.rateCard = UI.StatCard(rateRow, "EVENT RATE", {
        "Now", "Average", "Peak", "Total", "Distinct",
    })
    self.rateCard:SetPoint("TOPLEFT")
    self.rateCard:SetPoint("BOTTOMLEFT")
    self.rateCard:SetWidth(230)

    self.stormCard = UI.TopList(rateRow, "EVENT STORMS", { rows = 4, wideValue = true })
    self.stormCard:SetPoint("TOPRIGHT")
    self.stormCard:SetPoint("BOTTOMRIGHT")
    self.stormCard:SetWidth(280)

    self.rateGraph = UI.Graph(frame, {
        title = "EVENTS / SEC",
        valueFormat = function(v) return Fmt.Rate(v) end,
    })
    self.rateGraph:SetPoint("TOPLEFT", self.rateCard, "TOPRIGHT", M.cardGap, 0)
    self.rateGraph:SetPoint("BOTTOMRIGHT", self.stormCard, "BOTTOMLEFT", -M.cardGap, 0)
    self.rateSeries = { values = {}, times = {} }

    ------------------------------------------------------------------
    -- Storm banner
    ------------------------------------------------------------------
    self.storm = UI.NoticePanel(frame, "Event storm", "", nil, nil, "crit")
    self.storm:SetPoint("TOPLEFT", rateRow, "BOTTOMLEFT", 0, -10)
    self.storm:SetPoint("TOPRIGHT", rateRow, "BOTTOMRIGHT", 0, -10)
    self.storm:Hide()

    ------------------------------------------------------------------
    -- Table + listener panel
    ------------------------------------------------------------------
    self.table = UI.Table(frame, COLUMNS, {
        defaultSort = "rate",
        emptyMessage = "No events observed yet",
        onSort = function(key, ascending)
            self.sortKey, self.sortAscending = key, ascending
            self:Rebuild()
        end,
        onRowClick = function(row) self:SelectEvent(row.event) end,
        onRowEnter = function(rowFrame, row) self:ShowRowTooltip(rowFrame, row) end,
    })

    self.listeners = UI.Card(frame, "LISTENERS (HEURISTIC)", {})
    self.listeners:SetWidth(250)
    self.listenerRows = {}
    for i = 1, 12 do
        local statRow = UI.StatRow(self.listeners.content, "")
        statRow:SetPoint("TOPLEFT", 0, -(i - 1) * 19)
        statRow:SetPoint("TOPRIGHT", 0, -(i - 1) * 19)
        self.listenerRows[i] = statRow
    end
    self.listenerNote = UI.Text(self.listeners.content, "tiny", "textMuted")
    self.listenerNote:SetPoint("BOTTOMLEFT")
    self.listenerNote:SetPoint("BOTTOMRIGHT")
    self.listenerNote:SetJustifyH("LEFT")
    UI.Wrap(self.listenerNote)

    self.sortKey = "rate"
    self:UpdateModeButtons()
    self:LayoutTable()
end

function Page:UpdateModeButtons()
    if not self.modeButtons then return end
    local current = WTM.Events:GetMode()
    for _, button in ipairs(self.modeButtons) do
        button:SetSelected(button.mode == current)
    end
end

--- The rate summary, the storm list and the events-per-second graph.
--- All three read numbers the event monitor already produces.
function Page:RefreshRates()
    if not self.rateCard then return end
    local cur = WTM.Events.current

    self.rateCard:Set("Now", Fmt.Rate(cur.perSecond or 0))
    self.rateCard:Set("Average", Fmt.Rate(cur.avgPerSecond or 0))
    self.rateCard:Set("Peak", Fmt.Rate(cur.peakPerSecond or 0))
    self.rateCard:Set("Total", Fmt.Comma(cur.total or 0))
    self.rateCard:Set("Distinct", tostring(WTM.Events:GetDistinctCount()))

    local entries = self._stormEntries or {}
    self._stormEntries = entries
    for i = #entries, 1, -1 do entries[i] = nil end
    local storms = WTM.Events.storms
    for i = #storms, math.max(1, #storms - 3), -1 do
        local storm = storms[i]
        if storm then
            entries[#entries + 1] = {
                name = ("%s  %s"):format(
                    Fmt.Clock(storm.startedAt, WTM.state.sessionEpoch, WTM.state.sessionStart),
                    storm.event),
                value = Fmt.Rate(storm.peakRate or 0),
                tone = "warn",
                tooltipTitle = storm.event,
                tooltipLines = {
                    { "Peak rate", Fmt.Rate(storm.peakRate or 0) },
                    { "Normal rate", Fmt.Rate(storm.baseline or 0) },
                    { "Started", Fmt.Clock(storm.startedAt,
                        WTM.state.sessionEpoch, WTM.state.sessionStart) },
                },
            }
        end
    end
    self.stormCard:SetEntries(entries, "No event storm recorded this session.")

    if UI.MainWindow:ShouldRedrawGraphs() and UI.MainWindow:TakeGraphSlot(1, 1) then
        local now = GetTime()
        local from = now - math.max(120, math.min(1800,
            now - (WTM.state.sessionStart or now)))
        WTM.Recorder:GetSeries("events", from, now, 300,
            self.rateSeries.values, self.rateSeries.times)
        self.rateGraph:SetSeries(1, self.rateSeries.values, self.rateSeries.times,
            { label = "Events / sec", colorIndex = 6 })
        self.rateGraph:SetTimeRange(from, now)
        self.rateGraph.dirty = true
        self.rateGraph:Draw()
    end
end

function Page:LayoutTable()
    local pad = M.padding
    local anchor = (#WTM.Events.storms > 0 and self.storm:IsShown())
        and self.storm or self.rateRow

    self.listeners:ClearAllPoints()
    self.listeners:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -10)
    self.listeners:SetPoint("BOTTOM", self.frame, "BOTTOM", 0, pad)

    self.table:ClearAllPoints()
    self.table:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    self.table:SetPoint("BOTTOMRIGHT", self.listeners, "BOTTOMLEFT", -M.cardGap, 0)
    self.table.LayoutHeader()
end

function Page:OnLayout() if self.table then self:LayoutTable() end end
function Page:OnShow() self:Rebuild() end

function Page:SelectEvent(event)
    self.selectedEvent = event
    self:RefreshListeners()
end

function Page:ShowRowTooltip(rowFrame, row)
    UI.TooltipClear(row.event)
    UI.TooltipLine("Current rate", Fmt.Rate(row.rate))
    UI.TooltipLine("Rolling normal", Fmt.Rate(row.baseline))
    UI.TooltipLine("Peak this session", Fmt.Rate(row.peak))
    UI.TooltipLine("Total", Fmt.Comma(row.total))
    local ms, count = WTM.CPU:GetEventCPU(row.event)
    if ms then
        UI.TooltipLine("Handler CPU (all addons)", ("%.1f ms over %s calls"):format(ms, Fmt.Comma(count or 0)))
    else
        UI.TooltipLine("Handler CPU", WTM.CPU.reason or C.TXT_REQUIRES_PROFILING, nil, "muted")
    end
    UI.TooltipLine("", "")
    UI.TooltipLine("Click to see which addons listen for it", nil, "muted")
    UI.TooltipShow(rowFrame)
end

--------------------------------------------------------------------------

function Page:Rebuild()
    if not self.table then return end
    WTM.Events:BuildView(viewData, self.sortKey, self.sortAscending, self.filter)
    self.table:SetData(viewData)
    self.table:SetEmpty(#viewData == 0,
        WTM.Events.available and "No events observed yet" or (WTM.Events.reason or C.TXT_UNAVAILABLE_CLIENT))
end

function Page:RefreshListeners()
    local event = self.selectedEvent
    local hasScanned = WTM.Processes.attribution.lastScanAt > 0

    if not event then
        self.listeners:SetTitle("LISTENERS (HEURISTIC)")
        for _, statRow in ipairs(self.listenerRows) do statRow:Hide() end
        self.listenerNote:SetText(
            "Select an event to see which addons appear to listen for it.\n\nWoW has no API that maps an event to the addons handling it. This list is built by walking named frames, asking each one IsEventRegistered (exact), and matching the frame name to a loaded addon (heuristic).")
        return
    end

    self.listeners:SetTitle(Fmt.Truncate(event, 28))
    local list = WTM.Processes:GetEventListeners(event, listenerScratch)

    for i, statRow in ipairs(self.listenerRows) do
        local entry = list[i]
        statRow:SetShown(entry ~= nil)
        if entry then
            statRow:SetLabel(Fmt.Truncate(entry.name, 22))
            statRow:Set(("%d frame%s"):format(entry.frames, entry.frames == 1 and "" or "s"))
        end
    end

    if not hasScanned then
        self.listenerNote:SetText("No frame scan has run yet. Use \"Attribute to addons\" above.")
    elseif #list == 0 then
        self.listenerNote:SetText(
            "No named frame from a loaded addon was found listening for this event. It may be handled by an anonymous frame, by the default UI, or by a frame whose name does not start with its addon's name - none of which are attributable.")
    else
        self.listenerNote:SetText(WTM.Processes:AttributionSummary())
    end
end

function Page:Refresh()
    if not self.table then return end
    self:UpdateModeButtons()

    if WTM.Events:GetMode() == "OFF" then
        self.table:SetEmpty(true,
            "Event monitoring is OFF. No listener is registered, so nothing is being counted.\n\nSwitch to Normal or Detailed above.")
        -- The toolbar is one line. The full explanation of the mode is already
        -- on the empty table above and on the Settings page; putting it here
        -- too only meant it ran off the end of the toolbar.
        self.summary:SetText("monitoring off")
        self:RefreshListeners()
        -- Still refreshed: the rate panel has to show zeroes and the storm
        -- list has to keep showing what was recorded before it was switched
        -- off, rather than freezing on the last live values.
        self:RefreshRates()
        return
    end

    ------------------------------------------------------------------
    -- Storm banner
    ------------------------------------------------------------------
    local active = WTM.Events:GetActiveStorms(self._storms or {})
    self._storms = active
    if #active > 0 then
        local storm = active[1]
        self.storm.title:SetText(("EVENT STORM: %s"):format(storm.event))
        self.storm:SetMessage(("%s right now against a normal rate of %s - a %.1fx increase, running for %s.%s")
            :format(Fmt.Rate(storm.peakRate), Fmt.Rate(storm.baseline),
                    storm.baseline > 0 and (storm.peakRate / storm.baseline) or 0,
                    Fmt.Duration(GetTime() - storm.startedAt),
                    storm.cpuAtStart and (" Addon CPU at onset: %.1f%%."):format(storm.cpuAtStart) or ""))
        if not self.storm:IsShown() then
            self.storm:Show()
            self:LayoutTable()
        end
    elseif self.storm:IsShown() then
        self.storm:Hide()
        self:LayoutTable()
    end

    ------------------------------------------------------------------
    -- Table
    ------------------------------------------------------------------
    local now = GetTime()
    if not self.lastRebuild or (now - self.lastRebuild) >= 1.0 then
        self:Rebuild()
        self.lastRebuild = now
    else
        self.table:Refresh()
    end

    self:RefreshListeners()
    self:RefreshRates()

    local totalCPU, totalCalls = WTM.CPU:GetTotalEventCPU()
    self.summary:SetText(UI.FitText(self.summary, ("%s events/s  -  %d distinct  -  %s total%s")
        :format(Fmt.Comma(math.floor(WTM.Events.current.perSecond)),
                WTM.Events:GetDistinctCount(),
                Fmt.Comma(WTM.Events.current.total),
                totalCPU and ("  -  %.0f ms in handlers"):format(totalCPU) or "")))

    if WTM.Events:IsAtTrackingCap() then
        self.summary:SetTextColor(Theme:Tone("warn"))
    else
        self.summary:SetTextColor(T("textMuted"))
    end
end
