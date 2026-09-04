--[[--------------------------------------------------------------------------
    Compatibility/TBC.lua  --  Burning Crusade Anniversary 2.5.x

    Same modern engine as Classic Era.  Raid encounters exist as content but
    the ENCOUNTER_START/END broadcast events do not, so encounter markers stay
    off here as well.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local M = {}
WTM._flavorModules.tbc = M

function M.Apply(Compat)
    Compat.markerEvents = {
        combat    = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },
        zone      = { "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" },
        loading   = { "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED" },
        encounter = nil,
        keystone  = nil,
    }

    Compat.knownCVars = {
        "maxFPS", "maxFPSBk", "gxMaxFrameLatency",
        "vsync", "gxVSync",
        "graphicsQuality", "gxWindowedResolution", "gxFullscreenResolution",
        "scriptProfile", "scriptErrors", "uiScale", "useUiScale",
    }

    Compat.unsupported = {
        renderScale      = "Render scale is a Retail-only CVar",
        targetFPS        = "Adaptive target FPS is Retail-only",
        encounterMarkers = "ENCOUNTER_START/END are not broadcast in 2.5.x",
        keystoneMarkers  = "Mythic+ does not exist in this client",
    }

    Compat.notes = "TBC Anniversary: encounter markers fall back to combat markers."
end
