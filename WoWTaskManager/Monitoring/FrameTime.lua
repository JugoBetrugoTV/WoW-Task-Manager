--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/FrameTime.lua

    The most important measurement in the addon, and the one that must cost
    almost nothing.

    GetFramerate() is a smoothed value; it will happily report 118 FPS through
    a 90 ms hitch.  The `elapsed` argument of OnUpdate is the real delta of the
    frame that just finished, so that is what everything here is built on.

    The per-frame body is kept as small as the measurement allows: it is
    allocation-free (no table constructor, no string, no closure), touches only
    upvalues and one array slot, and never iterates.  It does do real work -
    accumulation, min/max tracking, a histogram index and a threshold test - so
    it is not free, only bounded and constant.

    Its actual cost is measured, not asserted: Monitoring/Overhead.lua reports
    it under "frame accounting" and /wtm benchmark prints a per-frame figure.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local Math  = WTM.Math
local Ring  = WTM.RingBuffer

local FrameTime = WTM:NewModule("FrameTime")
WTM.FrameTime = FrameTime

--------------------------------------------------------------------------
-- Per-frame accumulators (upvalues, deliberately not table fields)
--------------------------------------------------------------------------

local frames   = 0
local sumMs    = 0
local maxMs    = 0
local minMs    = 1e9
local windowT  = 0

-- Session-wide totals
local sessionFrames = 0
local sessionSumMs  = 0
local sessionMaxMs  = 0

-- The last frame that exceeded the lowest spike threshold; the spike detector
-- reads and clears this.
local pendingSpikeMs = 0
local pendingSpikeAt = 0

-- Rolling baseline of frame time. A 30 FPS player and a 240 FPS player need
-- very different absolute thresholds, so the detector compares against this.
local baselineMs = nil
local BASELINE_ALPHA = 0.02

-- How many windows the baseline needs before the RELATIVE spike rule may be
-- trusted.
--
-- The first window seeds the baseline, so if it happens to contain a hitch the
-- baseline is seeded at the hitch and that spike - plus everything smaller
-- after it - becomes invisible. Until the baseline has settled, the spike
-- detector uses the absolute thresholds only, which cannot be poisoned this
-- way. Seeding from the window's MINIMUM rather than its average is the other
-- half of the fix: the best frame in a window is a far better estimate of
-- "normal" than an average that includes the stutter.
local BASELINE_MIN_SAMPLES = 8
local baselineSamples = 0

-- One histogram for the whole session.  A second per-window histogram was
-- tempting for "percentiles over the last minute", but it would double the
-- per-frame array writes for a number nothing actually reads, so it is gone.
local sessionHist = Math.NewHistogram()

-- The cheapest threshold check possible: one comparison against a precomputed
-- number, refreshed whenever the settings change.
local spikeFloorMs = C.SPIKE_DEFAULTS.minor.absMs

FrameTime.current = {
    fps        = 0,
    frameMs    = 0,
    avgMs      = 0,
    minMs      = 0,
    maxMs      = 0,
    baselineMs = 0,
    smoothedFps = 0,
}

FrameTime.history = {
    fps     = nil,   -- RingBuffer, created in OnInitialize
    frameMs = nil,
    maxMs   = nil,
}

--------------------------------------------------------------------------
-- The hot path
--------------------------------------------------------------------------

local HistogramIndex = Math.HistogramIndex

local function OnFrame(elapsed)
    local ms = elapsed * 1000

    frames = frames + 1
    sumMs  = sumMs + ms
    if ms > maxMs then maxMs = ms end
    if ms < minMs then minMs = ms end

    local i = HistogramIndex(ms)
    sessionHist[i] = sessionHist[i] + 1

    if ms > pendingSpikeMs and ms >= spikeFloorMs then
        pendingSpikeMs = ms
        pendingSpikeAt = GetTime()
    end

    windowT = windowT + elapsed
end

--------------------------------------------------------------------------
-- Window close (runs at the `frametime` task interval)
--------------------------------------------------------------------------

function FrameTime:Sample(delta)
    if frames == 0 then
        -- No frames since the last sample (possible right after a loading
        -- screen).  Report nothing rather than dividing by zero.
        return
    end

    local avgMs = sumMs / frames
    local fps   = frames / (windowT > 0 and windowT or delta)

    -- Update the baseline from the average, not the max: a single hitch must
    -- not drag the reference up and hide the next one.
    if baselineMs == nil then
        -- Seed from the best frame in the window, not its average.
        baselineMs = (minMs < 1e9 and minMs > 0) and minMs or avgMs
    else
        baselineMs = Math.EMA(baselineMs, avgMs, BASELINE_ALPHA)
    end
    baselineSamples = baselineSamples + 1

    -- Re-derive the hot-path pre-filter from the live baseline.
    --
    -- This is not cosmetic. The pre-filter is the single comparison that
    -- decides whether a frame is even considered a spike, and it has to track
    -- the baseline: a 144 Hz player settles at ~7 ms, so their relative-rule
    -- spikes start around 14 ms - well under the 33 ms absolute floor. Leaving
    -- the floor at its startup value made every relative spike invisible on
    -- high-refresh setups.
    self:RefreshThresholds()

    -- Feed the background heuristic, which needs the window average.
    if WTM.Suppression then WTM.Suppression:UpdateBackground(avgMs) end

    local cur = self.current
    cur.fps         = fps
    cur.avgMs       = avgMs
    cur.minMs       = minMs < 1e9 and minMs or 0
    cur.maxMs       = maxMs
    cur.frameMs     = avgMs
    cur.baselineMs  = baselineMs or avgMs
    cur.smoothedFps = GetFramerate and GetFramerate() or fps

    sessionFrames = sessionFrames + frames
    sessionSumMs  = sessionSumMs + sumMs
    if maxMs > sessionMaxMs then sessionMaxMs = maxMs end
    sessionHist.count = sessionHist.count + frames

    self.history.fps:Push(fps)
    self.history.frameMs:Push(avgMs)
    self.history.maxMs:Push(maxMs)

    -- Hand the worst frame of the window to the spike detector before resetting.
    self.lastWindow = self.lastWindow or {}
    local w = self.lastWindow
    w.frames, w.avgMs, w.maxMs, w.minMs, w.fps = frames, avgMs, maxMs, cur.minMs, fps
    w.spikeMs, w.spikeAt = pendingSpikeMs, pendingSpikeAt
    w.baselineMs = baselineMs

    frames, sumMs, maxMs, minMs, windowT = 0, 0, 0, 1e9, 0
    pendingSpikeMs, pendingSpikeAt = 0, 0
end

--------------------------------------------------------------------------
-- Derived statistics
--------------------------------------------------------------------------

--- Percentile frame times over the whole session, in ms.
function FrameTime:GetPercentileMs(p)
    return Math.HistogramPercentile(sessionHist, p)
end

--- "1% low FPS" is the FPS equivalent of the 99th-percentile frame time: the
--- speed of the worst 1% of frames.  This is the number that actually matches
--- what a stutter feels like.
function FrameTime:Get1PercentLow()
    return Math.MsToFPS(self:GetPercentileMs(0.99))
end

function FrameTime:Get01PercentLow()
    return Math.MsToFPS(self:GetPercentileMs(0.999))
end

function FrameTime:GetSessionStats()
    local avgMs = sessionFrames > 0 and (sessionSumMs / sessionFrames) or 0
    return {
        frames    = sessionFrames,
        avgMs     = avgMs,
        avgFPS    = avgMs > 0 and (1000 / avgMs) or 0,
        maxMs     = sessionMaxMs,
        minFPS    = sessionMaxMs > 0 and (1000 / sessionMaxMs) or 0,
        low1      = self:Get1PercentLow(),
        low01     = self:Get01PercentLow(),
        medianMs  = self:GetPercentileMs(0.5),
    }
end

function FrameTime:GetHistogram() return sessionHist end
function FrameTime:GetBaseline()  return baselineMs or 0 end

--- True once the rolling baseline has seen enough windows to be compared
--- against. Before this the spike detector falls back to absolute thresholds.
function FrameTime:IsBaselineReady()
    return baselineSamples >= BASELINE_MIN_SAMPLES
end

function FrameTime:GetBaselineSamples() return baselineSamples end

--- Distribution of frames across the stutter classes, for the analyzer page.
function FrameTime:GetStutterDistribution(out)
    out = out or {}
    local spikes = WTM.db.profile.spikes
    local bounds = {
        { key = "smooth",  label = "Smooth",        maxMs = spikes.minor.absMs },
        { key = "minor",   label = "Minor Stutter", maxMs = spikes.stutter.absMs },
        { key = "stutter", label = "Stutter",       maxMs = spikes.heavy.absMs },
        { key = "heavy",   label = "Heavy Stutter", maxMs = spikes.freeze.absMs },
        { key = "freeze",  label = "Freeze",        maxMs = math.huge },
    }
    for i = #out, 1, -1 do out[i] = nil end

    local total = sessionHist.count
    local counts = {}
    for i = 1, #bounds do counts[i] = 0 end

    for bucket = 1, C.HIST_BUCKETS do
        local n = sessionHist[bucket]
        if n > 0 then
            local ms = Math.HistogramValue(bucket)
            for i = 1, #bounds do
                if ms < bounds[i].maxMs then
                    counts[i] = counts[i] + n
                    break
                end
            end
        end
    end

    for i = 1, #bounds do
        out[i] = {
            key   = bounds[i].key,
            label = bounds[i].label,
            count = counts[i],
            pct   = total > 0 and (counts[i] / total * 100) or 0,
        }
    end
    return out, total
end

--------------------------------------------------------------------------
-- Spike hand-off
--------------------------------------------------------------------------

--- Returns the worst frame seen in the last window and its timestamp, or nil.
function FrameTime:ConsumePendingSpike()
    local w = self.lastWindow
    if not w or (w.spikeMs or 0) <= 0 then return nil end
    local ms, at = w.spikeMs, w.spikeAt
    w.spikeMs, w.spikeAt = 0, 0
    return ms, at
end

--- Recomputed whenever thresholds change so the hot path stays one comparison.
function FrameTime:RefreshThresholds()
    local spikes = WTM.db.profile.spikes
    local floor = spikes.minor.absMs
    for _, kind in ipairs(C.SPIKE_KINDS) do
        local cfg = spikes[kind]
        if cfg and cfg.absMs < floor then floor = cfg.absMs end
    end
    -- Also respect the relative rule: with a fast baseline the multiplier can
    -- fire below the absolute floor, so take whichever is lower.
    local base = baselineMs or 16.67
    local relFloor = base * (spikes.minor.mult or 2)
    spikeFloorMs = math.min(floor, relFloor)
    if spikeFloorMs < 5 then spikeFloorMs = 5 end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function FrameTime:OnInitialize()
    local size = 512
    self.history.fps     = Ring.New(size)
    self.history.frameMs = Ring.New(size)
    self.history.maxMs   = Ring.New(size)
end

function FrameTime:OnEnable()
    local intervals = WTM.db.profile.sampling.intervals
    WTM.Scheduler:SetFrameCallback(OnFrame)
    WTM.Scheduler:Register("frametime", function(delta) FrameTime:Sample(delta) end,
        intervals.frametime, C.SAMPLE_DEFAULTS.frametime.burst, 0, "sampler")
    self:RefreshThresholds()

    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function FrameTime:Reset()
    frames, sumMs, maxMs, minMs, windowT = 0, 0, 0, 1e9, 0
    sessionFrames, sessionSumMs, sessionMaxMs = 0, 0, 0
    pendingSpikeMs, pendingSpikeAt = 0, 0
    baselineMs, baselineSamples = nil, 0
    Math.ResetHistogram(sessionHist)
    self.history.fps:Reset()
    self.history.frameMs:Reset()
    self.history.maxMs:Reset()
end
