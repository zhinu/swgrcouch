-- couchbacker.lua: PER-PLAYER BACKERS (couch-fix21; playtest notes 2026-10-17 #90 DECIDED by Jules 2026-10-18 ~09:58
-- UTC, also #2 and #78): P1 and every guest have their OWN backer contract. Each player picks his own backer at the
-- contract screen (his own half, the game's own CHOOSE A BACKER CONTRACT look: couchbackerui.lua), his contract's
-- progress comes from HIS OWN race (his ramjet seconds, his overtakes, his takedowns...), every backer moment is split
-- (offer, BACKER INFO, the planet's check-in = the contract completion screen, its rewards) and a backer favour
-- unlocked by ANY player at the end of the run is unlocked for ALL players (shared upward: couch = earn more, faster).
-- P1 keeps the game's own backer from end to end; this module is the guests' side.
--
-- HOW THE GAME COUNTS (static, SWGR-Win64-Shipping.exe of the hf2 install, capstone; JMAP Griffin-5.7.4-381121; asset
-- decodes work/decoded-campaign/.../Sponsors and work/decoded-backer21 - cue4cli --script + kismet2txt):
--   * SponsorContract (a PassiveConfig, SPON_Contract_S<n>_C<m>): one PassiveRule whose Requirements say WHAT counts
--     (TimeInActiveRamjet, TimeSpendPerforming(Airborne / Speed / Drafting / Afterburner / RacePosition), Overtake,
--     Takedown, ActivateAbility, HitTargetsWithAbility, PreFlightCheckCompleted, VehicleLanding, Malfunction,
--     VehicleModifier, RamjetState) and a SponsorContractStatPassiveEffect (statDelta) that adds to the contract.
--   * The effect lands in CampaignRun 0x1430d3d94 (ps, delta, notify): only while the racer's PlayerRaceEventComponent
--     is not finished (+0xcc) / wrecked (+0xcf) / eliminated (+0xd0) and the run's current node is a StandardEvent or
--     HighRiskEvent (Activity & 0xfe == 2) not yet completed; it adds the delta to the CURRENT PLANET's
--     CampaignPlanetInstance.SponsorContractProgress (+0xa0) capped at 2 x SponsorContractTarget (+0x98: "Contract 200%
--     Complete"), and only when ps == run.playerRacer's PlayerState also to that racer's
--     PlayerRaceEventComponent.SponsorContractProgress (+0x128, this race's count: the credits row) and
--     TrackedSponsorContractProgressToNotifyPlayerAbout (+0x130, the in-race feed).
--     => the game's contract is P1's ONLY, and the planet sum is written BEFORE the player check: a contract passive
--     given to a guest's PlayerState would add HIS actions to P1's planet progress. So a guest's contract is never
--     handed to the game: his actions are counted here (TRACKER below) from his own car / PlayerState, by the same rules.
--   * Targets: InitialTarget on the act's first planet, PlanetTargets[PlanetIndex] on the next ones (SponsorContract CDO
--     InitialTarget = 10 where an asset leaves it out). Credits per action: CampaignEconomy.Sponsors.SponsorN.ContractM
--     (5..125 CR, also RolledSponsorOptionVM.CreditsPerAction on the offer), paid per race for the race's whole units
--     (CreditsBreakdownActionDescription, "{NumActions}") up to the cap.
--   * The planet's check-in (WBP_SponsorCheckIn = the contract completion screen, then WBP_SponsorCheckinBonus): form
--     mood (finish positions), contract mood (progress / target: <= 0.49 Displeased, >= 0.99 Pleased, else Neutral:
--     CAM_SponsorConfig MaxNormContractProgressForFail / MinNormContractProgressForExcellent), overall mood -> the
--     check-in reward CheckinRewards_Bad / _Ok / _Excellent = 50 / 1000 / 2000 CR (+10 / 50 / 100 kit points: P1's
--     meta profile, no guest counterpart).
--   * The backer's favour (SponsorDef.RewardFavour, Favour_Sponsor_<Broker|Hutt|Pirate>_1) unlocks with TrackedUnlock
--     GameplaySponsorStats.RunsWithOkOrBetterRating >= 1 ("Reach Derven Acos with a Satisfactory Rating from the
--     <backer>"): tags Unlock.Cam.Favours.SponsorB (Broker) / SponsorA (Hutt) / SponsorC (Pirate).
-- WHAT IS AN APPROXIMATION ([L], live check): the form mood's points (CAM_SponsorConfig's EventPointsConfigs are not in
-- the decode), the overall mood (native formula not decoded), the run rating (mean of the planets), the sampled goals'
-- thresholds (the native requirement configs' internals: speed scale, a "jump", a "special corner", an ability HIT,
-- a malfunction TRIGGERED by him) - each one says how it is read in GOALS below.
--
-- STORE (couch-run.txt, per seat, couchrun's record p): p.backer = { sponsor = "CAM_Sponsor02", contract =
-- "SPON_Contract_S2_C1", cpa, migrated, startPaid, planets = { [planet] = { contract, progress, target, pos = {...},
-- races, checked, form, cmood, omood, cr } }, rated, rating, unlocked }. G.sharedUnlocks[tag] = { favour, seat, sponsor }
-- (couchrun.sharedUnlocks: the favours the guests unlocked; the pre-run favour pickers offer the union of P1's account
-- unlocks and these). MIGRATION: a guest of a run in progress without a backer gets P1's current backer as his own,
-- progress 0 (ensure).
local U = require("util")
local St = require("state")
local cfg = require("config")

local M = {}
local TAG = "couchbacker"

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function CR() return U.mod("couchrun") end

M.DIR = "/Game/Griffin/Gameplay/Campaign/Sponsors/"
M.FAV_DIR = "/Game/Griffin/Gameplay/Campaign/Loadouts/Favours/"

---------------------------------------------------------------------------------------------------- data
-- SponsorDef (CAM_Sponsor0N): the game's own names, RewardFavour, its unlock tag (CAM_TrackedUnlocks_Favours), the
-- starting credits (CampaignEconomy.StartingCredits.SponsorN)
M.SPONSORS = {
    CAM_Sponsor01 = { n = 1, name = "The Broker", favour = "Favour_Sponsor_Broker_1", favourName = "Deeper Pockets",
                      tag = "Unlock.Cam.Favours.SponsorB", start = 2000 },
    CAM_Sponsor02 = { n = 2, name = "The Hutt", favour = "Favour_Sponsor_Hutt_1", favourName = "Team Vranki",
                      tag = "Unlock.Cam.Favours.SponsorA", start = 2000 },
    CAM_Sponsor03 = { n = 3, name = "The Pirate", favour = "Favour_Sponsor_Pirate_1", favourName = "Bloody Bounty",
                      tag = "Unlock.Cam.Favours.SponsorC", start = 2000 },
}

-- the 18 SponsorContracts (decoded assets): goal = the tracker's rule (GOALS), init = InitialTarget, targets =
-- PlanetTargets by PlanetIndex 1..4, cpa = credits per action, units, text = SummaryHeading, line =
-- CreditsBreakdownActionDescription
local function C(sponsor, goal, init, targets, cpa, units, text, line)
    return { sponsor = sponsor, goal = goal, init = init, targets = targets, cpa = cpa, units = units, text = text,
             line = line }
end
local TIMES = "{NumActions}|plural(one=time,other=times)"
M.CONTRACTS = {
    SPON_Contract_S1_C1 = C("CAM_Sponsor01", "airborne", 40, { 45, 50, 55, 60 }, 25, "s", "Spend time airborne.",
        "Spent {NumActions}s airborne"),
    SPON_Contract_S1_C2 = C("CAM_Sponsor01", "abilityhit", 12, { 14, 16, 18, 20 }, 65, "", "Hit opponents with Abilities.",
        "Hit opponents with Abilities {NumActions} " .. TIMES),
    SPON_Contract_S1_C3 = C("CAM_Sponsor01", "highspeed", 30, { 32, 34, 36, 38 }, 35, "s",
        "Spend time at exceptionally high speeds.", "Spent {NumActions}s at an exceptionally high speed"),
    SPON_Contract_S1_C4 = C("CAM_Sponsor01", "takedown", 6, { 7, 8, 9, 10 }, 125, "", "Achieve Takedowns.",
        "Achieved {NumActions} {NumActions}|plural(one=Takedown,other=Takedowns)"),
    SPON_Contract_S1_C5 = C("CAM_Sponsor01", "slipstream", 32, { 33, 34, 35, 36 }, 35, "", "Slipstream past opponents.",
        "Slipstreamed past opponents {NumActions} " .. TIMES),
    SPON_Contract_S1_C6 = C("CAM_Sponsor01", "overtake2", 16, { 18, 20, 22, 24 }, 65, "", "Overtake 2 opponents within 2s.",
        "Overtook 2 opponents within 2s {NumActions} " .. TIMES),
    SPON_Contract_S2_C1 = C("CAM_Sponsor02", "ramjet", 200, { 225, 250, 275, 300 }, 5, "s", "Spend time using Ramjet.",
        "Spent {NumActions}s using Ramjet"),
    SPON_Contract_S2_C2 = C("CAM_Sponsor02", "overtake", 60, { 65, 70, 75, 80 }, 25, "", "Overtake opponents.",
        "Overtook opponents {NumActions} " .. TIMES),
    SPON_Contract_S2_C3 = C("CAM_Sponsor02", "abilityuse", 8, { 10, 12, 14, 16 }, 85, "", "Activate Abilities.",
        "Activated an Ability {NumActions} " .. TIMES),
    SPON_Contract_S2_C4 = C("CAM_Sponsor02", "preflight", 4, { 6, 8, 9, 10 }, 125, "", "Complete Pre-Race Checks.",
        "Completed {NumActions} Pre-Race {NumActions}|plural(one=Check,other=Checks)"),
    SPON_Contract_S2_C5 = C("CAM_Sponsor02", "jump", 12, { 13, 14, 15, 16 }, 125, "", "Perform jumps.",
        "Performed {NumActions} {NumActions}|plural(one=jump,other=jumps)"),
    SPON_Contract_S2_C6 = C("CAM_Sponsor02", "first", 150, { 175, 200, 225, 250 }, 10, "s", "Spend time in first place.",
        "Spent {NumActions}s in first place"),
    SPON_Contract_S3_C1 = C("CAM_Sponsor03", "afterburner", 150, { 175, 200, 225, 250 }, 5, "s",
        "Spend time using Afterburner.", "Spent {NumActions}s using Afterburner"),
    SPON_Contract_S3_C2 = C("CAM_Sponsor03", "malfunction", 10, { 15, 20, 22, 24 }, 50, "",
        "Trigger opponents' System Malfunction.", "Triggered opponents' System Malfunction {NumActions} " .. TIMES),
    SPON_Contract_S3_C3 = C("CAM_Sponsor03", "last", 40, { 45, 50, 55, 60 }, 35, "s", "Spend time in last place.",
        "Spent {NumActions}s in last place"),
    SPON_Contract_S3_C4 = C("CAM_Sponsor03", "drafting", 200, { 205, 210, 215, 220 }, 5, "s", "Spend time Slipstreaming.",
        "Spent {NumActions}s Slipstreaming"),
    SPON_Contract_S3_C5 = C("CAM_Sponsor03", "maneuver", 24, { 27, 30, 33, 36 }, 35, "", "Perform Advanced Maneuvers.",
        "Performed {NumActions} Special {NumActions}|plural(one=Corner,other=Corners)"),
    SPON_Contract_S3_C6 = C("CAM_Sponsor03", "redline", 10, { 12, 14, 16, 18 }, 85, "", "Redline.",
        "Redlined {NumActions} " .. TIMES),
}

-- ESponsorMood
M.MOOD = { Displeased = 0, Neutral = 1, Pleased = 2 }
M.MOOD_NAME = { [0] = "DISPLEASED", [1] = "SATISFIED", [2] = "PLEASED" }
-- CAM_SponsorConfig
M.FAIL_NORM, M.EXCELLENT_NORM = 0.49, 0.99
M.CHECKIN_CR = { [0] = 50, [1] = 1000, [2] = 2000 }
M.CHECKIN_KP = { [0] = 10, [1] = 50, [2] = 100 }          -- CheckinRewards_*.KitPointsAwarded (the "tuning" figure)
-- SponsorDef.PenaltyFavour (a DISPLEASED overall rating): note the decoded cross-wiring - the Hutt's is
-- Favour_Penalty_Sponsor01 (TNS: TotalCrashAllowance -2), the Pirate's Favour_Penalty_Sponsor02 (TNS:
-- SponsorTakesCreditsFromEndOfEventRewardsPercentage +40), the Broker's Favour_Penalty_Sponsor03 (all race events of
-- the planet are Eliminators). For a guest: the Pirate's 40% cut is HIS (his end-of-event credits of the next planet,
-- couchrun.onRaceEnd); couch-fix36 (Q4, couchpenalty.lua): the Hutt's -2 is HIS car's on the next planet
-- (couchfavours.crashTick), the Broker's Eliminators are the shared run's next steps (CouchBrokerPenalty "both") or his
-- own eliminator payout rule ("owner"). An unhappy backer never costs a League Token (the game takes none; couch-fix41).
M.PENALTY = {
    CAM_Sponsor01 = { favour = "Favour_Penalty_Sponsor03", text = "All race events this planet are Eliminators", runWide = true },
    CAM_Sponsor02 = { favour = "Favour_Penalty_Sponsor01", text = "Crashes allowed reduced by 2", runWide = true },
    CAM_Sponsor03 = { favour = "Favour_Penalty_Sponsor02", text = "Backer takes 40% of earned credits this planet", cut = 40 },
}
M.PENALTY_DIR = "/Game/Griffin/Gameplay/Campaign/Sponsors/Penalties/"
function M.penaltyPath(id) return M.PENALTY_DIR .. id .. "." .. id end
M.CAP = 2.0                                   -- "Contract 200% Complete"
M.CONTRACT_KINDS = { standard = true, highrisk = true }      -- Activity StandardEvent / HighRiskEvent

function M.sponsorPath(id) return M.DIR .. id .. "." .. id end
function M.contractPath(id) return M.DIR .. "Contracts/" .. id .. "." .. id end

---------------------------------------------------------------------------------------------------- pure model
function M.contract(cid) return M.CONTRACTS[cid] end
function M.sponsorOf(cid) local d = M.CONTRACTS[cid]; return d and d.sponsor or nil end

-- the contract's target on the act's planet `planet` (1-based): InitialTarget on the first, PlanetTargets[planet - 1]
-- after it (the last authored one beyond them)
function M.targetFor(def, planet)
    if type(def) ~= "table" then return nil end
    planet = math.max(1, math.floor(tonumber(planet) or 1))
    if planet == 1 or type(def.targets) ~= "table" or #def.targets == 0 then return tonumber(def.init) or 10 end
    return tonumber(def.targets[math.min(planet - 1, #def.targets)]) or tonumber(def.init) or 10
end

-- "Spent {NumActions}s using Ramjet" / the plural forms -> text for n
function M.fmtLine(text, n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(text or "")
    s = s:gsub("{NumActions}|plural%(one=([^,%)]*),other=([^%)]*)%)", function(one, other) return n == 1 and one or other end)
    s = s:gsub("{NumActions}", tostring(n))
    return s
end

-- contract mood from progress / target (CAM_SponsorConfig)
function M.contractMood(score, target)
    target = tonumber(target) or 0
    if target <= 0 then return M.MOOD.Pleased end
    local norm = (tonumber(score) or 0) / target
    if norm <= M.FAIL_NORM then return M.MOOD.Displeased end
    if norm >= M.EXCELLENT_NORM then return M.MOOD.Pleased end
    return M.MOOD.Neutral
end

-- [L] form mood from his finish positions on the planet: the mean place in the top quarter of the grid = Pleased, in
-- the top half = Neutral, else Displeased (no race = Neutral)
function M.formMood(positions, gridN)
    if type(positions) ~= "table" or #positions == 0 then return M.MOOD.Neutral end
    local g = math.max(2, math.floor(tonumber(gridN) or 12))
    local sum, n = 0, 0
    for _, p in ipairs(positions) do
        p = tonumber(p)
        if p and p >= 1 then sum, n = sum + math.min(p, g), n + 1 end
    end
    if n == 0 then return M.MOOD.Displeased end
    local mean = sum / n
    if mean <= math.max(1, g * 0.25) then return M.MOOD.Pleased end
    if mean <= g * 0.5 then return M.MOOD.Neutral end
    return M.MOOD.Displeased
end

-- [L] overall = the mean of form and contract, half up
function M.overallMood(form, cmood)
    return math.floor(((tonumber(form) or 1) + (tonumber(cmood) or 1) + 1) / 2)
end

function M.reward(mood) return M.CHECKIN_CR[math.max(0, math.min(2, math.floor(tonumber(mood) or 0)))] or 0 end

-- a backer record
function M.newRec(sponsor, contract, extra)
    local b = { sponsor = sponsor, contract = contract, planets = {} }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end

-- his record of planet `planet` for his CURRENT contract (a contract changed mid-planet starts at 0)
function M.planetRec(b, planet, target)
    b.planets = type(b.planets) == "table" and b.planets or {}
    local k = math.max(1, math.floor(tonumber(planet) or 1))
    local r = b.planets[k]
    if type(r) ~= "table" or r.contract ~= b.contract then
        local old = r
        r = { contract = b.contract, progress = 0, pos = (type(old) == "table" and type(old.pos) == "table") and old.pos or {},
              races = 0 }
        b.planets[k] = r
    end
    if target then r.target = target end
    return r
end

-- add `amount` units to planet `planet` up to the 200% cap -> credited (what counts for this race's credits), capped
function M.credit(b, planet, amount, target)
    local r = M.planetRec(b, planet, target)
    amount = math.max(0, tonumber(amount) or 0)
    local cap = M.CAP * (tonumber(r.target) or 0)
    local room = (cap > 0) and math.max(0, cap - (tonumber(r.progress) or 0)) or amount
    local got = math.min(amount, room)
    r.progress = (tonumber(r.progress) or 0) + got
    r.races = (r.races or 0) + 1
    return got, got < amount
end

-- the race's credits: whole units x credits per action
function M.racePay(credited, cpa)
    return math.max(0, math.floor(tonumber(credited) or 0)) * math.max(0, math.floor(tonumber(cpa) or 0))
end

-- his check-in of planet `planet` (pure): moods and the reward
function M.checkin(b, planet, gridN)
    local r = M.planetRec(b, planet)
    local form = M.formMood(r.pos, gridN)
    local cm = M.contractMood(r.progress, r.target)
    local om = M.overallMood(form, cm)
    local kp = M.CHECKIN_KP[math.max(0, math.min(2, om))] or 0
    local pen = (om == M.MOOD.Displeased) and M.PENALTY[b.sponsor] or nil
    return { form = form, cmood = cm, omood = om, cr = M.reward(om), kp = kp, penalty = pen,
             progress = tonumber(r.progress) or 0, target = tonumber(r.target) or 0, pos = r.pos,
             earned = tonumber(r.earned) or 0 }
end

-- [L] the run's rating: the mean overall mood of his checked planets, half up (nil: no check-in yet)
function M.runRating(b)
    local sum, n = 0, 0
    for _, r in pairs(type(b) == "table" and b.planets or {}) do
        if type(r) == "table" and r.checked and r.omood ~= nil then sum, n = sum + r.omood, n + 1 end
    end
    if n == 0 then return nil end
    return math.floor(sum / n + 0.5)
end

-- MIGRATION: a guest without a backer gets P1's (progress 0) -> true when it changed
function M.migrate(p, p1)
    if type(p) ~= "table" or type(p1) ~= "table" or not p1.contract then return false end
    if type(p.backer) == "table" and p.backer.contract then return false end
    p.backer = M.newRec(p1.sponsor or M.sponsorOf(p1.contract), p1.contract,
        { migrated = true, cpa = (M.CONTRACTS[p1.contract] or {}).cpa, startPaid = true })
    return true
end

---------------------------------------------------------------------------------------------------- tracker (pure)
-- One sample of his car every SAMPLE_MS while the race runs: s = { now, inAir (VehicleState.TimeInAir), speed
-- (SpeedKmph), top (TopSpeedKmph), rj (RamjetState), boost (BoostState), draft (DraftingState), knife, drift, pos (his
-- place in his race), grid (cars in his race), energy (PlayerAbilityComponent.CurrentAbilityEnergy) }. Time goals add
-- the time since the last sample while their condition holds; count goals count transitions. Events (hooks):
-- takedown, preflight, abilityhit, malfunction.
M.SAMPLE_MS = 200                      -- couch-racegc: ~4 wrappers per guest per sample (5 Hz is plenty for 0.1 s goals)
M.NO_TRACK_MS = 2000                   -- a guest without a backer is looked at again this often in a race
M.OUT_MS = 500                         -- his "out of the race" (finished / wrecked / eliminated) read this often
M.MAX_DT = 0.5                         -- a frame hitch is never booked as more than half a second
M.JUMP_AIR = 0.5                       -- [L] a jump = at least this long in the air, then a landing
M.MANEUVER_S = 1.2                     -- VehicleModifierRequirementConfig.ModifierDuration (knife / drift held)
M.SPEED_SCALE, M.SPEED_KMH = 1.395, 380 -- VehicleSpeedRequirementConfig: SpeedScaleThreshold / VehicleSpeedThreshold
M.DRAFT_GRACE = 1.5                    -- [L] a pass this soon after drafting = a slipstream pass
M.DOUBLE_WINDOW = 2.0                  -- OvertakeRequirementConfig.TimeLimit (2 opponents within 2 s)
M.ABILITY_HIT_WINDOW = 8.0             -- [L] a hit on an opponent this soon after his ability use = an ability hit
local RJ_ACTIVE = { [3] = true, [4] = true }       -- ERamjetState Active, CriticalWarning
local BOOST_AB = { [1] = true, [2] = true }        -- EBoostState MovingToAfterburner, Afterburner
local DRAFTING = { [1] = true, [2] = true }        -- EDraftingState Gaining, Maintaining

M.GOALS = {
    airborne = "time", highspeed = "time", ramjet = "time", afterburner = "time", drafting = "time", first = "time",
    last = "time", abilityhit = "event", takedown = "event", preflight = "event", malfunction = "event",
    slipstream = "count", overtake2 = "count", overtake = "count", abilityuse = "count", jump = "count",
    maneuver = "count", redline = "count",
}

function M.newTrack(goal) return { goal = goal, value = 0, gains = {}, samples = 0 } end

local function holds(goal, s)
    if goal == "airborne" then return (tonumber(s.inAir) or 0) > 0 end
    if goal == "highspeed" then
        local sp, top = tonumber(s.speed) or 0, tonumber(s.top) or 0
        if top > 0 then return sp >= top * M.SPEED_SCALE end
        return sp >= M.SPEED_KMH
    end
    if goal == "ramjet" then return RJ_ACTIVE[tonumber(s.rj) or -1] == true end
    if goal == "afterburner" then return BOOST_AB[tonumber(s.boost) or -1] == true end
    if goal == "drafting" then return DRAFTING[tonumber(s.draft) or -1] == true end
    if goal == "first" then return tonumber(s.pos) == 1 end
    if goal == "last" then
        local p, g = tonumber(s.pos), tonumber(s.grid)
        return p ~= nil and g ~= nil and g > 1 and p >= g
    end
    return false
end

-- one sample -> t (updated), the units added
function M.sample(t, s)
    local now = (tonumber(s.now) or 0) / 1000
    local dt = t.last and math.min(M.MAX_DT, math.max(0, now - t.last)) or 0
    t.last = now
    t.samples = t.samples + 1
    local g, add = t.goal, 0
    local kind = M.GOALS[g]
    if kind == "time" then
        if holds(g, s) then add = dt end
    elseif g == "overtake" or g == "slipstream" or g == "overtake2" then
        local pos = tonumber(s.pos)
        if DRAFTING[tonumber(s.draft) or -1] or tonumber(s.draft) == 3 then t.draftAt = now end
        if pos and t.pos and pos < t.pos then
            local k = t.pos - pos
            if g == "overtake" then add = k
            elseif g == "slipstream" then
                if t.draftAt and now - t.draftAt <= M.DRAFT_GRACE then add = k end
            else
                for _ = 1, k do t.gains[#t.gains + 1] = now end
                local keep = {}
                for _, at in ipairs(t.gains) do if now - at <= M.DOUBLE_WINDOW then keep[#keep + 1] = at end end
                t.gains = keep
                if #keep >= 2 then add = 1; t.gains = {} end
            end
        end
        if pos then t.pos = pos end
    elseif g == "jump" then
        local air = tonumber(s.inAir) or 0
        if air > 0 then t.airMax = math.max(t.airMax or 0, air)
        else
            if (t.airMax or 0) >= M.JUMP_AIR then add = 1 end
            t.airMax = 0
        end
    elseif g == "redline" then
        local rj = tonumber(s.rj)
        if rj == 4 and t.rj ~= 4 then add = 1 end
        t.rj = rj
    elseif g == "maneuver" then
        local on = s.knife == true or s.drift == true
        if on then
            t.manSince = t.manSince or now
            if not t.manDone and now - t.manSince >= M.MANEUVER_S then add = 1; t.manDone = true end
        else
            t.manSince, t.manDone = nil, nil
        end
    elseif g == "abilityuse" then
        local e = tonumber(s.energy)
        if e and t.energy and e < t.energy then add = 1 end
        if e then t.energy = e end
    end
    if g == "abilityhit" then                     -- his ability use is the window of an ability hit
        local e = tonumber(s.energy)
        if e and t.energy and e < t.energy then t.usedAt = now end
        if e then t.energy = e end
    end
    t.value = t.value + add
    return t, add
end

-- an event of his (a hook) -> units added
function M.event(t, kind, nowMs)
    local now = (tonumber(nowMs) or 0) / 1000
    local add = 0
    if kind == t.goal then
        add = 1
        if kind == "abilityhit" then t.nativeHits = true end   -- rel103: the game's own hit event counts from now on
    elseif kind == "hit" and t.goal == "abilityhit" and not t.nativeHits then
        if t.usedAt and now - t.usedAt <= M.ABILITY_HIT_WINDOW then add = 1 end
    end
    t.value = t.value + add
    return add
end

---------------------------------------------------------------------------------------------------- live: reads
local function activeRun()
    local ok, r = pcall(function() return CR().activeRun() end)
    return (ok and U.ok(r)) and r or nil
end

-- P1's backer and contract (the run's) -> { sponsor = id, contract = id } | nil
function M.p1Backer()
    local r = activeRun()
    if not r then return nil end
    local sp, ct = nil, nil
    pcall(function() sp = r.Sponsor end)
    pcall(function() ct = r.SponsorContract end)
    if not (U.ok(sp) and U.ok(ct)) then return nil end
    local s, c = U.objName(sp), U.objName(ct)
    -- only the game's own backers / contracts (an unknown object is never handed to a guest)
    if not (M.SPONSORS[s] and M.CONTRACTS[c]) then return nil end
    return { sponsor = s, contract = c }
end

-- his record's backer (migrated from P1's when he has none: a run in progress) -> b | nil
function M.ensure(ctrlId, pnum, why)
    local okP, p = pcall(function() return CR().ensure(ctrlId, pnum) end)
    if not (okP and type(p) == "table") then return nil end
    if type(p.backer) == "table" and p.backer.contract then return p.backer end
    local p1 = M.p1Backer()
    if p1 and M.migrate(p, p1) then
        -- couch-fix42 (live A5 "P2 has no backer!"): this IS his backer from now on (fix21's MIGRATION rule), so his
        -- contract pays; said plainly so a "contract +N" of a guest who never picked is not read as a bug
        U.log(TAG, "P%s has no backer of his own (%s): P1's %s / %s, progress 0 - MIGRATED (a guest without a pick "
            .. "takes P1's backer): his contract counts and pays from now on, his own pick at the next backer screen "
            .. "replaces it", tostring(p.pnum), tostring(why or "-"),
            M.nameOf(p1.sponsor), tostring((M.CONTRACTS[p1.contract] or {}).text or p1.contract))
        pcall(function() CR().save() end)
        return p.backer
    end
    return nil
end

function M.nameOf(sponsor) local s = M.SPONSORS[sponsor]; return s and s.name or tostring(sponsor) end

-- the contract's live target (the asset's own InitialTarget / PlanetTargets when it is loaded), else the table's
function M.liveTarget(cid, planet)
    local def = M.CONTRACTS[cid]
    local t = M.targetFor(def, planet)
    local o = U.findLoaded(M.contractPath(cid))
    if o and U.ok(o) then
        pcall(function()
            if planet <= 1 then t = tonumber(o.InitialTarget) or t; return end
            local best = nil
            for _, e in ipairs(U.arrayToTable(o.PlanetTargets)) do
                local i, v = tonumber(e.PlanetIndex), tonumber(e.Target)
                if i and v and i <= planet - 1 and (not best or i > best.i) then best = { i = i, v = v } end
            end
            if best then t = best.v end
        end)
    end
    return t
end

---------------------------------------------------------------------------------------------------- live: choice
-- his pick at the backer screen. o = { sponsor, contract, cpa, start, locked } (couchbackerui reads them from the
-- offer), startCredits = the offer shows starting credits (a run's first pick). -> ok, toast
function M.choose(ctrlId, pnum, o, startCredits)
    if type(o) ~= "table" or not o.contract then return false, "NO CONTRACT" end
    if o.locked then return false, "LOCKED" end
    local okP, p = pcall(function() return CR().ensure(ctrlId, pnum) end)
    if not (okP and type(p) == "table") then return false, "NO RUN" end
    local old = type(p.backer) == "table" and p.backer or nil
    local b = M.newRec(o.sponsor or M.sponsorOf(o.contract), o.contract,
        { cpa = tonumber(o.cpa) or (M.CONTRACTS[o.contract] or {}).cpa,
          planets = old and old.planets or {}, rated = old and old.rated, rating = old and old.rating,
          unlocked = old and old.unlocked, startPaid = old and old.startPaid })
    p.backer = b
    local grant = 0
    if startCredits and not b.startPaid then
        grant = math.max(0, math.floor(tonumber(o.start) or (M.SPONSORS[b.sponsor] or {}).start or 0))
        b.startPaid = true
        p.credits = (p.credits or 0) + grant
    end
    pcall(function() CR().save() end)
    local def = M.CONTRACTS[o.contract] or {}
    U.log(TAG, "P%s signs with %s: %s (%s CR per action)%s", tostring(p.pnum), M.nameOf(b.sponsor),
        tostring(def.text or o.contract), tostring(b.cpa), grant > 0 and string.format(", +%d starting CR (total %d)",
        grant, p.credits) or "")
    return true, "CONTRACT SIGNED"
end

---------------------------------------------------------------------------------------------------- live: tracker
-- tracks[seat-ish key] = { pnum, ctrlId, t, cid, psKey, pawnKey } of THIS race world
local T = { gen = nil, tracks = {}, lastAt = -1e12, kindOk = nil, hits = {}, tdSeen = {}, stats = { events = 0 },
            fires = {}, abSeen = {}, condSeen = {} }
M._T = function() return T end

local function guests()
    local ok, list = pcall(function() return U.mod("join").joinedList() end)
    return (ok and type(list) == "table") and list or {}
end

local function resetWorld()
    T.gen, T.tracks, T.kindOk, T.hits, T.tdSeen, T.lastAt = St.worldGen, {}, nil, {}, {}, -1e12
    T.miss, T.hitSeen, T.pfSeen = {}, {}, {}
    T.fires, T.abSeen, T.condSeen, T.firesLogged = {}, {}, {}, nil
    T.pfCount, T.pfPollAt, T.pfGame, T.pfFindAt = {}, nil, nil, nil
end
-- rel103: how often each attribution hook fired in this race world (logged once at the race end: the live check)
local function fired(k) T.fires[k] = (T.fires[k] or 0) + 1 end
M._fired = fired

-- this race counts for backer contracts (a StandardEvent / HighRiskEvent node, not a plane test)
local function kindOk()
    if T.kindOk ~= nil then return T.kindOk end
    local ok, planet, kind = pcall(function() return CR().nodeInfo() end)
    T.kindOk = ok and M.CONTRACT_KINDS[kind] == true or false
    T.planet = ok and planet or 1
    U.log(TAG, "race of kind %s on planet %s: the guests' backer contracts %s", tostring(ok and kind or "?"),
        tostring(T.planet), T.kindOk and "count" or "do not count (not a standard / high-risk event)")
    return T.kindOk
end

local function trackOf(e)
    local k = tostring(e.ctrlId)
    local tr = T.tracks[k]
    if tr then return tr end
    -- no backer of his at this race's start (none of P1's to migrate either): none this race (the run is read once
    -- per race world: no object-array walk in a steady race)
    T.miss = T.miss or {}
    if T.miss[k] then return nil end
    T.miss[k] = true
    local b = M.ensure(e.ctrlId, e.pnum, "race start")
    if not b then return nil end
    local def = M.CONTRACTS[b.contract]
    if not def then return nil end
    T.miss[k] = nil
    tr = { pnum = e.pnum, ctrlId = e.ctrlId, cid = b.contract, t = M.newTrack(def.goal) }
    pcall(function() tr.psKey = U.key(e.pc.PlayerState) end)
    T.tracks[k] = tr
    U.log(TAG, "P%s's own backer contract this race: %s (%s, goal %s)%s", tostring(e.pnum), M.nameOf(b.sponsor),
        tostring(def.text), def.goal, b.migrated and " [migrated from P1's: he has not picked one]" or "")
    return tr
end

-- what each goal reads from his car / PlayerState (couch-racegc: every property read is a new UE4SS wrapper - a sample
-- reads only its goal's fields)
local NEEDS = {
    airborne = { car = true, inAir = true }, jump = { car = true, inAir = true },
    highspeed = { car = true, speed = true }, ramjet = { car = true, rj = true }, redline = { car = true, rj = true },
    afterburner = { car = true, boost = true }, drafting = { car = true, draft = true },
    slipstream = { car = true, draft = true, pos = true }, overtake = { pos = true }, overtake2 = { pos = true },
    first = { pos = true }, last = { pos = true, grid = true }, maneuver = { car = true, knife = true },
    abilityuse = { energy = true }, abilityhit = { energy = true },
}
M.NEEDS = NEEDS

-- the cars in a race without instances (the PlayerArray, re-read every NO_TRACK_MS)
local function gridNow(now)
    if T.grid and now - (T.gridAt or 0) < M.NO_TRACK_MS then return T.grid end
    local n = nil
    pcall(function() n = U.arrayCount(U.gs().PlayerArray) end)
    if not n or n < 2 then pcall(function() n = tonumber(CR().gridN()) end) end
    T.grid, T.gridAt = n, now
    return n
end

-- his place in his race (instances: his copy's) and the cars in it
local function placeOf(ps, rec, now, wantGrid)
    local pos, grid = nil, nil
    pcall(function()
        local lp, _, of = U.mod("instances").localPosition(ps)
        if lp then pos, grid = lp, of end
    end)
    if not pos then pcall(function() pos = math.floor(tonumber(rec.EventPosition) or 0) end) end
    if not grid and wantGrid then grid = gridNow(now) end
    if pos and (pos >= 99 or pos < 1) then pos = nil end
    return pos, grid
end

local function readSample(e, now, tr)
    local need = NEEDS[tr.t.goal] or {}
    local s = { now = now }
    local ps, rec = nil, nil
    pcall(function() ps = e.pc.PlayerState end)
    if not U.ok(ps) then return nil end
    if need.pos or now - (tr.outAt or -1e12) >= M.OUT_MS then
        pcall(function() rec = ps.RaceEventComponent end)
    end
    if U.ok(rec) and now - (tr.outAt or -1e12) >= M.OUT_MS then
        tr.outAt = now
        local out = false
        pcall(function()
            out = rec.bHasFinishedEvent == true or rec.bHasVehicleWrecked == true or rec.bHasBeenEliminated == true
        end)
        if out then return nil, "out" end
    end
    if need.car then
        pcall(function()
            local car = e.pc.Pawn
            if not U.ok(car) then return end
            local vs = car.VehicleState
            if not U.ok(vs) then return end
            if need.inAir then s.inAir = tonumber(vs.TimeInAir) end
            if need.speed then s.speed, s.top = tonumber(vs.SpeedKmph), tonumber(vs.TopSpeedKmph) end
            if need.rj then s.rj = tonumber(vs.RamjetState) end
            if need.boost then s.boost = tonumber(vs.BoostState) end
            if need.draft then s.draft = tonumber(vs.DraftingState) end
            if need.knife then s.knife, s.drift = vs.Knifing == true, vs.Drifting == true end
        end)
    end
    if need.energy then pcall(function() s.energy = tonumber(ps.AbilityComponent.CurrentAbilityEnergy) end) end
    if need.pos then s.pos, s.grid = placeOf(ps, rec, now, need.grid) end
    return s
end

-- FAST loop (main.lua, race phases): every guest's own contract goal from his own car
function M.raceTick()
    if opt("CouchBackers", true) == false then return end
    if T.gen ~= St.worldGen then resetWorld() end
    if St.phase == "PRERACE" or St.phase == "RACING" then U.try(TAG, M.pollPreflight, St.nowMs()) end
    if St.phase ~= "RACING" then return end
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if not (okC and couch == true) then return end
    local now = St.nowMs()
    if now - T.lastAt < M.SAMPLE_MS then return end
    T.lastAt = now
    if not kindOk() then return end
    for _, e in ipairs(guests()) do
        local tr = trackOf(e)
        local g = tr and tr.t.goal
        -- the sampled goals (an ability hit samples his ability energy: its window)
        if tr and not tr.out and (M.GOALS[g] ~= "event" or g == "abilityhit") then
            local s, why = readSample(e, now, tr)
            if s then M.sample(tr.t, s)
            elseif why == "out" and not tr.out then
                tr.out = true
                U.log(TAG, "P%s is out of the race: his contract count stops at %.1f", tostring(e.pnum), tr.t.value)
            end
        end
    end
end

-- an event of a racer whose PlayerState key is psKey (hooks below)
local function bookEvent(psKey, kind, why)
    if not psKey or psKey == 0 then return end
    if T.gen ~= St.worldGen then return end
    if not (St.phase == "RACING" or (kind == "preflight" and St.phase == "PRERACE")) then return end
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if not (okC and couch == true) then return end
    if not kindOk() then return end
    for _, e in ipairs(guests()) do
        local tr = trackOf(e)
        if tr and tr.psKey == psKey and not tr.out then
            local add = M.event(tr.t, kind, St.nowMs())
            if add > 0 then
                T.stats.events = T.stats.events + 1
                U.log(TAG, "P%s %s (%s): his contract %s -> %g", tostring(e.pnum), kind, tostring(why or "-"),
                    tr.t.goal, tr.t.value)
            end
            return
        end
    end
end
M._bookEvent = bookEvent

local function psKeyOfPawn(pawn)
    local k = nil
    pcall(function() if U.ok(pawn) then local ps = pawn.PlayerState; if U.ok(ps) then k = U.key(ps) end end end)
    return k
end

-- takedown (VehicleGameplayComponent:OnVehicleTakedown, one call per bound component: deduped per pair)
function M.onTakedown(action)
    local a = U.unwrap(action)
    local inst, vic = nil, nil
    pcall(function() inst = a.Instigator end)
    pcall(function() vic = a.victim end)
    if not U.ok(inst) then return end
    local ik, vk = U.key(inst), U.ok(vic) and U.key(vic) or 0
    if ik == vk then return end
    local pair = tostring(ik) .. ">" .. tostring(vk)
    local now = St.nowMs()
    if T.tdSeen[pair] and now - T.tdSeen[pair] < 1500 then return end
    T.tdSeen[pair] = now
    -- #110: the per-player takedown counter of the favours (Brutal Calm, Family Legacy) shares this one hook
    local okF, FV = pcall(U.mod, "couchfavours")
    if okF and type(FV) == "table" and FV.bookTakedown then U.try(TAG, FV.bookTakedown, inst, vic) end
    bookEvent(ik, "takedown", "takedown")
end

-- a completed pre-race check of HIS component.
-- couch-fix74 (player report v1.0.2: "5 checks per race across 5 races, the contract still showed 0"): the old hook on
-- PlayerPreFlightCheckComponent:Server_OnSuccessfulPreFlightCheck NEVER fires for a real check. Static (CL381121 exe,
-- same code in CL386500): the native TestPreflightCheckInput (exec thunk 0x14700b8ee -> 0x1470c73e8) calls the RPC's
-- _Implementation 0x1470c7752 DIRECTLY (C++ call, no ProcessEvent; the reflected Server_ exec thunk 0x14700b6aa only
-- jmps to it via 0x1470c7b4c), so the UFunction hook only saw the mod's own "auto" completions. The _Implementation
-- broadcasts OnPreFlightCheckSuccess (PFCSuccess(FText Name)); every WBP_IgnitionScreen_C binds it to its BP event
-- OnPreFlightCheckSuccess for GetOwningPlayer()->PlayerState->PreFlightCheckComponent ("Setup Preflight Checks"), and a
-- delegate call of a BP function goes through ProcessEvent (hookable). So a success = that BP event on a screen owned by
-- his PC. Two screens can be bound to his component (the game's own screen belongs to the last local PC, plus
-- ignition.lua's per-player copy): one success = one booking (same check name within PREFLIGHT_DEDUP_MS, or any
-- success within PREFLIGHT_SAME_MS when the name is unreadable).
M.PREFLIGHT_DEDUP_MS = 1500
M.PREFLIGHT_SAME_MS = 120
M.IGN_SUCCESS = "/Game/Griffin/UI/Screens/PreRace/WBP_IgnitionScreen.WBP_IgnitionScreen_C:OnPreFlightCheckSuccess"
local function preflightDup(psk, name)
    T.pfSeen = T.pfSeen or {}
    local now = St.nowMs()
    local last = T.pfSeen[psk]
    local dup = last ~= nil and ((name ~= nil and last.name == name and now - last.at < M.PREFLIGHT_DEDUP_MS)
        or now - last.at < M.PREFLIGHT_SAME_MS)
    if not dup then T.pfSeen[psk] = { name = name, at = now } end
    return dup
end

local function bookPreflight(psk, name, why)
    if not psk or psk == 0 then return end
    if T.gen ~= St.worldGen then resetWorld() end
    if preflightDup(psk, name) then return end
    bookEvent(psk, "preflight", why)
end
M._bookPreflight = bookPreflight

-- the RPC path (the mod's own IgnitionMode "auto" completions call it through ProcessEvent)
function M.onPreflight(comp)
    comp = U.unwrap(comp)
    if not U.ok(comp) then return end
    local ck = U.key(comp)
    for _, e in ipairs(guests()) do
        local mine = false
        pcall(function() mine = U.key(e.pc.PlayerState.PreFlightCheckComponent) == ck end)
        if mine then
            local psk = nil
            pcall(function() psk = U.key(e.pc.PlayerState) end)
            bookPreflight(psk, nil, "pre-race check (RPC)")
            return
        end
    end
end

-- the success broadcast as a screen sees it (WBP_IgnitionScreen_C:OnPreFlightCheckSuccess(FText Name), self = screen)
function M.onScreenPreflight(screen, nameParam)
    screen = U.unwrap(screen)
    if not U.ok(screen) then return end
    local own = nil
    pcall(function() own = screen:GetOwningPlayer() end)
    if not U.ok(own) then return end
    local ok_ = U.key(own)
    local name = nil
    pcall(function()
        local v = U.unwrap(nameParam)
        if v ~= nil then name = v:ToString() end
    end)
    if type(name) ~= "string" or name == "" then name = nil end
    for _, e in ipairs(guests()) do
        if U.key(e.pc) == ok_ then
            local psk = nil
            pcall(function() psk = U.key(e.pc.PlayerState) end)
            bookPreflight(psk, name, "pre-race check " .. tostring(name or "?"))
            return
        end
    end
end

-- rel103 (hook audit finding A): WBP_IgnitionScreen_C:OnPreFlightCheckSuccess is a Blueprint event and this UE4SS runs
-- no Blueprint hook (ProcessLocalScriptFunction unavailable): fix74's hook never fires live. The screens themselves
-- count: the BP event increments the screen's SuccessCount (WBP_IgnitionScreen disasm, ubergraph 524..778). Polled in
-- PRERACE (and the first racing seconds) on ignition.lua's per-player copies and the game's own screen; per player the
-- HIGHEST count of his screens (two screens bound to one component count the same checks once) - each increase = one
-- check of his. The native VehicleAudioGovernorComponent:OnPreflightCheckSuccess hook only counts fires (evidence).
M.PREFLIGHT_POLL_MS = 150
M.PREFLIGHT_NATIVE_FN = "/Script/Griffin.VehicleAudioGovernorComponent:OnPreflightCheckSuccess"
local function screenCount(w)
    local n = nil
    pcall(function() n = tonumber(w.SuccessCount) end)
    return n
end
function M.pollPreflight(now)
    if now - (T.pfPollAt or -1e12) < M.PREFLIGHT_POLL_MS then return end
    T.pfPollAt = now
    if St.phase == "RACING" and now - (tonumber(St.race.startedAtMs) or now) > 5000 then return end
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if not (okC and couch == true) then return end
    local gl = guests()
    if #gl == 0 then return end
    local ign = St.present and St.present.ign or nil
    if type(ign) ~= "table" then ign = { players = {} } end
    -- live 2026-10-24: in a couch race ignition.lua keeps no screen (St.present.ign empty): the game's own screen
    -- (owned by the LAST local PC) is found here, once per race world, re-found only when it is gone
    if St.phase ~= "PRERACE" then T.pfGame = nil end    -- the screen goes at the start: never touched after it
    if St.phase == "PRERACE" and not U.ok(ign.game) then
        if not U.ok(T.pfGame) and now - (T.pfFindAt or -1e12) >= 1000 then
            T.pfFindAt = now
            local okF, w = pcall(FindFirstOf, "WBP_IgnitionScreen_C")
            T.pfGame = (okF and U.ok(w)) and w or nil
        end
        if U.ok(T.pfGame) then ign = { players = ign.players, game = T.pfGame } end
    end
    local best = {}                                    -- PC key -> highest SuccessCount of his screens
    local function see(pcKey, w)
        if pcKey == 0 or not U.ok(w) then return end
        local c = screenCount(w)
        if c and (best[pcKey] == nil or c > best[pcKey]) then best[pcKey] = c end
    end
    for _, e in pairs(ign.players or {}) do
        if U.ok(e.pc) then see(U.key(e.pc), e.widget) end
    end
    if U.ok(ign.game) then
        local own = nil
        pcall(function() own = ign.game:GetOwningPlayer() end)
        if U.ok(own) then see(U.key(own), ign.game) end
    end
    T.pfCount = T.pfCount or {}
    for _, e in ipairs(gl) do
        local k = U.ok(e.pc) and U.key(e.pc) or 0
        local c = best[k]
        if c ~= nil then
            local last = T.pfCount[k]
            if last == nil then
                T.pfCount[k] = c                       -- first look: the screen's count so far (0 at a race start)
                if c > 0 then last = 0 end
            end
            if last ~= nil and c > last then
                T.pfCount[k] = c
                local psk = nil
                pcall(function() psk = U.key(e.pc.PlayerState) end)
                fired("pfpoll")
                for _ = last + 1, c do bookEvent(psk, "preflight", "pre-race check (screen count " .. c .. ")") end
            end
        end
    end
end

-- a blame / damage by his car on an opponent: an ability hit (after his ability use) and the last damager of that
-- opponent (malfunctions)
function M.onBlame(comp, aggressor, reason)
    fired("blame")
    comp, aggressor = U.unwrap(comp), U.unwrap(aggressor)
    local ak = psKeyOfPawn(aggressor)
    if not ak then return end
    local vk = nil
    pcall(function() vk = psKeyOfPawn(comp:GetOwner()) end)
    if vk == ak then return end
    if vk then T.hits[vk] = { by = ak, at = St.nowMs() } end
    local pair = tostring(ak) .. ">" .. tostring(vk or 0)
    local now = St.nowMs()
    T.hitSeen = T.hitSeen or {}
    if T.hitSeen[pair] and now - T.hitSeen[pair] < 1000 then return end
    T.hitSeen[pair] = now
    bookEvent(ak, "hit", "blame on an opponent")
end

-- rel103: the key T.hits / bookEvent use (a PlayerState's) of a pawn, a controller or a PlayerState
local function psKeyOfAny(o)
    if not U.ok(o) then return nil end
    if U.isA(o, "GfnPlayerState") then local k = U.key(o); return k ~= 0 and k or nil end
    local k = nil
    pcall(function() local ps = o.PlayerState; if U.ok(ps) then k = U.key(ps) end end)
    return (k ~= nil and k ~= 0) and k or nil
end
M._psKeyOfAny = psKeyOfAny

function M.onDamaged(victim, instigator)
    fired("damage")
    victim, instigator = U.unwrap(victim), U.unwrap(instigator)
    if not (U.ok(victim) and U.ok(instigator)) then return end
    -- rel103: keyed by PlayerState like onBlame / onCondition read it (the raw object keys never matched)
    local vk, ik = psKeyOfAny(victim), psKeyOfAny(instigator)
    if vk and ik and vk ~= ik then T.hits[vk] = { by = ik, at = St.nowMs() } end
end

-- rel103 (extra of the v1.0.2 couple report: P2's "Trigger opponents' System Malfunction" never counted above 0 in any
-- log, 58 races): the malfunction's attribution came only from VehicleBlameComponent:Server_AddBlameContributor and
-- VehicleGameplayComponent:Server_OnVehicleDamaged. Both are SERVER RPCs: the host's own C++ calls their _Implementation
-- directly (the pre-race check RPC's story, couch-fix74), so the UFunction hooks never see a real hit (no V-INST-DMG /
-- V-INST-BLAME line in any log either) and T.hits stayed empty. The game's own reflected path:
-- GameplayActionSubsystem.OnPlayerHitTargetWithAbility (a dynamic multicast, broadcast per ability hit) is bound to
-- VehicleGameplayComponent:OnPlayerHitTargetWithAbility(FRacePlayerHitTargetWithAbilityGameplayAction {Player,
-- AffectedPlayer (GfnPlayerState), AbilityUsed}) - a delegate call = ProcessEvent = hookable. One broadcast reaches
-- every bound component: deduped per (player, victim, ability) within AB_DEDUP_MS. It is the attacker of the next
-- malfunction of that victim (MALF_BLAME_MS) and, for a "Hit opponents with Abilities" contract, the hit itself.
M.AB_DEDUP_MS = 250
M.AB_HIT_FN = "/Script/Griffin.VehicleGameplayComponent:OnPlayerHitTargetWithAbility"
M.CAR_COND_FN = "/Script/Griffin.VehicleGameplayComponent:OnConditionStarted"
function M.onAbilityHit(action)
    if St.phase ~= "RACING" then return end
    fired("abilityhit")
    local a = U.unwrap(action)
    local by, vic, ab = nil, nil, nil
    pcall(function() by = a.Player end)
    pcall(function() vic = a.AffectedPlayer end)
    pcall(function() ab = a.AbilityUsed end)
    local ik, vk = psKeyOfAny(by), psKeyOfAny(vic)
    if not ik or not vk or ik == vk then return end
    if T.gen ~= St.worldGen then resetWorld() end
    local now = St.nowMs()
    local pair = tostring(ik) .. ">" .. tostring(vk) .. ">" .. tostring(U.ok(ab) and U.key(ab) or 0)
    if T.abSeen[pair] and now - T.abSeen[pair] < M.AB_DEDUP_MS then return end
    T.abSeen[pair] = now
    T.hits[vk] = { by = ik, at = now }
    bookEvent(ik, "abilityhit", "ability hit on an opponent")
end

-- a vehicle's condition started (CriticalMalfunctionComponent:OnConditionStarted_OnServer): a malfunction of an opponent
-- he hit in the last MALF_BLAME_MS is his
M.MALF_BLAME_MS = 4000
-- rel103: two sources (CriticalMalfunctionComponent:OnConditionStarted_OnServer and the car's
-- VehicleGameplayComponent:OnConditionStarted, both on the victim's car): one condition start = one booking
M.COND_DEDUP_MS = 500
function M.onCondition(comp, tag, src)
    if St.phase ~= "RACING" then return end
    fired(src or "condition")
    comp, tag = U.unwrap(comp), U.unwrap(tag)
    local name = ""
    pcall(function() name = U.str(tag.TagName) end)
    if not tostring(name):lower():find("malfunction", 1, true) then return end
    fired("malfunction")
    local vk = nil
    pcall(function() vk = psKeyOfPawn(comp:GetOwner()) end)
    if not vk then return end
    if T.gen ~= St.worldGen then resetWorld() end
    local now = St.nowMs()
    local ck = tostring(vk) .. ">" .. tostring(name)
    if T.condSeen[ck] and now - T.condSeen[ck] < M.COND_DEDUP_MS then return end
    T.condSeen[ck] = now
    -- rel103 (hook audit finding B): the game's own rule (UMalfunctionRequirement::OnVehicleConditionStarted) asks the
    -- VICTIM's VehicleState:IsVehicleContributingToCondition(Condition, holder's pawn, out) - no damage / blame window.
    -- Asked for each guest with a malfunction contract; the hit window below stays as the fallback.
    local booked = false
    local car = nil
    pcall(function() car = comp:GetOwner() end)
    local vs = nil
    if U.ok(car) then pcall(function() vs = car.VehicleState end) end
    if U.ok(vs) then
        for _, tr in pairs(T.tracks) do
            if tr.t.goal == "malfunction" and not tr.out and tr.psKey ~= vk then
                local gcar = nil
                for _, e in ipairs(guests()) do
                    if tostring(e.ctrlId) == tostring(tr.ctrlId) and U.ok(e.pc) then pcall(function() gcar = e.pc.Pawn end) end
                end
                if U.ok(gcar) then
                    local okQ, r = U.pcallFn(vs, M.CONTRIB_FN, "IsVehicleContributingToCondition", tag, gcar, M.CONTRIB_OUT)
                    if St.dropOutRefs then St.dropOutRefs(M.CONTRIB_OUT) end
                    if not okQ then                    -- the tag as a plain struct table (UE4SS struct param)
                        okQ, r = U.pcallFn(vs, M.CONTRIB_FN, "IsVehicleContributingToCondition",
                            { TagName = U.fname(name) }, gcar, M.CONTRIB_OUT)
                        if St.dropOutRefs then St.dropOutRefs(M.CONTRIB_OUT) end
                    end
                    if not T.contribLogged and okQ then
                        T.contribLogged = true
                        U.log(TAG, "malfunction contract: the game's contributor check works (%s: %s, P%s) (V-BK-MALF)",
                            name, tostring(r), tostring(tr.pnum))
                    end
                    fired(okQ and (r == true and "contribyes" or "contribno") or "contriberr")
                    if not okQ and not T.contribWarned then
                        T.contribWarned = true
                        U.warn(TAG, "IsVehicleContributingToCondition failed (%s): the hit window decides", tostring(r))
                    end
                    if okQ and r == true then
                        booked = true
                        bookEvent(tr.psKey, "malfunction", name .. ", his contribution (the game's rule)")
                    end
                end
            end
        end
    end
    if booked then return end
    local h = T.hits[vk]
    if h and now - h.at <= M.MALF_BLAME_MS then bookEvent(h.by, "malfunction", name .. ", hit window") end
end
M.CONTRIB_FN = "/Script/Griffin.VehicleState:IsVehicleContributingToCondition"
M.CONTRIB_OUT = (St.outParams or function(t) return t end)({})

-- rel103: the hooks' fire counts of this race (once per race world, at the first guest's race end)
function M.logFires(why)
    if T.firesLogged == St.worldGen then return end
    T.firesLogged = St.worldGen
    local f = T.fires or {}
    U.log(TAG, "attribution hooks this race (%s): ability hits %d, blame %d, damage %d, conditions %d + %d (car), "
        .. "malfunctions %d (contributor yes %d / no %d / error %d), pre-race checks polled %d / native fires %d, "
        .. "booked events %d", tostring(why), f.abilityhit or 0, f.blame or 0, f.damage or 0, f.condition or 0,
        f.carcondition or 0, f.malfunction or 0, f.contribyes or 0, f.contribno or 0, f.contriberr or 0, f.pfpoll or 0,
        f.pfnative or 0, T.stats.events)
end

---------------------------------------------------------------------------------------------------- live: race end
-- couchrun.onRaceEnd: his contract's result of this race -> { cr, line, n, credited, capped, progress, target } | nil
-- (pos = his place for the check-in's form; info = { planet, kind })
function M.raceResult(e, p, info)
    if opt("CouchBackers", true) == false then return nil end
    if T.gen == St.worldGen then U.try(TAG, M.logFires, "race end") end
    info = info or {}
    local b = M.ensure(e.ctrlId, e.pnum, "race end")
    if not b then return nil end
    local def = M.CONTRACTS[b.contract]
    if not def then return nil end
    local planet = math.max(1, math.floor(tonumber(info.planet) or 1))
    local r = M.planetRec(b, planet, M.liveTarget(b.contract, planet))
    local pos = tonumber(info.pos)
    if pos and pos >= 1 and pos < 99 and M.CONTRACT_KINDS[info.kind] then r.pos[#r.pos + 1] = math.floor(pos) end
    if not M.CONTRACT_KINDS[info.kind] then return nil end
    local tr = (T.gen == St.worldGen) and T.tracks[tostring(e.ctrlId)] or nil
    local value = tr and tr.cid == b.contract and tr.t.value or 0
    local got, capped = M.credit(b, planet, value, r.target)
    local n = math.floor(got)
    local cr = M.racePay(got, b.cpa or def.cpa)
    local out = { cr = cr, n = n, credited = got, capped = capped, progress = r.progress, target = r.target,
                  line = M.fmtLine(def.line, n), text = def.text, sponsor = b.sponsor }
    if tr then tr.booked = true end
    out.migrated = b.migrated == true
    U.log(TAG, "P%s's contract this race (%s): %s -> %.1f / %g %s on planet %d%s: +%d CR%s", tostring(e.pnum),
        M.nameOf(b.sponsor), out.line, r.progress, r.target, def.units ~= "" and def.units or "actions", planet,
        capped and " (200% cap)" or "", cr, out.migrated and " [migrated backer: P1's, progress from 0]" or "")
    return out
end

-- couchrun.onRaceEnd: the Pirate's penalty on HIS end-of-event credits of the planet after a DISPLEASED check-in
-- (TNS_Penalty_Sponsor02: SponsorTakesCreditsFromEndOfEventRewardsPercentage 40) -> the credits taken (>= 0)
function M.penaltyCut(p, planet, cr)
    local b = type(p) == "table" and p.backer or nil
    local pen = type(b) == "table" and b.penalty or nil
    if not (type(pen) == "table" and tonumber(pen.planet) == tonumber(planet)) then return 0 end
    return math.floor((math.max(0, tonumber(cr) or 0)) * (tonumber(pen.cut) or 0) / 100)
end

-- his credits earned on a planet (race payouts + contract): the check-in page's figure
function M.addEarned(p, planet, cr)
    local b = type(p) == "table" and p.backer or nil
    if type(b) ~= "table" then return end
    local r = M.planetRec(b, planet)
    r.earned = (tonumber(r.earned) or 0) + math.floor(tonumber(cr) or 0)
end

---------------------------------------------------------------------------------------------------- live: check-in
-- P1's check-in screen came up on planet `planet`: his own check-in (moods, reward) -> data | nil. Booked once (collect).
function M.checkinData(ctrlId, pnum, planet)
    local b = M.ensure(ctrlId, pnum, "check-in")
    if not b then return nil end
    planet = math.max(1, math.floor(tonumber(planet) or 1))
    local r = M.planetRec(b, planet, M.liveTarget(b.contract, planet))
    local gridN = nil
    pcall(function() gridN = tonumber(CR().gridN()) end)
    local d = M.checkin(b, planet, gridN)
    d.planet, d.contract, d.sponsor, d.checked = planet, b.contract, b.sponsor, r.checked == true
    d.def = M.CONTRACTS[b.contract]
    if r.checked then d.cr, d.omood, d.form, d.cmood = r.cr or d.cr, r.omood or d.omood, r.form or d.form, r.cmood or d.cmood end
    return d
end

-- his check-in collected: the reward on his credits, the moods kept; the run's last check-in (runEnd) rates his run
-- and unlocks his backer's favour for everyone. -> credits paid, unlock note | nil
function M.collect(ctrlId, pnum, planet, runEnd, why)
    local okP, p = pcall(function() return CR().ensure(ctrlId, pnum) end)
    if not (okP and type(p) == "table") then return 0 end
    local d = M.checkinData(ctrlId, pnum, planet)
    if not d then return 0 end
    local b = p.backer
    local r = M.planetRec(b, d.planet)
    if r.checked then return 0 end
    r.checked, r.form, r.cmood, r.omood, r.cr, r.kp = true, d.form, d.cmood, d.omood, d.cr, d.kp
    p.credits = (p.credits or 0) + d.cr
    -- his tuning / kit points: kept on his record (shown on his pages) and, couch-fix35 (Jules's Q6), added to P1's
    -- account (couchmeta: the meta wallet the garage spends; once per run / planet / seat)
    p.kitPoints = (tonumber(p.kitPoints) or 0) + (d.kp or 0)
    if (d.kp or 0) > 0 then
        pcall(function()
            local rid = nil
            pcall(function() rid = CR().fpOf(CR().activeRun()).id end)
            U.mod("couchmeta").addPoints(string.format("%s:checkin%d:%s", tostring(rid or "?"), d.planet,
                tostring(p.seat or p.pnum)), p.pnum, 0, d.kp, "backer check-in")
        end)
    end
    if d.penalty then
        r.penalty = d.penalty.favour
        if d.penalty.cut then
            b.penalty = { planet = d.planet + 1, cut = d.penalty.cut, favour = d.penalty.favour, kind = "pirate" }
            U.log(TAG, "P%s's backer penalty (%s): %s - on HIS end-of-event credits of planet %d", tostring(p.pnum),
                M.nameOf(b.sponsor), d.penalty.text, d.planet + 1)
        else
            -- couch-fix36 (Q4): the Hutt = HIS car, the Broker = the shared map or his payout rule (couchpenalty)
            local atCheckin = false
            pcall(function() atCheckin = CR().nodeInfo() == d.planet end)
            local okN, note = pcall(function() return U.mod("couchpenalty").onGuestPenalty(p, d, atCheckin) end)
            U.log(TAG, "P%s's backer penalty (%s): %s - %s", tostring(p.pnum), M.nameOf(b.sponsor), d.penalty.text,
                (okN and note) or "not applied (couchpenalty unavailable)")
        end
    end
    U.log(TAG, "P%s's check-in with %s on planet %d (%s): form %s, contract %s (%.0f / %g), overall %s: +%d CR, +%d kit "
        .. "points (total %d CR)", tostring(p.pnum), M.nameOf(b.sponsor), d.planet, tostring(why or "his screen"),
        M.MOOD_NAME[d.form], M.MOOD_NAME[d.cmood], d.progress, d.target, M.MOOD_NAME[d.omood], d.cr, d.kp or 0, p.credits)
    local note = nil
    if runEnd then note = M.rateRun(p, why) end
    pcall(function() CR().save() end)
    return d.cr, note
end

-- the run's rating; Satisfactory or better = his backer's favour unlocked for every player (P1's account + the shared
-- store) -> a note for his screen | nil
function M.rateRun(p, why)
    local b = p and p.backer
    if type(b) ~= "table" or b.rated then return nil end
    local rating = M.runRating(b)
    if rating == nil then return nil end
    b.rated, b.rating = true, rating
    local sp = M.SPONSORS[b.sponsor]
    U.log(TAG, "P%s's run with %s rated %s (%s)", tostring(p.pnum), M.nameOf(b.sponsor), M.MOOD_NAME[rating], tostring(why))
    if rating < M.MOOD.Neutral or not sp then return nil end
    local how = M.shareUnlock(sp, p)
    b.unlocked = sp.tag
    return string.format("%s UNLOCKED FOR EVERYONE", string.upper(sp.favourName)), how
end

-- the favour's unlock tag into P1's account (the game's own SPUnlockSubsystem: the pre-run favour pickers of every player
-- read P1's account) and into couchrun's shared store (the guests' union). -> "account" | "already" | "store only"
function M.shareUnlock(sp, p)
    local how = "store only"
    pcall(function() CR().shareUnlock(sp.tag, sp.favour, p.seat, p.backer and p.backer.sponsor) end)
    if opt("CouchBackerShareUnlocks", true) == false then
        U.log(TAG, "%s (%s) kept in the couch store only (cfg.CouchBackerShareUnlocks = false)", sp.favour, sp.tag)
        return how
    end
    local lib = U.cdo("/Script/Griffin.Default__BlueprintSPUnlockSystemLibrary")
    local okS, sub = pcall(FindFirstOf, "SPUnlockSubsystem")
    if not (U.ok(lib) and okS and U.ok(sub)) then
        U.warn(TAG, "%s: no unlock subsystem - the favour is in the couch store only", sp.tag)
        return how
    end
    local tag = { TagName = U.fname(sp.tag) }
    local already = false
    pcall(function() already = lib:IsTagUnlocked(sub, tag) == true end)
    if already then
        how = "already"
    else
        local ok, err = pcall(function() lib:UnlockTag(sub, tag) end)
        how = ok and "account" or "store only"
        if not ok then U.warn(TAG, "UnlockTag(%s) failed: %s", sp.tag, tostring(err)) end
    end
    U.log(TAG, "backer favour %s (%s) earned by P%s: %s", sp.favour, sp.tag, tostring(p and p.pnum),
        how == "account" and "unlocked on P1's account for every player" or (how == "already"
            and "P1's account had it already" or "kept in the couch store"))
    return how
end

-- a planet he raced and never checked in on (no check-in screen seen, the areas closed early): settled at once, so
-- no reward is lost (couchrun.onRaceEnd: every planet before this one)
function M.settleOld(ctrlId, pnum, planet)
    local okP, p = pcall(function() return CR().ensure(ctrlId, pnum) end)
    if not (okP and type(p) == "table" and type(p.backer) == "table") then return 0 end
    local paid = 0
    for k, r in pairs(p.backer.planets or {}) do
        if type(k) == "number" and k < planet and type(r) == "table" and not r.checked and (r.races or 0) > 0
            and r.contract == p.backer.contract then
            paid = paid + (M.collect(ctrlId, pnum, k, false, "planet " .. k .. " left without his check-in") or 0)
        end
    end
    return paid
end

---------------------------------------------------------------------------------------------------- init / status
function M.init()
    U.hook("/Script/Griffin.VehicleGameplayComponent:OnVehicleTakedown", {
        pre = function(_, action) U.try(TAG, M.onTakedown, action) end }, TAG)
    U.hook("/Script/Griffin.PlayerPreFlightCheckComponent:Server_OnSuccessfulPreFlightCheck", {
        pre = function(ctx) U.try(TAG, M.onPreflight, ctx) end }, TAG)
    -- couch-fix74's Blueprint hook (M.IGN_SUCCESS) never fires in this UE4SS (rel103 hook audit): the screens' SuccessCount
    -- is polled instead (M.pollPreflight); the native audio-governor delegate target only counts fires (evidence)
    U.hook(M.PREFLIGHT_NATIVE_FN, { pre = function() fired("pfnative") end }, TAG)
    U.hook("/Script/Griffin.VehicleBlameComponent:Server_AddBlameContributor", {
        pre = function(ctx, aggr, _, reason) U.try(TAG, M.onBlame, ctx, aggr, reason) end }, TAG)
    U.hook("/Script/Griffin.VehicleGameplayComponent:Server_OnVehicleDamaged", {
        pre = function(_, victim, inst) U.try(TAG, M.onDamaged, victim, inst) end }, TAG)
    U.hook("/Script/Griffin.CriticalMalfunctionComponent:OnConditionStarted_OnServer", {
        pre = function(ctx, tag) U.try(TAG, M.onCondition, ctx, tag, "condition") end }, TAG)
    -- rel103: the attribution and condition paths the game itself broadcasts (delegate-bound UFunctions: ProcessEvent)
    U.hook(M.AB_HIT_FN, { pre = function(_, action) U.try(TAG, M.onAbilityHit, action) end }, TAG)
    U.hook(M.CAR_COND_FN, { pre = function(ctx, tag) U.try(TAG, M.onCondition, ctx, tag, "carcondition") end }, TAG)
    St.on("world", TAG, function() resetWorld() end)
end

function M.status()
    local t = {}
    for _, tr in pairs(T.tracks) do t[#t + 1] = string.format("P%s %s %.1f", tostring(tr.pnum), tr.t.goal, tr.t.value) end
    return "couchbacker: " .. (#t > 0 and table.concat(t, ", ") or "no race tracks") .. string.format(" (events %d)", T.stats.events)
end

return M
