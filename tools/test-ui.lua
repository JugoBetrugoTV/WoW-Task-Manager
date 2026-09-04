-- UI stress test.
--
-- Every page, at three window sizes, put through what a player does to it:
-- open, refresh, resize, scroll, hover, click, right-click, switch away,
-- close and reopen. After each one the same questions are asked:
--
--   * is anything drawn outside the content area, over the sidebar, the
--     topbar or the footer?
--   * did a tooltip, a menu or a dialog survive something that should have
--     dismissed it?
--   * is any widget on a page not a descendant of that page?
--   * did anything throw?
--
-- Written after a real client showed one page drawn over three others, which
-- no test at the time could see.
--
--   lua5.1 tools/test-ui.lua

package.path = "./tools/?.lua;" .. package.path
local mock = require("wowmock")

function GetBuildInfo() return "12.1.0", "60000", "Feb 10 2026", 120100 end
WOW_PROJECT_ID = 1
mock.knownEvents = nil

local ADDONS = {
    { "WoWTaskManager", "WoW Task Manager", "0.2.0", true },
    { "WeakAuras", "WeakAuras", "5.20.1", true },
}
local cpuCounters, memValues = { 0, 0 }, { 500, 900 }
C_AddOns = {
    GetNumAddOns = function() return #ADDONS end,
    GetAddOnInfo = function(i)
        local a = type(i) == "number" and ADDONS[i]
        if not a then for _, e in ipairs(ADDONS) do if e[1] == i then a = e end end end
        if not a then return nil end
        return a[1], a[2], "notes", true, nil, "INSECURE"
    end,
    GetAddOnMetadata = function(i, f)
        local a = type(i) == "number" and ADDONS[i]
        if a and f == "Version" then return a[3] end
        return nil
    end,
    IsAddOnLoaded = function() return true end,
    IsAddOnLoadOnDemand = function() return false end,
    GetAddOnEnableState = function() return 2 end,
    GetAddOnDependencies = function() return nil end,
    GetAddOnOptionalDependencies = function() return nil end,
    LoadAddOn = function() return true end,
    EnableAddOn = function() return true end,
    DisableAddOn = function() return true end,
}
local cvars = { scriptProfile = "1", maxFPS = "0", maxFPSBk = "30", vsync = "0" }
C_CVar = {
    GetCVar = function(n) return cvars[n] end,
    SetCVar = function(n, v) cvars[n] = tostring(v) return true end,
    GetCVarBool = function(n) return cvars[n] == "1" end,
    GetCVarDefault = function(n) return cvars[n] end,
    GetCVarInfo = function(n)
        if cvars[n] == nil then return nil end
        return cvars[n], cvars[n], false, false, false, false, false
    end,
}
GetCVar, SetCVar = C_CVar.GetCVar, C_CVar.SetCVar
GetCVarBool, GetCVarDefault, GetCVarInfo = C_CVar.GetCVarBool, C_CVar.GetCVarDefault, C_CVar.GetCVarInfo
C_Timer = { After = function() end }
function UpdateAddOnCPUUsage()
    for i = 1, #ADDONS do cpuCounters[i] = cpuCounters[i] + math.random() * 4 end
end
function GetAddOnCPUUsage(i) return cpuCounters[i] or 0 end
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage(i) return memValues[i] or 0 end
function ResetCPUUsage() end
function GetScriptCPUUsage() return 0 end
function GetEventCPUUsage() return 10, 100 end
function GetFrameCPUUsage() return 1, 10 end
function GetFunctionCPUUsage() return 0, 0 end

local NS = {}
local xml = assert(io.open("WoWTaskManager/Includes.xml"))
for line in xml:lines() do
    local path = line:match('<Script file="([^"]+)"')
    if path then assert(loadfile("WoWTaskManager/" .. path:gsub("\\", "/")))("WoWTaskManager", NS) end
end
xml:close()


local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print(("   FAIL  %s  (%s)"):format(name, tostring(detail))) end
end

WoWTaskManagerDB = nil
mock.Fire("ADDON_LOADED", "WoWTaskManager")
mock.Fire("PLAYER_LOGIN")

local MW = NS.UI.MainWindow
MW:Open()

-- Give the addon something to draw. An empty session hides most layout bugs,
-- because a card with "-" in it fits anywhere.
NS.db.profile.dev.enabled = true
for i = 1, 40 do
    NS.Dev:InjectFrameSpike(60 + (i % 7) * 40)
    NS.Errors:Record(("Interface/AddOns/Addon%d/File.lua:%d: a failure with a reasonably long message"):format(i % 9, i), nil, false)
    mock.Advance(0.4)
end
NS.Context:AddMarker("custom", "a marker")

local SIZES = {
    { name = "minimum", w = 940,  h = 600  },
    { name = "normal",  w = 1280, h = 800  },
    { name = "large",   w = 1920, h = 1080 },
}

--------------------------------------------------------------------------
-- Bounds: nothing may be drawn outside the content area
--------------------------------------------------------------------------
-- The content area is the box between the sidebar, the topbar and the bottom
-- of the window. A page widget outside it is over the navigation or over the
-- game, and in WoW nothing stops that on its own.

local function boundsViolations()
    local content = MW.frame.content
    local cl, cr = content:GetLeft(), content:GetRight()
    local bad = {}
    -- Horizontal only. The harness resolves horizontal anchors; GetTop and
    -- GetBottom are stubs, so a vertical check here would be asserting on
    -- fiction. Vertical overflow remains something only the real client shows.
    if not cl or not cr then return bad end

    local page = NS.UI.Pages[MW.currentPage]
    if not page or not page.frame then return bad end

    local function walk(frame, depth)
        if depth > 8 or not frame:IsShown() then return end
        for _, child in ipairs(frame._children or {}) do
            if child:IsShown() then
                local l, r = child:GetLeft(), child:GetRight()
                -- Only judge something that actually resolved to a box.
                if l and r and (r - l) > 8 then
                    if l < cl - 2 or r > cr + 2 then
                        bad[#bad + 1] = ("%s [%.0f..%.0f] outside [%.0f..%.0f]")
                            :format(child._kind or "?", l, r, cl, cr)
                    end
                end
                walk(child, depth + 1)
            end
        end
    end
    walk(page.frame, 0)
    return bad
end

--------------------------------------------------------------------------
-- Leftovers: menus, dialogs, overlays and tooltips
--------------------------------------------------------------------------

local function leftovers()
    local open = {}
    if NS.UI.IsContextMenuShown() then open[#open + 1] = "context menu" end
    if _G.WTMCopyBox and _G.WTMCopyBox:IsShown() then open[#open + 1] = "copy box" end
    if NS.UI.AddonDetail.scrim and NS.UI.AddonDetail.scrim:IsShown() then
        open[#open + 1] = "addon detail"
    end
    if NS.UI.ErrorDetail.scrim and NS.UI.ErrorDetail.scrim:IsShown() then
        open[#open + 1] = "error detail"
    end
    return table.concat(open, ", ")
end

--------------------------------------------------------------------------

local worstBounds, worstBoundsWhere = 0, ""
local overlapWorst, overlapWhere = 0, ""
local unboundedWorst, unboundedWhere = 0, ""
local errorsBefore = #mock.errors

for _, size in ipairs(SIZES) do
    print(("\n== %s (%d x %d) =="):format(size.name, size.w, size.h))
    MW.frame:SetSize(size.w, size.h)
    MW:LayoutAllPages()

    for _, key in ipairs(NS.UI.pageOrder) do
        MW:ShowPage(key)
        MW:LayoutPage(key)
        MW:RefreshCurrentPage()

        -- Bounds
        local bad = boundsViolations()
        if #bad > worstBounds then
            worstBounds, worstBoundsWhere = #bad, ("%s/%s: %s"):format(size.name, key, bad[1])
        end

        -- Text geometry
        local findings = mock.AuditText()
        local unbounded = 0
        for _, f in ipairs(findings) do
            if f.kind == "unbounded" then unbounded = unbounded + 1 end
        end
        if unbounded > unboundedWorst then
            unboundedWorst = unbounded
            unboundedWhere = ("%s/%s: %q"):format(size.name, key, findings[1] and findings[1].text:sub(1, 40) or "")
        end

        local overlaps = mock.AuditTextOverlap()
        if #overlaps > overlapWorst then
            overlapWorst = #overlaps
            overlapWhere = ("%s/%s: %q over %q"):format(size.name, key,
                overlaps[1].a:sub(1, 24), overlaps[1].b:sub(1, 24))
        end

        -- Hover every frame, then leave every frame. A tooltip still up after
        -- the mouse has left everything is a leak.
        mock.FireScriptOnAll("OnEnter")
        mock.FireScriptOnAll("OnLeave")

        -- Scroll, both directions, past both ends.
        mock.FireScriptOnAll("OnMouseWheel", -1)
        mock.FireScriptOnAll("OnMouseWheel", 1)

        MW:RefreshCurrentPage()
    end

    check(("%s: nothing is drawn outside the content area"):format(size.name),
        worstBounds == 0, worstBoundsWhere)
    check(("%s: no text escapes its box"):format(size.name),
        unboundedWorst == 0, unboundedWhere)
    check(("%s: no two labels collide on a row"):format(size.name),
        overlapWorst == 0, overlapWhere)
    worstBounds, unboundedWorst, overlapWorst = 0, 0, 0
end

check("nothing threw during the sweep", #mock.errors == errorsBefore,
    (#mock.errors - errorsBefore) .. " errors")
for i = errorsBefore + 1, math.min(#mock.errors, errorsBefore + 5) do
    print("      " .. mock.errors[i])
end

--------------------------------------------------------------------------
print("\n== transient UI does not survive anything ==")
--------------------------------------------------------------------------

MW.frame:SetSize(1280, 800)
MW:ShowPage("processes")

mock.FireScriptOnAll("OnEnter")
check("hovering shows a tooltip at all", NS.UI.IsTooltipShown(),
    "nothing showed one, so the checks below prove nothing")
mock.FireScriptOnAll("OnLeave")
check("leaving dismisses it", not NS.UI.IsTooltipShown())

mock.FireScriptOnAll("OnEnter")
MW:ShowPage("network")
check("a page change dismisses it", not NS.UI.IsTooltipShown())

mock.FireScriptOnAll("OnEnter")
MW:Close()
check("closing the window dismisses it", not NS.UI.IsTooltipShown())
MW:Open()

NS.UI.ShowContextMenu(MW.frame, { { label = "x", onClick = function() end } }, "t")
MW:ShowPage("memory")
check("a context menu does not survive a page change", leftovers() == "", leftovers())

NS.UI.ShowContextMenu(MW.frame, { { label = "x", onClick = function() end } }, "t")
MW:Close()
check("nor the window closing", leftovers() == "", leftovers())
MW:Open()

NS.UI.ShowCopyBox("text", "title")
MW:ShowPage("events")
check("nor does a copy box", leftovers() == "", leftovers())

--------------------------------------------------------------------------
print("\n== clicking everything, on every page ==")
--------------------------------------------------------------------------

local clickErrors = #mock.errors
for _, key in ipairs(NS.UI.pageOrder) do
    MW:ShowPage(key)
    MW:RefreshCurrentPage()
    mock.FireScriptOnAll("OnClick")
    mock.FireScriptOnAll("OnMouseUp", "RightButton")
    -- Whatever that opened must not outlive the switch to the next page.
    MW:RefreshCurrentPage()
end
MW:ShowPage("dashboard")
check("no click handler threw", #mock.errors == clickErrors,
    (#mock.errors - clickErrors) .. " errors")
for i = clickErrors + 1, math.min(#mock.errors, clickErrors + 5) do
    print("      " .. mock.errors[i])
end
check("nothing was left open by the click sweep", leftovers() == "", leftovers())

--------------------------------------------------------------------------
print("\n== close, reopen, resize while closed ==")
--------------------------------------------------------------------------

MW:ShowPage("timeline")
MW:Close()
MW.frame:SetSize(940, 600)
MW:LayoutAllPages()
MW:Open()
MW:RefreshCurrentPage()
check("reopening after a resize while closed lands on a laid-out page",
    #boundsViolations() == 0, (boundsViolations())[1])
check("and only one page is showing", (function()
    local n = 0
    for _, k in ipairs(NS.UI.pageOrder) do
        local p = NS.UI.Pages[k]
        if p.frame and p.frame:IsShown() then n = n + 1 end
    end
    return n == 1
end)())

--------------------------------------------------------------------------
print(("\n   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(6, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
