--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Processes.lua

    The addon inventory - the "process list".  One record per installed addon,
    created once and then updated in place by CPU.lua, Memory.lua and
    Events.lua.  Nothing here allocates during sampling.

    Also home to the frame-ownership heuristic.  There is no API that maps a
    frame to the addon that created it, so the only honest approach is a name
    prefix match against the list of loaded addons, with the unmatched
    remainder reported openly rather than swept under the rug.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local api    = Compat.api
local Ring   = WTM.RingBuffer
local Fmt    = WTM.Format

local Processes = WTM:NewModule("Processes")
WTM.Processes = Processes

Processes.list   = {}   -- array, stable order = addon index
Processes.byName = {}   -- lowercase name -> record
Processes.count  = 0

local HISTORY_POINTS = 240   -- per-addon detail graphs

--------------------------------------------------------------------------
-- Record construction
--------------------------------------------------------------------------

local function NewRecord(index, name)
    return {
        index = index,
        name  = name,
        key   = name:lower(),

        title       = name,
        titleClean  = name,
        version     = nil,
        author      = nil,
        notes       = nil,
        loaded      = false,
        lod         = false,
        enableState = nil,
        security    = nil,
        reason      = nil,

        -- CPU (only meaningful with scriptProfile)
        cpuTotalMs = 0, cpuDeltaMs = 0, cpuPct = 0,
        cpuPeakPct = 0, cpuSumPct = 0, cpuSamples = 0, cpuEma = 0,
        -- how many CPU samples this addon spent above its own average
        elevatedSamples = 0,

        -- Memory
        memKB = 0, memDeltaKB = 0, memStartKB = nil,
        memPeakKB = 0, memGrowthKBPerMin = 0,

        -- Attribution (heuristic)
        frameCount = 0, registeredEvents = 0, handlerCalls = 0,
        attributionConfident = false,

        -- Spikes
        spikes = 0, lastSpikeAt = nil,

        -- Derived
        score = 100,
        status = C.STATUS.NORMAL,

        -- Detail graphs, allocated lazily the first time a detail view opens
        cpuRing = nil, memRing = nil,
    }
end

local function EnsureRings(record)
    if not record.cpuRing then
        record.cpuRing = Ring.New(HISTORY_POINTS)
        record.memRing = Ring.New(HISTORY_POINTS)
    end
    return record
end
Processes.EnsureRings = EnsureRings

--------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------

--- Full rebuild.  Runs at login and whenever an addon is loaded on demand -
--- never on a sampling interval, because GetAddOnInfo over 150 addons is not
--- something you want on a timer.
function Processes:Rebuild()
    local total = Compat.GetNumAddOns()
    self.count = total

    for i = 1, total do
        local name, title, notes, loadable, reason, security = Compat.GetAddOnInfo(i)
        if name then
            local record = self.byName[name:lower()]
            if not record then
                record = NewRecord(i, name)
                self.list[#self.list + 1] = record
                self.byName[record.key] = record
            end
            record.index      = i
            record.title      = title or name
            record.titleClean = Fmt.StripColors(title or name)
            record.notes      = notes
            record.reason     = reason
            record.security   = security
            record.loadable   = loadable and true or false
            record.loaded     = Compat.IsAddOnLoaded(i)
            record.lod        = Compat.IsAddOnLoadOnDemand(i)
            record.version    = Compat.GetAddOnMetadata(i, "Version")
            record.author     = Compat.GetAddOnMetadata(i, "Author")
            record.enableState = Compat.GetAddOnEnableState(i, UnitName("player"))
        end
    end

    self:RefreshDependencies()
    WTM:SendMessage("WTM_PROCESSES_REBUILT")
    return self.list
end

--- Dependencies are only needed when the detail view or the Diagnostics page
--- asks, so they are refreshed separately and cached.
function Processes:RefreshDependencies()
    for i = 1, #self.list do
        local record = self.list[i]
        record.deps    = Compat.GetAddOnDependencies(record.index, false, record.deps)
        record.optDeps = Compat.GetAddOnDependencies(record.index, true, record.optDeps)
    end
end

--- Which loaded addons declare `name` as a dependency.  Answers "what breaks
--- if I disable this".
function Processes:GetDependents(name, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local lower = name:lower()
    for i = 1, #self.list do
        local record = self.list[i]
        local deps = record.deps
        if deps then
            for j = 1, #deps do
                if deps[j]:lower() == lower then
                    out[#out + 1] = record.name
                    break
                end
            end
        end
    end
    return out
end

function Processes:Get(name)
    return self.byName[tostring(name):lower()]
end

function Processes:Iterate() return ipairs(self.list) end

function Processes:CountLoaded()
    local n = 0
    for i = 1, #self.list do
        if self.list[i].loaded then n = n + 1 end
    end
    return n
end

--- True when the addon is a library-only package (no CPU/memory of its own
--- worth listing separately).  Purely cosmetic grouping, never used to hide
--- a real cost.
function Processes:IsLibrary(record)
    local name = record.name
    return name:find("^Lib") ~= nil or name == "Ace3" or (record.titleClean or ""):find("^Lib") ~= nil
end

--------------------------------------------------------------------------
-- Frame ownership heuristic
--------------------------------------------------------------------------
-- EnumerateFrames() walks every frame in the UI.  Frames have names, addons
-- have names, and most addons prefix their frames.  That is the entire basis
-- of this mapping - which is why every number it produces is labelled
-- "heuristic" in the UI and never presented as a measurement.

Processes.attribution = {
    lastScanAt   = 0,
    totalFrames  = 0,
    namedFrames  = 0,
    matchedFrames = 0,
    skippedNonFrames = 0,
    scanCostMs   = 0,
}

local prefixIndex = {}   -- lowercased addon name -> record

-- event -> { addonName -> frameCount }, filled by ScanFrames.  This is the
-- data behind the "which addons react to this event" column, and it is
-- labelled heuristic everywhere it is shown.
local eventListeners = {}
Processes.eventListeners = eventListeners

local EVENT_PROBE_LIMIT = 40

local function BuildPrefixIndex()
    for k in pairs(prefixIndex) do prefixIndex[k] = nil end
    for i = 1, #Processes.list do
        local record = Processes.list[i]
        if record.loaded then
            prefixIndex[record.key] = record
        end
    end
end

local function MatchFrameToAddon(frameName)
    -- Defensive: callers must pass a string, but this is reached from a walk
    -- over whatever EnumerateFrames hands back, and that is not always what the
    -- documentation implies. Failing soft here beats erroring mid-scan.
    if type(frameName) ~= "string" then return nil end
    local lower = frameName:lower()
    -- Longest prefix wins, so "WeakAurasOptions" is not attributed to a
    -- hypothetical "Weak" addon.
    local best, bestLen
    for key, record in pairs(prefixIndex) do
        local len = #key
        if len >= 3 and (not bestLen or len > bestLen) and lower:sub(1, len) == key then
            best, bestLen = record, len
        end
    end
    return best
end

--- Expensive: walks every frame in the UI.  Only ever called on demand (when
--- the Processes or Events page asks for attribution) and rate limited.
function Processes:ScanFrames(force)
    if not api.EnumerateFrames then return false, C.TXT_UNAVAILABLE_CLIENT end
    local now = GetTime()
    if not force and (now - self.attribution.lastScanAt) < 10 then return true end

    local t0 = Compat.Now()
    BuildPrefixIndex()

    for i = 1, #self.list do
        local record = self.list[i]
        record.frameCount = 0
        record.registeredEvents = 0
        record.handlerCalls = 0
        record.attributionConfident = false
    end

    local total, named, matched = 0, 0, 0
    local getFrameCPU = WTM.Caps:Has("frameCPU") and api.GetFrameCPUUsage or nil

    -- Which events to test each frame against.  Testing every event a frame
    -- could listen for is not possible (there is no "list my events" API), so
    -- we test the busiest events we have actually seen fire.
    local probeEvents = WTM.Events and WTM.Events:GetTopEventNames(EVENT_PROBE_LIMIT) or nil
    if probeEvents and #probeEvents == 0 then probeEvents = nil end
    for k in pairs(eventListeners) do eventListeners[k] = nil end

    local frame = api.EnumerateFrames()
    local skippedNonFrames = 0
    while frame do
        total = total + 1

        -- EnumerateFrames does not only yield Frames.
        --
        -- On a live Retail client it also returns regions - FontStrings,
        -- Textures - and their GetName does not reliably return a string. An
        -- earlier version assumed both, and blew up mid-scan on a FontString
        -- from another addon's XML.
        --
        -- Two guards, in order of cheapness: skip anything that cannot register
        -- events (which is the only property this scan actually needs), then
        -- require the name to really be a string.
        local isFrame = type(rawget(frame, "IsEventRegistered")) == "function"
            or type(frame.IsEventRegistered) == "function"

        local frameName
        if isFrame then
            local ok, name = pcall(frame.GetName, frame)
            if ok and type(name) == "string" then frameName = name end
        else
            skippedNonFrames = skippedNonFrames + 1
        end

        if frameName and frameName ~= "" then
            named = named + 1
            local record = MatchFrameToAddon(frameName)
            if record then
                matched = matched + 1
                record.frameCount = record.frameCount + 1

                -- How many of the events we have actually observed this frame
                -- listens for.  frame:IsEventRegistered is a real, exact API;
                -- only the frame -> addon mapping above is heuristic.  The
                -- probe list is capped so this stays O(frames * 40).
                if probeEvents then
                    local isRegistered = frame.IsEventRegistered
                    for e = 1, #probeEvents do
                        local ok2, registered = pcall(isRegistered, frame, probeEvents[e])
                        if ok2 and registered then
                            record.registeredEvents = record.registeredEvents + 1
                            local listeners = eventListeners[probeEvents[e]]
                            if not listeners then
                                listeners = {}
                                eventListeners[probeEvents[e]] = listeners
                            end
                            listeners[record.name] = (listeners[record.name] or 0) + 1
                        end
                    end
                end

                if getFrameCPU then
                    local ok3, _, calls = pcall(getFrameCPU, frame, false)
                    if ok3 and calls then record.handlerCalls = record.handlerCalls + calls end
                end
            end
        end
        local okNext, nextFrame = pcall(api.EnumerateFrames, frame)
        frame = okNext and nextFrame or nil
    end

    local a = self.attribution
    a.lastScanAt    = now
    a.totalFrames   = total
    a.namedFrames   = named
    a.matchedFrames = matched
    a.skippedNonFrames = skippedNonFrames
    a.scanCostMs    = Compat.Now() - t0

    for i = 1, #self.list do
        local record = self.list[i]
        record.attributionConfident = record.frameCount > 0
    end

    return true
end

--- Addons whose frames listen for `event`, best-effort.  Returns the list and
--- whether a scan has ever run.
function Processes:GetEventListeners(event, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local listeners = eventListeners[event]
    if not listeners then return out, self.attribution.lastScanAt > 0 end
    for name, count in pairs(listeners) do
        out[#out + 1] = { name = name, frames = count }
    end
    table.sort(out, function(a, b) return a.frames > b.frames end)
    return out, true
end

function Processes:AttributionSummary()
    local a = self.attribution
    if a.totalFrames == 0 then return "No frame scan has run yet." end
    local anonymous = a.totalFrames - a.namedFrames - (a.skippedNonFrames or 0)
    return ("%d objects walked: %d were not frames, %d named frames, %d matched to an addon, %d anonymous (not attributable). Scan cost %.1f ms.")
        :format(a.totalFrames, a.skippedNonFrames or 0, a.namedFrames,
                a.matchedFrames, anonymous, a.scanCostMs)
end

--------------------------------------------------------------------------
-- Status and score
--------------------------------------------------------------------------
-- The score is a presentation aid, not a measurement.  It compresses CPU,
-- memory growth and spike involvement into one sortable number so the list can
-- lead with what is worth looking at.

function Processes:UpdateDerived(record, sessionMinutes)
    if not record.loaded then
        record.status = (record.enableState == 0) and C.STATUS.DISABLED or C.STATUS.NOT_LOADED
        record.score = 100
        return
    end

    local penalty = 0
    local profile = WTM.db.profile

    local cpuPct = record.cpuEma or 0
    if cpuPct >= C.HIGH_CPU_PCT then
        penalty = penalty + 40 + math.min(30, (cpuPct - C.HIGH_CPU_PCT) * 2)
    elseif cpuPct >= C.ELEVATED_CPU_PCT then
        penalty = penalty + 15
    end

    local growth = record.memGrowthKBPerMin or 0
    local growthLimit = profile.memory.growthThresholdKBPerMin
    if growth >= growthLimit then
        penalty = penalty + math.min(30, 10 + (growth / growthLimit) * 5)
    end

    if record.spikes > 0 then
        penalty = penalty + math.min(20, record.spikes * 3)
    end

    record.score = math.max(0, math.min(100, 100 - penalty))

    if cpuPct >= C.HIGH_CPU_PCT then
        record.status = C.STATUS.HIGH_CPU
    -- Never label ourselves a spike source: our CPU rises because a spike was
    -- detected, not before it. See Monitoring/CPU:GetWindowDeltas.
    elseif record.spikes >= 3 and record.name ~= WTM.name then
        record.status = C.STATUS.SPIKY
    elseif growth >= growthLimit then
        record.status = C.STATUS.MEM_GROWTH
    elseif cpuPct >= C.ELEVATED_CPU_PCT then
        record.status = C.STATUS.ELEVATED
    elseif cpuPct < 0.05 and (record.memDeltaKB or 0) == 0 then
        record.status = C.STATUS.IDLE
    else
        record.status = C.STATUS.NORMAL
    end
end

--------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------

-- Every comparator is STABLE: equal values fall back to the addon name.
--
-- Without that, table.sort's ordering of ties is unspecified, so two addons
-- sitting at 0.00% CPU swap places on every refresh and the list visibly
-- churns while you are trying to read it. The page additionally throttles how
-- often it re-sorts and freezes entirely while the mouse is over it.
local function byName(a, b)
    return a.titleClean:lower() < b.titleClean:lower()
end

local function descending(get)
    return function(a, b)
        local av, bv = get(a) or 0, get(b) or 0
        if av ~= bv then return av > bv end
        return byName(a, b)
    end
end

-- Sorting uses the SMOOTHED cpu value, not the raw last-sample value: an addon
-- that happens to be idle in one 2-second window should not fall twenty rows
-- and climb back on the next sample.
-- Shared empty table so BuildView never allocates one per call.
local EMPTY_FILTERS = {}

local SORTERS = {
    name     = byName,
    cpu      = descending(function(r) return r.cpuEma end),
    cpudelta = descending(function(r) return r.cpuDeltaMs end),
    cpuavg   = descending(function(r) return r.cpuSamples > 0 and (r.cpuSumPct / r.cpuSamples) or 0 end),
    cpupeak  = descending(function(r) return r.cpuPeakPct end),
    memory   = descending(function(r) return r.memKB end),
    memdelta = descending(function(r)
        return r.memStartKB and (r.memKB - r.memStartKB) or 0
    end),
    events   = descending(function(r) return r.registeredEvents end),
    spikes   = descending(function(r) return r.spikes end),
    cpusession = descending(function(r) return r.cpuTotalMs end),
    mempct   = descending(function(r) return r.memKB end),
    frames   = descending(function(r) return r.frameCount end),
    -- Sorted by the association strength the correlation module computed for
    -- this session; addons with no association sort last rather than as zero.
    phi      = descending(function(r) return r.sessionPhi or -1 end),
    lod      = function(a, b)
        local function rank(r)
            if r.loaded then return 1 end
            if r.lod then return 2 end
            if r.enableState == 0 then return 4 end
            return 3
        end
        local ar, br = rank(a), rank(b)
        if ar ~= br then return ar < br end
        return byName(a, b)
    end,
    deps     = descending(function(r) return r.deps and #r.deps or 0 end),
    score    = function(a, b)
        local av, bv = a.score or 100, b.score or 100
        if av ~= bv then return av < bv end
        return byName(a, b)
    end,
    status   = function(a, b)
        local ak = a.status and a.status.key or ""
        local bk = b.status and b.status.key or ""
        if ak ~= bk then return ak < bk end
        return byName(a, b)
    end,
}
Processes.SORT_KEYS = { "name", "status", "cpu", "cpuavg", "cpupeak",
                        "memory", "memdelta", "events", "spikes", "score" }

--- Fills `out` with records matching `filter`, sorted.  The caller owns `out`
--- and reuses it between refreshes, so the process page allocates nothing per
--- redraw.
--- Builds the visible list.
---
--- `filters` is optional and additive: every field present has to pass. It
--- exists so the page can offer "only what is worth looking at" without the
--- page needing to know how a record is shaped.
---     minCPU     percent
---     minMemory  kilobytes
---     enabledOnly / loadedOnly / suspectedOnly / watchedOnly
function Processes:BuildView(out, sortKey, ascending, filter, includeUnloaded, filters)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end

    local needle = filter and filter ~= "" and filter:lower() or nil
    filters = filters or EMPTY_FILTERS

    for i = 1, #self.list do
        local record = self.list[i]
        local include = includeUnloaded or record.loaded
        if include and needle then
            include = record.key:find(needle, 1, true) ~= nil
                or record.titleClean:lower():find(needle, 1, true) ~= nil
        end
        if include and filters.loadedOnly then include = record.loaded end
        if include and filters.enabledOnly then include = record.enableState ~= 0 end
        if include and filters.watchedOnly then
            include = WTM.Database:IsWatched(record.name)
        end
        if include and filters.suspectedOnly then
            -- "Suspected" is deliberately a union of measured signals, not a
            -- judgement: elevated CPU, sustained growth, or an association
            -- with recorded spikes. Any one of them is a reason to look.
            include = (record.cpuEma or 0) >= C.ELEVATED_CPU_PCT
                or (record.memGrowthKBPerMin or 0) >= C.MEM_GROWTH_KB_PER_MIN
                or (record.spikes or 0) >= 3
        end
        if include and filters.minCPU then
            include = (record.cpuEma or 0) >= filters.minCPU
        end
        if include and filters.minMemory then
            include = (record.memKB or 0) >= filters.minMemory
        end
        if include then out[#out + 1] = record end
    end

    local sorter = SORTERS[sortKey or "cpu"] or SORTERS.cpu
    if ascending then
        table.sort(out, function(a, b) return sorter(b, a) end)
    else
        table.sort(out, sorter)
    end
    return out
end

--------------------------------------------------------------------------
-- Addon control (never bypasses anything the client protects)
--------------------------------------------------------------------------

--- Queues an enable/disable for the next reload.  There is deliberately no
--- "unload now": the API does not offer it and faking a stop button would be
--- worse than not having one.
function Processes:SetEnabled(name, enabled)
    if not WTM.Caps:Has("addonEnableDisable") then
        return false, C.TXT_UNAVAILABLE_CLIENT
    end
    local fn = enabled and api.EnableAddOn or api.DisableAddOn
    local character = UnitName("player")
    local ran = Compat.RunWhenSafe("SetAddonEnabled", function()
        -- Both argument shapes exist in the wild; the name-only form is
        -- accepted by every current client.
        if not pcall(fn, name, character) then pcall(fn, name) end
        local record = Processes:Get(name)
        if record then
            record.enableState = Compat.GetAddOnEnableState(record.index, character)
            record.pendingChange = enabled and "enable" or "disable"
        end
        WTM:SendMessage("WTM_ADDON_STATE_CHANGED", name, enabled)
    end)
    if not ran then return true, C.TXT_COMBAT_QUEUED end
    return true
end

function Processes:LoadNow(name)
    if not api.LoadAddOn then return false, C.TXT_UNAVAILABLE_CLIENT end
    local record = self:Get(name)
    if record and not record.lod then
        return false, "Not a LoadOnDemand addon"
    end
    local loaded, reason = Compat.SafeCall("LoadAddOn", api.LoadAddOn, name)
    if not loaded then return false, reason or "refused" end
    self:Rebuild()
    return true
end

function Processes:ReloadUI()
    Compat.RunWhenSafe("ReloadUI", function() ReloadUI() end)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Processes:OnInitialize()
    self:Rebuild()
end

function Processes:OnEnable()
    self:RegisterEvent("ADDON_LOADED", "OnAddonLoaded")
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
    self:Rebuild()
end

function Processes:OnAddonLoaded(_, name)
    local record = self:Get(name)
    if record then
        record.loaded = true
        record.version = record.version or Compat.GetAddOnMetadata(record.index, "Version")
    else
        self:Rebuild()
    end
end

function Processes:Reset()
    for i = 1, #self.list do
        local record = self.list[i]
        record.cpuTotalMs, record.cpuDeltaMs, record.cpuPct = 0, 0, 0
        record.cpuPeakPct, record.cpuSumPct, record.cpuSamples, record.cpuEma = 0, 0, 0, 0
        record.elevatedSamples = 0
        record.memDeltaKB, record.memPeakKB, record.memGrowthKBPerMin = 0, 0, 0
        record.memStartKB = nil
        record.spikes, record.lastSpikeAt = 0, nil
        if record.cpuRing then record.cpuRing:Reset() end
        if record.memRing then record.memRing:Reset() end
    end
end
