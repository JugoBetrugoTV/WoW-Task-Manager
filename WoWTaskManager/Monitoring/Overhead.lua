--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Overhead.lua

    The addon measuring itself.

    A diagnostic tool that costs more than the problems it finds is worse than
    no tool, so this module:
      * reports our own sampling cost per second, per task,
      * reports our own CPU% and memory the same way we report everyone else's,
      * automatically stretches the sampling intervals when we exceed budget,
      * and says so in the UI instead of quietly degrading.

    Note the honest caveat that is surfaced in the UI: turning on the client's
    scriptProfile CVar has a cost of its own that this addon cannot measure and
    is not responsible for. It is the client's profiler, not ours.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local api    = Compat.api
local Ring   = WTM.RingBuffer

local Overhead = WTM:NewModule("Overhead")
WTM.Overhead = Overhead

Overhead.current = {
    samplingMsPerSec = 0,
    cpuPct           = 0,
    memKB            = 0,
    memGrowthKBPerMin = 0,
    throttleLevel    = 0,
    verdict          = "ok",     -- ok | elevated | critical
}

Overhead.history = nil

local BUDGET_WINDOW = 5     -- seconds of sustained overspend before throttling
local overBudgetSince = nil

function Overhead:Sample()
    local cur = self.current
    local cost = WTM.Scheduler.cost

    cur.samplingMsPerSec = cost.msPerSec

    local record = WTM.Processes:Get(ADDON_NAME)
    if record then
        cur.cpuPct = record.cpuEma or 0
        cur.memKB  = record.memKB or 0
        cur.memGrowthKBPerMin = record.memGrowthKBPerMin or 0
    end

    self.history:Push(cur.samplingMsPerSec)

    local budget = WTM.db.profile.sampling.overheadBudgetMs or C.OVERHEAD_BUDGET_MS_PER_SEC
    if cur.samplingMsPerSec >= C.OVERHEAD_CRITICAL_MS_PER_SEC then
        cur.verdict = "critical"
    elseif cur.samplingMsPerSec >= budget then
        cur.verdict = "elevated"
    else
        cur.verdict = "ok"
    end

    self:UpdateThrottle(budget)
    cur.throttleLevel = WTM.Scheduler.cost.throttleLevel
end

--- Only throttles on SUSTAINED overspend.  A single expensive memory scan is
--- expected and must not permanently degrade the sampling rate.
function Overhead:UpdateThrottle(budget)
    if not WTM.db.profile.sampling.autoThrottle then
        if WTM.Scheduler.cost.throttleLevel ~= 0 then WTM.Scheduler:ReloadIntervals() end
        return
    end

    local now = GetTime()
    local over = self.current.samplingMsPerSec > budget

    if over then
        overBudgetSince = overBudgetSince or now
        if (now - overBudgetSince) >= BUDGET_WINDOW then
            local level = WTM.Scheduler.cost.throttleLevel + 1
            WTM.Scheduler:ApplyThrottle(level)
            overBudgetSince = now
            if level == 1 then
                WTM:SendMessage("WTM_THROTTLED", level)
            end
        end
    else
        overBudgetSince = nil
        -- Recover slowly: drop one throttle level at a time once we have been
        -- comfortably under budget.
        if WTM.Scheduler.cost.throttleLevel > 0
           and self.current.samplingMsPerSec < budget * 0.5 then
            self.recoverSince = self.recoverSince or now
            if (now - self.recoverSince) >= BUDGET_WINDOW * 3 then
                WTM.Scheduler:ApplyThrottle(WTM.Scheduler.cost.throttleLevel - 1)
                self.recoverSince = nil
            end
        else
            self.recoverSince = nil
        end
    end
end

--------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------

function Overhead:GetTaskBreakdown(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    for _, task in WTM.Scheduler:IterateTasks() do
        local stats = WTM.Scheduler.cost.perTask[task.name]
        if stats and stats.calls > 0 then
            out[#out + 1] = {
                name     = task.name,
                calls    = stats.calls,
                avgMs    = stats.avgMs,
                maxMs    = stats.maxMs,
                totalMs  = stats.totalMs,
                interval = task.normal,
                enabled  = task.enabled,
                -- Cost per second of wall clock, which is the number that
                -- actually matters when comparing tasks.
                msPerSec = stats.avgMs / math.max(0.001, task.normal),
            }
        end
    end
    table.sort(out, function(a, b) return a.msPerSec > b.msPerSec end)
    return out
end

function Overhead:Describe()
    local Fmt = WTM.Format
    local cur = self.current
    local parts = {
        ("sampling %.2f ms/s"):format(cur.samplingMsPerSec),
        ("memory %s"):format(Fmt.Memory(cur.memKB)),
    }
    if WTM.CPU.available then
        parts[#parts + 1] = ("CPU %.2f%%"):format(cur.cpuPct)
    else
        parts[#parts + 1] = "CPU n/a (profiling off)"
    end
    if cur.throttleLevel > 0 then
        parts[#parts + 1] = ("throttled x%d"):format(cur.throttleLevel)
    end
    return "Own cost: " .. table.concat(parts, ", ")
end

--- The percentage figure shown in the sidebar.  Expressed against a 16.67 ms
--- frame budget, because "0.4% of a frame" is the question people are actually
--- asking when they look at a monitor's overhead.
function Overhead:GetFrameBudgetPercent()
    local perFrame = self.current.samplingMsPerSec / 60
    return perFrame / 16.67 * 100
end

function Overhead:GetWarning()
    local cur = self.current
    if cur.verdict == "critical" then
        return ("This addon is using %.1f ms/s of sampling time, which is more than a diagnostic tool should cost. Increase the sampling intervals in Settings.")
            :format(cur.samplingMsPerSec), "crit"
    elseif cur.verdict == "elevated" then
        return ("Sampling cost is %.1f ms/s, above the %.1f ms/s budget.%s")
            :format(cur.samplingMsPerSec, WTM.db.profile.sampling.overheadBudgetMs,
                    cur.throttleLevel > 0 and " Intervals have been stretched automatically." or ""), "warn"
    end
    return nil
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Overhead:OnInitialize()
    self.history = Ring.New(180)
end

function Overhead:OnEnable()
    WTM.Scheduler:Register("overhead", function() Overhead:Sample() end, 2.0, 2.0, 0.9)
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function Overhead:Reset()
    WTM.Scheduler:ResetCost()
    self.history:Reset()
    overBudgetSince, self.recoverSince = nil, nil
end
