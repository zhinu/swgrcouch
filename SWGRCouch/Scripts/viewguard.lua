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
local FAILED_CAMS = { "PlayerFailedCam", "FailedCam", "CineCamera", "Podium", "PostRaceCam", "ResultsCam" }

local function enabled() return cfg.ViewGuard ~= false end

local function className(o)
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and s or ""
end

local function isFailedCam(vt)
    local n = className(vt)
    for _, k in ipairs(FAILED_CAMS) do if n:find(k, 1, true) then return true end end
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
    local okR, r = pcall(function() return rec:IsStillRacing() end)
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
    local car
    pcall(function() local p = e.pc.Pawn; if U.ok(p) and U.isVehicle(p) then car = p end end)
    if not car then return end
    if RA.step == 0 then
        if now - RA.at < 1000 then return end
        local vt
        pcall(function() vt = e.pc:GetViewTarget() end)
        if not (U.ok(vt) and U.key(vt) == U.key(car)) then return end    -- intro / crash camera: wait
        pcall(function() e.pc:SetViewTargetWithBlend(e.pc, 0.0, 0, 0.0, false) end)
        RA.step, RA.at = 1, now
    elseif now - RA.at >= 30 then
        local ok = pcall(function() e.pc:SetViewTargetWithBlend(car, 0.0, 0, 0.0, false) end)
        RA.step = 2
        U.log(TAG, "P1 chase camera re-armed (view -> its controller -> its car): %s (V-VG-REARM)", ok and "ok" or "failed")
    end
end

function M.fastTick()
    if not enabled() then return end
    local lps = U.localPlayers()
    if #lps < 2 then return end
    pcall(rearmP1, lps, St.nowMs())
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
            local car
            pcall(function() local p = pc.Pawn; if U.ok(p) and U.isVehicle(p) then car = p end end)
            if car then
                local vt
                pcall(function() vt = pc:GetViewTarget() end)
                if U.ok(vt) and isFailedCam(vt) and stillRacing(pc, car) then
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
    for _, e in ipairs(U.localPlayers()) do
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
