--[[--------------------------------------------------------------------------
    WoW Task Manager - History/Recorder.lua

    Long-term time series with tiered aggregation.

    Storing one row per second for a four hour raid night is ~14,400 rows.  Most
    of them are of no interest by the time you look at them, so older data is
    compacted into coarser buckets:

        0 - 5 min      1 s     300 buckets
        5 - 30 min     5 s     300 buckets
        30 min - 3 h  15 s     600 buckets
        3 h +         60 s     ~60 per hour

    Compaction keeps the MAX of frame time and event rate rather than the mean,
    because the peaks are the entire reason anyone looks at this data.  A mean
    would smooth a 200 ms freeze into a slightly-above-average second.

    Buckets are arrays, not keyed tables.  In SavedVariables that is roughly
    60% smaller for identical information.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat

local Recorder = WTM:NewModule("Recorder")
WTM.Recorder = Recorder

-- Field positions inside a bucket array.
local F_T, F_FPS, F_AVG, F_MAX, F_LATH, F_LATW, F_LUA, F_EV, F_CPU = 1, 2, 3, 4, 5, 6, 7, 8, 9
Recorder.FIELDS = { t = F_T, fps = F_FPS, frameAvgMs = F_AVG, frameMaxMs = F_MAX,
                    latH = F_LATH, latW = F_LATW, luaKB = F_LUA, events = F_EV, cpuMs = F_CPU }

Recorder.tiers = {}

-- Bumped whenever a new bucket is closed. The UI uses it to skip redrawing
-- graphs that cannot have changed - buckets are one second apart, so redrawing
-- twice a second was doing half its work for nothing.
Recorder.revision = 0

--------------------------------------------------------------------------
-- Tier setup
--------------------------------------------------------------------------

local function BuildTiers()
    local tiers = {}
    local previousAge = 0
    for i, spec in ipairs(C.HISTORY_TIERS) do
        local span = (spec.maxAge == math.huge) and (6 * 3600) or (spec.maxAge - previousAge)
        tiers[i] = {
            resolution = spec.resolution,
            maxAge     = spec.maxAge,
            capacity   = math.ceil(span / spec.resolution),
            buckets    = {},
            pending    = nil,
            pendingStart = nil,
        }
        previousAge = spec.maxAge
    end
    return tiers
end

--------------------------------------------------------------------------
-- Ingest
--------------------------------------------------------------------------

local function NewBucket(t)
    return { t, 0, 0, 0, 0, 0, 0, 0, 0 }
end

--- Merges `sample` into `bucket`, keeping worst-case values where that is the
--- meaningful summary.
local function Merge(bucket, fps, avgMs, maxMs, latH, latW, luaKB, events, cpuMs, weight)
    -- Running mean for the "typical" fields...
    local n = (bucket.n or 0) + weight
    bucket.n = n
    bucket[F_FPS] = bucket[F_FPS] + (fps - bucket[F_FPS]) * (weight / n)
    bucket[F_AVG] = bucket[F_AVG] + (avgMs - bucket[F_AVG]) * (weight / n)
    bucket[F_CPU] = bucket[F_CPU] + (cpuMs - bucket[F_CPU]) * (weight / n)
    -- ...and max for the fields where the peak is the point.
    if maxMs > bucket[F_MAX] then bucket[F_MAX] = maxMs end
    if events > bucket[F_EV] then bucket[F_EV] = events end
    if latH > bucket[F_LATH] then bucket[F_LATH] = latH end
    if latW > bucket[F_LATW] then bucket[F_LATW] = latW end
    bucket[F_LUA] = luaKB   -- a level, not a rate: last value wins
end

function Recorder:Sample()
    local ft  = WTM.FrameTime.current
    local net = WTM.Network.current
    local now = GetTime()

    local cpuMs = 0
    if WTM.CPU.available then
        cpuMs = WTM.CPU.current.totalPct
    end

    local tier = self.tiers[1]
    local slotStart = math.floor(now / tier.resolution) * tier.resolution

    if not tier.pending or tier.pendingStart ~= slotStart then
        if tier.pending then self:CloseBucket(1, tier.pending) end
        tier.pending = NewBucket(slotStart)
        tier.pendingStart = slotStart
    end

    Merge(tier.pending,
        ft.fps, ft.avgMs, ft.maxMs,
        net.latencyHome, net.latencyWorld,
        WTM.Memory.current.luaKB, WTM.Events.current.perSecond,
        cpuMs, 1)
end

function Recorder:CloseBucket(tierIndex, bucket)
    local tier = self.tiers[tierIndex]
    local buckets = tier.buckets
    buckets[#buckets + 1] = bucket
    self.revision = self.revision + 1
    self:Compact(tierIndex)
end

--------------------------------------------------------------------------
-- Compaction
--------------------------------------------------------------------------
-- When a tier is full its oldest buckets are folded into the next, coarser
-- tier.  This runs a handful of table operations at most once per second, so
-- it never shows up in the overhead numbers.

function Recorder:Compact(tierIndex)
    local tier = self.tiers[tierIndex]
    local nextTier = self.tiers[tierIndex + 1]
    local buckets = tier.buckets

    if #buckets <= tier.capacity then return end

    local overflow = #buckets - tier.capacity
    for _ = 1, overflow do
        local oldest = table.remove(buckets, 1)
        if nextTier then
            local slotStart = math.floor(oldest[F_T] / nextTier.resolution) * nextTier.resolution
            if not nextTier.pending or nextTier.pendingStart ~= slotStart then
                if nextTier.pending then
                    local target = nextTier.buckets
                    target[#target + 1] = nextTier.pending
                end
                nextTier.pending = NewBucket(slotStart)
                nextTier.pendingStart = slotStart
            end
            Merge(nextTier.pending,
                oldest[F_FPS], oldest[F_AVG], oldest[F_MAX],
                oldest[F_LATH], oldest[F_LATW], oldest[F_LUA], oldest[F_EV], oldest[F_CPU],
                oldest.n or 1)
            self:Compact(tierIndex + 1)
        end
        -- Without a next tier the sample simply ages out, which is the intent
        -- for the coarsest tier.
    end
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

--- Picks the finest tier whose retained data covers `fromTime`, then walks
--- coarser tiers for whatever is older.  Returns buckets oldest first.
---
--- Tiers overlap only at their seams, so instead of a nested search each tier
--- gets one cutoff: the earliest timestamp any finer tier still holds.  A
--- coarse bucket is used only for the stretch of time no finer tier covers.
local cutoffs = {}
function Recorder:GetRange(fromTime, toTime, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end

    local earliestFiner = math.huge
    for tierIndex = 1, #self.tiers do
        cutoffs[tierIndex] = earliestFiner
        local buckets = self.tiers[tierIndex].buckets
        if #buckets > 0 and buckets[1][F_T] < earliestFiner then
            earliestFiner = buckets[1][F_T]
        end
        local pending = self.tiers[tierIndex].pending
        if pending and pending[F_T] < earliestFiner then
            earliestFiner = pending[F_T]
        end
    end

    for tierIndex = 1, #self.tiers do
        local tier = self.tiers[tierIndex]
        local cutoff = cutoffs[tierIndex]
        local buckets = tier.buckets
        for i = 1, #buckets do
            local bucket = buckets[i]
            local t = bucket[F_T]
            if t >= fromTime and t <= toTime and t < cutoff then
                out[#out + 1] = bucket
            end
        end
    end

    -- The still-open bucket of the finest tier, so the graph reaches "now".
    local live = self.tiers[1].pending
    if live and live[F_T] >= fromTime and live[F_T] <= toTime then
        out[#out + 1] = live
    end

    table.sort(out, function(a, b) return a[F_T] < b[F_T] end)
    return out
end

--- Extracts one field as a plain numeric array, downsampled to at most
--- `maxPoints` while preserving peaks (min/max decimation per column).
function Recorder:GetSeries(fieldName, fromTime, toTime, maxPoints, outValues, outTimes)
    outValues = outValues or {}
    outTimes  = outTimes or {}
    for i = #outValues, 1, -1 do outValues[i] = nil end
    for i = #outTimes, 1, -1 do outTimes[i] = nil end

    local field = self.FIELDS[fieldName]
    if not field then return outValues, outTimes end

    local buckets = self:GetRange(fromTime, toTime, self._scratch or {})
    self._scratch = buckets
    local n = #buckets
    if n == 0 then return outValues, outTimes end

    if not maxPoints or n <= maxPoints then
        for i = 1, n do
            outValues[i] = buckets[i][field]
            outTimes[i]  = buckets[i][F_T]
        end
        return outValues, outTimes
    end

    -- Decimate by taking the extreme value of each group.  For frame time and
    -- event rate that means the max; for FPS the min.  Averaging here would
    -- hide exactly the events this tool exists to show.
    -- FPS is the one series whose worst value is the LOW one; every other
    -- field's worst value is its maximum.  Keeping the wrong end here erases
    -- spikes, which is the entire point of the series.
    local keepMin = (fieldName == "fps")
    local step = n / maxPoints
    local index = 0
    for p = 1, maxPoints do
        local first = math.floor((p - 1) * step) + 1
        local last  = math.min(n, math.floor(p * step))
        if last >= first then
            local best, bestT = buckets[first][field], buckets[first][F_T]
            for i = first + 1, last do
                local v = buckets[i][field]
                if (keepMin and v < best) or (not keepMin and v > best) then
                    best, bestT = v, buckets[i][F_T]
                end
            end
            index = index + 1
            outValues[index] = best
            outTimes[index]  = bestT
        end
    end
    return outValues, outTimes
end

function Recorder:GetCoverage()
    for tierIndex = #self.tiers, 1, -1 do
        local buckets = self.tiers[tierIndex].buckets
        if #buckets > 0 then
            return GetTime() - buckets[1][F_T]
        end
    end
    return 0
end

function Recorder:CountBuckets()
    local total = 0
    for i = 1, #self.tiers do total = total + #self.tiers[i].buckets end
    return total
end

--------------------------------------------------------------------------
-- Export for the session record
--------------------------------------------------------------------------

--- Flattens all tiers into one array for persistence, capped so a marathon
--- session cannot blow up the database.
function Recorder:ExportBuckets()
    local out = {}
    for tierIndex = #self.tiers, 1, -1 do
        local buckets = self.tiers[tierIndex].buckets
        for i = 1, #buckets do
            local b = buckets[i]
            out[#out + 1] = { b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9] }
        end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)

    local cap = C.MAX_BUCKETS_PER_SESSION
    if #out > cap then
        -- Keep every Nth bucket rather than truncating one end: a session
        -- summary that only covers the first hour would be misleading.
        local step = #out / cap
        local trimmed = {}
        for i = 1, cap do trimmed[i] = out[math.floor((i - 1) * step) + 1] end
        out = trimmed
    end
    return out
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Recorder:OnInitialize()
    self.tiers = BuildTiers()
end

function Recorder:OnEnable()
    local intervals = WTM.db.profile.sampling.intervals
    WTM.Scheduler:Register("history", function() Recorder:Sample() end,
        intervals.history, C.SAMPLE_DEFAULTS.history.burst, 0.85, "sampler")
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function Recorder:Reset()
    self.tiers = BuildTiers()
end
