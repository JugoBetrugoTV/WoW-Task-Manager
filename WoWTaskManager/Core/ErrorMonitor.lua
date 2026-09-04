--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/ErrorMonitor.lua

    Lua error capture, grouping and correlation.

    WHAT THIS IS NOT
    ----------------
    It is not a port of BugGrabber or BugSack. No code, table layout, callback
    registry or API surface is taken from either. The mechanism used here -
    chaining the client's error handler - is the only mechanism WoW offers, and
    it is documented behaviour rather than anyone's invention.

    COEXISTENCE IS THE FIRST REQUIREMENT
    ------------------------------------
    Someone running BugGrabber and BugSack must keep getting every error in
    BugSack, unchanged, with this addon installed. That constrains the design
    completely:

      * The previous handler is captured and ALWAYS called, exactly once, with
        the original message. It is called even when this module decides to
        ignore, deduplicate or drop the error - "ignored" here means "not shown
        prominently in our UI", never "swallowed".
      * The previous handler is called even if our own bookkeeping throws. It
        runs inside a pcall of its own so that a fault in the chain below us
        cannot stop it either.
      * We install once. If something else installs a handler after us, our
        handler stops being called - that is their arrangement, not ours to
        fight, and it is detected and reported rather than worked around by
        re-installing in a loop.
      * We never call the previous handler twice, and never re-enter ourselves.

    RECURSION
    ---------
    An error raised inside an error handler is the classic way to hang a
    client. A flag guards the whole handler; while it is set, an incoming error
    goes straight to the previous handler and nothing else happens.

    COST
    ----
    The handler is allowed to do real work, because errors are supposed to be
    rare. Error storms are the case that has to stay cheap, so a duplicate
    takes a fast path: hash the message, bump a counter, update a timestamp,
    return. No stack is captured for a duplicate, no context snapshot is taken,
    and nothing is written to the saved database.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local Fmt    = WTM.Format

local ErrorMonitor = WTM:NewModule("ErrorMonitor")
WTM.Errors = ErrorMonitor

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

-- Grouped errors, newest group last. One entry per fingerprint.
ErrorMonitor.groups = {}
ErrorMonitor.byFingerprint = {}

-- Exact message text -> group, which is the memo that makes a storm cheap.
--
-- Fingerprinting normalises a message, and normalising means gsub, and gsub
-- means a new string per call. Doing that ten thousand times during a storm is
-- ten thousand allocations for an answer we already had, so the exact text is
-- checked first: a bug firing in OnUpdate produces the identical string every
-- time, and that is the case worth being fast at.
ErrorMonitor.byRawMessage = {}
ErrorMonitor.rawMemoCount = 0

ErrorMonitor.stats = {
    total          = 0,   -- every error seen, duplicates included
    unique         = 0,   -- distinct fingerprints
    suppressed     = 0,   -- duplicates folded into an existing group
    internal       = 0,   -- errors raised by this addon itself
    lastAt         = nil,
    lastGroup      = nil,
    droppedByCap   = 0,   -- new fingerprints refused because the cap was hit
}

-- Rolling window for the error rate and storm detection.
--
-- One counter per second, in a fixed array indexed by the second modulo the
-- window. A list of timestamps was the obvious shape and the wrong one: ten
-- thousand errors in a minute made it a ten thousand entry array trimmed with
-- table.remove(list, 1), which is O(n) each time and therefore O(n squared)
-- over the storm. That is the exact condition this feature exists to survive.
--
-- These buckets are O(1) per error, never grow, and never allocate.
local RECENT_WINDOW = 60
local rateCounts, rateSeconds = {}, {}
for i = 1, RECENT_WINDOW do rateCounts[i], rateSeconds[i] = 0, -1 end

-- time() is a wall-clock call, and calling it once per error means calling it
-- ten thousand times during a storm for an answer that only changes once a
-- second. Cached against the game clock instead.
local cachedSecond, cachedEpoch = -1, 0

local function EpochFor(now)
    local second = math.floor(now)
    if second ~= cachedSecond then
        cachedSecond, cachedEpoch = second, time()
    end
    return cachedEpoch
end

--- Adds one occurrence at `now`, expiring whatever second the slot held.
local function NoteOccurrence(now)
    local second = math.floor(now)
    local index = (second % RECENT_WINDOW) + 1
    if rateSeconds[index] ~= second then
        rateSeconds[index] = second
        rateCounts[index] = 0
    end
    rateCounts[index] = rateCounts[index] + 1
end

local function ClearOccurrences()
    for i = 1, RECENT_WINDOW do rateCounts[i], rateSeconds[i] = 0, -1 end
end

-- Set while inside our handler. Everything about recursion protection hangs
-- off this one flag.
local inHandler = false

-- The handler that was installed when we arrived. Never replaced, never
-- dropped, always called.
--
-- Both of these live on `chaining` rather than as file locals so that the
-- state is inspectable: the Errors page reports it, and the test suite has to
-- be able to arrange "no previous handler", "a previous handler", "a handler
-- installed after ours" and so on without the module hiding which is which.
ErrorMonitor.chaining = {
    installed      = false,
    hadPrevious    = false,
    -- The handler that was current when Install ran. Called on every error.
    previous       = nil,
    -- Our own handler function, so a displacement check can compare identity.
    ours           = nil,
    -- True once something else has installed a handler after ours, which means
    -- we are no longer being called. Detected, reported, not fought.
    displaced      = false,
    displacedAt    = nil,
}
local chaining = ErrorMonitor.chaining

--------------------------------------------------------------------------
-- Fingerprinting
--------------------------------------------------------------------------
--
-- Two errors are "the same error" when they come from the same place and say
-- the same thing. Everything that varies between occurrences of one bug -
-- table addresses, counts, coordinates, unit GUIDs - is normalised away first,
-- or a storm of one bug would look like a thousand distinct ones.

--- Strips the parts of a message that change between occurrences.
local function NormalizeMessage(message)
    message = tostring(message or "")
    -- Table and function addresses.
    message = message:gsub("0x%x+", "0xADDR")
    message = message:gsub("table: %x+", "table: ADDR")
    message = message:gsub("function: %x+", "function: ADDR")
    -- Bare numbers, which are usually indices or counts.
    message = message:gsub("%d+", "N")
    return message
end

--- The file and line an error came from, if the message carries them.
--- WoW's messages start with "Interface/AddOns/Foo/Bar.lua:812: ...".
local function ParseLocation(message)
    message = tostring(message or "")
    local path, line = message:match("^(.-%.lua):(%d+):")
    if not path then
        path, line = message:match("(%[string \"[^\"]+\"%]):(%d+):")
    end
    return path, tonumber(line)
end

--- The addon a path belongs to, or nil when the path does not name one.
---
--- Deliberately conservative. An error from the default UI, from a string
--- chunk, or from a path shape we do not recognise returns nil, and the UI
--- shows "Unknown" rather than the nearest plausible addon.
local function ParseAddon(path)
    if not path then return nil end
    -- Interface/AddOns/<Name>/... in either slash direction.
    local name = path:match("[Ii]nterface[/\\][Aa]dd[Oo]ns[/\\]([^/\\]+)")
    if name then return name end
    return nil
end

--- The first few stack frames, which is what distinguishes two errors that
--- share a message but arrive by different routes.
local function TopFrames(stack, count)
    -- Coerced, not assumed. This is reached with whatever another addon put in
    -- its database: the BugGrabber bridge passes that straight through, and a
    -- future shape change there must not turn into an error raised from inside
    -- our own error handling. A number here used to throw.
    if type(stack) ~= "string" then return "" end
    if stack == "" then return "" end
    local frames, n = {}, 0
    for line in stack:gmatch("[^\n]+") do
        n = n + 1
        frames[n] = line:gsub("%d+", "N")
        if n >= (count or 3) then break end
    end
    return table.concat(frames, "|")
end

--- The identity of a bug, as opposed to the identity of one occurrence.
function ErrorMonitor:Fingerprint(message, stack, kind)
    local path, line = ParseLocation(message)
    return ("%s:%s:%s:%s:%s"):format(
        kind or "lua", path or "?", tostring(line or "?"),
        NormalizeMessage(message), TopFrames(stack, 3))
end

--------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------

--- A snapshot of what was happening when an error arrived.
---
--- Taken once per GROUP, not per occurrence: capturing frame time and latency
--- a thousand times during a storm would make the storm worse, and the
--- readings would all be from the same second anyway.
local function CaptureContext()
    local ft  = WTM.FrameTime.current
    local net = WTM.Network.current
    local ctx = WTM.Context.state
    return {
        fps          = ft.fps,
        frameMs      = ft.avgMs,
        latencyHome  = WTM.Caps:Has("latency") and net.latencyHome or nil,
        latencyWorld = WTM.Caps:Has("latency") and net.latencyWorld or nil,
        luaKB        = WTM.Memory.current.luaKB,
        -- Addon CPU is cumulative, so the figure only means anything with the
        -- window it was measured over attached to it.
        cpuPct       = WTM.CPU.available and WTM.CPU.current.totalPct or nil,
        cpuWindowSec = WTM.CPU.available and WTM.CPU.current.sampleWindowSec or nil,
        eventsPerSec = WTM.Events.available and WTM.Events.current.perSecond or nil,
        overheadMsPerSec = WTM.Overhead.current.totalMsPerSec,
        zone         = ctx.zone,
        instanceType = ctx.instanceType,
        difficulty   = ctx.difficulty,
        combat       = ctx.combat,
        encounter    = ctx.encounter,
        groupSize    = ctx.groupSize,
        sessionId    = WTM.Sessions.current and WTM.Sessions.current.id or nil,
    }
end

--------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------

local function settings()
    return WTM.db.profile.errors
end

--- Remembers that this exact text belongs to this group.
---
--- The memo is capped and emptied wholesale when it is full rather than being
--- evicted entry by entry: it is a cache, losing it costs one fingerprint per
--- message afterwards, and an LRU here would be more machinery than the thing
--- it protects.
function ErrorMonitor:MemoiseMessage(message, group)
    if self.byRawMessage[message] then return end
    local cap = (settings().maxUnique or C.ERROR_MAX_UNIQUE) * 2
    if self.rawMemoCount >= cap then
        for key in pairs(self.byRawMessage) do self.byRawMessage[key] = nil end
        self.rawMemoCount = 0
    end
    self.byRawMessage[message] = group
    self.rawMemoCount = self.rawMemoCount + 1
end

--- Trims the group list to the configured cap, oldest first.
local function EnforceCap()
    local cap = settings().maxUnique or C.ERROR_MAX_UNIQUE
    local groups = ErrorMonitor.groups
    while #groups > cap do
        local removed = table.remove(groups, 1)
        ErrorMonitor.byFingerprint[removed.fingerprint] = nil
        -- Leaving a memo pointing at an evicted group would resurrect it with
        -- the next occurrence, so the memo goes with it.
        for text, group in pairs(ErrorMonitor.byRawMessage) do
            if group == removed then
                ErrorMonitor.byRawMessage[text] = nil
                ErrorMonitor.rawMemoCount = ErrorMonitor.rawMemoCount - 1
            end
        end
    end
end

--- Records one occurrence. Returns the group it belongs to.
--- Increments an existing group. No fingerprint, no stack, no context, no
--- allocation - the whole cost of a repeat.
local function CountRepeat(self, group, now)
    group.count    = group.count + 1
    group.lastAt   = now
    group.lastEpoch = EpochFor(now)
    group.timeRing[group.timeCursor] = now
    group.timeCursor = (group.timeCursor % C.ERROR_TIME_RING) + 1
    if group.timeFilled < C.ERROR_TIME_RING then
        group.timeFilled = group.timeFilled + 1
    end
    self.stats.suppressed = self.stats.suppressed + 1
    self.stats.lastGroup = group
    return group
end

--- True when this exact message has been seen before, so the caller can skip
--- capturing a stack it is only going to throw away.
function ErrorMonitor:IsKnownMessage(message)
    return self.byRawMessage[message] ~= nil
end

--- Records one occurrence.
---
--- `options` is optional: { kind = "lua"|"forbidden"|"warning", addon = name }.
--- An explicit addon comes from the client itself - the blocked-action events
--- name the addon in their payload - and is therefore better attribution than
--- reading a file path, so it wins.
function ErrorMonitor:Record(message, stack, isInternal, options)
    -- Normalised once, here, because everything below assumes strings and this
    -- is a public entry point reached from three directions: our own handler,
    -- the blocked-action events, and another addon's stored error objects.
    if type(message) ~= "string" then message = tostring(message) end
    if type(stack) ~= "string" then stack = nil end

    local kind = options and options.kind or "lua"
    local explicitAddon = options and options.addon or nil
    local source = options and options.source or "handler"
    local now = GetTime()

    -- THE FAST PATH, taken before anything is computed. Exact string identity
    -- only: two different bugs never produce byte-identical messages, because
    -- the file and line are in the text.
    local known = self.byRawMessage[message]
    if known then
        self.stats.total = self.stats.total + 1
        self.stats.lastAt = now
        NoteOccurrence(now)
        return CountRepeat(self, known, now)
    end

    local fingerprint = self:Fingerprint(message, stack, kind)
    local group = self.byFingerprint[fingerprint]

    self.stats.total = self.stats.total + 1
    self.stats.lastAt = now

    -- Rolling window for the rate and for storm detection.
    NoteOccurrence(now)

    if group then
        -- Same bug, different text: an index or an address varied. Memoise this
        -- spelling of it so the next one takes the fast path above.
        self:MemoiseMessage(message, group)
        return CountRepeat(self, group, now)
    end

    local cap = settings().maxUnique or C.ERROR_MAX_UNIQUE
    if #self.groups >= cap and not settings().evictOldest then
        -- Refusing to grow is a decision worth reporting rather than hiding:
        -- the count keeps rising so the diagnosis stays honest even though the
        -- detail is gone.
        self.stats.droppedByCap = self.stats.droppedByCap + 1
        return nil
    end

    local path, line = ParseLocation(message)
    local addon = explicitAddon or ParseAddon(path)

    -- The stack is the largest thing stored, so it is capped by configuration
    -- rather than kept whole.
    local maxStack = settings().maxStackLength or C.ERROR_MAX_STACK
    if stack and #stack > maxStack then
        stack = stack:sub(1, maxStack) .. "\n[stack truncated by WoW Task Manager]"
    end

    group = {
        fingerprint = fingerprint,
        message     = tostring(message),
        stack       = stack,
        kind        = kind,
        -- Where this reached us. "handler" is our own error handler;
        -- "buggrabber" means another addon owns the handler and we are reading
        -- from the integration point it publishes.
        source      = source,
        addon       = addon,
        -- Distinguishes an addon the client named, or one read out of a file
        -- path, from no addon at all. Nothing here is ever guessed.
        addonCertain = addon ~= nil,
        addonFromClient = explicitAddon ~= nil,
        file        = path,
        line        = line,
        internal    = isInternal or false,
        count       = 1,
        firstAt     = now,
        lastAt      = now,
        firstEpoch  = time(),
        lastEpoch   = time(),
        context     = CaptureContext(),
        sessionId   = WTM.Sessions.current and WTM.Sessions.current.id or nil,
        timeRing    = { now },
        timeCursor  = 2,
        timeFilled  = 1,
    }

    self.groups[#self.groups + 1] = group
    self.byFingerprint[fingerprint] = group
    self:MemoiseMessage(message, group)
    self.stats.unique = self.stats.unique + 1
    self.stats.lastGroup = group

    if isInternal then self.stats.internal = self.stats.internal + 1 end

    EnforceCap()

    -- A marker on the shared axis, so an error can be found again next to the
    -- frame time that surrounded it.
    if settings().timelineMarkers then
        -- The FINGERPRINT, not the group. A marker outlives the group it
        -- refers to: markers are capped at 400 and errors at 400, and the two
        -- caps evict on different schedules. Holding the object meant an
        -- evicted group stayed alive through the marker - with its stack -
        -- and clicking the marker opened an error the monitor no longer had.
        WTM.Context:AddMarker("luaerror",
            ("%s %s: %s"):format((C.ERROR_KINDS[kind] or C.ERROR_KINDS.lua).label,
                addon or "Unknown", Fmt.Truncate(tostring(message), 60)),
            group.fingerprint)
    end

    self:Notify(group)

    WTM:SendMessage("WTM_ERROR_CAPTURED", group)
    return group
end

--------------------------------------------------------------------------
-- Chat notification
--------------------------------------------------------------------------

--- One line for a NEW error, never for a repeat, and never more often than the
--- configured cooldown.
---
--- The cooldown is the part that matters. During a storm the notices are what
--- makes the storm worse: printing to chat is a frame's worth of work, and an
--- error monitor whose own output turns a hiccup into a freeze has failed at
--- the only job it had.
function ErrorMonitor:Notify(group)
    if not settings().notifications then return end
    -- An ignored error is one the user asked not to be told about. It is still
    -- counted; this is the only thing ignoring switches off.
    if self:IsIgnored(group) then return end

    local now = GetTime()
    local cooldown = settings().notifyCooldown or 30
    if self.lastNotifyAt and (now - self.lastNotifyAt) < cooldown then
        self.suppressedNotices = (self.suppressedNotices or 0) + 1
        return
    end
    self.lastNotifyAt = now

    local prefix = group.internal
        and "|cffF0533FWoW Task Manager internal error|r: "
        or ("|cffF0533FLua error|r in %s: "):format(group.addon or "an unattributed file")

    WTM:Print(prefix .. Fmt.Truncate((tostring(group.message)):gsub("\n", " "), 120))

    if (self.suppressedNotices or 0) > 0 then
        WTM:Print(("  (%d further new error%s were not announced; the notice cooldown is %d s)")
            :format(self.suppressedNotices,
                    self.suppressedNotices == 1 and "" or "s", cooldown))
        self.suppressedNotices = 0
    end
end

--------------------------------------------------------------------------
-- The handler
--------------------------------------------------------------------------

--- Our error handler.
---
--- Contract, in order:
---   1. If we are already inside it, pass through and return. Nothing else.
---   2. Do our own bookkeeping inside a pcall, so a fault in it cannot stop
---      step 3.
---   3. Call the previous handler exactly once with the ORIGINAL message.
---
--- Step 3 happens whatever step 2 decided. There is no path through this
--- function where an error reaches us and does not reach the handler that was
--- installed before us.
--- Everything this addon does with an error, in one function so the handler
--- itself can stay a control-flow skeleton.
local function Bookkeep(message)
    local text = tostring(message)

    -- Our own errors are recorded like anyone else's and marked, never hidden.
    -- An addon that quietly swallows its own faults is worse than one that
    -- has them.
    local internal = text:find("WoWTaskManager", 1, true) ~= nil
        or text:find("WTM:", 1, true) ~= nil

    if settings().enabled then
        local stack
        -- A message already seen needs no stack: Record will fold it into the
        -- group that already has one. debugstack walks the call stack and
        -- builds a string, which is the single most expensive thing in this
        -- path, so a storm never pays for it.
        if not ErrorMonitor:IsKnownMessage(text) and type(debugstack) == "function" then
            -- Skip our own frames; 3 is this function, the pcall and the
            -- handler itself.
            local okStack, result = pcall(debugstack, 3, 20, 20)
            if okStack then stack = result end
        end
        ErrorMonitor:Record(text, stack, internal)
    end

    if internal then ErrorMonitor:NoteInternalError() end
end

local function HandleError(message, ...)
    if inHandler then
        -- Re-entry: an error was raised while handling an error. Pass it
        -- straight down and do nothing of our own - this is the case that
        -- hangs a client if it is handled with anything more ambitious.
        if chaining.previous then chaining.previous(message, ...) end
        return
    end

    inHandler = true

    local ok, err = pcall(Bookkeep, message)

    -- Step 3, unconditionally. Its own pcall: a fault in the handler below us
    -- must not propagate back into whatever raised the error.
    --
    -- Still INSIDE the guard. If the handler below raises an error of its own,
    -- that error has to take the re-entry path above and stop there; releasing
    -- the guard first would let a broken error addon and this one call each
    -- other until the stack ran out.
    if chaining.previous then
        pcall(chaining.previous, message, ...)
    end

    inHandler = false

    -- Only reported after the chain has run, so a bug in our bookkeeping can
    -- never cost someone their error output.
    if not ok and not ErrorMonitor.reportedOwnFault then
        ErrorMonitor.reportedOwnFault = true
        ErrorMonitor.ownFault = tostring(err)
    end
end

--------------------------------------------------------------------------
-- Installation
--------------------------------------------------------------------------

--- Installs our handler in front of whatever is already there.
---
--- Returns false with a reason when the client does not offer the mechanism.
--- Nothing here is retried in a loop: if another addon installs a handler
--- after us, that is its arrangement, and fighting over the slot would break
--- exactly the coexistence this module is built around.
function ErrorMonitor:Install()
    if self.chaining.installed then return true end

    if type(_G.seterrorhandler) ~= "function"
        or type(_G.geterrorhandler) ~= "function" then
        self.chaining.reason =
            "This client does not expose seterrorhandler / geterrorhandler, so Lua errors cannot be captured at all."
        return false, self.chaining.reason
    end

    local existing = _G.geterrorhandler()
    if type(existing) == "function" and existing ~= chaining.ours then
        chaining.previous = existing
        self.chaining.hadPrevious = true
    end

    chaining.ours = HandleError
    local ok = pcall(_G.seterrorhandler, chaining.ours)
    if not ok then
        self.chaining.reason = "seterrorhandler threw on this client."
        return false, self.chaining.reason
    end

    -- VERIFY. Calling seterrorhandler is not the same as being installed.
    --
    -- BugGrabber saves the real seterrorhandler, installs its own handler with
    -- it, and then replaces the global with an empty function so nothing can
    -- displace it. Our call then succeeds, throws nothing, and does nothing.
    -- Without this read-back we reported "chained" while receiving no errors at
    -- all - a real client had six hundred thousand errors in BugGrabber and
    -- zero here.
    local installed = _G.geterrorhandler()
    if installed ~= chaining.ours then
        chaining.previous = nil
        chaining.hadPrevious = false
        self.chaining.refused = true
        self.chaining.reason =
            "Another error addon owns the error handler and has made it permanent - it replaced seterrorhandler itself, so no later addon can install one. Nothing is broken and nothing was fought over."
        return false, self.chaining.reason
    end

    self.chaining.installed = true
    return true
end

--- Have we been displaced by something installed later?
---
--- Checked periodically rather than defended against. If BugGrabber loads
--- after us it becomes the handler and we stop seeing errors - which is
--- correct behaviour for it, and something the user should be told rather than
--- something to fight over.
function ErrorMonitor:CheckChain()
    if type(_G.geterrorhandler) ~= "function" then return end

    -- Not installed and not yet bridged: an error addon may have loaded after
    -- us, or on demand, since the last check. Its integration point is worth
    -- another look rather than leaving the page empty for the session.
    if not self.chaining.installed then
        if not (self.bridge and self.bridge.subscribed) then
            if self:InstallBugGrabberBridge() then self:BackfillFromBugGrabber() end
        end
        return
    end

    local current = _G.geterrorhandler()
    if current ~= chaining.ours and not self.chaining.displaced then
        self.chaining.displaced = true
        self.chaining.displacedAt = GetTime()
        -- Displaced AFTER installing, which is the other order the same
        -- situation arrives in: we were first, something permanent arrived
        -- second. Errors stop reaching us from here on, so read from whoever
        -- took over if it offers a way to.
        if not (self.bridge and self.bridge.subscribed) then
            self:InstallBugGrabberBridge()
        end
        WTM:SendMessage("WTM_ERROR_CHAIN_DISPLACED")
    elseif current == chaining.ours and self.chaining.displaced then
        -- It can come back, if whatever displaced us chained to us in turn.
        self.chaining.displaced = false
    end
end

function ErrorMonitor:DescribeChain()
    if not self.chaining.installed then
        if self.bridge and self.bridge.subscribed then
            return ("%s Errors are being read from BugGrabber's published feed instead, so this page fills up normally%s."):format(
                self.chaining.reason or "The error handler could not be installed.",
                (self.backfilled or 0) > 0
                    and (" - %d already-recorded error%s were taken over at login"):format(
                        self.backfilled, self.backfilled == 1 and "" or "s")
                    or ""), "ok"
        end
        return self.chaining.reason or "Not installed.", "crit"
    end
    if self.chaining.displaced then
        if self.bridge and self.bridge.subscribed then
            return "Another addon installed its error handler after this one, so errors no longer arrive here directly. They are being read from BugGrabber's published feed instead, so this page keeps filling up.", "ok"
        end
        return "Another addon installed its error handler after this one, so errors are no longer reaching here. Nothing is broken - that addon is now handling them - but this page will stop filling up.", "warn"
    end
    if self.chaining.hadPrevious then
        return "Installed in front of an existing handler. Every error is recorded here and then passed on unchanged, so any other error addon keeps working.", "ok"
    end
    return "Installed. No other error handler was present when this one was.", "ok"
end

--------------------------------------------------------------------------
-- Storm detection
--------------------------------------------------------------------------

--- How many errors arrived in the last `seconds`.
--- The occurrence times still held for a group, oldest first.
---
--- Only the last C.ERROR_TIME_RING of them exist: everything before that was
--- overwritten in place, and the view says so rather than implying the list is
--- the whole history.
function ErrorMonitor:Occurrences(group, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not group or not group.timeRing then return out end

    local ring, filled = group.timeRing, group.timeFilled or 0
    if filled < C.ERROR_TIME_RING then
        for i = 1, filled do out[#out + 1] = ring[i] end
    else
        local cursor = group.timeCursor or 1
        for i = 0, C.ERROR_TIME_RING - 1 do
            local index = ((cursor - 1 + i) % C.ERROR_TIME_RING) + 1
            if ring[index] then out[#out + 1] = ring[index] end
        end
    end
    return out
end

--- True when the group has produced more occurrences than the ring can hold,
--- which is the only case where the timeline is a sample rather than the whole.
function ErrorMonitor:OccurrencesTruncated(group)
    return group ~= nil and (group.count or 0) > C.ERROR_TIME_RING
end

--- The group a timeline marker refers to, or nil once it has been evicted.
---
--- Markers hold a fingerprint rather than the group itself, so this is where
--- "does that error still exist" gets answered instead of trusting a reference
--- that the cap may have made stale.
function ErrorMonitor:GroupForMarker(marker)
    if not marker or marker.kind ~= "luaerror" then return nil end
    if type(marker.ref) ~= "string" then return nil end
    return self.byFingerprint[marker.ref]
end

--- Occurrences the user has not asked to be left alone about.
---
--- Ignoring changes what is shown, never what is counted: `stats.total` keeps
--- every occurrence, and this figure exists alongside it rather than instead
--- of it. A setting decides which of the two the badge shows.
function ErrorMonitor:CountVisible()
    if settings().countIgnored then return self.stats.total end
    local total = 0
    for i = 1, #self.groups do
        local group = self.groups[i]
        if not self:IsIgnored(group) then total = total + (group.count or 0) end
    end
    return total
end

--- Three words for a card, where DescribeChain gives a paragraph for a panel.
function ErrorMonitor:ShortChainState()
    if not self.chaining.installed then
        if self.bridge and self.bridge.subscribed then return "via BugGrabber", "ok" end
        return "not installed", "crit"
    end
    if self.chaining.displaced then return "displaced", "warn" end
    if self.chaining.hadPrevious then return "chained", "ok" end
    return "installed", "ok"
end

--- Errors per minute over the recent window, as a series a graph can draw.
---
--- Built from the rolling occurrence times the monitor already keeps, so this
--- costs a walk over at most RECENT_WINDOW seconds of timestamps and allocates
--- nothing: both output tables are supplied by the caller and reused.
function ErrorMonitor:RateSeries(values, times)
    values = values or {}
    times  = times or {}
    for i = #values, 1, -1 do values[i] = nil end
    for i = #times, 1, -1 do times[i] = nil end

    local now = GetTime()
    local buckets = C.ERROR_RATE_BUCKETS
    local span    = RECENT_WINDOW
    local width   = span / buckets

    for i = 1, buckets do
        values[i] = 0
        times[i]  = now - span + (i - 0.5) * width
    end

    local newest = math.floor(now)
    for i = 1, RECENT_WINDOW do
        local second = rateSeconds[i]
        local age = newest - second
        if second >= 0 and age >= 0 and age < span then
            local index = buckets - math.floor(age / width)
            if index < 1 then index = 1 elseif index > buckets then index = buckets end
            values[index] = values[index] + rateCounts[i]
        end
    end

    -- Counts per bucket, expressed per minute so the axis means something
    -- regardless of how the window is divided.
    local perMinute = 60 / width
    for i = 1, buckets do values[i] = values[i] * perMinute end

    return values, times
end

--- Occurrences within the last `seconds`, to one-second resolution.
---
--- Bounded by the window, not by how many errors arrived: a fixed walk over
--- RECENT_WINDOW counters, whether that covers ten errors or ten thousand.
function ErrorMonitor:CountSince(seconds)
    local newest = math.floor(GetTime())
    local oldest = newest - math.min(seconds, RECENT_WINDOW)
    local n = 0
    for i = 1, RECENT_WINDOW do
        local second = rateSeconds[i]
        if second >= oldest and second <= newest then n = n + rateCounts[i] end
    end
    return n
end

function ErrorMonitor:RatePerMinute()
    return self:CountSince(RECENT_WINDOW)
end

ErrorMonitor.storms = {}

--- Two shapes of trouble, and they are not the same thing:
---   a STORM is many errors in a short window, from anywhere;
---   a REPEATING error is one bug firing over and over.
--- Both are worth reporting, and reporting them as one thing would lose that.
function ErrorMonitor:DetectStorms()
    if not settings().enabled then return end

    local threshold = settings().stormThreshold or C.ERROR_STORM_THRESHOLD
    local window = C.ERROR_STORM_WINDOW_SEC
    local count = self:CountSince(window)

    local now = GetTime()
    if count >= threshold then
        local last = self.storms[#self.storms]
        if not last or (now - last.at) > window then
            -- How many distinct bugs were involved separates "one addon is
            -- looping" from "several things broke at once", which are
            -- different problems with different fixes.
            local distinct = 0
            for i = 1, #self.groups do
                if (now - (self.groups[i].lastAt or 0)) <= window then
                    distinct = distinct + 1
                end
            end

            local storm = {
                at = now, epoch = time(), count = count, window = window,
                distinct = distinct, kind = "storm",
            }
            self.storms[#self.storms + 1] = storm
            while #self.storms > 20 do table.remove(self.storms, 1) end
            WTM.Context:AddMarker("errorstorm",
                ("%d Lua errors in %d seconds"):format(count, window))
            WTM:SendMessage("WTM_ERROR_STORM", storm)
        end
    end

    -- A single fingerprint repeating is its own finding.
    local repeatThreshold = settings().repeatThreshold or C.ERROR_REPEAT_THRESHOLD
    for _, group in ipairs(self.groups) do
        if group.count >= repeatThreshold and not group.reportedRepeating then
            group.reportedRepeating = true
            WTM:SendMessage("WTM_ERROR_REPEATING", group)
        end
    end
end

--------------------------------------------------------------------------
-- Safe mode
--------------------------------------------------------------------------
--
-- If this addon keeps faulting, the honest response is to switch off the part
-- that is faulting and keep recording - not to disappear, and not to keep
-- throwing. A diagnostic tool that dies during the problem it was installed to
-- diagnose is worth nothing.

ErrorMonitor.safeMode = {
    active   = false,
    disabled = {},    -- module name -> reason
    internalTimes = {},
}

function ErrorMonitor:NoteInternalError()
    local now = GetTime()
    local times = self.safeMode.internalTimes
    times[#times + 1] = now
    while #times > 0 and (now - times[1]) > C.SAFE_MODE_WINDOW_SEC do
        table.remove(times, 1)
    end

    if #times >= C.SAFE_MODE_THRESHOLD and not self.safeMode.active then
        self:EnterSafeMode("repeated internal errors")
    end
end

--- Disables the UI refresh loop and the analysis pages, and keeps the samplers
--- running. Core recording is the last thing to go.
function ErrorMonitor:EnterSafeMode(reason)
    self.safeMode.active = true
    self.safeMode.reason = reason
    self.safeMode.at = GetTime()

    -- The UI is the most likely source of an internal fault and the least
    -- important thing running, so it is what stops.
    WTM.Scheduler:SetEnabled("ui", false)
    self.safeMode.disabled["UI refresh"] = reason

    WTM:Print(("|cffF0533FSafe mode|r: UI refreshing disabled after %s. Recording continues. Use |cff4c8dff/wtm safemode off|r to re-enable."):format(reason))
    WTM:SendMessage("WTM_SAFE_MODE", reason)
end

function ErrorMonitor:LeaveSafeMode()
    if not self.safeMode.active then return false end
    self.safeMode.active = false
    self.safeMode.disabled = {}
    for i = #self.safeMode.internalTimes, 1, -1 do
        self.safeMode.internalTimes[i] = nil
    end
    if WTM.UI.MainWindow:IsOpen() or WTM.UI.LiveMonitor:IsShown() then
        WTM.Scheduler:SetEnabled("ui", true)
    end
    return true
end

--------------------------------------------------------------------------
-- Ignore lists
--------------------------------------------------------------------------
--
-- Ignoring is a display decision. An ignored error is still counted, because a
-- storm of errors you have chosen not to look at still costs frame time, and a
-- performance diagnosis that pretends otherwise is wrong.

function ErrorMonitor:IsIgnored(group)
    if not group then return false end
    local ignored = settings().ignored
    if ignored.fingerprints[group.fingerprint] then return true end
    if group.addon and ignored.addons[group.addon] then return true end
    if self.sessionIgnored and self.sessionIgnored[group.fingerprint] then return true end
    return false
end

function ErrorMonitor:SetIgnored(group, ignored)
    if not group then return end
    settings().ignored.fingerprints[group.fingerprint] = ignored or nil
end

function ErrorMonitor:SetAddonIgnored(addon, ignored)
    if not addon then return end
    settings().ignored.addons[addon] = ignored or nil
end

--- Ignore until the next reload: not written to the database at all.
function ErrorMonitor:IgnoreForSession(group)
    if not group then return end
    self.sessionIgnored = self.sessionIgnored or {}
    self.sessionIgnored[group.fingerprint] = true
end

function ErrorMonitor:ClearIgnored()
    local ignored = settings().ignored
    for k in pairs(ignored.fingerprints) do ignored.fingerprints[k] = nil end
    for k in pairs(ignored.addons) do ignored.addons[k] = nil end
    self.sessionIgnored = nil
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

--- Errors attributed to one addon.
function ErrorMonitor:ForAddon(name, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not name then return out end
    for _, group in ipairs(self.groups) do
        if group.addon == name then out[#out + 1] = group end
    end
    return out
end

function ErrorMonitor:CountForAddon(name)
    local total, unique = 0, 0
    for _, group in ipairs(self.groups) do
        if group.addon == name then
            total = total + group.count
            unique = unique + 1
        end
    end
    return total, unique
end

--- The addon with the most errors this session, or nil.
function ErrorMonitor:WorstAddon()
    local counts = {}
    for _, group in ipairs(self.groups) do
        local key = group.addon or "Unknown"
        counts[key] = (counts[key] or 0) + group.count
    end
    local worst, worstCount
    for name, count in pairs(counts) do
        if not worstCount or count > worstCount then worst, worstCount = name, count end
    end
    return worst, worstCount
end

function ErrorMonitor:MostFrequent()
    local worst
    for _, group in ipairs(self.groups) do
        if not worst or group.count > worst.count then worst = group end
    end
    return worst
end

--- Incidents whose window contains this error, within `slack` seconds.
---
--- Overlap in time. Nothing more is claimed, and the UI that shows this says
--- so: an error and a stutter arriving together is a place to look, not a
--- demonstration that one produced the other.
function ErrorMonitor:RelatedIncidents(group, out, slack)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not group then return out end
    slack = slack or C.ERROR_INCIDENT_SLACK_SEC

    local function consider(cluster)
        if not cluster then return end
        local from = (cluster.startedAt or 0) - slack
        local to   = (cluster.endedAt or cluster.startedAt or 0) + slack
        if group.lastAt >= from and group.firstAt <= to then
            out[#out + 1] = cluster
        end
    end

    for _, cluster in ipairs(WTM.SpikeDetector.clusters) do consider(cluster) end

    -- The cluster still being built counts too. An error raised DURING a
    -- stutter is the case most worth showing, and it would have been the one
    -- case missed by reading only the closed list.
    consider(WTM.SpikeDetector:GetOpenCluster())

    return out
end

--- How many of this group's occurrences fell near a recorded spike.
---
--- Only the first and last occurrence carry timestamps, so this is an overlap
--- test on the group's span rather than a per-occurrence count. Stated that
--- way wherever it is shown.
function ErrorMonitor:OverlapsSpikes(group)
    local incidents = self:RelatedIncidents(group, self._relScratch or {})
    self._relScratch = incidents
    return #incidents
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function ErrorMonitor:Reset()
    for i = #self.groups, 1, -1 do self.groups[i] = nil end
    for k in pairs(self.byFingerprint) do self.byFingerprint[k] = nil end
    for k in pairs(self.byRawMessage) do self.byRawMessage[k] = nil end
    self.rawMemoCount = 0
    ClearOccurrences()
    for i = #self.storms, 1, -1 do self.storms[i] = nil end
    local stats = self.stats
    stats.total, stats.unique, stats.suppressed = 0, 0, 0
    stats.internal, stats.droppedByCap = 0, 0
    stats.lastAt, stats.lastGroup = nil, nil
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------

--- Writes a trimmed copy of this session's errors into the database.
---
--- Trimmed in three ways, all of them deliberate:
---   * the busiest groups first, capped at C.ERROR_MAX_SAVED_GROUPS;
---   * the stack kept but the occurrence ring dropped, because a timestamp
---     from a previous session is not comparable to anything in this one;
---   * the context kept, because a bug report needs it and it is small.
---
--- Called at logout. It allocates - once, at a moment when nothing is being
--- rendered - which is why it is not on any timer.
function ErrorMonitor:Persist()
    if not settings().keepAcrossSessions then return end
    local global = WTM.db.global
    global.errorSessions = global.errorSessions or {}
    if #self.groups == 0 then return end

    local ordered = {}
    for i = 1, #self.groups do ordered[i] = self.groups[i] end
    table.sort(ordered, function(a, b) return (a.count or 0) > (b.count or 0) end)

    local saved = {}
    local limit = math.min(#ordered, C.ERROR_MAX_SAVED_GROUPS)
    for i = 1, limit do
        local group = ordered[i]
        saved[i] = {
            fingerprint = group.fingerprint,
            message     = group.message,
            stack       = group.stack,
            addon       = group.addon,
            addonCertain= group.addonCertain,
            file        = group.file,
            line        = group.line,
            internal    = group.internal,
            count       = group.count,
            firstEpoch  = group.firstEpoch,
            lastEpoch   = group.lastEpoch,
            context     = group.context,
        }
    end

    global.errorSessions[#global.errorSessions + 1] = {
        id       = WTM.Sessions.current and WTM.Sessions.current.id or 0,
        epoch    = time(),
        total    = self.stats.total,
        unique   = self.stats.unique,
        internal = self.stats.internal,
        -- How many distinct groups were not written, so a report reading this
        -- back knows it is looking at a selection rather than the lot.
        omitted  = math.max(0, #ordered - limit),
        groups   = saved,
    }

    local maxSessions = settings().maxSavedSessions or C.ERROR_MAX_SAVED_SESSIONS
    while #global.errorSessions > maxSessions do
        table.remove(global.errorSessions, 1)
    end
end

--- Every error saved from previous sessions, newest session first.
function ErrorMonitor:SavedGroups(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    local sessions = WTM.db.global.errorSessions
    if not sessions then return out end
    for i = #sessions, 1, -1 do
        local session = sessions[i]
        for j = 1, #(session.groups or {}) do
            out[#out + 1] = session.groups[j]
        end
    end
    return out
end

function ErrorMonitor:OnDisable()
    -- pcall, because a fault here would happen during logout and would be
    -- invisible: the client is already tearing down its UI.
    pcall(function() ErrorMonitor:Persist() end)
end

--------------------------------------------------------------------------
-- Things that are not Lua errors, and never reach an error handler
--------------------------------------------------------------------------
--
-- seterrorhandler sees Lua errors and nothing else. Two other classes of
-- problem arrive as EVENTS instead, and they are the ones people most often
-- mean when they say an addon is broken:
--
--   ADDON_ACTION_FORBIDDEN  the client refused a protected call
--   ADDON_ACTION_BLOCKED    the same, for a call blocked rather than refused
--   LUA_WARNING             the client complaining about Lua it still ran
--
-- An error monitor that ignores these shows an empty page while the client is
-- visibly unhappy, which is exactly what a real client reported. They are
-- captured, and they are labelled as what they are: a blocked action is the
-- client refusing a call, not code that failed.

--- Both blocked-action events carry the addon and the function in their
--- payload, so the attribution comes from the client rather than from parsing
--- a path. That is the best attribution available anywhere in this file.
function ErrorMonitor:OnActionBlocked(event, addonName, functionName)
    if not settings().enabled then return end
    if not settings().captureBlocked then return end

    local text = ("%s tried to call the protected function '%s'"):format(
        addonName and ("AddOn '" .. tostring(addonName) .. "'") or "An addon",
        tostring(functionName or "?"))

    -- No stack: these are raised by the client, not thrown from Lua, so there
    -- is no Lua call stack that means anything for them.
    self:Record(text, nil,
        addonName == C.ADDON_NAME,
        { kind = "forbidden", addon = addonName })
end

function ErrorMonitor:OnLuaWarning(event, warnType, message)
    if not settings().enabled then return end
    if not settings().captureWarnings then return end

    local text = ("Lua warning (type %s): %s"):format(
        tostring(warnType or "?"), tostring(message or ""))
    self:Record(text, nil,
        text:find("WoWTaskManager", 1, true) ~= nil,
        { kind = "warning" })
end

--------------------------------------------------------------------------
-- Reading from whoever owns the error handler
--------------------------------------------------------------------------
--
-- BugGrabber makes itself permanent: it keeps a reference to the real
-- seterrorhandler, installs with it, and then replaces the global with an
-- empty function. No addon loading afterwards can install a handler, and
-- that is deliberate on its part.
--
-- Racing it is not an option and would not be a good one: renaming this addon
-- to load first would just move the problem onto whoever loses next time.
-- What BugGrabber does offer is a published integration point - it announces
-- every error it grabs, and BugSack is built on exactly that. So when it owns
-- the handler we read from it instead of competing with it.
--
-- Nothing here reaches into its internals. It is the same three public calls
-- any addon is invited to use.

local BUGGRABBER_EVENT = "BugGrabber.BugGrabbed"

--- The BugGrabber addon table, if a version with the API we need is loaded.
local function BugGrabberAPI()
    local grabber = _G.BugGrabber
    if type(grabber) ~= "table" then return nil end
    if type(grabber.GetErrorByID) ~= "function" then return nil end
    return grabber
end

--- Ingests one error that BugGrabber grabbed.
---
--- Counted here the same way as anything else: one call, one occurrence. Its
--- own counter is not copied, because it counts from its database rather than
--- from this session, and mixing the two would produce a number that is true
--- of neither.
function ErrorMonitor:IngestFromBugGrabber(tableID)
    if not settings().enabled then return end
    local grabber = BugGrabberAPI()
    if not grabber then return end

    local ok, errorObject = pcall(grabber.GetErrorByID, grabber, tableID)
    if not ok or type(errorObject) ~= "table" then return end

    local message = tostring(errorObject.message or "")
    if message == "" then return end

    local group = self:Record(message, errorObject.stack, nil, { source = "buggrabber" })
    -- BugGrabber collects the locals at the point of the error, which nothing
    -- else here can do after the fact. Worth keeping when it is offered.
    if group and errorObject.locals and not group.locals then
        group.locals = errorObject.locals
    end
end

--- Subscribes to BugGrabber's announcements. Returns true when subscribed.
function ErrorMonitor:InstallBugGrabberBridge()
    local grabber = BugGrabberAPI()
    if not grabber then return false end

    local registry = _G.EventRegistry
    if type(registry) ~= "table" or type(registry.RegisterCallback) ~= "function" then
        self.bridge = { available = true, subscribed = false,
            reason = "This client has no EventRegistry, so BugGrabber's announcements cannot be subscribed to." }
        return false
    end

    local subscribed = pcall(registry.RegisterCallback, registry, BUGGRABBER_EVENT,
        function(_, tableID)
            pcall(ErrorMonitor.IngestFromBugGrabber, ErrorMonitor, tableID)
        end, self)

    self.bridge = { available = true, subscribed = subscribed and true or false }
    return self.bridge.subscribed
end

--- Backfills what BugGrabber already holds for THIS session, so the page is
--- not empty at login after a session that had errors before we loaded.
---
--- Errors from earlier sessions are deliberately left alone: this page is
--- about the session it is showing.
function ErrorMonitor:BackfillFromBugGrabber()
    local grabber = BugGrabberAPI()
    if not grabber or type(grabber.GetDB) ~= "function" then return 0 end
    if type(grabber.GetSessionId) ~= "function" then return 0 end

    local okDb, db = pcall(grabber.GetDB, grabber)
    local okSession, session = pcall(grabber.GetSessionId, grabber)
    if not okDb or not okSession or type(db) ~= "table" then return 0 end

    local taken = 0
    for i = 1, #db do
        local errorObject = db[i]
        if type(errorObject) == "table" and errorObject.session == session
           and type(errorObject.message) == "string" then
            local group = self:Record(errorObject.message, errorObject.stack, nil,
                { source = "buggrabber" })
            if group then
                if errorObject.locals and not group.locals then
                    group.locals = errorObject.locals
                end
                taken = taken + 1
            end
        end
    end
    self.backfilled = taken
    return taken
end

--- Registers the event-borne classes, each one feature-detected: a client that
--- does not fire an event simply never produces that class, and the capability
--- report says so rather than the page looking broken.
function ErrorMonitor:InstallEventCapture()
    local frame = CreateFrame("Frame", "WTMErrorEvents")
    self.eventFrame = frame

    local wanted = {
        ADDON_ACTION_FORBIDDEN = "OnActionBlocked",
        ADDON_ACTION_BLOCKED   = "OnActionBlocked",
        LUA_WARNING            = "OnLuaWarning",
    }

    self.eventsRegistered = {}
    for event, handler in pairs(wanted) do
        if WTM.Compat.SafeRegisterEvent(frame, event) then
            self.eventsRegistered[event] = handler
        end
    end

    frame:SetScript("OnEvent", function(_, event, ...)
        local handler = ErrorMonitor.eventsRegistered[event]
        if not handler then return end
        -- pcall, because this runs inside the client's event dispatch: a fault
        -- here would surface as an error about us during somebody else's
        -- problem, which helps nobody.
        pcall(ErrorMonitor[handler], ErrorMonitor, event, ...)
    end)
end

--- How many of the event-borne classes this client actually offers.
function ErrorMonitor:DescribeEventCapture()
    if not self.eventsRegistered then return "not installed", "crit" end
    local names = {}
    for event in pairs(self.eventsRegistered) do names[#names + 1] = event end
    if #names == 0 then
        return "This client fires none of the blocked-action or warning events, so only thrown Lua errors can be captured.", "warn"
    end
    table.sort(names)
    return ("Also capturing %s."):format(table.concat(names, ", ")), "ok"
end

function ErrorMonitor:OnEnable()
    self:InstallEventCapture()

    local ok, reason = self:Install()
    if not ok then
        WTM.Caps.errorChainReason = reason
        -- Could not install. If the addon that owns the handler publishes its
        -- errors, read from there rather than showing an empty page while the
        -- client is visibly full of them.
        if self:InstallBugGrabberBridge() then
            self:BackfillFromBugGrabber()
        end
    end

    -- Storm detection and the chain check share one slow task. Neither needs
    -- to be prompt, and neither is allowed its own timer.
    WTM.Scheduler:Register("errors", function()
        ErrorMonitor:DetectStorms()
        ErrorMonitor:CheckChain()
    end, 2, 1, 0.35, "sampler")

    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")
end
