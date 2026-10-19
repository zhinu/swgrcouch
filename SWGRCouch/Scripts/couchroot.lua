-- couchroot.lua: COUCH CAMPAIGN - P1's WHOLE screen in P1's area during a split moment (0.15, blocker 2 of 2026-10-14).
-- Jules (live, shop split): "the split is not a split" - couchpanel / couchprerun shrank ONE inner activatable (e.g.
-- WBP_Shop_MainSelectionPanel_Presentation_C) while the screen's own background, header, credits chip, tooltips and
-- the other layer widgets stayed full screen, and P2's area overlaid P1's screen.
-- The game has no single UI root to transform: the UIManager adds every layer screen with its own AddToViewport
-- (pause.lua notes: ZOrder = layer base + count, ~500-901; UIManager keeps its layer arrays native, unreflected).
-- So the "root" is the SET of top-level viewport screens: every CommonActivatableWidget (screens, holders, the
-- persistent Dialog / MenuOverlay / tooltip containers) whose IsInViewport() is true. While at least one split user is
-- open, each of them gets couchlayout.nativeTransform (P1's area: the top strip for 2 players, the top-left quadrant
-- for 3-4); a new top-level screen (a dialog, the next screen of the flow) is caught by the next scan (500 ms); every
-- transformed screen gets its identity transform back when the last user closes. Mod widgets are never touched
-- (couchpanel.isOwn, M.exclude). 2 players: P1's 16:9 screen sits at half size in the middle of the 3840 x 1080 strip;
-- the strip's sides get the game's paper (a P1-owned backer at the lowest viewport ZOrder, under every screen).
-- Nested widgets are remembered by key (never top-level later) so a scan calls IsInViewport once per widget.
local U = require("util")
local St = require("state")
local cfg = require("config")
local L = require("couchlayout")

local TAG = "couchroot"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local SCAN_MS = 500
local R = { users = {}, n = 2, shrunk = {}, nested = {}, exclude = {}, scanAt = -1e12, backer = nil, scans = 0,
            tipAt = -1e12 }

-- BUG-8 (live 2026-10-14: P1's ION BOLT / PERFECT START tooltips drawn at their full-screen spot, over P2's area):
-- the game's tooltips are NOT in the screens. A FuseButton's RequestTooltip places its tooltip widget on the Canvas of
-- the persistent WBP_TooltipContainer_C (native UTooltipContainer : UFuseUserWidget - not a CommonActivatableWidget,
-- so couch.lua's shared scan never lists it), at the button's position in the UNtransformed layout. The container is
-- a full-viewport top-level widget like the screens: giving it the SAME transform (L.applyNative, same pivot / scale)
-- puts every tooltip next to its shrunk button, in P1's area. Found by its own FindAllOf (rare class): at a split's
-- start, then every TIP_RETRY_MS until one is in the viewport (it is created lazily on the first request).
local TIP_CLS, TIP_RETRY_MS = "WBP_TooltipContainer_C", 3000

local function anyUser()
    for _ in pairs(R.users) do return true end
    return false
end

local function isOwn(k)
    if R.exclude[k] then return true end
    local cp = package.loaded["couchpanel"]
    if type(cp) == "table" and type(cp.isOwn) == "function" and cp.isOwn(k) then return true end
    return false
end

function M.exclude(w) if U.ok(w) then R.exclude[U.key(w)] = true end end

-- pure: may a top-level screen of this class be moved into P1's area? (the HUD of a race never is: no split race UI here)
function M.movable(cls)
    if type(cls) ~= "string" or cls:sub(1, 4) ~= "WBP_" then return false end
    if cls:find("^WBP_Hud") then return false end
    return true
end

-- the paper on both sides of P1's strip (2 players): a P1-owned host at the lowest ZOrder, under every game screen
local function backerOpen()
    if R.backer or R.n ~= 2 or opt("CouchRootBacker", true) == false then return end
    local okH, H = pcall(function() return U.mod("couchpanel").newHost() end)
    if not okH or type(H) ~= "table" then return end
    local kit = U.mod("couchpanel").kit
    -- (7) the two sides are crops of ONE paper covering the whole strip (ScaleToFill, texture aspect kept): they were the
    -- full texture squeezed into 960 x 1080 each. The middle stays open (P1's own screen / his 3D scene).
    pcall(function()
        local strip = { 0, 0, 3840, 1080 }
        if type(kit.paperCover) == "function" then
            kit.paperCover(H.tree, H.cv, { 0, 0, 960, 1080 }, strip, 0)
            kit.paperCover(H.tree, H.cv, { 2880, 0, 960, 1080 }, strip, 0)
        end
        H.host:SetVisibility(kit.VIS.HitTestInvisible)
        H.host:AddToViewport(-50)
    end)
    R.backer = H.host
    M.exclude(H.host)
end

local function backerClose(calls)
    local b = R.backer
    R.backer = nil
    if b and calls ~= false and U.alive(b) then pcall(function() b:RemoveFromParent() end) end
end

local function scan(now)
    R.scanAt = now
    R.scans = R.scans + 1
    local okQ, q = pcall(function() return U.mod("couch").isQuiet() end)
    if okQ and q == true then return 0 end
    local moved = 0
    local seen = {}
    -- couch.lua's shared scan (one FindAllOf per screen change, class names cached): no scan of our own
    local okA, all = pcall(function() return U.mod("couch").allActivatables() end)
    if not okA or type(all) ~= "table" then return 0 end
    for _, e in ipairs(all) do
        local w, k, cn = e.w, e.k, e.cls
        if U.ok(w) then
            seen[k] = true
            if not R.shrunk[k] and not R.nested[k] and not isOwn(k) then
                if M.movable(cn) and U.alive(w) then
                    local top = false
                    pcall(function() top = w:IsInViewport() == true end)
                    if top then
                        if L.applyNative(w, R.n) then
                            R.shrunk[k] = { w = w, cls = cn }
                            moved = moved + 1
                        end
                    else
                        R.nested[k] = true
                    end
                end
            end
        end
    end
    for k, e in pairs(R.shrunk) do
        if not seen[k] and not e.tip then R.shrunk[k] = nil end                   -- collected: nothing to restore
    end
    if moved > 0 then
        local names = {}
        for _, e in pairs(R.shrunk) do names[#names + 1] = e.cls end
        table.sort(names)
        U.log(TAG, "P1's screen into his area (%d player(s)): %d new top-level screen(s); now %s", R.n, moved,
            table.concat(names, ", "))
    end
    return moved
end

-- the tooltip container(s) into P1's area. -> moved
local function tipScan(now)
    R.tipAt = now
    local okQ, q = pcall(function() return U.mod("couch").isQuiet() end)
    if okQ and q == true then return 0 end
    local moved = 0
    pcall(function()
        for _, w in ipairs(FindAllOf(TIP_CLS) or {}) do
            if U.ok(w) then
                local k = U.key(w)
                if not R.shrunk[k] and not isOwn(k) and U.alive(w) then
                    local top = false
                    pcall(function() top = w:IsInViewport() == true end)
                    if top and L.applyNative(w, R.n) then
                        R.shrunk[k] = { w = w, cls = TIP_CLS, tip = true }
                        moved = moved + 1
                    end
                end
            end
        end
    end)
    if moved > 0 then U.log(TAG, "tooltips into P1's area: %d tooltip container(s)", moved) end
    return moved
end

local function hasTip()
    for _, e in pairs(R.shrunk) do if e.tip and U.alive(e.w) then return true end end
    return false
end

-- a split moment opens (user = "panel" | "prerun" | "build"; n = players in the split)
function M.begin(user, n)
    if opt("CouchRootSplit", true) == false then return false end
    local was = anyUser()
    R.users[user] = true
    n = math.max(2, math.min(4, math.floor(tonumber(n) or 2)))
    if was and n ~= R.n then
        -- another layout: every screen again with the new transform
        for _, e in pairs(R.shrunk) do if U.alive(e.w) then L.applyNative(e.w, n) end end
    end
    local nWas = R.n
    R.n = n
    -- #93: a re-laid-out split (4 -> 2 players): the 2-player side papers come / go with the strip layout
    if was and nWas ~= n then
        if n == 2 then backerOpen() else backerClose(true) end
    end
    if not was then
        U.log(TAG, "split on (%s, %d player(s)): every top-level game screen goes into P1's area", tostring(user), n)
        backerOpen()
    end
    U.try(TAG, scan, St.nowMs())
    if not hasTip() then U.try(TAG, tipScan, St.nowMs()) end
    return true
end

-- calls = false on a world change: nothing is called on dying widgets
function M.finish(user, calls)
    if not R.users[user] then return end
    R.users[user] = nil
    if anyUser() then return end
    local n = 0
    if calls ~= false then
        for _, e in pairs(R.shrunk) do
            if U.alive(e.w) then L.restoreNative(e.w); n = n + 1 end
        end
    end
    backerClose(calls)
    U.log(TAG, "split off (%s): %d screen(s) back to full screen", tostring(user), n)
    R.shrunk, R.nested = {}, {}
end

function M.tick()
    if not anyUser() then return end
    local now = St.nowMs()
    if now - R.scanAt < SCAN_MS then return end
    U.try(TAG, scan, now)
    if now - R.tipAt >= TIP_RETRY_MS and not hasTip() then U.try(TAG, tipScan, now) end
end

function M.active() return anyUser() end
function M.count() local c = 0; for _ in pairs(R.shrunk) do c = c + 1 end; return c end
function M.isShrunk(w) return U.ok(w) and R.shrunk[U.key(w)] ~= nil end
function M.stats() return { scans = R.scans, shrunk = M.count(), n = R.n } end

function M.init()
    St.on("leaving", TAG, function()
        for u in pairs(R.users) do M.finish(u) end
    end)
    St.on("world", TAG, function()
        R.users, R.shrunk, R.nested, R.exclude, R.backer, R.tipAt = {}, {}, {}, {}, nil, -1e12
    end)
end

return M
