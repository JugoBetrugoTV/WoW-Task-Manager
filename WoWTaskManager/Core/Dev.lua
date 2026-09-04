--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Dev.lua

    Developer tools (/wtm dev) and the overhead benchmark (/wtm benchmark).

    Two rules govern everything in this file:

    1. INJECTED DATA IS ALWAYS MARKED.  Every record produced here carries
       `simulated = true`, and every surface that shows it prints SIMULATED.
       A diagnostic tool whose test data is indistinguishable from real
       measurements is worse than one with no test data at all.

    2. THE BENCHMARK NEVER CREATES LAG.  It does not busy-wait, allocate
       garbage or stall the client to "see what happens". It measures what this
       addon already costs, using the same debugprofilestop figures the
       overhead module collects, and prints them. Manufacturing a freeze to
       demonstrate a freeze detector would be both dishonest and rude.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local Fmt    = WTM.Format

local Dev = {}
WTM.Dev = Dev

local function out(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff4c8dffWTM dev|r " .. tostring(text))
end
Dev.Print = out

local function header(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9aa4b5-- " .. tostring(text) .. " --|r")
end

--------------------------------------------------------------------------
-- Injection
--------------------------------------------------------------------------

--- Injects a frame spike of `ms` milliseconds.
---
--- This does NOT stall the client. It feeds a synthetic frame time straight
--- into the spike detector, so the whole downstream path - classification,
--- suppression, clustering, the flight recorder capture, correlation - runs
--- exactly as it would on a real hitch, without anyone's game stuttering.
function Dev:InjectFrameSpike(ms)
    ms = tonumber(ms) or 120
    local baseline = WTM.FrameTime:GetBaseline()
    local kind = WTM.SpikeDetector:Classify(ms, baseline)
    if not kind then
        out(("%.0f ms would not classify as a spike against the current baseline of %.1f ms. Try a larger value.")
            :format(ms, baseline))
        return nil
    end

    local suppressed = WTM.Suppression:Check()
    if suppressed then
        out(("Note: spikes are currently suppressed (%s). Injecting anyway so the path can be tested.")
            :format(C.SUPPRESSION_REASONS[suppressed] or suppressed))
    end

    local spike = WTM.SpikeDetector:Record(kind, ms, GetTime(), baseline, true)
    out(("Injected %s |cffd29922SIMULATED|r spike: %.0f ms (baseline %.1f ms)%s")
        :format(spike.label, ms, baseline,
                spike.clusterId and (", cluster #" .. spike.clusterId) or ""))
    return spike
end

--- Marks a synthetic latency spike on the timeline.
---
--- GetNetStats is read-only, so this cannot change the reported latency. What
--- it does is exercise the marker and timeline path with a clearly labelled
--- entry.
function Dev:InjectLatencySpike(ms)
    ms = tonumber(ms) or 400
    WTM.Context:AddMarker("netspike", ("SIMULATED world latency %d ms"):format(ms))
    WTM.Network.session.spikes = WTM.Network.session.spikes + 1
    out(("Marked a |cffd29922SIMULATED|r latency spike of %d ms. The real GetNetStats reading is unchanged - it is read-only.")
        :format(ms))
end

--- Fires a burst of a real event so the storm detector sees a genuine storm.
---
--- The events really are fired, on a private frame, so what the detector reacts
--- to is real event traffic rather than a doctored counter.
function Dev:InjectEventStorm(event, count)
    event = event or "UNIT_AURA"
    count = tonumber(count) or 500

    if WTM.Events:GetMode() == "OFF" then
        out("Event monitoring is OFF, so nothing would observe the storm. Set it to NORMAL or DETAILED first.")
        return
    end

    -- There is no API to make the client fire events on demand, so the counter
    -- is fed directly. Any storm this produces is flagged simulated.
    local injected = WTM.Events:InjectForTesting(event, count)
    if not injected then
        out("Event injection is unavailable in this build.")
        return
    end
    WTM.Context:AddMarker("eventstorm", ("SIMULATED %s x%d"):format(event, count))
    out(("Injected |cffd29922SIMULATED|r %d x %s. The storm detector will react on its next sample.")
        :format(count, event))
end

--- Grows a table this addon owns, so the Lua heap really does rise.
---
--- The growth is genuine memory, held by this addon and attributed to it by
--- GetAddOnMemoryUsage - it is not a doctored number. `/wtm dev freemem`
--- releases it again.
function Dev:SimulateMemoryGrowth(megabytes)
    megabytes = tonumber(megabytes) or 5
    self.ballast = self.ballast or {}
    local before = collectgarbage("count")
    -- Roughly 1 KB per string; close enough for a visible, reversible bump.
    local target = megabytes * 1024
    for i = 1, target do
        self.ballast[#self.ballast + 1] = string.rep("x", 1000)
    end
    local after = collectgarbage("count")
    out(("Allocated %s of |cffd29922SIMULATED|r ballast held by this addon (heap %s -> %s). Release it with |cff4c8dff/wtm dev freemem|r.")
        :format(Fmt.Memory(after - before), Fmt.Memory(before), Fmt.Memory(after)))
end

function Dev:FreeMemory()
    if not self.ballast then
        out("No ballast allocated.")
        return
    end
    local before = collectgarbage("count")
    self.ballast = nil
    -- Deliberately NOT calling collectgarbage("collect"): forcing a collect is
    -- the exact kind of hitch this addon exists to find. The heap will fall on
    -- its own, and watching it fall is itself a useful demonstration.
    out(("Ballast released (heap was %s). No collection is being forced - watch the Memory page for the decrease.")
        :format(Fmt.Memory(before)))
end

--------------------------------------------------------------------------
-- Dumps
--------------------------------------------------------------------------

function Dev:DumpCapabilities()
    WTM.Caps:PrintReport()
end

function Dev:DumpScheduler()
    header("scheduler")
    out(("running=%s  bursting=%s  throttle=%d")
        :format(tostring(WTM.Scheduler:IsRunning()),
                tostring(WTM.Scheduler:IsBursting()),
                WTM.Scheduler.cost.throttleLevel))
    for _, task in WTM.Scheduler:IterateTasks() do
        local stats = WTM.Scheduler.cost.perTask[task.name]
        out(("  %-16s %-8s every %.2fs  calls=%-6d avg=%.3fms max=%.3fms %s")
            :format(task.name, task.category or "-", task.normal,
                    stats and stats.calls or 0,
                    stats and stats.avgMs or 0,
                    stats and stats.maxMs or 0,
                    task.enabled and "" or "|cfff0533fDISABLED|r"))
    end
end

function Dev:DumpRings()
    header("ring buffers")
    local recorder = WTM.FlightRecorder
    if recorder.ring then
        out(("flight recorder: %d/%d slots used, %s of coverage, seq=%d, %d pending captures")
            :format(recorder.ring.count, recorder.ring.size,
                    Fmt.Duration(recorder:GetCoverageSeconds()),
                    recorder.ring.seq, recorder:PendingCount()))
        out(("  target window: %ds pre + %ds post (+ %ds reserve)")
            :format(WTM.db.profile.flightRecorder.preWindow,
                    WTM.db.profile.flightRecorder.postWindow, C.FR_RESERVE_SEC))
        out(("  incidents in memory: %d"):format(#recorder.incidents))
    else
        out("flight recorder: no ring allocated")
    end

    out(("history: %d buckets across %d tiers, %s of coverage")
        :format(WTM.Recorder:CountBuckets(), #WTM.Recorder.tiers,
                Fmt.Duration(WTM.Recorder:GetCoverage())))
    for i, tier in ipairs(WTM.Recorder.tiers) do
        out(("  tier %d: %ds resolution, %d/%d buckets")
            :format(i, tier.resolution, #tier.buckets, tier.capacity))
    end

    out(("frame time history: %d/%d, events: %d/%d, memory: %d/%d")
        :format(WTM.FrameTime.history.fps.count, WTM.FrameTime.history.fps.size,
                WTM.Events.history.count, WTM.Events.history.size,
                WTM.Memory.history.lua.count, WTM.Memory.history.lua.size))
end

function Dev:DumpIncident(id)
    local incident
    if id then
        incident = WTM.FlightRecorder:GetIncident(tonumber(id))
    else
        incident = WTM.FlightRecorder.incidents[#WTM.FlightRecorder.incidents]
    end
    if not incident then
        out("No incident recorded yet. Try |cff4c8dff/wtm dev spike 200|r.")
        return
    end

    header(("incident #%d%s"):format(incident.id, incident.simulated and " (SIMULATED)" or ""))
    out(WTM.FlightRecorder:DescribeCoverage(incident))
    if incident.spike then
        for line in WTM.SpikeDetector:Describe(incident.spike):gmatch("[^\n]+") do
            out("  " .. line)
        end
    end
    out(("  context: %s"):format(WTM.Context:Describe()))
    local shown = math.min(8, #incident.samples)
    out(("  first %d of %d samples (t relative to the spike):"):format(shown, #incident.samples))
    for i = 1, shown do
        local sample = incident.samples[i]
        out(("    %+6.2fs  fps %-6.1f frame %-7.1f events %-6.0f lua %s")
            :format(sample.t, sample.fps, sample.frameMaxMs, sample.events,
                    Fmt.Memory(sample.luaKB)))
    end
end

function Dev:DumpSuppression()
    header("suppression")
    local status, tone = WTM.Suppression:Status()
    out(status)
    local described = WTM.Suppression:Describe()
    out(described or "Nothing has been suppressed this session.")
end

--------------------------------------------------------------------------
-- Benchmark
--------------------------------------------------------------------------
-- Measures what THIS addon costs. It does not generate load, stall the client
-- or fabricate a scenario - it reads the same measured figures the overhead
-- module already collects and presents them together.

function Dev:Benchmark(seconds)
    seconds = tonumber(seconds) or 10
    if seconds < 3 then seconds = 3 end
    if seconds > 60 then seconds = 60 end

    out(("Measuring this addon's own overhead for %d seconds. No artificial load is generated; the game is untouched.")
        :format(seconds))

    WTM.Scheduler:ResetCost()
    WTM.UI.MainWindow:ResetRedrawStats()
    self.benchmarkStart = GetTime()
    self.benchmarkFrames = WTM.FrameTime:GetSessionStats().frames

    self.benchmarkTimer = WTM.Scheduler:Register("devbenchmark", function()
        Dev:FinishBenchmark()
    end, seconds, seconds, 0, "sampler")
end

function Dev:FinishBenchmark()
    WTM.Scheduler:SetEnabled("devbenchmark", false)

    local elapsed = GetTime() - (self.benchmarkStart or GetTime())
    local frames = WTM.FrameTime:GetSessionStats().frames - (self.benchmarkFrames or 0)
    local cur = WTM.Overhead.current

    header(("benchmark: %.1f s, %d frames"):format(elapsed, frames))

    for _, row in ipairs(WTM.Overhead:GetBreakdown()) do
        if row.measured then
            out(("  %-18s %6.3f ms/s   |cff5d6675%s|r"):format(row.label, row.ms, row.note))
        else
            out(("  %-18s %6s        |cff5d6675%s|r"):format(row.label, "n/a", row.note))
        end
    end

    local sum, total, delta = WTM.Overhead:ReconcileBreakdown()
    out(("  %-18s %6.3f ms/s   |cff5d6675categories sum to %.3f|r")
        :format("TOTAL MEASURED", total, sum))
    out(("  %-18s %6.3f ms/s   |cff5d6675measured total minus the categories - work inside the timed window that no category claims|r")
        :format("unattributed", delta))

    ------------------------------------------------------------------
    -- Per sampler: what it costs on an average call and on its worst one.
    ------------------------------------------------------------------
    header("per sampling task")
    local anyTask = false
    for name, stats in pairs(WTM.Scheduler.cost.perTask) do
        if stats.calls > 0 then
            anyTask = true
            out(("  %-16s %5d calls   avg %6.3f ms   peak %6.3f ms   total %7.2f ms")
                :format(name, stats.calls, stats.avgMs, stats.maxMs, stats.totalMs))
        end
    end
    if not anyTask then out("  nothing ran inside the window") end

    out(("  %-16s %d task%s came due on one tick, worst lateness %.0f ms")
        :format("scheduling", WTM.Scheduler.cost.maxBacklog,
                WTM.Scheduler.cost.maxBacklog == 1 and "" or "s",
                WTM.Scheduler.cost.maxLateSec * 1000))

    ------------------------------------------------------------------
    -- Graph redraws, which is the single most expensive thing here.
    ------------------------------------------------------------------
    header("graph redraws")
    local r = WTM.UI.MainWindow.redrawStats
    if r.draws > 0 then
        out(("  %-16s %d in %.1f s  =  %.2f/s")
            :format("redraws", r.draws, elapsed, r.draws / math.max(elapsed, 0.001)))
        out(("  %-16s avg %6.3f ms   peak %6.3f ms   total %7.2f ms")
            :format("cost", r.totalMs / r.draws, r.maxMs, r.totalMs))
    else
        out("  none - the window was closed, or no graph had new data")
    end
    out(("  %-16s %d   |cff5d6675redraws the round-robin budget refused this window; they happen on a later pass, they are not lost|r")
        :format("deferred", r.deferred))
    out(("  %-16s %d"):format("budget passes", r.passes))
    out(("  %-18s %6.3f %%  of the frame budget at the current %s FPS")
        :format("frame budget", WTM.Overhead:GetFrameBudgetPercent(),
                Fmt.FPS(WTM.FrameTime.current.fps)))

    if cur.frameCostMs then
        out(("  per-frame callback: %.4f ms, averaged over %d timed frames")
            :format(cur.frameCostMs, WTM.Scheduler:GetFrameCallbackSamples()))
    else
        out("  per-frame callback: not sampled yet")
    end

    out(("  own memory: %s   own CPU: %s")
        :format(Fmt.Memory(cur.memKB),
                WTM.CPU.available and ("%.2f%%"):format(cur.cpuPct) or "n/a (profiling off)"))

    out(("  event monitoring mode: %s"):format(WTM.Events:GetMode()))
    if WTM.CPU.available then
        out("  |cffd29922Note:|r the client's scriptProfile CVar is ON. It has a cost of its own which this addon cannot measure and is not responsible for.")
    end

    local warning = WTM.Overhead:GetWarning()
    if warning then out("  |cffd29922" .. warning .. "|r") end
end

--------------------------------------------------------------------------
-- Command dispatch
--------------------------------------------------------------------------

local commands
commands = {
    on = function()
        WTM.db.profile.dev.enabled = true
        out("Dev mode on. Injected data is always marked SIMULATED.")
        commands.help()
    end,
    off = function()
        WTM.db.profile.dev.enabled = false
        out("Dev mode off.")
    end,
    spike     = function(arg) Dev:InjectFrameSpike(arg) end,
    latency   = function(arg) Dev:InjectLatencySpike(arg) end,
    storm     = function(arg, arg2) Dev:InjectEventStorm(arg2 or "UNIT_AURA", arg) end,
    memory    = function(arg) Dev:SimulateMemoryGrowth(arg) end,
    freemem   = function() Dev:FreeMemory() end,
    caps      = function() Dev:DumpCapabilities() end,
    scheduler = function() Dev:DumpScheduler() end,
    rings     = function() Dev:DumpRings() end,
    incident  = function(arg) Dev:DumpIncident(arg) end,
    suppress  = function() Dev:DumpSuppression() end,
    help = function()
        out("Commands:")
        out("  |cff4c8dff/wtm dev spike [ms]|r        inject a simulated frame spike (default 120)")
        out("  |cff4c8dff/wtm dev latency [ms]|r      mark a simulated latency spike")
        out("  |cff4c8dff/wtm dev storm [n] [event]|r inject a simulated event storm")
        out("  |cff4c8dff/wtm dev memory [mb]|r       allocate real ballast held by this addon")
        out("  |cff4c8dff/wtm dev freemem|r           release the ballast")
        out("  |cff4c8dff/wtm dev caps|r              dump the capability matrix")
        out("  |cff4c8dff/wtm dev scheduler|r         dump every sampling task and its cost")
        out("  |cff4c8dff/wtm dev rings|r             dump ring buffer and history state")
        out("  |cff4c8dff/wtm dev incident [id]|r     dump an incident (default: the newest)")
        out("  |cff4c8dff/wtm dev suppress|r          dump suppression state")
        out("  |cff4c8dff/wtm dev off|r               leave dev mode")
        out("|cff5d6675Everything injected is recorded with simulated = true and shown as SIMULATED.|r")
    end,
}

--------------------------------------------------------------------------
-- Catalogue, for the Advanced section of the Settings page
--------------------------------------------------------------------------
--
-- Same idea as WTM.COMMANDS: the buttons and `/wtm dev help` describe one list.
-- `destructive` marks the entries that change measured state rather than only
-- printing something, so the UI can ask before running them.
local SUBCOMMANDS = {
    { cmd = "spike",     label = "Inject frame spike",   destructive = true,
      help = "inject a simulated frame spike - recorded and shown as SIMULATED" },
    { cmd = "latency",   label = "Inject latency spike", destructive = true,
      help = "mark a simulated latency spike" },
    { cmd = "storm",     label = "Inject event storm",   destructive = true,
      help = "inject a simulated event storm" },
    { cmd = "memory",    label = "Allocate ballast",     destructive = true,
      help = "allocate real memory held by this addon, to make growth visible" },
    { cmd = "freemem",   label = "Release ballast",
      help = "release the memory allocated above" },
    { cmd = "caps",      label = "Dump capabilities",
      help = "print the full capability matrix" },
    { cmd = "scheduler", label = "Dump scheduler",
      help = "print every sampling task and its measured cost" },
    { cmd = "rings",     label = "Dump ring buffers",
      help = "print ring buffer and history state" },
    { cmd = "incident",  label = "Dump newest incident",
      help = "print the most recent incident in full" },
    { cmd = "suppress",  label = "Dump suppression",
      help = "print why spikes are currently being suppressed" },
}

Dev.SUBCOMMANDS = SUBCOMMANDS

--- Runs one catalogued dev subcommand. Returns false with a reason when dev
--- mode is off, so a button can say why rather than doing nothing.
function Dev:RunSubcommand(name)
    if not WTM.db.profile.dev.enabled then
        return false, "Dev mode is off."
    end
    local handler = commands[name]
    if not handler then return false, ("Unknown dev command '%s'."):format(tostring(name)) end
    handler()
    return true
end

function Dev:IsEnabled()
    return WTM.db.profile.dev.enabled and true or false
end

function Dev:SetEnabled(enabled)
    if enabled then commands.on() else commands.off() end
    return self:IsEnabled()
end

function Dev:HandleCommand(input)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        if not WTM.db.profile.dev.enabled then
            commands.on()
        else
            commands.help()
        end
        return
    end

    local handler = commands[cmd]
    if not handler then
        out(("Unknown dev command '%s'."):format(cmd))
        commands.help()
        return
    end

    if cmd ~= "on" and cmd ~= "off" and cmd ~= "help" and not WTM.db.profile.dev.enabled then
        out("Dev mode is off. Enable it with |cff4c8dff/wtm dev on|r.")
        return
    end

    local first, second = rest:match("^(%S*)%s*(%S*)$")
    handler(first ~= "" and first or nil, second ~= "" and second or nil)
end
