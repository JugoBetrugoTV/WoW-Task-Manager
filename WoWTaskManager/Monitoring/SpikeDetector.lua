--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/SpikeDetector.lua

    Turns "the game hitched" into a record you can actually read afterwards.

    Detection is deliberately two-sided: a frame counts as a spike only if it
    exceeds BOTH an absolute floor AND a multiple of the rolling baseline.

        absolute only  -> a 144 Hz player drowns in "spikes" at 20 ms
        relative only  -> a 25 Hz player never registers one at all

    When a spike fires:
      1. the scheduler flips into burst mode, so the seconds around it are
         sampled densely,
      2. the flight recorder is asked for a capture (which completes after the
         post-window, not immediately),
      3. a snapshot of context, CPU deltas, memory movement and event activity
         is attached.

    What this module deliberately does NOT do is name a culprit.  It records
    what was busy at the same moment.  Analysis/Correlation.lua decides how
    strongly that may be worded, and the strongest wording available anywhere
    in this addon is "strongly correlated".
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat

local SpikeDetector = WTM:NewModule("SpikeDetector")
WTM.SpikeDetector = SpikeDetector

SpikeDetector.spikes = {}          -- session spike records, bounded
SpikeDetector.counts = { minor = 0, stutter = 0, heavy = 0, freeze = 0 }
SpikeDetector.total  = 0

local MAX_SPIKES = 300
local lastSpikeAt = 0
local lastSpikeSeverity = 0

--------------------------------------------------------------------------
-- Classification
--------------------------------------------------------------------------

--- Returns the spike kind for a frame time, or nil.  Walks from most to least
--- severe so a 300 ms frame is a freeze, not a minor stutter.
local ORDER = { "freeze", "heavy", "stutter", "minor" }

function SpikeDetector:Classify(frameMs, baselineMs)
    local settings = WTM.db.profile.spikes
    if not settings.enabled then return nil end
    baselineMs = (baselineMs and baselineMs > 0) and baselineMs or 16.67

    for i = 1, #ORDER do
        local kind = ORDER[i]
        local cfg = settings[kind]
        if cfg and frameMs >= cfg.absMs and frameMs >= baselineMs * cfg.mult then
            return kind
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Detection pass (runs on the frame-time cadence)
--------------------------------------------------------------------------

function SpikeDetector:Check()
    local frameMs, at = WTM.FrameTime:ConsumePendingSpike()
    if not frameMs then return end

    local baseline = WTM.FrameTime:GetBaseline()
    local kind = self:Classify(frameMs, baseline)
    if not kind then return end

    local severity = C.SPIKE_ORDER[kind] or 1
    local now = GetTime()
    local debounce = WTM.db.profile.spikes.debounce

    -- A long freeze produces several oversized frames in a row.  One incident
    -- is the useful outcome; four is noise.  A MORE severe spike is always
    -- allowed through, so a stutter escalating into a freeze is not swallowed.
    if (now - lastSpikeAt) < debounce and severity <= lastSpikeSeverity then
        return
    end
    lastSpikeAt = now
    lastSpikeSeverity = severity

    self:Record(kind, frameMs, at or now, baseline)
end

--------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------

function SpikeDetector:Record(kind, frameMs, at, baselineMs)
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
        luaKB      = WTM.Memory.current.luaKB,
        eventRate  = WTM.Events.current.perSecond,
        context    = WTM.Context:Capture(),
    }

    -- What was unusually busy in the sample window containing the spike.
    -- Sample out of band first: the CPU sampler runs far slower than spike
    -- detection, so the numbers sitting in the records right now describe a
    -- window that may end before the hitch even started.
    if WTM.CPU.available then
        WTM.CPU:SampleNow(0.2)
        spike.cpu = WTM.CPU:GetWindowDeltas(nil, 5, 0.5)
        spike.totalCpuPct = WTM.CPU.current.totalPct
    else
        spike.cpuUnavailable = WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
    end

    spike.events = WTM.Events:SnapshotTop(nil, 8)
    spike.memory = self:MemorySnapshot()

    -- Blame the addons that were above their own normal, not the ones that are
    -- simply always busy.
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

    if WTM.db.profile.general.openOnSpike and kind == "freeze" then
        if WTM.UI and WTM.UI.MainWindow then WTM.UI.MainWindow:Open("timeline") end
    end
end

local memScratch = {}
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

--- Human-readable description of one spike, used by the incident view and the
--- text report.  Wording is intentionally cautious throughout.
function SpikeDetector:Describe(spike)
    local Fmt = WTM.Format
    local lines = {}
    lines[#lines + 1] = ("%s   Frame time %s   (%s FPS)")
        :format(spike.label, Fmt.Ms(spike.frameMs), Fmt.FPS(spike.fps))
    lines[#lines + 1] = ("Baseline at the time: %s"):format(Fmt.Ms(spike.baselineMs))

    if spike.latStale then
        lines[#lines + 1] = ("World latency %d ms (reading may be up to 30 s old)"):format(spike.latWorld)
    else
        lines[#lines + 1] = ("World latency %d ms, home %d ms"):format(spike.latWorld, spike.latHome)
    end

    if spike.cpuUnavailable then
        lines[#lines + 1] = "Addon CPU: " .. spike.cpuUnavailable
    elseif spike.cpu and #spike.cpu > 0 then
        lines[#lines + 1] = "Addons above their own average at that moment:"
        for i = 1, #spike.cpu do
            local entry = spike.cpu[i]
            lines[#lines + 1] = ("   %s   %s CPU in the sample window (%+.1f%% vs its average)")
                :format(entry.title or entry.name, Fmt.Ms(entry.deltaMs), entry.excess)
        end
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
        rate, C.SAMPLE_DEFAULTS.frametime.burst, 0.25)
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function SpikeDetector:Reset()
    for i = #self.spikes, 1, -1 do self.spikes[i] = nil end
    for kind in pairs(self.counts) do self.counts[kind] = 0 end
    self.total = 0
    lastSpikeAt, lastSpikeSeverity = 0, 0
end
