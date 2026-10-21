-- ignition.lua (Track B; split out of present.lua 2026-10-07 after session E; 0.5.1 after run F): the pre-flight
-- checks / ignition minigame for every local player. present.lua calls tick(lps) (MAIN, race phases, 2+ local
-- players), fastTick() (FAST) and clear(); ignpad.lua does the per-player pad input and the pad prompts.
--
-- cfg.IgnitionMode (session E: "the screens don't respond to gamepads"; run F: "ignition game still doesn't work"):
--   "auto" (wanted default)  every player gets its own WBP_IgnitionScreen_C in its own view and does its own checks
--                            with its own pad: the game's own input path when it delivers (P1), else ignpad calls the
--                            player's OWN BP_GfnPlayerController action event (InpActEvt_IA_Veh_*) with the IA object,
--                            which runs TestPreflightCheckInput natively. NO soft pointer is touched in Lua in this
--                            mode (0.5.1): no completion rescue any more (it read the soft-keyed map); a player whose
--                            input cannot work keeps manual checks, which time out after PreFlightCheckDuration (run F:
--                            5.1 s, the race then starts normally).
--   "perplayer"              same as "auto" (kept as an alias).
--   "simple"                 "auto" + the game's simple pre-flight sequences for everyone (bUseSimplePreflights).
--   "p1game_guestauto"       FALLBACK: the game's own screen for P1 (viewport-wide, untouched) with P1's pad; guests'
--                            checks time out (~5 s). autoComplete (READS THE SOFT-KEYED MAP) only with the explicit
--                            opt-in cfg.IgnitionSoftComplete = true (integration 0.5.1, HARD RULE).
--   "complete"               own screens; every local player's checks completed by the mod only with
--                            IgnitionSoftComplete = true (else they time out).
--   "off"                    game behaviour (P1's screen only).
-- Static facts (notes/research/presentation.md §3, work/exports/present/WBP_IgnitionScreen.disasm.txt):
--   WBP_IgnitionScreen_C (UIManager HUD layer, viewport-wide): Construct binds ignition phase/status to
--     GetPlayerPawn(self, 0) (P1's car) and builds the check list from GetOwningPlayer()->PlayerState->
--     PreFlightCheckComponent (per player); vars VehiclePawn, IgnitionPhase, PreFlightCheckLists,
--     CurrentPreFlightCheckList (set by OnPreFlightCheckStart, None on Success/Failed), SuccessCount (+1 per success),
--     WBP_Hud_Ignition_Input_Action (IA_Veh_Throttle prompt); BP functions SetupIgnitionBindings(),
--     AddPreflightChecksToList(), OnSimplePreflightChanged(), OnIgnitionPhaseChanged(Old, New),
--     "On Ignition Status Changed"(Old, New). Its only input binding is IA_Veh_Pause (PauseForCutscene toggle).
--   PlayerPreFlightCheckComponent: bAreChecksUnderway, bUseSimplePreflights, AfterburnerCheck,
--     PreFlightChecksByAction (Map<SoftObject<InputAction>, PreFlightCheck>: NEVER read it in "auto"),
--     TestPreflightCheckInput(SoftObject), Server_OnSuccessfulPreFlightCheck(PreFlightCheck, Bool autoComplete).
--   AVehiclePawn.VehicleState: IgnitionPhase (Offline 0, EngineIgnite 1, PerfectStart 2, PostPerfectStart 3),
--     IgnitionStatus (Off 0, AlreadyOn 1, SuccessfulIgnite 2, FailedIgnite 3).
-- VERIFY(V-PRE-02): each half shows its own list; VERIFY(V-PRE-03): "P2 pre-flight checks underway: true" and P2's pad
-- advances P2's list (ignpad V-PRE-06); VERIFY(V-PRE-08): the per-player "probe" lines; VERIFY(V-PRE-10): per-player
-- "P2 ignition: phase ... status ..." lines (engine start of each car, SuccessfulIgnite for a guest that pressed).

local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "ignition"

local IGN_CLASS = "/Game/Griffin/UI/Screens/PreRace/WBP_IgnitionScreen.WBP_IgnitionScreen_C"
local IGN_SHORT = "WBP_IgnitionScreen_C"
local HUD_LAYER = 1 -- EUILayer::HUD (CSM_RF_IgnitionSequence ShowWidget Layer, decoded)
local SEARCH_EVERY_MS = 2000

local MODES = { auto = true, perplayer = true, simple = true, p1game_guestauto = true, complete = true, off = true }
function M.mode()
    local m = cfg.IgnitionMode
    if MODES[m] then return m end
    return "auto"
end

local function screensWanted(m) return m == "auto" or m == "perplayer" or m == "simple" or m == "complete" end
local function assistFor(m, pnum)
    if m == "off" or m == "complete" then return false end
    if m == "p1game_guestauto" then return pnum == 1 end
    return true
end

local function lazy(name)
    local ok, m = pcall(U.mod, name)
    if ok and type(m) == "table" then return m end
    return nil
end

-- State lives in St.present.ign (diag.lua prints it).
local function P()
    St.present = St.present or { view = nil, why = nil }
    St.present.ign = St.present.ign or { players = {} }
    return St.present.ign
end

-- U.findLoaded (cached; a miss retried after 1 s or on a phase / world change): the raw StaticFindObject (~2.5 ms in a
-- race world) ran on every MAIN tick of the ignition sequence (race smoothness 2026-10-15, present.tick spikes)
local function loadedClass(path)
    return U.findLoaded(path, 1000)
end

local function objName(o)
    if not U.ok(o) then return "?" end        -- GetFName on a null wrapper is a native AV
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    if ok and type(s) == "string" then return s end
    return "?"
end

local function isOurs(ign, w)
    for _, e in pairs(ign.players) do
        if U.same(e.widget, w) then return true end
    end
    return false
end

-- The game's (viewport-wide, P1-driven) ignition screen: UIManager HUD layer, else FindAllOf (<= 1 per 2 s).
local function findGameScreen(ign, cls)
    if U.ok(ign.game) then return ign.game end
    if not cls then return nil end
    local mgr = U.giSubsystem("UIManager")
    if U.ok(mgr) then
        local ok, w = pcall(U.callMethod, mgr, "GetWidgetInLayer", cls, HUD_LAYER)
        if ok and U.ok(w) and not isOurs(ign, w) then ign.game = w; return w end
    end
    local now = St.nowMs()
    if now - (ign.lastSearchMs or -1e9) < SEARCH_EVERY_MS then return nil end
    ign.lastSearchMs = now
    for _, w in ipairs(FindAllOf(IGN_SHORT) or {}) do -- nil or a Lua table [API 6]
        if U.ok(w) and not isOurs(ign, w) and (w:IsInViewport() == true or U.ok(w:GetParent())) then
            ign.game = w
            return w
        end
    end
    return nil
end

local function pfcOf(pc)
    local pawn = pc.Pawn
    local ps = (U.isVehicle(pawn) and U.ok(pawn.PlayerState)) and pawn.PlayerState or pc.PlayerState
    if not U.ok(ps) then return nil end
    local c = ps.PreFlightCheckComponent -- AGfnPlayerState.PreFlightCheckComponent
    if U.ok(c) then return c end
    return nil
end

-- Photo mode (session E: both PCs possessed BP_PhotoModePawn_C): leave everything alone while it runs.
-- Integration 0.5.0: phase.photoMode() first (the shared detector: PhotoModeManager flag, pawns, pause CSM), then the
-- pawn test below as the local fallback.
local function photoModeActive(lps)
    local ph = lazy("phase")
    if ph and type(ph.photoMode) == "function" then
        local ok, v = pcall(ph.photoMode)
        if ok and v == true then return true end
    end
    for _, lp in ipairs(lps) do
        local cn = nil
        -- U.ok FIRST: GetClass on a null wrapper is a native AV (UE4SS.dll+0x2ace67 null+0x10) that pcall cannot catch: at the ignition the
        -- pawn can still be null (a CONTINUEd run straight into its race crashed here every time, live 2026-10-14)
        pcall(function() local pawn = lp.pc.Pawn; if U.ok(pawn) then cn = U.className(pawn) end end)
        if type(cn) == "string" and cn:find("PhotoModePawn", 1, true) then return true end
    end
    return false
end
M.photoModeActive = photoModeActive

-- Transitions of each player's checks. VERIFY(V-PRE-03).
local function traceChecks(s, comp, pnum)
    local on = comp.bAreChecksUnderway == true
    if s.underway ~= on then
        U.log(TAG, "P%d pre-flight checks underway: %s (simple=%s)", pnum, tostring(on),
            tostring(comp.bUseSimplePreflights))
        s.underway = on
        if on then s.everUnderway = true end
    end
    return on
end

-- One line per player when its checks start: which component the screen, the PC's own BP cache and we use, the
-- mapping contexts on its raw input, whether that raw input feeds the PC's PlayerInput, and its CommonInput type.
-- VERIFY(V-PRE-08): a guest with "ctx={}" or "pcBP=None" explains a dead game path; ignpad then assists.
local function probe(lp, comp, e)
    local pc = lp.pc
    local bpComp, raw, epi, pi, ps, pawnPs, cisType = nil, nil, nil, nil, nil, nil, nil
    pcall(function() bpComp = pc["Pre Flight Check Component"] end)
    pcall(function() raw = pc.RawInputSubsystem end)
    pcall(function() epi = raw.EnhancedPlayerInput end)
    pcall(function() pi = pc.PlayerInput end)
    pcall(function() ps = pc.PlayerState end)
    pcall(function() pawnPs = pc.Pawn.PlayerState end)
    local ctx = {}
    pcall(function()
        raw.ActiveMappingContexts:ForEach(function(_, el) ctx[#ctx + 1] = objName(el:get()) end)
    end)
    pcall(function()
        local c = loadedClass("/Script/CommonInput.CommonInputSubsystem")
        cisType = U.SBL():GetLocalPlayerSubSystemFromPlayerController(pc, c):GetCurrentInputType()
    end)
    local lists = e and U.arrayCount(e.widget.PreFlightCheckLists) or -1
    -- run F: "same false" for P1 too: UE4SS `==` on two wrappers is not a pointer compare here; compare addresses.
    local function sameK(a, b) local ka = U.key(a); return ka ~= 0 and ka == U.key(b) end
    U.log(TAG, "P%d probe: comp=%s@0x%x pcBP=%s@0x%x (same %s) pawnPS==pcPS %s raw=%s ctx={%s} raw->PlayerInput %s "
        .. "commonInput=%s screen=%s lists=%d", lp.index, objName(comp), U.key(comp),
        U.ok(bpComp) and objName(bpComp) or "None", U.key(bpComp), tostring(sameK(bpComp, comp)),
        tostring(sameK(ps, pawnPs)), U.ok(raw) and objName(raw) or "None", table.concat(ctx, ","),
        tostring(sameK(epi, pi)), tostring(cisType), e and objName(e.widget) or "none", lists)
end

-- Every local car's engine start (VERIFY V-PRE-10): IgnitionPhase / IgnitionStatus transitions per player, read from
-- the car's VehicleState (plain enums). Tells whether a guest's ignition press (throttle) reaches its own car.
local PHASES = { [0] = "Offline", "EngineIgnite", "PerfectStart", "PostPerfectStart" }
local STATUS = { [0] = "Off", "AlreadyOn", "SuccessfulIgnite", "FailedIgnite" }
local function traceIgnition(s, pc, pnum)
    local ph, st = nil, nil
    pcall(function()
        local vs = pc.Pawn.VehicleState
        ph, st = vs.IgnitionPhase, vs.IgnitionStatus
    end)
    if type(ph) ~= "number" or type(st) ~= "number" then return end
    if ph ~= s.ignPhase or st ~= s.ignStatus then
        U.log(TAG, "P%d ignition: phase %s -> %s, status %s -> %s", pnum, tostring(PHASES[s.ignPhase] or s.ignPhase),
            tostring(PHASES[ph] or ph), tostring(STATUS[s.ignStatus] or s.ignStatus), tostring(STATUS[st] or st))
        s.ignPhase, s.ignStatus = ph, st
    end
end

---------------------------------------------------------------------------------------------------- completion + screens
-- (moved unchanged from present.lua 0.4.0)
-- SOFT-POINTER NOTE (0.5.1): this reads the soft-keyed PreFlightChecksByAction map (ForEach) and passes
-- FPreFlightCheck structs (TArray<TSoftObjectPtr> inside) to the RPC. It runs ONLY in the explicit fallback modes
-- "complete" / "p1game_guestauto" (run F3 ran it without a crash; runs F1/F2 crashed in the old ignpad soft reads).
-- Complete every check of this component, the way the game's own auto path does ("complete", guests of
-- "p1game_guestauto"; never in "auto" since 0.5.1).
-- AT MOST ONE CHECK PER MAIN TICK, from a FRESH map read: the ForEach value is a struct wrapper pointing into the
-- PreFlightChecksByAction TMap's element memory (no copy). On a standalone/listen server the RPC runs synchronously;
-- if its handler removes/resets entries or rebuilds the map (FPreFlightCheck holds FText/TArray members), wrappers
-- kept across calls would point at freed elements and the next call's struct copy would crash. So each tick: one
-- ForEach, the wanted entry is called at once, nothing is kept. When the map shrinks after a call (the handler
-- removes done checks) the first entry is taken each time, else the next index. Then AfterburnerCheck (a property
-- of the component, read fresh). e.autoDone only when bAreChecksUnderway turns false (or the call budget ends).
-- VERIFY(V-PRE-04): Server_OnSuccessfulPreFlightCheck(check, true) per check ends the checks for that player (its
-- list turns green / the engine-start prompt comes). Fallback: cfg.IgnitionMode = "perplayer" or IgnitionSimple.
local function autoComplete(e, comp, pnum)
    if e.autoDone then return end
    if comp.bAreChecksUnderway ~= true then
        if (e.autoCalls or 0) > 0 then
            e.autoDone = true
            U.log(TAG, "P%d pre-flight checks auto-completed: %d call(s), checks no longer underway", pnum, e.autoCalls)
        end
        return
    end
    e.autoCalls = e.autoCalls or 0
    local count, called, err = 0, false, nil
    local okM = pcall(function()
        local want = nil
        comp.PreFlightChecksByAction:ForEach(function() count = count + 1 end) -- uobj: opt-in IgnitionSoftComplete only (0.5.1)
        if e.autoPrevCount and count < e.autoPrevCount then e.autoShrinks = true end
        want = e.autoShrinks and 1 or ((e.autoMapDone or 0) + 1)
        if want > count then return end
        local i = 0
        comp.PreFlightChecksByAction:ForEach(function(_, v) -- uobj: opt-in IgnitionSoftComplete only; TMap:ForEach(key, value)
            i = i + 1
            if i ~= want or called then return end
            local st = U.unwrap(v)
            if st == nil then return end
            called = true
            local ok, e2 = pcall(function() comp:Server_OnSuccessfulPreFlightCheck(st, true) end)
            if not ok then err = e2 end
            return true                                -- stop iterating (UE4SS ForEach: a true return breaks)
        end)
    end)
    if not okM then err = err or "map not readable" end
    if called then
        e.autoMapDone = (e.autoMapDone or 0) + 1
        e.autoPrevCount = count
    elseif not e.autoAfterburner then
        e.autoAfterburner = true
        local ok, e2 = pcall(function()
            local ab = comp.AfterburnerCheck
            if ab == nil then error("no AfterburnerCheck") end
            comp:Server_OnSuccessfulPreFlightCheck(ab, true)
        end)
        called = ok
        if not ok then err = e2 end
    end
    if called then e.autoCalls, e.autoIdle = e.autoCalls + 1, 0 else e.autoIdle = (e.autoIdle or 0) + 1 end
    if err then U.logEvery("present.auto" .. pnum, 5000, TAG, "P%d auto pre-flight call failed: %s", pnum, tostring(err)) end
    -- budget: every map entry + afterburner, twice over, or ~3 s (12 MAIN ticks) with nothing left to call and the
    -- checks still underway; then stop trying (the checks stay manual)
    if (e.autoIdle > 12) or e.autoCalls > 2 * (count + 1) + 2 then
        if not e.autoGaveUp then
            e.autoGaveUp = true
            U.warn(TAG, "P%d pre-flight auto-complete: %d call(s) made, checks still underway (V-PRE-04)", pnum,
                e.autoCalls)
        end
        e.autoDone = true
    end
end

local function removeScreen(e)
    if e and U.ok(e.widget) then
        U.try(TAG, function() e.widget:RemoveFromParent() end)
    end
end

-- Our own screen for one local player, in that player's view.
local function ensureScreen(ign, cls, lp)
    local pc = lp.pc
    local k = U.key(pc)
    local e = ign.players[k]
    if e and U.ok(e.widget) then return e end
    local pawn = pc.Pawn
    if not U.isVehicle(pawn) then return nil end
    -- VERIFY(V-PRE-02): a WBP_IgnitionScreen_C created for a guest PC shows that guest's checks in the guest's view.
    local w = U.WBL():Create(pc, cls, pc) -- Create(WorldContextObject, WidgetType, OwningPlayer)
    if not U.ok(w) then
        U.logEvery("present.ignfail", 5000, TAG, "could not create the ignition screen for P%d", lp.index)
        return nil
    end
    local added = w:AddToPlayerScreen(tonumber(cfg.IgnitionZOrder) or 5)
    if cfg.IgnitionCopyInput ~= true then
        -- The screen's only binding is IA_Veh_Pause -> GetGfnPlayerController(self)->PauseForCutscene(!IsPaused), a
        -- TOGGLE: the hidden game screen and a P1 copy would both toggle on one press (no pause at all). The game's
        -- hidden screen keeps P1's pause; guests pause through pause.lua (pause CSM runs during IgnitionSequence).
        U.try(TAG, function() w:UnregisterInputComponent() end)
    end
    e = { pc = pc, widget = w, pnum = lp.index, pawnKey = 0, lastStatus = nil, listDone = false,
          added = (added == true) }   -- the game's screen is hidden only while every player's copy is on screen
    ign.players[k] = e
    U.log(TAG, "P%d ignition screen created (AddToPlayerScreen=%s)", lp.index, tostring(added))
    return e
end

-- A guest's copy was bound by Construct to GetPlayerPawn(0)'s (P1's) VehicleDelegates; SetupIgnitionBindings on the
-- guest car ADDS the guest bindings without removing P1's, so P1's ignite / perfect-start prompts animated P2's
-- screen. Every MAIN tick (the BP may bind late: its setup retries every 0.1 s) the copy's bindings are removed from
-- P1's car's OnIgnitionPhaseChanged / OnIgnitionStatusChanged with UE4SS's multicast-property API (3f4037d2:
-- GetBindings / Remove(target, FName)). If that API fails here, e.detachFailed: present.fastTick then re-syncs
-- the guest screens every FAST tick (~33 ms) so a P1 event shows for at most a frame.
-- VERIFY(V-PRE-02): the log line "P2 ignition screen detached from P1's car (n binding(s))"; no P1 prompt on P2.
local IGN_DELEGATES = { "OnIgnitionPhaseChanged", "OnIgnitionStatusChanged" }

local function detachFromP1(e)
    if e.pnum == 1 or e.detachFailed then return end
    local p1car
    pcall(function() p1car = U.p1().Pawn end)
    if not U.isVehicle(p1car) or U.same(p1car, e.pc.Pawn) then return end
    local ok, err = pcall(function()
        local vd = p1car.VehicleDelegates
        if not U.ok(vd) then return end
        local removed = 0
        for _, name in ipairs(IGN_DELEGATES) do
            local md = vd[name]
            local list = md:GetBindings() or {}
            for _, b in ipairs(list) do
                if U.same(b.Object, e.widget) then
                    md:Remove(e.widget, b.FunctionName)
                    removed = removed + 1
                end
            end
        end
        if removed > 0 then
            e.detached = (e.detached or 0) + removed
            U.log(TAG, "P%d ignition screen detached from P1's car (%d binding(s))", e.pnum, removed)
        end
    end)
    if not ok then
        e.detachFailed = true
        U.warn(TAG, "P%d ignition screen: cannot unbind P1's car delegates (%s): FAST re-sync instead", e.pnum,
            tostring(err))
    end
end

-- Keep one screen on its player's car: Construct bound it to GetPlayerPawn(0) (P1's car); re-point VehiclePawn and
-- rebind, then push the car's phase/status whenever the widget shows something else (detachFromP1 above removes
-- P1's delegates; when it cannot, the FAST re-sync limits P1's prompts to a frame).
local function syncScreen(e, comp)
    local w, pawn = e.widget, e.pc.Pawn
    if not U.isVehicle(pawn) then return end
    if e.pawnKey ~= U.key(pawn) then
        e.pawnKey = U.key(pawn)
        if e.pnum ~= 1 then
            pcall(function() w.VehiclePawn = pawn end)
            U.try(TAG, function() w:SetupIgnitionBindings() end)
        end
    end
    U.trace("ign", "P" .. e.pnum .. " sync: detach")
    detachFromP1(e)
    U.trace("ign", "P" .. e.pnum .. " sync: list")
    if comp and not e.listDone and comp.bAreChecksUnderway == true then
        e.listDone = true
        -- the list is built by the component's OnPreFlightChecksActivate; a screen made after it fired has none
        if U.arrayCount(w.PreFlightCheckLists) == 0 then U.try(TAG, function() w:AddPreflightChecksToList() end) end
    end
    U.trace("ign", "P" .. e.pnum .. " sync: state")
    local vs = pawn.VehicleState
    if not U.ok(vs) then return end
    local ph, shown = vs.IgnitionPhase, w.IgnitionPhase
    if type(ph) == "number" and type(shown) == "number" and ph ~= shown then
        U.try(TAG, function() w:OnIgnitionPhaseChanged(shown, ph) end)
    end
    local st = vs.IgnitionStatus
    if type(st) == "number" and e.lastStatus ~= nil and st ~= e.lastStatus then
        U.try(TAG, function() w["On Ignition Status Changed"](w, e.lastStatus, st) end)
    end
    e.lastStatus = st
end

---------------------------------------------------------------------------------------------------- loop
function M.clear()
    local ign = P()
    for _, e in pairs(ign.players or {}) do removeScreen(e) end
    if U.ok(ign.game) and ign.gameHidden then
        U.try(TAG, function() ign.game:SetRenderOpacity(1.0) end) -- the UIManager may reuse this instance
    end
    local ignpad = lazy("ignpad")
    if ignpad then U.try(TAG, ignpad.stop) end
    St.present.ign = { players = {} }
end

-- Why the mod completes this player's checks now (nil = it does not). ONLY the explicit fallback modes: autoComplete
-- reads the soft-keyed PreFlightChecksByAction map. 0.5.1: "auto" never completes (no soft pointer in "auto"); a
-- player whose ignpad input broke is logged once and keeps manual checks (they time out, the race starts).
local function completeWhy(mode, pnum, pc, s)
    local want = nil
    if mode == "complete" then want = "IgnitionMode complete" end
    if mode == "p1game_guestauto" and pnum ~= 1 then want = "guest, IgnitionMode p1game_guestauto" end
    if want then
        -- integration 0.5.1 (HARD RULE, two live UE4SS crashes from soft-object marshalling): autoComplete reads the
        -- soft-keyed map and passes a struct holding TSoftObjectPtr arrays. Only with the explicit opt-in
        -- cfg.IgnitionSoftComplete = true (run F3: it did not even work, "checks still underway"); otherwise that
        -- player's checks are left alone and time out (~5 s, the race starts normally).
        if cfg.IgnitionSoftComplete == true then return want end
        if not s.softSkipLogged then
            s.softSkipLogged = true
            U.log(TAG, "P%d checks left to the player/time-out (%s; no soft-pointer completion: IgnitionSoftComplete "
                .. "false)", pnum, want)
        end
        return nil
    end
    if (mode == "auto" or mode == "perplayer" or mode == "simple") and not s.brokenLogged then
        local ignpad = lazy("ignpad")
        local why = ignpad and ignpad.broken(pc) or nil
        if why then
            s.brokenLogged = true
            U.warn(TAG, "P%d pad input for the checks failed (%s): checks stay manual (no soft-pointer rescue in %s); "
                .. "fallback IgnitionMode = \"p1game_guestauto\"", pnum, tostring(why), mode)
        end
    end
    return nil
end

-- The game's own screen (P1's, viewport-wide, bound to P1's car at Construct, keeping P1's pause) is replaced by ours
-- ONLY while every local player with a car has its own copy really on screen; otherwise it is shown again.
local function gameScreenTick(ign, lps, perView, cls)
    local allOwn = perView and cls ~= nil
    if allOwn then
        local cars = 0
        for _, lp in ipairs(lps) do
            local hasCar = false
            pcall(function() hasCar = U.ok(lp.pc) and U.isVehicle(lp.pc.Pawn) end)
            if hasCar then
                cars = cars + 1
                local e = ign.players[U.key(lp.pc)]
                if not (e and e.added and U.ok(e.widget)) then allOwn = false end
            end
        end
        if cars == 0 then allOwn = false end
    end
    if allOwn then
        local g = findGameScreen(ign, cls)
        if g and not isOurs(ign, g) then
            if g:GetRenderOpacity() ~= 0 then g:SetRenderOpacity(0.0) end -- re-applied: the CSM may re-show it
            if not ign.gameHidden then
                ign.gameHidden = true
                U.log(TAG, "game's ignition screen hidden (%s): every player has its own", U.pathOf(g))
            end
        end
    elseif ign.gameHidden then
        ign.gameHidden = false
        U.try(TAG, function()
            if U.ok(ign.game) then ign.game:SetRenderOpacity(1.0) end
        end)
        U.log(TAG, "game's ignition screen shown again: a player has no own copy on screen (single view, "
            .. "IgnitionMode or AddToPlayerScreen failed)")
    end
end

-- MAIN loop (present.tick, race phases, 2+ local players).
function M.tick(lps)
    local ign = P()
    local mode = M.mode()
    local present = lazy("present")
    if not present then return end
    local active = present.stateActive("CSM_RF_IgnitionSequence") == true
    if not active or mode == "off" then
        if next(ign.players) ~= nil or ign.gameHidden or ign.began then M.clear() end
        return
    end
    ign.photo = photoModeActive(lps)
    if ign.photo then
        U.logEvery("ignition.photo", 10000, TAG, "photo mode active: ignition helpers paused")
        return
    end
    local ignpad = lazy("ignpad")
    if not ign.began then
        ign.began = true
        U.log(TAG, "ignition sequence: mode=%s view=%s simple=%s", mode, tostring(present.ignitionView()),
            tostring(mode == "simple" or cfg.IgnitionSimple == true))
        if ignpad then U.try(TAG, ignpad.begin) end
    end
    local perView = screensWanted(mode) and present.ignitionView() == "split" and not present.isSingleView()
    local cls = loadedClass(IGN_CLASS)
    -- couch-fix63 (#44 crash_2026_10_17_23_02_01, AV at UE4SS.dll+0x406911 0.08 ms after "P1 ignition screen created"):
    -- the ignition screen class (a hard reference of CSM_RF_IgnitionSequence, unloaded and reloaded with it) stays
    -- loaded for the session before any member of a screen is read by name (util.lua U.pinClass)
    if cls then U.pinClass(cls, "ignition screen") end
    local simple = (mode == "simple") or cfg.IgnitionSimple == true
    local padList = {}
    ign.state = ign.state or {}
    for _, lp in ipairs(lps) do
        if U.ok(lp.pc) then
            local k = U.key(lp.pc)
            local s = ign.state[k] or {}
            ign.state[k] = s
            U.trace("ign", "P" .. lp.index .. " pfcOf")
            local comp = pfcOf(lp.pc)
            if comp then
                U.trace("ign", "P" .. lp.index .. " traceChecks")
                traceChecks(s, comp, lp.index)
                U.trace("ign", "P" .. lp.index .. " traceIgnition")
                traceIgnition(s, lp.pc, lp.index)
                if simple and comp.bUseSimplePreflights ~= true then
                    -- VERIFY(V-PRE-05): writing the Bool directly simplifies the sequences like the settings toggle
                    pcall(function() comp.bUseSimplePreflights = true end)
                    s.simpleChanged = true
                end
                local why = completeWhy(mode, lp.index, lp.pc, s)
                if why and comp.bAreChecksUnderway == true then
                    if not s.completeLogged then
                        s.completeLogged = true
                        U.log(TAG, "P%d checks completed by the mod (%s)", lp.index, why)
                    end
                    autoComplete(s, comp, lp.index)
                end
            end
            local e = nil
            if perView and cls then
                U.trace("ign", "P" .. lp.index .. " ensureScreen")
                e = ensureScreen(ign, cls, lp)
                if e then
                    U.trace("ign", "P" .. lp.index .. " syncScreen")
                    syncScreen(e, comp)
                    if e.detachFailed then ign.anyDetachFailed = true end
                    if s.simpleChanged then
                        s.simpleChanged = nil
                        U.try(TAG, function() e.widget:OnSimplePreflightChanged() end)
                    end
                end
            end
            if comp and s.underway and not s.probed then
                s.probed = true
                U.trace("ign", "P" .. lp.index .. " probe")
                U.try(TAG, probe, lp, comp, e)
            end
            local screen = e and e.widget or nil
            if not screen and lp.index == 1 then screen = findGameScreen(ign, cls) end
            padList[#padList + 1] = { pc = lp.pc, pnum = lp.index, comp = comp, screen = screen,
                                      assist = assistFor(mode, lp.index) }
        end
    end
    -- Live run F (2026-10-07): the old ignpad.sync (soft-pointer map read) crashed UE4SS twice. 0.5.1 ignpad touches no
    -- soft pointer (it calls the PC's own action events); still only in the modes that use per-player pad input.
    -- (old comment:) only run it in the modes that
    -- need per-player pad input (auto/perplayer/simple). p1game_guestauto/complete/off never touch it.
    local padModes = { auto = true, perplayer = true, simple = true }
    if ignpad and padModes[mode] then U.try(TAG, ignpad.sync, padList) end
    gameScreenTick(ign, lps, perView, cls)
end

-- FAST loop (present.fastTick): pad polling while the ignition runs; guest screens re-synced every FAST tick while a
-- copy could not be detached from P1's car (detachFromP1).
function M.fastTick()
    local ign = P()
    if not ign.began or ign.photo then return end
    local ignpad = lazy("ignpad")
    local m = M.mode()
    if ignpad and (m == "auto" or m == "perplayer" or m == "simple") then ignpad.fastTick() end
    if not ign.anyDetachFailed then return end
    for _, e in pairs(ign.players) do
        if e.pnum ~= 1 and e.detachFailed and U.ok(e.widget) then
            local comp = nil
            pcall(function() comp = pfcOf(e.pc) end)
            U.try(TAG, syncScreen, e, comp)
        end
    end
end

return M
