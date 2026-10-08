-- pause.lua (G5): pause menus in local split races: any local player's Start (or Back/View: the player menu) opens the
--   game's own full-screen pause screen, owned and navigated by that player.                       [ARCH 1.6]
--   cfg.GuestPauseMode = "hud"  (default): the guest HUD's own IA_Veh_Pause binding does it (WBP_Hud_Race
--                                 ubergraph 1443: CSM manager -> GetStateMachineForRoot(CSM_PauseMenus_Root)
--                                 -> ChangeStateTo(CSM_PauseMenus_PauseMenu)) [HUD 3.2]; plus (cfg.GuestPauseFallback,
--                                 default true) the guests' Start poll below as a deferred fallback.
--                        "poll"  : FAST poll of the guest PCs' Start button, then the same CSM call from Lua.
--                        "off"   : guests cannot pause.
--   cfg.P1PausePoll (default true): while P1 has no race-HUD binding of its own (P1HudMode "rehost": the re-add drops
--     the HUD's IA_Veh_Pause binding; 0.7.0: also a guest-owned game HUD without a P1 clone), P1's Start (pad) and
--     Escape (keyboard) are polled the same way.
--   A press is acted on only when the game was not paused at the previous poll either: the press that closes the
--   pause menu (handled by the menu itself) must not reopen it. Every polled press waits cfg.PauseDeferMs and is
--   dropped if the game paused by itself meanwhile (no double ChangeStateTo when the HUD's binding works).
--   No Blueprint-function hook is used here (BP hooks never fired in the 2026-10-06 runs).
-- Revision 2026-10-07 (run E, "pressing Start pauses the game but no pause menu shows"): while the game is paused the
--   pause menu (CSM_PauseMenus_Paused_Racing shows WBP_PauseRacing_C in UIManager layer Menu) is probed and fixed
--   (block "pause menu"): visibility/opacity forced visible; probe lines "pause menu probe ..." (V-PAU-04).
-- Revision 2026-10-07 (run F, f-11.png "pause menu faint under a white overlay"): the screenshot was taken 19 ms after
--   a rehost, on the first frames of the menu's intro animation; our HUDs are hidden on the pause edge itself
--   (cfg.PauseHideHudsAtOnce), "pause menu parts" probe lines log the animated parts, and cfg.PauseMenuSettle restores
--   any part still below its intro-animation end value cfg.PauseMenuSettleMs after first sight (V-PAU-06).
-- Revision 2026-10-07 0.6.0 (run G, F2 "a guest-opened pause menu is invisible"): WBP_PlayerMenu_Presentation_C
--   (IA_Veh_Player = Back/View opens CSM_PauseMenus_PlayerMenu, a pausing state) is a pause screen too; probe lines add
--   focus=[Pn], states=[active pause CSM sub-states] and menuLayer=<UIManager Menu layer count>.
-- Revision 2026-10-07 0.7.0 (run H: a guest's Start soft-locked the game in [PauseMenu] with no screen; every pause
--   screen of a split race took no input, rehosted or not; after P1's wreck nobody could pause any more).
--   notes/research/pause-split.md. Two single-player assumptions of the game collide in a split race: the UIManager
--   creates every screen for the LAST local PlayerController (P2 in 2P; no UFunction on that path, no hook can change
--   the owner), and the InputModeManager raises IMC_UI to 500 for the FIRST local player only (a guest's IMC_UI stays
--   under its vehicle IMC: A/B/Start stay vehicle keys). P2's soft lock: two IA_Veh_Pause bindings on P2's stack (the
--   P2-owned game HUD + P2's own HUD) -> a second ChangeStateTo(PauseMenu) on the active state leaves Paused_Racing.
--   0.7.0 layers, each with its own cfg switch (VERIFY V-PAU-09..18 at the end of this header):
--   A  HUD input guard: the guest-owned game HUD's input is unregistered while a split race runs; every HUD hud.lua
--      hosts loses its input from the pause request until resume + pause keys up (cfg.PauseHudInputGuard).
--   B  ONE native pre-hook, /Script/Griffin.CosmeticStateMachine:ChangeStateTo, registered while a split race runs
--      (ids in _G.SWGRCouch_pause_hooks, armed flag checked before any param is read; cfg.PauseCsmHook). It names the
--      request (newState, cfg.PauseHookReadState) and the pauser (the PC holding a pause key / just releasing View).
--   C  the screen is created by us for the controlling player right before the CSM's ShowWidget runs; ShowWidget
--      ACQUIRES it (UIManager acquire path: refcount 2, OwningStateMachine set); our extra reference is then released
--      (cfg.PauseMenuPrecreate, PauseMenuOwner, PauseOwnerPadShift, PauseMenuZ).
--   D  every guest's IMC_UI at UIManagerSettings.UI_IMC_ActivePriority while paused, back on resume (PauseUiImcBoost).
--   E  the owner's slate focus is put back on the menu's desired focus target when lost (cfg.PauseMenuFocusOwner).
--   F  safety net (cfg.PauseLostMenu): [PauseMenu] without a sub-state for PauseNoSubStateMs -> ChangeStateTo(the
--      BP_CsmPickPauseMenu choice); a menu state without its screen for PauseLostMenuMs -> resume; a non-owner's
--      Start resumes when the menu did not react (PauseAnyStartResumes). "Dialog up" = a persistent Dialog/
--      SystemDialog/MenuOverlay container holding a message (the hidden, empty WBP_Dialog_Container no longer counts).
--   G  after P1's wreck/finish the pause CSM (a sub-CSM of CSM_RF_InProgress) is gone: a pause key starts it again
--      (StartCosmeticStateMachine) and EndStateMachine() runs when the race phase ends (cfg.PauseRestartCsm).
--   The 0.5/0.6 rehost (RemoveFromParent + AddToViewport of the CSM's screen) is off: PauseMenuRehost "auto" (the old
--   default) = "never"; only "always" re-adds (A/B tests): the re-added screen took no input in run H.
--   The 0.6.0 lost-menu steps (re-add / reopen / resume) are replaced by F.
-- Static facts (scripts/reflect-func-all.py, 2026-10-06):
--   PlayerController:IsInputKeyDown(Struct Key) -> Bool
--   CosmeticStateMachineManager:GetStateMachineForRoot(Object rootAsset) -> Object
--   CosmeticStateMachine:ChangeStateTo(Object newState, Str reason, Object optionalPayload)
--   CosmeticStateMachineManager:IsStateActiveByRef(Object stateAsset) -> Bool   (through U.csmActive)
-- 0.7.0 static facts (scripts/reflect-types.py on the local exe copy, 2026-10-07):
--   ChangeStateTo(Object<UCsmAsset> newState, Str reason, Object optionalPayload) Native BlueprintCallable; a null
--     newState is a no-op. CosmeticStateMachine.mCsmAsset Object<UCsmAsset>, FuseScreenWidget.OwningStateMachine
--     Object<UCosmeticStateMachine> (both hard pointers: readable). CosmeticStateMachineManager:
--     StartCosmeticStateMachine(Object rootAsset), CosmeticStateMachine:EndStateMachine().
--   UIManager: AddExistingWidgetToLayer(Object widgetToAdd, Enum targetLayer), RemoveWidget(Class, Enum),
--     GetWidgetInLayer(Class, Enum) -> Object, GetWidgetCountInLayer(Enum) -> Int, GetInputModeManager() -> Object;
--     InputModeManager:OnControlMappingsRebuilt() (Native, not BlueprintCallable: ProcessEvent from Lua).
--   UIManagerSettings CDO: UI_IMC_ActivePriority Int (500), UI_IMC_DefaultPriority Int (0); UIInputMappingContext is
--     a SOFT pointer: never read (IMC_UI is found by its path instead).
--   EnhancedInputLocalPlayerSubsystem: AddMappingContext(Object, Int, Struct ModifyContextOptions{bIgnoreAllPressed
--     KeysUntilRelease, bForceImmediately, bNotifyUserSettings}), RemoveMappingContext(Object, Struct),
--     HasMappingContext(Object, out Int OutFoundPriority) -> Bool.
--   GameViewportSubsystem:GetWidgetSlot(Object Widget) -> Struct{..., ZOrder Int}.
--   NotificationContainerWidget: TargetName Name, NotificationSubPanel Object<PanelWidget>, IsHidden() -> Bool.
--   PlayerController:WasInputKeyJustPressed / WasInputKeyJustReleased(Struct Key) -> Bool.
--   IMC_Vehicle_Keyboard: IA_Veh_Pause = Escape, P; IA_Veh_Player = Tab, O (pads: Special_Right / Special_Left).
-- VERIFY (0.7.0, expected log lines in the lead's handoff): V-PAU-09 HUD input guard, V-PAU-10 IMC_UI boost,
--   V-PAU-11 hook + pre-create + acquire, V-PAU-12 lost-menu repair, V-PAU-13 any Start resumes, V-PAU-14 dialog test,
--   V-PAU-15 owner navigation + focus (+ KeyboardIsP1 pad shift), V-PAU-16 after-wreck restart, V-PAU-17 guest player
--   menu, V-PAU-18 held Start.
-- Review 0.7.0 (integration): St.hud.p1hud is validated before any member access (gameHudOwner); a request or pick
--   that no pause followed is undone after 600 ms (requestWatch: pre-created screen removed, guests' IMC_UI restored,
--   HUD inputs back once the pause keys are up). Every key read here is declared in config.lua (Pause section).
-- Revision 0.7.2 (phase 2: every screen opened FROM a pause belongs to the pause controller; research in the lead's
--   handoff, static: pause CSM states decoded with cue4cli from sparse paks, WBP_Pause / WBP_Settings / WBP_Stickerbook
--   / WBP_Modal bytecode, BoundActionNotificationWidget native code). Facts:
--   * Settings: WBP_Pause.OnSettingsButtonCalled -> OwningStateMachine->ChangeStateTo(CSM_PauseMenus_Settings), which
--     auto-enters Settings_Menu (ShowWidget WBP_Settings_C, Menu layer, ForceNewInstance false = acquire); its pages
--     (GammaCorrection, ViewControls, Credits, BrightnessCalibration) are acquire screens too (Back = SettingsMenu).
--   * Logbook: WBP_Pause -> OwningStateMachine->ChangeToState(soft CSM_PauseMenus_Stickerbook, "Open Stickerbook from
--     Pause menu") -> WBP_Stickerbook_C (acquire). ChangeToState resolves the soft pointer and calls the C++
--     ChangeStateTo body (0x140d14328) directly: the ChangeStateTo hook never sees it. Photo mode: ChangeToState(..., "")
--     and no CSM screen (the photo-mode manager's own UI for every player).
--   * Confirm dialogs (EXIT TO MAIN MENU = QuitToMenu via AddMessageParams, ABANDON TOUR = AbandonRun, RetryRace,
--     Settings ConfirmReset ...) are WBP_Modal_C (BoundActionNotificationWidget) in the persistent P1-owned Dialog
--     container: DT_DialogData Actions = [Accept -> ResultID Yes, Cancel -> No] (RevertSettingsConfirmation: Confirm /
--     Revert), ShouldGenerateInputActions false: one dynamic button per action in ButtonPanel_Dynamic, in that order,
--     created with CreateWidget(panel) (= the dialog's owner, P1), whose native click calls ReportResultAndRemove(Id).
--   * Run I: a guest's own pre-created pause screen took the guest's native A/B/Start while its IMC_UI was boosted (D):
--     no menubridge click was needed (sessions 1627/1634).
--   Changes (each switchable, read through opt(); VERIFY V-PAU-19..22 below):
--   * B2: a second native pre-hook, /Script/Griffin.CosmeticStateMachine:ChangeToState, same lifecycle as B (split race
--     only, armed flag first, unregistered at POSTRACE / "leaving"). HARD RULE: its soft newState param is NEVER read;
--     only ctx and the Str reason ("Open Stickerbook from Pause menu" -> Stickerbook) (cfg.PauseSubScreenHook).
--     Integration 0.8.0: OPT-IN (cfg.PauseSubScreenHook default false). ARCHITECTURE Revision 0.5.1 §1 forbids hooking
--     a function with a soft param (run F crashed right after the TestPreflightCheckInput hook, a SoftObject param), and
--     UE4SS's pre-dispatch wraps EVERY param of EVERY ChangeToState call (any CSM) while armed. Off: the Logbook is made
--     for the last local PC and menubridge's controller fallback drives it. On only for the dedicated V-PAU-20 run; the
--     lead amends the HARD RULE before the default changes.
--   * C2: a request for Settings / its pages (ChangeStateTo, newState read) or the Logbook (B2) pre-creates that screen
--     for the pause controller (ownerFor(pauser): the owner the pause screen got) with the 0.7.0 recipe; the previous
--     pre-created screen of the pause is retired first (retirePre) (cfg.PauseSubScreenPrecreate).
--   * D2: while a confirm dialog is up the guests' IMC_UI goes back to its default, so the A/B the pause controller
--     gives the dialog (menubridge) do not also hit the guest's own pause screen under it (cfg.PauseDialogGuestUi).
--   * E2: sub-screen probes (+0 / +500 ms: owner, osm, focus, controller) and one owner focus fix per screen.
--   * Exports for menubridge: controller(), guestUiNative(pc), dialogWidget().
-- VERIFY(V-PAU-19): Settings from a P1 pause and from a P2 pause: "sub-screen request: Settings via ChangeStateTo ->
--   WBP_Settings_C pre-created for Pn", "pre-created WBP_Settings_C (owner Pn ...) acquired by the CSM", probe
--   "owner=Pn ... controller=Pn"; the controller navigates Settings natively; Back returns to a pause menu
--   pre-created for the same player ("pause CSM enters Paused_Racing").
-- VERIFY(V-PAU-20): default (PauseSubScreenHook false): LOGBOOK from a P1 pause gives the probe WARN "WBP_Stickerbook_C
--   owner=P2 ... NOT the controller's screen (menubridge fallback)" and menubridge bridges P1's A/B on it. Dedicated run
--   with PauseSubScreenHook = true: "sub-screen request: Stickerbook via ChangeToState 'Open Stickerbook from Pause
--   menu' -> WBP_Stickerbook_C pre-created for Pn"; no crash (else back to false).
-- VERIFY(V-PAU-21): EXIT TO MAIN MENU from a P2 pause: "IMC_UI restored (confirm dialog Dialog:1 up): P2 0", the
--   dialog answered by P2 through menubridge, Cancel -> "IMC_UI priority -> 500 for P2 (confirm dialog closed)".
-- VERIFY(V-PAU-22): the inactivity auto-pause (run J: ~60 s without game input) gets P1 as controller ("pauser unknown
--   -> P1") and its sub-screens are P1's.

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "pause"

-- cfg[k] when it has the type of the default d; keys config.lua does not list yet fall back to d.
local function opt(k, d)
    local v = cfg[k]
    if v == nil or type(v) ~= type(d) then return d end
    return v
end

local KEY_START, KEY_ESC, KEY_P, KEY_VIEW, KEY_TAB, KEY_O -- {KeyName = FName}, built on first use [API 3]
local function keys()
    if KEY_START then return end
    KEY_START = { KeyName = U.fname(C.KEY.Start) }           -- IA_Veh_Pause, pads
    KEY_ESC = { KeyName = U.fname(C.KEY.Escape) }            -- IA_Veh_Pause, keyboard (Escape, P)
    KEY_P = { KeyName = U.fname("P") }
    KEY_VIEW = { KeyName = U.fname("Gamepad_Special_Left") } -- IA_Veh_Player, pads
    KEY_TAB = { KeyName = U.fname("Tab") }                   -- IA_Veh_Player, keyboard (Tab, O)
    KEY_O = { KeyName = U.fname("O") }
end

local function P()
    St.pause = St.pause or { prevStart = {} }
    return St.pause
end

-- true = paused, false = not paused, nil = unknown (CSM state not resolvable)
-- Find-only (FAST poll: never LoadAsset); the pause CSM not in memory = unknown, not "idle inactive" (= paused).
-- Positive test (CSM_PauseMenus_Active active, U.csmPaused): after P1 finished the pause machine stops and
-- "Idle inactive" would read as paused, blocking guest pauses ("poll") and P1's quiet flag.   VERIFY(V-HUD-05)
function M.isPaused()
    return U.csmPaused()
end

local function pnumOf(pc)
    local ok, join = pcall(U.mod, "join")
    if ok and type(join) == "table" and join.pnumForPC then
        local ok2, n = pcall(join.pnumForPC, pc)
        if ok2 and n then return n end
    end
    return nil
end

-- Who paused: set by openPauseMenu / the request hook, else the local player whose pause key went down last.
local function notePauser(pc, why)
    local st = P()
    st.pauser, st.pauserWhy, st.pauserAtMs = pc, why, St.nowMs()
end

local function loaded(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, c = pcall(StaticFindObject, path)
    if ok and U.ok(c) then return c end
    return nil
end

local function pnumDesc(pc)
    if not U.ok(pc) then return "none" end
    for _, lp in ipairs(U.localPlayers()) do
        if U.key(lp.pc) == U.key(pc) then return "P" .. lp.index end
    end
    return "other " .. U.pathOf(pc)
end

-- "P2 (ctrlId 1)": owner lines (ControllerId decides the Slate/CommonUI user, V-PAU-15)
local function pnumCtrl(pc)
    if not U.ok(pc) then return "none" end
    for _, lp in ipairs(U.localPlayers()) do
        if U.key(lp.pc) == U.key(pc) then return string.format("P%d (ctrlId %s)", lp.index, tostring(lp.ctrlId)) end
    end
    return "other " .. U.pathOf(pc)
end

local function splitViews()
    local n = 0
    for _, lp in ipairs(U.localPlayers()) do if U.ok(lp.pc) then n = n + 1 end end
    local ok, present = pcall(U.mod, "present")
    if ok and type(present) == "table" and type(present.isSingleView) == "function" then
        local okS, single = pcall(present.isSingleView)
        if okS and single == true then return 1 end
    end
    if St.race.singleView == true then return 1 end
    return n
end

-- Local PlayerControllers (a race with >= 2 has the UIManager owner problem, single view or not).
local function localPCCount()
    local n = 0
    for _, lp in ipairs(U.localPlayers()) do if U.ok(lp.pc) then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------------------------------- pause CSM states
-- Screens of the pause CSM's menu states (decoded CSM_PauseMenus_Paused_* / _PlayerMenu: CsmActionShowWidgetData,
-- layer Menu, ForceNewInstance = false = the UIManager's acquire path).
local PAUSE_MENUS = {
    "/Game/Griffin/UI/Screens/Pause/WBP_PauseRacing.WBP_PauseRacing_C",
    "/Game/Griffin/UI/Screens/Pause/WBP_PauseArcadeRacing.WBP_PauseArcadeRacing_C",
    "/Game/Griffin/UI/Screens/Pause/WBP_PauseMultiplayer.WBP_PauseMultiplayer_C",
    "/Game/Griffin/UI/Screens/Pause/WBP_PausePaddock.WBP_PausePaddock_C",
    "/Game/Griffin/UI/Screens/WBP_PlayerMenu_Presentation.WBP_PlayerMenu_Presentation_C",
}
local MENU_EVERY_MS = 250
local MENU = C.E.UILayer.Menu

-- Pause CSM sub-states (children of CSM_PauseMenus_Active / Root, decoded). Settings / Photomode / Stickerbook show
-- their own screens (WBP_Settings_C ...) on top of a deactivated pause screen: no repair while one of them is up.
local PAUSE_DIR = "/Game/Griffin/Config/StateMachines/PauseMenus/"
local function pauseState(n) return PAUSE_DIR .. "CSM_PauseMenus_" .. n .. ".CSM_PauseMenus_" .. n end
local SUB_STATES = { "PauseMenu", "Paused_Racing", "Paused_Arcade", "Paused_Multiplayer", "Paused_Paddock",
    "PlayerMenu", "Settings", "Photomode", "Stickerbook", "Idle" }
local OTHER_SCREEN_STATES = { Settings = true, Photomode = true, Stickerbook = true }
-- 0.7.0: the menu states ("leaves") and the screen class each one's ShowWidget action acquires
local LEAVES = { "Paused_Racing", "Paused_Arcade", "Paused_Multiplayer", "Paused_Paddock", "PlayerMenu" }
local LEAF_CLASS = { Paused_Racing = PAUSE_MENUS[1], Paused_Arcade = PAUSE_MENUS[2],
    Paused_Multiplayer = PAUSE_MENUS[3], Paused_Paddock = PAUSE_MENUS[4], PlayerMenu = PAUSE_MENUS[5] }
local PADDOCK_ROOT = "/Game/Griffin/Gameplay/Paddock/StateMachine/CSM_Paddock_Root.CSM_Paddock_Root"
-- 0.7.2: screens opened FROM a pause, by pause CSM state (decoded CsmActionShowWidgetData: Menu layer, acquire).
-- "Settings" auto-enters its first child Settings_Menu (WBP_Settings_C).
local SUB_CLASS = {
    Settings = "/Game/Griffin/UI/Screens/Settings/WBP_Settings.WBP_Settings_C",
    Settings_Menu = "/Game/Griffin/UI/Screens/Settings/WBP_Settings.WBP_Settings_C",
    Settings_GammaCorrection = "/Game/Griffin/UI/Screens/Settings/WBP_GammaCorrection.WBP_GammaCorrection_C",
    Settings_ViewControls = "/Game/Griffin/UI/Screens/Settings/WBP_ControllerDiagram.WBP_ControllerDiagram_C",
    Settings_Credits = "/Game/Griffin/UI/Screens/WBP_Credits.WBP_Credits_C",
    Settings_BrightnessCalibration =
        "/Game/Griffin/UI/Screens/Settings/WBP_BrightnessCalibration.WBP_BrightnessCalibration_C",
    Stickerbook = "/Game/Griffin/UI/Screens/Stickerbook/WBP_Stickerbook.WBP_Stickerbook_C",
}
local SUB_PATHS = { SUB_CLASS.Settings, SUB_CLASS.Stickerbook, SUB_CLASS.Settings_GammaCorrection,
    SUB_CLASS.Settings_ViewControls, SUB_CLASS.Settings_Credits, SUB_CLASS.Settings_BrightnessCalibration }
-- ChangeToState(soft newState, Str reason, payload) callers on the pause CSM, by their literal reason (decoded BP
-- bytecode). The soft newState is never read: the reason names the target.
local REASON_STATE = { ["Open Stickerbook from Pause menu"] = "Stickerbook" }
local REASON_KNOWN = {
    ["Pause from player menu"] = "player menu -> pause menu: BP_CsmPickPauseMenu's ChangeStateTo follows (pick path)",
    [""] = "photo mode (WBP_Pause.OnPhotomodeButtonCalled): no CSM screen",
}

-- "PauseMenu Paused_Racing" (the active ones, find-only: never LoadAsset), whether a non-pause screen is up, and the
-- set of active names.
local function activeSubStates()
    local on, set, other = {}, {}, false
    for _, n in ipairs(SUB_STATES) do
        local okA, v = pcall(U.csmActive, pauseState(n), true)
        if okA and v == true then
            on[#on + 1] = n
            set[n] = true
            if OTHER_SCREEN_STATES[n] then other = true end
        end
    end
    return table.concat(on, " "), other, set
end

local function leafOf(set)
    for _, n in ipairs(LEAVES) do if set[n] then return n end end
    return nil
end

-- UIManager:GetWidgetCountInLayer(EUILayer) -> Int for the probe lines ("?" when unreadable).
local function layerCount(layer)
    local mgr = U.giSubsystem("UIManager")
    if not U.ok(mgr) then return "?" end
    local ok, n = pcall(function() return mgr:GetWidgetCountInLayer(layer) end)
    return ok and tostring(n) or "?"
end

local function shortCls(path)
    return tostring(path):match("%.([^%.]+)$") or tostring(path)
end

-- "PauseMenu" for the object CSM_PauseMenus_PauseMenu (nil when unreadable)
local function stateShort(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    if not ok or type(s) ~= "string" then return nil end
    return (s:gsub("^CSM_PauseMenus_", ""))
end

-- The sub-state BP_CsmPickPauseMenu picks (decoded switch on GfnGameInstance.PrimaryFlow, work/decoded-pause2):
-- 0 (with a "Primary Flow not set" print) / 2 -> Paused_Racing, 1 -> Paused_Paddock while CSM_Paddock_Root is active
-- else Paused_Racing, 3 -> Paused_Arcade, 4 -> Paused_Multiplayer, any other value -> none.
local function pickLeaf()
    local flow
    pcall(function() flow = math.tointeger(tonumber(U.gi().PrimaryFlow)) end)
    if flow == 3 then return "Paused_Arcade", flow end
    if flow == 4 then return "Paused_Multiplayer", flow end
    if flow == 1 and U.csmActive(PADDOCK_ROOT, true) == true then return "Paused_Paddock", flow end
    if flow == nil or flow == 0 or flow == 1 or flow == 2 then return "Paused_Racing", flow end
    return nil, flow
end

---------------------------------------------------------------------------------------------------- owner (C)
local function keyboardIsP1()
    local ok, v = pcall(function() return require("settings").get("KeyboardIsP1") end)
    return ok and v == true
end

local function lpOf(pc)
    local k = U.key(pc)
    if k == 0 then return nil end
    for _, lp in ipairs(U.localPlayers()) do
        if U.key(lp.pc) == k then return lp end
    end
    return nil
end

local function pcByCtrlId(c)
    for _, lp in ipairs(U.localPlayers()) do
        if lp.ctrlId == c and U.ok(lp.pc) then return lp.pc end
    end
    return nil
end

-- cfg.PauseMenuOwner: "pauser" (default) | "p1" (the single-player setup: the safest first test) | "game" (alias
-- "keep": the UIManager's own owner, the LAST local PC). With KeyboardIsP1 (bOffsetPlayerGamepadIds) pad k drives
-- ControllerId k+1, but UCommonGameViewportClient reroutes a key to the CommonUI router of the pad's OWN platform
-- user k before the engine applies the offset: a pad pauser with ControllerId c gets a screen owned by ControllerId
-- c-1 (cfg.PauseOwnerPadShift "auto" | "off").  VERIFY(V-PAU-15)
local function ownerFor(pauser, viaPad)
    local mode = opt("PauseMenuOwner", "pauser")
    if mode == "game" or mode == "keep" then return nil, "game" end
    local p1 = U.p1()
    if mode == "p1" then return U.ok(p1) and p1 or nil, "PauseMenuOwner p1" end
    if not U.ok(pauser) then return U.ok(p1) and p1 or nil, "pauser unknown -> P1" end
    if viaPad and opt("PauseOwnerPadShift", "auto") == "auto" and keyboardIsP1() then
        local lp = lpOf(pauser)
        if lp and lp.ctrlId >= 1 then
            local o = pcByCtrlId(lp.ctrlId - 1)
            if U.ok(o) then
                return o, string.format("KeyboardIsP1 pad shift ctrlId %d -> %d", lp.ctrlId, lp.ctrlId - 1)
            end
        end
    end
    return pauser, "pauser"
end

---------------------------------------------------------------------------------------------------- dialogs (F)
-- The persistent game-instance containers (UIManagerSettings.PersistentWidgets, created at boot, P1-owned):
-- WBP_Dialog_Container (TargetName Dialog), WBP_SystemDialog_Container (SystemDialog), WBP_MenuOverlay_Container
-- (MenuOverlay). Run H: GetWidgetCountInLayer(Dialog) is always >= 1 (the hidden, EMPTY WBP_Dialog_Container), so the
-- 0.6.0 test "Dialog layer count > 0" blocked the lost-menu repair forever. A dialog is up only while one of these
-- containers holds a message widget (NotificationSubPanel children > 0) and is not hidden.  VERIFY(V-PAU-14)
local DIALOG_TARGETS = { Dialog = true, SystemDialog = true, MenuOverlay = true }
local cont = { list = nil, atMs = -1e12 } -- session cache (game-instance widgets); never filled from the hook

local function containers(force)
    if cont.list and #cont.list > 0 and not force then
        local all = true
        for _, c in ipairs(cont.list) do if not U.ok(c.w) then all = false; break end end
        if all then return cont.list end
    end
    local now = St.nowMs()
    if now - cont.atMs < 5000 then return cont.list or {} end
    cont.atMs = now
    local list = {}
    local giKey = U.key(U.gi())
    local okF, all = pcall(FindAllOf, "NotificationContainerWidget")  -- <= 1 per 5 s while unresolved
    for _, w in ipairs((okF and type(all) == "table") and all or {}) do
        pcall(function()
            if not U.ok(w) then return end
            local tn = U.str(w.TargetName)
            if DIALOG_TARGETS[tn] and giKey ~= 0 and U.key(w:GetOuter()) == giKey then
                list[#list + 1] = { w = w, name = tn }
            end
        end)
    end
    cont.list = list
    return list
end

-- true, "Dialog:1" while a confirm / system dialog shows; false otherwise (an unresolved cache = false).
local function dialogUp()
    for _, c in ipairs(cont.list or {}) do
        if U.ok(c.w) then
            local n = 0
            pcall(function() n = math.tointeger(tonumber(c.w.NotificationSubPanel:GetChildrenCount())) or 0 end)
            if n > 0 then
                local hidden
                pcall(function() hidden = c.w:IsHidden() end)
                if hidden ~= true then return true, string.format("%s:%d", c.name, n) end
                local vis
                pcall(function() vis = c.w:GetVisibility() end)
                if vis == C.E.Vis.Visible or vis == C.E.Vis.HitTestInvisible or vis == C.E.Vis.SelfHitTestInvisible then
                    return true, string.format("%s:%d (IsHidden, vis %s)", c.name, n, tostring(vis))
                end
            end
        end
    end
    return false, nil
end

-- 0.7.2: the confirm dialog on screen = the newest message widget (NotificationSubPanel's last child) of the first
-- persistent container that dialogUp() would count, and "Dialog:1"; nil when none. Exported for menubridge.
local function dialogTop()
    for _, c in ipairs(cont.list or {}) do
        if U.ok(c.w) then
            local n = 0
            pcall(function() n = math.tointeger(tonumber(c.w.NotificationSubPanel:GetChildrenCount())) or 0 end)
            if n > 0 then
                local shown
                pcall(function() shown = c.w:IsHidden() ~= true end)
                if not shown then
                    local vis
                    pcall(function() vis = c.w:GetVisibility() end)
                    shown = vis == C.E.Vis.Visible or vis == C.E.Vis.HitTestInvisible
                        or vis == C.E.Vis.SelfHitTestInvisible
                end
                if shown then
                    local w
                    pcall(function() w = c.w.NotificationSubPanel:GetChildAt(n - 1) end)
                    if U.ok(w) then return w, string.format("%s:%d", c.name, n) end
                end
            end
        end
    end
    return nil, nil
end

---------------------------------------------------------------------------------------------------- Z order (C)
-- The UIManager adds its layer screens with AddToViewport(LayerBase + LayerCount): viewport widgets draw above every
-- player-screen widget (our HUDs), the ZOrder only orders viewport widgets (game HUD band < Menu < Dialog).
local vpSub = nil
local function viewportSub()
    if vpSub and U.ok(vpSub) then return vpSub end
    local ok, o = pcall(FindFirstOf, "GameViewportSubsystem")      -- engine subsystem: once per session
    vpSub = (ok and U.ok(o)) and o or nil
    return vpSub
end

local function slotZ(w)
    local vs = viewportSub()
    if not (vs and U.ok(w)) then return nil end
    local ok, t = pcall(function() return vs:GetWidgetSlot(w) end)     -- Struct GameViewportWidgetSlot -> table
    if not ok or t == nil then return nil end
    local z
    pcall(function() z = tonumber(t.ZOrder) end)
    return z and math.tointeger(z) or nil
end

local zSeen = nil -- ZOrder of a Menu screen the UIManager added itself this session (exactly its Menu band)
local zAuto = nil -- persistent WBP_Dialog_Container (Dialog layer) ZOrder - 1 (computed when a split race is armed)

-- cfg.PauseMenuZ: "auto" (default) or an integer.
local function menuZ()
    local v = cfg.PauseMenuZ
    if type(v) == "number" then return math.floor(v), "cfg.PauseMenuZ" end
    if zSeen then return zSeen, "seen on a UIManager menu" end
    if zAuto then return zAuto, "dialog layer - 1" end
    return math.floor(tonumber(cfg.PauseMenuZOrder) or 50), "PauseMenuZOrder fallback"
end

local function prepareZ()
    local dz, hz
    for _, c in ipairs(cont.list or {}) do
        if c.name == "Dialog" then dz = slotZ(c.w) end
    end
    local g = St.hud and St.hud.p1hud
    if U.ok(g) then hz = slotZ(g) end
    if dz then
        zAuto = dz - 1
        if hz and zAuto <= hz then zAuto = hz + 1 end
    end
    local z, how = menuZ()
    U.log(TAG, "Menu-layer ZOrder = %s (%s; dialog %s, game HUD %s, seen %s)", tostring(z), how, tostring(dz),
        tostring(hz), tostring(zSeen))
end

---------------------------------------------------------------------------------------------------- IMC_UI (D)
-- The InputModeManager raises IMC_UI for the FIRST local player only (0x140ded924, GetFirstLocalPlayerFromController).
-- A guest's IMC_UI stays at 0 with its vehicle IMC beside it (inputfix adds IMC_Vehicle_Default at P1's priority, 0 in
-- run H: P2 98 -> 78 mappings), so a guest's A/B/Start stay vehicle keys and CommonUI (which matches the raw key
-- against the router player's Enhanced Input mappings) never sees IA_UI_*. cfg.PauseUiImcBoost "all" (default: every
-- guest while paused) | "owner" (only a guest that owns the menu) | "off". P1 is left to the game's InputModeManager.
-- bIgnoreAllPressedKeysUntilRelease: the Start that paused / the A that resumed never fires the other context's action.
-- VERIFY(V-PAU-10)
local IMC_UI_PATH = "/Game/Griffin/Config/Input/UI/IMC_UI.IMC_UI"
local UIM_SETTINGS = "/Script/Griffin.Default__UIManagerSettings"
local EI_CLASS = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
local prio = nil
local imcWarned = false

local function imcPrios()
    if prio then return prio.act, prio.def end
    local act, def = 500, 0
    local s = loaded(UIM_SETTINGS)
    if s then
        pcall(function() local v = tonumber(s.UI_IMC_ActivePriority); if v then act = math.floor(v) end end)
        pcall(function() local v = tonumber(s.UI_IMC_DefaultPriority); if v then def = math.floor(v) end end)
        prio = { act = act, def = def }
    end
    return act, def
end

local eiCls = nil
local function eiSub(pc)
    if not U.ok(pc) then return nil end
    if not (eiCls and U.ok(eiCls)) then eiCls = loaded(EI_CLASS) end
    if not eiCls then return nil end
    local sub
    pcall(function() sub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(pc, eiCls) end)
    return U.ok(sub) and sub or nil
end

-- HasMappingContext(imc, out OutFoundPriority) -> has, priority (nil, nil when not callable)
local function eiHas(sub, imc)
    local out = {}
    local ok, r = pcall(function() return sub:HasMappingContext(imc, out) end)
    if not ok or type(r) ~= "boolean" then return nil, nil end
    local p = tonumber(out.OutFoundPriority)
    return r, p and math.floor(p) or nil
end

local function imcOpts() return { bIgnoreAllPressedKeysUntilRelease = true } end

-- Guests' IMC_UI -> the active priority (idempotent per guest; the previous priority is remembered for the restore).
local function imcBoost(st, owner, why)
    local mode = opt("PauseUiImcBoost", "all")
    if mode == "off" then return "off" end
    local imc = loaded(IMC_UI_PATH)
    if not imc then
        if not imcWarned then
            imcWarned = true
            U.warn(TAG, "IMC_UI not in memory (%s): no UI input for guests while paused (V-PAU-10)", IMC_UI_PATH)
        end
        return "IMC_UI not found"
    end
    local act = imcPrios()
    st.imc = st.imc or {}
    local done = {}
    for _, lp in ipairs(U.localPlayers()) do
        if lp.index >= 2 and U.ok(lp.pc) and (mode == "all" or U.key(lp.pc) == U.key(owner)) then
            local k = U.key(lp.pc)
            local rec = st.imc[k]
            if not (rec and rec.boosted) then
                local sub = eiSub(lp.pc)
                if sub then
                    if not rec then
                        local has, p = eiHas(sub, imc)
                        rec = { pnum = lp.index, had = has, prio = p }
                        st.imc[k] = rec
                    end
                    rec.boosted = pcall(function() sub:AddMappingContext(imc, act, imcOpts()) end)
                    done[#done + 1] = string.format("P%d%s", lp.index, rec.boosted and "" or " (failed)")
                end
            end
        end
    end
    if #done == 0 then return "unchanged" end
    st.imcBoosted = true
    U.log(TAG, "IMC_UI priority -> %d for %s (%s) (V-PAU-10)", act, table.concat(done, ","), tostring(why))
    return string.format("-> %d for %s", act, table.concat(done, ","))
end

-- Every guest whose IMC_UI sits at the active priority goes back to what it had before the boost (the default
-- priority when unknown; removed when it had none). Without a record (hot reload, a boost by the game) a guest at the
-- active priority is normalised too: resume edge, "leaving", FRONTEND, arming.
local function imcRestore(st, why)
    local imc = loaded(IMC_UI_PATH)
    if not imc then st.imc, st.imcBoosted = {}, false; return "IMC_UI not found" end
    local act, def = imcPrios()
    local done = {}
    for _, lp in ipairs(U.localPlayers()) do
        if lp.index >= 2 and U.ok(lp.pc) then
            local rec = st.imc and st.imc[U.key(lp.pc)]
            local sub = eiSub(lp.pc)
            if sub then
                local has, p = eiHas(sub, imc)
                if (rec and rec.boosted) or (has == true and p == act) then
                    if rec and rec.had == false then
                        local ok = pcall(function() sub:RemoveMappingContext(imc, imcOpts()) end)
                        done[#done + 1] = string.format("P%d removed%s", lp.index, ok and "" or " (failed)")
                    else
                        local to = (rec and rec.prio) or def
                        if to == act then to = def end
                        local ok = pcall(function() sub:AddMappingContext(imc, to, imcOpts()) end)
                        done[#done + 1] = string.format("P%d %d%s", lp.index, to, ok and "" or " (failed)")
                    end
                end
            end
        end
    end
    st.imc, st.imcBoosted = {}, false
    if #done == 0 then return "unchanged" end
    U.log(TAG, "IMC_UI restored (%s): %s (V-PAU-10)", tostring(why), table.concat(done, ", "))
    return table.concat(done, ", ")
end

-- "P1:500,P2:500" for the probe lines (none = not mapped, ? = unreadable)
local function imcDesc()
    local imc = loaded(IMC_UI_PATH)
    if not imc then return "?" end
    local parts = {}
    for _, lp in ipairs(U.localPlayers()) do
        if U.ok(lp.pc) then
            local sub = eiSub(lp.pc)
            local has, p
            if sub then has, p = eiHas(sub, imc) end
            parts[#parts + 1] = string.format("P%d:%s", lp.index,
                has == true and tostring(p) or (has == false and "none" or "?"))
        end
    end
    return table.concat(parts, ",")
end

---------------------------------------------------------------------------------------------------- HUD input guard (A)
-- IA_Veh_Pause has no trigger and the race HUD binds it on Triggered with bTriggerWhenPaused: it fires on EVERY frame
-- while Start is held, from every WBP_Hud_Race whose input component sits on the pressing PC's stack, and Enhanced
-- Input collects all those delegates before running any. A second ChangeStateTo(PauseMenu) on the active state makes
-- the CSM leave Paused_* (screen released, world frozen: the run G/H soft lock).
-- A1: the game's HUD owned by a guest (the UIManager's owner, the last local PC) that has its own HUD loses its input
--     (every 100 ms; every FAST tick for 2 s after a resume, when the CSM re-creates that HUD).
-- A2: every HUD hud.lua hosts loses its input from the pause request until the pause is over, every pause / player key
--     is up and cfg.PauseInputsBackMs passed (only the HUDs turned off here are turned on again).
-- cfg.PauseHudInputGuard (default true).  VERIFY(V-PAU-09)
local function guests() return (St.hud and St.hud.guests) or {} end

local function isModHud(w)
    local k = U.key(w)
    if k == 0 then return false end
    for _, e in pairs(guests()) do if U.key(e.widget) == k then return true end end
    return false
end

-- hud.lua keeps P1's clone input off while the game's HUD is P1's (ensureGuest, cfg.P1CloneInput): never turned on.
-- Review 0.7.0: St.hud.p1hud is validated before any member access. hud.findP1Hud keeps the last wrapper after the
-- UIManager stops listing that HUD, and UE4SS resolves a member of a collected object from freed memory (a native access
-- violation that pcall cannot catch): every stored wrapper gets U.ok() first.
local function gameHudOwner()
    local g = St.hud and St.hud.p1hud
    local o
    if U.ok(g) then pcall(function() o = g:GetOwningPlayer() end) end
    return U.ok(o) and o or nil
end

local function hudInputWasOn(e)
    local p1k = U.key(U.p1())
    if U.key(e.pc) ~= p1k or cfg.P1CloneInput == true then return true end
    local o = gameHudOwner()
    return not (o and U.key(o) == p1k)
end

local function hudInputsOff(st, why)
    if not opt("PauseHudInputGuard", true) then return "guard off" end
    st.hudOff = st.hudOff or {}
    local names = {}
    for _, e in pairs(guests()) do
        if U.ok(e.widget) then
            local wk = U.key(e.widget)
            if not st.hudOff[wk] and hudInputWasOn(e)
                and pcall(function() e.widget:UnregisterInputComponent() end) then
                st.hudOff[wk] = { w = e.widget, pnum = e.pnum }
                names[#names + 1] = "P" .. tostring(e.pnum)
            end
        end
    end
    if #names == 0 then return "none new" end
    st.hudOffAtMs = St.nowMs()
    U.dbg(TAG, "HUD inputs off (%s): %s", tostring(why), table.concat(names, ","))
    return table.concat(names, ",")
end

local function keysHeld(st)
    for _, ks in pairs(st.keyState or {}) do
        if ks.pause or ks.player then return true end
    end
    return false
end

local function hudInputsBack(st, now)
    if not st.hudOff or next(st.hudOff) == nil then return end
    if not st.resumedAtMs or (st.hudOffAtMs or 0) > st.resumedAtMs then return end -- turned off for a newer request
    if now - st.resumedAtMs < opt("PauseInputsBackMs", 150) or keysHeld(st) then return end
    local ours = {}
    for _, e in pairs(guests()) do if U.ok(e.widget) then ours[U.key(e.widget)] = true end end
    local names = {}
    for wk, rec in pairs(st.hudOff) do
        if ours[wk] and U.ok(rec.w) and pcall(function() rec.w:RegisterInputComponent() end) then
            names[#names + 1] = "P" .. tostring(rec.pnum)
        end
    end
    st.hudOff = {}
    U.log(TAG, "HUD inputs back on (%s) %d ms after resume (pause keys up) (V-PAU-09)",
        #names > 0 and table.concat(names, ",") or "none still hosted", math.floor(now - st.resumedAtMs))
end

local HUD_CLASS_PATHS = { C.BP.HudRace, C.BP.HudMemory }

-- The game's race HUD: hud.lua's record (refreshed every MAIN tick), else the UIManager's HUD layer (every 250 ms;
-- every FAST tick for 2 s after a resume). Never one of our HUDs.
local function gameHud(st, now)
    local g = St.hud and St.hud.p1hud or nil
    local soon = st.resumedAtMs ~= nil and now - st.resumedAtMs < 2000
    if (soon or not U.ok(g)) and now - (st.a1LookMs or -1e12) >= (soon and 0 or 250) then
        st.a1LookMs = now
        local mgr = U.giSubsystem("UIManager")
        if U.ok(mgr) then
            for _, path in ipairs(HUD_CLASS_PATHS) do
                local cls = loaded(path)
                local ok, w = false, nil
                if cls then ok, w = pcall(function() return mgr:GetWidgetInLayer(cls, C.E.UILayer.HUD) end) end
                if ok and U.ok(w) and not isModHud(w) then g = w; break end
            end
        end
    end
    return U.ok(g) and g or nil
end

-- A1 (FAST, split race)
local function guardGameHud(st, now)
    if not opt("PauseHudInputGuard", true) then return end
    local soon = st.resumedAtMs ~= nil and now - st.resumedAtMs < 2000
    if not soon and now - (st.a1Ms or -1e12) < 100 then return end
    st.a1Ms = now
    local g = gameHud(st, now)
    if not g then return end
    local owner
    pcall(function() owner = g:GetOwningPlayer() end)
    local ownerKey = U.key(owner)
    if ownerKey == 0 or ownerKey == U.key(U.p1()) then return end
    local e = guests()[ownerKey]
    if not (e and U.ok(e.widget)) or U.key(e.widget) == U.key(g) then return end -- that guest's only HUD: keep it
    pcall(function() g:UnregisterInputComponent() end)
    local gk = U.key(g)
    if st.a1Logged ~= gk then
        st.a1Logged = gk
        U.log(TAG, "game HUD input unregistered (%s, owner %s = UIManager owner, last local PC; that player's own HUD "
            .. "keeps IA_Veh_Pause/IA_Veh_Player) (V-PAU-09)", U.pathOf(g):match("[^%.]+$") or "?", pnumCtrl(owner))
    end
end

---------------------------------------------------------------------------------------------------- pause CSM
local rootCache = nil
local smKnownKey = 0 -- address of the last pause CSM seen (probe "osm" compare only, never trusted for identity)

local function rootAsset()
    if rootCache and U.ok(rootCache) then return rootCache end
    rootCache = loaded(C.ASSET.CSM_PauseRoot)
    return rootCache
end

-- The ctx of a ChangeStateTo call: the pause CSM? (mCsmAsset = CSM_PauseMenus_Root; an address alone could be reused)
local function isPauseSm(o)
    local root = rootAsset()
    if not root or U.key(o) == 0 then return false end
    local ok, a = pcall(function() return o.mCsmAsset end)
    if ok and U.key(a) ~= 0 and U.key(a) == U.key(root) then
        smKnownKey = U.key(o)
        return true
    end
    return false
end

-- The running pause CSM (GetStateMachineForRoot, find-only root); nil when none runs.
local function currentPauseSm()
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    local root = rootAsset()
    if not (U.ok(mgr) and root) then return nil end
    local ok, o = pcall(function() return mgr:GetStateMachineForRoot(root) end)
    if ok and U.ok(o) then
        smKnownKey = U.key(o)
        return o
    end
    return nil
end

-- ChangeStateTo on the pause CSM from Lua: a C.ASSET key ("CSM_PauseIdle") or a sub-state name ("Paused_Racing").
local function pauseCsmChange(state, why)
    local sm = currentPauseSm()
    local target = C.ASSET[state] and U.obj(C.ASSET[state]) or loaded(pauseState(state))
    if not (sm and U.ok(target)) then return false end
    return (pcall(function() sm:ChangeStateTo(target, why or "SWGRCouch", nil) end))
end

---------------------------------------------------------------------------------------------------- after a wreck (G)
-- CSM_RF_InProgress (and _Countdown) runs CSM_PauseMenus_Root as a sub-CSM (CsmActionRunSubCsmData): once P1 wrecked
-- or finished, the race CSM left InProgress and the pause CSM is gone (run H race 1: GetStateMachineForRoot nil, "only
-- 2 CSMs alive", nobody could pause). cfg.PauseRestartCsm "onpress" (default: a pause key restarts it) | "eager" (as
-- soon as it is gone) | "off". Only while a local human still races; ended again when the race phase ends.
local function humansRacing()
    local n, names = 0, {}
    local okW, wreck = pcall(U.mod, "wreck")
    if okW and type(wreck) == "table" and type(wreck._localRacers) == "function" then
        local ok, list = pcall(wreck._localRacers)
        if ok and type(list) == "table" then
            for _, r in ipairs(list) do
                if r.racing then n = n + 1; names[#names + 1] = "P" .. tostring(r.pnum) end
            end
            return n, table.concat(names, ",")
        end
    end
    for _, lp in ipairs(U.localPlayers()) do
        local ok, r = pcall(function() return lp.pc.PlayerState.RaceEventComponent:IsStillRacing() end)
        if ok and r == true then n = n + 1; names[#names + 1] = "P" .. lp.index end
    end
    return n, table.concat(names, ",")
end

local function restartPauseCsm(st, why)
    local n, who = humansRacing()
    if n == 0 then return false, "no local human still racing" end
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    local root = U.obj(C.ASSET.CSM_PauseRoot)
    if not (U.ok(mgr) and U.ok(root)) then return false, "CSM manager / CSM_PauseMenus_Root unresolved" end
    local okS, err = pcall(function() mgr:StartCosmeticStateMachine(root) end)
    local sm = currentPauseSm()
    if okS and sm then
        st.ownCsm, st.ownCsmKey = sm, U.key(sm)
        U.log(TAG, "pause CSM restarted (%s; still racing: %s): StartCosmeticStateMachine ok (V-PAU-16)", tostring(why),
            who)
        return true
    end
    U.warn(TAG, "pause CSM restart failed (%s): StartCosmeticStateMachine %s, GetStateMachineForRoot %s (V-PAU-16)",
        tostring(why), okS and "ok" or tostring(err), sm and "ok" or "nil")
    return false, "restart failed"
end

local function endOwnCsm(st, why)
    local sm = st.ownCsm
    st.ownCsm, st.ownCsmKey = nil, nil
    if not U.ok(sm) then return end
    local ok, err = pcall(function() sm:EndStateMachine() end)
    U.log(TAG, "own pause CSM ended (%s): EndStateMachine %s (V-PAU-16)", tostring(why),
        ok and "ok" or ("failed: " .. tostring(err)))
end

---------------------------------------------------------------------------------------------------- pre-create (C)
-- The UIManager creates its screens for the LAST local PC (0x14d28b91a). It REUSES a widget of the requested class that
-- already sits in the layer (acquire: refcount + 1, no viewport add, no input-mode broadcast), and every pause state
-- shows its screen through acquire. So the screen is created here for the controlling player right before the CSM's
-- ShowWidget runs (inside the ChangeStateTo pre-hook): WidgetBlueprintLibrary:Create(owner) -> AddToViewport(Menu z)
-- -> UIManager:AddExistingWidgetToLayer(Menu) (refcount 1). ShowWidget acquires it (refcount 2, SetOwningStateMachine,
-- TransitionIn); the FAST tick sees OwningStateMachine set, drops our reference (RemoveWidget: 2 -> 1, the CSM's own
-- stop removes the screen) and asks the InputModeManager to re-evaluate (OnControlMappingsRebuilt: the acquire path
-- never broadcasts "UI shown", and ShowWidget has set its input-mode override by then). Not acquired after 500 ms:
-- removed again. Never re-added. cfg.PauseMenuPrecreate (default true).  VERIFY(V-PAU-11)
local function inLayerFirst(cls)
    local mgr = U.giSubsystem("UIManager")
    if not U.ok(mgr) then return nil, nil end
    local ok, w = pcall(function() return mgr:GetWidgetInLayer(cls, MENU) end)
    return (ok and U.ok(w)) and w or nil, mgr
end

local function refreshInputMode()
    local mgr = U.giSubsystem("UIManager")
    local ok = U.ok(mgr) and pcall(function() mgr:GetInputModeManager():OnControlMappingsRebuilt() end)
    return ok and "ok" or "failed"
end

local function precreate(st, kind, leaf, owner, ownerWhy, why)
    if not opt("PauseMenuPrecreate", true) then return nil, "PauseMenuPrecreate off" end
    if kind == "sub" and not opt("PauseSubScreenPrecreate", true) then return nil, "PauseSubScreenPrecreate off" end
    if not U.ok(owner) then return nil, "no owner (" .. tostring(ownerWhy) .. ")" end
    local path = LEAF_CLASS[leaf or ""] or SUB_CLASS[leaf or ""]          -- 0.7.2: sub-screens (Settings, Logbook)
    if not path then return nil, "no screen class for " .. tostring(leaf) end
    local cls = loaded(path)
    if not cls then return nil, shortCls(path) .. " not in memory" end
    local ex, mgr = inLayerFirst(cls)
    if not U.ok(mgr) then return nil, "no UIManager" end
    if ex then
        local o
        pcall(function() o = ex:GetOwningPlayer() end)
        return nil, string.format("the Menu layer already holds %s (owner %s)", shortCls(path), pnumDesc(o))
    end
    local w
    local okC, errC = pcall(function() w = U.WBL():Create(owner, cls, owner) end) -- (WorldContext, Class, OwningPlayer)
    if not (okC and U.ok(w)) then return nil, "Create failed: " .. tostring(errC) end
    local z, zHow = menuZ()
    local okV, errV = pcall(function() w:AddToViewport(z) end)
    if not okV then return nil, "AddToViewport failed: " .. tostring(errV) end
    local okL, errL = pcall(function() mgr:AddExistingWidgetToLayer(w, MENU) end)
    if not okL then
        pcall(function() w:RemoveFromParent() end)
        return nil, "AddExistingWidgetToLayer failed: " .. tostring(errL)
    end
    st.pre = { w = w, key = U.key(w), cls = cls, path = path, leaf = leaf, kind = kind, owner = owner,
               ownerWhy = ownerWhy, atMs = St.nowMs(), z = z, zHow = zHow, why = why,
               vid = (kind == "sub") and "V-PAU-19" or "V-PAU-11" }
    return w, z
end

-- An UN-acquired screen of ours out of the layer and the viewport. RemoveWidget hits every entry of the class, so it
-- is used only while the layer's first entry of that class is ours.
local function dropPre(st, why)
    local pre = st.pre
    st.pre = nil
    if not (pre and U.ok(pre.w)) then return end
    local first, mgr = inLayerFirst(pre.cls)
    local how = "RemoveFromParent"
    if first and U.key(first) == pre.key and pcall(function() mgr:RemoveWidget(pre.cls, MENU) end) then
        how = "UIManager:RemoveWidget"
    end
    pcall(function() if pre.w:IsInViewport() == true then pre.w:RemoveFromParent() end end)
    U.log(TAG, "pre-created %s (owner %s) removed (%s): %s", shortCls(pre.path), pnumDesc(pre.owner), how,
        tostring(why))
end

-- FAST while paused: acquisition -> release our reference once; not acquired within 500 ms -> removed.
-- Self-check of the acquire refcount [research V, 0x140d74ff6]: if the release removed the screen (the acquire did not
-- count our reference), later pauses keep our reference until the pause is over (preAfter) - releaseAtEnd.
local releaseAtEnd = false
local function preTick(st, now)
    local pre = st.pre
    if not pre or pre.acquired then return end
    if not U.ok(pre.w) then st.pre = nil; return end
    local osm
    pcall(function() osm = pre.w.OwningStateMachine end)
    if U.ok(osm) then
        pre.acquired, pre.acqMs = true, now
        local first, mgr = inLayerFirst(pre.cls)
        local rel = "extra ref kept (the layer's first entry is not ours)"
        if releaseAtEnd then
            rel = "extra ref kept until the pause is over (release-at-end)"
        elseif first and U.key(first) == pre.key then
            pre.released = pcall(function() mgr:RemoveWidget(pre.cls, MENU) end)
            rel = pre.released and "extra ref released" or "RemoveWidget failed (released after the pause)"
            local still = inLayerFirst(pre.cls)
            -- gone while its state still shows it (a duplicate request that already left the state is no evidence)
            if pre.released and not (still and U.key(still) == pre.key)
                and U.csmActive(pauseState(pre.leaf), true) == true then
                releaseAtEnd = true
                U.warn(TAG, "releasing our reference REMOVED %s (the acquire did not count it): this pause loses its "
                    .. "screen (F2 resumes); release-at-end from now on (%s)", shortCls(pre.path), pre.vid or "V-PAU-11")
            end
        end
        U.log(TAG, "pre-created %s (owner %s) acquired by the CSM after %d ms (osm %s): %s; input mode refresh %s "
            .. "(%s)", shortCls(pre.path), pnumCtrl(pre.owner), math.floor(now - pre.atMs),
            U.key(osm) == smKnownKey and "= pause CSM" or U.pathOf(osm), rel, refreshInputMode(), pre.vid or "V-PAU-11")
    elseif now - pre.atMs >= 500 then
        U.warn(TAG, "pre-created %s not used by the CSM within 500 ms (states [%s]): removed (%s)",
            shortCls(pre.path), (activeSubStates()), pre.vid or "V-PAU-11")
        dropPre(st, "not acquired")
    end
end

-- After the pause: an acquired + released screen was removed by the CSM's own stop (after its out-animation). A screen
-- still holding OUR reference (a duplicate request left it in the layer, or the release was refused) is removed here
-- (600 ms after the resume edge), then the InputModeManager re-evaluates (P1's IMC_UI back to its default).
local function preAfter(st, now)
    local pre = st.pre
    -- a screen made after the last resume belongs to a newer pause (G can pause inside the tick that resumes)
    if not pre or not st.resumedAtMs or pre.atMs >= st.resumedAtMs then return end
    if now - st.resumedAtMs < (pre.released and 1500 or 600) then return end
    st.pre = nil
    if not U.ok(pre.w) then return end
    local first, mgr = inLayerFirst(pre.cls)
    if first and U.key(first) == pre.key then
        -- an entry left in the Menu layer keeps the UIManager's "interactive UI shown" (P1's IMC_UI at 500)
        local ok = pcall(function() mgr:RemoveWidget(pre.cls, MENU) end)
        local logf = pre.released and U.warn or U.log
        logf(TAG, "pause over: pre-created %s still in the Menu layer %d ms after resume (%s) -> RemoveWidget %s; "
            .. "input mode refresh %s (V-PAU-11)", shortCls(pre.path), math.floor(now - st.resumedAtMs),
            pre.released and "released, orphaned entry" or "our reference", ok and "ok" or "failed", refreshInputMode())
    end
    pcall(function()
        if pre.w:IsInViewport() == true then
            pre.w:RemoveFromParent()
            U.warn(TAG, "pause over: pre-created %s was still in the viewport: taken off", shortCls(pre.path))
        end
    end)
end

-- 0.7.2: the record of the screen pre-created earlier in THIS pause, before a new one is made (pause screen ->
-- Settings -> back to the pause screen): an acquired screen is the CSM's (its own ShowWidget stop removes it; a
-- reference we still hold is given back now, while the layer's first entry of that class is ours, so that stop
-- really removes it); an un-acquired one is removed like a failed pre-create. The acquisition is read live
-- (OwningStateMachine) as well: the FAST tick that records it may not have run yet.
local function retirePre(st, why)
    local pre = st.pre
    if not pre then return end
    st.pre = nil
    if not U.ok(pre.w) then return end
    local acquired = pre.acquired == true
    if not acquired then
        local osm
        pcall(function() osm = pre.w.OwningStateMachine end)
        acquired = U.ok(osm)
    end
    if not acquired then
        st.pre = pre
        dropPre(st, why)
        return
    end
    if pre.released or releaseAtEnd then return end
    local first, mgr = inLayerFirst(pre.cls)
    if first and U.key(first) == pre.key then
        local ok = pcall(function() mgr:RemoveWidget(pre.cls, MENU) end)
        U.dbg(TAG, "pre-created %s retired (%s): extra ref released %s", shortCls(pre.path), tostring(why), tostring(ok))
    else
        -- the layer's first entry of that class is not ours (RemoveWidget would hit it): retried after the pause
        st.orphans = st.orphans or {}
        st.orphans[#st.orphans + 1] = pre
    end
end

-- After the pause (600 ms after the resume edge, like preAfter): a retired screen that still holds our reference.
local function orphansAfter(st, now)
    if not st.orphans or #st.orphans == 0 or not st.resumedAtMs or now - st.resumedAtMs < 600 then return end
    local list = st.orphans
    st.orphans = nil
    for _, pre in ipairs(list) do
        if U.ok(pre.w) then
            local first, mgr = inLayerFirst(pre.cls)
            if first and U.key(first) == pre.key then
                local ok = pcall(function() mgr:RemoveWidget(pre.cls, MENU) end)
                U.warn(TAG, "pause over: retired %s still held our reference -> RemoveWidget %s (%s)", shortCls(pre.path),
                    ok and "ok" or "failed", pre.vid or "V-PAU-19")
            end
            pcall(function() if pre.w:IsInViewport() == true then pre.w:RemoveFromParent() end end)
        end
    end
end

---------------------------------------------------------------------------------------------------- open from Lua
-- kind: "pause" (default: CSM_PauseMenus_PauseMenu) | "player" (CSM_PauseMenus_PlayerMenu). viaPad: the press came from
-- a pad (KeyboardIsP1 owner shift). The request hook (B) sees this call too (ProcessEvent) and pre-creates for pc.
function M.openPauseMenu(pc, kind, viaPad)
    if M.isPaused() == true then return false end
    notePauser(pc, "mod")
    local ph = St.phase
    if ph ~= "PRERACE" and ph ~= "RACING" then return false end
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    local root = U.obj(C.ASSET.CSM_PauseRoot)
    local target = (kind == "player") and loaded(pauseState("PlayerMenu")) or U.obj(C.ASSET.CSM_PauseMenu)
    if not (U.ok(mgr) and U.ok(root) and U.ok(target)) then
        U.logEvery("pause.unres", 5000, TAG, "cannot pause: mgr=%s root=%s menu=%s", tostring(U.ok(mgr)),
            tostring(U.ok(root)), tostring(U.ok(target)))
        return false
    end
    local sm = mgr:GetStateMachineForRoot(root)
    if not U.ok(sm) then
        U.logEvery("pause.nosm", 5000, TAG, "no state machine for CSM_PauseMenus_Root")
        return false
    end
    P().ownCall = { kind = kind or "pause", atMs = St.nowMs(), why = "mod", pc = pc, pad = viaPad == true }
    -- VERIFY(V-PAU-02): ChangeStateTo from Lua opens the pause menu like the HUD's binding.
    sm:ChangeStateTo(target, "SWGRCouch", nil) -- 3 params: newState, reason (Str), optionalPayload (nil)
    local n = pnumOf(pc)
    local msg = n and ("P" .. n .. " PAUSED") or "GUEST PAUSED"
    U.log(TAG, "%s (%s)", msg, U.pathOf(pc))
    St.emit("status", msg)
    return true
end

-- P1 is polled while it has no race-HUD binding of its own: the game's HUD re-hosted (its binding dropped by the
-- re-add), or (0.7.0) no P1 clone and the game's HUD owned by a guest (UIManager owner) - P1's Start then reaches no
-- IA_Veh_Pause binding at all.
local function p1PollActive()
    if cfg.P1PausePoll ~= true then return false end
    local ok, hud = pcall(U.mod, "hud")
    if ok and type(hud) == "table" and type(hud.p1Rehosted) == "function" then
        local ok2, r = pcall(hud.p1Rehosted)
        if ok2 and r == true then return true end
    end
    if cfg.P1HudMode ~= "clone" and localPCCount() >= 2 then
        local o = gameHudOwner()                              -- review 0.7.0: validated wrapper (see gameHudOwner)
        if o and U.key(o) ~= U.key(U.p1()) then return true end
    end
    return false
end

-- P1 may pause only while the game's own pause binding would exist: the race HUD (IA_Veh_Pause) is up only in the
-- race CSM's *_InHud states [HUD§3.2]. Once P1 finished (CSM_RF_LocalResults: WBP_PostRace_Info_C instead of the HUD
-- [HUD§3.3]) a press must not pause the guests still racing. Evaluated on a press edge only (no per-tick CSM calls).
-- An unknown in-HUD state (nil: CSM not resolvable, V-HUD-05) does not block, like hud.updateVisibility.
local function p1MayPause()
    local ok, hud = pcall(U.mod, "hud")
    if ok and type(hud) == "table" and type(hud.inHudState) == "function" then
        local okS, inHud = pcall(hud.inHudState)
        if okS and inHud == false then return false, "race HUD state not active" end
    end
    if U.csmActive("CSM_LocalResults", true) == true then return false, "P1 is on its results (LocalResults)" end
    return true
end

-- cfg.GuestPauseFallback (default true): with GuestPauseMode "hud", guests' Start is polled as well, as a fallback
-- for a guest HUD whose IA_Veh_Pause binding does not reach the guest. Every polled press (guest or P1) is DEFERRED by
-- cfg.PauseDeferMs (default 200): it acts only if the game is still not paused then, so a binding that did work is
-- never doubled by the poll.
local function guestFallbackOn()
    return cfg.GuestPauseMode == "hud" and cfg.GuestPauseFallback ~= false
end

local function deferMs()
    local v = cfg.PauseDeferMs
    if type(v) == "number" and v >= 0 then return v end
    return 200
end

---------------------------------------------------------------------------------------------------- pause menu
-- The pause screen the CSM shows (UIManager layer Menu, decoded CSM_PauseMenus_Paused_*), else FindAllOf (<= 1 / 2 s).
local function findPauseMenu(st)
    local mgr = U.giSubsystem("UIManager")
    for _, path in ipairs(PAUSE_MENUS) do
        local cls = loaded(path)                       -- never LoadAsset from the FAST loop
        if cls and U.ok(mgr) then
            local ok, w = pcall(function() return mgr:GetWidgetInLayer(cls, MENU) end)
            if ok and U.ok(w) then return w, "UIManager" end
        end
    end
    local now = St.nowMs()
    if now - (st.menuSearchMs or -1e9) < 2000 then return nil end
    st.menuSearchMs = now
    for _, path in ipairs(PAUSE_MENUS) do
        if loaded(path) then
            local okF, all = pcall(FindAllOf, shortCls(path))
            for _, w in ipairs((okF and type(all) == "table") and all or {}) do
                if U.ok(w) and (w:IsInViewport() == true or U.ok(w:GetParent())) then return w, "FindAllOf" end
            end
        end
    end
    return nil
end

local function probe(st, w, tagTxt)
    local d = { owner = "?", vis = "?", op = "?", vp = "?", act = "?", parent = "none", chain = {}, osm = "nil" }
    pcall(function() d.owner = pnumCtrl(w:GetOwningPlayer()) end)
    pcall(function() d.vis = tostring(w:GetVisibility()) end)
    pcall(function() d.op = string.format("%.2f", w:GetRenderOpacity()) end)
    pcall(function() d.vp = tostring(w:IsInViewport()) end)
    pcall(function() d.act = tostring(w:IsActivated()) end)
    pcall(function()
        local o = w.OwningStateMachine
        if U.ok(o) then d.osm = (U.key(o) == smKnownKey) and "ok" or ("other " .. U.pathOf(o)) end
    end)
    pcall(function()
        local o = w:GetParent()
        if U.ok(o) then d.parent = U.pathOf(o) end
        for _ = 1, 8 do
            if not U.ok(o) then break end
            d.chain[#d.chain + 1] = string.format("%s(v%s o%.2f)", o:GetFName():ToString(), tostring(o:GetVisibility()),
                o:GetRenderOpacity())
            o = o:GetParent()
        end
    end)
    local hudVis = "?"
    pcall(function()
        local parts = {}
        for _, e in ipairs(U.mod("hud").allHuds()) do
            parts[#parts + 1] = string.format("P%s:v%s", tostring(e.pnum), tostring(e.widget:GetVisibility()))
        end
        hudVis = table.concat(parts, ",")
    end)
    -- VERIFY(V-PAU-04): the menu is visible (vis 0/3/4, opacity 1.00, inViewport true) and our HUDs are collapsed (v1).
    -- 0.6.0: the user focus (which player's pad navigates it), the pause CSM sub-states, the Menu layer count.
    -- 0.7.0 (V-PAU-10/11/15): owner with its ControllerId, pre=ours (pre-created) | game, osm=ok (OwningStateMachine =
    -- the pause CSM), imcUi=<IMC_UI priority per player>, z=<viewport ZOrder>.
    local focus = "?"
    pcall(function()
        local parts = {}
        for _, lp in ipairs(U.localPlayers()) do
            if U.ok(lp.pc) and (w:HasUserFocus(lp.pc) == true or w:HasUserFocusedDescendants(lp.pc) == true) then
                parts[#parts + 1] = "P" .. lp.index
            end
        end
        focus = #parts > 0 and table.concat(parts, ",") or "none"
    end)
    local pre = (st.pre and st.pre.key == U.key(w)) and "ours" or "game"
    U.log(TAG, "pause menu probe %s: %s via %s owner=%s pre=%s osm=%s vis=%s opacity=%s inViewport=%s activated=%s "
        .. "parent=%s chain=[%s] pauser=%s (%s) views=%d ourHUDs=[%s] csmPaused=%s focus=%s imcUi=%s z=%s states=[%s] "
        .. "menuLayer=%s", tagTxt, U.pathOf(w:GetClass()), tostring(st.menuHow), d.owner, pre, d.osm, d.vis, d.op, d.vp,
        d.act, d.parent, table.concat(d.chain, " < "), pnumDesc(st.pauser), tostring(st.pauserWhy), splitViews(),
        hudVis, tostring(M.isPaused()), focus, imcDesc(), tostring(slotZ(w)), (activeSubStates()), layerCount(MENU))
end

-- Visible + opaque, the menu and every ancestor (a collapsed/transparent parent hides it as well).
local function forceVisible(w)
    local fixed = 0
    local o = w
    for _ = 1, 9 do
        if not U.ok(o) then break end
        pcall(function()
            local v = o:GetVisibility()
            if v == C.E.Vis.Collapsed or v == C.E.Vis.Hidden then
                o:SetVisibility(o == w and C.E.Vis.Visible or C.E.Vis.SelfHitTestInvisible)
                fixed = fixed + 1
            end
            if o:GetRenderOpacity() < 0.99 then o:SetRenderOpacity(1.0); fixed = fixed + 1 end
        end)
        local ok, par = pcall(function() return o:GetParent() end)
        o = ok and par or nil
    end
    return fixed
end

---------------------------------------------------------------------------------------------------- menu parts
-- Run F (f-11.png, "pause menu faint under a white overlay"): that screenshot was taken 19 ms after the rehost below
-- (log: re-add 09:48:02.459, png 09:48:02.478) and ~310 ms after the pause, i.e. on the first frames of the menu's
-- intro animation, which the re-add restarts. Decoded (work/decoded-bp WBP_Pause.json, work/decoded-pause
-- WBP_Background_Blur.json + kismet-disasm), Anim_In of WBP_Pause drives RenderOpacity 0 -> 1 of O_PauseOverlay
-- (0-0.05 s), SzB_ButtonLayout (0-0.25 s) and WBP_ActionBar (0.35-0.5 s); WBP_Background_Blur's own Anim_In drives
-- BB_Background.BlurStrength 0 -> 10 and Img_BackgroundTint's RenderOpacity 0 -> 1 (0-0.25 s). The "white" is the
-- game's design: Img_BackgroundTint.ColorAndOpacity = FillColor (PreConstruct), and WBP_Pause sets FillColor to
-- DCDBD3 at alpha 0.65 (a bone-white frosted backdrop) with inverted (dark-on-light) buttons; Img_GradientVignette
-- is DCDBD3 as well. What this block adds: the opacities/blur are probed (+0/+0.5/+2 s lines), and once per menu
-- instance cfg.PauseMenuSettleMs (default 1500) after the re-add (or first sight) every part above still below its
-- final value is set to it (cfg.PauseMenuSettle, default true): an intro animation torn down by the re-add (UMG
-- stops a removed widget's animations) can no longer leave the menu faint. Only plain floats (RenderOpacity,
-- BlurStrength) are read or written here; no soft pointer, no Blueprint hook.
local PART_WANTED = {
    o_pauseoverlay = 1.0, szb_buttonlayout = 1.0, wbp_actionbar = 1.0, img_backgroundtint = 1.0, -- settled
    wbp_screen_title = false, img_swoop = false, img_gradientvignette = false, wbp_background_blur = false, -- probed
    bb_background = false,
}
local PART_ORDER = { "o_pauseoverlay", "szb_buttonlayout", "wbp_actionbar", "wbp_screen_title", "img_swoop",
    "img_gradientvignette", "wbp_background_blur", "img_backgroundtint", "bb_background" }
local BLUR_FINAL = 10.0
local PART_WALK_MAX = 400
local panelClsP, userClsP

local function lname(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and type(s) == "string" and string.lower(s) or ""
end

-- Breadth-first over the menu's WidgetTree (panels, and the WidgetTree of the nested WBP_Background_Blur):
-- parts[lowerName] = first widget of that name. Cached per menu instance in st.menuParts.
local function menuParts(st, w)
    if st.menuParts and st.menuPartsKey == st.menuKey then return st.menuParts end
    local parts = {}
    if not (panelClsP and U.ok(panelClsP)) then panelClsP = loaded("/Script/UMG.PanelWidget") end
    if not (userClsP and U.ok(userClsP)) then userClsP = loaded("/Script/UMG.UserWidget") end
    if not panelClsP then return parts end
    local queue, head = {}, 1
    local function pushTree(uw)
        pcall(function()
            local tree = uw.WidgetTree
            if U.ok(tree) and U.ok(tree.RootWidget) then queue[#queue + 1] = tree.RootWidget end
        end)
    end
    pushTree(w)
    while head <= #queue and head <= PART_WALK_MAX do
        local o = queue[head]; head = head + 1
        local n = lname(o)
        if PART_WANTED[n] ~= nil and not parts[n] then parts[n] = o end
        pcall(function()
            if o:IsA(panelClsP) then
                for i = 0, (o:GetChildrenCount() or 0) - 1 do
                    local ch = o:GetChildAt(i)
                    if U.ok(ch) then queue[#queue + 1] = ch end
                end
            elseif n == "wbp_background_blur" and userClsP and o:IsA(userClsP) then
                pushTree(o)
            end
        end)
    end
    st.menuParts, st.menuPartsKey = parts, st.menuKey
    return parts
end

local function blurOf(bb)
    local v
    pcall(function() v = bb.BlurStrength end)          -- UBackgroundBlur.BlurStrength (float)
    return type(v) == "number" and v or nil
end

-- "O_PauseOverlay=1.00 SzB_ButtonLayout=0.38 ... BB_Background=blur 10.0" (missing parts: "-")
local function partsLine(parts)
    local out = {}
    for _, n in ipairs(PART_ORDER) do
        local o = parts[n]
        local s = "-"
        if U.ok(o) then
            if n == "bb_background" then
                local b = blurOf(o)
                s = b and string.format("blur %.1f", b) or "blur ?"
            else
                pcall(function() s = string.format("%.2f", o:GetRenderOpacity()) end)
                pcall(function()
                    local v = o:GetVisibility()
                    if v == C.E.Vis.Collapsed or v == C.E.Vis.Hidden then s = s .. "(v" .. tostring(v) .. ")" end
                end)
            end
        end
        out[#out + 1] = n .. "=" .. s
    end
    return table.concat(out, " ")
end

-- Once per menu instance: parts still below their Anim_In end value are set to it. Returns the fixed names.
local function settleParts(st, w)
    local parts = menuParts(st, w)
    local fixed = {}
    for n, final in pairs(PART_WANTED) do
        local o = parts[n]
        if final and U.ok(o) then
            pcall(function()
                local v = o:GetRenderOpacity()
                if v < final - 0.01 then
                    o:SetRenderOpacity(final)
                    fixed[#fixed + 1] = string.format("%s %.2f->%.2f", n, v, final)
                end
            end)
        end
    end
    local bb = parts.bb_background
    if U.ok(bb) then
        local b = blurOf(bb)
        if b and b < BLUR_FINAL - 0.1 then
            pcall(function() bb:SetBlurStrength(BLUR_FINAL) end) -- BackgroundBlur:SetBlurStrength(Float)
            fixed[#fixed + 1] = string.format("bb_background blur %.1f->%.1f", b, BLUR_FINAL)
        end
    end
    return fixed
end

-- 0.6.0 (run G, guest pause): the owner's pad must navigate the menu. Slate.RequireFocusForGamepadInput=1
-- (DefaultEngine.ini): a pad only reaches the widget its own slate user focuses. CommonActivatableWidget:
-- GetDesiredFocusTarget() (the first button) gets the OWNER's user focus (Widget:SetUserFocus(PlayerController)),
-- else the menu itself; plain SetFocus() (the owner's keyboard user) as the last resort. Returns a short text.
local function giveFocus(w, pc)
    if opt("PauseMenuFocusOwner", true) ~= true then
        pcall(function() w:SetFocus() end)
        return "SetFocus"
    end
    if not U.ok(pc) then pcall(function() pc = w:GetOwningPlayer() end) end
    if not U.ok(pc) then
        pcall(function() w:SetFocus() end)
        return "SetFocus (no owner)"
    end
    local t
    pcall(function() t = w:GetDesiredFocusTarget() end)
    if U.ok(t) and pcall(function() t:SetUserFocus(pc) end) then
        return pnumDesc(pc) .. " -> " .. lname(t)
    end
    if pcall(function() w:SetUserFocus(pc) end) then return pnumDesc(pc) .. " -> menu" end
    pcall(function() w:SetFocus() end)
    return "SetFocus (SetUserFocus failed)"
end

-- Whole viewport, owned by the pauser. CommonUI: RemoveFromParent runs NativeDestruct (deactivates an active
-- widget); NativeConstruct on the re-add registers it with its (new) owner's action router; ActivateWidget again.
-- why: "rehost" (split race, once per instance) or "lost" (0.6.0: the menu was not in the viewport any more).
local function rehost(st, w, why)
    local target = st.pauser
    if opt("PauseMenuOwner", "pauser") ~= "pauser" or not U.ok(target) then target = nil end
    local wasAct = false
    pcall(function() wasAct = w:IsActivated() == true end)
    local ownerBefore = "?"
    pcall(function() ownerBefore = pnumDesc(w:GetOwningPlayer()) end)
    local focusTxt = "-"
    local ok, err = pcall(function()
        if target and U.key(w:GetOwningPlayer()) ~= U.key(target) then w:SetOwningPlayer(target) end
        w:RemoveFromParent()
        w:AddToViewport(opt("PauseMenuZOrder", 50))           -- UserWidget:AddToViewport(Int ZOrder)
        -- a lost menu may have been deactivated with it: activated again (the pause still runs)
        if (wasAct or why == "lost") and w:IsActivated() ~= true then w:ActivateWidget() end
        focusTxt = giveFocus(w, target)
    end)
    st.rehostedAtMs, st.menuW = St.nowMs(), w
    local actNow = "?"
    pcall(function() actNow = tostring(w:IsActivated()) end)
    -- VERIFY(V-PAU-07): "focus P2 -> ..." for a guest's pause, and that guest's pad moves the menu selection
    U.log(TAG, "pause menu re-added to the whole viewport (%s): owner %s -> %s, activated before=%s now=%s, focus %s%s",
        tostring(why or "rehost"), ownerBefore, target and pnumDesc(target) or ownerBefore, tostring(wasAct), actNow,
        focusTxt, ok and "" or (" ERROR " .. tostring(err)))
end

---------------------------------------------------------------------------------------------------- request hook (B)
local function keyDown(pc, k)
    local ok, v = pcall(function() return pc:IsInputKeyDown(k) end)
    return ok and v == true
end

-- The pause key a local player holds now: Start (pads), Escape / P (P1's keyboard). Returns name, viaPad.
local function pauseKeyOf(lp)
    if keyDown(lp.pc, KEY_START) then return "Start", true end
    if lp.index == 1 then
        if keyDown(lp.pc, KEY_ESC) then return "Escape", false end
        if keyDown(lp.pc, KEY_P) then return "P", false end
    end
    return nil, nil
end

local function playerKeyOf(lp)
    if keyDown(lp.pc, KEY_VIEW) then return "View", true end
    if lp.index == 1 then
        if keyDown(lp.pc, KEY_TAB) then return "Tab", false end
        if keyDown(lp.pc, KEY_O) then return "O", false end
    end
    return nil, nil
end

-- IA_Veh_Player is a Tap (0.3 s): it fires on the RELEASE frame.
local function playerKeyJustReleased(lp)
    local function rel(k)
        local ok, v = pcall(function() return lp.pc:WasInputKeyJustReleased(k) end)
        return ok and v == true
    end
    if rel(KEY_VIEW) then return "View", true end
    if lp.index == 1 then
        if rel(KEY_TAB) then return "Tab", false end
        if rel(KEY_O) then return "O", false end
    end
    return nil, nil
end

-- Who made this request. Our own call (openPauseMenu, repair, after-wreck restart) named its PC < 1 s ago; a HUD
-- binding fires on the pressing PC's own input stack, so that PC holds a pause key now (IA_Veh_Pause: Triggered while
-- held) or has just released a player key (IA_Veh_Player). FAST edges are the fallback. nil = unknown.
local function pauserFor(st, kind, now)
    local own = st.ownCall
    if own and now - own.atMs < 1000 then
        if U.ok(own.pc) then return own.pc, "our call (" .. tostring(own.why) .. ")", own.pad end
        if own.why == "repair" and U.ok(st.pauser) then return st.pauser, "repair", st.pauserViaPad end
    end
    keys()
    local cands = {}
    for _, lp in ipairs(U.localPlayers()) do
        if U.ok(lp.pc) then
            local k, pad
            if kind == "player" then k, pad = playerKeyJustReleased(lp) else k, pad = pauseKeyOf(lp) end
            if k then cands[#cands + 1] = { lp = lp, key = k, pad = pad } end
        end
    end
    if #cands > 1 and kind ~= "player" then        -- two players hold a pause key: the one that just pressed it
        for _, c in ipairs(cands) do
            local ks = (c.key == "Start" and KEY_START) or (c.key == "Escape" and KEY_ESC) or KEY_P
            local ok, j = pcall(function() return c.lp.pc:WasInputKeyJustPressed(ks) end)
            if ok and j == true then cands = { c }; break end
        end
    end
    local c = cands[1]
    if c then
        return c.lp.pc, string.format("P%d %s %s", c.lp.index, c.key, kind == "player" and "released" or "down"), c.pad
    end
    local e = (kind == "player") and st.lastPlayerPress or st.lastPausePress
    if e and U.ok(e.pc) and now - e.atMs < ((kind == "player") and 700 or 400) then
        return e.pc, string.format("P%d %s %d ms ago", e.pnum, e.key, math.floor(now - e.atMs)), e.pad
    end
    return nil, "unknown", false
end

-- A pause / player-menu REQUEST (the pause CSM is not paused yet): A2, C, D before the CSM's transition runs.
-- VERIFY(V-PAU-17): a guest's Back/View gives "kind=player target=PlayerMenu by P2 (P2 View released) ...
--   WBP_PlayerMenu_Presentation_C pre-created for P2"; P2's B closes it.
-- VERIFY(V-PAU-18): Start held 2 s gives ONE request line (A2 pops every HUD binding inside this call, so the held key
--   cannot fire IA_Veh_Pause on the next frames) and no "duplicate" / "lost menu" line.
local function onRequest(st, kind, tname, now)
    -- review 0.7.0: requestWatch undoes A2/C/D if no pause follows (a request made DURING a pause is undone by the
    -- normal resume path)
    if M.isPaused() ~= true then st.reqAtMs = now end
    local pauser, pwhy, viaPad = pauserFor(st, kind, now)
    notePauser(pauser, pwhy)
    st.pauserViaPad = viaPad
    local off = hudInputsOff(st, "request")
    local owner, owhy = ownerFor(pauser, viaPad)
    local leaf = (kind == "player") and "PlayerMenu" or pickLeaf()
    local preTxt
    if owhy == "game" then
        preTxt = "no pre-create (PauseMenuOwner game: the UIManager's owner)"
    else
        local w, z = precreate(st, kind, leaf, owner, owhy, "request")
        preTxt = w and string.format("%s pre-created for %s (z=%s, %s)", shortCls(LEAF_CLASS[leaf]), pnumCtrl(owner),
            tostring(z), owhy) or ("no pre-create: " .. tostring(z))
    end
    local imcTxt = imcBoost(st, owner, "request")
    st.reqCount = (st.reqCount or 0) + 1
    U.log(TAG, "request on the pause CSM: kind=%s target=%s by %s (%s) -> HUD inputs off (%s), %s; IMC_UI %s "
        .. "(V-PAU-11)", kind, tostring(tname or "?"), pnumDesc(pauser), tostring(pwhy), off, preTxt, imcTxt)
end

-- The CSM is about to enter a menu leaf (BP_CsmPickPauseMenu's own call, or our repair): a request the hook missed,
-- or a PrimaryFlow mirror that chose another screen, gets its screen pre-created now.
local function onPick(st, leaf, now)
    if M.isPaused() ~= true then st.reqAtMs = now end   -- review 0.7.0: requestWatch (a pick no pause followed)
    local pre = st.pre
    if pre and U.ok(pre.w) then
        local first = inLayerFirst(pre.cls)
        if first and U.key(first) == pre.key and pre.leaf == leaf then return end -- this transition acquires ours
        retirePre(st, "the CSM enters " .. tostring(leaf))   -- 0.7.2 (was: acquired -> forgotten, else removed)
    end
    hudInputsOff(st, "pick")
    local own = st.ownCall
    local owner, owhy = ownerFor(U.ok(st.pauser) and st.pauser or nil, st.pauserViaPad)
    if owhy == "game" then return end
    local w, z = precreate(st, "pause", leaf, owner, owhy, own and own.why or "pick")
    U.log(TAG, "pause CSM enters %s%s: %s (V-PAU-11)", leaf, own and (" (" .. tostring(own.why) .. ")") or "",
        w and string.format("%s pre-created for %s (z=%s, %s)", shortCls(LEAF_CLASS[leaf]), pnumCtrl(owner),
            tostring(z), owhy) or ("no pre-create: " .. tostring(z)))
    imcBoost(st, owner, "pick")
end

-- 0.7.2 (C2): a screen opened FROM a pause (Settings, its pages, the Logbook) is about to be shown by the CSM: it is
-- created now for the pause controller = ownerFor(pauser), the owner the pause screen got (the UIManager would use the
-- LAST local PC: P2 for P1's Settings in 2P, P4 for P2's in 4P), with the 0.7.0 recipe; the CSM acquires it. A screen
-- of that class already in the Menu layer (the page reopened while its old screen fades out) is left alone: the CSM
-- acquires that one. via: "ChangeStateTo" (B, newState read) | "ChangeToState '<reason>'" (B2).  VERIFY(V-PAU-19/20)
local function onSubScreen(st, state, now, via)
    st.subReqs = (st.subReqs or 0) + 1
    local owner, owhy = ownerFor(U.ok(st.pauser) and st.pauser or nil, st.pauserViaPad)
    if owhy == "game" then
        U.log(TAG, "sub-screen request: %s via %s -> no pre-create (PauseMenuOwner game) (V-PAU-19)", state, via)
        return
    end
    local path = SUB_CLASS[state]
    local cls = path and loaded(path) or nil
    local ex = cls and inLayerFirst(cls) or nil
    local txt
    if ex then
        local o
        pcall(function() o = ex:GetOwningPlayer() end)
        txt = string.format("no pre-create: the Menu layer already holds %s (owner %s)", shortCls(path), pnumDesc(o))
    else
        retirePre(st, "sub-screen " .. tostring(state))
        local w, z = precreate(st, "sub", state, owner, owhy, via)
        txt = w and string.format("%s pre-created for %s (z=%s, %s)", shortCls(path), pnumCtrl(owner), tostring(z),
            owhy) or ("no pre-create: " .. tostring(z))
    end
    st.subAtMs = now
    U.log(TAG, "sub-screen request: %s via %s -> %s (%s)", state, via, txt,
        state == "Stickerbook" and "V-PAU-20" or "V-PAU-19")
end

-- ChangeStateTo pre-hook body (armed split race only). Reads ctx, then newState (a hard Object<UCsmAsset>; run H's
-- probe hooks read params of Blueprint callers correctly: messageId, ContextObject/Class). Never :set().
local function onCsmPre(ctxP, newStateP)
    local sm = ctxP:get()
    if not isPauseSm(sm) then return end
    local st = P()
    local now = St.nowMs()
    st.hookCalls = (st.hookCalls or 0) + 1
    local tname
    if opt("PauseHookReadState", true) then
        local ok, o = pcall(function() return newStateP:get() end)
        if ok and U.ok(o) then tname = stateShort(o) end
    end
    if st.ownCall and now - st.ownCall.atMs > 1000 then st.ownCall = nil end
    local paused = M.isPaused()
    if opt("PauseHookTrace", false) then
        U.log(TAG, "hook: ChangeStateTo(%s) on the pause CSM, paused=%s states=[%s] own=%s", tostring(tname),
            tostring(paused), (activeSubStates()), st.ownCall and tostring(st.ownCall.why) or "-")
    end
    if tname then
        if tname == "PauseMenu" then
            if paused == true then
                local subs, _, set = activeSubStates()
                if set.PauseMenu then
                    st.dupAtMs = now
                    U.warn(TAG, "duplicate ChangeStateTo(PauseMenu) while [%s] (a second IA_Veh_Pause binding or a "
                        .. "held Start): the CSM leaves %s; repair armed (V-PAU-12)", subs,
                        tostring(leafOf(set) or "nothing"))
                    return
                end
            end
            return onRequest(st, "pause", tname, now)
        elseif tname == "PlayerMenu" then
            if paused ~= true then return onRequest(st, "player", tname, now) end
            return
        elseif LEAF_CLASS[tname] then
            return onPick(st, tname, now)
        elseif SUB_CLASS[tname] then                    -- 0.7.2 (C2): Settings (WBP_Pause) or one of its pages
            if paused == true then return onSubScreen(st, tname, now, "ChangeStateTo") end
            return
        end
        return
    end
    -- no state name (cfg.PauseHookReadState false, or unreadable): inferred from the CSM state and the keys
    if paused ~= true then
        local kind = st.ownCall and st.ownCall.kind or nil
        if not kind then
            local e = st.lastPlayerPress
            kind = (e and now - e.atMs < 700) and "player" or "pause"
            for _, lp in ipairs(U.localPlayers()) do
                if U.ok(lp.pc) and pauseKeyOf(lp) then kind = "pause"; break end
            end
        end
        return onRequest(st, kind, nil, now)
    end
    local subs, _, set = activeSubStates()
    local leaf = leafOf(set)
    if set.PauseMenu and not leaf then return onPick(st, pickLeaf() or "Paused_Racing", now) end
    if set.PauseMenu and leaf then
        for _, lp in ipairs(U.localPlayers()) do
            if U.ok(lp.pc) and pauseKeyOf(lp) then
                st.dupAtMs = now
                U.warn(TAG, "ChangeStateTo while [%s] with %s's pause key down: probably a duplicate PauseMenu "
                    .. "request; repair armed (V-PAU-12)", subs, pnumDesc(lp.pc))
                return
            end
        end
    end
end

-- Hot-reload-safe registry: _G.SWGRCouch_pause_hooks = {ids = {[path] = {pre, post}}, on = {[path] = handler},
-- armed = bool}. The registered callback reads only this table: a re-required pause.lua swaps the handler without a
-- second RegisterHook; RestartCurrentMod gets a fresh Lua state (UE4SS unhooks the old state's hooks itself).
local HOOK_CSM = "/Script/Griffin.CosmeticStateMachine:ChangeStateTo"
-- 0.7.2 (B2): ChangeToState(SoftObject<UCsmAsset> newState, Str reason, Object optionalPayload) [reflect-types]
local HOOK_CTS = "/Script/Griffin.CosmeticStateMachine:ChangeToState"

local function HK()
    local H = _G.SWGRCouch_pause_hooks
    if type(H) ~= "table" then
        H = {}
        _G.SWGRCouch_pause_hooks = H
    end
    H.ids = H.ids or {}
    H.on = H.on or {}
    return H
end

-- The registered pre-callback: the armed flag first (no param is touched while disarmed: race teardown, travel), then
-- the current handler inside pcall. Returns nil (ChangeStateTo has no return value to override).
local function csmHookCb(ctx, a, b, c)
    local H = _G.SWGRCouch_pause_hooks
    if type(H) ~= "table" or H.armed ~= true then return nil end
    local f = H.on and H.on[HOOK_CSM]
    if f then pcall(f, ctx, a, b, c) end
    return nil
end

local function hookHandler(ctx, a, b, c)
    U.tryEvery("pause.hook", nil, TAG, onCsmPre, ctx, a, b, c)
end

-- 0.7.2: the same guard for B2 (ChangeToState).
local function ctsHookCb(ctx, a, b, c)
    local H = _G.SWGRCouch_pause_hooks
    if type(H) ~= "table" or H.armed ~= true then return nil end
    local f = H.on and H.on[HOOK_CTS]
    if f then pcall(f, ctx, a, b, c) end
    return nil
end

-- B2 body (armed split race only). HARD RULE: the soft newState param (the 2nd callback argument) is NEVER touched:
-- no :get(), no U.str / U.unwrap on it. UE4SS only wraps its address (push_softobjectproperty, Operation::GetParam ->
-- RemoteUnrealParam; LuaUObject.cpp); the soft pointer is read by the game's own code only. ctx and the Str reason
-- (a literal in the calling Blueprint) are read.  VERIFY(V-PAU-20)
local function onCtsPre(ctxP, _softNewStateNeverRead, reasonP)
    local sm = ctxP:get()
    if not isPauseSm(sm) then return end
    local st = P()
    st.ctsCalls = (st.ctsCalls or 0) + 1
    if not opt("PauseSubScreenHook", false) then return end
    local reason = U.str(reasonP)
    local state = REASON_STATE[reason]
    local paused = M.isPaused()
    if opt("PauseHookTrace", false) then
        U.log(TAG, "hook: ChangeToState(<soft target, not read>, '%s') on the pause CSM, paused=%s states=[%s]", reason,
            tostring(paused), (activeSubStates()))
    end
    if not state then
        U.logOnce("pause.cts." .. reason, TAG, "ChangeToState on the pause CSM, reason '%s': %s (V-PAU-20)", reason,
            REASON_KNOWN[reason] or "not mapped: no pre-create, the UIManager picks the owner (menubridge fallback)")
        return
    end
    if paused == true then return onSubScreen(st, state, St.nowMs(), "ChangeToState '" .. reason .. "'") end
end

local function ctsHandler(ctx, a, b, c)
    U.tryEvery("pause.ctshook", nil, TAG, onCtsPre, ctx, a, b, c)
end

local HOOK_CB = { [HOOK_CSM] = csmHookCb, [HOOK_CTS] = ctsHookCb }
local HOOK_ON = { [HOOK_CSM] = hookHandler, [HOOK_CTS] = ctsHandler }
local HOOK_VID = { [HOOK_CSM] = "V-PAU-11", [HOOK_CTS] = "V-PAU-20" }

local function ensureHook(st, path)
    path = path or HOOK_CSM
    local H = HK()
    H.on[path] = HOOK_ON[path]
    if H.ids[path] then return true end
    if type(st.hookFailed) ~= "table" then st.hookFailed = {} end
    if st.hookFailed[path] or not loaded(path) then return false end
    local ok, pre, post = pcall(RegisterHook, path, HOOK_CB[path])
    if not ok or type(pre) ~= "number" then
        st.hookFailed[path] = tostring(pre)
        U.err(TAG, "RegisterHook(%s) failed: %s - %s (%s)", path, tostring(pre), path == HOOK_CSM
            and "requests are not seen (no pre-create; A/D/F/G still run)" or "no Logbook pre-create", HOOK_VID[path])
        return false
    end
    H.ids[path] = { pre = pre, post = post }
    U.log(TAG, "native pre-hook registered: %s (ids %s/%s, kept in _G.SWGRCouch_pause_hooks) (%s)", path,
        tostring(pre), tostring(post), HOOK_VID[path])
    return true
end

-- Disarm now and unregister. UnregisterHook only marks a native hook for removal (UE4SS LuaMod.cpp: removed in the
-- post-callback of the next call; the pre-callback of a marked hook returns before any Lua), so it is safe from any
-- context, also from inside a ChangeStateTo. 0.7.2: both hooks (ChangeStateTo, ChangeToState).
local function dropHook(why)
    local H = HK()
    H.armed = false
    local names, errs = {}, {}
    for _, path in ipairs({ HOOK_CSM, HOOK_CTS }) do
        local ids = H.ids[path]
        if ids then
            H.ids[path] = nil
            local ok, e = pcall(UnregisterHook, path, ids.pre, ids.post or ids.pre)
            names[#names + 1] = path:match(":([^:]+)$") or path
            if not ok then errs[#errs + 1] = tostring(e) end
        end
    end
    if #names == 0 then return end
    U.log(TAG, "native pre-hook unregistered (%s): %s%s", tostring(why), table.concat(names, ", "),
        #errs > 0 and (" (errors: " .. table.concat(errs, "; ") .. ")") or "")
end

---------------------------------------------------------------------------------------------------- safety net (F)
-- cfg.PauseLostMenu "recover" (default) | "probe" (log only) | "off". Never while Settings / Photomode / Stickerbook or
-- a dialog is up, never in photo mode, never re-adding a screen.  VERIFY(V-PAU-12, V-PAU-13, V-PAU-14)
local function lostMode() return opt("PauseLostMenu", "recover") end

-- Is the leaf's screen in the Menu layer and on screen? (class not in memory: cannot judge -> true)
local function leafScreen(leaf)
    local cls = loaded(LEAF_CLASS[leaf])
    if not cls then return true end
    local w = inLayerFirst(cls)
    if not w then return false end
    local shown = false
    pcall(function() shown = w:IsInViewport() == true or U.ok(w:GetParent()) end)
    return shown
end

-- F1: [PauseMenu] without a sub-state (a second ChangeStateTo(PauseMenu) left Paused_*, or PickPauseMenu chose
-- nothing) -> the same switch as BP_CsmPickPauseMenu from Lua; the hook pre-creates the screen for the pauser. After
-- two repairs, or with no sub-state for this PrimaryFlow, the game is resumed instead.
local function f1(st, now, subs, mode)
    st.repairs = (st.repairs or 0) + 1
    st.noLeafSince = now
    local leaf, flow = pickLeaf()
    if mode ~= "recover" then
        U.warn(TAG, "lost menu: [%s] without sub-state (PauseLostMenu %s: probe only) (V-PAU-12)", subs, mode)
        return
    end
    if st.repairs > 2 or not leaf then
        local ok = pauseCsmChange("CSM_PauseIdle", "SWGRCouch lost menu")
        U.warn(TAG, "lost menu: [%s] still without sub-state after %d repair(s)%s: resumed (Idle %s) (V-PAU-12)", subs,
            st.repairs - 1, leaf and "" or (" (PrimaryFlow " .. tostring(flow) .. ": no sub-state)"),
            ok and "ok" or "failed")
        st.repairs = 0
        return
    end
    st.ownCall = { kind = "pause", atMs = now, why = "repair" }
    local ok = pauseCsmChange(leaf, "SWGRCouch repair")
    U.log(TAG, "lost menu: [%s] without sub-state -> ChangeStateTo(CSM_PauseMenus_%s) for %s (repair %d: %s) "
        .. "(V-PAU-12)", subs, leaf, pnumDesc(st.pauser), st.repairs, ok and "ok" or "failed")
end

-- F2: a menu leaf whose screen is missing for PauseLostMenuMs -> resumed (never re-added).
local function f2(st, leaf, subs, mode)
    st.noScreenSince = nil
    if mode ~= "recover" then
        U.warn(TAG, "lost menu: [%s] shows no %s (PauseLostMenu %s: probe only) (V-PAU-12)", subs,
            shortCls(LEAF_CLASS[leaf]), mode)
        return
    end
    local ok = pauseCsmChange("CSM_PauseIdle", "SWGRCouch lost menu")
    U.warn(TAG, "lost menu: [%s] without its %s for %d ms: resumed (Idle %s); the screen is never re-added (V-PAU-12)",
        subs, shortCls(LEAF_CLASS[leaf]), math.floor(opt("PauseLostMenuMs", 1500)), ok and "ok" or "failed")
end

-- F3, cfg.PauseAnyStartResumes: "fallback" (default: a pause key of a player who does not own the menu) | "always" (any
-- local player's) | "off". The press counts once the menu leaf is up for 400 ms; if the menu did not close 300 ms
-- later (its owner's router got nothing, or the menu is dead), the pause is resumed from Lua.
local function f3(st, now, leaf)
    local mode = opt("PauseAnyStartResumes", "fallback")
    if mode == "off" or not leaf then st.f3 = nil; return end
    if st.f3 then
        if now - st.f3.atMs >= 300 then
            local f = st.f3
            st.f3 = nil
            local ok = pauseCsmChange("CSM_PauseIdle", "SWGRCouch any start")
            U.log(TAG, "%s %s while %s's menu is up: resumed from Lua (Idle %s) (V-PAU-13)", f.who, f.key, f.owner,
                ok and "ok" or "failed")
        end
        return
    end
    local e = st.lastPausePress
    if not (e and e.seq ~= st.f3Seq and st.leafSinceMs and e.atMs >= st.leafSinceMs + 400) then return end
    st.f3Seq = e.seq
    local owner = st.lastOwner
    local isOwner = U.ok(owner) and U.key(owner) == U.key(e.pc)
    if mode == "always" or not isOwner then
        st.f3 = { atMs = now, who = "P" .. tostring(e.pnum), key = e.key, owner = pnumDesc(owner) }
    end
end

-- FAST while paused: every 50 ms during the first 2 s of a pause / after a duplicate request, else every 200 ms.
local function safetyTick(st, now)
    local mode = lostMode()
    if mode == "off" then return end
    local hot = (st.pausedAtMs and now - st.pausedAtMs < 2000) or (st.dupAtMs and now - st.dupAtMs < 1000)
    if now - (st.fMs or -1e12) < (hot and 50 or 200) then return end
    st.fMs = now
    local okP, ph = pcall(U.mod, "phase")
    if okP and type(ph) == "table" and ph.photoMode and ph.photoMode() == true then return end
    if not cont.list then containers() end
    local subs, other, set = activeSubStates()
    local dlg = dialogUp()
    local leaf = leafOf(set)
    if leaf ~= st.leafNow then st.leafSinceMs = now end
    st.leafNow = leaf
    if set.PauseMenu and not leaf and not other and not dlg then
        st.noLeafSince = st.noLeafSince or now
        local wait = (st.dupAtMs and now - st.dupAtMs < 1000) and 50 or opt("PauseNoSubStateMs", 150)
        if now - st.noLeafSince >= wait then f1(st, now, subs, mode) end
    else
        st.noLeafSince = nil
    end
    if leaf and not other and not dlg then
        if leafScreen(leaf) then
            st.noScreenSince = nil
        else
            st.noScreenSince = st.noScreenSince or now
            if now - st.noScreenSince >= opt("PauseLostMenuMs", 1500) then f2(st, leaf, subs, mode) end
        end
    else
        st.noScreenSince = nil
    end
    if other or dlg then st.f3 = nil else f3(st, now, leaf) end
end

---------------------------------------------------------------------------------------------------- focus (E)
-- cfg.PauseMenuFocusOwner (default true): while the menu is activated and no dialog is up, the OWNER's slate user must
-- focus the menu or a descendant, else GetDesiredFocusTarget() gets that user's focus (giveFocus; at most every 500 ms,
-- 6 times per menu). The MENU is tested (HasUserFocus / HasUserFocusedDescendants), never the button: run H solo read
-- HasUserFocus false on the focused button while the menu worked.  VERIFY(V-PAU-15)
local function focusTick(st, w, now)
    if opt("PauseMenuFocusOwner", true) ~= true then return end
    if now - (st.focusMs or -1e12) < 500 then return end
    st.focusMs = now
    local owner
    pcall(function() owner = w:GetOwningPlayer() end)
    if not U.ok(owner) then return end
    local act = false
    pcall(function() act = w:IsActivated() == true end)
    if not act or dialogUp() then return end
    local has = false
    pcall(function() has = w:HasUserFocus(owner) == true or w:HasUserFocusedDescendants(owner) == true end)
    if has then return end
    if st.focusKey ~= U.key(w) then st.focusKey, st.focusFixes, st.focusGaveUp = U.key(w), 0, false end
    if st.focusFixes >= 6 then
        if not st.focusGaveUp then
            st.focusGaveUp = true
            U.warn(TAG, "focus: %s keeps losing the menu's focus (6 fixes): left alone (V-PAU-15)", pnumDesc(owner))
        end
        return
    end
    st.focusFixes = st.focusFixes + 1
    local txt = giveFocus(w, owner)
    if st.focusFixes == 1 then
        U.log(TAG, "focus: %s had no focus in the menu -> %s (V-PAU-15)", pnumCtrl(owner), txt)
    else
        U.dbg(TAG, "focus fix #%d: %s", st.focusFixes, txt)
    end
end

---------------------------------------------------------------------------------------------------- sub-screens (E2)
-- 0.7.2: the screen opened from a pause (Settings and its pages, the Logbook): in the Menu layer, activated, shown.
-- Find-only (StaticFindObject classes, UIManager:GetWidgetInLayer): no LoadAsset, no object-array scan.
local function findSubScreen()
    local mgr = U.giSubsystem("UIManager")
    if not U.ok(mgr) then return nil end
    for _, path in ipairs(SUB_PATHS) do
        local cls = loaded(path)
        if cls then
            local ok, w = pcall(function() return mgr:GetWidgetInLayer(cls, MENU) end)
            if ok and U.ok(w) then
                local shown, act = false, true
                pcall(function() shown = w:IsInViewport() == true or U.ok(w:GetParent()) end)
                pcall(function() act = w:IsActivated() ~= false end)
                if shown and act then return w, path end
            end
        end
    end
    return nil
end

-- "P2" / "P1,P2" / "none": the local players whose slate user focuses w or a descendant
local function focusOf(w)
    local parts = {}
    for _, lp in ipairs(U.localPlayers()) do
        local has = false
        if U.ok(lp.pc) then
            pcall(function() has = w:HasUserFocus(lp.pc) == true or w:HasUserFocusedDescendants(lp.pc) == true end)
        end
        if has then parts[#parts + 1] = "P" .. lp.index end
    end
    return #parts > 0 and table.concat(parts, ",") or "none"
end

-- Probes at first sight / +500 ms (owner, pre=ours|game, osm, activated, focus, controller). At +500 ms an owner with
-- no focus inside the screen gets it ONCE (giveFocus; never repeated: a settings page must not have its focus pulled
-- back while the player navigates). A screen not owned by the controller is a WARN (no pre-create: class not in
-- memory, PauseSubScreenPrecreate off, an unmapped ChangeToState, or a page re-entered by C++ Back): menubridge's
-- controller fallback covers it. Returns true while such a screen is up.  VERIFY(V-PAU-19)
local function subTick(st, now)
    local w, path = findSubScreen()
    if not w then
        st.subKey = nil
        return false
    end
    local k = U.key(w)
    if st.subKey ~= k then st.subKey, st.subSeenMs, st.subProbes, st.subFocusDone = k, now, 0, false end
    local due = ({ 0, 500 })[st.subProbes + 1]
    if not (due and now - st.subSeenMs >= due) then return true end
    st.subProbes = st.subProbes + 1
    local owner, osm, act = nil, "nil", "?"
    pcall(function() owner = w:GetOwningPlayer() end)
    pcall(function()
        local o = w.OwningStateMachine
        if U.ok(o) then osm = (U.key(o) == smKnownKey) and "ok" or U.pathOf(o) end
    end)
    pcall(function() act = tostring(w:IsActivated()) end)
    local ctl, cwhy = ownerFor(U.ok(st.pauser) and st.pauser or nil, st.pauserViaPad)
    local mismatch = cwhy ~= "game" and U.ok(ctl) and U.key(owner) ~= U.key(ctl)
    local focus = focusOf(w)
    local logf = mismatch and U.warn or U.log
    logf(TAG, "sub-screen probe +%dms: %s owner=%s pre=%s osm=%s activated=%s focus=%s controller=%s imcUi=%s "
        .. "states=[%s]%s (V-PAU-19)", math.floor(now - st.subSeenMs), shortCls(path), pnumCtrl(owner),
        (st.pre and st.pre.key == k) and "ours" or "game", osm, act, focus,
        cwhy == "game" and "game" or pnumCtrl(ctl), imcDesc(), (activeSubStates()),
        mismatch and " - NOT the controller's screen (menubridge fallback)" or "")
    if st.subProbes == 2 and not st.subFocusDone and opt("PauseMenuFocusOwner", true) and U.ok(owner) then
        st.subFocusDone = true
        if not focus:find(pnumDesc(owner), 1, true) and not dialogUp() then
            U.log(TAG, "sub-screen focus: %s had none in %s -> %s (V-PAU-19)", pnumCtrl(owner), shortCls(path),
                giveFocus(w, owner))
        end
    end
    return true
end

---------------------------------------------------------------------------------------------------- menu tick
-- C is on when the hook may pre-create the screen.
local function precreateOn()
    local o = opt("PauseMenuOwner", "pauser")
    return opt("PauseMenuPrecreate", true) and opt("PauseCsmHook", true) and o ~= "game" and o ~= "keep"
end

-- Every MENU_EVERY_MS while paused (FAST loop). Per menu instance: probe at first sight / +0.5 s / +2 s, visibility
-- fix, focus (E), settle; one rehost only with cfg.PauseMenuRehost "always" (A/B tests).
local function menuTick(st, pausedNow, now)
    -- review 0.5.0: nil = the pause CSM cannot be read this tick (unknown), not "the pause ended"
    if pausedNow == nil then return end
    if pausedNow ~= true then
        -- a menu WE moved to the viewport (rehost) is no longer the UIManager's to take down: removed once the pause ends
        if st.menuW ~= nil then
            local w = st.menuW
            st.menuW = nil
            pcall(function()
                if U.ok(w) and w:IsInViewport() == true then
                    w:RemoveFromParent()
                    U.log(TAG, "pause over: the re-added pause menu taken off the viewport")
                end
            end)
        end
        -- a Start / menu-key press since the rehost = the player resumed (review 0.5.0): not the rehost's doing
        local userResumed = (st.lastPress and st.lastPress.atMs >= (st.rehostedAtMs or 0))
            or (st.lastMenuPressMs and st.lastMenuPressMs >= (st.rehostedAtMs or 0))
        if userResumed and st.rehostedAtMs and now - st.rehostedAtMs < 600 then
            U.log(TAG, "pause ended %.0f ms after the pause-menu rehost by a player's press: rehost kept",
                now - st.rehostedAtMs)
        end
        if st.rehostedAtMs and st.menuKey and now - st.rehostedAtMs < 600 and not st.rehostBroken
            and not userResumed then
            -- the re-add closed the pause (deactivation popped the state): switch the rehost off and reopen
            st.rehostBroken = true
            U.warn(TAG, "pause ended %.0f ms after the pause-menu rehost: rehost off for this session (V-PAU-04; "
                .. "cfg.PauseMenuRehost = \"never\"); reopening the pause", now - st.rehostedAtMs)
            local who = U.ok(st.pauser) and st.pauser or U.p1()
            if U.ok(who) then U.try(TAG, M.openPauseMenu, who) end
        end
        st.menuKey, st.rehostedAtMs, st.rehostPending, st.menuParts = nil, nil, false, nil
        st.noMenuLogged = false
        return
    end
    -- a pending rehost is checked on every FAST tick (run F: double fade-in with the 250 ms cadence)
    if not st.rehostPending and now - (st.menuTickMs or -1e9) < MENU_EVERY_MS then return end
    st.menuTickMs = now
    local okP, ph = pcall(U.mod, "phase")
    if okP and type(ph) == "table" and ph.photoMode and ph.photoMode() then   -- photo mode: no menu
        st.rehostPending = false
        return
    end
    -- 0.7.2 (E2): a screen opened from the pause (Settings, its pages, the Logbook) replaces the pause screen
    local okS, onSub = U.tryEvery("pause.sub", nil, TAG, subTick, st, now)
    if okS and onSub == true then
        st.rehostPending, st.noMenuLogged = false, true      -- no "pause menu widget not found" line meanwhile
        return
    end
    local w, how = findPauseMenu(st)
    local shown = false
    if w then pcall(function() shown = w:IsInViewport() == true or U.ok(w:GetParent()) end) end
    if not w or not shown then
        st.rehostPending = false
        if not st.noMenuLogged then
            st.noMenuLogged = true
            local dlg, what = dialogUp()
            U.log(TAG, "paused, pause menu widget %s (classes loaded: %s; states [%s]%s)",
                w and "not in the viewport" or "not found yet", tostring(loaded(PAUSE_MENUS[1]) ~= nil),
                (activeSubStates()), dlg and (" +dialog " .. tostring(what)) or "")
        end
        if not w then return end
    end
    if shown then st.noMenuLogged = false end
    pcall(function() st.lastOwner = w:GetOwningPlayer() end)
    local k = U.key(w)
    if k ~= st.menuKey then
        st.menuKey, st.menuSeenMs, st.menuProbes, st.menuHow, st.menuRehosted = k, now, 0, how, false
        st.menuSettled, st.menuParts = false, nil
        -- 0.7.0: a screen the UIManager built itself shows the exact Menu-layer ZOrder it uses (LayerBase + count)
        if how == "UIManager" and not (st.pre and st.pre.key == k) then
            local z = slotZ(w)
            if z and z ~= zSeen then
                zSeen = z
                U.log(TAG, "Menu-layer ZOrder seen on the UIManager's %s: %d", U.pathOf(w:GetClass()):match("[^%.]+$")
                    or "?", z)
            end
        end
        -- D for a menu nobody pre-created (hook off / missed) and for cfg.PauseUiImcBoost "owner"
        if localPCCount() >= 2 then imcBoost(st, st.lastOwner, "menu owner") end
    end
    local age = now - st.menuSeenMs
    local due = ({ 0, 500, 2000 })[st.menuProbes + 1]
    if due and age >= due then
        st.menuProbes = st.menuProbes + 1
        U.try(TAG, probe, st, w, string.format("+%dms", math.floor(age)))
        -- VERIFY(V-PAU-06): at +2000ms every listed part reads 1.00 and BB_Background blur 10.0.
        U.try(TAG, function()
            U.log(TAG, "pause menu parts +%dms%s: %s", math.floor(age), st.menuRehosted and " (after rehost)" or "",
                partsLine(menuParts(st, w)))
        end)
    end
    -- only the ACTIVE pause screen is ours to show: a deactivated one is hidden on purpose (Settings, photo mode on top)
    local active = true
    pcall(function() active = w:IsActivated() ~= false end)
    if not active then
        st.rehostPending = false
        return
    end
    if opt("PauseMenuFix", true) then
        local n = forceVisible(w)
        if n > 0 then U.logEvery("pause.vis", 2000, TAG, "pause menu: %d hidden/transparent level(s) made visible", n) end
    end
    -- 0.7.0: only "always" re-adds (A/B tests): "auto" = "never" (the re-added screen took no input in run H, and the
    -- UIManager already shows its layer screens on the whole viewport)
    local want = opt("PauseMenuRehost", "never") == "always"
    st.rehostPending = want and not st.menuRehosted and not st.rehostBroken
    if st.rehostPending and age >= opt("PauseMenuRehostDelayMs", 50) then
        st.menuRehosted, st.rehostPending = true, false
        U.try(TAG, rehost, st, w)
        st.menuProbes = 1                                      -- probe again at +0.5 s / +2 s after the rehost
        st.menuSeenMs, st.menuSettled = now, false
        return
    end
    if not st.rehostPending then U.try(TAG, focusTick, st, w, now) end
    -- settle: once per instance (after the rehost when one is due), the intro animation's end values
    -- (deferred while a menu key was pressed < 600 ms ago: Resume's own fade-out must not be undone)
    local recentPress = st.lastMenuPressMs and now - st.lastMenuPressMs < 600
    if not st.rehostPending and not st.menuSettled and not recentPress and opt("PauseMenuSettle", true)
        and age >= opt("PauseMenuSettleMs", 1500) then
        st.menuSettled = true
        U.try(TAG, function()
            local fixed = settleParts(st, w)
            if #fixed > 0 then
                U.warn(TAG, "pause menu settled %.0f ms after %s: %d part(s) below their intro-animation end value "
                    .. "restored: %s", age, st.menuRehosted and "the rehost" or "first sight", #fixed,
                    table.concat(fixed, ", "))
            else
                U.log(TAG, "pause menu settled: every part at its intro-animation end value (nothing to restore)")
            end
        end)
    end
end

---------------------------------------------------------------------------------------------------- presses
-- Pause-key (Start; P1 also Escape/P) and player-key (View; P1 also Tab/O) down EDGES of every local player, with a
-- sequence number: the pauser at the pause edge, F3 (any Start resumes), G (a press restarts the pause CSM) and the
-- request hook's fallback. keyState also tells A2 when every key is up again. Review 0.5.0: while paused after a
-- rehost, the menu keys (A / B / Enter) are tracked too (st.lastMenuPressMs: "the player resumed, not the rehost").
local MENU_KEYS = { "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Enter" }
local menuKeyStructs = nil
local function trackPresses(st, now, pausedNow)
    keys()
    st.keyState = st.keyState or {}
    st.anyMenu = st.anyMenu or {}
    if pausedNow == true and not menuKeyStructs then
        menuKeyStructs = {}
        for i, n in ipairs(MENU_KEYS) do menuKeyStructs[i] = { KeyName = U.fname(n) } end
    end
    local seen = {}
    for _, lp in ipairs(U.localPlayers()) do
        if U.ok(lp.pc) then
            local k = U.key(lp.pc)
            seen[k] = true
            local ks = st.keyState[k]
            if not ks then ks = {}; st.keyState[k] = ks end
            local pk, ppad = pauseKeyOf(lp)
            local vk, vpad = playerKeyOf(lp)
            if pk and not ks.pause then
                st.pressSeq = (st.pressSeq or 0) + 1
                st.lastPausePress = { pc = lp.pc, atMs = now, pnum = lp.index, key = pk, pad = ppad, seq = st.pressSeq }
                st.lastPress = st.lastPausePress
            end
            if vk and not ks.player then
                st.pressSeq = (st.pressSeq or 0) + 1
                st.lastPlayerPress = { pc = lp.pc, atMs = now, pnum = lp.index, key = vk, pad = vpad,
                    seq = st.pressSeq }
                st.lastPress = st.lastPlayerPress
            end
            ks.pause, ks.player = pk ~= nil, vk ~= nil
            if pausedNow == true and st.rehostedAtMs then
                local m = false
                for _, kst in ipairs(menuKeyStructs) do
                    if keyDown(lp.pc, kst) then m = true; break end
                end
                if m and not st.anyMenu[k] then st.lastMenuPressMs = now end
                st.anyMenu[k] = m
            end
        end
    end
    for k in pairs(st.keyState) do
        if not seen[k] then st.keyState[k] = nil end
    end
end

---------------------------------------------------------------------------------------------------- G tick
-- FAST while a split race is RACING and not paused. The pause CSM counts as gone only while the race CSM's
-- InProgress / Countdown states (the only ones that run it) are known inactive: never during the intro.
local function wreckTick(st, now, pausedNow)
    local mode = opt("PauseRestartCsm", "onpress")
    if mode == "off" or St.phase ~= "RACING" or pausedNow == true or not St.race.started then return end
    if now - (st.gMs or -1e12) >= 500 then
        st.gMs = now
        local sm = currentPauseSm()
        if sm then
            if st.ownCsm and U.ok(st.ownCsm) and U.key(sm) ~= st.ownCsmKey then
                endOwnCsm(st, "the game runs its own pause CSM again")
            end
            st.smGone, st.smGoneLogged = false, false
        else
            st.smGone = U.csmPoll("CSM_RFInProgress") == false and U.csmPoll("CSM_RFCountdown") ~= true
            if st.smGone and not st.smGoneLogged then
                st.smGoneLogged = true
                local n, who = humansRacing()
                U.log(TAG, "pause CSM gone (the race CSM left CSM_RF_InProgress: P1 wrecked or finished); still "
                    .. "racing: %s; PauseRestartCsm %s (V-PAU-16)", n > 0 and who or "nobody", mode)
            end
        end
        if st.smGone and mode == "eager" and not st.eagerDone then
            st.eagerDone = true
            restartPauseCsm(st, "eager")
        end
    end
    if not st.smGone then return end
    local e = st.lastPausePress
    if not e or e.seq == st.gSeq or now - e.atMs > 300 then return end
    st.gSeq = e.seq
    if e.pnum == 1 and U.csmActive("CSM_LocalResults", true) == true then
        U.dbg(TAG, "P1 %s on its results (LocalResults): no pause", tostring(e.key))
        return
    end
    local ok, why = restartPauseCsm(st, "P" .. tostring(e.pnum) .. " " .. tostring(e.key))
    if ok then
        U.try(TAG, M.openPauseMenu, e.pc, "pause", e.pad)
        st.gOpenedAtMs = now                           -- M.poll re-reads the pause state of this tick
    else
        U.log(TAG, "P%s %s with no pause CSM: not restarted (%s) (V-PAU-16)", tostring(e.pnum), tostring(e.key),
            tostring(why))
    end
end

---------------------------------------------------------------------------------------------------- arming
-- Once per split race: the dialog containers + the Menu-layer Z, the IMC_UI priorities, the menu classes in memory
-- (the pre-create never loads a class from the hook), and a hot-reload leftover of a guest's IMC_UI boost normalised.
local function prepare(st)
    st.prepared = true
    containers(true)
    prepareZ()
    local act, def = imcPrios()
    local loadedTxt = {}
    for _, leaf in ipairs({ pickLeaf() or "Paused_Racing", "PlayerMenu" }) do
        local path = LEAF_CLASS[leaf]
        local inMem = loaded(path) ~= nil
        -- LoadAsset fallback, once per race (PRERACE): the hook never loads a class
        if not inMem and opt("PauseMenuPrecreate", true) then inMem = U.ok(U.class(path)) end
        loadedTxt[#loadedTxt + 1] = shortCls(path) .. (inMem and "" or " (not loaded)")
    end
    if M.isPaused() ~= true then imcRestore(st, "arm") end
    -- 0.7.2: sub-screen classes are find-only (the pause CSM's states hold them; never LoadAsset WBP_Settings here)
    local subTxt = {}
    for _, path in ipairs({ SUB_CLASS.Settings, SUB_CLASS.Stickerbook }) do
        subTxt[#subTxt + 1] = shortCls(path) .. (loaded(path) and "" or " (not in memory yet)")
    end
    U.log(TAG, "split race (%d local players): A=%s B=%s C=%s D=%s E=%s F=%s G=%s; owner %s, pad shift %s; "
        .. "IMC_UI %d/%d; dialog containers %d; classes %s; 0.7.2 B2=%s C2=%s D2=%s, sub-screens %s (V-PAU-09..22)",
        localPCCount(), tostring(opt("PauseHudInputGuard", true)), tostring(opt("PauseCsmHook", true)),
        tostring(precreateOn()), opt("PauseUiImcBoost", "all"), tostring(opt("PauseMenuFocusOwner", true)), lostMode(),
        opt("PauseRestartCsm", "onpress"), opt("PauseMenuOwner", "pauser"), opt("PauseOwnerPadShift", "auto"), act,
        def, #(cont.list or {}), table.concat(loadedTxt, ", "), tostring(opt("PauseSubScreenHook", false)),
        tostring(opt("PauseSubScreenPrecreate", true)), opt("PauseDialogGuestUi", "lower"), table.concat(subTxt, ", "))
end

-- FAST: true while a split race runs (PRERACE/RACING, >= 2 local PCs); arms the hook there, disarms it elsewhere.
local function armTick(st, now)
    local H = HK()
    local split = (St.phase == "PRERACE" or St.phase == "RACING") and localPCCount() >= 2
    if not split then
        if H.armed then
            H.armed = false
            U.log(TAG, "pause hook disarmed (phase %s, %d local players)", tostring(St.phase), localPCCount())
        end
        return false
    end
    if not st.prepared then U.try(TAG, prepare, st) end
    if not opt("PauseCsmHook", true) then
        H.armed = false
        return true
    end
    -- 0.7.2: B2 (ChangeToState) is registered beside B only with cfg.PauseSubScreenHook = true (opt-in since 0.8.0)
    local wantCts = opt("PauseSubScreenHook", false)
    if (not H.ids[HOOK_CSM] or (wantCts and not H.ids[HOOK_CTS])) and now - (st.hookTryMs or -1e12) >= 1000 then
        st.hookTryMs = now
        ensureHook(st, HOOK_CSM)
        if wantCts then ensureHook(st, HOOK_CTS) end
    end
    H.on[HOOK_CSM] = hookHandler
    H.on[HOOK_CTS] = ctsHandler
    if H.ids[HOOK_CSM] and H.armed ~= true then
        H.armed = true
        U.log(TAG, "pause hook armed (split race, %d local players; ChangeToState hook %s) (V-PAU-11/20)",
            localPCCount(), H.ids[HOOK_CTS] and "on" or (wantCts and "not registered" or "off"))
    end
    return true
end

-- FAST while paused in a split race: A2 for a HUD hud.lua created during the pause; D off while the photo mode runs
-- (the photo pawns take the pads), back on afterwards.
local function pausedSplitTick(st)
    hudInputsOff(st, "paused")
    local okP, ph = pcall(U.mod, "phase")
    local photo = okP and type(ph) == "table" and ph.photoMode and ph.photoMode() == true
    if photo and st.imcBoosted then
        imcRestore(st, "photo mode")
        st.imcPhoto = true
    elseif not photo and st.imcPhoto then
        st.imcPhoto = false
        imcBoost(st, st.lastOwner, "photo mode closed")
    end
    if photo then return end
    -- 0.7.2 (D2): a confirm dialog is a P1-owned persistent container's message; the pause controller answers it
    -- through menubridge. Meanwhile a guest's own pause screen under it would also take that guest's A (its EXIT entry
    -- again: a second dialog) and B (OnCancelAction: resume): the guests' IMC_UI goes back to its default until the
    -- dialog closes (their raw keys still reach IsInputKeyDown). cfg.PauseDialogGuestUi "lower" (default) | "keep".
    -- VERIFY(V-PAU-21)
    if opt("PauseDialogGuestUi", "lower") ~= "lower" then return end
    local dlg, what = dialogUp()
    if dlg then
        if st.imcBoosted then                              -- also a boost made meanwhile (a new menu instance)
            st.imcDialog = true
            imcRestore(st, "confirm dialog " .. tostring(what) .. " up")
        end
    elseif st.imcDialog then
        st.imcDialog = false
        imcBoost(st, st.lastOwner, "confirm dialog closed")
    end
end

-- FAST after a pause (not paused): A2 back on, the pre-created screen's leftovers, and once 1 s after the resume P1's
-- IMC_UI (the game's own InputModeManager must have dropped it: nothing is left in the Menu layer).
local function afterPause(st, now)
    hudInputsBack(st, now)
    preAfter(st, now)
    orphansAfter(st, now)                                -- 0.7.2: retired screens that kept our reference
    if st.p1ImcChecked or not st.resumedAtMs or now - st.resumedAtMs < 1000 then return end
    st.p1ImcChecked = true
    if localPCCount() < 2 then return end
    local imc, sub = loaded(IMC_UI_PATH), eiSub(U.p1())
    if not (imc and sub) then return end
    local has, p = eiHas(sub, imc)
    local act = imcPrios()
    if has == true and p == act and tonumber(layerCount(MENU)) == 0 then
        U.warn(TAG, "P1's IMC_UI still at %d with no Menu-layer screen 1 s after resume: input mode refresh %s "
            .. "(V-PAU-10)", act, refreshInputMode())
    end
end

-- Review 0.7.0: a request (or pick) that no pause followed: the CSM ignored it, the race CSM left Countdown /
-- InProgress in that frame, or the pause state is unreadable. A2, C and D were applied inside the hook and are
-- otherwise undone only after a resume edge: the pre-created screen would stay over the running race (and in the Menu
-- layer), no hosted HUD would get its pause binding back (nobody could pause) and the guests' IMC_UI would stay at 500
-- (their pad keys feeding UI actions). REQ_NO_PAUSE_MS after such a request: screen removed, IMC_UI restored, and the
-- HUD inputs come back through hudInputsBack (PauseInputsBackMs after this, once every pause key is up).
-- VERIFY(V-PAU-11): never seen in a normal run; when it shows, the race goes on with a clean screen and pausing works.
local REQ_NO_PAUSE_MS = 600
local function requestWatch(st, now, pausedNow)
    local t = st.reqAtMs
    if not t then return end
    if pausedNow == true or (st.pausedAtMs and st.pausedAtMs >= t) then st.reqAtMs = nil; return end
    if now - t < REQ_NO_PAUSE_MS then return end
    st.reqAtMs = nil
    st.reqNoPause = (st.reqNoPause or 0) + 1
    local pre, preTxt = st.pre, "none"
    if pre and not pre.acquired then
        preTxt = shortCls(pre.path) .. " removed"
        dropPre(st, "no pause followed the request")
    end
    local imc = imcRestore(st, "request without pause")
    local off = 0
    for _ in pairs(st.hudOff or {}) do off = off + 1 end
    st.resumedAtMs, st.p1ImcChecked = now, false
    U.warn(TAG, "request %d ms ago without a pause (paused=%s, states [%s]): pre-created screen %s; IMC_UI %s; %d HUD "
        .. "input(s) back once every pause key is up (V-PAU-11)", math.floor(now - t), tostring(pausedNow),
        (activeSubStates()), preTxt, tostring(imc), off)
end

---------------------------------------------------------------------------------------------------- poll
-- FAST loop, every race tick (main.lua calls it whenever phase.isRace()).
function M.poll()
    keys()
    local guestsPoll = (cfg.GuestPauseMode == "poll") or guestFallbackOn()
    local p1 = p1PollActive()
    local st = P()
    st.pending = st.pending or {}
    local pausedNow = M.isPaused()
    local now = St.nowMs()
    U.tryEvery("pause.track", nil, TAG, trackPresses, st, now, pausedNow)
    local okA, split = U.tryEvery("pause.arm", nil, TAG, armTick, st, now)
    split = okA and split == true
    if split then
        U.tryEvery("pause.guard", nil, TAG, guardGameHud, st, now)
        U.tryEvery("pause.wreck", nil, TAG, wreckTick, st, now, pausedNow)
        if st.gOpenedAtMs == now then pausedNow = M.isPaused() end -- G paused inside this tick
    end
    if pausedNow == true and st.menuWasPaused ~= true then
        st.pausedAtMs = now
        st.repairs, st.noLeafSince, st.noScreenSince, st.f3, st.leafNow, st.leafSinceMs = 0, nil, nil, nil, nil, nil
        local lp = st.lastPress
        if not (st.pauserAtMs and now - st.pauserAtMs < 1500) then
            if lp and now - lp.atMs < 1500 then notePauser(lp.pc, "P" .. lp.pnum .. " " .. tostring(lp.key))
            else notePauser(nil, "unknown: the menu keeps its owner") end
        end
        U.log(TAG, "game paused by %s (%s)", pnumDesc(st.pauser), tostring(st.pauserWhy))
        -- backups when the request hook did not run (hook off / failed / missed): A2 and D on the pause edge
        if split then
            U.tryEvery("pause.edgeoff", nil, TAG, hudInputsOff, st, "pause edge")
            if not st.imcBoosted then
                U.tryEvery("pause.edgeimc", nil, TAG, imcBoost, st, st.pre and st.pre.owner or nil, "pause edge")
            end
        end
        -- run F (f-11.png): our per-player HUDs are hidden on the pause edge itself, not on the next MAIN tick.
        -- VERIFY(V-PAU-06): the first "pause menu probe +0ms" line already shows ourHUDs=[P1:v1,P2:v1].
        if opt("PauseHideHudsAtOnce", true) then
            U.try(TAG, function()
                local hud = U.mod("hud")
                if type(hud) == "table" and type(hud.updateVisibility) == "function" then hud.updateVisibility() end
            end)
        end
    elseif pausedNow == false and st.menuWasPaused == true then
        st.resumedAtMs, st.p1ImcChecked = now, false
        st.imcDialog, st.subKey = false, nil                 -- 0.7.2: D2 / E2 end with the pause
        local r = "-"
        if split or st.imcBoosted then
            local okR, rr = U.tryEvery("pause.resumeimc", nil, TAG, imcRestore, st, "resume")
            r = okR and tostring(rr) or "restore failed"
        end
        U.log(TAG, "pause over (states [%s]); IMC_UI %s (V-PAU-10)", (activeSubStates()), r)
    end
    if pausedNow ~= nil then st.menuWasPaused = (pausedNow == true) end
    -- review 0.7.0: a request no pause followed is undone (requestWatch: cleared as soon as this tick is paused)
    if st.reqAtMs then U.tryEvery("pause.req", nil, TAG, requestWatch, st, now, pausedNow) end
    if pausedNow == true then
        U.tryEvery("pause.pre", nil, TAG, preTick, st, now)
        U.tryEvery("pause.safety", nil, TAG, safetyTick, st, now)
        if split then U.tryEvery("pause.split", nil, TAG, pausedSplitTick, st) end
    elseif pausedNow == false then
        U.tryEvery("pause.after", nil, TAG, afterPause, st, now)
    else
        -- review 0.7.0: state unreadable: HUD inputs turned off by an undone request still come back (hudInputsBack
        -- acts only after a resume edge or an undone request, never during a pause it saw starting)
        U.tryEvery("pause.back", nil, TAG, hudInputsBack, st, now)
    end
    U.tryEvery("pause.menu", nil, TAG, menuTick, st, pausedNow, now)
    if not guestsPoll and not p1 then
        st.pending = {}
        return
    end
    -- quiet = not paused now and not at the previous poll (an unknown state, nil, counts as not paused, like
    -- openPauseMenu's own check)
    local quiet = (pausedNow ~= true) and (st.lastPaused ~= true)
    st.lastPaused = pausedNow
    -- deferred presses: the game paused by itself (the HUD's own binding) -> dropped; still not paused -> act once
    if pausedNow == true then
        st.pending = {}
    else
        for k, pr in pairs(st.pending) do
            if now - pr.atMs >= deferMs() then
                st.pending[k] = nil
                if U.ok(pr.pc) then
                    U.dbg(TAG, "%s press not handled by the game within %d ms: pausing from the poll",
                        pr.isP1 and "P1" or "guest", deferMs())
                    U.try(TAG, M.openPauseMenu, pr.pc, "pause", pr.pad)
                end
                break   -- one pause per poll; the others are dropped by the next poll (paused by then)
            end
        end
    end
    local seen = {}
    -- Guests that may pause: joined (join.joinedList: valid PC, slot.joined) and still driving their own car. A
    -- single-view race (St.race.singleView: guests handed to the AI) polls no guest at all.
    local mayPause = nil
    if guestsPoll then
        mayPause = {}
        if St.race.singleView ~= true then
            U.tryEvery("pause.guests", nil, TAG, function()
                local join = U.mod("join")
                for _, e in ipairs(join.joinedList()) do         -- Lua table
                    local s = St.join.slots[e.ctrlId]
                    if s and not (s.leaving or s.abandoned or s.abandonPending) and U.ok(e.pc) then
                        mayPause[U.key(e.pc)] = true
                    end
                end
            end)
        end
    end
    for _, lp in ipairs(U.localPlayers()) do
        local pc = lp.pc
        local isP1 = (lp.index == 1)
        if U.ok(pc) and ((isP1 and p1) or (not isP1 and guestsPoll and mayPause[U.key(pc)] == true)) then
            local k = U.key(pc)
            seen[k] = true
            U.tryEvery("pause.poll", nil, TAG, function()
                local down = pc:IsInputKeyDown(KEY_START) == true
                local pad = down
                -- VERIFY(V-PAU-03): P1's keyboard pause key is Escape (IsInputKeyDown on P1's PC sees it).
                if isP1 and not down then down = pc:IsInputKeyDown(KEY_ESC) == true end
                if down and not st.prevStart[k] and quiet then
                    local may, why = true, nil
                    if isP1 then may, why = p1MayPause() end
                    if may then
                        st.pending[k] = { pc = pc, atMs = now, isP1 = isP1, pad = pad }
                    else
                        U.dbg(TAG, "P1 pause press ignored: %s", tostring(why))
                    end
                end
                st.prevStart[k] = down
            end)
        end
    end
    for k in pairs(st.prevStart) do
        if not seen[k] then st.prevStart[k] = nil end
    end
    for k in pairs(st.pending) do
        if not seen[k] then st.pending[k] = nil end
    end
end

---------------------------------------------------------------------------------------------------- exports (0.7.2)
-- For menubridge.lua. The pause controller = the PC the pause screens are created for (ownerFor(pauser); with
-- PauseMenuOwner "game": the pause screen's owner); nil while not paused.
function M.controller()
    if M.isPaused() ~= true then return nil end
    local st = P()
    local o, why = ownerFor(U.ok(st.pauser) and st.pauser or nil, st.pauserViaPad)
    if why == "game" then o = st.lastOwner end
    return U.ok(o) and o or nil
end

-- true while that guest's UI input reaches its own screens natively: its IMC_UI is boosted (D) and no confirm dialog
-- lowered it (D2). Run I: a guest's own pre-created pause screen took the guest's A/B/Start natively then.
function M.guestUiNative(pc)
    local st = P()
    if M.isPaused() ~= true or not st.imcBoosted or st.imcDialog then return false end
    local rec = st.imc and st.imc[U.key(pc)]
    return rec ~= nil and rec.boosted == true
end

-- The confirm dialog on screen (newest message of a persistent Dialog / SystemDialog / MenuOverlay container) and
-- "Dialog:1"; nil when none. The containers are resolved per split race (prepare).
function M.dialogWidget()
    return dialogTop()
end

-- Diagnostics (diag.lua may print it): hook state and the pause layers' live records.
function M.status()
    local H = HK()
    local st = P()
    local hudOff = 0
    for _ in pairs(st.hudOff or {}) do hudOff = hudOff + 1 end
    return { armed = H.armed == true, hook = H.ids[HOOK_CSM] ~= nil, hookCalls = st.hookCalls or 0,
             requests = st.reqCount or 0, noPause = st.reqNoPause or 0, pre = st.pre and shortCls(st.pre.path) or nil,
             preAcquired = st.pre and st.pre.acquired == true or false, imcBoosted = st.imcBoosted == true,
             hudInputsOff = hudOff, ownCsm = U.ok(st.ownCsm), pauser = pnumDesc(st.pauser), zSeen = zSeen,
             zAuto = zAuto, dialogs = #(cont.list or {}),
             ctsHook = H.ids[HOOK_CTS] ~= nil, ctsCalls = st.ctsCalls or 0, subRequests = st.subReqs or 0,
             subScreen = st.subKey ~= nil, imcDialog = st.imcDialog == true }
end

-- Per-race fields (St.pause) dropped outside the race phases; St.pause.pressSeq keeps counting.
local RACE_FIELDS = { "lastPaused", "lastPress", "lastPausePress", "lastPlayerPress", "pauser", "pauserWhy",
    "pauserAtMs", "pauserViaPad", "menuKey", "menuW", "rehostedAtMs", "lastMenuPressMs", "menuWasPaused", "menuParts",
    "noMenuLogged", "lastOwner", "pre", "ownCall", "dupAtMs", "pausedAtMs", "resumedAtMs", "p1ImcChecked", "repairs",
    "noLeafSince", "noScreenSince", "f3", "f3Seq", "leafNow", "leafSinceMs", "focusKey", "focusFixes", "focusGaveUp",
    "smGone", "smGoneLogged", "eagerDone", "gSeq", "ownCsm", "ownCsmKey", "prepared", "hookFailed", "a1Logged",
    "imcPhoto", "imcBoosted", "reqCount", "hookCalls", "gOpenedAtMs", "hudOffAtMs", "reqAtMs", "reqNoPause",
    "subKey", "subSeenMs", "subProbes", "subFocusDone", "subReqs", "subAtMs", "ctsCalls", "imcDialog", "orphans" }

function M.init()
    P()
    HK().on[HOOK_CSM] = hookHandler
    HK().on[HOOK_CTS] = ctsHandler
    -- "leaving" (LoadMap pre / seamless / return to menus / poll): disarm before the world goes; the own pause CSM
    -- ends, guests' IMC_UI back to normal, the hook marked for removal (never registered across a travel).
    St.on("leaving", TAG, function(reason)
        local st = P()
        HK().armed = false
        U.try(TAG, endOwnCsm, st, "leaving (" .. tostring(reason) .. ")")
        U.try(TAG, imcRestore, st, "leaving")
        U.try(TAG, dropHook, "leaving (" .. tostring(reason) .. ")")
    end)
    St.on("phase", TAG, function(new)
        local st = P()
        if new ~= "PRERACE" and new ~= "RACING" then
            HK().armed = false
            if st.ownCsm then U.try(TAG, endOwnCsm, st, "phase " .. tostring(new)) end
            if new ~= "LEAVING" then U.try(TAG, dropHook, "phase " .. tostring(new)) end
        end
        if new == "FRONTEND" then U.try(TAG, imcRestore, st, "front end") end
        if new ~= "PRERACE" and new ~= "RACING" and new ~= "POSTRACE" then
            for _, f in ipairs(RACE_FIELDS) do st[f] = nil end
            st.prevStart, st.pending, st.anyMenu, st.keyState, st.hudOff, st.imc = {}, {}, {}, {}, {}, {}
            st.rehostPending, st.menuSettled = false, false
        end
    end)
    -- VERIFY(V-PAU-01): in "hud" mode the guest HUD's IA_Veh_Pause binding reaches the guest PC.
    U.log(TAG, "init 0.7.2: phase 2 PauseSubScreenPrecreate=%s PauseSubScreenHook=%s PauseDialogGuestUi=%s "
        .. "(V-PAU-19..22)", tostring(opt("PauseSubScreenPrecreate", true)), tostring(opt("PauseSubScreenHook", false)),
        opt("PauseDialogGuestUi", "lower"))
    U.log(TAG, "init 0.7.0: GuestPauseMode=%s (poll fallback %s, defer %d ms), P1PausePoll=%s; split-race layers: "
        .. "PauseHudInputGuard=%s PauseCsmHook=%s (read state %s, trace %s) PauseMenuPrecreate=%s PauseMenuOwner=%s "
        .. "PauseOwnerPadShift=%s PauseMenuZ=%s PauseUiImcBoost=%s PauseMenuFocusOwner=%s PauseLostMenu=%s (no "
        .. "sub-state %s ms, no screen %s ms) PauseAnyStartResumes=%s PauseRestartCsm=%s; 0.6.0: PauseMenuRehost=%s%s "
        .. "PauseMenuFix=%s PauseMenuSettle=%s (%s ms) PauseHideHudsAtOnce=%s", tostring(cfg.GuestPauseMode),
        tostring(guestFallbackOn()), deferMs(), tostring(cfg.P1PausePoll), tostring(opt("PauseHudInputGuard", true)),
        tostring(opt("PauseCsmHook", true)), tostring(opt("PauseHookReadState", true)),
        tostring(opt("PauseHookTrace", false)), tostring(opt("PauseMenuPrecreate", true)),
        opt("PauseMenuOwner", "pauser"), opt("PauseOwnerPadShift", "auto"), tostring(cfg.PauseMenuZ or "auto"),
        opt("PauseUiImcBoost", "all"), tostring(opt("PauseMenuFocusOwner", true)), lostMode(),
        tostring(opt("PauseNoSubStateMs", 150)), tostring(opt("PauseLostMenuMs", 1500)),
        opt("PauseAnyStartResumes", "fallback"), opt("PauseRestartCsm", "onpress"), opt("PauseMenuRehost", "never"),
        opt("PauseMenuRehost", "never") == "always" and " (A/B: re-adds the CSM's screen)" or " (= never)",
        tostring(opt("PauseMenuFix", true)), tostring(opt("PauseMenuSettle", true)), opt("PauseMenuSettleMs", 1500),
        tostring(opt("PauseHideHudsAtOnce", true)))
end

return M
