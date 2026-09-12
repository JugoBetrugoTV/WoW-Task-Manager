--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Alerts.lua

    Thresholds you set, and what has tripped them.

    Every rule reads a number the sampler is already producing. None of them
    adds a timer, an event listener or an OnUpdate of its own - they are all
    evaluated in one pass on an existing tick. A monitoring feature that needs
    its own watchdog per rule is how a diagnostic tool becomes the thing worth
    diagnosing.

    A rule that cannot be measured on this client is shown disabled with the
    reason attached, rather than being silently never triggered.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("alerts", {})

--------------------------------------------------------------------------

local function BuildRuleRow(parent, rule)
    local row = UI.Panel(parent, {})
    row:SetHeight(58)

    row.check = CreateFrame("Button", nil, row)
    row.check:SetSize(16, 16)
    row.check:SetPoint("TOPLEFT", 12, -11)
    UI.Fill(row.check, "panelAlt")
    UI.Border(row.check, "TLBR", "borderStrong")
    row.check.mark = row.check:CreateTexture(nil, "ARTWORK")
    row.check.mark:SetPoint("CENTER")
    row.check.mark:SetSize(8, 8)
    row.check.mark:SetColorTexture(Theme:Tone("ok"))
    row.check.mark:Hide()

    row.label = UI.Text(row, "small", "textPrimary", "LEFT")
    row.label:SetPoint("TOPLEFT", row.check, "TOPRIGHT", 8, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -150, 0)
    row.label:SetText(rule.label)

    row.current = UI.Text(row, "numericSm", "textMuted", "RIGHT")
    row.current:SetPoint("TOPRIGHT", -12, -10)
    row.current:SetWidth(130)

    row.help = UI.Text(row, "tiny", "textMuted", "LEFT")
    row.help:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -2)
    row.help:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    row.help:SetHeight(24)
    UI.Wrap(row.help, 2)
    row.help:SetJustifyV("TOP")
    row.help:SetText(rule.help)

    row.rule = rule
    return row
end

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Master switch and delivery
    ------------------------------------------------------------------
    local header = UI.Panel(frame, {})
    header:SetHeight(66)
    header:SetPoint("TOPLEFT", pad, -pad)
    header:SetPoint("TOPRIGHT", -pad, -pad)
    self.header = header

    self.masterButton = UI.Button(header, "", function()
        local settings = WTM.db.profile.alerts
        settings.enabled = not settings.enabled
        self:Refresh()
    end, { height = 26, primary = true, minWidth = 150 })
    self.masterButton:SetPoint("TOPLEFT", 12, -12)
    self.masterButton.tooltip = "Turns every rule on or off at once. Individual rules keep their own settings."

    self.masterState = UI.Text(header, "small", "textMuted", "LEFT")
    self.masterState:SetPoint("TOPLEFT", self.masterButton, "TOPRIGHT", 12, -6)
    self.masterState:SetPoint("RIGHT", header, "RIGHT", -12, 0)

    self.deliveryButtons = {}
    local DELIVERY = {
        { key = "chat",   label = "Chat message",
          tip = "Prints one line to your chat frame." },
        { key = "marker", label = "Timeline marker",
          tip = "Drops a marker on the shared time axis, so an alert can be found again afterwards." },
        { key = "sound",  label = "Sound",
          tip = "Plays the raid warning sound. Feature-detected: a client without the sound kit simply stays silent." },
    }
    local previous
    for _, delivery in ipairs(DELIVERY) do
        local button = UI.Button(header, delivery.label, function()
            local settings = WTM.db.profile.alerts
            settings[delivery.key] = not settings[delivery.key]
            self:Refresh()
        end, { height = 22, style = "small" })
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
        else
            button:SetPoint("TOPLEFT", self.masterButton, "BOTTOMLEFT", 0, -6)
        end
        button.tooltip = delivery.tip
        self.deliveryButtons[delivery.key] = button
        previous = button
    end

    self.cooldownNote = UI.Text(header, "tiny", "textMuted", "LEFT")
    self.cooldownNote:SetPoint("LEFT", previous, "RIGHT", 14, 0)
    self.cooldownNote:SetPoint("RIGHT", header, "RIGHT", -12, 0)
    self.cooldownNote:SetHeight(14)

    ------------------------------------------------------------------
    -- Rules
    ------------------------------------------------------------------
    local scroll, canvas = UI.ScrollCanvas(frame, { padding = 0 })
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -M.cardGap)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad + 170)
    self.scroll, self.canvas = scroll, canvas

    local grid = UI.Grid(canvas, { minColumnWidth = 330, maxColumns = 3, gap = 8 })
    self.grid = grid

    self.ruleRows = {}
    for _, rule in ipairs(WTM.Alerts.RULES) do
        local row = BuildRuleRow(canvas, rule)
        grid:Add(row, { span = 1, height = 58, key = rule.key })
        self.ruleRows[rule.key] = row

        -- Threshold control, built after the row so it can anchor into it.
        row.less = UI.Button(row, "-", function()
            local config = WTM.Alerts:Config(rule.key)
            config.threshold = math.max(rule.min, config.threshold - rule.step)
            self:Refresh()
        end, { width = 20, height = 18, style = "tiny" })
        row.less:SetPoint("BOTTOMRIGHT", -12, 8)

        row.threshold = UI.Text(row, "numericSm", "textPrimary", "RIGHT")
        row.threshold:SetPoint("RIGHT", row.less, "LEFT", -6, 0)
        row.threshold:SetWidth(78)

        row.more = UI.Button(row, "+", function()
            local config = WTM.Alerts:Config(rule.key)
            config.threshold = math.min(rule.max, config.threshold + rule.step)
            self:Refresh()
        end, { width = 20, height = 18, style = "tiny" })
        row.more:SetPoint("RIGHT", row.threshold, "LEFT", -4, 0)

        row.check:SetScript("OnClick", function()
            local config = WTM.Alerts:Config(rule.key)
            config.enabled = not config.enabled
            self:Refresh()
        end)
        row.check:SetScript("OnEnter", function(self2)
            UI.ShowTooltip(self2, rule.label, rule.help)
        end)
        row.check:SetScript("OnLeave", UI.HideTooltip)
    end

    ------------------------------------------------------------------
    -- What has fired
    ------------------------------------------------------------------
    self.log = UI.TopList(frame, "RECENT ALERTS", { rows = 6, wideValue = true })
    self.log:SetPoint("BOTTOMLEFT", pad, pad)
    self.log:SetPoint("BOTTOMRIGHT", -pad, pad)
    -- The widget works out what six rows plus its chrome need; a hand-written
    -- 160 was four pixels short of it and clipped the last row.
    self.log:SetHeight(self.log.naturalHeight or 160)

    self.clearButton = UI.Button(self.log, "Clear", function()
        WTM.Alerts:ClearLog()
        self:Refresh()
    end, { height = 18, style = "tiny", minWidth = 52 })
    self.clearButton:SetPoint("TOPRIGHT", -8, -6)
    self.clearButton.tooltip = "Empties the list below. Timeline markers already placed are not removed."

    self:OnLayout()
end

--- `force` is only passed when the set of visible cells has changed. A
--- relayout resizes every cell, and a resize is not free - doing it on every
--- refresh made the grid itself the most expensive thing on the page.
function Page:OnLayout(force)
    if not self.grid then return end
    self.scroll:SyncWidth()
    self.canvas:SetHeight(self.grid:Layout(force))
end

function Page:OnShow() self:Refresh() end

--------------------------------------------------------------------------

function Page:Refresh()
    if not self.grid then return end
    self:OnLayout()

    local settings = WTM.db.profile.alerts
    local enabled, blocked = WTM.Alerts:CountActive()

    self.masterButton:SetText(settings.enabled and "Alerts are ON" or "Alerts are OFF")
    self.masterState:SetText(UI.FitText(self.masterState, settings.enabled
        and ("%d rule%s active%s"):format(enabled, enabled == 1 and "" or "s",
            blocked > 0 and (", %d cannot run on this client"):format(blocked) or "")
        or "No rule is being evaluated."))

    for key, button in pairs(self.deliveryButtons) do
        button:SetSelected(settings[key] and true or false)
        button:SetEnabledState(settings.enabled,
            "Turn alerts on first.")
    end
    self.cooldownNote:SetText(UI.FitText(self.cooldownNote,
        ("Each rule waits %d s before it can fire again."):format(settings.cooldown or 30)))

    ------------------------------------------------------------------
    for _, rule in ipairs(WTM.Alerts.RULES) do
        local row    = self.ruleRows[rule.key]
        local config = WTM.Alerts:Config(rule.key)
        local reason = WTM.Alerts:UnavailableReason(rule)
        local state  = WTM.Alerts.state[rule.key]

        row.check.mark:SetShown(config.enabled and not reason)
        row.threshold:SetText(UI.FitText(row.threshold, rule.format(config.threshold)))

        if reason then
            row.current:SetText("unavailable")
            row.current:SetTextColor(T("textMuted"))
            row.help:SetText(reason)
            row.less:SetEnabledState(false, reason)
            row.more:SetEnabledState(false, reason)
        else
            local ok, value = pcall(rule.read)
            local current = ok and value or 0
            row.current:SetText(UI.FitText(row.current, rule.format(current)))
            if config.enabled and current > config.threshold then
                row.current:SetTextColor(Theme:Tone("warn"))
            else
                row.current:SetTextColor(T("textMuted"))
            end
            row.help:SetText(state and state.count > 0
                and ("%s  -  fired %d time%s this session")
                    :format(rule.help, state.count, state.count == 1 and "" or "s")
                or rule.help)
            row.less:SetEnabledState(true)
            row.more:SetEnabledState(true)
        end
    end

    ------------------------------------------------------------------
    local entries = {}
    local log = WTM.Alerts.log
    for i = #log, math.max(1, #log - 5), -1 do
        local entry = log[i]
        if entry then
            entries[#entries + 1] = {
                name = ("%s  %s"):format(
                    Fmt.Clock(entry.at, WTM.state.sessionEpoch, WTM.state.sessionStart),
                    entry.label),
                value = entry.text,
                tone = "warn",
                tooltipTitle = entry.label,
                tooltipLines = {
                    { "Value", entry.text },
                    { "Threshold", tostring(entry.threshold) },
                    { "Zone", entry.zone or "unknown" },
                    { "In combat", entry.combat and "yes" or "no" },
                },
            }
        end
    end
    self.log:SetEntries(entries, settings.enabled
        and "Nothing has crossed a threshold yet."
        or "Alerts are switched off, so nothing is being evaluated.")
end
