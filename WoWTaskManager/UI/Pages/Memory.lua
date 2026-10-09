--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Memory.lua

    The resource-monitor view for memory.

    Two deliberate restraints here:
      * The word "leak" does not appear as a verdict.  Sustained growth is
        reported as sustained growth, because an addon caching a raid's worth
        of combat log data looks identical to a leak from the outside.
      * Garbage collection is described as inferred from the heap curve,
        because that is exactly what it is - WoW exposes no GC statistics.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

-- One row of cards is this tall; UI.LayoutCardRow returns what the row needs
-- once it has decided how many rows the width allows.
local CARD_ROW_HEIGHT = 78

local Page = UI.RegisterPage("memory", {})

local growthData = {}

local COLUMNS = {
    { key = "name", title = "Addon", flex = 3,
      value = function(row) return Fmt.Truncate(row.title, 40) end },
    { key = "start", title = "At login", width = 90, justify = "RIGHT",
      value = function(row) return Fmt.Memory(row.startKB) end,
      tone = function() return "muted" end },
    { key = "current", title = "Now", width = 90, justify = "RIGHT",
      value = function(row) return Fmt.Memory(row.currentKB) end },
    { key = "growth", title = "Growth", width = 96, justify = "RIGHT",
      value = function(row) return Fmt.MemoryDelta(row.growthKB) end,
      tone = function(row) return row.sustained and "warn" or nil end,
      bar = function(row) return row.growthKB / 51200, row.sustained and "warn" or "accent" end },
    { key = "rate", title = "Per minute", width = 96, justify = "RIGHT",
      value = function(row) return Fmt.Memory(row.perMinute) end,
      tone = function(row) return row.sustained and "warn" or "muted" end },
    { key = "flag", title = "", width = 160,
      value = function(row) return row.sustained and "Potential sustained growth" or "" end,
      tone = function() return "warn" end },
}

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Summary cards
    ------------------------------------------------------------------
    local row = CreateFrame("Frame", nil, frame)
    row:SetHeight(CARD_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", pad, -pad)
    row:SetPoint("TOPRIGHT", -pad, -pad)
    self.cardRow = row

    self.cards = {}
    local specs = {
        { key = "total",   label = "TOTAL LUA MEMORY" },
        { key = "addons",  label = "ATTRIBUTED TO ADDONS" },
        { key = "growth",  label = "SESSION GROWTH" },
        { key = "rate",    label = "GROWTH RATE" },
        { key = "peak",    label = "PEAK HEAP" },
        { key = "low",     label = "LOWEST HEAP" },
        { key = "largest", label = "LARGEST ADDON" },
        { key = "fastest", label = "FASTEST GROWING" },
        { key = "gc",      label = "HEAP DECREASES OBSERVED" },
    }
    for i, spec in ipairs(specs) do
        local card = UI.MetricCard(row, { label = spec.label, height = 78, sparkHeight = 0 })
        card.spark:Hide()
        self.cards[spec.key] = card
    end

    ------------------------------------------------------------------
    -- Heap graph
    ------------------------------------------------------------------
    self.graph = UI.Graph(frame, {
        title = "LUA HEAP  -  falls here are observed decreases, consistent with collection activity",
        valueFormat = function(v) return Fmt.Memory(v) end,
    })
    self.graph:SetHeight(190)
    self.graph:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -M.cardGap)
    self.graph:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -M.cardGap)
    self.series = { values = {}, times = {} }

    ------------------------------------------------------------------
    -- Growth notice
    ------------------------------------------------------------------
    self.notice = UI.NoticePanel(frame, "Potential sustained memory growth", "", nil, nil, "warn")
    self.notice:SetPoint("TOPLEFT", self.graph, "BOTTOMLEFT", 0, -M.cardGap)
    self.notice:SetPoint("TOPRIGHT", self.graph, "BOTTOMRIGHT", 0, -M.cardGap)
    self.notice:Hide()

    ------------------------------------------------------------------
    -- Growth table
    ------------------------------------------------------------------
    self.table = UI.Table(frame, COLUMNS, {
        emptyMessage = "Waiting for the first per-addon memory scan",
        onRowClick = function(row2)
            local record = WTM.Processes:Get(row2.name)
            if record then UI.AddonDetail:Open(record) end
        end,
    })
    self:LayoutTable()
    self:OnLayout()
end

function Page:LayoutTable()
    local anchor = self.notice:IsShown() and self.notice or self.graph
    self.table:ClearAllPoints()
    self.table:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -M.cardGap)
    self.table:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -M.cardGap)
    self.table:SetPoint("BOTTOM", self.frame, "BOTTOM", 0, M.padding)
    self.table.LayoutHeader()
end

function Page:OnLayout()
    if not self.cardRow then return end
    if (self.cardRow:GetWidth() or 0) <= 0 then return end

    -- "ATTRIBUTED TO ADDONS" needs more than a fifth of a narrow window. The
    -- cards wrap onto a second row rather than trimming to "ATTR...".
    local ordered = {}
    for _, key in ipairs({ "total", "addons", "growth", "rate", "gc" }) do
        ordered[#ordered + 1] = self.cards[key]
    end
    self.cardRow:SetHeight(
        UI.LayoutCardRow(self.cardRow, ordered, { rowHeight = CARD_ROW_HEIGHT }))

    self:LayoutTable()
end

function Page:OnShow()
    self:OnLayout()
    self:Refresh()
end

--------------------------------------------------------------------------

function Page:Refresh()
    if not self.cards then return end
    local mem = WTM.Memory.current

    ------------------------------------------------------------------
    -- Cards
    ------------------------------------------------------------------
    self.cards.total:SetValue(Fmt.Memory(mem.luaKB), "")
    self.cards.total:SetSub(("peak %s"):format(Fmt.Memory(mem.luaPeakKB)))

    if WTM.Caps:Has("addonMemory") then
        self.cards.addons:SetAvailable()
        self.cards.addons:SetValue(Fmt.Memory(mem.addonSumKB), "")
        self.cards.addons:SetSub(mem.lastAddonScanAt > 0
            and ("scanned %s, cost %s"):format(
                Fmt.Ago(GetTime() - mem.lastAddonScanAt), Fmt.Ms(mem.addonScanCostMs))
            or "not scanned yet")
    else
        self.cards.addons:SetUnavailable(C.TXT_UNAVAILABLE_CLIENT)
    end

    local sessionGrowth = mem.luaKB - mem.luaStartKB
    self.cards.growth:SetValue(Fmt.MemoryDelta(sessionGrowth), "",
        sessionGrowth > 102400 and "warn" or nil)
    self.cards.growth:SetSub(("started at %s"):format(Fmt.Memory(mem.luaStartKB)))

    self.cards.rate:SetValue(Fmt.Memory(mem.growthKBPerMin), "/min",
        mem.growthKBPerMin > WTM.db.profile.memory.growthThresholdKBPerMin and "warn" or nil)
    self.cards.rate:SetSub("least-squares slope over the retained curve")

    self.cards.gc:SetValue(tostring(WTM.Memory.heapDrops.events), "")
    self.cards.gc:SetSub(WTM.Memory.heapDrops.lastAt
        and ("last %s, reclaimed %s"):format(
            Fmt.Ago(GetTime() - WTM.Memory.heapDrops.lastAt),
            Fmt.Memory(WTM.Memory.heapDrops.lastFreedKB))
        or "none observed yet")

    self.cards.peak:SetValue(Fmt.Memory(mem.luaPeakKB or 0), "")
    self.cards.peak:SetSub("highest the heap has been this session")

    -- The lowest point the heap reached, which is the closest thing to a
    -- "floor" this addon can observe. It is not a measurement of live data:
    -- WoW reports no collection statistics, so all this says is that the heap
    -- was once this small.
    local ring = WTM.Memory.history.lua
    local low
    if ring and ring.count > 0 then
        low = ring:Get(1)
        for i = 2, ring.count do
            local v = ring:Get(i)
            if v < low then low = v end
        end
    end
    if low then
        self.cards.low:SetValue(Fmt.Memory(low), "")
        self.cards.low:SetSub("lowest point in the retained curve")
    else
        self.cards.low:SetUnavailable("No heap history retained yet.")
    end

    if WTM.Caps:Has("addonMemory") then
        self.cards.largest:SetAvailable()
        self.cards.fastest:SetAvailable()

        local top = WTM.Memory:GetTopConsumers(self._topScratch or {}, 1)
        self._topScratch = top
        if top[1] then
            self.cards.largest:SetValue(Fmt.Truncate(top[1].title or top[1].name, 14), "")
            self.cards.largest:SetSub(Fmt.Memory(top[1].memKB or 0))
        else
            self.cards.largest:SetValue("-", "")
            self.cards.largest:SetSub("no per-addon scan yet")
        end

        local growth = WTM.Memory:GetGrowthRanking(self._growthScratch or {}, 1)
        self._growthScratch = growth
        if growth[1] and (growth[1].perMinute or 0) > 0 then
            self.cards.fastest:SetValue(Fmt.Truncate(growth[1].title or growth[1].name, 14), "")
            self.cards.fastest:SetSub(("%s per minute"):format(Fmt.Memory(growth[1].perMinute)))
        else
            self.cards.fastest:SetValue("none", "")
            self.cards.fastest:SetSub("no addon is growing measurably")
        end
    else
        self.cards.largest:SetUnavailable(C.TXT_UNAVAILABLE_CLIENT)
        self.cards.fastest:SetUnavailable(C.TXT_UNAVAILABLE_CLIENT)
    end

    for _, card in pairs(self.cards) do card:Refresh() end

    ------------------------------------------------------------------
    -- Heap graph
    ------------------------------------------------------------------
    local now = GetTime()
    local fromTime = now - math.max(300, math.min(3600, now - (WTM.state.sessionStart or now)))
    WTM.Recorder:GetSeries("luaKB", fromTime, now, 300, self.series.values, self.series.times)
    self.graph:SetSeries(1, self.series.values, self.series.times,
        { label = "Lua heap", colorIndex = 4 })
    self.graph:SetTimeRange(fromTime, now)
    if UI.MainWindow:ShouldRedrawGraphs() and UI.MainWindow:TakeGraphSlot(1, 1) then
        self.graph.dirty = true
        self.graph:Draw()
    end

    ------------------------------------------------------------------
    -- Growth table
    ------------------------------------------------------------------
    WTM.Memory:GetGrowthRanking(growthData, 40)
    self.table:SetData(growthData)
    self.table:SetEmpty(#growthData == 0)

    local sustained = 0
    for i = 1, #growthData do
        if growthData[i].sustained then sustained = sustained + 1 end
    end

    if sustained > 0 then
        local names = {}
        for i = 1, #growthData do
            if growthData[i].sustained and #names < 4 then
                names[#names + 1] = ("%s (%s/min)"):format(
                    growthData[i].title, Fmt.Memory(growthData[i].perMinute))
            end
        end
        self.notice:SetMessage(table.concat(names, ", ") ..
            ".  Sustained growth is not proof of a leak: addons legitimately grow while caching combat logs, auction data or scanned items. What distinguishes a leak is that the growth never levels off and survives leaving the situation that caused it.")
        if not self.notice:IsShown() then
            self.notice:Show()
            self:LayoutTable()
        end
    elseif self.notice:IsShown() then
        self.notice:Hide()
        self:LayoutTable()
    end
end
