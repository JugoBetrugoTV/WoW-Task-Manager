--[[--------------------------------------------------------------------------
    WoW Task Manager - Utils/Color.lua
    Color helpers.  The palette itself lives in UI/Theme.lua; this file only
    knows how to manipulate colors.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local Color = {}
WTM.Color = Color

local format, floor = string.format, math.floor
local band, rshift = bit.band, bit.rshift

--- "#4C8DFF" or "4C8DFF" -> r, g, b in 0..1
function Color.FromHex(hex)
    hex = hex:gsub("^#", "")
    local n = tonumber(hex, 16) or 0
    if #hex <= 6 then
        return band(rshift(n, 16), 255) / 255,
               band(rshift(n, 8), 255) / 255,
               band(n, 255) / 255, 1
    end
    return band(rshift(n, 24), 255) / 255,
           band(rshift(n, 16), 255) / 255,
           band(rshift(n, 8), 255) / 255,
           band(n, 255) / 255
end

function Color.ToHex(r, g, b)
    return format("%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

--- Wraps text in a WoW color escape sequence.
function Color.Wrap(text, r, g, b)
    return format("|cff%s%s|r", Color.ToHex(r, g, b), tostring(text))
end

function Color.Mix(r1, g1, b1, r2, g2, b2, t)
    return r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t
end

--- Green -> amber -> red ramp for load-style values.
--- `v` is normalized 0..1 where 1 is "bad".
function Color.LoadRamp(v)
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    if v < 0.5 then
        return Color.Mix(0.247, 0.725, 0.314, 0.824, 0.600, 0.133, v * 2)
    end
    return Color.Mix(0.824, 0.600, 0.133, 0.941, 0.325, 0.247, (v - 0.5) * 2)
end

function Color.Dim(r, g, b, factor)
    return r * factor, g * factor, b * factor
end
