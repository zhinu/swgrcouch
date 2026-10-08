-- SWGRCouch · diag.lua (G2 Wiring & lifecycle)
-- Human-readable dumps that answer the runtime questions of ARCHITECTURE.md §6, plus debug-only hooks.
-- Read-only: nothing here changes game state (the only UFunctions called are const/pure getters).
--
-- Reflected data used (scripts/reflect-types.py / reflect-func-all.py on the shipping exe):
--   ARacingGameState.Racers Array<Object<AGfnPlayerState>>, .Vehicles Array<Object<AVehiclePawn>>,
--     .bIsRaceStarted/.bIsRaceFinished Bool, .LapCount Int, .EventRecipeState_Replication Struct<EventRecipeState>
--   ARacingGameState:FindRacerIndexByPlayer(Object<AGfnPlayerState> player) -> Int        (const pure)
--   AGfnPlayerState.RaceEventComponent Object<UPlayerRaceEventComponent>; APlayerState.bIsABot Bool,
--     .PawnPrivate Object<APawn>, :GetPlayerName() -> Str
--   UPlayerRaceEventComponent.EventPosition Int, .CurrentLapNumber Int, .bHasFinishedEvent Bool
--   AVehiclePawn:GetCurrentInputSource() -> Enum, :GetOriginalInputSource() -> Enum,
--     :GetInputSourceOverrides() -> Array<Enum<EVehicleInputSourceOverrideReason>>   (array return)
--   UEventRecipeSubsystem.ActiveRecipe Object<UEventRecipeInstance>; UEventRecipeInstance.Recipe
--     Struct<EventRecipe>{EventStages Array<Struct<RaceEventInstance>>}, .RecipeState Struct<EventRecipeState>
--     {ActiveStage Int, Racers Array<Struct<RecipeRacerSetup>{Player, Pilot, VehicleType Enum}>}
--   RaceEventInstance{PlayerFacingName Text, InternalName Str, TrackDef Object, LapCount Byte,
--     RaceEventModeType Enum, GameModeVariant Object}
--   UGameMapsSettings.bUseSplitscreen Bool, TwoPlayerSplitscreenLayout Byte, ThreePlayerSplitscreenLayout Byte,
--     FourPlayerSplitscreenLayout Enum, bOffsetPlayerGamepadIds Bool
--   UGfnGameInstance.PrimaryFlow Enum<EGfnPrimaryFlow>; UGfnUserSettings.TakedownCameras Bool
--   KismetSystemLibrary:IsValid(Object Object) -> Bool (static)

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local UEHelpers = require("UEHelpers")

local M = {}
local TAG = "diag"

-- ---------------------------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------------------------

local function out(fmt, ...) U.log(TAG, fmt, ...) end

-- "Class:Name" for a UObject, "nil" otherwise.
local function nm(o)
  if not U.ok(o) then return "nil" end
  local ok, s = pcall(function() return o:GetClass():GetFName():ToString() .. ":" .. o:GetFName():ToString() end)
  return ok and s or "?"
end

local function b(v) return tostring(v) end

local function enumName(tbl, v)
  if v == nil then return "nil" end
  local ok, s = pcall(C.enumName, tbl, v)
  if ok and s and s ~= "" then return string.format("%s(%s)", s, tostring(v)) end
  return tostring(v)
end

-- Runs one independent block; a failure is logged and the dump continues.
local function section(name, fn)
  local ok = U.try(TAG, fn)
  if not ok then out("  <%s failed, see the error above>", name) end
end

local function overridesText(car)
  local list = U.arrayToTable(car:GetInputSourceOverrides()) -- VERIFY(V-CORE-08): TArray<enum> return marshalling
  local parts = {}
  for i = 1, #list do parts[#parts + 1] = enumName(C.E.Override, list[i]) end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function isRacingGS(gs) return U.ok(gs) and U.isA(gs, "RacingGameState") end

-- ---------------------------------------------------------------------------------------------
-- Dump sections
-- ---------------------------------------------------------------------------------------------

local function dumpCore()
  local w = U.world()
  local phase = U.mod("phase")
  out("phase=%s since=%.0fms map=%s netMode=%s world=%s", St.phase, St.nowMs() - (St.phaseSinceMs or 0),
    tostring(U.levelName()), tostring(U.netMode()), nm(w))
  local st = phase.stats and phase.stats() or {}
  out("hooks fired: LoadMap pre=%s post=%s InitGameState=%s Seamless=%s ReturnToMenus=%s worlds=%s lastLeave=%s",
    b(st.loadMapPre), b(st.loadMapPost), b(st.initGameState), b(st.seamless), b(st.returnToMenus),
    b(st.worlds), b(st.lastLeaveReason))
  -- VERIFY(V-DIAG-01): transition worlds (L_SeamlessTravel) seen and the GameState found in the last one.
  out("worlds forced by LoadMap=%s transition worlds=%s last transition GameState=%s",
    b(st.forcedWorlds), b(st.transitWorlds), b(st.lastTransitGs))
  local gi = U.gi()
  -- VERIFY(V-CORE-04): GI class BP_GfnGameInstance_C, world L_FrontEnd in the menu.
  out("GameInstance=%s PrimaryFlow=%s GameMode=%s GameState=%s", nm(gi),
    U.ok(gi) and enumName(C.E.PrimaryFlow, gi.PrimaryFlow) or "?", nm(U.gm()), nm(U.gs()))
  if cfg.UseKslIsValid then
    -- VERIFY(V-CORE-05): KismetSystemLibrary:IsValid(Object) returns a boolean without throwing.
    -- Must go through the UFunction (U.kslIsValidRaw): `obj:IsValid()` is always the UE4SS built-in.
    local ok, r = U.kslIsValidRaw(U.p1())
    out("KSL:IsValid(P1) -> ok=%s value=%s (%s)", b(ok), b(r), type(r))
  end
  -- VERIFY(V-CORE-06): every subsystem resolves.
  local names = { "UIManager", "CosmeticStateMachineManager", "EventRecipeSubsystem", "PlayfabOnlineMatchmaking",
                  "ViewModelSubsystem" }
  local parts = {}
  for _, k in ipairs(names) do
    local ok, s = pcall(U.giSubsystem, k)
    parts[#parts + 1] = k .. "=" .. ((ok and U.ok(s)) and "ok" or "MISSING")
  end
  out("subsystems: %s", table.concat(parts, " "))
  -- VERIFY(V-HUD-05): CSM state queries return booleans.
  local csm = {}
  for _, k in ipairs({ "CSM_PauseIdle", "CSM_CountdownInHud", "CSM_InProgressInHud", "CSM_PostRace", "CSM_LocalResults" }) do
    local ok, v = pcall(U.csmActive, k)
    csm[#csm + 1] = k .. "=" .. (ok and tostring(v) or "err")
  end
  out("csm: %s", table.concat(csm, " "))
  -- VERIFY(V-CORE-07 / V-CORE-09): which hooks are registered, still pending (BP not loaded) or failed.
  if type(U.hookStatus) == "function" then
    local st = U.hookStatus()
    local paths = {}
    for path in pairs(st) do paths[#paths + 1] = path end
    table.sort(paths)
    for _, path in ipairs(paths) do out("  hook %s: %s", path, tostring(st[path])) end
  end
end

local function dumpPlayers()
  local s = St.join
  out("join: active=%s frozen=%s", b(s.active), b(s.frozen))
  for id = 1, 3 do
    local sl = s.slots[id]
    if sl then
      out("  slot ctrlId=%d joined=%s disconnected=%s leaving=%s createdMs=%.0f", id, b(sl.joined),
        b(sl.disconnected), b(sl.leaving), sl.createdMs or 0)
    end
  end
  local gs = U.gs()
  local racing = isRacingGS(gs)
  local lps = U.localPlayers()
  out("local players: %d", #lps)
  for _, e in ipairs(lps) do
    section("local player", function()
      local pc = e.pc
      local ps = U.ok(pc) and pc.PlayerState or nil
      local idx = "-"
      if racing and U.ok(ps) then idx = tostring(gs:FindRacerIndexByPlayer(ps)) end
      local tko = U.mod("takeover")
      local rps = (tko.racerPSFor and U.ok(pc)) and tko.racerPSFor(pc) or nil
      local ridx = "-"
      if racing and U.ok(rps) and not U.same(rps, ps) then ridx = tostring(gs:FindRacerIndexByPlayer(rps)) end
      out("  #%d ctrlId=%s pc=%s pawn=%s ps=%s racerIndex=%s racerPS=%s racerPSIndex=%s", e.index or 0,
        tostring(e.ctrlId), nm(pc), U.ok(pc) and nm(pc.Pawn) or "nil", nm(ps), idx, nm(rps), ridx)
    end)
  end
end

local function dumpSplitSettings()
  local g = U.GMS()
  if not U.ok(g) then out("GameMapsSettings CDO not found"); return end
  out("GameMapsSettings: bUseSplitscreen=%s 2P=%s 3P=%s 4P=%s bOffsetPlayerGamepadIds=%s forceDisabled=%s",
    b(g.bUseSplitscreen), enumName(C.E.TwoP, g.TwoPlayerSplitscreenLayout), b(g.ThreePlayerSplitscreenLayout),
    b(g.FourPlayerSplitscreenLayout), b(g.bOffsetPlayerGamepadIds),
    b(U.GS():IsSplitscreenForceDisabled(U.world())))
end

-- VERIFY(V-GFX-01): cvar values before/after the preset; TakedownCameras (Bool).
local function dumpGfx()
  local seen, names = {}, {}
  for _, preset in pairs(cfg.GfxPresets or {}) do
    for name in pairs(preset) do
      if not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
  end
  table.sort(names)
  local parts = {}
  for _, n in ipairs(names) do
    local ok, v = pcall(U.cvarFloat, n)
    parts[#parts + 1] = string.format("%s=%s", n, ok and string.format("%g", v or 0) or "err")
  end
  out("cvars: %s", table.concat(parts, " "))
  local gus = UEHelpers.GetEngine().GameUserSettings
  out("gfx: appliedViews=%s saved=%s TakedownCameras=%s savedTakedown=%s", b(St.gfx.appliedViews),
    St.gfx.saved and "yes" or "no", U.ok(gus) and b(gus.TakedownCameras) or "?", b(St.gfx.savedTakedown))
end

-- VERIFY(V-LCH-03): native slots — every local human appears in Racers with a car and a racer index >= 0.
-- VERIFY(V-TKO-02): the input-source overrides present on AI cars at countdown / race.
local function dumpRace()
  local gs = U.gs()
  if not isRacingGS(gs) then out("race: not in a race (GameState %s)", nm(gs)); return end
  out("race: bIsRaceStarted=%s bIsRaceFinished=%s LapCount=%s St.race{started=%s startedAtMs=%.0f localViews=%s lapOffset=%s map=%s}",
    b(gs.bIsRaceStarted), b(gs.bIsRaceFinished), b(gs.LapCount), b(St.race.started), St.race.startedAtMs or 0,
    b(St.race.localViews), b(St.race.lapOffset), b(St.race.mapPath))
  local racers = U.arrayToTable(gs.Racers)
  out("Racers: %d", #racers)
  for i = 1, #racers do
    section("racer", function()
      local ps = racers[i]
      local rec = U.ok(ps) and ps.RaceEventComponent or nil
      out("  racer %d %s name=%s bot=%s pos=%s lap=%s finished=%s pawn=%s", i, nm(ps),
        U.ok(ps) and U.str(ps:GetPlayerName()) or "?", U.ok(ps) and b(ps.bIsABot) or "?",
        U.ok(rec) and b(rec.EventPosition) or "?", U.ok(rec) and b(rec.CurrentLapNumber) or "?",
        U.ok(rec) and b(rec.bHasFinishedEvent) or "?", U.ok(ps) and nm(ps.PawnPrivate) or "nil")
    end)
  end
  local cars = U.arrayToTable(gs.Vehicles)
  out("Vehicles: %d", #cars)
  for i = 1, #cars do
    section("car", function()
      local car = cars[i]
      if not U.ok(car) then out("  car %d invalid", i); return end
      out("  car %d %s ctrl=%s ps=%s current=%s original=%s overrides=%s", i, nm(car), nm(car.Controller),
        nm(car.PlayerState), enumName(C.E.InputSource, car:GetCurrentInputSource()),
        enumName(C.E.InputSource, car:GetOriginalInputSource()), overridesText(car))
    end)
  end
end

local function dumpTakeovers()
  local n = 0
  for _, rec in pairs(St.takeovers) do
    n = n + 1
    out("  takeover pc=%s car=%s aiPS=%s aiCtrl=%s ownPS=%s adopted=%s aiCtrlHadPS=%s", nm(rec.pc), nm(rec.car),
      nm(rec.aiPS), nm(rec.aiCtrl), nm(rec.ownPS), b(rec.adopted), b(rec.aiCtrlHadPS))
  end
  out("takeovers: %d", n)
end

local function dumpHud()
  local h = St.hud
  out("hud: p1hud=%s p1Placed=%s", nm(h.p1hud), b(h.p1Placed))
  for _, e in pairs(h.guests) do
    out("  guest P%s pc=%s widget=%s lapCounter=%s lastLapText=%s", b(e.pnum), nm(e.pc), nm(e.widget),
      nm(e.lapCounter), b(e.lastLapText))
  end
  if U.ok(h.p1hud) then
    -- VERIFY(V-CORE-08): PanelWidget:GetAllChildren() -> TArray<UWidget> return marshalling.
    section("markers", function()
      -- WBP_VehicleMarkerContainer is a widget-tree member, not a Blueprint variable (hud.lua header): found by
      -- hud's tree walk, never by property access
      local mem = U.mod("hud")._membersOf(h.p1hud)
      local mc = mem and mem.markers
      local canvas = U.ok(mc) and mc.Canvas or nil
      if U.ok(canvas) then
        out("  P1 HUD marker canvas children: %d", #U.arrayToTable(canvas:GetAllChildren()))
      else
        out("  P1 HUD has no WBP_VehicleMarkerContainer.Canvas")
      end
    end)
  end
end

-- ---------------------------------------------------------------------------------------------
-- Public API
-- NO-INTRO mode (fastboot.lua): what the boot watcher did in this visit (V-FB-01..03).
local function dumpFastboot()
  local okM, fb = pcall(require, "fastboot")
  if not okM or type(fb) ~= "table" or type(fb.status) ~= "function" then
    out("fastboot: module not loaded")
    return
  end
  local s = fb.status()
  out("fastboot: running=%s arm=%s title=%s photo=%s link=%s menu=%s epic(found=%s wasOn=%s flips=%s settings=%s) "
    .. "eosFallback=%s", b(s.running), b(s.armReason), b(s.advanced), b(s.photoDone), b(s.linkDone), b(s.menu),
    b(s.epicFound), b(s.epicWasOn), b(s.epicFlips), b(s.settingsFlips), b(s.eosFallback))
  for step, text in pairs(s.log or {}) do out("  fastboot %s: %s", tostring(step), tostring(text)) end   -- Lua table
end

-- 0.4.0 integration: clock, per-view presentation, guest names, input isolation, race setup plan.
local function dumpClock()
  local ci = St.clockInfo and St.clockInfo() or {}
  out("clock: source=%s os.clock x%.2f of real time (%s rate samples, %s failures) now=%.0f ms", b(ci.source),
    1 / (tonumber(ci.rate) or 1), b(ci.samples), b(ci.fails), St.nowMs())
end

local function dumpPresent()
  local p = St.present
  if type(p) ~= "table" then out("present: not initialised"); return end
  local okP, present = pcall(require, "present")
  local decided, why = nil, nil
  if okP and type(present) == "table" and present.decide then
    local ok, v, w = pcall(present.decide)
    if ok then decided, why = v, w end
  end
  local single = "?"
  pcall(function() single = b(U.mod("split").isSingleView()) end)
  out("present: view=%s (%s) decide=%s (%s) engineSingle=%s mode=%s ignition=%s/%s", b(p.view), b(p.why), b(decided),
    b(why), single, b(cfg.PresentViewMode), b(cfg.IgnitionMode), b(cfg.IgnitionView))
  local ign = p.ign or {}
  out("  ignition: gameHidden=%s game=%s", b(ign.gameHidden), nm(ign.game))
  for _, e in pairs(ign.players or {}) do
    out("  P%s screen=%s pawnKey=%s listDone=%s", b(e.pnum), nm(e.widget), b(e.pawnKey), b(e.listDone))
  end
  for k, s in pairs(ign.state or {}) do
    out("  pc %s: checks underway=%s ever=%s autoDone=%s", tostring(k), b(s.underway), b(s.everUnderway), b(s.autoDone))
  end
  -- 0.5.0: ignition.lua's effective mode, ignpad (own-pad assist / prompts, V-PRE-06/07), shared photo-mode detector
  local okI, ig = pcall(require, "ignition")
  if okI and type(ig) == "table" and type(ig.mode) == "function" then
    out("  ignition: effective mode=%s photo=%s", b(ig.mode()), b(ign.photo))
  end
  local okG, ignpad = pcall(require, "ignpad")
  if okG and type(ignpad) == "table" and type(ignpad.describe) == "function" then
    pcall(ignpad.describe, function(line) out("%s", tostring(line)) end)
  end
  local okH, ph = pcall(require, "phase")
  if okH and type(ph) == "table" and type(ph.photoMode) == "function" then
    local okV, v, why = pcall(ph.photoMode)
    out("  photo mode: %s (%s)", okV and b(v) or "?", b(why))
  end
end

local function dumpNames()
  for _, lp in ipairs(U.localPlayers()) do
    local ps = U.ok(lp.pc) and lp.pc.PlayerState or nil
    local name, filtered = "?", "?"
    pcall(function() name = U.str(ps:GetPlayerName()) end)
    pcall(function() filtered = U.str(ps:GetFilteredName()) end)
    out("names: local %d ctrlId=%s ps=%s name='%s' filtered='%s'", lp.index, b(lp.ctrlId), nm(ps), name, filtered)
  end
end

local function dumpInputfix()
  local ok, inputfix = pcall(require, "inputfix")
  if not ok or type(inputfix) ~= "table" or type(inputfix.dump) ~= "function" then
    out("inputfix: module not loaded")
    return
  end
  inputfix.dump()          -- its lines + fresh native counters ~0.7 s later (UE4SS.log)
end

local function dumpSetup()
  local c = St.race.choice
  if type(c) ~= "table" then out("setup: no race chosen"); return end
  local s = c.setup
  out("setup: race '%s' setup=%s", b(c.label), type(s) == "table" and "yes" or "no (dev panel / settings.txt)")
  if type(s) == "table" then
    out("  class=%s mode=%s single=%s grid=%s maxRacers=%s", b(s.classKey), b(s.modeKey), b(s.single), b(s.grid),
      b(s.maxRacers))
    for pnum, p in pairs(s.players or {}) do
      out("  P%s model=%s build=%s", b(pnum), b(p.presetId), b(p.buildPath))
    end
  end
  local gp = St.launch.gridPatch
  if gp then out("  grid patch active on %s", U.ok(gp.gmv) and nm(gp.gmv) or tostring(gp.path)) end
end

-- wreck.lua (2026-10-07): race timeout (RaceTimeoutTime / now / timeout byte), every racer's wreck/finish/health
-- state, each local player's view target + camera probe, slow-mo cvar/dilation, P1's spectate/results CSM states.
local function dumpWreck()
  local ok, wreck = pcall(require, "wreck")
  if not ok or type(wreck) ~= "table" or type(wreck.dump) ~= "function" then
    out("wreck: module not loaded")
    return
  end
  wreck.dump()
end

-- crashcam.lua (0.5.1): guest crash-view verdicts (learned / proven), counters, one camera probe per local player.
local function dumpCrashcam()
  local ok, m = pcall(require, "crashcam")
  if ok and type(m) == "table" and type(m.dump) == "function" then m.dump() else out("crashcam: module not loaded") end
end

-- viewguard.lua (0.6.0): view fixes of still-racing players this race.
local function dumpViewguard()
  local ok, m = pcall(require, "viewguard")
  if ok and type(m) == "table" and type(m.dump) == "function" then m.dump() else out("viewguard: module not loaded") end
end

-- uxsplit.lua (0.7.0): per-player messages / index remap / danger visuals: armed state, hooks with ids, counters,
-- each HUD's notification containers, tints, fades, messages still held per player (V-UX-01..12).
local function dumpUxsplit()
  local ok, m = pcall(require, "uxsplit")
  if ok and type(m) == "table" and type(m.dump) == "function" then
    m.dump(function(f, ...) out(f, ...) end)
  else
    out("uxsplit: module not loaded")
  end
  -- guest lap mapping (run H fix, V-HUD-04): offset in use and the P1 lap it was taken at
  local h = St.hud or {}
  out("  lap: offset=%s (calibrated at P1 lap %s)", b(St.race.lapOffset), b(h.lapCalibDone))
end

-- pause.lua (0.7.0): the split-race pause layers. Its ChangeStateTo hook is a raw RegisterHook (U.hookStatus never
-- lists it): armed flag + hook, request count (and requests no pause followed), the pre-created screen (C) and whether
-- the CSM acquired it, guests' IMC_UI boost (D), HUD inputs turned off (A2), our restarted pause CSM (G), the last
-- pauser, the Menu-layer Z (seen / auto) and the dialog containers found (V-PAU-09..18).
local function dumpPause()
  local ok, m = pcall(require, "pause")
  if not (ok and type(m) == "table" and type(m.status) == "function") then
    out("pause: module not loaded")
    return
  end
  local okS, s = pcall(m.status)
  if not okS or type(s) ~= "table" then
    out("pause: status() failed: %s", b(s))
    return
  end
  out("pause: armed=%s hook=%s hookCalls=%s requests=%s noPause=%s pre=%s acquired=%s imcBoosted=%s hudInputsOff=%s "
    .. "ownCsm=%s pauser=%s z=%s/%s dialogs=%s", b(s.armed), b(s.hook), b(s.hookCalls), b(s.requests), b(s.noPause),
    b(s.pre), b(s.preAcquired), b(s.imcBoosted), b(s.hudInputsOff), b(s.ownCsm), b(s.pauser), b(s.zSeen), b(s.zAuto),
    b(s.dialogs))
  out("  cfg: hook=%s readState=%s precreate=%s owner=%s padShift=%s imcBoost=%s inputGuard=%s lostMenu=%s "
    .. "anyStart=%s restartCsm=%s rehost=%s", b(cfg.PauseCsmHook), b(cfg.PauseHookReadState), b(cfg.PauseMenuPrecreate),
    b(cfg.PauseMenuOwner), b(cfg.PauseOwnerPadShift), b(cfg.PauseUiImcBoost), b(cfg.PauseHudInputGuard),
    b(cfg.PauseLostMenu), b(cfg.PauseAnyStartResumes), b(cfg.PauseRestartCsm), b(cfg.PauseMenuRehost))
  -- 0.8.0 phase 2 (V-PAU-19..22): B2 ChangeToState hook (opt-in) and its calls, sub-screen requests (C2), a sub-screen
  -- on screen now (E2 probes), guests' IMC_UI lowered for a confirm dialog (D2)
  out("  phase 2: ctsHook=%s ctsCalls=%s subRequests=%s subScreen=%s imcDialog=%s; cfg subPrecreate=%s subHook=%s "
    .. "dialogGuestUi=%s", b(s.ctsHook), b(s.ctsCalls), b(s.subRequests), b(s.subScreen), b(s.imcDialog),
    b(cfg.PauseSubScreenPrecreate), b(cfg.PauseSubScreenHook), b(cfg.PauseDialogGuestUi))
end

-- menubridge.lua (0.7.1, 0.8.0): the screen a press would act on (a confirm dialog first), its owner, clicks so far, the
-- front-end profile-card loop (V-MB-01..06).
local function dumpMenubridge()
  local ok, m = pcall(require, "menubridge")
  if not (ok and type(m) == "table" and type(m.status) == "function") then
    out("menubridge: module not loaded")
    return
  end
  local okS, s = pcall(m.status)
  if not okS or type(s) ~= "table" then
    out("menubridge: status() failed: %s", b(s))
    return
  end
  out("menubridge: on=%s screens=%s top=%s owner=%s dialog=%s clicks=%s feLoop=%s", b(cfg.MenuBridge), b(s.screens),
    b(s.top), s.topOwner and ("P" .. tostring(s.topOwner)) or "-", b(s.dialog), b(s.clicks), b(s.feLoop))
  out("  cfg: wait=%s guestNative=%s dialogs=%s back=%s controllerFallback=%s profileOwner=%s", b(cfg.MenuBridgeWaitMs),
    b(cfg.MenuBridgeGuestNative), b(cfg.MenuBridgeDialogs), b(cfg.MenuBridgeBack), b(cfg.MenuBridgeControllerFallback),
    b(cfg.MenuBridgeProfileOwner))
end

-- subsplit.lua (0.8.0): subtitles per player: armed state, widget, hooks with ids, counters, cfg, layout, clones, the
-- last line and the pending requests (V-SUB-00..08).
local function dumpSubsplit()
  local ok, m = pcall(require, "subsplit")
  if ok and type(m) == "table" and type(m.dump) == "function" then
    m.dump(function(f, ...) out(f, ...) end)
  else
    out("subsplit: module not loaded")
  end
end

-- vpreview.lua (0.8.0): 3D vehicle cards of RACE SETUP > VEHICLES (front end only): on / off for the session (+ why),
-- each bay's state and model, captures (V-VP-01..10).
local function dumpVpreview()
  local ok, m = pcall(require, "vpreview")
  if not (ok and type(m) == "table" and type(m.status) == "function") then
    out("vpreview: module not loaded")
    return
  end
  local on, why = false, nil
  if type(m.enabled) == "function" then on, why = m.enabled() end
  out("vpreview: %s; usable now=%s%s", tostring(m.status()), b(on), why and (" (" .. tostring(why) .. ")") or "")
  out("  cfg: 3D=%s rebuild=%s brush=%s material=%s param=%s target %sx%s format %s source %s fov %s spin %s dps "
    .. "capture %s ms fill %s lux exposure=%s showOnly=%s captureOnly=%s", b(cfg.SetupPreview3D),
    b(cfg.SetupPreviewRebuild), b(cfg.SetupPreviewBrush), tostring(cfg.SetupPreviewMaterial):match("[^%./]+$") or "?",
    b(cfg.SetupPreviewMaterialParam), b(cfg.SetupPreviewW), b(cfg.SetupPreviewH), b(cfg.SetupPreviewRtFormat),
    b(cfg.SetupPreviewCaptureSource), b(cfg.SetupPreviewFov), b(cfg.SetupPreviewSpinDps), b(cfg.SetupPreviewCaptureMs),
    b(cfg.SetupPreviewFillLux), b(cfg.SetupPreviewExposure), b(cfg.SetupPreviewShowOnly), b(cfg.SetupPreviewCaptureOnly))
end

-- ---------------------------------------------------------------------------------------------

function M.dump()
  out("===== SWGRCouch %s diag =====", tostring(C.VERSION))
  section("core", dumpCore)
  section("fastboot", dumpFastboot)
  section("players", dumpPlayers)
  section("split", dumpSplitSettings)
  section("gfx", dumpGfx)
  section("race", dumpRace)
  section("takeovers", dumpTakeovers)
  section("hud", dumpHud)
  section("clock", dumpClock)
  section("present", dumpPresent)
  section("names", dumpNames)
  section("setup", dumpSetup)
  section("inputfix", dumpInputfix)
  section("wreck", dumpWreck)
  section("crashcam", dumpCrashcam)
  section("viewguard", dumpViewguard)
  section("uxsplit", dumpUxsplit)
  section("pause", dumpPause)
  section("menubridge", dumpMenubridge)
  section("subsplit", dumpSubsplit)
  section("vpreview", dumpVpreview)
  out("===== end diag =====")
end

-- Recipe evidence (V-LCH-03), called by launch right after LaunchCustomRace and by `couch recipe`.
-- DEVIATION from §4.2: UEventRecipeSubsystem:GetActiveRecipeEventStage() is NOT called. It returns a
-- RaceEventInstance by value (0x308 bytes) and UE4SS 3.0.1 marshals UFunction calls through a fixed
-- 0x200-byte buffer (LuaUFunction.hpp DynamicUnrealFunctionData), so the call would overrun the stack.
-- The same data is read from properties: ActiveRecipe.Recipe.EventStages[RecipeState.ActiveStage + 1].
function M.recipe()
  out("----- recipe -----")
  section("recipe", function()
    local rs = U.giSubsystem("EventRecipeSubsystem")
    if not U.ok(rs) then out("EventRecipeSubsystem not found"); return end
    local inst = rs.ActiveRecipe
    if not U.ok(inst) then out("no ActiveRecipe"); return end
    local state = inst.RecipeState
    local racers = state.Racers
    local n = racers:GetArrayNum()
    out("ActiveStage=%s racers=%d", b(state.ActiveStage), n)
    for i = 1, n do
      local r = racers[i]
      -- 0.4.0: VehicleCustomisation (the PRE_* model, +0x80) and the bot flag: V-SET-06/08 evidence
      local cust, bot = "-", "?"
      pcall(function() cust = nm(r.VehicleCustomisation) end)
      pcall(function() bot = b(r.Player.bIsABot) end)
      out("  [%d] player=%s bot=%s pilot=%s vehicleType=%s model=%s", i, nm(r.Player), bot, nm(r.Pilot),
        enumName(C.E.Archetype, r.VehicleType), cust)
    end
    local stages = inst.Recipe.EventStages
    local ns = stages:GetArrayNum()
    local idx = (tonumber(state.ActiveStage) or 0) + 1
    out("EventStages=%d", ns)
    if idx >= 1 and idx <= ns then
      local st = stages[idx]
      out("  stage %d InternalName=%s TrackDef=%s LapCount=%s RaceEventModeType=%s GameModeVariant=%s", idx,
        U.str(st.InternalName), nm(st.TrackDef), b(st.LapCount), b(st.RaceEventModeType), nm(st.GameModeVariant))
    end
  end)
  -- Clients: the replicated copy on the RacingGameState.
  section("recipe-gs", function()
    local gs = U.gs()
    if not isRacingGS(gs) then return end
    local racers = gs.EventRecipeState_Replication.Racers
    local n = racers:GetArrayNum()
    out("GameState.EventRecipeState_Replication racers=%d", n)
    for i = 1, n do
      local r = racers[i]
      local cust = "-"
      pcall(function() cust = nm(r.VehicleCustomisation) end)
      out("  [%d] player=%s vehicleType=%s model=%s", i, nm(r.Player), enumName(C.E.Archetype, r.VehicleType), cust)
    end
  end)
  out("----- end recipe -----")
end

function M.net()
  out("----- net -----")
  section("net", function()
    local w = U.world()
    local nd = U.ok(w) and w.NetDriver or nil
    local gi = U.gi()
    out("netMode=%s NetDriver=%s PrimaryFlow=%s map=%s", tostring(U.netMode()), nm(nd),
      U.ok(gi) and enumName(C.E.PrimaryFlow, gi.PrimaryFlow) or "?", tostring(U.levelName()))
    local keys = {}
    for k, v in pairs(St.net) do if type(v) ~= "table" then keys[#keys + 1] = k end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(St.net[k]) end
    out("St.net: %s", table.concat(parts, " "))
    local f = St.net.lastFailure
    if type(f) == "table" then
      out("last failure: %s %s (%.0f ms ago)", b(f.name), b(f.msg), St.nowMs() - (f.atMs or 0))
    end
  end)
  section("remote", function()
    local remote = U.mod("roster").remoteHumans() or {}
    out("remote humans: %d", #remote)
    for i = 1, #remote do
      local o = remote[i]
      local ps = (U.ok(o) and U.isPlayerController(o)) and o.PlayerState or o
      out("  %d %s ps=%s name=%s pawn=%s", i, nm(o), nm(ps), U.ok(ps) and U.str(ps:GetPlayerName()) or "?",
        U.ok(ps) and nm(ps.PawnPrivate) or "nil")
    end
  end)
  out("----- end net -----")
end

local lastPeriodicMs = 0

function M.periodic()
  local every = tonumber(cfg.DiagPeriodicMs) or 0
  if every <= 0 then return end
  local now = St.nowMs()
  if now - lastPeriodicMs < every then return end
  lastPeriodicMs = now
  M.dump()
end

-- Debug-only hooks (cfg.Debug): learn the game's own possession / human<->AI paths (V-TKO-08).
function M.init()
  if not cfg.Debug then return end
  -- AVehiclePawn::Multi_ReceiveControllerAssigned(), NetMulticast native, no params.
  U.hook(C.FN.ControllerAssigned, { post = function(ctx)
    local car = ctx:get()
    out("ControllerAssigned car=%s ctrl=%s ps=%s", nm(car), U.ok(car) and nm(car.Controller) or "nil",
      U.ok(car) and nm(car.PlayerState) or "nil")
  end }, TAG)
  -- AGfnPlayerController::PossessedPawnChanged(APawn* oldPawn, APawn* newPawn), native 0x40401.
  U.hook(C.FN.PossessedPawnChanged, { post = function(ctx, oldPawn, newPawn)
    out("PossessedPawnChanged pc=%s old=%s new=%s", nm(ctx:get()), nm(oldPawn and oldPawn:get()),
      nm(newPawn and newPawn:get()))
  end }, TAG)
  -- UMatchManagerSubsystem::OnHumanSwitchedWithAI(), native 0x40401, no params.
  -- VERIFY(V-TKO-08): fires when the game swaps a disconnected human for AI.
  U.hook(C.FN.HumanSwitchedWithAI, { post = function(ctx)
    out("OnHumanSwitchedWithAI on %s (phase %s)", nm(ctx:get()), St.phase)
  end }, TAG)
  U.dbg(TAG, "debug hooks queued")
end

return M
