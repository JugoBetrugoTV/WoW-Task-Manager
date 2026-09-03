--[[--------------------------------------------------------------------------
    WoW Task Manager - Analysis/Observations.lua

    Sentences about the session, and the comparison between two sessions.

    Every sentence here is a description of something that was measured, in the
    past tense, with the numbers it rests on. None of them says why. The
    difference matters: "world latency rose by 47 ms during combat" is a
    reading, "combat caused your latency" is a guess, and this file only ever
    produces the first kind.

    Where two things happened together, the wording says that they happened
    together - never that one produced the other.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C   = WTM.C
local Fmt = WTM.Format

local Observations = {}
WTM.Observations = Observations

--------------------------------------------------------------------------
-- Session observations
--------------------------------------------------------------------------

local function add(out, tone, title, detail, badge)
    out[#out + 1] = { tone = tone, title = title, detail = detail, badge = badge }
end

--- Builds the "top observations" list for the Overview page.
---
--- Ordered by how much a reader would want to see it first, not by severity
--- alone: a stable session should say so rather than showing an empty panel.
function Observations:Build(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end

    local stats    = WTM.FrameTime:GetSessionStats()
    local duration = GetTime() - (WTM.state.sessionStart or GetTime())
    local spikes   = WTM.SpikeDetector

    ------------------------------------------------------------------
    -- Frame pacing
    ------------------------------------------------------------------
    if stats.frames > 0 then
        local histogram = WTM.FrameTime:GetHistogram()
        local stable, total = 0, 0
        for i = 1, #histogram do
            local count = histogram[i] or 0
            total = total + count
            if WTM.Math.HistogramValue(i) <= C.FRAME_STABLE_MS then
                stable = stable + count
            end
        end
        if total > 0 then
            local pct = stable / total * 100
            add(out,
                pct >= 95 and "ok" or (pct >= 85 and "warn" or "crit"),
                ("Frame pacing was stable for %.0f%% of the session"):format(pct),
                ("%s of %s frames finished within %d ms. The remainder is what a stutter is made of.")
                    :format(Fmt.Comma(stable), Fmt.Comma(total), C.FRAME_STABLE_MS),
                ("%.0f%%"):format(pct))
        end
    end

    ------------------------------------------------------------------
    -- Spikes
    ------------------------------------------------------------------
    local severe = (spikes.counts.freeze or 0) + (spikes.counts.heavy or 0)
    if severe > 0 then
        add(out, severe >= 3 and "crit" or "warn",
            ("%d major stutter%s detected"):format(severe, severe == 1 and "" or "s"),
            ("%d freeze and %d heavy stutter over %s. The worst single frame took %s.")
                :format(spikes.counts.freeze or 0, spikes.counts.heavy or 0,
                        Fmt.Duration(duration), Fmt.Ms(stats.maxMs or 0)),
            tostring(severe))
    elseif spikes.total > 0 then
        add(out, "ok",
            ("%d minor spike%s, none severe"):format(spikes.total,
                spikes.total == 1 and "" or "s"),
            ("Nothing reached the heavy or freeze thresholds. Worst frame: %s.")
                :format(Fmt.Ms(stats.maxMs or 0)),
            tostring(spikes.total))
    else
        add(out, "ok", "No stutter recorded",
            ("%s of play with no frame above the stutter threshold.")
                :format(Fmt.Duration(duration)))
    end

    local suppressed = WTM.Suppression:Describe()
    if suppressed then
        add(out, "muted", "Some spikes were not counted", suppressed .. " These are the client doing its job, not stutter.")
    end

    ------------------------------------------------------------------
    -- Latency
    ------------------------------------------------------------------
    if WTM.Caps:Has("latency") then
        local net = WTM.Network
        local peak = net.session.peakWorld or 0
        local avg = (net.session.samples or 0) > 0
            and (net.session.sumWorld / net.session.samples) or 0
        if peak > 0 and avg > 0 and peak > avg * 1.5 and (peak - avg) >= 30 then
            add(out, peak >= 250 and "warn" or "muted",
                ("World latency peaked %d ms above its average"):format(peak - avg),
                ("Average %d ms, peak %d ms. The client refreshes latency roughly every 30 seconds, so short spikes can be missed entirely.")
                    :format(avg, peak),
                ("%d ms"):format(peak))
        elseif avg > 0 then
            add(out, "ok", ("World latency averaged %d ms"):format(avg),
                ("Peak %d ms. %d reading%s classed as a latency spike.")
                    :format(peak, net.session.spikes or 0,
                            (net.session.spikes or 0) == 1 and "" or "s"))
        end
    else
        add(out, "muted", "Latency is not measurable on this client",
            WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT)
    end

    ------------------------------------------------------------------
    -- Memory
    ------------------------------------------------------------------
    local mem = WTM.Memory.current
    if mem.luaStartKB and mem.luaKB then
        local growth = mem.luaKB - mem.luaStartKB
        if growth > 0 then
            local perMin = duration > 0 and (growth / (duration / 60)) or 0
            add(out,
                perMin >= C.MEM_GROWTH_KB_PER_MIN and "warn" or "muted",
                ("Lua memory increased by %s this session"):format(Fmt.Memory(growth)),
                ("From %s to %s, about %s per minute. Growth is normal while addons cache data; what matters is whether it stops.")
                    :format(Fmt.Memory(mem.luaStartKB), Fmt.Memory(mem.luaKB),
                            Fmt.Memory(perMin)),
                Fmt.Memory(growth))
        end
        local drops = WTM.Memory.heapDrops.events or 0
        if drops > 0 then
            add(out, "muted",
                ("%d observed heap decrease%s"):format(drops, drops == 1 and "" or "s"),
                ("The heap fell by a measurable amount %d time%s, freeing %s in total. WoW reports no collection statistics, so this is the curve, not a confirmed collection count.")
                    :format(drops, drops == 1 and "" or "s",
                            Fmt.Memory(WTM.Memory.heapDrops.totalFreedKB or 0)))
        end
    end

    ------------------------------------------------------------------
    -- Addon association
    ------------------------------------------------------------------
    local correlations, samples, unavailable = WTM.Correlation:Analyze({})
    if unavailable then
        add(out, "muted", "Addon association is unavailable", unavailable)
    elseif (samples or 0) >= C.CORRELATION_MIN_SAMPLES and correlations[1] then
        local top = correlations[1]
        add(out, "muted",
            ("%s was above its own average CPU during %d of %d spike windows")
                :format(top.title or top.name, top.hits or 0, top.spikes or samples),
            (top.explanation or "") ,
            ("phi %.2f"):format(top.phi or 0))
    elseif samples and samples > 0 then
        add(out, "muted", "Not enough spikes for an association yet",
            ("%d spike window%s recorded. At least %d are needed before an association means anything.")
                :format(samples, samples == 1 and "" or "s", C.CORRELATION_MIN_SAMPLES))
    end

    ------------------------------------------------------------------
    -- Events
    ------------------------------------------------------------------
    if WTM.Events.available and WTM.Events:GetMode() ~= "OFF" then
        local storms = #WTM.Events.storms
        if storms > 0 then
            local storm = WTM.Events.storms[storms]
            add(out, "warn", ("%d event storm%s"):format(storms, storms == 1 and "" or "s"),
                ("Most recent: %s peaked at %s against a normal rate of %s.")
                    :format(storm.event, Fmt.Rate(storm.peakRate), Fmt.Rate(storm.baseline)),
                tostring(storms))
        end
    end

    ------------------------------------------------------------------
    -- This addon's own cost
    ------------------------------------------------------------------
    local overhead = WTM.Overhead.current.totalMsPerSec or 0
    local budget   = WTM.db.profile.sampling.overheadBudgetMs or C.OVERHEAD_BUDGET_MS_PER_SEC
    if overhead > budget then
        add(out, "warn", ("This addon is using %.2f ms/s of its own"):format(overhead),
            ("Above the %.1f ms/s budget. It is measured, not estimated, and it is broken down on the dashboard.")
                :format(budget),
            ("%.2f"):format(overhead))
    end

    return out
end

--------------------------------------------------------------------------
-- Session comparison
--------------------------------------------------------------------------

--- The metrics two sessions are compared on. `betterIsHigher` is nil where
--- neither direction is obviously better and the delta stays uncoloured.
Observations.COMPARE_METRICS = {
    { key = "duration",  label = "Duration",           betterIsHigher = nil,
      get = function(s) return s.duration end,
      format = function(v) return Fmt.Duration(v or 0) end },
    { key = "avgFPS",    label = "Average FPS",        betterIsHigher = true,
      get = function(s) return s.avgFPS end,
      format = function(v) return Fmt.FPS(v or 0) end },
    { key = "low1",      label = "1% low FPS",         betterIsHigher = true,
      get = function(s) return s.low1 end,
      format = function(v) return Fmt.FPS(v or 0) end },
    { key = "low01",     label = "0.1% low FPS",       betterIsHigher = true,
      get = function(s) return s.low01 end,
      format = function(v) return Fmt.FPS(v or 0) end },
    { key = "maxFrameMs", label = "Worst frame",       betterIsHigher = false,
      get = function(s) return s.maxFrameMs end,
      format = function(v) return Fmt.Ms(v or 0) end },
    { key = "medianMs",  label = "Median frame time",  betterIsHigher = false,
      get = function(s) return s.medianMs end,
      format = function(v) return Fmt.Ms(v or 0) end },
    { key = "incidents", label = "Stutter incidents",  betterIsHigher = false,
      get = function(s)
          local c = s.spikeCount or {}
          return (c.freeze or 0) + (c.heavy or 0) + (c.stutter or 0)
      end,
      format = function(v) return tostring(math.floor(v or 0)) end },
    { key = "avgLatencyWorld", label = "Average world latency", betterIsHigher = false,
      get = function(s) return s.avgLatencyWorld end,
      format = function(v) return ("%d ms"):format(math.floor(v or 0)) end },
    { key = "peakLatencyWorld", label = "Peak world latency",   betterIsHigher = false,
      get = function(s) return s.peakLatencyWorld end,
      format = function(v) return ("%d ms"):format(math.floor(v or 0)) end },
    { key = "memGrowth", label = "Lua memory growth",  betterIsHigher = false,
      get = function(s)
          if not (s.luaEndKB and s.luaStartKB) then return nil end
          return s.luaEndKB - s.luaStartKB
      end,
      format = function(v) return Fmt.Memory(v or 0) end },
    { key = "eventPeakRate", label = "Peak event rate", betterIsHigher = nil,
      get = function(s) return s.eventPeakRate end,
      format = function(v) return Fmt.Rate(v or 0) end },
    { key = "eventStorms", label = "Event storms",     betterIsHigher = false,
      get = function(s) return s.eventStorms end,
      format = function(v) return tostring(math.floor(v or 0)) end },
}

--- Compares two stored sessions. Returns a list of rows; `delta` is nil where
--- one side has no value for that metric, so the UI can leave the cell blank
--- instead of pretending the missing side was zero.
function Observations:Compare(a, b, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not (a and b) then return out end

    for _, metric in ipairs(self.COMPARE_METRICS) do
        local av, bv = metric.get(a), metric.get(b)
        local row = {
            key   = metric.key,
            label = metric.label,
            a     = av and metric.format(av) or nil,
            b     = bv and metric.format(bv) or nil,
            betterIsHigher = metric.betterIsHigher,
        }
        if av and bv then
            local absolute = bv - av
            row.deltaValue = absolute
            -- A percentage is only shown where the baseline is non-zero, and
            -- the absolute change is shown alongside it: "+100%" of one spike
            -- is two spikes, and that is worth seeing.
            if math.abs(av) > 0.0001 then
                row.delta = ("%+.0f%%"):format(absolute / math.abs(av) * 100)
            else
                row.delta = ("%+.1f"):format(absolute)
            end
        end
        out[#out + 1] = row
    end
    return out
end

--- One-line summary of a comparison, for the top of the Compare page.
function Observations:DescribeComparison(rows)
    local improved, worsened = 0, 0
    for _, row in ipairs(rows) do
        if row.deltaValue and row.betterIsHigher ~= nil then
            local rose = row.deltaValue > 0
            if rose == row.betterIsHigher then improved = improved + 1
            elseif row.deltaValue ~= 0 then worsened = worsened + 1 end
        end
    end
    if improved == 0 and worsened == 0 then
        return "No directional metric differs between these two sessions."
    end
    return ("%d metric%s moved in the better direction, %d in the worse. Two sessions are not a controlled experiment - zone, group size and what the server was doing all differ too.")
        :format(improved, improved == 1 and "" or "s", worsened)
end
