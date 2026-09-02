--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/LiveMonitor.lua

    The compact always-on readout: FPS, frame time, latency, addon CPU, memory
    and event rate in a small movable panel, with optional sparklines.

    This is meant to sit on screen while you play, so its cost matters more than
    anywhere else in the addon:

      * text only by default - sparklines are opt-in, because they are the
        expensive part of any graph,
      * updates on the same schedule as the main window and only while shown,
      * sparkline redraws go through the same gate as the main window's graphs,
        so they follow the data rate rather than the refresh rate,
      * no background, border or shadow when locked, so it reads as an overlay
        rather than another window competing for attention.

    Toggle with /wtm mini.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local LiveMonitor = WTM:NewModule("LiveMonitor")
UI.LiveMonitor = LiveMonitor

local ROWS = {
    { key = "fps",     label = "FPS",     colorIndex = 1, worstIsLow = true },
    { key = "frame",   label = "FRAME",   colorIndex = 2 },
    { key = "latency", label = "WORLD",   colorIndex = 3 },
    { key = "cpu",     label = "CPU",     colorIndex = 5 },
    { key = "memory",  label = "MEMORY",  colorIndex = 4 },
    { key = "events",  label = "EVENTS",  colorIndex = 6 },
}

local ROW_HEIGHT = 17

--------------------------------------------------------------------------

function LiveMonitor:Build()
    if self.frame then return self.frame end

    local settings = WTM.db.profile.liveMonitor

    local frame = CreateFrame("Frame", "WTMLiveMonitor", UIParent)
    frame:SetSize(settings.width, 30 + #ROWS * ROW_HEIGHT)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:Hide()
    self.frame = frame

    if settings.point then
        frame:SetPoint(settings.point, UIParent, settings.point,
            settings.x or 0, settings.y or 0)
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 24, -160)
    end

    frame.bg = UI.Fill(frame, "windowBg", settings.opacity)
    frame.borders = UI.Border(frame, "TLBR", "borderSubtle")

    ------------------------------------------------------------------
    -- Header, which doubles as the drag handle
    ------------------------------------------------------------------
    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(22)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    self.header = header

    header.mark = header:CreateTexture(nil, "ARTWORK")
    header.mark:SetSize(6, 6)
    header.mark:SetPoint("LEFT", 8, 0)
    header.mark:SetColorTexture(T("accent"))

    header.title = UI.Text(header, "small", "textSecondary")
    header.title:SetPoint("LEFT", header.mark, "RIGHT", 6, 0)
    header.title:SetText("Task Manager")

    -- Collapsed, the header carries the two numbers worth a glance, so the
    -- panel is still useful at one line high.
    header.summary = UI.Text(header, "numericSm", "textPrimary", "RIGHT")
    header.summary:Hide()

    ------------------------------------------------------------------
    -- Header controls. Three buttons, right to left, each with a tooltip:
    -- everything this panel can do is reachable without typing a command.
    ------------------------------------------------------------------
    header.open = UI.Button(header, "open", function()
        UI.MainWindow:Open()
    end, { height = 16, style = "tiny", minWidth = 30 })
    header.open:SetPoint("RIGHT", -4, 0)
    header.open.tooltip = "Open the full window."

    header.config = UI.Button(header, "cfg", function()
        UI.MainWindow:Open("settings")
    end, { height = 16, style = "tiny", minWidth = 26 })
    header.config:SetPoint("RIGHT", header.open, "LEFT", -3, 0)
    header.config.tooltip = "Open the Settings page, where every option and every command has a button."

    header.collapse = UI.Button(header, "-", function()
        LiveMonitor:SetCollapsed(not WTM.db.profile.liveMonitor.collapsed)
    end, { width = 18, height = 16, style = "tiny" })
    header.collapse:SetPoint("RIGHT", header.config, "LEFT", -3, 0)
    header.collapse.tooltip = "Collapse to a single line. The panel stays on screen and keeps recording."
    header.summary:SetPoint("RIGHT", header.collapse, "LEFT", -6, 0)
    header.summary:SetPoint("LEFT", header.title, "RIGHT", 6, 0)

    UI.MakeMovable(frame, header, function()
        local point, _, _, x, y = frame:GetPoint()
        settings.point, settings.x, settings.y = point, x, y
    end)

    ------------------------------------------------------------------
    -- Rows
    ------------------------------------------------------------------
    self.rows = {}
    for i, spec in ipairs(ROWS) do
        local row = CreateFrame("Frame", nil, frame)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -22 - (i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", 0, -22 - (i - 1) * ROW_HEIGHT)

        row.label = UI.Text(row, "tiny", "textMuted")
        row.label:SetPoint("LEFT", 9, 0)
        row.label:SetText(spec.label)

        row.value = UI.Text(row, "numericSm", "textPrimary", "RIGHT")
        row.value:SetPoint("RIGHT", -9, 0)

        -- A sparkline behind the numbers rather than beside them: the panel has
        -- to stay narrow enough not to be in the way.
        row.spark = UI.Sparkline(row, spec.colorIndex, spec.worstIsLow)
        row.spark:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
        row.spark:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
        row.spark:SetPoint("TOP", 0, -3)
        row.spark:SetPoint("BOTTOM", 0, 3)

        row.spec = spec
        self.rows[spec.key] = row
    end

    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self2)
        UI.TooltipClear("Live monitor")
        UI.TooltipLine("Drag", "the header to move")
        UI.TooltipLine("open", "the full window")
        UI.TooltipLine("cfg", "the settings page")
        UI.TooltipLine("- / +", "collapse or expand")
        UI.TooltipLine("/wtm mini", "hide it again")
        local warning = WTM.Overhead:GetWarning()
        if warning then UI.TooltipLine(warning, nil, "warn") end
        UI.TooltipShow(self2)
    end)
    frame:SetScript("OnLeave", UI.HideTooltip)

    self:ApplySettings()
    return frame
end

--------------------------------------------------------------------------

function LiveMonitor:ApplySettings()
    if not self.frame then return end
    local settings = WTM.db.profile.liveMonitor

    self.frame:SetWidth(settings.width)
    self.frame:SetScale(settings.scale or 1)
    self.frame.bg:SetColorTexture(T("windowBg", settings.opacity))

    for _, row in pairs(self.rows) do
        row.spark:SetShown(settings.sparklines and not settings.collapsed)
    end

    self:ApplyCollapsed()

    -- Bound the sparklines to the data they display, once.
    if settings.sparklines and not self.ringsBound then
        self.rows.fps.spark:SetRing(WTM.FrameTime.history.fps)
        self.rows.frame.spark:SetRing(WTM.FrameTime.history.frameMs)
        self.rows.latency.spark:SetRing(WTM.Network.history.world)
        self.rows.memory.spark:SetRing(WTM.Memory.history.lua)
        self.rows.events.spark:SetRing(WTM.Events.history)
        self.ringsBound = true
    end
end

--------------------------------------------------------------------------

--- Applies the collapsed state to the frame. Collapsing hides the rows and
--- shrinks the panel to its header; the two numbers that survive move into the
--- header itself, so a collapsed panel is still a readout rather than a stub.
function LiveMonitor:ApplyCollapsed()
    if not self.frame then return end
    local collapsed = WTM.db.profile.liveMonitor.collapsed and true or false

    for _, row in pairs(self.rows) do
        row:SetShown(not collapsed)
    end
    self.header.summary:SetShown(collapsed)
    self.header.collapse:SetText(collapsed and "+" or "-")
    self.header.collapse.tooltip = collapsed
        and "Expand back to the full readout."
        or "Collapse to a single line. The panel stays on screen and keeps recording."

    self.frame:SetHeight(collapsed and 22 or (30 + #ROWS * ROW_HEIGHT))
end

function LiveMonitor:SetCollapsed(collapsed)
    WTM.db.profile.liveMonitor.collapsed = collapsed and true or false
    self:ApplySettings()
    -- Expanding reveals sparklines that were not being drawn, so this refresh
    -- needs a pass of its own rather than whatever the last tick left behind.
    UI.MainWindow:InvalidateGraphs()
    UI.MainWindow:BeginGraphPass()
    self:Refresh()
end

function LiveMonitor:IsCollapsed()
    return WTM.db.profile.liveMonitor.collapsed and true or false
end

--------------------------------------------------------------------------

function LiveMonitor:Refresh()
    local frame = self.frame
    if not frame or not frame:IsShown() then return end

    local ft  = WTM.FrameTime.current
    local net = WTM.Network.current
    local rows = self.rows

    if self:IsCollapsed() then
        -- One line: the frame time that shows the bad frame, and the FPS that
        -- everyone reads first anyway.
        self.header.summary:SetText(("%.1f ms  %s"):format(ft.avgMs, Fmt.FPS(ft.fps)))
        self.header.summary:SetTextColor(Theme:Tone(
            ft.avgMs <= 20 and "ok" or (ft.avgMs <= 40 and "warn" or "crit")))
        return
    end

    rows.fps.value:SetText(Fmt.FPS(ft.fps))
    rows.fps.value:SetTextColor(Theme:Tone(
        ft.fps >= 55 and "ok" or (ft.fps >= 30 and "warn" or "crit")))

    rows.frame.value:SetText(("%.1f ms"):format(ft.avgMs))
    rows.frame.value:SetTextColor(Theme:Tone(
        ft.avgMs <= 20 and "ok" or (ft.avgMs <= 40 and "warn" or "crit")))

    if WTM.Caps:Has("latency") then
        rows.latency.value:SetText(("%d ms"):format(net.latencyWorld))
        rows.latency.value:SetTextColor(T("textPrimary"))
    else
        rows.latency.value:SetText("n/a")
        rows.latency.value:SetTextColor(T("textMuted"))
    end

    if WTM.CPU.available then
        rows.cpu.value:SetText(("%.1f %%"):format(WTM.CPU.current.totalPct))
        rows.cpu.value:SetTextColor(T("textPrimary"))
    else
        rows.cpu.value:SetText("off")
        rows.cpu.value:SetTextColor(T("textMuted"))
    end

    rows.memory.value:SetText(Fmt.Memory(WTM.Memory.current.luaKB))
    rows.memory.value:SetTextColor(T("textPrimary"))

    if WTM.Events:GetMode() ~= "OFF" then
        rows.events.value:SetText(Fmt.Rate(WTM.Events.current.perSecond))
        rows.events.value:SetTextColor(T("textPrimary"))
    else
        rows.events.value:SetText("off")
        rows.events.value:SetTextColor(T("textMuted"))
    end

    -- Sparklines follow the DATA rate, not the refresh rate: redrawing them on
    -- every refresh is the same waste the main window's graphs had. They also
    -- take turns rather than all redrawing in the same frame, out of their own
    -- budget - sharing one with the page's graphs meant whichever refreshed
    -- first took every slot.
    if WTM.db.profile.liveMonitor.sparklines and UI.MainWindow:ShouldRedrawGraphs() then
        for i, spec in ipairs(ROWS) do
            if UI.MainWindow:TakeSparkSlot(i, #ROWS) then
                rows[spec.key].spark:Draw()
            end
        end
    end
end

--------------------------------------------------------------------------

function LiveMonitor:Show()
    self:Build()
    self.frame:Show()
    -- Refresh below runs outside the scheduler tick, so nobody has opened a
    -- graph pass for it. Open one, or the panel appears with empty sparklines
    -- and stays that way until the next tick.
    UI.MainWindow:InvalidateGraphs()
    UI.MainWindow:BeginGraphPass()
    WTM.db.profile.liveMonitor.shown = true
    WTM.Scheduler:SetEnabled("ui", true)
    self:Refresh()
end

function LiveMonitor:Hide()
    if self.frame then self.frame:Hide() end
    WTM.db.profile.liveMonitor.shown = false
    -- The UI task is only needed while something is visible.
    if not UI.MainWindow:IsOpen() then
        WTM.Scheduler:SetEnabled("ui", false)
    end
end

function LiveMonitor:Toggle()
    if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end
end

function LiveMonitor:IsShown()
    return self.frame and self.frame:IsShown() or false
end

--------------------------------------------------------------------------

function LiveMonitor:OnEnable()
    if WTM.db.profile.liveMonitor.shown then
        self:Show()
    end
end
