--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Compat.lua

    The ONLY place (together with Compatibility/*.lua) that is allowed to know
    which client it is running on.  Everything above this layer talks to
    WTM.Compat.* and WTM.Caps.* and stays client-agnostic.

    Design rules enforced here:
      * Never assume an API exists because of the version number.  Probe it.
      * Never call an optional API without a resolved wrapper.
      * Never register an event without pcall - unknown events raise Lua errors
        on modern clients.
      * Never call a protected function, never touch a secure frame.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local Compat = {}
WTM.Compat = Compat

local type, pcall, select, tonumber = type, pcall, select, tonumber
local wipe = wipe or table.wipe

--------------------------------------------------------------------------
-- 1. Client identification
--------------------------------------------------------------------------
-- Interface number is major*10000 + minor*100 + patch and exists on every
-- client, which makes it the most reliable discriminator.  WOW_PROJECT_ID is
-- only used as a cross-check because the project constants are not defined on
-- every flavor.

local version, build, buildDate, tocVersion = GetBuildInfo()
tocVersion = tonumber(tocVersion) or 0

Compat.version    = version or "unknown"
Compat.build      = build or "0"
Compat.buildDate  = buildDate or ""
Compat.tocVersion = tocVersion

local flavor, flavorName
if tocVersion >= 100000 then
    flavor, flavorName = "retail", "Retail"
elseif tocVersion >= 50000 and tocVersion < 60000 then
    flavor, flavorName = "mop", "Mists of Pandaria Classic"
elseif tocVersion >= 40000 and tocVersion < 50000 then
    flavor, flavorName = "cata", "Cataclysm Classic"
elseif tocVersion >= 30000 and tocVersion < 40000 then
    flavor, flavorName = "wrath", "Wrath Classic"
elseif tocVersion >= 20000 and tocVersion < 30000 then
    flavor, flavorName = "tbc", "Burning Crusade Classic"
elseif tocVersion >= 10000 and tocVersion < 20000 then
    flavor, flavorName = "classic", "Classic Era"
else
    -- Unknown future/odd build: behave like the most capable client but let
    -- feature detection do all the real work.
    flavor, flavorName = "retail", "Unknown (" .. tostring(tocVersion) .. ")"
end

Compat.flavor     = flavor
Compat.flavorName = flavorName
Compat.projectID  = WOW_PROJECT_ID

Compat.isRetail  = (flavor == "retail")
Compat.isMoP     = (flavor == "mop")
Compat.isTBC     = (flavor == "tbc")
Compat.isClassic = (flavor == "classic")
-- "modern" == built on the post-8.0 engine.  All four target clients are.
Compat.isModernEngine = (tocVersion >= 11300)

function Compat:GetClientLabel()
    return ("%s %s (%s)"):format(flavorName, Compat.version, Compat.build)
end

--------------------------------------------------------------------------
-- 2. Safe call helpers
--------------------------------------------------------------------------

local errorLog = {}
Compat.errorLog = errorLog

local function LogError(where, err)
    local n = #errorLog + 1
    if n > 50 then
        -- keep the log bounded; oldest entries fall out
        for i = 1, 49 do errorLog[i] = errorLog[i + 1] end
        n = 50
    end
    errorLog[n] = { t = GetTime and GetTime() or 0, where = where, err = tostring(err) }
end

--- Calls fn(...) inside pcall.  Returns nil on failure instead of erroring.
function Compat.SafeCall(where, fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if not ok then
        LogError(where, a)
        return nil
    end
    return a, b, c, d, e, f, g
end

local SafeCall = Compat.SafeCall

--- Resolves the first existing function from a list of candidates.
--- Candidates are given as {table, "key"} pairs; a nil table is skipped.
local function Resolve(...)
    for i = 1, select("#", ...), 2 do
        local tbl = select(i, ...)
        local key = select(i + 1, ...)
        if type(tbl) == "table" and type(tbl[key]) == "function" then
            return tbl[key], tbl
        end
    end
    return nil
end
Compat.Resolve = Resolve

--------------------------------------------------------------------------
-- 3. Event registration that cannot error
--------------------------------------------------------------------------
-- Registering an event the client does not know raises a Lua error on modern
-- clients, so every optional event goes through here.  Results are cached so a
-- failed probe costs nothing after the first attempt.

local eventSupport = {}
Compat.eventSupport = eventSupport

function Compat.IsEventSupported(event)
    local known = eventSupport[event]
    if known ~= nil then return known end
    -- Probe on a throwaway frame so a failure cannot leave a real frame in a
    -- half-registered state.
    local probe = Compat._probeFrame
    if not probe then
        probe = CreateFrame("Frame")
        Compat._probeFrame = probe
    end
    local ok = pcall(probe.RegisterEvent, probe, event)
    if ok then pcall(probe.UnregisterEvent, probe, event) end
    eventSupport[event] = ok and true or false
    return eventSupport[event]
end

--- Registers `event` on `frame` if the client knows it.  Returns true on success.
function Compat.SafeRegisterEvent(frame, event)
    if not Compat.IsEventSupported(event) then return false end
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then
        eventSupport[event] = false
        return false
    end
    return true
end

--------------------------------------------------------------------------
-- 4. Addon API bridge
--------------------------------------------------------------------------
-- Retail 11.0 moved these into C_AddOns and removed the globals.  Classic
-- flavors may have either or both.  We probe both, always.

local C_AddOns = _G.C_AddOns

local api = {}
Compat.api = api

api.GetNumAddOns              = Resolve(C_AddOns, "GetNumAddOns", _G, "GetNumAddOns")
api.GetAddOnInfo              = Resolve(C_AddOns, "GetAddOnInfo", _G, "GetAddOnInfo")
api.GetAddOnMetadata          = Resolve(C_AddOns, "GetAddOnMetadata", _G, "GetAddOnMetadata")
api.IsAddOnLoaded             = Resolve(C_AddOns, "IsAddOnLoaded", _G, "IsAddOnLoaded")
api.IsAddOnLoadOnDemand       = Resolve(C_AddOns, "IsAddOnLoadOnDemand", _G, "IsAddOnLoadOnDemand")
api.LoadAddOn                 = Resolve(C_AddOns, "LoadAddOn", _G, "LoadAddOn")
api.EnableAddOn               = Resolve(C_AddOns, "EnableAddOn", _G, "EnableAddOn")
api.DisableAddOn              = Resolve(C_AddOns, "DisableAddOn", _G, "DisableAddOn")
api.GetAddOnEnableState       = Resolve(C_AddOns, "GetAddOnEnableState", _G, "GetAddOnEnableState")
api.GetAddOnDependencies      = Resolve(C_AddOns, "GetAddOnDependencies", _G, "GetAddOnDependencies")
api.GetAddOnOptionalDependencies =
    Resolve(C_AddOns, "GetAddOnOptionalDependencies", _G, "GetAddOnOptionalDependencies")

-- Profiling APIs.  These are globals on every current client, but we probe the
-- C_AddOns namespace too so a future move does not silently disable the feature.
api.UpdateAddOnCPUUsage    = Resolve(C_AddOns, "UpdateAddOnCPUUsage", _G, "UpdateAddOnCPUUsage")
api.GetAddOnCPUUsage       = Resolve(C_AddOns, "GetAddOnCPUUsage", _G, "GetAddOnCPUUsage")
api.UpdateAddOnMemoryUsage = Resolve(C_AddOns, "UpdateAddOnMemoryUsage", _G, "UpdateAddOnMemoryUsage")
api.GetAddOnMemoryUsage    = Resolve(C_AddOns, "GetAddOnMemoryUsage", _G, "GetAddOnMemoryUsage")
api.ResetCPUUsage          = Resolve(C_AddOns, "ResetCPUUsage", _G, "ResetCPUUsage")
api.GetScriptCPUUsage      = Resolve(_G, "GetScriptCPUUsage")
api.GetEventCPUUsage       = Resolve(_G, "GetEventCPUUsage")
api.GetFrameCPUUsage       = Resolve(_G, "GetFrameCPUUsage")
api.GetFunctionCPUUsage    = Resolve(_G, "GetFunctionCPUUsage")

-- Misc
api.GetFramerate           = Resolve(_G, "GetFramerate")
api.GetNetStats            = Resolve(_G, "GetNetStats")
api.GetTimePreciseSec      = Resolve(_G, "GetTimePreciseSec")
api.debugprofilestop       = Resolve(_G, "debugprofilestop")
api.EnumerateFrames        = Resolve(_G, "EnumerateFrames")
api.GetPhysicalScreenSize  = Resolve(_G, "GetPhysicalScreenSize")
api.GetInstanceInfo        = Resolve(_G, "GetInstanceInfo")
api.IsEncounterInProgress  = Resolve(_G, "IsEncounterInProgress")
api.GetNumGroupMembers     = Resolve(_G, "GetNumGroupMembers")
api.GetCVar                = Resolve(_G.C_CVar, "GetCVar", _G, "GetCVar")
api.SetCVar                = Resolve(_G.C_CVar, "SetCVar", _G, "SetCVar")
api.GetCVarBool            = Resolve(_G.C_CVar, "GetCVarBool", _G, "GetCVarBool")
api.GetCVarDefault         = Resolve(_G.C_CVar, "GetCVarDefault", _G, "GetCVarDefault")
api.GetCVarInfo            = Resolve(_G.C_CVar, "GetCVarInfo", _G, "GetCVarInfo")

--------------------------------------------------------------------------
-- 5. Addon accessors (normalized)
--------------------------------------------------------------------------

function Compat.GetNumAddOns()
    return SafeCall("GetNumAddOns", api.GetNumAddOns) or 0
end

--- Returns name, title, notes, loadable, reason, security
function Compat.GetAddOnInfo(indexOrName)
    if not api.GetAddOnInfo then return nil end
    return SafeCall("GetAddOnInfo", api.GetAddOnInfo, indexOrName)
end

function Compat.GetAddOnMetadata(indexOrName, field)
    if not api.GetAddOnMetadata then return nil end
    return SafeCall("GetAddOnMetadata", api.GetAddOnMetadata, indexOrName, field)
end

function Compat.IsAddOnLoaded(indexOrName)
    if not api.IsAddOnLoaded then return false end
    local loaded = SafeCall("IsAddOnLoaded", api.IsAddOnLoaded, indexOrName)
    return loaded and true or false
end

function Compat.IsAddOnLoadOnDemand(indexOrName)
    if not api.IsAddOnLoadOnDemand then return false end
    return SafeCall("IsAddOnLoadOnDemand", api.IsAddOnLoadOnDemand, indexOrName) and true or false
end

--- Argument order for GetAddOnEnableState differs between clients:
---   legacy : GetAddOnEnableState(character, index)
---   modern : C_AddOns.GetAddOnEnableState(addonNameOrIndex, character)
--- Rather than guessing from the version we try both and accept only a value in
--- {0, 1, 2}.  The working order is cached after the first successful call.
local enableStateOrder  -- nil = unknown, "modern", "legacy"

function Compat.GetAddOnEnableState(indexOrName, character)
    local fn = api.GetAddOnEnableState
    if not fn then return nil end

    local function tryModern()
        local v = SafeCall("GetAddOnEnableState/modern", fn, indexOrName, character)
        if v == 0 or v == 1 or v == 2 then return v end
        return nil
    end
    local function tryLegacy()
        local v = SafeCall("GetAddOnEnableState/legacy", fn, character, indexOrName)
        if v == 0 or v == 1 or v == 2 then return v end
        return nil
    end

    if enableStateOrder == "modern" then
        return tryModern() or tryLegacy()
    elseif enableStateOrder == "legacy" then
        return tryLegacy() or tryModern()
    end

    local v = tryModern()
    if v then enableStateOrder = "modern" return v end
    v = tryLegacy()
    if v then enableStateOrder = "legacy" return v end
    return nil
end

--- Returns an array of dependency names (never nil).  Called on demand only,
--- never from a sampling task, so the temporary table is acceptable here.
function Compat.GetAddOnDependencies(indexOrName, optional, out)
    out = out or {}
    wipe(out)
    local fn = optional and api.GetAddOnOptionalDependencies or api.GetAddOnDependencies
    if not fn then return out end
    local ok, res = pcall(function() return { fn(indexOrName) } end)
    if ok and res then
        for i = 1, #res do
            local v = res[i]
            if type(v) == "string" and v ~= "" then
                out[#out + 1] = v
            end
        end
    end
    return out
end

--------------------------------------------------------------------------
-- 6. CVar bridge
--------------------------------------------------------------------------

function Compat.GetCVar(name)
    if not api.GetCVar then return nil end
    return SafeCall("GetCVar:" .. name, api.GetCVar, name)
end

function Compat.GetCVarNumber(name, default)
    return tonumber(Compat.GetCVar(name)) or default
end

--- Returns writable, reason.  A CVar that does not exist, is read-only, secure
--- or locked from the user is never written to.
function Compat.IsCVarWritable(name)
    if not api.SetCVar then return false, "no SetCVar API on this client" end
    if Compat.GetCVar(name) == nil then return false, "CVar does not exist on this client" end
    if api.GetCVarInfo then
        local _, _, _, _, isLocked, isSecure, isReadOnly =
            SafeCall("GetCVarInfo:" .. name, api.GetCVarInfo, name)
        if isReadOnly then return false, "read-only" end
        if isLocked   then return false, "locked from user" end
        if isSecure   then return false, "secure CVar" end
    end
    return true
end

--- Never bypasses protection: on failure it simply reports why.
function Compat.SetCVar(name, value)
    local writable, why = Compat.IsCVarWritable(name)
    if not writable then return false, why end
    local ok = pcall(api.SetCVar, name, value)
    if not ok then return false, "client refused the write" end
    return true
end

--------------------------------------------------------------------------
-- 7. High resolution clock
--------------------------------------------------------------------------
-- debugprofilestop() exists on all four target clients and is the cheapest
-- millisecond clock available to an addon.

local debugprofilestop = api.debugprofilestop
if debugprofilestop then
    Compat.Now = function() return debugprofilestop() end
elseif api.GetTimePreciseSec then
    local f = api.GetTimePreciseSec
    Compat.Now = function() return f() * 1000 end
else
    Compat.Now = function() return GetTime() * 1000 end
end

--------------------------------------------------------------------------
-- 8. Combat-safe action queue
--------------------------------------------------------------------------
-- Nothing this addon does is actually protected, but CVar writes and ReloadUI
-- during combat are a bad experience, so they are deferred instead.

local queue = {}
Compat.combatQueue = queue

function Compat.InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

--- Runs fn now, or after combat ends.  Returns true if it ran immediately.
function Compat.RunWhenSafe(label, fn)
    if not Compat.InCombat() then
        SafeCall(label, fn)
        return true
    end
    queue[#queue + 1] = { label = label, fn = fn }
    return false
end

function Compat.FlushCombatQueue()
    if #queue == 0 then return 0 end
    local n = #queue
    for i = 1, n do
        local entry = queue[i]
        SafeCall(entry.label, entry.fn)
        queue[i] = nil
    end
    return n
end

--------------------------------------------------------------------------
-- 9. Per-flavor override hook
--------------------------------------------------------------------------
-- Compatibility/<Flavor>.lua registers itself here.  Exactly one runs.

WTM._flavorModules = {}

function Compat.ApplyFlavorModule()
    local mod = WTM._flavorModules[flavor]
    if mod and mod.Apply then
        SafeCall("FlavorModule:" .. flavor, mod.Apply, Compat)
        Compat.flavorModule = mod
    end
    -- A flavor without a dedicated file still works: the generic layer above
    -- already probes everything.  This is only for the extras.
    return Compat.flavorModule
end
