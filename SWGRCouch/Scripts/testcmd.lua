-- testcmd.lua: file-driven test commands for unattended live testing (cfg.TestCommands = true; off by default).
-- The mod polls <ModDir>/test.cmd every cfg.TestCommandPollMs. The file starts with "seq=<n>"; when n is larger than
-- the last executed seq, every following line is run once, in order, on the game thread. Results are appended to
-- <ModDir>/test.out ("[seq n] <line> -> <result>") and logged with the [testcmd] tag.
-- Commands (p = local player number 1..4):
--   speedy on|off          Race.SpeedyFlow.Intro/.Movies (+ Race.SpeedyFlow) cvars: skip race intro cinematics
--   cvar <name> <value>    any console variable;   console <command...>   any console command
--   crash <p>              car:DEBUG_RequestCrash(reason, explosion)  (may be compiled out in Shipping)
--   reset <p>              car:DEBUG_RequestResetOnTrack()
--   health <p> <delta>     racer UPlayerRaceEventComponent:Server_ChangeVehicleHealthBy(delta)
--   wreck <p> [auto|arm|tags|off]  AUTO-119: health 0, then the game's own wreck once the car moves (CMD.wreck below)
--   strikes [n|limit|limit-1|+n|-n]  AUTO-119: the run's strikes (outside a race; no argument = show them)
--   critical <p>           UPlayerRaceEventComponent:DEBUG_SetToCriticalHealth() (compiled out: no effect)
--   malf <p> [basic|triggered|both|direct] [hits]  couch-fix55: a CRITICAL MALFUNCTION on p's car: basic (default) =
--                          the game's trigger path (BASIC Vehicle.Condition.Malfunction hits on the component until
--                          the buildup fills), direct = the component's client start (no condition tag on the car);
--                          the outcome (condition tag, state, hits, the component's config) follows in test.out
--   botcrit [resolve|timeout|pass|fail|crash|crashpre]  cfg.TestBotsCrit, what a TestBots car does in a critical
--                          malfunction (timeout / pass / crash / crashpre = the outcomes that queue a fault; the B
--                          press is an Enhanced Input injection per frame, couch-fix55)
--   finish <p>             UPlayerRaceEventComponent:Server_Cheat_FinishRace(false)
--   diag                   the F9 dump (diag module)
--   lua <code>             runs <code> with U, St, C, cfg, require and P(p) (-> pc, car, ps, rec) in scope; the
--                          returned value(s) are written to test.out
--   gauntlet start [steps] | stop | status | skip | goto <step> | arm | rival [status|offer|accept] | list
--                          couch-gauntlet (gauntlet.lua, docs/dev/gauntlet.md): every race type of the campaign one
--                          after the other, one per node pick; initialised here, so only with cfg.TestCommands
-- Static facts (scripts/reflect-func-all.py, 2026-10-07):
--   AVehiclePawn:DEBUG_RequestCrash(Struct crashReason, Enum explosionReason)  flags 0x4420401
--   AVehiclePawn:DEBUG_RequestResetOnTrack()                                  flags 0x4020401
--   UPlayerRaceEventComponent:Server_ChangeVehicleHealthBy(Int numHealth)      flags 0x220cc0 (server RPC)
--   UPlayerRaceEventComponent:DEBUG_SetToCriticalHealth()                      flags 0x4020401
--   UPlayerRaceEventComponent:Server_Cheat_FinishRace(Bool abandonedRace)      flags 0x4220cc0

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "testcmd"

local lastSeq = -1
local handle = nil
local outPath, cmdPath

local function paths()
    if cmdPath then return true end
    local ok, d = pcall(function() return require("settings").modDir() end)
    if not ok or type(d) ~= "string" or d == "" then return false end
    d = d:gsub("\\", "/")
    cmdPath, outPath = d .. "/test.cmd", d .. "/test.out"
    return true
end

local function out(seq, line, result)
    local s = string.format("[seq %s] %s -> %s", tostring(seq), tostring(line), tostring(result))
    U.log(TAG, "%s", s)
    if not outPath then return end
    local f = io.open(outPath, "a")
    if f then f:write(s, "\n"); f:close() end
end

-- Local player p (1-based, GameInstance.LocalPlayers order): pc, car (vehicle pawn or nil), ps, rec (race comp).
local function P(p)
    local lps = U.localPlayers()
    local e = lps[tonumber(p) or 1]
    if not e or not U.ok(e.pc) then return nil end
    local r = { pc = e.pc }
    pcall(function() local pawn = e.pc.Pawn; if U.ok(pawn) then r.car = pawn end end)
    pcall(function() local ps = e.pc.PlayerState; if U.ok(ps) then r.ps = ps end end)
    if r.ps then pcall(function() local rc = r.ps.RaceEventComponent; if U.ok(rc) then r.rec = rc end end) end
    -- the racer's own PlayerState may differ from the PC's (takeover / adoption): prefer the car's
    if r.car then
        pcall(function()
            local cps = r.car.PlayerState
            if U.ok(cps) then
                local rc = cps.RaceEventComponent
                if U.ok(rc) then r.ps, r.rec = cps, rc end
            end
        end)
    end
    return r
end
M.P = P

local function words(line)
    local t = {}
    for w in line:gmatch("%S+") do t[#t + 1] = w end
    return t
end

local function cvar(name, value)
    return U.console(string.format("%s %s", name, tostring(value))) and "ok" or "failed"
end

local CMD = {}

function CMD.speedy(a)
    local v = (a[2] == "off") and 0 or 1
    local r = {}
    for _, n in ipairs({ "Race.SpeedyFlow.Intro", "Race.SpeedyFlow.Movies" }) do r[#r + 1] = n .. "=" .. cvar(n, v) end
    return table.concat(r, " ")
end

function CMD.cvar(a) return cvar(a[2], a[3] or "") end

function CMD.console(_, line)
    local c = line:match("^%s*console%s+(.+)$")
    if not c then return "usage: console <command>" end
    return U.console(c) and "ok" or "failed"
end

function CMD.crash(a)
    local r = P(a[2]); if not r or not r.car then return "no car" end
    local ok, err = pcall(function() r.car:DEBUG_RequestCrash({}, 0) end)
    return ok and "called" or ("error: " .. tostring(err))
end

function CMD.reset(a)
    local r = P(a[2]); if not r or not r.car then return "no car" end
    local ok, err = pcall(function() r.car:DEBUG_RequestResetOnTrack() end)
    return ok and "called" or ("error: " .. tostring(err))
end

function CMD.health(a)
    local r = P(a[2]); if not r or not r.rec then return "no race component" end
    local d = math.tointeger(tonumber(a[3]) or -1) or -1
    local before; pcall(function() before = r.rec.VehicleHealth end)
    local ok, err = pcall(function() r.rec:Server_ChangeVehicleHealthBy(d) end)
    local after; pcall(function() after = r.rec.VehicleHealth end)
    return ok and string.format("health %s -> %s", tostring(before), tostring(after)) or ("error: " .. tostring(err))
end

---------------------------------------------------------------------------------------------------- AUTO-119 wreck
-- AUTO-119 (live round 1, 13:03:56-13:04:45): "wreck 2" / "health 2 -N" left the guest at 8 hp ("health 8 -> 8")
-- while "health 1 -2" worked on P1 (5 -> 3); "crash 2" did nothing; P(2).rec.VehicleHealth = 1 stuck, but the bot
-- finished without another crash, so A14 (the #99 strike refund at the strike limit) could not run. Static
-- (notes/research/wreck-angle2.md): Server_ChangeVehicleHealthBy changes the health only while ShouldUseHealth()
-- (cvar, the stage's bPlayerCanWreck, the car build's UseHealth, not a PvP mode) and the racer has not finished;
-- DEBUG_RequestCrash / DEBUG_SetToCriticalHealth are compiled out (empty stubs); a wreck = a crash at
-- ShouldNextCrashWreckVehicle() (VehicleHealth <= 1) that adds Vehicle.Crash.Wrecked, and the race reacts to that tag
-- in RacingGameMode:OnVehicleCrashTagChanged(VehiclePawn, crashTag, isAdded) (exec 0x141235206 -> HandleWreck
-- 0x142fe5d02: FailReasons |= Wrecked, bHasVehicleWrecked, NotifyRacerWrecked, the spectate, the standalone DNF
-- finish; the wreck strike comes from that state at the result). Memory: a wreck needs a MOVING car.
-- "wreck <p> [auto|arm|tags]":
--   auto (default)  health to 0 (the RPC; refused -> the component's VehicleHealth written + OnRep), then, as soon as
--                   the car MOVES (and still races), the game's own wreck handler with Vehicle.Crash.Wrecked; checked
--                   WRECK_CHECK_MS later (bHasVehicleWrecked + FailReasons Wrecked), the outcome logged / in test.out
--   arm             health to 0 only: the next real crash wrecks (nothing else is called)
--   tags            as auto, but first the car's own crash state: CrashComponent:Server_SetCrashTags(its tags +
--                   Vehicle.Crash.Tumble / Wrecking / Wrecked); the handler only when that did not wreck it
--                   (EXPERIMENTAL: the crash component runs without a crash in progress)
-- Cancel a waiting wreck with "wreck <p> off".
local WRECK_POLL_MS, WRECK_WAIT_MS, WRECK_CHECK_MS = 250, 30000, 1500
local MOVING_UU_S = 300                               -- wreck.lua: ~300 uu/s = moving
local TAG_WRECKED, TAG_WRECKING, TAG_TUMBLE = "Vehicle.Crash.Wrecked", "Vehicle.Crash.Wrecking", "Vehicle.Crash.Tumble"
local wrecks = {}                                     -- [p] = {h = sched handle, mode, t0}

local function asyncOut(line, result) out("async", line, result) end

local function speedOf(car)
    local v = nil
    pcall(function() v = car:GetVelocity() end)
    if v == nil then return nil end
    local x, y = tonumber(v.X) or 0, tonumber(v.Y) or 0
    return math.sqrt(x * x + y * y)
end

local function recState(r)
    local s = {}
    pcall(function() s.hp = tonumber(r.rec.VehicleHealth) end)
    pcall(function() s.start = tonumber(r.rec.StartingVehicleHealth) end)
    pcall(function() s.wrecked = r.rec.bHasVehicleWrecked == true end)
    pcall(function() s.finished = r.rec.bHasFinishedEvent == true end)
    pcall(function() s.fail = tonumber(r.rec.FailReasons) end)
    pcall(function() s.use = r.rec:ShouldUseHealth() end)
    pcall(function() s.racing = r.rec:IsStillRacing() end)
    return s
end
M._recState = recState

-- pure: what the wreck does now. s = recState, speed (nil = unreadable), mode -> "wait" | "wreck" | "done" | "stop", why
function M.wreckStep(s, speed, mode, waitedMs)
    if s.wrecked then return "done", "wrecked" end
    if s.finished then return "stop", "the racer has finished (a finished racer never wrecks)" end
    if s.racing == false then return "stop", "the racer is not racing any more" end
    if mode == "arm" then return "stop", "armed only (the next real crash wrecks)" end
    if (waitedMs or 0) >= WRECK_WAIT_MS then return "stop", string.format("the car did not move within %d s", WRECK_WAIT_MS / 1000) end
    if speed == nil or speed < MOVING_UU_S then return "wait", "the car is not moving" end
    return "wreck", string.format("moving at %.0f uu/s", speed)
end

-- health to 0: the server RPC, else (refused: a guest's car live) the component's own field + its OnRep -> text
local function healthToZero(p, r)
    local s0 = recState(r)
    local before = s0.hp
    if before == nil then return "health unreadable" end
    if before <= 0 then return string.format("health already %d", before) end
    pcall(function() r.rec:Server_ChangeVehicleHealthBy(-before) end)
    local after = recState(r).hp
    if after == 0 then return string.format("health %d -> 0 (Server_ChangeVehicleHealthBy)", before) end
    local okW = pcall(function() r.rec.VehicleHealth = 0 end)
    pcall(function() r.rec:OnRep_VehicleHealth() end)
    if r.car then pcall(function() r.car:OnRep_VehicleHealth() end) end
    after = recState(r).hp
    return string.format("health %d -> %s (the RPC left %s: ShouldUseHealth %s; VehicleHealth written%s)", before,
        tostring(after), tostring(before), tostring(s0.use), (okW and after == 0) and "" or " - FAILED")
end

local function tagNames(comp)
    local names = {}
    pcall(function()
        local arr = comp.CrashTags.GameplayTags
        for i = 1, U.arrayCount(arr) do
            local n = nil
            pcall(function() n = arr[i].TagName:ToString() end)
            if n then names[#names + 1] = n end
        end
    end)
    return names
end

-- the car's own crash state (mode "tags"): its crash tags + Tumble / Wrecking / Wrecked through the component's RPC
local function crashTags(r)
    local comp = nil
    pcall(function() comp = r.car.CrashComponent end)
    if not U.ok(comp) then return false, "no CrashComponent" end
    local names, seen = tagNames(comp), {}
    for _, n in ipairs(names) do seen[n] = true end
    for _, n in ipairs({ TAG_TUMBLE, TAG_WRECKING, TAG_WRECKED }) do
        if not seen[n] then names[#names + 1] = n end
    end
    local tags = {}
    for i, n in ipairs(names) do tags[i] = { TagName = U.fname(n) } end
    local ok, err = pcall(function() comp:Server_SetCrashTags({ GameplayTags = tags, ParentTags = {} }) end)
    return ok, ok and ("Server_SetCrashTags(" .. table.concat(names, ",") .. ")") or tostring(err)
end

-- the race's own wreck handler for this car (RacingGameMode:OnVehicleCrashTagChanged, Vehicle.Crash.Wrecked added)
local function wreckHandler(r)
    local gm = U.gm()
    if not U.ok(gm) then return false, "no AuthorityGameMode" end
    local ok, err = pcall(function() gm:OnVehicleCrashTagChanged(r.car, { TagName = U.fname(TAG_WRECKED) }, true) end)
    return ok, ok and "RacingGameMode:OnVehicleCrashTagChanged(Vehicle.Crash.Wrecked)" or tostring(err)
end

local function wreckCancel(p)
    local w = wrecks[p]
    wrecks[p] = nil
    if w and w.h then pcall(sched.cancel, w.h) end
    return w ~= nil
end

local function wreckVerify(p, line, how, tries)
    local r = P(p)
    local s = r and r.rec and recState(r) or {}
    if s.wrecked then
        local res = string.format("P%s WRECKED by %s (hp %s, FailReasons %s, still racing %s)", tostring(p), how,
            tostring(s.hp), tostring(s.fail), tostring(s.racing))
        U.log(TAG, "wreck: %s (AUTO-119)", res)
        asyncOut(line, res)
        return
    end
    if tries == "tags" then
        -- the crash state did not reach the race: the race's own handler
        local ok, why = wreckHandler(r)
        U.log(TAG, "wreck P%s: not wrecked %d ms after %s - %s %s", tostring(p), WRECK_CHECK_MS, how, why,
            ok and "called" or "FAILED")
        if ok then
            sched.after(TAG .. ".wreck", WRECK_CHECK_MS, function() wreckVerify(p, line, why, nil) end)
            return
        end
    end
    local res = string.format("P%s NOT wrecked after %s (hp %s, wrecked %s, finished %s, ShouldUseHealth %s)",
        tostring(p), how, tostring(s.hp), tostring(s.wrecked), tostring(s.finished), tostring(s.use))
    U.warn(TAG, "wreck: %s (AUTO-119)", res)
    asyncOut(line, res)
end

local function wreckTick(p, line)
    local w = wrecks[p]
    if not w then return end
    local r = P(p)
    if not r or not r.rec or not r.car then
        wreckCancel(p)
        asyncOut(line, "P" .. tostring(p) .. ": no car any more - wreck cancelled")
        return
    end
    local s = recState(r)
    local step, why = M.wreckStep(s, speedOf(r.car), w.mode, St.nowMs() - w.t0)
    if step == "wait" then return end
    wreckCancel(p)
    if step == "done" then
        asyncOut(line, string.format("P%s wrecked (by the game: a real crash at 0 hp)", tostring(p)))
        return
    end
    if step == "stop" then
        asyncOut(line, string.format("P%s: %s", tostring(p), why))
        return
    end
    local ok, how
    if w.mode == "tags" then ok, how = crashTags(r) end
    if not ok then
        if w.mode == "tags" then U.log(TAG, "wreck P%s: crash tags not set (%s): the race's wreck handler", tostring(p), tostring(how)) end
        ok, how = wreckHandler(r)
    end
    U.log(TAG, "wreck P%s (%s): %s %s", tostring(p), why, tostring(how), ok and "called" or "FAILED")
    if not ok then
        asyncOut(line, string.format("P%s: %s FAILED", tostring(p), tostring(how)))
        return
    end
    local tries = (w.mode == "tags" and how:find("Server_SetCrashTags", 1, true)) and "tags" or nil
    sched.after(TAG .. ".wreck", WRECK_CHECK_MS, function() wreckVerify(p, line, how, tries) end)
end

function CMD.wreck(a, line)
    local p = tonumber(a[2]) or 1
    local mode = a[3] or "auto"
    if mode == "off" then return wreckCancel(p) and ("P" .. p .. " wreck cancelled") or ("P" .. p .. ": no wreck waiting") end
    if mode ~= "auto" and mode ~= "arm" and mode ~= "tags" then return "usage: wreck <p> [auto|arm|tags|off]" end
    if St.phase ~= "RACING" then return "only in a race (phase " .. tostring(St.phase) .. ")" end
    local r = P(p)
    if not r or not r.rec then return "P" .. p .. ": no race component" end
    if not r.car then return "P" .. p .. ": no car" end
    local s = recState(r)
    if s.wrecked then return "P" .. p .. " is already wrecked" end
    if s.finished then return "P" .. p .. " has finished (a finished racer never wrecks)" end
    wreckCancel(p)
    local hp = healthToZero(p, r)
    U.log(TAG, "wreck P%d (%s): %s (AUTO-119)", p, mode, hp)
    if mode == "arm" then return hp .. "; armed: the next real crash wrecks" end
    wrecks[p] = { mode = mode, t0 = St.nowMs() }
    wrecks[p].h = sched.every(TAG .. ".wreck", WRECK_POLL_MS, function() U.try(TAG, wreckTick, p, line) end)
    wreckTick(p, line)                                 -- a moving car is wrecked at once
    return hp .. (wrecks[p] and "; waiting for the car to move (the outcome follows in test.out)" or "; wreck called (the outcome follows in test.out)")
end

---------------------------------------------------------------------------------------------------- AUTO-119 strikes
-- "strikes <n|limit|limit-1|+n|-n>": the run's League Token strikes (CampaignRun.Strikes) set outside a race, for the
-- strike-limit tests (A14: a guest's wreck refunded at the limit, #99). "limit-1" = one strike before the run is lost
-- (GetStrikesNeededToEndRun() - 1). Never "limit" or above while bRunLocked matters: a write does not lock or unlock
-- the run (only the game's strike change does); the reply shows strikes / limit / locked.
function M.strikeTarget(arg, cur, need)
    arg = tostring(arg or "")
    local n = nil
    if arg == "limit" then n = need
    elseif arg == "limit-1" then n = need and need - 1
    elseif arg:match("^[+-]%d+$") then n = (cur or 0) + tonumber(arg)
    elseif arg:match("^%d+$") then n = tonumber(arg) end
    if n == nil then return nil, "usage: strikes <n|limit|limit-1|+n|-n>" .. ((arg == "limit" or arg == "limit-1")
        and " (the strike limit is unreadable)" or "") end
    n = math.max(0, math.floor(n))
    return n
end

function CMD.strikes(a)
    if St.phase == "RACING" or St.phase == "PRERACE" then
        return "only outside a race (the strike ledger reads the race-start strikes): set it on the map / paddock"
    end
    local run = nil
    pcall(function() run = FindFirstOf("CampaignSubsystem").ActiveRun end)
    if not U.ok(run) then return "no active run" end
    local cur, need, locked = nil, nil, nil
    pcall(function() cur = math.floor(tonumber(run.Strikes) or 0) end)
    pcall(function() need = tonumber(run:GetStrikesNeededToEndRun()) end)
    pcall(function() locked = run.bRunLocked == true end)
    if a[2] == nil then
        return string.format("strikes %s / limit %s, run locked %s", tostring(cur), tostring(need), tostring(locked))
    end
    local n, err = M.strikeTarget(a[2], cur, need)
    if not n then return err end
    local ok = pcall(function() run.Strikes = n end)
    local now = nil
    pcall(function() now = math.floor(tonumber(run.Strikes) or -1) end)
    U.log(TAG, "strikes %s -> %s (limit %s, run locked %s)%s (AUTO-119)", tostring(cur), tostring(now), tostring(need),
        tostring(locked), (ok and now == n) and "" or " WRITE FAILED")
    return string.format("strikes %s -> %s / limit %s, run locked %s%s", tostring(cur), tostring(now), tostring(need),
        tostring(locked), (ok and now == n) and "" or " (WRITE FAILED)")
end

-- 0.13.0 test bots: "bot <p|all> on|off" hands a local human's car to the game's own AI (the Disconnect input-source
-- override, the path join.lua uses for a lost pad) or gives it back. The car keeps its human PlayerState, so places,
-- finishes, wrecks and the mod's run scoring are real. cfg.TestBots = true does "bot all on" at every race start
-- (unattended test races: no pad, no focus needed for the driving).
-- Overnight 2026-10-18 (tester #2, ramjet 4P): cfg.TestBots drives the cars through the SpawnAI override, so
-- "bot p off" must stop BOTH overrides, and the car is marked manual for this world: botsTick neither gives it back
-- to the AI nor presses B for its critical malfunction (the tester recovers it by hand). "bot p on" clears the mark.
local bots   -- forward (botsTick's state, below)
local function botSet(p, on)
    local r = P(p); if not r or not r.car then return "P" .. tostring(p) .. " no car" end
    local i = tonumber(p) or 1
    local ok, err = pcall(function()
        if on then r.car:StartInputSourceOverride_OnServer(C.E.Override.Disconnect)
        else
            r.car:StopInputSourceOverride_OnServer(C.E.Override.SpawnAI)
            r.car:StopInputSourceOverride_OnServer(C.E.Override.Disconnect)
        end
    end)
    if ok and bots then
        bots.manual[i] = (not on) and U.key(r.car) or nil
        bots.crit[i] = nil
    end
    return "P" .. tostring(p) .. (ok and (on and " bot on" or " bot off") or (" error " .. tostring(err)))
end
M.botSet = botSet

function CMD.bot(a)
    local on = (a[3] or "on") ~= "off"
    if a[2] == "all" then
        local out = {}
        for i = 1, #U.localPlayers() do out[#out + 1] = botSet(i, on) end
        return table.concat(out, ", ")
    end
    return botSet(tonumber(a[2]) or 1, on)
end

local CRIT_STATE = { [0] = "Idle", "Malfunction", "WaitForPress", "WaitForRelease", "Testing", "Resolving" }
local CRIT_RES = { [0] = "Failed", "Passed", "PerfectPass", "TimedOut", "Invalid" }
local function critComp(car)
    local comp = nil
    pcall(function() comp = car.CriticalMalfunctionComponent end)
    return U.ok(comp) and comp or nil
end
-- the component's ECriticalMalfunctionState (nil when unreadable)
local function critState(comp)
    local st = nil
    if comp then pcall(function() st = tonumber(comp:GetState()) end) end
    return st
end
M._critState = critState
-- "Testing / res TimedOut" for the log (the component's own getters)
local function critText(comp)
    if not comp then return "no component" end
    local st, res = critState(comp), nil
    pcall(function() res = tonumber(comp:GetResolutionState()) end)
    return string.format("state %s, resolution %s", CRIT_STATE[st or -1] or tostring(st), CRIT_RES[res or -1] or tostring(res))
end
M._critText = critText
function CMD.critical(a)
    local r = P(a[2]); if not r or not r.rec then return "no race component" end
    local ok, err = pcall(function() r.rec:DEBUG_SetToCriticalHealth() end)
    return ok and "called" or ("error: " .. tostring(err))
end

-- couch-fix55 (live round 3 A9: "malf 2" x3 -> state Idle; a natural malfunction sat in WaitForPress 30 s with the
-- B action). UCriticalMalfunctionComponent, decoded from the shipping exe (CL381121 = the hf2 copy, static):
--   TRIGGER (server): OnConditionStarted_OnServer / OnConditionTriggered_OnServer act ONLY on the BASIC condition tag
--     Vehicle.Condition.Malfunction (native tag 0x14aea7c58; fix50 passed Vehicle.Condition.CriticalMalfunction ->
--     no-op). Gates: the car's vfunc 0x820, none of 3 immunity tags on its VehicleState, the build state's
--     CriticalMalfunctions bool (+0x51) for its slot, the buildup (+0x13c) not full yet; Triggered also needs the car's
--     state stack top (+0xca8) == 9. Each hit: count++ and the buildup grows by MalfunctionStart/TriggeredBuildupAmount
--     (0x14717a3ba, virtualized); it drains after MalfunctionDrainDelayTime over MalfunctionDrainTime (the TICK).
--     A full buildup puts Vehicle.Condition.CriticalMalfunction on the car.
--   START (client): OnConditionStarted_OnClient(Vehicle.Condition.CriticalMalfunction, native tag 0x14aea7c80), car
--     vfuncs 0x820 and 0x818 true -> state Malfunction (1). OnConditionEnded_OnClient(same tag) ends it.
--   TICK (0x14059f376, vtable slot of TickComponent; only with comp.EnhancedInputComponent set, +0x128):
--     1 Malfunction: TimeBeforeCheck (cfg+4) -> 2 WaitForPress.
--     2 WaitForPress: GetBoundActionValue(cfg.Action) on comp.EnhancedInputComponent; NO TIMEOUT - it waits for the
--       press for ever (the PC's IA_Veh_CriticalMalfunction BP event is the pre-flight checks' input, not this).
--     3 WaitForRelease: TestProgress = held / TimeToHoldStart; released before 1.0 -> back to 2; released at 1.0 -> 4.
--     4 Testing: the sweep, TestProgress over TimeForCheck (SweepDialationLookup curve). A press: TestProgress in
--       [BonusStart, SuccessEnd) -> success (PerfectPass below SuccessStart, else Passed), outside -> Failed (early /
--       late); no press until the sweep's end -> TimedOut (0x14717a822).
--     5 Resolving: Fail/Pass/PerfectPass/TimeOutResolutionTime, then the end (0x140fd95e2: Server_Resolve RPC,
--       OnAffixMadeFaulty broadcast, state Idle).
--   FAULT (T 0x143096112): Passed -> ApplyFaulyOnSuccess, PerfectPass -> OnPerfect, Failed -> OnEarly/LateFail,
--     TimedOut -> OnTimeout; a crash (OnCrashTagChanged_OnClient, Vehicle.Crash.Tumble ADDED, vfuncs 0x820/0x818) in
--     states 1-4 faults ONLY while the car's VehicleState carries Vehicle.Condition.CriticalMalfunction: Testing ->
--     ApplyFaulyOnCrashOut, 1-3 -> ApplyFaulyOnPreTestCrash (+ MinimumTimeForCrashingFault).
-- "malf <p> [basic|triggered|both|direct] [hits]":
--   basic (default; "started" = the same) = the game's own trigger path: OnConditionStarted_OnServer with the BASIC
--     tag, one hit every MALF_HIT_MS until the car is in a critical malfunction (at most hits, default 12);
--   triggered = OnConditionTriggered_OnServer the same way; both = the two alternately;
--   direct = OnConditionStarted_OnClient(Vehicle.Condition.CriticalMalfunction): state Malfunction at once, WITHOUT
--     the car's condition tag (so a crash does not fault; timeout / pass / fail do).
-- test.out gets the outcome (tag, state, hits) and the component's config (the check's timings, the fault flags).
local MALF_TAG = "Vehicle.Condition.Malfunction"
local CRIT_TAG = "Vehicle.Condition.CriticalMalfunction"
local MALF_HIT_MS = 250
local MALF_FN = { basic = { "OnConditionStarted_OnServer" }, started = { "OnConditionStarted_OnServer" },
                  triggered = { "OnConditionTriggered_OnServer" },
                  both = { "OnConditionStarted_OnServer", "OnConditionTriggered_OnServer" } }
M._MALF = { tag = MALF_TAG, crit = CRIT_TAG, hitMs = MALF_HIT_MS }

-- the component's CriticalMalfunctionConfig (GetBPCriticalMalfunctionConfig), as a plain table (nil fields unread)
local CFG_KEYS = { "TimeBeforeCheck", "TimeToHoldStart", "TimeForCheck", "BonusStart", "SuccessStart", "SuccessEnd",
                   "MalfunctionStartBuildupAmount", "MalfunctionTriggeredBuildupAmount", "MinimumTimeForCrashingFault",
                   "ApplyFaulyOnEarlyFail", "ApplyFaulyOnPerfect", "ApplyFaulyOnSuccess", "ApplyFaulyOnLateFail",
                   "ApplyFaulyOnTimeout", "ApplyFaulyOnPreTestCrash", "ApplyFaulyOnCrashOut" }
local function critCfg(comp)
    local t = {}
    if not comp then return t end
    local s = nil
    pcall(function() s = comp:GetBPCriticalMalfunctionConfig() end)
    if s == nil then return t end
    for _, k in ipairs(CFG_KEYS) do pcall(function() t[k] = s[k] end) end
    pcall(function() local a = s.Action; if U.ok(a) then t.Action = a end end)
    return t
end
M._critCfg = critCfg
local function n2(v) v = tonumber(v); return v and string.format("%.2f", v) or "?" end
local function cfgText(t)
    local function b(k) return t[k] == true and "1" or (t[k] == false and "0" or "?") end
    return string.format("check %s/%s/%s s (before/hold/sweep), window %s-%s-%s, buildup %s/%s, faults succ %s perf %s "
        .. "early %s late %s timeout %s precrash %s crashout %s", n2(t.TimeBeforeCheck), n2(t.TimeToHoldStart),
        n2(t.TimeForCheck), n2(t.BonusStart), n2(t.SuccessStart), n2(t.SuccessEnd), n2(t.MalfunctionStartBuildupAmount),
        n2(t.MalfunctionTriggeredBuildupAmount), b("ApplyFaulyOnSuccess"), b("ApplyFaulyOnPerfect"),
        b("ApplyFaulyOnEarlyFail"), b("ApplyFaulyOnLateFail"), b("ApplyFaulyOnTimeout"), b("ApplyFaulyOnPreTestCrash"),
        b("ApplyFaulyOnCrashOut"))
end
M._cfgText = cfgText

-- in a critical malfunction: the car's condition tag OR the component past Idle (a "direct" start has no tag)
local function inCrit(car, comp)
    local ig = U.mod("ignpad")
    if ig and ig.carInCrit and ig.carInCrit(car) then return true, true end
    local st = critState(comp)
    return st ~= nil and st >= 1 and st <= 5, false
end
M._inCrit = inCrit

local malfRun = { gen = 0 }
function CMD.malf(a, line)
    local p = tonumber(a[2]) or 1
    local how = a[3] or "basic"
    local maxHits = math.tointeger(tonumber(a[4]) or 12) or 12
    if how ~= "direct" and not MALF_FN[how] then return "usage: malf <p> [basic|triggered|both|direct] [hits]" end
    if St.phase ~= "RACING" then return "only in a race (phase " .. tostring(St.phase) .. ")" end
    local r = P(p)
    if not r or not r.car then return "P" .. p .. ": no car" end
    local comp = critComp(r.car)
    if not comp then return "P" .. p .. ": no CriticalMalfunctionComponent" end
    if inCrit(r.car, comp) then return "P" .. p .. " is already in a critical malfunction (" .. critText(comp) .. ")" end
    local eic = false
    pcall(function() eic = U.ok(comp.EnhancedInputComponent) end)
    local cfgs = cfgText(critCfg(comp))
    malfRun.gen = malfRun.gen + 1
    local gen, carKey = malfRun.gen, U.key(r.car)
    local function report(hits, err)
        local r2 = P(p)
        local car = r2 and r2.car
        local c2 = car and U.key(car) == carKey and critComp(car) or nil
        local on, tagged = false, false
        if c2 then on, tagged = inCrit(car, c2) end
        local txt = string.format("P%d %s after malf (%s, %d hit(s)%s): condition tag %s, %s; input component %s; %s", p,
            on and "IN A CRITICAL MALFUNCTION" or "NOT in a critical malfunction", how, hits, err and (", " .. err) or "",
            tagged and "on" or "off", critText(c2), eic and "yes" or "NONE (the check never runs)", cfgs)
        U.log(TAG, "malf: %s (fix55)", txt)
        asyncOut(line, txt)
    end
    if how == "direct" then
        local ok, err = pcall(function() comp:OnConditionStarted_OnClient({ TagName = U.fname(CRIT_TAG) }) end)
        U.log(TAG, "malf P%d (direct): OnConditionStarted_OnClient(%s) %s (fix55)", p, CRIT_TAG,
            ok and "called" or ("FAILED: " .. tostring(err)))
        sched.after(TAG .. ".malf", 500, function() report(1, not ok and tostring(err) or nil) end)
        return "OnConditionStarted_OnClient(" .. CRIT_TAG .. ") " .. (ok and "called" or ("FAILED: " .. tostring(err)))
            .. "; the outcome follows in test.out"
    end
    local fns = MALF_FN[how]
    local hits, lastErr = 0, nil
    local function hit()
        if malfRun.gen ~= gen or St.phase ~= "RACING" then return end
        local r2 = P(p)
        local car = r2 and r2.car
        local c2 = car and U.key(car) == carKey and critComp(car) or nil
        if not c2 then report(hits, "the car changed"); return end
        if inCrit(car, c2) then report(hits); return end
        if hits >= maxHits then report(hits, "gave up: the buildup never filled"); return end
        local fn = fns[(hits % #fns) + 1]
        hits = hits + 1
        local ok, err = pcall(function() c2[fn](c2, { TagName = U.fname(MALF_TAG) }) end)
        if not ok then lastErr = fn .. " FAILED: " .. tostring(err); report(hits, lastErr); return end
        sched.after(TAG .. ".malf", MALF_HIT_MS, hit)
    end
    U.log(TAG, "malf P%d (%s): %s(%s) every %d ms, at most %d hit(s) (fix55)", p, how, table.concat(fns, "/"), MALF_TAG,
        MALF_HIT_MS, maxHits)
    hit()
    return string.format("%s(%s) every %d ms until the critical malfunction (at most %d); the outcome follows in test.out",
        table.concat(fns, "/"), MALF_TAG, MALF_HIT_MS, maxHits)
end

-- "botcrit [resolve|timeout|pass|fail|crash|crashpre]": cfg.TestBotsCrit at run time (no argument = show it)
function CMD.botcrit(a)
    local m = a[2]
    if m == nil then return "TestBotsCrit " .. M.critMode() end
    if not M.CRIT_MODES[m] then return "usage: botcrit [resolve|timeout|pass|fail|crash|crashpre]" end
    cfg.TestBotsCrit = m
    U.log(TAG, "TestBotsCrit = %s (AUTO-129)", m)
    return "TestBotsCrit " .. m
end

function CMD.finish(a)
    local r = P(a[2]); if not r or not r.rec then return "no race component" end
    local ok, err = pcall(function() r.rec:Server_Cheat_FinishRace(false) end)
    return ok and "called" or ("error: " .. tostring(err))
end

function CMD.diag()
    local d = U.mod("diag")
    for _, fn in ipairs({ "dumpAll", "dump", "full" }) do
        if type(d[fn]) == "function" then
            local ok, err = pcall(d[fn])
            return ok and ("diag." .. fn .. " done") or ("error: " .. tostring(err))
        end
    end
    return "no dump function in diag"
end

function CMD.gauntlet(a) return U.mod("gauntlet").command(a) end

function CMD.lua(_, line)
    local code = line:match("^%s*lua%s+(.+)$")
    if not code then return "usage: lua <code>" end
    local env = setmetatable({ U = U, St = St, C = C, cfg = cfg, P = P, require = require }, { __index = _G })
    local fn, err = load("return " .. code, "testcmd", "t", env)
    if not fn then fn, err = load(code, "testcmd", "t", env) end
    if not fn then return "compile error: " .. tostring(err) end
    local res = table.pack(pcall(fn))
    if not res[1] then return "error: " .. tostring(res[2]) end
    local parts = {}
    for i = 2, res.n do parts[#parts + 1] = tostring(res[i]) end
    return table.concat(parts, ", ")
end

-- one command line -> its result (the sims; the file poll runs the same table)
function M.exec(line)
    local a = words(line)
    local f = a[1] and CMD[a[1]]
    if not f then return "unknown command" end
    local ok, r = pcall(f, a, line)
    return ok and r or ("error: " .. tostring(r))
end

local function runBlock(seq, lines)
    for _, line in ipairs(lines) do
        local a = words(line)
        local f = a[1] and CMD[a[1]]
        if f then
            local ok, r = pcall(f, a, line)
            out(seq, line, ok and r or ("error: " .. tostring(r)))
        elseif a[1] then
            out(seq, line, "unknown command")
        end
    end
end

local speedyDone = false
local function applySpeedy()
    if speedyDone or not cfg.SkipRaceIntro then return end
    if not U.ok(U.world()) then return end
    speedyDone = true
    U.log(TAG, "SkipRaceIntro: %s", CMD.speedy({ "speedy", "on" }))
end

-- cfg.TestBots (test harness only): the game's AI drives the chosen local cars as soon as they exist in RACING and
-- again after any respawn (a new pawn), checked every second from this loop. true / "all" = every local car,
-- "guests" = P2..P4 only (P1 stays Jules's), "p1" = P1's car only (Jules plays P2 on his own pad, 2026-10-18). Live 2026-10-14: the harness's polled "AI on" step came 2:47 after the
-- start (behind other probes) and the old one-shot 2.5 s listener missed cars that were not possessed yet.
bots = { at = -1e12, keys = {}, world = nil, crit = {}, manual = {} }

-- Overnight 2026-10-18 (Jules watching: P2 sat in CRITICAL MALFUNCTION for the rest of the race): the game's AI never
-- answers a critical malfunction on an AI-driven PLAYER car. Every second, each AI-driven local car in a critical
-- malfunction is handled by cfg.TestBotsCrit; "resolve" ends it with the component's own resolve
-- (Server_ResolveCriticalMalfunction(success)) 4 s in.
local CRIT_RESOLVE_MS = 4000

-- couch-fix50 (live round 2 AUTO-129): "resolve" never queues a fault, so cfg.TestBotsCrit picks a human's outcome.
-- couch-fix55 (live round 3 A9: a natural P2 malfunction sat in WaitForPress 30.4 s after the B action): the decode
-- above - the check reads the ACTION VALUE of cfg.Action on the component's EnhancedInputComponent, and the PC's BP
-- event (ignpad.critRecoverPress) never reaches it. A press is now the Enhanced Input injection the game's own input
-- path processes: the player's EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction(cfg.Action, (1,0,0)),
-- once per frame while the press is held (one injection lasts one input tick). A per-frame DRIVER per car does what a
-- human does with B:
--   timeout  hold through WaitForPress + WaitForRelease until TestProgress = 1 (TimeToHoldStart), release -> Testing,
--            then no press: the sweep runs out -> TimedOut -> ApplyFaulyOnTimeout (FAULT);
--   pass     the same, then one press when TestProgress is in [SuccessStart, SuccessEnd) -> Passed ->
--            ApplyFaulyOnSuccess (FAULT);
--   fail     the same, one press at once in Testing (before BonusStart) -> Failed early (no fault: a control);
--   crash    the same, then the crash handler (Vehicle.Crash.Tumble added + removed) in Testing -> ApplyFaulyOnCrashOut
--            (FAULT, only while the car carries the condition tag: a "malf ... direct" start does not);
--   crashpre no press: the crash handler TestBotsCritCrashMs into the malfunction (state 1-3) ->
--            ApplyFaulyOnPreTestCrash (FAULT, the same tag rule).
-- Every mode but "resolve" resolves only after cfg.TestBotsCritGiveUpMs (a bot never sits out the race).
M.CRIT_MODES = { resolve = true, timeout = true, pass = true, fail = true, crash = true, crashpre = true }
local DRIVEN = { timeout = true, pass = true, fail = true, crash = true }
function M.critMode()
    local m = cfg.TestBotsCrit
    return M.CRIT_MODES[m] and m or "resolve"
end
-- pure: the next action of the 1 s tick for a car in a critical malfunction. c = {since, pressed, driving, crashed,
-- resolved} -> "press" | "drive" | "crash" | "resolve" | "giveup" | nil
function M.critPlan(mode, c, now, giveUpMs, crashMs)
    local age = now - c.since
    if c.resolved then return nil end
    if mode == "resolve" then
        if not c.pressed then return "press" end
        return (age >= CRIT_RESOLVE_MS) and "resolve" or nil
    end
    if DRIVEN[mode] and not c.driving then return "drive" end
    if mode == "crashpre" and not c.crashed and age >= crashMs then return "crash" end
    if age >= giveUpMs then return "giveup" end
    return nil
end
-- pure: what the per-frame driver does at this frame. st = the component's state, prog = TestProgress, k = config
-- (critCfg), d = the driver's record {pressedTesting, crashed} -> "hold" | "press" | "crash" | "stop" | nil (nothing)
function M.critDrivePlan(mode, st, prog, k, d)
    if st == nil or st == 0 or st == 5 then return "stop" end
    if st == 2 then return "hold" end
    -- 3 WaitForRelease: hold until TestProgress (held / TimeToHoldStart) is full, then RELEASE (a release before it
    -- goes back to WaitForPress; a press still held at 1.0 never starts the check)
    if st == 3 then return ((tonumber(prog) or 0) < 0.999) and "hold" or nil end
    if st ~= 4 then return nil end                          -- 1 Malfunction: TimeBeforeCheck runs
    if mode == "crash" then return (not d.crashed) and "crash" or nil end
    if d.pressedTesting then return nil end
    if mode == "fail" then return "press" end
    if mode == "pass" then
        prog = tonumber(prog) or 0
        local lo, hi = tonumber(k.SuccessStart), tonumber(k.SuccessEnd)
        if lo and hi and prog >= lo and prog < hi then return "press" end
    end
    return nil                                              -- timeout: never press, the sweep runs out
end

-- the component's own crash handler (the native crash path couchfaults hooks): a tumble added, then removed
local function critCrash(comp)
    if not comp then return false, "no CriticalMalfunctionComponent" end
    local tag = { TagName = U.fname("Vehicle.Crash.Tumble") }
    local ok, err = pcall(function() comp:OnCrashTagChanged_OnClient(tag, true) end)
    if ok then pcall(function() comp:OnCrashTagChanged_OnClient(tag, false) end) end
    return ok, ok and "OnCrashTagChanged_OnClient(Vehicle.Crash.Tumble)" or tostring(err)
end
M._critCrash = critCrash

-- one frame of the B button for this PC: Enhanced Input injection of the check's action (VERIFY live: the component's
-- EnhancedInputComponent reads the value the guest's PlayerInput produces from it)
local EI_CLASS = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
local IA_CRIT = "/Game/Griffin/Config/Input/IA_Veh_CriticalMalfunction.IA_Veh_CriticalMalfunction"
local PRESS_VEC = { X = 1.0, Y = 0.0, Z = 0.0 }
local NO_MODS = {}
function M.critInject(pc, action)
    if not U.ok(pc) then return false, "no PC" end
    if not U.ok(action) then action = U.findLoaded(IA_CRIT) end
    if not U.ok(action) then return false, "no action" end
    local sub = nil
    pcall(function() sub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(pc, U.class(EI_CLASS)) end)
    if not U.ok(sub) then return false, "no EnhancedInputLocalPlayerSubsystem" end
    return pcall(function() sub:InjectInputVectorForAction(action, PRESS_VEC, NO_MODS, NO_MODS) end)
end

-- the per-frame driver of player i's malfunction (bots.crit[i].drive)
M.driveFrames = true            -- the sims step the driver themselves (M._critDriveStep)
local function driveStep(i, pc, car, now)
    local c = bots.crit[i]
    local d = c and c.drive
    if not d or d.done then return false end
    local comp = critComp(car)
    local st = critState(comp)
    local prog = nil
    pcall(function() prog = tonumber(comp.TestProgress) end)
    if st == 4 and not d.testingAt then
        d.testingAt = now
        U.log(TAG, "TestBots: P%d critical malfunction (%s) - Testing after %d frame(s) of the held press (%.1f s in)", i,
            c.mode, d.held, (now - c.since) / 1000)
    end
    local act = M.critDrivePlan(c.mode, st, prog, d.k, d)
    if act == "hold" or act == "press" then
        local ok, err = M.critInject(pc, d.k.Action)
        d.held = d.held + 1
        if not ok and not d.injectErr then
            d.injectErr = tostring(err)
            U.log(TAG, "TestBots: P%d critical malfunction - the press injection FAILED: %s", i, d.injectErr)
        end
        if act == "press" then
            d.pressedTesting = true
            U.log(TAG, "TestBots: P%d critical malfunction (%s) - pressed at TestProgress %s (window %s-%s)", i, c.mode,
                n2(prog), n2(d.k.SuccessStart), n2(d.k.SuccessEnd))
        end
    elseif act == "crash" then
        d.crashed, c.crashed = true, true
        local ok, how = critCrash(comp)
        c.how = ok and "crash" or c.how
        U.log(TAG, "TestBots: P%d critical malfunction (%s) - %s %s in Testing (%s)", i, c.mode, tostring(how),
            ok and "called" or "FAILED", critText(comp))
    elseif act == "stop" then
        d.done = true
        U.log(TAG, "TestBots: P%d critical malfunction driver done (%s, %d press frame(s), %s)", i, c.mode, d.held,
            critText(comp))
        return false
    end
    return true
end
M._critDriveStep = function(i, pc, car, now) return driveStep(i, pc, car, now) end
local function driveLoop(i, pc, car, gen)
    if not M.driveFrames then return end
    local function frame()
        if bots.world ~= gen or St.phase ~= "RACING" or not U.ok(car) then return end
        if U.try(TAG, driveStep, i, pc, car, St.nowMs()) == true then sched.nextFrame(TAG .. ".crit", frame, 16) end
    end
    frame()
end

local function botsCritTick(i, e, car, now)
    local c = bots.crit[i]
    local comp = critComp(car)
    if not inCrit(car, comp) then
        if c then
            U.log(TAG, "TestBots: P%d critical malfunction over (%s, %.1f s; TestBotsCrit %s; %s)", i, c.how,
                (now - c.since) / 1000, c.mode, critText(comp))
            if c.drive then c.drive.done = true end
            bots.crit[i] = nil
        end
        return
    end
    if not c then
        c = { since = now, how = "on its own", mode = M.critMode() }
        bots.crit[i] = c
        U.log(TAG, "TestBots: P%d critical malfunction (TestBotsCrit %s; %s)", i, c.mode, critText(comp))
    end
    local act = M.critPlan(c.mode, c, now, tonumber(cfg.TestBotsCritGiveUpMs) or 30000,
        tonumber(cfg.TestBotsCritCrashMs) or 1500)
    if act == "press" then
        c.pressed = true
        local ig = U.mod("ignpad")
        local ok, err = false, "no ignpad"
        if ig and ig.critRecoverPress then ok, err = ig.critRecoverPress(e.pc) end
        c.how = ok and "B action" or "waiting"
        U.log(TAG, "TestBots: P%d critical malfunction - B action (its PC event) %s", i,
            ok and "called" or ("FAILED: " .. tostring(err)))
    elseif act == "drive" then
        c.driving = true
        local k = critCfg(comp)
        c.drive = { k = k, held = 0 }
        c.how = "driven (" .. c.mode .. ")"
        U.log(TAG, "TestBots: P%d critical malfunction - driver on (%s: the B press as Enhanced Input injection; %s)", i,
            c.mode, cfgText(k))
        driveLoop(i, e.pc, car, bots.world)
    elseif act == "crash" then
        c.crashed = true
        local ok, how = critCrash(comp)
        c.how = ok and "crash" or c.how
        U.log(TAG, "TestBots: P%d critical malfunction (%s) - %s %s %.1f s in (%s)", i, c.mode, tostring(how),
            ok and "called" or "FAILED", (now - c.since) / 1000, critText(comp))
    elseif act == "resolve" or act == "giveup" then
        c.resolved = true
        if c.drive then c.drive.done = true end
        -- couch-fix59 (AUTO-143): couchfaults must not read the tool's resolve as a crash that ended the malfunction
        local cf = package.loaded["couchfaults"]
        if type(cf) == "table" and cf.forcedEnd then pcall(cf.forcedEnd, e.pc) end
        local ok, err = pcall(function()
            if not comp then error("no CriticalMalfunctionComponent") end
            comp:Server_ResolveCriticalMalfunction(true, 1.0, 0.0)
        end)
        c.how = ok and "Server_ResolveCriticalMalfunction" or c.how
        U.log(TAG, "TestBots: P%d still in a critical malfunction after %.1f s%s - Server_ResolveCriticalMalfunction %s", i,
            (now - c.since) / 1000, act == "giveup" and (" (" .. c.mode .. ": gave up, " .. critText(comp) .. ")") or "",
            ok and "called" or ("FAILED: " .. tostring(err)))
    end
end
M._botsCritTick = function(i, e, car, now) bots = bots or { crit = {} }; return botsCritTick(i, e, car, now) end

local function botsTick()
    local mode = cfg.TestBots
    if mode ~= true and mode ~= "all" and mode ~= "guests" and mode ~= "p1" then return end
    if St.phase ~= "RACING" then return end
    local now = St.nowMs()
    if now - bots.at < 1000 then return end
    bots.at = now
    if bots.world ~= St.worldGen then bots.world, bots.keys, bots.crit, bots.manual = St.worldGen, {}, {}, {} end
    for i, e in ipairs(U.localPlayers()) do
        local pick = (mode == "guests" and i >= 2) or (mode == "p1" and i == 1) or mode == true or mode == "all"
        local car = nil
        if pick and U.ok(e.pc) then pcall(function() car = e.pc.Pawn end) end
        if pick and U.ok(car) and bots.manual[i] and bots.manual[i] == U.key(car) then pick = false end  -- "bot i off"
        if pick and U.ok(e.pc) then
            if U.ok(car) and U.isVehicle(car) and bots.keys[i] ~= U.key(car) then
                local ok = pcall(function() car:StartInputSourceOverride_OnServer(C.E.Override.SpawnAI) end)   -- 2: live-verified
                if ok then bots.keys[i] = U.key(car) end
                U.log(TAG, "TestBots (%s): P%d car to the AI%s", tostring(mode), i, ok and "" or " FAILED")
            end
            if U.ok(car) and bots.keys[i] == U.key(car) then U.try(TAG, botsCritTick, i, e, car, now) end
        end
    end
end

local function tick()
    applySpeedy()
    if cfg.TestCommands then U.try(TAG, botsTick) end
    if not cfg.TestCommands then return end
    if not paths() then return end
    local f = io.open(cmdPath, "r")
    if not f then return end
    local text = f:read("a") or ""
    f:close()
    local seq = tonumber(text:match("^%s*seq=(%d+)"))
    if not seq or seq <= lastSeq then return end
    lastSeq = seq
    local lines = {}
    local first = true
    for line in text:gmatch("[^\r\n]+") do
        if first then first = false else
            if not line:match("^%s*#") and line:match("%S") then lines[#lines + 1] = line end
        end
    end
    runBlock(seq, lines)
end

function M.init()
    if not cfg.TestCommands and not cfg.SkipRaceIntro then return end
    if handle then return end
    -- The first poll only records the current seq, so an old test.cmd is not replayed at boot or after a reload.
    if paths() then
        local f = io.open(cmdPath, "r")
        if f then lastSeq = tonumber((f:read("a") or ""):match("^%s*seq=(%d+)")) or -1; f:close() end
    end
    handle = sched.every(TAG, cfg.TestCommandPollMs or 300, tick)
    -- couch-gauntlet: its pick hook and phase listener exist only in a TestCommands build (never for players)
    if cfg.TestCommands then U.try(TAG, function() U.mod("gauntlet").init() end) end
    -- cfg.TestBots: see botsTick (polled from tick: immediate on RACING, re-applied to a respawned car)
    if cfg.TestCommands then U.log(TAG, "test commands on: %s (last seq %d)", tostring(cmdPath), lastSeq) end
end

return M
