--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Memory.lua

    Two very different measurements live here:

      collectgarbage("count")   - total Lua heap, essentially free to read, so
                                  it is sampled often and drives the GC curve.
      UpdateAddOnMemoryUsage()  - per-addon breakdown.  This walks the whole
                                  Lua state and is genuinely expensive, so it
                                  runs on a slow interval and its cost is
                                  measured and shown to the user.

    Garbage collection: WoW exposes no GC statistics at all. What this module
    watches is the heap curve, and a sustained fall in it is an OBSERVED HEAP
    DECREASE - which is consistent with collection activity but is not a
    measurement of it. Something else can shrink the heap, and a collection
    that frees little may not show at all. The wording throughout says
    "observed decrease" and "possible collection activity" for that reason.

    The addon never calls collectgarbage("collect") itself; forcing a collect is
    exactly the kind of hitch this tool exists to find.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local api    = Compat.api
local Ring   = WTM.RingBuffer
local MathU  = WTM.Math

local Memory = WTM:NewModule("Memory")
WTM.Memory = Memory

Memory.current = {
    luaKB        = 0,
    luaStartKB   = 0,
    luaPeakKB    = 0,
    addonSumKB   = 0,
    -- The first and largest attributed totals seen this session, so a summary
    -- can say how far it has moved without keeping a second ring for it.
    addonStartKB = nil,
    addonPeakKB  = 0,
    growthKBPerMin = 0,
    lastAddonScanAt = 0,
    addonScanCostMs = 0,
}

-- Observed heap decreases. Named `heapDrops` rather than `gc` so no caller can
-- read it as a confirmed collection count.
Memory.heapDrops = {
    events      = 0,
    lastAt      = nil,
    lastFreedKB = 0,
    totalFreedKB = 0,
    intervalSum = 0,
}

Memory.history = { lua = nil, times = nil }

local GC_DROP_MIN_KB = 256   -- ignore noise; a real collection frees more than this

--------------------------------------------------------------------------
-- Lua heap (cheap, frequent)
--------------------------------------------------------------------------

local previousLuaKB = nil

function Memory:SampleLua()
    local ok, kb = pcall(collectgarbage, "count")
    if not ok or type(kb) ~= "number" then return end

    local cur = self.current
    cur.luaKB = kb
    if cur.luaStartKB == 0 then cur.luaStartKB = kb end
    if kb > cur.luaPeakKB then cur.luaPeakKB = kb end

    -- A fall in the heap is an OBSERVED DECREASE, not a confirmed collection.
    -- No API reports collections; this is the curve, and it is labelled as an
    -- observation everywhere it is shown.
    if previousLuaKB and (previousLuaKB - kb) >= GC_DROP_MIN_KB then
        local drops = self.heapDrops
        local freed = previousLuaKB - kb
        local now = GetTime()
        drops.events = drops.events + 1
        drops.lastFreedKB = freed
        drops.totalFreedKB = drops.totalFreedKB + freed
        if drops.lastAt then drops.intervalSum = drops.intervalSum + (now - drops.lastAt) end
        drops.lastAt = now
        WTM:SendMessage("WTM_HEAP_DECREASE_OBSERVED", freed)
    end
    previousLuaKB = kb

    self.history.lua:Push(kb)
    self.history.times:Push(GetTime())

    -- Session growth as a least-squares slope over the retained curve, so a
    -- single spike does not read as a leak.
    self:UpdateGrowthTrend()
end

local slopeX, slopeY = {}, {}
function Memory:UpdateGrowthTrend()
    local ring = self.history.lua
    local times = self.history.times
    local n = ring.count
    if n < 8 then return end
    local step = math.max(1, math.floor(n / 60))
    local count = 0
    for i = 1, n, step do
        count = count + 1
        slopeX[count] = times:Get(i)
        slopeY[count] = ring:Get(i)
    end
    if count < 3 then return end
    local perSecond = MathU.Slope(slopeX, slopeY, count)
    self.current.growthKBPerMin = perSecond * 60
end

function Memory:GetHeapDropSummary()
    local drops = self.heapDrops
    if drops.events == 0 then
        return "No heap decrease observed yet this session."
    end
    local avgInterval = drops.events > 1 and (drops.intervalSum / (drops.events - 1)) or 0
    return ("%d heap decreases observed, %s reclaimed in total, roughly every %s. %s")
        :format(drops.events, WTM.Format.Memory(drops.totalFreedKB),
                WTM.Format.Duration(avgInterval), WTM.C.TXT_GC_NOTE)
end

--------------------------------------------------------------------------
-- Per-addon memory (expensive, infrequent)
--------------------------------------------------------------------------

function Memory:SampleAddons()
    if not (api.UpdateAddOnMemoryUsage and api.GetAddOnMemoryUsage) then return end

    local t0 = Compat.Now()
    -- The one genuinely expensive call in the whole addon.
    local ok = pcall(api.UpdateAddOnMemoryUsage)
    if not ok then return end

    local list = WTM.Processes.list
    local now = GetTime()
    local elapsedMinutes = (now - (self.sessionStart or now)) / 60
    local sum = 0

    for i = 1, #list do
        local record = list[i]
        if record.loaded then
            local okMem, kb = pcall(api.GetAddOnMemoryUsage, record.index)
            if okMem and kb then
                if record.memStartKB == nil then record.memStartKB = kb end
                record.memDeltaKB = kb - record.memKB
                record.memKB = kb
                if kb > record.memPeakKB then record.memPeakKB = kb end

                if elapsedMinutes > 0.5 then
                    record.memGrowthKBPerMin = (kb - record.memStartKB) / elapsedMinutes
                end

                if record.memRing then record.memRing:Push(kb) end
                sum = sum + kb
            end
        end
    end

    local cur = self.current
    cur.addonSumKB      = sum
    if cur.addonStartKB == nil then cur.addonStartKB = sum end
    if sum > (cur.addonPeakKB or 0) then cur.addonPeakKB = sum end
    cur.lastAddonScanAt = now
    cur.addonScanCostMs = Compat.Now() - t0

    WTM:SendMessage("WTM_MEMORY_SAMPLED")
end

--------------------------------------------------------------------------
-- Growth ranking
--------------------------------------------------------------------------

--- Addons sorted by growth since the start of the session.  This answers
--- "who is getting bigger", which is as close to leak detection as the API
--- allows.  The UI says "Potential sustained memory growth", never "leak".
function Memory:GetGrowthRanking(out, limit)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end

    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]
        if record.loaded and record.memStartKB then
            local growth = record.memKB - record.memStartKB
            if growth > 0 then
                out[#out + 1] = {
                    name       = record.name,
                    title      = record.titleClean,
                    startKB    = record.memStartKB,
                    currentKB  = record.memKB,
                    growthKB   = growth,
                    perMinute  = record.memGrowthKBPerMin or 0,
                    sustained  = (record.memGrowthKBPerMin or 0) >=
                                 WTM.db.profile.memory.growthThresholdKBPerMin,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.growthKB > b.growthKB end)
    if limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function Memory:GetTopConsumers(out, limit)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]
        if record.loaded and record.memKB > 0 then
            out[#out + 1] = { name = record.name, title = record.titleClean, memKB = record.memKB }
        end
    end
    table.sort(out, function(a, b) return a.memKB > b.memKB end)
    if limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

--------------------------------------------------------------------------
-- SavedVariables size estimate (opt-in)
--------------------------------------------------------------------------
-- There is no file system access, so the only way to size an addon's saved
-- data is to walk the global table it saves into.  That is a real cost on a
-- large database, so it is off by default and always run on demand.

local function EstimateTable(value, depth, seen)
    depth = (depth or 0) + 1
    if depth > 10 then return 0 end
    local t = type(value)
    if t == "number" then return 8
    elseif t == "boolean" then return 4
    elseif t == "string" then return #value + 17
    elseif t ~= "table" then return 0 end
    if seen[value] then return 0 end
    seen[value] = true

    local total = 40
    for k, v in pairs(value) do
        total = total + EstimateTable(k, depth, seen) + EstimateTable(v, depth, seen) + 16
    end
    return total
end

--- Best effort: reads the addon's declared SavedVariables from its TOC and
--- measures the corresponding globals.  Returns bytes and the variable names
--- it could actually find.
function Memory:EstimateSavedVariables(record)
    local names = {}
    for _, field in ipairs({ "SavedVariables", "SavedVariablesPerCharacter" }) do
        local declared = Compat.GetAddOnMetadata(record.index, field)
        if declared then
            for name in declared:gmatch("[^,%s]+") do names[#names + 1] = name end
        end
    end
    if #names == 0 then return nil, names end

    local seen = {}
    local total = 0
    for i = 1, #names do
        local value = _G[names[i]]
        if value ~= nil then total = total + EstimateTable(value, 0, seen) end
    end
    return total, names
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Memory:OnInitialize()
    self.history.lua   = Ring.New(720)
    self.history.times = Ring.New(720)
    self.available     = WTM.Caps:Has("luaMemory")
    self.addonAvailable = WTM.Caps:Has("addonMemory")
end

function Memory:OnEnable()
    self.sessionStart = GetTime()
    if not self.available then return end

    local intervals = WTM.db.profile.sampling.intervals
    -- The cheap heap read rides along with the history task frequency.
    WTM.Scheduler:Register("luamem", function() Memory:SampleLua() end,
        intervals.luamem, C.SAMPLE_DEFAULTS.luamem.burst, 0.15, "sampler")

    if self.addonAvailable then
        WTM.Scheduler:Register("memory", function() Memory:SampleAddons() end,
            intervals.memory, C.SAMPLE_DEFAULTS.memory.burst, 0.6, "sampler")
    end

    self:SampleLua()
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end

function Memory:Reset()
    local cur = self.current
    cur.luaStartKB, cur.luaPeakKB, cur.growthKBPerMin = cur.luaKB, cur.luaKB, 0
    local drops = self.heapDrops
    drops.events, drops.lastAt, drops.lastFreedKB, drops.totalFreedKB, drops.intervalSum = 0, nil, 0, 0, 0
    previousLuaKB = nil
    self.history.lua:Reset()
    self.history.times:Reset()
    self.sessionStart = GetTime()
end
