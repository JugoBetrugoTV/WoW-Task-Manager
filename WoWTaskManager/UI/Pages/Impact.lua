--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Impact.lua

    Rankings, and one combined score with its inputs on display.

    A single number that orders addons by "impact" is the most dangerous thing
    in this addon, because it is the one a reader is most likely to treat as a
    verdict. Three things keep it honest:

      * The formula is printed on the page, not buried in a tooltip.
      * Every component is shown next to the total, so a reader can see which
        one is driving a ranking rather than trusting the sum.
      * The score is relative to the addons you have installed. It normalises
        against the largest value in your own list, so it cannot be compared
        with anyone else's, and the page says so.

    A high score means "this one accounts for a large share of what was
    measured". It does not mean the addon is doing anything wrong, and it is
    never a recommendation to disable anything.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("impact", {})

local impactScratch = {}

local COLUMNS = {
    { key = "rank", title = "#", width = 34, justify = "RIGHT",
      value = function(row) return tostring(row.rank) end,
      tone = function() return "muted" end },
    { key = "name", title = "Addon", flex = 3,
      value = function(row) return Fmt.Truncate(row.title, 34) end },
    { key = "score", title = "Impact", width = 92, justify = "RIGHT",
      value = function(row) return ("%.1f"):format(row.score) end,
      bar = function(row) return row.score / 100, "accent" end },
    { key = "cpu", title = "CPU", width = 78, justify = "RIGHT",
      value = function(row)
          if not WTM.CPU.available then return "-" end
          return ("%.2f %%"):format(row.cpuPct)
      end },
    { key = "memory", title = "Memory", width = 86, justify = "RIGHT",
      value = function(row) return Fmt.Memory(row.memKB) end },
    { key = "growth", title = "Growth/min", width = 92, justify = "RIGHT",
      value = function(row) return Fmt.Memory(row.growthKB) end,
      tone = function(row)
          return row.growthKB >= C.MEM_GROWTH_KB_PER_MIN and "warn" or "muted"
      end },
    { key = "events", title = "Events", width = 70, justify = "RIGHT",
      value = function(row) return tostring(row.events) end,
      tone = function() return "muted" end },
    { key = "phi", title = "Spike assoc.", width = 100, justify = "RIGHT",
      -- phi, never a percentage: it is a coefficient of association, and
      -- rendering it with a % sign would invite exactly the misreading this
      -- addon exists to avoid.
      value = function(row) return row.phi and ("phi %.2f"):format(row.phi) or "-" end,
      tone = function(row) return row.phi and row.phi >= 0.5 and "warn" or "muted" end },
}

function Page:Build(frame)
    local pad = M.padding

    ------------------------------------------------------------------
    -- Ranking selector
    ------------------------------------------------------------------
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(26)
    toolbar:SetPoint("TOPLEFT", pad, -pad)
    toolbar:SetPoint("TOPRIGHT", -pad, -pad)
    self.toolbar = toolbar

    local label = UI.Text(toolbar, "small", "textMuted", "LEFT")
    label:SetPoint("LEFT")
    label:SetWidth(58)
    label:SetText("RANK BY")

    self.ranking = "score"
    self.rankButtons = {}
    local previous
    for _, spec in ipairs(WTM.Impact.RANKINGS) do
        local button = UI.Button(toolbar, spec.label, function()
            self.ranking = spec.key
            for key, b in pairs(self.rankButtons) do b:SetSelected(key == spec.key) end
            self:Refresh()
        end, { height = 22, style = "small" })
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("LEFT", label, "RIGHT", 6, 0)
        end
        button.tooltip = spec.help
        self.rankButtons[spec.key] = button
        previous = button
    end
    self.rankButtons.score:SetSelected(true)

    self.availabilityNote = UI.Text(toolbar, "tiny", "textMuted", "RIGHT")
    self.availabilityNote:SetPoint("RIGHT")
    self.availabilityNote:SetPoint("LEFT", previous, "RIGHT", 12, 0)

    ------------------------------------------------------------------
    -- Table
    ------------------------------------------------------------------
    self.table = UI.Table(frame, COLUMNS, {
        onRowClick = function(row)
            if row and row.record then UI.AddonDetail:Open(row.record) end
        end,
    })
    self.table:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    self.table:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -pad, pad + 96)

    ------------------------------------------------------------------
    -- The formula, in plain sight
    ------------------------------------------------------------------
    self.formula = UI.Card(frame, "HOW THE IMPACT SCORE IS BUILT", {})
    self.formula:SetPoint("BOTTOMLEFT", pad, pad)
    self.formula:SetPoint("BOTTOMRIGHT", -pad, pad)
    self.formula:SetHeight(88)

    self.formula.body = UI.Text(self.formula.content, "small", "textMuted", "LEFT")
    self.formula.body:SetPoint("TOPLEFT")
    self.formula.body:SetPoint("BOTTOMRIGHT")
    UI.Wrap(self.formula.body, 0)
    self.formula.body:SetJustifyV("TOP")
    self.formula.body:SetText(WTM.Impact.EXPLANATION)

    self:OnLayout()
end

function Page:OnLayout()
    if self.table then self.table:UpdateHeader() end
end

function Page:OnShow() self:Refresh() end

function Page:Refresh()
    if not self.table then return end

    local list, availability = WTM.Impact:Compute(impactScratch)
    WTM.Impact:Sort(list, self.ranking)
    for i, entry in ipairs(list) do entry.rank = i end

    self.table:SetData(list)

    -- Which components actually contributed, so a ranking is never presented
    -- as complete when half its inputs were unmeasurable.
    local missing = {}
    if not availability.cpu then missing[#missing + 1] = "CPU" end
    if not availability.memory then missing[#missing + 1] = "memory" end
    if not availability.spikes then missing[#missing + 1] = "spike association" end

    if #missing > 0 then
        self.availabilityNote:SetText(UI.FitText(self.availabilityNote,
            ("scored without %s"):format(table.concat(missing, ", "))))
        self.availabilityNote:SetTextColor(Theme:Tone("warn"))
    else
        self.availabilityNote:SetText(UI.FitText(self.availabilityNote,
            ("%d addons scored"):format(#list)))
        self.availabilityNote:SetTextColor(T("textMuted"))
    end

    local suffix = ""
    if availability.spikeReason then
        suffix = ("\n\nSpike association is not contributing yet: %s.")
            :format(availability.spikeReason)
    end
    if not availability.cpu then
        suffix = suffix .. "\n\nCPU is not contributing: " ..
            (WTM.CPU.reason or C.TXT_REQUIRES_PROFILING)
    end
    self.formula.body:SetText(WTM.Impact.EXPLANATION .. suffix)
end
