-- SWGRCouch / fastboot.lua  (NO-INTRO mode: boot straight to the main menu)
-- Skips, on a machine whose save has already been through the boot flow:
--   1. the title screen (Fuse + brand ident movies, "PRESS A TO CONTINUE")      -> FastBootSkipTitle
--   2. the photosensitivity / epilepsy warning                                   -> FastBootSkipPhotosensitivity
--   3. the Epic account login (browser page) and the "SOCIAL OVERLAY UNAVAILABLE ... EOS linking will be disabled"
--      modal, by turning the game's own "use EOS linking" profile flag off      -> FastBootEpic = "off"
-- Never touched: EULA / EULAOffline / PrivacyPolicy(Offline) / SaveVersion / SaveCorrupted / InitialSettings /
-- Brightness / Gamma states. They run before or instead of the photosensitivity screen, so a first boot (or a save
-- problem) still shows them.
--
-- Everything is POLL-based (Blueprint hooks never fire in this build): a game-thread loop (sched.every) armed on each
-- new world, which calls the game's OWN native functions. Evidence (static, nothing executed):
--  [V-bc] = Blueprint bytecode (scripts/kismet-disasm.py on retoc legacy assets, work/boot/*.disasm.txt)
--  [V-x86] = native code read with capstone in .data1 (work/boot/natives.py gives the exec thunks)
--  * Title: WBP_InitialInteraction::BP_OnHandleClickAction (press A) = IsReadyToLeavePreLoad() -> TryAdvanceFromPreLoad()
--    -> FrontEndGameMode::AdvancePreLoadIfPossible() [V-bc]. The game's dev path (ShouldDevSkipBootFlow, a constant
--    "return false" in Shipping [V-x86 exec 0x1461e1500]) does the same as soon as CampaignSaveManager::
--    IsInitialLoadComplete() [V-bc]. IsReadyToLeavePreLoad = PreLoadBoot flow state (12) active AND the save manager
--    load state == 4 [V-x86 0x142f90c94]. AdvancePreLoadIfPossible = optional Epic login attempt, then
--    StateMachine->SetFlow(Boot = 11) [V-x86 0x14708e0c0]; it does NOT check readiness itself, so we do.
--  * Boot: BP_Csm_FrontEnd_BootFlowRedirector: newer-version save -> SaveVersion; VerifySaveData() false ->
--    SaveCorrupted; HasExperiencedBootFlow() true -> PhotoSensitivityWarning, else EULA(Offline) [V-bc]. So the
--    photosensitivity state is only reached on an already-accepted save; we additionally require
--    HasExperiencedBootFlow() == true before skipping it.
--  * WBP_Photosensitivity "CONTINUE" = Anim_Out, then OwningStateMachine:HasNextState() ? ContinueToNextState(None)
--    : FrontEndGameMode:ReturnToMainMenu() [V-bc]; ReturnToMainMenu = StateMachine->SetFlow(PrimaryModeSelect = 1)
--    [V-x86 0x142f9211e]. We make exactly those calls (without the out animation).
--  * Epic: FrontEndGameMode::WantsEosLogin returns UProfileMetaData.bUseEosLinking (+0x68, in the save
--    GriffinSave.6.sav, currently TRUE there) when EOS is up [V-x86 0x142f927b4 + reflect-types offsets + save tag].
--    AdvancePreLoadIfPossible calls AttemptEpicLogin when WantsEosLogin (or arms a PlayFab-login callback that does)
--    [V-x86 0x142f92eba]; the main menu shows the EosRequirementsFail modal when WantsEosLogin and the EOS overlay
--    prerequisites fail (Proton), and its ACCEPT calls PlayfabMarketplaceSdkAuth:DisableEpicLinking() [V-bc
--    WBP_FE_MainMenu]. DisableEpicLinking -> SetUseEosLinking(false), which only writes the profile once the save
--    manager is "ready to save" and mirrors the value into GfnUserSettings.bEnableEOSAccountLinking [V-x86
--    0x14303715e]. Before the title is left the save is not ready to save yet, so we write the profile flag (and the
--    settings mirror) directly, then advance. Same end state as pressing ACCEPT on the game's own modal.
--
-- Wiring: main.lua requires it (MODULES) and calls fastboot.init() once (it registers a "world" listener and arms
-- itself); config keys FastBoot* (see the README / wiring notes); everything has a built-in default.

local cfg   = require("config")
local UEHelpers = require("UEHelpers")
local U     = require("util")
local St    = require("state")
local sched = require("sched")

local M = {}
local TAG = "fastboot"

-- config with built-in defaults (config.lua may not have the keys yet)
local DEF = {
    FastBoot                     = true,
    FastBootSkipTitle            = true,
    FastBootSkipPhotosensitivity = true,
    FastBootEpic                 = "off",   -- "off" (no Epic login / overlay modal; persisted like ACCEPT) | "keep"
    FastBootEosDialog            = true,    -- fallback: accept + remove the EosRequirementsFail modal if it shows anyway
    FastBootStopIdentMovies      = true,    -- Close() the title widget's two media players before leaving the title
    FastBootPollMs               = 50,
    FastBootWindowMs             = 180000,  -- give up this long after arming
    FastBootSettleMs             = 150,     -- a boot screen must be seen this long before it is skipped
    FastBootEpicWaitMs           = 3000,    -- title ready but no profile object found: advance anyway after this
    FastBootMenuGraceMs          = 20000,   -- keep watching the main menu (EOS fallback) this long, then stop
    FastBootPhotoBlind           = false,   -- photosensitivity state seen but its widget not found: ReturnToMainMenu
}
local function opt(name)
    local v = cfg[name]
    if v == nil then return DEF[name] end
    return v
end
local function epicOff() return opt("FastBootEpic") == "off" end

-- paths / names (asset-list.txt + export listings; classes in /Script/Griffin per the BP imports)
local SMDIR = "/Game/Griffin/Gameplay/FrontEnd/StateMachine/"
local function csmPath(n) return SMDIR .. n .. "." .. n end
local P = {
    PhotoState  = csmPath("CSM_FrontEnd_BootFlow_PhotoSensitivityWarning"),
    EpicState   = csmPath("CSM_FrontEnd_BootFlow_EpicLogin"),
    PrimaryMode = csmPath("CSM_FrontEnd_PrimaryModeSelect"),
    SaveManager = "/Script/Griffin.CampaignSaveManager",
    SdkAuth     = "/Script/Griffin.PlayfabMarketplaceSdkAuth",
    Messaging   = "/Script/Griffin.GfnMessagingSubsystem",
}
local W = {
    Title = "WBP_InitialInteraction_C",
    Photo = "WBP_Photosensitivity_C",
    Link  = "WBP_LinkAccount_C",
    Menu  = "WBP_FE_MainMenu_C",
}
local EOS_DIALOG_ID = "EosRequirementsFail"   -- DT_DialogData row used by WBP_FE_MainMenu [V-bc]

---------------------------------------------------------------------------------------------------- state
local S = {}
local function resetVisit()
    S.advanced, S.readySinceMs = false, nil
    S.photoSeenMs, S.photoDone, S.photoNoWidgetLogged = nil, false, false
    S.linkSeenMs, S.linkDone = nil, false
    S.menuAtMs, S.menuScanMs, S.eosChecked, S.eosFallback, S.eosLastRemoveMs = nil, -1e12, false, false, -1e12
    S.scanMs = {}               -- widget class -> last FindAllOf scan (one throttle per screen: stepLink must not
                                --   starve stepPhoto's scan)
    S.lastW = {}                -- widget class -> activated widget found by the last scan
    S.notFrontEndSinceMs = nil
end
S.handle, S.armedAtMs, S.armReason = nil, 0, ""
S.bootDone = false          -- the main menu was reached once in this Lua state: later worlds do not re-arm
S.epic = { lastMs = -1e12, found = false, wasOn = nil, flips = 0, settingsFlips = 0, warned = false, scanMs = -1e12 }
S.log = {}                  -- step -> text, for M.status()
resetVisit()

---------------------------------------------------------------------------------------------------- helpers
--- obj:fn(...) under pcall. Returns ok, value.
local function call(obj, fn, ...)
    if not U.ok(obj) then return false, "invalid object" end
    local args = table.pack(...)
    return pcall(function() return obj[fn](obj, table.unpack(args, 1, args.n)) end)
end

--- Boolean UFunction result, or nil (logged once per function) when the call failed / returned a non-boolean.
local function bcall(obj, fn, ...)
    local ok, v = call(obj, fn, ...)
    if ok and type(v) == "boolean" then return v end
    if U.ok(obj) then
        U.logOnce("fb.bcall!" .. fn, TAG, "WARN %s() unusable here: %s", fn, ok and ("returned " .. type(v)) or tostring(v))
    end
    return nil
end

local function isDefault(o)
    local ok, v = pcall(function()
        local n = o:GetFName():ToString()
        if type(n) == "string" and n:sub(1, 9) == "Default__" then return true end
        local f = o:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject)
        return f == true or (type(f) == "number" and f ~= 0)
    end)
    return ok and v == true
end

--- All live, non-default instances of a class short name (FindAllOf returns nil or a 1-based table [API§6]).
local function instances(cls)
    local ok, list = pcall(FindAllOf, cls)
    if not ok or type(list) ~= "table" then return {} end
    local out = {}
    for i = 1, #list do
        local o = list[i]
        if U.ok(o) and not isDefault(o) then out[#out + 1] = o end
    end
    return out
end

--- First instance of a CommonActivatableWidget class that is activated (a stale, deactivated one is skipped).
local function activeWidget(cls)
    for _, w in ipairs(instances(cls)) do
        local ok, act = call(w, "IsActivated")      -- UCommonActivatableWidget::IsActivated() -> Bool [reflect]
        if ok and act == true then return w end
    end
    return nil
end

local function note(step, f, ...)
    local okF, s = pcall(string.format, f, ...)
    s = okF and s or tostring(f)
    S.log[step] = s
    U.log(TAG, "%s: %s", step, s)
end

---------------------------------------------------------------------------------------------------- Epic linking off
-- UProfileMetaData.bUseEosLinking (Bool, +0x68) and GfnUserSettings.bEnableEOSAccountLinking (its mirror) [reflect].
-- Called before the title is left (forced) and then every 2 s until the loop stops, in case a later load/sync puts the
-- flag back. Returns true when at least one profile object was found.
-- Direct references, no object-array scan on the game thread: UGfnGameInstance.ProfileMetaData (ObjectProperty,
-- reflect.tsv) and GEngine.GameUserSettings (the GfnUserSettingsPC instance, as gfx.lua reads it). FindAllOf is only a
-- fallback while the GameInstance property is not set yet, at most once per 2 s.
local function profiles(now)
    local ok, p = pcall(function() return U.gi().ProfileMetaData end)
    if ok and U.ok(p) then return { p } end
    if now - S.epic.scanMs < 2000 then return {} end
    S.epic.scanMs = now
    return instances("ProfileMetaData")
end

local function userSettingsObj()
    local ok, gus = pcall(function()
        local eng = UEHelpers.GetEngine()
        if not U.ok(eng) then return nil end
        return eng.GameUserSettings
    end)
    if ok and U.ok(gus) then return gus end
    return nil
end

local function enforceEpicOff(now, force)
    local every = S.epic.found and 2000 or 250
    if not force and now - S.epic.lastMs < every then return S.epic.found end
    S.epic.lastMs = now
    local found = false
    for _, p in ipairs(profiles(now)) do
        local ok, v = pcall(function() return p.bUseEosLinking end)
        if ok and type(v) == "boolean" then
            found = true
            if S.epic.wasOn == nil then S.epic.wasOn = v end
            if v then
                local okW, e = pcall(function() p.bUseEosLinking = false end)
                if okW then
                    S.epic.flips = S.epic.flips + 1
                    local okN, name = pcall(function() return p:GetFullName() end)
                    note("epic", "profile bUseEosLinking true -> false (%s); no Epic login / overlay modal",
                        okN and tostring(name) or "?")
                else
                    U.logEvery("fb.epicw", 5000, TAG, "WARN cannot write bUseEosLinking: %s", tostring(e))
                end
            end
        end
    end
    -- settings mirror (GEngine.GameUserSettings = GfnUserSettingsPC): keep the in-game toggle consistent
    local gus = userSettingsObj()
    if gus then
        local ok, v = pcall(function() return gus.bEnableEOSAccountLinking end)
        if ok and v == true then
            if pcall(function() gus.bEnableEOSAccountLinking = false end) then
                S.epic.settingsFlips = S.epic.settingsFlips + 1
                U.log(TAG, "epic: GfnUserSettings bEnableEOSAccountLinking true -> false")
            end
        end
    end
    if found and not S.epic.found then
        U.log(TAG, "epic: profile found (bUseEosLinking was %s at first look)", tostring(S.epic.wasOn))
    end
    S.epic.found = S.epic.found or found
    return found
end

---------------------------------------------------------------------------------------------------- 1. title
local function stopIdentMovies()
    if not opt("FastBootStopIdentMovies") then return end
    for _, w in ipairs(instances(W.Title)) do
        for _, prop in ipairs({ "FirstMovieMediaPlayer", "SecondMovieMediaPlayer" }) do
            local ok, mp = pcall(function() return w[prop] end)
            -- UMediaPlayer::Close(): no OnEndReached, so the Fuse ident cannot chain into the brand ident [V-bc 2388/3482]
            if ok and U.ok(mp) then
                local okC, e = call(mp, "Close")
                if not okC then U.logOnce("fb.close!" .. prop, TAG, "WARN %s:Close() failed: %s", prop, tostring(e)) end
            end
        end
    end
end

local function stepTitle(gm, now)
    if S.advanced or not opt("FastBootSkipTitle") then return end
    -- PreLoadBoot active AND save loaded [V-x86]; false everywhere else (main menu, after a race, boot flow)
    if bcall(gm, "IsReadyToLeavePreLoad") ~= true then S.readySinceMs = nil; return end
    local sm = U.giSubsystem(P.SaveManager)
    if U.ok(sm) and bcall(sm, "IsInitialLoadComplete") == false then return end   -- same gate as the dev path
    S.readySinceMs = S.readySinceMs or now
    if epicOff() and not enforceEpicOff(now, true) then
        if now - S.readySinceMs < opt("FastBootEpicWaitMs") then return end
        if not S.epic.warned then
            S.epic.warned = true
            U.warn(TAG, "epic: no ProfileMetaData object after %d ms; advancing anyway (fallback: menu modal accept)",
                opt("FastBootEpicWaitMs"))
        end
    end
    stopIdentMovies()
    local ok, e = call(gm, "AdvancePreLoadIfPossible")      -- = pressing A on the title [V-bc]
    S.advanced = true
    if ok then
        note("title", "title skipped: AdvancePreLoadIfPossible() after %d ms ready (idents + PRESS A)",
            math.floor(now - S.readySinceMs))
    else
        U.err(TAG, "AdvancePreLoadIfPossible failed: %s (title left to the user)", tostring(e))
    end
end

---------------------------------------------------------------------------------------------------- 2./3. boot screens
-- Generic "a boot screen is up": its CSM state is active (CosmeticStateMachineManager, find-only) or its widget is
-- activated (FindAllOf). Returns seen, widget.
-- FindAllOf walks the whole GUObjectArray on the game thread (during async loading at boot): one throttle per screen
-- class, at most 2 scans per second, and none while the CSM state is resolvable and inactive (the widget is only
-- looked up when the state says the screen is up, or when the state cannot be read at all).
local SCAN_MS = 500
local function screenUp(statePath, widgetCls, now)
    local st = U.csmPoll(statePath)
    if st == false then return false, nil end
    -- the widget found by the last scan, while it is still activated (one IsActivated call, no scan)
    local w = S.lastW[widgetCls]
    if w ~= nil then
        local ok, act = call(w, "IsActivated")
        if not (ok and act == true) then w = nil; S.lastW[widgetCls] = nil end
    end
    if w == nil and now - (S.scanMs[widgetCls] or -1e12) >= ((st == true) and 250 or SCAN_MS) then
        S.scanMs[widgetCls] = now
        w = activeWidget(widgetCls)
        S.lastW[widgetCls] = w
    end
    return (st == true or w ~= nil), w
end

--- The widget's own continue: OwningStateMachine:HasNextState() ? ContinueToNextState(None) : gm:ReturnToMainMenu().
local function continueLike(gm, w, allowMenuFallback)
    local sm = nil
    if w then
        local ok, v = pcall(function() return w.OwningStateMachine end)   -- UFuseScreenWidget +0x5d0 [reflect]
        if ok and U.ok(v) then sm = v end
    end
    if sm then
        if bcall(sm, "HasNextState") == true then
            local ok, e = call(sm, "ContinueToNextState", nil)
            return ok, ok and "ContinueToNextState(None)" or tostring(e)
        end
        local ok, e = call(gm, "ReturnToMainMenu")
        return ok, ok and "ReturnToMainMenu() (no next state)" or tostring(e)
    end
    if allowMenuFallback then
        local ok, e = call(gm, "ReturnToMainMenu")
        return ok, ok and "ReturnToMainMenu() (blind: widget not found)" or tostring(e)
    end
    return false, "no widget / OwningStateMachine"
end

local function stepPhoto(gm, now)
    if S.photoDone or not opt("FastBootSkipPhotosensitivity") then return end
    local up, w = screenUp(P.PhotoState, W.Photo, now)
    if not up then S.photoSeenMs = nil; return end
    S.photoSeenMs = S.photoSeenMs or now
    if now - S.photoSeenMs < opt("FastBootSettleMs") then return end
    -- the redirector only routes here on an experienced save; double-check, never skip on a first boot
    if bcall(gm, "HasExperiencedBootFlow") ~= true then
        S.photoDone = true
        note("photo", "left to the user: HasExperiencedBootFlow() is not true (first boot)")
        return
    end
    if not w and now - S.photoSeenMs < 2000 then return end  -- give the widget time to activate
    local ok, how = continueLike(gm, w, opt("FastBootPhotoBlind") == true)
    if ok then
        S.photoDone = true
        note("photo", "photosensitivity warning skipped: %s", how)
    elseif not S.photoNoWidgetLogged then
        S.photoNoWidgetLogged = true
        U.warn(TAG, "photo: state active but not skipped (%s); FastBootPhotoBlind=true would ReturnToMainMenu", how)
    end
end

-- CSM_FrontEnd_BootFlow_EpicLogin (WBP_LinkAccount): its CANCEL plays Anim_Out then ContinueToNextState(None) [V-bc].
local function stepLink(gm, now)
    if S.linkDone or not epicOff() then return end
    local up, w = screenUp(P.EpicState, W.Link, now)
    if not up then S.linkSeenMs = nil; return end
    S.linkSeenMs = S.linkSeenMs or now
    if now - S.linkSeenMs < opt("FastBootSettleMs") or not w then return end
    local okS, sm = pcall(function() return w.OwningStateMachine end)
    if not okS or not U.ok(sm) then return end
    local ok, e = call(sm, "ContinueToNextState", nil)
    S.linkDone = true
    if ok then
        note("link", "Epic link-account screen cancelled: ContinueToNextState(None)")
    else
        U.warn(TAG, "link: ContinueToNextState failed: %s (screen left to the user)", tostring(e))
    end
end

---------------------------------------------------------------------------------------------------- 4. main menu
-- Main menu reached (PrimaryModeSelect active or WBP_FE_MainMenu activated). EOS fallback when the profile flag could
-- not be turned off before: WantsEosLogin(false) still true -> DisableEpicLinking() (= the modal's ACCEPT [V-bc]),
-- then RemoveMessage(EosRequirementsFail) once per second during the grace window. RemoveMessage(const FName&,
-- Bool, const FGfnMessageHandle&): both refs are CPF_ConstParm (flags 0x8000182) -> plain inputs for UE4SS.
local function stepMenu(gm, now)
    if not S.menuAtMs then
        local st = U.csmPoll(P.PrimaryMode)
        local up = st == true
        -- widget scan: 2/s while the state is unreadable, 1/s while it reads false (a tab's own CSM state may
        -- replace PrimaryModeSelect)
        if not up and now - S.menuScanMs >= ((st == nil) and SCAN_MS or 1000) then
            S.menuScanMs = now
            up = activeWidget(W.Menu) ~= nil
        end
        if up then
            S.menuAtMs = now
            S.bootDone = true
            note("menu", "main menu reached %.1f s after arming (%s)", (now - S.armedAtMs) / 1000, S.armReason)
        end
        return false
    end
    if epicOff() and opt("FastBootEosDialog") then
        if not S.eosChecked then
            S.eosChecked = true
            if bcall(gm, "WantsEosLogin", false) == true then
                S.eosFallback = true
                local ok, e = call(U.giSubsystem(P.SdkAuth), "DisableEpicLinking")
                note("eos", "WantsEosLogin still true at the menu: DisableEpicLinking() %s; removing the %s modal",
                    ok and "called" or ("failed: " .. tostring(e)), EOS_DIALOG_ID)
            end
        end
        if S.eosFallback and now - S.eosLastRemoveMs >= 1000 then
            S.eosLastRemoveMs = now
            local msg = U.giSubsystem(P.Messaging)
            if U.ok(msg) then
                local ok, e = call(msg, "RemoveMessage", U.fname(EOS_DIALOG_ID), true, {})
                if not ok then U.logEvery("fb.rm!", 10000, TAG, "WARN RemoveMessage failed: %s", tostring(e)) end
            end
        end
    end
    return now - S.menuAtMs >= opt("FastBootMenuGraceMs")
end

---------------------------------------------------------------------------------------------------- loop
local function finish(reason)
    local h = S.handle
    S.handle = nil
    if h then sched.cancel(h) end
    U.log(TAG, "stopped (%s): title=%s photo=%s link=%s menu=%s epic(found=%s wasOn=%s flips=%d) eosFallback=%s",
        reason, tostring(S.advanced), tostring(S.photoDone), tostring(S.linkDone), tostring(S.menuAtMs ~= nil),
        tostring(S.epic.found), tostring(S.epic.wasOn), S.epic.flips, tostring(S.eosFallback))
end

local function tick()
    local now = St.nowMs()
    if now - S.armedAtMs > opt("FastBootWindowMs") then finish("window elapsed"); return end
    local gm = U.gm()
    if not U.ok(gm) then return end                     -- loading / no authority game mode yet
    if not U.isA(gm, "FrontEndGameMode") then
        -- a race or other map: nothing to skip there; allow 5 s in case the world event came before the swap
        S.notFrontEndSinceMs = S.notFrontEndSinceMs or now
        if now - S.notFrontEndSinceMs > 5000 then finish("not the front end") end
        return
    end
    S.notFrontEndSinceMs = nil
    if epicOff() then enforceEpicOff(now, false) end
    if not S.menuAtMs then                               -- boot screens only exist before the main menu
        stepTitle(gm, now)
        stepLink(gm, now)
        stepPhoto(gm, now)
    end
    if stepMenu(gm, now) then finish("main menu + grace") end
end

--- (Re)arm the watcher for a new world / visit. Safe to call from any thread (no UObject touched here).
function M.arm(reason)
    if opt("FastBoot") == false then return false end
    resetVisit()
    S.armedAtMs, S.armReason = St.nowMs(), tostring(reason or "?")
    if S.handle then return true end                     -- loop already running: just restarted the visit
    S.handle = sched.every(TAG, opt("FastBootPollMs"), tick)
    U.dbg(TAG, "armed (%s), poll %d ms", S.armReason, opt("FastBootPollMs"))
    return S.handle ~= nil
end

function M.disarm(reason)
    if S.handle then finish(reason or "disarmed") end
end

--- Registers the "world" listener (phase emits it for every new world) and arms for the current boot.
function M.init()
    if opt("FastBoot") == false then
        U.log(TAG, "disabled (cfg.FastBoot = false)")
        return
    end
    -- Boot screens exist only before the first main menu of the process: once it was reached, later worlds (every
    -- post-race front end, a client's connect) do not re-arm the watcher (its scans would only cost frame time).
    St.on("world", TAG, function()
        if S.bootDone then return end
        M.arm("world")
    end)
    M.arm("init")
    U.log(TAG, "init: title=%s photo=%s epic=%s eosDialog=%s", tostring(opt("FastBootSkipTitle")),
        tostring(opt("FastBootSkipPhotosensitivity")), tostring(opt("FastBootEpic")), tostring(opt("FastBootEosDialog")))
end

--- Diag snapshot.
function M.status()
    return {
        running = S.handle ~= nil, armReason = S.armReason, advanced = S.advanced, photoDone = S.photoDone,
        linkDone = S.linkDone, menu = S.menuAtMs ~= nil, eosFallback = S.eosFallback,
        epicFound = S.epic.found, epicWasOn = S.epic.wasOn, epicFlips = S.epic.flips,
        settingsFlips = S.epic.settingsFlips, log = S.log,
    }
end

-- 0.13.0 (Jules 2026-10-12: "bypass the small wait time with sign in status"): every front-end visit (boot and every
-- return from a race) shows WBP_SignInCheck ("SIGN IN STATUS · In Progress") over the main menu until
-- FrontEndGameMode::IsAnyLoginPending() turns false, i.e. until AFrontEndGameMode.LoginTimeoutTime (10.0 s) has passed
-- since StartLoginAttemptTimer(): with Steam offline the login never completes, so it always waits the full 10 s
-- (notes/research/signin-offline.md). cfg.FastBootSignIn "always" (default): on each new front-end game mode the
-- timeout is set to 0 and the timer restarted, the vanilla state after the timeout, reached at once (the menu's own
-- completion steps still run; a real login continues in the background). "off": the game's wait.
local signGm = nil
function M.signInTick()
    if St.phase ~= "FRONTEND" then signGm = nil; return end
    local mode = cfg.FastBootSignIn
    if mode == "off" then return end
    local gm = U.gm()
    if not U.ok(gm) or U.key(gm) == signGm then return end
    if not U.isA(gm, "FrontEndGameMode") then return end
    signGm = U.key(gm)
    local before = nil
    local ok, err = pcall(function()
        before = gm.LoginTimeoutTime
        gm.LoginTimeoutTime = 0.0
        gm:StartLoginAttemptTimer()
    end)
    if ok then
        U.log(TAG, "sign-in wait skipped: LoginTimeoutTime %s -> 0, login timer restarted (V-FB-SIGNIN)", tostring(before))
    else
        U.warn(TAG, "sign-in wait not skipped: %s", tostring(err))
    end
end

return M
