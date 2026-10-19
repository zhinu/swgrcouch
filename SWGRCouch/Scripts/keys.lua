-- SWGRCouch · keys.lua (G2 Wiring & lifecycle)
-- Debug keybinds (ARCHITECTURE.md §1.8) and the `couch` console command.
--
-- UE4SS facts [API§3, §11, §12]: RegisterKeyBind callbacks run on the UE4SS event-loop thread, see the keyboard only
-- (GetAsyncKeyState), fire only while the game window has focus, and match modifiers exactly (F6 does not fire on
-- Ctrl+F6). 0.10.0: every bind goes through keyq (the event-loop callback only bumps a counter; the FAST loop runs the
-- body on the game thread). No UE4SS call may be made from that thread, not even ExecuteInGameThread: it corrupted the
-- shared hook lua_State (crash_2026_10_08_13_27_33, notes/research/ue4ss-hook-thread-gc.md). F10/Tilde belong to ConsoleEnablerMod, INS,
-- Ctrl+J/H/O/R/Y/U/I, Ctrl+Num5-9 and F3 to other bundled mods: none of them is used here.
-- The console handler runs on the game thread inside ProcessConsoleExec and must return a boolean.

local St = require("state")
local U = require("util")
local cfg = require("config")
local sched = require("sched")
local settings = require("settings")

local M = {}
local TAG = "keys"

local GFX_VALUES = { auto = true, performance = true, quality = true, off = true }

-- Calls <module>.<fn>(...) resolved lazily (U.mod), with a log line when the function is missing.
local function call(modName, fnName, ...)
  local m = U.mod(modName)
  local f = m and m[fnName]
  if type(f) ~= "function" then
    U.warn(TAG, "%s.%s is not available", modName, fnName)
    return nil
  end
  return f(...)
end

-- Keybind body: runs on the game thread (keyq.drain from the FAST loop wraps it in U.try).
local function onGame(label, modName, fnName)
  return function()
    U.log(TAG, "%s -> %s.%s()", label, modName, fnName)
    call(modName, fnName)
  end
end

local function bind(key, mods, label, fn)
  if key == nil then
    U.warn(TAG, "key for %s is missing in this UE4SS build", label)
    return
  end
  require("keyq").bind(key, mods, label, fn)
end

-- ---------------------------------------------------------------------------------------------
-- Console helpers
-- ---------------------------------------------------------------------------------------------

-- "true"/"false" -> boolean, numerals -> number, else the trimmed string; typed after the current value.
local function parseValue(key, raw)
  raw = tostring(raw or ""):match("^%s*(.-)%s*$")
  local cur = settings.get(key)
  local t = type(cur)
  if t == "boolean" then
    local l = raw:lower()
    if l == "true" or l == "1" or l == "on" or l == "yes" then return true end
    if l == "false" or l == "0" or l == "off" or l == "no" then return false end
    return nil, "expected true/false"
  elseif t == "number" then
    local n = tonumber(raw)
    if n == nil then return nil, "expected a number" end
    return n
  end
  return raw
end

-- "10.8.0.1", "10.8.0.1:7777", "host.lan:7778" (IPv4 / host names only).
local function parseAddress(s)
  if not s or s == "" then return nil end
  local host, port = s:match("^([^:]+):(%d+)$")
  if host then return host, tonumber(port) end
  if s:find(":", 1, true) then return nil end
  return s, nil
end

-- Number of joined guests (0 when join.joinedList is unavailable).
local function joinedCount()
  local jl = call("join", "joinedList")
  return type(jl) == "table" and #jl or 0
end

-- Guards the Lobby rows enforce for the same settings (§1.2): returns a refusal line, or nil when allowed.
local function settingGuard(key)
  -- lobby.onKbP1: bOffsetPlayerGamepadIds must not flip under live guests.
  if key == "KeyboardIsP1" then
    -- same order as lobby.onKbP1: a connected/connecting client's set changes only through DISCONNECT (§2.3)
    local frozen = call("join", "isFrozen") == true
    local okM, mode = pcall(U.netMode)
    if frozen or (okM and mode == "client") or St.net.connecting == true then return "DISCONNECT TO CHANGE PLAYERS" end
    if joinedCount() > 0 then return "REMOVE GUESTS FIRST" end
  end
  return nil
end

-- Side effects that the Lobby rows apply for the same settings (§1.2), so `couch set` behaves alike.
local function applySettingSideEffects(key)
  if key == "Layout2P" then
    call("split", "applyLayoutSettings")
  elseif key == "KeyboardIsP1" then
    -- Only reached with no joined guest (settingGuard), as in lobby.onKbP1. join.rebuild() removes nothing (2026-10-07
    -- guest lifecycle: no RemovePlayer) and re-opens the join session, so it runs only while the join screen is open
    -- (it would otherwise start the join poll on whatever game tab is shown). The next join.open picks the new
    -- mapping up.
    call("split", "applyGamepadOffset")
    if St.join.active or St.menu.visible == "lobby" then call("join", "rebuild") end
  end
  St.ui.dirty = true
end

local HELP = {
  "couch diag | recipe | net | input    dumps to UE4SS.log (F9 = diag, includes input)",
  "couch tab | join | leave | layout     lobby / guests / 2P layout",
  "couch launch | takeover               start the chosen race / force takeover (server, race)",
  "couch host | connect [addr[:port]] | disconnect",
  "couch gfx <auto|performance|quality|off>",
  "couch set <Key> <value>                write settings.txt",
  "couch set Name2 Jules                  P2's custom name (Name1..Name4; 'default' clears it)",
  "couch reload                           RestartCurrentMod()",
}

-- Each handler gets the params table (params[1] = subcommand) and returns reply lines (or nil).
local SUB = {}

SUB.help = function() return HELP end
SUB.diag = function() call("diag", "dump"); return { "diag dump written to UE4SS.log" } end
SUB.recipe = function() call("diag", "recipe"); return { "recipe dump written to UE4SS.log" } end
SUB.net = function() call("diag", "net"); return { "network dump written to UE4SS.log" } end
SUB.input = function() call("inputfix", "dump"); return { "input isolation dump written to UE4SS.log" } end
SUB.tab = function() call("menu_tab", "selectOurTab"); return { "FREE MODE tab requested" } end
SUB.join = function() call("join", "keyboardJoin"); return { "join requested" } end
SUB.leave = function() call("join", "keyboardLeave"); return { "leave requested" } end
SUB.layout = function()
  call("split", "toggle2PLayout")
  return { "2P layout: " .. tostring(settings.get("Layout2P")) }
end
SUB.launch = function()
  local ok = call("launch", "start")
  return { ok and "launch accepted" or ("launch refused: " .. tostring(St.ui.statusText)) }
end
SUB.takeover = function() call("takeover", "forceAll"); return { "takeover pass done (server, race only)" } end
SUB.host = function()
  call("net", "toggleHosting")
  return { "hosting: " .. tostring(St.net.hosting) }
end

SUB.connect = function(p)
  if p[2] then
    local host, port = parseAddress(p[2])
    if not host then return { "bad address '" .. tostring(p[2]) .. "' (use a.b.c.d or a.b.c.d:port)" } end
    settings.set("JoinAddress", host)
    if port then settings.set("Port", port) end
  end
  local prevMode = settings.get("NetMode")
  if prevMode ~= "join" then
    if St.net.hosting then return { "stop hosting first (couch host)" } end
    -- net.connect requires NetMode=join; it is put back below if the connect is refused.
    settings.set("NetMode", "join")
  end
  St.ui.dirty = true
  -- A user-requested connect starts with a fresh auto-rejoin budget, like net.toggleConnect (Ctrl+F8).
  St.net.rejoinTries = 0
  local ok = call("net", "connect")
  if not ok then
    if prevMode ~= "join" then settings.set("NetMode", prevMode) end
    return { "connect refused: " .. tostring(St.ui.statusText) }
  end
  return { string.format("connecting to %s:%s", tostring(settings.get("JoinAddress")), tostring(settings.get("Port"))) }
end

SUB.disconnect = function() call("net", "disconnect"); return { "disconnect requested" } end

SUB.gfx = function(p)
  local v = p[2] and p[2]:lower() or nil
  if not v or not GFX_VALUES[v] then return { "usage: couch gfx <auto|performance|quality|off>" } end
  settings.set("SplitGraphics", v)
  St.ui.dirty = true
  local phase = U.mod("phase")
  if phase.isRace() then call("gfx", "applyForViews", St.race.localViews) end
  return { "SplitGraphics = " .. v }
end

SUB.set = function(p)
  local key, raw = p[2], p[3]
  if not key or raw == nil then return { "usage: couch set <Key> <value>" } end
  if #p > 3 then raw = table.concat(p, " ", 3) end
  if settings.get(key) == nil then return { "unknown setting '" .. key .. "'" } end
  local v, why = parseValue(key, raw)
  if v == nil then return { key .. ": " .. tostring(why) } end
  local refusal = settingGuard(key)
  if refusal then
    St.emit("status", refusal)
    return { key .. " unchanged: " .. refusal }
  end
  -- settings.set never throws on a refused value: it returns false, why.
  local okCall, okSet, whySet = pcall(settings.set, key, v)
  if not okCall then return { "set failed: " .. tostring(okSet) } end
  if okSet ~= true then return { key .. " refused: " .. tostring(whySet) } end
  applySettingSideEffects(key)
  return { key .. " = " .. tostring(settings.get(key)) }
end

SUB.reload = function()
  if cfg.AllowHotReload ~= true then return { "hot reload is off (cfg.AllowHotReload = false): restart the game" } end
  RestartCurrentMod()
  return { "restarting SWGRCouch" }
end

local function dispatch(params)
  local sub = params[1] and params[1]:lower() or "help"
  local h = SUB[sub]
  if not h then return { "unknown subcommand '" .. sub .. "'", table.unpack(HELP) } end
  U.log(TAG, "console: couch %s", table.concat(params, " "))
  return h(params)
end

-- `couch <sub> [args]` (needs ConsoleEnablerMod; Tilde/F10 open the console). Always returns true.
local function onConsole(fullCommand, params, ar)
  local ok, err = pcall(function()
    local p = {}
    if type(params) == "table" then
      for i = 1, #params do p[i] = tostring(params[i]) end
    end
    local function reply(lines)
      if type(lines) ~= "table" then return end
      for i = 1, #lines do
        U.log(TAG, "%s", lines[i])
        if ar then pcall(function() ar:Log(lines[i]) end) end
      end
    end
    if IsInGameThread() then
      -- ProcessConsoleExec runs on the game thread: execute inline so the reply reaches the console.
      local good, lines = U.try(TAG, dispatch, p)
      reply(good and lines or { "error, see UE4SS.log" })
    else
      -- VERIFY(V-CORE-01): ProcessConsoleExec should be on the game thread; landing here means UE4SS's
      -- game-thread id is wrong on this build. `ar` is a raw pointer to a by-reference FOutputDevice that
      -- dies when this handler returns, so the deferred closure must never touch it: log only.
      U.logEvery("console!offthread", 60000, TAG, "console handler is not on the game thread (V-CORE-01); deferring")
      sched.run("console", function()
        local lines = dispatch(p)
        if type(lines) ~= "table" then return end
        for i = 1, #lines do U.log(TAG, "%s", lines[i]) end
      end)
      reply({ "queued on the game thread; reply in UE4SS.log" })
    end
  end)
  if not ok then U.err(TAG, "console handler: %s", tostring(err)) end
  return true
end

-- ---------------------------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------------------------

function M.init()
  local CTRL = { ModifierKey.CONTROL }
  bind(Key.F5, nil, "F5", onGame("F5", "menu_tab", "selectOurTab"))
  bind(Key.F6, nil, "F6", onGame("F6", "join", "keyboardJoin"))
  bind(Key.F7, nil, "F7", onGame("F7", "join", "keyboardLeave"))
  bind(Key.F8, nil, "F8", onGame("F8", "split", "toggle2PLayout"))
  bind(Key.F9, nil, "F9", onGame("F9", "diag", "dump"))
  bind(Key.F5, CTRL, "Ctrl+F5", onGame("Ctrl+F5", "launch", "start"))
  bind(Key.F6, CTRL, "Ctrl+F6", onGame("Ctrl+F6", "takeover", "forceAll"))
  bind(Key.F7, CTRL, "Ctrl+F7", onGame("Ctrl+F7", "net", "toggleHosting"))
  bind(Key.F8, CTRL, "Ctrl+F8", onGame("Ctrl+F8", "net", "toggleConnect"))
  bind(Key.F9, CTRL, "Ctrl+F9", onGame("Ctrl+F9", "diag", "net"))
  -- Hot reload only with cfg.AllowHotReload (0.10.0, default off): lua_close of a state other threads still use and
  -- the deletion of the process-wide Lua lock make it a crash risk in this UE4SS (upstream #1445 points 1-2).
  -- keyq runs the body on the game thread, where is_event_loop_thread() is false, so RestartCurrentMod queues the
  -- reinstall (queue_reinstall_mod) instead of lua_close()-ing the state this callback runs in.
  if cfg.AllowHotReload == true then
    bind(Key.F11, CTRL, "Ctrl+F11", function()
      U.log(TAG, "Ctrl+F11 -> RestartCurrentMod()")
      RestartCurrentMod()
    end)
  end

  local ok, err = pcall(RegisterConsoleCommandGlobalHandler, "couch", onConsole)
  if not ok then U.err(TAG, "RegisterConsoleCommandGlobalHandler failed: %s", tostring(err)) end
  U.dbg(TAG, "keybinds F5-F9, Ctrl+F5-F9%s and console 'couch' registered (through keyq)",
    cfg.AllowHotReload == true and ", Ctrl+F11" or "")
end

return M
