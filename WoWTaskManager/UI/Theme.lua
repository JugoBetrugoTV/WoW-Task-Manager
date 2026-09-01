--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Theme.lua

    Every colour, font and spacing value in the addon comes from here.  No UI
    file hardcodes a hex value.

    The palette is deliberately desaturated: near-black greys, one blue accent,
    and a green/amber/red trio reserved exclusively for status.  Series colours
    for graphs are muted and staggered in lightness so they stay apart from
    each other without any of them shouting.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local Color = WTM.Color

WTM.UI = WTM.UI or {}
local Theme = {}
WTM.UI.Theme = Theme

--------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------

local HEX = {
    windowBg   = "0F1115",
    sidebarBg  = "0B0D11",
    topbarBg   = "12151B",
    panelBg    = "161A21",
    panelAlt   = "1B2029",
    elevated   = "212733",
    hover      = "222834",
    selected   = "1D2634",

    borderSubtle = "252B36",
    borderStrong = "323A48",

    textPrimary   = "E6E9EF",
    textSecondary = "9AA4B5",
    textMuted     = "5D6675",
    textInverse   = "0F1115",

    accent     = "4C8DFF",
    accentDim  = "2E5DAA",
    accentSoft = "1C2B45",

    ok    = "3FB950",
    warn  = "D29922",
    crit  = "F0533F",
    info  = "5AB0C9",
}

Theme.hex = HEX

-- Graph series: blue, teal, violet, amber, rose, green, slate, copper.
local SERIES_HEX = {
    "4C8DFF", "38B2AC", "9B7BD4", "D29922",
    "E06C75", "56A46B", "7A8699", "C08457",
}

local cache = {}
local function C4(key, alpha)
    local entry = cache[key]
    if not entry then
        local r, g, b = Color.FromHex(HEX[key] or key)
        entry = { r, g, b }
        cache[key] = entry
    end
    return entry[1], entry[2], entry[3], alpha or 1
end
Theme.Get = C4

function Theme:Series(index)
    local hex = SERIES_HEX[((index - 1) % #SERIES_HEX) + 1]
    return Color.FromHex(hex)
end

function Theme:SeriesHex(index)
    return SERIES_HEX[((index - 1) % #SERIES_HEX) + 1]
end

--- Maps the tone names used throughout the data layer onto colours, so a
--- module can say tone = "warn" without knowing anything about the palette.
function Theme:Tone(tone, alpha)
    if tone == "ok" then return C4("ok", alpha)
    elseif tone == "warn" then return C4("warn", alpha)
    elseif tone == "crit" then return C4("crit", alpha)
    elseif tone == "accent" then return C4("accent", alpha)
    elseif tone == "muted" then return C4("textMuted", alpha)
    elseif tone == "info" then return C4("info", alpha)
    end
    return C4("textSecondary", alpha)
end

function Theme:ToneHex(tone)
    if tone == "ok" then return HEX.ok
    elseif tone == "warn" then return HEX.warn
    elseif tone == "crit" then return HEX.crit
    elseif tone == "accent" then return HEX.accent
    elseif tone == "muted" then return HEX.textMuted
    elseif tone == "info" then return HEX.info end
    return HEX.textSecondary
end

--------------------------------------------------------------------------
-- Metrics
--------------------------------------------------------------------------

Theme.metrics = {
    topbarHeight   = 56,
    sidebarWidth   = 200,
    padding        = 16,
    paddingSmall   = 8,
    paddingTight   = 4,
    rowHeight      = 26,
    headerHeight   = 28,
    cardHeight     = 92,
    cardGap        = 12,
    navItemHeight  = 34,
    borderSize     = 1,
    scrollbarWidth = 6,
}

--------------------------------------------------------------------------
-- Fonts
--------------------------------------------------------------------------
-- The client ships a small set of fonts and none of them can be replaced
-- without shipping a font file.  Arial Narrow is used for numbers because a
-- dashboard full of digits wants a condensed face; Friz Quadrata handles
-- labels because it is the one font guaranteed to have full glyph coverage
-- for every locale the client supports.

local FONT_NUMERIC = "Fonts\\ARIALN.TTF"
local FONT_TEXT    = "Fonts\\FRIZQT__.TTF"

-- Some locales (Korean, Chinese, Russian on older clients) ship different
-- files; if the numeric face fails to apply we fall back to the text face
-- rather than ending up with an invisible font string.
local function ApplyFont(fontString, path, size, flags)
    if not fontString.SetFont then return end
    local ok = pcall(fontString.SetFont, fontString, path, size, flags)
    if not ok or not fontString:GetFont() then
        pcall(fontString.SetFont, fontString, FONT_TEXT, size, flags)
    end
end

Theme.fonts = {
    display   = { path = FONT_NUMERIC, size = 30, flags = "" },
    metric    = { path = FONT_NUMERIC, size = 22, flags = "" },
    numeric   = { path = FONT_NUMERIC, size = 12, flags = "" },
    numericSm = { path = FONT_NUMERIC, size = 11, flags = "" },
    title     = { path = FONT_TEXT,    size = 15, flags = "" },
    heading   = { path = FONT_TEXT,    size = 12, flags = "" },
    body      = { path = FONT_TEXT,    size = 12, flags = "" },
    small     = { path = FONT_TEXT,    size = 11, flags = "" },
    tiny      = { path = FONT_TEXT,    size = 10, flags = "" },
}

function Theme:SetFont(fontString, style, colorKey, alpha)
    local font = self.fonts[style] or self.fonts.body
    ApplyFont(fontString, font.path, font.size, font.flags)
    if colorKey then
        fontString:SetTextColor(C4(colorKey, alpha))
    end
    return fontString
end

--------------------------------------------------------------------------
-- Texture helpers
--------------------------------------------------------------------------

-- Solid white 8x8, the standard building block for flat fills.
Theme.WHITE = "Interface\\Buttons\\WHITE8X8"

--- SetGradient changed signature in Retail 10.0 (it now takes colour objects
--- instead of eight numbers) while SetGradientAlpha was removed.  Both shapes
--- exist across the four target clients, so this resolves once and caches.
local gradientMode
function Theme:SetGradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
    if gradientMode == nil then
        if texture.SetGradient and _G.CreateColor then
            local ok = pcall(texture.SetGradient, texture, "VERTICAL",
                CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0))
            gradientMode = ok and "modern" or false
        end
        if gradientMode == nil then
            gradientMode = texture.SetGradientAlpha and "legacy" or false
        end
    end

    if gradientMode == "modern" then
        pcall(texture.SetGradient, texture, orientation,
            CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    elseif gradientMode == "legacy" then
        pcall(texture.SetGradientAlpha, texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
    else
        -- No gradient support: a flat mid-tone reads better than nothing.
        texture:SetColorTexture((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

--- Lines (frame:CreateLine) exist on every modern-engine client, but the graph
--- engine has a column fallback for anything that lacks them.
function Theme:SupportsLines(frame)
    if self._supportsLines == nil then
        self._supportsLines = type(frame.CreateLine) == "function"
    end
    return self._supportsLines
end

return Theme
