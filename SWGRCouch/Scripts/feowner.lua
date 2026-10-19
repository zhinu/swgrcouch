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
--   c3b (0.13.3) the ARCADE / SCENARIOS inspect screens are entered with CosmeticStateMachine:ChangeToState (soft
--       target, never read): the payload object (ArcadeEntryVM / ScenarioEntryVM) names the screen. Without it they
--       belonged to the guest and B / A were dead on both pads (Nexus report 2026-10-14).  VERIFY(V-FEO-14)
--   c6  (0.13.3) the return from Settings empties the Menu layer and builds a new menu inside one ChangeStateTo: the
--       guests' LocalPlayer is hidden from the owner helper for that call (see restoreGuests).  VERIFY(V-FEO-17)
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
local HOOK_CTS = "/Script/Griffin.CosmeticStateMachine:ChangeToState"        -- c3b (0.13.3): the inspect screens
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

local S = { pre = nil, loop = nil, hidden = {}, watch = nil, stage = nil, stageLoop = nil, bracket = nil }
local watchStage                                               -- c4, defined below preTick
local restoreGuests                                            -- c6, defined below preTick

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
            local ok, v = pcall(U.callMethod, m, "IsInViewport")
            if ok and v == true then return true end
        end
    end
    -- 0.13.3: every instance, not FindFirstOf: after an inspect screen's Back the old main menu instance stays alive
    -- out of the viewport, and FindFirstOf returned it during the next tab switch: a second menu was pre-created
    -- while the shown one was handed over (live 2026-10-15)
    local okF, list = pcall(FindAllOf, shortName(path))
    if not okF or type(list) ~= "table" then return false end
    for _, w in ipairs(list) do
        if U.ok(w) then
            local ok, v = pcall(U.callMethod, w, "IsInViewport")
            if ok and v == true then return true end
        end
    end
    return false
end

local function className(o)
    if not U.ok(o) then return "" end   -- U.ok FIRST: GetClass on a null wrapper is a native AV (UE4SS.dll+0x2ace67 null+0x10) that pcall cannot catch
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or ""
end

local function objName(o)
    if not U.ok(o) then return "" end         -- GetFName on a null wrapper is a native AV
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or ""
end

local function stopLoop()
    if S.loop then sched.cancel(S.loop); S.loop = nil end
end

-- FAST (33 ms) while a pre-created menu is pending.
local function settle()
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
        if ownerOk then watchStage(pre.w, shortName(pre.path)) end     -- c4: a screen with a native Back
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

function M.preTick()
    if S.bracket then restoreGuests("FAST") end          -- c6: never past the ChangeStateTo call
    return settle()
end

-- c4 (0.13.3): the LOGBOOK (WBP_FE_Stickerbook_C) goes back natively: no UFunction runs before the CSM shows the main
-- menu again (count-only trace of every CosmeticStateMachine / FuseScreenWidget / CommonActivatableWidget / UIManager
-- UFunction, live 2026-10-15), and the main menu instance is destroyed while the LOGBOOK shows, so the return built a
-- new menu for the guest: P1's B out of the LOGBOOK bricked both pads. While such a screen shows and no main menu
-- instance exists, a P1 main menu is STAGED hidden in the Menu layer (Create(P1), AddToViewport, Collapsed,
-- AddExistingWidgetToLayer); the CSM acquires it on the return (proven live), then it is shown with the visibility it
-- had after Create and our extra reference is released (preTick's recipe).  VERIFY(V-FEO-15)
local STAGE_FOR = { WBP_FE_Stickerbook_C = true }

local function stopStageLoop()
    if S.stageLoop then sched.cancel(S.stageLoop); S.stageLoop = nil end
end

local function anyMainMenu()
    local ok, list = pcall(FindAllOf, shortName(C.BP.MainMenu))
    if not ok or type(list) ~= "table" then return false end
    for _, w in ipairs(list) do if U.ok(w) then return true end end
    return false
end

local function unstage(why, removeFromLayer)
    local st = S.stage
    S.stage, S.watch = nil, nil
    stopStageLoop()
    if not (st and U.ok(st.w)) then return end
    local mgr, cls = U.giSubsystem("UIManager"), classOf(C.BP.MainMenu)
    if removeFromLayer and U.ok(mgr) and cls then pcall(function() mgr:RemoveWidget(cls, MENU) end) end
    pcall(function() if st.w:IsInViewport() then st.w:RemoveFromParent() end end)
    U.warn(TAG, "staged P1 main menu not used (%s): removed%s (V-FEO-15)", tostring(why),
        removeFromLayer and "" or " from the viewport only (another menu shows)")
end

function M.stageTick()
    local wt = S.watch
    if not wt then return stopStageLoop() end
    if St.phase ~= "FRONTEND" or St.launchHold() then return unstage("phase " .. tostring(St.phase), true) end
    local now = St.nowMs()
    local shown = false
    if U.ok(wt.screen) then pcall(function() shown = wt.screen:IsInViewport() == true end) end
    local st = S.stage
    if not st then
        if not shown then S.watch = nil; return stopStageLoop() end
        if now - (wt.checkMs or -1e12) < 250 then return end
        wt.checkMs = now
        if anyMainMenu() or not armed() then return end   -- an old instance still lives: the CSM reuses it
        local p1, cls, mgr = U.p1(), classOf(C.BP.MainMenu), U.giSubsystem("UIManager")
        if not (U.ok(p1) and cls and U.ok(mgr)) then return end
        local w
        local okC = pcall(function() w = U.WBL():Create(p1, cls, p1) end)
        if not (okC and U.ok(w)) then return end
        local vis = 4
        pcall(function() vis = w:GetVisibility() end)
        local z = math.tointeger(tonumber(opt("FrontEndMenuZ", 500))) or 500
        local okV = pcall(function() w:AddToViewport(z) end)
        pcall(function() w:SetVisibility(1) end)                                   -- Collapsed until acquired
        local okL = okV and pcall(function() mgr:AddExistingWidgetToLayer(w, MENU) end)
        if not okL then
            pcall(function() w:RemoveFromParent() end)
            U.warn(TAG, "%s shows without a main menu: staging a P1 menu failed (V-FEO-15)", wt.cls)
            S.watch = nil
            return stopStageLoop()
        end
        S.stage = { w = w, vis = vis, atMs = now }
        U.log(TAG, "%s shows and no main menu exists: P1 main menu staged hidden in the Menu layer for its native Back "
            .. "(V-FEO-15)", wt.cls)
        return
    end
    if not U.ok(st.w) then S.stage, S.watch = nil, nil; return stopStageLoop() end
    local osm
    pcall(function() osm = st.w.OwningStateMachine end)
    if U.ok(osm) then
        local mgr, cls = U.giSubsystem("UIManager"), classOf(C.BP.MainMenu)
        pcall(function() st.w:SetVisibility(st.vis) end)
        local okR = U.ok(mgr) and cls ~= nil and pcall(function() mgr:RemoveWidget(cls, MENU) end)   -- 2 -> 1
        local okI = U.ok(mgr) and pcall(function() mgr:GetInputModeManager():OnControlMappingsRebuilt() end)
        U.log(TAG, "staged P1 main menu acquired on the return from %s (%d ms staged): shown, extra ref %s, input mode "
            .. "refresh %s (V-FEO-15)", wt.cls, math.floor(now - st.atMs), okR and "released" or "kept",
            okI and "ok" or "failed")
        S.stage, S.watch = nil, nil
        return stopStageLoop()
    end
    if shown then st.goneMs = nil; return end
    st.goneMs = st.goneMs or now
    if now - st.goneMs > 1500 then
        local other = false
        local ok, list = pcall(FindAllOf, shortName(C.BP.MainMenu))
        if ok and type(list) == "table" then
            for _, w in ipairs(list) do
                if U.ok(w) and U.key(w) ~= U.key(st.w) then
                    local v = false
                    pcall(function() v = w:IsInViewport() == true end)
                    if v then other = true end
                end
            end
        end
        return unstage(wt.cls .. " left without acquiring it", not other)
    end
end

watchStage = function(screen, cls)
    if not STAGE_FOR[cls] or opt("FrontEndStageMenu", true) == false then return end
    if S.watch and S.stage then return end
    S.watch = { screen = screen, cls = cls }
    if not S.stageLoop then S.stageLoop = sched.every("feowner.stage", 33, M.stageTick) end
end

-- 0.13.3: a pre-created screen waits for the CSM (menu_tab.ensure leaves the main menu alone meanwhile)
function M.pending() return S.pre ~= nil end

-- A hook that finds a pre-create pending first settles it: the CSM may already have acquired it while the FAST tick
-- (33 ms) has not seen it yet. Live 2026-10-15: P1's B 0.5 s after opening EULA landed in that window, the page's
-- Back hook skipped its Settings pre-create ("a pre-create is pending") and Settings went to the guest (brick).
local function settlePre()
    if S.pre then settle() end
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

-- c6 (0.13.3): the return from Settings (BP_Csm_FrontEnd_ReturnFromSubmenus -> ChangeStateTo(cached main-menu leaf))
-- EMPTIES the Menu layer inside that call, our pre-created P1 menu included, and builds a new main menu in the same call
-- (traced live 2026-10-15: Menu layer 1 -> 0 between the ChangeStateTo pre and post hooks, a new WBP_FE_MainMenu_C
-- constructed before the post; a second AddExistingWidgetToLayer of ours is removed too). No pre-create can feed it:
-- P1's B out of Settings gave the main menu to the guest and bricked both pads (Settings itself, from every tab).
-- The owner helper keeps the last local PC that HAS a LocalPlayer (research menu-owner.md §0.1, pc+0x350 Player), so
-- while a main-menu pre-create is pending, a ChangeStateTo into a main-menu leaf hides the guests' LocalPlayer
-- (PlayerController.Player = nil) for that one call; the post-hook puts it back (FAST / MAIN ticks too, should a post
-- never run). A wait=false screen is created synchronously inside the call, so the bracket covers it (the research's
-- objection to (f) is about wait=true screens, created on a later CSM tick). cfg.FrontEndOwnerBracket.  VERIFY(V-FEO-17)
restoreGuests = function(why)
    local br = S.bracket
    if not br then return end
    S.bracket = nil
    local okAll = true
    for _, g in ipairs(br.guests) do
        local ok = U.ok(g.pc) and pcall(function() g.pc.Player = g.lp end)
        if not ok then okAll = false end
    end
    if why ~= "post" then
        U.warn(TAG, "guest LocalPlayer(s) put back by the %s tick, not by the ChangeStateTo post-hook (V-FEO-17)", tostring(why))
    end
    return okAll, br
end

local function hideGuests(name)
    if S.bracket or opt("FrontEndOwnerBracket", true) == false then return end
    local p1 = U.p1()
    if not U.ok(p1) then return end
    local guests = {}
    for _, e in ipairs(U.localPlayers()) do
        if U.ok(e.pc) and U.key(e.pc) ~= U.key(p1) then
            local lp
            pcall(function() lp = e.pc.Player end)
            if U.ok(lp) and pcall(function() e.pc.Player = nil end) then
                guests[#guests + 1] = { pc = e.pc, lp = lp, index = e.index }
            end
        end
    end
    if #guests > 0 then S.bracket = { guests = guests, name = name, atMs = St.nowMs() } end
end

local function onChangeStatePost()
    local okAll, br = restoreGuests("post")
    if not br then return end
    local owners = {}
    local okF, list = pcall(FindAllOf, shortName(C.BP.MainMenu))
    if okF and type(list) == "table" then
        for _, w in ipairs(list) do
            if U.ok(w) then
                local inV, owner = false, nil
                pcall(function() inV = w:IsInViewport() == true end)
                pcall(function() owner = w:GetOwningPlayer() end)
                if inV then owners[#owners + 1] = "P" .. tostring(pnumOf(owner) or "?") end
            end
        end
    end
    U.log(TAG, "ChangeStateTo(%s) with %d guest LocalPlayer(s) hidden from the owner helper: restored %s, main menu "
        .. "owner %s (V-FEO-17)", br.name, #br.guests, okAll and "ok" or "FAILED",
        #owners > 0 and table.concat(owners, ",") or "none yet")
end

-- c3: a ChangeStateTo into a main-menu leaf (the return from Settings) or into a front-end sub-screen (Settings,
-- Credits, Stickerbook, inspect screens, Settings pages).
local function onChangeStatePre(ctx, newState)
    settlePre()
    if St.phase ~= "FRONTEND" or St.launchHold() or not armed() or opt("FrontEndSubScreens", true) == false then return end
    local st
    pcall(function() st = newState:get() end)
    if not U.ok(st) then return end
    local name = objName(st)
    if MENU_LEAVES[name] then
        if not S.pre then tryPrecreate(C.BP.MainMenu, "ChangeStateTo(" .. name .. ")", "V-FEO-11") end
        -- c6: a main menu is about to be shown and ours waits for it (a tab switch hands the shown one over instead)
        if S.pre and S.pre.path == C.BP.MainMenu and U.ok(S.pre.w) then hideGuests(name)
        -- c7 (#75, tester #5 2026-10-18 04:28:22): leaving the FREE MODE tab for a game tab BUILDS A NEW main menu
        -- in that ChangeStateTo although the old one is still in the viewport (round 2a 18:47:52: "tab poll: active
        -- tab is now MainMenu_Multiplayer" -> "main menu instance installed"), so no pre-create runs (the shown menu
        -- skips it). With a guest joined there the new menu went to the guest: the tabs (LB / RB) and the tiles
        -- answered P2's pad, P1's did nothing. One of our pages showing = that tab leave: the guests are hidden from
        -- the owner helper for the call too (whatever the CSM builds in it is P1's; a hand-over builds nothing).
        -- cfg.FrontEndOwnerBracket = false turns it off with c6.
        elseif St.menu and St.menu.visible ~= nil then
            hideGuests(name .. ", leaving the FREE MODE tab")
        end
        return
    end
    if S.pre then return end
    if SUB_ENTER[name] then return tryPrecreate(SUB_ENTER[name], "ChangeStateTo(" .. name .. ")", "V-FEO-13") end
end

local function backTarget(cn)
    local t = BACK_TARGET[cn]
    if t == nil then return nil end
    if cn == "WBP_Credits_C" and U.csmActive(VIEW_CREDITS, true) == true then t = SETTINGS end
    return (t == "menu") and C.BP.MainMenu or t
end

-- c3b (0.13.3, Nexus report 2026-10-14 "B bricks both pads"): the ARCADE and SCENARIOS lists open their inspect
-- screens with CosmeticStateMachine:ChangeToState(SoftObject newState, Str reason, Object payload), not ChangeStateTo:
-- c3 never saw them, the screen went to the last local PC (the guest), P1's pad lost its screen, the guest's IA_UI_*
-- never fire in the front end and menubridge only bridges paused / post-race: B (and A) dead on both pads, mouse only.
-- The soft target is NEVER read (soft params crashed UE4SS twice, ignpad.lua header); the reason is empty (live
-- 2026-10-15); the hard payload object names the screen: ArcadeEntryVM / ScenarioEntryVM (live 2026-10-15).
local PAYLOAD_SCREEN = {
    ArcadeEntryVM = SUB_ENTER.CSM_FrontEnd_ArcadeInspect,
    ScenarioEntryVM = SUB_ENTER.CSM_FrontEnd_ScenarioInspect,
}
-- The Campaign tab's LOGBOOK tile (WBP_FE_Recommended_C.Btn_Tile_A1 in this build): ChangeToState with no payload and
-- an empty reason (CONTINUE CAMPAIGN = Btn_Tile_Main passes "mode wants title card"); the active leaf is _Recommended
-- or, after a return from a sub-screen, _Menu, so the clicked tile decides: the one holding a user's focus (live
-- 2026-10-15: the ChangeToState call itself creates the screen, a post-hook is too late).
local function logbookTileFocused()
    for _, rec in ipairs(FindAllOf("WBP_FE_Recommended_C") or {}) do
        if U.ok(rec) then
            local vis, f = false, false
            pcall(function() vis = rec:IsVisible() == true end)
            if vis then
                pcall(function()
                    local b = rec.Btn_Tile_A1
                    f = U.ok(b) and (b:HasAnyUserFocus() == true or b:HasFocusedDescendants() == true)
                end)
                if f then return true end
            end
        end
    end
    return false
end
local function onChangeToStatePre(ctx, _softNewStateNeverRead, reasonP, payloadP)
    settlePre()
    if St.phase ~= "FRONTEND" or St.launchHold() or S.pre or not armed() or opt("FrontEndSubScreens", true) == false then return end
    local o
    pcall(function() o = payloadP:get() end)
    if not U.ok(o) then
        local reason = "?"
        pcall(function() reason = U.str(reasonP) end)
        if reason == "" and logbookTileFocused() then
            return tryPrecreate(SUB_ENTER.CSM_FrontEnd_StickerBook, "ChangeToState(Campaign tab LOGBOOK)", "V-FEO-14")
        end
        U.logOnce("feowner.cts.r." .. tostring(reason), TAG, "ChangeToState without payload (reason '%s'): no pre-create "
            .. "(V-FEO-14)", tostring(reason))
        return
    end
    local cn = className(o)
    local path = PAYLOAD_SCREEN[cn]
    if path then return tryPrecreate(path, "ChangeToState(payload " .. cn .. ")", "V-FEO-14") end
    U.logOnce("feowner.cts." .. cn, TAG, "ChangeToState with payload %s: no known screen, no pre-create (V-FEO-14)", cn)
end

-- c3: a sub-screen's Back (FuseScreenWidget version: the screen is the context).
local function onScreenBackPre(ctx)
    settlePre()
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
    settlePre()
    if St.phase ~= "FRONTEND" or St.launchHold() or S.pre or not armed() or opt("FrontEndSubScreens", true) == false then return end
    for cn in pairs(BACK_TARGET) do
        local ok, w = pcall(FindFirstOf, cn)
        if ok and U.ok(w) then
            local okV, inV = pcall(U.callMethod, w, "IsInViewport")
            if okV and inV == true then
                local target = backTarget(cn)
                if target then return tryPrecreate(target, cn .. " Back (state machine)", "V-FEO-11") end
            end
        end
    end
end

-- c5 (0.13.3): the Settings pages (View Credits / EULA / Privacy / Patch Notes / controller diagram / gamma /
-- brightness) are entered natively from a Settings row: no UFunction precedes them (trace, live 2026-10-15), so they
-- belong to the guest and P1's B is dead there. Repair (MAIN loop): such a page active and owned by a guest -> its
-- CosmeticStateMachine:BackToPreviousState (c3's Back hook pre-creates Settings for P1), then, once Settings is back,
-- ChangeStateTo(the same page state) (c3's ChangeStateTo hook pre-creates the page for P1). One short flash of
-- Settings instead of a dead pad. At most 2 FAILED tries in a row per page per front-end visit (a success resets the
-- count: every visit of a page needs one).  VERIFY(V-FEO-16)
local SM_DIR = "/Game/Griffin/Gameplay/FrontEnd/StateMachine/"
local REPAIR = {}                          -- state name -> screen class short name (Settings pages only)
for st, path in pairs(SUB_ENTER) do
    local cn = shortName(path)
    if st:find("Settings_", 1, true) then REPAIR[st] = cn end
end
local R = { cur = nil, tries = {}, worldKey = nil }

local function stateObj(name) return classOf(SM_DIR .. name .. "." .. name) end   -- StaticFindObject, no load

local function repairTick()
    if St.launchHold() or not armed() or opt("FrontEndRepairPages", true) == false then R.cur = nil; return end
    local wk = 0
    pcall(function() wk = U.key(U.world()) end)
    if wk ~= R.worldKey then R.worldKey, R.tries, R.cur = wk, {}, nil end
    local now = St.nowMs()
    local cur = R.cur
    if cur then
        if now - cur.atMs > 4000 then
            U.warn(TAG, "repair of %s gave up in phase %s (V-FEO-16)", cur.state, cur.step)
            R.cur = nil
            return
        end
        if cur.step == "back" then
            if S.pre or U.csmActive(SM_DIR .. cur.state .. "." .. cur.state, true) == true then return end
            if not screenInViewport(SETTINGS) then return end
            local st = stateObj(cur.state)
            local ok = U.ok(st) and U.ok(cur.sm) and pcall(function() cur.sm:ChangeStateTo(st, "SWGRCouch P1 owner", nil) end)
            cur.step = "enter"
            if not ok then U.warn(TAG, "repair of %s: ChangeStateTo failed (V-FEO-16)", cur.state); R.cur = nil end
            return
        end
        if S.pre then return end                                         -- c3's pre-create of the page is pending
        local okF, w = pcall(FindFirstOf, cur.cls)
        local owner
        if okF and U.ok(w) then pcall(function() owner = w:GetOwningPlayer() end) end
        local p1 = U.p1()
        local good = U.ok(owner) and U.ok(p1) and U.key(owner) == U.key(p1)
        U.log(TAG, "repair of %s (%s, was P%s): %s after %d ms (V-FEO-16)", cur.state, cur.cls, tostring(cur.was),
            good and "now owned by P1" or "STILL NOT P1", math.floor(now - cur.atMs))
        -- the cap counts FAILED repairs only: a third visit of the same page (live 2026-10-15: View Credits) found the
        -- cap used up by two successful repairs, was not repaired and bricked both pads again
        if good then R.tries[cur.state] = nil end
        R.cur = nil
        return
    end
    for st, cn in pairs(REPAIR) do
        if (R.tries[st] or 0) < 2 and U.csmActive(SM_DIR .. st .. "." .. st, true) == true then
            local okF, w = pcall(FindFirstOf, cn)
            if okF and U.ok(w) then
                local owner, act, sm
                pcall(function() owner = w:GetOwningPlayer() end)
                pcall(function() act = w:IsActivated() == true end)
                pcall(function() sm = w.OwningStateMachine end)
                local p1 = U.p1()
                if act and U.ok(owner) and U.ok(p1) and U.key(owner) ~= U.key(p1) and U.ok(sm) then
                    R.tries[st] = (R.tries[st] or 0) + 1
                    R.cur = { state = st, cls = cn, sm = sm, step = "back", atMs = now, was = pnumOf(owner) }
                    U.log(TAG, "%s (%s) belongs to P%s: repair %d -> Back, then the same page for P1 (V-FEO-16)", cn,
                        st, tostring(pnumOf(owner) or "?"), R.tries[st])
                    local ok = pcall(function() sm:BackToPreviousState(nil) end)
                    if not ok then R.cur = nil end
                    return
                end
            end
        end
    end
end

-- g (MAIN loop, FRONTEND): the Multiplayer tab is hidden and disabled while split-screen guests exist.
-- VERIFY(V-FEO-07): LB/RB skip the hidden tab.
function M.mainTick()
    if S.bracket then restoreGuests("MAIN") end          -- c6: never past the ChangeStateTo call
    if St.phase == "FRONTEND" then U.try(TAG, repairTick) end            -- c5 (0.13.3)
    if St.phase ~= "FRONTEND" or opt("FrontEndHideMultiplayer", true) == false then return end
    if opt("FrontEndMenuOwner", "p1") ~= "p1" then return end
    local m = St.menu and St.menu.widget
    if not U.ok(m) then return end
    local guests = localPcCount() >= 2
    local k = U.key(m)
    -- #75: a main menu a guest owns (no pre-create / bracket covered its creation): LB / RB and the tiles answer that
    -- guest's pad. Named once per menu instance (the live evidence for the next uncovered path).
    if guests and S.ownerWarned ~= k then
        local owner
        pcall(function() owner = m:GetOwningPlayer() end)
        local p1 = U.p1()
        if U.ok(owner) and U.ok(p1) and U.key(owner) ~= U.key(p1) then
            S.ownerWarned = k
            U.warn(TAG, "the shown main menu belongs to P%s: its tabs (LB / RB) and tiles answer that pad, not P1's "
                .. "(no pre-create / owner bracket covered its creation) (V-FEO-18)", tostring(pnumOf(owner) or "?"))
        end
    end
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
        U.hook(HOOK_CST, { pre = onChangeStatePre, post = onChangeStatePost }, TAG)
        U.hook(HOOK_CTS, { pre = onChangeToStatePre }, TAG)
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
