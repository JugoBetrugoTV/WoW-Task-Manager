--[[--------------------------------------------------------------------------
    WoW Task Manager - Analysis/Diagnostics.lua

    Turns the session's raw numbers into a readable verdict.

    Every finding carries the evidence it was derived from, and findings that
    rest on an unavailable measurement say so rather than being silently
    omitted - "we could not measure this" is itself a useful diagnosis.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat

local Diagnostics = {}
WTM.Diagnostics = Diagnostics

--------------------------------------------------------------------------
-- Result cache
--------------------------------------------------------------------------
-- Build() runs the whole analysis: correlation, event correlation, memory
-- ranking, overhead.  The sidebar wants a finding count on every UI refresh,
-- which is twice a second - so the result is cached for a short window and
-- reused by every caller.

local CACHE_TTL = 2.0
local cache = { entries = {}, at = -1, spikeCount = -1 }

function Diagnostics:InvalidateCache()
    cache.at = -1
end

--------------------------------------------------------------------------
-- Health
--------------------------------------------------------------------------

function Diagnostics:ComputeHealth()
    local counts = WTM.SpikeDetector.counts
    local stats  = WTM.FrameTime:GetSessionStats()
    local duration = math.max(1, GetTime() - (WTM.state.sessionStart or GetTime()))
    local minutes = duration / 60

    local score = 100

    -- Spikes, weighted by severity and normalised per minute so a long session
    -- is not penalised for simply being long.
    local perMinute = (counts.freeze * 8 + counts.heavy * 4 + counts.stutter * 2 + counts.minor * 0.5) / minutes
    score = score - math.min(60, perMinute * 12)

    -- How far the 1% low sits below the average is a better stability signal
    -- than either number alone.
    if stats.avgFPS > 0 and stats.low1 > 0 then
        local ratio = stats.low1 / stats.avgFPS
        if ratio < 0.5 then score = score - 25
        elseif ratio < 0.7 then score = score - 12 end
    end

    if WTM.Network.session.spikes > 0 then
        score = score - math.min(15, WTM.Network.session.spikes * 3)
    end

    score = math.max(0, math.min(100, score))

    local health = C.HEALTH.CRITICAL
    for _, band in ipairs(C.HEALTH_BANDS) do
        if score >= band.min then health = band break end
    end

    -- The single thing most worth looking at, so a summary panel can lead with
    -- it instead of making the reader work the numbers out.
    local headline
    if counts.freeze > 0 then
        headline = ("%d freeze%s recorded"):format(counts.freeze,
            counts.freeze == 1 and "" or "s")
    elseif counts.heavy > 0 then
        headline = ("%d heavy stutter"):format(counts.heavy)
    elseif stats.avgFPS > 0 and stats.low1 > 0 and (stats.low1 / stats.avgFPS) < 0.6 then
        headline = "the worst 1% of frames are far below average"
    elseif WTM.Network.session.spikes > 0 then
        headline = ("%d latency spike%s"):format(WTM.Network.session.spikes,
            WTM.Network.session.spikes == 1 and "" or "s")
    elseif WTM.SpikeDetector.total > 0 then
        headline = "minor spikes only"
    else
        headline = "nothing above the thresholds"
    end

    return health, score, {
        spikesPerMinute = perMinute,
        avgFPS = stats.avgFPS,
        low1   = stats.low1,
        duration = duration,
        headline = headline,
    }
end

--------------------------------------------------------------------------
-- Findings
--------------------------------------------------------------------------

--- The categories a finding can belong to. Grouping them lets the page show
--- "what is the state of each area" as well as a flat list, which is the
--- difference between a log and a diagnosis.
Diagnostics.CATEGORIES = {
    { key = "pacing",   label = "Frame pacing" },
    { key = "cpu",      label = "Addon CPU" },
    { key = "memory",   label = "Memory" },
    { key = "events",   label = "Events" },
    { key = "latency",  label = "Latency" },
    { key = "overhead", label = "This addon" },
    { key = "other",    label = "Other" },
}

--- How much weight a finding carries.
---
---   measured   a direct reading; the number is what it says it is
---   derived    computed from several readings, still arithmetic
---   heuristic  rests on the frame-name attribution guess, or on an
---              association across samples rather than a measurement
---
--- This is NOT a probability, and it is not a claim about whether the finding
--- matters. It says what kind of evidence is underneath it.
Diagnostics.CONFIDENCE = {
    measured  = { label = "measured",  order = 3 },
    derived   = { label = "derived",   order = 2 },
    heuristic = { label = "heuristic", order = 1 },
}

local function AddFinding(out, tone, title, detail, evidence, category, confidence)
    out[#out + 1] = {
        tone = tone, title = title, detail = detail, evidence = evidence,
        category = category or "other",
        confidence = confidence or "derived",
    }
end

function Diagnostics:Build(out)
    local now = GetTime()
    if cache.at >= 0 and (now - cache.at) < CACHE_TTL
       and cache.spikeCount == WTM.SpikeDetector.total
       and cache.aggressiveness == WTM.db.profile.diagnostics.aggressiveness then
        if out and out ~= cache.entries then
            for i = #out, 1, -1 do out[i] = nil end
            for i = 1, #cache.entries do out[i] = cache.entries[i] end
            return out
        end
        return cache.entries
    end

    cache.at = now
    cache.spikeCount = WTM.SpikeDetector.total
    cache.aggressiveness = WTM.db.profile.diagnostics.aggressiveness
    self:Compute(cache.entries)

    if out and out ~= cache.entries then
        for i = #out, 1, -1 do out[i] = nil end
        for i = 1, #cache.entries do out[i] = cache.entries[i] end
        return out
    end
    return cache.entries
end

--- The actual analysis.  Always writes into `out`.
local errorAddonScratch = {}

function Diagnostics:Compute(out)
    for i = #out, 1, -1 do out[i] = nil end

    local Fmt = WTM.Format
    local counts = WTM.SpikeDetector.counts
    local total = WTM.SpikeDetector.total

    ------------------------------------------------------------------
    -- Frame time
    ------------------------------------------------------------------
    if total == 0 then
        AddFinding(out, "ok", "No frame time spikes detected",
            ("Frame times stayed within the configured thresholds for %s.")
                :format(Fmt.Duration(GetTime() - (WTM.state.sessionStart or GetTime()))), nil, "pacing", "measured")
    else
        local parts = {}
        for _, kind in ipairs({ "freeze", "heavy", "stutter", "minor" }) do
            if (counts[kind] or 0) > 0 then
                parts[#parts + 1] = ("%d %s"):format(counts[kind], C.SPIKE_DEFAULTS[kind].label:lower())
            end
        end
        AddFinding(out, counts.freeze > 0 and "crit" or "warn",
            ("%d frame time spikes detected"):format(total),
            table.concat(parts, ", "), nil, "pacing", "measured")
    end

    local suppressed = WTM.Suppression:Describe()
    if suppressed then
        AddFinding(out, "muted", "Some frame spikes were not reported", suppressed ..
            "\nThese happen during loading screens, the first seconds after login, a UI reload or a zone change - the client doing what it is supposed to do. They are counted but not treated as stutter.", nil, "pacing", "measured")
    end

    local stats = WTM.FrameTime:GetSessionStats()
    if stats.avgFPS > 0 and stats.low1 > 0 and (stats.low1 / stats.avgFPS) < 0.6 then
        AddFinding(out, "warn", "Frame pacing is uneven",
            ("Average %s FPS but the worst 1%% of frames ran at %s FPS. The gap between those two numbers is what a stutter feels like.")
                :format(Fmt.FPS(stats.avgFPS), Fmt.FPS(stats.low1)), nil, "pacing", "derived")
    end

    ------------------------------------------------------------------
    -- CPU correlation
    ------------------------------------------------------------------
    if not WTM.CPU.available then
        AddFinding(out, "muted", "Addon CPU was not measured",
            "The client's scriptProfile CVar is off, so per-addon CPU time is unavailable for this session. Nothing here can attribute a spike to an addon's CPU use.",
            { action = "enableProfiling" }, "cpu", "measured")
    else
        local correlations, spikeSamples = WTM.Correlation:Analyze()
        if spikeSamples >= C.CORRELATION_MIN_SAMPLES and #correlations > 0 then
            -- Aggressiveness changes WHAT IS SHOWN, never how it is measured or
            -- how strongly it is worded. An association reads identically at
            -- every setting; only the bar for mentioning it moves.
            local aggressiveness = WTM.db.profile.diagnostics.aggressiveness
            local threshold = 0.30
            local limit = 3
            if aggressiveness == "conservative" then
                threshold, limit = 0.55, 2
            elseif aggressiveness == "aggressive" then
                threshold, limit = 0.15, 5
            end

            for i = 1, math.min(limit, #correlations) do
                local entry = correlations[i]
                if entry.phi >= threshold then
                    AddFinding(out, entry.tone,
                        ("%s: %s"):format(entry.title, entry.label),
                        ("Above its own average CPU in %d of %d spike windows (phi %.2f, peak %+.1f%%). %s")
                            :format(entry.hits, entry.spikes, entry.phi, entry.peakExcess, C.TXT_PHI_NOTE),
                        { addon = entry.name }, "cpu", "heuristic")
                end
            end
        elseif total > 0 then
            AddFinding(out, "muted", "Not enough spikes to correlate",
                ("%d spike%s recorded; at least %d are needed before an association is worth reporting.")
                    :format(spikeSamples, spikeSamples == 1 and "" or "s", C.CORRELATION_MIN_SAMPLES), nil, "cpu", "derived")
        end
    end

    ------------------------------------------------------------------
    -- Event storms
    ------------------------------------------------------------------
    local eventCorrelations, eventSamples = WTM.Correlation:AnalyzeEvents()
    for i = 1, math.min(2, #eventCorrelations) do
        local entry = eventCorrelations[i]
        if entry.share >= 0.4 and eventSamples >= C.CORRELATION_MIN_SAMPLES then
            AddFinding(out, "warn",
                ("%s was busy during %d%% of spikes"):format(entry.event, entry.percent),
                ("Averaging %s during those windows. Frequent events cost CPU across every addon that listens for them.")
                    :format(Fmt.Rate(entry.avgRate)),
                { event = entry.event }, "events", "heuristic")
        end
    end

    local storms = WTM.Events.storms
    if #storms > 0 then
        AddFinding(out, "warn", ("%d event storm%s detected"):format(#storms, #storms == 1 and "" or "s"),
            ("Most recent: %s peaked at %s against a normal rate of %s.")
                :format(storms[#storms].event,
                        Fmt.Rate(storms[#storms].peakRate),
                        Fmt.Rate(storms[#storms].baseline)), nil, "events", "measured")
    end

    ------------------------------------------------------------------
    -- Memory
    ------------------------------------------------------------------
    local growth = WTM.Memory:GetGrowthRanking(nil, 5)
    local sustained = {}
    for i = 1, #growth do
        if growth[i].sustained then sustained[#sustained + 1] = growth[i] end
    end
    if #sustained > 0 then
        local lines = {}
        for i = 1, math.min(3, #sustained) do
            lines[#lines + 1] = ("%s  %s (%s/min)")
                :format(sustained[i].title, Fmt.MemoryDelta(sustained[i].growthKB),
                        Fmt.Memory(sustained[i].perMinute))
        end
        AddFinding(out, "warn", "Potential sustained memory growth",
            table.concat(lines, "\n") ..
            "\nGrowth is not proof of a leak. Addons legitimately grow while caching data; what matters is whether it ever stops.", nil, "memory", "derived")
    end

    local sessionGrowth = WTM.Memory.current.luaKB - WTM.Memory.current.luaStartKB
    if sessionGrowth > 51200 then   -- 50 MB
        AddFinding(out, "warn", "Lua heap grew notably this session",
            ("%s since login, now at %s. %s")
                :format(Fmt.MemoryDelta(sessionGrowth),
                        Fmt.Memory(WTM.Memory.current.luaKB),
                        WTM.Memory:GetHeapDropSummary()), nil, "memory", "measured")
    end

    ------------------------------------------------------------------
    -- Network
    ------------------------------------------------------------------
    if WTM.Network.session.spikes > 0 then
        AddFinding(out, "warn",
            ("%d world latency spike%s"):format(WTM.Network.session.spikes,
                WTM.Network.session.spikes == 1 and "" or "s"),
            ("Peak world latency %d ms, average %d ms. Latency spikes are server or connection side; no addon can cause or fix them.")
                :format(WTM.Network.session.peakWorld, select(2, WTM.Network:GetAverages())), nil, "latency", "measured")
    end

    ------------------------------------------------------------------
    -- The addon's own cost
    ------------------------------------------------------------------
    local warning, tone = WTM.Overhead:GetWarning()
    if warning then
        AddFinding(out, tone, "This addon's own overhead is elevated", warning, nil, "overhead", "measured")
    end

    ------------------------------------------------------------------
    -- Unattributed spikes
    ------------------------------------------------------------------
    if total > 0 and WTM.CPU.available then
        local unattributed = 0
        local spikes = WTM.SpikeDetector.spikes
        for i = 1, #spikes do
            local spike = spikes[i]
            local found = false
            if spike.cpu then
                for j = 1, #spike.cpu do
                    if spike.cpu[j].excess > WTM.CPU.ELEVATED_MARGIN_PCT then found = true break end
                end
            end
            if not found then unattributed = unattributed + 1 end
        end
        if unattributed > 0 then
            AddFinding(out, "muted",
                ("%d spike%s with no addon above its own average"):format(
                    unattributed, unattributed == 1 and "" or "s"),
                "These are consistent with work outside addon Lua: shader compilation, asset streaming, the game engine itself, or the server. An addon cannot see any of those directly.", nil, "cpu", "measured")
        end
    end

    ------------------------------------------------------------------
    -- Lua errors
    ------------------------------------------------------------------
    -- Every finding below reports a count, a window or an overlap. None of
    -- them says an error caused anything: an error and a stutter arriving
    -- together is a place to look, and the wording never goes past that.
    if WTM.db.profile.errors.includeInDiagnostics and WTM.Caps:Has("errorCapture") then
        local Errors = WTM.Errors
        local storms = Errors.storms

        if #storms > 0 then
            local last = storms[#storms]
            AddFinding(out, "crit",
                ("Lua error storm: %d errors in %d seconds"):format(last.count, last.window),
                ("%d storm%s this session. A storm is many errors from anywhere in a short window, which usually means one broken addon is throwing in a loop or several are reacting to the same event."):format(
                    #storms, #storms == 1 and "" or "s"),
                nil, "other", "measured")
        end

        local repeatThreshold = WTM.db.profile.errors.repeatThreshold
            or C.ERROR_REPEAT_THRESHOLD
        for i = 1, #Errors.groups do
            local group = Errors.groups[i]
            if (group.count or 0) >= repeatThreshold then
                AddFinding(out, group.internal and "crit" or "warn",
                    ("Repeating Lua error: %s x%d"):format(
                        group.addon or "unattributed", group.count),
                    ("%s\n\nRaised at %s:%s. An error inside a frequently called function costs time every time it is raised, and the client's own handler runs on each one."):format(
                        Fmt.Truncate((group.message or ""):gsub("\n", " "), 140),
                        group.file or "?", tostring(group.line or "?")),
                    nil, "other", "measured")
            end
        end

        -- Several distinct errors from one addon is a different signal from one
        -- error repeating: it points at the addon rather than at one function.
        local byAddon = errorAddonScratch
        for key in pairs(byAddon) do byAddon[key] = nil end
        for i = 1, #Errors.groups do
            local addon = Errors.groups[i].addon
            if addon then byAddon[addon] = (byAddon[addon] or 0) + 1 end
        end
        for addon, distinct in pairs(byAddon) do
            if distinct >= C.ERROR_MULTI_THRESHOLD then
                AddFinding(out, "warn",
                    ("%d distinct Lua errors from %s"):format(distinct, addon),
                    "Several different failures in one addon this session. Attribution is from the file path in each error and nothing else.",
                    nil, "other", "measured")
            end
        end

        local overlapping, inCombat = 0, 0
        for i = 1, #Errors.groups do
            local group = Errors.groups[i]
            if Errors:OverlapsSpikes(group) > 0 then overlapping = overlapping + 1 end
            if group.context and group.context.combat then inCombat = inCombat + 1 end
        end

        if overlapping > 0 then
            AddFinding(out, "warn",
                ("%d Lua error%s overlapped a recorded stutter"):format(
                    overlapping, overlapping == 1 and "" or "s"),
                C.TXT_ERROR_OVERLAP_NOTE .. " The Errors page can filter to just these, and each one shows the frame times around it.",
                nil, "pacing", "measured")
        end

        if inCombat > 0 then
            AddFinding(out, "warn",
                ("%d Lua error%s first seen in combat"):format(
                    inCombat, inCombat == 1 and "" or "s"),
                "Errors raised during combat are the ones most likely to be noticed as a stutter, because the client is busiest then. This counts where each error was FIRST seen; repeats are not re-checked.",
                nil, "other", "measured")
        end

        if Errors.stats.internal > 0 then
            AddFinding(out, "crit",
                ("WoW Task Manager raised %d Lua error%s of its own"):format(
                    Errors.stats.internal, Errors.stats.internal == 1 and "" or "s"),
                "These are this addon's own faults and they are never hidden. They are listed on the Errors page like any other, marked as internal, and they belong in a bug report against this addon.",
                nil, "overhead", "measured")
        end

        if Errors.safeMode.active then
            AddFinding(out, "crit",
                "Safe mode is on",
                ("Switched on after repeated internal faults: %s. Recording continues; the analysis module that was faulting is off until /wtm safemode off or the next reload."):format(
                    Errors.safeMode.reason or "reason not recorded"),
                nil, "overhead", "measured")
        end

        if Errors.chaining.displaced then
            AddFinding(out, "muted",
                "Another addon now owns the error handler",
                "An error addon installed its handler after this one, so errors no longer reach here and the Errors page has stopped filling up. Nothing is broken - that addon is handling them - and this addon deliberately does not reinstall itself over it.",
                nil, "other", "measured")
        end

        if Errors.stats.droppedByCap > 0 then
            AddFinding(out, "muted",
                ("%d distinct errors were not recorded in detail"):format(
                    Errors.stats.droppedByCap),
                "The distinct-error cap was reached. Their occurrences are still counted in the total; only the stack and context were not kept. The cap is on the Settings page.",
                nil, "other", "measured")
        end
    end

    return out
end

--------------------------------------------------------------------------
-- Text report
--------------------------------------------------------------------------

--- Plain text summary, printable to chat and usable as a bug report.
function Diagnostics:BuildReport()
    local Fmt = WTM.Format
    local lines = {}
    local health, score = self:ComputeHealth()
    local stats = WTM.FrameTime:GetSessionStats()

    lines[#lines + 1] = ("%s %s  -  session report"):format(C.ADDON_TITLE, C.VERSION)
    lines[#lines + 1] = Compat:GetClientLabel() .. "  |  " .. (GetLocale() or "?")
    lines[#lines + 1] = ("Overall: %s (%d/100)"):format(health.text, score)
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Duration        %s"):format(Fmt.Duration(GetTime() - (WTM.state.sessionStart or GetTime())))
    lines[#lines + 1] = ("Average FPS     %s"):format(Fmt.FPS(stats.avgFPS))
    lines[#lines + 1] = ("1%% low FPS      %s"):format(Fmt.FPS(stats.low1))
    lines[#lines + 1] = ("0.1%% low FPS    %s"):format(Fmt.FPS(stats.low01))
    lines[#lines + 1] = ("Worst frame     %s"):format(Fmt.Ms(stats.maxMs))
    lines[#lines + 1] = ("Spikes          %d (%d freeze, %d heavy, %d stutter, %d minor)")
        :format(WTM.SpikeDetector.total,
                WTM.SpikeDetector.counts.freeze, WTM.SpikeDetector.counts.heavy,
                WTM.SpikeDetector.counts.stutter, WTM.SpikeDetector.counts.minor)
    lines[#lines + 1] = ("Lua memory      %s (started at %s)")
        :format(Fmt.Memory(WTM.Memory.current.luaKB), Fmt.Memory(WTM.Memory.current.luaStartKB))
    lines[#lines + 1] = ("CPU profiling   %s"):format(WTM.CPU.available and "on" or "off")
    lines[#lines + 1] = ""

    local findings = self:Build()
    lines[#lines + 1] = "Findings:"
    if #findings == 0 then
        lines[#lines + 1] = "   nothing notable"
    end
    for i = 1, #findings do
        lines[#lines + 1] = ("   - %s"):format(findings[i].title)
        if findings[i].detail then
            for line in tostring(findings[i].detail):gmatch("[^\n]+") do
                lines[#lines + 1] = ("       %s"):format(line)
            end
        end
    end

    return table.concat(lines, "\n")
end

function Diagnostics:PrintReport()
    for line in self:BuildReport():gmatch("[^\n]+") do
        DEFAULT_CHAT_FRAME:AddMessage(line)
    end
end
