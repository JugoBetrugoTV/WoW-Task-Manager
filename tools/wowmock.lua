-- Minimal WoW API mock, enough to load and exercise WoWTaskManager outside the
-- game.  Not a reimplementation of WoW - just enough surface that load-time and
-- first-refresh code paths actually execute.

local M = {}

-- bit library (Lua 5.1 vanilla lacks it; WoW always has it)
if not bit then
    bit = {}
    local function tobit(x) return x % 4294967296 end
    function bit.band(a, b)
        local r, m = 0, 1
        a, b = tobit(a), tobit(b)
        for _ = 1, 32 do
            if a % 2 == 1 and b % 2 == 1 then r = r + m end
            a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
        end
        return r
    end
    function bit.rshift(a, n) return math.floor(tobit(a) / 2 ^ n) end
    function bit.lshift(a, n) return tobit(a * 2 ^ n) end
    function bit.bor(a, b)
        local r, m = 0, 1
        a, b = tobit(a), tobit(b)
        for _ = 1, 32 do
            if a % 2 == 1 or b % 2 == 1 then r = r + m end
            a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
        end
        return r
    end
end

--------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------
M.clock = 1000.0
function GetTime() return M.clock end
function debugprofilestop() return M.clock * 1000 end
function M.Advance(seconds) M.clock = M.clock + seconds end

--------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------
M.frames = {}
M.allFrames = {}

local Region = {}
Region.__index = Region
local function newRegion(kind, parent)
    local r = setmetatable({
        _kind = kind, _parent = parent, _points = {}, _shown = true,
        _w = 100, _h = 20, _scripts = {}, _events = {}, _children = {},
        _text = "", _color = {1,1,1,1},
    }, Region)
    return r
end

local noop = function() end
local selfReturn = function(self) return self end

--------------------------------------------------------------------------
-- Strict colour setters
--------------------------------------------------------------------------
-- These used to be no-ops that swallowed anything, which let a real bug ship:
--
--     obj:SetTextColor(tone and Theme:Tone(tone) or T("primary"))
--
-- In Lua, `a and f() or g()` truncates a multi-return to ONE value, so the
-- call received a single number instead of r, g, b, a. The live client threw
-- 220 times; the mock never noticed.
--
-- Validating argument shape here turns that whole class of mistake into a test
-- failure instead of a crash in someone's raid.
local function checkColor(name, self, r, g, b, a, ...)
    local extra = select("#", ...)
    if type(r) ~= "number" then
        error(("%s: expected r,g,b[,a] numbers, got %s (a multi-return truncated by an and/or expression?)")
            :format(name, type(r)), 3)
    end
    if type(g) ~= "number" or type(b) ~= "number" then
        error(("%s: expected r,g,b[,a] numbers, got r=%s g=%s b=%s - a colour was truncated to %d value(s)")
            :format(name, type(r), type(g), type(b), (type(g) == "nil") and 1 or 2), 3)
    end
    if a ~= nil and type(a) ~= "number" then
        error(("%s: alpha must be a number, got %s"):format(name, type(a)), 3)
    end
    if extra > 0 then
        error(("%s: too many arguments (%d extra)"):format(name, extra), 3)
    end
    for _, v in ipairs({ r, g, b }) do
        if v < 0 or v > 1 then
            error(("%s: colour components must be 0..1, got %s"):format(name, tostring(v)), 3)
        end
    end
end

function Region:SetTextColor(...) checkColor("SetTextColor", self, ...) end
function Region:SetColorTexture(...) checkColor("SetColorTexture", self, ...) end
function Region:SetVertexColor(...) checkColor("SetVertexColor", self, ...) end

local methods = {
    "SetPoint","SetAllPoints","ClearAllPoints",
    "SetTexture","SetTexCoord","SetAlpha",
    "SetJustifyH","SetJustifyV","SetWordWrap","SetNonSpaceWrap","SetMaxLines",
    "SetTextColor","SetShadowColor","SetShadowOffset","SetDrawLayer",
    "SetToplevel","SetClampedToScreen",
    "SetMovable","SetResizable","SetResizeBounds","SetMinResize","StartMoving",
    "StopMovingOrSizing","StartSizing","RegisterForDrag","RegisterForClicks",
    "EnableMouse","EnableMouseWheel","EnableKeyboard","SetClipsChildren",
    "SetScrollChild","SetVerticalScroll","SetHorizontalScroll","SetScale",
    "SetThickness","SetStartPoint","SetEndPoint","SetGradient","SetGradientAlpha",
    "SetBackdrop","Raise","Lower","SetHitRectInsets","SetAutoFocus","ClearFocus",
    "SetFocus","HighlightText","SetIgnoreParentScale","SetPropagateKeyboardInput",
    "SetBlendMode","SetDesaturated","SetRotation","SetParent","SetID","SetMouseClickEnabled",
}
for _, name in ipairs(methods) do
    if not Region[name] then Region[name] = noop end
end

--- Frame level is a real API on every supported client and addons anchor
--- layering to it, so it returns a number rather than being a no-op.
function Region:SetFrameLevel(level) self._frameLevel = level end
function Region:GetFrameLevel() return self._frameLevel or 1 end
function Region:SetFrameStrata(strata) self._strata = strata end
function Region:GetFrameStrata() return self._strata or "MEDIUM" end

function Region:Show() self._shown = true end
function Region:Hide() self._shown = false end
function Region:SetShown(v) self._shown = v and true or false end
function Region:IsShown() return self._shown end
function Region:IsVisible()
    if not self._shown then return false end
    local p = self._parent
    while p do
        if not p._shown then return false end
        p = p._parent
    end
    return true
end
--- Size is stored rather than discarded: layout code reads it back, and a
--- widget that collapses or grows is only testable if it does.
function Region:SetWidth(w) self._w = w end
function Region:SetHeight(h) self._h = h end
function Region:SetSize(w, h) self._w, self._h = w, h end

function Region:GetWidth() return self._w end
function Region:GetHeight() return self._h end
function Region:GetSize() return self._w, self._h end
function Region:GetLeft() return 0 end
function Region:GetRight() return self._w end
function Region:GetTop() return self._h end
function Region:GetBottom() return 0 end
function Region:GetEffectiveScale() return 1 end
function Region:GetScale() return 1 end
function Region:GetParent() return self._parent end
function Region:GetName() return self._name end
function Region:GetObjectType() return self._kind end
function Region:SetText(t) self._text = tostring(t or "") end
function Region:GetText() return self._text end
function Region:SetFont(path, size, flags) self._font = { path, size, flags } return true end
function Region:GetFont() return self._font and self._font[1] or "Fonts\\FRIZQT__.TTF" end
function Region:GetStringWidth() return #(self._text or "") * 6 end
function Region:GetStringHeight() return 12 end
function Region:SetScript(k, fn) self._scripts[k] = fn end
function Region:GetScript(k) return self._scripts[k] end
function Region:HookScript(k, fn) self._scripts[k .. "_hook"] = fn end
-- Only Frames have the event API. FontStrings, Textures and Lines do not, and
-- code that walks EnumerateFrames has to cope with that - so the mock models
-- the distinction rather than giving everything every method.
local FrameMethods = {}

function FrameMethods:RegisterEvent(e)
    if M.knownEvents and not M.knownEvents[e] then
        error("Unknown event: " .. tostring(e), 2)
    end
    self._events[e] = true
    M.listeners[e] = M.listeners[e] or {}
    M.listeners[e][self] = true
    return true
end
function FrameMethods:UnregisterEvent(e)
    self._events[e] = nil
    if M.listeners[e] then M.listeners[e][self] = nil end
end
function FrameMethods:RegisterAllEvents() self._allEvents = true M.allEventFrames[self] = true end
function FrameMethods:UnregisterAllEvents()
    self._allEvents = nil
    M.allEventFrames[self] = nil
    for e in pairs(self._events) do self:UnregisterEvent(e) end
end
function FrameMethods:IsEventRegistered(e) return self._events[e] and true or false end

-- Frames get the event methods; other regions deliberately do not.
local FrameProto = setmetatable({}, { __index = Region })
for k, v in pairs(FrameMethods) do FrameProto[k] = v end
FrameProto.__index = FrameProto

local function makeChild(self, kind, name)
    local r = newRegion(kind, self)
    r._name = name
    self._children[#self._children + 1] = r
    M.allFrames[#M.allFrames + 1] = r
    return r
end
function Region:CreateTexture(name, layer) return makeChild(self, "Texture", name) end
function Region:CreateFontString(name) return makeChild(self, "FontString", name) end
function Region:CreateLine(name) return makeChild(self, "Line", name) end
function Region:CreateMaskTexture(name) return makeChild(self, "MaskTexture", name) end

M.listeners = {}
M.allEventFrames = {}

function CreateFrame(kind, name, parent, template)
    local f = newRegion(kind, parent)
    setmetatable(f, FrameProto)
    f._name = name
    if name then _G[name] = f end
    M.frames[#M.frames + 1] = f
    M.allFrames[#M.allFrames + 1] = f
    return f
end

-- On a live Retail client EnumerateFrames also yields regions (FontStrings,
-- Textures), and their GetName does not reliably return a string - a real scan
-- crashed on a FontString from another addon's XML. The mock reproduces that
-- so the guard cannot regress: these objects are in the walk, they are not
-- frames, and one of them returns a non-string from GetName.
function M.AddHostileRegions()
    local host = CreateFrame("Frame", "DamageMeterEntry")
    local label = host:CreateFontString("DamageMeterEntryText")
    -- Whatever the client is really doing here, the addon must survive it.
    label.GetName = function(self) return self end
    local texture = host:CreateTexture("DamageMeterEntryIcon")
    -- Regions created this way already lack the event API, matching WoW.
    return label, texture
end

function EnumerateFrames(previous)
    if not previous then return M.allFrames[1] end
    for i = 1, #M.allFrames do
        if M.allFrames[i] == previous then return M.allFrames[i + 1] end
    end
    return nil
end

--- Fires an event to everything listening (specific or RegisterAllEvents).
function M.Fire(event, ...)
    for frame in pairs(M.allEventFrames) do
        local fn = frame._scripts.OnEvent
        if fn then fn(frame, event, ...) end
    end
    for frame in pairs(M.listeners[event] or {}) do
        local fn = frame._scripts.OnEvent
        if fn then fn(frame, event, ...) end
    end
end

--- Fires one script handler on one frame, returning false plus the error when
--- the handler blows up.
function M.FireScript(frame, script, ...)
    local fn = frame._scripts and frame._scripts[script]
    if not fn then return nil end
    local ok, err = pcall(fn, frame, ...)
    return ok, err
end

--- Fires `script` on every frame that has such a handler.
---
--- This exists because tooltips, hover highlights and click handlers are only
--- reachable by a human moving a mouse - so nothing in a headless suite touched
--- them, and a crash in one shipped. Walking every handler is the closest a
--- mock can get to someone hovering the whole UI.
function M.FireScriptOnAll(script, ...)
    local ran, failures = 0, {}
    -- Snapshot first: a handler may create frames, and iterating a growing
    -- list would never terminate.
    local snapshot = {}
    for i = 1, #M.frames do snapshot[i] = M.frames[i] end

    for i = 1, #snapshot do
        local frame = snapshot[i]
        if frame._scripts and frame._scripts[script] then
            ran = ran + 1
            local ok, err = pcall(frame._scripts[script], frame, ...)
            if not ok then
                failures[#failures + 1] = {
                    frame = frame._name or ("unnamed #" .. i),
                    script = script,
                    err = tostring(err),
                }
            end
        end
    end
    return ran, failures
end

--- Runs every OnUpdate handler once.
function M.Tick(elapsed)
    M.Advance(elapsed)
    for i = 1, #M.frames do
        local frame = M.frames[i]
        local fn = frame._scripts.OnUpdate
        if fn and frame:IsVisible() then fn(frame, elapsed) end
    end
end

--------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------
UIParent = CreateFrame("Frame", "UIParent")
UIParent._w, UIParent._h = 1920, 1080
WorldFrame = CreateFrame("Frame", "WorldFrame")
-- Every supported client has a Minimap; addons anchor buttons to it by name.
Minimap = CreateFrame("Frame", "Minimap", UIParent)
Minimap._w, Minimap._h = 140, 140

-- Panel management. HideUIPanel is what an addon calls to close the options
-- window behind its own; it is only ever reached out of combat.
function HideUIPanel(frame) if frame and frame.Hide then frame:Hide() end end
function ShowUIPanel(frame) if frame and frame.Show then frame:Show() end end

DEFAULT_CHAT_FRAME = { messages = {}, AddMessage = function(self, msg)
    self.messages[#self.messages + 1] = msg
    if M.verbose then print("  chat> " .. tostring(msg)) end
end }
SlashCmdList = {}
UISpecialFrames = {}

function geterrorhandler()
    return function(err)
        M.errors[#M.errors + 1] = tostring(err)
        print("  !! LUA ERROR: " .. tostring(err))
    end
end
M.errors = {}

function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function tinsert(...) return table.insert(...) end
function tremove(...) return table.remove(...) end
function strsplit(sep, s) local out = {} for m in s:gmatch("[^" .. sep .. "]+") do out[#out+1] = m end return unpack(out) end
function CreateColor(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function GetCursorPosition() return 500, 400 end
function GetScreenWidth() return 1920 end
function GetScreenHeight() return 1080 end
function GetPhysicalScreenSize() return 1920, 1080 end
function InCombatLockdown() return M.inCombat or false end
function IsResting() return true end
function ReloadUI() M.reloadRequested = true end
function UnitName() return "Testchar" end
function UnitClass() return "Mage", "MAGE" end
function UnitLevel() return 70 end
function GetRealmName() return "Testrealm" end
function GetLocale() return "enUS" end
function GetFramerate() return M.framerate or 60 end
function GetNetStats() return 12, 8, M.latHome or 40, M.latWorld or 55 end
function GetRealZoneText() return "Orgrimmar" end
function GetZoneText() return "Orgrimmar" end
function GetInstanceInfo() return "Orgrimmar", "none", 0, "", 0, 0, 0, 0, 0 end
function GetNumGroupMembers() return M.groupSize or 0 end
function IsEncounterInProgress() return false end
function hooksecurefunc() end
function securecall(fn, ...) return fn(...) end
function issecurevariable() return true end
function GetTimePreciseSec() return M.clock end

-- WoW exposes these as globals rather than under os.*
time = os.time
date = os.date

return M
