--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Capabilities.lua

    Builds the capability matrix at runtime by actually probing the API, not by
    trusting the version number.  Everything the UI greys out, it greys out
    because of a value in here.

    States:
        "yes"      AVAILABLE          available and exact
        "partial"  HEURISTIC          available but approximate; how it is
                                      derived is always stated
        "profile"  REQUIRES PROFILING needs the scriptProfile CVar and a reload
        "no"       NOT POSSIBLE       cannot be done through the addon API

    Nothing here is decided from the client version. Every entry is the result
    of actually probing for the function, the event or the CVar on the machine
    it is running on - which is why a client that gains or loses an API in a
    patch changes this report without any code change.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local Compat = WTM.Compat
local C      = WTM.C
local api    = Compat.api

local Caps = {}
WTM.Caps = Caps

Caps.matrix = {}

local function Set(key, state, note)
    Caps.matrix[key] = { state = state, note = note }
    return state
end
Caps.Set = Set

function Caps:Get(key)
    local entry = self.matrix[key]
    return entry and entry.state or "no", entry and entry.note
end

function Caps:Has(key)
    local state = self:Get(key)
    return state == "yes" or state == "partial"
end

function Caps:Note(key)
    local _, note = self:Get(key)
    return note
end

--------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------

function Caps:Detect()
    local m = self.matrix
    for k in pairs(m) do m[k] = nil end

    ------------------------------------------------------------------
    -- Timing
    ------------------------------------------------------------------
    Set("frameTime", "yes", "OnUpdate elapsed - exact per-frame delta")
    Set("fps", api.GetFramerate and "yes" or "no", "GetFramerate")
    Set("preciseClock", api.debugprofilestop and "yes"
        or (api.GetTimePreciseSec and "partial" or "no"),
        api.debugprofilestop and "debugprofilestop" or "GetTime fallback")
    Set("percentiles", "yes", "derived from the frame time histogram")

    ------------------------------------------------------------------
    -- Network
    ------------------------------------------------------------------
    if api.GetNetStats then
        Set("latency", "yes", "GetNetStats - the client refreshes it roughly every 30 s")
        Set("bandwidth", "yes", "GetNetStats")
    else
        Set("latency", "no", C.TXT_UNAVAILABLE_CLIENT)
        Set("bandwidth", "no", C.TXT_UNAVAILABLE_CLIENT)
    end

    ------------------------------------------------------------------
    -- Memory
    ------------------------------------------------------------------
    local luaMemOK = false
    do
        local ok, kb = pcall(collectgarbage, "count")
        luaMemOK = ok and type(kb) == "number"
    end
    Set("luaMemory", luaMemOK and "yes" or "no", 'collectgarbage("count")')
    Set("addonMemory",
        (api.UpdateAddOnMemoryUsage and api.GetAddOnMemoryUsage) and "yes" or "no",
        "UpdateAddOnMemoryUsage / GetAddOnMemoryUsage - the update call is expensive")
    Set("memoryGrowth", luaMemOK and "yes" or "no", "derived trend, not a leak proof")
    Set("gcEvents", luaMemOK and "partial" or "no",
        "inferred from drops in the Lua heap curve - WoW exposes no GC statistics")
    Set("forceGC", "no", "deliberately not implemented: forcing a collect is itself a stutter")

    ------------------------------------------------------------------
    -- CPU profiling
    ------------------------------------------------------------------
    local hasCPUApi = (api.UpdateAddOnCPUUsage and api.GetAddOnCPUUsage) and true or false
    self.cpuProfiling = self:IsCPUProfilingEnabled()

    local cpuState = (not hasCPUApi) and "no" or (self.cpuProfiling and "yes" or "profile")
    Set("addonCPU", cpuState, hasCPUApi
        and "GetAddOnCPUUsage - requires the scriptProfile CVar"
        or C.TXT_UNAVAILABLE_CLIENT)
    Set("scriptCPU", api.GetScriptCPUUsage and cpuState or "no", "GetScriptCPUUsage")
    Set("eventCPU", api.GetEventCPUUsage and cpuState or "no", "GetEventCPUUsage")
    Set("frameCPU", api.GetFrameCPUUsage and cpuState or "no", "GetFrameCPUUsage")
    Set("functionCPU", api.GetFunctionCPUUsage and cpuState or "no", "GetFunctionCPUUsage")

    local writable, why = Compat.IsCVarWritable("scriptProfile")
    Set("toggleProfiling", writable and "yes" or "no",
        writable and "SetCVar scriptProfile - takes effect after /reload" or (why or "?"))

    ------------------------------------------------------------------
    -- Events
    ------------------------------------------------------------------
    local canRegisterAll = false
    do
        local probe = CreateFrame("Frame")
        canRegisterAll = pcall(probe.RegisterAllEvents, probe)
        if canRegisterAll then pcall(probe.UnregisterAllEvents, probe) end
    end
    Set("eventRate", canRegisterAll and "yes" or "no", "frame:RegisterAllEvents")
    Set("eventStorm", canRegisterAll and "yes" or "no", "derived from the event rate")
    Set("eventToAddon", api.EnumerateFrames and "partial" or "no",
        "EnumerateFrames + frame-name heuristic; anonymous frames cannot be attributed")
    Set("frameCount", api.EnumerateFrames and "partial" or "no",
        "EnumerateFrames + frame-name heuristic")
    Set("onUpdateCount",
        (api.GetFrameCPUUsage and api.EnumerateFrames)
            and (self.cpuProfiling and "partial" or "profile") or "no",
        "handler call counts from GetFrameCPUUsage, attributed heuristically")

    ------------------------------------------------------------------
    -- Addon control
    ------------------------------------------------------------------
    Set("addonMetadata", api.GetAddOnInfo and "yes" or "no", "GetAddOnInfo / GetAddOnMetadata")
    Set("addonDependencies", api.GetAddOnDependencies and "yes" or "no", "GetAddOnDependencies")
    Set("addonLoadOnDemand", api.IsAddOnLoadOnDemand and "yes" or "no", "IsAddOnLoadOnDemand")
    Set("addonEnableState", api.GetAddOnEnableState and "yes" or "no", "GetAddOnEnableState")
    Set("addonEnableDisable",
        (api.EnableAddOn and api.DisableAddOn) and "yes" or "no",
        "EnableAddOn / DisableAddOn - effective after /reload")
    Set("addonLoadNow", api.LoadAddOn and "yes" or "no", "LoadAddOn, LoadOnDemand addons only")
    Set("addonUnload", "no", "No API exists. The Lua state cannot be partially torn down.")
    Set("addonKill", "no", "Lua in WoW is cooperative; there is no preemption to kill.")
    Set("savedVarSize", "partial",
        "estimated by walking the addon's global SavedVariables table - opt-in, off by default")
    Set("reloadUI", type(_G.ReloadUI) == "function" and "yes" or "no", "ReloadUI is not protected")

    ------------------------------------------------------------------
    -- Context
    ------------------------------------------------------------------
    Set("instanceInfo", api.GetInstanceInfo and "yes" or "no", "GetInstanceInfo")
    Set("groupSize", api.GetNumGroupMembers and "yes" or "no", "GetNumGroupMembers")
    Set("combatMarkers", Compat.IsEventSupported("PLAYER_REGEN_DISABLED") and "yes" or "no",
        "PLAYER_REGEN_DISABLED / _ENABLED")
    Set("encounterMarkers", Compat.IsEventSupported("ENCOUNTER_START") and "yes" or "no",
        Compat.IsEventSupported("ENCOUNTER_START") and "ENCOUNTER_START / _END"
        or "ENCOUNTER_START is not broadcast on this client")
    Set("keystoneMarkers", Compat.IsEventSupported("CHALLENGE_MODE_START") and "yes" or "no",
        "CHALLENGE_MODE_START")
    Set("loadingMarkers", Compat.IsEventSupported("LOADING_SCREEN_ENABLED") and "yes" or "no",
        "LOADING_SCREEN_ENABLED / _DISABLED")
    Set("zoneMarkers", Compat.IsEventSupported("ZONE_CHANGED_NEW_AREA") and "yes" or "no",
        "ZONE_CHANGED_NEW_AREA")

    ------------------------------------------------------------------
    -- System / graphics
    ------------------------------------------------------------------
    Set("physicalResolution", api.GetPhysicalScreenSize and "yes" or "partial",
        api.GetPhysicalScreenSize and "GetPhysicalScreenSize"
        or "derived from GetScreenWidth/Height and UIParent scale")

    local function cvarCap(name, label)
        local value = Compat.GetCVar(name)
        if value == nil then
            Set(label, "no", ("CVar '%s' does not exist on this client"):format(name))
        else
            local w = Compat.IsCVarWritable(name)
            Set(label, "yes", ("CVar '%s'%s"):format(name, w and "" or " (read-only)"))
        end
    end
    cvarCap("maxFPS", "cvarMaxFPS")
    cvarCap("maxFPSBk", "cvarMaxFPSBk")
    cvarCap("targetFPS", "cvarTargetFPS")
    cvarCap("renderScale", "cvarRenderScale")

    -- VSync is called different things on different clients.
    if Compat.GetCVar("vsync") ~= nil then
        Set("cvarVSync", "yes", "CVar 'vsync'")
        self.vsyncCVar = "vsync"
    elseif Compat.GetCVar("gxVSync") ~= nil then
        Set("cvarVSync", "yes", "CVar 'gxVSync'")
        self.vsyncCVar = "gxVSync"
    else
        Set("cvarVSync", "no", "no VSync CVar found on this client")
        self.vsyncCVar = nil
    end

    Set("graphicsAPI", "no", "No API exposes the renderer backend or GPU name to addons.")
    Set("osCPU", "no", "Sandbox: no operating-system access.")
    Set("osMemory", "no", "Sandbox: process memory outside Lua is not visible.")
    Set("packetInspection", "no", "Sandbox: no network access.")
    Set("fileAccess", "no", "Sandbox: no file system access.")
    Set("protectedActions", "no", "Protected functions are never called or worked around.")

    ------------------------------------------------------------------
    -- Lua error capture
    ------------------------------------------------------------------
    local hasHandlerApi = type(_G.seterrorhandler) == "function"
        and type(_G.geterrorhandler) == "function"
    Set("errorCapture", hasHandlerApi and "yes" or "no",
        hasHandlerApi and "seterrorhandler / geterrorhandler"
        or "This client exposes no way to intercept Lua errors.")

    -- Chaining works wherever the handler API does, but it can be undone at any
    -- moment by another addon installing its handler afterwards. That is not a
    -- failure and not something to fight over - it is reported instead.
    Set("errorChaining", hasHandlerApi and "partial" or "no",
        hasHandlerApi
            and "The previous handler is captured and always called. Another addon loading later can still take the slot, which is detected and reported."
            or C.TXT_UNAVAILABLE_CLIENT)

    Set("errorStacks", type(_G.debugstack) == "function" and "yes" or "no",
        type(_G.debugstack) == "function" and "debugstack"
        or "No stack traces: debugstack is not available, so only the message is recorded.")

    -- Always heuristic, on every client. There is no API that maps an error to
    -- the addon that raised it; the only signal is the file path in the
    -- message, and plenty of errors carry no usable path at all.
    Set("errorAttribution", "partial",
        "Parsed from the Interface/AddOns path in the error message. Errors from the default UI, from string chunks, or with no path are reported as Unknown rather than guessed at.")

    return self.matrix
end

--------------------------------------------------------------------------
-- scriptProfile handling
--------------------------------------------------------------------------

function Caps:IsCPUProfilingEnabled()
    local v = Compat.GetCVar("scriptProfile")
    if v == nil then return false end
    return v == "1" or v == 1 or v == true
end

--- Flips the CVar and tells the user a reload is required.  Never forces the
--- reload: yanking the UI out from under someone mid-combat would be worse
--- than waiting.
function Caps:SetCPUProfiling(enable)
    local writable, why = Compat.IsCVarWritable("scriptProfile")
    if not writable then
        return false, why or C.TXT_UNAVAILABLE_CLIENT
    end
    local ok, err = Compat.SetCVar("scriptProfile", enable and "1" or "0")
    if not ok then return false, err end

    -- Read back: a silent no-op write is worse than a refusal.
    local now = self:IsCPUProfilingEnabled()
    if now ~= (enable and true or false) then
        return false, "the client did not accept the change"
    end
    self.pendingProfilingReload = true
    return true
end

function Caps:ToggleCPUProfiling()
    local enabled = self:IsCPUProfilingEnabled()
    local ok, err = self:SetCPUProfiling(not enabled)
    if not ok then
        WTM:Print(("Could not change CPU profiling: %s"):format(tostring(err)))
        return false
    end
    WTM:Print(("CPU profiling will be |cff4c8dff%s|r after the next |cff4c8dff/reload|r.")
        :format((not enabled) and "ON" or "OFF"))
    if not enabled then
        WTM:Print("Note: the client's Lua profiler has a real cost of its own. Turn it off when you are done measuring.")
    end
    return true
end

--------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------

Caps.LABELS = {
    frameTime = "Frame time (exact)", fps = "FPS", preciseClock = "High-resolution clock",
    percentiles = "1% low / percentiles",
    latency = "Latency home/world", bandwidth = "Bandwidth in/out",
    luaMemory = "Total Lua memory", addonMemory = "Memory per addon",
    memoryGrowth = "Memory growth trend", gcEvents = "Garbage collection events",
    forceGC = "Force garbage collection",
    addonCPU = "CPU per addon", scriptCPU = "Total Lua CPU", eventCPU = "CPU per event",
    frameCPU = "CPU per frame", functionCPU = "CPU per function",
    toggleProfiling = "Toggle scriptProfile",
    eventRate = "Global event rate", eventStorm = "Event storm detection",
    eventToAddon = "Event to addon attribution", frameCount = "Frames per addon",
    onUpdateCount = "OnUpdate calls per addon",
    addonMetadata = "Addon metadata", addonDependencies = "Dependencies",
    addonLoadOnDemand = "LoadOnDemand state", addonEnableState = "Enable state",
    addonEnableDisable = "Enable/disable next reload", addonLoadNow = "Load LoadOnDemand addon",
    addonUnload = "Unload a running addon", addonKill = "Terminate a running addon",
    savedVarSize = "SavedVariables size estimate", reloadUI = "Reload UI",
    instanceInfo = "Instance / zone info", groupSize = "Group size",
    combatMarkers = "Combat markers", encounterMarkers = "Encounter markers",
    keystoneMarkers = "Mythic+ markers", loadingMarkers = "Loading screen markers",
    zoneMarkers = "Zone change markers",
    physicalResolution = "Physical resolution",
    cvarMaxFPS = "CVar maxFPS", cvarMaxFPSBk = "CVar maxFPSBk",
    cvarTargetFPS = "CVar targetFPS", cvarRenderScale = "CVar renderScale",
    cvarVSync = "VSync",
    graphicsAPI = "Graphics API / GPU", osCPU = "OS CPU / GPU load",
    osMemory = "Process memory (non-Lua)", packetInspection = "Network packet inspection",
    fileAccess = "File system access", protectedActions = "Protected actions",
}

-- Display order for the System page.
Caps.GROUPS = {
    { title = "Timing",        keys = { "frameTime", "fps", "preciseClock", "percentiles" } },
    { title = "Network",       keys = { "latency", "bandwidth", "packetInspection" } },
    { title = "Memory",        keys = { "luaMemory", "addonMemory", "memoryGrowth", "gcEvents", "forceGC" } },
    { title = "CPU profiling", keys = { "addonCPU", "scriptCPU", "eventCPU", "frameCPU", "functionCPU", "toggleProfiling" } },
    { title = "Events",        keys = { "eventRate", "eventStorm", "eventToAddon", "frameCount", "onUpdateCount" } },
    { title = "Addon control", keys = { "addonMetadata", "addonDependencies", "addonLoadOnDemand",
                                        "addonEnableState", "addonEnableDisable", "addonLoadNow",
                                        "addonUnload", "addonKill", "savedVarSize", "reloadUI" } },
    { title = "Lua errors",    keys = { "errorCapture", "errorChaining", "errorStacks",
                                        "errorAttribution" } },
    { title = "Context",       keys = { "instanceInfo", "groupSize", "combatMarkers", "encounterMarkers",
                                        "keystoneMarkers", "loadingMarkers", "zoneMarkers" } },
    { title = "System",        keys = { "physicalResolution", "cvarMaxFPS", "cvarMaxFPSBk",
                                        "cvarTargetFPS", "cvarRenderScale", "cvarVSync",
                                        "graphicsAPI", "osCPU", "osMemory", "fileAccess", "protectedActions" } },
}

-- The vocabulary used everywhere a capability is shown, so the UI, the chat
-- report and the docs cannot drift apart.
Caps.STATE_LABEL = {
    yes     = "AVAILABLE",
    partial = "HEURISTIC",
    profile = "REQUIRES PROFILING",
    no      = "NOT POSSIBLE",
}
Caps.STATE_TONE = {
    yes = "ok", partial = "warn", profile = "warn", no = "muted",
}

local STATE_TEXT = {
    yes     = "|cff3fb950AVAILABLE|r",
    partial = "|cffd29922HEURISTIC|r",
    profile = "|cffd29922REQUIRES PROFILING|r",
    no      = "|cff5d6675NOT POSSIBLE|r",
}
Caps.STATE_TEXT = STATE_TEXT

--------------------------------------------------------------------------
-- First-run report
--------------------------------------------------------------------------
-- The headline capabilities, in the order someone reading it for the first
-- time cares about. Printed once on a fresh install and available any time
-- with /wtm caps.

Caps.HEADLINE = {
    "frameTime", "addonMemory", "addonCPU", "eventRate", "eventCPU",
    "latency", "addonEnableDisable", "addonUnload", "osCPU",
}

--- Returns an array of { label, state, stateText, note } for the headline set.
function Caps:GetHeadlineReport(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    for _, key in ipairs(self.HEADLINE) do
        local state, note = self:Get(key)
        out[#out + 1] = {
            key   = key,
            label = self.LABELS[key] or key,
            state = state,
            stateLabel = self.STATE_LABEL[state] or state,
            tone  = self.STATE_TONE[state] or "muted",
            note  = note,
        }
    end
    return out
end

--- Printed once, on the first login after installing.  Says what this client
--- can and cannot do before the user goes looking for a feature that was never
--- possible.
function Caps:PrintFirstRunReport()
    WTM:Print(("First run on %s. Checking what this client actually supports:")
        :format(Compat:GetClientLabel()))
    for _, entry in ipairs(self:GetHeadlineReport()) do
        WTM:Print(("   %-26s %s"):format(entry.label, STATE_TEXT[entry.state] or entry.state))
    end
    if not self.cpuProfiling and self:Has("toggleProfiling") then
        WTM:Print("Addon CPU needs the client's scriptProfile CVar. Open |cff4c8dff/wtm|r and use the button on the dashboard, or type |cff4c8dff/wtm profiling|r.")
    end
    WTM:Print("Full matrix: |cff4c8dff/wtm caps|r, or the System page.")
end

function Caps:PrintReport()
    WTM:Print(("Capability report - %s"):format(Compat:GetClientLabel()))
    WTM:Print("|cff5d6675Every line below was probed on this client at login, not inferred from its version.|r")
    for _, group in ipairs(self.GROUPS) do
        WTM:Print(("|cff9aa4b5%s|r"):format(group.title))
        for _, key in ipairs(group.keys) do
            local state, note = self:Get(key)
            WTM:Print(("   %-32s %s  |cff5d6675%s|r")
                :format(self.LABELS[key] or key, STATE_TEXT[state] or state, note or ""))
        end
    end
end
