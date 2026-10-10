-- SWGRCouch · feowner.lua (0.10.0): the front-end main menu belongs to P1, also after a split race.
--
-- Why (notes/research/menu-owner.md): every screen the UIManager creates gets as owner the LAST local PlayerController
-- of UWorld::PlayerControllerList (native helper 0x14d28b91a, hotfix 0x14d271957; nothing stores it, no UFunction on the
-- path). Guests are kept for the whole session, and the return to L_FrontEnd after a race is a seamless travel that
-- carries their PCs: the front-end state machine then builds WBP_FE_MainMenu_C for the last guest. P2 drives the main
-- menu, P1's pad does nothing (its CommonUI router is in UI mode with no screen), the tab glyphs show keyboard keys.
-- The UIManager REUSES a widget of the requested class that already sits in the layer (acquire, WaitUntilLayerIsEmpty
-- false), the same path pause.lua's pre-create uses live. So the menu is created for P1 right before the CSM shows it:
--   c1  /Script/Griffin.CampaignSubsystem:GetMainMenuShouldOpenScenarios pre-hook: BP_Csm_FrontEnd_PickPrimaryMode
--       calls it right before ChangeToState(PrimaryModeSelect_Menu | _Scenarios), on every entry into
--       CSM_FrontEnd_PrimaryModeSelect, including the arrival after a race (no phase gate: St.phase is TRANSIT then).
--   c3  in FRONTEND: CosmeticStateMachine:ChangeStateTo pre-hook with a main-menu leaf as target (the Settings return
--       goes through BP_Csm_FrontEnd_ReturnFromSubmenus.OnStop -> ChangeStateTo(cached tab)) or a front-end sub-screen
--       state (Settings and its pages, Credits, Stickerbook, arcade / scenario inspect: SUB_ENTER), and the Back calls
--       of those sub-screens (FuseScreenWidget / CosmeticStateMachine:BackToPreviousState: BACK_TARGET). Live
--       2026-10-09: without it Settings opened from P1's main menu belonged to P2, and P1's B could not leave it.
--   g   the Multiplayer tab (its state shows the menu with WaitUntilLayerIsEmpty = true, which no pre-create can feed)
--       is hidden and disabled while split-screen guests exist; online play with guests is unsupported anyway.
-- Recipe: WidgetBlueprintLibrary:Create(P1) -> AddToViewport(Menu z) -> UIManager:AddExistingWidgetToLayer(Menu)
-- (refcount 1). The CSM's ShowWidget acquires it (refcount 2, OwningStateMachine set); the FAST tick then drops our
-- reference (RemoveWidget: 2 -> 1) and asks the InputModeManager to re-evaluate. Not acquired within 1500 ms: removed.
-- Never GetWidgetInLayer (crash, research §1.7): no main-menu state uses ForceNewInstance, so ours is the only
-- WBP_FE_MainMenu_C entry while it exists and RemoveWidget(class, Menu) only touches it.
-- The race results screens are not covered (WaitUntilLayerIsEmpty = true); menubridge keeps bridging them.
-- cfg.FrontEndMenuOwner = "game" is the kill switch.  VERIFY(V-FEO-01..12)
local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "feowner"

local MENU = C.E.UILayer.Menu                                  -- 2
local HOOK_PICK = "/Script/Griffin.CampaignSubsystem:GetMainMenuShouldOpenScenarios"
local HOOK_CST = "/Script/Griffin.CosmeticStateMachine:ChangeStateTo"
local HOOK_SM_BACK = "/Script/Griffin.CosmeticStateMachine:BackToPreviousState"
local HOOK_SCREEN_BACK = "/Script/Griffin.FuseScreenWidget:BackToPreviousState"
-- The main-menu leaves that show WBP_FE_MainMenu_C with WaitUntilLayerIsEmpty = false (research §3.1).
local MENU_LEAVES = {
    CSM_FrontEnd_PrimaryModeSelect_Menu = true, CSM_FrontEnd_PrimaryModeSelect_Recommended = true,
    CSM_FrontEnd_PrimaryModeSelect_Scenarios = true, CSM_FrontEnd_PrimaryModeSelect_Arcade = true,
}
-- Front-end sub-screen states (decoded CSM_FrontEnd_* StateActions, hotfix paks 2026-10-09): every one shows its
-- screen with WaitUntilLayerIsEmpty = false and ForceNewInstance = false, so a P1 instance pre-created right before the
-- ChangeStateTo is acquired like the main menu. Without it Settings & co. belong to the last guest (P1 cannot leave
-- them).  VERIFY(V-FEO-13)
local SETTINGS = "/Game/Griffin/UI/Screens/Settings/WBP_Settings.WBP_Settings_C"
local SUB_ENTER = {
    CSM_FrontEnd_Settings = SETTINGS,
    CSM_FrontEnd_Credits = "/Game/Griffin/UI/Screens/WBP_Credits.WBP_Credits_C",
    CSM_FrontEnd_StickerBook = "/Game/Griffin/UI/Screens/Stickerbook/WBP_FE_Stickerbook.WBP_FE_Stickerbook_C",
    CSM_FrontEnd_ArcadeInspect =
        "/Game/Griffin/UI/Screens/MainMenu/WBP_Arcade_InspectWrapper.WBP_Arcade_InspectWrapper_C",
    CSM_FrontEnd_ScenarioInspect =
        "/Game/Griffin/UI/Screens/MainMenu/WBP_Scenario_InspectEvent.WBP_Scenario_InspectEvent_C",
    CSM_Frontend_Settings_BrightnessCalibration =
        "/Game/Griffin/UI/Screens/Settings/WBP_BrightnessCalibration.WBP_BrightnessCalibration_C",
    CSM_Frontend_Settings_GammaCorrection = "/Game/Griffin/UI/Screens/Settings/WBP_GammaCorrection.WBP_GammaCorrection_C",
    CSM_FrontEnd_Settings_ViewControls = "/Game/Griffin/UI/Screens/Settings/WBP_ControllerDiagram.WBP_ControllerDiagram_C",
    CSM_FrontEnd_Settings_ViewCredits = "/Game/Griffin/UI/Screens/WBP_Credits.WBP_Credits_C",
    CSM_FrontEnd_Settings_ViewEULA = "/Game/Griffin/UI/Screens/Startup/WBP_EULAFromSettings.WBP_EULAFromSettings_C",
    CSM_FrontEnd_Settings_ViewEULAOffline =
        "/Game/Griffin/UI/Screens/Startup/WBP_EULAOfflineFromSettings.WBP_EULAOfflineFromSettings_C",
    CSM_FrontEnd_Settings_ViewPatchNotes = "/Game/Griffin/UI/Screens/Startup/WBP_PatchNotes.WBP_PatchNotes_C",
    CSM_FrontEnd_Settings_ViewPrivacyPolicy =
        "/Game/Griffin/UI/Screens/Startup/WBP_PrivacyPolicyFromSettings.WBP_PrivacyPolicyFromSettings_C",
    CSM_FrontEnd_Settings_ViewPrivacyPolicyOffline =
        "/Game/Griffin/UI/Screens/Startup/WBP_PrivacyPolicyOfflineFromSettings.WBP_PrivacyPolicyOfflineFromSettings_C",
}
-- Back from a sub-screen: the screen it returns to (decoded BackCosmeticStateName). "menu" = WBP_FE_MainMenu_C.
-- WBP_Credits_C is both the main menu's Credits and Settings > View Credits: decided by the active state.
local BACK_TARGET = {
    WBP_Settings_C = "menu", WBP_FE_Stickerbook_C = "menu", WBP_Credits_C = "menu",
    WBP_Arcade_InspectWrapper_C = "menu", WBP_Scenario_InspectEvent_C = "menu",
    WBP_BrightnessCalibration_C = SETTINGS, WBP_GammaCorrection_C = SETTINGS, WBP_ControllerDiagram_C = SETTINGS,
    WBP_EULAFromSettings_C = SETTINGS, WBP_EULAOfflineFromSettings_C = SETTINGS, WBP_PatchNotes_C = SETTINGS,
    WBP_PrivacyPolicyFromSettings_C = SETTINGS, WBP_PrivacyPolicyOfflineFromSettings_C = SETTINGS,
}
local VIEW_CREDITS = "/Game/Griffin/Gameplay/FrontEnd/StateMachine/CSM_FrontEnd_Settings_ViewCredits"
    .. ".CSM_FrontEnd_Settings_ViewCredits"
local MP_TAB = "MainMenu_Multiplayer"

local S = { pre = nil, loop = nil, hidden = {} }

local function opt(k, d)
    local v = cfg[k]
    if v == nil then return d end
    return v
end

local function pnumOf(pc)
    if not U.ok(pc) then return nil end
    local k = U.key(pc)
    for _, e in ipairs(U.localPlayers()) do
        if U.ok(e.pc) and U.key(e.pc) == k then return e.index end
    end
    return nil
end

local function localPcCount()
    local n = 0
    for _, e in ipairs(U.localPlayers()) do if U.ok(e.pc) then n = n + 1 end end
    return n
end

local function armed()
    return opt("FrontEndMenuOwner", "p1") == "p1" and localPcCount() >= 2
end

local function classOf(path)                      -- re-resolved on each use, never cached across a load (§1.7)
    local ok, c = pcall(StaticFindObject, path or C.BP.MainMenu)
    return (ok and U.ok(c)) and c or nil
end

local function shortName(path) return (tostring(path):match("%.([%w_]+)$")) or tostring(path) end

-- An instance of that screen class is on screen (FindFirstOf takes the short class name).
local function screenInViewport(path)
    if path == C.BP.MainMenu then
        local m = St.menu and St.menu.widget
        if U.ok(m) then
            local ok, v = pcall(function() return m:IsInViewport() end)
            if ok and v == true then return true end
        end
    end
    local okF, w = pcall(FindFirstOf, shortName(path))
    if not (okF and U.ok(w)) then return false end
    local ok, v = pcall(function() return w:IsInViewport() end)
    return ok and v == true
end

local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or ""
end

local function objName(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or ""
end

local function stopLoop()
    if S.loop then sched.cancel(S.loop); S.loop = nil end
end

-- FAST (33 ms) while a pre-created menu is pending.
function M.preTick()
    local pre = S.pre
    if not pre or not U.ok(pre.w) then S.pre = nil; return stopLoop() end
    if St.phase ~= "FRONTEND" then
        if St.nowMs() - pre.atMs > 15000 then          -- a travel that never ends in the front end: give up
            pcall(function() if pre.w:IsInViewport() then pre.w:RemoveFromParent() end end)
            U.warn(TAG, "pre-created main menu (%s) dropped: no front end within 15 s (phase %s) (V-FEO-02)", pre.why,
                tostring(St.phase))
            S.pre = nil; return stopLoop()
        end
        return                                           -- the travel frame is over before anything is released
    end
    local osm
    pcall(function() osm = pre.w.OwningStateMachine end)
    local mgr, cls = U.giSubsystem("UIManager"), classOf(pre.path)
    if U.ok(osm) then
        local okR = U.ok(mgr) and cls ~= nil and pcall(function() mgr:RemoveWidget(cls, MENU) end)   -- 2 -> 1
        local okI = U.ok(mgr) and pcall(function() mgr:GetInputModeManager():OnControlMappingsRebuilt() end)
        local owner
        pcall(function() owner = pre.w:GetOwningPlayer() end)
        local p1 = U.p1()
        local ownerOk = U.ok(owner) and U.ok(p1) and U.key(owner) == U.key(p1)
        U.log(TAG, "pre-created %s (%s) acquired by the front-end CSM after %d ms: extra ref %s; input "
            .. "mode refresh %s (V-FEO-02); owner %s (V-FEO-12)", shortName(pre.path), pre.why,
            math.floor(St.nowMs() - pre.atMs),
            okR and "released" or "kept", okI and "ok" or "failed",
            ownerOk and "P1" or ("NOT P1: P" .. tostring(pnumOf(owner) or "?")))
        S.pre = nil
        return stopLoop()
    end
    if St.nowMs() - pre.atMs > 1500 then
        if U.ok(mgr) and cls then pcall(function() mgr:RemoveWidget(cls, MENU) end) end           -- 1 -> 0
        pcall(function() if pre.w:IsInViewport() then pre.w:RemoveFromParent() end end)
        U.warn(TAG, "pre-created %s not used by the front-end CSM within 1500 ms (%s): removed (V-FEO-02)",
            shortName(pre.path), pre.why)
        S.pre = nil
        return stopLoop()
    end
end

-- Our instance, owned by P1, registered in the Menu layer; the CSM's acquire returns it.
local function precreate(path, why)
    if S.pre then return nil, "a pre-created screen is already pending" end
    local p1, cls, mgr = U.p1(), classOf(path), U.giSubsystem("UIManager")
    if not (U.ok(p1) and cls and U.ok(mgr)) then return nil, "no P1 PC / screen class in memory / UIManager" end
    local w
    local okC, errC = pcall(function() w = U.WBL():Create(p1, cls, p1) end)   -- (WorldContext, Class, OwningPlayer)
    if not (okC and U.ok(w)) then return nil, "Create failed: " .. tostring(errC) end
    local z = math.tointeger(tonumber(opt("FrontEndMenuZ", 500))) or 500
    local okV, errV = pcall(function() w:AddToViewport(z) end)
    if not okV then return nil, "AddToViewport failed: " .. tostring(errV) end
    local okL, errL = pcall(function() mgr:AddExistingWidgetToLayer(w, MENU) end)
    if not okL then
        pcall(function() w:RemoveFromParent() end)
        return nil, "AddExistingWidgetToLayer failed: " .. tostring(errL)
    end
    S.pre = { w = w, key = U.key(w), atMs = St.nowMs(), why = why, z = z, path = path }
    if not S.loop then S.loop = sched.every("feowner.pre", 33, M.preTick) end
    return w, z
end

local function tryPrecreate(path, why, vid)
    if S.pre then return end
    path = path or C.BP.MainMenu
    if screenInViewport(path) then return end         -- a tab switch / re-entry hands the existing instance over
    local w, z = precreate(path, why)
    local p1 = U.p1()
    if w then
        U.log(TAG, "%s: %s pre-created for P1 (pc %s, %d local PCs) z=%s (%s)", why, shortName(path),
            tostring(U.key(p1)), localPcCount(), tostring(z), vid)
    else
        U.warn(TAG, "%s: no pre-create of %s: %s (%s)", why, shortName(path), tostring(z), vid)
    end
end

-- c1: PickPrimaryMode is about to ChangeToState(Menu | Scenarios). No parameter is read.
local function onPickPre()
    if St.launchHold() then return end      -- 0.12.0: the front end is being torn down (state.lua St.launchHold)
    if not armed() or opt("FrontEndMenuPrecreate", true) == false or S.pre then return end
    tryPrecreate(C.BP.MainMenu, "PickPrimaryMode", "V-FEO-01")
end

-- c3: a ChangeStateTo into a main-menu leaf (the return from Settings) or into a front-end sub-screen (Settings,
-- Credits, Stickerbook, inspect screens, Settings pages).
local function onChangeStatePre(ctx, newState)
    if St.phase ~= "FRONTEND" or St.launchHold() or S.pre or not armed() or opt("FrontEndSubScreens", true) == false then return end
    local st
    pcall(function() st = newState:get() end)
    if not U.ok(st) then return end
    local name = objName(st)
    if MENU_LEAVES[name] then return tryPrecreate(C.BP.MainMenu, "ChangeStateTo(" .. name .. ")", "V-FEO-11") end
    if SUB_ENTER[name] then return tryPrecreate(SUB_ENTER[name], "ChangeStateTo(" .. name .. ")", "V-FEO-13") end
end

local function backTarget(cn)
    local t = BACK_TARGET[cn]
    if t == nil then return nil end
    if cn == "WBP_Credits_C" and U.csmActive(VIEW_CREDITS, true) == true then t = SETTINGS end
    return (t == "menu") and C.BP.MainMenu or t
end

-- c3: a sub-screen's Back (FuseScreenWidget version: the screen is the context).
local function onScreenBackPre(ctx)
    if St.phase ~= "FRONTEND" or St.launchHold() or S.pre or not armed() or opt("FrontEndSubScreens", true) == false then return end
    local w
    pcall(function() w = ctx:get() end)
    local cn = U.ok(w) and className(w) or ""
    local target = backTarget(cn)
    if target then tryPrecreate(target, cn .. " Back", "V-FEO-11") end
end

-- c3: CosmeticStateMachine:BackToPreviousState (the context is the state machine): the known sub-screen on screen
-- tells where Back goes.
local function onStateMachineBackPre()
    if St.phase ~= "FRONTEND" or St.launchHold() or S.pre or not armed() or opt("FrontEndSubScreens", true) == false then return end
    for cn in pairs(BACK_TARGET) do
        local ok, w = pcall(FindFirstOf, cn)
        if ok and U.ok(w) then
            local okV, inV = pcall(function() return w:IsInViewport() end)
            if okV and inV == true then
                local target = backTarget(cn)
                if target then return tryPrecreate(target, cn .. " Back (state machine)", "V-FEO-11") end
            end
        end
    end
end

-- g (MAIN loop, FRONTEND): the Multiplayer tab is hidden and disabled while split-screen guests exist.
-- VERIFY(V-FEO-07): LB/RB skip the hidden tab.
function M.mainTick()
    if St.phase ~= "FRONTEND" or opt("FrontEndHideMultiplayer", true) == false then return end
    if opt("FrontEndMenuOwner", "p1") ~= "p1" then return end
    local m = St.menu and St.menu.widget
    if not U.ok(m) then return end
    local guests = localPcCount() >= 2
    local k = U.key(m)
    if guests == (S.hidden[k] == true) then return end
    local tl
    pcall(function() tl = m.WBP_Tab_List end)
    if not U.ok(tl) then return end
    local id = U.fname(MP_TAB)
    local okE = pcall(function() tl:SetTabEnabled(id, not guests) end)
    local okV = pcall(function() tl:SetTabVisibility(id, guests and 1 or 0) end)   -- ESlateVisibility Collapsed / Visible
    S.hidden[k] = guests
    U.log(TAG, "Multiplayer tab %s while %d local player(s) exist: enabled %s, visibility %s (V-FEO-07)",
        guests and "hidden" or "shown again", localPcCount(), okE and "set" or "failed", okV and "set" or "failed")
end

function M.init()
    if opt("FrontEndMenuOwner", "p1") ~= "p1" then
        U.log(TAG, "init: FrontEndMenuOwner = %s (kill switch: the game picks the owner)", tostring(cfg.FrontEndMenuOwner))
        return
    end
    U.hook(HOOK_PICK, { pre = onPickPre }, TAG)
    if opt("FrontEndSubScreens", true) ~= false then
        U.hook(HOOK_CST, { pre = onChangeStatePre }, TAG)
        U.hook(HOOK_SCREEN_BACK, { pre = onScreenBackPre }, TAG)
        U.hook(HOOK_SM_BACK, { pre = onStateMachineBackPre }, TAG)
    end
    St.on("phase", TAG, function(new)
        if new ~= "FRONTEND" then S.hidden = {} end
    end)
    U.log(TAG, "init 0.10.0: main menu owner P1 (pre-create on PickPrimaryMode%s), Multiplayer tab %s with guests, z=%s",
        opt("FrontEndSubScreens", true) ~= false and " + sub-screen returns" or "",
        opt("FrontEndHideMultiplayer", true) ~= false and "hidden" or "kept", tostring(opt("FrontEndMenuZ", 500)))
end

return M
