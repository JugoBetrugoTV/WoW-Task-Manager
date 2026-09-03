-- Assertion suite.  Loads the addon under the mock for one flavor and checks
-- that it behaves correctly, rather than merely not erroring.
--   lua5.1 tools/test.lua <interface> [profileOn]

package.path = "./tools/?.lua;" .. package.path

local INTERFACE = tonumber(arg and arg[1]) or 120100
local PROFILE_ON = (arg and arg[2]) ~= "off"

-- Remaining arguments are flags, in any order.
local flags = {}
for i = 3, (arg and #arg or 0) do flags[arg[i]] = true end

-- "degraded" strips every optional API, to prove the feature-detection promise:
-- the addon must load, run and report honestly on a client that has none of them.
local DEGRADED = flags.degraded or false
-- "ace3" loads a faithful Ace3 stand-in BEFORE the addon, so the Ace3 branch of
-- Core/Ace.lua runs.  On a real client that branch is taken whenever any other
-- installed addon embeds Ace3, so it is not an exotic configuration - it is the
-- common one, and it was the untested one.
local WITH_ACE3 = flags.ace3 or false

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
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        if not a then return nil end
        if f == "Version" then return a[3] end
        -- Title and SavedVariables are how a second copy of this addon is
        -- recognised, including one that has been renamed.
        if f == "Title" then return a[2] end
        if f == "SavedVariables" then return a[7] end
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

--------------------------------------------------------------------------
-- Options-panel registration, which differs per client.
--
-- Modern clients register a canvas category through Settings; older ones use
-- InterfaceOptions_AddCategory. Neither is present on every supported client,
-- so exactly one is exposed here per flavor and the addon has to find it by
-- probing rather than by checking a version.
--------------------------------------------------------------------------
mock.optionsPanels = {}
if INTERFACE >= 100000 then
    Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            mock.optionsPanels[#mock.optionsPanels + 1] = { frame = frame, name = name }
            return { ID = "cat_" .. tostring(name), name = name }
        end,
        RegisterAddOnCategory = function(category)
            mock.registeredCategory = category
        end,
        OpenToCategory = function(id)
            mock.openedCategory = id
            return true
        end,
    }
else
    function InterfaceOptions_AddCategory(frame)
        mock.optionsPanels[#mock.optionsPanels + 1] = { frame = frame, name = frame.name }
        return true
    end
    function InterfaceOptionsFrame_OpenToCategory(frame)
        mock.openedCategory = frame and frame.name
        return true
    end
end

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
    -- No way to add a panel under Options - AddOns at all. The addon must load
    -- and work regardless; it simply has no entry there.
    Settings = nil
    InterfaceOptions_AddCategory = nil
    InterfaceOptionsFrame_OpenToCategory = nil
    -- ...and make RegisterAllEvents unavailable, the way a hypothetical
    -- locked-down client would.
    local Frame = getmetatable(CreateFrame("Frame"))
    Frame.RegisterAllEvents = function() error("RegisterAllEvents is not available") end
end

--------------------------------------------------------------------------
if WITH_ACE3 then require("ace3stub").Install() end

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

print(("== %s, scriptProfile=%s%s%s =="):format(GetBuildInfo(), cvars.scriptProfile,
    DEGRADED and ", DEGRADED API" or "", WITH_ACE3 and ", Ace3" or ""))

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

        -- The same exclusion has to hold in the correlation table, which is
        -- where a "probable cause" would actually be presented to the player.
        local correlations = NS.Correlation:Analyze({})
        local inCorrelation = false
        for _, entry in ipairs(correlations) do
            if entry.name == "WoWTaskManager" then inCorrelation = true end
        end
        check("and never appears as a correlated candidate", not inCorrelation)

        -- Its cost is not hidden, though - it is reported, under its own
        -- heading, as overhead rather than as a suspect.
        check("its cost is still reported, as overhead",
            (NS.Overhead.current.totalMsPerSec or 0) >= 0
                and #NS.Overhead:GetBreakdown() > 0)
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
-- Ace3 backend
--------------------------------------------------------------------------
-- Which backend is active depends on whether some OTHER addon in the player's
-- list loaded Ace3, so both branches have to be exercised.

check("backend matches the environment", NS.Ace.usingAce3 == WITH_ACE3,
    tostring(NS.Ace.usingAce3))
if WITH_ACE3 then
    check("AceDB was actually used", NS.Database.backend == "AceDB-3.0", tostring(NS.Database.backend))
else
    check("internal DB was used", NS.Database.backend ~= "AceDB-3.0", tostring(NS.Database.backend))
end
-- Whichever backend is in play, the database has to behave the same.
check("profile survives the backend", type(NS.db.profile) == "table")
check("global survives the backend", type(NS.db.global) == "table")
check("schema version readable", NS.db.global.schemaVersion ~= nil)

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------
-- WoW invokes SlashCmdList[key](msg, editBox).  The handler therefore has to
-- read the command out of the FIRST argument.  It did not: AceConsole embeds
-- RegisterChatCommand with a different calling convention than the internal
-- fallback, so on a client that had Ace3 loaded the handler received the chat
-- edit box where the command string belonged, and /wtm threw on every use.
-- These checks drive the command the way the client does, through whatever
-- registration is actually installed.

do
    local slashKeys = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and name:match("^SLASH_.+1$") and value == "/wtm" then
            slashKeys[#slashKeys + 1] = name:match("^SLASH_(.+)1$")
        end
    end
    -- Exactly one, or the command the player gets depends on table order. Two
    -- registrations is what a second, AceConsole-installed RegisterChatCommand
    -- would leave behind.
    check("/wtm is registered exactly once", #slashKeys == 1,
        table.concat(slashKeys, ", "))

    local handler = slashKeys[1] and SlashCmdList[slashKeys[1]]
    check("the registered command has a handler", type(handler) == "function")

    if handler then
        -- The second argument is the real trap: WoW passes the edit box frame.
        local editBox = CreateFrame("EditBox", "WTMTestChatEditBox")
        local errors = {}
        local function run(input)
            local ok, err = pcall(handler, input, editBox)
            if not ok then errors[#errors + 1] = ("%q -> %s"):format(tostring(input), tostring(err)) end
        end

        -- Every command reachable from chat, minus the ones that destroy data
        -- (reset) - those are covered by their own tests.
        for _, cmd in ipairs({ "", "show", "dashboard", "processes", "performance",
                               "timeline", "events", "memory", "diagnostics",
                               "sessions", "system", "settings", "incidents",
                               "mini", "hide", "overhead", "caps", "help",
                               "nonsense-command", "  help  " }) do
            run(cmd)
        end
        -- WoW passes "" for a bare slash, but a nil has been seen in the wild
        -- when other addons re-dispatch commands.
        run(nil)

        for i = 1, math.min(6, #errors) do print("      /wtm " .. errors[i]) end
        check("every /wtm command survives the client's calling convention",
            #errors == 0, #errors .. " failed")

        -- And it has to do something, not merely not crash.
        NS.UI.MainWindow:Close()
        run("dashboard")
        check("/wtm dashboard opens the window", NS.UI.MainWindow:IsOpen())
        check("/wtm dashboard selects the page",
            NS.UI.MainWindow.currentPage == "dashboard",
            tostring(NS.UI.MainWindow.currentPage))
        run("processes")
        check("/wtm processes switches page",
            NS.UI.MainWindow.currentPage == "processes",
            tostring(NS.UI.MainWindow.currentPage))
        run("hide")
        check("/wtm hide closes the window", not NS.UI.MainWindow:IsOpen())
    end
end

--------------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------------

do
    local mm = NS.UI.MinimapButton
    check("the minimap button exists", mm.button ~= nil, mm:UnavailableReason())
    check("it is shown by default", mm:IsShown())
    check("it is parented to the minimap",
        mm.button and mm.button:GetParent() == _G.Minimap)

    -- It carries a live FPS readout, which only means anything if something
    -- refreshes it while the main window is closed.
    local task = NS.Scheduler:GetTask("minimap")
    check("it has a refresh task of its own", task ~= nil)
    check("the task is charged to the ui budget", task and task.category == "ui",
        task and task.category)
    check("the task runs while the button is shown", task and task.enabled)

    mm:Refresh()
    check("the readout says something", mm.button and mm.button.text:GetText() ~= nil,
        mm.button and mm.button.text:GetText())

    -- Hiding it must stop the task too, or a hidden button keeps costing.
    mm:SetShown(false)
    check("hiding it hides the button", not mm:IsShown())
    check("hiding it stops the task", not NS.Scheduler:GetTask("minimap").enabled)
    check("the choice is persisted", NS.db.profile.minimap.shown == false)

    mm:Toggle()
    check("toggling brings it back", mm:IsShown())
    check("and restarts the task", NS.Scheduler:GetTask("minimap").enabled)

    -- The two clicks, driven the way the client drives them.
    local onClick = mm.button:GetScript("OnClick")
    check("the button handles clicks", type(onClick) == "function")
    if onClick then
        NS.UI.MainWindow:Close()
        onClick(mm.button, "LeftButton")
        check("left click opens the window", NS.UI.MainWindow:IsOpen())
        onClick(mm.button, "LeftButton")
        check("left click again closes it", not NS.UI.MainWindow:IsOpen())

        onClick(mm.button, "RightButton")
        check("right click opens the window", NS.UI.MainWindow:IsOpen())
        check("right click lands on Settings",
            NS.UI.MainWindow.currentPage == "settings",
            tostring(NS.UI.MainWindow.currentPage))
        NS.UI.MainWindow:Close()
    end

    -- Dragging stores an angle, and the button comes back where it was left.
    local onDragStart = mm.button:GetScript("OnDragStart")
    local onUpdate    = mm.button:GetScript("OnUpdate")
    local onDragStop  = mm.button:GetScript("OnDragStop")
    check("the button can be dragged",
        onDragStart and onUpdate and onDragStop and true or false)
    if onDragStart then
        local before = NS.db.profile.minimap.angle
        onDragStart(mm.button)
        onUpdate(mm.button, 0.016)
        onDragStop(mm.button)
        check("dragging writes an angle",
            type(NS.db.profile.minimap.angle) == "number",
            tostring(NS.db.profile.minimap.angle))
        check("the angle is what gets persisted, not a screen position",
            NS.db.profile.minimap.x == nil and NS.db.profile.minimap.y == nil)
        NS.db.profile.minimap.angle = before
    end
end

--------------------------------------------------------------------------
-- Options - AddOns entry
--------------------------------------------------------------------------
-- Three registration APIs exist across the four clients and none is present
-- everywhere, so what is asserted here is what this particular mock offers.

do
    local opts = NS.UI.Options
    if DEGRADED then
        check("no panel is claimed when the client offers no way to add one",
            not opts.registered)
        check("and the reason is stated", type(opts.unavailable) == "string",
            tostring(opts.unavailable))
        local ok, reason = opts:OpenBlizzardPanel()
        check("opening it fails honestly rather than erroring",
            ok == false and type(reason) == "string", tostring(reason))
    else
        check("an entry is registered", opts.registered, tostring(opts.unavailable))
        check("through the API this client actually has",
            opts.method == (INTERFACE >= 100000 and "settings" or "interfaceOptions"),
            tostring(opts.method))
        check("the panel was handed to the client", #mock.optionsPanels == 1,
            #mock.optionsPanels)
        check("under the addon's name",
            mock.optionsPanels[1] and mock.optionsPanels[1].name == NS.C.ADDON_TITLE,
            mock.optionsPanels[1] and tostring(mock.optionsPanels[1].name))
        check("and it opens", opts:OpenBlizzardPanel())
    end

    -- The panel is deliberately almost empty, but it must not be a blank frame.
    local panel = opts:BuildPanel()
    check("the panel has content", panel ~= nil)
    check("the panel carries an open button", opts.openButton ~= nil)
end

--------------------------------------------------------------------------
-- Onboarding
--------------------------------------------------------------------------
-- Shown once, skippable at every step, replayable afterwards. The steps that
-- offer an action have to actually perform it.

do
    local ob = NS.UI.Onboarding
    check("it has a small number of steps",
        #ob.STEPS >= 4 and #ob.STEPS <= 6, #ob.STEPS)

    ob:Open()
    check("the introduction opens", ob:IsShown())
    check("it starts at the first step", ob.index == 1, ob.index)
    check("Back is disabled on the first step", ob.frame.backButton.disabled == true)

    -- Walk forwards through every step and collect what each one says.
    local titles, hasAction = {}, {}
    for i = 1, #ob.STEPS do
        ob:ShowStep(i)
        titles[i] = ob.frame.title:GetText()
        hasAction[i] = ob.frame.actionButton:IsShown()
        check(("step %d has a title"):format(i), (titles[i] or "") ~= "")
        check(("step %d has a body"):format(i), (ob.frame.body:GetText() or "") ~= "")
        check(("step %d offers a way out"):format(i), ob.frame.skipButton:IsShown())
    end

    local joined = table.concat(titles, " | "):lower()
    check("one step explains per-addon CPU profiling",
        joined:find("cpu") ~= nil, joined)
    check("one step covers the compact monitor",
        joined:find("compact") ~= nil or joined:find("monitor") ~= nil, joined)
    check("one step says where the settings are",
        joined:find("where") ~= nil or joined:find("settings") ~= nil, joined)

    local actions = 0
    for _, yes in ipairs(hasAction) do if yes then actions = actions + 1 end end
    check("at least two steps offer an action button", actions >= 2, actions)

    check("the last step finishes rather than continuing",
        ob.frame.nextButton.text:GetText() == "Finish",
        ob.frame.nextButton.text:GetText())

    -- Back and forward.
    ob:ShowStep(2)
    ob:Advance(-1)
    check("Back goes back", ob.index == 1, ob.index)
    ob:Advance(1)
    check("Next goes forward", ob.index == 2, ob.index)

    -- The profiling step's button must actually change the setting, and must
    -- never reload the UI on its own.
    if NS.Caps:Has("toggleProfiling") then
        for i = 1, #ob.STEPS do
            if ob.STEPS[i].key == "profiling" then
                NS.Caps:SetCPUProfiling(false)
                ob:ShowStep(i)
                check("the profiling step offers an enable button",
                    ob.frame.actionButton:IsShown()
                        and not ob.frame.actionButton.disabled)
                mock.reloadRequested = false
                ob:RunAction()
                check("it enables profiling", NS.Caps:IsCPUProfilingEnabled())
                check("and never reloads the UI by itself",
                    mock.reloadRequested ~= true)
                check("the button then says there is nothing left to do",
                    ob.frame.actionButton.disabled == true)
            end
        end
    end

    -- Skipping is the same commitment as finishing: do not show this again.
    check("it has not been marked seen yet", not ob:HasBeenSeen())
    ob:ShowStep(1)
    local skipClick = ob.frame.skipButton:GetScript("OnClick")
    skipClick(ob.frame.skipButton, "LeftButton")
    check("Skip closes it", not ob:IsShown())
    check("Skip marks it seen", ob:HasBeenSeen())
    check("which is persisted", NS.db.global.onboardingDone == true)

    -- ...and it stays replayable afterwards.
    ob:Open()
    check("it can be replayed after being finished", ob:IsShown())
    check("replaying starts at the beginning again", ob.index == 1, ob.index)
    ob:Close()
end

--------------------------------------------------------------------------
-- Live monitor: collapsing
--------------------------------------------------------------------------

do
    local lm = NS.UI.LiveMonitor
    lm:Show()
    local fullHeight = lm.frame:GetHeight()
    check("the rows are visible when expanded", lm.rows.fps:IsShown())

    lm:SetCollapsed(true)
    check("collapsing hides the rows", not lm.rows.fps:IsShown())
    check("collapsing shrinks the panel", lm.frame:GetHeight() < fullHeight,
        lm.frame:GetHeight())
    check("the header takes over the readout", lm.header.summary:IsShown())
    lm:Refresh()
    check("and the readout has numbers in it",
        (lm.header.summary:GetText() or ""):find("%d") ~= nil,
        lm.header.summary:GetText())
    check("the button offers the way back", lm.header.collapse.text:GetText() == "+",
        lm.header.collapse.text:GetText())
    check("the state is persisted", NS.db.profile.liveMonitor.collapsed == true)

    lm:SetCollapsed(false)
    check("expanding restores the rows", lm.rows.fps:IsShown())
    check("expanding restores the height", lm.frame:GetHeight() == fullHeight,
        lm.frame:GetHeight())

    -- Collapsed or not, it must still be reachable and closable.
    check("the header has a settings button", lm.header.config ~= nil)
    lm:Hide()
    check("it closes", not lm:IsShown())
end

--------------------------------------------------------------------------
-- Command catalogue
--------------------------------------------------------------------------
-- The user-facing promise is that nothing requires typing a chat command. That
-- only holds if the button list and the command list are the same list.

do
    check("there is a command catalogue", type(NS.COMMANDS) == "table")
    check("it is not trivially short", #NS.COMMANDS >= 15, #NS.COMMANDS)

    local missingHandler, missingHelp, missingLabel = {}, {}, {}
    for _, entry in ipairs(NS.COMMANDS) do
        if type(NS:GetCommandHandler(entry.cmd)) ~= "function" then
            missingHandler[#missingHandler + 1] = entry.cmd
        end
        if type(entry.help) ~= "string" or entry.help == "" then
            missingHelp[#missingHelp + 1] = entry.cmd
        end
        if type(entry.label) ~= "string" or entry.label == "" then
            missingLabel[#missingLabel + 1] = entry.cmd
        end
    end
    check("every catalogued command actually runs something",
        #missingHandler == 0, table.concat(missingHandler, ", "))
    check("every catalogued command explains itself",
        #missingHelp == 0, table.concat(missingHelp, ", "))
    check("every catalogued command has a button label",
        #missingLabel == 0, table.concat(missingLabel, ", "))

    -- ...and the reverse: a command that exists but is not catalogued is a
    -- command with no button, which is the thing being ruled out. "show" is a
    -- deliberate alias for the bare command.
    local catalogued = {}
    for _, entry in ipairs(NS.COMMANDS) do catalogued[entry.cmd] = true end
    catalogued["show"] = true
    local uncatalogued = {}
    local handler = SlashCmdList[slashKeyForWtm or ""]
    for _, cmd in ipairs({ "", "show", "dashboard", "processes", "performance",
                           "timeline", "events", "memory", "diagnostics",
                           "sessions", "system", "settings", "incidents",
                           "mini", "hide", "profiling", "reset", "overhead",
                           "caps", "dev", "benchmark", "help" }) do
        if not catalogued[cmd] then uncatalogued[#uncatalogued + 1] = cmd end
    end
    check("no command is missing from the catalogue",
        #uncatalogued == 0, table.concat(uncatalogued, ", "))

    -- /wtm help must print the catalogue rather than a hand-maintained copy.
    local before = #DEFAULT_CHAT_FRAME.messages
    NS:GetCommandHandler("help")("")
    local printed = table.concat(DEFAULT_CHAT_FRAME.messages, "\n", before + 1)
    local unmentioned = {}
    for _, entry in ipairs(NS.COMMANDS) do
        if entry.cmd ~= "" and not printed:find(entry.cmd, 1, true) then
            unmentioned[#unmentioned + 1] = entry.cmd
        end
    end
    check("/wtm help lists every catalogued command",
        #unmentioned == 0, table.concat(unmentioned, ", "))
end

--------------------------------------------------------------------------
-- Everything reachable without typing a command
--------------------------------------------------------------------------
-- The promise is that a normal player never needs a slash command. That only
-- holds if the Settings page really carries a control for each one.

do
    NS.UI.MainWindow:Open("settings")
    NS.UI.MainWindow:RefreshCurrentPage()
    local page = NS.UI.Pages.settings

    check("no command is left without a button",
        page.orphanedCommands and #page.orphanedCommands == 0,
        page.orphanedCommands and table.concat(page.orphanedCommands, ", "))

    -- The named controls the user asked for, by the text on them.
    -- Every piece of text on a control: buttons carry theirs in a child font
    -- string, checkboxes in a label beside the box.
    local labels = {}
    for _, region in ipairs(mock.allFrames) do
        if region._kind == "FontString" and (region._text or "") ~= "" then
            labels[#labels + 1] = region._text:lower()
        end
    end
    local joined = table.concat(labels, " | ")

    local REQUIRED = {
        ["open the window"]   = "open wtm",
        ["compact monitor"]   = "mini monitor",
        ["benchmark"]         = "benchmark",
        ["profiling"]         = "profiling",
        ["reload"]            = "reload ui",
        ["capabilit"]         = "capability report",
        ["developer"]         = "dev mode",
        ["delete all saved"]  = "reset data",
        ["diagnostics"]       = "diagnostics",
    }
    local missing = {}
    for needle, what in pairs(REQUIRED) do
        if not joined:find(needle, 1, true) then missing[#missing + 1] = what end
    end
    table.sort(missing)
    check("every control the UI is supposed to expose has a button",
        #missing == 0, table.concat(missing, ", "))

    -- Developer tools are behind their own gate, not mixed in with the rest.
    -- (An earlier check in this suite ran /wtm dev, so the state is set here
    -- explicitly rather than assumed.)
    NS.Dev:SetEnabled(false)
    NS.UI.MainWindow:RefreshCurrentPage()
    check("developer mode can be turned off", not NS.Dev:IsEnabled())
    local devButtons, devEnabledButtons = 0, 0
    for _, control in ipairs(page.controls or {}) do
        if control.tooltipTitle and tostring(control.tooltipTitle):find("/wtm dev", 1, true) then
            devButtons = devButtons + 1
            if not control.disabled then devEnabledButtons = devEnabledButtons + 1 end
        end
    end
    check("the developer section has buttons", devButtons >= 8, devButtons)
    check("they are disabled while developer mode is off",
        devEnabledButtons == 0, devEnabledButtons)

    NS.Dev:SetEnabled(true)
    NS.UI.MainWindow:RefreshCurrentPage()
    devEnabledButtons = 0
    for _, control in ipairs(page.controls or {}) do
        if control.tooltipTitle and tostring(control.tooltipTitle):find("/wtm dev", 1, true)
            and not control.disabled then
            devEnabledButtons = devEnabledButtons + 1
        end
    end
    check("enabling developer mode unlocks them",
        devEnabledButtons >= 8, devEnabledButtons)
    NS.Dev:SetEnabled(false)

    -- Destructive buttons must not fire on a single click.
    local confirmButtons = 0
    for _, control in ipairs(page.controls or {}) do
        if control.isConfirmButton then confirmButtons = confirmButtons + 1 end
    end
    check("destructive controls ask for a second click", confirmButtons >= 3, confirmButtons)

    local sessionsBefore = #NS.db.global.sessions
    NS.db.global.sessions[#NS.db.global.sessions + 1] = { id = 999, startedAt = time() }
    local wipe
    for _, control in ipairs(page.controls or {}) do
        if control.isConfirmButton and control.baseLabel == "Delete all saved history" then
            wipe = control
        end
    end
    check("the delete-history button exists", wipe ~= nil)
    if wipe then
        local click = wipe:GetScript("OnClick")
        click(wipe, "LeftButton")
        check("one click does not delete anything",
            #NS.db.global.sessions == sessionsBefore + 1, #NS.db.global.sessions)
        check("it says what the second click will do",
            wipe.text:GetText() == "Click again to confirm", wipe.text:GetText())
        click(wipe, "LeftButton")
        check("the second click deletes", #NS.db.global.sessions == 0,
            #NS.db.global.sessions)
        check("and the button goes back to its label",
            wipe.text:GetText() == "Delete all saved history", wipe.text:GetText())
    end

    -- Reload is offered but never automatic.
    mock.reloadRequested = false
    NS.UI.MainWindow:RefreshCurrentPage()
    check("nothing reloaded the UI by itself", mock.reloadRequested ~= true)

    NS.UI.MainWindow:Close()
end

--------------------------------------------------------------------------
-- Graph redraw pacing
--------------------------------------------------------------------------
-- Redrawing every graph in one tick was measured at ~15 ms in a real client -
-- a whole frame. They take turns instead. The rules: one decision per tick, a
-- bounded number of redraws per tick, and everything gets its turn.

do
    local W = NS.UI.MainWindow
    W:Open("performance")

    -- One decision per tick, not one per caller. The live monitor refreshes
    -- before the page does, and used to consume the tick for itself.
    W.lastGraphDraw = nil
    W:InvalidateGraphs()
    W:BeginGraphPass()
    check("a pass opens when the data is stale", W:ShouldRedrawGraphs())
    check("asking twice gives the same answer", W:ShouldRedrawGraphs())
    check("asking does not consume the pass", W:ShouldRedrawGraphs())

    -- A bounded number of graphs per pass.
    W.lastGraphDraw = nil
    W.graphsDirty = true
    W.forceFullGraphPass = false
    W:BeginGraphPass()
    local granted = 0
    for i = 1, 8 do
        if W:TakeGraphSlot(i, 8) then granted = granted + 1 end
    end
    check("a pass redraws only a few graphs", granted > 0 and granted <= 3, granted)

    -- Sparklines have their own budget, so a visible live monitor cannot take
    -- the page's turn away from it.
    local sparkGranted = 0
    for i = 1, 6 do
        if W:TakeSparkSlot(i, 6) then sparkGranted = sparkGranted + 1 end
    end
    check("the live monitor has a budget of its own",
        sparkGranted > 0 and sparkGranted <= 3, sparkGranted)

    -- Over several passes every graph gets a turn.
    local seen = {}
    for pass = 1, 8 do
        W.lastGraphDraw = nil
        W.graphsDirty = true
        W.forceFullGraphPass = false
        W:BeginGraphPass()
        for i = 1, 8 do
            if W:TakeGraphSlot(i, 8) then seen[i] = true end
        end
    end
    local turns = 0
    for i = 1, 8 do if seen[i] then turns = turns + 1 end end
    check("every graph gets its turn within a few passes", turns == 8, turns)

    -- A resize drag marks graphs stale but must NOT demand a full pass: forcing
    -- one on every frame of a drag is what made resizing stutter.
    W.forceFullGraphPass = false
    W:MarkGraphsDirty()
    check("a resize drag does not force a full redraw", not W.forceFullGraphPass)
    W:InvalidateGraphs()
    check("a page change does force one", W.forceFullGraphPass)

    -- And the gate still holds: nothing redraws twice within the update rate.
    W.lastGraphDraw = nil
    W:BeginGraphPass()
    W:BeginGraphPass()
    check("a second tick inside the update rate does not redraw",
        not W:ShouldRedrawGraphs())

    W:Close()
end

--------------------------------------------------------------------------
-- Overhead accounting
--------------------------------------------------------------------------
-- A breakdown that does not add up to the total is not a breakdown.

do
    local rows = NS.Overhead:GetBreakdown()
    check("the breakdown has categories", #rows >= 4, #rows)

    local remainder
    for _, row in ipairs(rows) do
        if row.key == "dispatch" then remainder = row end
    end
    check("the unattributed remainder is always shown", remainder ~= nil)
    if remainder then
        check("and it is named as unattributed rather than as a component",
            remainder.label:lower():find("unattributed") ~= nil, remainder.label)
        check("with an explanation", (remainder.note or "") ~= "")
    end

    local sum, total, delta = NS.Overhead:ReconcileBreakdown()
    check("the categories reconcile against the measured total",
        math.abs(delta) < 0.0001, ("sum %.4f vs total %.4f"):format(sum, total))

    -- Measured time is never described as costing nothing.
    for _, row in ipairs(rows) do
        if row.measured and (row.ms or 0) > 0.001 then
            check(("%s does not call its measured time 'no cost'"):format(row.label),
                not tostring(row.note or ""):lower():find("no cost"), row.note)
        end
    end

    -- The dashboard has to have room for every category plus the total.
    NS.UI.MainWindow:Open("dashboard")
    NS.UI.MainWindow:RefreshCurrentPage()
    local shown = 0
    for _, row in ipairs(NS.UI.Pages.dashboard.overheadRows) do
        if row:IsShown() then shown = shown + 1 end
    end
    check("every category and the total fit on the card",
        shown == #rows + 1, ("%d rows shown for %d categories"):format(shown, #rows))
    NS.UI.MainWindow:Close()
end

--------------------------------------------------------------------------
-- Every page opens, refreshes and survives being empty
--------------------------------------------------------------------------
-- Ten pages were added in 0.6.0. The failure mode that matters for all of them
-- is the same: a widget that reads a number which does not exist yet, on a
-- client that cannot measure it, and throws instead of saying so.

do
    NS.UI.MainWindow:Open()

    local expected = {
        "dashboard", "overview", "processes", "resources", "performance",
        "frames", "network", "events", "memory", "incidents", "timeline",
        "diagnostics", "impact", "compare", "sessions", "recording",
        "system", "alerts", "settings",
    }
    local missing = {}
    for _, key in ipairs(expected) do
        if not NS.UI.Pages[key] then missing[#missing + 1] = key end
    end
    check("every page in the navigation exists", #missing == 0,
        table.concat(missing, ", "))

    -- Every page is reachable from the sidebar; a page nobody can click is a
    -- page nobody has.
    local unreachable = {}
    for _, key in ipairs(NS.UI.pageOrder) do
        if not NS.UI.Sidebar.items[key] then unreachable[#unreachable + 1] = key end
    end
    check("every page has a sidebar entry", #unreachable == 0,
        table.concat(unreachable, ", "))

    -- Exactly one page may be visible at a time. A frame in WoW is visible the
    -- moment it is created, so a page left showing is drawn underneath the one
    -- you switched to - which is what a real client reported. Checked after
    -- every navigation path a player has, not just a straight sweep.
    local function visiblePages()
        local shown = {}
        for _, key in ipairs(NS.UI.pageOrder) do
            local page = NS.UI.Pages[key]
            if page.frame and page.frame:IsShown() then shown[#shown + 1] = key end
        end
        return shown
    end

    local worst, worstAfter = 0, ""
    local function recordVisible(label)
        local shown = visiblePages()
        if #shown > worst then worst, worstAfter = #shown, label .. ": " .. table.concat(shown, ", ") end
    end

    -- Clicking the sidebar, which is how a player actually navigates.
    for _, key in ipairs(NS.UI.pageOrder) do
        local item = NS.UI.Sidebar.items[key]
        local handler = item and item:GetScript("OnClick")
        if handler then
            handler(item)
            recordVisible("sidebar click " .. key)
        end
    end

    -- Closing and reopening restores the remembered page.
    NS.UI.MainWindow:Close()
    NS.UI.MainWindow:Open()
    recordVisible("close and reopen")

    -- Selecting the page you are already on, then moving on.
    NS.UI.MainWindow:ShowPage("memory")
    NS.UI.MainWindow:ShowPage("memory")
    NS.UI.MainWindow:ShowPage("events")
    recordVisible("re-selecting the current page")

    -- A page built while another is on screen. This is the case the old code
    -- got wrong: CreateFrame returns a VISIBLE frame, so a lazily built page
    -- appeared over the current one for the length of its build.
    local rebuilt = NS.UI.Pages.system
    rebuilt.frame = nil
    NS.UI.MainWindow:ShowPage("system")
    recordVisible("building a page lazily")

    -- And the deliberately broken one: a page whose Build throws still has a
    -- frame, and that frame must not be left drawn over its successor.
    local brokenPage, originalBuild = NS.UI.Pages.alerts, NS.UI.Pages.alerts.Build
    brokenPage.frame, brokenPage.Build = nil, function() error("simulated build failure") end
    NS.UI.MainWindow:ShowPage("alerts")
    NS.UI.MainWindow:ShowPage("dashboard")
    recordVisible("switching away from a page that failed to build")
    brokenPage.Build, brokenPage.frame, brokenPage.buildFailed = originalBuild, nil, nil
    NS.UI.MainWindow:ShowPage("alerts")

    -- That failure was raised on purpose, and it really did travel through the
    -- error handler and get recorded - which is the wiring working. Take it
    -- back out so the suite's own "no unexpected errors" count stays honest.
    for i = #mock.errors, 1, -1 do
        if tostring(mock.errors[i]):find("simulated build failure", 1, true) then
            table.remove(mock.errors, i)
        end
    end
    NS.Errors:Reset()

    -- page.frame belongs to MainWindow: it is the frame it created for the
    -- page, and the frame it hides when you switch away. Overview assigned a
    -- StatCard to it, so every switch hid that CARD and left the whole page
    -- drawn on top of wherever you went next - on every page, for the life of
    -- the session. Nothing else in the addon can notice, because the page
    -- itself looks perfect while it is the one selected.
    local clobbered = {}
    for _, key in ipairs(NS.UI.pageOrder) do
        local page = NS.UI.Pages[key]
        if page.frame then
            -- The real page frame is a direct child of the window's content
            -- area. Anything else in this field is a widget that took its name.
            if page.frame:GetParent() ~= NS.UI.MainWindow.frame.content then
                clobbered[#clobbered + 1] = key
            end
        end
    end
    check("no page overwrites the frame field MainWindow owns",
        #clobbered == 0, table.concat(clobbered, ", "))

    -- And the consequence, checked directly: every widget a page builds has to
    -- descend from that page's frame, or hiding the page cannot hide it.
    local escaped = {}
    for _, key in ipairs(NS.UI.pageOrder) do
        local page = NS.UI.Pages[key]
        if page.frame and type(page.grid) == "table" and page.grid.cells then
            for _, cell in ipairs(page.grid.cells) do
                local node, hops, reached = cell.frame, 0, false
                while node and hops < 16 do
                    if node == page.frame then reached = true break end
                    node = node:GetParent()
                    hops = hops + 1
                end
                if not reached then
                    escaped[#escaped + 1] = ("%s.%s"):format(key, tostring(cell.key))
                end
            end
        end
    end
    check("every widget a page builds descends from that page's frame",
        #escaped == 0, table.concat(escaped, ", "))

    check("only one page is ever visible at a time", worst <= 1, worstAfter)

    -- Two folders containing this addon load as two separate addons, each with
    -- its own window, its own samplers and its own pages. Each hides its own
    -- pages correctly and cannot see the other, so from the outside it looks
    -- like every page showing through every other one - and everything is
    -- measured twice. A real client reported exactly that picture.
    do
        local SECOND = "WoWTaskManager-Copy"
        local second = {}
        local loaded, failure = true, nil
        local xml = io.open("WoWTaskManager/Includes.xml")
        for line in xml:lines() do
            local path = line:match('<Script file="([^"]+)"')
            if path and loaded then
                local chunk = loadfile("WoWTaskManager/" .. path:gsub("\\", "/"))
                local ok, err = pcall(chunk, SECOND, second)
                if not ok then loaded, failure = false, err end
            end
        end
        xml:close()

        check("a second copy loads without erroring", loaded, tostring(failure))
        check("it recognises the copy that got there first",
            second.duplicateOf == "WoWTaskManager", tostring(second.duplicateOf))
        check("it does not steal the global from the running copy",
            _G.WoWTaskManager == NS,
            _G.WoWTaskManager and _G.WoWTaskManager.name or "nil")

        -- And it stays switched off through a full boot.
        mock.Fire("ADDON_LOADED", SECOND)
        mock.Fire("PLAYER_LOGIN")
        check("the second copy never initialises",
            not (second.state and second.state.initialized),
            tostring(second.state and second.state.initialized))
        check("and never starts sampling",
            not (second.state and second.state.enabled),
            tostring(second.state and second.state.enabled))
        check("and never builds a window",
            second.UI == nil or second.UI.MainWindow == nil
                or second.UI.MainWindow.frame == nil)

        check("the running copy is untouched by it",
            NS.state.enabled == true and NS.UI.MainWindow.frame ~= nil)
    end

    -- A copy that is INSTALLED but disabled in the addon list never loads, so
    -- the guard above cannot see it. It is one click away from producing two of
    -- everything, so it is found by reading the installed list instead.
    do
        local found = NS:FindOtherCopies()
        check("no other copy is reported when there is none", #found == 0,
            table.concat(found, ", "))

        -- Add one to the client's installed list, disabled, the way a leftover
        -- folder sits there.
        ADDONS[#ADDONS + 1] = { "WoWTaskManager-old", "WoW Task Manager", "0.6.0",
                                false, false, 0, "WoWTaskManagerDB" }
        found = NS:FindOtherCopies()
        check("an installed but disabled copy is found",
            #found == 1 and found[1] == "WoWTaskManager-old",
            table.concat(found, ", "))

        -- A renamed folder still declares the same database.
        ADDONS[#ADDONS + 1] = { "MyPerfTool", "Something Else", "1.0",
                                false, false, 0, "WoWTaskManagerDB" }
        found = NS:FindOtherCopies()
        check("so is a renamed one, by the database it declares", #found == 2,
            table.concat(found, ", "))

        ADDONS[#ADDONS] = nil
        ADDONS[#ADDONS] = nil
        check("and nothing is reported once they are gone",
            #NS:FindOtherCopies() == 0)
    end

    -- And the belt-and-braces repair: a page forced visible behind the
    -- current one is caught on the next tick, hidden, and reported rather
    -- than silently patched.
    NS.UI.MainWindow:ShowPage("processes")
    NS.UI.Pages.overview.frame:Show()
    check("a stray page is detected", NS.UI.MainWindow:EnforceSinglePage() == 1)
    check("and hidden again", NS.UI.Pages.overview.frame:IsShown() == false)
    check("and named rather than patched in silence",
        (NS.UI.MainWindow:DescribeStrayPages() or ""):find("overview", 1, true) ~= nil,
        tostring(NS.UI.MainWindow:DescribeStrayPages()))

    NS.Diagnostics:InvalidateCache()
    local strayFindings = NS.Diagnostics:Build({})
    local reported = false
    for _, finding in ipairs(strayFindings) do
        if finding.title:find("drawn over another", 1, true) then reported = true end
    end
    check("and reported as a fault in this addon", reported)

    NS.UI.MainWindow.strayPages, NS.UI.MainWindow.pageRepairs = nil, nil
    NS.Diagnostics:InvalidateCache()

    -- Stale layout. A page keeps the geometry it was built with until
    -- something lays it out again; only the visible page used to be relaid out
    -- on a resize. A real client showed one page's content drawn over another
    -- page's table, with filter buttons running past the window's edge,
    -- because the window had been made smaller and nothing clipped it.
    check("the content area clips its children",
        NS.UI.MainWindow.frame.content._clipsChildren == true,
        tostring(NS.UI.MainWindow.frame.content._clipsChildren))

    NS.UI.MainWindow.frame:SetSize(1600, 900)
    for _, key in ipairs(NS.UI.pageOrder) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:RefreshCurrentPage()
    end
    -- Now shrink it the way a player does. During the drag only the visible
    -- page is laid out, on purpose: doing all of them on every frame of a
    -- resize is how resizing became this addon's own worst stutter. So the
    -- others ARE stale in between, and the clipping above is what keeps that
    -- from reaching the screen.
    NS.UI.MainWindow.frame:SetSize(940, 600)
    local resize = NS.UI.MainWindow.frame:GetScript("OnSizeChanged")
    if resize then resize(NS.UI.MainWindow.frame) end

    local contentWidth = NS.UI.MainWindow.frame.content:GetWidth() or 0
    local function stalePages()
        local stale = {}
        for _, key in ipairs(NS.UI.pageOrder) do
            local page = NS.UI.Pages[key]
            -- A scrolling page's canvas width is the honest record of the
            -- width it last laid itself out for.
            if page.scroll and page.canvas and key ~= NS.UI.MainWindow.currentPage then
                if (page.canvas:GetWidth() or 0) > contentWidth + 2 then
                    stale[#stale + 1] = key
                end
            end
        end
        return stale
    end

    -- This is the state the bug lived in, and it has to be real or the check
    -- below proves nothing.
    local staleDuringDrag = stalePages()
    check("pages other than the visible one are stale mid-resize",
        #staleDuringDrag > 0, "none were, so the next check proves nothing")

    -- And on release, every one of them is brought up to date.
    NS.UI.MainWindow:LayoutAllPages()
    local staleAfter = stalePages()
    check("releasing the resize brings every built page up to date",
        #staleAfter == 0, table.concat(staleAfter, ", "))

    -- A monitor that records nothing must say so. A real client sat on
    -- "Performance: EXCELLENT, health 100/100" at 0.0 FPS because sampling was
    -- off and nothing anywhere mentioned it.
    local samplingWas = NS.db.profile.sampling.enabled
    NS.db.profile.sampling.enabled = false
    NS.Scheduler:Stop()
    check("a paused addon can say why", NS.Scheduler:WhyNotRunning() ~= nil)

    -- Every /wtm command this addon tells the user to type has to exist. It
    -- told a real client to run "/wtm recording", which did not.
    local named = {}
    local function collectCommands(text)
        for command in tostring(text):gmatch("/wtm%s+([%a]+)") do
            named[command] = true
        end
    end
    collectCommands(NS.Scheduler:WhyNotRunning())
    for _, source in ipairs({ "Core/Core.lua", "Core/Scheduler.lua",
                              "Core/ErrorMonitor.lua", "UI/Pages/Errors.lua" }) do
        local handle = io.open("WoWTaskManager/" .. source, "r")
        if handle then collectCommands(handle:read("*a")) handle:close() end
    end
    local missingCommands = {}
    for command in pairs(named) do
        if not NS:GetCommandHandler(command) then
            missingCommands[#missingCommands + 1] = command
        end
    end
    table.sort(missingCommands)
    check("every /wtm command the addon names actually exists",
        #missingCommands == 0, table.concat(missingCommands, ", "))

    NS.UI.MainWindow:ShowPage("dashboard")
    NS.UI.MainWindow:RefreshCurrentPage()
    local verdict = NS.UI.Pages.dashboard.banner.verdict:GetText() or ""
    check("the dashboard leads with it rather than a health score",
        verdict:find("Not recording", 1, true) ~= nil, verdict)
    check("and offers a way back", NS.UI.Pages.dashboard.resumeButton:IsShown())

    NS.UI.Sidebar:Refresh()
    local footerState = NS.UI.Sidebar.footer.state:GetText() or ""
    check("the footer names the reason rather than just 'Paused'",
        footerState:find("OFF", 1, true) ~= nil, footerState)

    NS.db.profile.sampling.enabled = samplingWas
    if samplingWas then NS.Scheduler:Start() end
    NS.UI.MainWindow:RefreshCurrentPage()
    check("and goes back to normal once recording resumes",
        NS.Scheduler:WhyNotRunning() == nil)

    -- Menus, dialogs and overlays hang off UIParent so they can escape the
    -- window's edge, which means nothing hides them implicitly. Left alone
    -- they stayed on screen across a page switch and even after the window
    -- was closed, drawn over the game world. Reported from a real client.
    local function leftovers()
        local open = {}
        if NS.UI.IsContextMenuShown() then open[#open + 1] = "context menu" end
        if _G.WTMCopyBox and _G.WTMCopyBox:IsShown() then open[#open + 1] = "copy box" end
        if NS.UI.AddonDetail.scrim and NS.UI.AddonDetail.scrim:IsShown() then
            open[#open + 1] = "addon detail"
        end
        if NS.UI.ErrorDetail.scrim and NS.UI.ErrorDetail.scrim:IsShown() then
            open[#open + 1] = "error detail"
        end
        return table.concat(open, ", ")
    end

    NS.UI.MainWindow:ShowPage("processes")
    NS.UI.ShowContextMenu(NS.UI.MainWindow.frame,
        { { label = "an entry", onClick = function() end },
          -- A disabled entry takes the other colour branch, which is where a
          -- truncated multi-return used to throw the moment a menu opened.
          { label = "a disabled entry", disabled = true, reason = "why not" } },
        "a menu")
    check("a context menu opens without erroring", NS.UI.IsContextMenuShown())
    NS.UI.MainWindow:ShowPage("memory")
    check("a context menu does not survive a page change", leftovers() == "", leftovers())

    NS.UI.ShowCopyBox("some text", "a title")
    NS.UI.MainWindow:ShowPage("events")
    check("a copy box does not survive a page change", leftovers() == "", leftovers())

    local detailRecord = NS.Processes:Get("WeakAuras")
    if detailRecord then
        NS.UI.AddonDetail:Open(detailRecord)
        NS.UI.MainWindow:ShowPage("timeline")
        check("a detail overlay does not survive a page change",
            leftovers() == "", leftovers())
    end

    NS.UI.ShowContextMenu(NS.UI.MainWindow.frame,
        { { label = "an entry", onClick = function() end } }, "a menu")
    NS.UI.MainWindow:Close()
    check("nothing is left on screen after the window closes",
        leftovers() == "", leftovers())
    NS.UI.MainWindow:Open()

    local before = #mock.errors
    for _, key in ipairs(NS.UI.pageOrder) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:LayoutPage(key)
        NS.UI.MainWindow:RefreshCurrentPage()
        NS.UI.MainWindow:RefreshCurrentPage()
        local page = NS.UI.Pages[key]
        check(("page builds: %s"):format(key), page.frame ~= nil and not page.buildFailed)
        check(("page refreshes cleanly: %s"):format(key),
            (page.refreshErrors or 0) == 0, page.refreshErrors)
    end
    check("no page threw while being visited", #mock.errors == before,
        (#mock.errors - before) .. " new errors")
end

--------------------------------------------------------------------------
-- The new analysis modules
--------------------------------------------------------------------------

do
    -- Impact: a score with its inputs visible, and never a probability.
    local list, availability = NS.Impact:Compute({})
    check("the impact ranking is built", type(list) == "table")
    check("it reports which components contributed", type(availability) == "table")
    check("this addon is not in its own ranking", (function()
        for _, entry in ipairs(list) do
            if entry.name == "WoWTaskManager" then return false end
        end
        return true
    end)())
    for _, entry in ipairs(list) do
        check(("%s has a score in range"):format(entry.name),
            entry.score >= 0 and entry.score <= 100, entry.score)
        check(("%s shows its components"):format(entry.name),
            type(entry.components) == "table"
                and entry.components.cpu ~= nil and entry.components.spikes ~= nil)
    end
    check("the formula is stated, not hidden",
        NS.Impact.EXPLANATION:find("weighted", 1, true) ~= nil)
    check("and it says what the score is not",
        NS.Impact.EXPLANATION:lower():find("not a percentage", 1, true) ~= nil)

    -- Every ranking key sorts without erroring.
    for _, ranking in ipairs(NS.Impact.RANKINGS) do
        local ok = pcall(NS.Impact.Sort, NS.Impact, list, ranking.key)
        check(("ranking '%s' sorts"):format(ranking.key), ok)
    end

    -- Observations: sentences with numbers, in the past tense, no causation.
    local observations = NS.Observations:Build({})
    check("observations are produced", #observations > 0, #observations)
    local BANNED = { "caused", "because of", "is to blame", "responsible for" }
    local offenders = {}
    for _, entry in ipairs(observations) do
        check("each observation has a title", (entry.title or "") ~= "")
        local text = ((entry.title or "") .. " " .. (entry.detail or "")):lower()
        for _, phrase in ipairs(BANNED) do
            if text:find(phrase, 1, true) then
                offenders[#offenders + 1] = phrase .. " in: " .. (entry.title or "")
            end
        end
    end
    check("no observation asserts a cause", #offenders == 0,
        table.concat(offenders, "; "))

    -- Comparison: a delta only where both sides have a value.
    local live = NS.Sessions:LiveSnapshot()
    check("the live session can be compared", live ~= nil)
    local rows = NS.Observations:Compare(live, live, {})
    check("comparing a session with itself produces rows", #rows > 0, #rows)
    local nonZero = 0
    for _, row in ipairs(rows) do
        if row.deltaValue and math.abs(row.deltaValue) > 0.0001 then
            nonZero = nonZero + 1
        end
    end
    check("and every delta is zero", nonZero == 0, nonZero)

    local partial = { avgFPS = 60 }
    rows = NS.Observations:Compare(partial, live, {})
    local blanks = 0
    for _, row in ipairs(rows) do
        if row.delta == nil then blanks = blanks + 1 end
    end
    check("a missing value leaves the change cell blank rather than inventing zero",
        blanks > 0, blanks)
end

--------------------------------------------------------------------------
-- Alerts
--------------------------------------------------------------------------
-- The rules must not spam, must not fire when they cannot be measured, and
-- must not need a timer of their own.

do
    local Alerts = NS.Alerts
    check("alerts have rules", #Alerts.RULES >= 5, #Alerts.RULES)
    check("they run on the shared scheduler, not a timer of their own",
        NS.Scheduler:GetTask("alerts") ~= nil)

    local ruleTasks = 0
    for _, task in NS.Scheduler:IterateTasks() do
        if task.name:find("alert", 1, true) then ruleTasks = ruleTasks + 1 end
    end
    check("one task for all of them, not one per rule", ruleTasks == 1, ruleTasks)

    -- Off by default, and nothing fires while off.
    NS.db.profile.alerts.enabled = false
    Alerts:ClearLog()
    for _ = 1, 5 do Alerts:Evaluate() end
    check("nothing fires while alerts are off", #Alerts.log == 0, #Alerts.log)

    -- A rule that trips fires once, not once per evaluation.
    NS.db.profile.alerts.enabled = true
    NS.db.profile.alerts.chat = false
    local config = Alerts:Config("frameTime")
    config.enabled = true
    config.threshold = 0.001   -- guaranteed to be exceeded
    Alerts:ClearLog()
    for _ = 1, 10 do Alerts:Evaluate() end
    check("a tripped rule fires", #Alerts.log >= 1, #Alerts.log)
    check("but only once while it stays tripped", #Alerts.log == 1, #Alerts.log)

    -- A rule that cannot be measured here is not silently never fired: it
    -- reports why.
    for _, rule in ipairs(Alerts.RULES) do
        local reason = Alerts:UnavailableReason(rule)
        if reason then
            check(("%s explains why it cannot run"):format(rule.key),
                type(reason) == "string" and #reason > 10, reason)
        end
    end

    if not PROFILE_ON then
        local cpuRule
        for _, rule in ipairs(Alerts.RULES) do
            if rule.key == "addonCPU" then cpuRule = rule end
        end
        check("the CPU rule is unavailable without profiling",
            Alerts:UnavailableReason(cpuRule) ~= nil)
    end

    -- A fired alert lands on the shared timeline, so it can be found again.
    NS.db.profile.alerts.marker = true
    Alerts:ClearLog()
    Alerts.state.frameTime.firing = false
    Alerts.state.frameTime.lastFiredAt = nil
    local markersBefore = #NS.Context.markers
    Alerts:Evaluate()
    check("firing places a timeline marker", #NS.Context.markers > markersBefore)

    NS.db.profile.alerts.enabled = false
    config.enabled = false
    NS.db.profile.alerts.chat = true
end

--------------------------------------------------------------------------
-- Dashboard layout settings
--------------------------------------------------------------------------

do
    NS.UI.MainWindow:ShowPage("dashboard")
    local dashboard = NS.UI.Pages.dashboard
    check("the dashboard declares its widgets", #dashboard.WIDGETS >= 8, #dashboard.WIDGETS)

    -- Every widget key has at least one grid cell, or the layout editor would
    -- offer a control that does nothing.
    local orphans = {}
    for _, widget in ipairs(dashboard.WIDGETS) do
        local found = false
        for _, cell in ipairs(dashboard.grid.cells) do
            if cell.key == widget.key then found = true end
        end
        if not found then orphans[#orphans + 1] = widget.key end
    end
    check("every declared widget has a cell", #orphans == 0, table.concat(orphans, ", "))

    -- Hiding one actually hides it, and refreshing afterwards is still safe.
    local first = dashboard.WIDGETS[2]
    NS.db.profile.dashboard.hidden[first.key] = true
    dashboard:ApplyLayoutSettings()
    local hiddenCell
    for _, cell in ipairs(dashboard.grid.cells) do
        if cell.key == first.key then hiddenCell = cell end
    end
    check("hiding a widget hides its cell", hiddenCell and not hiddenCell.frame:IsShown())
    local before = #mock.errors
    dashboard:Refresh()
    check("refreshing with a widget hidden does not throw", #mock.errors == before)

    NS.db.profile.dashboard.hidden[first.key] = nil
    dashboard:ApplyLayoutSettings()

    -- Sizes change the span, which is what "large" has to mean.
    NS.db.profile.dashboard.sizes[first.key] = "large"
    dashboard:ApplyLayoutSettings()
    local cell
    for _, c in ipairs(dashboard.grid.cells) do
        if c.key == first.key then cell = c end
    end
    check("choosing a size changes the span",
        cell and cell.span == first.spans.large, cell and cell.span)
    NS.db.profile.dashboard.sizes[first.key] = nil
    dashboard:ApplyLayoutSettings()
end

--------------------------------------------------------------------------
-- The responsive grid
--------------------------------------------------------------------------

do
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(1000, 600)
    local grid = NS.UI.Grid(host, { minColumnWidth = 200, maxColumns = 6, gap = 10 })
    check("a wide host gets more columns", grid:ColumnsFor(1400) > grid:ColumnsFor(500))
    check("a narrow host never drops below one column", grid:ColumnsFor(50) == 1)
    check("it never exceeds its maximum", grid:ColumnsFor(100000) == 6)

    for i = 1, 6 do
        local cell = CreateFrame("Frame", nil, host)
        grid:Add(cell, { span = 1, height = 50, key = "c" .. i })
    end
    local tall = grid:Layout(true)
    check("laying out returns a height", tall > 0, tall)

    host:SetSize(400, 600)
    local taller = grid:Layout(true)
    check("a narrower host needs more height for the same cells", taller > tall,
        ("%d then %d"):format(tall, taller))

    -- Relayout is skipped when nothing changed: it resizes every cell, and a
    -- resize marks graphs dirty.
    local again = grid:Layout()
    check("an unchanged width does not relayout", again == taller)
end

--------------------------------------------------------------------------
-- Text must stay inside its boundaries
--------------------------------------------------------------------------
-- The headless harness can answer this now: SetPoint is recorded, anchors are
-- resolved, and a font string has a real width. Two failure modes, and they are
-- not equally bad:
--
--   unbounded  the string has no width of its own and is wider than the panel
--              it sits in. WoW does not clip it - it draws straight over
--              whatever is beside it. This is "text runs into itself", and the
--              budget for it is zero.
--   clipped    the string has a width and the text is wider. WoW cuts it off at
--              the edge. Ugly, but inside its boundaries.
--
-- Run at the SMALLEST window the addon allows, which is where every layout is
-- under the most pressure.

do
    local function auditAllPages()
        for _, key in ipairs(NS.UI.pageOrder) do
            NS.UI.MainWindow:ShowPage(key)
            NS.UI.MainWindow:LayoutPage(key)
            -- ShowPage refreshes before the layout above, and MainWindow:Refresh
            -- returns early while the window is hidden, so the page is
            -- refreshed explicitly here - otherwise every measurement would be
            -- of the pre-layout geometry.
            NS.UI.MainWindow:RefreshCurrentPage()
        end
        NS.UI.AddonDetail:Open(wa)
        for _, tab in ipairs({ "overview","cpu","memory","history","events",
                               "dependencies","diagnostics","metadata" }) do
            NS.UI.AddonDetail:ShowTab(tab)
        end
        NS.UI.AddonDetail:Close()

        local findings = mock.AuditText()
        local unbounded, clipped = {}, {}
        for _, f in ipairs(findings) do
            if f.kind == "unbounded" then unbounded[#unbounded + 1] = f
            else clipped[#clipped + 1] = f end
        end
        return unbounded, clipped
    end

    local function report(list, label)
        for i = 1, math.min(6, #list) do
            local f = list[i]
            print(("      %s: %q needs %.0f px in %.0f"):format(
                label, f.text:sub(1, 48), f.width, f.box))
        end
    end

    -- At the default size.
    NS.UI.MainWindow:Open()
    local unbounded, clipped = auditAllPages()
    report(unbounded, "escapes")
    check("no text escapes its panel at the default window size",
        #unbounded == 0, #unbounded .. " found")
    check("almost nothing is clipped at the default window size",
        #clipped <= 2, #clipped .. " clipped")

    -- And at the minimum the window can be resized to, which is the case the
    -- real client complained about.
    NS.UI.MainWindow.frame:SetSize(940, 600)
    unbounded, clipped = auditAllPages()
    report(unbounded, "escapes at min size")
    check("no text escapes its panel at the minimum window size",
        #unbounded == 0, #unbounded .. " found")
    report(clipped, "clipped at min size")
    check("clipping at the minimum window size stays rare",
        #clipped <= 3, #clipped .. " clipped")

    -- Long addon names and long localisation strings are the two inputs that
    -- break a layout in a way English test data never does.
    local longName = "SuperExtendedRaidFrameEnhancementSuiteDeluxe"
    local record = NS.Processes:Get("WeakAuras")
    if record then
        local originalTitle = record.title
        record.title = longName
        NS.UI.MainWindow:ShowPage("processes")
        NS.UI.MainWindow:LayoutPage("processes")
        NS.UI.MainWindow:RefreshCurrentPage()
        NS.UI.AddonDetail:Open(record)
        local findings = mock.AuditText()
        local escaped = 0
        for _, f in ipairs(findings) do
            if f.kind == "unbounded" then escaped = escaped + 1 end
        end
        check("a very long addon name does not escape its row", escaped == 0, escaped)
        NS.UI.AddonDetail:Close()
        record.title = originalTitle
    end

    -- ...and the direct form of the reported failure: two font strings on one
    -- row painting over each other. A label anchored LEFT and a value anchored
    -- RIGHT, neither of them bounded, grow towards each other until they meet.
    NS.UI.MainWindow.frame:SetSize(940, 600)
    for _, key in ipairs(NS.UI.pageOrder) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:LayoutPage(key)
        NS.UI.MainWindow:RefreshCurrentPage()
    end
    local overlaps = mock.AuditTextOverlap()
    for i = 1, math.min(6, #overlaps) do
        local o = overlaps[i]
        print(("      overlap %.0f px: %q over %q"):format(
            o.overlap, tostring(o.a):sub(1, 28), tostring(o.b):sub(1, 28)))
    end
    check("no two labels on the same row paint over each other",
        #overlaps == 0, #overlaps .. " overlapping pairs")

    -- Long localisation strings. Every label in this addon is English today;
    -- a German or Russian translation of the same label is routinely half again
    -- as long, and a row that only just fits in English does not fit then.
    -- Rather than wait for a translation, the widgets are stressed directly.
    do
        -- Long enough to exceed any row width the layout can produce, so the
        -- check is of the mechanism rather than of one particular window size.
        local LONG_LABEL = "Durchschnittliche Bildrate im Beobachtungsfenster " ..
            "einschliesslich aller geladenen Erweiterungen und ihrer Ereignisse"
        local LONG_VALUE = "1.234,567 Millisekunden pro Sekunde ueber das gesamte Fenster"

        NS.UI.MainWindow:ShowPage("dashboard")
        NS.UI.MainWindow:LayoutPage("dashboard")
        NS.UI.MainWindow:RefreshCurrentPage()

        local rows = NS.UI.Pages.dashboard.overheadRows
        check("the overhead card has rows to stress", rows and #rows > 0)
        for _, row in ipairs(rows or {}) do
            if row:IsShown() then
                row:SetLabel(LONG_LABEL)
                row:Set(LONG_VALUE)
            end
        end

        local overlaps2 = mock.AuditTextOverlap()
        for i = 1, math.min(4, #overlaps2) do
            local o = overlaps2[i]
            print(("      long-string overlap %.0f px: %q over %q"):format(
                o.overlap, tostring(o.a):sub(1, 30), tostring(o.b):sub(1, 30)))
        end
        check("a long label and a long value on one row do not collide",
            #overlaps2 == 0, #overlaps2 .. " overlapping pairs")

        -- And they must be shortened rather than merely drawn on top of one
        -- another somewhere off the row.
        local anyShortened = false
        for _, row in ipairs(rows or {}) do
            if row:IsShown() and row.label:GetText() ~= LONG_LABEL then
                anyShortened = true
            end
        end
        check("an over-long label is shortened to fit", anyShortened)

        NS.UI.MainWindow:RefreshCurrentPage()
    end

    -- Back to a normal size for the rest of the suite.
    NS.UI.MainWindow.frame:SetSize(1180, 720)
    for _, key in ipairs(NS.UI.pageOrder) do NS.UI.MainWindow:LayoutPage(key) end
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
