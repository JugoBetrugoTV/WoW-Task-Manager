-- Lua error monitor tests.
--
-- The whole point of this file is the handler contract, because that is the
-- part that can break somebody else's addon rather than just this one:
--
--   * whatever handler was installed before this one keeps receiving every
--     error, unchanged, exactly once;
--   * an error raised while handling an error does not recurse;
--   * this addon's own faults are visible and are never filtered out;
--   * ten thousand duplicates cost ten thousand counter increments and one
--     stored group, not ten thousand database rows.
--
--   lua5.1 tools/test-errors.lua

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

local Errors = NS.Errors
local C = NS.C

--- Puts the monitor back to a known state AND detaches it from the client, so
--- the next arrangement starts from whatever handler the test wants.
local function reinstall(previous)
    Errors:Reset()
    Errors.chaining.installed = false
    Errors.chaining.hadPrevious = false
    Errors.chaining.previous = nil
    Errors.chaining.displaced = false
    Errors.lastNotifyAt = nil
    Errors.suppressedNotices = 0
    Errors.sessionIgnored = nil
    Errors.safeMode.active = false
    for i = #Errors.safeMode.internalTimes, 1, -1 do
        Errors.safeMode.internalTimes[i] = nil
    end
    -- A silent handler by default: the tests raise thousands of errors on
    -- purpose, and letting the mock collect them all would make the suite's
    -- own "no unexpected errors" check meaningless.
    seterrorhandler(previous or function() end)
    return Errors:Install()
end

local function raise(message)
    -- Through the client's current handler, exactly as the real thing does.
    mock.RaiseError(message)
end

local ADDON_ERR = "Interface/AddOns/WeakAuras/Core.lua:412: attempt to index a nil value"

--------------------------------------------------------------------------
print("== handler chaining ==")
--------------------------------------------------------------------------

-- 1. Nothing installed before us.
seterrorhandler(nil)
reinstall(mock.defaultErrorHandler)
check("the handler installs", Errors.chaining.installed == true)
check("it reports whether something was there before",
    Errors.chaining.hadPrevious == true, tostring(Errors.chaining.hadPrevious))

-- 2. A previous handler, of the sort BugGrabber installs.
local seen, seenExtra = {}, {}
local other = function(message, ...)
    seen[#seen + 1] = message
    seenExtra[#seenExtra + 1] = select("#", ...) > 0 and (select(1, ...)) or nil
end
reinstall(other)
check("an existing handler is chained rather than replaced",
    Errors.chaining.hadPrevious == true and Errors.chaining.previous == other)

raise(ADDON_ERR)
check("the previous handler still receives the error", #seen == 1, #seen)
check("it receives the message unchanged", seen[1] == ADDON_ERR, seen[1])
check("this addon also recorded it", #Errors.groups == 1, #Errors.groups)

-- 3. Exactly once, never twice. A doubled error is the failure mode that makes
--    another error addon look broken.
for i = #seen, 1, -1 do seen[i] = nil end
raise(ADDON_ERR)
check("a repeat reaches the previous handler exactly once", #seen == 1, #seen)
check("the repeat folded into the existing group", #Errors.groups == 1, #Errors.groups)
check("the repeat was counted", Errors.groups[1].count == 2, Errors.groups[1].count)

-- 4. Extra arguments pass through.
for i = #seen, 1, -1 do seen[i] = nil end
for i = #seenExtra, 1, -1 do seenExtra[i] = nil end
geterrorhandler()("Interface/AddOns/Foo/Bar.lua:1: boom", "extra-argument")
check("extra arguments reach the previous handler unchanged",
    seenExtra[1] == "extra-argument", tostring(seenExtra[1]))

-- 5. Capture switched off: we record nothing and still pass everything on.
reinstall(other)
NS.db.profile.errors.enabled = false
for i = #seen, 1, -1 do seen[i] = nil end
raise("Interface/AddOns/Quiet/Thing.lua:9: silent")
check("with capture off nothing is recorded", #Errors.groups == 0, #Errors.groups)
check("with capture off the previous handler still gets it", #seen == 1, #seen)
NS.db.profile.errors.enabled = true

-- 6. A fault inside our own bookkeeping must not stop the pass-through. The
--    only honest way to test that is to actually break something we call.
reinstall(other)
for i = #seen, 1, -1 do seen[i] = nil end
local savedFingerprint = Errors.Fingerprint
Errors.Fingerprint = function() error("deliberate fault inside the monitor") end
raise("Interface/AddOns/Broken/Thing.lua:3: while we were broken")
Errors.Fingerprint = savedFingerprint
check("a fault in our own recording does not stop the pass-through",
    #seen == 1, #seen)
check("the fault itself is remembered rather than swallowed silently",
    Errors.ownFault ~= nil, tostring(Errors.ownFault))
Errors.ownFault, Errors.reportedOwnFault = nil, nil

-- 7. Re-entry. An error raised while an error is being handled must pass
--    through once and stop, not recurse.
reinstall(nil)
local depth, maxDepth = 0, 0
local reentrant
reentrant = function(message)
    depth = depth + 1
    if depth > maxDepth then maxDepth = depth end
    if depth < 4 then
        -- The previous handler raises an error of its own, which is exactly
        -- what a broken error addon does.
        geterrorhandler()("Interface/AddOns/Loop/Loop.lua:1: nested")
    end
    depth = depth - 1
end
Errors.chaining.previous = reentrant
raise("Interface/AddOns/Outer/Outer.lua:1: outer")
check("a nested error does not recurse without bound", maxDepth <= 4, maxDepth)
check("re-entry recorded only the outermost error", #Errors.groups == 1, #Errors.groups)
check("the nested error still reached the handler below",
    maxDepth >= 2, maxDepth)

-- 8. Displacement: something installs its handler after ours.
reinstall(other)
local usurper = function() end
seterrorhandler(usurper)
Errors:CheckChain()
check("a handler installed after ours is detected", Errors.chaining.displaced == true)
check("we do not fight it back", geterrorhandler() == usurper)
local text, tone = Errors:DescribeChain()
check("displacement is explained rather than treated as an error", tone == "warn", tone)
local short = Errors:ShortChainState()
check("the short form says displaced", short == "displaced", short)

--------------------------------------------------------------------------
print("\n== fingerprinting ==")
--------------------------------------------------------------------------

reinstall(nil)
raise("Interface/AddOns/A/A.lua:10: attempt to index field 'unit' (a nil value)")
raise("Interface/AddOns/A/A.lua:10: attempt to index field 'unit' (a nil value)")
check("the same error twice is one group", #Errors.groups == 1, #Errors.groups)
check("both occurrences are counted", Errors.stats.total == 2, Errors.stats.total)
check("the second is counted as folded", Errors.stats.suppressed == 1, Errors.stats.suppressed)

raise("Interface/AddOns/A/A.lua:11: attempt to index field 'unit' (a nil value)")
check("a different line is a different group", #Errors.groups == 2, #Errors.groups)

reinstall(nil)
raise("Interface/AddOns/B/B.lua:5: bad argument #1 to 'foo' (got table: 0x1a2b3c)")
raise("Interface/AddOns/B/B.lua:5: bad argument #7 to 'foo' (got table: 0xffee11)")
check("varying addresses and indices fold into one bug",
    #Errors.groups == 1, #Errors.groups)

reinstall(nil)
raise(ADDON_ERR)
check("the addon is read out of the file path",
    Errors.groups[1].addon == "WeakAuras", tostring(Errors.groups[1].addon))
check("the attribution is marked as certain", Errors.groups[1].addonCertain == true)

reinstall(nil)
raise("[string \"anonymous\"]:1: something went wrong")
check("an error with no addon path is not attributed to anything",
    Errors.groups[1].addon == nil, tostring(Errors.groups[1].addon))
check("and that is marked as uncertain", Errors.groups[1].addonCertain == false)

--------------------------------------------------------------------------
print("\n== this addon's own errors ==")
--------------------------------------------------------------------------

reinstall(nil)
raise("Interface/AddOns/WoWTaskManager/UI/Pages/Errors.lua:44: our own fault")
check("an error from this addon is recorded", #Errors.groups == 1, #Errors.groups)
check("it is marked internal", Errors.groups[1].internal == true)
check("internal errors are counted separately",
    Errors.stats.internal == 1, Errors.stats.internal)

-- Ignoring everything must not hide this addon's own faults from the list.
NS.db.profile.errors.ignored.addons["WoWTaskManager"] = true
check("an internal error is still in the list when its addon is ignored",
    #Errors.groups == 1, #Errors.groups)
check("ignoring never stops it being counted",
    Errors.stats.total == 1, Errors.stats.total)
NS.db.profile.errors.ignored.addons["WoWTaskManager"] = nil

--------------------------------------------------------------------------
print("\n== ignoring counts, it just does not shout ==")
--------------------------------------------------------------------------

reinstall(nil)
raise("Interface/AddOns/Noisy/Noisy.lua:1: over and over")
local noisy = Errors.groups[1]
Errors:SetIgnored(noisy, true)
for _ = 1, 5 do raise("Interface/AddOns/Noisy/Noisy.lua:1: over and over") end
check("an ignored error keeps counting occurrences", noisy.count == 6, noisy.count)
check("the session total includes them", Errors.stats.total == 6, Errors.stats.total)

NS.db.profile.errors.countIgnored = true
check("with counting on, the badge includes ignored errors",
    Errors:CountVisible() == 6, Errors:CountVisible())
NS.db.profile.errors.countIgnored = false
check("with counting off, the badge excludes them",
    Errors:CountVisible() == 0, Errors:CountVisible())
check("but the underlying total is unchanged either way",
    Errors.stats.total == 6, Errors.stats.total)
NS.db.profile.errors.countIgnored = true
Errors:SetIgnored(noisy, false)

--------------------------------------------------------------------------
print("\n== scale: a storm of one bug ==")
--------------------------------------------------------------------------

reinstall(nil)
local before = collectgarbage("count")
for _ = 1, 10000 do
    raise("Interface/AddOns/Loop/Loop.lua:88: attempt to call a nil value")
end
local after = collectgarbage("count")

check("ten thousand duplicates produce one group", #Errors.groups == 1, #Errors.groups)
check("all ten thousand are counted", Errors.groups[1].count == 10000,
    Errors.groups[1].count)
check("the session total agrees", Errors.stats.total == 10000, Errors.stats.total)
check("9999 of them are recorded as folded",
    Errors.stats.suppressed == 9999, Errors.stats.suppressed)
check("the occurrence ring stays bounded",
    #Errors:Occurrences(Errors.groups[1], {}) <= C.ERROR_TIME_RING,
    #Errors:Occurrences(Errors.groups[1], {}))
check("the ring reports itself as a sample rather than the whole",
    Errors:OccurrencesTruncated(Errors.groups[1]) == true)
-- The duplicate path is supposed to allocate nothing. Lua's own bookkeeping
-- makes an exact zero unrealistic, so the bar is "not proportional to 10,000".
check("ten thousand duplicates do not grow the heap by a per-error amount",
    (after - before) < 200, ("%.0f KB"):format(after - before))

-- And they must not turn into ten thousand saved rows either.
NS.db.profile.errors.keepAcrossSessions = true
NS.db.global.errorSessions = {}
Errors:Persist()
local savedSession = NS.db.global.errorSessions[1]
check("one session was written", #NS.db.global.errorSessions == 1)
check("it holds one group, not ten thousand", #savedSession.groups == 1,
    #savedSession.groups)
check("the saved group keeps the true count", savedSession.groups[1].count == 10000,
    savedSession.groups[1].count)
check("occurrence timestamps are not saved",
    savedSession.groups[1].timeRing == nil)

--------------------------------------------------------------------------
print("\n== caps ==")
--------------------------------------------------------------------------

reinstall(nil)
NS.db.profile.errors.maxUnique = 20
NS.db.profile.errors.evictOldest = false
for i = 1, 40 do
    raise(("Interface/AddOns/Many/File%d.lua:%d: distinct failure"):format(i, i))
end
check("the distinct-error cap holds", #Errors.groups == 20, #Errors.groups)
check("errors refused by the cap are counted, not silently dropped",
    Errors.stats.droppedByCap == 20, Errors.stats.droppedByCap)
check("the total still counts every occurrence",
    Errors.stats.total == 40, Errors.stats.total)
check("keeping the oldest kept the FIRST error of the session",
    Errors.groups[1].file:find("File1%.lua") ~= nil, Errors.groups[1].file)

reinstall(nil)
NS.db.profile.errors.evictOldest = true
for i = 1, 40 do
    raise(("Interface/AddOns/Many/File%d.lua:%d: distinct failure"):format(i, i))
end
check("evicting keeps the cap too", #Errors.groups == 20, #Errors.groups)
check("evicting keeps the LATEST error instead",
    Errors.groups[#Errors.groups].file:find("File40%.lua") ~= nil,
    Errors.groups[#Errors.groups].file)
NS.db.profile.errors.maxUnique = C.ERROR_MAX_UNIQUE
NS.db.profile.errors.evictOldest = false

-- Saved sessions are capped as well, or the database grows forever.
NS.db.global.errorSessions = {}
NS.db.profile.errors.maxSavedSessions = 3
for _ = 1, 6 do Errors:Persist() end
check("saved error sessions are capped",
    #NS.db.global.errorSessions == 3, #NS.db.global.errorSessions)

-- Stack traces are trimmed rather than stored whole.
reinstall(nil)
NS.db.profile.errors.maxStackLength = 200
Errors:Record("Interface/AddOns/Deep/Deep.lua:1: deep", ("frame\n"):rep(500), false)
check("a long stack is trimmed to the configured length",
    #Errors.groups[1].stack <= 200 + 48, #Errors.groups[1].stack)
check("and says that it was trimmed",
    Errors.groups[1].stack:find("truncated", 1, true) ~= nil)
NS.db.profile.errors.maxStackLength = C.ERROR_MAX_STACK

--------------------------------------------------------------------------
print("\n== storms and repeats ==")
--------------------------------------------------------------------------

reinstall(nil)
NS.db.profile.errors.stormThreshold = 10
for i = 1, 12 do
    raise(("Interface/AddOns/Storm/File%d.lua:1: a different failure"):format(i))
end
Errors:DetectStorms()
check("a burst of unrelated errors is a storm", #Errors.storms == 1, #Errors.storms)
check("the storm records how many and over what window",
    Errors.storms[1].count >= 10 and Errors.storms[1].window == C.ERROR_STORM_WINDOW_SEC,
    Errors.storms[1].count)
check("the storm records how many distinct bugs were involved",
    Errors.storms[1].distinct == 12, Errors.storms[1].distinct)

local stormMarkers = 0
for _, marker in ipairs(NS.Context.markers) do
    if marker.kind == "errorstorm" then stormMarkers = stormMarkers + 1 end
end
check("the storm is put on the shared time axis", stormMarkers >= 1, stormMarkers)

reinstall(nil)
NS.db.profile.errors.stormThreshold = C.ERROR_STORM_THRESHOLD
NS.db.profile.errors.repeatThreshold = 8
for _ = 1, 10 do raise("Interface/AddOns/One/One.lua:2: the same failure") end
Errors:DetectStorms()
check("one bug repeating is a separate finding from a storm",
    Errors.groups[1].reportedRepeating == true)
check("and it is not counted as a storm", #Errors.storms == 0, #Errors.storms)
NS.db.profile.errors.stormThreshold = C.ERROR_STORM_THRESHOLD
NS.db.profile.errors.repeatThreshold = C.ERROR_REPEAT_THRESHOLD

--------------------------------------------------------------------------
print("\n== safe mode ==")
--------------------------------------------------------------------------

reinstall(nil)
NS.Scheduler:SetEnabled("ui", true)
for i = 1, C.SAFE_MODE_THRESHOLD do
    raise(("Interface/AddOns/WoWTaskManager/Thing%d.lua:1: internal"):format(i))
end
check("repeated internal faults switch safe mode on", Errors.safeMode.active == true)
local uiTask = NS.Scheduler:GetTask("ui")
local frameTask = NS.Scheduler:GetTask("frametime")
check("safe mode stops the UI task", uiTask and uiTask.enabled == false,
    uiTask and tostring(uiTask.enabled))
check("safe mode does NOT stop recording",
    frameTask and frameTask.enabled ~= false,
    frameTask and tostring(frameTask.enabled))

local recordedBefore = Errors.stats.total
raise("Interface/AddOns/Other/Other.lua:1: still recording")
check("errors are still captured in safe mode",
    Errors.stats.total == recordedBefore + 1, Errors.stats.total)

Errors:LeaveSafeMode()
check("safe mode can be turned off again", Errors.safeMode.active == false)

-- Internal faults spread out over time must NOT trip it.
reinstall(nil)
for i = 1, C.SAFE_MODE_THRESHOLD do
    raise(("Interface/AddOns/WoWTaskManager/Slow%d.lua:1: internal"):format(i))
    mock.Advance(C.SAFE_MODE_WINDOW_SEC + 1)
end
check("internal faults spread over time do not trip safe mode",
    Errors.safeMode.active == false)

--------------------------------------------------------------------------
print("\n== correlation is never causation ==")
--------------------------------------------------------------------------

reinstall(nil)
NS.db.profile.dev.enabled = true
local spike = NS.Dev:InjectFrameSpike(300)
raise("Interface/AddOns/Near/Near.lua:1: happened around a stutter")
local nearGroup = Errors.groups[1]
check("an error near a stutter is reported as overlapping",
    Errors:OverlapsSpikes(nearGroup) >= 1, Errors:OverlapsSpikes(nearGroup))

local reportText = NS.Reports:Error(nearGroup)
local BANNED = { "caused", "because of", "responsible for", "due to", "led to" }
local offender
for _, word in ipairs(BANNED) do
    if reportText:lower():find(word, 1, true) then offender = word break end
end
check("the error report never claims causation", offender == nil, tostring(offender))
check("the report names the addon", reportText:find("Near", 1, true) ~= nil)
check("the report carries the client build",
    reportText:find("12.1.0", 1, true) ~= nil)

local allText = NS.Reports:AllErrors()
offender = nil
for _, word in ipairs(BANNED) do
    if allText:lower():find(word, 1, true) then offender = word break end
end
check("neither does the combined report", offender == nil, tostring(offender))

--------------------------------------------------------------------------
print("\n== things that are not Lua errors ==")
--------------------------------------------------------------------------
-- A real client showed BugSack holding four entries while our page was empty.
-- All four were ADDON_ACTION_FORBIDDEN, which is an EVENT: it never touches an
-- error handler, so capturing it needs a listener, not a handler.

reinstall(nil)
check("the blocked-action events were registered",
    Errors.eventsRegistered["ADDON_ACTION_FORBIDDEN"] ~= nil
    and Errors.eventsRegistered["ADDON_ACTION_BLOCKED"] ~= nil)

Errors:OnActionBlocked("ADDON_ACTION_FORBIDDEN", "SUI", "Frame:RegisterEvent()")
check("a forbidden action is captured", #Errors.groups == 1, #Errors.groups)
local blocked = Errors.groups[1]
check("it is NOT filed as a Lua error", blocked.kind == "forbidden", blocked.kind)
check("the addon comes from the client, not from a path",
    blocked.addon == "SUI" and blocked.addonFromClient == true, tostring(blocked.addon))
check("the function that was refused is in the message",
    blocked.message:find("Frame:RegisterEvent()", 1, true) ~= nil, blocked.message)
check("no stack is invented for it", blocked.stack == nil)

-- 423 of them in a taint storm is a realistic number, and it must fold.
for _ = 1, 422 do
    Errors:OnActionBlocked("ADDON_ACTION_FORBIDDEN", "SUI", "Frame:RegisterEvent()")
end
check("a taint storm folds into one entry", #Errors.groups == 1, #Errors.groups)
check("and counts every occurrence", blocked.count == 423, blocked.count)

-- A different function from the same addon is a different problem.
Errors:OnActionBlocked("ADDON_ACTION_FORBIDDEN", "SUI", "Frame:SetPoint()")
check("a different protected call is a different entry", #Errors.groups == 2, #Errors.groups)

-- And a thrown Lua error from the same addon is a different thing again.
raise("Interface/AddOns/SUI/Core.lua:1: an actual error")
check("a thrown error is separate from a blocked action",
    #Errors.groups == 3, #Errors.groups)
check("only the thrown one is a Lua error",
    Errors.groups[3].kind == "lua", Errors.groups[3].kind)

Errors:OnLuaWarning("LUA_WARNING", 0, "an unused variable somewhere")
check("a Lua warning is captured and labelled",
    #Errors.groups == 4 and Errors.groups[4].kind == "warning",
    Errors.groups[4] and Errors.groups[4].kind)

-- Switchable, because a taint storm is somebody else's problem to look at.
NS.db.profile.errors.captureBlocked = false
Errors:OnActionBlocked("ADDON_ACTION_FORBIDDEN", "Other", "Frame:Show()")
check("blocked-action capture can be switched off", #Errors.groups == 4, #Errors.groups)
NS.db.profile.errors.captureBlocked = true

-- The wording rule applies here too. Checking for the word "crash" would be a
-- substring trap - the note explains that it is NOT one - so this checks the
-- claim instead: the report has to name the kind and carry the explanation.
reinstall(nil)
Errors:OnActionBlocked("ADDON_ACTION_FORBIDDEN", "SUI", "Frame:RegisterEvent()")
local blockedReport = NS.Reports:Error(Errors.groups[1])
check("the report names it a blocked action, not an error",
    blockedReport:find("Blocked action", 1, true) ~= nil)
check("and explains that nothing threw",
    blockedReport:find("not a crash", 1, true) ~= nil)
check("and says the addon named may not be where it began",
    blockedReport:find("not necessarily where it began", 1, true) ~= nil)
check("the client-supplied attribution is marked as such",
    blockedReport:find("named by the client", 1, true) ~= nil)

--------------------------------------------------------------------------
print("\n== a client that cannot do this at all ==")
--------------------------------------------------------------------------

local savedSet, savedGet = seterrorhandler, geterrorhandler
_G.seterrorhandler, _G.geterrorhandler = nil, nil
Errors.chaining.installed = false
local ok, reason = Errors:Install()
check("installation fails rather than erroring", ok == false)
check("and says why", type(reason) == "string" and #reason > 20, reason)
_G.seterrorhandler, _G.geterrorhandler = savedSet, savedGet

--------------------------------------------------------------------------
print(("\n   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(8, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
