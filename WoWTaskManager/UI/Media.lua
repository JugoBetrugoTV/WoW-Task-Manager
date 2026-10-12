--[[--------------------------------------------------------------------------
    WoW Task Manager - UI/Media.lua

    Optional texture files under Media/ (icons, card frames, glow, logo).

    Lua inside WoW cannot ask whether a file exists, and a texture path that
    points at nothing renders as a green square rather than failing. So the
    list below is the single source of truth for what ships, and
    tools/release-check.sh fails if it disagrees with the files on disk.

    Every caller must work without the file: Path() returns nil for anything
    not listed, and the caller falls back to its flat, file-free look.
----------------------------------------------------------------------------]]

local ADDON_NAME, WTM = ...

local UI = WTM.UI
local Media = {}
UI.Media = Media

local ROOT = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"

-- One entry per file actually present, as "Folder/name" without extension,
-- e.g. ["UI/dot"] = true. Keep in sync with Media/ (release-check enforces it).
Media.PRESENT = {
}

--- Full texture path for "Folder/name", or nil when that file does not ship.
function Media.Path(name)
    if type(name) ~= "string" or not Media.PRESENT[name] then return nil end
    return ROOT .. name:gsub("/", "\\") .. ".tga"
end

--- Points `texture` at a shipped file and tints it, or falls back to a flat
--- colour. Returns true when the file was used.
function Media.Apply(texture, name, r, g, b, a)
    local path = Media.Path(name)
    if path then
        texture:SetTexture(path)
        texture:SetVertexColor(r, g, b, a or 1)
        return true
    end
    texture:SetColorTexture(r, g, b, a or 1)
    return false
end
