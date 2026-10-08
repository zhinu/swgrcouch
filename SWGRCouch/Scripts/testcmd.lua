-- testcmd.lua: file-driven test commands for unattended live testing (cfg.TestCommands = true; off by default).
-- The mod polls <ModDir>/test.cmd every cfg.TestCommandPollMs. The file starts with "seq=<n>"; when n is larger than
-- the last executed seq, every following line is run once, in order, on the game thread. Results are appended to
-- <ModDir>/test.out ("[seq n] <line> -> <result>") and logged with the [testcmd] tag.
-- Commands (p = local player number 1..4):
--   speedy on|off          Race.SpeedyFlow.Intro/.Movies (+ Race.SpeedyFlow) cvars: skip race intro cinematics
--   cvar <name> <value>    any console variable;   console <command...>   any console command
--   crash <p>              car:DEBUG_RequestCrash(reason, explosion)  (may be compiled out in Shipping)
--   reset <p>              car:DEBUG_RequestResetOnTrack()
--   health <p> <delta>     racer UPlayerRaceEventComponent:Server_ChangeVehicleHealthBy(delta)
--   wreck <p>              health <p> -10
--   critical <p>           UPlayerRaceEventComponent:DEBUG_SetToCriticalHealth()
--   finish <p>             UPlayerRaceEventComponent:Server_Cheat_FinishRace(false)
--   diag                   the F9 dump (diag module)
--   lua <code>             runs <code> with U, St, C, cfg, require and P(p) (-> pc, car, ps, rec) in scope; the
--                          returned value(s) are written to test.out
-- Static facts (scripts/reflect-func-all.py, 2026-10-07):
--   AVehiclePawn:DEBUG_RequestCrash(Struct crashReason, Enum explosionReason)  flags 0x4420401
--   AVehiclePawn:DEBUG_RequestResetOnTrack()                                  flags 0x4020401
--   UPlayerRaceEventComponent:Server_ChangeVehicleHealthBy(Int numHealth)      flags 0x220cc0 (server RPC)
--   UPlayerRaceEventComponent:DEBUG_SetToCriticalHealth()                      flags 0x4020401
--   UPlayerRaceEventComponent:Server_Cheat_FinishRace(Bool abandonedRace)      flags 0x4220cc0

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "testcmd"

local lastSeq = -1
local handle = nil
local outPath, cmdPath

local function paths()
    if cmdPath then return true end
    local ok, d = pcall(function() return require("settings").modDir() end)
    if not ok or type(d) ~= "string" or d == "" then return false end
    d = d:gsub("\\", "/")
    cmdPath, outPath = d .. "/test.cmd", d .. "/test.out"
    return true
end

local function out(seq, line, result)
    local s = string.format("[seq %s] %s -> %s", tostring(seq), tostring(line), tostring(result))
    U.log(TAG, "%s", s)
    local f = io.open(outPath, "a")
    if f then f:write(s, "\n"); f:close() end
end

-- Local player p (1-based, GameInstance.LocalPlayers order): pc, car (vehicle pawn or nil), ps, rec (race comp).
local function P(p)
    local lps = U.localPlayers()
    local e = lps[tonumber(p) or 1]
    if not e or not U.ok(e.pc) then return nil end
    local r = { pc = e.pc }
    pcall(function() local pawn = e.pc.Pawn; if U.ok(pawn) then r.car = pawn end end)
    pcall(function() local ps = e.pc.PlayerState; if U.ok(ps) then r.ps = ps end end)
    if r.ps then pcall(function() local rc = r.ps.RaceEventComponent; if U.ok(rc) then r.rec = rc end end) end
    -- the racer's own PlayerState may differ from the PC's (takeover / adoption): prefer the car's
    if r.car then
        pcall(function()
            local cps = r.car.PlayerState
            if U.ok(cps) then
                local rc = cps.RaceEventComponent
                if U.ok(rc) then r.ps, r.rec = cps, rc end
            end
        end)
    end
    return r
end
M.P = P

local function words(line)
    local t = {}
    for w in line:gmatch("%S+") do t[#t + 1] = w end
    return t
end

local function cvar(name, value)
    return U.console(string.format("%s %s", name, tostring(value))) and "ok" or "failed"
end

local CMD = {}

function CMD.speedy(a)
    local v = (a[2] == "off") and 0 or 1
    local r = {}
    for _, n in ipairs({ "Race.SpeedyFlow.Intro", "Race.SpeedyFlow.Movies" }) do r[#r + 1] = n .. "=" .. cvar(n, v) end
    return table.concat(r, " ")
end

function CMD.cvar(a) return cvar(a[2], a[3] or "") end

function CMD.console(_, line)
    local c = line:match("^%s*console%s+(.+)$")
    if not c then return "usage: console <command>" end
    return U.console(c) and "ok" or "failed"
end

function CMD.crash(a)
    local r = P(a[2]); if not r or not r.car then return "no car" end
    local ok, err = pcall(function() r.car:DEBUG_RequestCrash({}, 0) end)
    return ok and "called" or ("error: " .. tostring(err))
end

function CMD.reset(a)
    local r = P(a[2]); if not r or not r.car then return "no car" end
    local ok, err = pcall(function() r.car:DEBUG_RequestResetOnTrack() end)
    return ok and "called" or ("error: " .. tostring(err))
end

function CMD.health(a)
    local r = P(a[2]); if not r or not r.rec then return "no race component" end
    local d = math.tointeger(tonumber(a[3]) or -1) or -1
    local before; pcall(function() before = r.rec.VehicleHealth end)
    local ok, err = pcall(function() r.rec:Server_ChangeVehicleHealthBy(d) end)
    local after; pcall(function() after = r.rec.VehicleHealth end)
    return ok and string.format("health %s -> %s", tostring(before), tostring(after)) or ("error: " .. tostring(err))
end

function CMD.wreck(a) return CMD.health({ "health", a[2], "-10" }) end

function CMD.critical(a)
    local r = P(a[2]); if not r or not r.rec then return "no race component" end
    local ok, err = pcall(function() r.rec:DEBUG_SetToCriticalHealth() end)
    return ok and "called" or ("error: " .. tostring(err))
end

function CMD.finish(a)
    local r = P(a[2]); if not r or not r.rec then return "no race component" end
    local ok, err = pcall(function() r.rec:Server_Cheat_FinishRace(false) end)
    return ok and "called" or ("error: " .. tostring(err))
end

function CMD.diag()
    local d = U.mod("diag")
    for _, fn in ipairs({ "dumpAll", "dump", "full" }) do
        if type(d[fn]) == "function" then
            local ok, err = pcall(d[fn])
            return ok and ("diag." .. fn .. " done") or ("error: " .. tostring(err))
        end
    end
    return "no dump function in diag"
end

function CMD.lua(_, line)
    local code = line:match("^%s*lua%s+(.+)$")
    if not code then return "usage: lua <code>" end
    local env = setmetatable({ U = U, St = St, C = C, cfg = cfg, P = P, require = require }, { __index = _G })
    local fn, err = load("return " .. code, "testcmd", "t", env)
    if not fn then fn, err = load(code, "testcmd", "t", env) end
    if not fn then return "compile error: " .. tostring(err) end
    local res = table.pack(pcall(fn))
    if not res[1] then return "error: " .. tostring(res[2]) end
    local parts = {}
    for i = 2, res.n do parts[#parts + 1] = tostring(res[i]) end
    return table.concat(parts, ", ")
end

local function runBlock(seq, lines)
    for _, line in ipairs(lines) do
        local a = words(line)
        local f = a[1] and CMD[a[1]]
        if f then
            local ok, r = pcall(f, a, line)
            out(seq, line, ok and r or ("error: " .. tostring(r)))
        elseif a[1] then
            out(seq, line, "unknown command")
        end
    end
end

local speedyDone = false
local function applySpeedy()
    if speedyDone or not cfg.SkipRaceIntro then return end
    if not U.ok(U.world()) then return end
    speedyDone = true
    U.log(TAG, "SkipRaceIntro: %s", CMD.speedy({ "speedy", "on" }))
end

local function tick()
    applySpeedy()
    if not cfg.TestCommands then return end
    if not paths() then return end
    local f = io.open(cmdPath, "r")
    if not f then return end
    local text = f:read("a") or ""
    f:close()
    local seq = tonumber(text:match("^%s*seq=(%d+)"))
    if not seq or seq <= lastSeq then return end
    lastSeq = seq
    local lines = {}
    local first = true
    for line in text:gmatch("[^\r\n]+") do
        if first then first = false else
            if not line:match("^%s*#") and line:match("%S") then lines[#lines + 1] = line end
        end
    end
    runBlock(seq, lines)
end

function M.init()
    if not cfg.TestCommands and not cfg.SkipRaceIntro then return end
    if handle then return end
    -- The first poll only records the current seq, so an old test.cmd is not replayed at boot or after a reload.
    if paths() then
        local f = io.open(cmdPath, "r")
        if f then lastSeq = tonumber((f:read("a") or ""):match("^%s*seq=(%d+)")) or -1; f:close() end
    end
    handle = sched.every(TAG, cfg.TestCommandPollMs or 300, tick)
    if cfg.TestCommands then U.log(TAG, "test commands on: %s (last seq %d)", tostring(cmdPath), lastSeq) end
end

return M
