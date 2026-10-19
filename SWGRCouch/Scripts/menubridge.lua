-- menubridge.lua (0.7.1, 0.7.2): a menu that the game hands to a guest (or a shared results screen) takes the player's A/B.
-- Run I (2026-10-07): in a split race the UIManager creates its screens for the last local PC (P2). P2's D-pad moves the
-- selection on a P2-owned screen (Slate navigation reads raw keys), but CommonUI's accept / back are Enhanced Input
-- actions (IA_UI_*) that reach a guest only while its IMC_UI sits above its vehicle IMC (pause.lua layer D, paused
-- only); P1's A does nothing on a P2-owned screen either, so the post-race "Race FINISHED" CONTINUE was a dead end.
-- Proven live: CommonButtonBase:HandleButtonClicked() on the selected button runs the button's normal click (RESUME
-- resumed the game). This module polls the local players' A/B edges (IsInputKeyDown works while paused) and, when the
-- game has not reacted within cfg.MenuBridgeWaitMs, clicks the selected button of the top screen itself.
-- Who is bridged (P1's own presses on P1's own screens work natively and are never touched):
--   * a screen owned by a guest: the owner's A/B (0.7.2: only while that guest's UI input is not native, see below);
--   * a pause screen owned by another player: A (clicks the entry the owner selected, RESUME by default);
--   * a shared post-race screen (class name with Result / PostRace / RunEnd / RunComplete / Recap): anyone's A
--     (P1 included: such a screen is P2-owned in a split race).
-- A = click the selected button (GetSelected), else the one with any user focus, else the screen's desired focus
-- target. B on a pause screen = click its RESUME button (btn_resumerace). Poll-based, no hooks, no soft pointers.
-- Config: cfg.MenuBridge = true|false, cfg.MenuBridgeWaitMs (150).
-- VERIFY(V-MB-01): P2 pauses, D-pad to an entry, A -> "[menubridge] P2 A -> WBP_PauseRacing_C btn_...: clicked";
--   RESUME resumes. V-MB-02: results screen, P1 or P2 A -> "... WBP_SimpleRaceResultsScreen_C WBP_Common_Btn_Continue:
--   clicked" and the race leaves to the front end. Fallback: MenuBridge = false.
-- Revision 0.7.2 (pause phase 2; facts in pause.lua's 0.7.2 header). Every key is read through opt() (defaults below):
--   * Native first (cfg.MenuBridgeGuestNative "skip" | "bridge" = 0.7.1): run I sessions 1627/1634 show a guest
--     resuming its own pre-created pause screen with no bridge click (its IMC_UI boosted). Bridging such a screen too
--     acts twice on any screen that stays up after A (a Settings row toggled back). A guest's presses on its OWN
--     screen are bridged only while pause.guestUiNative(pc) is false (post-race, a confirm dialog up, boost off).
--   * Confirm dialogs (cfg.MenuBridgeDialogs): pause.dialogWidget() (WBP_Modal_C = BoundActionNotificationWidget in the
--     persistent P1-owned Dialog container) is the top screen while up. The pause controller (pause.controller(): the
--     player the pause screens belong to) answers a dialog it does not own: A = the dialog button showing focus (else
--     the dialog's desired focus target, else the first = Accept / ResultID Yes), B = the last button (Cancel / No),
--     D-pad = move between the buttons (the dialog owner's focus follows). Every button is one Actions row of
--     DT_DialogData, created in that order in ButtonPanel_Dynamic; its native click = ReportResultAndRemove(Id).
--     P1 still answers natively. Post-race: any player. pause.lua lowers the guests' IMC_UI meanwhile (D2).
--   * B on a screen without RESUME (cfg.MenuBridgeBack): the screen's own back path: Blueprint HandleBack() (WBP_Settings
--     applies the settings first; WBP_PlayerMenu_Presentation), else OnCancelAction(ActionName) (the IA_UI_Cancel
--     handler), else FuseScreenWidget:BackToPreviousState() (the Logbook; OwningStateMachine->BackToPreviousState).
--   * Controller fallback (cfg.MenuBridgeControllerFallback): a pause screen owned by another player than the pause
--     controller (a page the pre-create missed) takes the controller's A/B; the controller gets Game+UI input on it.
--   * Front end (cfg.MenuBridgeProfileOwner): once guests exist the UIManager creates the main menu for the LAST local
--     PC, and its WBP_MP_ProfileCard (top right) shows GetOwningPlayer().PlayerState's name ("Player 2" after a split
--     race; read once at Construct). The card is a plain FuseUserWidget (not activatable: no CommonUI router state), so
--     SetOwningPlayer(P1) is safe; then the name text is rewritten and its BP events PvpRankUpdated /
--     PlatformIconUpdated re-read GetOwningPlayer(). The activatable main menu itself is never re-owned (its CommonUI
--     registration happened at construction). Own 1 s loop in FRONTEND / LAUNCHING only, no object-array scan.
-- VERIFY(V-MB-03): P2 pauses, SETTINGS, B -> P2's B natively back to the pause menu, or (boost off) "[menubridge] P2 B
--   -> WBP_Settings_C: HandleBack() (V-MB-03)"; LOGBOOK, B -> "... WBP_Stickerbook_C: BackToPreviousState()".
-- VERIFY(V-MB-04): P2 pauses and navigates its own Settings: "P2's own WBP_Settings_C takes P2's pad natively ...: not
--   bridged (V-MB-04)" once; a toggled setting is NOT toggled back 150 ms later.
-- VERIFY(V-MB-05): P2 pauses, EXIT TO MAIN MENU, A: "P2 A -> dialog WBP_Modal_C (Dialog:1) button 1/2 'Accept'
--   (focused | desired focus | first button = accept): clicked" -> main menu; B instead: "button 2/2 'Cancel' (last
--   button = cancel)" -> the dialog closes, P2's pause menu works again; D-pad: "P2 D-pad -> dialog ... button 2/2".
-- VERIFY(V-MB-10) (0.11.0): P2 pauses, D-pad down to RESTART RACE, A: "[menubridge] P2 A -> WBP_PauseRacing_C
--   Btn_RetryRace (owner focus): clicked (V-MB-01/02)" and the confirm dialog opens; A on RESUME resumes; no "takes P2's
--   pad natively" line for the pause menu (Settings keeps it for A); B in Settings: "P2 B -> WBP_Settings_C: HandleBack()
--   (V-MB-03)" and P2 is back on its pause menu. After RESTART RACE: "P2's native A / B did nothing on its own pause menu
--   (world #N): ... bridged until the next world" and P2's A toggles a Settings row once.
-- VERIFY(V-MB-06): back in the front end after a split race: "front-end profile card WBP_MP_ProfileCard: owner P2
--   (UIManager owner = last local PC) -> P1 ... name 'Player 2' -> '<account name>'"; the top right shows P1's name.

local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "menubridge"

local SCAN_MS = 250
local EXCLUDE = { "Hud", "HUD", "Container", "Notification", "Subtitles", "Tooltip", "MPC_Manager", "SaveGame",
    "Watermark", "Background", "Ignition", "Preflight", "Spectate" }
local SHARED = { "Result", "PostRace", "RunEnd", "RunComplete", "Recap" }
local DIALOG_CLASS = "/Script/Griffin.BoundActionNotificationWidget"
-- couch-fix62 (AUTO-151): the act-end recap's NEW UNLOCK screen
local function isUnlockCls(c) return type(c) == "string" and c:find("EndRunNewUnlocks", 1, true) ~= nil end
local PANEL_CLASS = "/Script/UMG.PanelWidget"

local S = { screens = {}, seenAt = {}, scanAt = -1e9, prevA = {}, prevB = {}, prevD = {}, prevS = {}, pending = nil, clicks = 0,
            inputOpened = {}, native = {}, fb = {}, dlg = nil, dlgAt = -1e9, dlgE = nil }
local KEYSET

-- cfg[k] when it has the type of the default d (keys config.lua does not list yet fall back to d)
local function opt(k, d)
    local v = cfg[k]
    if v == nil or type(v) ~= type(d) then return d end
    return v
end

local function enabled() return cfg.MenuBridge ~= false end

-- 0.15 COUCH CAMPAIGN (live 2026-10-14): screens whose accept never reaches P1's pad while couch.lua swaps the pad
-- ids (a ListenForInputAction accept, a list view, a P1-owned popup pair): P1's A (read on the PC that carries his
-- physical pad, id 0) runs the screen's own accept path. Matched by class name prefix, in every couch phase.
-- (couch-scaccept: renamed from COUCH_NATIVE / KEYS - a hot reload carries old module locals BY NAME into the new
-- code, so a table with new entries needs a new name to reach a running game)
local COUCH_SCREENS = {
    { "WBP_PostRace_RunEndRecap", "recap" },          -- CONTINUE = OnContinue(ActionName) (ListenForInputAction)
    { "WBP_RunMapOverview", "overview" },             -- NEXT PLANET / planet pick = OnAccept (IA_UI_Accept action)
    { "WBP_RunMap_Presentation", "nodemap" },         -- the event map: the focused node's click (IA_UI_Accept too)
    { "WBP_FE_Paddock_MysteryInteraction", "list" },  -- choices / result: the selected button's click
    { "WBP_StrikesNotification", "strikes" },         -- KNOCKED OUT / strike popups: the visible WBP_Hero_Btn
    -- BUG-14 (live 2026-10-14, 2P, with and without the park): on the paddock vendor's shop P1's D-pad moves his focus
    -- (Slate navigation) but his A and B do nothing - its part cards / pack buttons / CONTINUE are CommonButtons clicked
    -- through the screen owner's CommonUI (a guest while the ids are swapped). A = the CommonButton P1's Slate user
    -- focuses (never the CommonButton "selected" state: it lagged live and bought the wrong card), B = the screen's
    -- own back (BackToPreviousState; nothing on the pack picker, as natively). Native-acted check: P1's credits, the
    -- layout's switcher page and the screen's activation one tick before the press vs after the wait.
    { "WBP_Paddock_Shop_Presentation", "shop" },
    -- input matrix (couchsim pausepad / pausepost, live BUG-1 "P1's A dead on the paddock pause, D-pad works", 3P
    -- session): the paddock pause (WBP_PausePaddock_C) and a pause over the post-race screens belong to the screen owner
    -- like every native screen; their rows are CommonButtons clicked through the owner's CommonUI, and in the paddock
    -- this bridge only took COUCH_SCREENS screens. A = the row P1's pad focuses (native first: every row closes or covers
    -- the menu, so the wait re-check never clicks twice), B = RESUME (back()).
    { "WBP_Pause", "pause" },
    -- input matrix (couchsim viewbuild): P1's player menu (View Build, the map tab, ...) in the paddock: B = its own
    -- back (HandleBack) when the native B did nothing; its A stays native (tabs / pages act in place)
    { "WBP_PlayerMenu_Presentation", "menu" },
    -- P1 BLOCKER (live 2026-10-15 final-live, a NEW run with P2 joined): on the guest-owned pre-run LOADOUT (ids swapped
    -- and parked) P1's D-pad moved his cursor and RB opened the difficulty screen, but A on START RUN (WBP_Hero_Btn) did
    -- nothing - the CommonButton class of BUG-14 / the post-race buttons; its own HandleButtonClicked() from code
    -- started the run (LoadoutConfirmation). A = START RUN's own click, ONLY while P1's pad (the PC on id 0) focuses
    -- that button and the ids are swapped (his own screen otherwise: native); native first, with a longer wait
    -- (LOADOUT_WAIT_MS) and no click once his LoadoutConfirmation is up. Tiles / favour slots keep their native A.
    { "WBP_PreRun_LoadoutSelect", "loadout" },
    -- couch-scaccept (live 2026-10-17, P1 = Steam Controller through Steam Input, P2 = DS4): the paddock BACKER /
    -- sponsor contract screen (CSM_Paddock_SelectSponsorChoice, owned by the last local PC). P1's D-pad moved the
    -- highlight, his A and VIEW BUILD did nothing: its three WBP_SponsorChoice_Btn_C are FuseButtons (CommonButtons)
    -- with no input action of their own (the BUG-14 / START RUN / post-race class), and the screen registers NO action
    -- binding (decoded: VIEW BUILD is not the screen's - its IA_UI_PlayerMenu belongs to another router, unreachable
    -- while P1's PC is parked). A = the focused contract's own click (HandleButtonClicked -> BP_OnClicked ->
    -- OnSponsorSelected -> WBP_SponsorSelect_Content:OnSponsorChosen: PaddockGameState:ChooseSponsor + the CSM's
    -- ContinueToNextState); VIEW = the player menu the way the paddock screens open it (CSM_PauseMenus_PlayerMenu).
    -- NOTE: the screen's own BndEvt__..OnSponsorButtonClicked / OnSponsorChosen are EMPTY on WBP_SponsorSelectBase
    -- (decoded; live 17:34 / 17:36 calls did nothing) - only the content's chain chooses.
    { "WBP_SponsorSelect", "sponsor" },
    -- couch-scaccept (live 2026-10-17): P1's OWN garage (root + Choose Model / Edit Vehicle / Edit Livery pages) while
    -- the ids are swapped for it (a guest's garage turn is garagenative's: not bridged here). D-pad native; B on a
    -- page = the page's back when the game did not act (CommonUI default back of the page owner's router).
    -- couch-p1garage (finding #27, round 2: CHOOSE MODEL / EDIT VEHICLE / EDIT LIVERY not clickable with P1's Steam
    -- Controller): his A on the ROOT enters the hero page his focus is on (garagenative.ownEnter: the root's own BndEvt),
    -- his A on a PAGE clicks the option entry he focuses (never a hold / locked one), his LB / RB step the page's tabs -
    -- each only when the game did not act within the wait (state machine / screen / tab / selection unchanged).
    { "WBP_Paddock_VehicleCust", "garage" },
}
-- couch-scaccept: every OTHER guest-owned paddock screen while the ids are swapped ("generic"): P1's A clicks the
-- CommonButton his pad focuses inside it and his B runs the screen's own HandleBack / OnCancelAction, each ONLY when the
-- game did not act within the wait (screen still activated, nothing new on top, no CosmeticStateMachine change).
-- Never a hold button (purchases) or a locked one. Classes here never get the generic bridge (own modules / wrappers).
local GENERIC_SKIP = { "Holder", "Skip_Cinematic", "PreRun_VehicleSelect", "SideBet", "Challenge", "Paddock_HUD",
    "MenuOverlay", "Stickerbook", "Tooltip" }
local function couchNative(n)
    for _, e in ipairs(COUCH_SCREENS) do
        if n:sub(1, #e[1]) == e[1] then
            if e[2] == "shop" and cfg.CouchShopBridge == false then return nil end
            return e[2]
        end
    end
    return nil
end

-- 0.15 COUCH CAMPAIGN map hosts: the screen that hosts the planet overview + the event map and moves the campaign on
-- (decoded kismet: WBP_Paddock_NextEvent_Presentation @1761-2138, WBP_PostRace_Cam_Holder_Presentation @3261-3343,
-- @8038-8141, @15, @2757). Their bound events ARE the native continuation of the overview / node clicks, and their
-- CSM state is the one the screen goes to; both are used as fallbacks when the native input path did nothing.
local CSM_DIR_PADDOCK = "/Game/Griffin/Gameplay/Paddock/StateMachine/"
local CSM_DIR_RF = "/Game/Griffin/Config/StateMachines/RaceFlow/"
local MAP_HOSTS = {
    WBP_Paddock_NextEvent_Presentation_C = {
        kind = "paddock",
        planet = "CustomEvent",                       -- (Index, PlanetDef): switcher -> node map of that planet
        node = "BndEvt__WBP_Paddock_NextEvent_Presentation_WBP_RunMap_Pres_K2Node_ComponentBoundEvent_0_OnMapNodeClicked__DelegateSignature",
        nodeCsm = CSM_DIR_PADDOCK .. "CSM_Paddock_StartLaunchingEvent.CSM_Paddock_StartLaunchingEvent",
    },
    WBP_PostRace_Cam_Holder_Presentation_C = {
        kind = "postrace",
        planet = "BndEvt__WBP_PostRace_Cam_Holder_Presentation_WBP_RunMapOverview_Presentation_K2Node_ComponentBoundEvent_2_OnPlanetSelected__DelegateSignature",
        planetCsm = CSM_DIR_RF .. "CSM_RF_Results_Campaign_EndOfPlanet.CSM_RF_Results_Campaign_EndOfPlanet",
        node = "BndEvt__WBP_PostRace_Cam_Holder_WBP_RunMap_Pres_K2Node_ComponentBoundEvent_1_OnMapNodeClicked__DelegateSignature",
        nodeCsm = CSM_DIR_RF .. "CSM_RF_Results_Campaign_StartTravelToNextNode.CSM_RF_Results_Campaign_StartTravelToNextNode",
    },
}
M.MAP_HOSTS = MAP_HOSTS
local function waitMs()
    local v = tonumber(cfg.MenuBridgeWaitMs)
    return (v and v >= 0) and v or 150
end
-- START RUN's native click opens the confirmation through the UIManager (a class load can take a few frames): the
-- bridge waits longer there before it decides the native A did nothing
local LOADOUT_WAIT_MS = 400
-- couch-scaccept kinds: the pad-watch edge can arrive ~50-110 ms after the key-down (DLL file every 50 ms + 60 ms read
-- cache), so the native-first wait is longer there
local PW_WAIT_MS = 300

local function keys()
    if KEYSET then return KEYSET end
    KEYSET = { A = { KeyName = U.fname("Gamepad_FaceButton_Bottom") }, B = { KeyName = U.fname("Gamepad_FaceButton_Right") },
             Enter = { KeyName = U.fname("Enter") }, Start = { KeyName = U.fname("Gamepad_Special_Right") },
             Up = { KeyName = U.fname("Gamepad_DPad_Up") }, Down = { KeyName = U.fname("Gamepad_DPad_Down") },
             Left = { KeyName = U.fname("Gamepad_DPad_Left") }, Right = { KeyName = U.fname("Gamepad_DPad_Right") },
             View = { KeyName = U.fname("Gamepad_Special_Left") } }
    return KEYSET
end

local function cls(o)
    if not U.ok(o) then return "?" end   -- U.ok FIRST: GetClass on a null wrapper is a native AV (UE4SS.dll+0x2ace67 null+0x10) that pcall cannot catch
    local n = U.className(o)                 -- the class is U.ok'ed too (FINDING #31: GetFName on a NULL class = AV +0x18)
    return n ~= "" and n or "?"
end

local function lname(o)
    local n = U.objName(o)                   -- U.ok inside: GetFName on a null wrapper is a native AV ([obj+0x18])
    return n ~= "" and n or "?"
end

local function hasAny(s, list)
    for _, k in ipairs(list) do if s:find(k, 1, true) then return true end end
    return false
end

local function pnumOf(pc)
    if not U.ok(pc) then return nil end
    for _, e in ipairs(U.localPlayersRO()) do
        if U.ok(e.pc) and U.key(e.pc) == U.key(pc) then return e.index end
    end
    return nil
end

local function pcOf(p)
    for _, e in ipairs(U.localPlayersRO()) do
        if e.index == p and U.ok(e.pc) then return e.pc end
    end
    return nil
end

local function ownerP(w)
    local ok, o = pcall(U.callMethod, w, "GetOwningPlayer")
    if ok then return pnumOf(o) end
    return nil
end

local classCache = {}
local function classOf(path)
    local c = classCache[path]
    if c and U.ok(c) then return c end
    local ok, o = pcall(StaticFindObject, path)
    c = (ok and U.ok(o)) and o or nil
    classCache[path] = c
    return c
end

local function isA(w, path)
    local c = classOf(path)
    if not c then return false end
    local ok, r = pcall(U.callMethod, w, "IsA", c)
    return ok and r == true
end

-- pause.lua's 0.7.2 exports, pcall-guarded (nil when unavailable)
local function pauseCall(name, ...)
    local ok, pm = pcall(U.mod, "pause")
    if not ok or type(pm) ~= "table" or type(pm[name]) ~= "function" then return nil end
    local ok2, a, b = pcall(pm[name], ...)
    if ok2 then return a, b end
    return nil
end

local function pausedNow() return St.pause ~= nil and St.pause.menuWasPaused == true end

-- the pause controller's P-number (pause.controller(): the player the pause screens belong to); nil when not paused
local function controllerP()
    if not pausedNow() then return nil end
    return pnumOf(pauseCall("controller"))
end

-- activated screens on screen, most recently activated first (refreshed every SCAN_MS; force = now)
---------------------------------------------------------------------------------------------------- couch-scaccept helpers
local function couchCsmSeq()
    local ok, v = pcall(function() return U.mod("couch").csmSeq() end)
    return ok and v or 0
end
local function couchSwapped()
    local ok, v = pcall(function() return U.mod("couch").swapped() end)
    return ok and v == true
end
-- a guest's garage turn (garagenative drives every garage screen itself)
local function guestTurn()
    local gn = package.loaded["garagenative"]
    if type(gn) ~= "table" or type(gn.active) ~= "function" then return false end
    local ok, v = pcall(gn.active)
    return ok and v == true
end
local GARAGE_PAGES = { "WBP_Paddock_VehicleCustThemeOptions_C", "WBP_Paddock_VehicleCustPartsOptions_C",
    "WBP_Paddock_VehicleCustLiveryOptions_C", "WBP_Paddock_VehicleCustLiveryOptionsBase_C",
    "WBP_Paddock_VehicleCustLiveryColour_C", "WBP_Paddock_VehicleCustLiveryTemplate_C", "WBP_Paddock_VehicleCustPatina_C" }
-- P1's own garage open while swapped and no garage page in the shared scan list: the activated pages found by class
-- (at most every 500 ms; the result is kept in between) -> { {w, k, cls, p1}... }
local function garagePages(now, list)
    if not couchSwapped() or guestTurn() then S.gp = nil; return {} end
    for _, e in ipairs(list) do
        if type(e.cls) == "string" and e.cls:find("VehicleCust", 1, true) and e.cls ~= "WBP_Paddock_VehicleCust_C" then
            S.gp = nil
            return {}
        end
    end
    local okG, open = pcall(function() return U.mod("couch").garageOpen() end)
    if not (okG and open == true) then S.gp = nil; return {} end
    if S.gp and now - S.gp.at < 500 then
        local keep = {}
        for _, e in ipairs(S.gp.list) do if U.alive(e.w) then keep[#keep + 1] = e end end
        return keep
    end
    local out = {}
    for _, cn in ipairs(GARAGE_PAGES) do
        for _, w in ipairs(FindAllOf(cn) or {}) do
            if U.ok(w) and U.alive(w) then
                local act = false
                pcall(function() act = w:IsActivated() == true end)
                -- (not activated but on screen: the page CommonUI did not activate for its owner still is the one shown)
                if not act then pcall(function() act = w:IsInViewport() == true and w:IsVisible() == true end) end
                if act then out[#out + 1] = { w = w, k = U.key(w), cls = cn, p1 = false, page = true } end
            end
        end
    end
    if #out > 0 and S.gpLogged ~= out[1].k then
        S.gpLogged = out[1].k
        U.log(TAG, "couch: P1's garage page %s found by class (not in the shared scan): bridged as a garage screen", out[1].cls)
    end
    S.gp = { at = now, list = out }
    return out
end

-- P1's PHYSICAL pad's A / B / VIEW press edges from swgr_inputfilter.dll's PAD WATCH (inputfix.padPresses: per Slate
-- UserIndex, before any LocalPlayer / CommonUI routing - the same for an XInput pad, a DS4, a Steam Input virtual pad
-- or a vpad). The pad = P1's ORIGINAL id (0). -> { a, b, view } booleans (each true once per press); all false without
-- the DLL's pad watch. The first read only sets the baseline.
local PW_FIELDS = { "a", "b", "view" }
local function padEdges()
    local out = { a = false, b = false, view = false }
    if opt("CouchPadWatchBridge", true) == false then S.pw = nil; return out end
    local IF = package.loaded["inputfix"]
    if type(IF) ~= "table" or type(IF.padPresses) ~= "function" then return out end
    local okW, on = pcall(function() return IF.padWatch() end)
    if not (okW and on == true) then return out end
    local okP, pads = pcall(IF.padPresses)
    if not okP or type(pads) ~= "table" then return out end
    local uid = 0
    pcall(function()
        local o = U.mod("couch").originalIdOf(pcOf(1))
        if type(o) == "number" then uid = o end
    end)
    local e = pads[uid]
    local prev = S.pw
    if type(e) ~= "table" then
        if not prev or prev.uid ~= uid then S.pw = { uid = uid, a = 0, b = 0, view = 0 } end
        return out
    end
    if prev and prev.uid == uid then
        for _, f in ipairs(PW_FIELDS) do
            if (tonumber(e[f]) or 0) > (tonumber(prev[f]) or 0) then out[f] = true end
        end
    end
    S.pw = { uid = uid, a = tonumber(e.a) or 0, b = tonumber(e.b) or 0, view = tonumber(e.view) or 0 }
    return out
end
M.padEdges = padEdges
-- the kinds whose P1 presses also come from the pad watch / the owner's IA_UI_Accept (IsInputKeyDown never sees them:
-- a focused CommonButton consumes the key in Slate, live 2026-10-15 / 2026-10-17)
-- #64 (tester #3, Sentinel I eliminator, both players out): two WBP_StrikesNotification_C stacked, P1's A reached
-- neither (no focus, IsInputKeyDown saw nothing, menubridge never ran): strikes take the pad watch too
local PW_KINDS = { sponsor = true, garage = true, generic = true, strikes = true }

-- couch-rewards2 STEP 2 (couchfence.lua): P1's reward flow takes P1's PAD only = the PC holding pad id 0
local function p1Reward(n)
    local okF, F = pcall(require, "couchfence")
    return okF and type(F) == "table" and F.isP1Reward(n) == true
end
local function holdsPad0(pc)
    local id = nil
    pcall(function() id = U.cdo("GameplayStatics"):GetPlayerControllerID(pc) end)
    return id == 0
end

local function scan(now, force)
    if not force and now - S.scanAt < (S.couchMode and 100 or SCAN_MS) then return end
    S.scanAt = now
    local list, alive = {}, {}
    S.host = nil
    -- couch: couch.lua's shared scan (class-filtered, alive, activated, cached) instead of a second FindAllOf
    local src, pre = nil, nil
    if S.couchMode then
        local okA, l = pcall(function() return U.mod("couch").activeScreens() end)
        if okA and type(l) == "table" then
            src, pre = {}, {}
            for i, e in ipairs(l) do src[i] = e.w; pre[e.w] = e end
            -- couch-scaccept: P1's own garage pages missing from the shared scan (live: CHOOSE MODEL never listed)
            for _, e in ipairs(garagePages(now, l)) do src[#src + 1] = e.w; pre[e.w] = e end
        end
    end
    local swapped = S.couchMode and couchSwapped()
    for _, w in ipairs(src or FindAllOf("CommonActivatableWidget") or {}) do
        local pe = pre and pre[w]
        local n = (pe and pe.cls) or cls(w)
        local cnat = S.couchMode and n:sub(1, 4) == "WBP_" and couchNative(n) or nil
        if cnat == "garage" and not (swapped and not guestTurn()) then cnat = nil end
        if cnat == "sponsor" and not swapped then cnat = nil end              -- his own screen (no guest): native
        if not cnat and swapped and St.phase == "OTHER" and pe and not pe.p1 and n:sub(1, 4) == "WBP_"
            and not hasAny(n, EXCLUDE) and not hasAny(n, GENERIC_SKIP) and not MAP_HOSTS[n]
            and opt("CouchGenericBridge", true) then
            cnat = "generic"
        end
        if cnat == "nodemap" and U.alive(w) then                         -- the player menu's map tab is display only
            local inter = true
            pcall(function() inter = w.AreMapNodesInteractable ~= false end)
            if not inter then cnat = nil end
        end
        if n:sub(1, 4) == "WBP_" and (cnat or not hasAny(n, EXCLUDE)) and U.alive(w) then
            local act, shown = false, false
            pcall(function() act = w:IsActivated() == true end)
            if not act and pe and pe.page then act = true end              -- garagePages checked it (shown, not activated)
            -- couch: "shown" is remembered per widget (a screen's place in the tree does not change while it lives)
            local sk = U.key(w)
            S.shownK = S.shownK or {}
            if act and S.couchMode and S.shownK[sk] then shown = true
            elseif act then
                pcall(function() shown = w:IsInViewport() == true or U.ok(w:GetParent()) end)
                if shown and S.couchMode then S.shownK[sk] = true end
            end
            -- couch-fix54 (AUTO-133): an activated page hidden in its switcher (the post-race holder's ActFinish page
            -- while the RESULTS show) is no press target: the newest-seen rule clicked its hidden CONTINUE forever
            if act and shown and S.couchMode and pe and not pe.p1 and not pe.page then
                local okH, hid = pcall(function() return U.mod("couch").inactivePage(w, now, n) end)
                if okH and hid == true then shown = false end
            end
            if act and shown then
                local k = U.key(w)
                if MAP_HOSTS[n] and S.couchMode then S.host = { w = w, k = k, cls = n, def = MAP_HOSTS[n] } end
                alive[k] = true
                S.seenAt[k] = S.seenAt[k] or now
                list[#list + 1] = { w = w, k = k, cls = n, at = S.seenAt[k], shared = hasAny(n, SHARED),
                                    dialog = isA(w, DIALOG_CLASS), cnat = cnat, p1Reward = p1Reward(n) }
            end
        end
    end
    for k in pairs(S.seenAt) do if not alive[k] then S.seenAt[k] = nil end end
    table.sort(list, function(a, b) return a.at > b.at end)
    S.screens = list
    -- couch-fix62 (AUTO-151): when a NEW UNLOCK screen was last up (the act-end recap's quiet time counts from it)
    if S.couchMode then
        for i = 1, #list do if isUnlockCls(list[i].cls) then S.unlockAt = now; break end end
    end
end

-- 0.7.2: the confirm dialog on screen as a screen entry (pause.dialogWidget, every 100 ms at most), else nil
local function dialogEntry(now, force)
    if not force and now - S.dlgAt < 100 then
        if S.dlgE and U.ok(S.dlgE.w) then return S.dlgE end
        return nil
    end
    S.dlgAt = now
    local w, where = pauseCall("dialogWidget")
    if U.ok(w) then
        S.dlgE = { w = w, k = U.key(w), cls = cls(w), at = now, dialog = true, where = where }
    else
        S.dlgE = nil
    end
    return S.dlgE
end

-- the screen a press acts on: a confirm dialog first, else the most recently activated screen
local function top(now, force)
    local d = dialogEntry(now, force)
    if d then return d end
    if S.couchMode then                                   -- couch: a screen P1's pad cannot reach natively wins
        for _, c in ipairs(S.screens) do if c.cnat and c.cnat ~= "generic" and U.alive(c.w) then return c end end
        -- couch-scaccept: the generic bridge only for a guest screen no module knows (and no known one is up)
        for _, c in ipairs(S.screens) do if c.cnat == "generic" and U.alive(c.w) then return c end end
    end
    -- U.alive: S.screens is up to SCAN_MS old and a screen closed since is garbage (a UFunction on it = the crash
    -- class of 2026-10-14; couchsim soak 12 4 hit it on the event map once menubridge ran in the paddock)
    local e = S.screens[1]
    if e and U.alive(e.w) then return e end
    return nil
end

-- the screen's selected / focused CommonButton (buttons whose outer chain reaches the screen). 0.11.0: the button the
-- screen's OWNER has focused comes first: the pause menu keeps RESUME selected while its owner's d-pad moves the focus
-- (live 2026-10-10, hotfix build: P2 on RESTART RACE, A, and the bridge clicked RESUME)
local function selectedButton(screen)
    local owner
    pcall(function() owner = screen:GetOwningPlayer() end)
    if not U.ok(owner) then owner = nil end
    local best, focused, ownerF
    for _, b in ipairs(FindAllOf("CommonButtonBase") or {}) do
        local inside = false
        pcall(function()
            local x = U.outerOf(b)               -- U.ok inside: GetOuter on a null / dead entry is a native AV
            for _ = 1, 8 do
                if not U.ok(x) then break end
                if U.key(x) == U.key(screen) then inside = true; break end
                x = U.outerOf(x)
            end
        end)
        if inside then
            local sel, foc, vis, of = false, false, true, false
            pcall(function() sel = b:GetSelected() == true end)
            pcall(function() foc = b:HasAnyUserFocus() == true or b:HasFocusedDescendants() == true end)
            pcall(function() local v = b:GetVisibility(); vis = (v ~= 1 and v ~= 2) end)
            if owner then
                pcall(function() of = b:HasUserFocus(owner) == true or b:HasUserFocusedDescendants(owner) == true end)
            end
            if vis and of and not ownerF then ownerF = b end
            if vis and sel and not best then best = b end
            if vis and foc and not focused then focused = b end
        end
    end
    if ownerF then return ownerF, "owner focus" end
    if best then return best, "selected" end
    if focused then return focused, "focused" end
    local okT, t = pcall(U.callMethod, screen, "GetDesiredFocusTarget")
    if okT and U.ok(t) then
        local isBtn = pcall(U.callMethod, t, "GetSelected")
        if isBtn then return t, "desired focus" end
    end
    return nil, "no button"
end

---------------------------------------------------------------------------------------------------- dialogs (0.7.2)
-- The dialog's dynamic buttons (BoundActionNotificationWidget.ButtonPanel_Dynamic children = DT_DialogData Actions in
-- order: Accept/Yes first, Cancel/No last), visible ones only.
local function dialogButtons(w)
    local list = {}
    local panel
    pcall(function() panel = w.ButtonPanel_Dynamic end)
    if not U.ok(panel) then return list end
    local n = 0
    pcall(function() n = math.tointeger(tonumber(panel:GetChildrenCount())) or 0 end)
    for i = 0, n - 1 do
        local b
        pcall(function() b = panel:GetChildAt(i) end)
        if U.ok(b) then
            local vis = true
            pcall(function() local v = b:GetVisibility(); vis = (v ~= 1 and v ~= 2) end)
            if vis then list[#list + 1] = b end
        end
    end
    return list
end

-- the button the dialog shows focused (any user, the button or a descendant), else the dialog's desired focus target
local function dialogIndex(list, w)
    for i, b in ipairs(list) do
        local f = false
        pcall(function() f = b:HasAnyUserFocus() == true or b:HasFocusedDescendants() == true end)
        if f then return i, "focused" end
    end
    local t
    pcall(function() t = w:GetDesiredFocusTarget() end)
    if U.ok(t) then
        local tk = U.key(t)
        for i, b in ipairs(list) do
            if U.key(b) == tk then return i, "desired focus" end
        end
    end
    return nil, nil
end

-- the button's label (WBP_Modal_Btn_C.ButtonLabel, an FText) or its object name
local function label(b)
    local s
    pcall(function() s = U.str(b.ButtonLabel) end)
    if type(s) == "string" and s ~= "" and not s:find("^userdata") then return s end
    return lname(b)
end

-- A = the D-pad pick, else the focused / desired-focus button, else the first (Accept); B = the last (Cancel).
local function dialogPress(e, p, what)
    local list = dialogButtons(e.w)
    local b, how, i
    if #list > 0 then
        if what == "B" then
            i, how = #list, "last button = cancel"
        elseif S.dlg and S.dlg.k == e.k and list[S.dlg.i] then
            i, how = S.dlg.i, "D-pad pick"
        else
            i, how = dialogIndex(list, e.w)
            if not i then i, how = 1, "first button = accept" end
        end
        b = list[i]
    elseif what == "A" then
        b, how = selectedButton(e.w)                  -- a custom dialog widget without dynamic buttons
    end
    if not U.ok(b) then
        U.logEvery("mb.dlg" .. e.cls, 5000, TAG, "P%d %s on dialog %s: %s, nothing clicked (V-MB-05)", p, what, e.cls,
            tostring(how or "no dynamic button"))
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks, S.dlg = S.clicks + 1, nil
    U.log(TAG, "P%d %s -> dialog %s (%s) button %s '%s' (%s): %s (V-MB-05)", p, what, e.cls, tostring(e.where or "-"),
        i and string.format("%d/%d", i, #list) or "-", label(b), tostring(how),
        ok and "clicked" or ("error " .. tostring(err)))
end

-- D-pad: the pick moves between the dialog's buttons; the dialog owner's focus follows (the highlight everyone sees)
local function dialogMove(e, p, dir)
    local list = dialogButtons(e.w)
    if #list < 2 then return end
    local cur = (S.dlg and S.dlg.k == e.k and S.dlg.i) or dialogIndex(list, e.w) or 1
    local i = math.max(1, math.min(#list, cur + dir))
    S.dlg = { k = e.k, i = i }
    local owner
    pcall(function() owner = e.w:GetOwningPlayer() end)
    local moved = U.ok(owner) and pcall(function() list[i]:SetUserFocus(owner) end)
    U.log(TAG, "P%d D-pad -> dialog %s button %d/%d '%s' (%s) (V-MB-05)", p, e.cls, i, #list, label(list[i]),
        moved and "the dialog owner's focus follows" or "picked for A")
end

---------------------------------------------------------------------------------------------------- clicks
-- B: a pause screen's RESUME (0.7.1); else (0.7.2) the screen's own back path: its Blueprint HandleBack()
-- (WBP_Settings applies the settings first; WBP_PlayerMenu_Presentation), else OnCancelAction(ActionName) (an
-- IA_UI_Cancel handler), else FuseScreenWidget:BackToPreviousState() (the Logbook). A missing UFunction is an invalid
-- object without __call in UE4SS (handle_unreal_property_value): calling it raises, so pcall tells the paths apart.
-- couch-fix50 (AUTO-128): a bridged leave of the Scrap Dealer's landing runs its own back handler's node completion
-- first (couchpanel.stopNodeComplete: BackToPreviousState alone left the BlackMarket node open, 0 choosable nodes)
local function stopNodeComplete(e, why)
    local CP = package.loaded["couchpanel"]
    if type(CP) ~= "table" or type(CP.stopNodeComplete) ~= "function" then return end
    U.try(TAG, CP.stopNodeComplete, e.w, why)
end

local function back(e, p)
    local b
    pcall(function() b = e.w.btn_resumerace end)
    if U.ok(b) then
        local ok, err = pcall(function() b:HandleButtonClicked() end)
        S.clicks = S.clicks + 1
        U.log(TAG, "P%d B -> %s %s (back = resume): %s (V-MB-01)", p, e.cls, lname(b),
            ok and "clicked" or ("error " .. tostring(err)))
        return
    end
    if not opt("MenuBridgeBack", true) then
        U.logEvery("mb.noback" .. e.cls, 5000, TAG, "P%d B on %s: no RESUME button, MenuBridgeBack off", p, e.cls)
        return
    end
    local how
    if pcall(function() e.w:HandleBack() end) then
        how = "HandleBack()"
    elseif pcall(function() e.w:OnCancelAction(U.fname("IA_UI_Cancel")) end) then
        how = "OnCancelAction()"
    else
        stopNodeComplete(e, "P" .. tostring(p) .. "'s B")              -- couch-fix50 AUTO-128
        if pcall(function() e.w:BackToPreviousState() end) then how = "BackToPreviousState()" end
    end
    S.clicks = S.clicks + 1
    U.log(TAG, "P%d B -> %s: %s (V-MB-03)", p, e.cls,
        how or "no back path (HandleBack / OnCancelAction / BackToPreviousState all failed)")
end

-- the visible button of class pattern pat inside screen w (outer chain), else nil
local function buttonInside(w, pat)
    local wk = U.key(w)
    for _, b in ipairs(FindAllOf("CommonButtonBase") or {}) do
        if U.ok(b) and cls(b):find(pat, 1, true) then
            local inside, vis = false, false
            pcall(function()
                local x = U.outerOf(b)
                for _ = 1, 8 do
                    if not U.ok(x) then break end
                    if U.key(x) == wk then inside = true; break end
                    x = U.outerOf(x)
                end
            end)
            pcall(function() vis = b:IsVisible() == true end)
            if inside and vis then return b end
        end
    end
    return nil
end

local overviewAccept, nodeAccept
---------------------------------------------------------------------------------------------------- couch map screens
-- 0.15 COUCH CAMPAIGN: the planet overview and the event map (paddock: WBP_Paddock_NextEvent_Presentation, post-race:
-- WBP_PostRace_Cam_Holder_Presentation). P1's pad reaches them natively once couch.lua boosts the screen owner's IMC_UI
-- (the root cause); the bridge acts only when the native press did nothing (no progress since the press) and then
-- walks the native chain itself, step by step, each step only while the previous one left the screen where it was:
--   overview: OnAccept -> (1.2 s) the host's own planet-selected event -> post-race (+4.5 s) the host CSM's
--             EndOfPlanet state -> (+3.5 s) CampaignSubsystem:TravelToNextPlanet();
--   node map: the focused node button's click -> (1.5 s) the host's own node-clicked event (ChooseNextMapNode + its
--             CSM change) -> (+2 s, a node chosen but the map still up) the host CSM's next state directly.
-- Why PaddockGameState:TravelToNextActivity / CampaignSubsystem:TravelToNextMapNode were "ignored" with the map open:
-- the paddock CSM was still in its EventSelect state; the native path is ChooseNextMapNode + ChangeToState(
-- CSM_Paddock_StartLaunchingEvent) -> DoLaunchEvent -> BP_Csm_Paddock_StartLaunchingEvent -> TravelToNextActivity
-- (decoded: WBP_Paddock_NextEvent_Presentation @2035-2138, notes 03 §2.5). The fallback goes through that CSM state.
local function findL(path)
    if type(U.findLoaded) == "function" then
        local o = U.findLoaded(path, 1000)
        if o then return o end
    end
    local ok, o, found = pcall(LoadAsset, path)
    if ok and U.ok(o) then return o end
    local ok2, o2 = pcall(StaticFindObject, path)
    return (ok2 and U.ok(o2)) and o2 or nil
end

local function stillActive(w)
    local up = false
    pcall(function() up = U.ok(w) and w:IsActivated() == true end)
    return up
end

local function animating(w)
    local b = false
    pcall(function() b = w:IsAnyAnimationPlaying() == true end)
    return b
end

-- the chosen, not completed node of the run (its object key), 0 = none
local function chosenNodeKey()
    local k = 0
    pcall(function()
        local nodes = FindFirstOf("CampaignSubsystem").ActiveRun.Map.mNodes
        for i = 1, U.arrayCount(nodes) do
            local nd = nodes[i]
            if U.ok(nd) and nd.bHasBeenChosen == true and nd.bHasBeenCompleted ~= true then k = U.key(nd) end
        end
    end)
    return k
end
M.chosenNodeKey = chosenNodeKey

local function hostCsm(host, assetPath, why)
    local asset = findL(assetPath)
    if not asset then return false, "CSM asset not loaded" end
    local ok, err = pcall(function() host.w.OwningStateMachine:ChangeStateTo(asset, "SWGRCouch: " .. why, nil) end)
    return ok, err
end

-- the planet the selector shows as current (its own index, as the overview's SelectPlanet compares) + its VM
local function currentPlanet(ov)
    local idx, def = nil, nil
    pcall(function()
        local sel = ov.WBP_PlanetSelector
        idx = math.tointeger(tonumber(sel["Current Planet Idx"]))
        local cur = math.tointeger(tonumber(sel.SelectedIndex))
        if idx == nil or idx < 0 then idx = cur end
        if idx ~= nil and idx >= 0 then def = sel.PlanetVMs[idx + 1] end
    end)
    return idx, def
end

local chain = { gen = 0 }
local mapHeld
local function chainStep(name, ms, fn)
    local gen, world = chain.gen, St.worldGen
    sched.after("mb.chain." .. name, ms, function()
        if gen ~= chain.gen or world ~= St.worldGen then return end
        -- couch-fix51: a chain step armed before the reward map hold began never picks / travels during it
        if mapHeld({ cls = "the map chain (" .. name .. ")" }) then return end
        U.try(TAG, fn)
    end)
end

-- couch-fix32: the reward split holds P1's run map while a guest is still choosing his rewards (couchpanel.mapHeld)
mapHeld = function(e)
    local okP, CP = pcall(U.mod, "couchpanel")
    if not (okP and type(CP) == "table" and type(CP.mapHeld) == "function") then return false end
    local ok, held = pcall(CP.mapHeld)
    if ok and held == true then
        U.logEvery("mb.maphold", 3000, TAG, "couch: P1's A on %s held: a guest is still choosing his rewards", tostring(e.cls))
        return true
    end
    return false
end

overviewAccept = function(e, p)
    if mapHeld(e) then return end
    if animating(e.w) then
        U.log(TAG, "couch: P1's A on %s: the overview is already moving (native input acted)", e.cls)
        return
    end
    local ok, err = pcall(function() e.w:OnAccept(U.fname("IA_UI_Accept")) end)
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s OnAccept(IA_UI_Accept): %s", e.cls, ok and "ok" or ("error " .. tostring(err)))
    chain.gen = chain.gen + 1
    local w, host = e.w, S.host
    chainStep("ov1", 1200, function()
        if not stillActive(w) or animating(w) then return end
        if not host or not stillActive(host.w) then
            U.warn(TAG, "couch: the overview ignored OnAccept and no map host is up: CampaignSubsystem:TravelToNextPlanet()")
            pcall(function() FindFirstOf("CampaignSubsystem"):TravelToNextPlanet() end)
            return
        end
        local idx, def = currentPlanet(w)
        local okH, errH = pcall(function() host.w[host.def.planet](host.w, idx or 0, def) end)
        U.log(TAG, "couch: the overview ignored OnAccept (no anim, still up): %s %s(planet %s): %s", host.cls,
            host.def.planet:sub(1, 40), tostring(idx), okH and "ok" or ("error " .. tostring(errH)))
        if host.def.kind ~= "postrace" then return end
        chainStep("ov2", 4500, function()
            if not stillActive(host.w) then return end
            local okC, errC = hostCsm(host, host.def.planetCsm, "couch NEXT PLANET")
            U.log(TAG, "couch: NEXT PLANET still up 4.5 s later: host CSM -> EndOfPlanet: %s",
                okC and "ok" or ("error " .. tostring(errC)))
            chainStep("ov3", 3500, function()
                if not stillActive(host.w) or St.phase ~= "POSTRACE" then return end
                local okT = pcall(function() FindFirstOf("CampaignSubsystem"):TravelToNextPlanet() end)
                U.warn(TAG, "couch: NEXT PLANET still up after the CSM change: TravelToNextPlanet() %s",
                    okT and "ok" or "failed")
            end)
        end)
    end)
end

nodeAccept = function(e, p)
    if mapHeld(e) then return end
    local before = chosenNodeKey()
    local b, how = selectedButton(e.w)
    local node = nil
    if U.ok(b) then pcall(function() node = b.MapNode end) end
    if not U.ok(b) then
        U.logEvery("mb.nonode", 5000, TAG, "couch: P1's A on %s: %s, nothing clicked", e.cls, tostring(how))
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s node %s (%s): %s", e.cls, lname(b), tostring(how), ok and "clicked" or tostring(err))
    chain.gen = chain.gen + 1
    local w, host = e.w, S.host
    if not host then return end
    chainStep("node1", 1500, function()
        if not stillActive(w) then return end
        local now = chosenNodeKey()
        if now == before and U.ok(node) then
            local choosable = false
            pcall(function() choosable = node.bIsChoosable == true end)
            if not choosable then
                U.log(TAG, "couch: the focused node is not choosable: nothing to do")
                return
            end
            local okH, errH = pcall(function() host.w[host.def.node](host.w, node) end)
            U.log(TAG, "couch: the node click did nothing: %s node-clicked event: %s", host.cls,
                okH and "ok" or ("error " .. tostring(errH)))
        end
        chainStep("node2", 2000, function()
            if not stillActive(w) or chosenNodeKey() == 0 then return end
            local okC, errC = hostCsm(host, host.def.nodeCsm, "couch node picked")
            U.log(TAG, "couch: a node is chosen but the map is still up: host CSM -> %s: %s",
                host.def.nodeCsm:match("([%w_]+)$"), okC and "ok" or ("error " .. tostring(errC)))
        end)
    end)
end

-- D-pad on the overview (native first: the press is bridged only when the selector did not move)
local function overviewNav(e, dir)
    -- the index of the PREVIOUS tick: a native IA_UI_Nav press moves the selector at the key-down event, before
    -- this tick read the key (couchsim mapinput: a snapshot taken now double-stepped)
    local before = S.ovPrev
    local w = e.w
    sched.after("mb.ovnav", math.max(150, waitMs()), function()
        if not stillActive(w) then return end
        local now = nil
        pcall(function() now = tonumber(w.WBP_PlanetSelector.SelectedIndex) end)
        if now ~= before then return end
        local ok = pcall(function() if dir < 0 then w:NavLeft() else w:NavRight() end end)
        U.log(TAG, "couch: P1's D-pad %s on the overview bridged: %s", dir < 0 and "left" or "right", ok and "ok" or "failed")
    end)
end

-- (couch-livefix r3) P1's START on the paddock run map (planet overview / node map). Decoded WBP_Paddock_NextEvent_
-- Presentation: its Construct registers IA_UI_Pause -> OnPauseAction (CSM_PauseMenus_Root "Pause from paddock map") and
-- IA_UI_PlayerMenu on the screen OWNER's action router; a guest / dormant owner (the LAST local PC) never gets P1's
-- START there (live round 3: "START does nothing on the map overview"; vanilla solo: P1 owns it and START pauses).
-- Native first: bridged only when no pause / menu came up within the wait. (B on the node list: vanilla has no way back
-- from the node list - OnBack is never registered and the screen is no back handler - so B is left alone.)
local function mapPause(e, host)
    local hw = host.w
    if ownerP(hw) == 1 then return end                  -- P1's own map: the game's START works (vanilla)
    sched.after("mb.mappause", math.max(250, waitMs() + 100), function()
        if not stillActive(hw) then return end
        local menu = false
        pcall(function() U.mod("couch")._menuReset(); menu = U.mod("couch").menuOver() == true end)
        if menu then
            U.log(TAG, "couch: P1's START on %s acted natively (a menu is up): not bridged", e.cls)
            return
        end
        local ok, err = pcall(function() hw:OnPauseAction(U.fname("IA_UI_Pause")) end)
        S.clicks = S.clicks + 1
        U.log(TAG, "couch: P1's START on %s -> %s OnPauseAction(IA_UI_Pause): %s", e.cls, host.cls,
            ok and "ok" or ("error " .. tostring(err)))
        pcall(function() U.mod("couch").markDirty("P1 START on the map") end)
    end)
end
M._mapPause = mapPause

---------------------------------------------------------------------------------------------------- couch paddock shop
-- the state a native A / B changes: P1's credits (a buy), the layout's switcher page (a pack opened / picked), the
-- screen's activation (CONTINUE / back left the shop), P1's focus still inside the shop (a replace-item message took
-- it). Read every tick while the shop is on top (S.shopPrev).
local function shopSig(e)
    local cr, sw, act, foc = "?", "?", "?", "?"
    pcall(function() cr = tostring(U.giSubsystem("/Script/Griffin.CampaignSubsystem").ActiveRun.Credits) end)
    pcall(function() sw = tostring(U.key(e.w.WBP_Paddock_Shop_Layout_Presentation.MainSwitcher:GetActiveWidget())) end)
    pcall(function() act = tostring(e.w:IsActivated() == true) end)
    if U.ok(S.couchPc) then pcall(function() foc = tostring(e.w:HasUserFocusedDescendants(S.couchPc) == true) end) end
    return cr .. "|" .. sw .. "|" .. act .. "|" .. foc
end
M.shopSig = shopSig

local function insideOf(b, wk)
    local inside = false
    if not U.ok(b) then return false end
    pcall(function()
        local x = b:GetOuter()
        for _ = 1, 10 do
            if not U.ok(x) then break end
            if U.key(x) == wk then inside = true; break end
            x = x:GetOuter()
        end
    end)
    return inside
end

-- the visible CommonButton inside the shop that pad 0's Slate user focuses (pc = the PC on ControllerId 0), else nil
local function shopFocused(e, pc)
    if not U.ok(pc) then return nil end
    local wk = U.key(e.w)
    for _, b in ipairs(FindAllOf("CommonButtonBase") or {}) do
        if U.ok(b) then
            local f = false
            pcall(function() f = b:HasUserFocus(pc) == true or b:HasUserFocusedDescendants(pc) == true end)
            if f and insideOf(b, wk) then
                local vis = true
                pcall(function() local v = b:GetVisibility(); vis = (v ~= 1 and v ~= 2) end)
                if vis then return b end
            end
        end
    end
    return nil
end

-- Live 2026-10-14 22:20 (2P, vendor shop with P2's native copy): no CommonButton in P1's shop was focused or selected
-- after the split opened, so his D-pad moved nothing and his A found "no shop button holds his focus". Focus given to
-- the layout switcher's active page (its desired focus target) for the PC on pad id 0 made his D-pad navigate and his
-- native A buy at once. HasUserFocus(pc) stays false even then (a parked PC's Slate user is not its pad id), so "no
-- cursor" = no visible button inside the shop is selected or has any user focus. At most once a second, never paused.
local function shopHasCursor(e)
    for _, b in ipairs(FindAllOf("CommonButtonBase") or {}) do
        if U.ok(b) and insideOf(b, e.k) then
            local on = false
            pcall(function() on = b:GetSelected() == true or b:HasAnyUserFocus() == true end)
            if on then return true end
        end
    end
    return false
end

local function shopCursor(e, pc, now)
    if now < (S.shopCursorAt or 0) then return end
    S.shopCursorAt = now + 1000
    if not U.ok(pc) or shopHasCursor(e) then return end
    local t = nil
    pcall(function()
        local a = e.w.WBP_Paddock_Shop_Layout_Presentation.MainSwitcher:GetActiveWidget()
        if U.ok(a) then
            pcall(function() t = a:GetDesiredFocusTarget() end)
            if not U.ok(t) then t = a end
        end
    end)
    if not U.ok(t) then return end
    local ok = pcall(function() t:SetUserFocus(pc) end)
    S.shopCursors = (S.shopCursors or 0) + 1
    U.logEvery("mb.shopcursor", 5000, TAG, "couch: no cursor in %s: focus on %s for the pad-0 PC: %s", e.cls, lname(t),
        ok and "ok" or "failed")
end
M.shopHasCursor = shopHasCursor

local function shopOnPack(e)
    local on = false
    pcall(function()
        local lay = e.w.WBP_Paddock_Shop_Layout_Presentation
        on = U.key(lay.MainSwitcher:GetActiveWidget()) == U.key(lay.WBP_Shop_ItemPack_Panel_Presentation)
    end)
    return on
end

local function shopAccept(e, p)
    local b = shopFocused(e, S.couchPc)
    if not U.ok(b) then
        U.logEvery("mb.shopnf", 5000, TAG, "couch: P1's A on %s: no shop button holds his focus, nothing clicked", e.cls)
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s %s (his focus): %s", e.cls, lname(b), ok and "clicked" or ("error " .. tostring(err)))
end

-- #77 (Jules 2026-10-18): P1's B on a shared shop / Scrap Dealer stop while a guest is still shopping is HELD
-- (couchpanel.holdLeave: P1's area "WAITING FOR P2", the stop closes once the guests left) instead of the screen's back.
-- -> true when held (nothing else to do for this B)
local function stopHeld(e)
    local CP = package.loaded["couchpanel"]
    if type(CP) ~= "table" or type(CP.holdLeave) ~= "function" then return false end
    local ok, held = pcall(CP.holdLeave, e.w, "P1's B (bridged on " .. tostring(e.cls) .. ")")
    return ok and held == true
end

local function shopBack(e, p)
    -- P1's focus must be in the shop (a player menu / message over it takes his B natively)
    local inShop = false
    pcall(function() inShop = U.ok(S.couchPc) and e.w:HasUserFocusedDescendants(S.couchPc) == true end)
    if not inShop then
        U.logEvery("mb.shopbf", 5000, TAG, "couch: P1's B on %s: his focus is not in the shop: not bridged", e.cls)
        return
    end
    if shopOnPack(e) then
        U.log(TAG, "couch: P1's B on %s: the pack picker is open (native B does nothing there): not bridged", e.cls)
        return
    end
    if stopHeld(e) then return end
    U.log(TAG, "couch: P1's B on %s (his pad on P%s's PC): the screen's own back", e.cls, tostring(p))
    back(e, p)
end

---------------------------------------------------------------------------------------------------- couch pre-run loadout
-- P1's LoadoutConfirmation (his own dialog after START RUN) among the activated screens
local function loadoutConfirmUp()
    -- a fresh full scan (one, at the bridge's decision): the shared cache may predate a dialog the native A opened
    local list = S.screens or {}
    local okA, l = pcall(function() return U.mod("couch").activeScreens(true) end)
    if okA and type(l) == "table" then list = l end
    for _, c in ipairs(list) do
        if type(c.cls) == "string" and c.cls:find("LoadoutConfirmation", 1, true) then return true end
    end
    return false
end
M.loadoutConfirmUp = loadoutConfirmUp

-- the loadout's START RUN when the pad-0 PC (P1's pad) focuses it, else nil, why
local function loadoutHero(e)
    local b = nil
    pcall(function() b = e.w.WBP_Hero_Btn end)
    if not U.ok(b) then return nil, "no WBP_Hero_Btn" end
    local pc = S.couchPc
    if not U.ok(pc) then return nil, "no PC on pad id 0" end
    local f = false
    pcall(function() f = b:HasUserFocus(pc) == true or b:HasUserFocusedDescendants(pc) == true end)
    if not f then return nil, "his focus is not on START RUN" end
    return b
end

-- Live 2026-10-15 (loadoutfix, swapped + parked loadout): while P1 held A on a focused CommonButton of the loadout,
-- IsInputKeyDown(A) was false on EVERY PC (the button consumes the key in Slate - the /CHALLENGES finding), and the
-- button's IsPressed stayed false; the screen owner's (the PC on pad id 0) GfnRawInputSubsystem EnhancedPlayerInput
-- showed IA_UI_Accept Triggered (IMC_UI boosted by couch.lua) for as long as A was held, nothing on P1's parked PC.
-- So P1's A on the loadout is read there (ETriggerEvent Triggered / Started / Ongoing).
local ACCEPT_TRIGGER = { [1] = true, [2] = true, [4] = true }
local function uiAcceptDown(pc)
    local down = false
    pcall(function()
        local raw = pc.RawInputSubsystem
        if not U.ok(raw) then return end
        local epi = raw.EnhancedPlayerInput
        if not U.ok(epi) then return end
        epi.ActionInstanceData:ForEach(function(k, v)
            if down then return end
            local ia = k:get()
            if U.ok(ia) and ia:GetFName():ToString() == "IA_UI_Accept" then
                local inst = v:get()
                if ACCEPT_TRIGGER[tonumber(inst.TriggerEvent) or 0] then down = true end
            end
        end)
    end)
    return down
end
M.uiAcceptDown = uiAcceptDown

local function loadoutAccept(e, p)
    if loadoutConfirmUp() then
        U.log(TAG, "couch: P1's A on %s: his LoadoutConfirmation is up (native acted): not bridged", e.cls)
        return
    end
    local b, why = loadoutHero(e)
    if not b then
        U.logEvery("mb.loadout", 5000, TAG, "couch: P1's A on %s: %s: native only", e.cls, tostring(why))
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s START RUN (WBP_Hero_Btn, his focus): %s", e.cls,
        ok and "clicked" or ("error " .. tostring(err)))
end

---------------------------------------------------------------------------------------------------- couch-scaccept
-- the visible CommonButton of class pattern pat (nil = any) inside screen e that the pad-0 PC's Slate user focuses
local function focusedInside(e, pat)
    local pc = S.couchPc
    if not U.ok(pc) then return nil end
    for _, b in ipairs(FindAllOf(pat or "CommonButtonBase") or {}) do
        if U.ok(b) and U.alive(b) then
            local f = false
            pcall(function() f = b:HasUserFocus(pc) == true or b:HasUserFocusedDescendants(pc) == true end)
            if f and insideOf(b, e.k) then
                local vis = true
                pcall(function() local v = b:GetVisibility(); vis = (v ~= 1 and v ~= 2) end)
                if vis then return b end
            end
        end
    end
    return nil
end
M.focusedInside = focusedInside

-- the sponsor screen's content widget (WBP_SponsorSelect_Content_C: the real chooser) for screen entry e
local function sponsorContent(e)
    if type(e.cls) == "string" and e.cls:find("_Content", 1, true) then return e.w end
    local c = nil
    pcall(function() c = e.w.WBP_SponsorSelect_Content end)
    return U.ok(c) and c or nil
end

local function sponsorAccept(e, p)
    local b = focusedInside(e, "WBP_SponsorChoice_Btn_C")
    if not U.ok(b) then
        U.logEvery("mb.sponsornf", 5000, TAG, "couch: P1's A on %s: no contract holds his focus, nothing chosen", e.cls)
        return
    end
    local locked, lbl = false, lname(b)
    pcall(function() locked = b:GetLocked() == true end)
    pcall(function() local t = U.str(b.SponsorLabel); if type(t) == "string" and t ~= "" then lbl = t end end)
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s contract '%s'%s (his focus): %s", e.cls, tostring(lbl), locked and " (LOCKED)" or "",
        ok and "clicked" or ("error " .. tostring(err)))
    if locked then return end
    -- the click's chain ends in ContinueToNextState (hooked: csmSeq moves) and the screen leaves (its TransitionOut waits
    -- 2 s, decoded). No state change AND still activated 2.5 s later = the click did not reach the chooser: the content's
    -- own OnSponsorChosen(Sponsor, Contract) (the same chain, called directly) - never after a state change (no double)
    local w, k, seq, world = e.w, e.k, couchCsmSeq(), St.worldGen
    local sp, ct = nil, nil
    pcall(function() sp = b.Sponsor end)
    pcall(function() ct = b.Contract end)
    local content = sponsorContent(e)
    sched.after("mb.sponsorcheck", 2500, function()
        if St.worldGen ~= world or not U.alive(w) or not stillActive(w) or couchCsmSeq() ~= seq then return end
        local okC, errC = false, "no content widget"
        if U.ok(content) and U.ok(sp) then okC, errC = pcall(function() content:OnSponsorChosen(sp, ct) end) end
        U.log(TAG, "couch: %s still up 2.5 s after the contract click: content OnSponsorChosen('%s'): %s", e.cls,
            tostring(lbl), okC and "called" or ("error " .. tostring(errC)))
    end)
end

-- VIEW BUILD from a shared paddock screen: the player menu state, as WBP_Paddock_Shop_Presentation's own
-- OnPlayerMenuAction does it (decoded: CosmeticStateMachineManager:GetStateMachineForRoot(CSM_PauseMenus_Root)
-- :ChangeStateTo(CSM_PauseMenus_PlayerMenu, "", null))
local CSM_PAUSE_ROOT = "/Game/Griffin/Config/StateMachines/PauseMenus/CSM_PauseMenus_Root.CSM_PauseMenus_Root"
local CSM_PLAYER_MENU = "/Game/Griffin/Config/StateMachines/PauseMenus/CSM_PauseMenus_PlayerMenu.CSM_PauseMenus_PlayerMenu"
local function playerMenuUp()
    local okA, l = pcall(function() return U.mod("couch").activeScreens(true) end)
    if okA and type(l) == "table" then
        for _, c in ipairs(l) do if type(c.cls) == "string" and c.cls:find("^WBP_PlayerMenu") then return true end end
    end
    return false
end
local function openPlayerMenu(e, p)
    if playerMenuUp() then
        U.log(TAG, "couch: P1's VIEW on %s: the player menu is up (native acted): not bridged", e.cls)
        return
    end
    local root, st = findL(CSM_PAUSE_ROOT), findL(CSM_PLAYER_MENU)
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    local m, err = nil, "CSM assets / manager not loaded"
    if root and st and U.ok(mgr) then pcall(function() m = mgr:GetStateMachineForRoot(root) end) end
    local ok = false
    if U.ok(m) then ok, err = pcall(function() m:ChangeStateTo(st, "SWGRCouch: VIEW BUILD for P1", nil) end) end
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's VIEW -> %s: player menu (CSM_PauseMenus_PlayerMenu): %s", e.cls,
        ok and "opened" or ("failed " .. tostring(err)))
end

-- garage B: a page's back as its CommonUI default back does it (garagenative.backOf), the root's OnCancelAction
local function garageBack(e, p)
    local how, ok = nil, false
    if e.cls == "WBP_Paddock_VehicleCust_C" then
        ok = pcall(function() e.w:OnCancelAction(U.fname("IA_UI_Cancel")) end)
        how = "OnCancelAction (garage exit)"
    else
        local gn = package.loaded["garagenative"]
        if type(gn) == "table" and type(gn.backOf) == "function" then
            local okB, r, h = pcall(gn.backOf, e.w)
            ok, how = okB and r == true, tostring(h or "back")
        else
            ok = pcall(function() e.w:BackToPreviousState() end)
            how = "BackToPreviousState"
        end
    end
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's B -> %s (his own garage, swapped): %s: %s", e.cls, tostring(how), ok and "ok" or "failed")
end

-- P1's own garage screen with no cursor of his (CommonUI focuses a page for its owner's user when it activates it; a page
-- found by class may never have been activated): its desired focus target for the pad-0 PC, at most once a second,
-- only while his focus is not inside it (GetDesiredFocusTarget only at that moment: the periodic-call freeze trap).
-- couch-p1garage (#27): on an option page an ENTRY must hold it (a focus on the list itself = a dead D-pad, the guest
-- turn's live 2026-10-16 finding): the equipped entry (else the first) gets it; a new screen is checked within 300 ms;
-- the root too (his A bridge enters the hero HIS focus is on).
local function gnMod()
    local gn = package.loaded["garagenative"]
    return type(gn) == "table" and gn or nil
end
local function garageCursor(e, now)
    if S.gCursorK ~= e.k then S.gCursorK, S.gCursorAt = e.k, now + 300 end
    if now < (S.gCursorAt or 0) then return end
    S.gCursorAt = now + 1000
    local pc = S.couchPc
    if not U.ok(pc) or not U.alive(e.w) then return end
    local gn = gnMod()
    local t = nil
    if gn and type(gn.ownEntryFocus) == "function" and e.cls ~= "WBP_Paddock_VehicleCust_C" then
        local okE, holdsE, en = pcall(gn.ownEntryFocus, e.w, pc)
        if okE and holdsE == true then return end
        if okE and holdsE == false then
            if not U.ok(en) then return end                  -- the page's entries are not generated yet: next check
            t = en
        end
    end
    if not t then
        local holds = false
        pcall(function() holds = e.w:HasUserFocusedDescendants(pc) == true or e.w:HasUserFocus(pc) == true end)
        if holds then return end
        pcall(function() t = e.w:GetDesiredFocusTarget() end)
        if not U.ok(t) then t = e.w end
    end
    local ok = pcall(function() t:SetUserFocus(pc) end)
    U.logEvery("mb.gcursor", 5000, TAG, "couch: no cursor of P1 in his garage screen %s: focus on %s for the pad-0 PC: %s",
        e.cls, lname(t), ok and "ok" or "failed")
end

-- couch-p1garage (#27): the native-first signature of P1's garage screen (a page's tab + selected entry; nil = root)
local function garageSig(e)
    if not e or e.cls == "WBP_Paddock_VehicleCust_C" then return nil end
    local gn = gnMod()
    if not (gn and type(gn.ownPageSig) == "function") then return nil end
    local ok, v = pcall(gn.ownPageSig, e.w)
    return ok and v or nil
end

-- P1's A on his own garage: root = the hero page his focus is on; page = the option entry he focuses
local OPT_BTN = "WBP_CustomisationOptionButton_Vehicle_C"
local function garageAccept(e, p)
    local gn = gnMod()
    if e.cls == "WBP_Paddock_VehicleCust_C" then
        if not (gn and type(gn.ownEnter) == "function") then return end
        local okC, ok, sub = pcall(gn.ownEnter, e.w, S.couchPc)
        if not (okC and ok) and sub == "no hero button holds his focus" then
            U.logEvery("mb.gheronf", 5000, TAG, "couch: P1's A on %s (his own garage): no hero button holds his focus, "
                .. "nothing entered", e.cls)
            return
        end
        S.clicks = S.clicks + 1
        S.gCursorK = nil                                 -- the page that opens gets his cursor checked soon
        U.log(TAG, "couch: P1's A -> %s (his own garage, swapped): enter %s: %s", e.cls, tostring(sub),
            (okC and ok) and "ok" or "failed")
        return
    end
    local b = focusedInside(e, OPT_BTN) or focusedInside(e)
    if not U.ok(b) then
        U.logEvery("mb.gpagenf" .. e.cls, 5000, TAG, "couch: P1's A on %s (his own garage): no option holds his focus, "
            .. "nothing clicked", e.cls)
        return
    end
    local hold, locked = false, false
    pcall(function() hold = b.bRequiresHold == true end)
    pcall(function() locked = b:GetLocked() == true end)
    if hold or locked then
        U.logEvery("mb.gpagehold" .. e.cls, 5000, TAG, "couch: P1's A on %s %s: a %s option, not bridged (the game's own "
            .. "hold / lock)", e.cls, lname(b), hold and "hold" or "locked")
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s %s (his own garage, his focus): %s", e.cls, lname(b),
        ok and "clicked" or ("error " .. tostring(err)))
end

-- couch-p1garage (#27): P1's LB / RB on his own garage page. Read on the PC holding pad id 0 (the swapped owner) from (a)
-- its PlayerInput (IsInputKeyDown: an XInput pad / vpad) and (b) its raw input subsystem's IA_UI_Tab_Left / _Right
-- (triggered, or LastTriggeredWorldTime moved: a one-frame trigger between two polls) - where the live 2026-10-15
-- loadout session saw P1's IA_UI_Accept (uiAcceptDown, b88269e). The DLL's pad watch has no shoulder keys. Bridged
-- after the wait only when the page's selected tab did not change.
local TAB_IA = { IA_UI_Tab_Left = -1, IA_UI_Tab_Right = 1 }
local function rawTabEdges(pc, st)
    local out = 0
    local nativeOn = false
    pcall(function() nativeOn = U.mod("inputfix").nativeOn() == true end)
    if not nativeOn or not U.ok(pc) then st.raw = nil; return 0 end
    local seen = {}
    pcall(function()
        local epi = pc.RawInputSubsystem.EnhancedPlayerInput
        if not U.ok(epi) then return end
        epi.ActionInstanceData:ForEach(function(k, v)
            local ia = k:get()
            if not U.ok(ia) then return end
            local n = ia:GetFName():ToString()
            if TAB_IA[n] then
                local inst = v:get()
                local te = tonumber(inst.TriggerEvent) or 0
                local t = nil
                pcall(function() t = tonumber(inst.LastTriggeredWorldTime) end)
                seen[n] = { trig = (te == 1 or te == 2 or te == 4), ltw = t or 0 }
            end
        end)
    end)
    local prev = st.raw
    if prev then
        for n, cur in pairs(seen) do
            local p0 = prev[n]
            if p0 and ((cur.trig and not p0.trig) or (not cur.trig and not p0.trig and cur.ltw > p0.ltw)) then
                out = TAB_IA[n]
            end
        end
    end
    st.raw = seen
    return out
end
local function garageTabs(e, now)
    local gn = gnMod()
    if not (gn and type(gn.ownTab) == "function") or e.cls == "WBP_Paddock_VehicleCust_C" then S.gt = nil; return end
    local okT, tl, id = pcall(gn.ownTab, e.w)
    if not okT or not tl then S.gt = nil; return end
    local st = S.gt
    if not st or st.k ~= e.k then
        st = { k = e.k, cur = id, keys = {} }
        S.gt = st
    end
    local prevId = st.cur                                -- the previous tick's tab (a native LB acts at the key-down)
    st.cur = id
    -- the edges (both sources read every tick: their baselines move on)
    local dir = 0
    local K = { [-1] = "Gamepad_LeftShoulder", [1] = "Gamepad_RightShoulder" }
    for d, key in pairs(K) do
        local down = false
        if U.ok(S.couchPc) then pcall(function() down = S.couchPc:IsInputKeyDown({ KeyName = U.fname(key) }) == true end) end
        if down and not st.keys[d] then dir = d end
        st.keys[d] = down
    end
    local rd = rawTabEdges(S.couchPc, st)
    if dir == 0 then dir = rd end
    local pend = st.pend
    if pend and now - pend.at >= waitMs() then
        st.pend = nil
        if id ~= pend.id then
            U.log(TAG, "couch: P1's %s on %s acted natively (tab %s -> %s): not bridged", pend.dir > 0 and "RB" or "LB",
                e.cls, tostring(pend.id), tostring(id))
        else
            local okS, ok, nid = pcall(gn.ownTabStep, e.w, pend.dir)
            S.clicks = S.clicks + 1
            st.cur = (okS and ok and nid) or st.cur
            S.gCursorK = nil                             -- the new tab's entries get his cursor checked soon
            U.log(TAG, "couch: P1's %s -> %s (his own garage, swapped): tab %s: %s", pend.dir > 0 and "RB" or "LB",
                e.cls, tostring(nid), (okS and ok) and "ok" or "failed")
        end
        return
    end
    if dir ~= 0 and not pend then
        st.pend = { at = now, id = prevId, dir = dir }
        pcall(function() U.mod("couch").markDirty("P1 press") end)
    end
end

local function genericAccept(e, p)
    local b = focusedInside(e)
    if not U.ok(b) then
        U.logEvery("mb.gennf" .. e.cls, 5000, TAG, "couch: P1's A on %s: no button holds his focus, nothing clicked", e.cls)
        return
    end
    local hold, locked = false, false
    pcall(function() hold = b.bRequiresHold == true end)
    pcall(function() locked = b:GetLocked() == true end)
    if hold or locked then
        U.logEvery("mb.genhold" .. e.cls, 5000, TAG, "couch: P1's A on %s %s: a %s button, not bridged", e.cls, lname(b),
            hold and "hold" or "locked")
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s %s (generic, his focus): %s", e.cls, lname(b), ok and "clicked" or ("error " .. tostring(err)))
end

local function genericBack(e, p)
    if stopHeld(e) then return end                    -- #77: the Scrap Dealer's landing while a guest shops
    stopNodeComplete(e, "P1's bridged B")
    local how
    if pcall(function() e.w:HandleBack() end) then how = "HandleBack()"
    elseif pcall(function() e.w:OnCancelAction(U.fname("IA_UI_Cancel")) end) then how = "OnCancelAction()"
    -- overnight 2026-10-18 (tester #2): the SCRAP DEALER's shop page (WBP_ExoticVendorShop_Presentation_C, guest-owned
    -- while swapped) has neither; P1 was stuck in it. Its GfnActivatableWidget BackToPreviousState() returns to the
    -- dealer's landing page (live-verified by hand), as the non-couch back path (pressBack) already does.
    elseif pcall(function() e.w:BackToPreviousState() end) then how = "BackToPreviousState()" end
    if how then S.clicks = S.clicks + 1 end
    U.log(TAG, "couch: P1's B -> %s (generic): %s", e.cls,
        how or "no screen back (HandleBack / OnCancelAction / BackToPreviousState): nothing done")
end

-- #64: the strike popup's CONTINUE. Live (tester #3): with two notifications stacked (Strikes 1/2 over 0/2, both
-- P1's) the button's own HandleButtonClicked did NOTHING; the screen's bound-event handler of that button (the BP's
-- OnButtonBaseClicked binding) continued the flow, one notification per call. Handler first, the click as fallback;
-- one A = the top notification (the next A takes the one under it).
M.STRIKES_EVT = "BndEvt__WBP_StrikesNotification_WBP_Hero_Btn_K2Node_ComponentBoundEvent_1_CommonButtonBaseClicked__DelegateSignature"
local function strikesAccept(e, p)
    local b = nil
    pcall(function() b = e.w.WBP_Hero_Btn end)
    if not U.ok(b) then b = buttonInside(e.w, "Hero_Btn") end
    if not U.ok(b) then
        U.logEvery("mb.strikes", 5000, TAG, "P%d A on %s: no visible WBP_Hero_Btn", p, e.cls)
        return
    end
    local n = 0
    for _, c in ipairs(S.screens) do if c.cnat == "strikes" and U.alive(c.w) then n = n + 1 end end
    local okE, errE = pcall(function() e.w[M.STRIKES_EVT](e.w, b) end)
    local how = "its CONTINUE handler"
    -- the handler may have closed it: a closed popup can be garbage at once (a UFunction on it = an access violation)
    local still = false
    if U.alive(e.w) then pcall(function() still = e.w:IsActivated() == true end) end
    if not okE or still then
        -- the handler is missing (another build) or left the popup up: the button's own click
        local okC, errC = false, "the button is gone"
        if U.alive(b) then okC, errC = pcall(function() b:HandleButtonClicked() end) end
        how = string.format("CONTINUE clicked (handler %s)%s", okE and "left it up" or tostring(errE),
            okC and "" or (" error " .. tostring(errC)))
    end
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s: %s%s", e.cls, how,
        n > 1 and string.format(" (%d strike notifications stacked: the next A takes the one under it)", n) or "")
end

-- couch-fix61 (AUTO-149, live round 6 09:48:07: P1's A 2.7 s into the act-end recap -> OnContinue -> the next act, and
-- not one NEW UNLOCK screen; left alone the first came ~7 s in). Decoded WBP_PostRace_RunEndRecap ubergraph: BP_OnActivated
-- -> the timeline animation; its OnTimelineAnimComplete -> HasNewUnlocksToShow ? Delay(UnlocksPopupDelay) -> AddMessage
-- 'EndRunNewUnlocks' (the NEW UNLOCK screens) ... -> WBP_Section_1/2/3 BeginAnimSequence; only WBP_Section_3's
-- AllProgressAnimsComplete registers IA_UI_Accept -> OnContinue. So the game's own CONTINUE does not exist before the
-- unlock screens were shown: a solo early A does nothing. The bridge called OnContinue at once (its
-- CleanupAfterRunAndPrepareForNext dropped the queued screens). Parity: P1's bridged A on the recap waits for that
-- binding.
-- couch-fix62 (AUTO-151, live round 7 11:53:03-11:59:14): the post-hook on the Section_3 event REGISTERS but never fires
-- (BP hooks do not fire in this build), so fix61's 12 s fallback (taken only without the hook) never ran and the A
-- waited for the 30 s cap. Readiness is now READ from the recap (polled at P1's press), the hook only an extra signal.
-- Decoded WBP_Cam_EndTour_Section (the three sections): Construct -> SetVisibility(Hidden); BeginAnimSequence with an
-- unlock child -> SetVisibility(HitTestInvisible) + its progress anims; each anim's end sets IndexHasAnimated[i] = true
-- and the last one broadcasts AllProgressAnimsComplete (Section_1 -> Section_2 -> Section_3 -> the CONTINUE binding;
-- an empty / collapsed section broadcasts at once). So: a shown section (not Collapsed, IndexHasAnimated non-empty)
-- still Hidden or with an un-animated index = the recap is NOT ready (its NEW UNLOCK screens come before Section_1);
-- every shown section begun and fully animated = ready (the game bound its CONTINUE). Without a readable section, the
-- fallback: RECAP_QUIET_MS after the recap appeared or its last NEW UNLOCK screen went, with no NEW UNLOCK up and none
-- still due (RunStatsVM.TimelineNewUnlocksVM.NewUnlocks non-empty and none shown yet), the A goes through; after
-- RECAP_MAX_MS quiet it goes through whatever (never a dead A).
M.RECAP_READY_HOOK = "/Game/Griffin/UI/Screens/PostRace/WBP_PostRace_RunEndRecap.WBP_PostRace_RunEndRecap_C:"
    .. "BndEvt__WBP_PostRace_RunEndRecap_WBP_Section_3_K2Node_ComponentBoundEvent_1_AllProgressAnimsComplete__DelegateSignature"
local RECAP_QUIET_MS, RECAP_MAX_MS = 8000, 30000
local RECAP_SECTIONS = { "WBP_Section_1", "WBP_Section_2", "WBP_Section_3" }
local VIS_COLLAPSED, VIS_HIDDEN = 1, 2
S.recapReady = {}
S.unlockAt = nil                                   -- St.nowMs() a NEW UNLOCK screen was last seen up
function M.onRecapReady(ctx)
    local w = U.unwrap(ctx)
    if not U.ok(w) then return end
    S.recapReady[U.key(w)] = St.nowMs()
    U.log(TAG, "act-end recap: the game bound its CONTINUE (its NEW UNLOCK screens are over): P1's A continues it (AUTO-149)")
end
local function unlockUp()
    local up = false
    for _, c in ipairs(S.screens or {}) do
        if isUnlockCls(c.cls) and U.alive(c.w) then up = true; break end
    end
    if up then S.unlockAt = St.nowMs() end
    return up
end
-- one recap section: "skip" (absent / collapsed / no unlock rows / unreadable), "wait" (not begun or a row still to
-- animate), "done" (begun, every row animated)
local function sectionState(w, name)
    local sec
    pcall(function() sec = w[name] end)
    if not U.ok(sec) then return "skip" end
    local vis, num
    pcall(function() vis = sec:GetVisibility() end)
    vis = tonumber(vis)
    if vis == nil or vis == VIS_COLLAPSED then return "skip" end
    local arr
    pcall(function() arr = sec.IndexHasAnimated end)
    if arr == nil then return "skip" end
    pcall(function() num = arr:GetArrayNum() end)
    num = math.tointeger(tonumber(num))
    if not num or num < 1 then return "skip" end
    if vis == VIS_HIDDEN then return "wait" end    -- BeginAnimSequence not called yet
    for i = 1, num do
        local v
        local okV = pcall(function() v = arr[i] end)
        if not okV or type(v) ~= "boolean" then return "skip" end
        if v ~= true then return "wait" end
    end
    return "done"
end
-- the recap's own state: true (every shown section animated), false (a section still to begin / animate), nil (unreadable)
local function recapAnimsDone(w)
    if not U.alive(w) then return nil end
    local done = false
    for _, name in ipairs(RECAP_SECTIONS) do
        local st = sectionState(w, name)
        if st == "wait" then return false, name end
        if st == "done" then done = true end
    end
    if done then return true end
    return nil
end
-- the recap's view model still has NEW UNLOCK screens to show (no unlock screen seen since the recap appeared)
local function unlocksDue(w, since)
    if S.unlockAt and S.unlockAt >= since then return false end
    local n
    pcall(function() n = w.RunStatsVM.TimelineNewUnlocksVM.NewUnlocks:GetArrayNum() end)
    n = tonumber(n)
    return n ~= nil and n > 0
end
-- -> true when P1's A may continue recap entry e, else false + why
local function recapReady(e)
    if opt("CouchRecapWaitUnlocks", true) == false then return true end
    if S.recapReady[e.k] then return true end
    local now = St.nowMs()
    if unlockUp() then return false, "a NEW UNLOCK screen is up" end
    local at = tonumber(e.at) or now
    local quiet = now - math.max(at, S.unlockAt or at)  -- since the recap appeared or its last NEW UNLOCK went
    local done, which = recapAnimsDone(e.w)
    if done == true then
        S.recapReady[e.k] = now
        U.log(TAG, "act-end recap: every section animated (the game bound its CONTINUE): P1's A continues it (AUTO-151)")
        return true
    end
    if quiet >= RECAP_MAX_MS then
        return true, string.format("recap up %.1f s, %.1f s with no NEW UNLOCK: no readiness signal (%s) within the "
            .. "%d s cap, continued anyway", (now - at) / 1000, quiet / 1000,
            done == false and (tostring(which) .. " still animating") or "sections unreadable", RECAP_MAX_MS // 1000)
    end
    if done == false then
        return false, string.format("%.1f s in, %s not animated yet (the NEW UNLOCK screens and the sections come first, "
            .. "as solo)", (now - at) / 1000, tostring(which))
    end
    -- no readable section: the time fallback (never before the NEW UNLOCK screens the view model still has)
    if unlocksDue(e.w, at) then
        return false, string.format("%.1f s in, sections unreadable and its NEW UNLOCK screens still due", (now - at) / 1000)
    end
    if quiet >= RECAP_QUIET_MS then
        return true, string.format("no readiness signal (sections unreadable): %.1f s with no NEW UNLOCK up", quiet / 1000)
    end
    return false, string.format("%.1f s in, its CONTINUE not bound yet (%.1f s of %d s quiet)", (now - at) / 1000,
        quiet / 1000, RECAP_QUIET_MS // 1000)
end
M._recapReady = recapReady

local function couchAccept(e, p)
    local how, ok, err = e.cnat, true, nil
    if e.cnat == "shop" then
        return shopAccept(e, p)
    elseif e.cnat == "sponsor" then
        return sponsorAccept(e, p)
    elseif e.cnat == "generic" then
        return genericAccept(e, p)
    elseif e.cnat == "garage" then
        return garageAccept(e, p)
    elseif e.cnat == "loadout" then
        return loadoutAccept(e, p)
    elseif e.cnat == "recap" then
        local ready, why = recapReady(e)
        if not ready then
            U.logEvery("mb.recaphold", 2000, TAG, "couch: P1's A on %s held: %s (AUTO-149)", e.cls, tostring(why))
            return
        end
        if why then U.warn(TAG, "couch: act-end recap: %s (AUTO-151)", why) end
        ok, err = pcall(function() e.w:OnContinue(U.fname("Continue")) end)
        how = "OnContinue(Continue)"
    elseif e.cnat == "overview" then
        return overviewAccept(e, p)
    elseif e.cnat == "nodemap" then
        return nodeAccept(e, p)
    elseif e.cnat == "strikes" then
        return strikesAccept(e, p)
    else
        local b, sel = selectedButton(e.w)
        if not U.ok(b) then
            U.logEvery("mb.nobtn" .. e.cls, 5000, TAG, "P%d A on %s: %s, nothing clicked", p, e.cls, tostring(sel))
            return
        end
        ok, err = pcall(function() b:HandleButtonClicked() end)
        how = lname(b) .. " (" .. tostring(sel) .. ") clicked"
    end
    S.clicks = S.clicks + 1
    U.log(TAG, "couch: P1's A -> %s %s: %s", e.cls, how, ok and "ok" or ("error " .. tostring(err)))
end

-- couch race: player p presses on a pause screen another player opened (his pause: he drives it) -> RESUME only
local function resumeOnly(e, p)
    if not (S.couchRace and type(e.cls) == "string" and e.cls:find("^WBP_Pause")) then return false end
    local own = ownerP(e.w)
    return own ~= nil and own ~= p
end

local function click(e, p, what)
    if e.dialog then return dialogPress(e, p, what) end
    if resumeOnly(e, p) then
        local own = ownerP(e.w)                       -- read before the click: RESUME closes the screen (garbage after)
        local b
        pcall(function() b = e.w.btn_resumerace end)
        if not U.ok(b) then
            U.logEvery("mb.noresume" .. e.cls, 5000, TAG, "P%d %s on P%s's %s: no RESUME button, nothing clicked", p, what,
                tostring(own), e.cls)
            return
        end
        local ok, err = pcall(function() b:HandleButtonClicked() end)
        S.clicks = S.clicks + 1
        U.log(TAG, "P%d %s on P%s's %s: RESUME (his pause, he drives its rows): %s", p, what, tostring(own), e.cls,
            ok and "clicked" or ("error " .. tostring(err)))
        return
    end
    if what == "View" then return openPlayerMenu(e, p) end
    if e.cnat and what == "A" then return couchAccept(e, p) end
    if e.cnat == "shop" and what == "B" then return shopBack(e, p) end
    if e.cnat == "garage" and what == "B" then return garageBack(e, p) end
    if e.cnat == "generic" and what == "B" then return genericBack(e, p) end
    if what == "B" then return back(e, p) end
    local b, how = selectedButton(e.w)
    if not U.ok(b) then
        U.logEvery("mb.nobtn" .. e.cls, 5000, TAG, "P%d %s on %s: %s, nothing clicked", p, what, e.cls, tostring(how))
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    -- couch-rewards2: in the couch's shared phases the bridged PC is the one holding pad id 0 = P1's PHYSICAL pad;
    -- "P2 A" there (ids swapped: that PC is P2's) was P1's own press
    U.log(TAG, "P%d %s -> %s %s (%s): %s%s (V-MB-01/02)", p, what, e.cls, lname(b), how,
        ok and "clicked" or ("error " .. tostring(err)),
        (S.couchMode and p ~= 1) and " [P1's pad, on P" .. tostring(p) .. "'s PC: ids swapped]" or "")
end

---------------------------------------------------------------------------------------------------- input modes
-- run I: on the post-race results (owned by P2 in split) P1's PC sees no key at all (IsInputKeyDown(A) false while
-- P2's reads true): a player who must reach the bridge gets Game+UI input once per screen (non-owners of a shared
-- screen; 0.7.2: the pause controller on a pause screen another player owns).
local function openFor(e, p, why)
    S.inputOpened[e.k] = S.inputOpened[e.k] or {}
    if S.inputOpened[e.k][p] then return end
    S.inputOpened[e.k][p] = true
    local wbl, pc = U.WBL(), pcOf(p)
    if not (U.ok(wbl) and U.ok(pc)) then return end
    local ok, err = pcall(function() wbl:SetInputMode_GameAndUIEx(pc, nil, 0, false, false) end)
    U.log(TAG, "P%d input mode Game+UI on %s (%s): %s", p, e.cls, why, ok and "ok" or tostring(err))
end

-- 0.9.0 (run L, 3 players): on the P3-owned results screen P1's pad still did nothing (mouse only): the game's
-- InputModeManager keeps the FIRST local player in UI-only input, so P1's PC never sees the key the bridge polls,
-- whatever SetInputMode_GameAndUIEx did. P1's A does reach Slate: P1 gets Slate user focus on the screen's own focus
-- target (pause.lua's giveFocus trick), so its A clicks CONTINUE natively. Re-given at most every 500 ms while P1 holds
-- no focus inside the screen. cfg.MenuBridgeSharedFocus = true | false.  VERIFY(V-MB-07): "P1 focus on
-- WBP_SimpleRaceResultsScreen_C (...)" and P1's A leaves the results.
local function focusShared(e, p, now)
    if not opt("MenuBridgeSharedFocus", true) then return end
    S.sharedFocus = S.sharedFocus or {}
    local fk = tostring(e.k) .. ":" .. tostring(p)
    local st = S.sharedFocus[fk]
    if st and now < st.nextMs then return end
    local pc = pcOf(p)
    if not U.ok(pc) then return end
    local holds = false
    pcall(function() holds = e.w:HasUserFocusedDescendants(pc) == true end)
    S.sharedFocus[fk] = { nextMs = now + 500, n = (st and st.n or 0) + (holds and 0 or 1) }
    if holds then return end
    local t = nil
    pcall(function() t = e.w:GetDesiredFocusTarget() end)
    if not U.ok(t) then return end
    local ok = pcall(function() t:SetUserFocus(pc) end)
    if not st then
        U.log(TAG, "P%d focus on %s (%s): %s (V-MB-07)", p, e.cls, U.pathOf(t):match("([^.:]+)$") or "?",
            ok and "ok" or "failed")
    end
end

-- 0.10.0 (task #10): on a shared post-race screen another player owns, P1's PC still sees no key (the game keeps the
-- first local player in UI-only input whatever SetInputMode does, and Slate focus did not click: V-MB-07 failed live
-- in runs L and N1). The car input path does see the pad: each player's GfnRawInputSubsystem feeds its own
-- EnhancedPlayerInput with the vehicle contexts (A = IA_Veh_Boost; IA_Veh_Throttle in the alternative layout), and
-- ActionInstanceData (reflected TMap<InputAction, FInputActionInstance>) holds the trigger state. A held A is
-- Triggered/Started/Ongoing for longer than one FAST tick. cfg.MenuBridgeRawA = true | false.  VERIFY(V-MB-08)
local ACTIVE_TRIGGER = { [1] = true, [2] = true, [4] = true }      -- ETriggerEvent Triggered / Started / Ongoing
local function rawA(pc)
    local down = false
    pcall(function()
        local raw = pc.RawInputSubsystem
        if not U.ok(raw) then return end
        local alt = false
        pcall(function()
            raw.ActiveMappingContexts:ForEach(function(_, el)
                local c = el:get()
                if U.ok(c) and U.pathOf(c):find("IMC_Vehicle_Alternative", 1, true) then alt = true end
            end)
        end)
        local want = alt and "IA_Veh_Throttle" or "IA_Veh_Boost"
        local epi = raw.EnhancedPlayerInput
        if not U.ok(epi) then return end
        epi.ActionInstanceData:ForEach(function(k, v)
            if down then return end
            local ia = k:get()
            if U.ok(ia) and ia:GetFName():ToString() == want then
                local inst = v:get()
                if ACTIVE_TRIGGER[tonumber(inst.TriggerEvent) or 0] then down = true end
            end
        end)
    end)
    return down
end

-- 0.10.1 (task #10): P1's A on a shared screen another player owns reaches neither P1's PlayerInput nor its
-- EnhancedPlayerInput (V-MB-08 failed live), but Slate still delivers it to P1's focused widget. A CommonUI button
-- ignores it (its click comes from the owner's action router); a plain UMG Button handles the Accept key itself.
-- Probe 2026-10-10 on WBP_SimpleRaceResultsScreen_C: a Button added to the screen's root canvas and focused for P1
-- read IsPressed() = true while P1 held A. The bridge polls that invisible "catcher" like a key (V-MB-09).
local function catcherOf(e, create)
    S.catch = S.catch or {}
    local c = S.catch[e.k]
    if c and c.b and U.ok(c.b) then return c.b end
    if not create or (c and c.failed) then return nil end
    local b, err = nil, nil
    local ok = pcall(function()
        local tree = e.w.WidgetTree                                -- UUserWidget.WidgetTree
        local root = tree.RootWidget
        local cls = U.class("/Script/UMG.Button")
        if not (U.ok(root) and U.ok(cls)) then err = "no root panel or Button class"; return end
        b = StaticConstructObject(cls, tree)
        if not U.ok(b) then err = "Button not constructed"; b = nil; return end
        local rc = U.clsStr(root)                                  -- raises (no AV) on a NULL class
        if rc:find("Canvas", 1, true) then root:AddChildToCanvas(b)
        elseif rc:find("Overlay", 1, true) then root:AddChildToOverlay(b)
        else root:AddChild(b) end
        b:SetRenderOpacity(0.01)                                   -- invisible; focus and keys do not need paint
    end)
    if not ok or not b then
        S.catch[e.k] = { failed = true }
        U.warn(TAG, "P1 catcher on %s not made (%s): P1's A stays unbridged there (V-MB-09)", e.cls, tostring(err))
        return nil
    end
    S.catch[e.k] = { b = b, focusAt = -1e12 }
    U.log(TAG, "P1 catcher button added to %s (V-MB-09)", e.cls)
    return b
end

-- keeps P1's Slate focus on the catcher (re-checked every 500 ms; the screen's own focus logic may move it)
local function focusCatcher(e, now)
    local b = catcherOf(e, true)
    if not b then return false end
    local c = S.catch[e.k]
    if now - c.focusAt < 500 then return true end
    c.focusAt = now
    local pc = pcOf(1)
    if not U.ok(pc) then return true end
    local has = false
    pcall(function() has = b:HasUserFocus(pc) == true end)
    if not has then pcall(function() b:SetUserFocus(pc) end) end
    return true
end

local function catcherDown(e)
    local b = catcherOf(e, false)
    if not b then return false end
    local down = false
    pcall(function() down = b:IsPressed() == true end)
    return down
end

-- couch.sharedScreens(): the campaign world's shared screens (joined guests or dormant ones), false when unknown
local function sharedNow()
    local ok, v = pcall(function() return U.mod("couch").sharedScreens() end)
    return ok and v == true
end

local function openInputs(e)
    -- 0.15 COUCH CAMPAIGN: P1's PC carries the GUEST's pad while couch.lua swaps the ids; its focus belongs to the
    -- guest's own panel (couchpanel), not to a catcher
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if okC and couch == true then return end
    -- BUG 2 (couch-savepath): the same on a dormant guest's shared screen (couch.sharedScreens, pad ids swapped)
    if (St.phase == "OTHER" or St.phase == "POSTRACE") and sharedNow() then return end
    local own = ownerP(e.w)
    local now = St.nowMs()
    for _, lp in ipairs(U.localPlayersRO()) do
        if U.ok(lp.pc) and lp.index ~= own then
            openFor(e, lp.index, "its pad must reach the bridge")
            if lp.index == 1 then
                -- UI-only P1: the catcher reads its A (V-MB-09); without it, focus on the screen's target (V-MB-07)
                if not (opt("MenuBridgeP1Catcher", true) and focusCatcher(e, now)) then focusShared(e, 1, now) end
            end
        end
    end
end

-- 0.7.2: a pause screen owned by another player than the pause controller (checked once per screen)
local function fallbackInputs(e)
    if S.fb[e.k] or not opt("MenuBridgeControllerFallback", true) then return end
    S.fb[e.k] = true
    local cp, own = controllerP(), ownerP(e.w)
    if cp and own and cp ~= own then
        U.log(TAG, "%s is P%d's but the pause controller is P%d: the controller's A/B are bridged on it (V-MB-03)",
            e.cls, own, cp)
        openFor(e, cp, "pause controller")
    end
end

---------------------------------------------------------------------------------------------------- rules
local function noteNative(e, p)
    S.native[e.k] = S.native[e.k] or {}
    if S.native[e.k][p] then return end
    S.native[e.k][p] = true
    U.log(TAG, "P%d's own %s takes P%d's pad natively (IMC_UI boosted while paused): not bridged (V-MB-04)", p, e.cls, p)
end

-- 0.11.0 (hotfix CL382493, live 2026-10-10): a guest's A never clicks a row of its OWN pause menu natively, IMC_UI
-- boosted or not (its d-pad moves the focus; A on RESUME did not resume). Every pause-menu row closes or covers the
-- menu (resume, a confirm dialog, a sub-screen), so the MenuBridgeWaitMs re-check (same screen still up and activated)
-- never acts twice there: a guest's own pause menu is bridged whatever MenuBridgeGuestNative says. Its B too on the
-- screens opened from it (live: P2 stuck in Settings, B ignored): B leaves the screen (HandleBack applies Settings
-- first), so the same re-check covers it. A on in-place screens (Settings rows toggle) keeps the native-first rule.
-- cfg.MenuBridgeGuestPauseMenu = false: the 0.10 behaviour.
local function guestPauseMenu(e, what)
    if opt("MenuBridgeGuestPauseMenu", true) == false then return false end
    return what == "B" or (type(e.cls) == "string" and e.cls:find("^WBP_Pause") ~= nil)
end

-- A guest's press on its own pause menu also tells whether its native UI input works in this world: every row closes
-- or covers the menu, so "still up after MenuBridgeWaitMs" = native did nothing. Live 2026-10-10: native in a race
-- started from the front end, dead after RESTART RACE's seamless travel (the bridge clicked RESUME for P2). A dead
-- guest gets its A bridged on its in-place screens too (Settings rows) until the next world.
local function guestDead(p)
    return opt("MenuBridgeGuestPauseMenu", true) ~= false and S.guestDead ~= nil and S.guestDead[p] == St.worldGen
end

local function guestProbe(e, p)
    return p >= 1 and ownerP(e.w) == p and pausedNow() and type(e.cls) == "string" and e.cls:find("^WBP_Pause") ~= nil
end

local function noteGuestNative(p, acted)
    S.guestDead = S.guestDead or {}
    local dead = S.guestDead[p] == St.worldGen
    if acted and dead then
        S.guestDead[p] = nil
        U.log(TAG, "P%d's native menu input acted again: its own screens are native-first again (V-MB-10)", p)
    elseif not acted and not dead then
        S.guestDead[p] = St.worldGen
        U.log(TAG, "P%d's native A / B did nothing on its own pause menu (world #%s): its presses on its own screens "
            .. "are bridged until the next world (V-MB-10)", p, tostring(St.worldGen))
    end
end

-- may player p's press (what = "A" | "B") be bridged on screen e?
local function bridgeable(e, p, what)
    local own = ownerP(e.w)
    local paused = pausedNow()
    if e.dialog then                                     -- 0.7.2: confirm dialogs (P1-owned persistent container)
        if not opt("MenuBridgeDialogs", true) then return false end
        if own == p then return p ~= 1 end               -- P1 answers its own dialog natively
        if paused then return p == controllerP() end     -- the pause controller answers it
        return St.phase == "POSTRACE"                    -- post-race: any player
    end
    -- couch shop: A and B, never while a pause / player menu is up over it (the shop stays activated under it)
    if e.cnat == "shop" then return (what == "A" or what == "B") and not paused end
    if e.cnat == "pause" then return what == "A" or what == "B" end
    if e.cnat == "menu" then return what == "B" end
    -- couch-scaccept: the sponsor screen (A + VIEW), P1's own garage (B; A / D-pad native), any other guest screen
    if e.cnat == "sponsor" then return (what == "A" or what == "View") and not paused end
    if e.cnat == "garage" then
        if paused then return false end
        if what == "B" then return true end
        if what ~= "A" then return false end
        if e.cls == "WBP_Paddock_VehicleCust_C" then return opt("CouchP1GarageRootA", true) ~= false end
        return opt("CouchP1GaragePageA", true) ~= false
    end
    if e.cnat == "generic" then return (what == "A" or what == "B") and not paused end
    -- the pre-run loadout: only while it is a guest's screen driven through the swap (P1's own one is native)
    if e.cnat == "loadout" then
        if what ~= "A" or own == 1 then return false end
        -- #104: P1's START RUN is held while a guest is not READY (couchprerun: its interaction is off, "WAITING FOR")
        local okH, held = pcall(function() return U.mod("couchprerun").p1Held() end)
        if okH and held == true then
            U.logEvery("mb.loadoutheld", 3000, TAG, "P1's A on the loadout: START RUN held (a guest is not READY)")
            return false
        end
        local okS, sw = pcall(function() return U.mod("couch").swapped() end)
        return okS and sw == true
    end
    if e.cnat then return what == "A" end                -- couch: P1's pad only (fastTick's couchOnly filter)
    if e.shared then return what == "A" end              -- shared post-race screens: anyone's A (P2-owned in split)
    if own == p then                                     -- the owner: a guest is bridged, P1 works natively
        -- couch-finish (live 2026-10-17 #16): after P2 finished, P1's START opened HIS pause (owner P1, ctrlId 0) but
        -- his pad's A / B never acted on it (P2's A resumed it, 50 s later). P1's own race pause in a couch race is
        -- now bridged like a guest's once his native press was seen dead in this world (the first unanswered press is
        -- the probe, see the pending check in fastTick): each press waits MenuBridgeWaitMs, a native press that acted
        -- (RESUME closes the menu, a row covers it) is never clicked again. cfg.MenuBridgeP1Pause = false: native only.
        if p == 1 then
            -- (B also on the screens opened from it, A only on the pause menu itself: guestPauseMenu's rule)
            return S.couchRace == true and paused and opt("MenuBridgeP1Pause", true) ~= false
                and (what == "B" or (type(e.cls) == "string" and e.cls:find("^WBP_Pause") ~= nil))
        end
        if paused and opt("MenuBridgeGuestNative", "skip") == "skip" and pauseCall("guestUiNative", pcOf(p)) == true
            and not guestPauseMenu(e, what) and not guestDead(p) then
            noteNative(e, p)                             -- 0.7.2: native A/B already reach it (run I)
            return false
        end
        return true
    end
    -- couch race (input matrix racepause): a pause another player opened takes my A / B as RESUME only (click())
    if S.couchRace and paused and type(e.cls) == "string" and e.cls:find("^WBP_Pause") then return what == "A" or what == "B" end
    -- 0.7.2: the pause controller on a screen another player owns (a page the pre-create missed)
    if paused and opt("MenuBridgeControllerFallback", true) and p == controllerP() then return true end
    -- run I/J: a pause the game opened by itself (its inactivity auto-pause) is P1's: another player's A clicks the
    -- entry it selected (RESUME by default)
    return what == "A" and e.cls:find("Pause", 1, true) ~= nil
end

local function stillUp(e)
    if e.dialog then return true end                     -- top() has just found it on screen
    local still = false
    pcall(function() still = e.w:IsActivated() == true end)
    if not still and e.cnat == "garage" and e.cls ~= "WBP_Paddock_VehicleCust_C" then    -- a page found by class (garagePages)
        pcall(function() still = e.w:IsInViewport() == true and e.w:IsVisible() == true end)
    end
    return still
end

---------------------------------------------------------------------------------------------------- tick
-- (couch-livefix r2, live 2026-10-16 round 2: "P1's hold-A on EXIT TO MAIN MENU never completes, had to kill the game")
-- The race pause's EXIT TO MAIN MENU is LOCKED by the game in a campaign race (decoded WBP_PauseRacing PreConstruct:
-- Btn_Exit:SetIsLocked(true) unless one of its SafeExitToMenuStates - the CSM_RF_Results_Campaign* states - is active;
-- the padlock in the round-2 shots): a click or a hold on it only runs BP_OnLockClicked, the only ways out are ABANDON
-- TOUR or finishing the race. With guests on the couch (joined or dormant) the mod unlocks it: its own click path then
-- asks the game's QuitToMenu confirm (P1's Dialog container) and ReturnToMainMenu; CONTINUE resumes the run from its
-- last save (the node pick = this race), exactly what killing the game did. The pause menu has no hold button (no
-- bRequiresHold on WBP_Vertical_Btn; the confirm dialogs' buttons are plain clicks: DT_DialogData). One local player
-- = the game's rule (fastTick returns before). cfg.CouchRaceExitUnlock = false keeps the lock.
-- couch-fix61 (AUTO-148, live round 6 09:06:59, 2P takedown field test): the unlocked row opened the game's QuitToMenu
-- confirm, but in a FIELD TEST that confirm's buttons stay non-interactable (IsInteractionEnabled false; SetIsLocked /
-- SetIsInteractionEnabled / HandleButtonClicked / DeactivateWidget change nothing): every pad dead, the game had to be
-- killed. Solo shows the same row with its padlock in a field test (shot 111322-r6-82) and the game only opens the exit
-- at the results. Parity: a field test (any race-alone test kind: couchsolo.info().kind - takedowns, ramjet, time
-- trial / podracer test, hot lap, precision) keeps the game's lock; at its results the game unlocks the row itself.
local function fieldTestKind()
    local ok, k = pcall(function() return U.mod("couchsolo").info().kind end)
    if ok and type(k) == "string" then return k end
    return nil
end
M._fieldTestKind = fieldTestKind

local EXIT_PH = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }
local function exitUnlock()
    if opt("CouchRaceExitUnlock", true) == false or not EXIT_PH[St.phase] then return end
    for _, e in ipairs(S.screens or {}) do
        local act = false
        if e.cls == "WBP_PauseRacing_C" and U.alive(e.w) then pcall(function() act = e.w:IsActivated() == true end) end
        if act then
            -- re-checked at every scan (a re-added screen runs its PreConstruct again, the lock comes back)
            local b = nil
            pcall(function() b = e.w.Btn_Exit end)
            local locked = false
            if U.alive(b) then pcall(function() locked = b:GetLocked() == true end) end
            local run = false
            if locked then
                pcall(function() run = U.giSubsystem("/Script/Griffin.CampaignSubsystem"):HasActiveRun() == true end)
            end
            local ftk = (locked or S.exitUnlocked == e.k) and fieldTestKind() or nil
            if ftk then
                -- AUTO-148: the game's lock stays (re-locked if this pause was unlocked before the test kind was known)
                if not locked and S.exitUnlocked == e.k and St.phase ~= "POSTRACE" and U.alive(b) then
                    pcall(function() b:SetIsLocked(true) end)
                end
                S.exitUnlocked = nil
                if S.exitLockKey ~= e.k then
                    S.exitKey, S.exitLockKey = e.k, e.k
                    U.log(TAG, "campaign race pause: EXIT TO MAIN MENU stays LOCKED in a field test (%s), as solo: the "
                        .. "game's confirm cannot be answered there (AUTO-148); the results unlock it", ftk)
                end
                locked, run = false, false
            end
            if locked and run then
                local ok = pcall(function() b:SetIsLocked(false) end)
                if ok then S.exitUnlocked = e.k end
                if S.exitKey ~= e.k then
                    S.exitKey = e.k
                    U.log(TAG, "campaign race pause: EXIT TO MAIN MENU unlocked for the couch (%d local players; the "
                        .. "game locks it outside the results): %s", #U.localPlayers(), ok and "ok" or "failed")
                end
            end
        end
    end
end

function M.fastTick()
    if not enabled() then return end
    -- 0.15 COUCH CAMPAIGN: P1 alone drives the shared screens. Only the PlayerController that carries P1's PHYSICAL
    -- pad now (ControllerId 0: couch.lua's pad-id swap moves it to the screen owner) is bridged; a guest's A would
    -- pick P1's reward or node. The P1 catcher / raw-A paths read P1's PC, which holds the guest's pad while swapped.
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    local couchOnly = nil
    -- input matrix (couchsim racepause, 2026-10-15): the P1-pad-only rule belongs to the SHARED phases (paddock and
    -- post-race: the pad-id swap). In a couch race (LOADING / PRERACE / RACING) every player pauses for himself like in
    -- FREE MODE (pause.lua makes the pause for the presser) - P1-only left a guest unable to answer his own pause menu
    -- (his native A never clicks it, 0.11.0) and let P1's A click the row the guest had picked.
    S.couchRace = okC and couch == true and St.phase ~= "OTHER" and St.phase ~= "POSTRACE"
    -- BUG 2 (couch-savepath, live 2026-10-16): all guests left, their PCs dormant: the paddock / post-race screens are
    -- still a dormant PC's and couch.lua swaps the ids for them (couch.sharedScreens): the same P1-only bridge
    local sharedP = (St.phase == "OTHER" or St.phase == "POSTRACE") and ((okC and couch == true) or sharedNow())
    if sharedP then
        local GS = U.cdo("GameplayStatics")
        S.couchPc = nil
        for _, lp in ipairs(U.localPlayersRO()) do
            local okI, id = pcall(function() return GS:GetPlayerControllerID(lp.pc) end)
            if okI and id == 0 then couchOnly, S.couchPc = U.key(lp.pc), lp.pc end
        end
        if not couchOnly then S.pending = nil; return end
        -- world changes: no widget scan inside couch.lua's quiet window (FindAllOf + UFunction crashes, 2026-10-14)
        local okQ, q = pcall(function() return U.mod("couch").isQuiet() end)
        if okQ and q == true then S.pending, S.screens = nil, {}; return end
    end
    S.couchMode = couchOnly ~= nil
    local lps = U.localPlayers()
    if #lps < 2 then S.pending = nil; return end
    local now = St.nowMs()
    -- menus only exist while paused (pause / player menu, their sub-screens and dialogs) or after the race (results);
    -- couch: also the paddock (OTHER), for the COUCH_SCREENS screens only (a mystery interaction is not paused)
    local paused = pausedNow()
    local couchPaddock = S.couchMode and St.phase == "OTHER"
    if not paused and St.phase ~= "POSTRACE" and not couchPaddock then
        S.screens, S.pending, S.dlg, S.dlgE, S.catch = {}, nil, nil, nil, {}
        return
    end
    U.tryEvery("mb.scan", nil, TAG, scan, now)
    U.tryEvery("mb.exit", nil, TAG, exitUnlock)
    local e = top(now)
    if couchPaddock and not paused and e and not e.cnat then e = nil end
    -- couch map screens: their state one tick ago (native input acts at the key-down event, before this poll)
    if S.couchMode and e and e.cnat == "overview" then
        local v = nil
        pcall(function() v = tonumber(e.w.WBP_PlanetSelector.SelectedIndex) end)
        S.ovPrev, S.ovCur = S.ovCur, v
        if S.ovPrev == nil then S.ovPrev = v end
    elseif S.couchMode and e and e.cnat == "nodemap" then
        local v = chosenNodeKey()
        S.nodePrev, S.nodeCur = S.nodeCur, v
        if S.nodePrev == nil then S.nodePrev = v end
    elseif S.couchMode and e and e.cnat == "shop" then
        local v = shopSig(e)
        if S.shopK ~= e.k then S.shopK, S.shopCur = e.k, nil end
        S.shopPrev, S.shopCur = S.shopCur, v
        if S.shopPrev == nil then S.shopPrev = v end
        if not paused and opt("CouchShopBridge", true) ~= false then U.try(TAG, shopCursor, e, S.couchPc, now) end
    elseif S.couchMode and e and e.cnat == "garage" and not paused then
        -- couch-p1garage (#27): the page's tab / selection one tick ago (native-first check of a bridged A), his cursor,
        -- his LB / RB
        if S.gK ~= e.k then S.gK, S.gSigCur = e.k, nil end
        local v = garageSig(e)
        S.gSigPrev, S.gSigCur = S.gSigCur, v
        if S.gSigPrev == nil then S.gSigPrev = v end
        U.try(TAG, garageCursor, e, now)
        U.try(TAG, garageTabs, e, now)
    else
        S.ovPrev, S.ovCur, S.nodePrev, S.nodeCur = nil, nil, nil, nil
        S.shopPrev, S.shopCur, S.shopK = nil, nil, nil
        S.gK, S.gSigPrev, S.gSigCur, S.gt = nil, nil, nil, nil
    end
    if e and e.shared then U.tryEvery("mb.inputs", nil, TAG, openInputs, e) end
    if e and paused and not e.dialog and not e.shared then U.tryEvery("mb.fb", nil, TAG, fallbackInputs, e) end
    if not (e and e.dialog) then S.dlg = nil end
    -- a pending press: the game had its chance; the same screen still on top (re-read now) -> click it ourselves
    local pd = S.pending
    if pd and now - pd.atMs >= (pd.wait or waitMs()) then
        S.pending = nil
        U.tryEvery("mb.scan", nil, TAG, scan, now, true)
        local e2 = top(now, true)
        local still = e2 ~= nil and e2.k == pd.k and stillUp(e2)
        -- couch: a screen that came up on top since the press = the native press acted (input matrix pausepad: LOGBOOK
        -- covers the pause, which stays activated under it and still wins top() as a COUCH_SCREENS screen: a second
        -- click opened the Logbook twice)
        local newest = S.screens[1]
        if still and S.couchMode and newest and newest.k ~= e2.k and (newest.at or 0) >= pd.atMs then
            still = false
            U.log(TAG, "couch: P1's %s on %s acted natively (%s came up on top): not bridged", pd.what, e2.cls, newest.cls)
        end
        -- couch node map: a node chosen since the press = the native click acted (a second click would pick twice)
        if still and pd.chosen ~= nil and chosenNodeKey() ~= pd.chosen then
            still = false
            U.log(TAG, "couch: P1's A on %s acted natively (node chosen): not bridged", e2.cls)
        end
        -- couch shop: credits / switcher page / activation moved since the tick before the press = the native press acted
        if still and pd.sig ~= nil and e2.cnat == "shop" then
            local now2 = shopSig(e2)
            if now2 ~= pd.sig then
                still = false
                U.log(TAG, "couch: P1's %s on %s acted natively (%s -> %s): not bridged", pd.what, e2.cls, pd.sig, now2)
            end
        end
        -- couch-p1garage (#27): his own garage page's tab / selected entry moved since the tick before the press = the
        -- native A acted (an equip)
        if still and pd.gsig ~= nil and e2.cnat == "garage" then
            local now2 = garageSig(e2)
            if now2 ~= nil and now2 ~= pd.gsig then
                still = false
                U.log(TAG, "couch: P1's %s on %s acted natively (%s -> %s): not bridged", pd.what, e2.cls, pd.gsig, now2)
            end
        end
        -- couch-scaccept kinds: a CosmeticStateMachine change since the press = the game acted (a state action shows
        -- the next screen); VIEW: the player menu came up by itself
        if still and pd.csm ~= nil and couchCsmSeq() ~= pd.csm then
            still = false
            U.log(TAG, "couch: P1's %s on %s acted natively (state machine changed): not bridged", pd.what, e2.cls)
        end
        if still and pd.what == "View" and playerMenuUp() then
            still = false
            U.log(TAG, "couch: P1's VIEW on %s acted natively (player menu up): not bridged", e2.cls)
        end
        -- couch-finish (#16): P1's own pause is bridged only once his native A / B was seen dead in this world (the
        -- first unanswered press is the probe, not clicked): a native action that leaves the menu up longer than the
        -- wait (an in-place row, a slow dialog) is never doubled while his pad works (couchsim pauseexit couch)
        -- #64: a strike popup is no probe: its CONTINUE closes it (the wait re-check sees a native press), and only
        -- pause screens ever end the probe (pd.probe) - on P1's own stacked popups every A was swallowed here forever
        local p1Probe = pd.p == 1 and still and ownerP(e2.w) == 1 and not guestDead(1) and e2.cnat ~= "strikes"
        if pd.probe then noteGuestNative(pd.p, not still) end
        if still and not p1Probe then U.try(TAG, click, e2, pd.p, pd.what) end
        e = e2
    end
    local K = keys()
    -- couch-scaccept: P1's physical pad's edges from the DLL's pad watch (read every couch tick: the baseline moves on)
    local pw = S.couchMode and padEdges() or { a = false, b = false, view = false }
    if not S.couchMode then S.pw = nil end
    local pwKind = S.couchMode and e and PW_KINDS[e.cnat] == true
    for _, lp in ipairs(lps) do
        local pc = lp.pc
        if U.ok(pc) and (couchOnly == nil or U.key(pc) == couchOnly) then
            local k = U.key(pc)
            local a, b, dir = false, false, 0
            pcall(function()
                a = pc:IsInputKeyDown(K.A) == true or (lp.index == 1 and pc:IsInputKeyDown(K.Enter) == true)
                -- couch loadout: the key never reaches PlayerInput there (live 2026-10-15), the owner's IA_UI_Accept does
                if not a and couchOnly ~= nil and e and (e.cnat == "loadout" or pwKind) then a = uiAcceptDown(pc) end
                if not a and couchOnly == nil and e and e.shared and lp.index == 1 and opt("MenuBridgeP1Catcher", true)
                    and lp.index ~= ownerP(e.w) then
                    a = catcherDown(e)
                    if a and not S.prevA[U.key(pc)] then
                        U.logEvery("mb.catch", 2000, TAG, "P1 A read from the catcher button on %s (V-MB-09)", e.cls)
                    end
                end
                if not a and couchOnly == nil and e and e.shared and opt("MenuBridgeRawA", false) ~= false
                    and lp.index ~= ownerP(e.w) then
                    a = rawA(pc)
                    if a and not S.prevA[U.key(pc)] then
                        U.logEvery("mb.rawA" .. tostring(lp.index), 2000, TAG,
                            "P%d A read from its raw vehicle input on %s (V-MB-08)", lp.index, e.cls)
                    end
                end
                b = pc:IsInputKeyDown(K.B) == true
                if e and e.dialog then                   -- D-pad read only while a confirm dialog is up
                    if pc:IsInputKeyDown(K.Left) == true or pc:IsInputKeyDown(K.Up) == true then
                        dir = -1
                    elseif pc:IsInputKeyDown(K.Right) == true or pc:IsInputKeyDown(K.Down) == true then
                        dir = 1
                    end
                elseif e and e.cnat == "overview" and couchOnly ~= nil then   -- couch: the planet overview
                    if pc:IsInputKeyDown(K.Left) == true then dir = -1
                    elseif pc:IsInputKeyDown(K.Right) == true then dir = 1 end
                end
            end)
            -- couch-scaccept: VIEW (IA_UI_PlayerMenu's pad key) on the couch PC, and the pad-watch edges
            local v = false
            if couchOnly ~= nil and pwKind then pcall(function() v = pc:IsInputKeyDown(K.View) == true end) end
            local aE = (a and not S.prevA[k]) or (couchOnly ~= nil and pwKind and pw.a)
            local bE = (b and not S.prevB[k]) or (couchOnly ~= nil and pwKind and pw.b)
            local vE = (v and not (S.prevV or {})[k]) or (couchOnly ~= nil and pwKind and pw.view)
            S.prevV = S.prevV or {}
            S.prevV[k] = v
            -- (couch-livefix r3) P1's START on the paddock map (overview / node map) of a guest- / dormant-owned host
            local st = false
            if couchOnly ~= nil and e and (e.cnat == "overview" or e.cnat == "nodemap") and S.host
                and S.host.def.kind == "paddock" and opt("CouchMapPauseBridge", true) ~= false then
                pcall(function() st = pc:IsInputKeyDown(K.Start) == true end)
                if st and not S.prevS[k] then U.try(TAG, mapPause, e, S.host) end
            end
            S.prevS[k] = st
            -- couch: P1's press on a shared screen usually changes the screen (a new switcher page, a dialog): the shared
            -- scan runs in full on the next calls (couch.lua's scan only re-reads on such edges)
            if couchOnly ~= nil and (aE or bE or vE or (dir ~= 0 and (S.prevD[k] or 0) == 0)) then
                pcall(function() U.mod("couch").markDirty("P1 press") end)
            end
            -- couch-rewards2: P1's reward flow is bridged for P1's pad alone (the PC holding id 0, any swap state)
            local fenced = e and e.p1Reward and (aE or bE) and not (couchOnly ~= nil or holdsPad0(pc))
            if fenced then
                U.logEvery("mb.fence" .. tostring(lp.index), 3000, TAG, "P%d's %s on P1's %s: not bridged (only P1's pad "
                    .. "presses P1's reward flow)", lp.index, aE and "A" or "B", e.cls)
            end
            if e and not S.pending and not fenced then
                local csm = pwKind and couchCsmSeq() or nil
                local pwWait = pwKind and math.max(waitMs(), PW_WAIT_MS) or nil
                if aE and bridgeable(e, lp.index, "A") then
                    S.pending = { k = e.k, p = lp.index, what = "A", atMs = now, probe = guestProbe(e, lp.index),
                                  wait = (e.cnat == "loadout") and math.max(waitMs(), LOADOUT_WAIT_MS) or pwWait,
                                  chosen = (e.cnat == "nodemap") and (S.nodePrev or chosenNodeKey()) or nil,
                                  sig = (e.cnat == "shop") and (S.shopPrev or shopSig(e)) or nil, csm = csm,
                                  gsig = (e.cnat == "garage") and S.gSigPrev or nil }
                elseif bE and not e.shared and bridgeable(e, lp.index, "B") then
                    S.pending = { k = e.k, p = lp.index, what = "B", atMs = now, probe = guestProbe(e, lp.index),
                                  sig = (e.cnat == "shop") and (S.shopPrev or shopSig(e)) or nil, csm = csm, wait = pwWait }
                elseif vE and bridgeable(e, lp.index, "View") then
                    S.pending = { k = e.k, p = lp.index, what = "View", atMs = now, csm = csm, wait = pwWait }
                elseif dir ~= 0 and (S.prevD[k] or 0) == 0 and e.dialog and bridgeable(e, lp.index, "A") then
                    U.try(TAG, dialogMove, e, lp.index, dir)
                elseif dir ~= 0 and (S.prevD[k] or 0) == 0 and e.cnat == "overview" then
                    U.try(TAG, overviewNav, e, dir)
                end
            end
            S.prevA[k], S.prevB[k], S.prevD[k] = a, b, dir
        end
    end
end

---------------------------------------------------------------------------------------------------- front end (0.7.2)
local FE = { handle = nil, menuKey = 0, card = nil, lastFindMs = -1e12, tries = {} }

-- breadth-first over a UserWidget's own WidgetTree panels for the widget named name (nested UserWidgets not entered)
local function findNamed(uw, name, max)
    local panel = classOf(PANEL_CLASS)
    if not panel then return nil end
    local queue, head = {}, 1
    pcall(function()
        local tree = uw.WidgetTree
        if U.ok(tree) and U.ok(tree.RootWidget) then queue[1] = tree.RootWidget end
    end)
    while head <= #queue and head <= max do
        local o = queue[head]
        head = head + 1
        if lname(o) == name then return o end
        pcall(function()
            if o:IsA(panel) then
                for i = 0, (o:GetChildrenCount() or 0) - 1 do
                    local ch = o:GetChildAt(i)
                    if U.ok(ch) then queue[#queue + 1] = ch end
                end
            end
        end)
    end
    return nil
end

-- the game's main menu: menu_tab's installed instance (St.menu.widget), else FindFirstOf at most every 3 s
local function feMenu(now)
    local mm = St.menu and St.menu.widget
    if U.ok(mm) then return mm end
    if now - FE.lastFindMs < 3000 then return nil end
    FE.lastFindMs = now
    local ok, m = pcall(FindFirstOf, "WBP_FE_MainMenu_C")
    return (ok and U.ok(m)) and m or nil
end

local function feStop(why)
    if FE.handle then
        sched.cancel(FE.handle)
        FE.handle = nil
        U.dbg(TAG, "front-end profile loop stopped (%s)", tostring(why))
    end
    FE.card, FE.menuKey = nil, 0
end

-- every 1 s in FRONTEND / LAUNCHING with 2+ local players: the main menu's profile card owned by a guest -> P1
-- (at most 3 attempts per card instance: GetText / SetText build FTexts).  VERIFY(V-MB-06)
local function feTick()
    if St.phase ~= "FRONTEND" and St.phase ~= "LAUNCHING" then return feStop("phase " .. tostring(St.phase)) end
    if St.launchHold() then return end      -- 0.12.0: the main menu is being torn down (state.lua St.launchHold)
    if not enabled() or not opt("MenuBridgeProfileOwner", true) then return end
    local lps = U.localPlayers()
    if #lps < 2 or not U.ok(lps[1].pc) then return end
    local p1 = lps[1].pc
    local mm = feMenu(St.nowMs())
    if not mm then return end
    local mk = U.key(mm)
    if mk ~= FE.menuKey then FE.menuKey, FE.card = mk, nil end
    if not U.ok(FE.card) then
        FE.card = findNamed(mm, "WBP_MP_ProfileCard", 300)
        if not U.ok(FE.card) then FE.card = nil; return end
    end
    local card = FE.card
    local owner
    pcall(function() owner = card:GetOwningPlayer() end)
    if not U.ok(owner) or U.key(owner) == U.key(p1) then return end
    local op = pnumOf(owner)
    if not op then return end                            -- not a local PC: not the UIManager-owner case
    local ck = U.key(card)
    FE.tries[ck] = (FE.tries[ck] or 0) + 1
    if FE.tries[ck] > 3 then return end
    -- SetOwningPlayer re-adds a widget that sits in the viewport itself (RemoveFromParent + AddToPlayerScreen): the
    -- card is a child of the main menu's tree, so only its player context changes. Anything else is left alone.
    local inVp = false
    pcall(function() inVp = card:IsInViewport() == true end)
    if inVp then
        if FE.tries[ck] == 1 then U.warn(TAG, "front-end profile card %s is a viewport widget: owner left (V-MB-06)", lname(card)) end
        return
    end
    local before, name = "?", nil
    pcall(function() before = U.str(card.Txt_PlayerName:GetText()) end)
    local okO = pcall(function() card:SetOwningPlayer(p1) end)
    pcall(function() name = U.str(p1.PlayerState:GetPlayerName()) end)
    local okN = type(name) == "string" and name ~= ""
        and pcall(function() card.Txt_PlayerName:SetText(U.ftext(name)) end)
    local okR = pcall(function() card:PvpRankUpdated() end)          -- BP events: re-read GetOwningPlayer()
    local okP = pcall(function() card:PlatformIconUpdated() end)
    U.log(TAG, "front-end profile card %s: owner P%d (UIManager owner = last local PC) -> P1: SetOwningPlayer %s; name "
        .. "'%s' -> '%s' %s; rank %s, platform %s (try %d) (V-MB-06)", lname(card), op, okO and "ok" or "failed",
        tostring(before), tostring(name), okN and "ok" or "failed", okR and "ok" or "failed", okP and "ok" or "failed",
        FE.tries[ck])
end

local function feStart(why)
    if FE.handle or not enabled() or not opt("MenuBridgeProfileOwner", true) then return end
    FE.handle = sched.every("menubridge.fe", 1000, feTick)
    U.dbg(TAG, "front-end profile loop started (%s)", tostring(why))
end

---------------------------------------------------------------------------------------------------- api
function M.status()
    local t = top(St.nowMs())
    return { screens = #S.screens, top = t and t.cls or "-", topOwner = t and ownerP(t.w) or nil, clicks = S.clicks,
             dialog = (t and t.dialog) == true, feLoop = FE.handle ~= nil }
end

function M.init()
    St.on("phase", TAG, function(new)
        if new ~= "PRERACE" and new ~= "RACING" and new ~= "POSTRACE" then
            S.screens, S.seenAt, S.pending, S.prevA, S.prevB, S.prevD, S.prevS = {}, {}, nil, {}, {}, {}, {}
            S.inputOpened, S.native, S.fb, S.dlg, S.dlgE = {}, {}, {}, nil, nil
        end
        S.shownK = {}                              -- object keys are reused across worlds
        S.recapReady, S.unlockAt = {}, nil
        if new == "FRONTEND" or new == "LAUNCHING" then feStart("phase " .. new) else feStop("phase " .. tostring(new)) end
    end)
    if St.phase == "FRONTEND" or St.phase == "LAUNCHING" then feStart("init") end
    -- AUTO-149: the recap's CONTINUE binding (a BP post-hook; queued until the recap class is in memory)
    U.hook(M.RECAP_READY_HOOK, { post = function(ctx) return M.onRecapReady(ctx) end }, TAG .. ".recap")
    U.log(TAG, "init 0.7.2: MenuBridge=%s wait %d ms (guest-owned screens: owner's A/B unless native, GuestNative %s; "
        .. "shared post-race screens: anyone's A); dialogs %s, back %s, controller fallback %s, profile owner %s",
        tostring(enabled()), math.floor(waitMs()), opt("MenuBridgeGuestNative", "skip"),
        tostring(opt("MenuBridgeDialogs", true)), tostring(opt("MenuBridgeBack", true)),
        tostring(opt("MenuBridgeControllerFallback", true)), tostring(opt("MenuBridgeProfileOwner", true)))
end

return M
