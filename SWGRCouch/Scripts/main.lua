-- SWGRCouch · main.lua (G2 Wiring & lifecycle)
-- Local split-screen (SPLIT SCREEN main-menu tab, 1-4 pads) and self-hosted network races for
-- STAR WARS: Galactic Racer. Boot order, module init order, the FAST/MAIN/SLOW loops with their fixed
-- tick order, and unload (ARCHITECTURE.md §4.2 main). No game logic of its own.
--
-- This file runs on the UE4SS mod-start thread (not the game thread): nothing here calls a UFunction.
-- Game work starts only through sched (LoopInGameThreadWithDelay / ExecuteInGameThread with an explicit
-- EGameThreadMethod) [API§2].
--
-- Debug keys (keys.lua): F5 tab · F6 join · F7 leave · F8 2P layout · F9 diag · Ctrl+F5 launch ·
-- Ctrl+F6 takeover · Ctrl+F7 host · Ctrl+F8 connect · Ctrl+F9 net dump · Ctrl+F11 restart mod.
-- Console (ConsoleEnablerMod): couch help.

-- 1. Group 1 first (plain require: nothing works without them), then every other module.
local C = require("consts")
local cfg = require("config")
local settings = require("settings")
local St = require("state")
local U = require("util")
local sched = require("sched")

local TAG = "main"

-- Every other module is required through pcall so one broken file does not take the whole mod down;
-- a missing module only disables its own calls (logged once).
-- 0.4.0 (2026-10-07 integration of the session-B feedback): inputfix (per-player input isolation), present (one
-- full-screen view for intro/cinematics/results, per-player ignition screens), vehicles + setup (RACE SETUP flow:
-- class -> planet -> track -> mode -> per-player vehicles, full AI grid). setup/vehicles have no init (lobby builds
-- the setup page); they are listed so a load error shows at boot.
-- 0.5.0 (2026-10-07 integration of run E): ignition + ignpad (per-player pre-flight checks with each player's own pad,
-- pad prompts; present.lua ticks them, no init) are listed so a load error shows at boot. Photo mode: phase.photoMode()
-- is the shared detector (hud/pause/inputfix/ignition back off; wreck.lua keeps its own cached copy).
-- 0.5.1 (2026-10-07 integration of run F): crashcam (a guest's CRASH view: black -> own car, fades, emulated slow-mo;
-- FAST right after wreck, persisted for hot reload).
-- 0.7.0 (2026-10-07, run H "the ux were sharing perfect landing and danger"): uxsplit (per-player race messages, index
-- remap of the guest HUDs' BotEngineInfo, per-player danger visuals). Its init runs at boot BEFORE hud's (listeners
-- first); its native hooks exist only while a split race runs (armed by its own ticks or by hud.lua right before a HUD
-- is created, removed at POSTRACE / leaving). FAST after viewguard, MAIN right after hud.tick.
-- 0.7.2 (run I: radio chatter for one player was drawn in P2's half): subsplit (each subtitle line in its player's
-- half; lines for everybody copied into a guest-owned clone). Same hook rules as uxsplit (hooks only while a split race
-- runs); init right after uxsplit's, FAST / MAIN right after uxsplit's ticks, persisted for hot reload (its clones).
-- 0.8.0 (integration of the 0.7.2 work): vpreview (3D render of each RACE SETUP vehicle pick, front end only) is listed
-- right after setup so a load error shows at boot (setup requires it itself and ticks it from its FAST pollNav; no init,
-- no loop of its own) and persisted for hot reload (its photo-bay actors are destroyed by the next Lua state).
-- 0.10.0 RACERS step (notes/design/vehicle-step-v2.md): pilots (pilot table), perkdata (generated perk catalog, pure
-- data), perks (pure loadout logic), perkapply (launch writes: base-build patch, pilots, loadouts, PRERACE traits),
-- cards (card widgets) and racers (the step's per-player state machines) are listed right after cmap so a load error
-- shows at boot. No init, no loop of their own: setup.lua reaches racers / cards / perkapply lazily and ticks racers
-- from its FAST pollNav; launch.raceTick ticks perkapply. perkapply is persisted for hot reload (the in-memory
-- base-build patch record: the next Lua state restores the asset by path).
-- 0.11.0 RESTART RACE (notes/research/restart-race.md): restart (the pause menu's RESTART RACE entry: pause.lua hands it
-- every WBP_PauseRacing_C; its RequestRestartEvent hook exists only while an eligible race is RACING). Init after
-- menubridge, FAST right after menubridge's tick, persisted for hot reload (the cleared LastPlayedArcadeEvent's path).
-- 0.12.0 UI v2 (notes/design/ui-v2/ui-redesign-final.md §3, §9, §12): theme (tokens + the shared chrome builders of the
-- lobby, OPTIONS, RACE SETUP and cmap; its "menu" / "phase" listeners drop the page's widgets) is listed right after ui,
-- cards2 (the v2 RACERS cards, cards.lua's API) right after cards, so a load error shows at boot like cards / cmap. No
-- init, no loop of their own: lobby / setup / cmap / racers reach them lazily (U.mod) and tick them from their polls.
local MODULES = { "phase", "fastboot", "ui", "theme", "menu_tab", "lobby", "join", "split", "vehicles", "setup", "vpreview",
                  "cmap", "pilots", "perkdata", "perks", "perkapply", "cards", "cards2", "racers",
                  "builder", "launch", "inputfix", "hud", "uxsplit", "subsplit", "present", "ignition", "ignpad", "wreck",
                  "crashcam", "nametags", "gfx", "pause",
                  "roster", "takeover", "net", "netfix", "diag", "keyq", "keys", "testcmd", "viewguard", "menubridge",
                  "restart", "feowner", "backprompt" }
local mods = {}
for _, name in ipairs(MODULES) do
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then
    mods[name] = m
  else
    U.err(TAG, "module %s failed to load: %s", name, tostring(m))
  end
end

local missingFn = {}

-- Calls mods[name][fnName](...) inside its own error guard (tag = module name). Returns the U.try results.
-- U.tryEvery, not U.try: the loop ticks below run every 33/250 ms, and a persistent fault must log its traceback
-- once, then at most one line per cfg.LoopErrorLogEveryMs (sched.every's own throttle never sees these errors).
local function call(name, fnName, ...)
  local m = mods[name]
  if not m then return false end
  local f = m[fnName]
  if type(f) ~= "function" then
    local k = name .. "." .. fnName
    if not missingFn[k] then
      missingFn[k] = true
      U.warn(TAG, "%s() is not implemented; skipped", k)
    end
    return false
  end
  return U.tryEvery(name .. "." .. fnName, nil, name, f, ...)
end

local phase = mods.phase
local function isFrontEnd() return phase ~= nil and phase.isFrontEnd() end
local function isRace() return phase ~= nil and phase.isRace() end

-- 2. Settings and banner.
do
  local ok, loaded = U.try(TAG, settings.load)
  local unreal = "?"
  pcall(function()
    if UnrealVersion then unreal = string.format("%d.%d", UnrealVersion.GetMajor(), UnrealVersion.GetMinor()) end
  end)
  local gtName = "?"
  if type(sched.methodName) == "function" then
    local okName, n = pcall(sched.methodName)
    if okName then gtName = tostring(n) end
  elseif EGameThreadMethod then
    gtName = (sched.GT == EGameThreadMethod.EngineTick) and "EngineTick" or "ProcessEvent"
  end
  -- VERIFY(V-CORE-01): EngineTickAvailable=true on this Denuvo 5.7 build; otherwise GT=ProcessEvent.
  U.log(TAG, "%s %s loading: EngineTickAvailable=%s ProcessEventAvailable=%s GT=%s UE=%s settings=%s (%s)",
    C.MOD, C.VERSION, tostring(EngineTickAvailable), tostring(ProcessEventAvailable), gtName, unreal,
    tostring(settings.path()), (ok and loaded) and "loaded" or "defaults")
end

-- 3. Module init() calls, fixed order (§4.2 main). init() only registers hooks / NotifyOnNewObject /
--    event listeners; native /Script/ hooks register now, Blueprint hooks are queued by U.hook and retried
--    in the SLOW loop.
--    DEVIATION (documented): gfx.init() is not in the §4.2 list but gfx.lua's contract gives it an init()
--    that registers its phase listeners (LOADING -> applyForViews, FRONTEND -> restore); it runs right after
--    hud.init() (gfx.init is idempotent). Modules whose contract has no init() (lobby, launch, nametags) are
--    initialised only if their file defines one, just before keys.init().
--    fastboot (NO-INTRO mode, 2026-10-07) runs right after phase: its init() touches no UObject, registers a "world"
--    listener and arms its own game-thread loop (sched.every "fastboot", cfg.FastBootPollMs) before the first LoadMap;
--    the loop cancels itself at the main menu (+ grace), on a non-front-end map or after cfg.FastBootWindowMs.
--    BLUEPRINT HOOKS DO NOT FIRE in this build (first live run 2026-10-06): every module's BP hook is an optional
--    extra; the polls below (tab poll + builder.poll in MAIN, click/pad-nav poll in FAST, pause poll, HUD lap poll)
--    are the required paths. Native /Script/ hooks register normally.
--    inputfix (0.4.0): listeners, two optional native hooks and its own sched.every loop; touches no UObject in init.
--    present (0.4.0): listeners only (cfg.PresentFromMain = true; with false hud.lua initialises and ticks it).
--    wreck (2026-10-07): listeners only ("leaving" / FRONTEND give the cvars back); its custom property is registered
--    lazily on the game thread (first armed race timeout), never here.
local INIT_ORDER = { "phase", "fastboot", "menu_tab", "ui", "join", "builder", "roster", "takeover", "inputfix",
                     "uxsplit", "subsplit", "hud", "present", "wreck", "crashcam", "gfx", "pause", "net", "netfix", "diag",
                     "testcmd", "viewguard", "menubridge", "restart", "feowner" }
for _, name in ipairs(INIT_ORDER) do
  if name ~= "present" or cfg.PresentFromMain == true then call(name, "init") end
end
for _, name in ipairs({ "lobby", "launch", "nametags" }) do
  if mods[name] and type(mods[name].init) == "function" then call(name, "init") end
end

-- nametags.clear ("leaving") and launch.restoreGridPatch (phase -> FRONTEND) are registered by those
-- modules themselves (at require time / when a grid patch is made); main adds no listener of its own.

call("keys", "init")

-- 3b. Hot reload (Ctrl+F11 / couch reload): what the previous Lua state left in the game is described by UE4SS
--     shared variables written in OnUnload (§6 below). Modules read their part back here (Lua state only, no game
--     call); the game-side leftovers are adopted or removed by the modules on the game thread (menu_tab stale pages,
--     hud orphan HUDs, takeover records re-found by address, gfx values restored in the front end).
--     VERIFY(V-CORE-11): after Ctrl+F11 mid-race and in the menu, the log shows the restored values and no
--     duplicate page/HUD; cvars are restored in the next front end.
local SHARED_PREFIX = C.MOD .. "."
local PERSIST_MODULES = { "join", "net", "gfx", "takeover", "launch", "inputfix", "wreck", "crashcam", "subsplit",
                          "vpreview", "perkapply", "restart" }

local function sharedPut(name, v)
  local ok, err = pcall(function() ModRef:SetSharedVariable(SHARED_PREFIX .. name, v) end)
  if not ok then print("[" .. C.MOD .. "][main] WARN SetSharedVariable(" .. name .. "): " .. tostring(err) .. "\n") end
end

local function sharedGet(name)
  local ok, v = pcall(function() return ModRef:GetSharedVariable(SHARED_PREFIX .. name) end)
  if ok then return v end
  return nil
end

do
  if sharedGet("persisted") == true then
    sharedPut("persisted", false)        -- read once: a later reload writes a fresh set in its OnUnload
    for _, name in ipairs(PERSIST_MODULES) do
      if mods[name] and type(mods[name].restoreShared) == "function" then call(name, "restoreShared", sharedGet) end
    end
    if sharedGet("ui.tabOpen") == true or sharedGet("ui.returnToTab") == true then St.ui.returnToTab = true end
    if sharedGet("race.launchedByUs") == true then St.race.launchedByUs = true end
    U.log(TAG, "hot reload: state of the previous instance restored (returnToTab=%s, launchedByUs=%s)",
      tostring(St.ui.returnToTab), tostring(St.race.launchedByUs))
  end
end

-- 4. CDO writes (GameMapsSettings) on the game thread. The Iris cvar is applied by netfix on the first
--    "world" event.
sched.run("boot", function() call("split", "init") end)

-- ---------------------------------------------------------------------------------------------
-- 5. Loops: FAST (33 ms), MAIN (250 ms), SLOW (1 s), all on the game thread through sched.every.
-- ---------------------------------------------------------------------------------------------

-- VERIFY(V-CORE-02): FAST loop period ~cfg.FastPollMs; measured during the first 5 s and logged once
-- (St.nowMs() is real time from the first loop tick on: state.lua REAL CLOCK, V-CORE-13).
local timing = { first = nil, last = nil, n = 0, sum = 0, min = math.huge, max = 0, done = not cfg.Debug }
local function measureFast()
  if timing.done then return end
  local now = St.nowMs()
  if timing.first == nil then timing.first, timing.last = now, now; return end
  local d = now - timing.last
  timing.last = now
  timing.n, timing.sum = timing.n + 1, timing.sum + d
  if d < timing.min then timing.min = d end
  if d > timing.max then timing.max = d end
  if now - timing.first >= 5000 then
    timing.done = true
    local ci = St.clockInfo and St.clockInfo() or {}
    U.log(TAG, "FAST loop timing over %d ticks: avg=%.1f min=%.1f max=%.1f ms (target %d); clock %s, os.clock x%.2f",
      timing.n, timing.sum / math.max(timing.n, 1), timing.min, timing.max, cfg.FastPollMs, tostring(ci.source),
      1 / (tonumber(ci.rate) or 1))
  end
end

-- 0.12.0 launch hold (state.lua St.launchHold): the front end is being torn down; its pages, the main menu's objects
-- and the theme's widgets are not touched until the race world (phase.tick keeps running: it ends the hold).
local holdSeen = nil
local function frontHeld()
  if not St.launchHold() then return false end
  if holdSeen ~= St.launch.atMs then
    holdSeen = St.launch.atMs
    U.log(TAG, "launch hold: the front-end pages stop until the race world (V-LCH-07)")
  end
  return true
end

local function fastTick()
  -- 0.10.0: keyboard presses queued by keyq's event-loop callbacks run here, on the game thread, in every phase
  U.try(TAG, mods.keyq and mods.keyq.drain or function() end)
  measureFast()
  if St.join.active then call("join", "poll") end
  -- every ClickMode: ui.pollClicks runs the lobby's pad/keyboard navigation (cfg.LobbyPadNav) and, in ClickMode
  -- "poll" (default: BP_OnClicked never fires in this build), the selected-toggle click detection
  if St.menu.visible and not frontHeld() then call("ui", "pollClicks") end
  -- 0.12.0: P1's B on OPTIONS / RACE SETUP reaches only the game (its QuitGame prompt): answered No + the page's back
  call("backprompt", "fastTick")
  -- guests (GuestPauseMode "poll", or "hud" + GuestPauseFallback) and P1 while its HUD is re-hosted (P1PausePoll);
  -- pause.poll decides who. 0.7.0: it also runs the split-race pause layers A-G (HUD input guard, request hook arming,
  -- pre-created screen, guests' IMC_UI, focus, safety net, after-wreck restart). It must stay FIRST in this block:
  -- uxsplit.fastTick reads this tick's pause state from it (St.pause.menuWasPaused, full-screen effects override).
  if isRace() then
    call("pause", "poll")
    -- 0.7.1 (run I): guest-owned menus and shared post-race screens take A/B through a click bridge (after pause.poll:
    -- it reads this tick's St.pause.menuWasPaused)
    call("menubridge", "fastTick")
    -- 0.11.0: RESTART RACE (placed by pause.lua's calls): hook arming, the re-check of the row, the confirmed request ->
    -- RequestResetRace; after menubridge (a bridged Accept on the confirm dialog lands in this tick's pause state)
    call("restart", "fastTick")
    call("inputfix", "bindPoll")   -- a car re-pointed by the game is re-bound within one FAST tick
    call("inputfix", "p1UiGuard")  -- 0.9.0: P1's vehicle IMC over IMC_UI while racing (LB / R3), released at once on pause
    if cfg.PresentFromMain == true then call("present", "fastTick") end   -- ignition: ignpad pad poll + replay (0.5.1)
    -- the game ends an offline race 2 s after the first human finish/wreck: the guard must see the armed timeout well
    -- inside that window; also no-wreck top-ups, slow-mo, the wrecked players' spectate/view guard
    call("wreck", "fastTick")
    -- 0.5.1: a local human's crash (not a wreck): guest crash view, fades, emulated slow-mo (wreck.lua owns wrecks)
    call("crashcam", "fastTick")
    call("viewguard", "fastTick")
    -- 0.7.0: hidden message copies kept hidden, waiting copies matched, per-player danger tints / fades (~100 ms)
    call("uxsplit", "fastTick")
    -- 0.7.2: subtitle line poll (fallback of its config hook), line end -> clones idle, clone visibility; after pause.poll
    -- (it reads this tick's St.pause.menuWasPaused to hold its waiting requests while paused)
    call("subsplit", "fastTick")
  end
end

local function mainTick()
  call("phase", "tick")
  if isFrontEnd() then
    local held = frontHeld()       -- 0.12.0: nothing of the dying front end during the launch hold
    if not held then call("lobby", "tick") end
    call("net", "tick")
    -- always in this build (menu_tab.pollWanted() == true: the CustomEvent hook never fires); also drives
    -- builder.poll() (Go / live pick capture)
    local mt = mods.menu_tab
    if not held and mt and (type(mt.pollWanted) ~= "function" or mt.pollWanted()) then call("menu_tab", "pollTab") end
    if not held then
      -- guests get their own names already in the menu (feedback 5; 1 s throttle inside, cheap without guests)
      call("nametags", "namesTick")
      call("feowner", "mainTick")  -- 0.10.0: Multiplayer tab hidden while split-screen guests exist (V-FEO-07)
    end
  elseif isRace() then
    call("roster", "tick")
    call("launch", "raceTick")     -- LOADING: per-player vehicle override retries (cheap no-op otherwise)
    call("takeover", "tick")
    call("inputfix", "tick")       -- also polled by its own loop (cfg.InputFixOwnLoopMs); de-duplicated inside
    -- wreck before present/hud: this tick's HUD already knows the timeout fallback (Remaining line) state
    call("wreck", "tick")          -- backup of the FAST timeout guard (8 MAIN ticks inside the 2 s window)
    -- present first: this tick's HUD visibility already knows whether the race runs on one view
    if cfg.PresentFromMain == true then call("present", "tick") end
    call("hud", "tick")
    call("uxsplit", "tick")        -- 0.7.0: arm/disarm backup, this tick's HUD list, 1 s copy scan, MPC pin, probe
    call("subsplit", "tick")       -- 0.7.2: arm (once the subtitle widget exists) / disarm, players, layout, clones, probe
    call("nametags", "tick")
    call("net", "tick")
    if U.isServer() then call("join", "raceTick") end
  end
end

local function slowTick()
  U.try(TAG, U.checkThreadAnchor)  -- 0.10.0 V-CORE-12: log when UE4SS drops its anchor of the shared hook thread
  U.try(TAG, U.retryPendingHooks)
  if isFrontEnd() and not frontHeld() then call("menu_tab", "ensure") end
  call("net", "slowTick")
  if isRace() then call("takeover", "finishIdlePlayerStates") end
  -- every mode: "hook" runs it as an edge-only watchdog for a silent device hook (join.pollDevices decides)
  call("join", "pollDevices")
  if not frontHeld() then
    call("join", "hotplugTick")    -- 0.8.1: a hot-plugged pad takes P1 (deferred from a race to the next front end)
  end
  call("diag", "periodic")
end

local FAST = sched.every("fast", cfg.FastPollMs, fastTick)
local MAIN = sched.every("main", cfg.MainPollMs, mainTick)
local SLOW = sched.every("slow", cfg.SlowPollMs, slowTick)

-- ---------------------------------------------------------------------------------------------
-- 6. Unload (RestartCurrentMod / uninstall): cancel our delayed actions and hooks [API§12], then describe what
--    stays in the game for the next instance (shared variables survive the reload [API§12]). OnUnload does not run
--    on the game thread: no UObject is touched here (Lua values and pre-taken addresses only).
-- ---------------------------------------------------------------------------------------------
local okUnload, errUnload = pcall(function()
  ModRef.OnUnload = function()
    pcall(sched.cancelAll)
    -- No U.unhookAll here: UnregisterHook calls StaticFindObject, and OnUnload does not run on the game thread
    -- (a GC in progress would be a Fatal). LuaMod::uninstall unhooks every hook of this mod by itself right after
    -- OnUnload (UE4SS LuaMod.cpp, uninstall: "Unhook all UFunctions for this mod BEFORE closing Lua state").
    pcall(function()
      for _, name in ipairs(PERSIST_MODULES) do
        local m = mods[name]
        if m and type(m.persistShared) == "function" then
          local ok, err = pcall(m.persistShared, sharedPut)
          if not ok then print("[" .. C.MOD .. "][main] WARN " .. name .. ".persistShared: " .. tostring(err) .. "\n") end
        end
      end
      sharedPut("ui.tabOpen", St.menu.visible ~= nil)
      -- a pending return chain (menu_tab turned returnToTab into returnPending) is a return still to do
      local chain = false
      local mt = mods.menu_tab
      if mt and type(mt.returnPending) == "function" then
        local okR, r = pcall(mt.returnPending)
        chain = okR and r == true
      end
      sharedPut("ui.returnToTab", St.ui.returnToTab == true or chain)
      sharedPut("race.launchedByUs", St.race.launchedByUs == true)
      sharedPut("persisted", true)
    end)
    print("[" .. C.MOD .. "][" .. TAG .. "] unloaded\n")
  end
end)
if not okUnload then U.warn(TAG, "ModRef.OnUnload not settable: %s", tostring(errUnload)) end

U.log(TAG, "started: loops fast=%s main=%s slow=%s (%d/%d/%d ms), modules=%d/%d, phase=%s", tostring(FAST),
  tostring(MAIN), tostring(SLOW), cfg.FastPollMs, cfg.MainPollMs, cfg.SlowPollMs,
  (function() local n = 0; for _ in pairs(mods) do n = n + 1 end; return n end)(), #MODULES, St.phase)
