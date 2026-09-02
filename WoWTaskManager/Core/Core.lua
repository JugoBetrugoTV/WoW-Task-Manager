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

    -- On a genuinely fresh install, say what this client can and cannot do
    -- before the user goes looking for a feature that was never possible.
    if WTM.Database.isFirstRun and not WTM.db.global.firstRunReportShown then
        WTM.db.global.firstRunReportShown = true
        WTM.Caps:PrintFirstRunReport()
    elseif WTM.db.profile.general.printOnLogin then
        WTM:Print(("v%s ready on %s. Type |cff4c8dff/wtm|r to open. Library backend: %s.")
            :format(C.VERSION, Compat:GetClientLabel(), Ace.Describe()))
        if not WTM.Caps.cpuProfiling then
            WTM:Print("Addon CPU profiling is off, so per-addon CPU is unavailable. Everything else works. |cff4c8dff/wtm profiling|r to enable it.")
        end
    end

    local schemaNote, schemaTone = WTM.Database:DescribeSchema()
    if schemaTone == "crit" then
        WTM:Print("|cfff0533f" .. schemaNote .. "|r")
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

commands["incidents"]   = function() OpenPage("incidents") end

commands["mini"] = function()
    if WTM.UI.LiveMonitor then WTM.UI.LiveMonitor:Toggle() end
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

commands["dev"] = function(rest)
    WTM.Dev:HandleCommand(rest)
end

commands["benchmark"] = function(rest)
    WTM.Dev:Benchmark(rest)
end

--==========================================================================
-- Command catalogue
--==========================================================================
--
-- The Settings page renders a button for every entry in this list, and /wtm
-- help prints the same list. Both read it; neither maintains its own copy.
-- A command that exists only in chat, or a button that fires something the
-- help text has never heard of, is not possible as long as this stays the
-- single source.
--
--   cmd      the word after /wtm ("" is the bare command)
--   label    what the button says
--   help     one line, used by /wtm help and as the button's tooltip
--   group    which section of the Settings page the button belongs to
--   arg      shown after the command in help when it takes one
--   confirm  destructive: the button asks before running
--
local COMMANDS = {
    { cmd = "",            label = "Open the window",      group = "window",
      help = "open the window" },
    { cmd = "dashboard",   label = "Dashboard",            group = "pages",
      help = "live metrics, graphs and this addon's own overhead" },
    { cmd = "processes",   label = "Processes",            group = "pages",
      help = "the addon list with CPU, memory, events and spikes" },
    { cmd = "performance", label = "Performance",          group = "pages",
      help = "frame time distribution, percentiles and the histogram" },
    { cmd = "timeline",    label = "Timeline",             group = "pages",
      help = "every metric on one shared time axis" },
    { cmd = "incidents",   label = "Incidents",            group = "pages",
      help = "recorded stutters with the seconds before and after them" },
    { cmd = "events",      label = "Events",               group = "pages",
      help = "event rates and storm detection" },
    { cmd = "memory",      label = "Memory",               group = "pages",
      help = "Lua heap, per-addon memory and observed growth" },
    { cmd = "diagnostics", label = "Diagnostics",          group = "pages",
      help = "findings, stated as associations rather than causes" },
    { cmd = "sessions",    label = "Sessions",             group = "pages",
      help = "saved history from previous play sessions" },
    { cmd = "system",      label = "System",               group = "pages",
      help = "client, hardware and capability report" },
    { cmd = "settings",    label = "Settings",             group = "pages",
      help = "this page" },
    { cmd = "hide",        label = "Close the window",     group = "window",
      help = "close the window" },
    { cmd = "mini",        label = "Toggle live monitor",  group = "window",
      help = "toggle the compact always-on monitor" },
    { cmd = "profiling",   label = "Toggle CPU profiling", group = "tools",
      help = "toggle the scriptProfile CVar - takes effect after a UI reload" },
    { cmd = "caps",        label = "Print capabilities",   group = "tools",
      help = "print the runtime capability report to chat" },
    { cmd = "overhead",    label = "Print own overhead",   group = "tools",
      help = "print this addon's own measured cost to chat" },
    { cmd = "benchmark",   label = "Run benchmark",        group = "tools", arg = "[seconds]",
      help = "measure this addon's own overhead over a few seconds and report it" },
    { cmd = "dev",         label = "Developer tools",      group = "tools", arg = "[subcommand]",
      help = "developer tools - injected data is always marked SIMULATED" },
    { cmd = "reset",       label = "Reset runtime counters", group = "tools", confirm = true,
      help = "reset this session's counters - saved history is untouched" },
    { cmd = "help",        label = "Print command list",   group = "tools",
      help = "print this list" },
}

WTM.COMMANDS = COMMANDS

--- The handler for a catalogue entry, so a button can run exactly what the
--- chat command runs.
function WTM:GetCommandHandler(cmd)
    return commands[cmd or ""]
end

commands["help"] = function()
    WTM:Print("Commands:")
    for _, entry in ipairs(COMMANDS) do
        local invocation = "/wtm" .. (entry.cmd ~= "" and (" " .. entry.cmd) or "")
        if entry.arg then invocation = invocation .. " " .. entry.arg end
        WTM:Print(("  |cff4c8dff%-24s|r %s"):format(invocation, entry.help))
    end
    WTM:Print("Every one of these is also a button on the Settings page.")
end

--- Receives the command string and nothing else; see
--- ConsoleMixin:RegisterChatCommand for why that guarantee is worth having.
local function HandleSlash(input)
    input = type(input) == "string" and input or ""
    local cmd, rest = input:match("^%s*(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()
    local handler = commands[cmd]
    if handler then
        handler(rest)
    else
        WTM:Print(("Unknown command '%s'."):format(cmd))
        commands["help"]()
    end
end

WTM:RegisterChatCommand("wtm", HandleSlash)
WTM:RegisterChatCommand("taskmanager", HandleSlash)
