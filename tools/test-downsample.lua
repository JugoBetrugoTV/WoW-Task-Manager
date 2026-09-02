-- Focused regression test for spike preservation under downsampling.
--
-- This exists because the first implementation got the direction backwards on
-- every series where the spike is the HIGH value, which silently deleted every
-- spike from exactly the graphs that are supposed to show them.
--
--   lua5.1 tools/test-downsample.lua

package.path = "./tools/?.lua;" .. package.path
local mock = require("wowmock")

function GetBuildInfo() return "12.1.0", "60000", "Feb 10 2026", 120100 end
WOW_PROJECT_ID = 1
mock.knownEvents = nil   -- accept every event
C_AddOns = {
    GetNumAddOns = function() return 0 end,
    GetAddOnInfo = function() return nil end,
    GetAddOnMetadata = function() return nil end,
    IsAddOnLoaded = function() return false end,
    IsAddOnLoadOnDemand = function() return false end,
    GetAddOnEnableState = function() return 2 end,
    GetAddOnDependencies = function() return nil end,
    GetAddOnOptionalDependencies = function() return nil end,
    LoadAddOn = function() return false end,
    EnableAddOn = function() return true end,
    DisableAddOn = function() return true end,
}
local cvars = { scriptProfile = "0", maxFPS = "0", maxFPSBk = "30", vsync = "0" }
C_CVar = {
    GetCVar = function(n) return cvars[n] end,
    SetCVar = function(n, v) cvars[n] = tostring(v) return true end,
    GetCVarBool = function(n) return cvars[n] == "1" end,
    GetCVarDefault = function(n) return cvars[n] end,
    GetCVarInfo = function(n) if cvars[n] == nil then return nil end return cvars[n], cvars[n], false, false, false, false, false end,
}
GetCVar, SetCVar = C_CVar.GetCVar, C_CVar.SetCVar
GetCVarBool, GetCVarDefault, GetCVarInfo = C_CVar.GetCVarBool, C_CVar.GetCVarDefault, C_CVar.GetCVarInfo
C_Timer = { After = function() end }
function UpdateAddOnCPUUsage() end
function GetAddOnCPUUsage() return 0 end
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage() return 0 end
function ResetCPUUsage() end
function GetScriptCPUUsage() return 0 end

local NS = {}
local xml = assert(io.open("WoWTaskManager/Includes.xml"))
for line in xml:lines() do
    local path = line:match('<Script file="([^"]+)"')
    if path then assert(loadfile("WoWTaskManager/" .. path:gsub("\\", "/")))("WoWTaskManager", NS) end
end
xml:close()
mock.Fire("ADDON_LOADED", "WoWTaskManager")
mock.Fire("PLAYER_LOGIN")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1 ; print(("   FAIL  %s  (%s)"):format(name, tostring(detail))) end
end

print("== downsampling: spikes must survive ==")

--------------------------------------------------------------------------
-- 1. The exact case from the brief: a bucket of 5 / 6 / 97 / 5 ms.
--------------------------------------------------------------------------
local graph = NS.UI.Graph(UIParent, { title = "frame time" })
-- The plot area is pinned to an exact size so the column count is known.
-- Its anchors are cleared first: the harness resolves real geometry from
-- anchors now, and anchors beat an explicitly set width, exactly as in the
-- client.  12 px => 4 columns at 3 px each.
graph:SetSize(60, 140)
graph.plot:ClearAllPoints()
graph.plot:SetSize(12, 100)

local frameMs, times = {}, {}
for i = 1, 16 do frameMs[i] = 5 + (i % 2) ; times[i] = i end
frameMs[11] = 97                            -- the spike
graph:SetSeries(1, frameMs, times, { label = "frame" })
graph:SetTimeRange(1, 16)
graph:Draw()

local rendered = graph.series[1].renderValues
local peak = 0
for i = 1, #rendered do if rendered[i] > peak then peak = rendered[i] end end
check("97 ms spike survives collapsing 16 samples into 4 columns", peak == 97, "peak rendered = " .. peak)
check("downsampling actually happened", #rendered < 16, "#rendered = " .. #rendered)

--------------------------------------------------------------------------
-- 2. FPS is the one series where the LOW value is the bad one.
--------------------------------------------------------------------------
local fpsGraph = NS.UI.Graph(UIParent, { title = "fps", worstIsLow = true })
fpsGraph.plot:ClearAllPoints()
fpsGraph.plot:SetSize(12, 100)
local fps = {}
for i = 1, 16 do fps[i] = 120 end
fps[11] = 9                                  -- the drop
fpsGraph:SetSeries(1, fps, times, { label = "fps" })
fpsGraph:SetTimeRange(1, 16)
fpsGraph:Draw()

local fpsRendered = fpsGraph.series[1].renderValues
local trough = math.huge
for i = 1, #fpsRendered do if fpsRendered[i] < trough then trough = fpsRendered[i] end end
check("9 fps drop survives downsampling", trough == 9, "trough rendered = " .. trough)

--------------------------------------------------------------------------
-- 3. The same rule through the history Recorder's own decimation.
--------------------------------------------------------------------------
local F = NS.Recorder.FIELDS
local tier = NS.Recorder.tiers[1]
local base = GetTime() - 500
for i = 1, 400 do
    local bucket = { base + i, 120, 8, 8, 20, 30, 1000, 50, 1 }
    bucket[F.frameMaxMs] = (i == 200) and 210 or 8
    bucket[F.fps]        = (i == 200) and 4 or 120
    tier.buckets[i] = bucket
end

local values = NS.Recorder:GetSeries("frameMaxMs", base, GetTime(), 40)
local seriesPeak = 0
for i = 1, #values do if values[i] > seriesPeak then seriesPeak = values[i] end end
check("Recorder keeps the frame time peak", seriesPeak == 210, seriesPeak)

local fpsValues = NS.Recorder:GetSeries("fps", base, GetTime(), 40)
local seriesTrough = math.huge
for i = 1, #fpsValues do if fpsValues[i] < seriesTrough then seriesTrough = fpsValues[i] end end
check("Recorder keeps the FPS trough", seriesTrough == 4, seriesTrough)

--------------------------------------------------------------------------
-- 4. End to end: Recorder decimation feeding graph decimation.
--------------------------------------------------------------------------
local chained = NS.UI.Graph(UIParent, { title = "chained" })
chained.plot:ClearAllPoints()
chained.plot:SetSize(30, 100)
local v2, t2 = NS.Recorder:GetSeries("frameMaxMs", base, GetTime(), 120)
chained:SetSeries(1, v2, t2, { label = "frame" })
chained:SetTimeRange(base, GetTime())
chained:Draw()
local chainedPeak = 0
for i = 1, #chained.series[1].renderValues do
    local v = chained.series[1].renderValues[i]
    if v > chainedPeak then chainedPeak = v end
end
check("peak survives two rounds of decimation", chainedPeak == 210, chainedPeak)

--------------------------------------------------------------------------
-- 5. Sparklines follow the same rule.
--------------------------------------------------------------------------
check("sparkline defaults to keeping the maximum",
    NS.UI.Sparkline(UIParent, 1).worstIsLow == false)
check("sparkline honours worstIsLow",
    NS.UI.Sparkline(UIParent, 1, true).worstIsLow == true)

--------------------------------------------------------------------------
-- 6. The wiring, which is where the bug actually was.
--
-- Constructing a graph by hand and checking it downsamples correctly proves
-- nothing if the pages pass the flag the wrong way round.  These assertions
-- walk the real pages and check each live graph against its own field.
--------------------------------------------------------------------------
-- Series whose BAD value is the low one. Everything else spikes upward, so
-- its column must keep the maximum. Anything FPS-shaped belongs here.
local FPS_SHAPED = { fps = true, low1 = true, low01 = true }

local function ExpectedWorstIsLow(fieldOrKey)
    return FPS_SHAPED[fieldOrKey] == true
end

NS.UI.MainWindow:Open("performance")
NS.UI.MainWindow:ShowPage("performance")
local perf = NS.UI.Pages.performance
for _, graph2 in ipairs(perf.graphs or {}) do
    local spec = graph2.spec
    check(("performance graph '%s' downsamples the right way"):format(spec.key),
        graph2.worstIsLow == ExpectedWorstIsLow(spec.field),
        ("field=%s worstIsLow=%s"):format(spec.field, tostring(graph2.worstIsLow)))
end

NS.UI.MainWindow:ShowPage("timeline")
local timeline = NS.UI.Pages.timeline
for _, track in ipairs(timeline.tracks or {}) do
    local spec = track.spec
    check(("timeline track '%s' downsamples the right way"):format(spec.key),
        track.worstIsLow == ExpectedWorstIsLow(spec.field),
        ("field=%s worstIsLow=%s"):format(spec.field, tostring(track.worstIsLow)))
end

NS.UI.MainWindow:ShowPage("dashboard")
local dash = NS.UI.Pages.dashboard
for key, card in pairs(dash.cards or {}) do
    check(("dashboard sparkline '%s' downsamples the right way"):format(key),
        card.spark.worstIsLow == ExpectedWorstIsLow(key),
        ("key=%s worstIsLow=%s"):format(key, tostring(card.spark.worstIsLow)))
end

for key, cell in pairs(NS.UI.MainWindow.frame.topMetrics or {}) do
    check(("topbar sparkline '%s' downsamples the right way"):format(key),
        cell.spark.worstIsLow == ExpectedWorstIsLow(key),
        ("key=%s worstIsLow=%s"):format(key, tostring(cell.spark.worstIsLow)))
end
NS.UI.MainWindow:Close()

print(("   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(5, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
