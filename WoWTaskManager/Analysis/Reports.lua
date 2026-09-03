--[[--------------------------------------------------------------------------
    WoW Task Manager - Analysis/Reports.lua

    Text reports, for pasting into a bug tracker.

    WoW gives addons no clipboard access whatsoever - there is no way to write
    to it and no way to read it. So "copy" here means "put the text somewhere
    you can select it", and every function in this file produces a plain string
    for that purpose.

    Two rules the formats follow:

      * Every figure names its units and, where it is a cumulative counter,
        the window it was measured over. A bug report that says "CPU 31" is
        worse than one that says nothing.
      * Nothing is asserted about cause. Where an error and a stutter overlap,
        the report says they overlapped.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C   = WTM.C
local Fmt = WTM.Format

local Reports = {}
WTM.Reports = Reports

--------------------------------------------------------------------------

local function line(out, format, ...)
    if select("#", ...) > 0 then
        out[#out + 1] = format:format(...)
    else
        out[#out + 1] = format
    end
end

local function header(out, title)
    line(out, "")
    line(out, title)
    line(out, ("-"):rep(#title))
end

--- Client, addon version and session, on every report. A report without them
--- is a report nobody can act on.
local function Preamble(out)
    line(out, "WoW Task Manager Error Report")
    line(out, "Addon version:  %s", C.VERSION)
    line(out, "Client:         %s %s (build %s)",
        WTM.Compat.flavorName or "?", WTM.Compat.version or "?",
        WTM.Compat.build or "?")
    line(out, "Locale:         %s", GetLocale() or "?")
    line(out, "Timestamp:      %s", Fmt.DateTime(time()))
    line(out, "Session:        #%s, running %s",
        WTM.Sessions.current and WTM.Sessions.current.id or "?",
        Fmt.Duration(GetTime() - (WTM.state.sessionStart or GetTime())))
end

local function ContextBlock(out, context)
    if not context then
        line(out, "Context:        not captured")
        return
    end
    line(out, "FPS:            %s", Fmt.FPS(context.fps or 0))
    line(out, "Frame time:     %s", Fmt.Ms(context.frameMs or 0))
    if context.latencyWorld then
        line(out, "Latency:        %d ms world, %d ms home (client refreshes it about every 30 s)",
            context.latencyWorld, context.latencyHome or 0)
    else
        line(out, "Latency:        not measurable on this client")
    end
    line(out, "Lua memory:     %s", Fmt.Memory(context.luaKB or 0))
    if context.cpuPct then
        -- Cumulative counter: the window is part of the number, not a detail.
        line(out, "Addon CPU:      %.2f %% measured over a %.2f s observation window",
            context.cpuPct, context.cpuWindowSec or 0)
    else
        line(out, "Addon CPU:      unavailable (the scriptProfile CVar is off)")
    end
    line(out, "Events/sec:     %s",
        context.eventsPerSec and Fmt.Rate(context.eventsPerSec) or "not counted")
    line(out, "WTM overhead:   %.3f ms/s", context.overheadMsPerSec or 0)
    line(out, "Zone:           %s", context.zone or "unknown")
    line(out, "Instance:       %s", context.instanceType or "none")
    line(out, "Combat:         %s", context.combat and "yes" or "no")
    line(out, "Group size:     %d", context.groupSize or 0)
end

--------------------------------------------------------------------------
-- One error
--------------------------------------------------------------------------

function Reports:Error(group)
    if not group then return "No error selected." end
    local out = {}
    Preamble(out)

    header(out, "Error")
    line(out, "Addon:          %s", group.addon
        or "Unknown (no addon path in the message)")
    line(out, "File:           %s", group.file or "unknown")
    line(out, "Line:           %s", tostring(group.line or "unknown"))
    line(out, "Occurrences:    %d", group.count or 1)
    line(out, "First seen:     %s", Fmt.DateTime(group.firstEpoch or 0))
    line(out, "Last seen:      %s", Fmt.DateTime(group.lastEpoch or 0))
    if group.internal then
        line(out, "NOTE:           raised by WoW Task Manager itself")
    end
    line(out, "")
    line(out, "%s", group.message or "")

    header(out, "Context when first seen")
    ContextBlock(out, group.context)

    local incidents = WTM.Errors:RelatedIncidents(group, {})
    if #incidents > 0 then
        header(out, "Overlapping stutter incidents")
        for _, cluster in ipairs(incidents) do
            line(out, "  %s  peak %s over %.2f s, %d frames",
                Fmt.DateTime(cluster.startedEpoch or 0),
                Fmt.Ms(cluster.peakMs or 0),
                cluster.duration or 0, cluster.frames or 0)
        end
        line(out, "%s", C.TXT_ERROR_OVERLAP_NOTE)
    end

    header(out, "Stack")
    line(out, "%s", group.stack or "(no stack captured)")

    return table.concat(out, "\n")
end

--------------------------------------------------------------------------
-- Every error this session
--------------------------------------------------------------------------

function Reports:AllErrors()
    local out = {}
    Preamble(out)

    local stats = WTM.Errors.stats
    header(out, "Summary")
    line(out, "Total errors:   %d", stats.total)
    line(out, "Unique:         %d", stats.unique)
    line(out, "Duplicates:     %d folded into their group", stats.suppressed)
    line(out, "From this addon:%d", stats.internal)
    if stats.droppedByCap > 0 then
        line(out, "Not recorded:   %d new fingerprints refused after the cap was reached",
            stats.droppedByCap)
    end
    local chain, _ = WTM.Errors:DescribeChain()
    line(out, "Handler:        %s", chain)

    header(out, "Errors")
    if #WTM.Errors.groups == 0 then
        line(out, "None recorded.")
    end
    for index, group in ipairs(WTM.Errors.groups) do
        line(out, "")
        line(out, "[%d] %s x%d", index, group.addon or "Unknown", group.count)
        line(out, "    %s", (group.message or ""):gsub("\n", " "))
        line(out, "    first %s, last %s",
            Fmt.DateTime(group.firstEpoch or 0), Fmt.DateTime(group.lastEpoch or 0))
    end

    return table.concat(out, "\n")
end

--------------------------------------------------------------------------
-- The whole session
--------------------------------------------------------------------------

--- The report to attach to a bug report about performance rather than about
--- one error: everything measured, in one paste.
function Reports:Session()
    local out = {}
    Preamble(out)

    local stats = WTM.FrameTime:GetSessionStats()
    local health, score, info = WTM.Diagnostics:ComputeHealth()

    header(out, "Performance")
    line(out, "Health:         %s (%d / 100)", health.text, score)
    line(out, "Average FPS:    %s", Fmt.FPS(stats.avgFPS or 0))
    line(out, "1%% low:         %s", Fmt.FPS(stats.low1 or 0))
    line(out, "0.1%% low:       %s", Fmt.FPS(stats.low01 or 0))
    line(out, "Median frame:   %s", Fmt.Ms(stats.medianMs or 0))
    line(out, "Worst frame:    %s", Fmt.Ms(stats.maxMs or 0))
    line(out, "Frames measured:%s", Fmt.Comma(stats.frames or 0))

    local counts = WTM.SpikeDetector.counts
    header(out, "Incidents")
    line(out, "Spikes:         %d (%d freeze, %d heavy, %d stutter, %d minor)",
        WTM.SpikeDetector.total, counts.freeze or 0, counts.heavy or 0,
        counts.stutter or 0, counts.minor or 0)
    line(out, "Clusters:       %d", #WTM.SpikeDetector.clusters)
    local suppressed = WTM.Suppression:Describe()
    if suppressed then line(out, "Suppressed:     %s", suppressed) end

    header(out, "Lua errors")
    local es = WTM.Errors.stats
    line(out, "Total:          %d in %d distinct errors", es.total, es.unique)
    local worst, worstCount = WTM.Errors:WorstAddon()
    if worst then
        line(out, "Most errors:    %s (%d)", worst, worstCount)
    end
    if #WTM.Errors.storms > 0 then
        line(out, "Error storms:   %d", #WTM.Errors.storms)
    end

    header(out, "Addon CPU")
    if WTM.CPU.available then
        line(out, "Total now:      %.2f %% of one core", WTM.CPU.current.totalPct or 0)
        local top = WTM.CPU:GetTopConsumers({}, 8)
        for i, entry in ipairs(top) do
            line(out, "  %d. %-28s %.2f %%", i, entry.title or entry.name, entry.pct)
        end
        line(out, "%s", C.TXT_CPU_WINDOW_NOTE)
    else
        line(out, "Unavailable:    %s", WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
    end

    header(out, "Memory")
    local mem = WTM.Memory.current
    line(out, "Lua heap:       %s now, %s at login, %s peak",
        Fmt.Memory(mem.luaKB or 0), Fmt.Memory(mem.luaStartKB or 0),
        Fmt.Memory(mem.luaPeakKB or 0))
    line(out, "Observed heap decreases: %d", WTM.Memory.heapDrops.events or 0)
    line(out, "(WoW reports no collection statistics; that is the heap curve, not a collection count.)")

    header(out, "Events")
    if WTM.Events.available and WTM.Events:GetMode() ~= "OFF" then
        line(out, "Rate:           %s now, %s peak",
            Fmt.Rate(WTM.Events.current.perSecond or 0),
            Fmt.Rate(WTM.Events.current.peakPerSecond or 0))
        line(out, "Distinct:       %d", WTM.Events:GetDistinctCount())
        line(out, "Storms:         %d", #WTM.Events.storms)
    else
        line(out, "Event monitoring is off.")
    end

    header(out, "Network")
    if WTM.Caps:Has("latency") then
        local s = WTM.Network.session
        line(out, "World latency:  %d ms now, %d ms peak",
            WTM.Network.current.latencyWorld or 0, s.peakWorld or 0)
        line(out, "Latency spikes: %d", s.spikes or 0)
    else
        line(out, "Unavailable:    %s", WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT)
    end

    header(out, "This addon's own cost")
    for _, row in ipairs(WTM.Overhead:GetBreakdown({})) do
        line(out, "  %-26s %s", row.label,
            row.measured and ("%.3f ms/s"):format(row.ms) or "not measured")
    end
    local sum, total, delta = WTM.Overhead:ReconcileBreakdown()
    line(out, "  %-26s %.3f ms/s (categories sum to %.3f, difference %.3f)",
        "TOTAL MEASURED", total, sum, delta)

    header(out, "Capabilities")
    for _, entry in ipairs(WTM.Caps:GetHeadlineReport({})) do
        line(out, "  %-22s %s", entry.label, entry.state)
    end

    header(out, "Observations")
    for _, entry in ipairs(WTM.Observations:Build({})) do
        line(out, "  - %s", entry.title)
        if entry.detail and entry.detail ~= "" then
            line(out, "      %s", (entry.detail:gsub("\n", " ")))
        end
    end

    line(out, "")
    line(out, "Everything above is measured. Where two things are reported together, they occurred together - this addon does not decide what caused what.")

    return table.concat(out, "\n")
end

--------------------------------------------------------------------------
-- A user-marked moment
--------------------------------------------------------------------------

--- "It happened here." A snapshot taken when the user says something went
--- wrong, which is often the only way to line a complaint up with the data.
function Reports:Moment(note)
    local out = {}
    Preamble(out)

    header(out, "Reported problem")
    line(out, "Note:           %s", note and note ~= "" and note or "(none given)")

    header(out, "At this moment")
    ContextBlock(out, {
        fps = WTM.FrameTime.current.fps,
        frameMs = WTM.FrameTime.current.avgMs,
        latencyWorld = WTM.Caps:Has("latency") and WTM.Network.current.latencyWorld or nil,
        latencyHome = WTM.Caps:Has("latency") and WTM.Network.current.latencyHome or nil,
        luaKB = WTM.Memory.current.luaKB,
        cpuPct = WTM.CPU.available and WTM.CPU.current.totalPct or nil,
        cpuWindowSec = WTM.CPU.available and WTM.CPU.current.sampleWindowSec or nil,
        eventsPerSec = WTM.Events.available and WTM.Events.current.perSecond or nil,
        overheadMsPerSec = WTM.Overhead.current.totalMsPerSec,
        zone = WTM.Context.state.zone,
        instanceType = WTM.Context.state.instanceType,
        combat = WTM.Context.state.combat,
        groupSize = WTM.Context.state.groupSize,
    })

    header(out, "Recent incidents")
    local clusters = WTM.SpikeDetector.clusters
    if #clusters == 0 then line(out, "None.") end
    for i = #clusters, math.max(1, #clusters - 4), -1 do
        local cluster = clusters[i]
        line(out, "  %s  peak %s, %d frames over %.2f s",
            Fmt.DateTime(cluster.startedEpoch or 0), Fmt.Ms(cluster.peakMs or 0),
            cluster.frames or 0, cluster.duration or 0)
    end

    header(out, "Recent Lua errors")
    local groups = WTM.Errors.groups
    if #groups == 0 then line(out, "None.") end
    for i = #groups, math.max(1, #groups - 4), -1 do
        local group = groups[i]
        line(out, "  %s x%d  %s", group.addon or "Unknown", group.count,
            (group.message or ""):gsub("\n", " "):sub(1, 120))
    end

    header(out, "Addon CPU at this moment")
    if WTM.CPU.available then
        for i, entry in ipairs(WTM.CPU:GetTopConsumers({}, 5)) do
            line(out, "  %d. %-28s %.2f %%", i, entry.title or entry.name, entry.pct)
        end
        line(out, "%s", C.TXT_CPU_WINDOW_NOTE)
    else
        line(out, "Unavailable: %s", WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
    end

    return table.concat(out, "\n")
end
