--[[--------------------------------------------------------------------------
    WoW Task Manager - Core/Ace.lua

    Ace3 bridge.  If Ace3 is present under Libs/ it is used.  If it is not, an
    internal, API-compatible implementation of the same five concepts takes
    over.  No module above this file ever needs to know which case applies.

    Covered:
        AceAddon-3.0    module lifecycle (NewModule / OnInitialize / OnEnable)
        AceEvent-3.0    RegisterEvent / RegisterMessage / SendMessage
        AceConsole-3.0  RegisterChatCommand / Print
        AceTimer-3.0    ScheduleTimer / ScheduleRepeatingTimer / CancelTimer
        AceDB-3.0       defaults, profiles, global/char sections

    AceGUI and AceConfig are deliberately NOT used - the whole point of the UI
    is that it does not look like an Ace3 options window.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local Compat = WTM.Compat
local C = WTM.C

local Ace = {}
WTM.Ace = Ace

local LibStub = _G.LibStub
local function GetLib(name, silent)
    if not LibStub then return nil end
    local ok, lib = pcall(LibStub, name, silent == nil and true or silent)
    if ok then return lib end
    return nil
end

Ace.AceAddon   = GetLib("AceAddon-3.0")
Ace.AceEvent   = GetLib("AceEvent-3.0")
Ace.AceConsole = GetLib("AceConsole-3.0")
Ace.AceTimer   = GetLib("AceTimer-3.0")
Ace.AceDB      = GetLib("AceDB-3.0")

Ace.usingAce3 = (Ace.AceAddon and Ace.AceEvent and Ace.AceDB) and true or false

--==========================================================================
-- Internal fallback: events
--==========================================================================

local EventMixin = {}
WTM.EventMixin = EventMixin

local eventFrame = CreateFrame("Frame", "WTMEventDispatcher")
local listeners  = {}   -- event -> { [object] = handlerNameOrFunc }
local messages   = {}   -- message -> { [object] = handlerNameOrFunc }

local function Dispatch(map, key, ...)
    local subs = map[key]
    if not subs then return end
    for obj, handler in pairs(subs) do
        local fn
        if type(handler) == "function" then
            fn = handler
        else
            fn = obj[handler]
        end
        if fn then
            -- A broken listener must never take the dispatcher down with it.
            local ok, err = pcall(fn, obj, key, ...)
            if not ok then geterrorhandler()(err) end
        end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    Dispatch(listeners, event, ...)
end)

function EventMixin:RegisterEvent(event, handler)
    handler = handler or event
    local subs = listeners[event]
    if not subs then
        subs = {}
        listeners[event] = subs
        -- SafeRegisterEvent swallows unknown events instead of erroring.
        if not Compat.SafeRegisterEvent(eventFrame, event) then
            listeners[event] = nil
            return false
        end
    end
    subs[self] = handler
    return true
end

function EventMixin:UnregisterEvent(event)
    local subs = listeners[event]
    if not subs then return end
    subs[self] = nil
    if not next(subs) then
        listeners[event] = nil
        pcall(eventFrame.UnregisterEvent, eventFrame, event)
    end
end

function EventMixin:UnregisterAllEvents()
    for event, subs in pairs(listeners) do
        if subs[self] then self:UnregisterEvent(event) end
    end
    for msg, subs in pairs(messages) do
        subs[self] = nil
    end
end

function EventMixin:RegisterMessage(message, handler)
    local subs = messages[message]
    if not subs then subs = {}; messages[message] = subs end
    subs[self] = handler or message
end

function EventMixin:UnregisterMessage(message)
    local subs = messages[message]
    if subs then subs[self] = nil end
end

function EventMixin:SendMessage(message, ...)
    Dispatch(messages, message, ...)
end

--==========================================================================
-- Internal fallback: timers
--==========================================================================

local TimerMixin = {}
WTM.TimerMixin = TimerMixin

local C_Timer_After = _G.C_Timer and _G.C_Timer.After
local pendingTimers = {}
local timerSeq = 0

-- A single OnUpdate driver for repeating timers.  Non-repeating timers go
-- through C_Timer.After when available, which is cheaper than polling.
local timerFrame = CreateFrame("Frame", "WTMTimerDriver")
timerFrame:Hide()

local function TimerDriverUpdate()
    local now = GetTime()
    local any = false
    for id, timer in pairs(pendingTimers) do
        if timer.cancelled then
            pendingTimers[id] = nil
        elseif now >= timer.at then
            local fn = type(timer.fn) == "function" and timer.fn or timer.obj[timer.fn]
            if timer.repeating then
                timer.at = now + timer.delay
                any = true
            else
                pendingTimers[id] = nil
            end
            if fn then
                local ok, err = pcall(fn, timer.obj, timer.arg)
                if not ok then geterrorhandler()(err) end
            end
        else
            any = true
        end
    end
    if not any then timerFrame:Hide() end
end
timerFrame:SetScript("OnUpdate", TimerDriverUpdate)

local function AddTimer(obj, fn, delay, repeating, arg)
    timerSeq = timerSeq + 1
    local id = timerSeq
    local timer = {
        obj = obj, fn = fn, delay = delay, repeating = repeating,
        arg = arg, at = GetTime() + delay,
    }
    pendingTimers[id] = timer
    timerFrame:Show()
    return id
end

function TimerMixin:ScheduleTimer(fn, delay, arg)
    return AddTimer(self, fn, delay, false, arg)
end

function TimerMixin:ScheduleRepeatingTimer(fn, delay, arg)
    return AddTimer(self, fn, delay, true, arg)
end

function TimerMixin:CancelTimer(id)
    local timer = pendingTimers[id]
    if timer then timer.cancelled = true end
end

function TimerMixin:CancelAllTimers()
    for id, timer in pairs(pendingTimers) do
        if timer.obj == self then timer.cancelled = true end
    end
end

--==========================================================================
-- Internal fallback: console
--==========================================================================

local ConsoleMixin = {}
WTM.ConsoleMixin = ConsoleMixin

local PRINT_PREFIX = "|cff4c8dff" .. (C and C.ADDON_SHORT or "WTM") .. "|r "

function ConsoleMixin:Print(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    DEFAULT_CHAT_FRAME:AddMessage(PRINT_PREFIX .. table.concat(parts, " "))
end

function ConsoleMixin:RegisterChatCommand(command, handler)
    local key = "WTM_" .. command:upper()
    _G["SLASH_" .. key .. "1"] = "/" .. command
    SlashCmdList[key] = function(input)
        local fn = type(handler) == "function" and handler or self[handler]
        if fn then
            local ok, err = pcall(fn, self, input or "")
            if not ok then geterrorhandler()(err) end
        end
    end
end

--==========================================================================
-- Internal fallback: database
--==========================================================================
-- Mirrors the part of AceDB-3.0 this addon relies on.  Defaults live behind a
-- metatable so unmodified values are never written to SavedVariables - that is
-- what keeps WoWTaskManagerDB small.

local DB = {}
WTM.DBLib = DB

local function ApplyDefaults(tbl, defaults)
    if not defaults then return tbl end
    setmetatable(tbl, {
        __index = function(t, k)
            local d = defaults[k]
            if type(d) == "table" then
                local created = {}
                ApplyDefaults(created, d)
                rawset(t, k, created)
                return created
            end
            return d
        end,
    })
    -- Re-apply to already-saved sub-tables so they inherit their own defaults.
    for k, v in pairs(tbl) do
        if type(v) == "table" and type(defaults[k]) == "table" then
            ApplyDefaults(v, defaults[k])
        end
    end
    return tbl
end
DB.ApplyDefaults = ApplyDefaults

local function CopyTable(src, dst)
    dst = dst or {}
    for k, v in pairs(src) do
        if type(v) == "table" then dst[k] = CopyTable(v) else dst[k] = v end
    end
    return dst
end
DB.CopyTable = CopyTable

local dbProto = {}
dbProto.__index = dbProto

function dbProto:GetCurrentProfile() return self.keys.profile end

function dbProto:GetProfiles(out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    for name in pairs(self.sv.profiles) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function dbProto:SetProfile(name)
    if self.keys.profile == name then return end
    self.sv.profiles[name] = self.sv.profiles[name] or {}
    self.keys.profile = name
    self.sv.profileKeys[self.charKey] = name
    self.profile = ApplyDefaults(self.sv.profiles[name], self.defaults.profile)
    self:FireCallback("OnProfileChanged", name)
end

function dbProto:ResetProfile()
    local name = self.keys.profile
    self.sv.profiles[name] = {}
    self.profile = ApplyDefaults(self.sv.profiles[name], self.defaults.profile)
    self:FireCallback("OnProfileReset", name)
end

function dbProto:DeleteProfile(name)
    if name == self.keys.profile then return false end
    self.sv.profiles[name] = nil
    return true
end

--- Callback registry.  Deliberately NOT the CallbackHandler dot-call signature:
--- the internal DB cannot recover `db` from a dot call, and every profile switch
--- in this addon goes through code we own, so an explicit method call is both
--- simpler and harder to get wrong.
---     db:AddCallback("OnProfileChanged", obj, "MethodName")
function dbProto:AddCallback(event, obj, method)
    self.callbacks = self.callbacks or {}
    local list = self.callbacks[event]
    if not list then list = {}; self.callbacks[event] = list end
    list[#list + 1] = { obj = obj, method = method }
end

function dbProto:FireCallback(event, ...)
    local list = self.callbacks and self.callbacks[event]
    if not list then return end
    for i = 1, #list do
        local entry = list[i]
        local fn = type(entry.method) == "function" and entry.method or entry.obj[entry.method]
        if fn then pcall(fn, entry.obj, event, self, ...) end
    end
end

function DB.New(svName, defaults, profileKey)
    _G[svName] = _G[svName] or {}
    local sv = _G[svName]
    sv.profiles    = sv.profiles or {}
    sv.profileKeys = sv.profileKeys or {}
    sv.global      = sv.global or {}
    sv.char        = sv.char or {}

    local charKey = (UnitName("player") or "?") .. " - " .. (GetRealmName() or "?")
    local wanted  = profileKey or sv.profileKeys[charKey] or "Default"
    sv.profileKeys[charKey] = wanted
    sv.profiles[wanted] = sv.profiles[wanted] or {}
    sv.char[charKey] = sv.char[charKey] or {}

    local self = setmetatable({
        sv       = sv,
        charKey  = charKey,
        defaults = defaults or {},
        keys     = { profile = wanted, char = charKey },
    }, dbProto)

    self.profile = ApplyDefaults(sv.profiles[wanted], self.defaults.profile)
    self.global  = ApplyDefaults(sv.global,           self.defaults.global)
    self.char    = ApplyDefaults(sv.char[charKey],    self.defaults.char)
    return self
end

--==========================================================================
-- Public factory
--==========================================================================

--- Embeds event/timer/console behaviour into `obj`, using Ace3 when present.
function Ace.Embed(obj)
    if Ace.AceEvent then
        Ace.AceEvent:Embed(obj)
    else
        for k, v in pairs(EventMixin) do obj[k] = obj[k] or v end
    end

    if Ace.AceTimer then
        Ace.AceTimer:Embed(obj)
    else
        for k, v in pairs(TimerMixin) do obj[k] = obj[k] or v end
    end

    if Ace.AceConsole then
        Ace.AceConsole:Embed(obj)
    else
        for k, v in pairs(ConsoleMixin) do obj[k] = obj[k] or v end
    end

    return obj
end

--- Creates the database, preferring AceDB-3.0.
function Ace.NewDB(svName, defaults)
    if Ace.AceDB then
        local ok, db = pcall(Ace.AceDB.New, Ace.AceDB, svName, defaults, true)
        if ok and db then
            -- Give the AceDB object the same tiny callback surface the internal
            -- one has, so callers never branch on which implementation is live.
            db.AddCallback    = db.AddCallback    or dbProto.AddCallback
            db.FireCallback   = db.FireCallback   or dbProto.FireCallback
            return db, "AceDB-3.0"
        end
    end
    return DB.New(svName, defaults), "internal"
end

function Ace.Describe()
    if Ace.usingAce3 then
        local parts = {}
        if Ace.AceAddon then parts[#parts + 1] = "AceAddon" end
        if Ace.AceEvent then parts[#parts + 1] = "AceEvent" end
        if Ace.AceConsole then parts[#parts + 1] = "AceConsole" end
        if Ace.AceTimer then parts[#parts + 1] = "AceTimer" end
        if Ace.AceDB then parts[#parts + 1] = "AceDB" end
        return "Ace3 (" .. table.concat(parts, ", ") .. ")"
    end
    return "internal fallback (Ace3 not found)"
end
