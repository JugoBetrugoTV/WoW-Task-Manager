--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Processes.lua

    The process list. One row per installed addon, sortable, searchable, with
    a full diagnostic view behind a click.

    Live sorting is deliberately restrained. Re-sorting on every refresh makes
    rows leapfrog while you are trying to read them, which is the single most
    annoying thing a live task manager can do. Three things prevent it:

      * comparators are STABLE - ties fall back to the addon name, so equal
        values keep a fixed order instead of shuffling,
      * CPU sorts on the SMOOTHED value, so one idle sample does not drop an
        addon twenty rows and bring it back on the next,
      * re-sorting is throttled, and pauses entirely while the pointer is over
        the table, so a row cannot move out from under the mouse.

    Columns whose measurement is unavailable show a dash and explain themselves
    in the header tooltip rather than showing a zero that looks like a reading.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("processes", {})

local viewData = {}

--------------------------------------------------------------------------
-- Column helpers
--------------------------------------------------------------------------

local function cpuTone(record)
    if not WTM.CPU.available or not record.loaded then return "muted" end
    local pct = record.cpuEma or 0
    if pct >= C.HIGH_CPU_PCT then return "crit" end
    if pct >= C.ELEVATED_CPU_PCT then return "warn" end
    return nil
end

local function cpuValue(get)
    return function(record)
        if not WTM.CPU.available then return "-" end
        if not record.loaded then return "" end
        return ("%.2f"):format(get(record) or 0)
    end
end

local COLUMNS = {
    {
        key = "name", title = "Name", flex = 3, sort = "name",
        value = function(record)
            local text = Fmt.Truncate(record.titleClean or record.name, 42)
            if WTM.Database:IsWatched(record.name) then text = "* " .. text end
            return text
        end,
        tone = function(record) return record.loaded and nil or "muted" end,
        tooltip = "Every installed addon. Unloaded and disabled ones are greyed out; use \"Show unloaded\" to include them. Right click a row to flag it for diagnostics.",
    },
    {
        key = "status", title = "Status", width = 104, sort = "status",
        value = function(record) return record.status and record.status.text or "" end,
        tone = function(record) return record.status and record.status.tone or "muted" end,
        tooltip = "Derived from smoothed CPU, sustained memory growth and how often this addon was above its own average during a frame spike.",
    },
    {
        key = "cpu", title = "CPU %", width = 68, justify = "RIGHT", sort = "cpu",
        value = cpuValue(function(r) return r.cpuEma end),
        tone = cpuTone,
        bar = function(record)
            if not WTM.CPU.available then return 0 end
            return (record.cpuEma or 0) / 25, cpuTone(record) or "accent"
        end,
        tooltip = "Share of one CPU core spent in this addon's Lua, smoothed across samples. Requires the client's scriptProfile CVar; without it every value here is a dash rather than a zero.",
    },
    {
        key = "cpuavg", title = "CPU avg", width = 66, justify = "RIGHT", sort = "cpuavg",
        value = cpuValue(function(r)
            return r.cpuSamples > 0 and (r.cpuSumPct / r.cpuSamples) or 0
        end),
        tone = function() return "muted" end,
        tooltip = "Mean CPU across every sample this session. Less reactive than the CPU column and better for judging a persistent cost.",
    },
    {
        key = "cpupeak", title = "CPU peak", width = 70, justify = "RIGHT", sort = "cpupeak",
        value = cpuValue(function(r) return r.cpuPeakPct end),
        tone = function(record)
            if not WTM.CPU.available then return "muted" end
            return (record.cpuPeakPct or 0) >= C.HIGH_CPU_PCT and "warn" or "muted"
        end,
        tooltip = "The highest single-sample CPU share seen this session. A high peak with a low average means bursty work rather than a constant drain.",
    },
    {
        key = "memory", title = "Memory", width = 84, justify = "RIGHT", sort = "memory",
        value = function(record)
            if not record.loaded then return "" end
            return Fmt.Memory(record.memKB or 0)
        end,
        bar = function(record) return (record.memKB or 0) / 51200, "accent" end,
        tooltip = "Lua memory attributed to this addon by GetAddOnMemoryUsage.",
    },
    {
        key = "memdelta", title = "Growth", width = 80, justify = "RIGHT", sort = "memdelta",
        value = function(record)
            if not record.loaded or not record.memStartKB then return "" end
            return Fmt.MemoryDelta(record.memKB - record.memStartKB)
        end,
        tone = function(record)
            return (record.memGrowthKBPerMin or 0) >= WTM.db.profile.memory.growthThresholdKBPerMin
                and "warn" or nil
        end,
        tooltip = "Change since this session started. Growth is not proof of a leak - addons legitimately grow while caching. What separates a leak is that it never levels off.",
    },
    {
        key = "events", title = "Events ~", width = 72, justify = "RIGHT", sort = "events",
        value = function(record)
            if not record.attributionConfident then return "-" end
            return tostring(record.registeredEvents or 0)
        end,
        tone = function(record) return record.attributionConfident and "warn" or "muted" end,
        tooltip = "HEURISTIC. How many of the busiest observed events this addon's named frames listen for. No API maps a frame to its addon, so this is a name-prefix match and anonymous frames are invisible to it. The ~ in the header is there to keep that visible. Use \"Scan frames\" to populate it.",
    },
    {
        key = "spikes", title = "Spikes", width = 58, justify = "RIGHT", sort = "spikes",
        value = function(record) return (record.spikes or 0) > 0 and tostring(record.spikes) or "" end,
        tone = function(record) return (record.spikes or 0) >= 3 and "warn" or nil end,
        tooltip = "How often this addon was above its own average CPU during a frame time spike. An association, not a demonstrated cause.",
    },
    {
        key = "cpusession", title = "CPU total", width = 82, justify = "RIGHT", sort = "cpusession",
        value = function(record)
            if not WTM.CPU.available then return "-" end
            if not record.loaded then return "" end
            return Fmt.Ms(record.cpuTotalMs or 0)
        end,
        tone = function() return "muted" end,
        tooltip = "Cumulative CPU time this addon has been charged with since the counters were last reset. This is the raw counter WoW exposes - a total over an unknown span, not a share of any one frame.",
    },
    {
        key = "mempct", title = "Mem %", width = 62, justify = "RIGHT", sort = "mempct",
        value = function(record)
            local total = WTM.Memory.current.addonSumKB or 0
            if not record.loaded or total <= 0 then return "" end
            return ("%.1f"):format((record.memKB or 0) / total * 100)
        end,
        bar = function(record)
            local total = WTM.Memory.current.addonSumKB or 0
            if total <= 0 then return 0 end
            return (record.memKB or 0) / total, "accent"
        end,
        tone = function() return "muted" end,
        tooltip = "This addon's share of all memory the client attributes to addons. Not a share of the whole Lua heap - the default UI is not counted here.",
    },
    {
        key = "frames", title = "Frames ~", width = 72, justify = "RIGHT", sort = "frames",
        value = function(record)
            if not record.attributionConfident then return "-" end
            return tostring(record.frameCount or 0)
        end,
        tone = function(record) return record.attributionConfident and nil or "muted" end,
        tooltip = "HEURISTIC. How many named frames were matched to this addon by name prefix. Anonymous frames cannot be attributed to anyone, so this is a lower bound. Use \"Scan frames\" to populate it.",
    },
    {
        key = "phi", title = "Spike assoc.", width = 96, justify = "RIGHT", sort = "phi",
        value = function(record)
            -- phi, never rendered as a percentage: it measures association
            -- between two yes/no observations, and a % sign would read as a
            -- likelihood.
            return record.sessionPhi and ("phi %.2f"):format(record.sessionPhi) or "-"
        end,
        tone = function(record)
            if not record.sessionPhi then return "muted" end
            return record.sessionPhi >= 0.5 and "warn" or nil
        end,
        tooltip = "How consistently this addon was above its own average CPU during recorded frame spikes, as a phi coefficient over a fully measured 2x2 table. It is an association across many samples. It is not a probability and it never demonstrates a cause.",
    },
    {
        key = "lod", title = "Load", width = 66, sort = "lod",
        value = function(record)
            if record.loaded then return "loaded" end
            if record.lod then return "on demand" end
            if record.enableState == 0 then return "disabled" end
            return "not loaded"
        end,
        tone = function(record) return record.loaded and nil or "muted" end,
        tooltip = "Whether the addon is loaded, waiting to be loaded on demand, or disabled. A load-on-demand addon costs nothing until something asks for it.",
    },
    {
        key = "deps", title = "Deps", width = 54, justify = "RIGHT", sort = "deps",
        value = function(record)
            local n = record.deps and #record.deps or 0
            return n > 0 and tostring(n) or ""
        end,
        tone = function() return "muted" end,
        tooltip = "How many other addons this one declares as required dependencies. Open the addon's details to see which, and what depends on it in turn.",
    },
    {
        key = "score", title = "Score", width = 54, justify = "RIGHT", sort = "score",
        value = function(record) return tostring(record.score or 100) end,
        tone = function(record)
            local score = record.score or 100
            if score < 50 then return "crit" end
            if score < 80 then return "warn" end
            return "muted"
        end,
        tooltip = "A presentation aid, not a measurement: it compresses smoothed CPU, sustained memory growth and spike involvement into one sortable number so the list can lead with what is worth looking at.",
    },
}

--------------------------------------------------------------------------

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

    self.search = UI.SearchBox(toolbar, "Search addons", function(text)
        self.filter = text
        self:Rebuild(true)
    end)
    self.search:SetPoint("LEFT")
    self.search:SetWidth(210)

    self.showUnloaded = false
    self.unloadedButton = UI.Button(toolbar, "Show unloaded", function(button)
        self.showUnloaded = not self.showUnloaded
        button:SetSelected(self.showUnloaded)
        self:Rebuild(true)
    end, { height = 24 })
    self.unloadedButton:SetPoint("LEFT", self.search, "RIGHT", 8, 0)

    self.scanButton = UI.Button(toolbar, "Scan frames", function()
        local ok, err = WTM.Processes:ScanFrames(true)
        if not ok then WTM:Print(err) end
        self:Rebuild(true)
    end, { height = 24 })
    self.scanButton:SetPoint("LEFT", self.unloadedButton, "RIGHT", 8, 0)
    self.scanButton.tooltip =
        "Walks every frame in the UI and matches frame names against loaded addons. This is the only way to attribute frames and events to an addon, and it is a heuristic - anonymous frames cannot be attributed at all."

    ------------------------------------------------------------------
    -- Filters. Additive: every active one has to pass.
    ------------------------------------------------------------------
    self.filters = {}
    self.filterButtons = {}

    local FILTERS = {
        { key = "loadedOnly",    label = "Loaded",
          tip = "Only addons the client has actually loaded. Unloaded ones cost nothing until something asks for them." },
        { key = "enabledOnly",   label = "Enabled",
          tip = "Hides addons disabled for this character." },
        { key = "watchedOnly",   label = "Flagged",
          tip = "Only the addons you have flagged. Right click a row to flag one." },
        { key = "suspectedOnly", label = "Worth a look",
          tip = "Addons with elevated CPU, sustained memory growth, or an association with recorded spikes. Any one of the three qualifies - it is a union of measured signals, not a verdict." },
        { key = "cpuOver",       label = "CPU > 1%",
          tip = "Only addons above one percent of a core, smoothed.",
          apply = function(f, on) f.minCPU = on and 1 or nil end },
        { key = "memOver",       label = "Mem > 1 MB",
          tip = "Only addons the client attributes at least a megabyte to.",
          apply = function(f, on) f.minMemory = on and 1024 or nil end },
    }

    local previousFilter
    for _, filter in ipairs(FILTERS) do
        local button = UI.Button(toolbar, filter.label, function(button)
            local on = not button.active
            button.active = on
            button:SetSelected(on)
            if filter.apply then
                filter.apply(self.filters, on)
            else
                self.filters[filter.key] = on or nil
            end
            self:Rebuild(true)
        end, { height = 24, style = "small" })
        if previousFilter then
            button:SetPoint("LEFT", previousFilter, "RIGHT", 4, 0)
        else
            button:SetPoint("LEFT", self.scanButton, "RIGHT", 12, 0)
        end
        button.tooltip = filter.tip
        self.filterButtons[filter.key] = button
        previousFilter = button
    end

    self.summary = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.summary:SetPoint("RIGHT")
    self.summary:SetPoint("LEFT", previousFilter, "RIGHT", 12, 0)

    ------------------------------------------------------------------
    -- Profiling notice
    ------------------------------------------------------------------
    self.notice = UI.NoticePanel(frame,
        "Addon CPU profiling is disabled",
        "The CPU columns need the client's own Lua profiler, which is off. Enabling it sets the scriptProfile CVar; it takes effect after a reload, and nothing reloads without your click. Memory, events, spikes and scores all work regardless.",
        "Enable profiling", function()
            local ok, err = WTM.Caps:SetCPUProfiling(true)
            if ok then
                WTM:Print("CPU profiling will be ON after the next |cff4c8dff/reload|r.")
            else
                WTM:Print("Could not enable CPU profiling: " .. tostring(err))
            end
            Page:Refresh()
        end, "warn")
    self.notice:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -10)
    self.notice:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -10)

    ------------------------------------------------------------------
    -- Table
    ------------------------------------------------------------------
    self.table = UI.Table(frame, COLUMNS, {
        defaultSort = WTM.db.profile.ui.processSort,
        defaultAscending = WTM.db.profile.ui.processSortAsc,
        emptyMessage = "No addons match this filter",
        onSort = function(key, ascending)
            WTM.db.profile.ui.processSort = key
            WTM.db.profile.ui.processSortAsc = ascending
            -- An explicit click always re-sorts immediately.
            self:Rebuild(true)
        end,
        onRowClick = function(record, button, row)
            if button == "RightButton" then
                Page:ShowRowMenu(row, record)
            else
                UI.AddonDetail:Open(record)
            end
        end,
        onRowEnter = function(row, record)
            -- Freeze the order while the pointer is over the list, so a row
            -- cannot move out from under the mouse mid-click.
            Page.hovering = true
            Page:ShowRowTooltip(row, record)
        end,
        onRowLeave = function()
            Page.hovering = false
        end,
    })
    self:PositionTable()
end

function Page:PositionTable()
    self.table:ClearAllPoints()
    self.table:SetPoint("BOTTOMLEFT", M.padding, M.padding)
    self.table:SetPoint("BOTTOMRIGHT", -M.padding, M.padding)
    local anchor
    if WTM.CPU.available then
        self.notice:Hide()
        anchor = self.toolbar
    else
        self.notice:Show()
        anchor = self.notice
    end
    self.table:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    self.table:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -10)
end

function Page:OnLayout()
    if self.table then self.table.LayoutHeader() end
end

function Page:OnShow()
    self:PositionTable()
    self:Rebuild(true)
end

--------------------------------------------------------------------------

function Page:ShowRowTooltip(row, record)
    UI.TooltipClear(record.titleClean or record.name)
    UI.TooltipLine("Folder", record.name)
    if record.version then UI.TooltipLine("Version", record.version) end
    UI.TooltipLine("Loaded", record.loaded and "yes" or "no")
    UI.TooltipLine("LoadOnDemand", record.lod and "yes" or "no")

    if WTM.CPU.available and record.loaded then
        UI.TooltipLine("CPU now", ("%.2f %%"):format(record.cpuEma or 0))
        UI.TooltipLine("CPU average", ("%.2f %%"):format(WTM.CPU:GetAverage(record)))
        UI.TooltipLine("CPU peak", ("%.2f %%"):format(record.cpuPeakPct or 0))
        UI.TooltipLine("Samples", tostring(record.cpuSamples or 0))
    elseif record.loaded then
        UI.TooltipLine("CPU", C.TXT_REQUIRES_PROFILING, nil, "muted")
    end

    if record.loaded then
        UI.TooltipLine("Memory", Fmt.Memory(record.memKB))
        if record.memStartKB then
            UI.TooltipLine("Growth/min", Fmt.Memory(record.memGrowthKBPerMin or 0))
        end
        UI.TooltipLine("Score", ("%d / 100"):format(record.score or 100))
    end

    if record.attributionConfident then
        UI.TooltipLine("Named frames (heuristic)", tostring(record.frameCount), nil, "warn")
    end

    UI.TooltipLine("", "")
    UI.TooltipLine("Left click for details, right click to flag", nil, "muted")
    UI.TooltipShow(row)
end

--------------------------------------------------------------------------

--- `force` bypasses the re-sort throttle; used for explicit user actions.
--- The right-click menu for one row.
---
--- Enable and disable are offered because the client offers them, and they are
--- labelled with what they actually do: they take effect at the next reload.
--- There is deliberately no "unload now" - no API does that, and a button that
--- pretended to would be worse than its absence.
function Page:ShowRowMenu(row, record)
    if not record then return end

    local watched = WTM.Database:IsWatched(record.name)
    local canToggle = WTM.Caps:Has("addonEnableDisable")
    local toggleReason = canToggle and nil
        or (WTM.Caps:Note("addonEnableDisable") or C.TXT_UNAVAILABLE_CLIENT)

    local entries = {
        { label = "Open details",
          tooltip = "Everything measured for this addon, on its own page.",
          onClick = function() UI.AddonDetail:Open(record) end },
        { label = "Show on timeline",
          tooltip = "Opens the timeline with this addon's CPU as its own track under the shared axis.",
          onClick = function()
              WTM.Database:SetWatched(record.name, true)
              UI.MainWindow:ShowPage("timeline")
              local page = UI.Pages.timeline
              if page and page.FocusAddon then page:FocusAddon(record.name) end
          end },
        { label = watched and "Remove flag" or "Flag for diagnostics",
          tooltip = "Flagged addons are the ones the timeline and diagnostics lead with.",
          onClick = function()
              WTM.Database:SetWatched(record.name, not watched)
              Page:Rebuild(true)
          end },
        { label = "Copy name",
          tooltip = "Puts the addon's name in an edit box you can copy from - WoW gives addons no clipboard access.",
          onClick = function() UI.ShowCopyBox(record.name, "Addon name") end },
        { label = "Copy diagnostics",
          tooltip = "A short text summary of what has been measured for this addon, ready to paste into a bug report.",
          onClick = function()
              UI.ShowCopyBox(Page:BuildDiagnosticText(record), "Diagnostics for " .. record.titleClean)
          end },
        { label = record.enableState == 0 and "Enable (after reload)" or "Disable (after reload)",
          disabled = not canToggle, reason = toggleReason,
          tooltip = "Takes effect at the next UI reload. Nothing is unloaded now - the client offers no way to do that.",
          onClick = function()
              local ok, err = WTM.Processes:SetEnabled(record.name, record.enableState == 0)
              WTM:Print(ok and ("%s will be %s after the next reload.")
                    :format(record.titleClean, record.enableState == 0 and "enabled" or "disabled")
                  or ("Could not change it: " .. tostring(err)))
              Page:Rebuild(true)
          end },
    }

    UI.ShowContextMenu(row, entries, record.titleClean)
end

--- A paste-ready summary of one addon. Every figure names what it is, and the
--- CPU line names its observation window rather than implying a per-frame cost.
function Page:BuildDiagnosticText(record)
    local lines = {}
    lines[#lines + 1] = ("%s %s"):format(record.titleClean, record.version or "")
    lines[#lines + 1] = ("state: %s"):format(record.loaded and "loaded"
        or (record.enableState == 0 and "disabled" or "not loaded"))

    if WTM.CPU.available then
        lines[#lines + 1] = ("CPU: %.2f%% now, %.2f%% average, %.2f%% peak")
            :format(record.cpuEma or 0,
                    (record.cpuSamples or 0) > 0 and (record.cpuSumPct / record.cpuSamples) or 0,
                    record.cpuPeakPct or 0)
        lines[#lines + 1] = ("CPU total charged: %s (%s)")
            :format(Fmt.Ms(record.cpuTotalMs or 0), C.TXT_CPU_WINDOW_NOTE)
    else
        lines[#lines + 1] = "CPU: " .. (WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
    end

    lines[#lines + 1] = ("memory: %s now, %s since login, %s per minute")
        :format(Fmt.Memory(record.memKB or 0),
                Fmt.MemoryDelta((record.memKB or 0) - (record.memStartKB or record.memKB or 0)),
                Fmt.Memory(record.memGrowthKBPerMin or 0))

    if record.sessionPhi then
        lines[#lines + 1] = ("spike association: phi %.2f over %d recorded spikes - an association, not a demonstrated cause")
            :format(record.sessionPhi, WTM.SpikeDetector.total)
    else
        lines[#lines + 1] = "spike association: none recorded"
    end

    lines[#lines + 1] = ("frames attributed (heuristic): %d, events %d")
        :format(record.frameCount or 0, record.registeredEvents or 0)
    lines[#lines + 1] = ("measured by %s %s on %s")
        :format(C.ADDON_TITLE, C.VERSION, WTM.Compat.flavorName or "?")
    return table.concat(lines, "\n")
end

function Page:Rebuild(force)
    if not self.table then return end
    WTM.Processes:BuildView(viewData,
        WTM.db.profile.ui.processSort,
        WTM.db.profile.ui.processSortAsc,
        self.filter,
        self.showUnloaded,
        self.filters)
    self.table:SetData(viewData)
    self.table:SetEmpty(#viewData == 0)
    self.lastRebuild = GetTime()
end

function Page:Refresh()
    if not self.table then return end

    local sessionMinutes = (GetTime() - (WTM.state.sessionStart or GetTime())) / 60
    for _, record in WTM.Processes:Iterate() do
        WTM.Processes:UpdateDerived(record, sessionMinutes)
    end

    -- Repainting the visible rows is cheap and always safe; re-sorting is what
    -- makes rows move, so it is throttled and paused while hovering.
    local now = GetTime()
    local interval = WTM.db.profile.ui.processResortInterval or 2.0
    if not self.hovering and (not self.lastRebuild or (now - self.lastRebuild) >= interval) then
        self:Rebuild()
    else
        self.table:Refresh()
    end

    local loaded = WTM.Processes:CountLoaded()
    local attribution = WTM.Processes.attribution
    self.summary:SetText(UI.FitText(self.summary, ("%d of %d loaded  -  %s%s")
        :format(loaded, #WTM.Processes.list,
                attribution.totalFrames > 0
                    and ("%d frames scanned, %d attributed"):format(
                        attribution.totalFrames, attribution.matchedFrames)
                    or "frames not scanned",
                self.hovering and "  -  sort paused while hovering" or "")))
end
