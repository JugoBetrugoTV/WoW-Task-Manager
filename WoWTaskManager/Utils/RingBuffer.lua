--[[--------------------------------------------------------------------------
    WoW Task Manager - Utils/RingBuffer.lua

    Two flavors:
      RingBuffer   - fixed-size ring of numbers.  Zero allocation after New().
      SlotRing     - fixed-size ring of pre-allocated record tables.  Push()
                     hands back the slot to fill in; nothing is ever created
                     during sampling.

    Both are 1-based and store `count` entries where count <= size.  Index 1 is
    always the OLDEST entry, so iteration reads naturally left-to-right on a
    time axis.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

--------------------------------------------------------------------------
-- Numeric ring
--------------------------------------------------------------------------

local RingBuffer = {}
RingBuffer.__index = RingBuffer
WTM.RingBuffer = RingBuffer

function RingBuffer.New(size)
    local self = setmetatable({}, RingBuffer)
    self.size  = size
    self.head  = 0      -- index of the newest entry
    self.count = 0
    self.data  = {}
    for i = 1, size do self.data[i] = 0 end
    return self
end

function RingBuffer:Push(v)
    local head = self.head + 1
    if head > self.size then head = 1 end
    self.head = head
    self.data[head] = v
    if self.count < self.size then self.count = self.count + 1 end
    return head
end

--- i = 1 is the oldest retained entry, i = count the newest.
function RingBuffer:Get(i)
    local count = self.count
    if i < 1 or i > count then return nil end
    local idx = self.head - count + i
    if idx < 1 then idx = idx + self.size end
    return self.data[idx]
end

function RingBuffer:Newest()
    if self.count == 0 then return nil end
    return self.data[self.head]
end

function RingBuffer:Reset()
    self.head, self.count = 0, 0
    for i = 1, self.size do self.data[i] = 0 end
end

--- Returns min, max, avg over the retained entries without allocating.
function RingBuffer:Stats()
    local n = self.count
    if n == 0 then return 0, 0, 0 end
    local lo, hi, sum = math.huge, -math.huge, 0
    for i = 1, n do
        local v = self:Get(i)
        if v < lo then lo = v end
        if v > hi then hi = v end
        sum = sum + v
    end
    return lo, hi, sum / n
end

--------------------------------------------------------------------------
-- Slot ring (records)
--------------------------------------------------------------------------
-- The flight recorder's backbone.  `template` lists the numeric fields; every
-- slot is created once at New() and reused forever, so the recorder produces
-- no garbage at all while idling.

local SlotRing = {}
SlotRing.__index = SlotRing
WTM.SlotRing = SlotRing

function SlotRing.New(size, template)
    local self = setmetatable({}, SlotRing)
    self.size     = size
    self.head     = 0
    self.count    = 0
    self.template = template
    self.slots    = {}
    self.seq      = 0   -- monotonically increasing push counter
    for i = 1, size do
        local slot = {}
        for j = 1, #template do slot[template[j]] = 0 end
        slot._seq = 0
        self.slots[i] = slot
    end
    return self
end

--- Advances the ring and returns the slot to write into.  The caller is
--- expected to overwrite every field it cares about; stale values from the
--- previous lap are cleared here for the declared template fields.
function SlotRing:Acquire()
    local head = self.head + 1
    if head > self.size then head = 1 end
    self.head = head
    if self.count < self.size then self.count = self.count + 1 end
    self.seq = self.seq + 1

    local slot = self.slots[head]
    local template = self.template
    for j = 1, #template do slot[template[j]] = 0 end
    slot._seq = self.seq
    return slot
end

function SlotRing:Get(i)
    local count = self.count
    if i < 1 or i > count then return nil end
    local idx = self.head - count + i
    if idx < 1 then idx = idx + self.size end
    return self.slots[idx]
end

function SlotRing:Newest()
    if self.count == 0 then return nil end
    return self.slots[self.head]
end

--- Translates an absolute sequence number into a current index, or nil when
--- that sample has already been overwritten.
function SlotRing:IndexOfSeq(seq)
    local oldestSeq = self.seq - self.count + 1
    if seq < oldestSeq or seq > self.seq then return nil end
    return seq - oldestSeq + 1
end

--- Finds the first retained index whose `t` field is >= time.
function SlotRing:IndexAtTime(t)
    local n = self.count
    if n == 0 then return nil end
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if (self:Get(mid).t or 0) < t then lo = mid + 1 else hi = mid end
    end
    return lo
end

function SlotRing:Reset()
    self.head, self.count, self.seq = 0, 0, 0
end
