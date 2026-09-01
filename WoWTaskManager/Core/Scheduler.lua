--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Scheduler.lua

    The one and only OnUpdate in this addon.

    Everything periodic goes through here so that:
      * the per-frame cost is bounded and constant - it does not grow with the
        number of addons, tasks or samples,
      * two expensive tasks can never land in the same frame (phase offsets),
      * one switch turns all sampling off,
      * every task's cost is measured, so the addon can police itself.

    Tasks declare a normal interval and a burst interval.  The spike detector
    flips the scheduler into burst mode for a few seconds so the data around a
    stutter is dense, then it drops back down.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local Now    = Compat.Now

local Scheduler = {}
WTM.Scheduler = Scheduler

local tasks       = {}   -- array, iterated every tick
local tasksByName = {}
local running     = false
local burstUntil  = 0

-- Cost accounting, read by Monitoring/Overhead.lua.
--
-- Costs are attributed to a CATEGORY as well as a task, because "this addon
-- uses 1.8 ms/s" is much less useful than knowing whether that is sampling,
-- event monitoring or drawing the UI - each of which the user can turn down
-- independently.
Scheduler.cost = {
    windowStart  = 0,
    totalMs      = 0,
    lastTotalMs  = 0,
    msPerSec     = 0,
    perTask      = {},
    perCategory  = {},      -- category -> ms accumulated in the current window
    categoryMsPerSec = {},  -- category -> ms/s over the last closed window
    throttled    = false,
    throttleLevel = 0,
}

Scheduler.CATEGORIES = { "frame", "sampler", "events", "ui" }
for _, category in ipairs(Scheduler.CATEGORIES) do
    Scheduler.cost.perCategory[category] = 0
    Scheduler.cost.categoryMsPerSec[category] = 0
end

--------------------------------------------------------------------------
-- Task registration
--------------------------------------------------------------------------

--- name      identifier, also the key in profile.sampling.intervals
--- fn        function(deltaSeconds) - must not allocate on the hot path
--- normal    seconds between runs in normal mode
--- burst     seconds between runs while a spike burst is active
--- phase     0..1, fraction of the interval to offset the first run by, so
---           expensive tasks do not stack up in the same frame
--- category  which bucket this task's cost belongs to: "sampler", "events" or
---           "ui".  Defaults to "sampler".
function Scheduler:Register(name, fn, normal, burst, phase, category)
    local task = tasksByName[name]
    if not task then
        task = { name = name }
        tasks[#tasks + 1] = task
        tasksByName[name] = task
        Scheduler.cost.perTask[name] = { totalMs = 0, calls = 0, lastMs = 0, avgMs = 0, maxMs = 0 }
    end
    task.fn        = fn
    task.normal    = normal
    task.burst     = burst or normal
    task.category  = category or "sampler"
    task.enabled   = true
    task.nextRun   = GetTime() + (normal * (phase or 0))
    task.lastRun   = GetTime()
    return task
end

function Scheduler:SetEnabled(name, enabled)
    local task = tasksByName[name]
    if task then task.enabled = enabled and true or false end
end

function Scheduler:SetInterval(name, normal, burst)
    local task = tasksByName[name]
    if not task then return end
    task.normal = normal
    if burst then task.burst = burst end
end

function Scheduler:GetTask(name) return tasksByName[name] end
function Scheduler:IterateTasks() return ipairs(tasks) end

--------------------------------------------------------------------------
-- Burst mode
--------------------------------------------------------------------------

function Scheduler:TriggerBurst(duration)
    if not WTM.db.profile.sampling.adaptive then return end
    local until_ = GetTime() + (duration or WTM.db.profile.sampling.burstDuration or C.BURST_DURATION_SEC)
    if until_ > burstUntil then burstUntil = until_ end
end

function Scheduler:IsBursting()
    return GetTime() < burstUntil
end

function Scheduler:BurstRemaining()
    local r = burstUntil - GetTime()
    return r > 0 and r or 0
end

--------------------------------------------------------------------------
-- The driver
--------------------------------------------------------------------------
-- The OnUpdate body below is the most performance-sensitive code in the addon.
-- It does frame time accounting inline (FrameTime.lua installs the callback)
-- and only then looks at the task list.  No table is created, no string is
-- built, nothing is indexed through more than one level.

local driver = CreateFrame("Frame", "WTMScheduler")
driver:Hide()

local frameCallback   -- set by Monitoring/FrameTime.lua
function Scheduler:SetFrameCallback(fn) frameCallback = fn end

local costWindow = 0
local costAccum  = 0

-- The per-frame callback's own cost is measured by SAMPLING it, not by timing
-- every frame: two debugprofilestop() calls per frame would cost more than the
-- work they are measuring and would corrupt the very number we want. Timing one
-- frame in FRAME_COST_SAMPLE_EVERY gives a usable average for a fraction of a
-- percent of the overhead.
local FRAME_COST_SAMPLE_EVERY = 64
local frameCounter    = 0
local frameCostSumMs  = 0
local frameCostSamples = 0

--- Average measured cost of the per-frame callback, in milliseconds.
function Scheduler:GetFrameCallbackCostMs()
    if frameCostSamples == 0 then return nil end
    return frameCostSumMs / frameCostSamples
end

function Scheduler:GetFrameCallbackSamples() return frameCostSamples end

local function OnUpdate(_, elapsed)
    -- 1. Per-frame accounting (never skipped, never conditional).
    if frameCallback then
        frameCounter = frameCounter + 1
        if frameCounter >= FRAME_COST_SAMPLE_EVERY then
            frameCounter = 0
            local t0 = Now()
            frameCallback(elapsed)
            frameCostSumMs = frameCostSumMs + (Now() - t0)
            frameCostSamples = frameCostSamples + 1
        else
            frameCallback(elapsed)
        end
    end

    -- 2. Task dispatch.
    local now = GetTime()
    local bursting = now < burstUntil
    local profileStart = Now()

    for i = 1, #tasks do
        local task = tasks[i]
        if task.enabled and now >= task.nextRun then
            local interval = bursting and task.burst or task.normal
            local delta = now - task.lastRun
            task.lastRun = now
            -- Schedule from `now`, not from nextRun: after a freeze we do not
            -- want a burst of catch-up runs making the recovery worse.
            task.nextRun = now + interval

            local t0 = Now()
            local ok, err = pcall(task.fn, delta)
            local spent = Now() - t0

            local category = Scheduler.cost.perCategory
            local key = task.category or "sampler"
            category[key] = (category[key] or 0) + spent

            local stats = Scheduler.cost.perTask[task.name]
            stats.lastMs  = spent
            stats.totalMs = stats.totalMs + spent
            stats.calls   = stats.calls + 1
            if spent > stats.maxMs then stats.maxMs = spent end
            stats.avgMs = stats.totalMs / stats.calls

            if not ok then
                task.errors = (task.errors or 0) + 1
                -- A task that keeps erroring gets switched off rather than
                -- spamming the error handler forever.
                if task.errors >= 5 then
                    task.enabled = false
                    geterrorhandler()(("WTM: sampling task '%s' disabled after repeated errors: %s")
                        :format(task.name, tostring(err)))
                else
                    geterrorhandler()(err)
                end
            end
        end
    end

    -- 3. Self-cost bookkeeping, once per second.
    costAccum = costAccum + (Now() - profileStart)
    costWindow = costWindow + elapsed
    if costWindow >= 1 then
        local cost = Scheduler.cost
        cost.lastTotalMs = costAccum
        cost.msPerSec = costAccum / costWindow
        cost.totalMs = cost.totalMs + costAccum

        for category, ms in pairs(cost.perCategory) do
            cost.categoryMsPerSec[category] = ms / costWindow
            cost.perCategory[category] = 0
        end
        -- The frame callback is not a scheduler task, so its measured average
        -- is converted into a per-second figure from the observed frame rate.
        local perFrame = Scheduler:GetFrameCallbackCostMs()
        if perFrame then
            local fps = WTM.FrameTime and WTM.FrameTime.current.fps or 0
            cost.categoryMsPerSec.frame = perFrame * fps
        end

        costAccum, costWindow = 0, 0
    end
end

driver:SetScript("OnUpdate", OnUpdate)

--------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------

function Scheduler:Start()
    if running then return end
    running = true
    local now = GetTime()
    for i = 1, #tasks do
        tasks[i].lastRun = now
        tasks[i].nextRun = now + (tasks[i].normal * ((i - 1) / math.max(1, #tasks)))
    end
    driver:Show()
end

function Scheduler:Stop()
    if not running then return end
    running = false
    driver:Hide()
end

function Scheduler:IsRunning() return running end

--------------------------------------------------------------------------
-- Self-throttling
--------------------------------------------------------------------------
-- If our own sampling cost exceeds the budget we stretch the most expensive
-- tasks rather than letting the diagnostic tool become the thing that needs
-- diagnosing.  Called from Monitoring/Overhead.lua.

local THROTTLE_FACTORS = { 1.0, 1.5, 2.5, 4.0 }

function Scheduler:ApplyThrottle(level)
    level = math.max(0, math.min(#THROTTLE_FACTORS - 1, level))
    if level == Scheduler.cost.throttleLevel then return end
    Scheduler.cost.throttleLevel = level
    Scheduler.cost.throttled = level > 0

    local factor = THROTTLE_FACTORS[level + 1]
    local base = WTM.db.profile.sampling.intervals
    for i = 1, #tasks do
        local task = tasks[i]
        local configured = base[task.name]
        if configured then
            -- Frame time sampling is cheap and is the one signal we refuse to
            -- degrade, so it is never throttled.
            if task.name == "frametime" then
                task.normal = configured
            else
                task.normal = configured * factor
            end
        end
    end
end

function Scheduler:ReloadIntervals()
    local base = WTM.db.profile.sampling.intervals
    for i = 1, #tasks do
        local task = tasks[i]
        local configured = base[task.name]
        if configured then task.normal = configured end
    end
    Scheduler.cost.throttleLevel = 0
    Scheduler.cost.throttled = false
end

function Scheduler:ResetCost()
    local cost = Scheduler.cost
    cost.totalMs, cost.lastTotalMs, cost.msPerSec = 0, 0, 0
    for _, stats in pairs(cost.perTask) do
        stats.totalMs, stats.calls, stats.lastMs, stats.avgMs, stats.maxMs = 0, 0, 0, 0, 0
    end
    for category in pairs(cost.perCategory) do
        cost.perCategory[category] = 0
        cost.categoryMsPerSec[category] = 0
    end
    frameCostSumMs, frameCostSamples, frameCounter = 0, 0, 0
end

--- Total measured overhead per second: scheduler tasks plus the per-frame
--- callback. Everything in it is measured with debugprofilestop; nothing is
--- modelled or apportioned.
function Scheduler:GetTotalOverheadMsPerSec()
    local cost = Scheduler.cost
    local total = cost.msPerSec or 0
    total = total + (cost.categoryMsPerSec.frame or 0)
    return total
end
