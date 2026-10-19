-- couchfaults.lua (couch-rewards2 STEP 3, 2026-10-17; couch-fix27 #109, 2026-10-18): A GUEST'S OWN FAULTS (critical
-- malfunction -> a faulted part of HIS build, never one of P1's).
--
-- NATIVE (decoded from the shipping exe, couch-fix27; CriticalMalfunctionConfig offsets from the jmap/ObjectDump):
--   * The component is UCriticalMalfunctionComponent on every AVehiclePawn (VehiclePawn.CriticalMalfunctionComponent;
--     its owner is the CAR, not a PlayerController - the 07b analysis said PC: the pre-fix guestOf compared the owner
--     with the guest's PC, never matched, and every guest malfunction stayed on P1's run: #109, zero couchfaults lines
--     in the whole 2026-10-18 session).
--   * Scheduler T (0x143096112, called with the component): standalone net mode only; if comp+0x140 (the fault this
--     malfunction already queued) is null -> F(CampaignSubsystem.ActiveRun) -> comp+0x140 = the affix F picked.
--     F (0x1430da0c4): gate 0x1471ed1c0(run) (the run's event state, no random roll), candidates = affixes of
--     run.playerRacer's build (P1's: status Active 1 / Fixed 3, not already in the queue), a random one (FMath::Rand)
--     and a random fault of the Faulty group -> run.mAffixesToTurnFaultyThroughoutRace += {AffixToAddFaultTo,
--     FaultToAdd}. The ROLL picks the part; WHETHER a fault comes is decided by the outcome rule below, per car.
--   * Who calls T (each car's own component; the car's config = HC_CriticalMalfunction / HC_P_ for pods, no tune set
--     changes the ApplyFauly* flags):
--       - OnCrashTagChanged_OnClient (native UFunction, the crash path): a crash while Testing (state 4) ->
--         ApplyFaulyOnCrashOut (true); in Malfunction / WaitForPress / WaitForRelease (1-3) -> ApplyFaulyOnPreTestCrash
--         (true) once MinimumTimeForCrashingFault (0) has passed;
--       - the check's outcome, in the component's TICK (no UFunction): Passed (the SUCCESS window) ->
--         ApplyFaulyOnSuccess (true); PerfectPass -> ApplyFaulyOnPerfect (false); Failed early / late ->
--         ApplyFaulyOnEarlyFail / OnLateFail (false); TimedOut -> ApplyFaulyOnTimeout (true).
--     So: one fault per QUALIFYING malfunction (several per race; the malfunction end 0x140fd95e2 broadcasts
--     OnAffixMadeFaulty(affix) and clears comp+0x140), for ANY car's component - always on P1's parts.
--   * OnAffixMadeFaulty is bound by BP_VehicleUIComponent_C (a BP event called by a delegate broadcast: UE4SS's script
--     hook does not see those in this build, couchrun SAVE OBJECT HOOKS) - not usable.
-- HERE, per race (cfg.CouchGuestFaults "native"; "off" = the game's own behaviour):
--   * the crash path: pre/post hook on OnCrashTagChanged_OnClient - queue growth inside a guest car's call is his;
--   * the outcome path: a poll (cfg.CouchFaultsPollMs) of the queue count + every local car's component state
--     (GetState / GetResolutionState): growth while exactly one local car was in a malfunction (state 1-5 at this poll
--     or the previous one; several -> the ones that just resolved Passed / TimedOut) is that car's;
--   * a guest's entries come OFF P1's run (P1 never keeps a guest's fault) and HE gets one fault per such malfunction
--     on his own build (couchrewards.pickFault: a part not faulty, not already queued; a fault of the Faulty group),
--     queued on his run (couchrun.queueFault) for his FAULTS stage. P1's own growth stays native. Growth no local car
--     explains (a bot's component, or two cars at once) stays on P1's run and is logged.
-- couch-fix59 (AUTO-143, live round 4 18:42:15 / 18:55:32: P2 crashed 0.5-1.2 s into his critical malfunction, 2/2
-- without a fault and without a single couchfaults line):
--   * the crash handler is called NATIVELY (no UTF-16 "OnCrashTagChanged_OnClient" in the exe: no AddDynamic, a C++
--     binding; the same as OnAffixMadeFaulty): the UE4SS hook above only sees the test tool's own Lua call (botcrit
--     crash / crashpre), never a real crash - zero "(crash)" lines in every live log;
--   * the malfunction lasted 0.4 s before the crash: the 1 s state poll never saw it, so even a queue growth had no
--     owner; and the native roll (F) only grows the queue when P1's build has a part to fault.
--   Decoded handler (exec 0x140fd93ac, static): the owner car's checks, the crash tag, then with the critical tag on
--   the car: state 4 -> ApplyFaulyOnCrashOut, 1-3 -> ApplyFaulyOnPreTestCrash once MinimumTimeForCrashingFault has
--   passed -> T; then 0x140fd97e8 ends the malfunction AT ONCE: state 0, resolution 4 (Invalid), no Resolving (5).
--   So each GUEST car's state is sampled every cfg.CouchFaultsGuestMs (an EPISODE per malfunction): a malfunction that
--   goes from 1-4 straight to Idle with resolution Invalid was ended by a crash; one through Resolving ended by the
--   check. At the episode's end, a qualifying end (the car's own ApplyFauly* flags) that no queue growth was
--   attributed to (P1's build had no part to roll, or the growth went unseen) gives him his own fault; growth
--   attributed to him during the episode, ambiguous growth, or a test-tool resolve (M.forcedEnd) give nothing more.
local U = require("util")
local St = require("state")
local cfg = require("config")

local M = {}
local TAG = "couchfaults"
local FN = "/Script/Griffin.CriticalMalfunctionComponent:OnCrashTagChanged_OnClient"
M.FN = FN

-- ECriticalMalfunctionState: 0 Idle, 1 Malfunction, 2 WaitForPress, 3 WaitForRelease, 4 Testing, 5 Resolving
-- ECriticalMalfunctionResolutionState: 0 Failed, 1 Passed, 2 PerfectPass, 3 TimedOut, 4 Invalid
local FAULTING_RES = { [1] = true, [3] = true }       -- ApplyFaulyOnSuccess / OnTimeout (HC_CriticalMalfunction)

local S = { pre = nil, n = nil, malfMs = {}, stMs = nil, comp = {}, pollMs = nil, run = nil, arr = nil, noRun = nil,
            p1Key = nil, attributed = 0, removed = 0, kept = 0, unexplained = 0, guestFaults = 0,
            ep = {}, faultedAt = {}, ambigAt = {}, forcedAt = {}, guestMs = nil, ownEnds = 0 }
local EMPTY = {}
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function CR() return U.mod("couchrun") end
local function RW() local ok, m = pcall(require, "couchrewards"); return ok and m or nil end
local PD = nil
pcall(function() PD = require("perkdata") end)

local function run()
    local r = nil
    pcall(function() r = U.mod("couchrules")._campaignRun() end)
    return U.ok(r) and r or nil
end
local function queueCount(r)
    local n = nil
    pcall(function() n = U.arrayCount(r.mAffixesToTurnFaultyThroughoutRace) end)
    return n
end

-- the queue as Lua: { {a = affix, f = fault, k = key of the affix} }
local function entriesOf(r)
    local out = {}
    local arr = nil
    pcall(function() arr = r.mAffixesToTurnFaultyThroughoutRace end)
    local n = U.arrayCount(arr)
    for i = 1, n do
        local a, f = nil, nil
        pcall(function()
            local e = U.unwrap(arr[i])
            a, f = e.AffixToAddFaultTo, e.FaultToAdd
        end)
        out[i] = { a = a, f = f, k = U.ok(a) and U.key(a) or nil }
    end
    return out, arr
end

local function joined()
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    return (ok and type(list) == "table") and list or {}
end

-- the local players with their cars: { {pnum, guest (joinedList entry or nil for P1), car} }
local function players(js)
    local out = {}
    local p1 = U.p1()
    local car1 = U.carOf(p1)
    if car1 then out[1] = { pnum = 1, car = car1 } end
    for _, e in ipairs(js or joined()) do
        local car = U.carOf(e.pc)
        if car then out[#out + 1] = { pnum = e.pnum, guest = e, car = car } end
    end
    return out
end

-- who owns this car (P1 -> "p1", a joined guest -> his entry, else nil)
local function ownerOfCar(car)
    if not U.ok(car) then return nil end
    local k = U.key(car)
    for _, pl in ipairs(players()) do
        if U.key(pl.car) == k then return pl.guest or "p1" end
    end
    return nil
end

-- the player whose car owns this component (the component is on the car; a PC owner is accepted as well)
local function ownerOfComp(comp)
    local owner = nil
    pcall(function() owner = comp:GetOwner() end)
    if not U.ok(owner) then return nil end
    if U.isVehicle(owner) then return ownerOfCar(owner) end
    local k = U.key(owner)
    local p1 = U.p1()
    if U.ok(p1) and U.key(p1) == k then return "p1" end
    for _, e in ipairs(joined()) do if U.ok(e.pc) and U.key(e.pc) == k then return e end end
    return nil
end
M._ownerOfComp = ownerOfComp

-- the fault list (the Faulty group: AFX_Faulty_*, never a plane-only one)
local FLAWS = nil
local function flaws()
    if FLAWS then return FLAWS end
    FLAWS = {}
    for id, d in pairs(PD and PD.PARTS or {}) do
        if d.cat == "flaws" and not d.planeOnly and id:find("^AFX_Faulty_") then FLAWS[#FLAWS + 1] = id end
    end
    table.sort(FLAWS)
    return FLAWS
end
M._flaws = flaws

-- his build for the scheduler: { {id, faulty, queued} } (faulty = an inherently faulty part not repaired, or already
-- faulted by a malfunction)
function M.buildOf(p)
    local out = {}
    local fixed = type(p.fixed) == "table" and p.fixed or {}
    local faults = type(p.faults) == "table" and p.faults or {}
    local queued = {}
    for _, q in ipairs(type(p.faultQueue) == "table" and p.faultQueue or {}) do queued[q.part] = true end
    for _, id in ipairs(p.lo and p.lo.parts or {}) do
        if id then
            local d = PD and PD.PARTS and PD.PARTS[id]
            local inherent = d and d.faulty == true and not fixed[id]
            out[#out + 1] = { id = id, faulty = inherent or faults[id] ~= nil, queued = queued[id] == true }
        end
    end
    return out
end

-- Take the entries at the indices `drop` off P1's queue. Nothing kept -> Empty() (live-proven on other arrays). Else a
-- rebuild from Lua tables: one probe append first (a struct element written one past the end), so a refused write
-- leaves the queue as it was; then Empty() and the kept entries written back in order. -> ok, how
local function removeEntries(r, drop)
    local list, arr = entriesOf(r)
    local keep = {}
    for i, e in ipairs(list) do if not drop[i] then keep[#keep + 1] = e end end
    local n0 = #list
    if #keep == n0 then return true, "nothing to remove" end
    if not arr then return false, "queue unreadable" end
    if #keep > 0 then
        local okP = pcall(function() arr[n0 + 1] = { AffixToAddFaultTo = keep[1].a, FaultToAdd = keep[1].f } end)
        local n1 = U.arrayCount(arr)
        if not okP or n1 ~= n0 + 1 then
            if n1 > n0 then
                -- a zeroed element half written: never leave a null affix for the FAULTS screen
                pcall(function() arr:Empty() end)
                return false, string.format("struct append refused after growing the queue: EMPTIED (P1's %d own "
                    .. "fault(s) of this race lost)", #keep)
            end
            return false, "struct append refused (queue unchanged)"
        end
    end
    local okE = pcall(function() arr:Empty() end)
    if not okE then return false, "Empty() failed" end
    for i, e in ipairs(keep) do
        local okW = pcall(function() arr[i] = { AffixToAddFaultTo = e.a, FaultToAdd = e.f } end)
        if not okW then
            pcall(function() arr:Empty() end)
            return false, string.format("rebuild failed at %d of %d: EMPTIED (P1's own fault(s) of this race lost)", i,
                #keep)
        end
    end
    local after = entriesOf(r)
    local same = #after == #keep
    for i = 1, math.min(#after, #keep) do if after[i].k ~= keep[i].k then same = false end end
    if not same then return false, string.format("rebuild read back %d entr(ies), %d expected", #after, #keep) end
    return true, (#keep == 0) and "emptied" or string.format("rebuilt with P1's %d own", #keep)
end
M._removeEntries = removeEntries

-- his own fault for one malfunction of his car
local function giveOwn(g, why)
    local p = CR().player(g.ctrlId)
    local Rm = RW()
    if not (p and Rm) then return false end
    S.guestFaults = S.guestFaults + 1
    local rnd = Rm.stream(Rm.seedOf(os.time(), St.nowMs(), g.ctrlId, "fault", S.guestFaults))
    local pick = Rm.pickFault(M.buildOf(p), flaws(), rnd)
    if not pick then
        U.log(TAG, "P%d's critical malfunction (%s): no part of his can take a fault", g.pnum, why)
        return false
    end
    return CR().queueFault(g.ctrlId, pick.part, pick.fault, "his critical malfunction (" .. why .. ")")
end

-- entries first..last of the queue were queued for guest g's malfunction: off P1's run, one fault of his own each
local function attribute(r, g, first, last, why)
    local drop, cnt = {}, 0
    for i = first, last do drop[i] = true; cnt = cnt + 1 end
    if cnt == 0 then return end
    S.attributed = S.attributed + cnt
    if U.ok(g.pc) then S.faultedAt[U.key(g.pc)] = St.nowMs() end      -- AUTO-143: this episode has its fault
    local ok, how = removeEntries(r, drop)
    if ok then
        S.removed = S.removed + cnt
        U.log(TAG, "P%d's critical malfunction (%s): the %d fault(s) the game queued on P1's run taken off again (%s)",
            g.pnum, why, cnt, how)
    else
        S.kept = S.kept + cnt
        U.warn(TAG, "P%d's critical malfunction (%s): the %d fault(s) the game queued on P1's run NOT removed: %s",
            g.pnum, why, cnt, how)
    end
    for _ = 1, cnt do giveOwn(g, why) end
end

---------------------------------------------------------------------------------------------------- the crash path
function M.pre(compParam)
    if St.phase ~= "RACING" or opt("CouchGuestFaults", "native") == "off" then return end
    local comp = U.unwrap(compParam)
    if not U.ok(comp) then return end
    local r = run()
    if not r then return end
    S.pre = { k = U.key(comp), n = queueCount(r) }
end

function M.post(compParam)
    local pre = S.pre
    S.pre = nil
    if not pre or St.phase ~= "RACING" then return end
    local comp = U.unwrap(compParam)
    if not (U.ok(comp) and U.key(comp) == pre.k) then return end
    local r = run()
    local n = r and queueCount(r)
    if not (n and pre.n and n > pre.n) then return end
    local who = ownerOfComp(comp)
    if who and who ~= "p1" then
        attribute(r, who, pre.n + 1, n, "crash")
    elseif who == nil then
        S.unexplained = S.unexplained + (n - pre.n)
        U.log(TAG, "a critical-malfunction crash of a car that is no local player's queued %d fault(s) on P1's run "
            .. "(native, kept)", n - pre.n)
    end
    S.n = queueCount(r)                                       -- the poll does not count this growth again
end

---------------------------------------------------------------------------------------------------- the outcome path
-- couch-racegc: the poll runs in every couch race, so its steady path allocates almost nothing: the run object and
-- its TArray wrapper kept for the race (U.ok-checked), each car's component wrapper kept per PC (U.pcallFn's cached
-- GetState), no closures; tables and the resolution states only when the queue grew.
local GET_STATE = "/Script/Griffin.CriticalMalfunctionComponent:GetState"
-- this player's car's component, kept per PC for the race (wrapper reuse: U.pcallFn's cached UFunction works on it)
local function compOf(pcKey, car)
    local ck = U.key(car)
    local e = S.comp[pcKey]
    if e and e.car == ck and U.ok(e.c) then return e.c end
    local okC, c = U.pcallGet(car, "CriticalMalfunctionComponent")
    if not (okC and U.ok(c)) then S.comp[pcKey] = nil; return nil end
    S.comp[pcKey] = { car = ck, c = c }
    return c
end
local function stateOf(pcKey, car)
    if not U.ok(car) then return nil, nil end
    local c = compOf(pcKey, car)
    if not U.ok(c) then return nil, nil end
    local okS, st = U.pcallFn(c, GET_STATE, "GetState")
    return okS and tonumber(st) or nil, c
end
local function resOf(c)
    if not U.ok(c) then return nil end
    local ok, res = U.pcallM(c, "GetResolutionState")
    return ok and tonumber(res) or nil
end
local function inMalf(st) return st ~= nil and st >= 1 and st <= 5 end

-- the player (P1 -> "p1", a guest -> his joinedList entry) of this PlayerController key (the pad ids may be swapped
-- by the couch's shared-screen routing: the PC is the player)
local function whoOf(pcKey, p1Key)
    if pcKey == p1Key then return "p1" end
    for _, e in ipairs(joined()) do if U.ok(e.pc) and U.key(e.pc) == pcKey then return e end end
    return nil
end

local RECENT_MS = 2000      -- a car seen in a critical malfunction this recently still owns new growth (an episode is
                           -- >= 2.6 s in states 1-4: TimeBeforeCheck 0.8 + TimeForCheck 1.8; the state poll is 1 s)

-- the queue's count (the run and its TArray wrapper kept for the race; nil = no campaign run)
local function count(final)
    if S.noRun then return nil end                             -- no campaign run in this race (FREE MODE, GP)
    local r = S.run
    if not U.ok(r) then r = run(); S.run, S.arr = r, nil end
    if not U.ok(r) then S.noRun = not final; return nil end
    local arr = S.arr                                          -- the TArray wrapper of the live run (U.ok(r) above)
    if arr == nil then
        local okA, a = U.pcallGet(r, "mAffixesToTurnFaultyThroughoutRace")
        if not okA then return nil end
        arr = a
        S.arr = a
    end
    return U.arrayCount(arr), r
end

-- every local car's critical-malfunction state (S.malfMs[PC key] = last time seen in one); on growth, who owns it
function M.poll(final)
    if opt("CouchGuestFaults", "native") == "off" then return end
    local n, r = count(final)
    if not n then return end
    local base = S.n
    local grew = base ~= nil and n > base
    local now = St.nowMs()
    local lps = final and EMPTY or U.localPlayers()
    if not final and #lps < 2 then S.n = n; return end        -- solo: the game's own faults
    local p1Key = (lps[1] and U.ok(lps[1].pc)) and U.key(lps[1].pc) or S.p1Key
    S.p1Key = p1Key
    local malfMs = S.malfMs
    local cands = grew and {} or nil
    for i = 1, #lps do
        local e = lps[i]
        if U.ok(e.pc) then
            local id = U.key(e.pc)
            local st, c = stateOf(id, U.carOf(e.pc))
            if inMalf(st) then malfMs[id] = now end
            if grew and (inMalf(st) or now - (malfMs[id] or -1e12) <= RECENT_MS) then
                cands[#cands + 1] = { id = id, st = st, c = c }
            end
        end
    end
    S.stMs = now
    if final and grew then                                     -- POSTRACE: the cars may be gone; the last polls' view
        for id, t in pairs(malfMs) do
            if now - t <= RECENT_MS then cands[#cands + 1] = { id = id } end
        end
    end
    if grew then
        -- the outcome path leaves the owner Resolving (5), or already Idle after a 0 s resolution (a time-out); a car
        -- still in 1-4 can only own it through the crash path (hooked above: a fallback when the hook did not run)
        local res5, idle, active = {}, {}, {}
        for _, cd in ipairs(cands) do
            if cd.st == 5 then res5[#res5 + 1] = cd
            elseif inMalf(cd.st) then active[#active + 1] = cd
            else idle[#idle + 1] = cd end
        end
        local id = nil
        if #res5 == 1 then id = res5[1].id
        elseif #res5 > 1 then                                   -- several resolving: the one that Passed / TimedOut
            local nRes = 0
            for _, cd in ipairs(res5) do
                local res = cd.c and resOf(cd.c) or nil
                if res ~= nil and FAULTING_RES[res] then nRes = nRes + 1; id = cd.id end
            end
            if nRes ~= 1 then id = nil end
        elseif #idle >= 1 then                                  -- the latest malfunction to end
            local best, tie = nil, false
            for _, cd in ipairs(idle) do
                local t = malfMs[cd.id] or -1e12
                if not best or t > best.t then best, tie = { id = cd.id, t = t }, false
                elseif t == best.t then tie = true end
            end
            id = (best and not tie) and best.id or nil
        elseif #active == 1 then id = active[1].id end
        if id == nil then                                       -- AUTO-143: no episode end adds a fault for this one
            for _, cd in ipairs(cands) do S.ambigAt[cd.id] = now end
        end
        local who = id ~= nil and whoOf(id, p1Key) or nil
        if type(who) == "table" then
            attribute(r, who, base + 1, n, final and "race end" or "check outcome")
        elseif who == nil then
            S.unexplained = S.unexplained + (n - base)
            U.log(TAG, "%d fault(s) queued on P1's run with %d local car(s) in a critical malfunction: not attributed "
                .. "(native, kept on P1's run)", n - base, #cands)
        end
        n = queueCount(r) or n
    end
    S.n = n
end

---------------------------------------------------------------------------------------------------- AUTO-143 episodes
-- ECriticalMalfunctionResolutionState 1 Passed / 2 PerfectPass / 3 TimedOut -> the car config's flag (0 Failed: early
-- or late, not told apart here: no fault)
local RES_FLAG = { [1] = "ApplyFaulyOnSuccess", [2] = "ApplyFaulyOnPerfect", [3] = "ApplyFaulyOnTimeout" }
local function critCfg(c)
    local t = nil
    pcall(function() t = c:GetBPCriticalMalfunctionConfig() end)
    return type(t) == "table" and t or nil
end
-- the end of guest g's malfunction episode ep (last = the last state 1-5 seen, res = the resolution now)
local function endEpisode(id, g, ep, c, now)
    if (S.faultedAt[id] or -1e12) >= ep.since or (S.ambigAt[id] or -1e12) >= ep.since
        or (S.forcedAt[id] or -1e12) >= ep.since then return end
    local res = resOf(c)
    local flag, why
    if ep.last == 5 or (res ~= nil and res ~= 4) then          -- the check's outcome (Resolving, or a 0 s one)
        flag = RES_FLAG[res or -1]
        why = "check outcome"
        if not flag then return end                            -- Failed: no fault
    elseif res == 4 then                                       -- 1-4 -> Idle, Invalid: the crash handler ended it
        flag = (ep.last == 4) and "ApplyFaulyOnCrashOut" or "ApplyFaulyOnPreTestCrash"
        why = (ep.last == 4) and "crash in the check" or "crash before the check"
    else
        return
    end
    local k = critCfg(c)
    local on = k and k[flag]
    local dur = (now - ep.since) / 1000
    if on == true and flag == "ApplyFaulyOnPreTestCrash" then
        local minT = tonumber(k.MinimumTimeForCrashingFault) or 0
        if dur < minT then on = false end
    end
    if on ~= true then
        U.log(TAG, "P%d's critical malfunction ended (%s, last state %s, %.1f s): no fault (%s %s)", g.pnum, why,
            tostring(ep.last), dur, flag, k and tostring(k[flag]) or "config unreadable")
        return
    end
    S.ownEnds = S.ownEnds + 1
    U.log(TAG, "P%d's critical malfunction ended (%s, last state %s, %.1f s; %s): no fault of the game's was "
        .. "attributed to it (the game's roll needs a part on P1's build; a real crash is handled natively): his own",
        g.pnum, why, tostring(ep.last), dur, flag)
    giveOwn(g, why)
end

-- every guest car's state (sampled every cfg.CouchFaultsGuestMs): the episodes
local function sampleGuests(now)
    local lps = U.localPlayersRO()
    if #lps < 2 then return end
    local p1Key = U.ok(lps[1].pc) and U.key(lps[1].pc) or S.p1Key
    for i = 2, #lps do
        local e = lps[i]
        if U.ok(e.pc) then
            local id = U.key(e.pc)
            local car = U.carOf(e.pc)
            local ck = U.ok(car) and U.key(car) or nil
            local ep = S.ep[id]
            if ep and ep.car ~= ck then S.ep[id] = nil; ep = nil end   -- a new car (respawn / wreck): forgotten
            if ck then
                local st, c = stateOf(id, car)
                if inMalf(st) then
                    S.malfMs[id] = now
                    if ep and ep.last == 5 and st ~= 5 then           -- a new malfunction right after a check
                        S.ep[id] = nil
                        local who = whoOf(id, p1Key)
                        if type(who) == "table" then endEpisode(id, who, ep, c, now) end
                        ep = nil
                    end
                    if not ep then ep = { car = ck, since = now }; S.ep[id] = ep end
                    ep.last = st
                elseif st == 0 and ep then
                    S.ep[id] = nil
                    local who = whoOf(id, p1Key)
                    if type(who) == "table" then endEpisode(id, who, ep, c, now) end
                end
            end
        end
    end
end
M._sampleGuests = sampleGuests

-- the test tool resolves a TestBots car's malfunction itself (Server_ResolveCriticalMalfunction): not a crash
function M.forcedEnd(pc)
    if U.ok(pc) then S.forcedAt[U.key(pc)] = St.nowMs() end
end

-- couch-racegc: the steady path is the count read only (no U.try, no tables); the cars' states once a second, and at
-- once when the queue grew
function M.fastTick()
    if St.phase ~= "RACING" or S.noRun or opt("CouchGuestFaults", "native") == "off" then return end
    local t = St.nowMs()
    if S.pollMs and t - S.pollMs < math.min(tonumber(opt("CouchFaultsPollMs", 250)) or 250,
        tonumber(opt("CouchFaultsGuestMs", 100)) or 100) then return end
    S.pollMs = t
    local n = count(false)
    if not n then return end
    if S.n == nil then S.n = n end
    if n > S.n or t - (S.stMs or -1e12) >= (tonumber(opt("CouchFaultsStateMs", 1000)) or 1000) then
        U.try(TAG, M.poll, false)
    elseif n < S.n then
        S.n = n                                                -- applied / emptied by the game
    end
    -- AUTO-143: the guests' episodes, after the growth above was attributed
    if t - (S.guestMs or -1e12) >= (tonumber(opt("CouchFaultsGuestMs", 100)) or 100) then
        S.guestMs = t
        U.try(TAG, sampleGuests, t)
    end
end

function M.status()
    return string.format("couchfaults: %d guest fault(s) attributed this race (%d off P1's run, %d left on it), %d "
        .. "unexplained on P1's run, %d of his own at a malfunction's end", S.attributed, S.removed, S.kept,
        S.unexplained, S.ownEnds)
end

function M.init()
    St.on("phase", TAG, function(new, old)
        if new == "RACING" then
            S.pre, S.malfMs, S.comp, S.pollMs, S.stMs, S.run, S.arr, S.noRun = nil, {}, {}, nil, nil, nil, nil, nil
            S.attributed, S.removed, S.kept, S.unexplained = 0, 0, 0, 0
            S.ep, S.faultedAt, S.ambigAt, S.forcedAt, S.guestMs, S.ownEnds = {}, {}, {}, {}, nil, 0
            local r = run()
            S.run = r
            S.n = r and queueCount(r) or nil
        elseif old == "RACING" then
            if #joined() > 0 then U.try(TAG, M.poll, true) end
            if S.attributed > 0 or S.unexplained > 0 or S.ownEnds > 0 then U.log(TAG, "%s", M.status()) end
            S.malfMs, S.comp, S.pre, S.run, S.arr, S.ep = {}, {}, nil, nil, nil, {}
        end
    end)
    U.hook(FN, { pre = function(c) U.try(TAG, M.pre, c) end, post = function(c) U.try(TAG, M.post, c) end }, TAG)
end
return M
