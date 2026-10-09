--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Onboarding.lua

    A five-step introduction, shown once on the first login.

    Two of the five exist because of what this addon measures rather than where
    its buttons are. Per-addon CPU needs a client CVar and a UI reload, and a
    player who does not know that reads every CPU column as "0.00" and concludes
    the addon is broken. And the numbers here are associations, not verdicts -
    saying so once, up front, is more honest than hoping the wording on each
    individual panel carries it.

    Three rules it follows:
      * skippable at every step, from a button that is always visible,
      * automatic only on the very first run, never again,
      * always reachable afterwards from the Settings page.

    Steps that offer an action carry a button that performs it inline, so the
    introduction is not a list of instructions to go and follow somewhere else.
    Nothing it does is irreversible, and it never reloads the UI on its own.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local M     = Theme.metrics

local Onboarding = WTM:NewModule("Onboarding")
UI.Onboarding = Onboarding

local WIDTH, HEIGHT = 540, 360

--------------------------------------------------------------------------
-- Content
--------------------------------------------------------------------------
--
-- Each step is a title, a body, a one-line hint, and optionally one action.
-- An action declares its own availability, so a step never offers a button
-- that would do nothing on this client.

local STEPS = {
    {
        key   = "welcome",
        title = "Welcome",
        body =
            "This is a diagnostics window for your own client: frame time, FPS, " ..
            "latency, memory, event rate and per-addon cost, sampled continuously " ..
            "and drawn as live graphs.\n\n" ..
            "When your game stutters, it records the seconds before and after the " ..
            "stutter by itself, so you can look at what happened instead of trying " ..
            "to reproduce it.\n\n" ..
            "It reports what it measured. It does not decide what caused a stutter " ..
            "and it will not tell you that a particular addon is to blame.",
        hint = "Frame time is the graph that matters. FPS is an average; frame time shows the individual bad frame.",
    },

    {
        key   = "profiling",
        title = "Per-addon CPU has to be switched on",
        body =
            "WoW only measures how much CPU each addon uses when the client's " ..
            "scriptProfile setting is enabled, and that setting only takes effect " ..
            "after a UI reload.\n\n" ..
            "Until then every per-addon CPU figure reads as unavailable. Nothing is " ..
            "estimated or filled in to cover the gap.\n\n" ..
            "Memory, frame time, FPS, latency and event rates all work without it.",
        hint = "Enabling it here changes the setting only. Reloading is a separate button, and never happens on its own.",
        action = {
            label = "Enable CPU profiling",
            available = function()
                return WTM.Caps:Has("toggleProfiling") and not WTM.Caps:IsCPUProfilingEnabled()
            end,
            unavailable = function()
                if not WTM.Caps:Has("toggleProfiling") then
                    return WTM.Caps:Note("toggleProfiling") or C.TXT_UNAVAILABLE_CLIENT
                end
                return "Already enabled."
            end,
            run = function()
                WTM.Caps:SetCPUProfiling(true)
            end,
        },
    },

    {
        key   = "mini",
        title = "The compact monitor",
        body =
            "A small always-on panel with just the live numbers: FPS, frame time, " ..
            "latency, CPU, memory and event rate. Drag its header to move it.\n\n" ..
            "It collapses to a single line that keeps the frame time and FPS, so it " ..
            "can sit in a corner while you play without taking up space.\n\n" ..
            "Sparklines behind the numbers are optional - they are the expensive " ..
            "part of any graph, and turning them off leaves the numbers.",
        hint = "Its header also has buttons for the settings and the full window.",
        action = {
            label = "Show the compact monitor",
            available = function() return not UI.LiveMonitor:IsShown() end,
            unavailable = function() return "It is already on screen." end,
            run = function() UI.LiveMonitor:Show() end,
        },
    },

    {
        key   = "settings",
        title = "Where everything lives",
        body =
            "One Settings page, inside this addon's own window. Sampling rates, " ..
            "spike thresholds, the flight recorder window, event monitoring, " ..
            "retention, the minimap button - and a button for every chat command, " ..
            "so you never have to memorise one.\n\n" ..
            "Three ways in, all the same place:\n\n" ..
            "the minimap button - left click opens the window, right click goes " ..
            "straight to Settings\n" ..
            "ESC - Options - AddOns - " .. C.ADDON_TITLE .. "\n" ..
            "|cff4c8dff/wtm|r in chat",
        hint = "The entry under Options - AddOns is deliberately just a description and a button; the real settings are here.",
        action = {
            label = "Open Settings now",
            available = function() return true end,
            run = function() UI.MainWindow:Open("settings") end,
        },
    },

    {
        key   = "finish",
        title = "That is everything",
        body =
            "The window is open for you to look around.\n\n" ..
            "Two things worth knowing about how results are worded:\n\n" ..
            "Addon CPU is a running total that WoW exposes, so a figure is always " ..
            "stated with the window it was measured over - never as a share of one " ..
            "specific frame.\n\n" ..
            "Where the client cannot measure something, the panel says so instead of " ..
            "showing a plausible-looking zero.",
        hint = "You can replay this introduction any time from the Settings page.",
    },
}

Onboarding.STEPS = STEPS

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
    step:SetPoint("RIGHT", M.padding * -1, 0)
    step:SetPoint("LEFT", brand, "RIGHT", 8, 0)
    frame.stepText = step

    ------------------------------------------------------------------
    local title = UI.Text(frame, "title", "accent", "LEFT")
    title:SetPoint("TOPLEFT", M.padding, -(40 + M.padding))
    title:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
    title:SetHeight(20)
    frame.title = title

    local body = UI.Text(frame, "body", "textSecondary", "LEFT")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    body:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
    -- Bounded on purpose: a wrapping font string with no height grows downwards
    -- through whatever is beneath it.
    body:SetHeight(HEIGHT - 218)
    UI.Wrap(body, 12)
    body:SetJustifyV("TOP")
    frame.body = body

    -- The optional per-step action, between the body and the hint.
    local action = UI.Button(frame, "", function() Onboarding:RunAction() end,
        { height = 24, primary = true, minWidth = 180 })
    action:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -6)
    frame.actionButton = action

    local hint = UI.Text(frame, "small", "textMuted", "LEFT")
    hint:SetPoint("BOTTOMLEFT", M.padding, 52)
    hint:SetPoint("RIGHT", frame, "RIGHT", -M.padding, 0)
    hint:SetHeight(28)
    UI.Wrap(hint, 2)
    hint:SetJustifyV("BOTTOM")
    frame.hint = hint

    ------------------------------------------------------------------
    -- Always visible, at every step: this is never a dialog you have to
    -- finish to get rid of.
    local skip = UI.Button(frame, "Skip introduction", function()
        Onboarding:Finish()
    end, { height = 24 })
    skip:SetPoint("BOTTOMLEFT", M.padding, M.padding)
    skip.tooltip = "Closes this and does not show it again. It stays available on the Settings page."
    frame.skipButton = skip

    local next_ = UI.Button(frame, "Next", function() Onboarding:Advance(1) end,
        { height = 24, primary = true, minWidth = 110 })
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

    ------------------------------------------------------------------
    -- The step's action, if it has one that is worth offering.
    local action = step.action
    if action then
        frame.actionButton:Show()
        frame.actionButton:SetText(action.label)
        local available = action.available and action.available() or false
        if available then
            frame.actionButton:SetEnabledState(true)
            frame.actionButton.tooltip = nil
        else
            -- Disabled with the reason attached, rather than absent: "why is
            -- there no button here" is a worse question than a greyed one.
            frame.actionButton:SetEnabledState(false,
                action.unavailable and action.unavailable() or nil)
        end
    else
        frame.actionButton:Hide()
    end

    frame.backButton:SetEnabledState(index > 1)
    frame.nextButton:SetText(index == #STEPS and "Finish" or "Next")
end

function Onboarding:RunAction()
    local step = STEPS[self.index or 1]
    if not (step and step.action and step.action.run) then return end
    step.action.run()
    -- Re-render so the button reflects what just happened ("already enabled").
    self:ShowStep(self.index)
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

--- Marks the introduction as seen and closes it. Skip and finishing the last
--- step both land here - both mean "do not show this again".
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
