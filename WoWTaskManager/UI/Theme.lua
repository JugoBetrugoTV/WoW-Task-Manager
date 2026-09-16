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
    -- A second accent, independent of the picker below, for anything that
    -- needs to sit next to the primary accent without competing with it
    -- (a secondary series highlight, a "compare" state).
    accentSecondary = "38B2AC",

    ok    = "3FB950",
    warn  = "D29922",
    crit  = "F0533F",
    info  = "5AB0C9",

    -- Fainter than borderSubtle: the minor grid lines between the major ones
    -- on a graph, which must read as texture rather than as more lines.
    gridMinor = "1B2029",
}

Theme.hex = HEX

--------------------------------------------------------------------------
-- Theme presets and accents
--------------------------------------------------------------------------
-- One layout, several palettes: switching a preset never moves a widget, it
-- only recolours the same design tokens above. Each preset defines every
-- surface/text/status key so switching back and forth is always a full,
-- deterministic replace rather than a patch on top of whatever was there.
--
-- The accent is a second, independent axis (it only ever touches the three
-- accent* keys) so "Midnight + Orange" and "Graphite + Cyan" are both valid
-- combinations without a 4x5 table of palettes.

Theme.PALETTES = {
    {
        key = "wtmdark", label = "WTM Dark",
        hex = {
            windowBg = "0F1115", sidebarBg = "0B0D11", topbarBg = "12151B",
            panelBg = "161A21", panelAlt = "1B2029", elevated = "212733",
            hover = "222834", selected = "1D2634",
            borderSubtle = "252B36", borderStrong = "323A48",
            textPrimary = "E6E9EF", textSecondary = "9AA4B5",
            textMuted = "5D6675", textInverse = "0F1115",
            ok = "3FB950", warn = "D29922", crit = "F0533F", info = "5AB0C9",
            gridMinor = "1B2029",
        },
    },
    {
        key = "graphite", label = "Graphite",
        hex = {
            windowBg = "121212", sidebarBg = "0E0E0E", topbarBg = "161616",
            panelBg = "1C1C1C", panelAlt = "222222", elevated = "292929",
            hover = "2A2A2A", selected = "262626",
            borderSubtle = "2C2C2C", borderStrong = "3A3A3A",
            textPrimary = "E8E8E8", textSecondary = "A0A0A0",
            textMuted = "707070", textInverse = "121212",
            ok = "45B96A", warn = "D2A03A", crit = "E85C4A", info = "5FB4CC",
            gridMinor = "202020",
        },
    },
    {
        key = "midnight", label = "Midnight",
        hex = {
            windowBg = "090B10", sidebarBg = "060810", topbarBg = "0C0F16",
            panelBg = "111726", panelAlt = "151C2E", elevated = "1B2438",
            hover = "1D2740", selected = "1A2438",
            borderSubtle = "1E2740", borderStrong = "2A3652",
            textPrimary = "E4E9F5", textSecondary = "92A0BF",
            textMuted = "566079", textInverse = "090B10",
            ok = "3FC172", warn = "D8A431", crit = "F0594A", info = "5FBEDD",
            gridMinor = "18213A",
        },
    },
    {
        key = "highcontrast", label = "High Contrast",
        hex = {
            windowBg = "000000", sidebarBg = "000000", topbarBg = "060606",
            panelBg = "0A0A0A", panelAlt = "121212", elevated = "1A1A1A",
            hover = "1E1E1E", selected = "202020",
            borderSubtle = "3A3A3A", borderStrong = "707070",
            textPrimary = "FFFFFF", textSecondary = "D8D8D8",
            textMuted = "9A9A9A", textInverse = "000000",
            ok = "4CD964", warn = "E5A00D", crit = "FF4433", info = "5FD0F0",
            gridMinor = "2A2A2A",
        },
    },
}

Theme.ACCENTS = {
    { key = "blue",   label = "Blue",   hex = { accent = "4C8DFF", accentDim = "2E5DAA", accentSoft = "1C2B45" } },
    { key = "cyan",   label = "Cyan",   hex = { accent = "33C2D9", accentDim = "1F7A8A", accentSoft = "122C33" } },
    { key = "green",  label = "Green",  hex = { accent = "3FB966", accentDim = "26703E", accentSoft = "152A1D" } },
    { key = "orange", label = "Orange", hex = { accent = "E08A3C", accentDim = "8A5426", accentSoft = "2E2013" } },
    { key = "purple", label = "Purple", hex = { accent = "9B7BD4", accentDim = "5F4C8A", accentSoft = "241D33" } },
}

Theme.PALETTE_BY_KEY, Theme.ACCENT_BY_KEY = {}, {}
for _, p in ipairs(Theme.PALETTES) do Theme.PALETTE_BY_KEY[p.key] = p end
for _, a in ipairs(Theme.ACCENTS) do Theme.ACCENT_BY_KEY[a.key] = a end

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

--- Frame-time threshold zones (GOOD / ELEVATED / POOR / STUTTER), reusing the
--- real severity tones rather than a fourth colour axis nobody asked for.
--- ELEVATED is POOR's tone at half the alpha, so the bands read as one
--- worsening gradient rather than four unrelated colours.
local ZONE_ALPHA = { good = 0, elevated = 0.05, poor = 0.07, stutter = 0.10 }
local ZONE_TONE  = { good = "ok", elevated = "warn", poor = "warn", stutter = "crit" }
function Theme:Zone(kind, alphaOverride)
    local tone = ZONE_TONE[kind] or "muted"
    return C4(tone, alphaOverride or ZONE_ALPHA[kind] or 0.06)
end

--- Rewrites the palette/accent tokens in place and drops the colour cache, so
--- every already-created FontString or texture that reads through Theme.Get
--- picks up the new colours on its next SetTextColor/SetColorTexture call.
---
--- This does NOT repaint anything by itself - colours baked into a texture at
--- Build() time (most of them) stay as they were until the widget redraws or
--- the UI reloads. That is why the settings page marks this "takes effect
--- after /reload", the same convention already used for the CPU-profiling
--- CVar: a live full repaint would mean auditing every widget for whether it
--- re-reads its colour every frame, and none of them do, on purpose.
function Theme:ApplyPreset(paletteKey, accentKey)
    local palette = self.PALETTE_BY_KEY[paletteKey] or self.PALETTE_BY_KEY.wtmdark
    local accent  = self.ACCENT_BY_KEY[accentKey] or self.ACCENT_BY_KEY.blue
    for k, v in pairs(palette.hex) do HEX[k] = v end
    for k, v in pairs(accent.hex) do HEX[k] = v end
    for k in pairs(cache) do cache[k] = nil end
    self.currentPalette, self.currentAccent = palette.key, accent.key
end

--- Reads the saved theme/accent choice and applies it. Safe to call before
--- the profile exists (falls back to the defaults both tables already are).
function Theme:ApplyFromProfile()
    local ui = WTM.db and WTM.db.profile and WTM.db.profile.ui
    self:ApplyPreset(ui and ui.theme, ui and ui.accent)
    self:ApplyDensity(ui and ui.density)
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
    -- Below this a metric card is not a card any more: the heading trims to
    -- "UNIQ...", the sublabel to "every o...", and six unreadable boxes in a
    -- row tell the reader less than three readable ones over two rows.
    cardMinWidth   = 150,
    -- A list-or-detail side column: a share of the page, never narrower than
    -- a readable list row nor wider than it needs to be. Eight pages carried
    -- eight different fixed widths for this before.
    sideColumnFraction = 0.26,
    sideColumnMin      = 250,
    sideColumnMax      = 400,
    navItemHeight  = 28,
    borderSize     = 1,
    scrollbarWidth = 6,
}

-- Snapshot of the comfortable values above, so Compact can be re-derived from
-- them instead of drifting further from "comfortable" every time it is
-- applied twice.
local BASE_METRICS = {}
for k, v in pairs(Theme.metrics) do BASE_METRICS[k] = v end

-- Rows are what Compact is actually for: Processes, Events, Errors and
-- Sessions are lists, and a list is where density is felt. Sizing tokens
-- that are not about row rhythm (side column widths, card min width) are
-- left alone - a narrower side column would clip the same list this is
-- trying to show more of.
local COMPACT_METRICS = {
    padding = 12, paddingSmall = 6, rowHeight = 20, headerHeight = 22,
    cardHeight = 78, cardGap = 8, navItemHeight = 22,
}

--- Same "bake at build time, apply after reload" rule as ApplyPreset: this
--- resets every widget-sizing token, but only widgets built AFTER the call
--- read the new values.
function Theme:ApplyDensity(density)
    for k, v in pairs(BASE_METRICS) do self.metrics[k] = v end
    if density == "compact" then
        for k, v in pairs(COMPACT_METRICS) do self.metrics[k] = v end
    end
    self.currentDensity = (density == "compact") and "compact" or "comfortable"
end

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
