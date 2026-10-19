-- finishplate.lua: #96 (live 2026-10-18 09:30, takedowns test, photo state/runs/20261018-session/p1-no-hud-photo.jpg):
-- P1 reached 10/10 at 32 s and was finished (EventFinishTime 32.33); the game took his HUD away (a finished racer has
-- no race HUD), hud.lua hides the game's viewport-wide results panel while a guest still races (it would cover the
-- guests' views: cfg.LocalResultsMode), so P1's half showed his car driving on with NO UI at all until P2 was done.
-- In solo the finish goes straight to the results; a couch player who is done must see that he is done.
-- THIS (cfg.CouchFinishPlate): while a couch race runs and at least one other view-holding player still races, every
-- view-holding player who is OUT of the race (his REC no longer IsStillRacing: finished / wrecked / eliminated) gets
-- a result plate in HIS OWN view - his verdict, his score and his time ("TEST PASSED - 10/10 - 00:32.33", "FAILED - 3/10
-- - 02:00.00", "FINISHED - PLACE 2 - 01:41.20", "WRECKED") and "WAITING FOR P2" (the players still racing) - kept until
-- the race ends (POSTRACE: the game's results and couchsolo's band take over) or he races again (a restart).
-- The game's own WBP_PostRace_Info is ONE viewport-wide widget of P1's results CSM state (its "rehost" mode into P1's
-- player screen is cfg.LocalResultsMode's, unverified live), so the plate is the mod's own: couchpanel's host (the
-- 3840 x 2160 canvas) on the viewport, hit-test invisible, the plate centred in the lower third of his split rect
-- (split.layoutRects, the 2P layout setting). A race-alone test reads couchsolo's own verdict / medal and soloscore's
-- own score (the same lines the results band shows later); a race reads his own place (instances' own copy, else the
-- game's EventPosition).
-- [?] live: the plate is drawn over his view in a split race (couchpanel host on the viewport, as the results band).
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "finishplate"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local TICK_MS = 250
M.PLATE_W, M.PLATE_H = 1500, 250

---------------------------------------------------------------------------------------------------- pure
-- the plate's two lines. s = {pnum, verdict ("passed" | "failed" | "wrecked" | "dnf" | "finished"), test (bool),
-- score (text), time (sec), place, of, medal, waiting = {"P2", ...}} -> line1, line2
function M.plateText(s)
    local fmt = function(t)
        local x = tonumber(t)
        if not x or x < 0 then return nil end
        local m = math.floor(x / 60)
        return string.format("%02d:%05.2f", m, x - m * 60)
    end
    local parts = {}
    local v = s.verdict
    if v == "wrecked" then
        parts[1] = "WRECKED"
    elseif v == "dnf" then
        parts[1] = "OUT OF THE RACE"
    elseif s.test then
        parts[1] = (v == "passed") and "TEST PASSED" or "TEST FAILED"
    else
        parts[1] = "FINISHED"
    end
    if s.score and v ~= "wrecked" then parts[#parts + 1] = s.score end
    if not s.test and s.place and v ~= "wrecked" and v ~= "dnf" then
        parts[#parts + 1] = s.of and string.format("PLACE %d OF %d", s.place, s.of) or string.format("PLACE %d", s.place)
    end
    local t = (v ~= "wrecked") and fmt(s.time) or nil
    if t then parts[#parts + 1] = t end
    if s.medal and v == "passed" then parts[#parts + 1] = s.medal end
    local l2 = nil
    if type(s.waiting) == "table" and #s.waiting > 0 then l2 = "WAITING FOR " .. table.concat(s.waiting, ", ") end
    return table.concat(parts, "  -  "), l2
end

-- the plate's rect in canvas units (3840 x 2160) inside view slot i of n (split rects {ox, oy, sx, sy})
function M.plateRect(rect, vw, vh, w, h)
    vw, vh = vw or 3840, vh or 2160
    local rx, ry, rw, rh = rect.ox * vw, rect.oy * vh, rect.sx * vw, rect.sy * vh
    w = math.min(w or M.PLATE_W, rw - 80)
    h = h or M.PLATE_H
    return math.floor(rx + (rw - w) / 2), math.floor(ry + rh * 0.62 - h / 2), math.floor(w), math.floor(h)
end

---------------------------------------------------------------------------------------------------- race
local P = { gen = nil, host = nil, plates = {}, at = -1e12, logged = {} }
local stats = { plates = 0, updates = 0, fails = 0 }
function M.stats() return stats end

-- couch-fix40: a PC's RaceEventComponent (pc.PlayerState's own component) is kept per world for REC_TTL_MS (U.ok-checked at every use; 2 UE4SS wrappers
-- + a closure per player per tick before), IsStillRacing through the kept UFunction (U.pcallFn), joinedList once per
-- tick (it was walked once per guest view)
local REC_TTL_MS = 2000
local recCache = { gen = nil, byPc = {} }
local function recOf(pc)
    local now, pk = St.nowMs(), U.key(pc)
    if recCache.gen ~= St.worldGen then recCache.gen, recCache.byPc = St.worldGen, {} end
    local c = recCache.byPc[pk]
    if c and now - c.at < REC_TTL_MS and U.ok(c.rec) then return c.rec end
    local rec = nil
    pcall(function() rec = pc.PlayerState.RaceEventComponent end)
    rec = U.ok(rec) and rec or nil
    recCache.byPc[pk] = rec and { rec = rec, at = now } or nil
    return rec
end

local STILL_RACING = "/Script/Griffin.PlayerRaceEventComponent:IsStillRacing"
local function racing(rec)
    local r = nil
    local okR, v = U.pcallFn(rec, STILL_RACING, "IsStillRacing")
    if okR then r = v end
    if type(r) == "boolean" then return r end
    local out = false
    pcall(function() out = rec.bHasFinishedEvent == true or rec.bHasVehicleWrecked == true or rec.bHasBeenEliminated == true end)
    return not out
end

local function pnumOf(e, joined)
    if e.index == 1 then return 1 end
    local pn = nil
    if type(joined) == "table" then                    -- couch-fix40: no closure when the tick's list is there
        local ek = U.key(e.pc)
        for _, j in ipairs(joined) do
            if U.ok(j.pc) and U.key(j.pc) == ek then pn = j.pnum end
        end
        return pn or e.index
    end
    pcall(function()
        joined = joined or U.mod("join").joinedList()
        for _, j in ipairs(joined) do
            if U.ok(j.pc) and U.key(j.pc) == U.key(e.pc) then pn = j.pnum end
        end
    end)
    return pn or e.index
end

-- one out player's plate data (his own verdict / score / time / place)
local function plateData(pc, rec, waiting)
    local s = { waiting = waiting }
    local fin, wr, el, fail, t = false, false, false, 0, nil
    pcall(function() fin = rec.bHasFinishedEvent == true end)
    pcall(function() wr = rec.bHasVehicleWrecked == true end)
    pcall(function() el = rec.bHasBeenEliminated == true end)
    pcall(function() fail = tonumber(rec.FailReasons) or 0 end)
    pcall(function() t = tonumber(rec.EventFinishTime) end)
    s.time = t
    local ps = nil
    pcall(function() ps = pc.PlayerState end)
    local cs = U.mod("couchsolo")
    local alone = false
    pcall(function() alone = cs.raceAlone() == true end)
    if alone then
        s.test = true
        local sc = nil
        pcall(function() sc = U.mod("soloscore").scoreOf(ps) end)
        if type(sc) == "table" then
            s.score = sc.text
            -- a scored test's own time: the moment he reached his target (his finish call follows it)
            if sc.reached and tonumber(sc.reachedAt) and sc.reachedAt >= 0 and not (t and t >= 0) then s.time = sc.reachedAt end
        end
        local v = "dnf"
        pcall(function()
            v = cs.verdict({ fin = fin, wrecked = wr, elim = el, fail = fail, time = t, score = sc }, cs.target())
        end)
        s.verdict = v
        pcall(function()
            local i = cs.info()
            if not sc then s.medal = cs.medalOf(t, i.targets) end
        end)
    else
        s.verdict = wr and "wrecked" or ((fin and not el) and "finished" or "dnf")
        local lp, of = nil, nil
        pcall(function() lp, _, of = U.mod("instances").localPosition(ps) end)
        if not lp then pcall(function() lp = tonumber(rec.EventPosition) end) end
        if lp and lp > 0 then s.place, s.of = lp, of end
    end
    return s
end

local function closeAll(why)
    if P.host and U.alive(P.host) then pcall(function() P.host:RemoveFromParent() end) end
    if P.host and why then U.log(TAG, "finish plates removed (%s)", tostring(why)) end
    P.host, P.cv, P.tree, P.plates = nil, nil, nil, {}
end

local function ensureHost()
    if P.host and U.alive(P.host) then return true end
    local CP = U.mod("couchpanel")
    local ok, H = pcall(CP.newHost)
    if not (ok and type(H) == "table") then
        stats.fails = stats.fails + 1
        U.logEvery("finishplate.host", 10000, TAG, "WARN no plate host (%s): a finished player's view stays bare",
            tostring(H))
        return false
    end
    pcall(function() H.host:SetVisibility(CP.kit.VIS.HitTestInvisible) end)
    pcall(function() H.host:AddToViewport((tonumber(opt("CouchPanelZ", 1000)) or 1000) - 7) end)
    pcall(function() U.mod("couchroot").exclude(H.host) end)
    P.host, P.cv, P.tree = H.host, H.cv, H.tree
    return true
end

local function draw(slot, rect, l1, l2, passed, pnum)
    local CP = U.mod("couchpanel")
    local kit = CP.kit
    local C = require("consts")
    local pl = P.plates[slot]
    if not pl then
        local x, y, w, h = M.plateRect(rect, kit.VW, kit.VH)
        pl = { x = x, y = y, w = w, h = h }
        pl.back = kit.solid(P.tree, kit.colours.DEEP)
        kit.place(P.cv, pl.back, x, y, w, h, 1)
        pl.stripe = kit.solid(P.tree, C.COLOURS[pnum] or kit.colours.AMBER)
        kit.place(P.cv, pl.stripe, x, y, 16, h, 2)
        pl.t1 = kit.text(P.tree, 56, kit.colours.AMBER)
        local s1 = kit.place(P.cv, pl.t1, x + w / 2, y + 40, nil, nil, 3)
        pcall(function() s1:SetAlignment({ X = 0.5, Y = 0 }) end)
        pl.t2 = kit.text(P.tree, 40, kit.colours.PAPER)
        local s2 = kit.place(P.cv, pl.t2, x + w / 2, y + 140, nil, nil, 3)
        pcall(function() s2:SetAlignment({ X = 0.5, Y = 0 }) end)
        P.plates[slot] = pl
        stats.plates = stats.plates + 1
    end
    if pl.l1 ~= l1 or pl.l2 ~= l2 or pl.passed ~= passed then
        kit.setText(pl.t1, l1)
        pcall(function() kit.setInk(pl.t1, passed and kit.colours.SAGE or kit.colours.AMBER) end)
        kit.setText(pl.t2, l2 or "")
        pl.l1, pl.l2, pl.passed = l1, l2, passed
        stats.updates = stats.updates + 1
    end
    kit.show(pl.back, true); kit.show(pl.stripe, true); kit.show(pl.t1, true); kit.show(pl.t2, l2 ~= nil)
    pl.on = true
end

local function hide(slot)
    local pl = P.plates[slot]
    if not (pl and pl.on) then return end
    local kit = U.mod("couchpanel").kit
    for _, w in ipairs({ pl.back, pl.stripe, pl.t1, pl.t2 }) do kit.show(w, false) end
    pl.on = false
end

function M.mainTick()
    if opt("CouchFinishPlate", true) ~= true then return end
    if St.phase ~= "RACING" then
        if P.host then closeAll("phase " .. tostring(St.phase)) end
        return
    end
    if P.gen ~= St.worldGen then
        closeAll()
        P = { gen = St.worldGen, host = nil, plates = {}, at = -1e12, logged = {} }
    end
    local now = St.nowMs()
    if now - P.at < TICK_MS then return end
    P.at = now
    local split = U.mod("split")
    local views = {}
    pcall(function() views = split.viewSplit().views end)
    if #views < 2 then return end
    local side = false
    pcall(function() side = U.mod("settings").get("Layout2P") == "side-by-side" end)
    local rects = split.layoutRects(#views, side)
    local state = {}
    local joined = nil
    pcall(function() joined = U.mod("join").joinedList() end)
    for i, e in ipairs(views) do
        local rec = U.ok(e.pc) and recOf(e.pc) or nil
        state[i] = { e = e, rec = rec, pnum = pnumOf(e, joined), out = rec ~= nil and racing(rec) == false }
    end
    local waiting = {}
    for _, s in ipairs(state) do if s.rec and not s.out then waiting[#waiting + 1] = "P" .. s.pnum end end
    for i, s in ipairs(state) do
        if s.out and #waiting > 0 then
            if ensureHost() then
                local d = plateData(s.e.pc, s.rec, waiting)
                d.pnum = s.pnum
                local l1, l2 = M.plateText(d)
                local okD, err = pcall(draw, i, rects[i], l1, l2, d.verdict == "passed", s.pnum)
                if not okD then
                    stats.fails = stats.fails + 1
                    U.logEvery("finishplate.draw", 10000, TAG, "WARN P%d's finish plate: %s", s.pnum, tostring(err))
                elseif P.logged[i] ~= l1 .. "|" .. tostring(l2) then
                    P.logged[i] = l1 .. "|" .. tostring(l2)
                    U.log(TAG, "P%d is out of the race, others still racing: his view shows \"%s\" / \"%s\" (V-FIN-PLATE)",
                        s.pnum, l1, tostring(l2))
                end
            end
        else
            pcall(hide, i)
        end
    end
end

function M.init()
    St.on("leaving", TAG, function() U.try(TAG, closeAll, "leaving") end)
end

return M
