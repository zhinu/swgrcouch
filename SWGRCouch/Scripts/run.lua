-- run.lua: GALAXY RUN v3 "LEAGUE RUN" - the game's real rogue mode (the campaign "Run") rebuilt for 1-4 couch
-- players (design notes/design/galaxy-run-v3.md; research notes/research/rogue-mode/00-ANALYSIS.md).
--
-- Mod-owned: the run lives in Mods/SWGRCouch/run.txt (+ run-history.txt). It never opens, continues or abandons the
-- game's CAMPAIGN / tour and never writes the game's save. The CONTENT is the campaign's, baked into rundata.lua
-- (generated from the decoded assets by galactic-racer/scripts/gen-rundata.py):
--   * presets = the real Acts: QUALIFIER (Act I planets, Championship vs Sebulba), LEAGUE (Act II, Gauntlet +
--     Championship vs Kestar), KESTAR'S LEAGUE (Act III, podracer finale), SPRINT (short Act I cut);
--   * per planet a seeded NODE MAP (the campaign's map-gen rules: 3 starting paths, per-column path joins, weighted
--     activities with the real no-repeat list); the team picks the next node (the picker cycles with RIGHT);
--   * node kinds v3.0: RACE (standard), ELIMINATOR (high risk: best human top 3 or -1 token), FIELD TEST
--     (humans-only, everybody finishes), PODRACER TEST (Act III pods interlude, token on a miss) and the boss
--     events GALACTIC GAUNTLET / CHAMPIONSHIP RACE (must-win: -1 token and the same event again);
--   * LEAGUE TOKENS are the lives (the campaign's strikes; R.hull keeps its name for the consumers): lost on a
--     missed eliminator / plane target, a lost boss event and a race every human wrecked out of; 0 = RUN LOST;
--   * CREDITS use the real payout tables (position x planet depth, eliminators pay one planet ahead, skipping a
--     reward pays the real skip bonus) and the real shop prices; a wreck turns a part FAULTY (repair = real price);
--   * rewards are rarity-rolled with the real per-planet ramp, mapped onto the mod's perk grades (real affixes are
--     the v3.3 research item).
-- The launch/result plumbing is unchanged (prelaunch <- launch.lua, snapshot <- POSTRACE edge, settle <- FRONTEND);
-- every game read is pcall-guarded; the module never touches a front-end widget (lobby / setup / racers render).
local U = require("util")
local St = require("state")
local cfg = require("config")
local settings = require("settings")

local TAG = "run"
local M = {}

local okD, D = pcall(require, "rundata")
if not okD or type(D) ~= "table" then D = nil end

local POINTS = { 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 }
local RIVAL_BONUS = 500
local FILE, HISTORY = "run.txt", "run-history.txt"

local R = nil            -- the run (persisted); nil = none
local loaded = false

local function K() return U.mod("perks") end
local function P() return U.mod("pilots") end
local function V() return U.mod("vehicles") end
local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

---------------------------------------------------------------------------------------------------- persistence
local function path(name)
    local ok, d = pcall(function() return settings.modDir() end)
    if not ok or type(d) ~= "string" then return nil end
    return d .. "/" .. name
end

local function open(name, mode)
    local p = path(name)
    if not p then return nil, "no mod folder" end
    return io.open(p, mode)
end

local function ser(v, ind)
    local t = type(v)
    if t == "number" then return (math.type(v) == "integer") and tostring(v) or string.format("%.17g", v) end
    if t == "boolean" then return tostring(v) end
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return "nil" end
    ind = ind or ""
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    local out = { "{" }
    for _, k in ipairs(keys) do
        local kv = v[k]
        if type(kv) ~= "function" then
            local ks = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or ("[" .. ser(k) .. "]")
            out[#out + 1] = ind .. "  " .. ks .. " = " .. ser(kv, ind .. "  ") .. ","
        end
    end
    out[#out + 1] = ind .. "}"
    return table.concat(out, "\n")
end
M._ser = ser

local function save()
    if not R then
        local f = open(FILE, "w")
        if f then f:write("return nil\n"); f:close() end
        return
    end
    local f, err = open(FILE, "w")
    if not f then U.warn(TAG, "run.txt not written: %s", tostring(err)); return end
    f:write("-- SWGRCouch GALAXY RUN (mod-owned; delete this file to drop the run)\nreturn " .. ser(R) .. "\n")
    f:close()
end

local function loadFile()
    loaded = true
    local f = open(FILE, "r")
    if not f then return end
    local text = f:read("a")
    f:close()
    local chunk = load(text, "run.txt", "t", {})
    if not chunk then U.warn(TAG, "run.txt unreadable: the run starts over"); return end
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" and t.v == 3 and type(t.players) == "table" then
        R = t
        U.log(TAG, "run loaded: %s (%s), race %d of %d, tokens %d, %d player(s)", tostring(R.status),
            tostring(R.preset), R.race or 0, R.length or 0, R.hull or 0, M.playerCount())
    elseif ok and type(t) == "table" and t.v ~= nil then
        U.warn(TAG, "run.txt is a v%s run (this build plays v3): ignored, a new run starts fresh", tostring(t.v))
    end
end

local function ensureLoaded() if not loaded then loadFile() end end

local function archive(outcome)
    local f = open(HISTORY, "a")
    if not f then return end
    local list = {}
    for c, p in pairs(R.players) do list[#list + 1] = { name = tostring(p.name or ("P" .. c)), pts = p.points or 0 } end
    table.sort(list, function(a, b) if a.pts ~= b.pts then return a.pts > b.pts end return a.name < b.name end)
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = string.format("%s %d pts", e.name, e.pts) end
    f:write(string.format("%s  %s  %s %s  races %d/%d  tokens %d  %s\n", os.date("%Y-%m-%d %H:%M"), outcome,
        tostring(R.preset), tostring(R.classKey), math.min(R.race - 1, R.length), R.length, R.hull,
        table.concat(parts, ", ")))
    f:close()
end

---------------------------------------------------------------------------------------------------- presets / data
-- v3.0 node kinds the map generator may roll (blackmarket / mystery nodes are v3.1; their weight is simply ignored).
local SUPPORTED = { standard = true, highrisk = true, fieldtest = true }

local function presetOf(key) return D and D.presets and D.presets[key] or nil end

local function days()
    local n = math.floor(tonumber(opt("RunDays", 3)) or 3)
    return math.max(2, math.min(5, n))
end

-- total events of a preset at the current RunDays
local function lengthOf(pre) return days() * #pre.planets + #pre.boss end

-- ordered preset list for the lobby cycle: key, label, races
local PRESET_ORDER = { "qualifier", "league", "kestar", "sprint" }
function M.presets()
    local out = {}
    for _, k in ipairs(PRESET_ORDER) do
        local pre = presetOf(k)
        if pre then out[#out + 1] = { key = k, label = pre.label, races = lengthOf(pre) } end
    end
    return out
end

function M.presetLabel(key)
    local pre = presetOf(key)
    if not pre then return string.upper(tostring(key or "?")) end
    return string.format("%s (%d RACES)", pre.label, lengthOf(pre))
end

-- a SHORT name for narrow texts (the poster kicker fits ~515 su; the full act titles do not)
local SHORT = { qualifier = "THE QUALIFIER", league = "THE LEAGUE", kestar = "KESTAR'S LEAGUE", sprint = "SPRINT" }
function M.presetName(key)
    if SHORT[key] then return SHORT[key] end
    local pre = presetOf(key)
    return pre and pre.label or string.upper(tostring(key or "?"))
end

---------------------------------------------------------------------------------------------------- queries
function M.playerCount()
    local n = 0
    for _ in pairs(R and R.players or {}) do n = n + 1 end
    return n
end
function M.state() ensureLoaded(); return R end
function M.active() ensureLoaded(); return R ~= nil and R.status == "on" end
function M.inFlight() return M.active() and R.flight ~= nil end
function M.betweenRaces() return M.active() and R.flight == nil and R.race > 1 end

-- OPTIONS > Galaxy run: the armed preset key ("qualifier" | "league" | "kestar" | "sprint"), nil = off/unknown.
function M.lengthSetting()
    local v = tostring(settings.get("RunLength") or "off")
    if presetOf(v) then return v end
    return nil
end

-- AI tier of race i (speeders; 1 = the zero base): TIER 1 at the start, TIER 6 at the final.
function M.tierFor(i, len)
    if len <= 1 then return 1 end
    return math.max(1, math.min(6, 1 + math.floor((i - 1) * 5 / (len - 1) + 0.5)))
end

local function ordinal(n)
    local s = ({ "ST", "ND", "RD" })[n] or "TH"
    if n >= 11 and n <= 13 then s = "TH" end
    return tostring(n) .. s
end

---------------------------------------------------------------------------------------------------- events
-- v3: the campaign's node kinds. Every node is still a normal race scored by the mod per player (the game's own
-- challenge modes track ONE player, 04-mod-surface.md); rank "place" | "time" decides the human ranking.
local EVENT = {
    standard    = { name = "RACE",              mode = "race",       rank = "place",
                    rule = "Finish as high as you can: the payout follows your place." },
    highrisk    = { name = "ELIMINATOR",        mode = "eliminator", rank = "place", speeders = true, target = "TOP 3",
                    rule = "The best player must finish in the top three or the team loses a League Token." },
    fieldtest   = { name = "FIELD TEST",        mode = "race",       rank = "time",  humansOnly = true,
                    rule = "No AI: the fastest race time wins. Finish it for the payout." },
    planesprint = { name = "PODRACER TEST",     mode = "race",       rank = "time",  humansOnly = true,
                    classOver = "Plane", target = "EVERYBODY FINISHES",
                    rule = "A podracer time trial. Everybody finishes, or the team loses a League Token." },
    knockout    = { name = "GALACTIC GAUNTLET", mode = "fullgrid",   rank = "place", mustWin = true, target = "WIN",
                    rule = "Full grid, must-win: lose it and it costs a League Token to try again." },
    champion    = { name = "CHAMPIONSHIP RACE", mode = "fullgrid",   rank = "place", mustWin = true, target = "WIN",
                    rule = "The boss race, must-win: lose it and it costs a League Token to try again." },
}
M.EVENT = EVENT

function M.eventOf(kind)
    local ev = EVENT[kind or "standard"] or EVENT.standard
    if D and D.strings and D.strings.kinds and D.strings.kinds[kind] then
        -- real player-facing names from the game's localization
        ev = setmetatable({ name = D.strings.kinds[kind] }, { __index = ev })
    end
    return ev
end

-- "TOP 3" / "EVERYBODY FINISHES" / "WIN" for the next event; nil = no team target (standard / field test).
function M.targetText(kind)
    return (EVENT[kind or "standard"] or EVENT.standard).target
end

-- One status line for the FREE MODE pill / the racer cards.
function M.statusText()
    ensureLoaded()
    if not R then return nil end
    if R.status == "won" then return "GALAXY RUN WON! " .. M.leaderText() end
    if R.status == "lost" then
        return string.format("GALAXY RUN LOST AT RACE %d (%s) · %s", R.race - 1,
            (D and D.strings and D.strings.outOfTokens) or "OUT OF LEAGUE TOKENS", M.leaderText())
    end
    local kind = (R.next and R.next.kind) or (R.flight and R.flight.kind) or "standard"
    if R.race == 1 then kind = "standard" end
    local parts = { string.format("GALAXY RUN · RACE %d / %d", R.race, R.length), M.eventOf(kind).name,
                    "TOKENS " .. tostring(R.hull) }
    local t = M.targetText(kind)
    if t then parts[#parts + 1] = "TARGET " .. t end
    return table.concat(parts, " · ")
end

function M.leaderText()
    local best, bp = nil, -1
    for _, p in pairs(R and R.players or {}) do
        if (p.points or 0) > bp then best, bp = p, p.points or 0 end
    end
    return best and string.format("MVP %s %d PTS", tostring(best.name or "?"), bp) or ""
end

-- Standings for the lobby's GALAXY RUN card: "P1 43 · P2 31 · TOKENS 2" (points order; nil without a run).
function M.standingsText()
    ensureLoaded()
    if not R or M.playerCount() == 0 then return nil end
    local list = {}
    for _, p in pairs(R.players) do list[#list + 1] = p end
    table.sort(list, function(a, b)
        if (a.points or 0) ~= (b.points or 0) then return (a.points or 0) > (b.points or 0) end
        return (a.pnum or 9) < (b.pnum or 9)
    end)
    local parts = {}
    for _, p in ipairs(list) do parts[#parts + 1] = string.format("%s %d", tostring(p.name or "?"), p.points or 0) end
    if R.status == "on" then parts[#parts + 1] = "TOKENS " .. tostring(R.hull) end
    return table.concat(parts, " · ")
end

-- Per-player rows for the GALAXY RUN page (points order; pending = a reward or shop pick waits on the card).
function M.standingsRows()
    ensureLoaded()
    if not R then return {} end
    local list = {}
    for _, p in pairs(R.players) do
        list[#list + 1] = { name = tostring(p.name or "?"), points = p.points or 0, credits = p.credits or 0,
                            cap = p.cap or 1,
                            pending = (type(p.offer) == "table" and #p.offer > 0) or p.offerPending == true
                                or p.shopPending == true }
    end
    table.sort(list, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        return a.name < b.name
    end)
    return list
end

-- Card line: "RUN 43 PTS · 2ND · 1250 CREDITS · CAP 3" (nil without a run player).
function M.cardLine(ctrlId)
    if not M.active() then return nil end
    local p = R.players[ctrlId]
    if not p then return nil end
    local rank = 1
    for c, o in pairs(R.players) do if c ~= ctrlId and (o.points or 0) > (p.points or 0) then rank = rank + 1 end end
    return string.format("RUN %d PTS · %s · %d CREDITS · CAP %d", p.points or 0, ordinal(rank), p.credits or 0, p.cap or 1)
end

---------------------------------------------------------------------------------------------------- map generation
-- The campaign's per-planet node graph (02-data-assets.md §2), reimplemented on the real rules from rundata:
-- width starts at startingPaths (3) and shrinks by the per-column join chance; node kinds are rolled from the act's
-- weighted activity tables (first node of planet / first planet / default) with the real no-repeat list. v3.0 keeps
-- the race-type kinds only (SUPPORTED); blackmarket / mystery weights are ignored until v3.1. Act III planets may
-- roll PODRACER TEST (a pods interlude for any run class). Seeded by R.seed: the same run file = the same maps.
local function actRules(act)
    local a = D and D.mapgen and D.mapgen.acts and D.mapgen.acts[act] or nil
    return a or { joins = { 0, 25, 50, 75, 100 }, noRepeat = {}, weights = {} }
end

local function rollKind(weights, act, prevKind)
    local rules = actRules(act)
    local noRep = {}
    for _, k in ipairs(rules.noRepeat or {}) do noRep[k] = true end
    local function roll(exclude)
        local pool, total = {}, 0
        for k, w in pairs(weights or {}) do
            local okKind = SUPPORTED[k] or (k == "planesprint" and act == 3)
            if okKind and k ~= exclude and (tonumber(w) or 0) > 0 then
                pool[#pool + 1] = { k = k, w = tonumber(w) }
                total = total + tonumber(w)
            end
        end
        if total <= 0 then return "standard" end
        local r = math.random() * total
        for _, e in ipairs(pool) do
            r = r - e.w
            if r <= 0 then return e.k end
        end
        return pool[#pool].k
    end
    local kind = roll(nil)
    if prevKind and kind == prevKind and noRep[kind] then kind = roll(kind) end
    return kind
end

-- one planet's map: { days = N, cols = { [c] = { "standard", ... } } } (cols[c][i] = the node kind)
local function genPlanetMap(act, planetIdx, firstPlanet)
    local rules = actRules(act)
    local d = days()
    local w = math.max(1, math.min(3, math.floor(tonumber(D and D.mapgen and D.mapgen.startingPaths) or 3)))
    local map = { days = d, cols = {} }
    for c = 1, d do
        if c > 1 and w > 1 then
            local joins = rules.joins or {}
            local chance = tonumber(joins[math.min(c, #joins)] or 0) or 0
            if math.random() * 100 < chance then w = w - 1 end
        end
        local tbl = (c == 1) and (rules.weights.firstNodeOfPlanet or rules.weights.default)
            or (firstPlanet and (rules.weights.firstPlanet or rules.weights.default))
            or rules.weights.default
        map.cols[c] = {}
        for i = 1, w do
            local prev = nil
            if c > 1 then
                local pw = #map.cols[c - 1]
                prev = map.cols[c - 1][math.max(1, math.min(pw, i))]
            end
            local kind
            if planetIdx == 1 and c == 1 then
                kind = "standard"                      -- the campaign's FirstNodeOfTour table is standard-only
            else
                kind = rollKind(tbl, act, prev)
            end
            map.cols[c][i] = kind
        end
    end
    return map
end

local function genMaps(pre)
    local maps = {}
    for p = 1, #pre.planets do maps[p] = genPlanetMap(pre.act, p, p == 1) end
    return maps
end

---------------------------------------------------------------------------------------------------- builds
local KINDS = { "ab", "crash", "part", "trait" }

local function emptyOwned() return { ab = {}, crash = {}, part = {}, trait = {} } end

local function addOwned(owned, lo)
    for n = 1, 4 do if lo.ab and lo.ab[n] then owned.ab[lo.ab[n]] = true end end
    if lo.crash then owned.crash[lo.crash] = true end
    for _, id in pairs(lo.parts or {}) do if id then owned.part[id] = true end end
    for _, id in pairs(lo.traits or {}) do if id then owned.trait[id] = true end end
end

-- The starter: the pilot's own kit, its first 2 abilities, every level 0, no crash ability / parts / traits.
function M.starter(arch, style)
    local Km = K()
    local lo = Km.fromKit("pilot", arch, style)
    local kept = 0
    for n = 1, 4 do
        if lo.ab[n] and kept < 2 then kept = kept + 1 else lo.ab[n] = false end
    end
    lo.crash = false
    for i in pairs(lo.parts or {}) do lo.parts[i] = false end
    for i in pairs(lo.traits or {}) do lo.traits[i] = false end
    for s = 0, 5 do lo.tune[s] = 0 end
    lo.kit = "custom"
    return Km.validate(lo, arch, style)
end

-- Keeps a build to what the player owns and to its level cap (a card edit, a decoded code, a stale file).
function M.sanitize(lo, p, arch, style)
    if type(lo) ~= "table" or not p then return lo end
    local o = p.owned or emptyOwned()
    for n = 1, 4 do if lo.ab[n] and not o.ab[lo.ab[n]] then lo.ab[n] = false end end
    if lo.crash and not o.crash[lo.crash] then lo.crash = false end
    for i, id in pairs(lo.parts or {}) do
        if id and (not o.part[id] or (p.broken or {})[id]) then lo.parts[i] = false end   -- faulty = unusable
    end
    for i, id in pairs(lo.traits or {}) do if id and not o.trait[id] then lo.traits[i] = false end end
    local cap = p.cap or 1
    for s = 0, 5 do if (lo.tune[s] or 0) > cap then lo.tune[s] = cap end end
    lo.kit = "custom"
    return K().validate(lo, arch, style)
end

local function styleOf(pilotId, arch)
    local ok, s = pcall(function() return P().styleKey(pilotId, arch) end)
    return ok and s or nil
end

-- The run build of a card (a validated copy) or nil (no run / not in the run).
function M.buildFor(ctrlId, arch, style)
    if not M.active() then return nil end
    local p = R.players[ctrlId]
    if not p or type(p.lo) ~= "table" or tonumber(arch) ~= tonumber(R.arch) then return nil end
    return M.sanitize(K().copy(p.lo), p, arch, style)
end

function M.capFor(ctrlId)
    local p = M.active() and R.players[ctrlId] or nil
    return p and (p.cap or 1) or nil
end

-- perks picker filter for one card: owned perks only (EMPTY / NONE rows stay).
function M.filterFor(ctrlId)
    if not M.active() then return nil end
    local p = R.players[ctrlId]
    if not p then return nil end
    local o = p.owned or emptyOwned()
    return function(kind, id)
        if id == false or id == nil then return true end
        local set = o[kind]
        if set == nil then return true end           -- styles: free
        if kind == "part" and (p.broken or {})[id] then return false end   -- faulty until repaired
        return set[id] == true
    end
end

local function ensurePlayer(ctrlId, pnum, pilotId, name)
    local p = R.players[ctrlId]
    if not p then
        local style = styleOf(pilotId, R.arch)
        local lo = M.starter(R.arch, style)
        local owned = emptyOwned()
        addOwned(owned, lo)
        p = { pnum = pnum, name = name or ("P" .. tostring(pnum)), points = 0, cap = 1, lo = lo, owned = owned,
              offer = nil, wins = 0, joinedAt = R.race, credits = 0 }
        R.players[ctrlId] = p
        if R.race > 1 then p.offerPending = true end   -- a late joiner gets one free pick
        U.log(TAG, "P%s joins the run on a starter build (%s)", tostring(pnum), tostring(lo.kit))
    end
    p.pnum = pnum or p.pnum
    if name then p.name = name end
    return p
end

---------------------------------------------------------------------------------------------------- rewards
-- Every perk the class offers, per kind, as picker rows (perks.picker / pickerCat over each category).
local function catalog(arch)
    local Km = K()
    local lo = M.starter(arch, nil)
    local out = { ab = {}, crash = {}, part = {}, trait = {} }
    for _, slot in ipairs({ "ab1", "crash", "part1", "trait1" }) do
        local kind = Km.slotKind(slot)
        local pk = Km.picker(lo, slot, arch)
        if pk then
            for ci = 1, #pk.cats do
                local items = Km.pickerCat(lo, slot, arch, ci)
                for _, it in ipairs(items or {}) do
                    if it.id and not it.inert and not it.faulty then
                        local row = {}
                        for k, v in pairs(it) do row[k] = v end
                        row.slot, row.rkind, row.equipped, row.usedBy = slot, kind, nil, nil
                        out[kind][#out[kind] + 1] = row
                    end
                end
            end
        end
    end
    return out
end

local function pickFrom(list, owned, taken)
    local pool = {}
    for _, it in ipairs(list) do
        if not owned[it.id] and not taken[it.rkind .. ":" .. tostring(it.id)] then pool[#pool + 1] = it end
    end
    if #pool == 0 then return nil end
    local it = pool[math.random(#pool)]
    taken[it.rkind .. ":" .. tostring(it.id)] = true
    return it
end

-- The campaign's rarity ramp mapped onto the mod's perk grades (v3.0 adaptation; real affixes = v3.3):
-- grade 1 (Common) = level/pips 1 items, 2 (Rare) = level/pips 2 or a trait, 3 (Epic) = level/pips 3 or a crash
-- ability, 4 (Legendary) = a trait / crash / the level-cap upgrade.
local function gradeOf(it)
    if it.rkind == "ab" then return math.max(1, math.min(3, tonumber(it.lvl) or 1)) end
    if it.rkind == "part" then return math.max(1, math.min(3, tonumber(it.pips) or 1)) end
    if it.rkind == "crash" then return 3 end
    if it.rkind == "trait" then return 2 end
    if it.rkind == "upgrade" then return 4 end
    return 1
end

-- planet slot of the current/last node (1..5; the boss events use the slot after the last planet, clamped).
local function slotOf(p, boss)
    if not R then return 1 end
    local n = boss and (#(presetOf(R.preset) or { planets = {} }).planets + 1) or (p or (R.cursor and R.cursor.p) or 1)
    return math.max(1, math.min(5, n))
end

local function rarityRoll(slot, pool)
    local tbl = D and D.rarity and D.rarity[pool or "event"] or nil
    local w = tbl and (tbl[math.min(slot, #tbl)] or tbl[#tbl]) or { 60, 25, 10, 5 }
    local total = 0
    for i = 1, 4 do total = total + (tonumber(w[i]) or 0) end
    if total <= 0 then return 1 end
    local r = math.random() * total
    for i = 1, 4 do
        r = r - (tonumber(w[i]) or 0)
        if r <= 0 then return i end
    end
    return 1
end

local function upgradeRow()
    return { id = "upgrade", name = "UPGRADE: LEVEL CAP +1", rkind = "upgrade", slot = "tun0", iconKind = "glyph" }
end

-- a rare team reward while tokens are missing (one player's pick buys one back for everyone)
local function tokenRow()
    return { id = "repair", name = "LEAGUE TOKEN +1", rkind = "repair", slot = "tun2", iconKind = "glyph" }
end
local TOKEN_CHANCE = 0.15

local function skipRow(slot)
    local skipT = D and D.payouts and D.payouts.skip or { 1000, 2000, 3000, 4000, 5000 }
    local cr = math.floor((tonumber(skipT[math.min(slot, #skipT)]) or 1000) * (tonumber(opt("RunPayoutScale", 1)) or 1))
    return { id = "skip", name = string.format("SKIP: +%d CR", cr), rkind = "skip", slot = "tun1",
             iconKind = "glyph", credits = cr }
end

-- grade-biased pick: items of the rolled grade first, a neighbour grade next, anything last.
local function pickGraded(cat, o, taken, grade)
    local kinds = { "ab", "part", "trait" }
    if grade >= 3 and #cat.crash > 0 then kinds[#kinds + 1] = "crash" end
    for _, pass in ipairs({ 0, 1, 99 }) do
        local ks = { kinds[math.random(#kinds)], kinds[math.random(#kinds)], "ab", "part", "trait", "crash" }
        for _, k in ipairs(ks) do
            local list = {}
            for _, it in ipairs(cat[k] or {}) do
                if math.abs(gradeOf(it) - grade) <= pass then list[#list + 1] = it end
            end
            local it = pickFrom(list, o[k] or {}, taken)
            if it then return it end
        end
    end
    return nil
end

-- The reward offer after a node (3 rows, 4 for the last human) + the SKIP row: rarities rolled with the real
-- per-planet ramp; a Legendary roll may be the level-cap upgrade; a missing token may replace the last row.
function M.makeOffer(p, n)
    local cat = catalog(R.arch)
    local slot = slotOf(R.lastSlot, false)
    local pool = (R.lastKind == "highrisk") and "highrisk" or "event"
    local o, taken, out = p.owned or emptyOwned(), {}, {}
    for _ = 1, n do
        local g = rarityRoll(slot, pool)
        local it = nil
        if g == 4 and math.random() < 0.5 then it = upgradeRow() end
        it = it or pickGraded(cat, o, taken, g)
        if not it then it = upgradeRow() end
        local dup = false
        for _, e in ipairs(out) do if e.rkind == it.rkind and e.id == it.id and it.rkind == "upgrade" then dup = true end end
        if not dup then out[#out + 1] = it end
    end
    if #out == 0 then out[1] = upgradeRow() end
    if R.hull < (R.tokensMax or R.hull) and
        math.random() < (tonumber(opt("RunRepairChance", TOKEN_CHANCE)) or TOKEN_CHANCE) then
        out[#out] = tokenRow()                       -- replaces the last offer
    end
    out[#out + 1] = skipRow(slot)
    return out
end

-- The reward picker of a card (racers.lua opens it on PERKS), nil when nothing is offered.
function M.offerPicker(ctrlId)
    if not M.active() then return nil end
    local p = R.players[ctrlId]
    if not p then return nil end
    if p.offerPending and not p.offer then p.offer = M.makeOffer(p, 3); p.offerPending = nil; save() end
    if not p.offer or #p.offer == 0 then return nil end
    return { slot = p.offer[1].slot, kind = "reward", cats = { { key = "reward", name = "RUN REWARD · PICK ONE" } },
             cat = 1, items = p.offer, sel = 1 }
end

-- A reward claimed on a card: owned + equipped into a free slot of its kind (the player may move it on PERKS).
-- -> the new run build (a validated copy for the card), a toast.
function M.claim(ctrlId, item, arch, style)
    if not M.active() or type(item) ~= "table" then return nil end
    local p = R.players[ctrlId]
    if not p then return nil end
    local Km = K()
    local toastText
    local lo = Km.copy(p.lo)
    if item.rkind == "upgrade" then
        p.cap = (p.cap or 1) + 1
        toastText = "LEVEL CAP " .. p.cap
    elseif item.rkind == "repair" then
        R.hull = math.min(R.tokensMax or R.hull + 1, R.hull + 1)
        toastText = "LEAGUE TOKENS " .. R.hull
        St.emit("status", string.format("P%s BOUGHT A LEAGUE TOKEN BACK: %d", tostring(p.pnum), R.hull))
    elseif item.rkind == "skip" then
        local cr = math.floor(tonumber(item.credits) or 0)
        p.credits = (p.credits or 0) + cr
        toastText = string.format("REWARD SKIPPED: +%d CR", cr)
    else
        p.owned[item.rkind] = p.owned[item.rkind] or {}
        p.owned[item.rkind][item.id] = true
        local slot
        if item.rkind == "ab" then
            for n = 1, 4 do if not lo.ab[n] then slot = "ab" .. n; break end end
        elseif item.rkind == "crash" then
            if not lo.crash then slot = "crash" end
        elseif item.rkind == "part" then
            for i = 1, Km.partSlots() do if not lo.parts[i] then slot = "part" .. i; break end end
        elseif item.rkind == "trait" then
            for i = 1, Km.traitSlots() do if not lo.traits[i] then slot = "trait" .. i; break end end
        end
        if slot then pcall(function() Km.equip(lo, slot, item.id, arch, style) end) end
        toastText = "UNLOCKED: " .. tostring(item.name or item.id)
    end
    p.offer = nil
    p.lo = M.sanitize(lo, p, arch, style)
    save()
    U.log(TAG, "P%s claims %s %s (cap %d)", tostring(p.pnum), tostring(item.rkind), tostring(item.id), p.cap or 1)
    return Km.copy(p.lo), toastText
end

---------------------------------------------------------------------------------------------------- races
local function tierPath(arch, i)
    if tonumber(arch) == 1 or i <= 1 then return nil end
    local ok, list = pcall(function() return V().builds(arch) end)
    if not ok or type(list) ~= "table" or not list[i] then return nil end
    return list[i].path
end

local function candidates(classKey)
    local setup = U.mod("setup")
    if type(setup.runCandidates) ~= "function" then return {} end
    local ok, cands = pcall(setup.runCandidates, classKey or R.classKey)
    return (ok and type(cands) == "table") and cands or {}
end

-- the launch mode of an event on a candidate track (eliminator needs track support; pods have no eliminator)
local function modeFor(ev, cand)
    local modes = {}
    for _, m in ipairs(cand.modes or { "race" }) do modes[m] = true end
    if ev.mode == "eliminator" and (tonumber(R.arch) == 1 or not modes.eliminator) then
        return modes.fullgrid and "fullgrid" or "race"
    end
    if modes[ev.mode] then return ev.mode end
    if ev.mode == "fullgrid" and modes.race then return "race" end
    return (cand.modes or {})[1] or "race"
end

-- A track for a node on a planet: the campaign's weighted track table for that planet (rundata tracks, matched into
-- the candidate's TrackDef full name) over the class's real candidates; unused tracks first, the planet first.
local function trackFor(planetKey, ev, classKey)
    local cands = candidates(classKey)
    if #cands == 0 then return nil end
    local act = (presetOf(R.preset) or {}).act or 1
    local wtab = D and D.tracks and D.tracks[act] and D.tracks[act][planetKey] or nil
    local function weight(c)
        if wtab then
            for _, e in ipairs(wtab) do
                if type(c.path) == "string" and c.path:find(e.name, 1, true) then return tonumber(e.w) or 1 end
            end
        end
        return 0.25                                     -- not in the campaign's table: possible, rare
    end
    local function pickWeighted(pool)
        local total = 0
        for _, e in ipairs(pool) do total = total + e.w end
        if total <= 0 then return pool[math.random(#pool)].c end
        local r = math.random() * total
        for _, e in ipairs(pool) do
            r = r - e.w
            if r <= 0 then return e.c end
        end
        return pool[#pool].c
    end
    local passes = {
        function(c) return c.planet == planetKey and not (R.used or {})[c.path] end,
        function(c) return c.planet == planetKey end,
        function(c) return not (R.used or {})[c.path] end,
        function(c) return true end,
    }
    for _, fits in ipairs(passes) do
        local pool = {}
        for _, c in ipairs(cands) do
            if fits(c) then pool[#pool + 1] = { c = c, w = weight(c) } end
        end
        if #pool > 0 then return pickWeighted(pool) end
    end
    return nil
end

-- The spec of a map node / boss event: what setup.openRun and prelaunch consume.
-- node = { p, c, i, kind } (map node) or { boss = n, kind, planet, classOver } (boss event).
local function specFor(node)
    local pre = presetOf(R.preset)
    if not pre then return nil end
    local ev = M.eventOf(node.kind)
    local planetKey = node.boss and pre.boss[node.boss].planet or pre.planets[node.p]
    local classOver = node.boss and pre.boss[node.boss].classOverride or ev.classOver
    local classKey = classOver or R.classKey
    local cand = trackFor(planetKey, ev, classKey)
    if not cand then return nil end
    local conds = cand.conds or {}
    return { class = classKey, classOver = classOver, planet = cand.planet, track = cand.track,
             mode = modeFor(ev, cand), kind = node.kind, path = cand.path, name = cand.name,
             planetName = cand.planetName, cond = (#conds > 0) and conds[math.random(#conds)] or "",
             p = node.p, c = node.c, i = node.i, boss = node.boss,
             away = (cand.planet ~= planetKey) or nil }                 -- no track of this class on the map planet
end

-- The reachable next nodes from the cursor (the map choice): up to 3 specs. Boss events are a single option.
function M.makeOptions()
    local pre = presetOf(R.preset)
    if not pre then R.options, R.next = {}, nil; return {} end
    local opts = {}
    if R.bossIdx then
        local b = pre.boss[R.bossIdx]
        if b then
            local s = specFor({ boss = R.bossIdx, kind = b.kind })
            if s then opts[1] = s end
        end
    else
        local cur = R.cursor
        local map = R.maps[cur.p]
        if map and cur.c < map.days then
            local nextCol = map.cols[cur.c + 1]
            -- a narrower next column: rescale the path index first, or an edge path would reach only one node
            local w1, w2 = #map.cols[cur.c], #nextCol
            local base = cur.i
            if w1 > 1 and w2 ~= w1 then base = math.floor((cur.i - 1) * (w2 - 1) / (w1 - 1) + 0.5) + 1 end
            local idxs, seen = {}, {}
            for _, j in ipairs({ base - 1, base, base + 1 }) do
                local jj = math.max(1, math.min(w2, j))
                if not seen[jj] then seen[jj] = true; idxs[#idxs + 1] = jj end
            end
            for _, j in ipairs(idxs) do
                local s = specFor({ p = cur.p, c = cur.c + 1, i = j, kind = nextCol[j] })
                if s then opts[#opts + 1] = s end
            end
        elseif R.maps[cur.p + 1] then
            local col = R.maps[cur.p + 1].cols[1]
            for j = 1, #col do
                local s = specFor({ p = cur.p + 1, c = 1, i = j, kind = col[j] })
                if s then opts[#opts + 1] = s end
            end
        else
            R.bossIdx = 1
            return M.makeOptions()
        end
    end
    -- antagonist invasion (the real per-act chance): the chosen race gets a stronger grid and the rival label
    local ant = pre.antagonist or {}
    if (tonumber(ant.invasionPct) or 0) > 0 then
        for _, s in ipairs(opts) do
            if not s.boss and math.random() * 100 < tonumber(ant.invasionPct) then s.invaded = true end
        end
    end
    R.options, R.choice = opts, 1
    R.next = opts[1]
    return opts
end

-- kept for tests / callers that only want the chosen spec
function M.pickNext()
    M.makeOptions()
    return R.next
end

function M.nextSpec() return M.active() and R.next or nil end

-- The GALAXY RUN poster's RIGHT between races: cycle the reachable nodes. Returns the new spec (nil = one option).
function M.switchRoute()
    if not M.betweenRaces() or not R.options or #R.options < 2 then return nil end
    R.choice = (R.choice % #R.options) + 1
    R.next = R.options[R.choice]
    save()
    St.emit("status", M.routeText())
    return R.next
end

function M.routeText()
    if not (R and R.next) then return nil end
    local n = R.next
    local ev = M.eventOf(n.kind)
    local tag = (R.options and #R.options > 1) and string.format("NODE %d / %d", R.choice or 1, #R.options)
        or (n.boss and "BOSS" or "NEXT")
    local inv = n.invaded and (" · " .. tostring((presetOf(R.preset) or {}).antagonist
        and presetOf(R.preset).antagonist.name or "RIVAL") .. " INVADES") or ""
    return string.format("%s: %s · %s%s", tag, ev.name, tostring(n.planetName or n.planet or "?"), inv)
end

-- the GALAXY RUN card between run races: {planet, caption, track, footer}
function M.cardView()
    if not (M.betweenRaces() and R.next) then return nil end
    local n = R.next
    local ev = M.eventOf(n.kind)
    local cap
    if n.boss then
        cap = "BOSS · " .. ev.name
    else
        cap = string.format("DAY %d / %d · %s", n.c or 1, ((R.maps or {})[n.p or 1] or {}).days or days(), ev.name)
    end
    if R.options and #R.options > 1 then cap = string.format("NODE %d/%d · ", R.choice or 1, #R.options) .. cap end
    if n.invaded then cap = cap .. " · INVADED" end
    return { planet = tostring(n.planetName or n.planet or ""), caption = cap, track = tostring(n.name or n.track or ""),
             footer = M.standingsText() or "" }
end

-- starting League Tokens: "couch" = 1 + 1 per player beyond the first, "real" = the campaign's BaseStartingStrikes
-- (1), a number = that many.
local function startTokens(humans)
    local v = opt("RunTokens", "couch")
    if tonumber(v) then return math.max(1, math.floor(tonumber(v))) end
    if tostring(v) == "real" then return 1 end
    return 1 + math.max(0, (humans or 1) - 1)
end

-- launch.start: a run race gets the run builds and the race's AI tier; a new run starts here (an armed preset).
-- c = St.race.choice, plan = launch.plan(c) (players / arch / cls / aiTierPath / grid / maxRacers; plan.players is
-- the table the launch applies, modified in place). Returns true when the race is a run race.
function M.prelaunch(c, plan)
    ensureLoaded()
    -- 0.16: the GALACTIC GRAND PRIX replaced the GALAXY RUN on the FREE MODE poster; while a GP is on it owns launches
    local okG, gpOn = pcall(function() return U.mod("gp").active() end)
    if okG and gpOn == true then return false end
    if type(c) ~= "table" or type(plan) ~= "table" or type(plan.players) ~= "table" or plan.arch == nil then
        return false
    end
    local classKey = plan.cls and plan.cls.key or nil
    local humans = 0
    for _, pick in pairs(plan.players) do
        if type(pick) == "table" and pick.ctrlId ~= nil then humans = humans + 1 end
    end
    local starting = false
    if not M.active() then
        local preKey = M.lengthSetting()
        local pre = preKey and presetOf(preKey) or nil
        if not pre then return false end
        if not D then U.warn(TAG, "rundata.lua missing: GALAXY RUN cannot start"); return false end
        local seed = math.floor((os.time() % 1000000) * 7 + (St.nowMs() or 0) % 7919)
        math.randomseed(seed)
        R = { v = 3, status = "on", preset = preKey, race = 1, arch = plan.arch, classKey = classKey,
              players = {}, used = {}, history = {}, seed = seed, hull = startTokens(humans),
              startedAt = os.date("%Y-%m-%d %H:%M") }
        R.tokensMax = R.hull
        R.maps = genMaps(pre)
        R.length = lengthOf(pre)
        R.cursor = { p = 1, c = 1, i = math.random(#R.maps[1].cols[1]) }
        starting = true
        U.log(TAG, "GALAXY RUN started: %s (%s), %d events, %d token(s), seed %d", pre.label,
            tostring(R.classKey), R.length, R.hull, seed)
    end
    local over = (not starting) and R.next and R.next.classOver or nil
    if over then
        if tostring(classKey) ~= tostring(over) then
            St.emit("status", "GALAXY RUN: THIS EVENT RACES IN " .. string.upper(tostring(over)))
            U.warn(TAG, "override event needs class %s (launched %s): played outside the run", tostring(over),
                tostring(classKey))
            return false
        end
    elseif tonumber(plan.arch) ~= tonumber(R.arch) then
        St.emit("status", "GALAXY RUN: RACE IN " .. tostring(R.classKey) .. " (OPTIONS > GALAXY RUN: OFF TO LEAVE)")
        U.warn(TAG, "run race in another class (%s, run %s): played outside the run", tostring(classKey),
            tostring(R.classKey))
        return false
    end
    local Km = K()
    for pnum, pick in pairs(plan.players) do
        if type(pick) == "table" and pick.ctrlId ~= nil then
            local name = (pnum == 1) and "P1" or ("P" .. tostring(pnum))
            local p = ensurePlayer(pick.ctrlId, pnum, pick.pilotId, name)
            if not over then
                -- pods/override interludes race on the cards' own builds; run races get the run build
                local style = styleOf(pick.pilotId, R.arch)
                local lo
                if starting or type(pick.loadout) ~= "table" then
                    lo = Km.copy(p.lo)
                else
                    lo = Km.copy(pick.loadout)             -- the card's edit (owned perks, capped levels)
                end
                lo = M.sanitize(lo, p, R.arch, style)
                p.lo = Km.copy(lo)
                pick.loadout, pick.code = lo, nil
            end
        end
    end
    R.lastHumans = humans
    local kind = (not starting and R.next and R.next.kind) or "standard"
    local ev = M.eventOf(kind)
    if ev.humansOnly then                           -- field / pod test: the grid is the humans alone
        plan.grid, plan.maxRacers = "max", math.max(1, humans)   -- the plan only: the stored choice keeps its grid
    end
    local tier = M.tierFor(R.race, R.length)
    if not starting and R.next and R.next.invaded then tier = math.min(6, tier + 1) end
    plan.aiTierPath = tierPath(over and 1 or R.arch, tier)
    -- pods have no tier build: the tier goes into the AI pods' own builds (perkapply.applyAI)
    plan.aiLoadout = nil
    if (tonumber(R.arch) == 1 or over) and tier > 1 then
        pcall(function() plan.aiLoadout = U.mod("perkapply").tierLoadout(tier, 1) end)
    end
    local node = starting and { p = R.cursor.p, c = R.cursor.c, i = R.cursor.i } or R.next or {}
    R.flight = { race = R.race, label = tostring(c.label or "?"), planet = node.planet, kind = kind,
                 over = over, invaded = (not starting) and R.next and R.next.invaded or nil,
                 p = node.p, c = node.c, i = node.i, boss = node.boss,
                 slot = slotOf(node.p, node.boss ~= nil), stats = {} }
    pcall(function() R.flight.track = c.track:GetFullName() end)
    save()
    St.emit("status", M.statusText())
    U.log(TAG, "run race %d / %d launched (%s, %s%s): AI tier %d, %d player(s)", R.race, R.length, ev.name,
        R.flight.label, R.flight.invaded and ", INVADED" or "", tier, M.playerCount())
    return true
end

---------------------------------------------------------------------------------------------------- in-race
local function stat(ctrlId)
    local st = R.flight.stats
    st[ctrlId] = st[ctrlId] or {}
    return st[ctrlId]
end

-- FAST loop (main.lua, race phases): wreck watch for the fault rule (any player count / WreckMode).
local lastWreckPoll = 0
local function pollWrecks(now)
    if now - lastWreckPoll < 250 then return end
    lastWreckPoll = now
    local tko = U.mod("takeover")
    for _, e in ipairs(U.localPlayersRO()) do
        pcall(function()
            local ps = e.pc.PlayerState
            if tko and type(tko.racerPSFor) == "function" then
                local okP, rps = pcall(tko.racerPSFor, e.pc)
                if okP and U.ok(rps) then ps = rps end
            end
            if U.ok(ps) and ps.RaceEventComponent.bHasVehicleWrecked == true then stat(e.ctrlId).wrecked = true end
        end)
    end
end

function M.fastTick()
    if R and R.flight and St.phase == "RACING" then pcall(pollWrecks, St.nowMs()) end
end

-- The live line next to a player's race timer (hud.fastChallenge): the event, else the rival.
-- bestLap = that player's RaceEventComponent.BestLapTime (seconds, -1 = none yet).
function M.liveText(ctrlId, bestLap)
    if not (R and R.flight and St.phase == "RACING") then return nil end
    local kind = R.flight.kind or "standard"
    if kind == "fieldtest" then return "FIELD TEST" end
    if kind == "planesprint" then return "POD TEST" end
    if R.flight.boss then return M.eventOf(kind).name end
    if R.flight.invaded then
        local ant = (presetOf(R.preset) or {}).antagonist
        return "RIVAL " .. string.upper(tostring(ant and ant.name or R.rival or "?"))
    end
    if R.rival then return "RIVAL " .. string.upper(tostring(R.rival)) end
    return nil
end

-- the rival (the AI that placed best last race) marked for the game's HUD (bIsRival / RacingGameState.Rival)
local function markRival()
    if not (R and R.flight and R.rival) then return end
    local gs = U.gs()
    if not U.ok(gs) then return end
    pcall(function()
        local list = gs.Racers
        for i = 1, U.arrayCount(list) do
            local ps = list[i]
            if U.ok(ps) and ps.bIsABot and ps:GetPlayerName():ToString() == R.rival then
                pcall(function() ps.bIsRival = true end)
                pcall(function() gs.Rival = ps end)
                U.log(TAG, "rival %s marked", R.rival)
            end
        end
    end)
end

-- POSTRACE edge (and "leaving"): every racer's place / time / best lap; the local humans by their racing
-- PlayerState.
local function snapshot()
    if not (R and R.flight) then return end
    local gs = U.gs()
    if not U.ok(gs) then return end
    local finished = false
    pcall(function() finished = gs.bIsRaceFinished == true end)
    local humans, keyToCtrl, all = {}, {}, {}
    local tko = U.mod("takeover")
    for _, e in ipairs(U.localPlayersRO()) do
        if U.ok(e.pc) then
            local ps = e.pc.PlayerState
            if tko and type(tko.racerPSFor) == "function" then
                local okP, rps = pcall(tko.racerPSFor, e.pc)
                if okP and U.ok(rps) then ps = rps end
            end
            if U.ok(ps) then keyToCtrl[U.key(ps)] = e.ctrlId end
        end
    end
    local n = 0
    pcall(function()
        local list = gs.Racers
        local cnt = U.arrayCount(list)
        for i = 1, cnt do
            local ps = list[i]
            if U.ok(ps) then
                n = n + 1
                local rec = ps.RaceEventComponent
                local pos, ft, lap, wrecked = 99, -1, -1, false
                pcall(function() pos = math.floor(tonumber(rec.EventPosition) or 99) end)
                pcall(function() ft = tonumber(rec.EventFinishTime) or -1 end)
                pcall(function() lap = tonumber(rec.BestLapTime) or -1 end)
                pcall(function() wrecked = rec.bHasVehicleWrecked == true end)
                local name = "?"
                pcall(function() name = ps:GetPlayerName():ToString() end)
                local c = keyToCtrl[U.key(ps)]
                all[#all + 1] = { name = name, pos = pos, lap = lap, bot = c == nil }
                if c ~= nil then
                    local s = R.flight.stats[c] or {}
                    humans[c] = { pos = pos, dnf = (ft < 0), time = ft, lap = lap,
                                  wrecked = wrecked or s.wrecked == true }
                end
            end
        end
    end)
    if next(humans) == nil then return end
    R.flight.snap = { n = n, humans = humans, all = all, finished = finished }
    local parts = {}
    for c, h in pairs(humans) do
        parts[#parts + 1] = string.format("c%d %s%s%s", c, ordinal(h.pos), h.dnf and " DNF" or "",
            h.wrecked and " WRECKED" or "")
    end
    U.log(TAG, "race %d (%s) result: %s of %d racers (race finished %s)", R.flight.race, tostring(R.flight.kind),
        table.concat(parts, ", "), n, tostring(finished))
end
M._snapshot = snapshot

---------------------------------------------------------------------------------------------------- economy
-- a wreck turns a random equipped part FAULTY ("Critical Malfunction Error"): unequipped and locked (owned, not
-- usable) until repaired in the shop for the campaign's repair price
local function breakPart(p)
    local equipped = {}
    for _, id in pairs(p.lo and p.lo.parts or {}) do if id then equipped[#equipped + 1] = id end end
    if #equipped == 0 then return nil end
    local id = equipped[math.random(#equipped)]
    p.broken = p.broken or {}
    p.broken[id] = true
    for i, x in pairs(p.lo.parts) do if x == id then p.lo.parts[i] = false end end
    return id
end

-- the campaign's prices (ECO_Campaign; rundata.prices); abilities by level, repair = the affix-repair price
local function priceOf(it)
    local pr = D and D.prices or {}
    if it.rkind == "ab" then
        local byLvl = pr.ability or { 1000, 2000, 4000 }
        return byLvl[math.max(1, math.min(#byLvl, tonumber(it.lvl) or 1))]
    end
    if it.rkind == "crash" then return pr.crash or 2000 end
    if it.rkind == "part" then return pr.part or 1000 end
    if it.rkind == "trait" then return pr.trait or 2000 end
    if it.rkind == "upgrade" then return pr.upgrade or 1000 end
    if it.rkind == "repairpart" then return pr.repair or 2000 end
    return 1000
end

local function rerollPrice(n)
    local rr = D and D.prices and D.prices.reroll or { base = 250, step = 250 }
    return (rr.base or 250) + (rr.step or 250) * (n or 0)
end

-- the payout of a finish position (1..12) at a planet slot (1..5); eliminators pay one planet ahead (the real
-- high-risk rule); DNF pays the real floor
local function payout(slot, pos, dnf, highRisk)
    local pt = D and D.payouts or nil
    local scale = tonumber(opt("RunPayoutScale", 1)) or 1
    if not pt then return math.floor((dnf and 25 or math.max(25, 1300 - pos * 100)) * scale) end
    if dnf then return math.floor((pt.dnf or 25) * scale) end
    local s = math.max(1, math.min(#pt.pos, (highRisk and slot + 1 or slot)))
    local row = pt.pos[s]
    local p = math.max(1, math.min(#row, math.floor(tonumber(pos) or #row)))
    return math.floor((tonumber(row[p]) or 25) * scale)
end

-- The real payout of a finish position for the NEXT node (the run page's risk card); the kind decides the
-- high-risk planet shift. Safe without a run (planet-1 numbers).
function M.payoutPreview(pos, kind)
    local slot = slotOf(R and R.next and R.next.p or nil, (R and R.next and R.next.boss) ~= nil)
    return payout(slot, pos, false, kind == "highrisk")
end

-- the shop stock of a player: 4 perks it does not own (mixed kinds, shop-ramp rarities) + the level-cap upgrade
function M.makeShop(p)
    local cat = catalog(R.arch)
    local o, taken, out = p.owned or emptyOwned(), {}, {}
    local slot = slotOf(R.lastSlot, false)
    for _ = 1, 4 do
        local it = pickGraded(cat, o, taken, rarityRoll(slot, "shop"))
        if it then it.price = priceOf(it); out[#out + 1] = it end
    end
    local up = upgradeRow(); up.price = priceOf(up); out[#out + 1] = up
    return out
end

-- the shop picker of a card: stock + repairs + reroll + leave (names carry the prices)
function M.shopPicker(ctrlId)
    if not M.active() then return nil end
    local p = R.players[ctrlId]
    if not p or not p.shopPending then return nil end
    p.shop = p.shop or M.makeShop(p)
    local items = {}
    for _, it in ipairs(p.shop) do
        local row = {}
        for k, v in pairs(it) do row[k] = v end
        row.name = string.format("%s · %d CR", tostring(it.name or it.id), it.price or 0)
        items[#items + 1] = row
    end
    for id in pairs(p.broken or {}) do
        local nm = id
        pcall(function() nm = (U.mod("perkdata").PARTS[id] or {}).name or id end)
        items[#items + 1] = { id = id, rkind = "repairpart", slot = "part1", iconKind = "tile",
                              name = string.format("REPAIR %s · %d CR", tostring(nm), priceOf({ rkind = "repairpart" })),
                              price = priceOf({ rkind = "repairpart" }) }
    end
    local rr = rerollPrice(p.rerolls)
    items[#items + 1] = { id = "reroll", rkind = "reroll", slot = "tun0", iconKind = "glyph",
                          name = string.format("REROLL THE SHOP · %d CR", rr), price = rr }
    items[#items + 1] = { id = "leave", rkind = "leave", slot = "tun0", iconKind = "glyph", name = "LEAVE THE SHOP" }
    return { slot = items[1].slot, kind = "shop", cats = { { key = "shop", name = string.format("SHOP · %d CREDITS",
             p.credits or 0) } }, cat = 1, items = items, sel = 1 }
end

-- A shop row bought on a card. -> new run build (copy) or nil, a toast, the refreshed picker (nil = shop closed)
function M.buy(ctrlId, item, arch, style)
    if not M.active() or type(item) ~= "table" then return nil, nil, nil end
    local p = R.players[ctrlId]
    if not p then return nil, nil, nil end
    if item.rkind == "leave" then
        p.shopPending = nil
        save()
        return K().copy(p.lo), string.format("%d CREDITS LEFT", p.credits or 0), nil
    end
    local price = tonumber(item.price) or 0
    if (p.credits or 0) < price then
        return nil, string.format("NOT ENOUGH CREDITS (%d)", p.credits or 0), M.shopPicker(ctrlId)
    end
    p.credits = (p.credits or 0) - price
    local lo, toastText = K().copy(p.lo), nil
    if item.rkind == "reroll" then
        p.rerolls = (p.rerolls or 0) + 1
        p.shop = M.makeShop(p)
        toastText = "NEW STOCK"
    elseif item.rkind == "repairpart" then
        if p.broken then p.broken[item.id] = nil end
        toastText = "REPAIRED"
        local Km = K()
        for i = 1, Km.partSlots() do if not lo.parts[i] then pcall(function() Km.equip(lo, "part" .. i, item.id, arch, style) end); break end end
        p.lo = M.sanitize(lo, p, arch, style)
    else
        for i, it in ipairs(p.shop or {}) do if it.id == item.id and it.rkind == item.rkind then table.remove(p.shop, i); break end end
        local offer = p.offer
        p.offer = nil
        local newLo, t = M.claim(ctrlId, item, arch, style)
        p.offer = offer
        p.shopPending = true                     -- claim() saves; the shop stays open
        toastText = t
        lo = newLo
    end
    U.log(TAG, "P%s buys %s %s for %d (%d left)", tostring(p.pnum), tostring(item.rkind), tostring(item.id), price,
        p.credits or 0)
    save()
    return K().copy(p.lo), toastText, M.shopPicker(ctrlId)
end

---------------------------------------------------------------------------------------------------- settle
-- the humans' ranking value of an event kind (lower is better)
local function rankValue(kind, h)
    local ev = M.eventOf(kind)
    if ev.rank == "time" then return (not h.dnf and h.time and h.time > 0) and h.time or 1e9 end
    return (h.dnf and 100 or 0) + (h.pos or 99)
end

-- the team outcome of an event; -> met, tokensLost, detail text
local function targetMet(kind, snap)
    local ev = M.eventOf(kind)
    local nh, best, allFin, allWrecked = 0, 99, true, true
    for _, h in pairs(snap.humans) do
        nh = nh + 1
        if not h.dnf and (h.pos or 99) < best then best = h.pos or 99 end
        if h.dnf then allFin = false end
        if not h.wrecked then allWrecked = false end
    end
    local lost, met, detail = 0, true, best < 99 and ("BEST " .. ordinal(best)) or "NOBODY FINISHED"
    if kind == "highrisk" then
        met = best <= 3
        if not met then lost = lost + 1; detail = detail .. " · ELIMINATOR TOP 3 MISSED: TOKEN -1" end
    elseif kind == "planesprint" then
        met = allFin
        if not met then lost = lost + 1; detail = "A PLAYER DID NOT FINISH: TOKEN -1" end
    elseif kind == "knockout" or kind == "champion" then
        met = best == 1
        if not met then lost = lost + 1; detail = detail .. " · MUST-WIN LOST: TOKEN -1" end
    elseif kind == "fieldtest" then
        met = true
        detail = allFin and "EVERYBODY FINISHED" or "A PLAYER DID NOT FINISH"
    end
    if allWrecked and nh > 0 then
        lost = lost + 1
        detail = detail .. " · EVERYBODY WRECKED: TOKEN -1"
    end
    return met, lost, detail
end
M._targetMet = targetMet

-- advance the cursor onto the settled node, then roll the next options
local function advance(fl)
    if fl.boss then
        R.bossIdx = (fl.boss or R.bossIdx or 1) + 1
        local pre = presetOf(R.preset)
        if not pre or R.bossIdx > #pre.boss then return "won" end
    elseif fl.p then
        R.cursor = { p = fl.p, c = fl.c, i = fl.i }
    end
    R.race = R.race + 1
    if R.race > R.length then return "won" end
    return "on"
end

-- Back in the front end: score the race (or drop it when it did not end), credits, faults, rewards, next nodes.
function M.settle()
    if not (R and R.flight) then return end
    local fl = R.flight
    R.flight = nil
    if not fl.snap then
        save()
        St.emit("status", "GALAXY RUN: RACE " .. fl.race .. " NOT FINISHED, RACE IT AGAIN")
        U.log(TAG, "run race %d left before its end: not counted", fl.race)
        return
    end
    local kind = fl.kind or "standard"
    local ev = M.eventOf(kind)
    -- humans ranked by the event's value
    local order = {}
    for c, h in pairs(fl.snap.humans) do order[#order + 1] = { c = c, h = h, v = rankValue(kind, h) } end
    table.sort(order, function(a, b) if a.v ~= b.v then return a.v < b.v end return (a.h.pos or 99) < (b.h.pos or 99) end)
    -- the rival's place (an AI racer, by name)
    local rivalPos = nil
    for _, a in ipairs(fl.snap.all or {}) do if R.rival and a.bot and a.name == R.rival then rivalPos = a.pos end end
    local res, broke = {}, {}
    local worstC = order[#order] and order[#order].c or nil
    for i, e in ipairs(order) do
        local p = R.players[e.c]
        local pts = (not e.h.dnf) and (POINTS[i] or 0) or 0
        local cr = payout(fl.slot or 1, e.h.pos or 12, e.h.dnf, kind == "highrisk")
        local beatRival = rivalPos ~= nil and not e.h.dnf and (e.h.pos or 99) < rivalPos
        if beatRival then cr = cr + RIVAL_BONUS end
        if p then
            p.points = (p.points or 0) + pts
            p.credits = (p.credits or 0) + cr
            if i == 1 and not e.h.dnf then p.wins = (p.wins or 0) + 1 end
            if e.h.wrecked and not fl.over then
                local id = breakPart(p)
                if id then broke[#broke + 1] = string.format("%s: %s FAULTY", tostring(p.name), id) end
            end
        end
        res[e.c] = { rank = i, pos = e.h.pos, dnf = e.h.dnf, pts = pts, cr = cr, rival = beatRival or nil }
    end
    local met, tokensLost, detail = targetMet(kind, fl.snap)
    R.hull = math.max(0, R.hull - tokensLost)
    R.history[#R.history + 1] = { race = fl.race, label = fl.label, kind = kind, met = met, detail = detail, res = res }
    R.used[fl.track or ("race" .. fl.race)] = true
    R.lastKind, R.lastSlot = kind, fl.slot or 1
    -- the next rival: the AI that placed best
    local bestAI = nil
    for _, a in ipairs(fl.snap.all or {}) do if a.bot and (not bestAI or a.pos < bestAI.pos) then bestAI = a end end
    R.rival = bestAI and bestAI.name or R.rival
    -- a lost must-win is raced again (the token already went); tokens 0 = the run is over
    local mustWinAgain = (ev.mustWin and not met and R.hull > 0)
    local outcome = "on"
    if not mustWinAgain then outcome = advance(fl) end
    for c, p in pairs(R.players) do
        p.cap = (p.cap or 1) + 1
        p.credits = p.credits or 0
        if R.hull > 0 and outcome == "on" then
            p.offer = M.makeOffer(p, (c == worstC and M.playerCount() > 1) and 4 or 3)
            p.offerPending = nil                  -- (a late joiner's free pick is this offer)
            p.shop, p.rerolls, p.shopPending = M.makeShop(p), 0, true
        end
    end
    local winner = order[1] and R.players[order[1].c]
    local msg
    if R.hull <= 0 then
        R.status = "lost"
        msg = M.statusText()
        archive("LOST")
    elseif outcome == "won" then
        R.status = "won"
        msg = M.statusText()
        archive("WON")
    elseif mustWinAgain then
        M.makeOptions()
        msg = string.format("%s LOST (%s): RACE IT AGAIN · %s", ev.name, detail, M.statusText())
    else
        M.makeOptions()
        msg = string.format("%s (%s) · %s WINS THE %s · %s",
            tokensLost > 0 and ("TOKEN -" .. tokensLost) or "DONE", detail,
            winner and tostring(winner.name) or "?", ev.name, M.statusText())
    end
    if #broke > 0 then msg = msg .. " · " .. table.concat(broke, ", ") end
    save()
    St.emit("status", msg)
    U.log(TAG, "race %d (%s) settled: %s, tokens %d, rival %s, next %s", fl.race, ev.name, detail, R.hull,
        tostring(R.rival), R.next and (tostring(R.next.kind) .. " " .. tostring(R.next.track)) or "-")
end

-- OPTIONS > Galaxy run OFF while a run is on: the run is dropped (archived as ABANDONED).
function M.abandon(why)
    ensureLoaded()
    if not R then return end
    if R.status == "on" then archive("ABANDONED") end
    U.log(TAG, "run dropped (%s)", tostring(why))
    R = nil
    save()
end

-- FREE MODE START between run races: RACE SETUP on the racer cards for the next race. true when handled.
function M.openNext()
    if not M.betweenRaces() then return false end
    if not R.next then M.makeOptions(); save() end
    local spec = R.next
    if not spec then return false end
    local setup = U.mod("setup")
    if type(setup.openRun) ~= "function" then return false end
    local ok, r = pcall(setup.openRun, spec)
    if not ok or r ~= true then
        U.warn(TAG, "next run race not opened (%s): pick it in RACE SETUP", tostring(r))
        return false
    end
    local ev = M.eventOf(spec.kind)
    local t = M.targetText(spec.kind)
    St.emit("status", string.format("%s: %s%s", ev.name, ev.rule, t and (" TARGET " .. t .. ".") or ""))
    return true
end

---------------------------------------------------------------------------------------------------- events
function M.init()
    ensureLoaded()
    if not D then U.warn(TAG, "rundata.lua missing or unreadable: GALAXY RUN stays off") end
    St.on("phase", TAG, function(new)
        if not (R and R.flight) then return end
        if new == "POSTRACE" then U.try(TAG, snapshot)
        elseif new == "PRERACE" then R.flight.snap, R.flight.stats = nil, {}   -- RESTART RACE: the old race is void
        elseif new == "RACING" then
            R.flight.snap = nil
            U.try(TAG, markRival)
        elseif new == "FRONTEND" then U.try(TAG, M.settle) end
    end)
    St.on("leaving", TAG, function()
        if R and R.flight and R.flight.snap and St.phase == "POSTRACE" then U.try(TAG, snapshot) end
    end)
    St.on("humanWrecked", TAG, function(pc)
        if not (R and R.flight) then return end
        for _, e in ipairs(U.localPlayersRO()) do
            if U.ok(e.pc) and U.key(e.pc) == U.key(pc) then
                stat(e.ctrlId).wrecked = true
                U.log(TAG, "c%d wrecked: a part turns faulty at the race end", e.ctrlId)
            end
        end
    end)
    St.on("tab", TAG, function(shown)
        if shown and R then
            local t = M.statusText()
            if t then St.emit("status", t) end
        end
    end)
    if math.randomseed then math.randomseed(os.time()) end
end

-- tests
function M._reset() R, loaded = nil, true end
function M._set(r) R, loaded = r, true end
function M._data() return D end
function M._setData(d) D = d end

return M
