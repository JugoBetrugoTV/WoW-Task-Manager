--[[--------------------------------------------------------------------------
    WoW Task Manager - Analysis/Impact.lua

    Rankings, and one combined score.

    A single "impact" number is a compression of four different measurements
    into one, and compressions lose information. It is offered because the
    question "which addon should I look at first?" is a real one and a reader
    should not have to sort four tables by eye - but it is presented with its
    inputs visible, and it is never described as a measurement of harm.

    What the score is:
        a weighted sum of four normalised components, each 0..1, scaled to 100.

    What the score is NOT:
        a percentage of anything, a probability, an amount of lag caused, or a
        reason to disable an addon. An addon can score highly for doing exactly
        the job it was installed to do.

    Every component is stated alongside the total, so a reader can see which one
    is driving it.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C = WTM.C

local Impact = {}
WTM.Impact = Impact

-- The weights. Deliberately round numbers: precision here would imply a
-- calibration that does not exist.
Impact.WEIGHTS = {
    cpu     = 0.40,   -- share of measured addon CPU
    memory  = 0.20,   -- share of measured addon memory
    growth  = 0.15,   -- memory growth rate
    events  = 0.10,   -- attributed event load (heuristic)
    spikes  = 0.15,   -- association with recorded spikes
}

Impact.EXPLANATION =
    "A weighted sum of four normalised measurements: CPU share (40%), memory " ..
    "share (20%), memory growth (15%), attributed event load (10%) and how " ..
    "often the addon was above its own average during recorded spikes (15%). " ..
    "Each component is normalised against the largest value observed this " ..
    "session, so the score is relative to your own addon list and cannot be " ..
    "compared against someone else's. It is not a percentage, not a " ..
    "probability, and not a measure of how much lag an addon caused."

--------------------------------------------------------------------------

local function safeShare(value, maximum)
    if not maximum or maximum <= 0 then return 0 end
    return math.max(0, math.min(1, (value or 0) / maximum))
end

--- Builds the ranking. Returns the list plus a table of what was available,
--- so the UI can say which components actually contributed.
function Impact:Compute(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end

    local cpuAvailable = WTM.CPU.available and true or false
    local memAvailable = WTM.Caps:Has("addonMemory")

    -- Correlation is only meaningful once enough spikes have been recorded;
    -- below that the component is simply absent rather than estimated.
    local correlations, samples = WTM.Correlation:Analyze({})
    local correlated = {}
    local correlationAvailable = (samples or 0) >= C.CORRELATION_MIN_SAMPLES
    if correlationAvailable then
        for _, entry in ipairs(correlations) do
            correlated[entry.name] = entry
        end
    end

    -- Maxima for normalisation, taken from the same session being ranked.
    local maxCPU, maxMem, maxGrowth, maxEvents = 0, 0, 0, 0
    for _, record in WTM.Processes:Iterate() do
        if record.loaded and record.name ~= WTM.name then
            maxCPU    = math.max(maxCPU, record.cpuPct or 0)
            maxMem    = math.max(maxMem, record.memKB or 0)
            maxGrowth = math.max(maxGrowth, record.memGrowthKBPerMin or 0)
            maxEvents = math.max(maxEvents, record.registeredEvents or 0)
        end
    end

    for _, record in WTM.Processes:Iterate() do
        -- This addon is excluded, for the same reason it is excluded from
        -- spike attribution: its own activity is a reaction to what it
        -- measures. Its cost is reported under Overhead instead.
        if record.loaded and record.name ~= WTM.name then
            local components = {
                cpu    = cpuAvailable and safeShare(record.cpuPct, maxCPU) or 0,
                memory = memAvailable and safeShare(record.memKB, maxMem) or 0,
                growth = memAvailable and safeShare(record.memGrowthKBPerMin, maxGrowth) or 0,
                events = safeShare(record.registeredEvents, maxEvents),
                spikes = 0,
            }

            local correlation = correlated[record.name]
            if correlation then
                -- phi is already 0..1 for a positive association; a negative
                -- one contributes nothing rather than a negative score.
                components.spikes = math.max(0, math.min(1, correlation.phi or 0))
            end

            local score = 0
            for key, weight in pairs(self.WEIGHTS) do
                score = score + weight * (components[key] or 0)
            end

            out[#out + 1] = {
                name       = record.name,
                title      = record.title or record.name,
                record     = record,
                score      = score * 100,
                components = components,
                cpuPct     = record.cpuPct or 0,
                memKB      = record.memKB or 0,
                growthKB   = record.memGrowthKBPerMin or 0,
                events     = record.registeredEvents or 0,
                phi        = correlation and correlation.phi or nil,
                phiLabel   = correlation and correlation.label or nil,
            }
        end
    end

    table.sort(out, function(a, b) return a.score > b.score end)

    self.availability = {
        cpu         = cpuAvailable,
        memory      = memAvailable,
        growth      = memAvailable,
        events      = true,
        spikes      = correlationAvailable,
        spikeReason = correlationAvailable and nil
            or ("%d of %d spike windows recorded so far")
                :format(samples or 0, C.CORRELATION_MIN_SAMPLES),
    }
    return out, self.availability
end

--- A named ranking, for the tabs on the Addon Impact page. `key` selects which
--- number to sort by; the list is the same one Compute produced.
Impact.RANKINGS = {
    { key = "score",  label = "Combined impact",
      help = "The weighted score. Hover the header for what goes into it." },
    { key = "cpu",    label = "Highest CPU",
      help = "Average CPU share this session. Needs the scriptProfile CVar." },
    { key = "memory", label = "Highest memory",
      help = "Current memory attributed to the addon by the client." },
    { key = "growth", label = "Fastest growing",
      help = "Memory growth per minute. Growth is not proof of a leak." },
    { key = "spikes", label = "Most spike-associated",
      help = "How consistently the addon was above its own average CPU during recorded spikes. An association, not a cause." },
    { key = "events", label = "Most event-heavy",
      help = "How many distinct events its named frames are registered for. Heuristic: anonymous frames cannot be attributed." },
}

function Impact:Sort(list, key)
    local getters = {
        score  = function(e) return e.score end,
        cpu    = function(e) return e.cpuPct end,
        memory = function(e) return e.memKB end,
        growth = function(e) return e.growthKB end,
        events = function(e) return e.events end,
        spikes = function(e) return e.phi or -1 end,
    }
    local get = getters[key] or getters.score
    table.sort(list, function(a, b) return get(a) > get(b) end)
    return list
end
