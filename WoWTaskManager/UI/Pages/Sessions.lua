--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Sessions.lua
    Past sessions, their summary numbers and their stored graphs.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("sessions", {})

local sessionList = {}

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Session list on the left
    ------------------------------------------------------------------
    self.listCard = UI.Card(frame, "SESSIONS", {})
    self.listCard:SetWidth(320)
    self.listCard:SetPoint("TOPLEFT", pad, -pad)
    self.listCard:SetPoint("BOTTOMLEFT", pad, pad)

    self.list = UI.ScrollList(self.listCard.content, 46,
        function(parent)
            local row = CreateFrame("Button", nil, parent)
            row.when = UI.Text(row, "body", "textPrimary")
            row.when:SetPoint("TOPLEFT", 6, -6)
            row.who = UI.Text(row, "small", "textMuted")
            row.who:SetPoint("TOPLEFT", row.when, "BOTTOMLEFT", 0, -2)
            row.stats = UI.Text(row, "numericSm", "textSecondary", "RIGHT")
            row.stats:SetPoint("TOPRIGHT", -6, -6)
            row.spikes = UI.Text(row, "numericSm", "textMuted", "RIGHT")
            row.spikes:SetPoint("TOPRIGHT", row.stats, "BOTTOMRIGHT", 0, -2)
            return row
        end,
        function(row, session)
            row.when:SetText(Fmt.DateTime(session.startedAt))
            row.who:SetText(("%s  -  %s  -  %s")
                :format(session.character or "?", session.flavorName or session.flavor or "?",
                        Fmt.Duration(session.duration or 0)))
            row.stats:SetText(("%s fps avg"):format(Fmt.FPS(session.avgFPS or 0)))
            local total = session.spikeCount and session.spikeCount.total or 0
            row.spikes:SetText(("%d spikes"):format(total))
            row.spikes:SetTextColor(Theme:Tone(total > 20 and "warn" or "muted"))
        end,
        function(session) Page:Select(session) end)
    self.list:SetAllPoints(self.listCard.content)

    ------------------------------------------------------------------
    -- Detail on the right
    ------------------------------------------------------------------
    local detail = CreateFrame("Frame", nil, frame)
    detail:SetPoint("TOPLEFT", self.listCard, "TOPRIGHT", M.cardGap, 0)
    detail:SetPoint("BOTTOMRIGHT", -pad, pad)
    self.detail = detail

    local header = UI.Panel(detail, {})
    header:SetHeight(72)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    self.header = header

    header.title = UI.Text(header, "title", "textPrimary")
    header.title:SetPoint("TOPLEFT", 16, -12)
    header.sub = UI.Text(header, "small", "textSecondary")
    header.sub:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -4)
    header.sub:SetPoint("RIGHT", header, "RIGHT", -180, 0)
    header.sub:SetJustifyH("LEFT")

    self.deleteButton = UI.Button(header, "Delete session", function()
        if self.selectedIndex then
            WTM.Sessions:Delete(self.selectedIndex)
            self.selected, self.selectedIndex = nil, nil
            Page:Refresh()
        end
    end, { height = 22 })
    self.deleteButton:SetPoint("TOPRIGHT", -14, -14)
    self.deleteButton:Hide()

    -- Stat grid
    local stats = UI.Card(detail, "SUMMARY", {})
    stats:SetHeight(150)
    stats:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -M.cardGap)
    stats:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -M.cardGap)
    self.statsCard = stats

    self.statRows = {}
    local STAT_KEYS = {
        "Average FPS", "Minimum FPS", "1% low FPS", "0.1% low FPS", "Worst frame",
        "Spikes", "Freezes", "Average latency", "Peak latency", "Lua memory at end",
        "Lua growth", "Collections observed", "Event total", "Event storms",
        "Client", "CPU profiling",
    }
    for i, label in ipairs(STAT_KEYS) do
        local column = (i - 1) % 2
        local rowIndex = math.floor((i - 1) / 2)
        local statRow = UI.StatRow(stats.content, label)
        statRow:SetPoint("TOPLEFT", stats.content, "TOPLEFT",
            column * ((stats:GetWidth() or 600) / 2), -rowIndex * 16)
        statRow:SetWidth(280)
        self.statRows[label] = statRow
        statRow.column, statRow.rowIndex = column, rowIndex
    end

    -- Top lists
    self.topCard = UI.Card(detail, "TOP CONSUMERS", {})
    self.topCard:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -M.cardGap)
    self.topCard:SetPoint("BOTTOMRIGHT")
    self.topRows = {}
    for i = 1, 10 do
        local statRow = UI.StatRow(self.topCard.content, "")
        statRow:SetPoint("TOPLEFT", 0, -(i - 1) * 18)
        statRow:SetWidth(300)
        self.topRows[i] = statRow
    end
    self.topMemRows = {}
    for i = 1, 10 do
        local statRow = UI.StatRow(self.topCard.content, "")
        statRow:SetPoint("TOPRIGHT", 0, -(i - 1) * 18)
        statRow:SetWidth(300)
        self.topMemRows[i] = statRow
    end

    self.empty = UI.EmptyState(detail, "Select a session on the left")
    self.empty:SetAllPoints(detail)
end

function Page:OnLayout()
    if not self.statRows then return end
    local width = (self.statsCard:GetWidth() or 600) - M.padding * 2
    for _, statRow in pairs(self.statRows) do
        statRow:ClearAllPoints()
        statRow:SetPoint("TOPLEFT", self.statsCard.content, "TOPLEFT",
            statRow.column * (width / 2), -statRow.rowIndex * 16)
        statRow:SetWidth(width / 2 - 20)
    end
end

function Page:OnShow()
    self:Refresh()
    self:OnLayout()
end

function Page:Select(session)
    self.selected = session
    for i, stored in ipairs(WTM.db.global.sessions) do
        if stored == session then self.selectedIndex = i break end
    end
    self:RefreshDetail()
end

--------------------------------------------------------------------------

function Page:Refresh()
    local stored = WTM.db.global.sessions
    for i = #sessionList, 1, -1 do sessionList[i] = nil end

    -- The live session first, so you can see the one you are in.
    local live = WTM.Sessions:UpdateSummary()
    if live then
        sessionList[1] = live
        live.isLive = true
    end
    for i = 1, #stored do sessionList[#sessionList + 1] = stored[i] end

    self.list:SetData(sessionList)

    if not self.selected then
        self.selected = sessionList[1]
        self.selectedIndex = nil
    end
    self:RefreshDetail()
end

local function Set(page, key, value, tone)
    local statRow = page.statRows[key]
    if statRow then statRow:Set(value, tone) end
end

function Page:RefreshDetail()
    local session = self.selected
    self.empty:SetShown(session == nil)
    self.header:SetShown(session ~= nil)
    self.statsCard:SetShown(session ~= nil)
    self.topCard:SetShown(session ~= nil)
    if not session then return end

    self.header.title:SetText(session.isLive and "Current session"
        or Fmt.DateTime(session.startedAt))
    self.header.sub:SetText(UI.FitText(self.header.sub,
        ("%s - %s  |  %s %s (build %s)  |  %s  |  %s")
        :format(session.character or "?", session.realm or "?",
                session.flavorName or session.flavor or "?", session.version or "?",
                session.build or "?", session.locale or "?",
                Fmt.Duration(session.duration or 0))))

    self.deleteButton:SetShown(not session.isLive and self.selectedIndex ~= nil)

    local spikes = session.spikeCount or {}
    Set(self, "Average FPS",        Fmt.FPS(session.avgFPS or 0))
    Set(self, "Minimum FPS",        Fmt.FPS(session.minFPS or 0))
    Set(self, "1% low FPS",         Fmt.FPS(session.low1 or 0))
    Set(self, "0.1% low FPS",       Fmt.FPS(session.low01 or 0))
    Set(self, "Worst frame",        Fmt.Ms(session.maxFrameMs or 0))
    Set(self, "Spikes",             tostring(spikes.total or 0), (spikes.total or 0) > 20 and "warn" or nil)
    Set(self, "Freezes",            tostring(spikes.freeze or 0), (spikes.freeze or 0) > 0 and "crit" or nil)
    Set(self, "Average latency",    ("%d ms"):format(math.floor(session.avgLatencyWorld or 0)))
    Set(self, "Peak latency",       ("%d ms"):format(session.peakLatencyWorld or 0))
    Set(self, "Lua memory at end",  Fmt.Memory(session.luaEndKB or 0))
    Set(self, "Lua growth",         Fmt.MemoryDelta((session.luaEndKB or 0) - (session.luaStartKB or 0)))
    Set(self, "Collections observed", tostring(session.gcEvents or 0))
    Set(self, "Event total",        Fmt.Comma(session.eventTotal or 0))
    Set(self, "Event storms",       tostring(session.eventStorms or 0))
    Set(self, "Client",             ("%s %s"):format(session.flavorName or "?", session.version or "?"))
    Set(self, "CPU profiling",      session.profilingEnabled and "on" or "off",
        session.profilingEnabled and nil or "muted")

    ------------------------------------------------------------------
    -- Top consumers
    ------------------------------------------------------------------
    local topCPU = session.topCPU
    for i, statRow in ipairs(self.topRows) do
        local entry = topCPU and topCPU[i]
        statRow:SetShown(entry ~= nil or i == 1)
        if entry then
            statRow:SetLabel(("CPU  %s"):format(Fmt.Truncate(entry.name, 20)))
            statRow:Set(("%.2f %%"):format(entry.avgPct))
        elseif i == 1 then
            statRow:SetLabel(topCPU and "No addon CPU recorded" or "CPU profiling was off")
            statRow:Set("")
        end
    end

    local topMem = session.topMemory
    for i, statRow in ipairs(self.topMemRows) do
        local entry = topMem and topMem[i]
        statRow:SetShown(entry ~= nil)
        if entry then
            statRow:SetLabel(("MEM  %s"):format(Fmt.Truncate(entry.name, 20)))
            statRow:Set(Fmt.MemoryDelta(entry.growthKB))
        end
    end
end
