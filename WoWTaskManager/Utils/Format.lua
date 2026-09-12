--[[--------------------------------------------------------------------------
    WoW Task Manager - Utils/Format.lua
    Display formatting.  Never called from a sampling path - string building
    happens only when the UI is actually visible.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local F = {}
WTM.Format = F

local format, floor, abs = string.format, math.floor, math.abs
local C = WTM.C

--- A number, or nil if this is not one that can be shown.
---
--- Every formatter here already answered "-" for nil. It answered nonsense for
--- the other ways a measurement fails: a rate over zero elapsed seconds is a
--- NaN, a share of an empty total is an infinity, and both went straight to
--- the screen as "-nan KB", "inf %", "infh ago". A player reading that
--- concludes the addon is broken, and is not entirely wrong.
---
--- Anything that is not a number at all used to throw - from inside a page
--- refresh, which is the worst possible place for a formatter to have an
--- opinion about its input. A string that happens to hold digits is accepted
--- because tonumber accepts it and the caller clearly meant a number.
---
--- One gate, at the boundary, so every formatter treats "no usable number" the
--- same way it already treats nil.
local function finite(v)
    v = tonumber(v)
    -- NaN is the only value that is not equal to itself, and the infinities
    -- are the only ones that survive being halved unchanged.
    if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end
F.Finite = finite

--- 1234567 -> "1,234,567"
function F.Comma(n)
    n = floor(finite(n) or 0)
    local sign = n < 0 and "-" or ""
    local s = tostring(abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    return sign .. out
end

--- KB in, human-readable out.  Addon memory comes from the API in KB.
function F.Memory(kb)
    kb = finite(kb)
    if kb == nil then return "-" end
    if abs(kb) >= 1048576 then return format("%.2f GB", kb / 1048576) end
    if abs(kb) >= 1024 then return format("%.1f MB", kb / 1024) end
    if abs(kb) >= 1 then return format("%.0f KB", kb) end
    if kb == 0 then return "0 KB" end
    return format("%.1f KB", kb)
end

function F.MemoryDelta(kb)
    kb = finite(kb)
    if kb == nil then return "-" end
    if abs(kb) < 1 then return "0" end
    local sign = kb > 0 and "+" or "-"
    return sign .. F.Memory(abs(kb))
end

function F.Ms(ms, decimals)
    ms = finite(ms)
    if ms == nil then return "-" end
    return format("%." .. (decimals or 1) .. "f ms", ms)
end

function F.Percent(p, decimals)
    p = finite(p)
    if p == nil then return "-" end
    return format("%." .. (decimals or 1) .. "f %%", p)
end

function F.FPS(fps)
    fps = finite(fps)
    if fps == nil then return "-" end
    if fps >= 100 then return format("%.0f", fps) end
    return format("%.1f", fps)
end

function F.Rate(n)
    n = finite(n)
    if n == nil then return "-" end
    if n >= 1000 then return F.Comma(n) .. "/s" end
    if n >= 10 then return format("%.0f/s", n) end
    return format("%.1f/s", n)
end

--- 3725 -> "1h 02m 05s"
function F.Duration(seconds)
    seconds = floor(finite(seconds) or 0)
    if seconds < 0 then seconds = 0 end
    local h = floor(seconds / 3600)
    local m = floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then return format("%dh %02dm %02ds", h, m, s) end
    if m > 0 then return format("%dm %02ds", m, s) end
    return format("%ds", s)
end

--- Short relative age: "12s ago", "4m ago".
function F.Ago(seconds)
    seconds = finite(seconds)
    if seconds == nil then return "-" end
    if seconds < 1 then return "now" end
    if seconds < 60 then return format("%.0fs ago", seconds) end
    if seconds < 3600 then return format("%.0fm ago", seconds / 60) end
    return format("%.1fh ago", seconds / 3600)
end

--- Timestamp with milliseconds, as used in spike records: "19:42:13.482".
--- `t` is a GetTime() value; sessionEpoch maps it onto wall clock time.
function F.Clock(t, sessionEpoch, sessionStart)
    t = finite(t)
    if not t then return "--:--:--" end
    if sessionEpoch and sessionStart then
        local wall = sessionEpoch + (t - sessionStart)
        local frac = wall - floor(wall)
        return date("%H:%M:%S", floor(wall)) .. format(".%03d", floor(frac * 1000))
    end
    local frac = t - floor(t)
    return format("%s.%03d", date("%H:%M:%S", time()), floor(frac * 1000))
end

function F.DateTime(epoch)
    epoch = finite(epoch)
    if not epoch then return "-" end
    return date("%Y-%m-%d %H:%M", epoch)
end

--- Truncates with an ellipsis, measured in characters (WoW fonts are not
--- monospaced, so the widgets also clamp width; this is a first pass).
function F.Truncate(s, maxChars)
    s = tostring(s or "")
    -- A missing limit used to compare a length against nil and throw. Nothing
    -- to truncate to is not a reason to take a page down.
    maxChars = finite(maxChars)
    if not maxChars or maxChars < 1 then return s end
    if #s <= maxChars then return s end
    if maxChars <= 3 then return s:sub(1, maxChars) end
    return s:sub(1, maxChars - 1) .. "..."
end

--- Strips WoW color escape sequences so sorting and searching work on the
--- actual text.  Addon titles frequently contain |cff....|r.
function F.StripColors(s)
    if type(s) ~= "string" then return s end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    return s
end

function F.Bytes(bytes)
    bytes = finite(bytes)
    if bytes == nil then return "-" end
    return F.Memory(bytes / 1024)
end

--- "12 min ago at 19:42" style label for session lists.
function F.SessionLabel(session)
    if not session then return "-" end
    return format("%s  -  %s (%s)",
        F.DateTime(session.startedAt),
        session.character or "?",
        F.Duration(session.duration or 0))
end

--- Signed number with an explicit plus, used for deltas in tables.
function F.Signed(v, decimals, unit)
    v = finite(v)
    if v == nil then return "-" end
    local s = format("%+." .. (decimals or 1) .. "f", v)
    return unit and (s .. " " .. unit) or s
end
