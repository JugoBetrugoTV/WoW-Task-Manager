--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Timeline.lua

    Profiler-style stacked tracks on one shared time axis, with a marker lane
    underneath.  Clicking a marker opens the flight recorder incident for that
    moment - which is the whole reason the flight recorder exists.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("timeline", {})

local TRACKS = {
    { key = "fps",    field = "fps",        label = "FPS",        colorIndex = 1, worstIsLow = true,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "frame",  field = "frameMaxMs", label = "FRAME MS",   colorIndex = 2,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "cpu",    field = "cpuMs",      label = "ADDON CPU",  colorIndex = 5,
      format = function(v) return ("%.1f"):format(v) end },
    { key = "events", field = "events",     label = "EVENTS/S",   colorIndex = 6,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "memory", field = "luaKB",      label = "LUA MB",     colorIndex = 4,
      format = function(v) return ("%.0f"):format(v / 1024) end },
    { key = "latency", field = "latW",      label = "WORLD MS",   colorIndex = 3,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "home",    field = "latH",      label = "HOME MS",    colorIndex = 7,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "addonmem", field = "addonKB",  label = "ADDON MB",   colorIndex = 8,
      format = function(v) return ("%.0f"):format(v / 1024) end },
    -- This addon's own cost, on the same axis as everything it measures. If it
    -- ever becomes the tallest track, that is the finding.
    { key = "overhead", field = "wtmMs",    label = "WTM MS/S",   colorIndex = 7,
      format = function(v) return ("%.2f"):format(v) end },
}

local TRACK_HEIGHT = 54

-- Zoom presets. Deliberately fewer than the Performance page offers: the
-- timeline is for locating an event, not for scrubbing a continuum.
Page.ZOOM_LEVELS = {
    { key = "60s",     seconds = 60,   label = "60 s"    },
    { key = "5m",      seconds = 300,  label = "5 min"   },
    { key = "15m",     seconds = 900,  label = "15 min"  },
    { key = "session", seconds = 0,    label = "Session" },
}

-- Every marker kind the timeline can show, with what produces it. Kinds whose
-- source event does not exist on this client are listed as unavailable in the
-- legend rather than silently never appearing.
Page.MARKER_LEGEND = {
    { kind = "fpsdrop",    label = "Frame spike",  cap = nil },
    { kind = "eventstorm", label = "Event storm",  cap = "eventRate" },
    { kind = "netspike",   label = "Latency spike", cap = "latency" },
    { kind = "combat",     label = "Combat",       cap = "combatMarkers" },
    { kind = "encounter",  label = "Encounter",    cap = "encounterMarkers" },
    { kind = "zone",       label = "Zone change",  cap = "zoneMarkers" },
    { kind = "loading",    label = "Loading",      cap = "loadingMarkers" },
}

function Page:Build(frame)
    local pad = M.padding
    self.series = {}

    ------------------------------------------------------------------
    -- Toolbar
    ------------------------------------------------------------------
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(26)
    toolbar:SetPoint("TOPLEFT", pad, -pad)
    toolbar:SetPoint("TOPRIGHT", -pad, -pad)

    local label = UI.Text(toolbar, "small", "textMuted")
    label:SetPoint("LEFT")
    label:SetText("RANGE")

    self.rangeButtons = {}
    local previous
    for _, range in ipairs(Page.ZOOM_LEVELS) do
        local button = UI.Button(toolbar, range.label, function()
            self.range = range.key
            for key, b in pairs(self.rangeButtons) do b:SetSelected(key == range.key) end
            self:Refresh()
        end, { height = 22, minWidth = 52, style = "small" })
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("LEFT", label, "RIGHT", 10, 0)
        end
        button.rangeKey = range.key
        self.rangeButtons[range.key] = button
        previous = button
    end

    -- Legend: which marker kinds this client can actually produce.
    -- Optional per-addon CPU sub-tracks under the shared axis.
    self.addonTracksButton = UI.Button(toolbar, "Addon tracks", function(button)
        Page.showAddonTracks = not Page.showAddonTracks
        button:SetSelected(Page.showAddonTracks)
        Page:RebuildAddonTracks()
        Page:Refresh()
    end, { height = 22, style = "small" })
    self.addonTracksButton:SetPoint("LEFT", previous, "RIGHT", 12, 0)
    self.addonTracksButton.tooltip =
        "Adds a CPU track per addon beneath the shared axis: the addons you have flagged, or the top CPU consumers if you have flagged none. Requires the scriptProfile CVar."
    previous = self.addonTracksButton

    self.legend = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.legend:SetPoint("RIGHT")
    self.legend:SetPoint("LEFT", previous, "RIGHT", 16, 0)
    self.legend:SetJustifyH("RIGHT")

    self:RefreshLegend()

    ------------------------------------------------------------------
    -- Track stack
    ------------------------------------------------------------------
    local stack = CreateFrame("Frame", nil, frame)
    stack:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -10)
    stack:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -10)
    stack:SetHeight(#TRACKS * TRACK_HEIGHT)
    self.stack = stack

    self.tracks = {}
    for i, spec in ipairs(TRACKS) do
        local track = UI.Graph(stack, {
            showAxis = false,
            showGrid = true,
            padLeft = 76,
            valueFormat = spec.format,
            worstIsLow = spec.worstIsLow,
            border = false,
        })
        track:SetHeight(TRACK_HEIGHT)
        track:SetPoint("TOPLEFT", 0, -(i - 1) * TRACK_HEIGHT)
        track:SetPoint("TOPRIGHT", 0, -(i - 1) * TRACK_HEIGHT)
        UI.Border(track, "B", "borderSubtle")

        track.nameText = UI.Text(track, "small", "textSecondary")
        track.nameText:SetPoint("TOPLEFT", 8, -6)
        track.nameText:SetText(spec.label)

        track.currentText = UI.Text(track, "numericSm", "textPrimary")
        track.currentText:SetPoint("TOPLEFT", 8, -22)

        track.spec = spec
        self.tracks[i] = track
        self.series[spec.key] = { values = {}, times = {} }
    end

    ------------------------------------------------------------------
    -- Per-addon sub-tracks
    ------------------------------------------------------------------
    self.addonTrackHost = CreateFrame("Frame", nil, frame)
    self.addonTrackHost:SetPoint("TOPLEFT", stack, "BOTTOMLEFT", 0, 0)
    self.addonTrackHost:SetPoint("TOPRIGHT", stack, "BOTTOMRIGHT", 0, 0)
    self.addonTrackHost:SetHeight(1)
    self.addonTracks = {}
    self.addonSeries = {}

    ------------------------------------------------------------------
    -- Marker lane
    ------------------------------------------------------------------
    local lane = UI.Panel(frame, { color = "panelBg" })
    lane:SetHeight(38)
    lane:SetPoint("TOPLEFT", self.addonTrackHost, "BOTTOMLEFT", 0, -6)
    lane:SetPoint("TOPRIGHT", self.addonTrackHost, "BOTTOMRIGHT", 0, -6)
    self.lane = lane

    lane.label = UI.Text(lane, "small", "textMuted")
    lane.label:SetPoint("LEFT", 8, 0)
    lane.label:SetText("EVENTS")

    lane.plot = CreateFrame("Frame", nil, lane)
    lane.plot:SetPoint("TOPLEFT", 76, 0)
    lane.plot:SetPoint("BOTTOMRIGHT", -8, 0)

    self.markerButtons = {}

    ------------------------------------------------------------------
    -- Incident detail below
    ------------------------------------------------------------------
    local detail = UI.Panel(frame, { color = "panelBg" })
    detail:SetPoint("TOPLEFT", lane, "BOTTOMLEFT", 0, -M.cardGap)
    detail:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
    self.detail = detail

    detail.title = UI.Text(detail, "title", "textPrimary")
    detail.title:SetPoint("TOPLEFT", M.padding, -12)

    detail.subtitle = UI.Text(detail, "small", "textSecondary")
    detail.subtitle:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)

    detail.body = UI.Text(detail, "small", "textSecondary")
    detail.body:SetPoint("TOPLEFT", detail.subtitle, "BOTTOMLEFT", 0, -10)
    detail.body:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -M.padding, M.padding)
    detail.body:SetJustifyH("LEFT")
    detail.body:SetJustifyV("TOP")
    -- A multi-line description in a box that is bounded on all four sides. It
    -- wraps: clipping each line at the right edge would cut off the half of a
    -- sentence that says what the number means.
    UI.Wrap(detail.body, 0)

    ------------------------------------------------------------------
    -- Range inspector
    ------------------------------------------------------------------
    -- Drag across any track to mark a span; the panel then summarises just
    -- that span. This is what turns the timeline from a picture into
    -- something you can ask a question of.
    self.inspector = UI.StatCard(detail, "SELECTED RANGE", {
        "Span", "Average FPS", "Worst frame", "Average world latency",
        "Peak addon CPU", "Events at peak", "Lua memory change",
    })
    self.inspector:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -M.padding, -12)
    self.inspector:SetWidth(280)
    self.inspector:SetPoint("BOTTOM", detail, "BOTTOM", 0, M.padding)
    self.inspector:Hide()

    self.inspectorClear = UI.Button(self.inspector, "clear", function()
        Page:ClearSelection()
    end, { height = 18, style = "tiny", minWidth = 46 })
    self.inspectorClear:SetPoint("TOPRIGHT", -6, -4)

    -- Selection is captured on the first track, which shares its time axis
    -- with every other one. One handler, not one per track.
    local firstTrack = self.tracks[1]
    if firstTrack then
        firstTrack:EnableMouse(true)
        firstTrack:RegisterForDrag("LeftButton")
        firstTrack:SetScript("OnDragStart", function(track)
            Page.dragStartX = Page:CursorFraction(track)
        end)
        firstTrack:SetScript("OnDragStop", function(track)
            local a, b = Page.dragStartX, Page:CursorFraction(track)
            Page.dragStartX = nil
            if not (a and b) then return end
            if math.abs(a - b) < 0.01 then return end
            Page:SetSelection(math.min(a, b), math.max(a, b))
        end)
    end

    self.range = "5m"
    self.rangeButtons["5m"]:SetSelected(true)
end

--- Where the cursor sits across `frame`, as 0..1. Returns nil when the frame
--- has no resolvable geometry, rather than a fabricated 0.
function Page:CursorFraction(frame)
    local left = frame:GetLeft()
    local width = frame:GetWidth()
    if not left or not width or width <= 0 then return nil end
    local x = GetCursorPosition() / (frame:GetEffectiveScale() or 1)
    return math.max(0, math.min(1, (x - left) / width))
end

--- Marks a span of the visible window, as two fractions of it.
function Page:SetSelection(fromFraction, toFraction)
    self.selection = { from = fromFraction, to = toFraction }
    self:Refresh()
end

function Page:ClearSelection()
    self.selection = nil
    if self.inspector then self.inspector:Hide() end
    self:Refresh()
end

--- Summarises the selected span from the recorded series. Reads the same
--- buckets the tracks draw, so the numbers cannot disagree with the picture.
function Page:RefreshInspector(fromTime, toTime)
    if not self.selection or not self.inspector then
        if self.inspector then self.inspector:Hide() end
        return
    end

    local span = toTime - fromTime
    local a = fromTime + span * self.selection.from
    local b = fromTime + span * self.selection.to
    self.inspector:Show()

    local values, times = self._inspectValues or {}, self._inspectTimes or {}
    self._inspectValues, self._inspectTimes = values, times

    --- The extreme of one field over the selection, or nil when the selection
    --- contains no recorded bucket at all.
    local function extreme(field, wantMin)
        WTM.Recorder:GetSeries(field, a, b, 0, values, times)
        if #values == 0 then return nil end
        local best = values[1]
        for i = 2, #values do
            if (wantMin and values[i] < best) or (not wantMin and values[i] > best) then
                best = values[i]
            end
        end
        return best
    end

    local function mean(field)
        WTM.Recorder:GetSeries(field, a, b, 0, values, times)
        if #values == 0 then return nil end
        local sum = 0
        for i = 1, #values do sum = sum + values[i] end
        return sum / #values
    end

    local function set(label, value, formatter)
        if value == nil then
            self.inspector:Set(label, "no data", "muted")
        else
            self.inspector:Set(label, formatter(value))
        end
    end

    self.inspector:Set("Span", Fmt.Duration(b - a))
    set("Average FPS", mean("fps"), function(v) return Fmt.FPS(v) end)
    set("Worst frame", extreme("frameMaxMs", false), function(v) return Fmt.Ms(v) end)
    set("Average world latency", mean("latW"), function(v) return ("%d ms"):format(v) end)
    set("Peak addon CPU", WTM.CPU.available and extreme("cpuMs", false) or nil,
        function(v) return ("%.2f %%"):format(v) end)
    set("Events at peak", extreme("events", false), function(v) return Fmt.Rate(v) end)

    -- Memory is a level, so the interesting figure is the change across the
    -- span rather than its extreme.
    WTM.Recorder:GetSeries("luaKB", a, b, 0, values, times)
    if #values >= 2 then
        self.inspector:Set("Lua memory change",
            Fmt.MemoryDelta(values[#values] - values[1]))
    else
        self.inspector:Set("Lua memory change", "no data", "muted")
    end
end

--- Which addons get their own track: the ones you flagged, or the top CPU
--- consumers when you have flagged none.
local ADDON_TRACK_LIMIT = 3
local ADDON_TRACK_HEIGHT = 40

--- Rebuilds the marker legend and fits it to the toolbar.
---
--- Its contents depend on what this client can produce, and its available width
--- depends on the window size, so it is rebuilt on every layout rather than
--- once at build time - fitted to the default width and then never revisited,
--- it ran off the end of the toolbar at the minimum window size.
function Page:RefreshLegend()
    if not self.legend then return end
    local parts = {}
    for _, entry in ipairs(Page.MARKER_LEGEND) do
        local available = (not entry.cap) or WTM.Caps:Has(entry.cap)
        local def = C.MARKERS[entry.kind]
        if available then
            parts[#parts + 1] = ("|cff%s%s|r %s")
                :format(Theme:ToneHex(def and def.tone or "muted"),
                        def and def.glyph or "|", entry.label)
        else
            parts[#parts + 1] = ("|cff5d6675%s unavailable|r"):format(entry.label)
        end
    end
    self.legend:SetText(UI.FitText(self.legend, table.concat(parts, "   ")))
end

--- Brings one addon's CPU up as its own track. Called when another page hands
--- an addon over ("show on timeline").
function Page:FocusAddon(name)
    self.focusAddon = name
    self.showAddonTracks = true
    if self.addonTracksButton then self.addonTracksButton:SetSelected(true) end
    self:RebuildAddonTracks()
    self:Refresh()
end

function Page:PickTrackedAddons(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not WTM.CPU.available then return out end

    -- An addon handed over from another page leads, whether or not it is
    -- flagged: "show me this one" should put it first, not somewhere in a list.
    if self.focusAddon then
        local record = WTM.Processes:Get(self.focusAddon)
        if record and record.loaded then out[#out + 1] = record end
    end

    for _, record in WTM.Processes:Iterate() do
        if record.loaded and WTM.Database:IsWatched(record.name)
            and record.name ~= self.focusAddon and #out < ADDON_TRACK_LIMIT then
            out[#out + 1] = record
        end
    end
    if #out > 0 then return out end

    local top = WTM.CPU:GetTopConsumers(self._topScratch or {}, ADDON_TRACK_LIMIT)
    self._topScratch = top
    for i = 1, #top do
        local record = WTM.Processes:Get(top[i].name)
        if record then out[#out + 1] = record end
    end
    return out
end

function Page:RebuildAddonTracks()
    local records = self:PickTrackedAddons(self._trackedScratch or {})
    self._trackedScratch = records

    local count = self.showAddonTracks and #records or 0
    self.addonTrackHost:SetHeight(count > 0 and (count * ADDON_TRACK_HEIGHT) or 1)

    for i = 1, math.max(count, #self.addonTracks) do
        local track = self.addonTracks[i]
        if i <= count then
            if not track then
                track = UI.Graph(self.addonTrackHost, {
                    showAxis = false,
                    showGrid = false,
                    padLeft = 76,
                    border = false,
                    valueFormat = function(v) return ("%.2f %%"):format(v) end,
                })
                track:SetHeight(ADDON_TRACK_HEIGHT)
                UI.Border(track, "B", "borderSubtle")
                track.nameText = UI.Text(track, "small", "textSecondary")
                track.nameText:SetPoint("TOPLEFT", 8, -5)
                track.currentText = UI.Text(track, "numericSm", "textPrimary")
                track.currentText:SetPoint("TOPLEFT", 8, -20)
                self.addonTracks[i] = track
                self.addonSeries[i] = {}
            end
            track:ClearAllPoints()
            track:SetPoint("TOPLEFT", 0, -(i - 1) * ADDON_TRACK_HEIGHT)
            track:SetPoint("TOPRIGHT", 0, -(i - 1) * ADDON_TRACK_HEIGHT)
            track:Show()
            track.record = records[i]
            -- Detail rings are allocated lazily; a tracked addon needs one.
            WTM.Processes.EnsureRings(records[i])
        elseif track then
            track:Hide()
            track.record = nil
        end
    end
end

function Page:RefreshAddonTracks()
    if not self.showAddonTracks then return end
    local redraw = UI.MainWindow:ShouldRedrawGraphs()

    for i, track in ipairs(self.addonTracks) do
        local record = track.record
        if record and track:IsShown() then
            local values = self.addonSeries[i]
            for j = #values, 1, -1 do values[j] = nil end
            local ring = record.cpuRing
            if ring then
                for j = 1, ring.count do values[j] = ring:Get(j) end
            end
            track:SetSeries(1, values, nil,
                { label = record.titleClean, colorIndex = 5 + i })
            track.nameText:SetText(Fmt.Truncate(record.titleClean, 16))
            track.currentText:SetText(("%.2f %%"):format(record.cpuEma or 0))
            track.currentText:SetTextColor(Theme:Series(5 + i))
            if redraw then
                track.dirty = true
                track:Draw()
            end
        end
    end
end

function Page:OnShow()
    self:RebuildAddonTracks()
    self:Refresh()
end

--------------------------------------------------------------------------

local markerScratch = {}

local function AcquireMarkerButton(page, index)
    local button = page.markerButtons[index]
    if button then return button end

    button = CreateFrame("Button", nil, page.lane.plot)
    button:SetSize(12, 28)
    button.tick = button:CreateTexture(nil, "ARTWORK")
    button.tick:SetWidth(2)
    button.tick:SetPoint("TOP")
    button.tick:SetPoint("BOTTOM")
    button.glyph = UI.Text(button, "tiny", "textPrimary", "CENTER")
    button.glyph:SetPoint("TOP", 0, 0)

    button:SetScript("OnEnter", function(self)
        if not self.marker then return end
        local def = C.MARKERS[self.marker.kind]
        UI.TooltipClear(def and def.label or self.marker.kind)
        UI.TooltipLine(self.marker.label or "")
        UI.TooltipLine("Time", Fmt.Ago(GetTime() - self.marker.t))
        if self.spike then
            UI.TooltipLine("", "")
            for line in WTM.SpikeDetector:Describe(self.spike):gmatch("[^\n]+") do
                UI.TooltipLine(line)
            end
        end
        UI.TooltipShow(self)
    end)
    button:SetScript("OnLeave", UI.HideTooltip)
    button:SetScript("OnClick", function(self)
        if not self.spike then return end
        page:ShowIncident(self.spike)
        -- The full record lives on the Incidents page; jump there with the
        -- right cluster already selected rather than duplicating it here.
        if self.spike.clusterId then
            local cluster = WTM.SpikeDetector:GetCluster(self.spike.clusterId)
            if cluster then
                UI.Pages.incidents.selected = cluster
            end
        end
    end)

    page.markerButtons[index] = button
    return button
end

function Page:Refresh()
    if not self.tracks then return end

    local now = GetTime()
    -- Cheap, and the toolbar width may have changed since the last refresh.
    self:RefreshLegend()

    local rangeSeconds
    for _, range in ipairs(Page.ZOOM_LEVELS) do
        if range.key == self.range then rangeSeconds = range.seconds end
    end
    if not rangeSeconds or rangeSeconds == 0 then
        rangeSeconds = math.max(60, now - (WTM.state.sessionStart or now))
    end
    local fromTime = now - rangeSeconds

    ------------------------------------------------------------------
    -- Tracks
    ------------------------------------------------------------------
    local redraw = UI.MainWindow:ShouldRedrawGraphs()
    local trackCount = #self.tracks
    for trackIndex, track in ipairs(self.tracks) do
        local spec = track.spec
        local series = self.series[spec.key]

        local unavailable
        if spec.key == "cpu" and not WTM.CPU.available then
            unavailable = WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
        elseif spec.key == "latency" and not WTM.Caps:Has("latency") then
            unavailable = C.TXT_UNAVAILABLE_CLIENT
        elseif spec.key == "events" and not WTM.Events.available then
            unavailable = C.TXT_UNAVAILABLE_CLIENT
        end

        if unavailable then
            track:ClearSeries()
            track.currentText:SetText(unavailable)
            track.currentText:SetTextColor(T("textMuted"))
        else
            WTM.Recorder:GetSeries(spec.field, fromTime, now, 320, series.values, series.times)
            track:SetSeries(1, series.values, series.times, { colorIndex = spec.colorIndex, label = spec.label })
            local latest = series.values[#series.values]
            track.currentText:SetText(latest and spec.format(latest) or "-")
            track.currentText:SetTextColor(Theme:Series(spec.colorIndex))
        end

        track:SetTimeRange(fromTime, now)
        if redraw and UI.MainWindow:TakeGraphSlot(trackIndex, trackCount) then
            track.dirty = true
            track:Draw()
        end
    end

    self:RefreshAddonTracks()

    ------------------------------------------------------------------
    -- Markers
    ------------------------------------------------------------------
    -- The inspector reads the same window the tracks just drew, so its numbers
    -- and the picture cannot disagree.
    self:RefreshInspector(fromTime, now)

    WTM.Context:GetMarkersInRange(fromTime, now, markerScratch)

    local spikes = WTM.SpikeDetector:GetInRange(fromTime, now, self._spikes or {})
    self._spikes = spikes
    -- Match a marker back to its spike so clicking it can open the incident.
    local spikeByTime = {}
    for i = 1, #spikes do
        spikeByTime[math.floor(spikes[i].t * 4)] = spikes[i]
    end

    local width = self.lane.plot:GetWidth() or 1
    local span = now - fromTime

    for i = 1, #markerScratch do
        local marker = markerScratch[i]
        local button = AcquireMarkerButton(self, i)
        local fraction = span > 0 and ((marker.t - fromTime) / span) or 0
        local def = C.MARKERS[marker.kind]

        button:ClearAllPoints()
        button:SetPoint("CENTER", self.lane.plot, "LEFT", fraction * width, 0)
        button.tick:SetColorTexture(Theme:Tone(def and def.tone or "muted"))
        button.glyph:SetText(def and def.glyph or "|")
        button.glyph:SetTextColor(Theme:Tone(def and def.tone or "muted"))
        button.marker = marker
        button.spike = spikeByTime[math.floor(marker.t * 4)]
        button:Show()
    end
    for i = #markerScratch + 1, #self.markerButtons do
        self.markerButtons[i]:Hide()
    end

    ------------------------------------------------------------------
    -- Selected incident
    ------------------------------------------------------------------
    if not self.selectedSpike and #spikes > 0 then
        self:ShowIncident(spikes[#spikes])
    elseif not self.selectedSpike then
        self.detail.title:SetText("No incident selected")
        self.detail.subtitle:SetText(
            ("The flight recorder is holding %s of history. When a spike is detected, the %ds before and %ds after it are captured automatically.")
            :format(Fmt.Duration(WTM.FlightRecorder:GetCoverageSeconds()),
                    WTM.db.profile.flightRecorder.preWindow,
                    WTM.db.profile.flightRecorder.postWindow))
        self.detail.body:SetText("")
    end
end

function Page:ShowIncident(spike)
    self.selectedSpike = spike
    local detail = self.detail

    detail.title:SetText(("%s at %s"):format(spike.label,
        Fmt.Clock(spike.t, WTM.state.sessionEpoch, WTM.state.sessionStart)))
    detail.title:SetTextColor(Theme:Tone(
        spike.kind == "freeze" and "crit" or (spike.kind == "heavy" and "crit" or "warn")))

    local context = spike.context or {}
    local contextParts = {}
    if context.zone then contextParts[#contextParts + 1] = context.zone end
    if context.instanceType and context.instanceType ~= "none" then
        contextParts[#contextParts + 1] = context.instanceName or context.instanceType
    end
    if context.encounter then contextParts[#contextParts + 1] = "Encounter: " .. context.encounter end
    contextParts[#contextParts + 1] = context.combat and "in combat" or "out of combat"
    if (context.groupSize or 0) > 1 then
        contextParts[#contextParts + 1] = ("group of %d"):format(context.groupSize)
    end
    if context.loading then contextParts[#contextParts + 1] = "loading screen" end
    detail.subtitle:SetText(table.concat(contextParts, "  -  "))

    local lines = {}
    lines[#lines + 1] = WTM.SpikeDetector:Describe(spike)

    local candidates = WTM.Correlation:ForSpike(spike, self._candidates or {})
    self._candidates = candidates
    if #candidates > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Correlation across this session:"
        for i = 1, math.min(4, #candidates) do
            local entry = candidates[i]
            local hex = Theme:ToneHex(entry.tone)
            if entry.sessionPhi then
                lines[#lines + 1] = ("   |cff%s%s|r  %s  -  phi %.2f over %d spikes")
                    :format(hex, entry.label, entry.title, entry.sessionPhi, entry.sessionSpikes or 0)
            else
                lines[#lines + 1] = ("   |cff%s%s|r  %s"):format(hex, entry.label, entry.title)
            end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cff5d6675These are associations measured across the session, not demonstrated causes. A spike with no elevated addon is consistent with work outside addon Lua entirely.|r"
    end

    if spike.incidentId then
        local incident = WTM.FlightRecorder:GetIncident(spike.incidentId)
        if incident then
            lines[#lines + 1] = ""
            lines[#lines + 1] = ("|cff5d6675Flight recorder incident #%d: %d samples covering -%ds to +%ds around this spike.|r")
                :format(incident.id, #incident.samples, incident.preWindow, incident.postWindow)
        end
    end

    detail.body:SetText(table.concat(lines, "\n"))
end
