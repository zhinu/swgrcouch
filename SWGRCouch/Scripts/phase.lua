-- SWGRCouch · phase.lua (G2 Wiring & lifecycle)
-- Decides the current lifecycle phase and emits "world", "phase"(new, old) and "leaving"(reason).
-- ARCHITECTURE.md §4.2 phase, §5. Detection runs in the MAIN loop (phase.tick); engine hooks only make it
-- earlier (LoadMap pre/post, InitGameState post, RacingGameState:OnSeamlessTravelStarted pre,
-- RacingGameMode:RequestReturnToMenus pre).
--
-- Phases: BOOT|FRONTEND|LAUNCHING|LOADING|PRERACE|RACING|POSTRACE|LEAVING|OTHER|TRANSIT
-- Revision 2026-10-07 (run E): phase.photoMode() + "photomode"(active, why) event (shared photo-mode detection for every
-- module that must back off); a (hot) reload re-detects the phase on the next frame (M.redetect) and warns once when a
-- live world stays BOOT (V-CORE-14).
--
-- Game/engine data read (verified with scripts/reflect-types.py on the shipping exe):
--   UWorld.GameState (engine)                         ARacingGameState.bIsRaceStarted   Bool  (Net)
--   ARacingGameState.bIsRaceFinished  Bool  (Net)     ARacingGameState.Vehicles  Array<Object<AVehiclePawn>>
--   ARacingGameState:OnSeamlessTravelStarted(Object<UWorld> currentWorld, Str newMapUrl)  flags 0x40401 Native
--   ARacingGameMode:RequestReturnToMenus()            flags 0x4020401 BlueprintCallable Native (server only)

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "phase"

-- A launch that has not left the front end after this long is considered failed (§5.1 LAUNCHING edge).
-- Counted only while the launch's own front-end world is current (see compute()). A launch the game ACCEPTED
-- (St.launch.accepted, set by launch.start / prepareExternal once GameInstance.PrimaryFlow == QuickRace) gets
-- cfg.LaunchAcceptedTimeoutMs instead: the native LaunchingQuickRace flow may preload or show a loading screen in
-- the front-end world before it travels [RB§10 #2], and timing it out would undo the guest bookkeeping of a launch
-- that is still going to happen (launchedByUs cleared, dormant guests re-created, joined guests closed at race_enter).
local LAUNCH_TIMEOUT_MS = 30000
local LAUNCH_ACCEPTED_TIMEOUT_MS = 180000

local function launchLimitMs()
  if St.launch.accepted ~= true then return tonumber(cfg.LaunchTimeoutMs) or LAUNCH_TIMEOUT_MS end
  -- VERIFY(V-LCH-06): GameInstance.PrimaryFlow stays QuickRace (2) until the launch travels; a value that changed
  -- back means the game abandoned the launch, so the short limit applies again.
  local okF, flow = pcall(function() return U.gi().PrimaryFlow end)
  if okF and type(flow) == "number" and flow ~= C.E.PrimaryFlow.QuickRace then
    return tonumber(cfg.LaunchTimeoutMs) or LAUNCH_TIMEOUT_MS
  end
  return tonumber(cfg.LaunchAcceptedTimeoutMs) or LAUNCH_ACCEPTED_TIMEOUT_MS
end

-- Seamless-travel transition map (DefaultEngine.ini:18 TransitionMap=/Game/Griffin/Maps/L_SeamlessTravel/
-- L_SeamlessTravel.L_SeamlessTravel [PS§4, NET]). Stock UE carries the old GameMode + GameState into it
-- (AGameModeBase::GetSeamlessTravelActorList(bToTransition=true), then CopyGameState), so its World.GameState is
-- still the previous FrontEndGameState / RacingGameState: it must never be read as a front-end or race phase.
-- C.MAP.Transition belongs to consts.lua (G1); the literal is the fallback until G1 adds the key.
local TRANSITION_MAP = (C.MAP and C.MAP.Transition) or "/Game/Griffin/Maps/L_SeamlessTravel/L_SeamlessTravel"
local TRANSITION_SHORT = TRANSITION_MAP:match("([^/]+)$")

local RACE = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }
local FRONT = { FRONTEND = true, LAUNCHING = true }
-- Rank inside one RacingGameState: a phase never goes backwards there (§4.2), LEAVING is terminal.
local RANK = { LOADING = 1, PRERACE = 2, RACING = 3, POSTRACE = 4, LEAVING = 5 }

-- Private bookkeeping (UObject-free; dumped by diag through phase.stats()).
local refreshQueued = false
local leavingGsKey = nil          -- GameState address for which "leaving" was already emitted
-- World changes seen since "leaving" was emitted for leavingGsKey. The left GameState may legitimately be
-- carried into exactly one following world (the seamless transition world); after that the key is dropped so
-- a new GameState allocated at the same address is not mistaken for the old one.
local leavingWorlds = 0
-- Set by the LoadMap post-hook: the next tick treats the world as new even if the UWorld address was reused
-- (hard travel to the same kind of map can allocate the new UWorld in the freed block of the old one).
local forceNewWorld = false
-- Front-end world / GameState where the pending launch began (taken on the first compute() that sees a new
-- St.launch.atMs). The 30 s timeout only runs in that world; the same FrontEndGameState carried into
-- another world (transition) means the travel is under way.
local launchAtMs, launchWorldKey, launchGsKey = nil, nil, nil
local compute                     -- forward: function(w) -> phase, gs (defined under "Detection")
local stats = { loadMapPre = 0, loadMapPost = 0, initGameState = 0, seamless = 0, returnToMenus = 0,
                worlds = 0, forcedWorlds = 0, transitWorlds = 0, gsWorlds = 0, lastLeaveReason = "", lastTransitGs = "" }
local sinceWorld = { loadMapPre = 0, loadMapPost = 0, initGameState = 0 }

-- ---------------------------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------------------------

function M.get() return St.phase end

-- FRONTEND or LAUNCHING
function M.isFrontEnd() return FRONT[St.phase] == true end

-- LOADING, PRERACE, RACING, POSTRACE
function M.isRace() return RACE[St.phase] == true end

-- Read-only counters for diag (hook firing evidence for V-DIAG-01 / V-CORE-10).
function M.stats() return stats end

-- ---------------------------------------------------------------------------------------------
-- Photo mode (run E 2026-10-07: entering the game's photo mode possessed a BP_PhotoModePawn_C for BOTH local PCs and
-- wreck/hud kept fighting it). One shared answer for every module that must back off while it is open: hud, pause,
-- inputfix, present, wreck. Sources, any one is enough:
--   1. UPhotoModeManager (WorldSubsystem, /Script/PhotoMode) .bPhotoModeActive          [reflect.tsv]
--   2. a local PC whose pawn's class name contains "PhotoModePawn" (APhotoModePawn, BP_PhotoModePawn_C)
--   3. CSM_PauseMenus_Photomode active (the pause CSM state that launches it: BP_Csm_LaunchPhotomode), find-only
-- Cached cfg.PhotoModeCacheMs (default 200) so the FAST loop may ask. Edges are logged and emitted by M.tick as
-- "photomode"(active, why).  VERIFY(V-PH-01): "photo mode OPEN (...)" when it opens, "photo mode CLOSED" after.
-- ---------------------------------------------------------------------------------------------
local PHOTO_CSM = "/Game/Griffin/Config/StateMachines/PauseMenus/CSM_PauseMenus_Photomode.CSM_PauseMenus_Photomode"
local photo = { at = -1e12, v = false, why = nil, last = false }

-- class names by pawn address, per world (couch-racefast: GetClass + FName -> string for every local pawn every 200 ms
-- of the race; a pawn's class never changes, a new pawn - photo mode's - has another address)
local pawnCls = { gen = nil, by = {} }
local function pawnClassName(pc)
  if pawnCls.gen ~= St.worldGen then pawnCls.gen, pawnCls.by = St.worldGen, {} end
  local ok, n = pcall(function()
    local p = pc.Pawn
    if not U.ok(p) then return "" end
    local k = U.key(p)
    local c = pawnCls.by[k]
    if c then return c end
    c = U.className(p)
    if c ~= "" then pawnCls.by[k] = c end
    return c
  end)
  return (ok and type(n) == "string") and n or ""
end

local function detectPhoto()
  if not RACE[St.phase] and St.phase ~= "OTHER" then return false, nil end
  local okM, active = pcall(function()
    local pm = U.worldSubsystem("/Script/PhotoMode.PhotoModeManager")
    return U.ok(pm) and pm.bPhotoModeActive == true
  end)
  if okM and active then return true, "PhotoModeManager.bPhotoModeActive" end
  for _, lp in ipairs(U.localPlayersRO()) do
    if U.ok(lp.pc) then
      local n = pawnClassName(lp.pc)
      if n:find("PhotoModePawn", 1, true) then return true, string.format("P%d possesses %s", lp.index, n) end
    end
  end
  if U.csmActive(PHOTO_CSM, true) == true then return true, "CSM_PauseMenus_Photomode active" end
  return false, nil
end

--- true while the game's photo mode is open (any local player), plus why. Cheap (cached).
function M.photoMode()
  local now = St.nowMs()
  local cache = tonumber(cfg.PhotoModeCacheMs) or 200
  if now - photo.at >= cache then
    photo.at = now
    local ok, v, why = pcall(detectPhoto)
    photo.v, photo.why = (ok and v == true), ok and why or nil
  end
  return photo.v, photo.why
end

local function photoEdge()
  local v, why = M.photoMode()
  if v == photo.last then return end
  photo.last = v
  if v then
    local pawns = {}
    for _, lp in ipairs(U.localPlayersRO()) do
      if U.ok(lp.pc) then pawns[#pawns + 1] = string.format("P%d=%s", lp.index, pawnClassName(lp.pc)) end
    end
    U.log(TAG, "photo mode OPEN (%s); pawns: %s - modules back off until it closes", tostring(why),
      table.concat(pawns, " "))
  else
    U.log(TAG, "photo mode CLOSED")
  end
  St.photoMode = v
  St.emit("photomode", v, why)
end

-- ---------------------------------------------------------------------------------------------
-- Transitions
-- ---------------------------------------------------------------------------------------------

-- Last phase other than TRANSIT: tells a race entered from the menu (FRONTEND/LAUNCHING, maybe through a seamless
-- transition world) from one entered after another race (relisten, servertravel) or after a hot reload (BOOT).
local lastStable = "BOOT"

local function setPhase(new, why)
  local old = St.phase
  if new == old then return end
  local from = (old == "TRANSIT") and lastStable or old
  if old ~= "TRANSIT" then lastStable = old end
  St.phase = new
  St.phaseSinceMs = St.nowMs()
  local map = ""
  if new ~= "TRANSIT" and new ~= "LEAVING" then
    local ok, name = U.try(TAG, U.levelName)
    if ok and name then map = tostring(name) end
  end
  U.log(TAG, "%s -> %s%s%s", old, new, (why and why ~= "") and ("  (" .. why .. ")") or "",
    map ~= "" and ("  map=" .. map) or "")
  if old == "BOOT" then
    -- VERIFY(V-CORE-14): after Ctrl+F11 mid-race this line names the race phase within ~0.3 s of "started".
    U.log(TAG, "phase detected from the live world after (re)load: %s (race started=%s)", new,
      tostring(St.race.started))
  end
  if new == "FRONTEND" then St.launch.pending = false end
  -- The launch is over once it produced a race: nothing reads pending during a race, and a stale pending would make
  -- the post-race menu (installed by its RegisterTabs before phase.tick sees the front-end world) keep returnToTab
  -- without starting the return chain. St.race.launchedByUs carries "launched by us" through the race.
  if RACE[new] and not RACE[old] then
    St.launch.pending = false
    St.launch.accepted = false
  end
  -- "race_enter"(new, from) runs before every "phase" listener of the first race phase, so a module can veto or
  -- clean up (join removes the guests of a race the mod did not launch) before split/gfx/hud react.
  if RACE[new] and not RACE[old] then St.emit("race_enter", new, from) end
  St.emit("phase", new, old)
end

-- Sets LEAVING once per race and emits "leaving"(reason) synchronously (before the old world is torn
-- down when called from a hook). Only meaningful while a race phase is active.
function M.markLeaving(reason)
  reason = reason or "?"
  if not M.isRace() then
    U.dbg(TAG, "markLeaving(%s) ignored in phase %s", reason, St.phase)
    return
  end
  if leavingGsKey ~= nil and leavingGsKey == St.gsKey then return end
  leavingGsKey = St.gsKey
  leavingWorlds = 0
  stats.lastLeaveReason = reason
  U.log(TAG, "leaving the race (%s)", reason)
  -- "leaving" first: takeover.releaseAll must run while PCs/PlayerStates are still alive (§3.4, §5.2).
  St.emit("leaving", reason)
  setPhase("LEAVING", reason)
end

-- Undo a LEAVING that did not happen: net.serverTravelNow marks LEAVING as soon as the console SERVERTRAVEL returns,
-- but UWorld::ServerTravel may refuse silently (no feedback through ExecuteConsoleCommand). Only acts while the
-- same world (generation) and the same RacingGameState are current. The race phase is restored WITHOUT phase events
-- (only "leaving_cancelled"(phase), for split's single view):
-- "race_enter"/"phase" would re-run the race-entry listeners (split, gfx, join guard); the race ticks resume through
-- phase.isRace(), and hud/takeover/nametags rebuild what the "leaving" listeners released from their polls.
-- Returns true when the phase was restored.
function M.cancelLeaving(reason, worldGen)
  if St.phase ~= "LEAVING" then return false end
  if worldGen ~= nil and worldGen ~= St.worldGen then return false end
  if leavingGsKey == nil or leavingGsKey ~= St.gsKey then return false end
  local w = U.world()
  if not U.ok(w) then return false end
  leavingGsKey = nil
  local new = compute(w)
  if not RACE[new] then
    U.warn(TAG, "cancelLeaving(%s): the GameState no longer reads as a race (%s); LEAVING kept", tostring(reason),
      tostring(new))
    return false
  end
  U.warn(TAG, "leaving cancelled (%s): LEAVING -> %s without phase events", tostring(reason), new)
  St.phase = new
  St.phaseSinceMs = St.nowMs()
  -- Only for what a "leaving" listener changed and no poll rebuilds (split: the single view set on "leaving").
  St.emit("leaving_cancelled", new)
  return true
end

-- Runs phase.tick on the next frame (debounced). Used by the LoadMap / InitGameState hooks.
function M.refreshSoon()
  if refreshQueued then return end
  refreshQueued = true
  sched.nextFrame(TAG, function()
    refreshQueued = false
    M.tick()
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Detection (MAIN loop, game thread)
-- ---------------------------------------------------------------------------------------------

local finishedDisagreeGs = nil   -- GameState key for which the bIsRaceFinished/CSM disagreement was logged

local function racePhase(gs)
  -- VERIFY(V-DIAG-01): bIsRaceFinished / CSM_RF_PostRacePhase mark the results screen on every mode. The meaning of
  -- bIsRaceFinished is not established (all racers done, or the first local/human finisher?): when the CSM answers
  -- "post-race not active" at the same time, both values are logged once per GameState so the log decides.
  -- hud.updateVisibility (csm mode) trusts a resolvable CSM answer over this phase.
  if gs.bIsRaceFinished == true then
    local gk = U.key(gs)
    if finishedDisagreeGs ~= gk then
      local pst = U.csmActive("CSM_PostRace", true)
      if pst == false and U.csmLoaded("CSM_PostRace") then
        finishedDisagreeGs = gk
        U.warn(TAG, "V-DIAG-01: bIsRaceFinished=true while CSM_PostRace=false (phase POSTRACE from the flag)")
      end
    end
    return "POSTRACE"
  end
  if gs.bIsRaceStarted == true then
    -- The CSM term only once the race started (no results screen before), and find-only: a state asset that is not
    -- in memory cannot be active, and a LoadAsset here would block the game thread from the MAIN poll (LOADING).
    if U.csmActive("CSM_PostRace", true) == true then return "POSTRACE" end
    return "RACING"
  end
  -- a campaign CONTINUE saved in the post-event flow (EContinueRunState PostEvent) loads the race world straight into
  -- the results / rewards (IsLoadingSaveIntoPostEvent): the race never starts, CSM_PostRace is active. Without this
  -- the phase stayed PRERACE under the rewards and no POSTRACE module ran (no P2 reward area, live 2026-10-14).
  if U.csmActive("CSM_PostRace", true) == true then return "POSTRACE" end
  local vehicles = gs.Vehicles
  if U.arrayCount(vehicles) > 0 then return "PRERACE" end
  return "LOADING"
end

-- True on the seamless-travel transition map (full package path, short name as a second check).
local function isTransitionMap()
  local ok, p = U.try(TAG, U.currentMapPath)
  if not ok or type(p) ~= "string" or p == "" then return false end
  if p == TRANSITION_MAP then return true end
  return TRANSITION_SHORT ~= nil and p:match("([^/]+)$") == TRANSITION_SHORT
end

-- Returns the phase the current world/GameState indicates, plus the GameState (or nil).
compute = function(w)
  -- Transition world first: its GameState is the carried old one (see TRANSITION_MAP). No timeout runs here.
  -- VERIFY(V-DIAG-01): the transition world's GameState class/address is logged by onNewWorld.
  if isTransitionMap() then return "TRANSIT", nil end
  local gs = w.GameState
  if not U.ok(gs) then return "TRANSIT", nil end
  local gk = U.key(gs)
  if U.isA(gs, "FrontEndGameState") then
    if St.launch.pending then
      if launchAtMs ~= St.launch.atMs then
        -- First look at this launch: it starts in the current world with the current GameState.
        launchAtMs, launchWorldKey, launchGsKey = St.launch.atMs, U.key(w), gk
      end
      if U.key(w) ~= launchWorldKey then
        -- Another world: the launch's own FrontEndGameState carried along = travel under way (no timeout);
        -- a fresh FrontEndGameState = the launch came back to a front end, it is over.
        if gk == launchGsKey then return "LAUNCHING", gs end
        return "FRONTEND", gs
      end
      if (St.nowMs() - (St.launch.atMs or 0)) < launchLimitMs() then return "LAUNCHING", gs end
    end
    return "FRONTEND", gs
  end
  if U.isA(gs, "RacingGameState") then
    -- A RacingGameState we already left never re-enters a race phase (seamless carry-over, §5.1).
    if leavingGsKey ~= nil and gk == leavingGsKey then return "LEAVING", gs end
    return racePhase(gs), gs
  end
  return "OTHER", gs
end

local function onNewWorld(w, forced)
  -- Backup "leaving" detector (§5.3): no hook fired before the world changed.
  if M.isRace() then M.markLeaving("poll") end
  -- A launch that already produced a race is over once a new world follows the race.
  if St.phase == "LEAVING" or RACE[St.phase] then St.launch.pending = false end
  stats.worlds = stats.worlds + 1
  if forced then stats.forcedWorlds = stats.forcedWorlds + 1 end
  U.log(TAG, "world changed (#%d%s); hooks since the previous world: LoadMap pre=%d post=%d, InitGameState=%d",
    stats.worlds, forced and ", LoadMap" or "", sinceWorld.loadMapPre, sinceWorld.loadMapPost,
    sinceWorld.initGameState)
  sinceWorld.loadMapPre, sinceWorld.loadMapPost, sinceWorld.initGameState = 0, 0, 0

  -- VERIFY(V-DIAG-01): on L_SeamlessTravel the GameState should be the carried previous one (same address).
  if isTransitionMap() then
    stats.transitWorlds = stats.transitWorlds + 1
    local gsDesc = "none"
    U.try(TAG, function()
      local gs = w.GameState
      if U.ok(gs) then
        gsDesc = string.format("%s @%s%s", tostring(U.pathOf(gs:GetClass())), tostring(U.key(gs)),
          (leavingGsKey ~= nil and U.key(gs) == leavingGsKey) and " (the race just left)"
          or (launchGsKey ~= nil and U.key(gs) == launchGsKey) and " (the launching front end)" or "")
      end
    end)
    stats.lastTransitGs = gsDesc
    U.log(TAG, "seamless transition world, GameState = %s", gsDesc)
  end

  -- The left GameState may be carried into one following world only, and never across a LoadMap (hard travel
  -- destroys it; the new GameState may reuse its address).
  leavingWorlds = leavingWorlds + 1
  if forced or leavingWorlds > 1 then leavingGsKey = nil end
  -- Same rule for the launch's FrontEndGameState (a hard travel never carries it).
  if forced then launchGsKey = nil end

  St.worldKey = U.key(w)
  -- the generation changes even when the new UWorld sits at the old one's address (forced = LoadMap post-hook)
  St.worldGen = (St.worldGen or 0) + 1
  St.gsKey = 0
  St.resetRace()
  St.emit("world", w)
end

local function tickInner()
  -- couch-fix60: the fresh world (U.world's RACING cache could hand out the old, not yet purged, race world)
  local w = U.worldFresh()
  if not U.ok(w) then return "no world" end
  local wk = U.key(w)
  if wk ~= St.worldKey or forceNewWorld then
    local forced = forceNewWorld
    forceNewWorld = false
    onNewWorld(w, forced)
  else
    -- Backup for a missed (or unavailable) LoadMap post-hook: a hard travel can put the new UWorld at the old one's
    -- address, but its GameState is new. One world never swaps one live GameState for another (a carried seamless
    -- GameState keeps its address; the transition world reads gs = nil; a client going 0 -> GameState is excluded),
    -- so a different non-zero GameState in the "same" world means a new world.
    -- VERIFY(V-DIAG-01): a "GameState replaced in place" line appears only after a hard travel (stats.gsWorlds).
    local okG, g = pcall(U.getField, w, "GameState")
    local gk0 = (okG and U.ok(g)) and U.key(g) or 0
    if gk0 ~= 0 and St.gsKey ~= 0 and gk0 ~= St.gsKey and not isTransitionMap() then
      stats.gsWorlds = stats.gsWorlds + 1
      U.warn(TAG, "GameState replaced in place (world address %s reused, no LoadMap hook seen): new world",
        tostring(wk))
      onNewWorld(w, true)
    end
  end

  local new, gs = compute(w)
  local gk = gs and U.key(gs) or 0

  if gk ~= St.gsKey then
    -- Same world, other (or no) GameState: a client that lost the race GameState (disconnect, travel) or
    -- a GameState swap leaves the race.
    if M.isRace() and not RACE[new] then M.markLeaving(gs and "gamestate" or "gamestate-lost") end
    St.gsKey = gk
    if gk ~= 0 and leavingGsKey ~= nil and leavingGsKey ~= gk then leavingGsKey = nil end
  elseif RANK[St.phase] and RANK[new] and RANK[new] < RANK[St.phase] then
    -- Never backwards inside one RacingGameState (LEAVING stays until the world/GameState changes).
    return
  end

  if new == St.phase then return end

  -- LAUNCHING -> FRONTEND on the same front-end GameState = the launch timed out.
  if St.phase == "LAUNCHING" and new == "FRONTEND" and St.launch.pending then
    local limit = launchLimitMs()
    St.launch.pending = false
    St.launch.accepted = false
    -- the launch is over: an unrelated later menu instance must not jump to our tab (launch.start set it)
    St.ui.returnToTab = false
    St.emit("status", "LAUNCH TIMED OUT")
    U.warn(TAG, "launch did not leave the front end within %d ms", limit)
  end

  -- Race start edge (also when the first race poll already sees it running / finished).
  if (new == "RACING" or new == "POSTRACE") and not St.race.started then
    St.race.started = true
    St.race.startedAtMs = St.nowMs()
    U.log(TAG, "race started at %.0f ms", St.race.startedAtMs)
  end
  if new == "LOADING" or new == "PRERACE" then
    local ok, p = U.try(TAG, U.currentMapPath)
    if ok and p then St.race.mapPath = p end
  end

  setPhase(new)
end

-- Still BOOT this long after load with a world present = detection is stuck (hot reload report, run E): logged once
-- with what compute() sees, then retried every tick as usual.
local bootSinceMs = nil
local bootWarned = false
local function bootWatch(why)
  if St.phase ~= "BOOT" then bootSinceMs = nil; return end
  local now = St.nowMs()
  bootSinceMs = bootSinceMs or now
  -- a cold start has no world for a while (intro / loading): only a world that is there but not classified is quick news
  local limit = (why == "no world") and 20000 or (tonumber(cfg.PhaseBootWarnMs) or 3000)
  if bootWarned or now - bootSinceMs < limit then return end
  bootWarned = true
  local desc = tostring(why or "")
  U.try(TAG, function()
    local w = U.world()
    local gs = U.ok(w) and w.GameState or nil
    desc = string.format("%s; world=%s gs=%s worldKey=%s gsKey=%s localPlayers=%d map=%s", desc, tostring(U.ok(w)),
      U.ok(gs) and U.pathOf(gs:GetClass()) or "nil", tostring(St.worldKey), tostring(St.gsKey), #U.localPlayers(),
      tostring(U.levelName()))
  end)
  U.warn(TAG, "phase still BOOT %.0f ms after load (%s); V-CORE-14", now - bootSinceMs, desc)
end

-- couch-fix60 (AUTO-146, crash_2026_10_18_21_32_31 + 22_25_08, live round 5, 2/2: pause > EXIT TO MAIN MENU > ACCEPT on
-- the grid of a boss / head-to-head instances race). The game leaves a race by a SILENT seamless travel: every
-- "leaving the race" of round 5 says "(poll)", no OnSeamlessTravelStarted / RequestReturnToMenus / LoadMap hook fires.
-- The race world's pawns and AI PlayerStates are collected at the switch, but the race was only left at the next MAIN
-- poll (up to 250 ms later); FAST ticks in between ran every race module on the dead race (instances' boss pacing read
-- `p.PlayerState` of a freed pawn: UE4SS.dll+0x406099 in UStruct::FindProperty under the member __index, FName
-- 0x1E0DB = PlayerState in both dumps). THIS, first thing of every FAST tick in a race phase: the current world
-- against St.worldKey; a different (or no) world = the phase poll runs NOW (leaving -> "leaving" listeners -> new
-- world generation) before any race module. -> true when the race modules must not run this tick.
local fastGoneGen = nil
function M.fastWorldCheck()
  if not M.isRace() then return false end
  local w = U.worldFresh()
  local wk = U.key(w)
  if wk ~= 0 and wk == St.worldKey and not forceNewWorld then return false end
  stats.fastWorldChecks = (stats.fastWorldChecks or 0) + 1
  if fastGoneGen ~= St.worldGen then
    fastGoneGen = St.worldGen
    U.log(TAG, "the race world is gone under the FAST loop (world %s -> %s, phase %s): phase poll now, before any race "
      .. "module (AUTO-146)", tostring(St.worldKey), tostring(wk), tostring(St.phase))
  end
  if wk ~= 0 then M.tick() end
  return true
end

function M.tick()
  local ok, why = U.try(TAG, tickInner)
  if St.phase == "BOOT" then bootWatch(ok and why or "tick error") end
  if RACE[St.phase] or St.phase == "OTHER" or photo.last then U.try(TAG, photoEdge) end
end

--- Detect the phase now (hot reload: the new Lua state starts at BOOT while a race may be running).
function M.redetect(reason)
  U.log(TAG, "re-detecting the phase from the live world (%s)", tostring(reason))
  M.tick()
end

-- ---------------------------------------------------------------------------------------------
-- Hooks (registered at boot; never call UFunctions here)
-- ---------------------------------------------------------------------------------------------

-- Engine-level hook registrars exist in this UE4SS build [API§1, §4]; they need [Hooks] HookLoadMap /
-- HookInitGameState = 1 (shipped defaults). Registration is guarded so a disabled hook only logs.
local function registerEngineHook(name, fn)
  local reg = _G[name]
  if type(reg) ~= "function" then
    U.warn(TAG, "%s is not available in this UE4SS build; MAIN poll only", name)
    return false
  end
  local ok, err = pcall(reg, fn)
  if not ok then
    U.warn(TAG, "%s failed: %s (MAIN poll only)", name, tostring(err))
    return false
  end
  return true
end

function M.init()
  -- LoadMap pre: (Engine, World, URL, PendingGame, Error). URL is an opaque FURL [HERE] and is not read.
  -- The callback must return nil (a bool would become LoadMap's return value [HERE LuaMod.cpp:6450]).
  registerEngineHook("RegisterLoadMapPreHook", function(Engine, World)
    U.try(TAG, function()
      stats.loadMapPre = stats.loadMapPre + 1
      sinceWorld.loadMapPre = sinceWorld.loadMapPre + 1
      U.dbg(TAG, "LoadMap pre (phase %s)", St.phase)
      if M.isRace() then M.markLeaving("loadmap") end
    end)
    return nil
  end)

  registerEngineHook("RegisterLoadMapPostHook", function(Engine, World)
    U.try(TAG, function()
      stats.loadMapPost = stats.loadMapPost + 1
      sinceWorld.loadMapPost = sinceWorld.loadMapPost + 1
      U.dbg(TAG, "LoadMap post")
      -- A LoadMap always yields a new world, whatever its address (UWorld/GameState address reuse).
      forceNewWorld = true
      M.refreshSoon()
    end)
    return nil
  end)

  -- InitGameState post: the param is the AGameModeBase, not the GameState [API§4]. Server/standalone only.
  registerEngineHook("RegisterInitGameStatePostHook", function(GameMode)
    U.try(TAG, function()
      stats.initGameState = stats.initGameState + 1
      sinceWorld.initGameState = sinceWorld.initGameState + 1
      M.refreshSoon()
    end)
  end)

  -- ARacingGameState::OnSeamlessTravelStarted(UWorld* currentWorld, FString newMapUrl), flags 0x40401
  -- (Native, not BlueprintCallable): bound to a delegate, so it reaches the hook only when the delegate is
  -- dispatched through ProcessEvent.
  -- VERIFY(V-CORE-10): the pre-hook fires before a seamless travel out of a race; fallback = MAIN poll.
  U.hook(C.FN.SeamlessTravelStarted, { pre = function(ctx, currentWorld, newMapUrl)
    stats.seamless = stats.seamless + 1
    local url = ""
    U.try(TAG, function() url = U.str(newMapUrl:get()) end)
    U.log(TAG, "OnSeamlessTravelStarted -> %s", url)
    M.markLeaving("seamless")
  end }, TAG)

  -- ARacingGameMode::RequestReturnToMenus(), BlueprintCallable native, no params (server/standalone).
  -- VERIFY(V-CORE-10): fires when the results/pause menu returns to the front end.
  U.hook(C.FN.RequestReturnToMenus, { pre = function(ctx)
    stats.returnToMenus = stats.returnToMenus + 1
    M.markLeaving("return")
  end }, TAG)

  -- A (hot) reload starts at BOOT: detect on the next frame (after every module's init registered its listeners)
  -- from the live world instead of waiting for the first MAIN tick; the MAIN tick keeps retrying (bootWatch reports
  -- a world that stays unclassified).
  sched.nextFrame(TAG .. ".boot", function() M.redetect("load") end)
  U.dbg(TAG, "init done")
end

return M
