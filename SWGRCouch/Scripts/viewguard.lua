-- viewguard.lua: keeps every still-racing local player on their own car when the game's single-player race flow
-- points their view at a "player failed" cinematic camera that belongs to someone else's DNF.
-- Live run G (2026-10-07): P2 wrecked; P1 (still racing, parked) got BP_PlayerFailedCam_C as its view target and kept
-- it for minutes (the failed-race cinematic of the offline flow targets the first local player). Fix proven live:
-- P1 SetViewTargetWithBlend(own car, 0) restored the normal chase view at once.
-- Poll-based (FAST loop via main.lua, race phases only; Blueprint hooks never fire in this build). Native calls only;
-- no soft object pointer is read. Backs off while photo mode is open (every view is a photo camera then).
-- Config: cfg.ViewGuard = true|false (config.lua; a missing key = on).
-- VERIFY(V-VG-01): P2 wrecks while P1 races -> at most one "[viewguard] P1 is still racing but its view was
--   BP_PlayerFailedCam_C ..." line per 3 s, P1's half shows its own chase view within ~0.5 s; F9 prints
--   "viewguard: on fixes={P1=n}". Fallback: ViewGuard = false (the game's behaviour: P1 watches the DNF cinematic).

local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "viewguard"

local fixes = {}        -- pc key -> count this race
local lastFixMs = {}    -- pc key -> ms
local lastWhat = {}     -- pc key -> "P<n> <class> <ok|err>" of the last fix (diag)
local photoLogged = false

-- 0.13.0 (Jules, live: P2 finished first and P1, still racing, watched the podium cinematic): the finish / podium
-- cinematic cameras too (LevelSequence cine cameras, podium cams). The mod's own crash / wreck rigs are plain
-- CameraActors and never match.
-- 2026-10-13 (Jules: the race-start flythrough "reloads every second", "models appear twice"): the INTRO is a
-- CineCameraActor too, and the generic 0.13 names yanked the view back to the car twice per second through the
-- whole flythrough. The podium / finish cine cams this guard is for can only be seen AFTER the views have split
-- once (the intro runs on ONE view and splits at the ignition sequence, present.lua): the generic names arm only
-- from that first split on; the original wreck cams stay guarded always.
-- couch-finish (live 2026-10-17 #9 / #15, recording session-195105 at 142 s and 594 s): P2 crossed the line while P1
-- raced; ~2 s later P1's half showed P2's FINISH cinematic (a flyby, then the podium hologram; at 594 s a static low
-- camera on the finish straight) for 5 s while P1 drove on blind: P1 crashed (#9) / went OUT OF BOUNDS (#15). The
-- guard caught only the podium CineCameraActor at the end: the finish-line cameras of the game's single-player flow
-- (Camera/Cinematics/FinishLine: BP_PlayerFinishedCam, BP_PlayerFinishedCamEased, BP_PlayerTimedOutCam,
-- BP_PlayerFailedSplineCam) matched none of the names. They are only ever seen at a finish: guarded always.
local STRICT_CAMS = { "FailedCam", "FailedSplineCam", "FinishedCam", "TimedOutCam" }
local LATE_CAMS   = { "CineCamera", "Podium", "PostRaceCam", "ResultsCam" }

local function enabled() return cfg.ViewGuard ~= false end

local function className(o)
    if not U.ok(o) then return "" end   -- U.ok FIRST: GetClass on a null wrapper is a native AV (UE4SS.dll+0x2ace67 null+0x10) that pcall cannot catch
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and s or ""
end

local SPLIT = { world = -1, seen = false }
local function splitSeenNow()
    if SPLIT.world ~= St.worldGen then SPLIT.world, SPLIT.seen = St.worldGen, false end
    if not SPLIT.seen then
        local ok, pr = pcall(require, "present")
        if ok and type(pr) == "table" and type(pr.isSingleView) == "function" then
            local ok2, single = pcall(pr.isSingleView)
            if ok2 and single == false then SPLIT.seen = true end
        end
    end
    return SPLIT.seen
end

local function isFailedCam(vt)
    local n = className(vt)
    for _, k in ipairs(STRICT_CAMS) do if n:find(k, 1, true) then return true end end
    if splitSeenNow() then
        for _, k in ipairs(LATE_CAMS) do if n:find(k, 1, true) then return true end end
    end
    return false
end

local function photoOpen()
    local ok, ph = pcall(require, "phase")
    if not ok or type(ph) ~= "table" or type(ph.photoMode) ~= "function" then return false end
    local ok2, v = pcall(ph.photoMode)
    return ok2 and v == true
end

-- still racing = UPlayerRaceEventComponent:IsStillRacing() (native, as wreck.lua uses it); if that call is not
-- available, the flags: not finished / not wrecked / not eliminated.
local function stillRacing(pc, car)
    local ps
    pcall(function() ps = car.PlayerState end)
    if not U.ok(ps) then pcall(function() ps = pc.PlayerState end) end
    if not U.ok(ps) then return false end
    local rec
    pcall(function() rec = ps.RaceEventComponent end)
    if not U.ok(rec) then return false end
    local okR, r = pcall(U.callMethod, rec, "IsStillRacing")
    if okR and type(r) == "boolean" then return r end
    local fin, wr, el = false, false, false
    pcall(function() fin = rec.bHasFinishedEvent == true end)
    pcall(function() wr = rec.bHasVehicleWrecked == true end)
    pcall(function() el = rec.bHasBeenEliminated == true end)
    return not (fin or wr or el)
end

-- 0.13.0 (Jules 2026-10-12: "P1 has a mechanical camera before crashing for the first time"): in a split race P1's
-- chase camera stayed in its rest pose (live 20:41, 3 bots: P1 d=469 / FOV 85 at every speed, guests 360-707 /
-- 108-120). The game hands P1's view from the intro camera to the car without re-arming the camera modes; a crash
-- (crash camera, then back) re-arms it, and so does a REAL view-target change (setting the same car again is a no-op).
-- Once per race, ~1 s after the start, P1's view goes to its own controller and, the next frame, back to its car
-- (never to another human's car: two camera managers on one car froze that player's camera, live 20:43).
local RA = { world = -1, step = 0, at = 0 }
local function rearmP1(lps, now)
    if cfg.ViewRearmP1 == false or St.phase ~= "RACING" then return end
    if RA.world ~= St.worldGen then RA.world, RA.step, RA.at = St.worldGen, 0, now end
    if RA.step >= 2 then return end
    local e = lps[1]
    if not U.ok(e.pc) then return end
    local car = U.carOf(e.pc)
    if not car then return end
    if RA.step == 0 then
        if now - RA.at < 1000 then return end
        -- couch-fix33 (racegc): cached UFunction, no closure per FAST tick while it waits for the chase camera
        local okV, vt = U.pcallFn(e.pc, "/Script/Engine.Controller:GetViewTarget", "GetViewTarget")
        if not okV then vt = nil end
        if not (U.ok(vt) and U.key(vt) == U.key(car)) then return end    -- intro / crash camera: wait
        pcall(function() e.pc:SetViewTargetWithBlend(e.pc, 0.0, 0, 0.0, false) end)
        RA.step, RA.at = 1, now
    elseif now - RA.at >= 30 then
        local ok = pcall(function() e.pc:SetViewTargetWithBlend(car, 0.0, 0, 0.0, false) end)
        RA.step = 2
        U.log(TAG, "P1 chase camera re-armed (view -> its controller -> its car): %s (V-VG-REARM)", ok and "ok" or "failed")
    end
end

-- couch-finish: a GUEST's finish must not touch another local player's view (live 2026-10-17 #9 / #15 / #16).
-- The game's FinishRacer (wreck-angle1.md §2.1) plays the finisher's EventCompleteCinematicChain on HIS PC's
-- PlayerCinematicFlowComponent, but the chain's level sequence cuts the FIRST local player's camera (UE's camera cut
-- goes to GetFirstLocalPlayerController): P1, still racing, got the guest's finish cameras. At the source: a guest
-- who finishes while another local human still races has his chain ended (Client_EndCurrentCinematic, the call
-- wreck.lua makes for a wrecked guest's failed chain) as soon as it is current - before the cut (~2 s after the line
-- live) - and blind once 1 s after the finish; any newer chain of his inside GF_WINDOW_MS is ended too. P1's own
-- finish chain is never touched (it cuts P1's own view: native). The guest's own half keeps his car (live: his view
-- never showed the chain). Wrecks stay wreck.lua's. Per local PC: { chain0 = key while racing, at = sample ms,
-- fin = finish ms, ended = { [chain key] = true }, blind = bool }.
local GF = { world = -1, p = {}, lastOut = nil }
local GF_WINDOW_MS, GF_BLIND_MS, GF_SAMPLE_MS = 12000, 1000, 2000
local getF = U.getField

-- couch-racegc: the REC per PC is kept for the world (U.ok-checked at every use), the flag tables are reused and the
-- poll runs every GF_POLL_MS (the camera cut comes ~2 s after the line): racegc measured 1.9 KB / FAST call without.
local GF_POLL_MS = 100
local recCache, flagT = {}, {}
local function recFlags(e, i)
    local k = U.key(e.pc)
    local rec = recCache[k]
    if not (rec and U.ok(rec)) then
        rec = nil
        local okP, ps = pcall(getF, e.pc, "PlayerState")
        if okP and U.ok(ps) then
            local okR, r = pcall(getF, ps, "RaceEventComponent")
            if okR and U.ok(r) then rec = r end
        end
        recCache[k] = rec
    end
    if not rec then return nil end
    local f = flagT[i]
    if not f then f = {}; flagT[i] = f end
    local ok, v = pcall(getF, rec, "bHasFinishedEvent"); f.fin = ok and v == true
    ok, v = pcall(getF, rec, "bHasVehicleWrecked"); f.wrecked = ok and v == true
    ok, v = pcall(getF, rec, "bHasBeenEliminated"); f.elim = ok and v == true
    f.racing = not (f.fin or f.wrecked or f.elim)
    return f
end

local function chainOf(pc)
    local okF, flow = pcall(getF, pc, "PlayerCinematicFlowComponent")
    if not (okF and U.ok(flow)) then return nil, nil end
    local okC, ch = pcall(getF, flow, "CurrentCinematicChain")
    if okC and U.ok(ch) then return flow, ch end
    return flow, nil
end

local function endChain(e, g, flow, ch, why)
    local ok = pcall(function() flow:Client_EndCurrentCinematic("SWGRCouch", false) end)
    if ch then g.ended[U.key(ch)] = true end
    g.endedN = (g.endedN or 0) + 1
    U.log(TAG, "P%d finished while another local player races: its finish cinematic %s ended (%s; %s) (V-VG-FIN)",
        e.index, ch and className(ch) or "(none current)", why, ok and "ok" or "call failed")
end

-- FAST, RACING only. Returns the time of the last other-player finish / wreck (the foreign-camera window).
local flagsNow = {}
local function guestFinishTick(lps, now)
    if GF.world ~= St.worldGen then GF.world, GF.p, GF.lastOut, GF.at = St.worldGen, {}, nil, nil; recCache = {} end
    if GF.at and now - GF.at < GF_POLL_MS then return GF.lastOut end
    GF.at = now
    local flags, racing = flagsNow, 0
    for i = 1, #flags do flags[i] = nil end
    for i, e in ipairs(lps) do
        if U.ok(e.pc) then
            local f = recFlags(e, i)
            flags[i] = f
            if f and f.racing then racing = racing + 1 end
        end
    end
    for i, e in ipairs(lps) do
        local f = flags[i]
        if f then
            local k = U.key(e.pc)
            local g = GF.p[k]
            if not g then g = { ended = {} }; GF.p[k] = g end
            if f.racing then
                g.fin = nil
                if e.index >= 2 and (not g.at or now - g.at >= GF_SAMPLE_MS) then
                    local _, ch = chainOf(e.pc)
                    g.chain0, g.at = ch and U.key(ch) or 0, now
                end
            elseif not g.fin then
                g.fin, g.blind = now, false
                GF.lastOut = now
                if e.index >= 2 then
                    U.log(TAG, "P%d is out of the race (%s), %d local player(s) still racing: finish cinematic %s (V-VG-FIN)",
                        e.index, f.wrecked and "wrecked" or (f.elim and "eliminated" or "finished"), racing,
                        (racing > 0 and not f.wrecked and cfg.GuestFinishCinematic ~= "keep") and "watched" or "native")
                end
            end
            -- a guest's finish (wrecks: wreck.lua) while someone else still races
            if e.index >= 2 and g.fin and f.fin and not f.wrecked and racing > 0 and cfg.GuestFinishCinematic ~= "keep"
                and now - g.fin <= GF_WINDOW_MS then
                local flow, ch = chainOf(e.pc)
                if flow then
                    local ck = ch and U.key(ch) or 0
                    if ch and ck ~= g.chain0 and not g.ended[ck] then
                        endChain(e, g, flow, ch, string.format("%.0f ms after the line", now - g.fin))
                    elseif not g.blind and not g.endedN and now - g.fin >= GF_BLIND_MS then
                        g.blind = true
                        endChain(e, g, flow, nil, "blind, 1 s after the line")
                    end
                end
            end
        end
    end
    return GF.lastOut
end

-- couch-finish GRID PROBE (live 2026-10-17 #14 / #18, read-only): three couch-campaign races (L_Husky_Loop_A 17:51,
-- L_Husky_Loop_B 17:59 and 18:05) began with P1's car crashing at the GO (crash camera = P1's view on the first RACING
-- tick, hp 5 -> 4; 18:05: WrongWay for P1 before RACING). Recording: P1 (12/12) sat off the grid - his ignition shots on
-- open rocks, his countdown camera inside a hangar wall - while P2 (the guest, grid entry 12) was on POLE (01/12); at
-- the GO P1's car exploded on the rocks (L_Husky_P2P 17:45: the same hangar view, the car popped out airborne and
-- survived). The slot / spawn data decides the cause in the next live race: once in PRERACE (cars spawned) and once
-- at the GO, one line per racer: grid row / column of its REC.StartingGridInfo (+ the grid's max), its spawn point,
-- where its car really is, and the nearest other car.
local GP = { world = -1, done = {} }
local function v3(v)
    local x, y, z
    pcall(function() x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z) end)
    if x and y and z then return { x, y, z } end
    return nil
end
local function gridProbe(label)
    local gs = U.gs()
    if not U.ok(gs) then return false end
    local cars = {}
    pcall(function()
        local vs = gs.Vehicles
        for i = 1, U.arrayCount(vs) do
            local c = vs[i]
            if U.ok(c) then
                local loc = nil
                pcall(function() loc = v3(c:K2_GetActorLocation()) end)
                local ps = nil
                pcall(function() ps = c.PlayerState end)
                cars[#cars + 1] = { car = c, loc = loc, ps = U.ok(ps) and ps or nil }
            end
        end
    end)
    if #cars == 0 then return false end
    local humans = {}
    for _, e in ipairs(U.localPlayersRO()) do
        local ps = nil
        pcall(function() ps = e.pc.PlayerState end)
        if U.ok(ps) then humans[U.key(ps)] = e.index end
    end
    local parts = {}
    for _, c in ipairs(cars) do
        local name, g = "?", "-"
        if c.ps then
            pcall(function() name = c.ps:GetPlayerName():ToString() end)
            pcall(function()
                local s = c.ps.RaceEventComponent.StartingGridInfo
                local sp = v3(s.SpawnTransform.Translation)
                g = string.format("r%s/%s c%s/%s spawn=%s", tostring(s.StartingRow), tostring(s.MaxRows),
                    tostring(s.StartingCollumn), tostring(s.MaxCollumns),
                    sp and string.format("%.0f,%.0f,%.0f", sp[1], sp[2], sp[3]) or "?")
                if sp and c.loc then
                    g = g .. string.format(" off=%.0f", math.sqrt((sp[1] - c.loc[1]) ^ 2 + (sp[2] - c.loc[2]) ^ 2
                        + (sp[3] - c.loc[3]) ^ 2))
                end
            end)
        end
        local near = nil
        if c.loc then
            for _, o in ipairs(cars) do
                if o ~= c and o.loc then
                    local d = math.sqrt((o.loc[1] - c.loc[1]) ^ 2 + (o.loc[2] - c.loc[2]) ^ 2 + (o.loc[3] - c.loc[3]) ^ 2)
                    if not near or d < near then near = d end
                end
            end
        end
        local who = c.ps and humans[U.key(c.ps)] and ("P" .. humans[U.key(c.ps)]) or "AI"
        parts[#parts + 1] = string.format("%s %s [%s at=%s nearest=%s]", who, name, g,
            c.loc and string.format("%.0f,%.0f,%.0f", c.loc[1], c.loc[2], c.loc[3]) or "?",
            near and string.format("%.0f", near) or "?")
    end
    U.log(TAG, "grid probe (%s, %d car(s)): %s (V-VG-GRID)", label, #cars, table.concat(parts, " | "))
    return true
end
local function gridProbeTick()
    if cfg.ViewGuardGridProbe == false then return end
    if GP.world ~= St.worldGen then GP.world, GP.done = St.worldGen, {} end
    local label = (St.phase == "PRERACE") and "prerace" or (St.phase == "RACING" and "go" or nil)
    if not label or GP.done[label] then return end
    if label == "prerace" then
        -- once every local player has a car (the spawn is done)
        for _, e in ipairs(U.localPlayersRO()) do if U.ok(e.pc) and not U.carOf(e.pc) then return end end
    end
    if gridProbe(label) then GP.done[label] = true end
end

-- a camera actor on a still-racing player's view that is none of his own (his car, his controller, his crash camera)
local function foreignCam(vt, car, pc)
    if U.same(vt, car) or U.same(vt, pc) then return false end
    if U.isVehicle(vt) then return false end                      -- another car (wreck spectate is for the out ones)
    local n = className(vt)
    if n == "" or not n:find("Cam", 1, true) then return false end
    if n:find("Crash", 1, true) then return false end             -- the crash camera (crashcam.lua owns it)
    return true
end

function M.fastTick()
    if not enabled() then return end
    local lps = U.localPlayers()
    if #lps < 2 then return end
    pcall(rearmP1, lps, St.nowMs())
    pcall(gridProbeTick)
    local lastOut = nil
    if St.phase == "RACING" then
        local okG, lo = pcall(guestFinishTick, lps, St.nowMs())
        if okG then lastOut = lo end
    end
    local foreignMs = tonumber(cfg.ViewGuardForeignMs) or 30000
    if photoOpen() then
        if not photoLogged then photoLogged = true; U.log(TAG, "photo mode open: view guard paused") end
        return
    elseif photoLogged then
        photoLogged = false; U.log(TAG, "photo mode closed: view guard resumes")
    end
    local now = St.nowMs()
    for _, e in ipairs(lps) do
        local pc = e.pc
        if U.ok(pc) then
            local car = U.carOf(pc)                                -- couch-racegc: one pc.Pawn read per loop run
            if car then
                local okV, vt = U.pcallFn(pc, "/Script/Engine.Controller:GetViewTarget", "GetViewTarget")
                if not okV then vt = nil end
                local bad = U.ok(vt) and isFailedCam(vt)
                if not bad and U.ok(vt) and lastOut and foreignMs > 0 and now - lastOut <= foreignMs then
                    bad = foreignCam(vt, car, pc)
                end
                if bad and stillRacing(pc, car) then
                    local k = U.key(pc)
                    if now - (lastFixMs[k] or 0) > 500 then
                        lastFixMs[k] = now
                        local ok, err = pcall(function() pc:SetViewTargetWithBlend(car, 0.0, 0, 0.0, false) end)
                        fixes[k] = (fixes[k] or 0) + 1
                        lastWhat[k] = string.format("P%d %s %s", e.index, className(vt), ok and "ok" or tostring(err))
                        U.logEvery("viewguard.fix" .. k, 3000, TAG,
                            "P%d is still racing but its view was %s (another player's DNF cinematic): back to its own car (%s, x%d)",
                            e.index, className(vt), ok and "ok" or tostring(err), fixes[k])
                    end
                end
            end
        end
    end
end

function M.clear(why)
    local n = 0
    for _, c in pairs(fixes) do n = n + c end
    if n > 0 then U.log(TAG, "cleared (%s): %d view fix(es) this race", tostring(why or "?"), n) end
    fixes = {}; lastFixMs = {}; lastWhat = {}; photoLogged = false
end

-- F9 / diag line (diag.lua can call it like crashcam.dump). Read-only.
function M.dump()
    local parts = {}
    for _, e in ipairs(U.localPlayersRO()) do
        local k = U.ok(e.pc) and U.key(e.pc) or nil
        if k and fixes[k] then parts[#parts + 1] = string.format("P%d=%d (%s)", e.index, fixes[k], lastWhat[k] or "?") end
    end
    U.log("diag", "viewguard: %s fixes={%s}", enabled() and "on" or "off (ViewGuard=false)", table.concat(parts, ", "))
end

local inited = false
function M.init()
    if inited then return end
    inited = true
    St.on("leaving", TAG, function() M.clear("leaving") end)
    St.on("phase", TAG, function(new)
        if new == "FRONTEND" or new == "OTHER" or new == "LOADING" then M.clear(tostring(new)) end
    end)
    U.log(TAG, "init: ViewGuard=%s", tostring(enabled()))
end

return M
