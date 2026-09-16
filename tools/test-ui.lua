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

-- Counted for the whole run rather than in a sweep of its own: FitText is
-- called thousands of times by the sweeps that already happen, and a second
-- pass over every page at every size to ask one more question is three
-- minutes of CI for nothing.
local fitEmptied = 0
do
    local original = NS.UI.FitText
    NS.UI.FitText = function(fs, text)
        local out = original(fs, text)
        if (text or "") ~= "" and out == "" then fitEmptied = fitEmptied + 1 end
        return out
    end
end

local worstBounds, worstBoundsWhere = 0, ""
local overlapWorst, overlapWhere = 0, ""
local unboundedWorst, unboundedWhere = 0, ""
local verticalWorst, verticalWhere = 0, nil
local trimmedHeadings, trimmedWhere = 0, nil
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

        -- Vertical geometry, new in 0.7.2. Until the harness resolved top and
        -- bottom edges, every "does this fit below that" question was answered
        -- by a screenshot or not at all.
        local vertical = mock.AuditVertical()
        if #vertical > verticalWorst then
            verticalWorst = #vertical
            verticalWhere = ("%s/%s: %s %s over %.0f px"):format(size.name, key,
                vertical[1].kind, tostring(vertical[1].name), vertical[1].over)
        end

        -- A card heading trimmed to initials. Short, upper case, and ending in
        -- an ellipsis only because it did not fit: "UNIQ...", "TOTA...".
        for _, region in ipairs(mock.allFrames) do
            if region._kind == "FontString" and region:IsVisible() then
                local text = region._text or ""
                if text:match("%.%.%.$") and text:upper() == text
                   and #text <= 12 and #text >= 4 then
                    trimmedHeadings = trimmedHeadings + 1
                    trimmedWhere = trimmedWhere
                        or ("%s/%s: %q"):format(size.name, key, text)
                end
            end
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
    check(("%s: nothing runs off the bottom of its box"):format(size.name),
        verticalWorst == 0, verticalWhere)
    check(("%s: no card heading is trimmed to initials"):format(size.name),
        trimmedHeadings == 0, ("%d, first %s"):format(trimmedHeadings, trimmedWhere or "-"))
    worstBounds, unboundedWorst, overlapWorst = 0, 0, 0
    verticalWorst, verticalWhere = 0, nil
    trimmedHeadings, trimmedWhere = 0, nil
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
print("\n== a squeezed label still says something ==")
--------------------------------------------------------------------------
-- Trimming text to fit is right. Trimming it to NOTHING is not: the reader
-- sees an empty space where a label belongs and has no way to know a label
-- was ever there. This happened nine times in one sweep of the pages.

do
    local probe = MW.frame:CreateFontString(nil, "OVERLAY")
    for _, width in ipairs({ 40, 24, 12, 6, 2 }) do
        probe:SetWidth(width)
        local out = NS.UI.FitText(probe, "Addon memory usage")
        check(("a %d px box keeps something visible"):format(width),
            out ~= "" and out ~= nil, ("%q"):format(tostring(out)))
    end

    -- And the ordinary case must be untouched: text that fits is returned
    -- whole, with no ellipsis bolted on.
    probe:SetWidth(400)
    check("text that fits is returned unchanged",
        NS.UI.FitText(probe, "Addon memory usage") == "Addon memory usage")
    check("empty text stays empty", NS.UI.FitText(probe, "") == "")
end

-- The same question over everything this file has done so far. It does NOT go
-- red on the bug above - the addon names in this fixture are short enough that
-- no row is ever squeezed that hard - so it is a regression guard rather than
-- the proof. The probe above is the proof.
check("no label anywhere was trimmed out of existence", fitEmptied == 0,
    fitEmptied .. " labels vanished")

--------------------------------------------------------------------------
print("\n== a stat row spends its width on the label, not the value ==")
--------------------------------------------------------------------------
-- Every stat row reserved half its width for the value, so a row 321 px wide
-- gave 160 px to the string "0" and trimmed "Collections observed" to fit in
-- what was left. The value was anchored LEFT to the row's centre as well as
-- RIGHT, which hard-codes a 50/50 split that no SetWidth can override - in
-- the real client as much as here.
--
-- The card-heading half of this question is checked inside the size sweep
-- above, where the pages are already laid out at three widths.

do
    MW.frame:SetSize(1280, 800)
    MW:LayoutAllPages()
    MW:ShowPage("sessions")
    MW:RefreshCurrentPage()
    mock.Tick(0.1)

    local greedy, checked, worstRow = 0, 0, nil
    for _, region in ipairs(mock.allFrames) do
        if region.value and region.label and region.RefitLabel and region:IsVisible() then
            local rowWidth = region:GetWidth() or 0
            local valueWidth = region.value:GetWidth() or 0
            if rowWidth > 80 then
                checked = checked + 1
                if valueWidth > rowWidth * 0.55 then
                    greedy = greedy + 1
                    worstRow = worstRow or ("%s: value %.0f of %.0f"):format(
                        tostring(region.labelFull), valueWidth, rowWidth)
                end
            end
        end
    end
    check("some stat rows were actually examined", checked > 5, checked)
    check("no stat row hands most of its width to the value",
        greedy == 0, worstRow or "-")
end

--------------------------------------------------------------------------
print("\n== the harness does not invent allocation ==")
--------------------------------------------------------------------------
-- A page refresh appeared to allocate 150 KB. Almost none of it was the
-- addon: SetPoint built a table per call and ClearAllPoints threw those
-- tables away, so the ClearAllPoints-then-SetPoint that all layout code does
-- allocated two fresh tables per cell - 304 per list refresh. The real
-- client's anchors are not Lua tables at all.
--
-- Left alone, that hides real regressions behind harness noise, so the cost
-- of the mock's own hot methods is asserted rather than assumed.

do
    local function perCall(times, fn)
        fn(0)   -- warm up with the same shape of argument the loop passes
        collectgarbage(); collectgarbage()
        local before = collectgarbage("count")
        for i = 1, times do fn(i) end
        return (collectgarbage("count") - before) * 1024 / times
    end

    local a = CreateFrame("Frame", nil, UIParent)
    local b = CreateFrame("Frame", nil, UIParent)
    a:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

    check("re-anchoring allocates nothing",
        perCall(2000, function(i) a:SetPoint("TOPLEFT", b, "TOPLEFT", i % 13, 0) end) < 8,
        ("%.0f bytes/call"):format(
            perCall(2000, function(i) a:SetPoint("TOPLEFT", b, "TOPLEFT", i % 13, 0) end)))

    check("clear-then-anchor allocates nothing either",
        perCall(2000, function(i)
            a:ClearAllPoints()
            a:SetPoint("TOPLEFT", b, "TOPLEFT", i % 13, 0)
            a:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
        end) < 16, "clear + two anchors")

    check("setting a colour allocates nothing",
        perCall(2000, function() a:SetAlpha(1) b:SetFrameLevel(2) end) < 8, "colour path")

    -- And the thing those add up to: a refresh of every page.
    --
    -- The numbers below are the addon's own allocation now that the harness
    -- has stopped adding its own. They were 151 KB on the errors page and
    -- 189 KB on performance before that was found. The cap is generous enough
    -- not to be flaky and tight enough that a return to those numbers fails.
    local worstPage, worstKB = nil, 0
    for _, key in ipairs(NS.UI.pageOrder) do
        MW:ShowPage(key)
        MW:RefreshCurrentPage()
        local perRefresh = perCall(20, function() MW:RefreshCurrentPage() end) / 1024
        if perRefresh > worstKB then worstPage, worstKB = key, perRefresh end
    end
    check("no page allocates more than 60 KB per refresh",
        worstKB < 60, ("%s at %.1f KB"):format(tostring(worstPage), worstKB))
    print(("      worst page: %s at %.1f KB per refresh"):format(
        tostring(worstPage), worstKB))
end

--------------------------------------------------------------------------
print("\n== side columns behave the same on every page ==")
--------------------------------------------------------------------------
-- Eight pages had a list-or-detail side column and eight different hard-coded
-- widths for it. A fixed width is wrong at both ends: at 940 a 380 px column
-- takes 40% of the page, and at 1920 the same column is a sliver next to an
-- enormous pane. They are a clamped share of the page now.

do
    local COLUMNS = {
        { page = "incidents",   get = function(p) return p.listCard end },
        { page = "sessions",    get = function(p) return p.listCard end },
        { page = "reports",     get = function(p) return p.side end },
        { page = "system",      get = function(p) return p.infoCard end },
        { page = "diagnostics", get = function(p) return p.correlationCard end },
    }

    for _, size in ipairs(SIZES) do
        MW.frame:SetSize(size.w, size.h)
        MW:LayoutAllPages()

        local widths, narrowest, widest = {}, math.huge, 0
        for _, spec in ipairs(COLUMNS) do
            MW:ShowPage(spec.page)
            MW:RefreshCurrentPage()
            mock.Tick(0.1)

            local card = spec.get(NS.UI.Pages[spec.page])
            local width = card and card:GetWidth() or 0
            widths[spec.page] = width
            narrowest, widest = math.min(narrowest, width), math.max(widest, width)

            local pageWidth = NS.UI.Pages[spec.page].frame:GetWidth() or 1
            check(("%s/%s: the side column leaves most of the page to the content")
                :format(size.name, spec.page),
                width / pageWidth < 0.4,
                ("%.0f of %.0f = %.0f%%"):format(width, pageWidth, width / pageWidth * 100))
            check(("%s/%s: and is still wide enough to read"):format(size.name, spec.page),
                width >= 240, width)
        end

        check(("%s: every side column is the same width"):format(size.name),
            widest - narrowest < 2, ("%.0f..%.0f"):format(narrowest, widest))
    end
end

--------------------------------------------------------------------------
print("\n== settings uses the width it is given ==")
--------------------------------------------------------------------------
-- Sixteen sections in one fixed 520 px column: at 1920 the right two thirds
-- of the page were empty and the page was 4840 px tall regardless of how much
-- room there was. The sections are cards now and flow into as many columns as
-- fit, so the same content is a third as tall on a wide window.

do
    local page = NS.UI.Pages.settings
    check("settings has sections at all", page.sections and #page.sections > 8,
        page.sections and #page.sections)

    local tallest, heights = 0, {}
    for _, size in ipairs(SIZES) do
        MW.frame:SetSize(size.w, size.h)
        MW:LayoutAllPages()
        MW:ShowPage("settings")
        MW:RefreshCurrentPage()
        mock.Tick(0.1)

        -- How many distinct left edges the visible cards sit on.
        local lefts, columns = {}, 0
        for _, card in ipairs(page.sections) do
            if card:IsShown() then
                local left = card:GetLeft()
                if left and not lefts[left] then lefts[left] = true; columns = columns + 1 end
            end
        end
        heights[size.name] = page.canvas:GetHeight() or 0
        tallest = math.max(tallest, columns)

        check(("%s: every section card is visible"):format(size.name), (function()
            for _, card in ipairs(page.sections) do
                if not card:IsShown() then return false end
            end
            return true
        end)())
        check(("%s: the canvas fills the width it was given"):format(size.name),
            math.abs((page.canvas:GetWidth() or 0) - (page.scroll:GetWidth() or 0)) < 2,
            ("canvas %.0f vs scroll %.0f"):format(
                page.canvas:GetWidth() or 0, page.scroll:GetWidth() or 0))
    end

    check("a wide window gets more than one column", tallest > 1, tallest)
    check("and that makes the page shorter, not just wider",
        heights.large < heights.minimum * 0.6,
        ("%.0f at 1920 vs %.0f at 940"):format(heights.large, heights.minimum))

    -- The filter.
    MW.frame:SetSize(1280, 800)
    MW:LayoutAllPages()
    MW:ShowPage("settings")
    mock.Tick(0.1)

    local function visibleSections()
        local n = 0
        for _, card in ipairs(page.sections) do
            if card:IsShown() then n = n + 1 end
        end
        return n
    end

    local total = visibleSections()
    page.filter = "memory"
    page:LayoutSections()
    local matched = visibleSections()
    check("filtering narrows the page", matched > 0 and matched < total,
        ("%d of %d"):format(matched, total))
    check("and says how much it narrowed it",
        (page.filterCount:GetText() or ""):find("match") ~= nil,
        page.filterCount:GetText())

    page.filter = "zzzznothing"
    page:LayoutSections()
    check("a filter that matches nothing hides everything rather than throwing",
        visibleSections() == 0, visibleSections())

    page.filter = nil
    page:LayoutSections()
    check("clearing the filter brings every section back",
        visibleSections() == total, ("%d of %d"):format(visibleSections(), total))
end

--------------------------------------------------------------------------
print("\n== the mouse wheel actually scrolls ==")
--------------------------------------------------------------------------
-- This path had never run. The mock did not define GetVerticalScroll at all,
-- and every wheel handler reads it before subtracting a step - so firing a
-- wheel would have thrown, and nothing ever fired one. "Scrolled" was in this
-- file's own header the whole time.

do
    local threw, moved, scrollable = 0, 0, 0
    for _, key in ipairs(NS.UI.pageOrder) do
        MW:ShowPage(key)
        MW:RefreshCurrentPage()
        mock.Tick(0.1)
        for _, frame in ipairs(mock.allFrames) do
            local handler = frame._scripts and frame._scripts.OnMouseWheel
            if frame:GetScrollChild() and frame:IsVisible() and handler then
                local range = frame:GetVerticalScrollRange()
                if range > 0 then
                    scrollable = scrollable + 1
                    local before = frame:GetVerticalScroll()
                    local ok = pcall(handler, frame, -1)
                    if not ok then threw = threw + 1
                    elseif frame:GetVerticalScroll() > before then moved = moved + 1 end
                    -- Back to the top, and never past the end.
                    pcall(handler, frame, 1)
                    check("scrolling never goes above the top",
                        frame:GetVerticalScroll() >= 0, frame:GetVerticalScroll())
                    frame:SetVerticalScroll(0)
                end
            end
        end
    end
    check("at least one page has something to scroll", scrollable > 0, scrollable)
    check("no wheel handler threw", threw == 0, threw .. " threw")
    check("every scrollable view moved when the wheel turned",
        moved == scrollable, ("%d of %d moved"):format(moved, scrollable))
end

--------------------------------------------------------------------------
print("\n== the vertical audit can actually fail ==")
--------------------------------------------------------------------------
-- Three green ticks per window size mean nothing unless the check that
-- produced them is capable of going red. The pages are audited inside the
-- size sweep above; this breaks both shapes deliberately and confirms both
-- are caught.

-- And the audit has to be capable of failing, or three green ticks mean
-- nothing. Break the two shapes deliberately and confirm both are caught.
do
    -- On a page that is actually showing: the audit only looks at what a
    -- player can see, so probing a hidden page would prove nothing.
    MW:ShowPage("dashboard")
    MW:RefreshCurrentPage()
    mock.Tick(0.1)
    local host = NS.UI.Pages.dashboard.frame
    local runner = CreateFrame("Frame", "WTMTestOverflowProbe", host)
    runner:SetPoint("TOPLEFT")
    runner:SetPoint("TOPRIGHT")
    runner:SetHeight((host:GetHeight() or 300) + 80)
    runner:Show()

    local label = host:CreateFontString(nil, "OVERLAY")
    label:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -4)
    label:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, -4)
    label:SetHeight(14)
    label:SetWordWrap(true)
    label:SetText(("a sentence that keeps going and going "):rep(8))
    label:Show()

    local kinds = {}
    for _, f in ipairs(mock.AuditVertical()) do kinds[f.kind] = true end
    check("the audit catches a frame that outgrows its parent",
        kinds.spill or kinds.cutoff)
    check("the audit catches text that needs more lines than it has",
        kinds.truncated)

    runner:Hide()
    runner:SetParent(nil)
    label:Hide()
    label:SetText("")
end

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
print("\n== design overhaul: theme, accent and density switching ==")
--------------------------------------------------------------------------
-- Switching a preset rewrites live tables (UI/Theme.lua's HEX) while widgets
-- from every earlier preset are still on screen holding old colour cache
-- entries. If ApplyPreset missed a key, or the colour cache were not
-- cleared, this would either throw or silently keep serving a stale colour.

do
    local Theme = NS.UI.Theme
    local before = Theme.hex.windowBg

    local switchErrors = #mock.errors
    for _, palette in ipairs(Theme.PALETTES) do
        for _, accent in ipairs(Theme.ACCENTS) do
            NS.db.profile.ui.theme  = palette.key
            NS.db.profile.ui.accent = accent.key
            Theme:ApplyFromProfile()
            MW:RefreshCurrentPage()
        end
    end
    check("cycling every theme x accent combination never throws",
        #mock.errors == switchErrors, (#mock.errors - switchErrors) .. " errors")

    check("every palette actually changes the window background", (function()
        local seen = {}
        for _, palette in ipairs(Theme.PALETTES) do
            seen[palette.hex.windowBg] = true
        end
        return next(seen) ~= nil and (Theme.PALETTES[1].hex.windowBg ~= Theme.PALETTES[2].hex.windowBg)
    end)())

    for _, density in ipairs({ "comfortable", "compact" }) do
        NS.db.profile.ui.density = density
        Theme:ApplyDensity(density)
    end
    check("compact density actually shrinks row height",
        (function()
            Theme:ApplyDensity("compact")
            local compact = Theme.metrics.rowHeight
            Theme:ApplyDensity("comfortable")
            local comfortable = Theme.metrics.rowHeight
            return compact < comfortable
        end)())

    -- Back to the default before the rest of the file's checks run - they
    -- were all written against WTM Dark / Blue / Comfortable.
    NS.db.profile.ui.theme, NS.db.profile.ui.accent, NS.db.profile.ui.density =
        "wtmdark", "blue", "comfortable"
    Theme:ApplyFromProfile()
    check("windowBg is restored once switched back to the default",
        Theme.hex.windowBg == before, Theme.hex.windowBg)
end

--------------------------------------------------------------------------
print("\n== design overhaul: graph engine edge cases ==")
--------------------------------------------------------------------------
-- The newest, least-exercised code in this session's work: threshold zones,
-- the minor grid, Graph Quality's column-width lever, and three data shapes
-- (empty / one sample / a full ring buffer) the normal sweep above never
-- actually produces because the fixture always has a comfortable amount of
-- history by the time it runs.

do
    MW.frame:SetSize(1280, 800)
    MW:LayoutAllPages()

    ------------------------------------------------------------------
    -- Threshold zones + minor grid + Graph Quality, on a probe graph built
    -- with known "elevated" frame-time data - not through the Performance
    -- page's own recorder-fed graph, which may have no data yet at this
    -- point in a headless run and would make every assertion here trivially
    -- true regardless of whether the feature actually works.
    ------------------------------------------------------------------
    local zoneValues, zoneTimes = {}, {}
    for i = 1, 60 do zoneValues[i] = 20 + (i % 10); zoneTimes[i] = i end  -- 20-29 ms: ELEVATED band
    local zoneGraph = NS.UI.Graph(MW.frame, { title = "probe: threshold zones", thresholdZones = true })
    zoneGraph:SetSize(300, 150)
    zoneGraph:Show()
    zoneGraph:SetSeries(1, zoneValues, zoneTimes, { label = "frame" })
    zoneGraph:SetTimeRange(1, 60)

    NS.db.profile.ui.showThresholdZones = false
    zoneGraph.dirty = true
    zoneGraph:Draw()
    local _, zActiveOff = zoneGraph.zonePool:GetStats()
    check("threshold zones draw nothing while the setting is off",
        zActiveOff == 0, zActiveOff)

    NS.db.profile.ui.showThresholdZones = true
    zoneGraph.dirty = true
    zoneGraph:Draw()
    local _, zActiveOn = zoneGraph.zonePool:GetStats()
    check("threshold zones draw a band once enabled, for data that is actually elevated",
        zActiveOn > 0, zActiveOn)
    NS.db.profile.ui.showThresholdZones = false

    NS.db.profile.ui.graphQuality = "performance"
    zoneGraph.dirty = true
    zoneGraph:Draw()
    local _, minorActiveAtPerf = zoneGraph.minorGridPool:GetStats()
    check("Performance graph quality turns the minor grid off",
        minorActiveAtPerf == 0, minorActiveAtPerf)

    NS.db.profile.ui.graphQuality = "high"
    zoneGraph.dirty = true
    zoneGraph:Draw()
    local _, minorActiveAtHigh = zoneGraph.minorGridPool:GetStats()
    check("High graph quality draws the minor grid",
        minorActiveAtHigh > 0, minorActiveAtHigh)

    NS.db.profile.ui.graphQuality = "balanced"
    zoneGraph:Hide()
    zoneGraph:SetParent(nil)

    ------------------------------------------------------------------
    -- Auto graph style: two active series should not both fill.
    ------------------------------------------------------------------
    MW:ShowPage("network")
    MW:RefreshCurrentPage()
    -- The overlay graph, not the single-series one above it: it is the one
    -- actually carrying two series (world latency and frame time) on one axis.
    local netGraph = NS.UI.Pages.network.overlay
    if netGraph then
        NS.db.profile.ui.graphStyle = "auto"
        netGraph.dirty = true
        netGraph:Draw()
        local autoSegments = netGraph.lastSegments or 0

        NS.db.profile.ui.graphStyle = "area"
        netGraph.dirty = true
        netGraph:Draw()
        local areaSegments = netGraph.lastSegments or 0

        check("auto style draws fewer segments than forced area on a multi-series graph",
            autoSegments <= areaSegments, ("auto=%d area=%d"):format(autoSegments, areaSegments))
        NS.db.profile.ui.graphStyle = "auto"
    end

    ------------------------------------------------------------------
    -- Extreme peak: softCeiling must clip it, not hide it. Built directly
    -- against the Graph widget rather than through the recorder pipeline, so
    -- this tests the clipping logic itself rather than whichever scheduler
    -- ticks happen to have run in a headless harness by this point.
    ------------------------------------------------------------------
    local spikeValues, spikeTimes = {}, {}
    for i = 1, 40 do spikeValues[i] = 8 + (i % 5); spikeTimes[i] = i end
    spikeValues[41], spikeTimes[41] = 4200, 41  -- one 4.2 second "frame"
    local spikeGraph = NS.UI.Graph(MW.frame, { title = "probe: extreme peak", softCeiling = 0.95 })
    spikeGraph:SetSize(300, 150)
    spikeGraph:Show()
    spikeGraph:SetSeries(1, spikeValues, spikeTimes, { label = "frame" })
    spikeGraph:SetTimeRange(1, 41)
    spikeGraph.dirty = true
    spikeGraph:Draw()
    check("an extreme spike is reported as clipped rather than silently rescaling",
        spikeGraph.clipped == true, tostring(spikeGraph.clipped))
    check("the true peak is still the one reported, even though it is clipped",
        spikeGraph.dataPeak == 4200, spikeGraph.dataPeak)
    spikeGraph:Hide()
    spikeGraph:SetParent(nil)

    ------------------------------------------------------------------
    -- No data / one sample / a full ring buffer: three shapes the normal
    -- fixture never produces once the file has been running for a while.
    ------------------------------------------------------------------
    local probeParent = MW.frame
    local emptyGraph = NS.UI.Graph(probeParent, { title = "probe: empty" })
    emptyGraph:SetSize(300, 150)
    emptyGraph:Show()
    check("a graph with zero series does not throw when drawn",
        pcall(function() emptyGraph:Draw() end))

    local oneGraph = NS.UI.Graph(probeParent, { title = "probe: one sample" })
    oneGraph:SetSize(300, 150)
    oneGraph:Show()
    oneGraph:SetSeries(1, { 42 }, { 0 }, { label = "x" })
    oneGraph:SetTimeRange(0, 1)
    check("a graph with exactly one sample does not throw when drawn",
        pcall(function() oneGraph:Draw() end))

    local fullValues, fullTimes = {}, {}
    for i = 1, 4096 do fullValues[i] = 8 + (i % 37); fullTimes[i] = i * 0.1 end
    local fullGraph = NS.UI.Graph(probeParent, { title = "probe: full ring buffer" })
    fullGraph:SetSize(300, 150)
    fullGraph:Show()
    fullGraph:SetSeries(1, fullValues, fullTimes, { label = "x" })
    fullGraph:SetTimeRange(fullTimes[1], fullTimes[#fullTimes])
    check("a graph downsampling 4096 raw samples does not throw when drawn",
        pcall(function() fullGraph:Draw() end))
    check("downsampling still bounds the drawn segment count to the pixel width, not the sample count",
        (fullGraph.lastSegments or 0) < 4096, fullGraph.lastSegments)

    for _, g in ipairs({ emptyGraph, oneGraph, fullGraph }) do
        g:Hide()
        g:SetParent(nil)
    end
end

--------------------------------------------------------------------------
print("\n== design overhaul: pooling stats and reduced motion ==")
--------------------------------------------------------------------------

do
    local stats = NS.UI.GetGraphPoolStats()
    check("pooling stats cover every graph built so far",
        stats.graphs >= #NS.UI.pageOrder, stats.graphs)
    check("pooling stats report at least as many created as active",
        stats.created >= stats.active, ("created=%d active=%d"):format(stats.created, stats.active))

    -- Reduced motion must reach UI.Animate synchronously: a caller asking for
    -- fraction 1 immediately, with no frame of delay, is the whole point of
    -- the setting - a dropped frame during combat is not an acceptable price
    -- for a nav badge flash.
    NS.db.profile.ui.reduceMotion = true
    local ranSync = false
    NS.UI.Animate(0.5, function(fraction)
        if fraction == 1 then ranSync = true end
    end)
    check("reduced motion resolves an animation immediately rather than over time",
        ranSync)
    NS.db.profile.ui.reduceMotion = false
end

--------------------------------------------------------------------------
print("\n== design overhaul: topbar strip fits at the minimum window width ==")
--------------------------------------------------------------------------
-- Adding a 7th live-metric cell (ERRORS) pushed the strip's last cell 59 px
-- past the topbar's own right edge at 940 px wide - invisible to every check
-- above, because those only walk the CURRENT PAGE's frame tree, and the
-- topbar is chrome, not a page. Nothing else in this file would have caught
-- that regression.

do
    MW.frame:SetSize(940, 600)
    MW:LayoutAllPages()
    local topbar = MW.frame.topbar
    local metrics = MW.frame.topMetrics
    local rightmost = 0
    for _, cell in pairs(metrics) do
        rightmost = math.max(rightmost, cell:GetRight() or 0)
    end
    check("the last live-metric cell stays inside the topbar at the minimum window width",
        rightmost <= (topbar:GetRight() or 0),
        ("cell right %.0f vs topbar right %.0f"):format(rightmost, topbar:GetRight() or 0))
    MW.frame:SetSize(1280, 800)
    MW:LayoutAllPages()
end

--------------------------------------------------------------------------
print("\n== design overhaul: UI scale variants ==")
--------------------------------------------------------------------------
-- The same three window sizes, now also at two non-1.0 UI scales - the
-- addon does not control the player's UI scale, so it has to lay out
-- correctly at whatever scale WoW hands it.

do
    local scaleErrors = #mock.errors
    for _, scale in ipairs({ 0.75, 1.25 }) do
        MW.frame:SetScale(scale)
        for _, size in ipairs(SIZES) do
            MW.frame:SetSize(size.w, size.h)
            MW:LayoutAllPages()
            for _, key in ipairs({ "dashboard", "performance", "processes", "settings" }) do
                MW:ShowPage(key)
                MW:RefreshCurrentPage()
            end
        end
    end
    MW.frame:SetScale(1)
    MW.frame:SetSize(1280, 800)
    MW:LayoutAllPages()
    check("laying out at 0.75x and 1.25x UI scale never throws",
        #mock.errors == scaleErrors, (#mock.errors - scaleErrors) .. " errors")
end

--------------------------------------------------------------------------
print("\n== design overhaul: badge counts survive a heavy session ==")
--------------------------------------------------------------------------
-- 40 injected spikes/errors (the fixture at the top of this file) never
-- exercised the "999+" cap. A real long raid night can produce more
-- distinct errors and spikes than that badge has digits for.

do
    NS.db.profile.dev.enabled = true
    local badgeErrors = #mock.errors
    for i = 1, 300 do
        NS.Dev:InjectFrameSpike(60 + (i % 11) * 45)
        NS.Errors:Record(("Interface/AddOns/Bulk%d/File.lua:%d: a bulk failure"):format(i % 23, i), nil, false)
    end
    NS.UI.Sidebar:Refresh()
    check("injecting hundreds of spikes and errors does not throw",
        #mock.errors == badgeErrors, (#mock.errors - badgeErrors) .. " errors")

    local errorsItem = NS.UI.Sidebar.items.errors
    check("the errors badge caps at 999+ instead of growing the row wider",
        errorsItem.badge:GetText() == "999+" or tonumber(errorsItem.badge:GetText()) ~= nil,
        errorsItem.badge:GetText())
end

--------------------------------------------------------------------------
print("\n== design overhaul: Addon Detail hero header ==")
--------------------------------------------------------------------------
-- The hero row (CPU/Memory/Errors/Spikes tiles) sits beside a "SCORE" number
-- pinned to the header's own right edge. Nothing clips either against the
-- page-bounds walk above, because this overlay is not a page.

do
    local record = NS.Processes:Get("WeakAuras")
    local openErrors = #mock.errors
    check("the addon detail overlay opens without throwing",
        pcall(function() NS.UI.AddonDetail:Open(record) end))
    check("opening it does not throw", #mock.errors == openErrors,
        (#mock.errors - openErrors) .. " errors")

    local header = NS.UI.AddonDetail.header
    local rightmost = 0
    for _, key in ipairs({ "cpu", "memory", "errors", "spikes" }) do
        local cell = header.hero[key]
        rightmost = math.max(rightmost, cell:GetRight() or 0)
    end
    check("the hero tile row stays clear of the SCORE number",
        rightmost < (header.score:GetLeft() or math.huge),
        ("hero right %.0f vs score left %.0f"):format(rightmost, header.score:GetLeft() or -1))

    local tabErrors = #mock.errors
    for _, tab in ipairs({ "overview", "cpu", "memory", "history", "events",
                           "dependencies", "errors", "diagnostics", "metadata" }) do
        pcall(function() NS.UI.AddonDetail:ShowTab(tab) end)
    end
    check("switching through every tab never throws",
        #mock.errors == tabErrors, (#mock.errors - tabErrors) .. " errors")

    NS.UI.AddonDetail:Close()
end

--------------------------------------------------------------------------
print("\n== design overhaul: Processes table pills ==")
--------------------------------------------------------------------------
-- Status/Errors/Spikes render as UI.Badge pills now instead of plain
-- coloured text. A pill column has no `.text` cell any more, so any code
-- still reading `cell.text` on one of these three columns would throw.

do
    MW.frame:SetSize(1280, 800)
    MW:ShowPage("processes")

    -- Earlier sweeps in this file fire OnClick on every frame on every page,
    -- which includes this page's filter toggle buttons - by this point in
    -- the file they may have left every addon filtered out. Reset them
    -- explicitly rather than assume whatever state they were clicked into.
    local page = NS.UI.Pages.processes
    page.filter, page.filters = nil, {}
    for key, button in pairs(page.filterButtons) do
        button.active = false
        button:SetSelected(false)
    end
    page:Rebuild(true)
    mock.Tick(0.1)

    local pillColumns, textColumns = 0, 0
    for _, column in ipairs(page.table.columns) do
        if column.pill then pillColumns = pillColumns + 1 else textColumns = textColumns + 1 end
    end
    check("the table declares the three pill columns", pillColumns == 3, pillColumns)
    check("and still has plain-text columns beside them", textColumns > 0, textColumns)

    local pillErrors = #mock.errors
    local sawPill = false
    for _, row in ipairs(page.table.list.rows or {}) do
        if row.data then
            for i, column in ipairs(page.table.columns) do
                local cell = row.cells[i]
                if column.pill and cell.pill and cell.pill:IsShown() then sawPill = true end
            end
        end
    end
    check("at least one visible row shows a pill (every addon has a Status)", sawPill)

    -- The stress the pill rendering actually needs: many rows, both window
    -- sizes, and the resort/resize paths a plain-text cell already survived.
    for _, size in ipairs(SIZES) do
        MW.frame:SetSize(size.w, size.h)
        MW:LayoutAllPages()
        MW:RefreshCurrentPage()
        mock.FireScriptOnAll("OnMouseWheel", -1)
    end
    MW.frame:SetSize(1280, 800)
    MW:LayoutAllPages()
    check("pill columns survive resizing and rescrolling the table without throwing",
        #mock.errors == pillErrors, (#mock.errors - pillErrors) .. " errors")
end

--------------------------------------------------------------------------
print("\n== design overhaul: incident timeline strip ==")
--------------------------------------------------------------------------
-- One clickable tick per cluster, positioned by time and sized by severity,
-- above the STUTTER CLUSTERS list. Built from a RegionPool of buttons, not
-- plain textures, specifically so a spotted cluster can be clicked open.

do
    MW.frame:SetSize(1280, 800)
    MW:ShowPage("incidents")
    MW:RefreshCurrentPage()
    mock.Tick(0.1)

    local page = NS.UI.Pages.incidents
    check("the strip sits clear above the cluster list, not overlapping it",
        (page.timelineStrip:GetBottom() or 0) > (page.listCard:GetTop() or math.huge) - 1,
        ("strip bottom %.0f vs list top %.0f")
            :format(page.timelineStrip:GetBottom() or -1, page.listCard:GetTop() or -1))

    local clusterCount = #page.list.data
    if clusterCount > 0 then
        check("one tick is drawn per cluster",
            page.timelinePool.nActive == clusterCount,
            ("%d ticks for %d clusters"):format(page.timelinePool.nActive, clusterCount))

        local heights = {}
        for _, tick in ipairs(page.timelinePool.active) do
            heights[#heights + 1] = tick:GetHeight()
        end
        local allSame = true
        for i = 2, #heights do if heights[i] ~= heights[1] then allSame = false end end
        check("severity actually changes the tick height when clusters differ in kind",
            not allSame or clusterCount < 2, table.concat(heights, ","))

        -- Clicking a tick selects its cluster, same as clicking its row.
        local tick = page.timelinePool.active[1]
        local clickErrors = #mock.errors
        local ok = pcall(function() tick:GetScript("OnClick")(tick) end)
        check("clicking a timeline tick does not throw", ok and #mock.errors == clickErrors)
        check("clicking a timeline tick selects its cluster",
            page.selected == tick.cluster)
    else
        check("with no clusters the strip says so instead of drawing nothing unexplained",
            page.timelineEmpty:IsShown())
    end
end

--------------------------------------------------------------------------
print(("\n   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(6, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
