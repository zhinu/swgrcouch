-- couchfavours.lua: COUCH CAMPAIGN - FAVOURS PER PLAYER (#110, Jules 2026-10-18, playtest notes 2026-10-17 #110).
-- Every guest picks his own 3 favours on his loadout (couchprerun #101: any favour P1's account unlocked, stored per
-- SEAT in couch-run.txt: couchrun p.favours). The game applies favours to P1's CampaignRun only (RacerFavour
-- PassiveRule -> tunesets / one-time effects on P1's run, P1's car, P1's reward rounds), so a guest's favour acts here,
-- on HIS couch run (couchrun: build, credits, shop, packs, reward flow) and on HIS car; P1 keeps every native effect of
-- his own picks. Two rules on top: P1's native effects never reach a guest (the places where a guest's economy reads
-- P1's run are corrected below), and a guest's favour never changes P1 - except the TEAM favours, which act on the one
-- shared run (League Tokens are the team's lives).
--
-- DECODED (cue4cli json Gameplay/Campaign/Loadouts/Favours + Tuneset, CL381121; wiki "Run build 5 Favors"):
--   PER PLAYER (his picks, his results)
--   Mechanic_B   Gadgeteer       UnlockAdditionalAffixSlots 1/2/2; III TNS CampaignShopTuneConfig.NumAffixesAvailable +2
--   Mechanic_A   Mad Genius      TNS RaceTuneConfig.TotalCrashAllowance +1/+2/+2; III ChanceMechanicBonusStrike curve
--                                (0,100): after a knock-out, a League Token at the next tour's start (-> the team's)
--   QuietStrength Brutal Calm    TakedownRequirement 5/4/3 + CoreEvent -> AddUpgradeRewardRound Resilience +1
--   Mercenary    Underhanded U.  CountdownEnded -> ApplyTunesetToMercenaryTarget TNS_Favour_Mercenary_N
--                                (VehicleConditionConfig MalfunctionDuration / MalfunctionTimerMultiplier x3/x5/x10)
--   Mentor_A     Feet First      RaceFinish (core, Standard/HighRisk, IsFinite, 1/2/3 races) -> AddRewardRound Ability
--   Mentor_B     Old Greats      PlaneTestEventCompleted -> RepairFaultyAffix 50/75/100 %
--   Star         Fan Club        RacePosition <= 3, core, Standard/HighRisk -> 20 % AddRewardRound VehicleUpgrade
--                                OverrideUpgradeLevel 1/2/3
--   Thrall       Silent Defiance RacePosition <= 12 (no DNF), core -> 25/50/50 % AddRewardRound (part pack,
--                                MinimumRarityForOneItem Low); III TNS bIncreaseGaurenteedAffixRarityByOne +
--                                AffixGenerationAdditional{Rare,Epic,Legendary}Weight x1.25
--   Sponsor_Broker Deeper Pockets NumberOfEndOfEventRewards -1, AffixGenerationAdditional*Weight +3/+5/+7,
--                                UpgradeLevelBoostWeights[1] +0.25/+0.34/+0.54 (= a 20/25/35 % +1 level boost)
--   Sponsor_Pirate Bloody Bounty NumberOfEndOfEventRewards +1/+2/+2; III NumAbilitiesAvailable /
--                                NumVehiclePartsAvailable +2 (the shop's packs)
--   Sponsor_Hutt Team Vranki     RaceFinish + core + Standard/HighRisk -> credits PerCrashAllowanceLeft 100/150/200
--   Protege      Family Legacy   TakedownRivals / TakedownAntagonist -> 200/400/600 and 400/800/1200 credits each
--   (and the 4 of NOTE 6, couchrun: Veteran, Nomad, InnerHonour, Ghost)
--   TEAM (the one shared run)
--   ElegantProfessional Second Chance  AddStrikeProtector ProtectUntil PlanetNum 2/3/4 (1 token)
--   Rager        Racer Roulette  WonSidebet vs DA_Racer_Rager x6/5/4 in a tour -> StrikesBalance -1 (a token)
--   MIXED
--   Promoter     Clandestine Aid TNS CampaignTuneConfig.BonusStrikes +1 (team token) + CarryoverCreditsFlatBonus
--                                0/1000/2000 (his credits); Act III: Darius Pax is gone (restricted)
--   ExoticVendor Preferred Cust. TNS BonusChanceForBlackMarketNodes +170 (the map: P1's run, the team's) +
--                                BlackMarketTuneConfig.AffixRepairDiscountPercentage 0/25/50 (his repairs)
-- A team favour counts when ANY player holds it (best rank); when P1 holds it natively the game already applies it to
-- the run and the mod adds nothing twice. Token gains go through the game's own mutation path
-- (CampaignRun:RequestStrikesBalanceChange(-1, Reason) = Rager's own StrikesBalancePassiveEffect -1).
--
-- CLOSEST EQUIVALENTS (said in the #110 report): Mad Genius = his car's StartingVehicleHealth / VehicleHealth set to the
-- crash allowance without P1's native Mad Genius plus his own (the race tune is one per race); Underhanded Upperhand =
-- the favour's own tuneset on HIS challenge target's car (VehiclePawn:RequestApplyTuneSet, the native effect's
-- target kind), never on a racer P1's own Mercenary already hits; Second Chance = his strike protection is taken in
-- couchrules' strike ledger (a kept strike of a couch race becomes "protected", NumProtected +1) - a token lost outside
-- a couch race (a backer check-in) is not covered; Preferred Customer's MAP frequency stays P1's pick (the map is the
-- game's, generated from P1's run tune), a guest's pick gives his repair discount only.
-- Pure helpers (no UObject) are tested by tools/test_couchfavours.lua; the game glue is pcall-guarded.
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "couchfavours"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function CR() return U.mod("couchrun") end

M.DEF = {
    Veteran = { name = "VICTORIOUS LOSER", scope = "player" },
    Nomad = { name = "HIGH ROLLER", scope = "player" },
    InnerHonour = { name = "SMUGGLER'S HOPE", scope = "player" },
    Ghost = { name = "UNASSUMING PRODIGY", scope = "player" },
    Mechanic_B = { name = "GADGETEER", scope = "player", slots = { 1, 2, 2 }, shop = { 0, 0, 2 } },
    Mechanic_A = { name = "MAD GENIUS", scope = "player", crashes = { 1, 2, 2 }, koToken = { 0, 0, 100 } },
    QuietStrength = { name = "BRUTAL CALM", scope = "player", takedowns = { 5, 4, 3 } },
    Mercenary = { name = "UNDERHANDED UPPERHAND", scope = "player", mult = { 3, 5, 10 } },
    Mentor_A = { name = "FEET FIRST", scope = "player", events = { 1, 2, 3 } },
    Mentor_B = { name = "OLD GREATS", scope = "player", chance = { 50, 75, 100 } },
    Star = { name = "FAN CLUB", scope = "player", chance = { 20, 20, 20 }, levels = { 1, 2, 3 } },
    Thrall = { name = "SILENT DEFIANCE", scope = "player", chance = { 25, 50, 50 }, rarityUp = { 0, 0, 1 } },
    Sponsor_Broker = { name = "DEEPER POCKETS", scope = "player", cards = { -1, -1, -1 }, addW = { 3, 5, 7 },
                       boost = { 0.25, 0.34, 0.54 } },
    Sponsor_Pirate = { name = "BLOODY BOUNTY", scope = "player", cards = { 1, 2, 2 }, packs = { 0, 0, 2 } },
    Sponsor_Hutt = { name = "TEAM VRANKI", scope = "player", perCrash = { 100, 150, 200 } },
    Protege = { name = "FAMILY LEGACY", scope = "player", rival = { 200, 400, 600 }, kestar = { 400, 800, 1200 } },
    ElegantProfessional = { name = "SECOND CHANCE", scope = "team", planets = { 2, 3, 4 } },
    Rager = { name = "RACER ROULETTE", scope = "team", bets = { 6, 5, 4 } },
    Promoter = { name = "CLANDESTINE AID", scope = "mixed", credits = { 0, 1000, 2000 } },
    ExoticVendor = { name = "PREFERRED CUSTOMER", scope = "mixed", repair = { 0, 25, 50 } },
}
M.RESILIENCE = 2                                         -- EVehiclePartSlot::Resilience
M.BIDDY = "DA_Racer_Rager"                               -- Racer Roulette's RacerToTrackSideBetsAgainst
M.MERC_TNS = "/Game/Griffin/Gameplay/Campaign/Loadouts/Favours/Tuneset/TNS_Favour_Mercenary_%d.TNS_Favour_Mercenary_%d"
-- the node kinds the favours' AllowedNodeTypes name (StandardEvent, HighRiskEvent) and the core campaign races
-- (CoreEventRequirement: no field / podracer test, no rival challenge)
local NODE = { standard = true, highrisk = true }
local CORE = { standard = true, highrisk = true, knockout = true, champion = true, mystery = true }
M.NODE, M.CORE = NODE, CORE

---------------------------------------------------------------------------------------------------- pure: ranks
-- "Favour_Mechanic_B_2" -> "Mechanic_B", 2
function M.base(id)
    local b, r = tostring(id or ""):match("^Favour_(.+)_(%d+)$")
    if not b then return nil, 0 end
    return b, tonumber(r) or 1
end
-- the best rank of a favour base in a list of favour ids (0 = not held)
function M.rankIn(list, base)
    local best = 0
    if type(list) ~= "table" then return 0 end
    for _, id in pairs(list) do
        local b, r = M.base(id)
        if b == base and r > best then best = r end
    end
    return best
end
function M.rank(p, base) return M.rankIn(p and p.favours, base) end
-- the value of a favour field at a rank (nil when not held)
function M.v(base, key, r)
    local d = M.DEF[base]
    local t = d and d[key]
    r = math.floor(tonumber(r) or 0)
    if r <= 0 or t == nil then return nil end
    if type(t) == "table" then return t[math.min(#t, r)] end
    return t
end
-- a favour a guest's own run applies (per-player kinds; a team-only kind acts on the shared run)
function M.perPlayer(id)
    local b = M.base(id)
    local d = b and M.DEF[b]
    return d ~= nil and d.scope ~= "team"
end
-- a favour whose effect is the team's only (shown as the team's on a guest's backer page)
function M.teamOnly(id)
    local b = M.base(id)
    local d = b and M.DEF[b]
    return d == nil or d.scope == "team"
end

---------------------------------------------------------------------------------------------------- P1's native picks
local function campaignRun()
    local c = nil
    local okM, m = pcall(U.mod, "couch")
    if okM and type(m) == "table" and type(m.campaignSubsystem) == "function" then
        pcall(function() c = m.campaignSubsystem() end)
    end
    if not U.ok(c) then
        local ok, f = pcall(FindFirstOf, "CampaignSubsystem")
        c = (ok and U.ok(f)) and f or nil
    end
    if not c then return nil end
    local r = nil
    pcall(function() r = c.ActiveRun end)
    return U.ok(r) and r or nil
end
M._campaignRun = campaignRun

local p1c = { key = nil, at = -1e12, ids = {}, all = {} }
-- P1's equipped favours (CampaignRun.favours: RacerFavour objects) -> ids; cached 2 s per run object. p1c.all = every
-- favour name on his run (the hidden MYST_* ones of his mystery deals too)
function M.p1Favours()
    local r = campaignRun()
    local k = r and U.key(r) or 0
    local now = St.nowMs()
    if p1c.key == k and now - p1c.at < 2000 then return p1c.ids end
    local ids, all = {}, {}
    if r then
        pcall(function()
            for _, f in ipairs(U.arrayToTable(r.favours)) do
                local n = U.ok(f) and U.objName(f) or nil
                if type(n) == "string" then
                    all[n] = true
                    if M.base(n) then ids[#ids + 1] = n end
                end
            end
        end)
    end
    p1c.key, p1c.at, p1c.ids, p1c.all = k, now, ids, all
    return ids
end
-- couch-fix48: a favour was just added to P1's run (a guest's team effect): the next read is fresh
function M.p1Dirty() p1c.at = -1e12 end
-- does P1's run carry that favour (any name, e.g. "Favour_MYST_LessEventRewardChoices")?
function M.p1Has(name)
    M.p1Favours()
    return p1c.all[name] == true
end

-- couch-fix32 (audit 12 issue 9): a guest's card count from P1's native round (pure): P1's round count carries P1's own
-- Bloody Bounty / Deeper Pockets (p1Delta) and P1's MYST "fewer reward choices" deal (p1Fewer): those come off FIRST,
-- the native 2..4 clamp is on that base, then his own favours and his own deal. (The clamp ran before P1's delta came
-- off: P1's Bloody Bounty II on a 5-card round = 4 - 2 = 2 for a guest without favours instead of 3.)
function M.offerCards(p1Round, p1Delta, p1Fewer, hisDelta, hisFewer)
    local n = math.floor(tonumber(p1Round) or 3)
    if n <= 0 then n = 3 end
    local base = n - (tonumber(p1Delta) or 0) + (tonumber(p1Fewer) or 0)
    base = math.max(2, math.min(4, base))
    return math.max(1, base + (tonumber(hisDelta) or 0) - math.floor(tonumber(hisFewer) or 0))
end
function M.p1Rank(base) return M.rankIn(M.p1Favours(), base) end
function M._p1Forget() p1c.key = nil end

-- the team's rank of a favour: the best of P1's native pick and every guest's of this run -> best, p1, guests
function M.teamRank(base)
    local p1 = M.p1Rank(base)
    local g = 0
    local okP, players = pcall(function() return CR().players() end)
    if okP and type(players) == "table" then
        for _, p in pairs(players) do g = math.max(g, M.rank(p, base)) end
    end
    return math.max(p1, g), p1, g
end

---------------------------------------------------------------------------------------------------- per player: build
-- his part slots: the native base (UnlockedAffixSlots 4, cfg.CouchGuestPartSlots) + Gadgeteer; a guest who already had
-- more parts installed than that when #110 came keeps those slots for the run (p.slotsKept: nothing he owns is lost)
function M.partSlots(p)
    local base = math.max(1, math.floor(tonumber(opt("CouchGuestPartSlots", 4)) or 4))
    local n = base + (M.v("Mechanic_B", "slots", M.rank(p, "Mechanic_B")) or 0)
    n = math.max(n, math.floor(tonumber(p and p.slotsKept) or 0))
    return math.max(1, math.min(10, n))
end

-- his build's part list cut / padded to his part slots. A part in a slot past them leaves the car and stays OWNED (the
-- garage swap / shop keeps it). The first fit of a record from before #110 keeps his installed parts (p.slotsKept).
-- -> number of parts taken off
function M.fitParts(p, why)
    local lo = p and p.lo
    if type(lo) ~= "table" then return 0 end
    lo.parts = type(lo.parts) == "table" and lo.parts or {}
    if p.slotsV ~= 1 then
        p.slotsV = 1
        local have = 0
        for _, id in pairs(lo.parts) do if id then have = have + 1 end end
        local n0 = M.partSlots(p)
        if have > n0 then
            p.slotsKept = have
            U.log(TAG, "P%s: %d part(s) installed before the per-player slots (#110): %d slot(s) kept for this run",
                tostring(p.pnum), have, have)
        end
    end
    local n = M.partSlots(p)
    local top = 0
    for k in pairs(lo.parts) do if math.type(k) == "integer" and k > top then top = k end end
    local off = 0
    -- a part past his slots: moved into a free slot first, else off the car (owned)
    for i = n + 1, top do
        local id = lo.parts[i]
        lo.parts[i] = nil
        if id then
            local put = false
            for j = 1, n do
                if not lo.parts[j] then lo.parts[j] = id; put = true; break end
            end
            if not put then
                p.owned = type(p.owned) == "table" and p.owned or {}
                p.owned.part = type(p.owned.part) == "table" and p.owned.part or {}
                p.owned.part[id] = true
                off = off + 1
                U.log(TAG, "P%s: part %s off his car (%d part slot(s), %s); kept owned", tostring(p.pnum), tostring(id), n,
                    tostring(why))
            end
        end
    end
    for i = 1, n do if lo.parts[i] == nil then lo.parts[i] = false end end
    return off
end

-- Hibi's shop shelf (n = the base stock) with Gadgeteer III's +2 parts
function M.shopParts(p, n) return n + (M.v("Mechanic_B", "shop", M.rank(p, "Mechanic_B")) or 0) end
-- the choices of a shop pack (n = the base 3) with Bloody Bounty III's +2
function M.packChoices(p, n) return n + (M.v("Sponsor_Pirate", "packs", M.rank(p, "Sponsor_Pirate")) or 0) end
-- reward cards: Bloody Bounty +1/+2, Deeper Pockets -1 (NumberOfEndOfEventRewards) for a favour list
function M.cardDelta(list)
    return (M.v("Sponsor_Pirate", "cards", M.rankIn(list, "Sponsor_Pirate")) or 0)
        + (M.v("Sponsor_Broker", "cards", M.rankIn(list, "Sponsor_Broker")) or 0)
end

-- his reward flow's tune (couchrun.flowCtx): card count, Deeper Pockets' rarity weights and +1 level boost, Silent
-- Defiance III's rarity floor. c = the flow ctx (tune, rarityW). -> notes (log)
function M.flowTune(p, c)
    local notes = {}
    local tn = c.tune or {}
    c.tune = tn
    local d = M.cardDelta(p and p.favours)
    if d ~= 0 then
        tn.cards = math.max(1, math.floor(tonumber(tn.cards) or 3) + d)
        notes[#notes + 1] = string.format("cards %+d", d)
    end
    local br, tr = M.rank(p, "Sponsor_Broker"), M.rank(p, "Thrall")
    if br > 0 then
        local add = M.v("Sponsor_Broker", "addW", br) * ((M.v("Thrall", "rarityUp", tr) or 0) > 0 and 1.25 or 1)
        local w = {}
        for i, x in ipairs(c.rarityW or { 60, 20, 10, 5 }) do w[i] = tonumber(x) or 0 end
        for i = 2, 4 do w[i] = (w[i] or 0) + add end
        c.rarityW = w
        local b = M.v("Sponsor_Broker", "boost", br)
        tn.boost = b / (1 + b)
        notes[#notes + 1] = string.format("rarity +%g, +1 level %d%%", add, math.floor(tn.boost * 100 + 0.5))
    end
    if (M.v("Thrall", "rarityUp", tr) or 0) > 0 then
        tn.partUp = 1
        tn.guarantee = math.min(3, math.floor(tonumber(tn.guarantee) or 2) + 1)
        notes[#notes + 1] = "part rarity +1"
    end
    return notes
end

---------------------------------------------------------------------------------------------------- per player: results
-- the event's facts for his favours (couchrun.onRaceEnd): info = {kind, pos, wrecked, sitOut, beat, td = {n, rival,
-- kestar}, crashesLeft}. finished = he completed the event (not wrecked / sat out / DNF)
local function finished(info)
    return not info.wrecked and not info.sitOut and (tonumber(info.pos) or 99) >= 1 and (tonumber(info.pos) or 99) < 99
end
M.finished = finished

-- Feet First's count: his completed Standard / High Risk events of this run (p.fav.core). Call once per event.
function M.countEvent(p, info)
    p.fav = type(p.fav) == "table" and p.fav or {}
    if NODE[info.kind] and finished(info) then p.fav.core = (tonumber(p.fav.core) or 0) + 1 end
    return tonumber(p.fav.core) or 0
end

-- his bonus reward rounds of this event (pure; rnd = a couchrewards stream) -> specs { {kind, reason, ...} }, notes
--   Feet First   kind "ab"     (an ABILITY PACK) after each of his first 1/2/3 completed Standard / High Risk events
--   Fan Club     kind "stat"   top 3 of a Standard / High Risk event, 20 %: an UPGRADE PACK of +1/+2/+3 levels
--   Silent Def.  kind "part"   any core event completed, 25/50/50 %: a PART PACK (one part at least Rare)
--   Brutal Calm  kind "fixed"  a core event completed with 5/4/3 of HIS takedowns: +1 RESILIENCE
function M.bonusRounds(p, info, rnd)
    local out, notes = {}, {}
    if not finished(info) then return out, notes end
    local pos = math.floor(tonumber(info.pos) or 99)
    local ff = M.rank(p, "Mentor_A")
    local core = tonumber(p.fav and p.fav.core) or 0
    if ff > 0 and NODE[info.kind] and core >= 1 and core <= M.v("Mentor_A", "events", ff) then
        out[#out + 1] = { kind = "ab", reason = "Feet First" }
        notes[#notes + 1] = string.format("FEET FIRST: ABILITY PACK (event %d of %d)", core, M.v("Mentor_A", "events", ff))
    end
    local fc = M.rank(p, "Star")
    if fc > 0 and NODE[info.kind] and pos <= 3 then
        local x = rnd.next() * 100
        if x < M.v("Star", "chance", fc) then
            out[#out + 1] = { kind = "stat", levels = M.v("Star", "levels", fc), reason = "Fan Club" }
            notes[#notes + 1] = string.format("FAN CLUB: +%d UPGRADE PACK", M.v("Star", "levels", fc))
        end
    end
    local sd = M.rank(p, "Thrall")
    if sd > 0 and CORE[info.kind] and pos <= 12 then
        local x = rnd.next() * 100
        if x < M.v("Thrall", "chance", sd) then
            out[#out + 1] = { kind = "part", floorOne = 1, reason = "Silent Defiance" }
            notes[#notes + 1] = "SILENT DEFIANCE: PART PACK"
        end
    end
    local bc = M.rank(p, "QuietStrength")
    local td = type(info.td) == "table" and math.floor(tonumber(info.td.n) or 0) or 0
    if bc > 0 and CORE[info.kind] and td >= M.v("QuietStrength", "takedowns", bc) then
        out[#out + 1] = { kind = "fixed", stat = M.RESILIENCE, lv = 1, reason = "Brutal Calm" }
        notes[#notes + 1] = string.format("BRUTAL CALM: %d TAKEDOWNS, +1 RESILIENCE", td)
    end
    return out, notes
end

-- his credit rows of this event (pure) -> rows { {reason, delta} }
--   Team Vranki   a completed Standard / High Risk event: each crash he had left x 100/150/200 ("Unused Crash")
--   Family Legacy each of HIS takedowns on the rival x 200/400/600, on Kestar Bool x 400/800/1200
function M.creditExtras(p, info)
    local rows = {}
    local hr = M.rank(p, "Sponsor_Hutt")
    local left = math.floor(tonumber(info.crashesLeft) or 0)
    if hr > 0 and NODE[info.kind] and finished(info) and left > 0 then
        rows[#rows + 1] = { reason = "Unused Crash", delta = left * M.v("Sponsor_Hutt", "perCrash", hr), n = left }
    end
    local fl = M.rank(p, "Protege")
    local td = type(info.td) == "table" and info.td or {}
    if fl > 0 then
        local r, k = math.floor(tonumber(td.rival) or 0), math.floor(tonumber(td.kestar) or 0)
        if r > 0 then rows[#rows + 1] = { reason = "Took down Rival", delta = r * M.v("Protege", "rival", fl), n = r } end
        if k > 0 then rows[#rows + 1] = { reason = "Took down Kestar", delta = k * M.v("Protege", "kestar", fl), n = k } end
    end
    return rows
end

-- Old Greats: after HIS passed podracer test, 50/75/100 % to repair one of his faulty parts (pure: faulty = the ids
-- couchrun.repairRows lists as faulty, rnd = a stream) -> the part id to repair, or nil
function M.oldGreats(p, info, faulty, rnd)
    local r = M.rank(p, "Mentor_B")
    if r <= 0 or info.kind ~= "planesprint" or info.beat ~= true or info.sitOut or info.wrecked then return nil end
    if type(faulty) ~= "table" or #faulty == 0 then return nil end
    if rnd.next() * 100 >= M.v("Mentor_B", "chance", r) then return nil end
    return faulty[rnd.int(#faulty)]
end

-- Clandestine Aid's starting credits: P1's run start credits carry P1's own CarryoverCreditsFlatBonus (never a guest's),
-- his own rank adds his. -> his grant
function M.startCredits(p1Credits, p, act)
    local p1r = M.p1Rank("Promoter")
    local g = math.max(0, math.floor(tonumber(p1Credits) or 0) - (M.v("Promoter", "credits", p1r) or 0))
    if tonumber(act) ~= 3 then g = g + (M.v("Promoter", "credits", M.rank(p, "Promoter")) or 0) end
    return g
end

-- Preferred Customer: his repair price from the vendor's (nativeCost carries P1's own discount) -> price
function M.repairPrice(p, nativeCost, fallback)
    local n = tonumber(nativeCost)
    local base = (n and n > 0) and n or (tonumber(fallback) or 2000)
    if n and n > 0 then
        local p1d = M.v("ExoticVendor", "repair", M.p1Rank("ExoticVendor")) or 0
        if p1d > 0 and p1d < 100 then base = n * 100 / (100 - p1d) end
    end
    local d = M.v("ExoticVendor", "repair", M.rank(p, "ExoticVendor")) or 0
    return math.floor(base * (100 - d) / 100 + 0.5)
end

-- Mad Genius (pure): his race's crash allowance = HIS car's own (StartingVehicleHealth, the race tune the game gave his
-- car) without P1's native Mad Genius when his car carries it, plus his own Mad Genius. couch-fix32 (audit 12 issue 9):
-- it was P1's allowance minus P1's Mad Genius plus his = P1's style trait / backer penalty / difficulty leaked onto
-- every guest and his own allowance was thrown away. His car carries P1's Mad Genius when its allowance is above P1's
-- without it (the one race tune of the shared race); a car below that never got it. Nobody holding Mad Genius = his
-- car untouched. -> target (nil = leave his car as it is)
-- couch-fix36 (Q4, Jules: the Hutt's "crashes allowed -2" is THAT player's car only): p1Extra / hisExtra are NET
-- deltas - Mad Genius minus a Hutt penalty (couchpenalty.lua) - so P1's Hutt tune comes off a guest's car like P1's
-- Mad Genius does (a car below P1's allowance without it carries it), and his own Hutt takes 2 off his own car.
function M.crashTarget(guestStart, p1Start, p1Extra, hisExtra)
    guestStart, p1Start = tonumber(guestStart), tonumber(p1Start)
    p1Extra, hisExtra = tonumber(p1Extra) or 0, tonumber(hisExtra) or 0
    if not guestStart or guestStart <= 0 then return nil end
    local unknown = not p1Start or p1Start <= 0
    local carries = (p1Extra > 0 and (unknown or guestStart > p1Start - p1Extra))
        or (p1Extra < 0 and (unknown or guestStart < p1Start - p1Extra))
    if hisExtra == 0 and not carries then return nil end
    local base = guestStart - (carries and p1Extra or 0)
    return math.max(1, base + hisExtra)
end

---------------------------------------------------------------------------------------------------- team state
-- couchrun keeps it with the guests' run (G.team, reset with P1's run): {key, promoter, mech, rr = {n, p1, granted},
-- sc, failed}; G.pending survives a new run (Mad Genius III's knock-out token)
local function team() local ok, t = pcall(function() return CR().teamState() end); return ok and t or nil end
local function saveTeam() pcall(function() CR().saveTeam() end) end

-- the team gains a League Token (the game's own path: Rager's StrikesBalancePassiveEffect -1) -> ok
function M.grantToken(r, why)
    if not U.ok(r) then return false end
    local s0, m0 = nil, nil
    pcall(function() s0 = tonumber(r.Strikes) end)
    pcall(function() m0 = tonumber(r:GetMaxStrikes()) end)
    local ok, err = pcall(function() r:RequestStrikesBalanceChange(-1, U.ftext(why)) end)
    local s1, m1 = nil, nil
    pcall(function() s1 = tonumber(r.Strikes) end)
    pcall(function() m1 = tonumber(r:GetMaxStrikes()) end)
    U.log(TAG, "TEAM TOKEN (%s): %s - strikes %s -> %s, max %s -> %s", tostring(why), ok and "granted" or ("FAILED: "
        .. tostring(err)), tostring(s0), tostring(s1), tostring(m0), tostring(m1))
    return ok
end

-- P1's run started (couchrun.runStartTick, the first grid as the fallback): Clandestine Aid's team token from a
-- guest's pick (P1's own is native), Mad Genius III's knock-out token of the previous run
function M.onRunStart(why)
    local r = campaignRun()
    local t = team()
    if not (r and t) or t.started then return end
    t.started = true
    -- the tour's START only: a run first seen with events done (a file from before #110, a resume) gets no late token
    local dn = nil
    pcall(function() dn = tonumber(CR().fpOf(r).dn) end)
    if dn and dn > 0 then
        t.promoter, t.mechDone = true, true
        saveTeam()
        U.log(TAG, "run already under way (%d event(s) done): no tour-start team token", dn)
        return
    end
    local act = nil
    pcall(function() act = tonumber(U.objName(r.Tour):match("Tour_?(%d)")) end)
    if not t.promoter then
        t.promoter = true
        local _, p1, g = M.teamRank("Promoter")
        if g > 0 and p1 == 0 and act ~= 3 then
            M.grantToken(r, "Clandestine Aid")
            t.promoter = "team"
        elseif g > 0 then
            U.log(TAG, "Clandestine Aid (a guest's, rank %d): %s", g, act == 3 and "Act III - Darius Pax is gone, no token"
                or ("P1's own (rank " .. p1 .. ") gives the team its token"))
        end
    end
    local pend = t.pendingMech
    if pend and not t.mechDone then
        t.mechDone = true
        if M.p1Rank("Mechanic_A") >= 3 then
            U.log(TAG, "Mad Genius III knock-out token: P1's own favour gives it natively")
        else
            M.grantToken(r, "Mad Genius")
        end
    end
    saveTeam()
    U.log(TAG, "run start (%s): team favours checked", tostring(why))
end

-- P1's run failed (knocked out): a guest with Mad Genius III -> a token at the next run's start (couchrun keeps the
-- flag over the reset)
function M.onRunFailed()
    local t = team()
    if not t or t.failed then return end
    t.failed = true
    local g = 0
    local okP, players = pcall(function() return CR().players() end)
    if okP and type(players) == "table" then for _, p in pairs(players) do g = math.max(g, M.rank(p, "Mechanic_A")) end end
    local chance = M.v("Mechanic_A", "koToken", g) or 0
    if chance > 0 and M.p1Rank("Mechanic_A") < 3 and math.random() * 100 < chance then
        pcall(function() CR().setPending("mech", true) end)
        U.log(TAG, "knocked out with a guest's Mad Genius III: a League Token at the next tour's start")
    end
    saveTeam()
end

-- Racer Roulette: a settled side bet of any player (who = 1 for P1, else his seat) -> true when a token was granted
function M.onBet(who, won, racer, name)
    if not won then return false end
    local biddy = racer == M.BIDDY or tostring(name or ""):upper():find("BIDDY", 1, true) ~= nil
    if not biddy then return false end
    local t = team()
    if not t then return false end
    t.rr = type(t.rr) == "table" and t.rr or { n = 0, p1 = 0 }
    t.rr.n = (t.rr.n or 0) + 1
    if who == 1 then t.rr.p1 = (t.rr.p1 or 0) + 1 end
    local best, p1 = M.teamRank("Rager")
    local granted = false
    -- couch-fix32 (audit 12 issue 9): ONE token a tour. When P1 holds Racer Roulette the game's own counter (P1's won
    -- bets, StrikesBalance -1 at his 6/5/4) gives the tour's token on P1's run whatever the mod does: a mod token at the
    -- team count first, then P1's native one = two tokens. P1's pick = the native token is the team's (as for every team
    -- favour P1 holds: the mod adds nothing twice); the team count (every player's bets) grants only when P1 does not
    -- hold it
    if best > 0 and not t.rr.granted then
        local need = M.v("Rager", "bets", best)
        if p1 > 0 then
            if t.rr.p1 >= M.v("Rager", "bets", p1) then
                t.rr.granted = "native"
                U.log(TAG, "Racer Roulette: P1's own %d won Biddy Blas bets earned the tour's token natively", t.rr.p1)
            elseif t.rr.n >= need and not t.rr.saidNative then
                t.rr.saidNative = true
                U.log(TAG, "Racer Roulette: team count %d reached %d, but P1 holds it (rank %d): the tour's token is "
                    .. "P1's native one (%d of his own won bets) - no second token", t.rr.n, need, p1, M.v("Rager", "bets", p1))
            end
        elseif t.rr.n >= need then
            t.rr.granted = "team"
            granted = M.grantToken(campaignRun(), "Won Sidebet")
        end
    end
    U.log(TAG, "Racer Roulette: %s won vs Biddy Blas - team count %d (P1 %d)%s", who == 1 and "P1" or ("seat " .. tostring(who)),
        t.rr.n, t.rr.p1 or 0, best > 0 and string.format(", need %d", M.v("Rager", "bets", best)) or " (nobody holds it)")
    saveTeam()
    return granted
end

-- Second Chance (couchrules' strike ledger, a kept strike of a couch race): -> true = protect one token now.
-- entries = the new StrikeChangeDisplayDetails {delta, prot}; planet = the run's planet (1-based)
function M.secondChance(entries, planet, r)
    local best, p1, g = M.teamRank("ElegantProfessional")
    if best <= 0 then return false end
    local t = team()
    if not t or t.sc then return false end
    for _, e in ipairs(entries or {}) do
        if (tonumber(e.prot) or 0) > 0 then
            t.sc = "native"
            saveTeam()
            U.log(TAG, "Second Chance: the run's own protector absorbed a strike (P1's favour): the team's is used")
            return false
        end
    end
    if p1 > 0 and U.ok(r) then
        local active = false
        pcall(function() active = r:HasActiveStrikeProtector() == true end)
        if active then return false end
    end
    local upto = M.v("ElegantProfessional", "planets", best)
    if (tonumber(planet) or 99) > upto then return false end
    t.sc = "team"
    saveTeam()
    U.log(TAG, "Second Chance (team rank %d: P1 %d, guests %d): a League Token protected on planet %s", best, p1, g,
        tostring(planet))
    return true
end

---------------------------------------------------------------------------------------------------- the race
-- W: this race world's per-guest state; TD: takedowns per instigator PlayerState key
local W = { gen = nil, crash = {}, merc = {}, tries = 0 }
local TD = { gen = nil, by = {} }
local function fresh()
    if W.gen ~= St.worldGen then
        W.gen, W.crash, W.merc, W.tries, W.preload, W.racing, W.idle = St.worldGen, {}, {}, 0, nil, 0, nil
        W.planet = nil                                 -- couch-fix36: the Hutt planet, read once per race world
    end
    if TD.gen ~= St.worldGen then TD.gen, TD.by = St.worldGen, {} end
end

-- a takedown, already deduped per pair (couchbacker.onTakedown: the ONE VehicleGameplayComponent:OnVehicleTakedown
-- hook of the mod - one call per bound component - forwards every takedown here; inst / vic = PlayerStates)
function M.bookTakedown(inst, vic)
    if St.phase ~= "RACING" then return end
    fresh()
    if not U.ok(inst) then return end
    local ik, vk = U.key(inst), U.ok(vic) and U.key(vic) or 0
    if ik == vk then return end
    local c = TD.by[ik] or { n = 0, rival = 0, kestar = 0 }
    TD.by[ik] = c
    c.n = c.n + 1
    if U.ok(vic) then
        local rv, ks = false, false
        pcall(function() rv = vic.bIsRival == true end)
        pcall(function() ks = vic.bIsAntagonist == true end)
        if rv then c.rival = c.rival + 1 end
        if ks then c.kestar = c.kestar + 1 end
    end
end
-- his takedowns in this race world -> {n, rival, kestar}
function M.takedownsOf(ps)
    fresh()
    if not U.ok(ps) then return { n = 0, rival = 0, kestar = 0 } end
    local c = TD.by[U.key(ps)] or {}
    return { n = c.n or 0, rival = c.rival or 0, kestar = c.kestar or 0 }
end

local function guests()
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    return (ok and type(list) == "table") and list or {}
end
local function recOf(pc)
    local rec = nil
    pcall(function() rec = pc.PlayerState.RaceEventComponent end)
    return U.ok(rec) and rec or nil
end
local function num(o, k)
    local ok, v = pcall(U.getField, o, k)
    return ok and tonumber(v) or nil
end

-- his crashes left (Team Vranki): health 1 = the next crash wrecks -> VehicleHealth - 1; nil when health is off
function M.crashesLeft(pc)
    local rec = recOf(pc)
    if not rec then return nil end
    local use = nil
    pcall(function() use = rec:ShouldUseHealth() end)
    if use == false then return nil end
    local hp = num(rec, "VehicleHealth")
    if not hp or hp <= 0 then return nil end
    return math.max(0, math.floor(hp) - 1)
end

-- Mad Genius: a guest's crash allowance = his car's own, without P1's native Mad Genius, plus his own (crashTarget)
-- couch-fix36 (Q4): the Hutt penalties (couchpenalty): P1's native one (Favour_Penalty_Sponsor01 on his run) and his own
local function hutt() local ok, P = pcall(U.mod, "couchpenalty"); return (ok and type(P) == "table") and P or nil end
local function crashTick(p1rec)
    local PEN = hutt()
    local p1Hutt = (PEN and M.p1Has(PEN.HUTT_FAVOUR)) and PEN.HUTT_CRASHES or 0
    -- the run's planet only for a guest holding a Hutt penalty record, once per race world (nodeInfo walks the map's
    -- nodes: couch-racegc's steady-race budget)
    local function planetOnce()
        if W.planet == nil then
            W.planet = 1
            pcall(function() W.planet = CR().nodeInfo() end)
        end
        return W.planet
    end
    local p1Extra = (M.v("Mechanic_A", "crashes", M.p1Rank("Mechanic_A")) or 0) - p1Hutt
    local p1Start = p1rec and num(p1rec, "StartingVehicleHealth") or nil
    for _, e in ipairs(guests()) do
        local w = W.crash[e.ctrlId]
        if not (w and w.done) then
            local p = CR().player(e.ctrlId)
            local rec = recOf(e.pc)
            local use = nil
            if rec then pcall(function() use = rec:ShouldUseHealth() end) end
            local start = rec and num(rec, "StartingVehicleHealth") or nil
            -- no health this race (read once the race runs: the PRERACE build may not be final)
            if rec and use == false and St.phase == "RACING" then W.crash[e.ctrlId] = { done = true } end
            if p and rec and use ~= false and start and start > 0 then
                local pen = type(p.backer) == "table" and p.backer.penalty or nil
                local hisHutt = (PEN and type(pen) == "table" and pen.kind == "hutt") and PEN.huttCrashes(p, planetOnce()) or 0
                local his = (M.v("Mechanic_A", "crashes", M.rank(p, "Mechanic_A")) or 0) - hisHutt
                -- P1's allowance is only needed to see whether his car carries P1's Mad Genius: read when P1's car has
                -- one; a race without it (P1 not racing) after 40 ticks
                if p1Extra == 0 or (p1Start and p1Start > 0) or W.tries > 40 then
                    local target = M.crashTarget(start, p1Start, p1Extra, his)
                    w = { done = true, target = target, native = start }
                    W.crash[e.ctrlId] = w
                    if target and target ~= start then
                        local d = target - start
                        local okS = pcall(function() rec.StartingVehicleHealth = target end)
                        local okH = pcall(function() rec:Server_ChangeVehicleHealthBy(d) end)
                        U.log(TAG, "P%d crash allowance %d -> %d (his own %d, P1's Mad Genius / Hutt %+d off, his Mad "
                            .. "Genius / Hutt %+d; P1's %s%s%s)%s%s", e.pnum, start, target, start, start + his - target, his,
                            tostring(p1Start), p1Hutt > 0 and ", P1's Hutt -" .. p1Hutt or "",
                            hisHutt > 0 and ", HIS Hutt -" .. hisHutt or "",
                            okS and "" or " START WRITE FAILED", okH and "" or " HEALTH CALL FAILED")
                    else
                        U.log(TAG, "P%d crash allowance %d kept (his own; P1's %s, P1's Mad Genius %d, his %d)", e.pnum,
                            start, tostring(p1Start), p1Extra, his)
                    end
                end
            end
        elseif w.target and (w.again or 0) < 3 then
            -- the race start reset his allowance to the race tune's (ResetToFullHealthAtRaceStart): set it again
            local rec = recOf(e.pc)
            local start = rec and num(rec, "StartingVehicleHealth") or nil
            if start and start == w.native and start ~= w.target then
                w.again = (w.again or 0) + 1
                pcall(function() rec.StartingVehicleHealth = w.target end)
                pcall(function() rec:Server_ChangeVehicleHealthBy(w.target - start) end)
                U.log(TAG, "P%d crash allowance reset by the race to %d: %d again (%d)", e.pnum, start, w.target, w.again)
            end
        end
    end
end

-- Underhanded Upperhand: the favour's own tuneset on HIS challenge target's car at the countdown's end
local function mercTick()
    local okB, B = pcall(U.mod, "couchbets")
    local st = okB and type(B) == "table" and type(B.state) == "function" and B.state() or nil
    local targets = st and st.targets or {}
    local p1bet = st and st.p1Bet or nil
    local p1r = M.p1Rank("Mercenary")
    for _, e in ipairs(guests()) do
        if not W.merc[e.ctrlId] then
            local p = CR().player(e.ctrlId)
            local r = M.rank(p, "Mercenary")
            if r <= 0 then
                W.merc[e.ctrlId] = "none"
            else
                local tps = targets[e.ctrlId]
                local bet = p and p.bet
                if not (U.ok(tps) and bet) then
                    W.merc[e.ctrlId] = "no challenge"
                elseif p1r > 0 and type(p1bet) == "table" and p1bet.gen == St.worldGen and p1bet.name == bet.name then
                    W.merc[e.ctrlId] = "P1's"
                    U.log(TAG, "P%d Underhanded Upperhand %d: %s is P1's challenge too (P1's own favour hits him)", e.pnum,
                        r, tostring(bet.name))
                else
                    local pawn = nil
                    pcall(function() pawn = tps.PawnPrivate end)
                    if U.ok(pawn) then
                        local tns = U.obj(string.format(M.MERC_TNS, r, r))
                        local ok = false
                        if U.ok(tns) then ok = pcall(function() pawn:RequestApplyTuneSet(tns, 1) end) end
                        W.merc[e.ctrlId] = ok and "applied" or "failed"
                        U.log(TAG, "P%d Underhanded Upperhand %d: System Malfunction x%d on %s's car (%s)", e.pnum, r,
                            M.v("Mercenary", "mult", r), tostring(bet.name), ok and "tuneset applied"
                            or (U.ok(tns) and "RequestApplyTuneSet failed" or "tuneset not loaded"))
                    end
                end
            end
        end
    end
end

-- MAIN race tick (main.lua): PRERACE / RACING of a couch campaign race
function M.raceTick()
    if St.phase ~= "PRERACE" and St.phase ~= "RACING" then return end
    fresh()
    -- couch-racegc: nothing left to do this race (every guest's allowance set + re-checked, his challenge target done)
    if W.idle or W.tries > 200 then return end
    local okC, on = pcall(function() return U.mod("couch").active() end)
    if not (okC and on == true) then return end
    W.tries = W.tries + 1
    local lp = U.localPlayers()
    local p1rec = lp[1] and U.ok(lp[1].pc) and recOf(lp[1].pc) or nil
    U.try(TAG, crashTick, p1rec)
    if St.phase == "RACING" then
        U.try(TAG, mercTick)
        W.racing = (W.racing or 0) + 1
        if W.racing >= 12 then
            local open = false
            for _, e in ipairs(guests()) do
                if not (W.crash[e.ctrlId] and W.crash[e.ctrlId].done) or not W.merc[e.ctrlId] then open = true end
            end
            if not open then W.idle = true end
        end
    elseif not W.preload then
        -- PRERACE: the Mercenary tunesets loaded before the countdown ends (no LoadAsset while racing)
        W.preload = true
        for _, e in ipairs(guests()) do
            local r = M.rank(CR().player(e.ctrlId), "Mercenary")
            if r > 0 then pcall(U.obj, string.format(M.MERC_TNS, r, r)) end
        end
    end
end

-- MAIN tick in the paddock: P1's run failed (knocked out) -> Mad Genius III's token for the next tour
function M.runTick()
    if St.phase ~= "OTHER" and St.phase ~= "POSTRACE" then return end
    local okC, on = pcall(function() return U.mod("couch").active() end)
    if not (okC and on == true) then return end
    local r = campaignRun()
    if not r then return end
    local failed = false
    pcall(function() failed = r:IsFailed() == true end)
    if failed then U.try(TAG, M.onRunFailed) end
end

function M.status()
    local n = 0
    for _ in pairs(TD.by) do n = n + 1 end
    return string.format("couchfavours: P1 %s; takedown instigators %d", table.concat(M.p1Favours(), ","), n)
end

function M.init()
    -- (no hook of its own: couchbacker's OnVehicleTakedown hook forwards each takedown to M.bookTakedown)
    St.on("world", TAG, function() W.gen = nil; TD.gen = nil; p1c.key = nil end)
end

return M
