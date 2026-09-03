--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Settings.lua

    Settings, built from the same widgets as the rest of the window rather than
    an AceConfig dialog - the point of the whole UI is that it is one piece.

    Everything that changes a sampling rate applies immediately through the
    scheduler; the two that cannot (the flight recorder ring size and the
    scriptProfile CVar) say what they need.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("settings", {})

--------------------------------------------------------------------------
-- Small controls, local to this page
--------------------------------------------------------------------------

local function Checkbox(parent, label, get, set, description)
    local frame = CreateFrame("Button", nil, parent)
    frame:SetHeight(22)

    local box = frame:CreateTexture(nil, "ARTWORK")
    box:SetSize(12, 12)
    box:SetPoint("LEFT", 0, 0)

    local tick = frame:CreateTexture(nil, "OVERLAY")
    tick:SetSize(6, 6)
    tick:SetPoint("CENTER", box, "CENTER")

    local text = UI.Text(frame, "body", "textSecondary")
    text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    text:SetText(label)

    local function Update()
        local value = get()
        box:SetColorTexture(T(value and "accentSoft" or "panelAlt"))
        tick:SetColorTexture(T("accent"))
        tick:SetShown(value)
        text:SetTextColor(T(value and "textPrimary" or "textSecondary"))
    end

    frame:SetScript("OnClick", function()
        set(not get())
        Update()
    end)
    frame:SetScript("OnEnter", function(self)
        if description then UI.ShowTooltip(self, label, description) end
    end)
    frame:SetScript("OnLeave", UI.HideTooltip)

    frame.Update = Update
    Update()
    return frame
end

local function Slider(parent, label, minValue, maxValue, step, get, set, format, description)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(38)

    local text = UI.Text(frame, "small", "textSecondary")
    text:SetPoint("TOPLEFT")
    text:SetText(label)

    local value = UI.Text(frame, "numeric", "textPrimary", "RIGHT")
    value:SetPoint("TOPRIGHT")

    local track = CreateFrame("Frame", nil, frame)
    track:SetHeight(4)
    track:SetPoint("BOTTOMLEFT", 0, 8)
    track:SetPoint("BOTTOMRIGHT", 0, 8)
    local trackTex = track:CreateTexture(nil, "BACKGROUND")
    trackTex:SetAllPoints()
    trackTex:SetColorTexture(T("panelAlt"))

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT")
    fill:SetPoint("BOTTOMLEFT")
    fill:SetColorTexture(T("accent"))

    local knob = CreateFrame("Button", nil, track)
    knob:SetSize(10, 10)
    local knobTex = knob:CreateTexture(nil, "OVERLAY")
    knobTex:SetAllPoints()
    knobTex:SetColorTexture(T("textPrimary"))

    local function Update()
        local current = get()
        local fraction = (current - minValue) / math.max(0.0001, maxValue - minValue)
        fraction = math.max(0, math.min(1, fraction))
        local width = track:GetWidth() or 200
        fill:SetWidth(math.max(1, width * fraction))
        knob:ClearAllPoints()
        knob:SetPoint("CENTER", track, "LEFT", width * fraction, 0)
        value:SetText(format and format(current) or tostring(current))
    end

    local dragging
    local function Apply()
        local x = GetCursorPosition() / UIParent:GetEffectiveScale() - track:GetLeft()
        local fraction = math.max(0, math.min(1, x / math.max(1, track:GetWidth())))
        local newValue = minValue + fraction * (maxValue - minValue)
        newValue = math.floor(newValue / step + 0.5) * step
        set(newValue)
        Update()
    end

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function() dragging = true Apply() end)
    track:SetScript("OnMouseUp", function() dragging = false end)
    track:SetScript("OnUpdate", function() if dragging then Apply() end end)
    knob:SetScript("OnMouseDown", function() dragging = true end)
    knob:SetScript("OnMouseUp", function() dragging = false end)

    if description then
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", function(self) UI.ShowTooltip(self, label, description) end)
        frame:SetScript("OnLeave", UI.HideTooltip)
    end

    frame.Update = Update
    frame:SetScript("OnShow", Update)
    Update()
    return frame
end

--- Segmented choice control, for the settings that are an enum rather than a
--- number or a flag.
local function Segmented(parent, label, options, get, set, description)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(44)

    local text = UI.Text(frame, "small", "textSecondary")
    text:SetPoint("TOPLEFT")
    text:SetText(label)

    local detail = UI.Text(frame, "tiny", "textMuted")
    detail:SetPoint("TOPRIGHT")
    detail:SetJustifyH("RIGHT")

    local buttons = {}
    local previous
    for _, option in ipairs(options) do
        local button = UI.Button(frame, option.label, function()
            set(option.key)
            frame.Update()
        end, { height = 22, minWidth = 72, style = "small" })
        button:SetPoint("BOTTOMLEFT", previous and 0 or 0, 0)
        if previous then
            button:ClearAllPoints()
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("BOTTOMLEFT")
        end
        button.optionKey = option.key
        button.optionDetail = option.detail
        buttons[#buttons + 1] = button
        previous = button
    end

    function frame.Update()
        local current = get()
        for _, button in ipairs(buttons) do
            button:SetSelected(button.optionKey == current)
            if button.optionKey == current then
                detail:SetText(button.optionDetail or "")
            end
        end
    end

    if description then
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", function(self) UI.ShowTooltip(self, label, description) end)
        frame:SetScript("OnLeave", UI.HideTooltip)
    end

    frame.Update()
    return frame
end

--- A button that will not act on a single click.
---
--- Destructive controls sit on the same page as harmless ones, and the page is
--- scrollable, so a misplaced click is a normal accident rather than an exotic
--- one. The first click only arms the button; it disarms itself after a few
--- seconds so a forgotten arm cannot be confirmed later by an unrelated click.
local function ConfirmButton(parent, label, onConfirm, opts)
    opts = opts or {}
    local button
    button = UI.Button(parent, label, function()
        if not button.armed then
            button.armed = true
            button:SetText("Click again to confirm")
            WTM:ScheduleTimer(function()
                if button.armed then
                    button.armed = false
                    button:SetText(button.baseLabel or label)
                end
            end, 5)
            return
        end
        button.armed = false
        button:SetText(button.baseLabel or label)
        onConfirm()
    end, opts)
    button.baseLabel = label
    button.isConfirmButton = true
    return button
end

--------------------------------------------------------------------------

function Page:Build(frame)
    local pad = M.padding
    self.controls = {}

    local scroll = CreateFrame("ScrollFrame", nil, frame)
    scroll:SetPoint("TOPLEFT", pad, -pad)
    scroll:SetPoint("BOTTOMRIGHT", -pad, pad)

    local canvas = CreateFrame("Frame", nil, scroll)
    canvas:SetSize(1, 1)
    scroll:SetScrollChild(canvas)
    self.canvas = canvas
    self.scroll = scroll

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local newOffset = self:GetVerticalScroll() - delta * 40
        local max = math.max(0, (canvas:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.max(0, math.min(max, newOffset)))
    end)

    local y = 0
    local COLUMN = 520

    local function AddSection(title)
        local divider = UI.Divider(canvas, title)
        divider:SetPoint("TOPLEFT", 0, -y)
        divider:SetWidth(COLUMN)
        y = y + 26
        return divider
    end

    local function Add(control, height)
        control:SetPoint("TOPLEFT", 0, -y)
        control:SetWidth(COLUMN)
        y = y + (height or control:GetHeight() or 24) + 4
        self.controls[#self.controls + 1] = control
        return control
    end

    local profile = WTM.db.profile

    ------------------------------------------------------------------
    AddSection("MONITORING")
    Add(Checkbox(canvas, "Enable sampling",
        function() return profile.sampling.enabled end,
        function(v)
            profile.sampling.enabled = v
            if v then WTM.Scheduler:Start() else WTM.Scheduler:Stop() end
        end,
        "Stops every sampling task. The addon keeps its data but records nothing new."))

    Add(Checkbox(canvas, "Adaptive sampling around spikes",
        function() return profile.sampling.adaptive end,
        function(v) profile.sampling.adaptive = v end,
        "When a spike is detected, sampling rates temporarily increase for a few seconds so the window around it is dense, then drop back. This is what makes a flight recorder incident detailed without paying for that detail all the time."))

    Add(Checkbox(canvas, "Automatically throttle if overhead exceeds the budget",
        function() return profile.sampling.autoThrottle end,
        function(v)
            profile.sampling.autoThrottle = v
            if not v then WTM.Scheduler:ReloadIntervals() end
        end,
        "If this addon's own sampling cost stays above the budget for several seconds, the sampling intervals are stretched automatically. Frame time sampling is never throttled - it is cheap and it is the signal everything else depends on."))

    Add(Slider(canvas, "Overhead budget", 0.5, 10, 0.5,
        function() return profile.sampling.overheadBudgetMs end,
        function(v) profile.sampling.overheadBudgetMs = v end,
        function(v) return ("%.1f ms/s"):format(v) end,
        "How much CPU time per second this addon is allowed to spend on sampling before it throttles itself. 2 ms/s is roughly 0.2% of one core."))

    ------------------------------------------------------------------
    AddSection("SAMPLING INTERVALS")
    local INTERVALS = {
        { key = "frametime", label = "Frame time", min = 0.1,  max = 2,  step = 0.05,
          desc = "How often the per-frame accumulators are closed into a sample. The per-frame work itself happens every frame regardless; this only controls how finely it is bucketed." },
        { key = "cpu",       label = "Addon CPU",  min = 0.5,  max = 10, step = 0.5,
          desc = "How often every addon's CPU counter is read. Costs roughly proportional to your addon count." },
        { key = "memory",    label = "Addon memory", min = 5,  max = 120, step = 5,
          desc = "How often UpdateAddOnMemoryUsage runs. This is the single most expensive call the addon makes - it walks the entire Lua heap - so it is deliberately infrequent." },
        { key = "events",    label = "Event rates", min = 0.25, max = 5, step = 0.25,
          desc = "How often event counters are turned into rates. The counting itself is per-event and unaffected." },
        { key = "luamem",    label = "Lua heap",   min = 0.5,  max = 10, step = 0.5,
          desc = "How often collectgarbage(\"count\") is read. Very cheap; this also determines how precisely garbage collections can be spotted in the curve." },
        { key = "network",   label = "Network",    min = 1,    max = 30, step = 1,
          desc = "How often GetNetStats is read. The client only refreshes it about every 30 seconds, so anything faster returns the same numbers." },
        { key = "ui",        label = "UI refresh", min = 0.1,  max = 2,  step = 0.1,
          desc = "How often the visible page redraws. Only runs while the window is open." },
    }
    for _, spec in ipairs(INTERVALS) do
        Add(Slider(canvas, spec.label, spec.min, spec.max, spec.step,
            function() return profile.sampling.intervals[spec.key] end,
            function(v)
                profile.sampling.intervals[spec.key] = v
                WTM.Scheduler:SetInterval(spec.key, v)
            end,
            function(v) return ("%.2f s"):format(v) end,
            spec.desc))
    end

    ------------------------------------------------------------------
    AddSection("SPIKE THRESHOLDS")
    local thresholdNote = UI.Text(canvas, "tiny", "textMuted")
    thresholdNote:SetPoint("TOPLEFT", 0, -y)
    thresholdNote:SetWidth(COLUMN)
    thresholdNote:SetJustifyH("LEFT")
    UI.Wrap(thresholdNote)
    thresholdNote:SetText("A frame counts as a spike only when it exceeds BOTH the absolute floor and the multiple of the rolling baseline. The floor stops a 144 Hz player from drowning in false positives; the multiplier stops a 25 Hz player from never seeing one.")
    y = y + 34

    for _, kind in ipairs({ "minor", "stutter", "heavy", "freeze" }) do
        Add(Slider(canvas, C.SPIKE_DEFAULTS[kind].label .. " - floor", 10, 500, 5,
            function() return profile.spikes[kind].absMs end,
            function(v)
                profile.spikes[kind].absMs = v
                WTM.FrameTime:RefreshThresholds()
            end,
            function(v) return ("%d ms"):format(v) end))
        Add(Slider(canvas, C.SPIKE_DEFAULTS[kind].label .. " - baseline multiple", 1.2, 15, 0.1,
            function() return profile.spikes[kind].mult end,
            function(v)
                profile.spikes[kind].mult = v
                WTM.FrameTime:RefreshThresholds()
            end,
            function(v) return ("%.1f x"):format(v) end))
    end

    ------------------------------------------------------------------
    AddSection("FLIGHT RECORDER")
    Add(Checkbox(canvas, "Enable flight recorder",
        function() return profile.flightRecorder.enabled end,
        function(v)
            profile.flightRecorder.enabled = v
            WTM.FlightRecorder.enabled = v
        end,
        "Continuously keeps the last minute of detailed samples in a pre-allocated ring buffer, so that when a spike happens the time BEFORE it is already recorded."))

    Add(Slider(canvas, "Capture before a spike", 5, 60, 5,
        function() return profile.flightRecorder.preWindow end,
        function(v) profile.flightRecorder.preWindow = v end,
        function(v) return ("%d s"):format(v) end,
        "Changing this resizes the ring buffer, which takes effect after a reload."))

    Add(Slider(canvas, "Capture after a spike", 5, 60, 5,
        function() return profile.flightRecorder.postWindow end,
        function(v) profile.flightRecorder.postWindow = v end,
        function(v) return ("%d s"):format(v) end,
        "The incident is only written out once this window has elapsed, so it includes the recovery as well as the run-up."))

    Add(Checkbox(canvas, "Save incidents between sessions",
        function() return profile.flightRecorder.persist end,
        function(v) profile.flightRecorder.persist = v end,
        "Saved incidents are downsampled to 1 Hz on the way into SavedVariables. The full-resolution version stays in memory for the current session."))

    ------------------------------------------------------------------
    AddSection("EVENT MONITORING")
    Add(Segmented(canvas, "Event monitoring mode", {
        { key = "OFF",      label = "Off",
          detail = "no listener registered" },
        { key = "NORMAL",   label = "Normal",
          detail = "counts and rates only" },
        { key = "DETAILED", label = "Detailed",
          detail = "adds per-event CPU and rate history" },
    },
    function() return WTM.Events:GetMode() end,
    function(mode)
        local actual, err = WTM.Events:SetMode(mode)
        if err then WTM:Print(("Event monitoring: %s"):format(err)) end
        Page:Refresh()
    end,
    "Event monitoring uses a frame with RegisterAllEvents. The handler is deliberately tiny, but in a raid it runs thousands of times a second, so how much it does is a choice.\n\nOFF registers no listener at all. NORMAL counts events and computes rates. DETAILED additionally keeps a short per-event rate history and reads per-event handler CPU, which needs the scriptProfile CVar.\n\nWhichever mode is active, its measured cost is shown under Overhead on the dashboard."), 48)

    self.eventModeNote = UI.Text(canvas, "tiny", "textMuted")
    self.eventModeNote:SetPoint("TOPLEFT", 0, -y)
    self.eventModeNote:SetWidth(COLUMN)
    self.eventModeNote:SetJustifyH("LEFT")
    UI.Wrap(self.eventModeNote)
    y = y + 30

    Add(Slider(canvas, "Event storm multiplier", 2, 20, 0.5,
        function() return profile.events.stormMultiplier end,
        function(v) profile.events.stormMultiplier = v end,
        function(v) return ("%.1f x normal"):format(v) end))

    AddSection("MEMORY")
    Add(Slider(canvas, "Memory growth threshold", 64, 4096, 64,
        function() return profile.memory.growthThresholdKBPerMin end,
        function(v) profile.memory.growthThresholdKBPerMin = v end,
        function(v) return Fmt.Memory(v) .. "/min" end,
        "Above this sustained rate an addon is flagged with \"Potential sustained memory growth\". It is never called a leak - caching looks identical from the outside."))

    ------------------------------------------------------------------
    AddSection("DATA RETENTION")
    Add(Slider(canvas, "Sessions kept", 5, 100, 5,
        function() return profile.retention.maxSessions end,
        function(v) profile.retention.maxSessions = v WTM.Database:Prune() end,
        function(v) return ("%d"):format(v) end))

    Add(Slider(canvas, "Incidents kept", 5, 100, 5,
        function() return profile.retention.maxIncidents end,
        function(v) profile.retention.maxIncidents = v WTM.Database:Prune() end,
        function(v) return ("%d"):format(v) end))

    Add(Checkbox(canvas, "Save time series with each session",
        function() return profile.retention.saveBuckets end,
        function(v) profile.retention.saveBuckets = v end,
        "Time series are aggregated into coarser buckets as they age (1 s, then 5 s, 15 s and 60 s), so a long session stays manageable. Turning this off keeps only the summary numbers."))

    self.sizeText = UI.Text(canvas, "small", "textMuted")
    self.sizeText:SetPoint("TOPLEFT", 0, -y)
    self.sizeText:SetWidth(COLUMN)
    self.sizeText:SetJustifyH("LEFT")
    y = y + 24

    local wipeButton = ConfirmButton(canvas, "Delete all saved history", function()
        -- Through the command, so this button and /wtm wipe cannot drift apart.
        local handler = WTM:GetCommandHandler("wipe")
        if handler then handler("") end
        Page:Refresh()
    end, { height = 24 })
    wipeButton.tooltip = "Deletes every saved session and every saved incident. Settings and this session's live counters are not affected, and it cannot be undone - the button asks for a second click."
    Add(wipeButton, 28)

    ------------------------------------------------------------------
    AddSection("CPU PROFILING")
    self.profilingText = UI.Text(canvas, "small", "textSecondary")
    self.profilingText:SetPoint("TOPLEFT", 0, -y)
    self.profilingText:SetWidth(COLUMN)
    self.profilingText:SetJustifyH("LEFT")
    UI.Wrap(self.profilingText)
    y = y + 52

    local profilingButton = UI.Button(canvas, "Toggle scriptProfile", function()
        WTM.Caps:ToggleCPUProfiling()
        Page:Refresh()
    end, { height = 24, primary = true })
    Add(profilingButton, 28)
    self.profilingButton = profilingButton

    local resetCountersButton = UI.Button(canvas, "Reset the client's CPU counters", function()
        local ok, err = WTM.CPU:ResetClientCounters()
        WTM:Print(ok and "Client CPU counters reset."
            or ("Could not reset counters: " .. tostring(err)))
    end, { height = 24 })
    resetCountersButton.tooltip =
        "Calls ResetCPUUsage. Other profiling addons read the same counters, so this is never done automatically - it would corrupt their numbers without warning."
    Add(resetCountersButton, 28)

    -- A profiling change only takes effect after a reload, so the reload button
    -- belongs here rather than only on the dashboard notice. It is its own
    -- button on purpose: nothing in this addon reloads without a click.
    local reloadButton = ConfirmButton(canvas, "Reload the user interface", function()
        local handler = WTM:GetCommandHandler("reload")
        if handler then handler("") end
    end, { height = 24 })
    reloadButton.tooltip = "Reloads the interface, which is what makes a CPU profiling change take effect. Queued until combat ends if you are fighting. Asks for a second click."
    Add(reloadButton, 28)

    local capsButton = UI.Button(canvas, "Print the capability report", function()
        WTM.Caps:PrintReport()
    end, { height = 24 })
    capsButton.tooltip = "Prints what this client can and cannot measure, and why, to chat. The same report is on the System page. Same as /wtm caps."
    Add(capsButton, 28)

    ------------------------------------------------------------------
    AddSection("INTERFACE")
    local minimapCheck = Checkbox(canvas, "Show the minimap button",
        function() return WTM.UI.MinimapButton:IsShown() end,
        function(v) WTM.UI.MinimapButton:SetShown(v) end,
        "Left click opens the window, right click toggles the live monitor, drag moves it around the minimap. It shows the current FPS.")
    -- Some clients have no Minimap frame at all. Say so rather than offering a
    -- checkbox that silently does nothing.
    local minimapReason = WTM.UI.MinimapButton:UnavailableReason()
    if minimapReason then minimapCheck:SetEnabledState(false, minimapReason) end
    Add(minimapCheck)
    self.minimapCheck = minimapCheck

    local optionsButton = UI.Button(canvas, "Open the Options - AddOns entry", function()
        local ok, reason = WTM.UI.Options:OpenBlizzardPanel()
        if not ok then WTM:Print(reason) end
    end, { height = 24 })
    optionsButton.tooltip =
        "Shows this addon's entry under ESC - Options - AddOns. That entry is deliberately just a description and a button; the settings live here."
    if not WTM.UI.Options.registered then
        optionsButton:SetEnabledState(false, WTM.UI.Options.unavailable)
    end
    Add(optionsButton, 28)

    local tourButton = UI.Button(canvas, "Show the introduction again", function()
        WTM.UI.Onboarding:Open()
    end, { height = 24 })
    tourButton.tooltip =
        "Replays the four-step introduction: what this measures, how to open it, why per-addon CPU needs a client setting, and how to read the results."
    Add(tourButton, 28)

    Add(Checkbox(canvas, "Print a status line at login",
        function() return profile.general.printOnLogin end,
        function(v) profile.general.printOnLogin = v end))

    Add(Checkbox(canvas, "Jump to the timeline when a freeze is detected",
        function() return profile.general.openOnSpike end,
        function(v) profile.general.openOnSpike = v end,
        "Only for the most severe class. Opening a window during a freeze is itself disruptive, so this is off by default."))

    Add(Checkbox(canvas, "Mark peaks on graphs",
        function() return profile.ui.showPeaks end,
        function(v) profile.ui.showPeaks = v end))

    Add(Checkbox(canvas, "Show reference lines on graphs",
        function() return profile.ui.showReferenceLines end,
        function(v) profile.ui.showReferenceLines = v end,
        "Draws faint guides at the frame times that matter: 16.7 ms (60 FPS) and 6.9 ms (144 FPS) on the frame time graph, and the matching FPS lines on the FPS graph."))

    Add(Slider(canvas, "Graph update rate", 0.1, 2, 0.1,
        function() return profile.ui.graphUpdateRate end,
        function(v)
            profile.ui.graphUpdateRate = v
            profile.sampling.intervals.ui = v
            WTM.Scheduler:SetInterval("ui", v)
        end,
        function(v) return ("%.1f s"):format(v) end,
        "How often the visible page redraws. Only runs while the window is open, and its measured cost appears under Overhead on the dashboard."))

    Add(Slider(canvas, "Process list re-sort interval", 0.5, 10, 0.5,
        function() return profile.ui.processResortInterval end,
        function(v) profile.ui.processResortInterval = v end,
        function(v) return ("%.1f s"):format(v) end,
        "How often the process list is allowed to change its order. Rows repaint continuously regardless; this only controls re-sorting, which is what makes rows move. Sorting also pauses entirely while the pointer is over the table."))

    ------------------------------------------------------------------
    AddSection("LIVE MONITOR")

    -- A button, not only a checkbox: this is the control people look for, and
    -- nobody should have to know that /wtm mini exists to find it.
    local miniButton = UI.Button(canvas, "", function()
        WTM.UI.LiveMonitor:Toggle()
        Page:Refresh()
    end, { height = 26, primary = true })
    miniButton.tooltip = "The small always-on panel with FPS, frame time, latency, CPU, memory and event rate. Drag its header to move it; its position and collapsed state are remembered."
    miniButton.Update = function()
        miniButton:SetText(WTM.UI.LiveMonitor:IsShown()
            and "Close the compact monitor" or "Open the compact monitor")
    end
    miniButton.Update()
    Add(miniButton, 30)

    local miniCollapse = UI.Button(canvas, "", function()
        WTM.UI.LiveMonitor:SetCollapsed(not WTM.UI.LiveMonitor:IsCollapsed())
        Page:Refresh()
    end, { height = 24 })
    miniCollapse.tooltip = "Collapsing keeps the panel on screen as a single line with the frame time and FPS. It keeps recording either way."
    miniCollapse.Update = function()
        miniCollapse:SetText(WTM.UI.LiveMonitor:IsCollapsed()
            and "Expand it to the full readout" or "Collapse it to one line")
        miniCollapse:SetEnabledState(WTM.UI.LiveMonitor:IsShown(),
            "The compact monitor is not open.")
    end
    miniCollapse.Update()
    Add(miniCollapse, 28)

    Add(Checkbox(canvas, "Show the compact live monitor",
        function() return WTM.UI.LiveMonitor:IsShown() end,
        function(v)
            if v then WTM.UI.LiveMonitor:Show() else WTM.UI.LiveMonitor:Hide() end
        end,
        "A small always-on panel with FPS, frame time, latency, CPU, memory and event rate. Drag its header to move it. Also toggled with /wtm mini."))

    Add(Checkbox(canvas, "Collapse the live monitor to one line",
        function() return WTM.UI.LiveMonitor:IsCollapsed() end,
        function(v) WTM.UI.LiveMonitor:SetCollapsed(v) end,
        "Hides the rows and keeps the header, which then carries the frame time and FPS. The panel keeps recording either way. Also on the panel's own - button."))

    Add(Checkbox(canvas, "Sparklines in the live monitor",
        function() return profile.liveMonitor.sparklines end,
        function(v)
            profile.liveMonitor.sparklines = v
            WTM.UI.LiveMonitor:ApplySettings()
        end,
        "Sparklines are the expensive part of any graph. Turning them off leaves the numbers, which cost almost nothing."))

    Add(Slider(canvas, "Live monitor width", 150, 400, 10,
        function() return profile.liveMonitor.width end,
        function(v)
            profile.liveMonitor.width = v
            WTM.UI.LiveMonitor:ApplySettings()
        end,
        function(v) return ("%d px"):format(v) end))

    Add(Slider(canvas, "Live monitor opacity", 0.1, 1, 0.05,
        function() return profile.liveMonitor.opacity end,
        function(v)
            profile.liveMonitor.opacity = v
            WTM.UI.LiveMonitor:ApplySettings()
        end,
        function(v) return ("%.0f %%"):format(v * 100) end))

    Add(Slider(canvas, "Live monitor scale", 0.6, 1.6, 0.05,
        function() return profile.liveMonitor.scale end,
        function(v)
            profile.liveMonitor.scale = v
            WTM.UI.LiveMonitor:ApplySettings()
        end,
        function(v) return ("%.2f x"):format(v) end))

    ------------------------------------------------------------------
    AddSection("DIAGNOSTICS")
    Add(Segmented(canvas, "Diagnostic aggressiveness", {
        { key = "conservative", label = "Conservative",
          detail = "only findings that clear the thresholds" },
        { key = "balanced",     label = "Balanced",
          detail = "the default" },
        { key = "aggressive",   label = "Aggressive",
          detail = "also lists weak associations, labelled weak" },
    },
    function() return profile.diagnostics.aggressiveness end,
    function(v)
        profile.diagnostics.aggressiveness = v
        WTM.Diagnostics:InvalidateCache()
    end,
    "How readily findings are reported. This changes what is SHOWN, never how anything is measured or how strongly it is worded: an association is described the same way at every setting, and no setting will make this addon claim causation."), 48)

    ------------------------------------------------------------------
    -- Every chat command, as a button.
    --
    -- The rows are generated from WTM.COMMANDS, which is also what /wtm help
    -- prints, so this list cannot fall behind the commands that actually
    -- exist. Nothing here is a second implementation: each button calls the
    -- same handler the chat command calls.
    ------------------------------------------------------------------
    AddSection("COMMANDS")

    local commandsNote = UI.Text(canvas, "small", "textMuted", "LEFT")
    commandsNote:SetWidth(COLUMN)
    commandsNote:SetHeight(30)
    UI.Wrap(commandsNote, 2)
    commandsNote:SetText("Everything below is also a chat command, but nothing here requires typing one. Hover a button to see what it does.")
    Add(commandsNote, 34)

    -- Groups rendered here, in order. "advanced" is deliberately absent: its
    -- one command has its own section further down, with the explanation that
    -- belongs beside it. Anything else missing is a bug, and the check below
    -- makes it a visible one rather than a quietly unreachable command.
    local GROUP_TITLES = {
        window = "Window",
        pages  = "Go to a page",
        tools  = "Tools",
    }
    local RENDERED_ELSEWHERE = { advanced = true }

    local orphaned = {}
    for _, entry in ipairs(WTM.COMMANDS) do
        if not GROUP_TITLES[entry.group] and not RENDERED_ELSEWHERE[entry.group] then
            orphaned[#orphaned + 1] = entry.cmd
        end
    end
    if #orphaned > 0 then
        local warn = UI.Text(canvas, "small", "warn", "LEFT")
        warn:SetWidth(COLUMN)
        warn:SetHeight(16)
        warn:SetText(("No button for: %s"):format(table.concat(orphaned, ", ")))
        Add(warn, 20)
    end
    self.orphanedCommands = orphaned

    for _, group in ipairs({ "window", "pages", "tools" }) do
        local groupLabel = UI.Text(canvas, "small", "textSecondary", "LEFT")
        groupLabel:SetWidth(COLUMN)
        groupLabel:SetText(GROUP_TITLES[group])
        Add(groupLabel, 20)

        -- Three across, so the page does not become one very long column.
        local row, inRow = nil, 0
        for _, entry in ipairs(WTM.COMMANDS) do
            if entry.group == group then
                if inRow == 0 then
                    row = CreateFrame("Frame", nil, canvas)
                    row:SetHeight(26)
                    Add(row, 30)
                end

                local invocation = "/wtm" .. (entry.cmd ~= "" and (" " .. entry.cmd) or "")
                if entry.arg then invocation = invocation .. " " .. entry.arg end

                local function run()
                    local handler = WTM:GetCommandHandler(entry.cmd)
                    if not handler then return end
                    handler("")
                    Page:Refresh()
                end

                local opts = { height = 24, width = (COLUMN - 16) / 3 }
                local button = entry.confirm
                    and ConfirmButton(row, entry.label, run, opts)
                    or UI.Button(row, entry.label, run, opts)
                button.tooltipTitle = invocation
                button.tooltip = entry.help ..
                    (entry.confirm and "\n\nThis one asks for a second click first." or "")
                button:SetPoint("LEFT", (inRow * ((COLUMN - 16) / 3 + 8)), 0)

                inRow = inRow + 1
                if inRow == 3 then inRow = 0 end
            end
        end
    end

    ------------------------------------------------------------------
    -- Dashboard layout
    --
    -- Deliberately not drag and drop. Dragging a widget grid is a large amount
    -- of frame work for a choice most people make once, and it would have to
    -- be re-implemented for every layout in the addon. A row per widget with
    -- a visibility toggle and a size is the same decision, made faster.
    ------------------------------------------------------------------
    AddSection("DASHBOARD LAYOUT")

    local layoutNote = UI.Text(canvas, "small", "textMuted", "LEFT")
    layoutNote:SetWidth(COLUMN)
    layoutNote:SetHeight(30)
    UI.Wrap(layoutNote, 2)
    layoutNote:SetText("Which blocks the dashboard shows, and how much room each gets. A hidden block is not refreshed at all, so hiding what you do not read makes the page cheaper as well as shorter.")
    Add(layoutNote, 34)

    local SIZES = { "small", "medium", "large" }
    for _, widget in ipairs(WTM.UI.Pages.dashboard.WIDGETS) do
        local row = CreateFrame("Frame", nil, canvas)
        row:SetHeight(26)
        Add(row, 30)

        local dashboard = WTM.db.profile.dashboard

        local visible = UI.Button(row, "", function(button)
            dashboard.hidden[widget.key] = not dashboard.hidden[widget.key] or nil
            button.Update()
            WTM.UI.Pages.dashboard:ApplyLayoutSettings()
        end, { height = 22, width = 74, style = "small" })
        visible:SetPoint("LEFT")
        visible.Update = function()
            local hidden = dashboard.hidden[widget.key]
            visible:SetText(hidden and "hidden" or "shown")
            visible:SetSelected(not hidden)
        end
        visible.Update()
        visible.tooltip = "Hides this block. A hidden block is skipped by the refresh loop entirely."
        self.controls[#self.controls + 1] = visible

        local label = UI.Text(row, "small", "textSecondary", "LEFT")
        label:SetPoint("LEFT", visible, "RIGHT", 10, 0)
        label:SetPoint("RIGHT", row, "RIGHT", -230, 0)
        label:SetText(widget.label)

        local previousSize
        for _, size in ipairs(SIZES) do
            local button = UI.Button(row, size, function(button)
                dashboard.sizes[widget.key] = size
                for _, other in ipairs(row.sizeButtons) do other.Update() end
                WTM.UI.Pages.dashboard:ApplyLayoutSettings()
            end, { height = 22, width = 66, style = "small" })
            if previousSize then
                button:SetPoint("LEFT", previousSize, "RIGHT", 4, 0)
            else
                button:SetPoint("RIGHT", row, "RIGHT", -(66 * 2 + 8), 0)
            end
            button.Update = function()
                button:SetSelected((dashboard.sizes[widget.key] or widget.default) == size)
            end
            button.Update()
            button.tooltip = ("How many columns this block takes on a wide window: %d of 6.")
                :format(widget.spans[size] or 3)
            row.sizeButtons = row.sizeButtons or {}
            row.sizeButtons[#row.sizeButtons + 1] = button
            self.controls[#self.controls + 1] = button
            previousSize = button
        end
    end

    local layoutReset = UI.Button(canvas, "Reset the dashboard layout", function()
        local dashboard = WTM.db.profile.dashboard
        for key in pairs(dashboard.hidden) do dashboard.hidden[key] = nil end
        for key in pairs(dashboard.sizes) do dashboard.sizes[key] = nil end
        WTM.UI.Pages.dashboard:ApplyLayoutSettings()
        Page:Refresh()
    end, { height = 24 })
    layoutReset.tooltip = "Shows every block again at its default size."
    Add(layoutReset, 28)

    ------------------------------------------------------------------
    -- Developer tools, behind their own heading.
    --
    -- These inject data. Everything they inject is recorded with simulated =
    -- true and rendered as SIMULATED wherever it appears, but it still lands in
    -- the same history as real measurements, so it does not belong next to the
    -- ordinary controls.
    ------------------------------------------------------------------
    AddSection("DEVELOPER / ADVANCED")

    local devNote = UI.Text(canvas, "small", "textMuted", "LEFT")
    devNote:SetWidth(COLUMN)
    devNote:SetHeight(44)
    UI.Wrap(devNote, 3)
    devNote:SetText("For testing this addon itself. The injection commands write simulated samples into the real history; everything they produce is marked SIMULATED wherever it is shown. Nothing here is needed for normal use.")
    Add(devNote, 48)

    Add(Checkbox(canvas, "Enable developer mode",
        function() return WTM.Dev:IsEnabled() end,
        function(v)
            WTM.Dev:SetEnabled(v)
            Page:Refresh()
        end,
        "Unlocks the buttons below. Off by default, and off again after you turn it off - it is not remembered as a capability, only as a setting."))

    local devButtons = {}
    do
        local row, inRow = nil, 0
        for _, entry in ipairs(WTM.Dev.SUBCOMMANDS) do
            if inRow == 0 then
                row = CreateFrame("Frame", nil, canvas)
                row:SetHeight(26)
                Add(row, 30)
            end

            local function run()
                local ok, reason = WTM.Dev:RunSubcommand(entry.cmd)
                if not ok then WTM:Print(reason) end
                Page:Refresh()
            end

            local opts = { height = 24, width = (COLUMN - 16) / 3 }
            local button = entry.destructive
                and ConfirmButton(row, entry.label, run, opts)
                or UI.Button(row, entry.label, run, opts)
            button:SetPoint("LEFT", (inRow * ((COLUMN - 16) / 3 + 8)), 0)
            button.tooltipTitle = "/wtm dev " .. entry.cmd
            button.tooltip = entry.help ..
                (entry.destructive and "\n\nWrites a simulated sample into the real history." or "")
            button.Update = function()
                button:SetEnabledState(WTM.Dev:IsEnabled(),
                    "Developer mode is off. Enable it above.")
            end
            button.Update()
            devButtons[#devButtons + 1] = button
            self.controls[#self.controls + 1] = button

            inRow = inRow + 1
            if inRow == 3 then inRow = 0 end
        end
    end

    ------------------------------------------------------------------
    AddSection("RESET")
    local resetRuntimeButton = ConfirmButton(canvas, "Reset runtime counters", function()
        WTM.Database:ResetRuntime()
        WTM:Print("Runtime counters reset. Saved history is untouched.")
        Page:Refresh()
    end, { height = 24 })
    resetRuntimeButton.tooltip = "Clears this session's spikes, incidents, CPU and memory counters and starts measuring again. Saved sessions and incidents are not affected."
    Add(resetRuntimeButton, 28)

    local resetSettingsButton = ConfirmButton(canvas, "Reset all settings to defaults", function()
        WTM.db:ResetProfile()
        WTM:Print("Settings reset to defaults. Some changes take effect after a reload.")
        Page:Refresh()
    end, { height = 24 })
    resetSettingsButton.tooltip = "Restores every setting on this page. Saved sessions, incidents and history are not affected."
    Add(resetSettingsButton, 28)

    canvas:SetHeight(y + 20)
    canvas:SetWidth(COLUMN)
end

function Page:OnShow() self:Refresh() end

function Page:Refresh()
    if not self.controls then return end
    for _, control in ipairs(self.controls) do
        if control.Update then control.Update() end
    end

    if self.eventModeNote then
        self.eventModeNote:SetText(WTM.Events:DescribeMode())
    end

    local bytes = WTM.Database:EstimateSizeBytes()
    self.sizeText:SetText(("Saved database is roughly %s across %d sessions and %d incidents.")
        :format(Fmt.Bytes(bytes), #WTM.db.global.sessions, #WTM.db.global.incidents))

    if WTM.CPU.available then
        self.profilingText:SetText(
            "CPU profiling is |cff3fb950ON|r. Per-addon CPU time is being measured. The client's Lua profiler has a real cost of its own - turn it off when you are finished measuring.")
        self.profilingButton:SetText("Turn CPU profiling off")
    elseif WTM.Caps:Has("toggleProfiling") then
        self.profilingText:SetText(
            "CPU profiling is |cff5d6675OFF|r. Every per-addon CPU figure in this addon is unavailable until the scriptProfile CVar is enabled and the UI is reloaded. Nothing is estimated in the meantime.")
        self.profilingButton:SetText("Turn CPU profiling on")
    else
        self.profilingText:SetText(
            "The scriptProfile CVar cannot be changed on this client: " ..
            (WTM.Caps:Note("toggleProfiling") or C.TXT_UNAVAILABLE_CLIENT))
        self.profilingButton:SetEnabledState(false, WTM.Caps:Note("toggleProfiling"))
    end
end
