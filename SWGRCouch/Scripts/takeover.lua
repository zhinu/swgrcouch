-- SWGRCouch · takeover.lua (G6 Racer assignment)
-- Fallback racer assignment (ARCHITECTURE §3): a human PC the race left without a vehicle takes over an AI
-- racer and ADOPTS its PlayerState, so results, position, lap, abilities and the Racers/Vehicles bookkeeping
-- stay on a real racer entry. Reverse of the game's own human->AI disconnect switch. SERVER ONLY: every public
-- function returns at once on a client, except racerPSFor and recordFor.
--
-- Verified signatures (scripts/reflect-func-all.py on the shipping exe; enums are integers, the
-- "Byte UnderlyingType" line is the enum's inner property, not an argument):
--   ARacingGameState:FindRacerIndexByPlayer(Object player) -> Int               0x54020401
--   AVehiclePawn:WasSpawnedForCinematic() -> Bool / IsUnderCinematicControl() -> Bool
--   AVehiclePawn:GetOriginalInputSource() -> Enum / GetCurrentInputSource() -> Enum
--   AVehiclePawn:GetInputSourceOverrides() -> TArray<Enum> (array RETURN)        0x54020401
--   AVehiclePawn:Start/StopInputSourceOverride_OnServer(Enum reason)             0x4020401 (not an RPC)
--   AVehiclePawn:SetInputSource_OnServer(Enum source)                            0x4020401 (not an RPC)
--   AController:Possess(Object InPawn) 0x4020407 (BlueprintAuthorityOnly) / UnPossess() 0x4020403
--   AActor:SetOwner(Object NewOwner) / ForceNetUpdate() / K2_DestroyActor()
--   APlayerController:SetViewTargetWithBlend(Object, Float BlendTime, Byte BlendFunc, Float BlendExp, Bool)
--   UPlayerRaceEventComponent:Server_Cheat_FinishRace(Bool abandonedRace)          0x4220cc0 (NetServer RPC)
--   UPlayerRaceEventComponent:IsStillRacing() -> Bool
--   URaceAIComponent:SetBehaviour(Enum behaviour)                                  0x4020401
--   UVehicleResetComponent:Client_BindInputActions()                               0x1040cc1 (NetClient RPC)
--   UPlayerSpectatorComponent:Client_OnSpectatorModeEnded()                        0x1040cc1 (NetClient RPC)
--   UGameplayStatics:RemovePlayer(Object Player, Bool bDestroyPawn)                0x4022403
--   *WorldSubsystem:RegisterLocalPlayerControlledPawn(Object InPawn)               0x4020401
--   ARacingGameMode:OnPlayerControllerDestroyed(Object playerController)           0x20401 (native, hooked)
-- Properties: ARacingGameState.Vehicles/Racers/bIsRaceStarted, APawn.Controller/PlayerState, AController.PlayerState/Pawn,
--   AVehiclePawn.PlayerInputComponent/RaceAIComponent/ResetComponent, UPlayerInputComponent.RawInputSubsystem
--   (WeakObject), AGfnPlayerController.RawInputSubsystem @+0x8d8 / SpectatorComponent @+0x898,
--   UPlayerSpectatorComponent.bIsSpectatorRunning (Bool), UPlayerRaceEventComponent.bHasFinishedEvent (Bool)
--   / EventPosition (Int), AGfnPlayerState.RaceEventComponent, APlayerState.bIsABot (Bool).

local C     = require("consts")
local cfg   = require("config")
local St    = require("state")
local U     = require("util")
local sched = require("sched")

local M = {}
local TAG = "takeover"

local E = C.E
-- Overrides that force AI and must go for a human to drive (§3.3 step 4).
local STOP_OVERRIDES = {
    [E.Override.SpawnAI] = true, [E.Override.Disconnect] = true,
    [E.Override.Debug] = true, [E.Override.Autopilot] = true,
}
-- Overrides the game itself manages on human cars; left alone, and accepted by verify().
local LEGIT_OVERRIDES = {
    [E.Override.RollingStart] = true, [E.Override.TakedownCam] = true,
    [E.Override.FinishedRace] = true, [E.Override.Reset] = true,
}
local AUDIO_SUBSYSTEMS = { "PassbyWorldSubsystem", "OvertakeWorldSubsystem", "AudioNonPlayerProximityWorldSubsystem" }

-- Config keys (defined in config.lua; the functions below also tolerate a missing or unknown value):
--   cfg.TakeoverAICarTest          = "original" | "override"        VERIFY(V-TKO-02)
--   cfg.TakeoverEndSpectateRemote  = "joiner" | "always" | "off"    VERIFY(V-TKO-11)  (true = "joiner", false = "off")
local function aiCarTest()
    local v = cfg.TakeoverAICarTest
    if v == "override" then return "override" end
    return "original"
end
local function endSpectateRemoteMode()
    local v = cfg.TakeoverEndSpectateRemote
    if v == false or v == "off" then return "off" end
    if v == "always" then return "always" end
    return "joiner"                                    -- nil / true / "joiner"
end

-- Scalars only (no UObjects): "countdown" mode stability counter.
-- uncarriedSent: PlayerState address -> true (finishIdlePlayerStates, once per race)
local RACE_PHASE = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }
local priv = { lastVehCount = -1, stablePolls = 0, carLogged = {}, uncarriedSent = {} }   -- carLogged: car address -> true
-- Hot reload: records to re-find (set by restoreShared, consumed by the first tick); defined further down.
local pendingRestore = nil   -- {world = key, list = {strings}}
local finishRestore          -- function(gs)

-- ---------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------

local function server()
    local ok, res = pcall(U.isServer)
    return ok and res == true
end

local function nameOf(o)
    if not U.ok(o) then return "<invalid>" end
    local ok, s = pcall(function() return U.str(o:GetFName()) end)
    return ok and s or "?"
end

local function isLocal(pc)
    local ok, res = pcall(U.callMethod, pc, "IsLocalController")
    return ok and res == true
end

-- Race GameState with a built grid, or nil.
local function raceGS()
    local gs = U.gs()
    if not U.ok(gs) or not U.isA(gs, "RacingGameState") then return nil end
    local ok, n = pcall(function() return gs.Vehicles:GetArrayNum() end)
    if not ok or type(n) ~= "number" or n <= 0 then return nil end
    return gs, n
end

-- Snapshot of the car's override stack as a Lua array of integers.
-- VERIFY(V-CORE-08): GetInputSourceOverrides returns a TArray<enum> by value; U.arrayToTable unwraps it.
local function overridesOf(car)
    local out = {}
    local ok, err = pcall(function()
        local t = U.arrayToTable(car:GetInputSourceOverrides())
        for i = 1, #t do
            local v = t[i]
            if type(v) == "number" then out[#out + 1] = math.tointeger(v) or v end
        end
    end)
    if not ok then U.logEvery("tko_ovr", 5000, TAG, "GetInputSourceOverrides failed: %s", tostring(err)) end
    return out
end

-- Read a WeakObject property as a UObject (FWeakObjectPtr:Get()), tolerating a plain object.
local function weakGet(v)
    if v == nil then return nil end
    local ok, o = pcall(U.callMethod, v, "Get")
    if ok and o ~= nil then return o end
    return v
end

local function racePos(ps)
    local ok, p = pcall(function() return ps.RaceEventComponent.EventPosition end)
    return (ok and type(p) == "number") and p or -1
end

local function hasFinished(ps)
    local ok, f = pcall(function() return ps.RaceEventComponent.bHasFinishedEvent end)
    return ok and f == true
end

-- ---------------------------------------------------------------------------------------------
-- records
-- ---------------------------------------------------------------------------------------------

function M.recordFor(pc)
    if pc == nil then return nil end
    local k = U.key(pc)
    if k == 0 then return nil end
    return St.takeovers[k]
end

-- The PlayerState that races for this PC: the adopted/AI racer PS when a record exists (server only); else, with
-- cfg.RacerPSSource = "pawn" (default), the PlayerState of the vehicle the PC possesses, else pc.PlayerState.
-- Pawn first because records exist only on the server: on a client whose car the host took over with adoption, the
-- host's raw `pc.PlayerState = aiPS` write may not replicate (push model / Iris), while APawn.PlayerState is set
-- natively in PossessedBy and replicated [PS§6]. For a native-slot car both are the same PlayerState.
-- VERIFY(V-TKO-05): on a client after a host takeover, pc.Pawn.PlayerState is the racer PS (HUD lap/position and
-- name tags follow it); fallback cfg.RacerPSSource = "controller" (the old pc.PlayerState behaviour).
function M.racerPSFor(pc)
    if pc == nil then return CreateInvalidObject() end
    local rec = M.recordFor(pc)
    if rec and U.ok(rec.aiPS) then return rec.aiPS end
    if cfg.RacerPSSource ~= "controller" and U.ok(pc) then
        -- couch-racegc: the car from U.carOf (one pc.Pawn read per loop run), no closure per call
        local car = U.carOf(pc)
        if car then
            local ok, p = pcall(U.getField, car, "PlayerState")   -- APawn.PlayerState (replicated)
            if ok and U.ok(p) then return p end
        end
    end
    return pc.PlayerState                              -- invalid object when pc is invalid: safe to chain
end

-- ---------------------------------------------------------------------------------------------
-- §3.2 car pick
-- ---------------------------------------------------------------------------------------------

function M.pickCar(gs)
    if not server() then return nil end
    if not U.ok(gs) or not U.isA(gs, "RacingGameState") then return nil end
    local cars = gs.Vehicles                           -- ARacingGameState.Vehicles (never FindAllOf: cinematic cars exist)
    local okn, n = pcall(U.callMethod, cars, "GetArrayNum")
    if not okn or type(n) ~= "number" then return nil end
    local best, bestPos = nil, -math.huge
    local test = aiCarTest()
    local rejected = {}                                -- scalars only: { key, name, orig, cur, ovr, why }
    for i = 1, n do
        U.try(TAG, function()
            local car = cars[i]
            if not U.ok(car) then return end
            if St.takeoversByCar[U.key(car)] then return end
            if car:WasSpawnedForCinematic() == true then return end
            if car:IsUnderCinematicControl() == true then return end
            if U.isPlayerController(car.Controller) then return end
            local ps = car.PlayerState
            if not U.ok(ps) or not U.isA(ps, "GfnPlayerState") then return end
            local orig, cur = -1, -1
            pcall(function() orig = car:GetOriginalInputSource() end)
            pcall(function() cur = car:GetCurrentInputSource() end)
            local isAI
            if test == "override" then
                -- fallback: an AI car is one forced to AI by the SpawnAI override and whose PS is a bot
                -- (a human's car left to the AI carries Disconnect, and its PS has bIsABot == false)
                local hasSpawnAI = false
                local ov = overridesOf(car)
                for j = 1, #ov do if ov[j] == E.Override.SpawnAI then hasSpawnAI = true end end
                isAI = hasSpawnAI and ps.bIsABot == true
                if not isAI then
                    rejected[#rejected + 1] = { U.key(car), nameOf(car), orig, cur, table.concat(ov, ","),
                        "no SpawnAI override or PS not a bot" }
                    return
                end
            else
                -- a human car under an AI override reports AI as CURRENT source, never as ORIGINAL source
                -- VERIFY(V-TKO-02): AI racers report GetOriginalInputSource()==AI
                --   (fallback: cfg.TakeoverAICarTest = "override")
                isAI = (orig == E.InputSource.AI)
                if not isAI then
                    if not priv.carLogged[U.key(car)] then
                        rejected[#rejected + 1] = { U.key(car), nameOf(car), orig, cur,
                            table.concat(overridesOf(car), ","), "original source not AI" }
                    end
                    return
                end
            end
            if hasFinished(ps) then return end
            if cfg.TakeoverPick == "first" then
                if best == nil then best, bestPos = car, racePos(ps) end
                return
            end
            local pos = racePos(ps)                    -- "last": highest EventPosition = least disruptive
            if best == nil or pos > bestPos then best, bestPos = car, pos end
        end)
    end
    if best == nil then
        U.logEvery("tko_nocar", 5000, TAG, "no free AI car among %d vehicles (test=%s)", n, test)
        -- once per car per world: what the AI-car test saw (V-TKO-02)
        for _, r in ipairs(rejected) do
            if r[1] ~= 0 and not priv.carLogged[r[1]] then
                priv.carLogged[r[1]] = true
                U.log(TAG, "  rejected %s: original=%s current=%s overrides={%s} (%s)",
                    r[2], tostring(r[3]), tostring(r[4]), r[5], r[6])
            end
        end
    else
        U.dbg(TAG, "pickCar -> %s (position %d, pick=%s)", nameOf(best), bestPos, tostring(cfg.TakeoverPick))
    end
    return best
end

-- ---------------------------------------------------------------------------------------------
-- §3.3 takeover, exact order
-- ---------------------------------------------------------------------------------------------

-- Each numbered step runs in its own U.try and is logged, so the first runtime session shows which step
-- the game needs and which one fails (V-TKO-01).
-- COUCH CAMPAIGN: the reason no takeover may happen in this world (couch.takeoverBlocked: a campaign race), or nil.
-- The ONE guard of every path that hands a human an AI car (tick, forceAll / Ctrl+F6, join's mid-race F6 -> takeOver):
-- possessing a campaign AI car crashes the game natively (exe+0x641579 null+0xdf0, live 2026-10-14 twice).
local function blockedHere()
    local ok, why = pcall(function() return U.mod("couch").takeoverBlocked() end)
    if ok and type(why) == "string" then return why end
    return nil
end
M.blockedHere = blockedHere

local function step(rec, label, fn)
    local ok = U.try(TAG, fn)
    U.dbg(TAG, "  step %s %s", label, ok and "ok" or "FAILED")
    if not ok then rec.failedSteps[#rec.failedSteps + 1] = label end
    return ok
end

function M.takeOver(pc, car)
    if not server() then return nil end
    if cfg.SlotMode == "off" then
        U.logEvery("tko_off", 5000, TAG, "takeover disabled (cfg.SlotMode = off)")
        return nil
    end
    if not U.ok(pc) then U.warn(TAG, "takeOver: invalid PC"); return nil end
    local existing = M.recordFor(pc)
    if existing then return existing end
    if not U.ok(car) then
        U.logEvery("tko_nocar_" .. tostring(U.key(pc)), 5000, TAG, "takeOver %s: no AI car available", nameOf(pc))
        return nil
    end
    if St.takeoversByCar[U.key(car)] then U.warn(TAG, "takeOver: car %s already taken", nameOf(car)); return nil end
    local blocked = blockedHere()
    if blocked then
        U.logEvery("tko_blocked_" .. tostring(U.key(pc)), 30000, TAG,
            "takeOver %s refused: %s (no AI takeover there: the game crashes natively; he spectates)", nameOf(pc), blocked)
        return nil
    end

    local rec = {
        pc = pc, car = car, aiPS = car.PlayerState, aiCtrl = car.Controller, ownPS = pc.PlayerState,
        adopted = false, aiCtrlHadPS = false, isLocal = isLocal(pc), atMs = St.nowMs(),
        idleAI = false, botFlagCleared = false, finishSent = false, verifyStage = 0, failedSteps = {},
        hadNonVehiclePawn = false,
    }
    pcall(function() rec.hadNonVehiclePawn = U.ok(pc.Pawn) and not U.isVehicle(pc.Pawn) end)
    -- addresses for the hot-reload persistence (OnUnload may not call UObject methods)
    rec.keys = { pc = U.key(pc), car = U.key(car), aiPS = U.key(rec.aiPS), aiCtrl = U.key(rec.aiCtrl),
                 ownPS = U.key(rec.ownPS) }
    -- VERIFY(V-TKO-03): does the AI controller hold the racer PS (aiCtrl.PlayerState == car.PlayerState)?
    rec.aiCtrlHadPS = U.ok(rec.aiCtrl) and U.same(rec.aiCtrl.PlayerState, rec.aiPS)
    U.log(TAG, "takeOver %s (%s) -> car %s, aiPS %s, aiCtrl %s, aiCtrlHadPS=%s, pos %d",
        nameOf(pc), rec.isLocal and "local" or "remote", nameOf(car), nameOf(rec.aiPS), nameOf(rec.aiCtrl),
        tostring(rec.aiCtrlHadPS), racePos(rec.aiPS))

    -- 0. a late PC may own a non-vehicle default pawn (SpawnDefaultPawnFor): drop it
    step(rec, "0 drop default pawn", function()
        local old = pc.Pawn
        if U.ok(old) and not U.isVehicle(old) then
            pc:UnPossess()
            old:K2_DestroyActor()
        end
    end)
    -- 1. detach the AI controller; the idle AI controller must never destroy the racer PS
    step(rec, "1 AI unpossess", function()
        if U.ok(rec.aiCtrl) then rec.aiCtrl:UnPossess() end
        if rec.aiCtrlHadPS then rec.aiCtrl.PlayerState = nil end
    end)
    -- 2. adopt the racer PlayerState (raw property write + owner)
    if cfg.TakeoverAdoptPS then
        step(rec, "2 adopt PS", function()
            pc.PlayerState = rec.aiPS
            rec.aiPS:SetOwner(pc)
            rec.adopted = true
            -- VERIFY(V-TKO-03): the raw write of AController.PlayerState must read back
            if not U.same(pc.PlayerState, rec.aiPS) then
                U.warn(TAG, "adopt: pc.PlayerState did not read back as aiPS (fallback: cfg.TakeoverAdoptPS=false)")
            end
        end)
    end
    -- 3. possess: APawn::PossessedBy copies pc.PlayerState onto the car -> OnPawnSet (abilities, passives)
    if not step(rec, "3 possess", function() pc:Possess(car) end) then
        -- nothing drives the car now: register the record so release() restores the AI in the exact order
        St.takeovers[U.key(pc)] = rec
        St.takeoversByCar[U.key(car)] = rec
        U.err(TAG, "takeOver %s: Possess failed, handing the car back to the AI", nameOf(pc))
        M.release(rec)
        return nil
    end
    -- 4. stop only the AI-forcing overrides the car really carries (read, never assume)
    step(rec, "4 stop overrides", function()
        local ov = overridesOf(car)                    -- VERIFY(V-TKO-02): which overrides an AI car carries
        U.log(TAG, "  overrides before: {%s}", table.concat(ov, ","))
        for i = 1, #ov do
            local r = ov[i]
            if STOP_OVERRIDES[r] then car:StopInputSourceOverride_OnServer(r) end
        end
    end)
    -- 5. the car reads the human input source
    step(rec, "5 input source", function() car:SetInputSource_OnServer(E.InputSource.Player) end)
    -- 6. camera
    step(rec, "6 view target", function() pc:SetViewTargetWithBlend(car, 0.0, E.ViewBlend.Linear, 0.0, false) end)
    -- 7. push the new state to a remote owner now
    -- VERIFY(V-TKO-05): the raw PlayerState write replicates to the client (PC.PlayerState == Pawn.PlayerState there)
    step(rec, "7 net update", function()
        if not rec.isLocal then pc:ForceNetUpdate(); car:ForceNetUpdate() end
    end)
    -- 8. a mid-game joiner may sit in spectator mode.
    --    bIsSpectatorRunning has no Net flag and spectator mode is driven by NetClient RPCs, so the server's copy
    --    is meaningful only for the host's own local PCs. For a remote PC the server cannot read the client's
    --    state and decides from what it knows (mid-game joiner, late join allowed, arrived after the start,
    --    owned a spectator/default pawn before step 0).
    step(rec, "8 end spectate", function()
        local sc = pc.SpectatorComponent
        if not U.ok(sc) then return end
        if rec.isLocal then
            if sc.bIsSpectatorRunning == true then sc:Client_OnSpectatorModeEnded() end
            return
        end
        local mode = endSpectateRemoteMode()
        if mode == "off" then return end
        local why = nil
        if mode == "always" then
            why = "always"
        else
            local roster = U.mod("roster")
            local fs = roster.firstSeenMs(pc)
            if roster.isMidGameJoiner(pc) then why = "mid-game joiner"
            elseif St.net.lateJoinAllowed == true then why = "late join allowed"
            elseif rec.hadNonVehiclePawn then why = "had a non-vehicle pawn"
            elseif St.race.started == true and (St.race.startedAtMs or 0) > 0 and fs ~= nil
                and fs >= St.race.startedAtMs then why = "arrived after the start"
            end
        end
        if why then
            -- VERIFY(V-TKO-11): Client_OnSpectatorModeEnded (NetClient Reliable) sent to a remote client that is
            -- not spectating must be harmless; fallback cfg.TakeoverEndSpectateRemote = "off" (or "always").
            sc:Client_OnSpectatorModeEnded()
            U.log(TAG, "  remote %s: Client_OnSpectatorModeEnded sent (%s)", nameOf(pc), why)
        end
    end)
    if cfg.TakeoverClearBotFlag then
        step(rec, "bot flag", function()
            if U.ok(rec.aiPS) and rec.aiPS.bIsABot == true then
                rec.aiPS.bIsABot = false
                rec.botFlagCleared = true
            end
        end)
    end
    -- 9. records
    St.takeovers[U.key(pc)] = rec
    St.takeoversByCar[U.key(car)] = rec

    St.emit("status", "TAKEOVER: " .. string.upper(nameOf(pc)) .. " DRIVES AN AI CAR")
    sched.after(TAG, 1000, function() M.verify(rec) end)
    if cfg.ReRegisterP1Pawn and rec.isLocal then M.reRegisterP1Pawn() end
    return rec
end

-- ---------------------------------------------------------------------------------------------
-- verification and escalations (1 s after the takeover; a second pass only after an escalation)
-- ---------------------------------------------------------------------------------------------

function M.verify(rec)
    if not server() or type(rec) ~= "table" then return end
    if St.takeovers[U.key(rec.pc)] ~= rec then return end         -- released meanwhile
    if not U.ok(rec.pc) or not U.ok(rec.car) then return end
    rec.verifyStage = rec.verifyStage + 1
    local pc, car = rec.pc, rec.car

    local src = -1
    pcall(function() src = car:GetCurrentInputSource() end)
    local ov = overridesOf(car)
    local onlyLegit = true
    for i = 1, #ov do if not LEGIT_OVERRIDES[ov[i]] then onlyLegit = false end end
    local sourceOk = (src == E.InputSource.Player) or (#ov > 0 and onlyLegit)

    local racerIdx = -1
    pcall(function()
        local gs = U.gs()
        if U.ok(gs) and U.isA(gs, "RacingGameState") then racerIdx = gs:FindRacerIndexByPlayer(pc.PlayerState) end
    end)
    local psOnCar = false
    pcall(function() psOnCar = U.same(car.PlayerState, pc.PlayerState) end)

    -- local PCs: the car's input must come from this player's own raw input subsystem
    local inputOk = nil
    if rec.isLocal then
        pcall(function()
            local carRaw = weakGet(car.PlayerInputComponent.RawInputSubsystem)
            inputOk = U.same(carRaw, pc.RawInputSubsystem)
        end)
    end

    U.log(TAG, "verify#%d %s: source=%s overrides={%s} racerIdx=%s psOnCar=%s input=%s failedSteps={%s}",
        rec.verifyStage, nameOf(pc), tostring(src), table.concat(ov, ","), tostring(racerIdx), tostring(psOnCar),
        inputOk == nil and "n/a" or tostring(inputOk), table.concat(rec.failedSteps, ","))
    if rec.adopted and racerIdx < 0 then
        -- VERIFY(V-TKO-04): with adoption the human PC must be found as a racer
        U.warn(TAG, "adopted PS is not found by FindRacerIndexByPlayer (HUD/position may be wrong)")
    end

    local escalated = false
    -- AI still steering -> idle the car's AI brain (undone with Racing on release)
    if not sourceOk and cfg.TakeoverIdleAI and not rec.idleAI then
        if U.try(TAG, function() car.RaceAIComponent:SetBehaviour(E.AIBehaviour.Idle) end) then
            rec.idleAI = true; escalated = true
            U.log(TAG, "  escalation: RaceAIComponent:SetBehaviour(Idle)")
        end
    end
    -- Remote PC (a client's P1 or its child-connection guest): the server cannot read the client's input binding, so
    -- the NetClient RPC Client_BindInputActions (flags 0x1040cc1) is sent once, unconditionally. After pc:Possess(car)
    -- APawn::PossessedBy made that PC the car's owner, so the RPC runs on exactly the client whose pad drives the car.
    -- VERIFY(V-TKO-12): a remote player drives a taken-over car (relisten_takeover / lateJoinAllowed); fallback
    -- cfg.TakeoverBindInputRemote = false (no RPC) if the rebind disturbs a car that was already driving.
    if not rec.isLocal and rec.verifyStage == 1 and cfg.TakeoverBindInput and cfg.TakeoverBindInputRemote
        and not rec.remoteBound then
        rec.remoteBound = true
        if U.try(TAG, function() car.ResetComponent:Client_BindInputActions() end) then
            U.log(TAG, "  remote: ResetComponent:Client_BindInputActions() sent to the owning client")
        else
            U.warn(TAG, "  remote: Client_BindInputActions failed for %s", nameOf(pc))
        end
    end
    -- pad not driving (local only): rebind input actions first, raw weak-pointer write as the last resort
    if rec.isLocal and inputOk == false then
        local bound = false
        if rec.verifyStage == 1 and cfg.TakeoverBindInput then
            if U.try(TAG, function() car.ResetComponent:Client_BindInputActions() end) then
                bound = true; escalated = true
                U.log(TAG, "  escalation: ResetComponent:Client_BindInputActions()")
            else
                U.log(TAG, "  escalation: Client_BindInputActions failed, falling through to the raw write")
            end
        end
        -- last resort: this pass when BindInput was not tried or failed, else the next pass
        if not bound and cfg.TakeoverForceRawInput and not rec.rawForced then
            -- VERIFY(V-TKO-01): writing a TWeakObjectPtr property from Lua with a UObject value
            if U.try(TAG, function() car.PlayerInputComponent.RawInputSubsystem = pc.RawInputSubsystem end) then
                rec.rawForced = true; escalated = true
                U.log(TAG, "  escalation: raw write PlayerInputComponent.RawInputSubsystem")
            end
        end
    end
    if escalated and rec.verifyStage < 3 then
        sched.after(TAG, 1000, function() M.verify(rec) end)
    end
end

-- ---------------------------------------------------------------------------------------------
-- §3.4 release, exact order (server)
-- ---------------------------------------------------------------------------------------------

-- leaving = true when called from the "leaving" event (phase.markLeaving emits it BEFORE St.phase becomes LEAVING).
function M.release(rec, leaving)
    if not server() or type(rec) ~= "table" then return end
    -- U.ok misses destroyed-but-uncollected actors (API§7); U.alive also checks Garbage (KSL IsValid).
    -- sweep() and a late OnPlayerControllerDestroyed (V-TKO-06) reach here with dead actors.
    local pcAlive    = U.alive(rec.pc)
    local carAlive   = U.alive(rec.car)
    local psAlive    = U.alive(rec.aiPS)
    local ctrlAlive  = U.alive(rec.aiCtrl)
    local ownPSAlive = U.alive(rec.ownPS)
    U.log(TAG, "release %s from car %s (adopted=%s, alive: pc=%s car=%s aiPS=%s aiCtrl=%s)", nameOf(rec.pc),
        nameOf(rec.car), tostring(rec.adopted), tostring(pcAlive), tostring(carAlive), tostring(psAlive),
        tostring(ctrlAlive))
    if not psAlive then
        U.warn(TAG, "release %s: the racer PlayerState is gone; the car goes back to the AI without one "
            .. "(racer entry lost)", nameOf(rec.pc))
    end
    -- 1. the human lets go of the car
    if pcAlive then U.try(TAG, function() rec.pc:UnPossess() end) end
    -- 2. give the PC its own PS back BEFORE anything may destroy the PC:
    --    AController::Destroyed -> CleanupPlayerState destroys pc.PlayerState (= the racer PS while adopted)
    --    Only while the PC still holds the racer PS: a late release (orphan sweep, a release after a seamless travel
    --    gave the PC a new PS, a pre-hook after CleanupPlayerState) must never clobber a live PC's current PS, and
    --    the property is never set to nil.
    if rec.adopted then
        if pcAlive then
            U.try(TAG, function()
                if not U.same(rec.pc.PlayerState, rec.aiPS) then
                    U.log(TAG, "  release %s: PC no longer holds the racer PS; its PlayerState is left alone",
                        nameOf(rec.pc))
                elseif ownPSAlive then
                    rec.pc.PlayerState = rec.ownPS
                else
                    U.warn(TAG, "  release %s: own PlayerState is gone; PC keeps the racer PS reference",
                        nameOf(rec.pc))
                end
            end)
        end
        if psAlive then
            U.try(TAG, function() rec.aiPS:SetOwner(ctrlAlive and rec.aiCtrl or nil) end)
        end
    end
    if rec.botFlagCleared and psAlive then
        U.try(TAG, function() rec.aiPS.bIsABot = true end)
    end
    if carAlive then
        -- 3. the AI controller takes the car back, with the racer PS only while that PS is alive
        --    (Possess -> APawn::PossessedBy copies aiCtrl.PlayerState onto the car and fires OnPawnSet with it)
        if ctrlAlive then
            U.try(TAG, function()
                if rec.aiCtrlHadPS and psAlive then rec.aiCtrl.PlayerState = rec.aiPS end
                rec.aiCtrl:Possess(rec.car)
            end)
        end
        if psAlive then
            U.try(TAG, function()
                if not U.same(rec.car.PlayerState, rec.aiPS) then
                    rec.car.PlayerState = rec.aiPS        -- raw fallback when the AI controller had no PS [S]
                end
            end)
        end
        -- 4. the AI drives again
        U.try(TAG, function()
            if ctrlAlive then
                rec.car:SetInputSource_OnServer(E.InputSource.AI)
            else
                rec.car:StartInputSourceOverride_OnServer(E.Override.Disconnect)
            end
        end)
        if rec.idleAI then
            U.try(TAG, function() rec.car.RaceAIComponent:SetBehaviour(E.AIBehaviour.Racing) end)
        end
    end
    -- 5. forget the record
    for k, r in pairs(St.takeovers) do if r == rec then St.takeovers[k] = nil end end
    for k, r in pairs(St.takeoversByCar) do if r == rec then St.takeoversByCar[k] = nil end end
    -- 6. a local PC's UnPossess (step 1) fired OnPossessedPawnChanged(old, nil), and BP_GfnPlayerController then
    --    unregistered the single tracked pawn (= P1's car) from the three audio subsystems: restore P1.
    --    Not while leaving the race. No-op unless cfg.ReRegisterP1Pawn.
    if rec.isLocal and not leaving and St.phase ~= "LEAVING" then M.reRegisterP1Pawn() end
end

function M.releaseAll(leaving)
    if not server() then return end
    local list = {}
    for _, rec in pairs(St.takeovers) do list[#list + 1] = rec end
    for _, rec in ipairs(list) do U.try(TAG, M.release, rec, leaving) end
    if #list > 0 then U.log(TAG, "releaseAll: %d record(s)%s", #list, leaving and " (leaving the race)" or "") end
end

-- ---------------------------------------------------------------------------------------------
-- §3.6 a local guest leaves mid-race (F7 via join.keyboardLeave)
-- ---------------------------------------------------------------------------------------------

function M.leaveMidRace(pc)
    if not server() then return false end
    if not U.ok(pc) then return false end
    local rec = M.recordFor(pc)
    if rec then
        M.release(rec)                                 -- PS restored first, then the PC may die
        local removed = false
        if isLocal(pc) then
            -- 2026-10-07: every guest RemovePlayer leaves a dangling input-mode listener (join.lua GUEST LIFECYCLE);
            -- join.removeGuest removes only where cfg.GuestRemoval allows it (default "never": the guest's
            -- LocalPlayer stays, un-joined in the next front end by join.resync).
            local okJ, join = pcall(U.mod, "join")
            if okJ and type(join) == "table" and type(join.removeGuest) == "function" then
                local okR, r = U.try(TAG, join.removeGuest, pc, "left mid-race (takeover)")
                removed = okR and r == true
            end
        end
        -- release() re-registered P1 already; again after RemovePlayer in case destroying the PC fired another
        -- unregister (no-op unless cfg.ReRegisterP1Pawn)
        if rec.isLocal then M.reRegisterP1Pawn() end
        U.log(TAG, "leaveMidRace %s: released%s", nameOf(pc), removed and " and removed" or " (LocalPlayer kept)")
        return true
    end
    -- native slot: the game's own human->AI path; LocalPlayer and PC stay until the front end
    -- (destroying the PC now would destroy its PlayerState = the racer entry)
    local car = pc.Pawn
    if U.isVehicle(car) then
        U.try(TAG, function() car:StartInputSourceOverride_OnServer(E.Override.Disconnect) end)
        U.log(TAG, "leaveMidRace %s: native slot handed to the AI (Disconnect override)", nameOf(pc))
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- §3.5 results must not block: BP_Csm_Race_WaitForAllPlayersToFinish waits on ARacingGameState.Racers
-- ---------------------------------------------------------------------------------------------
-- Bytecode (scripts/kismet-disasm.py on BP_Csm_Race_WaitForAllPlayersToFinish.uasset, ExecuteUbergraph, OnTick):
-- `Array_Get(this.RacingState->this.Racers, i)` -> cast<GfnPlayerState> -> `RaceEventComponent->IsStillRacing()`
-- -> any true clears AllPlayersFinishedRace; loop bound `Array_Length(RacingState.Racers)`; all done ->
-- `OwningStateMachine->ContinueToNextState(None)`. Its name table has `Racers` and no `PlayerArray`. So only Racers
-- entries can block; a PlayerState without a racer entry (FindRacerIndexByPlayer < 0: rejoined client, refused late
-- joiner, spectator, the idle ownPS of an adopted takeover) never blocks, and an entry the cast rejects (null,
-- destroyed) is skipped. Server_Cheat_FinishRace is a cheat RPC with unknown side effects (ARacingGameState has a
-- replicated `bHaveCheatsBeenUsed`), so it is only ever sent to a Racers entry that no car carries any more.

-- Keys of the PlayerStates carried by the cars of gs.Vehicles (car.PlayerState).
local function carriedPS(gs)
    local set = {}
    U.try(TAG, function()
        local cars = gs.Vehicles
        for i = 1, cars:GetArrayNum() do               -- numeric loop only: reading past the end grows a TArray
            local car = cars[i]
            if U.ok(car) then
                local ps = car.PlayerState
                if U.ok(ps) then set[U.key(ps)] = true end
            end
        end
    end)
    return set
end

local function stillRacing(ps)
    local ok, r = pcall(function()
        local comp = ps.RaceEventComponent             -- AGfnPlayerState.RaceEventComponent
        if not U.ok(comp) then return false end
        return comp:IsStillRacing() == true            -- UPlayerRaceEventComponent:IsStillRacing() -> Bool
    end)
    return ok and r == true
end

-- Racers entries split by whether a car carries them: {ps, key, carried, racing}. nil when Racers is unreadable.
local function racerEntries(gs)
    local carried = carriedPS(gs)
    local out = {}
    local ok = pcall(function()
        local arr = gs.Racers                          -- ARacingGameState.Racers Array<Object<AGfnPlayerState>>
        for i = 1, arr:GetArrayNum() do
            local ps = arr[i]
            if U.ok(ps) then
                local k = U.key(ps)
                out[#out + 1] = { ps = ps, key = k, carried = carried[k] == true, racing = stillRacing(ps) }
            end
        end
    end)
    return ok and out or nil
end

-- Every Racers entry a car carries is done (finished, DNF, eliminated); the uncarried ones are ignored here.
local function carriedRacersDone(gs, entries)
    if gs.bIsRaceStarted ~= true or St.race.started ~= true then return false end
    if not entries or #entries == 0 then return false end
    local any = false
    for _, e in ipairs(entries) do
        if e.carried then
            any = true
            if e.racing then return false end
        end
    end
    return any
end

local function cheatFinish(ps, why)
    local ok = U.try(TAG, function() ps.RaceEventComponent:Server_Cheat_FinishRace(false) end)
    U.log(TAG, "finishIdlePlayerStates: racer PS %s marked finished (%s; %s)", nameOf(ps), why,
        ok and "ok" or "call failed")
    return ok
end

-- (a) Non-adopted takeover (cfg.TakeoverAdoptPS = false, or step 2 failed): the human's car carries ownPS, while
-- rec.aiPS stays in Racers with no car and may never finish. It is finished once the human's car finished, every
-- carried racer is done, or POSTRACE was reached. An adopted record needs nothing: the car carries aiPS, which
-- finishes natively, and ownPS is not in Racers.
-- (b) Optional safety net, cfg.FinishUncarriedRacers = true (default off; nil = off): once every carried racer is
-- done (or at POSTRACE), any Racers entry still racing that no car of gs.Vehicles carries is finished, once per
-- PlayerState address and race.
-- VERIFY(V-TKO-07): an uncarried Racers entry (aiPS of a non-adopted takeover) really stays IsStillRacing() and
-- blocks the results; Server_Cheat_FinishRace(false) called on the server (a Server RPC runs locally) finishes it
-- and the results appear; whether bHaveCheatsBeenUsed flips. Fallback cfg.FinishIdlePlayerStates = false.
function M.finishIdlePlayerStates()
    if not server() or not cfg.FinishIdlePlayerStates then return end
    local gs = U.gs()
    if not U.ok(gs) or not U.isA(gs, "RacingGameState") then return end
    local post = (St.phase == "POSTRACE")
    local entries = racerEntries(gs)
    if not entries then
        U.logEvery("tko_racers", 10000, TAG, "finishIdlePlayerStates: gs.Racers unreadable")
        return
    end
    local byKey = {}
    for _, e in ipairs(entries) do byKey[e.key] = e end
    local allDone = post or carriedRacersDone(gs, entries)
    priv.uncarriedSent = priv.uncarriedSent or {}

    for _, rec in pairs(St.takeovers) do
        if not rec.finishSent and U.ok(rec.aiPS) then
            local e = byKey[U.key(rec.aiPS)]
            -- only an aiPS that is a Racers entry, carried by no car (not by rec.car either), and still racing
            if e and not e.carried and e.racing then
                -- VERIFY(V-TKO-07): the car's ownPS (not a Racers entry) may never get bHasFinishedEvent; then the
                -- entry is finished when every carried racer is done, i.e. possibly while the human still drives last.
                local humanDone = false
                pcall(function() humanDone = U.ok(rec.car) and hasFinished(rec.car.PlayerState) end)
                if allDone or humanDone then
                    rec.finishSent = true
                    priv.uncarriedSent[e.key] = true
                    cheatFinish(rec.aiPS, "AI racer entry of non-adopted takeover " .. nameOf(rec.pc))
                end
            end
        end
    end

    if cfg.FinishUncarriedRacers ~= true or not allDone then return end
    for _, e in ipairs(entries) do
        if not e.carried and e.racing and not priv.uncarriedSent[e.key] then
            priv.uncarriedSent[e.key] = true
            cheatFinish(e.ps, "uncarried Racers entry")
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- single-pawn audio subsystems: a guest's possession replaces P1's registration (PS§2)
-- ---------------------------------------------------------------------------------------------

function M.reRegisterP1Pawn()
    if not server() or not cfg.ReRegisterP1Pawn then return end
    local p1 = U.p1()
    if not U.ok(p1) then return end
    local pawn = p1.Pawn
    if not U.isVehicle(pawn) then return end
    for _, k in ipairs(AUDIO_SUBSYSTEMS) do
        -- VERIFY(V-TKO-10): RegisterLocalPlayerControlledPawn(VehiclePawn) restores passby/overtake audio for P1
        U.try(TAG, function()
            local ss = U.worldSubsystem(k)
            if U.ok(ss) then ss:RegisterLocalPlayerControlledPawn(pawn) end
        end)
    end
    U.dbg(TAG, "re-registered P1 pawn %s with the audio subsystems", nameOf(pawn))
end

function M.clear()
    St.takeovers, St.takeoversByCar = {}, {}
    priv.lastVehCount, priv.stablePolls = -1, 0
    priv.carLogged = {}
    priv.uncarriedSent = {}
end

-- ---------------------------------------------------------------------------------------------
-- §3.1 gate
-- ---------------------------------------------------------------------------------------------

-- Gate 3 + 4 for one PC. startRef = St.race.startedAtMs once the race started, else nil (countdown mode).
local function eligible(pc, gs, startRef, ignoreMidGame)
    if not U.ok(pc) then return false, "invalid" end
    if M.recordFor(pc) then return false, "has record" end
    if U.isVehicle(pc.Pawn) then return false, "has a car" end
    -- A PC whose own PS is already a racer has a car of its own in gs.Vehicles (e.g. between reset and
    -- re-possession); stealing another car for it would leave a racer entry without a driver.
    local idx = -1
    pcall(function() idx = gs:FindRacerIndexByPlayer(pc.PlayerState) end)
    if type(idx) == "number" and idx >= 0 then return false, "own PS is racer " .. tostring(idx) end
    if ignoreMidGame or St.net.lateJoinAllowed == true or cfg.TakeoverMidGameJoiners == true then
        return true, "ok (mid-game filter bypassed)"
    end
    local roster = U.mod("roster")
    if startRef then
        local fs = roster.firstSeenMs(pc)
        if fs == nil or fs >= startRef then return false, "joined after the start" end
    end
    if roster.isMidGameJoiner(pc) then return false, "mid-game joiner" end
    return true, "ok"
end

-- Records whose PC or car died without going through release(): restore what can be restored.
-- VERIFY(V-TKO-06): if the OnPlayerControllerDestroyed pre-hook fires only from AActor::OnDestroyed (after
-- AController::Destroyed ran CleanupPlayerState), an adopted racer PS of a remote PC that quit is already gone;
-- this sweep then only gives the car back to the AI.
local function sweep()
    local dead = {}
    for _, rec in pairs(St.takeovers) do
        if not U.alive(rec.pc) or not U.alive(rec.car) then dead[#dead + 1] = rec end
    end
    for _, rec in ipairs(dead) do
        U.warn(TAG, "orphan record (pc %s, car %s): releasing", tostring(U.alive(rec.pc)), tostring(U.alive(rec.car)))
        U.try(TAG, M.release, rec)
    end
end

-- MAIN poll in a race. At most one takeover per call.
function M.tick()
    if not server() or cfg.SlotMode == "off" then return end
    if St.phase == "POSTRACE" or St.phase == "LEAVING" then return end
    local gs, n = raceGS()
    if not gs then return end
    if pendingRestore then U.try(TAG, finishRestore, gs) end
    sweep()

    local startRef = nil
    if St.race.started == true and (St.race.startedAtMs or 0) > 0 then startRef = St.race.startedAtMs end
    if cfg.TakeoverWhen == "countdown" then
        -- earlier, riskier: vehicles present and their count unchanged for 2 polls
        if n == priv.lastVehCount then
            priv.stablePolls = priv.stablePolls + 1
        else
            priv.lastVehCount, priv.stablePolls = n, 0
        end
        if priv.stablePolls < 2 then return end
    else
        -- "started" (default): bIsRaceStarted and the grace period since phase saw the start edge
        if gs.bIsRaceStarted ~= true or startRef == nil then return end
        if St.nowMs() - startRef < cfg.TakeoverGraceMs then return end
    end

    local roster = U.mod("roster")
    for _, pc in ipairs(roster.humanPCs()) do
        local ok, why = eligible(pc, gs, startRef, false)
        -- COUCH CAMPAIGN: a guest left without a car means the grid patch missed him; taking over a campaign AI car
        -- crashes the game natively (exe+0x641579 null+0xdf0, live 2026-10-14 twice). Spectating beats a crash.
        local blocked = ok and blockedHere() or nil
        if blocked then
            U.logEvery("tko_couch", 30000, TAG, "%s: %s has no car, no AI takeover (spectates)", blocked, nameOf(pc))
            return
        elseif ok then
            local car = M.pickCar(gs)
            if car then M.takeOver(pc, car) end
            return
        elseif why ~= "has a car" and why ~= "has record" then
            U.logEvery("tko_skip_" .. tostring(U.key(pc)), 10000, TAG, "no takeover for %s: %s", nameOf(pc), why)
        end
    end
end

-- Ctrl+F6 / console "couch takeover": every human PC without a car, now (no grace period, no mid-game filter).
function M.forceAll()
    if not server() then
        St.emit("status", "TAKEOVER: HOST ONLY")
        return
    end
    if cfg.SlotMode == "off" then
        St.emit("status", "TAKEOVER DISABLED (SlotMode = off)")
        return
    end
    local gs = raceGS()
    if not gs then
        St.emit("status", "TAKEOVER: NO RACE GRID YET")
        return
    end
    local blocked = blockedHere()
    if blocked then
        U.log(TAG, "forceAll: refused in a %s (possessing a campaign AI car crashes the game)", blocked)
        St.emit("status", "TAKEOVER: OFF IN CAMPAIGN RACES")
        return
    end
    sweep()
    local done, skipped = 0, 0
    for _, pc in ipairs(U.mod("roster").humanPCs()) do
        local ok, why = eligible(pc, gs, nil, true)
        if ok then
            local car = M.pickCar(gs)
            if not car then
                St.emit("status", "TAKEOVER: NO FREE AI CAR")
                break
            end
            if M.takeOver(pc, car) then done = done + 1 end
        else
            skipped = skipped + 1
            U.log(TAG, "forceAll: skip %s (%s)", nameOf(pc), why)
        end
    end
    U.log(TAG, "forceAll: %d takeover(s), %d skipped", done, skipped)
    if done > 0 then St.emit("status", "TAKEOVER: " .. done .. " PLAYER(S)") end
end

-- ---------------------------------------------------------------------------------------------
-- init: listeners and hooks only (no UFunction calls at boot)
-- ---------------------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------------------------
-- hot reload (Ctrl+F11): records survive as object ADDRESSES (numbers) in UE4SS shared variables and are re-found
-- in the live world afterwards. No UObject is stored: a shared UObject would be re-wrapped from a raw pointer that
-- may be freed by then. OnUnload does not run on the game thread, so persistShared touches no UObject either
-- (keys are the U.key values taken at takeover time).
-- ---------------------------------------------------------------------------------------------

local FLAGS = { "adopted", "aiCtrlHadPS", "isLocal", "idleAI", "botFlagCleared", "finishSent", "hadNonVehiclePawn" }

function M.persistShared(put)
    local n = 0
    for _, rec in pairs(St.takeovers) do
        if rec.keys then
            n = n + 1
            local k = rec.keys
            local fl = {}
            for _, f in ipairs(FLAGS) do fl[#fl + 1] = rec[f] and "1" or "0" end
            put("tko." .. n, string.format("%d,%d,%d,%d,%d,%s", k.pc, k.car, k.aiPS, k.aiCtrl, k.ownPS,
                table.concat(fl)))
        end
    end
    put("tko.n", n)
    put("tko.world", St.worldKey or 0)
end

function M.restoreShared(get)
    local n = get("tko.n")
    if type(n) ~= "number" or n <= 0 then return end
    local list = {}
    for i = 1, n do
        local v = get("tko." .. i)
        if type(v) == "string" then list[#list + 1] = v end
    end
    pendingRestore = { world = get("tko.world"), list = list }
    U.log(TAG, "hot reload: %d takeover record(s) to re-find in the race", #list)
end

-- Game thread, first takeover.tick of this Lua state: rebuild the records whose objects are all found again.
finishRestore = function(gs)
    local pr = pendingRestore
    pendingRestore = nil
    if not pr or pr.world ~= St.worldKey then
        if pr then U.warn(TAG, "hot reload: the world changed since the unload; %d record(s) dropped", #pr.list) end
        return
    end
    local byKey = {}
    local function add(o) if U.ok(o) then byKey[U.key(o)] = o end end
    for _, pc in ipairs(U.mod("roster").humanPCs()) do add(pc); add(pc.PlayerState) end
    U.try(TAG, function()
        local cars = gs.Vehicles
        for i = 1, cars:GetArrayNum() do
            local car = cars[i]
            add(car); if U.ok(car) then add(car.PlayerState) end
        end
        local pa = gs.PlayerArray
        for i = 1, pa:GetArrayNum() do add(pa[i]) end
    end)
    local ais = FindAllOf("DrivingAIController")         -- once per reload: nil or a Lua table [API§6]
    if ais then for _, c in ipairs(ais) do add(c) end end
    for _, line in ipairs(pr.list) do
        local a = {}
        for tok in line:gmatch("[^,]+") do a[#a + 1] = tok end
        local pc, car = byKey[tonumber(a[1])], byKey[tonumber(a[2])]
        if pc and car and U.same(car.Controller, pc) then
            local rec = { pc = pc, car = car, aiPS = byKey[tonumber(a[3])], aiCtrl = byKey[tonumber(a[4])],
                          ownPS = byKey[tonumber(a[5])], atMs = St.nowMs(), verifyStage = 9, failedSteps = {},
                          keys = { pc = tonumber(a[1]), car = tonumber(a[2]), aiPS = tonumber(a[3]),
                                   aiCtrl = tonumber(a[4]), ownPS = tonumber(a[5]) } }
            local fl = a[6] or ""
            for i, f in ipairs(FLAGS) do rec[f] = fl:sub(i, i) == "1" end
            St.takeovers[U.key(pc)] = rec
            St.takeoversByCar[U.key(car)] = rec
            U.log(TAG, "hot reload: takeover %s -> %s restored (aiPS %s, aiCtrl %s, ownPS %s)", nameOf(pc),
                nameOf(car), tostring(rec.aiPS ~= nil), tostring(rec.aiCtrl ~= nil), tostring(rec.ownPS ~= nil))
        else
            U.warn(TAG, "hot reload: takeover record %s not found again (pc %s, car %s); dropped", line,
                tostring(pc ~= nil), tostring(car ~= nil))
        end
    end
end

function M.init()
    St.on("leaving", TAG, function() M.releaseAll(true) end)
    -- Per-race private state goes with every new world and on the first race phase of a race (the MAIN poll may skip
    -- LOADING: seamless travel, relisten + servertravel, a client receiving a replicated grid), like split/gfx do.
    -- Otherwise a new grid of the same size would pass the countdown gate's "stable for 2 polls" at once, and a new
    -- racer at a reused PlayerState address would be skipped by uncarriedSent.
    local function resetPriv()
        priv.lastVehCount, priv.stablePolls = -1, 0
        priv.carLogged = {}
        priv.uncarriedSent = {}
    end
    St.on("world", TAG, resetPriv)
    St.on("phase", TAG, function(new, old)
        if RACE_PHASE[new] and not RACE_PHASE[old] then resetPriv() end
        if new == "POSTRACE" then
            M.finishIdlePlayerStates()
        elseif new == "FRONTEND" then
            M.clear()
        elseif new == "RACING" then
            M.reRegisterP1Pawn()                       -- no-op unless cfg.ReRegisterP1Pawn
        end
    end)
    -- Release before the engine destroys the controller and its PlayerState (F7, client quitting mid-race).
    -- VERIFY(V-TKO-06): fires through ProcessEvent (dynamic-delegate target) and early enough; see sweep().
    U.hook(C.FN.RaceCtrlDestroyed, {
        pre = function(ctx, playerController)
            local pc = playerController:get()
            local rec = M.recordFor(pc)
            if rec then
                U.log(TAG, "OnPlayerControllerDestroyed(%s): releasing its takeover", nameOf(pc))
                M.release(rec)
            end
        end,
    }, TAG)
end

return M
