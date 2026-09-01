-- Assertion suite.  Loads the addon under the mock for one flavor and checks
-- that it behaves correctly, rather than merely not erroring.
--   lua5.1 tools/test.lua <interface> [profileOn]

package.path = "./tools/?.lua;" .. package.path

local INTERFACE = tonumber(arg and arg[1]) or 120100
local PROFILE_ON = (arg and arg[2]) ~= "off"
-- "degraded" strips every optional API, to prove the feature-detection promise:
-- the addon must load, run and report honestly on a client that has none of them.
local DEGRADED = (arg and arg[3]) == "degraded"

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print(("   FAIL  %s%s"):format(name, detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

--------------------------------------------------------------------------
-- Environment (shares the harness in run.lua by re-implementing the minimum)
--------------------------------------------------------------------------
local mock = require("wowmock")

function GetBuildInfo()
    local map = { [120100] = "12.1.0", [50504] = "5.5.4", [20506] = "2.5.6", [11509] = "1.15.9" }
    return map[INTERFACE] or "0.0.0", "60000", "Feb 10 2026", INTERFACE
end
WOW_PROJECT_ID = (INTERFACE >= 100000) and 1 or 2

mock.knownEvents = {}
for _, e in ipairs({ "ADDON_LOADED","PLAYER_LOGIN","PLAYER_LOGOUT","PLAYER_ENTERING_WORLD",
    "PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","ZONE_CHANGED_NEW_AREA",
    "GROUP_ROSTER_UPDATE","COMBAT_LOG_EVENT_UNFILTERED","UNIT_AURA",
    "LOADING_SCREEN_ENABLED","LOADING_SCREEN_DISABLED" }) do
    mock.knownEvents[e] = true
end
if INTERFACE >= 50000 then
    mock.knownEvents.ENCOUNTER_START = true
    mock.knownEvents.ENCOUNTER_END = true
    mock.knownEvents.CHALLENGE_MODE_START = true
    mock.knownEvents.CHALLENGE_MODE_COMPLETED = true
end

local ADDONS = {
    { "WoWTaskManager", "WoW Task Manager", "0.1.0", true },
    { "WeakAuras", "WeakAuras", "5.20.1", true },
    { "LibStub", "LibStub", "1.0.2", true },
    { "SomeLODAddon", "Some LOD Addon", "1.0", false, true },
    { "DisabledAddon", "Disabled Addon", "0.9", false, false, 0 },
}
local cpuCounters, memValues = {}, {}
for i = 1, #ADDONS do cpuCounters[i] = 0 ; memValues[i] = 500 + i * 100 end

local cvars = { scriptProfile = PROFILE_ON and "1" or "0", maxFPS = "0", maxFPSBk = "30" }
if INTERFACE >= 100000 then cvars.vsync = "0" ; cvars.renderScale = "1.0"
else cvars.gxVSync = "0" end

local api = {
    GetNumAddOns = function() return #ADDONS end,
    GetAddOnInfo = function(i)
        local a = type(i) == "number" and ADDONS[i]
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        if not a then return nil end
        return a[1], a[2], "notes", true, nil, "INSECURE"
    end,
    GetAddOnMetadata = function(i, f)
        local a = type(i) == "number" and ADDONS[i]
        if a and f == "Version" then return a[3] end
        return nil
    end,
    IsAddOnLoaded = function(i)
        local a = type(i) == "number" and ADDONS[i]
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        return a and a[4] or false
    end,
    IsAddOnLoadOnDemand = function(i) local a = ADDONS[i] return a and a[5] or false end,
    GetAddOnEnableState = function(first, second)
        if INTERFACE >= 100000 then
            -- modern order only: (nameOrIndex, character)
            if type(first) == "number" then return ADDONS[first] and ADDONS[first][6] or 2 end
            if type(first) == "string" and (second == nil or type(second) == "string") then return 2 end
            return nil
        else
            -- legacy order only: (character, index)
            if type(second) == "number" then return ADDONS[second] and ADDONS[second][6] or 2 end
            return nil
        end
    end,
    GetAddOnDependencies = function(i)
        if ADDONS[i] and ADDONS[i][1] == "WeakAuras" then return "LibStub" end
        return nil
    end,
    GetAddOnOptionalDependencies = function() return nil end,
    LoadAddOn = function(name)
        for _, e in ipairs(ADDONS) do if e[1] == name then e[4] = true return true end end
        return false, "MISSING"
    end,
    EnableAddOn = function() return true end,
    DisableAddOn = function() return true end,
}
if INTERFACE >= 100000 then C_AddOns = api
else for k, v in pairs(api) do _G[k] = v end end

local CULPRIT = 2
function UpdateAddOnCPUUsage()
    if cvars.scriptProfile ~= "1" then return end
    for i = 1, #ADDONS do
        if ADDONS[i][4] then cpuCounters[i] = cpuCounters[i] + math.random() * 5 end
    end
end
function BurstCulprit(ms)
    if cvars.scriptProfile == "1" then cpuCounters[CULPRIT] = cpuCounters[CULPRIT] + ms end
end
function GetAddOnCPUUsage(i) return cvars.scriptProfile == "1" and (cpuCounters[i] or 0) or 0 end
function UpdateAddOnMemoryUsage()
    for i = 1, #ADDONS do if ADDONS[i][4] then memValues[i] = memValues[i] + (i == CULPRIT and 800 or 5) end end
end
function GetAddOnMemoryUsage(i) return memValues[i] or 0 end
function ResetCPUUsage() for i = 1, #ADDONS do cpuCounters[i] = 0 end end
function GetScriptCPUUsage() local t = 0 for i = 1, #ADDONS do t = t + cpuCounters[i] end return t end
function GetEventCPUUsage() return cvars.scriptProfile == "1" and 42.5 or 0, 1200 end
function GetFrameCPUUsage() return 1.5, 300 end
function GetFunctionCPUUsage() return 0.2, 10 end

C_CVar = {
    GetCVar = function(n) return cvars[n] end,
    SetCVar = function(n, v) cvars[n] = tostring(v) return true end,
    GetCVarBool = function(n) return cvars[n] == "1" end,
    GetCVarDefault = function(n) return cvars[n] end,
    GetCVarInfo = function(n)
        if cvars[n] == nil then return nil end
        return cvars[n], cvars[n], false, false, false, false, false
    end,
}
GetCVar, SetCVar = C_CVar.GetCVar, C_CVar.SetCVar
GetCVarBool, GetCVarDefault, GetCVarInfo = C_CVar.GetCVarBool, C_CVar.GetCVarDefault, C_CVar.GetCVarInfo
C_Timer = { After = function() end }

if DEGRADED then
    -- Remove everything the addon is only allowed to use after probing for it.
    GetNetStats = nil
    EnumerateFrames = nil
    GetEventCPUUsage = nil
    GetFrameCPUUsage = nil
    GetFunctionCPUUsage = nil
    GetScriptCPUUsage = nil
    GetPhysicalScreenSize = nil
    GetInstanceInfo = nil
    GetNumGroupMembers = nil
    IsEncounterInProgress = nil
    GetTimePreciseSec = nil
    GetCVarInfo = nil
    C_CVar.GetCVarInfo = nil
    C_Timer = nil
    -- ...and make RegisterAllEvents unavailable, the way a hypothetical
    -- locked-down client would.
    local Frame = getmetatable(CreateFrame("Frame"))
    Frame.RegisterAllEvents = function() error("RegisterAllEvents is not available") end
end

--------------------------------------------------------------------------
local NS = {}
do
    local xml = assert(io.open("WoWTaskManager/Includes.xml"))
    for line in xml:lines() do
        local path = line:match('<Script file="([^"]+)"')
        if path then
            local chunk = assert(loadfile("WoWTaskManager/" .. path:gsub("\\", "/")))
            chunk("WoWTaskManager", NS)
        end
    end
    xml:close()
end
mock.Fire("ADDON_LOADED", "WoWTaskManager")
mock.Fire("PLAYER_LOGIN")

print(("== %s, scriptProfile=%s%s =="):format(GetBuildInfo(), cvars.scriptProfile,
    DEGRADED and ", DEGRADED API" or ""))

--------------------------------------------------------------------------
-- Compatibility
--------------------------------------------------------------------------
local expectedFlavor = ({ [120100] = "retail", [50504] = "mop",
                          [20506] = "tbc", [11509] = "classic" })[INTERFACE]
check("flavor detection", NS.Compat.flavor == expectedFlavor, NS.Compat.flavor)
check("interface recorded", NS.Compat.tocVersion == INTERFACE)

-- GetAddOnEnableState argument order probing: the mock accepts only ONE order
-- depending on flavor, so a correct answer here proves the probe works.
check("enable state (enabled addon)", NS.Compat.GetAddOnEnableState(1, "Testchar") == 2,
    tostring(NS.Compat.GetAddOnEnableState(1, "Testchar")))
check("enable state (disabled addon)", NS.Compat.GetAddOnEnableState(5, "Testchar") == 0,
    tostring(NS.Compat.GetAddOnEnableState(5, "Testchar")))

-- Optional events must not error and must be reported honestly.
local hasEncounter = INTERFACE >= 50000
check("encounter event support probed",
    NS.Compat.IsEventSupported("ENCOUNTER_START") == hasEncounter)
check("encounter capability matches",
    NS.Caps:Has("encounterMarkers") == hasEncounter)
check("nonexistent event is safe",
    NS.Compat.IsEventSupported("TOTALLY_MADE_UP_EVENT") == false)
check("SafeRegisterEvent on a bogus event returns false",
    NS.Compat.SafeRegisterEvent(CreateFrame("Frame"), "ANOTHER_FAKE_EVENT") == false)

-- Retail-only CVars
if INTERFACE >= 100000 then
    check("renderScale capability on retail", NS.Caps:Get("cvarRenderScale") == "yes")
else
    check("renderScale unavailable off retail", NS.Caps:Get("cvarRenderScale") == "no")
end
check("vsync CVar resolved", NS.Caps:Get("cvarVSync") == "yes", NS.Caps.vsyncCVar)

if DEGRADED then
    -- Every one of these must be reported as unavailable, not crashed on.
    check("latency reported unavailable", NS.Caps:Get("latency") == "no")
    check("network module stands down", NS.Network.available == false)
    check("network task not registered", NS.Scheduler:GetTask("network") == nil)
    check("event rate reported unavailable", NS.Caps:Get("eventRate") == "no")
    check("event module stands down", NS.Events.available == false)
    check("event capture is off", NS.Events:IsCapturing() == false)
    check("event->addon attribution unavailable", NS.Caps:Get("eventToAddon") == "no")
    check("frame CPU unavailable", NS.Caps:Get("frameCPU") == "no")
    check("event CPU unavailable", NS.Caps:Get("eventCPU") == "no")
    check("resolution falls back", NS.Caps:Get("physicalResolution") == "partial")
    check("frame scan refuses cleanly", (function()
        local ok, err = NS.Processes:ScanFrames(true)
        return ok == false and err ~= nil
    end)())
    check("frame time still works", NS.Caps:Get("frameTime") == "yes")
    check("lua memory still works", NS.Caps:Get("luaMemory") == "yes")
    check("addon memory still works", NS.Caps:Get("addonMemory") == "yes")
end

-- Things that are never possible
for _, key in ipairs({ "addonUnload", "addonKill", "osCPU", "osMemory",
                       "packetInspection", "fileAccess", "protectedActions",
                       "graphicsAPI", "forceGC" }) do
    check("impossible stays impossible: " .. key, NS.Caps:Get(key) == "no")
end

--------------------------------------------------------------------------
-- CPU profiling gating
--------------------------------------------------------------------------
check("CPU availability tracks the CVar", NS.CPU.available == PROFILE_ON)
if not PROFILE_ON then
    check("CPU reason is stated", NS.CPU.reason ~= nil, NS.CPU.reason)
    check("addonCPU capability reports 'profile'", NS.Caps:Get("addonCPU") == "profile")
    check("cpu task is not registered", NS.Scheduler:GetTask("cpu") == nil)
end

--------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------
check("addons enumerated", #NS.Processes.list == #ADDONS, #NS.Processes.list)
local wa = NS.Processes:Get("WeakAuras")
check("addon lookup by name", wa ~= nil)
check("version metadata read", wa and wa.version == "5.20.1", wa and wa.version)
check("loaded flag", wa and wa.loaded == true)
check("LoadOnDemand flag", NS.Processes:Get("SomeLODAddon").lod == true)
check("dependencies read", wa and wa.deps and wa.deps[1] == "LibStub",
    wa and wa.deps and wa.deps[1])
check("dependents resolved",
    (function() local d = NS.Processes:GetDependents("LibStub") return d[1] == "WeakAuras" end)())

--------------------------------------------------------------------------
-- Simulate
--------------------------------------------------------------------------
math.randomseed(99)
local injected = 0
local function Simulate(seconds, spikeChancePerSecond, spikeMs)
    local elapsed = 0
    while elapsed < seconds do
        local ms = 16.67
        if spikeChancePerSecond and math.random() < spikeChancePerSecond / 60 then
            ms = spikeMs
            injected = injected + 1
            BurstCulprit(120)
        end
        mock.Tick(ms / 1000)
        elapsed = elapsed + ms / 1000
        if math.random() < 0.5 then mock.Fire("COMBAT_LOG_EVENT_UNFILTERED") end
    end
end
Simulate(90, 0.25, 200)

check("frames counted", NS.FrameTime:GetSessionStats().frames > 4000)
check("worst frame captured", NS.FrameTime:GetSessionStats().maxMs >= 190,
    NS.FrameTime:GetSessionStats().maxMs)
check("1% low is below the average", NS.FrameTime:Get1PercentLow() < NS.FrameTime:GetSessionStats().avgFPS)
check("spikes detected", NS.SpikeDetector.total > 0, NS.SpikeDetector.total)
check("spikes do not exceed injected count", NS.SpikeDetector.total <= injected,
    ("%d detected vs %d injected"):format(NS.SpikeDetector.total, injected))
check("200 ms frames classify as freeze or heavy",
    (NS.SpikeDetector.counts.freeze + NS.SpikeDetector.counts.heavy) == NS.SpikeDetector.total)
if DEGRADED then
    check("no events counted without RegisterAllEvents", NS.Events.current.total == 0)
else
    check("events counted", NS.Events.current.total > 1000, NS.Events.current.total)
    check("event rate is plausible", NS.Events.current.perSecond > 0)
end
check("memory sampled", NS.Memory.current.luaKB > 0)
check("addon memory attributed", NS.Memory.current.addonSumKB > 0)
check("flight recorder filled", NS.FlightRecorder:GetCoverageSeconds() > 30,
    NS.FlightRecorder:GetCoverageSeconds())
check("incidents captured", #NS.FlightRecorder.incidents > 0, #NS.FlightRecorder.incidents)

local incident = NS.FlightRecorder.incidents[1]
if incident then
    local hasBefore, hasAfter = false, false
    for _, sample in ipairs(incident.samples) do
        if sample.t < -1 then hasBefore = true end
        if sample.t > 1 then hasAfter = true end
    end
    check("incident contains the run-up", hasBefore)
    check("incident contains the recovery", hasAfter)
end

check("history buckets recorded", NS.Recorder:CountBuckets() > 30, NS.Recorder:CountBuckets())
local values, times = NS.Recorder:GetSeries("frameMaxMs", GetTime() - 120, GetTime(), 100)
check("series extraction works", #values > 5, #values)
check("series preserves the peak", (function()
    local peak = 0
    for _, v in ipairs(values) do if v > peak then peak = v end end
    return peak >= 190
end)(), "downsampling must keep maxima, not average them away")

--------------------------------------------------------------------------
-- Correlation wording
--------------------------------------------------------------------------
local correlations, samples, unavailable = NS.Correlation:Analyze()
if PROFILE_ON then
    check("correlation ran", unavailable == nil, unavailable)
    check("correlation found the culprit",
        correlations[1] and correlations[1].name == "WeakAuras",
        correlations[1] and correlations[1].name)
    check("culprit correlation is strong", correlations[1] and correlations[1].phi > 0.5,
        correlations[1] and correlations[1].phi)
else
    check("correlation reports why it cannot run", unavailable ~= nil)
end

-- The single most important editorial rule in the project.
local report = NS.Diagnostics:BuildReport()
local forbidden = { "caused by", "is causing", "the cause is", "responsible for", "blame" }
for _, phrase in ipairs(forbidden) do
    check("report avoids '" .. phrase .. "'", not report:lower():find(phrase, 1, true))
end
for _, label in ipairs(NS.C.CORRELATION_LEVELS) do
    check("correlation label is hedged: " .. label.label,
        not label.label:lower():find("cause"))
end

--------------------------------------------------------------------------
-- Combat safety
--------------------------------------------------------------------------
mock.inCombat = true
mock.Fire("PLAYER_REGEN_DISABLED")
local ranImmediately = NS.Compat.RunWhenSafe("test", function() mock.queuedRan = true end)
check("action deferred during combat", ranImmediately == false)
check("deferred action did not run yet", mock.queuedRan ~= true)
local ok, message = NS.Processes:SetEnabled("DisabledAddon", true)
check("enable during combat is queued", ok and message == NS.C.TXT_COMBAT_QUEUED, message)
mock.inCombat = false
mock.Fire("PLAYER_REGEN_ENABLED")
check("queue flushed after combat", mock.queuedRan == true)

--------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------
NS.UI.MainWindow:Open("dashboard")
check("window opens", NS.UI.MainWindow:IsOpen())
for _, key in ipairs(NS.UI.pageOrder) do
    NS.UI.MainWindow:ShowPage(key)
    NS.UI.MainWindow:Refresh()
    local page = NS.UI.Pages[key]
    check("page builds: " .. key, page.frame ~= nil and not page.buildFailed)
    check("page refreshes cleanly: " .. key, (page.refreshErrors or 0) == 0)
end

NS.UI.AddonDetail:Open(wa)
for _, tab in ipairs({ "overview","cpu","memory","history","events","dependencies","diagnostics","metadata" }) do
    NS.UI.AddonDetail:ShowTab(tab)
end
check("detail overlay opens", NS.UI.AddonDetail:IsOpen())
NS.UI.AddonDetail:Close()
NS.UI.MainWindow:Close()
check("ui task disabled while closed", NS.Scheduler:GetTask("ui").enabled == false)

--------------------------------------------------------------------------
-- Dashboard MVP requirements
--------------------------------------------------------------------------
-- The brief names the metrics the dashboard must show and the graphs it must
-- draw. Asserting on the built page keeps that contract from quietly eroding.

NS.UI.MainWindow:Open("dashboard")
NS.UI.MainWindow:Refresh()
local dashboard = NS.UI.Pages.dashboard

for _, key in ipairs({ "fps", "frame", "low1", "latHome", "latWorld",
                       "cpu", "memory", "events" }) do
    check("dashboard has a " .. key .. " tile", dashboard.cards[key] ~= nil)
end

local graphFields = {}
for _, graph in ipairs(dashboard.graphs or {}) do
    graphFields[graph.spec.key] = true
end
for _, key in ipairs({ "frame", "fps", "cpu", "latency", "events", "memory" }) do
    check("dashboard has a " .. key .. " graph", graphFields[key] == true)
end
check("frame time is the first graph on the dashboard",
    dashboard.graphs[1] and dashboard.graphs[1].spec.key == "frame",
    dashboard.graphs[1] and dashboard.graphs[1].spec.key)

-- Cards for unavailable measurements must explain themselves, not show zeros.
if not PROFILE_ON then
    check("the CPU tile reports unavailable rather than zero",
        dashboard.cards.cpu.unavailable == true)
    check("the profiling notice is shown",
        dashboard.profilingNotice:IsShown() == true)
end

--------------------------------------------------------------------------
-- Processes MVP requirements
--------------------------------------------------------------------------

NS.UI.MainWindow:ShowPage("processes")
NS.UI.MainWindow:Refresh()
local processes = NS.UI.Pages.processes
local columnKeys = {}
for _, column in ipairs(processes.table.columns) do columnKeys[column.key] = true end
for _, key in ipairs({ "name", "status", "cpu", "cpuavg", "cpupeak",
                       "memory", "memdelta", "events", "spikes", "score" }) do
    check("processes has a " .. key .. " column", columnKeys[key] == true)
end

-- Sorting must be stable: two addons with identical values must not swap.
do
    local view = {}
    NS.Processes:BuildView(view, "cpu", false, nil, true)
    local firstOrder = {}
    for i, record in ipairs(view) do firstOrder[i] = record.name end
    NS.Processes:BuildView(view, "cpu", false, nil, true)
    local stable = true
    for i, record in ipairs(view) do
        if firstOrder[i] ~= record.name then stable = false break end
    end
    check("process sorting is stable across identical rebuilds", stable)
end

-- Re-sorting must pause while the pointer is over the list.
processes.hovering = true
processes.lastRebuild = 0
local orderBefore = {}
for i, record in ipairs(processes.table.list.data) do orderBefore[i] = record.name end
processes:Refresh()
local frozen = true
for i, record in ipairs(processes.table.list.data) do
    if orderBefore[i] ~= record.name then frozen = false break end
end
check("process order is frozen while hovering", frozen)
processes.hovering = false

--------------------------------------------------------------------------
-- Incident record completeness
--------------------------------------------------------------------------

do
    local spike = NS.SpikeDetector.spikes[#NS.SpikeDetector.spikes]
    if spike then
        for _, field in ipairs({ "t", "kind", "label", "frameMs", "fps",
                                 "baselineMs", "latHome", "latWorld",
                                 "eventRate", "context" }) do
            check("incident record has " .. field, spike[field] ~= nil)
        end
        check("incident records its memory total", spike.memoryTotalKB ~= nil)
        if PROFILE_ON then
            check("incident records its CPU observation window",
                spike.cpuWindow ~= nil and spike.cpuWindow.seconds ~= nil)
        else
            check("incident says why CPU is missing", spike.cpuUnavailable ~= nil)
        end

        -- The wording rule: CPU is described against its window, never as part
        -- of the spiking frame.
        local described = NS.SpikeDetector:Describe(spike)
        check("spike description never claims CPU belongs to the frame",
            not described:lower():find("of this"), described:sub(1, 80))
        if PROFILE_ON and spike.cpu and #spike.cpu > 0 then
            check("spike description names the observation window",
                described:find("observation window") ~= nil)
        end
    end
end

--------------------------------------------------------------------------
-- Dev mode marks everything it injects
--------------------------------------------------------------------------

NS.db.profile.dev.enabled = true
do
    local injected = NS.Dev:InjectFrameSpike(300)
    check("an injected spike exists", injected ~= nil)
    if injected then
        check("an injected spike is flagged simulated", injected.simulated == true)
    end
end

--------------------------------------------------------------------------
-- Benchmark measures rather than generating load
--------------------------------------------------------------------------

do
    local framesBefore = NS.FrameTime:GetSessionStats().frames
    NS.Dev:Benchmark(3)
    NS.Dev:FinishBenchmark()
    check("the benchmark does not fabricate frames",
        NS.FrameTime:GetSessionStats().frames == framesBefore)
    check("the benchmark reports a measured total",
        NS.Overhead.current.totalMsPerSec ~= nil)
end

--------------------------------------------------------------------------
-- Retention
--------------------------------------------------------------------------
mock.Fire("PLAYER_LOGOUT")
check("session persisted", #NS.db.global.sessions == 1, #NS.db.global.sessions)
local session = NS.db.global.sessions[1]
check("session has fps summary", session.avgFPS and session.avgFPS > 0)
check("session records the client", session.flavor == expectedFlavor)
check("session records profiling state", session.profilingEnabled == PROFILE_ON)
check("session buckets are arrays", type(session.buckets) == "table"
    and (session.buckets[1] == nil or type(session.buckets[1]) == "table"))

-- Retention must actually bound growth.
for i = 1, 200 do
    table.insert(NS.db.global.sessions, 1, { startedAt = i, duration = 60 })
    NS.db.global.incidents[#NS.db.global.incidents + 1] = { id = i }
end
NS.Database:Prune()
check("sessions capped", #NS.db.global.sessions <= NS.db.profile.retention.maxSessions,
    #NS.db.global.sessions)
check("incidents capped", #NS.db.global.incidents <= NS.db.profile.retention.maxIncidents,
    #NS.db.global.incidents)

--------------------------------------------------------------------------
-- Live monitor
--------------------------------------------------------------------------

do
    NS.UI.LiveMonitor:Show()
    check("the live monitor opens", NS.UI.LiveMonitor:IsShown())
    NS.UI.LiveMonitor:Refresh()
    check("it shows an FPS value",
        NS.UI.LiveMonitor.rows.fps.value:GetText() ~= "",
        NS.UI.LiveMonitor.rows.fps.value:GetText())
    if not PROFILE_ON then
        check("it says CPU is off rather than showing zero",
            NS.UI.LiveMonitor.rows.cpu.value:GetText() == "off",
            NS.UI.LiveMonitor.rows.cpu.value:GetText())
    end

    -- It drives the UI task on its own, so closing the main window must not
    -- stop it updating.
    NS.UI.MainWindow:Open("dashboard")
    NS.UI.MainWindow:Close()
    check("the UI task stays on while the live monitor is visible",
        NS.Scheduler:GetTask("ui").enabled == true)

    NS.UI.LiveMonitor:Hide()
    check("the live monitor closes", NS.UI.LiveMonitor:IsShown() == false)
    check("the UI task stops once nothing is visible",
        NS.Scheduler:GetTask("ui").enabled == false)
end

--------------------------------------------------------------------------
-- Frame time distribution histogram
--------------------------------------------------------------------------

do
    NS.UI.MainWindow:Open("performance")
    NS.UI.MainWindow:ShowPage("performance")
    NS.UI.MainWindow:InvalidateGraphs()
    NS.UI.MainWindow:Refresh()
    local histogram = NS.UI.Pages.performance.histogram
    check("the performance page has a distribution histogram", histogram ~= nil)
    if histogram then
        check("the histogram received data", histogram.histogram ~= nil)
        check("the histogram reports a frame count",
            histogram.summary:GetText():find("frames") ~= nil,
            histogram.summary:GetText())
    end
    NS.UI.MainWindow:Close()
end

--------------------------------------------------------------------------
-- Graph redraws must be gated
--------------------------------------------------------------------------
-- A live client measured 33 ms/s of UI cost from redrawing six graphs twice a
-- second - an entire 60 FPS frame budget per redraw. Graphs may only redraw
-- when there is new data, because history buckets are one second apart.

do
    NS.UI.MainWindow:Open("dashboard")
    NS.UI.MainWindow:ShowPage("dashboard")

    local draws = 0
    local dashboard = NS.UI.Pages.dashboard
    for _, graph in ipairs(dashboard.graphs) do
        local original = graph.Draw
        graph.Draw = function(self, ...) draws = draws + 1 return original(self, ...) end
    end

    -- Twenty refreshes with no time passing and no new buckets.
    NS.UI.MainWindow:InvalidateGraphs()
    NS.UI.MainWindow:Refresh()
    local afterFirst = draws
    for _ = 1, 20 do NS.UI.MainWindow:Refresh() end

    check("the first refresh does draw the graphs", afterFirst > 0, afterFirst)
    check("twenty further refreshes with no new data redraw nothing",
        draws == afterFirst, ("%d -> %d"):format(afterFirst, draws))

    -- New buckets must let it through again.
    NS.Recorder.revision = NS.Recorder.revision + 1
    mock.Advance(5)
    NS.UI.MainWindow:Refresh()
    check("a new bucket allows a redraw", draws > afterFirst, draws)

    check("the graph update rate is configurable",
        NS.db.profile.ui.graphUpdateRate ~= nil)
    NS.UI.MainWindow:Close()
end

--------------------------------------------------------------------------
-- This addon never blames itself for the spikes it reacts to
--------------------------------------------------------------------------
-- Detecting a spike is what makes it burst-sample, so its own CPU rises right
-- after every spike. Correlating that with spikes inverts cause and effect.

do
    local self_ = NS.Processes:Get("WoWTaskManager")
    if self_ and PROFILE_ON then
        self_.cpuDeltaMs = 9999
        self_.cpuPct = 99
        self_.cpuSamples = 10
        self_.cpuSumPct = 10
        local deltas = NS.CPU:GetWindowDeltas(nil, 10, 0.1)
        local foundSelf = false
        for _, entry in ipairs(deltas) do
            if entry.name == "WoWTaskManager" then foundSelf = true end
        end
        check("this addon excludes itself from spike CPU attribution", not foundSelf)

        self_.spikes = 10
        NS.Processes:UpdateDerived(self_, 1)
        check("this addon never labels itself a spike source",
            self_.status.key ~= "SPIKY", self_.status.key)
    end
end

--------------------------------------------------------------------------
-- The frame walk must survive whatever EnumerateFrames actually returns
--------------------------------------------------------------------------
-- A live client returned FontStrings from EnumerateFrames, and their GetName
-- did not return a string. The scan crashed. These regions are now part of the
-- mock so the guard cannot quietly regress.

if not DEGRADED then
    mock.AddHostileRegions()
    local ok, err = pcall(NS.Processes.ScanFrames, NS.Processes, true)
    check("frame scan survives non-Frame objects in the walk", ok, err)
    check("non-frames are counted, not silently dropped",
        (NS.Processes.attribution.skippedNonFrames or 0) > 0,
        NS.Processes.attribution.skippedNonFrames)
    check("the attribution summary reports them",
        NS.Processes:AttributionSummary():find("not frames") ~= nil,
        NS.Processes:AttributionSummary())
end

--------------------------------------------------------------------------
-- Hover and click every interactive element
--------------------------------------------------------------------------
-- Tooltips and hover handlers are only reachable with a mouse, so nothing else
-- in this suite touches them. A truncated colour in a tooltip shipped and threw
-- 220 times in a real client because of exactly that gap.

do
    -- Visit every page first so their widgets exist to be hovered.
    for _, key in ipairs(NS.UI.pageOrder) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:Refresh()
    end
    NS.UI.AddonDetail:Open(wa)
    for _, tab in ipairs({ "overview","cpu","memory","history","events",
                           "dependencies","diagnostics","metadata" }) do
        NS.UI.AddonDetail:ShowTab(tab)
    end

    local enterRan, enterFailures = mock.FireScriptOnAll("OnEnter")
    check("something actually has a hover handler", enterRan > 10, enterRan)
    if #enterFailures > 0 then
        for i = 1, math.min(6, #enterFailures) do
            local f = enterFailures[i]
            print(("      OnEnter on %s: %s"):format(f.frame, f.err))
        end
    end
    check(("all %d OnEnter handlers survive"):format(enterRan),
        #enterFailures == 0, #enterFailures .. " failed")

    local leaveRan, leaveFailures = mock.FireScriptOnAll("OnLeave")
    check(("all %d OnLeave handlers survive"):format(leaveRan),
        #leaveFailures == 0, #leaveFailures .. " failed")

    -- Clicking must be safe too, including on rows with no data bound.
    local clickRan, clickFailures = mock.FireScriptOnAll("OnClick", "LeftButton")
    if #clickFailures > 0 then
        for i = 1, math.min(6, #clickFailures) do
            local f = clickFailures[i]
            print(("      OnClick on %s: %s"):format(f.frame, f.err))
        end
    end
    check(("all %d OnClick handlers survive"):format(clickRan),
        #clickFailures == 0, #clickFailures .. " failed")

    NS.UI.AddonDetail:Close()
end

--------------------------------------------------------------------------
print(("   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(5, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
