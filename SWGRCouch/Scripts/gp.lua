-- gp.lua: the GALACTIC GRAND PRIX (design notes/design/galactic-grand-prix.md). Jules 2026-10-15: "Call the section
-- Galactic Grand Prix ... podracer tours, planet tours, championship per planet, galactic championship ... options but
-- not too many ... Custom will give a lot of options"; "make it fair; options to add advantages and disadvantages".
--
-- A championship of 1..12 races on the FREE MODE launch path: every race opens the RACERS cards on the slot's track
-- (setup.openRun), launch.lua calls M.prelaunch (GP builds, AI tier, per-player class), the POSTRACE edge snapshots
-- every racer's place, FRONTEND settles it: 25-18-15-12-10-8-6-4-2-1 for every racer (AI by name), standings, and a
-- podium after the last race. Mod-owned state in Mods/SWGRCouch/gp.txt (+ gp-history.txt); never the game's save.
--
-- Two halves:
--   * PURE (offline-tested, tools/test_gp.lua): tours, drafts (the setup page's choices), slot stepping / random draw /
--     order, the equal-upgrade budget, scoring, standings, podium. No UObject, no game call.
--   * PLUMBING (same contract as run.lua): prelaunch / snapshot / settle / openNext / init; every game read guarded.
local U = require("util")
local St = require("state")
local cfg = require("config")
local settings = require("settings")

local TAG = "gp"
local M = {}

local okD, D = pcall(require, "gpdata")
if not okD or type(D) ~= "table" then D = { SPEEDER_PLANETS = {}, speeder = {}, pod = {} } end

M.POINTS = { 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 }
M.UPGRADES = { 0, 3, 6, 10, 15 }            -- 0 = NONE; else EQUAL n levels to spread
M.AI_NAMES = { "ROOKIE", "CADET", "PRO", "ACE", "VETERAN", "LEGEND" }
M.CLASSES = { "Car", "Bike", "Skimmer" }    -- the speeder classes a player picks (vehicles.CLASSES keys)
M.CLASS_LABEL = { Car = "LANDSPEEDER", Bike = "SPEEDER BIKE", Skimmer = "SKIM SPEEDER", Plane = "PODRACER" }
M.ARCH = { Car = 0, Plane = 1, Bike = 2, Skimmer = 3 }
M.PLANET_NAME = { Mastiff = "JAKKU", Dalmatian = "LANTAANA", Husky = "SENTINEL I", Corgi = "ANDO PRIME",
                  Spaniel = "CRAIT", Whippet = "DERVEN ACOS", Beagle = "TATOOINE" }
M.LEVEL_MAX = 10
M.FINALE = "TRAK_WHP_LOOP_A_FWD_ARC"        -- THE GALACTIC GAUNTLET (Derven Acos): the Galactic Championship finale
local FILE, HISTORY = "gp.txt", "gp-history.txt"

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

---------------------------------------------------------------------------------------------------- tours
-- count = {min, max, default}; fixed = the race list is the planet's circuits (no count, no slot edits)
M.TOURS = {
    { key = "pod", title = "PODRACER\nTOUR", name = "PODRACER TOUR", pool = "pod", count = { 3, 12, 8 },
      kicker = "Pods · pick your podracer", vehicles = "pods" },
    { key = "planet", title = "PLANET\nTOUR", name = "PLANET TOUR", pool = "planet", count = { 3, 12, 4 }, planet = true,
      kicker = "One planet · 4 races", vehicles = "each" },
    { key = "champ", title = "PLANET\nCHAMPIONSHIP", name = "PLANET CHAMPIONSHIP", pool = "planet", planet = true,
      fixed = true, kicker = "Every circuit of a planet", vehicles = "each" },
    { key = "galactic", title = "GALACTIC\nCHAMPIONSHIP", name = "GALACTIC CHAMPIONSHIP", pool = "speeder",
      count = { 3, 12, 8 }, kicker = "Every planet · Gauntlet finale", vehicles = "each" },
    { key = "custom", title = "CUSTOM", name = "CUSTOM GRAND PRIX", pool = "custom", count = { 1, 12, 6 },
      kicker = "Every option", vehicles = "each", custom = true },
}
local TOUR = {}
for _, t in ipairs(M.TOURS) do TOUR[t.key] = t end
function M.tour(key) return TOUR[key] end

-- planets a planet tour can pick: at least 3 circuits (Derven Acos has one track)
function M.planets()
    local out = {}
    for _, p in ipairs(D.SPEEDER_PLANETS or {}) do
        if #(D.speeder[p] or {}) >= 3 then out[#out + 1] = p end
    end
    return out
end

local function podAllowed(e) return e.proven or opt("GPPodTourTracks", true) ~= false end

local function entry(e, planet, group)
    return { key = e.key, planet = planet or e.planet, name = e.name, layout = e.layout or "", conds = e.conds or {},
             set = e.set or "arcade", group = group, proven = e.proven ~= false }
end

-- the track pool of a draft: list of entries {key, planet, name, layout, conds, set, group = "speeder" | "pod"}
function M.pool(dr)
    local t = TOUR[dr.tour] or TOUR.galactic
    local kind = t.pool
    if kind == "custom" then kind = (dr.custom and dr.custom.vehicles == "pods") and "pod" or "speeder" end
    local out = {}
    if kind == "pod" then
        for _, e in ipairs(D.pod or {}) do if podAllowed(e) then out[#out + 1] = entry(e, e.planet, "pod") end end
    elseif kind == "planet" then
        for _, e in ipairs(D.speeder[dr.planet or ""] or {}) do out[#out + 1] = entry(e, dr.planet, "speeder") end
    else
        for _, p in ipairs(D.SPEEDER_PLANETS or {}) do
            for _, e in ipairs(D.speeder[p] or {}) do out[#out + 1] = entry(e, p, "speeder") end
        end
    end
    return out
end

function M.findTrack(key)
    for _, e in ipairs(D.pod or {}) do if e.key == key then return entry(e, e.planet, "pod") end end
    for _, p in ipairs(D.SPEEDER_PLANETS or {}) do
        for _, e in ipairs(D.speeder[p] or {}) do if e.key == key then return entry(e, p, "speeder") end end
    end
    return nil
end

-- the plain variant of a circuit: no HARD / MINES / SCORCHING, forward first
local function plainScore(e)
    local s = 0
    local l = e.layout or ""
    if l:find("HARD") or l:find("SCORCHING") then s = s + 4 end
    if l:find("MINES") then s = s + 2 end
    if l:find("REVERSE") then s = s + 1 end
    return s
end

-- every distinct circuit (display name) of a planet, its plain variant, in the planet list's name order
function M.circuits(planet)
    local best, order = {}, {}
    for _, e in ipairs(D.speeder[planet] or {}) do
        local b = best[e.name]
        if not b then order[#order + 1] = e.name end
        if not b or plainScore(e) < plainScore(b) then best[e.name] = e end
    end
    local out = {}
    for _, n in ipairs(order) do out[#out + 1] = best[n].key end
    return out
end

-- default race list of a tour (keys); n = the race count
local POD_DEFAULT = { "TRAK_BGL_PLANE_FWD_PDay", "TRAK_DAL_PLANE_FWD_Pday", "TRAK_INSTA_COR_PLANE_FWD",
                      "TRAK_MP_COR_Loop_A_FWD_PLANE", "TRAK_SPA_PLANE_FWD_PDay", "TRAK_MP_DAL_PLANE_REV",
                      "TRAK_MP_HSK_P2P_FWD_PLANE", "TRAK_INSTA_COR_PLANE_REV" }
local GALACTIC_PLANETS = { "Mastiff", "Dalmatian", "Husky", "Corgi", "Spaniel", "Mastiff", "Corgi" }

function M.defaultSlots(dr, n)
    local t = TOUR[dr.tour] or TOUR.galactic
    local pool = M.pool(dr)
    local inPool = {}
    for _, e in ipairs(pool) do inPool[e.key] = true end
    local out = {}
    local function add(k) if #out < n and k and inPool[k] then out[#out + 1] = k end end
    if t.fixed then
        for _, k in ipairs(M.circuits(dr.planet)) do out[#out + 1] = k end
        return out
    end
    if t.pool == "pod" or (t.custom and dr.custom and dr.custom.vehicles == "pods") then
        for _, k in ipairs(POD_DEFAULT) do add(k) end
        for _, e in ipairs(pool) do
            local seen = false
            for _, k in ipairs(out) do if k == e.key then seen = true end end
            if not seen then add(e.key) end
        end
    elseif t.pool == "planet" then
        for _, k in ipairs(M.circuits(dr.planet)) do add(k) end
    else
        -- one circuit per planet (round robin over their circuit lists), the Gauntlet as the finale
        local idx = {}
        local finale = (n >= 2) and M.findTrack(M.FINALE) ~= nil
        local room = finale and n - 1 or n
        local i = 0
        while #out < room and i < 60 do
            i = i + 1
            local p = GALACTIC_PLANETS[((i - 1) % #GALACTIC_PLANETS) + 1]
            local list = M.circuits(p)
            idx[p] = (idx[p] or 0) + 1
            if list[idx[p]] then add(list[idx[p]]) end
        end
        if finale then out[#out + 1] = M.FINALE end
    end
    while #out < n do out[#out + 1] = "random" end
    return out
end

---------------------------------------------------------------------------------------------------- drafts
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function M.newDraft(tourKey, players)
    local t = TOUR[tourKey] or TOUR.galactic
    local dr = { tour = t.key, upgrades = 6, order = "listed", ai = 3, classes = {} }
    if t.planet then dr.planet = M.planets()[1] or "Mastiff" end
    if t.custom then
        dr.custom = { vehicles = "each", grid = "full", weather = "default", catchup = false, noAbilities = false,
                      handicap = {} }
    end
    for _, pn in ipairs(players or { 1 }) do dr.classes[pn] = "Car" end
    dr.count = t.count and t.count[3] or nil
    dr.slots = M.defaultSlots(dr, dr.count or 0)
    if t.fixed then dr.count = #dr.slots end
    return dr
end

function M.countRange(dr)
    local t = TOUR[dr.tour]
    if not t or t.fixed then return nil end
    return t.count[1], t.count[2]
end

-- RACES row: n races (slots kept, new ones from the defaults, else RANDOM)
function M.setCount(dr, n)
    local lo, hi = M.countRange(dr)
    if not lo then return dr.count end
    n = clamp(math.floor(tonumber(n) or lo), lo, hi)
    local def = M.defaultSlots(dr, n)
    local out = {}
    for i = 1, n do out[i] = dr.slots[i] or def[i] or "random" end
    -- a list that ended on the finale keeps it last
    local had = dr.slots[#dr.slots] == M.FINALE
    if had and n < #dr.slots then out[n] = M.FINALE end
    dr.slots, dr.count = out, n
    return n
end

-- LEFT / RIGHT on slot i: the pool in order, then RANDOM, wrapping. Fixed tours: nothing.
function M.stepSlot(dr, i, dir)
    local t = TOUR[dr.tour]
    if not t or t.fixed or not dr.slots[i] then return nil end
    local pool = M.pool(dr)
    local cycle = {}
    for _, e in ipairs(pool) do cycle[#cycle + 1] = e.key end
    cycle[#cycle + 1] = "random"
    local cur = 0
    for j, k in ipairs(cycle) do if k == dr.slots[i] then cur = j end end
    if cur == 0 then cur = #cycle end
    local nxt = ((cur - 1 + (dir < 0 and -1 or 1)) % #cycle) + 1
    dr.slots[i] = cycle[nxt]
    return dr.slots[i]
end

local function cycleList(list, cur, dir)
    local i = 1
    for j, v in ipairs(list) do if v == cur then i = j end end
    return list[((i - 1 + (dir < 0 and -1 or 1)) % #list) + 1]
end

-- the option rows (A / LEFT / RIGHT step them). key: planet | count | upgrades | order | ai | class<pnum> |
-- vehicles | grid | weather | catchup | noAbilities | hcap<pnum>
function M.stepOption(dr, key, dir)
    dir = (dir or 1) < 0 and -1 or 1
    if key == "planet" and dr.planet then
        dr.planet = cycleList(M.planets(), dr.planet, dir)
        dr.slots = M.defaultSlots(dr, (TOUR[dr.tour].fixed and 99) or dr.count)
        if TOUR[dr.tour].fixed then dr.count = #dr.slots end
    elseif key == "count" then
        M.setCount(dr, (dr.count or 0) + dir)
    elseif key == "upgrades" then
        dr.upgrades = cycleList(M.UPGRADES, dr.upgrades, dir)
    elseif key == "order" then
        dr.order = (dr.order == "random") and "listed" or "random"
    elseif key == "ai" then
        dr.ai = clamp(((dr.ai or 3) - 1 + dir) % 6 + 1, 1, 6)
    elseif key:match("^class%d$") then
        local pn = tonumber(key:sub(6))
        dr.classes[pn] = cycleList(M.CLASSES, dr.classes[pn] or "Car", dir)
    elseif dr.custom and key == "vehicles" then
        local was = dr.custom.vehicles
        dr.custom.vehicles = cycleList({ "each", "same", "pods" }, was, dir)
        if (was == "pods") ~= (dr.custom.vehicles == "pods") then dr.slots = M.defaultSlots(dr, dr.count) end
    elseif dr.custom and key == "grid" then
        local list = { "full", 0, 1, 3, 5, 7, 9, 11 }
        dr.custom.grid = cycleList(list, dr.custom.grid, dir)
    elseif dr.custom and key == "weather" then
        dr.custom.weather = (dr.custom.weather == "random") and "default" or "random"
    elseif dr.custom and key == "catchup" then
        dr.custom.catchup = not dr.custom.catchup
    elseif dr.custom and key == "noAbilities" then
        dr.custom.noAbilities = not dr.custom.noAbilities
    elseif dr.custom and key:match("^hcap%d$") then
        local pn = tonumber(key:sub(5))
        dr.custom.handicap[pn] = clamp((dr.custom.handicap[pn] or 0) + dir * 2, -6, 6)
    end
    return dr
end

-- display words of the shared options
function M.upgradesText(n) n = tonumber(n) or 0; return n <= 0 and "NONE" or string.format("EQUAL · %d LEVELS", n) end
function M.orderText(o) return o == "random" and "RANDOM" or "AS LISTED" end
function M.aiText(t) return M.AI_NAMES[clamp(tonumber(t) or 3, 1, 6)] end

---------------------------------------------------------------------------------------------------- start
-- the tour's vehicle rule: "pods" | "each" | "same"
function M.vehicleRule(dr)
    local t = TOUR[dr.tour] or TOUR.galactic
    if t.custom and dr.custom then return dr.custom.vehicles end
    return t.vehicles
end

-- draft -> a running GP. humans = list {pnum, ctrlId, name}; rnd = function(n) -> 1..n (math.random by default).
-- RANDOM slots are drawn from the pool's unused tracks (distinct circuits first); ORDER RANDOM shuffles the list,
-- a finale (Derven Acos in the last slot) stays last.
function M.start(dr, humans, rnd)
    rnd = rnd or function(n) return math.random(n) end
    local pool = M.pool(dr)
    local used, usedName = {}, {}
    for _, k in ipairs(dr.slots) do
        if k ~= "random" then
            used[k] = true
            local e = M.findTrack(k)
            if e then usedName[e.planet .. "|" .. e.name] = true end
        end
    end
    local keys = {}
    for i, k in ipairs(dr.slots) do
        if k == "random" then
            local fresh, any = {}, {}
            for _, e in ipairs(pool) do
                if not used[e.key] then
                    any[#any + 1] = e
                    if not usedName[e.planet .. "|" .. e.name] then fresh[#fresh + 1] = e end
                end
            end
            local list = (#fresh > 0) and fresh or ((#any > 0) and any or pool)
            local e = list[rnd(#list)]
            if e then
                keys[i] = e.key
                used[e.key], usedName[e.planet .. "|" .. e.name] = true, true
            end
        else
            keys[i] = k
        end
    end
    local finale = nil
    if keys[#keys] and (M.findTrack(keys[#keys]) or {}).planet == "Whippet" and #keys > 1 then
        finale = table.remove(keys)
    end
    if dr.order == "random" then
        for i = #keys, 2, -1 do
            local j = rnd(i)
            keys[i], keys[j] = keys[j], keys[i]
        end
    end
    if finale then keys[#keys + 1] = finale end
    local rule = M.vehicleRule(dr)
    local races = {}
    for _, k in ipairs(keys) do
        local e = M.findTrack(k)
        if e then
            local cond = e.conds[1] or ""
            if dr.custom and dr.custom.weather == "random" and #e.conds > 0 then cond = e.conds[rnd(#e.conds)] end
            races[#races + 1] = { key = e.key, planet = e.planet, name = e.name, layout = e.layout, set = e.set,
                                  group = e.group, cond = cond }
        end
    end
    local G = { v = 1, status = "on", tour = dr.tour, planet = dr.planet, rule = rule, upgrades = dr.upgrades or 0,
                ai = dr.ai or 3, order = dr.order, custom = dr.custom, races = races, race = 1, table = {},
                players = {}, history = {}, bonus = {}, tune = {}, startedAt = os.date("%Y-%m-%d %H:%M") }
    for _, h in ipairs(humans or {}) do
        local cls = (rule == "pods") and "Plane" or (dr.classes[h.pnum] or "Car")
        if rule == "same" then cls = dr.classes[1] or "Car" end
        G.players[h.ctrlId] = { pnum = h.pnum, ctrlId = h.ctrlId, name = h.name or ("P" .. h.pnum), cls = cls }
    end
    return G
end

---------------------------------------------------------------------------------------------------- the upgrade budget
-- levels a player may spread this race: the tour's EQUAL n (0 = NONE) + his CUSTOM handicap + a catch-up bonus
function M.budget(G, pnum)
    local n = tonumber(G and G.upgrades) or 0
    if G and G.custom and G.custom.handicap then n = n + (tonumber(G.custom.handicap[pnum]) or 0) end
    if G and G.bonus then n = n + (tonumber(G.bonus[pnum]) or 0) end
    return math.max(0, n)
end

function M.levelsUsed(tune)
    local s = 0
    for i = 0, 5 do s = s + math.max(0, math.floor(tonumber(type(tune) == "table" and tune[i] or 0) or 0)) end
    return s
end

-- can stat i go one level up? -> ok, reason ("budget" | "max")
function M.canRaise(tune, i, budget)
    local cur = math.floor(tonumber(tune and tune[i]) or 0)
    if cur >= M.LEVEL_MAX then return false, "max" end
    if M.levelsUsed(tune) >= budget then return false, "budget" end
    return true
end

-- a tune clamped to the budget (each stat 0..10; over budget: levels come off the last stats first)
function M.clampTune(tune, budget)
    local out = {}
    for i = 0, 5 do out[i] = clamp(math.floor(tonumber(type(tune) == "table" and tune[i] or 0) or 0), 0, M.LEVEL_MAX) end
    local over = M.levelsUsed(out) - math.max(0, budget)
    for i = 5, 0, -1 do
        if over <= 0 then break end
        local cut = math.min(out[i], over)
        out[i], over = out[i] - cut, over - cut
    end
    return out
end

-- the GP build of a player: the style's kit (abilities, crash, traits; a pod = its own build) with no parts and
-- `tune` (already clamped) as the stat levels; noAbilities (CUSTOM handicap) clears the d-pad and crash slots.
function M.loadout(arch, style, tune, noAbilities)
    local Km = U.mod("perks")
    local lo = Km.fromKit("pilot", arch, style)
    local kitKey = type(lo.style) == "string" and lo.style or nil
    for i = 1, #(lo.parts or {}) do lo.parts[i] = false end
    lo.tune = {}
    for i = 0, 5 do lo.tune[i] = tune[i] or 0 end
    if noAbilities then
        for i = 1, 4 do lo.ab[i] = false end
        lo.crash = false
    end
    lo.kit, lo.from = "custom", nil
    local out = Km.validate(lo, arch, style)
    out.gp = true
    out.style = out.style or kitKey
    return out
end

---------------------------------------------------------------------------------------------------- scoring
local function rowOf(G, id, name, human)
    local r = G.table[id]
    if not r then
        r = { id = id, name = name, human = human, points = 0, wins = 0, places = {}, races = 0 }
        G.table[id] = r
    end
    if name then r.name = name end
    return r
end

-- one race's result. snap.all = list {name, pos, dnf, ctrlId (humans) | nil}; the pos field is the game's
-- EventPosition (1-based). Places are re-ranked 1..n by pos (gaps / duplicates from the game tolerated).
function M.applyResult(G, snap)
    local list = {}
    for _, a in ipairs(snap and snap.all or {}) do list[#list + 1] = a end
    table.sort(list, function(a, b)
        if (a.dnf == true) ~= (b.dnf == true) then return b.dnf == true end
        if (a.pos or 99) ~= (b.pos or 99) then return (a.pos or 99) < (b.pos or 99) end
        return tostring(a.name) < tostring(b.name)
    end)
    local res = {}
    for i, a in ipairs(list) do
        local human = a.ctrlId ~= nil
        local id = human and ("c" .. tostring(a.ctrlId)) or ("ai:" .. tostring(a.name))
        local name = a.name
        if human and G.players[a.ctrlId] then name = G.players[a.ctrlId].name end
        local r = rowOf(G, id, name, human)
        local pts = (not a.dnf) and (M.POINTS[i] or 0) or 0
        r.points = r.points + pts
        r.races = r.races + 1
        if not a.dnf then
            r.places[i] = (r.places[i] or 0) + 1
            if i == 1 then r.wins = r.wins + 1 end
        end
        r.last = a.dnf and 99 or i
        res[#res + 1] = { id = id, name = name, human = human, place = i, dnf = a.dnf == true, pts = pts }
    end
    local race = G.races[G.race] or {}
    G.history[#G.history + 1] = { race = G.race, key = race.key, name = race.name, res = res }
    G.race = G.race + 1
    if G.race > #G.races then G.status = "done" end
    -- CUSTOM catch-up: the last human in the table gets +2 levels for the next race
    G.bonus = {}
    if G.custom and G.custom.catchup and G.status == "on" then
        local worst = nil
        for _, r in ipairs(M.standings(G)) do if r.human then worst = r end end
        local nh = 0
        for _ in pairs(G.players) do nh = nh + 1 end
        if worst and nh > 1 then
            local p = G.players[tonumber(worst.id:sub(2))]
            if p then G.bonus[p.pnum] = 2 end
        end
    end
    return res
end

local function placesCmp(a, b)
    for i = 1, 12 do
        local x, y = a.places[i] or 0, b.places[i] or 0
        if x ~= y then return x > y end
    end
    return nil
end

-- the table, best first: points, wins (places[1]), then more 2nds / 3rds ..., then the last race's place, then name
function M.standings(G)
    local out = {}
    for _, r in pairs(G and G.table or {}) do out[#out + 1] = r end
    table.sort(out, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        local c = placesCmp(a, b)
        if c ~= nil then return c end
        if (a.last or 99) ~= (b.last or 99) then return (a.last or 99) < (b.last or 99) end
        return tostring(a.name) < tostring(b.name)
    end)
    for i, r in ipairs(out) do r.rank = i end
    return out
end

function M.podium(G)
    local s = M.standings(G)
    return { s[1], s[2], s[3] }
end

---------------------------------------------------------------------------------------------------- persistence
local F = { loaded = false, gp = nil, drafts = {} }

local function path(name)
    local ok, d = pcall(function() return settings.modDir() end)
    if not ok or type(d) ~= "string" then return nil end
    return d .. "/" .. name
end

-- run.txt's serializer (sorted keys: the file diffs cleanly between races)
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
    local p = path(FILE)
    if not p then return end
    local f, err = io.open(p, "w")
    if not f then U.warn(TAG, "gp.txt not written: %s", tostring(err)); return end
    f:write("-- SWGRCouch GALACTIC GRAND PRIX (mod-owned; delete this file to drop the Grand Prix)\nreturn "
        .. ser({ v = 1, gp = F.gp, drafts = F.drafts }) .. "\n")
    f:close()
end

local function loadFile()
    F.loaded = true
    local p = path(FILE)
    local f = p and io.open(p, "r")
    if not f then return end
    local text = f:read("a")
    f:close()
    local chunk = load(text, "gp.txt", "t", {})
    local ok, t = false, nil
    if chunk then ok, t = pcall(chunk) end
    if ok and type(t) == "table" and t.v == 1 then
        F.gp = type(t.gp) == "table" and t.gp or nil
        F.drafts = type(t.drafts) == "table" and t.drafts or {}
        if F.gp then
            U.log(TAG, "Grand Prix loaded: %s, race %d of %d (%s)", tostring(F.gp.tour), F.gp.race or 0,
                #(F.gp.races or {}), tostring(F.gp.status))
        end
    else
        U.warn(TAG, "gp.txt unreadable: no Grand Prix")
    end
end

local function ensure() if not F.loaded then loadFile() end end

local function archive(outcome)
    local G = F.gp
    if not G then return end
    local p = path(HISTORY)
    local f = p and io.open(p, "a")
    if not f then return end
    local parts = {}
    for i, r in ipairs(M.standings(G)) do
        if i <= 6 or r.human then parts[#parts + 1] = string.format("%d. %s %d", i, tostring(r.name), r.points) end
    end
    f:write(string.format("%s  %s  %s  races %d/%d  %s\n", os.date("%Y-%m-%d %H:%M"), outcome,
        tostring((TOUR[G.tour] or {}).name or G.tour), math.min(G.race - 1, #G.races), #G.races, table.concat(parts, ", ")))
    f:close()
end

function M.state() ensure(); return F.gp end
function M.active() ensure(); return F.gp ~= nil and F.gp.status == "on" end
function M.done() ensure(); return F.gp ~= nil and F.gp.status == "done" end
function M.inFlight() return M.active() and F.gp.flight ~= nil end
function M.betweenRaces() return M.active() and F.gp.flight == nil end
function M.nextRace() return M.active() and F.gp.races[F.gp.race] or nil end

-- a GP owns the builds of this class's launches (quick.lua stays out; run.lua refuses)
function M.owns() return M.active() end

-- the draft of a tour (kept across visits in gp.txt); players = the current pnums
function M.draft(tourKey, players)
    ensure()
    local dr = F.drafts[tourKey]
    if type(dr) ~= "table" or type(dr.slots) ~= "table" then
        dr = M.newDraft(tourKey, players)
        F.drafts[tourKey] = dr
    end
    for _, pn in ipairs(players or {}) do dr.classes[pn] = dr.classes[pn] or "Car" end
    return dr
end
function M.saveDrafts() save() end

function M.begin(dr, humans)
    ensure()
    if F.gp and F.gp.status == "on" then archive("ABANDONED") end
    math.randomseed(os.time())
    F.gp = M.start(dr, humans)
    save()
    U.log(TAG, "Grand Prix started: %s, %d race(s), upgrades %s, AI %s, %d player(s)", tostring(dr.tour),
        #F.gp.races, M.upgradesText(F.gp.upgrades), M.aiText(F.gp.ai), #humans)
    return F.gp
end

function M.abandon(why)
    ensure()
    if not F.gp then return end
    if F.gp.status == "on" then archive("ABANDONED") end
    U.log(TAG, "Grand Prix dropped (%s)", tostring(why))
    F.gp = nil
    save()
end

-- the podium was seen: archive and clear
function M.finish()
    ensure()
    if F.gp and F.gp.status == "done" then archive("FINISHED") end
    F.gp = nil
    save()
end

---------------------------------------------------------------------------------------------------- racer cards
-- racers.lua: the build a card shows while a GP is on: the style's kit with no parts and the player's spread (his
-- last GP race's, else the card's previous levels) clamped to his budget. style = the card's chosen style, else the
-- pilot's. -> lo, budget
function M.cardLoadout(ctrlId, pnum, arch, style, prev)
    local G = M.state()
    if not (G and G.status == "on") then return nil end
    local b = M.budget(G, pnum)
    local src = (type(prev) == "table" and prev.gp and prev.tune) or G.tune[ctrlId] or (type(prev) == "table" and prev.tune)
    local tune = M.clampTune(src, b)
    local ok, lo = pcall(M.loadout, arch, style, tune, G.custom and G.custom.noAbilities)
    if not ok then return nil end
    return lo, b
end

-- racers.lua: one level up on stat i? -> ok, toast text
function M.cardRaise(lo, i, pnum)
    local G = M.state()
    if not (G and G.status == "on") then return true end
    local b = M.budget(G, pnum)
    local ok, why = M.canRaise(lo and lo.tune, i, b)
    if ok then return true end
    if why == "max" then return false, "LEVEL 10 IS THE MAXIMUM" end
    if b == 0 then return false, "GRAND PRIX: NO UPGRADES" end
    return false, string.format("GRAND PRIX: ALL %d LEVELS USED", b)
end

-- the card's toast line: "GRAND PRIX · 6 LEVELS TO SPREAD" / "GRAND PRIX · NO UPGRADES"
function M.cardLine(pnum)
    local G = M.state()
    if not (G and G.status == "on") then return nil end
    local b = M.budget(G, pnum)
    if b == 0 then return "GRAND PRIX · NO UPGRADES" end
    return string.format("GRAND PRIX · %d LEVELS TO SPREAD", b)
end

-- racers.lua: the speeder class (vehicles.CLASSES key) a player's racer card shows and races in the GP's next race:
-- his own one (the setup page's P<n> vehicle) on a speeder race of the "each" rule, nil = the page's class (pods, the
-- "same" rule, GPPerPlayerClass off, a late joiner without a GP entry). live2 (2026-10-15): the cards were built from
-- the page's (P1's) class for everybody while prelaunch raced P2 on his own; the card itself now is in his class.
function M.cardClass(ctrlId)
    local G = M.state()
    if not (G and G.status == "on") then return nil end
    local r = G.races[G.race]
    if not r or r.group == "pod" or G.rule ~= "each" or opt("GPPerPlayerClass", true) == false then return nil end
    local p = G.players[tonumber(ctrlId) or -1]
    if p and p.cls ~= "Plane" and M.ARCH[p.cls] then return p.cls end
    return nil
end

-- (couch-livefix g) LIVE 2026-10-16: on GRAND PRIX race 2 the setup's MODE strip still read "2 players and 10 AI, all
-- in landspeeders" while the players raced different classes (the "each" rule: every player in his own class). ->
-- {{pnum, cls}, ...} of the humans when the next GP race has per-player classes AND they differ from the page's class
-- (else nil: the page's single class is right)
function M.setupClasses(pageCls)
    local G = M.state()
    if not (G and G.status == "on") then return nil end
    local out, differ = {}, false
    for _, h in ipairs(M.humans()) do
        local c = M.cardClass(h.ctrlId) or pageCls
        out[#out + 1] = { pnum = h.pnum, cls = c }
        if c ~= pageCls then differ = true end
    end
    return differ and out or nil
end

local SINGULAR = { Car = "landspeeder", Bike = "speeder bike", Skimmer = "skim speeder", Plane = "podracer" }
local PLURALS = { Car = "landspeeders", Bike = "speeder bikes", Skimmer = "skim speeders", Plane = "podracers" }
M.SINGULAR, M.PLURALS = SINGULAR, PLURALS
-- pure: the setup strip's sentence for per-player classes.
-- "2 players and 10 AI: P1 in a landspeeder, P2 in a speeder bike; the AI in landspeeders."
function M.setupStripText(classes, nAi, aiCls)
    local n = #classes
    local parts = {}
    for _, e in ipairs(classes) do
        local name = SINGULAR[e.cls] or "speeder"
        local art = name:match("^[aeiou]") and "an" or "a"
        parts[#parts + 1] = string.format("P%d in %s %s", e.pnum, art, name)
    end
    local players = string.format("%d player%s", n, n == 1 and "" or "s")
    if (tonumber(nAi) or 0) > 0 then
        return string.format("%s and %d AI: %s; the AI in %s.", players, nAi, table.concat(parts, ", "),
            PLURALS[aiCls] or "the class")
    end
    return string.format("%s: %s.", players, table.concat(parts, ", "))
end

-- pure (couch-livefix r2, live round 2: the MODE step's line above the per-class strip still read "A single-class
-- race: the whole grid drives the landspeeder" while the strip under it named each player's own class): the RACE
-- mode's description for per-player classes - the same facts as setupStripText, one line.
-- "Each player races in their own class; the AI drive <H1>landspeeders</>."
function M.setupModeText(classes, aiCls)
    local own = {}
    for _, e in ipairs(classes or {}) do own[e.cls] = true end
    local n = 0
    for _ in pairs(own) do n = n + 1 end
    local ai = PLURALS[aiCls] or "the class"
    if n <= 1 then return "A single-class race: everybody drives the <H1>" .. (SINGULAR[next(own) or aiCls] or "speeder") .. "</>." end
    return "Each player races in their own class; the AI drive <H1>" .. ai .. "</>."
end

---------------------------------------------------------------------------------------------------- launch plumbing
local function humanName(pnum)
    local ok, n = pcall(function() return U.mod("nametags").displayName(pnum) end)
    if ok and type(n) == "string" and n ~= "" then return n end
    return "P" .. tostring(pnum)
end
M.humanName = humanName

-- P1 + the joined guests: {pnum, ctrlId, name}
function M.humans()
    local out = { { pnum = 1, ctrlId = 0, name = humanName(1) } }
    pcall(function()
        for _, e in ipairs(U.mod("join").joinedList()) do
            out[#out + 1] = { pnum = e.pnum, ctrlId = e.ctrlId, name = humanName(e.pnum) }
        end
    end)
    return out
end

-- FREE MODE START / the page's NEXT RACE: the racer cards on the next race's track. true when open.
function M.openNext()
    if not M.betweenRaces() then return false end
    local G = F.gp
    local r = G.races[G.race]
    if not r then return false end
    local p1 = G.players[0] or {}
    local cls = (r.group == "pod") and "Plane" or (p1.cls or "Car")
    local setup = U.mod("setup")
    local ok, res = pcall(setup.openRun, { class = cls, planet = r.planet, track = r.key, mode = "race",
                                           cond = r.cond, set = r.set })
    if not ok or res ~= true then
        U.warn(TAG, "race %d (%s) not opened: %s", G.race, tostring(r.key), tostring(res))
        return false
    end
    St.emit("status", string.format("GRAND PRIX RACE %d / %d: %s", G.race, #G.races, tostring(r.name)))
    return true
end

local function tierPath(arch, i)
    if tonumber(arch) == 1 or i <= 1 then return nil end
    local ok, list = pcall(function() return U.mod("vehicles").builds(arch) end)
    if not ok or type(list) ~= "table" or not list[i] then return nil end
    return list[i].path
end

local function presetFor(pilotId, arch, pnum)
    local V, Pm = U.mod("vehicles"), U.mod("pilots")
    local id = nil
    pcall(function() id = Pm.signature(pilotId, arch) end)
    if id and V.presetById(arch, id) then return id end
    local d = nil
    pcall(function() d = V.presets(arch)[V.defaultPresetIndex(arch, pnum)] end)
    return d and d.id or nil
end

-- launch.start (after quick.forcePlan): a GP race gets the GP builds, the per-player classes and the AI tier.
-- c = St.race.choice, plan = launch.plan(c). -> true when this launch is the GP's next race.
function M.prelaunch(c, plan)
    ensure()
    if not M.betweenRaces() or type(plan) ~= "table" or type(plan.players) ~= "table" then return false end
    local G = F.gp
    local r = G.races[G.race]
    local key = nil
    pcall(function() key = U.mod("setup").trackKey(c.track) end)
    if not r or key ~= r.key then
        St.emit("status", "GRAND PRIX: THIS IS NOT THE NEXT RACE (" .. tostring(r and r.name) .. "): NOT SCORED")
        U.warn(TAG, "launch of %s while the Grand Prix waits for %s: not a GP race", tostring(key), tostring(r and r.key))
        return false
    end
    local Pm = U.mod("pilots")
    local mixed = opt("GPPerPlayerClass", true) ~= false
    local humans = 0
    for pnum, pick in pairs(plan.players) do
        if type(pick) == "table" and pick.ctrlId ~= nil then
            humans = humans + 1
            local p = G.players[pick.ctrlId]
            if not p then
                p = { pnum = pnum, ctrlId = pick.ctrlId, name = humanName(pnum), cls = G.players[0] and G.players[0].cls or "Car" }
                G.players[pick.ctrlId] = p
            end
            p.pnum, p.pilotId = pnum, pick.pilotId
            -- his class: the card's (pick.arch, racers.choicePlayers: the card is built in his own class, cardClass),
            -- else the page's; a pick still in another class than his GP one (a card from before cardClass, a
            -- restored choice) moves to it on his pilot's signature model
            local arch = tonumber(pick.arch) or tonumber(plan.arch)
            local want = M.ARCH[p.cls]
            if r.group ~= "pod" and mixed and G.rule == "each" and want and want ~= 1 then
                local okV, known = pcall(function()
                    return U.mod("vehicles").presetById(want, pick.presetId) ~= nil
                end)
                if want ~= arch or (want ~= tonumber(plan.arch) and okV and known == false) then
                    pick.presetId = presetFor(pick.pilotId, want, pnum)
                end
                arch = want
                pick.arch = (want ~= tonumber(plan.arch)) and want or nil
            end
            local style = nil
            pcall(function() style = Pm.styleKey(pick.pilotId, arch) end)
            local lo = type(pick.loadout) == "table" and pick.loadout or {}
            local st = (type(lo.style) == "string") and lo.style or style
            local tune = M.clampTune(lo.tune or G.tune[pick.ctrlId], M.budget(G, pnum))
            local okL, built = pcall(M.loadout, arch, st, tune, G.custom and G.custom.noAbilities)
            if okL and type(built) == "table" then
                pick.loadout, pick.code = built, nil
                G.tune[pick.ctrlId] = tune
            else
                U.warn(TAG, "P%s GP build failed (%s): his card's build races", tostring(pnum), tostring(built))
            end
        end
    end
    plan.aiTierPath = tierPath(plan.arch, G.ai or 3)
    plan.aiLoadout = nil
    if tonumber(plan.arch) == 1 and (G.ai or 3) > 1 then
        pcall(function() plan.aiLoadout = U.mod("perkapply").tierLoadout(G.ai, 1) end)
    end
    local grid = G.custom and G.custom.grid
    if type(grid) == "number" then plan.grid, plan.maxRacers = "max", humans + grid end
    G.flight = { race = G.race, key = r.key, stats = {} }
    save()
    U.log(TAG, "GP race %d / %d launched: %s, %d human(s), AI %s", G.race, #G.races, tostring(r.key), humans,
        M.aiText(G.ai))
    return true
end

-- POSTRACE edge: every racer's place (humans by their racing PlayerState). Same reads as run.lua's snapshot.
local function snapshot()
    local G = F.gp
    if not (G and G.flight) then return end
    local gs = U.gs()
    if not U.ok(gs) then return end
    local keyToCtrl = {}
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
    local all = {}
    pcall(function()
        local list = gs.Racers
        for i = 1, U.arrayCount(list) do
            local ps = list[i]
            if U.ok(ps) then
                local rec = ps.RaceEventComponent
                local pos, ft, wrecked = 99, -1, false
                pcall(function() pos = math.floor(tonumber(rec.EventPosition) or 99) end)
                pcall(function() ft = tonumber(rec.EventFinishTime) or -1 end)
                pcall(function() wrecked = rec.bHasVehicleWrecked == true end)
                local name = "?"
                pcall(function() name = ps:GetPlayerName():ToString() end)
                all[#all + 1] = { name = name, pos = pos, dnf = (ft < 0) or wrecked, ctrlId = keyToCtrl[U.key(ps)] }
            end
        end
    end)
    local human = false
    for _, a in ipairs(all) do if a.ctrlId ~= nil then human = true end end
    if not human then return end
    G.flight.snap = { all = all }
    U.log(TAG, "GP race %d result: %d racer(s)", G.flight.race, #all)
end
M._snapshot = snapshot

-- FRONTEND: score the race (or keep it to race again when it did not end)
function M.settle()
    local G = F.gp
    if not (G and G.flight) then return end
    local fl = G.flight
    G.flight = nil
    if not fl.snap then
        save()
        St.emit("status", "GRAND PRIX: RACE " .. tostring(fl.race) .. " NOT FINISHED, RACE IT AGAIN")
        return
    end
    M.applyResult(G, fl.snap)
    save()
    local top = M.standings(G)[1]
    if G.status == "done" then
        St.emit("status", string.format("GRAND PRIX OVER: %s WINS WITH %d POINTS", tostring(top and top.name),
            top and top.points or 0))
    else
        St.emit("status", string.format("GRAND PRIX: RACE %d / %d NEXT · LEADER %s %d PTS", G.race, #G.races,
            tostring(top and top.name), top and top.points or 0))
    end
    U.log(TAG, "GP race %d settled; next %d / %d (%s)", fl.race, G.race, #G.races, tostring(G.status))
    -- the standings page opens on its own back in the front end
    pcall(function() U.mod("gppage").wantOpen() end)   -- standings, or the podium after the last race
end

function M.init()
    ensure()
    St.on("phase", TAG, function(new)
        local G = F.gp
        if not (G and G.flight) then return end
        if new == "POSTRACE" then U.try(TAG, snapshot)
        elseif new == "PRERACE" or new == "RACING" then G.flight.snap = nil
        elseif new == "FRONTEND" then U.try(TAG, M.settle) end
    end)
    St.on("leaving", TAG, function()
        local G = F.gp
        if G and G.flight and St.phase == "POSTRACE" then U.try(TAG, snapshot) end
    end)
end

-- tests
function M._reset() F.loaded, F.gp, F.drafts = true, nil, {} end
function M._set(g) F.loaded, F.gp = true, g end
function M._setData(d) D = d end
function M._data() return D end

return M
