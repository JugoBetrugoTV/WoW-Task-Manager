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

    local health
    if score >= 75 then health = C.HEALTH.GOOD
    elseif score >= 45 then health = C.HEALTH.WARNING
    else health = C.HEALTH.CRITICAL end

    return health, score, {
        spikesPerMinute = perMinute,
        avgFPS = stats.avgFPS,
        low1   = stats.low1,
        duration = duration,
    }
end

--------------------------------------------------------------------------
-- Findings
--------------------------------------------------------------------------

local function AddFinding(out, tone, title, detail, evidence)
    out[#out + 1] = { tone = tone, title = title, detail = detail, evidence = evidence }
end

function Diagnostics:Build(out)
    local now = GetTime()
    if cache.at >= 0 and (now - cache.at) < CACHE_TTL
       and cache.spikeCount == WTM.SpikeDetector.total then
        if out and out ~= cache.entries then
            for i = #out, 1, -1 do out[i] = nil end
            for i = 1, #cache.entries do out[i] = cache.entries[i] end
            return out
        end
        return cache.entries
    end

    cache.at = now
    cache.spikeCount = WTM.SpikeDetector.total
    self:Compute(cache.entries)

    if out and out ~= cache.entries then
        for i = #out, 1, -1 do out[i] = nil end
        for i = 1, #cache.entries do out[i] = cache.entries[i] end
        return out
    end
    return cache.entries
end

--- The actual analysis.  Always writes into `out`.
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
                :format(Fmt.Duration(GetTime() - (WTM.state.sessionStart or GetTime()))))
    else
        local parts = {}
        for _, kind in ipairs({ "freeze", "heavy", "stutter", "minor" }) do
            if (counts[kind] or 0) > 0 then
                parts[#parts + 1] = ("%d %s"):format(counts[kind], C.SPIKE_DEFAULTS[kind].label:lower())
            end
        end
        AddFinding(out, counts.freeze > 0 and "crit" or "warn",
            ("%d frame time spikes detected"):format(total),
            table.concat(parts, ", "))
    end

    local stats = WTM.FrameTime:GetSessionStats()
    if stats.avgFPS > 0 and stats.low1 > 0 and (stats.low1 / stats.avgFPS) < 0.6 then
        AddFinding(out, "warn", "Frame pacing is uneven",
            ("Average %s FPS but the worst 1%% of frames ran at %s FPS. The gap between those two numbers is what a stutter feels like.")
                :format(Fmt.FPS(stats.avgFPS), Fmt.FPS(stats.low1)))
    end

    ------------------------------------------------------------------
    -- CPU correlation
    ------------------------------------------------------------------
    if not WTM.CPU.available then
        AddFinding(out, "muted", "Addon CPU was not measured",
            "The client's scriptProfile CVar is off, so per-addon CPU time is unavailable for this session. Nothing here can attribute a spike to an addon's CPU use.",
            { action = "enableProfiling" })
    else
        local correlations, spikeSamples = WTM.Correlation:Analyze()
        if spikeSamples >= C.CORRELATION_MIN_SAMPLES and #correlations > 0 then
            for i = 1, math.min(3, #correlations) do
                local entry = correlations[i]
                if entry.phi >= 0.30 then
                    AddFinding(out, entry.tone,
                        ("%s: %s"):format(entry.title, entry.label),
                        ("Elevated above its own average in %d of %d spike windows (phi %.2f, peak %+.1f%% CPU). This is an association, not a demonstrated cause.")
                            :format(entry.hits, entry.spikes, entry.phi, entry.peakExcess),
                        { addon = entry.name })
                end
            end
        elseif total > 0 then
            AddFinding(out, "muted", "Not enough spikes to correlate",
                ("%d spike%s recorded; at least %d are needed before an association is worth reporting.")
                    :format(spikeSamples, spikeSamples == 1 and "" or "s", C.CORRELATION_MIN_SAMPLES))
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
                { event = entry.event })
        end
    end

    local storms = WTM.Events.storms
    if #storms > 0 then
        AddFinding(out, "warn", ("%d event storm%s detected"):format(#storms, #storms == 1 and "" or "s"),
            ("Most recent: %s peaked at %s against a normal rate of %s.")
                :format(storms[#storms].event,
                        Fmt.Rate(storms[#storms].peakRate),
                        Fmt.Rate(storms[#storms].baseline)))
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
            "\nGrowth is not proof of a leak. Addons legitimately grow while caching data; what matters is whether it ever stops.")
    end

    local sessionGrowth = WTM.Memory.current.luaKB - WTM.Memory.current.luaStartKB
    if sessionGrowth > 51200 then   -- 50 MB
        AddFinding(out, "warn", "Lua heap grew notably this session",
            ("%s since login, now at %s. %s")
                :format(Fmt.MemoryDelta(sessionGrowth),
                        Fmt.Memory(WTM.Memory.current.luaKB),
                        WTM.Memory:GetGCSummary()))
    end

    ------------------------------------------------------------------
    -- Network
    ------------------------------------------------------------------
    if WTM.Network.session.spikes > 0 then
        AddFinding(out, "warn",
            ("%d world latency spike%s"):format(WTM.Network.session.spikes,
                WTM.Network.session.spikes == 1 and "" or "s"),
            ("Peak world latency %d ms, average %d ms. Latency spikes are server or connection side; no addon can cause or fix them.")
                :format(WTM.Network.session.peakWorld, select(2, WTM.Network:GetAverages())))
    end

    ------------------------------------------------------------------
    -- The addon's own cost
    ------------------------------------------------------------------
    local warning, tone = WTM.Overhead:GetWarning()
    if warning then
        AddFinding(out, tone, "This addon's own overhead is elevated", warning)
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
                "These are consistent with work outside addon Lua: shader compilation, asset streaming, the game engine itself, or the server. An addon cannot see any of those directly.")
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
