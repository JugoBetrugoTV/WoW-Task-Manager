--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/Base.lua

    The primitives the rest of the UI is built from.  Deliberately NOT built on
    Blizzard templates: BackdropTemplate, UIPanelButtonTemplate and friends all
    carry the 2005 art style with them, and the whole point of this window is
    that it does not look like that.

    A panel here is a plain frame with a flat fill and hairline borders made
    from 1-pixel textures.  That is also what modern desktop dashboards
    actually are - the "rounded panel" look in Grafana or VS Code is mostly
    hairlines, spacing and restraint rather than corner radii.  WoW cannot draw
    a real border radius without shipping corner artwork, so instead of faking
    it badly this uses crisp edges and leans on spacing and elevation.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local Theme = WTM.UI.Theme
local T     = Theme.Get
local M     = Theme.metrics

local UI = WTM.UI

--------------------------------------------------------------------------
-- Fills and borders
--------------------------------------------------------------------------

function UI.Fill(frame, colorKey, alpha, layer)
    local texture = frame:CreateTexture(nil, layer or "BACKGROUND")
    texture:SetAllPoints(frame)
    texture:SetColorTexture(T(colorKey, alpha))
    return texture
end

--- One-pixel hairline on any combination of edges.
--- edges is a string containing any of "TLBR" - "TB" gives top and bottom only.
function UI.Border(frame, edges, colorKey, alpha, inset)
    edges = edges or "TLBR"
    inset = inset or 0
    local out = {}
    local r, g, b, a = T(colorKey or "borderSubtle", alpha)

    local function edge(point1, point2, horizontal)
        local texture = frame:CreateTexture(nil, "BORDER")
        texture:SetColorTexture(r, g, b, a)
        if horizontal then
            texture:SetHeight(M.borderSize)
            texture:SetPoint(point1, frame, point1, inset, 0)
            texture:SetPoint(point2, frame, point2, -inset, 0)
        else
            texture:SetWidth(M.borderSize)
            texture:SetPoint(point1, frame, point1, 0, -inset)
            texture:SetPoint(point2, frame, point2, 0, inset)
        end
        out[#out + 1] = texture
        return texture
    end

    if edges:find("T") then out.top    = edge("TOPLEFT", "TOPRIGHT", true) end
    if edges:find("B") then out.bottom = edge("BOTTOMLEFT", "BOTTOMRIGHT", true) end
    if edges:find("L") then out.left   = edge("TOPLEFT", "BOTTOMLEFT", false) end
    if edges:find("R") then out.right  = edge("TOPRIGHT", "BOTTOMRIGHT", false) end
    return out
end

--- A panel: flat fill, hairline border, and a barely-there highlight along the
--- top edge that gives it the sense of being lit from above.  That one-pixel
--- highlight is what stops a flat dark rectangle from reading as a hole.
function UI.Panel(parent, opts)
    opts = opts or {}
    local frame = CreateFrame("Frame", nil, parent)
    frame.bg = UI.Fill(frame, opts.color or "panelBg", opts.alpha)
    if opts.border ~= false then
        frame.borders = UI.Border(frame, opts.edges, opts.borderColor or "borderSubtle")
    end
    if opts.highlight ~= false then
        local highlight = frame:CreateTexture(nil, "ARTWORK")
        highlight:SetHeight(1)
        highlight:SetPoint("TOPLEFT", 1, -1)
        highlight:SetPoint("TOPRIGHT", -1, -1)
        highlight:SetColorTexture(1, 1, 1, 0.025)
        frame.topHighlight = highlight
    end
    return frame
end

--- A card is a panel with a title and a generous content inset - the unit the
--- dashboard is built from.
function UI.Card(parent, title, opts)
    opts = opts or {}
    local card = UI.Panel(parent, opts)

    if title then
        card.titleText = card:CreateFontString(nil, "OVERLAY")
        Theme:SetFont(card.titleText, "heading", "textSecondary")
        card.titleText:SetPoint("TOPLEFT", M.padding, -M.paddingSmall - 2)
        card.titleText:SetText(title)
    end

    card.content = CreateFrame("Frame", nil, card)
    card.content:SetPoint("TOPLEFT", M.padding, title and -(M.paddingSmall + 22) or -M.paddingSmall)
    card.content:SetPoint("BOTTOMRIGHT", -M.padding, M.paddingSmall)

    function card:SetTitle(text)
        if self.titleText then self.titleText:SetText(text) end
    end
    return card
end

--------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------

function UI.Text(parent, style, colorKey, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    Theme:SetFont(fs, style or "body", colorKey or "textPrimary")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

--- A label above a value, the shape used everywhere a number is shown.
function UI.LabeledValue(parent, label, valueStyle)
    local group = CreateFrame("Frame", nil, parent)
    group.label = UI.Text(group, "small", "textMuted")
    group.label:SetPoint("TOPLEFT")
    group.label:SetText(label)

    group.value = UI.Text(group, valueStyle or "metric", "textPrimary")
    group.value:SetPoint("TOPLEFT", group.label, "BOTTOMLEFT", 0, -2)

    group.unit = UI.Text(group, "small", "textMuted")
    group.unit:SetPoint("BOTTOMLEFT", group.value, "BOTTOMRIGHT", 3, 2)

    group:SetHeight(46)

    function group:Set(value, unit, colorKey)
        self.value:SetText(value)
        if unit then self.unit:SetText(unit) end
        if colorKey then self.value:SetTextColor(T(colorKey)) end
    end
    return group
end

--------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------
-- Flat, borderless until hovered.  No bevels, no gradients, no Blizzard art.

local function StyleButtonState(button)
    if button.disabled then
        button.bg:SetColorTexture(T("panelAlt", 0.4))
        button.text:SetTextColor(T("textMuted"))
    elseif button.isPrimary then
        button.bg:SetColorTexture(T(button.hovered and "accent" or "accentDim"))
        button.text:SetTextColor(T("textPrimary"))
    elseif button.selected then
        button.bg:SetColorTexture(T("selected"))
        button.text:SetTextColor(T("accent"))
    else
        button.bg:SetColorTexture(T(button.hovered and "hover" or "panelAlt", button.hovered and 1 or 0.8))
        button.text:SetTextColor(T(button.hovered and "textPrimary" or "textSecondary"))
    end
end

function UI.Button(parent, text, onClick, opts)
    opts = opts or {}
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(opts.height or 24)

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()

    button.text = UI.Text(button, opts.style or "body", "textSecondary", "CENTER")
    button.text:SetPoint("CENTER")
    button.text:SetText(text)

    button.isPrimary = opts.primary
    UI.Border(button, "TLBR", opts.primary and "accentDim" or "borderSubtle")

    if not opts.width then
        button:SetWidth(math.max(opts.minWidth or 64, button.text:GetStringWidth() + 24))
    else
        button:SetWidth(opts.width)
    end

    button:SetScript("OnEnter", function(self)
        self.hovered = true
        StyleButtonState(self)
        if self.tooltip then UI.ShowTooltip(self, self.tooltipTitle or text, self.tooltip) end
    end)
    button:SetScript("OnLeave", function(self)
        self.hovered = false
        StyleButtonState(self)
        UI.HideTooltip()
    end)
    button:SetScript("OnClick", function(self, ...)
        if self.disabled then return end
        if onClick then onClick(self, ...) end
    end)

    function button:SetEnabledState(enabled, reason)
        self.disabled = not enabled
        self.tooltip = reason
        StyleButtonState(self)
    end
    function button:SetSelected(selected)
        self.selected = selected
        StyleButtonState(self)
    end
    function button:SetText(newText)
        self.text:SetText(newText)
    end

    StyleButtonState(button)
    return button
end

--- Small pill used for statuses and badges.
function UI.Badge(parent, text, tone)
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetHeight(16)
    badge.bg = badge:CreateTexture(nil, "BACKGROUND")
    badge.bg:SetAllPoints()
    badge.text = UI.Text(badge, "tiny", "textPrimary", "CENTER")
    badge.text:SetPoint("CENTER")

    function badge:Set(newText, newTone)
        self.text:SetText(newText or "")
        local r, g, b = Theme:Tone(newTone or "muted")
        self.bg:SetColorTexture(r, g, b, 0.16)
        self.text:SetTextColor(r, g, b)
        self:SetWidth(math.max(28, self.text:GetStringWidth() + 14))
    end
    badge:Set(text, tone)
    return badge
end

--------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------

--- Thin horizontal fill bar, used in table cells to make magnitudes scannable
--- without reading every number.
function UI.MiniBar(parent, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(height or 3)
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetAllPoints()
    bar.track:SetColorTexture(T("borderSubtle", 0.6))

    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetPoint("TOPLEFT")
    bar.fill:SetPoint("BOTTOMLEFT")
    bar.fill:SetWidth(1)

    function bar:SetValue(fraction, tone)
        fraction = math.max(0, math.min(1, fraction or 0))
        local width = self:GetWidth() or 0
        if width <= 0 then width = 100 end
        self.fill:SetWidth(math.max(1, width * fraction))
        self.fill:SetColorTexture(Theme:Tone(tone or "accent", 0.9))
        self.fill:SetShown(fraction > 0)
    end
    return bar
end

--- A separator line with optional label, for grouping inside a page.
function UI.Divider(parent, label)
    local divider = CreateFrame("Frame", nil, parent)
    divider:SetHeight(label and 20 or 1)

    local line = divider:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetColorTexture(T("borderSubtle"))

    if label then
        divider.text = UI.Text(divider, "small", "textMuted")
        divider.text:SetPoint("LEFT")
        divider.text:SetText(label)
        line:SetPoint("LEFT", divider.text, "RIGHT", 8, 0)
        line:SetPoint("RIGHT")
    else
        line:SetPoint("LEFT")
        line:SetPoint("RIGHT")
    end
    divider.line = line
    return divider
end

--------------------------------------------------------------------------
-- Search box
--------------------------------------------------------------------------

function UI.SearchBox(parent, placeholder, onChanged)
    local frame = UI.Panel(parent, { color = "panelAlt" })
    frame:SetHeight(24)

    local edit = CreateFrame("EditBox", nil, frame)
    edit:SetPoint("TOPLEFT", 8, 0)
    edit:SetPoint("BOTTOMRIGHT", -22, 0)
    edit:SetAutoFocus(false)
    Theme:SetFont(edit, "body", "textPrimary")
    edit:SetTextColor(Theme.Get("textPrimary"))

    local hint = UI.Text(frame, "body", "textMuted")
    hint:SetPoint("LEFT", 8, 0)
    hint:SetText(placeholder or "Search")

    local clear = UI.Button(frame, "x", function()
        edit:SetText("")
        edit:ClearFocus()
    end, { width = 16, height = 16, style = "small" })
    clear:SetPoint("RIGHT", -4, 0)
    clear:Hide()

    edit:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        hint:SetShown(text == "")
        clear:SetShown(text ~= "")
        if onChanged then onChanged(text) end
    end)
    edit:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    frame.edit = edit
    function frame:GetText() return edit:GetText() end
    function frame:SetText(t) edit:SetText(t or "") end
    return frame
end

--------------------------------------------------------------------------
-- Tab strip
--------------------------------------------------------------------------
-- Underline-style tabs; the active one gets a 2px accent rule rather than a
-- raised chrome tab.

function UI.TabStrip(parent, items, onSelect)
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(30)
    strip.buttons = {}
    strip.selected = nil

    local x = 0
    for i, item in ipairs(items) do
        local tab = CreateFrame("Button", nil, strip)
        tab:SetHeight(30)
        tab.text = UI.Text(tab, "body", "textSecondary", "CENTER")
        tab.text:SetPoint("CENTER", 0, 1)
        tab.text:SetText(item.label or item)
        tab:SetWidth(tab.text:GetStringWidth() + 26)
        tab:SetPoint("BOTTOMLEFT", x, 0)
        x = x + tab:GetWidth()

        tab.rule = tab:CreateTexture(nil, "ARTWORK")
        tab.rule:SetHeight(2)
        tab.rule:SetPoint("BOTTOMLEFT", 6, 0)
        tab.rule:SetPoint("BOTTOMRIGHT", -6, 0)
        tab.rule:SetColorTexture(T("accent"))
        tab.rule:Hide()

        tab.key = item.key or item
        tab:SetScript("OnEnter", function(self)
            if strip.selected ~= self then self.text:SetTextColor(T("textPrimary")) end
        end)
        tab:SetScript("OnLeave", function(self)
            if strip.selected ~= self then self.text:SetTextColor(T("textSecondary")) end
        end)
        tab:SetScript("OnClick", function(self) strip:Select(self.key) end)

        strip.buttons[i] = tab
    end

    local baseline = strip:CreateTexture(nil, "BACKGROUND")
    baseline:SetHeight(1)
    baseline:SetPoint("BOTTOMLEFT")
    baseline:SetPoint("BOTTOMRIGHT")
    baseline:SetColorTexture(T("borderSubtle"))

    function strip:Select(key)
        for _, tab in ipairs(self.buttons) do
            local active = tab.key == key
            tab.rule:SetShown(active)
            tab.text:SetTextColor(T(active and "textPrimary" or "textSecondary"))
            if active then self.selected = tab end
        end
        self.selectedKey = key
        if onSelect then onSelect(key) end
    end

    return strip
end

--------------------------------------------------------------------------
-- Empty / unavailable states
--------------------------------------------------------------------------
-- Used wherever a capability is missing.  The feature stays visible and
-- explains itself instead of silently disappearing, which is the whole point
-- of being honest about what the sandbox allows.

function UI.NoticePanel(parent, title, message, actionLabel, onAction, tone)
    local panel = UI.Panel(parent, { color = "panelAlt" })

    local accent = panel:CreateTexture(nil, "ARTWORK")
    accent:SetWidth(2)
    accent:SetPoint("TOPLEFT")
    accent:SetPoint("BOTTOMLEFT")
    accent:SetColorTexture(Theme:Tone(tone or "warn"))

    panel.title = UI.Text(panel, "heading", "textPrimary")
    panel.title:SetPoint("TOPLEFT", 14, -10)
    panel.title:SetText(title)

    panel.message = UI.Text(panel, "small", "textSecondary")
    panel.message:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -5)
    panel.message:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    panel.message:SetJustifyH("LEFT")
    panel.message:SetText(message or "")
    panel.message:SetWordWrap(true)

    local height = 44 + (panel.message:GetStringHeight() or 12)

    if actionLabel and onAction then
        panel.action = UI.Button(panel, actionLabel, onAction, { primary = true, height = 22 })
        panel.action:SetPoint("TOPLEFT", panel.message, "BOTTOMLEFT", 0, -8)
        height = height + 30
    end

    panel:SetHeight(height)

    function panel:SetMessage(text)
        self.message:SetText(text or "")
        self:SetHeight(44 + (self.message:GetStringHeight() or 12) + (self.action and 30 or 0))
    end
    return panel
end

--- Centered placeholder for a table or graph that has nothing to show yet.
function UI.EmptyState(parent, message)
    local frame = CreateFrame("Frame", nil, parent)
    frame.text = UI.Text(frame, "body", "textMuted", "CENTER")
    frame.text:SetPoint("CENTER")
    frame.text:SetText(message or "No data yet")
    function frame:SetMessage(text) self.text:SetText(text) end
    return frame
end

--------------------------------------------------------------------------
-- Misc helpers
--------------------------------------------------------------------------

--- Makes a frame draggable by `handle`, clamped to the screen.
function UI.MakeMovable(frame, handle, onStop)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function() frame:StartMoving() end)
    handle:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        if onStop then onStop() end
    end)
end

--- Adds a bottom-right resize grip drawn from plain textures.
function UI.MakeResizable(frame, minWidth, minHeight, onStop)
    frame:SetResizable(true)
    -- The setter was renamed in Retail 10.0; older clients only have the pair
    -- form.  Try both, quietly.
    if frame.SetResizeBounds then
        pcall(frame.SetResizeBounds, frame, minWidth, minHeight)
    elseif frame.SetMinResize then
        pcall(frame.SetMinResize, frame, minWidth, minHeight)
    end

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    for i = 1, 3 do
        local line = grip:CreateTexture(nil, "OVERLAY")
        line:SetSize(9 - (i - 1) * 3, 1)
        line:SetPoint("BOTTOMRIGHT", 0, (i - 1) * 3 + 1)
        line:SetColorTexture(T("textMuted", 0.5))
    end

    grip:SetScript("OnMouseDown", function()
        if frame.StartSizing then frame:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        if onStop then onStop() end
    end)
    return grip
end

function UI.Anchor(frame, parent, point, relativePoint, x, y)
    frame:ClearAllPoints()
    frame:SetPoint(point, parent, relativePoint or point, x or 0, y or 0)
    return frame
end
