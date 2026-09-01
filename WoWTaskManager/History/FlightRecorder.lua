--[[--------------------------------------------------------------------------
    WoW Task Manager - History/FlightRecorder.lua

    The answer to "what happened in the 30 seconds before the freeze".

    A pre-allocated ring of slots is filled continuously at the frame-time
    sample rate.  Nothing is written to disk and nothing is allocated while it
    runs - slots are overwritten in place.  When the spike detector flags a
    hitch it does NOT copy anything immediately: it sets a pending capture and
    waits out the post-window, so the resulting incident contains the recovery
    as well as the run-up.

        ring:  [..][..][..][XX][..][..][..][..]
                            ^ spike
               |<- pre 30s ->|<- post 15s ->|
               \________ incident _________/

    Copying an incident out of the ring is the only place in the addon that
    allocates meaningfully, and it happens on a spike, not on a timer.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local SlotRing = WTM.SlotRing

local FlightRecorder = WTM:NewModule("FlightRecorder")
WTM.FlightRecorder = FlightRecorder

local SLOT_FIELDS = {
    "t", "fps", "frameAvgMs", "frameMaxMs", "frameMinMs",
    "latHome", "latWorld", "luaKB", "events", "cpuMs", "cpuPct", "flags",
}

FlightRecorder.ring = nil
FlightRecorder.incidents = {}     -- full-resolution, RAM only
FlightRecorder.enabled = false

local pendingCaptures = {}        -- captures waiting for their post-window

--------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------

function FlightRecorder:Record()
    if not self.enabled then return end
    local ring = self.ring
    if not ring then return end

    local slot = ring:Acquire()
    local ft = WTM.FrameTime.current

    slot.t          = GetTime()
    slot.fps        = ft.fps
    slot.frameAvgMs = ft.avgMs
    slot.frameMaxMs = ft.maxMs
    slot.frameMinMs = ft.minMs
    slot.luaKB      = WTM.Memory.current.luaKB
    slot.events     = WTM.Events.current.perSecond
    slot.flags      = WTM.Context:Flags()

    local net = WTM.Network.current
    slot.latHome  = net.latencyHome
    slot.latWorld = net.latencyWorld

    if WTM.CPU.available then
        slot.cpuPct = WTM.CPU.current.totalPct
        slot.cpuMs  = WTM.CPU.current.totalPct * 0.01 * (slot.frameAvgMs or 0)
    end

    self:ProcessPendingCaptures()
end

--------------------------------------------------------------------------
-- Capture
--------------------------------------------------------------------------

--- Marks a point in time for capture.  The actual copy happens once the
--- post-window has elapsed, which is what makes the incident useful.
function FlightRecorder:RequestCapture(spike)
    if not self.enabled then return nil end
    if not WTM.db.profile.flightRecorder.enabled then return nil end

    local settings = WTM.db.profile.flightRecorder
    local capture = {
        spike     = spike,
        markSeq   = self.ring.seq,
        markTime  = GetTime(),
        readyAt   = GetTime() + settings.postWindow,
        preWindow = settings.preWindow,
        postWindow = settings.postWindow,
    }
    pendingCaptures[#pendingCaptures + 1] = capture
    return capture
end

function FlightRecorder:ProcessPendingCaptures()
    if #pendingCaptures == 0 then return end
    local now = GetTime()
    for i = #pendingCaptures, 1, -1 do
        local capture = pendingCaptures[i]
        if now >= capture.readyAt then
            table.remove(pendingCaptures, i)
            self:Materialize(capture)
        end
    end
end

--- Copies the window around a mark out of the ring into a standalone incident.
function FlightRecorder:Materialize(capture)
    local ring = self.ring
    local fromTime = capture.markTime - capture.preWindow
    local toTime   = capture.markTime + capture.postWindow

    local samples = {}
    local n = ring.count
    for i = 1, n do
        local slot = ring:Get(i)
        if slot and slot.t >= fromTime and slot.t <= toTime then
            samples[#samples + 1] = {
                t          = slot.t - capture.markTime,   -- relative to the spike
                fps        = slot.fps,
                frameAvgMs = slot.frameAvgMs,
                frameMaxMs = slot.frameMaxMs,
                latWorld   = slot.latWorld,
                luaKB      = slot.luaKB,
                events     = slot.events,
                cpuPct     = slot.cpuPct,
                flags      = slot.flags,
            }
        end
    end

    if #samples == 0 then return nil end

    local incident = {
        id        = (self.nextId or 1),
        at        = capture.markTime,
        epoch     = time(),
        spike     = capture.spike,
        preWindow = capture.preWindow,
        postWindow = capture.postWindow,
        samples   = samples,
        context   = WTM.Context:Capture(),
        markers   = WTM.Context:GetMarkersInRange(fromTime, toTime),
        clientLabel = Compat:GetClientLabel(),
    }
    self.nextId = incident.id + 1

    local incidents = self.incidents
    if #incidents >= C.FR_MAX_INCIDENTS_MEM then table.remove(incidents, 1) end
    incidents[#incidents + 1] = incident

    if capture.spike then capture.spike.incidentId = incident.id end

    if WTM.db.profile.flightRecorder.persist and WTM.db.profile.retention.saveIncidents then
        self:Persist(incident)
    end

    WTM:SendMessage("WTM_INCIDENT_CAPTURED", incident)
    return incident
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------
-- The in-memory incident is at the frame-time sample rate (4 Hz by default).
-- Saving that verbatim for twenty incidents would be a few hundred kilobytes
-- of SavedVariables for data nobody reads at that resolution, so it is
-- downsampled to 1 Hz on the way out, keeping the max of each bucket - the
-- peaks are the whole point.

function FlightRecorder:Persist(incident)
    local step = 1 / C.FR_PERSIST_HZ
    local packed = {}
    local bucketStart, acc, count = nil, nil, 0

    local function flush()
        if acc and count > 0 then
            packed[#packed + 1] = {
                acc.t, acc.fps, acc.frameAvgMs, acc.frameMaxMs,
                acc.latWorld, acc.luaKB, acc.events, acc.cpuPct,
            }
        end
    end

    for i = 1, #incident.samples do
        local s = incident.samples[i]
        if not bucketStart or (s.t - bucketStart) >= step then
            flush()
            bucketStart = s.t
            acc = { t = s.t, fps = s.fps, frameAvgMs = s.frameAvgMs, frameMaxMs = s.frameMaxMs,
                    latWorld = s.latWorld, luaKB = s.luaKB, events = s.events, cpuPct = s.cpuPct }
            count = 1
        else
            -- Keep the worst frame and the highest event rate in each bucket.
            if s.frameMaxMs > acc.frameMaxMs then acc.frameMaxMs = s.frameMaxMs end
            if s.fps < acc.fps then acc.fps = s.fps end
            if s.events > acc.events then acc.events = s.events end
            if (s.cpuPct or 0) > (acc.cpuPct or 0) then acc.cpuPct = s.cpuPct end
            acc.luaKB = s.luaKB
            count = count + 1
        end
    end
    flush()

    local stored = {
        id      = incident.id,
        epoch   = incident.epoch,
        spike   = incident.spike and {
            kind    = incident.spike.kind,
            frameMs = incident.spike.frameMs,
            fps     = incident.spike.fps,
            cpu     = incident.spike.cpu,
            events  = incident.spike.events,
            memory  = incident.spike.memory,
        } or nil,
        context = incident.context,
        client  = incident.clientLabel,
        -- Array-of-arrays: roughly 60% smaller in SavedVariables than the
        -- equivalent array of keyed tables.
        fields  = { "t", "fps", "frameAvgMs", "frameMaxMs", "latWorld", "luaKB", "events", "cpuPct" },
        samples = packed,
    }

    local saved = WTM.db.global.incidents
    saved[#saved + 1] = stored
    local maxIncidents = WTM.db.profile.retention.maxIncidents
    while #saved > maxIncidents do table.remove(saved, 1) end
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

function FlightRecorder:GetIncident(id)
    for i = #self.incidents, 1, -1 do
        if self.incidents[i].id == id then return self.incidents[i] end
    end
    return nil
end

function FlightRecorder:GetRecent(out, limit)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local incidents = self.incidents
    local first = math.max(1, #incidents - (limit or 10) + 1)
    for i = #incidents, first, -1 do out[#out + 1] = incidents[i] end
    return out
end

--- Reads the live ring into a plain array for graphing, oldest first.
function FlightRecorder:ReadRange(fromTime, toTime, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local ring = self.ring
    if not ring then return out end
    for i = 1, ring.count do
        local slot = ring:Get(i)
        if slot and slot.t >= fromTime and slot.t <= toTime then
            out[#out + 1] = slot
        end
    end
    return out
end

function FlightRecorder:GetCoverageSeconds()
    local ring = self.ring
    if not ring or ring.count < 2 then return 0 end
    local first = ring:Get(1)
    local last  = ring:Get(ring.count)
    return (last.t or 0) - (first.t or 0)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function FlightRecorder:OnInitialize()
    self.nextId = 1
end

function FlightRecorder:OnEnable()
    local settings = WTM.db.profile.flightRecorder
    local rate = WTM.db.profile.sampling.intervals.frametime
    if rate <= 0 then rate = C.SAMPLE_DEFAULTS.frametime.normal end

    local seconds = settings.preWindow + settings.postWindow + C.FR_RESERVE_SEC
    -- 25% headroom so a modest interval change does not immediately shrink the
    -- window below what the settings promise.
    local slots = math.ceil(seconds / rate * 1.25)
    self.ring = SlotRing.New(slots, SLOT_FIELDS)
    self.slotCount = slots
    self.targetSeconds = seconds
    self.enabled = settings.enabled

    -- Deliberately NOT bursting.  The ring is sized in slots, so raising its
    -- rate during a spike would shorten the window it covers - exactly when
    -- the run-up matters most.  A 60-second ring that collapses to 12 seconds
    -- under load is worse than useless, so the recorder keeps one steady rate
    -- and the burst goes to the CPU and event samplers instead, which is where
    -- the extra detail actually lives.
    WTM.Scheduler:Register("flightrecorder", function() FlightRecorder:Record() end,
        rate, rate, 0.5)

    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function FlightRecorder:Rebuild()
    local wasEnabled = self.enabled
    self.enabled = false
    self:OnEnable()
    self.enabled = wasEnabled
end

function FlightRecorder:Reset()
    if self.ring then self.ring:Reset() end
    for i = #self.incidents, 1, -1 do self.incidents[i] = nil end
    for i = #pendingCaptures, 1, -1 do pendingCaptures[i] = nil end
end
