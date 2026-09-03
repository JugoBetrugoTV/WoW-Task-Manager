--[[--------------------------------------------------------------------------
    WoW Task Manager - History/Sessions.lua

    One session per login.  Summary numbers are computed live so a crash still
    leaves a usable record; the heavy parts (buckets) are attached at logout.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat

local Sessions = WTM:NewModule("Sessions")
WTM.Sessions = Sessions

Sessions.current = nil

--------------------------------------------------------------------------
-- Session lifecycle
--------------------------------------------------------------------------

function Sessions:Begin()
    local _, class = UnitClass("player")
    local session = {
        id        = (WTM.db.char.lastSessionId or 0) + 1,
        startedAt = time(),
        startTime = GetTime(),
        character = UnitName("player"),
        realm     = GetRealmName(),
        class     = class,
        level     = UnitLevel("player"),
        flavor    = Compat.flavor,
        flavorName = Compat.flavorName,
        version   = Compat.version,
        build     = Compat.build,
        tocVersion = Compat.tocVersion,
        locale    = GetLocale(),
        addonVersion = C.VERSION,
        zone      = WTM.Context.state.zone,
        profilingEnabled = WTM.CPU.available,
    }
    WTM.db.char.lastSessionId = session.id
    self.current = session
    return session
end

--- Fills in everything derivable from the live modules.  Called both
--- periodically (so a disconnect still leaves good data) and at logout.
function Sessions:UpdateSummary()
    local session = self.current
    if not session then return end

    local stats = WTM.FrameTime:GetSessionStats()
    session.duration   = GetTime() - session.startTime
    session.endedAt    = time()
    session.frames     = stats.frames
    session.avgFPS     = stats.avgFPS
    session.minFPS     = stats.minFPS
    session.low1       = stats.low1
    session.low01      = stats.low01
    session.maxFrameMs = stats.maxMs
    session.medianMs   = stats.medianMs

    session.spikeCount = {
        minor   = WTM.SpikeDetector.counts.minor or 0,
        stutter = WTM.SpikeDetector.counts.stutter or 0,
        heavy   = WTM.SpikeDetector.counts.heavy or 0,
        freeze  = WTM.SpikeDetector.counts.freeze or 0,
        total   = WTM.SpikeDetector.total,
    }

    local avgHome, avgWorld = WTM.Network:GetAverages()
    session.avgLatencyHome  = avgHome
    session.avgLatencyWorld = avgWorld
    session.peakLatencyHome  = WTM.Network.session.peakHome
    session.peakLatencyWorld = WTM.Network.session.peakWorld
    session.latencySpikes    = WTM.Network.session.spikes

    local mem = WTM.Memory.current
    session.luaStartKB = mem.luaStartKB
    session.luaEndKB   = mem.luaKB
    session.luaPeakKB  = mem.luaPeakKB
    session.heapDrops  = WTM.Memory.heapDrops.events

    session.eventTotal    = WTM.Events.current.total
    session.eventPeakRate = WTM.Events.current.peakPerSecond
    session.eventStorms   = #WTM.Events.storms

    session.topCPU    = self:BuildTopCPU()
    session.topMemory = self:BuildTopMemory()

    session.zone = WTM.Context.state.zone or session.zone
    return session
end

function Sessions:BuildTopCPU()
    if not WTM.CPU.available then return nil end
    local out = {}
    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]
        if record.loaded and record.cpuSamples > 0 then
            local avg = WTM.CPU:GetAverage(record)
            if avg > 0.05 then
                out[#out + 1] = {
                    name = record.name, avgPct = avg,
                    peakPct = record.cpuPeakPct, spikes = record.spikes,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.avgPct > b.avgPct end)
    for i = #out, C.MAX_TOP_LISTS + 1, -1 do out[i] = nil end
    return out
end

function Sessions:BuildTopMemory()
    local out = {}
    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]
        if record.loaded and record.memStartKB then
            local growth = record.memKB - record.memStartKB
            out[#out + 1] = { name = record.name, growthKB = growth, endKB = record.memKB }
        end
    end
    table.sort(out, function(a, b) return a.growthKB > b.growthKB end)
    for i = #out, C.MAX_TOP_LISTS + 1, -1 do out[i] = nil end
    return out
end

--- Writes the session into SavedVariables, newest first.
function Sessions:Finalize()
    local session = self:UpdateSummary()
    if not session then return end
    if (session.duration or 0) < 30 then
        -- A 10-second login is not a session worth keeping.
        return
    end

    local stored = {}
    for k, v in pairs(session) do
        if k ~= "startTime" then stored[k] = v end
    end

    if WTM.db.profile.retention.saveBuckets then
        stored.buckets = WTM.Recorder:ExportBuckets()
        stored.bucketFields = C.BUCKET_FIELDS
    end

    stored.spikes = self:ExportSpikes()

    local sessions = WTM.db.global.sessions
    table.insert(sessions, 1, stored)
    WTM.Database:Prune()
end

--- Spike records, stripped to what is worth keeping across a login.
function Sessions:ExportSpikes()
    local out = {}
    local spikes = WTM.SpikeDetector.spikes
    for i = 1, #spikes do
        local spike = spikes[i]
        local entry = {
            rel     = spike.t - (self.current and self.current.startTime or 0),
            epoch   = spike.epoch,
            kind    = spike.kind,
            frameMs = spike.frameMs,
            latWorld = spike.latWorld,
            zone    = spike.context and spike.context.zone,
            combat  = spike.context and spike.context.combat,
        }
        if spike.cpu and #spike.cpu > 0 then
            entry.cpu = {}
            for j = 1, math.min(3, #spike.cpu) do
                entry.cpu[j] = { spike.cpu[j].name, spike.cpu[j].deltaMs }
            end
        end
        if spike.events and #spike.events > 0 then
            entry.events = {}
            for j = 1, math.min(3, #spike.events) do
                entry.events[j] = { spike.events[j].event, spike.events[j].count }
            end
        end
        out[#out + 1] = entry
    end
    -- Cap so a pathological session cannot bloat the file.
    while #out > 150 do table.remove(out, 1) end
    return out
end

--------------------------------------------------------------------------
-- Reading past sessions
--------------------------------------------------------------------------

--- The live session in the same shape as a stored one, so anything that reads
--- stored sessions (the compare page, the sessions list) can take the current
--- one without a second code path. Summary fields are brought up to date
--- first; this is the same work the periodic update does, so calling it costs
--- one pass over already-sampled numbers.
function Sessions:LiveSnapshot()
    if not self.current then return nil end
    self:UpdateSummary()
    self.current.isLive = true
    return self.current
end

function Sessions:GetStored()
    return WTM.db.global.sessions
end

function Sessions:Get(index)
    return WTM.db.global.sessions[index]
end

function Sessions:Delete(index)
    table.remove(WTM.db.global.sessions, index)
end

--- Reads a stored session's buckets back into the array shape the graph
--- widget expects.
function Sessions:GetStoredSeries(session, fieldName, outValues, outTimes)
    outValues = outValues or {}
    outTimes  = outTimes or {}
    for i = #outValues, 1, -1 do outValues[i] = nil end
    for i = #outTimes, 1, -1 do outTimes[i] = nil end

    local buckets = session and session.buckets
    if not buckets or #buckets == 0 then return outValues, outTimes, false end

    local field = WTM.Recorder.FIELDS[fieldName]
    if not field then return outValues, outTimes, false end

    local base = buckets[1][1]
    for i = 1, #buckets do
        outValues[i] = buckets[i][field]
        outTimes[i]  = buckets[i][1] - base
    end
    return outValues, outTimes, true
end

function Sessions:Describe(session)
    local Fmt = WTM.Format
    if not session then return "-" end
    return ("%s  %s-%s  %s  avg %s FPS, 1%% low %s, %d spikes")
        :format(Fmt.DateTime(session.startedAt),
                session.character or "?", session.realm or "?",
                Fmt.Duration(session.duration or 0),
                Fmt.FPS(session.avgFPS or 0),
                Fmt.FPS(session.low1 or 0),
                (session.spikeCount and session.spikeCount.total) or 0)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Sessions:OnEnable()
    self:Begin()
    -- Refresh the summary periodically so a disconnect or crash still leaves
    -- a usable record behind, not just an empty stub.
    WTM.Scheduler:Register("session", function() Sessions:UpdateSummary() end, 30, 30, 0.95, "sampler")
end

function Sessions:OnDisable()
    self:Finalize()
end
