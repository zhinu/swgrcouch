-- builder.lua (G4 Players & launch) - embeds the game's race-builder panel (WBP_FE_QuickRace_Custom_Widget_C)
-- in the main menu's page switcher, captures the chosen race by value on Go, persists and restores it.
-- ARCHITECTURE.md §1.4, §4.2 `builder`, §7 (devscreen alternative).
-- Since 2026-10-07 the lobby's CHOOSE RACE row opens setup.lua's RACE SETUP flow (class -> planet -> track -> mode ->
-- per-player vehicles, notes/research/race-setup.md); this dev panel is the lobby's ADVANCED row. setup.lua hands
-- its finished choice to M.adoptExternal (validation + persistence shared with the panel's Go).
--
-- Verified data (work/bpprops/WBP_FE_QuickRace_Custom_Widget.txt, work/exports/..., reflect-types.py):
--   BP variables: ObjectProperty ChosenArchetype / ChosenGameMode / ChosenPlanet / ChosenTrack / ChosenBuild /
--     ChosenDebugBuild; StructProperty ChosenCondition (FGameplayTag {Name TagName}).
--   Root widget: FuseGridPanel_0 (UFuseGridPanel : UGridPanel), 3 slots (FuseGridPanel_1, List_Choices, Btn_Go).
--   Go handler: BndEvt__..._Btn_Go_K2Node_ComponentBoundEvent_6_CommonButtonBaseClicked__DelegateSignature (1 param:
--     the button). Its BP test: IsValid(Archetype, GameMode, Track) and (IsValid(Build) or IsValid(DebugBuild)).
--   BP_OnActivated -> InitVehicleArchetypes/InitGameModes/InitPlanets/InitBuilds/ClearChoices. ClearChoices only
--     empties List_Choices and collapses it (work/race-builder/...disasm.txt 0-70): Chosen* SURVIVE re-activation,
--     and the BP never resets them consistently (planet change clears ChosenTrack only, ubergraph 1425; a vehicle
--     change clears nothing; ChosenCondition is written only at 1857). The choice is captured by value (the widget
--     is shared with later picks) by builder.poll (live pick / Go poll; the Go hook is an optional extra that never
--     fired in the 2026-10-06 runs) and VALIDATED: the condition must be one of
--     ChosenTrack.TrackConditionDataLayers[i].Tag [RB§1.3, §7.5]; the track must be in
--     GfnGameInstance.Events:GetQuickplayTracksForVehicleAndPlanet(archetype, planet) when that list is readable.
--   UGfnEventList:GetQuickplayTracksForVehicleAndPlanet(Object vehicleType, Object planet) -> Array<Object UTrackDef>
--     (BlueprintPure const, native) [RB§2]; GfnGameInstance.Events @+0x2f0.
--   FText PlayerFacingName: UVehicleArchetype +0x40, UGameModeVariantDef +0x30, UTrackDef +0x30, UPlanetDef +0x30.
--   WidgetBlueprintLibrary:Create(Object WorldContextObject, Class WidgetType, Object OwningPlayer) -> Object
--   PanelWidget:AddChild(Object Content) -> Object
--   GridPanel:AddChildToGrid(Object Content, Int InRow, Int InColumn) -> Object (GridSlot)
--   UCosmeticStateMachine:ChangeStateTo(UCsmAsset newState, FString reason, UObject optionalPayload) (devscreen mode)
--   AFrontEndGameMode:ReturnToMainMenu() (devscreen mode; flags 0x4020401, real body StateMachine->ChangeState(1) [RB§2])
--   AFrontEndGameMode:ResetPrimaryFlow() (devscreen mode; 0 params, real body GfnGameInstance.PrimaryFlow = 0 [RB§2])
--   CosmeticStateMachineManager:IsStateActiveByRef(Object) -> Bool (through U.csmActive; devscreen exit check)

local C        = require("consts")
local cfg      = require("config")
local settings = require("settings")
local St       = require("state")
local U        = require("util")

local M = {}
local TAG = "builder"

-- §7 / [RB§6a]: the game's own dev screen state (hard-imported by CSM_FrontEnd_Root).
local CSM_QUICKRACE_SETUP = (C.ASSET and C.ASSET.CSM_QuickRaceSetup)
    or "/Game/Griffin/Gameplay/FrontEnd/StateMachine/CSM_FrontEnd_QuickRaceSetup.CSM_FrontEnd_QuickRaceSetup"
-- The main menu's cosmetic state (asset-list.txt:59548), target of the devscreen exit fallback.
local CSM_PRIMARY_MODE_SELECT = (C.ASSET and C.ASSET.CSM_PrimaryModeSelect)
    or "/Game/Griffin/Gameplay/FrontEnd/StateMachine/CSM_FrontEnd_PrimaryModeSelect.CSM_FrontEnd_PrimaryModeSelect"

-- Settings keys of the persisted choice, in the order of the choice fields.
local PERSIST = {
    { key = "LastRaceArchetype", field = "archetype", class = "VehicleArchetype" },
    { key = "LastRaceGameMode",  field = "gameMode",  class = "GameModeVariantDef" },
    { key = "LastRacePlanet",    field = "planet",    class = "PlanetDef" },
    { key = "LastRaceTrack",     field = "track",     class = "TrackDef" },
    { key = "LastRaceBuild",     field = "build",     class = "VehicleBuildDef" },
}

-- A restored object must be of the class LaunchCustomRace expects for that argument (UE4SS does not type-check
-- Object params, and the native body reads class-specific fields: GridMakeup, Archetype, ...). An unresolvable
-- class is not checked (logged once): a missing class must not discard every saved race.
local function hasClass(o, classKey)
    local cls = U.class(classKey)
    if not U.ok(cls) then
        U.logOnce("builder.cls." .. classKey, TAG, "class %s not resolvable: restored %s objects are not class-checked",
            tostring(C.CLASS[classKey] or classKey), classKey)
        return true
    end
    local ok, v = pcall(U.callMethod, o, "IsA", cls)
    return ok and v == true
end

local function status(text)
    U.log(TAG, "%s", text)
    St.emit("status", text)
end

local function devscreen()
    return cfg.BuilderMode == "devscreen"
end

-- cfg.BuilderAdopt: "live" (default: a complete, validated pick on the embedded builder becomes the race as soon as
-- it is made; Go / BACK / leaving only return to the lobby and persist) | "go" (only Go adopts; leaving the page
-- adopts a complete pick only while no Go was ever detected in this session - the pre-2026-10-07 behaviour).
local function adoptMode()
    if cfg.BuilderAdopt == "go" then return "go" end
    return "live"
end

-- cfg.BuilderGoPoll (default true): Btn_Go is made selectable + toggleable so every click flips GetSelected(), which
-- builder.poll() reads (the BndEvt Go hook never fires in this build). false: Btn_Go is left untouched (Go then
-- works only through the optional hook; with BuilderAdopt "live" the pick is adopted anyway).
local function goPollOn()
    return cfg.BuilderGoPoll ~= false
end

-- UObject or nil (never an invalid userdata inside a choice table).
local function objOrNil(o)
    if U.ok(o) then return o end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Choice helpers
---------------------------------------------------------------------------------------------------

function M.isValid(c)
    if type(c) ~= "table" then return false end
    return U.ok(c.archetype) and U.ok(c.gameMode) and U.ok(c.track)
        and (U.ok(c.build) or U.ok(c.debugBuild))
end

-- FText PlayerFacingName, falling back to the object's FName.
local function facingName(o)
    if not U.ok(o) then return nil end
    -- pcall, not U.try: an empty name is a normal case and must not log an ERROR with a traceback
    local ok, t = pcall(function() return U.str(o.PlayerFacingName) end)
    if ok and type(t) == "string" and t ~= "" then return t end
    local ok2, n = pcall(function() return o:GetFName():ToString() end)
    if ok2 and n then return n end
    return "?"
end

-- "JAKKU / THE WAR FIELDS / RACE / LANDSPEEDER / SUNSET"
function M.describe(c)
    if type(c) ~= "table" then return "" end
    local parts = {}
    for _, o in ipairs({ c.planet, c.track, c.gameMode, c.archetype }) do
        local s = facingName(o)
        if s then parts[#parts + 1] = s end
    end
    if c.condition and c.condition ~= "" then
        local cond = c.condition:gsub("^TrackCondition%.", ""):gsub("%.", " ")
        parts[#parts + 1] = cond
    end
    return string.upper(table.concat(parts, " / "))
end

-- Condition tag string -> the same string if the track offers it, else "" (= "None"; LaunchCustomRace then
-- uses no condition layer) or, with cfg.ConditionPassMode = "trackdefault", the track's first condition.
-- The persisted choice of an older session goes through here too.
local function validCondition(track, cond)
    if type(cond) ~= "string" or cond == "" or not U.ok(track) then return cond or "" end
    local found, first, n = false, nil, 0
    U.try(TAG, function()
        local arr = track.TrackConditionDataLayers
        n = arr:GetArrayNum()
        for i = 1, n do                               -- numeric loop up to GetArrayNum (never past the end)
            local t = U.str(arr[i].Tag.TagName)
            if i == 1 then first = t end
            if t == cond then found = true; break end
        end
    end)
    if found then return cond end
    local repl = ""
    if cfg.ConditionPassMode == "trackdefault" and first and first ~= "None" then repl = first end
    U.warn(TAG, "condition %s is not offered by track %s (%d condition(s)); using %s",
        cond, U.pathOf(track), n, repl ~= "" and repl or "None")
    return repl
end

-- false only when the game's own track list for (archetype, planet) is readable, non-empty and lacks the track
-- (ChosenTrack is not reset when the vehicle changes). Unknown -> true (the BP's own Go test accepts it too).
local function trackFitsClass(c)
    if not (U.ok(c.track) and U.ok(c.archetype) and U.ok(c.planet)) then return true end
    local fits = true
    U.try(TAG, function()
        local events = U.gi().Events
        if not U.ok(events) then return end
        -- VERIFY(V-BLD-02): the native filter returns the same list the Track picker showed.
        -- An array RETURN value comes back as a Lua table of RemoteUnrealParams (LuaUObject.cpp push_arrayproperty
        -- GetParam -> RemoteUnrealParam::construct; the param has only get/set/type, no IsValid), so the elements
        -- are unwrapped with U.arrayToTable before they are compared.
        local list = U.arrayToTable(events:GetQuickplayTracksForVehicleAndPlanet(c.archetype, c.planet))
        U.log(TAG, "track filter: %d track(s) offered for %s on %s", #list, U.pathOf(c.archetype), U.pathOf(c.planet))
        if #list == 0 then return end
        -- 0.10.0 (V-TRK-09): compare FNames; U.same(list[i], c.track) never matched (5 of 5 calls, cause unknown: the
        -- UE4SS __eq compares the same pointer U.key reads). Pods: 9 pod TrackDefs have no VehicleTypeTag, so they
        -- are only in the speeder lists of their planet (notes/research/track-whitelist.md §2).
        local function fname(o)
            if not U.ok(o) then return "" end   -- GetFName on a null wrapper is a native AV
            local ok, n = pcall(function() return o:GetFName():ToString() end)
            return ok and n or ""
        end
        local want = fname(c.track)
        local function scan(l)
            for i = 1, #l do
                if U.ok(l[i]) and fname(l[i]) == want then return true end
            end
            return false
        end
        fits = scan(list)
        if not fits and U.pathOf(c.archetype):find("VA_Plane", 1, true) then
            local V = U.mod("vehicles")
            local car = V and V.archetypeObj(V.classByArch(0))
            if car then fits = scan(U.arrayToTable(events:GetQuickplayTracksForVehicleAndPlanet(car, c.planet))) end
        end
        if not fits then
            U.logOnce("builder.fitkeys", TAG, "track filter miss: first entry %s (key %s), pick %s (key %s)",
                fname(list[1]), U.key(list[1]), want, U.key(c.track))
        end
    end)
    return fits
end

-- Runs inside the Go handler (or M.onLeavePage); the widget keeps whatever was picked last (see the header).
function M.capture(p)
    if not U.ok(p) then return nil end
    local c = {
        archetype  = objOrNil(p.ChosenArchetype),
        gameMode   = objOrNil(p.ChosenGameMode),
        planet     = objOrNil(p.ChosenPlanet),
        track      = objOrNil(p.ChosenTrack),
        build      = objOrNil(p.ChosenBuild),
        debugBuild = objOrNil(p.ChosenDebugBuild),
        condition  = "",
    }
    U.try(TAG, function()
        -- struct property field read [API§8]; NAME_None prints as "None"
        local tag = U.str(p.ChosenCondition.TagName)
        if tag and tag ~= "None" then c.condition = tag end
    end)
    c.condition = validCondition(c.track, c.condition)
    if not trackFitsClass(c) then
        U.warn(TAG, "track %s is not offered for %s on %s (stale pick); choice rejected",
            U.pathOf(c.track), U.pathOf(c.archetype), U.pathOf(c.planet))
        c.track = nil                                 -- isValid fails -> "PICK VEHICLE, MODE, TRACK AND BUILD"
    end
    c.label = M.describe(c)
    return c
end

function M.persist(c)
    if type(c) ~= "table" then return end
    for _, e in ipairs(PERSIST) do
        local o = c[e.field]
        settings.set(e.key, U.ok(o) and U.pathOf(o) or "")
    end
    settings.set("LastRaceCondition", c.condition or "")
    settings.set("LastRaceDebugBuild", "")       -- debug builds are runtime objects (SpawnObject + LoadFromConfig)
    U.log(TAG, "persisted: %s", c.label or "?")
end

-- Game thread. Rebuilds the choice from settings.txt paths (StaticFindObject, then LoadAsset in U.obj).
function M.restoreFromSettings()
    if M.isValid(St.race.choice) then return true end    -- keep a live choice (it may hold a debug build)
    local c = { condition = settings.get("LastRaceCondition") or "" }
    local any = false
    for _, e in ipairs(PERSIST) do
        local path = settings.get(e.key)
        -- settings.txt is hand-editable: only a full object path "/Mount/Pkg.Obj" ever reaches StaticFindObject /
        -- LoadAsset (a short name or garbage would go to the engine finders and could load any package it names)
        if type(path) == "string" and path ~= "" and not path:match("^/%w[^%s]*%.[^%s]+$") then
            U.warn(TAG, "last race: %s = %q is not an object path '/Pkg.Obj' (settings.txt edited?); cleared", e.key,
                path)
            settings.set(e.key, "")
            path = ""
        end
        if type(path) == "string" and path ~= "" then
            any = true
            local ok, o = U.try(TAG, U.obj, path)
            -- VERIFY(V-BLD-04): persisted data-asset paths resolve again in a new session.
            if ok and U.ok(o) and not hasClass(o, e.class) then
                U.warn(TAG, "last race: %s = %s is not a %s (settings.txt edited?); dropped", e.key, path, e.class)
            elseif ok and U.ok(o) then
                c[e.field] = o
            else
                U.warn(TAG, "last race: %s no longer resolves (%s)", e.key, path)
            end
        end
    end
    if not any then return false end
    if M.isValid(c) then
        c.condition = validCondition(c.track, c.condition)
        c.label = M.describe(c)
        St.race.choice = c
        U.log(TAG, "last race restored: %s", c.label)
        St.emit("race_chosen", c)
        return true
    end
    St.race.choice = nil
    U.warn(TAG, "last race in settings.txt is incomplete or stale; no race preselected")
    return false
end

---------------------------------------------------------------------------------------------------
-- Embedding (once per main-menu instance; called by menu_tab.install)
---------------------------------------------------------------------------------------------------

local function addBackButton(bw, pc)
    if not cfg.BuilderBackButton then return end
    local root = bw.WidgetTree.RootWidget
    if not U.isA(root, C.CLASS.GridPanel) then
        U.warn(TAG, "builder root is not a GridPanel; no BACK button (use F5 or switch tabs)")
        return
    end
    local back = U.mod("ui").button(pc, "builderBack", "< BACK TO LOBBY", function() M.close() end)
    if not U.ok(back) then return end
    -- VERIFY(V-BLD-03): row/column of the free grid cell (cfg.BuilderBackRow / BuilderBackCol).
    local slot = root:AddChildToGrid(back, cfg.BuilderBackRow, cfg.BuilderBackCol)
    U.log(TAG, "BACK button added at grid row %d col %d (slot %s)",
        cfg.BuilderBackRow, cfg.BuilderBackCol, tostring(U.ok(slot)))
end

function M.ensure(menu)
    if devscreen() then return end                    -- §7: the game's own screen is used instead
    if U.ok(St.menu.builder) then return end           -- St.resetMenu() clears it for a new menu instance
    if not U.ok(menu) then return end
    local pc = menu:GetOwningPlayer()
    local cls = U.class(C.BP.Builder)                  -- StaticFindObject, else LoadAsset(<asset path>) inside U.class
    if not U.ok(cls) then
        U.warn(TAG, "WBP_FE_QuickRace_Custom_Widget_C is not loadable; race builder unavailable")
        return
    end
    -- Same context fallback as ui.make: the UIManager creates the main menu without an owning-player parameter
    -- [UI§1.4], so its owner (presumed P1) may be null; then the world is the WorldContextObject and no owner is set.
    local owner = U.ok(pc) and pc or nil
    local ctx = owner or U.world()
    if not U.ok(ctx) then
        U.warn(TAG, "no world context for the race builder widget")
        return
    end
    if not owner then U.warn(TAG, "main menu has no owning player; race builder created without an owner") end
    pc = owner
    local bw = U.WBL():Create(ctx, cls, owner) -- Create(WorldContextObject, WidgetType, OwningPlayer) [3 params]
    if not U.ok(bw) then
        U.warn(TAG, "creating the race builder widget failed")
        return
    end
    -- VERIFY(V-BLD-01): the panel works embedded (pickers filled, pad navigation inside WS_ScreenContent).
    menu.WS_ScreenContent:AddChild(bw)
    St.menu.builder = bw
    St.menu.hooksBuilder = true
    U.retryPendingHooks()                              -- the Go hook can register now that the class is loaded
    U.try(TAG, addBackButton, bw, pc)
    -- Go is detected by builder.poll() (Btn_Go armed as a selectable+toggleable button, GetSelected edge), never
    -- through ui's click registry (that would be a second detector for the same click). cfg.GoMode is obsolete.
    M.armGo(bw)
    U.log(TAG, "race builder embedded in the main menu (adopt %s, Go poll %s, Go hook optional)", adoptMode(),
        tostring(goPollOn()))
end

function M.open()
    local menu = St.menu.widget
    if not U.ok(menu) then
        status("MAIN MENU NOT READY")
        return false
    end
    if devscreen() then
        -- §7 alternative: the dev screen's own OnEventChosen listener launches LaunchCustomRace itself on Go,
        -- with whatever PCs exist at that moment, so the dormant guests are dropped first - but only once the
        -- screen can actually be opened (else the lobby would stay up with no join poll).
        -- Deviation: join.commit is not in builder's §4.2 "May call" line (same group G4).
        local sm = menu.OwningStateMachine
        local csm = U.obj(CSM_QUICKRACE_SETUP)
        if not (U.ok(sm) and U.ok(csm)) then
            status("RACE BUILDER SCREEN NOT AVAILABLE")
            return false
        end
        -- an un-joined guest cannot be removed (RemovePlayer crash) and the dev screen launches with every PC
        local dormant = U.mod("join").dormantText()
        if dormant then
            status(dormant .. ": PRESS A ON IT FIRST")
            return false
        end
        U.mod("join").commit()
        -- PrimaryFlow is launch.prepareExternal's proof that the dev screen's listener ran LaunchCustomRace (which sets
        -- QuickRace first [RB§3.1]). An earlier quick race may have left it at QuickRace: cleared here, so a QuickRace
        -- seen on Go can only come from this screen's launch.
        local reset = false
        local gm = U.gm()
        if U.ok(gm) and U.isA(gm, "FrontEndGameMode") then
            reset = U.try(TAG, function() gm:ResetPrimaryFlow() end)          -- 0 params
        end
        if not reset then
            U.try(TAG, function() U.gi().PrimaryFlow = C.E.PrimaryFlow.Unknown end)
        end
        -- VERIFY(V-BLD-01): ChangeStateTo(CSM_FrontEnd_QuickRaceSetup) renders and focuses the dev screen.
        sm:ChangeStateTo(csm, "SWGRCouch", nil)
        -- the join set is committed now: a dev-screen exit that bypasses close() (the game's own Back) is caught by
        -- menu_tab (RegisterTabs again, or the SLOW ensure() seeing the state inactive), which reselects our tab
        St.menu.devscreen = true
        return true
    end
    if not U.ok(St.menu.builder) then M.ensure(menu) end
    if not U.ok(St.menu.builder) then
        status("RACE BUILDER NOT AVAILABLE")
        return false
    end
    U.mod("menu_tab").showPage("builder")             -- SetActiveWidget + ActivateWidget + RequestRefreshFocus
    return true
end

-- Undo of the cosmetic ChangeStateTo(CSM_FrontEnd_QuickRaceSetup) at the same level. -> true when the call went out.
local function csmToMainMenu(why)
    local menu = St.menu.widget
    local sm = U.ok(menu) and menu.OwningStateMachine or nil
    local csm = U.obj(CSM_PRIMARY_MODE_SELECT)
    if not (U.ok(sm) and U.ok(csm)) then
        U.warn(TAG, "devscreen exit (%s): no state machine or CSM_FrontEnd_PrimaryModeSelect", why)
        return false
    end
    -- VERIFY(V-BLD-01): ChangeStateTo(CSM_FrontEnd_PrimaryModeSelect) (3 args) brings the main menu back.
    sm:ChangeStateTo(csm, "SWGRCouch", nil)
    U.log(TAG, "devscreen exit: cosmetic state set to PrimaryModeSelect (%s)", why)
    return true
end

-- cfg.BuilderDevscreenExit: "auto" (default: native ReturnToMainMenu, then the cosmetic fallback if the dev screen is
-- still active) | "native" (ReturnToMainMenu only) | "csm" (cosmetic ChangeStateTo only).
local function exitDevscreen()
    local mode = cfg.BuilderDevscreenExit or "auto"
    if mode ~= "csm" then
        local gm = U.gm()
        if U.ok(gm) and U.isA(gm, "FrontEndGameMode") then
            -- VERIFY(V-BLD-01): ReturnToMainMenu (native ChangeState(1) while already in 1: open() only changed the
            -- cosmetic CSM [RB§6a]) brings the cosmetic CSM back to the main menu. The dev screen's own Back makes the
            -- same call [RB§1 Back]. Fallback: cfg.BuilderDevscreenExit = "csm" (or "auto", checked below).
            U.try(TAG, function() gm:ReturnToMainMenu() end)
        end
        if mode == "native" then return end
        -- VERIFY(V-BLD-01): the cosmetic state change is visible synchronously through IsStateActiveByRef.
        local still = U.csmActive(CSM_QUICKRACE_SETUP)
        if still ~= true then
            if still == nil then U.log(TAG, "devscreen exit: dev screen state not readable; assuming it closed") end
            return
        end
        U.warn(TAG, "devscreen exit: dev screen still active after ReturnToMainMenu; cosmetic fallback")
    end
    U.try(TAG, csmToMainMenu, mode)
end

function M.close()
    if devscreen() then
        St.menu.devscreen = nil
        exitDevscreen()
        U.mod("menu_tab").selectOurTab()
        return
    end
    U.mod("menu_tab").showPage("lobby")
end

---------------------------------------------------------------------------------------------------
-- Go and choice capture. POLL FIRST (live run 2026-10-06: the BndEvt Go hook registers but never fires).
--   builder.poll() (MAIN, driven by menu_tab.pollTab) is the required path:
--     * Go: Btn_Go is armed selectable + toggleable (UCommonButtonBase SetIsSelectable / SetIsToggleable, as ui's
--       ClickMode poll does for our rows): a click (pad A or mouse) flips GetSelected(), the poll resets it with
--       SetIsSelected(false, false) and runs handleGo. The BP's own Go handler still runs (it only broadcasts
--       OnEventChosen, which has no listener on our instance).
--     * live pick (cfg.BuilderAdopt "live"): the raw Chosen* variables are read each poll while the page is shown;
--       when they change into a complete pick that passes capture()'s validation, it becomes St.race.choice at once
--       (persisted when Go / BACK / leaving the page ends the visit). Go itself is then optional.
--     * dev screen (cfg.BuilderMode "devscreen"): the game's own listener launches on Go; the poll sees
--       GfnGameInstance.PrimaryFlow become QuickRace (builder.open reset it) and does the hook's bookkeeping.
--   The Go hook stays registered as an optional extra; handleGo de-duplicates (GO_DUP_MS) so hook + poll on the
--   same click run it once.
---------------------------------------------------------------------------------------------------

local GO_DUP_MS = 1500
local goSeen = false      -- a Go reached handleGo in this session ("go" mode: leaving the page = cancel)
local lastGoMs = -1e9     -- handleGo de-duplication (hook + poll on one click)
local goHookFired = false
local armedKey = 0        -- builder instance whose Btn_Go is armed for the GetSelected poll
-- live pick: key = builder instance, shown = the page was visible at the previous poll, sig = raw Chosen* signature,
-- dirty = a live-adopted choice not yet persisted
local live = { key = 0, shown = false, sig = nil, dirty = false }
local devLaunchSeen = false   -- devscreen: the PrimaryFlow edge of this dev-screen visit was handled

local function sameChoice(a, b)
    return type(a) == "table" and type(b) == "table" and U.same(a.archetype, b.archetype)
        and U.same(a.gameMode, b.gameMode) and U.same(a.track, b.track)
        and ((a.build == nil and b.build == nil) or U.same(a.build, b.build))
        and ((a.debugBuild == nil and b.debugBuild == nil) or U.same(a.debugBuild, b.debugBuild))
        and (a.condition or "") == (b.condition or "")
end

-- The BP's own Go test on the raw Chosen* variables [RB§1.3].
local function rawComplete(p)
    return U.ok(p.ChosenArchetype) and U.ok(p.ChosenGameMode) and U.ok(p.ChosenTrack)
        and (U.ok(p.ChosenBuild) or U.ok(p.ChosenDebugBuild))
end

-- Raw signature of the pick: object addresses + condition tag (property reads only, no UFunction call).
local function rawSig(p)
    local parts = {}
    for _, n in ipairs({ "ChosenArchetype", "ChosenGameMode", "ChosenPlanet", "ChosenTrack", "ChosenBuild",
                         "ChosenDebugBuild" }) do
        local o = p[n]
        parts[#parts + 1] = U.ok(o) and tostring(U.key(o)) or "-"
    end
    local okT, tag = pcall(function() return U.str(p.ChosenCondition.TagName) end)
    parts[#parts + 1] = okT and tostring(tag) or "?"
    return table.concat(parts, "|")
end

local function flushPersist(why)
    if not live.dirty then return end
    live.dirty = false
    if M.isValid(St.race.choice) then
        M.persist(St.race.choice)
        U.dbg(TAG, "live pick persisted (%s)", tostring(why))
    end
end

-- Adopt a captured, valid choice (live pick or leave fallback). persistNow: write settings.txt at once.
local function adopt(c, why, persistNow)
    St.race.choice = c
    if persistNow then
        M.persist(c)
        live.dirty = false
    else
        live.dirty = true
    end
    St.emit("race_chosen", c)
    status("RACE: " .. c.label)
    U.log(TAG, "race adopted (%s): %s", why, c.label)
end

-- A complete choice made outside the embedded panel (setup.lua's RACE SETUP flow): validated like a Go, adopted,
-- persisted (the five LastRace* keys; setup.persistExtras stores its own extras) and announced. -> true when adopted.
-- c.setup (class, mode, grid size, per-player vehicles) rides along in St.race.choice for launch.start.
function M.adoptExternal(c, why)
    if not M.isValid(c) then
        status("PICK VEHICLE, MODE, TRACK AND BUILD")
        return false
    end
    c.condition = validCondition(c.track, c.condition)
    if not trackFitsClass(c) then
        U.warn(TAG, "%s: track %s is not offered for %s on %s; adopted anyway (the setup listed it)", tostring(why),
            U.pathOf(c.track), U.pathOf(c.archetype), U.pathOf(c.planet))
    end
    c.label = c.label or M.describe(c)
    St.race.choice = c
    M.persist(c)
    live.dirty = false
    St.emit("race_chosen", c)
    status("RACE: " .. c.label)
    U.log(TAG, "race adopted (%s): %s | archetype=%s mode=%s track=%s build=%s condition=%s", tostring(why), c.label,
        U.pathOf(c.archetype), U.pathOf(c.gameMode), U.pathOf(c.track), c.build and U.pathOf(c.build) or "-",
        c.condition ~= "" and c.condition or "None")
    return true
end

-- Arm Btn_Go for the GetSelected poll (once per builder instance) and clear a selection left by an earlier click.
function M.armGo(bw)
    if not goPollOn() or not U.ok(bw) then return end
    U.try(TAG, function()
        local go = bw.Btn_Go
        if not U.ok(go) then
            U.logOnce("builder.nogo", TAG, "builder has no Btn_Go: Go poll unavailable (live pick still works)")
            return
        end
        if armedKey ~= U.key(bw) then
            go:SetIsSelectable(true)          -- SetIsSelectable(Bool bInIsSelectable)
            go:SetIsToggleable(true)          -- SetIsToggleable(Bool bInIsToggleable)
            armedKey = U.key(bw)
            -- VERIFY(V-BLD-06): pad A / mouse on Btn_Go logs "Go: ..." with "(poll)".
            U.log(TAG, "Btn_Go armed for the Go poll")
        end
        if go:GetSelected() == true then go:SetIsSelected(false, false) end   -- (Bool InSelected, Bool bGiveClickFeedback)
    end)
end

-- true when a Go click was consumed (the selection is reset here).
local function pollGoClick(bw)
    if not goPollOn() then return false end
    local go = bw.Btn_Go
    if not U.ok(go) then return false end
    if go:GetSelected() ~= true then return false end   -- GetSelected() -> Bool
    go:SetIsSelected(false, false)
    return true
end

-- Live pick: adopt when the raw pick changed into a complete, valid one that differs from the current race.
local function pollLive(bw)
    local sig = rawSig(bw)
    if live.sig == sig then return end
    live.sig = sig
    if adoptMode() ~= "live" or not rawComplete(bw) then return end
    local c = M.capture(bw)
    if not M.isValid(c) or sameChoice(c, St.race.choice) then return end
    adopt(c, "live pick", false)
end

-- Dev screen: the game's listener launched iff PrimaryFlow became QuickRace (builder.open reset it before).
local function pollDevscreen()
    if not St.menu.devscreen then devLaunchSeen = false; return end
    if devLaunchSeen or St.launch.pending or St.phase ~= "FRONTEND" then return end
    local okF, flow = pcall(function() return U.gi().PrimaryFlow end)
    if not okF or flow ~= C.E.PrimaryFlow.QuickRace then return end
    devLaunchSeen = true
    U.log(TAG, "dev screen launched the race (PrimaryFlow = QuickRace): Go seen by the poll")
    local w = FindFirstOf("WBP_FE_QuickRace_Custom_Widget_C")   -- the dev screen's Custom_EventSetup (non-CDO)
    if U.ok(w) then M.handleGo(w, "poll") end
    if not St.launch.pending then U.mod("launch").prepareExternal(nil) end
end

-- MAIN loop (menu_tab.pollTab), front end. Never throws out of a single read (callers wrap it in U.try).
function M.poll()
    if devscreen() then return pollDevscreen() end
    local bw = St.menu.builder
    local shown = U.ok(bw) and St.menu.visible == "builder"
    if not shown then
        if live.shown then
            live.shown = false
            flushPersist("page left")
        end
        return
    end
    if not live.shown or live.key ~= U.key(bw) then
        -- page (re)shown: baseline the pick (the Chosen* of an earlier visit survive re-activation) and clear a Go
        -- selection that an unseen click (e.g. the hook path) left behind
        live.shown, live.key, live.sig = true, U.key(bw), rawSig(bw)
        M.armGo(bw)
        return
    end
    if pollGoClick(bw) then
        M.handleGo(bw, "poll")
        return
    end
    pollLive(bw)
end

-- Leaving the builder page (BACK, F5, tab switch; menu_tab.showPage / hidePages).
--   "live": a complete pick not adopted yet (changed since the last poll) is adopted; the visit's pick is persisted.
--   "go": fallback for a Go that was never detected (V-CORE-07 / V-BLD-06): a complete pick is adopted only while
--         no Go was ever detected in this session; once one was, leaving the page is a cancel.
function M.onLeavePage()
    if devscreen() then return end
    local bw = St.menu.builder
    if adoptMode() == "live" then
        -- (skipped right after a Go: handleGo captured this very pick and its close() is what brings us here)
        -- and only when the pick changed since the last poll (the poll already judged the current one)
        if U.ok(bw) and St.nowMs() - lastGoMs >= GO_DUP_MS and rawSig(bw) ~= live.sig and rawComplete(bw) then
            live.sig = rawSig(bw)
            local c = M.capture(bw)
            if M.isValid(c) and not sameChoice(c, St.race.choice) then adopt(c, "page left", true) end
        end
        flushPersist("page left")
        return
    end
    if goSeen or not U.ok(bw) then return end
    local c = M.capture(bw)
    if not M.isValid(c) or sameChoice(c, St.race.choice) then return end
    U.warn(TAG, "no Go detected; adopting the builder's complete pick on leaving: %s", c.label)
    adopt(c, "leave fallback", true)
end

-- Go post-hook: OPTIONAL extra (never fired in the 2026-10-06 runs). handleGo de-duplicates against the poll.
function M.onGo(ctx)
    if not goHookFired then
        goHookFired = true
        U.log(TAG, "Go BP hook fired: BP hooks work in this session (the poll stays the main path)")
    end
    M.handleGo(ctx:get(), "hook")
end

-- One Go, from the poll (src "poll") or the optional hook (src "hook"); a second report within GO_DUP_MS is dropped.
function M.handleGo(p, src)
    if not U.ok(p) then return end
    if devscreen() then
        if U.ok(St.menu.builder) and not U.same(p, St.menu.builder) then return end
    elseif not U.same(p, St.menu.builder) then
        return                                         -- the dev screen's own Custom_EventSetup instance
    end
    local now = St.nowMs()
    if now - lastGoMs < GO_DUP_MS then
        U.dbg(TAG, "Go (%s) already handled %d ms ago: ignored", tostring(src), math.floor(now - lastGoMs))
        return
    end
    lastGoMs = now
    if not devscreen() then
        -- a hook-detected Go leaves Btn_Go selected (armed button): clear it, so the poll does not see it again
        U.try(TAG, function()
            local go = p.Btn_Go
            if goPollOn() and U.ok(go) and go:GetSelected() == true then go:SetIsSelected(false, false) end
        end)
    end
    -- The BP's own Go test on the raw Chosen* (the dev screen's listener launched iff it passed).
    local rawValid = rawComplete(p)
    goSeen = true
    local c = M.capture(p)
    if not M.isValid(c) then
        if devscreen() and rawValid then
            -- the game launched its (stale) pick anyway: keep the bookkeeping right, do not persist it
            U.mod("launch").prepareExternal(nil)
            return
        end
        status("PICK VEHICLE, MODE, TRACK AND BUILD")
        return
    end
    -- VERIFY(V-BLD-02): the captured objects and the condition tag match the pickers.
    U.log(TAG, "Go (%s): %s | archetype=%s mode=%s planet=%s track=%s build=%s debugBuild=%s condition=%s",
        tostring(src), c.label, U.pathOf(c.archetype), U.pathOf(c.gameMode), c.planet and U.pathOf(c.planet) or "-",
        U.pathOf(c.track), c.build and U.pathOf(c.build) or "-",
        c.debugBuild and U.pathOf(c.debugBuild) or "-", c.condition ~= "" and c.condition or "None")
    St.race.choice = c
    M.persist(c)
    live.dirty = false
    live.sig = rawSig(p)                               -- the live poll must not re-adopt this pick
    St.emit("race_chosen", c)
    if devscreen() then
        -- The dev screen's listener has already called LaunchCustomRace with the widget's Chosen* (travel itself
        -- happens on a later tick): pending/launchedByUs/returnToTab and, on a listen host, net.beforeLaunch.
        -- Deviation: launch.prepareExternal is not in builder's §4.2 "May call" line.
        devLaunchSeen = true
        U.warn(TAG, "devscreen mode: the game launched the race itself; choice saved for the rematch")
        U.mod("launch").prepareExternal(c)
        return
    end
    M.close()
    status("RACE: " .. c.label)
    if cfg.LaunchOnGo then
        U.mod("launch").start()
    end
end

---------------------------------------------------------------------------------------------------
-- init: the optional Go hook is queued until the class is loaded (U.hook / U.retryPendingHooks)
---------------------------------------------------------------------------------------------------

function M.init()
    U.hook(C.FN.BuilderGo, { post = M.onGo }, TAG)
end

return M
