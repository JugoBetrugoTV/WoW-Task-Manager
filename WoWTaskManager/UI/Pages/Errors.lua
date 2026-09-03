--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Pages/Errors.lua

    Lua errors, grouped by what they actually are rather than by how often they
    fired.

    The list shows one row per distinct error with an occurrence count, which is
    the difference between "500 errors" and "one bug, 500 times". The second is
    actionable; the first is a wall.

    Two wordings are load-bearing here:

      * An addon is only named when the error message carried an
        Interface/AddOns path. Everything else is "Unknown", not the nearest
        plausible guess.
      * An error and a stutter that overlap in time are reported as
        overlapping. Nothing on this page says one produced the other.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C     = WTM.C
local UI    = WTM.UI
local Theme = UI.Theme
local T     = Theme.Get
local M     = Theme.metrics
local Fmt   = WTM.Format

local Page = UI.RegisterPage("errors", {})

local viewData = {}

--------------------------------------------------------------------------

local function severityOf(group)
    if group.internal then return "crit", "internal" end
    if group.count >= (WTM.db.profile.errors.repeatThreshold or 25) then
        return "crit", "repeating"
    end
    if group.count > 1 then return "warn", "repeated" end
    return "muted", "once"
end

local COLUMNS = {
    { key = "time", title = "Last seen", width = 92, sort = "time",
      value = function(group)
          return Fmt.Clock(group.lastAt, WTM.state.sessionEpoch, WTM.state.sessionStart)
      end,
      tone = function() return "muted" end },
    { key = "addon", title = "Addon", width = 130, sort = "addon",
      value = function(group)
          if group.internal then return C.ADDON_TITLE end
          return group.addon or "Unknown"
      end,
      tone = function(group)
          if group.internal then return "crit" end
          return group.addon and nil or "muted"
      end,
      tooltip = "Parsed from the Interface/AddOns path in the message. Errors from the default UI, from string chunks, or with no path show as Unknown - this addon does not guess." },
    { key = "message", title = "Error", flex = 3, sort = "message",
      value = function(group)
          local text = (group.message or ""):gsub("\n", " ")
          -- The path prefix is in its own column; showing it twice costs the
          -- half of the row that carries the actual message.
          text = text:gsub("^.-%.lua:%d+:%s*", "")
          return text
      end,
      tone = function(group)
          return WTM.Errors:IsIgnored(group) and "muted" or nil
      end },
    { key = "count", title = "Count", width = 62, justify = "RIGHT", sort = "count",
      value = function(group) return tostring(group.count or 1) end,
      tone = function(group) return (group.count or 1) > 1 and "warn" or "muted" end,
      tooltip = "How many times this exact error fired. Identical errors are folded into one row rather than stored one by one - a storm of one bug is one bug." },
    { key = "first", title = "First seen", width = 92, sort = "first",
      value = function(group)
          return Fmt.Clock(group.firstAt, WTM.state.sessionEpoch, WTM.state.sessionStart)
      end,
      tone = function() return "muted" end },
    { key = "severity", title = "Severity", width = 84, sort = "severity",
      value = function(group) return (select(2, severityOf(group))) end,
      tone = function(group) return (severityOf(group)) end },
    { key = "context", title = "Context", width = 120,
      value = function(group)
          local ctx = group.context
          if not ctx then return "" end
          local parts = {}
          if ctx.combat then parts[#parts + 1] = "combat" end
          if ctx.instanceType and ctx.instanceType ~= "none" then
              parts[#parts + 1] = ctx.instanceType
          end
          if ctx.frameMs and ctx.frameMs > 33 then
              parts[#parts + 1] = ("%.0f ms"):format(ctx.frameMs)
          end
          return table.concat(parts, ", ")
      end,
      tone = function() return "muted" end,
      tooltip = "What was happening when the error was first seen: combat state, instance type, and the frame time at that moment if it was already high." },
}

--------------------------------------------------------------------------

--- Entry point from the Processes page: show only this addon's errors.
---
--- It fills the search box rather than adding a hidden filter, so the state is
--- visible and the user can clear it the same way they set any other.
function Page:FilterByAddon(name)
    if not self.search then return end
    self.search:SetText(name or "")
    self.filter = name or ""
    self:Rebuild()
end

function Page:Build(frame)
    local pad = M.padding
    self.filters = {}

    ------------------------------------------------------------------
    -- Toolbar
    ------------------------------------------------------------------
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(28)
    toolbar:SetPoint("TOPLEFT", pad, -pad)
    toolbar:SetPoint("TOPRIGHT", -pad, -pad)
    self.toolbar = toolbar

    self.search = UI.SearchBox(toolbar, "Search message, addon or file", function(text)
        self.filter = text
        self:Rebuild()
    end)
    self.search:SetPoint("LEFT")
    self.search:SetWidth(240)

    local FILTERS = {
        { key = "repeating", label = "Repeating",
          tip = "Only errors that fired more than once." },
        { key = "combat",    label = "In combat",
          tip = "Only errors first seen while in combat." },
        { key = "overlap",   label = "Near a stutter",
          tip = "Only errors whose window overlaps a recorded stutter incident. Overlap in time - nothing causal is claimed by it." },
        { key = "ignored",   label = "Show ignored",
          tip = "Ignored errors are hidden by default but always counted, because a storm you chose not to look at still costs frame time." },
        { key = "internal",  label = "This addon",
          tip = "Only errors raised by WoW Task Manager itself. They are never hidden - an addon that swallows its own faults is worse than one that has them." },
    }

    local previous = self.search
    self.filterButtons = {}
    for _, filter in ipairs(FILTERS) do
        local button = UI.Button(toolbar, filter.label, function(button)
            local on = not button.active
            button.active = on
            button:SetSelected(on)
            self.filters[filter.key] = on or nil
            self:Rebuild()
        end, { height = 24, style = "small" })
        button:SetPoint("LEFT", previous, "RIGHT", filter.key == "repeating" and 10 or 4, 0)
        button.tooltip = filter.tip
        self.filterButtons[filter.key] = button
        previous = button
    end

    self.copyAll = UI.Button(toolbar, "Copy all", function()
        UI.ShowCopyBox(WTM.Reports:AllErrors(), "All errors this session")
    end, { height = 24, style = "small" })
    self.copyAll:SetPoint("LEFT", previous, "RIGHT", 10, 0)
    self.copyAll.tooltip = "Opens every recorded error as selectable text. WoW gives addons no clipboard access, so selecting and pressing Ctrl-C is as far as this can go."

    self.summary = UI.Text(toolbar, "small", "textMuted", "RIGHT")
    self.summary:SetPoint("RIGHT")
    self.summary:SetPoint("LEFT", self.copyAll, "RIGHT", 12, 0)

    ------------------------------------------------------------------
    -- Summary cards
    ------------------------------------------------------------------
    local cardRow = CreateFrame("Frame", nil, frame)
    cardRow:SetHeight(78)
    cardRow:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -10)
    cardRow:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -10)
    self.cardRow = cardRow

    self.cards = {}
    local SPECS = {
        { key = "total",    label = "TOTAL ERRORS" },
        { key = "unique",   label = "UNIQUE ERRORS" },
        { key = "minute",   label = "LAST MINUTE" },
        { key = "rate",     label = "ERROR RATE" },
        { key = "last",     label = "LAST ERROR" },
        { key = "frequent", label = "MOST FREQUENT" },
        { key = "worst",    label = "WORST ADDON" },
        { key = "folded",   label = "DUPLICATES FOLDED" },
    }
    for _, spec in ipairs(SPECS) do
        local card = UI.MetricCard(cardRow, {
            label = spec.label, height = 78, sparkHeight = 0,
        })
        card.spark:Hide()
        self.cards[spec.key] = card
    end
    self.cardSpecs = SPECS

    ------------------------------------------------------------------
    -- Handler status
    ------------------------------------------------------------------
    self.chainNotice = UI.NoticePanel(frame, "Error capture", "", nil, nil, "warn")
    self.chainNotice:SetPoint("TOPLEFT", cardRow, "BOTTOMLEFT", 0, -M.cardGap)
    self.chainNotice:SetPoint("TOPRIGHT", cardRow, "BOTTOMRIGHT", 0, -M.cardGap)
    self.chainNotice:Hide()

    ------------------------------------------------------------------
    -- Table
    ------------------------------------------------------------------
    self.sortKey, self.sortAscending = "time", false
    self.table = UI.Table(frame, COLUMNS, {
        defaultSort = "time",
        emptyMessage = "No Lua errors recorded this session.",
        onSort = function(key, ascending)
            self.sortKey, self.sortAscending = key, ascending
            self:Rebuild()
        end,
        onRowClick = function(group, button, row)
            if button == "RightButton" then
                Page:ShowRowMenu(row, group)
            else
                UI.ErrorDetail:Open(group)
            end
        end,
    })
    self:PositionTable()
end

function Page:PositionTable()
    local pad = M.padding
    local anchor = self.chainNotice:IsShown() and self.chainNotice or self.cardRow
    self.table:ClearAllPoints()
    self.table:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -M.cardGap)
    self.table:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -pad, pad)
    self.table.LayoutHeader()
end

function Page:OnLayout()
    if not self.cardRow then return end
    local width = self.cardRow:GetWidth() or 0
    if width <= 0 then return end
    local count = #self.cardSpecs
    local cardWidth = (width - M.cardGap * (count - 1)) / count
    local previous
    for _, spec in ipairs(self.cardSpecs) do
        local card = self.cards[spec.key]
        card:ClearAllPoints()
        card:SetPoint("TOP")
        card:SetPoint("BOTTOM")
        card:SetWidth(cardWidth)
        if previous then card:SetPoint("LEFT", previous, "RIGHT", M.cardGap, 0)
        else card:SetPoint("LEFT") end
        previous = card
    end
    self:PositionTable()
end

function Page:OnShow()
    self:OnLayout()
    self:Rebuild()
end

--------------------------------------------------------------------------

--- The right-click menu. Ignoring is a display choice, and the menu says so.
function Page:ShowRowMenu(row, group)
    if not group then return end
    local ignored = WTM.Errors:IsIgnored(group)

    UI.ShowContextMenu(row, {
        { label = "Open details",
          onClick = function() UI.ErrorDetail:Open(group) end },
        { label = "Copy this error",
          tooltip = "Opens the full report as selectable text.",
          onClick = function()
              UI.ShowCopyBox(WTM.Reports:Error(group), "Error report")
          end },
        { label = ignored and "Stop ignoring" or "Ignore this error",
          tooltip = "Hides it from this list. It keeps being counted - a storm you chose not to look at still costs frame time.",
          onClick = function()
              WTM.Errors:SetIgnored(group, not ignored)
              Page:Rebuild()
          end },
        { label = "Ignore until reload",
          tooltip = "Hides it for this session only; nothing is written to the database.",
          onClick = function()
              WTM.Errors:IgnoreForSession(group)
              Page:Rebuild()
          end },
        { label = group.addon and ("Ignore all from " .. group.addon) or "Ignore this addon",
          disabled = group.addon == nil,
          reason = "This error carries no addon path, so there is nothing to ignore by addon.",
          onClick = function()
              WTM.Errors:SetAddonIgnored(group.addon, true)
              Page:Rebuild()
          end },
        { label = "Show the addon",
          disabled = group.addon == nil or WTM.Processes:Get(group.addon) == nil,
          reason = "The addon this came from is not in the installed list.",
          onClick = function()
              local record = WTM.Processes:Get(group.addon)
              if record then UI.AddonDetail:Open(record) end
          end },
    }, group.addon or "Unknown")
end

--------------------------------------------------------------------------

local SORTERS = {
    time     = function(a, b) return a.lastAt > b.lastAt end,
    first    = function(a, b) return a.firstAt > b.firstAt end,
    count    = function(a, b) return (a.count or 0) > (b.count or 0) end,
    addon    = function(a, b) return (a.addon or "~") < (b.addon or "~") end,
    message  = function(a, b) return (a.message or "") < (b.message or "") end,
    severity = function(a, b)
        local rank = { crit = 3, warn = 2, muted = 1 }
        return (rank[(severityOf(a))] or 0) > (rank[(severityOf(b))] or 0)
    end,
}

function Page:Rebuild()
    if not self.table then return end

    for i = #viewData, 1, -1 do viewData[i] = nil end
    local needle = self.filter and self.filter ~= "" and self.filter:lower() or nil

    for _, group in ipairs(WTM.Errors.groups) do
        local include = true

        if not self.filters.ignored and WTM.Errors:IsIgnored(group) then
            include = false
        end
        if include and needle then
            include = (group.message or ""):lower():find(needle, 1, true) ~= nil
                or (group.addon or ""):lower():find(needle, 1, true) ~= nil
                or (group.file or ""):lower():find(needle, 1, true) ~= nil
        end
        if include and self.filters.repeating then include = (group.count or 1) > 1 end
        if include and self.filters.combat then
            include = group.context and group.context.combat or false
        end
        if include and self.filters.internal then include = group.internal end
        if include and self.filters.overlap then
            include = WTM.Errors:OverlapsSpikes(group) > 0
        end

        if include then viewData[#viewData + 1] = group end
    end

    local sorter = SORTERS[self.sortKey] or SORTERS.time
    if self.sortAscending then
        table.sort(viewData, function(a, b) return sorter(b, a) end)
    else
        table.sort(viewData, sorter)
    end

    self.table:SetData(viewData)
    self.table:SetEmpty(#viewData == 0)
    self:Refresh()
end

function Page:Refresh()
    if not self.table then return end

    local stats = WTM.Errors.stats
    local cards = self.cards

    cards.total:SetValue(Fmt.Comma(stats.total), "",
        stats.total > 0 and "warn" or "ok")
    cards.total:SetSub(stats.droppedByCap > 0
        and ("%d not recorded, cap reached"):format(stats.droppedByCap)
        or "every occurrence, duplicates included")

    cards.unique:SetValue(tostring(stats.unique), "")
    cards.unique:SetSub("distinct errors")

    local lastMinute = WTM.Errors:CountSince(60)
    cards.minute:SetValue(tostring(lastMinute), "",
        lastMinute > 0 and "warn" or nil)
    cards.minute:SetSub("in the last 60 seconds")

    cards.rate:SetValue(("%.1f"):format(WTM.Errors:RatePerMinute()), "/min")
    cards.rate:SetSub(#WTM.Errors.storms > 0
        and ("%d error storm%s"):format(#WTM.Errors.storms,
            #WTM.Errors.storms == 1 and "" or "s")
        or "no storm detected")

    local last = stats.lastGroup
    if last then
        cards.last:SetValue(Fmt.Clock(stats.lastAt,
            WTM.state.sessionEpoch, WTM.state.sessionStart), "")
        cards.last:SetSub(last.addon or "Unknown")
    else
        cards.last:SetValue("none", "")
        cards.last:SetSub("no error yet this session")
    end

    local frequent = WTM.Errors:MostFrequent()
    if frequent then
        cards.frequent:SetValue(tostring(frequent.count), "x")
        cards.frequent:SetSub(frequent.addon or "Unknown")
    else
        cards.frequent:SetValue("-", "")
        cards.frequent:SetSub("nothing repeated")
    end

    local worst, worstCount = WTM.Errors:WorstAddon()
    if worst then
        cards.worst:SetValue(Fmt.Truncate(worst, 12), "")
        cards.worst:SetSub(("%d error%s"):format(worstCount,
            worstCount == 1 and "" or "s"))
    else
        cards.worst:SetValue("none", "")
        cards.worst:SetSub("no errors attributed")
    end

    cards.folded:SetValue(Fmt.Comma(stats.suppressed), "")
    cards.folded:SetSub("duplicates folded into their group")

    for _, card in pairs(cards) do card:Refresh() end

    ------------------------------------------------------------------
    -- Handler status, shown only when there is something to say.
    local text, tone = WTM.Errors:DescribeChain()
    local show = tone ~= "ok"
    if show ~= self.chainNotice:IsShown() then
        self.chainNotice:SetShown(show)
        self:PositionTable()
    end
    if show then
        self.chainNotice:SetMessage(text)
    end

    -- The short form here, not the paragraph: this label is a right-aligned
    -- strip at the end of the toolbar, and the paragraph belongs in the notice
    -- panel above the table, which is where it already is.
    self.summary:SetText(UI.FitText(self.summary,
        ("%d shown of %d distinct  -  handler %s")
            :format(#viewData, stats.unique, (WTM.Errors:ShortChainState()))))

    self.table:Refresh()
end
