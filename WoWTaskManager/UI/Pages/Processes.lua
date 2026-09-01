--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Processes.lua

    The process list.  One row per installed addon, sortable, searchable, with
    a detail overlay behind a click.

    Columns that depend on an unavailable capability show a dash and explain
    themselves in the header tooltip rather than showing zeroes that look like
    real measurements.
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
-- Column definitions
--------------------------------------------------------------------------

local function cpuText(record)
    if not WTM.CPU.available then return "-" end
    if not record.loaded then return "" end
    return ("%.2f"):format(record.cpuEma or 0)
end

local function cpuTone(record)
    if not WTM.CPU.available or not record.loaded then return "muted" end
    local pct = record.cpuEma or 0
    if pct >= C.HIGH_CPU_PCT then return "crit" end
    if pct >= C.ELEVATED_CPU_PCT then return "warn" end
    return nil
end

local COLUMNS = {
    {
        key = "name", title = "Addon", flex = 3, sort = "name",
        value = function(record)
            local text = Fmt.Truncate(record.titleClean or record.name, 40)
            if WTM.Database:IsWatched(record.name) then text = "* " .. text end
            return text
        end,
        tone = function(record) return record.loaded and nil or "muted" end,
        tooltip = "Installed addons. Unloaded and disabled addons are shown greyed out; toggle them with the filter above.",
    },
    {
        key = "cpu", title = "CPU %", width = 74, justify = "RIGHT", sort = "cpu",
        value = cpuText, tone = cpuTone,
        bar = function(record)
            if not WTM.CPU.available then return 0 end
            return (record.cpuEma or 0) / 25, cpuTone(record) or "accent"
        end,
        tooltip = "Share of one CPU core spent in this addon's Lua, smoothed. Requires the client's scriptProfile CVar; without it every value here is a dash.",
    },
    {
        key = "cpudelta", title = "CPU ms", width = 70, justify = "RIGHT", sort = "cpudelta",
        value = function(record)
            if not WTM.CPU.available then return "-" end
            return ("%.1f"):format(record.cpuDeltaMs or 0)
        end,
        tone = cpuTone,
        tooltip = "Milliseconds of CPU time consumed since the previous sample. This is the raw delta the percentage is derived from.",
    },
    {
        key = "memory", title = "Memory", width = 86, justify = "RIGHT", sort = "memory",
        value = function(record)
            if not record.loaded then return "" end
            return Fmt.Memory(record.memKB or 0)
        end,
        bar = function(record) return (record.memKB or 0) / 51200, "accent" end,
        tooltip = "Lua memory attributed to this addon by GetAddOnMemoryUsage.",
    },
    {
        key = "memdelta", title = "Growth", width = 82, justify = "RIGHT", sort = "memdelta",
        value = function(record)
            if not record.loaded or not record.memStartKB then return "" end
            return Fmt.MemoryDelta(record.memKB - record.memStartKB)
        end,
        tone = function(record)
            local perMinute = record.memGrowthKBPerMin or 0
            if perMinute >= WTM.db.profile.memory.growthThresholdKBPerMin then return "warn" end
            return nil
        end,
        tooltip = "Change in this addon's memory since the session started. Growth is not proof of a leak - addons legitimately cache data.",
    },
    {
        key = "events", title = "Events", width = 66, justify = "RIGHT", sort = "events",
        value = function(record)
            if not record.attributionConfident then return "-" end
            return tostring(record.registeredEvents or 0)
        end,
        tone = function(record) return record.attributionConfident and nil or "muted" end,
        tooltip = "How many of the busiest observed events this addon's named frames listen for. HEURISTIC: frames cannot be mapped to addons by any API, so this is a name-prefix match and anonymous frames are invisible to it. Run a scan from the toolbar.",
    },
    {
        key = "spikes", title = "Spikes", width = 60, justify = "RIGHT", sort = "spikes",
        value = function(record) return (record.spikes or 0) > 0 and tostring(record.spikes) or "" end,
        tone = function(record) return (record.spikes or 0) >= 3 and "warn" or nil end,
        tooltip = "How often this addon was above its own average CPU during a frame time spike. Association, not cause.",
    },
    {
        key = "status", title = "Status", width = 108, sort = "status",
        value = function(record) return record.status and record.status.text or "" end,
        tone = function(record) return record.status and record.status.tone or "muted" end,
        tooltip = "Derived from CPU, memory growth and spike involvement.",
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
        self:Rebuild()
    end)
    self.search:SetPoint("LEFT")
    self.search:SetWidth(220)

    self.showUnloaded = false
    self.unloadedButton = UI.Button(toolbar, "Show unloaded", function(button)
        self.showUnloaded = not self.showUnloaded
        button:SetSelected(self.showUnloaded)
        self:Rebuild()
    end, { height = 24 })
    self.unloadedButton:SetPoint("LEFT", self.search, "RIGHT", 8, 0)

    self.scanButton = UI.Button(toolbar, "Scan frames", function()
        local ok, err = WTM.Processes:ScanFrames(true)
        if not ok then WTM:Print(err) end
        self:Rebuild()
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
        "CPU profiling is disabled",
        "Per-addon CPU time comes from the client's own Lua profiler, which is off. Enabling it sets the scriptProfile CVar and takes effect after a reload. The profiler is not free - turn it back off when you are done measuring.",
        "Enable and reload", function()
            if WTM.Caps:ToggleCPUProfiling() then
                WTM.Processes:ReloadUI()
            end
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
            self:Rebuild()
        end,
        onRowClick = function(record, button)
            if button == "RightButton" then
                WTM.Database:SetWatched(record.name, not WTM.Database:IsWatched(record.name))
                self:Rebuild()
            else
                UI.AddonDetail:Open(record)
            end
        end,
        onRowEnter = function(row, record)
            Page:ShowRowTooltip(row, record)
        end,
    })
    self.table:SetPoint("BOTTOMLEFT", pad, pad)
    self.table:SetPoint("BOTTOMRIGHT", -pad, pad)

    self:PositionTable()
end

function Page:PositionTable()
    self.table:ClearAllPoints()
    self.table:SetPoint("BOTTOMLEFT", M.padding, M.padding)
    self.table:SetPoint("BOTTOMRIGHT", -M.padding, M.padding)
    if WTM.CPU.available then
        self.notice:Hide()
        self.table:SetPoint("TOPLEFT", self.toolbar, "BOTTOMLEFT", 0, -10)
        self.table:SetPoint("TOPRIGHT", self.toolbar, "BOTTOMRIGHT", 0, -10)
    else
        self.notice:Show()
        self.table:SetPoint("TOPLEFT", self.notice, "BOTTOMLEFT", 0, -10)
        self.table:SetPoint("TOPRIGHT", self.notice, "BOTTOMRIGHT", 0, -10)
    end
end

function Page:OnLayout()
    if self.table then self.table.LayoutHeader() end
end

function Page:OnShow()
    self:PositionTable()
    self:Rebuild()
end

function Page:ShowRowTooltip(row, record)
    UI.TooltipClear(record.titleClean or record.name)
    UI.TooltipLine("Name", record.name)
    if record.version then UI.TooltipLine("Version", record.version) end
    if record.author then UI.TooltipLine("Author", Fmt.Truncate(Fmt.StripColors(record.author), 32)) end
    UI.TooltipLine("Loaded", record.loaded and "yes" or "no")
    UI.TooltipLine("LoadOnDemand", record.lod and "yes" or "no")

    if WTM.CPU.available and record.loaded then
        UI.TooltipLine("CPU average", ("%.2f %%"):format(WTM.CPU:GetAverage(record)))
        UI.TooltipLine("CPU peak", ("%.2f %%"):format(record.cpuPeakPct or 0))
    end
    if record.loaded then
        UI.TooltipLine("Memory", Fmt.Memory(record.memKB))
        if record.memStartKB then
            UI.TooltipLine("Growth per minute", Fmt.Memory(record.memGrowthKBPerMin or 0))
        end
        UI.TooltipLine("Performance score", ("%d / 100"):format(record.score or 100))
    end
    if record.frameCount and record.frameCount > 0 then
        UI.TooltipLine("Named frames (heuristic)", tostring(record.frameCount), nil, "warn")
    end
    UI.TooltipLine("", "")
    UI.TooltipLine("Left click for details, right click to flag", nil, "muted")
    UI.TooltipShow(row)
end

--------------------------------------------------------------------------

function Page:Rebuild()
    if not self.table then return end
    WTM.Processes:BuildView(viewData,
        WTM.db.profile.ui.processSort,
        WTM.db.profile.ui.processSortAsc,
        self.filter,
        self.showUnloaded)
    self.table:SetData(viewData)
    self.table:SetEmpty(#viewData == 0)
end

local REBUILD_INTERVAL = 1.0
function Page:Refresh()
    if not self.table then return end

    local sessionMinutes = (GetTime() - (WTM.state.sessionStart or GetTime())) / 60
    for _, record in WTM.Processes:Iterate() do
        WTM.Processes:UpdateDerived(record, sessionMinutes)
    end

    -- The sort order only changes on a rebuild; refreshing in between just
    -- repaints the visible rows, which is far cheaper than re-sorting 150
    -- entries twice a second.
    local now = GetTime()
    if not self.lastRebuild or (now - self.lastRebuild) >= REBUILD_INTERVAL then
        self:Rebuild()
        self.lastRebuild = now
    else
        self.table:Refresh()
    end

    local loaded = 0
    for _, record in WTM.Processes:Iterate() do
        if record.loaded then loaded = loaded + 1 end
    end
    self.summary:SetText(("%d of %d addons loaded   -   %s")
        :format(loaded, #WTM.Processes.list,
                WTM.Processes.attribution.totalFrames > 0
                    and ("%d frames scanned, %d attributed"):format(
                        WTM.Processes.attribution.totalFrames,
                        WTM.Processes.attribution.matchedFrames)
                    or "frames not scanned"))
end
