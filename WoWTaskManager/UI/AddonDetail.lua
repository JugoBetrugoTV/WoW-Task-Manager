--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/AddonDetail.lua

    The per-addon diagnostic overlay, opened by clicking a row in the process
    list.  Tabs: Overview, Performance, Memory, Events, Dependencies, History,
    Diagnostics.

    The Control section is where the addon is most careful about what it does
    NOT offer.  There is no "unload" and no "terminate" button, because WoW has
    no API for either - the Lua state cannot be partially torn down and Lua in
    WoW has no preemption.  Enable and disable exist, take effect on the next
    reload, and say so.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local UI     = WTM.UI
local Theme  = UI.Theme
local T      = Theme.Get
local M      = Theme.metrics
local Fmt    = WTM.Format
local Compat = WTM.Compat

local Detail = {}
UI.AddonDetail = Detail

-- Eight tabs, and none of them may be blank. Where a measurement is not
-- available on this client, or needs the scriptProfile CVar, the panel says
-- "Unavailable" and gives the reason - an empty panel reads as a bug, an
-- explained one reads as a limitation, and the second is the truth.
local TABS = {
    { key = "overview",     label = "Overview" },
    { key = "cpu",          label = "CPU" },
    { key = "memory",       label = "Memory" },
    { key = "history",      label = "History" },
    { key = "events",       label = "Events" },
    { key = "dependencies", label = "Dependencies" },
    { key = "errors",       label = "Errors" },
    { key = "diagnostics",  label = "Diagnostics" },
    { key = "metadata",     label = "Metadata" },
}

--------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------

function Detail:Build()
    if self.frame then return self.frame end

    local parent = UI.MainWindow.frame or UIParent

    -- Dim the window behind so focus is unambiguous.
    local scrim = CreateFrame("Button", nil, parent)
    scrim:SetAllPoints(parent)
    scrim:SetFrameStrata("DIALOG")
    local scrimTex = scrim:CreateTexture(nil, "BACKGROUND")
    scrimTex:SetAllPoints()
    scrimTex:SetColorTexture(0, 0, 0, 0.55)
    scrim:SetScript("OnClick", function() Detail:Close() end)
    scrim:Hide()
    self.scrim = scrim

    local frame = UI.Panel(scrim, { color = "windowBg", borderColor = "borderStrong" })
    frame:SetPoint("CENTER")
    frame:SetSize(780, 520)
    frame:EnableMouse(true)
    self.frame = frame

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------
    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(64)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    UI.Fill(header, "panelBg")
    UI.Border(header, "B", "borderSubtle")
    self.header = header

    header.accent = header:CreateTexture(nil, "ARTWORK")
    header.accent:SetWidth(3)
    header.accent:SetPoint("TOPLEFT")
    header.accent:SetPoint("BOTTOMLEFT")

    header.title = UI.Text(header, "title", "textPrimary")
    header.title:SetPoint("TOPLEFT", 18, -12)

    header.sub = UI.Text(header, "small", "textSecondary")
    header.sub:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -4)

    header.status = UI.Badge(header, "", "muted")
    header.status:SetPoint("LEFT", header.title, "RIGHT", 12, 0)

    local close = UI.Button(header, "X", function() Detail:Close() end,
        { width = 26, height = 22, style = "small" })
    close:SetPoint("TOPRIGHT", -10, -10)

    header.score = UI.Text(header, "metric", "textPrimary", "RIGHT")
    header.score:SetPoint("BOTTOMRIGHT", -16, 10)
    header.scoreLabel = UI.Text(header, "tiny", "textMuted", "RIGHT")
    header.scoreLabel:SetPoint("BOTTOMRIGHT", header.score, "BOTTOMLEFT", -6, 3)
    header.scoreLabel:SetText("SCORE")

    UI.MakeMovable(frame, header)

    ------------------------------------------------------------------
    -- Tabs
    ------------------------------------------------------------------
    self.tabStrip = UI.TabStrip(frame, TABS, function(key) Detail:ShowTab(key) end)
    self.tabStrip:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 12, 0)
    self.tabStrip:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -12, 0)

    ------------------------------------------------------------------
    -- Body
    ------------------------------------------------------------------
    local body = CreateFrame("Frame", nil, frame)
    body:SetPoint("TOPLEFT", self.tabStrip, "BOTTOMLEFT", 0, -M.paddingSmall)
    body:SetPoint("BOTTOMRIGHT", -M.padding, 52)
    self.body = body

    self.panels = {}
    for _, tab in ipairs(TABS) do
        local panel = CreateFrame("Frame", nil, body)
        panel:SetAllPoints(body)
        panel:Hide()
        self.panels[tab.key] = panel
    end

    self:BuildOverview(self.panels.overview)
    self:BuildPerformance(self.panels.cpu)
    self:BuildMemory(self.panels.memory)
    self:BuildEvents(self.panels.events)
    self:BuildDependencies(self.panels.dependencies)
    self:BuildHistory(self.panels.history)
    self:BuildErrors(self.panels.errors)
    self:BuildDiagnostics(self.panels.diagnostics)
    self:BuildMetadata(self.panels.metadata)

    ------------------------------------------------------------------
    -- Control bar
    ------------------------------------------------------------------
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetHeight(44)
    bar:SetPoint("BOTTOMLEFT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    UI.Fill(bar, "panelBg")
    UI.Border(bar, "T", "borderSubtle")
    self.bar = bar

    self.toggleButton = UI.Button(bar, "Disable after reload", function()
        Detail:ToggleEnabled()
    end, { height = 24 })
    self.toggleButton:SetPoint("LEFT", 16, 0)

    self.reloadButton = UI.Button(bar, "Reload UI", function()
        WTM.Processes:ReloadUI()
    end, { height = 24, primary = true })
    self.reloadButton:SetPoint("LEFT", self.toggleButton, "RIGHT", 8, 0)

    self.loadButton = UI.Button(bar, "Load now", function()
        local ok, err = WTM.Processes:LoadNow(Detail.record.name)
        if not ok then WTM:Print("Could not load: " .. tostring(err)) end
        Detail:Refresh()
    end, { height = 24 })
    self.loadButton:SetPoint("LEFT", self.reloadButton, "RIGHT", 8, 0)

    self.watchButton = UI.Button(bar, "Flag for diagnostics", function(button)
        local name = Detail.record.name
        WTM.Database:SetWatched(name, not WTM.Database:IsWatched(name))
        button:SetSelected(WTM.Database:IsWatched(name))
    end, { height = 24 })
    self.watchButton:SetPoint("LEFT", self.loadButton, "RIGHT", 8, 0)

    self.hideButton = UI.Button(bar, "Hide from graphs", function(button)
        local name = Detail.record.name
        WTM.Database:SetHidden(name, not WTM.Database:IsHidden(name))
        button:SetSelected(WTM.Database:IsHidden(name))
    end, { height = 24 })
    self.hideButton:SetPoint("LEFT", self.watchButton, "RIGHT", 8, 0)

    self.clearButton = UI.Button(bar, "Clear its history", function()
        WTM.Database:WipeAddonHistory(Detail.record.name)
        local record = Detail.record
        record.spikes, record.lastSpikeAt = 0, nil
        record.cpuPeakPct, record.cpuSumPct, record.cpuSamples = 0, 0, 0
        if record.cpuRing then record.cpuRing:Reset() end
        if record.memRing then record.memRing:Reset() end
        Detail:Refresh()
    end, { height = 24 })
    self.clearButton:SetPoint("LEFT", self.hideButton, "RIGHT", 8, 0)

    self.controlNote = UI.Text(bar, "tiny", "textMuted", "RIGHT")
    self.controlNote:SetPoint("RIGHT", -16, 0)

    return frame
end

--------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------

local function StatColumn(parent, labels, columnIndex, columns)
    local rows = {}
    for i, label in ipairs(labels) do
        local row = UI.StatRow(parent, label)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * 18)
        rows[label] = row
        row.rowIndex = i
    end
    return rows
end

function Detail:BuildOverview(panel)
    self.overviewRows = StatColumn(panel, {
        "Folder name", "Version", "Author", "Loaded", "LoadOnDemand",
        "Enable state", "Security", "Load failure reason",
        "CPU now", "CPU average", "CPU peak",
        "Memory", "Memory at login", "Growth per minute",
        "Spikes involved in", "Last spike",
        "Named frames (heuristic)", "Registered events (heuristic)",
    })
    for label, row in pairs(self.overviewRows) do
        row:SetWidth(340)
    end

    panel.notes = UI.Text(panel, "small", "textMuted")
    panel.notes:SetPoint("TOPLEFT", 360, 0)
    panel.notes:SetPoint("BOTTOMRIGHT")
    panel.notes:SetJustifyH("LEFT")
    panel.notes:SetJustifyV("TOP")
    UI.Wrap(panel.notes)
    self.overviewNotes = panel.notes
end

function Detail:BuildPerformance(panel)
    self.cpuGraph = UI.Graph(panel, {
        title = "CPU USAGE (% of one core)",
        valueFormat = function(v) return ("%.2f"):format(v) end,
    })
    self.cpuGraph:SetPoint("TOPLEFT")
    self.cpuGraph:SetPoint("TOPRIGHT")
    self.cpuGraph:SetHeight(190)

    self.perfRows = StatColumn(panel, {
        "Peak CPU", "Average CPU", "Current CPU", "CPU samples",
        "Milliseconds since last sample", "Total CPU time this session",
    })
    for _, row in pairs(self.perfRows) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.cpuGraph, "BOTTOMLEFT", 0, -12 - (row.rowIndex - 1) * 18)
        row:SetWidth(340)
    end

    self.perfUnavailable = UI.NoticePanel(panel,
        "Addon CPU is unavailable", "", "Enable profiling", function()
            local ok, err = WTM.Caps:SetCPUProfiling(true)
            WTM:Print(ok and "CPU profiling will be ON after the next /reload."
                or ("Could not enable CPU profiling: " .. tostring(err)))
            Detail:Refresh()
        end, "warn")
    self.perfUnavailable:SetPoint("TOPLEFT")
    self.perfUnavailable:SetPoint("TOPRIGHT")
    self.perfUnavailable:Hide()

    self.perfNotice = UI.Text(panel, "small", "textMuted")
    self.perfNotice:SetPoint("TOPLEFT", self.cpuGraph, "BOTTOMLEFT", 360, -12)
    self.perfNotice:SetPoint("BOTTOMRIGHT")
    self.perfNotice:SetJustifyH("LEFT")
    self.perfNotice:SetJustifyV("TOP")
    UI.Wrap(self.perfNotice)
end

function Detail:BuildMemory(panel)
    self.memGraph = UI.Graph(panel, {
        title = "MEMORY",
        valueFormat = function(v) return Fmt.Memory(v) end,
    })
    self.memGraph:SetPoint("TOPLEFT")
    self.memGraph:SetPoint("TOPRIGHT")
    self.memGraph:SetHeight(190)

    self.memRows = StatColumn(panel, {
        "Current", "At login", "Peak", "Growth", "Growth per minute",
        "SavedVariables estimate",
    })
    for _, row in pairs(self.memRows) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.memGraph, "BOTTOMLEFT", 0, -12 - (row.rowIndex - 1) * 18)
        row:SetWidth(340)
    end

    self.savedVarButton = UI.Button(panel, "Estimate SavedVariables size", function()
        Detail:EstimateSavedVars()
    end, { height = 22 })
    self.savedVarButton:SetPoint("TOPLEFT", self.memGraph, "BOTTOMLEFT", 0, -12 - 6 * 18 - 6)
    self.savedVarButton.tooltip =
        "There is no file system access, so the only way to size an addon's saved data is to walk the global tables it declares in its TOC. That costs real time on a large database, so it is on demand only."

    self.memNotice = UI.Text(panel, "small", "textMuted")
    self.memNotice:SetPoint("TOPLEFT", self.memGraph, "BOTTOMLEFT", 360, -12)
    self.memNotice:SetPoint("BOTTOMRIGHT")
    self.memNotice:SetJustifyH("LEFT")
    self.memNotice:SetJustifyV("TOP")
    UI.Wrap(self.memNotice)
end

function Detail:BuildEvents(panel)
    panel.note = UI.Text(panel, "small", "textMuted")
    panel.note:SetPoint("TOPLEFT")
    panel.note:SetPoint("TOPRIGHT")
    panel.note:SetJustifyH("LEFT")
    UI.Wrap(panel.note)
    self.eventsNote = panel.note

    self.eventRows = {}
    for i = 1, 16 do
        local row = UI.StatRow(panel, "")
        row:SetPoint("TOPLEFT", 0, -46 - (i - 1) * 18)
        row:SetWidth(360)
        self.eventRows[i] = row
    end

    self.eventScanButton = UI.Button(panel, "Scan frames", function()
        WTM.Processes:ScanFrames(true)
        Detail:Refresh()
    end, { height = 22 })
    self.eventScanButton:SetPoint("TOPRIGHT")
end

function Detail:BuildDependencies(panel)
    self.depTitle = UI.Text(panel, "heading", "textSecondary")
    self.depTitle:SetPoint("TOPLEFT")
    self.depTitle:SetText("REQUIRES")

    self.depRows = {}
    for i = 1, 12 do
        local row = UI.StatRow(panel, "")
        row:SetPoint("TOPLEFT", 0, -22 - (i - 1) * 18)
        row:SetWidth(340)
        self.depRows[i] = row
    end

    self.dependentTitle = UI.Text(panel, "heading", "textSecondary")
    self.dependentTitle:SetPoint("TOPLEFT", 380, 0)
    self.dependentTitle:SetText("REQUIRED BY")

    self.dependentRows = {}
    for i = 1, 12 do
        local row = UI.StatRow(panel, "")
        row:SetPoint("TOPLEFT", 380, -22 - (i - 1) * 18)
        row:SetWidth(340)
        self.dependentRows[i] = row
    end
end

function Detail:BuildHistory(panel)
    panel.note = UI.Text(panel, "small", "textMuted")
    panel.note:SetPoint("TOPLEFT")
    panel.note:SetPoint("TOPRIGHT")
    panel.note:SetJustifyH("LEFT")
    UI.Wrap(panel.note)
    self.historyNote = panel.note

    self.historyRows = {}
    for i = 1, 14 do
        local row = UI.StatRow(panel, "")
        row:SetPoint("TOPLEFT", 0, -44 - (i - 1) * 18)
        row:SetPoint("TOPRIGHT", 0, -44 - (i - 1) * 18)
        self.historyRows[i] = row
    end
end

--- Everything the TOC and the addon API expose about this addon, with the
--- fields it did NOT declare listed as "not declared" rather than omitted -
--- a missing Version is itself worth seeing.
function Detail:BuildMetadata(panel)
    self.metadataRows = {}
    local FIELDS = {
        "Folder name", "Title", "Version", "Author", "Notes",
        "Interface", "X-Category", "X-Website", "X-License", "X-Curse-Project-ID",
        "SavedVariables", "SavedVariablesPerCharacter",
        "LoadOnDemand", "LoadWith", "Dependencies", "OptionalDeps",
        "Security", "Load state", "Load failure reason", "Addon index",
    }
    for i, label in ipairs(FIELDS) do
        local row = UI.StatRow(panel, label)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * 17)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * 17)
        self.metadataRows[label] = row
        row.fieldIndex = i
    end

    panel.note = UI.Text(panel, "tiny", "textMuted")
    panel.note:SetPoint("BOTTOMLEFT")
    panel.note:SetPoint("BOTTOMRIGHT")
    panel.note:SetJustifyH("LEFT")
    UI.Wrap(panel.note)
    panel.note:SetText("Read with GetAddOnMetadata, which returns only fields the addon actually declared in its .toc. \"not declared\" means the field is absent from the TOC, not that this tool could not read it.")
    self.metadataNote = panel.note
end

--- TOC fields are read on demand; there is no reason to poll them.
local META_TOC_FIELDS = {
    ["Title"] = "Title", ["Version"] = "Version", ["Author"] = "Author",
    ["Notes"] = "Notes", ["X-Category"] = "X-Category",
    ["X-Website"] = "X-Website", ["X-License"] = "X-License",
    ["X-Curse-Project-ID"] = "X-Curse-Project-ID",
    ["SavedVariables"] = "SavedVariables",
    ["SavedVariablesPerCharacter"] = "SavedVariablesPerCharacter",
    ["LoadWith"] = "LoadWith",
}

function Detail:RefreshMetadata()
    local record = self.record
    local rows = self.metadataRows
    local function set(key, value, tone)
        local row = rows[key]
        if not row then return end
        if value == nil or value == "" then
            row:Set("not declared", "muted")
        else
            row:Set(Fmt.Truncate(Fmt.StripColors(tostring(value)), 46), tone)
        end
    end

    set("Folder name", record.name)
    for label, field in pairs(META_TOC_FIELDS) do
        set(label, Compat.GetAddOnMetadata(record.index, field))
    end

    set("Interface", Compat.GetAddOnMetadata(record.index, "Interface")
        or ("not declared (client is %d)"):format(Compat.tocVersion))

    local deps = record.deps or {}
    set("Dependencies", #deps > 0 and table.concat(deps, ", ") or nil)
    local optional = record.optDeps or {}
    set("OptionalDeps", #optional > 0 and table.concat(optional, ", ") or nil)

    set("LoadOnDemand", record.lod and "yes" or "no")
    set("Security", record.security)
    set("Load state", record.loaded and "loaded" or "not loaded",
        record.loaded and nil or "muted")
    set("Load failure reason", record.reason, record.reason and "warn" or nil)
    set("Addon index", tostring(record.index))
end

--------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------

local function AddonErrorRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.count = UI.Text(row, "small", "textPrimary", "RIGHT")
    row.count:SetPoint("LEFT", 4, 0)
    row.count:SetWidth(44)

    row.when = UI.Text(row, "small", "textMuted")
    row.when:SetPoint("LEFT", row.count, "RIGHT", 8, 0)
    row.when:SetWidth(84)

    row.message = UI.Text(row, "small", "textSecondary")
    row.message:SetPoint("LEFT", row.when, "RIGHT", 8, 0)
    row.message:SetPoint("RIGHT", -6, 0)
    return row
end

local function UpdateAddonErrorRow(row, group)
    row.count:SetText(("x%d"):format(group.count or 1))
    row.count:SetTextColor(Theme:Tone(
        (group.count or 1) >= C.ERROR_REPEAT_THRESHOLD and "crit" or "warn"))
    row.when:SetText(UI.FitText(row.when, Fmt.Ago(group.lastAt)))
    row.message:SetText(UI.FitText(row.message,
        ("%s:%s  %s"):format(group.file or "?", tostring(group.line or "?"),
            Fmt.StripColors(group.message or ""))))
end

function Detail:BuildErrors(panel)
    self.errorRows = StatColumn(panel, {
        "Errors this session", "Distinct errors", "Last error", "Overlapping incidents",
    })
    for _, row in pairs(self.errorRows) do row:SetWidth(340) end

    self.errorNote = UI.Text(panel, "small", "textMuted")
    self.errorNote:SetPoint("TOPLEFT", 360, 0)
    self.errorNote:SetPoint("TOPRIGHT")
    self.errorNote:SetHeight(74)
    self.errorNote:SetJustifyH("LEFT")
    self.errorNote:SetJustifyV("TOP")
    UI.Wrap(self.errorNote)

    self.errorList = UI.ScrollList(panel, 22, AddonErrorRow, UpdateAddonErrorRow,
        function(group)
            Detail:Close()
            UI.ErrorDetail:Open(group)
        end)
    self.errorList:SetPoint("TOPLEFT", 0, -5 * 18 - 10)
    self.errorList:SetPoint("BOTTOMRIGHT")

    self.errorEmpty = UI.EmptyState(panel, "")
    self.errorEmpty:SetPoint("TOPLEFT", 0, -5 * 18 - 10)
    self.errorEmpty:SetPoint("BOTTOMRIGHT")
    self.errorEmpty:Hide()
end

function Detail:RefreshErrors()
    local record = self.record
    local rows = self.errorRows
    local Errors = WTM.Errors

    local list = Errors:ForAddon(record.name, self._addonErrors or {})
    self._addonErrors = list

    local occurrences, overlapping = 0, 0
    local last
    for i = 1, #list do
        local group = list[i]
        occurrences = occurrences + (group.count or 0)
        if not last or (group.lastAt or 0) > (last.lastAt or 0) then last = group end
        if Errors:OverlapsSpikes(group) > 0 then overlapping = overlapping + 1 end
    end

    rows["Errors this session"]:Set(Fmt.Comma(occurrences),
        occurrences > 0 and "warn" or "ok")
    rows["Distinct errors"]:Set(tostring(#list))
    rows["Last error"]:Set(last and Fmt.Ago(last.lastAt) or "never")
    rows["Overlapping incidents"]:Set(overlapping > 0 and tostring(overlapping) or "none",
        overlapping > 0 and "warn" or nil)

    self.errorList:SetData(list)
    self.errorList:SetShown(#list > 0)
    self.errorEmpty:SetShown(#list == 0)

    if not WTM.Caps:Has("errorCapture") then
        self.errorEmpty:SetMessage(
            "This client does not expose seterrorhandler, so no Lua error can be captured at all.")
    else
        self.errorEmpty:SetMessage(("No Lua error has been attributed to %s this session.")
            :format(record.title or record.name))
    end

    self.errorNote:SetText(
        "|cff9aa4b5How an error is attributed|r\nOnly from the file path in the " ..
        "message: an error raised in Interface/AddOns/" .. tostring(record.name) ..
        "/ is this addon's. An error this addon caused somewhere else carries " ..
        "that other file's path, and is listed there. Nothing is inferred from " ..
        "the message text.")
end

function Detail:BuildDiagnostics(panel)
    panel.body = UI.Text(panel, "small", "textSecondary")
    panel.body:SetPoint("TOPLEFT")
    panel.body:SetPoint("BOTTOMRIGHT")
    panel.body:SetJustifyH("LEFT")
    panel.body:SetJustifyV("TOP")
    -- Paragraphs in a box bounded on all four sides. They wrap; clipping each
    -- line would cut off the caveats, which are the part that matters most.
    UI.Wrap(panel.body, 0)
    self.diagBody = panel.body
end

--------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------

function Detail:Open(record)
    if not record then return end
    self:Build()
    self.record = record
    WTM.Processes.EnsureRings(record)
    self.scrim:Show()
    self.frame:Show()
    if not self.panels[self.currentTab or ""] then self.currentTab = "overview" end
    self.tabStrip:Select(self.currentTab)
    self:Refresh()
end

function Detail:Close()
    if self.scrim then self.scrim:Hide() end
end

function Detail:ShowTab(key)
    self.currentTab = key
    for tabKey, panel in pairs(self.panels) do
        panel:SetShown(tabKey == key)
    end
    self:Refresh()
end

function Detail:IsOpen()
    return self.scrim and self.scrim:IsShown()
end

--------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------

function Detail:ToggleEnabled()
    local record = self.record
    local enabled = (record.enableState or 2) ~= 0
    local ok, message = WTM.Processes:SetEnabled(record.name, not enabled)
    if not ok then
        WTM:Print("Cannot change state: " .. tostring(message))
        return
    end
    if message == C.TXT_COMBAT_QUEUED then
        WTM:Print(("Queued: %s will be %s once you leave combat, and takes effect after a reload.")
            :format(record.name, enabled and "disabled" or "enabled"))
    else
        WTM:Print(("%s will be %s after the next /reload.")
            :format(record.name, enabled and "disabled" or "enabled"))
    end
    self:Refresh()
end

function Detail:EstimateSavedVars()
    local bytes, names = WTM.Memory:EstimateSavedVariables(self.record)
    self.savedVarResult = bytes
    self.savedVarNames = names
    self:Refresh()
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local depScratch, dependentScratch, listenerScratch = {}, {}, {}

function Detail:Refresh()
    local record = self.record
    if not record or not self:IsOpen() then return end

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------
    local header = self.header
    header.title:SetText(Fmt.Truncate(record.titleClean or record.name, 40))
    header.sub:SetText(("%s  -  %s  -  %s")
        :format(record.name,
                record.version and ("v" .. record.version) or "no version declared",
                record.loaded and "loaded" or "not loaded"))
    header.status:Set(record.status and record.status.text or "", record.status and record.status.tone)
    header.accent:SetColorTexture(Theme:Tone(record.status and record.status.tone or "muted"))
    header.score:SetText(tostring(record.score or 100))
    header.score:SetTextColor(Theme:Tone(
        (record.score or 100) >= 80 and "ok" or ((record.score or 100) >= 50 and "warn" or "crit")))

    ------------------------------------------------------------------
    -- Control bar
    ------------------------------------------------------------------
    local enabled = (record.enableState or 2) ~= 0
    self.toggleButton:SetText(enabled and "Disable after reload" or "Enable after reload")
    self.toggleButton:SetEnabledState(WTM.Caps:Has("addonEnableDisable"),
        WTM.Caps:Note("addonEnableDisable"))
    self.loadButton:SetEnabledState(record.lod and not record.loaded,
        record.lod and "Already loaded" or "Only LoadOnDemand addons can be loaded at runtime")
    self.watchButton:SetSelected(WTM.Database:IsWatched(record.name))
    self.hideButton:SetSelected(WTM.Database:IsHidden(record.name))

    if Compat.InCombat() then
        self.controlNote:SetText(C.TXT_COMBAT_BLOCKED .. " - actions are queued until combat ends")
        self.controlNote:SetTextColor(Theme:Tone("warn"))
    else
        self.controlNote:SetText("Enable/disable takes effect after /reload. A running addon cannot be unloaded - no API exists.")
        self.controlNote:SetTextColor(T("textMuted"))
    end

    ------------------------------------------------------------------
    -- Per tab
    ------------------------------------------------------------------
    local tab = self.currentTab or "overview"
    if tab == "overview" then self:RefreshOverview()
    elseif tab == "cpu" then self:RefreshPerformance()
    elseif tab == "metadata" then self:RefreshMetadata()
    elseif tab == "memory" then self:RefreshMemory()
    elseif tab == "events" then self:RefreshEvents()
    elseif tab == "dependencies" then self:RefreshDependencies()
    elseif tab == "history" then self:RefreshHistory()
    elseif tab == "errors" then self:RefreshErrors()
    elseif tab == "diagnostics" then self:RefreshDiagnostics() end
end

local ENABLE_STATE_TEXT = { [0] = "Disabled", [1] = "Enabled for this character", [2] = "Enabled" }

function Detail:RefreshOverview()
    local record = self.record
    local rows = self.overviewRows
    local function set(key, value, tone)
        local row = rows[key]
        if row then row:Set(value, tone) end
    end

    set("Folder name",    record.name)
    set("Version",        record.version or "not declared")
    set("Author",         record.author and Fmt.Truncate(Fmt.StripColors(record.author), 28) or "not declared")
    set("Loaded",         record.loaded and "yes" or "no", record.loaded and nil or "muted")
    set("LoadOnDemand",   record.lod and "yes" or "no")
    set("Enable state",   ENABLE_STATE_TEXT[record.enableState] or "unknown")
    set("Security",       record.security or "-")
    set("Load failure reason", record.reason or "-", record.reason and "warn" or "muted")

    if WTM.CPU.available then
        set("CPU now",     ("%.2f %%"):format(record.cpuEma or 0))
        set("CPU average", ("%.2f %%"):format(WTM.CPU:GetAverage(record)))
        set("CPU peak",    ("%.2f %%"):format(record.cpuPeakPct or 0))
    else
        set("CPU now",     C.TXT_REQUIRES_PROFILING, "muted")
        set("CPU average", "-", "muted")
        set("CPU peak",    "-", "muted")
    end

    set("Memory",           Fmt.Memory(record.memKB))
    set("Memory at login",  record.memStartKB and Fmt.Memory(record.memStartKB) or "-")
    set("Growth per minute", Fmt.Memory(record.memGrowthKBPerMin or 0),
        (record.memGrowthKBPerMin or 0) >= WTM.db.profile.memory.growthThresholdKBPerMin and "warn" or nil)

    set("Spikes involved in", tostring(record.spikes or 0),
        (record.spikes or 0) > 0 and "warn" or nil)
    set("Last spike", record.lastSpikeAt and Fmt.Ago(GetTime() - record.lastSpikeAt) or "never")

    set("Named frames (heuristic)",
        record.attributionConfident and tostring(record.frameCount) or "not scanned",
        record.attributionConfident and nil or "muted")
    set("Registered events (heuristic)",
        record.attributionConfident and tostring(record.registeredEvents) or "not scanned",
        record.attributionConfident and nil or "muted")

    local notes = {}
    if record.notes then
        notes[#notes + 1] = Fmt.StripColors(record.notes)
        notes[#notes + 1] = ""
    end
    notes[#notes + 1] = "|cff9aa4b5Performance score|r"
    notes[#notes + 1] = "A presentation aid, not a measurement. It compresses smoothed CPU, sustained memory growth and spike involvement into one sortable number so the process list can lead with what is worth looking at."
    notes[#notes + 1] = ""
    notes[#notes + 1] = "|cff9aa4b5Why some numbers say 'heuristic'|r"
    notes[#notes + 1] = "No API maps a frame to the addon that created it. Frame and event counts come from matching frame names against loaded addon names, so anonymous frames are invisible and an addon whose frames do not start with its own name will be undercounted."
    self.overviewNotes:SetText(table.concat(notes, "\n"))
end

function Detail:RefreshPerformance()
    local record = self.record
    local rows = self.perfRows
    local function set(key, value, tone)
        local row = rows[key]
        if row then row:Set(value, tone) end
    end

    if not WTM.CPU.available then
        self.cpuGraph:Hide()
        self.perfUnavailable:Show()
        self.perfUnavailable:SetMessage(
            "Per-addon CPU comes from the client's own Lua profiler, enabled with the scriptProfile CVar and a reload. Without it GetAddOnCPUUsage returns zero for every addon, so nothing on this tab is estimated in the meantime - a fabricated number would be worse than an empty one. Memory, events, dependencies and metadata all work regardless.")
        for _, row in pairs(rows) do row:Set(C.TXT_UNAVAILABLE_CLIENT, "muted") end
        self.perfNotice:SetText("")
        return
    end
    self.cpuGraph:Show()
    self.perfUnavailable:Hide()

    self.cpuGraph:SetTitle("CPU USAGE (% of one core)")
    self.cpuValues = self.cpuValues or {}
    local ring = record.cpuRing
    for i = #self.cpuValues, 1, -1 do self.cpuValues[i] = nil end
    if ring then
        for i = 1, ring.count do self.cpuValues[i] = ring:Get(i) end
    end
    self.cpuGraph:SetSeries(1, self.cpuValues, nil, { label = record.name, colorIndex = 5 })
    self.cpuGraph.dirty = true
    self.cpuGraph:Draw()

    set("Peak CPU",     ("%.2f %%"):format(record.cpuPeakPct or 0))
    set("Average CPU",  ("%.2f %%"):format(WTM.CPU:GetAverage(record)))
    set("Current CPU",  ("%.2f %%"):format(record.cpuEma or 0))
    set("CPU samples",  tostring(record.cpuSamples or 0))
    set("Milliseconds since last sample", ("%.2f ms"):format(record.cpuDeltaMs or 0))
    set("Total CPU time this session", ("%.0f ms"):format(record.cpuTotalMs or 0))

    self.perfNotice:SetText(
        "|cff9aa4b5How this is measured|r\nGetAddOnCPUUsage returns cumulative milliseconds since the client's counters were last reset. Only the delta between two samples is meaningful, divided by the wall-clock time between them - that is what the percentage is.\n\n|cff9aa4b5What it does not include|r\nWork the client does on this addon's behalf outside Lua, and anything happening in another addon that this one triggered.")
end

function Detail:RefreshMemory()
    local record = self.record
    local rows = self.memRows
    local function set(key, value, tone)
        local row = rows[key]
        if row then row:Set(value, tone) end
    end

    self.memValues = self.memValues or {}
    local ring = record.memRing
    for i = #self.memValues, 1, -1 do self.memValues[i] = nil end
    if ring then
        for i = 1, ring.count do self.memValues[i] = ring:Get(i) end
    end
    self.memGraph:SetSeries(1, self.memValues, nil, { label = record.name, colorIndex = 4 })
    self.memGraph.dirty = true
    self.memGraph:Draw()

    local growth = record.memStartKB and (record.memKB - record.memStartKB) or 0
    set("Current",   Fmt.Memory(record.memKB))
    set("At login",  record.memStartKB and Fmt.Memory(record.memStartKB) or "-")
    set("Peak",      Fmt.Memory(record.memPeakKB or 0))
    set("Growth",    Fmt.MemoryDelta(growth))
    set("Growth per minute", Fmt.Memory(record.memGrowthKBPerMin or 0),
        (record.memGrowthKBPerMin or 0) >= WTM.db.profile.memory.growthThresholdKBPerMin and "warn" or nil)

    if self.savedVarResult and self.savedVarRecord == record.name then
        set("SavedVariables estimate", Fmt.Bytes(self.savedVarResult))
    else
        set("SavedVariables estimate", "not estimated", "muted")
    end
    self.savedVarRecord = record.name

    local sustained = (record.memGrowthKBPerMin or 0) >= WTM.db.profile.memory.growthThresholdKBPerMin
    self.memNotice:SetText(sustained
        and "|cffd29922Potential sustained memory growth|r\n\nThis addon's memory has been rising steadily. That is not proof of a leak: addons legitimately grow while caching combat logs, auction scans or item data. What separates a leak from a cache is that a leak never levels off and does not shrink when you leave the situation that caused it.\n\nWatch this graph after leaving a raid or closing the addon's own windows."
        or "|cff9aa4b5How this is measured|r\nUpdateAddOnMemoryUsage walks the entire Lua heap and attributes each object to the addon that allocated it, so it is expensive and runs on a slow interval.\n\nMemory attributed to an addon is not the same as memory it will release - a table shared between two addons is charged to whichever created it.")
end

function Detail:RefreshEvents()
    local record = self.record
    local hasScanned = WTM.Processes.attribution.lastScanAt > 0

    if WTM.Events:GetMode() == "OFF" then
        self.eventsNote:SetText(
            "Event monitoring is switched OFF, so no events have been observed and there is nothing to attribute.\n\nSet it to NORMAL or DETAILED in Settings.")
        for _, row in ipairs(self.eventRows) do row:Hide() end
        return
    end

    if not WTM.Caps:Has("eventToAddon") then
        self.eventsNote:SetText(
            ("Event attribution is unavailable on this client: %s.")
            :format(WTM.Caps:Note("eventToAddon") or C.TXT_UNAVAILABLE_CLIENT))
        for _, row in ipairs(self.eventRows) do row:Hide() end
        return
    end

    if not hasScanned then
        self.eventsNote:SetText(
            "No frame scan has run yet.\n\nEvent attribution requires walking every frame in the UI, matching its name against loaded addons, and asking each frame which of the busiest observed events it listens for. The registration check is exact; the frame-to-addon match is a name prefix heuristic.")
        for _, row in ipairs(self.eventRows) do row:Hide() end
        return
    end

    self.eventsNote:SetText(("%s\n\nThis addon: %d named frames matched, listening for %d of the events observed so far.")
        :format(WTM.Processes:AttributionSummary(), record.frameCount or 0, record.registeredEvents or 0))

    -- Which of the tracked events this addon's frames listen for.
    local shown = 0
    local topEvents = WTM.Events:GetTopEventNames(40, self._topEvents or {})
    self._topEvents = topEvents
    for i = 1, #topEvents do
        local event = topEvents[i]
        local listeners = WTM.Processes:GetEventListeners(event, listenerScratch)
        local frames
        for j = 1, #listeners do
            if listeners[j].name == record.name then frames = listeners[j].frames break end
        end
        if frames and shown < #self.eventRows then
            shown = shown + 1
            local row = self.eventRows[shown]
            row:Show()
            row:SetLabel(Fmt.Truncate(event, 34))
            row:Set(("%s   %d frame%s"):format(
                Fmt.Rate(WTM.Events:GetRate(event)), frames, frames == 1 and "" or "s"))
        end
    end
    for i = shown + 1, #self.eventRows do self.eventRows[i]:Hide() end

    if shown == 0 then
        self.eventRows[1]:Show()
        self.eventRows[1]:SetLabel("No attributable event registrations found")
        self.eventRows[1]:Set("")
    end
end

function Detail:RefreshDependencies()
    local record = self.record
    local deps = record.deps or {}
    local optional = record.optDeps or {}

    local shown = 0
    for i = 1, #deps do
        shown = shown + 1
        local row = self.depRows[shown]
        if row then
            row:Show()
            row:SetLabel(deps[i])
            local other = WTM.Processes:Get(deps[i])
            row:Set(other and (other.loaded and "loaded" or "not loaded") or "missing",
                (other and other.loaded) and nil or "crit")
        end
    end
    for i = 1, #optional do
        if shown < #self.depRows then
            shown = shown + 1
            local row = self.depRows[shown]
            row:Show()
            row:SetLabel(optional[i] .. "  (optional)")
            local other = WTM.Processes:Get(optional[i])
            row:Set(other and (other.loaded and "loaded" or "not loaded") or "not installed", "muted")
        end
    end
    if shown == 0 and self.depRows[1] then
        self.depRows[1]:Show()
        self.depRows[1]:SetLabel("No declared dependencies")
        self.depRows[1]:Set("")
        shown = 1
    end
    for i = shown + 1, #self.depRows do self.depRows[i]:Hide() end

    local dependents = WTM.Processes:GetDependents(record.name, dependentScratch)
    for i, row in ipairs(self.dependentRows) do
        local name = dependents[i]
        row:SetShown(name ~= nil or i == 1)
        if name then
            row:SetLabel(name)
            local other = WTM.Processes:Get(name)
            row:Set(other and other.loaded and "loaded" or "not loaded", "muted")
        elseif i == 1 then
            row:SetLabel("Nothing declares this as a dependency")
            row:Set("")
        end
    end
end

function Detail:RefreshHistory()
    local record = self.record
    local sessions = WTM.db.global.sessions

    if #sessions == 0 then
        self.historyNote:SetText(
            "No previous sessions have been saved yet. A session is stored at logout once it has run for at least 30 seconds, so this fills in from your next play session onwards.")
    else
        self.historyNote:SetText(
            ("Per-addon figures from the last %d saved session%s. Sessions recorded while CPU profiling was off have no CPU row.")
            :format(#sessions, #sessions == 1 and "" or "s"))
    end

    local shown = 0
    for i = 1, #sessions do
        local session = sessions[i]
        local cpuEntry, memEntry
        for _, entry in ipairs(session.topCPU or {}) do
            if entry.name == record.name then cpuEntry = entry break end
        end
        for _, entry in ipairs(session.topMemory or {}) do
            if entry.name == record.name then memEntry = entry break end
        end

        if (cpuEntry or memEntry) and shown < #self.historyRows then
            shown = shown + 1
            local row = self.historyRows[shown]
            row:Show()
            row:SetLabel(("%s  (%s)"):format(Fmt.DateTime(session.startedAt),
                Fmt.Duration(session.duration or 0)))
            local parts = {}
            if cpuEntry then parts[#parts + 1] = ("CPU %.2f%% avg, %.2f%% peak"):format(cpuEntry.avgPct, cpuEntry.peakPct) end
            if memEntry then parts[#parts + 1] = ("mem %s"):format(Fmt.MemoryDelta(memEntry.growthKB)) end
            row:Set(table.concat(parts, "   "))
        end
    end
    for i = shown + 1, #self.historyRows do self.historyRows[i]:Hide() end

    if shown == 0 and self.historyRows[1] then
        self.historyRows[1]:Show()
        self.historyRows[1]:SetLabel("No saved session mentions this addon")
        self.historyRows[1]:Set("")
    end
end

function Detail:RefreshDiagnostics()
    local record = self.record
    local lines = {}

    ------------------------------------------------------------------
    -- Correlation across this session
    ------------------------------------------------------------------
    local correlations, samples, unavailable = WTM.Correlation:Analyze(self._corr or {})
    self._corr = correlations
    local mine
    for i = 1, #correlations do
        if correlations[i].name == record.name then mine = correlations[i] break end
    end

    lines[#lines + 1] = "|cff9aa4b5SPIKE ASSOCIATION|r"
    if unavailable then
        lines[#lines + 1] = unavailable
    elseif samples < C.CORRELATION_MIN_SAMPLES then
        lines[#lines + 1] = ("Only %d spike%s recorded this session. At least %d are needed before an association means anything.")
            :format(samples, samples == 1 and "" or "s", C.CORRELATION_MIN_SAMPLES)
    elseif not mine then
        lines[#lines + 1] = ("This addon was not above its own average CPU during any of the %d recorded spikes.")
            :format(samples)
    else
        lines[#lines + 1] = ("|cff%s%s|r  -  phi %.2f")
            :format(Theme:ToneHex(mine.tone), mine.label, mine.phi)
        lines[#lines + 1] = mine.explanation
        lines[#lines + 1] = ("Average excess when it was elevated: %+.2f%% CPU. Peak: %+.2f%%.")
            :format(mine.avgExcess, mine.peakExcess)
        lines[#lines + 1] = ""
        lines[#lines + 1] = "|cff5d6675This measures how consistently this addon was busier than usual when the game hitched. It is an association across many samples, not a demonstrated cause. Several addons react to the same events, the sampling window is coarser than a frame, and the real cause may be outside Lua entirely.|r"
    end

    ------------------------------------------------------------------
    -- Memory
    ------------------------------------------------------------------
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cff9aa4b5MEMORY|r"
    local growth = record.memStartKB and (record.memKB - record.memStartKB) or 0
    local perMinute = record.memGrowthKBPerMin or 0
    if perMinute >= WTM.db.profile.memory.growthThresholdKBPerMin then
        lines[#lines + 1] = ("|cffd29922Potential sustained memory growth|r  -  %s so far, %s per minute.")
            :format(Fmt.MemoryDelta(growth), Fmt.Memory(perMinute))
    else
        lines[#lines + 1] = ("%s since login (%s per minute). Nothing unusual.")
            :format(Fmt.MemoryDelta(growth), Fmt.Memory(perMinute))
    end

    ------------------------------------------------------------------
    -- CPU
    ------------------------------------------------------------------
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cff9aa4b5CPU|r"
    if not WTM.CPU.available then
        lines[#lines + 1] = WTM.CPU.reason or C.TXT_REQUIRES_PROFILING
    else
        local average = WTM.CPU:GetAverage(record)
        if average >= C.HIGH_CPU_PCT then
            lines[#lines + 1] = ("|cfff0533fHigh sustained CPU|r  -  averaging %.2f%% of one core, peaking at %.2f%%.")
                :format(average, record.cpuPeakPct)
        elseif average >= C.ELEVATED_CPU_PCT then
            lines[#lines + 1] = ("Elevated  -  averaging %.2f%% of one core, peaking at %.2f%%.")
                :format(average, record.cpuPeakPct)
        else
            lines[#lines + 1] = ("Averaging %.2f%% of one core. Nothing unusual.") :format(average)
        end
    end

    ------------------------------------------------------------------
    -- What cannot be determined
    ------------------------------------------------------------------
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cff9aa4b5WHAT THIS CANNOT TELL YOU|r"
    lines[#lines + 1] = "|cff5d6675Which function inside this addon is slow (there is no sampling profiler in the addon API), how much non-Lua work the client does on its behalf, or whether its Lua triggered work that was then charged to another addon.|r"

    self.diagBody:SetText(table.concat(lines, "\n"))
end
