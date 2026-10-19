-- SWGRCouch / gctune.lua  (couch-racegc, 2026-10-15)
-- The Lua garbage collector of the mod's own Lua state, tuned so a race never stalls on it.
--
-- WHY. Every UE4SS UObject / UFunction / struct wrapper is a full userdata with 5 user values and a __gc finalizer
-- (LuaMadeSimple transfer_stack_object); a property read of an object = ~265 bytes of such garbage. Lua 5.4's
-- INCREMENTAL collector (the default: pause 200, stepmul 100) splits marking and sweeping into small steps, but its
-- ATOMIC step is indivisible and walks EVERY finalizable object (lgc.c atomic: separatetobefnz over the whole 'finobj'
-- list, markbeingfnz resurrecting each dead wrapper): with a ~34 MB live heap a cycle lets ~30 MB of wrappers die
-- before one atomic step. Live 2026-10-15 (racefast profiles, 2P couch races): 10-20 ms spikes in random module ticks,
-- about half of them flagged as a GC step by the profiler. tools/gcbench.lua replays that shape: default settings 14 ms
-- worst tick; GENERATIONAL with a small minor multiplier: every minor collection only walks the young objects (the
-- garbage of the last ~1 MB of allocation), worst tick < 1 ms there.
--
-- WHAT.
--   * cfg.LuaGcMode "generational" (default): collectgarbage("generational", LuaGcMinorMul, LuaGcMajorMul). A major
--     (full, stop-the-world) collection only runs when the OLD generation grew by LuaGcMajorMul % since the last one;
--     in PRERACE / RACING / POSTRACE the major multiplier is LuaGcRaceMajorMul (1000: no major inside a race; Lua reads the
--     parameter at every step, lgc.c genstep);
--     "incremental": collectgarbage("incremental", LuaGcPause, LuaGcStepMul, LuaGcStepSize); "off": Lua's defaults.
--   * a FULL collection at the load screens (phase LOADING, FRONTEND, OTHER = world travel), when the heap grew by
--     LuaGcFullCollectGrowth % since the last full one: the major collections happen there, never in a race. Only Lua
--     work (UE4SS's wrapper finalizers touch no UObject), on the next tick after the phase event.
--   * live check: a sentinel table whose finalizer re-arms itself counts the collector's cycles (a minor or a major
--     in generational mode); per phase and the full collects' durations in M.stats() / M.report().
-- Lua 5.4.7 (UE4SS 3f4037d2 deps/first/LuaRaw): the generational mode has no open bug there (lua.org/bugs.html).

local cfg = require("config")
local St  = require("state")
local U   = require("util")

local M = {}
local TAG = "gctune"

local applied = nil                 -- the mode string actually set
local cycles = { total = 0, byPhase = {} }
local full = { n = 0, lastMs = nil, maxMs = 0, lastBeforeKB = nil, lastAfterKB = nil, baseKB = nil, pending = nil }
local armed = false

---------------------------------------------------------------------------------------------------- cycle counter
-- A table only reachable from its own finalizer's re-arm: collected by every cycle that reaches it (young: every minor
-- collection in generational mode). The finalizer allocates one table; it never errors and touches no UObject.
local function arm()
    setmetatable({}, { __gc = function()
        cycles.total = cycles.total + 1
        local ph = St.phase or "?"
        cycles.byPhase[ph] = (cycles.byPhase[ph] or 0) + 1
        if armed then arm() end
    end })
end

---------------------------------------------------------------------------------------------------- mode
local function num(v, d)
    local n = tonumber(v)
    if n == nil then return d end
    return math.floor(n)
end

local RACE = { PRERACE = true, RACING = true, POSTRACE = true }   -- the race + its results screens
local appliedRace = false           -- the multiplier set is the race one
--- Apply cfg.LuaGcMode (race phases: LuaGcRaceMajorMul). -> the mode text
function M.apply()
    local mode = cfg.LuaGcMode
    if mode == "generational" then
        local minor, major = num(cfg.LuaGcMinorMul, 1), num(cfg.LuaGcMajorMul, 400)
        appliedRace = RACE[St.phase] == true
        if appliedRace then major = num(cfg.LuaGcRaceMajorMul, 1000) end
        collectgarbage("generational", minor, major)
        applied = string.format("generational minor %d%% major %d%%", minor, major)
    elseif mode == "incremental" then
        local pause, mul, size = num(cfg.LuaGcPause, 200), num(cfg.LuaGcStepMul, 100), num(cfg.LuaGcStepSize, 13)
        collectgarbage("incremental", pause, mul, size)
        applied = string.format("incremental pause %d stepmul %d stepsize %d", pause, mul, size)
    else
        applied = "Lua defaults (LuaGcMode " .. tostring(mode) .. ")"
    end
    return applied
end

---------------------------------------------------------------------------------------------------- full collects
local SAFE = { LOADING = true, FRONTEND = true, OTHER = true }

--- Full collection now (load screens only). -> ms, KB before, KB after
function M.fullCollect(why)
    local kb0 = collectgarbage("count")
    local t0 = St.preciseMs and St.preciseMs() or nil
    collectgarbage("collect")
    local t1 = St.preciseMs and St.preciseMs() or nil
    local kb1 = collectgarbage("count")
    local ms = (t0 and t1) and (t1 - t0) or -1
    full.n, full.lastMs, full.lastBeforeKB, full.lastAfterKB, full.baseKB = full.n + 1, ms, kb0, kb1, kb1
    if ms > full.maxMs then full.maxMs = ms end
    U.log(TAG, "full collect (%s, phase %s): %.0f KB -> %.0f KB in %.1f ms (cycles so far %d) (V-GC-02)",
        tostring(why), tostring(St.phase), kb0, kb1, ms, cycles.total)
    return ms, kb0, kb1
end

local function maybeFull(why)
    if not SAFE[St.phase] then return end
    local growth = num(cfg.LuaGcFullCollectGrowth, 25)
    if growth < 0 then return end
    local kb = collectgarbage("count")
    if full.baseKB and kb < full.baseKB * (1 + growth / 100) then return end
    M.fullCollect(why)
end

---------------------------------------------------------------------------------------------------- report
--- Collector cycles so far (the profiler flags a spike during which one ran).
function M.cycleCount() return cycles.total end

function M.stats()
    local by = {}
    for k, v in pairs(cycles.byPhase) do by[k] = v end
    return { mode = applied, heapKB = collectgarbage("count"), cycles = cycles.total, cyclesByPhase = by,
             fullCollects = full.n, fullLastMs = full.lastMs, fullMaxMs = full.maxMs, fullBeforeKB = full.lastBeforeKB,
             fullAfterKB = full.lastAfterKB }
end

--- One line for testcmd / the profiler report (registry size included: the UE4SS out-param leak watch).
function M.report()
    local s = M.stats()
    local reg = 0
    pcall(function() for _ in pairs(debug.getregistry()) do reg = reg + 1 end end)
    local ph = {}
    for k, v in pairs(s.cyclesByPhase) do ph[#ph + 1] = k .. ":" .. v end
    table.sort(ph)
    return string.format("gc %s | heap %.0f KB | registry %d | cycles %d (%s) | full collects %d, last %.1f ms "
        .. "(%s -> %s KB), max %.1f ms", tostring(s.mode), s.heapKB, reg, s.cycles, table.concat(ph, ","),
        s.fullCollects, s.fullLastMs or -1, s.fullBeforeKB and string.format("%.0f", s.fullBeforeKB) or "-",
        s.fullAfterKB and string.format("%.0f", s.fullAfterKB) or "-", s.fullMaxMs)
end

---------------------------------------------------------------------------------------------------- init
function M.init()
    if cfg.LuaGcMode ~= "generational" and cfg.LuaGcMode ~= "incremental" then
        applied = "Lua defaults"
        U.log(TAG, "LuaGcMode %s: the collector keeps Lua's defaults (V-GC-01)", tostring(cfg.LuaGcMode))
        return
    end
    U.log(TAG, "collector: %s; full collects at the load screens when the heap grew %s%% (V-GC-01)", M.apply(),
        tostring(cfg.LuaGcFullCollectGrowth))
    if not armed then armed = true; arm() end
    -- the phase event runs inside a loop tick or a hook: the collect waits for the next tick (sched.after 0)
    St.on("phase", TAG, function(new, old)
        -- the race / non-race major multiplier
        if cfg.LuaGcMode == "generational" and (RACE[new] == true) ~= appliedRace then M.apply() end
        if not SAFE[new] then return end
        local sched = require("sched")
        sched.after("gctune.full", 0, function() maybeFull("phase " .. tostring(new)) end)
    end)
end

return M
