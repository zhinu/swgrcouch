-- SWGRCouch · quick.lua (0.13.0): QUICK RACE, the friends' play mode. User request 2026-10-12: "the game has too many
-- customizations per kart. when playing with friends it is better to have a pretty easy to use setup with opponents
-- of the same level". Three modes: QUICK RACE (settings PlayMode "quick", the default), CUSTOM (PlayMode "custom": the
-- full FREE MODE with perks) and CAREER (the GALAXY RUN, run.lua, settings RunLength).
-- QUICK RACE: one difficulty for everybody, settings OpponentTier 1..6 (RACE SETUP > MODE "Opponents"). The AI race the
-- speeder tier build of that number (PowerLevel 0 / 6 / .. / 30) and every human races perkdata's matching tier kit
-- (tune levels 0..5, the same abilities and crash) with no traits (the AI have none), pods included. The racer cards
-- skip PERKS (racers.lua) and keep each player's own CUSTOM build untouched: the tier kit only goes into the plan.
-- A GALAXY RUN owns the builds: while one is on (or RunLength starts one at the next launch) quick mode stays out.
-- Pure: no UObject, no game call; settings / perks / pilots / run are read lazily and guarded.
--
-- API (racers.lua, setup.lua, launch.lua):
--   M.isQuick() -> bool          the setting (PlayMode == "quick"), run or not
--   M.quickTier() -> 1..6        OpponentTier clamped
--   M.forRace(arch) -> bool      isQuick() and no GALAXY RUN owns this class's builds (the launch's test)
--   M.name(t) / M.text(t)        "PRO" / "PRO · TIER 3, SAME AS THE AI" (the cards' summary line)
--   M.loadout(arch, style[, t])  the tier kit for (class, pilot style): perks.fromKit("tier"..t), traits all false
--   M.forcePlayers(players, arch[, t]) / M.forcePlan(plan)   every pick with a pilot gets loadout + code of the tier
--     kit and quick = true (racers.persist / restore never save it as the player's build); idempotent

local settings = require("settings")
local U        = require("util")

local M = {}
local TAG = "quick"

M.NAMES = { "ROOKIE", "CADET", "PRO", "ACE", "VETERAN", "LEGEND" }
M.TIERS = 6

function M.isQuick()
    local ok, v = pcall(settings.get, "PlayMode")
    return ok and v == "quick"
end

function M.quickTier()
    local ok, v = pcall(settings.get, "OpponentTier")
    local t = math.floor(tonumber(ok and v or nil) or 1)
    return math.max(1, math.min(M.TIERS, t))
end

-- A GALAXY RUN of this class is on, or RunLength is set (run.prelaunch starts one at the next launch): its builds rule.
function M.runOwns(arch)
    local ok, r = pcall(U.mod, "run")
    if not (ok and type(r) == "table") then return false end
    local okA, owns = pcall(function()
        if r.active() then return arch == nil or tonumber(r.state().arch) == tonumber(arch) end
        return r.lengthSetting() ~= nil
    end)
    return okA and owns == true
end

function M.forRace(arch) return M.isQuick() and not M.runOwns(arch) end

function M.name(t) return M.NAMES[t or M.quickTier()] or M.NAMES[1] end

-- "PRO · TIER 3, SAME AS THE AI"
function M.text(t)
    t = t or M.quickTier()
    return string.format("%s · TIER %d, SAME AS THE AI", M.name(t), t)
end

function M.loadout(arch, style, t)
    t = t or M.quickTier()
    local Km = U.mod("perks")
    local lo = Km.fromKit("tier" .. t, arch, style)
    for i = 1, #lo.traits do lo.traits[i] = false end
    lo.kit, lo.from = "tier" .. t, nil
    return lo
end

function M.forcePlayers(players, arch, t)
    if type(players) ~= "table" or arch == nil then return 0 end
    t = t or M.quickTier()
    local Km, Pm = U.mod("perks"), U.mod("pilots")
    local n = 0
    for _, p in pairs(players) do
        if type(p) == "table" and type(p.pilotId) == "string" then
            local style = nil
            pcall(function() style = Pm.styleKey(p.pilotId, arch) end)
            local lo = M.loadout(arch, style, t)
            p.loadout, p.code, p.quick = lo, Km.encode(lo), true
            n = n + 1
        end
    end
    return n
end

-- launch.start (after launch.plan): QUICK RACE forces every human's tier kit; no-op in CUSTOM or a GALAXY RUN race.
function M.forcePlan(plan)
    if type(plan) ~= "table" or not M.forRace(plan.arch) then return 0 end
    local t = M.quickTier()
    -- copies: plan.players is the stored choice's own table (launch.plan); forcing it in place made a later CUSTOM
    -- "race again" race the tier kit (review 2026-10-12)
    local copy = {}
    for k, p in pairs(type(plan.players) == "table" and plan.players or {}) do
        if type(p) == "table" then
            local c = {}
            for kk, vv in pairs(p) do c[kk] = vv end
            copy[k] = c
        else
            copy[k] = p
        end
    end
    plan.players = copy
    local n = M.forcePlayers(plan.players, plan.arch, t)
    U.log(TAG, "QUICK RACE %s: %d player(s) on the tier %d kit, no traits", M.name(t), n, t)
    return n
end

return M
