--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Alerts.lua

    User-defined thresholds, evaluated on data that is already being sampled.

    Two rules shaped this file:

      * No alert gets its own timer, its own event listener, or its own
        OnUpdate. They are all evaluated in one pass on the existing sampler
        tick, reading values the sampler has already produced. Adding a
        watchdog per rule is how a monitoring tool becomes the thing that needs
        monitoring.

      * No alert may spam. Each rule has a cooldown, and while a condition
        stays true it fires once, not once per sample. The chat channel is not
        a log file.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C   = WTM.C
local Fmt = WTM.Format

local Alerts = WTM:NewModule("Alerts")
WTM.Alerts = Alerts

--------------------------------------------------------------------------
-- Rule definitions
--------------------------------------------------------------------------
--
-- Each rule reads one already-sampled number. `unavailable` returns a reason
-- string when the value cannot be measured on this client, so a rule is shown
-- as unavailable rather than silently never firing.

local RULES = {
    {
        key = "frameTime", label = "Frame time above",
        unit = "ms", default = 100, min = 20, max = 500, step = 10,
        help = "Fires when a single frame takes longer than this. 100 ms is a hitch you can feel; 50 ms is a stutter you can see.",
        read = function() return WTM.FrameTime.current.maxMs or 0 end,
        format = function(v) return Fmt.Ms(v) end,
    },
    {
        key = "worldLatency", label = "World latency above",
        unit = "ms", default = 150, min = 50, max = 1000, step = 25,
        help = "The client only refreshes latency about every 30 seconds, so this reacts on that cadence, not instantly.",
        read = function() return WTM.Network.current.latencyWorld or 0 end,
        format = function(v) return ("%d ms"):format(v) end,
        unavailable = function()
            if not WTM.Caps:Has("latency") then
                return WTM.Caps:Note("latency") or C.TXT_UNAVAILABLE_CLIENT
            end
        end,
    },
    {
        key = "luaMemory", label = "Lua memory above",
        unit = "MB", default = 400, min = 50, max = 4000, step = 50,
        help = "Total Lua heap, which includes the default UI as well as addons.",
        read = function() return (WTM.Memory.current.luaKB or 0) / 1024 end,
        format = function(v) return ("%.0f MB"):format(v) end,
    },
    {
        key = "addonCPU", label = "Total addon CPU above",
        unit = "%", default = 10, min = 1, max = 100, step = 1,
        help = "The summed CPU share of all addons. Needs the scriptProfile CVar.",
        read = function() return WTM.CPU.current.totalPct or 0 end,
        format = function(v) return ("%.1f %%"):format(v) end,
        unavailable = function()
            if not WTM.CPU.available then
                return WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
            end
        end,
    },
    {
        key = "eventRate", label = "Events per second above",
        unit = "/s", default = 2000, min = 100, max = 20000, step = 100,
        help = "The global event rate across the whole UI, not one addon's share.",
        read = function() return WTM.Events.current.perSecond or 0 end,
        format = function(v) return Fmt.Rate(v) end,
        unavailable = function()
            if WTM.Events:GetMode() == "OFF" then
                return "Event monitoring is switched off."
            end
            if not WTM.Events.available then
                return WTM.Events.reason or C.TXT_UNAVAILABLE_CLIENT
            end
        end,
    },
    {
        key = "ownOverhead", label = "This addon's own cost above",
        unit = "ms/s", default = 5, min = 0.5, max = 50, step = 0.5,
        help = "A safety net on the diagnostic tool itself. If this fires, the thing to look at is this addon's settings.",
        read = function() return WTM.Overhead.current.totalMsPerSec or 0 end,
        format = function(v) return ("%.2f ms/s"):format(v) end,
    },
}

Alerts.RULES = RULES

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

Alerts.state = {}     -- key -> { firing, lastFiredAt, count, lastValue }
Alerts.log   = {}     -- most recent firings, newest last

local MAX_LOG = 40

local function stateFor(key)
    local state = Alerts.state[key]
    if not state then
        state = { firing = false, lastFiredAt = nil, count = 0, lastValue = 0 }
        Alerts.state[key] = state
    end
    return state
end

function Alerts:GetRule(key)
    for _, rule in ipairs(RULES) do
        if rule.key == key then return rule end
    end
end

function Alerts:Config(key)
    local config = WTM.db.profile.alerts.rules[key]
    if not config then
        local rule = self:GetRule(key)
        config = { enabled = false, threshold = rule and rule.default or 0 }
        WTM.db.profile.alerts.rules[key] = config
    end
    return config
end

--- Why a rule cannot run here, or nil when it can.
function Alerts:UnavailableReason(rule)
    return rule.unavailable and rule.unavailable() or nil
end

--------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------

local function fire(rule, value)
    local config   = Alerts:Config(rule.key)
    local settings = WTM.db.profile.alerts
    local state    = stateFor(rule.key)

    state.count       = state.count + 1
    state.lastFiredAt = GetTime()
    state.lastValue   = value

    local entry = {
        key       = rule.key,
        label     = rule.label,
        value     = value,
        text      = rule.format(value),
        threshold = config.threshold,
        at        = GetTime(),
        wallClock = time(),
        zone      = WTM.Context.state.zone,
        combat    = WTM.Context.state.combat,
    }
    Alerts.log[#Alerts.log + 1] = entry
    while #Alerts.log > MAX_LOG do table.remove(Alerts.log, 1) end

    if settings.chat then
        WTM:Print(("|cffd29922Alert|r %s %s (threshold %s)")
            :format(rule.label, rule.format(value), rule.format(config.threshold)))
    end

    if settings.marker then
        -- A marker on the shared timeline, so an alert can be found later
        -- rather than only being read as it goes past in chat.
        WTM.Context:AddMarker("alert", ("%s %s"):format(rule.label, rule.format(value)))
    end

    if settings.sound and type(_G.PlaySound) == "function" then
        -- Feature-detected and pcall'd: the sound kit constants differ between
        -- clients, and a missing one must not take the sampler down.
        pcall(_G.PlaySound, _G.SOUNDKIT and _G.SOUNDKIT.RAID_WARNING or 8959, "Master")
    end

    WTM:SendMessage("WTM_ALERT_FIRED", entry)
end

--- One pass over every enabled rule. Called by the scheduler, not by a timer
--- of its own.
function Alerts:Evaluate()
    local settings = WTM.db.profile.alerts
    if not settings.enabled then return end

    local now = GetTime()
    for _, rule in ipairs(RULES) do
        local config = self:Config(rule.key)
        if config.enabled and not self:UnavailableReason(rule) then
            local ok, value = pcall(rule.read)
            if ok and type(value) == "number" then
                local state = stateFor(rule.key)
                local over  = value > config.threshold

                if over and not state.firing then
                    -- Rising edge, subject to the cooldown. While the value
                    -- stays over the threshold it does not fire again.
                    local cooled = not state.lastFiredAt
                        or (now - state.lastFiredAt) >= (settings.cooldown or 30)
                    if cooled then fire(rule, value) end
                    state.firing = true
                elseif not over and state.firing then
                    -- Hysteresis on the way down, so a value sitting exactly on
                    -- the threshold does not chatter.
                    if value < config.threshold * 0.9 then state.firing = false end
                end
            end
        end
    end
end

function Alerts:ClearLog()
    for i = #self.log, 1, -1 do self.log[i] = nil end
    for _, state in pairs(self.state) do
        state.count, state.lastFiredAt, state.firing = 0, nil, false
    end
end

--- How many rules are enabled and actually able to run here.
function Alerts:CountActive()
    local enabled, blocked = 0, 0
    for _, rule in ipairs(RULES) do
        if self:Config(rule.key).enabled then
            if self:UnavailableReason(rule) then blocked = blocked + 1
            else enabled = enabled + 1 end
        end
    end
    return enabled, blocked
end

--------------------------------------------------------------------------

function Alerts:OnEnable()
    -- One task for every rule, on the slow tick. Alerts are a safety net, not
    -- a sampler: evaluating them faster than the data changes buys nothing.
    WTM.Scheduler:Register("alerts", function() Alerts:Evaluate() end,
        2, 1, 0.7, "sampler")
    self:RegisterMessage("WTM_RESET_RUNTIME", "ClearLog")
end
