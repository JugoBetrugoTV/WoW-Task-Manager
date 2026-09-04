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
--- REAL elapsed milliseconds, not the simulated clock.
---
--- This used to return M.clock * 1000, which only moves when the harness moves
--- it - so every "how long did this task take" measurement inside the addon
--- was exactly zero, and the harness was structurally incapable of finding a
--- slow sampler. A real client reported 16 ms/s of sampling cost that no test
--- here could see.
---
--- The absolute numbers are this machine's, not WoW's. What they are good for
--- is comparing samplers against each other and catching one that becomes
--- disproportionately expensive.
function debugprofilestop() return os.clock() * 1000 end
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
    "SetTexture","SetTexCoord","SetAlpha",
    "SetJustifyH","SetJustifyV",
    "SetTextColor","SetShadowColor","SetShadowOffset","SetDrawLayer",
    "SetToplevel","SetClampedToScreen",
    "SetMovable","SetResizable","SetResizeBounds","SetMinResize","StartMoving",
    "StopMovingOrSizing","StartSizing","RegisterForDrag","RegisterForClicks",
    "EnableMouse","EnableMouseWheel","EnableKeyboard",
    "SetScrollChild","SetVerticalScroll","SetHorizontalScroll","SetScale",
    "SetThickness","SetStartPoint","SetEndPoint","SetGradient","SetGradientAlpha",
    "SetBackdrop","Raise","Lower","SetHitRectInsets","SetAutoFocus","ClearFocus",
    "SetFocus","HighlightText","SetIgnoreParentScale","SetPropagateKeyboardInput",
    "SetBlendMode","SetDesaturated","SetRotation","SetParent","SetID","SetMouseClickEnabled",
    "SetMultiLine","SetMaxLetters","SetCountInvisibleLetters","SetCursorPosition","SetFontObject",
    "SetTextInsets","SetHyperlinksEnabled","SetSpacing","Insert","SetEnabled",
}
for _, name in ipairs(methods) do
    if not Region[name] then Region[name] = noop end
end

--- Frame level is a real API on every supported client and addons anchor
--- layering to it, so it returns a number rather than being a no-op.
--- Recorded rather than ignored: whether a frame clips its children is the
--- difference between a wrong layout looking wrong and a wrong layout painting
--- over the game, and a real client hit the second one.
function Region:SetClipsChildren(v) self._clipsChildren = v and true or false end
function Region:DoesClipChildren() return self._clipsChildren or false end

function Region:SetFrameLevel(level) self._frameLevel = level end
function Region:GetFrameLevel() return self._frameLevel or 1 end
function Region:SetFrameStrata(strata) self._strata = strata end
function Region:GetFrameStrata() return self._strata or "MEDIUM" end

--- Show and Hide fire OnShow and OnHide, the way the client does, and only on
--- an actual transition.
---
--- They used to be plain flag writes. The main window enables its refresh task
--- from OnShow, so nothing in the harness ever turned the UI task on - the one
--- task that drives every page refresh and every graph redraw was untested.
local function fireVisibility(self, script)
    local fn = self._scripts and self._scripts[script]
    if fn then fn(self) end
end

function Region:Show()
    if self._shown then return end
    self._shown = true
    fireVisibility(self, "OnShow")
end

function Region:Hide()
    if not self._shown then return end
    self._shown = false
    fireVisibility(self, "OnHide")
end

function Region:SetShown(v)
    if v then self:Show() else self:Hide() end
end
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
--------------------------------------------------------------------------
-- Anchors and resolved geometry
--------------------------------------------------------------------------
--
-- SetPoint used to be a no-op, which meant the harness could not answer the one
-- question the real client kept answering badly: does this text fit in the box
-- it was given? Anchors are now recorded and resolved, so a font string that is
-- anchored LEFT and RIGHT has a real width, and a label that outgrows it can be
-- caught here instead of in a screenshot.
--
-- This is a deliberately small subset of the real anchoring system: horizontal
-- edges only, no scale, no strata. It is enough to find text overflow and not
-- enough to pretend it is a layout engine.

local function invalidateLayout() M.layoutEpoch = (M.layoutEpoch or 0) + 1 end
M.layoutEpoch = 0

--- SetPoint has six accepted argument shapes in WoW. Normalise them all.
local function parsePoint(a, b, c, d, e)
    local point, relativeTo, relativePoint, x, y = a, nil, nil, 0, 0
    if type(b) == "number" then            -- (point, x, y)
        x, y = b, c or 0
    elseif type(b) == "string" then        -- (point, relativePoint, x, y) is not
        relativePoint, x, y = b, c or 0, d or 0   -- valid WoW, but be lenient
    elseif b ~= nil then
        relativeTo = b
        if type(c) == "number" then        -- (point, rel, x, y)
            x, y = c, d or 0
        else
            relativePoint, x, y = c, d or 0, e or 0
        end
    end
    return { point = point, rel = relativeTo, relPoint = relativePoint or point,
             x = x or 0, y = y or 0 }
end

function Region:SetPoint(a, b, c, d, e)
    if not a then return end
    local p = parsePoint(a, b, c, d, e)
    -- Setting the same anchor point twice replaces it, as in the real client.
    for i = 1, #self._points do
        if self._points[i].point == p.point then
            self._points[i] = p
            invalidateLayout()
            return
        end
    end
    self._points[#self._points + 1] = p
    invalidateLayout()
end

function Region:ClearAllPoints()
    for i = #self._points, 1, -1 do self._points[i] = nil end
    invalidateLayout()
end

function Region:SetAllPoints(rel)
    rel = rel or self._parent
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", rel, "TOPLEFT", 0, 0)
    self:SetPoint("BOTTOMRIGHT", rel, "BOTTOMRIGHT", 0, 0)
end

function Region:GetPoint(index)
    local p = self._points[index or 1]
    if not p then return nil end
    return p.point, p.rel, p.relPoint, p.x, p.y
end
function Region:GetNumPoints() return #self._points end

local LEFT_POINTS  = { LEFT = true, TOPLEFT = true, BOTTOMLEFT = true }
local RIGHT_POINTS = { RIGHT = true, TOPRIGHT = true, BOTTOMRIGHT = true }

--- Absolute left and right edges, or nil where they cannot be worked out.
--- Memoised per layout epoch; recursion through a cycle yields nil rather than
--- hanging.
local function resolveEdges(region, seen)
    if not region then return nil, nil end
    if region._edgeEpoch == M.layoutEpoch then
        return region._edgeLeft, region._edgeRight
    end
    seen = seen or {}
    if seen[region] then return nil, nil end
    seen[region] = true

    local left, right, centre, fromText
    if region == _G.UIParent or region == _G.WorldFrame then
        left, right = 0, region._w or 1920
    else
        for _, p in ipairs(region._points) do
            local rel = p.rel or region._parent
            local rl, rr = resolveEdges(rel, seen)
            if rl and rr then
                local anchor
                if LEFT_POINTS[p.relPoint] then anchor = rl
                elseif RIGHT_POINTS[p.relPoint] then anchor = rr
                else anchor = rl + (rr - rl) / 2 end

                local at = anchor + p.x
                if LEFT_POINTS[p.point] then left = at
                elseif RIGHT_POINTS[p.point] then right = at
                else centre = at end
            end
        end

        -- One edge (or the centre) plus an explicit width gives the rest.
        local w = region._explicitW
        if not (left and right) and w then
            if left then right = left + w
            elseif right then left = right - w
            elseif centre then left, right = centre - w / 2, centre + w / 2 end
        end

        -- A font string with one anchor and no width takes its other edge from
        -- the text, exactly as the real client does - which is why anchoring a
        -- button to the RIGHT of a bare label works in game. Without this the
        -- chain simply stops here, and everything anchored beyond the label
        -- becomes unresolvable.
        --
        -- Flagged, because a width that came from the text is NOT a width the
        -- layout imposed: the overflow audit has to keep telling those apart.
        if region._kind == "FontString" and not (left and right) then
            local textWidth = region:GetStringWidth()
            if left then right, fromText = left + textWidth, true
            elseif right then left, fromText = right - textWidth, true end
        end
    end

    seen[region] = nil
    region._edgeEpoch = M.layoutEpoch
    region._edgeLeft, region._edgeRight = left, right
    region._edgeFromText = fromText or false
    return left, right
end

--- The width this region actually occupies on screen, worked out from its
--- anchors, falling back to an explicitly set width and finally to the parent.
--- Separate from GetWidth so existing behaviour is untouched.
--- The width the ANCHORS give this region, with no fallbacks. nil means the
--- region has no width of its own - in the real client it would grow to fit its
--- text and draw over whatever is beside it.
function Region:GetAnchoredWidth()
    local left, right = resolveEdges(self)
    -- A width the text supplied is not a width the layout imposed. Reporting it
    -- as one would make every unbounded string look bounded, which is exactly
    -- the failure this audit exists to catch.
    if self._edgeFromText then
        if self._explicitW and self._explicitW > 0 then return self._explicitW end
        return nil
    end
    if left and right and right - left > 1 then return right - left end
    if self._explicitW and self._explicitW > 0 then return self._explicitW end
    return nil
end

function Region:GetResolvedWidth()
    local left, right = resolveEdges(self)
    -- A non-positive span means the anchors could not really be worked out
    -- (a relative frame with no resolvable width of its own, usually). Treat
    -- that as unknown rather than reporting a negative box.
    if left and right and right - left > 1 then return right - left end
    if self._explicitW then return self._explicitW end
    local parent = self._parent
    if parent and parent ~= self then return parent:GetResolvedWidth() end
    return nil
end

function Region:GetLeft() local l = resolveEdges(self) return l end
function Region:GetRight() local _, r = resolveEdges(self) return r end

--- Size is stored rather than discarded: layout code reads it back, and a
--- widget that collapses or grows is only testable if it does.
--- The real client fires OnSizeChanged when a frame is resized, and layout code
--- relies on it. Re-entry is guarded: a handler that resizes its own children
--- is normal, a handler that resizes itself must not recurse forever.
local function fireSizeChanged(region)
    local handler = region._scripts and region._scripts.OnSizeChanged
    if not handler or region._inSizeChanged then return end
    region._inSizeChanged = true
    local ok, err = pcall(handler, region, region._w, region._h)
    region._inSizeChanged = false
    if not ok then geterrorhandler()(err) end
end

function Region:SetWidth(w)
    self._w, self._explicitW = w, w
    invalidateLayout()
    fireSizeChanged(self)
end
function Region:SetHeight(h)
    self._h, self._explicitH = h, h
    invalidateLayout()
    fireSizeChanged(self)
end
function Region:SetSize(w, h)
    self._w, self._h = w, h
    self._explicitW, self._explicitH = w, h
    invalidateLayout()
    fireSizeChanged(self)
end

--- Real geometry where the anchors allow it, which is what layout code in the
--- addon expects. Returning the stored value regardless was its own source of
--- nonsense: widths computed as "parent width minus padding" came out negative
--- because the parent always claimed to be the default 100 wide.
function Region:GetWidth()
    return self:GetResolvedWidth() or self._w
end
function Region:GetHeight() return self._h end
function Region:GetSize() return self._w, self._h end

function Region:GetTop() return self._h end
function Region:GetBottom() return 0 end
--- The centre of a frame, which is how a minimap button works out where the
--- cursor is relative to the minimap.
function Region:GetCenter()
    local left, right = resolveEdges(self)
    local x = (left and right) and (left + (right - left) / 2) or ((self._w or 0) / 2)
    return x, (self._h or 0) / 2
end

function Region:GetEffectiveScale() return 1 end
function Region:GetScale() return 1 end
function Region:GetParent() return self._parent end
function Region:GetName() return self._name end
function Region:GetObjectType() return self._kind end
function Region:SetText(t) self._text = tostring(t or "") end
function Region:SetWordWrap(v) self._wordWrap = v and true or false end
function Region:SetMaxLines(n) self._maxLines = n end
function Region:SetNonSpaceWrap(v) self._nonSpaceWrap = v and true or false end
function Region:GetText() return self._text end
function Region:SetFont(path, size, flags) self._font = { path, size, flags } return true end
function Region:GetFont() return self._font and self._font[1] or "Fonts\\FRIZQT__.TTF" end
--- Colour codes and texture escapes are markup, not glyphs. Measuring them as
--- text made every coloured label look twice as wide as it renders.
local function visibleText(text)
    text = tostring(text or "")
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("|T.-|t", "MM")   -- an inline icon is about two glyphs wide
    return text
end

--- Approximate rendered width. Not the real font metrics - the point is to
--- catch a label that is obviously too long for its box, not to typeset.
function Region:GetStringWidth()
    local size = (self._font and self._font[2]) or 12
    local widest = 0
    for line in (visibleText(self._text) .. "\n"):gmatch("(.-)\n") do
        widest = math.max(widest, #line)
    end
    return widest * size * 0.5
end
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
-- Text overflow audit
--------------------------------------------------------------------------
--
-- The one question a headless harness could never answer before: does this text
-- fit in the box it was given? Two ways it can fail, and they fail differently:
--
--   "clipped"   the string has a resolved width and its text is wider - WoW
--               cuts it off, so the reader loses the end of it.
--   "unbounded" the string has no width of its own and its text is wider than
--               the container it sits in - it does not clip, it draws straight
--               over whatever is next to it. This is the one that produced
--               "text runs into itself" in a real client.
--
-- Wrapping strings are exempt: they grow downwards by design, and their height
-- is bounded by UI.Wrap's line cap.
function M.AuditText(tolerance)
    tolerance = tolerance or 2
    -- A container narrower than this has not really been laid out - a panel on
    -- a page that was never sized, or a detail pane that is still hidden. Text
    -- "overflowing" a 20 px box says nothing about the real UI, and reporting
    -- it would bury the findings that do.
    local MIN_MEANINGFUL_BOX = 60
    local findings = {}
    for _, region in ipairs(M.allFrames) do
        -- Only text somebody can actually see. Auditing hidden text reported
        -- every tooltip line the moment a tooltip had ever been populated -
        -- a tooltip sizes itself to its content, so its lines are unbounded by
        -- design - and that noise is exactly what buries a real finding.
        if region._kind == "FontString" and not region._wordWrap
           and region:IsVisible() then
            local text = region._text or ""
            if text ~= "" then
                local own = region:GetStringWidth()
                -- Anchors only: a fallback to the parent's width would report a
                -- string that has no width of its own as if it had one, which
                -- hides the worse of the two failure modes.
                local box = region:GetAnchoredWidth()
                local parent = region._parent
                local container = parent and parent:GetResolvedWidth()

                if box and box < MIN_MEANINGFUL_BOX then
                    -- not laid out; nothing to say
                elseif box and own > box + tolerance then
                    findings[#findings + 1] = {
                        kind = "clipped", text = text, width = own, box = box, region = region,
                        name = region._name or (parent and parent._name) or "unnamed",
                    }
                elseif not box and container and container >= MIN_MEANINGFUL_BOX
                    and own > container + tolerance then
                    findings[#findings + 1] = {
                        kind = "unbounded", text = text, width = own, box = container, region = region,
                        name = region._name or (parent and parent._name) or "unnamed",
                    }
                end
            end
        end
    end
    return findings
end

--- The span a font string actually paints over.
---
--- Bounded on both sides it is the box, because WoW clips to it. Anchored on
--- one side only it is the anchor plus however wide the text turns out to be -
--- which is the whole problem: nothing stops it.
local function paintedSpan(fs)
    local left, right = resolveEdges(fs)
    local width = fs:GetStringWidth()
    if left and right and right - left > 1 then return left, right end
    if left then return left, left + width end
    if right then return right - width, right end
    return nil
end

--- Sibling font strings that paint over each other.
---
--- Restricted to short parents holding EXACTLY TWO font strings: the label and
--- value shape. That is deliberately narrow. Vertical anchors are not resolved
--- here, so in any richer parent - a graph's axis labels, say - two strings can
--- overlap horizontally while sitting on different lines, and reporting those
--- would bury the real finding in noise.
---
--- This is the check that catches the reported failure directly: a label
--- anchored LEFT and a value anchored RIGHT, neither bounded, growing towards
--- each other until they meet.
function M.AuditTextOverlap(maxRowHeight, tolerance)
    maxRowHeight = maxRowHeight or 30
    tolerance = tolerance or 2
    local findings = {}

    for _, frame in ipairs(M.allFrames) do
        -- An EXPLICIT height, not the default: a panel nobody sized would
        -- otherwise look like a one-line row and every title-above-body pair
        -- in it would be reported as an overlap.
        -- Same guard as AuditText: a row 20 px wide has not been laid out, and
        -- what its children do inside it says nothing about the real UI.
        local rowWidth = frame:GetAnchoredWidth()
        if frame._kind ~= "FontString" and frame._explicitH
            and frame._explicitH <= maxRowHeight and frame:IsShown()
            and rowWidth and rowWidth >= 60 then
            local strings = {}
            for _, child in ipairs(frame._children or {}) do
                if child._kind == "FontString" and child:IsShown()
                    and (child._text or "") ~= "" then
                    local l, r = paintedSpan(child)
                    if l then strings[#strings + 1] = { fs = child, left = l, right = r } end
                end
            end
            if #strings == 2 then
              for i = 1, #strings do
                for j = i + 1, #strings do
                    local a, b = strings[i], strings[j]
                    local overlap = math.min(a.right, b.right) - math.max(a.left, b.left)
                    if overlap > tolerance then
                        findings[#findings + 1] = {
                            overlap = overlap,
                            a = a.fs._text, b = b.fs._text,
                            parent = frame._name or "unnamed row",
                            rowRef = frame,
                        }
                    end
                end
              end
            end
        end
    end
    return findings
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

--------------------------------------------------------------------------
-- Error handler
--------------------------------------------------------------------------
--
-- A real settable handler, not a constant. Chaining one error handler onto
-- another is the whole mechanism behind the error monitor, and a mock that
-- returns a fresh closure every call cannot test it: nothing can observe
-- whether the previous handler was preserved, replaced, or called twice.

M.errors = {}

--- The handler that was in place before anything installed its own. Stands in
--- for the client's built-in one; everything it receives is recorded so a test
--- can assert that a chained handler really did pass the error on.
M.defaultErrorHandler = function(err)
    M.errors[#M.errors + 1] = tostring(err)
    if M.verbose then print("  !! LUA ERROR: " .. tostring(err)) end
end

local currentErrorHandler = M.defaultErrorHandler

function geterrorhandler() return currentErrorHandler end
function seterrorhandler(handler)
    if type(handler) ~= "function" then return end
    currentErrorHandler = handler
end

--- Raises an error the way the client does: straight into whatever handler is
--- installed at this moment.
function M.RaiseError(message)
    currentErrorHandler(message)
end

--- Puts the handler chain back to a bare client, for tests that install their
--- own arrangement.
function M.ResetErrorHandler()
    currentErrorHandler = M.defaultErrorHandler
    for i = #M.errors, 1, -1 do M.errors[i] = nil end
end

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
