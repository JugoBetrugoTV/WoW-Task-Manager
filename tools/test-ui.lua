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

    -- And the thing those add up to: one page refresh.
    MW:ShowPage("errors")
    MW:RefreshCurrentPage()
    local perRefresh = perCall(20, function() MW:RefreshCurrentPage() end) / 1024
    check("a page refresh stays well under 100 KB of garbage",
        perRefresh < 100, ("%.1f KB per refresh"):format(perRefresh))
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
print(("\n   %d passed, %d failed, %d lua errors"):format(passed, failed, #mock.errors))
for i = 1, math.min(6, #mock.errors) do print("   error: " .. mock.errors[i]) end
os.exit((failed == 0 and #mock.errors == 0) and 0 or 1)
