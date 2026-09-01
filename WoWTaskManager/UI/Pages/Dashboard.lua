--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Dashboard.lua

    The overview: six live metric cards, a health verdict, the top CPU and
    memory consumers, recent incidents, and this addon's own cost.

    Cards for measurements the client cannot provide put themselves into their
    "unavailable" state with the reason, rather than showing a zero.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("dashboard", {})

local CARD_SPECS = {
    { key = "fps",     label = "FRAMES PER SECOND", unit = "fps",  colorIndex = 1,
      tooltip = "Measured from the real per-frame delta, not the client's smoothed GetFramerate value." },
    { key = "frame",   label = "FRAME TIME", unit = "ms", colorIndex = 2, invert = true,
      tooltip = "Average time to render one frame in the current sample window. 60 FPS is 16.67 ms, 120 FPS is 8.33 ms." },
    { key = "latency", label = "WORLD LATENCY", unit = "ms", colorIndex = 3, invert = true,
      tooltip = "From GetNetStats. The client only refreshes this roughly every 30 seconds, so it is never a live figure." },
    { key = "memory",  label = "LUA MEMORY", unit = "", colorIndex = 4, invert = true,
      tooltip = "Total Lua heap across the client and every addon." },
    { key = "cpu",     label = "ADDON CPU", unit = "%", colorIndex = 5, invert = true,
      tooltip = "Share of one CPU core spent inside addon Lua. Requires the client's scriptProfile CVar." },
    { key = "events",  label = "EVENTS", unit = "/s", colorIndex = 6, invert = true,
      tooltip = "Every event the client fired, counted via a frame with RegisterAllEvents." },
}

function Page:Build(frame)
    local pad = M.padding
    self.cards = {}

    ------------------------------------------------------------------
    -- Health banner
    ------------------------------------------------------------------
    local banner = UI.Panel(frame, { color = "panelBg" })
    banner:SetHeight(58)
    banner:SetPoint("TOPLEFT", pad, -pad)
    banner:SetPoint("TOPRIGHT", -pad, -pad)
    self.banner = banner

    banner.accent = banner:CreateTexture(nil, "ARTWORK")
    banner.accent:SetWidth(3)
    banner.accent:SetPoint("TOPLEFT")
    banner.accent:SetPoint("BOTTOMLEFT")

    banner.verdict = UI.Text(banner, "title", "textPrimary")
    banner.verdict:SetPoint("TOPLEFT", 18, -10)

    banner.detail = UI.Text(banner, "small", "textSecondary")
    banner.detail:SetPoint("TOPLEFT", banner.verdict, "BOTTOMLEFT", 0, -4)
    banner.detail:SetPoint("RIGHT", banner, "RIGHT", -220, 0)
    banner.detail:SetJustifyH("LEFT")

    banner.uptime = UI.Text(banner, "numeric", "textSecondary", "RIGHT")
    banner.uptime:SetPoint("TOPRIGHT", -18, -12)
    banner.uptimeLabel = UI.Text(banner, "tiny", "textMuted", "RIGHT")
    banner.uptimeLabel:SetPoint("TOPRIGHT", banner.uptime, "BOTTOMRIGHT", 0, -2)
    banner.uptimeLabel:SetText("SESSION")

    ------------------------------------------------------------------
    -- Metric cards
    ------------------------------------------------------------------
    local row = CreateFrame("Frame", nil, frame)
    row:SetHeight(M.cardHeight)
    row:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -M.cardGap)
    row:SetPoint("TOPRIGHT", banner, "BOTTOMRIGHT", 0, -M.cardGap)
    self.cardRow = row

    for i, spec in ipairs(CARD_SPECS) do
        local card = UI.MetricCard(row, spec)
        card:SetPoint("TOP")
        card:SetPoint("BOTTOM")
        self.cards[spec.key] = card
        card.specIndex = i
    end

    ------------------------------------------------------------------
    -- Bottom: three columns
    ------------------------------------------------------------------
    local columns = CreateFrame("Frame", nil, frame)
    columns:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -M.cardGap)
    columns:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
    self.columns = columns

    -- Column 1: top CPU
    self.cpuCard = UI.Card(columns, "TOP CPU", {})
    self.cpuCard:SetPoint("TOPLEFT")
    self.cpuCard:SetPoint("BOTTOMLEFT")
    self.cpuRows = {}
    for i = 1, 6 do
        local statRow = UI.StatRow(self.cpuCard.content, "")
        statRow:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
        statRow:SetPoint("TOPRIGHT", 0, -(i - 1) * 20)
        self.cpuRows[i] = statRow
    end
    self.cpuNotice = UI.Text(self.cpuCard.content, "small", "textMuted")
    self.cpuNotice:SetPoint("TOPLEFT")
    self.cpuNotice:SetPoint("RIGHT")
    self.cpuNotice:SetJustifyH("LEFT")
    self.cpuNotice:SetWordWrap(true)
    self.cpuNotice:Hide()

    self.enableProfilingButton = UI.Button(self.cpuCard.content, "Enable CPU profiling", function()
        WTM.Caps:ToggleCPUProfiling()
        Page:Refresh()
    end, { primary = true, height = 22 })
    self.enableProfilingButton:SetPoint("BOTTOMLEFT")
    self.enableProfilingButton:Hide()

    -- Column 2: top memory
    self.memCard = UI.Card(columns, "TOP MEMORY", {})
    self.memCard:SetPoint("TOPLEFT", self.cpuCard, "TOPRIGHT", M.cardGap, 0)
    self.memCard:SetPoint("BOTTOM")
    self.memRows = {}
    for i = 1, 6 do
        local statRow = UI.StatRow(self.memCard.content, "")
        statRow:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
        statRow:SetPoint("TOPRIGHT", 0, -(i - 1) * 20)
        self.memRows[i] = statRow
    end

    -- Column 3: recent incidents
    self.incidentCard = UI.Card(columns, "RECENT INCIDENTS", {})
    self.incidentCard:SetPoint("TOPLEFT", self.memCard, "TOPRIGHT", M.cardGap, 0)
    self.incidentCard:SetPoint("BOTTOMRIGHT")
    self.incidentRows = {}
    for i = 1, 6 do
        local entry = CreateFrame("Button", nil, self.incidentCard.content)
        entry:SetHeight(20)
        entry:SetPoint("TOPLEFT", 0, -(i - 1) * 21)
        entry:SetPoint("TOPRIGHT", 0, -(i - 1) * 21)
        entry.kind = UI.Text(entry, "small", "textPrimary")
        entry.kind:SetPoint("LEFT")
        entry.detail = UI.Text(entry, "numericSm", "textMuted", "RIGHT")
        entry.detail:SetPoint("RIGHT")
        entry:SetScript("OnClick", function(self)
            if self.spike then UI.MainWindow:ShowPage("timeline") end
        end)
        entry:SetScript("OnEnter", function(self)
            if not self.spike then return end
            UI.TooltipClear(self.spike.label)
            for line in WTM.SpikeDetector:Describe(self.spike):gmatch("[^\n]+") do
                UI.TooltipLine(line)
            end
            UI.TooltipShow(self)
        end)
        entry:SetScript("OnLeave", UI.HideTooltip)
        self.incidentRows[i] = entry
    end
    self.incidentEmpty = UI.Text(self.incidentCard.content, "small", "textMuted")
    self.incidentEmpty:SetPoint("TOPLEFT")
    self.incidentEmpty:SetText("No spikes recorded yet.")

    ------------------------------------------------------------------
    -- Overhead strip along the very bottom of column 1
    ------------------------------------------------------------------
    self.overheadNotice = nil

    self:OnLayout()
end

function Page:OnLayout()
    local frame = self.frame
    if not frame then return end

    local width = frame:GetWidth() - M.padding * 2
    local count = #CARD_SPECS
    local cardWidth = (width - M.cardGap * (count - 1)) / count

    local previous
    for i, spec in ipairs(CARD_SPECS) do
        local card = self.cards[spec.key]
        card:ClearAllPoints()
        card:SetPoint("TOP")
        card:SetPoint("BOTTOM")
        card:SetWidth(cardWidth)
        if previous then
            card:SetPoint("LEFT", previous, "RIGHT", M.cardGap, 0)
        else
            card:SetPoint("LEFT")
        end
        previous = card
    end

    local columnWidth = (width - M.cardGap * 2) / 3
    self.cpuCard:SetWidth(columnWidth)
    self.memCard:SetWidth(columnWidth)
end

--------------------------------------------------------------------------

local cpuScratch, memScratch, spikeScratch = {}, {}, {}

function Page:Refresh()
    local ft   = WTM.FrameTime.current
    local cards = self.cards

    ------------------------------------------------------------------
    -- Cards
    ------------------------------------------------------------------
    local stats = WTM.FrameTime:GetSessionStats()

    cards.fps:SetValue(Fmt.FPS(ft.fps), "fps",
        ft.fps >= 55 and "ok" or (ft.fps >= 30 and "warn" or "crit"))
    cards.fps:SetSub(("1%% low %s   avg %s"):format(Fmt.FPS(stats.low1), Fmt.FPS(stats.avgFPS)))
    cards.fps:SetRing(WTM.FrameTime.history.fps)

    cards.frame:SetValue(("%.1f"):format(ft.avgMs), "ms",
        ft.avgMs <= 20 and "ok" or (ft.avgMs <= 40 and "warn" or "crit"))
    cards.frame:SetSub(("worst %s   baseline %s"):format(Fmt.Ms(stats.maxMs), Fmt.Ms(ft.baselineMs)))
    cards.frame:SetRing(WTM.FrameTime.history.frameMs)

    if WTM.Caps:Has("latency") then
        local net = WTM.Network.current
        cards.latency:SetAvailable()
        cards.latency:SetValue(tostring(net.latencyWorld), "ms",
            net.latencyWorld <= 80 and "ok" or (net.latencyWorld <= 200 and "warn" or "crit"))
        cards.latency:SetSub(WTM.Network:IsStale()
            and ("home %d ms   reading is stale"):format(net.latencyHome)
            or ("home %d ms"):format(net.latencyHome))
        cards.latency:SetRing(WTM.Network.history.world)
    else
        cards.latency:SetUnavailable(WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT)
    end

    local mem = WTM.Memory.current
    cards.memory:SetValue(Fmt.Memory(mem.luaKB), "")
    cards.memory:SetSub(("%s since login   %s addons")
        :format(Fmt.MemoryDelta(mem.luaKB - mem.luaStartKB), Fmt.Memory(mem.addonSumKB)))
    cards.memory:SetRing(WTM.Memory.history.lua)

    if WTM.CPU.available then
        cards.cpu:SetAvailable()
        local pct = WTM.CPU.current.totalPct
        cards.cpu:SetValue(("%.1f"):format(pct), "%",
            pct <= 8 and "ok" or (pct <= 20 and "warn" or "crit"))
        cards.cpu:SetSub(("%d addons measured"):format(#WTM.Processes.list))
    else
        cards.cpu:SetUnavailable(WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
    end

    if WTM.Events.available then
        cards.events:SetAvailable()
        cards.events:SetValue(Fmt.Comma(math.floor(WTM.Events.current.perSecond)), "/s")
        cards.events:SetSub(("%d distinct   peak %s")
            :format(WTM.Events:GetDistinctCount(), Fmt.Rate(WTM.Events.current.peakPerSecond)))
        cards.events:SetRing(WTM.Events.history)
    else
        cards.events:SetUnavailable(WTM.Events.reason or C.TXT_UNAVAILABLE_CLIENT)
    end

    for _, card in pairs(cards) do card:Refresh() end

    ------------------------------------------------------------------
    -- Health banner
    ------------------------------------------------------------------
    local health, score, info = WTM.Diagnostics:ComputeHealth()
    self.banner.accent:SetColorTexture(Theme:Tone(health.tone))
    self.banner.verdict:SetText(("Performance: %s"):format(health.text))
    self.banner.verdict:SetTextColor(Theme:Tone(health.tone))

    local counts = WTM.SpikeDetector.counts
    self.banner.detail:SetText(("%d spikes  (%d freeze, %d heavy, %d stutter, %d minor)   -   %.1f per minute   -   health score %d/100")
        :format(WTM.SpikeDetector.total, counts.freeze, counts.heavy, counts.stutter, counts.minor,
                info.spikesPerMinute, score))
    self.banner.uptime:SetText(Fmt.Duration(info.duration))

    ------------------------------------------------------------------
    -- Top CPU
    ------------------------------------------------------------------
    if WTM.CPU.available then
        self.cpuNotice:Hide()
        self.enableProfilingButton:Hide()
        local top = WTM.CPU:GetTopConsumers(cpuScratch, #self.cpuRows)
        for i, statRow in ipairs(self.cpuRows) do
            local entry = top[i]
            statRow:SetShown(entry ~= nil)
            if entry then
                statRow:SetLabel(Fmt.Truncate(entry.title, 22))
                statRow:Set(("%.2f %%"):format(entry.pct),
                    entry.pct >= C.HIGH_CPU_PCT and "crit"
                    or (entry.pct >= C.ELEVATED_CPU_PCT and "warn" or nil))
            end
        end
        if #top == 0 then
            self.cpuRows[1]:Show()
            self.cpuRows[1]:SetLabel("No measurable addon CPU yet")
            self.cpuRows[1]:Set("")
        end
    else
        for _, statRow in ipairs(self.cpuRows) do statRow:Hide() end
        self.cpuNotice:SetText(
            "Per-addon CPU time needs the client's scriptProfile CVar, which takes effect after a reload. It has a cost of its own, so leave it off when you are not measuring.")
        self.cpuNotice:Show()
        self.enableProfilingButton:SetShown(WTM.Caps:Has("toggleProfiling"))
    end

    ------------------------------------------------------------------
    -- Top memory
    ------------------------------------------------------------------
    local topMem = WTM.Memory:GetTopConsumers(memScratch, #self.memRows)
    for i, statRow in ipairs(self.memRows) do
        local entry = topMem[i]
        statRow:SetShown(entry ~= nil)
        if entry then
            statRow:SetLabel(Fmt.Truncate(entry.title, 22))
            statRow:Set(Fmt.Memory(entry.memKB))
        end
    end
    if #topMem == 0 then
        self.memRows[1]:Show()
        self.memRows[1]:SetLabel("Waiting for the first memory scan")
        self.memRows[1]:Set("")
    end

    ------------------------------------------------------------------
    -- Recent incidents
    ------------------------------------------------------------------
    local spikes = WTM.SpikeDetector:GetRecent(spikeScratch, #self.incidentRows)
    self.incidentEmpty:SetShown(#spikes == 0)
    for i, entry in ipairs(self.incidentRows) do
        local spike = spikes[i]
        entry:SetShown(spike ~= nil)
        entry.spike = spike
        if spike then
            entry.kind:SetText(spike.label)
            entry.kind:SetTextColor(Theme:Tone(
                spike.kind == "freeze" and "crit" or (spike.kind == "heavy" and "crit" or "warn")))
            entry.detail:SetText(("%s   %s"):format(Fmt.Ms(spike.frameMs), Fmt.Ago(GetTime() - spike.t)))
        end
    end
end
