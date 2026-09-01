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
            -- Fold spikes arriving close together into one stutter cluster.
            coalesce       = true,
            clusterWindow  = C.CLUSTER_WINDOW_SEC,
            -- Do not report loading screens, login, /reload or zone changes as
            -- freezes.  They are still counted, as suppressed.
            suppressLoading = true,
            suppressWarmup  = true,
            suppressBackground = true,
            warmupLogin    = C.WARMUP_LOGIN_SEC,
            warmupReload   = C.WARMUP_RELOAD_SEC,
            warmupZone     = C.WARMUP_ZONE_SEC,
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
            -- OFF | NORMAL | DETAILED, see C.EVENT_MODES
            mode             = "NORMAL",
            attributeAddons  = false,   -- opt-in: costs a full frame walk
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

        diagnostics = {
            -- How readily findings are reported.  "conservative" only surfaces
            -- what clears the correlation thresholds; "aggressive" also lists
            -- weak associations, clearly labelled as weak.
            aggressiveness = "balanced",   -- conservative | balanced | aggressive
        },

        dev = {
            enabled = false,   -- /wtm dev on
        },

        ui = {
            graphSmoothing = true,
            showGrid       = true,
            showPeaks      = true,
            showReferenceLines = true,   -- 60/144 fps and 16.7/6.9 ms guides
            timeRange      = "5m",
            graphUpdateRate = 0.5,
            -- How often the process list is allowed to re-sort.  Re-sorting on
            -- every refresh makes rows leapfrog while you are trying to read
            -- them, so it is throttled and paused while the mouse is over it.
            processResortInterval = 2.0,
            processSort    = "cpu",
            processSortAsc = false,
            hiddenAddons   = {},   -- name -> true, excluded from graphs
            watchedAddons  = {},   -- name -> true, flagged for diagnostics
        },
    },

    global = {
        -- schemaVersion is deliberately NOT defaulted.
        --
        -- Defaults are served through a metatable, so a defaulted key answers
        -- for data that was never actually written. A version stamp that
        -- reports the current version for an un-migrated database defeats the
        -- entire point of having one, so it is only ever read with rawget and
        -- only ever written by a migration.
        sessions  = {},
        incidents = {},
        clusters  = {},
        -- Set the first time the addon runs, so the capability report can be
        -- shown once rather than on every login.
        firstRunAt = nil,
        firstRunReportShown = false,
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

    if not db.global.firstRunAt then
        db.global.firstRunAt = time()
        self.isFirstRun = true
    end

    return db
end

--- Human-readable state of the stored database, shown on the System page.
function Database:DescribeSchema()
    if self.schemaFromFuture then
        return ("Stored database is schema version %d, this addon understands %d. It is being left untouched - update the addon rather than losing the data.")
            :format(self.schemaVersionFound or 0, C.SCHEMA_VERSION), "crit"
    end
    if self.schemaError then
        return ("Schema migration stopped: %s. Existing data has been left as-is.")
            :format(self.schemaError), "crit"
    end
    if (self.migrationsApplied or 0) > 0 then
        return ("Schema version %d (upgraded through %d migration%s at login).")
            :format(C.SCHEMA_VERSION, self.migrationsApplied,
                    self.migrationsApplied == 1 and "" or "s"), "ok"
    end
    return ("Schema version %d."):format(C.SCHEMA_VERSION), "muted"
end

--------------------------------------------------------------------------
-- Schema migrations
--------------------------------------------------------------------------
-- Each entry upgrades the database FROM the version in its key TO that key
-- plus one.  They run in order, so a database three versions behind is
-- brought forward one well-defined step at a time rather than being
-- reinterpreted in place.
--
-- Rules for adding one:
--   * bump C.SCHEMA_VERSION,
--   * add the step here keyed on the OLD version,
--   * never delete data you cannot reconstruct - drop it only when the new
--     shape genuinely cannot represent it, and say so in the comment.

local migrations = {}

--- 1 -> 2: the version key was renamed from `dbVersion` to `schemaVersion`,
--- and the cluster list was introduced alongside individual incidents.
migrations[1] = function(global)
    rawset(global, "schemaVersion", 2)
    rawset(global, "dbVersion", nil)
    global.clusters = global.clusters or {}
    -- Sessions gained spikeCount.suppressed; older ones simply have none,
    -- which reads correctly as zero rather than as missing.
    for _, session in ipairs(global.sessions or {}) do
        if session.spikeCount and session.spikeCount.suppressed == nil then
            session.spikeCount.suppressed = 0
        end
    end
end

Database.migrations = migrations

--- Returns the version actually STORED in the database, tolerating the
--- pre-rename key and a database that predates versioning entirely.
---
--- Uses rawget throughout: the defaults metatable would otherwise answer with
--- the current version for a database that has never been migrated, which
--- would silently skip every migration step.
function Database:DetectVersion(global)
    local stored = rawget(global, "schemaVersion")
    if type(stored) == "number" then return stored end

    local legacy = rawget(global, "dbVersion")
    if type(legacy) == "number" then return legacy end

    -- No version stamp at all. If there is data it was written before
    -- versioning existed, so it is version 1; if there is none this is a fresh
    -- install and starts at the current version.
    local sessions  = rawget(global, "sessions")
    local incidents = rawget(global, "incidents")
    local hasData = (sessions and #sessions > 0) or (incidents and #incidents > 0)
    return hasData and 1 or C.SCHEMA_VERSION
end

function Database:Migrate()
    local global = self.db.global
    local from = self:DetectVersion(global)

    self.schemaVersionFound = from
    if from > C.SCHEMA_VERSION then
        -- The database was written by a NEWER version of the addon.  Migrating
        -- backwards is not possible, so the data is left untouched and the
        -- addon runs read-only against it rather than corrupting it.
        self.schemaFromFuture = true
        return false
    end

    local applied = 0
    while from < C.SCHEMA_VERSION do
        local step = migrations[from]
        if not step then
            -- A gap in the migration chain is a bug, not something to guess
            -- around.  Stop here and report it rather than half-upgrading.
            self.schemaError = ("no migration from schema version %d"):format(from)
            return false
        end
        local ok, err = pcall(step, global)
        if not ok then
            self.schemaError = ("migration %d -> %d failed: %s"):format(from, from + 1, tostring(err))
            return false
        end
        applied = applied + 1
        from = from + 1
    end

    rawset(global, "schemaVersion", C.SCHEMA_VERSION)
    self.migrationsApplied = applied
    return true
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

    local clusters = g.clusters
    if clusters then
        local maxClusters = retention.maxIncidents or C.MAX_SAVED_INCIDENTS
        while #clusters > maxClusters do table.remove(clusters, 1) end
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
    for i = #(g.clusters or {}), 1, -1 do g.clusters[i] = nil end
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
