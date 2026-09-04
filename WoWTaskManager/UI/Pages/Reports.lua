--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Reports.lua

    Problem reports: a block of plain text describing what the client was doing,
    ready to paste into a bug tracker or a Discord thread.

    WoW gives addons no clipboard access in either direction.  Nothing can be
    written to the clipboard and nothing can be read from it.  So "copy" here
    means a selectable edit box with the text already in it and already
    selected, and the page says so rather than pretending a Copy button did
    something it cannot do.

    "Report a problem now" is the important button.  A stutter the player
    noticed but cannot point at is not diagnosable; the same stutter with a
    timestamp on the same axis as the frame times is.  Pressing it drops a
    marker AND produces the report, so the moment survives in both places.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("reports", {})

-- The four reports, in the order somebody filing a bug would want them.
local KINDS = {
    {
        key   = "moment",
        label = "Report a problem now",
        title = "Problem report",
        blurb = "Everything measurable about this moment, plus a marker on the timeline so it can be found again later.",
        build = function(note) return WTM.Reports:Moment(note) end,
        marks = true,
    },
    {
        key   = "errors",
        label = "All Lua errors",
        title = "Lua error report",
        blurb = "Every distinct error captured this session, with counts, stacks and the context each one arrived in.",
        build = function() return WTM.Reports:AllErrors() end,
    },
    {
        key   = "session",
        label = "Session summary",
        title = "Session report",
        blurb = "Frame time, memory, CPU, events, incidents and findings for the whole session.",
        build = function() return WTM.Reports:Session() end,
    },
    {
        key   = "worst",
        label = "Worst error",
        title = "Error report",
        blurb = "The single error that fired most often this session, in full.",
        build = function()
            local group = WTM.Errors:MostFrequent()
            if not group then return "No Lua error has been captured this session." end
            return WTM.Reports:Error(group)
        end,
    },
}

--------------------------------------------------------------------------

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Left column: what can be generated
    ------------------------------------------------------------------
    local side = CreateFrame("Frame", nil, frame)
    side:SetWidth(250)
    side:SetPoint("TOPLEFT", pad, -pad)
    side:SetPoint("BOTTOMLEFT", pad, pad)
    self.side = side

    local heading = UI.SectionHeading(side, "Reports")
    heading:SetPoint("TOPLEFT")
    heading:SetPoint("TOPRIGHT")

    self.kindButtons = {}
    local previous = heading
    for _, kind in ipairs(KINDS) do
        local button = UI.Button(side, kind.label, function()
            Page:Generate(kind.key)
        end, { height = 26 })
        button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -8)
        button:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, -8)
        button.tooltip = kind.blurb
        self.kindButtons[kind.key] = button
        previous = button
    end

    ------------------------------------------------------------------
    -- The note attached to a problem report
    ------------------------------------------------------------------
    self.noteHeading = UI.SectionHeading(side, "What went wrong")
    self.noteHeading:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -18)
    self.noteHeading:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, -18)

    self.noteBox = UI.SearchBox(side, "e.g. froze opening the bags")
    self.noteBox:SetPoint("TOPLEFT", self.noteHeading, "BOTTOMLEFT", 0, -6)
    self.noteBox:SetPoint("TOPRIGHT", self.noteHeading, "BOTTOMRIGHT", 0, -6)
    self.noteBox:SetHeight(24)

    self.noteHint = UI.Text(side, "tiny", "textMuted", "LEFT")
    self.noteHint:SetPoint("TOPLEFT", self.noteBox, "BOTTOMLEFT", 0, -6)
    self.noteHint:SetPoint("RIGHT", side, "RIGHT", 0, 0)
    self.noteHint:SetHeight(46)
    UI.Wrap(self.noteHint, 4)
    self.noteHint:SetText("One line in your own words. It is written at the top of the report and into the timeline marker, so a report and a marker can be lined up months later.")

    ------------------------------------------------------------------
    -- Storage summary, so the page says what it would be reporting on
    ------------------------------------------------------------------
    self.summary = UI.StatCard(side, "AVAILABLE", {
        "Lua errors", "Distinct errors", "Incidents", "Markers", "Findings",
    })
    self.summary:SetPoint("BOTTOMLEFT")
    self.summary:SetPoint("BOTTOMRIGHT")
    self.summary:SetHeight(122)

    ------------------------------------------------------------------
    -- Right: the report itself
    ------------------------------------------------------------------
    local panel = UI.Panel(frame, { color = "panelBg", borderColor = "borderSubtle" })
    panel:SetPoint("TOPLEFT", side, "TOPRIGHT", pad, 0)
    panel:SetPoint("BOTTOMRIGHT", -pad, pad)
    self.panel = panel

    self.reportTitle = UI.Text(panel, "heading", "textPrimary", "LEFT")
    self.reportTitle:SetPoint("TOPLEFT", 12, -10)
    self.reportTitle:SetPoint("TOPRIGHT", -230, -10)
    self.reportTitle:SetText("NO REPORT GENERATED")

    self.copyButton = UI.Button(panel, "Open selectable copy", function()
        if not Page.reportText or Page.reportText == "" then return end
        UI.ShowCopyBox(Page.reportText, Page.reportTitleText or "Report")
    end, { height = 22, width = 150, primary = true })
    self.copyButton:SetPoint("TOPRIGHT", -10, -8)

    self.clearButton = UI.Button(panel, "Clear", function()
        Page:Clear()
    end, { height = 22, width = 60 })
    self.clearButton:SetPoint("RIGHT", self.copyButton, "LEFT", -6, 0)

    local scroll, canvas = UI.ScrollCanvas(panel, { padding = 12, step = 72 })
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 12, -38)
    scroll:SetPoint("BOTTOMRIGHT", -12, 34)
    self.scroll, self.canvas = scroll, canvas

    canvas.text = UI.Text(canvas, "small", "textSecondary", "LEFT")
    canvas.text:SetPoint("TOPLEFT")
    canvas.text:SetJustifyV("TOP")
    UI.Wrap(canvas.text)
    self.reportBody = canvas.text

    self.empty = UI.EmptyState(panel,
        "Pick a report on the left. Nothing is generated until you ask for one: building a report walks the whole session, and doing that on a timer would be this addon spending your frame budget on paperwork.")
    self.empty:SetPoint("TOPLEFT", 12, -38)
    self.empty:SetPoint("BOTTOMRIGHT", -12, 34)

    self.footer = UI.Text(panel, "tiny", "textMuted", "LEFT")
    self.footer:SetPoint("BOTTOMLEFT", 12, 6)
    self.footer:SetPoint("BOTTOMRIGHT", -12, 6)
    self.footer:SetHeight(22)
    UI.Wrap(self.footer, 2)
    self.footer:SetText("WoW gives addons no access to the system clipboard, in either direction. \"Open selectable copy\" puts the text in a box with everything selected, ready for Ctrl+C.")

    self:Clear()
end

function Page:OnShow() self:Refresh() end

--------------------------------------------------------------------------

function Page:Clear()
    self.reportText = nil
    self.reportTitleText = nil
    self.reportBody:SetText("")
    self.reportTitle:SetText("NO REPORT GENERATED")
    self.canvas:SetHeight(1)
    self.scroll:Hide()
    self.empty:Show()
    self.copyButton:SetEnabledState(false, "Generate a report first.")
    self.clearButton:SetEnabledState(false, "There is nothing to clear.")
end

function Page:Generate(key)
    local kind
    for _, candidate in ipairs(KINDS) do
        if candidate.key == key then kind = candidate break end
    end
    if not kind then return end

    local note = self.noteBox:GetText() or ""

    -- A marker first, so the moment is on the timeline even if the report
    -- itself is thrown away.
    if kind.marks then
        WTM.Context:AddMarker("custom",
            note ~= "" and ("Problem reported: " .. note) or "Problem reported")
    end

    -- Report building walks the session, and a fault in one report must not
    -- take the page down with it.
    local ok, text = pcall(kind.build, note)
    if not ok then
        text = ("The report could not be generated:\n\n%s\n\nThis is a fault in " ..
                "WoW Task Manager, not in the data."):format(tostring(text))
    end

    self.reportText = text
    self.reportTitleText = kind.title
    self.reportTitle:SetText(UI.FitText(self.reportTitle, kind.title:upper()))

    self.empty:Hide()
    self.scroll:Show()
    self.scroll:SyncWidth()
    local width = self.scroll:GetWidth() or 500
    self.reportBody:SetWidth(math.max(200, width - 8))
    self.reportBody:SetText(text)
    self.canvas:SetHeight(math.max(1, (self.reportBody:GetStringHeight() or 200) + 12))
    self.scroll:SetVerticalScroll(0)

    self.copyButton:SetEnabledState(true)
    self.clearButton:SetEnabledState(true)

    self:Refresh()
end

--------------------------------------------------------------------------

function Page:Refresh()
    if not self.summary then return end

    local errors = WTM.Errors
    self.summary:Set("Lua errors", Fmt.Comma(errors.stats.total or 0))
    self.summary:Set("Distinct errors", Fmt.Comma(#errors.groups))
    self.summary:Set("Incidents", Fmt.Comma(#WTM.SpikeDetector.clusters))
    self.summary:Set("Markers", Fmt.Comma(#WTM.Context.markers))

    -- Build() is cached behind a TTL, so asking for the count here does not
    -- re-run the analysis on every refresh of this page.
    self._findings = WTM.Diagnostics:Build(self._findings or {})
    self.summary:Set("Findings", Fmt.Comma(#self._findings))
end
