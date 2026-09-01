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

--- 1234567 -> "1,234,567"
function F.Comma(n)
    n = floor(n or 0)
    local sign = n < 0 and "-" or ""
    local s = tostring(abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    return sign .. out
end

--- KB in, human-readable out.  Addon memory comes from the API in KB.
function F.Memory(kb)
    if kb == nil then return "-" end
    if abs(kb) >= 1048576 then return format("%.2f GB", kb / 1048576) end
    if abs(kb) >= 1024 then return format("%.1f MB", kb / 1024) end
    if abs(kb) >= 1 then return format("%.0f KB", kb) end
    if kb == 0 then return "0 KB" end
    return format("%.1f KB", kb)
end

function F.MemoryDelta(kb)
    if kb == nil then return "-" end
    if abs(kb) < 1 then return "0" end
    local sign = kb > 0 and "+" or "-"
    return sign .. F.Memory(abs(kb))
end

function F.Ms(ms, decimals)
    if ms == nil then return "-" end
    return format("%." .. (decimals or 1) .. "f ms", ms)
end

function F.Percent(p, decimals)
    if p == nil then return "-" end
    return format("%." .. (decimals or 1) .. "f %%", p)
end

function F.FPS(fps)
    if fps == nil then return "-" end
    if fps >= 100 then return format("%.0f", fps) end
    return format("%.1f", fps)
end

function F.Rate(n)
    if n == nil then return "-" end
    if n >= 1000 then return F.Comma(n) .. "/s" end
    if n >= 10 then return format("%.0f/s", n) end
    return format("%.1f/s", n)
end

--- 3725 -> "1h 02m 05s"
function F.Duration(seconds)
    seconds = floor(seconds or 0)
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
    if seconds == nil then return "-" end
    if seconds < 1 then return "now" end
    if seconds < 60 then return format("%.0fs ago", seconds) end
    if seconds < 3600 then return format("%.0fm ago", seconds / 60) end
    return format("%.1fh ago", seconds / 3600)
end

--- Timestamp with milliseconds, as used in spike records: "19:42:13.482".
--- `t` is a GetTime() value; sessionEpoch maps it onto wall clock time.
function F.Clock(t, sessionEpoch, sessionStart)
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
    if not epoch then return "-" end
    return date("%Y-%m-%d %H:%M", epoch)
end

--- Truncates with an ellipsis, measured in characters (WoW fonts are not
--- monospaced, so the widgets also clamp width; this is a first pass).
function F.Truncate(s, maxChars)
    s = tostring(s or "")
    if #s <= maxChars then return s end
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
    return F.Memory((bytes or 0) / 1024)
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
    if v == nil then return "-" end
    local s = format("%+." .. (decimals or 1) .. "f", v)
    return unit and (s .. " " .. unit) or s
end
