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

    self.summary = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.summary:SetPoint("RIGHT")
    self.summary:SetPoint("LEFT", self.scanButton, "RIGHT", 12, 0)

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
        onRowClick = function(record, button)
            if button == "RightButton" then
                WTM.Database:SetWatched(record.name, not WTM.Database:IsWatched(record.name))
                self:Rebuild(true)
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
function Page:Rebuild(force)
    if not self.table then return end
    WTM.Processes:BuildView(viewData,
        WTM.db.profile.ui.processSort,
        WTM.db.profile.ui.processSortAsc,
        self.filter,
        self.showUnloaded)
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
