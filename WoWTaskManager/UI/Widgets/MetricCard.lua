--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Widgets/MetricCard.lua

    The dashboard tile: a label, one large number, its unit, an optional
    secondary line and a sparkline across the bottom.

    A card can also be in an "unavailable" state, which is used wherever a
    capability is missing.  The tile stays in the layout and explains itself
    rather than disappearing - a missing tile looks like a bug, an explained
    one looks like a limitation, and the second is the truth.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics

function UI.MetricCard(parent, opts)
    opts = opts or {}
    local card = UI.Panel(parent, {})
    card:SetHeight(opts.height or M.cardHeight)

    card.label = UI.Text(card, "small", "textMuted")
    card.label:SetPoint("TOPLEFT", 14, -10)
    card.label:SetText(opts.label or "")

    card.value = UI.Text(card, opts.valueStyle or "metric", "textPrimary")
    card.value:SetPoint("TOPLEFT", 13, -26)
    card.value:SetText("-")

    card.unit = UI.Text(card, "small", "textMuted")
    card.unit:SetPoint("BOTTOMLEFT", card.value, "BOTTOMRIGHT", 4, 3)
    card.unit:SetText(opts.unit or "")

    card.sub = UI.Text(card, "tiny", "textMuted")
    card.sub:SetPoint("TOPLEFT", card.value, "BOTTOMLEFT", 1, -1)
    card.sub:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.sub:SetJustifyH("LEFT")
    card.sub:SetHeight(11)

    -- Status dot in the top right, driven by tone.
    card.dot = card:CreateTexture(nil, "OVERLAY")
    card.dot:SetSize(6, 6)
    card.dot:SetPoint("TOPRIGHT", -12, -13)
    card.dot:Hide()

    -- Sparkline hugging the bottom edge.
    card.spark = UI.Sparkline(card, opts.colorIndex or 1, opts.worstIsLow)
    card.spark:SetPoint("BOTTOMLEFT", 1, 1)
    card.spark:SetPoint("BOTTOMRIGHT", -1, 1)
    card.spark:SetHeight(opts.sparkHeight or 22)

    -- The reason a measurement is unavailable can be a sentence, and a card is
    -- ~150 px wide. Two lines, then it clips: the full text is in the tooltip.
    card.notice = UI.Text(card, "tiny", "textMuted")
    card.notice:SetPoint("TOPLEFT", 13, -28)
    card.notice:SetPoint("RIGHT", card, "RIGHT", -11, 0)
    card.notice:SetJustifyH("LEFT")
    card.notice:SetJustifyV("TOP")
    UI.Wrap(card.notice, 3)
    card.notice:Hide()

    ------------------------------------------------------------------

    function card:SetValue(value, unit, tone)
        self.value:SetText(value)
        if unit ~= nil then self.unit:SetText(unit) end
        if tone then
            self.value:SetTextColor(Theme:Tone(tone))
            self.dot:SetColorTexture(Theme:Tone(tone))
            self.dot:Show()
        else
            self.value:SetTextColor(T("textPrimary"))
            self.dot:Hide()
        end
    end

    function card:SetSub(text, tone)
        self.sub:SetText(text or "")
        self.sub:SetTextColor(Theme:Tone(tone or "muted"))
    end

    --- Puts the card into its "this cannot be measured here" state.
    function card:SetUnavailable(reason)
        self.unavailableReason = reason
        self.value:Hide()
        self.unit:Hide()
        self.sub:Hide()
        self.spark:Hide()
        self.dot:Hide()
        self.notice:SetText(reason or WTM.C.TXT_UNAVAILABLE_CLIENT)
        self.notice:Show()
        self.unavailable = true
    end

    function card:SetAvailable()
        if not self.unavailable then return end
        self.value:Show()
        self.unit:Show()
        self.sub:Show()
        self.spark:Show()
        self.notice:Hide()
        self.unavailable = false
    end

    function card:SetRing(ring)
        self.spark:SetRing(ring)
    end

    function card:Refresh()
        if not self.unavailable then self.spark:Draw() end
    end

    -- Always hoverable: the card is too small for a full explanation, so the
    -- tooltip carries it - including the reason a value is unavailable, which
    -- may be clipped on the card itself.
    card:EnableMouse(true)
    card:SetScript("OnEnter", function(self)
        UI.TooltipClear(opts.label or "")
        if self.unavailable and self.unavailableReason then
            UI.TooltipLine(self.unavailableReason, nil, "warn")
            UI.TooltipLine("", "")
        end
        if opts.tooltip then
            local line = ""
            for word in tostring(opts.tooltip):gmatch("%S+") do
                if #line + #word + 1 > 58 then
                    UI.TooltipLine(line, nil, "muted")
                    line = word
                else
                    line = (line == "") and word or (line .. " " .. word)
                end
            end
            if line ~= "" then UI.TooltipLine(line, nil, "muted") end
        end
        UI.TooltipShow(self)
    end)
    card:SetScript("OnLeave", UI.HideTooltip)

    return card
end

--------------------------------------------------------------------------
-- Compact stat row: label on the left, value on the right
--------------------------------------------------------------------------

function UI.StatRow(parent, label)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(18)

    row.label = UI.Text(row, "small", "textSecondary")
    row.label:SetPoint("LEFT")
    row.label:SetText(label or "")

    row.value = UI.Text(row, "numeric", "textPrimary", "RIGHT")
    row.value:SetPoint("RIGHT")

    function row:Set(value, tone)
        self.value:SetText(value or "-")
        self.value:SetTextColor(Theme:Tone(tone or nil))
        if not tone then self.value:SetTextColor(T("textPrimary")) end
    end
    function row:SetLabel(text) self.label:SetText(text) end
    return row
end
