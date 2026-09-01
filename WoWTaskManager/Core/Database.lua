--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Database.lua

    SavedVariables layout, defaults and retention.

    The single most important job here is keeping WoWTaskManagerDB small.  A
    naive recorder writing one row per second for a four-hour raid night would
    produce ~14k rows per session; with tiered aggregation and array-shaped
    buckets the same session lands in the low hundreds of kilobytes.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Ace    = WTM.Ace
local Compat = WTM.Compat

local Database = {}
WTM.Database = Database

--------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------

local defaults = {
    profile = {
        general = {
            printOnLogin      = true,
            openOnSpike       = false,
            minimapButton     = true,
            scale             = 1.0,
            windowWidth       = 1180,
            windowHeight      = 720,
            lastPage          = "dashboard",
        },

        sampling = {
            enabled           = true,
            adaptive          = true,
            burstDuration     = C.BURST_DURATION_SEC,
            intervals = {
                frametime = C.SAMPLE_DEFAULTS.frametime.normal,
                events    = C.SAMPLE_DEFAULTS.events.normal,
                luamem    = C.SAMPLE_DEFAULTS.luamem.normal,
                cpu       = C.SAMPLE_DEFAULTS.cpu.normal,
                network   = C.SAMPLE_DEFAULTS.network.normal,
                memory    = C.SAMPLE_DEFAULTS.memory.normal,
                history   = C.SAMPLE_DEFAULTS.history.normal,
                ui        = C.SAMPLE_DEFAULTS.ui.normal,
            },
            overheadBudgetMs  = C.OVERHEAD_BUDGET_MS_PER_SEC,
            autoThrottle      = true,
        },

        spikes = {
            enabled  = true,
            debounce = C.SPIKE_DEBOUNCE_SEC,
            minor    = { absMs = C.SPIKE_DEFAULTS.minor.absMs,   mult = C.SPIKE_DEFAULTS.minor.mult   },
            stutter  = { absMs = C.SPIKE_DEFAULTS.stutter.absMs, mult = C.SPIKE_DEFAULTS.stutter.mult },
            heavy    = { absMs = C.SPIKE_DEFAULTS.heavy.absMs,   mult = C.SPIKE_DEFAULTS.heavy.mult   },
            freeze   = { absMs = C.SPIKE_DEFAULTS.freeze.absMs,  mult = C.SPIKE_DEFAULTS.freeze.mult  },
            -- The minimum severity that produces a stored flight-recorder incident.
            captureFrom = "stutter",
        },

        flightRecorder = {
            enabled    = true,
            preWindow  = C.FR_PRE_WINDOW_SEC,
            postWindow = C.FR_POST_WINDOW_SEC,
            persist    = true,
        },

        events = {
            enabled          = true,
            attributeAddons  = false,   -- opt-in: costs a frame walk
            stormMultiplier  = C.EVENT_STORM_MULTIPLIER,
            stormMinRate     = C.EVENT_STORM_MIN_RATE,
        },

        memory = {
            enabled          = true,
            estimateSavedVars = false,  -- opt-in: walks addon global tables
            growthThresholdKBPerMin = C.MEM_GROWTH_KB_PER_MIN,
        },

        retention = {
            maxSessions   = C.MAX_SESSIONS,
            maxIncidents  = C.MAX_SAVED_INCIDENTS,
            saveBuckets   = true,
            saveIncidents = true,
        },

        ui = {
            graphSmoothing = true,
            showGrid       = true,
            showPeaks      = true,
            timeRange      = "5m",
            processSort    = "cpu",
            processSortAsc = false,
            hiddenAddons   = {},   -- name -> true, excluded from graphs
            watchedAddons  = {},   -- name -> true, flagged for diagnostics
        },
    },

    global = {
        dbVersion = C.DB_VERSION,
        sessions  = {},
        incidents = {},
    },

    char = {
        lastSessionId = 0,
    },
}

Database.defaults = defaults

--------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------

function Database:Initialize()
    local db, backend = Ace.NewDB("WoWTaskManagerDB", defaults)
    WTM.db = db
    self.db = db
    self.backend = backend

    self:Migrate()
    self:Prune()
    return db
end

function Database:Migrate()
    local g = self.db.global
    local from = g.dbVersion or 0
    if from == C.DB_VERSION then return end

    if from == 0 then
        -- Fresh install, or a pre-versioning database.  Nothing to move.
        g.sessions  = g.sessions or {}
        g.incidents = g.incidents or {}
    end

    -- Future migrations chain here, oldest first.

    g.dbVersion = C.DB_VERSION
end

--------------------------------------------------------------------------
-- Retention
--------------------------------------------------------------------------
-- Called on login and on logout.  Trimming on both ends means a crash between
-- them cannot leave the database unbounded.

function Database:Prune()
    local g = self.db.global
    local retention = self.db.profile.retention

    local sessions = g.sessions
    if sessions then
        -- Newest first is the storage order, so trimming means dropping the tail.
        local maxSessions = retention.maxSessions or C.MAX_SESSIONS
        for i = #sessions, maxSessions + 1, -1 do
            sessions[i] = nil
        end
        -- Buckets are the bulk of the payload: drop them from all but the
        -- newest few sessions, keeping the summary numbers.
        local keepBuckets = math.min(5, maxSessions)
        for i = keepBuckets + 1, #sessions do
            if sessions[i] then sessions[i].buckets = nil end
        end
    end

    local incidents = g.incidents
    if incidents then
        local maxIncidents = retention.maxIncidents or C.MAX_SAVED_INCIDENTS
        for i = #incidents, maxIncidents + 1, -1 do
            incidents[i] = nil
        end
    end
end

--- Rough size estimate of the saved database, so the Settings page can show
--- what the retention settings actually cost.  Walks the table once on demand.
local function EstimateSize(value, depth)
    depth = (depth or 0) + 1
    if depth > 12 then return 0 end
    local t = type(value)
    if t == "number" then return 8
    elseif t == "boolean" then return 4
    elseif t == "string" then return #value + 17
    elseif t ~= "table" then return 0 end

    local total = 40
    for k, v in pairs(value) do
        total = total + EstimateSize(k, depth) + EstimateSize(v, depth) + 16
    end
    return total
end

function Database:EstimateSizeBytes()
    return EstimateSize(_G.WoWTaskManagerDB or {})
end

--------------------------------------------------------------------------
-- Runtime reset
--------------------------------------------------------------------------

function Database:ResetRuntime()
    WTM:SendMessage("WTM_RESET_RUNTIME")
end

function Database:WipeHistory()
    local g = self.db.global
    for i = #g.sessions, 1, -1 do g.sessions[i] = nil end
    for i = #g.incidents, 1, -1 do g.incidents[i] = nil end
end

function Database:WipeAddonHistory(addonName)
    local g = self.db.global
    for _, session in ipairs(g.sessions) do
        if session.topCPU then
            for i = #session.topCPU, 1, -1 do
                if session.topCPU[i].name == addonName then table.remove(session.topCPU, i) end
            end
        end
        if session.topMemory then
            for i = #session.topMemory, 1, -1 do
                if session.topMemory[i].name == addonName then table.remove(session.topMemory, i) end
            end
        end
    end
    for _, incident in ipairs(g.incidents) do
        if incident.cpu then
            for i = #incident.cpu, 1, -1 do
                if incident.cpu[i].name == addonName then table.remove(incident.cpu, i) end
            end
        end
    end
end

--------------------------------------------------------------------------
-- Convenience accessors used across the UI
--------------------------------------------------------------------------

function Database:Profile() return self.db.profile end
function Database:Global()  return self.db.global end

function Database:IsHidden(addonName)
    return self.db.profile.ui.hiddenAddons[addonName] == true
end

function Database:SetHidden(addonName, hidden)
    self.db.profile.ui.hiddenAddons[addonName] = hidden or nil
end

function Database:IsWatched(addonName)
    return self.db.profile.ui.watchedAddons[addonName] == true
end

function Database:SetWatched(addonName, watched)
    self.db.profile.ui.watchedAddons[addonName] = watched or nil
end
