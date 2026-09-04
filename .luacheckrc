-- luacheck configuration for a World of Warcraft addon.
--
-- Advisory only: no list of WoW globals is ever complete, so this is tuned to
-- surface real mistakes (typos, unused locals, shadowing) without drowning
-- them in "undefined global" noise for every API the client provides.

std = "lua51"
max_line_length = false
codes = true

-- The addon namespace is passed in via the vararg of every file.
globals = {
    "WoWTaskManager", "WoWTaskManagerDB",
    "SLASH_WTM_WTM1", "SLASH_WTM_TASKMANAGER1",
}

read_globals = {
    -- Core
    "CreateFrame", "UIParent", "WorldFrame", "GetTime", "GetTimePreciseSec",
    "debugprofilestop", "debugprofilestart", "collectgarbage", "geterrorhandler",
    "securecall", "issecurevariable", "hooksecurefunc", "EnumerateFrames",
    "wipe", "tinsert", "tremove", "strsplit", "date", "time", "bit",
    "DEFAULT_CHAT_FRAME", "SlashCmdList", "UISpecialFrames", "CreateColor",
    "GetCursorPosition", "GetScreenWidth", "GetScreenHeight",
    "GetPhysicalScreenSize", "InCombatLockdown", "IsResting", "ReloadUI",

    -- Player / world
    "UnitName", "UnitClass", "UnitLevel", "UnitAffectingCombat",
    "GetRealmName", "GetLocale", "GetBuildInfo", "GetFramerate", "GetNetStats",
    "GetRealZoneText", "GetZoneText", "GetInstanceInfo", "GetNumGroupMembers",
    "IsEncounterInProgress",

    -- Addon + profiling APIs (globals on every current client)
    "GetNumAddOns", "GetAddOnInfo", "GetAddOnMetadata", "IsAddOnLoaded",
    "IsAddOnLoadOnDemand", "LoadAddOn", "EnableAddOn", "DisableAddOn",
    "GetAddOnEnableState", "GetAddOnDependencies", "GetAddOnOptionalDependencies",
    "UpdateAddOnCPUUsage", "GetAddOnCPUUsage", "UpdateAddOnMemoryUsage",
    "GetAddOnMemoryUsage", "ResetCPUUsage", "GetScriptCPUUsage",
    "GetEventCPUUsage", "GetFrameCPUUsage", "GetFunctionCPUUsage",

    -- CVars
    "GetCVar", "SetCVar", "GetCVarBool", "GetCVarDefault", "GetCVarInfo",

    -- Namespaces, all feature-detected in Core/Compat.lua
    "C_AddOns", "C_CVar", "C_Timer", "LibStub",

    -- Project constants
    "WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE", "WOW_PROJECT_CLASSIC",
    "WOW_PROJECT_BURNING_CRUSADE_CLASSIC", "WOW_PROJECT_MISTS_CLASSIC",
}

exclude_files = { "WoWTaskManager/Libs/**" }

files["tools/*.lua"] = {
    -- The mock deliberately defines the WoW API as globals.
    ignore = { "111", "112", "113", "121", "122", "131", "142", "143" },
}
