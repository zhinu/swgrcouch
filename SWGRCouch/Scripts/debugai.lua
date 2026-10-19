-- debugai.lua (debug, 2026-10-15, Jules): in a race, a local player's L3 (left stick click, Gamepad_LeftThumbstick: in
-- no vehicle IMC and unused by the mod) TOGGLES the game's AI on HIS OWN car (AVehiclePawn:StartInputSourceOverride_
-- OnServer(SpawnAI = 2, the call the live harness verified) / StopInputSourceOverride_OnServer), with a short toast in
-- his half: "P1: AI DRIVING" / "P1: YOU DRIVE". While on, a new pawn (respawn) gets the AI again. Everything is
-- cleared on a world change. cfg.DebugAiKey (true in the test copies for now).
-- Cost: FAST tick, RACING only: one IsInputKeyDown per local player (no object lookups; the key struct is cached).

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "debugai"

local KEY = nil
local S = { world = nil, prev = {}, on = {}, carKey = {}, toasts = {} }

local function key()
    if not KEY then KEY = { KeyName = U.fname("Gamepad_LeftThumbstick") } end
    return KEY
end

local function closeToast(i)
    local h = S.toasts[i]
    S.toasts[i] = nil
    if h then pcall(function() if U.ok(h) then h:RemoveFromParent() end end) end
end

-- a display-only band in player i's half (2 players: top / bottom; more: no split geometry here, top band)
local function toast(i, n, text)
    closeToast(i)
    U.log(TAG, "P%d: %s", i, text)
    pcall(function()
        local CP = U.mod("couchpanel")
        local kit = CP.kit
        local H = CP.newHost()
        pcall(function() H.host:SetVisibility(kit.VIS.HitTestInvisible) end)
        local bandW, bandH = 1100, 130
        local y = 300
        if n == 2 and i == 2 then y = math.floor(kit.VH / 2) + 300 end
        local x = math.floor((kit.VW - bandW) / 2)
        kit.place(H.cv, kit.solid(H.tree, kit.colours.DEEP), x, y, bandW, bandH, 1)
        kit.place(H.cv, kit.solid(H.tree, kit.colours.AMBER), x, y + bandH - 8, bandW, 8, 2)
        local t = kit.text(H.tree, 56, kit.colours.AMBER)
        kit.setText(t, text)
        local s = kit.place(H.cv, t, math.floor(kit.VW / 2), y + 30, nil, nil, 3)
        pcall(function() s:SetAlignment({ X = 0.5, Y = 0 }) end)
        H.host:AddToViewport((tonumber(cfg.CouchPanelZ) or 1000) + 20)
        S.toasts[i] = H.host
        local host = H.host
        U.mod("sched").after("debugai.toast" .. i, 1800, function()
            if S.toasts[i] == host then closeToast(i) end
        end)
    end)
end

local function setAi(car, on)
    return pcall(function()
        if on then car:StartInputSourceOverride_OnServer(C.E.Override.SpawnAI)
        else car:StopInputSourceOverride_OnServer(C.E.Override.SpawnAI) end
    end)
end

function M.fastTick()
    if cfg.DebugAiKey ~= true then return end
    if S.world ~= St.worldGen then
        for i in pairs(S.toasts) do closeToast(i) end
        S.world, S.prev, S.on, S.carKey = St.worldGen, {}, {}, {}
    end
    if St.phase ~= "RACING" then S.prev = {}; return end
    local lps = U.localPlayers()
    local n = #lps
    for i, e in ipairs(lps) do
        if U.ok(e.pc) then
            local okK, k = pcall(key)
            local down = okK and U.keyDown(e.pc, k)               -- couch-racegc: cached UFunction, no closure
            local car = U.carOf(e.pc)                              -- one pc.Pawn read per loop run
            local carOk = car ~= nil
            if down and not S.prev[i] and carOk then
                local want = not S.on[i]
                local ok = setAi(car, want)
                if ok then
                    S.on[i] = want
                    S.carKey[i] = want and U.key(car) or nil
                    toast(i, n, string.format("P%d: %s", i, want and "AI DRIVING" or "YOU DRIVE"))
                else
                    U.warn(TAG, "P%d: AI %s failed", i, want and "on" or "off")
                end
            elseif S.on[i] and carOk and S.carKey[i] ~= U.key(car) then
                -- respawned (new pawn) while on: the AI again
                if setAi(car, true) then S.carKey[i] = U.key(car); U.log(TAG, "P%d: new car, AI again", i) end
            end
            S.prev[i] = down
        end
    end
end

function M.status()
    local t = {}
    for i, v in pairs(S.on) do if v then t[#t + 1] = "P" .. i end end
    return "debugai: " .. (cfg.DebugAiKey == true and "on" or "off") .. ", AI on " .. (#t > 0 and table.concat(t, ",") or "none")
end

function M.init()
    U.log(TAG, "init: L3 toggles the AI on the player's own car in races (cfg.DebugAiKey %s)", tostring(cfg.DebugAiKey))
end

return M
