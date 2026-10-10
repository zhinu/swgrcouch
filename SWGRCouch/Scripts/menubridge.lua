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
local PANEL_CLASS = "/Script/UMG.PanelWidget"

local S = { screens = {}, seenAt = {}, scanAt = -1e9, prevA = {}, prevB = {}, prevD = {}, pending = nil, clicks = 0,
            inputOpened = {}, native = {}, fb = {}, dlg = nil, dlgAt = -1e9, dlgE = nil }
local KEYS

-- cfg[k] when it has the type of the default d (keys config.lua does not list yet fall back to d)
local function opt(k, d)
    local v = cfg[k]
    if v == nil or type(v) ~= type(d) then return d end
    return v
end

local function enabled() return cfg.MenuBridge ~= false end
local function waitMs()
    local v = tonumber(cfg.MenuBridgeWaitMs)
    return (v and v >= 0) and v or 150
end

local function keys()
    if KEYS then return KEYS end
    KEYS = { A = { KeyName = U.fname("Gamepad_FaceButton_Bottom") }, B = { KeyName = U.fname("Gamepad_FaceButton_Right") },
             Enter = { KeyName = U.fname("Enter") },
             Up = { KeyName = U.fname("Gamepad_DPad_Up") }, Down = { KeyName = U.fname("Gamepad_DPad_Down") },
             Left = { KeyName = U.fname("Gamepad_DPad_Left") }, Right = { KeyName = U.fname("Gamepad_DPad_Right") } }
    return KEYS
end

local function cls(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

local function lname(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and type(n) == "string" and n or "?"
end

local function hasAny(s, list)
    for _, k in ipairs(list) do if s:find(k, 1, true) then return true end end
    return false
end

local function pnumOf(pc)
    if not U.ok(pc) then return nil end
    for _, e in ipairs(U.localPlayers()) do
        if U.ok(e.pc) and U.key(e.pc) == U.key(pc) then return e.index end
    end
    return nil
end

local function pcOf(p)
    for _, e in ipairs(U.localPlayers()) do
        if e.index == p and U.ok(e.pc) then return e.pc end
    end
    return nil
end

local function ownerP(w)
    local ok, o = pcall(function() return w:GetOwningPlayer() end)
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
    local ok, r = pcall(function() return w:IsA(c) end)
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
local function scan(now, force)
    if not force and now - S.scanAt < SCAN_MS then return end
    S.scanAt = now
    local list, alive = {}, {}
    for _, w in ipairs(FindAllOf("CommonActivatableWidget") or {}) do
        local n = cls(w)
        if n:sub(1, 4) == "WBP_" and not hasAny(n, EXCLUDE) then
            local act, shown = false, false
            pcall(function() act = w:IsActivated() == true end)
            if act then pcall(function() shown = w:IsInViewport() == true or U.ok(w:GetParent()) end) end
            if act and shown then
                local k = U.key(w)
                alive[k] = true
                S.seenAt[k] = S.seenAt[k] or now
                list[#list + 1] = { w = w, k = k, cls = n, at = S.seenAt[k], shared = hasAny(n, SHARED),
                                    dialog = isA(w, DIALOG_CLASS) }
            end
        end
    end
    for k in pairs(S.seenAt) do if not alive[k] then S.seenAt[k] = nil end end
    table.sort(list, function(a, b) return a.at > b.at end)
    S.screens = list
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
    local e = S.screens[1]
    if e and U.ok(e.w) then return e end
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
            local x = b:GetOuter()
            for _ = 1, 8 do
                if not U.ok(x) then break end
                if U.key(x) == U.key(screen) then inside = true; break end
                x = x:GetOuter()
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
    local okT, t = pcall(function() return screen:GetDesiredFocusTarget() end)
    if okT and U.ok(t) then
        local isBtn = pcall(function() return t:GetSelected() end)
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
    elseif pcall(function() e.w:BackToPreviousState() end) then
        how = "BackToPreviousState()"
    end
    S.clicks = S.clicks + 1
    U.log(TAG, "P%d B -> %s: %s (V-MB-03)", p, e.cls,
        how or "no back path (HandleBack / OnCancelAction / BackToPreviousState all failed)")
end

local function click(e, p, what)
    if e.dialog then return dialogPress(e, p, what) end
    if what == "B" then return back(e, p) end
    local b, how = selectedButton(e.w)
    if not U.ok(b) then
        U.logEvery("mb.nobtn" .. e.cls, 5000, TAG, "P%d %s on %s: %s, nothing clicked", p, what, e.cls, tostring(how))
        return
    end
    local ok, err = pcall(function() b:HandleButtonClicked() end)
    S.clicks = S.clicks + 1
    U.log(TAG, "P%d %s -> %s %s (%s): %s (V-MB-01/02)", p, what, e.cls, lname(b), how,
        ok and "clicked" or ("error " .. tostring(err)))
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
        local rc = root:GetClass():GetFName():ToString()
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

local function openInputs(e)
    local own = ownerP(e.w)
    local now = St.nowMs()
    for _, lp in ipairs(U.localPlayers()) do
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
    return p >= 2 and ownerP(e.w) == p and pausedNow() and type(e.cls) == "string" and e.cls:find("^WBP_Pause") ~= nil
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
    if e.shared then return what == "A" end              -- shared post-race screens: anyone's A (P2-owned in split)
    if own == p then                                     -- the owner: a guest is bridged, P1 works natively
        if p == 1 then return false end
        if paused and opt("MenuBridgeGuestNative", "skip") == "skip" and pauseCall("guestUiNative", pcOf(p)) == true
            and not guestPauseMenu(e, what) and not guestDead(p) then
            noteNative(e, p)                             -- 0.7.2: native A/B already reach it (run I)
            return false
        end
        return true
    end
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
    return still
end

---------------------------------------------------------------------------------------------------- tick
function M.fastTick()
    if not enabled() then return end
    local lps = U.localPlayers()
    if #lps < 2 then S.pending = nil; return end
    local now = St.nowMs()
    -- menus only exist while paused (pause / player menu, their sub-screens and dialogs) or after the race (results)
    local paused = pausedNow()
    if not paused and St.phase ~= "POSTRACE" then
        S.screens, S.pending, S.dlg, S.dlgE, S.catch = {}, nil, nil, nil, {}
        return
    end
    U.tryEvery("mb.scan", nil, TAG, scan, now)
    local e = top(now)
    if e and e.shared then U.tryEvery("mb.inputs", nil, TAG, openInputs, e) end
    if e and paused and not e.dialog and not e.shared then U.tryEvery("mb.fb", nil, TAG, fallbackInputs, e) end
    if not (e and e.dialog) then S.dlg = nil end
    -- a pending press: the game had its chance; the same screen still on top (re-read now) -> click it ourselves
    local pd = S.pending
    if pd and now - pd.atMs >= waitMs() then
        S.pending = nil
        U.tryEvery("mb.scan", nil, TAG, scan, now, true)
        local e2 = top(now, true)
        local still = e2 ~= nil and e2.k == pd.k and stillUp(e2)
        if pd.probe then noteGuestNative(pd.p, not still) end
        if still then U.try(TAG, click, e2, pd.p, pd.what) end
        e = e2
    end
    local K = keys()
    for _, lp in ipairs(lps) do
        local pc = lp.pc
        if U.ok(pc) then
            local k = U.key(pc)
            local a, b, dir = false, false, 0
            pcall(function()
                a = pc:IsInputKeyDown(K.A) == true or (lp.index == 1 and pc:IsInputKeyDown(K.Enter) == true)
                if not a and e and e.shared and lp.index == 1 and opt("MenuBridgeP1Catcher", true)
                    and lp.index ~= ownerP(e.w) then
                    a = catcherDown(e)
                    if a and not S.prevA[U.key(pc)] then
                        U.logEvery("mb.catch", 2000, TAG, "P1 A read from the catcher button on %s (V-MB-09)", e.cls)
                    end
                end
                if not a and e and e.shared and opt("MenuBridgeRawA", false) ~= false and lp.index ~= ownerP(e.w) then
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
                end
            end)
            if e and not S.pending then
                if a and not S.prevA[k] and bridgeable(e, lp.index, "A") then
                    S.pending = { k = e.k, p = lp.index, what = "A", atMs = now, probe = guestProbe(e, lp.index) }
                elseif b and not S.prevB[k] and not e.shared and bridgeable(e, lp.index, "B") then
                    S.pending = { k = e.k, p = lp.index, what = "B", atMs = now, probe = guestProbe(e, lp.index) }
                elseif dir ~= 0 and (S.prevD[k] or 0) == 0 and e.dialog and bridgeable(e, lp.index, "A") then
                    U.try(TAG, dialogMove, e, lp.index, dir)
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
            S.screens, S.seenAt, S.pending, S.prevA, S.prevB, S.prevD = {}, {}, nil, {}, {}, {}
            S.inputOpened, S.native, S.fb, S.dlg, S.dlgE = {}, {}, {}, nil, nil
        end
        if new == "FRONTEND" or new == "LAUNCHING" then feStart("phase " .. new) else feStop("phase " .. tostring(new)) end
    end)
    if St.phase == "FRONTEND" or St.phase == "LAUNCHING" then feStart("init") end
    U.log(TAG, "init 0.7.2: MenuBridge=%s wait %d ms (guest-owned screens: owner's A/B unless native, GuestNative %s; "
        .. "shared post-race screens: anyone's A); dialogs %s, back %s, controller fallback %s, profile owner %s",
        tostring(enabled()), math.floor(waitMs()), opt("MenuBridgeGuestNative", "skip"),
        tostring(opt("MenuBridgeDialogs", true)), tostring(opt("MenuBridgeBack", true)),
        tostring(opt("MenuBridgeControllerFallback", true)), tostring(opt("MenuBridgeProfileOwner", true)))
end

return M
