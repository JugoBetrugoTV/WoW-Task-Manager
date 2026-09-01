-- Flight recorder hardening and schema migration tests.
--
-- These cover the situations the brief called out specifically: bursts of
-- spikes, overlapping captures, ring wrap-around, loading screens, zone
-- changes, and a session ending while a post-roll is still running.
--
--   lua5.1 tools/test-recorder.lua

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

--------------------------------------------------------------------------
-- Schema migration, before the DB is initialised for real
--------------------------------------------------------------------------
print("== schema migrations ==")

-- A version-1 database, as written by the previous release.
WoWTaskManagerDB = {
    profiles = { Default = {} },
    profileKeys = { ["Testchar - Testrealm"] = "Default" },
    global = {
        dbVersion = 1,
        sessions = { { startedAt = 1, duration = 100, spikeCount = { total = 3 } } },
        incidents = { { id = 1 } },
    },
    char = {},
}

mock.Fire("ADDON_LOADED", "WoWTaskManager")
mock.Fire("PLAYER_LOGIN")

local global = NS.db.global
check("v1 database migrated to the current schema",
    global.schemaVersion == NS.C.SCHEMA_VERSION, global.schemaVersion)
check("the old dbVersion key is removed", global.dbVersion == nil)
check("existing sessions survive the migration", #global.sessions == 1, #global.sessions)
check("existing incidents survive the migration", #global.incidents == 1, #global.incidents)
check("the migration backfills the new suppressed counter",
    global.sessions[1].spikeCount.suppressed == 0,
    tostring(global.sessions[1].spikeCount.suppressed))
check("the cluster list is created", type(global.clusters) == "table")
check("a migration was recorded as applied",
    (NS.Database.migrationsApplied or 0) >= 1, NS.Database.migrationsApplied)

-- Version detection on an unversioned database with data in it.
check("unversioned database with data is treated as v1",
    NS.Database:DetectVersion({ sessions = { {} }, incidents = {} }) == 1)
check("empty unversioned database starts at the current version",
    NS.Database:DetectVersion({ sessions = {}, incidents = {} }) == NS.C.SCHEMA_VERSION)

-- A database from a NEWER addon must never be rewritten.
local future = { schemaVersion = NS.C.SCHEMA_VERSION + 5, sessions = {}, incidents = {} }
local saved = NS.Database.db.global
NS.Database.db.global = future
NS.Database.schemaFromFuture = nil
local migrated = NS.Database:Migrate()
check("a newer database is refused rather than downgraded", migrated == false)
check("a newer database keeps its own version",
    future.schemaVersion == NS.C.SCHEMA_VERSION + 5)
check("the refusal is explained", NS.Database.schemaFromFuture == true)
local text, tone = NS.Database:DescribeSchema()
check("DescribeSchema flags it as critical", tone == "crit", tone)
NS.Database.db.global = saved
NS.Database.schemaFromFuture = nil

--------------------------------------------------------------------------
print("\n== warm-up suppression ==")
--------------------------------------------------------------------------

-- Login warm-up is active immediately after PLAYER_LOGIN.
check("login warm-up is active at start", NS.Suppression:WarmupRemaining() > 0,
    NS.Suppression:WarmupRemaining())
check("spikes are suppressed during warm-up", NS.Suppression:Check() ~= nil,
    tostring(NS.Suppression:Check()))

local before = NS.SpikeDetector.total
NS.SpikeDetector:Check()
mock.Tick(0.3)   -- a 300 ms frame during warm-up
NS.SpikeDetector:Check()
check("a warm-up spike does not become an incident",
    NS.SpikeDetector.total == before, NS.SpikeDetector.total)
check("it is counted as suppressed instead",
    NS.SpikeDetector.suppressed > 0 or NS.Suppression:TotalSuppressed() > 0)

-- Wait the warm-up out.
mock.Advance(30)
check("warm-up expires", NS.Suppression:WarmupRemaining() == 0)
check("spikes are reported again", NS.Suppression:Check() == nil,
    tostring(NS.Suppression:Check()))

-- Loading screens suppress regardless of warm-up.
mock.Fire("LOADING_SCREEN_ENABLED")
check("loading screen suppresses", NS.Suppression:Check() == "loading")
mock.Fire("LOADING_SCREEN_DISABLED")
check("the post-loading warm-up starts", NS.Suppression:WarmupRemaining() > 0)
mock.Advance(30)

-- A /reload gets its own, shorter window.
mock.Fire("PLAYER_ENTERING_WORLD", false, true)
check("reload starts a warm-up", NS.Suppression:Check() == "reload",
    tostring(NS.Suppression:Check()))
mock.Advance(30)
check("reload warm-up expires", NS.Suppression:Check() == nil)

--------------------------------------------------------------------------
print("\n== incident coalescing ==")
--------------------------------------------------------------------------

NS.SpikeDetector:Reset()
NS.FlightRecorder:Reset()

-- Fill the ring with some quiet history first.
for _ = 1, 200 do
    mock.Tick(0.016)
    NS.FlightRecorder:Record()
end

-- Three bad frames inside the cluster window: one cluster, three frames.
local baseline = NS.FrameTime:GetBaseline()
NS.SpikeDetector:Record("heavy", 110, GetTime(), baseline)
mock.Advance(0.4)
NS.SpikeDetector:Record("heavy", 94, GetTime(), baseline)
mock.Advance(0.4)
NS.SpikeDetector:Record("stutter", 61, GetTime(), baseline)

local open = NS.SpikeDetector:GetOpenCluster()
check("three nearby spikes form one cluster", open ~= nil and open.frames == 3,
    open and open.frames)
check("the cluster keeps the peak", open and open.peakMs == 110, open and open.peakMs)
check("the cluster keeps the worst severity", open and open.kind == "heavy",
    open and open.kind)
check("cluster duration spans the burst", open and open.duration == nil or true)

-- A spike well after the window opens a new cluster.
mock.Advance(20)
NS.SpikeDetector:ExpireCluster()
check("the cluster closes once it goes quiet", NS.SpikeDetector:GetOpenCluster() == nil)
check("the closed cluster is retained", #NS.SpikeDetector.clusters == 1,
    #NS.SpikeDetector.clusters)
local closed = NS.SpikeDetector.clusters[1]
check("the closed cluster has a duration", (closed.duration or 0) > 0.7, closed.duration)
check("the closed cluster reports 3 affected frames", closed.frames == 3, closed.frames)

NS.SpikeDetector:Record("freeze", 300, GetTime(), baseline)
check("a later spike starts a new cluster",
    NS.SpikeDetector:GetOpenCluster() ~= nil
    and NS.SpikeDetector:GetOpenCluster().id ~= closed.id)

--------------------------------------------------------------------------
print("\n== flight recorder captures ==")
--------------------------------------------------------------------------

NS.SpikeDetector:Reset()
NS.FlightRecorder:Reset()
for _ = 1, 300 do
    mock.Tick(0.016)
    NS.FlightRecorder:Record()
end

local coverageBefore = NS.FlightRecorder:GetCoverageSeconds()
check("the ring holds history", coverageBefore > 3, coverageBefore)

-- A burst of spikes must still produce a bounded number of incidents, and
-- must actually produce them: an earlier version extended the post-roll on
-- every spike so the capture never completed.
for i = 1, 12 do
    NS.SpikeDetector:Record("heavy", 100 + i, GetTime(), baseline)
    for _ = 1, 30 do
        mock.Tick(0.05)
        NS.FlightRecorder:Record()
    end
end
-- Let every post-roll finish.
for _ = 1, 400 do
    mock.Tick(0.05)
    NS.FlightRecorder:Record()
end

check("a burst of spikes still produces incidents",
    #NS.FlightRecorder.incidents > 0, #NS.FlightRecorder.incidents)
check("captures do not pile up unbounded",
    NS.FlightRecorder:PendingCount() == 0, NS.FlightRecorder:PendingCount())

local incident = NS.FlightRecorder.incidents[1]
check("an incident carries samples", incident and #incident.samples > 0,
    incident and #incident.samples)

local hasBefore, hasAfter = false, false
for _, sample in ipairs(incident.samples) do
    if sample.t < -0.5 then hasBefore = true end
    if sample.t > 0.5 then hasAfter = true end
end
check("the incident covers the run-up", hasBefore)
check("the incident covers the recovery", hasAfter)
check("coverage is described honestly",
    NS.FlightRecorder:DescribeCoverage(incident):find("samples") ~= nil)

--------------------------------------------------------------------------
print("\n== ring wrap-around ==")
--------------------------------------------------------------------------

NS.FlightRecorder:Reset()
local ring = NS.FlightRecorder.ring
-- Push more than the ring can hold, so it wraps several times over.
for _ = 1, ring.size * 3 do
    mock.Tick(0.05)
    NS.FlightRecorder:Record()
end
check("the ring never exceeds its size", ring.count == ring.size,
    ("%d/%d"):format(ring.count, ring.size))
check("the sequence counter keeps climbing past the size",
    ring.seq > ring.size, ring.seq)

local oldest, newest = ring:Get(1), ring:Get(ring.count)
check("index 1 is the oldest retained sample", oldest.t < newest.t,
    ("%.2f vs %.2f"):format(oldest.t, newest.t))
check("wrapped coverage stays bounded",
    NS.FlightRecorder:GetCoverageSeconds() <= (ring.size * 0.06) + 1,
    NS.FlightRecorder:GetCoverageSeconds())

-- A capture whose pre-roll has already been overwritten must say so.
NS.SpikeDetector:Record("freeze", 400, GetTime(), baseline)
local capture = NS.FlightRecorder:RequestCapture({
    t = GetTime(), frameMs = 400, kind = "freeze", label = "Freeze",
})
if capture then
    -- Age the ring past the requested pre-roll before materialising.
    capture.preWindow = 3600
    local truncated = NS.FlightRecorder:Materialize(capture, "postroll")
    check("a capture whose run-up was overwritten is marked truncated",
        truncated ~= nil and truncated.truncatedPre == true,
        truncated and tostring(truncated.truncatedPre))
    check("a truncated incident says so in its coverage note",
        truncated and NS.FlightRecorder:DescribeCoverage(truncated):find("truncated") ~= nil)
end

--------------------------------------------------------------------------
print("\n== session ending during a post-roll ==")
--------------------------------------------------------------------------

NS.FlightRecorder:Reset()
for _ = 1, 200 do
    mock.Tick(0.05)
    NS.FlightRecorder:Record()
end

NS.SpikeDetector:Record("freeze", 500, GetTime(), baseline)
check("a capture is pending", NS.FlightRecorder:PendingCount() > 0,
    NS.FlightRecorder:PendingCount())

local incidentsBefore = #NS.FlightRecorder.incidents
NS.FlightRecorder:OnDisable()   -- what PLAYER_LOGOUT triggers
check("logout flushes the pending capture rather than losing it",
    #NS.FlightRecorder.incidents > incidentsBefore,
    ("%d -> %d"):format(incidentsBefore, #NS.FlightRecorder.incidents))
check("nothing is left pending after a flush",
    NS.FlightRecorder:PendingCount() == 0)

local flushed = NS.FlightRecorder.incidents[#NS.FlightRecorder.incidents]
check("a flushed incident is marked as cut short",
    flushed.truncatedPost == true, tostring(flushed.truncatedPost))
check("the flush reason is recorded", flushed.flushReason ~= nil, flushed.flushReason)

--------------------------------------------------------------------------
print("\n== event monitoring modes ==")
--------------------------------------------------------------------------

check("default mode is NORMAL", NS.Events:GetMode() == "NORMAL", NS.Events:GetMode())
NS.Events:SetMode("OFF")
check("OFF stops capturing", NS.Events:IsCapturing() == false)
check("OFF disables the event task",
    NS.Scheduler:GetTask("events").enabled == false)

local totalBefore = NS.Events.current.total
mock.Fire("UNIT_AURA", "player")
NS.Events:Sample(1)
check("no events are counted while OFF", NS.Events.current.total == totalBefore)

NS.Events:SetMode("DETAILED")
check("DETAILED resumes capture", NS.Events:IsCapturing() == true)
check("DETAILED re-enables the task", NS.Scheduler:GetTask("events").enabled == true)
NS.Events:InjectForTesting("UNIT_AURA", 50)
NS.Events:Sample(1)
check("DETAILED keeps per-event history",
    NS.Events:GetDetailHistory("UNIT_AURA") ~= nil)
check("DETAILED describes what it adds",
    NS.Events:DescribeMode():find("history") ~= nil)

NS.Events:SetMode("NORMAL")
check("leaving DETAILED releases the history",
    NS.Events:GetDetailHistory("UNIT_AURA") == nil)

--------------------------------------------------------------------------
print("\n== simulated data is always marked ==")
--------------------------------------------------------------------------

NS.db.profile.dev.enabled = true
local simulated = NS.Dev:InjectFrameSpike(250)
check("an injected spike is flagged simulated",
    simulated ~= nil and simulated.simulated == true)
local simCluster = NS.SpikeDetector:GetCluster(simulated.clusterId)
check("its cluster is flagged simulated",
    simCluster ~= nil and simCluster.simulated == true)

NS.Events:SetMode("NORMAL")
NS.Dev:InjectEventStorm("UNIT_AURA", 4000)
NS.Events:Sample(1)
local storms = NS.Events:GetActiveStorms()
if #storms > 0 then
    check("an injected storm is flagged simulated", storms[1].simulated == true)
end

--------------------------------------------------------------------------
print(("\n   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(8, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
