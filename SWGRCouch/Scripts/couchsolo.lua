-- couchsolo.lua: COUCH RACE-ALONE EVENTS (couch-fieldtest, Jules's live round 3 2026-10-17, findings #34 / #35): the game's
-- single-player test modes (a campaign FIELD TEST, a PODRACER TEST, any TimeTrial / HotLap / Takedowns / RamjetDistance
-- / PrecisionDriving event) raced by 2-4 couch players at once. Each player runs HIS OWN test: his own time limit, his
-- own result screen values; the run (the mission counted as passed) follows the team rule (couchrules D1/D3).
--
-- #34 (19:42 L_Mastiff_LOOP_A, EVT_SHK_BAT_Bike_MAS_A_REV = Takedowns x8, target 120 s): P2 (AI-driven guest) reached his
--   8 takedowns at 19:44:26; the game armed its end-of-race timeout (FinishRacer: RaceTimeoutTime = now + 2 s, the
--   GameMode byte) and wreck.lua's guard DISARMED it ("race timeout disarmed (human finish; 1 human(s) still racing)"):
--   the guard exists for normal races (the first human home must not end the race for the others), but in a test it
--   left P1's test without any end - nothing else ever ends a test that misses its target (P1 drove on for 3 min and
--   quit from the pause menu). NOW: in a race-alone event with a target time (TimeTrial, Takedowns: their authored
--   TargetTimes are the pass line) the armed timeout is KEPT and moved to the TEST'S OWN LIMIT: RaceStartTime + the
--   target (+ cfg.CouchSoloLimitGraceSec). The others race on until then (the game's HUD "Remaining" line counts it
--   down: WBP_Hud_EventTimes_List shows RaceTimeoutTime - now), and the race ends natively at that moment for whoever
--   is still out (EndRace books them unfinished = the test failed). A wreck arms the same timeout: same rule. Events
--   without a target time (HotLap's is a lap time, PrecisionDriving's gates shorten the clock, RamjetDistance has none)
--   keep the old guard: the others race to their own finish.
-- #89 (live 2026-10-18 09:06, podracer test): a TIME TRIAL's limit is its target x cfg.CouchSoloTimeTrialCap (the game
--   never ends one at its target: a solo player races to the line and gets his failed time); its verdicts use the
--   game's own pass line = TimeForGold (M.passLine), each player's medal shows on his card when the event authors
--   distinct medal times; the owner-read screens are patched with P1's result also when the guest who owns them did
--   not race at all (a sit-out: his REC never finished -> "PASSED" outro, "--:--.--" time).
-- #35 (19:58 L_Mastiff_LOOP_B, EVT_SHK_PRT_Skimmer_MAS_B_REV = TimeTrial 2 laps, target 120 s; P1 02:09.60 failed, P2
--   passed): "the end screen said PASSED, the time screen FAILED with a time under the target". Decoded (cue4cli --script
--   + kismet2txt, hotfixed paks): every post-race screen is created by UIManager for the LAST local PC (the guest), and
--     WBP_PostRace_Info (the race outro: Txt_Title / Txt_Secondary) = GetOwningPlayer().PlayerState.RaceEventComponent
--       :HasPlayerFailedEvent() -> RaceOutroTextSuccess / Failure = P2's verdict ("PASSED");
--     WBP_Shakedown_Results_Presentation (inside WBP_PostRace_Results_Shakedown_Presentation) Txt_TimeResult =
--       FormatRaceTime(owner's REC.EventFinishTime) = P2's time, but its verdict (UpdateResult / medal / audio) =
--       ViewModelSubsystem:GetRaceEventVM().bIsSuccess = P1's result ("FAILED"); Txt_BeatBestTime from the owner's time.
--   NOW (cfg.CouchSoloResults): while those screens show after a race-alone couch event, their owner-read values are
--   written back with P1's OWN result (they are P1's run screens: his time vs the target, his verdict), and a
--   display-only results band gives EVERY player his own card: his time, his verdict, and the team line ("FAILED -
--   P2 PASSED: THE TEST COUNTS"); the mission counts as passed when the team rule says so (couchrules: "best" = any
--   player passed, "p1" = P1's).
-- Instances (#34 / Jules's design for every race-alone event): a 1-car test (Field Test TimeTrial / Precision /
--   Ramjet: GridMakeup PlayerChoice x1) gives each player his own set of 1 car (instances.planSolo: per-view hide, no
--   collision, his own place / timer / result); a test with its own opponents on the grid (SHK_BAT Takedowns: Car x8 +
--   7 CustomOpponents) gets one copy of its field per player in PaddockGameMode:FinishLeaving (#37 / #39 / #51: couch.fieldTestPre / Post,
--   instances.assignGrid); each player's own takedown count / ramjet distance = soloscore.lua (h.snap.score: verdict()
--   reads it instead of the game's fail bits, which follow ONE tracked player).
-- Reflected names [JMAP Griffin-5.7.4-381121, jmapq.py]: RacingGameState.RaceStartTime (Double @0x378), RaceTimeoutTime
--   (Double @0x380), GetServerWorldTimeSeconds(); RacingGameMode.ModeRules -> TimeTrialRules / HotLapRules /
--   PrecisionDrivingRules / TakedownEventRules .Settings.TargetTimes {TimeForGold, TimeForSilver, TimeForBronze}
--   (AuthoredTargetTimes); RaceEventVM.ModeType (ERaceEventModeType: 2 TimeTrial, 3 HotLap, 6 Takedowns,
--   7 RamjetDistance, 8 PrecisionDriving), CurrentTargetTime, bIsSuccess, RaceOutroTextSuccess / Failure,
--   RaceOutroInfoTextSuccess / Failure; PlayerRaceEventComponent.EventFinishTime, bHasTimedOut, FailReasons,
--   HasPlayerFailedEvent().
-- Every game access is pcall-guarded; no UObject is kept across worlds.
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "couchsolo"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

---------------------------------------------------------------------------------------------------- pure rules
M.MODE = { [2] = "timetrial", [3] = "hotlap", [6] = "takedowns", [7] = "ramjet", [8] = "precision" }
local RULES_PAT = { { "TimeTrial", "timetrial" }, { "HotLap", "hotlap" }, { "Takedown", "takedowns" },
                    { "RamjetDistance", "ramjet" }, { "Precision", "precision" } }
-- the kinds whose authored target time is the test's pass line = its time limit
M.LIMITED = { timetrial = true, takedowns = true }
M.NAME = { timetrial = "TIME TRIAL", hotlap = "HOT LAP", takedowns = "TAKEDOWN TEST", ramjet = "RAMJET TEST",
           precision = "PRECISION TEST" }

-- ERaceEventModeType (the race VM) and / or the mode rules' class name -> kind, or nil (a normal race mode)
function M.modeKind(modeType, rulesClass)
    local k = M.MODE[tonumber(modeType) or -1]
    if k then return k end
    if type(rulesClass) == "string" and rulesClass ~= "" then
        for _, p in ipairs(RULES_PAT) do if rulesClass:find(p[1], 1, true) then return p[2] end end
    end
    return nil
end

-- the test's limit = its loosest authored target (gold / silver / bronze; the campaign's field tests author all three
-- equal); nil when none is > 0
function M.limitOf(t)
    if type(t) ~= "table" then return nil end
    local best = nil
    for _, k in ipairs({ "gold", "silver", "bronze" }) do
        local v = tonumber(t[k])
        if v and v > 0 and (best == nil or v > best) then best = v end
    end
    return best
end

-- #89 (live 2026-10-18 09:03-09:06, Crait podracer test EVT_TT_SPA_A_PLANE: TimeForGold 113, silver / bronze 0).
-- THE GAME'S OWN PASS LINE (static, hf2 SWG-Win64-Shipping.exe, CL381121; TimeTrialRules vtable 0x1498fed50 vs the
-- base rules 0x1498fbd70): slot 0x398 HasRacerFailedModeRules = 0x1470d922c: failed = NOT (REC.EventFinishTime (+0xf0)
-- < Settings.TargetTimes.TimeForGold (+0xd8) + eps) (0x1470af1c2 = "b + eps > a"); slot 0x380, the race VM fill
-- 0x1470d9162: VM.CurrentTargetTime (+0x1b4) = TimeForGold, VM.bIsSuccess = CurrentEventTime < TimeForGold + eps,
-- VM.CurrentTargetTimeRank from the targets. PrecisionDrivingRules (0x1470d780c / 0x1470d77ae) the same on ITS gold
-- (+0xdc). Silver / bronze are medals only: the pass line is GOLD (an authored 0 = no such medal). Neither rule ends a
-- run: a solo player races to the line and gets his failed time (live: P1 02:03.91 > 01:53.00, FAILED natively).
-- -> the pass line (gold; else the loosest positive target), nil when none
function M.passLine(t)
    if type(t) ~= "table" then return nil end
    local g = tonumber(t.gold)
    if g and g > 0 then return g end
    return M.limitOf(t)
end

-- #89: a player's medal from his own time (gold / silver / bronze, the authored > 0 ones), nil = none. medals (bool):
-- the event authors distinct medal times (the campaign's field tests author three equal ones = one pass line)
function M.medalOf(time, t)
    local x = tonumber(time)
    if not x or x < 0 or type(t) ~= "table" then return nil, false end
    local seen, n = {}, 0
    for _, k in ipairs({ "gold", "silver", "bronze" }) do
        local v = tonumber(t[k])
        if v and v > 0 and not seen[v] then seen[v] = true; n = n + 1 end
    end
    for _, k in ipairs({ "gold", "silver", "bronze" }) do
        local v = tonumber(t[k])
        if v and v > 0 and x < v + 0.005 then return k:upper(), n > 1 end
    end
    return nil, n > 1
end

-- the race's start on the server clock. #36 (live round 4a, Takedowns): a finisher's EventFinishTime is NOT the time
-- since GO in every mode (P2 finished 154 s after GO, his EventFinishTime put the start ~100 s late: deadline 256.75
-- instead of ~153), so the trusted source is the mod's own GO sample (go: GetServerWorldTimeSeconds read at the
-- PRERACE -> RACING edge, the SAME clock as RaceTimeoutTime). RaceStartTime is used when it agrees with that sample
-- (within 5 s); without a sample, the old rule: RaceStartTime when it agrees with the finisher (or there is none),
-- else derived from the finisher (now - his EventFinishTime). -> start, how (nil when nothing can be trusted)
function M.startOf(raceStart, now, finT, go)
    local s, n, f, g = tonumber(raceStart), tonumber(now), tonumber(finT), tonumber(go)
    if not n then return nil, "no server time" end
    local sane = s and s > 0 and s <= n
    if g and g >= 0 and g <= n + 0.25 then
        if sane and math.abs(s - g) <= 5 then return s, "RaceStartTime" end
        return g, "the race's GO (mod clock sample)"
    end
    if sane and f and f >= 0 and math.abs((n - s) - f) > 5 then sane = false end
    if sane then return s, "RaceStartTime" end
    if f and f >= 0 and f <= n then return n - f, "the finisher's race time" end
    return nil, "no race start"
end

-- the timeout decision when the game armed its end-of-race timeout in a race-alone event while humans still race.
-- s = {now, start, limit, grace}. -> {act = "limit", T} (keep it, ending at the test's own limit) | {act = "over"}
-- (the limit is already over: the game's own 2 s ends it) | {act = "nolimit", why} (the old guard: disarm)
function M.timeoutPlan(s)
    local now, start, limit = tonumber(s.now), tonumber(s.start), tonumber(s.limit)
    if not limit then return { act = "nolimit", why = "no target time" } end
    if not (now and start) then return { act = "nolimit", why = "no race clock" } end
    local T = start + limit + math.max(0, tonumber(s.grace) or 0)
    if T <= now + 0.25 then return { act = "over", T = T } end
    return { act = "limit", T = T }
end

-- "02:09.60" (the game's FormatRaceTime look); "--:--.--" when unknown / DNF
function M.fmtTime(sec)
    local t = tonumber(sec)
    if not t or t < 0 then return "--:--.--" end
    local m = math.floor(t / 60)
    return string.format("%02d:%05.2f", m, t - m * 60)
end

-- one player's own verdict from his result snapshot (couchrules: taken at HIS finish, before any team bookkeeping).
-- s = {fin, wrecked, elim, timedOut, fail, failedCall, time}; limit = the test's target when it is a time limit.
-- -> "passed" | "failed" | "wrecked" | "dnf", why
function M.verdict(s, limit)
    if type(s) ~= "table" then return "dnf", "no result" end
    if s.wrecked then return "wrecked", "wrecked" end
    -- #37: a scored test (soloscore: takedowns / ramjet distance): his own count decides, not the game's fail bits (the
    -- game's mode rule reads ONE tracked player for everybody)
    local sc = s.score
    if type(sc) == "table" then
        if sc.reached then return "passed", (sc.text or "?") .. " reached" end
        if s.elim then return "failed", "eliminated" end
        if sc.kind == "takedowns" or s.fin then return "failed", (sc.text or "?") .. ": target missed" end
        return "dnf", "not finished"
    end
    if s.elim then return "failed", "eliminated" end
    if not s.fin then return "dnf", "not finished" end
    local t = tonumber(s.time)
    if not t or t < 0 then return "dnf", "no finish time (the race ended first)" end
    if s.timedOut then return "failed", "timed out" end
    if math.floor(tonumber(s.fail) or 0) ~= 0 then return "failed", "fail reasons " .. math.floor(tonumber(s.fail)) end
    if s.failedCall == true then return "failed", "HasPlayerFailedEvent" end
    if limit and t > limit + 0.005 then return "failed", string.format("%.2f over the target %.2f", t, limit) end
    return "passed", "target met"
end

local WORD = { passed = "PASSED", failed = "FAILED", wrecked = "WRECKED", dnf = "DID NOT FINISH" }
M.WORD = WORD

-- every player's card + the team line. humans = { {pnum, isP1, snap} }; rule "best" | "p1"; limit (or nil); carrier =
-- the player whose result the run counts (couchrules M.last.carrier: couch-fix34, the first player who PASSED a team
-- test - the booking is held until everyone is done and repaired into his pass), when known: the team line follows
-- it, so the screens never claim a pass the run did not count (out.gap: a pass the run did not count - kept for the
-- "p1"-less edge cases, e.g. an old race result).
-- -> { players = { {pnum, isP1, verdict, why, time, word, note} }, passed = bool, by = pnum | nil, banner, gap }
function M.results(humans, rule, limit, testName, carrier, targets)
    local out = { players = {}, passed = false, by = nil }
    local p1 = nil
    for _, h in ipairs(humans or {}) do
        local v, why = M.verdict(h.snap, limit)
        local e = { pnum = h.pnum, isP1 = h.isP1 == true, verdict = v, why = why,
                    time = h.snap and tonumber(h.snap.time) or nil, word = WORD[v] or "?" }
        local sc = h.snap and h.snap.score
        if type(sc) == "table" then
            e.score = sc.text
            -- a passed takedown test's result is the moment the count was reached (the game's own: the tracked player's
            -- stamped time), also without a finish (CouchSoloFinishAtTarget off / the finish call refused)
            if v == "passed" and tonumber(sc.reachedAt) and sc.reachedAt >= 0
                and (sc.kind == "takedowns" or not (e.time and e.time >= 0)) then
                e.time = sc.reachedAt
            end
            -- a takedowns test he did NOT pass ends at its time limit (the game's timeout): his EventFinishTime then is
            -- no race time (live 2026-10-18, tester #3: "P2 FAILED 4/6 04:15.65" with a 100 s limit, "1/8 05:56.40" /
            -- "5/8 05:09.02" with 140 / 120 s) -> the limit is his time
            local lim = tonumber(limit)
            if v ~= "passed" and sc.kind == "takedowns" and lim and lim > 0 and e.time and e.time > lim + 0.5 then
                e.time = lim
            end
        end
        -- #89: his own medal (an event with distinct medal times; the verdict stays the game's gold line)
        if e.verdict ~= "wrecked" and e.verdict ~= "dnf" and not e.score then
            local md, distinct = M.medalOf(e.time, targets)
            if distinct then e.medal = md or "NO MEDAL" end
        end
        out.players[#out.players + 1] = e
        if e.isP1 then p1 = e end
    end
    table.sort(out.players, function(a, b) return (a.pnum or 9) < (b.pnum or 9) end)
    local anyPass = nil
    for _, e in ipairs(out.players) do if e.verdict == "passed" and not anyPass then anyPass = e.pnum end end
    if rule == "p1" then
        if p1 and p1.verdict == "passed" then out.passed, out.by = true, 1 end
    elseif carrier then
        for _, e in ipairs(out.players) do
            if e.pnum == carrier and e.verdict == "passed" then out.passed, out.by = true, e.pnum end
        end
        if not out.passed and anyPass then out.gap = anyPass end
    elseif anyPass then
        out.passed, out.by = true, anyPass
    end
    local name = testName or "THE TEST"
    for _, e in ipairs(out.players) do
        if out.passed and e.verdict ~= "passed" then
            e.note = string.format("P%d PASSED: %s COUNTS", out.by, name)
        elseif out.passed then
            e.note = (out.by == e.pnum) and string.format("%s COUNTS AS PASSED", name)
                or string.format("P%d PASSED TOO: %s COUNTS", out.by, name)
        elseif rule == "p1" and not e.isP1 and e.verdict == "passed" then
            e.note = string.format("P1 FAILED: %s IS FAILED (P1 RULE)", name)
        elseif out.gap and e.verdict == "passed" then
            -- #87 (Jules's design: each player's field test is his own game): his pass earns HIS rewards
            e.note = "PASSED: YOUR OWN REWARDS"
        else
            e.note = string.format("%s IS FAILED", name)
        end
    end
    -- #87 (live 2026-10-18 08:58, ramjet test: P2 PASSED, P1 FAILED): the band said "FAILED - NOBODY MADE THE TARGET".
    -- A pass the run did not book (out.gap) is still HIS pass: the band names every player's own result.
    local each = {}
    for _, e in ipairs(out.players) do each[#each + 1] = string.format("P%d %s", e.pnum, e.word) end
    if out.passed then
        -- couch-fix34 (Jules's Q5): one pass = the team passes ("P2 PASSED - THE FIELD TEST COUNTS FOR THE TEAM")
        out.banner = string.format("P%d PASSED - %s COUNTS FOR THE TEAM", out.by, name)
    elseif out.gap then
        out.banner = string.format("%s: %s - EACH PLAYER'S OWN RESULT", name, table.concat(each, ", "))
    else
        out.banner = string.format("%s FAILED - NOBODY MADE THE TARGET", name)
    end
    return out
end

---------------------------------------------------------------------------------------------------- game reads
local function field(o, k)
    if o == nil then return nil end
    local ok, v = pcall(U.getField, o, k)
    if ok then return v end
    return nil
end

local function raceVM()
    local vm = nil
    pcall(function()
        local vms = U.giSubsystem("ViewModelSubsystem")
        if U.ok(vms) then vm = vms:GetRaceEventVM() end
    end)
    return U.ok(vm) and vm or nil
end
M._raceVM = raceVM

local function couchOn()
    local on = false
    pcall(function() on = U.mod("couch").active() == true end)
    return on
end

local function couchTimeTrial()
    local tt = false
    pcall(function() tt = U.mod("couch").isTimeTrial() == true end)
    return tt
end

-- this race world's event: {kind, modeType, rules, targets, limit}; cached per world (the mode does not change in a
-- race), re-read until the mode is known
local info = { gen = nil }
function M.info()
    if info.gen == St.worldGen and info.kind ~= nil then return info end
    local i = { gen = St.worldGen }
    local vm = raceVM()
    if vm then i.modeType = tonumber(field(vm, "ModeType")) end
    local rules = nil
    pcall(function() local gm = U.gm(); if U.ok(gm) then rules = gm.ModeRules end end)
    if U.ok(rules) then
        i.rules = U.className(rules)
        pcall(function()
            local tt = rules.Settings.TargetTimes
            i.targets = { gold = tonumber(tt.TimeForGold), silver = tonumber(tt.TimeForSilver),
                          bronze = tonumber(tt.TimeForBronze) }
        end)
    end
    i.kind = M.modeKind(i.modeType, i.rules)
    i.limit = M.passLine(i.targets)                 -- #89: the target = the game's pass line (gold)
    if not i.limit and vm then
        local ct = tonumber(field(vm, "CurrentTargetTime"))
        if ct and ct > 0 then i.limit, i.targets = ct, { gold = ct } end
    end
    if not i.kind and couchTimeTrial() then i.kind = "timetrial" end   -- the couch time-trial node (GMV_Shakedown)
    info = i
    if i.kind and not M._logged then
        M._logged = St.worldGen
        U.log(TAG, "race-alone event: %s (mode type %s, rules %s), target %s", tostring(i.kind), tostring(i.modeType),
            tostring(i.rules), i.limit and string.format("%.2f s", i.limit) or "none")
    end
    return info
end

-- a couch race with 2+ local humans in one of the single-player test modes (or the couch time-trial node)
function M.raceAlone()
    if #U.localPlayers() < 2 or not couchOn() then return false end
    return M.info().kind ~= nil
end

-- the test's pass line (its target time; nil = none / not a time-limited kind): the verdicts
function M.target()
    local i = M.info()
    if not (i.kind and M.LIMITED[i.kind]) then return nil end
    return i.limit
end

-- the time limit of a test of this kind with this target (pure): takedowns = the target (the game's own end: the
-- rules finish the tracked player at TimeForGold); a time trial = target x cap (#89: the game never ends one at its
-- target - the cap is only a safety end; cap 0 = none)
function M.limitFor(kind, target, cap)
    local t = tonumber(target)
    if not (t and t > 0 and M.LIMITED[kind]) then return nil end
    if kind == "timetrial" then
        local c = tonumber(cap) or 0
        if c <= 0 then return nil end
        return t * math.max(1, c)
    end
    return t
end

-- the test's own time limit (nil = none: the others race to their own finish)
function M.limit()
    if opt("CouchSoloTimeLimit", true) ~= true then return nil end
    local i = M.info()
    return M.limitFor(i.kind, M.target(), opt("CouchSoloTimeTrialCap", 2.0))
end

-- wreck.lua's guard asks, when the game armed its timeout while humans still race (gs, server now, the latest real
-- finisher's EventFinishTime or nil) -> plan (M.timeoutPlan) + the start's source, or nil (not a race-alone event)
function M.timeoutDecision(gs, now, finT)
    if not M.raceAlone() then return nil end
    local limit = M.limit()
    local rst = field(gs, "RaceStartTime")
    local go = (M.go and M.go.gen == St.worldGen) and M.go.t or nil
    local start, how = M.startOf(rst, now, finT, go)
    local plan = M.timeoutPlan({ now = now, start = start, limit = limit,
                                 grace = tonumber(opt("CouchSoloLimitGraceSec", 0)) or 0 })
    plan.start, plan.how, plan.limit, plan.kind = start, how, limit, M.info().kind
    plan.raw = string.format("now %s, RaceStartTime %s, GO %s, finisher's EventFinishTime %s", tostring(now),
        tostring(rst), tostring(go), tostring(finT))
    return plan
end

---------------------------------------------------------------------------------------------------- result screens
-- POSTRACE after a race-alone couch event (couchrules.last.alone): the owner-read values of the native result screens
-- -> P1's own, and the players' results band. MAIN tick.
local res = { gen = nil, out = nil, host = nil, findAt = -1e12, info = {}, logged = {}, since = nil, limit = nil }

local function closeBand(why)
    local h = res.host
    res.host = nil
    if h and U.alive(h) then pcall(function() h:RemoveFromParent() end) end
    if why and res.bandUp then U.log(TAG, "results band closed (%s)", tostring(why)) end
    res.bandUp = false
end

local function lastRace()
    local last = nil
    pcall(function() last = U.mod("couchrules").last end)
    if type(last) ~= "table" or last.alone ~= true or last.gen ~= St.worldGen then return nil end
    if type(last.humans) ~= "table" or #last.humans < 1 then return nil end
    -- #89 (live 09:06, podracer test, P2 sat out): ONE racer, but the post-race screens are still the LAST local PC's
    -- (the guest who did not race: his REC never finished -> "PASSED" outro, "--:--.--" time). Patched whenever a
    -- couch guest owns them; the band needs 2+ racers
    if #last.humans < 2 then
        local n = 0
        pcall(function() n = #U.localPlayers() end)
        if n < 2 then return nil end
    end
    return last
end

local function p1Entry(out)
    for _, e in ipairs(out.players) do if e.isP1 then return e end end
end

local function setText(t, s)
    if not U.ok(t) then return false end
    return pcall(function() t:SetText(U.ftext(s)) end)
end

-- WBP_PostRace_Info: Txt_Title = P1's verdict (the VM's outro text of HIS result), Txt_Secondary = the team line
local function patchInfo(w, out, vm)
    local p1 = p1Entry(out)
    if not p1 then return end
    local okT = false
    if p1.verdict == "passed" or p1.verdict == "failed" then
        local ft = vm and field(vm, p1.verdict == "passed" and "RaceOutroTextSuccess" or "RaceOutroTextFailure") or nil
        if ft ~= nil then okT = pcall(function() w.Txt_Title:SetText(ft) end) end
    end
    if not okT then okT = setText(field(w, "Txt_Title"), p1.word) end
    local sec = field(w, "Txt_Secondary")
    local okS = true
    if #out.players >= 2 then
        okS = setText(sec, p1.note or "")
        if U.ok(sec) then pcall(function() sec:SetVisibility(4) end) end   -- SelfHitTestInvisible (InitForWrecked hides it)
    end
    local k = U.key(w)
    if not res.logged[k] then
        res.logged[k] = true
        U.log(TAG, "outro screen (owner = the screen's guest) shows P1's own result: %s %s, \"%s\" (title %s, line %s)",
            p1.word, M.fmtTime(p1.time), tostring(p1.note), okT and "ok" or "FAILED", okS and "ok" or "FAILED")
    end
end

-- WBP_Shakedown_Results_Presentation: Txt_TimeResult = P1's time (time-based modes; Takedowns / Ramjet show the VM's
-- = P1's value already), Txt_BeatBestTime (the owner's time vs the leaderboard) collapsed, the verdict checked
local function patchShk(w, out, vm, kind)
    local p1 = p1Entry(out)
    if not p1 then return end
    local okT = true
    if kind ~= "takedowns" and kind ~= "ramjet" then okT = setText(field(w, "Txt_TimeResult"), M.fmtTime(p1.time)) end
    pcall(function() w.Txt_BeatBestTime:SetVisibility(1) end)
    local vmOk = vm and field(vm, "bIsSuccess")
    local mine = p1.verdict == "passed"
    if type(vmOk) == "boolean" and vmOk ~= mine then
        -- the VM's verdict and P1's own disagree (his fail bits cleared while a guest carried the team result): the
        -- verdict line follows HIS result
        setText(field(w, "Txt_MedalResult"), p1.word)
        pcall(function() w.Txt_MedalResult:SetVisibility(4) end)
    end
    local k = U.key(w)
    if not res.logged[k] then
        res.logged[k] = true
        U.log(TAG, "time screen shows P1's own result: %s %s (screen owner's time replaced %s; VM verdict %s%s)",
            p1.word, M.fmtTime(p1.time), okT and "ok" or "FAILED", tostring(vmOk),
            (type(vmOk) == "boolean" and vmOk ~= mine) and ", his own verdict written" or "")
    end
end

-- the band: one card per player along the bottom (4K canvas), above the screens' action bar (live check: Jules's
-- round-4 photo). #52 (overnight 2026-10-18, t3-fieldtests/27): fixed 1100 px cards with a 54 px one-line headline
-- overflowed - "P1  FAILED  3/6  04:10.72" measured ~1130 px and ran into P2's card, P1's note ran under P2's (read
-- as "THE FIELD TEST COUNTS THE FIELD TEST COUNTS AS PASSED"); 4 cards (4 x 1100 + gaps) did not even fit the 3840
-- canvas. M.bandLayout sizes every card to the player count and every line to its card (an upper-case glyph of the
-- display font measured live at ~0.85 x the font size; GLYPH = 1.0 keeps a margin): the headline splits into verdict
-- + score / time when one line would shrink below HEAD_MIN, the note shrinks and wraps (WrapTextAt) inside the card.
local BAND = { VW = 3840, MARGIN = 120, GAP = 40, MAXW = 1500, BOTTOM = 1830, PADX = 44, PADR = 30, GLYPH = 1.0,
               HEAD = 54, HEAD_MIN = 44, SUB = 44, NOTE = 34, NOTE_MIN = 26, LINE = 1.25, PADY = 22 }
M.BAND = BAND

local function fitSize(text, width, base, min)
    local n = #(text or "")
    if n == 0 then return base end
    return math.max(min, math.min(base, math.floor(width / (n * BAND.GLYPH))))
end

-- -> { cards = { {x, y, w, h, pnum, lines = { {text, size, y, wrap, role} }} }, bannerY }
function M.bandLayout(players, vw)
    vw = vw or BAND.VW
    local n = math.max(1, #players)
    local w = math.min(BAND.MAXW, math.floor((vw - 2 * BAND.MARGIN - (n - 1) * BAND.GAP) / n))
    local x0 = math.floor((vw - (n * w + (n - 1) * BAND.GAP)) / 2)
    local inner = w - BAND.PADX - BAND.PADR
    local cards, hMax = {}, 0
    for i, e in ipairs(players) do
        local tail = e.score and string.format("%s  %s", e.score, M.fmtTime(e.time)) or M.fmtTime(e.time)
        if e.medal then tail = tail .. "  " .. e.medal end
        local one = string.format("P%d  %s  %s", e.pnum or 0, e.word or "?", tail)
        local lines, y = {}, BAND.PADY
        if fitSize(one, inner, BAND.HEAD, 1) >= BAND.HEAD_MIN then
            local sz = fitSize(one, inner, BAND.HEAD, BAND.HEAD_MIN)
            lines[#lines + 1] = { text = one, size = sz, y = y, role = "head" }
            y = y + math.floor(sz * BAND.LINE)
        else
            local head = string.format("P%d  %s", e.pnum or 0, e.word or "?")
            local hs = fitSize(head, inner, BAND.HEAD, 30)
            lines[#lines + 1] = { text = head, size = hs, y = y, role = "head" }
            y = y + math.floor(hs * BAND.LINE)
            local ss = fitSize(tail, inner, BAND.SUB, 28)
            lines[#lines + 1] = { text = tail, size = ss, y = y, role = "sub" }
            y = y + math.floor(ss * BAND.LINE)
        end
        local note = e.note or ""
        if note ~= "" then
            -- one line when it fits at NOTE_MIN or more, else NOTE_MIN wrapped to the card (2 lines at most here)
            local ns = fitSize(note, inner, BAND.NOTE, BAND.NOTE_MIN)
            local rows = math.max(1, math.ceil(#note * ns * BAND.GLYPH / inner))
            y = y + 6
            lines[#lines + 1] = { text = note, size = ns, y = y, wrap = inner, role = "note", rows = rows }
            y = y + math.floor(ns * BAND.LINE) * rows
        end
        local h = y + BAND.PADY
        if h > hMax then hMax = h end
        cards[i] = { x = x0 + (i - 1) * (w + BAND.GAP), w = w, pnum = e.pnum, lines = lines, e = e }
    end
    local y0 = BAND.BOTTOM - hMax
    for _, c in ipairs(cards) do c.y, c.h = y0, hMax end
    return { cards = cards, bannerY = y0 - 70, inner = inner }
end

local function buildBand(out)
    local CP = U.mod("couchpanel")
    local kit = CP.kit
    local H = CP.newHost()
    pcall(function() H.host:SetVisibility(kit.VIS.HitTestInvisible) end)
    local C = require("consts")
    local L = M.bandLayout(out.players, kit.VW)
    for _, c in ipairs(L.cards) do
        local e = c.e
        local col = C.COLOURS[e.pnum] or kit.colours.AMBER
        kit.place(H.cv, kit.solid(H.tree, kit.colours.DEEP), c.x, c.y, c.w, c.h, 1)
        kit.place(H.cv, kit.solid(H.tree, col), c.x, c.y, 14, c.h, 2)
        for _, ln in ipairs(c.lines) do
            local ink = ln.role == "note" and kit.colours.PAPER
                or (e.verdict == "passed" and kit.colours.SAGE or kit.colours.AMBER)
            local t = kit.text(H.tree, ln.size, ink, nil, ln.wrap)
            kit.setText(t, ln.text)
            kit.place(H.cv, t, c.x + BAND.PADX, c.y + ln.y, nil, nil, 3)
        end
    end
    local b = kit.text(H.tree, 40, out.passed and kit.colours.SAGE or kit.colours.AMBER)
    kit.setText(b, out.banner)
    local s = kit.place(H.cv, b, math.floor(kit.VW / 2), L.bannerY, nil, nil, 3)
    pcall(function() s:SetAlignment({ X = 0.5, Y = 0 }) end)
    H.host:AddToViewport((tonumber(opt("CouchPanelZ", 1000)) or 1000) - 6)
    pcall(function() U.mod("couchroot").exclude(H.host) end)
    return H.host
end

local INFO_CLS = "WBP_PostRace_Info_C"
local SHK_HOLDER = "WBP_PostRace_Results_Shakedown_Presentation_C"

function M.mainTick()
    if St.phase ~= "POSTRACE" or opt("CouchSoloResults", true) ~= true then
        if res.host then closeBand("phase " .. tostring(St.phase)) end
        return
    end
    local last = lastRace()
    if not last then
        if res.host then closeBand("no race-alone result") end
        return
    end
    if res.gen ~= St.worldGen then
        closeBand()
        res = { gen = St.worldGen, findAt = -1e12, info = {}, logged = {}, since = St.nowMs(), bandUp = false }
        local kind = last.aloneKind or "timetrial"
        -- #89: the verdict's line is the test's TARGET (the game's gold), never its time limit
        local lim = (M.LIMITED[kind] and (last.target or last.limit)) or nil
        local tg = nil
        pcall(function() tg = M.info().targets end)
        local name = (last.kind == "fieldtest" and "THE FIELD TEST") or (last.kind == "planesprint" and "THE PODRACER TEST")
            or ("THE " .. (M.NAME[kind] or "TEST"))
        res.out = M.results(last.humans, last.rule, lim, name, last.carrier, tg)
        if res.out.gap then
            U.warn(TAG, "P%d passed but the run booked P%s's failed result (the first human home): reported as is",
                res.out.gap, tostring(last.carrier))
        end
        local parts = {}
        for _, e in ipairs(res.out.players) do
            parts[#parts + 1] = string.format("P%d %s %s%s%s (%s)", e.pnum, e.word, e.score and (e.score .. " ") or "",
                M.fmtTime(e.time), e.medal and (" " .. e.medal) or "", tostring(e.why))
        end
        U.log(TAG, "results (%s / %s, %s rule, target %s): %s; team %s", tostring(last.kind), kind, tostring(last.rule),
            lim and string.format("%.2f", lim) or "-", table.concat(parts, ", "),
            res.out.passed and ("PASSED by P" .. tostring(res.out.by))
            or (res.out.gap and ("FAILED (booked); band: " .. tostring(res.out.banner)) or "FAILED"))
    end
    local now = St.nowMs()
    if now - (res.since or now) > 180000 then
        if res.host then closeBand("3 min") end
        return
    end
    local vm = raceVM()
    -- WBP_PostRace_Info (a plain user widget of the outro, not an activatable): FindAllOf once a second
    if now - res.findAt >= 1000 then
        res.findAt = now
        res.info = {}
        local ok, list = pcall(FindAllOf, INFO_CLS)
        if ok and type(list) == "table" then
            for _, w in ipairs(list) do if U.alive(w) then res.info[#res.info + 1] = w end end
        end
    end
    local shown = false
    for _, w in ipairs(res.info) do
        if U.alive(w) then
            local vis = false
            pcall(function() vis = w:IsVisible() == true end)
            if vis then shown = true; U.try(TAG, patchInfo, w, res.out, vm) end
        end
    end
    local screens = {}
    pcall(function() screens = U.mod("couch").activeScreens() end)
    for _, e in ipairs(screens) do
        if e.cls == SHK_HOLDER and U.alive(e.w) then
            local inner = field(e.w, "WBP_Shakedown_Results_Presentation")
            if U.ok(inner) then shown = true; U.try(TAG, patchShk, inner, res.out, vm, last.aloneKind) end
        end
    end
    local hide = false
    pcall(function() hide = U.mod("couch").menuOver() == true end)
    if shown and not hide and #res.out.players >= 2 then
        if not res.host or not U.alive(res.host) then
            local ok, h = pcall(buildBand, res.out)
            if ok and h then
                res.host, res.bandUp = h, true
                U.log(TAG, "results band up: %s", res.out.banner)
            else
                U.logEvery("couchsolo.band", 10000, TAG, "results band not built: %s", tostring(h))
            end
        end
    elseif res.host then
        closeBand(hide and "a menu over it" or "result screens gone")
    end
end

function M.init()
    St.on("leaving", TAG, function() closeBand("leaving") end)
    St.on("world", TAG, function() res.host = nil; res.bandUp = false; res.info = {}; info = { gen = nil } end)
    St.on("phase", TAG, function(new, old)
        if new == "PRERACE" or new == "LOADING" then info = { gen = nil }; M._logged = nil; M.go = nil end
        -- #36: the race's GO on the server clock (the clock RaceTimeoutTime is in), sampled once per race world, only on
        -- the real PRERACE -> RACING edge (a mid-race reload would sample a late GO: the fallbacks below take it)
        if new == "RACING" and old == "PRERACE" and not (M.go and M.go.gen == St.worldGen) then
            local t = nil
            pcall(function() local gs = U.gs(); if U.ok(gs) then t = U.callMethod(gs, "GetServerWorldTimeSeconds") end end)
            if type(t) == "number" then
                M.go = { gen = St.worldGen, t = t }
                U.log(TAG, "race GO on the server clock: T=%.2f", t)
            end
        end
    end)
end

function M.status()
    local i = info
    return string.format("couchsolo: kind %s limit %s band %s", tostring(i.kind), tostring(i.limit), tostring(res.bandUp))
end

return M
