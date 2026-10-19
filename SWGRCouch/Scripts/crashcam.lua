-- crashcam.lua (G5, 0.5.1, 2026-10-07): a local human's CRASH (tumble + reset, health 3 -> 2 -> 1, no wreck) in a
-- split race. User report (run F, f-11.png: P2 at 1/3 HP): "P2's view goes black when P2's pod crashes; P1's crash
-- shows the crash camera with slow-mo". wreck.lua only handles full wrecks (bHasVehicleWrecked); this module owns the
-- crash window of every local human that is NOT wrecked, and hands over to wreck.lua the moment a wreck shows.
--
-- Static research (exe, nothing executed; addresses in SWGR-Win64-Shipping.exe, .text only, never .edata):
--   * UVehicleCrashCamComponent::OnCrashTagChanged impl 0x140f4b256 (wreck-angle2.md §3.1) on Vehicle.Crash.Tumble
--     added: config = GetNetMode == Standalone ? CrashCameraConfig_SP : _MP (0x140f4b424..0x140f4b442; pods use
--     DA_Plane_CrashCamConfig_SP: CrashingInfo CDT_Plane_CrashCameras MinDuration 3.0, WreckingInfo
--     CDT_Plane_WreckCameras FinalCutBuffer 1.5); CrashCam spawned ONCE per car (0x140f4b530 SpawnActor with NO
--     location/rotation: the BP_CrashCameraActor_C sits at the world origin, Owner = the car) and reused for every
--     later crash; 0x144a79a42 sets the data table, 0x144a79aba STARTS it: InitialCameraMode (+0xe90) = the shot picked
--     by vfunc +0x6d8 (scoring + InitialValidationRules: LookAtActor in view, distance, overlap, crash tags, speed...),
--     NULL when no row validates; the blend time is read from it (0 when null); then the car's OWN controller gets
--     SetViewTargetWithBlend(CrashCam) (vtable +0xd78, 0x140f4b6b3). On Tumble removed the view blends back to the car
--     only if it is still the CrashCam. Nothing in that path selects player 0.
--   * Slow-mo comes only from an EVALUATED crash camera mode (CrashCameraComponent::ApplySlowMo 0x1406035fe, from the
--     camera update; Standalone, cvar CrashCamera.SlowMoEnabled, bSlowMoAllowed = !PC+0x860 which only P1's PC ever
--     sets). Pods: CVF_Slowmo_Crash_Plane = 1.0 -> 0.2 at 0.2 s, held to 1.2 s, 0.7 at 2.2 s.
--   => A guest's crash with a black view AND no slow-mo means its crash camera was never evaluated with a shot: the
--      PlayerCameraManager renders the camera actor itself (world origin, under the terrain = black). Leading
--      hypothesis (H-CC1): no InitialValidationRules row validates for the second view (TargetInView-type rules use
--      viewport/projection data of the first view); H-CC2: a camera fade on the guest's manager; H-CC3: NaN POV.
--      The probes below name it (V-CC-01).
--   * The car reset after a crash (UVehicleResetComponent Multi_ResetAtLocation) may fade the camera; the fade guard
--     clears a fade held on a guest view (FadeAmount @0x2EC, wreck.lua's custom properties, V-WD-15).
--
-- What this module does (poll only, FAST tick; native UFunction calls and property reads; NO soft pointers, NO hooks):
--   1. DETECT a local human's crash: its view target becomes its car's VehicleCrashCamComponent.CrashCam (compared by
--      address), or VehicleState.CrashTimeRemaining > 0, or its RaceEventComponent.VehicleHealth drops.
--   2. GUEST VIEW (cfg.CrashCamGuest): "car" (default since 0.6.0, run G) puts a guest's view on its OWN CAR at once;
--      "auto" keeps the game's crash camera while it is usable and puts the
--      view on the player's OWN CAR (its chase camera, the camera a guest renders while driving) when it is not: no
--      InitialCameraMode (no shot), camera NaN / at the origin / farther than CrashCamMaxDistUU from the car, or fully
--      faded; unusable for CrashCamBadMs -> car. A player whose crash camera proved unusable once goes to its car at
--      once on later crashes (cfg.CrashCamLearn). "car": guests never keep the crash camera. "keep": probes only.
--      "off": module off. cfg.CrashCamPlayers "guests" (default) | "all" (P1 too). A crash camera left as the view
--      after the crash is put back on the car ("stuck").
--   3. FADES: a fade >= 0.5 held CrashCamFadeClearMs on a guarded view (crash + CrashCamAfterMs) -> StopCameraFade.
--   4. SLOW-MO (cfg.WreckSlowMo semantics, world-wide, see wreck.lua): "game": when the guest's crash camera was
--      replaced (no game slow-mo possible) the pod crash curve is EMULATED on CinematicTimeDilation (real time,
--      cfg.CrashSlowMoEmulate, cfg.CrashSlowMoCurve); "last": only when the crashing human is the only one racing;
--      "off": never (wreck.lua sets CrashCamera.SlowMoEnabled 0 while split). Never while another slow-mo runs (the
--      game's, wreck.lua's emulation), never in photo mode; another writer stops it; real time is always put back.
--   5. PROBES at the crash edge, +0.5 s, +2 s and the crash end (P1 too: the working reference): view target, camera
--      location + distance to the car, InitialCameraMode, active stack, crash-cam actor/component location, fade,
--      dilation, VehicleState crash timers, health.
-- Live run G (2026-10-07, 0.6.0, F4a), UE4SS-123943.log:
--   * CrashCamGuest "auto", P2 crash 10:34:07: the game's crash camera WAS the view with a valid shot
--     (initMode CMD_Plane_HardStop_Tracking_Static_Left_High, stack Default, camera 3405 uu from the car, fade 0,
--     slow-mo seen, dilation 0.03) and P2's half rendered BLACK for the whole crash. Every check of "auto" passed (it
--     even logged "crash camera proved usable"): the black is not a missing shot (H-CC1 disproven for that shot), not
--     a fade (H-CC2) and not a NaN POV (H-CC3); the cause is still open (the camera actor is rendered for P2's view
--     but its image is black: e.g. a per-view post-process/exposure or a scene-capture path of the cinematic camera
--     component that only the first view gets).
--   * CrashCamGuest "car", P2 crashes 10:36:17 / 10:37:12: "crash camera -> own car view after 0 ms", P2's half
--     followed its own pod through the tumble (no black) with the EMULATED slow-mo (CrashSlowMoEmulate, both halves).
--   => CrashCamGuest defaults to "car" (module fallback and config.lua). "auto" stays for tests; its "kept to the
--      end" lines no longer claim the camera rendered. wreck.lua's wreck-camera hold is skipped for guests in "car"
--      (crashCamBad -> true): a guest's wreck goes straight to its wreck view (WreckView, chasecam.lua).
-- Exports: M.fastTick(), M.tick(), M.clear(why), M.init(), M.dump(), M.crashCamBad(pc) -> bad, why (wreck.lua: skip
-- the wreck-camera hold for a player whose crash camera is unusable), M.viewInfo(pc) -> nil | {pnum, phase, why}.
-- VERIFY ids V-CC-01..06 (see the functions).

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
-- couch-racegc: constant option lists (a literal in the call built a new table every call)
local OPTS_CrashCamGuest = { "auto", "car", "keep", "off" }
local OPTS_CrashCamPlayers = { "guests", "all" }
local OPTS_WreckSlowMo = { "off", "last", "game" }
local OPTS_CrashCamWreckHold = { "proven", "never", "always" }

local M = {}
local TAG = "crashcam"

local PROBE_AT_MS = { 500, 2000 }        -- after the edge probe (V-CC-01)
local MIN_CRASH_MS = 800                 -- a crash record lives at least this long
local END_QUIET_MS = 600                 -- no crash signal this long -> crash over
local MAX_CRASH_MS = 15000
local REAPPLY_MIN_MS = 250
local REAPPLY_MAX = 6
local FADE_AMT, FADE_FLAGS = "SWGRCouchFadeAmount", "SWGRCouchFadeFlags"   -- same names/offsets as wreck.lua
-- CVF_Slowmo_Crash_Plane (decoded), ms of real time -> CinematicTimeDilation; the tail eases back to 1.0
local DEFAULT_CURVE = { { 0, 1.0 }, { 200, 0.2 }, { 1200, 0.2 }, { 2200, 0.7 }, { 2500, 1.0 } }

---------------------------------------------------------------------------------------------------- options
local function opt(v, allowed, default)
    for _, a in ipairs(allowed) do if v == a then return v end end
    return default
end
local function num(v, d)
    local n = tonumber(v)
    if n == nil then return d end
    return n
end
-- 0.6.0 (run G, F4a): the default is "car" (see the header: a guest crash camera can render BLACK while every
-- check passes, so "auto" cannot tell a black one from a working one).
local function guestMode() return opt(cfg.CrashCamGuest, OPTS_CrashCamGuest, "auto") end
local function playersMode() return opt(cfg.CrashCamPlayers, OPTS_CrashCamPlayers, "guests") end
local function slowMoMode() return opt(cfg.WreckSlowMo, OPTS_WreckSlowMo, "game") end

---------------------------------------------------------------------------------------------------- state
-- St.crashcam per world; learned[pnum] (crash camera proved unusable) and the fade registration survive worlds.
local fadeReg = { tried = false, ok = false, bad = false }
local learned = {}
-- proven[pnum]: a crash of that player ended with the game's crash camera as a usable view the whole time (integration
-- 0.5.1). cfg.CrashCamWreckHold "proven" (default): wreck.lua keeps a guest's wreck-camera hold only for such a player.
local proven = {}
-- InitialCameraMode has been read as a VALID object at least once (any crash camera, e.g. P1's): only then does a null
-- read mean "no shot" (UE4SS also returns an invalid object when a property lookup itself fails).
local modeReadOk = false

local function S()
    local s = St.crashcam
    if type(s) ~= "table" or s.gen ~= St.worldGen then
        s = { gen = St.worldGen, p = {}, comp = {}, emu = nil, crashes = 0, switches = 0, fadeClears = 0, emus = 0 }
        St.crashcam = s
    end
    return s
end

---------------------------------------------------------------------------------------------------- helpers
local function lazy(name)
    local ok, m = pcall(U.mod, name)
    if ok and type(m) == "table" then return m end
    return nil
end

local function field(o, name)
    if o == nil then return nil end
    local ok, v = pcall(U.getField, o, name)
    if ok then return v end
    return nil
end

local function call0(o, fn)
    if o == nil then return nil end
    local ok, v = pcall(U.callMethod, o, fn)
    if ok then return v end
    return nil
end

local function clsName(o)
    if not U.ok(o) then return "nil" end
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and tostring(s) or "?"
end

local function objName(o)
    if not U.ok(o) then return "nil" end
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and tostring(s) or "?"
end

local function vec3(v)
    if v == nil then return nil end
    local x, y, z
    pcall(function() x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z) end)
    if x and y and z then return x, y, z end
    return nil
end

local function locS(x, y, z)
    if not x then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

local function photoMode()
    local ph = lazy("phase")
    if ph and ph.photoMode then                                   -- the shared detector (cached in phase.lua)
        local ok, v = pcall(ph.photoMode)
        return ok and v == true
    end
    local wr = lazy("wreck")
    if wr and wr.photoMode then
        local ok, v = pcall(wr.photoMode)
        if ok and v == true then return true end
    end
    return false
end

-- couch-fix40: U.worldSettings (kept per world, U.ok-checked; the chain read was 2 wrappers + a closure per FAST tick)
local function worldSettings() return U.worldSettings() end

local function dilation()
    local ws = worldSettings()
    return ws and tonumber(field(ws, "CinematicTimeDilation")) or nil, ws
end

-- Local humans with a racer entry: wreck.lua's list ({pc, pnum, ps, rec, key, racing, wrecked}), else our own.
local function localRacers()
    local wr = lazy("wreck")
    if wr and wr._localRacers then
        local ok, lrs = pcall(wr._localRacers)
        if ok and type(lrs) == "table" then return lrs end
    end
    local out = {}
    for _, lp in ipairs(U.localPlayersRO()) do
        if U.ok(lp.pc) then
            local ps = field(lp.pc, "PlayerState")
            local rec = U.ok(ps) and field(ps, "RaceEventComponent") or nil
            if U.ok(rec) then
                out[#out + 1] = { pc = lp.pc, pnum = lp.index, ps = ps, rec = rec, key = U.key(lp.pc),
                                  racing = call0(rec, "IsStillRacing") == true,
                                  wrecked = field(rec, "bHasVehicleWrecked") == true }
            end
        end
    end
    return out
end

-- The player's car: its racer PlayerState's pawn, else the PC's pawn; a VehiclePawn only (photo mode pawn: nil).
-- couch-fix40: K2_GetPawn only when PawnPrivate is no vehicle (same order and result; the candidate table and the
-- second call were made every FAST tick per player)
local function vehEntry(s, p)
    if not U.ok(p) then return nil end
    local k = U.key(p)
    local v = s.comp[k]
    if v == nil then
        v = { veh = U.isVehicle(p) }
        s.comp[k] = v
    end
    if v.veh then return v end
    return nil
end
local K2_GETPAWN = "/Script/Engine.Controller:K2_GetPawn"
local function carOf(s, e)
    local p = field(e.ps, "PawnPrivate")
    if p == nil then return nil, nil end              -- (the old candidate list stopped at a nil first entry too)
    local v = vehEntry(s, p)
    if v then return p, v end
    local ok, p2 = U.pcallFn(e.pc, K2_GETPAWN, "K2_GetPawn")
    v = ok and vehEntry(s, p2) or nil
    if v then return p2, v end
    return nil, nil
end

-- The car's crash camera actor (VehicleCrashCamComponent.CrashCam @0x108; spawned at the first crash, then reused).
local CAM_REREAD_MS, CAM_NONE_MS = 1000, 250
local function crashCamOf(car, cache, vtKey, carKey, force)
    if not cache.cc or not U.ok(cache.cc) then
        local now = St.nowMs()
        if now < (cache.ccRetryAt or 0) then return nil end          -- no component: looked up again every 2 s
        cache.ccRetryAt = now + 2000
        local cls = U.class("/Script/Griffin.VehicleCrashCamComponent")
        if not U.ok(cls) then return nil end
        local ok, comp = pcall(U.callMethod, car, "GetComponentByClass", cls)
        if not ok or not U.ok(comp) then return nil end
        cache.cc = comp
    end
    -- couch-fix40: the camera actor is kept per car once seen (U.ok-checked at every use) and read again when the
    -- view target is neither the car nor that actor (a new crash camera), else every CAM_REREAD_MS; while the car has
    -- none yet (before its first crash) it is read every FAST tick while the view is not on the car, else every
    -- CAM_NONE_MS (nothing uses it then: the view is the car)
    local now = St.nowMs()
    local cam = cache.cam
    local camOk = cam ~= nil and U.ok(cam)
    local vk = vtKey or 0
    local fresh = (vk ~= 0 and vk ~= (carKey or 0) and (not camOk or vk ~= cache.camKey))
        or now >= (cache.camReadAt or 0) or force == true
    if fresh then
        cam = field(cache.cc, "CrashCam")
        camOk = U.ok(cam)
        cache.cam, cache.camKey = camOk and cam or nil, camOk and U.key(cam) or 0
        cache.camReadAt = now + (camOk and CAM_REREAD_MS or CAM_NONE_MS)
    end
    if camOk then return cam end
    return nil
end

-- 0.7.2 (run J, research guest-camera-black.md): the game's DefaultEngine.ini turns on a post-process letterbox for
-- camera actors (r.CinematicCamera.ConstrainAspectRatioUsingPostProcess); BP_CrashCameraActor serialises the same flag.
-- Its 16:9 mask is placed in absolute screen pixels, so a GUEST's (second) view lay outside it and the game's crash
-- camera rendered BLACK (runs E/G). Cleared once per crash camera actor (the native setter removes the blendable); the
-- guest can then keep the game's crash camera (with the game's own slow-mo) instead of CrashCamGuest "car".
local camComps = {}                     -- [camera actor key] = { components } (the actor is reused for every crash)
local fixLogged = {}                    -- [camera actor key] = number of re-applications logged
-- Run J: the flag is RE-APPLIED at every crash (the crash camera re-reads its mode data), so this runs on every FAST
-- tick while a guest looks through its crash camera; it only writes when the flag is back on (cheap read otherwise).
local function fixLetterbox(cam, pnum)
    if not U.ok(cam) then return end
    local k = U.key(cam)
    local list = camComps[k]
    if not list then
        list = {}
        pcall(function()
            local arr = cam:K2_GetComponentsByClass(U.class("/Script/Engine.CameraComponent"))
            for _, c in ipairs(U.arrayToTable(arr)) do list[#list + 1] = c end
        end)
        camComps[k] = list
        U.log(TAG, "P%d crash camera %s: %d camera component(s) watched for the post-process letterbox (V-GCB-03)",
            pnum or 0, cam:GetClass():GetFName():ToString(), #list)
    end
    -- Run J: clearing the flag alone lost the race against the crash camera's per-frame refresh (black again 1 s into
    -- the crash); PostProcessBlendWeight = 0 survives it (the view then copies no camera post-process, letterbox
    -- included) and the game's crash shots render in the guest's half. The flag is still cleared as well.
    for _, comp in ipairs(list) do
        if U.ok(comp) then
            local okW, w = pcall(U.getField, comp, "PostProcessBlendWeight")
            if okW and type(w) == "number" and w > 0 then
                pcall(function() comp.PostProcessBlendWeight = 0.0 end)
                U.log(TAG, "P%d crash camera post-process weight %.2f -> 0 (%s): no letterbox in a guest view (V-GCB-03)",
                    pnum or 0, w, comp:GetFName():ToString())
            end
            local okR, on = U.pcallFn(comp, "/Script/Engine.CameraComponent:GetConstraintAspectRatioUsingPostProcess",
                "GetConstraintAspectRatioUsingPostProcess")      -- couch-fix40: kept UFunction wrapper
            if okR and on == true then
                pcall(function() comp:SetConstrainAspectRatioUsingPostProcess(false) end)
                fixLogged[k] = (fixLogged[k] or 0) + 1
                if fixLogged[k] <= 3 then
                    U.dbg(TAG, "P%d crash camera letterbox flag cleared (%s)", pnum or 0, comp:GetFName():ToString())
                end
            end
        end
    end
end

local function setView(pc, target, blend)
    return pcall(function() pc:SetViewTargetWithBlend(target, blend or 0.0, C.E.ViewBlend.Linear, 0.0, false) end)
end

-- Camera fade of a PlayerCameraManager: {enabled, amount} or nil. Same custom properties as wreck.lua (UE4SS keeps
-- one process-wide list: if wreck.lua registered them, the read works at once; else they are registered here, a
-- duplicate registration only adds an entry with the same offset). Untrusted when FadeAmount reads outside [0, 1].
local function fadeState(pcm)
    if fadeReg.bad or not U.ok(pcm) then return nil end
    local a, f = field(pcm, FADE_AMT), field(pcm, FADE_FLAGS)
    if type(a) ~= "number" and not fadeReg.tried and cfg.WreckFadeRead ~= false
        and type(RegisterCustomProperty) == "function" and type(PropertyTypes) == "table" then
        fadeReg.tried = true
        local cls = "/Script/Engine.PlayerCameraManager"
        local ok1 = pcall(RegisterCustomProperty, { Name = FADE_AMT, Type = PropertyTypes.FloatProperty,
            BelongsToClass = cls, OffsetInternal = { Property = "DefaultAspectRatio", RelativeOffset = 0x14 } })
        local ok2 = pcall(RegisterCustomProperty, { Name = FADE_FLAGS, Type = PropertyTypes.ByteProperty,
            BelongsToClass = cls, OffsetInternal = { Property = "bDefaultConstrainAspectRatio", RelativeOffset = 0 } })
        fadeReg.ok = ok1 and ok2
        U.log(TAG, "camera fade fields %s", fadeReg.ok and "registered" or "could not be registered (no fade guard)")
        a, f = field(pcm, FADE_AMT), field(pcm, FADE_FLAGS)
    end
    if type(a) ~= "number" or type(f) ~= "number" then return nil end
    if a ~= a or a < -0.01 or a > 1.01 then
        fadeReg.bad = true
        U.warn(TAG, "camera fade fields not trusted (FadeAmount reads %s): fade guard off (V-CC-04)", tostring(a))
        return nil
    end
    return { enabled = (math.floor(f) // 8) % 2 == 1, amount = a }
end

local tickP1Key = nil        -- P1's PC address, sampled once per FAST tick (U.p1 walks GameInstance.LocalPlayers)
-- Does this module act on that player's view (CrashCamPlayers)? Probes run for every local human.
local function applies(pc)
    return playersMode() == "all" or U.key(pc) ~= (tickP1Key or U.key(U.p1()))
end

local function dist3(ax, ay, az, bx, by, bz) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) end

---------------------------------------------------------------------------------------------------- probes
-- Crash camera internals: component, InitialCameraMode name ("NONE" = null: no shot validated), active stack name,
-- actor and component locations.
local function camInfo(cam)
    local im, stack, al, cl = "-", "-", "?", "?"
    if not U.ok(cam) then return im, stack, al, cl end
    al = locS(vec3(call0(cam, "K2_GetActorLocation")))
    local comp = field(cam, "CameraComponent")
    if U.ok(comp) then
        local m = field(comp, "InitialCameraMode")
        if U.ok(m) then modeReadOk = true end
        im = U.ok(m) and objName(m) or (m ~= nil and "NONE" or "?")
        local ok, n = pcall(U.callMethod, comp, "GetActiveStackName")
        stack = ok and U.str(n) or "?"
        cl = locS(vec3(call0(comp, "K2_GetComponentLocation")))
    end
    return im, stack, al, cl
end

-- VERIFY(V-CC-01): one line per crash at the edge, +0.5 s, +2 s, the switch and the end, for P1 (the working
-- reference) and the guests. A black guest view names its cause: initMode=NONE and cam=(~0,0,0) (H-CC1: no shot, the
-- camera actor at the origin), fade=on:1.00 (H-CC2), cam=(nan) (H-CC3). P1's line shows the working values.
local function probe(s, e, c, car, label)
    if cfg.CrashCamProbe == false then return end
    local vt = call0(e.pc, "GetViewTarget")
    local pcm = field(e.pc, "PlayerCameraManager")
    local x, y, z
    if U.ok(pcm) then x, y, z = vec3(call0(pcm, "GetCameraLocation")) end
    local dist = "?"
    if x and U.ok(car) then
        local cx, cy, cz = vec3(call0(car, "K2_GetActorLocation"))
        if cx then dist = string.format("%.0f", dist3(x, y, z, cx, cy, cz)) end
    end
    local vk = U.key(vt)
    local vdesc = clsName(vt) .. ((vk ~= 0 and vk == c.camKey) and "(own crash cam)" or
        ((U.ok(car) and vk == U.key(car)) and "(own car)" or ""))
    local im, stack, al, cl = camInfo(c.cam)
    local fs = fadeState(pcm)
    local vs = U.ok(car) and field(car, "VehicleState") or nil
    local function f(n)
        local v = U.ok(vs) and tonumber(field(vs, n)) or nil
        return v and string.format("%.2f", v) or "?"
    end
    local d = dilation()
    U.log(TAG, "probe P%d %s +%.1fs: phase=%s view=%s cam=(%s) dist=%s initMode=%s stack=%s camActor=(%s) "
        .. "camComp=(%s) fade=%s dilation=%s crash=%s/%s/%s hp=%s/%s slowSeen=%s emu=%s", e.pnum, label,
        (St.nowMs() - c.since) / 1000, c.phase, vdesc, locS(x, y, z), dist, im, stack, al, cl,
        fs and string.format("%s:%.2f", fs.enabled and "on" or "off", fs.amount) or (fadeReg.bad and "untrusted" or "n/a"),
        d and string.format("%.2f", d) or "?", f("CrashTimeRemaining"), f("CrashTimeElapsed"), f("CrashTimeDuration"),
        tostring(field(e.rec, "VehicleHealth")), tostring(field(e.rec, "StartingVehicleHealth")),
        tostring(c.slowSeen ~= nil), s.emu and string.format("P%d", s.emu.pnum) or "-")
end

---------------------------------------------------------------------------------------------------- 4. slow-mo
local function curve()
    local cv = cfg.CrashSlowMoCurve
    if type(cv) == "table" and #cv >= 2 then
        local good = true
        for i = 1, #cv do
            local p = cv[i]
            if type(p) ~= "table" or type(p[1]) ~= "number" or type(p[2]) ~= "number" or p[2] <= 0
                or (i > 1 and p[1] <= cv[i - 1][1]) then good = false end
        end
        if good then return cv end
        U.logOnce("crashcam.curve", TAG, "CrashSlowMoCurve is not {{ms, dilation}, ...} with rising ms: default curve")
    end
    return DEFAULT_CURVE
end

local function curveAt(cv, t)
    for i = 2, #cv do
        local a, b = cv[i - 1], cv[i]
        if t <= b[1] then return a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1]) end
    end
    return nil
end

local function emuStop(s, why, restore)
    local e = s.emu
    if not e then return end
    s.emu = nil
    if restore then
        local d, ws = dilation()
        if ws and type(d) == "number" and (e.last == nil or math.abs(d - e.last) < 1e-3) and d < 0.999 then
            pcall(function() ws.CinematicTimeDilation = 1.0 end)
        end
    end
    U.log(TAG, "emulated crash slow-mo %s (P%d, %d write(s), %.1f s)", why, e.pnum, e.steps, (St.nowMs() - e.start) / 1000)
end

-- Started when a guest's crash camera is replaced by its car (no evaluated crash camera = no game slow-mo).
-- VERIFY(V-CC-05): "crash slow-mo emulated" then "emulated crash slow-mo done"; both halves slow ~2 s; the +2 s probe
-- shows dilation < 1 and the end probe 1.00. Fallback: cfg.CrashSlowMoEmulate = false, or WreckSlowMo "off".
local function slowStart(s, e, c, lrs, now)
    local m = slowMoMode()
    if m == "off" or cfg.CrashSlowMoEmulate == false then return end
    if m == "last" then
        local n = 0
        for _, o in ipairs(lrs) do if o.racing then n = n + 1 end end
        if n > 1 then
            U.logEvery("crashcam.last", 10000, TAG, "P%d crash: no slow-mo (WreckSlowMo last, %d humans racing)", e.pnum, n)
            return
        end
    end
    if s.emu then return end
    local w = St.wreck
    if type(w) == "table" and w.emu then
        U.log(TAG, "P%d crash: no slow-mo emulation (wreck.lua's runs)", e.pnum)
        return
    end
    if photoMode() then return end
    if U.cvarInt("CrashCamera.SlowMoEnabled") == 0 then
        U.log(TAG, "P%d crash: no slow-mo (CrashCamera.SlowMoEnabled is 0)", e.pnum)
        return
    end
    local d, ws = dilation()
    if not ws or type(d) ~= "number" then return end
    if d < 0.999 then
        U.log(TAG, "P%d crash: another slow-mo runs (dilation %.2f): none emulated", e.pnum, d)
        return
    end
    s.emu = { start = now, pnum = e.pnum, steps = 0 }
    s.emus = s.emus + 1
    c.emulated = true
    U.log(TAG, "P%d crash: crash slow-mo emulated (WreckSlowMo %s; the replaced crash camera cannot run it) (V-CC-05)",
        e.pnum, m)
end

local function emuTick(s, now)
    local e = s.emu
    if photoMode() then emuStop(s, "stopped: photo mode", true); return end
    local cur, ws = dilation()
    if not ws or type(cur) ~= "number" then emuStop(s, "stopped: no WorldSettings", false); return end
    if e.last and math.abs(cur - e.last) > 1e-3 then
        emuStop(s, string.format("stopped: another writer (dilation %.2f, ours %.2f)", cur, e.last), false)
        return
    end
    local v = curveAt(curve(), now - e.start)
    if v == nil then emuStop(s, "done", true); return end
    pcall(function() ws.CinematicTimeDilation = v end)
    e.last, e.steps = v, e.steps + 1
end

---------------------------------------------------------------------------------------------------- 2. guest view
-- Is the crash camera view unusable? bad, why. Only asked while the view IS the own crash camera (or has no target).
-- VERIFY(V-CC-02): "crash camera -> own car view" on a guest crash whose probe shows initMode=NONE / cam at the origin
-- / far / faded; never on P1 with CrashCamPlayers "guests"; never when the guest's crash camera renders (slowSeen).
local function camBad(e, c, car, vt)
    if not U.ok(vt) then return true, "no view target" end
    if cfg.CrashCamModeCheck ~= false and not c.slowSeen and U.ok(c.cam) then
        local comp = field(c.cam, "CameraComponent")
        if U.ok(comp) then
            local m = field(comp, "InitialCameraMode")
            if U.ok(m) then
                modeReadOk = true
            elseif m ~= nil and modeReadOk then
                return true, "no initial camera mode (no crash shot validated)"
            end
        end
    end
    local pcm = field(e.pc, "PlayerCameraManager")
    local x, y, z
    if U.ok(pcm) then x, y, z = vec3(call0(pcm, "GetCameraLocation")) end
    if x then
        if x ~= x or y ~= y or z ~= z then return true, "NaN camera" end
        -- the crash camera actor is spawned at the origin (0x140f4b530, no transform): a camera that never left it
        if math.abs(x) + math.abs(y) + math.abs(z) < 50 then return true, "camera at the world origin" end
        local cx, cy, cz = vec3(call0(car, "K2_GetActorLocation"))
        local maxD = num(cfg.CrashCamMaxDistUU, num(cfg.WreckCamMaxDistUU, 15000))
        if cx and dist3(x, y, z, cx, cy, cz) > maxD then
            return true, string.format("camera %.0f uu from the car", dist3(x, y, z, cx, cy, cz))
        end
    end
    local fs = fadeState(pcm)
    if fs and fs.enabled and fs.amount >= 0.95 then return true, string.format("view faded %.2f", fs.amount) end
    return false, nil
end

local function switchToCar(s, e, c, car, why, lrs, now)
    local ok = setView(e.pc, car, 0.0)
    c.phase, c.why, c.switchedAt = "car", why, now
    s.switches = s.switches + 1
    U.log(TAG, "P%d crash camera -> own car view after %d ms (%s)%s (V-CC-02)", e.pnum, now - c.since, why,
        ok and "" or " (call failed)")
    probe(s, e, c, car, "switch")
    slowStart(s, e, c, lrs, now)
end

local function viewStep(s, e, c, car, vt, onCam, lrs, now)
    local gm = guestMode()
    if gm == "keep" then return end
    if c.phase == "game" then
        if not onCam and U.ok(vt) then c.badSince = nil; return end    -- its car again, a cinematic: not ours
        local why
        if gm == "car" then
            why = "CrashCamGuest car"
        elseif learned[e.pnum] and cfg.CrashCamLearn ~= false then
            why = "learned: " .. learned[e.pnum]
        elseif now - c.since >= num(cfg.CrashCamStuckMs, 9000) then
            why = string.format("crash camera still the view after %.0f s (stuck)", (now - c.since) / 1000)
        else
            local bad, w = camBad(e, c, car, vt)
            if not bad then c.badSince = nil; return end
            c.badSince = c.badSince or now
            if now - c.badSince < num(cfg.CrashCamBadMs, 150) then return end
            why = w
            if cfg.CrashCamLearn ~= false and not learned[e.pnum] then
                learned[e.pnum] = w
                U.log(TAG, "P%d: crash camera unusable (%s): later crashes go to the car at once (CrashCamLearn)", e.pnum, w)
            end
        end
        switchToCar(s, e, c, car, why, lrs, now)
    elseif onCam or not U.ok(vt) then
        -- the game set the crash camera again (a new Tumble tag) or the view was lost: back on the car, rate-limited
        if now - (c.switchedAt or 0) >= REAPPLY_MIN_MS and c.reapplies < REAPPLY_MAX then
            c.reapplies = c.reapplies + 1
            local ok = setView(e.pc, car, 0.0)
            c.switchedAt = now
            U.log(TAG, "P%d view was %s again: back on its car (%d/%d)%s", e.pnum, clsName(vt), c.reapplies, REAPPLY_MAX,
                ok and "" or " (call failed)")
        end
    end
end

-- 3. fades on a guarded view (crash + CrashCamAfterMs). VERIFY(V-CC-04): no "camera fade ... StopCameraFade" line in
-- a normal crash (the reset fade is short); a held one is cleared and the view comes back.
local function fadeGuard(s, e, pr, now)
    local clearMs = num(cfg.CrashCamFadeClearMs, 1500)
    if clearMs <= 0 then return end
    local pcm = field(e.pc, "PlayerCameraManager")
    if not U.ok(pcm) then return end
    local fs = fadeState(pcm)
    if not fs then
        local a = pr.after
        if a and not a.blind and cfg.CrashCamBlindFade ~= false and now - a.at >= clearMs then
            a.blind = true
            pcall(function() pcm:StopCameraFade() end)
            U.logEvery("crashcam.blind" .. tostring(e.pnum), 10000, TAG, "P%d blind StopCameraFade %d ms after the crash "
                .. "(fade fields unreadable)", e.pnum, clearMs)
        end
        return
    end
    if not (fs.enabled and fs.amount >= 0.5) then pr.fadeSince = nil; return end
    pr.fadeSince = pr.fadeSince or now
    if now - pr.fadeSince < clearMs then return end
    pcall(function() pcm:StopCameraFade() end)
    local after = fadeState(pcm)
    pr.fadeSince = nil
    s.fadeClears = s.fadeClears + 1
    U.logEvery("crashcam.fade" .. tostring(e.pnum), 2000, TAG, "P%d camera fade %.2f held %d+ ms around a crash: "
        .. "StopCameraFade -> %s (V-CC-04)", e.pnum, fs.amount, clearMs,
        after and string.format("%s:%.2f", after.enabled and "on" or "off", after.amount) or "?")
end

---------------------------------------------------------------------------------------------------- 1. crash edges
local function endCrash(s, e, pr, car, now, why)
    local c = pr.crash
    if not c then return end
    pr.crash = nil
    probe(s, e, c, car, "end")
    if c.phase == "game" and c.slowSeen and applies(e.pc) and guestMode() == "auto" then
        U.log(TAG, "P%d crash camera kept to the end, slow-mo seen (NOT proof it rendered: run G P2 was black with "
            .. "the same verdict; CrashCamGuest \"car\" is the default) (V-CC-01)", e.pnum)
    end
    -- integration 0.5.1: the crash camera was the view and stayed usable until the end -> this player's wreck camera
    -- may be held by wreck.lua (CrashCamWreckHold "proven")
    if c.phase == "game" and c.camSeen and why ~= "wrecked" and applies(e.pc) and guestMode() == "auto"
        and not proven[e.pnum] then
        proven[e.pnum] = true
        U.log(TAG, "P%d crash camera kept to the end (not proof it rendered, see run G): its wreck camera may be "
            .. "held (CrashCamWreckHold proven)", e.pnum)
    end
    pr.after = (why ~= "wrecked") and { at = now, untilMs = now + num(cfg.CrashCamAfterMs, 4000), blind = false } or nil
    U.log(TAG, "P%d crash over (%s, %.1f s, view %s%s)", e.pnum, why, (now - c.since) / 1000, c.phase,
        c.why and (": " .. c.why) or "")
end

local GET_VIEW_TARGET = "/Script/Engine.PlayerController:GetViewTarget"
local VS_REREAD_MS = 1000
-- FAST, per local human of a split race.
local function stepPlayer(s, e, lrs, now, dil)
    local pr = s.p[e.key]
    if not pr then pr = { pnum = e.pnum }; s.p[e.key] = pr end
    pr.pnum = e.pnum
    local hp = tonumber(field(e.rec, "VehicleHealth"))
    local hpWas = pr.hp
    local hpDrop = hp ~= nil and hpWas ~= nil and hp < hpWas
    if hp ~= nil then pr.hp = hp end
    local car, cache = carOf(s, e)
    if e.wrecked or not e.racing then
        -- VERIFY(V-CC-06): "crash over (wrecked ...)": wreck.lua owns a wrecked player's view from here
        if pr.crash then endCrash(s, e, pr, car, now, e.wrecked and "wrecked" or "not racing") end
        return
    end
    if not car then return end
    local okV, vt = U.pcallFn(e.pc, GET_VIEW_TARGET, "GetViewTarget")   -- couch-fix40: kept UFunction wrapper
    if not okV then vt = nil end
    local vtK = U.key(vt)
    local cam = crashCamOf(car, cache, vtK, U.key(car))
    if cam and e.pnum ~= 1 and cfg.CrashCamLetterboxFix ~= false then fixLetterbox(cam, e.pnum) end
    local camKey = U.key(cam)
    local onCam = camKey ~= 0 and vtK == camKey
    -- couch-fix40: the car's VehicleState object kept per car (U.ok-checked; read again when it is not valid, and every
    -- VS_REREAD_MS in case the car points at another one)
    local vs = cache.vs
    if vs == nil or not U.ok(vs) or now >= (cache.vsReadAt or 0) then
        vs = field(car, "VehicleState")
        cache.vs, cache.vsReadAt = U.ok(vs) and vs or nil, now + VS_REREAD_MS
    end
    -- the crash timer counts only while it CHANGES (a value left > 0 after a crash must not read as a crash forever)
    local rem = U.ok(vs) and tonumber(field(vs, "CrashTimeRemaining")) or nil
    local remWas = pr.rem
    pr.rem = rem
    local crashing = onCam or (rem ~= nil and rem > 0 and remWas ~= nil and math.abs(rem - remWas) > 1e-4)
    local c = pr.crash
    local act = applies(e.pc) and not photoMode()
    if not c then
        if pr.after and act then
            if now >= pr.after.untilMs then pr.after = nil else fadeGuard(s, e, pr, now) end
        end
        if not (crashing or hpDrop) then return end
        c = { since = now, cam = cam, camKey = camKey, phase = "game", probeIdx = 1, reapplies = 0,
              trigger = onCam and "crash camera is the view" or (hpDrop and string.format("health %s -> %s",
                  tostring(hpWas), tostring(hp)) or "VehicleState.CrashTimeRemaining") }
        pr.crash, pr.after = c, nil
        s.crashes = s.crashes + 1
        U.log(TAG, "P%d crash (%s; hp %s, %s)", e.pnum, c.trigger, tostring(hp),
            applies(e.pc) and ("CrashCamGuest " .. guestMode()) or "P1: game camera, probes only")
        probe(s, e, c, car, "crash")
    end
    if camKey ~= 0 and c.camKey ~= camKey then c.cam, c.camKey = cam, camKey end    -- spawned after a health edge
    if onCam and dil and dil < 0.999 and not s.emu and not c.slowSeen then c.slowSeen = now end
    if onCam then c.camSeen = true end
    local age = now - c.since
    while c.probeIdx <= #PROBE_AT_MS and age >= PROBE_AT_MS[c.probeIdx] do
        probe(s, e, c, car, "")
        c.probeIdx = c.probeIdx + 1
    end
    if act then
        viewStep(s, e, c, car, vt, onCam, lrs, now)
        fadeGuard(s, e, pr, now)
    end
    if crashing then c.quietSince = nil else c.quietSince = c.quietSince or now end
    if (c.quietSince and now - c.quietSince >= END_QUIET_MS and age >= MIN_CRASH_MS) or age >= MAX_CRASH_MS then
        endCrash(s, e, pr, car, now, age >= MAX_CRASH_MS and "timeout" or "crash over")
    end
end

---------------------------------------------------------------------------------------------------- loops
local restoredEmu = false    -- restoreShared: the previous Lua state was emulating a slow-mo

-- FAST loop (main.lua, race phases, right after wreck.fastTick).
function M.fastTick()
    local s = S()
    if St.phase ~= "RACING" or guestMode() == "off" then
        if s.emu then U.tryEvery("crashcam.emuStop", nil, TAG, emuStop, s, "stopped: race over / module off", true) end
        return
    end
    if restoredEmu then
        restoredEmu = false
        local d, ws = dilation()
        if ws and type(d) == "number" and d < 0.999 then
            pcall(function() ws.CinematicTimeDilation = 1.0 end)
            U.log(TAG, "hot reload during an emulated crash slow-mo: CinematicTimeDilation %.2f put back to 1.0", d)
        end
    end
    local lrs = localRacers()
    tickP1Key = U.key(U.p1())
    if #lrs >= 2 then
        local now = St.nowMs()
        local dil = dilation()
        for _, e in ipairs(lrs) do
            if U.ok(e.pc) then U.tryEvery("crashcam.step", nil, TAG, stepPlayer, s, e, lrs, now, dil) end
        end
    end
    if s.emu then U.tryEvery("crashcam.emu", nil, TAG, emuTick, s, St.nowMs()) end
end

function M.clear(why)
    local s = S()
    if s.emu then U.try(TAG, emuStop, s, "stopped: " .. tostring(why), true) end
    s.p, s.comp = {}, {}
end

---------------------------------------------------------------------------------------------------- exports
-- For wreck.lua (wiring): skip the wreck-camera hold for a player whose crash camera is unusable (the hold would put
-- the same black camera back for WreckCrashCamHoldMs). bad, why.
function M.crashCamBad(pc)
    if not U.ok(pc) or guestMode() == "off" or guestMode() == "keep" or not applies(pc) then return false, nil end
    if guestMode() == "car" then return true, "CrashCamGuest car" end
    local s = St.crashcam
    local pr = type(s) == "table" and type(s.p) == "table" and s.p[U.key(pc)] or nil
    if pr and pr.crash and pr.crash.phase == "car" then return true, pr.crash.why end
    if pr and learned[pr.pnum] and cfg.CrashCamLearn ~= false then return true, "learned: " .. learned[pr.pnum] end
    -- integration 0.5.1 (user, after run F: "the wrecked is still black screen"): a guest's crash camera is suspected
    -- unusable in the second view (H-CC1). "proven" (default): the wreck camera is held only for a guest whose crash
    -- camera was seen working in an earlier crash; "never": guests never get the hold; "always": only a known-bad one
    -- is skipped (the 0.5.0 behaviour + learned verdicts).
    local wh = opt(cfg.CrashCamWreckHold, OPTS_CrashCamWreckHold, "proven")
    if wh == "never" then return true, "CrashCamWreckHold never" end
    if wh == "proven" then
        local pnum = pr and pr.pnum or nil
        if not pnum then
            for _, lp in ipairs(U.localPlayersRO()) do
                if U.key(lp.pc) == U.key(pc) then pnum = lp.index end
            end
        end
        if not (pnum and proven[pnum]) then return true, "guest crash camera not proven usable yet (CrashCamWreckHold proven)" end
    end
    return false, nil
end

-- For hud.lua / present.lua: nil (no crash) | {pnum, phase = "game"|"car", why}.
function M.viewInfo(pc)
    local s = St.crashcam
    if type(s) ~= "table" or type(s.p) ~= "table" or not U.ok(pc) then return nil end
    local pr = s.p[U.key(pc)]
    if not pr or not pr.crash then return nil end
    return { pnum = pr.pnum, phase = pr.crash.phase, why = pr.crash.why }
end

-- diag.dump() section (F9). Read-only apart from the probe lines.
function M.dump()
    local s = S()
    local lr = {}
    for p, w in pairs(learned) do lr[#lr + 1] = string.format("P%d=%s", p, w) end
    for p in pairs(proven) do lr[#lr + 1] = string.format("P%d=proven", p) end
    U.log("diag", "crashcam: guest=%s players=%s learn=%s modeCheck=%s(readOk %s) badMs=%s maxDist=%s slowMo=%s emulate=%s "
        .. "crashes=%d switches=%d fadeClears=%d emus=%d emu=%s fadeFields=%s%s learned{%s}", guestMode(), playersMode(),
        tostring(cfg.CrashCamLearn ~= false), tostring(cfg.CrashCamModeCheck ~= false), tostring(modeReadOk), tostring(num(cfg.CrashCamBadMs, 150)),
        tostring(num(cfg.CrashCamMaxDistUU, num(cfg.WreckCamMaxDistUU, 15000))), slowMoMode(),
        tostring(cfg.CrashSlowMoEmulate ~= false), s.crashes, s.switches, s.fadeClears, s.emus,
        s.emu and string.format("P%d %.1fs", s.emu.pnum, (St.nowMs() - s.emu.start) / 1000) or "-",
        tostring(fadeReg.ok), fadeReg.bad and " untrusted" or "", table.concat(lr, ","))
    for _, e in ipairs(localRacers()) do
        local pr = s.p[e.key]
        local car, cache = carOf(s, e)
        local cam = car and crashCamOf(car, cache, nil, nil, true) or nil
        local c = pr and pr.crash or { since = St.nowMs(), cam = cam, camKey = U.key(cam), phase = "-" }
        probe(s, e, c, car, pr and pr.crash and "F9 (in crash)" or "F9")
    end
end

---------------------------------------------------------------------------------------------------- hot reload
function M.persistShared(put)
    put("crashcam.emu", S().emu and "1" or "")
    local parts = {}
    for p, w in pairs(learned) do parts[#parts + 1] = tostring(p) .. "=" .. tostring(w):gsub("[;=]", ",") end
    put("crashcam.learned", table.concat(parts, ";"))
    local pv = {}
    for p in pairs(proven) do pv[#pv + 1] = tostring(p) end
    put("crashcam.proven", table.concat(pv, ","))
end

function M.restoreShared(get)
    if get("crashcam.emu") == "1" then restoredEmu = true end
    local pv = get("crashcam.proven")
    if type(pv) == "string" then
        for p in pv:gmatch("%d+") do proven[tonumber(p)] = true end
    end
    local v = get("crashcam.learned")
    if type(v) ~= "string" or v == "" then return end
    for p, w in v:gmatch("(%d+)=([^;]+)") do learned[tonumber(p)] = w end
    U.log(TAG, "hot reload: learned crash-camera verdicts restored (%s)", v)
end

---------------------------------------------------------------------------------------------------- init
local inited = false
function M.init()
    if inited then return end
    inited = true
    St.on("leaving", TAG, function() M.clear("leaving") end)
    St.on("phase", TAG, function(new)
        if new == "FRONTEND" or new == "OTHER" then M.clear("front end") end
    end)
    U.log(TAG, "init: CrashCamGuest=%s (effective %s) CrashCamPlayers=%s learn=%s WreckSlowMo=%s emulate=%s",
        tostring(cfg.CrashCamGuest), guestMode(), playersMode(), tostring(cfg.CrashCamLearn ~= false),
        slowMoMode(), tostring(cfg.CrashSlowMoEmulate ~= false))
end

return M
