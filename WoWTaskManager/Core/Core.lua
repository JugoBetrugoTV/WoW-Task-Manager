--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Core.lua

    The addon object, the module registry and the boot sequence.

    Boot order:
        file load  ->  Compat.ApplyFlavorModule()
        ADDON_LOADED(WoWTaskManager)  ->  Database, Capabilities, module:Init()
        PLAYER_LOGIN                  ->  module:Enable(), sampling starts
        PLAYER_LOGOUT                 ->  Sessions:Finalize(), Database:Prune()
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local Compat = WTM.Compat
local C      = WTM.C
local Ace    = WTM.Ace

_G.WoWTaskManager = WTM

WTM.name    = ADDON_NAME
WTM.version = C.VERSION

Ace.Embed(WTM)

--------------------------------------------------------------------------
-- Module registry
--------------------------------------------------------------------------
-- A module is a plain table with optional OnInitialize / OnEnable / OnDisable.
-- Modules are enabled in registration order, which Includes.xml controls.

local modules      = {}
local moduleOrder  = {}
WTM.modules = modules

function WTM:NewModule(name)
    if modules[name] then return modules[name] end
    local module = { moduleName = name, enabled = false }
    Ace.Embed(module)
    modules[name] = module
    moduleOrder[#moduleOrder + 1] = name
    return module
end

function WTM:GetModule(name)
    return modules[name]
end

function WTM:IterateModules()
    local i = 0
    return function()
        i = i + 1
        local name = moduleOrder[i]
        if name then return name, modules[name] end
    end
end

local function CallModule(module, method, ...)
    local fn = module[method]
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, module, ...)
    if not ok then
        geterrorhandler()(("%s: %s.%s failed: %s"):format(ADDON_NAME, module.moduleName, method, tostring(err)))
        return false
    end
    return true
end
WTM.CallModule = CallModule

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------

WTM.state = {
    initialized = false,
    enabled     = false,
    loginTime   = nil,
    sessionStart = nil,
    sessionEpoch = nil,
}

local function Initialize()
    if WTM.state.initialized then return end

    Compat.ApplyFlavorModule()

    WTM.Database:Initialize()
    WTM.Caps:Detect()

    for name, module in WTM:IterateModules() do
        CallModule(module, "OnInitialize")
    end

    WTM.state.initialized = true
end

local function Enable()
    if WTM.state.enabled or not WTM.state.initialized then return end

    WTM.state.loginTime    = GetTime()
    WTM.state.sessionStart = GetTime()
    WTM.state.sessionEpoch = time()

    for name, module in WTM:IterateModules() do
        if CallModule(module, "OnEnable") ~= false then
            module.enabled = true
        end
    end

    -- Modules have registered their tasks by now, so the sampling driver can
    -- start.  Nothing runs before this point: the single OnUpdate stays hidden
    -- until every task exists.
    if WTM.db.profile.sampling.enabled then
        WTM.Scheduler:Start()
    end

    WTM.state.enabled = true
    WTM:SendMessage("WTM_ENABLED")

    if WTM.db.profile.general.printOnLogin then
        WTM:Print(("v%s ready on %s. Type |cff4c8dff/wtm|r to open. Library backend: %s.")
            :format(C.VERSION, Compat:GetClientLabel(), Ace.Describe()))
        if not WTM.Caps.cpuProfiling then
            WTM:Print("CPU profiling is off - addon CPU figures are unavailable. |cff4c8dff/wtm profiling|r to enable.")
        end
    end
end

local function Shutdown()
    if not WTM.state.enabled then return end
    WTM:SendMessage("WTM_SHUTDOWN")
    for name, module in WTM:IterateModules() do
        CallModule(module, "OnDisable")
    end
    WTM.Scheduler:Stop()
    WTM.state.enabled = false
end

--------------------------------------------------------------------------
-- Lifecycle events
--------------------------------------------------------------------------

local boot = CreateFrame("Frame", "WTMBootstrap")
Compat.SafeRegisterEvent(boot, "ADDON_LOADED")
Compat.SafeRegisterEvent(boot, "PLAYER_LOGIN")
Compat.SafeRegisterEvent(boot, "PLAYER_LOGOUT")
Compat.SafeRegisterEvent(boot, "PLAYER_REGEN_ENABLED")

boot:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            Initialize()
            boot:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        Initialize()   -- no-op if ADDON_LOADED already ran
        Enable()
    elseif event == "PLAYER_LOGOUT" then
        Shutdown()
    elseif event == "PLAYER_REGEN_ENABLED" then
        local n = Compat.FlushCombatQueue()
        if n > 0 then
            WTM:SendMessage("WTM_COMBAT_QUEUE_FLUSHED", n)
        end
    end
end)

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

local function OpenPage(page)
    if WTM.UI and WTM.UI.MainWindow then
        WTM.UI.MainWindow:Open(page)
    else
        WTM:Print("UI is not available yet.")
    end
end

local commands = {}

commands[""] = function() OpenPage() end

commands["show"]        = function() OpenPage() end
commands["dashboard"]   = function() OpenPage("dashboard") end
commands["processes"]   = function() OpenPage("processes") end
commands["performance"] = function() OpenPage("performance") end
commands["timeline"]    = function() OpenPage("timeline") end
commands["events"]      = function() OpenPage("events") end
commands["memory"]      = function() OpenPage("memory") end
commands["diagnostics"] = function() OpenPage("diagnostics") end
commands["sessions"]    = function() OpenPage("sessions") end
commands["system"]      = function() OpenPage("system") end
commands["settings"]    = function() OpenPage("settings") end

commands["hide"] = function()
    if WTM.UI and WTM.UI.MainWindow then WTM.UI.MainWindow:Close() end
end

commands["profiling"] = function()
    WTM.Caps:ToggleCPUProfiling()
end

commands["reset"] = function()
    WTM.Database:ResetRuntime()
    WTM:Print("Runtime counters reset.")
end

commands["overhead"] = function()
    local o = WTM:GetModule("Overhead")
    if o then WTM:Print(o:Describe()) end
end

commands["caps"] = function()
    WTM.Caps:PrintReport()
end

commands["help"] = function()
    WTM:Print("Commands:")
    WTM:Print("  |cff4c8dff/wtm|r                open the window")
    WTM:Print("  |cff4c8dff/wtm <page>|r         dashboard | processes | performance | timeline |")
    WTM:Print("                        events | memory | diagnostics | sessions | system | settings")
    WTM:Print("  |cff4c8dff/wtm profiling|r      toggle the scriptProfile CVar (needs /reload)")
    WTM:Print("  |cff4c8dff/wtm caps|r           print the runtime capability report")
    WTM:Print("  |cff4c8dff/wtm overhead|r       print this addon's own cost")
    WTM:Print("  |cff4c8dff/wtm reset|r          reset runtime counters")
end

local function HandleSlash(_, input)
    local cmd = (input or ""):lower():match("^%s*(%S*)") or ""
    local handler = commands[cmd]
    if handler then
        handler()
    else
        WTM:Print(("Unknown command '%s'."):format(cmd))
        commands["help"]()
    end
end

WTM:RegisterChatCommand("wtm", HandleSlash)
WTM:RegisterChatCommand("taskmanager", HandleSlash)
