-- couchrun.lua: COUCH CAMPAIGN - the guests' own run progression (0.15).
-- P1's build is the real CampaignRun (native rewards, shop, credits, save). Each joined guest gets a mod-side run of
-- the SAME shape, kept in Mods/SWGRCouch/couch-run.txt:
--   * a build (perks.lua loadout: abilities, crash ability, parts = the campaign's affixes, traits, 6 stat levels),
--     started from the pilot kit like the campaign's starter (2 abilities, levels 0);
--   * credits: EXACTLY what the native run pays P1 for the same finish (couchrules.guestPayout: one position row on
--     every planet, time trials = target beaten, his own end-of-event multiplier from his mystery deals / favours),
--     the planet's native skip bonus, P1's starting credits at the run's first grid, native shop prices (ECONOMY
--     below);
--   * a reward offer after every finished event, MIRRORING the round P1 gets: the node's ECampaignMapNodeReward
--     (UpgradePart = +1 on one of 3 stats, Ability, Affix = a part, Modifier = a trait), 3 choices, SKIP for credits;
--   * a shop stock when P1 opens a shop (couchpanel shows both).
-- The build reaches the guest's car at every node pick: couch.patchGrid gives the guest a grid entry, then
-- couchrun.applyBuilds writes the loadout into the guest's own PlayerState (perkapply, the FREE MODE path); the race
-- spawn applies it (06b §1: the spawn reads the controller's PlayerState build).
-- A NEW campaign run resets every guest to a starter build: the guests' records belong to P1's run id (RUN IDENTITY:
-- the pre-run screens only put the old run's guests aside; the run P1 then plays decides - new, or backed out).
-- Each guest has his OWN vehicle class and racer style (couchprerun.lua: his half of the native vehicle select /
-- loadout screens): p.arch + p.style, his starter = run.starter(p.arch, p.style), his car = that class (couch.patchGrid)
-- with that build. A guest who never picked follows P1's class (CampaignRun.MainVehicleType).
-- run.lua supplies the content helpers (starter, makeOffer's rarity/grade logic through a shadow run, catalog); this
-- module never calls a run.lua function that saves (run.txt stays the GALAXY RUN's).
local U = require("util")
local St = require("state")
local cfg = require("config")
local settings = require("settings")

local TAG = "couchrun"
local M = {}
local FILE = "couch-run.txt"

local function run() return U.mod("run") end
local function K() return U.mod("perks") end
-- #110 favours per player (couchfavours.lua: decoded ranks, the per-player / team effects)
local function F() local ok, m = pcall(U.mod, "couchfavours"); return (ok and type(m) == "table") and m or nil end
local function PA() return U.mod("perkapply") end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

local okD, D = pcall(require, "rundata")
if not okD or type(D) ~= "table" then D = nil end
local okPD, PD = pcall(require, "perkdata")
if not okPD or type(PD) ~= "table" then PD = nil end
-- FINDING #111: the mystery outcomes' favours (generated, static): Lua never reads a ResultFavours element
-- couch-fix29: the campaign racer styles per rank (static, decoded): a guest's starter abilities and his traits
local okCS, CS = pcall(require, "camstyles")
if not okCS or type(CS) ~= "table" then CS = nil end
local okMD, MD = pcall(require, "mystdata")
if not okMD or type(MD) ~= "table" or type(MD.OUTCOMES) ~= "table" then MD = { OUTCOMES = {} } end
local LEVEL_MAX = (PD and tonumber(PD.LEVEL_MAX)) or 10

-- G: { v = 3, keys = "seat", arch (P1's class), planet, kind, players = {[seat] = {seat, pnum, arch, style, picked, lo,
--      owned, cap, credits, offer, shop, lastPos, lastPay}} }   picked = the guest chose his class (else he follows P1's)
-- SEATS (couchseat.lua, FINDING #43): players are keyed by the guest's SEAT (2 = the first guest to join the couch run,
-- 3, 4), never by his pad's ControllerId: every public function here still takes the ctrlId its caller has and looks
-- the seat up (seatKey). p.pnum = his display number when last seen (logs), p.seat = the key. A file from before
-- (players keyed by ctrlId, no `keys`) is migrated once at load (SEAT MIGRATION below).
local G = nil

local function Seat() return U.mod("couchseat") end
-- the storage key of a guest's progress (nil: P1 / a dormant guest / no seat free)
local function seatKey(ctrlId, pnum)
    local ok, k = pcall(function() return Seat().key(ctrlId, pnum) end)
    return ok and k or nil
end
M.seatKey = seatKey
-- a guest without a seat (should not happen: join gives every joined pad one) gets a record that is never saved
local unseated = {}

---------------------------------------------------------------------------------------------------- persistence
local function ser(v, ind)
    ind = ind or ""
    local t = type(v)
    if t == "number" then return (math.type(v) == "integer") and tostring(v) or string.format("%.17g", v) end
    if t == "string" then return string.format("%q", v) end
    if t == "boolean" or t == "nil" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = { "{\n" }
    for _, k in ipairs(keys) do
        local ks = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
        out[#out + 1] = ind .. "  " .. ks .. " = " .. ser(v[k], ind .. "  ") .. ",\n"
    end
    out[#out + 1] = ind .. "}"
    return table.concat(out)
end

M._ser = ser                             -- sim / tests

local function filePath()
    local ok, d = pcall(function() return settings.modDir() end)
    return (ok and type(d) == "string") and (d .. "/" .. FILE) or nil
end

-- couch-run.txt holds the guests' LIVE state (every change written at once, as before). Format v2 (runsync) is the same
-- table with `v = 2`: a file from before (no v) is read as it is and becomes v2 at its next write; an older mod reading a
-- v2 file still finds its `players`. The checkpoints the live state is rolled back to live in couch-run-journal.txt
-- (CHECKPOINT JOURNAL below).
-- Format v3 (couch-seat): the same table with `keys = "seat"` (players keyed by seat, SEAT MIGRATION below).
-- Format v4 (couch-fix31, audit issue 3): + runId (P1's CampaignRun.RunId the guests' records belong to), stash (the
-- previous run's guests while a NEW run's pre-run screens are up), starts ({[runId] = P1's run-start credits}),
-- padSeats ({[ControllerId] = seat}: the seat each pad sat in, couchseat's memory across a relaunch). RUN IDENTITY below.
local STATE_V = 4
local noWrite = nil     -- SEAT MIGRATION: the old file could not be copied first -> never overwritten this session
local migrateSeats      -- SEAT MIGRATION (below)
local function newState() return { v = STATE_V, keys = "seat", arch = nil, planet = 1, kind = "standard", players = {} } end
local function save()
    local p = filePath()
    if not p or not G then return end
    if noWrite then
        U.logEvery("couchrun.nowrite", 60000, TAG, "WARN %s not written: %s", FILE, noWrite)
        return
    end
    G.v = STATE_V
    G.keys = "seat"
    local f = io.open(p, "w")
    if not f then return end
    f:write("return " .. ser(G) .. "\n")
    f:close()
end

local function readTable(path, name)
    local f = path and io.open(path, "r")
    if not f then return nil end
    local src = f:read("a")
    f:close()
    local chunk = load(src, "@" .. name, "t", {})
    local ok, t = pcall(chunk or function() return nil end)
    if ok and type(t) == "table" then return t end
    return nil
end

local function loadState()
    if G then return G end
    local t = readTable(filePath(), FILE)
    if t and type(t.players) == "table" then
        G = t
        if t.keys == "seat" and (tonumber(t.v) or 0) < 4 and t.runId == nil then
            -- v3 -> v4 (couch-fix31): no run id yet; the guests' run is taken from the journal at the first look at
            -- P1's run (RUN IDENTITY: bindRun), nothing changes before
            U.log(TAG, "couch-run.txt from before run ids (v%s): the guests' run is read from the checkpoint journal "
                .. "at the first look at P1's run", tostring(t.v))
        end
        if t.v == nil then
            U.log(TAG, "couch-run.txt from before the checkpoint journal (no format version): kept as the guests' live "
                .. "state, written as v%d from now on", STATE_V)
        end
        if t.keys ~= "seat" then
            local ok, err = pcall(migrateSeats)
            if not ok then
                -- never run on pad-keyed records as if they were seats: start the session empty, the file untouched
                noWrite = "the seat migration failed (" .. tostring(err) .. "): the old file is left as it is"
                U.warn(TAG, "%s", noWrite)
                G = newState()
            end
        end
    end
    G = G or newState()
    return G
end

---------------------------------------------------------------------------------------------------- campaign reads
local function cs()
    local ok, c = pcall(FindFirstOf, "CampaignSubsystem")
    return (ok and U.ok(c)) and c or nil
end

local function activeRun()
    local c = cs()
    if not c then return nil end
    local r = nil
    pcall(function() r = c.ActiveRun end)
    return U.ok(r) and r or nil
end

function M.campaignArch()
    local r = activeRun()
    local a = nil
    if r then pcall(function() a = tonumber(r.MainVehicleType) end) end
    return a
end

-- P1's credits (CampaignRun.Credits), nil when unreadable
function M.campaignCredits()
    local r = activeRun()
    local c = nil
    if r then pcall(function() c = tonumber(r.Credits) end) end
    return c
end

-- the node P1 is on (the last chosen, not completed one; else the last completed)
local function currentNode()
    local r = activeRun()
    if not r then return nil end
    local best, done = nil, nil
    pcall(function()
        local nodes = r.Map.mNodes
        for i = 1, U.arrayCount(nodes) do
            local nd = nodes[i]
            if U.ok(nd) then
                if nd.bHasBeenChosen == true and nd.bHasBeenCompleted ~= true then best = nd end
                if nd.bHasBeenCompleted == true then done = nd end
            end
        end
    end)
    return best or done
end

local ACT_KIND = { [2] = "standard", [3] = "highrisk", [4] = "fieldtest", [5] = "knockout", [6] = "champion",
                   [10] = "planesprint", [11] = "rival" }

-- P1's current reward round: {type, n, skippable} or nil
function M.nativeRound()
    local nd = currentNode()
    if not nd then return nil end
    local out = nil
    pcall(function()
        local rounds = nd.RewardRounds
        local cnt = rounds:GetArrayNum()
        if cnt == 0 then return end
        local ix = math.max(0, math.min(cnt - 1, tonumber(nd.RewardRoundIx) or 0))
        local rr = rounds[ix + 1]
        out = { type = tonumber(rr.RewardType) or 0, n = U.arrayCount(rr.AvailableRewards),
                skippable = rr.bIsSkippableReward == true }
    end)
    return out
end

local function nodeInfo()
    local nd = currentNode()
    local planet, kind = 1, "standard"
    if nd then
        pcall(function() planet = (tonumber(nd.PlanetIndex) or 0) + 1 end)
        pcall(function() kind = ACT_KIND[tonumber(nd.Activity) or 0] or "standard" end)
    end
    -- #30: the planet's plane test is no node: paid as a time trial (target beaten or not), like the native run
    pcall(function() if U.mod("couch").isPlaneTest() == true then kind = "planesprint" end end)
    -- couch-fix58: a RIVAL CHALLENGE is no node either (the run's current node is the last one raced): its own kind
    pcall(function() local r = activeRun(); if r and r.bIsPlayingRivalChallengeEvent == true then kind = "rival" end end)
    return math.max(1, math.min(5, planet)), kind
end

-- couch-fix21 (per-player backers, couchbacker.lua): the run, its node / planet, the grid size and the live state's save
M.activeRun = activeRun
M.nodeInfo = nodeInfo
function M.gridN() loadState(); return tonumber(G.gridN) end
function M.save() if G then save() end end
-- the backer favours the guests unlocked (couchbacker.shareUnlock): G.sharedUnlocks[tag] = {favour, seat, sponsor}.
-- couchprerun's favour pickers offer every player the union of P1's account unlocks and these.
function M.shareUnlock(tag, favour, seat, sponsor)
    loadState()
    G.sharedUnlocks = type(G.sharedUnlocks) == "table" and G.sharedUnlocks or {}
    if not G.sharedUnlocks[tag] then
        G.sharedUnlocks[tag] = { favour = favour, seat = seat, sponsor = sponsor }
        save()
    end
end
-- couch-fix35 (Q6): couchmeta's store (the guests' counts towards P1's tracked unlocks, the events seen): meta, not
-- run state (META_KEYS: never rolled back by a checkpoint restore)
function M.metaStore()
    loadState()
    G.meta = type(G.meta) == "table" and G.meta or {}
    return G.meta
end
-- couch-fix35: "<run id>:<nodes chosen>" - one key per event of P1's run (couchmeta's once-each keys)
function M.visitKey()
    local f = nil
    pcall(function() f = M.fpOf(activeRun()) end)
    if type(f) ~= "table" then return nil end
    return string.format("%s:%s", tostring(f.id or "-"), tostring(f.ch or "-"))
end
local function META() local ok, m = pcall(U.mod, "couchmeta"); return (ok and type(m) == "table") and m or nil end

function M.sharedUnlocks()
    loadState()
    local out = {}
    for tag, u in pairs(type(G.sharedUnlocks) == "table" and G.sharedUnlocks or {}) do
        if type(u) == "table" then out[#out + 1] = { tag = tag, favour = u.favour, seat = u.seat, sponsor = u.sponsor } end
    end
    table.sort(out, function(a, b) return a.tag < b.tag end)
    return out
end

-- the act (CampaignRun.Tour = CAM_Tour1..3) and the planet's engine name (the world: L_<Engine>_...), for the
-- per-planet native skip value; nil when unreadable
local function actEngine()
    local act, engine = nil, nil
    local r = activeRun()
    if r then pcall(function() act = tonumber(U.objName(r.Tour):match("Tour_?(%d)")) end) end
    pcall(function() engine = tostring(U.levelName() or ""):match("^L_(%a+)_") end)
    return act, engine
end

local function rules() local ok, R = pcall(U.mod, "couchrules"); return ok and type(R) == "table" and R or nil end

---------------------------------------------------------------------------------------------------- economy
-- ECONOMY (couch-econ 2026-10-15): a guest's run pays and charges what P1's native run does (couchrules.guestPayout
-- has the payout derivation and its live proof). Per guest, saved with his run:
--   p.mods = { mult (end-of-event credits multiplier: CreditsFromEndOfEventRewardsMultiplier), top3, win (Lyren's
--             podium / first-place bonus), fewer (fewer reward choices), shop (shop price factor) }
-- set by the MYST favours of HIS mystery deals (MYST_FAV); Victorious Loser (Veteran) is a x1.5 on mult in the
-- bottom N like the native tuneset (FloatAddMultiple +0.5).
local function mods(p)
    p.mods = type(p.mods) == "table" and p.mods or {}
    local m = p.mods
    m.mult = tonumber(m.mult) or 1
    m.top3, m.win = tonumber(m.top3) or 0, tonumber(m.win) or 0
    m.fewer, m.shop = tonumber(m.fewer) or 0, tonumber(m.shop) or 1
    m.better = (m.better == true) or nil                 -- couch-fix32: Favour_MYST_BetterUpgradeRewards
    if type(m.rager) ~= "table" then m.rager = nil end   -- couch-fix46: HIS Biddy Blas race bet (Favour_MYST_Rager_*)
    return m
end
M.mods = mods

-- the MYST_* RacerFavours a mystery outcome grants that act on the economy a guest has (decoded TuneSets /
-- PassiveEffects). The *CreditRewardLine favours only add a results-breakdown line natively (no effect).
local MYST_FAV = {
    Favour_MYST_HalfCreditRewards = { mult = 0.5, txt = "RACE CREDITS HALVED" },    -- FloatSubtractMultiple 0.5
    Favour_MYST_DoubleCreditRewards = { mult = 2.0, txt = "RACE CREDITS DOUBLED" }, -- FloatAddMultiple 1.0
    Favour_MYST_StarCreditsForVictory_Lvl1 = { top3 = 250, txt = "+250 CR ON THE PODIUM" },
    Favour_MYST_StarCreditsForVictory_Lvl2 = { win = 1000, txt = "+1000 CR FOR A WIN" },
    Favour_MYST_LessEventRewardChoices = { fewer = 1, txt = "FEWER REWARD CHOICES" },
    Favour_MYST_IncreasedShopPrices = { shop = 1.5, txt = "SHOP PRICES +50%" },
    Favour_MYST_Gain3RandomStats = { stats = 3, txt = "+3 RANDOM STATS" },
    Favour_MYST_Lose3RandomStats = { stats = -3, txt = "-3 RANDOM STATS" },
    Favour_MYST_IncreasedCreditRewardLine = { none = true },
    Favour_MYST_DecreasedCreditRewardLine = { none = true },
    -- couch-fix32: MYST_108's second deal. TNS_MYST_BetterUpgradeRewards: UpgradeLevelBoostWeights x0 (priority 1),
    -- then [1] +1.0 / [2] +0.01 = every upgrade card one level more, ~1 % two more ("Gaurentees +2 Upgrades with a
    -- minor chance of +3"); a whole-run favour like the x0.5 (no FavoursToRemove in its bookend)
    Favour_MYST_BetterUpgradeRewards = { better = true, txt = "BETTER UPGRADES" },
    -- couch-fix32: MYST_110's repair. Two RepairFaultyAffixPassiveEffectConfig + RemoveItself: up to 2 faulty parts
    Favour_MYST_FixFaultyAffixes = { repair = 2, txt = "FAULTY PARTS REPAIRED" },
    -- couch-fix46 (live round 1 AUTO-120, MYST_106A "Alright, you're on."): Biddy Blas' RACE BET is a bet like the
    -- pre-race challenges (#25: per player). Decoded Favour_MYST_Rager_RagersBet_Lvl1: two PassiveRules (UseOnce false)
    -- on RacePositionRelativeRequirementConfig vs DA_Racer_Rager: ahead -> CreditsBalance +250 ("Biddy Blas' Bet -
    -- Finished Ahead"), behind -> -250 ("... Finished Behind"), every race Biddy Blas races until the favour goes. The
    -- outcome's FavoursToRemove (2) are the OTHER bet levels (Lvl2 / Lvl3): for a guest = his own bet replaced. It was
    -- a run favour = "P1'S RUN ONLY" (greyed). Lvl2 / Lvl3 also make Biddy Blas' AI harder at the countdown
    -- (SabotageRandomTargetFromList PAS_MYST_HarderAi: the shared race's AI) and Lvl3 pays through a bookend: those
    -- stay P1's run (greyed for the guests).
    Favour_MYST_Rager_RagersBet_Lvl1 = { rager = { lvl = 1, ahead = 250, behind = -250 },
                                         txt = "BIDDY BLAS' BET: +250 AHEAD / -250 BEHIND" },
}
-- couch-fix46: the racer of Biddy Blas' bets (RacePositionRelativeRequirementConfig.Target)
M.RAGER_DEF = "DA_Racer_Rager"
M.MYST_FAV = MYST_FAV

-- couch-fix39 (audit Q10, Jules: "let P2 pick team-effect mystery choices whatever the consequences"): the run-wide
-- MYST favours whose effect is the TEAM's (the shared run P1's CampaignRun is: sabotage of the field or of P1's own
-- car, one-race / whole-run debuffs, the rivals' difficulty, Hibi's prices, the map, a strike protector). With the
-- setting CouchMysteryTeam = "allowed" a guest's choice that grants one adds it to the shared run (couchrun.mystTeam*
-- below); the favours that PAY or CHARGE P1's wallet (Biddy Blas' bets: CreditsBalancePassiveEffect on P1's run, the
-- promises / Lyren's payouts) are never a team effect: such a choice stays greyed for a guest in both modes.
-- (decoded Narrative/MysteryInteractions/Passives + Loadouts/Favours, CL381121; txt = his toast)
local TEAM_FAV = {
    Favour_MYST_SabotagePlayerByAntagonist_ExplodeOnStart = { txt = "TEAM: P1 SABOTAGED (EXPLODES AT THE START)" },
    Favour_MYST_SabotagePlayerByRager_ExplodeOnStart = { txt = "TEAM: P1 SABOTAGED (EXPLODES AT THE START)" },
    Favour_MYST_OneRace_IncreasedRamjetActiveHeating = { txt = "TEAM: P1'S RAMJET SABOTAGED (1 RACE)" },
    Favour_MYST_OneRace_StuckSteering = { txt = "TEAM: P1'S STEERING SABOTAGED (1 RACE)" },
    Favour_MYST_InnerHonourAndProtoge_EasierDifficulty = { txt = "TEAM: TWO RIVALS WEAKER" },
    Favour_MYST_InnerHonourAndProtoge_HigherDifficulty = { txt = "TEAM: TWO RIVALS STRONGER" },
    Favour_MYST_MechanicNewSupplier = { txt = "TEAM: HIBI'S PARTS HALF PRICE, PACKS DOUBLE" },
    Favour_MYST_MechanicNewSupplier_Alt = { txt = "TEAM: HIBI'S PACKS HALF PRICE, PARTS DOUBLE" },
    Favour_MYST_SabotageByMerc = { txt = "TEAM: A RACER SABOTAGED" },
    Favour_MYST_SabotageByMerc_Rival = { txt = "TEAM: THE RIVAL SABOTAGED" },
    Favour_MYST_SabotageByMerc_ManyRacers = { txt = "TEAM: 5 RACERS SABOTAGED" },
    Favour_MYST_SabotageByMerc_AntagonistInChampionship = { txt = "TEAM: THE ANTAGONIST SABOTAGED" },
    Favour_MYST_SabotageByRager_RandomRacer = { txt = "TEAM: A RACER SABOTAGED" },
    Favour_MYST_SabotageByRager_Rival = { txt = "TEAM: THE RIVAL SABOTAGED" },
    -- paid by a later bookend in every outcome that grants them (mystdata bk): greyed for guests anyway
    Favour_MYST_MoreHighRiskEvents = { txt = "TEAM: MORE HIGH RISK EVENTS" },
    Favour_MYST_ExoticVendorToken_Lvl1 = { txt = "TEAM: SCRAP DEALER DISCOUNT" },
    Favour_MYST_WholeRun_DoubleAbilityCooldown = { txt = "TEAM: P1'S ABILITIES COOL DOWN SLOWER" },
    Favour_MYST_WholeRun_RamjetDoubleHeat = { txt = "TEAM: P1'S RAMJET HEATS TWICE AS FAST" },
    Favour_MYST_WholeRun_TripleAfterburnerDepletion = { txt = "TEAM: P1'S AFTERBURNER DRAINS FASTER" },
    Favour_MYST_ReducedTopSpeed = { txt = "TEAM: P1'S TOP SPEED -10%" },
}
M.TEAM_FAV = TEAM_FAV

-- couch-fix48 (solo parity, coordinator 2026-10-18): a NON-HIDDEN ResultFavour is no run effect. Decoded P1's pick
-- (CampaignRun::ChooseMysteryInteractionOutcome 0x1430cc470): only a ResultFavours element whose RacerFavour.bIsHidden
-- (+0x109) is set reaches CampaignRun::AddFavour; a non-hidden one is never added to the run nor applied to P1. The
-- outcomes that carry one (MYST_152C Malis, MYST_136C Elegant Professional, MYST_106C Biddy Blas' bookend) also carry
-- its loadout favour's ResultUnlockTags, which the same function unlocks on the ACCOUNT (outcome +0x68: Days <= 0 ->
-- 0x1471eb392 at once, else run.DelayedUnlocks); the Result widget only SHOWS the favour (ShowResultFavours, its
-- bIsHidden check: WBP_FE_Paddock_MysteryInteraction_Result kismet @1454-1872). So a guest's pick does the same for
-- HIM: no run favour (in either team setting), the favour unlocked the couch way for a guest's unlock (couchbacker.
-- shareUnlock: the game's one account = P1's, the pickers every player uses, + the couch store with his seat).
-- Every non-hidden favour mystdata names (the decoded Favour_* assets, CL381121):
local UNLOCK_FAV = {
    Favour_Mercenary_1 = { tag = "Unlock.Cam.Favours.Mercenery", name = "MALIS' FAVOUR" },
    Favour_ElegantProfessional_1 = { tag = "Unlock.Cam.Favours.ElegantProfessional", name = "SECOND CHANCE" },
    Favour_Rager_1 = { tag = "Unlock.Cam.Favours.Rager", name = "BIDDY BLAS' FAVOUR" },
}
M.UNLOCK_FAV = UNLOCK_FAV
-- the OPTIONS > COUCH CAMPAIGN setting (settings.txt CouchMysteryTeam; a config_user.lua cfg.CouchMysteryTeam wins)
local function teamAllowed()
    local v = cfg.CouchMysteryTeam
    if v == nil then
        local ok, s = pcall(function() return require("settings").get("CouchMysteryTeam") end)
        v = ok and s or nil
    end
    return v == "allowed"
end
M.mysteryTeamAllowed = teamAllowed

-- FINDING #111 (crash_2026_10_18_10_24_48, MYST_108 Sen Fira; #67b crash_2026_10_18_03_57_20, Soren Zaks): a
-- ResultFavours ELEMENT is never read. It is a TSoftObjectPtr (0x28 bytes in this UE 5.7 game) and UE4SS GR Edition's
-- push copies its FSoftObjectPath from element +0x10 (the UE4 TagAtLastTest layout): the path's FString is read 8 bytes
-- past the element, a nonzero length there = memcpy from NULL (the AV of both dumps; pcall cannot catch it). The
-- favour names come from mystdata (static, keyed by the outcome's object names); see tools/gen-mystdata.py.
-- -> the outcome's favour names, or nil when the table does not know the outcome (a newer game build)
local function outcomeFavours(key)
    local row = key and MD.OUTCOMES[key]
    if type(row) ~= "table" or type(row.favs) ~= "table" then return nil end
    return row.favs
end
M.outcomeFavours = outcomeFavours

-- FINDING #112: does that outcome pay through a ResultBookend (mystdata bk: a follow-up interaction later in the run -
-- MYST_157's gamble, MYST_107's promises, MYST_108's payout two days later, MYST_113's race-result deal)? Static like
-- the favours (ResultBookend is a TSoftObjectPtr: never read from Lua). An outcome mystdata does not know: false
local function outcomeDelayed(key)
    local row = key and MD.OUTCOMES[key]
    return type(row) == "table" and row.bk == true
end
M.outcomeDelayed = outcomeDelayed

-- the mystdata key of an outcome: "<interaction>:<choice>.<outcome>" (object names; GetFName only, no soft read)
local function outcomeKey(inter, choice, o)
    local a, b, c = U.objName(inter), U.objName(choice), U.objName(o)
    if a == "" or b == "" or c == "" then return nil end
    return a .. ":" .. b .. "." .. c
end
M.outcomeKey = outcomeKey

-- the planet's native skip bonus (couchrules: the planet setup's SkipRewardEconomyId)
local function skipCredits()
    local act, engine = actEngine()
    local R = rules()
    local ok, v = pcall(function() return R.skipCredits(act, engine) end)
    if ok and tonumber(v) then return math.floor(v) end
    local nat = D and D.payouts and D.payouts.native
    return math.floor(tonumber(nat and nat.skip and nat.skip[1] and nat.skip[1].Mastiff) or 1000)
end
M.skipCredits = skipCredits

---------------------------------------------------------------------------------------------------- players
local function emptyOwned() return { ab = {}, crash = {}, part = {}, trait = {} } end

local function addOwned(owned, lo)
    for n = 1, 4 do if lo.ab and lo.ab[n] then owned.ab[lo.ab[n]] = true end end
    if lo.crash then owned.crash[lo.crash] = true end
    for _, id in pairs(lo.parts or {}) do if id then owned.part[id] = true end end
    for _, id in pairs(lo.traits or {}) do if id then owned.trait[id] = true end end
end

---------------------------------------------------------------------------------------------------- style + base (fix29)
-- couch-fix29 (audit 12 issue 10b, design Q7 "same class base state as P1"): a guest's build starts like P1's solo one.
--   * his racer style keeps its RANK: p.styleRank = the CAM_Style_<Key>_Lv<N> he picked (couchprerun: the highest rank
--     the shared unlocks give that style), else the rank P1's unlocks give it (Unlock.Cam.Style.<Key>[.UpgradeA|B]),
--     else 1. His starter abilities = that rank's StandardAbilities, his traits = its Traits (camstyles.lua), applied
--     on his car in every campaign race (perkapply couch record) - the native run applies only P1's style;
--   * his starting stat levels = P1's garage Tuning upgrades of that class (CampaignMetaProgression.BaseVehicleStates
--     [vehicleType].StartingStatForSlot[slot]: the meta save, "unlocks shared upward"); his level cap follows.
local function unlockSub()
    local ok, sub = pcall(FindFirstOf, "SPUnlockSubsystem")
    return (ok and U.ok(sub)) and sub or nil
end
local function tagOn(sub, tag)
    local lib = U.cdo("/Script/Griffin.Default__BlueprintSPUnlockSystemLibrary")
    if not (sub and U.ok(lib)) then return nil end
    local ok, v = pcall(function() return lib:IsTagUnlocked(sub, { TagName = U.fname(tag) }) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end
-- the rank P1's unlocks give a style (nil: unreadable / no such style). Seam: M._unlockedRank
function M.unlockedRank(key)
    if M._unlockedRank then return M._unlockedRank(key) end
    if not (CS and CS.STYLES[key]) then return nil end
    local sub = unlockSub()
    if not sub then return nil end
    local best = nil
    for r = 1, 3 do
        local e = CS.STYLES[key][r]
        if e and e.unlock ~= "" and tagOn(sub, e.unlock) == true then best = r end
    end
    return best
end
-- his style's rank: his pick's, else P1's unlocks (stored once: the run keeps the rank it started with), else 1
function M.styleRank(p)
    if type(p) ~= "table" or type(p.style) ~= "string" then return nil end
    if not (CS and CS.STYLES[p.style]) then return nil end
    local r = tonumber(p.styleRank)
    if r then return r end
    r = M.unlockedRank(p.style)
    if r then
        p.styleRank = r
        U.log(TAG, "P%s's racer style %s: rank %d from P1's unlocks", tostring(p.pnum), p.style, r)
        save()
    end
    return r or 1
end
-- his style's traits (static paths) and its text "Airborne II" -> list, text (nil: no campaign style)
local ROMAN = { "I", "II", "III" }
function M.styleTraits(p)
    local r = M.styleRank(p)
    local e, rr = nil, nil
    if CS and r then e, rr = CS.get(p.style, r) end
    if not e then return nil, nil end
    local out = {}
    for i, t in ipairs(e.traits or {}) do out[i] = t end
    return out, string.format("style %s %s", p.style, ROMAN[rr] or tostring(rr))
end
-- P1's garage Tuning upgrades of a class: {[0..5] = level} | nil. Seam: M._metaBase
function M.metaBase(arch)
    if M._metaBase then return M._metaBase(arch) end
    local out = nil
    pcall(function()
        local c = cs()
        local meta = c and c.MetaProgression
        if not U.ok(meta) then return end
        local arr = meta.BaseVehicleStates
        for i = 1, U.arrayCount(arr) do
            local st = arr[i]
            if tonumber(st.vehicleType) == tonumber(arch) then
                local lv = st.StartingStatForSlot
                local n = U.arrayCount(lv)
                out = {}
                for sl = 0, 5 do out[sl] = (sl + 1 <= n) and (tonumber(lv[sl + 1]) or 0) or 0 end
            end
        end
    end)
    return out
end
-- the starter's style abilities and P1's class base levels (pure on its inputs; the seams above feed it)
function M.campStarter(p, lo, arch, style)
    if type(lo) ~= "table" then return lo end
    local notes = {}
    local e, rr = nil, nil
    if CS and type(style) == "string" then e, rr = CS.get(style, M.styleRank(p)) end
    if e then
        for n = 1, 4 do lo.ab[n] = e.abilities[n] or false end
        notes[#notes + 1] = string.format("abilities of %s %s (%s)", style, ROMAN[rr] or tostring(rr),
            #e.abilities > 0 and table.concat(e.abilities, ",") or "none")
    end
    local base = M.metaBase(arch)
    if base then
        local top, t = 0, {}
        for sl = 0, 5 do
            local v = math.max(0, math.min(LEVEL_MAX, math.floor(tonumber(base[sl]) or 0)))
            lo.tune[sl] = v
            top = math.max(top, v)
            t[#t + 1] = tostring(v)
        end
        p.cap = math.max(tonumber(p.cap) or 1, top)
        notes[#notes + 1] = "P1's class base levels " .. table.concat(t, "/")
    end
    local okV, v = pcall(function() return K().validate(lo, arch, style, F() and F().partSlots(p) or nil) end)
    if okV and type(v) == "table" then lo = v end
    if #notes > 0 then U.log(TAG, "P%s starter (class %s): %s", tostring(p.pnum), tostring(arch), table.concat(notes, ", ")) end
    return lo
end

local function starterFor(p, arch, style)
    p.arch, p.style = arch, style
    p.lo = M.campStarter(p, run().starter(arch, style), arch, style)
    p.fixed = nil                                       -- a new build: no repaired parts (scrap dealer)
    p.faults, p.faultQueue, p.flow = nil, nil, nil      -- couch-rewards2: no faults / reward flow carried over
    p.owned = emptyOwned()
    addOwned(p.owned, p.lo)
    p.slotsKept, p.slotsV, p.fav = nil, 1, nil               -- #110: a new build = his slots from his favours alone
    local f = F()
    if f then f.fitParts(p, "starter build") end
end

-- a run vehicle class (never the podracer: arch 1 is only a time-trial vehicle)
local function runArch(a)
    a = tonumber(a)
    if a == nil or a == 1 then return nil end
    return a
end

function M.ensure(ctrlId, pnum)
    loadState()
    local camp = runArch(M.campaignArch())
    if camp and G.arch ~= camp then
        -- no wipe here: a new run is told by P1's run id (RUN IDENTITY: bindRun), and the guests' own picks survive
        -- P1's run starting on another class
        if G.arch ~= nil then U.log(TAG, "P1's vehicle class %s -> %s", tostring(G.arch), tostring(camp)) end
        G.arch = camp
    end
    local k = seatKey(ctrlId, pnum)
    local p = k and G.players[k] or unseated[tonumber(ctrlId) or -1]
    if not p then
        p = { seat = k, pnum = pnum, cap = tonumber(D and D.LEVEL_CAP_START) or 3, credits = 0 }
        starterFor(p, camp or runArch(G.arch) or 0, nil)
        if k then
            G.players[k] = p
            U.log(TAG, "%s joins the couch campaign on a starter build (class %s)", Seat().label(pnum, k), tostring(p.arch))
            save()
        else
            unseated[tonumber(ctrlId) or -1] = p
            U.warn(TAG, "ctrlId %s (P%s) has no seat: a starter build that is not saved", tostring(ctrlId), tostring(pnum))
        end
    else
        if k and p.seat ~= k then p.seat = k end
        if p.arch == nil then p.arch = runArch(G.arch) or 0 end            -- a file from before per-guest classes
        if p.slotsV ~= 1 and F() then F().fitParts(p, "record from before #110"); save() end
        if not p.picked and camp and p.arch ~= camp then
            -- he never chose a class: he follows P1's (a new starter for it, his style kept)
            U.log(TAG, "P%s follows P1's class %s -> %s (no own pick): starter build", tostring(p.pnum),
                tostring(p.arch), tostring(camp))
            starterFor(p, camp, p.style)
            save()
        end
    end
    p.pnum = pnum or p.pnum
    return p
end

-- A guest's pre-run pick (couchprerun): what = "arch" | "style". A changed class or style = a new starter build for
-- it (the run is new: nothing else to keep); the same pick again keeps the build. -> the player
function M.choose(ctrlId, pnum, what, value, why, rank)
    local p = M.ensure(ctrlId, pnum)
    local arch, style = p.arch, p.style
    -- couch-fix29: the rank of the CAM style he picked (couchprerun: the highest rank the unlocks give it)
    local rank0 = p.styleRank
    if what == "style" then
        if tonumber(rank) then p.styleRank = math.floor(tonumber(rank))
        elseif value ~= p.style then p.styleRank = nil end
    end
    if what == "arch" then
        arch = runArch(value)
        if arch == nil then return p end
        p.picked = true
    elseif what == "style" then
        if type(value) ~= "string" or value == "" then return p end
        style = value
        p.stylePicked = true
    else
        return p
    end
    if arch ~= p.arch or style ~= p.style or type(p.lo) ~= "table" or (what == "style" and p.styleRank ~= rank0) then
        starterFor(p, arch, style)
        U.log(TAG, "P%s picks %s %s (%s): starter build %s / %s", tostring(p.pnum), what, tostring(value),
            tostring(why), tostring(arch), tostring(style))
    end
    save()
    return p
end

-- The guest's class for this race: his own (P1's when he has none).
function M.archOf(ctrlId, pnum)
    local p = M.ensure(ctrlId, pnum)
    return runArch(p.arch) or runArch(M.campaignArch()) or runArch(G.arch)
end

function M.player(ctrlId)
    loadState()
    local k = seatKey(ctrlId)
    if k then return G.players[k] end
    return unseated[tonumber(ctrlId) or -1]
end
-- a seat's record (whoever sits there now), or nil
function M.seatPlayer(seat) loadState(); return G.players[tonumber(seat) or -1] end

local journalReset   -- CHECKPOINT JOURNAL (below)
-- M.resetRun (the pre-run screens) and the run identity (bindRun / bindTick): RUN IDENTITY, after the journal below

-- 0.15 F02 DELETE ALL COUCH PROGRESS (couchacts.deleteAll): every guest's run is dropped. Nothing is deleted (hard rule
-- 10): the old file's text is first written to couch-run.bak-<date>-<time>.txt next to it, then couch-run.txt is
-- rewritten in place with an empty state. -> the kept copy's name ("" when there was no file); error() when the copy
-- cannot be written (couch-run.txt is then left as it was).
function M.wipe(why)
    local p = filePath()
    if not p then error("no mod directory") end
    local kept = ""
    local f = io.open(p, "r")
    if f then
        local src = f:read("a")
        f:close()
        if src and src ~= "" then
            kept = "couch-run.bak-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
            local bp = p:gsub("[^/]+$", kept)
            local o = io.open(bp, "w")
            if not o then error("cannot write " .. kept) end
            o:write(src)
            o:close()
        end
    end
    local n = 0
    pcall(loadState)
    if G then for _ in pairs(G.players or {}) do n = n + 1 end end
    local pads = G and G.padSeats or nil
    G = newState()
    G.padSeats = pads                    -- couch-fix31: which pad sat where is no progress
    unseated = {}
    noWrite = nil                        -- the old text is in the .bak copy now: the file may be rewritten
    save()
    U.log(TAG, "couch-run.txt reset (%s): %d guest run(s) dropped%s", tostring(why), n,
        kept ~= "" and (", old file kept as " .. kept) or "")
    journalReset(why, true)              -- the checkpoints go too (their text kept in a .bak copy, like the file's)
    return kept
end

---------------------------------------------------------------------------------------------------- favours
-- NOTE 6 (Jules 2026-10-14, split LOADOUT: "no favors in the bottom part"). Favours (RacerFavour Favour_<Base>_<rank>,
-- 3 slots, perks-loadout.md 2.6) are run perks the game applies to P1's CampaignRun. A guest's own economy is couchrun's
-- (his credits, offers, shop, side bets, build), so the favours whose effect lands in THAT economy are his own,
-- per guest, here (rank values from the favour descriptions):
--   Veteran  "Victorious Loser":  +50% race credits when he finishes in the bottom 3 / 6 / 9 of the grid
--   Nomad    "High Roller":       +50% / 75% / 100% on his won side bets
--   InnerHonour "Smuggler's Hope": 1 part in his shop at 50% / 75% / 99% off
--   Ghost    "Unassuming Prodigy": the tour starts with +2 levels in 1 / 2 / 3 random stats of his build (once a run)
-- #110 (Jules 2026-10-18): EVERY favour is per player now except the team's (Second Chance, Racer Roulette, the
-- token of Clandestine Aid, the map of Preferred Customer): couchfavours.lua has the decoded ranks and effects, the
-- hooks below call it (part slots, shop / pack sizes, the reward flow's tune and bonus rounds, credit lines, repairs,
-- start credits). P1 keeps the game's own effects of his picks.
local GUEST_FAV = { Veteran = { 3, 6, 9 }, Nomad = { 0.5, 0.75, 1.0 }, InnerHonour = { 0.5, 0.75, 0.99 },
                    Ghost = { 1, 2, 3 } }
M.GUEST_FAVOURS = GUEST_FAV

-- "Favour_InnerHonour_2" -> "InnerHonour", 2
function M.favourBase(id)
    local base, r = tostring(id or ""):match("^Favour_(.+)_(%d+)$")
    if not base then return nil, 0 end
    return base, tonumber(r) or 1
end
-- a favour that acts on a guest's own run (#110: every kind but the team-only ones)
function M.guestFavour(id)
    local f = F()
    if f then return f.perPlayer(id) end
    local b = M.favourBase(id)
    return b ~= nil and GUEST_FAV[b] ~= nil
end
-- #110: a favour of P1's whose effect (or part of it) is the team's: Second Chance, Racer Roulette, Clandestine Aid's
-- token, Preferred Customer's map (a guest's backer page lists them as the team's)
function M.teamFavour(id)
    local f = F()
    local b = M.favourBase(id)
    if not (f and b) then return not M.guestFavour(id) end
    local d = f.DEF[b]
    return d == nil or d.scope == "team" or d.scope == "mixed"
end
-- his rank of a favour base (0 = not equipped)
local function favRank(p, base)
    local best = 0
    for i = 1, 3 do
        local b, r = M.favourBase(p and p.favours and p.favours[i])
        if b == base and r > best then best = r end
    end
    return best
end
M.favRank = favRank

-- his 3 favour slots (ids or false). #101 (Jules 2026-10-18: the guests get the SAME favour choices as P1): any
-- RacerFavour id P1's account has unlocked is kept, per seat. The per-guest EFFECTS stay those of GUEST_FAV (they act
-- in his own economy, favRank); a run-wide kind (League tokens, map, crash allowance, P1's packs / reward rounds,
-- rivals) acts on the one shared run, through P1's own loadout.
function M.setFavours(ctrlId, pnum, list)
    local p = M.ensure(ctrlId, pnum)
    local out = {}
    for i = 1, 3 do
        local id = list and list[i]
        out[i] = (id and M.favourBase(id) ~= nil) and id or false
    end
    p.favours = out
    if F() then F().fitParts(p, "favours") end            -- #110 Gadgeteer: his part slots
    save()
    U.log(TAG, "P%s favours: %s", tostring(p.pnum), table.concat({ tostring(out[1]), tostring(out[2]), tostring(out[3]) }, ", "))
    return p
end

-- #110: every guest record of this run (couchfavours: the team's favour ranks)
function M.players() loadState(); return G.players end
-- his part slots (couchpanel's INSTALLED PARTS n/m)
function M.partSlotsOf(ctrlId)
    local p = M.player(ctrlId)
    local f = F()
    if not (p and f) then return nil end
    return f.partSlots(p)
end
-- #110 the team favours' state of P1's run (G.team, a new one per run: RunId + map seed); G.pending survives a new run
-- (Mad Genius III: a knock-out's token at the next tour's start)
function M.teamState()
    loadState()
    local key = "?"
    pcall(function()
        local f = M.fpOf(activeRun())
        if type(f) == "table" then key = string.format("%s:%s", tostring(f.id or "-"), tostring(f.seed or "-")) end
    end)
    if key == "?" then return type(G.team) == "table" and G.team or {} end      -- P1's run unreadable: no reset
    if type(G.team) ~= "table" or G.team.key ~= key then
        local pend = type(G.pending) == "table" and G.pending or {}
        G.team = { key = key, pendingMech = pend.mech == true and key ~= pend.from or nil }
        if G.team.pendingMech then G.pending = nil end
    end
    return G.team
end
function M.saveTeam() save() end
function M.setPending(what, on)
    loadState()
    G.pending = type(G.pending) == "table" and G.pending or {}
    G.pending[what] = on or nil
    G.pending.from = type(G.team) == "table" and G.team.key or nil
    save()
end

-- the tour starts (the loadout screen closes on a new run): Ghost's levels, once a run
function M.startTour(ctrlId, pnum)
    local p = M.ensure(ctrlId, pnum)
    if p.tourStarted then return 0 end
    p.tourStarted = true
    -- ECONOMY: the run's STARTING credits. P1's run starts with its sponsor's StartingCredits (+ carryover; 3,800 in
    -- the 2026-10-14 qualifier) and a guest started at 0. At the run's first grid P1 has earned nothing yet: his
    -- credits ARE the start credits. cfg.CouchGuestStartCredits = "p1" (default) | a number | false (0).
    -- couch-fix31 (audit Q11): "p1" = P1's run-START figure of this run (M.runStartCredits, noted per run id when the
    -- run is first seen at its start), never his wallet now: a late joiner / a guest fresh after a CONTINUE gets the
    -- same start as everyone. Unknown (a run started before this build, no run-start checkpoint): the wallet, WARN.
    local sc = opt("CouchGuestStartCredits", "p1")
    local grant = 0
    local f = F()
    local act = actEngine()
    if sc == "p1" then
        local start, src, atStart = M.runStartCredits()
        if start == nil then
            start = M.campaignCredits()
            U.warn(TAG, "P%s: P1's run-start credits unknown for this run: his wallet now (%s CR) is the start",
                tostring(p.pnum), tostring(start))
        elseif not atStart then
            U.log(TAG, "P%s starts the tour mid-run: P1's run-start figure %d CR (%s), not his wallet now (%s CR)",
                tostring(p.pnum), math.floor(tonumber(start) or 0), src, tostring(M.campaignCredits()))
        end
        grant = math.max(0, math.floor(tonumber(start) or 0))
        -- #110 Clandestine Aid: P1's start credits carry P1's own CarryoverCreditsFlatBonus (never a guest's); his own
        -- rank adds his (not in Act III: Darius Pax is gone)
        if f then grant = f.startCredits(grant, p, act) end
    elseif tonumber(sc) then
        grant = math.max(0, math.floor(tonumber(sc)))
        if f and act ~= 3 then grant = grant + (f.v("Promoter", "credits", f.rank(p, "Promoter")) or 0) end
    end
    if grant > 0 then
        p.credits = (p.credits or 0) + grant
        U.log(TAG, "P%s starts the run with %d CR (P1's starting credits%s; total %d)", tostring(p.pnum), grant,
            (f and f.rank(p, "Promoter") > 0) and ", his Clandestine Aid" or "", p.credits)
    end
    local r = favRank(p, "Ghost")
    local n = r > 0 and GUEST_FAV.Ghost[r] or 0
    local pool = {}
    for s = 0, 5 do if (tonumber(p.lo.tune[s]) or 0) < LEVEL_MAX then pool[#pool + 1] = s end end
    local got = {}
    for _ = 1, n do
        if #pool == 0 then break end
        local s = table.remove(pool, math.random(#pool))
        p.lo.tune[s] = math.min(LEVEL_MAX, (tonumber(p.lo.tune[s]) or 0) + 2)
        got[#got + 1] = tostring(s)
    end
    save()
    if n > 0 then U.log(TAG, "P%s Unassuming Prodigy %d: +2 levels in stat(s) %s", tostring(p.pnum), r, table.concat(got, ",")) end
    return #got
end

---------------------------------------------------------------------------------------------------- offers
-- run.lua's content helpers run on a SHADOW run (its own R swapped in for the call, restored after); none of the
-- helpers used here saves.
local function withShadow(p, fn)
    local rm = run()
    local old = rm.state()
    local planet, kind = nodeInfo()
    rm._set({ status = "on", arch = p.arch or G.arch, players = { [0] = p }, lastSlot = planet, lastKind = kind,
              hull = 99, tokensMax = 99, race = 2, cursor = { p = planet } })
    local ok, res = pcall(fn, rm)
    rm._set(old)
    if not ok then U.warn(TAG, "shadow run: %s", tostring(res)); return nil end
    return res
end

local function statRow(s, p)
    local st = PD and PD.STATS and PD.STATS[s] or nil
    local name = st and st.name or ("STAT " .. s)
    local arch = p.arch or G.arch
    if s == 5 and PD and PD.ADVANCED and PD.ADVANCED[arch] then name = PD.ADVANCED[arch] end
    local cur = math.floor(tonumber(p.lo.tune[s]) or 0)
    return { rkind = "stat", id = s, name = name .. " +1", sub = string.format("LEVEL %d -> %d", cur, cur + 1),
             icon = st and st.large or (st and st.icon), desc = st and st.desc or "", grade = 1 }
end

-- SKIP: the planet's native SkipRewardEconomyId value (1000 on every planet but Act III's final Derven Acos: 5000)
local function skipRow()
    local cr = skipCredits()
    return { rkind = "skip", id = "skip", name = "SKIP REWARD", sub = string.format("+%d CR", cr), credits = cr }
end

local function catalogKind(p, kind, n)
    return withShadow(p, function(rm)
        local out, taken = {}, {}
        -- (a one-kind stock of 4 needs more draws than 12: run.lua's graded draw is one item of a random kind)
        for _ = 1, math.max(12, n * 10) do
            if #out >= n then break end
            local offer = rm.makeOffer(p, 1) or {}
            for _, it in ipairs(offer) do
                -- fix16: run.lua's offer ends with its SKIP row ("SKIP: +1000 CR"): never a catalog item (it became a
                -- shop card after RESTOCK); the offers add their own SKIP (skipRow)
                if it.rkind ~= "skip" and it.id ~= "skip"
                    and (kind == nil or it.rkind == kind) and it.id and not taken[tostring(it.rkind) .. tostring(it.id)] then
                    taken[tostring(it.rkind) .. tostring(it.id)] = true
                    out[#out + 1] = it
                    break
                end
            end
        end
        return out
    end) or {}
end

local REWARD_KIND = { [1] = "stat", [2] = "ab", [3] = "trait", [4] = "part" }
M.REWARD_KIND = REWARD_KIND
-- the reward flow's collection stages (RewardsCollectionStageVM.CollectionType, ERewardsCollectionType: Credits 1,
-- VehicleUpgrade 2, Ability 3, Modifier 4, Affix 5, Faults 6) -> the guest offer kind; 2..5 are CHOOSE AN UPGRADE rounds
local STAGE_KIND = { [2] = "stat", [3] = "ab", [4] = "trait", [5] = "part" }
M.STAGE_KIND = STAGE_KIND
M.KIND_NAME = { stat = "stat levels (UPGRADE PACK)", ab = "abilities", trait = "modifiers", part = "parts", mixed = "mixed" }

-- the SKIP REWARD row of a guest (couchpanel: an area closed unpicked books it, never nothing)
function M.skipRow() return skipRow() end

-- pure (tests): the guest offer kind for P1's round -> want, why (why = nil when P1's round kind is mirrored)
-- round = M.nativeRound() (nil: no reward round on P1's node), stageKind = the flow's upgrade stage kind if known
function M.offerKind(round, stageKind)
    if round and (tonumber(round.n) or 0) > 0 then
        local k = REWARD_KIND[tonumber(round.type) or -1]
        if k then return k, nil end
        return stageKind or "stat", string.format("P1's round type %s has no guest equivalent", tostring(round.type))
    end
    if stageKind then return stageKind, nil end
    return "stat", "P1's reward has no CHOOSE AN UPGRADE round (credits / faults only)"
end

-- A guest's offer mirroring P1's current round (3 choices + SKIP). Every reward moment gives the guest an area: a round
-- kind without a guest equivalent (or no round at all: an act-finish / credits-only flow, live 2026-10-17) = the
-- closest kind (stat levels, the UPGRADE PACK), logged; nothing buildable = the SKIP-for-credits row alone.
function M.makeOffer(ctrlId, stageKind, noRound)
    loadState()
    local p = M.player(ctrlId)
    if not p then return nil end
    -- noRound: P1's reward flow itself has no upgrade stage (couchpanel read its RewardsCollectionVM)
    local native = (not noRound) and M.nativeRound() or nil
    local want, why = M.offerKind(native, stageKind)
    local round = (native and (tonumber(native.n) or 0) > 0) and native or { type = 1, n = 3, skippable = true }
    if why then
        U.log(TAG, "P%s's reward: %s - his area gets the closest kind: %s", tostring(p.pnum), why,
            M.KIND_NAME[want] or want)
    end
    local n
    -- #110: P1's round carries P1's own Bloody Bounty / Deeper Pockets card count and (couch-fix32) P1's own "fewer
    -- reward choices" deal: those off first, then the native clamp, then HIS favours and HIS "fewer reward choices" deal
    -- (Favour_MYST_LessEventRewardChoices: -1 part / affix reward natively)
    local f = F()
    if f and f.offerCards then
        local p1d, p1f = 0, 0
        if native then
            p1d = f.cardDelta(f.p1Favours())
            p1f = f.p1Has("Favour_MYST_LessEventRewardChoices") and 1 or 0
        end
        n = f.offerCards(round.n, p1d, p1f, f.cardDelta(p.favours), mods(p).fewer)
    else
        n = math.max(1, math.max(2, math.min(4, round.n > 0 and round.n or 3)) - math.floor(mods(p).fewer))
    end
    local rows = {}
    if want == "stat" then
        local pool = {}
        for s = 0, 5 do
            if (tonumber(p.lo.tune[s]) or 0) < LEVEL_MAX then pool[#pool + 1] = s end
        end
        for _ = 1, n do
            if #pool == 0 then break end
            local s = table.remove(pool, math.random(#pool))
            rows[#rows + 1] = statRow(s, p)
        end
    else
        rows = catalogKind(p, want ~= "mixed" and want or nil, n)
        if #rows < n then
            for _, it in ipairs(catalogKind(p, nil, n - #rows)) do rows[#rows + 1] = it end
        end
    end
    if round.skippable ~= false or #rows == 0 then rows[#rows + 1] = skipRow() end
    p.offer = rows
    p.offerType = want
    save()
    U.log(TAG, "P%s offer (%s, mirrors P1's round type %s): %d choice(s)", tostring(p.pnum), want,
        tostring(round.type), #rows)
    return rows
end

-- NOTE 8: n offer rows of the native card type itype (1 stat, 2 ability, 3 trait, 4 part) for a guest whose offer
-- lacks them (his copy keeps every native card's type): appended to his pending offer so a claim finds them
function M.offerOfType(ctrlId, itype, n)
    loadState()
    local p = M.player(ctrlId)
    if not p then return {} end
    local kind = REWARD_KIND[tonumber(itype) or 0]
    if not kind then return {} end
    local rows = {}
    if kind == "stat" then
        local pool = {}
        for s = 0, 5 do if (tonumber(p.lo.tune[s]) or 0) < LEVEL_MAX then pool[#pool + 1] = s end end
        for _ = 1, n do
            if #pool == 0 then break end
            rows[#rows + 1] = statRow(table.remove(pool, math.random(#pool)), p)
        end
    else
        rows = catalogKind(p, kind, n)
    end
    return rows
end

-- first free slot of a kind in a loadout (ab 1..4, parts / traits by index), or nil
local function freeSlot(lo, kind)
    if kind == "ab" then for n = 1, 4 do if not lo.ab[n] then return n end end end
    if kind == "part" then for i = 1, #(lo.parts or {}) do if not lo.parts[i] then return i end end end
    if kind == "trait" then for i = 1, #(lo.traits or {}) do if not lo.traits[i] then return i end end end
    return nil
end

---------------------------------------------------------------------------------------------------- part slots full
-- FINDING #95 (Jules's 1:1 rule): a part bought / picked with every part slot full. Solo (decoded WBP_Item_Btn /
-- WBP_ItemChangeModifier, CL381121): the card's click checks CampaignItemVM:PlayerMustPickReplacement(); when true the
-- game posts ReplaceAffixMessage = WBP_ItemChangeModifier ("Part Slots Full" / "Your Part slots are full. Would you
-- like to replace one?"): the new part on top (locked), the build's parts below (VehicleBuildVM:GetBuildItemsOfType,
-- plane-only parts filtered out, a FAULTY part greyed: ApplyFaultyDisabledLook, it "cannot be replaced until
-- repaired"); a part = SetItemToBeReplaced + Accept -> the buy / pick goes through with that part replaced (it leaves
-- the car), Cancel = nothing bought, nothing picked. A guest gets the same choice in his area (couchpanel V.replace*):
-- item.replace = the installed part he picked; applyClaim puts the new part in that slot, the old one stays owned.
-- does this part need his PART SLOTS FULL choice? (a part not in his build, no free part slot)
function M.mustReplace(ctrlId, item)
    if type(item) ~= "table" or item.rkind ~= "part" or item.replace then return false end
    local p = M.player(ctrlId)
    local lo = p and p.lo
    if type(lo) ~= "table" or type(lo.parts) ~= "table" or #lo.parts == 0 then return false end
    for _, x in ipairs(lo.parts) do if x == item.id then return false end end
    return freeSlot(lo, "part") == nil
end
local function partFaulty(p, id)
    if type(p.faults) == "table" and p.faults[id] then return true end
    return M.isFaultyPart(id) and not (type(p.fixed) == "table" and p.fixed[id])
end
-- the parts his new part can replace, in slot order: { rkind = "vreplace", id, slot, name, faulty } + the cancel row
function M.replaceRows(ctrlId)
    local p = M.player(ctrlId)
    local rows = {}
    for i, id in ipairs(p and p.lo and p.lo.parts or {}) do
        local d = id and PD and PD.PARTS and PD.PARTS[id]
        if id and not (d and d.planeOnly) then
            local bad = partFaulty(p, id)
            rows[#rows + 1] = { rkind = "vreplace", id = id, slot = i, name = tostring(d and d.name or id),
                                faulty = bad, icon = d and d.icon, desc = d and (d.desc or d.rich) or "",
                                sub = bad and "FAULTY - REPAIR IT AT THE SCRAP DEALER FIRST" or "INSTALLED PART" }
        end
    end
    rows[#rows + 1] = { rkind = "vkeep", id = "vkeep", name = "DON'T REPLACE",
                        sub = "Keep your parts - nothing bought" }
    return rows
end
-- item.replace (when set) names one of his installed, non-faulty parts. -> ok, why
function M.replaceValid(ctrlId, item)
    if type(item) ~= "table" or not item.replace then return true end
    local p = M.player(ctrlId)
    if not (p and p.lo) then return false, "NO BUILD" end
    local here = false
    for _, x in ipairs(p.lo.parts or {}) do if x == item.replace then here = true end end
    if not here then return false, "NOT IN YOUR BUILD" end
    if partFaulty(p, item.replace) then return false, "FAULTY PARTS CANNOT BE REPLACED UNTIL REPAIRED" end
    return true
end

local flowClaimed    -- OWN REWARD FLOW (below)

-- A guest claims an offer row: owned + equipped (a full slot kind keeps the item owned for the shop's swap).
-- applyClaim works on any player record (the live one, or a checkpoint's copy: runsync). -> toast text
local function applyClaim(p, item)
    local lo, toast = K().copy(p.lo), nil
    if item.rkind == "skip" then
        p.credits = (p.credits or 0) + (tonumber(item.credits) or 0)
        toast = string.format("+%d CR", tonumber(item.credits) or 0)
    elseif item.rkind == "stat" then
        -- an UPGRADE PACK row carries its rolled levels (lv 1..3); a reward round's stat row is +1
        local lv = math.max(1, math.floor(tonumber(item.lv) or 1))
        lo.tune[item.id] = math.min(LEVEL_MAX, (tonumber(lo.tune[item.id]) or 0) + lv)
        toast = item.name
    elseif item.rkind == "upgrade" then
        p.cap = (p.cap or 1) + 1
        toast = "LEVEL CAP " .. p.cap
    else
        p.owned[item.rkind] = p.owned[item.rkind] or {}
        p.owned[item.rkind][item.id] = true
        local upSlot = nil                       -- an ABILITY PACK's next pip replaces the ability it grows from
        if item.rkind == "ab" and item.up and item.from then
            for n = 1, 4 do if lo.ab[n] == item.from then upSlot = n; break end end
        end
        -- #95: a part with his part slots full replaces the installed part he picked (item.replace, the game's
        -- PART SLOTS FULL choice: SetItemToBeReplaced); the replaced part stays owned (the garage swap)
        local repSlot = nil
        if item.rkind == "part" and item.replace then
            for i = 1, #(lo.parts or {}) do if lo.parts[i] == item.replace then repSlot = i; break end end
        end
        if item.rkind == "crash" then
            lo.crash = item.id
        elseif upSlot then
            lo.ab[upSlot] = item.id
        elseif repSlot then
            lo.parts[repSlot] = item.id
        else
            local slot = freeSlot(lo, item.rkind)
            if slot then
                if item.rkind == "ab" then lo.ab[slot] = item.id
                elseif item.rkind == "part" then lo.parts[slot] = item.id
                elseif item.rkind == "trait" then lo.traits[slot] = item.id end
            end
        end
        toast = tostring(item.name or item.id)
    end
    -- couch-fix29: validated on HIS part slots (Gadgeteer can give more than the board's PerkPartSlots: never cut)
    local okV, v = pcall(function() return K().validate(lo, p.arch or G.arch, p.style, F() and F().partSlots(p) or nil) end)
    p.lo = (okV and type(v) == "table") and v or lo
    if F() then F().fitParts(p, "claim") end              -- #110: validate pads to PerkPartSlots, his are his own
    p.offer = nil
    if item.fstage then flowClaimed(p, item, p.lo) end      -- couch-rewards2: his own flow moves on
    return toast
end

-- a claim on his live run (shop buys and mystery parts go through here: never folded into a checkpoint)
local function claimLive(ctrlId, item)
    loadState()
    local p = M.player(ctrlId)
    if not p or type(item) ~= "table" then return nil end
    local toast = applyClaim(p, item)
    save()
    U.log(TAG, "P%s claimed %s (%s)", tostring(p.pnum), tostring(item.name or item.id), tostring(item.rkind))
    if item.replace then
        local d = PD and PD.PARTS and PD.PARTS[item.replace]
        local on = false
        for _, x in ipairs(p.lo and p.lo.parts or {}) do if x == item.id then on = true end end
        U.log(TAG, "P%s: PART SLOTS FULL - %s replaces %s on his car (%s; the old part stays owned)", tostring(p.pnum),
            tostring(item.name or item.id), tostring(d and d.name or item.replace),
            on and "installed" or "NOT installed")
    end
    return toast
end

local amendClaim     -- CHECKPOINT JOURNAL (below)

-- his REWARD claim (couchpanel): the live claim, then folded into a checkpoint that was taken while this very offer
-- was already open (runsync: the "after rewards" save comes with P1's pick, the guest picks a moment later)
function M.claim(ctrlId, item)
    -- couch-rewards2: a row of a flow stage already collected (a second press on the old round) claims nothing
    if type(item) == "table" and item.fstage then
        local p = M.player(ctrlId)
        local st = p and type(p.flow) == "table" and p.flow.seed == item.fseed and p.flow.stages
            and p.flow.stages[tonumber(item.fstage)] or nil
        if not st or st.collected then
            U.warn(TAG, "P%s: %s refused (its reward stage is %s)", tostring(p and p.pnum), tostring(item.name or item.id),
                st and "already collected" or "not in his flow")
            return nil
        end
    end
    if not M.replaceValid(ctrlId, item) then return nil end            -- #95: a faulty / foreign part to replace
    local toast = claimLive(ctrlId, item)
    if toast ~= nil then U.try(TAG, amendClaim, ctrlId, item) end
    return toast
end

---------------------------------------------------------------------------------------------------- mystery
-- NOTE 10 (Jules 2026-10-14: "in the weird encounter there was the option just for P1"). A paddock MYSTERY ENCOUNTER
-- (MysteryInteraction: Choices[] -> MysteryInteractionChoice {choice, ExtraInformation, Outcomes[]} -> weighted
-- MysteryInteractionOutcome, JMAP CL381121) is applied natively to P1's run only (CampaignRun:
-- ChooseMysteryInteractionOutcome). A guest's choice is applied HERE to HIS couch run from the outcome's own data:
--   ResultNumCreditsToExchange (his credits; a negative amount is the choice's cost: he must have it),
--   ResultUpgradeItems {PartSlot = EVehiclePartSlot = his stat 0..5, UpgradeLevels, MinimumUpgradeLevelRequired},
--   ResultAffixRewardPools (one part each, from his catalog), NumRandomAffixesToLose / NumRandomAbilitiesToLose.
-- Run-wide effects stay P1's: League tokens, favours (the MYST passives act on P1's run), unlock tags, bookends,
-- chains, races. A choice whose every outcome is run-wide only is shown READ-ONLY for a guest; a choice without any
-- effect (a pass / fallback) is his "no deal".
-- FINDING #112: a choice with a bookend outcome (mystdata bk) is greyed for a guest (cfg.CouchMysteryGreyDelayed).

-- couch-fix32 (audit 12 issue 7, Jules's rule: a guest's mystery outcome = the solo outcome on HIS economy, else
-- greyed). cfg.CouchMysteryStrict (default on):
--   * a choice is a guest's only when EVERY effect of EVERY outcome has a guest implementation: credits, stat levels,
--     lost parts / abilities, the MYST economy favours (MYST_FAV), reward pools (below). A League token, any other
--     favour (sabotage, race debuffs, difficulty, the scrap dealer's token deal), FavoursToRemove or a RunUnlock tag
--     is P1's run only: such a choice that ALSO pays / charges him is greyed ("mixed": 152A paid for a sabotage he never
--     got, 013 / 014 / 136 kept the upside without the drawback, 109's token bought from his wallet for the team);
--   * a reward pool rolls its own native groups (mystdata POOLS: the RewardPoolDef's AffixGroups with their
--     FaultyChancePercent, GeneratedAffixGroups primary + secondary; mystdata GROUPS = DA_CampaignRewardGroups) over the
--     parts of HIS car (the part picker's catalog, not owned / equipped): MYST_049 "Spend 400, Gain 2 Rare Faulty Parts"
--     = 2 Rare parts each with a Faulty drawback (it was 2 clean random parts); a pool no part of his car fits greys
--     the choice for him (NO SUCH PART FOR YOUR CAR); a pool mystdata does not know (a newer game build) is not rolled;
--   * a follow-up interaction of an earlier deal (mystdata FOLLOW: an outcome's ResultBookend target or unlocked by a
--     RunUnlock.Mystery.Bookend tag - 108's +1,500 / -2,500, 157's payouts, 113B...) pays the run that made the deal:
--     greyed for every guest ("P1'S DEAL"); before, an unknown outcome with credits was a guest row = P1's payout
--     claimable by every guest.
local partPool       -- his part candidates (own reward flow, below)
local function strictMyst() return cfg.CouchMysteryStrict ~= false end
M.MYST_MIXED_REASON = "NOT AVAILABLE FOR GUESTS"
M.MYST_FOLLOW_REASON = "P1'S DEAL"
M.MYST_NOPART_REASON = "NO SUCH PART FOR YOUR CAR"

-- the static data of an outcome (mystdata) or nil
local function outcomeRow(key)
    local row = key and MD.OUTCOMES[key]
    return type(row) == "table" and row or nil
end

-- a MysteryInteractionOutcome -> plain data (no UObject kept). key = outcomeKey(...) (its favours from mystdata)
local function outcomeData(o, key)
    local d = { w = 1, credits = 0, tokens = 0, ups = {}, pools = 0, loseParts = 0, loseAb = 0, runOnly = 0, text = "" }
    pcall(function() d.w = math.max(0, tonumber(o.WeightedChance) or 1) end)
    pcall(function() d.credits = math.floor(tonumber(o.ResultNumCreditsToExchange) or 0) end)
    pcall(function() d.tokens = math.floor(tonumber(o.ResultNumTokensToExchange) or 0) end)
    pcall(function()
        for _, u in ipairs(U.arrayToTable(o.ResultUpgradeItems)) do
            local slot, lv, mn = nil, 0, 0
            pcall(function() slot = tonumber(u.PartSlot) end)
            pcall(function() lv = math.floor(tonumber(u.UpgradeLevels) or 0) end)
            pcall(function() mn = math.floor(tonumber(u.MinimumUpgradeLevelRequired) or 0) end)
            if slot and slot >= 0 and slot <= 5 and lv ~= 0 then d.ups[#d.ups + 1] = { slot = slot, lv = lv, min = mn } end
        end
    end)
    -- soft arrays: the COUNT only (GetArrayNum reads the TArray header, never an element: FINDING #111)
    pcall(function() d.pools = U.arrayCount(o.ResultAffixRewardPools) end)
    pcall(function() d.loseParts = math.max(0, math.floor(tonumber(o.NumRandomAffixesToLose) or 0)) end)
    pcall(function() d.loseAb = math.max(0, math.floor(tonumber(o.NumRandomAbilitiesToLose) or 0)) end)
    -- favours: the MYST_* economy favours (MYST_FAV) become HIS (d.favs); any other favour stays P1's run-wide one.
    -- The names come from mystdata; an outcome it does not know counts every favour as run-wide (read-only for him)
    local nf, nr = 0, 0
    d.favs = {}
    local others = {}                                      -- couch-fix39: the run-wide favour names (team or not)
    local row = outcomeRow(key)
    local names = row and type(row.favs) == "table" and row.favs or nil
    if names then
        for _, n in ipairs(names) do
            if MYST_FAV[n] then
                if not MYST_FAV[n].none then d.favs[#d.favs + 1] = n end
                if MYST_FAV[n].rager then d.ragerBet = true end
            elseif UNLOCK_FAV[n] then                      -- couch-fix48: an unlock, no run favour (solo parity)
                d.unlocks = d.unlocks or {}
                d.unlocks[#d.unlocks + 1] = n
            else
                nf = nf + 1
                others[#others + 1] = n
            end
        end
    else
        pcall(function() nf = math.max(0, U.arrayCount(o.ResultFavours)) end)
        if nf > 0 then
            d.unknownFavs = true
            U.log(TAG, "mystery outcome %s: %d favour(s) not in mystdata - P1's run only for the guests", tostring(key), nf)
        end
    end
    pcall(function() nr = math.max(0, U.arrayCount(o.FavoursToRemove)) end)
    nr = math.max(nr, math.floor(tonumber(row and row.rm) or 0))
    -- couch-fix46: a Biddy Blas bet's removals are the other bet levels = his own previous bet, replaced (his mods)
    if d.ragerBet then nr = 0 end
    local runTags = math.floor(tonumber(row and row.run) or 0)
    d.runOnly = nf + nr + ((d.tokens ~= 0) and 1 or 0)
    pcall(function() d.text = o.Outcome:ToString() end)
    d.delayed = type(row) == "table" and row.bk == true
    -- couch-fix32: the reward pools by name (static: ResultAffixRewardPools is a soft array) and every effect without a
    -- guest implementation (d.unsup: the first one names it in the log)
    d.poolNames = (row and type(row.pools) == "table") and row.pools or nil
    local unsup = {}
    -- couch-fix39: with CouchMysteryTeam "allowed" a League token and a TEAM_FAV favour (its asset path known) are his
    -- TEAM effects (d.team: applied to the shared run, once per encounter); any other run favour stays unsupported
    local allowed = teamAllowed()
    d.team = {}
    if d.tokens ~= 0 then
        if allowed then d.team[#d.team + 1] = { k = "tok:" .. d.tokens, tokens = d.tokens }
        else unsup[#unsup + 1] = "League token" end
    end
    if nf > 0 then
        local teamOk = allowed and names ~= nil
        if teamOk then
            for _, n in ipairs(others) do
                if not (TEAM_FAV[n] and type(MD.FAVPATH) == "table" and MD.FAVPATH[n]) then teamOk = false end
            end
        end
        if teamOk then
            for _, n in ipairs(others) do d.team[#d.team + 1] = { k = "fav:" .. n, fav = n } end
        else
            unsup[#unsup + 1] = "run favour"
        end
    end
    if nr > 0 then unsup[#unsup + 1] = "favour removal" end
    if runTags > 0 then unsup[#unsup + 1] = "run unlock" end
    if d.pools > 0 and not (d.poolNames and #d.poolNames == d.pools) then unsup[#unsup + 1] = "unknown reward pool" end
    d.unsup = unsup
    if strictMyst() and runTags > 0 then d.runOnly = d.runOnly + runTags end
    d.guest = d.credits ~= 0 or #d.ups > 0 or d.pools > 0 or d.loseParts > 0 or d.loseAb > 0 or #d.favs > 0
        or #d.team > 0 or (d.unlocks ~= nil and #d.unlocks > 0)
    return d
end
M.outcomeData = outcomeData

-- the part ids of an affix group (mystdata GROUPS, DA_CampaignRewardGroups) that perkdata knows -> set
local function groupSet(g)
    local out = {}
    for _, id in ipairs((MD.GROUPS or {})[g] or {}) do if PD and PD.PARTS and PD.PARTS[id] then out[id] = true end end
    return out
end
-- a pool's choices for him: { {w, cands = {ids}, faults = {ids} | nil, chance} } (only entries with a part he can use)
local function poolEntries(p, poolName, taken)
    local def = MD.POOLS and MD.POOLS[poolName]
    if type(def) ~= "table" then return nil end
    local usable = {}
    for _, it in ipairs(partPool(p)) do if not (taken and taken[it.id]) then usable[#usable + 1] = it.id end end
    local function cands(g)
        local set, out = groupSet(g), {}
        for _, id in ipairs(usable) do if set[id] then out[#out + 1] = id end end
        return out
    end
    local function faultIds(groups)
        local out, seen = {}, {}
        for _, g in ipairs(groups or {}) do
            local ids = {}
            for id in pairs(groupSet(g)) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
            table.sort(ids)
            for _, id in ipairs(ids) do out[#out + 1] = id end
        end
        return out
    end
    local out = {}
    for _, e in ipairs(def) do
        local w = tonumber(e.w) or 0
        if w > 0 then
            local c = cands(e.g)
            if #c > 0 then
                local f = tonumber(e.f) or 0
                out[#out + 1] = { w = w, cands = c, chance = f, faults = f > 0 and faultIds(e.fg) or nil, g = e.g }
            end
        end
    end
    for _, e in ipairs(def.gen or {}) do
        local w = tonumber(e.w) or 0
        local c = cands(e.g)
        local fl = faultIds({ e.s })
        if w > 0 and #c > 0 and #fl > 0 then
            out[#out + 1] = { w = w, cands = c, chance = 100, faults = fl, g = e.g .. "+" .. e.s }
        end
    end
    return out
end
-- can a pool give him a part? (nil = the pool is not in mystdata)
local function poolFits(p, poolName)
    local e = poolEntries(p, poolName)
    if e == nil then return nil end
    return #e > 0
end
M._poolFits = poolFits

-- one part from a pool for him (rnd = math.random-like) -> claim item (rkind part, id, name, pips, fault?) or nil
local function poolPart(p, poolName, rnd, taken)
    local es = poolEntries(p, poolName, taken)
    if not es or #es == 0 then return nil end
    local total = 0
    for _, e in ipairs(es) do total = total + e.w end
    local x, pick = rnd() * total, es[#es]
    for _, e in ipairs(es) do
        x = x - e.w
        if x < 0 then pick = e; break end
    end
    local id = pick.cands[rnd(#pick.cands)]
    local d = PD.PARTS[id]
    local rar = tonumber(d and d.rarity) or 0
    local item = { rkind = "part", id = id, name = tostring(d and d.name or id), grade = math.min(4, rar + 1),
                   pips = math.max(1, math.min(4, rar + 1)), pool = poolName, group = pick.g }
    if pick.faults and #pick.faults > 0 and rnd() * 100 < pick.chance then
        local fid = pick.faults[rnd(#pick.faults)]
        item.fault = fid
        item.faultName = tostring(PD.PARTS[fid] and PD.PARTS[fid].name or fid)
    end
    return item
end
M._poolPart = poolPart

-- the guest's rows of a mystery interaction (P1's native screen's, same order as its Choices list). Each row:
-- {rkind = "myst", i, name, desc, outs = {outcomeData...}, cost, mode = "guest" | "pass" | "run" | "mixed" | "follow",
--  why (the grey reason of a mixed / follow row)}
function M.mysteryRows(ctrlId, interaction)
    loadState()
    local p = M.player(ctrlId)
    if not p or not U.ok(interaction) then return {} end
    local rows = {}
    local choices = {}
    pcall(function() choices = U.arrayToTable(interaction.Choices) end)
    local strict = strictMyst()
    local iname = U.objName(interaction)
    local follow = strict and type(MD.FOLLOW) == "table" and MD.FOLLOW[iname] == true
    for i, c in ipairs(choices) do
        if U.ok(c) then
            local r = { rkind = "myst", i = i, name = "", desc = "", outs = {}, cost = 0, choice = c, inter = iname }
            pcall(function() r.name = c.choice:ToString() end)
            pcall(function() r.desc = c.ExtraInformation:ToString() end)
            local anyGuest, anyRun, unsup = false, false, nil
            pcall(function()
                for _, o in ipairs(U.arrayToTable(c.Outcomes)) do
                    if U.ok(o) then
                        local d = outcomeData(o, outcomeKey(interaction, c, o))
                        r.outs[#r.outs + 1] = d
                        if d.delayed then r.delayed = true end
                        if d.guest then anyGuest = true end
                        if d.runOnly > 0 then anyRun = true end
                        if d.credits < 0 then r.cost = math.max(r.cost, -d.credits) end
                        if strict then
                            if not unsup and d.unsup[1] then unsup = { d.unsup[1], M.MYST_MIXED_REASON } end
                            for _, pn in ipairs(d.poolNames or {}) do
                                if not unsup and poolFits(p, pn) == false then
                                    unsup = { "no part of his car in " .. tostring(pn), M.MYST_NOPART_REASON }
                                end
                            end
                        end
                    end
                end
            end)
            r.mode = anyGuest and "guest" or (anyRun and "run" or "pass")
            if follow and r.mode ~= "pass" then
                r.mode, r.why = "follow", M.MYST_FOLLOW_REASON
            elseif unsup and anyGuest then
                r.mode, r.why = "mixed", unsup[2]
                U.log(TAG, "P%s mystery %s choice %d greyed for him: %s (%s)", tostring(p.pnum), tostring(iname), i,
                    unsup[2], unsup[1])
            end
            rows[#rows + 1] = r
        end
    end
    if follow and #rows > 0 then
        U.log(TAG, "P%s mystery %s: a follow-up of P1's own deal - its choices are P1's", tostring(p.pnum), tostring(iname))
    end
    return rows
end

-- FINDING #112: a choice paid (partly) by a bookend later in the run is not tracked per guest yet (the bookend runs on
-- P1's run only: a guest could pay now and never get the payout) -> greyed on the guests' halves with this reason
M.MYST_DELAYED_REASON = "NOT AVAILABLE FOR GUESTS YET"
function M.mysteryGreyDelayed() return cfg.CouchMysteryGreyDelayed ~= false end
-- the reasons of a greyed choice that its focused entry spells out (couchpanel: the line under it)
M.MYST_GREY_REASONS = { [M.MYST_DELAYED_REASON] = true, [M.MYST_MIXED_REASON] = true, [M.MYST_FOLLOW_REASON] = true,
                        [M.MYST_NOPART_REASON] = true }

-- can this guest take that row? -> ok, reason
function M.mysteryValid(ctrlId, row)
    local p = G and M.player(ctrlId)
    if not p or type(row) ~= "table" then return false, "?" end
    if row.mode == "follow" then return false, row.why or M.MYST_FOLLOW_REASON end
    -- couch-fix39: a bookend deal stays greyed with team choices ALLOWED too (not tracked per guest)
    if row.delayed and (M.mysteryGreyDelayed() or teamAllowed()) then return false, M.MYST_DELAYED_REASON end
    if row.mode == "mixed" then return false, row.why or M.MYST_MIXED_REASON end
    if row.mode == "run" then return false, "P1'S RUN ONLY" end
    if (p.credits or 0) < (row.cost or 0) then return false, "NOT ENOUGH CREDITS" end
    return true, nil
end

-- weighted pick of an outcome (WeightedChance; all zero = equal)
local function rollOutcome(outs, rnd)
    if #outs == 0 then return nil end
    local total = 0
    for _, d in ipairs(outs) do total = total + d.w end
    rnd = rnd or math.random
    if total <= 0 then return outs[rnd(#outs)] end
    local x = rnd() * total
    for _, d in ipairs(outs) do
        x = x - d.w
        if x <= 0 then return d end
    end
    return outs[#outs]
end

-- the guest takes a mystery row: the rolled outcome applied to his run. -> ok, toast, applied (the outcome data)
function M.mysteryChoose(ctrlId, row, rnd)
    loadState()
    local p = M.player(ctrlId)
    local ok, why = M.mysteryValid(ctrlId, row)
    if not ok then return false, why end
    local d = rollOutcome(row.outs or {}, rnd)
    local notes = {}
    if d then
        if d.credits ~= 0 then
            p.credits = math.max(0, (p.credits or 0) + d.credits)
            notes[#notes + 1] = string.format("%+d CR", d.credits)
        end
        for _, u in ipairs(d.ups) do
            local cur = tonumber(p.lo.tune[u.slot]) or 0
            if u.lv > 0 or cur >= u.min then
                p.lo.tune[u.slot] = math.max(0, math.min(LEVEL_MAX, cur + u.lv))
                local st = PD and PD.STATS and PD.STATS[u.slot]
                notes[#notes + 1] = string.format("%+d %s", u.lv, st and st.name or ("STAT " .. u.slot))
            end
        end
        local taken = {}
        for i = 1, d.pools do
            local pn = d.poolNames and d.poolNames[i]
            local got = nil
            if pn and strictMyst() then
                -- couch-fix32: the pool's own rarity / fault (MYST_049: Rare + a Faulty drawback)
                got = poolPart(p, pn, rnd or math.random, taken)
            elseif not strictMyst() then
                got = catalogKind(p, "part", 1)[1]
            end
            if got then
                taken[got.id] = true
                claimLive(ctrlId, got)
                local note = "+ " .. tostring(got.name or got.id)
                if got.fault then
                    p.faults = type(p.faults) == "table" and p.faults or {}
                    p.faults[got.id] = got.fault
                    if type(p.fixed) == "table" then p.fixed[got.id] = nil end
                    note = note .. " (FAULTY)"
                end
                notes[#notes + 1] = note
                U.log(TAG, "P%s mystery part %s from %s (%s)%s", tostring(p.pnum), tostring(got.id), tostring(pn),
                    tostring(got.group), got.fault and (", faulty: " .. tostring(got.fault)) or "")
            end
        end
        local function lose(list, n, what)
            local have = {}
            for k, v in pairs(list or {}) do if v then have[#have + 1] = k end end
            for _ = 1, n do
                if #have == 0 then break end
                local k = table.remove(have, math.random(#have))
                list[k] = false
                notes[#notes + 1] = "- " .. what
            end
        end
        if d.loseParts > 0 then lose(p.lo.parts, d.loseParts, "PART") end
        if d.loseAb > 0 then lose(p.lo.ab, d.loseAb, "ABILITY") end
        -- HIS economy deals (the MYST favours P1 would get on his run)
        local m = mods(p)
        for _, n in ipairs(d.favs or {}) do
            local f = MYST_FAV[n] or {}
            if f.mult then m.mult = m.mult * f.mult end
            if f.top3 then m.top3 = m.top3 + f.top3 end
            if f.win then m.win = m.win + f.win end
            if f.fewer then m.fewer = m.fewer + f.fewer end
            if f.shop then m.shop = m.shop * f.shop end
            if f.better then m.better = true end
            if f.rager then                                 -- couch-fix46: his Biddy Blas bet (a new level replaces his old)
                m.rager = { lvl = f.rager.lvl, ahead = f.rager.ahead, behind = f.rager.behind, fav = n }
            end
            if f.repair then
                local n2 = 0
                for _, rr in ipairs(M.repairRows(ctrlId)) do
                    if n2 >= f.repair then break end
                    if M.repair(ctrlId, rr.id, 0) then n2 = n2 + 1 end      -- (a repaired one says no)
                end
                U.log(TAG, "P%s mystery repair: %d faulty part(s) repaired", tostring(p.pnum), n2)
            end
            if f.stats then
                local up = f.stats > 0
                local pool = {}
                for s = 0, 5 do
                    local cur = tonumber(p.lo.tune[s]) or 0
                    if (up and cur < LEVEL_MAX) or (not up and cur > 0) then pool[#pool + 1] = s end
                end
                for _ = 1, math.abs(f.stats) do
                    if #pool == 0 then break end
                    local s = table.remove(pool, math.random(#pool))
                    p.lo.tune[s] = math.max(0, math.min(LEVEL_MAX, (tonumber(p.lo.tune[s]) or 0) + (up and 1 or -1)))
                end
            end
            if f.txt then notes[#notes + 1] = f.txt end
        end
        -- couch-fix48: a non-hidden favour = its unlock, for him (P1's native pick unlocks it, adds nothing to the run)
        for _, n in ipairs(d.unlocks or {}) do
            local u = UNLOCK_FAV[n]
            local how = "?"
            U.try(TAG, function()
                local okB, B = pcall(U.mod, "couchbacker")
                if okB and type(B) == "table" and type(B.shareUnlock) == "function" then
                    how = B.shareUnlock({ tag = u.tag, favour = n, favourName = u.name }, p)
                else
                    M.shareUnlock(u.tag, n, p.seat, nil)
                    how = "store only"
                end
            end)
            notes[#notes + 1] = u.name .. " UNLOCKED"
            U.log(TAG, "P%s mystery unlock %s (%s): %s - no run favour (non-hidden: P1's pick adds none either)",
                tostring(p.pnum), u.tag, n, tostring(how))
        end
        -- couch-fix39: his TEAM effects onto the shared run (counted once per encounter, see mystTeam*)
        local nTeam = 0
        if d.team and #d.team > 0 and teamAllowed() then
            for _, e in ipairs(d.team) do
                nTeam = nTeam + 1
                local applied, why = M.mystTeamPick(row.inter, p.pnum, e)
                notes[#notes + 1] = (applied == false) and (M.teamEffectText(e) .. " (ALREADY TAKEN)")
                    or M.teamEffectText(e)
                if why then U.log(TAG, "P%s mystery team effect %s: %s", tostring(p.pnum), e.k, why) end
            end
        end
        if d.runOnly > nTeam then notes[#notes + 1] = "(run effects: P1's run)" end
    end
    save()
    local toast = (#notes > 0) and table.concat(notes, "  ") or "NO DEAL"
    U.log(TAG, "P%s mystery choice %d (%s): %s", tostring(p.pnum), row.i or 0, tostring(row.name), toast)
    return true, toast, d
end

---------------------------------------------------------------------------------------------------- team mystery
-- couch-fix39 (audit Q10): CouchMysteryTeam = "allowed" - a guest's mystery choice with a TEAM effect is his, and its
-- team half goes onto the ONE shared run (P1's CampaignRun) through the game's own run state:
--   * a League token: CampaignRun:RequestStrikesBalanceChange(-n, Reason) (the mutation path couchfavours' team tokens
--     and Rager's StrikesBalancePassiveEffect use; a negative n costs the team a token);
--   * a TEAM_FAV favour: its RacerFavour (loaded by mystdata FAVPATH, never read from the outcome's soft list: FINDING
--     #111) appended to CampaignRun.favours - the run's own favour list that P1's mystery favours land in, saved with
--     the run (UE4SS grows a TArray written one past its end: perkapply's AppliedAffixes, live 2026-10-15).
-- NO STACKING: one ENCOUNTER (one interaction on the paddock screen) applies a team effect once. P1's native pick
-- applies his outcome's effects itself (ChooseMysteryInteractionOutcome); a guest's effect that P1's chosen outcome
-- (PaddockGameState.MysteryInteractionOutcome) also carries is not applied again, nor one another guest already took.
-- As long as P1 has not chosen, a guest's team effects WAIT (P1's native pick would add a second copy); they are
-- applied when P1's outcome shows (mystTeamTick) or when the encounter ends (mystTeamEnd: the screen closed).
-- Per guest (his credits, stats, parts, MYST economy favours) mysteryChoose applies his own half as before.
local ENC = nil              -- { inter = name, p1 = nil | {[k] = true}, taken = {[k] = "P1" | "P2" ...}, wait = { {e, who} } }
local pendSave = false       -- couch-fix48: a team favour added since the last run save (teamSave)
M.MYST_TEAM_ONCE = "counted once"

function M.teamEffectText(e)
    if type(e) ~= "table" then return "?" end
    if e.tokens then
        local n = tonumber(e.tokens) or 0
        return string.format("TEAM: %+d LEAGUE TOKEN%s", n, math.abs(n) == 1 and "" or "S")
    end
    local t = e.fav and TEAM_FAV[e.fav]
    return t and t.txt or ("TEAM: " .. tostring(e.fav))
end

local function teamRun()
    local f = F()
    if f and type(f._campaignRun) == "function" then
        local ok, r = pcall(f._campaignRun)
        if ok and U.ok(r) then return r end
    end
    return nil
end

-- apply one team effect to the shared run -> ok, detail
local function applyTeam(e, who)
    local r = teamRun()
    if not r then return false, "no active CampaignRun" end
    local why = tostring(who) .. "'s mystery deal"
    if e.tokens then
        local s0, s1 = nil, nil
        pcall(function() s0 = tonumber(r.Strikes) end)
        local ok, err = pcall(function() r:RequestStrikesBalanceChange(-(tonumber(e.tokens) or 0), U.ftext(why)) end)
        pcall(function() s1 = tonumber(r.Strikes) end)
        return ok, string.format("RequestStrikesBalanceChange(%d) %s - strikes %s -> %s", -(tonumber(e.tokens) or 0),
            ok and "done" or ("FAILED: " .. tostring(err)), tostring(s0), tostring(s1))
    end
    local path = type(MD.FAVPATH) == "table" and MD.FAVPATH[e.fav] or nil
    local obj = path and U.obj(path) or nil
    if not U.ok(obj) then return false, "favour " .. tostring(e.fav) .. " not loaded (" .. tostring(path) .. ")" end
    -- couch-fix48: P1's pick adds only a HIDDEN favour to the run (0x1430cc701: RacerFavour.bIsHidden == 1)
    local hidden = nil
    pcall(function() hidden = obj.bIsHidden end)
    if hidden == false then return false, tostring(e.fav) .. " is not hidden: P1's pick adds no such favour to the run" end
    local n0, n1 = nil, nil
    pcall(function() n0 = U.arrayCount(r.favours) end)
    if not n0 then return false, "CampaignRun.favours not readable" end
    local ok, err = pcall(function() r.favours[n0 + 1] = obj end)
    pcall(function() n1 = U.arrayCount(r.favours) end)
    ok = ok and n1 == n0 + 1
    local info = string.format("%s added to CampaignRun.favours %s (%s -> %s)", tostring(e.fav),
        ok and "done" or ("FAILED: " .. tostring(err or "no growth")), tostring(n0), tostring(n1))
    if ok then
        info = info .. "; " .. M._favourNative(r, obj)
        pendSave = true
        local f = F()
        if f and type(f.p1Dirty) == "function" then f.p1Dirty() end   -- couchfavours' 2 s cache of P1's favours
    end
    return ok, info
end

-- couch-fix48 (live round 2 AUTO-124: P2's MYST_105 favour was in run.favours and Hibi's prices did not move, on both
-- halves, on the next planet too). A favour in CampaignRun.favours is only the run's LIST. P1's own pick goes through
-- CampaignRun::ChooseMysteryInteractionOutcome (exec 0x1471e84de -> 0x1430cc470), which calls, per ResultFavours
-- element whose RacerFavour.bIsHidden (+0x109) is set, CampaignRun::AddFavour (0x1430d1856):
--   1. favours.Add(favour)                                       (run +0xf0)
--   2. playerRacer.Player valid -> 0x142f8a89e: PassiveManagerComponent::AddPassive(favour, 0) on P1's GfnPlayerState
--      (+0x380), playerRacer.Build.AppliedPassives.Add (run +0x1d8 +0x18 +0x20) and the PlayerState's
--      RacerBuildState.AppliedPassives.Add (+0x398 +0x20) - the build state a level load re-applies from
--   3. a GameInstance subsystem notification (a tracker map keyed by the favour: achievements / telemetry)
-- GfnPlayerState:Server_ApplyPassive's native body (0x1470d5518) IS step 2's AddPassive(config, 0) (a server RPC that
-- runs locally on the standalone host: perkapply's traits use it). The passive's rule applies the favour's TuneSets
-- (TNS_MYST_MechanicShopLowAffixPricesHighPackPrices: CampaignShopTuneConfig Sales +50 / pack discounts -100).
-- -> the log text of what was done
function M._favourNative(r, obj)
    local ps = nil
    pcall(function() ps = r.playerRacer.Player end)
    if not U.ok(ps) then return "P1's passive NOT applied (run.playerRacer.Player not readable)" end
    local okP = pcall(function() ps:Server_ApplyPassive(obj) end)
    local function append(get, what)
        local arr = nil
        pcall(function() arr = get() end)
        if arr == nil then return what .. " not readable" end
        local n0 = U.arrayCount(arr)
        local okA = pcall(function() arr[n0 + 1] = obj end)
        local n1 = U.arrayCount(arr)
        return string.format("%s %s -> %s%s", what, tostring(n0), tostring(n1), (okA and n1 == n0 + 1) and "" or " FAILED")
    end
    local a = append(function() return r.playerRacer.Build.AppliedPassives end, "playerRacer.Build.AppliedPassives")
    local b = append(function() return ps.RacerBuildState.AppliedPassives end, "RacerBuildState.AppliedPassives")
    return string.format("P1's passive (Server_ApplyPassive = AddPassive(favour, 0)) %s, %s, %s",
        okP and "applied" or "FAILED", a, b)
end

-- couch-fix48 (AUTO-124: the add came 23 ms after checkpoint #335's save, P1's pick: in the save only at the next
-- checkpoint). The run's save function (0x1430d293e) has no UFunction of its own; CampaignRun:OnLeaveShop's native body
-- (0x1430ce818) is that save + a telemetry event (shop type), nothing else - the game's own save after Hibi's shop.
-- A League token needs none: RequestStrikesBalanceChange (0x1430dd8de) saves the run itself. cfg.CouchMysteryTeamSave
-- = false: no save (the next checkpoint carries it).
local SHOP_TYPE_SHOP = 0                 -- ECampaignShopType::Shop
local function teamSave(why)
    if not pendSave then return end
    pendSave = false
    if opt("CouchMysteryTeamSave", true) == false then return end
    local r = teamRun()
    if not r then
        U.warn(TAG, "TEAM mystery effect: no active CampaignRun to save (%s)", tostring(why))
        return
    end
    local ok, err = pcall(function() r:OnLeaveShop(SHOP_TYPE_SHOP) end)
    if ok then
        U.log(TAG, "TEAM mystery effect: the run saved now (CampaignRun:OnLeaveShop = the run's native save, %s)",
            tostring(why))
    else
        U.warn(TAG, "TEAM mystery effect: the run save FAILED (%s): %s - the next checkpoint carries it", tostring(why),
            tostring(err))
    end
end
M._teamSave = teamSave

local function teamApply(e, who)
    local ok, info = applyTeam(e, who)
    if ok then
        U.log(TAG, "TEAM mystery effect of %s: %s", tostring(who), info)
    else
        U.warn(TAG, "TEAM mystery effect of %s not applied: %s", tostring(who), info)
    end
    return ok
end

-- P1's chosen outcome of that interaction (PaddockGameState, hard object properties) -> {[k] = true} | nil (not yet)
local function p1TeamKeys(iname)
    local gs = U.gs()
    if not U.isA(gs, "/Script/Griffin.PaddockGameState") then return nil end
    local inter, ch, out = nil, nil, nil
    pcall(function() inter = gs.ActiveMysteryInteraction end)
    pcall(function() ch = gs.ChosenMysteryInteractionChoice end)
    pcall(function() out = gs.MysteryInteractionOutcome end)
    if not (U.ok(inter) and U.ok(out)) or U.objName(inter) ~= iname then return nil end
    local keys = {}
    local d = outcomeData(out, U.ok(ch) and outcomeKey(inter, ch, out) or nil)
    for _, e in ipairs(d.team or {}) do keys[e.k] = true end
    return keys
end
M._p1TeamKeys = p1TeamKeys
-- couch-fix54 (AUTO-132): P1 has made his pick of that interaction (the paddock's chosen outcome is set)
function M.mystP1Picked(iname)
    return iname ~= nil and iname ~= "" and p1TeamKeys(iname) ~= nil
end

local function encounter(iname)
    iname = tostring(iname or "?")
    if not ENC or ENC.inter ~= iname then
        if ENC then M.mystTeamEnd("another interaction") end
        ENC = { inter = iname, p1 = nil, taken = {}, wait = {} }
    end
    return ENC
end

-- P1's outcome known: his team effects are taken (native), the waiting ones of the guests applied (minus his)
local function p1Known(E, keys)
    E.p1 = keys
    for k in pairs(keys) do
        if not E.taken[k] or E.taken[k] ~= "P1" then
            if E.taken[k] then
                U.log(TAG, "mystery %s: team effect %s of %s is also P1's pick - %s (P1's native one)", E.inter, k,
                    tostring(E.taken[k]), M.MYST_TEAM_ONCE)
            end
            E.taken[k] = "P1"
        end
    end
    local wait = E.wait
    E.wait = {}
    for _, w in ipairs(wait) do
        if not keys[w.e.k] then teamApply(w.e, w.who) end
    end
    teamSave("after P1's outcome")
end

-- a guest took a team effect -> applied (true) | already taken this encounter (false) | waiting for P1 (nil), why
function M.mystTeamPick(iname, pnum, e)
    local E = encounter(iname)
    local who = "P" .. tostring(pnum or "?")
    if E.taken[e.k] then
        local why = string.format("already %s's in this encounter - %s", tostring(E.taken[e.k]), M.MYST_TEAM_ONCE)
        return false, why
    end
    if not E.p1 then
        local keys = p1TeamKeys(E.inter)
        if keys then p1Known(E, keys) end
        if E.taken[e.k] then
            return false, string.format("already P1's in this encounter - %s", M.MYST_TEAM_ONCE)
        end
    end
    E.taken[e.k] = who
    if E.p1 then
        teamApply(e, who)
        teamSave(who .. "'s pick")
        return true, nil
    end
    E.wait[#E.wait + 1] = { e = e, who = who }
    return nil, "waits for P1's pick (his native outcome may carry the same)"
end

-- couchpanel's mystery tick while the guests' halves are open: P1's pick seen -> the waiting effects go out
function M.mystTeamTick()
    local E = ENC
    if not E or E.p1 or #E.wait == 0 then return end
    local keys = p1TeamKeys(E.inter)
    if keys then p1Known(E, keys) end
end

-- the encounter is over (the screen closed): P1's pick read one last time, every waiting effect applied
function M.mystTeamEnd(why)
    local E = ENC
    if not E then return end
    ENC = nil
    if not E.p1 and #E.wait > 0 then
        local keys = p1TeamKeys(E.inter)
        if keys then
            p1Known(E, keys)
        else
            U.log(TAG, "mystery %s ended (%s) without P1's outcome: %d waiting team effect(s) applied", E.inter,
                tostring(why), #E.wait)
            for _, w in ipairs(E.wait) do teamApply(w.e, w.who) end
            teamSave("the encounter's end")
        end
    end
end
function M._mystEncounter() return ENC end

---------------------------------------------------------------------------------------------------- shop
-- ECONOMY: native shop prices (ECO_Campaign, rundata.prices). A guest "stat" row = the native vehicle UPGRADE
-- (Upgrades.LevelN 1000); a guest "part" = the native Affix (the shop's part cards): its rarity price
-- Common/Rare/Epic/Legendary 2000/2500/3000/4000 by the perk grade (pips 1..3; it was 1000 = 2x too cheap: P2's
-- VOLATILE BATTERY 1000 vs P1's REPULSORMOD I 2000 in the qualifier shop); abilities Abilities.Level1..3; a trait =
-- Affixes.Common. x his shop factor (Favour_MYST_IncreasedShopPrices).
local function basePrice(item)
    local pr = D and D.prices or {}
    local k = item.rkind
    if k == "stat" or k == "upgrade" then return tonumber(pr.upgrade) or 1000 end
    if k == "ab" then
        local t = type(pr.ability) == "table" and pr.ability or { 1000, 2000, 4000 }
        return tonumber(t[math.max(1, math.min(#t, tonumber(item.lvl) or 1))]) or 1000
    end
    if k == "part" then
        local t = type(pr.affix) == "table" and pr.affix or { 2000, 2500, 3000, 4000 }
        return tonumber(t[math.max(1, math.min(#t, tonumber(item.pips) or 1))]) or 2000
    end
    if k == "trait" then return tonumber(pr.trait) or 2000 end
    if k == "crash" then return tonumber(pr.crash) or 2000 end
    return 1000
end
local function price(item, p)
    local f = p and mods(p).shop or 1
    return math.floor(basePrice(item) * f + 0.5)
end
M.price = price

-- couch-fix48 (AUTO-124): HIBI'S TUNE. The native shop prices go through CampaignShopTuneConfig percents a favour's
-- TuneSet moves: price x (100 - SalesPriceModifierPercentage) / 100 for a part, x (100 - Part/AbilityPackPrice-
-- DiscountPercentage) / 100 for a pack, x (100 - RerollPriceDiscountPercentage) / 100 for RESTOCK (the reading
-- MYST_FAV's Favour_MYST_IncreasedShopPrices = -50 on all three = x1.5 already uses). The TEAM's Hibi's favours (a MYST_105
-- deal: P1's native pick or a guest's team pick, both in CampaignRun.favours) act on every player's Hibi's; a guest's
-- own IncreasedShopPrices (mods.shop) adds its -50 to the same percents, like a second TuneSet on the same config.
-- (decoded TNS_MYST_MechanicShopLowAffixPricesHighPackPrices / ...LowPackPricesHighAffixPrices, CL381121)
local HIBI_TUNE = {
    Favour_MYST_MechanicNewSupplier = { sales = 50, pack = -100 },
    Favour_MYST_MechanicNewSupplier_Alt = { sales = -100, pack = 50, reroll = 60 },
}
M.HIBI_TUNE = HIBI_TUNE
-- his Hibi's percent of one kind ("sales" | "pack" | "reroll") -> number
local function hibiPct(p, cat)
    local pct = 0
    if cat ~= "reroll" and p then pct = (1 - (tonumber(mods(p).shop) or 1)) * 100 end
    local f = F()
    if f and type(f.p1Has) == "function" then
        for name, t in pairs(HIBI_TUNE) do
            local ok, has = pcall(f.p1Has, name)
            if ok and has == true then pct = pct + (t[cat] or 0) end
        end
    end
    return pct
end
local function hibiFactor(p, cat) return math.max(0, (100 - hibiPct(p, cat)) / 100) end
M.hibiFactor = hibiFactor
-- a shelf part's price at Hibi's for him now (his Smuggler's Hope discount, it.smug, kept)
local function hibiPartPrice(it, p)
    local v = math.floor(basePrice(it) * hibiFactor(p, "sales") + 0.5)
    if it.smug then v = math.max(0, math.floor(v * (1 - it.smug) + 0.5)) end
    return v
end

-- Smuggler's Hope (InnerHonour): 1 part of a stock at 50 / 75 / 99% off
local function smugglersHope(p, rows)
    local ih = favRank(p, "InnerHonour")
    if ih <= 0 then return end
    for _, it in ipairs(rows) do
        if it.rkind == "part" then
            it.fullPrice = it.price
            it.smug = GUEST_FAV.InnerHonour[ih]
            it.price = math.max(0, math.floor(it.price * (1 - GUEST_FAV.InnerHonour[ih]) + 0.5))
            U.log(TAG, "P%s Smuggler's Hope %d: %s %d -> %d CR", tostring(p.pnum), ih, tostring(it.name or it.id),
                it.fullPrice, it.price)
            return
        end
    end
end

-- HIBI'S SHOP (couch-shopstock, Jules 2026-10-17 live: "P2's shop must offer the SAME KIND of stock as P1's"). P2's shop
-- showed 3 abilities + 1 stat card, no PACKS and no RESTOCK, while P1's native shop had 4 PARTS, the PACKS column and
-- RESTOCK: makeShop rolled catalogKind(p, nil, 3) (run.lua's mixed offer: abilities came first) and the paddock shop
-- path never added the controls. The native shop (DA_C_ShopTuneConfig, research 02 "Shop & items"; 06c 3.1):
--   * the shelf = 4 AFFIXES (the UI's "PARTS", bought singly, rarity price): his stock = 4 parts of HIS class / style
--     (catalogKind "part": the perks catalog of his arch), cfg.CouchShopParts;
--   * PACKS: UPGRADE PACK (PurchasePartPack, ShopVM.UpgradeParts: pick one of 3 stats, +1 / +2 / +3 levels at weights
--     12 / 2 / 1) 1,500 +1,000 per pack bought on this planet; ABILITY PACK (PurchaseAbilityPack: a new ability or the
--     next pip of one he has) 2,500 +1,000; prices rundata.prices.partPack / abilityPack x his shop factor;
--   * RESTOCK (RerollShopItems) 250 +250 per restock on this planet.
-- A pack is paid at once and its choice is HIS run state (p.pack, saved with the purchase: a quit / crash with the
-- choice open shows it again the next time his shop opens; the checkpoint journal holds it the same way).
local SHOP_PARTS = 4
local PACK_CHOICES = 3
local UPGRADE_WEIGHTS = { 12, 2, 1 }                      -- +1 / +2 / +3 levels (Upgrade Pack, research build guide)
M.PACKS = {
    upgrade = { name = "UPGRADE PACK", data = "partPack", base = 1500, step = 1000 },
    ability = { name = "ABILITY PACK", data = "abilityPack", base = 2500, step = 1000 },
}
M.PACK_ORDER = { "upgrade", "ability" }                  -- the native PACKS column, top to bottom

-- couch-fix32 (audit 12 issue 14): HIS shelf rolls the SHOP's rarity table (rundata rarity.shop, DA_C_ShopTuneConfig:
-- the race-reward ramp one planet behind) for the planet, never the race / eliminator reward table run.lua's offer uses
-- (catalogKind: after an eliminator the shelf drew from the eliminator's, one planet AHEAD - shelves richer than P1's).
-- Rarity first (Common / Rare / Epic / Legendary weights), then one of HIS class's parts of it (the part picker's
-- catalog, not owned / equipped; no part of that rarity = the nearest rarity he has). A part's price is its rarity's
-- (Affixes 2,000 / 2,500 / 3,000 / 4,000). cfg.CouchShopRarityTable = false: the 0.16 catalogKind shelf.
local planetNow
local function shopShelf(p, n)
    local planet = math.max(1, math.min(5, planetNow()))
    local tbl = D and D.rarity and D.rarity.shop
    local w = type(tbl) == "table" and (tbl[math.min(planet, #tbl)] or tbl[#tbl]) or { 60, 15, 0, 0 }
    local owned = type(p.owned) == "table" and type(p.owned.part) == "table" and p.owned.part or {}
    local mine = {}
    for _, id in ipairs(p.lo and p.lo.parts or {}) do if id then mine[id] = true end end
    local byRar, seen = { [0] = {}, {}, {}, {} }, {}
    pcall(function()
        local Km = K()
        local arch = p.arch or G.arch
        local pk = Km.picker(p.lo, "part1", arch)
        for ci = 1, #((pk and pk.cats) or {}) do
            for _, it in ipairs(Km.pickerCat(p.lo, "part1", arch, ci) or {}) do
                local d = it.id and PD and PD.PARTS and PD.PARTS[it.id]
                local r = d and tonumber(d.rarity)
                if d and r and r >= 0 and r <= 3 and not it.empty and not it.inert and not it.faulty and not d.faulty
                    and not d.planeOnly and not seen[it.id] and not mine[it.id] and not owned[it.id] then
                    seen[it.id] = true
                    local row = {}
                    for k, v in pairs(it) do row[k] = v end
                    row.slot, row.rkind, row.equipped, row.usedBy = "part1", "part", nil, nil
                    row.pips = r + 1
                    byRar[r][#byRar[r] + 1] = row
                end
            end
        end
    end)
    for r = 0, 3 do table.sort(byRar[r], function(a, b) return a.id < b.id end) end
    local out, rolled = {}, {}
    for _ = 1, n do
        local total = 0
        for i = 1, 4 do total = total + (tonumber(w[i]) or 0) end
        local r = 0
        if total > 0 then
            local x = math.random() * total
            for i = 1, 4 do
                x = x - (tonumber(w[i]) or 0)
                if x <= 0 then r = i - 1; break end
            end
        end
        local got = nil
        for _, rr in ipairs({ r, r - 1, r - 2, r - 3, r + 1, r + 2, r + 3 }) do
            local b = byRar[rr]
            if b and #b > 0 then got = table.remove(b, math.random(#b)); break end
        end
        if not got then break end
        out[#out + 1] = got
        rolled[#rolled + 1] = string.format("%s(%d)", tostring(got.id), got.pips - 1)
    end
    U.log(TAG, "P%s's Hibi's shelf: planet %d shop rarity {%s}: %s", tostring(p.pnum), planet,
        table.concat({ tostring(w[1]), tostring(w[2]), tostring(w[3]), tostring(w[4]) }, ","), table.concat(rolled, ", "))
    return out
end
M._shopShelf = shopShelf

function M.rollStock(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    if not p then return nil end
    local n = math.max(1, math.floor(tonumber(opt("CouchShopParts", SHOP_PARTS)) or SHOP_PARTS))
    if F() then n = F().shopParts(p, n) end              -- #110 Gadgeteer III: +2 parts at Hibi's
    local rows = {}
    local shelf = (opt("CouchShopRarityTable", true) ~= false) and shopShelf(p, n) or catalogKind(p, "part", n)
    for _, it in ipairs(shelf) do it.price = hibiPartPrice(it, p); rows[#rows + 1] = it end
    smugglersHope(p, rows)
    rows[#rows + 1] = { rkind = "leave", id = "leave", name = "LEAVE THE SHOP", sub = "" }
    p.shop = rows
    save()
    return rows
end

-- native shop reroll: Shop.Reroll 250 + Shop.RerollIncrease 250 per reroll (cfg.CouchShopRestock overrides the base)
function M.restockPrice(p)
    local rr = D and D.prices and D.prices.reroll or {}
    local base = tonumber(opt("CouchShopRestock", nil)) or tonumber(rr.base) or 250
    local step = tonumber(rr.step) or base
    return math.floor((base + step * (tonumber(p and p.restocks) or 0)) * hibiFactor(p, "reroll") + 0.5)
end

-- a pack's price for him now: the native base + step per pack of that kind bought on this planet, x his shop factor
function M.packPrice(p, which)
    local def = M.PACKS[which]
    if not def then return nil end
    local pr = D and D.prices and D.prices[def.data] or {}
    local base, step = tonumber(pr.base) or def.base, tonumber(pr.step) or def.step
    local n = tonumber(p and type(p.packs) == "table" and p.packs[which]) or 0
    return math.floor((base + step * n) * hibiFactor(p, "pack") + 0.5)
end

-- -> rows: stock..., LEAVE, RESTOCK, UPGRADE PACK, ABILITY PACK (couchpanel: shelf cards, his LEAVE / RESTOCK buttons,
-- the PACKS column)
local function withControls(p)
    local out = {}
    for _, r in ipairs(p.shop or {}) do                  -- (a stock saved before fix16 may hold a SKIP card)
        if r.rkind ~= "leave" and r.rkind ~= "restock" and r.rkind ~= "skip" and r.rkind ~= "pack" then
            -- couch-fix48: a part's price follows Hibi's tune NOW (a team favour that came after the roll); a stock
            -- saved before fix48 with a Smuggler's Hope part (no it.smug) keeps its price
            if r.rkind == "part" and not r.packPick and (r.smug or not r.fullPrice) then r.price = hibiPartPrice(r, p) end
            out[#out + 1] = r
        end
    end
    out[#out + 1] = { rkind = "leave", id = "leave", name = "LEAVE THE SHOP", sub = "" }
    out[#out + 1] = { rkind = "restock", id = "restock", name = "RESTOCK", price = M.restockPrice(p) }
    for _, k in ipairs(M.PACK_ORDER) do
        out[#out + 1] = { rkind = "pack", id = k, name = M.PACKS[k].name, price = M.packPrice(p, k) }
    end
    return out
end

-- NOTE 11 (Jules 2026-10-14: "I feel P2 is never getting the option to spend their money"): HIS OWN SHOP, opened by
-- him from the run map (couchpanel "pshop") or beside P1's native shop: ONE stock per planet (a vendor visit: rollStock)
-- kept with his purchases until the next planet; RESTOCK rerolls it, the restock and pack prices climb per planet.
-- couch-fix48 (AUTO-125, live round 2 13:45: Jakku's Hibi's showed P2's Sentinel I shelf): the planet of the shop =
-- the run's planet VISIT, #CampaignRun.VisitedPlanets (TravelToNextPlanet appends one entry; GetCurrentPlanet() =
-- VisitedPlanets.Last()). nodeInfo's node scan lags on a new planet: before a node of it is chosen its "current
-- node" is the last completed one, the previous planet's. Unreadable (0 entries) = nodeInfo's planet.
planetNow = function()
    local n = 0
    local r = activeRun()
    if r then pcall(function() n = U.arrayCount(r.VisitedPlanets) end) end
    if (tonumber(n) or 0) >= 1 then return math.floor(n) end
    local planet = nodeInfo()
    return planet
end
M._shopPlanet = planetNow

-- couch-fix56 (AUTO-137 note / AUTO-138 todo, live round 3 runs 42/43: "the picked node is on Jakku but the run is
-- still on Sentinel I" on every planet change): THE run-planet sources side by side, one reader for every consumer.
--   visit = #VisitedPlanets (CampaignRun:GetCurrentPlanet() = its last entry): the GAME's planet - the paddock world,
--           P1's Hibi's, the native check-in, the strike protectors' PlanetNum, the planet-exit flow. P2's own shop
--           (fix48), couchrules' strike / results bookkeeping and the gauntlet's write gate (AUTO-118) key on it: they
--           follow the game, they must not "correct" it.
--   node  = the current node's PlanetIndex + 1 (nodeInfo): the planet of the race being run - the backer contracts
--           and check-in settling (couchbacker) key on it. It trails the visit on a new planet before its first pick
--           (fix48) and is never ahead of it in a native run.
--   lag   = node > visit: the run raced on a planet it never travelled to (TravelToNextPlanet never ran: the round-3
--           harness picked the next planet's node in the old paddock before the native planet travel). The game stays
--           on the old planet; couch.lua says so once at the race start. -> {visit, node, lag, visitDef, nodeDef}
function M.runPlanet()
    local out = { lag = false }
    local r = activeRun()
    if r then
        pcall(function()
            local n = U.arrayCount(r.VisitedPlanets)
            if n >= 1 then out.visit = math.floor(n) end
        end)
        pcall(function() local d = r:GetCurrentPlanet(); if U.ok(d) then out.visitDef = d end end)
    end
    local nd = currentNode()
    if nd then
        pcall(function() local i = tonumber(nd.PlanetIndex); if i then out.node = math.floor(i) + 1 end end)
        pcall(function() local d = nd.Planet.Planet; if U.ok(d) then out.nodeDef = d end end)
    end
    out.lag = out.visit ~= nil and out.node ~= nil and out.node > out.visit
    return out
end
function M.personalShop(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    if not p then return {} end
    local planet = planetNow()
    -- a stock rolled by the old code (abilities / a stat on the shelf) or another planet's: a new one
    local stale = type(p.shop) ~= "table" or p.shopKind ~= "parts"
    if p.shopPlanet ~= planet or stale then
        M.rollStock(ctrlId)
        if p.shopPlanet ~= planet then p.restocks, p.packs = 0, {} end   -- the planet's counters (restock, packs)
        p.shopPlanet, p.shopKind = planet, "parts"
        if type(p.packs) ~= "table" then p.packs = {} end
        save()
        U.log(TAG, "P%s's own shop: new stock for planet %s", tostring(p.pnum), tostring(planet))
    end
    return withControls(p)
end

-- the pack choice he has paid for and not taken yet, or nil
function M.pendingPack(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    local pk = p and p.pack
    if type(pk) ~= "table" or type(pk.rows) ~= "table" or #pk.rows == 0 then return nil end
    return pk
end

-- RESTOCK: his credits -> a new stock. -> ok, toast, rows
function M.restock(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    if not p then return false, nil end
    if M.pendingPack(ctrlId) then return false, "CHOOSE FROM YOUR PACK FIRST" end
    local cost = M.restockPrice(p)
    if (p.credits or 0) < cost then return false, "NOT ENOUGH CREDITS" end
    p.credits = (p.credits or 0) - cost
    M.rollStock(ctrlId)
    p.shopKind = "parts"
    p.restocks = (p.restocks or 0) + 1
    save()
    U.log(TAG, "P%s restocks his shop: -%d CR (total %d)", tostring(p.pnum), cost, p.credits)
    return true, string.format("RESTOCKED  -%d CR", cost), withControls(p)
end

-- the stat rows of an UPGRADE PACK: 3 of his stats below the max, each with its rolled levels
local function rollLevels(rnd)
    local total = 0
    for _, w in ipairs(UPGRADE_WEIGHTS) do total = total + w end
    local x = (rnd or math.random)() * total
    for i, w in ipairs(UPGRADE_WEIGHTS) do
        x = x - w
        if x <= 0 then return i end
    end
    return 1
end
local function upgradeChoices(p, n)
    local pool = {}
    for s = 0, 5 do if (tonumber(p.lo.tune[s]) or 0) < LEVEL_MAX then pool[#pool + 1] = s end end
    local rows = {}
    for _ = 1, n do
        if #pool == 0 then break end
        local s = table.remove(pool, math.random(#pool))
        local r = statRow(s, p)
        local cur = math.floor(tonumber(p.lo.tune[s]) or 0)
        local lv = math.min(rollLevels(), LEVEL_MAX - cur)
        r.lv = lv
        r.name = r.name:gsub("%s*%+1$", "") .. " +" .. lv
        r.sub = string.format("LEVEL %d -> %d", cur, cur + lv)
        r.grade = lv
        rows[#rows + 1] = r
    end
    return rows
end

-- the ability rows of an ABILITY PACK: a new ability (level 1, a family he does not have) or the next pip of one he has
-- (its `from` equipped), from HIS class's ability catalog (perks picker: his arch, his car's systems)
local function abilityCands(p)
    local equipped, fams = {}, {}
    for i = 1, 4 do
        local id = p.lo.ab and p.lo.ab[i]
        if id then
            equipped[id] = true
            local a = PD and PD.ABILITIES and PD.ABILITIES[id]
            if a and a.fam then fams[a.fam] = true end
        end
    end
    local owned = type(p.owned) == "table" and type(p.owned.ab) == "table" and p.owned.ab or {}
    local cands, seen = {}, {}
    pcall(function()
        local Km = K()
        local arch = p.arch or G.arch
        local pk = Km.picker(p.lo, "ab1", arch)
        for ci = 1, #((pk and pk.cats) or {}) do
            for _, it in ipairs(Km.pickerCat(p.lo, "ab1", arch, ci) or {}) do
                local a = it.id and PD and PD.ABILITIES and PD.ABILITIES[it.id]
                if a and not it.inert and not seen[it.id] and not equipped[it.id] then
                    seen[it.id] = true
                    local lvl = tonumber(a.lvl) or 1
                    local up = a.from ~= nil and equipped[a.from] == true
                    local new = lvl == 1 and not owned[it.id] and not (a.fam and fams[a.fam])
                    if up or new then
                        cands[#cands + 1] = { rkind = "ab", id = it.id, name = a.name, lvl = lvl, icon = it.icon,
                                              desc = a.desc, up = up or nil, from = up and a.from or nil, grade = lvl }
                    end
                end
            end
        end
    end)
    return cands
end
M._abilityCands = abilityCands
local function abilityChoices(p, n)
    local cands = abilityCands(p)
    local rows = {}
    for _ = 1, n do
        if #cands == 0 then break end
        rows[#rows + 1] = table.remove(cands, math.random(#cands))
    end
    if #rows == 0 then rows = catalogKind(p, "ab", n) end     -- no picker (a broken catalog): run.lua's offer
    return rows
end

-- PACK: his credits -> a paid pack, its choice his run state (p.pack). -> ok, toast, choice rows
function M.buyPack(ctrlId, which)
    loadState()
    local p = M.player(ctrlId)
    if not p or not M.PACKS[which] then return false, nil end
    if M.pendingPack(ctrlId) then return false, "CHOOSE FROM YOUR PACK FIRST" end
    local cost = M.packPrice(p, which)
    if (p.credits or 0) < cost then return false, "NOT ENOUGH CREDITS" end
    local nc = F() and F().packChoices(p, PACK_CHOICES) or PACK_CHOICES     -- #110 Bloody Bounty III: +2 choices
    local rows = (which == "upgrade") and upgradeChoices(p, nc) or abilityChoices(p, nc)
    if #rows == 0 then return false, "NOTHING LEFT TO UPGRADE" end
    for _, r in ipairs(rows) do r.packPick = true; r.price = 0 end
    p.credits = (p.credits or 0) - cost
    p.packs = type(p.packs) == "table" and p.packs or {}
    p.packs[which] = (tonumber(p.packs[which]) or 0) + 1
    p.packSeq = (tonumber(p.packSeq) or 0) + 1
    p.pack = { kind = which, seq = p.packSeq, rows = rows }
    save()
    U.log(TAG, "P%s buys an %s: -%d CR (total %d), %d choice(s): %s", tostring(p.pnum), M.PACKS[which].name, cost,
        p.credits, #rows, (function()
            local t = {}
            for _, r in ipairs(rows) do t[#t + 1] = tostring(r.name or r.id) end
            return table.concat(t, ", ")
        end)())
    return true, string.format("%s  -%d CR: CHOOSE ONE", M.PACKS[which].name, cost), rows
end

local amendPack      -- CHECKPOINT JOURNAL (below)

-- his pick from the paid pack (one of p.pack.rows) -> ok, toast
function M.packPick(ctrlId, row)
    loadState()
    local p = M.player(ctrlId)
    local pk = M.pendingPack(ctrlId)
    if not p or not pk or type(row) ~= "table" then return false, nil end
    local found = nil
    for _, r in ipairs(pk.rows) do
        if r.rkind == row.rkind and tostring(r.id) == tostring(row.id) then found = r; break end
    end
    if not found then return false, "NOT IN YOUR PACK" end
    if row.replace then                                                   -- #95: his PART SLOTS FULL pick
        local c = {}
        for k, v in pairs(found) do c[k] = v end
        c.replace, found = row.replace, c
    end
    local okR, whyR = M.replaceValid(ctrlId, found)
    if not okR then return false, whyR end
    local offer = p.offer                                -- a pending reward offer is not his pack's business
    local toast = applyClaim(p, found)
    p.offer = offer
    p.pack = nil
    save()
    U.log(TAG, "P%s takes %s from his %s (pack #%s)", tostring(p.pnum), tostring(found.name or found.id),
        tostring(M.PACKS[pk.kind] and M.PACKS[pk.kind].name or pk.kind), tostring(pk.seq))
    U.try(TAG, amendPack, ctrlId, pk.seq, found)
    return true, tostring(toast)
end

-- -> ok, toast
function M.buy(ctrlId, item)
    loadState()
    local p = M.player(ctrlId)
    if not p or type(item) ~= "table" then return false, nil end
    if item.rkind == "pack" then
        local ok, toast = M.buyPack(ctrlId, item.id)
        return ok, toast
    end
    if M.pendingPack(ctrlId) then return false, "CHOOSE FROM YOUR PACK FIRST" end
    local okR, whyR = M.replaceValid(ctrlId, item)
    if not okR then return false, whyR end
    local cost = tonumber(item.price) or 0
    if (p.credits or 0) < cost then return false, "NOT ENOUGH CREDITS" end
    p.credits = (p.credits or 0) - cost
    local toast = claimLive(ctrlId, item)
    if item.exp and item.fault and type(p.lo) == "table" then
        -- #73: an experimental part comes with its drawback: Faulty until repaired at the scrap dealer
        p.faults = type(p.faults) == "table" and p.faults or {}
        p.faults[item.id] = item.fault
        if type(p.fixed) == "table" then p.fixed[item.id] = nil end
        U.log(TAG, "P%s bought %s at the scrap dealer: %d CR, FAULTY (%s) until repaired", tostring(p.pnum),
            tostring(item.name or item.id), cost, tostring(item.faultName or item.fault))
        toast = tostring(toast) .. " (FAULTY)"
        -- couch-fix35 (Q6): a scrap dealer purchase counts for P1's account (Preferred Customer's "Purchase N Parts")
        U.try(TAG, function()
            local MM = META()
            if MM then
                MM.count(string.format("%s:buy:%s:%s", tostring(M.visitKey() or "?"), tostring(p.seat or p.pnum),
                    tostring(item.id)), p.pnum, { stat = "dealer" })
            end
        end)
    end
    for _, list in ipairs({ p.shop or {}, p.vendorShop or {} }) do
        for i, it in ipairs(list) do
            if it == item or (it.rkind == item.rkind and tostring(it.id) == tostring(item.id)) then table.remove(list, i); break end
        end
    end
    save()
    return true, string.format("%s  -%d CR", tostring(toast), cost)
end
---------------------------------------------------------------------------------------------------- scrap dealer
-- FINDING #20 (Jules 2026-10-17 playtest, 18:12): the paddock's REPAIR PARTS vendor (WBP_ExoticVendor_C) let only P1
-- repair; each guest got a SHOP in his area. The vendor (decoded: WBP_ExoticVendor / WBP_ExoticVendorRepair_Presentation
-- / WBP_ExoticVendorShop_Presentation kismet, BlackMarketVM / AppliedAffixVM JMAP CL381121) is "Ori & Per, Scrap
-- Dealer": a landing with REPAIR PARTS and SHOP (the SHOP button shown only when
-- CampaignRun:ShouldBlackMarketHaveShopItems()). REPAIR PARTS = BlackMarketVM.FaultyItems (AppliedAffixVM: Name,
-- AffixStatus Faulty 2 / Fixed 3, IsRepairable, FaultyPassiveFlavourTexts), one RepairCost (ECO_Campaign "Affix
-- repair" 2,000, the VM's own figure when readable); a click repairs when AffixStatus == Faulty, CurrentPlayerCredits >=
-- RepairCost and IsRepairable, and the part stays listed as "Repaired". A guest's faulty parts are the parts of HIS
-- build whose affix is a fault (perkdata faulty = the config's FaultyRules: the game sets such an affix Faulty);
-- p.fixed[id] = repaired (written as EAffixStatus Fixed on his car: perkapply). Paid with his own credits; the live
-- state is saved at once and the checkpoint journal copies p.fixed with the rest of his state (a crash before P1's next
-- save rolls the repair back with P1's own).
local AFFIX_FAULTY, AFFIX_FIXED = 2, 3                 -- EAffixStatus
function M.isFaultyPart(id)
    local d = PD and PD.PARTS and PD.PARTS[id]
    return d ~= nil and d.faulty == true
end

-- the repair price for him: the game's RepairCost of this vendor (nativeCost) else rundata's affix repair (2,000)
-- #110 Preferred Customer: the vendor's figure carries P1's own AffixRepairDiscountPercentage (taken back out), his
-- own rank's discount applies (couchfavours.repairPrice)
function M.repairPrice(p, nativeCost)
    local n = tonumber(nativeCost)
    local pr = D and D.prices or {}
    local f = F()
    if f then return f.repairPrice(p, nativeCost, math.floor(tonumber(pr.repair) or 2000)) end
    if n and n > 0 then return math.floor(n + 0.5) end
    return math.floor(tonumber(pr.repair) or 2000)
end

-- the vendor's REPAIR PARTS list for him, in his build's slot order: { rkind = "repair", id, slot, name, status
-- (EAffixStatus 2 faulty / 3 fixed), repairable, fault } - only parts with a fault (the native FaultyItems), repaired
-- ones stay listed as REPAIRED.
-- FINDING #91 (playtest 2026-10-18 09:13): P2 bought 3 experimental parts at the Scrap Dealer with his 6 part slots
-- full: applyClaim keeps such a part OWNED (p.owned.part, for the garage swap) but not in p.lo.parts, and the fault
-- went on p.faults[id] - this list walked p.lo.parts only, so his REPAIR PARTS said "No Parts in need of repair" while
-- couch-run.txt held 6 faults. A faulted part he owns but has not installed is listed after his build's parts (slot
-- nil, owned = true) and repairable the same way (his credits, the vendor's price, the fault gone for when he fits it).
local function ownsPart(p, id)
    if not id then return false end
    for _, x in ipairs(p.lo and p.lo.parts or {}) do if x == id then return true end end
    return type(p.owned) == "table" and type(p.owned.part) == "table" and p.owned.part[id] == true
end
M._ownsPart = ownsPart

function M.repairRows(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    local rows = {}
    if not (p and p.lo) then return rows end
    local fixed = type(p.fixed) == "table" and p.fixed or {}
    local faults = type(p.faults) == "table" and p.faults or {}
    local seen = {}
    local function add(id, slot)
        local d = PD and PD.PARTS and PD.PARTS[id]
        rows[#rows + 1] = { rkind = "repair", id = id, slot = slot, owned = (slot == nil) or nil,
                            name = tostring(d and d.name or id), fault = faults[id] or nil,
                            status = (fixed[id] and not faults[id]) and AFFIX_FIXED or AFFIX_FAULTY, repairable = true }
        seen[id] = true
    end
    for i, id in ipairs(p.lo.parts or {}) do
        -- couch-rewards2: a part a critical malfunction faulted (p.faults) is repairable like a faulty part
        if id and not seen[id] and (M.isFaultyPart(id) or faults[id]) then add(id, i) end
    end
    -- #91: the faulted parts he owns outside his build (a dealer buy / reward with his part slots full), by id
    local extra = {}
    for id, f in pairs(faults) do
        if f and not seen[id] and ownsPart(p, id) then extra[#extra + 1] = id end
    end
    table.sort(extra)
    for _, id in ipairs(extra) do add(id, nil) end
    return rows
end

-- his repair of one part: -> ok, toast, why ("repaired" | "credits" | "notfaulty" | "nopart")
function M.repair(ctrlId, id, cost)
    loadState()
    local p = M.player(ctrlId)
    if not (p and p.lo) then return false, "NO PARTS", "nopart" end
    local faulted = type(p.faults) == "table" and p.faults[id] ~= nil
    -- #91: a faulted part he owns outside his build is repairable too (the dealer's buy with his slots full)
    local here = false
    for _, x in ipairs(p.lo.parts or {}) do if x == id then here = true end end
    if not (here or (faulted and ownsPart(p, id))) or not (M.isFaultyPart(id) or faulted) then
        return false, "NOTHING TO REPAIR", "nopart"
    end
    p.fixed = type(p.fixed) == "table" and p.fixed or {}
    if p.fixed[id] and not faulted then return false, "REPAIRED", "notfaulty" end
    cost = math.max(0, math.floor(tonumber(cost) or M.repairPrice(p)))
    if (p.credits or 0) < cost then return false, "INSUFFICIENT CREDITS", "credits" end
    p.credits = (p.credits or 0) - cost
    p.fixed[id] = true
    if faulted then p.faults[id] = nil end                 -- couch-rewards2 / #73: the fault removed from his part
    save()
    local d = PD and PD.PARTS and PD.PARTS[id]
    U.log(TAG, "P%s repaired %s at the scrap dealer: -%d CR (total %d)%s", tostring(p.pnum),
        tostring(d and d.name or id), cost, p.credits, here and "" or " (owned, not in his build)")
    return true, string.format("REPAIRED  -%d CR", cost), "repaired"
end

-- the repaired parts of his build (a copy for perkapply: EAffixStatus Fixed on his car), or nil
function M.fixedParts(ctrlId)
    local p = M.player(ctrlId)
    if not (p and type(p.fixed) == "table") then return nil end
    local out, n = {}, 0
    for id, on in pairs(p.fixed) do if on then out[id] = true; n = n + 1 end end
    return n > 0 and out or nil
end

-- does this vendor sell? (CampaignRun:ShouldBlackMarketHaveShopItems, the landing's SHOP button) -> bool or nil
function M.vendorHasShop()
    local r = activeRun()
    if not r then return nil end
    local ok, v = pcall(function() return r:ShouldBlackMarketHaveShopItems() end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

-- the vendor visit (P1's run id + nodes chosen): ONE stock per visit for him (his SHOP -> BACK -> SHOP is not a reroll)
local function vendorVisit()
    local f = nil
    pcall(function() f = M.fpOf(activeRun()) end)
    if type(f) ~= "table" then return "?" end
    return string.format("%s:%s", tostring(f.id or "-"), tostring(f.ch or "-"))
end
function M.vendorStock(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    if not p then return nil end
    local visit = vendorVisit()
    if p.vendorVisit ~= visit or type(p.vendorShop) ~= "table" or p.vendorKind ~= M.BM_KIND then
        M.makeShop(ctrlId)
        p.vendorVisit = visit
        save()
        U.log(TAG, "P%s's scrap dealer stock for visit %s: %d row(s)", tostring(p.pnum), visit, #(p.vendorShop or {}))
    end
    local out, hasLeave = {}, false
    for _, r in ipairs(p.vendorShop or {}) do
        out[#out + 1] = r
        if r.rkind == "leave" then hasLeave = true end
    end
    if not hasLeave then out[#out + 1] = { rkind = "leave", id = "leave", name = "LEAVE THE SHOP", sub = "" } end
    return out
end

---------------------------------------------------------------------------------------------------- own reward flow
-- couch-rewards2 STEP 3: each guest's OWN post-race reward flow (couchrewards.lua: the native rules ported; analysis
-- notes/research/rogue-mode/07-p2-rewards-parity.md). At the race end (onRaceEnd) his stage list is computed from HIS
-- finish, build and favours on P1's node: p.flow = { gen, seed, kind, tune, skip, credit, stages = { {type, reason,
-- rows | faults | round, collected, picked} } }, saved with his run and journaled like his payout. couchflow.lua shows
-- it with the game's own widgets (hub, CREDITS BREAKDOWN, FAULTS, CHOOSE AN UPGRADE). Credits are booked at the race
-- end as before (the CREDITS stage is display only); a pick claims through M.claim (rows carry fstage / fseed), the
-- FAULTS stage applies his queued faults (p.faultQueue -> p.faults). cfg.CouchRewardFlow = false: the old offer that
-- mirrors P1's round (makeOffer).
local function RW() local ok, m = pcall(require, "couchrewards"); return ok and type(m) == "table" and m or nil end
M.FLOW_V = 1
local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deepCopy(x) end
    return o
end
M._deepCopy = deepCopy

-- his part candidates for a part round: the part picker's catalog for his class / systems (not owned, not equipped,
-- not faulty, not inert) -> { {id, rarity, fam} }, his owned families
partPool = function(p)
    local out, fams, seen = {}, {}, {}
    local mine = {}
    for _, id in ipairs(p.lo and p.lo.parts or {}) do
        if id then
            mine[id] = true
            local d = PD and PD.PARTS and PD.PARTS[id]
            if d and d.fam then fams[d.fam] = true end
        end
    end
    local owned = type(p.owned) == "table" and type(p.owned.part) == "table" and p.owned.part or {}
    pcall(function()
        local Km = K()
        local arch = p.arch or G.arch
        local pk = Km.picker(p.lo, "part1", arch)
        for ci = 1, #((pk and pk.cats) or {}) do
            for _, it in ipairs(Km.pickerCat(p.lo, "part1", arch, ci) or {}) do
                local d = it.id and PD and PD.PARTS and PD.PARTS[it.id]
                if d and not it.empty and not it.inert and not d.faulty and not d.planeOnly and not seen[it.id]
                    and not mine[it.id] and not owned[it.id] then
                    seen[it.id] = true
                    out[#out + 1] = { id = it.id, rarity = tonumber(d.rarity) or 0, fam = d.fam }
                end
            end
        end
    end)
    table.sort(out, function(a, b) return a.id < b.id end)      -- the stream picks by index: a stable order
    return out, fams
end
M._partPool = partPool

-- THE SCRAP DEALER's stock (FINDING #73 / #32, tester #5 07:03 54-shops.png, round 3 r3-scrap-dealer.png): P2's SHOP
-- at Ori & Per was "HIBI'S SHOP" with a Hibi-like mixed stock (Vent / Shockwave / Status Scrubber / Ramjet at 1,000:
-- run.lua's catalogKind(p, nil, 3) + a stat) while P1's was the dealer's: 3 EXPERIMENTAL parts, each a top-tier affix
-- fused with a faulty drawback, "4,000" struck through, 250 CR. The game's rules (decoded):
--   * the stock: the planet's BlackMarketPool (CAM_Tour1/2/3_BlackMarket, every Act the same) = one
--     GeneratedAffixGroups entry: Primary AffixGroup.GoodExperimental (39 top-tier affixes) + Secondary
--     AffixGroup.BadExperimental (the 51 AFX_Faulty_* drawbacks), DA_CampaignRewardGroups; the item = the primary
--     affix with the drawback as its secondary, Faulty until repaired (the card's FAULT box: "cannot be replaced
--     until repaired. Faults can be repaired at the Scrap Dealer");
--   * BlackMarketTuneConfig.NumberOfItemsToPurchase: the shop screen has 3 places (WBP_Item_1..3, PopulateItems);
--   * the price: the affix's own rarity price (CreditsValueNoDiscount, Legendary 4,000) x (100 -
--     SalesPriceModifierPercentage 75)% (DA_C_BlackMarketConfig) = 1,000; P1's 250 = a second 75% off from his
--     MYST_111 deal (Favour_MYST_ExoticVendorToken_Lvl1: SalesPriceAdditionalModifierPercentage +75, a League token:
--     P1's run only, a guest gets the base sale).
-- His stock: 3 GoodExperimental parts his class / systems can use (the part picker's catalog, not owned / equipped),
-- each with a BadExperimental drawback, rolled from a SEEDED stream per visit (P1's run seed + id + nodes chosen + his
-- seat): one stock per visit (SHOP -> BACK -> SHOP), and a crash + CONTINUE into the same visit rolls the same stock
-- (the native stock is in P1's run save). Bought = his part with p.faults[id] = the drawback (perkapply: Status Faulty,
-- SecondaryAffix = the drawback), repairable at the dealer's REPAIR PARTS (couchrun.repairRows / repair).
M.BM_GOOD = {
    "AFX_Conditions_DisruptedProtection", "AFX_Conditions_CooledLastsLonger_v3", "AFX_Cooled_CorrodeProtection",
    "AFX_Ramjet_CoolsFaster_v4", "AFX_Ramjet_HeatReduction_v4", "AFX_Ramjet_MorePower_v4",
    "AFX_Ramjet_OverheatIncreasesPowerUntilCrash_v3", "AFX_Ramjet_CooledWhenCritical_v3",
    "AFX_Ramjet_OverheatingReleaseResetsHeat", "AFX_Ramjet_ResetHeatOnLanding_v2",
    "AFX_Afterburner_IncreasedTopSpeed_v4", "AFX_Cooled_GainOnLanding_v4",
    "AFX_Afterburner_FullFuelIncreasesPower_v4", "AFX_Ramjet_CriticalResetChance_v3",
    "AFX_Conditions_Cooled_IncreasedPotency_v4", "AFX_Takedown_GainCooled_v4",
    "AFX_Takedown_GainSurgeAndOvercharged_v3", "AFX_Afterburner_RefillOnImpact_v3",
    "AFX_Afterburner_RefillOnLanding_V3", "AFX_Afterburner_MorePowerPerTakedown_v4",
    "AFX_Slipstreaming_LastsUntilImpact", "AFX_Condition_Surging_IncreasedPotency_v3", "AFX_Energy_AddOnTakedown_v2",
    "AFX_Afterburner_gainShieldWhile", "AFX_Ramjet_gainShieldWhile", "AFX_Energy_GainOnTakedown_v4",
    "AFX_Crashes_CooledSurgingShieldedWhenOneCrashRemains", "AFX_Ability_FasterCooldown_v4",
    "AFX_Afterburner_MoreDuration_v4", "AFX_Cooled_PowerfulRamjet_v4", "AFX_Ignition_PerfectStartPower_v4",
    "AFX_PerfectStart_GainShield_v3", "AFX_PerfectStart_ImprovedSlipstreaming_v3", "AFX_Ramjet_ExtendedAlarm_v4",
    "AFX_Landing_IncreaseSpeedStat_v3", "AFX_Takedown_IncreaseSpeedStat_v4", "AFX_Slipstream_gainSurging_v3",
    "AFX_Afterburner_OverheatIncreasesPowerUntilCrash_v3", "AFX_Afterburner_CooledSavesFuel_v4"
}
M.BM_BAD = {
    "AFX_Faulty_Ability_LongerCooldown_v1", "AFX_Faulty_Ability_OneLessTotalEnergy", "AFX_Faulty_BlockOvercharged",
    "AFX_Faulty_BlockSurge", "AFX_Faulty_Burning_AbilityTriggersBurning", "AFX_Faulty_Burning_GainBurningOnImpact",
    "AFX_Faulty_Burning_GainChoked", "AFX_Faulty_Burning_GainWhileSpeeding",
    "AFX_Faulty_Conditions_CorrodeVulnerability", "AFX_Faulty_Conditions_ExplosiveBurning",
    "AFX_Faulty_FreezeVulnerability_v2", "AFX_Faulty_GainDisrupted", "AFX_Faulty_GainSysMalf",
    "AFX_Faulty_NoSlipstreaming", "AFX_Faulty_Ramjet_HeatIncrease_v2", "AFX_Faulty_Ramjet_LessPower_v2",
    "AFX_Faulty_Ramjet_ReducedAlarm", "AFX_Faulty_StartWithWeakAfterburner", "AFX_Faulty_StuckSteering",
    "AFX_Faulty_SysMalf_EmptyAfterburner", "AFX_Faulty_SysMalf_TripleDuration", "AFX_Faulty_PerfectStartDifficulty",
    "AFX_Faulty_Afterburner_SlowerRecharge", "AFX_Faulty_DisruptedDecaysAfterburner",
    "AFX_Faulty_SysMalf_GainFrozen", "AFX_Faulty_Overheating_AppliesBurn", "AFX_Faulty_Burning_NoDecay",
    "AFX_Faulty_Overcharged_GainBurning", "AFX_Faulty_Afterburner_GainBurning",
    "AFX_Faulty_Slipstreaming_GainHeated", "AFX_Faulty_Ability_GainCorroded",
    "AFX_Faulty_Condition_FrozenWhenAirborne", "AFX_Faulty_Afterburner_DecayWhileAirborne",
    "AFX_Faulty_SysMalf_BecomeCorroded", "AFX_Faulty_Slipstreaming_BecomeFrozen", "AFX_Faulty_Crash_ReturnDisrupted",
    "AFX_Faulty_Concussed_OnImpact", "AFX_Faulty_Overheating_AppliesCorrode", "AFX_Faulty_Overheating_AppliesFrozen",
    "AFX_Faulty_CritMalf_HardCheck", "AFX_Faulty_CritMalf_MoreLikely", "AFX_Faulty_Afterburner_onEmptyBecomeBurning",
    "AFX_Faulty_Frozen_LastsLonger", "AFX_Faulty_Frozen_IncreasedSteeringPenalty", "AFX_Faulty_gainFrozen",
    "AFX_Faulty_Afterburner_onEmptyBecomeFrozen", "AFX_Faulty_Landing_BecomeConcussed",
    "AFX_Faulty_Afterburner_onEmptyCorrode", "AFX_Faulty_Afterburner_onEmptySysMalf",
    "AFX_Faulty_Afterburner_becomeFrozen", "AFX_Faulty_PerfectStart_Crash"
}
M.BM_ITEMS = 3                                           -- the dealer's shop places (WBP_Item_1..3)
M.BM_SALE = 75                                           -- BlackMarketTuneConfig.SalesPriceModifierPercentage
M.BM_KIND = "experimental"                               -- p.vendorKind of a stock rolled by these rules
local BM_GOOD_SET = {}
for _, id in ipairs(M.BM_GOOD) do BM_GOOD_SET[id] = true end

local function bmSeed(ctrlId)
    local f = nil
    pcall(function() f = M.fpOf(activeRun()) end)
    f = type(f) == "table" and f or {}
    local k = seatKey(ctrlId)
    local Rm = RW()
    return Rm and Rm.seedOf(f.seed or 0, f.id or 0, f.ch or 0, k and (k - 1) or ctrlId, "couch-blackmarket") or 1
end

-- his price of one dealer item: { full (the part's rarity price x his shop factor), sale (x (100 - 75)%) }
function M.bmPrice(row, p)
    local full = price({ rkind = "part", pips = row.pips }, p)
    local sale = tonumber(opt("CouchVendorSale", M.BM_SALE)) or M.BM_SALE
    return full, math.max(0, math.floor(full * (100 - sale) / 100 + 0.5))
end

-- the dealer's stock for him (pure: his build + a seed) -> rows { rkind "part", id, name, exp, fault, faultName,
-- rarity, pips, price, fullPrice }
function M.rollBlackMarket(p, seed)
    local Rm = RW()
    local rnd = Rm and Rm.stream(seed or 1) or { int = function(n) return math.random(n) end }
    local pool = {}
    for _, it in ipairs(partPool(p)) do if BM_GOOD_SET[it.id] then pool[#pool + 1] = it end end
    local bad = {}
    for _, id in ipairs(M.BM_BAD) do if PD and PD.PARTS and PD.PARTS[id] then bad[#bad + 1] = id end end
    local rows = {}
    while #rows < M.BM_ITEMS and #pool > 0 and #bad > 0 do
        local it = table.remove(pool, rnd.int(#pool))
        local fid = table.remove(bad, rnd.int(#bad))
        local d, fd = PD.PARTS[it.id], PD.PARTS[fid]
        local r = { rkind = "part", id = it.id, name = tostring(d.name or it.id), exp = true, fault = fid,
                    faultName = tostring(fd.name or fid), rarity = it.rarity, pips = math.max(1, math.min(4, (tonumber(it.rarity) or 0) + 1)) }
        r.fullPrice, r.price = M.bmPrice(r, p)
        rows[#rows + 1] = r
    end
    return rows
end

function M.makeShop(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    if not p then return nil end
    local rows = M.rollBlackMarket(p, bmSeed(ctrlId))
    local names = {}
    for _, r in ipairs(rows) do names[#names + 1] = string.format("%s+%s %d", r.id, r.fault, r.price) end
    rows[#rows + 1] = { rkind = "leave", id = "leave", name = "LEAVE THE SHOP", sub = "" }
    p.vendorShop, p.vendorKind = rows, M.BM_KIND         -- (his own shop's planet stock, p.shop, is not touched)
    save()
    U.log(TAG, "P%s's scrap dealer stock (experimental, %d%% off): %s", tostring(p.pnum),
        tonumber(opt("CouchVendorSale", M.BM_SALE)) or M.BM_SALE, #names > 0 and table.concat(names, ", ")
        or "nothing for his class")
    return rows
end

-- P1's run seed + the node (the native mid-event seed rule: a resume re-rolls the same offers)
local function flowSeed(ctrlId)
    local r = activeRun()
    local a, b = 0, 0
    if r then
        pcall(function() a = tonumber(r.mGeneratedEventSeed) or 0 end)
        if a == 0 then pcall(function() a = tonumber(r.Map.mSeed) or 0 end) end
        pcall(function() b = U.arrayCount(r.mPlayerPath) end)
        if b == 0 then pcall(function() b = tonumber(M.fpOf(r).ch) or 0 end) end
    end
    local Rm = RW()
    -- "a resume re-rolls the same offers" for the SEAT, whatever pad sits in it: seat - 1 (= the pad id of the
    -- seat's usual pad, the value this seed had before seats)
    local k = seatKey(ctrlId)
    return Rm and Rm.seedOf(a, b, k and (k - 1) or ctrlId, "couch-flow") or 1
end

-- the flow ctx for one guest (info from onRaceEnd) -> ctx
function M.flowCtx(ctrlId, p, info)
    local m = mods(p)
    local planet = info.planet or 1
    local rar = D and D.rarity or {}
    local rw = (info.kind == "highrisk" and rar.highrisk and rar.highrisk[math.min(5, planet)])
        or (rar.event and rar.event[math.min(6, planet)]) or { 60, 20, 10, 5 }
    local pool, fams = partPool(p)
    local earned = info.offer ~= false
    -- an eliminator he failed himself (outside the top 3: FailReasons HighRisk natively) earns him no round
    local top = math.floor(tonumber(opt("CouchHighRiskTop", 3)) or 3)
    if info.kind == "highrisk" and not info.sitOut and (tonumber(info.pos) or 99) > top then earned = false end
    local contrib = {}
    for _, n in ipairs(info.favNotes or {}) do contrib[#contrib + 1] = n end
    local ctx = {
        kind = info.kind, activity = info.activity, earned = earned, pos = info.pos, pay = info.cr,
        wrecked = info.wrecked, sitOut = info.sitOut, timeTrial = info.kind == "fieldtest" or info.kind == "planesprint",
        beat = info.beat, score = info.score, bonus = info.bonus, contrib = contrib, skip = skipCredits(),
        contract = info.contract, penalty = info.penalty,
        tune = { cards = math.max(1, math.floor(tonumber(opt("CouchGuestRewardCards", 3)) or 3) - math.floor(m.fewer)),
                 picks = 1, max = LEVEL_MAX, famChance = 33.3,
                 guarantee = math.floor(tonumber(opt("CouchGuestHighRiskRarity", 2)) or 2) },
        partPool = pool, ownedFams = fams, rarityW = rw, seed = flowSeed(ctrlId),
        faults = type(p.faultQueue) == "table" and p.faultQueue or {},
        extra = info.extra,                                -- #110: his favours' credit lines
    }
    -- #110 his favours: card count, rarity weights, level boost, part rarity (couchfavours.flowTune) + bonus rounds
    local f = F()
    if f then
        local notes = f.flowTune(p, ctx)
        if #notes > 0 then U.log(TAG, "P%s's favours on his rewards: %s", tostring(p.pnum), table.concat(notes, ", ")) end
    end
    -- couch-fix32: HIS MYST_108 "better upgrades" deal (TNS_MYST_BetterUpgradeRewards: UpgradeLevelBoostWeights
    -- {0, 1, 0.01}): every upgrade card one level more, 0.01 / 1.01 of them two more (it replaces Deeper Pockets' boost)
    if m.better then ctx.tune.boost, ctx.tune.boost2 = 1, 0.01 / 1.01 end
    if type(info.favRounds) == "table" and #info.favRounds > 0 then
        ctx.favRounds = info.favRounds
        for _, sp in ipairs(info.favRounds) do
            if sp.kind == "ab" then
                local pool = {}
                for _, c in ipairs(abilityCands(p)) do
                    pool[#pool + 1] = { id = c.id, lvl = c.lvl, up = c.up, from = c.from }
                end
                table.sort(pool, function(a, b) return a.id < b.id end)      -- the stream picks by index
                ctx.abilityPool = pool
                break
            end
        end
    end
    return ctx
end

-- couch-fix63 (AUTO-154g): couchrules.flowLabel - a failed podracer test's round is named as the solo fail's
local function flowLabel(ctx)
    local ok, r = pcall(require, "couchrules")
    if ok and type(r) == "table" and type(r.flowLabel) == "function" then
        local okL, s = pcall(r.flowLabel, ctx.kind, ctx.earned, ctx.beat)
        if okL and type(s) == "string" then return s end
    end
    return ctx.earned and "rewards earned" or "no reward round"
end

-- his flow from the race end (onRaceEnd) -> flow or nil
function M.buildFlow(ctrlId, p, info)
    if opt("CouchRewardFlow", true) == false then return nil end
    local Rm = RW()
    if not Rm then return nil end
    local ctx = M.flowCtx(ctrlId, p, info)
    local stages = Rm.stagesFor(p.lo, ctx)
    local flow = { v = M.FLOW_V, gen = St.worldGen, seed = ctx.seed, kind = ctx.kind, tune = ctx.tune, skip = ctx.skip,
                   stages = stages,
                   credit = { pay = ctx.pay, pos = ctx.pos, wrecked = ctx.wrecked, sitOut = ctx.sitOut,
                              timeTrial = ctx.timeTrial, beat = ctx.beat, score = ctx.score, bonus = ctx.bonus,
                              contrib = ctx.contrib, contract = ctx.contract, penalty = ctx.penalty,
                              extra = ctx.extra } }
    local t = {}
    for _, st in ipairs(stages) do
        t[#t + 1] = tostring(st.type) .. (st.round and ("(" .. st.round.kind .. " x" .. #st.round.cards .. ")") or "")
    end
    U.log(TAG, "P%s's own reward flow (%s, %s): stages %s%s", tostring(p.pnum), tostring(ctx.kind),
        flowLabel(ctx), #t > 0 and table.concat(t, ",") or "none",
        (#(ctx.faults or {}) > 0) and string.format(", %d fault(s)", #ctx.faults) or "")
    return flow
end

-- his challenge of this race joins the CREDITS stage (it may settle after the race end): stage rows refreshed while
-- the credits stage is not collected yet -> true when the stages changed
function M.flowRefresh(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    local f = p and p.flow
    local Rm = RW()
    if not (f and Rm and type(f.stages) == "table") then return false end
    local lb = p.lastBet
    if not (type(lb) == "table" and lb.gen == f.gen and not lb.inFlow) then return false end
    local ci = nil
    for i, st in ipairs(f.stages) do if st.type == Rm.STAGE.CREDITS then ci = i end end
    if ci and f.stages[ci].collected then return false end
    local cctx = {}
    for k, v in pairs(f.credit or {}) do cctx[k] = v end
    cctx.bet = { name = lb.name, won = lb.won, pay = lb.pay, stake = lb.stake }
    if ci then
        for _, r in ipairs(f.stages[ci].rows or {}) do if r.reason == Rm.REASON.maxed then cctx.maxedSkip = r.delta end end
    end
    local rows, total = Rm.creditRows(cctx)
    if #rows == 0 then return false end
    local st = { type = Rm.STAGE.CREDITS, reason = rows[1].reason, rows = rows, total = total }
    if ci then f.stages[ci] = st
    else
        local at = 1                                       -- after the faults stages, before the rounds
        for i, x in ipairs(f.stages) do if x.type == Rm.STAGE.FAULTS then at = i + 1 end end
        table.insert(f.stages, at, st)
    end
    for i, x in ipairs(f.stages) do x.i = i end
    lb.inFlow = true
    save()
    U.log(TAG, "P%s's CREDITS stage: his challenge vs %s (%s) added", tostring(p.pnum), tostring(lb.name),
        lb.won and "won" or "lost")
    return true
end

-- the row of one round card (couchpanel's card rows: statRow / the catalog part row)
local function flowCardRow(p, c, idx, seed)
    local row
    if c.rkind == "stat" then
        row = statRow(c.id, p)
        local cur = math.floor(tonumber(p.lo.tune[c.id]) or 0)
        local lv = math.max(1, math.min(tonumber(c.lv) or 1, LEVEL_MAX - cur))
        row.lv = lv
        row.name = row.name:gsub("%s*%+1$", "") .. " +" .. lv
        row.sub = string.format("LEVEL %d -> %d", cur, cur + lv)
        row.grade = lv
    elseif c.rkind == "ab" then
        -- #110 Feet First's ABILITY PACK: a new ability or the next pip of one he has (applyClaim: up / from)
        local a = PD and PD.ABILITIES and PD.ABILITIES[c.id] or {}
        row = { rkind = "ab", id = c.id, name = tostring(a.name or c.id), desc = a.desc or "", icon = a.icon,
                lvl = c.lvl or a.lvl, up = c.up, from = c.from, grade = tonumber(c.lvl or a.lvl) or 1 }
    else
        local d = PD and PD.PARTS and PD.PARTS[c.id] or {}
        row = { rkind = c.rkind, id = c.id, name = tostring(d.name or c.id), desc = d.desc or "", icon = d.icon,
                grade = (tonumber(d.rarity) or 0) + 1 }
    end
    row.fstage, row.fseed = idx, seed
    return row
end

-- the rows of his round stage idx (cards + SKIP) -> rows, round
function M.flowRows(ctrlId, idx)
    loadState()
    local p = M.player(ctrlId)
    local f = p and p.flow
    local st = f and f.stages and f.stages[idx]
    if not (st and st.round) then return nil end
    local rows = {}
    for _, c in ipairs(st.round.cards or {}) do rows[#rows + 1] = flowCardRow(p, c, idx, f.seed) end
    if st.round.skippable ~= false then
        local cr = math.floor(tonumber(st.round.skip) or skipCredits())
        rows[#rows + 1] = { rkind = "skip", id = "skip", name = "SKIP REWARD", sub = string.format("+%d CR", cr),
                            credits = cr, fstage = idx, fseed = f.seed }
    end
    p.offer = rows                                       -- the claim / journal fold look for the open offer
    save()
    return rows, st.round
end

-- a claimed row advances his flow (any player record: live or a checkpoint's copy)
flowClaimed = function(p, item, lo)
    local f = p.flow
    local idx = tonumber(item.fstage)
    if not (type(f) == "table" and idx and type(f.stages) == "table" and f.seed == item.fseed) then return end
    local st = f.stages[idx]
    if not st or st.collected then return end
    st.picked = (st.picked or 0) + 1
    if item.rkind == "skip" or st.picked >= (st.round and st.round.picks or 1) then st.collected = true end
    local Rm = RW()
    if Rm and item.rkind == "stat" then
        local n = Rm.rerollAfterPick(f.stages, idx, item.id, lo.tune, { tune = f.tune }, f.seed)
        if n > 0 then U.log(TAG, "P%s: %d later stat round(s) re-rolled after his %s pick (native)", tostring(p.pnum), n,
            tostring(item.name or item.id)) end
    end
end

local amendFlow      -- CHECKPOINT JOURNAL (below)

-- his CREDITS / FAULTS stage collected (couchflow's COLLECT / CONTINUE) -> true
local function collectStage(p, idx, seed)
    local f = p.flow
    if not (type(f) == "table" and f.seed == seed and type(f.stages) == "table") then return false end
    local st = f.stages[idx]
    if not st or st.collected then return false end
    local Rm = RW()
    if Rm and st.type == Rm.STAGE.FAULTS then
        p.faults = type(p.faults) == "table" and p.faults or {}
        local left = {}
        local applied = {}
        for _, x in ipairs(st.faults or {}) do applied[tostring(x.part)] = x.fault end
        for part, fault in pairs(applied) do
            p.faults[part] = fault
            if type(p.fixed) == "table" then p.fixed[part] = nil end         -- a repaired part faults again
        end
        for _, q in ipairs(type(p.faultQueue) == "table" and p.faultQueue or {}) do
            if not applied[tostring(q.part)] then left[#left + 1] = q end
        end
        p.faultQueue = (#left > 0) and left or nil
    end
    st.collected = true
    return true
end

function M.flowCollect(ctrlId, idx)
    loadState()
    local p = M.player(ctrlId)
    if not (p and p.flow) then return false end
    local seed = p.flow.seed
    local st = p.flow.stages and p.flow.stages[idx]
    if not collectStage(p, idx, seed) then return false end
    save()
    U.log(TAG, "P%s collected his %s stage (%d/%d)%s", tostring(p.pnum),
        (st.type == 6 and "FAULTS") or (st.type == 1 and "CREDITS") or tostring(st.type), idx, #p.flow.stages,
        st.type == 6 and string.format(": %d fault(s) on his parts", #(st.faults or {})) or "")
    U.try(TAG, amendFlow, ctrlId, idx, seed)
    return true
end

-- his area went before his flow was done (P1 travelled, a world change): nothing is held back - each open round books
-- its SKIP credits (the old rule), his faults land on his parts, the credits stage is marked seen -> stages closed
function M.flowAbandon(ctrlId, why)
    loadState()
    local p = M.player(ctrlId)
    local f = p and p.flow
    if not (type(f) == "table" and type(f.stages) == "table") then return 0 end
    local n, cr = 0, 0
    for i, st in ipairs(f.stages) do
        if not st.collected then
            if st.round then
                local c = (st.round.skippable ~= false) and math.floor(tonumber(st.round.skip) or skipCredits()) or 0
                M.claim(ctrlId, { rkind = "skip", id = "skip", name = "SKIP REWARD", credits = c, fstage = i, fseed = f.seed })
                cr = cr + c
            else
                M.flowCollect(ctrlId, i)
            end
            n = n + 1
        end
    end
    if n > 0 then
        U.warn(TAG, "P%s's reward flow left with %d stage(s) open (%s): skip credits +%d CR, faults applied", tostring(p.pnum),
            n, tostring(why), cr)
    end
    return n
end

-- his flow: the stage list (read-only copy for the views) and the current index, nil when none
function M.flow(ctrlId)
    loadState()
    local p = M.player(ctrlId)
    local f = p and p.flow
    if not (type(f) == "table" and type(f.stages) == "table" and #f.stages > 0) then return nil end
    local Rm = RW()
    local cur = Rm and Rm.current(f) or nil
    return f, cur
end
function M.flowDone(ctrlId)
    local f, cur = M.flow(ctrlId)
    return f ~= nil and cur == nil
end
-- his faulted parts (a copy for perkapply: the fault on top of the part, EAffixStatus Faulty), or nil
function M.faultedParts(ctrlId)
    local p = M.player(ctrlId)
    if not (p and type(p.faults) == "table") then return nil end
    local out, n = {}, 0
    for id, fault in pairs(p.faults) do if fault then out[id] = fault; n = n + 1 end end
    return n > 0 and out or nil
end
-- couchfaults: a fault his car got in this race (queued, applied at his FAULTS stage)
function M.queueFault(ctrlId, part, fault, why)
    loadState()
    local p = M.player(ctrlId)
    if not p then return false end
    p.faultQueue = type(p.faultQueue) == "table" and p.faultQueue or {}
    for _, q in ipairs(p.faultQueue) do if q.part == part then return false end end
    p.faultQueue[#p.faultQueue + 1] = { part = part, fault = fault }
    save()
    local d = PD and PD.PARTS
    U.log(TAG, "P%s's %s gets a fault: %s (%s)", tostring(p.pnum), tostring(d and d[part] and d[part].name or part),
        tostring(d and d[fault] and d[fault].name or fault), tostring(why))
    return true
end

---------------------------------------------------------------------------------------------------- results
-- POSTRACE: each guest's finish -> credits + a pending reward offer (made when P1's round is known)
-- ECONOMY: the credits are couchrules.guestOutcome's native payout (one row, time trials by target, the
-- championship unmultiplied) with HIS end-of-event multiplier (his mystery deals x Victorious Loser in the bottom N),
-- then his Lyren bonuses (Favour_MYST_StarCreditsForVictory: +250 on the podium / +1000 for a win, race events).
local FAIL_TARGET = 2 + 8                               -- REC.FailReasons ModeRules | ExtraConditions (target missed)
local racing = { atMs = nil, ms = nil, paid = false }   -- this world's race (M.init's phase listener)
local metaRace = {}                                     -- couch-fix35: {visit, tp, kp, alone} of the race being paid
local amendRace      -- CHECKPOINT JOURNAL (below)
-- couch-fix46: Biddy Blas' race bet (MYST_FAV rager) settled on one race. bet = m.rager, gpos / gwrecked = his place
-- in the race (the global grid's, as the native RacePositionRelativeRequirement compares), bpos = Biddy Blas' place (nil:
-- he does not race here = the requirement never fires). Pure. -> delta, reason (nil when nothing is settled)
function M.ragerBetDelta(bet, gpos, gwrecked, bpos)
    if type(bet) ~= "table" or not tonumber(bpos) then return nil end
    gpos, bpos = tonumber(gpos) or 99, tonumber(bpos)
    local ahead = (not gwrecked) and gpos >= 1 and gpos < bpos
    if ahead then return math.floor(tonumber(bet.ahead) or 0), "Biddy Blas' Bet - Finished Ahead" end
    return math.floor(tonumber(bet.behind) or 0), "Biddy Blas' Bet - Finished Behind"
end

-- couch-fix46: Biddy Blas' place in this race (the grid entry whose pilot is DA_Racer_Rager: the recipe's entries,
-- else GameState.Racers' PlayerState.Pilot) -> place, or nil when he does not race
local function ragerPlace()
    local ps = nil
    pcall(function()
        local racers = U.giSubsystem("EventRecipeSubsystem").ActiveRecipe.RecipeState.Racers
        for i = 1, U.arrayCount(racers) do
            local r = racers[i]
            if U.ok(r) and U.ok(r.Pilot) and U.objName(r.Pilot) == M.RAGER_DEF then ps = r.Player; break end
        end
    end)
    if not U.ok(ps) then
        ps = nil
        pcall(function()
            local racers = U.gs().Racers
            for i = 1, U.arrayCount(racers) do
                local q = racers[i]
                if U.ok(q) and U.ok(q.Pilot) and U.objName(q.Pilot) == M.RAGER_DEF then ps = q; break end
            end
        end)
    end
    if not U.ok(ps) then return nil end
    local pos = nil
    pcall(function() pos = math.floor(tonumber(ps.RaceEventComponent.EventPosition) or 0) end)
    return (pos and pos >= 1) and pos or nil
end
M._ragerPlace = ragerPlace

function M.onRaceEnd()
    racing.paid = true
    metaRace = {}                                       -- couch-fix35: this race's node figures for couchmeta
    local paid = {}                                     -- [seat] = {cr, pos, offer}: folded into a race-end checkpoint
    loadState()
    local planet, kind = nodeInfo()
    local act, engine = actEngine()
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" then return end
    for _, e in ipairs(list) do
        local p = M.ensure(e.ctrlId, e.pnum)
        local m = mods(p)
        local pos, wrecked, fails = 99, false, nil
        pcall(function()
            local rec = e.pc.PlayerState.RaceEventComponent
            pos = math.floor(tonumber(rec.EventPosition) or 99)
            wrecked = rec.bHasVehicleWrecked == true
        end)
        pcall(function() fails = math.floor(tonumber(e.pc.PlayerState.RaceEventComponent.FailReasons)) end)
        -- couch-fix30 (audit 12 #5): a final event a guest won for the team swapped his REC with P1's (couchrules
        -- finalSwap, before this listener): his payout, rounds, bet and backer rating follow HIS real place
        pcall(function()
            local rp, rw, rf = rules().realResult(e.pc.PlayerState)
            if rp then
                U.log(TAG, "P%d's real result (the final-event swap rewrote his REC: P%d): P%d%s", e.pnum, pos, rp,
                    rw and " wrecked" or "")
                pos, wrecked, fails = math.floor(tonumber(rp) or 99), rw == true, math.floor(tonumber(rf) or 0)
            end
        end)
        local gridPos, gridWrecked = pos, wrecked                -- couch-fix46: his place on the shared grid
        -- couch-trial2: a mission with instances pays his place in HIS OWN race (instances.localPosition)
        pcall(function()
            local lp, gp = U.mod("instances").localPosition(e.pc.PlayerState)
            if lp then
                U.log(TAG, "P%d paid for his own race's place %d (global %s)", e.pnum, lp, tostring(gp))
                pos = lp
            end
        end)
        -- #81 (live 2026-10-18 08:41, Jakku ELIMINATOR): P2 outlasted P1 (eliminated 1st), led the last lap and wrecked
        -- with 3 racers left; his REC read P12 + wrecked = 0 CR and "no own reward round" while P1 got CHOOSE A PART.
        -- A refunded wreck in an elimination race is booked as his elimination at his standing (couchrules).
        local outNote = nil
        if wrecked then
            local okO, op, why = pcall(function() return rules().wreckOutPlace(e.ctrlId) end)
            if okO and op then
                U.log(TAG, "P%d %s (the game's row: P%d wrecked)", e.pnum, tostring(why), pos)
                pos, wrecked, outNote = op, false, string.format("out in place %d (wrecked)", op)
            end
        end
        local beat = nil                                -- nil: the team's result decides (couchrules)
        local score = nil                               -- #72: his own count (soloscore) for his credits row
        if fails and (fails & FAIL_TARGET) ~= 0 then beat = false end
        -- #37: a takedowns / ramjet test: HIS own count decides (the game's fail rule reads one tracked player)
        pcall(function()
            local sc = U.mod("soloscore").scoreOf(e.pc.PlayerState)
            if type(sc) == "table" then
                -- #68: was "(not sc.reached) and false or nil" = always nil (and/or with a false middle): a guest who
                -- missed his own target was paid "target beaten" (+1250) and got a 0-CR "Beat Target Time" stage
                beat = sc.reached == true
                score = { kind = sc.kind, value = sc.value, target = sc.target }
                U.log(TAG, "P%d's own score %s: %s", e.pnum, tostring(sc.text), sc.reached and "target met" or "target missed")
            end
        end)
        local mult, notes = m.mult, {}
        local vr = favRank(p, "Veteran")                -- Victorious Loser: x1.5 (native +0.5) in the bottom 3 / 6 / 9
        local gn = tonumber(G.gridN)
        if vr > 0 and gn and gn > 0 and pos <= gn and pos > gn - GUEST_FAV.Veteran[vr] then
            mult = mult * 1.5
            notes[#notes + 1] = "Victorious Loser x1.5"
        end
        if m.mult ~= 1 then notes[#notes + 1] = string.format("his deal x%g", m.mult) end
        local cr, offer, note = 0, true, ""
        local R = rules()
        local okR, out = pcall(function()
            return R.guestOutcome({ kind = kind, planet = planet, pos = pos, wrecked = wrecked, mult = mult,
                beat = beat, act = act, engine = engine, sitOut = R.isSittingOut(e.ctrlId),
                teamEarned = R.teamEarned() })
        end)
        if okR and type(out) == "table" then
            cr, offer, note = math.floor(tonumber(out.credits) or 0), out.offer, out.note or ""
        else                                            -- no rules module: the native row, unmultiplied
            local row = D and D.payouts and D.payouts.native and D.payouts.native.pos or { 1250 }
            cr = (wrecked or pos >= 99) and 0 or math.floor(tonumber(row[math.max(1, math.min(#row, pos))]) or 0)
        end
        -- couch-fix36 (Q4, CouchBrokerPenalty "owner"): HIS Broker penalty planet = his standard races follow the
        -- eliminator's rule for his own payout (outside the top 3: no reward round), the shared map untouched
        pcall(function()
            local eo, en = U.mod("couchpenalty").ownerEliminator(p, planet, kind, pos, wrecked)
            if eo ~= nil then
                if eo == false then offer = false end
                note = (note ~= "" and (note .. "; ") or "") .. en
            end
        end)
        local raceKind = okR and R.multipliedKind and R.multipliedKind(kind) or false
        local sat = okR and R.isSittingOut and R.isSittingOut(e.ctrlId) or false
        if raceKind and not wrecked and not sat and pos >= 1 and pos < 99 then
            if m.top3 > 0 and pos <= 3 then cr = cr + m.top3; notes[#notes + 1] = string.format("podium +%d", m.top3) end
            if m.win > 0 and pos == 1 then cr = cr + m.win; notes[#notes + 1] = string.format("win +%d", m.win) end
        end
        if note ~= "" then table.insert(notes, 1, note) end
        if outNote then table.insert(notes, 1, outNote) end
        note = table.concat(notes, "; ")
        -- couch-fix21 (#90): HIS backer contract's count of this race (couchbacker: his own car's goal), paid per action
        -- like the game's "ContractActions" credits row; a planet raced without his check-in is settled first
        local contract, settled = nil, 0
        pcall(function()
            local BK = U.mod("couchbacker")
            settled = tonumber(BK.settleOld(e.ctrlId, e.pnum, planet)) or 0
            contract = BK.raceResult(e, p, { planet = planet, kind = kind, pos = (not wrecked) and pos or nil })
        end)
        local ccr = contract and math.floor(tonumber(contract.cr) or 0) or 0
        if ccr > 0 then
            notes[#notes + 1] = string.format("contract +%d%s", ccr, contract.migrated and " (P1's backer, migrated)" or "")
        end
        -- his backer's penalty (the Pirate's 40%% after HIS displeased check-in): his end-of-event credits only
        local cut = 0
        pcall(function()
            local BK = U.mod("couchbacker")
            cut = math.min(cr, BK.penaltyCut(p, planet, cr))
            BK.addEarned(p, planet, cr - cut + ccr)
        end)
        if cut > 0 then
            cr = cr - cut
            notes[#notes + 1] = string.format("backer takes %d", cut)
        end
        note = table.concat(notes, "; ")
        p.credits = (p.credits or 0) + cr + ccr
        p.lastPos, p.lastPay, p.offerPending = pos, cr, offer
        -- couch-rewards2: his own stage list (faults, credits, rounds) from HIS result
        local favNotes = {}
        for _, n in ipairs(notes) do
            if not n:find("^podium") and not n:find("^win ") and n ~= note and n ~= outNote then favNotes[#favNotes + 1] = n:upper() end
        end
        local bonus = { top3 = 0, win = 0 }
        if raceKind and not wrecked and not sat and pos >= 1 and pos < 99 then
            if m.top3 > 0 and pos <= 3 then bonus.top3 = m.top3 end
            if m.win > 0 and pos == 1 then bonus.win = m.win end
        end
        -- #72 (tester #4, t11 12-collect.png): "(beat ~= nil) and beat or (... and false or nil)" turned a false beat
        -- into nil (the #68 and/or trap again): a guest who MISSED his own takedown target got a "Beat Target Time 0" row
        local flowBeat = beat
        if flowBeat == nil and okR and type(out) == "table" and out.note == "target missed" then flowBeat = false end
        -- #110 HIS favours on HIS result: credit lines (Team Vranki, Family Legacy), bonus rounds (Feet First, Fan Club,
        -- Silent Defiance, Brutal Calm), Old Greats' repair after his passed podracer test
        local fav = { extra = nil, rounds = nil, repaired = nil }
        local f = F()
        if f then
            U.try(TAG, function()
                local ps = nil
                pcall(function() ps = e.pc.PlayerState end)
                local won = flowBeat
                if won == nil and okR and type(out) == "table" and out.note == "target beaten" then won = true end
                local finfo = { kind = kind, pos = pos, wrecked = wrecked, sitOut = sat, beat = won,
                                td = f.takedownsOf(ps), crashesLeft = f.crashesLeft(e.pc) }
                f.countEvent(p, finfo)
                local Rm = RW()
                local rnd = Rm and Rm.stream(Rm.seedOf(flowSeed(e.ctrlId), "favour-rolls")) or nil
                local extra = f.creditExtras(p, finfo)
                local add = 0
                for _, x in ipairs(extra) do add = add + x.delta end
                if add ~= 0 then
                    fav.extra, fav.add = extra, add
                    p.credits = (p.credits or 0) + add
                end
                if rnd then
                    local specs, rnotes = f.bonusRounds(p, finfo, rnd)
                    if #specs > 0 then fav.rounds = specs end
                    local faulty = {}
                    for _, r in ipairs(M.repairRows(e.ctrlId)) do if r.status == AFFIX_FAULTY then faulty[#faulty + 1] = r.id end end
                    local fixId = f.oldGreats(p, finfo, faulty, rnd)
                    if fixId then
                        p.fixed = type(p.fixed) == "table" and p.fixed or {}
                        p.fixed[fixId] = true
                        if type(p.faults) == "table" then p.faults[fixId] = nil end
                        fav.repaired = fixId
                        local d = PD and PD.PARTS and PD.PARTS[fixId]
                        favNotes[#favNotes + 1] = "OLD GREATS: " .. string.upper(tostring(d and d.name or fixId)) .. " REPAIRED"
                        rnotes[#rnotes + 1] = "OLD GREATS repaired " .. tostring(fixId)
                    end
                    for _, x in ipairs(extra) do rnotes[#rnotes + 1] = string.format("%s x%d +%d CR", x.reason, x.n or 1, x.delta) end
                    if #rnotes > 0 then
                        U.log(TAG, "P%s's favours (%s, P%d, %d takedown(s), crashes left %s): %s", tostring(p.pnum), kind, pos,
                            finfo.td.n, tostring(finfo.crashesLeft), table.concat(rnotes, "; "))
                    end
                end
            end)
        end
        -- couch-fix32 (audit 12 #17): his PASSED podracer test also pays the game's "Passed Podracer Challenge" row
        -- (PlaneTestCredits 3,000) beside the finish row: a line of his CREDITS stage like the favours' lines
        local plane = (okR and type(out) == "table") and math.floor(tonumber(out.plane) or 0) or 0
        if plane > 0 and not sat then
            fav.extra = fav.extra or {}
            fav.extra[#fav.extra + 1] = { reason = "Passed Podracer Challenge", delta = plane, n = 1 }
            fav.add = (fav.add or 0) + plane
            p.credits = (p.credits or 0) + plane
            U.log(TAG, "P%s passed the podracer test: +%d CR (Passed Podracer Challenge) beside his finish row %d",
                tostring(p.pnum), plane, cr)
        end
        -- couch-fix46: HIS Biddy Blas race bet (MYST_106A on his half): +ahead / behind vs Biddy Blas' place, a line of
        -- his CREDITS stage like the game's "Biddy Blas' Bet - Finished Ahead / Behind" credit rows
        if m.rager and not sat then
            local bpos = ragerPlace()
            local delta, reason = M.ragerBetDelta(m.rager, gridPos, gridWrecked, bpos)
            if delta and delta ~= 0 then
                if delta < 0 then delta = math.max(delta, -math.max(0, p.credits or 0)) end
                fav.extra = fav.extra or {}
                fav.extra[#fav.extra + 1] = { reason = reason, delta = delta, n = 1 }
                fav.add = (fav.add or 0) + delta
                p.credits = (p.credits or 0) + delta
            end
            U.log(TAG, "P%s's Biddy Blas bet (lvl %s): P%s%s vs Biddy Blas %s -> %s", tostring(p.pnum),
                tostring(m.rager.lvl), tostring(gridPos), gridWrecked and " wrecked" or "",
                bpos and ("P" .. bpos) or "not in this race", delta and string.format("%+d CR", delta) or "nothing")
        end
        local okF, flow = pcall(M.buildFlow, e.ctrlId, p, { kind = kind, planet = planet, pos = pos, wrecked = wrecked,
            sitOut = sat, beat = flowBeat, score = score, cr = cr + cut, offer = offer, bonus = bonus, favNotes = favNotes,
            contract = (ccr > 0) and { line = contract.line, cr = ccr } or nil,
            penalty = (cut > 0) and cut or nil, extra = fav.extra, favRounds = fav.rounds })
        -- #110 his favour credit lines (booked above) are lines of his CREDITS stage, beside the backer contract's
        if (fav.add or 0) ~= 0 then cr = cr + fav.add; p.lastPay = cr end
        if not okF then U.warn(TAG, "P%s's reward flow failed (%s): the mirror offer instead", tostring(p.pnum), tostring(flow)) end
        p.flow = okF and flow or nil
        -- #87 / #107: a guest's failed test = what the game shows a solo player for that result. Live 2026-10-18: a failed
        -- FIELD TEST booked "earned rewards false, finish credits 0" (P1: no CREDITS / round stage, 09:03); P1's failed
        -- PODRACER test (10:11) showed FAULTS ("Critical Malfunction Error") + CREDITS + UPGRADE PACK: the FAULTS stage is
        -- built from the queued malfunction faults whatever the result. So his failed field test keeps only his FAULTS
        -- stage(s) and a CREDITS stage with a real credit change (no 0-credit hub); nothing left = no flow, no area.
        -- (A failed podracer test keeps its whole flow: offer true, the bottom row's credits, the base round.)
        -- #89: a guest who sat the test out (no run of his own): no flow at all
        if p.flow and okR and type(out) == "table" and out.offer == false and (kind == "fieldtest" or kind == "planesprint") then
            local keep, Rm = {}, RW()
            if not sat and Rm then
                for _, st in ipairs(p.flow.stages or {}) do
                    if st.type == Rm.STAGE.FAULTS or (st.type == Rm.STAGE.CREDITS and (tonumber(st.total) or 0) ~= 0) then
                        keep[#keep + 1] = st
                    end
                end
            end
            for i2, st in ipairs(keep) do st.i = i2 end
            if #keep > 0 then
                p.flow.stages = keep
                U.log(TAG, "P%s failed his own %s: his flow = the solo fail's stages (%d: faults / credits, no round)",
                    tostring(p.pnum), kind, #keep)
            else
                U.log(TAG, "P%s %s his own %s: no reward flow (no fault, no credit change: the game shows a solo player "
                    .. "nothing)", tostring(p.pnum), sat and "has no run of" or "failed", kind)
                p.flow = nil
                offer = false
            end
        end
        -- couch-fix35 (Q6): his completed event onto P1's account (tuning / kit points, the tracked unlocks' counters)
        U.try(TAG, function()
            local MM = META()
            if not MM then return end
            local visit = metaRace.visit
            if visit == nil then
                visit = M.visitKey() or "?"
                metaRace.visit = visit
                local nd = currentNode()
                if nd then
                    pcall(function() metaRace.tp = tonumber(nd.FinishTuningPointsAwarded) or 0 end)
                    pcall(function() metaRace.kp = tonumber(nd.FinishKitPointsAwarded) or 0 end)
                end
                pcall(function()
                    local L = rules().last
                    if L and L.gen == St.worldGen and L.alone then metaRace.alone = L.aloneKind end
                end)
                if not metaRace.alone and kind == "fieldtest" then
                    pcall(function() metaRace.alone = U.mod("couchsolo").info().kind end)
                end
            end
            local td = 0
            pcall(function() td = tonumber(F().takedownsOf(e.pc.PlayerState).n) or 0 end)
            local seat = p.seat or e.pnum
            -- a planet he raced is behind the run now: his favours held there count it (PlanetsCompleted)
            local pl = tonumber(p.metaPlanet)
            if pl and planet > pl then
                MM.planetDone(string.format("%s:planet%d:%s", tostring(G.runId or "?"), pl, tostring(seat)), p.pnum,
                    type(p.metaFav) == "table" and p.metaFav or {})
            end
            if not pl or planet ~= pl then
                p.metaPlanet = planet
                local fv = {}
                for _, id in ipairs(type(p.favours) == "table" and p.favours or {}) do if id then fv[#fv + 1] = id end end
                p.metaFav = fv
            end
            MM.raceEnd({ visit = visit, seat = seat, pnum = p.pnum, kind = kind, aloneKind = metaRace.alone, pos = pos,
                         wrecked = wrecked, sitOut = sat, takedowns = td, style = p.style, tp = metaRace.tp,
                         kp = metaRace.kp })
        end)
        if p.flow then p.faultQueue = nil end               -- queued faults now live in his FAULTS stage
        if p.flow then p.offerPending = #p.flow.stages > 0 else p.offerPending = offer end
        if p.seat then
            paid[p.seat] = { cr = cr + ccr + settled, pos = pos, offer = p.offerPending, flow = p.flow, lastPay = cr,
                             backer = type(p.backer) == "table" and deepCopy(p.backer) or nil,
                             fav = p.fav, repaired = fav.repaired }
        end
        U.log(TAG, "P%s finished P%d%s: +%d CR (total %d)%s", tostring(p.pnum), pos, wrecked and " (wrecked)" or "",
            cr + ccr, p.credits, note ~= "" and (" - " .. note) or "")
    end
    save()
    U.try(TAG, amendRace, "race payout", function(sp, seat)
        local d = paid[seat]
        if not d then return false end
        sp.credits = (sp.credits or 0) + d.cr
        sp.lastPos, sp.lastPay, sp.offerPending = d.pos, d.lastPay or d.cr, d.offer
        sp.flow, sp.faultQueue = d.flow and deepCopy(d.flow) or nil, nil
        if d.backer then sp.backer = deepCopy(d.backer) end           -- couch-fix21: his contract's progress
        sp.fav = d.fav and deepCopy(d.fav) or sp.fav                       -- #110 Feet First's event count
        if d.repaired then                                                  -- #110 Old Greats' repair
            sp.fixed = type(sp.fixed) == "table" and sp.fixed or {}
            sp.fixed[d.repaired] = true
            if type(sp.faults) == "table" then sp.faults[d.repaired] = nil end
        end
        return true
    end, true)
end

---------------------------------------------------------------------------------------------------- side bets
-- The guests' PRE-RACE CHALLENGES (couchbets.lua): one open bet per guest (p.bet, saved with his run), the stake taken
-- from his couch credits when he challenges, paid back x cfg.CouchBetPayout when he wins, refunded when the race is
-- left before its result. bet = {name, stake, predicted, rival, gen, rule, target}. -> ok, toast
function M.placeBet(ctrlId, bet)
    loadState()
    local p = M.player(ctrlId)
    if not p or type(bet) ~= "table" then return false, nil end
    if p.bet then return false, "ALREADY CHALLENGED " .. tostring(p.bet.name) end
    local stake = math.max(0, math.floor(tonumber(bet.stake) or 0))
    if (p.credits or 0) < stake then return false, "NOT ENOUGH CREDITS" end
    p.credits = (p.credits or 0) - stake
    p.bet = { name = tostring(bet.name or "?"), stake = stake, predicted = tonumber(bet.predicted),
              rival = bet.rival == true, gen = bet.gen, rule = bet.rule, target = bet.target ~= false,
              racer = type(bet.racer) == "string" and bet.racer or nil }           -- #110: Racer Roulette's Biddy Blas
    save()
    U.log(TAG, "P%s challenges %s (predicted P%s): stake %d CR (left %d)", tostring(p.pnum), p.bet.name,
        tostring(p.bet.predicted), stake, p.credits)
    return true, string.format("CHALLENGE %s  -%d CR", p.bet.name, stake)
end

-- the race result: won = stake x cfg.CouchBetPayout into his credits. info = {pos, out, targetPos}. -> credits paid
function M.settleBet(ctrlId, won, info)
    loadState()
    local p = M.player(ctrlId)
    if not p or not p.bet then return 0 end
    local b = p.bet
    info = type(info) == "table" and info or {}
    local pay = 0
    if won then
        -- native: a won sidebet credits the stake (CreditsReason_WonSidebet), a lost one debits it (LostSidebet);
        -- here the stake left at the challenge, so a win gives it back x2 (= the same +stake / -stake net)
        local mult = tonumber(opt("CouchBetPayout", 2)) or 2
        pay = math.max(0, math.floor(b.stake * mult + 0.5))
        -- High Roller (Favour_Nomad_N: CreditsBalancePassiveEffectConfig, CalculationMethod SidebetStake,
        -- SidebetStakePercentage 50 / 75 / 100): + that share of the STAKE (it was a share of the x2 pay = double)
        local nr = favRank(p, "Nomad")
        if nr > 0 then pay = pay + math.floor(b.stake * GUEST_FAV.Nomad[nr] + 0.5) end
        p.credits = (p.credits or 0) + pay
    end
    p.bet = nil
    p.lastBet = { name = b.name, stake = b.stake, won = won == true, pay = pay, gen = St.worldGen }
    save()
    if F() then U.try(TAG, F().onBet, p.seat or 2, won == true, b.racer, b.name) end    -- #110 Racer Roulette (team)
    U.try(TAG, amendRace, "challenge settled", function(sp, cid)
        if cid ~= seatKey(ctrlId) or not M.sameBet(sp.bet, b) then return false end
        sp.credits = (sp.credits or 0) + pay
        sp.bet = nil
        sp.lastBet = { name = b.name, stake = b.stake, won = won == true, pay = pay }
        return true
    end, false)
    U.log(TAG, "P%s challenge vs %s (predicted P%s, stake %d CR): P%s %s vs %s -> %s (total %d CR)",
        tostring(p.pnum), b.name, tostring(b.predicted), b.stake, tostring(p.pnum),
        info.out and "OUT" or ("P" .. tostring(info.pos)), "P" .. tostring(info.targetPos),
        won and string.format("WON +%d CR", pay) or "LOST", p.credits or 0)
    U.try(TAG, M.wreckCredits160, ctrlId, p)
    return pay
end

-- couch-fix65 (AUTO-160d, live round 10 14:07:25, standard race Sentinel I: P2 wrecked (refunded: P1 still raced), P1
-- won): P2 got NO area at all. The rule is the solo one and stays (couchrules D2/D4, couch-fix13 #81): a wreck is no
-- finish (the native ingestion books no finish row, 0 CR) and earns no reward round - only a REFUNDED wreck in an
-- elimination race (eliminator / gauntlet) counts as an elimination at his standing. But the solo hub still shows
-- what a wrecked racer's race did to his credits: his side bet (CreditsReason_LostSidebet / WonSidebet), backer
-- lines, favour lines. His flow was built at the race end with no stage (no finish row, no round) and offerPending
-- false, and his challenge settled right after it ("LOST", -1000 CR) never reached a CREDITS stage: no area opened,
-- the lost stake shown nowhere. When a challenge settles on such a flow (this world, no stage, no area pending), its
-- CREDITS stage is made now (flowRefresh) and his area opens with P1's reward screen: CREDITS (the challenge row) on
-- his hub, no round - the solo wreck. A wreck with nothing to show (no bet, no lines) keeps no area, as before.
function M.wreckCredits160(ctrlId, p)
    p = p or M.player(ctrlId)
    local f = p and p.flow
    if not (type(f) == "table" and type(f.stages) == "table" and #f.stages == 0) then return false end
    if f.gen ~= St.worldGen or p.offerPending then return false end
    if not M.flowRefresh(ctrlId) then return false end
    p.offerPending = true
    save()
    U.log(TAG, "P%s's race left him no stage (%s): his settled challenge makes his CREDITS stage - his area opens "
        .. "with P1's reward screen, no reward round (the solo rule, AUTO-160d)", tostring(p.pnum),
        (f.credit and f.credit.wrecked) and "wrecked" or "no finish row")
    return true
end

-- the bet cannot be judged (race left, target unreadable): the stake back
function M.voidBet(ctrlId, why)
    loadState()
    local p = M.player(ctrlId)
    if not p or not p.bet then return 0 end
    local b = p.bet
    p.credits = (p.credits or 0) + (b.stake or 0)
    p.bet = nil
    save()
    U.try(TAG, amendRace, "challenge void", function(sp, cid)
        if cid ~= seatKey(ctrlId) or not M.sameBet(sp.bet, b) then return false end
        sp.credits = (sp.credits or 0) + (b.stake or 0)
        sp.bet = nil
        return true
    end, false)
    U.log(TAG, "P%s challenge vs %s void (%s): stake %d CR refunded (total %d CR)", tostring(p.pnum), tostring(b.name),
        tostring(why), b.stake or 0, p.credits or 0)
    return b.stake or 0
end

---------------------------------------------------------------------------------------------------- the pilot
-- (5) "P2 doesn't have a body" (live, couch campaign races + results): the campaign builds its grid with ONE human
-- (P1, the run's pilot) and couch.patchGrid only hands a guest the Player of an AI entry. Nothing ever gave the guest
-- a pilot: his GfnPlayerState.Pilot (+0x3D0) stays null (the front end sets it only in FREE MODE: launch /
-- perkapply.assignPilots), while the entry keeps the replaced AI's RacerDef. The seated pilot of a car
-- (VehicleAnimationComponent:SynchronousRefreshPilot rebuilds it from the PlayerState's Pilot - perkapply's seat
-- check) and the results / podium holograms read the racer's PlayerState pilot: no RacerDef = no body. FREE MODE's
-- fix applied here: each guest on the grid gets a RacerDef on BOTH his recipe entry (FRecipeRacerSetup.Pilot) and his
-- PlayerState (it travels with the PlayerState like FREE MODE's), before the travel. Which pilot: his own from the
-- first race on (couchrun p.pilot, saved), else pilots.defaultFor (the first free class specialist, as FREE MODE's
-- guest default) - never one another racer of this grid already has (P1, a rival, an AI): no AI is ever re-assigned,
-- P1's entry and the run's story opponents are never touched. His own taken this race (an AI holds it) = the next
-- free one for this race only (p.pilot kept). -> notes
local function nameOfObj(o)
    if not U.ok(o) then return nil end
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    if ok and type(n) == "string" and n ~= "" and n ~= "None" then return n end
    return nil
end
M.nameOfObj = nameOfObj

function M.assignPilots(racers, n, guests, tt)
    local okP, PIL = pcall(U.mod, "pilots")
    if not (okP and type(PIL) == "table") then return {} end
    local entryOf, taken = {}, {}
    for i = 1, tonumber(n) or 0 do
        pcall(function()
            local r = racers[i]
            local ps = r.Player
            if U.ok(ps) then entryOf[U.key(ps)] = i end
        end)
    end
    local mine = {}
    for _, g in ipairs(guests) do if g.ps and entryOf[U.key(g.ps)] then mine[entryOf[U.key(g.ps)]] = true end end
    for i = 1, tonumber(n) or 0 do
        if not mine[i] then
            pcall(function()
                local id = nameOfObj(racers[i].Pilot)
                if id then taken[id] = -1 end
            end)
        end
    end
    local notes = {}
    for _, g in ipairs(guests) do
        local idx = g.ps and entryOf[U.key(g.ps)]
        local p = M.player(g.ctrlId)
        if idx and p then
            local arch = tonumber(g.arch) or tonumber(p.arch) or 0
            local e = nil
            pcall(function() e = PIL.defaultFor(arch, false, taken, p.pilot, g.ctrlId) end)
            local def = e and PIL.def(e) or nil
            if U.ok(def) then
                local okR = pcall(function() racers[idx].Pilot = def end)
                local okS = pcall(function() g.ps.Pilot = def end)
                taken[e.id] = g.ctrlId
                if p.pilot == nil then p.pilot = e.id; save() end
                g.pilotId = e.id
                notes[#notes + 1] = string.format("P%d=%s%s%s%s", g.pnum, e.id, okR and "" or " (entry refused)",
                    okS and "" or " (PlayerState refused)", (p.pilot ~= e.id) and (" (his " .. tostring(p.pilot) .. " is taken)") or "")
            else
                notes[#notes + 1] = string.format("P%d=(no pilot resolved)", g.pnum)
            end
        end
    end
    if #notes > 0 then U.log(TAG, "guest pilots: %s", table.concat(notes, " ")) end
    return notes
end

-- In the race world: a guest whose PlayerState lost the pilot on the travel (or whose seat was built before it) gets
-- it back and his seated pilot rebuilt (perkapply's PilotSeatCheck "refresh" technique), once per world and guest.
-- MAIN race tick (main.lua). Retried while his car is not spawned yet (PRERACE / RACING, at most 40 ticks).
local seat = { wk = nil, done = {}, tries = 0 }
local function couchCars() PA().couchRaceTick() end          -- couch-fix29 (no closure per tick: couch-racegc)
function M.raceTick()
    if St.phase ~= "PRERACE" and St.phase ~= "RACING" then return end
    local okC, on = pcall(function() return U.mod("couch").active() end)
    if not (okC and on == true) then return end
    -- couch-fix29: each guest's build verified on his car, his traits applied, the per-race "couch car" line
    U.tryEvery("couchrun.cars", nil, TAG, couchCars)
    if seat.wk ~= St.worldGen then seat.wk, seat.done, seat.tries = St.worldGen, {}, 0 end
    if seat.tries >= 40 then return end
    seat.tries = seat.tries + 1
    loadState()
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" then return end
    local okP, PIL = pcall(U.mod, "pilots")
    if not (okP and type(PIL) == "table") then return end
    for _, e in ipairs(list) do
        local p = M.player(e.ctrlId)
        local want = p and (p.racePilot or p.pilot) or nil
        if want and not seat.done[e.ctrlId] then
            U.try(TAG, function()
                local ps = nil
                pcall(function() ps = e.pc.PlayerState end)
                if not U.ok(ps) then return end
                local pawn = nil
                pcall(function() pawn = ps.PawnPrivate end)
                if not U.ok(pawn) then return end                -- not spawned yet: next tick
                seat.done[e.ctrlId] = true
                local have = nameOfObj(ps.Pilot)
                if have == want then
                    U.log(TAG, "P%d seated pilot: %s", e.pnum, want)
                    return
                end
                local def = PIL.def(want)
                if not U.ok(def) then return end
                pcall(function() ps.Pilot = def end)
                local how = "not refreshed (no VehicleAnimationComponent)"
                local cls = U.class("/Script/Griffin.VehicleAnimationComponent")
                local anim = nil
                if U.ok(cls) then pcall(function() anim = pawn:GetComponentByClass(cls) end) end
                if U.ok(anim) then
                    local okR, errR = pcall(function() anim:SynchronousRefreshPilot() end)
                    how = okR and "refreshed" or ("refresh failed: " .. tostring(errR))
                end
                U.log(TAG, "P%d pilot in race: %s -> %s, seat %s", e.pnum, tostring(have), want, how)
            end)
        end
    end
    -- every guest seated (or nothing to seat): no more passes this world (couch-racefast)
    local left = false
    for _, e in ipairs(list) do
        local p = M.player(e.ctrlId)
        if p and (p.racePilot or p.pilot) and not seat.done[e.ctrlId] then left = true end
    end
    if not left and #list > 0 then seat.tries = 40 end
end

---------------------------------------------------------------------------------------------------- the car
-- After couch.patchGrid (and every kickoff that puts guests on a grid): every guest's run build into his own
-- PlayerState (the race spawn applies it), for HIS class (perkapply takes the class per pick: pick.arch).
-- couch-fix29 (audit 12 issue 1): what P1's car gets in each race type, the guest's gets the same way:
--   * a race built at the pick (standard, eliminator / high risk, knockout, championship, boss, mystery race): his run
--     build - levels, abilities, crash, his parts in HIS part slots (F().partSlots: 4 + his Gadgeteer, the entry's
--     AffixSlots grown to them: the live 0-slot entries of 2026-10-18 08:32 / 08:36), his faults and repairs, and his
--     racer style's traits (the native run applies only P1's style: perkapply couchRaceTick);
--   * a FIELD TEST races the event's own test build (EVT_SHK_*.CustomVehicle.VehicleBuildDef, e.g. VBD_SHK_PRT_
--     Skimmer_MAS_T3; the all-PC builder writes it for P1 and every guest alike - the guest's entry going 0 -> 6 slots
--     at the 08:49 takedowns kickoff is that write): nothing of the run build is written (P1 races none of his either),
--     only his traits. cfg.CouchFieldTestRunBuild = true restores the old write of his run build into the test class;
--   * a PODRACER TEST (planet plane test, #88 podracer node: the one-human builder, CustomVehicle = a preset pod, no
--     build def) races the racer's own build: P1's pod reads his entry RacerBuildState.ArchetypeToUseForPlane names.
--     The guest's points the same way (P1's points at his run class -> the guest's at HIS run class; at the pod entry
--     -> his pod entry, his build validated for pods) and gets his build there; his seat keeps the mission pilot.
-- how (optional): {pod = true} (#88 podracer node kickoff), {field = true} (a field-test kickoff).
-- One "build for this race" line per guest, then perkapply's "couch car" line in the race.
local function podIndexOf(ps)
    local v = nil
    pcall(function() v = tonumber(ps.RacerBuildState.ArchetypeToUseForPlane) end)
    return v
end

function M.buildText(p, lo, slots, faults, fixed, traits, styleText)
    local t = {}
    for sl = 0, 5 do t[#t + 1] = tostring(lo.tune[sl] or 0) end
    local ab = {}
    for n = 1, 4 do if lo.ab[n] then ab[#ab + 1] = tostring(lo.ab[n]) end end
    local nP, flt, rep = 0, {}, 0
    for i = 1, slots or #lo.parts do
        local id = lo.parts[i]
        if id then
            nP = nP + 1
            local d = PD and PD.PARTS and PD.PARTS[id]
            if (type(faults) == "table" and faults[id]) or (d and (d.faulty or d.rarity == 4)) then flt[#flt + 1] = id end
            if type(fixed) == "table" and fixed[id] then rep = rep + 1 end
        end
    end
    local base = math.max(1, math.floor(tonumber(opt("CouchGuestPartSlots", 4)) or 4))
    return string.format("levels %s, abilities %s, crash %s, parts %d in %d slot(s)%s%s%s, traits %d%s",
        table.concat(t, "/"), #ab > 0 and table.concat(ab, ",") or "-", tostring(lo.crash or "-"), nP, slots or 0,
        (slots or 0) > base and string.format(" (%d + %d Gadgeteer/kept)", base, slots - base) or "",
        #flt > 0 and (", faulty " .. table.concat(flt, " ")) or "", rep > 0 and string.format(", %d repaired", rep) or "",
        type(traits) == "table" and #traits or 0, styleText and (" (" .. styleText .. ")") or "")
end

function M.applyBuilds(racers, n, how)
    how = type(how) == "table" and how or {}
    loadState()
    pcall(function() PA().couchForget("a new grid") end)
    G.gridN = tonumber(n)                               -- the grid size of the coming race (Victorious Loser)
    local camp = M.campaignArch() or G.arch
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" or #list == 0 then return end
    local okT, tt = pcall(function() return U.mod("couch").isTimeTrial() end)
    tt = okT and tt == true
    -- #30: a plane test (KickOffPlaneTestEvent); #88: a podracer node (PlaneSprint, activity 10)
    local okPl, plane = pcall(function() return U.mod("couch").isPlaneTest() end)
    local act = nil
    pcall(function() act = U.mod("couch").chosenActivity() end)
    local pod = (okPl and plane == true) or how.pod == true or tonumber(act) == 10
    local field = not pod and (tt or how.field == true)
    local R = rules()
    local kind = pod and "podracer test" or field and "field test"
        or (R and R.kindOf and R.kindOf(act)) or "campaign"
    -- never an index past the grid (UE4SS grows a TArray read at Num + 1): an empty grid has no P1 entry to read
    local hasP1 = U.arrayCount(racers) >= 1
    local ttArch = nil
    if hasP1 and (tt or field) then pcall(function() ttArch = tonumber(racers[1].VehicleType) end) end
    local p1ps = nil
    if hasP1 then pcall(function() p1ps = racers[1].Player end) end
    local p1Pod = (pod and U.ok(p1ps)) and podIndexOf(p1ps) or nil
    -- only the guests the grid holds: a build written for a guest without an entry would log "ok" for a car he has not
    local onGrid = {}
    for i = 1, tonumber(n) or 0 do
        pcall(function()
            local ps = racers[i].Player
            if U.ok(ps) then onGrid[U.key(ps)] = true end
        end)
    end
    local runBuildInField = opt("CouchFieldTestRunBuild", false) == true
    local hc, players, first, notes, lines = {}, {}, nil, {}, {}
    local pg = {}                                       -- (5) the guests on the grid, for their pilots
    if F() then U.try(TAG, F().onRunStart, "first grid") end   -- #110 (once per run: the run-start fallback)
    for _, e in ipairs(list) do
        local p = M.ensure(e.ctrlId, e.pnum)
        pcall(M.startTour, e.ctrlId, e.pnum)            -- the run's first grid: his "begin tour" favours (once)
        local ps = nil
        pcall(function() ps = e.pc.PlayerState end)
        local own = M.archOf(e.ctrlId, e.pnum)
        local arch = own
        if field then arch = tonumber(ttArch or camp) end
        if pod then
            -- his pod reads the entry his ArchetypeToUseForPlane names: pointed like P1's (run class -> his run class)
            local want = (p1Pod ~= nil and p1Pod ~= 1) and own or 1
            if U.ok(ps) and want ~= nil then
                pcall(function()
                    if podIndexOf(ps) ~= want then ps.RacerBuildState.ArchetypeToUseForPlane = want end
                end)
            end
            arch = want
        end
        if U.ok(ps) and not onGrid[U.key(ps)] then
            notes[#notes + 1] = string.format("P%d not on the grid", e.pnum)
        elseif U.ok(ps) and arch ~= nil then
            local pcKey = nil
            pcall(function() pcKey = U.key(e.pc) end)
            hc[U.key(ps)] = { pnum = e.pnum, ctrlId = e.ctrlId, ps = ps, pcKey = pcKey }
            local traits, styleText = M.styleTraits(p)
            local slots = (F() and F().partSlots(p)) or math.max(#(p.lo.parts or {}), 4)
            local fixed, faults = M.fixedParts(e.ctrlId), M.faultedParts(e.ctrlId)
            local pick = { ctrlId = e.ctrlId, loadout = K().copy(p.lo), arch = arch, fixed = fixed, faults = faults,
                           partSlots = slots, styleTraits = traits, styleText = styleText, kind = kind }
            if field and not runBuildInField then
                pick.traitsOnly = true
                lines[#lines + 1] = string.format("P%d build for this %s: the test's own build (as P1's), traits %d%s",
                    e.pnum, kind, type(traits) == "table" and #traits or 0, styleText and (" (" .. styleText .. ")") or "")
            else
                lines[#lines + 1] = string.format("P%d build for this %s (class %s%s): %s", e.pnum, kind, tostring(arch),
                    pod and string.format(", P1's pod reads entry %s", tostring(p1Pod or "?")) or "",
                    M.buildText(p, pick.loadout, slots, faults, fixed, traits, styleText))
            end
            players[e.pnum] = pick
            pg[#pg + 1] = { ps = ps, pnum = e.pnum, ctrlId = e.ctrlId, arch = arch }
            first = first or arch
            notes[#notes + 1] = string.format("P%d %s/%s%s", e.pnum, tostring(arch), tostring(p.style or "pilot"),
                field and " (field test: P1's test vehicle)" or pod and " (podracer test: P1's mission pod)" or "")
        end
    end
    if first == nil then return end
    if pod then
        -- #30 / #88: the mission's pod and character (couch.patchGrid / instances copied P1's entry: vehicle, pilot): his
        -- seat keeps the mission pilot
        local pil = nil
        pcall(function() pil = nameOfObj(racers[1].Pilot) end)
        for _, g in ipairs(pg) do
            local pp = M.player(g.ctrlId)
            if pp then pp.racePilot = pil end
        end
    else
        -- (5) a body for every guest: his pilot on his entry + PlayerState. NOT handed to applyAll as pick.pilotId: that
        -- makes perkapply validate his run loadout against the pilot's racer style (his couch build would change)
        U.try(TAG, function()
            M.assignPilots(racers, n, pg, tt or field)
            for _, g in ipairs(pg) do
                local pp = M.player(g.ctrlId)
                if pp then pp.racePilot = g.pilotId end
            end
        end)
    end
    for _, l in ipairs(lines) do U.log(TAG, "%s", l) end
    local p1Arch = pod and 1 or (field and ttArch) or camp
    local plan = { arch = first, flow = "cards", players = players, couch = true, kind = kind, p1Arch = p1Arch }
    local okA, rep = pcall(function() return PA().applyAll(racers, n, hc, plan) end)
    U.log(TAG, "guest builds applied (%s): %s", table.concat(notes, ", "),
        okA and tostring(type(rep) == "table" and rep.text or rep) or tostring(rep))
end

function M.summary(ctrlId)
    local p = M.player(ctrlId)
    if not p then return "-" end
    local t = {}
    for s = 0, 5 do t[#t + 1] = tostring(p.lo.tune[s] or 0) end
    local ab = {}
    for n = 1, 4 do if p.lo.ab[n] then ab[#ab + 1] = tostring(p.lo.ab[n]) end end
    return string.format("P%s %s/%s %d CR  levels %s  abilities %s", tostring(p.pnum), tostring(p.arch),
        tostring(p.style or "pilot"), p.credits or 0, table.concat(t, "/"), table.concat(ab, ","))
end

-- fix16 bug 2 (live 2026-10-15: "[couchrun] P2 finished P1: +1250 CR" on a CONTINUE): a run resumed into its post
-- event loads the race map and goes PRERACE -> POSTRACE within a second, nobody races (the race was paid before the
-- quit). A guest is paid only for a race whose RACING phase was seen in this world for cfg.CouchMinRaceMs (1 s: the
-- live resume had no RACING at all; harness races can be short).
-- pure: -> paid?, why
function M.raceRan(racingMs, minMs)
    minMs = tonumber(minMs) or 1000
    if racingMs == nil then return false, "no RACING phase in this world (a post-event resume)" end
    if racingMs < minMs then
        return false, string.format("RACING lasted %d ms (< %d)", math.floor(racingMs), math.floor(minMs))
    end
    return true, "raced"
end
---------------------------------------------------------------------------------------------------- checkpoint journal
-- RUNSYNC (2026-10-16). The flaw: after a crash or a quit mid-run the game resumes P1's run from its LAST SAVE (the run
-- checkpoint: run start, node pick, race end, after rewards - notes 2026-10-14 evening), while couch-run.txt was written
-- at every guest change. A guest kept what he bought / won after that checkpoint and the players were out of step.
--
-- The checkpoint event: CampaignSaveManager broadcasts OnSaveStartedEvent / OnSaveEndedEvent(bool success) around every
-- save it writes; its BP-visible listener is the save icon WBP_SaveGame_Icn (one instance, outer = the GameInstance,
-- ObjectDump), whose OnSaveStarted / OnSaveEnded(success) custom events are bound to them (decoded ubergraph:
-- EX_BindDelegate + EX_AddMulticastDelegate on CampaignSaveManager). Hooked here: OnSaveStarted = the moment the run is
-- serialised (the broadcast and the serialisation are one native call on the game thread: no Lua runs between them), so
-- the guests' state at that call IS the state that belongs to the saved run. There is no "SaveRunAsync" UFunction to
-- hook (research 01 section 4). The same events also fire for the META save (settings, unlocks): a staged checkpoint is
-- confirmed as a RUN save by the run's own clock (CampaignRun:GetTimeSinceLastSaveInSeconds back near 0, runSave =
-- true / false, nil = unreadable). That clock is also the FALLBACK detector (syncTick): a run save the icon hook missed
-- (class not loaded, hook refused) is staged at the next poll.
--
-- Each checkpoint = {seq, at, why, fp, cont, world, sess, pendPay, post, runSave, state = a copy of the guests' state}
-- in couch-run-journal.txt (the last cfg.CouchJournalMax, default 8). fp = P1's run fingerprint at the save: RunId,
-- Map.mSeed, nodes chosen / completed, the current node's RewardRoundIx, Credits, Strikes - what the loaded run shows
-- again after a CONTINUE.
-- RESUME (resumeCheck): once per entry into a run (mod start / every FRONTEND visit), at the first phases with an
-- ActiveRun, P1's loaded run fingerprint picks the newest checkpoint with the SAME fingerprint and the guests' live
-- state becomes that checkpoint's copy (newer checkpoints = a future that did not happen: dropped). No match = the
-- live state is kept (never worse than before: a missed save, a solo run, a file from before this journal).
-- Quitting to the menu and CONTINUE = the same path (the run is rebuilt from the save at CONTINUE).
-- Race consequences: the race-end save comes BEFORE the guests' payout (it runs at the last human's finish, while
-- RACING: fix16's gate flag landed in it). A checkpoint whose continue state is PostEvent (5) and whose world's payout
-- has not happened yet (pendPay) gets the payout folded in when it happens (the resumed post event pays nobody:
-- raceRan), and a challenge it still holds open gets its settlement. A reward claim of an offer the checkpoint already
-- held open is folded in too (P1's "after rewards" save comes with his pick, the guest picks a moment later).
--
-- SAVE LISTENER (couch-savepath, live 2026-10-16): the save icon hooks NEVER fired live (UE4SS-launch3.log: every
-- checkpoint came from the run clock, "a run save the save icon hook did not report"). The icon binds its handlers in
-- its Construct (decoded ubergraph: SetRenderOpacity(0), GetGameInstanceSubsystem(CampaignSaveManager), bind
-- OnSaveStarted / OnSaveEnded += the manager's OnSaveStartedEvent / OnSaveEndedEvent): no constructed icon in the
-- world (the ObjectDump only has its CDO) = nobody listens. The mod now constructs its OWN instance (collapsed, z -1000,
-- once per world, outside the quiet window): its Construct binds it to the CampaignSaveManager's own events, so the
-- same hooks fire for every save the manager writes, whatever the game's UI shows. One broadcast = one event (a game
-- icon and ours both bound: the second call inside SAVE_EVT_MS is ignored). OnSaveStarted runs inside the manager's
-- native save call: couch.saveOwnerSync puts the save on the pad-id-0 user right there (BUG 1) and the log says where
-- the save goes. The run clock stays the fallback. cfg.CouchSaveListener = false: no own instance.
local JFILE = "couch-run-journal.txt"
local SAVE_ICON = "/Game/Griffin/UI/Widgets/Messaging/WBP_SaveGame_Icn.WBP_SaveGame_Icn_C"
local SAVE_EVT_MS = 300
local LISTEN_PHASES = { OTHER = true, PRERACE = true, RACING = true, POSTRACE = true }
local listen = { w = nil, world = nil, tryAt = -1e12, tries = 0, made = 0, startAt = -1e12, endAt = -1e12, events = 0 }
local CONT_POST_EVENT = 5                -- EContinueRunState::PostEvent
local J = nil                            -- { v = 1, seq, cps = {checkpoint...} }
local sessN = 0
local SESSION = nil
local function newSession()
    sessN = sessN + 1
    SESSION = string.format("%d-%d-%d", os.time(), math.random(1, 999999), sessN)
end
newSession()
local resume = { pending = true, seen = {} }
local poll = { at = -1e12, t = nil, missLogged = false }

local function jmax() return math.max(2, math.floor(tonumber(opt("CouchJournalMax", 8)) or 8)) end

-- a plain-data deep copy (what ser writes: numbers, strings, booleans, tables)
local function plain(v)
    local t = type(v)
    if t == "number" or t == "string" or t == "boolean" then return v end
    if t ~= "table" then return nil end
    local out = {}
    for k, x in pairs(v) do
        local tk = type(k)
        if tk == "number" or tk == "string" then
            local c = plain(x)
            if c ~= nil then out[k] = c end
        end
    end
    return out
end
M._plain = plain

local function jPath()
    local ok, d = pcall(function() return settings.modDir() end)
    return (ok and type(d) == "string") and (d .. "/" .. JFILE) or nil
end

local jMigrate          -- SEAT MIGRATION (below)
local function journal()
    if J then return J end
    if not G then loadState() end        -- the live file's seat migration decides first (it migrates the journal too)
    if J then return J end
    local t = readTable(jPath(), JFILE)
    if t and type(t.cps) == "table" then J = t end
    J = J or { v = 1, seq = 0, cps = {} }
    if J.keys ~= "seat" then jMigrate(J, {}, "the journal alone (no pad-keyed couch-run.txt)") end
    return J
end
M._journal = journal


local function saveJournal()
    local p = jPath()
    if not p or not J then return end
    local f = io.open(p, "w")
    if not f then U.warn(TAG, "cannot write %s", JFILE); return end
    f:write("return " .. ser(J) .. "\n")
    f:close()
end

---------------------------------------------------------------------------------------------------- seat migration
-- SEAT MIGRATION (couch-seat, FINDING #43). Before seats, couch-run.txt and every checkpoint's state keyed the guests'
-- records by pad ControllerId: one guest who came back on another pad slot got a SECOND record with the same player
-- number (live 2026-10-18: G.players[1] = P2 3025 CR 5 parts from the DS4 on ctrlId 1, G.players[2] = P2 4710 CR 0
-- parts from the vpad on ctrlId 2; after the relaunch his payouts went to [1]). At the first load of such a file:
--   * each record's seat = its pnum (the P number it was saved with; ctrlId + 1 when it has none); seats 2-4 only;
--   * one record per seat is kept. RULE: the record with the most recent checkpoint of the CURRENT RUN wins - the
--     newest journal checkpoint (fp.id = the run id: P1's live run when readable, else the newest checkpoint's run) at
--     which that record CHANGED (its copy differs from the previous checkpoint's of the same run, or is new there); a
--     live record that differs from the newest checkpoint's copy changed after it (newer than every checkpoint). Ties
--     (no change seen, no journal): the lowest old ControllerId. Each kept / dropped record is logged with its credits
--     and parts;
--   * the checkpoints are re-keyed the same way (a seat keeps the same old record where the checkpoint has it, else
--     its lowest old ControllerId), so a resume restores seat-keyed state;
--   * nothing is deleted: both old files are first copied next to them as couch-run.pre-seat-<date>-<time>.txt /
--     couch-run-journal.pre-seat-<date>-<time>.txt (no copy = the files are not rewritten this session).
local function partCount(p)
    local n = 0
    for _, v in pairs(type(p) == "table" and type(p.owned) == "table" and type(p.owned.part) == "table" and p.owned.part
        or {}) do if v then n = n + 1 end end
    return n
end
local function recLine(k, p)
    return string.format("ctrlId %s's record (P%s %d CR %d part(s))", tostring(k), tostring(type(p) == "table" and p.pnum
        or "?"), math.floor(tonumber(type(p) == "table" and p.credits) or 0), partCount(p))
end
local function oldSeat(k, p)
    local s = tonumber(type(p) == "table" and p.pnum)
    if s == nil and tonumber(k) then s = tonumber(k) + 1 end
    if s == nil or s < 2 or s > 4 or s ~= math.floor(s) then return nil end
    return s
end

-- pure (sim / tests): old pad-keyed players + the old journal's checkpoints (oldest first) -> seat-keyed players,
-- winners {[seat] = old key}, notes (log lines). runId nil = the newest checkpoint's run.
function M.seatMerge(players, cps, runId)
    players, cps = type(players) == "table" and players or {}, type(cps) == "table" and cps or {}
    if runId == nil then
        for i = #cps, 1, -1 do
            local c = cps[i]
            if type(c) == "table" and type(c.fp) == "table" and c.fp.id ~= nil then runId = c.fp.id; break end
        end
    end
    local mine = {}                                          -- the current run's checkpoints, oldest first
    for _, c in ipairs(cps) do
        if type(c) == "table" and type(c.state) == "table" and type(c.state.players) == "table"
            and (runId == nil or (type(c.fp) == "table" and c.fp.id == runId)) then mine[#mine + 1] = c end
    end
    local function copyOf(st, k)
        local v = st.players[k]
        if type(v) ~= "table" then return nil end
        return ser(v)
    end
    -- last change seq per old key
    local last = {}
    for i = 2, #mine do
        local prev, cur = mine[i - 1].state, mine[i].state
        for k in pairs(cur.players) do
            local now = copyOf(cur, k)
            if now ~= nil and now ~= copyOf(prev, k) then last[k] = tonumber(mine[i].seq) or i end
        end
    end
    local newest = mine[#mine]
    local after = (newest and tonumber(newest.seq) or 0) + 0.5
    for k, p in pairs(players) do
        if type(p) == "table" and (newest == nil or copyOf(newest.state, k) ~= ser(p)) then
            -- changed after the newest checkpoint (or no journal of this run: the live state is the newest thing)
            if newest ~= nil then last[k] = after end
        end
    end
    local groups = {}
    for k, p in pairs(players) do
        local s = oldSeat(k, p)
        if s then
            groups[s] = groups[s] or {}
            table.insert(groups[s], k)
        end
    end
    local out, winners, notes = {}, {}, {}
    for k, p in pairs(players) do
        if oldSeat(k, p) == nil then
            notes[#notes + 1] = string.format("%s has no seat (P number %s): dropped", recLine(k, p), tostring(p and p.pnum))
        end
    end
    local function when(k)
        local v = last[k]
        if v == nil then return "no change in the journal of run " .. tostring(runId) end
        if newest and v == after then return "changed after the newest checkpoint #" .. tostring(newest.seq) end
        return string.format("last changed at checkpoint #%s of run %s", tostring(v), tostring(runId))
    end
    local seats = {}
    for s in pairs(groups) do seats[#seats + 1] = s end
    table.sort(seats)
    for _, s in ipairs(seats) do
        local ks = groups[s]
        table.sort(ks, function(a, b)
            local la, lb = last[a] or -1, last[b] or -1
            if la ~= lb then return la > lb end
            local na, nb = tonumber(a), tonumber(b)
            if na and nb and na ~= nb then return na < nb end
            return tostring(a) < tostring(b)
        end)
        local win = ks[1]
        winners[s] = win
        local p = plain(players[win])
        p.seat = s
        p.pnum = tonumber(p.pnum) or s
        out[s] = p
        if #ks == 1 then
            notes[#notes + 1] = string.format("seat %d <- %s", s, recLine(win, players[win]))
        else
            notes[#notes + 1] = string.format("seat %d: %d records - KEPT %s (%s)", s, #ks, recLine(win, players[win]), when(win))
            for i = 2, #ks do
                notes[#notes + 1] = string.format("seat %d: DROPPED %s (%s; its text stays in the pre-seat copy)", s,
                    recLine(ks[i], players[ks[i]]), when(ks[i]))
            end
        end
    end
    return out, winners, notes
end

-- one checkpoint state (or any pad-keyed state table), re-keyed in place: winners first, else the lowest old key
local function rekeyState(st, winners)
    if type(st) ~= "table" or st.keys == "seat" then return false end
    local groups = {}
    for k, p in pairs(type(st.players) == "table" and st.players or {}) do
        local s = oldSeat(k, p)
        if s then groups[s] = groups[s] or {}; table.insert(groups[s], k) end
    end
    local out = {}
    for s, ks in pairs(groups) do
        local pick = nil
        for _, k in ipairs(ks) do if k == winners[s] then pick = k end end
        if pick == nil then
            table.sort(ks, function(a, b) return (tonumber(a) or 99) < (tonumber(b) or 99) end)
            pick = ks[1]
        end
        local p = st.players[pick]
        p.seat, p.pnum = s, tonumber(p.pnum) or s
        out[s] = p
    end
    st.players, st.keys = out, "seat"
    return true
end
M._rekeyState = rekeyState

local function copyNextTo(path, stem)
    local f = path and io.open(path, "r")
    if not f then return "" end                              -- no file: nothing to keep
    local src = f:read("a")
    f:close()
    if not src or src == "" then return "" end
    local name = stem .. ".pre-seat-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
    local o = io.open((path:gsub("[^/]+$", name)), "w")
    if not o then return nil end
    o:write(src)
    o:close()
    return name
end

jMigrate = function(Jt, winners, why)
    local n = 0
    for _, c in ipairs(type(Jt.cps) == "table" and Jt.cps or {}) do
        if type(c) == "table" and rekeyState(c.state, winners) then n = n + 1 end
    end
    Jt.keys = "seat"
    if n == 0 then return 0 end
    local kept = copyNextTo(jPath(), "couch-run-journal")
    if kept == nil then
        noWrite = noWrite or "the journal could not be copied before its seat migration"
        U.warn(TAG, "seat migration: %s could not be copied: %d checkpoint(s) re-keyed in memory only", JFILE, n)
        return n
    end
    saveJournal()
    U.log(TAG, "seat migration (%s): %d checkpoint(s) of %s re-keyed by seat%s", tostring(why), n, JFILE,
        kept ~= "" and (", old file kept as " .. kept) or "")
    return n
end

-- G holds the old pad-keyed file (loadState): -> G seat-keyed, J migrated, both files rewritten after their copies
migrateSeats = function()
    local old = G
    local jt = readTable(jPath(), JFILE)
    if not (jt and type(jt.cps) == "table") then jt = { v = 1, seq = 0, cps = {} } end
    local runId = nil
    pcall(function() runId = M.fpOf(activeRun()).id end)
    local players, winners, notes = M.seatMerge(old.players, jt.cps, runId)
    local kept = copyNextTo(filePath(), "couch-run")
    old.players, old.keys, old.v = players, "seat", STATE_V
    G = old
    U.log(TAG, "seat migration: %s keyed by pad ControllerId -> by SEAT (FINDING #43)%s", FILE,
        (kept and kept ~= "") and (", old file kept as " .. kept) or "")
    for _, n in ipairs(notes) do U.log(TAG, "seat migration: %s", n) end
    if kept == nil then
        noWrite = string.format("%s could not be copied before its seat migration (the old file is left as it is)", FILE)
        U.warn(TAG, "seat migration: %s", noWrite)
    end
    J = jt
    if kept == nil then
        for _, c in ipairs(jt.cps) do rekeyState(type(c) == "table" and c.state, winners) end   -- in memory only
        jt.keys = "seat"
        return
    end
    if jt.keys ~= "seat" then jMigrate(jt, winners, "with " .. FILE) end
    if not noWrite then save() end
end

-- resetRun (keep = false) / wipe (keep = true: the old text first goes to couch-run-journal.bak-<date>-<time>.txt)
journalReset = function(why, keep)
    journal()
    local n = #J.cps
    if keep then
        local p = jPath()
        local f = p and io.open(p, "r")
        if f then
            local src = f:read("a")
            f:close()
            if src and src ~= "" then
                local bp = p:gsub("[^/]+$", "couch-run-journal.bak-" .. os.date("%Y%m%d-%H%M%S") .. ".txt")
                local o = io.open(bp, "w")
                if o then o:write(src); o:close() end
            end
        end
    end
    J.cps = {}
    saveJournal()
    if n > 0 then U.log(TAG, "checkpoint journal cleared (%s): %d checkpoint(s) dropped", tostring(why), n) end
end

---------------------------------------------------------------------------------------------------- run identity
-- RUN IDENTITY (couch-fix31, campaign audit issue 3 + Q11 + the 3-4P seats). The flaw: couch-run.txt had no run id
-- and every guest went back to a starter build the moment WBP_PreRun_VehicleSelect appeared (resetRun at the screen).
-- NEW ACT -> back out -> CONTINUE wiped every guest (and the journal: no resume either); a run started without guests
-- and continued with them inherited the PREVIOUS run's guest wallets / parts / backers.
-- Now the guests' records belong to P1's run: G.runId = CampaignRun.RunId (a new run = a new id, REPLAY ACT included;
-- a CONTINUE rebuilds the run with its saved id).
--   * the pre-run screens (M.resetRun): the old run's guests go to G.stash (kept in the file), the screens' picks go
--     into a fresh G.players. Nothing is dropped yet.
--   * the first look at P1's run in play (bindTick: an ActiveRun, the couch on, no pre-run split open, outside the
--     quiet window) decides (bindRun):
--       stash of the SAME run id  -> the pre-run screens were backed out of: the stash comes back, the picks go;
--       stash, another id, the run at its start (no node chosen / done) -> the NEW run: the picks stay, the stash is
--                                    dropped (its text first copied to couch-run.bak-<date>-<time>.txt), journal cleared;
--       no stash, G.runId ~= the id -> another run than the guests' (CONTINUE of another save, a run started solo):
--                                    every guest starts fresh (old text copied first); the journal stays (a checkpoint
--                                    of THAT run still resumes);
--       no G.runId (a file from before run ids) -> the newest checkpoint's run id is the guests' (no journal: P1's run
--                                    is adopted as it is, the records kept).
--     A solo session (the couch off: another profile, P1 alone) never binds: it cannot touch the guests.
--   * P1's RUN-START credits (Q11): the first look at a run with no node chosen / done records Credits per run id
--     (G.starts, also solo); a guest who starts the tour later (a late joiner, a fresh guest after a CONTINUE) gets
--     that figure, never P1's wallet now (fallback: the run's oldest checkpoint at its start, else the wallet, WARN).
local bind = { key = nil }
local function nGuests(t)
    local n = 0
    for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end
    return n
end
-- the run id of the newest checkpoint (a file from before run ids: its records are that run's)
local function journalRunId()
    local j = journal()
    for i = #j.cps, 1, -1 do
        local c = j.cps[i]
        if type(c) == "table" and type(c.fp) == "table" and c.fp.id ~= nil then return c.fp.id end
    end
    return nil
end
-- the run the live records belong to (nil: unknown)
local function guestsRunId()
    loadState()
    if G.runId ~= nil then return G.runId end
    return journalRunId()
end
M.guestsRunId = guestsRunId
-- couch-run.txt's text before the guests of a run are dropped -> the copy's name ("" nothing to keep, nil failed)
local function backupFile(why)
    local p = filePath()
    local f = p and io.open(p, "r")
    if not f then return "" end
    local src = f:read("a")
    f:close()
    if not src or src == "" then return "" end
    local name = "couch-run.bak-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
    local o = io.open((p:gsub("[^/]+$", name)), "w")
    if not o then U.warn(TAG, "cannot keep a copy of %s (%s)", FILE, tostring(why)); return nil end
    o:write(src)
    o:close()
    return name
end
local function keptNote(kept) return (kept and kept ~= "") and (", old file kept as " .. kept) or "" end

-- P1's run-start credits of a run first seen at its start (no node chosen / done), once per run id -> noted?
local function noteStart(fp, how)
    if not (type(fp) == "table" and fp.id ~= nil and fp.ch == 0 and fp.dn == 0 and fp.cr ~= nil) then return false end
    G.starts = type(G.starts) == "table" and G.starts or {}
    if G.starts[fp.id] ~= nil then return false end
    G.starts[fp.id] = fp.cr
    local n = nGuests(G.starts)
    while n > 4 do                                         -- the last few runs only
        local lo = nil
        for k in pairs(G.starts) do
            if k ~= fp.id and (lo == nil or (tonumber(k) or 0) < (tonumber(lo) or 0)) then lo = k end
        end
        if lo == nil then break end
        G.starts[lo], n = nil, n - 1
    end
    U.log(TAG, "run %s starts with %d CR (P1's run-start credits: a guest's starting figure%s)", tostring(fp.id), fp.cr,
        tostring(how or ""))
    return true
end

-- the pre-run screens (couch.markPreRun, once per pre-run sequence): the guests of the run so far wait in G.stash
function M.resetRun(why)
    loadState()
    if type(G.stash) == "table" then
        -- a second pre-run sequence before any run was seen (backed out, NEW ACT again): the stash stays the real
        -- old run's, the picks start over
        U.log(TAG, "pre-run screens again (%s): the previous run's guests stay put aside (run %s), %d pick(s) of the "
            .. "last pre-run screens dropped", tostring(why), tostring(G.stash.runId), nGuests(G.players))
    else
        G.stash = { runId = guestsRunId(), players = G.players, arch = G.arch, at = os.date("%Y-%m-%d %H:%M:%S") }
        U.log(TAG, "new campaign run? (%s): %d guest run(s) of run %s put aside until P1's run shows which run is "
            .. "played (a new run: dropped; backed out to the same run: back)", tostring(why), nGuests(G.players),
            tostring(G.stash.runId))
    end
    G.players, G.arch = {}, M.campaignArch()
    unseated = {}
    save()
end

-- P1's run seen in play (fp = M.fpOf): the guests' records follow its id. -> what happened ("same" | "back" | "new" |
-- "other" | "adopt")
function M.bindRun(fp, why)
    loadState()
    local id = type(fp) == "table" and fp.id or nil
    if id == nil then return nil end
    local atStart = fp.ch == 0 and fp.dn == 0
    local noted = noteStart(fp, "")
    if type(G.stash) == "table" then
        local st = G.stash
        if st.runId ~= nil and st.runId == id then
            local picks = nGuests(G.players)
            G.players, G.arch, G.stash = type(st.players) == "table" and st.players or {}, st.arch or G.arch, nil
            G.runId = id
            unseated = {}
            save()
            U.log(TAG, "P1's run %s is the guests' run (%s): the pre-run screens were backed out of, the guests are back "
                .. "(%d pick(s) of those screens dropped)", tostring(id), tostring(why), picks)
            return "back"
        end
        local kept = nGuests(st.players) > 0 and backupFile("the previous run's guests") or ""
        local old = st.runId
        G.stash = nil
        G.runId = id
        if not atStart then
            -- the pre-run screens were left for ANOTHER run in progress (CONTINUE of another save): no pick applies
            G.players, unseated = {}, {}
        end
        save()
        journalReset("new campaign run", false)
        U.log(TAG, "new campaign run %s (%s): the guests of run %s dropped (%d)%s; %s", tostring(id), tostring(why),
            tostring(old), nGuests(st.players), keptNote(kept), atStart and
            string.format("%d guest(s) start it from their pre-run picks", nGuests(G.players))
            or "a run in progress: every guest starts fresh")
        return "new"
    end
    if G.runId == id then
        if noted then save() end
        return "same"
    end
    if G.runId == nil then
        local jid = journalRunId()
        if jid == nil or jid == id then
            G.runId = id
            save()
            U.log(TAG, "P1's run %s adopted as the guests' run (%s; %s): %d guest run(s) kept", tostring(id), tostring(why),
                jid and "the journal's run" or "a file from before run ids, no journal", nGuests(G.players))
            return "adopt"
        end
        G.runId = jid                                    -- the records are the journal's run: not this one
    end
    local old, n = G.runId, nGuests(G.players)
    local kept = n > 0 and backupFile("another run's guests") or ""
    G.players, G.runId, G.arch = {}, id, M.campaignArch() or G.arch
    unseated = {}
    save()
    U.log(TAG, "P1's run %s is not the guests' run %s (%s): %d guest run(s) put away%s, every guest starts this run fresh",
        tostring(id), tostring(old), tostring(why), n, keptNote(kept))
    return "other"
end

-- MAIN tick (syncTick, before the run-start grant and the save counter): the first look at each run object in play
function M.bindTick()
    if St.phase == "FRONTEND" or St.phase == "LOADING" or St.phase == "TRANSIT" then return end
    local r = M._liveRun()
    if not r then return end
    local k = U.key(r)
    if bind.key == k then return end
    local okP, pr = pcall(function() return U.mod("couchprerun").state() end)
    if okP and type(pr) == "table" and pr.open == true then return end     -- the pre-run split: not decided yet
    local fp = M.fpOf(r)
    if not (fp and fp.id ~= nil) then return end
    local okA, on = pcall(function() return U.mod("couch").active() end)
    if not (okA and on == true) then
        -- solo: only the run-start figure is noted (a guest joining later gets it); the guests are never touched, and
        -- the run is looked at again once the couch is on (a guest joins in this world)
        if bind.soloKey ~= k then
            bind.soloKey = k
            loadState()
            if noteStart(fp, ", noted while the couch is off") then save() end
        end
        return
    end
    bind.key = k
    M.bindRun(fp, "phase " .. tostring(St.phase))
end

-- Q11: P1's run-START credits of the run in play (never his wallet now). -> credits, source, the run is at its start
function M.runStartCredits()
    loadState()
    local fp = M.fpOf(activeRun())
    local id = fp and fp.id
    local atStart = fp ~= nil and fp.ch == 0 and fp.dn == 0
    if id ~= nil and type(G.starts) == "table" and G.starts[id] ~= nil then
        return G.starts[id], "noted at the run start", atStart
    end
    if atStart and fp.cr ~= nil then return fp.cr, "the run is at its start", true end
    if id ~= nil then
        for _, c in ipairs(journal().cps) do
            local f = type(c) == "table" and c.fp
            if type(f) == "table" and f.id == id and f.ch == 0 and f.dn == 0 and f.cr ~= nil then
                return f.cr, "the run-start checkpoint", atStart
            end
        end
    end
    return nil, "unknown", atStart
end

-- couchseat's pad memory (FINDING #43 + the 3-4P relaunch): {[ControllerId] = seat} of the last pads seated
function M.padSeatOf(ctrlId)
    loadState()
    local t = type(G.padSeats) == "table" and G.padSeats or nil
    return t and tonumber(t[tonumber(ctrlId) or -1]) or nil
end
function M.padSeats()
    loadState()
    return type(G.padSeats) == "table" and G.padSeats or {}
end
function M.rememberPadSeat(ctrlId, seat)
    local id, s = tonumber(ctrlId), tonumber(seat)
    if not (id and s) then return end
    loadState()
    G.padSeats = type(G.padSeats) == "table" and G.padSeats or {}
    if G.padSeats[id] == s then return end
    for k, v in pairs(G.padSeats) do if v == s and k ~= id then G.padSeats[k] = nil end end    -- one pad per seat
    G.padSeats[id] = s
    save()
end

-- P1's run fingerprint (what a loaded run shows again). Unreadable fields stay nil.
local FP_KEYS = { "id", "seed", "ch", "dn", "rr", "cr", "st" }
function M.fpOf(r)
    if not U.ok(r) then return nil end
    local f = {}
    local function num(v) v = tonumber(v); return v and math.floor(v) or nil end
    pcall(function() f.id = num(r.RunId) end)
    pcall(function() f.seed = num(r.Map.mSeed) end)
    pcall(function() f.cr = num(r.Credits) end)
    pcall(function() f.st = num(r.Strikes) end)
    pcall(function()
        local nodes = r.Map.mNodes
        local ch, dn, rr = 0, 0, nil
        for i = 1, U.arrayCount(nodes) do
            local nd = nodes[i]
            if U.ok(nd) then
                if nd.bHasBeenChosen == true then
                    ch = ch + 1
                    if nd.bHasBeenCompleted ~= true then rr = num(nd.RewardRoundIx) end
                end
                if nd.bHasBeenCompleted == true then dn = dn + 1 end
            end
        end
        f.ch, f.dn, f.rr = ch, dn, rr
    end)
    return f
end
function M.fpStr(f)
    if type(f) ~= "table" then return "?" end
    local t = {}
    for _, k in ipairs(FP_KEYS) do t[#t + 1] = k .. "=" .. tostring(f[k] == nil and "-" or f[k]) end
    return table.concat(t, " ")
end
local fpStr = M.fpStr

-- pure (sim): the checkpoint for a loaded run. -> index or nil, why
function M.pickCheckpoint(cps, fp)
    if type(fp) ~= "table" or (fp.cr == nil and fp.ch == nil and fp.id == nil) then
        return nil, "P1's run unreadable"
    end
    if type(cps) ~= "table" or #cps == 0 then return nil, "no checkpoint journal" end
    local want, other = fpStr(fp), nil
    for i = #cps, 1, -1 do
        local c = cps[i]
        -- couch-fix31: a checkpoint whose guests belong to another run than the one saved (written before run ids
        -- were checked at the save) is never a resume target
        local foreign = type(c) == "table" and type(c.state) == "table" and c.state.runId ~= nil
            and type(c.fp) == "table" and c.fp.id ~= nil and c.state.runId ~= c.fp.id
        if type(c) == "table" and type(c.fp) == "table" and fpStr(c.fp) == want and not foreign then
            if c.runSave ~= false then return i, "exact" end
            other = other or i
        end
    end
    if other then return other, "exact (a save the run clock did not confirm as a run save)" end
    return nil, "no checkpoint matches"
end

local function guestLine(st)
    local t = {}
    local keys = {}
    for k in pairs(type(st) == "table" and type(st.players) == "table" and st.players or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local p = st.players[k]
        local parts = 0
        for _, v in pairs(type(p.owned) == "table" and type(p.owned.part) == "table" and p.owned.part or {}) do
            if v then parts = parts + 1 end
        end
        local who = "P" .. tostring(p.pnum or "?")
        if st.keys == "seat" and type(k) == "number" and k ~= tonumber(p.pnum) then
            who = string.format("%s (seat %d)", who, k)
        end
        t[#t + 1] = string.format("%s %d CR %d part(s)", who, math.floor(tonumber(p.credits) or 0), parts)
    end
    return #t > 0 and table.concat(t, ", ") or "no guest"
end

local function liveRun()
    -- couch.campaignSubsystem: the cached GameInstance subsystem (a FindFirstOf at most every 2 s on a miss)
    local c = nil
    local okM, m = pcall(U.mod, "couch")
    if okM and type(m) == "table" and type(m.campaignSubsystem) == "function" then
        pcall(function() c = m.campaignSubsystem() end)
    else
        c = cs()
    end
    if not U.ok(c) then return nil, nil end
    local r = nil
    pcall(function() r = c.ActiveRun end)
    return U.ok(r) and r or nil, c
end

M._liveRun = liveRun

local function runClock(r)
    local t = nil
    if U.ok(r) then pcall(function() t = tonumber(r:GetTimeSinceLastSaveInSeconds()) end) end
    return t
end

local function p1Finished()
    local done = false
    pcall(function()
        local rec = U.localPlayers()[1].pc.PlayerState.RaceEventComponent
        done = rec.bHasFinishedEvent == true or rec.bHasBeenEliminated == true or rec.bHasVehicleWrecked == true
    end)
    return done
end

-- couch-fix31: G's keys that are no run state (a checkpoint never holds them, a resume keeps the live ones)
local META_KEYS = { "padSeats", "starts", "stash", "meta" }   -- couch-fix35: meta = couchmeta's store (account progress)
M.META_KEYS = META_KEYS
-- RESTORE: the live state becomes checkpoint i's copy (G keeps its table identity)
local function restore(i, why, how)
    local j = journal()
    local c = j.cps[i]
    local dropped = #j.cps - i
    for n = #j.cps, i + 1, -1 do table.remove(j.cps, n) end
    c.pendPay = nil                                   -- an earlier session's world: nothing left to fold in
    local was = guestLine(G)
    local want = plain(c.state) or { players = {} }
    if type(want.players) ~= "table" then want.players = {} end
    want.v = nil
    local cur = plain(G)
    cur.v = nil
    -- couch-fix31: the checkpoint's run is the guests' run (a checkpoint from before run ids: its fingerprint's id)
    if want.runId == nil and type(c.fp) == "table" and c.fp.id ~= nil then want.runId = c.fp.id end
    local wantS, curS = want.sharedUnlocks, cur.sharedUnlocks      -- couch-fix21: meta, not run state (below)
    want.sharedUnlocks, cur.sharedUnlocks = nil, nil
    for _, mk in ipairs(META_KEYS) do want[mk], cur[mk] = nil, nil end
    local wantR, curR = want.runId, cur.runId
    want.runId, cur.runId = nil, nil
    local same = ser(want) == ser(cur) and (curR == nil or curR == wantR)
    want.sharedUnlocks, cur.sharedUnlocks, want.runId = wantS, curS, wantR
    if same then
        if G.runId == nil and wantR ~= nil then G.runId = wantR; save() end
        saveJournal()
        U.log(TAG, "resume (%s): P1's run is at checkpoint #%s (%s, %s): the guests are in step (%s)%s", tostring(why),
            tostring(c.seq), tostring(c.why), how, was, dropped > 0 and string.format("; %d later checkpoint(s) dropped", dropped) or "")
        return false
    end
    -- couch-fix21: a favour unlock is meta (P1's account keeps it whatever run the game reloads): never rolled back
    local shared = G.sharedUnlocks
    local meta = {}                                   -- couch-fix31: pad seats, run-start credits, a stash: not run state
    for _, mk in ipairs(META_KEYS) do meta[mk] = G[mk] end
    for k in pairs(G) do G[k] = nil end
    for k, v in pairs(want) do G[k] = v end
    for _, mk in ipairs(META_KEYS) do G[mk] = meta[mk] end
    if type(shared) == "table" then
        G.sharedUnlocks = type(G.sharedUnlocks) == "table" and G.sharedUnlocks or {}
        for tag, u in pairs(shared) do if G.sharedUnlocks[tag] == nil then G.sharedUnlocks[tag] = u end end
    end
    save()
    saveJournal()
    U.log(TAG, "resume (%s): P1's run is back at checkpoint #%s (%s, saved %s, %s): guests rolled back to it: %s -> %s%s",
        tostring(why), tostring(c.seq), tostring(c.why), tostring(c.at), how, was, guestLine(G),
        dropped > 0 and string.format("; %d later checkpoint(s) dropped", dropped) or "")
    return true
end

-- pure entry (sim + resumeCheck): P1's loaded run fingerprint -> the guests restored? (true = rolled back)
function M.resumeFrom(fp, why)
    loadState()
    local j = journal()
    local i, how = M.pickCheckpoint(j.cps, fp)
    if not i then
        local last = j.cps[#j.cps]
        U.log(TAG, "resume (%s): %s for P1's run [%s]%s: the guests' live state kept (%s)", tostring(why), how, fpStr(fp),
            last and string.format(" (newest checkpoint #%s [%s])", tostring(last.seq), fpStr(last.fp)) or "",
            guestLine(G))
        return false
    end
    return restore(i, why, how)
end

-- once per entry into a run: every new ActiveRun seen before the run is in play is checked (CONTINUE may build the
-- run after the first phase change); the check in an in-play phase ends the entry
local IN_PLAY = { OTHER = true, PRERACE = true, RACING = true, POSTRACE = true }
function M.resumeCheck(why)
    if not resume.pending then return false end
    if St.phase == "FRONTEND" then return false end
    local r = liveRun()
    if not r then return false end
    local k = U.key(r)
    local inPlay = IN_PLAY[St.phase] == true
    if resume.seen[k] then
        if inPlay then resume.pending = false end
        return false
    end
    resume.seen[k] = true
    if inPlay then resume.pending = false end
    return M.resumeFrom(M.fpOf(r), why)
end

-- STAGE: the game is saving now (the save icon's OnSaveStarted, or the run clock fallback)
function M.stage(why)
    if St.phase == "FRONTEND" then return nil end
    local r, sub = liveRun()
    if not r then return nil end
    U.try(TAG, M.bindTick)                            -- couch-fix31: whose run the guests' records are, before the copy
    if resume.pending then M.resumeCheck("a save before the resume check: " .. tostring(why)) end
    loadState()
    if next(G.players) == nil then return nil end
    -- a solo session (another save profile, P1 alone) must not push the couch run's checkpoints out
    if opt("CouchJournalSolo", false) ~= true and #U.localPlayers() < 2 then return nil end
    local fp = M.fpOf(r)
    -- couch-fix31: the guests' records are another run's (P1 plays a run they are not in: solo with a dormant guest,
    -- before the first look bound them): this save is not theirs
    if G.runId ~= nil and fp and fp.id ~= nil and G.runId ~= fp.id then
        U.logEvery("couchrun.foreignsave", 30000, TAG, "a save of P1's run %s: no checkpoint (the guests' records are run %s's)",
            tostring(fp.id), tostring(G.runId))
        return nil
    end
    local cont = nil
    if U.ok(sub) then pcall(function() cont = tonumber(sub:GetContinueRunState()) end) end
    local post = cont == CONT_POST_EVENT
    if cont == nil then post = racing.atMs ~= nil and (St.phase == "POSTRACE" or p1Finished()) end
    local j = journal()
    local now = St.nowMs()
    local last = j.cps[#j.cps]
    if last and last.sess == SESSION and now - (tonumber(last.ms) or -1e12) < 500 and fpStr(last.fp) == fpStr(fp) then
        table.remove(j.cps)                           -- the same save seen twice (two icon instances / hook + clock)
    end
    j.seq = (tonumber(j.seq) or 0) + 1
    local c = { seq = j.seq, at = os.date("%Y-%m-%d %H:%M:%S"), why = tostring(why), fp = fp, cont = cont,
                world = St.worldGen, sess = SESSION, ms = now, post = post or nil,
                pendPay = (post and racing.atMs ~= nil and not racing.paid) or nil, state = plain(G) }
    c.state.v = nil
    for _, mk in ipairs(META_KEYS) do c.state[mk] = nil end
    j.cps[#j.cps + 1] = c
    while #j.cps > jmax() do table.remove(j.cps, 1) end
    saveJournal()
    U.log(TAG, "checkpoint #%d (%s): P1's run [%s] continue state %s%s: %s", c.seq, c.why, fpStr(fp), tostring(cont),
        c.pendPay and " (race end: the guests' payout is folded in when it comes)" or "", guestLine(G))
    return c
end

-- the save finished: success false = the checkpoint goes; the run clock says whether it was the RUN's save
function M.saveEnded(success)
    local j = journal()
    local c = j.cps[#j.cps]
    if not c or c.sess ~= SESSION or c.ended or St.nowMs() - (tonumber(c.ms) or -1e12) > 60000 then return end
    c.ended = true
    if success == false then
        table.remove(j.cps)
        saveJournal()
        U.warn(TAG, "checkpoint #%s dropped: the game reports its save FAILED", tostring(c.seq))
        return
    end
    local t = runClock(liveRun())
    if t ~= nil and c.runSave == nil then c.runSave = t <= 10 end
    saveJournal()
    U.log(TAG, "checkpoint #%s: save ended (success %s, run clock %s s: %s)", tostring(c.seq), tostring(success),
        t and string.format("%.1f", t) or "unreadable",
        c.runSave == true and "the run's save" or (c.runSave == false and "NOT the run's save (meta?)" or "unconfirmed"))
end

-- the journal's same-world checkpoints a race consequence belongs to. payout = only those waiting for this world's
-- payout (pendPay); else the post-event ones. fn(snapshotPlayer, seat) -> changed?
amendRace = function(what, fn, payout)
    local j = journal()
    local hit = {}
    for _, c in ipairs(j.cps) do
        local mine = c.sess == SESSION and c.world == St.worldGen and type(c.state) == "table"
        if mine and ((payout and c.pendPay) or (not payout and c.post)) then
            local n = 0
            for seat, sp in pairs(c.state.players or {}) do
                if type(sp) == "table" and fn(sp, seat) then n = n + 1 end
            end
            if payout then c.pendPay = nil end
            if n > 0 or payout then hit[#hit + 1] = string.format("#%s (%d guest(s))", tostring(c.seq), n) end
        end
    end
    if #hit > 0 then
        saveJournal()
        U.log(TAG, "%s folded into the race-end checkpoint(s) %s", what, table.concat(hit, ", "))
    end
end

function M.sameBet(a, b)
    return type(a) == "table" and type(b) == "table" and a.name == b.name and a.stake == b.stake and a.gen == b.gen
end

local function sameItem(a, b)
    return type(a) == "table" and type(b) == "table" and a.rkind == b.rkind and tostring(a.id) == tostring(b.id)
end

amendClaim = function(ctrlId, item)
    local j = journal()
    local hit = {}
    for _, c in ipairs(j.cps) do
        local sp = type(c.state) == "table" and type(c.state.players) == "table" and c.state.players[seatKey(ctrlId)] or nil
        -- couch-rewards2: a pick of his own flow's round: every checkpoint holding that flow with the stage open
        local inFlow = false
        if type(sp) == "table" and item.fstage and type(sp.flow) == "table" and sp.flow.seed == item.fseed
            and type(sp.flow.stages) == "table" then
            local st = sp.flow.stages[tonumber(item.fstage)]
            inFlow = st ~= nil and not st.collected
        end
        if type(sp) == "table" and (type(sp.offer) == "table" or inFlow) then
            local open = inFlow
            for _, row in ipairs(sp.offer or {}) do if sameItem(row, item) then open = true; break end end
            if open then
                applyClaim(sp, item)
                hit[#hit + 1] = "#" .. tostring(c.seq)
            end
        end
    end
    if #hit > 0 then
        saveJournal()
        U.log(TAG, "P%s's reward %s folded into checkpoint(s) %s (the offer was open when the game saved)",
            tostring(M.player(ctrlId) and M.player(ctrlId).pnum or "?"), tostring(item.name or item.id),
            table.concat(hit, ", "))
    end
end

-- couch-rewards2: his CREDITS / FAULTS stage collected after a checkpoint that holds the same flow (same seed)
amendFlow = function(ctrlId, idx, seed)
    local j = journal()
    local hit = {}
    for _, c in ipairs(j.cps) do
        local sp = type(c.state) == "table" and type(c.state.players) == "table" and c.state.players[seatKey(ctrlId)] or nil
        if type(sp) == "table" and collectStage(sp, idx, seed) then hit[#hit + 1] = "#" .. tostring(c.seq) end
    end
    if #hit > 0 then
        saveJournal()
        U.log(TAG, "P%s's reward stage %d folded into checkpoint(s) %s", tostring(M.player(ctrlId) and
            M.player(ctrlId).pnum or "?"), idx, table.concat(hit, ", "))
    end
end

-- couch-shopstock: a PACK bought before a checkpoint and opened after it. The checkpoint holds the paid pack (credits
-- gone, p.pack with its choices); his pick is folded into every checkpoint holding THAT pack (same seq), so a resume
-- there never offers the paid pack again (a new roll = a free re-pick) nor loses what he took.
amendPack = function(ctrlId, seq, item)
    local j = journal()
    local hit = {}
    for _, c in ipairs(j.cps) do
        local sp = type(c.state) == "table" and type(c.state.players) == "table" and c.state.players[seatKey(ctrlId)] or nil
        if type(sp) == "table" and type(sp.pack) == "table" and sp.pack.seq == seq then
            local offer = sp.offer
            applyClaim(sp, item)
            sp.offer, sp.pack = offer, nil
            hit[#hit + 1] = "#" .. tostring(c.seq)
        end
    end
    if #hit > 0 then
        saveJournal()
        U.log(TAG, "P%s's pack pick %s folded into checkpoint(s) %s (the pack was paid when the game saved)",
            tostring(M.player(ctrlId) and M.player(ctrlId).pnum or "?"), tostring(item.name or item.id),
            table.concat(hit, ", "))
    end
end

-- SAVE REQUEST COUNTER (couch-livefix r2, live 2026-10-16 round 2): the save icon hooks AND the save objects'
-- OnPreSave / OnPostSave hooks registered and NEVER fired: every checkpoint came from the run clock, and the RUN-START
-- save (GriffinRun.0.6.sav at 12:25:35.7) made none. OnPreSave / OnPostSave are BlueprintImplementableEvents (jmap:
-- Event | BlueprintEvent, no Native flag), not native events: on the native CampaignSaveData nothing implements them,
-- the engine's ProcessEvent runs no script and UE4SS's script hook never sees a call. The run saves themselves are
-- native code (CampaignSaveManager has no run-save UFunction, its BP-callable saves are the META's) - there is no
-- UFunction on that path to hook. What the save path DOES leave behind, every time: ULocalPlayerSaveGame's reflected
-- request counters. AsyncSaveGameToSlotForLocalPlayer increments CurrentSaveRequest (+0x48) before anything else and
-- its async end writes the request number into LastSuccessfulSaveRequest (+0x4c) or LastErrorSaveRequest (+0x50).
-- The manager's run save objects (CurrentRunSaveData / CampaignSaveData / ScenarioSaveData) are polled every MAIN
-- tick (three property reads each): a higher CurrentSaveRequest = a run save = the checkpoint (staged now; the run
-- clock's ±1.5 s match then only confirms it), the success / error counter = the save's end. A save object seen for
-- the first time after the first poll that already counts a request (a new run's own object, saved at once) is a
-- save too. FRONTEND: baselines only. cfg.CouchSaveCounter = false: the run clock alone.
local RUN_FIELDS = { "CurrentRunSaveData", "CampaignSaveData", "ScenarioSaveData" }
local cnt = { seen = {}, polls = 0, pend = nil }
function M.counterTick()
    if opt("CouchSaveCounter", true) == false then return false end
    local okC, couch = pcall(U.mod, "couch")
    local csm = okC and type(couch) == "table" and couch.saveManager and couch.saveManager() or nil
    if not csm then return false end
    cnt.polls = cnt.polls + 1
    local done, hit = {}, nil
    for _, f in ipairs(RUN_FIELDS) do
        local o = nil
        pcall(function() o = csm[f] end)
        local k = U.ok(o) and U.key(o) or 0
        if k ~= 0 and not done[k] then
            done[k] = true
            local req, okN, errN = nil, nil, nil
            pcall(function()
                req, okN, errN = tonumber(o.CurrentSaveRequest), tonumber(o.LastSuccessfulSaveRequest),
                    tonumber(o.LastErrorSaveRequest)
            end)
            if req then
                local prev = cnt.seen[k]
                cnt.seen[k] = { req = req }
                if (prev and req > prev.req) or (not prev and cnt.polls > 1 and req > 0) then
                    hit = hit or { k = k, req = req, f = f, new = prev == nil }
                end
                local pd = cnt.pend
                if pd and pd.k == k then
                    if errN and errN >= pd.req then cnt.pend = nil; U.try(TAG, M.onSaveEnded, false)
                    elseif okN and okN >= pd.req then cnt.pend = nil; U.try(TAG, M.onSaveEnded, true) end
                end
            end
        end
    end
    if hit and St.phase ~= "FRONTEND" then
        cnt.pend = { k = hit.k, req = hit.req }
        listen.counterEvents = (listen.counterEvents or 0) + 1
        local now = St.nowMs()
        if now - listen.startAt >= SAVE_EVT_MS then
            listen.startAt = now
            listen.events = listen.events + 1
            U.try(TAG, M.stage, string.format("the game saves (run save request #%d%s)", hit.req,
                hit.new and ", a new save object" or ""))
        end
        return true
    end
    return false
end

local FIRST_SAVE_S = 5      -- a run first seen with its clock this low was saved as it appeared (the run-start save)

-- RUN-START CREDITS (couch-livefix r2, live round 2): P2's chip read 0 on the event map while P1's read 3,600, then
-- the first checkpoint recorded P2 at 3,600 CR. Neither the chip nor the journal was wrong: a guest's starting credits
-- (P1's run starting credits, startTour) were only granted at the run's FIRST GRID (applyBuilds, at the node pick) -
-- until then he really had 0 (his shop before the first race too), and the node-pick checkpoint came 20 ms after the
-- grant. The grant now happens when the run starts: the first look at a new run whose map has no node chosen yet
-- (the paddock right after the loadout), before this tick's save counter stages the run-start checkpoint. Once per
-- guest and run (tourStarted, kept in the checkpoints: a resumed run never pays twice); the first grid stays the
-- fallback (a guest who joins later, a run first seen elsewhere).
local startGrant = { key = nil }
function M.runStartTick()
    if St.phase ~= "OTHER" then return end
    local okA, on = pcall(function() return U.mod("couch").active() end)
    if not (okA and on == true) then return end
    local r = liveRun()
    if not r then return end
    local k = U.key(r)
    if startGrant.key == k then return end
    startGrant.key = k
    local fp = M.fpOf(r)
    if not (fp and fp.ch == 0 and fp.dn == 0) then return end
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if not okJ or type(list) ~= "table" then return end
    local n = 0
    for _, e in ipairs(list) do
        local p = M.ensure(e.ctrlId, e.pnum)
        if not p.tourStarted then
            local ok = pcall(M.startTour, e.ctrlId, e.pnum)
            if ok then n = n + 1 end
        end
    end
    if n > 0 then
        U.log(TAG, "run start [%s]: %d guest(s) start the tour now (starting credits before the first race)",
            M.fpStr(fp), n)
    end
    if F() then U.try(TAG, F().onRunStart, "run start") end      -- #110 the team favours' tour-start tokens
end

-- MAIN tick, every phase (main.lua): the save request counter, the resume check, the run clock fallback (500 ms)
function M.syncTick()
    local now = St.nowMs()
    local okQ, q = pcall(function() return U.mod("couch").isQuiet() end)
    local quiet = okQ and q == true
    if not quiet then
        U.try(TAG, M.bindTick)                        -- couch-fix31: whose run the guests' records are, first
        U.try(TAG, M.runStartTick)                    -- the guests' starting credits BEFORE the run-start checkpoint
        U.try(TAG, M.counterTick)
    end
    if now - poll.at < 500 then return end
    poll.at = now
    if St.phase == "FRONTEND" then poll.t = nil; return end
    if quiet then return end                          -- no UFunction during a world change (couch's quiet window)
    U.try(TAG, M.listenTick)
    local r = liveRun()
    if not r then poll.t = nil; return end
    if resume.pending then U.try(TAG, M.resumeCheck, "phase " .. tostring(St.phase)) end
    local t = runClock(r)
    if t == nil then
        if not poll.missLogged then
            poll.missLogged = true
            U.log(TAG, "run clock (GetTimeSinceLastSaveInSeconds) unreadable: checkpoints come from the save icon hook only")
        end
        return
    end
    local prev = poll.t
    poll.t = t
    -- (couch-livefix r2) a run object seen for the FIRST time (live: the new run's ActiveRun appears together with its
    -- run-start save, 0.6 s before the first look) with its clock near 0: that save is a checkpoint too
    local rk = U.key(r)
    local firstSight = poll.runKey ~= rk
    poll.runKey = rk
    if firstSight and t <= FIRST_SAVE_S then
        local j = journal()
        local c = j.cps[#j.cps]
        local savedAt = now - t * 1000
        if c and c.sess == SESSION and math.abs((tonumber(c.ms) or -1e12) - savedAt) <= 1500 then
            if c.runSave ~= true then c.runSave = true; saveJournal() end
            return
        end
        U.try(TAG, M.stage, "run clock: the run's first save (the run appeared with it)")
        local n = j.cps[#j.cps]
        if n and n ~= c then n.runSave = true; saveJournal() end
        return
    end
    if prev == nil or t >= prev - 0.25 then return end
    -- the run saved since the last poll, about t s ago
    local j = journal()
    local c = j.cps[#j.cps]
    local savedAt = now - t * 1000
    if c and c.sess == SESSION and math.abs((tonumber(c.ms) or -1e12) - savedAt) <= 1500 then
        if c.runSave ~= true then c.runSave = true; saveJournal() end
        return
    end
    U.try(TAG, M.stage, "run clock: a run save the save icon hook did not report")
    local n = j.cps[#j.cps]
    if n and n ~= c then n.runSave = true; saveJournal() end
end

-- sim only: the process dies (a crash): every in-memory state goes, the files stay
function M._forget()
    G, J = nil, nil
    resume.pending, resume.seen = true, {}
    poll.at, poll.t, poll.runKey = -1e12, nil, nil
    cnt.seen, cnt.polls, cnt.pend = {}, 0, nil
    startGrant.key = nil
    bind.key, bind.soloKey = nil, nil
    racing.atMs, racing.ms, racing.paid = nil, nil, false
    listen.w, listen.world, listen.tryAt, listen.tries, listen.startAt, listen.endAt = nil, nil, -1e12, 0, -1e12, -1e12
    newSession()
end
M._listen = listen

-- the mod's own save icon instance (see SAVE LISTENER): -> true when one is up in this world
function M.listenTick()
    if opt("CouchSaveListener", true) == false then return false end
    if not LISTEN_PHASES[St.phase] then return false end
    if listen.world == St.worldGen and U.ok(listen.w) then return true end
    local now = St.nowMs()
    if listen.world ~= St.worldGen then listen.w, listen.world, listen.tries = nil, St.worldGen, 0 end
    if listen.tries >= 3 or now - listen.tryAt < 3000 then return false end
    local okQ, q = pcall(function() return U.mod("couch").isQuiet() end)
    if okQ and q == true then return false end
    listen.tryAt, listen.tries = now, listen.tries + 1
    local p1 = U.p1()
    if not U.ok(p1) then return false end
    local cls = U.class(SAVE_ICON)
    if not U.ok(cls) then
        U.logOnce("couchrun.listen.cls", TAG, "save listener: class %s not found: checkpoints from the game's own icon / the run clock", SAVE_ICON)
        return false
    end
    local w = nil
    local ok, err = pcall(function()
        w = U.WBL():Create(p1, cls, p1)
        if not U.ok(w) then error("Create returned no widget") end
        w:SetVisibility(1)                            -- Collapsed: never drawn (its Anim_In only animates opacity)
        w:AddToViewport(-1000)                        -- Construct: binds OnSaveStarted / OnSaveEnded to the manager
    end)
    if not ok or not U.ok(w) then
        U.warn(TAG, "save listener not created (try %d): %s", listen.tries, tostring(err))
        return false
    end
    listen.w = w
    listen.made = listen.made + 1
    U.log(TAG, "save listener up (WBP_SaveGame_Icn bound to CampaignSaveManager OnSaveStartedEvent / OnSaveEndedEvent, phase %s)",
        tostring(St.phase))
    return true
end

-- the manager's OnSaveStartedEvent (any bound icon instance): one per broadcast
function M.onSaveStarted(ctx)
    local now = St.nowMs()
    if now - listen.startAt < SAVE_EVT_MS then return false end
    listen.startAt = now
    listen.events = listen.events + 1
    local okC, couch = pcall(U.mod, "couch")
    if okC and type(couch) == "table" and type(couch.saveOwnerSync) == "function" then
        U.try(TAG, couch.saveOwnerSync, "the game saves")
        local okU, id, slot = pcall(couch.saveUserNow)
        if okU and id == 0 then
            U.log(TAG, "the game saves: %s for pad id 0 (P1's account folder)", tostring(slot))
        elseif okU and id ~= nil then
            U.warn(TAG, "the game saves: %s for pad id %s: NOT P1's account (the account-less root slot)", tostring(slot), tostring(id))
        end
    end
    local mine = U.ok(ctx) and U.ok(listen.w) and U.key(ctx) == U.key(listen.w)
    U.try(TAG, M.stage, mine and "the game saves (save manager event)" or "the game saves (save icon)")
    return true
end

-- SAVE OBJECT HOOKS (couch-livefix i, live 2026-10-16): "save listener up" in every world, yet EVERY checkpoint still
-- came from the run clock ("a run save the save icon hook did not report"): the icon's bound OnSaveStarted /
-- OnSaveEnded never fired (the decoded binding is right: Construct += CampaignSaveManager.OnSaveStartedEvent /
-- OnSaveEndedEvent; either the manager does not broadcast for its autosaves or UE4SS's script hook does not see a
-- BP custom event called by a delegate broadcast - not provable offline). The manager has no run-save UFunction to
-- hook (SaveMetaSaveAsync only), but every save it writes is a ULocalPlayerSaveGame whose
-- AsyncSaveGameToSlotForLocalPlayer calls the BlueprintNativeEvents OnPreSave (before the user index - the folder -
-- is read) and OnPostSave(bSuccess) (at the async end): native UFunctions, hooked here on
-- /Script/Engine.LocalPlayerSaveGame. OnPreSave of the RUN save object (the manager's CurrentRunSaveData /
-- CampaignSaveData / ScenarioSaveData) = the checkpoint; any save object's OnPreSave first puts its owner on the
-- account user (couch.saveOwnerSync, BUG 1). The icon events stay (the first of the two within SAVE_EVT_MS wins),
-- the run clock stays the fallback.
-- (couch-livefix r2) LIVE round 2: these never fired either. OnPreSave / OnPostSave are BlueprintImplementableEvents
-- (jmap flags Event | BlueprintEvent, no Native), not native functions: with no Blueprint body on CampaignSaveData no
-- script runs and UE4SS's script hook sees nothing. Kept (harmless, a later build may implement them); the save
-- request counters (M.counterTick, above) are the checkpoint event now.
local PRE_SAVE = "/Script/Engine.LocalPlayerSaveGame:OnPreSave"
local POST_SAVE = "/Script/Engine.LocalPlayerSaveGame:OnPostSave"

-- the save object's role for the manager: "run" | "meta" | nil (not one of the manager's)
local function saveKind(obj)
    if not U.ok(obj) then return nil end
    local okC, couch = pcall(U.mod, "couch")
    local csm = okC and type(couch) == "table" and couch.saveManager and couch.saveManager() or nil
    if not csm then return nil end
    local k = U.key(obj)
    for _, f in ipairs(RUN_FIELDS) do
        local o = nil
        pcall(function() o = csm[f] end)
        if U.ok(o) and U.key(o) == k then return "run" end
    end
    local m = nil
    pcall(function() m = csm.CampaignMetaSaveData end)
    if U.ok(m) and U.key(m) == k then return "meta" end
    return nil
end
M._saveKind = saveKind

function M.onPreSave(obj)
    local kind = saveKind(obj)
    if not kind then return false end
    listen.objEvents = (listen.objEvents or 0) + 1
    local okC, couch = pcall(U.mod, "couch")
    if okC and type(couch) == "table" and type(couch.onSaveObject) == "function" then
        U.try(TAG, couch.onSaveObject, obj, kind)
    elseif okC and type(couch) == "table" and type(couch.saveOwnerSync) == "function" then
        U.try(TAG, couch.saveOwnerSync, "the game saves")
    end
    -- the folder this save goes to (its OwningPlayer's pad id NOW: the engine reads it right after OnPreSave)
    local id = nil
    pcall(function() id = tonumber(obj.OwningPlayer.ControllerId) end)
    if id == 0 then
        U.dbg(TAG, "the game saves: the %s save for pad id 0 (P1's account folder)", kind)
    elseif id ~= nil then
        U.warn(TAG, "the game saves: the %s save for pad id %s: NOT P1's account (the account-less root slot)", kind, tostring(id))
    end
    if kind ~= "run" then return true end
    local now = St.nowMs()
    if now - listen.startAt < SAVE_EVT_MS then return true end          -- the icon event of this save came first
    listen.startAt = now
    listen.events = listen.events + 1
    U.try(TAG, M.stage, "the game saves (save object OnPreSave)")
    listen.preRun = now
    return true
end

function M.onPostSave(obj, success)
    if saveKind(obj) ~= "run" then return false end
    return M.onSaveEnded(success)
end

function M.onSaveEnded(success)
    local now = St.nowMs()
    if now - listen.endAt < SAVE_EVT_MS then return false end
    listen.endAt = now
    U.try(TAG, M.saveEnded, success ~= false)
    return true
end
M._resume = resume

function M.init()
    St.on("phase", TAG, function(new, old)
        if new == "RACING" and racing.atMs == nil then racing.atMs = St.nowMs() end
        if old == "RACING" and new ~= "RACING" and racing.atMs then racing.ms = St.nowMs() - racing.atMs end
        if new == "FRONTEND" then resume.pending, resume.seen = true, {} end
        if new ~= "FRONTEND" and resume.pending then U.try(TAG, M.resumeCheck, "phase " .. tostring(new)) end
        if new == "POSTRACE" then
            local okC, c = pcall(function() return U.mod("couch").active() end)
            if okC and c == true then
                local paid, why = M.raceRan(racing.ms, opt("CouchMinRaceMs", 1000))
                -- couch-fix32 (audit 12 #16): racing.paid was set by onRaceEnd and never read: a POSTRACE -> other
                -- phase -> POSTRACE flip in one race world paid every guest again and rebuilt his reward flow
                if racing.paid then
                    U.warn(TAG, "POSTRACE again in this race world: the guests were paid already (no second payout)")
                elseif paid then U.try(TAG, M.onRaceEnd)
                else U.log(TAG, "no guest payout at POSTRACE: %s", why) end
            end
        end
    end)
    St.on("world", TAG, function() racing.atMs, racing.ms, racing.paid = nil, nil, false end)
    -- the checkpoint event: the save icon's handlers of CampaignSaveManager OnSaveStartedEvent / OnSaveEndedEvent
    -- (any instance: the game's own icon when one is constructed, the mod's listener otherwise - M.listenTick)
    U.hook(SAVE_ICON .. ":OnSaveStarted", {
        post = function(ctx) U.try(TAG, M.onSaveStarted, U.unwrap(ctx)) end,
    }, TAG)
    U.hook(SAVE_ICON .. ":OnSaveEnded", {
        post = function(_, success)
            local s = U.unwrap(success)
            U.try(TAG, M.onSaveEnded, s)
        end,
    }, TAG)
    if opt("CouchSaveObjectHooks", true) ~= false then
        U.hook(PRE_SAVE, { pre = function(ctx) U.try(TAG, M.onPreSave, U.unwrap(ctx)) end }, TAG)
        U.hook(POST_SAVE, { post = function(ctx, success) U.try(TAG, M.onPostSave, U.unwrap(ctx), U.unwrap(success)) end }, TAG)
    end
end

return M
