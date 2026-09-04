--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Overhead.lua

    The addon measuring itself.

    A diagnostic tool that costs more than the problems it finds is worse than
    no tool, so this module:
      * reports our own sampling cost per second, per task,
      * reports our own CPU% and memory the same way we report everyone else's,
      * automatically stretches the sampling intervals when we exceed budget,
      * and says so in the UI instead of quietly degrading.

    Everything reported here is MEASURED with debugprofilestop, never modelled:

        frame accounting   the per-frame callback, timed on a sampled subset of
                           frames (timing every frame would cost more than the
                           work being timed and would corrupt the figure)
        sampling           every scheduler task in the "sampler" category
        event monitoring   the RegisterAllEvents handler and its rate task
        UI                 redrawing the visible page, zero while it is closed

    There is no "estimated module cost" anywhere. If a component cannot be
    measured it is reported as not measured rather than apportioned.

    One honest caveat surfaced in the UI: turning on the client's scriptProfile
    CVar has a cost of its own which this addon cannot measure and is not
    responsible for. It is the client's profiler, not ours.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local api    = Compat.api
local Ring   = WTM.RingBuffer

local Overhead = WTM:NewModule("Overhead")
WTM.Overhead = Overhead

Overhead.current = {
    samplingMsPerSec = 0,   -- scheduler tasks only
    totalMsPerSec    = 0,   -- scheduler tasks + the per-frame callback
    frameMsPerSec    = 0,
    eventsMsPerSec   = 0,
    uiMsPerSec       = 0,
    frameCostMs      = nil, -- measured average per frame, nil until sampled
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
    local perCategory = cost.categoryMsPerSec

    cur.samplingMsPerSec = perCategory.sampler or 0
    cur.eventsMsPerSec   = perCategory.events or 0
    cur.uiMsPerSec       = perCategory.ui or 0
    cur.frameMsPerSec    = perCategory.frame or 0
    cur.frameCostMs      = WTM.Scheduler:GetFrameCallbackCostMs()
    cur.totalMsPerSec    = WTM.Scheduler:GetTotalOverheadMsPerSec()

    local record = WTM.Processes:Get(ADDON_NAME)
    if record then
        cur.cpuPct = record.cpuEma or 0
        cur.memKB  = record.memKB or 0
        cur.memGrowthKBPerMin = record.memGrowthKBPerMin or 0
    end

    self.history:Push(cur.totalMsPerSec)

    local budget = WTM.db.profile.sampling.overheadBudgetMs or C.OVERHEAD_BUDGET_MS_PER_SEC
    if cur.totalMsPerSec >= C.OVERHEAD_CRITICAL_MS_PER_SEC then
        cur.verdict = "critical"
    elseif cur.totalMsPerSec >= budget then
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
    local over = self.current.totalMsPerSec > budget

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
           and self.current.totalMsPerSec < budget * 0.5 then
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

--- What to say beside the UI cost. Measured time is never called "no cost":
--- with nothing on screen the number is what the last visible window left
--- behind in the current averaging window, and the note says exactly that.
local function UICostNote(windowOpen, miniOpen, msPerSec)
    if windowOpen and miniOpen then return "window and live monitor open" end
    if windowOpen then return "window open" end
    if miniOpen then return "live monitor only" end
    if (msPerSec or 0) > 0.001 then
        return "nothing on screen now - residual from the last window that was"
    end
    return "nothing on screen"
end

--- Measured breakdown, newest first. Categories with no measurement yet are
--- returned with `measured = false` rather than a zero.
function Overhead:GetBreakdown(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local cur = self.current
    local windowOpen = WTM.UI.MainWindow and WTM.UI.MainWindow:IsOpen()
    local miniOpen = WTM.UI.LiveMonitor and WTM.UI.LiveMonitor:IsShown()

    -- Both of these are asked for twice below; building them once keeps the
    -- string work out of the table constructor.
    local frameSamples = WTM.Scheduler:GetFrameCallbackSamples()
    local scanCost     = WTM.Memory:DescribeScanCost()

    local rows = {
        { key = "frame",   label = "Frame accounting", ms = cur.frameMsPerSec,
          measured = cur.frameCostMs ~= nil,
          -- The sample count is part of the claim: "averaged over 0 frames"
          -- is not an average, and printing one made a stale reading look
          -- like a fresh measurement.
          note = (cur.frameCostMs and frameSamples > 0)
              and ("%.4f ms per frame, averaged over %d timed frames")
                  :format(cur.frameCostMs, frameSamples)
              or "not yet sampled" },
        { key = "sampler", label = "Sampling tasks", ms = cur.samplingMsPerSec, measured = true,
          -- The per-addon memory scan dominates this line on a client with
          -- many addons, so it is named here rather than left inside a total.
          note = scanCost
              and ("per-addon memory scan: %s"):format(scanCost)
              or "frame time, CPU, memory, network, history, spike detection" },
        { key = "events",  label = "Event monitoring", ms = cur.eventsMsPerSec, measured = true,
          note = ("mode: %s"):format(WTM.Events:GetMode()) },
        { key = "ui",      label = "UI updates", ms = cur.uiMsPerSec, measured = true,
          -- Say what is actually on screen, and never describe measured time as
          -- costing nothing. An earlier version printed "window closed - no
          -- cost" beside a non-zero number, which is exactly the contradiction
          -- this addon exists to avoid. A figure with nothing on screen is
          -- residual from the last window that was, and it says so.
          note = UICostNote(windowOpen, miniOpen, cur.uiMsPerSec) },
    }

    -- Everything the scheduler spent that no task accounts for: walking the
    -- task list every frame to see what is due, and the timing calls around
    -- each dispatch.
    --
    -- This row is ALWAYS present, including when the remainder is zero or
    -- negative. The point of a breakdown is that it reconciles against the
    -- total; a remainder that only appears when it is convenient is not a
    -- reconciliation, and an unexplained gap in an overhead report is worse
    -- than a slightly longer report.
    local attributed = cur.frameMsPerSec + cur.samplingMsPerSec
        + cur.eventsMsPerSec + cur.uiMsPerSec
    local remainder = (cur.totalMsPerSec or 0) - attributed

    local taskCount = 0
    for _ in WTM.Scheduler:IterateTasks() do taskCount = taskCount + 1 end

    local note
    if remainder < -0.001 then
        -- Should not happen: the categories are disjoint by construction. If it
        -- ever does, saying so is the only honest option - silently clamping to
        -- zero would hide a double count in the accounting itself.
        note = ("categories exceed the measured total by %.3f ms/s - the accounting is double counting somewhere")
            :format(-remainder)
    elseif remainder <= 0.001 then
        note = ("nothing left over; %d tasks checked each frame"):format(taskCount)
    else
        note = ("dispatch and timing around %d tasks, checked each frame"):format(taskCount)
    end

    rows[#rows + 1] = {
        key = "dispatch", label = "Scheduler / unattributed",
        ms = remainder, measured = true, note = note,
    }

    for i = 1, #rows do out[i] = rows[i] end
    return out
end

--- The sum of the breakdown rows, and the measured total they should equal.
--- Exposed so the UI can state the reconciliation instead of asking the reader
--- to add up the column themselves.
function Overhead:ReconcileBreakdown()
    local rows = self:GetBreakdown()
    local sum = 0
    for i = 1, #rows do sum = sum + (rows[i].ms or 0) end
    local total = self.current.totalMsPerSec or 0
    return sum, total, sum - total
end

function Overhead:Describe()
    local Fmt = WTM.Format
    local cur = self.current
    local parts = {
        ("total %.2f ms/s"):format(cur.totalMsPerSec),
        ("sampling %.2f"):format(cur.samplingMsPerSec),
        ("events %.2f"):format(cur.eventsMsPerSec),
        ("ui %.2f"):format(cur.uiMsPerSec),
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
    -- Against the frame rate actually being achieved, not an assumed 60.
    local fps = WTM.FrameTime.current.fps
    if not fps or fps <= 0 then fps = 60 end
    local frameMs = 1000 / fps
    local perFrame = self.current.totalMsPerSec / fps
    return perFrame / frameMs * 100
end

function Overhead:GetWarning()
    local cur = self.current
    if cur.verdict == "critical" then
        return ("This addon is measuring %.1f ms/s of its own overhead, which is more than a diagnostic tool should cost. Raise the sampling intervals, or set event monitoring to a cheaper mode, in Settings.")
            :format(cur.totalMsPerSec), "crit"
    elseif cur.verdict == "elevated" then
        return ("Measured overhead is %.1f ms/s, above the %.1f ms/s budget.%s")
            :format(cur.totalMsPerSec, WTM.db.profile.sampling.overheadBudgetMs,
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
    WTM.Scheduler:Register("overhead", function() Overhead:Sample() end, 2.0, 2.0, 0.9, "sampler")
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function Overhead:Reset()
    WTM.Scheduler:ResetCost()
    self.history:Reset()
    overBudgetSince, self.recoverSince = nil, nil
end
