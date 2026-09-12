-- A minimal Ace3 stand-in for the test harness.
--
-- This exists because the Ace3 branch of Core/Ace.lua had never been executed:
-- the mock had no Ace3, so every test ran the internal fallback. A real client
-- loads Ace3 whenever ANY installed addon embeds it, so which branch runs
-- depends on the player's addon list - and a bug in the untested branch shipped.
--
-- The point is not to reimplement Ace3. It is to be faithful about the places
-- where Ace3 and the fallback DISAGREE, so those disagreements show up as test
-- failures instead of as errors in someone's game.
--
-- Deliberate faithful detail: AceConsole calls slash handlers as
-- func(msg, editBox), while the internal fallback calls func(input). That
-- mismatch is the bug this file was written to catch, so it is reproduced
-- exactly rather than smoothed over.

local M = {}

function M.Install()
    local libs = {}

    LibStub = setmetatable({}, {
        __call = function(_, name, silent)
            local lib = libs[name]
            if not lib and not silent then
                error("Cannot find a library instance of " .. tostring(name), 2)
            end
            return lib
        end,
    })
    function LibStub:NewLibrary(name, minor)
        libs[name] = libs[name] or {}
        return libs[name], minor
    end
    function LibStub:GetLibrary(name, silent)
        local lib = libs[name]
        if not lib and not silent then error("missing library " .. tostring(name), 2) end
        return lib
    end
    function LibStub:IterateLibraries() return pairs(libs) end

    ----------------------------------------------------------------------
    -- CallbackHandler-1.0
    ----------------------------------------------------------------------
    libs["CallbackHandler-1.0"] = { New = function(_, target) return { Fire = function() end } end }

    ----------------------------------------------------------------------
    -- AceEvent-3.0
    ----------------------------------------------------------------------
    local AceEvent = { embeds = {} }
    libs["AceEvent-3.0"] = AceEvent

    local eventFrame = CreateFrame("Frame", "AceStubEventFrame")
    local listeners, messages = {}, {}

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        for obj, handler in pairs(listeners[event] or {}) do
            local fn = type(handler) == "function" and handler or obj[handler]
            if fn then
                local ok, err = pcall(fn, obj, event, ...)
                if not ok then geterrorhandler()(err) end
            end
        end
    end)

    local eventMethods = {}
    function eventMethods:RegisterEvent(event, handler)
        listeners[event] = listeners[event] or {}
        if not next(listeners[event]) then
            -- Ace3 does NOT guard against unknown events; it lets the error
            -- through, which is why the addon must never rely on it doing so.
            local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
            if not ok then listeners[event] = nil return false end
        end
        listeners[event][self] = handler or event
        return true
    end
    function eventMethods:UnregisterEvent(event)
        if listeners[event] then listeners[event][self] = nil end
    end
    function eventMethods:UnregisterAllEvents()
        for event, subs in pairs(listeners) do subs[self] = nil end
        for _, subs in pairs(messages) do subs[self] = nil end
    end
    function eventMethods:RegisterMessage(message, handler)
        messages[message] = messages[message] or {}
        messages[message][self] = handler or message
    end
    function eventMethods:UnregisterMessage(message)
        if messages[message] then messages[message][self] = nil end
    end
    function eventMethods:SendMessage(message, ...)
        for obj, handler in pairs(messages[message] or {}) do
            local fn = type(handler) == "function" and handler or obj[handler]
            if fn then
                local ok, err = pcall(fn, obj, message, ...)
                if not ok then geterrorhandler()(err) end
            end
        end
    end
    function AceEvent:Embed(target)
        for k, v in pairs(eventMethods) do target[k] = v end
        return target
    end

    ----------------------------------------------------------------------
    -- AceConsole-3.0
    ----------------------------------------------------------------------
    local AceConsole = {}
    libs["AceConsole-3.0"] = AceConsole

    local consoleMethods = {}
    function consoleMethods:Print(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        DEFAULT_CHAT_FRAME:AddMessage(table.concat(parts, " "))
    end
    function consoleMethods:Printf(fmt, ...)
        DEFAULT_CHAT_FRAME:AddMessage(fmt:format(...))
    end

    --- The important one. AceConsole passes (msg, editBox) - NOT (self, input).
    --- Reproduced exactly: this is the divergence that broke a real client.
    function consoleMethods:RegisterChatCommand(command, func)
        local name = "ACESTUB_" .. command:upper()
        _G["SLASH_" .. name .. "1"] = "/" .. command
        SlashCmdList[name] = function(msg, editBox)
            if type(func) == "string" then
                self[func](self, msg, editBox)
            else
                func(msg, editBox)
            end
        end
    end
    function AceConsole:Embed(target)
        for k, v in pairs(consoleMethods) do target[k] = v end
        return target
    end

    ----------------------------------------------------------------------
    -- AceTimer-3.0
    ----------------------------------------------------------------------
    local AceTimer = {}
    libs["AceTimer-3.0"] = AceTimer
    local timerMethods = {}
    local timers, timerSeq = {}, 0
    function timerMethods:ScheduleTimer(fn, delay, arg)
        timerSeq = timerSeq + 1
        timers[timerSeq] = { obj = self, fn = fn, at = GetTime() + delay, arg = arg }
        return timerSeq
    end
    function timerMethods:ScheduleRepeatingTimer(fn, delay, arg)
        timerSeq = timerSeq + 1
        timers[timerSeq] = { obj = self, fn = fn, at = GetTime() + delay,
                             delay = delay, repeating = true, arg = arg }
        return timerSeq
    end
    function timerMethods:CancelTimer(id) timers[id] = nil end
    function timerMethods:CancelAllTimers()
        for id, t in pairs(timers) do if t.obj == self then timers[id] = nil end end
    end
    function AceTimer:Embed(target)
        for k, v in pairs(timerMethods) do target[k] = v end
        return target
    end

    ----------------------------------------------------------------------
    -- AceDB-3.0
    ----------------------------------------------------------------------
    local AceDB = {}
    libs["AceDB-3.0"] = AceDB

    local function applyDefaults(tbl, defaults)
        if not defaults then return tbl end
        setmetatable(tbl, { __index = function(t, k)
            local d = defaults[k]
            if type(d) == "table" then
                local created = {}
                applyDefaults(created, d)
                rawset(t, k, created)
                return created
            end
            return d
        end })
        for k, v in pairs(tbl) do
            if type(v) == "table" and type(defaults[k]) == "table" then
                applyDefaults(v, defaults[k])
            end
        end
        return tbl
    end

    local dbProto = {}
    dbProto.__index = dbProto
    function dbProto:GetCurrentProfile() return self.keys.profile end
    function dbProto:GetProfiles(out)
        out = out or {}
        for name in pairs(self.sv.profiles) do out[#out + 1] = name end
        return out
    end
    function dbProto:SetProfile(name)
        self.sv.profiles[name] = self.sv.profiles[name] or {}
        self.keys.profile = name
        self.profile = applyDefaults(self.sv.profiles[name], self.defaults.profile)
    end
    function dbProto:ResetProfile()
        local name = self.keys.profile
        self.sv.profiles[name] = {}
        self.profile = applyDefaults(self.sv.profiles[name], self.defaults.profile)
    end

    function AceDB:New(svName, defaults, defaultProfile)
        _G[svName] = _G[svName] or {}
        local sv = _G[svName]
        sv.profiles = sv.profiles or {}
        sv.profileKeys = sv.profileKeys or {}
        sv.global = sv.global or {}
        sv.char = sv.char or {}

        local charKey = (UnitName("player") or "?") .. " - " .. (GetRealmName() or "?")
        local profileName = sv.profileKeys[charKey] or "Default"
        sv.profileKeys[charKey] = profileName
        sv.profiles[profileName] = sv.profiles[profileName] or {}
        sv.char[charKey] = sv.char[charKey] or {}

        local db = setmetatable({
            sv = sv, defaults = defaults or {},
            keys = { profile = profileName, char = charKey },
        }, dbProto)
        db.profile = applyDefaults(sv.profiles[profileName], db.defaults.profile)
        db.global  = applyDefaults(sv.global, db.defaults.global)
        db.char    = applyDefaults(sv.char[charKey], db.defaults.char)
        return db
    end

    ----------------------------------------------------------------------
    -- AceAddon-3.0 (present so Ace.usingAce3 becomes true)
    ----------------------------------------------------------------------
    libs["AceAddon-3.0"] = {
        NewAddon = function(_, name) return { name = name } end,
        GetAddon = function(_, name) return nil end,
    }

    return libs
end

return M
