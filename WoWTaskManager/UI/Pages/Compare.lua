--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Compare.lua

    Two sessions, side by side, with the difference spelled out.

    This is the page that answers "did that change help?" - after adding an
    addon, removing one, changing a setting, or updating the client. It is also
    the page most able to mislead, because two play sessions are not a
    controlled experiment: the zone, the group size, what the server was doing
    and what you were doing all differ, and any of those moves these numbers
    more than an addon does.

    So the deltas are shown, and the caveat is shown with them, every time.
    The page reports the difference between two measurements. It does not
    attribute that difference to anything.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("compare", {})

local compareScratch = {}

--------------------------------------------------------------------------

local function SessionLabel(session, index)
    if not session then return "-" end
    if session.isLive then return "Current session" end
    return ("%s  (%s)"):format(Fmt.DateTime(session.startedAt),
        Fmt.Duration(session.duration or 0))
end

--- Every session available to compare: the live one first, then stored ones
--- newest first. The live session is included deliberately - "how does today
--- compare with last night" is the common question.
local function BuildChoices(out)
    for i = #out, 1, -1 do out[i] = nil end
    out[1] = { live = true, session = WTM.Sessions:LiveSnapshot() }
    local stored = WTM.Sessions:GetStored()
    for i = #stored, 1, -1 do
        out[#out + 1] = { index = i, session = stored[i] }
    end
    return out
end

function Page:Build(frame)
    local pad = M.padding
    self.choices = {}

    ------------------------------------------------------------------
    -- Two pickers
    ------------------------------------------------------------------
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(26)
    toolbar:SetPoint("TOPLEFT", pad, -pad)
    toolbar:SetPoint("TOPRIGHT", -pad, -pad)

    self.aLabel = UI.Text(toolbar, "small", "textSecondary", "LEFT")
    self.aLabel:SetPoint("LEFT")
    self.aLabel:SetPoint("RIGHT", toolbar, "CENTER", -80, 0)

    self.swap = UI.Button(toolbar, "swap", function()
        self.aIndex, self.bIndex = self.bIndex, self.aIndex
        self:Refresh()
    end, { height = 22, style = "small", minWidth = 52 })
    self.swap:SetPoint("CENTER", toolbar, "CENTER", 0, 0)
    self.swap.tooltip = "Exchanges the two sides. The change column is always B relative to A."

    self.bLabel = UI.Text(toolbar, "small", "textSecondary", "RIGHT")
    self.bLabel:SetPoint("RIGHT")
    self.bLabel:SetPoint("LEFT", toolbar, "CENTER", 80, 0)

    ------------------------------------------------------------------
    -- Session lists, one per side
    ------------------------------------------------------------------
    local function buildPicker(anchorPoint, onPick)
        local list = UI.ScrollList(frame, 20,
            function(parent)
                local row = CreateFrame("Button", nil, parent)
                row:SetHeight(20)
                row.text = UI.Text(row, "small", "textSecondary", "LEFT")
                row.text:SetPoint("LEFT", 6, 0)
                row.text:SetPoint("RIGHT", -6, 0)
                row.highlight = row:CreateTexture(nil, "BACKGROUND")
                row.highlight:SetAllPoints()
                row.highlight:SetColorTexture(T("selected", 0.9))
                row.highlight:Hide()
                return row
            end,
            function(row, entry, index)
                row.text:SetText(UI.FitText(row.text, SessionLabel(entry.session)))
                row.entry = entry
                row.highlight:SetShown(entry.selected)
                if entry.selected then
                    row.text:SetTextColor(T("textPrimary"))
                else
                    row.text:SetTextColor(T("textSecondary"))
                end
            end,
            function(row) if row.entry then onPick(row.entry) end end)
        return list
    end

    self.aList = buildPicker("LEFT", function(entry)
        self.aIndex = entry.live and 0 or entry.index
        self:Refresh()
    end)
    self.aList:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -6)
    self.aList:SetPoint("BOTTOM", frame, "BOTTOM", 0, pad)
    self.aList:SetWidth(196)

    self.bList = buildPicker("RIGHT", function(entry)
        self.bIndex = entry.live and 0 or entry.index
        self:Refresh()
    end)
    self.bList:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -6)
    self.bList:SetPoint("BOTTOM", frame, "BOTTOM", 0, pad)
    self.bList:SetWidth(196)

    ------------------------------------------------------------------
    -- The comparison itself
    ------------------------------------------------------------------
    self.card = UI.ComparisonCard(frame, "SESSION COMPARISON",
        WTM.Observations.COMPARE_METRICS)
    self.card:SetPoint("TOPLEFT", self.aList, "TOPRIGHT", M.cardGap, 0)
    self.card:SetPoint("TOPRIGHT", self.bList, "TOPLEFT", -M.cardGap, 0)
    self.card:SetHeight(self.card.naturalHeight)

    self.summary = UI.Card(frame, "READING THIS COMPARISON", {})
    self.summary:SetPoint("TOPLEFT", self.card, "BOTTOMLEFT", 0, -M.cardGap)
    self.summary:SetPoint("TOPRIGHT", self.card, "BOTTOMRIGHT", 0, -M.cardGap)
    self.summary:SetPoint("BOTTOM", frame, "BOTTOM", 0, pad)

    self.summary.body = UI.Text(self.summary.content, "small", "textMuted", "LEFT")
    self.summary.body:SetPoint("TOPLEFT")
    self.summary.body:SetPoint("BOTTOMRIGHT")
    UI.Wrap(self.summary.body, 0)
    self.summary.body:SetJustifyV("TOP")

    -- Default: the live session against the most recent stored one, which is
    -- the comparison almost everybody wants first.
    self.aIndex, self.bIndex = nil, 0
end

function Page:OnShow() self:Refresh() end
function Page:OnLayout() end

--------------------------------------------------------------------------

function Page:Refresh()
    if not self.card then return end

    local choices = BuildChoices(self.choices)

    -- Default A to the newest stored session once one exists.
    if self.aIndex == nil then
        local stored = WTM.Sessions:GetStored()
        self.aIndex = #stored > 0 and #stored or 0
    end

    local function resolve(index)
        if index == 0 then return WTM.Sessions:LiveSnapshot() end
        return WTM.Sessions:Get(index)
    end

    local a, b = resolve(self.aIndex), resolve(self.bIndex)

    for _, entry in ipairs(choices) do
        entry.selected = false
    end
    self.aList:SetData(choices)
    self.bList:SetData(choices)

    self.aLabel:SetText(UI.FitText(self.aLabel, "A:  " .. SessionLabel(a)))
    self.bLabel:SetText(UI.FitText(self.bLabel, "B:  " .. SessionLabel(b)))
    self.card:SetHeaders("A", "B")

    if not (a and b) then
        for _, metric in ipairs(WTM.Observations.COMPARE_METRICS) do
            self.card:SetRow(metric.key, "-", "-", nil)
        end
        self.summary.body:SetText(
            "Pick a session on each side. Only one session has been recorded so far, so there is nothing to compare against yet - sessions are saved when you log out or reload.")
        return
    end

    local rows = WTM.Observations:Compare(a, b, compareScratch)
    for _, row in ipairs(rows) do
        self.card:SetRow(row.key, row.a, row.b, row.delta, row.betterIsHigher)
    end

    self.summary.body:SetText(
        WTM.Observations:DescribeComparison(rows) .. "\n\n" ..
        "The change column is B relative to A. Percentages are shown against A; where A was zero, the absolute change is shown instead, because a percentage of zero means nothing.\n\n" ..
        "Two sessions are not an experiment. Zone, group size, what the server was doing and what you were doing all differ between them, and any of those moves these numbers. A difference here is a difference between two measurements - it is not evidence about what produced it.")
end
