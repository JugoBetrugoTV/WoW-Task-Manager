--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/SpikeDetector.lua

    Turns "the game hitched" into a record you can read afterwards.

    Detection is two-sided: a frame counts as a spike only if it exceeds BOTH
    an absolute floor AND a multiple of the rolling baseline.

        absolute only  -> a 144 Hz player drowns in "spikes" at 20 ms
        relative only  -> a 25 Hz player never registers one at all

    Three things happen around a detected spike:

      1. Monitoring/Suppression decides whether it is real stutter at all.
         Loading screens, login, /reload and zone changes are counted as
         suppressed rather than reported as freezes.
      2. Spikes close together are folded into one STUTTER CLUSTER carrying the
         peak, the duration and the affected frame count - a stutter is rarely
         one bad frame, and a wall of near-identical incidents hides that.
      3. The flight recorder is asked for a capture, which completes after the
         post-roll rather than immediately.

    What this module deliberately does NOT do is name a culprit. It records
    what was busy at the same time. Two things follow from GetAddOnCPUUsage
    being CUMULATIVE and sampled on an interval:

      * CPU attached to a spike is always described as used "within the
        observation window", never as part of the spiking frame. A 31 ms CPU
        delta measured across 1.4 s says nothing about which 84 ms frame in
        that window it landed on.
      * Analysis/Correlation decides how strongly an association may be worded,
        and the strongest available phrase is "Strongly correlated".
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat

local SpikeDetector = WTM:NewModule("SpikeDetector")
WTM.SpikeDetector = SpikeDetector

SpikeDetector.spikes   = {}   -- individual spike records, bounded
SpikeDetector.clusters = {}   -- coalesced stutter clusters, bounded
SpikeDetector.counts   = { minor = 0, stutter = 0, heavy = 0, freeze = 0 }
SpikeDetector.total    = 0
SpikeDetector.suppressed = 0
-- When the most recent spike was recorded, for "time since last spike".
-- Public because several summary panels want it; the internal `lastSpikeAt`
-- upvalue drives debouncing and is deliberately separate.
SpikeDetector.lastSpikeAt = nil

local MAX_SPIKES = 300
local lastSpikeAt = 0
local lastSpikeSeverity = 0

-- The cluster currently being built, if any.
local openCluster = nil

--------------------------------------------------------------------------
-- Classification
--------------------------------------------------------------------------

local ORDER = { "freeze", "heavy", "stutter", "minor" }

--- Returns the spike kind for a frame time, or nil.
---
--- Normally BOTH rules must agree: the frame must exceed an absolute floor and
--- a multiple of the rolling baseline. Until the baseline has settled, only the
--- absolute rule applies - an unsettled baseline can be seeded by the very
--- hitch it is meant to catch, and a rule that can be poisoned by its own
--- subject is worse than no rule.
function SpikeDetector:Classify(frameMs, baselineMs)
    local settings = WTM.db.profile.spikes
    if not settings.enabled then return nil end

    local relativeReady = WTM.FrameTime:IsBaselineReady()
    baselineMs = (baselineMs and baselineMs > 0) and baselineMs or 16.67

    for i = 1, #ORDER do
        local kind = ORDER[i]
        local cfg = settings[kind]
        if cfg and frameMs >= cfg.absMs
           and (not relativeReady or frameMs >= baselineMs * cfg.mult) then
            return kind
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Detection pass (runs on the frame-time cadence)
--------------------------------------------------------------------------

function SpikeDetector:Check()
    self:ExpireCluster()

    local frameMs, at = WTM.FrameTime:ConsumePendingSpike()
    if not frameMs then return end

    local baseline = WTM.FrameTime:GetBaseline()
    local kind = self:Classify(frameMs, baseline)
    if not kind then return end

    -- Is this real stutter, or the client doing something expected?
    local suppressedReason = WTM.Suppression:Check()
    if suppressedReason then
        WTM.Suppression:Record(suppressedReason)
        self.suppressed = self.suppressed + 1
        return
    end

    local severity = C.SPIKE_ORDER[kind] or 1
    local now = GetTime()
    local debounce = WTM.db.profile.spikes.debounce

    -- A long freeze produces several oversized frames in a row. One incident is
    -- useful; four is noise. A MORE severe spike is always let through, so a
    -- stutter escalating into a freeze is not swallowed.
    if (now - lastSpikeAt) < debounce and severity <= lastSpikeSeverity then
        -- Still worth counting towards the open cluster's affected-frame tally.
        if openCluster then
            openCluster.frames = openCluster.frames + 1
            openCluster.endedAt = at or now
            if frameMs > openCluster.peakMs then openCluster.peakMs = frameMs end
        end
        return
    end
    lastSpikeAt = now
    SpikeDetector.lastSpikeAt = now
    lastSpikeSeverity = severity

    self:Record(kind, frameMs, at or now, baseline)
end

--------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------

function SpikeDetector:Record(kind, frameMs, at, baselineMs, simulated)
    local net = WTM.Network.current

    local spike = {
        t          = at,
        epoch      = time(),
        kind       = kind,
        label      = C.SPIKE_DEFAULTS[kind].label,
        frameMs    = frameMs,
        fps        = frameMs > 0 and (1000 / frameMs) or 0,
        baselineMs = baselineMs,
        latHome    = net.latencyHome,
        latWorld   = net.latencyWorld,
        latStale   = WTM.Network:IsStale(),
        latAgeSec  = GetTime() - (net.lastChangeAt or GetTime()),
        luaKB      = WTM.Memory.current.luaKB,
        eventRate  = WTM.Events.current.perSecond,
        context    = WTM.Context:Capture(),
        simulated  = simulated or nil,
    }

    -- What was unusually busy around the spike.
    --
    -- Sample out of band first: spikes are detected on the frame-time cadence
    -- while CPU samples far more slowly, so the deltas sitting in the records
    -- right now may describe a window that ended BEFORE the hitch. The window
    -- bounds are recorded alongside the numbers precisely because they are what
    -- makes the figures interpretable.
    if WTM.CPU.available then
        local before = WTM.CPU.current.lastSampleAt
        WTM.CPU:SampleNow(0.2)
        spike.cpu = WTM.CPU:GetWindowDeltas(nil, 5, 0.5)
        spike.totalCpuPct = WTM.CPU.current.totalPct
        spike.cpuWindow = {
            startedAt = before,
            endedAt   = WTM.CPU.current.lastSampleAt,
            seconds   = WTM.CPU.current.sampleWindowSec,
        }
    else
        spike.cpuUnavailable = WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
    end

    spike.events = WTM.Events:SnapshotTop(nil, 8)
    spike.storms = WTM.Events:GetActiveStorms(nil)
    spike.memory = self:MemorySnapshot()
    spike.memoryTotalKB = WTM.Memory.current.luaKB
    spike.memoryGrowthKBPerMin = WTM.Memory.current.growthKBPerMin

    -- Credit the addons that were above their OWN normal, not the ones that
    -- are simply always busy.
    if spike.cpu then
        for i = 1, #spike.cpu do
            local entry = spike.cpu[i]
            local record = WTM.Processes:Get(entry.name)
            if record and entry.excess > WTM.CPU.ELEVATED_MARGIN_PCT then
                record.spikes = record.spikes + 1
                record.lastSpikeAt = at
            end
        end
    end

    local spikes = self.spikes
    if #spikes >= MAX_SPIKES then table.remove(spikes, 1) end
    spikes[#spikes + 1] = spike

    self.counts[kind] = (self.counts[kind] or 0) + 1
    self.total = self.total + 1

    self:AddToCluster(spike)

    WTM.Context:AddMarker("fpsdrop", ("%s  %.0f ms"):format(spike.label, frameMs))

    -- Dense sampling around the event, then back down.
    WTM.Scheduler:TriggerBurst()

    -- Only spikes at or above the configured severity get a flight recorder
    -- incident, so a session full of minor stutters does not fill the database.
    local captureFrom = C.SPIKE_ORDER[WTM.db.profile.spikes.captureFrom] or 2
    if (C.SPIKE_ORDER[kind] or 1) >= captureFrom then
        WTM.FlightRecorder:RequestCapture(spike)
    end

    WTM:SendMessage("WTM_SPIKE", spike)

    if WTM.db.profile.general.openOnSpike and kind == "freeze" and not simulated then
        if WTM.UI and WTM.UI.MainWindow then WTM.UI.MainWindow:Open("incidents") end
    end
    return spike
end

function SpikeDetector:MemorySnapshot()
    local out = {}
    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]
        if record.loaded and (record.memDeltaKB or 0) > 32 then
            out[#out + 1] = { name = record.name, deltaKB = record.memDeltaKB }
        end
    end
    table.sort(out, function(a, b) return a.deltaKB > b.deltaKB end)
    for i = #out, 4, -1 do out[i] = nil end
    return out
end

--------------------------------------------------------------------------
-- Coalescing into stutter clusters
--------------------------------------------------------------------------
-- Three 90 ms frames over 0.8 s is one stutter, not three freezes. A cluster
-- carries the peak, the span and how many frames were affected; the individual
-- spikes remain available inside it.

function SpikeDetector:AddToCluster(spike)
    if not WTM.db.profile.spikes.coalesce then
        openCluster = nil
        return
    end

    local window = WTM.db.profile.spikes.clusterWindow or C.CLUSTER_WINDOW_SEC

    if openCluster and (spike.t - openCluster.endedAt) <= window
       and (spike.t - openCluster.startedAt) <= C.CLUSTER_MAX_SPAN_SEC then
        openCluster.endedAt = spike.t
        openCluster.frames = openCluster.frames + 1
        openCluster.spikes[#openCluster.spikes + 1] = spike
        if spike.frameMs > openCluster.peakMs then
            openCluster.peakMs = spike.frameMs
            openCluster.peakSpike = spike
        end
        if (C.SPIKE_ORDER[spike.kind] or 1) > (C.SPIKE_ORDER[openCluster.kind] or 1) then
            openCluster.kind = spike.kind
            openCluster.label = spike.label
        end
        -- A cluster that contains any injected spike is itself simulated:
        -- mixing real and injected data into something labelled real would be
        -- exactly the confusion dev mode is supposed to avoid.
        openCluster.simulated = openCluster.simulated or spike.simulated
        spike.clusterId = openCluster.id
        return openCluster
    end

    self:CloseCluster()

    self.nextClusterId = (self.nextClusterId or 0) + 1
    openCluster = {
        id        = self.nextClusterId,
        startedAt = spike.t,
        endedAt   = spike.t,
        epoch     = spike.epoch,
        kind      = spike.kind,
        label     = spike.label,
        peakMs    = spike.frameMs,
        peakSpike = spike,
        frames    = 1,
        spikes    = { spike },
        context   = spike.context,
        simulated = spike.simulated,
    }
    spike.clusterId = openCluster.id
    return openCluster
end

--- Closes the open cluster once it has gone quiet, so its duration is accurate.
function SpikeDetector:ExpireCluster()
    if not openCluster then return end
    local window = WTM.db.profile.spikes.clusterWindow or C.CLUSTER_WINDOW_SEC
    if (GetTime() - openCluster.endedAt) > window then
        self:CloseCluster()
    end
end

function SpikeDetector:CloseCluster()
    if not openCluster then return end
    openCluster.duration = openCluster.endedAt - openCluster.startedAt
    openCluster.closed = true

    local clusters = self.clusters
    if #clusters >= C.MAX_CLUSTERS then table.remove(clusters, 1) end
    clusters[#clusters + 1] = openCluster

    WTM:SendMessage("WTM_CLUSTER", openCluster)
    openCluster = nil
end

function SpikeDetector:GetOpenCluster() return openCluster end

--- Clusters newest first, including the one still open.
function SpikeDetector:GetClusters(out, limit)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if openCluster then
        openCluster.duration = openCluster.endedAt - openCluster.startedAt
        out[1] = openCluster
    end
    local clusters = self.clusters
    for i = #clusters, 1, -1 do
        if limit and #out >= limit then break end
        out[#out + 1] = clusters[i]
    end
    return out
end

function SpikeDetector:GetCluster(id)
    if openCluster and openCluster.id == id then return openCluster end
    for i = #self.clusters, 1, -1 do
        if self.clusters[i].id == id then return self.clusters[i] end
    end
    return nil
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

function SpikeDetector:GetRecent(out, limit)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local spikes = self.spikes
    local first = math.max(1, #spikes - (limit or 20) + 1)
    for i = #spikes, first, -1 do out[#out + 1] = spikes[i] end
    return out
end

function SpikeDetector:GetInRange(fromTime, toTime, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    for i = 1, #self.spikes do
        local spike = self.spikes[i]
        if spike.t >= fromTime and spike.t <= toTime then out[#out + 1] = spike end
    end
    return out
end

--- Human-readable description of one spike. Wording is deliberately cautious:
--- the CPU section always names its observation window.
--- How many spikes were recorded in the last `seconds`, optionally only those
--- at or above `minSeverity`. Walks the bounded spike list backwards and stops
--- as soon as it leaves the window, so it stays cheap enough to call on every
--- dashboard refresh.
function SpikeDetector:CountSince(seconds, minSeverity)
    local cutoff = GetTime() - (seconds or 60)
    local count = 0
    for i = #self.spikes, 1, -1 do
        local spike = self.spikes[i]
        if spike.t < cutoff then break end
        -- Severity is stored as the kind; C.SPIKE_ORDER maps it to a rank.
        if not minSeverity or (C.SPIKE_ORDER[spike.kind] or 0) >= minSeverity then
            count = count + 1
        end
    end
    return count
end

--- The worst spike recorded this session, or nil if there has not been one.
function SpikeDetector:WorstSpike()
    local worst
    for i = 1, #self.spikes do
        local spike = self.spikes[i]
        if not worst or (spike.frameMs or 0) > (worst.frameMs or 0) then worst = spike end
    end
    return worst
end

function SpikeDetector:Describe(spike)
    local Fmt = WTM.Format
    local lines = {}
    lines[#lines + 1] = ("%s   Frame time %s   (equivalent to %s FPS)")
        :format(spike.label, Fmt.Ms(spike.frameMs), Fmt.FPS(spike.fps))
    lines[#lines + 1] = ("Rolling baseline at the time: %s"):format(Fmt.Ms(spike.baselineMs))

    if spike.latStale then
        lines[#lines + 1] = ("World latency %d ms, home %d ms (reading was %s old - the client refreshes it about every 30 s)")
            :format(spike.latWorld, spike.latHome, Fmt.Duration(spike.latAgeSec or 0))
    else
        lines[#lines + 1] = ("World latency %d ms, home %d ms"):format(spike.latWorld, spike.latHome)
    end

    if spike.cpuUnavailable then
        lines[#lines + 1] = "Addon CPU: " .. spike.cpuUnavailable
    elseif spike.cpu and #spike.cpu > 0 then
        local window = spike.cpuWindow
        lines[#lines + 1] = ("Addon CPU within a %s observation window:")
            :format(window and ("%.1f s"):format(window.seconds or 0) or "recent")
        for i = 1, #spike.cpu do
            local entry = spike.cpu[i]
            lines[#lines + 1] = ("   %s   %s CPU within the window (%+.1f%% vs its own average)")
                :format(entry.title or entry.name, Fmt.Ms(entry.deltaMs), entry.excess)
        end
        lines[#lines + 1] = C.TXT_CPU_WINDOW_NOTE
    else
        lines[#lines + 1] = "No addon stood out above its own average in this window."
    end

    if spike.events and #spike.events > 0 then
        lines[#lines + 1] = "Event activity in the same window:"
        for i = 1, math.min(5, #spike.events) do
            local entry = spike.events[i]
            lines[#lines + 1] = ("   %s   %s"):format(entry.event, Fmt.Rate(entry.rate))
        end
    end

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function SpikeDetector:OnEnable()
    local rate = WTM.db.profile.sampling.intervals.frametime
    WTM.Scheduler:Register("spikes", function() SpikeDetector:Check() end,
        rate, C.SAMPLE_DEFAULTS.frametime.burst, 0.25, "sampler")
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function SpikeDetector:OnDisable()
    -- A cluster still open at logout is real data; close it rather than losing
    -- the last stutter of the session.
    self:CloseCluster()
end

function SpikeDetector:Reset()
    for i = #self.spikes, 1, -1 do self.spikes[i] = nil end
    for i = #self.clusters, 1, -1 do self.clusters[i] = nil end
    for kind in pairs(self.counts) do self.counts[kind] = 0 end
    self.total, self.suppressed = 0, 0
    openCluster = nil
    lastSpikeAt, lastSpikeSeverity = 0, 0
end
