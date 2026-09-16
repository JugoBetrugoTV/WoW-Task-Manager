--[[--------------------------------------------------------------------------
    Compatibility/Mists.lua  --  Mists of Pandaria Classic 5.5.x

    The first target client with encounter broadcasts and challenge modes.
    Retail-only graphics CVars (renderScale, targetFPS) still do not exist.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local M = {}
WTM._flavorModules.mop = M

function M.Apply(Compat)
    Compat.markerEvents = {
        combat    = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },
        zone      = { "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" },
        loading   = { "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED" },
        encounter = { "ENCOUNTER_START", "ENCOUNTER_END" },
        keystone  = { "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED" },
    }

    Compat.knownCVars = {
        "maxFPS", "maxFPSBk", "gxMaxFrameLatency",
        "vsync", "gxVSync",
        "graphicsQuality", "gxWindowedResolution", "gxFullscreenResolution",
        "scriptProfile", "scriptErrors", "uiScale", "useUiScale",
    }

    Compat.unsupported = {
        renderScale = "Render scale is a Retail-only CVar",
        targetFPS   = "Adaptive target FPS is Retail-only",
    }

    Compat.notes = "MoP Classic: encounter markers available, Retail-only graphics CVars are not."
end
