-- couchrewards.lua (couch-rewards2 STEP 3, 2026-10-17): A GUEST'S OWN POST-RACE REWARD FLOW, the native rules ported.
-- PURE: no UObject access (couchrun builds ctx from the game; couchsim / tools/test_couchrewards.lua call it directly).
-- Source: notes/research/rogue-mode/07-p2-rewards-parity.md §1-§2 (CL382801 statics). No native call rolls rewards for
-- a second player (the generator, the fault scheduler and the stage builder read run.playerRacer = P1, the run's one
-- mRand and the run's node), so a guest's flow is computed here from HIS finish, HIS build and HIS favours, on P1's
-- node (activity, planet, day: shared). P1's flow is never touched.
--
-- THE STAGE LIST (BuildRewardsCollectionVMForCampaign 0x14715d61c order; ERewardsCollectionType):
--   6 FAULTS   his queued faults (couchfaults: a critical malfunction of HIS car), one stage per 4;
--   1 CREDITS  his credit rows (the CREDITS BREAKDOWN): "Finished 4th" (time trials: Beat / Missed Target Time) with
--              his payout (couchrules.guestOutcome: the native formula on his place) and his favour lines as
--              contributions, his challenge (WON / LOST), his Lyren podium / win bonus, "Max Vehicle Stats" + the skip
--              value when every stat of his is maxed (the base round's no-round path);
--   2.. ROUNDS only when he earned rewards (the day's bEventGeneratesRewards, not wrecked, not a failed eliminator
--              for HIM, the team's node earned them):
--              * the BASE round is ALWAYS stat upgrades (0x1430db3ce, stage 2): cards = NumberOfEndOfEventVehiclePart
--                Rewards + NumberOfEndOfEventRewards (3, minus his "fewer reward choices" deal), one pick, each card one
--                of HIS stats below the max (no repeats), level step = a [0,12,2,1] weighted roll + levelBonus - 1
--                (bonus 1, 2 on eliminators / podracer tests) [? index base: spike S9];
--              * eliminator (HighRisk 3): + a PART round (stage 5) with at least the guaranteed rarity;
--              * field test (Preview 4): one 50/50 roll: a part round (rarity floor = the top), else a second stat
--                round [? the native "else" round kind 0x147082f8a: spike S9];
--              * all stats maxed: no base round (the credits stage carries "Max Vehicle Stats").
-- After a pick, his later stat rounds that offered the same stat are re-rolled against his new build (0x1430dd81c).
-- SEEDED: one stream per (P1's run seed, node, guest), so a CONTINUE into the post event re-rolls the same offers (the
-- native mRand re-seed from mSavedDuringEventInfo.RewardRandomSeed); Lua's math.random (run.lua's) is never touched.
local M = {}

M.STAGE = { CREDITS = 1, UPGRADE = 2, ABILITY = 3, MODIFIER = 4, AFFIX = 5, FAULTS = 6 }
M.KIND_STAGE = { stat = 2, ab = 3, trait = 4, part = 5 }
M.LEVEL_WEIGHTS = { 0, 12, 2, 1 }          -- DA_Campaign_RewardsTuneConfig.UpgradeLevelRewardWeights (index 0..3)
M.LEVEL_MAX = 10
M.FAULTS_PER_STAGE = 4
M.REASON = {
    faults = "Critical Malfunction Error",               -- CampaignStringsDef.PlayerFacingAffixFaultsReason
    standard = "Event Reward", highrisk = "High Risk Event Reward", shakedown = "Shakedown Run Reward",
    -- #72: CampaignText CreditsReason_BeatTargetTime / CreditsReason_MissedTargetTime (was "Missed Target Time")
    beat = "Beat Target Time", missed = "Failed to Beat Target Time", maxed = "Max Vehicle Stats",
    takedowns = "Took down %d/%d opponents.",            -- CampaignText WinCondition_TakedownResult (P1's native row)
    won = "Won Challenge", lost = "Lost Challenge", sitout = "Sat Out", wrecked = "Wrecked",
}

---------------------------------------------------------------------------------------------------- the stream
-- a 31-bit LCG (Park-Miller, minimal standard): deterministic in plain Lua 5.4 integers
function M.seedOf(...)
    local h = 2166136261
    for _, v in ipairs({ ... }) do
        local s = tostring(v)
        for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) % 4294967296 end
        h = (h ~ 0x9e37) % 4294967296
    end
    h = h % 2147483646
    return h + 1
end
function M.stream(seed)
    local s = math.floor(tonumber(seed) or 1) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    local t = {}
    function t.next() s = (s * 48271) % 2147483647; return (s - 1) / 2147483646 end      -- [0, 1)
    function t.int(n) return math.min(n, 1 + math.floor(t.next() * n)) end              -- 1..n
    function t.state() return s end
    return t
end

---------------------------------------------------------------------------------------------------- text
function M.ordinal(n)
    n = math.floor(tonumber(n) or 0)
    local m100, m10 = n % 100, n % 10
    local suf = "th"
    if m100 < 11 or m100 > 13 then
        if m10 == 1 then suf = "st" elseif m10 == 2 then suf = "nd" elseif m10 == 3 then suf = "rd" end
    end
    return tostring(n) .. suf
end
-- the finish row's reason (CampaignText:CreditsReason_Finish "Finished {0}{0}|ordinal(...)")
function M.finishReason(ctx)
    if ctx.sitOut then return M.REASON.sitout end
    if ctx.wrecked then return M.REASON.wrecked end
    -- #72: a takedowns test's row is his own count, as P1's native one ("Took down 8/8 opponents."), passed or not
    local sc = ctx.score
    if type(sc) == "table" and sc.kind == "takedowns" and tonumber(sc.value) and tonumber(sc.target) then
        return string.format(M.REASON.takedowns, math.floor(tonumber(sc.value)), math.floor(tonumber(sc.target)))
    end
    if ctx.timeTrial then return (ctx.beat == false) and M.REASON.missed or M.REASON.beat end
    return "Finished " .. M.ordinal(ctx.pos)
end

---------------------------------------------------------------------------------------------------- credits
-- ctx: pay (his booked finish credits), pos, timeTrial, beat, score = {kind, value, target} (soloscore, a scored test),
-- wrecked, sitOut, contrib = {texts}, bet = {name, won,
-- pay, stake} | nil, bonus = {top3, win} (applied amounts), maxedSkip (credits when no base round: all stats maxed),
-- contract = {line, cr} (his backer contract's actions, couch-fix21) | nil
-- -> rows {reason, delta, contrib}, total
function M.creditRows(ctx)
    local rows, total = {}, 0
    local function add(reason, delta, contrib)
        delta = math.floor(tonumber(delta) or 0)
        rows[#rows + 1] = { reason = reason, delta = delta, contrib = contrib or {} }
        total = total + delta
    end
    -- a wreck is not ingested natively (no finish row); a sit-out is paid its share of the skip value
    if not ctx.wrecked or (tonumber(ctx.pay) or 0) ~= 0 then
        local base = (tonumber(ctx.pay) or 0) - (tonumber(ctx.bonus and ctx.bonus.top3) or 0)
            - (tonumber(ctx.bonus and ctx.bonus.win) or 0)
        add(M.finishReason(ctx), base, ctx.contrib)
    end
    if type(ctx.bet) == "table" then
        local b = ctx.bet
        local who = b.name and (" vs " .. tostring(b.name)) or ""
        add((b.won and M.REASON.won or M.REASON.lost) .. who, b.won and (tonumber(b.pay) or 0) or -(tonumber(b.stake) or 0))
    end
    if ctx.bonus then
        if (tonumber(ctx.bonus.top3) or 0) > 0 then add("Podium Bonus", ctx.bonus.top3) end
        if (tonumber(ctx.bonus.win) or 0) > 0 then add("Victory Bonus", ctx.bonus.win) end
    end
    -- couch-fix21 (#90): his backer contract's actions this race (the game's "ContractActions" row: the contract's
    -- CreditsBreakdownActionDescription, NumActions x the contract's credits per action)
    if type(ctx.contract) == "table" and (tonumber(ctx.contract.cr) or 0) > 0 then
        add(tostring(ctx.contract.line or "Backer contract"), ctx.contract.cr)
    end
    -- couch-fix21: his backer's cut after his displeased check-in (the game's "Contribution to Pirates" row)
    if (tonumber(ctx.penalty) or 0) > 0 then add("Contribution to Pirates", -math.floor(ctx.penalty)) end
    if ctx.maxedSkip then add(M.REASON.maxed, ctx.maxedSkip) end
    -- #110: his favours' credit lines (Team Vranki "Unused Crash", Family Legacy "Took down Rival / Kestar")
    for _, x in ipairs(type(ctx.extra) == "table" and ctx.extra or {}) do
        if (tonumber(x.delta) or 0) ~= 0 then add(tostring(x.reason or "Favor"), x.delta) end
    end
    return rows, total
end

---------------------------------------------------------------------------------------------------- rounds
-- level step: weighted roll over LEVEL_WEIGHTS (index 0..n-1) + bonus - 1, at least 1
function M.levelStep(rnd, bonus, weights)
    weights = weights or M.LEVEL_WEIGHTS
    local total = 0
    for _, w in ipairs(weights) do total = total + (tonumber(w) or 0) end
    local idx = 1
    if total > 0 then
        local x = rnd.next() * total
        for i, w in ipairs(weights) do
            x = x - (tonumber(w) or 0)
            if x < 0 then idx = i - 1; break end
        end
    end
    return math.max(1, idx + (tonumber(bonus) or 1) - 1)
end

-- his stats below the max (0..5)
local function openStats(tune, max)
    local out = {}
    for s = 0, 5 do if (tonumber(tune and tune[s]) or 0) < max then out[#out + 1] = s end end
    return out
end
M.openStats = openStats

-- the base stat round for his build (tune = lo.tune) -> round or nil (every stat maxed)
-- ctx.tune = {cards, picks, weights, max}; bonus = the event's levelBonus
function M.rollStatRound(tune, ctx, rnd, bonus, reason)
    local tn = ctx.tune or {}
    local max = tonumber(tn.max) or M.LEVEL_MAX
    local pool = openStats(tune, max)
    if #pool == 0 then return nil end
    local n = math.max(1, math.floor(tonumber(tn.cards) or 3))
    local cards = {}
    for _ = 1, n do
        if #pool == 0 then break end
        local s = table.remove(pool, rnd.int(#pool))
        local cur = math.floor(tonumber(tune[s]) or 0)
        local step = M.levelStep(rnd, bonus, tn.weights)
        -- #110 Deeper Pockets: UpgradeLevelBoostWeights[1] (a chance of one level more); no draw without it
        if tonumber(tn.boost) and tn.boost > 0 and rnd.next() < tn.boost then step = step + 1 end
        -- couch-fix32 MYST_108 "better upgrades": UpgradeLevelBoostWeights[2] (two levels more); no draw without it
        if tonumber(tn.boost2) and tn.boost2 > 0 and rnd.next() < tn.boost2 then step = step + 1 end
        local lv = math.min(step, max - cur)
        cards[#cards + 1] = { rkind = "stat", id = s, lv = lv, from = cur }
    end
    return { kind = "stat", type = M.STAGE.UPGRADE, reason = reason or M.REASON.standard, cards = cards,
             picks = math.max(1, math.floor(tonumber(tn.picks) or 1)), skippable = true, skip = ctx.skip, bonus = bonus }
end

-- #110 an ability round (Feet First's ABILITY PACK): ctx.abilityPool = { {id, lvl, up, from} } (his class's new
-- abilities and the next pip of his own, couchrun) -> round or nil
function M.rollAbilityRound(ctx, rnd, reason)
    local pool = {}
    for _, it in ipairs(ctx.abilityPool or {}) do pool[#pool + 1] = it end
    if #pool == 0 then return nil end
    local n = math.max(1, math.floor(tonumber(ctx.tune and ctx.tune.cards) or 3))
    local cards = {}
    for _ = 1, n do
        if #pool == 0 then break end
        local it = table.remove(pool, rnd.int(#pool))
        cards[#cards + 1] = { rkind = "ab", id = it.id, lvl = it.lvl, up = it.up, from = it.from }
    end
    return { kind = "ab", type = M.STAGE.ABILITY, reason = reason or "Ability Pack", cards = cards, picks = 1,
             skippable = true, skip = ctx.skip }
end

-- #110 his favours' bonus rounds (couchfavours.bonusRounds specs), rolled on the flow's own stream after the event's
-- rounds -> rounds
function M.rollBonusRounds(tune, ctx, rnd, specs)
    local out = {}
    local tn = ctx.tune or {}
    local max = tonumber(tn.max) or M.LEVEL_MAX
    for _, sp in ipairs(specs or {}) do
        local r = nil
        if sp.kind == "ab" then
            r = M.rollAbilityRound(ctx, rnd, sp.reason)
        elseif sp.kind == "stat" then
            -- an UPGRADE PACK of a fixed level (Fan Club: OverrideUpgradeLevel)
            r = M.rollStatRound(tune, { tune = { cards = tn.cards, picks = 1, max = max } }, rnd, 1, sp.reason)
            if r then
                r.levels = tonumber(sp.levels) or 1
                r.skip = ctx.skip
                for _, c in ipairs(r.cards) do c.lv = math.max(1, math.min(r.levels, max - (c.from or 0))) end
            end
        elseif sp.kind == "fixed" then
            -- one upgrade of one stat (Brutal Calm: AddUpgradeRewardRound Resilience +1)
            local cur = math.floor(tonumber(tune and tune[sp.stat]) or 0)
            if cur < max then
                r = { kind = "stat", type = M.STAGE.UPGRADE, reason = sp.reason, picks = 1, skippable = true,
                      skip = ctx.skip, fixed = true,
                      cards = { { rkind = "stat", id = sp.stat, lv = math.min(tonumber(sp.lv) or 1, max - cur), from = cur } } }
            end
        elseif sp.kind == "part" then
            local floor = tonumber(tn.partUp) and (tn.partUp > 0) and math.min(3, (tonumber(sp.floorOne) or 0) + 1) or nil
            r = M.rollPartRound(ctx, rnd, nil, sp.reason)
            local one = math.max(tonumber(sp.floorOne) or 0, floor or 0)
            if r and one > 0 then
                -- MinimumRarityForOneItem: one card at least that rare (the rarest he can get when none is)
                local okOne = false
                for _, c in ipairs(r.cards) do if (tonumber(c.rarity) or 0) >= one then okOne = true end end
                if not okOne then
                    local taken = {}
                    for _, c in ipairs(r.cards) do taken[c.id] = true end
                    local cand, best = {}, -1
                    for _, it in ipairs(ctx.partPool or {}) do
                        if not taken[it.id] then best = math.max(best, math.min(one, tonumber(it.rarity) or 0)) end
                    end
                    for _, it in ipairs(ctx.partPool or {}) do
                        if not taken[it.id] and math.min(one, tonumber(it.rarity) or 0) == best then cand[#cand + 1] = it end
                    end
                    if #cand > 0 then
                        local it = cand[rnd.int(#cand)]
                        r.cards[1] = { rkind = "part", id = it.id, rarity = it.rarity }
                    end
                end
            end
        end
        if r then out[#out + 1] = r end
    end
    return out
end

-- a part round: ctx.partPool = { {id, rarity, fam} } (his class, not owned / equipped / faulty), rarity weights by
-- rarity index 1..4 (ctx.rarityW), floor = the guaranteed minimum rarity (nil = none), famChance = % to draw from a
-- family he owns (ctx.ownedFams) -> round or nil (no part left)
function M.rollPartRound(ctx, rnd, floor, reason)
    local pool = {}
    for _, it in ipairs(ctx.partPool or {}) do
        if not floor or (tonumber(it.rarity) or 0) >= floor then pool[#pool + 1] = it end
    end
    if #pool == 0 and floor then                              -- nothing that rare: the rarest he can get
        local best = -1
        for _, it in ipairs(ctx.partPool or {}) do best = math.max(best, tonumber(it.rarity) or 0) end
        for _, it in ipairs(ctx.partPool or {}) do if (tonumber(it.rarity) or 0) == best then pool[#pool + 1] = it end end
    end
    if #pool == 0 then return nil end
    local n = math.max(1, math.floor(tonumber(ctx.tune and ctx.tune.cards) or 3))
    local cards, taken = {}, {}
    local famChance = tonumber(ctx.tune and ctx.tune.famChance) or 33.3
    for _ = 1, n do
        local cand = {}
        local fam = (ctx.ownedFams and next(ctx.ownedFams) ~= nil and rnd.next() * 100 < famChance)
        if fam then
            for _, it in ipairs(pool) do if not taken[it.id] and it.fam and ctx.ownedFams[it.fam] then cand[#cand + 1] = it end end
        end
        if #cand == 0 then
            -- a rarity first (the planet's weights), then a part of it
            local w = ctx.rarityW or { 1, 1, 1, 1 }
            local byR = {}
            for _, it in ipairs(pool) do
                if not taken[it.id] then
                    local r = math.max(1, math.min(#w, (tonumber(it.rarity) or 0) + 1))
                    byR[r] = byR[r] or {}
                    byR[r][#byR[r] + 1] = it
                end
            end
            local total = 0
            for r, list in pairs(byR) do if #list > 0 then total = total + (tonumber(w[r]) or 0) end end
            if total > 0 then
                local x = rnd.next() * total
                for r = 1, #w do
                    local list = byR[r]
                    if list and #list > 0 then
                        x = x - (tonumber(w[r]) or 0)
                        if x < 0 then cand = list; break end
                    end
                end
            end
            if #cand == 0 then for _, it in ipairs(pool) do if not taken[it.id] then cand[#cand + 1] = it end end end
        end
        if #cand == 0 then break end
        local it = cand[rnd.int(#cand)]
        taken[it.id] = true
        cards[#cards + 1] = { rkind = "part", id = it.id, rarity = it.rarity }
    end
    if #cards == 0 then return nil end
    return { kind = "part", type = M.STAGE.AFFIX, reason = reason or M.REASON.highrisk, cards = cards, picks = 1,
             skippable = true, skip = ctx.skip, floor = floor }
end

---------------------------------------------------------------------------------------------------- faults
-- the fault scheduler for his build (F = 0x1430da0c4, ported): a random part with status Active or Fixed that is not
-- already faulty / queued, a random fault of the Faulty group. build = { {id, faulty, fixed, queued} }, flaws = {ids}
-- -> {part, fault} or nil
function M.pickFault(build, flaws, rnd)
    local cand = {}
    for _, b in ipairs(build or {}) do
        if b.id and not b.faulty and not b.queued then cand[#cand + 1] = b end
    end
    if #cand == 0 or #(flaws or {}) == 0 then return nil end
    local part = cand[rnd.int(#cand)]
    return { part = part.id, fault = flaws[rnd.int(#flaws)] }
end

---------------------------------------------------------------------------------------------------- the stage list
-- ctx (couchrun.flowCtx): kind ("standard" | "highrisk" | "fieldtest" | "knockout" | "champion" | "mystery" |
-- "planesprint"), activity, earned (his rounds exist), tune {cards, picks, weights, max, famChance, guarantee},
-- skip (the skip value), partPool, rarityW, ownedFams, seed, faults = { {part, fault} }, + the creditRows ctx fields.
-- lo = his build (lo.tune). -> stages { {type, reason, rows, total | faults | round} }
function M.stagesFor(lo, ctx)
    local rnd = M.stream(ctx.seed or 1)
    local tune = lo and lo.tune or {}
    local stages, rounds = {}, {}
    local maxedSkip = nil
    if ctx.earned then
        local bonus = (ctx.kind == "highrisk" or ctx.kind == "planesprint") and 2 or 1
        local reason = (ctx.kind == "highrisk" and M.REASON.highrisk) or (ctx.kind == "fieldtest" and M.REASON.shakedown)
            or M.REASON.standard
        local base = M.rollStatRound(tune, ctx, rnd, bonus, reason)
        if base then rounds[#rounds + 1] = base else maxedSkip = tonumber(ctx.skip) or 0 end
        if ctx.kind == "highrisk" then
            local g = tonumber(ctx.tune and ctx.tune.guarantee)     -- (Silent Defiance III: +1, couchfavours.flowTune)
            local r = M.rollPartRound(ctx, rnd, g, M.REASON.highrisk)
            if r then rounds[#rounds + 1] = r end
        elseif ctx.kind == "fieldtest" then
            if rnd.next() < 0.5 then
                local top = 0
                for _, it in ipairs(ctx.partPool or {}) do top = math.max(top, tonumber(it.rarity) or 0) end
                local r = M.rollPartRound(ctx, rnd, top, M.REASON.shakedown)
                if r then rounds[#rounds + 1] = r end
            else
                local r = M.rollStatRound(tune, ctx, rnd, bonus, M.REASON.shakedown)
                if r then rounds[#rounds + 1] = r end
            end
        end
    end
    -- #110 his favours' bonus rounds (Feet First, Fan Club, Silent Defiance, Brutal Calm): not tied to the event's own
    -- rewards (the native passives add their round to the node whatever it earned); their own stream, so the event's
    -- rounds above roll exactly as without favours
    if type(ctx.favRounds) == "table" and #ctx.favRounds > 0 then
        local frnd = M.stream(M.seedOf(ctx.seed or 1, "favours"))
        for _, r in ipairs(M.rollBonusRounds(tune, ctx, frnd, ctx.favRounds)) do rounds[#rounds + 1] = r end
    end
    -- 6 FAULTS (one stage per 4)
    local f = ctx.faults or {}
    for i = 1, #f, M.FAULTS_PER_STAGE do
        local chunk = {}
        for j = i, math.min(#f, i + M.FAULTS_PER_STAGE - 1) do chunk[#chunk + 1] = f[j] end
        stages[#stages + 1] = { type = M.STAGE.FAULTS, reason = M.REASON.faults, faults = chunk }
    end
    -- 1 CREDITS
    local cctx = {}
    for k, v in pairs(ctx) do cctx[k] = v end
    cctx.maxedSkip = maxedSkip
    local rows, total = M.creditRows(cctx)
    if #rows > 0 then
        stages[#stages + 1] = { type = M.STAGE.CREDITS, reason = rows[1].reason, rows = rows, total = total }
    end
    for _, r in ipairs(rounds) do
        stages[#stages + 1] = { type = r.type, reason = r.reason, round = r }
    end
    for i, s in ipairs(stages) do s.i = i end
    return stages, maxedSkip
end

-- after a pick of stat `slot` in stage `fromIdx`: every LATER stat round offering that slot is re-rolled against the
-- new build (tune) with the flow's own stream (seed + stage). -> number of rounds re-rolled
function M.rerollAfterPick(stages, fromIdx, slot, tune, ctx, seed)
    local n = 0
    for i = fromIdx + 1, #stages do
        local s = stages[i]
        local r = s.round
        if r and r.kind == "stat" and not s.collected and not r.fixed then
            local offered = false
            for _, c in ipairs(r.cards or {}) do if c.id == slot then offered = true end end
            if offered then
                local rnd = M.stream(M.seedOf(seed or 1, "reroll", i, slot))
                local nr = M.rollStatRound(tune, ctx or {}, rnd, r.bonus or 1, r.reason)
                if nr and r.levels then
                    -- #110 a fixed-level UPGRADE PACK (Fan Club) keeps its level
                    nr.levels = r.levels
                    local max = tonumber(ctx and ctx.tune and ctx.tune.max) or M.LEVEL_MAX
                    for _, c in ipairs(nr.cards) do c.lv = math.max(1, math.min(r.levels, max - (c.from or 0))) end
                end
                if nr then s.round = nr; nr.skip = r.skip; n = n + 1 end
            end
        end
    end
    return n
end

-- the first stage not collected (index) or nil = every stage collected
function M.current(flow)
    if type(flow) ~= "table" or type(flow.stages) ~= "table" then return nil end
    for i, s in ipairs(flow.stages) do if not s.collected then return i, s end end
    return nil
end

return M
