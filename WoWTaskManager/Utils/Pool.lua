--[[--------------------------------------------------------------------------
    WoW Task Manager - Utils/Pool.lua

    Table pool and texture/fontstring pools.  The graph engine redraws several
    times per second; without pooling it would create thousands of textures per
    minute and become exactly the kind of addon this tool is meant to catch.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local wipe = wipe or table.wipe

--------------------------------------------------------------------------
-- Generic table pool
--------------------------------------------------------------------------

local TablePool = {}
TablePool.__index = TablePool
WTM.TablePool = TablePool

function TablePool.New()
    return setmetatable({ free = {}, n = 0, created = 0, reused = 0 }, TablePool)
end

function TablePool:Acquire()
    local n = self.n
    if n > 0 then
        local t = self.free[n]
        self.free[n] = nil
        self.n = n - 1
        self.reused = self.reused + 1
        return t
    end
    self.created = self.created + 1
    return {}
end

function TablePool:Release(t)
    if type(t) ~= "table" then return end
    wipe(t)
    local n = self.n + 1
    self.n = n
    self.free[n] = t
end

function TablePool:ReleaseArray(arr)
    for i = #arr, 1, -1 do
        self:Release(arr[i])
        arr[i] = nil
    end
end

--------------------------------------------------------------------------
-- Frame-region pools (textures, fontstrings, child frames)
--------------------------------------------------------------------------

local RegionPool = {}
RegionPool.__index = RegionPool
WTM.RegionPool = RegionPool

--- factory(parent) must return the new region.
--- resetter(region) is called when a region goes back into the pool.
function RegionPool.New(parent, factory, resetter)
    return setmetatable({
        parent   = parent,
        factory  = factory,
        resetter = resetter,
        active   = {},
        inactive = {},
        nActive  = 0,
        nFree    = 0,
        created  = 0,
    }, RegionPool)
end

function RegionPool:Acquire()
    local region
    local nFree = self.nFree
    if nFree > 0 then
        region = self.inactive[nFree]
        self.inactive[nFree] = nil
        self.nFree = nFree - 1
    else
        region = self.factory(self.parent)
        self.created = self.created + 1
    end
    local nActive = self.nActive + 1
    self.nActive = nActive
    self.active[nActive] = region
    region:Show()
    return region
end

--- Releases everything acquired since the last ReleaseAll.  The graph engine
--- calls this at the start of every redraw, which keeps the texture count
--- bounded by the widest frame ever drawn rather than by the redraw count.
function RegionPool:ReleaseAll()
    local resetter = self.resetter
    for i = self.nActive, 1, -1 do
        local region = self.active[i]
        self.active[i] = nil
        region:Hide()
        if resetter then resetter(region) end
        local nFree = self.nFree + 1
        self.nFree = nFree
        self.inactive[nFree] = region
    end
    self.nActive = 0
end

function RegionPool:GetStats()
    return self.created, self.nActive, self.nFree
end

--------------------------------------------------------------------------
-- Shared pools used across the UI
--------------------------------------------------------------------------

WTM.Pools = {
    tables = TablePool.New(),
}
