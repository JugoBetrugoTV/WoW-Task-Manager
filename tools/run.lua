-- Loads WoWTaskManager under the mock and drives a simulated session.
-- Usage:  lua5.1 tools/run.lua [flavorInterface]
--   e.g.  lua5.1 tools/run.lua 11509     (Classic Era)

package.path = "./tools/?.lua;" .. package.path
local mock = require("wowmock")

local INTERFACE = tonumber(arg and arg[1]) or 120100
local FLAVOR_NAMES = {
    [120100] = "Retail 12.1.0", [50504] = "MoP Classic 5.5.4",
    [20506] = "TBC 2.5.6", [11509] = "Classic Era 1.15.9",
}

--------------------------------------------------------------------------
-- Client-specific mock surface
--------------------------------------------------------------------------
function GetBuildInfo()
    local map = { [120100] = "12.1.0", [50504] = "5.5.4", [20506] = "2.5.6", [11509] = "1.15.9" }
    return map[INTERFACE] or "0.0.0", "60000", "Feb 10 2026", INTERFACE
end

WOW_PROJECT_ID = (INTERFACE >= 100000) and 1 or 2

-- Events this "client" knows about.  Classic and TBC deliberately lack the
-- encounter and challenge-mode events, so SafeRegisterEvent gets exercised.
local baseEvents = {
    "ADDON_LOADED","PLAYER_LOGIN","PLAYER_LOGOUT","PLAYER_ENTERING_WORLD",
    "PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","ZONE_CHANGED_NEW_AREA",
    "GROUP_ROSTER_UPDATE","COMBAT_LOG_EVENT_UNFILTERED","UNIT_AURA",
    "LOADING_SCREEN_ENABLED","LOADING_SCREEN_DISABLED",
}
mock.knownEvents = {}
for _, e in ipairs(baseEvents) do mock.knownEvents[e] = true end
if INTERFACE >= 50000 then
    mock.knownEvents.ENCOUNTER_START = true
    mock.knownEvents.ENCOUNTER_END = true
    mock.knownEvents.CHALLENGE_MODE_START = true
    mock.knownEvents.CHALLENGE_MODE_COMPLETED = true
end

--------------------------------------------------------------------------
-- Addon inventory
--------------------------------------------------------------------------
local ADDONS = {
    { "WoWTaskManager", "WoW Task Manager", "0.1.0", true },
    { "WeakAuras",      "WeakAuras",        "5.20.1", true },
    { "Details",        "|cFFFFAADDDetails!|r", "12.0.1", true },
    { "ElvUI",          "ElvUI",            "13.90", true },
    { "DBM-Core",       "Deadly Boss Mods", "11.0.2", true },
    { "Plater",         "Plater Nameplates","1.2.3", true },
    { "LibStub",        "LibStub",          "1.0.2", true },
    { "SomeLODAddon",   "Some LOD Addon",   "1.0",   false, true },
    { "DisabledAddon",  "Disabled Addon",   "0.9",   false, false, 0 },
}

local cpuCounters, memValues = {}, {}
for i, entry in ipairs(ADDONS) do
    cpuCounters[i] = 0
    memValues[i] = 200 + i * 350
end

local scriptProfile = (INTERFACE >= 50000) and "1" or "0"  -- exercise both paths
local cvars = {
    scriptProfile = scriptProfile, maxFPS = "0", maxFPSBk = "30",
    graphicsQuality = "5", uiScale = "0.71", useUiScale = "1", scriptErrors = "1",
}
if INTERFACE >= 100000 then
    cvars.targetFPS = "0" ; cvars.renderScale = "1.0" ; cvars.vsync = "0"
else
    cvars.gxVSync = "0"
end

local C_AddOnsTable = {
    GetNumAddOns = function() return #ADDONS end,
    GetAddOnInfo = function(i)
        local a = type(i) == "number" and ADDONS[i]
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        if not a then return nil end
        return a[1], a[2], "Notes for " .. a[1], true, nil, "INSECURE"
    end,
    GetAddOnMetadata = function(i, field)
        local a = type(i) == "number" and ADDONS[i]
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        if not a then return nil end
        if field == "Version" then return a[3] end
        if field == "Author" then return "Someone" end
        if field == "SavedVariables" and a[1] == "WeakAuras" then return "WeakAurasSaved" end
        return nil
    end,
    IsAddOnLoaded = function(i)
        local a = type(i) == "number" and ADDONS[i]
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        return a and a[4] or false
    end,
    IsAddOnLoadOnDemand = function(i)
        local a = type(i) == "number" and ADDONS[i]
        return a and a[5] or false
    end,
    GetAddOnEnableState = function(first, second)
        -- Modern order: (nameOrIndex, character).  Reject the legacy order so
        -- the compat layer's probing is genuinely exercised on retail.
        if INTERFACE >= 100000 then
            if type(first) == "string" and second == nil then return 2 end
            if type(first) == "number" or type(first) == "string" then
                local a = type(first) == "number" and ADDONS[first]
                return (a and a[6]) or 2
            end
            return nil
        else
            -- Legacy order: (character, index)
            if type(second) == "number" then
                local a = ADDONS[second]
                return (a and a[6]) or 2
            end
            return nil
        end
    end,
    GetAddOnDependencies = function(i)
        local a = type(i) == "number" and ADDONS[i]
        if a and a[1] == "WeakAuras" then return "LibStub" end
        if a and a[1] == "ElvUI" then return "LibStub" end
        return nil
    end,
    GetAddOnOptionalDependencies = function() return nil end,
    LoadAddOn = function(name)
        for _, e in ipairs(ADDONS) do if e[1] == name then e[4] = true return true end end
        return false, "MISSING"
    end,
    EnableAddOn = function(name) return true end,
    DisableAddOn = function(name) return true end,
}

if INTERFACE >= 100000 then
    C_AddOns = C_AddOnsTable          -- retail: namespaced only
else
    for k, v in pairs(C_AddOnsTable) do _G[k] = v end   -- classic: globals
end

-- Profiling APIs are globals on every current client.
-- Set by the simulator whenever it injects a frame spike, so one addon's CPU
-- genuinely correlates with the hitches and the correlation path is exercised
-- rather than just being reachable.
local CULPRIT_INDEX
for i, e in ipairs(ADDONS) do if e[1] == "WeakAuras" then CULPRIT_INDEX = i end end

function BurstCulprit(ms)
    if cvars.scriptProfile == "1" then
        cpuCounters[CULPRIT_INDEX] = cpuCounters[CULPRIT_INDEX] + ms
    end
end

function UpdateAddOnCPUUsage()
    for i = 1, #ADDONS do
        if ADDONS[i][4] and cvars.scriptProfile == "1" then
            local isCulprit = (i == CULPRIT_INDEX)
            cpuCounters[i] = cpuCounters[i] + math.random() * 8 * (isCulprit and 3 or 1)
        end
    end
end
function GetAddOnCPUUsage(i) return cpuCounters[i] or 0 end
function UpdateAddOnMemoryUsage()
    for i = 1, #ADDONS do
        if ADDONS[i][4] then
            local drift = (ADDONS[i][1] == "WeakAuras") and 900 or math.random() * 40
            memValues[i] = memValues[i] + drift
        end
    end
end
function GetAddOnMemoryUsage(i) return memValues[i] or 0 end
function ResetCPUUsage() for i = 1, #ADDONS do cpuCounters[i] = 0 end end
function GetScriptCPUUsage()
    local total = 0
    for i = 1, #ADDONS do total = total + cpuCounters[i] end
    return total
end
function GetEventCPUUsage(event) return 42.5, 1200 end
function GetFrameCPUUsage(frame, includeChildren) return 1.5, 300 end
function GetFunctionCPUUsage(fn) return 0.2, 10 end

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
GetCVar = C_CVar.GetCVar
SetCVar = C_CVar.SetCVar
GetCVarBool = C_CVar.GetCVarBool
GetCVarDefault = C_CVar.GetCVarDefault
GetCVarInfo = C_CVar.GetCVarInfo

C_Timer = { After = function(delay, fn) end }

--------------------------------------------------------------------------
-- Load the addon
--------------------------------------------------------------------------
local ADDON_NAME = "WoWTaskManager"
local NS = {}

local function LoadFileList()
    local files, xml = {}, io.open("WoWTaskManager/Includes.xml")
    assert(xml, "Includes.xml not found - run from the repository root")
    for line in xml:lines() do
        local path = line:match('<Script file="([^"]+)"')
        if path then files[#files + 1] = path:gsub("\\", "/") end
    end
    xml:close()
    return files
end

print(("== Loading WoWTaskManager for %s (interface %d) =="):format(
    FLAVOR_NAMES[INTERFACE] or "?", INTERFACE))

local files = LoadFileList()
for _, relative in ipairs(files) do
    local path = "WoWTaskManager/" .. relative
    local chunk, err = loadfile(path)
    if not chunk then
        print("  LOAD FAIL " .. path .. ": " .. tostring(err))
        os.exit(1)
    end
    local ok, runErr = pcall(chunk, ADDON_NAME, NS)
    if not ok then
        print("  RUN FAIL " .. path .. ": " .. tostring(runErr))
        os.exit(1)
    end
end
print(("  %d files loaded"):format(#files))

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------
mock.Fire("ADDON_LOADED", ADDON_NAME)
mock.Fire("PLAYER_LOGIN")
print(("  flavor detected: %s (%s)"):format(NS.Compat.flavor, NS.Compat.flavorName))
print(("  library backend: %s"):format(NS.Ace.Describe()))
print(("  CPU profiling:   %s%s"):format(tostring(NS.CPU.available),
    NS.CPU.available and "" or ("  (" .. tostring(NS.CPU.reason) .. ")")))
print(("  event capture:   %s"):format(tostring(NS.Events:IsCapturing())))
print(("  scheduler:       %s, %d tasks"):format(tostring(NS.Scheduler:IsRunning()),
    (function() local n = 0 for _ in NS.Scheduler:IterateTasks() do n = n + 1 end return n end)()))

--------------------------------------------------------------------------
-- Simulate a session
--------------------------------------------------------------------------
math.randomseed(1234)

local function SimulateSeconds(seconds, opts)
    opts = opts or {}
    local elapsedTotal = 0
    while elapsedTotal < seconds do
        local frameMs = 16.67 + (math.random() - 0.5) * 3
        -- Inject spikes
        local isSpike = opts.spikeEvery and math.random() < (1 / (opts.spikeEvery * 60))
        if isSpike then
            frameMs = opts.spikeMs or 120
            -- Charge the culprit's cumulative counter directly, the way the
            -- client would if that addon had really burned the time.
            BurstCulprit(90)
        end
        mock.Tick(frameMs / 1000)
        elapsedTotal = elapsedTotal + frameMs / 1000

        -- Fire some game events so the event monitor has something to count.
        if math.random() < 0.4 then mock.Fire("COMBAT_LOG_EVENT_UNFILTERED") end
        if math.random() < 0.2 then mock.Fire("UNIT_AURA", "player") end
    end
end

print("\n-- simulating 40 s of normal play --")
SimulateSeconds(40, { spikeEvery = 8, spikeMs = 140 })

print("-- entering combat --")
mock.inCombat = true
mock.Fire("PLAYER_REGEN_DISABLED")
SimulateSeconds(30, { spikeEvery = 4, spikeMs = 260 })

print("-- event storm --")
for i = 1, 3 do
    for _ = 1, 600 do mock.Fire("UNIT_AURA", "player") end
    SimulateSeconds(1.2)
end

print("-- leaving combat --")
mock.inCombat = false
mock.Fire("PLAYER_REGEN_ENABLED")
SimulateSeconds(25, { spikeEvery = 10, spikeMs = 90 })

--------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------
local stats = NS.FrameTime:GetSessionStats()
print(("\n  frames: %d   avg %.2f ms (%.1f fps)   1%% low %.1f fps   worst %.0f ms")
    :format(stats.frames, stats.avgMs, stats.avgFPS, stats.low1, stats.maxMs))
print(("  spikes: %d total (%d freeze, %d heavy, %d stutter, %d minor)")
    :format(NS.SpikeDetector.total, NS.SpikeDetector.counts.freeze,
            NS.SpikeDetector.counts.heavy, NS.SpikeDetector.counts.stutter,
            NS.SpikeDetector.counts.minor))
print(("  events: %.0f/s now, %d total, %d distinct, %d storms")
    :format(NS.Events.current.perSecond, NS.Events.current.total,
            NS.Events:GetDistinctCount(), #NS.Events.storms))
-- "observed heap decreases", not "collections": WoW reports no GC statistics,
-- and the field is called heapDrops precisely so this line cannot claim more
-- than was measured.
print(("  memory: %s lua, %s attributed, %d observed heap decreases")
    :format(NS.Format.Memory(NS.Memory.current.luaKB),
            NS.Format.Memory(NS.Memory.current.addonSumKB),
            NS.Memory.heapDrops.events))
print(("  recorder: %.0f s in the ring, %d history buckets, %d incidents")
    :format(NS.FlightRecorder:GetCoverageSeconds(), NS.Recorder:CountBuckets(),
            #NS.FlightRecorder.incidents))
print(("  overhead: %.3f ms/s (%.3f%% of a 60fps frame), throttle level %d")
    :format(NS.Overhead.current.samplingMsPerSec, NS.Overhead:GetFrameBudgetPercent(),
            NS.Scheduler.cost.throttleLevel))

--------------------------------------------------------------------------
-- Exercise the UI end to end
--------------------------------------------------------------------------
print("\n-- opening every page --")
NS.UI.MainWindow:Open("dashboard")
for _, key in ipairs(NS.UI.pageOrder) do
    NS.UI.MainWindow:ShowPage(key)
    NS.UI.MainWindow:Refresh()
    local page = NS.UI.Pages[key]
    print(("   %-12s built=%s  refreshErrors=%d")
        :format(key, tostring(page.frame ~= nil and not page.buildFailed),
                page.refreshErrors or 0))
end

--------------------------------------------------------------------------
-- Graph redraw pacing
--------------------------------------------------------------------------
-- The mock clock only advances when the harness advances it, so debugprofilestop
-- measures nothing here and a "ms/s" figure from this run would be fiction.
-- What CAN be counted is the thing the pacing work was about: how many graphs
-- redraw in a single refresh tick. That is a real number, and it is the number
-- that turned into 15 ms on a live client.
print("\n-- graph redraws per refresh tick --")
do
    local draws = 0
    local Graph = getmetatable(NS.UI.MainWindow.frame) and nil
    -- Count by wrapping Draw on every graph the pages built.
    local wrapped = 0
    for _, page in pairs(NS.UI.Pages) do
        for _, graph in ipairs(page.graphs or {}) do
            if not graph._countWrapped then
                local original = graph.Draw
                graph.Draw = function(self, ...) draws = draws + 1 return original(self, ...) end
                graph._countWrapped = true
                wrapped = wrapped + 1
            end
        end
    end

    NS.UI.MainWindow:ShowPage("performance")
    local perTick = {}
    for tick = 1, 6 do
        draws = 0
        -- A fresh tick's worth of data, then one refresh.
        NS.Recorder.revision = (NS.Recorder.revision or 0) + 1
        NS.UI.MainWindow.lastGraphDraw = nil
        NS.UI.MainWindow:Refresh()
        perTick[#perTick + 1] = draws
    end
    local worst, total = 0, 0
    for _, n in ipairs(perTick) do
        worst = math.max(worst, n)
        total = total + n
    end
    -- What one tick used to cost: every graph on the page, together. A forced
    -- full pass is exactly that, and it still happens on a page change - which
    -- is why it is worth knowing how much bigger it is.
    draws = 0
    NS.Recorder.revision = (NS.Recorder.revision or 0) + 1
    NS.UI.MainWindow.lastGraphDraw = nil
    NS.UI.MainWindow:InvalidateGraphs()
    NS.UI.MainWindow:Refresh()
    local fullPassDraws = draws

    print(("   %d graphs instrumented on the visible page"):format(wrapped))
    print(("   redraws per tick: %s"):format(table.concat(perTick, ", ")))
    print(("   worst paced tick: %d   average: %.1f"):format(worst, total / #perTick))
    print(("   full pass (page change / end of resize): %d"):format(fullPassDraws))
end

print("\n-- measured overhead breakdown --")
do
    for _, row in ipairs(NS.Overhead:GetBreakdown()) do
        print(("   %-26s %8s   %s"):format(row.label,
            row.measured and ("%.3f ms/s"):format(row.ms) or "not measured",
            row.note or ""))
    end
    local sum, total, delta = NS.Overhead:ReconcileBreakdown()
    print(("   %-26s %8.3f ms/s   categories sum to %.3f (difference %.3f)")
        :format("TOTAL MEASURED", total, sum, delta))
    print("   (the mock clock does not advance on its own, so these are structural, not timings)")
end

print("\n-- opening addon detail on every tab --")
local record = NS.Processes:Get("WeakAuras")
NS.UI.AddonDetail:Open(record)
for _, tab in ipairs({ "overview","cpu","memory","history","events","dependencies","diagnostics","metadata" }) do
    NS.UI.AddonDetail:ShowTab(tab)
end
NS.Processes:ScanFrames(true)
NS.UI.AddonDetail:ShowTab("events")
NS.UI.AddonDetail:Close()
print("   " .. NS.Processes:AttributionSummary())

print("\n-- correlation --")
do
    local correlations, samples, unavailable = NS.Correlation:Analyze()
    if unavailable then
        print("   " .. unavailable)
    else
        print(("   %d spike windows with CPU data"):format(samples))
        for i = 1, math.min(4, #correlations) do
            local e = correlations[i]
            print(("   %-16s phi %.2f  %-22s  %s")
                :format(e.name, e.phi, e.label, e.explanation))
        end
        if #correlations == 0 then print("   no addon was elevated during any spike") end
    end
end

print("\n-- diagnostics report --")
mock.verbose = true
NS.Diagnostics:PrintReport()
mock.verbose = false

print("\n-- slash commands --")
for _, cmd in ipairs({ "help", "caps", "overhead", "processes", "hide" }) do
    local ok, err = pcall(SlashCmdList.WTM_WTM or SlashCmdList["WTM_WTM"], cmd)
    if not ok then print("   FAIL /wtm " .. cmd .. ": " .. tostring(err)) end
end

print("\n-- logout --")
mock.Fire("PLAYER_LOGOUT")
print(("   sessions saved: %d"):format(#NS.db.global.sessions))
print(("   incidents saved: %d"):format(#NS.db.global.incidents))
print(("   database estimate: %s"):format(NS.Format.Bytes(NS.Database:EstimateSizeBytes())))

print(("\n== %d lua errors during the run =="):format(#mock.errors))
if #mock.errors > 0 then
    for i = 1, math.min(15, #mock.errors) do print("   " .. mock.errors[i]) end
    os.exit(1)
end
print("== OK ==")
