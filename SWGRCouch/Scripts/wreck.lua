-- wreck.lua (G5 in-race rules and presentation, added 2026-10-07): wrecks and finishes in a couch race.
-- User report (0.4.0): "a wreck (top or bottom player) ends the race for everyone; P2's wreck view is black, no
-- slow-mo". Design: notes/research/wreck-design.md (+ wreck-angle1.md, wreck-angle2.md).
--
-- Cause [V, static]: in NM_Standalone the first HUMAN who finishes OR is wrecked runs FinishRacer (0x140fec472), which
-- arms RacingGameState.RaceTimeoutTime = now + 2.0 s (network: 30 s) and sets an unreflected GameMode byte
-- (RacingGameMode+0x4D0, "timeout armed"). ShouldEndRace (0x1402504be) ends the race for everyone once
-- `byte && now > RaceTimeoutTime` while a human still races (and at once when no human races any more).
--
-- What this module does (poll-based only: Blueprint hooks never fire; native UFunction calls + property writes):
--   1. TIMEOUT GUARD (FAST, Standalone only): while a human (non-bot racer) still races, an armed timeout is
--      disarmed (byte 0 first, then RaceTimeoutTime 0). cfg.FinishGraceSec: "all" = wait for every human (default);
--      N > 0 = after the first REAL human finish the others get N s (the game's own HUD countdown shows it, online
--      uses 30); 0 = the game's 2 s after a finish (wrecks are still disarmed). The last human out ends the race
--      natively. Fallback when the byte cannot be registered/verified: RaceTimeoutTime parked at 1e9 (never reached)
--      and hud.lua collapses the HUD's "Remaining" line (St.wreck.hideRemaining).
--   2. WRECKED HUMAN SPECTATES (cfg.WreckMode "spectate", default): the game's own spectate path
--      (OnHumanRacerOut -> SpectatorComponent; asked again with Server_RequestPostRaceSpectate if it did not start),
--      retargeted to the other local human still racing (cfg.WreckSpectateTarget); the single-player failed-event
--      cinematic is ended (cfg.WreckCinematic); a view guard checks the wrecked player's camera every FAST tick and,
--      if it is unusable (no view target, NaN/origin, far from its car), puts that view on another racer's car with
--      SetViewTargetWithBlend (cfg.WreckViewGuard / WreckViewFallback), so the view is never left black.
--   3. NO WRECKS (cfg.WreckMode "noWreck"): local humans never wreck: per-build UseHealth = false (cfg.NoWreckMethod
--      "build", verified with ShouldUseHealth()), or Race.InfiniteHealth 1 ("cvar": everybody, AI included), or a
--      health top-up just before a wrecking crash ("topup"; also the safety net of the other two).
--   4. SLOW MOTION (cfg.WreckSlowMo): crash-cam slow-mo is WORLD-wide (WorldSettings.CinematicTimeDilation, written by
--      CrashCameraComponent::ApplySlowMo 0x1406035fe, Standalone only), so it cannot be per view. "game" (default since
--      run E, the user wants it): both views slow down on any human wreck; when the game's own slow-mo does not run
--      within WreckSlowMoWaitMs of a wreck while another human races, it is EMULATED (cfg.WreckSlowMoEmulate) by
--      writing the dilation along a short curve. "off": CrashCamera.SlowMoEnabled 0 while the race runs split, and a
--      dilation left below 1 is put back to 1.0; "last": off while 2+ local humans race.
--   cfg.WreckMode "game": vanilla behaviour, this module only reports (F9).
--
-- Live run E (2026-10-07, UE4SS-E5/E6 logs), and what changed:
--   * P2's wreck view was black. The probes showed the game's spectate had replaced P2's crash cam at the Wrecked tag
--     (StartSpectatingBestRacer, blend 0: P2 never saw its wreck camera, and no crash-cam update meant no slow-mo even
--     with the cvar on) and a BP_SpectatorCameraActor_C (FuseCinematicCameraActor) fixed at P1's parked car. In SP the
--     last human out never gets this spectate (ShouldEndRace is already true), why P1's solo wreck looked fine.
--     Now (cfg.WreckView "car", default): the wreck camera (the pawn's VehicleCrashCamComponent.CrashCam) is put back
--     for WreckCrashCamHoldMs, then a guest's native spectate is ended (Client_OnSpectatorModeEnded: destroys the
--     spectator camera, view on the own pawn) and the view goes straight to a MOVING racing car with
--     SetViewTargetWithBlend (the car's own chase camera, the camera a guest already renders while driving). The
--     watched car is re-picked when it stops racing or stands still (WreckTargetStaticMs). "carAll" does the same
--     for P1; "native" keeps the game's spectate (+ the guard above).
--   * Camera fades are READ (FadeAmount / bEnableFading are not reflected; registered as custom properties from
--     SetManualCameraFade 0x1449f8286: FadeAmount @0x2EC, bEnableFading = bit 3 of the 0x33E8 bitfield) and a fade
--     held on a wrecked view longer than WreckFadeClearMs is cleared with StopCameraFade (blindly every 1 s when the
--     fields cannot be trusted). The probe lines print the fade state.
--   * Photo mode (PhotoModeManager.bPhotoModeActive, or a local PC possessing BP_PhotoModePawn_C): the view guard and
--     the slow-mo emulation back off completely, and resume 1.5 s after it closes (M.photoMode() for other modules).
-- Live run G (2026-10-07, 0.6.0, F3: g-w3-sheet.png / g-w-fix.png): "view -> Griff Halloran's car, AI" put P2's
--   camera INSIDE the AI pod beside its engine: a view target pawn is rendered through its one CameraComponent
--   (UVehicleCameraComponent, a camera-mode stack) and an AI car runs no stack. Now (cfg.WreckCarCam "auto", see
--   chasecam.lua): a local human's car is watched through its own live chase camera; any other car through its own
--   camera only while chasecam.placement() reads "chase" (checked 0.5 s after the switch, 4 samples; 2 bad =
--   w.badCam), else through a CHASE RIG (an engine CameraActor attached behind/above the watched car, re-used per
--   player, destroyed in M.clear). "rig" = always the rig, "car" = 0.5.1. g.view = the view actor (car or rig).
-- The race CSM states CSM_RF_Spectating / CSM_RF_LocalResults (P1 out, a guest still racing) are kept off the guest
-- views by hud.lua (manageSpectateWidget / manageLocalResults); present.lua keeps them split.
--
-- Reflected names used [V: object dump / JMAP, wreck-design.md §1]:
--   ARacingGameState.RaceTimeoutTime (Double @0x380), bIsRaceFinished (Bool), Racers (Array<GfnPlayerState>),
--     GetServerWorldTimeSeconds() -> Double
--   ARacingGameMode.mRaceState (@0x4C8); +0x4D0 = timeout-armed byte (UNREFLECTED, RegisterCustomProperty)
--   APlayerState.bIsABot, PawnPrivate; AGfnPlayerState.RaceEventComponent, RacerBuildState.VehicleBuilds[].UseHealth
--   UPlayerRaceEventComponent: IsStillRacing(), ShouldUseHealth(), ShouldNextCrashWreckVehicle(),
--     Server_ChangeVehicleHealthBy(Int), bHasVehicleWrecked, bHasFinishedEvent, EventFinishTime (-1 = DNF),
--     EventPosition, FailReasons, VehicleHealth, StartingVehicleHealth
--   AGfnPlayerController.SpectatorComponent (UPlayerSpectatorComponent: bIsSpectatorRunning, playerToSpectate,
--     SpectatorCam, Server_RequestPostRaceSpectate(), SelectPlayerToSpectate_OnClient(ps)),
--     PlayerCinematicFlowComponent (CurrentCinematicChain, Client_EndCurrentCinematic(Str, Bool))
--   APlayerController:GetViewTarget(), SetViewTargetWithBlend(Actor, Float, Enum, Float, Bool), PlayerCameraManager
--     (GetCameraLocation() -> Vector, StopCameraFade()); AWorldSettings.CinematicTimeDilation (Float @0x414)
--   cvars: CrashCamera.SlowMoEnabled (bool, 1), Race.InfiniteHealth (bool, 0); neither is cheat-flagged.

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "wreck"

local ARMED_PROP = "SWGRCouchTimeoutArmed"
local PARKED_T = 1.0e9                   -- fallback "never" for RaceTimeoutTime (seconds of world time)
local CV_SLOWMO = "CrashCamera.SlowMoEnabled"
local CV_INFHEALTH = "Race.InfiniteHealth"
local BUILD_TRIES = 20                   -- FAST ticks (~0.7 s) to see ShouldUseHealth() turn false after the write
local PROBE_AT_MS = { 500, 2000, 4500, 6000, 10000, 20000, 40000 }  -- probe lines after a wreck edge (V-WD-04)
local PHOTO_CACHE_MS = 150               -- photo-mode state cached this long (FAST loop)
local PHOTO_GRACE_MS = 1500              -- the view guard resumes this long after photo mode closed
local MOTION_SAMPLE_MS = 500             -- racing cars' positions sampled this often
local MOVE_MIN_UU = 150                  -- moved at least this much between two samples (~300 uu/s) = moving
local MOVING_RECENT_MS = 1500            -- "moving" = moved within this long
local REAPPLY_MAX = 12                   -- car view re-applied at most this often per wreck (something fights it)
local FADE_AMT, FADE_FLAGS = "SWGRCouchFadeAmount", "SWGRCouchFadeFlags"
-- emulated slow-mo: {ms since start, CinematicTimeDilation} (shape of CVF_Slowmo_Extreme, floor 0.1 not 0.05: the
-- FAST loop may run on game time, V-WD-09)
local EMU_CURVE = { { 0, 1.0 }, { 150, 0.1 }, { 700, 0.1 }, { 2000, 0.8 }, { 2400, 1.0 } }

-- Registration of the custom property is process-wide in UE4SS (static property list, kept across a hot reload; a
-- second registration only adds a duplicate entry with the same offset). Lua-state local: tried once per state.
local reg = { prop = nil, how = nil, err = nil, verified = false, sawZero = false }
local restoredEmu = false                -- restoreShared: the previous Lua state was emulating a slow-mo

---------------------------------------------------------------------------------------------------- state
local function newState()
    return { gen = -1, seen = {}, guard = {}, build = {}, graceSet = false, disarms = 0, lastDisarm = nil,
             lastDisarmWhy = nil, hideRemaining = false, topups = 0, dilationResets = 0, slowOff = false,
             infHealth = false, p1Out = false, standalone = nil, saved = {} }
end

-- St.wreck: per world (St.worldGen); the saved user cvar values (saved[name] = int) survive the reset until they are
-- given back ("leaving" / FRONTEND), and a hot reload (persistShared / restoreShared).
local function W()
    local w = St.wreck
    if type(w) ~= "table" then
        w = newState()
        St.wreck = w
    end
    if w.gen ~= St.worldGen then
        local saved = w.saved or {}
        w = newState()
        w.gen, w.saved = St.worldGen, saved
        St.wreck = w
    end
    return w
end

---------------------------------------------------------------------------------------------------- options
local function mode()
    local m = cfg.WreckMode
    if m == "spectate" or m == "noWreck" or m == "game" then return m end
    return "spectate"
end
M.mode = mode

-- nil = wait for every human ("all"); 0 = the game's own 2 s after a real finish; N > 0 = N s after it.
local function graceSec()
    local g = cfg.FinishGraceSec
    if type(g) == "number" and g >= 0 then return g end
    return nil
end

local function opt(v, allowed, default)
    for _, a in ipairs(allowed) do if v == a then return v end end
    return default
end

local function numCfg(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

-- Fallback defaults (config.lua may not list the run-E keys yet): view "car", slow-mo "game".
local function viewMode() return opt(cfg.WreckView, { "car", "carAll", "native" }, "car") end
local function slowMoMode() return opt(cfg.WreckSlowMo, { "off", "last", "game" }, "game") end
local function holdMs() return numCfg(cfg.WreckCrashCamHoldMs, 4000) end

---------------------------------------------------------------------------------------------------- helpers
local function lazy(name)
    local ok, m = pcall(U.mod, name)
    if ok and type(m) == "table" then return m end
    return nil
end

-- o[name], or nil on error (callers test objects with U.ok).
local function field(o, name)
    if o == nil then return nil end
    local ok, v = pcall(function() return o[name] end)
    if ok then return v end
    return nil
end

local function call0(o, fn)
    if o == nil then return nil end
    local ok, v = pcall(function() return o[fn](o) end)
    if ok then return v end
    return nil
end

local function clsName(o)
    if not U.ok(o) then return "nil" end
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and tostring(s) or "?"
end

local function racerPS(pc)
    local tko = lazy("takeover")
    if tko and tko.racerPSFor then
        local ok, ps = pcall(tko.racerPSFor, pc)
        if ok and U.ok(ps) then return ps end
    end
    local ok, ps = pcall(function() return pc.PlayerState end)
    if ok and U.ok(ps) then return ps end
    return nil
end

local function recOf(ps)
    if not U.ok(ps) then return nil end
    local ok, r = pcall(function() return ps.RaceEventComponent end)
    if ok and U.ok(r) then return r end
    return nil
end

local function stillRacing(rec) return rec ~= nil and call0(rec, "IsStillRacing") == true end
local function isBot(ps) return field(ps, "bIsABot") == true end

local function pawnOf(ps)
    if not U.ok(ps) then return nil end
    local p = field(ps, "PawnPrivate")
    if U.ok(p) then return p end
    p = call0(ps, "GetPawn")
    if U.ok(p) then return p end
    return nil
end

-- Every local player with a racer entry: {pc, pnum, ps, rec, key, racing, wrecked}.
local function localRacers()
    local out = {}
    local join = lazy("join")
    for _, lp in ipairs(U.localPlayers()) do
        if U.ok(lp.pc) then
            local ps = racerPS(lp.pc)
            local rec = recOf(ps)
            if rec then
                local pnum = lp.index
                if join and join.displayNumForPC then
                    local ok, n = pcall(join.displayNumForPC, lp.pc)
                    if ok and type(n) == "number" then pnum = n end
                end
                out[#out + 1] = { pc = lp.pc, pnum = pnum, ps = ps, rec = rec, key = U.key(lp.pc),
                                  racing = stillRacing(rec), wrecked = field(rec, "bHasVehicleWrecked") == true }
            end
        end
    end
    return out
end
M._localRacers = localRacers

local function eachRacer(gs, fn)
    local arr = field(gs, "Racers")
    local n = U.arrayCount(arr)
    for i = 1, n do
        local ok, ps = pcall(function() return arr[i] end)
        if ok and U.ok(ps) and fn(ps) == true then return end
    end
end

-- The filter of ShouldEndRace (0x1402504be): every Racers entry without bIsABot. Returns the number of humans still
-- racing and whether one REALLY finished (finished, not wrecked, EventFinishTime >= 0).
local function humanStatus(gs)
    local racing, realFinish = 0, false
    eachRacer(gs, function(ps)
        if isBot(ps) then return end
        local rec = recOf(ps)
        if not rec then return end
        if stillRacing(rec) then
            racing = racing + 1
        elseif field(rec, "bHasVehicleWrecked") ~= true and field(rec, "bHasFinishedEvent") == true then
            local t = field(rec, "EventFinishTime")
            if not (type(t) == "number" and t < 0) then realFinish = true end
        end
    end)
    return racing, realFinish
end

------------------------------------------------------------------------------------------------ view helpers (run E)
local function vec3(v)
    if v == nil then return nil end
    local x, y, z
    pcall(function() x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z) end)
    if x and y and z then return x, y, z end
    return nil
end

local function camLoc(pc)
    local pcm = field(pc, "PlayerCameraManager")
    if not U.ok(pcm) then return nil end
    return vec3(call0(pcm, "GetCameraLocation"))
end

local function setView(pc, target, blend)
    return pcall(function() pc:SetViewTargetWithBlend(target, blend or 0.0, C.E.ViewBlend.Linear, 0.0, false) end)
end

-- Photo mode: the PhotoMode plugin's world subsystem flag, else a local PC possessing a photo-mode pawn (run E: both
-- local PCs got a BP_PhotoModePawn_C). Returns active, why. Cached PHOTO_CACHE_MS. VERIFY(V-WD-17): "view guard
-- paused: photo mode" when the photo mode opens, "photo mode closed" when it closes, nothing touches the views between.
local photo = { at = -1e9, v = false, why = nil }
function M.photoMode()
    local now = St.nowMs()
    if now - photo.at < PHOTO_CACHE_MS then return photo.v, photo.why end
    photo.at = now
    local active, why = false, nil
    local pm = U.worldSubsystem("/Script/PhotoMode.PhotoModeManager")
    if U.ok(pm) and field(pm, "bPhotoModeActive") == true then
        active, why = true, "PhotoModeManager.bPhotoModeActive"
    end
    if not active then
        for _, lp in ipairs(U.localPlayers()) do
            local p = U.ok(lp.pc) and call0(lp.pc, "K2_GetPawn") or nil
            if U.ok(p) and clsName(p):find("PhotoMode", 1, true) then
                active, why = true, string.format("local player %d possesses %s", lp.index, clsName(p))
                break
            end
        end
    end
    photo.v, photo.why = active, why
    return active, why
end

-- Camera fade state of a PlayerCameraManager. FadeAmount and bEnableFading are not reflected; offsets from
-- APlayerCameraManager::SetManualCameraFade (0x1449f8286: `or [rcx+0x33e8], 8` = bEnableFading,
-- `movups [rcx+0x2dc]` = FadeColor, `movss [rcx+0x2ec], xmm1` = FadeAmount), registered relative to reflected
-- neighbours (DefaultAspectRatio @0x2D8 + 0x14; bDefaultConstrainAspectRatio @0x33E8, same byte). Trusted while
-- FadeAmount reads in [0, 1]; "verified" once a StopCameraFade is seen to clear the bit.
-- VERIFY(V-WD-15): probe lines show fade=off:<n> on a normal view; a black wrecked view shows fade=on:1.00 and then
-- "camera fade ... StopCameraFade" with fade=off afterwards. Fallback: blind StopCameraFade every 1 s.
local fadeReg = { tried = false, ok = false, bad = false, verified = false, err = nil }
local function registerFadeProps()
    if fadeReg.tried then return fadeReg.ok end
    fadeReg.tried = true
    if cfg.WreckFadeRead == false then
        fadeReg.err = "WreckFadeRead false"
        return false
    end
    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
        fadeReg.err = "RegisterCustomProperty / PropertyTypes not available"
        U.warn(TAG, "camera fade fields: %s; blind StopCameraFade only", fadeReg.err)
        return false
    end
    local cls = "/Script/Engine.PlayerCameraManager"
    local ok1, e1 = pcall(RegisterCustomProperty, { Name = FADE_AMT, Type = PropertyTypes.FloatProperty,
        BelongsToClass = cls, OffsetInternal = { Property = "DefaultAspectRatio", RelativeOffset = 0x14 } })
    local ok2, e2 = pcall(RegisterCustomProperty, { Name = FADE_FLAGS, Type = PropertyTypes.ByteProperty,
        BelongsToClass = cls, OffsetInternal = { Property = "bDefaultConstrainAspectRatio", RelativeOffset = 0 } })
    fadeReg.ok = ok1 and ok2
    if fadeReg.ok then
        U.log(TAG, "camera fade fields registered (FadeAmount = DefaultAspectRatio+0x14, flags byte = 0x33E8 bit 3)")
    else
        fadeReg.err = tostring(ok1 and e2 or e1)
        U.warn(TAG, "camera fade fields: RegisterCustomProperty failed (%s); blind StopCameraFade only", fadeReg.err)
    end
    return fadeReg.ok
end

-- {enabled, amount, flags} or nil (unreadable / untrusted).
local function fadeState(pcm)
    if fadeReg.bad or not U.ok(pcm) or not registerFadeProps() then return nil end
    local a, f = field(pcm, FADE_AMT), field(pcm, FADE_FLAGS)
    if type(a) ~= "number" or type(f) ~= "number" then return nil end
    if a ~= a or a < -0.01 or a > 1.01 then
        fadeReg.bad = true
        U.warn(TAG, "camera fade fields not trusted (FadeAmount reads %s): blind StopCameraFade (V-WD-15)", tostring(a))
        return nil
    end
    local fl = math.floor(f)
    return { enabled = (fl // 8) % 2 == 1, amount = a, flags = fl }
end

local function fadeText(pc)
    local fs = fadeState(field(pc, "PlayerCameraManager"))
    if fs then return string.format("%s:%.2f", fs.enabled and "on" or "off", fs.amount) end
    return fadeReg.bad and "untrusted" or "n/a"
end

-- Racing cars' motion (sampled in the FAST loop while 2+ local humans race): w.motion[pawnKey] = {x, y, z, movedAt}.
local function sampleMotion(w, now)
    if now - (w.motionAt or -1e9) < MOTION_SAMPLE_MS then return end
    w.motionAt = now
    w.motion = w.motion or {}
    eachRacer(U.gs(), function(ps)
        local p = pawnOf(ps)
        if not p then return end
        local x, y, z = vec3(call0(p, "K2_GetActorLocation"))
        if not x then return end
        local k = U.key(p)
        local m = w.motion[k]
        if not m then
            w.motion[k] = { x = x, y = y, z = z, movedAt = -1e9 }    -- unknown until the next sample
            return
        end
        if math.abs(x - m.x) + math.abs(y - m.y) + math.abs(z - m.z) >= MOVE_MIN_UU then m.movedAt = now end
        m.x, m.y, m.z = x, y, z
    end)
end

-- ms since this pawn last moved (nil = never sampled).
local function stillMs(w, pawn, now)
    local m = w.motion and U.ok(pawn) and w.motion[U.key(pawn)] or nil
    if not m then return nil end
    return now - m.movedAt
end

local function isMoving(w, pawn, now)
    local s = stillMs(w, pawn, now)
    return s ~= nil and s < MOVING_RECENT_MS
end

-- The wrecked pawn's crash camera actor (UVehicleCrashCamComponent.CrashCam @0x108), or nil.
local function crashCamOf(pawn)
    if not U.ok(pawn) then return nil end
    local cls = U.class("/Script/Griffin.VehicleCrashCamComponent")
    if not U.ok(cls) then return nil end
    local ok, comp = pcall(function() return pawn:GetComponentByClass(cls) end)
    if not ok or not U.ok(comp) then return nil end
    local cam = field(comp, "CrashCam")
    if U.ok(cam) then return cam end
    return nil
end

---------------------------------------------------------------------------------------------------- 1. timeout guard
-- RacingGameMode+0x4D0 (unreflected bool byte: set by FinishRacer 0x140fec58e, read by ShouldEndRace 0x140250540),
-- registered relative to the reflected mRaceState (@0x4C8, +8), else at the absolute offset. UE4SS 3f4037d2
-- (LuaMod.cpp RegisterCustomProperty) resolves BelongsToClass with StaticFindObject and matches subclasses
-- (LuaCustomProperty.cpp, TSuperStructRange), so it works on the BP game mode. Called on the game thread only.
-- The byte is TRUSTED only after it read 0 with no timeout armed (sightZero) and then 1 once the game armed the
-- timeout; otherwise nothing is ever written to it. VERIFY(V-WD-03): log "timeout byte verified"; else the parked-time fallback runs.
local function registerArmedProp()
    if reg.prop ~= nil then return reg.prop end
    if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
        reg.prop, reg.err = false, "RegisterCustomProperty / PropertyTypes not available"
        U.warn(TAG, "timeout byte: %s; parked-time fallback", reg.err)
        return false
    end
    local function try(offset)
        return pcall(RegisterCustomProperty, { Name = ARMED_PROP, Type = PropertyTypes.ByteProperty,
            BelongsToClass = "/Script/Griffin.RacingGameMode", OffsetInternal = offset })
    end
    local ok, err = try({ Property = "mRaceState", RelativeOffset = 8 })
    reg.how = "mRaceState+8"
    if not ok then
        U.warn(TAG, "timeout byte: relative registration failed (%s); trying the absolute offset 0x4D0", tostring(err))
        ok, err = try(0x4D0)
        reg.how = "absolute 0x4D0"
    end
    reg.prop, reg.err = ok, (not ok) and tostring(err) or nil
    if ok then
        U.log(TAG, "timeout byte registered as %s (%s), not trusted until it reads 1 on an armed timeout", ARMED_PROP,
            reg.how)
    else
        U.warn(TAG, "timeout byte: RegisterCustomProperty failed (%s); parked-time fallback", reg.err)
    end
    return ok
end

local function untrust(why)
    reg.prop, reg.verified, reg.err = false, false, why
    U.warn(TAG, "timeout byte not trusted (%s): parked-time fallback (V-WD-03)", why)
end

local function serverNow(gs)
    local v = call0(gs, "GetServerWorldTimeSeconds")
    if type(v) == "number" then return v end
    return nil
end

-- FAST tick (and MAIN as a backup), Standalone only (a hosted network race keeps the game's own network rules: no
-- timeout on a wreck, 30 s after a human finish).
-- VERIFY(V-WD-01/02): "race timeout disarmed (human wreck)" in the log one FAST tick after a wreck, and the race goes
-- on until the last human finishes or is wrecked (results: the wrecked player DNF).
-- Byte sanity, part 1 (review 2026-10-07): the byte must first read 0 while the race runs with no timeout armed, then
-- 1 once the game armed it; one read of 1 alone could be any byte at a wrong offset (a 0 written there + T = 0 would
-- end the race at once). One custom-property read per FAST tick, only until the 0 has been seen.
local function sightZero()
    if reg.sawZero or reg.prop == false then return end
    local w = W()
    if w.standalone == nil then w.standalone = (U.netMode() == "standalone") end
    if w.standalone ~= true then return end
    local gm = U.gm()
    if not (registerArmedProp() and U.ok(gm)) then return end
    if field(gm, ARMED_PROP) == 0 then
        reg.sawZero = true
        U.dbg(TAG, "timeout byte reads 0 with no timeout armed (check 1/2)")
    end
end

function M.guardTimeout()
    if mode() == "game" or St.phase ~= "RACING" then return end
    local gs = U.gs()
    if not U.ok(gs) then return end
    local T = field(gs, "RaceTimeoutTime")
    if type(T) ~= "number" or T <= 0 then                     -- not armed: the common case, one property read
        if type(T) == "number" and not reg.sawZero then sightZero() end
        return
    end
    local w = W()
    if w.standalone == nil then w.standalone = (U.netMode() == "standalone") end
    if w.standalone ~= true then return end
    if w.graceSet then return end                             -- a FinishGraceSec countdown runs: nothing more to do
    local grace = graceSec()
    local parked = T >= PARKED_T * 0.5
    if parked and grace == nil then                           -- parked for good ("all"); also after a hot reload
        w.hideRemaining = true
        return
    end
    if not parked and grace ~= nil and grace > 0 and w.disarms == 0 then
        -- hot reload during a countdown we set (St.wreck is new): the game's own arm is now + 2.0
        local now = serverNow(gs)
        if now and T - now > 2.5 then w.graceSet = true; return end
    end
    if field(gs, "bIsRaceFinished") == true then return end
    local racing, realFinish = humanStatus(gs)
    if racing == 0 then return end                            -- the last human is out: the game ends the race
    if realFinish and grace ~= nil then
        if grace == 0 and not parked then return end          -- 0: the game's own 2 s
        local now = serverNow(gs)
        if not now then return end
        -- the byte is 1 here: set by this finish (FinishRacer, human), or by the wreck that got the time parked (the
        -- game does not re-arm a time > 0, so a parked time gets the game's 2 s for 0): the native countdown runs
        local secs = (grace == 0) and 2.0 or grace
        w.hideRemaining = false
        gs.RaceTimeoutTime = now + secs
        w.graceSet = true
        U.log(TAG, "a human finished: the others get %g s (FinishGraceSec %g%s), %d still racing", secs, grace,
            parked and ", time was parked" or "", racing)
        return
    end
    if parked then return end                                 -- already parked (fallback)
    local gm = U.gm()
    local prop = registerArmedProp() and U.ok(gm)
    if prop and not reg.verified then
        local a = field(gm, ARMED_PROP)
        if a == 1 and reg.sawZero then
            reg.verified = true
            U.log(TAG, "timeout byte verified: %s read 0 unarmed, 1 on an armed timeout (%s)", ARMED_PROP, reg.how)
        elseif a == 1 then
            -- never seen 0 in this Lua state: not proof enough; park this time, the next race can verify
            U.logOnce("wreck.nozero", TAG, "timeout byte reads 1 but was never seen 0 unarmed: parked-time fallback")
            prop = false
        else
            untrust(string.format("reads %s while the game armed the timeout, expected 1", tostring(a)))
            prop = false
        end
    end
    local how
    if prop then
        -- ORDER: byte first, then the time. A time <= 0 with the byte still 1 would end the race at once
        -- (ShouldEndRace: now > RaceTimeoutTime).
        local okW = pcall(function() gm[ARMED_PROP] = 0 end)
        if okW and field(gm, ARMED_PROP) == 0 then
            gs.RaceTimeoutTime = 0.0
            how = "disarmed"
        else
            untrust("writing 0 did not stick")
        end
    end
    if not how then
        gs.RaceTimeoutTime = PARKED_T                         -- never reached; hud.lua hides the Remaining line
        w.hideRemaining = true
        how = "parked at 1e9"
    end
    w.disarms = w.disarms + 1
    w.lastDisarm, w.lastDisarmWhy = how, realFinish and "human finish" or "human wreck"
    U.log(TAG, "race timeout %s (%s; %d human(s) still racing; was T=%.2f)", how, w.lastDisarmWhy, racing, T)
end

---------------------------------------------------------------------------------------------------- cvars
-- Our value for a cvar; the user's value is saved once (restored on "leaving" / FRONTEND / mode change).
local function cvarSet(w, name, value, why)
    if w.saved[name] == nil then
        local cur = U.cvarInt(name)
        if cur == nil then
            U.logOnce("wreck.cvarread." .. name, TAG, "cannot read %s: not changed", name)
            return false
        end
        w.saved[name] = cur
    end
    if U.cvarInt(name) == value then return true end
    U.console(string.format("%s %d", name, value))
    local now = U.cvarInt(name)
    if now ~= value then
        U.logOnce("wreck.cvarset." .. name, TAG, "%s %d did not take (reads %s)", name, value, tostring(now))
        return false
    end
    U.log(TAG, "%s %d (%s; user value %s)", name, value, why, tostring(w.saved[name]))
    return true
end

local function cvarRestore(w, name, why)
    local v = w.saved[name]
    if v == nil then return end
    if U.cvarInt(name) ~= v then U.console(string.format("%s %d", name, v)) end
    local now = U.cvarInt(name)
    if now ~= v then
        -- kept saved: the next race must not save our value as the user's; retried on the next restore
        U.logEvery("wreck.cvarrestore." .. name, 10000, TAG, "%s back to %d did not take (reads %s; %s): retried later",
            name, v, tostring(now), why)
        return
    end
    w.saved[name] = nil
    U.log(TAG, "%s back to the user value %d (%s)", name, v, why)
end

function M.restoreCvars(why)
    local w = W()
    for _, name in ipairs({ CV_SLOWMO, CV_INFHEALTH }) do cvarRestore(w, name, why or "restore") end
    w.slowOff, w.infHealth = false, false
end

---------------------------------------------------------------------------------------------------- 4. slow motion
local function worldSettings()
    local ok, ws = pcall(function() return U.world().PersistentLevel.WorldSettings end)
    if ok and U.ok(ws) then return ws end
    return nil
end

local function dilation()
    local ws = worldSettings()
    return ws and field(ws, "CinematicTimeDilation") or nil, ws
end

-- FAST. VERIFY(V-WD-14): a wreck in a split race shows the crash camera without slowing the other view
-- (CinematicTimeDilation stays 1.0; "dilation reset" lines only if a slow-mo began before the cvar took).
-- "last": a wreck's crash cam is still running (ApplySlowMo reads the cvar every frame) for this long after the
-- wreck edge; the cvar stays 0 meanwhile, else the FIRST wreck would get the slow-mo the moment its player is out.
local SLOWMO_HOLD_MS = 3000

-- A dilation below 1 is put back only when it is STALE (same value as on the previous FAST tick: nothing writes it
-- any more, e.g. a slow-mo begun before the cvar took). A writer that keeps setting it (a level sequence's slow-mo
-- track, not covered by the cvar) is not fought: after 3 quick returns it is left alone for this world.
local function dilationReset(w, now)
    local d, ws = dilation()
    if type(d) ~= "number" or not ws then return end
    if M.photoMode() then return end                          -- photo mode owns the world's time (PrePhotoModeSlomo)
    local last = w.lastDil
    w.lastDil = d
    if d >= 0.999 or w.dilGaveUp then return end
    if now - (w.dilResetAt or -1e9) < 500 and last ~= nil and last >= 0.999 then
        w.dilReturns = (w.dilReturns or 0) + 1                -- back below 1 right after our reset: someone writes it
        if w.dilReturns >= 3 then
            w.dilGaveUp = true
            U.warn(TAG, "CinematicTimeDilation %.2f keeps coming back after a reset: another writer, left alone (V-WD-14)", d)
            return
        end
    end
    if last == nil or math.abs(last - d) > 1e-4 then return end   -- still changing: not stale yet
    pcall(function() ws.CinematicTimeDilation = 1.0 end)
    w.lastDil, w.dilResetAt = 1.0, now
    w.dilationResets = w.dilationResets + 1
    U.logEvery("wreck.dilation", 2000, TAG, "stale CinematicTimeDilation %.2f reset to 1.0 (split race, %d reset(s))",
        d, w.dilationResets)
end

local function slowMoTick(w, lrs, split, now)
    local m = slowMoMode()
    if m == "game" or mode() == "game" then
        if w.slowOff then cvarRestore(w, CV_SLOWMO, "WreckSlowMo game"); w.slowOff = false end
        return
    end
    local want = false
    if split then
        if m == "off" then
            want = true
        else
            local n = 0
            for _, e in ipairs(lrs) do if e.racing then n = n + 1 end end
            want = n >= 2
            if not want then                                  -- a wreck's crash cam may still run: hold (see above)
                for _, g in pairs(w.guard) do
                    if not g.done and now - g.since < SLOWMO_HOLD_MS then want = true end
                end
            end
        end
    end
    if want then
        if not w.slowOff then
            cvarSet(w, CV_SLOWMO, 0, "slow-mo off while the race is split")
            w.slowOff = true
        end
        -- ApplySlowMo no longer writes once the cvar is 0: a dilation below 1 (a slow-mo begun before, or a cvar that
        -- did not take) would stay; put it back to real time
        dilationReset(w, now)
    elseif w.slowOff then
        cvarRestore(w, CV_SLOWMO, m == "last" and "one human left racing" or "single view")
        w.slowOff = false
    end
end

-- Emulated wreck slow-mo (WreckSlowMo "game"). Run E: P2's crash cam was replaced by the game's spectate camera at
-- the Wrecked tag, so its ApplySlowMo never ran (the cvar was 0 as well). The crash cam is now put back
-- (guardStep), which should let the game's own slow-mo run; when no dilation < 1 was seen within WreckSlowMoWaitMs
-- of a wreck (or in the 3 s before it: the crash cam starts at the Tumble tag), the curve EMU_CURVE is written to
-- WorldSettings.CinematicTimeDilation on real time (St.nowMs). Any other writer (the game's crash cam, a dilation
-- that differs from our last write) ends the emulation at once without a write; the end puts 1.0 back.
-- VERIFY(V-WD-16): on P2's wreck both views slow down for ~2 s ("emulated wreck slow-mo done", or "the game's
-- slow-mo runs"); real time resumes (dilation=1.0 in the +4.5 s probe). Fallback: cfg.WreckSlowMoEmulate = false.
local function curveAt(t)
    for i = 2, #EMU_CURVE do
        local a, b = EMU_CURVE[i - 1], EMU_CURVE[i]
        if t <= b[1] then return a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1]) end
    end
    return nil
end

local function emuStop(w, why, restore)
    local e = w.emu
    if not e then return end
    w.emu = nil
    if restore then
        local d, ws = dilation()
        if ws and type(d) == "number" and (e.last == nil or math.abs(d - e.last) < 1e-3) then
            pcall(function() ws.CinematicTimeDilation = 1.0 end)
        end
    end
    U.log(TAG, "emulated wreck slow-mo %s (P%d, %d write(s), %.1f s)", why, e.pnum, e.steps,
        (St.nowMs() - e.start) / 1000)
end
M._emuStop = emuStop

local function slowMoEmuTick(w, now)
    local d = dilation()
    if type(d) == "number" and d < 0.999 and not (w.emu and w.emu.last and math.abs(d - w.emu.last) < 1e-3) then
        w.slowSeenAt = now                                    -- someone else's slow-mo (the game's crash cam)
    end
    if not w.emu then
        if slowMoMode() ~= "game" or cfg.WreckSlowMoEmulate == false or mode() == "game" then return end
        local waitMs = numCfg(cfg.WreckSlowMoWaitMs, 350)
        for _, g in pairs(w.guard) do
            if not g.slowChecked and not g.done then
                if w.slowSeenAt and w.slowSeenAt >= g.since - 3000 then
                    g.slowChecked = true
                    U.log(TAG, "P%d wreck: the game's own slow-mo runs (dilation %s)", g.pnum, tostring(d))
                elseif now - g.since >= waitMs then
                    g.slowChecked = true
                    local ph = M.photoMode()
                    if ph then
                        U.log(TAG, "P%d wreck: no slow-mo emulation (photo mode)", g.pnum)
                    elseif U.cvarInt(CV_SLOWMO) == 0 then
                        U.log(TAG, "P%d wreck: no slow-mo (%s is 0: the user's choice)", g.pnum, CV_SLOWMO)
                    else
                        w.emu = { start = now, pnum = g.pnum, steps = 0 }
                        U.log(TAG, "P%d wreck: no slow-mo from the game %.0f ms after the wreck (dilation %s): "
                            .. "emulated (V-WD-16)", g.pnum, now - g.since, tostring(d))
                    end
                end
            end
        end
        if not w.emu then return end
    end
    local e = w.emu
    if M.photoMode() then emuStop(w, "stopped: photo mode", true); return end
    local cur, ws = dilation()
    if not ws or type(cur) ~= "number" then emuStop(w, "stopped: no WorldSettings", false); return end
    if e.last and math.abs(cur - e.last) > 1e-3 then
        emuStop(w, string.format("stopped: another writer (dilation %.2f, ours %.2f)", cur, e.last), false)
        return
    end
    local v = curveAt(now - e.start)
    if v == nil then emuStop(w, "done", true); return end
    pcall(function() ws.CinematicTimeDilation = v end)
    e.last, e.steps = v, e.steps + 1
end

---------------------------------------------------------------------------------------------------- 3. no wrecks
local function buildsNoHealth(ps)
    local vbs = ps.RacerBuildState.VehicleBuilds            -- TArray<FVehicleBuildState>; UseHealth @+0x53 (Bool)
    local n, changed = vbs:GetArrayNum(), 0
    for k = 1, n do
        local el = vbs[k]
        if el.UseHealth ~= false then
            el.UseHealth = false
            changed = changed + 1
        end
    end
    return n, changed
end

-- FAST. "build": UseHealth = false on every VehicleBuilds entry of the local human's racer PlayerState, re-applied
-- until rec:ShouldUseHealth() reads false (ShouldUseHealth 0x14389d186 reads the build of the pawn's archetype live),
-- re-checked in MAIN (the replicated build state may be rebuilt). "cvar": Race.InfiniteHealth 1 (read live on every
-- ShouldUseHealth call; global: AI never wrecks either). Every method keeps the top-up safety net: a local human whose
-- next crash would wreck (the game's own ShouldNextCrashWreckVehicle) gets its starting health back.
-- VERIFY(V-WD-08): "P2: no wrecks (UseHealth false ...)" in the log; a human at health 1 crashes, tumbles and resets
-- (no bHasVehicleWrecked). Fallback: the per-player top-up (logged as V-WD-08), or NoWreckMethod "cvar".
-- Authority: "build" and "cvar" only change THIS process's copy (ShouldUseHealth reads it, so a client would log
-- "no wrecks" while its server still wrecks the car). A network client keeps only the top-up (a Server RPC).
local function hasAuthority(w)
    if w.authority == nil then w.authority = (U.netMode() == "standalone") or U.isServer() end   -- once per world
    return w.authority
end

local function noWreckTick(w, lrs)
    local m = opt(cfg.NoWreckMethod, { "build", "cvar", "topup" }, "build")
    if m ~= "topup" and not hasAuthority(w) then
        U.logOnce("wreck.noauth", TAG, "NoWreckMethod %s has no effect on a network client: health top-up only", m)
        m = "topup"
    end
    if m == "cvar" and not w.infHealth then
        cvarSet(w, CV_INFHEALTH, 1, "WreckMode noWreck")
        w.infHealth = true
    end
    for _, e in ipairs(lrs) do
        if e.racing then
            local b = w.build[e.key]
            if not b then b = { tries = 0 }; w.build[e.key] = b end
            if m == "build" and not b.gaveUp then
                local psk = U.key(e.ps)
                if b.psKey ~= psk then b.psKey, b.tries, b.ok = psk, 0, false end
                if not b.ok then
                    b.tries = b.tries + 1
                    local okB, n, changed = pcall(buildsNoHealth, e.ps)
                    if call0(e.rec, "ShouldUseHealth") == false then
                        b.ok = true
                        U.log(TAG, "P%d: no wrecks (UseHealth false on %s build entr%s%s)", e.pnum, tostring(n),
                            n == 1 and "y" or "ies", okB and "" or ", write error")
                    elseif b.tries >= BUILD_TRIES then
                        b.gaveUp = true
                        U.warn(TAG, "P%d still uses health after %d UseHealth writes (%s): health top-up instead (V-WD-08)",
                            e.pnum, b.tries, okB and ("changed " .. tostring(changed)) or tostring(n))
                    end
                end
            end
            if call0(e.rec, "ShouldNextCrashWreckVehicle") == true then
                local start, hp = tonumber(field(e.rec, "StartingVehicleHealth")), tonumber(field(e.rec, "VehicleHealth"))
                if start and hp and start > hp then
                    local ok = pcall(function() e.rec:Server_ChangeVehicleHealthBy(start - hp) end)
                    w.topups = w.topups + 1
                    U.logEvery("wreck.topup" .. e.pnum, 3000, TAG, "P%d health %d -> %d (no wrecks, %s; %d top-up(s))",
                        e.pnum, hp, start, ok and "ok" or "call failed", w.topups)
                end
            end
        end
    end
end

-- MAIN: a rebuilt build state turns health back on: apply again.
local function noWreckRecheck(w, lrs)
    for _, e in ipairs(lrs) do
        local b = w.build[e.key]
        if b and b.ok and e.racing and call0(e.rec, "ShouldUseHealth") == true then
            b.ok, b.tries = false, 0
            U.log(TAG, "P%d uses health again (build state rebuilt?): UseHealth re-applied", e.pnum)
        end
    end
end

---------------------------------------------------------------------------------------------------- 2. spectate
-- The car a wrecked player watches: still racing, with a pawn, not the player itself. cfg.WreckSpectateTarget:
-- "human" = another local human first (lowest EventPosition), then the leader; "leader" = lowest EventPosition;
-- "ai" = an AI car first (no camera shared with another view; V-WD-07), then a human.
-- Note: the game's own pick (StartSpectatingBestRacer 0x1470df07e) ignores bHasVehicleWrecked, so it may pick a wreck.
-- prefOverride: applyFallback passes "ai" (its SetViewTargetWithBlend on another HUMAN's pawn would have that car's
-- camera evaluated by two camera managers; V-WD-07). The native spectate has its own SpectatorCam actor.
local function pickTarget(gs, selfPS, lrs, prefOverride)
    if not U.ok(gs) then return nil end
    local pref = prefOverride or opt(cfg.WreckSpectateTarget, { "human", "leader", "ai" }, "human")
    local localPS = {}
    for _, e in ipairs(lrs) do localPS[U.key(e.ps)] = true end
    local w = (type(St.wreck) == "table" and type(St.wreck.motion) == "table") and St.wreck or nil
    local now = St.nowMs()
    local best = {}
    eachRacer(gs, function(ps)
        if U.same(ps, selfPS) then return end
        local rec = recOf(ps)
        if not stillRacing(rec) or not pawnOf(ps) then return end
        local pos = tonumber(field(rec, "EventPosition")) or 99
        local rank = 1
        if pref == "human" then rank = localPS[U.key(ps)] and 1 or 2
        elseif pref == "ai" then rank = isBot(ps) and 1 or 2 end
        -- run E: a car that stands still (P1 parked on the grid) only when no moving car is left
        if w and not isMoving(w, pawnOf(ps), now) then rank = rank + 2 end
        if not best[rank] or pos < best[rank].pos then best[rank] = { ps = ps, pos = pos } end
    end)
    local b = best[1] or best[2] or best[3] or best[4]
    return b and b.ps or nil
end

local function psRacing(ps) return stillRacing(recOf(ps)) and pawnOf(ps) ~= nil end

local function nameOf(ps)
    local ok, s = pcall(function() return U.str(ps:GetPlayerName()) end)
    return ok and s or "?"
end

-- One probe line per call (V-WD-04: which camera a wrecked view really has).
local function probe(g, label)
    if cfg.WreckProbe == false then return end
    local pc = g.pc
    local vt = call0(pc, "GetViewTarget")
    local pcm = field(pc, "PlayerCameraManager")
    local loc = U.ok(pcm) and call0(pcm, "GetCameraLocation") or nil
    local locS = "?"
    if loc ~= nil then
        pcall(function() locS = string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) end)
    end
    local sc = field(pc, "SpectatorComponent")
    local flow = field(pc, "PlayerCinematicFlowComponent")
    local tgt = U.ok(sc) and field(sc, "playerToSpectate") or nil
    local d = dilation()
    -- run E additions: fade state (V-WD-15), our view phase, the watched car and whether it moves, camera motion
    local w = St.wreck
    local now = St.nowMs()
    local phase = g.useCar == nil and "-" or (g.crashCam and "crash" or (g.useCar and "car" or "native"))
    local carS = "-"
    if U.ok(g.car) then
        local s = type(w) == "table" and stillMs(w, g.car, now) or nil
        carS = string.format("%s(%s)", g.carPS and nameOf(g.carPS) or clsName(g.car),
            s == nil and "?" or (s < MOVING_RECENT_MS and "moving" or string.format("still %.1fs", s / 1000)))
    end
    local camS = g.camMovedAt and string.format("%.1fs", (now - g.camMovedAt) / 1000) or "?"
    U.log(TAG, "probe P%d %s: view=%s cam=(%s) camStill=%s fade=%s phase=%s car=%s spectating=%s specCam=%s "
        .. "target=%s chain=%s dilation=%s photo=%s", g.pnum, label, clsName(vt), locS, camS, fadeText(pc), phase, carS,
        tostring(U.ok(sc) and field(sc, "bIsSpectatorRunning")), clsName(U.ok(sc) and field(sc, "SpectatorCam") or nil),
        U.ok(tgt) and nameOf(tgt) or "nil", clsName(U.ok(flow) and field(flow, "CurrentCinematicChain") or nil),
        tostring(d), tostring((M.photoMode())))
end

-- Is this view's camera unusable? bad, why, viewTarget. A camera that cannot be read is never "bad" (no fight).
local function camBad(g, sc)
    local pc = g.pc
    local vt = call0(pc, "GetViewTarget")
    if not U.ok(vt) then return true, "no view target", nil end
    local pcm = field(pc, "PlayerCameraManager")
    local loc = U.ok(pcm) and call0(pcm, "GetCameraLocation") or nil
    local x, y, z
    if loc ~= nil then pcall(function() x, y, z = tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z) end) end
    if not (x and y and z) then return false, "camera not readable", vt end
    if x ~= x or y ~= y or z ~= z then return true, "NaN camera", vt end
    if math.abs(x) + math.abs(y) + math.abs(z) < 1 then return true, "camera at the world origin", vt end
    local cn = clsName(vt)
    local focus
    if U.isVehicle(vt) then
        focus = vt
        -- 0.7.1 (run I): the player's own pod camera following another car (chasecam TargetActorOverride) is measured
        -- against the WATCHED car, not the view target (the own wreck, far behind): else every check read "camera
        -- 180000 uu from its car" and flipped the watched car twice a second
        local cc = lazy("chasecam")
        if cc and cc.isOverride and cc.isOverride(pc) and U.ok(g.car) and not U.same(g.car, vt) then focus = g.car end
    elseif cn:find("Spectator") then
        local t = U.ok(sc) and field(sc, "playerToSpectate") or nil
        focus = pawnOf(t)
    elseif cn:find("Crash") then
        focus = pawnOf(g.ps)
    end
    if focus then
        local fl = call0(focus, "K2_GetActorLocation")
        local fx, fy, fz
        if fl ~= nil then pcall(function() fx, fy, fz = tonumber(fl.X), tonumber(fl.Y), tonumber(fl.Z) end) end
        if fx and fy and fz then
            local dist = math.sqrt((x - fx) ^ 2 + (y - fy) ^ 2 + (z - fz) ^ 2)
            if dist > (tonumber(cfg.WreckCamMaxDistUU) or 15000) then
                return true, string.format("camera %.0f uu from its car (%s)", dist, cn), vt
            end
        end
    end
    return false, cn, vt
end

local function endCinematic(g, blind)
    local flow = field(g.pc, "PlayerCinematicFlowComponent")
    if not U.ok(flow) then return false end
    local ok = pcall(function() flow:Client_EndCurrentCinematic("SWGRCouch", false) end)
    g.cineEnded, g.cineEndedAt = true, St.nowMs()
    -- the chain was played with returnToCamType 0 and the flow keeps a PreviousViewTarget: ending it may put the view
    -- back on the player's own wreck; guardStep re-selects the native spectate target once (g.reassert)
    g.reassert = true
    U.log(TAG, "P%d failed-event cinematic ended%s (%s)", g.pnum, blind and " (blind, no new chain seen)" or "",
        ok and "ok" or "call failed")
    return ok
end

-- Puts the wrecked player's view on a car still racing (or its own wreck: cfg.WreckViewFallback "own").
-- Its own order, not WreckSpectateTarget: an AI car first, then a human, then the player's own wreck (V-WD-07: a
-- SetViewTargetWithBlend on the other human's pawn has its camera evaluated by two camera managers).
-- VERIFY(V-WD-05/07): "view fallback" lines; the view shows that car within ~0.5 s and no camera fight/jitter in either
-- view. Fallback: WreckViewFallback "own".
local function applyFallback(g, lrs, why, now)
    local pc = g.pc
    local target, tps
    if cfg.WreckViewFallback == "own" then target = pawnOf(g.ps) end
    if not U.ok(target) then                                 -- "racer", or "own" with the wreck already destroyed
        local ps = pickTarget(U.gs(), g.ps, lrs, "ai")
        tps = ps and U.ok(pawnOf(ps)) and ps or nil
        target = ps and pawnOf(ps) or pawnOf(g.ps)
    end
    -- the racer the fallback watches, kept for "fallback car out" (a pawn's own PlayerState read can fail: the
    -- check then saw every car "out" and re-applied each second)
    g.appliedPS = tps
    if not U.ok(target) then
        U.logEvery("wreck.nofallback" .. tostring(g.pnum), 5000, TAG, "P%d view fallback (%s): no car to show", g.pnum, why)
        return
    end
    local pcm = field(pc, "PlayerCameraManager")
    if U.ok(pcm) then pcall(function() pcm:StopCameraFade() end) end       -- H3; FadeAmount is not reflected
    if cfg.WreckCinematic ~= "keep" and not g.cineEnded then endCinematic(g, true) end
    local ok = pcall(function() pc:SetViewTargetWithBlend(target, 0.3, C.E.ViewBlend.Linear, 0.0, false) end)
    g.applied, g.appliedAt, g.fallbacks = target, now, (g.fallbacks or 0) + 1
    -- the game's camera was unusable: stop re-selecting native spectate targets (each re-select would put the broken
    -- spectator camera back); our fallback then follows the cars itself ("fallback car out")
    if why ~= "fallback car out" then g.nativeBroken = true end
    U.log(TAG, "P%d view fallback (%s) -> %s%s", g.pnum, why, clsName(target), ok and "" or " (call failed)")
end

-- "force": the native spectate is never requested nor retargeted. VERIFY: a native spectate the GAME starts by itself
-- at the wreck is not stopped; if its camera fights the forced view ("view moved" fallback lines every ~1 s), use "auto".
local function guardMode() return opt(cfg.WreckViewGuard, { "auto", "force", "off" }, "auto") end

---------------------------------------------------------------------------------------------------- 2b. car view (run E)
-- The car a wrecked view watches (WreckView "car"/"carAll"): a MOVING racing car always beats a still one (run E: the
-- "human" pick was P1's parked car); then cfg.WreckSpectateTarget ("human" = another local human, "ai" = an AI car,
-- "leader"), then the lowest EventPosition. exclude = a pawn whose camera just proved unusable.
local function pickCarTarget(w, g, lrs, now, exclude)
    local pref = opt(cfg.WreckSpectateTarget, { "human", "leader", "ai" }, "human")
    local localPS = {}
    for _, e in ipairs(lrs) do localPS[U.key(e.ps)] = true end
    local best
    eachRacer(U.gs(), function(ps)
        if U.same(ps, g.ps) then return end
        local rec = recOf(ps)
        if not stillRacing(rec) then return end
        local p = pawnOf(ps)
        if not p or (exclude and U.same(p, exclude)) then return end
        local human, moving = localPS[U.key(ps)] == true, isMoving(w, p, now)
        local rank = 1
        if pref == "human" then rank = human and 1 or 2
        elseif pref == "ai" then rank = isBot(ps) and 1 or 2 end
        if not moving then rank = rank + 10 end
        local pos = tonumber(field(rec, "EventPosition")) or 99
        if not best or rank < best.rank or (rank == best.rank and pos < best.pos) then
            best = { ps = ps, pawn = p, rank = rank, pos = pos, moving = moving, human = human }
        end
    end)
    return best
end

-- Puts the view on a racing car (or, with none left, the player's own wreck). VERIFY(V-WD-05/07): "view -> <name>'s
-- car" lines; that view follows a moving car, and the other human's view does not jitter when its car is watched.
-- 0.6.0 (run G, F3): the view ACTOR may differ from the watched car (g.car): chasecam.lua's rig (g.view) when the
-- car's own camera is no chase camera (an AI pod: "camera in the engine"). cfg.WreckCarCam "auto": a local human's car
-- through its own (live) camera; another car through its own camera until the placement check (carStep, g.verifyAt)
-- says "inside"/"front", then (and for a car already known bad: w.badCam) through the rig. "rig": every other car
-- through the rig. "car": unchecked (0.5.1). The player's own wreck is always shown through its own camera.
local function viewActorFor(w, g, b, target)
    local cc = lazy("chasecam")
    if not (cc and b) then return target, "own camera", false end
    local m = cc.mode()
    local _, info, live = cc.ownCamInfo(target)
    -- "auto": a non-human car whose camera runs no stack (live == false), or proved bad, goes to the rig at once
    local wantRig = m == "rig" or (m == "auto" and not b.human
        and (live == false or (w.badCam and w.badCam[U.key(target)] == true)))
    if wantRig then
        -- 0.7.1 (run I): a camera actor renders black in a guest's (lower) view; the player's own pod camera with
        -- TargetActorOverride renders normally. "auto"/"override" try it first; "rig" keeps the 0.6.0 rig.
        if m == "override" then
            local own = pawnOf(g.ps)
            if not (U.ok(own) and U.isVehicle(own)) then pcall(function() own = g.pc.Pawn end) end
            if U.ok(own) and U.isVehicle(own) and not U.same(own, target) then
                local v, whyO = cc.overrideFor(g.pc, own, target)
                if v then return v, "own camera following it (" .. info .. ")", false end
                U.logEvery("wreck.ovr" .. tostring(g.pnum), 10000, TAG, "P%d camera override unavailable: %s", g.pnum,
                    tostring(whyO))
            end
        end
        local rig, why = cc.rigFor(g.pc, target)
        if rig then return rig, "rig (" .. info .. ")", false end
        return target, string.format("own camera, rig failed: %s (%s)", tostring(why), info), false
    end
    if m == "auto" and not b.human then return target, "own camera, checking (" .. info .. ")", true end
    return target, "own camera (" .. info .. ")", false
end

local function carView(w, g, lrs, now, why, exclude)
    local b = pickCarTarget(w, g, lrs, now, exclude)
    -- 0.7.1 (run I): an AI pod has no camera component, a camera actor (chasecam rig, the game's spectator / crash
    -- camera) renders BLACK in a guest's view, and the own-camera override (TargetActorOverride) made the game pause
    -- itself again and again. With WreckCarCam "auto" a guest whose pick is such a car keeps its OWN wreck in view
    -- (rendered by its own pod camera); "override" / "rig" keep the experiments.
    if b and not b.human and g.pnum ~= 1 then
        local cc = lazy("chasecam")
        if cc and cc.mode() == "own" then   -- 0.7.2: the rig renders in a guest view again ("auto" = rig)
            local okI, _, _, live = pcall(cc.ownCamInfo, b.pawn)
            if okI and live == false then
                local own = pawnOf(g.ps)
                if U.ok(own) and U.same(g.applied, own) then return true end   -- already on its own wreck
                U.logEvery("wreck.ownfb" .. tostring(g.pnum), 10000, TAG, "P%d: %s's car has no camera of its own and "
                    .. "a camera actor renders black in a guest view: own wreck shown instead (V-WD-22)", g.pnum,
                    nameOf(b.ps))
                b = nil
            end
        end
    end
    local target = b and b.pawn or pawnOf(g.ps)
    if not U.ok(target) then
        U.logEvery("wreck.nocar" .. tostring(g.pnum), 5000, TAG, "P%d car view (%s): no car to show", g.pnum, why)
        return false
    end
    local okV, view, how, verify = U.try(TAG, viewActorFor, w, g, b, target)
    if not okV or not U.ok(view) then view, how, verify = target, "own camera", false end
    local cc = lazy("chasecam")
    if cc and not cc.isRig(view) then pcall(cc.release, g.pc, "view on a car's own camera") end
    -- 0.7.1: an override only lives while the view is the player's own pod following another car
    if cc and cc.isOverride and cc.isOverride(g.pc) and not (tostring(how):find("following", 1, true)) then
        pcall(cc.releaseOverride, g.pc, "view changed")
    end
    local ok = setView(g.pc, view, numCfg(cfg.WreckViewBlendSec, 0.0))
    if not U.same(target, g.car) then g.carSince = now end
    g.car, g.carPS, g.carAt, g.applied, g.appliedAt = target, b and b.ps or nil, now, view, now
    g.view, g.verifyAt, g.verifyN, g.verifyBad = view, verify and now + 500 or nil, 0, 0
    g.camMovedAt, g.camX = now, nil
    g.carSets = (g.carSets or 0) + 1
    U.log(TAG, "P%d view -> %s (%s; pref %s) via %s%s", g.pnum,
        b and string.format("%s's car, %s, %s, pos %d", nameOf(b.ps), b.human and "local human" or
            (isBot(b.ps) and "AI" or "racer"), b.moving and "moving" or "still", b.pos) or "its own wreck (no car racing)",
        why, b and opt(cfg.WreckSpectateTarget, { "human", "leader", "ai" }, "human") or "-", tostring(how),
        ok and "" or " (call failed)")
    return ok
end

-- 0.6.0: the watched car's own camera checked 0.5 s after the view was set, then every 300 ms, 4 samples
-- (chasecam.placement). Two bad samples ("inside": closer than WreckCarCamMinDistUU; "front": not behind the car)
-- mark that car's camera bad for the race (w.badCam) and switch the same car to the rig. VERIFY(V-WD-19): run G's AI
-- pod reads "inside"/"front" -> "rig"; a human's car reads "chase".
local function verifyStep(w, g, now)
    if not g.verifyAt or now < g.verifyAt then return end
    local cc = lazy("chasecam")
    if not cc or not U.ok(g.car) then g.verifyAt = nil; return end
    local v, dist, along, up = cc.placement(g.pc, g.car)
    g.verifyN = (g.verifyN or 0) + 1
    if v ~= "chase" and v ~= "unknown" then g.verifyBad = (g.verifyBad or 0) + 1 end
    U.log(TAG, "P%d watched car camera check %d: %s (dist %.0f, along %.0f, up %.0f)", g.pnum, g.verifyN, v,
        dist or -1, along or 0, up or 0)
    if (g.verifyBad or 0) >= 2 then
        g.verifyAt = nil
        w.badCam = w.badCam or {}
        w.badCam[U.key(g.car)] = true
        local rig, why = cc.rigFor(g.pc, g.car)
        if rig then
            local ok = setView(g.pc, rig, 0.0)
            g.view, g.applied, g.carAt, g.camMovedAt = rig, rig, now, now
            U.log(TAG, "P%d %s's car camera is no chase camera (%s): view -> rig%s", g.pnum,
                g.carPS and nameOf(g.carPS) or clsName(g.car), v, ok and "" or " (call failed)")
        else
            U.warn(TAG, "P%d %s's car camera is no chase camera (%s) and the rig failed (%s): view left on it",
                g.pnum, g.carPS and nameOf(g.carPS) or clsName(g.car), v, tostring(why))
        end
        return
    end
    g.verifyAt = g.verifyN < 4 and now + 300 or nil
end

-- Fades on a wrecked view (V-WD-15): a fade held longer than WreckFadeClearMs is cleared (StopCameraFade disables
-- the overlay). Unreadable fields: blind StopCameraFade every 1 s once WreckFadeClearMs has passed since the wreck.
local function fadeGuard(g, now)
    local clearMs = numCfg(cfg.WreckFadeClearMs, 1500)
    if clearMs <= 0 then return end
    local pcm = field(g.pc, "PlayerCameraManager")
    if not U.ok(pcm) then return end
    local fs = fadeState(pcm)
    if fs then
        if not (fs.enabled and fs.amount > 0.02) then g.fadeSince = nil; return end
        g.fadeSince = g.fadeSince or now
        if now - g.fadeSince < clearMs then return end
        pcall(function() pcm:StopCameraFade() end)
        local after = fadeState(pcm)
        g.fadeClears, g.fadeSince = (g.fadeClears or 0) + 1, nil
        if after and not after.enabled and not fadeReg.verified then
            fadeReg.verified = true
            U.log(TAG, "camera fade fields verified: bEnableFading read 1, then 0 after StopCameraFade (V-WD-15)")
        end
        U.logEvery("wreck.fade" .. tostring(g.pnum), 2000, TAG,
            "P%d camera fade %.2f held %.0f+ ms on the wrecked view: StopCameraFade -> %s (%d clear(s))", g.pnum, fs.amount,
            clearMs, after and string.format("%s:%.2f", after.enabled and "on" or "off", after.amount) or "?", g.fadeClears)
        return
    end
    if now - g.since >= clearMs and now - (g.blindFadeAt or -1e9) >= 1000 then
        g.blindFadeAt = now
        pcall(function() pcm:StopCameraFade() end)
        g.blindFades = (g.blindFades or 0) + 1
        if g.blindFades == 1 then
            U.log(TAG, "P%d blind StopCameraFade every 1 s while the view is guarded (fade fields: %s)", g.pnum,
                fadeReg.bad and "untrusted" or tostring(fadeReg.err or "unreadable"))
        end
    end
end

-- Camera motion of the guarded view, sampled every 500 ms (g.camMovedAt: last time it moved > 50 uu).
local function camMotion(g, now)
    if now - (g.camSampleAt or -1e9) < 500 then return end
    g.camSampleAt = now
    local x, y, z = camLoc(g.pc)
    if not x then return end
    if g.camX == nil or math.abs(x - g.camX) + math.abs(y - g.camY) + math.abs(z - g.camZ) > 50 then
        g.camMovedAt = now
    end
    g.camX, g.camY, g.camZ = x, y, z
end

-- Crash-camera hold (every mode but WreckViewGuard "off"): run E showed the game's spectate replacing the wreck
-- camera at the Wrecked tag (blend 0). The crash cam is put back at the wreck edge (pollRacers) and kept for
-- WreckCrashCamHoldMs (re-set at most twice if something moves the view; dropped when unusable or destroyed).
-- Returns true while the hold runs. VERIFY(V-WD-18): the wrecked player sees its tumbling car (crash cam) for ~4 s,
-- probe "+2.0s ... phase=crash view=BP_CrashCameraActor_C"; then "view -> ..." (car) or the native spectate.
local function holdStep(g, now)
    if not g.crashCam then return false end
    if now - g.since >= holdMs() or not U.ok(g.crashCam) then
        U.log(TAG, "P%d wreck camera hold over (%s)", g.pnum, U.ok(g.crashCam) and "time" or "camera destroyed")
        g.crashCam = nil
        return false
    end
    local vt = call0(g.pc, "GetViewTarget")
    if not U.same(vt, g.crashCam) then
        if (g.crashRe or 0) < 2 and now - (g.crashReAt or -1e9) >= 500 then
            g.crashRe, g.crashReAt = (g.crashRe or 0) + 1, now
            local ok = setView(g.pc, g.crashCam, 0.0)
            U.log(TAG, "P%d wreck camera re-set (view was %s)%s", g.pnum, clsName(vt), ok and "" or " (call failed)")
        elseif (g.crashRe or 0) >= 2 then
            U.log(TAG, "P%d wreck camera hold given up: the view keeps moving (%s)", g.pnum, clsName(vt))
            g.crashCam = nil
            return false
        end
        return true
    end
    local bad, why = camBad(g, nil)
    if bad then
        g.badSince = g.badSince or now
        if now - g.badSince >= numCfg(cfg.WreckCamBadMs, 400) then
            U.log(TAG, "P%d wreck camera unusable (%s): hold dropped", g.pnum, why)
            g.crashCam, g.badSince = nil, nil
            return false
        end
    else
        g.badSince = nil
    end
    return true
end

-- WreckView "car" after the hold: keeps the view on a moving racing car.
local function carStep(w, g, lrs, now)
    camMotion(g, now)
    -- review 0.5.0: the game may start its (static) spectate again after the wreck edge (the DNF update / failed
    -- chain); it would keep pulling the view to the spectator camera and use up the re-apply budget. Ended again
    -- (every 250 ms at most, 4 times), the car view put back at once. VERIFY(V-WD-18): "native spectate restarted" rare.
    if now >= (g.nextSpecEndMs or 0) then
        g.nextSpecEndMs = now + 250
        local sc = field(g.pc, "SpectatorComponent")
        if U.ok(sc) and field(sc, "bIsSpectatorRunning") == true and (g.specReEnds or 0) < 4 then
            g.specReEnds = (g.specReEnds or 0) + 1
            local okE = pcall(function() sc:Client_OnSpectatorModeEnded() end)
            local okV = U.ok(g.car) and setView(g.pc, U.ok(g.view) and g.view or g.car, 0.0)
            if U.ok(g.car) then g.carAt = now end
            U.log(TAG, "P%d native spectate restarted by the game: ended again (%s), view back on %s (%d/4)", g.pnum,
                okE and "ok" or "call failed", U.ok(g.car) and (g.carPS and nameOf(g.carPS) or clsName(g.car)) or "-",
                g.specReEnds)
            if not okV and U.ok(g.car) then U.log(TAG, "P%d car view call failed after the spectate end", g.pnum) end
        end
    end
    if not U.ok(g.car) or (g.view ~= nil and not U.ok(g.view)) then
        carView(w, g, lrs, now, g.carSets and (U.ok(g.car) and "rig gone" or "watched car gone")
            or (g.hadCrashCam and "wreck camera over" or "wrecked"))
        return
    end
    local viewActor = U.ok(g.view) and g.view or g.car
    local recent = now - (g.carAt or -1e9) < 1000
    if g.carPS and not psRacing(g.carPS) and not recent then
        carView(w, g, lrs, now, "watched car out")
        return
    end
    local vt = call0(g.pc, "GetViewTarget")
    if not U.same(vt, viewActor) then
        -- moved by someone else (photo mode exit, a cinematic, the flow component): back on the car, rate-limited
        if now - (g.carAt or -1e9) >= numCfg(cfg.WreckViewReapplyMs, 1500) then
            g.reapplies = (g.reapplies or 0) + 1
            if g.reapplies > REAPPLY_MAX then
                if not g.reapplyGaveUp then
                    g.reapplyGaveUp = true
                    U.warn(TAG, "P%d: the view was moved off the watched car %d times (now %s): left alone", g.pnum,
                        g.reapplies - 1, clsName(vt))
                end
                return
            end
            local ok = setView(g.pc, viewActor, 0.0)
            g.carAt, g.camMovedAt = now, now
            U.logEvery("wreck.reapply" .. tostring(g.pnum), 3000, TAG, "P%d view was moved to %s: back on %s (%d)%s",
                g.pnum, clsName(vt), g.carPS and nameOf(g.carPS) or clsName(g.car), g.reapplies, ok and "" or " (failed)")
        end
        return
    end
    verifyStep(w, g, now)                                      -- 0.6.0: is the car's own camera a chase camera?
    -- the camera itself: NaN / origin / far from its car (camBad), or frozen while its car moves
    local bad, why = camBad(g, nil)
    local carStill = stillMs(w, g.car, now)
    if not bad and carStill and carStill < 1000 and now - (g.camMovedAt or now) > 3000 and not recent then
        bad, why = true, "camera frozen while its car moves"
    end
    if bad then
        g.badSince = g.badSince or now
        if now - g.badSince >= numCfg(cfg.WreckCamBadMs, 400) and not recent then
            g.badSince = nil
            carView(w, g, lrs, now, why, g.car)
        end
        return
    end
    g.badSince = nil
    -- a watched car that stands still while another one moves (run E: P1 parked on the grid)
    if now >= (g.nextPickMs or 0) and now - (g.carSince or now) >= 3000 then
        g.nextPickMs = now + 1000
        if carStill and carStill >= numCfg(cfg.WreckTargetStaticMs, 4000) then
            local b = pickCarTarget(w, g, lrs, now)
            if b and b.moving and not U.same(b.pawn, g.car) then
                carView(w, g, lrs, now, string.format("watched car still for %.1f s", carStill / 1000))
            end
        end
    end
end

-- FAST, per wrecked local player while another local human races.
local function guardStep(w, g, lrs, now)
    local othersRacing = false
    for _, e in ipairs(lrs) do if e.racing and e.key ~= g.key then othersRacing = true end end
    if not othersRacing or not U.ok(g.pc) then g.done = true; return end    -- the race ends natively now
    -- photo mode (run E: both local PCs possess a BP_PhotoModePawn_C and this guard "restored" P2's spectate view
    -- three times): hands off until PHOTO_GRACE_MS after it closed (the PCs re-possess their pawns meanwhile)
    local ph, phWhy = M.photoMode()
    if ph then
        if not g.photo then
            g.photo = true
            U.log(TAG, "P%d view guard paused: photo mode (%s)", g.pnum, tostring(phWhy))
        end
        g.photoEnd = nil
        return
    elseif g.photo then
        g.photo, g.photoEnd = false, now
        U.log(TAG, "P%d photo mode closed: view guard resumes in %d ms", g.pnum, PHOTO_GRACE_MS)
    end
    if g.photoEnd then
        if now - g.photoEnd < PHOTO_GRACE_MS then return end
        g.photoEnd = nil
        g.reapplies, g.crashRe = 0, 2                         -- a fresh budget for the car view; no crash-cam re-set
        g.reasserts = math.min(g.reasserts or 0, 2)           -- native: one more "spectate view restored" allowed
        g.camMovedAt, g.camX, g.badSince = now, nil, nil      -- no "frozen camera" from the paused samples
        probe(g, "after photo mode")
    end
    local age = now - g.since
    while g.probeIdx <= #PROBE_AT_MS and age >= PROBE_AT_MS[g.probeIdx] do
        probe(g, string.format("+%.1fs", PROBE_AT_MS[g.probeIdx] / 1000))
        g.probeIdx = g.probeIdx + 1
    end
    -- the single-player failed-event chain (Client_PlayCinematicChain on the next racer update) may hide actors or cut
    -- the camera while the other human still races (V-WD-06): ended once a chain OTHER than the one current at the
    -- wreck (g.chain0: e.g. the race intro, still referenced) is seen; blind once after 1.5 s, only after the DNF (the
    -- update that plays the failed chain) has happened
    if cfg.WreckCinematic ~= "keep" and not g.cineEnded and age < 8000 then
        local flow = field(g.pc, "PlayerCinematicFlowComponent")
        local chain = U.ok(flow) and field(flow, "CurrentCinematicChain") or nil
        if U.ok(chain) and U.key(chain) ~= g.chain0 then endCinematic(g, false)
        elseif age >= 1500 and field(g.rec, "bHasFinishedEvent") == true then endCinematic(g, true) end
    end
    local gmode = guardMode()
    if gmode ~= "off" then
        fadeGuard(g, now)                                     -- V-WD-15 (replaces the single blind clear at +1.5 s)
        if holdStep(g, now) then return end                   -- the wreck camera first (V-WD-18)
        if g.useCar then carStep(w, g, lrs, now); return end  -- WreckView "car"/"carAll" (V-WD-05)
    end
    local sc = field(g.pc, "SpectatorComponent")
    if U.ok(sc) and now >= (g.nextSpecMs or 0) then
        g.nextSpecMs = now + 250
        local running = field(sc, "bIsSpectatorRunning") == true
        local waitMs = tonumber(cfg.WreckSpectateWaitMs) or 800
        if not running and not g.specAsked and age >= waitMs and not g.nativeBroken and gmode ~= "force" then
            g.specAsked = true
            if U.same(g.pc, U.p1()) then
                -- P1's race CSM is the only one: a request moves it to CSM_RF_Spectating, whose full-screen
                -- WBP_PVP_Spectate_C (and spectate music/mix) would cover the other player's view until hud's next
                -- MAIN tick. P1 gets the view fallback instead (VERIFY V-WD-11).
                if gmode ~= "off" then
                    applyFallback(g, lrs, "P1 native spectate not running; no request (its CSM covers every view)", now)
                else
                    U.log(TAG, "P1 native spectate not running; no request (its CSM covers every view), WreckViewGuard off")
                end
            else
                local ok = pcall(function() sc:Server_RequestPostRaceSpectate() end)
                U.log(TAG, "P%d native spectate not running: Server_RequestPostRaceSpectate (%s)", g.pnum,
                    ok and "ok" or "failed")
            end
        elseif running and not g.nativeBroken and gmode ~= "force" then
            local cur = field(sc, "playerToSpectate")
            local want = pickTarget(U.gs(), g.ps, lrs)
            local curOk = U.ok(cur) and psRacing(cur)
            -- the preference once, then only when the watched car is out (never fight the game's/player's choice)
            if want and not U.same(cur, want) and (not curOk or not g.prefApplied) then
                local ok = pcall(function() sc:SelectPlayerToSpectate_OnClient(want) end)
                U.log(TAG, "P%d spectates %s (%s, %s)", g.pnum, nameOf(want), curOk and "preferred target" or
                    "previous target out", ok and "ok" or "call failed")
            elseif g.prefApplied then
                -- the spectate runs but the view is elsewhere (typically back on the own wreck after the cinematic end,
                -- which camBad accepts): select the target again, which puts the view back on the spectator camera.
                -- Only after the cinematic end or the crash-cam time; every 2 s at most, 3 times.
                -- VERIFY(V-WD-05): "spectate view restored" at most once per wreck in a normal run.
                local vt = call0(g.pc, "GetViewTarget")
                local onSpec = U.same(vt, field(sc, "SpectatorCam")) or (curOk and U.same(vt, pawnOf(cur)))
                    or U.same(vt, g.applied)
                local settled = (g.reassert and now - (g.cineEndedAt or now) >= 300) or age >= 4000
                -- 0.13.0 (task #15, live 2026-10-11): the game's crash camera (BP_CrashCameraActor_C) took P1's view
                -- back after every one of the 3 re-selects and P1 watched its own wreck for 40 s (until a pause).
                -- While the view is a crash camera the budget is cfg.WreckSpectateReasserts (default 30, every 2 s)
                -- and the view is also put straight on the spectated car.
                local onCrashCam = U.ok(vt) and tostring(clsName(vt)):find("CrashCamera", 1, true) ~= nil
                local budget = onCrashCam and numCfg(cfg.WreckSpectateReasserts, 30) or 3
                if not onSpec and U.ok(vt) and settled and (g.reasserts or 0) < budget
                    and now - (g.reassertAt or -1e9) >= 2000 then
                    local tgt = curOk and cur or want
                    if tgt then
                        local ok = pcall(function() sc:SelectPlayerToSpectate_OnClient(tgt) end)
                        local direct = ""
                        if onCrashCam then
                            local pw = pawnOf(tgt)
                            if U.ok(pw) and setView(g.pc, pw, 0.0) then direct = ", view set on the car" end
                        end
                        g.reasserts, g.reassertAt, g.reassert = (g.reasserts or 0) + 1, now, false
                        U.logEvery("wreck.reassert" .. tostring(g.pnum), 6000, TAG,
                            "P%d spectate view restored (view was %s) -> %s (%s%s; %d)", g.pnum, clsName(vt),
                            nameOf(tgt), ok and "ok" or "call failed", direct, g.reasserts)
                    end
                end
            end
            g.prefApplied = true
        end
    end
    -- view guard
    if gmode == "off" then return end
    local bad, why, vt = camBad(g, sc)
    local recent = now - (g.appliedAt or -1e9) < 1000
    if gmode == "force" then
        local t = g.applied
        local tOut = U.ok(t) and not U.same(t, pawnOf(g.ps)) and not stillRacing(recOf(g.appliedPS or field(t, "PlayerState")))
        if (not U.ok(t) or tOut or not U.same(vt, t)) and not recent then
            applyFallback(g, lrs, not U.ok(t) and "force" or (tOut and "target out" or "view moved"), now)
        end
        return
    end
    if bad then
        g.badSince = g.badSince or now
        g.lastBad = why
        if now - g.badSince >= (tonumber(cfg.WreckCamBadMs) or 400) and not recent then
            applyFallback(g, lrs, why, now)
            g.badSince = nil
        end
        return
    end
    g.badSince = nil
    -- our fallback car stopped racing: move on to the next one (the native spectate retargets by itself)
    if U.ok(g.applied) and U.same(vt, g.applied) and not U.same(vt, pawnOf(g.ps)) and not recent
        and not stillRacing(recOf(g.appliedPS or field(vt, "PlayerState"))) then
        applyFallback(g, lrs, "fallback car out", now)
    end
end

-- FAST, every mode but "game": wreck edges of the local humans.
-- At the wreck edge, while another local human races (V-WD-18): a car-view player's native spectate is ended
-- (Client_OnSpectatorModeEnded 0x1470c9072: bIsSpectatorRunning 0, spectator camera destroyed, view on the own pawn,
-- OnSpectatorModeActivityChanged(false)), then the wreck camera is put back (or kept) for the hold.
local function wreckEdgeView(g)
    local vm = viewMode()
    g.useCar = vm == "carAll" or (vm == "car" and not U.same(g.pc, U.p1()))
    if guardMode() == "off" then g.useCar = false; return end
    if M.photoMode() then return end
    local vt0 = call0(g.pc, "GetViewTarget")
    local ended = false
    if g.useCar then
        local sc = field(g.pc, "SpectatorComponent")
        if U.ok(sc) and field(sc, "bIsSpectatorRunning") == true then
            ended = pcall(function() sc:Client_OnSpectatorModeEnded() end)
        end
    end
    local cam = holdMs() > 0 and crashCamOf(pawnOf(g.ps)) or nil
    -- 0.5.1 (crashcam.lua wiring): no hold of a guest crash camera that is unusable or not proven usable (it would put
    -- the same black camera back for WreckCrashCamHoldMs). Config-only fallback: WreckCrashCamHoldMs = 0.
    local cc, skipped = lazy("crashcam"), false
    if cam and cc and cc.crashCamBad then
        local okB, bad, why = pcall(cc.crashCamBad, g.pc)
        if okB and bad then
            U.log(TAG, "P%d wreck camera skipped: %s (crashcam.lua)", g.pnum, tostring(why))
            cam, skipped = nil, true
        end
    end
    local how = "none"
    if cam then
        if U.same(call0(g.pc, "GetViewTarget"), cam) then how = "kept"
        else how = setView(g.pc, cam, 0.0) and "put back" or "put back (call failed)" end
        g.crashCam, g.hadCrashCam = cam, true
    end
    U.log(TAG, "P%d wreck view: %s%s; wreck camera %s%s, then %s", g.pnum, "was " .. clsName(vt0),
        ended and ", the game's spectate ended" or "", how, cam and string.format(" for %.0f ms", holdMs()) or
        (skipped and " skipped" or (holdMs() > 0 and " (no CrashCam on the pawn)" or " (hold off)")), g.useCar and "a racing car" or "the game's spectate")
end

local function pollRacers(w, lrs, now)
    for _, e in ipairs(lrs) do
        local was = w.seen[e.key]
        w.seen[e.key] = e.wrecked
        if e.wrecked and was ~= true then
            local other
            for _, o in ipairs(lrs) do if o.key ~= e.key and o.racing then other = o end end
            local g = { pc = e.pc, ps = e.ps, rec = e.rec, pnum = e.pnum, key = e.key, since = now, probeIdx = 1 }
            -- the chain current at the wreck (a stale one, e.g. the race intro): never taken for the failed chain
            local flow = field(e.pc, "PlayerCinematicFlowComponent")
            g.chain0 = U.ok(flow) and U.key(field(flow, "CurrentCinematicChain")) or 0
            probe(g, "wreck")
            -- 0.13.0 v2: GALAXY RUN breaks a part of a wrecked player (live: bHasVehicleWrecked is clear again at the
            -- race end, so the run is told at the wreck itself)
            pcall(St.emit, "humanWrecked", e.pc)
            if other then
                w.guard[e.key] = g
                if e.pnum == 1 then w.p1Out = true end
                U.log(TAG, "P%d wrecked while P%d races: the race goes on, P%d spectates", e.pnum, other.pnum, e.pnum)
                U.tryEvery("wreck.edgeView", nil, TAG, wreckEdgeView, g)
            else
                U.log(TAG, "P%d wrecked, no other local human racing: the race ends natively", e.pnum)
            end
        end
    end
    for k, g in pairs(w.guard) do
        if not g.done then
            U.tryEvery("wreck.guardStep", nil, TAG, guardStep, w, g, lrs, now)
        elseif g.done ~= "logged" then
            g.done = "logged"
            U.dbg(TAG, "P%d view guard ended (%d fallback(s))", g.pnum, g.fallbacks or 0)
        end
        if g.done and not U.ok(g.pc) then w.guard[k] = nil end
    end
end

---------------------------------------------------------------------------------------------------- loops
local function split(lrs)
    if St.race.singleView == true or #lrs < 2 then return false end
    local present = lazy("present")
    if present and present.isSingleView then
        local ok, s = pcall(present.isSingleView)
        if ok and s == true then return false end
    end
    return true
end

-- FAST loop (main.lua, race phases).
function M.fastTick()
    if St.phase ~= "RACING" then
        -- the race ended (results) during an emulated slow-mo: real time back, never left at 0.1
        local w0 = St.wreck
        if type(w0) == "table" and w0.emu then U.tryEvery("wreck.emuStop", nil, TAG, emuStop, w0, "stopped: race over", true) end
        return
    end
    local w = W()
    local m = mode()
    if w.emuReset == nil and restoredEmu then
        -- hot reload during an emulated slow-mo (restoreShared): the new Lua state does not know our last write
        w.emuReset, restoredEmu = true, false
        local d, ws = dilation()
        if ws and type(d) == "number" and d < 0.999 then
            pcall(function() ws.CinematicTimeDilation = 1.0 end)
            U.log(TAG, "hot reload during an emulated slow-mo: CinematicTimeDilation %.2f put back to 1.0", d)
        end
    end
    -- U.tryEvery: a persistent fault in this 33 ms loop must not print a traceback every tick (main.lua's throttle
    -- only sees errors that reach it)
    U.tryEvery("wreck.guardTimeout", nil, TAG, M.guardTimeout)
    if m == "game" then
        if w.slowOff or w.infHealth then U.tryEvery("wreck.restoreCvars", nil, TAG, M.restoreCvars, "WreckMode game") end
        return
    end
    local lrs = localRacers()
    if #lrs == 0 then return end
    local now = St.nowMs()
    -- wreck edges first: slowMoTick's "last" hold sees this tick's new guard entry (no 33 ms cvar flip at the wreck)
    if #lrs >= 2 then
        -- motion first: a wreck edge in this tick already knows which cars move (run E: the watched car was parked)
        if m == "spectate" then U.tryEvery("wreck.motion", nil, TAG, sampleMotion, w, now) end
        U.tryEvery("wreck.pollRacers", nil, TAG, pollRacers, w, lrs, now)
        U.tryEvery("wreck.slowMoEmu", nil, TAG, slowMoEmuTick, w, now)
    elseif w.emu then
        U.tryEvery("wreck.slowMoEmu", nil, TAG, slowMoEmuTick, w, now)   -- finish a running curve
    end
    U.tryEvery("wreck.slowMo", nil, TAG, slowMoTick, w, lrs, split(lrs), now)
    if m == "noWreck" then U.tryEvery("wreck.noWreck", nil, TAG, noWreckTick, w, lrs) end
end

-- MAIN loop (main.lua, race phases): backup of the timeout guard (the 2 s window is 8 MAIN ticks), build re-check.
-- 0.13.0: the race flow follows P1. When P1 is wrecked (or finishes) while guests race, CSM_RF_PostRacePhase /
-- LocalResults run BP_Csm_Mix_PostEvent = FuseMixingControlSubsystem:SetActiveMix(CBM_PostEvent): the post-race mix
-- ducked every race sound for the players still racing (live 19:40 / 20:01: "music and all the other sfx not present").
-- While a human still races, CBM_PostEvent is replaced by the mix P1 raced with (CBM_Race). Pause / photo / other
-- mixes are left alone.
local MIX = { race = nil, world = -1, fixed = 0 }
local MIX_RACE = "/Game/Griffin/Audio/Mixing/Control/CBM_Race.CBM_Race"
local function mixTick()
    if cfg.WreckKeepRaceMix == false then return end
    if MIX.world ~= St.worldGen then MIX.race, MIX.world, MIX.fixed = nil, St.worldGen, 0 end
    local rs = localRacers()
    if #rs < 2 then return end
    local sub = FindFirstOf("FuseMixingControlSubsystem")
    if not U.ok(sub) then return end
    local am = sub.ActiveMix
    local amName = U.ok(am) and am:GetFName():ToString() or ""
    local p1, guests = rs[1], false
    for i = 2, #rs do if rs[i].racing then guests = true end end
    if p1.racing then
        if amName == "CBM_Race" then MIX.race = am end
        return
    end
    if not guests or amName ~= "CBM_PostEvent" then return end
    local race = MIX.race
    if not U.ok(race) then local ok, o = pcall(StaticFindObject, MIX_RACE); race = ok and o or nil end
    if not U.ok(race) then return end
    sub:SetActiveMix(race)
    MIX.fixed = MIX.fixed + 1
    U.logEvery("wreck.mix", 5000, TAG, "P1 out, guests still racing: the post-race mix CBM_PostEvent replaced by %s "
        .. "(%d time(s) this race) (V-WR-MIX)", race:GetFName():ToString(), MIX.fixed)
end

function M.tick()
    local w = W()
    if St.phase ~= "RACING" then return end
    U.tryEvery("wreck.guardTimeout", nil, TAG, M.guardTimeout)
    U.tryEvery("wreck.mixTick", nil, TAG, mixTick)
    if mode() == "noWreck" and opt(cfg.NoWreckMethod, { "build", "cvar", "topup" }, "build") == "build" then
        U.tryEvery("wreck.noWreckRecheck", nil, TAG, noWreckRecheck, w, localRacers())
    end
end

function M.clear(why)
    U.try(TAG, M.restoreCvars, why)
    local w = W()
    if w.emu then U.try(TAG, emuStop, w, "stopped: " .. tostring(why), true) end
    w.guard, w.seen, w.build, w.motion, w.badCam = {}, {}, {}, {}, {}
    w.hideRemaining, w.p1Out = false, false
    local cc = lazy("chasecam")
    if cc then U.try(TAG, cc.releaseAll, why) end              -- 0.6.0: the chase rigs (camera actors) go too
end

-- For hud.lua / present.lua (wiring): how a wrecked local player's view is run, or nil (not wrecked / no guard).
-- {pnum, phase = "crash"|"car"|"native", targetPS, targetPawn, photo}
function M.viewInfo(pc)
    local w = St.wreck
    if type(w) ~= "table" or type(w.guard) ~= "table" or not U.ok(pc) then return nil end
    local g = w.guard[U.key(pc)]
    if not g or g.done then return nil end
    return { pnum = g.pnum, phase = g.crashCam and "crash" or (g.useCar and "car" or "native"), targetPS = g.carPS,
             targetPawn = g.car, viewActor = g.view, photo = g.photo == true }
end

---------------------------------------------------------------------------------------------------- diag (F9)
local function fmtNum(v, f)
    if type(v) ~= "number" then return tostring(v) end
    return string.format(f or "%.2f", v)
end

-- diag.dump() section. Read-only (getters and property reads; no registration, no write).
function M.dump()
    local w = W()
    local out = function(f, ...) U.log("diag", f, ...) end
    out("wreck: mode=%s grace=%s slowMo=%s noWreck=%s cinematic=%s viewGuard=%s/%s target=%s standalone=%s",
        mode(), tostring(cfg.FinishGraceSec), tostring(cfg.WreckSlowMo), tostring(cfg.NoWreckMethod),
        tostring(cfg.WreckCinematic), tostring(cfg.WreckViewGuard), tostring(cfg.WreckViewFallback),
        tostring(cfg.WreckSpectateTarget), tostring(w.standalone))
    local ph, phWhy = M.photoMode()
    out("  run E: view=%s hold=%.0f ms slowMo(eff)=%s emulate=%s emu=%s photo=%s (%s) fadeFields=%s%s%s",
        viewMode(), holdMs(), slowMoMode(), tostring(cfg.WreckSlowMoEmulate ~= false),
        w.emu and string.format("P%d %.1fs last=%s", w.emu.pnum, (St.nowMs() - w.emu.start) / 1000, tostring(w.emu.last))
        or "-", tostring(ph), tostring(phWhy), tostring(fadeReg.ok), fadeReg.bad and " untrusted" or "",
        fadeReg.verified and " verified" or "")
    local gs, gm = U.gs(), U.gm()
    if U.ok(gs) and field(gs, "RaceTimeoutTime") ~= nil then
        local T, now = field(gs, "RaceTimeoutTime"), serverNow(gs)
        local armed = (reg.prop == true) and U.ok(gm) and field(gm, ARMED_PROP) or "n/a"
        out("  timeout: T=%s now=%s remaining=%s byte=%s (reg=%s %s sawZero=%s verified=%s err=%s) finished=%s",
            fmtNum(T), fmtNum(now), (type(T) == "number" and type(now) == "number" and T > 0) and fmtNum(T - now) or "-",
            tostring(armed), tostring(reg.prop), tostring(reg.how), tostring(reg.sawZero), tostring(reg.verified),
            tostring(reg.err),
            tostring(field(gs, "bIsRaceFinished")))
        out("  guard: disarms=%d last=%s (%s) graceSet=%s hideRemaining=%s p1Out=%s topups=%d dilationResets=%d",
            w.disarms, tostring(w.lastDisarm), tostring(w.lastDisarmWhy), tostring(w.graceSet),
            tostring(w.hideRemaining), tostring(w.p1Out), w.topups, w.dilationResets)
        local rules = U.ok(gm) and field(gm, "ModeRules") or nil
        out("  mode rules: %s (V-WD-10)", clsName(rules))
        local i = 0
        eachRacer(gs, function(ps)
            i = i + 1
            local rec = recOf(ps)
            if not rec then out("  racer %d %s: no RaceEventComponent", i, nameOf(ps)); return end
            out("  racer %d %s%s: racing=%s wrecked=%s finished=%s time=%s fail=%s hp=%s/%s pos=%s useHealth=%s", i,
                nameOf(ps), isBot(ps) and " (bot)" or "", tostring(stillRacing(rec)),
                tostring(field(rec, "bHasVehicleWrecked")), tostring(field(rec, "bHasFinishedEvent")),
                fmtNum(field(rec, "EventFinishTime")), tostring(field(rec, "FailReasons")),
                tostring(field(rec, "VehicleHealth")), tostring(field(rec, "StartingVehicleHealth")),
                tostring(field(rec, "EventPosition")), tostring(call0(rec, "ShouldUseHealth")))
        end)
    else
        out("  timeout: no racing GameState")
    end
    for _, e in ipairs(localRacers()) do
        local g = w.guard[e.key] or { pc = e.pc, ps = e.ps, pnum = e.pnum }
        local sc = field(e.pc, "SpectatorComponent")
        local bad, why = camBad(g, sc)
        out("  P%d: racing=%s wrecked=%s view=%s camBad=%s (%s) guard=%s fallbacks=%s cineEnded=%s specAsked=%s "
            .. "useCar=%s carSets=%s reapplies=%s fadeClears=%s blindFades=%s", e.pnum, tostring(e.racing),
            tostring(e.wrecked), clsName(call0(e.pc, "GetViewTarget")), tostring(bad), tostring(why),
            w.guard[e.key] and (g.done and "done" or "on") or "-", tostring(g.fallbacks), tostring(g.cineEnded),
            tostring(g.specAsked), tostring(g.useCar), tostring(g.carSets), tostring(g.reapplies),
            tostring(g.fadeClears), tostring(g.blindFades))
        probe(g, "F9")
    end
    local d = dilation()
    local present = lazy("present")
    local csm = {}
    if present and present.stateActive then
        for _, n in ipairs({ "CSM_RF_Spectating", "CSM_RF_SpectatingInProgress", "CSM_RF_LocalResults" }) do
            local ok, v = pcall(present.stateActive, n)
            csm[#csm + 1] = n:gsub("^CSM_RF_", "") .. "=" .. tostring(ok and v)
        end
    end
    local saved = {}
    for k, v in pairs(w.saved) do saved[#saved + 1] = k .. "=" .. tostring(v) end
    out("  dilation=%s %s=%s %s=%s saved{%s} csm{%s}", tostring(d), CV_SLOWMO, tostring(U.cvarInt(CV_SLOWMO)),
        CV_INFHEALTH, tostring(U.cvarInt(CV_INFHEALTH)), table.concat(saved, ","), table.concat(csm, ","))
end

---------------------------------------------------------------------------------------------------- hot reload
function M.persistShared(put)
    local parts = {}
    for k, v in pairs(W().saved) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    put("wreck.saved", table.concat(parts, ";"))
    put("wreck.emu", W().emu and "1" or "")                  -- an emulated slow-mo in progress (dilation < 1)
end

function M.restoreShared(get)
    if get("wreck.emu") == "1" then restoredEmu = true end    -- fastTick puts the dilation back to 1.0
    local v = get("wreck.saved")
    if type(v) ~= "string" or v == "" then return end
    local w = W()
    for name, val in v:gmatch("([^;=]+)=([^;]+)") do
        local n = tonumber(val)
        if n then w.saved[name] = n end
    end
    U.log(TAG, "hot reload: saved user cvar values restored (%s)", v)
end

---------------------------------------------------------------------------------------------------- init
local inited = false
function M.init()
    if inited then return end
    inited = true
    W()
    St.on("leaving", TAG, function() M.clear("leaving") end)
    St.on("phase", TAG, function(new)
        if new == "FRONTEND" or new == "OTHER" then M.clear("front end") end
    end)
    U.log(TAG, "init: WreckMode=%s FinishGraceSec=%s WreckSlowMo=%s (effective %s, emulate %s) NoWreckMethod=%s "
        .. "WreckViewGuard=%s WreckView=%s (effective %s) hold=%.0f ms WreckCarCam=%s", mode(),
        tostring(cfg.FinishGraceSec), tostring(cfg.WreckSlowMo), slowMoMode(), tostring(cfg.WreckSlowMoEmulate ~= false),
        tostring(cfg.NoWreckMethod), tostring(cfg.WreckViewGuard), tostring(cfg.WreckView), viewMode(), holdMs(),
        (lazy("chasecam") and lazy("chasecam").mode()) or "chasecam.lua missing")
end

return M
