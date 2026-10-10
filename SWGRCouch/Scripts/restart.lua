-- restart.lua (G5, 0.11.0): RESTART RACE in the pause menu of an offline custom race SWGRCouch launched (user,
--   2026-10-10: "Also add restart race in the menu"). notes/research/restart-race.md. Static facts (decoded hotfix paks +
--   exe CL382493):
--   * WBP_PauseRacing_C (State Name 'CampaignRace') is a WBP_Pause_C. WBP_Pause's rows are WBP_Vertical_Btn_C widgets in
--     FuseFilteredVerticalBox (BP variable, a UVerticalBox). PreConstruct calls FuseFilteredVerticalBox:UpdateSlots(State
--     Name), whose native body (0x14705e378 -> 0x14712e4b0) DETACHES every child not in FilterListMap[State Name].List
--     (UPanelWidget::RemoveChild): in a custom race Btn_RetryRace and Btn_ReportPlayer are gone (alive as BP variables,
--     bindings kept); the dev rows (AbandonRace / WreckVehicle / ResetVehicle) stay, collapsed by Construct.
--   * Btn_RetryRace: click -> GfnMessagingSubsystem:AddMessage('RetryRace', OnConfirmPrompt) = the game's own dialog "Are
--     You Sure? / Are you sure you want to retry the current race?" (Accept -> Yes, Cancel -> No) in the P1-owned Dialog
--     container; OnConfirmPrompt('Yes') -> ArcadeSubsystem:RequestRestartEvent() (EX_FinalFunction); focus ->
--     description MenuText.Pause_Description_Retry ("Give it another go!").
--   * ArcadeSubsystem::RequestRestartEvent (exec 0x14707c2f2): returns at once while LastPlayedArcadeEvent (+0x40, a
--     HARD Object<UArcadeEventDef>) is null; else race SM event 8 + TravelToEvent(LastPlayedArcadeEvent) = another race.
--   * ARacingGameMode::RequestResetRace (exec 0x1470de988 -> 0x142fe0bb2): a no-op on a net client; else race SM event 8
--     + ServerTravel("?Restart") (seamless, same map). Live 2026-10-10 03:16:31 (state/runs/20261010-0512-hud-before,
--     UE4SS-051730.log:1242-1425): called FROM THE PAUSE (P1's inactivity auto-pause, WBP_PauseRacing_C up since
--     03:15:30, restart-0-before.png): the pause CSM went with the race CSM ("pause over (states [])" 290 ms later),
--     RACING -> LEAVING -> TRANSIT -> PRERACE on the same map, the same 12-racer recipe, perkapply re-verified both
--     humans, PRERACE -> RACING after the intro, 0 ERROR lines.
--   Design: the game's own Btn_RetryRace is put back right below RESUME and labelled "Restart Race"
--   (MenuText.Pause_Button_Restart, localised, unused by the game); its native click raises the game's confirm dialog;
--   Accept reaches RequestRestartEvent, where ONE native pre-hook (armed flag first, registered only while an eligible
--   race is RACING) records the request; the next FAST tick calls RequestResetRace + phase.markLeaving("restart")
--   (cfg.PauseRestartSequence "direct": from the pause, the live-proven state; "resume": RESUME first, the call
--   PauseRestartAfterResumeMs after the pause ended). LastPlayedArcadeEvent is kept null while the entry is offered (the
--   native body must stay a no-op), written back at FRONTEND. cfg.PauseRestartConfirm "twice": our own
--   WBP_Vertical_Btn_C instead, confirmed by a second press within PauseRestartConfirmMs (no hook, no dialog).
--   Rules: game thread only (FAST tick, the hook); every game call in pcall / U.try; every kept UObject U.ok-checked
--   before a member access; no UIManager layer query (pause.lua hands each screen over: its pre-create / first sight);
--   no soft pointer read (WBP_PauseRacing.SafeExitToMenuStates and WBP_Pause.ValidPhotomodeCSMStates are soft arrays:
--   never touched); no TArray.
-- VERIFY(V-RST-01..12): notes/research/restart-race.md §5; the expected lines are next to each log call.

local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "restart"

-- cfg[k] when it has the type of the default d; keys config.lua does not list yet fall back to d.
local function opt(k, d)
    local v = cfg[k]
    if v == nil or type(v) ~= type(d) then return d end
    return v
end

local PAUSE_RACING = "/Game/Griffin/UI/Screens/Pause/WBP_PauseRacing.WBP_PauseRacing_C"
local MENU_TEXT = "/Game/Griffin/Localization/MenuText.MenuText"        -- string table of every pause label
local KTL = "/Script/Engine.Default__KismetTextLibrary"
local ARCADE = "/Script/Griffin.ArcadeSubsystem"
local HOOK_RESTART = "/Script/Griffin.ArcadeSubsystem:RequestRestartEvent"
local DEV_ROWS = { "Btn_AbandonRace", "Btn_WreckVehicle", "Btn_ResetVehicle" }   -- collapsed by Construct: never moved
local ELIG_MS, CHECK_MS = 1000, 500
local ROWS_MS = 1500        -- moved rows checked every FAST tick for this long after the pause starts / the row is placed

local function R()
    St.restart = St.restart or { restarts = 0, offers = 0 }
    return St.restart
end

local function confirmMode() return opt("PauseRestartConfirm", "dialog") end
local function sequenceMode() return opt("PauseRestartSequence", "direct") end

local function loaded(path)
    local ok, o = pcall(StaticFindObject, path)
    return (ok and U.ok(o)) and o or nil
end

local function pauseMod()
    local ok, p = pcall(U.mod, "pause")
    return (ok and type(p) == "table") and p or nil
end

-- "P2" for a local PlayerController, "?" when unknown
local function pnumDesc(pc)
    if not U.ok(pc) then return "?" end
    for _, lp in ipairs(U.localPlayers()) do
        if U.key(lp.pc) == U.key(pc) then return "P" .. lp.index end
    end
    return "other"
end

-- the pause state now: true / false / nil = unknown (pause.isPaused: find-only CSM reads). For the hook only.
local function pausedNow()
    local p = pauseMod()
    if not (p and type(p.isPaused) == "function") then return nil end
    local ok, v = pcall(p.isPaused)
    if ok then return v end
    return nil
end

-- this tick's pause state as pause.poll read it first in the FAST race block (menubridge / uxsplit read the same field):
-- true / false / nil = unknown (no pause state read yet in this race). No CSM call of our own on every tick.
local function pausedThisTick()
    local p = St.pause
    if type(p) ~= "table" or p.menuWasPaused == nil then return nil end
    return p.menuWasPaused == true
end

-- the pause controller (pause.controller(): the player the pause screens belong to) as "P2"
local function controllerDesc()
    local p = pauseMod()
    local ctl
    if p and type(p.controller) == "function" then pcall(function() ctl = p.controller() end) end
    return pnumDesc(ctl)
end

---------------------------------------------------------------------------------------------------- hook (dialog)
-- Hot-reload-safe registry like pause.lua's: _G.SWGRCouch_restart_hooks = {ids = {pre, post}, on = handler,
-- armed = bool}. The registered callback reads only this table: a re-required restart.lua swaps the handler without a
-- second RegisterHook; RestartCurrentMod gets a fresh Lua state (UE4SS unhooks the old state's hooks itself).
local function HK()
    local H = _G.SWGRCouch_restart_hooks
    if type(H) ~= "table" then
        H = {}
        _G.SWGRCouch_restart_hooks = H
    end
    return H
end

-- The registered pre-callback: the armed flag first, then the current handler inside pcall. RequestRestartEvent has
-- no param (only ctx, read by the handler). Returns nil (no return value to override).
local function hookCb(ctx)
    local H = _G.SWGRCouch_restart_hooks
    if type(H) ~= "table" or H.armed ~= true then return nil end
    local f = H.on
    if f then pcall(f, ctx) end
    return nil
end

local function hookArmed()
    local H = HK()
    return H.ids ~= nil and H.armed == true
end

---------------------------------------------------------------------------------------------------- eligibility
-- The checks that need game calls (net mode, the authority game mode, PrimaryFlow, the roster walk): nil = they pass,
-- else the first that fails. Cached ELIG_MS by baseVerdict (the FAST tick refreshes it).
local function baseWhy()
    if St.phase ~= "RACING" then return "phase " .. tostring(St.phase) end   -- PRERACE (intro, grid) on purpose
    if St.race.launchedByUs ~= true then return "race not launched by SWGRCouch" end
    local nm = U.netMode()
    if nm == "client" then return "network client" end
    local gm = U.gm()
    if not (U.ok(gm) and U.isA(gm, "RacingGameMode")) then return "no RacingGameMode (not the authority)" end
    local flow
    pcall(function() flow = math.tointeger(tonumber(U.gi().PrimaryFlow)) end)
    -- LaunchCustomRace sets QuickRace (2); Campaign 1, Arcade 3, Multiplayer 4 never get the entry
    if flow ~= C.E.PrimaryFlow.QuickRace then return "PrimaryFlow " .. tostring(flow) .. " (not a custom race)" end
    if not opt("PauseRestartRemote", false) then
        local n = 0
        if nm ~= "standalone" then                                  -- a standalone world has no remote player
            local okR, r = pcall(function() return #U.mod("roster").remoteHumans() end)
            if not okR then return "remote humans unknown (roster: " .. tostring(r) .. ")" end
            n = r
        end
        local expected = tonumber(St.net and St.net.expectedRemote) or 0
        if n > 0 or expected > 0 then
            return string.format("remote humans (%d connected, %d expected; PauseRestartRemote false)", n, expected)
        end
    end
    if confirmMode() == "dialog" and not U.ok(U.giSubsystem(ARCADE)) then
        return "ArcadeSubsystem not found (the RetryRace dialog would reach nothing)"
    end
    return nil
end

-- The cached checks, refreshed when due. -> nil when they pass, else why not.
local function baseVerdict(st, now)
    if not st.elig or now - st.elig.atMs >= ELIG_MS then
        local okW, why = pcall(baseWhy)
        if not okW then why = "check failed: " .. tostring(why) end
        st.elig = { atMs = now, why = why }
    end
    return st.elig.why
end

-- -> offered, why not. After the cached checks come the live ones: a pending request, the hook (dialog). The verdict is
-- logged once per race and whenever it changes (a remote player joining, the hook armed late).  VERIFY(V-RST-01): the
-- first RACING tick of a FREE MODE race logs "RESTART RACE offered in this race (standalone, confirm dialog, sequence
-- direct)"; a campaign or online race "RESTART RACE not offered: race not launched by SWGRCouch".
local function eligible(st, now)
    local why = baseVerdict(st, now)
    if why == nil and st.req then why = "restart already requested" end
    if why == nil and confirmMode() == "dialog" and not hookArmed() then
        why = st.hookFailed and ("RequestRestartEvent hook not registered: " .. st.hookFailed)
            or "RequestRestartEvent hook not armed"
    end
    st.whyNot = why
    local verdict = why or "offered"
    if St.phase == "RACING" and (st.verdictGen ~= St.worldGen or st.verdict ~= verdict) then
        st.verdictGen, st.verdict = St.worldGen, verdict
        if why then
            U.log(TAG, "RESTART RACE not offered: %s (V-RST-01)", why)
        else
            U.log(TAG, "RESTART RACE offered in this race (%s, confirm %s, sequence %s) (V-RST-01)", U.netMode(),
                confirmMode(), sequenceMode())
        end
    end
    return why == nil, why
end

---------------------------------------------------------------------------------------------------- label
-- cfg.PauseRestartLabel: "game" = MenuText.Pause_Button_Restart ("Restart Race", localised) | "retry" = the row's own
-- label (Pause_Button_Retry "Retry") | any other text = that text. -> FText (nil = keep the label), description
local function label()
    local mode = opt("PauseRestartLabel", "game")
    if mode == "retry" then return nil, "game label 'Retry'" end
    if mode == "game" then
        local ktl = loaded(KTL)
        local t
        if ktl then
            -- UKismetTextLibrary::TextFromStringTable(Name TableId, Str Key) -> Text (static, BlueprintPure)
            pcall(function() t = ktl:TextFromStringTable(U.fname(MENU_TEXT), "Pause_Button_Restart") end)
        end
        local s = t and U.str(t) or ""
        if s ~= "" and not s:find("MISSING", 1, true) and not s:find("^userdata") then
            return t, "MenuText.Pause_Button_Restart '" .. s .. "'"
        end
        return U.ftext("Restart Race"), "literal 'Restart Race' (string table entry unreadable)"
    end
    return U.ftext(mode), "cfg '" .. mode .. "'"
end

---------------------------------------------------------------------------------------------------- arcade guard
-- RequestRestartEvent's native body travels to LastPlayedArcadeEvent when it is set (an Arcade event played earlier
-- in this session): it must be null while our entry is offered. Cleared through the game's own
-- ResetLastPlayedArcadeEvent(); the asset path is kept (a scalar) and the pointer written back at FRONTEND.
-- cfg.PauseRestartArcadeGuard false: the entry is not offered while it is set. -> true when the field reads null.
local function arcadeGuard(sub, why)
    if not U.ok(sub) then sub = U.giSubsystem(ARCADE) end
    if not U.ok(sub) then return false end
    local ev
    pcall(function() ev = sub.LastPlayedArcadeEvent end)           -- Object<UArcadeEventDef> @+0x40 (hard pointer)
    if not U.ok(ev) then return true end
    if not opt("PauseRestartArcadeGuard", true) then return false end
    local st = R()
    if not st.arcadePath then st.arcadePath = U.pathOf(ev) end
    pcall(function() sub:ResetLastPlayedArcadeEvent() end)
    local after
    pcall(function() after = sub.LastPlayedArcadeEvent end)
    local ok = not U.ok(after)
    -- VERIFY(V-RST-05): an Arcade event played before the FREE MODE race: "... /Game/... cleared (entry offered)"
    local logf = ok and U.log or U.warn
    logf(TAG, "ArcadeSubsystem.LastPlayedArcadeEvent %s %s (%s): RequestRestartEvent stays a no-op; restored at "
        .. "FRONTEND (V-RST-05)", tostring(st.arcadePath), ok and "cleared" or "NOT cleared", tostring(why))
    return ok
end

-- FRONTEND: the cleared pointer written back, only while the field is still null (the same object-property write as
-- perkapply's ps.Pilot = def).  VERIFY(V-RST-05): "LastPlayedArcadeEvent restored (front end): ... ok"
local function arcadeRestore(why)
    local st = R()
    local path = st.arcadePath
    st.arcadePath = nil
    if type(path) ~= "string" or path == "" then return end
    local sub = U.giSubsystem(ARCADE)
    local ev = loaded(path)
    if not (U.ok(sub) and ev) then
        U.warn(TAG, "LastPlayedArcadeEvent %s not restored (%s): subsystem or asset not in memory (V-RST-05)", path,
            tostring(why))
        return
    end
    local cur
    pcall(function() cur = sub.LastPlayedArcadeEvent end)
    if U.ok(cur) then
        U.log(TAG, "LastPlayedArcadeEvent not restored (%s): the game set %s meanwhile (V-RST-05)", tostring(why),
            U.pathOf(cur))
        return
    end
    local ok = pcall(function() sub.LastPlayedArcadeEvent = ev end)
    U.log(TAG, "LastPlayedArcadeEvent restored (%s): %s %s (V-RST-05)", tostring(why), path, ok and "ok" or "failed")
end

---------------------------------------------------------------------------------------------------- placement
local function dropOwn(st)
    local b = st.own
    st.own = nil
    if U.ok(b) then pcall(function() b:RemoveFromParent() end) end
end

-- cfg.PauseRestartConfirm "twice": our own row, styled like RESUME (IsInvert + its focus pill colour); its clicks are
-- seen by the selected-toggle trick (ui.registerButton's poll path; ui.pollClicks itself runs in the front end only).
local function ownButton(w, resume)
    local owner
    pcall(function() owner = w:GetOwningPlayer() end)
    local b
    pcall(function() b = U.mod("ui").make("VerticalBtn", owner) end)  -- WBP_Vertical_Btn_C, owned like the screen
    if not U.ok(b) then return nil end
    pcall(function() b.IsInvert = true end)                         -- read by PreConstruct (the pause rows are inverted)
    pcall(function()
        local c = resume.LinearSelectBackgroundColor                -- the focus pill colour (E0AC50 in the asset)
        b.LinearSelectBackgroundColor = { R = c.R, G = c.G, B = c.B, A = c.A }
    end)
    pcall(function()
        b:SetIsSelectable(true)
        b:SetIsToggleable(true)
    end)
    -- a row that selects itself on focus would read as a press as soon as the D-pad reaches it
    if not pcall(function() b:SetShouldSelectUponReceivingFocus(false) end) then
        pcall(function() b.bShouldSelectUponReceivingFocus = false end)
    end
    return b
end

-- The row right below RESUME: every child after RESUME except the dev rows is taken out, the row is added, the others
-- are added back in their order (UVerticalBox has no reflected insert; the game's UpdateSlots takes the same
-- RemoveChild path on this live panel). A new UVerticalBoxSlot is HAlign Fill, the designer slots are HAlign Left:
-- without it the focus pill would stretch over the 1880-unit box. cfg.PauseRestartPosition "end": appended, nothing
-- moved. Every call in its own pcall: a removed row is added back even when our add failed. -> ok, text
-- 0.11.0: a row re-added to the box rebuilds its Slate widget and comes back with GetIsFocusable() and
-- IsInteractionEnabled() false: live 2026-10-10 every moved row was grey and the d-pad stopped at the first of them
-- (the detached Btn_RetryRace was off too). RESUME is never moved and keeps what the game set, so the moved rows and
-- ours copy it, only ever switched ON (BP_SetIsFocusable / BP_SetIsInteractionEnabled: the CommonButtonBase UFunctions
-- of this build; SetIsFocusable / SetIsInteractionEnabled are not exposed). Returns the short names it switched on.
local function enableRows(rows, resume)
    local rf, ri = false, false
    pcall(function() rf = resume:GetIsFocusable() == true end)
    pcall(function() ri = resume:IsInteractionEnabled() == true end)
    local fixed = {}
    for _, b in ipairs(rows or {}) do
        if U.ok(b) then
            local f, i = true, true
            pcall(function() f = b:GetIsFocusable() == true end)
            pcall(function() i = b:IsInteractionEnabled() == true end)
            local did = false
            if rf and not f and pcall(function() b:BP_SetIsFocusable(true) end) then did = true end
            if ri and not i and pcall(function() b:BP_SetIsInteractionEnabled(true) end) then did = true end
            if did then
                local n = "?"
                pcall(function() n = (b:GetFName():ToString():gsub("^Btn_", "")) end)
                fixed[#fixed + 1] = n
            end
        end
    end
    return fixed
end

local function place(w, btn, resume)
    local box
    pcall(function() box = w.FuseFilteredVerticalBox end)
    if not U.ok(box) then return false, "no FuseFilteredVerticalBox" end
    local has = false
    pcall(function() has = box:HasChild(btn) == true end)              -- (Object Content) -> Bool
    if has then return true, "already in the list" end
    local function add(c)
        local s
        pcall(function() s = box:AddChildToVerticalBox(c) end)          -- (Object Content) -> UVerticalBoxSlot
        if not U.ok(s) then return false end
        pcall(function() s:SetHorizontalAlignment(C.E.HAlign.Left) end) -- UVerticalBoxSlot:SetHorizontalAlignment(Byte)
        return true
    end
    local function count()
        local n
        pcall(function() n = math.tointeger(tonumber(box:GetChildrenCount())) end)
        return n or 0
    end
    local function indexOf(c)
        local i
        pcall(function() i = math.tointeger(tonumber(box:GetChildIndex(c))) end)   -- (Object Content) -> Int, -1
        return i or -1
    end
    local ri = indexOf(resume)
    if opt("PauseRestartPosition", "below_resume") == "end" or ri < 0 then
        local okA = add(btn)
        pcall(function() btn:SetVisibility(C.E.Vis.Visible) end)
        local rows = { btn }
        local fx = enableRows(rows, resume)
        return okA, string.format("appended at %d of %d (%s)%s", indexOf(btn), count(),
            ri < 0 and "RESUME not in the list" or "PauseRestartPosition end",
            #fx > 0 and (", switched on: " .. table.concat(fx, ", ")) or ""), rows
    end
    local dev = {}
    for _, n in ipairs(DEV_ROWS) do
        local d
        pcall(function() d = w[n] end)
        if U.ok(d) then dev[U.key(d)] = true end
    end
    local tail = {}
    for i = ri + 1, count() - 1 do
        local c
        pcall(function() c = box:GetChildAt(i) end)
        if U.ok(c) and not dev[U.key(c)] then tail[#tail + 1] = c end
    end
    local removed = {}
    for _, c in ipairs(tail) do
        local r = false
        pcall(function() r = box:RemoveChild(c) == true end)            -- (Object Content) -> Bool
        if r then removed[#removed + 1] = c end
    end
    local okA = add(btn)
    local back = 0
    for _, c in ipairs(removed) do
        if add(c) then back = back + 1 end
    end
    pcall(function() btn:SetVisibility(C.E.Vis.Visible) end)
    local rows = { btn }
    for _, c in ipairs(removed) do rows[#rows + 1] = c end
    local fx = enableRows(rows, resume)
    local lost, stuck = #removed - back, #tail - #removed
    return okA and lost == 0, string.format("at %d of %d under RESUME (%d row(s) moved below it%s%s)%s", indexOf(btn),
        count(), back, stuck > 0 and (", " .. stuck .. " not removable: above it") or "",
        lost > 0 and (", " .. lost .. " LOST") or "",
        #fx > 0 and (", switched on: " .. table.concat(fx, ", ")) or ""), rows
end

-- Called by pause.lua with every new pause screen: right after its pre-create (split race, inside the ChangeStateTo
-- hook: AddToViewport ran PreConstruct / Construct, the CSM shows the screen afterwards, so the re-layout is not seen)
-- and at first sight (menuTick: every screen, also the UIManager's own in a one-player race or with PauseMenuOwner
-- "game"). Idempotent per screen.
-- VERIFY(V-RST-02): 2P, P1 pauses: "RESTART RACE added to WBP_PauseRacing_C (owner P1, pre-create): Btn_RetryRace at 4
--   of 10 under RESUME (5 row(s) moved below it), switched on: RetryRace, Stickerbook, Settings, Photomode, Exit,
--   AbandonRun, label MenuText.Pause_Button_Restart 'Restart Race'"; the screen shows RESUME / RESTART RACE / LOGBOOK /
--   SETTINGS / PHOTO MODE / EXIT TO MAIN MENU (lock) / ABANDON TOUR, left aligned, every row black (none grey);
--   the d-pad walks the whole list and the description reads "Give it another go!". 1P race: "(owner P1, UIManager)".
function M.decorate(w, how)
    if not opt("PauseRestart", true) then return end
    local st = R()
    if not U.ok(w) then return end
    local k = U.key(w)
    if st.screenKey == k and st.placed then return end
    local cls = loaded(PAUSE_RACING)                                -- find-only: its instance holds it in memory
    local isRacing = false
    if cls then pcall(function() isRacing = w:IsA(cls) == true end) end
    if not isRacing then return end                                 -- WBP_PauseMultiplayer / Arcade / Paddock: never
    local now = St.nowMs()
    local ok, why = eligible(st, now)
    if not ok then
        U.dbg(TAG, "pause screen (%s): no RESTART RACE (%s)", tostring(how), tostring(why))
        return
    end
    local confirm = confirmMode()
    if confirm == "dialog" and not arcadeGuard(nil, "entry offered") then
        U.warn(TAG, "RESTART RACE not offered: ArcadeSubsystem.LastPlayedArcadeEvent is set and not cleared "
            .. "(PauseRestartArcadeGuard %s) (V-RST-05)", tostring(opt("PauseRestartArcadeGuard", true)))
        return
    end
    local resume
    pcall(function() resume = w.Btn_ResumeRace end)
    if not U.ok(resume) then
        U.warn(TAG, "RESTART RACE not added (%s): the screen has no Btn_ResumeRace (V-RST-02)", tostring(how))
        return
    end
    local btn
    if confirm == "twice" then
        dropOwn(st)
        btn = ownButton(w, resume)
        st.own = btn
    else
        pcall(function() btn = w.Btn_RetryRace end)                 -- detached by UpdateSlots, alive in the tree
    end
    if not U.ok(btn) then
        U.warn(TAG, "RESTART RACE not added (%s): no %s (V-RST-02)", tostring(how),
            confirm == "twice" and "own WBP_Vertical_Btn_C" or "Btn_RetryRace")
        return
    end
    local ft, ltxt = label()
    -- WBP_Vertical_Btn_C:SetText sets ButtonLabel + Txt_Label: the label survives the re-add's PreConstruct
    if ft then pcall(function() btn:SetText(ft) end) end
    local okP, placed, ptxt, rows = pcall(place, w, btn, resume)
    st.screen, st.screenKey, st.btn, st.placed = w, k, btn, okP and placed == true
    st.rows, st.resume, st.rowFixes, st.placedMs = okP and rows or nil, resume, 0, now
    st.rowLogged, st.rowWarned = false, false
    st.checkMs, st.offers = now, (st.offers or 0) + 1
    local owner
    pcall(function() owner = w:GetOwningPlayer() end)
    local logf = st.placed and U.log or U.warn
    logf(TAG, "RESTART RACE added to WBP_PauseRacing_C (owner %s, %s): %s %s, label %s (V-RST-02)", pnumDesc(owner),
        tostring(how), confirm == "twice" and "own WBP_Vertical_Btn_C" or "Btn_RetryRace",
        okP and tostring(ptxt) or ("ERROR " .. tostring(placed)), ltxt)
end

-- The moved rows (and ours) back on whenever RESUME is on and they are not. Live 2026-10-10 the game switched them off
-- once more AFTER the pre-create placement (nothing to switch at placement, all six off at the first paused re-check):
-- FAST checks them every tick for ROWS_MS after the pause starts or the row is placed (Anim_In fades the list in over
-- 0.25 s, so the grey rows are never seen), the CHECK_MS re-check after that. A fix inside that window is the expected
-- one (LOG); a later one is news (WARN); 20 fixes per screen at most.
local function rowsTick(st, now)
    if not (st.placed and st.rows and U.ok(st.resume)) or (st.rowFixes or 0) >= 20 then return end
    local fx = enableRows(st.rows, st.resume)
    if #fx == 0 then return end
    st.rowFixes = (st.rowFixes or 0) + 1
    local t0 = math.max(st.pauseMs or 0, st.placedMs or 0)
    local logf = U.dbg
    if now - t0 < ROWS_MS then
        if not st.rowLogged then st.rowLogged, logf = true, U.log end
    elseif not st.rowWarned then
        st.rowWarned, logf = true, U.warn
    end
    logf(TAG, "RESTART RACE: row(s) found off %d ms into the pause, switched on: %s (V-RST-02)",
        math.floor(now - (st.pauseMs or now)), table.concat(fx, ", "))
end

-- FAST while paused, every CHECK_MS: a rebuilt screen (PreConstruct -> UpdateSlots again, e.g. PauseMenuRehost
-- "always") lost the row: placed again.
local function recheck(st)
    local w, b = st.screen, st.btn
    if not (U.ok(w) and U.ok(b)) then
        st.placed = false
        return
    end
    local box
    local has = true
    pcall(function() box = w.FuseFilteredVerticalBox end)
    if U.ok(box) then pcall(function() has = box:HasChild(b) == true end) end
    if has then
        rowsTick(st, St.nowMs())
        return
    end
    st.placed = false
    U.warn(TAG, "RESTART RACE row lost (screen rebuilt): placing it again (V-RST-02)")
    M.decorate(w, "re-check")
end

---------------------------------------------------------------------------------------------------- request
local function request(st, by, via)
    if st.req then return false end
    st.req = { atMs = St.nowMs(), gen = St.worldGen, by = by, via = via, step = "confirmed" }
    -- VERIFY(V-RST-03): Accept -> "restart confirmed by P1 (RetryRace dialog Accept -> ArcadeSubsystem:
    --   RequestRestartEvent pre-hook)"; Cancel: no [restart] line. V-RST-04: P2 pauses and accepts -> "... by P2 ..."
    U.log(TAG, "restart confirmed by %s (%s) (V-RST-03)", tostring(by), tostring(via))
    return true
end

-- The hook body (game thread, inside the Blueprint's OnConfirmPrompt('Yes'), the dialog's call chain still on the
-- stack): the native body that runs right after it must stay a no-op (LastPlayedArcadeEvent null), then the request is
-- recorded. Nothing else happens here: the FAST tick acts.
local function onRestartEvent(ctxP)
    local st = R()
    local sub
    pcall(function() sub = ctxP:get() end)
    if not arcadeGuard(sub, "hook") then
        U.err(TAG, "RequestRestartEvent while LastPlayedArcadeEvent could not be cleared: the game travels to that "
            .. "Arcade event; no restart requested (V-RST-05)")
        return
    end
    -- our row is only on pause screens: a call while the game runs and no row of ours is up is not ours (a confirm
    -- dialog keeps the pause CSM active; the placed row keeps the request even if that read were wrong)
    if pausedNow() == false and not st.placed then
        U.warn(TAG, "RequestRestartEvent outside a pause and without our row: ignored (V-RST-03)")
        return
    end
    request(st, controllerDesc(), "RetryRace dialog Accept -> ArcadeSubsystem:RequestRestartEvent pre-hook")
end

local function hookHandler(ctx)
    U.tryEvery("restart.hook", nil, TAG, onRestartEvent, ctx)
end

-- FAST while an eligible race is RACING (dialog): registered once (at most one try per second, never again after a
-- failure), armed while it is wanted.  VERIFY(V-RST-07): "native pre-hook registered: /Script/Griffin.ArcadeSubsystem:
-- RequestRestartEvent (ids ...)" on the first RACING tick of every eligible race
local function ensureHook(st, now)
    local H = HK()
    H.on = hookHandler
    if H.ids then
        H.armed = true
        return true
    end
    if st.hookFailed or now - (st.hookTryMs or -1e12) < 1000 then return false end
    st.hookTryMs = now
    if not loaded(HOOK_RESTART) then
        st.hookFailed = "UFunction not found"
        U.err(TAG, "%s not found: RESTART RACE not offered (PauseRestartConfirm \"twice\" needs no hook) (V-RST-07)",
            HOOK_RESTART)
        return false
    end
    local ok, pre, post = pcall(RegisterHook, HOOK_RESTART, hookCb)
    if not ok or type(pre) ~= "number" then
        st.hookFailed = tostring(pre)
        U.err(TAG, "RegisterHook(%s) failed: %s - RESTART RACE not offered (PauseRestartConfirm \"twice\" needs no "
            .. "hook) (V-RST-07)", HOOK_RESTART, tostring(pre))
        return false
    end
    H.ids, H.armed = { pre = pre, post = post }, true
    U.log(TAG, "native pre-hook registered: %s (ids %s/%s, kept in _G.SWGRCouch_restart_hooks) (V-RST-07)",
        HOOK_RESTART, tostring(pre), tostring(post))
    return true
end

-- Disarm now and unregister. UnregisterHook only marks a native hook for removal (UE4SS LuaMod.cpp), so it is safe
-- from any context.  VERIFY(V-RST-07): "native pre-hook unregistered (leaving (restart))" before "RACING -> LEAVING",
-- "(phase POSTRACE)" at the race end
local function dropHook(why)
    local H = HK()
    H.armed = false
    local ids = H.ids
    if not ids then return end
    H.ids = nil
    local ok, e = pcall(UnregisterHook, HOOK_RESTART, ids.pre, ids.post or ids.pre)
    U.log(TAG, "native pre-hook unregistered (%s)%s (V-RST-07)", tostring(why), ok and "" or (": " .. tostring(e)))
end

---------------------------------------------------------------------------------------------------- twice
-- FAST while paused (PauseRestartConfirm "twice"): a click flips our toggleable row's selection. The first press arms a
-- PauseRestartConfirmMs window and puts a hint in the screen's own description box; a second press inside it is the
-- request.  VERIFY(V-RST-12): "RESTART RACE pressed once by P1: press again within 3000 ms", the description box reads
-- "Press again to restart the race"; the second A: "restart confirmed by P1 (second press within 3000 ms)"
local function twiceTick(st, now)
    local b = st.own
    if not U.ok(b) then return end
    local sel = false
    pcall(function() sel = b:GetSelected() == true end)
    if not sel then return end
    pcall(function() b:SetIsSelected(false, false) end)
    local by = controllerDesc()
    local win = math.floor(opt("PauseRestartConfirmMs", 3000))
    if st.armedUntil and now <= st.armedUntil then
        st.armedUntil = nil
        request(st, by, "second press within " .. win .. " ms")
        return
    end
    st.armedUntil = now + win
    local w = st.screen
    if U.ok(w) then
        -- the screen's own description box (VS_Info -> SzB_Description_Size), shown by its Blueprint ShowDescription()
        pcall(function()
            local txt = w.Txt_Description
            if U.ok(txt) then txt:SetText(U.ftext("Press again to restart the race")) end
        end)
        pcall(function() w:ShowDescription() end)
    end
    U.log(TAG, "RESTART RACE pressed once by %s: press again within %d ms (V-RST-12)", by, win)
end

---------------------------------------------------------------------------------------------------- sequence
-- Watchdog: still the same world PauseRestartWatchdogMs after the call = refused (a travel already pending, a net
-- client): LEAVING is undone like net.lua's servertravel watchdog. sched.after, not the FAST tick: LEAVING is no race
-- phase.  VERIFY(V-RST-08): never seen in a normal run; if seen: "restart: no travel 5000 ms after RequestResetRace
-- ...; LEAVING undone" and the race goes on
local function armWatchdog(st, gen, sentMs)
    sched.after("restart.watch", opt("PauseRestartWatchdogMs", 5000), function()
        if St.worldGen ~= gen then return end                     -- travelled: the new race offers it again
        local q = st.req
        st.req = nil
        local undone = false
        U.try(TAG, function() undone = U.mod("phase").cancelLeaving("restart not executed", gen) == true end)
        U.warn(TAG, "restart: no travel %d ms after RequestResetRace (requested by %s); LEAVING %s (V-RST-08)",
            math.floor(St.nowMs() - sentMs), q and tostring(q.by) or "?", undone and "undone" or "kept")
    end)
end

-- RequestResetRace on the authority game mode, then phase.markLeaving("restart") in the same tick (net.serverTravelNow's
-- order: ServerTravel only arms the travel, so every "leaving" listener still sees the PCs and PlayerStates; it also
-- replaces the late "poll" leaving of the live test), then the watchdog.
local function send(st, q, now, since)
    local gm = U.gm()
    if not (U.ok(gm) and U.isA(gm, "RacingGameMode")) then
        U.warn(TAG, "restart: no RacingGameMode any more: request dropped (V-RST-06)")
        st.req = nil
        return
    end
    local okR, err = pcall(function() gm:RequestResetRace() end)
    if not okR then
        U.err(TAG, "restart: RequestResetRace failed: %s (V-RST-06)", tostring(err))
        st.req = nil
        return
    end
    st.restarts = (st.restarts or 0) + 1
    q.step, q.sentMs, q.sentGen = "sent", now, St.worldGen
    U.log(TAG, "restart #%d: RequestResetRace sent %s (requested by %s) (V-RST-06)", st.restarts, since, tostring(q.by))
    armWatchdog(st, q.sentGen, now)
    U.try(TAG, function() U.mod("phase").markLeaving("restart") end)
end

-- cfg.PauseRestartSequence "direct" (default): the call in the first FAST tick after the confirmation, from the pause:
-- the live-proven state, and the game's own Arcade RETRY runs race SM event 8 + TravelToEvent inside this very dialog
-- callback (also a bridged Accept, clicked earlier in this FAST tick by menubridge, has returned by then). "resume":
-- the screen's own RESUME first (menubridge's live-proven HandleButtonClicked; else the pause CSM -> Idle), then the
-- call PauseRestartAfterResumeMs after the pause ended; still paused 2 s later: the pause CSM -> Idle once more, 2 s
-- after that the request is dropped.
-- VERIFY(V-RST-06), "direct": "restart #1: RequestResetRace sent from the pause, <n> ms after the confirm (requested by
--   P1)", "[phase] leaving the race (restart)", "RACING -> LEAVING  (restart)", "LEAVING -> TRANSIT", "TRANSIT ->
--   PRERACE  map=<same>", perkapply "build ok ..." for every human, "PRERACE -> RACING", "RESTART RACE offered in this
--   race" again. "resume": first "restart: resuming the pause (Btn_ResumeRace:HandleButtonClicked)", "[pause] pause
--   over", then "... sent 2xx ms after the pause ended ...".
local function sequenceTick(st, now)
    local q = st.req
    if not q or q.step == "sent" then return end
    if St.phase ~= "RACING" and St.phase ~= "POSTRACE" then
        U.warn(TAG, "restart request dropped: phase %s (V-RST-06)", tostring(St.phase))
        st.req = nil
        return
    end
    if sequenceMode() ~= "resume" then
        return send(st, q, now, string.format("from the pause, %d ms after the confirm", math.floor(now - q.atMs)))
    end
    local paused = pausedThisTick()
    if q.step == "confirmed" then
        if paused ~= true then
            q.step, q.unpausedMs = "wait", now
            return
        end
        local how = "pause CSM -> Idle"
        local okB = false
        local w = st.screen
        if U.ok(w) then
            local b
            pcall(function() b = w.Btn_ResumeRace end)
            okB = U.ok(b) and pcall(function() b:HandleButtonClicked() end)
            if okB then how = "Btn_ResumeRace:HandleButtonClicked" end
        end
        if not okB then
            local p = pauseMod()
            local okC = p and type(p.resume) == "function" and p.resume("SWGRCouch restart") == true
            if not okC then how = how .. " FAILED" end
        end
        q.step, q.resumeMs = "resuming", now
        st.screen, st.btn, st.placed = nil, nil, false              -- the CSM takes it down; the pause exit runs a GC
        U.log(TAG, "restart: resuming the pause (%s) (V-RST-06)", how)
        return
    end
    if q.step == "resuming" then
        if paused == false then
            q.step, q.unpausedMs = "wait", now
        elseif now - q.resumeMs > 2000 then
            local p = pauseMod()
            if not q.retried and p and type(p.resume) == "function" then
                q.retried, q.resumeMs = true, now
                p.resume("SWGRCouch restart retry")
                U.warn(TAG, "restart: still paused 2 s after the resume: pause CSM -> Idle (V-RST-06)")
            else
                U.warn(TAG, "restart: the pause did not end: request dropped (V-RST-06)")
                st.req = nil
            end
        end
        return
    end
    if q.step == "wait" then
        if paused == true then return end
        if now - q.unpausedMs < opt("PauseRestartAfterResumeMs", 250) then return end
        return send(st, q, now, string.format("%d ms after the pause ended", math.floor(now - q.unpausedMs)))
    end
end

---------------------------------------------------------------------------------------------------- FAST
-- FAST, every race tick, right after pause.poll and menubridge.fastTick (a bridged Accept on the confirm dialog lands
-- in this tick's pause state).
function M.fastTick()
    if not opt("PauseRestart", true) then return end
    local st = R()
    local now = St.nowMs()
    -- a confirmed request first: "direct" leaves the race in this tick (the rest of the tick then sees LEAVING)
    if st.req then U.tryEvery("restart.seq", nil, TAG, sequenceTick, st, now) end
    -- the hook lives while the race could offer the entry (dialog); eligible() reads its armed state
    local wantHook = false
    if St.phase == "RACING" and not st.req and confirmMode() == "dialog" then
        local okB, base = U.tryEvery("restart.base", nil, TAG, baseVerdict, st, now)
        wantHook = okB == true and base == nil
    end
    if wantHook then
        U.tryEvery("restart.hook.ensure", nil, TAG, ensureHook, st, now)
    elseif HK().armed and not st.req then
        HK().armed = false
        U.dbg(TAG, "RequestRestartEvent hook disarmed (%s)", tostring(st.elig and st.elig.why or St.phase))
    end
    U.tryEvery("restart.elig", nil, TAG, eligible, st, now)
    local paused = pausedThisTick()
    if paused == true then
        if not st.sawPause then st.pauseMs = now end
        st.sawPause = true
        if st.placed and now - math.max(st.pauseMs or 0, st.placedMs or 0) < ROWS_MS then
            U.tryEvery("restart.rows", nil, TAG, rowsTick, st, now)
        end
        if st.placed and now - (st.checkMs or 0) >= CHECK_MS then
            st.checkMs = now
            U.tryEvery("restart.check", nil, TAG, recheck, st)
        end
        if st.own and not st.req then U.tryEvery("restart.twice", nil, TAG, twiceTick, st, now) end
    elseif paused == false and st.sawPause and not st.req then
        -- the pause is over: the CSM took the screen down (our own row with it). Only after a pause seen here: a
        -- screen pre-created by the request (decorated before the pause starts) keeps its record; an unknown tick too.
        st.sawPause = false
        st.screen, st.screenKey, st.btn, st.placed, st.own, st.armedUntil = nil, nil, nil, false, nil, nil
        st.rows, st.resume, st.pauseMs, st.placedMs = nil, nil, nil, nil
    end
end

-- Diagnostics (diag.lua prints it).
function M.status()
    local st = R()
    local H = HK()
    return { hook = H.ids ~= nil, armed = H.armed == true, offered = st.verdict == "offered",
             whyNot = st.whyNot, offers = st.offers or 0, placed = st.placed == true,
             pending = st.req and st.req.step or nil, restarts = st.restarts or 0, arcadeSaved = st.arcadePath,
             confirm = confirmMode(), sequence = sequenceMode() }
end

-- Hot reload: the cleared LastPlayedArcadeEvent's path (a scalar) so the next Lua state still restores it at FRONTEND.
function M.persistShared(put)
    put("restart.arcade", R().arcadePath or "")
end

function M.restoreShared(get)
    local v = get("restart.arcade")
    if type(v) == "string" and v ~= "" then
        R().arcadePath = v
        U.log(TAG, "hot reload: LastPlayedArcadeEvent %s is restored at the next FRONTEND (V-RST-05)", v)
    end
end

function M.init()
    R()
    HK().on = hookHandler
    -- "leaving" (also our own markLeaving("restart")): the hook marked for removal (never registered across a travel),
    -- the screen records dropped; a request not sent yet is dropped (a "sent" one waits for its new world)
    St.on("leaving", TAG, function(reason)
        local st = R()
        U.try(TAG, dropHook, "leaving (" .. tostring(reason) .. ")")
        dropOwn(st)
        st.screen, st.screenKey, st.btn, st.placed, st.armedUntil, st.elig, st.sawPause =
            nil, nil, nil, false, nil, nil, false
        if st.req and st.req.step ~= "sent" then
            U.warn(TAG, "restart request dropped: the race is left (%s) (V-RST-06)", tostring(reason))
            st.req = nil
        end
    end)
    St.on("phase", TAG, function(new)
        local st = R()
        if new ~= "RACING" then
            HK().armed = false
            if new ~= "LEAVING" then U.try(TAG, dropHook, "phase " .. tostring(new)) end
        end
        if new == "LOADING" or new == "PRERACE" then
            st.req, st.elig = nil, nil                              -- the restarted race (or any new one) starts clean
        elseif new == "FRONTEND" then
            U.try(TAG, arcadeRestore, "front end")
            st.req, st.elig, st.verdictGen, st.verdict = nil, nil, nil, nil
        end
    end)
    U.log(TAG, "init 0.11.0: PauseRestart=%s confirm %s, sequence %s, label %s, position %s, remote %s, arcade guard "
        .. "%s (V-RST-01..12)", tostring(opt("PauseRestart", true)), confirmMode(), sequenceMode(),
        opt("PauseRestartLabel", "game"), opt("PauseRestartPosition", "below_resume"),
        tostring(opt("PauseRestartRemote", false)), tostring(opt("PauseRestartArcadeGuard", true)))
end

return M
