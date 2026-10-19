-- soloscore.lua: EVERY PLAYER'S OWN SCORE in a race-alone test raced by 2-4 couch players (finding #37, Jules's round 4
-- 2026-10-17 21:58, Crait = Spaniel L_Spaniel_Loop_A TAKEDOWNS field test, target 12 takedowns / 140 s: "There is a
-- counter only for P1. P1 and P2 should have independent sessions and scores"; #39: every field-test kind).
--
-- HOW THE GAME COUNTS (static, SWGR-Win64-Shipping.exe of the hf2 install, capstone; JMAP Griffin-5.7.4-381121):
--   TakedownEventRules (BP_ModeRules_Takedown_C): Settings +0xd8 (TakedownEventSettings: NumberOfTakedowns, TargetTimes,
--   SharedSettings, BotTuneset), TrackedPlayer +0x100 (GfnPlayerState), TrackedTakedowns +0x108; unreflected: +0x10c
--   race time, +0x110 time the target was reached, +0x114 init done, +0x118 TArray<TakedownEventAIInfo>, +0x128 failed.
--   * Tick (vtable 0x1498fdd90 slot 0x2D8 = 0x142fda342), FIRST racing tick: every car of GameState.Vehicles - a
--     player-controlled one sets TrackedPlayer (each one overwrites it: the LAST human wins = P2 in a couch race), every
--     AI car gets the BotTuneset / SharedSettings and joins the AI list (one list: the AI director - line-up behind
--     0x1470d861e, distance sort 0x1470d8230, the AI's race progress taken relative to the tracked car 0x1470d87f2
--     (vtable slot 0x2b0) - follows TrackedPlayer only; #70 below: the director per copy).
--   * OnVehicleTakedown (exec 0x1470d7e56 -> 0x1470d7f26), bound to the takedown gameplay action: the instigator must
--     be a player-controlled car; with a TrackedPlayer set, ANY OTHER instigator is ignored; TrackedTakedowns += 1; on
--     reaching Settings.NumberOfTakedowns the race time is stamped (+0x110) and the target sound plays.
--   * Tick, race time >= TargetTimes.TimeForGold: TrackedPlayer is finished (0x142fe6c3a) - passed with the stamped
--     time if the count was reached, failed (+0x128 = 1) otherwise. Nobody else is ever finished or failed by the rules
--     (HasRacerFailedModeRules, slot 0x328 = 0x1470d8906, reads TrackedPlayer's state for every racer).
--   * The race VM (0x1470d87ae): RaceEventVM.NumberOfTakedowns = TrackedTakedowns, TargetNumberOfTakedowns =
--     Settings.NumberOfTakedowns, bIsSuccess = reached. WBP_Hud_EventTakedownCounter (cue4cli --script + kismet2txt)
--     keeps that ONE VM in its RaceEventVM variable (set at Construct) and rewrites its text from it every Tick.
--   => live #37: P2 (the last human) was the tracked player from the first tick, so P1's counter showed P2's takedowns
--     (9 while P1 had none) and P2's HUD collapsed its copy (hud.lua GuestHudCollapse: "shows P1's values").
--   RamjetDistanceRules: TrackedPlayer +0xd8 = the FIRST player-controlled car of GameState.Vehicles (Tick 0x1470d7910),
--   TrackedInfo +0xe0 {DistanceInRamjet, PreviousLocation, BestRaceCompletion}: each tick, while the tracked car's
--   VehicleState.RamjetState & 0xfd == 1 (Ready / Active) and its RouteMarker.EventProgressNormalised beats the best,
--   DistanceInRamjet += |location - previous|; VM.RamjetDistance / TargetRamjetDistance (0x1470d7d42), the fail rule
--   (0x1470d7d22) for the tracked player only: the guests' distance is counted nowhere and they never fail.
--
-- WHAT THIS MODULE DOES (cfg.CouchSoloScores, only in a race-alone couch race of kind takedowns / ramjet):
--   * TAKEDOWNS: TrackedPlayer pinned to P1 (the game's count, VM, counter, AI director and time-limit finish are P1's);
--     every takedown seen by a pre-hook of TakedownEventRules:OnVehicleTakedown is booked for its instigator if he is
--     a local player AND the victim races in his instance (instances.sameSet; no instances = his own count of the shared
--     field); after the native body TrackedTakedowns := P1's own count (a cross-set hit never counts for him). #59:
--     a hit P1 does not book (another set's bot, after his own target) runs the native body with TrackedPlayer = the
--     victim for that one call (the native ignores every instigator but the tracked one): no native count, no
--     target-reached stamp from it; P1 tracked again in the post-hook.
--   * RAMJET: every player's distance counted here like the native rule (P1's own value is the game's when it tracks
--     P1).
--   * The guests' HUD counters (WBP_Hud_EventTakedownCounter / WBP_Hud_EventRamjetCounter of their HUD) get a private
--     RaceEventVM each (StaticConstructObject, outer = the guest's HUD), fed from the guest's own count: the game's own
--     widget shows "N/12" and plays its own target-reached animation; hud.lua leaves those counters visible.
--   * A player reaching the takedown target: his test PASSED at that moment (logged), and (cfg.CouchSoloFinishAtTarget)
--     his race is finished there: PlayerRaceEventComponent:Server_Cheat_FinishRace(false) (exec 0x1470c8aa2 ->
--     0x142fc69b6 -> GameMode 0x142fe66b2: finishes that racer if still racing; it sets RacingGameState.
--     bHaveCheatsBeenUsed, put back right after). His finish arms the game's end timeout as any finish: couchsolo /
--     wreck.lua keep it at the test's own limit for the others.
--   * scoreOf(ps) -> his own score for couchrules' result snapshot (couchsolo.verdict: reached = PASSED, else FAILED
--     with the count; the band shows it).
-- [?] (live): the hook fires (UE4SS hook on a delegate-bound native UFunction; if not, a WARN once the game's count
--     moved without it); Server_Cheat_FinishRace finishes the racer in a shipping build (WARN when his REC is still
--     racing 2 s later; his PASSED verdict stands either way); #70: the game's bot director follows P1 only - with
--     separate copies it is replaced by one per copy (M.directorTick).
-- Every game access is pcall-guarded; UObjects only inside one race world.
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "soloscore"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

M.HOOK_TD = "/Script/Griffin.TakedownEventRules:OnVehicleTakedown"
M.VM_CLASS = "/Script/Griffin.RaceEventVM"
M.COUNTERS = { takedowns = "WBP_Hud_EventTakedownCounter", ramjet = "WBP_Hud_EventRamjetCounter" }
M.SCORED = { takedowns = true, ramjet = true }
local RAMJET_MS = 100

---------------------------------------------------------------------------------------------------- pure rules
-- the native ramjet distance step (0x1470d7966..0x1470d7b40): p = {dist, best, prev = {X, Y, Z}}; st = RamjetState,
-- prog = EventProgressNormalised, loc = {X, Y, Z}. -> p (updated), added distance
function M.ramjetStep(p, st, prog, loc)
    local add = 0
    st, prog = tonumber(st) or 0, tonumber(prog)
    if prog and loc and p.prev and (math.floor(st) & 0xfd) == 1 and prog > (p.best or -1e30) then
        local dx, dy, dz = loc.X - p.prev.X, loc.Y - p.prev.Y, loc.Z - p.prev.Z
        add = math.sqrt(dx * dx + dy * dy + dz * dz)
        p.dist = (p.dist or 0) + add
    end
    if loc then p.prev = { X = loc.X, Y = loc.Y, Z = loc.Z } end
    if prog and prog > (p.best or -1e30) then p.best = prog end
    return p, add
end

-- the short score text: "9/12" (takedowns), "1840/2500 M" (ramjet: the game's counter shows units / 100)
function M.scoreText(kind, value, target)
    local v, t = tonumber(value) or 0, tonumber(target)
    if kind == "ramjet" then
        return t and string.format("%d/%d M", math.floor(v / 100), math.floor(t / 100)) or string.format("%d M", math.floor(v / 100))
    end
    return t and string.format("%d/%d", math.floor(v), math.floor(t)) or tostring(math.floor(v))
end

-- a takedown booked for its instigator? who = instigator's pnum (nil = an AI), victimHuman (bool), same =
-- instances.sameSet (true / false / nil = no instances), passed (bool: he already reached the target; his car races on
-- under the AI after his finish, #59: "SUCCESS 28") -> book (bool), why
function M.bookTakedown(who, victimHuman, same, passed)
    if not who then return false, "by an AI" end
    if victimHuman then return false, "a player's car (another instance)" end
    if same == false then return false, "a bot of another player's instance" end
    if passed then return false, "after his own target (his test is already passed)" end
    return true, same == nil and "shared field" or "his own instance"
end

---------------------------------------------------------------------------------------------------- race state
local S = { gen = nil }
local stats = { hookCalls = 0, booked = 0, ignored = 0, finishes = 0, vms = 0, nativeSkipped = 0 }
function M.stats() return stats end
M._state = function() return S end

local function solo() return U.mod("couchsolo") end

-- the scored kind of this race (nil = not a scored race-alone couch race); re-read at most once a second per world
-- (couch-racegc: couchsolo.raceAlone reads the local players, the couch state and the race VM)
local kindMemo = { gen = nil, at = -1e12, k = nil }
function M.kind()
    if opt("CouchSoloScores", true) ~= true then return nil end
    local now = St.nowMs()
    if kindMemo.gen == St.worldGen and now - kindMemo.at < 1000 then return kindMemo.k end
    local ok, k = pcall(function()
        local cs = solo()
        if not cs.raceAlone() then return nil end
        return cs.info().kind
    end)
    kindMemo.gen, kindMemo.at, kindMemo.k = St.worldGen, now, (ok and M.SCORED[k]) and k or nil
    return kindMemo.k
end
M._kindForget = function() kindMemo.gen = nil end

-- hud.lua (collapseGlobalParts): a guest HUD member this module feeds from the guest's own score stays visible
function M.ownsGuestCounter(name)
    local k = M.kind()
    return k ~= nil and type(name) == "string" and M.COUNTERS[k] ~= nil and name:lower() == M.COUNTERS[k]:lower()
end

local function humans()
    -- [pnum] = {pc, ps}: P1 = the first local player, the guests by join's pnum
    local out = {}
    pcall(function()
        local lps = U.localPlayers()
        if lps[1] and U.ok(lps[1].pc) then out[1] = { pc = lps[1].pc } end
    end)
    pcall(function()
        for _, e in ipairs(U.mod("join").joinedList()) do if U.ok(e.pc) then out[e.pnum] = { pc = e.pc } end end
    end)
    for _, h in pairs(out) do pcall(function() h.ps = h.pc.PlayerState end) end
    return out
end

-- the race's rules actor, kept per world while valid (Q8: read every 100 ms by the pin; one wrapper per world)
local rulesMemo = { gen = nil, r = nil }
local function rules()
    if rulesMemo.gen == St.worldGen and rulesMemo.r and U.ok(rulesMemo.r) then return rulesMemo.r end
    local r = nil
    pcall(function() local gm = U.gm(); if U.ok(gm) then r = gm.ModeRules end end)
    r = U.ok(r) and r or nil
    rulesMemo.gen, rulesMemo.r = St.worldGen, r
    return r
end

local function nowServer()
    local t = nil
    pcall(function() local gs = U.gs(); if U.ok(gs) then t = U.callMethod(gs, "GetServerWorldTimeSeconds") end end)
    return tonumber(t)
end

-- seconds since the race's GO (couchsolo's GO sample on the server clock), or nil
local function raceTime()
    local now = nowServer()
    local go = nil
    pcall(function() local g = solo().go; if g and g.gen == St.worldGen then go = g.t end end)
    if now and go then return now - go end
    return nil
end

local function psName(ps)
    local n = "?"
    pcall(function() n = ps:GetPlayerName():ToString() end)
    return n
end

-- a player's PlayerRaceEventComponent, kept for the race (Q8: no wrapper per check)
local function recOfP(p)
    if p.rec and U.ok(p.rec) then return p.rec end
    local ok, rec = pcall(U.getField, p.ps, "RaceEventComponent")
    p.rec = (ok and U.ok(rec)) and rec or nil
    return p.rec
end

-- this world's state; built on first use in a scored race (kind, target, the players)
local function state()
    local k = M.kind()
    if not k then return nil end
    if S.gen == St.worldGen and S.kind == k then return S end
    S = { gen = St.worldGen, kind = k, p = {}, pinLog = nil, target = nil, vmLogged = {}, lastRj = -1e12,
          warnedHook = false }
    local r = rules()
    if r then
        pcall(function()
            if k == "takedowns" then S.target = tonumber(r.Settings.NumberOfTakedowns)
            else S.target = tonumber(r.Settings.DistanceInRamjet) end
        end)
    end
    if k == "takedowns" and S.target then U.try(TAG, M.scaleTarget, S, r) end
    for pnum, h in pairs(humans()) do
        if U.ok(h.ps) then S.p[pnum] = { pnum = pnum, pc = h.pc, ps = h.ps, key = U.key(h.ps), count = 0, dist = 0 } end
    end
    local list = {}
    for pnum in pairs(S.p) do list[#list + 1] = "P" .. pnum end
    table.sort(list)
    U.log(TAG, "%s test: every player his own score (%s), target %s%s", k, table.concat(list, ", "),
        S.target and M.scoreText(k, 0, S.target):match("/(.*)$") or "?",
        (function() local ok, a = pcall(function() return U.mod("instances").active() end)
            return (ok and a) and ", each in his own instance" or ", one shared field" end)())
    return S
end
M._stateNow = state

-- Q8 B (Jules 2026-10-18, audit issue 15): every copy of a takedown test is solo's whole field (P + 7 bots) up to
-- cfg.CouchFieldTestMaxGrid; a copy made smaller (the cap, or the game's builder clamping the grid) gets the target
-- scaled to its opponents (instances.scaleTarget: 12 with 5 of the 7 bots = 9), for every player: the game's own rule
-- (Settings.NumberOfTakedowns of this race's rules actor: P1's counter, its target stamp and the VM read it) and the
-- guests' counters (S.target). Said on the HUD (couch.banner) and in the log. cfg.CouchFieldTestScaleTarget false = the
-- event's target kept (logged WARN: a set may hold too few bots for it)
function M.scaleTarget(st, r)
    local inst = U.mod("instances")
    local setS, fullS, nP = inst.shrunk()
    if not setS then return end
    local t0 = st.target
    local t1 = inst.scaleTarget(t0, setS, fullS)
    if opt("CouchFieldTestScaleTarget", true) ~= true or not t1 or t1 == t0 then
        U.warn(TAG, "takedown target %s kept for sets of %d car(s) (solo's field %d; CouchFieldTestScaleTarget off)",
            tostring(t0), setS, fullS)
        return
    end
    local okW = r and pcall(function() r.Settings.NumberOfTakedowns = t1 end)
    st.target, st.target0 = t1, t0
    local msg = string.format("%d PLAYERS, %d CARS EACH: TAKEDOWN TARGET %d (SOLO %d)", nP, setS, t1, t0)
    U.log(TAG, "takedown target scaled %d -> %d: %d set(s) of %d car(s), solo's field %d (the grid cap / limit); the "
        .. "game's rule %s", t0, t1, nP, setS, fullS, okW and "set" or "NOT set (P1's own count still finishes him)")
    St.emit("status", msg)
    U.try(TAG, function() U.mod("couch").banner(msg, tonumber(opt("CouchFieldTestScaleNoticeMs", 6000)) or 6000) end)
end

local function pOfPs(st, ps)
    if not U.ok(ps) then return nil end
    local k = U.key(ps)
    for _, p in pairs(st.p) do if p.key == k then return p end end
    return nil
end

---------------------------------------------------------------------------------------------------- takedowns
-- TrackedPlayer -> P1 (the native init sets the LAST human; re-checked every FAST tick, cheap)
function M.pinTracked(st)
    if st.kind ~= "takedowns" then return end
    local p1 = st.p[1]
    local r = rules()
    if not (p1 and r) then return end
    local cur = nil
    do local okT, v = pcall(U.getField, r, "TrackedPlayer"); if okT then cur = v end end
    if U.ok(cur) and U.key(cur) == p1.key then return end
    local was = U.ok(cur) and psName(cur) or "nobody"
    local ok = pcall(function()
        r.TrackedPlayer = p1.ps
        r.TrackedTakedowns = p1.count
    end)
    st.pins = (st.pins or 0) + 1
    if st.pins <= 3 then
        U.log(TAG, "the game's takedown count follows ONE player (TrackedPlayer: %s): pinned to P1 %s (%s) - P1's HUD "
            .. "counter, the game's time-limit finish and its bot director are P1's; the others' counts are this "
            .. "module's", was, psName(p1.ps), ok and "ok" or "FAILED")
    end
end

local function vmOf(pnum)
    local p = S.p and S.p[pnum]
    return p and p.vm or nil
end

local function syncVm(p)
    local vm = p.vm
    if not U.ok(vm) then return end
    pcall(function()
        if S.kind == "takedowns" then
            vm.NumberOfTakedowns = math.floor(p.count)
            vm.TargetNumberOfTakedowns = math.floor(S.target or 0)
            vm.bIsSuccess = p.reachedAt ~= nil
        else
            vm.RamjetDistance = p.dist
            vm.TargetRamjetDistance = S.target or 0
            vm.bIsSuccess = p.reachedAt ~= nil
        end
    end)
end

local function finishPlayer(p, why)
    if p.finishAsked then return end
    p.finishAsked = true
    local rec = nil
    pcall(function() rec = p.ps.RaceEventComponent end)
    if not U.ok(rec) then U.warn(TAG, "P%d: no RaceEventComponent to finish", p.pnum); return end
    local racing = true
    pcall(function() racing = U.callMethod(rec, "IsStillRacing") == true end)
    if not racing then return end
    local gs = U.gs()
    local cheats = nil
    pcall(function() cheats = gs.bHaveCheatsBeenUsed end)
    local ok, err = pcall(function() rec:Server_Cheat_FinishRace(false) end)
    if cheats ~= nil then pcall(function() if gs.bHaveCheatsBeenUsed ~= cheats then gs.bHaveCheatsBeenUsed = cheats end end) end
    stats.finishes = stats.finishes + 1
    U.log(TAG, "P%d finishes his own test (%s): Server_Cheat_FinishRace %s", p.pnum, why, ok and "called" or
        ("FAILED: " .. tostring(err)))
    local gen = St.worldGen
    U.mod("sched").after("soloscore.finish." .. p.pnum, 2000, function()
        if St.worldGen ~= gen then return end
        local still, t = true, nil
        pcall(function()
            still = U.callMethod(rec, "IsStillRacing") == true
            t = tonumber(rec.EventFinishTime)
        end)
        if still then
            U.warn(TAG, "P%d is still racing 2 s after his finish call: his test stays PASSED (his score), the race goes "
                .. "on to the time limit", p.pnum)
        else
            U.log(TAG, "P%d finished: EventFinishTime %s", p.pnum, t and string.format("%.2f", t) or "?")
        end
    end)
end

local function reached(p)
    if p.reachedAt then return end
    p.reachedAt = raceTime() or -1
    syncVm(p)
    U.log(TAG, "P%d reached %s at %s: his test PASSED", p.pnum, M.scoreText(S.kind, S.kind == "takedowns" and p.count
        or p.dist, S.target), p.reachedAt >= 0 and string.format("%.2f s", p.reachedAt) or "?")
    -- #68: couchrules' target-missed bits off his REC first (the finish call ingests him at once)
    pcall(function() U.mod("couchrules").clearPreFail(p.ps) end)
    if S.kind == "takedowns" and opt("CouchSoloFinishAtTarget", true) == true then
        -- #72 (tester #4 t11: P1 8/8, his native credits row "Took down 7/8 opponents."): reached() runs in the
        -- PRE-hook of the target takedown; finishing him there took his result (FinishRacer) before the native body
        -- counted that takedown. The finish waits for the post-hook (afterTakedown), a short timer covers a missed one.
        p.finishDue = true
        local gen = St.worldGen
        U.mod("sched").after("soloscore.due." .. p.pnum, 100, function()
            if St.worldGen == gen and p.finishDue then p.finishDue = nil; finishPlayer(p, "target reached") end
        end)
    end
end

-- pre-hook: book the takedown for its instigator (his own instance only)
function M.onTakedown(actionParam)
    if St.phase ~= "RACING" then return end
    local st = state()
    if not st or st.kind ~= "takedowns" then return end
    stats.hookCalls = stats.hookCalls + 1
    local a = U.unwrap(actionParam)
    local inst, vic = nil, nil
    pcall(function() inst = a.Instigator end)
    pcall(function() vic = a.victim end)
    local p = pOfPs(st, inst)
    local vp = pOfPs(st, vic)
    local same = nil
    pcall(function() same = U.mod("instances").sameSet(inst, vic) end)
    local book, why = M.bookTakedown(p and p.pnum or nil, vp ~= nil, same, p ~= nil and p.reachedAt ~= nil)
    if not book then
        stats.ignored = stats.ignored + 1
        if not p and same == false then
            -- #84 b: a takedown ACROSS copies by an AI (silent before): the evidence of a cross-copy damage path
            stats.crossAi = (stats.crossAi or 0) + 1
            U.logEvery("soloscore.crossai", 3000, TAG, "an AI of one copy took down %s of another copy (%d so far): a "
                .. "cross-copy damage path (V-INST-DMG)", U.ok(vic) and psName(vic) or "?", stats.crossAi)
        end
        if p then
            U.log(TAG, "P%d's takedown of %s NOT counted: %s", p.pnum, U.ok(vic) and psName(vic) or "?", why)
            -- #59: the native body counts EVERY hit of the tracked player (P1) - its count, its target-reached stamp
            -- (the time it keeps for the result) and the results' SUCCESS line. It ignores any instigator that is not
            -- TrackedPlayer: for this one call TrackedPlayer is the victim (afterTakedown puts P1 back)
            if p.pnum == 1 then
                local r = rules()
                local stand = nil
                if U.ok(vic) and not vp then stand = vic end
                if not stand then
                    for pn, o in pairs(st.p) do if pn ~= 1 and U.ok(o.ps) then stand = o.ps; break end end
                end
                if r and stand and pcall(function() r.TrackedPlayer = stand end) then
                    st.swapped = true
                    stats.nativeSkipped = (stats.nativeSkipped or 0) + 1
                end
            end
        end
        return
    end
    p.count = p.count + 1
    stats.booked = stats.booked + 1
    U.log(TAG, "P%d takedown %s (%s, %s)", p.pnum, M.scoreText("takedowns", p.count, st.target),
        U.ok(vic) and psName(vic) or "?", why)
    syncVm(p)
    if st.target and st.target > 0 and p.count >= st.target then reached(p) end
end

-- post-hook: the native body counted for TrackedPlayer: P1's own filtered count wins
function M.afterTakedown()
    local st = (S.gen == St.worldGen) and S or nil
    if not st or st.kind ~= "takedowns" then return end
    local r = st.p[1] and rules() or nil
    if r then
        if st.swapped then
            st.swapped = nil
            pcall(function() r.TrackedPlayer = st.p[1].ps end)
        end
        local nat = nil
        pcall(function() nat = tonumber(r.TrackedTakedowns) end)
        if nat ~= st.p[1].count then
            pcall(function() r.TrackedTakedowns = st.p[1].count end)
            if nat and st.target and nat >= st.target and st.p[1].count < st.target then
                U.warn(TAG, "the game counted P1's hit on another instance's bot up to its target (%d): set back to %d "
                    .. "(its target-reached stamp cannot be undone)", nat, st.p[1].count)
            end
        end
    end
    -- #72: a player who reached his target in this takedown is finished now, with the takedown counted
    for _, p in pairs(st.p) do
        if p.finishDue then p.finishDue = nil; finishPlayer(p, "target reached") end
    end
end

---------------------------------------------------------------------------------------------------- ramjet
local function ramjetTick(st)
    local now = St.nowMs()
    if now - st.lastRj < RAMJET_MS then return end
    st.lastRj = now
    local trackedP1 = false
    local r = rules()
    pcall(function() trackedP1 = U.key(r.TrackedPlayer) == st.p[1].key end)
    for pnum, p in pairs(st.p) do
        if not p.done then
            pcall(function()
                local car = p.pc.Pawn
                if not U.ok(car) then return end
                local vs = car.VehicleState
                local stt = tonumber(vs.RamjetState) or 0
                local prog = tonumber(car.RouteMarker.EventProgressNormalised)
                local l = car:K2_GetActorLocation()
                M.ramjetStep(p, stt, prog, { X = l.X, Y = l.Y, Z = l.Z })
            end)
            if pnum == 1 and trackedP1 then
                -- P1's own value is the game's (his HUD counter shows it)
                pcall(function() p.dist = tonumber(r.TrackedInfo.DistanceInRamjet) or p.dist end)
            end
            if st.target and st.target > 0 and p.dist >= st.target then reached(p) end
            if pnum ~= 1 then syncVm(p) end
        end
    end
    -- (the rules set it on their first racing tick: judged 3 s into the race, never while it is still empty)
    local trackedSet = false
    pcall(function() trackedSet = U.ok(r.TrackedPlayer) end)
    st.rjSince = st.rjSince or now
    if not trackedP1 and trackedSet and now - st.rjSince > 3000 and not st.rjWarned then
        st.rjWarned = true
        U.warn(TAG, "ramjet test: the game tracks %s, not P1: P1's distance is this module's too", (function()
            local n = "nobody"; pcall(function() n = psName(r.TrackedPlayer) end); return n end)())
    end
end

---------------------------------------------------------------------------------------------------- guest counters
local function newVm(outer)
    local cls = U.class(M.VM_CLASS)
    if not U.ok(cls) then
        local g = nil
        pcall(function() g = solo()._raceVM() end)
        if U.ok(g) then pcall(function() cls = g:GetClass() end) end
    end
    if not U.ok(cls) then return nil, "no RaceEventVM class" end
    local ok, vm = pcall(StaticConstructObject, cls, outer)
    if not (ok and U.ok(vm)) then return nil, tostring(vm) end
    -- the game VM's descriptive values (mode, names) + the counter's own
    local g = nil
    pcall(function() g = solo()._raceVM() end)
    pcall(function()
        if U.ok(g) then vm.ModeType = g.ModeType end
        if S.kind == "takedowns" then vm.bWantsNumberOfTakedowns = true else vm.bWantsRamjetDistance = true end
    end)
    return vm
end

-- every guest HUD's counter of this kind: his private VM in its RaceEventVM variable, visible (MAIN tick)
local function guestCounters(st)
    local name = M.COUNTERS[st.kind]
    local H = St.hud
    if not (H and H.guests and name) then return end
    local hud = U.mod("hud")
    for _, e in pairs(H.guests) do
        local p = st.p[e.pnum]
        if p and e.pnum ~= 1 and U.ok(e.widget) then
            local list = {}
            pcall(function() list = hud.guestMembers(e, name) end)
            for _, w in ipairs(list) do
                if U.ok(w) then
                    if not (U.ok(p.vm) and p.vmOuter == U.key(e.widget)) then
                        local vm, why = newVm(e.widget)
                        if vm then
                            p.vm, p.vmOuter = vm, U.key(e.widget)
                            stats.vms = stats.vms + 1
                            syncVm(p)
                        elseif not st.vmLogged[e.pnum] then
                            st.vmLogged[e.pnum] = true
                            U.warn(TAG, "P%d's own %s counter: no VM (%s): his counter stays hidden", e.pnum, st.kind, why)
                        end
                    end
                    if U.ok(p.vm) and type(e.hidden) == "table" then
                        -- hud.lua collapsed it before this race was known as scored: out of its re-collapse list
                        local wk = U.key(w)
                        for i = #e.hidden, 1, -1 do
                            if U.key(e.hidden[i]) == wk then table.remove(e.hidden, i) end
                        end
                    end
                    if U.ok(p.vm) then
                        local cur = nil
                        pcall(function() cur = w.RaceEventVM end)
                        if not (U.ok(cur) and U.key(cur) == U.key(p.vm)) then
                            local okS = pcall(function() w.RaceEventVM = p.vm end)
                            pcall(function() w:SetVisibility(4) end)          -- SelfHitTestInvisible
                            U.log(TAG, "P%d's HUD %s: fed from his own count (%s) %s", e.pnum, name,
                                M.scoreText(st.kind, st.kind == "takedowns" and p.count or p.dist, st.target),
                                okS and "ok" or "FAILED")
                        else
                            local vis = nil
                            pcall(function() vis = w:GetVisibility() end)
                            if vis == 1 then pcall(function() w:SetVisibility(4) end) end
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- #70 per-set bot director
-- Tester #4 (2026-10-18, Jakku EVT_SHK_BAT_Car_MAS_B_FWD, separate races): P1 took his 8 down in 40 s, P2 never got
-- past 3/8 - "P2's bots race the line ahead of him". THE GAME'S DIRECTOR (TakedownEventRules Tick 0x142fda342, static,
-- CL381121; every offset named from the JMAP: TakedownEventSharedSettings = Settings.SharedSettings):
--   * every racing tick: the AI list (+0x118, every AI car of GameState.Vehicles, built on the first tick = ALL the
--     copies' bots) gets each bot's route distance to TrackedPlayer's car (0x1470d8230 -> 0x1470e1f9a: RouteMarker.
--     DistanceAroundMainRoute difference, wrapped by half the main route spline's length on a closed loop) and is
--     sorted, most ahead first;
--   * a bot more than MaxDistanceBehind behind the tracked car (and not tumbling: VehicleState.CrashTags holds
--     "Vehicle.Crash.Tumble", the tag the init at 0x1430be52f registers) is reset SpawnDistanceAhead ahead of it
--     (VehicleRequester reset, its speed kept);
--   * no bot within MaximumDistanceforAnyAI of the tracked car (and that car not tumbling): the first
--     NumberOfBotsToRespawn of the list are reset BEHIND it, at SpawnDistanceBehind + k x SpawnBehindGap, at the
--     tracked car's SpeedMPH + SpawnBehindSpeedDiff (at least SpawnBehindMinimumSpeed) - 0x1470d861e: the bots that
--     "come to him". All of it around TrackedPlayer = P1 (pinned above): P2's bots were put back next to P1's car.
-- THIS (cfg.CouchTakedownSetDirector, a takedowns test raced as separate copies): the game's two distances are set out of
-- reach for that race (MaxDistanceBehind / MaximumDistanceforAnyAI = 1e9 on the SharedSettings asset; the originals
-- put back when the race world goes), and the same rules run here for EVERY copy around its own player: his copy's
-- bots, his car, the reflected reset VehicleRequester:RequestResetAtLocation (resetWithProtection, NoTelemetry, as the
-- native call) on the main route spline (GetLocation / GetRotationAtDistanceAlongSpline, world space).
-- Each copy's bots also pace against their own player: AIRaceDirector.VehicleInfos[].RacePacingTarget and
-- RaceAIComponent.mPawnToPaceAgainst / mAggressionTarget pointing at ANOTHER copy's player are pointed at their own.
-- [?] live: the reset of an AI car by the reflected call (the native respawn uses the same requester); the spline
--     distance = DistanceAroundMainRoute on a track with alternative routes (the native follows the marker's own route).
M.TUMBLE_TAG = "Vehicle.Crash.Tumble"
M.NEUTRAL = 1.0e9
M.DIR_MS = 100
M.DIR_FIELDS = { "MaxDistanceBehind", "SpawnDistanceAhead", "MaximumDistanceforAnyAI", "NumberOfBotsToRespawn",
                 "SpawnDistanceBehind", "SpawnBehindGap", "SpawnBehindSpeedDiff", "SpawnBehindMinimumSpeed" }
local BOT_COOL_MS, LINEUP_COOL_MS, PACE_MS = 600, 1500, 2000
-- Q8 (big grids: 4 copies x 8 = 32 cars): the director step runs at 4 Hz (its put-backs have 600 ms cooldowns, the
-- game's own rule thresholds are thousands of units = seconds of driving) and the copies' pawn list is kept 2 s
local DIR_MS, COPIES_MS = 250, 2000
-- the asset's original numbers by its path (plain data: a restore missed in one world is done in the next)
local sharedOrig, sharedPending = {}, {}
local dstats = { ahead = 0, lineups = 0, resets = 0, resetFails = 0, paceWrites = 0 }
function M.dirStats() return dstats end

-- signed route distance a - b (native 0x1470e1f9a): wrapped by half the length on a closed loop
function M.routeDelta(a, b, len, closed)
    local d = (tonumber(a) or 0) - (tonumber(b) or 0)
    len = tonumber(len)
    if closed and len and len > 0 then
        if d > 0.5 * len then d = d - len elseif d < -0.5 * len then d = d + len end
    end
    return d
end

-- one copy's director step (pure). h = {tumbling, speed}; bots = {{k, d (route delta to h), tumbling}...};
-- s = the SharedSettings originals; cool = {[k] = ms until which that bot is left alone, lineup = ms}. -> actions
-- {{k, kind = "ahead" | "lineup", offset (route distance from h), speed (nil = keep his own)}...}
function M.directorStep(h, bots, s, now, cool)
    local acts = {}
    local mdb, mada = tonumber(s.MaxDistanceBehind) or 0, tonumber(s.MaximumDistanceforAnyAI) or 0
    local near = false
    for _, b in ipairs(bots) do if math.abs(b.d) < mada then near = true end end
    local done = {}
    for _, b in ipairs(bots) do
        if b.d < -mdb and not b.tumbling and now >= (cool[b.k] or -1e12) then
            acts[#acts + 1] = { k = b.k, kind = "ahead", offset = tonumber(s.SpawnDistanceAhead) or 0 }
            done[b.k] = #acts
        end
    end
    if not near and not h.tumbling and #bots > 0 and now >= (cool.lineup or -1e12) then
        local list = {}
        for _, b in ipairs(bots) do list[#list + 1] = b end
        table.sort(list, function(x, y) return x.d > y.d end)
        local n = math.min(math.floor(tonumber(s.NumberOfBotsToRespawn) or 0), #list)
        local speed = math.max((tonumber(h.speed) or 0) + (tonumber(s.SpawnBehindSpeedDiff) or 0),
            tonumber(s.SpawnBehindMinimumSpeed) or 0)
        local off = tonumber(s.SpawnDistanceBehind) or 0
        for i = 1, n do
            local a = { k = list[i].k, kind = "lineup", offset = -off, speed = speed }
            if done[a.k] then acts[done[a.k]] = a else acts[#acts + 1] = a end
            off = off + (tonumber(s.SpawnBehindGap) or 0)
        end
    end
    return acts
end

-- UE FRotator::Quaternion
function M.rotQuat(r)
    local h = math.pi / 360
    local p, y, ro = (tonumber(r.Pitch) or 0) * h, (tonumber(r.Yaw) or 0) * h, (tonumber(r.Roll) or 0) * h
    local SP, CP, SY, CY, SR, CR = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    return { X = CR * SP * SY - SR * CP * CY, Y = -CR * SP * CY - SR * CP * SY,
             Z = CR * CP * SY - SR * SP * CY, W = CR * CP * CY + SR * SP * SY }
end

local function tumbling(pawn)
    local t = false
    pcall(function()
        for _, g in ipairs(U.arrayToTable(pawn.VehicleState.CrashTags.GameplayTags)) do
            local n = nil
            pcall(function() n = g.TagName:ToString() end)
            if n == M.TUMBLE_TAG then t = true end
        end
    end)
    return t
end

-- mk = the pawn's RouteMarker kept by copies() (Q8: one wrapper per car per 2 s, not per step); read closure-free
local function routeDist(pawn, mk)
    if mk and U.ok(mk) then
        local ok, d = pcall(U.getField, mk, "DistanceAroundMainRoute")
        if ok then return tonumber(d) end
    end
    local d = nil
    pcall(function() d = tonumber(pawn.RouteMarker.DistanceAroundMainRoute) end)
    return d
end

local function sharedSettings()
    local r = rules()
    local ss = nil
    if r then pcall(function() ss = r.Settings.SharedSettings end) end
    return U.ok(ss) and ss or nil
end

local function readShared(ss)
    local t = {}
    for _, f in ipairs(M.DIR_FIELDS) do pcall(function() t[f] = tonumber(ss[f]) end) end
    return t
end

-- the game's director off for this race (its two distances out of reach), the originals kept by asset path
local function neutralize(st, ss)
    local path = U.pathOf(ss)
    local cur = readShared(ss)
    local orig = sharedOrig[path]
    local curNeutral = (tonumber(cur.MaxDistanceBehind) or 0) >= M.NEUTRAL * 0.5
    if curNeutral and not orig then
        U.warn(TAG, "takedown bot director per copy: %s is already out of reach with no original kept (a mod reload "
            .. "mid-race?): left as it is, no director this race", U.objName(ss))
        return false
    end
    if not curNeutral then orig = cur end
    sharedOrig[path] = orig
    local ok = pcall(function()
        ss.MaxDistanceBehind = M.NEUTRAL
        ss.MaximumDistanceforAnyAI = M.NEUTRAL
    end)
    sharedPending[path] = true
    st.dir.ss, st.dir.path, st.dir.s = ss, path, orig
    local parts = {}
    for _, f in ipairs(M.DIR_FIELDS) do parts[#parts + 1] = string.format("%s %s", f, tostring(orig[f])) end
    U.log(TAG, "takedown bot director per copy: the game's (one bot list around TrackedPlayer = P1) off for this race "
        .. "(%s: MaxDistanceBehind / MaximumDistanceforAnyAI -> out of reach %s); every copy's bots run its rules around "
        .. "their own player: %s", U.objName(ss), ok and "ok" or "FAILED", table.concat(parts, ", "))
    return ok
end

function M.restoreShared(why)
    for path in pairs(sharedPending) do
        local ss = nil
        if S.dir and S.dir.path == path and U.ok(S.dir.ss) then ss = S.dir.ss end
        if not ss then pcall(function() ss = U.findLoaded(path) end) end
        local orig = sharedOrig[path]
        if U.ok(ss) and orig then
            local ok = pcall(function()
                ss.MaxDistanceBehind = orig.MaxDistanceBehind
                ss.MaximumDistanceforAnyAI = orig.MaximumDistanceforAnyAI
            end)
            if ok then sharedPending[path] = nil end
            U.log(TAG, "takedown bot director: the game's put back (%s): %s MaxDistanceBehind %s, "
                .. "MaximumDistanceforAnyAI %s %s", tostring(why), U.objName(ss), tostring(orig.MaxDistanceBehind),
                tostring(orig.MaximumDistanceforAnyAI), ok and "ok" or "FAILED")
        end
    end
end

-- this world's copies: {{owner = pnum, human = pawn, bots = {pawn...}}...} (nil = no separate copies)
local copiesMemo = { gen = nil, at = -1e12, v = nil }
local function copiesBuild()
    local inst = U.mod("instances")
    local okA, act = pcall(function() return inst.active() end)
    if not (okA and act) then return nil end
    local sets = nil
    pcall(function() sets = inst.setList() end)
    if type(sets) ~= "table" or #sets < 2 then return nil end
    local byPs = {}
    pcall(function()
        local vs = U.gs().Vehicles
        for i = 1, U.arrayCount(vs) do
            local v = vs[i]
            if U.ok(v) then
                local ps = v.PlayerState
                if U.ok(ps) then byPs[U.key(ps)] = v end
            end
        end
    end)
    local out = {}
    for s, set in ipairs(sets) do
        local c = { owner = set.owner, set = s, bots = {}, mk = {}, ai = {}, buf = {} }
        for j, ps in ipairs(set.ps or {}) do
            local pawn = U.ok(ps) and byPs[U.key(ps)] or nil
            if pawn then
                if j == 1 then c.human = pawn else c.bots[#c.bots + 1] = pawn end
                local okM, mk = pcall(U.getField, pawn, "RouteMarker")
                if okM and U.ok(mk) then c.mk[U.key(pawn)] = mk end
                if j > 1 then
                    local okA, ai = pcall(U.getField, pawn, "RaceAIComponent")
                    if okA and U.ok(ai) then c.ai[U.key(pawn)] = ai end
                end
            end
        end
        if c.human then out[#out + 1] = c end
    end
    return #out >= 2 and out or nil
end
local function copies()
    local now = St.nowMs()
    local m = copiesMemo
    if m.gen == St.worldGen and now - m.at < COPIES_MS and m.v then
        local okAll = true
        for _, c in ipairs(m.v) do if not U.ok(c.human) then okAll = false; break end end
        if okAll then return m.v end
    end
    m.gen, m.at, m.v = St.worldGen, now, copiesBuild()
    return m.v
end

local function splineOf(st, pawn)
    if U.ok(st.dir.spline) then return st.dir.spline, st.dir.len, st.dir.closed end
    local sp = nil
    pcall(function() sp = pawn.RouteMarker.mRoute.mMainRouteSpline end)
    if not U.ok(sp) then return nil end
    local len, closed = nil, false
    pcall(function() len = tonumber(U.callMethod(sp, "GetSplineLength")) end)
    pcall(function() closed = U.callMethod(sp, "IsClosedLoop") == true end)
    if not (len and len > 0) then return nil end                     -- not a usable route yet: asked again next tick
    st.dir.spline, st.dir.len, st.dir.closed = sp, len, closed
    U.log(TAG, "takedown bot director: main route spline %s, length %s, %s", U.objName(sp), tostring(len),
        closed and "closed loop" or "point to point")
    return sp, len, closed
end

local function resetAt(st, bot, at, speed)
    local sp, len, closed = st.dir.spline, st.dir.len, st.dir.closed
    if not U.ok(sp) then return false, "no spline" end
    if len and len > 0 then
        if closed then at = at % len else at = math.max(0, math.min(len, at)) end
    end
    local ok, err = pcall(function()
        local l = U.callMethod(sp, "GetLocationAtDistanceAlongSpline", at, 1)
        local r = U.callMethod(sp, "GetRotationAtDistanceAlongSpline", at, 1)
        local T = { Rotation = M.rotQuat(r), Translation = { X = l.X, Y = l.Y, Z = l.Z },
                    Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
        bot.VehicleRequester:RequestResetAtLocation(T, speed, true, false, 1, false)
    end)
    dstats.resets = dstats.resets + 1
    if not ok then dstats.resetFails = dstats.resetFails + 1 end
    return ok, err
end

-- pacing / aggression targets: a copy's bot pointed at another copy's player -> his own
local function paceTick(st, cs)
    local now = St.nowMs()
    if now - (st.dir.paceAt or -1e12) < PACE_MS then return end
    st.dir.paceAt = now
    local ownerOf, humanOf = {}, {}
    for _, c in ipairs(cs) do
        humanOf[U.key(c.human)] = c.owner
        for _, b in ipairs(c.bots) do ownerOf[U.key(b)] = c end
    end
    local seen, fixed = {}, 0
    local function fix(c, pawn, cur, write, what)
        if not U.ok(cur) then return end
        local who = humanOf[U.key(cur)]
        if who == nil then return end
        local key = string.format("copy %d %s -> P%d", c.set, what, who)
        seen[key] = (seen[key] or 0) + 1
        if who ~= c.owner and pcall(write) then
            fixed = fixed + 1
            dstats.paceWrites = dstats.paceWrites + 1
        end
    end
    pcall(function()
        local infos = U.gs().RaceDirector.VehicleInfos
        for i = 1, U.arrayCount(infos) do
            local e = infos[i]
            local v = nil
            pcall(function() v = e.Vehicle end)
            local c = U.ok(v) and ownerOf[U.key(v)] or nil
            if c then
                local cur = nil
                pcall(function() cur = e.RacePacingTarget end)
                fix(c, v, cur, function() e.RacePacingTarget = c.human end, "RacePacingTarget")
            end
        end
    end)
    for _, c in ipairs(cs) do
        for _, b in ipairs(c.bots) do
            local ai = c.ai and c.ai[U.key(b)] or nil
            if not U.ok(ai) then ai = nil; pcall(function() ai = b.RaceAIComponent end) end
            if U.ok(ai) then
                local p, a = nil, nil
                pcall(function() p = ai.mPawnToPaceAgainst end)
                pcall(function() a = ai.mAggressionTarget end)
                fix(c, b, p, function() ai.mPawnToPaceAgainst = c.human end, "mPawnToPaceAgainst")
                fix(c, b, a, function() ai.mAggressionTarget = c.human end, "mAggressionTarget")
            end
        end
    end
    -- logged once, then on a rewrite (at most 3 more times a race)
    local first = not st.dir.paceLogged
    if first or (fixed > 0 and (st.dir.paceFixLogs or 0) < 3) then
        st.dir.paceLogged = true
        if fixed > 0 then st.dir.paceFixLogs = (st.dir.paceFixLogs or 0) + 1 end
        local list = {}
        for k, n in pairs(seen) do list[#list + 1] = string.format("%s x%d", k, n) end
        table.sort(list)
        U.log(TAG, "takedown bots' targets: %s; %d pointed at their own player", #list > 0 and table.concat(list, ", ")
            or "none set", fixed)
    end
end

-- FAST (10 Hz, takedowns): every copy's director step
function M.directorTick(st)
    if opt("CouchTakedownSetDirector", true) ~= true then return end
    st.dir = st.dir or { cool = {}, on = false }
    if st.dir.off then return end
    local now0 = St.nowMs()
    if now0 - (st.dir.at or -1e12) < DIR_MS then return end
    st.dir.at = now0
    local cs = copies()
    if not cs then return end
    if not st.dir.on then
        local ss = sharedSettings()
        if not ss then
            st.dir.off = true
            U.warn(TAG, "takedown bot director per copy: no SharedSettings on the rules - the game's director stays (P2's "
                .. "bots follow P1)")
            return
        end
        if not neutralize(st, ss) then st.dir.off = true; return end
        st.dir.on = true
    end
    local now = St.nowMs()
    local s = st.dir.s
    for _, c in ipairs(cs) do
        local p = nil
        for _, q in pairs(st.p) do if q.pnum == c.owner then p = q end end
        local racing = true
        if p then
            local okR, v = pcall(U.callMethod, recOfP(p), "IsStillRacing")
            if okR then racing = v ~= false end
        end
        local hd = routeDist(c.human, c.mk[U.key(c.human)])
        local sp, len, closed = splineOf(st, c.human)
        if racing and hd and sp then
            local h = { tumbling = false, speed = 0 }
            pcall(function() h.speed = tonumber(c.human.VehicleState.SpeedMPH) or 0 end)
            -- Q8 (32-car grids): the crash tags (an array walk per car) are read only where directorStep looks at them:
            -- a bot past MaxDistanceBehind, the human when no bot is within MaximumDistanceforAnyAI
            local mdb, mada = tonumber(s.MaxDistanceBehind) or 0, tonumber(s.MaximumDistanceforAnyAI) or 0
            -- the entries are reused from step to step (c.buf: one table per bot for the copies' 2 s)
            local bots, byK, near, n = c.buf, c.byK or {}, false, 0
            c.byK = byK
            for _, b in ipairs(c.bots) do
                local k = U.key(b)
                local bd = routeDist(b, c.mk[k])
                if bd then
                    local d = M.routeDelta(bd, hd, len, closed)
                    n = n + 1
                    local e = bots[n]
                    if not e then e = {}; bots[n] = e end
                    e.k, e.d, e.tumbling = k, d, d < -mdb and tumbling(b) or false
                    byK[k] = b
                    if math.abs(d) < mada then near = true end
                end
            end
            for i = #bots, n + 1, -1 do bots[i] = nil end
            if not near then h.tumbling = tumbling(c.human) end
            st.dir.cool[c.set] = st.dir.cool[c.set] or {}
            local cool = st.dir.cool[c.set]
            local acts = M.directorStep(h, bots, s, now, cool)
            local lined = 0
            for _, a in ipairs(acts) do
                local b = byK[a.k]
                local speed = a.speed
                if speed == nil then pcall(function() speed = tonumber(b.VehicleState.SpeedMPH) or 0 end) end
                local ok, err = resetAt(st, b, hd + a.offset, speed or 0)
                cool[a.k] = now + BOT_COOL_MS
                if a.kind == "lineup" then
                    lined = lined + 1
                else
                    dstats.ahead = dstats.ahead + 1
                    if dstats.ahead <= 5 or dstats.ahead % 25 == 0 then
                        U.log(TAG, "copy %d (P%d): a bot more than %s behind put back %s ahead of P%d %s (%d so far)",
                            c.set, c.owner, tostring(s.MaxDistanceBehind), tostring(s.SpawnDistanceAhead), c.owner,
                            ok and "ok" or ("FAILED: " .. tostring(err)), dstats.ahead)
                    end
                end
            end
            if lined > 0 then
                cool.lineup = now + LINEUP_COOL_MS
                dstats.lineups = dstats.lineups + 1
                if dstats.lineups <= 5 or dstats.lineups % 10 == 0 then
                    U.log(TAG, "copy %d (P%d): no bot within %s - %d lined up behind him (from %s, gap %s) at %d mph "
                        .. "(%d so far)", c.set, c.owner, tostring(s.MaximumDistanceforAnyAI), lined,
                        tostring(s.SpawnDistanceBehind), tostring(s.SpawnBehindGap),
                        math.floor(math.max((h.speed or 0) + (tonumber(s.SpawnBehindSpeedDiff) or 0),
                            tonumber(s.SpawnBehindMinimumSpeed) or 0)), dstats.lineups)
                end
            end
        end
    end
    paceTick(st, cs)
end

---------------------------------------------------------------------------------------------------- ticks
function M.fastTick()
    if St.phase ~= "RACING" then return end
    local st = state()
    if not st then return end
    -- 10 Hz is enough for the pin / the finish checks / the ramjet samples (couch-racegc: no work every FAST tick)
    local now = St.nowMs()
    if now - (st.lastFast or -1e12) < RAMJET_MS then return end
    st.lastFast = now
    st.lastRj = -1e12
    if st.kind == "takedowns" then
        M.pinTracked(st)
        U.try(TAG, M.directorTick, st)
        -- the hook never fired while the game's own count moved: a WARN (the guests' counts stay 0)
        if stats.hookCalls == 0 and not st.warnedHook then
            local r = rules()
            local nat = 0
            pcall(function() nat = tonumber(r.TrackedTakedowns) or 0 end)
            if nat > 0 then
                st.warnedHook = true
                U.warn(TAG, "the game counted %d takedown(s) but the OnVehicleTakedown hook never fired: only the game's "
                    .. "count (P1's) works this race", nat)
            end
        end
    else
        ramjetTick(st)
    end
    -- a player's race over: no more scoring for him (4 Hz: Q8, up to 4 players)
    if now - (st.doneAt or -1e12) < DIR_MS then return end
    st.doneAt = now
    for _, p in pairs(st.p) do
        if not p.done then
            local okR, v = pcall(U.callMethod, recOfP(p), "IsStillRacing")
            if okR and v == false then p.done = true end
        end
    end
end

function M.mainTick()
    if St.phase ~= "RACING" then return end
    local st = state()
    if not st then return end
    U.try(TAG, guestCounters, st)
end

-- couchrules' result snapshot: this player's own score (nil = not a scored race)
function M.scoreOf(ps)
    local st = (S.gen == St.worldGen) and S or nil
    if not st then return nil end
    local p = pOfPs(st, ps)
    if not p then return nil end
    local v = st.kind == "takedowns" and p.count or p.dist
    return { kind = st.kind, value = v, target = st.target, reached = p.reachedAt ~= nil, reachedAt = p.reachedAt,
             text = M.scoreText(st.kind, v, st.target) }
end

function M.status()
    if S.gen ~= St.worldGen or not S.kind then return "soloscore: idle" end
    local parts = {}
    for pnum, p in pairs(S.p) do
        parts[#parts + 1] = string.format("P%d %s%s", pnum, M.scoreText(S.kind, S.kind == "takedowns" and p.count or p.dist,
            S.target), p.reachedAt and " (passed)" or "")
    end
    table.sort(parts)
    return string.format("soloscore: %s %s; hook %d, booked %d, ignored %d", S.kind, table.concat(parts, ", "),
        stats.hookCalls, stats.booked, stats.ignored)
end

function M.init()
    U.hook(M.HOOK_TD, {
        pre = function(_, action) U.try(TAG, M.onTakedown, action) end,
        post = function() U.try(TAG, M.afterTakedown) end,
    }, TAG)
    -- #70: the takedown director's asset values go back with the race world (a missed one in the next world)
    St.on("world", TAG, function() U.try(TAG, M.restoreShared, "world change"); S = { gen = nil }; kindMemo.gen = nil end)
    St.on("leaving", TAG, function() U.try(TAG, M.restoreShared, "leaving"); S = { gen = nil }; kindMemo.gen = nil end)
    St.on("phase", TAG, function(new)
        kindMemo.gen = nil
        if new ~= "RACING" and next(sharedPending) ~= nil then U.try(TAG, M.restoreShared, "phase " .. tostring(new)) end
    end)
end

M._vmOf = vmOf
return M
