-- couchlayout.lua: COUCH CAMPAIGN - the split of one shared native screen between 2-4 local players (0.15).
-- Shared by every couch panel (couchprerun's vehicle / racer-style split, later the rewards view): P1 keeps the native
-- screen, shrunk into HIS area by a render transform (the subsplit.lua technique: layout untouched, no re-layout of the
-- game's widgets); every guest gets his own area for a mod panel. Pure math + one pcall-guarded transform helper; no
-- module state, no UObject kept.
--   2 players: TOP / BOTTOM strips (P1 top, P2 bottom; 3840 x 1080 each, like the race split): the game's UI is made for
--   wide screens (a 16:9 frame centred, its paper backdrop running to the edges - Jules's 21:9 reference), so each
--   strip shows the 16:9 screen at half size in its centre with the paper filling the whole strip.
--   3-4 players: quadrants (P1 top left, P2 top right, P3 bottom left, P4
--   bottom right; with 3 the 4th quadrant is free).
-- Units: the campaign's 3840 x 2160 canvas (couchpanel's ScaleBox -> SizeBox host), at any resolution.
local M = {}

M.VW, M.VH = 3840, 2160

local function clampN(n)
    n = math.floor(tonumber(n) or 1)
    if n < 1 then return 1 end
    if n > 4 then return 4 end
    return n
end

-- Area of player slot index (1 = P1) in an n-player split -> x, y, w, h (canvas units).
function M.area(index, n)
    n = clampN(n)
    index = math.max(1, math.min(4, math.floor(tonumber(index) or 1)))
    local hw, hh = M.VW / 2, M.VH / 2
    if n == 1 then return 0, 0, M.VW, M.VH end
    if n == 2 then return 0, (index - 1 >= 1) and hh or 0, M.VW, hh end
    local col, row = (index - 1) % 2, math.floor((index - 1) / 2)
    return col * hw, row * hh, hw, hh
end

-- The 16:9 content frame inside area(index, n) (the native screen / a ScaleToFit copy show their 3840 x 2160 canvas
-- there): strips = the centred 1920 x 1080, quadrants = the quadrant itself -> x, y, w, h.
function M.frame(index, n)
    local x, y, w, h = M.area(index, n)
    local fw = math.min(w, h * M.VW / M.VH)
    local fh = fw * M.VH / M.VW
    return x + (w - fw) / 2, y + (h - fh) / 2, fw, fh
end

-- Number of areas the split draws (3 players still split in quadrants: 4 areas, the last one free).
function M.slots(n)
    n = clampN(n)
    if n <= 2 then return n end
    return 4
end

-- Render transform that puts a FULL-SCREEN native widget into area(1, n): {scale, pivot = {X, Y}}.
-- Strips: scale 0.5 around the top edge's middle (x 960..2880, y 0..1080); quadrants: 0.5 around the top left.
function M.nativeTransform(n)
    n = clampN(n)
    if n == 1 then return { scale = 1, pivot = { X = 0.5, Y = 0.5 } } end
    if n == 2 then return { scale = 0.5, pivot = { X = 0.5, Y = 0 } } end
    return { scale = 0.5, pivot = { X = 0, Y = 0 } }
end

-- a widget kept across ticks may be dead: a call on it is a native AV that pcall cannot catch (util is looked up lazily:
-- the offline tests load this file alone)
local function alive(w)
    local U = package.loaded["util"]
    if type(U) == "table" and type(U.alive) == "function" then return U.alive(w) end
    return w ~= nil
end

-- Apply / undo nativeTransform on a widget (pcall-guarded; U.alive checked here too, not only by the callers).
function M.applyNative(w, n)
    if not alive(w) then return false end
    local t = M.nativeTransform(n)
    return pcall(function()
        w:SetRenderTransformPivot(t.pivot)
        w:SetRenderScale({ X = t.scale, Y = t.scale })
    end)
end

function M.restoreNative(w)
    if not alive(w) then return false end
    return pcall(function()
        w:SetRenderScale({ X = 1, Y = 1 })
        w:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
    end)
end

-- Grid of count tiles in a w x h box: the column count giving the largest tiles of aspect (w / h of a tile).
-- -> cols, rows, tileW, tileH (gap between tiles included in the fit)
function M.grid(count, w, h, aspect, gap)
    count = math.max(1, math.floor(tonumber(count) or 1))
    aspect, gap = tonumber(aspect) or 1, tonumber(gap) or 0
    local best = nil
    for c = 1, count do
        local r = math.ceil(count / c)
        local tw = (w - (c - 1) * gap) / c
        local th = (h - (r - 1) * gap) / r
        if tw > 0 and th > 0 then
            if tw / th > aspect then tw = th * aspect else th = tw / aspect end
            if not best or tw * th > best[3] * best[4] then best = { c, r, tw, th } end
        end
    end
    if not best then return 1, count, w, h / count end
    return best[1], best[2], math.floor(best[3]), math.floor(best[4])
end

return M
