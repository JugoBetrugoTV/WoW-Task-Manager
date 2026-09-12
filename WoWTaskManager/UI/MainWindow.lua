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
    -- A switched-off duplicate must not put a second window on the screen; a
    -- second window over the first is the whole thing this guard exists for.
    if WTM.duplicateOf then return nil end

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
        -- On release, relayout EVERY built page, not just the visible one.
        -- The others keep the geometry they were built with until something
        -- lays them out again, and "something" used to be nothing at all.
        self:LayoutAllPages()
        self:InvalidateGraphs()
    end, function()
        -- Live, while dragging. Layout has to follow the drag or panels sit at
        -- their old size and text runs into itself - but the graphs only get
        -- marked stale, NOT forced into a full pass. Forcing one on every frame
        -- of a drag is how resizing became the addon's own worst stutter.
        if self.currentPage then self:LayoutPage(self.currentPage) end
        self:MarkGraphsDirty()
    end)

    window:SetScript("OnSizeChanged", function()
        if MainWindow.currentPage then MainWindow:LayoutPage(MainWindow.currentPage) end
        MainWindow:MarkGraphsDirty()
    end)

    -- Sidebar
    window.sidebar = UI.Sidebar:Build(window)

    -- Content host
    local content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", window.sidebar, "TOPRIGHT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", -1, 1)
    -- A parent in WoW does NOT clip its children unless it is told to. Without
    -- this, a page still holding the layout it was given at 1900 px paints
    -- across a 1150 px window and out over the game - which is exactly what a
    -- real client showed: one page's observations drawn on top of another
    -- page's table, and the filter buttons running off the window's edge.
    --
    -- Correct layout is handled below; this is the guarantee that a layout
    -- which is momentarily wrong stays inside the window while it is wrong.
    content:SetClipsChildren(true)
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

--- Relayouts every page that has been built.
---
--- Only the visible one is laid out while a drag is in progress - doing all of
--- them on every frame of a resize is how resizing became this addon's own
--- worst stutter - so the rest are brought up to date once, on release.
function MainWindow:LayoutAllPages()
    for key, page in pairs(UI.Pages) do
        if page.frame and page.OnLayout then
            pcall(page.OnLayout, page, true)
        end
    end
end

function MainWindow:LayoutPage(key)
    local page = UI.Pages[key]
    if page and page.frame and page.OnLayout then
        pcall(page.OnLayout, page)
    end
end

--- Shows one page and hides every other one.
---
--- This used to hide only the page it BELIEVED was current, which made "at
--- most one page is visible" a property of one bookkeeping variable rather
--- than of the frames themselves. That is a bad bet in this API: a frame in
--- WoW is visible the moment it is created, so any path that builds a page
--- outside this function - or that leaves currentPage stale - leaves the old
--- page drawn underneath the new one.
---
--- Hiding all of them costs a loop over about twenty frames that are already
--- hidden, which is nothing, and it makes the invariant true by construction.
function MainWindow:ShowPage(key)
    if not UI.Pages[key] then key = "dashboard" end

    -- A menu, a copy box or a detail overlay belongs to the page it was opened
    -- from. They hang off UIParent so that they can escape the window's edge,
    -- which also means nothing here hides them implicitly.
    UI.DismissTransient()

    for otherKey, other in pairs(UI.Pages) do
        if otherKey ~= key and other.frame and other.frame:IsShown() then
            other.frame:Hide()
            if other.OnHide then pcall(other.OnHide, other) end
        end
    end

    local page = UI.Pages[key]
    if not page.frame then
        -- Lazily built: a page nobody opens never costs anything.
        --
        -- Built VISIBLE, deliberately. Every other page was hidden above, so
        -- there is nothing for a half-built one to appear over, and a
        -- responsive grid measures the width it is given while it builds - a
        -- hidden frame is the one case where that measurement cannot be
        -- trusted. Hiding during the build bought nothing and risked a page
        -- laid out against a width of zero.
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

    -- Lay out AFTER the frame is on screen. A grid built or refreshed while
    -- its page was hidden may have measured a width that was not yet real, and
    -- the forced pass is the only one that resizes every cell rather than
    -- reusing the sizes from last time.
    if page.OnLayout then pcall(page.OnLayout, page, true) end
    -- A page that was just shown has stale graphs by definition, and the
    -- refresh below runs outside the scheduler tick, so the pass has to be
    -- opened here or the page would appear blank until the next tick.
    self:InvalidateGraphs()
    self:BeginGraphPass()

    if page.OnShow then pcall(page.OnShow, page) end
    self:RefreshCurrentPage()
end

--------------------------------------------------------------------------
-- Graph redraw pacing
--------------------------------------------------------------------------
--
-- Redrawing a graph repositions hundreds of pooled textures, and it is by far
-- the most expensive thing this addon does. A live client measured 33 ms/s of
-- UI cost from redrawing six graphs twice a second, and a single pass at
-- ~15 ms - an entire 60 FPS frame budget landing in one frame.
--
-- Two mechanisms, and both are needed:
--
--   1. A GATE. Buckets are one second apart, so redrawing faster than the
--      configured rate cannot show new data.
--   2. A ROUND-ROBIN BUDGET. Even at the right rate, six graphs redrawing
--      together is one 15 ms frame. At most GRAPHS_PER_PASS redraw per pass,
--      so the work is amortised over three passes. Nothing visible is lost:
--      the data underneath is on a one second cadence either way.
--
-- The decision is made ONCE per refresh tick, in BeginGraphPass, and everything
-- else only reads it. It used to be made inside ShouldRedrawGraphs, which every
-- caller called for itself - and because MainWindow:Refresh refreshes the live
-- monitor first, the live monitor's call consumed the tick and the page's own
-- graphs then got `false` every single time. With the live monitor open, the
-- main window's graphs only ever redrew on a forced full pass.
local GRAPHS_PER_PASS = 2

--- One round-robin budget: how many draws are left in this pass, and where the
--- rotation stands. The page's graphs and the live monitor's sparklines get one
--- each, so a visible live monitor cannot starve the page of its turn.
local function NewBudget()
    return { left = 0, cursor = 0, full = false }
end

local function OpenBudget(budget, full)
    budget.left = GRAPHS_PER_PASS
    budget.full = full and true or false
end

--- Asks a budget for permission to redraw ONE item this pass.
--- `index` keeps the rotation stable, so every item gets its turn instead of
--- the first two always winning.
--- What the redraw budget actually did, so the benchmark reports measurements
--- rather than intentions. Every field here is counted, none is derived from a
--- setting.
MainWindow.redrawStats = {
    draws     = 0,   -- redraws that happened
    deferred  = 0,   -- redraws the budget refused this pass
    totalMs   = 0,
    maxMs     = 0,
    passes    = 0,
}

function MainWindow:ResetRedrawStats()
    local r = self.redrawStats
    r.draws, r.deferred, r.totalMs, r.maxMs, r.passes = 0, 0, 0, 0, 0
end

local function TakeSlot(budget, index, total)
    if budget.full then return true end
    if budget.left <= 0 then
        MainWindow.redrawStats.deferred = MainWindow.redrawStats.deferred + 1
        return false
    end
    if not total or total <= GRAPHS_PER_PASS then
        budget.left = budget.left - 1
        return true
    end

    local offset = budget.cursor
    if ((index - 1 - offset) % total) < GRAPHS_PER_PASS then
        budget.left = budget.left - 1
        if budget.left <= 0 then
            budget.cursor = (offset + GRAPHS_PER_PASS) % total
        end
        return true
    end
    MainWindow.redrawStats.deferred = MainWindow.redrawStats.deferred + 1
    return false
end

--- Decides, once per refresh tick, whether this tick redraws graphs at all -
--- and if so, opens a fresh round-robin budget for the page and another for the
--- live monitor.
---
--- Call this exactly once at the top of a refresh, before anything that draws.
function MainWindow:BeginGraphPass()
    self.redrawStats.passes = self.redrawStats.passes + 1
    self.graphBudget = self.graphBudget or NewBudget()
    self.sparkBudget = self.sparkBudget or NewBudget()

    local now = GetTime()
    local minInterval = WTM.db.profile.ui.graphUpdateRate or 1.0

    if self.lastGraphDraw and (now - self.lastGraphDraw) < minInterval then
        self.graphPassOpen = false
        return false
    end
    -- Nothing new to draw and no layout change pending.
    if self.lastGraphRevision == WTM.Recorder.revision and not self.graphsDirty then
        -- Still redraw occasionally so the time axis keeps scrolling.
        if self.lastGraphDraw and (now - self.lastGraphDraw) < math.max(2, minInterval * 3) then
            self.graphPassOpen = false
            return false
        end
    end

    self.lastGraphDraw = now
    self.lastGraphRevision = WTM.Recorder.revision
    self.graphsDirty = false

    -- A full pass draws everything in one tick. It is reserved for the moments
    -- where stale geometry would be visibly wrong - a page change, or the end
    -- of a resize - and never used for the frame-by-frame updates of a drag,
    -- which is what turned resizing into a stutter generator.
    local full = self.forceFullGraphPass or false
    self.forceFullGraphPass = false

    OpenBudget(self.graphBudget, full)
    OpenBudget(self.sparkBudget, full)
    self.graphPassOpen = true
    return true
end

--- True when graphs should be redrawn during this refresh tick.
--- A pure read of the decision BeginGraphPass already made; calling it twice
--- returns the same answer and consumes nothing.
function MainWindow:ShouldRedrawGraphs()
    return self.graphPassOpen == true
end

--- Permission to redraw one graph on the visible page.
function MainWindow:TakeGraphSlot(index, total)
    if not self.graphPassOpen then return false end
    return TakeSlot(self.graphBudget, index, total)
end

--- Permission to redraw one sparkline in the live monitor. Separate budget on
--- purpose: see the comment above BeginGraphPass.
function MainWindow:TakeSparkSlot(index, total)
    if not self.graphPassOpen then return false end
    return TakeSlot(self.sparkBudget, index, total)
end

--- Marks the graph data as stale so the next tick redraws, without demanding
--- that everything redraw at once. This is what a resize drag uses.
function MainWindow:MarkGraphsDirty()
    self.graphsDirty = true
    self.lastGraphDraw = nil
end

--- Marks graphs stale AND demands one full pass: every graph redraws on the
--- next tick. For page changes and the end of a resize, where leaving four of
--- six graphs at the old geometry would look broken.
function MainWindow:InvalidateGraphs()
    self:MarkGraphsDirty()
    self.forceFullGraphPass = true
end

--- Hides any page that is showing and should not be.
---
--- ShowPage already hides every other page, so in principle this can never
--- find anything. In practice a real client showed one page's cards drawn over
--- three different pages in a row, and neither reading the code nor the
--- headless harness could produce it - so the invariant is enforced on the UI
--- tick as well as at the moment of switching.
---
--- The cost is a loop over about twenty frames that are already hidden, which
--- is nothing next to a single graph redraw. What it finds is COUNTED and
--- named rather than quietly patched: a bug that repairs itself in silence is
--- a bug that never gets fixed.
function MainWindow:EnforceSinglePage()
    local current = self.currentPage
    if not current then return 0 end

    local repaired = 0
    for key, page in pairs(UI.Pages) do
        if key ~= current and page.frame and page.frame:IsShown() then
            page.frame:Hide()
            repaired = repaired + 1
            self.strayPages = self.strayPages or {}
            self.strayPages[key] = (self.strayPages[key] or 0) + 1
        end
    end

    if repaired > 0 then
        self.pageRepairs = (self.pageRepairs or 0) + repaired
    end
    return repaired
end

--- The pages that have been caught showing when they should not have been,
--- newest count first, for the diagnostics finding.
function MainWindow:DescribeStrayPages()
    if not self.strayPages then return nil end
    local names = {}
    for key, count in pairs(self.strayPages) do
        names[#names + 1] = ("%s (%d)"):format(key, count)
    end
    if #names == 0 then return nil end
    table.sort(names)
    return table.concat(names, ", ")
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
    -- One decision per tick, taken before anything draws, so the live monitor
    -- and the visible page see the same answer instead of racing for it.
    self:BeginGraphPass()

    -- The compact monitor updates on the same task, and may be visible while
    -- the main window is closed.
    if UI.LiveMonitor then UI.LiveMonitor:Refresh() end

    if not self.frame or not self.frame:IsShown() then return end
    RefreshTopbar(self.frame)
    UI.Sidebar:Refresh()
    self:EnforceSinglePage()
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
    -- Same reason as in ShowPage, and worse here: a context menu left over
    -- after the window closes is drawn over the game itself.
    UI.DismissTransient()
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
