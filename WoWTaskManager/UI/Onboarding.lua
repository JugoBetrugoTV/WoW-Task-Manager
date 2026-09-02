--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Onboarding.lua

    A four-step introduction, shown once.

    Two of the four steps exist because of what this addon measures rather than
    because of where its buttons are. Per-addon CPU needs a client CVar and a
    reload, and a player who does not know that reads every CPU column as "0.00"
    and concludes the addon is broken. And the numbers this addon produces are
    associations, not verdicts - saying so once, up front, is more honest than
    hoping the wording on each individual panel carries it.

    It is skippable, it is re-openable from the Settings page, and it writes
    exactly one flag when it is finished.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local M     = Theme.metrics

local Onboarding = WTM:NewModule("Onboarding")
UI.Onboarding = Onboarding

local WIDTH, HEIGHT = 520, 340

--------------------------------------------------------------------------
-- Content
--------------------------------------------------------------------------

local STEPS = {
    {
        title = "What this is",
        body =
            "A diagnostics window for your own client: frame time, FPS, latency, " ..
            "memory, event rate and per-addon cost, sampled continuously and drawn " ..
            "as live graphs.\n\n" ..
            "When your game stutters, it records the seconds before and after the " ..
            "stutter automatically, so you can look at what happened instead of " ..
            "trying to reproduce it.",
        hint = "Frame time is the graph that matters. FPS is an average; frame time shows the individual bad frame.",
    },
    {
        title = "Opening it",
        body =
            "Three ways, all equivalent:\n\n" ..
            "|cff4c8dff/wtm|r in chat\n" ..
            "the minimap button (left click)\n" ..
            "ESC - Options - AddOns - " .. C.ADDON_TITLE .. "\n\n" ..
            "There is also a compact always-on panel with just the live numbers: " ..
            "|cff4c8dff/wtm mini|r, or right click the minimap button. It can be " ..
            "collapsed to a single line.",
        hint = "Every chat command also exists as a button on the Settings page. You never have to memorise one.",
    },
    {
        title = "Per-addon CPU needs to be switched on",
        body =
            "WoW only measures how much CPU each addon uses when the client's " ..
            "scriptProfile setting is enabled, and that setting only takes effect " ..
            "after a UI reload.\n\n" ..
            "Until then, every per-addon CPU figure reads as unavailable. Nothing " ..
            "is estimated or filled in to cover the gap.\n\n" ..
            "Memory, frame time, FPS, latency and event rates all work without it.",
        hint = "The dashboard has a button that enables it and a separate button that reloads - it will never reload your UI on its own.",
    },
    {
        title = "How to read the results",
        body =
            "This addon reports what it measured and how strongly two things " ..
            "occurred together. It does not decide what caused a stutter, and it " ..
            "will not tell you that a particular addon is to blame.\n\n" ..
            "Addon CPU is a running total that WoW exposes, so a figure is always " ..
            "stated with the window it was measured over - never as a share of one " ..
            "specific frame.\n\n" ..
            "Where the client cannot measure something, the panel says so instead " ..
            "of showing a plausible-looking zero.",
        hint = "An association is a place to start looking, not an answer.",
    },
}

--------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------

function Onboarding:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "WTMOnboarding", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER", 0, 40)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:Hide()
    self.frame = frame

    UI.Fill(frame, "windowBg", 0.98)
    UI.Border(frame, "TLBR", "accentDim")

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    header:SetHeight(40)
    UI.Fill(header, "topbarBg")
    UI.MakeMovable(frame, header)

    local brand = UI.Text(header, "title", "textPrimary", "LEFT")
    brand:SetPoint("LEFT", M.padding, 0)
    brand:SetText(C.ADDON_TITLE)

    local step = UI.Text(header, "small", "textMuted", "RIGHT")
    step:SetPoint("RIGHT", -M.padding, 0)
    frame.stepText = step

    ------------------------------------------------------------------
    local title = UI.Text(frame, "title", "accent", "LEFT")
    title:SetPoint("TOPLEFT", M.padding, -(40 + M.padding))
    title:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
    frame.title = title

    local body = UI.Text(frame, "body", "textSecondary", "LEFT")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    body:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
    body:SetHeight(HEIGHT - 190)
    -- The body is a paragraph block sized to the dialog, not a notice squeezed
    -- into a layout, so it gets the room the dialog was built for.
    UI.Wrap(body, 12)
    body:SetJustifyV("TOP")
    frame.body = body

    local hint = UI.Text(frame, "small", "textMuted", "LEFT")
    hint:SetPoint("BOTTOMLEFT", M.padding, 54)
    hint:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
    hint:SetHeight(28)
    UI.Wrap(hint, 2)
    hint:SetJustifyV("BOTTOM")
    frame.hint = hint

    ------------------------------------------------------------------
    local skip = UI.Button(frame, "Skip", function() Onboarding:Finish() end,
        { height = 24 })
    skip:SetPoint("BOTTOMLEFT", M.padding, M.padding)
    skip.tooltip = "Closes this and does not show it again. It stays available on the Settings page."

    local next_ = UI.Button(frame, "Next", function() Onboarding:Advance(1) end,
        { height = 24, primary = true, minWidth = 96 })
    next_:SetPoint("BOTTOMRIGHT", -M.padding, M.padding)
    frame.nextButton = next_

    local back = UI.Button(frame, "Back", function() Onboarding:Advance(-1) end,
        { height = 24, minWidth = 80 })
    back:SetPoint("RIGHT", next_, "LEFT", -8, 0)
    frame.backButton = back

    return frame
end

--------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------

function Onboarding:ShowStep(index)
    local frame = self:Build()
    index = math.max(1, math.min(#STEPS, index or 1))
    self.index = index

    local step = STEPS[index]
    frame.stepText:SetText(("Step %d of %d"):format(index, #STEPS))
    frame.title:SetText(step.title)
    frame.body:SetText(step.body)
    frame.hint:SetText(step.hint or "")

    frame.backButton:SetEnabledState(index > 1)
    frame.nextButton:SetText(index == #STEPS and "Open the window" or "Next")
end

function Onboarding:Advance(delta)
    local target = (self.index or 1) + delta
    if target > #STEPS then
        self:Finish()
        UI.MainWindow:Open("dashboard")
        return
    end
    self:ShowStep(target)
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

function Onboarding:Open()
    self:Build()
    self:ShowStep(1)
    self.frame:Show()
end

function Onboarding:Close()
    if self.frame then self.frame:Hide() end
end

--- Marks the introduction as seen and closes it. Called by Skip and by
--- finishing the last step alike - both mean "do not show this again".
function Onboarding:Finish()
    WTM.db.global.onboardingDone = true
    self:Close()
end

function Onboarding:IsShown()
    return self.frame and self.frame:IsShown() or false
end

function Onboarding:HasBeenSeen()
    return WTM.db.global.onboardingDone and true or false
end

--------------------------------------------------------------------------

function Onboarding:OnEnable()
    if self:HasBeenSeen() then return end
    -- Not during the login rush: PLAYER_LOGIN fires while addons are still
    -- loading and the screen is still fading in, and a dialog that appears
    -- underneath a loading screen is a dialog nobody reads.
    self:ScheduleTimer(function()
        if not Onboarding:HasBeenSeen() then Onboarding:Open() end
    end, 6)
end
