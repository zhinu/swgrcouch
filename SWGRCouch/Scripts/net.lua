-- net.lua (G7 Network): self-hosted network races over a plain IpNetDriver (ARCHITECTURE.md §2, §4.2 net).
--
-- Host: reloads the front end as a listen server (`open L_FrontEnd?listen`), clients connect into that front end,
-- the host launches the race with LaunchCustomRace (every PC, local and remote, gets a recipe entry) and the
-- game travels natively. Whether that native travel carries the clients is the "travel question" (V-NET-13):
-- checkTravel() detects the answer and applies cfg.HostTravelFallback (relisten + servertravel, or relisten +
-- takeover). Clients join with GameplayStatics:OpenLevel("<addr>:<port>", GetClientTravelOptions()) like the
-- game's own dev server browser, and rejoin automatically after a network failure.
--
-- Requires the user Engine.ini override from mod/config/Engine.ini (GameNetDriver = IpNetDriver) on every machine.
-- Every function here runs on the game thread (MAIN/SLOW loops, hooks, sched callbacks, keys via sched.run).

local C = require("consts")
local cfg = require("config")
local settings = require("settings")
local St = require("state")
local U = require("util")
local sched = require("sched")
local UEHelpers = require("UEHelpers")

local M = {}
local TAG = "net"

-- Fallback "attempt over" detector for a pending connection that neither connects nor reports a failure:
-- a little above InitialConnectTimeout=120 s from mod/config/Engine.ini (the engine fails the pending
-- connection itself at that point, which normally reaches the HandleNetworkFailure hook first).
local CONNECT_GIVEUP_MS = 130000
-- A failure line stays in statusText() for this long (ARCHITECTURE §4.2 net: "newer than 30 s").
local FAILURE_SHOW_MS = 30000
local IPNETDRIVER = "OnlineSubsystemUtils.IpNetDriver"

-- Module-private additions to St.net (the module's own state table; created here so diag dumps them):
--   connectSinceMs  start of the current connect attempt (0 = none)
--   feWorldGen      St.worldGen for which onFrontEnd() already ran (per-world idempotence; a generation, not the
--                   UWorld address: consecutive worlds often share an address)
--   fePhaseGen      St.worldGen in which a "phase" -> FRONTEND event was seen (join.resync ran from join's own
--                   listener); a front-end world without one (FRONTEND -> FRONTEND reload) gets resync from net
--   raceWorldGen    St.worldGen for which onRaceMap() already ran
--   remoteAtCheck   remote count when a relisten wait was armed (the wait ends in servertravel only if it grew)
--   travelWatchGen  St.worldGen in which serverTravelNow marked LEAVING (watchdog)
--   clientWorldGen  St.worldGen in which this machine was last seen as a connected client (tick). The same world
--                   reading standalone later is a hard ClientTravel in flight, not a drop (see slowTick)
--   travelStandaloneSinceMs  when that same-world standalone state was first seen (0 = not seen)
--   driverOk        nil = not checked, true/false = result of checkDriverConfig()
--   driverClassLogged  the live NetDriver class was logged once while listening
--   serverTravelRetries  refused servertravels retried in this race world (watchdog, at most 1)
--   waitFromStage2  the relisten wait was armed by checkTravel(2) (listening native travel, clients late), not by
--                   hostTravelFallback: it ends in a servertravel only if a human still has no car
--   waitRemoteSeen / waitArriveMs  remote count last seen during that wait and when it last changed
--   clientMenuGen   St.worldGen whose client front end was checked for a main menu (V-NET-17)
--   stopCheckGen    St.worldGen in which STOP HOSTING reloaded the front end; the next front end is checked for a
--                   listen state left over (V-NET-18)
local function initState()
  local n = St.net
  if n.connectSinceMs == nil then n.connectSinceMs = 0 end
  if n.feWorldGen == nil then n.feWorldGen = -1 end
  if n.fePhaseGen == nil then n.fePhaseGen = -1 end
  if n.raceWorldGen == nil then n.raceWorldGen = -1 end
  if n.remoteAtCheck == nil then n.remoteAtCheck = 0 end
  if n.driverClassLogged == nil then n.driverClassLogged = false end
  if n.serverTravelRetries == nil then n.serverTravelRetries = 0 end
  if n.waitFromStage2 == nil then n.waitFromStage2 = false end
end

-- ---------------------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------------------

local function phaseName()
  local ok, p = pcall(function() return U.mod("phase").get() end)
  if ok and type(p) == "string" then return p end
  return St.phase
end

local function inFrontEnd() return phaseName() == "FRONTEND" end

local function isRacePhase()
  local p = phaseName()
  return p == "LOADING" or p == "PRERACE" or p == "RACING" or p == "POSTRACE"
end

-- User-visible message: Lobby status row ("status" event) and the log.
local function status(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  U.log(TAG, "status: %s", text)
  St.emit("status", text)
end

local function emitNet() St.emit("net") end

local function port()
  local p = tonumber(settings.get("Port")) or 7777
  return math.floor(p)
end

-- "<host>:<port>" to connect to. A JoinAddress that already carries a port (hand edit of settings.txt:
-- "10.8.0.1:7777") uses that port instead of the Port setting (never "host:7777:7777").
local function joinAddr()
  local a = tostring(settings.get("JoinAddress") or "")
  a = a:gsub("^%s+", ""):gsub("%s+$", "")
  local host, p = a:match("^([^:]+):(%d+)$")
  if host then
    U.logOnce("net.addrport." .. a, TAG, "JoinAddress %q carries a port: using port %s (Port setting %d ignored)", a,
      p, port())
    return host .. ":" .. p
  end
  return a .. ":" .. tostring(port())
end

local function netModeSetting() return settings.get("NetMode") end

local function remoteCount()
  local ok, list = pcall(function() return U.mod("roster").remoteHumans() end)
  if ok and type(list) == "table" then return #list end
  return 0
end

-- Package path of the current map ("/Game/.../L_X"), "" when unknown.
local function mapPath()
  local ok, p = pcall(U.currentMapPath)
  if ok and type(p) == "string" then return p end
  return ""
end

-- Runs fn only if the world is still the one that was current when the timer was armed (world generation: a new
-- UWorld at the freed address of the old one is still another world).
local function afterSameWorld(tag, ms, fn)
  local gen = St.worldGen
  return sched.after(tag, ms, function()
    if St.worldGen ~= gen then
      U.dbg(TAG, "%s: world changed since scheduling, skipped", tag)
      return
    end
    fn()
  end)
end

-- ---------------------------------------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------------------------------------

-- KSL:IsServer(Object WorldContextObject) -> Bool, KSL:IsStandalone(Object) -> Bool [reflect-func-all, KSL owner]
-- VERIFY(V-NET-15): a listen host reports IsServer=true, IsStandalone=false and a valid UWorld.NetDriver.
-- Fallback if the NetDriver term misbehaves: the log line below shows the disagreement; drop the term then.
function M.isListening()
  local ok, res = pcall(function()
    if not U.isServer() or U.isStandalone() then return false end
    local w = U.world()
    if not U.ok(w) then return false end
    local drv = w.NetDriver
    if not U.ok(drv) then
      U.logOnce("net.listen.nodriver", TAG, "netmode listen but UWorld.NetDriver invalid (V-NET-15)")
      return false
    end
    return true
  end)
  return ok and res == true
end

function M.isConnectedClient()
  local ok, m = pcall(U.netMode)
  return ok and m == "client"
end

local function isStandalone()
  local ok, m = pcall(U.netMode)
  return ok and m == "standalone"
end

-- Host = this machine chose NETWORK: HOST and started hosting.
local function isHost()
  return netModeSetting() == "host" and St.net.hosting == true
end

local function failureLine()
  local f = St.net.lastFailure
  if type(f) ~= "table" or not f.atMs then return nil end
  if St.nowMs() - f.atMs > FAILURE_SHOW_MS then return nil end
  local msg = f.msg or ""
  if #msg > 60 then msg = msg:sub(1, 57) .. "..." end
  return ("NETWORK ERROR: %s %s"):format(tostring(f.name), msg)
end

-- Text of the Lobby `remote` row (empty when offline; lobby collapses the row then).
function M.statusText()
  local mode = netModeSetting()
  local text = ""
  if mode == "host" then
    if M.isListening() and not St.net.hosting then
      text = ("STILL LISTENING ON PORT %d: %d REMOTE PLAYERS (STOP HOSTING AGAIN)"):format(port(), remoteCount())
    elseif M.isListening() then
      text = ("HOSTING ON PORT %d: %d REMOTE PLAYERS"):format(port(), remoteCount())
    elseif St.net.hosting and (St.net.listenSinceMs or 0) > 0 then
      text = ("STARTING HOST ON PORT %d..."):format(port())
    else
      text = "NOT HOSTING"
    end
  elseif mode == "join" then
    if M.isConnectedClient() then
      text = "CONNECTED TO " .. joinAddr()
    elseif St.net.connecting then
      text = "CONNECTING TO " .. joinAddr() .. "..."
    elseif St.net.wantConnected and (St.net.nextRejoinMs or 0) > 0 then
      text = ("RECONNECTING TO %s (TRY %d/%d)"):format(joinAddr(), (St.net.rejoinTries or 0) + 1, cfg.RejoinMaxTries)
    else
      text = "NOT CONNECTED"
    end
  else
    return ""
  end
  if St.net.driverOk == false then text = text .. "  |  ENGINE.INI NET OVERRIDE NOT ACTIVE" end
  local fl = failureLine()
  if fl then text = text .. "  |  " .. fl end
  return text
end

-- Label of the Lobby `netact` button.
function M.netactLabel()
  local mode = netModeSetting()
  if mode == "host" then
    if St.net.hosting or M.isListening() then return "STOP HOSTING" end
    return ("START HOSTING (PORT %d)"):format(port())
  elseif mode == "join" then
    if St.net.wantConnected or St.net.connecting or M.isConnectedClient() then return "DISCONNECT" end
    return "CONNECT TO " .. joinAddr()
  end
  return ""
end

-- ---------------------------------------------------------------------------------------------------------
-- Host
-- ---------------------------------------------------------------------------------------------------------

-- Reloads the front end as a listen server. LocalPlayers (joined guests) survive the reload; their PCs are
-- re-created and picked up by join.resync() (FRONTEND -> FRONTEND emits no "phase" event: net.onFrontEnd calls
-- resync itself for such a world); St.ui.returnToTab reopens the SPLIT SCREEN tab.
local function openFrontEndListen(reason)
  St.net.listenSinceMs = St.nowMs()
  St.ui.returnToTab = true
  U.log(TAG, "%s: open %s?listen (port %d from [URL] Port / -port=)", reason, C.MAP.FrontEnd, port())
  -- KSL:ExecuteConsoleCommand(Object WorldContextObject, Str Command, Object SpecificPlayer) via U.console.
  -- The mod never appends ?port= (FURL ignores it for listening [NET§9]).
  -- VERIFY(V-NET-04): the front end reloads listening, boot flow skipped, menu + our tab come back, guests kept.
  U.console("open " .. C.MAP.FrontEnd .. "?listen")
end

function M.startHosting()
  if netModeSetting() ~= "host" then
    status("SET NETWORK TO HOST FIRST")
    return false
  end
  if not inFrontEnd() then
    status("HOSTING CAN ONLY START IN THE MENU")
    return false
  end
  if M.isListening() then
    St.net.hosting = true
    St.net.listenSinceMs = 0
    U.log(TAG, "startHosting: already listening")
    emitNet()
    return true
  end
  St.net.hosting = true
  St.net.lastFailure = nil
  U.mod("netfix").applySafetyCvars()
  if port() ~= 7777 then
    -- The listen port is the engine's [URL] Port (7777) unless the host exe was started with -port=N.
    status("HOST MUST BE STARTED WITH -port=%d", port())
  end
  openFrontEndListen("startHosting")
  emitNet()
  return true
end

-- Reloads the front end WITHOUT the carried URL options. The console `open X` is a TRAVEL_Partial travel, and
-- FURL(&LastURL, X, TRAVEL_Partial) copies every option of WorldContext.LastURL - after `open L_FrontEnd?listen`
-- that includes `listen`, so a plain `open L_FrontEnd` would listen again [E: UEngine::HandleOpenCommand, FURL ctor].
--   cfg.StopHostingMethod = "openlevel_abs" (default): GameplayStatics:OpenLevel(world, FName map, bAbsolute=true, "")
--                             -> TRAVEL_Absolute, LastURL options dropped.
--                           "disconnect": console `disconnect` (UEngine::HandleDisconnect removes Listen/LAN from
--                             LastURL, then ?closed loads GameDefaultMap = L_FrontEnd [NET: DefaultEngine.ini]).
-- VERIFY(V-NET-18): after STOP HOSTING the new front end is standalone (isListening() false); tick() reports
-- "STILL LISTENING" otherwise, and the lobby button stays STOP HOSTING so it can be retried with the other method.
local function reloadFrontEndNoListen()
  local mode = cfg.StopHostingMethod
  if mode == "disconnect" then
    U.log(TAG, "stopHosting: console disconnect (strips Listen from LastURL, loads GameDefaultMap)")
    return U.console("disconnect")
  end
  U.log(TAG, "stopHosting: OpenLevel(%s, bAbsolute=true, no options); clients get a network failure", C.MAP.FrontEnd)
  -- GameplayStatics:OpenLevel(Object WorldContextObject, Name LevelName, Bool bAbsolute, Str Options) [4 params]
  local ok = U.try(TAG, function() U.GS():OpenLevel(U.world(), U.fname(C.MAP.FrontEnd), true, "") end)
  if not ok then
    U.warn(TAG, "stopHosting: OpenLevel failed; falling back to console disconnect")
    return U.console("disconnect")
  end
  return true
end

function M.stopHosting()
  local wasListening = M.isListening()
  St.net.hosting = false
  St.net.listenSinceMs = 0
  St.net.relistenPending = false
  if wasListening then
    St.ui.returnToTab = true
    St.net.stopCheckGen = St.worldGen  -- tick() checks the NEXT front-end world is not listening (V-NET-18)
    reloadFrontEndNoListen()
  else
    U.log(TAG, "stopHosting: was not listening, nothing to reload")
  end
  status("HOSTING STOPPED")
  emitNet()
  return true
end

function M.toggleHosting()
  -- also stops a listen state left over without hosting (V-NET-18 failure), so the user can always leave it
  if St.net.hosting or M.isListening() then return M.stopHosting() end
  return M.startHosting()
end

-- Re-establishes the listen server after the host fell back to a standalone front end (e.g. the race
-- returned to the menu with a local OpenLevel). Called 1 s after such a front end appears.
function M.ensureListening()
  if not (cfg.AutoRelistenInFrontEnd and isHost()) then return end
  if not inFrontEnd() or M.isListening() then return end
  if (St.net.listenSinceMs or 0) > 0 and St.nowMs() - St.net.listenSinceMs < cfg.ListenCheckMs then
    U.dbg(TAG, "ensureListening: a listen attempt is still in flight")
    return
  end
  openFrontEndListen("ensureListening")
  emitNet()
end

-- Called by launch.start() right before LaunchCustomRace on a listen host.
function M.beforeLaunch()
  St.net.expectedRemote = remoteCount()
  St.net.relistenDone = false
  St.net.relistenPending = false
  St.net.serverTravelDone = false
  St.net.lateJoinAllowed = false
  St.net.waitUntilMs = 0
  St.net.waitFromStage2 = false
  St.net.serverTravelRetries = 0
  U.log(TAG, "beforeLaunch: listening=%s expectedRemote=%d", tostring(M.isListening()), St.net.expectedRemote)
end

-- ---------------------------------------------------------------------------------------------------------
-- Client
-- ---------------------------------------------------------------------------------------------------------

-- PlayfabOnlineMatchmaking:GetClientTravelOptions() -> Str (0 params) [reflect-func-all, flags 0x54020401].
-- The game's own dev join passes it to OpenLevel [NET§5.4]. Returns "" when unavailable.
local function clientTravelOptions()
  local opts = ""
  local ok = U.try(TAG, function()
    local mm = U.giSubsystem("PlayfabOnlineMatchmaking")
    if not U.ok(mm) then
      U.warn(TAG, "PlayfabOnlineMatchmaking subsystem not found: joining without travel options")
      return
    end
    opts = U.str(mm:GetClientTravelOptions()) or ""
  end)
  if not ok then
    U.warn(TAG, "GetClientTravelOptions failed: joining without travel options")
    opts = ""
  end
  -- GameplayStatics::OpenLevel inserts the '?' itself ("<LevelName>?<Options>").
  opts = opts:gsub("^%?+", "")
  -- Content may hold tokens: log the length only.
  U.log(TAG, "client travel options: %d chars", #opts)
  return opts
end

-- A connect that could not even start (call error, no KSL CDO): undo everything connect() armed, so the
-- slow loop does not take it for a dropped connection and auto-rejoin (wantConnected + standalone + front end).
-- Also undoes what connect() did to the guest set and the tab return (join.commit, St.join.keep, St.ui.returnToTab),
-- like launch's undoPrelaunch does for a refused launch: the lobby gets its dormant guests and join poll back.
local function connectRefused(msg)
  St.net.connecting = false
  St.net.connectSinceMs = 0
  St.net.wantConnected = false
  St.net.nextRejoinMs = 0
  St.join.frozen = false
  St.join.keep = false
  St.ui.returnToTab = false
  if St.menu.visible == "lobby" or St.menu.visible == "builder" then
    U.try(TAG, function() U.mod("join").open() end)
  end
  St.emit("players")
  status(msg)
  emitNet()
  return false
end

function M.connect()
  if netModeSetting() ~= "join" then
    status("SET NETWORK TO JOIN FIRST")
    return false
  end
  if not inFrontEnd() then
    status("CONNECT ONLY FROM THE MENU")
    return false
  end
  if not isStandalone() then
    status("ALREADY ONLINE: DISCONNECT FIRST")
    return false
  end
  local addrOnly = tostring(settings.get("JoinAddress") or "")
  if addrOnly:match("^%s*$") then
    status("NO JoinAddress IN settings.txt")
    return false
  end
  -- Every local guest split-joins the host once connected, joined or not, and an un-joined one cannot be removed
  -- (RemovePlayer crash, join.lua GUEST LIFECYCLE): it would be a ghost racer on the host (no slot, its car standing
  -- still). So CONNECT is refused while one exists [§2.3].
  local dormant = U.mod("join").dormantText()
  if dormant then
    status("%s: PRESS A ON IT BEFORE CONNECTING", dormant)
    return false
  end
  U.mod("join").commit()
  St.join.frozen = true
  St.net.wantConnected = true
  St.net.connecting = true
  St.net.connectSinceMs = St.nowMs()
  St.net.nextRejoinMs = 0
  St.ui.returnToTab = true
  local addr = joinAddr()
  local method = cfg.JoinMethod
  U.log(TAG, "connect: %s method=%s try=%d", addr, tostring(method), St.net.rejoinTries or 0)
  if method == "console" then
    -- VERIFY(V-NET-06): console `open <addr>:<port>` joins (drops the game's travel options).
    if not U.console("open " .. addr) then
      return connectRefused("CONNECT FAILED (console open error, see log)")
    end
  else
    local opts = ""
    if method == "openlevel_opts" then
      -- VERIFY(V-NET-05): options are accepted by the host's login; fallback cfg.JoinMethod = "openlevel".
      opts = clientTravelOptions()
    end
    -- GameplayStatics:OpenLevel(Object WorldContextObject, Name LevelName, Bool bAbsolute, Str Options)
    -- [reflect-func-all, flags 0x4022403]; 4 params, LevelName = FName("<addr>:<port>") like the dev browser.
    local ok = U.try(TAG, function()
      U.GS():OpenLevel(U.world(), U.fname(addr), true, opts)
    end)
    if not ok then
      return connectRefused("CONNECT FAILED (OpenLevel error, see log)")
    end
  end
  status("CONNECTING TO %s...", addr)
  emitNet()
  return true
end

function M.disconnect()
  local online = M.isConnectedClient() or St.net.connecting
  -- the guests stay joined in the standalone front end we fall back to (read by join.resync)
  if online then St.join.keep = true end
  St.net.wantConnected = false
  St.net.connecting = false
  St.net.connectSinceMs = 0
  St.net.nextRejoinMs = 0
  if online then
    -- `disconnect` cancels a pending connection or leaves the host; the engine returns to L_FrontEnd.
    -- Not sent while standalone: on a standalone world it would reload the default map for nothing.
    St.ui.returnToTab = true
    U.console("disconnect")
  end
  status("DISCONNECTED")
  emitNet()
  return true
end

-- Pre-hook of /Script/Griffin.UIBlueprintFunctionLibrary:ReturnToMainMenu(Object WorldContextObject): the game's own
-- pause-menu Quit / Abandon race on a client. That is a local travel/disconnect with no HandleNetworkFailure, so
-- wantConnected would stay true and onFrontEnd/slowTick would pull the client back into the host's race (as a
-- spectating mid-game joiner, possibly triggering the host's stage-2 restart). The user chose to leave: do
-- disconnect()'s bookkeeping without the console command (the game travels by itself).
-- VERIFY(V-NET-19): the pause menu's Quit reaches this hook on a client (log "left the host through the game's menu");
-- fallback cfg.RejoinAfterQuitToMenu = true restores the old behaviour (auto-rejoin after any return to the menu).
function M.onUserLeaves()
  if cfg.RejoinAfterQuitToMenu == true then return end
  if not St.net.wantConnected then return end
  if not (M.isConnectedClient() or St.net.connecting) then return end
  U.log(TAG, "left the host through the game's menu (ReturnToMainMenu): no auto-rejoin")
  St.net.wantConnected = false
  St.net.connecting = false
  St.net.connectSinceMs = 0
  St.net.nextRejoinMs = 0
  St.join.keep = true      -- the joined guests stay joined in the standalone front end (join.resync)
  St.ui.returnToTab = true
  status("LEFT THE HOST")
  emitNet()
end

function M.toggleConnect()
  if St.net.wantConnected or St.net.connecting or M.isConnectedClient() then return M.disconnect() end
  St.net.rejoinTries = 0
  return M.connect()
end

-- Arms the automatic rejoin (client) after a failure or a silent drop.
local armRejoin

-- Backup drop paths (no HandleNetworkFailure, V-NET-14): same bookkeeping as onNetworkFailure, so join.resync keeps
-- the guests for the auto-rejoin and the lobby reopens. The front-end menu of this world may already be installed
-- (its RegisterTabs runs before phase.tick sees the world) and found no return flag: then our tab is selected here.
-- DEVIATION (ARCHITECTURE §4.2 net "May call"): adds `menu_tab.selectOurTab` (menu_tab.menu was already used).
local function armDropped(reason)
  if St.net.wantConnected then
    St.join.keep = true
    St.ui.returnToTab = true
    if inFrontEnd() and cfg.ReturnToSplitTab and St.menu.key ~= 0 and (St.menu.worldKey or 0) ~= 0
        and St.menu.worldKey == St.worldKey and St.menu.visible ~= "lobby" and St.menu.visible ~= "builder" then
      St.ui.returnToTab = false          -- consumed here: no later unrelated menu install may jump to our tab
      local gen = St.worldGen
      sched.after(TAG, 200, function()
        if St.worldGen ~= gen or not inFrontEnd() or St.launch.pending then return end
        U.log(TAG, "%s: reopening the FREE MODE tab on the installed menu", reason)
        U.try(TAG, function() U.mod("menu_tab").selectOurTab() end)
      end)
    end
  end
  armRejoin(reason)
end

armRejoin = function(reason)
  if not St.net.wantConnected then return end
  if not cfg.AutoRejoin then
    St.net.wantConnected = false
    St.join.frozen = false
    U.log(TAG, "%s: AutoRejoin off, giving up the connection", reason)
    return
  end
  St.net.nextRejoinMs = St.nowMs() + cfg.RejoinDelayMs
  U.log(TAG, "%s: rejoin in %d ms (try %d/%d)", reason, cfg.RejoinDelayMs, (St.net.rejoinTries or 0) + 1,
    cfg.RejoinMaxTries)
end

-- ---------------------------------------------------------------------------------------------------------
-- Network failures
-- ---------------------------------------------------------------------------------------------------------

-- Post-hook of /Script/Griffin.GfnGameInstance:HandleNetworkFailure(Object World, Object NetDriver,
-- Byte FailureType, Str ErrorString) [reflect-func-all, flags 0x40401 Final|Native|Private].
-- VERIFY(V-NET-14): the handler is dispatched through ProcessEvent (bound as a UFunction), so the hook fires.
-- Backup when it does not: slowTick() notices a client that fell back to standalone while wantConnected.
function M.onNetworkFailure(ctx, World, NetDriver, FailureType, ErrorString)
  local ft, msg = nil, ""
  pcall(function() ft = FailureType:get() end)
  pcall(function() msg = U.str(ErrorString:get()) or "" end)
  local name = (ft ~= nil and C.E.NetworkFailure[ft]) or tostring(ft)
  St.net.lastFailure = { name = name, msg = msg, atMs = St.nowMs() }
  U.warn(TAG, "HandleNetworkFailure: type=%s (%s) error=%q netmode=%s hosting=%s wantConnected=%s",
    tostring(ft), tostring(name), msg, tostring(select(2, pcall(U.netMode))), tostring(St.net.hosting),
    tostring(St.net.wantConnected))
  status("NETWORK ERROR: %s %s", tostring(name), msg)
  if St.net.wantConnected then
    -- the joined guests must survive the fall-back to a standalone front end (join.resync), so that the auto-rejoin
    -- reconnects with them; returnToTab reopens the lobby there
    St.join.keep = true
    St.ui.returnToTab = true
    St.net.connecting = false
    St.net.connectSinceMs = 0
    armRejoin("network failure")
  end
  emitNet()
end

-- ---------------------------------------------------------------------------------------------------------
-- World transitions (each runs once per world; called from the phase listener and from tick())
-- ---------------------------------------------------------------------------------------------------------

-- fromPhase = called by the "phase" -> FRONTEND listener (join's own listener, registered earlier, already ran
-- join.resync). From tick(): a new front-end world whose phase stayed FRONTEND across the world change (the
-- listen reload `open L_FrontEnd?listen`, the stop-hosting reload, `disconnect` or a network failure from the
-- host's front end): phase.setPhase emits nothing, so net runs join.resync here, before its own front-end logic
-- (same order as on the phase event: join.init precedes net.init).
-- DEVIATION (ARCHITECTURE §4.2 net "May call"): adds `join.resync`.
function M.onFrontEnd(fromPhase)
  if St.net.feWorldGen == St.worldGen then return end
  St.net.feWorldGen = St.worldGen
  if not fromPhase and St.net.fePhaseGen ~= St.worldGen then
    U.log(TAG, "front-end world %s without a phase event (FRONTEND -> FRONTEND): join.resync", tostring(St.worldGen))
    U.try(TAG, function() U.mod("join").resync() end)
  end
  if not St.net.driverChecked then M.checkDriverConfig() end
  St.net.relistenDone = false
  St.net.relistenPending = false
  St.net.serverTravelDone = false
  St.net.lateJoinAllowed = false
  St.net.waitUntilMs = 0
  St.net.waitFromStage2 = false
  local mode = select(2, pcall(U.netMode))
  U.log(TAG, "front end: netmode=%s hosting=%s wantConnected=%s connecting=%s", tostring(mode),
    tostring(St.net.hosting), tostring(St.net.wantConnected), tostring(St.net.connecting))
  -- (a pending listen attempt is confirmed or timed out by tick())
  if St.net.hosting and not M.isListening() and cfg.AutoRelistenInFrontEnd and netModeSetting() == "host" then
    -- Back in a standalone front end while hosting: listen again (clients auto-rejoin).
    sched.after(TAG, 1000, M.ensureListening)
  end
  if mode == "client" then
    -- tick() emits "CONNECTED TO" only while connecting is set: report it here before clearing it
    if St.net.connecting then status("CONNECTED TO %s", joinAddr()) end
    St.net.connecting = false
    St.net.connectSinceMs = 0
    St.net.rejoinTries = 0
    St.net.nextRejoinMs = 0
    St.join.frozen = true
    -- VERIFY(V-NET-17): the client's cosmetic front end shows WBP_FE_MainMenu (the host's AFrontEndGameMode drives the
    -- front-end flow, and it does not exist on a client [RB, NET§5.3]). Checked 5 s in; fallback cfg.ClientMenuFallback.
    afterSameWorld("net.clientmenu", 5000, function() M.checkClientMenu(1) end)
  elseif mode == "standalone" then
    if St.net.wantConnected and St.net.connecting then
      -- A connection attempt ended in our own front end without a failure callback.
      St.net.connecting = false
      St.net.connectSinceMs = 0
      if (St.net.nextRejoinMs or 0) == 0 then armDropped("connect attempt ended") end
    elseif St.net.wantConnected and (St.net.nextRejoinMs or 0) == 0 then
      armDropped("back in a standalone front end")
    elseif not St.net.wantConnected and St.join.frozen then
      St.join.frozen = false
      St.emit("players")
    end
  end
  emitNet()
end

function M.onRaceMap()
  if St.net.raceWorldGen == St.worldGen then return end
  St.net.raceWorldGen = St.worldGen
  St.net.serverTravelRetries = 0
  if M.isConnectedClient() then
    -- launch.start (the per-race setter) runs on the host only: after every networked race the client's menu
    -- reopens on SPLIT SCREEN too (§1.1)
    St.ui.returnToTab = true
  end
  if not isHost() then return end
  U.log(TAG, "race map (host): listening=%s remote=%d expected=%d relistenDone=%s", tostring(M.isListening()),
    remoteCount(), St.net.expectedRemote or 0, tostring(St.net.relistenDone))
  if St.net.relistenDone then return end
  afterSameWorld("net.travel1", cfg.TravelCheckDelayMs, function() M.checkTravel(1) end)
  afterSameWorld("net.travel2", cfg.RemoteArriveTimeoutMs, function() M.checkTravel(2) end)
end

-- ---------------------------------------------------------------------------------------------------------
-- The travel question (V-NET-13) and its fallbacks
-- ---------------------------------------------------------------------------------------------------------

-- Native travel was a local OpenLevel: the race map runs standalone, remote players were dropped.
local function hostTravelFallback()
  local mode = cfg.HostTravelFallback
  local map = mapPath()
  if mode == "none" then
    U.warn(TAG, "travel fallback: host is standalone on %s; HostTravelFallback=none, nothing done", map)
    status("RACE STARTED OFFLINE: REMOTE PLAYERS WERE DROPPED")
    return
  end
  if (St.net.expectedRemote or 0) == 0 then
    -- Nobody to wait for: restarting the race would only cost a reload. The front end relistens later.
    U.log(TAG, "travel fallback: host standalone but no remote players were expected; race left as is")
    return
  end
  if map == "" then
    U.err(TAG, "travel fallback: current map path unknown, cannot relisten")
    return
  end
  St.net.relistenDone = true
  St.net.lateJoinAllowed = (mode == "relisten_takeover")
  St.net.relistenPending = (mode == "relisten")
  St.net.waitFromStage2 = false
  -- provisional deadline; re-armed by tick() once the race map actually listens (the blocking World Partition
  -- reload must not eat the clients' rejoin window), and extended while clients keep arriving
  St.net.waitUntilMs = St.nowMs() + cfg.RejoinWaitMs
  St.net.waitRemoteSeen, St.net.waitArriveMs = 0, 0
  St.net.remoteAtCheck = 0                             -- standalone: nobody is connected yet
  -- tick() confirms the listen or reports RELISTEN FAILED after cfg.ListenCheckMs (race phases too)
  St.net.listenSinceMs = St.nowMs()
  U.warn(TAG, "travel fallback (%s): native travel was local; open %s?listen, expecting %d remote", tostring(mode),
    map, St.net.expectedRemote or 0)
  status("RELISTENING ON THE RACE MAP: CLIENTS REJOIN")
  -- VERIFY(V-NET-07): the recipe survives the reload (UEventRecipeSubsystem is per GameInstance);
  -- fallback cfg.HostTravelFallback = "relisten_takeover".
  U.console("open " .. map .. "?listen")
  emitNet()
end

-- At least one human PC (local or remote) has no vehicle pawn.
local function someHumanWithoutCar()
  local ok, res = pcall(function()
    local pcs = U.mod("roster").humanPCs()
    for _, pc in ipairs(pcs) do
      if U.ok(pc) and not U.isVehicle(pc.Pawn) then return true end
    end
    return false
  end)
  return ok and res == true
end

local function serverTravelNow(reason)
  local map = mapPath()
  if map == "" then
    U.err(TAG, "servertravel (%s): current map path unknown", reason)
    return false
  end
  St.net.relistenPending = false
  St.net.waitFromStage2 = false
  St.net.serverTravelDone = true
  U.warn(TAG, "servertravel (%s): %s with %d/%d remote players", reason, map, remoteCount(),
    St.net.expectedRemote or 0)
  status("RESTARTING THE RACE WITH EVERYONE")
  -- Console SERVERTRAVEL (token present in Shipping [NET§2]); runs UWorld::ServerTravel on the listen host.
  -- VERIFY(V-NET-13): console servertravel on the listen host carries every client (child connections
  -- included), keeps ?listen and the race restarts with every PlayerState on the grid;
  -- fallback cfg.HostTravelFallback = "relisten_takeover".
  if not U.console("servertravel " .. map) then
    U.err(TAG, "servertravel (%s): console command failed", reason)
    status("RESTART FAILED (servertravel error, see log)")
    emitNet()
    return false
  end
  -- Seamless travel runs no LoadMap and the OnSeamlessTravelStarted pre-hook may not fire (V-CORE-10): leave the
  -- race now, while every PC and PlayerState is alive (UWorld::ServerTravel only arms the travel; it happens on a
  -- later tick). takeover.releaseAll gives adopted PlayerStates back before HandleSeamlessTravelPlayer.
  U.try(TAG, function() U.mod("phase").markLeaving("servertravel") end)
  -- ExecuteConsoleCommand gives no result: UWorld::ServerTravel can refuse silently (CanServerTravel false, a travel
  -- already pending, package not found). Still in this world after cfg.ServerTravelWatchdogMs = it did not happen:
  -- the race phase is restored so the race ticks resume and serverTravelDone is cleared; the servertravel is retried
  -- once (cfg.ServerTravelWatchdogMs later again), and a second refusal lets takeover adopt the remote players that
  -- wait without a car (St.net.lateJoinAllowed: takeover's mid-game filter would refuse them as "joined after the
  -- start"), so they race in AI cars instead of spectating.
  -- VERIFY(V-NET-16): a refused servertravel logs "servertravel was not executed" and the race keeps running.
  local gen = St.worldGen
  St.net.travelWatchGen = gen
  afterSameWorld("net.travelwatch", tonumber(cfg.ServerTravelWatchdogMs) or 10000, function()
    if St.net.travelWatchGen ~= gen then return end
    St.net.travelWatchGen = nil
    U.err(TAG, "servertravel was not executed (%s): still on %s after %d ms", reason, mapPath(),
      tonumber(cfg.ServerTravelWatchdogMs) or 10000)
    local ok, restored = U.try(TAG, function() return U.mod("phase").cancelLeaving("servertravel refused", gen) end)
    if ok and restored then
      St.net.serverTravelDone = false
      if (St.net.serverTravelRetries or 0) < 1 then
        St.net.serverTravelRetries = (St.net.serverTravelRetries or 0) + 1
        U.warn(TAG, "servertravel refused: retrying once in 2 s (V-NET-16)")
        status("RESTART FAILED: RETRYING")
        afterSameWorld("net.travelretry", 2000, function()
          if not (isHost() and isRacePhase()) or St.net.serverTravelDone then return end
          serverTravelNow(tostring(reason) .. ", retry")
        end)
      else
        St.net.lateJoinAllowed = true
        U.warn(TAG, "servertravel refused twice: late remote players take AI cars (lateJoinAllowed, V-NET-16)")
        status("RESTART FAILED: LATE PLAYERS TAKE AI CARS")
      end
    end
    emitNet()
  end)
  return true
end

-- stage 1 = early check (cfg.TravelCheckDelayMs after LOADING), stage 2 = remote-arrival timeout,
-- stage 3 = re-armed missing-car check (cfg.ServerTravelOnMissingCars) until the race started + grace.
function M.checkTravel(stage)
  if not isHost() or not isRacePhase() then return end
  -- VERIFY(V-NET-13): native LaunchCustomRace travel keeps the listen driver and carries clients
  -- (listening + remote >= expected); fallback cfg.HostTravelFallback.
  local listening = M.isListening()
  local remote, expected = remoteCount(), St.net.expectedRemote or 0
  if stage ~= 3 then
    U.log(TAG, "checkTravel(%d): listening=%s remote=%d expected=%d map=%s", stage, tostring(listening), remote,
      expected, mapPath())
  end
  if stage == 1 then
    if not listening then
      hostTravelFallback()
    elseif remote >= expected then
      U.log(TAG, "checkTravel(1): native networked travel carried every client (V-NET-13 answered: yes)")
    end
    return
  end
  if not listening then return end
  if stage == 2 and remote < expected then
    local mode = cfg.HostTravelFallback
    U.warn(TAG, "checkTravel(2): %d of %d remote players arrived; missing clients rejoin", remote, expected)
    if mode == "relisten" and not St.net.serverTravelDone then
      St.net.relistenPending = true
      St.net.waitUntilMs = St.nowMs() + cfg.RejoinWaitMs
      -- a client that left on purpose (DISCONNECT) or crashed never comes back: the wait ends in a servertravel
      -- only if somebody arrived after this check (tick())
      St.net.remoteAtCheck = remote
      -- The travel was networked: a late client may simply be a slow loader carried by the seamless travel
      -- (HandleSeamlessTravelPlayer adds it once loaded) that still gets its car. tick() restarts the race only if a
      -- human has no car once the arrivals settled.
      St.net.waitFromStage2 = true
      St.net.waitRemoteSeen, St.net.waitArriveMs = remote, St.nowMs()
    elseif mode == "relisten_takeover" then
      St.net.lateJoinAllowed = true
    end
    emitNet()
    return
  end
  if cfg.ServerTravelOnMissingCars and not St.net.serverTravelDone then
    -- Humans get their cars at the grid spawn / possession, which can come after this fixed-delay check (slow World
    -- Partition load): the "no car" test only counts once the race started plus the takeover grace period, like
    -- takeover's own gate [PS§8 #7]. Before that the check is re-armed (stage 3) in this world.
    local graceOver = St.race.started == true and (St.race.startedAtMs or 0) > 0
      and St.nowMs() - St.race.startedAtMs >= (tonumber(cfg.TakeoverGraceMs) or 3000)
    if not graceOver then
      if St.phase ~= "POSTRACE" then
        afterSameWorld("net.travel3", 2000, function() M.checkTravel(3) end)
      end
      return
    end
    -- ARCHITECTURE §4.2 net: only when every expected client is present (stage 2's remote < expected early return
    -- does not cover stage 3: a client may drop during the grace period).
    remote = remoteCount()
    if remote < expected then
      U.log(TAG, "checkTravel(%d): %d of %d remote players present; no missing-car servertravel", stage, remote,
        expected)
      return
    end
    if someHumanWithoutCar() then serverTravelNow("human without a car") end
  end
end

-- ---------------------------------------------------------------------------------------------------------
-- Driver configuration check (V-NET-02)
-- ---------------------------------------------------------------------------------------------------------

-- Reads UEngine.NetDriverDefinitions (Array<Struct<NetDriverDefinition>>; struct members Name DefName,
-- Name DriverClassName, Name DriverClassNameFallback, Int MaxChannelsOverride [reflect-types --struct]).
-- VERIFY(V-NET-02): GameNetDriver = /Script/OnlineSubsystemUtils.IpNetDriver once mod/config/Engine.ini is
-- active (fallback: fix the Engine.ini section/path, V-NET-01). HOST/JOIN still run when it is not.
function M.checkDriverConfig()
  local eng = UEHelpers.GetEngine()
  if not U.ok(eng) then
    U.warn(TAG, "checkDriverConfig: engine object not found, retried in the next front end")
    return
  end
  local defs = eng.NetDriverDefinitions
  local okN, n = pcall(U.callMethod, defs, "GetArrayNum")
  if not okN or type(n) ~= "number" then
    U.warn(TAG, "checkDriverConfig: NetDriverDefinitions not readable")
    St.net.driverChecked = true
    return
  end
  local gameDriver = nil
  for i = 1, n do
    U.try(TAG, function()
      local d = defs[i]
      local def, cls, fb = U.str(d.DefName), U.str(d.DriverClassName), U.str(d.DriverClassNameFallback)
      U.log(TAG, "NetDriverDefinitions[%d]: DefName=%s DriverClassName=%s Fallback=%s", i, def, cls, fb)
      if def == "GameNetDriver" and gameDriver == nil then gameDriver = cls end
    end)
  end
  St.net.driverChecked = true
  St.net.driverOk = (gameDriver ~= nil and gameDriver:find(IPNETDRIVER, 1, true) ~= nil)
  if St.net.driverOk then
    U.log(TAG, "GameNetDriver = %s: Engine.ini override active", gameDriver)
  else
    U.warn(TAG, "GameNetDriver = %s: ENGINE.INI NET OVERRIDE NOT ACTIVE (split-screen clients need IpNetDriver)",
      tostring(gameDriver))
    if netModeSetting() ~= "offline" then status("ENGINE.INI NET OVERRIDE NOT ACTIVE") end
  end
  emitNet()
end

-- ---------------------------------------------------------------------------------------------------------
-- Client front end without a main menu (V-NET-17)
-- ---------------------------------------------------------------------------------------------------------

local function clientMenuWidget()
  local ok, m = pcall(function() return U.mod("menu_tab").menu() end)
  if ok and m and U.ok(m) then return m end
  local okF, f = pcall(FindFirstOf, "WBP_FE_MainMenu_C")
  if okF and U.ok(f) then return f end
  return nil
end

-- attempt 1: 5 s after a connected client's FRONTEND; attempt 2: 3 s after the cosmetic fallback.
function M.checkClientMenu(attempt)
  if not M.isConnectedClient() or not inFrontEnd() then return end
  local menu = clientMenuWidget()
  local function st(key)
    local v = U.csmActive(key, true)
    return v == nil and "?" or tostring(v)
  end
  U.log(TAG, "client front end (V-NET-17, check %d): main menu %s; CSM PrimaryModeSelect=%s QuickRaceSetup=%s",
    attempt, menu and "present" or "MISSING", st(C.ASSET.CSM_PrimaryModeSelect), st(C.ASSET.CSM_QuickRaceSetup))
  if menu then return end
  if attempt == 1 and cfg.ClientMenuFallback == "csm" then
    local done = U.try(TAG, function()
      local mgr = U.giSubsystem("CosmeticStateMachineManager")
      local root = U.obj(C.ASSET.CSM_FrontEndRoot)
      local target = U.obj(C.ASSET.CSM_PrimaryModeSelect)
      if not (U.ok(mgr) and U.ok(root) and U.ok(target)) then
        error(string.format("mgr=%s root=%s state=%s", tostring(U.ok(mgr)), tostring(U.ok(root)), tostring(U.ok(target))))
      end
      -- CosmeticStateMachineManager:GetStateMachineForRoot(Object rootAsset) -> Object
      local sm = mgr:GetStateMachineForRoot(root)
      if not U.ok(sm) then error("no state machine for CSM_FrontEnd_Root") end
      -- CosmeticStateMachine:ChangeStateTo(Object newState, Str reason, Object optionalPayload): 3 args
      -- VERIFY(V-NET-17): on a client this shows WBP_FE_MainMenu (then menu_tab.ensure installs our tab).
      sm:ChangeStateTo(target, "SWGRCouch", nil)
    end)
    U.warn(TAG, "client front end without a main menu: cosmetic ChangeStateTo(PrimaryModeSelect) %s",
      done and "sent" or "failed")
    afterSameWorld("net.clientmenu", 3000, function() M.checkClientMenu(2) end)
    return
  end
  status("NO MENU ON THIS CLIENT: CTRL+F8 OR 'couch disconnect' TO LEAVE")
end

-- ---------------------------------------------------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------------------------------------------------

local function logLiveDriverOnce()
  if St.net.driverClassLogged then return end
  St.net.driverClassLogged = true
  U.try(TAG, function()
    local drv = U.world().NetDriver
    U.log(TAG, "listening: live NetDriver = %s", tostring(drv:GetFullName()))
  end)
end

-- MAIN loop (front end and race).
function M.tick()
  local now = St.nowMs()
  if M.isConnectedClient() then St.net.clientWorldGen = St.worldGen end
  if inFrontEnd() then M.onFrontEnd() elseif isRacePhase() then M.onRaceMap() end

  -- Host: confirm or time out a front-end listen attempt.
  if St.net.hosting and (St.net.listenSinceMs or 0) > 0 then
    if M.isListening() then
      St.net.listenSinceMs = 0
      if isRacePhase() and St.net.relistenDone and St.net.relistenPending and not St.net.waitFromStage2 then
        -- the relisten (hostTravelFallback) is confirmed: the clients' rejoin window starts now
        St.net.waitUntilMs = now + cfg.RejoinWaitMs
        St.net.waitRemoteSeen, St.net.waitArriveMs = remoteCount(), now
        U.log(TAG, "race-map relisten confirmed: rejoin window %d ms from now", cfg.RejoinWaitMs)
      end
      logLiveDriverOnce()
      status("HOSTING ON PORT %d", port())
      emitNet()
    elseif inFrontEnd() and now - St.net.listenSinceMs >= cfg.ListenCheckMs then
      St.net.hosting = false
      St.net.listenSinceMs = 0
      status("LISTEN FAILED (see UE4SS.log)")
      emitNet()
    elseif isRacePhase() and St.net.relistenDone and now - St.net.listenSinceMs >= cfg.ListenCheckMs then
      -- The race-map relisten (hostTravelFallback) came up standalone (e.g. NetDriverListenFailure on the port):
      -- nobody can rejoin this race. Hosting stays on: the next front end relistens (AutoRelistenInFrontEnd).
      St.net.listenSinceMs = 0
      St.net.relistenPending = false
      St.net.lateJoinAllowed = false
      U.err(TAG, "relisten on %s failed: not listening after %d ms", mapPath(), cfg.ListenCheckMs)
      status("RELISTEN FAILED (see UE4SS.log)")
      emitNet()
    end
  end

  -- After STOP HOSTING: the next front-end world must not listen (V-NET-18). Reported once per stop.
  if St.net.stopCheckGen ~= nil and St.net.stopCheckGen ~= St.worldGen and inFrontEnd() then
    St.net.stopCheckGen = nil
    if not St.net.hosting and M.isListening() then
      U.err(TAG, "STOP HOSTING did not close the listen server (StopHostingMethod=%s): still listening on port %d",
        tostring(cfg.StopHostingMethod), port())
      status("STILL LISTENING: PRESS STOP HOSTING AGAIN (OR SET StopHostingMethod)")
      emitNet()
    end
  end

  -- Host in the front end: keep the remote roster current for the Lobby.
  if isHost() and inFrontEnd() then
    U.try(TAG, function() U.mod("roster").tick() end)
    local n = remoteCount()
    if n ~= St.net.lastRemoteCount then
      U.log(TAG, "remote players in the lobby: %d -> %d", St.net.lastRemoteCount or 0, n)
      St.net.lastRemoteCount = n
      emitNet()
    end
  end

  -- Client: a pending connection completed.
  if St.net.connecting and M.isConnectedClient() then
    St.net.connecting = false
    St.net.connectSinceMs = 0
    St.net.rejoinTries = 0
    St.net.nextRejoinMs = 0
    St.join.frozen = true
    status("CONNECTED TO %s", joinAddr())
    emitNet()
  end

  -- Host after a relisten fallback: wait for the clients, then restart the race with everyone present.
  if isHost() and isRacePhase() and St.net.relistenPending and not St.net.serverTravelDone and M.isListening() then
    local remote, expected = remoteCount(), St.net.expectedRemote or 0
    if remote ~= St.net.waitRemoteSeen then
      St.net.waitRemoteSeen, St.net.waitArriveMs = remote, now
    end
    -- The window ends at waitUntilMs, but not while clients are still arriving (a split-join guest's child
    -- connection follows its P1): it is extended until no arrival for cfg.RejoinSettleMs, at most to twice the
    -- window. The relisten path re-arms waitUntilMs when the listen is confirmed (tick, above).
    local due = now >= (St.net.waitUntilMs or 0)
    local settleMs = tonumber(cfg.RejoinSettleMs) or 10000
    local over = due and ((now - (St.net.waitArriveMs or 0) >= settleMs)
      or now >= (St.net.waitUntilMs or 0) + cfg.RejoinWaitMs)
    local arrivedAll = remote >= expected
    local someArrived = over and remote > (St.net.remoteAtCheck or 0)
    if St.net.waitFromStage2 and (arrivedAll or someArrived) then
      -- Wait armed by checkTravel(2): decide once the race started plus the takeover grace AND no arrival for that
      -- long (a late client's car may still be possessed), with the same test as ServerTravelOnMissingCars.
      local grace = tonumber(cfg.TakeoverGraceMs) or 3000
      local settled = St.race.started == true and (St.race.startedAtMs or 0) > 0
        and now - St.race.startedAtMs >= grace and now - (St.net.waitArriveMs or 0) >= grace
      if settled then
        if someHumanWithoutCar() then
          serverTravelNow(("late remote players without a car (%d/%d)"):format(remote, expected))
        else
          St.net.relistenPending = false
          St.net.waitFromStage2 = false
          U.log(TAG, "late clients arrived with cars (%d/%d remote): no restart", remote, expected)
          emitNet()
        end
      end
    elseif arrivedAll then
      serverTravelNow("all remote players rejoined")
    elseif over then
      if someArrived then
        serverTravelNow(("rejoin wait over (%d/%d)"):format(remote, expected))
      else
        -- nobody came back (left on purpose, crashed): restarting the race would gain nothing
        St.net.relistenPending = false
        St.net.waitFromStage2 = false
        U.warn(TAG, "rejoin wait over: nobody rejoined (%d/%d remote, %d at the check); race left as is", remote,
          expected, St.net.remoteAtCheck or 0)
        status("NOBODY REJOINED: RACE CONTINUES")
        emitNet()
      end
    end
  end
end

-- SLOW loop (every phase).
function M.slowTick()
  local now = St.nowMs()
  local standalone = isStandalone()
  if M.isConnectedClient() then St.net.clientWorldGen = St.worldGen end

  -- A world in which this machine was a connected client and that now reads standalone is a hard (non-seamless)
  -- ClientTravel in flight: stock UEngine::Browse shuts the world's NetDriver down, then a UPendingNetGame connects
  -- while the host loads the race map (World Partition: easily longer than the rejoin delay). A connect() now would
  -- cancel that travel (Browse -> CancelPending). A real drop reloads the default map (new St.worldGen) and is armed
  -- by onFrontEnd / onNetworkFailure. A same-world standalone state older than CONNECT_GIVEUP_MS (the engine's
  -- InitialConnectTimeout + margin) is treated as a drop after all.
  -- VERIFY(V-NET-14): a client's hard travel logs "connected-client world reads standalone" and then a new world.
  local inTravel = false
  if standalone and St.net.clientWorldGen ~= nil and St.net.clientWorldGen == St.worldGen then
    if (St.net.travelStandaloneSinceMs or 0) == 0 then
      St.net.travelStandaloneSinceMs = now
      U.log(TAG, "connected-client world reads standalone: travel in flight assumed (no rejoin for %d ms)",
        CONNECT_GIVEUP_MS)
    end
    inTravel = now - St.net.travelStandaloneSinceMs < CONNECT_GIVEUP_MS
  else
    St.net.travelStandaloneSinceMs = 0
  end

  -- Client: a pending connection that neither connected nor failed (engine timeout normally comes first).
  if St.net.connecting and standalone and (St.net.connectSinceMs or 0) > 0
      and now - St.net.connectSinceMs >= CONNECT_GIVEUP_MS then
    St.net.connecting = false
    St.net.connectSinceMs = 0
    status("CONNECT TIMED OUT: %s", joinAddr())
    armRejoin("connect timeout")
    emitNet()
  end

  -- Client: dropped back to a standalone front end without a HandleNetworkFailure callback (V-NET-14 backup).
  if St.net.wantConnected and not St.net.connecting and standalone and inFrontEnd() and not inTravel
      and (St.net.nextRejoinMs or 0) == 0 then
    armDropped("standalone while connected was wanted")
  end

  -- Client: automatic rejoin (never into a travel in flight: see inTravel).
  if St.net.wantConnected and not St.net.connecting and standalone and inFrontEnd() and not inTravel
      and (St.net.nextRejoinMs or 0) > 0 and now >= St.net.nextRejoinMs then
    if (St.net.rejoinTries or 0) < cfg.RejoinMaxTries then
      St.net.rejoinTries = (St.net.rejoinTries or 0) + 1
      St.net.nextRejoinMs = 0
      U.log(TAG, "auto-rejoin try %d/%d", St.net.rejoinTries, cfg.RejoinMaxTries)
      if not M.connect() then
        St.net.wantConnected = false
        U.warn(TAG, "auto-rejoin: connect refused, giving up")
      end
    else
      St.net.wantConnected = false
      St.net.nextRejoinMs = 0
      status("GAVE UP RECONNECTING AFTER %d TRIES", St.net.rejoinTries or 0)
    end
    emitNet()
  end

  -- Client gave up or disconnected: the guest set may change again.
  if not St.net.wantConnected and not St.net.connecting and standalone and St.join.frozen then
    St.join.frozen = false
    St.emit("players")
  end

  -- Host in the front end: the native login gate must not hold remote players.
  -- AFrontEndGameMode:IsAnyLoginPending() -> Bool (0 params) [reflect-func-all, flags 0x54020401].
  if isHost() and inFrontEnd() and now - (St.net.lastLoginLogMs or 0) >= cfg.LoginLogEveryMs then
    St.net.lastLoginLogMs = now
    U.try(TAG, function()
      local gm = U.gm()
      if U.ok(gm) and U.isA(gm, "FrontEndGameMode") then
        -- VERIFY(V-NET-11): false once the clients are in the lobby.
        U.log(TAG, "IsAnyLoginPending=%s remote=%d listening=%s", tostring(gm:IsAnyLoginPending()), remoteCount(),
          tostring(M.isListening()))
      end
    end)
  end
end

-- ---------------------------------------------------------------------------------------------------------
-- Hot reload (Ctrl+F11): the user's network intent survives in UE4SS shared variables (scalars only)
-- ---------------------------------------------------------------------------------------------------------

function M.persistShared(put)
  put("net.hosting", St.net.hosting == true)
  put("net.wantConnected", St.net.wantConnected == true)
  put("net.rejoinTries", math.floor(tonumber(St.net.rejoinTries) or 0))
end

function M.restoreShared(get)
  if get("net.hosting") == true then St.net.hosting = true end
  if get("net.wantConnected") == true then St.net.wantConnected = true end
  local t = get("net.rejoinTries")
  if type(t) == "number" then St.net.rejoinTries = t end
  if St.net.hosting or St.net.wantConnected then
    U.log(TAG, "hot reload: hosting=%s wantConnected=%s restored", tostring(St.net.hosting),
      tostring(St.net.wantConnected))
  end
end

-- ---------------------------------------------------------------------------------------------------------
-- Init (hooks and listeners only; no UFunction calls)
-- ---------------------------------------------------------------------------------------------------------

function M.init()
  initState()
  -- Native UFunction: exists at boot, so the hook registers at once (otherwise U.hook queues it).
  U.hook(C.FN.NetFailure, { post = M.onNetworkFailure }, TAG)
  U.hook(C.FN.UIReturnToMainMenu, { pre = M.onUserLeaves }, TAG)   -- native static: registers at boot (V-NET-19)
  St.on("phase", TAG, function(new, old)
    if new == "FRONTEND" then
      St.net.fePhaseGen = St.worldGen
      M.onFrontEnd(true)
    elseif new == "LOADING" or new == "PRERACE" then
      M.onRaceMap()
    end
  end)
  U.log(TAG, "init: NetMode=%s JoinMethod=%s HostTravelFallback=%s AutoRejoin=%s", tostring(netModeSetting()),
    tostring(cfg.JoinMethod), tostring(cfg.HostTravelFallback), tostring(cfg.AutoRejoin))
end

return M
