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
          local ms = WTM.CPU:GetEventCPU(row.event)
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

    self.pauseButton = UI.Button(toolbar, "Pause capture", function(button)
        if WTM.Events:IsCapturing() then
            WTM.Events:StopCapture()
            button:SetText("Resume capture")
        else
            WTM.Events:StartCapture()
            button:SetText("Pause capture")
        end
    end, { height = 24 })
    self.pauseButton:SetPoint("LEFT", self.attributeButton, "RIGHT", 8, 0)
    self.pauseButton.tooltip =
        "Stops listening to every event. The listener itself is a single counter increment per event, but in a raid that still runs thousands of times a second - this is the switch if you want it gone entirely."

    self.summary = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.summary:SetPoint("RIGHT")
    self.summary:SetPoint("LEFT", self.pauseButton, "RIGHT", 12, 0)

    ------------------------------------------------------------------
    -- Storm banner
    ------------------------------------------------------------------
    self.storm = UI.NoticePanel(frame, "Event storm", "", nil, nil, "crit")
    self.storm:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -10)
    self.storm:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -10)
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
    self.listenerNote:SetWordWrap(true)

    self.sortKey = "rate"
    self:LayoutTable()
end

function Page:LayoutTable()
    local pad = M.padding
    local anchor = (#WTM.Events.storms > 0 and self.storm:IsShown()) and self.storm or self.toolbar

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

    local totalCPU, totalCalls = WTM.CPU:GetTotalEventCPU()
    self.summary:SetText(("%s events/s   -   %d distinct   -   %s total%s")
        :format(Fmt.Comma(math.floor(WTM.Events.current.perSecond)),
                WTM.Events:GetDistinctCount(),
                Fmt.Comma(WTM.Events.current.total),
                totalCPU and ("   -   %.0f ms in handlers"):format(totalCPU) or ""))

    if WTM.Events:IsAtTrackingCap() then
        self.summary:SetTextColor(Theme:Tone("warn"))
    else
        self.summary:SetTextColor(T("textMuted"))
    end
end
