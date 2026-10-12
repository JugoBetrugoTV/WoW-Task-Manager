--[[--------------------------------------------------------------------------
    Compatibility/Classic.lua  --  Classic Era 1.15.x

    Classic Era runs on the modern engine, so the API surface is close to
    Retail minus the systems that never existed in 1.x.  What this file does is
    declare the *absences* so the UI can grey those features out instead of
    discovering them by erroring.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local M = {}
WTM._flavorModules.classic = M

function M.Apply(Compat)
    Compat.markerEvents = {
        combat    = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },
        zone      = { "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" },
        loading   = { "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED" },
        -- No encounter journal / instance-wide encounter events in 1.x.
        encounter = nil,
        keystone  = nil,
    }

    -- CVars that actually exist here.  Anything not listed is reported as
    -- "Unavailable on this client" rather than shown as an empty field.
    Compat.knownCVars = {
        "maxFPS", "maxFPSBk", "gxMaxFrameLatency",
        "vsync", "gxVSync",
        "graphicsQuality", "gxWindowedResolution", "gxFullscreenResolution",
        "scriptProfile", "scriptErrors", "uiScale", "useUiScale",
    }

    Compat.unsupported = {
        renderScale       = "Render scale is a Retail-only CVar",
        targetFPS         = "Adaptive target FPS is Retail-only",
        encounterMarkers  = "ENCOUNTER_START/END do not exist in Classic Era",
        keystoneMarkers   = "Mythic+ does not exist in Classic Era",
    }

    -- 1.15 has GetPhysicalScreenSize on most builds but it is not guaranteed;
    -- Capabilities.lua probes it and falls back to the UI-scaled screen size.
    Compat.notes = "Classic Era: encounter and keystone timeline markers are unavailable."
end
