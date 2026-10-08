--[[
    CompassLoc | position.lua
    Author: Mage

    Overview: Converts between viewport pixels and normalized saved compass-anchor
              coordinates.
    Scope: Pure coordinate arithmetic and clamping; no game-memory access.
]]

local M = {}
function M.xy(v)
    return v.x or v[1], v.y or v[2]
end

local function finite(v)
    assert(
        type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge,
        'Invalid coordinate'
    )
    return v
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, finite(v)))
end

function M.normalize(x, y, w, h)
    assert(w > 1 and h > 1, 'Viewport unavailable')
    return clamp(x, 0, w - 1) / (w - 1), clamp(y, 0, h - 1) / (h - 1)
end

function M.resolve(ax, ay, w, h)
    assert(w > 1 and h > 1, 'Viewport unavailable')
    return math.floor(clamp(ax, 0, 1) * (w - 1) + 0.5), math.floor(clamp(ay, 0, 1) * (h - 1) + 0.5)
end

return M
