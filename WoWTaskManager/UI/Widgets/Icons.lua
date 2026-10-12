--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/Icons.lua

    A small geometric icon system, built from the same WHITE8X8 texture as
    everything else in this addon - no external art, no icon font, no
    borrowed Blizzard atlas textures that might vanish or change meaning in a
    future client patch.

    Each icon is 2-4 flat rectangles inside a fixed box. That is a real
    constraint - it cannot draw a magnifying glass or a folder - so related
    pages deliberately SHARE a shape family (every "a graph lives here" page
    uses the ascending-bars glyph, every "this is a list of records" page
    uses the stacked-rows glyph) rather than each inventing a shape that
    would not read as anything at this size anyway.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI    = WTM.UI
local Theme = UI.Theme

UI.Icons = {}
local Icons = UI.Icons

--- Builds one icon glyph inside a `size` x `size` frame, coloured `colorKey`.
--- `shape` selects which family of rectangles to draw; unknown shapes fall
--- back to a single centred dot rather than drawing nothing, so a typo in a
--- page's icon key is a visible dot, not an invisible bug.
function Icons.Build(parent, shape, size, colorKey)
    size = size or 12
    local icon = CreateFrame("Frame", nil, parent)
    icon:SetSize(size, size)
    icon.pieces = {}

    local function rect(x, y, w, h)
        local tex = icon:CreateTexture(nil, "ARTWORK")
        tex:SetColorTexture(Theme.Get(colorKey or "textSecondary"))
        tex:SetSize(w, h)
        tex:SetPoint("TOPLEFT", icon, "TOPLEFT", x, -y)
        icon.pieces[#icon.pieces + 1] = tex
        return tex
    end

    local s = size
    local build = Icons.SHAPES[shape] or Icons.SHAPES.dot
    build(rect, s)

    --- Recolours every rectangle at once, e.g. when a nav item becomes active.
    function icon:SetColor(key, alpha)
        local r, g, b, a = Theme.Get(key, alpha)
        for _, tex in ipairs(self.pieces) do tex:SetColorTexture(r, g, b, a) end
    end

    return icon
end

-- Every builder receives (rect, size) and places its pieces inside a
-- `size` x `size` box using rect(x, y, w, h) in TOPLEFT-relative pixels.
Icons.SHAPES = {
    -- Dashboard, Session overview: a 2x2 grid, the classic "overview" mark.
    grid = function(rect, s)
        local g, c = s * 0.42, s * 0.16
        rect(0, 0, g, g)
        rect(g + c, 0, g, g)
        rect(0, g + c, g, g)
        rect(g + c, g + c, g, g)
    end,

    -- Processes, Live resources, Performance, Frame analysis: ascending
    -- bars - this addon's own graphs, reduced to three columns.
    bars = function(rect, s)
        local w, gap = s * 0.24, s * 0.12
        rect(0,            s * 0.55, w, s * 0.45)
        rect(w + gap,       s * 0.28, w, s * 0.72)
        rect((w + gap) * 2, 0,        w, s)
    end,

    -- Network: two nodes and the line between them.
    network = function(rect, s)
        local d = s * 0.28
        rect(0, s * 0.36, d, d)
        rect(s - d, 0, d, d)
        rect(0, s * 0.5 - 1, s, 2)
    end,

    -- Events: a pulse - a short-tall-short run, like a heartbeat trace.
    pulse = function(rect, s)
        local w = s * 0.2
        rect(0,             s * 0.4, w, s * 0.2)
        rect(w + 1,         0,       w, s)
        rect((w + 1) * 2,   s * 0.4, w, s * 0.2)
        rect((w + 1) * 3,   s * 0.55, w, s * 0.45)
    end,

    -- Memory: stacked bars, like RAM sticks.
    stack = function(rect, s)
        local h, gap = s * 0.22, s * 0.12
        rect(0, 0,          s, h)
        rect(0, h + gap,     s, h)
        rect(0, (h + gap)*2, s, h)
    end,

    -- Incidents, Alerts: a diamond, this addon's one "notice me" shape.
    diamond = function(rect, s)
        local half = s * 0.5
        local t = s * 0.32
        -- Four small squares set on a point read as a diamond at this size
        -- without needing a rotated texture.
        rect(half - t / 2, 0, t, t)
        rect(0, half - t / 2, t, t)
        rect(s - t, half - t / 2, t, t)
        rect(half - t / 2, s - t, t, t)
    end,

    -- Timeline: a track with three ticks.
    timeline = function(rect, s)
        rect(0, s * 0.5 - 1, s, 2)
        local w = s * 0.14
        rect(s * 0.15, s * 0.2, w, s * 0.6)
        rect(s * 0.5 - w / 2, s * 0.1, w, s * 0.8)
        rect(s * 0.85 - w, s * 0.3, w, s * 0.4)
    end,

    -- Diagnostics, Addon impact, Compare: a target - concentric marks.
    target = function(rect, s)
        rect(0, s * 0.42, s, s * 0.16)
        rect(s * 0.42, 0, s * 0.16, s)
    end,

    -- Lua errors, Reports: a page, narrower than it is tall.
    document = function(rect, s)
        rect(s * 0.2, 0, s * 0.6, s)
    end,

    -- Sessions, Recording: a clock face reduced to a dot and one hand.
    history = function(rect, s)
        local d = s * 0.7
        rect((s - d) / 2, (s - d) / 2, d, d * 0.16)
        rect(s * 0.5 - 1, (s - d) / 2, 2, d * 0.5)
    end,

    -- System, Settings: a gear reduced to a hub and four teeth.
    cog = function(rect, s)
        local hub = s * 0.36
        rect((s - hub) / 2, (s - hub) / 2, hub, hub)
        local t = s * 0.18
        rect((s - t) / 2, 0, t, t)
        rect((s - t) / 2, s - t, t, t)
        rect(0, (s - t) / 2, t, t)
        rect(s - t, (s - t) / 2, t, t)
    end,

    dot = function(rect, s)
        local d = s * 0.4
        rect((s - d) / 2, (s - d) / 2, d, d)
    end,
}
