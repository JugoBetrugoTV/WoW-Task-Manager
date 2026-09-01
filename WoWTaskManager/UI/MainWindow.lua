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
    { key = "fps",     label = "FPS",       colorIndex = 1 },
    { key = "frame",   label = "FRAME",     colorIndex = 2, invert = true },
    { key = "latency", label = "WORLD",     colorIndex = 3, invert = true },
    { key = "memory",  label = "LUA MEM",   colorIndex = 4, invert = true },
    { key = "cpu",     label = "ADDON CPU", colorIndex = 5, invert = true },
    { key = "events",  label = "EVENTS",    colorIndex = 6, invert = true },
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

    -- Close / minimise
    local close = UI.Button(topbar, "X", function() window:Close() end,
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

        cell.spark = UI.Sparkline(cell, spec.colorIndex, spec.invert)
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
    UI.MakeResizable(window, 900, 560, function()
        WTM.db.profile.general.windowWidth  = window:GetWidth()
        WTM.db.profile.general.windowHeight = window:GetHeight()
        if self.currentPage then self:LayoutPage(self.currentPage) end
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
        MainWindow:StopRefresh()
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

    if page.OnShow then pcall(page.OnShow, page) end
    self:RefreshCurrentPage()
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
        WTM.db.profile.sampling.intervals.ui, C.SAMPLE_DEFAULTS.ui.burst, 0.05)
    WTM.Scheduler:SetEnabled("ui", false)
end
