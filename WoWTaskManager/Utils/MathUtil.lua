--[[--------------------------------------------------------------------------
    WoW Task Manager - Utils/MathUtil.lua
    Allocation-free numeric helpers.  Anything used from a sampling path lives
    here and never creates a table.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local M = {}
WTM.Math = M

local floor, ceil, sqrt, abs, log = math.floor, math.ceil, math.sqrt, math.abs, math.log
local huge, min, max = math.huge, math.min, math.max

function M.Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

function M.Round(v, decimals)
    local mult = 10 ^ (decimals or 0)
    return floor(v * mult + 0.5) / mult
end

--- Exponential moving average.  alpha closer to 1 reacts faster.
function M.EMA(previous, sample, alpha)
    if previous == nil then return sample end
    return previous + alpha * (sample - previous)
end

function M.Lerp(a, b, t) return a + (b - a) * t end

function M.SafeDiv(a, b, fallback)
    if b == nil or b == 0 then return fallback or 0 end
    return a / b
end

--------------------------------------------------------------------------
-- Frame time histogram
--------------------------------------------------------------------------
-- Quadratic bucket spacing: index = round(sqrt(ms / maxMs) * (n - 1)).
-- That gives ~0.15 ms resolution around 8 ms and ~10 ms resolution around
-- 400 ms, which is exactly the trade we want: precise where frames live,
-- coarse where freezes live.

local HIST_N   = WTM.C and WTM.C.HIST_BUCKETS or 64
local HIST_MAX = WTM.C and WTM.C.HIST_MAX_MS or 500

function M.HistogramIndex(ms)
    if ms <= 0 then return 1 end
    if ms >= HIST_MAX then return HIST_N end
    local i = floor(sqrt(ms / HIST_MAX) * (HIST_N - 1)) + 1
    return i
end

--- Inverse of HistogramIndex: the lower bound in ms of a bucket.
function M.HistogramValue(index)
    local f = (index - 1) / (HIST_N - 1)
    return f * f * HIST_MAX
end

function M.NewHistogram(out)
    out = out or {}
    for i = 1, HIST_N do out[i] = 0 end
    out.count = 0
    return out
end

function M.ResetHistogram(h)
    for i = 1, HIST_N do h[i] = 0 end
    h.count = 0
end

--- Percentile of the frame time distribution, in ms.
--- p = 0.99 gives the frame time that 99% of frames were faster than, i.e. the
--- value behind "1% low FPS".
function M.HistogramPercentile(h, p)
    local total = h.count or 0
    if total == 0 then return 0 end
    local target = total * p
    local running = 0
    for i = 1, HIST_N do
        running = running + h[i]
        if running >= target then
            return M.HistogramValue(i + 1)
        end
    end
    return HIST_MAX
end

function M.HistogramAdd(h, ms)
    local i = M.HistogramIndex(ms)
    h[i] = h[i] + 1
    h.count = (h.count or 0) + 1
end

--- Frame time in ms -> FPS.  Used to express percentiles as "1% low FPS".
function M.MsToFPS(ms)
    if ms <= 0 then return 0 end
    return 1000 / ms
end

--------------------------------------------------------------------------
-- Correlation
--------------------------------------------------------------------------

--- Phi coefficient for two boolean series given as 2x2 counts.
---   a = both true, b = x true / y false, c = x false / y true, d = both false
--- Returns 0 when the denominator collapses (a degenerate series correlates
--- with nothing, and pretending otherwise would be a fabricated number).
function M.Phi(a, b, c, d)
    local n1 = (a + b) * (c + d) * (a + c) * (b + d)
    if n1 <= 0 then return 0 end
    return (a * d - b * c) / sqrt(n1)
end

--- Pearson correlation over two equal-length numeric arrays.
function M.Pearson(xs, ys, n)
    n = n or min(#xs, #ys)
    if n < 2 then return 0 end
    local sx, sy, sxx, syy, sxy = 0, 0, 0, 0, 0
    for i = 1, n do
        local x, y = xs[i], ys[i]
        sx = sx + x; sy = sy + y
        sxx = sxx + x * x; syy = syy + y * y
        sxy = sxy + x * y
    end
    local num = n * sxy - sx * sy
    local den = sqrt((n * sxx - sx * sx) * (n * syy - sy * sy))
    if den == 0 then return 0 end
    return num / den
end

--- Least-squares slope of y over x.  Used for memory growth per minute.
function M.Slope(xs, ys, n)
    n = n or min(#xs, #ys)
    if n < 2 then return 0 end
    local sx, sy, sxx, sxy = 0, 0, 0, 0
    for i = 1, n do
        local x, y = xs[i], ys[i]
        sx = sx + x; sy = sy + y
        sxx = sxx + x * x; sxy = sxy + x * y
    end
    local den = n * sxx - sx * sx
    if den == 0 then return 0 end
    return (n * sxy - sx * sy) / den
end

function M.StdDev(values, n, meanOut)
    n = n or #values
    if n < 2 then return 0, values[1] or 0 end
    local sum = 0
    for i = 1, n do sum = sum + values[i] end
    local mean = sum / n
    local acc = 0
    for i = 1, n do
        local d = values[i] - mean
        acc = acc + d * d
    end
    return sqrt(acc / (n - 1)), mean
end

--------------------------------------------------------------------------
-- Axis helpers for the graph engine
--------------------------------------------------------------------------

--- Rounds a range up to a "nice" number (1, 2, 5 x 10^n) so the grid does not
--- get labels like 37.4194.
function M.NiceCeil(v)
    if v <= 0 then return 1 end
    local exp = floor(log(v) / log(10))
    local mag = 10 ^ exp
    local norm = v / mag
    local nice
    if norm <= 1 then nice = 1
    elseif norm <= 2 then nice = 2
    elseif norm <= 5 then nice = 5
    else nice = 10 end
    return nice * mag
end

function M.NiceStep(range, targetLines)
    if range <= 0 then return 1 end
    return M.NiceCeil(range / (targetLines or 4))
end

return M
