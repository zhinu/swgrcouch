-- run.lua: GALAXY RUN, a rogue-style career for 1-4 couch players (0.13.0, Jules 2026-10-11: "Think about creating a
-- career mode for 2 to 4 players. Rogue multiplayer would be awesome.").
--
-- Mod-owned: the run lives in Mods/SWGRCouch/run.txt (+ run-history.txt). It never opens, continues or abandons the
-- game's CAMPAIGN / tour and never writes the game's save. It rides on FREE MODE's own paths:
--   * start: OPTIONS > Galaxy run = 4 / 6 / 9 races; the next race launched from FREE MODE is race 1 (any track the
--     players chose). Everyone starts on a STARTER build (the pilot's kit with 2 abilities, every level 0, no parts,
--     no traits): growing it is the run.
--   * launch.start -> M.prelaunch(choice): a run race gets each player's run build (the cards' build, kept to what the
--     player owns and to the level cap) and the AI tier of the race number (TIER 1 -> 6 over the run, speeders).
--   * POSTRACE edge -> snapshot of every racer's place (RacingGameState.Racers + RaceEventComponent); FRONTEND ->
--     settle: points 25/18/15/12/10/8/6/4/2/1 per human, the TEAM TARGET (a human in the top 5 early, top 3 in the
--     middle, 1st in the final) or the team loses a hull point (3 at the start; 0 = RUN LOST), +1 level cap, and a
--     REWARD offer per player: 3 real perks (ability / crash, part, trait or +1 level cap), 4 for the last human.
--   * between races the FREE MODE START opens RACE SETUP right on the racer cards for the run's next race (planet /
--     track / condition / mode picked by the run, never the same track twice); each card opens its reward picker first,
--     PERKS pickers list owned perks only, L/R on perks and the KIT row are locked, levels stop at the cap.
--   * a race left before its end (EXIT TO MAIN MENU) or restarted does not count: the same race again.
-- Every game read is pcall-guarded; the module never touches a front-end widget (lobby / setup / racers render).
local U = require("util")
local St = require("state")
local cfg = require("config")
local settings = require("settings")

local TAG = "run"
local M = {}

local POINTS = { 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 }
local HULL_START = 3
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
    if ok and type(t) == "table" and t.v == 1 and type(t.players) == "table" then
        R = t
        U.log(TAG, "run loaded: %s, race %d of %d, hull %d, %d player(s)", tostring(R.status), R.race or 0,
            R.length or 0, R.hull or 0, M.playerCount())
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
    f:write(string.format("%s  %s  %s  races %d/%d  hull %d  %s\n", os.date("%Y-%m-%d %H:%M"), outcome,
        tostring(R.classKey), math.min(R.race - 1, R.length), R.length, R.hull, table.concat(parts, ", ")))
    f:close()
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
function M.lengthSetting()
    local v = tostring(settings.get("RunLength") or "off")
    local n = tonumber(v)
    return (n and n >= 2) and math.floor(n) or nil
end

-- The team target of race i: the best human must place this high (or better).
-- 0.13.0 (live: a solo run was LOST at race 3, every target missed): the targets loosen with fewer players (one of
-- four placing well is likelier than one of one): slack 2 places solo, 1 with two players, 0 with 3-4; the final:
-- top 2 solo, else a win. n = humans of the race (nil = the run's last launch).
function M.slack(n)
    n = math.max(1, math.floor(tonumber(n) or (R and R.lastHumans) or 4))
    return math.max(0, 3 - n)
end

function M.targetFor(i, len, n)
    local sl = M.slack(n)
    if i >= len then return 1 + math.floor(sl / 2) end
    if i <= math.max(1, math.floor(len / 3)) then return 5 + sl end
    return 3 + sl
end

function M.lapTarget(n) return 3 + M.slack(n) end

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

-- One status line for the FREE MODE pill / the racer cards: "GALAXY RUN · RACE 2 / 6 · HULL 2 · TARGET TOP 3".
function M.statusText()
    ensureLoaded()
    if not R then return nil end
    if R.status == "won" then return "GALAXY RUN WON! " .. M.leaderText() end
    if R.status == "lost" then return string.format("GALAXY RUN LOST AT RACE %d · %s", R.race - 1, M.leaderText()) end
    local kind = (R.next and R.next.kind) or (R.flight and R.flight.kind) or "race"
    if R.race == 1 then kind = "race" end
    return string.format("GALAXY RUN · RACE %d / %d · %s · HULL %d · TARGET %s", R.race, R.length,
        M.eventOf(kind).name, R.hull, M.targetText(kind, R.race, R.length))
end

function M.leaderText()
    local best, bp = nil, -1
    for _, p in pairs(R and R.players or {}) do
        if (p.points or 0) > bp then best, bp = p, p.points or 0 end
    end
    return best and string.format("MVP %s %d PTS", tostring(best.name or "?"), bp) or ""
end

-- Standings for the lobby's RACE card: "P1 43 · P2 31 · HULL 2" (points order; nil without a run).
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
    if R.status == "on" then parts[#parts + 1] = "HULL " .. tostring(R.hull) end
    return table.concat(parts, " · ")
end

-- Card line: "RUN 43 PTS · 2ND" (nil without a run player).
function M.cardLine(ctrlId)
    if not M.active() then return nil end
    local p = R.players[ctrlId]
    if not p then return nil end
    local rank = 1
    for c, o in pairs(R.players) do if c ~= ctrlId and (o.points or 0) > (p.points or 0) then rank = rank + 1 end end
    return string.format("RUN %d PTS · %s · %d CREDITS · CAP %d", p.points or 0, ordinal(rank), p.credits or 0, p.cap or 1)
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
        if id and (not o.part[id] or (p.broken or {})[id]) then lo.parts[i] = false end   -- v2: broken = unusable
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
        if kind == "part" and (p.broken or {})[id] then return false end   -- v2: broken until repaired
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
              offer = nil, wins = 0, joinedAt = R.race, credits = 200 }   -- v2: starting credits
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

local function upgradeRow()
    return { id = "upgrade", name = "UPGRADE: LEVEL CAP +1", rkind = "upgrade", slot = "tun0", iconKind = "glyph" }
end

-- 0.13.0 design §5: a rare team reward while the hull is damaged (one player's pick repairs it for everyone)
local function repairRow()
    return { id = "repair", name = "TEAM REPAIR: HULL +1", rkind = "repair", slot = "tun2", iconKind = "glyph" }
end
local REPAIR_CHANCE = 0.15

-- 3 offers (4 for the last human): an ability or crash ability, a part, a trait or an upgrade (+ one more).
function M.makeOffer(p, n)
    local cat = catalog(R.arch)
    local o, taken, out = p.owned or emptyOwned(), {}, {}
    local function add(it) if it then out[#out + 1] = it end end
    local abList = (math.random() < 0.25 and #cat.crash > 0) and cat.crash or cat.ab
    add(pickFrom(abList, o[abList == cat.crash and "crash" or "ab"], taken))
    add(pickFrom(cat.part, o.part, taken))
    if math.random() < 0.6 then add(pickFrom(cat.trait, o.trait, taken)) else add(upgradeRow()) end
    while #out < n do
        local kinds = { "ab", "part", "trait" }
        local k = kinds[math.random(#kinds)]
        local it = pickFrom(cat[k], o[k], taken)
        if not it then it = upgradeRow() end
        add(it)
        if #out >= n then break end
    end
    if #out == 0 then out[1] = upgradeRow() end
    if R.hull < HULL_START and math.random() < (tonumber(opt("RunRepairChance", REPAIR_CHANCE)) or REPAIR_CHANCE) then
        out[#out] = repairRow()                       -- replaces the last offer
    end
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
        R.hull = math.min(HULL_START, R.hull + 1)
        toastText = "TEAM HULL " .. R.hull
        St.emit("status", string.format("P%s REPAIRED THE TEAM HULL: %d", tostring(p.pnum), R.hull))
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

---------------------------------------------------------------------------------------------------- events (v2)
-- 0.13.0 v2: every run event is a normal race scored by the mod per player (the game's own TimeTrial / Takedowns /
-- RamjetDistance / Precision modes track ONE player and have no AI grid). rank: how the humans are ranked;
-- mode: the setup mode key (GMV); humansOnly: the grid is the humans alone (no AI).
local EVENT = {
    race       = { name = "RACE",            mode = "race",       rank = "place",
                   rule = "Finish as high as you can." },
    eliminator = { name = "ELIMINATOR",      mode = "eliminator", rank = "place", speeders = true,
                   rule = "The last racer is out at every elimination." },
    final      = { name = "FINAL",           mode = "fullgrid",   rank = "place",
                   rule = "Full grid. Win it to win the run." },
    timetrial  = { name = "TIME TRIAL",      mode = "race",       rank = "time",  humansOnly = true,
                   rule = "No AI: the fastest race time wins. Everybody must finish." },
    hotlap     = { name = "HOT LAP",         mode = "race",       rank = "lap",
                   rule = "The best single lap wins. Set a lap in the top 3 of the field." },
    boost      = { name = "BOOST CHALLENGE", mode = "race",       rank = "boost",
                   rule = "Most seconds on boost wins: afterburner burning, ramjet counts double." },
    takedown   = { name = "TAKEDOWN HUNT",   mode = "fullgrid",   rank = "takedown",
                   rule = "Full grid: most takedowns wins." },
}
M.EVENT = EVENT
local CHALLENGES = { "timetrial", "hotlap", "boost", "takedown" }
local CREDITS = { 300, 220, 160, 120 }          -- by rank among the humans
local RISKY_MULT = 1.5
local RIVAL_BONUS = 100
local BOOST_TARGET_S = 45                        -- team boost target: seconds per player (ramjet counts double)
local START_CREDITS = 200

function M.eventOf(kind) return EVENT[kind or "race"] or EVENT.race end

-- "TOP 3" / "EVERYBODY FINISHES" / "36 S OF BOOST" ... for the next event (n = humans in the run)
function M.targetText(kind, race, len, n)
    local ev = M.eventOf(kind)
    n = math.max(1, n or (R and R.lastHumans) or M.playerCount())
    if ev.rank == "place" then
        local t = M.targetFor(race, len, n)
        return t == 1 and "WIN" or ("TOP " .. t)
    elseif ev.rank == "time" then return "EVERYBODY FINISHES"
    elseif ev.rank == "lap" then return string.format("A TOP-%d LAP", M.lapTarget(n))
    elseif ev.rank == "boost" then return string.format("%d S OF BOOST", BOOST_TARGET_S * n)
    elseif ev.rank == "takedown" then return string.format("%d TAKEDOWN%s", n, n == 1 and "" or "S") end
    return "?"
end

local function candidates()
    local setup = U.mod("setup")
    if type(setup.runCandidates) ~= "function" then return {} end
    local ok, cands = pcall(setup.runCandidates, R.classKey)
    return (ok and type(cands) == "table") and cands or {}
end

-- One next event of a kind: a planet / track not raced yet (another planet than the last race) that offers the
-- kind's mode, a random condition. -> {class, planet, track, cond, mode, kind, name, planetName} or nil.
function M.pickEvent(kind, avoidPath)
    local ev = M.eventOf(kind)
    local cands = candidates()
    if #cands == 0 then return nil end
    local function fits(c, strict)
        local modes = {}
        for _, m in ipairs(c.modes or { "race" }) do modes[m] = true end
        if not modes[ev.mode] then return false end
        if c.path == avoidPath then return false end
        if strict and ((R.used or {})[c.path] or c.planet == R.lastPlanet) then return false end
        if not strict and (R.used or {})[c.path] then return false end
        return true
    end
    local pool = {}
    for _, c in ipairs(cands) do if fits(c, true) then pool[#pool + 1] = c end end
    if #pool == 0 then for _, c in ipairs(cands) do if fits(c, false) then pool[#pool + 1] = c end end end
    if #pool == 0 then
        if kind ~= "race" then return M.pickEvent("race", avoidPath) end
        pool = cands
    end
    local c = pool[math.random(#pool)]
    local conds = c.conds or {}
    return { class = R.classKey, planet = c.planet, track = c.track, mode = ev.mode, kind = kind, path = c.path,
             name = c.name, planetName = c.planetName,
             cond = (#conds > 0) and conds[math.random(#conds)] or "" }
end

-- Route choice (v2): two next events, A = the safe one (race; the scheduled eliminator), B = a challenge for x1.5
-- credits; the final has one route. R.choice picks one; R.next is the chosen spec.
function M.makeOptions()
    local opts = {}
    if R.race >= R.length then
        opts[1] = M.pickEvent("final")
    else
        local safeKind = (R.race == R.elimRace and not (tonumber(R.arch) == 1)) and "eliminator" or "race"
        opts[1] = M.pickEvent(safeKind)
        local pool = {}
        for _, k in ipairs(CHALLENGES) do if k ~= R.lastKind then pool[#pool + 1] = k end end
        local b = M.pickEvent(pool[math.random(#pool)], opts[1] and opts[1].path or nil)
        if b then b.risky = true; opts[2] = b end
    end
    R.options, R.choice = opts, 1
    R.next = opts[1]
    return opts
end

-- kept for v1 callers / tests
function M.pickNext()
    M.makeOptions()
    return R.next
end

function M.nextSpec() return M.active() and R.next or nil end

-- RACE card between run races: switch the route (A <-> B). Returns the new spec.
function M.switchRoute()
    if not M.betweenRaces() or not R.options or #R.options < 2 then return nil end
    R.choice = (R.choice == 1) and 2 or 1
    R.next = R.options[R.choice]
    save()
    St.emit("status", M.routeText())
    return R.next
end

function M.routeText()
    if not (R and R.next) then return nil end
    local n = R.next
    local ev = M.eventOf(n.kind)
    local tag = (R.options and #R.options > 1) and ((R.choice == 1) and "ROUTE A" or "ROUTE B") or "LAST RACE"
    return string.format("%s: %s%s · %s", tag, ev.name, n.risky and " (CREDITS x1.5)" or "",
        tostring(n.planetName or n.planet or "?"))
end

-- the RACE card between run races: {planet, caption, track, footer}
function M.cardView()
    if not (M.betweenRaces() and R.next) then return nil end
    local n = R.next
    local ev = M.eventOf(n.kind)
    local cap = ev.name .. (n.risky and " · CREDITS x1.5" or "")
    if R.options and #R.options > 1 then cap = ((R.choice == 1) and "ROUTE A · " or "ROUTE B · ") .. cap end
    return { planet = tostring(n.planetName or n.planet or ""), caption = cap, track = tostring(n.name or n.track or ""),
             footer = M.standingsText() or "" }
end

-- launch.start: a run race gets the run builds and the race's AI tier; a new run starts here (RunLength set).
-- c = St.race.choice, plan = launch.plan(c) (players / arch / cls / aiTierPath / grid / maxRacers; plan.players is
-- the table the launch applies, modified in place). Returns true when the race is a run race.
function M.prelaunch(c, plan)
    ensureLoaded()
    if type(c) ~= "table" or type(plan) ~= "table" or type(plan.players) ~= "table" or plan.arch == nil then
        return false
    end
    local classKey = plan.cls and plan.cls.key or nil
    local starting = false
    if not M.active() then
        local len = M.lengthSetting()
        if not len then return false end
        R = { v = 1, status = "on", length = len, race = 1, hull = HULL_START, arch = plan.arch,
              classKey = classKey, players = {}, used = {}, history = {},
              elimRace = (len >= 4) and math.random(2, len - 1) or nil, startedAt = os.date("%Y-%m-%d %H:%M") }
        starting = true
        U.log(TAG, "GALAXY RUN started: %s, %d races, hull %d", tostring(R.classKey), len, R.hull)
    end
    if tonumber(plan.arch) ~= tonumber(R.arch) then
        St.emit("status", "GALAXY RUN: RACE IN " .. tostring(R.classKey) .. " (OPTIONS > GALAXY RUN: OFF TO LEAVE)")
        U.warn(TAG, "run race in another class (%s, run %s): played outside the run", tostring(classKey),
            tostring(R.classKey))
        return false
    end
    local Km = K()
    local humans = 0
    for pnum, pick in pairs(plan.players) do
        if type(pick) == "table" and pick.ctrlId ~= nil then
            humans = humans + 1
            local name = (pnum == 1) and "P1" or ("P" .. tostring(pnum))
            local p = ensurePlayer(pick.ctrlId, pnum, pick.pilotId, name)
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
    R.lastHumans = humans
    local kind = (not starting and R.next and R.next.kind) or "race"
    local ev = M.eventOf(kind)
    if ev.humansOnly then                           -- time trial: the grid is the humans alone
        plan.grid, plan.maxRacers = "max", math.max(1, humans)   -- the plan only: the stored choice keeps its grid
    end
    plan.aiTierPath = tierPath(R.arch, M.tierFor(R.race, R.length))
    -- pods have no tier build: the run's tier goes into the AI pods' own builds (perkapply.applyAI)
    plan.aiLoadout = nil
    if tonumber(R.arch) == 1 and M.tierFor(R.race, R.length) > 1 then
        pcall(function() plan.aiLoadout = U.mod("perkapply").tierLoadout(M.tierFor(R.race, R.length), R.arch) end)
    end
    R.flight = { race = R.race, label = tostring(c.label or "?"), planet = R.next and R.next.planet or nil,
                 kind = kind, risky = (not starting and R.next and R.next.risky) or nil, stats = {} }
    pcall(function() R.flight.track = c.track:GetFullName() end)
    save()
    St.emit("status", M.statusText())
    U.log(TAG, "run race %d / %d launched (%s, %s%s): AI %s, %d player(s)", R.race, R.length, ev.name,
        R.flight.label, R.flight.risky and ", risky route" or "",
        (plan.aiTierPath or plan.aiLoadout) and ("tier " .. M.tierFor(R.race, R.length)) or "base build (tier 1)",
        M.playerCount())
    return true
end

---------------------------------------------------------------------------------------------------- in-race counters
local function ctrlOfPnum(pnum)
    for _, e in ipairs(U.localPlayers()) do
        local okN, n = pcall(function() return U.mod("join").displayNumForPC(e.pc) end)
        if (okN and n == pnum) or (not okN and e.index == pnum) then return e.ctrlId end
    end
    return nil
end

local function stat(ctrlId)
    local st = R.flight.stats
    st[ctrlId] = st[ctrlId] or { boost = 0, takedowns = 0 }
    return st[ctrlId]
end

local lastBoostMs = nil
local lastEnergy = {}
-- FAST loop (main.lua, race phases): boost seconds per local car in a boost challenge. EBoostState is only the selected
-- boost (live: 2 = Afterburner even standing still), so: afterburner seconds = AfterburnerEnergy falling since the
-- last sample; ramjet seconds (IsRamjetting) count double. Paused races do not count.
local lastWreckPoll = 0
local function pollWrecks(now)
    if now - lastWreckPoll < 250 then return end
    lastWreckPoll = now
    local tko = U.mod("takeover")
    for _, e in ipairs(U.localPlayers()) do
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
    if R and R.flight and St.phase == "RACING" then pcall(pollWrecks, St.nowMs()) end   -- any player count / WreckMode
    if not (R and R.flight and R.flight.kind == "boost" and St.phase == "RACING") then
        lastBoostMs, lastEnergy = nil, {}
        return
    end
    local now = St.nowMs()
    if lastBoostMs and now - lastBoostMs < 100 then return end
    local dt = lastBoostMs and math.min(0.5, (now - lastBoostMs) / 1000) or 0
    lastBoostMs = now
    local okP, paused = pcall(U.csmPaused)
    if okP and paused == true then return end
    for _, e in ipairs(U.localPlayers()) do
        pcall(function()
            local car = e.pc.Pawn
            if not U.ok(car) or not U.isVehicle(car) then return end
            local vs = car.VehicleState
            local ram = false
            pcall(function() ram = vs:IsRamjetting() == true end)
            local en = tonumber(vs.AfterburnerEnergy)
            local prev = lastEnergy[e.ctrlId]
            lastEnergy[e.ctrlId] = en
            if dt <= 0 then return end
            local burning = en ~= nil and prev ~= nil and en < prev - 1e-4
            if ram then stat(e.ctrlId).boost = stat(e.ctrlId).boost + 2 * dt
            elseif burning then stat(e.ctrlId).boost = stat(e.ctrlId).boost + dt end
        end)
    end
end

-- The live line next to a player's race timer (hud.fastChallenge): the challenge counter, else the rival.
-- bestLap = that player's RaceEventComponent.BestLapTime (seconds, -1 = none yet).
function M.liveText(ctrlId, bestLap)
    if not (R and R.flight and St.phase == "RACING") then return nil end
    local kind = R.flight.kind or "race"
    local s = (R.flight.stats or {})[ctrlId] or { boost = 0, takedowns = 0 }
    if kind == "boost" then return string.format("BOOST %d S", math.floor(s.boost or 0)) end
    if kind == "takedown" then return string.format("TAKEDOWNS %d", s.takedowns or 0) end
    if kind == "hotlap" then
        local b = tonumber(bestLap) or -1
        return b > 0 and string.format("BEST LAP %.2f", b) or "HOT LAP"
    end
    if kind == "timetrial" then return "TIME TRIAL" end
    if R.rival then return "RIVAL " .. string.upper(tostring(R.rival)) end
    return nil
end

-- uxsplit's per-player HUD messages: "Takedown" = that player took a racer down (split races)
local function onHudMsg(pnum, id)
    if not (R and R.flight and St.phase == "RACING") then return end
    if id ~= "Takedown" then return end
    local c = ctrlOfPnum(pnum)
    if c ~= nil then stat(c).takedowns = stat(c).takedowns + 1 end
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
-- PlayerState; the challenge counters of this race.
local function snapshot()
    if not (R and R.flight) then return end
    local gs = U.gs()
    if not U.ok(gs) then return end
    local finished = false
    pcall(function() finished = gs.bIsRaceFinished == true end)
    local humans, keyToCtrl, all = {}, {}, {}
    local tko = U.mod("takeover")
    for _, e in ipairs(U.localPlayers()) do
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
                    local s = R.flight.stats[c] or { boost = 0, takedowns = 0 }
                    humans[c] = { pos = pos, dnf = (ft < 0), time = ft, lap = lap, wrecked = wrecked or s.wrecked == true,
                                  boost = s.boost or 0, takedowns = s.takedowns or 0 }
                end
            end
        end
    end)
    if next(humans) == nil then return end
    -- solo takedowns: the global race VM follows P1 (split races count through uxsplit's messages)
    if M.playerCount() <= 1 and R.flight.kind == "takedown" then
        pcall(function()
            local vm = U.giSubsystem("ViewModelSubsystem"):GetRaceEventVM()
            for c, h in pairs(humans) do h.takedowns = math.max(h.takedowns, tonumber(vm.NumberOfTakedowns) or 0) end
        end)
    end
    R.flight.snap = { n = n, humans = humans, all = all, finished = finished }
    local parts = {}
    for c, h in pairs(humans) do
        parts[#parts + 1] = string.format("c%d %s%s lap %.2f boost %.1f td %d", c, ordinal(h.pos), h.dnf and " DNF" or "",
            h.lap, h.boost, h.takedowns)
    end
    U.log(TAG, "race %d (%s) result: %s of %d racers (race finished %s)", R.flight.race, tostring(R.flight.kind),
        table.concat(parts, ", "), n, tostring(finished))
end
M._snapshot = snapshot

---------------------------------------------------------------------------------------------------- economy
-- a wreck breaks a random equipped part: unequipped and locked (owned, not usable) until repaired in the shop
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

local function priceOf(it)
    if it.rkind == "ab" then return 60 + 40 * (tonumber(it.lvl) or 1) end
    if it.rkind == "crash" then return 140 end
    if it.rkind == "part" then return 60 + 40 * (tonumber(it.pips) or 1) end
    if it.rkind == "trait" then return 150 end
    if it.rkind == "upgrade" then return 160 end
    if it.rkind == "repairpart" then return 120 end
    return 100
end

-- the shop stock of a player: 4 perks it does not own (mixed kinds) + the level-cap upgrade
function M.makeShop(p)
    local cat = catalog(R.arch)
    local o, taken, out = p.owned or emptyOwned(), {}, {}
    for _, k in ipairs({ "ab", "part", "trait", math.random() < 0.5 and "ab" or "part" }) do
        local it = pickFrom(cat[k], o[k], taken)
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
    local cat = nil
    for id in pairs(p.broken or {}) do
        local nm = id
        pcall(function() nm = (U.mod("perkdata").PARTS[id] or {}).name or id end)
        items[#items + 1] = { id = id, rkind = "repairpart", slot = "part1", iconKind = "tile",
                              name = string.format("REPAIR %s · %d CR", tostring(nm), priceOf({ rkind = "repairpart" })),
                              price = priceOf({ rkind = "repairpart" }) }
    end
    local rr = 50 + 25 * (p.rerolls or 0)
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

---------------------------------------------------------------------------------------------------- settle (v2)
-- the humans' ranking value of an event kind (lower is better; nil = no result)
local function rankValue(kind, h)
    local ev = M.eventOf(kind)
    if ev.rank == "place" then return (h.dnf and 100 or 0) + (h.pos or 99) end
    if ev.rank == "time" then return (not h.dnf and h.time and h.time > 0) and h.time or 1e9 end
    if ev.rank == "lap" then return (h.lap and h.lap > 0) and h.lap or 1e9 end
    if ev.rank == "boost" then return -(h.boost or 0) end
    if ev.rank == "takedown" then return -(h.takedowns or 0) * 1000 + (h.pos or 99) end
    return h.pos or 99
end

-- the team target of an event; -> met, detail text
local function targetMet(kind, snap, race, len)
    local ev = M.eventOf(kind)
    local nh, best, allFin, team = 0, 99, true, 0
    for _, h in pairs(snap.humans) do
        nh = nh + 1
        if not h.dnf and (h.pos or 99) < best then best = h.pos or 99 end
        if h.dnf then allFin = false end
        if ev.rank == "boost" then team = team + (h.boost or 0) end
        if ev.rank == "takedown" then team = team + (h.takedowns or 0) end
    end
    if ev.rank == "place" then
        local t = M.targetFor(race, len, nh)
        return best <= t, best < 99 and ("BEST " .. ordinal(best)) or "NOBODY FINISHED"
    elseif ev.rank == "time" then
        return allFin, allFin and "EVERYBODY FINISHED" or "A PLAYER DID NOT FINISH"
    elseif ev.rank == "lap" then
        local laps = {}
        for _, a in ipairs(snap.all or {}) do if a.lap and a.lap > 0 then laps[#laps + 1] = a end end
        table.sort(laps, function(a, b) return a.lap < b.lap end)
        local lt = M.lapTarget(nh)
        for i = 1, math.min(lt, #laps) do if not laps[i].bot then return true, string.format("LAP %.2f", laps[i].lap) end end
        return false, "NO HUMAN LAP IN THE TOP " .. lt
    elseif ev.rank == "boost" then
        local need = BOOST_TARGET_S * math.max(1, nh)
        return team >= need, string.format("%d / %d S OF BOOST", math.floor(team), need)
    elseif ev.rank == "takedown" then
        return team >= nh, string.format("%d / %d TAKEDOWNS", team, nh)
    end
    return false, "?"
end
M._targetMet = targetMet

-- Back in the front end: score the race (or drop it when it did not end), credits, faults, rewards, next routes.
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
    local kind = fl.kind or "race"
    local ev = M.eventOf(kind)
    -- humans ranked by the event's value
    local order = {}
    for c, h in pairs(fl.snap.humans) do order[#order + 1] = { c = c, h = h, v = rankValue(kind, h) } end
    table.sort(order, function(a, b) if a.v ~= b.v then return a.v < b.v end return (a.h.pos or 99) < (b.h.pos or 99) end)
    -- the rival's place (an AI racer, by name)
    local rivalPos = nil
    for _, a in ipairs(fl.snap.all or {}) do if R.rival and a.bot and a.name == R.rival then rivalPos = a.pos end end
    local mult = fl.risky and RISKY_MULT or 1
    local res, broke = {}, {}
    local worstC = order[#order] and order[#order].c or nil
    for i, e in ipairs(order) do
        local p = R.players[e.c]
        local counts = not (ev.rank == "place" or ev.rank == "time") or not e.h.dnf
        local pts = counts and (POINTS[i] or 0) or 0
        local cr = counts and math.floor((CREDITS[i] or 100) * mult) or math.floor(60 * mult)
        local beatRival = rivalPos ~= nil and not e.h.dnf and (e.h.pos or 99) < rivalPos
        if beatRival then cr = cr + RIVAL_BONUS end
        if p then
            p.points = (p.points or 0) + pts
            p.credits = (p.credits or START_CREDITS) + cr
            if i == 1 and not e.h.dnf then p.wins = (p.wins or 0) + 1 end
            if e.h.wrecked then
                local id = breakPart(p)
                if id then broke[#broke + 1] = string.format("%s: %s BROKEN", tostring(p.name), id) end
            end
        end
        res[e.c] = { rank = i, pos = e.h.pos, dnf = e.h.dnf, pts = pts, cr = cr, rival = beatRival or nil }
    end
    local met, detail = targetMet(kind, fl.snap, fl.race, R.length)
    if not met then R.hull = R.hull - 1 end
    R.history[#R.history + 1] = { race = fl.race, label = fl.label, kind = kind, met = met, detail = detail, res = res }
    R.used[fl.track or ("race" .. fl.race)] = true
    if not fl.planet and fl.track then                        -- race 1 (chosen by the players): find its planet
        pcall(function()
            for _, c in ipairs(candidates()) do
                if c.path == fl.track then fl.planet = c.planet end
            end
        end)
    end
    R.lastPlanet, R.lastKind = fl.planet, kind
    -- the next rival: the AI that placed best
    local bestAI = nil
    for _, a in ipairs(fl.snap.all or {}) do if a.bot and (not bestAI or a.pos < bestAI.pos) then bestAI = a end end
    R.rival = bestAI and bestAI.name or R.rival
    -- the final is a must-win: missed with hull left -> another final (same race number), until won or hull 0
    local finalAgain = ((kind == "final" or fl.race >= R.length) and not met and R.hull > 0)
    if not finalAgain then R.race = R.race + 1 end
    for c, p in pairs(R.players) do
        p.cap = (p.cap or 1) + 1
        p.credits = p.credits or START_CREDITS
        if R.hull > 0 and R.race <= R.length then
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
    elseif R.race > R.length then
        R.status = "won"
        msg = M.statusText()
        archive("WON")
    elseif finalAgain then
        M.makeOptions()
        msg = string.format("FINAL LOST (%s): HULL -1, RACE THE FINAL AGAIN · %s", detail, M.statusText())
    else
        M.makeOptions()
        msg = string.format("%s (%s) · %s WINS THE %s · %s", met and "TARGET MET" or "TARGET MISSED: HULL -1", detail,
            winner and tostring(winner.name) or "?", ev.name, M.statusText())
    end
    if #broke > 0 then msg = msg .. " · " .. table.concat(broke, ", ") end
    save()
    St.emit("status", msg)
    U.log(TAG, "race %d (%s) settled: %s, target %s, hull %d, rival %s, next %s", fl.race, ev.name, detail,
        met and "met" or "missed", R.hull, tostring(R.rival), R.next and (tostring(R.next.kind) .. " " .. tostring(R.next.track)) or "-")
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
    if not R.next then R.next = M.pickNext(); save() end
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
    St.emit("status", string.format("%s: %s TARGET %s.", ev.name, ev.rule,
        M.targetText(spec.kind, R.race, R.length)))
    return true
end

---------------------------------------------------------------------------------------------------- events
function M.init()
    ensureLoaded()
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
    St.on("hudmsg", TAG, function(pnum, id) U.try(TAG, onHudMsg, pnum, id) end)
    St.on("humanWrecked", TAG, function(pc)
        if not (R and R.flight) then return end
        for _, e in ipairs(U.localPlayers()) do
            if U.ok(e.pc) and U.key(e.pc) == U.key(pc) then
                stat(e.ctrlId).wrecked = true
                U.log(TAG, "c%d wrecked: a part breaks at the race end", e.ctrlId)
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

return M
