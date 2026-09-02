--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/MinimapButton.lua

    A minimap button, drawn rather than shipped as artwork.

    LibDBIcon would normally do this, but it is not present and the addon has
    no dependencies. The whole button is a few textures on a frame: the round
    Blizzard tracking border, a dark disc, and a small live FPS readout - which
    is more useful on a minimap button than a logo would be.

    Position is stored as an angle around the minimap, which is how every
    minimap button behaves and is what makes dragging feel right.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local Fmt   = WTM.Format

local MinimapButton = WTM:NewModule("MinimapButton")
UI.MinimapButton = MinimapButton

local BUTTON_SIZE = 31
local ORBIT_RADIUS = 80

--------------------------------------------------------------------------

local function PositionOnMinimap(button, angle)
    local minimap = _G.Minimap
    if not minimap then return end
    local radians = math.rad(angle)
    -- Minimap buttons orbit the centre; 52..80 keeps it clear of the ring art
    -- on both round and square minimaps.
    local radius = ORBIT_RADIUS
    button:ClearAllPoints()
    button:SetPoint("CENTER", minimap, "CENTER",
        math.cos(radians) * radius, math.sin(radians) * radius)
end

--------------------------------------------------------------------------

function MinimapButton:Build()
    if self.button then return self.button end
    if not _G.Minimap then
        -- No minimap on this client or it is not created yet; the addon simply
        -- has no minimap button rather than erroring.
        self.unavailable = "No Minimap frame exists on this client"
        return nil
    end

    local settings = WTM.db.profile.minimap

    local button = CreateFrame("Button", "WTMMinimapButton", _G.Minimap)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((_G.Minimap:GetFrameLevel() or 1) + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    self.button = button

    -- Dark disc behind everything.
    local disc = button:CreateTexture(nil, "BACKGROUND")
    disc:SetSize(20, 20)
    disc:SetPoint("CENTER", 0, 0)
    disc:SetColorTexture(T("windowBg", 0.9))
    button.disc = disc

    -- A small accent square, matching the window's brand mark.
    local mark = button:CreateTexture(nil, "ARTWORK")
    mark:SetSize(5, 5)
    mark:SetPoint("CENTER", 0, 5)
    mark:SetColorTexture(T("accent"))
    button.mark = mark

    -- Live FPS, which is the number people actually want at a glance.
    button.text = UI.Text(button, "numericSm", "textPrimary", "CENTER")
    button.text:SetPoint("CENTER", 0, -3)
    button.text:SetText("--")

    -- Blizzard's standard tracking-border ring, so it reads as a minimap button
    -- rather than a floating square.
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button.border = border

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetSize(20, 20)
    highlight:SetPoint("CENTER")
    highlight:SetColorTexture(T("accent", 0.25))

    ------------------------------------------------------------------
    -- Interaction
    ------------------------------------------------------------------
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            UI.LiveMonitor:Toggle()
        else
            UI.MainWindow:Toggle()
        end
    end)

    button:SetScript("OnEnter", function(self2)
        UI.TooltipClear(C.ADDON_TITLE)
        UI.TooltipLine("FPS", Fmt.FPS(WTM.FrameTime.current.fps))
        UI.TooltipLine("Frame time", Fmt.Ms(WTM.FrameTime.current.avgMs))
        UI.TooltipLine("Spikes", tostring(WTM.SpikeDetector.total))
        UI.TooltipLine("Own overhead", ("%.2f ms/s"):format(WTM.Overhead.current.totalMsPerSec))
        UI.TooltipLine("", "")
        UI.TooltipLine("Left click", "open the window", "muted")
        UI.TooltipLine("Right click", "toggle the live monitor", "muted")
        UI.TooltipLine("Drag", "move around the minimap", "muted")
        UI.TooltipShow(self2)
    end)
    button:SetScript("OnLeave", UI.HideTooltip)

    local dragging
    button:SetScript("OnDragStart", function() dragging = true end)
    -- OnUpdate already writes the angle on every frame of the drag, so there is
    -- nothing left to record here.
    button:SetScript("OnDragStop", function() dragging = false end)
    button:SetScript("OnUpdate", function()
        if not dragging then return end
        -- Follow the cursor around the minimap's centre.
        local minimap = _G.Minimap
        local scale = minimap:GetEffectiveScale()
        local cx, cy = minimap:GetCenter()
        local mx, my = GetCursorPosition()
        mx, my = mx / scale, my / scale
        local angle = math.deg(math.atan2(my - cy, mx - cx))
        settings.angle = angle
        PositionOnMinimap(button, angle)
    end)

    PositionOnMinimap(button, settings.angle or 200)
    button:SetShown(settings.shown ~= false)
    return button
end

--------------------------------------------------------------------------

function MinimapButton:Refresh()
    local button = self.button
    if not button or not button:IsShown() then return end
    local fps = WTM.FrameTime.current.fps
    button.text:SetText(fps > 0 and ("%d"):format(fps + 0.5) or "--")
    button.text:SetTextColor(Theme:Tone(
        fps >= 55 and "ok" or (fps >= 30 and "warn" or "crit")))
    -- The mark turns amber while a spike burst is active, so the button itself
    -- says whether anything is happening.
    button.mark:SetColorTexture(Theme:Tone(
        WTM.Scheduler:IsBursting() and "warn" or "accent"))
end

function MinimapButton:SetShown(shown)
    WTM.db.profile.minimap.shown = shown and true or false
    if shown then
        self:Build()
        if self.button then self.button:Show() end
    elseif self.button then
        self.button:Hide()
    end
    WTM.Scheduler:SetEnabled("minimap", self:IsShown())
end

function MinimapButton:Toggle()
    self:SetShown(not self:IsShown())
    return self:IsShown()
end

--- Why there is no button, when there is no button.
function MinimapButton:UnavailableReason()
    return self.unavailable
end

function MinimapButton:IsShown()
    return self.button and self.button:IsShown() or false
end

function MinimapButton:OnEnable()
    -- The button carries a live FPS readout, so it needs a refresh of its own:
    -- the "ui" task only runs while the main window is open, and the button is
    -- most useful exactly when it is not. One text update per second is the
    -- cheapest thing this addon does, and it is disabled outright when the
    -- button is hidden.
    WTM.Scheduler:Register("minimap", function() MinimapButton:Refresh() end,
        1, 0.5, 0.5, "ui")

    if WTM.db.profile.minimap.shown ~= false then
        self:Build()
    end
    WTM.Scheduler:SetEnabled("minimap", self:IsShown())
end
