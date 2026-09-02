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

    --- The caption under the number. It is one line inside a fixed-width card,
    --- so it is FITTED rather than allowed to run to the card's edge and be cut
    --- mid-word: the full text stays available on the card's tooltip.
    function card:SetSub(text, tone)
        text = text or ""
        self.subFull = text
        self.sub:SetText(UI.FitText(self.sub, text))
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

--- A label on the left and a value on the right, on one line.
---
--- Both halves are BOUNDED. They used to be anchored to one edge each and
--- nothing else, so a long label and a long value grew towards each other and
--- met in the middle - which is precisely the "text runs into itself" reported
--- from a real client. The row is split at its centre, each half is fitted to
--- its share with an ellipsis, and the untruncated text stays on the row so a
--- tooltip can show it.
function UI.StatRow(parent, label)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(18)

    row.value = UI.Text(row, "numeric", "textPrimary", "RIGHT")
    row.value:SetPoint("RIGHT")
    row.value:SetPoint("LEFT", row, "CENTER", 0, 0)

    row.label = UI.Text(row, "small", "textSecondary")
    row.label:SetPoint("LEFT")
    row.label:SetPoint("RIGHT", row.value, "LEFT", -6, 0)

    --- Refits the label if the row has been resized since it was last fitted.
    --- A label is normally set once, at build time, when the row has no width
    --- yet and fitting is a no-op; without this it would stay unfitted forever.
    function row:RefitLabel()
        local width = self.label:GetWidth() or 0
        if width > 0 and width ~= self._fittedAt then
            self._fittedAt = width
            self.label:SetText(UI.FitText(self.label, self.labelFull or ""))
        end
    end

    function row:Set(value, tone)
        value = value or "-"
        self.valueFull = value
        self.value:SetText(UI.FitText(self.value, value))
        self.value:SetTextColor(Theme:Tone(tone or nil))
        if not tone then self.value:SetTextColor(T("textPrimary")) end
        self:RefitLabel()
    end
    function row:SetLabel(text)
        text = text or ""
        self.labelFull = text
        self._fittedAt = self.label:GetWidth() or 0
        self.label:SetText(UI.FitText(self.label, text))
    end

    -- Resizing the row changes how much room the label has, and the label is
    -- normally set exactly once, before the row has any size at all.
    row:SetScript("OnSizeChanged", function(self) self:RefitLabel() end)

    row:SetLabel(label or "")
    return row
end
