--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/Tooltip.lua

    A private tooltip rather than GameTooltip.  Two reasons: GameTooltip carries
    Blizzard's frame art, and borrowing it means fighting every other addon that
    also borrows it.  This one is a plain elevated panel that matches the rest
    of the window.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get

local tooltip
local MAX_LINES = 24

local function EnsureTooltip()
    if tooltip then return tooltip end

    tooltip = UI.Panel(UIParent, { color = "elevated", borderColor = "borderStrong" })
    tooltip:SetFrameStrata("TOOLTIP")
    tooltip:SetClampedToScreen(true)
    tooltip:Hide()

    tooltip.title = UI.Text(tooltip, "heading", "textPrimary")
    tooltip.title:SetPoint("TOPLEFT", 10, -8)
    tooltip.title:SetPoint("TOPRIGHT", -10, -8)
    tooltip.title:SetJustifyH("LEFT")

    tooltip.lines = {}
    for i = 1, MAX_LINES do
        local row = CreateFrame("Frame", nil, tooltip)
        row:SetHeight(14)
        row.left = UI.Text(row, "small", "textSecondary")
        row.left:SetPoint("LEFT")
        row.right = UI.Text(row, "numericSm", "textPrimary", "RIGHT")
        row.right:SetPoint("RIGHT")
        row:Hide()
        tooltip.lines[i] = row
    end

    return tooltip
end

--------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------

local activeLines = 0

function UI.TooltipClear(title)
    local tip = EnsureTooltip()
    tip.title:SetText(title or "")
    for i = 1, MAX_LINES do tip.lines[i]:Hide() end
    activeLines = 0
    return tip
end

--- Adds a line.  `right` is optional; with it the line becomes a key/value row.
function UI.TooltipLine(left, right, leftTone, rightTone)
    local tip = EnsureTooltip()
    if activeLines >= MAX_LINES then return end
    activeLines = activeLines + 1

    local row = tip.lines[activeLines]
    row:ClearAllPoints()
    if activeLines == 1 then
        row:SetPoint("TOPLEFT", tip.title, "BOTTOMLEFT", 0, -6)
        row:SetPoint("TOPRIGHT", tip.title, "BOTTOMRIGHT", 0, -6)
    else
        row:SetPoint("TOPLEFT", tip.lines[activeLines - 1], "BOTTOMLEFT", 0, -2)
        row:SetPoint("TOPRIGHT", tip.lines[activeLines - 1], "BOTTOMRIGHT", 0, -2)
    end

    row.left:SetText(left or "")
    row.left:SetTextColor(Theme:Tone(leftTone or "muted"))
    row.right:SetText(right or "")

    -- Written out rather than as `rightTone and Theme:Tone(rightTone) or
    -- T("textPrimary")`.
    --
    -- In Lua an and/or expression yields exactly ONE value, so that form
    -- silently truncated r, g, b, a down to r. The live client rejected the
    -- single argument and threw on every tooltip that had a value with no tone
    -- - which is most of them.
    if rightTone then
        row.right:SetTextColor(Theme:Tone(rightTone))
    else
        row.right:SetTextColor(T("textPrimary"))
    end
    row:Show()
end

function UI.TooltipShow(anchorFrame, anchorPoint)
    local tip = EnsureTooltip()

    -- Width from the widest line, so a tooltip is never wider than it needs.
    local width = tip.title:GetStringWidth() or 0
    for i = 1, activeLines do
        local row = tip.lines[i]
        local w = (row.left:GetStringWidth() or 0) + (row.right:GetStringWidth() or 0) + 24
        if w > width then width = w end
    end
    tip:SetWidth(math.min(420, math.max(140, width + 20)))
    tip:SetHeight(20 + (tip.title:GetText() ~= "" and 16 or 0) + activeLines * 16 + 8)

    tip:ClearAllPoints()
    if anchorFrame then
        tip:SetPoint(anchorPoint or "BOTTOMLEFT", anchorFrame, "TOPLEFT", 0, 6)
    else
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        tip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 12, y / scale + 12)
    end
    tip:Show()
end

function UI.HideTooltip()
    if tooltip then tooltip:Hide() end
end

--- Whether the tooltip is on screen. Exists so a test can ask directly rather
--- than inferring it from stray text, which is how a harness ends up auditing
--- things nobody can see.
function UI.IsTooltipShown()
    return tooltip ~= nil and tooltip:IsShown()
end

--- Convenience for the common "title plus one paragraph" case.
function UI.ShowTooltip(anchorFrame, title, text, tone)
    UI.TooltipClear(title)
    if text then
        -- Wrap by hand: the row font strings are single-line by design so the
        -- layout maths above stays simple.
        local line = ""
        for word in tostring(text):gmatch("%S+") do
            if #line + #word + 1 > 58 then
                UI.TooltipLine(line, nil, tone)
                line = word
            else
                line = (line == "") and word or (line .. " " .. word)
            end
        end
        if line ~= "" then UI.TooltipLine(line, nil, tone) end
    end
    UI.TooltipShow(anchorFrame)
end
