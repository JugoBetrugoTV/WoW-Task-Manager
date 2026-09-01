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
    { key = "fps",    field = "fps",        label = "FPS",        colorIndex = 1,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "frame",  field = "frameMaxMs", label = "FRAME MS",   colorIndex = 2, invert = true,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "cpu",    field = "cpuMs",      label = "ADDON CPU",  colorIndex = 5,
      format = function(v) return ("%.1f"):format(v) end },
    { key = "events", field = "events",     label = "EVENTS/S",   colorIndex = 6,
      format = function(v) return ("%.0f"):format(v) end },
    { key = "memory", field = "luaKB",      label = "LUA MB",     colorIndex = 4,
      format = function(v) return ("%.0f"):format(v / 1024) end },
    { key = "latency", field = "latW",      label = "LATENCY",    colorIndex = 3,
      format = function(v) return ("%.0f"):format(v) end },
}

local TRACK_HEIGHT = 54

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
    for _, range in ipairs(C.TIME_RANGES) do
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

    self.legend = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.legend:SetPoint("RIGHT")
    self.legend:SetText("click a marker to open its incident")

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
            invertBetter = spec.invert,
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
    -- Marker lane
    ------------------------------------------------------------------
    local lane = UI.Panel(frame, { color = "panelBg" })
    lane:SetHeight(38)
    lane:SetPoint("TOPLEFT", stack, "BOTTOMLEFT", 0, -6)
    lane:SetPoint("TOPRIGHT", stack, "BOTTOMRIGHT", 0, -6)
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

    self.range = "5m"
    self.rangeButtons["5m"]:SetSelected(true)
end

function Page:OnShow() self:Refresh() end

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
        if self.spike then page:ShowIncident(self.spike) end
    end)

    page.markerButtons[index] = button
    return button
end

function Page:Refresh()
    if not self.tracks then return end

    local now = GetTime()
    local rangeSeconds
    for _, range in ipairs(C.TIME_RANGES) do
        if range.key == self.range then rangeSeconds = range.seconds end
    end
    if not rangeSeconds or rangeSeconds == 0 then
        rangeSeconds = math.max(60, now - (WTM.state.sessionStart or now))
    end
    local fromTime = now - rangeSeconds

    ------------------------------------------------------------------
    -- Tracks
    ------------------------------------------------------------------
    for _, track in ipairs(self.tracks) do
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
        track.dirty = true
        track:Draw()
    end

    ------------------------------------------------------------------
    -- Markers
    ------------------------------------------------------------------
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
    detail.subtitle:SetText(table.concat(contextParts, "   -   "))

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
