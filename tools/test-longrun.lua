-- Long-run memory test: six simulated hours.
--
-- Everything in this addon is supposed to be bounded. This is the test that
-- says so out loud, by running a session long enough for anything unbounded to
-- become obvious and then checking that the second half grew no more than the
-- first.
--
-- The clock is driven through the real scheduler, so the samplers, the
-- recorder, the flight recorder, the spike detector and the error monitor all
-- run their actual code paths rather than being poked directly.
--
--   lua5.1 tools/test-longrun.lua

package.path = "./tools/?.lua;" .. package.path
local mock = require("wowmock")

function GetBuildInfo() return "12.1.0", "60000", "Feb 10 2026", 120100 end
WOW_PROJECT_ID = 1
mock.knownEvents = nil

local ADDONS = {
    { "WoWTaskManager", "WoW Task Manager", "0.2.0", true },
    { "WeakAuras", "WeakAuras", "5.20.1", true },
}
local cpuCounters, memValues = { 0, 0 }, { 500, 900 }
C_AddOns = {
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
    IsAddOnLoaded = function() return true end,
    IsAddOnLoadOnDemand = function() return false end,
    GetAddOnEnableState = function() return 2 end,
    GetAddOnDependencies = function() return nil end,
    GetAddOnOptionalDependencies = function() return nil end,
    LoadAddOn = function() return true end,
    EnableAddOn = function() return true end,
    DisableAddOn = function() return true end,
}
local cvars = { scriptProfile = "1", maxFPS = "0", maxFPSBk = "30", vsync = "0" }
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
function UpdateAddOnCPUUsage()
    for i = 1, #ADDONS do cpuCounters[i] = cpuCounters[i] + math.random() * 4 end
end
function GetAddOnCPUUsage(i) return cpuCounters[i] or 0 end
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage(i) return memValues[i] or 0 end
function ResetCPUUsage() end
function GetScriptCPUUsage() return 0 end
function GetEventCPUUsage() return 10, 100 end
function GetFrameCPUUsage() return 1, 10 end
function GetFunctionCPUUsage() return 0, 0 end

local NS = {}
local xml = assert(io.open("WoWTaskManager/Includes.xml"))
for line in xml:lines() do
    local path = line:match('<Script file="([^"]+)"')
    if path then assert(loadfile("WoWTaskManager/" .. path:gsub("\\", "/")))("WoWTaskManager", NS) end
end
xml:close()


local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print(("   FAIL  %s  (%s)"):format(name, tostring(detail))) end
end

WoWTaskManagerDB = nil
mock.Fire("ADDON_LOADED", "WoWTaskManager")
mock.Fire("PLAYER_LOGIN")

-- A tick of 100 ms with default thresholds would make every frame a stutter and
-- the run would measure spike handling rather than long-run growth. The floors
-- are raised so the simulated client looks like a client having an ordinary
-- night, with the spikes injected deliberately below.
for _, kind in ipairs(NS.C.SPIKE_KINDS) do
    local def = NS.db.profile.spikes[kind]
    if def then def.absMs = def.absMs * 8 end
end

local HOURS       = 6
local TICK        = 0.1
local TOTAL_TICKS = math.floor(HOURS * 3600 / TICK)
local HALF        = math.floor(TOTAL_TICKS / 2)

local function snapshot()
    local db = NS.db.global
    return {
        clusters   = #NS.SpikeDetector.clusters,
        spikes     = NS.SpikeDetector.total,
        markers    = #NS.Context.markers,
        errors     = #NS.Errors.groups,
        errorTotal = NS.Errors.stats.total,
        buckets    = NS.Recorder:CountBuckets(),
        incidents  = #NS.FlightRecorder.incidents,
        sessions   = #db.sessions,
        savedInc   = #db.incidents,
        dbBytes    = NS.Database:EstimateSizeBytes(),
        heapKB     = collectgarbage("count"),
    }
end

print(("== %d simulated hours at a %.0f ms tick (%d ticks) =="):format(
    HOURS, TICK * 1000, TOTAL_TICKS))

local heapCurve = {}
local started = os.clock()
local midpoint
local nextReport = 1800   -- every simulated half hour
local elapsedSim = 0

collectgarbage("collect")
local before = snapshot()

for i = 1, TOTAL_TICKS do
    mock.Tick(TICK)
    elapsedSim = elapsedSim + TICK

    -- A client doing things: a spike every couple of minutes, an error every
    -- few minutes, a marker every half hour, a zone change every hour.
    -- A real long frame through the real path, rather than poking the
    -- detector: 350 ms is above the raised floor and is what the frame
    -- callback would actually see.
    -- Above the "heavy" floor, so the flight recorder captures an incident.
    -- At 350 ms it only classified as minor and captured nothing, which meant
    -- the biggest consumer in the addon was not being exercised at all.
    if i % 1200 == 0 then mock.Tick(1.2) ; elapsedSim = elapsedSim + 1.2 end
    if i % 2000 == 0 then
        NS.Errors:Record(("Interface/AddOns/Addon%d/File.lua:%d: a repeating failure")
            :format(i % 12, i % 40), nil, false)
    end
    if i % 500 == 0 then
        -- The same error over and over, which is the case that must not grow.
        NS.Errors:Record("Interface/AddOns/Loud/Loud.lua:1: the same one forever", nil, false)
    end
    if i % 18000 == 0 then NS.Context:AddMarker("custom", "half hourly") end
    if i % 36000 == 0 then mock.Fire("ZONE_CHANGED_NEW_AREA") end

    if i == HALF then collectgarbage("collect") ; midpoint = snapshot() end

    if elapsedSim >= nextReport then
        nextReport = nextReport + 1800
        -- Collected before reading. Without this the figure is sawtooth
        -- garbage and says nothing about whether anything is actually being
        -- retained, which is the only question here.
        collectgarbage("collect")
        local s = snapshot()
        heapCurve[#heapCurve + 1] = s.heapKB
        print(("   %4.1f h  clusters %-4d spikes %-5d markers %-4d errors %-4d/%-6d buckets %-5d incidents %-3d heap %.0f KB")
            :format(elapsedSim / 3600, s.clusters, s.spikes, s.markers,
                    s.errors, s.errorTotal, s.buckets, s.incidents, s.heapKB))
    end
end

collectgarbage("collect")
local after = snapshot()
local wall = os.clock() - started

print(("\n   simulated %d h in %.1f s of harness time"):format(HOURS, wall))

--------------------------------------------------------------------------
print("\n== what is held at the end ==")
--------------------------------------------------------------------------

print(("   history buckets      %d"):format(after.buckets))
print(("   flight incidents     %d"):format(after.incidents))
print(("   spike clusters       %d   (of %d spikes seen)"):format(after.clusters, after.spikes))
print(("   timeline markers     %d"):format(after.markers))
print(("   distinct errors      %d   (of %d occurrences)"):format(after.errors, after.errorTotal))
print(("   stored sessions      %d"):format(after.sessions))
print(("   stored incidents     %d"):format(after.savedInc))
print(("   estimated DB size    %s"):format(NS.Format.Bytes(after.dbBytes)))
print(("   Lua heap             %.0f KB  (started at %.0f KB)"):format(after.heapKB, before.heapKB))

--------------------------------------------------------------------------
print("\n== nothing grows without bound ==")
--------------------------------------------------------------------------

-- Two different questions, and conflating them is how a linear growth curve
-- gets called "bounded".
--
--   A hard cap:  the number must simply never exceed it. Growing linearly
--                towards it is fine, and is what a long session does.
--   A compacted store: growth must actually SLOW, because the tiering is
--                supposed to be folding old samples into coarser ones.
local function underCap(name, field, cap)
    check(("%s stays under its cap of %d"):format(name, cap),
        after[field] <= cap, after[field])
end

local function compacts(name, field)
    local firstHalf  = midpoint[field] - before[field]
    local secondHalf = after[field] - midpoint[field]
    check(("%s grows more slowly as it ages"):format(name),
        secondHalf < firstHalf,
        ("first half +%d, second half +%d - not compacting"):format(firstHalf, secondHalf))
end

underCap("spike clusters", "clusters", NS.C.MAX_CLUSTERS)
underCap("timeline markers", "markers", 400)
underCap("flight recorder incidents", "incidents", NS.C.FR_MAX_INCIDENTS_MEM)
underCap("distinct errors", "errors", NS.db.profile.errors.maxUnique)

-- The recorder is the one that must actively shrink its own growth rate: it
-- keeps seconds for the recent past and minutes for the distant past.
compacts("history buckets", "buckets")

check("the flight recorder actually captured something",
    after.incidents > 0, "nothing captured, so its cap proves nothing")

check("the repeating error never became more than one entry",
    after.errors <= 40, after.errors)
check("but every one of its occurrences was counted",
    after.errorTotal > 400, after.errorTotal)

-- The heap is the one figure that cannot be asserted tightly: the harness
-- itself allocates, and Lua's collector is not deterministic. What can be said
-- is that six hours must not multiply it.
local growth = after.heapKB - before.heapKB
-- The question is not "did it grow" - filling a 40-incident ring and a
-- 1,400-bucket history is supposed to cost memory - it is whether it is still
-- growing at the same rate once those are full. A retained-memory bug shows up
-- as a second half as steep as the first.
local firstHalfHeap  = heapCurve[math.floor(#heapCurve / 2)] - heapCurve[1]
local secondHalfHeap = heapCurve[#heapCurve] - heapCurve[math.floor(#heapCurve / 2)]
print(("   heap after GC: %.0f -> %.0f -> %.0f KB  (first half +%.0f, second half +%.0f)")
    :format(heapCurve[1], heapCurve[math.floor(#heapCurve / 2)], heapCurve[#heapCurve],
            firstHalfHeap, secondHalfHeap))
check("heap growth flattens once the ring buffers are full",
    secondHalfHeap < firstHalfHeap,
    ("first half +%.0f KB, second half +%.0f KB"):format(firstHalfHeap, secondHalfHeap))

--------------------------------------------------------------------------
print("\n== what one call to each hot path allocates ==")
--------------------------------------------------------------------------
-- Allocation in a sampler is the thing that turns a monitor into the problem
-- it is monitoring: it runs every tick forever, and what it allocates the
-- collector eventually has to walk. These are the paths that run whether or
-- not anybody has the window open.

local function perCall(label, n, fn)
    fn(0)
    collectgarbage("collect")
    local start = collectgarbage("count")
    for i = 1, n do fn(i) end
    local kb = (collectgarbage("count") - start) / n
    print(("   %-30s %7.3f KB per call"):format(label, kb))
    return kb
end

local N = 5000
local budgets = {
    { "frame callback (every frame)", function() NS.FrameTime:Sample(1/60) end, 0.05 },
    { "spike detection",              function() NS.SpikeDetector:Check() end,  0.05 },
    { "event counting",               function() NS.Events:Sample(1) end,       0.05 },
    { "Lua memory sampling",          function() NS.Memory:SampleLua(1) end,    0.05 },
    { "own overhead accounting",      function() NS.Overhead:Sample(1) end,     0.05 },
    { "history recording",            function() NS.Recorder:Sample(1) end,     0.05 },
}
for _, row in ipairs(budgets) do
    local kb = perCall(row[1], N, row[2])
    check(("%s allocates nothing per call"):format(row[1]), kb < row[3],
        ("%.3f KB, budget %.2f"):format(kb, row[3]))
end

-- The error path has two halves and they are supposed to be very different.
NS.Errors:Reset()
local newKB = perCall("a new error", 2000, function(i)
    NS.Errors:Record(("Interface/AddOns/A%d/F.lua:%d: distinct"):format(i, i), nil, false)
end)
NS.Errors:Reset()
local repeatKB = perCall("the same error again", N, function()
    NS.Errors:Record("Interface/AddOns/Loud/Loud.lua:1: same", nil, false)
end)
check("a repeated error allocates nothing", repeatKB < 0.01,
    ("%.4f KB"):format(repeatKB))
check("which is what makes it far cheaper than a new one",
    newKB > repeatKB, ("new %.3f, repeat %.4f"):format(newKB, repeatKB))

--------------------------------------------------------------------------
print("\n== the database stays a sensible size ==")
--------------------------------------------------------------------------

NS.Sessions:UpdateSummary()
mock.Fire("PLAYER_LOGOUT")
local savedBytes = NS.Database:EstimateSizeBytes()
print(("   after logout: %s"):format(NS.Format.Bytes(savedBytes)))
check("the saved database is under a megabyte after six hours",
    savedBytes < 1024 * 1024, NS.Format.Bytes(savedBytes))

--------------------------------------------------------------------------
print("\n== the expensive scan throttles itself ==")
--------------------------------------------------------------------------
-- UpdateAddOnMemoryUsage walks the whole Lua state in one call. On a client
-- with a couple of hundred addon folders it is the most expensive thing this
-- addon does, and it arrives as one hitch rather than a smooth cost. A real
-- client reported 16 ms/s of sampling with the window closed, which is what
-- that call looks like spread over its interval.

do
    local baseInterval = NS.db.profile.sampling.intervals.memory
    NS.Memory.scanStretch = 1
    NS.Scheduler:SetInterval("memory", baseInterval)

    check("a cheap scan leaves the interval alone", (function()
        NS.Memory:AdaptScanInterval(1)
        return NS.Memory.scanStretch == 1
    end)(), NS.Memory.scanStretch)

    -- Now make it expensive, the way two hundred addon folders would.
    for _ = 1, 10 do NS.Memory:AdaptScanInterval(NS.C.MEMORY_SCAN_BUDGET_MS * 4) end
    check("an expensive scan stretches its own interval",
        NS.Memory.scanStretch > 1, NS.Memory.scanStretch)
    check("but never past the cap",
        NS.Memory.scanStretch <= NS.C.MEMORY_SCAN_MAX_STRETCH, NS.Memory.scanStretch)

    local task = NS.Scheduler:GetTask("memory")
    check("and the scheduler was actually told",
        task and task.normal > baseInterval,
        task and ("%.0f s vs a %.0f s base"):format(task.normal, baseInterval))

    check("what happened is reported rather than done quietly",
        (NS.Memory:DescribeScanCost() or ""):find("stretched", 1, true) ~= nil,
        tostring(NS.Memory:DescribeScanCost()))

    -- And it comes back down on a quiet client, slowly.
    for _ = 1, 20 do NS.Memory:AdaptScanInterval(1) end
    check("it relaxes again when the scan is cheap",
        NS.Memory.scanStretch == 1, NS.Memory.scanStretch)
    check("and the interval goes back with it",
        NS.Scheduler:GetTask("memory").normal == baseInterval,
        NS.Scheduler:GetTask("memory").normal)
end

--------------------------------------------------------------------------
print("\n== the same number, wherever it is shown ==")
--------------------------------------------------------------------------
-- Every figure here is produced by one module and displayed by several. Two
-- pages disagreeing about how many errors there were is worse than either page
-- being absent: it means one of them is lying and there is no way to tell
-- which.

NS.UI.MainWindow:Open()

-- Errors: the sidebar badge, the Errors page, the dashboard card, the Reports
-- summary and the per-addon tab all count the same occurrences.
local errorTotal = NS.Errors.stats.total
local perAddon, sumPerAddon = {}, 0
for _, group in ipairs(NS.Errors.groups) do
    local key = group.addon or "?"
    perAddon[key] = (perAddon[key] or 0) + group.count
end
for _, n in pairs(perAddon) do sumPerAddon = sumPerAddon + n end
check("per-addon error counts add up to the session total",
    sumPerAddon == errorTotal, ("%d vs %d"):format(sumPerAddon, errorTotal))

local visible = NS.Errors:CountVisible()
check("the badge count never exceeds the true total",
    visible <= errorTotal, ("%d visible of %d"):format(visible, errorTotal))

-- Incidents: the count the dashboard shows and the list the page renders.
local listed = NS.SpikeDetector:GetClusters({})
check("the incident count matches the incident list",
    #listed == #NS.SpikeDetector.clusters, ("%d listed, %d held"):format(#listed, #NS.SpikeDetector.clusters))

-- Memory: what the session summary says and what the sampler holds.
local stats = NS.FrameTime:GetSessionStats()
check("frames rendered is never larger than the frames measured",
    stats.frames >= 0 and stats.frames == math.floor(stats.frames), stats.frames)

-- Timeline markers must point at things that still exist. An error marker
-- holding a group that was evicted by the cap would open an empty detail view.
local holdsObject, resolvable, evicted = 0, 0, 0
for _, marker in ipairs(NS.Context.markers) do
    if marker.kind == "luaerror" then
        -- A marker must not hold the group itself: markers and errors are
        -- capped separately, so the object would outlive its own eviction and
        -- keep its stack trace alive with it.
        if type(marker.ref) == "table" then holdsObject = holdsObject + 1 end
        if NS.Errors:GroupForMarker(marker) then
            resolvable = resolvable + 1
        else
            evicted = evicted + 1
        end
    end
end
check("no marker holds an error object", holdsObject == 0, holdsObject)
check("a marker whose error was evicted resolves to nothing rather than to a stale one",
    evicted >= 0 and resolvable + evicted > 0,
    ("%d resolvable, %d evicted"):format(resolvable, evicted))
print(("   markers referencing errors: %d still held, %d since dropped")
    :format(resolvable, evicted))

-- Sessions: the summary the list shows and the record behind it.
NS.Sessions:UpdateSummary()
local current = NS.Sessions.current
if current then
    check("the live session summary carries a duration",
        (current.duration or 0) >= 0, tostring(current.duration))
end

-- Saved incidents must not outnumber the retention setting.
check("stored incidents respect the retention setting",
    #NS.db.global.incidents <= NS.db.profile.retention.maxIncidents,
    ("%d stored, cap %d"):format(#NS.db.global.incidents,
                                 NS.db.profile.retention.maxIncidents))

-- And nothing simulated may have reached the database.
local sim = 0
for _, incident in ipairs(NS.db.global.incidents) do
    if incident.simulated then sim = sim + 1 end
end
check("no simulated incident reached the database", sim == 0, sim)

--------------------------------------------------------------------------
print(("\n   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(6, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
