--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Sidebar.lua

    Navigation column.  The active item is marked by a 4 px accent bar on its
    left edge and a brighter label - no boxes, no highlight rectangles, no
    Blizzard tab art.

    The footer carries the two facts that should always be visible in a
    monitoring tool: whether it is recording, and what it is costing you.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Sidebar = {}
UI.Sidebar = Sidebar

local NAV = {
    { key = "dashboard",   label = "Dashboard" },
    { key = "processes",   label = "Processes" },
    { key = "performance", label = "Performance" },
    { key = "incidents",   label = "Incidents" },
    { key = "timeline",    label = "Timeline" },
    { key = "events",      label = "Events" },
    { key = "memory",      label = "Memory" },
    { key = "diagnostics", label = "Diagnostics" },
    { key = "sessions",    label = "Sessions" },
    { separator = true },
    { key = "system",      label = "System" },
    { key = "settings",    label = "Settings" },
}

Sidebar.items = {}

function Sidebar:Build(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetWidth(M.sidebarWidth)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 1, -M.topbarHeight)
    frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 1, 1)
    UI.Fill(frame, "sidebarBg")
    UI.Border(frame, "R", "borderSubtle")
    self.frame = frame

    local y = -M.paddingSmall
    for _, entry in ipairs(NAV) do
        if entry.separator then
            local divider = UI.Divider(frame)
            divider:SetPoint("TOPLEFT", 16, y - 6)
            divider:SetPoint("TOPRIGHT", -16, y - 6)
            y = y - 14
        else
            local item = CreateFrame("Button", nil, frame)
            item:SetHeight(M.navItemHeight)
            item:SetPoint("TOPLEFT", 0, y)
            item:SetPoint("TOPRIGHT", 0, y)

            item.hover = item:CreateTexture(nil, "BACKGROUND")
            item.hover:SetAllPoints()
            item.hover:SetColorTexture(T("hover", 0.7))
            item.hover:Hide()

            item.rule = item:CreateTexture(nil, "ARTWORK")
            item.rule:SetWidth(3)
            item.rule:SetPoint("TOPLEFT", 0, -4)
            item.rule:SetPoint("BOTTOMLEFT", 0, 4)
            item.rule:SetColorTexture(T("accent"))
            item.rule:Hide()

            item.text = UI.Text(item, "body", "textSecondary")
            item.text:SetPoint("LEFT", 18, 0)
            item.text:SetText(entry.label)

            -- Right-aligned count badge (spike count, storm count, ...)
            item.badge = UI.Text(item, "numericSm", "textMuted", "RIGHT")
            item.badge:SetPoint("RIGHT", -14, 0)

            item.key = entry.key
            item:SetScript("OnEnter", function(self)
                self.hover:Show()
                if not self.active then self.text:SetTextColor(T("textPrimary")) end
            end)
            item:SetScript("OnLeave", function(self)
                self.hover:Hide()
                if not self.active then self.text:SetTextColor(T("textSecondary")) end
            end)
            item:SetScript("OnClick", function(self)
                UI.MainWindow:ShowPage(self.key)
            end)

            self.items[entry.key] = item
            y = y - M.navItemHeight
        end
    end

    ------------------------------------------------------------------
    -- Footer status
    ------------------------------------------------------------------
    local footer = CreateFrame("Frame", nil, frame)
    footer:SetHeight(94)
    footer:SetPoint("BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", 0, 0)
    UI.Border(footer, "T", "borderSubtle")
    self.footer = footer

    footer.dot = footer:CreateTexture(nil, "ARTWORK")
    footer.dot:SetSize(6, 6)
    footer.dot:SetPoint("TOPLEFT", 18, -12)

    footer.state = UI.Text(footer, "small", "textSecondary")
    footer.state:SetPoint("LEFT", footer.dot, "RIGHT", 8, 0)

    footer.overhead = UI.Text(footer, "tiny", "textMuted")
    footer.overhead:SetPoint("TOPLEFT", 18, -30)
    footer.overhead:SetPoint("RIGHT", -12, 0)
    footer.overhead:SetJustifyH("LEFT")
    footer.overhead:SetWordWrap(false)

    footer.budget = UI.Text(footer, "tiny", "textMuted")
    footer.budget:SetPoint("TOPLEFT", 18, -44)
    footer.budget:SetPoint("RIGHT", -12, 0)
    footer.budget:SetJustifyH("LEFT")
    footer.budget:SetWordWrap(false)

    footer.coverage = UI.Text(footer, "tiny", "textMuted")
    footer.coverage:SetPoint("TOPLEFT", 18, -60)
    footer.coverage:SetPoint("RIGHT", -12, 0)
    footer.coverage:SetJustifyH("LEFT")
    footer.coverage:SetWordWrap(false)

    footer.history = UI.Text(footer, "tiny", "textMuted")
    footer.history:SetPoint("TOPLEFT", 18, -74)
    footer.history:SetPoint("RIGHT", -12, 0)
    footer.history:SetJustifyH("LEFT")
    footer.history:SetWordWrap(false)

    footer:EnableMouse(true)
    footer:SetScript("OnEnter", function(self)
        UI.TooltipClear("Monitoring status")
        UI.TooltipLine("Sampling", WTM.Scheduler:IsRunning() and "running" or "stopped")
        UI.TooltipLine("Own cost", ("%.2f ms/s"):format(WTM.Overhead.current.samplingMsPerSec))
        UI.TooltipLine("Frame budget", ("%.2f %% of a 60 FPS frame"):format(WTM.Overhead:GetFrameBudgetPercent()))
        UI.TooltipLine("Own memory", Fmt.Memory(WTM.Overhead.current.memKB))
        UI.TooltipLine("Flight recorder", ("%s of history"):format(
            Fmt.Duration(WTM.FlightRecorder:GetCoverageSeconds())))
        UI.TooltipLine("Adaptive burst", WTM.Scheduler:IsBursting()
            and ("active, %.0fs left"):format(WTM.Scheduler:BurstRemaining()) or "idle")
        if WTM.Scheduler.cost.throttled then
            UI.TooltipLine("Throttle", ("level %d - intervals stretched to stay in budget")
                :format(WTM.Scheduler.cost.throttleLevel), nil, "warn")
        end
        UI.TooltipShow(self, "BOTTOMLEFT")
    end)
    footer:SetScript("OnLeave", UI.HideTooltip)

    return frame
end

function Sidebar:SetActive(key)
    for itemKey, item in pairs(self.items) do
        local active = itemKey == key
        item.active = active
        item.rule:SetShown(active)
        item.text:SetTextColor(T(active and "textPrimary" or "textSecondary"))
    end
end

function Sidebar:Refresh()
    if not self.frame then return end

    local spikes = WTM.SpikeDetector.total
    local storms = #WTM.Events.storms

    local function badge(key, count, tone)
        local item = self.items[key]
        if not item then return end
        if count and count > 0 then
            item.badge:SetText(count > 999 and "999+" or tostring(count))
            item.badge:SetTextColor(Theme:Tone(tone or "muted"))
        else
            item.badge:SetText("")
        end
    end

    badge("incidents", #WTM.SpikeDetector.clusters + (WTM.SpikeDetector:GetOpenCluster() and 1 or 0),
        spikes > 0 and "warn" or nil)
    badge("timeline", spikes, spikes > 0 and "warn" or nil)
    badge("events", storms, storms > 0 and "warn" or nil)
    badge("sessions", #WTM.db.global.sessions)

    local findings = WTM.Diagnostics:Build(self._findingScratch or {})
    self._findingScratch = findings
    local bad = 0
    for i = 1, #findings do
        if findings[i].tone == "warn" or findings[i].tone == "crit" then bad = bad + 1 end
    end
    badge("diagnostics", bad, bad > 0 and "warn" or nil)

    ------------------------------------------------------------------
    -- Footer
    ------------------------------------------------------------------
    local footer = self.footer
    local recording = WTM.Scheduler:IsRunning() and WTM.db.profile.sampling.enabled
    local overheadTone = WTM.Overhead.current.verdict

    if not recording then
        footer.dot:SetColorTexture(Theme:Tone("muted"))
        footer.state:SetText("Paused")
    elseif WTM.Scheduler:IsBursting() then
        footer.dot:SetColorTexture(Theme:Tone("warn"))
        footer.state:SetText("Recording (burst)")
    else
        footer.dot:SetColorTexture(Theme:Tone("ok"))
        footer.state:SetText("Recording")
    end

    -- One line per fact, and the ms and the percentage now describe the SAME
    -- number: previously this printed the sampling-only cost next to a
    -- percentage derived from the total, which disagreed with the dashboard.
    local tone = overheadTone == "critical" and "crit"
        or (overheadTone == "elevated" and "warn" or "muted")

    footer.overhead:SetText(("overhead %.2f ms/s total")
        :format(WTM.Overhead.current.totalMsPerSec))
    footer.overhead:SetTextColor(Theme:Tone(tone))

    footer.budget:SetText(("%.2f%% of a frame at %s fps")
        :format(WTM.Overhead:GetFrameBudgetPercent(), Fmt.FPS(WTM.FrameTime.current.fps)))
    footer.budget:SetTextColor(Theme:Tone(tone))

    footer.coverage:SetText(("recorder %s")
        :format(Fmt.Duration(WTM.FlightRecorder:GetCoverageSeconds())))
    footer.history:SetText(("history %s")
        :format(Fmt.Duration(WTM.Recorder:GetCoverage())))
end
