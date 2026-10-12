--[[--------------------------------------------------------------------------
    Compatibility/Retail.lua  --  Retail / Midnight 12.x

    The most capable client.  Everything optional is still probed rather than
    assumed, because Blizzard moves and renames things between major patches
    and this file must not become the reason the addon breaks on 12.2.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local M = {}
WTM._flavorModules.retail = M

function M.Apply(Compat)
    Compat.markerEvents = {
        combat    = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },
        zone      = { "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" },
        loading   = { "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED" },
        encounter = { "ENCOUNTER_START", "ENCOUNTER_END" },
        keystone  = { "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED" },
    }

    Compat.knownCVars = {
        "maxFPS", "maxFPSBk", "targetFPS", "renderScale",
        "vsync", "gxMaxFrameLatency",
        "graphicsQuality", "gxWindowedResolution", "gxFullscreenResolution",
        "scriptProfile", "scriptErrors", "uiScale", "useUiScale",
        "ffxGlow", "particleDensity",
    }

    Compat.unsupported = {}

    Compat.notes = "Retail: full feature set. Addon CPU figures still require scriptProfile."
end
