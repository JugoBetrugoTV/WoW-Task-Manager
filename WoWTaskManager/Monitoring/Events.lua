--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Events.lua

    Global event accounting via frame:RegisterAllEvents().

    That API is the documented way to observe every event the client fires -
    Blizzard's own event trace uses it.  It is also the single riskiest thing
    this addon does for performance, because COMBAT_LOG_EVENT_UNFILTERED alone
    can fire several hundred times a second in a raid.

    So the handler is as small as a Lua function gets: one table index, one
    add, one counter.  No string concatenation, no varargs capture, no table
    creation.  Everything derived (rates, baselines, storms) happens once per
    second in the sampling task, not per event.

    It is also switchable: profile.events.enabled turns the whole thing off,
    including the RegisterAllEvents subscription.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local Ring   = WTM.RingBuffer
local MathU  = WTM.Math

local Events = WTM:NewModule("Events")
WTM.Events = Events

--------------------------------------------------------------------------
-- Counters
--------------------------------------------------------------------------

local counts     = {}   -- event -> count since the last window close
local totals     = {}   -- event -> count since session start
local rates      = {}   -- event -> calls per second in the last window
local peaks      = {}   -- event -> highest rate seen
local baselines  = {}   -- event -> EMA of the rate
local lastSeen   = {}   -- event -> GetTime()
local tracked    = {}   -- array of event names, insertion ordered
local trackedSet = {}

local windowTotal   = 0
local sessionTotal  = 0
local distinctCount = 0

Events.current = {
    perSecond    = 0,
    peakPerSecond = 0,
    distinct     = 0,
    total        = 0,
}

Events.history = nil      -- RingBuffer of events/sec
Events.storms  = {}       -- detected storms, bounded

local MAX_STORMS = 50

--------------------------------------------------------------------------
-- The hot path
--------------------------------------------------------------------------
-- Deliberately a bare closure over upvalues rather than a method: `self`
-- lookups and table field access would be measurable at 1000 events/second.

local listener = CreateFrame("Frame", "WTMEventListener")
local capturing = false

local function OnAnyEvent(_, event)
    local n = counts[event]
    if n then
        counts[event] = n + 1
    else
        -- First sighting of this event.  The `tracked` list is capped so a
        -- client that invents new event names cannot grow this without bound.
        if distinctCount < C.EVENT_MAX_TRACKED then
            counts[event] = 1
            totals[event] = 0
            distinctCount = distinctCount + 1
            tracked[distinctCount] = event
            trackedSet[event] = true
        else
            -- Past the distinct-event cap we stop tracking this event
            -- individually, but it still happened: counting it in the total
            -- keeps the overall rate honest instead of silently under-reporting.
            windowTotal = windowTotal + 1
            return
        end
    end
    windowTotal = windowTotal + 1
end

--------------------------------------------------------------------------
-- Window close (once per second)
--------------------------------------------------------------------------

function Events:Sample(delta)
    if delta <= 0 then return end

    local now = GetTime()
    local perSecond = windowTotal / delta
    sessionTotal = sessionTotal + windowTotal

    local cur = self.current
    cur.perSecond = perSecond
    cur.total     = sessionTotal
    cur.distinct  = distinctCount
    if perSecond > cur.peakPerSecond then cur.peakPerSecond = perSecond end

    self.history:Push(perSecond)

    local stormMultiplier = WTM.db.profile.events.stormMultiplier
    local stormMinRate    = WTM.db.profile.events.stormMinRate

    for i = 1, distinctCount do
        local event = tracked[i]
        local n = counts[event]
        if n and n > 0 then
            local rate = n / delta
            rates[event]  = rate
            totals[event] = (totals[event] or 0) + n
            lastSeen[event] = now
            if rate > (peaks[event] or 0) then peaks[event] = rate end

            local baseline = baselines[event]
            if baseline and rate >= stormMinRate and rate > baseline * stormMultiplier then
                self:OnStorm(event, rate, baseline)
            end
            baselines[event] = MathU.EMA(baseline, rate, C.EVENT_BASELINE_ALPHA)

            counts[event] = 0
        else
            rates[event] = 0
            baselines[event] = MathU.EMA(baselines[event], 0, C.EVENT_BASELINE_ALPHA)
        end
    end

    windowTotal = 0
end

--------------------------------------------------------------------------
-- Storm detection
--------------------------------------------------------------------------

local activeStorms = {}

function Events:OnStorm(event, rate, baseline)
    local now = GetTime()
    local storm = activeStorms[event]
    if storm then
        -- Still going: extend it rather than raising a second incident.
        storm.endedAt = now
        storm.peakRate = math.max(storm.peakRate, rate)
        return
    end

    storm = {
        event    = event,
        startedAt = now,
        endedAt  = now,
        baseline = baseline,
        peakRate = rate,
        rate     = rate,
        cpuAtStart = WTM.CPU.available and WTM.CPU.current.totalPct or nil,
    }
    activeStorms[event] = storm

    local storms = self.storms
    if #storms >= MAX_STORMS then table.remove(storms, 1) end
    storms[#storms + 1] = storm

    WTM.Context:AddMarker("eventstorm",
        ("%s  %d/s (normal %d/s)"):format(event, rate, baseline))
    WTM:SendMessage("WTM_EVENT_STORM", event, rate, baseline)
end

--- Storms that have not been fed for a while are closed out so their duration
--- is accurate.  Runs in the same task as Sample.
function Events:ExpireStorms()
    local now = GetTime()
    for event, storm in pairs(activeStorms) do
        if (now - storm.endedAt) > C.EVENT_STORM_MIN_SEC * 2 then
            storm.duration = storm.endedAt - storm.startedAt
            activeStorms[event] = nil
        end
    end
end

function Events:GetActiveStorms(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    for _, storm in pairs(activeStorms) do out[#out + 1] = storm end
    table.sort(out, function(a, b) return a.peakRate > b.peakRate end)
    return out
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

--- Builds the event table view.  Reuses `out` between refreshes.
function Events:BuildView(out, sortKey, ascending, filter)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local needle = filter and filter ~= "" and filter:upper() or nil
    local now = GetTime()

    for i = 1, distinctCount do
        local event = tracked[i]
        if not needle or event:find(needle, 1, true) then
            out[#out + 1] = {
                event    = event,
                rate     = rates[event] or 0,
                total    = totals[event] or 0,
                peak     = peaks[event] or 0,
                baseline = baselines[event] or 0,
                lastAgo  = lastSeen[event] and (now - lastSeen[event]) or nil,
            }
        end
    end

    local sorters = {
        rate  = function(a, b) return a.rate > b.rate end,
        total = function(a, b) return a.total > b.total end,
        peak  = function(a, b) return a.peak > b.peak end,
        name  = function(a, b) return a.event < b.event end,
        last  = function(a, b) return (a.lastAgo or 1e9) < (b.lastAgo or 1e9) end,
    }
    local sorter = sorters[sortKey or "rate"] or sorters.rate
    if ascending then
        table.sort(out, function(a, b) return sorter(b, a) end)
    else
        table.sort(out, sorter)
    end
    return out
end

--- The busiest events by total count, used by the frame attribution scan and
--- by spike snapshots.
function Events:GetTopEventNames(limit, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local scratch = {}
    for i = 1, distinctCount do
        scratch[i] = tracked[i]
    end
    table.sort(scratch, function(a, b) return (totals[a] or 0) > (totals[b] or 0) end)
    for i = 1, math.min(limit or 20, #scratch) do out[i] = scratch[i] end
    return out
end

--- Snapshot of what fired recently, for a spike record.  Uses the per-window
--- rates, which is the finest resolution available without storing every event.
function Events:SnapshotTop(out, limit)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    for i = 1, distinctCount do
        local event = tracked[i]
        local rate = rates[event] or 0
        if rate > 0 then
            out[#out + 1] = { event = event, rate = rate, count = math.floor(rate + 0.5) }
        end
    end
    table.sort(out, function(a, b) return a.rate > b.rate end)
    for i = #out, (limit or 8) + 1, -1 do out[i] = nil end
    return out
end

function Events:GetRate(event) return rates[event] or 0 end
function Events:GetTotal(event) return totals[event] or 0 end
function Events:GetDistinctCount() return distinctCount end
function Events:IsAtTrackingCap() return distinctCount >= C.EVENT_MAX_TRACKED end

--------------------------------------------------------------------------
-- Capture control
--------------------------------------------------------------------------

function Events:StartCapture()
    if capturing then return true end
    if not WTM.Caps:Has("eventRate") then return false, C.TXT_UNAVAILABLE_CLIENT end
    local ok = pcall(listener.RegisterAllEvents, listener)
    if not ok then return false, "RegisterAllEvents was refused" end
    listener:SetScript("OnEvent", OnAnyEvent)
    capturing = true
    return true
end

function Events:StopCapture()
    if not capturing then return end
    pcall(listener.UnregisterAllEvents, listener)
    listener:SetScript("OnEvent", nil)
    capturing = false
end

function Events:IsCapturing() return capturing end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Events:OnInitialize()
    self.history = Ring.New(360)
    self.available = WTM.Caps:Has("eventRate")
end

function Events:OnEnable()
    if not self.available then return end
    if not WTM.db.profile.events.enabled then return end

    local ok, err = self:StartCapture()
    if not ok then
        self.available = false
        self.reason = err
        return
    end

    local intervals = WTM.db.profile.sampling.intervals
    WTM.Scheduler:Register("events", function(delta)
        Events:Sample(delta)
        Events:ExpireStorms()
    end, intervals.events, C.SAMPLE_DEFAULTS.events.burst, 0.75)

    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function Events:OnDisable()
    self:StopCapture()
end

function Events:Reset()
    for i = 1, distinctCount do
        local event = tracked[i]
        counts[event], totals[event], rates[event] = 0, 0, 0
        peaks[event], baselines[event] = 0, nil
    end
    windowTotal, sessionTotal = 0, 0
    local cur = self.current
    cur.perSecond, cur.peakPerSecond, cur.total = 0, 0, 0
    for i = #self.storms, 1, -1 do self.storms[i] = nil end
    for k in pairs(activeStorms) do activeStorms[k] = nil end
    self.history:Reset()
end
