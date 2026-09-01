--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/CPU.lua

    Addon CPU accounting.  Everything in here depends on the client's
    scriptProfile CVar; with it off, GetAddOnCPUUsage returns 0 for everybody.
    That is not a bug and it is not something to paper over with an estimate -
    the module reports `available = false` and the UI shows an explanation plus
    the switch to turn it on.

    GetAddOnCPUUsage returns CUMULATIVE milliseconds since the last
    ResetCPUUsage().  The only meaningful figure is the delta between two
    samples divided by the wall-clock time between them, which gives
    "percent of one core spent inside that addon's Lua".
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local api    = Compat.api
local MathU  = WTM.Math

local CPU = WTM:NewModule("CPU")
WTM.CPU = CPU

CPU.current = {
    totalPct      = 0,   -- all addons combined, % of one core
    scriptTotalMs = 0,   -- GetScriptCPUUsage, cumulative
    scriptDeltaMs = 0,
    lastSampleAt  = 0,
    sampleCostMs  = 0,
    sampleWindowSec = 0,
}

CPU.available = false

local EMA_ALPHA = 0.25

-- How far above its own average an addon has to be for the sample to count as
-- "elevated".  Also used by the spike detector, so the two agree.
local ELEVATED_MARGIN_PCT = 0.5
CPU.ELEVATED_MARGIN_PCT = ELEVATED_MARGIN_PCT
local lastSampleTime = nil

--------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------

function CPU:Sample()
    if not self.available then return end

    local t0 = Compat.Now()
    local ok = pcall(api.UpdateAddOnCPUUsage)
    if not ok then
        self.available = false
        return
    end

    local now = GetTime()
    local windowSec = lastSampleTime and (now - lastSampleTime) or 0
    lastSampleTime = now
    if windowSec <= 0 then return end
    local windowMs = windowSec * 1000

    local list = WTM.Processes.list
    local totalDeltaMs = 0

    for i = 1, #list do
        local record = list[i]
        if record.loaded then
            local okCPU, cumulativeMs = pcall(api.GetAddOnCPUUsage, record.index)
            if okCPU and cumulativeMs then
                local delta = cumulativeMs - record.cpuTotalMs
                -- ResetCPUUsage elsewhere (or a client quirk) can move the
                -- counter backwards; treat that as a restart, not as negative
                -- work.
                if delta < 0 then delta = 0 end

                record.cpuTotalMs = cumulativeMs
                record.cpuDeltaMs = delta

                local pct = delta / windowMs * 100
                record.cpuPct = pct
                record.cpuEma = MathU.EMA(record.cpuSamples > 0 and record.cpuEma or nil, pct, EMA_ALPHA)
                if pct > record.cpuPeakPct then record.cpuPeakPct = pct end
                record.cpuSumPct = record.cpuSumPct + pct
                record.cpuSamples = record.cpuSamples + 1

                -- Count how often this addon runs hotter than its own average.
                -- Analysis/Correlation.lua needs this as the "elevated with no
                -- spike" cell of its contingency table; measuring it here is
                -- one comparison per addon per sample and removes the need to
                -- estimate that number later.
                if record.cpuSamples > 3 then
                    local average = record.cpuSumPct / record.cpuSamples
                    if pct - average > ELEVATED_MARGIN_PCT then
                        record.elevatedSamples = (record.elevatedSamples or 0) + 1
                    end
                end

                if record.cpuRing then record.cpuRing:Push(pct) end
                totalDeltaMs = totalDeltaMs + delta
            end
        end
    end

    local cur = self.current
    cur.totalPct = totalDeltaMs / windowMs * 100
    cur.lastSampleAt = now
    cur.sampleWindowSec = windowSec

    if api.GetScriptCPUUsage then
        local okScript, totalMs = pcall(api.GetScriptCPUUsage)
        if okScript and totalMs then
            cur.scriptDeltaMs = math.max(0, totalMs - cur.scriptTotalMs)
            cur.scriptTotalMs = totalMs
        end
    end

    cur.sampleCostMs = Compat.Now() - t0
    WTM:SendMessage("WTM_CPU_SAMPLED")
end

--- Takes a sample right now, out of band.
---
--- The spike detector needs this.  Spikes are detected on the frame time
--- cadence (four times a second by default) while CPU is sampled every two
--- seconds, so without this the snapshot attached to a spike would carry CPU
--- deltas measured up to two seconds BEFORE the hitch - describing a window
--- that does not contain the event it is supposed to explain.
---
--- Sampling out of band is only worth its cost at the moment something went
--- wrong, which is exactly when this is called.  `minAge` stops it from doing
--- the work twice when a burst has already sampled recently.
function CPU:SampleNow(minAge)
    if not self.available then return false end
    if lastSampleTime and (GetTime() - lastSampleTime) < (minAge or 0.2) then
        return false
    end
    self:Sample()
    return true
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

function CPU:GetTopConsumers(out, limit)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not self.available then return out end

    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]
        if record.loaded and (record.cpuEma or 0) > 0.01 then
            out[#out + 1] = {
                name    = record.name,
                title   = record.titleClean,
                pct     = record.cpuEma,
                peakPct = record.cpuPeakPct,
                deltaMs = record.cpuDeltaMs,
            }
        end
    end
    table.sort(out, function(a, b) return a.pct > b.pct end)
    if limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function CPU:GetAverage(record)
    if record.cpuSamples == 0 then return 0 end
    return record.cpuSumPct / record.cpuSamples
end

--- CPU cost per event across all addons.  Exact when profiling is on, and the
--- only per-event cost figure the API offers.
function CPU:GetEventCPU(event)
    if not (self.available and api.GetEventCPUUsage) then return nil end
    local ok, ms, count = pcall(api.GetEventCPUUsage, event)
    if not ok then return nil end
    return ms, count
end

--- Total time spent in event handlers across all addons.
function CPU:GetTotalEventCPU()
    if not (self.available and api.GetEventCPUUsage) then return nil end
    local ok, ms, count = pcall(api.GetEventCPUUsage)
    if not ok then return nil end
    return ms, count
end

--------------------------------------------------------------------------
-- Spike attribution helpers
--------------------------------------------------------------------------
-- Called by the spike detector: which addons burned unusually much CPU in the
-- sample window that contained the spike.  This produces a candidate list, not
-- a verdict; Analysis/Correlation.lua decides how strongly to word it.

function CPU:GetWindowDeltas(out, limit, minMs)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not self.available then return out end

    minMs = minMs or 0.5
    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]

        -- This addon excludes ITSELF from spike attribution.
        --
        -- Detecting a spike is what makes it switch to burst sampling, so its
        -- own CPU rises immediately after every spike - and it would then show
        -- up, correctly by the arithmetic and completely backwards in meaning,
        -- as a leading correlate of the spikes it just detected. A monitor that
        -- reports its own reaction as the cause of the thing it reacted to is
        -- worse than useless. Its real cost is measured and reported separately
        -- under Overhead, where it belongs.
        local isSelf = (record.name == WTM.name)

        if record.loaded and not isSelf and record.cpuDeltaMs >= minMs then
            local average = self:GetAverage(record)
            out[#out + 1] = {
                name     = record.name,
                title    = record.titleClean,
                deltaMs  = record.cpuDeltaMs,
                pct      = record.cpuPct,
                -- How far above its own normal this addon was; a busy addon
                -- being busy is not evidence of anything.
                excess   = record.cpuPct - average,
            }
        end
    end
    table.sort(out, function(a, b) return a.excess > b.excess end)
    if limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function CPU:OnInitialize()
    self.available = WTM.Caps:Get("addonCPU") == "yes"
    self.reason = nil
    if not self.available then
        local state, note = WTM.Caps:Get("addonCPU")
        self.reason = (state == "profile") and C.TXT_REQUIRES_PROFILING or (note or C.TXT_UNAVAILABLE_CLIENT)
    end
end

function CPU:OnEnable()
    if not self.available then return end
    local intervals = WTM.db.profile.sampling.intervals
    WTM.Scheduler:Register("cpu", function() CPU:Sample() end,
        intervals.cpu, C.SAMPLE_DEFAULTS.cpu.burst, 0.45, "sampler")
    lastSampleTime = GetTime()
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

--- Resets the client's own counters.  Deliberately NOT called automatically:
--- other profiling addons read the same cumulative counters, and silently
--- zeroing them under another addon's feet would be rude and would corrupt
--- its numbers.  Only the user can trigger this.
function CPU:ResetClientCounters()
    if not api.ResetCPUUsage then return false, C.TXT_UNAVAILABLE_CLIENT end
    local ok = pcall(api.ResetCPUUsage)
    if not ok then return false, "client refused" end
    local list = WTM.Processes.list
    for i = 1, #list do list[i].cpuTotalMs = 0 end
    self.current.scriptTotalMs = 0
    lastSampleTime = GetTime()
    return true
end

function CPU:Reset()
    local list = WTM.Processes.list
    for i = 1, #list do list[i].elevatedSamples = 0 end
    lastSampleTime = GetTime()
    local cur = self.current
    cur.totalPct, cur.scriptDeltaMs = 0, 0
end
