--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Network.lua

    Latency and bandwidth, and the one comparison worth making.

    The honest framing matters more here than anywhere else in the addon,
    because latency is where players most readily reach for a cause. Two facts
    constrain everything on this page:

      * `GetNetStats` is refreshed by the client roughly every 30 seconds. A
        latency spike shorter than that is invisible to every addon, including
        this one. The age of the current reading is shown, always.

      * WoW exposes no packet loss, no jitter and no route information. Those
        rows exist on this page and say so, rather than being quietly absent -
        "not offered by the client" is information; a missing row is not.

    The overlay graph puts world latency and frame time on one axis so a reader
    can see whether a hitch and a latency reading moved together. Moving
    together is all it shows. The panel says so.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("network", {})

local latValues, latTimes = {}, {}
local frameValues, frameTimes = {}, {}
local markerScratch = {}

function Page:Build(frame)
    local scroll, canvas = UI.ScrollCanvas(frame, { padding = M.padding })
    self.scroll, self.canvas = scroll, canvas

    local grid = UI.Grid(canvas, { minColumnWidth = 260, maxColumns = 4 })
    self.grid = grid

    self.world = UI.StatCard(canvas, "WORLD LATENCY", {
        "Current", "Average", "Minimum", "Peak", "Spikes",
    })
    grid:Add(self.world, { span = 1, height = 122, key = "world" })

    self.home = UI.StatCard(canvas, "HOME LATENCY", {
        "Current", "Average", "Minimum", "Peak", "Spikes",
    })
    grid:Add(self.home, { span = 1, height = 122, key = "home" })

    self.bandwidth = UI.StatCard(canvas, "BANDWIDTH", {
        "Incoming", "Outgoing", "Reading age",
    })
    grid:Add(self.bandwidth, { span = 1, height = 122, key = "bandwidth" })

    -- Deliberately present. A row that says the client does not offer a figure
    -- is worth more than the absence of the row: it answers the question.
    self.unavailable = UI.StatCard(canvas, "NOT OFFERED BY THE CLIENT", {
        "Packet loss", "Jitter", "Route / hops", "Server tick",
    })
    grid:Add(self.unavailable, { span = 1, height = 106, key = "unavailable" })

    self.graph = UI.Graph(canvas, { title = "WORLD LATENCY", unit = "ms" })
    grid:Add(self.graph, { span = 4, height = 200, key = "graph" })

    self.overlay = UI.Graph(canvas, {
        title = "WORLD LATENCY AND FRAME TIME ON ONE AXIS", unit = "",
    })
    grid:Add(self.overlay, { span = 4, height = 200, key = "overlay" })

    self.caveat = UI.Card(canvas, "WHAT THIS CAN AND CANNOT SHOW", {})
    self.caveat.body = UI.Text(self.caveat.content, "small", "textMuted", "LEFT")
    self.caveat.body:SetPoint("TOPLEFT")
    self.caveat.body:SetPoint("BOTTOMRIGHT")
    UI.Wrap(self.caveat.body, 0)
    self.caveat.body:SetJustifyV("TOP")
    self.caveat.body:SetText(
        "The client refreshes its latency figures roughly every 30 seconds. Anything shorter than that never reaches an addon at all, so a short spike can be entirely invisible here while being very visible to you.\n\n" ..
        "The overlay above draws both series on one time axis, each scaled to its own range. If a hitch and a latency reading rise together, that is worth noticing and worth investigating - it is not evidence that one produced the other, and this addon will not say that it is. A loading screen, a busy server tick and a heavy frame can all move both at once.\n\n" ..
        "Packet loss, jitter and route information are not exposed to addons by any WoW client. No addon can show them; anything that appears to is estimating.")
    grid:Add(self.caveat, { span = 4, height = 150, key = "caveat" })

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

function Page:OnShow() self:Refresh() end

--------------------------------------------------------------------------

function Page:Refresh()
    if not self.grid then return end
    self:OnLayout()

    local available = WTM.Caps:Has("latency")
    local reason = WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT

    if not available then
        for _, card in ipairs({ self.world, self.home, self.bandwidth }) do
            for label in pairs(card.rows) do card:SetUnavailable(label, reason) end
        end
    else
        local net = WTM.Network
        local session = net.session
        local samples = session.samples or 0

        self.world:Set("Current", ("%d ms"):format(net.current.latencyWorld or 0))
        self.world:Set("Average", samples > 0
            and ("%d ms"):format(session.sumWorld / samples) or "-")
        self.world:Set("Minimum", session.minWorld
            and ("%d ms"):format(session.minWorld) or "-")
        self.world:Set("Peak", ("%d ms"):format(session.peakWorld or 0),
            (session.peakWorld or 0) >= 250 and "warn" or nil)
        self.world:Set("Spikes", tostring(session.spikes or 0))

        self.home:Set("Current", ("%d ms"):format(net.current.latencyHome or 0))
        self.home:Set("Average", samples > 0
            and ("%d ms"):format(session.sumHome / samples) or "-")
        self.home:Set("Minimum", session.minHome
            and ("%d ms"):format(session.minHome) or "-")
        self.home:Set("Peak", ("%d ms"):format(session.peakHome or 0))
        self.home:Set("Spikes", "-", "muted")

        if WTM.Caps:Has("bandwidth") then
            self.bandwidth:Set("Incoming", ("%.2f KB/s"):format(net.current.bandwidthIn or 0))
            self.bandwidth:Set("Outgoing", ("%.2f KB/s"):format(net.current.bandwidthOut or 0))
        else
            self.bandwidth:SetUnavailable("Incoming", WTM.Caps:Note("bandwidth") or reason)
            self.bandwidth:SetUnavailable("Outgoing", WTM.Caps:Note("bandwidth") or reason)
        end
        self.bandwidth:Set("Reading age",
            Fmt.Duration(net.current.ageSeconds or 0),
            (net.current.ageSeconds or 0) > 35 and "warn" or "muted")
    end

    -- These four are not "unavailable on this client"; they are unavailable on
    -- every client, and the wording says which.
    local NEVER = "No WoW client exposes this to addons."
    self.unavailable:SetUnavailable("Packet loss", NEVER)
    self.unavailable:SetUnavailable("Jitter", NEVER)
    self.unavailable:SetUnavailable("Route / hops", NEVER)
    self.unavailable:SetUnavailable("Server tick", NEVER)

    ------------------------------------------------------------------
    local redraw = UI.MainWindow:ShouldRedrawGraphs()
    if not redraw then return end

    local now = GetTime()
    local from = now - math.max(120, math.min(3600, now - (WTM.state.sessionStart or now)))
    WTM.Context:GetMarkersInRange(from, now, markerScratch)

    if available then
        WTM.Recorder:GetSeries("latW", from, now, 300, latValues, latTimes)
        self.graph:SetSeries(1, latValues, latTimes,
            { label = "World latency", colorIndex = 3 })
        self.graph:SetTitle("WORLD LATENCY")
    else
        self.graph:ClearSeries()
        self.graph:SetTitle("WORLD LATENCY  -  " .. reason)
    end
    self.graph:SetTimeRange(from, now)
    self.graph:SetMarkers(markerScratch)

    -- The overlay reuses the same window so the two series line up exactly.
    WTM.Recorder:GetSeries("frameAvgMs", from, now, 300, frameValues, frameTimes)
    self.overlay:ClearSeries()
    self.overlay:SetSeries(1, frameValues, frameTimes,
        { label = "Frame time (ms)", colorIndex = 2 })
    if available then
        self.overlay:SetSeries(2, latValues, latTimes,
            { label = "World latency (ms)", colorIndex = 3 })
    end
    self.overlay:SetTimeRange(from, now)
    self.overlay:SetMarkers(markerScratch)

    if UI.MainWindow:TakeGraphSlot(1, 2) then
        self.graph.dirty = true
        self.graph:Draw()
    end
    if UI.MainWindow:TakeGraphSlot(2, 2) then
        self.overlay.dirty = true
        self.overlay:Draw()
    end
end
