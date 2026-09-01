--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Network.lua

    GetNetStats() is the only latency source an addon has, and the client only
    refreshes it roughly every 30 seconds.  Polling it faster does not produce
    a faster signal, it just produces the same number repeatedly - so this
    module samples slowly and, importantly, labels the value with its age so
    nobody reads a 28-second-old latency figure as "right now".
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local api    = Compat.api
local Ring   = WTM.RingBuffer
local Math   = WTM.Math

local Network = WTM:NewModule("Network")
WTM.Network = Network

Network.current = {
    latencyHome  = 0,
    latencyWorld = 0,
    bandwidthIn  = 0,
    bandwidthOut = 0,
    lastChangeAt = 0,   -- when the value last actually moved
    ageSeconds   = 0,
}

Network.session = {
    peakHome  = 0,
    peakWorld = 0,
    sumHome   = 0,
    sumWorld  = 0,
    samples   = 0,
    spikes    = 0,
}

Network.history = { home = nil, world = nil }

local SPIKE_MULTIPLIER = 2.0
local SPIKE_MIN_MS     = 150
local baselineWorld    = nil

function Network:Sample()
    if not api.GetNetStats then return end
    local bwIn, bwOut, latHome, latWorld = Compat.SafeCall("GetNetStats", api.GetNetStats)
    if latWorld == nil then return end

    local cur = self.current
    local changed = (latHome ~= cur.latencyHome) or (latWorld ~= cur.latencyWorld)

    cur.bandwidthIn  = bwIn or 0
    cur.bandwidthOut = bwOut or 0
    cur.latencyHome  = latHome or 0
    cur.latencyWorld = latWorld or 0

    if changed then
        cur.lastChangeAt = GetTime()

        -- Only a genuinely new reading is worth recording; otherwise the graph
        -- would show a staircase of repeated samples.
        local s = self.session
        s.samples = s.samples + 1
        s.sumHome  = s.sumHome + cur.latencyHome
        s.sumWorld = s.sumWorld + cur.latencyWorld
        if cur.latencyHome > s.peakHome then s.peakHome = cur.latencyHome end
        if cur.latencyWorld > s.peakWorld then s.peakWorld = cur.latencyWorld end

        baselineWorld = Math.EMA(baselineWorld, cur.latencyWorld, 0.2)
        if cur.latencyWorld >= SPIKE_MIN_MS
           and baselineWorld and cur.latencyWorld > baselineWorld * SPIKE_MULTIPLIER then
            s.spikes = s.spikes + 1
            WTM.Context:AddMarker("netspike",
                ("World latency %d ms (baseline %d ms)"):format(cur.latencyWorld, baselineWorld))
        end
    end

    self.history.home:Push(cur.latencyHome)
    self.history.world:Push(cur.latencyWorld)
    cur.ageSeconds = GetTime() - cur.lastChangeAt
end

function Network:GetAverages()
    local s = self.session
    if s.samples == 0 then return 0, 0 end
    return s.sumHome / s.samples, s.sumWorld / s.samples
end

--- True when the reading is stale enough that the UI should say so.
function Network:IsStale()
    return (GetTime() - self.current.lastChangeAt) > 35
end

function Network:OnInitialize()
    self.history.home  = Ring.New(256)
    self.history.world = Ring.New(256)
    self.available = WTM.Caps:Has("latency")
end

function Network:OnEnable()
    if not self.available then return end
    local intervals = WTM.db.profile.sampling.intervals
    WTM.Scheduler:Register("network", function() Network:Sample() end,
        intervals.network, C.SAMPLE_DEFAULTS.network.burst, 0.3)
    self.current.lastChangeAt = GetTime()
    self:Sample()
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function Network:Reset()
    local s = self.session
    s.peakHome, s.peakWorld, s.sumHome, s.sumWorld, s.samples, s.spikes = 0, 0, 0, 0, 0, 0
    baselineWorld = nil
    self.history.home:Reset()
    self.history.world:Reset()
end
