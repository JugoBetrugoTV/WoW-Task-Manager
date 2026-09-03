--[[--------------------------------------------------------------------------
    WoW Task Manager - Analysis/Correlation.lua

    The part of the addon most likely to be misread, so it is the part that is
    worded most carefully.

    What we can observe: at the moment the frame time spiked, addon X had used
    more CPU than it usually does in a sample window of that length.

    What that is NOT: proof that addon X caused the spike.  The sample window
    is coarser than a frame, several addons react to the same event, and the
    real cause may be outside Lua entirely (shader compilation, streaming, a
    server hitch).

    So this module computes a phi coefficient between "addon was busy" and
    "spike happened" across every spike in the session, reports the sample
    count alongside it, and maps the result onto deliberately hedged language.
    The strongest phrase available is "Strongly correlated". There is no code
    path in this addon that outputs the word "caused".

    PHI IS NOT A PROBABILITY. Phi 0.67 does not mean "67% likely" and it does
    not mean "responsible for 67% of the spike". It is a correlation
    coefficient between two yes/no observations, running from -1 to 1, and its
    only honest reading is "these two things tended to occur together across N
    samples". The UI therefore shows it as a coefficient with its sample count,
    never as a percentage of blame - `percent` below exists solely to size a
    progress bar and is never labelled as a likelihood.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local MathU = WTM.Math

local Correlation = {}
WTM.Correlation = Correlation

--------------------------------------------------------------------------
-- Result cache
--------------------------------------------------------------------------
-- Analyze() walks every spike and every addon.  The sidebar, the dashboard,
-- the diagnostics page and the addon detail view all want the answer, and the
-- UI refreshes twice a second - recomputing it four times per refresh would
-- make this addon exactly the kind of thing it exists to catch.
--
-- The inputs only change when a spike is recorded or a CPU sample lands, so a
-- short TTL is both correct and cheap.

local CACHE_TTL = 2.0
local cache = { entries = {}, at = -1, samples = 0, unavailable = nil, spikeCount = -1 }

function Correlation:InvalidateCache()
    cache.at = -1
end

--------------------------------------------------------------------------
-- Labelling
--------------------------------------------------------------------------

function Correlation:Label(phi, samples)
    if (samples or 0) < C.CORRELATION_MIN_SAMPLES then
        return C.TXT_INSUFFICIENT, "muted"
    end
    for _, level in ipairs(C.CORRELATION_LEVELS) do
        if phi >= level.min then return level.label, level.tone end
    end
    return C.CORRELATION_LEVELS[#C.CORRELATION_LEVELS].label, "muted"
end

--------------------------------------------------------------------------
-- Per-addon correlation across the session's spikes
--------------------------------------------------------------------------

--- For every addon that appeared in at least one spike snapshot, computes how
--- consistently it was above its own average when spikes occurred.
---
--- The 2x2 contingency table is fully MEASURED, not estimated:
---
---                        spike window   no spike window
---     elevated                 a               b
---     not elevated             c               d
---
---     a  spike snapshots where this addon was above its own average
---     b  every other CPU sample where it was elevated (Monitoring/CPU counts
---        these directly, which is why nothing here has to be guessed)
---     c  spike snapshots where it was NOT elevated
---     d  the remaining quiet samples
---
--- An earlier version estimated `b` from the ratio of an addon's average to its
--- peak.  That was a fabricated number sitting in the middle of the only
--- calculation on this page that matters, so it is gone.
function Correlation:Analyze(out)
    local now = GetTime()
    if cache.at >= 0 and (now - cache.at) < CACHE_TTL
       and cache.spikeCount == #WTM.SpikeDetector.spikes then
        if out and out ~= cache.entries then
            for i = #out, 1, -1 do out[i] = nil end
            for i = 1, #cache.entries do out[i] = cache.entries[i] end
            return out, cache.samples, cache.unavailable
        end
        return cache.entries, cache.samples, cache.unavailable
    end

    local computed = cache.entries
    for i = #computed, 1, -1 do computed[i] = nil end
    cache.at = now
    cache.spikeCount = #WTM.SpikeDetector.spikes
    cache.unavailable = nil
    cache.samples = 0

    local result, samples, unavailable = self:Compute(computed)
    cache.samples = samples
    cache.unavailable = unavailable

    -- Stamp the association back onto the process records, so a sortable
    -- column and the impact ranking can read one number instead of each
    -- rebuilding a lookup from this list. Cleared first: an addon that no
    -- longer has an association must not keep yesterday's.
    for _, record in WTM.Processes:Iterate() do record.sessionPhi = nil end
    for i = 1, #computed do
        local entry = computed[i]
        local record = WTM.Processes:Get(entry.name)
        if record then record.sessionPhi = entry.phi end
    end

    if out and out ~= computed then
        for i = #out, 1, -1 do out[i] = nil end
        for i = 1, #computed do out[i] = computed[i] end
        return out, samples, unavailable
    end
    return computed, samples, unavailable
end

--- The actual computation.  Always writes into `out`.
function Correlation:Compute(out)
    for i = #out, 1, -1 do out[i] = nil end

    local spikes = WTM.SpikeDetector.spikes
    local spikeCount = #spikes
    if spikeCount == 0 then return out, 0 end

    if not WTM.CPU.available then
        return out, spikeCount, WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
    end

    -- addon -> how many spikes it was elevated in
    local elevated, totalExcess, peakExcess = {}, {}, {}
    local counted = 0

    for i = 1, spikeCount do
        local spike = spikes[i]
        if spike.cpu then
            counted = counted + 1
            for j = 1, #spike.cpu do
                local entry = spike.cpu[j]
                if entry.excess > WTM.CPU.ELEVATED_MARGIN_PCT then
                    elevated[entry.name]    = (elevated[entry.name] or 0) + 1
                    totalExcess[entry.name] = (totalExcess[entry.name] or 0) + entry.excess
                    if entry.excess > (peakExcess[entry.name] or 0) then
                        peakExcess[entry.name] = entry.excess
                    end
                end
            end
        end
    end

    if counted == 0 then
        return out, spikeCount, "No spike snapshot carried CPU data."
    end

    local list = WTM.Processes.list
    for i = 1, #list do
        local record = list[i]
        local hits = elevated[record.name]
        -- Excluded for the same reason as in Monitoring/CPU: this addon's own
        -- CPU rises BECAUSE a spike was detected, so correlating it with spikes
        -- inverts cause and effect.
        if hits and hits > 0 and record.name ~= WTM.name then
            local totalWindows  = record.cpuSamples or 0
            local elevatedTotal = record.elevatedSamples or 0

            local a = hits
            local b = math.max(0, elevatedTotal - hits)
            local cVal = math.max(0, counted - hits)
            local d = math.max(0, totalWindows - a - b - cVal)

            local phi = MathU.Phi(a, b, cVal, d)
            if phi < 0 then phi = 0 end

            local label, tone = self:Label(phi, counted)
            out[#out + 1] = {
                name        = record.name,
                title       = record.titleClean,
                phi         = phi,
                -- Bar width only. Never rendered with a "%" as though it were
                -- a likelihood; see the note at the top of this file.
                barFraction = phi,
                hits        = hits,
                spikes      = counted,
                elevatedTotal = elevatedTotal,
                totalWindows  = totalWindows,
                avgExcess   = totalExcess[record.name] / hits,
                peakExcess  = peakExcess[record.name] or 0,
                label       = label,
                tone        = tone,
                explanation = ("Above its own average in %d of %d spike windows, and in %d of %d samples overall.")
                    :format(hits, counted, elevatedTotal, totalWindows),
            }
        end
    end

    table.sort(out, function(a, b) return a.phi > b.phi end)
    return out, counted
end

--------------------------------------------------------------------------
-- Event correlation
--------------------------------------------------------------------------

--- Which events were running unusually hot when spikes happened.  Same
--- caution applies: an event storm and a frame spike sharing a second is a
--- coincidence until it repeats.
function Correlation:AnalyzeEvents(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end

    local spikes = WTM.SpikeDetector.spikes
    if #spikes == 0 then return out, 0 end

    local hits, rateSum = {}, {}
    local counted = 0
    for i = 1, #spikes do
        local spike = spikes[i]
        if spike.events and #spike.events > 0 then
            counted = counted + 1
            for j = 1, math.min(4, #spike.events) do
                local entry = spike.events[j]
                hits[entry.event]    = (hits[entry.event] or 0) + 1
                rateSum[entry.event] = (rateSum[entry.event] or 0) + entry.rate
            end
        end
    end

    for event, count in pairs(hits) do
        local share = count / math.max(1, counted)
        local label, tone = self:Label(share, counted)
        out[#out + 1] = {
            event   = event,
            hits    = count,
            spikes  = counted,
            -- `share` IS a genuine proportion: the fraction of recorded spike
            -- windows in which this event was among the busiest. Unlike phi it
            -- may legitimately be shown as a percentage.
            share   = share,
            percent = share * 100,
            avgRate = rateSum[event] / count,
            label   = label,
            tone    = tone,
        }
    end
    table.sort(out, function(a, b) return a.share > b.share end)
    return out, counted
end

--------------------------------------------------------------------------
-- Single-spike attribution
--------------------------------------------------------------------------

--- Candidates for one spike, ranked, with per-candidate wording.  Used by the
--- incident view.  With only one observation nothing can be called correlated,
--- so the wording caps out at "Possible contributor" here.
function Correlation:ForSpike(spike, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not spike or not spike.cpu then return out end

    -- Session-wide numbers give a single spike some context.
    local sessionView = self:Analyze(self._sessionScratch or {})
    self._sessionScratch = sessionView
    local sessionByName = {}
    for i = 1, #sessionView do sessionByName[sessionView[i].name] = sessionView[i] end

    for i = 1, #spike.cpu do
        local entry = spike.cpu[i]
        if entry.excess > 0.2 then
            local session = sessionByName[entry.name]
            local label, tone
            if session and session.spikes >= C.CORRELATION_MIN_SAMPLES then
                label, tone = session.label, session.tone
            else
                label, tone = "Possible contributor", "warn"
            end
            out[#out + 1] = {
                name       = entry.name,
                title      = entry.title or entry.name,
                deltaMs    = entry.deltaMs,
                excess     = entry.excess,
                label      = label,
                tone       = tone,
                sessionPhi = session and session.phi or nil,
                sessionHits = session and session.hits or nil,
                sessionSpikes = session and session.spikes or nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.excess > b.excess end)
    return out
end
