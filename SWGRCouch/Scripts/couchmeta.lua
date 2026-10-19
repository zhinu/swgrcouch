-- couchmeta.lua (couch-fix35, audit 12 issue 6 / Jules's Q6 2026-10-18): THE GUESTS' META PROGRESS, SHARED UPWARD.
-- A guest has no meta profile of his own: what he earns for the account goes onto P1's ("earn more, faster"):
--   * TUNING / KIT POINTS: the node's own award (node.FinishTuningPointsAwarded / FinishKitPointsAwarded: the native
--     per-activity row x the tune percents, CL382801 0x1430df344, what P1's ingestion paid for the event) once per guest
--     who completed the event (raced it to a finish or an elimination: not wrecked, not sat out), and his backer
--     check-in's kit points (couchbacker.collect) -> CampaignSubsystem.MetaProgression.TuningPointsToSpend (max 999) /
--     KitPointsToSpend (max 9999), the wallet the garage spends;
--   * THE TRACKED UNLOCKS (CAM_Progression.TrackedUnlocks, decoded CAM_TrackedUnlocks_*.json): each guest's qualifying
--     events are counted once (an event key per run / node / seat / stat) towards every unlock whose condition counts
--     that stat and is open now (its prerequisites unlocked on P1's account, itself not yet). When P1's own native
--     progress (GameplayStatTracker:FindTrackedUnlockProgress -> CurrentStatValue, 0 when unreadable) + the guests'
--     count reaches the unlock's TargetValue, the tag is unlocked on P1's account (SPUnlockSubsystem UnlockTag, as
--     couchbacker's shared backer favours). P1's own events are never counted here (the game counts them): only the
--     guests' are added, each once. Counted stats (the ones the mod sees per guest):
--       fieldtest  EventModeStats ShakedownsCompleted per test mode (Precision / Time Trial / Battling / Ramjet field
--                  tests: Unassuming Prodigy, Gadgeteer, Brutal Calm, Smuggler's Hope conversations) - his own test
--                  completed (finished it, passed or not, not wrecked);
--       dealer     CampaignRunStats BlackMarketItemsPurchased (Preferred Customer: "Purchase 4 Parts from the Scrap
--                  Dealer") - each part he buys at the scrap dealer;
--       takedowns / wins / events  RacerStyleStats Takedowns / EventWins / EventsPlayed: the style unlocks (any
--                  style) and their rank II / III upgrades (with that style raced) - his takedowns, his 1st places, his
--                  completed events;
--       planets    GameplayFavourStats PlanetsCompleted ("Complete N planets with <favour> equipped"): each planet he
--                  raced with that favour rank held, counted when the run moves on to the next planet.
--     Not counted (the mod has no per-guest figure): ability uses, ramjet / shield / airborne seconds, rival wins
--     (couch-fix58: a rival challenge a guest wins is the TEAM's - couchrules.rivalResolve gives the rivalry's
--     UnlockedOnWin through M.io.unlock when the game booked it as lost), the shared map's own counters (planets visited, days, runs: P1's run is the
--     team's - adding them would count P1's own events twice), backer ratings (couchbacker shares those already).
-- Stored in couch-run.txt (couchrun's G.meta: meta, kept through checkpoint restores; Delete all couch progress
-- clears it). cfg.CouchShareMeta = false: nothing is added.
local U = require("util")
local cfg = require("config")

local TAG = "couchmeta"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

M.TP_MAX, M.KP_MAX = 999, 9999                             -- the meta wallet's caps (07-p2-rewards-parity §1.3)
M.CONTEXT = "Campaign"                                     -- every campaign TrackedUnlockList's statContext

---------------------------------------------------------------------------------------------------- the unlock table
-- { tag, stat, item (nil = any), target, pre = { tags } } (CL381121 CAM_TrackedUnlocks_Favours / _RacerStyles)
local UNLOCKS = {
    { tag = "Unlock.Cam.FavourConversation.Ghost", stat = "fieldtest", item = "precision", target = 2 },
    { tag = "Unlock.Cam.FavourConversation.MechanicB", stat = "fieldtest", item = "timetrial", target = 6 },
    { tag = "Unlock.Cam.FavourConversation.QuietStrength", stat = "fieldtest", item = "takedowns", target = 2 },
    { tag = "Unlock.Cam.FavourConversation.InnerHonour", stat = "fieldtest", item = "ramjet", target = 6 },
    { tag = "Unlock.Cam.FavourConversation.ExoticVendor", stat = "dealer", target = 4, pre = { "Unlock.Cam.Map.BlackMarket" } },
}
-- the racer styles: base unlock (any style raced) and the rank II / III upgrades (that style raced)
local STYLE = {
    { "Battling", "takedowns", 20, 24, 48 }, { "Burning", "takedowns", 48, 24, 48 }, { "Antagonist", "takedowns", nil, 24, 48 },
    { "Drafting", "wins", 40, 8, 16 }, { "Afterburner", "wins", 35, 8, 16 }, { "Surging", "wins", 60, 8, 16 },
    { "Struggling", "events", 4, 8, 16 },
}
for _, s in ipairs(STYLE) do
    local base = "Unlock.Cam.Style." .. s[1]
    if s[3] then UNLOCKS[#UNLOCKS + 1] = { tag = base, stat = s[2], target = s[3], pre = { "Unlock.Cam.Sys.CharacterLoadout" } } end
    UNLOCKS[#UNLOCKS + 1] = { tag = base .. ".UpgradeA", stat = s[2], item = s[1], target = s[4], pre = { base } }
    UNLOCKS[#UNLOCKS + 1] = { tag = base .. ".UpgradeB", stat = s[2], item = s[1], target = s[5], pre = { base .. ".UpgradeA" } }
end
-- the favours' rank II / III: "Complete 2 / 4 planets with <favour> equipped" (rank I / II held). {tag name, favour id}
local FAVOUR = {
    { "Ghost", "Ghost" }, { "MechanicA", "Mechanic_A" }, { "MechanicB", "Mechanic_B" }, { "MentorA", "Mentor_A" },
    { "MentorB", "Mentor_B" }, { "Mercenery", "Mercenary" }, { "Nomad", "Nomad" }, { "Promoter", "Promoter" },
    { "Protege", "Protege" }, { "QuietStrength", "QuietStrength" }, { "Rager", "Rager" },
    { "SponsorA", "Sponsor_Hutt" }, { "SponsorB", "Sponsor_Broker" }, { "SponsorC", "Sponsor_Pirate" }, { "Star", "Star" },
    { "Thrall", "Thrall" }, { "Veteran", "Veteran" }, { "InnerHonour", "InnerHonour" },
    { "ElegantProfessional", "ElegantProfessional" }, { "ExoticVendor", "ExoticVendor" },
}
for _, f in ipairs(FAVOUR) do
    local base = "Unlock.Cam.Favours." .. f[1]
    UNLOCKS[#UNLOCKS + 1] = { tag = base .. ".UpgradeA", stat = "planets", item = "Favour_" .. f[2] .. "_1", target = 2, pre = { base } }
    UNLOCKS[#UNLOCKS + 1] = { tag = base .. ".UpgradeB", stat = "planets", item = "Favour_" .. f[2] .. "_2", target = 4,
                              pre = { base .. ".UpgradeA" } }
end
M.UNLOCKS = UNLOCKS

-- pure: the unlocks one event counts towards. ev = { stat, n, item = his test kind | nil, style = his style key,
-- favours = { "Favour_X_n", ... } } -> list
function M.matching(ev)
    local out = {}
    if type(ev) ~= "table" then return out end
    for _, u in ipairs(UNLOCKS) do
        if u.stat == ev.stat then
            local ok = u.item == nil
            if not ok and ev.stat == "planets" then
                for _, id in ipairs(ev.favours or {}) do if id == u.item then ok = true end end
            elseif not ok and ev.stat == "fieldtest" then ok = ev.item == u.item
            elseif not ok then ok = ev.style == u.item end
            if ok then out[#out + 1] = u end
        end
    end
    return out
end

---------------------------------------------------------------------------------------------------- the game (seams)
-- M.io: unlocked(tag) -> bool | nil, unlock(tag) -> bool, native(tag) -> number | nil, meta() -> MetaProgression | nil,
-- store() -> the persisted table (couchrun's G.meta), save(). Tests replace it.
local function lib() return U.cdo("/Script/Griffin.Default__BlueprintSPUnlockSystemLibrary") end
local function unlockSub()
    local ok, sub = pcall(FindFirstOf, "SPUnlockSubsystem")
    return (ok and U.ok(sub)) and sub or nil
end
M.io = {}
function M.io.unlocked(tag)
    local l, sub = lib(), unlockSub()
    if not (U.ok(l) and sub) then return nil end
    local ok, v = pcall(function() return l:IsTagUnlocked(sub, { TagName = U.fname(tag) }) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end
function M.io.unlock(tag)
    local l, sub = lib(), unlockSub()
    if not (U.ok(l) and sub) then return false end
    return pcall(function() l:UnlockTag(sub, { TagName = U.fname(tag) }) end)
end
function M.io.native(tag)
    local okT, tr = pcall(FindFirstOf, "GameplayStatTracker")
    if not (okT and U.ok(tr)) then return nil end
    local out = {}
    local ok, found = pcall(function()
        return tr:FindTrackedUnlockProgress(U.fname(M.CONTEXT), { TagName = U.fname(tag) }, out)
    end)
    if not (ok and found == true) then return nil end
    local v = nil
    pcall(function() v = tonumber(out.CurrentStatValue) end)
    if v == nil then pcall(function() v = tonumber(out.TrackedUnlock.CurrentStatValue) end) end
    return v
end
function M.io.meta()
    local ok, cs = pcall(FindFirstOf, "CampaignSubsystem")
    if not (ok and U.ok(cs)) then return nil end
    local m = nil
    pcall(function() m = cs.MetaProgression end)
    return U.ok(m) and m or nil
end
function M.io.store()
    local ok, t = pcall(function() return U.mod("couchrun").metaStore() end)
    return (ok and type(t) == "table") and t or nil
end
function M.io.save() pcall(function() U.mod("couchrun").save() end) end

local function on() return opt("CouchShareMeta", true) ~= false end

local function store()
    local t = M.io.store()
    if not t then return nil end
    t.counts = type(t.counts) == "table" and t.counts or {}
    t.seen = type(t.seen) == "table" and t.seen or {}
    t.order = type(t.order) == "table" and t.order or {}
    return t
end

-- an event key seen before -> true; else remembered (the last 400 kept) -> false
local function seenBefore(t, key)
    if t.seen[key] then return true end
    t.seen[key] = true
    t.order[#t.order + 1] = key
    while #t.order > 400 do
        local old = table.remove(t.order, 1)
        t.seen[old] = nil
    end
    return false
end

-- is this unlock open (prerequisites unlocked, itself not yet)? -> bool, why
local function open(u)
    local done = M.io.unlocked(u.tag)
    if done == true then return false, "already unlocked" end
    for _, p in ipairs(u.pre or {}) do
        if M.io.unlocked(p) ~= true then return false, "needs " .. p end
    end
    return true
end

---------------------------------------------------------------------------------------------------- events
-- one guest's qualifying event. key: once per key (nil = always); pnum for the log. -> unlocked tags
function M.count(key, pnum, ev)
    if not on() or type(ev) ~= "table" then return {} end
    local n = math.floor(tonumber(ev.n) or 1)
    if n <= 0 then return {} end
    local list = M.matching(ev)
    if #list == 0 then return {} end
    local t = store()
    if not t then return {} end
    if key and seenBefore(t, key) then return {} end
    local got, notes = {}, {}
    -- open BEFORE the event (an unlock this event completes does not open its upgrade for the same event)
    local wasOpen = {}
    for i, u in ipairs(list) do wasOpen[i] = open(u) end
    for i, u in ipairs(list) do
        if wasOpen[i] then
            t.counts[u.tag] = (tonumber(t.counts[u.tag]) or 0) + n
            local native = tonumber(M.io.native(u.tag)) or 0
            local total = native + t.counts[u.tag]
            notes[#notes + 1] = string.format("%s %g+%d/%g", u.tag, native, t.counts[u.tag], u.target)
            if total >= u.target then
                if M.io.unlock(u.tag) then
                    got[#got + 1] = u.tag
                    t.counts[u.tag] = nil
                    U.log(TAG, "%s UNLOCKED on P1's account: P1's own %g + the guests' %d >= %g (P%s's %s)", u.tag,
                        native, total - native, u.target, tostring(pnum), ev.stat)
                else
                    U.warn(TAG, "%s: UnlockTag failed (the guests' count kept)", u.tag)
                end
            end
        end
    end
    M.io.save()
    if #notes > 0 then
        U.log(TAG, "P%s's %s x%d (%s) counted for P1's account: %s", tostring(pnum), ev.stat, n,
            tostring(ev.item or ev.style or "-"), table.concat(notes, ", "))
    end
    return got
end

-- tuning / kit points onto P1's meta wallet, once per key -> tp, kp added
function M.addPoints(key, pnum, tp, kp, why)
    tp, kp = math.max(0, math.floor(tonumber(tp) or 0)), math.max(0, math.floor(tonumber(kp) or 0))
    if not on() or (tp == 0 and kp == 0) then return 0, 0 end
    local t = store()
    if not t then return 0, 0 end
    if key and seenBefore(t, key) then return 0, 0 end
    local m = M.io.meta()
    if not m then
        U.warn(TAG, "P%s's %d tuning / %d kit points: no meta profile readable (%s)", tostring(pnum), tp, kp, tostring(why))
        M.io.save()
        return 0, 0
    end
    local addT, addK = 0, 0
    pcall(function()
        local cur = math.floor(tonumber(m.TuningPointsToSpend) or 0)
        local nv = math.min(M.TP_MAX, cur + tp)
        if nv ~= cur then m.TuningPointsToSpend = nv; addT = nv - cur end
    end)
    pcall(function()
        local cur = math.floor(tonumber(m.KitPointsToSpend) or 0)
        local nv = math.min(M.KP_MAX, cur + kp)
        if nv ~= cur then m.KitPointsToSpend = nv; addK = nv - cur end
    end)
    M.io.save()
    U.log(TAG, "P%s's points onto P1's account (%s): +%d tuning, +%d kit", tostring(pnum), tostring(why), addT, addK)
    return addT, addK
end

-- couchrun.onRaceEnd, per guest: his completed event -> TP / KP, field test / style counters. r = { visit (run:node
-- key), seat, pnum, kind, aloneKind, pos, wrecked, sitOut, takedowns, style, tp, kp }
function M.raceEnd(r)
    if not on() or type(r) ~= "table" or r.sitOut or r.wrecked then return end
    local pos = tonumber(r.pos) or 99
    if pos <= 0 or pos >= 99 then return end
    local k = string.format("%s:%s", tostring(r.visit), tostring(r.seat))
    U.try(TAG, M.addPoints, k .. ":points", r.pnum, r.tp, r.kp, "completed " .. tostring(r.kind))
    if r.aloneKind or r.kind == "fieldtest" then
        U.try(TAG, M.count, k .. ":fieldtest", r.pnum, { stat = "fieldtest", item = r.aloneKind })
    end
    U.try(TAG, M.count, k .. ":events", r.pnum, { stat = "events", style = r.style })
    if pos == 1 then U.try(TAG, M.count, k .. ":wins", r.pnum, { stat = "wins", style = r.style }) end
    local td = math.floor(tonumber(r.takedowns) or 0)
    if td > 0 then U.try(TAG, M.count, k .. ":takedowns", r.pnum, { stat = "takedowns", n = td, style = r.style }) end
end

-- a planet he raced is behind the run: his favours held there -> PlanetsCompleted
function M.planetDone(key, pnum, favours)
    local list = {}
    for _, id in ipairs(favours or {}) do if id then list[#list + 1] = id end end
    if #list == 0 then return {} end
    return M.count(key, pnum, { stat = "planets", favours = list })
end

return M
