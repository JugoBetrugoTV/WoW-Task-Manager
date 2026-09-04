--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Resources.lua

    The resource-monitor grid: every live signal at once, each with its own
    current / average / peak, a sparkline and a status.

    The compact monitor is the version of this you keep on screen while you
    play. This is the version you open when something is wrong and you want to
    see which signal moved.

    It samples nothing. Every module here already keeps a ring buffer for its
    own graph; this page binds sparklines to those rings and reads the numbers
    the samplers have already produced. The only cost it adds is drawing, and
    that goes through the same redraw budget as everything else.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("resources", {})

--------------------------------------------------------------------------
-- What the grid shows
--------------------------------------------------------------------------
--
-- Each module declares how to read itself. `ring` is bound once at build time
-- and never copied out of; `unavailable` returns a reason string rather than
-- letting the panel show a plausible zero.

local MODULES = {
    {
        key = "fps", title = "FRAME RATE", unit = "fps", colorIndex = 1,
        worstIsLow = true,
        ring = function() return WTM.FrameTime.history.fps end,
        current = function() return WTM.FrameTime.current.fps end,
        average = function() return WTM.FrameTime:GetSessionStats().avgFPS end,
        peak    = function() return WTM.FrameTime:GetSessionStats().minFPS end,
        peakLabel = "Lowest",
        format  = function(v) return Fmt.FPS(v or 0) end,
        tone    = function(v) return v >= 55 and "ok" or (v >= 30 and "warn" or "crit") end,
    },
    {
        key = "frame", title = "FRAME TIME", unit = "ms", colorIndex = 2,
        ring = function() return WTM.FrameTime.history.frameMs end,
        current = function() return WTM.FrameTime.current.avgMs end,
        average = function() return WTM.FrameTime:GetSessionStats().avgMs end,
        peak    = function() return WTM.FrameTime:GetSessionStats().maxMs end,
        format  = function(v) return Fmt.Ms(v or 0) end,
        tone    = function(v) return v <= 20 and "ok" or (v <= 40 and "warn" or "crit") end,
    },
    {
        key = "cpu", title = "ADDON CPU", unit = "%", colorIndex = 5,
        ring = function() return WTM.CPU.history end,
        current = function() return WTM.CPU.current.totalPct end,
        average = function() return WTM.CPU.session.avgPct end,
        peak    = function() return WTM.CPU.session.peakPct end,
        format  = function(v) return ("%.2f %%"):format(v or 0) end,
        tone    = function(v) return v < 5 and "ok" or (v < 15 and "warn" or "crit") end,
        unavailable = function()
            if not WTM.CPU.available then
                return WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
            end
        end,
    },
    {
        key = "memory", title = "LUA HEAP", unit = "", colorIndex = 4,
        ring = function() return WTM.Memory.history.lua end,
        current = function() return WTM.Memory.current.luaKB end,
        average = function() return WTM.Memory.current.luaStartKB end,
        averageLabel = "At login",
        peak    = function() return WTM.Memory.current.luaPeakKB end,
        format  = function(v) return Fmt.Memory(v or 0) end,
        tone    = function() return nil end,
    },
    {
        key = "addonmem", title = "ADDON MEMORY", unit = "", colorIndex = 8,
        current = function() return WTM.Memory.current.addonSumKB end,
        average = function() return WTM.Memory.current.addonStartKB end,
        averageLabel = "At login",
        peak    = function() return WTM.Memory.current.addonPeakKB end,
        format  = function(v) return Fmt.Memory(v or 0) end,
        tone    = function() return nil end,
        unavailable = function()
            if not WTM.Caps:Has("addonMemory") then
                return WTM.Caps:Note("addonMemory") or C.TXT_UNAVAILABLE_CLIENT
            end
        end,
    },
    {
        key = "latency", title = "WORLD LATENCY", unit = "ms", colorIndex = 3,
        ring = function() return WTM.Network.history.world end,
        current = function() return WTM.Network.current.latencyWorld end,
        average = function()
            local s = WTM.Network.session
            return (s.samples or 0) > 0 and (s.sumWorld / s.samples) or 0
        end,
        peak    = function() return WTM.Network.session.peakWorld end,
        format  = function(v) return ("%d ms"):format(math.floor(v or 0)) end,
        tone    = function(v) return v < 100 and "ok" or (v < 250 and "warn" or "crit") end,
        note    = function()
            return ("reading %s old; the client refreshes it about every 30 s")
                :format(Fmt.Duration(WTM.Network.current.ageSeconds or 0))
        end,
        unavailable = function()
            if not WTM.Caps:Has("latency") then
                return WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT
            end
        end,
    },
    {
        key = "home", title = "HOME LATENCY", unit = "ms", colorIndex = 7,
        ring = function() return WTM.Network.history.home end,
        current = function() return WTM.Network.current.latencyHome end,
        average = function()
            local s = WTM.Network.session
            return (s.samples or 0) > 0 and (s.sumHome / s.samples) or 0
        end,
        peak    = function() return WTM.Network.session.peakHome end,
        format  = function(v) return ("%d ms"):format(math.floor(v or 0)) end,
        tone    = function(v) return v < 100 and "ok" or (v < 250 and "warn" or "crit") end,
        unavailable = function()
            if not WTM.Caps:Has("latency") then
                return WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT
            end
        end,
    },
    {
        key = "events", title = "EVENTS / SEC", unit = "/s", colorIndex = 6,
        ring = function() return WTM.Events.history end,
        current = function() return WTM.Events.current.perSecond end,
        average = function() return WTM.Events.current.avgPerSecond end,
        peak    = function() return WTM.Events.current.peakPerSecond end,
        format  = function(v) return Fmt.Rate(v or 0) end,
        tone    = function() return nil end,
        unavailable = function()
            if WTM.Events:GetMode() == "OFF" then
                return "Event monitoring is switched off in Settings."
            end
            if not WTM.Events.available then
                return WTM.Events.reason or C.TXT_UNAVAILABLE_CLIENT
            end
        end,
    },
    {
        key = "overhead", title = "THIS ADDON", unit = "ms/s", colorIndex = 7,
        current = function() return WTM.Overhead.current.totalMsPerSec end,
        average = function() return WTM.Overhead.current.samplingMsPerSec end,
        averageLabel = "Sampling",
        peak    = function() return WTM.Overhead.current.uiMsPerSec end,
        peakLabel = "UI",
        format  = function(v) return ("%.3f"):format(v or 0) end,
        tone    = function()
            return WTM.Overhead.current.verdict == "ok" and "ok" or "warn"
        end,
        note    = function()
            return ("%.2f%% of a frame at the current rate")
                :format(WTM.Overhead:GetFrameBudgetPercent())
        end,
    },
}

Page.MODULES = MODULES

--------------------------------------------------------------------------

local function BuildModuleCard(parent, spec)
    local card = UI.Card(parent, spec.title, {})

    card.value = UI.Text(card.content, "metric", "textPrimary", "LEFT")
    card.value:SetPoint("TOPLEFT", 0, 2)
    card.value:SetText("-")

    card.unit = UI.Text(card.content, "small", "textMuted", "LEFT")
    card.unit:SetPoint("BOTTOMLEFT", card.value, "BOTTOMRIGHT", 4, 3)
    card.unit:SetText(spec.unit or "")

    card.status = UI.Text(card.content, "tiny", "textMuted", "RIGHT")
    card.status:SetPoint("TOPRIGHT", 0, 0)
    card.status:SetPoint("LEFT", card.value, "RIGHT", 40, 0)

    card.avgRow  = UI.StatRow(card.content, spec.averageLabel or "Average")
    card.avgRow:SetHeight(14)
    card.avgRow:SetPoint("TOPLEFT", 0, -30)
    card.avgRow:SetPoint("TOPRIGHT", 0, -30)

    card.peakRow = UI.StatRow(card.content, spec.peakLabel or "Peak")
    card.peakRow:SetHeight(14)
    card.peakRow:SetPoint("TOPLEFT", 0, -44)
    card.peakRow:SetPoint("TOPRIGHT", 0, -44)

    card.note = UI.Text(card.content, "tiny", "textMuted", "LEFT")
    card.note:SetPoint("TOPLEFT", 0, -60)
    card.note:SetPoint("RIGHT", card.content, "RIGHT", 0, 0)
    card.note:SetHeight(22)
    UI.Wrap(card.note, 2)

    card.spark = UI.Sparkline(card, spec.colorIndex or 1, spec.worstIsLow)
    card.spark:SetPoint("BOTTOMLEFT", 1, 1)
    card.spark:SetPoint("BOTTOMRIGHT", -1, 1)
    card.spark:SetHeight(26)

    -- Why a value is missing, in the space the value would have occupied.
    card.unavailable = UI.Text(card.content, "tiny", "textMuted", "LEFT")
    card.unavailable:SetPoint("TOPLEFT", 0, 0)
    card.unavailable:SetPoint("RIGHT", card.content, "RIGHT", 0, 0)
    card.unavailable:SetHeight(48)
    UI.Wrap(card.unavailable, 3)
    card.unavailable:SetJustifyV("TOP")
    card.unavailable:Hide()

    card.spec = spec
    return card
end

function Page:Build(frame)
    local scroll, canvas = UI.ScrollCanvas(frame, { padding = M.padding })
    self.scroll, self.canvas = scroll, canvas

    -- Four across on a wide window, two on a narrow one, and the grid decides
    -- which without this page knowing the width.
    local grid = UI.Grid(canvas, { minColumnWidth = 250, maxColumns = 4 })
    self.grid = grid

    self.cards = {}
    for _, spec in ipairs(MODULES) do
        local card = BuildModuleCard(canvas, spec)
        grid:Add(card, { span = 1, height = 148, key = spec.key })
        self.cards[spec.key] = card
    end

    self.footer = UI.Text(canvas, "tiny", "textMuted", "LEFT")
    self.footer:SetHeight(28)
    UI.Wrap(self.footer, 2)
    grid:Add(self.footer, { span = 4, height = 28, key = "footer" })

    self:OnLayout()
end

--- `force` is only passed when the set of visible cells has changed. A
--- relayout resizes every cell, and a resize is not free - doing it on every
--- refresh made the grid itself the most expensive thing on the page.
function Page:OnLayout(force)
    if not self.grid then return end
    self.scroll:SyncWidth()
    self.canvas:SetHeight(self.grid:Layout(force))
end

function Page:OnShow()
    -- Bind the rings once, when the page is first shown: the ring buffers do
    -- not exist until the modules have initialised.
    if not self.ringsBound then
        for _, spec in ipairs(MODULES) do
            local card = self.cards[spec.key]
            if spec.ring then card.spark:SetRing(spec.ring()) end
            card.spark:SetShown(spec.ring ~= nil)
        end
        self.ringsBound = true
    end
    self:Refresh()
end

function Page:Refresh()
    if not self.cards then return end

    local redraw = UI.MainWindow:ShouldRedrawGraphs()
    local total = #MODULES

    for index, spec in ipairs(MODULES) do
        local card = self.cards[spec.key]
        local reason = spec.unavailable and spec.unavailable() or nil

        if reason then
            card.unavailable:Show()
            card.unavailable:SetText(reason)
            card.value:Hide() ; card.unit:Hide() ; card.status:Hide()
            card.avgRow:Hide() ; card.peakRow:Hide() ; card.note:Hide()
            card.spark:Hide()
        else
            card.unavailable:Hide()
            card.value:Show() ; card.unit:Show() ; card.status:Show()
            card.avgRow:Show() ; card.peakRow:Show() ; card.note:Show()
            card.spark:SetShown(spec.ring ~= nil)

            local current = spec.current() or 0
            local tone = spec.tone and spec.tone(current) or nil
            card.value:SetText(UI.FitText(card.value, spec.format(current)))
            -- Explicit if/else, not `tone and Theme:Tone(tone) or T(...)`:
            -- in Lua that truncates the multi-return to a single value and
            -- SetTextColor receives one number instead of r, g, b.
            if tone then
                card.value:SetTextColor(Theme:Tone(tone))
            else
                card.value:SetTextColor(T("textPrimary"))
            end

            card.avgRow:Set(spec.format(spec.average() or 0))
            card.peakRow:Set(spec.format(spec.peak() or 0))

            card.status:SetText(UI.FitText(card.status,
                tone == "crit" and "critical"
                or (tone == "warn" and "elevated"
                or (tone == "ok" and "normal" or ""))))
            if tone then
                card.status:SetTextColor(Theme:Tone(tone))
            else
                card.status:SetTextColor(T("textMuted"))
            end

            card.note:SetText(spec.note and spec.note() or "")

            if redraw and card.spark:IsShown()
                and UI.MainWindow:TakeGraphSlot(index, total) then
                card.spark:Draw()
            end
        end
    end

    self.footer:SetText(("Sampled by the modules that own each signal - this page adds no sampling of its own. Sparklines cover the last %d seconds of retained history.")
        :format(math.floor(WTM.FrameTime.history.fps and WTM.FrameTime.history.fps.capacity or 0)))
end
