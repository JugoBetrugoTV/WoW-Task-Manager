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

    -- The caption was anchored to the left edge and nothing else, so a long
    -- one ran straight out of the card. Bounded to the card's right edge and
    -- fitted; the full text is on the tooltip, which is where a card this
    -- narrow has to keep an explanation anyway.
    card.label = UI.Text(card, "small", "textMuted")
    card.label:SetPoint("TOPLEFT", 14, -10)
    card.label:SetPoint("RIGHT", card, "RIGHT", -22, 0)
    card.label:SetJustifyH("LEFT")
    card.labelFull = opts.label or ""

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

    --- Refits the caption to whatever width the card currently has. Cards live
    --- in a responsive grid, so the width is not known at build time.
    function card:RefitLabel()
        self.label:SetText(UI.FitText(self.label, self.labelFull or ""))
    end

    function card:SetLabel(text)
        self.labelFull = text or ""
        self:RefitLabel()
    end

    card:SetScript("OnSizeChanged", function(self) self:RefitLabel() end)
    card:RefitLabel()

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

    -- The value is pinned on the RIGHT only, so the width RefitLabel gives it
    -- is the width it gets. Anchoring its LEFT to the row's CENTER as well -
    -- which is what this did - hard-codes a 50/50 split that no SetWidth can
    -- override, in the real client as much as in the harness, and that is how
    -- 160 px came to be reserved for the string "0".
    row.value = UI.Text(row, "numeric", "textPrimary", "RIGHT")
    row.value:SetPoint("TOP")
    row.value:SetPoint("BOTTOM")
    row.value:SetPoint("RIGHT")

    row.label = UI.Text(row, "small", "textSecondary")
    row.label:SetPoint("LEFT")
    row.label:SetPoint("RIGHT", row.value, "LEFT", -6, 0)

    --- Splits the row between label and value, then fits both to their share.
    ---
    --- The split is computed from the ROW's width, not from the halves' own.
    --- A half anchored between two frames has a width only once that chain has
    --- been resolved, and layout code has to answer "how much room is there"
    --- before that. Giving each half an explicit width makes the answer
    --- available immediately, and keeps the anchors as the backstop.
    ---
    --- The split used to be a flat 45/55, which is how a row 321 px wide came
    --- to reserve 160 px for the string "0" while trimming "Collections
    --- observed" to fit in what was left. The value takes what it needs now
    --- and the label gets the rest.
    ---
    --- Quantised to a step so that 9 -> 10 -> 11 does not shove the label
    --- sideways on every refresh, and never below a floor, so a row whose
    --- value is briefly "-" does not collapse and then jump back.
    local VALUE_STEP, VALUE_FLOOR = 24, 48

    function row:RefitLabel()
        local width = self:GetWidth() or 0
        if width <= 40 then return end

        self.value:SetText(self.valueFull or "-")
        local needed = (self.value:GetStringWidth() or 0) + 6
        local share = math.ceil(math.max(VALUE_FLOOR, needed) / VALUE_STEP) * VALUE_STEP
        -- Never more than half the row: a very long value is trimmed rather
        -- than allowed to squeeze the label out, because the label is what
        -- says which number this is.
        share = math.min(share, width * 0.5)

        if width ~= self._fittedAt or share ~= self._valueShare then
            self._fittedAt, self._valueShare = width, share
            self.value:SetWidth(share)
            self.label:SetWidth(math.max(24, width - share - 6))
        end
        self.label:SetText(UI.FitText(self.label, self.labelFull or ""))
    end

    function row:Set(value, tone)
        value = value or "-"
        self.valueFull = value
        self:RefitLabel()
        self.value:SetText(UI.FitText(self.value, value))
        self.value:SetTextColor(Theme:Tone(tone or nil))
        if not tone then self.value:SetTextColor(T("textPrimary")) end
    end

    function row:SetLabel(text)
        self.labelFull = text or ""
        self:RefitLabel()
        -- RefitLabel is a no-op before the row has a width; set the text
        -- anyway so the row is never blank, and let the next Set fit it.
        if (self:GetWidth() or 0) <= 40 then self.label:SetText(self.labelFull) end
    end

    -- The real client fires this when anchors change the row's size; the
    -- harness only fires it on an explicit SetWidth. Either way the refit is
    -- driven from Set as well, so a row is never left unfitted.
    row:SetScript("OnSizeChanged", function(self) self:RefitLabel() end)

    row:SetLabel(label or "")
    return row
end
