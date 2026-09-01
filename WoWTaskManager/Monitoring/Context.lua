--[[--------------------------------------------------------------------------
    WoW Task Manager - Monitoring/Context.lua

    Tracks "what was the game doing" so every spike snapshot can say whether it
    happened in combat, during a loading screen, on a boss pull or while zoning.

    Every event here is registered through Compat.SafeRegisterEvent, so a client
    that does not broadcast ENCOUNTER_START simply never gets encounter markers
    instead of throwing a Lua error at login.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local C      = WTM.C
local Compat = WTM.Compat
local api    = Compat.api

local Context = WTM:NewModule("Context")
WTM.Context = Context

Context.state = {
    combat       = false,
    instanceType = "none",
    instanceName = nil,
    difficulty   = nil,
    zone         = nil,
    groupSize    = 0,
    encounter    = nil,
    encounterId  = nil,
    loading      = false,
    resting      = false,
}

-- Timeline markers produced by context changes.  Bounded ring; the timeline
-- page reads it, nothing else.
Context.markers = {}
local MAX_MARKERS = 400

local function AddMarker(kind, label)
    local markers = Context.markers
    local n = #markers + 1
    if n > MAX_MARKERS then
        table.remove(markers, 1)
        n = MAX_MARKERS
    end
    markers[n] = { t = GetTime(), kind = kind, label = label }
    WTM:SendMessage("WTM_MARKER", kind, label)
end
Context.AddMarker = function(_, kind, label) AddMarker(kind, label) end

function Context:GetMarkersInRange(fromTime, toTime, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    for i = 1, #self.markers do
        local m = self.markers[i]
        if m.t >= fromTime and m.t <= toTime then out[#out + 1] = m end
    end
    return out
end

--------------------------------------------------------------------------
-- Flags packed into a flight recorder slot
--------------------------------------------------------------------------

function Context:Flags()
    local s = self.state
    local flags = 0
    if s.combat then flags = flags + C.FLAG_COMBAT end
    if s.instanceType and s.instanceType ~= "none" then flags = flags + C.FLAG_INSTANCE end
    if s.loading then flags = flags + C.FLAG_LOADING end
    if s.encounter then flags = flags + C.FLAG_ENCOUNTER end
    if (s.groupSize or 0) > 1 then flags = flags + C.FLAG_GROUP end
    if s.resting then flags = flags + C.FLAG_RESTING end
    return flags
end

--- Copies the current context into `out` for a snapshot record.
function Context:Capture(out)
    out = out or {}
    local s = self.state
    out.combat       = s.combat
    out.instanceType = s.instanceType
    out.instanceName = s.instanceName
    out.difficulty   = s.difficulty
    out.zone         = s.zone
    out.groupSize    = s.groupSize
    out.encounter    = s.encounter
    out.loading      = s.loading
    return out
end

function Context:Describe()
    local s = self.state
    local parts = {}
    parts[#parts + 1] = s.zone or "Unknown zone"
    if s.instanceType and s.instanceType ~= "none" then
        parts[#parts + 1] = (s.instanceName or s.instanceType) ..
            (s.difficulty and (" (" .. s.difficulty .. ")") or "")
    end
    if s.encounter then parts[#parts + 1] = "Encounter: " .. s.encounter end
    if s.combat then parts[#parts + 1] = "In combat" end
    if (s.groupSize or 0) > 1 then parts[#parts + 1] = ("Group %d"):format(s.groupSize) end
    return table.concat(parts, "  |  ")
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

function Context:Refresh()
    local s = self.state

    if api.GetInstanceInfo then
        local name, instanceType, difficultyID, difficultyName = Compat.SafeCall(
            "GetInstanceInfo", api.GetInstanceInfo)
        s.instanceName = name
        s.instanceType = instanceType or "none"
        s.difficulty   = difficultyName
    end

    s.zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or nil
    if s.zone == "" then s.zone = nil end

    if api.GetNumGroupMembers then
        s.groupSize = Compat.SafeCall("GetNumGroupMembers", api.GetNumGroupMembers) or 0
    end

    if IsResting then s.resting = IsResting() and true or false end
    s.combat = Compat.InCombat()
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Context:OnInitialize()
    self.availableMarkers = {
        combat    = WTM.Caps:Has("combatMarkers"),
        encounter = WTM.Caps:Has("encounterMarkers"),
        keystone  = WTM.Caps:Has("keystoneMarkers"),
        loading   = WTM.Caps:Has("loadingMarkers"),
        zone      = WTM.Caps:Has("zoneMarkers"),
    }
end

function Context:OnEnable()
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnZoneChanged")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneChanged")

    -- Optional per client.  RegisterEvent returns false instead of erroring
    -- when the client does not know the event.
    self:RegisterEvent("ENCOUNTER_START", "OnEncounterStart")
    self:RegisterEvent("ENCOUNTER_END", "OnEncounterEnd")
    self:RegisterEvent("CHALLENGE_MODE_START", "OnKeystoneStart")
    self:RegisterEvent("LOADING_SCREEN_ENABLED", "OnLoadingStart")
    self:RegisterEvent("LOADING_SCREEN_DISABLED", "OnLoadingEnd")
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnRosterChanged")

    self:Refresh()
end

function Context:OnDisable()
    self:UnregisterAllEvents()
end

function Context:OnCombatStart()
    self.state.combat = true
    AddMarker("combat", "Combat start")
end

function Context:OnCombatEnd()
    self.state.combat = false
end

function Context:OnZoneChanged()
    local previous = self.state.zone
    self:Refresh()
    if self.state.zone and self.state.zone ~= previous then
        AddMarker("zone", self.state.zone)
    end
end

function Context:OnEncounterStart(_, encounterId, encounterName)
    self.state.encounter   = encounterName
    self.state.encounterId = encounterId
    AddMarker("encounter", encounterName or ("Encounter " .. tostring(encounterId)))
end

function Context:OnEncounterEnd()
    self.state.encounter, self.state.encounterId = nil, nil
end

function Context:OnKeystoneStart()
    AddMarker("encounter", "Keystone start")
end

function Context:OnLoadingStart()
    self.state.loading = true
    AddMarker("loading", "Loading screen")
end

function Context:OnLoadingEnd()
    self.state.loading = false
    self:Refresh()
end

function Context:OnRosterChanged()
    if api.GetNumGroupMembers then
        self.state.groupSize = Compat.SafeCall("GetNumGroupMembers", api.GetNumGroupMembers) or 0
    end
end
