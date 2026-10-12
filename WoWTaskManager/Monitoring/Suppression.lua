--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Suppression.lua

    Decides when a bad frame is NOT stutter.

    A 900 ms frame while a loading screen is up, or in the first seconds after
    logging in, is not the kind of freeze anyone wants reported - it is the
    client doing exactly what it is supposed to do. Reporting those as freezes
    buries the ones that matter, so they are counted separately and shown as
    suppressed with the reason.

    Everything here is a stated rule with a named reason. Nothing is silently
    discarded: SpikeDetector keeps a per-reason tally, and the UI shows it.

    The one heuristic is background detection. WoW has no "is the window
    focused" API, so this infers it from the maxFPSBk CVar: a backgrounded
    client renders at roughly that cap, so frame times sitting steadily near
    1000/maxFPSBk are probably a backgrounded client rather than a stutter.
    It is labelled as a guess wherever it appears, and it can be turned off.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat

local Suppression = WTM:NewModule("Suppression")
WTM.Suppression = Suppression

Suppression.state = {
    loading      = false,
    loadingSince = nil,
    warmupUntil  = 0,
    warmupReason = nil,
    background   = false,
    backgroundStreak = 0,
}

-- reason key -> how many spikes it swallowed this session
Suppression.counts = {}

--------------------------------------------------------------------------
-- Warm-up windows
--------------------------------------------------------------------------

--- Starts a warm-up window.  The longest pending window wins, so a zone change
--- during login warm-up does not shorten it.
function Suppression:BeginWarmup(reason, seconds)
    if seconds <= 0 then return end
    local until_ = GetTime() + seconds
    if until_ > self.state.warmupUntil then
        self.state.warmupUntil = until_
        self.state.warmupReason = reason
    end
end

function Suppression:WarmupRemaining()
    local remaining = self.state.warmupUntil - GetTime()
    return remaining > 0 and remaining or 0
end

--------------------------------------------------------------------------
-- Background detection (heuristic)
--------------------------------------------------------------------------

--- Called once per frame-time sample with the window's average frame time.
--- Returns true when the client looks backgrounded.
function Suppression:UpdateBackground(avgMs)
    local state = self.state
    if not WTM.db.profile.spikes.suppressBackground then
        state.background = false
        state.backgroundStreak = 0
        return false
    end

    local cap = Compat.GetCVarNumber("maxFPSBk", 0)
    if not cap or cap <= 0 then
        -- No background cap configured, so there is nothing to recognise.
        state.background = false
        state.backgroundStreak = 0
        return false
    end

    local expectedMs = 1000 / cap
    local tolerance = expectedMs * C.BACKGROUND_TOLERANCE
    if math.abs(avgMs - expectedMs) <= tolerance then
        state.backgroundStreak = state.backgroundStreak + 1
    else
        state.backgroundStreak = 0
    end

    state.background = state.backgroundStreak >= C.BACKGROUND_MIN_SAMPLES
    state.backgroundExpectedMs = expectedMs
    return state.background
end

--------------------------------------------------------------------------
-- The decision
--------------------------------------------------------------------------

--- Returns nil when the spike should be reported, or a reason key when it
--- should be suppressed.
function Suppression:Check()
    local settings = WTM.db.profile.spikes
    if not settings.enabled then return "disabled" end

    local state = self.state

    if settings.suppressLoading and state.loading then
        return "loading"
    end

    if settings.suppressWarmup and self:WarmupRemaining() > 0 then
        return state.warmupReason or "warmup"
    end

    if settings.suppressBackground and state.background then
        return "background"
    end

    return nil
end

function Suppression:Record(reason)
    self.counts[reason] = (self.counts[reason] or 0) + 1
    self.lastReason = reason
    self.lastAt = GetTime()
end

function Suppression:TotalSuppressed()
    local total = 0
    for _, n in pairs(self.counts) do total = total + n end
    return total
end

--- One line describing what has been filtered out, for the dashboard.
function Suppression:Describe()
    local total = self:TotalSuppressed()
    if total == 0 then return nil end
    local parts = {}
    for reason, n in pairs(self.counts) do
        parts[#parts + 1] = ("%d %s"):format(n, (C.SUPPRESSION_REASONS[reason] or reason):lower())
    end
    table.sort(parts)
    return ("%d frame spike%s not reported: %s")
        :format(total, total == 1 and "" or "s", table.concat(parts, ", "))
end

--- Current status, for the System page and /wtm dev.
function Suppression:Status()
    local state = self.state
    if state.loading then return "Loading screen active", "warn" end
    local warmup = self:WarmupRemaining()
    if warmup > 0 then
        return ("Warm-up: %s, %.0fs remaining")
            :format(C.SUPPRESSION_REASONS[state.warmupReason] or "settling", warmup), "warn"
    end
    if state.background then
        return ("Client looks backgrounded (frames near the %s ms background cap - heuristic)")
            :format(state.backgroundExpectedMs and ("%.0f"):format(state.backgroundExpectedMs) or "?"), "warn"
    end
    return "Recording normally", "ok"
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Suppression:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
    self:RegisterEvent("LOADING_SCREEN_ENABLED", "OnLoadingStart")
    self:RegisterEvent("LOADING_SCREEN_DISABLED", "OnLoadingEnd")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneChanged")
    self:RegisterMessage("WTM_RESET_RUNTIME", "Reset")

    -- We are enabled during login, so the login warm-up starts here even if
    -- PLAYER_ENTERING_WORLD has already fired.
    self:BeginWarmup("login", WTM.db.profile.spikes.warmupLogin)
end

--- PLAYER_ENTERING_WORLD carries isInitialLogin and isReloadingUi on modern
--- clients.  Both may be nil on a client that does not send them, in which case
--- we fall back to the zone-change window rather than assuming either.
function Suppression:OnEnteringWorld(_, isInitialLogin, isReloadingUi)
    local settings = WTM.db.profile.spikes
    if isInitialLogin then
        self:BeginWarmup("login", settings.warmupLogin)
    elseif isReloadingUi then
        self:BeginWarmup("reload", settings.warmupReload)
    else
        self:BeginWarmup("zone", settings.warmupZone)
    end
end

function Suppression:OnLoadingStart()
    self.state.loading = true
    self.state.loadingSince = GetTime()
end

function Suppression:OnLoadingEnd()
    self.state.loading = false
    -- The frames right after a loading screen are still the client catching
    -- up, so the warm-up continues past the screen itself.
    self:BeginWarmup("zone", WTM.db.profile.spikes.warmupZone)
end

function Suppression:OnZoneChanged()
    self:BeginWarmup("zone", WTM.db.profile.spikes.warmupZone)
end

function Suppression:Reset()
    for k in pairs(self.counts) do self.counts[k] = nil end
    self.lastReason, self.lastAt = nil, nil
    self.state.backgroundStreak = 0
    self.state.background = false
end
