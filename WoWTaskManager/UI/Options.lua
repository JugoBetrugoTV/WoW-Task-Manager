--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Options.lua

    The entry under ESC -> Options -> AddOns.

    It is deliberately almost empty. Every setting this addon has lives on its
    own Settings page, inside its own window, where there is room to explain
    what each one measures. Duplicating them here would mean two lists that
    disagree the first time one of them is edited. So this panel is a short
    explanation and one button.

    Three registration APIs exist across the four supported clients and none of
    them is present everywhere, so all three are feature-detected:

        Settings.RegisterCanvasLayoutCategory   modern (Retail, and any client
        + Settings.RegisterAddOnCategory        that has backported it)
        InterfaceOptions_AddCategory            older clients
        (neither)                               no panel; the addon still works

    Nothing here assumes a client. If no registration API is found, the panel
    simply does not exist and /wtm and the minimap button are unaffected.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme

local Options = WTM:NewModule("Options")
UI.Options = Options

Options.registered = false
Options.method = nil

--------------------------------------------------------------------------

local BLURB =
    "Everything this addon does lives in its own window: live frame time, " ..
    "FPS and latency graphs, a per-addon process list, recorded stutter " ..
    "incidents with the seconds before and after them, and every setting " ..
    "with an explanation of what it actually measures."

local SECOND_LINE =
    "Its settings are not duplicated here on purpose - one list is easier to " ..
    "trust than two."

--------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------

function Options:BuildPanel()
    if self.panel then return self.panel end

    local panel = CreateFrame("Frame", "WTMOptionsPanel", UIParent)
    panel.name = C.ADDON_TITLE
    panel:Hide()
    self.panel = panel

    local title = UI.Text(panel, "title", "textPrimary", "LEFT")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(C.ADDON_TITLE)

    local version = UI.Text(panel, "small", "textMuted", "LEFT")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    version:SetText("Version " .. C.VERSION)

    local blurb = UI.Text(panel, "body", "textSecondary", "LEFT")
    blurb:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -16)
    blurb:SetPoint("RIGHT", panel, "RIGHT", -32, 0)
    blurb:SetHeight(64)
    UI.Wrap(blurb, 4)
    blurb:SetText(BLURB)
    blurb:SetJustifyV("TOP")

    local second = UI.Text(panel, "body", "textMuted", "LEFT")
    second:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -10)
    second:SetPoint("RIGHT", panel, "RIGHT", -32, 0)
    second:SetHeight(32)
    UI.Wrap(second, 2)
    second:SetText(SECOND_LINE)

    local open = UI.Button(panel, "Open " .. C.ADDON_TITLE, function()
        Options:CloseBlizzardOptions()
        UI.MainWindow:Open("dashboard")
    end, { height = 26 })
    open:SetPoint("TOPLEFT", second, "BOTTOMLEFT", 0, -20)
    open:SetWidth(220)
    open.tooltip = "Opens the addon window. Same as typing /wtm."
    self.openButton = open

    local settings = UI.Button(panel, "Open settings directly", function()
        Options:CloseBlizzardOptions()
        UI.MainWindow:Open("settings")
    end, { height = 26 })
    settings:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -8)
    settings:SetWidth(220)
    settings.tooltip = "Opens the addon window on its Settings page. Same as typing /wtm settings."

    local hint = UI.Text(panel, "small", "textMuted", "LEFT")
    hint:SetPoint("TOPLEFT", settings, "BOTTOMLEFT", 0, -18)
    hint:SetPoint("RIGHT", panel, "RIGHT", -32, 0)
    hint:SetHeight(48)
    UI.Wrap(hint, 3)
    hint:SetText("Chat commands: /wtm opens the window, /wtm mini toggles the " ..
        "compact live monitor. Every command also exists as a button on the " ..
        "addon's own Settings page.")

    return panel
end

--------------------------------------------------------------------------

--- Closes whichever options frame this client uses, if it is safe to do so.
--- Blizzard's own addon panels do the same thing; it is guarded because
--- hiding a UI panel during combat lockdown is not permitted.
function Options:CloseBlizzardOptions()
    if InCombatLockdown and InCombatLockdown() then return end
    local frame = _G.SettingsPanel or _G.InterfaceOptionsFrame
    if frame and frame:IsShown() and _G.HideUIPanel then
        pcall(_G.HideUIPanel, frame)
    end
end

--- Opens this addon's own panel inside the Blizzard options, if the client
--- offers a way to. Returns false with a reason when it does not.
function Options:OpenBlizzardPanel()
    if not self.registered then
        return false, self.unavailable or "No options panel is registered on this client"
    end
    if self.method == "settings" and _G.Settings and _G.Settings.OpenToCategory then
        local ok = pcall(_G.Settings.OpenToCategory, self.categoryID)
        if ok then return true end
    elseif _G.InterfaceOptionsFrame_OpenToCategory then
        -- The double call is not superstition: on the clients that have this
        -- function, the first call only expands the AddOns list and the second
        -- actually selects the panel.
        pcall(_G.InterfaceOptionsFrame_OpenToCategory, self.panel)
        pcall(_G.InterfaceOptionsFrame_OpenToCategory, self.panel)
        return true
    end
    return false, "This client would not open the panel"
end

--------------------------------------------------------------------------

function Options:Register()
    if self.registered then return true end
    local panel = self:BuildPanel()

    local Settings = _G.Settings
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, C.ADDON_TITLE)
        if ok and category then
            category.ID = category.ID or C.ADDON_TITLE
            pcall(Settings.RegisterAddOnCategory, category)
            self.category = category
            self.categoryID = category.ID
            self.method = "settings"
            self.registered = true
            return true
        end
    end

    if _G.InterfaceOptions_AddCategory then
        local ok = pcall(_G.InterfaceOptions_AddCategory, panel)
        if ok then
            self.method = "interfaceOptions"
            self.registered = true
            return true
        end
    end

    self.unavailable =
        "This client exposes neither Settings.RegisterAddOnCategory nor " ..
        "InterfaceOptions_AddCategory, so no entry can be added under " ..
        "Options - AddOns. Use /wtm instead."
    return false
end

--------------------------------------------------------------------------

function Options:OnEnable()
    self:Register()
end
