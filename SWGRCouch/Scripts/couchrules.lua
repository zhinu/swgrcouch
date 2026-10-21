-- couchrules.lua: COUCH CAMPAIGN - the special events with several humans (0.15 rules pass, 2026-10-14, OFFLINE build:
-- every native fact below is static analysis of the CL381121 exe + JMAP, nothing here has run live yet).
--
-- ===================================================================================================== NATIVE FACTS
-- (disassembly of the CL381121 launch exe; notes 06b §3 completed)
-- N1 RESULT INGESTION IS PER HUMAN, NOT PER P1. ARacingGameMode::OnRacerFinished (0x140fec472) calls the campaign's
--    result ingestion CampaignRun::OnEventFinished (0x1430ddd0a, call site 0x140fec7ff) for EVERY racer whose PlayerState
--    is not bIsABot, whose REC.bHasVehicleWrecked is false and whose pawn IsLocallyControlled (vfunc 0x818 = the exec
--    thunk of Pawn:IsLocallyControlled) - i.e. for every couch guest too - passing THAT racer's REC.EventPosition.
--    OnRacerFinished also runs for an ELIMINATED racer (TimeEliminator tick 0x142fdb18a: bHasFinishedEvent+bHasTimedOut,
--    then OnRacerFinished) and for every unfinished racer at EndRace (OnRaceEnded 0x142fd76ec).
--    One ingestion = RaceResults += {position} on VisitedPlanets[last], CampaignRun:AddCredits (finish credits),
--    node.FinishCredits/Tuning/KitPoints, and on P1's OWN REC (run.playerRacer.Player.RaceEventComponent):
--    FailReasons |= HighRisk(4) when Activity == 3 and position > the tuning threshold, |= MissedRequiredWin(16) when the
--    event is must-win and position >= 2; then, Activity 3 with P1's FailReasons ~= 0 -> a strike + bEarnedRewards = 0.
--    => WITHOUT THIS MODULE a guest's finish (or elimination) is booked into P1's run a second time: double credits and
--    RaceResults, and a guest finishing 4th+ in an eliminator (or being eliminated) costs the team a League Token even
--    when P1 made the top 3. Even the "p1" rule needs the gate below.
-- N2 WRECKS. OnRacerWrecked -> CampaignRun wreck hook (0x1430dd5a6) for every player-controlled non-bot racer: a strike
--    (tuning wreck amount, or the must-win amount), node.bEarnedRewards = 0, RaceResults += DNF(-1). A GUEST's wreck
--    costs P1's run a token and P1's reward round natively. There is no run flag that gates this hook.
-- N3 THE GATE. The ingestion's main path first asks CampaignRun::IsPlayingCoreEvent (0x1471e9544 = reflected
--    IsPlayingCoreEvent): false while CampaignRun.bHasJustCompletedPlaneTest is true -> the ingestion returns at once
--    (only CurrentRunTime += time). bHasJustCompletedPlaneTest is a plain reflected bool, false during every core event
--    (else no race would ever pay), read by the results CSM (BP_Csm_Race_Cam_PickResultsEntry.IsPlayingPlaneIntro) only
--    after the race. Plane tests (ActivePlaneTestEvent) and rival challenges take their own paths BEFORE the gate:
--    plane test = per human finish: won flag VisitedPlanets[last].bHasWonPlaneTest = (pos 1 and target time met),
--    a miss = an immediate strike; rival = per human finish a strike +1/-1 (couch-fix58: M.rivalResolve, D5).
-- N4 P1 = the run: DidLocalPlayerWin (act-finish branch) = PC 0's REC: EventPosition == 1 and FailReasons == 0.
-- N5 THE RACE END GENERATES P1'S REWARD ROUNDS, AND IT ASKS THE SAME GATE (couch-rewards2, static CL382801 + every
--    couch log since 2026-10-14). The race-end virtual (vtable 0x149943450 slot 86 = 0x143049cae) calls the reward
--    generator 0x1430da390 -> 0x1430da3dc, which returns at once unless IsPlayingCoreEvent() (and node.bEarnedRewards).
--    ShouldEndRace ends the race on the GameMode tick right after the LAST human's FinishRacer - before our FAST tick
--    (a Lua loop) could put the flag back. So with the gate closed at that moment (every "best" place race: closed
--    since the first human home; "p1": closed once P1 is done) P1 got NO upgrade round: the qualifier 2026-10-14 and
--    tonight's 2026-10-17 logs, every couch race: gate closed at the last finish -> "rewards VM has no items" /
--    "stage types 1" / "6,1" (27 races); gate open at the last finish (eliminations, same-frame double bookings) ->
--    the round was there (13 races).
--    FinishRacer (CL382801 0x140fec26c) order: the ingestion (0x140fec5f9, skipped for a wreck or while the gate is
--    closed) -> FinishedRacers.Add -> ProcessEvent(REC, Client_OnThisRacerFinished(EventPosition)) (0x140fec783, the
--    FName at 0x14ae97248) - for EVERY racer, finishers, eliminated and wrecked alike. That RPC is a native UFunction:
--    its pre-hook runs AFTER the human's own ingestion and BEFORE the race end. couchrules runs its ledger step there
--    (same frame): the last human out releases the gate, a refundable wreck gets node.bEarnedRewards back - so the
--    race end generates P1's rounds exactly as in solo. The FAST tick stays the fallback (hook not armed: logged).
--
-- ========================================================================================================= DECISIONS
-- D1 cfg.CouchTeamResult = "best" (default) | "p1". The ONE ingestion the run gets is the best human's ("best") or P1's
--    ("p1"). Mechanism: the INGESTION GATE (N3) - couchrules holds run.bHasJustCompletedPlaneTest = true while the next
--    human finish must NOT be booked, false while it must, and puts the original value back the moment every human is
--    done (and on POSTRACE / leaving / world as a safety net), before the results CSM reads it.
--      "best", TEAM TESTS (couch-fix34, audit 12 #4, Jules's Q5: every field test / race-alone test, the podracer
--        test): closed while 2+ players race, open for the last one out; his booking is repaired into the team's pass
--        when an earlier player passed (M.teamTest, teamTestRepair) - the test fails only if EVERY player failed.
--      "best", place races (2 standard, 6 championship, 9 mystery): open until the first human is booked
--        = the first human home (positions are finish order; time trials start together, so first home = fastest).
--      "best", eliminations (3 eliminator, 5 gauntlet = TimeEliminator): closed while 2+ humans are still in, open for
--        the last human standing (an eliminated human is worse than everyone still racing).
--      "p1": open only while P1 is still racing and no guest can be booked first (no racing guest ahead of P1 in a
--        place race; no racing guest in the last CouchRiskBand places in an elimination race).
--    Chosen over (a) swapping EventPosition between P1's and the best guest's REC at POSTRACE: too late, the ingestion
--    already ran at each finish (N1); (b) a native hook: the ingestion is not a UFunction (UE4SS cannot hook it);
--    (c) flagging guests bIsABot: blocks N1/N2 per racer, but ShouldEndRace ends the race as soon as no NON-bot racer is
--    racing (guests cut off at P1's finish), bots skip spectate/finish flows; (d) gate via CampaignSubsystem.RepeatRaces:
--    needs a fake object, read by more of the post-race flow.
--    RISK (gate): while the gate is closed, every native caller of IsPlayingCoreEvent (16 call sites) sees "not a core
--    event". It is closed only (1) after the team result is booked, until the last human is done, and (2) in
--    elimination races while 2+ humans are in. Unverified live: mid-race systems that poll it (faults, contracts).
--    RISK (timing): the gate flips on the FAST tick; two humans finishing inside one frame, or a forced finish of 2+
--    humans at EndRace while open, books both (logged "double booking"). In "p1" eliminations a P1 overtake into the
--    last place inside one frame of the elimination timer can be missed (logged).
--    "best" + a guest carrier while P1 is already done: P1's FailReasons (eliminated/wrecked bits) would make the
--    Activity-3 check strike regardless of the guest's place (N1), so they are cleared while the gate is open for the
--    guest, and put back afterwards only if the team result FAILED (team success keeps P1's REC clean so the post-race
--    flow sees the team's success; the results board still shows P1's real place/time).
--    cfg.CouchFinalWinSwap (default true): on the run's FINAL event, a guest carrier who WON and a P1 who did not get
--    their EventPosition / FailReasons swapped once every human is done, so DidLocalPlayerWin (N4) takes the tour-win
--    branch. Visible: the results board lists P1 first. couch-fix30 (audit 12 #5): a WRECKED P1 is swapped too (the act
--    never finished: the run stalled), and each human's real result is kept (M.realResult) for his own payout, rounds,
--    side bet and backer rating - the swap is for DidLocalPlayerWin only.
--    couch-fix30 (audit 12 #2): "best" eliminations - a human FINISHING while the gate is closed (another human at
--    elimination risk) is not booked; the next booking (worse) is repaired into his place (repairMissed below).
--    Every human's own result is kept per race (snapshot: place, wrecked, eliminated, fail bits; M.ownResult(ctrlId)):
--    the team test verdict (couch-fix34, Q5) and P1's OWN PLACE economy (couch-fix35, Q1: ownEconomy - P1's wallet and
--    reward round follow his own result, the team booking keeps tokens / must-win / the act; setting CouchEconomy).
-- D2 WRECKS cfg.CouchWreckToken = "all" (default) | "each". "all" = GALAXY RUN's rule: a wreck costs the team a token only
--    when EVERY human wrecked. Any wreck strike (N2) taken while another human has not wrecked is refunded on the next
--    FAST tick (CampaignRun.Strikes back, the new mStrikeChangesForDisplay entries Delta 0 + bSeen, node.bEarnedRewards
--    back, the DNF RaceResults entry bShowInRecaps false). The last human's wreck when all wrecked keeps its token.
--    "each" = native, extended to guests: every human wreck costs a token. P1's own wreck follows the same policy.
--    couch-fix30 (audit 12 #8): "another human" = one still RACING or FINISHED - an eliminated human is out with a failed
--    result (P1 eliminated + P2 wrecking dodged the token). A strike protector (P1's native Second Chance) consumed by a
--    refunded strike is OWED back: the next strike that stands in a couch race (until the protector's planet) is
--    protected instead. P1's own refunded wreck: cfg.CouchWreckRefundRewards (default false = the solo rule, audit Q2):
--    the token only - he loses his reward round like a wrecked guest (taken right before the race end).
--    A wrecked guest himself: DNF payout, no own reward offer this round (the native single-player wreck rule).
--    couch-fix65 (AUTO-160d): his credits lines still show, as in the solo hub - a challenge settled after the race
--    end makes his CREDITS stage and opens his area (couchrun.wreckCredits160); nothing to show = no area.
--    #81: EXCEPT in an elimination race (eliminator / gauntlet) when his wreck was refunded (the team kept its token):
--    a wreck there leaves the race like an elimination, so he is booked at his standing (M.standingAt: 1 + the racers
--    not eliminated / wrecked yet) - credits and his own reward round as an eliminated guest at that place (D4).
-- D3 PLANE TESTS (ActivePlaneTestEvent): every human finish is booked natively (N3). "best": a miss strike is refunded
--    while another human still races or a human already won; the won flag = any human won. "p1": guests' strikes are
--    refunded, the won flag = P1's. (Plane tests with guests exist only with cfg.CouchTimeTrials grids.)
-- D4 GUEST PAYOUTS (couchrun.onRaceEnd asks M.guestOutcome): what the NATIVE run pays P1 for the same finish (see
--    ECONOMY above M.guestPayout: one position row on every planet, the guest's own end-of-event multiplier, time
--    trials = target beaten or not, no tier shift); an eliminated guest is paid his final place; a wreck pays 0 (the
--    native ingestion skips wrecked racers). No reward offer for anyone when the team's event earned no rewards
--    (node.bEarnedRewards false: P1 has no round either).
-- D5 RIVAL CHALLENGES (Activity 11/12, or run.bIsPlayingRivalChallengeEvent): fixed 2-racer recipe. couch.patchGrid
--    never touches them (it would have taken the RIVAL's entry: it picks the last bot entry), and never takes a
--    protected entry anywhere (bIsRival / bIsRaceNemesis / bIsAntagonist / bIsSideBet / the run's active rival).
--    couch-fix58 (Jules: every player races every campaign race): M.rivalPlace APPENDS every guest to the 2-racer recipe
--    at the kickoff (KickOffRivalChallengeEvent post-hook; a CONTINUE at FRONTEND -> TRANSIT), each with his own copy of
--    the rival (RIVAL INSTANCES, cfg.CouchRivalInstances) or vs the one rival (the shared race); the game books the first
--    player out's result, the team's rule ("best": any player beat his rival) is applied when every player is out
--    (M.rivalResolve: a won challenge the game booked as lost repaired - strikes, bPlayerWonRivalChallenge, the rivalry's
--    UnlockedOnWin). Guests are paid as solo pays a rival challenge: nothing (cfg.CouchRivalRaces false = the old rule).
--    A guest without a grid entry SITS OUT: St.race.singleView = true at race_enter (split.enterRace, hud, pause and
--    present already treat that as "one view, no guest HUD/pause") = everyone watches P1's race on the big screen.
--    Each sitting-out guest gets cfg.CouchSitOutShare x the planet's native skip bonus and his reward offer is kept pending
--    (it opens with P1's next native reward round).
-- D6 MYSTERY RACES: KickOffMysteryInteractionEvent builds with the all-PC builder (guests get entries natively).
--    patchGrid only runs at ChooseNextMapNode (never for these) and skips non-race nodes (7/8/9 + rivals); a post-hook
--    on KickOffMysteryInteractionEvent checks the grid (duplicates/missing logged) and writes the guests' run builds
--    (couchrun.applyBuilds). Their results go through the same gate / payouts (kind "mystery" = standard table).
--    NOTE (#51, decoded on the live exe): that hook NEVER fires - PaddockGameMode:FinishLeaving's native body calls
--    KickOffMysteryInteractionEvent directly (0x142fb094a -> 0x1430ce7f4); the field-test grid work is in couch.lua's
--    FinishLeaving hook (fieldTestPre / Post).
-- D7 CHAMPIONSHIP GRID (cfg.CouchChampionGrid, default true): GMV_HeadToHead (boss + PlayerChoice x1) gets +guests
--    PlayerChoice entrants for the duration of ChooseNextMapNode (pre -> post, restored at once), so the builder adds
--    fill entries that couch.patchGrid re-points to the guests [? live: authored championship events may carry their
--    own GridMakeup]. With D8 on, D7 is the FALLBACK (shared boss race) when the instance plan cannot be made.
-- D8 BOSS INSTANCES (couch-fix38, Jules's Q12 B, cfg.CouchBossInstances default true): every player races his own copy
--    of the boss race. Pick: GMV_HeadToHead grown to 2 x (1 + guests) (M.patchChampion), the builder's [P1, boss, fill..]
--    placed per set by M.bossPlace (the boss entry CLONED onto each copy's entry: the game's own AI build state);
--    race: instances.lua (per-view hide, per-set collision channels and hazards: the boss abilities stay in their copy,
--    boss pacing per copy); booking: the gate holds it to the last player out and bossRepair writes the team's result
--    (the act is won if ANY player beats his own boss, "best"; "p1" = P1's). The #97 intro swap stays (one global
--    RacingGameState.Rival / "last racer" binding for every local chain: a per-player boss binding is not possible).
-- Every game access is pcall-guarded; no UObject is held across worlds (dropped on leaving/world).
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "couchrules"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local okD, D = pcall(require, "rundata")
if not okD or type(D) ~= "table" then D = nil end

---------------------------------------------------------------------------------------------------- pure rules
M.FAIL = { Wrecked = 1, ModeRules = 2, HighRisk = 4, ExtraConditions = 8, MissedRequiredWin = 16 }
local ACT_KIND = { [2] = "standard", [3] = "highrisk", [4] = "fieldtest", [5] = "knockout", [6] = "champion",
                   [9] = "mystery", [10] = "planesprint", [11] = "rival", [12] = "rival" }
function M.kindOf(activity) return ACT_KIND[tonumber(activity) or -1] or "standard" end
-- TimeEliminator events (GMV_Eliminator, GMV_FinalKnockout)
function M.isElimination(activity) local a = tonumber(activity); return a == 3 or a == 5 end
-- couch.patchGrid may re-point AI entries on this node (races only; never rivals or non-race nodes)
local NO_PATCH = { [7] = "black market", [8] = "repair", [9] = "mystery (all-PC builder)", [11] = "rival race",
                   [12] = "rival mystery" }
function M.allowGridPatchFor(activity)
    local why = NO_PATCH[tonumber(activity) or -1]
    return why == nil, why
end

function M.rule()
    local r = opt("CouchTeamResult", "best")
    return (r == "p1") and "p1" or "best"
end

-- couch-fix34 (audit 12 issue 4, Jules's Q5 2026-10-18): a TEAM TEST (a field test of any mode - precision, ramjet,
-- takedowns, time trial, hot lap, any race-alone event - and a podracer test) is FAILED for the team only if EVERY
-- player failed; one pass = the team passes, decided once everyone is done. "best" only ("p1": P1's test is the run's).
function M.teamTest(rule, kind, alone)
    return rule ~= "p1" and (alone == true or kind == "fieldtest" or kind == "planesprint")
end

-- humans: { {pnum, isP1, racing, pos, atRisk} }, ingested: the team result is already booked; teamTest (couch-fix34):
-- the booking is held until the last player is out (the first one home may be the one who failed).
-- -> open (bool), why (text)
function M.gateWanted(rule, activity, humans, ingested, teamTest)
    if ingested then return false, "team result booked" end
    local racing, p1 = {}, nil
    for _, h in ipairs(humans) do
        if h.racing then racing[#racing + 1] = h end
        if h.isP1 then p1 = h end
    end
    if #racing == 0 then return false, "no human racing" end
    -- couch-fix38 (D8): boss instances hold the booking the same way, under either rule (each player's own race)
    if (teamTest and rule ~= "p1") or teamTest == "boss" then
        -- couch-fix34: ONE native booking, the last player's, repaired into a pass when an earlier player passed
        local what = (teamTest == "boss") and "boss instances" or "team test"
        if #racing >= 2 then return false, string.format("%s: held until every player is done (%d racing)", what, #racing) end
        return true, string.format("%s: P%s is the last player out", what, tostring(racing[1].pnum))
    end
    local elim = M.isElimination(activity)
    if rule == "p1" then
        if not (p1 and p1.racing) then return false, "P1 is done" end
        if #racing == 1 then return true, "P1 alone" end
        for _, h in ipairs(racing) do
            if not h.isP1 then
                if elim and h.atRisk then return false, string.format("P%s at elimination risk", tostring(h.pnum)) end
                if not elim and (tonumber(h.pos) or 99) < (tonumber(p1.pos) or 99) then
                    return false, string.format("P%s ahead of P1", tostring(h.pnum))
                end
            end
        end
        return true, "P1 is next"
    end
    if elim then
        if #racing == 1 then return true, string.format("P%s last human standing", tostring(racing[1].pnum)) end
        -- 2+ humans in: the next human out is either a FINISHER (better than every human still racing: book him) or
        -- the one the timer eliminates (the last place: worse than the others). Live 2026-10-14: closed for every
        -- 2+-humans moment, P1's finish in 1st was never booked and P2's later 2nd became the team result. Closed only
        -- while a racing human sits in the elimination band (cfg.CouchRiskBand last places).
        for _, h in ipairs(racing) do
            if h.atRisk then return false, string.format("P%s at elimination risk", tostring(h.pnum)) end
        end
        return true, string.format("%d humans in, none at elimination risk", #racing)
    end
    return true, "first human home"
end

-- ECONOMY (couch-econ 2026-10-15): THE NATIVE PAYOUT P1 GETS, applied to a guest's own finish.
-- Data: every planet setup (all 3 acts, bosses included) serializes the Planet1 position ids and the Planet1 skip id
-- (only Act III's final Whippet carries Planet5's skip): rundata.payouts.native (gen-rundata.py). Live proof, qualifier
-- 2026-10-14 (state/runs/20261014-1917-qualifier-2p, P1's CampaignRun.Credits after each of the 13 events):
--   Jakku race 1st +1250, field test (target beaten) +1250, [Sen Fira's deal: Favour_MYST_HalfCreditRewards =
--   CreditsFromEndOfEventRewardsMultiplier -0.5, "position credits halved"], race 1st +625 (Jakku, Lantaana x2,
--   Ando), Lantaana ELIMINATOR 1st +625, field tests beaten +1250 (Lantaana, Ando: NOT halved), field test missed +0,
--   Ando race 4th +350, Derven QUALIFIER 1st +1250 (NOT halved).
-- => position credits = native.pos[place] on EVERY planet (no per-planet tier, eliminators NOT one planet ahead),
--    x the run's end-of-event multiplier (mystery deals, Victorious Loser) for place races (race, eliminator,
--    gauntlet, mystery race); a time trial (field test, podracer test) pays native.pos[1] when the target is beaten,
--    0 when missed, never multiplied; the championship pays native.pos[place], never multiplied.
--    A wreck is never ingested natively (N1: the ingestion skips bHasVehicleWrecked racers): 0 credits.
-- (The old guest rule = payouts.pos[planet (+1 for eliminator/gauntlet/championship)]: P2 ended Act I on 30,500 CR vs
-- P1's 10,025.)
local TIME_TRIAL = { fieldtest = true, planesprint = true }
local UNMULTIPLIED = { champion = true }

local function nativeRow()
    local pt = D and D.payouts or nil
    local row = pt and pt.native and pt.native.pos or (pt and pt.pos and pt.pos[1]) or nil
    return row or { 1250, 1000, 800, 700, 600, 500, 400, 300, 200, 100, 50, 25 }
end
M.nativeRow = nativeRow

-- the guests' payout (native, see above). planet is kept for the callers' logs; mult = the guest's end-of-event
-- credits multiplier (1 = none); beat = a time trial's target met (nil = unknown: paid as beaten).
function M.guestPayout(kind, planet, pos, dnf, mult, beat)
    local scale = tonumber(opt("RunPayoutScale", 1)) or 1
    local row = nativeRow()
    if TIME_TRIAL[kind] then
        if dnf then return 0 end
        -- #107 (live 2026-10-18 10:11, podracer test failed by both: P1's node "finish credits 25, earned rewards true,
        -- reward rounds 1, strikes 0"): a missed PODRACER test still pays the bottom row; a missed field test pays 0
        -- (live 08:58 / 09:03: "finish credits 0, earned rewards false, strikes 1")
        if beat == false then
            return (kind == "planesprint") and math.floor((tonumber(row[#row]) or 25) * scale) or 0
        end
        return math.floor((tonumber(row[1]) or 1250) * scale)
    end
    if dnf then return math.floor((tonumber(opt("CouchWreckCredits", 0)) or 0) * scale) end
    local i = math.max(1, math.min(#row, math.floor(tonumber(pos) or #row)))
    local cr = (tonumber(row[i]) or 25) * scale
    if not UNMULTIPLIED[kind] then cr = cr * math.max(0, tonumber(mult) or 1) end
    return math.floor(cr + 0.5)
end
-- couch-fix32 (audit 12 issue 17): a PASSED podracer test pays two rows natively - the finish row ("Beat Target Time",
-- the Planet1 row's 1,250, what guestPayout gives) AND "Passed Podracer Challenge" (CampaignStringsDef
-- PlayerFacingCreditsReasonPlaneTestWon) = ECO_Campaign CampaignEconomy.Rewards.PlaneTestCredits 3,000 (rundata
-- misc.planeTestCredits; the decoded race-end credit function adds it for a plane test, 07-p2-rewards-parity §1.3.1).
-- A failed one pays the bottom finish row only (live 10:11: finish credits 25, run credits +25). -> the second row
function M.planeTestCredits(kind, dnf, beat)
    if kind ~= "planesprint" or dnf or beat == false then return 0 end
    local v = tonumber(D and D.misc and D.misc.planeTestCredits) or 3000
    return math.floor(v * (tonumber(opt("RunPayoutScale", 1)) or 1))
end

-- does the run's end-of-event credits multiplier apply to this event kind
function M.multipliedKind(kind) return not TIME_TRIAL[kind] and not UNMULTIPLIED[kind] end

-- the planet's native SKIP REWARD credits (the planet setup's SkipRewardEconomyId): act 1..3, engine = the planet's
-- engine name ("Mastiff", "Whippet", ...); unknown -> the Planet1 value
function M.skipCredits(act, engine)
    local pt = D and D.payouts or nil
    local nat = pt and pt.native and pt.native.skip or nil
    local v = nat and act and nat[act] and engine and nat[act][engine] or nil
    v = tonumber(v) or tonumber(pt and pt.skip and pt.skip[1]) or 1000
    return math.floor(v * (tonumber(opt("RunPayoutScale", 1)) or 1))
end

function M.sitOutCredits(planet, act, engine)
    local cr = M.skipCredits(act, engine)
    local share = tonumber(opt("CouchSitOutShare", 0.5)) or 0.5
    return math.floor(cr * math.max(0, share))
end

-- ctx = {kind, planet, pos, wrecked, sitOut, teamEarned, mult, beat, act, engine} -> {credits, offer, note}
-- couch-fix63 (AUTO-154g, live round 8 11:25:27): the words of a guest's own reward-flow log line. After a team-FAILED
-- podracer test P2's line said "rewards earned: stages 1,2(stat x3)" while the tester read P1's hub as "NO REWARDS
-- (+25 CR)" - read as P2 being paid for a fail. It is the solo fail itself: P1's node of that very race booked
-- "completed true, earned rewards true, reward rounds 1 (at 1), finish credits 25, tuning 2" (gauntlet RESULT
-- 11:26:54; RewardRoundIx 0 -> 1 = P1's round was played), the same as #107b (2026-10-18 10:11, Jules's photo: FAULTS
-- + CREDITS + UPGRADE PACK). So the line names a failed test's round for what it is.
function M.flowLabel(kind, earned, beat)
    if not earned then return "no reward round" end
    if beat == false and kind == "planesprint" then
        return "podracer test FAILED: the solo fail's credits + base round, as the game books P1's own fail"
    end
    return "rewards earned"
end

function M.guestOutcome(ctx)
    -- #89 (live 2026-10-18 09:06, podracer test: "P2 finished P0: +500 CR - sat out (planesprint)" + his own reward
    -- flow): a test is each player's own game (#87) - a guest without a run of his own has no result to be paid for
    if ctx.sitOut and TIME_TRIAL[ctx.kind] then
        return { credits = 0, offer = false, note = "sat out (" .. tostring(ctx.kind) .. "): no run of his own, no rewards" }
    end
    if ctx.sitOut then
        return { credits = M.sitOutCredits(ctx.planet, ctx.act, ctx.engine), offer = true,
                 note = "sat out (" .. tostring(ctx.kind) .. ")" }
    end
    -- couch-fix58 (D5): a guest who RACED a rival challenge is paid what P1 gets for it in solo: nothing (the native rival
    -- path books no credits and IsPlayingCoreEvent is false = no reward round); the challenge itself is the team's
    if ctx.kind == "rival" then
        return { credits = 0, offer = false, note = "rival challenge: no prize money / reward round (as solo; the "
            .. "challenge is the team's)" }
    end
    local pos = math.floor(tonumber(ctx.pos) or 99)
    local dnf = ctx.wrecked == true or pos >= 99 or pos < 1
    local beat = ctx.beat
    if beat == nil and TIME_TRIAL[ctx.kind] then beat = ctx.teamEarned end
    local out = { credits = M.guestPayout(ctx.kind, ctx.planet, pos, dnf, ctx.mult, beat), offer = true, note = "" }
    if TIME_TRIAL[ctx.kind] and not dnf then out.note = (beat == false) and "target missed" or "target beaten" end
    out.plane = M.planeTestCredits(ctx.kind, dnf, beat)
    if ctx.wrecked then out.offer, out.note = false, "wrecked: no own reward round" end
    -- #87 (Jules: every player's field test is his own game): a time trial with HIS own verdict known follows it alone,
    -- like solo - passed = his own reward stages whatever the booked (team) result; failed = what the game gives a solo
    -- player who failed (#107): a field test = no round (his FAULTS stage still comes: couchrun), a podracer test = the
    -- node's base round (UPGRADE PACK) all the same
    if TIME_TRIAL[ctx.kind] and ctx.beat ~= nil and not dnf then
        if ctx.beat == false then out.offer = (ctx.kind == "planesprint") end
        return out
    end
    if ctx.teamEarned == false then out.offer, out.note = false, "the team earned no rewards" end
    return out
end

-- a grid entry couch.patchGrid must never hand to a guest
function M.protectedEntry(ps, activeRival)
    local prot = false
    pcall(function()
        prot = ps.bIsRival == true or ps.bIsRaceNemesis == true or ps.bIsAntagonist == true or ps.bIsSideBet == true
    end)
    if not prot and activeRival ~= nil and U.ok(activeRival) then prot = U.key(activeRival) == U.key(ps) end
    return prot
end

-- strike refund decision for one human event.
-- ev = {what = "wreck"|"planefail", who = human, humans = {...}, rule, teamWon = bool}
function M.refundable(ev)
    if ev.what == "wreck" then
        if opt("CouchWreckToken", "all") == "each" then return false, "CouchWreckToken each" end
        -- couch-fix30 (audit 12 #8): only a human who still RACES or FINISHED carries the team's result on. An
        -- ELIMINATED one is out with a failed result (solo: eliminated = a token): P1 eliminated + P2 wrecking was
        -- refunded, nobody was booked, the team kept a token no solo player keeps.
        for _, h in ipairs(ev.humans) do
            if h ~= ev.who and not h.wrecked and not h.elim then
                return true, h.racing and "another human still races" or "another human finished"
            end
        end
        return false, "no other human still racing or finished (wrecked / eliminated)"
    end
    if ev.what == "planefail" then
        if ev.rule == "p1" then return not ev.who.isP1, ev.who.isP1 and "P1's own test" or "a guest's test (p1 rule)" end
        if ev.teamWon then return true, "a human already passed" end
        for _, h in ipairs(ev.humans) do
            if h ~= ev.who and h.racing then return true, "another human still racing" end
        end
        return false, "last human of the test"
    end
    return false, "not a refundable event"
end

---------------------------------------------------------------------------------------------------- game reads
-- the CampaignSubsystem through couch.lua's cached accessor (stutter fix: no FindFirstOf per tick); the plain lookup
-- only where that accessor does not exist (tests' couch stub)
local function campaignSub()
    local m = nil
    pcall(function() m = U.mod("couch") end)
    if type(m) == "table" and type(m.campaignSubsystem) == "function" then
        local c = nil
        pcall(function() c = m.campaignSubsystem() end)
        return U.ok(c) and c or nil
    end
    local ok, f = pcall(FindFirstOf, "CampaignSubsystem")
    return (ok and U.ok(f)) and f or nil
end

local function campaignRun()
    local r = nil
    pcall(function() r = campaignSub().ActiveRun end)
    return U.ok(r) and r or nil
end
M._campaignRun = campaignRun

local function currentNode(run)
    local nd = nil
    pcall(function() nd = run:GetCurrentNode() end)
    if U.ok(nd) then return nd end
    pcall(function()
        local path = run.mPlayerPath
        local n = U.arrayCount(path)
        if n > 0 then nd = path[n].Node end
    end)
    return U.ok(nd) and nd or nil
end

local function lastPlanet(run)
    local p = nil
    pcall(function()
        local vp = run.VisitedPlanets
        local n = U.arrayCount(vp)
        if n > 0 then p = vp[n] end
    end)
    return p
end

local function isRivalRace(run)
    local r = false
    pcall(function() r = run.bIsPlayingRivalChallengeEvent == true end)
    return r
end

local function activityNow(run)
    local a = nil
    pcall(function() a = tonumber(campaignSub():GetCurrentNodeActivity()) end)
    if a == nil then
        local nd = currentNode(run)
        if nd then pcall(function() a = tonumber(nd.Activity) end) end
    end
    if isRivalRace(run) then a = 11 end
    return a
end

local function planeTestActive(run)
    local on = false
    pcall(function() on = U.ok(run.ActivePlaneTestEvent) end)
    return on
end

---------------------------------------------------------------------------------------------------- resume repair
-- fix16 (live 2026-10-15): the gate's flag ends up IN THE CAMPAIGN SAVE. The run autosaves at the race end, natively,
-- while the gate is still closed (the last human's finish is the one the gate must not book; our FAST tick puts the
-- flag back only after it). CONTINUE then resumes PostEvent (EContinueRunState 5) with bHasJustCompletedPlaneTest =
-- true, and BP_Csm_Race_Cam_PickResultsEntry (IsLoadingSaveIntoPostEvent -> IsPlayingPlaneIntro: HasJustCompletedPlaneTest
-- and IsPlaneTestActuallyPlaneIntro) jumps to CSM_RF_Results_Campaign_ConfirmLeavePlanet: the NEXT PLANET overview of a
-- planet that was never left (map VM CurrentPlanetIndex -1 -> WBP_PlanetSelector "Current Planet Idx" -2, its
-- SelectPlanet only fires when the current planet is selected = never: A on NEXT PLANET does nothing). The race map
-- also flashed PRERACE -> POSTRACE (the post-event resume) and paid the guests a race nobody ran (couchrun.raceRan).
-- There is no UFunction that saves the run, so the save cannot be fixed at the race end: the flag is put back right
-- after a load, before the results CSM reads it. A marker file (couch-gate.txt) says "a save may hold our flag": set
-- when the gate closes, cleared when a load reads the flag false or a real plane test starts (whose flag is native).
-- Without the marker (a save from before this fix) the repair still runs while 2+ local players are in.
local GATE_FILE = "couch-gate.txt"
local CONT_POST_EVENT = 5                    -- EContinueRunState::PostEvent (logged)

local function gateFilePath()
    local ok, d = pcall(function() return require("settings").modDir() end)
    return (ok and type(d) == "string") and (d .. "/" .. GATE_FILE) or nil
end

function M.gateMarker()
    local p = gateFilePath()
    local f = p and io.open(p, "r")
    if not f then return nil end                                  -- nil: no marker file yet (a save before fix16)
    local s = f:read("a") or ""
    f:close()
    return s:find("closed", 1, true) ~= nil
end

function M.setGateMarker(on, why)
    local cur = M.gateMarker()
    if cur ~= nil and cur == (on == true) then return end
    local p = gateFilePath()
    local f = p and io.open(p, "w")
    if not f then return end
    f:write(on and "closed" or "open", " ", tostring(why or ""), " ", os.date("%Y-%m-%d %H:%M:%S"), "\n")
    f:close()
end

-- the decision, pure (sim): {flag, plane, intro, loading, cont, marker (true/false/nil = no file), players}
-- -> repair?, why. Only a LOAD into the post event (IsLoadingSaveIntoPostEvent): a live race end never qualifies.
function M.resumeRepairWanted(s)
    if s.flag ~= true then return false, "flag clear" end
    if s.plane == true then return false, "a plane test is active (native flag)" end
    if s.intro == true then return false, "plane intro playing (native)" end
    if s.loading ~= true then return false, "not a post-event load" end
    if s.marker == true then return true, "marker: the gate was closed when the run saved" end
    if s.marker == nil and (tonumber(s.players) or 1) >= 2 then
        return true, "no marker file (save from before fix16), couch session"
    end
    return false, s.marker == false and "marker clear: native flag left alone" or "solo, no marker: native flag left alone"
end

-- after a load (couchpage CONTINUE, every phase change outside a ruled race): put the flag back. -> repaired?
function M.repairResume(why)
    if M._state and M._state() then return false end             -- a ruled race owns the flag
    local run = campaignRun()
    if not run then return false end
    local s = { marker = M.gateMarker(), players = #U.localPlayers() }
    pcall(function() s.flag = run.bHasJustCompletedPlaneTest == true end)
    s.plane = planeTestActive(run)
    pcall(function() s.intro = run.bIsPlayingPlaneIntro == true end)
    pcall(function() s.loading = campaignSub():IsLoadingSaveIntoPostEvent() == true end)
    pcall(function() s.cont = tonumber(campaignSub():GetContinueRunState()) end)
    if s.flag == false and s.marker == true and s.loading then M.setGateMarker(false, "load read the flag clear") end
    local yes, reason = M.resumeRepairWanted(s)
    if not yes then return false end
    local ok = pcall(function() run.bHasJustCompletedPlaneTest = false end)
    U.log(TAG, "resume repair (%s): bHasJustCompletedPlaneTest true -> false %s (%s; continue state %s): the post-event "
        .. "resume shows the race results, not the NEXT PLANET overview", tostring(why), ok and "ok" or "FAILED", reason,
        tostring(s.cont))
    return ok
end

---------------------------------------------------------------------------------------------------- #99 run lock
-- #99 (playtest 2026-10-18): after the boss-intro freeze the run could not be continued: CampaignSaveManager:
-- CanContinueCurrentCampaignSave() false, only NEW ACT. Static (CL382801): CanContinueCurrentCampaignSave (exec
-- 0x1470f24be) = CampaignSaveData valid (WasLoaded or WasSaveRequested) AND NOT CampaignSaveHeader.CampaignRunLocked;
-- the save writes the header from CampaignRun.bRunLocked (+0x346, 0x14300821a). The game locks a run only when it ends:
-- LockRun (pause ABANDON TOUR, the run-end recap), CleanupAfterRunAndPrepareForNext, RestartCampaignSelected (NEW ACT),
-- ContinueAfterCompletingCampaign, a completed scenario, and the STRIKE CHANGE 0x1430de4c6: a strike taking Strikes
-- from below GetStrikesNeededToEndRun() to it = the run is LOST: run-end record (0x1430d79c4), bRunLocked = 1, a save
-- request. A kill mid-event in SOLO is resumable (the save at the node pick is EContinueRunState StartEvent; the couch
-- resumed four such saves: #21 #29 #40 #117). The playtest's saves (state/save-profiles/history): 08:22 UTC no lock
-- tag, 09:32:48 (checkpoint #300, the boss pick) CampaignRunLocked = true. The only strike change between them: P2's
-- wreck in the eliminator, 08:41:11 (Strikes 1 -> 2 = the limit), refunded by D2 ("P2 wreck: 1 strike(s) refunded") -
-- the refund put Strikes back but NOT the lock the native strike had set, so the run played on locked and every later
-- save (from #247, 08:41:11.95, Strikes 1 = written after the refund: the native save is deferred) carried
-- CampaignRunLocked. = the couch made the run unresumable, not a game rule (solo: that strike ends the run).
-- FIX: a refund that brings Strikes back below the limit also clears the lock that strike set (bRunLocked false; never
-- a lock that was there before the strike, never while Strikes stay at the limit). The deferred lock-save then writes
-- an unlocked header, as every later save. The native run-end record of the refunded strike (stats) stays.

-- pure (sim): s = {locked (now), wasLocked (before the strike), strikes (after the refund), need} -> unlock?, why
function M.unlockWanted(s)
    if s.locked ~= true then return false, "run not locked" end
    if s.wasLocked == true then return false, "locked before the strike (not the refunded strike's lock)" end
    local st, need = tonumber(s.strikes), tonumber(s.need)
    if st == nil then return false, "strikes unreadable" end
    if need ~= nil and st >= need then return false, string.format("strikes %d still at the limit %d", st, need) end
    return true, need and string.format("strikes %d < limit %d after the refund", st, need)
        or "the refunded strike locked it (limit unreadable)"
end

-- refund(): -> unlocked?
function M.unlockAfterRefund(run, prev, why)
    if not run then return false end
    local s = { wasLocked = prev and prev.locked == true }
    pcall(function() s.locked = run.bRunLocked == true end)
    pcall(function() s.strikes = math.floor(tonumber(run.Strikes) or 0) end)
    pcall(function() s.need = tonumber(run:GetStrikesNeededToEndRun()) end)
    local yes, reason = M.unlockWanted(s)
    if not yes then
        if s.locked then U.log(TAG, "#99 run lock kept (%s): %s", tostring(why), reason) end
        return false
    end
    local ok = pcall(function() run.bRunLocked = false end)
    local now = nil
    pcall(function() now = run.bRunLocked == true end)
    ok = ok and now == false
    U.log(TAG, "#99 run lock cleared %s (%s: %s): the refunded strike had reached the limit and locked the run - the "
        .. "game's CONTINUE stays available", ok and "ok" or "FAILED", tostring(why), reason)
    return ok
end

-- P1 + the joined guests with a racer entry: {pnum, ctrlId, isP1, pc, ps, rec}
local function humanList()
    local out = {}
    local lp = U.localPlayers()
    if lp[1] and U.ok(lp[1].pc) then out[1] = { pnum = 1, ctrlId = lp[1].ctrlId, isP1 = true, pc = lp[1].pc } end
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    if ok and type(list) == "table" then
        for _, e in ipairs(list) do out[#out + 1] = { pnum = e.pnum, ctrlId = e.ctrlId, isP1 = false, pc = e.pc } end
    end
    local gs = U.gs()
    local res = {}
    for _, h in ipairs(out) do
        pcall(function() h.ps = h.pc.PlayerState end)
        if U.ok(h.ps) then
            pcall(function() h.rec = h.ps.RaceEventComponent end)
            local idx = -1
            pcall(function() idx = gs:FindRacerIndexByPlayer(h.ps) end)
            h.inRace = type(idx) == "number" and idx >= 0
            if U.ok(h.rec) and h.inRace then res[#res + 1] = h end
        end
    end
    return res
end

local function readRec(h)
    local r = h.rec
    -- R.humans live across fast ticks: a REC whose PlayerState is gone (a guest dropped, the world went before the
    -- phase event) is a dead object, and a property read on it is a native AV that pcall cannot catch. Keep the last
    -- values; the human counts as done.
    if not U.ok(r) then
        h.gone = true
        h.pos = h.pos or 99
        h.racing = false
        return h
    end
    -- couch-racegc: plain field reads (no closure per field per human per FAST tick); a failed read keeps the last value
    local get = U.getField
    local ok, v = pcall(get, r, "EventPosition")
    if ok then h.pos = math.floor(tonumber(v) or 99) end
    ok, v = pcall(get, r, "bHasFinishedEvent")
    if ok then h.fin = v == true end
    ok, v = pcall(get, r, "bHasVehicleWrecked")
    if ok then h.wrecked = v == true end
    ok, v = pcall(get, r, "bHasBeenEliminated")
    if ok then h.elim = v == true end
    ok, v = pcall(get, r, "FailReasons")
    if ok then h.fail = math.floor(tonumber(v) or 0) end
    h.pos = h.pos or 99
    -- h.outHook: his FinishRacer ran (N5 hook) - out even before the RPC's own flags are written
    h.racing = not (h.fin or h.wrecked or h.elim or h.outHook)
    return h
end

-- couch-fieldtest (#35): a human's OWN result, taken the tick he stops racing (before any team bookkeeping: the "best"
-- rule may clear P1's fail bits later while a guest carries the team result) -> h.snap; couchsolo.lua's result screens and
-- band read it from M.last.humans. Only on that edge (and once at the race's end for the rest): no per-tick cost.
local function snapOf(h)
    -- pos (couch-fix30): his own place when he stopped racing, whatever the team bookkeeping / final swap does later
    local s = { fin = h.fin == true, wrecked = h.wrecked == true, elim = h.elim == true, fail = h.fail or 0, pos = h.pos }
    local r = h.rec
    if U.ok(r) then
        local ok, v = pcall(U.getField, r, "EventFinishTime")
        if ok then s.time = tonumber(v) end
        ok, v = pcall(U.getField, r, "bHasTimedOut")
        if ok then s.timedOut = v == true end
        ok, v = pcall(U.callMethod, r, "HasPlayerFailedEvent")
        if ok and type(v) == "boolean" then s.failedCall = v end
    end
    -- #37: a takedowns / ramjet test raced by several players: his OWN score (the game's fail rule reads one player)
    local okS, sc = pcall(function() return U.mod("soloscore").scoreOf(h.ps) end)
    if okS and type(sc) == "table" then s.score = sc end
    return s
end
M._snapOf = snapOf

-- couch-racegc: every racer's RaceEventComponent, re-read from the GameState at most once a second (a race's grid
-- does not change; each FAST tick re-reading GameState.Racers + 8 PlayerStates + 8 components made ~17 UE4SS wrappers).
-- Each rec is U.ok-checked every tick before any read.
local riskCache = { at = -1e12, gen = nil, race = nil, recs = nil }
local R
local function riskRecs()
    local c, now = riskCache, St.nowMs()
    if c.recs and c.gen == St.worldGen and c.race == R and now - c.at < 1000 then return c.recs end
    local recs = {}
    pcall(function()
        local racers = U.gs().Racers
        for i = 1, U.arrayCount(racers) do
            local ps = racers[i]
            local rec = U.ok(ps) and ps.RaceEventComponent or nil
            if U.ok(rec) then recs[#recs + 1] = rec end
        end
    end)
    c.recs, c.at, c.gen, c.race = recs, now, St.worldGen, R
    return recs
end
-- position of a racer still racing, nil when done / unreadable
local function stillPos(rec)
    if rec.bHasFinishedEvent == true or rec.bHasVehicleWrecked == true or rec.bHasBeenEliminated == true then return nil end
    return math.floor(tonumber(rec.EventPosition) or 0)
end
local function worstFirst(a, b) return a > b end

-- #81 (playtest 2026-10-18 08:41, Jakku ELIMINATOR, recording: P2 "01 POS /3", lap 8/8 at 10:40:43-55): a human who
-- WRECKS in an elimination race leaves it at his standing, exactly like an elimination: his place = 1 + the racers not
-- out yet (still racing or home; eliminated = bHasBeenEliminated / bHasTimedOut, and the wrecked, are behind him).
-- The game's REC reads EventPosition 12 (the DNF row) for him at the race end. recs = every racer's REC.
local function outFlag(rec, name)
    local ok, v = pcall(U.getField, rec, name)
    return ok and v == true
end
function M.standingAt(rec, recs)
    local k, n = U.key(rec), 0
    for i = 1, #(recs or {}) do
        local r = recs[i]
        if U.ok(r) and U.key(r) ~= k and not (outFlag(r, "bHasBeenEliminated") or outFlag(r, "bHasTimedOut")
            or outFlag(r, "bHasVehicleWrecked")) then
            n = n + 1
        end
    end
    return n + 1
end

-- the last CouchRiskBand places among the racers still racing (AI included)
local function markRisk(humans)
    local band = math.max(1, math.floor(tonumber(opt("CouchRiskBand", 1)) or 1))
    local worst = {}
    local recs = riskRecs()
    for i = 1, #recs do
        local rec = recs[i]
        if U.ok(rec) then
            local ok, pos = pcall(stillPos, rec)
            if ok and pos then worst[#worst + 1] = pos end
        end
    end
    table.sort(worst, worstFirst)
    local cut = worst[math.min(band, #worst)] or 1e9
    for _, h in ipairs(humans) do h.atRisk = h.racing and h.pos >= cut end
end

---------------------------------------------------------------------------------------------------- race state
-- R: the couch race being ruled (nil outside RACING of a couch campaign race); declared above riskRecs
R = nil
M.last = nil              -- the last ruled race: {kind, activity, carrier, sitOut = {[ctrlId]=true}, booked}
local sitOut = {}         -- [ctrlId] = true: guests without a grid entry this race (race_enter)

-- couch-fix33 (racegc): runs every FAST tick - plain field reads (no closure per field), and an unreadable node is
-- looked up again at most once per NODE_RETRY_MS (each GetCurrentNode / mPlayerPath try made UE4SS wrappers)
local NODE_RETRY_MS = 1000
local function snapLedger(run, planet)
    local s = {}
    local get = U.getField
    local ok, v = pcall(get, run, "Strikes")
    if ok then s.strikes = math.floor(tonumber(v) or 0) end
    ok, v = pcall(get, run, "mStrikeChangesForDisplay")
    if ok then s.disp = U.arrayCount(v) end
    ok, v = pcall(get, planet, "RaceResults")
    if ok then s.rr = U.arrayCount(v) end
    -- the race's node is fixed for the race: GetCurrentNode once per ruled race, not every FAST tick (couch-racefast)
    local nd = nil
    local mine = R and R.run == run
    if mine and R.node ~= nil and U.ok(R.node) then nd = R.node
    elseif mine and R.node == nil and R.nodeTryAt and St.nowMs() - R.nodeTryAt < NODE_RETRY_MS then
        nd = nil
    else
        nd = currentNode(run)
        if mine then R.node = nd; R.nodeTryAt = St.nowMs() end
    end
    if nd then
        ok, v = pcall(get, nd, "bEarnedRewards")
        if ok then s.earned = v == true end
    end
    return s
end

-- #99: the run's lock, read only at the race start and when a strike lands (snapLedger runs every FAST tick: no
-- garbage budget for it); the ledger carries it between strikes
local function readLock(run)
    local okL, lk = pcall(U.getField, run, "bRunLocked")
    return okL and lk == true
end

local function setGate(open, why)
    if not R or not R.gate then return end
    local want = not open                                         -- the flag CLOSES the gate
    if R.gateClosed == want then return end
    local ok = pcall(function() R.run.bHasJustCompletedPlaneTest = want end)
    if ok then
        R.gateClosed = want
        if want then M.setGateMarker(true, why) end                -- a race-end save may hold the flag now
        -- couch-fix34: the run's credits before the team test's one booking (its credits are repaired: teamTestRepair)
        -- couch-fix35 (Q1): every opening (not only a team test's): P1's own-place economy measures the booking's
        -- credits from here when the node's FinishCreditsAwarded is unreadable (one read per gate flip)
        if not want then                                 -- (fix34 / fix38: team tests, boss races too)
            local okC, cr = pcall(U.getField, R.run, "Credits")
            R.openCr = okC and tonumber(cr) or nil
        end
        U.log(TAG, "result gate %s (%s)", open and "OPEN" or "closed", tostring(why))
    end
end

local function restoreGate(why)
    if not R or not R.gate then return end
    pcall(function() R.run.bHasJustCompletedPlaneTest = R.gateOrig end)
    R.gateClosed = R.gateOrig
    R.gate = false
    U.log(TAG, "result gate released: plane-test flag back to %s (%s)", tostring(R.gateOrig), tostring(why))
end

local function begin()
    local run = campaignRun()
    if not run then return end
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if not (okC and couch == true) then return end
    local act = activityNow(run)
    local humans = humanList()
    local guests = 0
    for _, h in ipairs(humans) do if not h.isP1 then guests = guests + 1 end end
    R = { run = run, activity = act, kind = M.kindOf(act), rule = M.rule(), humans = {}, booked = nil,
          plane = planeTestActive(run), planeWon = {}, refunds = {}, guests = guests }
    if R.plane and R.kind == "standard" then R.kind = "planesprint" end   -- #30: the planet's plane test (no node)
    R.planet = lastPlanet(run)
    for _, h in ipairs(humans) do R.humans[#R.humans + 1] = readRec(h) end
    R.outSeq = 0
    -- couch-fieldtest: a race-alone event (couchsolo.lua: each player his own test, his own limit / result screens)
    pcall(function()
        local solo = U.mod("couchsolo")
        R.alone = solo.raceAlone() == true
        if R.alone then R.aloneKind, R.limit, R.target = solo.info().kind, solo.limit(), solo.target() end
    end)
    R.teamTest = guests > 0 and M.teamTest(R.rule, R.kind, R.alone)
    -- couch-fix38 (D8): a boss race raced as one copy per player (instances.lua plan kind "boss", built at the pick)
    -- couch-fix57: a standard / high-risk head-to-head raced the same way (plan h2h: each player vs his own rival copy)
    R.bossH2H = guests > 0 and M.bossInstanceRace() and M.bossH2HRace()
    R.boss = guests > 0 and (R.kind == "champion" or R.bossH2H) and M.bossInstanceRace()
    -- couch-fix58 (D5): a rival challenge raced by 2+ players (couchrules.rivalPlace): ONE native challenge result
    -- (the first player out), the team's rule on it at the end (M.rivalResolve); rival instances = each his own rival
    R.rival = guests > 0 and isRivalRace(run) and opt("CouchRivalRaces", true) == true
    R.rivalInst = R.rival and M.rivalInstanceRace()
    if R.rival then
        local okM, mx = pcall(U.getField, run, "EarnedMaxStrikes")
        R.maxStrikes0 = okM and tonumber(mx) or nil
    end
    local orig = false
    pcall(function() orig = run.bHasJustCompletedPlaneTest == true end)
    R.gateOrig = orig
    R.gate = guests > 0 and opt("CouchIngestGate", true) ~= false and not R.plane and not isRivalRace(run) and not orig
    R.gateManaged = R.gate                     -- couch-fix35: the gate ruled this race (restoreGate clears R.gate)
    R.gateClosed = orig
    R.prev = snapLedger(run, R.planet)
    R.prev.locked = readLock(run)
    R.prev.maxS = R.maxStrikes0                 -- couch-fix58: a rival race's strike ledger (a win at 0 strikes)
    -- couch-fix30: the run's strike protectors' last planet (StrikeProtector.ProtectUntil.PlanetNum, best effort): an
    -- owed protector (a refunded strike used one up) lasts as long as the one it replaces
    pcall(function()
        local arr = run.StrikeProtectors
        for i = 1, U.arrayCount(arr) do
            local u = tonumber(arr[i].ProtectUntil.PlanetNum)
            if u and (not R.protUntil or u > R.protUntil) then R.protUntil = u end
        end
    end)
    if R.plane then M.setGateMarker(false, "plane test: its flag is native") end
    U.log(TAG, "couch race: %s (activity %s), rule %s, %d human(s) racing, gate %s%s%s%s", R.kind, tostring(act), R.rule,
        #R.humans, R.gate and "managed" or "off", orig and " (plane-test flag already set: native left alone)" or "",
        R.teamTest and "; TEAM TEST (failed only if every player fails: booked once everyone is done)" or
            (R.rival and (R.rivalInst and "; RIVAL INSTANCES (each player races his own copy of the rival: the challenge "
                .. "is won if any of them wins)" or "; SHARED RIVAL RACE (every player vs the rival: the challenge is won "
                .. "if any of them beats it)")) or
            (R.bossH2H and "; HEAD-TO-HEAD INSTANCES (each player races his own rival: the team result is the best of "
                .. "them)" or (R.boss and "; BOSS INSTANCES (each player races his own boss: the act is won if any of "
                .. "them wins)" or "")),
        R.alone and string.format("; race-alone %s, own time limit %s, target %s", tostring(R.aloneKind),
            R.limit and string.format("%.2f s", R.limit) or "none",
            R.target and string.format("%.2f s", R.target) or "none") or "")
end

local function humanByKey(k)
    for _, h in ipairs(R.humans) do if U.key(h.ps) == k then return h end end
end

-- the refund of the strike(s) taken since the previous tick
local function refund(now, who, what, why)
    local run = R.run
    local p = R.prev
    local d = (now.strikes or 0) - (p.strikes or 0)
    pcall(function() if d > 0 then run.Strikes = p.strikes end end)
    local entries = {}
    pcall(function()
        local arr = run.mStrikeChangesForDisplay
        for i = (p.disp or 0) + 1, U.arrayCount(arr) do
            local e = arr[i]
            entries[#entries + 1] = { i = i, delta = tonumber(e.Delta) or 0, prot = tonumber(e.NumProtected) or 0 }
            e.Delta = 0
            e.bSeen = true
        end
    end)
    -- the node's rewards flag is the TEAM's while the race runs (later bookings, the guests' offers read it): back now.
    -- couch-fix30 (audit 12 #8 / Q2, cfg.CouchWreckRefundRewards false = solo rule): P1's OWN refunded wreck still costs
    -- HIM his reward round - taken just before the race end generates it (M.stripP1Round), like a wrecked guest's
    if what == "wreck" and p.earned == true and now.earned == false then
        pcall(function() currentNode(run).bEarnedRewards = true end)
    end
    if what == "wreck" and who.isP1 and opt("CouchWreckRefundRewards", false) ~= true then R.p1RoundLost = true end
    if what == "wreck" then
        pcall(function()
            local rr = R.planet.RaceResults
            for i = (p.rr or 0) + 1, U.arrayCount(rr) do rr[i].bShowInRecaps = false end
        end)
    end
    local prot = 0
    for _, e in ipairs(entries) do prot = prot + e.prot end
    R.refunds[#R.refunds + 1] = { who = who.pnum, what = what, strikes = d, entries = entries }
    if what == "wreck" then who.wreckRefunded = true end                -- #81: the team keeps its token
    -- couch-fix30 (audit 12 #8): a strike protector (P1's native Second Chance) that absorbed the refunded strike is
    -- owed back: the next strike that STANDS in a couch race this run is protected in its place (M.owedProtect)
    if prot > 0 then M.oweProtector(prot, R.protUntil) end
    U.log(TAG, "P%s %s: %d strike(s) refunded (%s)%s", tostring(who.pnum), what, d, why,
        prot > 0 and string.format("; %d strike protector(s) used up by it: owed back to the team", prot) or "")
    if d > 0 then M.unlockAfterRefund(run, p, string.format("P%s %s refund", tostring(who.pnum), what)) end
end

-- #110 SECOND CHANCE (a team favour: couchfavours.secondChance decides, any player's pick, P1's own native protector
-- first): one strike that STANDS in a couch race on the first 2 / 3 / 4 planets is protected the way the game's
-- StrikeProtector does it - Strikes back by one, the display entry Delta - 1 / NumProtected + 1. -> true when protected
-- the display entries of the strikes since the previous tick -> entries, protected count
local function newEntries()
    local p = R.prev
    local entries, prot = {}, 0
    pcall(function()
        local arr = R.run.mStrikeChangesForDisplay
        for i = (p.disp or 0) + 1, U.arrayCount(arr) do
            local e = arr[i]
            entries[#entries + 1] = { i = i, delta = tonumber(e.Delta) or 0, prot = tonumber(e.NumProtected) or 0 }
            prot = prot + (tonumber(e.NumProtected) or 0)
        end
    end)
    return entries, prot
end

-- protect ONE standing strike the native way (Strikes back by one, the last display entry Delta - 1 / NumProtected + 1)
local function protectOne(now, entries, who, label)
    local okW = pcall(function() R.run.Strikes = (now.strikes or 0) - 1 end)
    local last = entries[#entries]
    if last then
        pcall(function()
            local e = R.run.mStrikeChangesForDisplay[last.i]
            e.Delta = math.max(0, last.delta - 1)
            e.NumProtected = last.prot + 1
        end)
    end
    U.log(TAG, "P%s: %s - a League Token protected (strikes %s -> %s%s)", tostring(who and who.pnum or "-"), label,
        tostring(now.strikes), tostring((now.strikes or 0) - 1), okW and "" or ", WRITE FAILED")
    -- #99 + couch-fix30: the strike it takes back may have reached the limit and locked the run natively - cleared
    -- only when the protection really stands (Strikes written back below the limit, the lock not there before)
    if okW then M.unlockAfterRefund(R.run, R.prev, string.format("P%s %s", tostring(who and who.pnum or "-"), label)) end
    return okW
end

local function planetNum()
    local planet = 99
    pcall(function() planet = math.max(1, U.arrayCount(R.run.VisitedPlanets)) end)
    return planet
end

-- couch-fix30 (audit 12 #8): strike protectors owed to the team - a native protector (P1's own Second Chance) that a
-- REFUNDED strike used up. Kept in the run's team state (couchrun.teamState: one per run id), else in memory.
-- {n, upto = the last planet number it protects (the consumed protector's ProtectUntil.PlanetNum when readable)}
M._owedMem = nil
local function owedStore()
    local ok, t = pcall(function() return U.mod("couchrun").teamState() end)
    if ok and type(t) == "table" then return t, true end
    M._owedMem = M._owedMem or {}
    return M._owedMem, false
end
function M.owedProtect()
    local t = owedStore()
    local o = type(t.owedProtect) == "table" and t.owedProtect or nil
    return (o and (tonumber(o.n) or 0) > 0) and o or nil
end
function M.oweProtector(n, untilPlanet)
    local t, persisted = owedStore()
    local o = type(t.owedProtect) == "table" and t.owedProtect or { n = 0 }
    o.n = (tonumber(o.n) or 0) + math.max(1, math.floor(tonumber(n) or 1))
    local u = tonumber(untilPlanet)
    if u and (not o.upto or u > o.upto) then o.upto = u end
    if not o.at and R and U.ok(R.run) then o.at = planetNum() end
    t.owedProtect = o
    if persisted then pcall(function() U.mod("couchrun").saveTeam() end) end
    U.log(TAG, "strike protector owed to the team (%d, until planet %s): it absorbed a strike that was refunded", o.n,
        tostring(o.upto or "this one"))
end
-- a standing strike on this planet: an owed protector takes it -> true when protected
local function owedProtector(now, entries, who, d)
    if d <= 0 then return false end
    local t, persisted = owedStore()
    local o = type(t.owedProtect) == "table" and t.owedProtect or nil
    if not (o and (tonumber(o.n) or 0) > 0) then return false end
    local planet = planetNum()
    o.at = o.at or planet                                            -- an unreadable ProtectUntil: that planet only
    if planet > (tonumber(o.upto) or o.at) then
        U.log(TAG, "owed strike protector expired (planet %d > %s)", planet, tostring(o.upto or o.at))
        t.owedProtect = nil
        if persisted then pcall(function() U.mod("couchrun").saveTeam() end) end
        return false
    end
    o.n = o.n - 1
    if o.n <= 0 then t.owedProtect = nil end
    if persisted then pcall(function() U.mod("couchrun").saveTeam() end) end
    return protectOne(now, entries, who, "OWED STRIKE PROTECTOR (used up by a refunded strike)")
end

local function secondChance(now, who)
    local p = R.prev
    local d = (now.strikes or 0) - (p.strikes or 0)
    local entries, prot = newEntries()
    if d <= 0 and prot == 0 then return false end
    if owedProtector(now, entries, who, d) then return true end
    local okF, F = pcall(U.mod, "couchfavours")
    if not (okF and type(F) == "table") then return false end
    local planet = planetNum()
    local yes = false
    local okS, errS = pcall(function() yes = F.secondChance(entries, planet, R.run) == true end)
    if not okS then U.warn(TAG, "Second Chance check failed: %s", tostring(errS)) end
    if not yes or d <= 0 then return false end
    return protectOne(now, entries, who, "SECOND CHANCE")
end
M._secondChance = function(now, who) return secondChance(now, who) end

local function instancesOn()
    local on = false
    pcall(function() on = U.mod("instances").active() == true end)
    return on
end

-- couch-fix58 (D5): THE RIVAL CHALLENGE'S ONE RESULT. Static (CL381121): CampaignRun::OnEventFinished (0x1430ddd0a)
-- takes the rival path BEFORE the core gate (N3): bIsPlayingRivalChallengeEvent -> the strike change 0x1430dd8de
-- (+1 lost / -1 won: a strike back, at 0 strikes EarnedMaxStrikes + 1; protectors natively) for EVERY human finish, then
-- the challenge outcome 0x1430dbd36 ONCE (bHasCompletedRivalChallenge guard): bPlayerWonRivalChallenge = (his
-- EventPosition == 1), a win unlocks ActiveRivalry.UnlockedOnWin (favour, palette, livery; bPlayerJustUnlockedFavour).
-- The wreck hook (0x1430dd5a6) takes the same path: a strike + a LOST outcome. No credits, no reward round natively
-- (IsPlayingCoreEvent is false in a rival challenge). So with 2+ players: the FIRST player out decides the game's
-- challenge (his finish / wreck, as solo); every later player's strike change is taken back (one challenge, one
-- result); when every player is out the team's rule ("best": any player beat his rival - instances: his own copy,
-- shared: crossed before it) is compared with the game's: a team win the game booked as lost (the first player out lost,
-- a later one won his own) is repaired - the loss's strike back (a protector it used owed), the win's strike back,
-- bPlayerWonRivalChallenge, the rivalry's UnlockedOnWin tags (couchmeta's SPUnlockSubsystem path). A loss stands
-- (one strike, Second Chance / an owed protector may take it as for any standing strike).
local function readMax()
    local okM, mx = pcall(U.getField, R.run, "EarnedMaxStrikes")
    return okM and tonumber(mx) or nil
end
-- every strike change since base taken back (Strikes, EarnedMaxStrikes, the display entries; a protector it used owed)
local function rivalRevert(now, base, who, why)
    local run = R.run
    local d = (now.strikes or 0) - (base.strikes or 0)
    local okS = true
    if d ~= 0 then okS = pcall(function() run.Strikes = base.strikes end) end
    local mx, dm = readMax(), 0
    if mx and base.maxS and mx ~= base.maxS then
        dm = mx - base.maxS
        pcall(function() run.EarnedMaxStrikes = base.maxS end)
    end
    local prot, ne = 0, 0
    pcall(function()
        local arr = run.mStrikeChangesForDisplay
        for i = (base.disp or 0) + 1, U.arrayCount(arr) do
            local e = arr[i]
            prot = prot + (tonumber(e.NumProtected) or 0)
            if (tonumber(e.Delta) or 0) ~= 0 or e.bSeen ~= true then
                e.Delta = 0
                e.bSeen = true
                ne = ne + 1
            end
        end
    end)
    R.refunds[#R.refunds + 1] = { who = who and who.pnum, what = "rival", strikes = d, entries = {} }
    if prot > 0 then M.oweProtector(prot, R.protUntil) end
    U.log(TAG, "P%s rival challenge: strike change %+d%s taken back (%s)%s%s", tostring(who and who.pnum or "-"), d,
        dm ~= 0 and string.format(", max strikes %+d", dm) or "", tostring(why), okS and "" or " - WRITE FAILED",
        prot > 0 and string.format("; %d strike protector(s) it used owed back", prot) or "")
    if d > 0 then M.unlockAfterRefund(run, base, string.format("P%s rival refund", tostring(who and who.pnum or "-"))) end
    return d
end

local function rivalLedger(newWreck, newDone)
    local now = snapLedger(R.run, R.planet)
    local p = R.prev
    now.locked, now.maxS = p.locked, p.maxS
    local struck = (now.strikes or 0) ~= (p.strikes or 0) or (now.disp or 0) > (p.disp or 0)
    if struck then
        local first = R.rivalFirst
        local events = #newWreck + #newDone
        local who = newDone[1] or newWreck[1]
        if first and (first.tick == R.tickN or (first.after == nil and events == 0)) then
            first.after = now
            now.maxS = readMax()
            first.after.maxS = now.maxS
            if events > 1 then
                U.warn(TAG, "rival challenge: %d players out in one tick - the game booked them in its own order (the "
                    .. "first of them decided the challenge): strike change %+d left as it is", events,
                    (now.strikes or 0) - (p.strikes or 0))
            end
            U.log(TAG, "rival challenge: P%s's %s decides the game's challenge (global place %s): strike change %+d kept "
                .. "for now - the team's result is ruled once every player is out", tostring(first.who.pnum),
                first.wreck and "wreck" or "finish", tostring(first.pos), (now.strikes or 0) - (p.strikes or 0))
        else
            rivalRevert(now, p, who, "one challenge result per team: the first player out's")
        end
        now = snapLedger(R.run, R.planet)
        now.locked = readLock(R.run)
        now.maxS = readMax() or p.maxS
    end
    R.prev = now
end

-- the rivalry's win unlocks (CampaignRivalryDef.UnlockedOnWin) -> list of tag names
local function rivalWinTags(run)
    local out = {}
    pcall(function()
        local tags = run.ActiveRivalry.UnlockedOnWin.GameplayTags
        for i = 1, U.arrayCount(tags) do
            local nm = U.str(tags[i].TagName)
            if nm ~= "" and nm ~= "None" then out[#out + 1] = nm end
        end
    end)
    return out
end
M._rivalWinTags = rivalWinTags

-- the team won a challenge the game booked as lost: the repair (the frame of the last player out, before the race end)
local function rivalRepairWin(first, carrier)
    local base = first.before
    local now = snapLedger(R.run, R.planet)
    local notes = {}
    rivalRevert(now, base, first.who, string.format("P%d beat his rival: the team won the challenge", carrier.pnum))
    -- the win's own strike change: a strike back (at 0 strikes: one more League Token, EarnedMaxStrikes + 1)
    local s0 = math.floor(tonumber(base.strikes) or 0)
    if s0 > 0 then
        local okW = pcall(function() R.run.Strikes = s0 - 1 end)
        notes[#notes + 1] = string.format("strikes %d -> %d%s", s0, s0 - 1, okW and "" or " (FAILED)")
    else
        local mx = readMax() or base.maxS or 0
        local okW = pcall(function() R.run.EarnedMaxStrikes = mx + 1 end)
        notes[#notes + 1] = string.format("max strikes %d -> %d%s", mx, mx + 1, okW and "" or " (FAILED)")
    end
    M.unlockAfterRefund(R.run, base, "rival challenge won by the team")
    local okF = pcall(function()
        R.run.bHasCompletedRivalChallenge = true
        R.run.bPlayerWonRivalChallenge = true
    end)
    notes[#notes + 1] = "bPlayerWonRivalChallenge true" .. (okF and "" or " (FAILED)")
    -- the rivalry's win unlocks (the native win branch's UnlockedOnWin): P1's account
    local okMM, MM = pcall(U.mod, "couchmeta")
    local done, favour = {}, false
    for _, tag in ipairs(rivalWinTags(R.run)) do
        local had = nil
        if okMM and type(MM) == "table" and MM.io then
            pcall(function() had = MM.io.unlocked(tag) end)
            if had ~= true then
                local okU, r = pcall(MM.io.unlock, tag)
                done[#done + 1] = tag .. ((okU and r ~= false) and "" or " (FAILED)")
                if okU and r ~= false and tag:find("^Unlock%.Cam%.Favours%.") then favour = true end
            end
        end
    end
    if favour then pcall(function() R.run.bPlayerJustUnlockedFavour = true end) end
    notes[#notes + 1] = #done > 0 and ("unlocked " .. table.concat(done, ", ")) or "no new win unlock"
    R.prev = snapLedger(R.run, R.planet)
    R.prev.locked, R.prev.maxS = readLock(R.run), readMax()
    U.log(TAG, "rival challenge WON for the team: P%d beat his %s (place %s) - the game booked P%d's %s (global place "
        .. "%s) as lost: repaired; %s", carrier.pnum, R.rivalInst and "own copy of the rival" or "rival",
        tostring(carrier.setPos or (carrier.snap and carrier.snap.pos)), first.who.pnum,
        first.wreck and "wreck" or "finish", tostring(first.pos), table.concat(notes, "; "))
end

-- a standing loss: Second Chance / an owed protector, on the first player's own strike entries
local function rivalStandingLoss(first)
    local a, b = first.before, first.after
    if not (a and b) or (b.strikes or 0) <= (a.strikes or 0) then return end
    local entries = {}
    pcall(function()
        local arr = R.run.mStrikeChangesForDisplay
        for i = (a.disp or 0) + 1, math.min(b.disp or 0, U.arrayCount(arr)) do
            local e = arr[i]
            entries[#entries + 1] = { i = i, delta = tonumber(e.Delta) or 0, prot = tonumber(e.NumProtected) or 0 }
        end
    end)
    local saved = R.prev
    R.prev = a
    local now = snapLedger(R.run, R.planet)
    local d = (now.strikes or 0) - (a.strikes or 0)
    local done = owedProtector(now, entries, first.who, d)
    if not done and d > 0 then
        local okF, F = pcall(U.mod, "couchfavours")
        local yes = false
        if okF and type(F) == "table" then pcall(function() yes = F.secondChance(entries, planetNum(), R.run) == true end) end
        if yes then protectOne(now, entries, first.who, "SECOND CHANCE") end
    end
    R.prev = saved
    R.prev = snapLedger(R.run, R.planet)
    R.prev.locked, R.prev.maxS = readLock(R.run), readMax()
end

function M.rivalResolve(why)
    if not (R and R.rival) or R.rivalResult then return end
    local first = R.rivalFirst
    local carrier = nil
    for _, h in ipairs(R.humans) do
        local w = false
        if R.rivalInst then w = h.bossWon == true
        else
            local s = h.snap
            w = type(s) == "table" and s.fin == true and not s.wrecked and math.floor(tonumber(s.pos) or 99) == 1
        end
        if w and (R.rule ~= "p1" or h.isP1) and (not carrier or (h.outAt or 99) < (carrier.outAt or 99)) then carrier = h end
    end
    local won = carrier ~= nil
    local native = nil
    pcall(function() native = R.run.bPlayerWonRivalChallenge == true end)
    if native == nil then native = first ~= nil and not first.wreck and first.pos == 1 end
    R.rivalResult = { won = won, carrier = carrier and carrier.pnum or nil, native = native,
                      first = first and first.who.pnum or nil }
    R.teamCarrier = carrier or (first and first.who) or nil
    if won and not native and first then
        rivalRepairWin(first, carrier)
        return
    end
    if native and not won then
        U.warn(TAG, "rival challenge: the game booked a WIN (P%s's finish) the %s rule does not count - left native "
            .. "(its unlocks are given) (%s)", tostring(first and first.who.pnum), R.rule, tostring(why))
        R.rivalResult.won = true
        return
    end
    if not won and first then rivalStandingLoss(first) end
    U.log(TAG, "rival challenge %s for the team: %s - the game's result (P%s's %s) stands (%s)", won and "WON" or "LOST",
        won and string.format("P%d beat his %s", carrier.pnum, R.rivalInst and "own copy of the rival" or "rival")
            or ("nobody beat his " .. (R.rivalInst and "own copy of the rival" or "rival")),
        tostring(first and first.who.pnum or "-"), first and (first.wreck and "wreck" or "finish") or "-", tostring(why))
end

local function ledgerStep(newWreck, newDone)
    if R.rival then return rivalLedger(newWreck, newDone) end            -- couch-fix58 (D5)
    local now = snapLedger(R.run, R.planet)
    local p = R.prev
    local struck = (now.strikes or 0) > (p.strikes or 0) or (now.disp or 0) > (p.disp or 0)
    now.locked = p.locked
    if struck then
        local ev = nil
        if #newWreck == 1 and #newDone == 0 then
            ev = { what = "wreck", who = newWreck[1] }
        elseif #newWreck == 0 and #newDone == 1 and R.plane then
            ev = { what = "planefail", who = newDone[1] }
        elseif #newWreck == 0 and #newDone > 1 and R.plane and instancesOn() then
            -- couch-trial2: two instances finishing in one tick (separate races: no photo finish needed)
            ev = { what = "planefail", who = newDone[#newDone] }
        end
        if ev then
            ev.humans, ev.rule = R.humans, R.rule
            for _, w in pairs(R.planeWon) do if w then ev.teamWon = true end end
            local yes, why = M.refundable(ev)
            if yes then refund(now, ev.who, ev.what, why)
            else
                U.log(TAG, "P%s %s: strike kept (%s)", tostring(ev.who.pnum), ev.what, why)
                secondChance(now, ev.who)                            -- #110 the team's Second Chance
                -- couch-rewards2: a GUEST's kept wreck token never takes P1's reward round (N2 clears the run's
                -- node.bEarnedRewards for any human's wreck; solo P1 loses it only to his own wreck)
                -- couch-fix30: nor does it give back a round P1's OWN result lost (eliminated: solo = a token, no round)
                local p1Wrecked, p1Elim = false, false
                for _, h in ipairs(R.humans) do
                    if h.isP1 and h.wrecked then p1Wrecked = true end
                    if h.isP1 and h.elim then p1Elim = true end
                end
                if ev.what == "wreck" and not ev.who.isP1 and not p1Wrecked and not p1Elim and p.earned == true
                    and now.earned == false then
                    local okE = pcall(function() currentNode(R.run).bEarnedRewards = true end)
                    U.log(TAG, "P%s's wreck: P1's reward round kept (node rewards back %s)", tostring(ev.who.pnum),
                        okE and "ok" or "FAILED")
                end
            end
        elseif #newWreck == 0 and #newDone > 0 then
            U.log(TAG, "booked result struck (native: eliminator target / must-win), strikes %s -> %s",
                tostring(p.strikes), tostring(now.strikes))
            secondChance(now, newDone[1])                            -- #110 the team's Second Chance
        elseif #newWreck + #newDone > 0 then
            U.warn(TAG, "strike change with %d wreck(s) + %d finish(es) in one tick: left native", #newWreck, #newDone)
        end
        now = snapLedger(R.run, R.planet)
        now.locked = readLock(R.run)
    end
    R.prev = now
end

-- #68 (tester #3, Lantaana RAMJET test, both FAILED 8489 / 10546 of 11900 m): P2 home first was booked as the team
-- result with place 1 and NO fail bit - the game's ramjet / takedown rules fail their ONE tracked player (P1) only -
-- so the run paid P1 "Finished 1st" 1,250 and gave the team its rewards. In a takedowns / ramjet test raced by several
-- players a guest who has not reached his OWN target carries the target-missed bits on his REC while he races (the
-- ingestion ORs its own bits into FailReasons, N1): booked, his result is the failure it is. Cleared the tick he
-- reaches it. P1's REC is the game's own (tracked).
local PRE_FAIL = 2 + 8                                  -- FailReasons ModeRules | ExtraConditions (target missed)
-- soloscore at a player's target, BEFORE it finishes him (Server_Cheat_FinishRace ingests him in that same call)
function M.clearPreFail(ps)
    if not (R and U.ok(ps)) then return false end
    for _, h in ipairs(R.humans) do
        if h.preFail and U.ok(h.ps) and U.key(h.ps) == U.key(ps) and U.ok(h.rec) then
            local f = math.floor(tonumber(h.fail) or 0)
            local ok = pcall(function()
                f = math.floor(tonumber(h.rec.FailReasons) or f)
                h.rec.FailReasons = f & ~PRE_FAIL
            end)
            if ok then
                h.preFail, h.fail = nil, f & ~PRE_FAIL
                U.log(TAG, "P%s reached his own target: the target-missed bits cleared before his finish", tostring(h.pnum))
            end
            return ok
        end
    end
    return false
end
local function preFailGuests()
    if not (R and R.alone and (R.aloneKind == "takedowns" or R.aloneKind == "ramjet")) then return end
    local ss = package.loaded["soloscore"]
    if type(ss) ~= "table" or type(ss.scoreOf) ~= "function" then return end
    for _, h in ipairs(R.humans) do
        if not h.isP1 and h.racing and U.ok(h.rec) then
            local okS, sc = pcall(ss.scoreOf, h.ps)
            if okS and type(sc) == "table" then
                local f = math.floor(tonumber(h.fail) or 0)
                if not sc.reached and (f & PRE_FAIL) ~= PRE_FAIL then
                    if pcall(function() h.rec.FailReasons = f | PRE_FAIL end) then
                        h.fail = f | PRE_FAIL
                        if not h.preFail then
                            h.preFail = true
                            U.log(TAG, "P%s races his own %s test below its target: his result carries the target-missed "
                                .. "bits until he reaches it (#68: booked, it is a failure)", tostring(h.pnum), R.aloneKind)
                        end
                    end
                elseif sc.reached and h.preFail then
                    h.preFail = nil
                    if pcall(function() h.rec.FailReasons = f & ~PRE_FAIL end) then
                        h.fail = f & ~PRE_FAIL
                        U.log(TAG, "P%s reached his own target (%s): the target-missed bits cleared", tostring(h.pnum),
                            tostring(sc.text))
                    end
                end
            end
        end
    end
end

local function teamEarned()
    if not R then return nil end
    if R.teamEarnedKept ~= nil then return R.teamEarnedKept end      -- P1's round taken for his own wreck (fix30)
    local nd = currentNode(R.run)
    local e = nil
    if nd then pcall(function() e = nd.bEarnedRewards == true end) end
    return e
end
M.teamEarned = function()
    if R and R.teamEarnedKept ~= nil then return R.teamEarnedKept end
    if not R and M.last and M.last.gen == St.worldGen and M.last.teamEarnedKept ~= nil then return M.last.teamEarnedKept end
    local run = campaignRun()
    local nd = run and currentNode(run)
    local e = nil
    if nd then pcall(function() e = nd.bEarnedRewards == true end) end
    return e
end

local repairDouble
local teamTestResolve
local ownEconomy
-- the final-event swap wanted now? -> carrier, p1 (nil = no swap)
-- couch-fix30 (audit 12 #5, BLOCKER part): a WRECKED P1 is swapped too. Before, the swap returned for him: his REC kept
-- the DNF (his wreck refunded under "all"), DidLocalPlayerWin read it, no act-finish flow started - the run neither
-- advanced nor failed although a guest won. The team rule "best": a guest's win completes the act.
local function finalSwapWanted()
    if not R or opt("CouchFinalWinSwap", true) ~= true or R.rule ~= "best" or not R.booked or R.booked.isP1 then return nil end
    -- couch-fix38 (D8): boss instances write the team's result into P1's REC (bossRepair), a guest's REC stays his own
    if R.boss then return nil end
    local c, p1 = R.booked, nil
    for _, h in ipairs(R.humans) do if h.isP1 then p1 = h end end
    if not p1 or c.pos ~= 1 or c.wrecked or (p1.pos == 1 and not p1.wrecked) then return nil end
    -- the run's final event, and every act-finishing event (championship qualifier, gauntlet): their result screen
    -- reads P1's REC alone (N4), so a guest's win showed "QUALIFIER LOST" with P1 2nd (live 2026-10-14)
    local final = R.kind == "champion" or R.kind == "knockout"
    if not final and U.ok(R.run) then pcall(function() final = R.run:IsPlayingFinalEventOfRun() == true end) end
    if not final then return nil end
    return c, p1
end
local function finalSwap()
    local c, p1 = finalSwapWanted()
    if not c then return end
    if not (U.ok(p1.rec) and U.ok(c.rec)) then
        U.warn(TAG, "final event of the run won by P%s: no swap (a REC is gone)", tostring(c.pnum))
        return
    end
    -- couch-fix30 (audit 12 #5): each human's REAL result, before the swap - couchrun's payout / reward flow, couchbets'
    -- settlement and the backer rating read it (M.realResult): the winning guest is paid at HIS 1st, not P1's place
    R.real = R.real or {}
    for _, h in ipairs({ p1, c }) do
        local r = { pos = h.pos, wrecked = h.wrecked == true, fail = h.fail or 0, ctrlId = h.ctrlId, pnum = h.pnum }
        R.real[U.key(h.ps)] = r
    end
    local ok = pcall(function()
        local a, b = p1.rec, c.rec
        local ap, bp = a.EventPosition, b.EventPosition
        a.EventPosition, b.EventPosition = bp, ap
        local af, bf = a.FailReasons, b.FailReasons
        a.FailReasons, b.FailReasons = bf, af
    end)
    U.log(TAG, "final event of the run won by P%s: places swapped with P1%s (DidLocalPlayerWin) %s - every player is "
        .. "paid / rewarded / settled at his own place (P%s 1st, P1 %s)", tostring(c.pnum),
        p1.wrecked and " (P1 wrecked: the team's win still completes the act)" or "", ok and "ok" or "FAILED",
        tostring(c.pnum), p1.wrecked and "wrecked" or ("P" .. tostring(p1.pos)))
    if not ok then R.real = nil end
end

-- couch-fix30 (audit 12 #8 / Q2, the solo rule): P1's refunded wreck costs HIM his round - node.bEarnedRewards false
-- right before the race end generates his rounds (the FinishRacer hook of the last human out; the FAST-tick fallback
-- after). The team's value is kept for the guests' offers (M.teamEarned). Not on a final event a guest won for the
-- team (finalSwap writes the team's win into P1's REC: the act-finish flow is the team's, left whole).
local function stripP1Round(why)
    if not R or not R.p1RoundLost or R.p1RoundStripped then return end
    R.p1RoundStripped = true
    if finalSwapWanted() or (R.boss and R.bossResult and R.bossResult.won and not R.bossResult.p1Won) then
        U.log(TAG, "P1's refunded wreck: his reward round kept - a guest won the final event for the team (%s)", why)
        return
    end
    local nd = R.node or currentNode(R.run)
    local cur = nil
    if nd then pcall(function() cur = nd.bEarnedRewards == true end) end
    R.teamEarnedKept = cur
    if cur == true and pcall(function() nd.bEarnedRewards = false end) then
        U.log(TAG, "P1's wreck (token refunded): no reward round for him - the solo rule, like a wrecked guest "
            .. "(cfg.CouchWreckRefundRewards false; %s)", why)
    end
end

-- couch-fix34 (audit 12 issue 4, Jules's Q5): THE TEAM TEST. The gate holds the booking until the last player is out
-- (M.gateWanted); the game books him alone. Every player's own verdict = couchsolo.verdict of his result snapshot.
--   * the booking failed natively (a strike, node.bEarnedRewards lost, or less than a pass's credits) while an earlier
--     player PASSED: repaired in the same frame (FinishRacer hook, before the race end generates P1's rounds) - the
--     strike(s) refunded, node.bEarnedRewards back, P1's REC fail bits cleared (put back only if the team failed), P1's
--     run credits = a pass's (the finish row's 1st + a podracer test's "Passed Podracer Challenge"); the carrier = the
--     first player who passed (the band and couchrun read M.last.carrier);
--   * nobody passed: the booking stands (one strike for the team);
--   * no booking at all (the last player wrecked: never ingested, N1) with an earlier pass: the pass's credits added.
local function ownVerdict(h)
    local s = h and h.snap
    if type(s) ~= "table" then return "dnf" end
    if h.outHook and not (s.fin or s.wrecked or s.elim) then
        -- read inside his FinishRacer hook: the RPC's own finish flag is written after it (N5)
        local c = {}
        for k, v in pairs(s) do c[k] = v end
        c.fin, s = true, c
    end
    local okS, solo = pcall(U.mod, "couchsolo")
    if not (okS and type(solo) == "table" and type(solo.verdict) == "function") then return "dnf" end
    local lim = R.target
    if lim == nil and type(solo.LIMITED) == "table" and solo.LIMITED[R.aloneKind or ""] then lim = R.limit end
    local ok, v = pcall(solo.verdict, s, lim)
    return ok and v or "dnf"
end
M._ownVerdict = function(h) return ownVerdict(h) end

-- the first player out who passed (finish order), nil = nobody
local function firstPasser()
    local best = nil
    for _, h in ipairs(R.humans) do
        if not h.racing and ownVerdict(h) == "passed" and (not best or (h.outAt or 99) < (best.outAt or 99)) then best = h end
    end
    return best
end

-- P1's credits for a passed test (native: the finish row's 1st; a podracer test also "Passed Podracer Challenge")
local function passCredits()
    local row = nativeRow()
    local fin = math.floor(tonumber(row[1]) or 1250)
    local plane = 0
    if R.kind == "planesprint" then plane = math.floor(tonumber(D and D.misc and D.misc.planeTestCredits) or 3000) end
    return fin + plane, fin
end

local function teamTestRepair(booked)
    if not (R and R.teamTest) or R.teamResolved then return end
    R.teamResolved = true
    local now = snapLedger(R.run, R.planet)
    local p = R.prev
    local okC, cr = pcall(U.getField, R.run, "Credits")
    local crNow = okC and tonumber(cr) or nil
    local delta = (crNow and R.openCr) and math.max(0, crNow - R.openCr) or nil
    local want, fin = passCredits()
    local struck = (now.strikes or 0) > (p.strikes or 0) or (now.disp or 0) > (p.disp or 0)
    local lost = p.earned == true and now.earned == false
    local passer = firstPasser()
    if not (struck or lost or (delta and delta < want)) then
        -- the game booked a pass: the team's (his own verdict may not be readable inside his hook frame yet)
        R.teamPassed, R.teamCarrier = true, passer or booked          -- the first player who passed
        -- couch-fix63 (AUTO-154f): the booking is the GAME's (the last player out); the team result is the first
        -- player who passed - say both, or the later "team result by P2" reads as a contradiction of this line
        local carrier = R.teamCarrier
        U.log(TAG, "team test PASSED: the game booked P%s's finish as a pass; team result carried by P%s (%s)",
            tostring(booked.pnum), tostring(carrier.pnum),
            carrier == booked and "his own pass" or "the first player who passed")
        return
    end
    if not passer then
        R.teamPassed, R.teamCarrier = false, booked
        U.log(TAG, "team test FAILED: every player failed - P%s's booking stands", tostring(booked.pnum))
        return
    end
    R.teamPassed, R.teamCarrier = true, passer
    local notes = {}
    if struck then
        refund(now, booked, "team test", string.format("P%s passed: the test counts for the team", tostring(passer.pnum)))
    end
    if lost then
        local okE = pcall(function() (R.node or currentNode(R.run)).bEarnedRewards = true end)
        notes[#notes + 1] = "node rewards back" .. (okE and "" or " (FAILED)")
    end
    for _, h in ipairs(R.humans) do
        if h.isP1 and U.ok(h.rec) then
            local f = 0
            pcall(function() f = math.floor(tonumber(h.rec.FailReasons) or 0) end)
            if f ~= 0 and pcall(function() h.rec.FailReasons = 0 end) then
                R.p1FailSaved = (R.p1FailSaved or 0) | f
                h.fail = 0
                notes[#notes + 1] = string.format("P1's fail reasons %d cleared", f)
            end
        end
    end
    if delta and crNow and delta < want then
        local okW = pcall(function() R.run.Credits = crNow + (want - delta) end)
        pcall(function()
            local nd = R.node or currentNode(R.run)
            if tonumber(nd.FinishCreditsAwarded) == delta or tonumber(nd.FinishCreditsAwarded) == 0 then
                nd.FinishCreditsAwarded = fin
            end
        end)
        notes[#notes + 1] = string.format("P1's credits %+d -> %+d%s", delta, want, okW and "" or " (FAILED)")
    end
    R.prev = snapLedger(R.run, R.planet)
    R.prev.locked = readLock(R.run)
    U.log(TAG, "team test PASSED by P%s: P%s's failed booking repaired (the test counts for the team)%s",
        tostring(passer.pnum), tostring(booked.pnum), #notes > 0 and ("; " .. table.concat(notes, ", ")) or "")
end

-- every player out (or the race's end): the team test's carrier when nothing was repaired at a booking
teamTestResolve = function(why)
    if not (R and R.teamTest) or R.teamResolved then return end
    R.teamResolved = true
    local passer = firstPasser()
    R.teamPassed = passer ~= nil
    R.teamCarrier = passer or R.booked
    if passer and R.gate and not R.booked then
        -- the last player was never ingested (a wreck): the earlier pass is the team's, the game paid nothing
        local want, fin = passCredits()
        local okC, cr = pcall(U.getField, R.run, "Credits")
        local okW = okC and tonumber(cr) and pcall(function() R.run.Credits = tonumber(cr) + want end)
        pcall(function()
            local nd = R.node or currentNode(R.run)
            if nd.bEarnedRewards ~= true and R.prev.earned == true then nd.bEarnedRewards = true end
            if (tonumber(nd.FinishCreditsAwarded) or 0) == 0 then nd.FinishCreditsAwarded = fin end
        end)
        U.warn(TAG, "team test PASSED by P%s, no booking (the last player out was not ingested): P1's credits +%d%s, "
            .. "no RaceResults row (%s)", tostring(passer.pnum), want, okW and "" or " (FAILED)", tostring(why))
    else
        U.log(TAG, "team test %s%s (%s)", passer and "PASSED by P" .. tostring(passer.pnum) or "FAILED",
            R.booked and (", booked P" .. tostring(R.booked.pnum)) or ", nobody booked", tostring(why))
    end
end

-- couch-fix35 (audit 12 issue 6, Jules's Q1 2026-10-18): P1'S OWN PLACE PAYS P1. Under "best" the run gets ONE booking -
-- the carrier's (a guest home first, a team test repaired into a pass) - and its finish credits, RaceResults row and
-- reward round were P1's whatever P1's own result was, while the carrier guest is paid again from his own result
-- (couchrun.onRaceEnd). The team booking stays for what it is for: League Tokens / strikes, must-win events and the
-- act (DidLocalPlayerWin, the final swap). P1's WALLET and REWARD ROUND follow his own result (M.ownResult):
--   * place races (race, eliminator, gauntlet, championship, mystery race) carried by a guest: the booking's finish
--     credits rescaled from the carrier's native row to P1's own place (the run's multiplier kept: M.rescaleCredits),
--     0 for a wrecked P1 (the native ingestion skips wrecks); the booked RaceResults row = P1's place (the recap);
--   * a team test passed by a guest that P1 failed: the pass's finish credits taken back (a failed field test pays 0);
--   * his round: none when his own result earns none in solo (wrecked, an eliminator outside the top
--     cfg.CouchHighRiskTop or eliminated, a failed field test) - node.bEarnedRewards false right before the race end
--     generates it (the FinishRacer hook of the last human out), the team's value kept for the guests' offers
--     (R.teamEarnedKept, as stripP1Round). Not on a final event a guest won for the team (the act-finish flow is the
--     team's: the final swap).
-- Setting CouchEconomy (FREE MODE > OPTIONS > PLAYERS > Couch campaign > P1's rewards, settings.txt): "own" (default) | "best"
-- (the old rule: the best result carries everyone's wallet). Read at the race end. Plane tests (every finish booked
-- natively, no gate) and the "p1" rule (P1's own booking) are left alone.
function M.econRule()
    local v = nil
    pcall(function() v = require("settings").get("CouchEconomy") end)
    return (v == "best") and "best" or "own"
end

-- pure: does P1's OWN result earn him a reward round in solo? (activity, kind, his snapshot, his team-test verdict or
-- nil) -> bool, why
function M.ownEarned(activity, kind, snap, verdict)
    if type(snap) ~= "table" then return true, "no snapshot" end
    if snap.wrecked then return false, "wrecked" end
    if verdict ~= nil and verdict ~= "passed" and kind ~= "planesprint" then
        return false, "his own test " .. tostring(verdict)
    end
    if tonumber(activity) == 3 then
        if snap.elim then return false, "eliminated" end
        local top = tonumber(opt("CouchHighRiskTop", 3)) or 3
        if (tonumber(snap.pos) or 99) > top then return false, string.format("eliminator place %s > %d", tostring(snap.pos), top) end
    end
    return true, "his own result earns it"
end

-- pure: P1's own finish credits from the booking's (delta, booked = the carrier {pos, isP1}, P1's snapshot, team test
-- verdict or nil, team test passed) -> want (nil = keep), why
function M.ownCredits(delta, booked, snap, verdict, teamPassed, kind)
    delta = math.floor(tonumber(delta) or 0)
    if delta <= 0 or type(snap) ~= "table" then return nil, "no booked credits" end
    if verdict ~= nil then
        if teamPassed and verdict ~= "passed" then
            -- solo: a failed field test pays 0, a failed podracer test the bottom row (#107)
            if kind == "planesprint" and verdict ~= "wrecked" then
                local row = nativeRow()
                return math.floor(tonumber(row[#row]) or 25), "his own podracer test failed: the bottom row"
            end
            return 0, "his own test " .. tostring(verdict) .. ": a failed test pays 0"
        end
        return nil, "his own test passed"
    end
    if not booked or booked.isP1 then return nil, "P1's own booking" end
    if snap.wrecked then return 0, "wrecked: the native ingestion pays a wreck nothing" end
    local want = M.rescaleCredits(delta, booked.pos, snap.pos)
    return want, string.format("his place %s, not P%s's %s", tostring(snap.pos), tostring(booked.pnum), tostring(booked.pos))
end

local function ordinalText(n)
    n = math.floor(tonumber(n) or 0)
    local m100, m10, suf = n % 100, n % 10, "th"
    if m100 < 11 or m100 > 13 then
        if m10 == 1 then suf = "st" elseif m10 == 2 then suf = "nd" elseif m10 == 3 then suf = "rd" end
    end
    return tostring(n) .. suf
end

ownEconomy = function(why)
    if not R or R.ownDone or not R.gateManaged or R.plane or R.rule ~= "best" or (R.guests or 0) <= 0 then return end
    if M.econRule() ~= "own" then
        R.ownDone = true
        U.log(TAG, "economy rule BEST CARRIES EVERYONE: P1's wallet / round follow the team booking (%s)", tostring(why))
        return
    end
    local p1 = nil
    for _, h in ipairs(R.humans) do if h.isP1 then p1 = h end end
    if not p1 or p1.racing then return end
    R.ownDone = true
    if not p1.snap and U.ok(p1.rec) then readRec(p1); p1.snap = snapOf(p1) end
    local snap = p1.snap
    local verdict = R.teamTest and ownVerdict(p1) or nil
    if verdict == "dnf" and type(snap) == "table" and (snap.fin or p1.outHook) and not snap.wrecked then
        verdict = "passed"            -- finished, no readable time / verdict: never taken as his failure
    end
    local booked = R.booked
    -- couch-fix38 boss instances: the booking was repaired into the team's win (1st); P1's own place = his set's
    if R.boss and R.bossResult then
        local tp = R.bossResult.teamPos
        if not R.bossResult.won and tp and p1.setPos and p1.setPos ~= tp and type(snap) == "table" then
            -- couch-fix57: a head-to-head nobody won, booked at the team's best own place: P1's from his own set
            booked = { pos = tp, pnum = R.bossResult.teamBy, isP1 = false }
            local c = {}
            for k, v in pairs(snap) do c[k] = v end
            c.pos, snap = p1.setPos, c
        elseif not R.bossResult.won or p1.bossWon == true then
            booked = { pos = 1, pnum = 1, isP1 = true }                    -- nothing to correct: his own result
        else
            booked = { pos = 1, pnum = R.bossResult.carrier, isP1 = false }
            if type(snap) == "table" and p1.setPos then
                local c = {}
                for k, v in pairs(snap) do c[k] = v end
                c.pos, snap = p1.setPos, c
            end
        end
    end
    local notes = {}
    -- 1. his wallet
    local nd = R.node or currentNode(R.run)
    local fca = nil
    if nd then pcall(function() fca = tonumber(nd.FinishCreditsAwarded) end) end
    local delta = (fca and fca > 0) and fca or ((R.bookCr and R.openCr) and (R.bookCr - R.openCr) or 0)
    local passFin = nil
    if R.teamTest and R.teamPassed then delta, passFin = passCredits() end   -- the pass P1's run holds (fix34's rows)
    local want, cwhy = M.ownCredits(delta, booked, snap, verdict, R.teamPassed, R.kind)
    if want ~= nil and want ~= delta then
        local okC, cr = pcall(U.getField, R.run, "Credits")
        local okW = okC and tonumber(cr) and pcall(function() R.run.Credits = math.max(0, tonumber(cr) - delta + want) end)
        pcall(function() local lc = tonumber(R.run.LifetimeCreditsEarned); if lc then R.run.LifetimeCreditsEarned = math.max(0, lc - delta + want) end end)
        if nd and (fca == delta or (passFin and fca == passFin)) then
            local fw = want
            if passFin then fw = math.min(want, passFin) end
            pcall(function() nd.FinishCreditsAwarded = fw end)
        end
        -- the booking's credit change shown on P1's results (its newest unseen entry of that amount)
        pcall(function()
            local arr = R.run.mCreditChangesForDisplay
            for i = U.arrayCount(arr), 1, -1 do
                local e = arr[i]
                if tonumber(e.Delta) == delta and e.bSeen ~= true then
                    e.Delta = want
                    if verdict == nil and not snap.wrecked and type(FText) == "function" then
                        pcall(function() e.Reason = FText("Finished " .. ordinalText(snap.pos)) end)
                    end
                    break
                end
            end
        end)
        R.ownCr = { from = delta, to = want }
        notes[#notes + 1] = string.format("credits %+d -> %+d (%s)%s", delta, want, tostring(cwhy), okW and "" or " WRITE FAILED")
    end
    -- the recap row: P1's own place
    if verdict == nil and booked and not booked.isP1 and not snap.wrecked and R.bookRr then
        local okR = pcall(function() R.planet.RaceResults[R.bookRr].FinishPosition = math.floor(tonumber(snap.pos) or 99) end)
        notes[#notes + 1] = string.format("RaceResults P%s -> P%s%s", tostring(booked.pos), tostring(snap.pos), okR and "" or " (FAILED)")
    end
    -- 2. his reward round
    local earned, ewhy = M.ownEarned(R.activity, R.kind, snap, verdict)
    -- his refunded wreck's round is D2's (stripP1Round; cfg.CouchWreckRefundRewards true = he keeps it)
    if not earned and type(snap) == "table" and snap.wrecked then earned = true end
    if not earned and not R.p1RoundStripped and not finalSwapWanted() then
        local cur = nil
        if nd then pcall(function() cur = nd.bEarnedRewards == true end) end
        if cur == true then
            if R.teamEarnedKept == nil then R.teamEarnedKept = cur end
            if pcall(function() nd.bEarnedRewards = false end) then
                R.p1RoundStripped, R.p1OwnNoRound = true, true
                notes[#notes + 1] = "no reward round for him (" .. tostring(ewhy) .. ")"
                if why ~= "last human out, before the race end" then
                    notes[#notes + 1] = "(after the race end: the round may be generated already)"
                end
            end
        end
    end
    -- couch-fix63 (AUTO-154f): `booked` is the game's booking (the team test's carrier may be another player)
    U.log(TAG, "P1's own result pays P1 (OWN PLACE rule; the game booked %s, P1 %s): %s (%s)",
        booked and ("P" .. tostring(booked.pnum)) or "nobody",
        snap and (snap.wrecked and "wrecked" or ("P" .. tostring(snap.pos))) or "?",
        #notes > 0 and table.concat(notes, "; ") or "nothing to change", tostring(why))
end

-- couch-fix38 (D8, Jules's Q12 B): BOSS INSTANCES. Every player races his own copy of the boss race (instances.lua plan
-- kind "boss": set g = guest g + his copy of the boss, built at the pick by M.bossPlace). The game ranks EventPosition
-- over the whole track (two bosses, two humans): a player who beats HIS boss can be "2nd", and the ingestion would book
-- that as a must-win miss (MissedRequiredWin on P1's REC = "Qualifier / Championship Lost"). So, like the team test
-- (couch-fix34): the gate holds the ONE native booking until the last player is out (M.gateWanted "boss"), each
-- player's own verdict is taken the frame he is out (instances.finishOf: his place in his own set, h.bossWon), and the
-- booking is repaired into the team's result in that same frame (FinishRacer hook, before the race end):
--   * team won ("best": ANY player beat his own boss - couch-fix30's must-win rule, the first winner out = the carrier;
--     "p1": P1 beat his) -> the booking's strike(s) refunded, node.bEarnedRewards back, the RaceResults row = 1st, P1's
--     credits from the booked global row rescaled to the 1st row, P1's REC = the team's win (EventPosition 1,
--     FailReasons 0: DidLocalPlayerWin, the act-finish flow); P1's own result kept in R.real (M.realResult);
--   * nobody won -> the booking stands (the act is lost as in solo).
-- Guests are paid from their own set place (couchrun: instances.localPosition); their RECs are never swapped.
local function bossHuman(pnum) for _, h in ipairs(R.humans) do if h.pnum == pnum then return h end end end

-- couch-fix61 (AUTO-150c, live round 6 10:28:09 / mid-race exit): a head-to-head runs this shared boss code but decides
-- no act (a standard node): its log lines say "the head-to-head" / "rival", never "the act is lost / WON"; a booking
-- nobody made reads "nobody booked" (was "P-'s booking")
local function bossWords()
    if R and R.bossH2H then
        return { inst = "head-to-head instances", opp = "rival", stake = "the head-to-head", what = "head-to-head booking" }
    end
    return { inst = "boss instances", opp = "boss", stake = "the act", what = "boss booking" }
end
M._bossWords = function() return bossWords() end
local function bookedBy(b) return b and ("P" .. tostring(b.pnum) .. "'s booking") or "nobody booked" end

-- the team's verdict from the players' own verdicts so far -> won, carrier (the first winner out), p1Won
local function bossTeam()
    local best, p1Won = nil, false
    for _, h in ipairs(R.humans) do
        if h.bossWon == true then
            if h.isP1 then p1Won = true end
            if (R.rule ~= "p1" or h.isP1) and (not best or (h.outAt or 99) < (best.outAt or 99)) then best = h end
        end
    end
    return best ~= nil, best, p1Won
end

-- his own verdict, the frame he is out: a finish = his place in his own set is 1st (instances.finishOf); a wreck /
-- elimination = his own race lost
local function bossVerdictOf(h)
    if h.bossWon ~= nil then return end
    if h.wrecked or h.elim then
        h.bossWon, h.setPos = false, nil
        U.log(TAG, "P%s is out of his own boss race (%s): lost", tostring(h.pnum), h.wrecked and "wrecked" or "eliminated")
        return
    end
    local won, lp = false, nil
    local ok = pcall(function() won, lp = U.mod("instances").finishOf(h) end)
    h.bossWon, h.setPos = ok and won == true, ok and lp or nil
end

-- P1's REC = the team's win (re-asserted at the race's end: finish)
local function bossP1Write(why)
    local B = R.bossResult
    if not (B and B.won) then return end
    local p1 = bossHuman(1)
    if not (p1 and U.ok(p1.rec)) then return end
    local pos, fail = nil, nil
    pcall(function() pos = math.floor(tonumber(p1.rec.EventPosition) or 99); fail = math.floor(tonumber(p1.rec.FailReasons) or 0) end)
    if pos == 1 and fail == 0 then return end
    if not B.real then
        B.real = true
        R.real = R.real or {}
        R.real[U.key(p1.ps)] = { pos = p1.setPos or (p1.snap and p1.snap.pos) or pos, wrecked = p1.wrecked == true,
                                 fail = (p1.snap and p1.snap.fail) or fail, ctrlId = p1.ctrlId, pnum = 1 }
    end
    local ok = pcall(function() p1.rec.EventPosition = 1; p1.rec.FailReasons = 0 end)
    local bw = bossWords()
    U.log(TAG, "%s: P1's result = the team's win (P%s%s beat his %s): EventPosition %s -> 1, fail reasons "
        .. "%s -> 0 %s (%s)", bw.inst, tostring(B.carrier), B.carrier == 1 and " himself" or "", bw.opp, tostring(pos), tostring(fail),
        ok and "ok" or "FAILED", tostring(why))
end

-- the one booking (the last player out) -> repaired into the team's result
local function bossRepair(booked)
    if not (R and R.boss) or R.bossResult then return end
    local won, carrier, p1Won = bossTeam()
    R.bossResult = { won = won, carrier = carrier and carrier.pnum or nil, p1Won = p1Won, booked = booked and booked.pnum }
    R.teamCarrier = carrier or booked
    if not won then
        -- couch-fix57: a standard head-to-head nobody won: the team's result is the best OWN place (2nd of his own
        -- race), never the last player's global place over every copy (4th of 4 = row 4 instead of 2)
        if R.bossH2H and booked then
            local best = nil
            for _, h in ipairs(R.humans) do
                if h.setPos and (not best or h.setPos < best.setPos) then best = h end
            end
            local gp = math.floor(tonumber(booked.pos) or 99)
            if best and best.setPos < gp then
                local notes = {}
                local now = snapLedger(R.run, R.planet)
                local p = R.prev
                if (now.rr or 0) > (p.rr or 0) then
                    local okR = pcall(function() R.planet.RaceResults[now.rr].FinishPosition = best.setPos end)
                    notes[#notes + 1] = string.format("RaceResults P%d -> P%d%s", gp, best.setPos, okR and "" or " (FAILED)")
                end
                local okC, cr = pcall(U.getField, R.run, "Credits")
                local crNow = okC and tonumber(cr) or nil
                local delta = (crNow and R.openCr) and (crNow - R.openCr) or nil
                if delta and delta > 0 then
                    local want = M.rescaleCredits(delta, gp, best.setPos)
                    if want ~= delta then
                        local okW = pcall(function() R.run.Credits = crNow - delta + want end)
                        pcall(function()
                            local nd = R.node or currentNode(R.run)
                            if tonumber(nd.FinishCreditsAwarded) == delta then nd.FinishCreditsAwarded = want end
                        end)
                        notes[#notes + 1] = string.format("P1's credits %+d -> %+d%s", delta, want, okW and "" or " (FAILED)")
                    end
                end
                R.bossResult.teamPos, R.bossResult.teamBy = best.setPos, best.pnum
                R.teamCarrier = best
                R.prev = snapLedger(R.run, R.planet)
                R.prev.locked = readLock(R.run)
                U.log(TAG, "head-to-head instances: nobody beat his own rival (rule %s) - the team's result is P%d's own "
                    .. "place %d (P%s's booking: global place %d)%s", R.rule, best.pnum, best.setPos,
                    tostring(booked.pnum), gp, #notes > 0 and ("; " .. table.concat(notes, ", ")) or "")
                return
            end
        end
        local bw = bossWords()
        U.log(TAG, "%s: nobody beat his own %s (rule %s) - %s: %s is lost as in solo", bw.inst, bw.opp, R.rule,
            booked and (bookedBy(booked) .. " stands") or "nobody booked", bw.stake)
        return
    end
    local notes = {}
    if booked then
        local now = snapLedger(R.run, R.planet)
        local p = R.prev
        if (now.strikes or 0) > (p.strikes or 0) or (now.disp or 0) > (p.disp or 0) then
            local bw = bossWords()
            refund(now, booked, bw.what, string.format("P%d beat his own %s: %s is won", carrier.pnum, bw.opp, bw.stake))
        end
        if p.earned == true and now.earned == false then
            local okE = pcall(function() (R.node or currentNode(R.run)).bEarnedRewards = true end)
            notes[#notes + 1] = "node rewards back" .. (okE and "" or " (FAILED)")
        end
        local gp = math.floor(tonumber(booked.pos) or 99)
        if (now.rr or 0) > (p.rr or 0) and gp ~= 1 then
            local okR = pcall(function() R.planet.RaceResults[now.rr].FinishPosition = 1 end)
            notes[#notes + 1] = string.format("RaceResults P%d -> P1%s", gp, okR and "" or " (FAILED)")
        end
        local okC, cr = pcall(U.getField, R.run, "Credits")
        local crNow = okC and tonumber(cr) or nil
        local delta = (crNow and R.openCr) and (crNow - R.openCr) or nil
        if delta and delta > 0 and gp ~= 1 then
            local want = M.rescaleCredits(delta, gp, 1)
            if want ~= delta then
                local okW = pcall(function() R.run.Credits = crNow - delta + want end)
                pcall(function()
                    local nd = R.node or currentNode(R.run)
                    if tonumber(nd.FinishCreditsAwarded) == delta then nd.FinishCreditsAwarded = want end
                end)
                notes[#notes + 1] = string.format("P1's credits %+d -> %+d%s", delta, want, okW and "" or " (FAILED)")
            end
        end
    end
    bossP1Write("booking repaired")
    R.prev = snapLedger(R.run, R.planet)
    R.prev.locked = readLock(R.run)
    local bw = bossWords()
    U.log(TAG, "%s: %s is WON - P%d beat his own %s (rule %s); %s%s", bw.inst, bw.stake, carrier.pnum, bw.opp, R.rule,
        booked and string.format("P%s's booking (global place %s) repaired", tostring(booked.pnum), tostring(booked.pos))
            or "nobody booked (the last player out was not ingested: no RaceResults row / finish credits)",
        #notes > 0 and ("; " .. table.concat(notes, ", ")) or "")
end
M._bossRepair = function(b) return bossRepair(b) end

-- every player out without a booking (the last one wrecked: never ingested, N1)
local function bossResolve(why)
    if not (R and R.boss) or R.bossResult then return end
    if R.booked then bossRepair(R.booked); return end
    bossRepair(nil)
    if not R.bossResult.won then U.log(TAG, "%s: nobody booked, nobody won (%s)", bossWords().inst, tostring(why)) end
end

local function finish(why)
    if not R then return end
    restoreGate(why)
    if R.p1FailSaved ~= nil then
        local earned = teamEarned()
        -- couch-fix34: a team test every player failed (a failed podracer test keeps node.bEarnedRewards natively)
        if R.teamTest and R.teamPassed == false then earned = false end
        -- couch-fix38 (D8): a won boss race keeps P1's REC clean (acts II / III earn no rewards natively)
        if R.boss and R.bossResult and R.bossResult.won then earned = true end
        if earned == false then
            local p1 = nil
            for _, h in ipairs(R.humans) do if h.isP1 then p1 = h end end
            -- U.ok: finish also runs from the "world" event, when the race's PlayerStates may be freed already
            if p1 and U.ok(p1.rec) then pcall(function()
                local cur = math.floor(tonumber(p1.rec.FailReasons) or 0)
                p1.rec.FailReasons = cur | R.p1FailSaved
            end) end
            U.log(TAG, "team result failed: P1's fail reasons put back (%d)", R.p1FailSaved)
        else
            U.log(TAG, "team result succeeded: P1's own fail reasons (%d) stay cleared", R.p1FailSaved)
        end
        R.p1FailSaved = nil
    end
    if R.plane and #R.humans > 1 then
        local won = false
        for k, w in pairs(R.planeWon) do
            local h = humanByKey(k)
            if w and (R.rule == "best" or (h and h.isP1)) then won = true end
        end
        pcall(function() R.planet.bHasWonPlaneTest = won end)
        U.log(TAG, "plane test (%s rule): bHasWonPlaneTest = %s", R.rule, tostring(won))
    end
    -- (the FinishRacer hook of the last human out did it before the race end; without it the race end has generated
    -- P1's round already - the node is left alone then, logged)
    if R.p1RoundLost and not R.p1RoundStripped then
        U.warn(TAG, "P1's refunded wreck: his reward round could not be taken (no FinishRacer hook before the race end)")
    end
    -- couch-fix30 (audit 12 #2): a missed finish nobody's booking followed (the last human standing wrecked, refunded):
    -- the team result is his place (no token, P1's REC clean), but the game never booked it: no RaceResults row / credits
    if R.missed and not R.booked then
        R.booked = R.missed
        U.warn(TAG, "P%s's place %d (finished while the gate was closed) is the team result; no later booking to repair: "
            .. "the run has no RaceResults row / finish credits for this event", tostring(R.missed.pnum), R.missed.pos or 99)
    end
    teamTestResolve("race end")
    bossResolve("race end")
    M.rivalResolve("race end")
    ownEconomy(why)                 -- couch-fix35 (Q1): no FinishRacer hook ran it (its round strip is too late then)
    if R.boss then bossP1Write("race end") end
    -- couch-fieldtest: every human's own result (the ones without an edge snapshot: still out at the race's end) -
    -- read BEFORE the final swap (couch-fix30: the swap rewrites the RECs)
    local own = {}
    for _, h in ipairs(R.humans) do
        if not h.snap and not h.gone and U.ok(h.rec) then readRec(h); h.snap = snapOf(h) end
        own[#own + 1] = { pnum = h.pnum, isP1 = h.isP1, ctrlId = h.ctrlId, snap = h.snap,
                          wreckRefunded = h.wreckRefunded == true }
    end
    finalSwap()
    local carrier = R.teamCarrier or R.booked
    M.last = { kind = R.kind, activity = R.activity, rule = R.rule, carrier = carrier and carrier.pnum or nil,
               booked = R.booked and R.booked.pnum or nil, teamTest = R.teamTest == true, teamPassed = R.teamPassed,
               boss = R.boss and (R.bossResult or { won = false }) or nil,
               rival = R.rival and (R.rivalResult or { won = false }) or nil,
               refunds = #R.refunds, sitOut = sitOut, earned = teamEarned(), alone = R.alone == true,
               aloneKind = R.aloneKind, limit = R.limit, target = R.target, humans = own, gen = St.worldGen,
               real = R.real, teamEarnedKept = R.teamEarnedKept, p1RoundLost = R.p1RoundLost == true,
               ownCr = R.ownCr, p1OwnNoRound = R.p1OwnNoRound == true }
    -- couch-fix63 (AUTO-154f): a team test's carrier (the first player who passed) is not always the game's booking
    -- (the last player out): the line names both then
    local by = carrier and ("P" .. tostring(carrier.pnum)) or "nobody"
    if carrier and R.booked and carrier ~= R.booked then
        by = string.format("%s (%s; the game booked P%s)", by,
            R.teamTest and (R.teamPassed and "the first player who passed" or "the team test's carrier") or "carrier",
            tostring(R.booked.pnum))
    end
    U.log(TAG, "couch race ruled (%s): team result by %s, %d refund(s), team rewards %s%s", tostring(why),
        by, #R.refunds, tostring(M.last.earned),
        R.teamTest and (", team test " .. (R.teamPassed and "PASSED" or "FAILED")) or
            (R.boss and (", " .. bossWords().inst .. " " .. ((R.bossResult and R.bossResult.won) and "WON" or "LOST")) or
            (R.rival and (", rival challenge " .. ((R.rivalResult and R.rivalResult.won) and "WON" or "LOST")) or "")))
    R = nil
end

-- Two humans booked inside one frame (a photo finish; every harness "finish 1 + finish 2" block): the extra, worse
-- booking also ran the must-win / high-risk checks on P1's OWN REC (N1): a won championship read "QUALIFIER LOST"
-- (live 2026-10-14). When the team result (the best place) is a WIN, P1's fail bits go back to their value before this
-- frame and the strike(s) of this frame are refunded. A worse team result is left native (logged).
repairDouble = function(p1FailBefore)
    local best = R.booked
    if not best or (best.pos or 99) ~= 1 then
        U.warn(TAG, "double booking left native: team result place %s is not a win", tostring(best and best.pos))
        return
    end
    for _, h in ipairs(R.humans) do
        if h.isP1 and U.ok(h.rec) then
            local cur = math.floor(tonumber(h.rec.FailReasons) or 0)
            local want = math.floor(tonumber(p1FailBefore) or 0)
            if cur ~= want then
                pcall(function() h.rec.FailReasons = want end)
                h.fail = want
                U.log(TAG, "double booking repaired: P1's fail reasons %d -> %d (team result = a win)", cur, want)
            end
        end
    end
    local now = snapLedger(R.run, R.planet)
    if (now.strikes or 0) > (R.prev.strikes or 0) or (now.disp or 0) > (R.prev.disp or 0) then
        refund(now, best, "double booking", "the team result is a win")
        R.prev = snapLedger(R.run, R.planet)
        R.prev.locked = readLock(R.run)
    end
    local nd = currentNode(R.run)
    if nd and R.prev.earned == true then pcall(function() nd.bEarnedRewards = true end) end
end

-- couch-fix30 (audit 12 #2, BLOCKER): an ELIMINATION race (eliminator / Gauntlet), "best": while a racing human sits in
-- the elimination band the gate is closed (else his elimination would be booked). A human who FINISHES in that window is
-- not booked by the game (R.missed) - and he is better than every human still racing (finish order). The game books
-- the next human out instead (the last human standing: his later, worse place or his elimination), with the high-risk /
-- must-win strike on P1's REC. The ingestion is not callable, so that late booking is REPAIRED into the missed one, in
-- the same frame (FinishRacer hook, before the race end generates P1's rounds):
--   * the team result = the missed human's place: the late booking's strike(s) refunded and node.bEarnedRewards back
--     when that place passes the event (eliminator: top cfg.CouchHighRiskTop; must-win: 1st), P1's REC fail bits as
--     for a guest carrier (P1's own result kept clean on a team success);
--   * always: the booked RaceResults entry gets the missed place, P1's credits from the booking are rescaled to the
--     missed place's row (CampaignRun.Credits; the node's FinishCreditsAwarded when it holds that booking).
-- pure: does a place pass the event, given the fail bits the late booking put on P1's REC (bits) -> bool
function M.missedPasses(activity, pos, bits)
    pos = tonumber(pos) or 99
    bits = math.floor(tonumber(bits) or 0)
    if (bits & M.FAIL.MissedRequiredWin) ~= 0 and pos >= 2 then return false end
    if tonumber(activity) == 3 and pos > (tonumber(opt("CouchHighRiskTop", 3)) or 3) then return false end
    return true
end
-- the booking's credits rescaled from the late place's native row to the missed place's (the run's multiplier kept)
function M.rescaleCredits(delta, fromPos, toPos)
    local row = nativeRow()
    local a = tonumber(row[math.max(1, math.min(#row, math.floor(tonumber(fromPos) or #row)))])
    local b = tonumber(row[math.max(1, math.min(#row, math.floor(tonumber(toPos) or #row)))])
    delta = tonumber(delta) or 0
    if not (a and b) or a <= 0 or delta <= 0 then return delta end
    return math.floor(delta * b / a + 0.5)
end
local function repairMissed(late, p1FailBefore)
    local m = R.missed
    local now = snapLedger(R.run, R.planet)
    local p1 = nil
    for _, h in ipairs(R.humans) do if h.isP1 then p1 = h end end
    local p1Now = p1 and math.floor(tonumber(p1.fail) or 0) or 0
    pcall(function() p1Now = math.floor(tonumber(p1.rec.FailReasons) or p1Now) end)
    local added = p1Now & ~math.floor(tonumber(p1FailBefore) or 0)
    local passes = M.missedPasses(R.activity, m.pos, added)
    local notes = {}
    -- the RaceResults entry of the late booking -> the missed place
    if (now.rr or 0) > (R.prev.rr or 0) then
        local okR = pcall(function() R.planet.RaceResults[now.rr].FinishPosition = m.pos end)
        notes[#notes + 1] = string.format("RaceResults P%s -> P%d%s", tostring(late.pos), m.pos, okR and "" or " (FAILED)")
    end
    -- P1's credits from the late booking -> the missed place's row
    local okC, cr = pcall(U.getField, R.run, "Credits")
    now.cr = okC and tonumber(cr) or nil
    local delta = (now.cr and R.missedCr) and (now.cr - R.missedCr) or nil
    if delta and delta > 0 then
        local want = M.rescaleCredits(delta, late.pos, m.pos)
        if want ~= delta then
            local okC = pcall(function() R.run.Credits = now.cr - delta + want end)
            pcall(function()
                local nd = R.node or currentNode(R.run)
                if tonumber(nd.FinishCreditsAwarded) == delta then nd.FinishCreditsAwarded = want end
            end)
            notes[#notes + 1] = string.format("P1's credits %+d -> %+d%s", delta, want, okC and "" or " (FAILED)")
        end
    end
    if passes then
        if p1 and U.ok(p1.rec) then
            local want = 0
            if m.isP1 then want = math.floor(tonumber(m.snap and m.snap.fail or p1FailBefore) or 0)
            elseif R.p1FailSaved == nil and p1Now ~= 0 then R.p1FailSaved = p1Now & ~added end
            if p1Now ~= want and pcall(function() p1.rec.FailReasons = want end) then
                p1.fail = want
                notes[#notes + 1] = string.format("P1's fail reasons %d -> %d", p1Now, want)
            end
        end
        if (now.strikes or 0) > (R.prev.strikes or 0) or (now.disp or 0) > (R.prev.disp or 0) then
            refund(now, late, "missed finish", string.format("P%s's missed place %d is the team result", tostring(m.pnum),
                m.pos))
        end
        if R.prev.earned == true then
            pcall(function() (R.node or currentNode(R.run)).bEarnedRewards = true end)
        end
        R.prev = snapLedger(R.run, R.planet)
        R.prev.locked = readLock(R.run)
    end
    R.booked = m
    R.missedRepaired = true
    U.log(TAG, "missed finish repaired: P%s's place %d (finished while the gate was closed) is the team result, not "
        .. "P%s's booked place %d - %s%s", tostring(m.pnum), m.pos, tostring(late.pnum), late.pos or 99,
        passes and "the event is passed" or "the event is failed all the same (strike kept)",
        #notes > 0 and ("; " .. table.concat(notes, ", ")) or "")
end
M._repairMissed = function(late, before) return repairMissed(late, before) end

local function byPos(a, b) return (a.pos or 99) < (b.pos or 99) end
local NONE = setmetatable({}, { __newindex = function() error("couchrules: NONE is read-only", 2) end })
-- fromHook: called from the FinishRacer hook (N5), inside the frame of that racer's finish / wreck / elimination
function M.fastTick(fromHook)
    if St.phase ~= "RACING" then return end
    if not R then
        if not M._begun then
            M._begun = true
            U.try(TAG, begin)
            if R and R.gate then
                M.finishHooked = M.finishHooked or U.hook(M.FINISH_FN, {
                    pre = function(rec) U.try(TAG, M.onRacerOut, rec) end }, TAG)
                U.log(TAG, "result gate: FinishRacer hook %s", M.finishHooked and
                    "armed (the last human out opens it before the race end: P1's reward rounds are generated)" or
                    "NOT armed - FAST-tick fallback: the race end may skip P1's reward rounds")
            end
        end
        if not R then return end
    end
    if not U.ok(R.run) then R = nil; return end
    -- couch-fix33 (racegc): the two lists are only made on a tick where a human stops racing (NONE: shared, never
    -- written), and no table per human per FAST tick for his previous state
    local newWreck, newDone = NONE, NONE
    R.tickN = (R.tickN or 0) + 1
    local gateWasOpen = R.gate and not R.gateClosed
    local p1FailBefore = nil
    for _, h in ipairs(R.humans) do if h.isP1 then p1FailBefore = h.fail end end
    for _, h in ipairs(R.humans) do
        local wasRacing, wasWrecked = h.racing, h.wrecked
        readRec(h)
        local sn = h.snap
        if sn and not wasRacing and h.fin and not (sn.fin or sn.wrecked or sn.elim or h.gone) then
            -- couch-fix34: his snapshot came from his FinishRacer hook (the RPC's finish flag after it): taken again
            -- once, his first-seen fail bits kept (P1's may have been cleared for a guest's booking since)
            local s2 = snapOf(h)
            s2.fail = math.floor(tonumber(s2.fail) or 0) | math.floor(tonumber(sn.fail) or 0)
                | ((h.isP1 and R.p1FailSaved) or 0)
            if s2.score == nil then s2.score = sn.score end
            h.snap = s2
        end
        if wasRacing and not h.racing and not h.gone then     -- a gone REC is no finish / wreck to book
            if h.wrecked and not wasWrecked then
                if newWreck == NONE then newWreck = {} end
                newWreck[#newWreck + 1] = h
            else
                if newDone == NONE then newDone = {} end
                newDone[#newDone + 1] = h
            end
            h.snap = snapOf(h)                                  -- couch-fieldtest: his own result, now
            R.outSeq = (R.outSeq or 0) + 1
            h.outAt = R.outSeq                                  -- couch-fix34: finish order (the team test's carrier)
            if R.boss or R.rivalInst then bossVerdictOf(h) end  -- couch-fix38: his own boss race, this frame
            -- couch-fix58 (D5): the first player out decides the game's rival challenge (his finish / wreck)
            if R.rival and not R.rivalFirst then
                R.rivalFirst = { who = h, wreck = h.wrecked == true, pos = h.pos, before = R.prev, tick = R.tickN }
            end
            -- #81: a wreck in an elimination race = out at his standing (the racers not eliminated / wrecked yet)
            if h.wrecked and M.isElimination(R.activity) then h.snap.outPlace = M.standingAt(h.rec, riskRecs()) end
        end
    end
    -- what the native booked since the last tick (N1: a non-wrecked human's finish/elimination while the gate was open)
    local doubled = false
    if R.gate then
        if #newDone > 1 then table.sort(newDone, byPos) end
        for _, h in ipairs(newDone) do
            if gateWasOpen then
                if R.booked then
                    doubled = true
                    U.warn(TAG, "double booking: P%s booked too, place %d (finished inside the same frame window)",
                        tostring(h.pnum), h.pos)
                else
                    R.booked = h
                    U.log(TAG, "team result booked: P%s, place %d (%s rule)", tostring(h.pnum), h.pos, R.rule)
                    -- couch-fix35 (Q1): the booking's credits / RaceResults row, read once (P1's own-place economy)
                    local okC, cr = pcall(U.getField, R.run, "Credits")
                    R.bookCr = okC and tonumber(cr) or nil
                    local okR, rr = pcall(U.getField, R.planet, "RaceResults")
                    R.bookRr = okR and U.arrayCount(rr) or nil
                    if R.teamTest then teamTestRepair(h) end   -- couch-fix34: before the ledger (no Second Chance on it)
                    if R.boss then bossRepair(h) end           -- couch-fix38 (D8): the team's result, same frame
                end
            elseif not h.elim and not R.booked and not R.missed and not R.teamTest and not R.boss then
                R.missed = h
                -- couch-fix30: P1's credits before the late booking (its credits are rescaled: repairMissed); read once
                -- here, not per FAST tick (couch-racegc)
                local okC, cr = pcall(U.getField, R.run, "Credits")
                R.missedCr = okC and tonumber(cr) or nil
                U.log(TAG, "P%s finished in place %d while the gate was closed: not booked by the game (the next booking "
                    .. "is repaired into this place)", tostring(h.pnum), h.pos)
            end
        end
    else
        for _, h in ipairs(newDone) do if not R.booked then R.booked = h end end
    end
    -- couch-fix30 (audit 12 #2): the late booking after a missed finish in an elimination race -> the missed place
    local late = R.booked
    if R.gate and late and R.missed and late ~= R.missed and not R.missedRepaired and R.rule == "best"
        and M.isElimination(R.activity) and (late.elim or (late.pos or 99) > (R.missed.pos or 99)) then
        repairMissed(late, p1FailBefore)
    end
    if R.plane then
        -- couch-trial2: with MISSION INSTANCES each human's result is his own race's (instances.finishOf: his place in
        -- his own set + his target); the native flag (ranked over every set) is only kept when it says "won"
        local inst = nil
        if #newDone > 0 then        -- couch-fix33 (racegc): only on a tick with a finish (was a closure every tick)
            pcall(function() local m = U.mod("instances"); if m.active() then inst = m end end)
        end
        for _, h in ipairs(newDone) do
            local w = false
            pcall(function() w = R.planet.bHasWonPlaneTest == true end)
            if inst then
                local okF, iw = pcall(inst.finishOf, h)
                local native = (#newDone == 1) and w or false
                R.planeWon[U.key(h.ps)] = (okF and iw == true) or native
                U.log("instances", "finish booking: P%s own race %s, native flag %s (%s) -> booked %s", tostring(h.pnum),
                    (okF and iw == true) and "WON" or "not won", tostring(w),
                    #newDone == 1 and "his" or "2+ finishes this tick: not his alone", tostring(R.planeWon[U.key(h.ps)]))
            elseif #newDone == 1 then
                R.planeWon[U.key(h.ps)] = w
            end
        end
    end
    if doubled then repairDouble(p1FailBefore) end
    ledgerStep(newWreck, newDone)
    preFailGuests()
    local racing = 0
    for _, h in ipairs(R.humans) do if h.racing then racing = racing + 1 end end
    if racing == 0 then
        -- N5: inside the last human's FinishRacer the race has not ended yet: the gate opens NOW, so the race end that
        -- follows generates P1's reward rounds; the rest of the bookkeeping (fail bits, final swap) on the FAST tick
        teamTestResolve("every player out")
        bossResolve("every player out")
        M.rivalResolve("every player out")
        if fromHook == true then
            stripP1Round("last human out, before the race end")
            ownEconomy("last human out, before the race end")
            if R.gate then restoreGate("last human out, before the race end: the game generates the reward rounds") end
            R.outByHook = true
            return
        end
        finish("every human done"); return
    end
    if R.gate then
        if M.isElimination(R.activity) then markRisk(R.humans) end
        local open, why = M.gateWanted(R.rule, R.activity, R.humans, R.booked ~= nil, R.boss and "boss" or R.teamTest)
        -- "best" with a guest as the carrier: P1's own fail bits would strike regardless of the guest's place (N1)
        if open and R.rule == "best" and R.p1FailSaved == nil then
            for _, h in ipairs(R.humans) do
                if h.isP1 and not h.racing and (h.fail or 0) ~= 0 and U.ok(h.rec) then
                    local ok = pcall(function() h.rec.FailReasons = 0 end)
                    if ok then
                        R.p1FailSaved = h.fail
                        U.log(TAG, "P1 is done (fail reasons %d): cleared while a guest carries the team result", h.fail)
                    end
                end
            end
        end
        setGate(open, why)
    end
end

---------------------------------------------------------------------------------------------------- grid helpers
-- couch.patchGrid asks: may it re-point AI entries now?
function M.allowGridPatch()
    local run = campaignRun()
    if not run then return true end
    if isRivalRace(run) then
        return false, "rival challenge (fixed 2-racer recipe): couchrules.rivalPlace adds the guests (D5, couch-fix58)"
    end
    local act = nil
    pcall(function()
        local nodes = run.Map.mNodes
        for i = 1, U.arrayCount(nodes) do
            local nd = nodes[i]
            if U.ok(nd) and nd.bHasBeenChosen == true and nd.bHasBeenCompleted ~= true then act = tonumber(nd.Activity) end
        end
    end)
    return M.allowGridPatchFor(act)
end

-- couch.patchGrid asks: is this bot entry one a guest must never take?
function M.isProtected(ps)
    local run = campaignRun()
    local rival = nil
    if run then pcall(function() rival = run:GetActiveRival() end) end
    return M.protectedEntry(ps, rival)
end

-- D7: the championship's HeadToHead grid +guests for the node pick
local H2H = "/Game/Griffin/Gameplay/Campaign/GameModes/GMV_HeadToHead.GMV_HeadToHead"
local h2hPatch = nil
local PLAYER_CHOICE = 4                    -- ERaceGridEntryType::PlayerChoice (consts.E.GridEntry)
local function guestCount()
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    return (ok and type(list) == "table") and #list or 0
end
-- #74 (tester #5, 05:01:27): the pick of a BLACK MARKET stop logged "championship grid ... (guests race the boss too)":
-- the hook grew the HeadToHead grid on EVERY node pick. Only a championship pick (ECampaignMapNodeActivity
-- ChampionEvent 6) builds from GMV_HeadToHead; a node whose activity is unreadable keeps the old behaviour.
M.CHAMPION_ACTIVITY = 6
local function pickedActivity(nodeP)
    local a = nil
    pcall(function()
        local nd = nodeP
        if nd ~= nil and type(nd) ~= "number" and not U.ok(nd) then nd = nodeP:get() end   -- a RemoteUnrealParam
        if U.ok(nd) then a = tonumber(nd.Activity) end
    end)
    return a
end
M._pickedActivity = pickedActivity
-- couch-fix57 (round 4, Derven Acos node #48: a gauntlet STANDARD pick rolled WHP_LOOP_A_ELM_TeamRace_Night =
-- GMV_HeadToHead, 2 cars P1 vs Griff Halloran; "1 guest(s) without an entry" -> P2 sat out): a race pick whose event
-- the planet's EventPicker rolls INSIDE the pick may be a head-to-head (the GMV is only known after the builder). For
-- these activities GMV_HeadToHead is grown at the pick exactly as for a championship (D7 / D8); the post-hook keeps
-- the growth only when the rolled event's stage really is GMV_HeadToHead (any other event never reads that GMV).
-- Placed as D8's instances: each player vs his own copy of the rival (plan h2h), team result "best", each paid from
-- his own place.
M.H2H_ACTIVITY = { [2] = true, [3] = true }
-- couch-fix38 (D8): is this championship pick raced as BOSS INSTANCES? -> want (total racers), S = 2, nil + why
-- (couch-fix57: h2h = a standard / high-risk pick that may roll a head-to-head: the same plan)
function M.bossInstancesWanted(act, n, h2h)
    if opt("CouchBossInstances", true) ~= true then return nil, nil, "CouchBossInstances off" end
    if act ~= M.CHAMPION_ACTIVITY and not (h2h and M.H2H_ACTIVITY[act]) then
        return nil, nil, "node activity " .. tostring(act) .. " (not a readable championship)"
    end
    if (tonumber(n) or 0) < 1 then return nil, nil, "no guest" end
    local inst = nil
    pcall(function() inst = U.mod("instances") end)
    if not (type(inst) == "table" and inst.enabled and inst.enabled()) then return nil, nil, "CouchMissionInstances off" end
    -- S = 2 (the player + his boss) per set: 4 / 6 / 8 racers for 2 / 3 / 4 players, under the game's 12
    local want, S, why = inst.gridFor(2, 1, n, "championship")
    if not want then return nil, nil, why end
    return want, S, nil
end

function M.patchChampion(node, actOverride)
    if h2hPatch or opt("CouchChampionGrid", true) ~= true then return end
    local act = actOverride or pickedActivity(node)
    local maybe = act ~= nil and M.H2H_ACTIVITY[act] == true               -- couch-fix57: may roll a head-to-head
    if act ~= nil and act ~= M.CHAMPION_ACTIVITY and not maybe then return end
    local n = guestCount()
    if n < 1 or opt("CouchCampaign", true) ~= true then return end
    local g = U.obj(H2H)
    if not U.ok(g) then return end
    local want, S, noWhy = M.bossInstancesWanted(act, n, maybe)
    pcall(function()
        local entries = g.GridMakeup.Entries
        local k, total = nil, 0
        for i = 1, entries:GetArrayNum() do
            -- the PlayerChoice entry (ERaceGridEntryType 4, P1's); the boss entry (Skimmer x1) is never touched
            if k == nil and tonumber(entries[i].EntryType) == PLAYER_CHOICE then k = i end
            total = total + (tonumber(entries[i].NumEntrants) or 0)
        end
        if k then
            local orig = tonumber(entries[k].NumEntrants) or 1
            if want and want > total then
                -- D8: the builder adds 2 x guests fill entries after [P1, boss]: each guest + his boss copy (M.bossPlace)
                entries[k].NumEntrants = orig + (want - total)
                h2hPatch = { gmv = g, k = k, orig = orig, inst = { S = S, nG = n, want = want }, maybe = maybe }
                -- (a standard pick: said by the post-hook, only when the rolled event is a head-to-head - #74)
                if not maybe then
                    U.log(TAG, "championship grid: entry %d %d -> %d - BOSS INSTANCES: %d copies of the boss race x %d "
                        .. "racers (each player + his own boss)", k, orig, orig + (want - total), 1 + n, S)
                end
                return
            end
            entries[k].NumEntrants = orig + n
            h2hPatch = { gmv = g, k = k, orig = orig, maybe = maybe, sharedWhy = noWhy }
            if not maybe then
                U.log(TAG, "championship grid: entry %d %d -> %d (guests race the boss too%s)", k, orig, orig + n,
                    noWhy and ("; shared boss race: " .. tostring(noWhy)) or "")
            end
        end
    end)
end
function M.restoreChampion()
    if not h2hPatch then return end
    pcall(function() h2hPatch.gmv.GridMakeup.Entries[h2hPatch.k].NumEntrants = h2hPatch.orig end)
    h2hPatch = nil
end

-- couch-fix49 (AUTO-127, live round 2 13:56:30): CONTINUE straight into a pending championship (a run saved inside
-- the boss event: continue state 1) rebuilds the grid from the node with the native builder - no ChooseNextMapNode, so
-- GMV_HeadToHead was never grown: [P1, boss], "P2: no AI entry to take (grid of 2, 0 AI left): sits this one out" ->
-- P1 alone vs the boss, P2 watching. The fix38 note "ContinueCurrentMapNodeEvent is not hooked": its post-hook never
-- logged live (the front end calls it natively). NOW: the CONTINUE entries the front end goes through
-- (FrontEndGameMode:CampaignSelected - the CONTINUE tile and the couch page -, :TravelToContinueRaceEvent,
-- CampaignSubsystem:ContinueCurrentMapNodeEvent; pre-hooks) grow GMV_HeadToHead as a championship pick does (boss
-- instances: 2 x players; else the shared race's +guests) when the run's current node is a championship - or cannot be
-- read yet (the builder uses GMV_HeadToHead for championships only: any other continue leaves it unused). At
-- FRONTEND -> TRANSIT (the recipe is built, couch.lua's continue branch) M.continuePlace places it exactly like the
-- pick's post-hook (M.bossPlace: each guest + his own boss copy, the shared boss race as its fallback) and swaps the
-- boss intro (#97); a recipe that is no head-to-head is left to couch.patchGrid. The grid is restored at once.
local function stageGmvName()
    local nm = nil
    pcall(function()
        local rc = U.giSubsystem("EventRecipeSubsystem").ActiveRecipe
        local stages = rc.Recipe.EventStages
        local idx = (tonumber(rc.RecipeState.ActiveStage) or 0) + 1
        if idx >= 1 and idx <= U.arrayCount(stages) then nm = U.objName(stages[idx].GameModeVariant) end
    end)
    return nm
end

function M.continueArm(why)
    if St.phase ~= "FRONTEND" or h2hPatch then return end
    if opt("CouchCampaign", true) ~= true or guestCount() < 1 then return end
    local run = campaignRun()
    local nd = run and currentNode(run) or nil
    local act = nd and pickedActivity(nd) or nil
    -- couch-fix58 (a): a pending STANDARD / HIGH-RISK node may be a rolled head-to-head (fix57's node #48): grown the
    -- same way (maybe: kept only when the continued recipe is one, M.continuePlace)
    local maybe = act ~= nil and M.H2H_ACTIVITY[act] == true
    if act ~= nil and act ~= M.CHAMPION_ACTIVITY and not maybe then return end
    M.patchChampion(nd, maybe and act or M.CHAMPION_ACTIVITY)
    if h2hPatch then
        h2hPatch.cont = tostring(why)
        U.log(TAG, "campaign CONTINUE (%s): GMV_HeadToHead grown for the run's %s (a %s rebuilt by the continue gets "
            .. "every player's place)", tostring(why), maybe and ("pending activity " .. tostring(act) .. " node (it may be "
            .. "a rolled head-to-head)") or (act and "pending championship" or "current node (not readable yet)"),
            maybe and "head-to-head" or "championship")
    end
end

-- (M.continueChampion / M.continuePlace: after the #97 boss intro section, they use its stage readers)

-- couch.patchGrid asks (the ChooseNextMapNode post-hook runs it first): this pick is placed by M.bossPlace
function M.bossPending()
    if not (h2hPatch ~= nil and h2hPatch.inst ~= nil and not h2hPatch.inst.done) then return false end
    -- couch-fix57: a standard pick's growth is used only by a rolled head-to-head
    if h2hPatch.maybe then return M.pickIsH2H() end
    return true
end

-- couch-fix57: the picked (or continued) recipe's active stage plays on GMV_HeadToHead
function M.pickIsH2H() return stageGmvName() == "GMV_HeadToHead" end

-- this race world is a boss race raced as instances (the plan of the pick survives the travel)
function M.bossInstanceRace()
    local ok, p = pcall(function() return U.mod("instances").plan() end)
    return ok and type(p) == "table" and p.kind == "boss"
end
-- couch-fix58: ... a rival challenge's (couchrules.rivalPlace: each player vs his own copy of the rival)
function M.rivalInstanceRace()
    local ok, p = pcall(function() return U.mod("instances").plan() end)
    return ok and type(p) == "table" and p.kind == "boss" and p.rival == true
end
-- couch-fix57: ... built from a standard / high-risk pick's head-to-head (not a championship)
function M.bossH2HRace()
    local ok, p = pcall(function() return U.mod("instances").plan() end)
    return ok and type(p) == "table" and p.kind == "boss" and p.h2h == true
end

-- D8, ChooseNextMapNode POST: the builder made [P1, boss, fill x 2n] (one-human campaign builder, 06b §1). Set g =
-- entries 2g+1 (guest g, his own pilot / class / preset / run build as in the shared race) + 2g+2 = HIS BOSS: the game's
-- own boss entry 2 cloned onto that fill entry (the whole RecipeRacerSetup, UE4SS struct copy: the builder's
-- unreflected AI build state 0x18..0x80 = the boss's AIState pacing / aggression / perfect-start and its
-- RacerArchetypeStack (Boss) come with it - the "AI settings that Lua cannot copy" are copied by the game's own struct
-- copy), its Player put back (a distinct bot PlayerState, re-dressed as the boss by instances.assignGrid: pilot,
-- style, RacerBuildState = the boss's build, abilities and crash slots applied by the spawn). Not placed = the shared
-- boss race (D7: couch.patchGrid).
function M.bossPlace(h2hKnown)
    local maybe = h2hPatch and h2hPatch.maybe == true
    local pt = h2hPatch and h2hPatch.inst
    -- (h2hKnown, couch-fix58: a CONTINUE told the head-to-head from its grid - the continued stage names no GMV)
    if maybe and not (h2hKnown == true or M.pickIsH2H()) then
        -- couch-fix57: the standard pick rolled an ordinary event: GMV_HeadToHead unused (restored next), couch.patchGrid
        if pt then pt.done = true end
        return
    end
    if maybe and not pt then
        U.log(TAG, "HEAD-TO-HEAD race (node picked, %s): GMV_HeadToHead grown +%d - each guest takes a fill entry "
            .. "(shared race vs the rival: %s)", tostring(stageGmvName()), guestCount(), tostring(h2hPatch.sharedWhy))
        U.try(TAG, M.guardBossIntro, "node picked (head-to-head)", guestCount(), true)
        return
    end
    if not pt or pt.done then return end
    pt.done = true
    local label = maybe and "HEAD-TO-HEAD INSTANCES" or "BOSS INSTANCES"
    local couch = U.mod("couch")
    local function shared(why)
        U.warn(TAG, "%s not placed (%s): FALLBACK to the shared %s race (D7)", label, tostring(why),
            maybe and "head-to-head" or "boss")
        pcall(function() U.mod("instances").reset("boss fallback") end)
        U.try(TAG, couch.patchGrid, "node picked (boss instances fallback)")
    end
    local racers = nil
    pcall(function() racers = U.giSubsystem("EventRecipeSubsystem").ActiveRecipe.RecipeState.Racers end)
    local n = U.arrayCount(racers)
    if n ~= pt.want then return shared(string.format("grid of %d, want %d", n, pt.want)) end
    local guests = {}
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    for _, e in ipairs((okJ and type(list) == "table") and list or {}) do
        local ps = nil
        pcall(function() ps = e.pc.PlayerState end)
        if U.ok(ps) then guests[#guests + 1] = { ps = ps, pnum = e.pnum, ctrlId = e.ctrlId } end
    end
    if #guests ~= pt.nG then return shared(string.format("%d guest(s) now, %d at the pick", #guests, pt.nG)) end
    local p1ps, bossP = nil, nil
    pcall(function() p1ps = U.localPlayers()[1].pc.PlayerState end)
    pcall(function() bossP = racers[2].Player end)
    local isBot = false
    pcall(function() isBot = bossP.bIsABot == true end)
    if not (U.ok(bossP) and isBot) then return shared("entry 2 is not the boss (an AI)") end
    local bossName = "?"
    pcall(function() bossName = U.objName(racers[2].Pilot) end)
    -- the clone: entry 2g+2 <- entry 2 (the game's boss entry), its own bot PlayerState kept
    local cloned, notes = 0, {}
    for g = 1, pt.nG do
        local k = pt.S * g + 2
        local keep = nil
        pcall(function() keep = racers[k].Player end)
        local okC = U.ok(keep) and pcall(function() racers[k] = racers[2] end)
        local back = okC and pcall(function() racers[k].Player = keep end)
        local now = nil
        pcall(function() now = racers[k].Player end)
        if not (U.ok(now) and U.key(now) == U.key(keep)) then
            -- never leave the boss's PlayerState twice in the recipe
            pcall(function() racers[k].Player = keep end)
            pcall(function() now = racers[k].Player end)
            if not (U.ok(now) and U.key(now) == U.key(keep)) then
                return shared(string.format("entry %d's PlayerState did not come back after the clone", k))
            end
        end
        if okC and back then cloned = cloned + 1 end
        notes[#notes + 1] = string.format("entry %d %s", k, (okC and back) and "= the boss's entry (AI build state "
            .. "cloned)" or "NOT cloned (the copy keeps the fill racer's AI tune)")
    end
    local inst = U.mod("instances")
    local okI, placed, why = pcall(inst.assignGrid, racers, guests, pt.S, p1ps,
        { kind = "boss", ev = bossName, guestPilot = "own", h2h = maybe })
    if not (okI and placed) then return shared(okI and why or placed) end
    -- each guest's own car (his class / garage preset), as the shared race gives it (couch.patchGrid)
    local cars = {}
    for g, gu in ipairs(guests) do
        local okV, note = pcall(couch.guestVehicle, racers, pt.S * g + 1, gu, false)
        cars[#cars + 1] = string.format("P%d %s", gu.pnum, okV and tostring(note) or "car not set")
    end
    U.try(TAG, function() U.mod("couchrun").applyBuilds(racers, n) end)
    if cloned < pt.nG then
        U.warn(TAG, "boss instances: %d of %d boss copies kept the fill racer's AI tune (struct clone failed): their "
            .. "pilot, car, build and abilities are the boss's", pt.nG - cloned, pt.nG)
    end
    U.log(TAG, "%s: %d copies of the %s race (%s): %s; guests' cars %s (V-BOSS-GRID)", label, 1 + pt.nG,
        maybe and "head-to-head" or "boss", bossName, table.concat(notes, ", "), table.concat(cars, ", "))
    -- couch-fix57: a head-to-head with a rival-bound story intro gets the #97 swap too (quiet when it has none)
    if maybe then U.try(TAG, M.guardBossIntro, "node picked (head-to-head)", pt.nG, true) end
end

---------------------------------------------------------------------------------------------------- D5 rival challenge
-- couch-fix58 (Jules's rule: every player races every campaign race - solo parity per player): a RIVAL CHALLENGE
-- (the head-to-head vs a named rival: the paddock's WBP_FE_Paddock_RivalChallenge accept / a rival mystery ->
-- CampaignRun:KickOffRivalChallengeEvent) gets every guest a place. Static (CL381121 0x1430cdf68 = the impl of
-- KickOffRivalChallengeEvent, exec 0x1471e9a82): a track of ActiveRivalry.Tracks (its stage GMV_HeadToHead), the run's
-- bIsPlayingRivalChallengeEvent = 1, a local recipe with EXACTLY two racers added by 0x1430d8c10 (run.playerRacer, then
-- GetActiveRival's CampaignRunRacer) - NO GridMakeup read, nothing to grow -, stored (0x142fe992e) and the travel
-- (0x142feb388) requested in the same call. A CONTINUE into a pending challenge re-runs that impl natively (0x1430dd2b2:
-- bIsPlayingRivalChallengeEvent -> 0x1430cdf68, no UFunction hook fires): placed at FRONTEND -> TRANSIT (continuePlace).
-- The post-hook (and the continue) APPEND the entries (UE4SS grows a struct TArray read at Num + 1 by one zeroed element
-- = live 2026-10-15 AppliedAffixes; the struct copy racers[k] = racers[j] copies the whole RecipeRacerSetup, its
-- unreflected AI build state with it = live boss instances): per guest g, entry 2g+1 = P1's entry (a human's
-- unreflected part) re-pointed to the guest, entry 2g+2 = THE RIVAL'S ENTRY cloned onto a spare AI PlayerState of the
-- run (an OpponentRacers player not on this grid, re-dressed as the rival by instances.assignGrid) = RIVAL INSTANCES,
-- each player vs his own copy of the rival (plan kind "boss", rival). No spare AI / CouchRivalInstances false /
-- instances off = the SHARED rival race (the guests' entries only: everyone vs the one rival).
local RIVAL_KICK = "/Script/Griffin.CampaignRun:KickOffRivalChallengeEvent"
M.RIVAL_KICK = RIVAL_KICK
local rivalPlaced = nil    -- {key = the recipe placed, inst = bool, nG}
local rivalPre = nil       -- couch-fix60: {path, ok} the rival's RacerDef loaded by the kickoff pre-hook

-- couch-fix60 (AUTO-147, live round 5 21:56:22: the harness's KickOffRivalChallengeEvent built a ONE-racer recipe,
-- GetActiveRival() nil). Static (hf2 exe): the active rival's CampaignRunRacer (0x1471edf7c, used by GetActiveRival, the
-- kickoff's builder and the offer check) = ActiveRivalry.racer (a TSoftObjectPtr<RacerDef>) RESOLVED (0x14707d0ec: a
-- soft pointer's Get, null while the asset is not in memory), then the OpponentRacers (+0x2c0) / NarrativeOpponentRacers
-- (+0x2d0) entry whose Pilot (+0x10) is that RacerDef. The game's own offer screen (WBP_FE_Paddock_RivalChallenge,
-- BP_OnActivated) LoadAsset_Blocking()s ActiveRivalry.racer before its GO RACING calls the kickoff; a kickoff without
-- that screen (the harness, any other path) finds no rival while nothing else loaded the RacerDef: [P1] alone.
-- THIS (pre-hook): the rival's RacerDef loaded first. The soft member itself is never read (finding #111): its path is
-- the rivalry def's name, CAM_Rivalry_<X> -> DA_Racer_<X> (all 11 CAM_RivalryConfig rivalries, decoded JSON).
M.RIVAL_RACER_DIR = "/Game/Griffin/Narrative/CharacterDefs/Racers/"
function M.rivalRacerPath(run)
    local rv = nil
    pcall(function() rv = run.ActiveRivalry end)
    if not U.ok(rv) then return nil end
    local id = tostring(U.objName(rv) or ""):match("^CAM_Rivalry_(.+)$")
    if not id or id == "" then return nil end
    return M.RIVAL_RACER_DIR .. "DA_Racer_" .. id .. ".DA_Racer_" .. id, id
end
function M.rivalPreload(why)
    rivalPre = nil
    local run = campaignRun()
    if not run then return nil end
    local path, id = M.rivalRacerPath(run)
    if not path then
        U.warn(TAG, "RIVAL CHALLENGE (%s): no active rivalry name to load its racer from (AUTO-147)", tostring(why))
        return nil
    end
    local o = U.obj(path)
    rivalPre = { path = path, id = id, ok = U.ok(o) }
    U.log(TAG, "RIVAL CHALLENGE (%s): the rival's RacerDef DA_Racer_%s %s before the kickoff (the game finds the rival by "
        .. "it, as its own offer screen loads it) (AUTO-147)", tostring(why), id, rivalPre.ok and "in memory" or "NOT loadable")
    return rivalPre.ok
end
M._rivalPre = function() return rivalPre end

-- the run's AI PlayerStates a rival copy may wear: OpponentRacers' players (bots) not on this grid, not protected
local function spareBots(run, racers, need, rival)
    local have = {}
    for i = 1, U.arrayCount(racers) do
        pcall(function() local ps = racers[i].Player; if U.ok(ps) then have[U.key(ps)] = true end end)
    end
    local out = {}
    for _, field in ipairs({ "OpponentRacers", "NarrativeOpponentRacers" }) do
        pcall(function()
            local arr = run[field]
            for i = 1, U.arrayCount(arr) do
                if #out >= need then return end
                local ps = nil
                pcall(function() ps = arr[i].Player end)
                if U.ok(ps) and not have[U.key(ps)] then
                    local bot = false
                    pcall(function() bot = ps.bIsABot == true end)
                    if bot and not M.protectedEntry(ps, rival) then
                        have[U.key(ps)] = true
                        out[#out + 1] = ps
                    end
                end
            end
        end)
    end
    return out
end

-- one appended entry k = a struct copy of entry src, Player = ps -> ok, why
local function appendEntry(racers, k, src, ps)
    if U.arrayCount(racers) ~= k - 1 then return false, string.format("grid of %d, entry %d not next", U.arrayCount(racers), k) end
    local okG = pcall(function() local _ = racers[k] end)                  -- UE4SS: a read at Num + 1 appends one
    if not okG or U.arrayCount(racers) ~= k then return false, "the grid did not grow (entry " .. k .. ")" end
    local okC = pcall(function() racers[k] = racers[src] end)
    local okP = pcall(function() racers[k].Player = ps end)
    local now = nil
    pcall(function() now = racers[k].Player end)
    if not (okP and U.ok(now) and U.key(now) == U.key(ps)) then
        return false, string.format("entry %d's PlayerState not written", k)
    end
    return true, okC and "copied" or "NOT copied (zeroed entry)"
end

-- KickOffRivalChallengeEvent post / CONTINUE -> placed guests (0 = none)
function M.rivalPlace(why)
    if opt("CouchRivalRaces", true) ~= true or opt("CouchCampaign", true) ~= true then return 0 end
    local run = campaignRun()
    if not (run and isRivalRace(run)) then return 0 end
    local guests = {}
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    for _, e in ipairs((okJ and type(list) == "table") and list or {}) do
        local ps = nil
        pcall(function() ps = e.pc.PlayerState end)
        if U.ok(ps) then guests[#guests + 1] = { ps = ps, pnum = e.pnum, ctrlId = e.ctrlId } end
    end
    local nG = #guests
    if nG < 1 then return 0 end
    local rs = U.giSubsystem("EventRecipeSubsystem")
    local rc, racers = nil, nil
    pcall(function() rc = rs.ActiveRecipe; racers = rc.RecipeState.Racers end)
    local n = U.arrayCount(racers)
    local key = U.ok(rc) and U.key(rc) or nil
    if rivalPlaced and rivalPlaced.key == key and key ~= nil then return 0 end      -- this recipe is placed already
    local p1ps, rivalPs = nil, nil
    pcall(function() p1ps = U.localPlayers()[1].pc.PlayerState end)
    -- couch-fix60: never an entry past Num (UE4SS appends a zeroed struct element on a read at Num + 1: on the live
    -- 1-racer recipe the old read of racers[2] would have grown it by a blank racer)
    if n >= 2 then pcall(function() rivalPs = racers[2].Player end) end
    local first, isBot = nil, false
    if n >= 1 then pcall(function() first = racers[1].Player end) end
    pcall(function() isBot = rivalPs.bIsABot == true end)
    if n == 1 and U.ok(first) and U.ok(p1ps) and U.key(first) == U.key(p1ps) then
        -- couch-fix60 (AUTO-147): the live shape of a kickoff that found no rival (see M.rivalPreload): [P1] alone. No
        -- rival entry exists to copy (its unreflected AI build state is the game's): the guests cannot be given a rival.
        local pre = rivalPre
        U.warn(TAG, "RIVAL CHALLENGE (%s): the game built [P1] alone - it found no rival (GetActiveRival nil: %s): the "
            .. "guests sit it out (AUTO-147)", tostring(why), pre == nil and "the kickoff pre-hook did not run"
            or (pre.ok and ("DA_Racer_" .. tostring(pre.id) .. " was loaded: the rival is on neither opponent list")
            or ("DA_Racer_" .. tostring(pre.id) .. " could not be loaded")))
        return 0
    end
    if n ~= 2 or not (U.ok(first) and U.ok(p1ps) and U.key(first) == U.key(p1ps)) or not (U.ok(rivalPs) and isBot) then
        U.warn(TAG, "RIVAL CHALLENGE (%s): the grid is not [P1, rival] (%d racer(s)): left alone - the guests sit it out",
            tostring(why), n)
        return 0
    end
    local rivalName = "?"
    pcall(function() rivalName = U.objName(racers[2].Pilot) end)
    pcall(function() local nm = rivalPs:GetPlayerName():ToString(); if nm ~= "" then rivalName = nm end end)
    local inst = nil
    pcall(function() inst = U.mod("instances") end)
    local instWhy = nil
    if opt("CouchRivalInstances", true) ~= true then instWhy = "CouchRivalInstances off"
    elseif not (type(inst) == "table" and inst.enabled and inst.enabled()) then instWhy = "CouchMissionInstances off"
    else
        local want, _, gwhy = inst.gridFor(2, 1, nG, "rival challenge")
        if not want then instWhy = gwhy end
    end
    local spares = {}
    if not instWhy then
        local active = nil
        pcall(function() active = run:GetActiveRival() end)
        spares = spareBots(run, racers, nG, U.ok(active) and active or rivalPs)
        if #spares < nG then
            instWhy = string.format("%d spare AI PlayerState(s) of the run for %d rival copies", #spares, nG)
        end
    end
    pcall(function() U.mod("instances").reset("rival challenge") end)
    local couch = U.mod("couch")
    local notes, cars = {}, {}
    local useInst = instWhy == nil
    -- the guests' entries first (P1's entry: a human's), then (instances) each guest's rival copy
    for g, gu in ipairs(guests) do
        local k = U.arrayCount(racers) + 1
        local okA, how = appendEntry(racers, k, 1, gu.ps)
        if not okA then
            U.warn(TAG, "RIVAL CHALLENGE (%s): P%d's entry %d not added (%s) - he sits it out", tostring(why), gu.pnum, k,
                tostring(how))
            useInst = false
            break
        end
        pcall(function() local own = gu.ps.Pilot; if U.ok(own) then racers[k].Pilot = own end end)
        if useInst then
            local okR, rhow = appendEntry(racers, k + 1, 2, spares[g])
            if not okR then
                -- (a copy that grew but holds no PlayerState is never left behind: the spare written again)
                if U.arrayCount(racers) == k + 1 then pcall(function() racers[k + 1].Player = spares[g] end) end
                U.warn(TAG, "RIVAL CHALLENGE (%s): P%d's rival copy (entry %d) not added (%s): FALLBACK to the shared "
                    .. "rival race", tostring(why), gu.pnum, k + 1, tostring(rhow))
                useInst = false
            else
                notes[#notes + 1] = string.format("entry %d = the rival's entry %s", k + 1, rhow == "copied"
                    and "(AI build state cloned)" or rhow)
            end
        end
    end
    n = U.arrayCount(racers)
    local placedN = 0
    local planned = false
    if useInst then
        local okI, placed, iwhy = pcall(inst.assignGrid, racers, guests, 2, p1ps,
            { kind = "boss", ev = rivalName, guestPilot = "own", rival = true })
        if okI and placed then planned = true else instWhy = tostring(okI and iwhy or placed) end
    end
    for _, gu in ipairs(guests) do
        local idx = nil
        for i = 1, n do
            pcall(function() if U.key(racers[i].Player) == U.key(gu.ps) then idx = i end end)
        end
        if idx then
            placedN = placedN + 1
            local okV, note = pcall(couch.guestVehicle, racers, idx, gu, false)
            cars[#cars + 1] = string.format("P%d entry %d %s", gu.pnum, idx, okV and tostring(note) or "car not set")
        end
    end
    if placedN == 0 then return 0 end
    U.try(TAG, function() U.mod("couchrun").applyBuilds(racers, n) end)
    rivalPlaced = { key = key, inst = planned, nG = placedN }
    if planned then
        U.log(TAG, "RIVAL CHALLENGE (%s): RIVAL INSTANCES - %d copies of the rival race vs %s (each player vs his own "
            .. "rival; the challenge is the team's: won if any player beats his own rival): %s; cars %s (V-RIVAL-GRID)",
            tostring(why), 1 + placedN, rivalName, table.concat(notes, ", "), table.concat(cars, ", "))
    else
        if inst then pcall(function() inst.reset("rival challenge (shared)") end) end
        U.log(TAG, "RIVAL CHALLENGE (%s): SHARED rival race - %d player(s) vs %s (%s); cars %s (V-RIVAL-GRID)",
            tostring(why), 1 + placedN, rivalName, tostring(instWhy or "instances not placed"), table.concat(cars, ", "))
    end
    U.try(TAG, M.guardBossIntro, tostring(why) .. " (rival challenge)", placedN, true)
    return placedN
end
M._rivalPlaced = function() return rivalPlaced end
M._rivalForget = function() rivalPlaced = nil end

---------------------------------------------------------------------------------------------------- #97 boss intro
-- FREEZE (playtest 2026-10-18 09:32:56, no dump, the process alive): the act II championship (EVT_WHP_SHORTBOSS_FAIR,
-- Kestar, 1 boss + P1 + P2) froze the game thread ~5.8 s after its race world came up, at the end of its 5.0 s intro
-- shot (recording session-112429 at 508.0 s: the last moving frame shows the "STADIUM SHOWDOWN" title; the log's last
-- line 09:32:56.82). Static facts (CL382801 exe + JMAP):
--   * the boss intros are the ONLY chains in the game data with vehicle bindings of type Player (13) AND Rival (14):
--     CINC_TrackIntro_WHP_MIDBOSS (act I, Sebulba) and CINC_TrackIntro_WHP_FINAL_BOSS_TOUR2 (act II, Kestar)
--     (story sequences LS_ACT01_SC10 / LS_ACT02_SC20_Layout, "PlayerVehicle" + "RivalVehicle" with HidePilot) - all
--     102 CinematicChain packages of the hf2 paks decoded (cue4cli); CINC_TrackIntro_Grid_1v1 / Plane_1v1 only use
--     Rival as a camera ORIGIN (no car possessed).
--   * the binding resolver (0x142fc5b72: 1-12 RacePosition, 13 Player, 14 Rival) resolves Rival as
--     RacingGameState.Rival (+0x3c8, never set: "Rival selected for the transform of a cinematic but no rivals are
--     implemented yet. Attaching to the last pawn in the list") -> the LAST entry of RacingGameState.Racers (+0x348),
--     or Racers[0] when that is the asking player's own car. Solo: [P1, boss] -> the boss.
--   * every local PC plays the race intro chain itself (couch.lua skip notes): with a guest in the grid [P1, boss, P2]
--     P1's chain binds P2's car as its RivalVehicle while P2's chain binds that same car as its PlayerVehicle (and P1's
--     as its Rival): two story sequences possess the same two player-driven cars, crosswise. Never seen in solo, never
--     played in couch before (the 2026-10-14 act I qualifier had no intro); every other intro of the session (3 played
--     out, 7 skipped) has no vehicle bindings. The freeze is at that chain's end (bindings restored / destroyed).
-- FIX (cfg.CouchBossIntroSwap, default true): a championship picked with guests gets the TRACK's own intro chain in its
-- event recipe (each stage's FRaceEventInstance.IntroCinematic = its TrackDef.IntroCinematic - couch-fix49: the STAGE's
-- member, below; act II: CINC_TrackIntro_WHP_LOOP_A, the
-- generic stadium fly-through, no bindings; act I, whose track chain IS the boss intro: that same stadium chain,
-- M.BOSS_INTRO_FALLBACK) - per recipe, no asset changed, nothing to restore. The promoter's intro
-- line (the event's IntroDialogueTrigger) still plays. Checked again at the race world (PRERACE); if the swap could not
-- be made (no track chain), RacingGameState.Rival is pinned to the boss there, so every chain binds the boss as solo
-- does (fallback, logged).
M.RIVAL_BOUND_INTROS = { CINC_TrackIntro_WHP_MIDBOSS = true, CINC_TrackIntro_WHP_FINAL_BOSS_TOUR2 = true }
-- both boss tracks are on L_Whippet_Loop_A; the generic stadium intro (TRAK_WHP_SHORTBOSS_FAIR's own chain, no
-- bindings) when the track's chain is the boss intro itself (act I) or missing
M.BOSS_INTRO_FALLBACK = "/Game/Griffin/Cinematics/Events/Whippet/CINC_TrackIntro_WHP_LOOP_A.CINC_TrackIntro_WHP_LOOP_A"
local bossPick = nil       -- {guests} between ChooseNextMapNode pre and post (a championship picked with guests)
local bossRace = nil       -- {from, to, swapped, why} the last couch championship's intro decision (PRERACE re-check)

-- pure (sim): -> swap?, why. s = {on, guests, kind, intro (chain name), track (the track's chain name), bound (set)}
function M.bossIntroSwapWanted(s)
    if s.on == false then return false, "CouchBossIntroSwap off" end
    if (tonumber(s.guests) or 0) < 1 then return false, "no guest" end
    if s.kind ~= "champion" then return false, "not a championship" end
    local bound = s.bound or M.RIVAL_BOUND_INTROS
    if not (s.intro and bound[s.intro]) then return false, "intro " .. tostring(s.intro) .. " has no Rival binding" end
    if not s.track or s.track == "" then return false, "the track has no intro chain of its own" end
    if s.track == s.intro then return false, "the track's chain is the boss intro" end
    return true, "Rival-bound boss intro with " .. tostring(s.guests) .. " guest(s)"
end

local function activeRecipe()
    local r = nil
    pcall(function() r = U.giSubsystem("EventRecipeSubsystem").ActiveRecipe end)
    return U.ok(r) and r or nil
end

-- ChooseNextMapNode PRE: remember a championship pick with guests (the recipe is built inside the call)
function M.bossPickPre(node)
    bossPick = nil
    local act = pickedActivity(node)
    if act ~= M.CHAMPION_ACTIVITY then return end
    local n = guestCount()
    if n < 1 or opt("CouchCampaign", true) ~= true then return end
    bossPick = { guests = n }
end

-- couch-fix49 (AUTO-126, live round 2 2026-10-18 13:48:54): the swap NEVER ran live. IntroCinematic / TrackDef are
-- members of the recipe's STAGE (FRaceEventInstance, @0x2C8 / @0x20), not of UEventRecipeInstance: the old read
-- rc.IntroCinematic returned nothing, the pick logged "boss intro nil -> nil" and P2's chain played
-- CINC_TrackIntro_WHP_FINAL_BOSS_TOUR2 (run 42 skip line 14:03:36 "also skipped: P2's CINC_TrackIntro_WHP_FINAL_BOSS_TOUR2").
-- Run 41's pick (not skipped) hung exactly as #97 did: last lines "P1 HUD not found yet" + "msg WrongWay ... local
-- player 1 without a HUD" ~6 s into the race world, the frozen frame the STADIUM SHOWDOWN title, then the game's "Out of
-- video memory trying to allocate a rendering resource" + "Application Hang Detected" (VRAM 8.7 of 16.3 GB, no NVRM
-- line: not the card running out). The intro is read and written on every stage of the subsystem's recipe
-- (ActiveRecipe.Recipe.EventStages[i]) and, in the race world, on the RacingGameState's copy (EventRecipe @0x3F8).
-- -> list of { st = the stage struct, i, intro = chain or nil, track = the stage track's chain or nil }
local function stagesOf(recipeStruct)
    local out = {}
    pcall(function()
        local stages = recipeStruct.EventStages
        for i = 1, U.arrayCount(stages) do
            local st = stages[i]
            local e = { st = st, i = i }
            pcall(function() local c = st.IntroCinematic; if U.ok(c) then e.intro = c end end)
            pcall(function() local c = st.TrackDef.IntroCinematic; if U.ok(c) then e.track = c end end)
            out[#out + 1] = e
        end
    end)
    return out
end
M._stagesOf = stagesOf

-- the swap on one recipe (a FEventRecipe struct: the subsystem's ActiveRecipe.Recipe or RacingGameState.EventRecipe)
-- -> swapped (bool: every boss-bound stage now holds a binding-free chain), why, from, to, bound (stages that held one)
local function swapStages(recipeStruct, guests)
    local on = opt("CouchBossIntroSwap", true) ~= false
    local swapped, bound, why, from, to = true, 0, nil, nil, nil
    local list = stagesOf(recipeStruct)
    if #list == 0 then return false, "no event stage in the recipe", nil, nil, 0 end
    for _, e in ipairs(list) do
        local introName = e.intro and U.objName(e.intro) or nil
        local track, tn = e.track, e.track and U.objName(e.track) or nil
        -- act I: the boss intro IS its track's intro (TRAK_WHP_Loop_A_MID_BOSS): the stadium's generic fly-through
        if introName and M.RIVAL_BOUND_INTROS[introName] and (tn == nil or M.RIVAL_BOUND_INTROS[tn]) then
            local fb = U.obj(M.BOSS_INTRO_FALLBACK)
            local fn = U.ok(fb) and U.objName(fb) or ""
            if fn ~= "" and not M.RIVAL_BOUND_INTROS[fn] then track, tn = fb, fn end
        end
        local yes, reason = M.bossIntroSwapWanted({ on = on, guests = guests, kind = "champion", intro = introName,
                                                    track = tn })
        why = why or reason
        if introName and M.RIVAL_BOUND_INTROS[introName] then
            bound = bound + 1
            from, to, why = introName, tn, reason
            local ok = false
            if yes then
                pcall(function() e.st.IntroCinematic = track end)
                local now = nil
                pcall(function() now = U.objName(e.st.IntroCinematic) end)
                ok = now == tn
            end
            swapped = swapped and ok
        elseif from == nil then
            from = introName
        end
    end
    if bound == 0 then return false, why or "no stage holds a boss intro", from, to, 0 end
    return swapped, why, from, to, bound
end

-- the swap on the active recipe -> swapped?, why (logged). quiet (couch-fix56: a continue / any start that is not
-- known to be a championship): a recipe without a boss intro is left alone and leaves no decision for PRERACE
function M.guardBossIntro(why, guests, quiet)
    local rc = activeRecipe()
    if not rc then return false, "no active recipe" end
    local rec = nil
    pcall(function() rec = rc.Recipe end)
    local ok, reason, from, to, bound = swapStages(rec, guests)
    if bound == 0 and quiet then return false, reason end
    bossRace = { from = from, to = to, swapped = ok, why = reason, guests = guests }
    if bound == 0 then return false, reason end
    if not ok then
        if opt("CouchBossIntroSwap", true) ~= false then
            U.warn(TAG, "#97 boss intro %s NOT swapped (%s, %s): the race world pins the Rival binding to the boss",
                tostring(from), tostring(reason), tostring(why))
        end
        return false, reason
    end
    U.log(TAG, "#97 boss intro (%s): %s -> %s ok (%d stage(s); %s; the story intro binds the player's and the rival's "
        .. "car in every local player's own chain: with guests it crosses two human cars)", tostring(why), tostring(from),
        tostring(to), bound, tostring(reason))
    return true, reason
end

-- ChooseNextMapNode POST
function M.bossPickPost()
    local p = bossPick
    bossPick = nil
    if not p then return end
    M.guardBossIntro("node picked", p.guests)
end

-- the boss PlayerState of a championship grid: the AI flagged antagonist / rival, else the only AI
local function bossPs(gs)
    local bots, flagged = {}, nil
    pcall(function()
        local racers = gs.Racers
        for i = 1, U.arrayCount(racers) do
            local ps = racers[i]
            if U.ok(ps) and ps.bIsABot == true then
                bots[#bots + 1] = ps
                if not flagged and (ps.bIsAntagonist == true or ps.bIsRival == true) then flagged = ps end
            end
        end
    end)
    if flagged then return flagged end
    if #bots == 1 then return bots[1] end
    return nil
end

-- race world (PRERACE): the recipe again (a rebuilt recipe gets the swap too) AND the race world's own copy
-- (RacingGameState.EventRecipe: the stage the race plays); a boss intro left in place = pin the Rival binding to the
-- boss (solo's binding)
-- couch-fix56 (AUTO-138: the CONTINUE's race had no decision at all - no "#97" line, the boss intro played, "Out of
-- video memory" + exit): UNCONDITIONAL with 2+ local players - whatever started the race (a pick, a continue, the
-- game's tile, a paddock kickoff, a resume), a Rival-bound boss intro in the recipe or the race world's copy is
-- swapped here; with no earlier decision and no boss intro nothing is logged.
local function localGuests()
    local n = guestCount()
    pcall(function() n = math.max(n, #U.localPlayers() - 1) end)
    return n
end
M._localGuests = localGuests

function M.bossIntroCheck(why)
    local b = bossRace
    bossRace = nil
    local unplanned = b == nil
    if unplanned then
        local g = localGuests()
        if g < 1 then return end
        b = { guests = g, why = "no pick / continue decision (AUTO-138)" }
    end
    local gs = U.gs()
    local recs = {}
    local rc = activeRecipe()
    if rc then pcall(function() recs[#recs + 1] = { "recipe", rc.Recipe } end) end
    if U.ok(gs) then pcall(function() recs[#recs + 1] = { "race world", gs.EventRecipe } end) end
    local left, cur, fixed = {}, nil, {}
    for _, r in ipairs(recs) do
        for _, e in ipairs(stagesOf(r[2])) do
            local nm = e.intro and U.objName(e.intro) or nil
            cur = cur or nm
            if nm and M.RIVAL_BOUND_INTROS[nm] then
                if opt("CouchBossIntroSwap", true) == false then
                    U.log(TAG, "#97 race world (%s): boss intro %s kept (CouchBossIntroSwap off)", tostring(why), nm)
                    return
                end
                local ok, _, from, to = swapStages(r[2], b.guests)
                if ok then
                    fixed[#fixed + 1] = string.format("%s %s -> %s", r[1], tostring(from), tostring(to))
                else
                    left[#left + 1] = r[1] .. " " .. nm
                end
                break
            end
        end
    end
    if #fixed > 0 then
        U.log(TAG, "#97 race world (%s): the boss intro swapped %s: %s", tostring(why), unplanned and "HERE (no node "
            .. "pick / CONTINUE swapped it: AUTO-138)" or "again", table.concat(fixed, ", "))
    end
    if #left > 0 then
        local boss = U.ok(gs) and bossPs(gs) or nil
        local pinned = false
        if boss then
            local had = nil
            pcall(function() had = gs.Rival end)
            if not U.ok(had) then pinned = pcall(function() gs.Rival = boss end) end
        end
        U.warn(TAG, "#97 boss intro still in %s (%s): RacingGameState.Rival %s", table.concat(left, ", "), tostring(why),
            pinned and "pinned to the boss (every chain binds the boss, as solo)" or "NOT pinned (no single boss PS / "
            .. "already set)")
        return
    end
    if #fixed > 0 or unplanned then return end
    U.log(TAG, "#97 race world (%s): intro %s (boss intro %s -> %s, %s)", tostring(why), tostring(cur), tostring(b.from),
        tostring(b.to), b.swapped and "swapped at the pick" or tostring(b.why))
end
M._bossRace = function() return bossRace end
M._forget = function() bossRace, bossPick = nil, nil end                  -- sims: a new process (memory gone)

-- couch-fix56 (AUTO-138, live round 3 17:18:46, UE4SS-round3f-boss-oom.log): the couch page's CONTINUE into the
-- pending Derven Acos championship grew GMV_HeadToHead (BOSS INSTANCES 2 x 2) and the builder DID use it (4 racers:
-- P1, the boss, 2 fills), but at FRONTEND -> TRANSIT the stage read "the recipe is , not a championship": the rebuilt
-- (continued) recipe's stage holds no readable GameModeVariant (an empty name - only a PICKED node's recipe names its
-- GMV). The grid went to couch.patchGrid (one shared 4-car race, P2 on a fill entry), the boss intro stayed
-- (guardBossIntro ran only in the championship branch) -> the #97 freeze family: "Out of video memory" + exit. NOW a
-- championship is told by any of: the stage's GMV is GMV_HeadToHead; the stage plays a Rival-bound boss intro (only
-- the boss events have one); the run's current node reads ChampionEvent now (the run is loaded at the transit); the
-- GMV is unreadable AND the grid is exactly the grown head-to-head's size with an AI on entry 2. A stage naming another
-- GMV is no championship (as before). -> isChamp, why
function M.continueChampion(p, gmv)
    if gmv == "GMV_HeadToHead" then return true, "the stage's GMV is GMV_HeadToHead" end
    if gmv ~= nil and gmv ~= "" then return false, "the stage's GMV is " .. tostring(gmv) end
    local rc = activeRecipe()
    if rc then
        local rec = nil
        pcall(function() rec = rc.Recipe end)
        for _, e in ipairs(stagesOf(rec)) do
            local nm = e.intro and U.objName(e.intro) or nil
            if nm and M.RIVAL_BOUND_INTROS[nm] then return true, "the stage plays the boss intro " .. nm end
        end
    end
    local run = campaignRun()
    local nd = run and currentNode(run) or nil
    local act = nd and pickedActivity(nd) or nil
    if act == M.CHAMPION_ACTIVITY then return true, "the run's current node is a championship" end
    -- couch-fix58 (a): a standard / high-risk node continued: a head-to-head only by its grid (below; the other
    -- events' grids are 5 or 12 racers, a grown head-to-head's 4 / 6 / 8)
    local h2hNode = act ~= nil and M.H2H_ACTIVITY[act] == true
    if act ~= nil and not h2hNode then return false, "the run's current node is activity " .. tostring(act) end
    local racers, n, bot = nil, 0, false
    pcall(function() racers = rc.RecipeState.Racers end)
    n = U.arrayCount(racers)
    pcall(function() bot = racers[2].Player.bIsABot == true end)
    local want = p and (p.inst and p.inst.want or ((p.orig or 1) + 1 + guestCount())) or nil
    if want and n == want and bot then
        if h2hNode then
            return true, string.format("the run's current node is activity %d and its grid is the grown head-to-head's "
                .. "(%d racers, an AI on entry 2): a rolled head-to-head", act, n), true
        end
        return true, string.format("the grid is the grown head-to-head's (%d racers, an AI on entry 2)", n)
    end
    if h2hNode then return false, "the run's current node is activity " .. tostring(act) end
    return false, string.format("no championship sign (GMV unreadable, grid of %d, want %s)", n, tostring(want))
end

-- couch.lua, FRONTEND -> TRANSIT with an active run -> true when the continue's grid was handled here
function M.continuePlace(why)
    local p = h2hPatch
    local n = guestCount()
    -- couch-fix58 (b): a CONTINUE into a pending RIVAL CHALLENGE (the native continue re-ran its kickoff: [P1, rival],
    -- no hook) - every guest's place (rival instances / the shared rival race); a grown head-to-head is not its grid
    local run = campaignRun()
    if n >= 1 and run and isRivalRace(run) then
        if p then U.try(TAG, M.restoreChampion) end
        local okR, placed = pcall(M.rivalPlace, tostring(why))
        if not okR then U.warn(TAG, "rival challenge continue: %s", tostring(placed)) end
        return true
    end
    if not (p and p.cont) then
        -- couch-fix56: a continue the arm never saw (no grown grid): the boss intro is still swapped (#97, any path)
        if n >= 1 then U.try(TAG, M.guardBossIntro, tostring(why), n, true) end
        return false
    end
    local gmv = stageGmvName()
    local champ, how, rolled = M.continueChampion(p, gmv)
    local handled = false
    -- couch-fix58 (a): a continued standard / high-risk node that IS a head-to-head (its GMV, or its grid) is placed
    -- like fix57's pick: head-to-head instances (each player vs his own rival copy) + the quiet #97 guard
    local h2h = champ and (p.maybe == true or rolled == true)
    if h2h then p.maybe = true end
    if champ then
        if h2h then
            U.log(TAG, "campaign CONTINUE (%s): a HEAD-TO-HEAD (%s; the continued stage's GMV reads %q) - placed as "
                .. "head-to-head instances (fix58)", tostring(why), tostring(how), tostring(gmv))
        elseif gmv ~= "GMV_HeadToHead" then
            U.log(TAG, "campaign CONTINUE (%s): a championship (%s; the continued stage's GMV reads %q) - placed as one "
                .. "(AUTO-138)", tostring(why), tostring(how), tostring(gmv))
        end
        if p.inst then
            U.try(TAG, M.bossPlace, true)
        elseif h2h then
            U.log(TAG, "campaign CONTINUE (%s): head-to-head grown +%d - each guest takes a fill entry (shared race vs "
                .. "the rival: %s)", tostring(why), n, tostring(p.sharedWhy))
            U.try(TAG, function() U.mod("couch").patchGrid(tostring(why) .. " (shared head-to-head)", true) end)
        else
            U.try(TAG, function() U.mod("couch").patchGrid(tostring(why) .. " (shared boss race)", true) end)
        end
        handled = true
        U.try(TAG, M.restoreChampion)
        U.try(TAG, M.guardBossIntro, tostring(why), n, h2h)
    else
        U.log(TAG, "campaign CONTINUE (%s): the recipe is %s, not a championship (%s): GMV_HeadToHead put back",
            tostring(why), tostring(gmv), tostring(how))
        U.try(TAG, M.restoreChampion)
        U.try(TAG, M.guardBossIntro, tostring(why), n, true)
    end
    return handled
end

-- D6: a mystery race's grid (all-PC builder): every guest once, then his run build
function M.checkMysteryGrid()
    local rs = U.giSubsystem("EventRecipeSubsystem")
    if not (U.ok(rs) and U.ok(rs.ActiveRecipe)) then return end
    local racers = rs.ActiveRecipe.RecipeState.Racers
    local n = racers:GetArrayNum()
    local count = {}
    for i = 1, n do
        local ps = racers[i].Player
        if U.ok(ps) then count[U.key(ps)] = (count[U.key(ps)] or 0) + 1 end
    end
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    if not (ok and type(list) == "table") or #list == 0 then return end
    local notes, missing = {}, 0
    for _, e in ipairs(list) do
        local ps = nil
        pcall(function() ps = e.pc.PlayerState end)
        local c = U.ok(ps) and (count[U.key(ps)] or 0) or 0
        if c == 0 then missing = missing + 1 end
        notes[#notes + 1] = string.format("P%d x%d", e.pnum, c)
        if c > 1 then U.warn(TAG, "mystery grid: P%d holds %d entries", e.pnum, c) end
    end
    U.log(TAG, "mystery race grid (%d racers): %s", n, table.concat(notes, ", "))
    if missing < #list then U.try(TAG, function() U.mod("couchrun").applyBuilds(racers, n) end) end
end

---------------------------------------------------------------------------------------------------- sit-outs
-- race_enter: a guest without a grid entry (rival challenge, a patch that found no AI entry) watches P1's race
function M.sitOutCheck(why)
    sitOut = {}
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if not (okC and couch == true) then return 0 end
    local run = campaignRun()
    local rival = run and isRivalRace(run) or false
    local have, n = {}, 0
    pcall(function()
        local racers = U.giSubsystem("EventRecipeSubsystem").ActiveRecipe.RecipeState.Racers
        n = racers:GetArrayNum()
        for i = 1, n do local ps = racers[i].Player; if U.ok(ps) then have[U.key(ps)] = true end end
    end)
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    if not (ok and type(list) == "table") then return 0 end
    local out = 0
    for _, e in ipairs(list) do
        local ps = nil
        pcall(function() ps = e.pc.PlayerState end)
        local inGrid = U.ok(ps) and have[U.key(ps)] == true
        -- couch-fix58: a rival challenge sits out only the guests rivalPlace gave no entry (was: every guest)
        if (rival and not inGrid) or (n > 0 and not inGrid) then
            sitOut[e.ctrlId] = true
            out = out + 1
        end
    end
    if out > 0 then
        St.race.singleView = true
        -- #29: a couch sit-out keeps P1's own HUD (hud.lua's P1 clone, uxsplit's routing) exactly like a dormant player:
        -- the game's own HUD belongs to the LAST local PC = the carless guest, whose owner-pawn parts (the critical-
        -- malfunction QTE WBP_CriticalMalfunction, crash pips) bind no car - live 18:54 a CRITICAL MALFUNCTION / RECOVER
        -- prompt stood on P1's screen from the start and P1's B (his own car: no malfunction) could not clear it
        St.race.sitOut = true
        U.log(TAG, "%d guest(s) sit this race out (%s%s): one view, everyone watches P1", out,
            rival and "rival challenge" or "no grid entry", why and (", " .. tostring(why)) or "")
    end
    return out
end
function M.isSittingOut(ctrlId) return sitOut[ctrlId] == true end

-- couch-fix30 (audit 12 #5): a human's REAL result when this world's last ruled race rewrote his REC (the final-event
-- swap) -> pos, wrecked, fail; nil = his REC is his own (read it). ps = his PlayerState.
function M.realResult(ps)
    local L = M.last
    if not (L and L.gen == St.worldGen and type(L.real) == "table") or not U.ok(ps) then return nil end
    local r = L.real[U.key(ps)]
    if not r then return nil end
    return r.pos, r.wrecked, r.fail
end
-- a human's own result of this world's last ruled race (his edge snapshot: place, wrecked, eliminated, fail bits),
-- by ctrlId - the per-player data a P1-own-place economy (audit 12 #6, Q1) or a best-verdict field test (#4, Q5)
-- reads (couch-fix35: the OWN PLACE economy, ownEconomy above, reads the live R.humans snapshots the same way)
function M.ownResult(ctrlId)
    local L = M.last
    if not (L and L.gen == St.worldGen) or ctrlId == nil then return nil end
    for _, h in ipairs(L.humans or {}) do
        if h.ctrlId == ctrlId then return h.snap end
    end
    return nil
end

-- #81: the place a guest's WRECK in an elimination race is booked at (couchrun.onRaceEnd), or nil (no such wreck).
-- Only for a wreck whose token the team kept (refunded: another human had not wrecked) - a wreck that cost the team
-- its token stays the native single-player wreck (DNF, no own round). -> place, why
function M.wreckOutPlace(ctrlId)
    local L = M.last
    if R then L = { activity = R.activity, humans = R.humans, gen = St.worldGen } end   -- not ruled yet: the live race
    if not (L and L.gen == St.worldGen and M.isElimination(L.activity)) or ctrlId == nil then return nil end
    for _, h in ipairs(L.humans or {}) do
        if h.ctrlId == ctrlId and not h.isP1 then
            local sn = h.snap
            if not (sn and sn.wrecked and tonumber(sn.outPlace)) then return nil end
            if not h.wreckRefunded then return nil, "his wreck cost the team its token" end
            return math.floor(sn.outPlace), string.format("wrecked with %d racer(s) left: out in place %d, like an "
                .. "elimination", sn.outPlace, sn.outPlace)
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------- init
function M.status()
    if not R then return "couchrules: idle" .. (M.last and (" (last: " .. tostring(M.last.kind) .. " by P"
        .. tostring(M.last.carrier) .. ")") or "") end
    return string.format("couchrules: %s rule %s gate %s booked %s refunds %d", R.kind, R.rule,
        R.gate and (R.gateClosed and "closed" or "open") or "off", R.booked and ("P" .. R.booked.pnum) or "-",
        #R.refunds)
end

local function drop(why)
    if R then U.try(TAG, finish, why) end
    R = nil
end

-- N5: FinishRacer's ProcessEvent of the racer's own Client_OnThisRacerFinished (every racer: AI too, cheap reject)
M.FINISH_FN = "/Script/Griffin.PlayerRaceEventComponent:Client_OnThisRacerFinished"
M.hookFires = 0
function M.onRacerOut(recParam)
    if St.phase ~= "RACING" then return end
    if not R and M._begun then return end                      -- not a ruled race
    local rec = U.unwrap(recParam)
    if not U.ok(rec) then return end
    if not R then U.try(TAG, M.fastTick, true) end             -- the first frame of the race: begin() first
    if not R then return end
    local k, who = U.key(rec), nil
    for _, h in ipairs(R.humans) do
        if not who and U.ok(h.rec) and U.key(h.rec) == k then who = h end
    end
    if not who or who.outHook then return end
    who.outHook = true
    M.hookFires = M.hookFires + 1
    local wasClosed = R.gate and R.gateClosed
    M.fastTick(true)
    if wasClosed and R and not R.gate then
        U.log(TAG, "P%s out (FinishRacer hook, place %s): last human - the result gate released before the race end",
            tostring(who.pnum), tostring(who.pos))
    end
end

M.CONTINUE_FNS = { "/Script/Griffin.FrontEndGameMode:CampaignSelected",
                   "/Script/Griffin.FrontEndGameMode:TravelToContinueRaceEvent",
                   "/Script/Griffin.CampaignSubsystem:ContinueCurrentMapNodeEvent" }
local REPAIR_PHASES = { TRANSIT = true, LOADING = true, PRERACE = true, POSTRACE = true, OTHER = true }
function M.init()
    St.on("race_enter", TAG, function(new, from) U.try(TAG, M.sitOutCheck, "race enter from " .. tostring(from)) end)
    St.on("phase", TAG, function(new, old)
        if new == "RACING" then M._begun = false end
        if old == "RACING" and new ~= "RACING" then drop("phase " .. tostring(new)) end
        if new == "FRONTEND" then
            sitOut = {}; M.restoreChampion(); bossRace = nil
        end
        if new == "PRERACE" then U.try(TAG, M.bossIntroCheck, "phase PRERACE") end
        -- couch-fix49: a continue's grown grid never outlives the front end (couch.lua places it at FRONTEND -> TRANSIT)
        if old == "FRONTEND" and new ~= "TRANSIT" and h2hPatch and h2hPatch.cont then M.restoreChampion() end
        if (new == "PRERACE" or new == "OTHER") and h2hPatch and h2hPatch.cont then M.restoreChampion() end
        if REPAIR_PHASES[new] then U.try(TAG, M.repairResume, "phase " .. tostring(new)) end
    end)
    St.on("leaving", TAG, function() drop("leaving") end)
    St.on("world", TAG, function() drop("world") end)
    U.hook("/Script/Griffin.CampaignSubsystem:ChooseNextMapNode", {
        pre = function(_, node) U.try(TAG, M.patchChampion, node); U.try(TAG, M.bossPickPre, node) end,
        post = function() U.try(TAG, M.bossPlace); U.try(TAG, M.restoreChampion); U.try(TAG, M.bossPickPost) end,
    }, TAG)
    -- couch-fix49 (AUTO-127): the CONTINUE entries of the front end (pre: before the native builder)
    for _, fn in ipairs(M.CONTINUE_FNS) do
        local short = fn:match(":(.+)$")
        U.hook(fn, { pre = function() U.try(TAG, M.continueArm, short) end }, TAG)
    end
    -- couch-fix58 (D5): the rival challenge's kickoff (the paddock accept's BP call / a rival mystery): every guest a place
    U.hook(RIVAL_KICK, {
        pre = function()
            rivalPlaced = nil
            pcall(function() U.mod("instances").reset("rival kickoff") end)
            U.try(TAG, M.rivalPreload, "rival kickoff")                 -- couch-fix60 (AUTO-147)
        end,
        post = function() U.try(TAG, M.rivalPlace, "rival challenge accepted") end,
    }, TAG)
    U.hook("/Script/Griffin.CampaignRun:KickOffMysteryInteractionEvent", {
        post = function() U.try(TAG, M.checkMysteryGrid) end,
    }, TAG)
    M.finishHooked = U.hook(M.FINISH_FN, { pre = function(rec) U.try(TAG, M.onRacerOut, rec) end }, TAG)
    U.log(TAG, "init: CouchTeamResult=%s CouchIngestGate=%s CouchWreckToken=%s CouchChampionGrid=%s CouchBossInstances=%s "
        .. "CouchRivalRaces=%s CouchRivalInstances=%s", M.rule(), tostring(opt("CouchIngestGate", true)),
        tostring(opt("CouchWreckToken", "all")), tostring(opt("CouchChampionGrid", true)),
        tostring(opt("CouchBossInstances", true)), tostring(opt("CouchRivalRaces", true)),
        tostring(opt("CouchRivalInstances", true)))
end

M._state = function() return R end
M._setSitOut = function(t) sitOut = t or {} end
return M
