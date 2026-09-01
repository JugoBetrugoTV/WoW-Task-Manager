--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Diagnostics.lua

    The automatic session read-out.  Findings come from Analysis/Diagnostics
    and are rendered here with the correlation strength attached to each one,
    so nothing reads as a verdict when it is only an association.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("diagnostics", {})

local findingScratch, correlationScratch = {}, {}

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Verdict header
    ------------------------------------------------------------------
    local header = UI.Panel(frame, {})
    header:SetHeight(84)
    header:SetPoint("TOPLEFT", pad, -pad)
    header:SetPoint("TOPRIGHT", -pad, -pad)
    self.header = header

    header.accent = header:CreateTexture(nil, "ARTWORK")
    header.accent:SetWidth(3)
    header.accent:SetPoint("TOPLEFT")
    header.accent:SetPoint("BOTTOMLEFT")

    header.verdict = UI.Text(header, "display", "textPrimary")
    header.verdict:SetPoint("TOPLEFT", 18, -12)

    header.score = UI.Text(header, "small", "textMuted")
    header.score:SetPoint("BOTTOMLEFT", header.verdict, "BOTTOMRIGHT", 10, 6)

    header.summary = UI.Text(header, "small", "textSecondary")
    header.summary:SetPoint("TOPLEFT", header.verdict, "BOTTOMLEFT", 2, -4)
    header.summary:SetPoint("RIGHT", header, "RIGHT", -200, 0)
    header.summary:SetJustifyH("LEFT")

    self.reportButton = UI.Button(header, "Print report to chat", function()
        WTM.Diagnostics:PrintReport()
        WTM:Print("Report printed above. Copy it from your chat log.")
    end, { height = 24 })
    self.reportButton:SetPoint("TOPRIGHT", -16, -14)

    self.resetButton = UI.Button(header, "Reset counters", function()
        WTM.Database:ResetRuntime()
        Page:Refresh()
    end, { height = 24 })
    self.resetButton:SetPoint("TOPRIGHT", self.reportButton, "BOTTOMRIGHT", 0, -6)

    ------------------------------------------------------------------
    -- Findings list (left) and correlation table (right)
    ------------------------------------------------------------------
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -M.cardGap)
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad)
    self.body = body

    self.findingsCard = UI.Card(body, "FINDINGS", {})
    self.findingsCard:SetPoint("TOPLEFT")
    self.findingsCard:SetPoint("BOTTOMLEFT")

    self.findingsList = UI.ScrollList(self.findingsCard.content, 58,
        function(parent)
            local row = CreateFrame("Button", nil, parent)
            row.accent = row:CreateTexture(nil, "ARTWORK")
            row.accent:SetWidth(2)
            row.accent:SetPoint("TOPLEFT", 0, -4)
            row.accent:SetPoint("BOTTOMLEFT", 0, 4)

            row.title = UI.Text(row, "body", "textPrimary")
            row.title:SetPoint("TOPLEFT", 12, -6)
            row.title:SetPoint("RIGHT", row, "RIGHT", -8, 0)
            row.title:SetJustifyH("LEFT")

            row.detail = UI.Text(row, "small", "textSecondary")
            row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)
            row.detail:SetPoint("RIGHT", row, "RIGHT", -8, 0)
            row.detail:SetJustifyH("LEFT")
            row.detail:SetJustifyV("TOP")
            row.detail:SetHeight(32)
            return row
        end,
        function(row, finding)
            row.accent:SetColorTexture(Theme:Tone(finding.tone))
            row.title:SetText(finding.title)
            row.title:SetTextColor(Theme:Tone(finding.tone == "muted" and "muted" or "textPrimary"))
            if finding.tone == "muted" then
                row.title:SetTextColor(T("textSecondary"))
            end
            row.detail:SetText(finding.detail or "")
        end,
        function(finding)
            if finding.evidence and finding.evidence.addon then
                local record = WTM.Processes:Get(finding.evidence.addon)
                if record then UI.AddonDetail:Open(record) end
            elseif finding.evidence and finding.evidence.action == "enableProfiling" then
                WTM.Caps:ToggleCPUProfiling()
                Page:Refresh()
            end
        end)
    self.findingsList:SetAllPoints(self.findingsCard.content)

    ------------------------------------------------------------------
    -- Correlation panel
    ------------------------------------------------------------------
    self.correlationCard = UI.Card(body, "SPIKE CORRELATION", {})
    self.correlationCard:SetWidth(380)
    self.correlationCard:SetPoint("TOPRIGHT")
    self.correlationCard:SetPoint("BOTTOMRIGHT")
    self.findingsCard:SetPoint("RIGHT", self.correlationCard, "LEFT", -M.cardGap, 0)

    self.correlationRows = {}
    for i = 1, 8 do
        local row = CreateFrame("Button", nil, self.correlationCard.content)
        row:SetHeight(34)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * 36)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * 36)

        row.name = UI.Text(row, "body", "textPrimary")
        row.name:SetPoint("TOPLEFT")

        row.label = UI.Text(row, "small", "textSecondary", "RIGHT")
        row.label:SetPoint("TOPRIGHT")

        row.bar = UI.MiniBar(row, 3)
        row.bar:SetPoint("BOTTOMLEFT", 0, 8)
        row.bar:SetPoint("BOTTOMRIGHT", 46, 8)

        row.pct = UI.Text(row, "numericSm", "textSecondary", "RIGHT")
        row.pct:SetPoint("BOTTOMRIGHT", 0, 5)

        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            UI.TooltipClear(self.entry.title)
            UI.TooltipLine("Strength", self.entry.label, nil, self.entry.tone)
            UI.TooltipLine("Phi coefficient", ("%.3f"):format(self.entry.phi))
            UI.TooltipLine("Elevated during", ("%d of %d spikes"):format(self.entry.hits, self.entry.spikes))
            UI.TooltipLine("Average excess CPU", ("%+.2f %%"):format(self.entry.avgExcess))
            UI.TooltipLine("Peak excess CPU", ("%+.2f %%"):format(self.entry.peakExcess))
            UI.TooltipLine("", "")
            UI.TooltipLine(self.entry.explanation, nil, "muted")
            UI.TooltipLine("A correlation is not a cause. Several addons react to the same events, and a spike can come from outside Lua entirely.", nil, "muted")
            UI.TooltipShow(self)
        end)
        row:SetScript("OnLeave", UI.HideTooltip)
        row:SetScript("OnClick", function(self)
            if not self.entry then return end
            local record = WTM.Processes:Get(self.entry.name)
            if record then UI.AddonDetail:Open(record) end
        end)
        self.correlationRows[i] = row
    end

    self.correlationNote = UI.Text(self.correlationCard.content, "tiny", "textMuted")
    self.correlationNote:SetPoint("BOTTOMLEFT")
    self.correlationNote:SetPoint("BOTTOMRIGHT")
    self.correlationNote:SetJustifyH("LEFT")
    self.correlationNote:SetWordWrap(true)
end

function Page:OnShow() self:Refresh() end

--------------------------------------------------------------------------

function Page:Refresh()
    if not self.header then return end

    local health, score, info = WTM.Diagnostics:ComputeHealth()
    self.header.accent:SetColorTexture(Theme:Tone(health.tone))
    self.header.verdict:SetText(health.text)
    self.header.verdict:SetTextColor(Theme:Tone(health.tone))
    self.header.score:SetText(("%d / 100"):format(score))
    self.header.summary:SetText(
        ("%s of session   -   avg %s FPS, 1%% low %s FPS   -   %d spikes (%.1f per minute)   -   CPU profiling %s")
        :format(Fmt.Duration(info.duration), Fmt.FPS(info.avgFPS), Fmt.FPS(info.low1),
                WTM.SpikeDetector.total, info.spikesPerMinute,
                WTM.CPU.available and "on" or "off"))

    WTM.Diagnostics:Build(findingScratch)
    self.findingsList:SetData(findingScratch)

    ------------------------------------------------------------------
    -- Correlation
    ------------------------------------------------------------------
    local correlations, samples, unavailable = WTM.Correlation:Analyze(correlationScratch)

    for i, row in ipairs(self.correlationRows) do
        local entry = correlations[i]
        row:SetShown(entry ~= nil)
        row.entry = entry
        if entry then
            row.name:SetText(Fmt.Truncate(entry.title, 24))
            row.label:SetText(entry.label)
            row.label:SetTextColor(Theme:Tone(entry.tone))
            row.bar:SetValue(entry.phi, entry.tone)
            row.pct:SetText(("%.0f %%"):format(entry.percent))
        end
    end

    if unavailable then
        self.correlationNote:SetText(unavailable ..
            "\n\nWithout per-addon CPU time there is nothing to correlate a spike against.")
    elseif samples < C.CORRELATION_MIN_SAMPLES then
        self.correlationNote:SetText(
            ("%d spike%s recorded. At least %d are needed before an association means anything; below that, coincidence dominates.")
            :format(samples, samples == 1 and "" or "s", C.CORRELATION_MIN_SAMPLES))
    elseif #correlations == 0 then
        self.correlationNote:SetText(
            "No addon was consistently above its own average when spikes occurred. That is a real result: it points at work outside addon Lua - the engine, asset streaming or the server.")
    else
        self.correlationNote:SetText(
            ("Measured across %d spike windows. Phi is an association between \"this addon was busier than usual\" and \"a spike happened\", never a demonstrated cause.")
            :format(samples))
    end
end
