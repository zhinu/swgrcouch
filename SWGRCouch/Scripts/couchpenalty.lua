-- couchpenalty.lua (couch-fix36): COUCH CAMPAIGN - UNHAPPY BACKERS AND THEIR PENALTIES WITH SEVERAL PLAYERS. Jules's
-- audit decisions Q3 / Q4 (playtest notes 2026-10-17 "AUDIT DECISIONS", 2026-10-18 ~11:50 UTC). Every player has his
-- own backer (couchbacker.lua, couch-fix21); this module says what an UNHAPPY one (overall rating DISPLEASED = "POOR")
-- costs the team and whose car / map its penalty reaches.
--
-- NATIVE FACTS (static, capstone on SWGR-Win64-Shipping.exe of the hf2 install = CL381121, the same code checked in the
-- CL382801 exe; JMAP Griffin-5.7.4-381121; decoded CAM_Sponsor0N / Favour_Penalty_Sponsor0N / TNS_Penalty_Sponsor01):
--   * THE GAME NEVER TAKES A LEAGUE TOKEN FOR AN UNHAPPY BACKER. Every native strike goes through the strike change
--     0x1430de4c6 (CampaignRun, delta, reason) with a CampaignDef.Strings reason: wrecked (+0x88: 0x1430de1df /
--     0x1430de41b), poor finish (+0x98: 0x1430df9b4), failed plane test (+0xb8: 0x1430dec95), rival won / lost
--     (+0xc8 / +0xd8: 0x1430de997), mystery token trades (0x1430cd5a7), RequestStrikesBalanceChange (0x1471ea638: the
--     Repair vendor, favours). CampaignStringsDef.PlayerFacingStrikeReasonSponsorCheckin (+0xa8, "Disappointed your
--     Backer") is read by NO code: the 30 places that load CampaignDef.Strings never add 0xa8 (scan of every executable
--     section), no decoded Blueprint calls RequestStrikesBalanceChange with it (only WBP_FE_Paddock_Repair's -1).
--     CompleteSponsorCheckin (exec 0x1471e8e80 -> 0x1430ce034) pays the reviewed planet's SponsorCreditsAwarded /
--     KitPointsAwarded, books the sponsor stats (0x1471ed70c) and the act's favour unlock - no strike.
--   * THE PENALTY (planet-leave step 0x1430d2bee-0x1430d2d4f): moods -> VisitedPlanets[left].SponsorOverallMood; when it
--     is Displeased and the planet is not the act's last (Tour+0xc8 == VisitedPlanets.Num): bSponsorPenaltyApplied, the
--     backer's PenaltyFavour added to run.favours (0x1430d243e: Hutt Favour_Penalty_Sponsor01 = TNS RaceTuneConfig
--     .TotalCrashAllowance IntSubtract 2; Pirate Favour_Penalty_Sponsor02 = the 40% cut; Broker Favour_Penalty_Sponsor03,
--     text only), run.PlayerVehicleHealth -= Sponsor.NumCurrentCrashAllowanceToRemove (SponsorDef CDO 2: the Hutt; the
--     Broker / Pirate assets 0; min 1), and Sponsor.NumHighRiskDaysForPenalty > 0 (the Broker's 4): 0x14707ee1c(the
--     player's current node = mPlayerPath.Last().Node, 4, 2, 3) = every node of the next 4 steps along NextNodes with
--     Activity StandardEvent (2) becomes HighRiskEvent (3, the eliminator), + DaysOfHighRiskPenalty = 4.
--
-- Q3 - NO TOKEN FOR A BACKER (couch-fix41, Jules 2026-10-18: "make the couch experience similar to solo"): the solo
-- game takes no League Token for an unhappy backer, so the couch takes none either, whatever the players' ratings (the
-- fix36 CouchBackerTokens rule is gone; an old settings.txt line is dropped by settings.lua). Each player keeps his own
-- backer's penalty below.
-- Q4 - PENALTIES ON A POOR RATING:
--   Hutt (crashes allowed -2) = THAT player's own car only: couchfavours.crashTick strips P1's native Hutt tune (the
--     race tune is one per race, so it reached every guest's car) the way it strips P1's Mad Genius, and a guest's own
--     Hutt takes 2 off HIS car on his penalty planet (M.huttActive).
--   Broker (events become Eliminators) = settings.txt CouchBrokerPenalty: "both" (DEFAULT) a guest's Broker converts the
--     shared run's next 4 steps the native way (M.brokerConvert, from P1's current node; P1's own is native and shared
--     anyway); "owner" a guest's Broker is his own eliminator payout rule (his standard events of the penalty planet:
--     outside the top 3 = no reward round, like a failed eliminator; no token: M.ownerEliminator). LIMITATION: P1's own
--     Broker stays the game's, which is the shared map by nature - with "owner" it still makes the events eliminators
--     for everybody.
--   Pirate (40% of his end-of-event credits): his own already (couchbacker.penaltyCut).
-- Pure helpers (no UObject) are tested by tools/test_couchpenalty.lua; tools/sim/fix36.lua plays the penalties and
-- tools/sim/fix41.lua checks that no backer ever costs a token.
local U = require("util")
local cfg = require("config")

local TAG = "couchpenalty"
local M = {}

local function CR() return U.mod("couchrun") end

M.HUTT = "CAM_Sponsor02"
M.BROKER = "CAM_Sponsor01"
M.HUTT_FAVOUR = "Favour_Penalty_Sponsor01"         -- the Hutt's PenaltyFavour (decoded cross-wiring, couchbacker.PENALTY)
M.HUTT_CRASHES = 2                                 -- TNS_Penalty_Sponsor01: TotalCrashAllowance IntSubtract 2
M.BROKER_DAYS = 4                                  -- CAM_Sponsor01.NumHighRiskDaysForPenalty
M.ELIM_TOP = 3                                     -- "Finish in the Top Three or lose a League Token"

---------------------------------------------------------------------------------------------------- settings
M.BROKER_RULES = { "both", "owner" }
M.BROKER_WORD = { both = "BOTH PLAYERS", owner = "OWNER ONLY" }

local function setting(key, list, def)
    local v = nil
    pcall(function() v = U.mod("settings").get(key) end)
    if v == nil then v = cfg[key] end
    for _, x in ipairs(list) do if x == v then return v end end
    return def
end
function M.brokerRule() return setting("CouchBrokerPenalty", M.BROKER_RULES, "both") end

---------------------------------------------------------------------------------------------------- pure: Q4
-- does a penalty record (couchbacker p.backer.penalty) of this kind act on planet `planet`
function M.penaltyOn(pen, kind, planet)
    return type(pen) == "table" and pen.kind == kind and tonumber(pen.planet) ~= nil
        and tonumber(pen.planet) == tonumber(planet)
end

-- "owner" Broker: his standard event of the penalty planet follows the eliminator's rule (pure) -> offer?, note | nil
function M.eliminatorRule(kind, pos, wrecked)
    if kind ~= "standard" then return nil end
    pos = tonumber(pos)
    if wrecked or not pos or pos < 1 or pos >= 99 then return nil end
    if pos <= M.ELIM_TOP then return true, "backer penalty: eliminator rule, top 3 made" end
    return false, "backer penalty: eliminator rule, outside the top 3: no reward round"
end

-- the nodes the native Broker penalty converts (pure walk of a node graph): start = the player's current node,
-- next(node) -> list, act(node) / setAct(node, v); the native recursion: depth levels below start, Standard -> HighRisk
function M.convertWalk(start, depth, next, act, setAct)
    local n = 0
    local function rec(node, d)
        if d <= 0 then return end
        for _, c in ipairs(next(node) or {}) do
            if act(c) == 2 then setAct(c, 3); n = n + 1 end
            rec(c, d - 1)
        end
    end
    rec(start, depth)
    return n
end

---------------------------------------------------------------------------------------------------- live: reads
local function activeRun(r)
    if r ~= nil and U.ok(r) then return r end
    local ok, run = pcall(function() return CR().activeRun() end)
    return (ok and U.ok(run)) and run or nil
end

---------------------------------------------------------------------------------------------------- live: Q4
-- a guest's own penalty after his DISPLEASED check-in (couchbacker.collect): Hutt = his car next planet, Broker = the
-- shared map ("both") or his payout rule ("owner"). d = his check-in data, atCheckin = collected on the check-in planet.
-- -> a short note for the log
function M.onGuestPenalty(p, d, atCheckin)
    if type(p) ~= "table" or type(p.backer) ~= "table" or type(d) ~= "table" or not d.penalty then return nil end
    local sp = p.backer.sponsor
    if sp == M.HUTT then
        p.backer.penalty = { planet = d.planet + 1, kind = "hutt", crashes = M.HUTT_CRASHES, favour = d.penalty.favour }
        return string.format("HIS car's crashes allowed -%d on planet %d", M.HUTT_CRASHES, d.planet + 1)
    end
    if sp == M.BROKER then
        local rule = M.brokerRule()
        p.backer.penalty = { planet = d.planet + 1, kind = "broker", rule = rule, favour = d.penalty.favour }
        if rule == "owner" then
            return string.format("HIS eliminator rule on planet %d's races (OWNER ONLY: the map is untouched)", d.planet + 1)
        end
        if not atCheckin then return "BOTH PLAYERS: the planet is behind the run already (no map change)" end
        local n = M.brokerConvert()
        return string.format("BOTH PLAYERS: %d event(s) of the run's next %d steps became Eliminators", n, M.BROKER_DAYS)
    end
    return nil
end

-- the native Broker conversion on the shared run (0x14707ee1c from mPlayerPath.Last().Node, depth 4, 2 -> 3) -> count
function M.brokerConvert(run)
    run = activeRun(run)
    if not run then return 0 end
    local start = nil
    pcall(function() start = run:GetCurrentNode() end)
    if not U.ok(start) then
        pcall(function()
            local path = run.mPlayerPath
            local k = U.arrayCount(path)
            if k > 0 then start = path[k].Node end
        end)
    end
    if not U.ok(start) then
        U.warn(TAG, "Broker (BOTH PLAYERS): no current node on the run - the map is untouched")
        return 0
    end
    local n = M.convertWalk(start, M.BROKER_DAYS,
        function(nd) local t = {}; pcall(function() t = U.arrayToTable(nd.NextNodes) end); return t end,
        function(nd) local a = nil; pcall(function() a = tonumber(nd.Activity) end); return a end,
        function(nd, v) pcall(function() nd.Activity = v end) end)
    return n
end

-- his Hutt penalty acts on this planet -> crashes to take off his car (0 = none)
function M.huttCrashes(p, planet)
    local pen = type(p) == "table" and type(p.backer) == "table" and p.backer.penalty or nil
    if M.penaltyOn(pen, "hutt", planet) then return tonumber(pen.crashes) or M.HUTT_CRASHES end
    return 0
end

-- "owner" Broker on his race (couchrun.onRaceEnd) -> offer (false = none), note | nil
function M.ownerEliminator(p, planet, kind, pos, wrecked)
    local pen = type(p) == "table" and type(p.backer) == "table" and p.backer.penalty or nil
    if not M.penaltyOn(pen, "broker", planet) or pen.rule ~= "owner" then return nil end
    return M.eliminatorRule(kind, pos, wrecked)
end

---------------------------------------------------------------------------------------------------- init
function M.init() end                              -- couch-fix41: no check-in hook (no token rule)

function M.status()
    return string.format("couchpenalty: backers never cost a token (solo parity), broker %s", M.brokerRule())
end

return M
