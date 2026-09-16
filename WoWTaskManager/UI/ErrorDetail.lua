--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/ErrorDetail.lua

    The per-error overlay, opened by clicking a row on the Errors page.

    Six tabs: Overview, Stack Trace, Context, Timeline, Related Incidents,
    Related Errors.

    Two rules shape everything here.

    The first is that nothing on this screen claims causation.  An error and a
    stutter that arrived in the same second are shown side by side and called
    an overlap in time, because that is the whole of what was measured.  The
    words "caused", "because of" and "responsible for" do not appear.

    The second is that an absent measurement is written down as absent.  The
    occurrence ring holds the last handful of timestamps and nothing older, so
    the Timeline tab says so instead of drawing a line that implies it has the
    lot.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Detail = {}
UI.ErrorDetail = Detail

local TABS = {
    { key = "overview",  label = "Overview"  },
    { key = "stack",     label = "Stack Trace" },
    { key = "context",   label = "Context"   },
    { key = "timeline",  label = "Timeline"  },
    { key = "incidents", label = "Related Incidents" },
    { key = "related",   label = "Related Errors" },
}

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function StatColumn(parent, labels, width)
    local rows = {}
    for i, label in ipairs(labels) do
        local row = UI.StatRow(parent, label)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * 18)
        row:SetWidth(width or 360)
        row.rowIndex = i
        rows[label] = row
    end
    return rows
end

--- The severity of a group, as a word plus the tone that goes with it.
---
--- Severity here means "how loudly is this bug shouting", which is a count and
--- a rate. It is not a judgement about how bad the bug is: this addon cannot
--- read the intent of somebody else's code.
function Detail.Severity(group)
    if not group then return "unknown", "muted" end
    if group.internal then return "internal", "crit" end
    local count = group.count or 0
    if count >= (C.ERROR_REPEAT_THRESHOLD or 25) then return "repeating", "crit" end
    if count >= 5 then return "recurring", "warn" end
    return "once-off", "muted"
end

--------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------

function Detail:Build()
    if self.frame then return self.frame end

    local parent = UI.MainWindow.frame or UIParent

    local scrim = CreateFrame("Button", nil, parent)
    scrim:SetAllPoints(parent)
    scrim:SetFrameStrata("DIALOG")
    local scrimTex = scrim:CreateTexture(nil, "BACKGROUND")
    scrimTex:SetAllPoints()
    scrimTex:SetColorTexture(0, 0, 0, 0.55)
    scrim:SetScript("OnClick", function() Detail:Close() end)
    scrim:Hide()
    self.scrim = scrim

    local frame = UI.Panel(scrim, { color = "windowBg", borderColor = "borderStrong" })
    frame:SetPoint("CENTER")
    frame:SetSize(800, 540)
    frame:EnableMouse(true)
    self.frame = frame

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------
    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(70)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    UI.Fill(header, "panelBg")
    UI.Border(header, "B", "borderSubtle")
    self.header = header

    header.accent = header:CreateTexture(nil, "ARTWORK")
    header.accent:SetWidth(3)
    header.accent:SetPoint("TOPLEFT")
    header.accent:SetPoint("BOTTOMLEFT")

    header.title = UI.Text(header, "body", "textPrimary")
    header.title:SetPoint("TOPLEFT", 18, -12)
    header.title:SetPoint("TOPRIGHT", -180, -12)
    header.title:SetJustifyH("LEFT")

    header.sub = UI.Text(header, "small", "textSecondary")
    header.sub:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -6)
    header.sub:SetPoint("RIGHT", header, "RIGHT", -180, 0)
    header.sub:SetJustifyH("LEFT")

    header.badge = UI.Badge(header, "", "muted")
    header.badge:SetPoint("TOPRIGHT", -46, -14)

    header.count = UI.Text(header, "metric", "textPrimary", "RIGHT")
    header.count:SetPoint("BOTTOMRIGHT", -16, 10)
    header.countLabel = UI.Text(header, "tiny", "textMuted", "RIGHT")
    header.countLabel:SetPoint("BOTTOMRIGHT", header.count, "BOTTOMLEFT", -6, 3)
    header.countLabel:SetText("OCCURRENCES")

    local close = UI.Button(header, "X", function() Detail:Close() end,
        { width = 26, height = 22, style = "small" })
    close:SetPoint("TOPRIGHT", -10, -10)

    UI.MakeMovable(frame, header)

    ------------------------------------------------------------------
    -- Tabs and panels
    ------------------------------------------------------------------
    self.tabStrip = UI.TabStrip(frame, TABS, function(key) Detail:ShowTab(key) end)
    self.tabStrip:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 12, 0)
    self.tabStrip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -12, 0)

    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", self.tabStrip, "BOTTOMLEFT", 0, -M.paddingSmall)
    body:SetPoint("BOTTOMRIGHT", -M.padding, 52)
    self.body = body

    self.panels = {}
    for _, tab in ipairs(TABS) do
        local panel = CreateFrame("Frame", nil, body)
        panel:SetAllPoints(body)
        panel:Hide()
        self.panels[tab.key] = panel
    end

    self:BuildOverview(self.panels.overview)
    self:BuildStack(self.panels.stack)
    self:BuildContext(self.panels.context)
    self:BuildTimeline(self.panels.timeline)
    self:BuildIncidents(self.panels.incidents)
    self:BuildRelated(self.panels.related)

    ------------------------------------------------------------------
    -- Control bar
    ------------------------------------------------------------------
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetHeight(44)
    bar:SetPoint("BOTTOMLEFT")
    bar:SetPoint("BOTTOMRIGHT")
    UI.Fill(bar, "panelBg")
    UI.Border(bar, "T", "borderSubtle")
    self.bar = bar

    self.copyButton = UI.Button(bar, "Copy report", function()
        UI.ShowCopyBox(WTM.Reports:Error(Detail.group), "Error report")
    end, { height = 24, primary = true })
    self.copyButton:SetPoint("LEFT", 16, 0)

    self.ignoreButton = UI.Button(bar, "Ignore this error", function(button)
        local group = Detail.group
        if not group then return end
        WTM.Errors:SetIgnored(group, not WTM.Errors:IsIgnored(group))
        button:SetSelected(WTM.Errors:IsIgnored(group))
        Detail:Refresh()
    end, { height = 24 })
    self.ignoreButton:SetPoint("LEFT", self.copyButton, "RIGHT", 8, 0)
    self.ignoreButton.tooltip =
        "An ignored error is kept out of the notifications and out of the top of " ..
        "the list. It keeps being counted: hiding a number is not the same as " ..
        "the number not existing."

    self.ignoreAddonButton = UI.Button(bar, "Ignore this addon", function(button)
        local group = Detail.group
        if not group or not group.addon then return end
        local ignored = not WTM.Errors:IsIgnored(group)
        WTM.Errors:SetAddonIgnored(group.addon, ignored)
        button:SetSelected(ignored)
        Detail:Refresh()
    end, { height = 24 })
    self.ignoreAddonButton:SetPoint("LEFT", self.ignoreButton, "RIGHT", 8, 0)

    self.addonButton = UI.Button(bar, "Open addon", function()
        local group = Detail.group
        if not group or not group.addon then return end
        local record = WTM.Processes:Get(group.addon)
        if record then
            Detail:Close()
            UI.AddonDetail:Open(record)
        end
    end, { height = 24 })
    self.addonButton:SetPoint("LEFT", self.ignoreAddonButton, "RIGHT", 8, 0)

    self.note = UI.Text(bar, "tiny", "textMuted", "RIGHT")
    self.note:SetPoint("RIGHT", -16, 0)

    return frame
end

--------------------------------------------------------------------------
-- Overview
--------------------------------------------------------------------------

function Detail:BuildOverview(panel)
    self.overviewRows = StatColumn(panel, {
        "Addon", "Attribution", "File", "Line", "Severity",
        "Occurrences", "First seen", "Last seen", "Rate",
        "Overlapping incidents", "Ignored", "Origin", "Session",
    }, 350)

    panel.notes = UI.Text(panel, "small", "textMuted")
    panel.notes:SetPoint("TOPLEFT", 368, 0)
    panel.notes:SetPoint("BOTTOMRIGHT")
    panel.notes:SetJustifyH("LEFT")
    panel.notes:SetJustifyV("TOP")
    UI.Wrap(panel.notes)
    self.overviewNotes = panel.notes
end

function Detail:RefreshOverview()
    local group = self.group
    if not group then return end
    local rows = self.overviewRows
    local Errors = WTM.Errors

    local severity, tone = Detail.Severity(group)
    local elapsed = math.max(1, (group.lastAt or 0) - (group.firstAt or 0))
    local perMinute = (group.count or 1) / (elapsed / 60)

    rows["Addon"]:Set(group.addon or "Unknown")
    rows["Attribution"]:Set(group.addonCertain and "From the file path"
        or "Not attributable", group.addonCertain and "ok" or "muted")
    rows["File"]:Set(group.file or "unknown")
    rows["Line"]:Set(group.line and tostring(group.line) or "unknown")
    rows["Severity"]:Set(severity, tone)
    rows["Occurrences"]:Set(Fmt.Comma(group.count or 0))
    rows["First seen"]:Set(Fmt.Ago(group.firstAt))
    rows["Last seen"]:Set(Fmt.Ago(group.lastAt))
    rows["Rate"]:Set((group.count or 0) > 1
        and ("%.1f/min while it was firing"):format(perMinute) or "single occurrence")

    local overlaps = Errors:OverlapsSpikes(group)
    rows["Overlapping incidents"]:Set(overlaps > 0 and tostring(overlaps) or "none",
        overlaps > 0 and "warn" or "muted")

    local ignored = Errors:IsIgnored(group)
    rows["Ignored"]:Set(ignored and "yes - still counted" or "no",
        ignored and "muted" or nil)
    rows["Origin"]:Set(group.internal and "WoW Task Manager internal error" or "other addon or Blizzard code",
        group.internal and "crit" or nil)
    rows["Session"]:Set(group.sessionId and tostring(group.sessionId) or "this session")

    local notes = {}
    notes[#notes + 1] = "MESSAGE\n" .. tostring(group.message or "")
    if group.internal then
        notes[#notes + 1] =
            "\nThis error came from WoW Task Manager itself. It is shown exactly " ..
            "like any other, and it is never filtered out by default: a monitor " ..
            "that hides its own faults is worse than no monitor."
    end
    if not group.addonCertain then
        notes[#notes + 1] =
            "\nThe addon could not be read out of the file path, so no addon is " ..
            "named. Guessing one would be worse than leaving it blank."
    end
    if overlaps > 0 then
        notes[#notes + 1] = "\n" .. C.TXT_ERROR_OVERLAP_NOTE
    end
    self.overviewNotes:SetText(table.concat(notes, "\n"))
end

--------------------------------------------------------------------------
-- Stack trace
--------------------------------------------------------------------------

function Detail:BuildStack(panel)
    local scroll, canvas = UI.ScrollCanvas(panel, { step = 60 })
    self.stackScroll, self.stackCanvas = scroll, canvas
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 28)

    canvas.text = UI.Text(canvas, "small", "textSecondary")
    canvas.text:SetPoint("TOPLEFT")
    canvas.text:SetJustifyH("LEFT")
    canvas.text:SetJustifyV("TOP")
    UI.Wrap(canvas.text)
    self.stackText = canvas.text

    self.stackNote = UI.Text(panel, "tiny", "textMuted")
    self.stackNote:SetPoint("BOTTOMLEFT", 0, 6)
    self.stackNote:SetPoint("BOTTOMRIGHT", -110, 6)
    self.stackNote:SetJustifyH("LEFT")

    self.stackCopy = UI.Button(panel, "Copy stack", function()
        local group = Detail.group
        UI.ShowCopyBox(group and group.stack or "No stack trace was captured.",
            "Stack trace")
    end, { height = 22, width = 100 })
    self.stackCopy:SetPoint("BOTTOMRIGHT", 0, 2)

    self.stackEmpty = UI.EmptyState(panel, "No stack trace")
    self.stackEmpty:SetAllPoints(panel)
    self.stackEmpty:Hide()
end

function Detail:RefreshStack()
    local group = self.group
    local stack = group and group.stack

    if not stack or stack == "" then
        self.stackScroll:Hide()
        self.stackCopy:Hide()
        self.stackNote:Hide()
        self.stackEmpty:Show()
        self.stackEmpty:SetMessage(WTM.Caps:Has("errorStacks")
            and "The error arrived without a usable stack. Some errors are raised from places where there is nothing above them to walk."
            or "This client does not expose debugstack, so no stack could be captured.")
        return
    end

    self.stackEmpty:Hide()
    self.stackScroll:Show()
    self.stackCopy:Show()
    self.stackNote:Show()

    self.stackScroll:SyncWidth()
    local width = self.stackScroll:GetWidth() or 600
    self.stackText:SetWidth(math.max(200, width - 8))
    self.stackText:SetText(stack)
    local height = self.stackText:GetStringHeight() or 200
    self.stackCanvas:SetHeight(math.max(1, height + 8))

    self.stackNote:SetText(stack:find("[stack truncated", 1, true)
        and ("Trimmed at %d characters, which is the configured cap."):format(
            WTM.db.profile.errors.maxStackLength or C.ERROR_MAX_STACK)
        or "Captured once, when the fingerprint was first seen. Repeats of the same error do not re-capture it.")
end

--------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------

function Detail:BuildContext(panel)
    self.contextRows = StatColumn(panel, {
        "Frames per second", "Frame time", "Lua memory",
        "Addon CPU", "CPU window", "Events per second", "Own overhead",
        "Home latency", "World latency",
    }, 350)

    self.contextWhere = StatColumn(panel, {
        "Zone", "Instance", "Difficulty", "In combat", "Encounter", "Group size",
    }, 340)
    for _, row in pairs(self.contextWhere) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 368, -(row.rowIndex - 1) * 18)
    end

    panel.note = UI.Text(panel, "small", "textMuted")
    panel.note:SetPoint("TOPLEFT", 0, -9 * 18 - 16)
    panel.note:SetPoint("BOTTOMRIGHT")
    panel.note:SetJustifyH("LEFT")
    panel.note:SetJustifyV("TOP")
    UI.Wrap(panel.note)
    self.contextNote = panel.note
end

function Detail:RefreshContext()
    local group = self.group
    local ctx = group and group.context or nil
    local rows, where = self.contextRows, self.contextWhere

    local function set(row, value, formatter, tone)
        if value == nil then
            row:Set("not measured", "muted")
        else
            row:Set(formatter and formatter(value) or tostring(value), tone)
        end
    end

    if not ctx then
        for _, row in pairs(rows) do row:Set("no snapshot", "muted") end
        for _, row in pairs(where) do row:Set("no snapshot", "muted") end
        self.contextNote:SetText("No context was captured for this error.")
        return
    end

    set(rows["Frames per second"], ctx.fps, Fmt.FPS)
    set(rows["Frame time"], ctx.frameMs, Fmt.Ms)
    set(rows["Lua memory"], ctx.luaKB, Fmt.Memory)
    set(rows["Addon CPU"], ctx.cpuPct, Fmt.Percent)
    set(rows["CPU window"], ctx.cpuWindowSec,
        function(v) return ("%.0f s"):format(v) end)
    set(rows["Events per second"], ctx.eventsPerSec, Fmt.Rate)
    set(rows["Own overhead"], ctx.overheadMsPerSec,
        function(v) return ("%.2f ms/s"):format(v) end)
    set(rows["Home latency"], ctx.latencyHome,
        function(v) return ("%d ms"):format(v) end)
    set(rows["World latency"], ctx.latencyWorld,
        function(v) return ("%d ms"):format(v) end)

    set(where["Zone"], ctx.zone)
    set(where["Instance"], ctx.instanceType)
    set(where["Difficulty"], ctx.difficulty)
    where["In combat"]:Set(ctx.combat and "yes" or "no", ctx.combat and "warn" or nil)
    set(where["Encounter"], ctx.encounter)
    set(where["Group size"], ctx.groupSize, function(v) return tostring(v) end)

    self.contextNote:SetText(
        "This snapshot was taken once, when the fingerprint was first seen. " ..
        "Repeats of the same error do not re-snapshot it: taking nine readings " ..
        "of the same second during a storm would slow the client down and " ..
        "would not tell you anything the first reading did not.\n\n" ..
        "Addon CPU is a share of the sampling window shown above it, not an " ..
        "instant. There is no API that reports what one addon was doing in the " ..
        "exact frame the error was raised.")
end

--------------------------------------------------------------------------
-- Timeline
--------------------------------------------------------------------------

function Detail:BuildTimeline(panel)
    self.timelineGraph = UI.Graph(panel, {
        title = "FRAME TIME AROUND THIS ERROR",
        valueFormat = function(v) return Fmt.Ms(v) end,
    })
    self.timelineGraph:SetPoint("TOPLEFT")
    self.timelineGraph:SetPoint("TOPRIGHT")
    self.timelineGraph:SetHeight(170)

    self.occurrenceHeading = UI.SectionHeading(panel, "Occurrences kept")
    self.occurrenceHeading:SetPoint("TOPLEFT", self.timelineGraph, "BOTTOMLEFT", 0, -10)
    self.occurrenceHeading:SetPoint("TOPRIGHT", self.timelineGraph, "BOTTOMRIGHT", 0, -10)

    self.occurrenceText = UI.Text(panel, "small", "textSecondary")
    self.occurrenceText:SetPoint("TOPLEFT", self.occurrenceHeading, "BOTTOMLEFT", 0, -6)
    self.occurrenceText:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    self.occurrenceText:SetJustifyH("LEFT")
    self.occurrenceText:SetJustifyV("TOP")
    UI.Wrap(self.occurrenceText)

    self.timelineNote = UI.Text(panel, "tiny", "textMuted")
    self.timelineNote:SetPoint("BOTTOMLEFT", 0, 4)
    self.timelineNote:SetPoint("BOTTOMRIGHT", 0, 4)
    self.timelineNote:SetJustifyH("LEFT")
    UI.Wrap(self.timelineNote)
end

function Detail:RefreshTimeline()
    local group = self.group
    if not group then return end
    local Errors = WTM.Errors

    -- The frame time either side of the window this bug was alive in, taken
    -- from the recorder rather than from anything the error itself carried.
    local from = (group.firstAt or 0) - 15
    local to   = (group.lastAt or 0) + 15

    self._values = self._values or {}
    self._stamps = self._stamps or {}
    WTM.Recorder:GetSeries("frameAvgMs", from, to, 300, self._values, self._stamps)

    if #self._values > 1 then
        self.timelineGraph:SetSeries(1, self._values, self._stamps,
            { label = "Frame time", colorIndex = 2 })
        self.timelineGraph:SetTitle("FRAME TIME AROUND THIS ERROR")
    else
        self.timelineGraph:ClearSeries()
        self.timelineGraph:SetTitle(
            "FRAME TIME AROUND THIS ERROR - no history recorded in this window")
    end
    self.timelineGraph:SetTimeRange(from, to)

    local times = Errors:Occurrences(group, self._times or {})
    self._times = times

    -- Where the occurrences fall on that axis. Ticks, not annotations: the
    -- graph is told when the error arrived and nothing about why.
    local markers = self._markers or {}
    self._markers = markers
    for i = #markers, 1, -1 do markers[i] = nil end
    for i = 1, #times do
        markers[#markers + 1] = { t = times[i], kind = "luaerror" }
    end
    self.timelineGraph:SetMarkers(markers)
    self.timelineGraph.dirty = true
    self.timelineGraph:Draw()

    local lines = {}
    local now = GetTime()
    for i = #times, 1, -1 do
        lines[#lines + 1] = ("  %s ago"):format(Fmt.Duration(math.max(0, now - times[i])))
        if #lines >= 12 then break end
    end
    self.occurrenceText:SetText(#lines > 0 and table.concat(lines, "\n")
        or "  no timestamps held")

    if Errors:OccurrencesTruncated(group) then
        self.timelineNote:SetText(
            ("Showing the most recent %d of %s occurrences. Older timestamps were " ..
             "overwritten in place: the ring is fixed size so that a storm costs " ..
             "one store per error rather than one allocation.")
            :format(math.min(#times, C.ERROR_TIME_RING), Fmt.Comma(group.count or 0)))
    else
        self.timelineNote:SetText(
            "Every occurrence of this error is listed. " .. C.TXT_ERROR_OVERLAP_NOTE)
    end
end

--------------------------------------------------------------------------
-- Related incidents
--------------------------------------------------------------------------

local function IncidentRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.when = UI.Text(row, "small", "textSecondary")
    row.when:SetPoint("LEFT", 6, 0)
    row.when:SetWidth(110)

    row.kind = UI.Badge(row, "", "muted")
    row.kind:SetPoint("LEFT", row.when, "RIGHT", 6, 0)

    row.peak = UI.Text(row, "small", "textPrimary", "RIGHT")
    row.peak:SetPoint("LEFT", row.kind, "RIGHT", 8, 0)
    row.peak:SetWidth(80)

    row.detail = UI.Text(row, "small", "textMuted")
    row.detail:SetPoint("LEFT", row.peak, "RIGHT", 10, 0)
    row.detail:SetPoint("RIGHT", -6, 0)
    return row
end

local function UpdateIncidentRow(row, cluster)
    row.when:SetText(Fmt.Ago(cluster.startedAt))
    row.kind:Set((cluster.label or cluster.kind or "spike"):upper(),
        cluster.kind == "freeze" and "crit" or "warn")
    row.peak:SetText(Fmt.Ms(cluster.peakMs or 0))
    row.detail:SetText(UI.FitText(row.detail, ("%d frames over %s")
        :format(cluster.frames or 1, Fmt.Duration(cluster.duration or 0))))
end

function Detail:BuildIncidents(panel)
    self.incidentList = UI.ScrollList(panel, 24, IncidentRow, UpdateIncidentRow,
        function(cluster)
            Detail:Close()
            UI.MainWindow:ShowPage("incidents")
            local page = UI.Pages.incidents
            if page and page.SelectIncident then page:SelectIncident(cluster.id) end
        end)
    self.incidentList:SetPoint("TOPLEFT")
    self.incidentList:SetPoint("BOTTOMRIGHT", 0, 42)

    self.incidentEmpty = UI.EmptyState(panel, "")
    self.incidentEmpty:SetPoint("TOPLEFT")
    self.incidentEmpty:SetPoint("BOTTOMRIGHT", 0, 42)
    self.incidentEmpty:Hide()

    self.incidentNote = UI.Text(panel, "small", "textMuted")
    self.incidentNote:SetPoint("BOTTOMLEFT", 0, 4)
    self.incidentNote:SetPoint("BOTTOMRIGHT", 0, 4)
    self.incidentNote:SetJustifyH("LEFT")
    UI.Wrap(self.incidentNote)
    self.incidentNote:SetText(C.TXT_ERROR_OVERLAP_NOTE)
end

function Detail:RefreshIncidents()
    local list = WTM.Errors:RelatedIncidents(self.group, self._incidents or {})
    self._incidents = list
    self.incidentList:SetData(list)
    self.incidentList:SetShown(#list > 0)
    self.incidentEmpty:SetShown(#list == 0)
    self.incidentEmpty:SetMessage(("No stutter was recorded within %d seconds of " ..
        "this error. That is a fact about the frame times, not a verdict on the bug.")
        :format(C.ERROR_INCIDENT_SLACK_SEC or 5))
end

--------------------------------------------------------------------------
-- Related errors
--------------------------------------------------------------------------

local function RelatedRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.count = UI.Text(row, "small", "textPrimary", "RIGHT")
    row.count:SetPoint("LEFT", 6, 0)
    row.count:SetWidth(46)

    row.badge = UI.Badge(row, "", "muted")
    row.badge:SetPoint("LEFT", row.count, "RIGHT", 8, 0)

    row.message = UI.Text(row, "small", "textSecondary")
    row.message:SetPoint("LEFT", row.badge, "RIGHT", 8, 0)
    row.message:SetPoint("RIGHT", -6, 0)
    return row
end

local function UpdateRelatedRow(row, group)
    local severity, tone = Detail.Severity(group)
    row.count:SetText(Fmt.Comma(group.count or 0))
    row.badge:Set(severity:upper(), tone)
    row.message:SetText(UI.FitText(row.message,
        ("%s:%s  %s"):format(group.file or "?", tostring(group.line or "?"),
            Fmt.StripColors(group.message or ""))))
end

function Detail:BuildRelated(panel)
    self.relatedList = UI.ScrollList(panel, 24, RelatedRow, UpdateRelatedRow,
        function(group) Detail:Open(group) end)
    self.relatedList:SetPoint("TOPLEFT")
    self.relatedList:SetPoint("BOTTOMRIGHT", 0, 42)

    self.relatedEmpty = UI.EmptyState(panel, "")
    self.relatedEmpty:SetPoint("TOPLEFT")
    self.relatedEmpty:SetPoint("BOTTOMRIGHT", 0, 42)
    self.relatedEmpty:Hide()

    self.relatedNote = UI.Text(panel, "small", "textMuted")
    self.relatedNote:SetPoint("BOTTOMLEFT", 0, 4)
    self.relatedNote:SetPoint("BOTTOMRIGHT", 0, 4)
    self.relatedNote:SetJustifyH("LEFT")
    UI.Wrap(self.relatedNote)
end

function Detail:RefreshRelated()
    local group = self.group
    if not group then return end

    local list = self._related or {}
    self._related = list
    for i = #list, 1, -1 do list[i] = nil end

    if group.addon then
        WTM.Errors:ForAddon(group.addon, list)
        for i = #list, 1, -1 do
            if list[i] == group then table.remove(list, i) end
        end
        self.relatedNote:SetText(("Other distinct errors attributed to %s this session.")
            :format(group.addon))
        self.relatedList:SetData(list)
        self.relatedEmpty:SetMessage(
            ("No other distinct error has been attributed to %s."):format(group.addon))
    else
        -- Without an addon there is nothing honest to group by, so the panel
        -- says that rather than inventing a relationship.
        self.relatedNote:SetText(
            "This error could not be attributed to an addon, so there is nothing " ..
            "to relate it to. Matching on message text alone would group " ..
            "unrelated bugs that happen to fail the same way.")
        self.relatedList:SetData(list)
        self.relatedEmpty:SetMessage(
            "This error could not be attributed to an addon, so there is nothing " ..
            "to relate it to.")
    end

    self.relatedList:SetShown(#list > 0)
    self.relatedEmpty:SetShown(#list == 0)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Detail:Open(group)
    if not group then return end
    self:Build()
    self.group = group
    self.scrim:Show()
    self.frame:Show()
    if not self.panels[self.currentTab or ""] then self.currentTab = "overview" end
    self.tabStrip:Select(self.currentTab)
    self:Refresh()
end

function Detail:Close()
    if self.scrim then self.scrim:Hide() end
end

function Detail:IsShown()
    return self.scrim ~= nil and self.scrim:IsShown()
end

function Detail:ShowTab(key)
    self.currentTab = key
    for tabKey, panel in pairs(self.panels) do
        panel:SetShown(tabKey == key)
    end
    self:Refresh()
end

function Detail:Refresh()
    local group = self.group
    if not self.frame or not group then return end

    local severity, tone = Detail.Severity(group)
    local header = self.header

    header.accent:SetColorTexture(Theme:Tone(tone))
    header.title:SetText(UI.FitText(header.title,
        Fmt.StripColors(tostring(group.message or ""))))
    header.sub:SetText(UI.FitText(header.sub, ("%s  -  %s:%s")
        :format(group.addon or "Unknown addon", group.file or "?", tostring(group.line or "?"))))
    header.badge:Set(severity:upper(), tone)
    header.count:SetText(Fmt.Comma(group.count or 0))

    local ignored = WTM.Errors:IsIgnored(group)
    self.ignoreButton:SetSelected(ignored)
    self.ignoreButton:SetText(ignored and "Stop ignoring" or "Ignore this error")
    self.ignoreAddonButton:SetEnabledState(group.addon ~= nil,
        "This error could not be attributed to an addon.")
    self.addonButton:SetEnabledState(
        group.addon ~= nil and WTM.Processes:Get(group.addon) ~= nil,
        "No loaded addon of that name is known to this client.")

    if group.internal then
        self.note:SetText("WoW Task Manager internal error")
    elseif ignored then
        self.note:SetText("Ignored - hidden from notices, still counted")
    else
        self.note:SetText("")
    end

    local tab = self.currentTab
    if tab == "overview" then self:RefreshOverview()
    elseif tab == "stack" then self:RefreshStack()
    elseif tab == "context" then self:RefreshContext()
    elseif tab == "timeline" then self:RefreshTimeline()
    elseif tab == "incidents" then self:RefreshIncidents()
    elseif tab == "related" then self:RefreshRelated() end
end
