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

    Edge cases this has to survive, all of which are covered by tests:

      * several spikes in quick succession, each requesting its own capture
      * overlapping captures whose windows share samples
      * the ring wrapping mid-capture, so the requested pre-roll no longer
        exists - the incident is marked TRUNCATED rather than silently short
      * a loading screen or zone change during the post-roll
      * logout or /reload while a post-roll is still pending, which flushes
        what exists instead of losing the incident entirely
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
    if not self.ring then return nil end

    local settings = WTM.db.profile.flightRecorder
    local now = GetTime()

    -- Several spikes inside one post-roll should not each produce their own
    -- near-identical incident. If a capture is already pending and this spike
    -- falls inside its window, extend that capture instead and note the extra
    -- spike on it.
    for i = 1, #pendingCaptures do
        local existing = pendingCaptures[i]
        if now <= existing.readyAt then
            existing.extraSpikes = (existing.extraSpikes or 0) + 1
            if spike and (not existing.spike or spike.frameMs > existing.spike.frameMs) then
                -- Keep the WORST spike as the incident's subject.
                existing.spike = spike
                existing.markTime = spike.t
            end
            -- Push the end out so the incident covers the whole burst - but
            -- only up to a hard ceiling.
            --
            -- Without the ceiling a sustained stutter storm keeps extending the
            -- same pending capture on every spike and it NEVER materialises:
            -- the one situation where you most want an incident produces none
            -- at all. The ceiling guarantees every capture completes, and the
            -- spikes that arrive after it simply open the next one.
            existing.readyAt = math.min(existing.maxReadyAt,
                math.max(existing.readyAt, now + settings.postWindow))
            return existing
        end
    end

    local capture = {
        spike      = spike,
        markSeq    = self.ring.seq,
        markTime   = spike and spike.t or now,
        readyAt    = now + settings.postWindow,
        -- Hard ceiling on how far a burst of spikes may push the post-roll out.
        maxReadyAt = now + settings.postWindow + C.CLUSTER_MAX_SPAN_SEC,
        preWindow  = settings.preWindow,
        postWindow = settings.postWindow,
        requestedAt = now,
    }
    pendingCaptures[#pendingCaptures + 1] = capture
    return capture
end

function FlightRecorder:PendingCount() return #pendingCaptures end

function FlightRecorder:ProcessPendingCaptures()
    if #pendingCaptures == 0 then return end
    local now = GetTime()
    for i = #pendingCaptures, 1, -1 do
        local capture = pendingCaptures[i]
        if now >= capture.readyAt then
            table.remove(pendingCaptures, i)
            self:Materialize(capture, "postroll")
        end
    end
end

--- Copies the window around a mark out of the ring into a standalone incident.
---
--- `reason` is "postroll" for the normal path and "flush" when the session is
--- ending while the post-roll is still running; a flushed incident is marked so
--- nobody reads its short tail as the stutter having ended early.
function FlightRecorder:Materialize(capture, reason)
    local ring = self.ring
    if not ring then return nil end

    local fromTime = capture.markTime - capture.preWindow
    local toTime   = capture.markTime + capture.postWindow

    -- The ring may have wrapped past the requested pre-roll while we waited
    -- (a long post window, or a burst of samples). Record what we actually
    -- have rather than implying the missing seconds were quiet.
    local oldest = ring.count > 0 and ring:Get(1) or nil
    local truncatedPre = false
    if oldest and oldest.t and oldest.t > fromTime then
        truncatedPre = true
        fromTime = oldest.t
    end

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

    -- Sample timestamps are stored relative to the spike, so the first and last
    -- of them are exactly the pre- and post-roll actually captured.
    local firstRel   = samples[1].t
    local lastRel    = samples[#samples].t

    local incident = {
        id        = (self.nextId or 1),
        at        = capture.markTime,
        epoch     = time(),
        spike     = capture.spike,
        preWindow = capture.preWindow,
        postWindow = capture.postWindow,
        -- What was actually captured, which is not always what was requested.
        actualPreSec  = -firstRel,
        actualPostSec = lastRel,
        truncatedPre  = truncatedPre or nil,
        truncatedPost = (reason ~= "postroll") or nil,
        flushReason   = (reason ~= "postroll") and reason or nil,
        spikeCount    = 1 + (capture.extraSpikes or 0),
        samples   = samples,
        context   = WTM.Context:Capture(),
        markers   = WTM.Context:GetMarkersInRange(fromTime, toTime),
        clientLabel = Compat:GetClientLabel(),
        simulated = capture.spike and capture.spike.simulated or nil,
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
    -- Injected data stays in memory for the session that injected it, where it
    -- is labelled SIMULATED, and never reaches the database. A developer spike
    -- from a debugging session last week has no business turning up in a
    -- Compare against a real raid night.
    if incident.simulated then return end

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
        truncatedPre  = incident.truncatedPre,
        truncatedPost = incident.truncatedPost,
        actualPreSec  = incident.actualPreSec,
        actualPostSec = incident.actualPostSec,
        spikeCount    = incident.spikeCount,
        simulated     = incident.simulated,
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
        rate, rate, 0.5, "sampler")

    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

--- Materialises every pending capture immediately.  Called at logout and
--- before a reload: a capture whose post-roll never finished is still the most
--- interesting 30 seconds of the session, and losing it because the player
--- typed /reload would be the worst possible time to lose it.
function FlightRecorder:FlushPending(reason)
    local flushed = 0
    for i = #pendingCaptures, 1, -1 do
        local capture = pendingCaptures[i]
        table.remove(pendingCaptures, i)
        if self:Materialize(capture, reason or "flush") then
            flushed = flushed + 1
        end
    end
    return flushed
end

function FlightRecorder:OnDisable()
    self:FlushPending("sessionEnd")
end

function FlightRecorder:Rebuild()
    local wasEnabled = self.enabled
    self.enabled = false
    self:OnEnable()
    self.enabled = wasEnabled
end

--- Human-readable coverage note for one incident, so a truncated capture is
--- never mistaken for a quiet run-up.
function FlightRecorder:DescribeCoverage(incident)
    if not incident then return "" end
    local parts = {}
    parts[#parts + 1] = ("%d samples covering -%.0fs to +%.0fs around the spike")
        :format(#incident.samples, incident.actualPreSec or 0, incident.actualPostSec or 0)
    if incident.truncatedPre then
        parts[#parts + 1] = ("run-up truncated: the ring only held %.0fs of history at capture time, not the %ds requested")
            :format(incident.actualPreSec or 0, incident.preWindow or 0)
    end
    if incident.truncatedPost then
        parts[#parts + 1] = "post-roll cut short because the session ended"
    end
    if (incident.spikeCount or 1) > 1 then
        parts[#parts + 1] = ("%d spikes fell inside this window"):format(incident.spikeCount)
    end
    return table.concat(parts, ". ") .. "."
end

function FlightRecorder:Reset()
    if self.ring then self.ring:Reset() end
    for i = #self.incidents, 1, -1 do self.incidents[i] = nil end
    for i = #pendingCaptures, 1, -1 do pendingCaptures[i] = nil end
end
