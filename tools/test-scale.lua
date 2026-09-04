-- Scale and emptiness.
--
-- Two failure modes that only appear at the ends of the range:
--
--   EMPTY   a widget reads a number that does not exist yet, at the first
--           second of a session, and throws instead of saying "no data".
--   LARGE   a list, a graph or a layout that is fine with five addons and
--           quadratic with two hundred.
--
-- Both are checked here rather than in the main suite, because both need a
-- world built specially: one with nothing in it, one with far too much.
--
--   lua5.1 tools/test-scale.lua

package.path = "./tools/?.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print(("   FAIL  %s%s"):format(name, detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local mock = require("wowmock")

local INTERFACE = 120100
function GetBuildInfo() return "12.1.0", "60000", "Feb 10 2026", INTERFACE end
WOW_PROJECT_ID = 1

mock.knownEvents = {}
for _, e in ipairs({ "ADDON_LOADED","PLAYER_LOGIN","PLAYER_LOGOUT","PLAYER_ENTERING_WORLD",
    "PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED","ZONE_CHANGED_NEW_AREA",
    "GROUP_ROSTER_UPDATE","COMBAT_LOG_EVENT_UNFILTERED","UNIT_AURA",
    "LOADING_SCREEN_ENABLED","LOADING_SCREEN_DISABLED","ENCOUNTER_START","ENCOUNTER_END" }) do
    mock.knownEvents[e] = true
end

--------------------------------------------------------------------------
-- A great many addons, several with names no layout was designed for
--------------------------------------------------------------------------

local ADDON_COUNT = 220
local ADDONS = { { "WoWTaskManager", "WoW Task Manager", "0.6.0", true } }

local LONG = "SuperExtendedRaidFrameEnhancementSuiteDeluxeEditionWithExtraLongTitle"
for i = 2, ADDON_COUNT do
    local name = ("Addon%03d"):format(i)
    local title = name
    -- Every tenth addon gets a name far longer than any column is wide, and
    -- every seventh gets colour escapes, because both exist in the wild.
    if i % 10 == 0 then title = LONG .. i end
    if i % 7 == 0 then title = "|cFFFFAADD" .. title .. "|r" end
    ADDONS[i] = { name, title, "1.0." .. i, i % 5 ~= 0 }
end

local cpuCounters, memValues = {}, {}
for i = 1, #ADDONS do cpuCounters[i] = 0 ; memValues[i] = 200 + i * 37 end

local cvars = { scriptProfile = "1", maxFPS = "0", maxFPSBk = "30", vsync = "0", renderScale = "1.0" }

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
        if a and f == "Author" then return "Author " .. a[1] end
        return nil
    end,
    IsAddOnLoaded = function(i)
        local a = type(i) == "number" and ADDONS[i]
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        return a and a[4] or false
    end,
    IsAddOnLoadOnDemand = function(i) return (i % 11) == 0 end,
    GetAddOnEnableState = function(first) return (first % 13 == 0) and 0 or 2 end,
    GetAddOnDependencies = function(i)
        if i and i % 6 == 0 then return "Addon002" end
        return nil
    end,
    GetAddOnOptionalDependencies = function() return nil end,
    LoadAddOn = function() return true end,
    EnableAddOn = function() return true end,
    DisableAddOn = function() return true end,
}
C_AddOns = api

function UpdateAddOnCPUUsage()
    for i = 1, #ADDONS do
        if ADDONS[i][4] then cpuCounters[i] = cpuCounters[i] + math.random() * 4 end
    end
end
function GetAddOnCPUUsage(i) return cpuCounters[i] or 0 end
function UpdateAddOnMemoryUsage()
    for i = 1, #ADDONS do
        if ADDONS[i][4] then memValues[i] = memValues[i] + (i % 17) end
    end
end
function GetAddOnMemoryUsage(i) return memValues[i] or 0 end
function ResetCPUUsage() for i = 1, #ADDONS do cpuCounters[i] = 0 end end
function GetScriptCPUUsage() local t = 0 for i = 1, #ADDONS do t = t + cpuCounters[i] end return t end
function GetEventCPUUsage() return 42.5, 1200 end
function GetFrameCPUUsage() return 1.5, 300 end

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
Settings = {
    RegisterCanvasLayoutCategory = function(_, name) return { ID = "c", name = name } end,
    RegisterAddOnCategory = function() end,
    OpenToCategory = function() return true end,
}

--------------------------------------------------------------------------
-- Load
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

print("== scale: an empty session, then a very large one ==")

--------------------------------------------------------------------------
-- 1. Completely empty: nothing sampled, nothing recorded
--------------------------------------------------------------------------
-- Everything on every page has to render before a single sample exists. This
-- is the very first second after login, and it is the state a new user sees.

mock.Fire("ADDON_LOADED", "WoWTaskManager")
mock.Fire("PLAYER_LOGIN")

do
    local before = #mock.errors
    NS.UI.MainWindow:Open()
    for _, key in ipairs(NS.UI.pageOrder) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:LayoutPage(key)
        NS.UI.MainWindow:RefreshCurrentPage()
    end
    check("every page renders with no data at all", #mock.errors == before,
        (#mock.errors - before) .. " errors")
    for i = before + 1, math.min(#mock.errors, before + 4) do
        print("      " .. mock.errors[i])
    end

    -- Rendering without throwing is the low bar. The one that matters to
    -- somebody who just installed this is whether the page SAYS anything: a
    -- panel full of dashes and a broken page look identical from the outside,
    -- and the difference is a sentence explaining that there is nothing to
    -- show yet and what would make something appear.
    local function isDescendant(ancestor, node)
        local n, guard = node, 0
        while n and guard < 64 do
            if n == ancestor then return true end
            n, guard = n._parent, guard + 1
        end
        return false
    end

    local silent = {}
    for _, key in ipairs(NS.UI.pageOrder) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:RefreshCurrentPage()
        local page = NS.UI.Pages[key]
        local sentences, contentful = 0, 0
        for _, region in ipairs(mock.allFrames) do
            if region._kind == "FontString" and region:IsVisible()
               and isDescendant(page.frame, region) then
                local text = NS.Format.StripColors(region._text or "")
                -- A number, a dash or a one-word heading explains nothing. A
                -- sentence does.
                if #text > 24 and text:find(" ") then sentences = sentences + 1 end
                if #text > 1 and text ~= "-" then contentful = contentful + 1 end
            end
        end
        -- Either explain, or show something. A table of addon names is not
        -- prose and does not need to be: it is already telling the reader what
        -- the page is for. What is not allowed is a panel that does neither.
        if sentences == 0 and contentful < 10 then silent[#silent + 1] = key end
    end
    check("no page is silent about having no data yet",
        #silent == 0, table.concat(silent, ", "))
end

--------------------------------------------------------------------------
-- 2. A large session
--------------------------------------------------------------------------

local FRAME_MS = { 8, 9, 8, 10, 8, 9, 12, 8, 9, 8 }
local function advance(seconds, frames)
    for i = 1, frames do
        local ms = FRAME_MS[(i % #FRAME_MS) + 1]
        -- One clearly bad frame every so often, so there is something to
        -- cluster and correlate.
        if i % 37 == 0 then ms = 120 + (i % 90) end
        mock.Tick(ms / 1000)
    end
    if seconds > 0 then mock.Advance(seconds) end
end

advance(0, 4000)

check("many addons are tracked", #NS.Processes.list == ADDON_COUNT, #NS.Processes.list)
check("frames were measured",
    NS.FrameTime:GetSessionStats().frames > 1000,
    NS.FrameTime:GetSessionStats().frames)
check("spikes were recorded", NS.SpikeDetector.total > 0, NS.SpikeDetector.total)

-- Force a large incident and marker history rather than waiting for one.
for i = 1, 140 do
    NS.SpikeDetector:Record("heavy", 150 + i, GetTime() - (140 - i), 10)
end
for i = 1, 200 do
    NS.Context:AddMarker("custom", ("marker %d"):format(i))
end
check("more than a hundred incidents are held", #NS.SpikeDetector.spikes > 100,
    #NS.SpikeDetector.spikes)
-- The list is a bounded ring, not an ever-growing table: a four-hour session
-- must not turn the spike history into the memory problem it is measuring.
check("the spike list is bounded rather than unbounded",
    #NS.SpikeDetector.spikes <= 300, #NS.SpikeDetector.spikes)
check("the marker list is bounded", #NS.Context.markers <= 400, #NS.Context.markers)

--------------------------------------------------------------------------
-- 3. Every page again, now with far too much of everything
--------------------------------------------------------------------------

do
    local before = #mock.errors
    local slowest, slowestPage = 0, nil
    for _, key in ipairs(NS.UI.pageOrder) do
        local t0 = os.clock()
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:LayoutPage(key)
        NS.UI.MainWindow:InvalidateGraphs()
        NS.UI.MainWindow:BeginGraphPass()
        NS.UI.MainWindow:RefreshCurrentPage()
        NS.UI.MainWindow:RefreshCurrentPage()
        local elapsed = os.clock() - t0
        if elapsed > slowest then slowest, slowestPage = elapsed, key end
    end
    check("every page survives 220 addons and 140 incidents",
        #mock.errors == before, (#mock.errors - before) .. " errors")
    for i = before + 1, math.min(#mock.errors, before + 4) do
        print("      " .. mock.errors[i])
    end
    print(("   slowest page under load: %s at %.1f ms of harness time")
        :format(tostring(slowestPage), slowest * 1000))
end

--------------------------------------------------------------------------
-- 4. Long names must not escape their boxes at this scale either
--------------------------------------------------------------------------

do
    NS.UI.MainWindow.frame:SetSize(940, 600)
    for _, key in ipairs({ "processes", "impact", "dashboard", "overview" }) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:LayoutPage(key)
        NS.UI.MainWindow:RefreshCurrentPage()
    end
    local findings = mock.AuditText()
    local escaped = 0
    for _, finding in ipairs(findings) do
        if finding.kind == "unbounded" then
            escaped = escaped + 1
            if escaped <= 4 then
                print(("      escapes: %q needs %.0f px in %.0f")
                    :format(finding.text:sub(1, 40), finding.width, finding.box))
            end
        end
    end
    check("no text escapes its panel with 220 addons at the minimum size",
        escaped == 0, escaped)

    local overlaps = mock.AuditTextOverlap()
    check("no two labels collide at this scale", #overlaps == 0, #overlaps)
end

--------------------------------------------------------------------------
-- 5. The addon detail view, on an addon with an absurd name
--------------------------------------------------------------------------

do
    local before = #mock.errors
    local record = NS.Processes:Get("Addon010")
    check("the long-named addon exists", record ~= nil)
    if record then
        NS.UI.AddonDetail:Open(record)
        for _, tab in ipairs({ "overview","cpu","memory","history","events",
                               "dependencies","diagnostics","metadata" }) do
            NS.UI.AddonDetail:ShowTab(tab)
        end
        NS.UI.AddonDetail:Close()
    end
    check("its detail view opens on every tab", #mock.errors == before,
        (#mock.errors - before) .. " errors")
end

--------------------------------------------------------------------------
-- 6. Session compare with many stored sessions
--------------------------------------------------------------------------

do
    local before = #mock.errors
    for i = 1, 40 do
        NS.db.global.sessions[#NS.db.global.sessions + 1] = {
            id = i, startedAt = time() - i * 3600, duration = 1800 + i,
            avgFPS = 60 + i, low1 = 30 + i, low01 = 20 + i,
            maxFrameMs = 100 + i, medianMs = 10,
            spikeCount = { freeze = i % 3, heavy = i % 5, stutter = i % 7, minor = 0 },
            avgLatencyWorld = 40 + i, peakLatencyWorld = 200 + i,
            luaStartKB = 100000, luaEndKB = 100000 + i * 1024,
            eventPeakRate = 500 + i, eventStorms = i % 4,
        }
    end
    NS.UI.MainWindow:ShowPage("compare")
    NS.UI.MainWindow:LayoutPage("compare")
    NS.UI.MainWindow:RefreshCurrentPage()
    check("compare handles a long session list", #mock.errors == before,
        (#mock.errors - before) .. " errors")

    NS.UI.MainWindow:ShowPage("sessions")
    NS.UI.MainWindow:RefreshCurrentPage()
    check("the sessions page handles it too", #mock.errors == before,
        (#mock.errors - before) .. " errors")
end

--------------------------------------------------------------------------
-- 6b. A lot of errors, and the pages that render them
--------------------------------------------------------------------------
-- 300 distinct bugs plus a storm of one, which is what the Errors page, the
-- dashboard widgets, the process columns and the detail view actually have to
-- draw when a client is having a bad night.

do
    local before = #mock.errors

    for i = 1, 300 do
        NS.Errors:Record(("Interface/AddOns/Addon%d/File.lua:%d: %s")
            :format(i % 40, i, ("a fairly long failure message that has to fit in a row "):rep(2)),
            ("Interface/AddOns/Addon%d/File.lua:%d: in function <anonymous>\n"):format(i % 40, i):rep(6),
            false)
    end
    for _ = 1, 5000 do
        NS.Errors:Record("Interface/AddOns/Loud/Loud.lua:1: over and over", nil, false)
    end
    NS.Errors:Record("Interface/AddOns/WoWTaskManager/Thing.lua:1: our own", nil, true)

    check("300 distinct errors and a 5000-strong storm are held",
        #NS.Errors.groups >= 300, #NS.Errors.groups)

    local start = os.clock()
    NS.UI.MainWindow:ShowPage("errors")
    NS.UI.MainWindow:LayoutPage("errors")
    NS.UI.MainWindow:RefreshCurrentPage()
    local elapsed = (os.clock() - start) * 1000
    print(("      errors page with %d groups: %.1f ms of harness time")
        :format(#NS.Errors.groups, elapsed))
    check("the errors page renders them", #mock.errors == before,
        (#mock.errors - before) .. " errors")

    NS.UI.MainWindow:ShowPage("dashboard")
    NS.UI.MainWindow:LayoutPage("dashboard")
    NS.UI.MainWindow:RefreshCurrentPage()
    check("the dashboard error widgets render them", #mock.errors == before,
        (#mock.errors - before) .. " errors")

    NS.UI.MainWindow:ShowPage("reports")
    NS.UI.MainWindow:LayoutPage("reports")
    NS.UI.MainWindow:RefreshCurrentPage()
    NS.UI.Pages.reports:Generate("errors")
    check("a report over 300 errors generates", #mock.errors == before,
        (#mock.errors - before) .. " errors")

    -- The detail view, on the noisiest error and on one with no addon at all.
    NS.UI.ErrorDetail:Open(NS.Errors:MostFrequent())
    for _, tab in ipairs({ "overview", "stack", "context", "timeline",
                           "incidents", "related" }) do
        NS.UI.ErrorDetail:ShowTab(tab)
    end
    NS.UI.ErrorDetail:Close()
    check("every error detail tab renders", #mock.errors == before,
        (#mock.errors - before) .. " errors")
    for i = before + 1, math.min(#mock.errors, before + 4) do
        print("      " .. mock.errors[i])
    end

    -- Diagnostics has to survive 300 findings-worth of input.
    NS.Diagnostics:InvalidateCache()
    NS.UI.MainWindow:ShowPage("diagnostics")
    NS.UI.MainWindow:LayoutPage("diagnostics")
    NS.UI.MainWindow:RefreshCurrentPage()
    check("diagnostics renders with hundreds of error findings",
        #mock.errors == before, (#mock.errors - before) .. " errors")

    -- And the process list, whose two error columns query the monitor per row.
    NS.UI.MainWindow:ShowPage("processes")
    NS.UI.MainWindow:LayoutPage("processes")
    NS.UI.MainWindow:RefreshCurrentPage()
    check("the process list renders its error columns at scale",
        #mock.errors == before, (#mock.errors - before) .. " errors")
end

--------------------------------------------------------------------------
-- 7. Degraded to nothing, at scale
--------------------------------------------------------------------------
-- A client that can measure almost nothing, with a very large addon list, is
-- the combination most likely to divide by zero somewhere.

do
    local before = #mock.errors
    NS.CPU.available = false
    NS.CPU.reason = "simulated: profiling unavailable"
    NS.Events.mode = "OFF"

    for _, key in ipairs(NS.UI.pageOrder) do
        NS.UI.MainWindow:ShowPage(key)
        NS.UI.MainWindow:LayoutPage(key)
        NS.UI.MainWindow:RefreshCurrentPage()
    end
    check("every page survives losing CPU and events at scale",
        #mock.errors == before, (#mock.errors - before) .. " errors")
    for i = before + 1, math.min(#mock.errors, before + 4) do
        print("      " .. mock.errors[i])
    end
end

NS.UI.MainWindow:Close()

print(("   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
if failed > 0 or #mock.errors > 0 then os.exit(1) end
