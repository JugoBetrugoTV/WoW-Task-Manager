--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/MainWindow.lua

    The shell: topbar with the live readout, sidebar navigation, content area.

    Pages register themselves into WTM.UI.Pages and are created lazily the
    first time they are opened - a page that has never been looked at costs
    nothing.  Only the visible page is refreshed, and refreshing stops entirely
    while the window is closed.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

UI.Pages = UI.Pages or {}
UI.pageOrder = UI.pageOrder or {}

local MainWindow = WTM:NewModule("MainWindow")
UI.MainWindow = MainWindow

--------------------------------------------------------------------------
-- Page registration
--------------------------------------------------------------------------

function UI.RegisterPage(key, definition)
    definition.key = key
    UI.Pages[key] = definition
    UI.pageOrder[#UI.pageOrder + 1] = key
    return definition
end

--------------------------------------------------------------------------
-- Topbar: the live resource monitor
--------------------------------------------------------------------------

local TOPBAR_METRICS = {
    -- worstIsLow marks the series whose BAD value is the low one.  Only FPS
    -- qualifies; for everything else the spike is the high value, so the
    -- sparkline must keep the maximum of each column or it erases them.
    { key = "fps",     label = "FPS",       colorIndex = 1, worstIsLow = true },
    { key = "frame",   label = "FRAME",     colorIndex = 2 },
    { key = "latency", label = "WORLD",     colorIndex = 3 },
    { key = "memory",  label = "LUA MEM",   colorIndex = 4 },
    { key = "cpu",     label = "ADDON CPU", colorIndex = 5 },
    { key = "events",  label = "EVENTS",    colorIndex = 6 },
}

local function BuildTopbar(window)
    local topbar = CreateFrame("Frame", nil, window)
    topbar:SetHeight(M.topbarHeight)
    topbar:SetPoint("TOPLEFT")
    topbar:SetPoint("TOPRIGHT")
    UI.Fill(topbar, "topbarBg")
    UI.Border(topbar, "B", "borderSubtle")

    -- Brand mark: a small accent square instead of an icon file, so the addon
    -- ships without any artwork at all.
    local mark = topbar:CreateTexture(nil, "ARTWORK")
    mark:SetSize(10, 10)
    mark:SetPoint("LEFT", 16, 1)
    mark:SetColorTexture(T("accent"))

    local title = UI.Text(topbar, "title", "textPrimary")
    title:SetPoint("LEFT", mark, "RIGHT", 10, 0)
    title:SetText("WoW Task Manager")

    local clientLabel = UI.Text(topbar, "tiny", "textMuted")
    clientLabel:SetPoint("LEFT", title, "RIGHT", 10, -1)
    clientLabel:SetText(WTM.Compat.flavorName .. " " .. WTM.Compat.version)

    -- Close.  MainWindow owns Close(), not the frame - calling window:Close()
    -- here meant the titlebar X threw instead of closing the window.
    local close = UI.Button(topbar, "X", function() MainWindow:Close() end,
        { width = 26, height = 22, style = "small" })
    close:SetPoint("RIGHT", -10, 0)

    local reload = UI.Button(topbar, "Reload UI", function()
        WTM.Processes:ReloadUI()
    end, { height = 22, style = "small" })
    reload:SetPoint("RIGHT", close, "LEFT", -6, 0)
    reload.tooltip = "Reloads the interface. Queued until combat ends if you are fighting."

    -- Live metric strip
    local strip = CreateFrame("Frame", nil, topbar)
    strip:SetPoint("LEFT", clientLabel, "RIGHT", 24, 0)
    strip:SetPoint("RIGHT", reload, "LEFT", -16, 0)
    strip:SetPoint("TOP")
    strip:SetPoint("BOTTOM")

    window.topMetrics = {}
    local previous
    for i, spec in ipairs(TOPBAR_METRICS) do
        local cell = CreateFrame("Frame", nil, strip)
        cell:SetWidth(96)
        cell:SetPoint("TOP", 0, -8)
        cell:SetPoint("BOTTOM", 0, 6)
        if previous then
            cell:SetPoint("LEFT", previous, "RIGHT", 12, 0)
        else
            cell:SetPoint("LEFT")
        end
        previous = cell

        cell.label = UI.Text(cell, "tiny", "textMuted")
        cell.label:SetPoint("TOPLEFT")
        cell.label:SetText(spec.label)

        cell.value = UI.Text(cell, "numeric", "textPrimary")
        cell.value:SetPoint("TOPLEFT", cell.label, "BOTTOMLEFT", 0, -1)

        cell.spark = UI.Sparkline(cell, spec.colorIndex, spec.worstIsLow)
        cell.spark:SetPoint("BOTTOMLEFT")
        cell.spark:SetPoint("BOTTOMRIGHT")
        cell.spark:SetHeight(10)

        cell.spec = spec
        window.topMetrics[spec.key] = cell
    end

    window.topbar = topbar
    return topbar
end

local function RefreshTopbar(window)
    local metrics = window.topMetrics
    if not metrics then return end

    local ft = WTM.FrameTime.current

    local fps = metrics.fps
    fps.value:SetText(Fmt.FPS(ft.fps))
    fps.value:SetTextColor(Theme:Tone(ft.fps >= 55 and "ok" or (ft.fps >= 30 and "warn" or "crit")))

    metrics.frame.value:SetText(("%.1f ms"):format(ft.avgMs))
    metrics.latency.value:SetText(("%d ms"):format(WTM.Network.current.latencyWorld))
    metrics.memory.value:SetText(Fmt.Memory(WTM.Memory.current.luaKB))

    if WTM.CPU.available then
        metrics.cpu.value:SetText(("%.1f %%"):format(WTM.CPU.current.totalPct))
        metrics.cpu.value:SetTextColor(T("textPrimary"))
    else
        metrics.cpu.value:SetText("n/a")
        metrics.cpu.value:SetTextColor(T("textMuted"))
    end

    metrics.events.value:SetText(Fmt.Rate(WTM.Events.current.perSecond))

    -- Sparklines are attached once, then just redrawn.
    if not window.sparksBound then
        metrics.fps.spark:SetRing(WTM.FrameTime.history.fps)
        metrics.frame.spark:SetRing(WTM.FrameTime.history.frameMs)
        metrics.latency.spark:SetRing(WTM.Network.history.world)
        metrics.memory.spark:SetRing(WTM.Memory.history.lua)
        metrics.events.spark:SetRing(WTM.Events.history)
        window.sparksBound = true
    end
    for _, cell in pairs(metrics) do
        cell.spark:Draw()
    end
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

function MainWindow:Build()
    if self.frame then return self.frame end

    local profile = WTM.db.profile.general

    local window = CreateFrame("Frame", "WTMMainWindow", UIParent)
    window:SetSize(profile.windowWidth, profile.windowHeight)
    window:SetPoint("CENTER")
    window:SetFrameStrata("HIGH")
    window:SetToplevel(true)
    window:Hide()

    UI.Fill(window, "windowBg")
    UI.Border(window, "TLBR", "borderStrong")

    -- A soft drop shadow: four thin edge textures fading outward.  Cheaper and
    -- more controllable than a nine-slice frame, and it is the one touch that
    -- makes the window sit ON the game rather than in it.
    for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local shadow = window:CreateTexture(nil, "BACKGROUND", nil, -1)
        local horizontal = (edge == "TOP" or edge == "BOTTOM")
        if horizontal then
            shadow:SetHeight(8)
            shadow:SetPoint(edge == "TOP" and "BOTTOMLEFT" or "TOPLEFT", window,
                edge == "TOP" and "TOPLEFT" or "BOTTOMLEFT", 0, 0)
            shadow:SetPoint(edge == "TOP" and "BOTTOMRIGHT" or "TOPRIGHT", window,
                edge == "TOP" and "TOPRIGHT" or "BOTTOMRIGHT", 0, 0)
            Theme:SetGradient(shadow, "VERTICAL",
                0, 0, 0, edge == "TOP" and 0 or 0.45,
                0, 0, 0, edge == "TOP" and 0.45 or 0)
        else
            shadow:SetWidth(8)
            shadow:SetPoint(edge == "LEFT" and "TOPRIGHT" or "TOPLEFT", window,
                edge == "LEFT" and "TOPLEFT" or "TOPRIGHT", 0, 0)
            shadow:SetPoint(edge == "LEFT" and "BOTTOMRIGHT" or "BOTTOMLEFT", window,
                edge == "LEFT" and "BOTTOMLEFT" or "BOTTOMRIGHT", 0, 0)
            Theme:SetGradient(shadow, "HORIZONTAL",
                0, 0, 0, edge == "LEFT" and 0 or 0.45,
                0, 0, 0, edge == "LEFT" and 0.45 or 0)
        end
    end

    local topbar = BuildTopbar(window)

    UI.MakeMovable(window, topbar, function()
        -- Position is intentionally not persisted per profile: people move a
        -- diagnostic window constantly and restoring yesterday's position is
        -- more annoying than helpful.
    end)
    -- Layout has to follow the drag, not just the release: laying out only on
    -- mouse-up left every panel at its old size while resizing, which is what
    -- made text run into itself mid-drag.
    UI.MakeResizable(window, 940, 600, function()
        WTM.db.profile.general.windowWidth  = window:GetWidth()
        WTM.db.profile.general.windowHeight = window:GetHeight()
        if self.currentPage then self:LayoutPage(self.currentPage) end
        self:InvalidateGraphs()
    end, function()
        -- Live, while dragging.
        if self.currentPage then self:LayoutPage(self.currentPage) end
        self:InvalidateGraphs()
    end)

    window:SetScript("OnSizeChanged", function()
        if MainWindow.currentPage then MainWindow:LayoutPage(MainWindow.currentPage) end
        MainWindow:InvalidateGraphs()
    end)

    -- Sidebar
    window.sidebar = UI.Sidebar:Build(window)

    -- Content host
    local content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", window.sidebar, "TOPRIGHT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", -1, 1)
    window.content = content

    window:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then MainWindow:Close() end
    end)
    window:EnableKeyboard(false)

    -- Escape-to-close, the way every other WoW window behaves.
    if UISpecialFrames then
        tinsert(UISpecialFrames, "WTMMainWindow")
    end

    window:SetScript("OnShow", function()
        MainWindow:StartRefresh()
    end)
    window:SetScript("OnHide", function()
        -- The live monitor also drives the UI task, so only stop it when
        -- nothing at all is on screen.
        if not (UI.LiveMonitor and UI.LiveMonitor:IsShown()) then
            MainWindow:StopRefresh()
        end
        WTM.db.profile.general.lastPage = MainWindow.currentPage
    end)

    self.frame = window
    return window
end

--------------------------------------------------------------------------
-- Page switching
--------------------------------------------------------------------------

function MainWindow:LayoutPage(key)
    local page = UI.Pages[key]
    if page and page.frame and page.OnLayout then
        pcall(page.OnLayout, page)
    end
end

function MainWindow:ShowPage(key)
    if not UI.Pages[key] then key = "dashboard" end

    if self.currentPage and self.currentPage ~= key then
        local previous = UI.Pages[self.currentPage]
        if previous and previous.frame then
            previous.frame:Hide()
            if previous.OnHide then pcall(previous.OnHide, previous) end
        end
    end

    local page = UI.Pages[key]
    if not page.frame then
        -- Lazily built: a page nobody opens never costs anything.
        page.frame = CreateFrame("Frame", nil, self.frame.content)
        page.frame:SetAllPoints(self.frame.content)
        local ok, err = pcall(page.Build, page, page.frame)
        if not ok then
            geterrorhandler()(("WTM: page '%s' failed to build: %s"):format(key, tostring(err)))
            page.buildFailed = true
        end
    end

    page.frame:Show()
    self.currentPage = key
    UI.Sidebar:SetActive(key)
    -- A page that was just shown has stale graphs by definition.
    self:InvalidateGraphs()

    if page.OnShow then pcall(page.OnShow, page) end
    self:RefreshCurrentPage()
end

--- True when graphs on the visible page should actually be redrawn.
---
--- Redrawing a graph repositions hundreds of pooled textures, and it is by far
--- the most expensive thing this addon does - a live client measured 33 ms/s of
--- UI cost from redrawing six graphs twice a second, which is an entire 60 FPS
--- frame budget per redraw.
---
--- Buckets are one second apart, so redrawing faster than that cannot show new
--- data. Pages ask this before drawing; text and numbers still update on every
--- refresh because they are nearly free.
-- How many graphs may be redrawn in one pass.
--
-- The gate alone was not enough: six graphs still redrew together, and the
-- benchmark measured that single pass at ~15 ms - one whole frame. Spreading
-- them round-robin means at most two redraw per pass, so the work is amortised
-- over three passes instead of landing in one frame. The data is on a one
-- second cadence, so nothing visible is lost.
local GRAPHS_PER_PASS = 2

function MainWindow:ShouldRedrawGraphs()
    local now = GetTime()
    local minInterval = WTM.db.profile.ui.graphUpdateRate or 1.0
    if self.lastGraphDraw and (now - self.lastGraphDraw) < minInterval then
        return false
    end
    -- Nothing new to draw and the window is not being resized.
    if self.lastGraphRevision == WTM.Recorder.revision and not self.graphsDirty then
        -- Still redraw occasionally so the time axis keeps scrolling.
        if self.lastGraphDraw and (now - self.lastGraphDraw) < math.max(2, minInterval * 3) then
            return false
        end
    end
    self.lastGraphDraw = now
    self.lastGraphRevision = WTM.Recorder.revision
    self.graphsDirty = false

    -- Open a new round-robin pass.
    -- A layout change invalidates every graph at once, so that one pass draws
    -- all of them; afterwards the round-robin resumes.
    self.fullPass = self.forceFullGraphPass or false
    self.forceFullGraphPass = false

    self.graphSlotsLeft = GRAPHS_PER_PASS
    self.graphCursor = self.graphCursor or 0
    return true
end

--- Asks for permission to redraw ONE graph in the current pass.
---
--- Pages call this per graph instead of drawing all of them: `index` keeps the
--- rotation stable so every graph gets its turn rather than the first two
--- always winning.
function MainWindow:TakeGraphSlot(index, total)
    if self.fullPass then return true end
    if not self.graphSlotsLeft or self.graphSlotsLeft <= 0 then return false end
    if not total or total <= GRAPHS_PER_PASS then
        self.graphSlotsLeft = self.graphSlotsLeft - 1
        return true
    end

    -- Whose turn is it this pass?
    local offset = (self.graphCursor or 0)
    local turn = ((index - 1 - offset) % total) < GRAPHS_PER_PASS
    if turn then
        self.graphSlotsLeft = self.graphSlotsLeft - 1
        if self.graphSlotsLeft <= 0 then
            self.graphCursor = (offset + GRAPHS_PER_PASS) % total
        end
        return true
    end
    return false
end



--- Forces the next refresh to redraw graphs, e.g. after a resize or a page change.
function MainWindow:InvalidateGraphs()
    self.graphsDirty = true
    self.lastGraphDraw = nil
    -- A layout change invalidates every graph at once, so the round-robin is
    -- suspended for one pass rather than leaving four of six stale.
    self.forceFullGraphPass = true
end

function MainWindow:RefreshCurrentPage()
    local page = UI.Pages[self.currentPage]
    if page and page.frame and page.frame:IsVisible() and page.Refresh and not page.buildFailed then
        local ok, err = pcall(page.Refresh, page)
        if not ok then
            page.refreshErrors = (page.refreshErrors or 0) + 1
            if page.refreshErrors <= 3 then geterrorhandler()(err) end
        end
    end
end

--------------------------------------------------------------------------
-- Refresh loop
--------------------------------------------------------------------------
-- Registered with the scheduler like everything else, and only enabled while
-- the window is actually shown.

function MainWindow:StartRefresh()
    WTM.Scheduler:SetEnabled("ui", true)
    self:Refresh()
end

function MainWindow:StopRefresh()
    WTM.Scheduler:SetEnabled("ui", false)
end

function MainWindow:Refresh()
    -- The compact monitor updates on the same task, and may be visible while
    -- the main window is closed.
    if UI.LiveMonitor then UI.LiveMonitor:Refresh() end

    if not self.frame or not self.frame:IsShown() then return end
    RefreshTopbar(self.frame)
    UI.Sidebar:Refresh()
    self:RefreshCurrentPage()
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

function MainWindow:Open(page)
    self:Build()
    self.frame:Show()
    self:ShowPage(page or WTM.db.profile.general.lastPage or "dashboard")
end

function MainWindow:Close()
    if self.frame then self.frame:Hide() end
end

function MainWindow:Toggle(page)
    if self.frame and self.frame:IsShown() then
        self:Close()
    else
        self:Open(page)
    end
end

function MainWindow:IsOpen()
    return self.frame and self.frame:IsShown()
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function MainWindow:OnEnable()
    WTM.Scheduler:Register("ui", function() MainWindow:Refresh() end,
        WTM.db.profile.sampling.intervals.ui, C.SAMPLE_DEFAULTS.ui.burst, 0.05, "ui")
    WTM.Scheduler:SetEnabled("ui", false)
end
