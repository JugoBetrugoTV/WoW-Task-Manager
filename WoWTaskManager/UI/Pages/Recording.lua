--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Recording.lua

    What is being recorded, how much of it there is, and a way to mark a moment.

    The markers are the point of this page. A stutter you can find again on the
    timeline is a stutter you can look into; one you only remember happening is
    not. Pressing "Pull started" before a pull, or "Lag noticed" the moment it
    happens, turns a vague memory into a timestamp on the same axis as every
    other signal.

    Nothing here starts a second recorder. "Start" and "Stop" enable and
    disable the sampling that already exists; the buttons are a visible control
    over one switch, not a parallel system.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("recording", {})

-- Ready-made markers for the moments people actually want to find again.
local QUICK_MARKERS = {
    { label = "Pull started",  text = "Pull started" },
    { label = "Boss fight",    text = "Boss fight" },
    { label = "Lag noticed",   text = "Lag noticed" },
    { label = "Addon changed", text = "Addon changed" },
    { label = "Zone entered",  text = "Zone entered" },
    { label = "Something odd", text = "Something odd" },
}

function Page:Build(frame)
    local pad = M.padding

    local scroll, canvas = UI.ScrollCanvas(frame, { padding = pad })
    self.scroll, self.canvas = scroll, canvas

    local grid = UI.Grid(canvas, { minColumnWidth = 280, maxColumns = 3 })
    self.grid = grid

    ------------------------------------------------------------------
    -- State
    ------------------------------------------------------------------
    self.state = UI.StatusCard(canvas, "RECORDER", {
        "Session", "Duration", "Sampling", "Adaptive burst",
    })
    grid:Add(self.state, { span = 1, height = 118, key = "state" })

    self.volume = UI.StatCard(canvas, "WHAT HAS BEEN RECORDED", {
        "Frames measured", "History buckets", "Flight recorder", "Incidents", "Markers",
    })
    grid:Add(self.volume, { span = 1, height = 122, key = "volume" })

    self.storage = UI.StatCard(canvas, "SAVED DATA", {
        "Stored sessions", "Stored incidents", "Estimated size", "Retention",
    })
    grid:Add(self.storage, { span = 1, height = 106, key = "storage" })

    ------------------------------------------------------------------
    -- Controls
    ------------------------------------------------------------------
    local controls = UI.Card(canvas, "CONTROLS", {})
    grid:Add(controls, { span = 3, height = 96, key = "controls" })
    self.controls = controls

    self.startStop = UI.Button(controls.content, "", function()
        local sampling = WTM.db.profile.sampling
        sampling.enabled = not sampling.enabled
        if sampling.enabled then WTM.Scheduler:Start() else WTM.Scheduler:Stop() end
        self:Refresh()
    end, { height = 26, primary = true, minWidth = 150 })
    self.startStop:SetPoint("TOPLEFT", 0, 0)
    self.startStop.tooltip = "Stops or starts every sampling task. Data already recorded is kept either way; stopping simply records nothing new."

    self.resetButton = UI.Button(controls.content, "Reset this session's counters", function()
        WTM.Database:ResetRuntime()
        WTM:Print("Runtime counters reset. Saved history is untouched.")
        self:Refresh()
    end, { height = 26 })
    self.resetButton:SetPoint("LEFT", self.startStop, "RIGHT", 8, 0)
    self.resetButton.tooltip = "Clears this session's spikes, incidents and counters and starts measuring again. Saved sessions are not affected."

    self.saveButton = UI.Button(controls.content, "Save session now", function()
        WTM.Sessions:UpdateSummary()
        WTM:Print("Session summary updated. It is written to the database at logout or reload.")
        self:Refresh()
    end, { height = 26 })
    self.saveButton:SetPoint("LEFT", self.resetButton, "RIGHT", 8, 0)
    self.saveButton.tooltip = "Brings the stored summary up to date with the numbers measured so far, so a disconnect still leaves usable data."

    self.controlNote = UI.Text(controls.content, "tiny", "textMuted", "LEFT")
    self.controlNote:SetPoint("TOPLEFT", self.startStop, "BOTTOMLEFT", 0, -8)
    self.controlNote:SetPoint("RIGHT", controls.content, "RIGHT", 0, 0)
    self.controlNote:SetHeight(24)
    UI.Wrap(self.controlNote, 2)
    self.controlNote:SetText("These control the sampling that already runs. Nothing here starts a second recorder, and nothing is written to disk until you log out or reload.")

    ------------------------------------------------------------------
    -- Markers
    ------------------------------------------------------------------
    local markers = UI.Card(canvas, "ADD A MARKER", {})
    grid:Add(markers, { span = 2, height = 122, key = "markers" })
    self.markerCard = markers

    local perRow = 3
    for i, quick in ipairs(QUICK_MARKERS) do
        local column = (i - 1) % perRow
        local rowIndex = math.floor((i - 1) / perRow)
        local button = UI.Button(markers.content, quick.label, function()
            WTM.Context:AddMarker("custom", quick.text)
            WTM:Print(("Marker placed: %s"):format(quick.text))
            self:Refresh()
        end, { height = 24, width = 132 })
        button:SetPoint("TOPLEFT", column * 140, -rowIndex * 30)
        button.tooltip = ("Places a marker labelled \"%s\" at the current moment. It appears on the timeline and on every graph that shows markers.")
            :format(quick.text)
    end

    self.markerNote = UI.Text(markers.content, "tiny", "textMuted", "LEFT")
    self.markerNote:SetPoint("BOTTOMLEFT", 0, 0)
    self.markerNote:SetPoint("RIGHT", markers.content, "RIGHT", 0, 0)
    self.markerNote:SetHeight(14)

    self.recentMarkers = UI.TopList(canvas, "RECENT MARKERS", { rows = 5, wideValue = true })
    grid:Add(self.recentMarkers, { span = 1, height = 122, key = "recent" })

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

function Page:Refresh()
    if not self.grid then return end
    self:OnLayout()

    local sampling = WTM.db.profile.sampling
    local running  = WTM.Scheduler:IsRunning() and sampling.enabled
    local duration = GetTime() - (WTM.state.sessionStart or GetTime())
    local session  = WTM.Sessions.current

    self.state:SetState(running and "RECORDING" or "STOPPED",
        running and "ok" or "muted",
        running and "Every sampler is running." or "No sampler is running; nothing new is being measured.")
    self.state:Set("Session", session and ("#%d"):format(session.id) or "-")
    self.state:Set("Duration", Fmt.Duration(duration))
    self.state:Set("Sampling", running and "on" or "off", running and "ok" or "muted")
    self.state:Set("Adaptive burst", WTM.Scheduler:IsBursting()
        and ("active, %.0fs left"):format(WTM.Scheduler:BurstRemaining()) or "idle")

    local stats = WTM.FrameTime:GetSessionStats()
    self.volume:Set("Frames measured", Fmt.Comma(stats.frames or 0))
    self.volume:Set("History buckets", Fmt.Comma(WTM.Recorder:CountBuckets()))
    self.volume:Set("Flight recorder",
        ("%.0f s in the ring"):format(WTM.FlightRecorder:GetCoverageSeconds()))
    self.volume:Set("Incidents", tostring(#WTM.FlightRecorder.incidents))
    self.volume:Set("Markers", tostring(#WTM.Context.markers))

    self.storage:Set("Stored sessions", tostring(#WTM.db.global.sessions))
    self.storage:Set("Stored incidents", tostring(#WTM.db.global.incidents))
    self.storage:Set("Estimated size", Fmt.Bytes(WTM.Database:EstimateSizeBytes()))
    self.storage:Set("Retention", ("%d sessions, %d incidents")
        :format(WTM.db.profile.retention.maxSessions,
                WTM.db.profile.retention.maxIncidents))

    self.startStop:SetText(running and "Stop recording" or "Start recording")
    self.markerNote:SetText(UI.FitText(self.markerNote,
        ("%d marker%s on the timeline so far.")
            :format(#WTM.Context.markers, #WTM.Context.markers == 1 and "" or "s")))

    ------------------------------------------------------------------
    local entries = {}
    local markers = WTM.Context.markers
    for i = #markers, math.max(1, #markers - 4), -1 do
        local marker = markers[i]
        if marker then
            local def = C.MARKERS[marker.kind]
            entries[#entries + 1] = {
                name = marker.label or (def and def.label) or marker.kind,
                value = Fmt.Clock(marker.t, WTM.state.sessionEpoch, WTM.state.sessionStart),
                tone = def and def.tone or nil,
                tooltipTitle = def and def.label or marker.kind,
                tooltipLines = { { "Label", marker.label or "-" } },
            }
        end
    end
    self.recentMarkers:SetEntries(entries,
        "No markers yet. The buttons on the left place one at the current moment.")
end
